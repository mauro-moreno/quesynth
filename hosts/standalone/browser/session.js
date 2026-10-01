"use strict";
// One browser page and the daemon connection it owns.
//
// The daemon is the only authority. What this keeps -- the values the page is
// believed to show, writes still in flight, the bank last sent -- is there to
// decide what to tell the page and is thrown away with the connection.
//
// Everything that talks to the daemon runs through one queue, so a poll never
// overlaps a page request and the order the page sent things in is the order
// the daemon sees them.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { DaemonError, ConnectionError } = require("./daemon");
const bank = require("./bank");

const DEFAULTS = {
  pollMs: 100,
  // How long the page's own write outranks what the daemon reports for that
  // parameter. A write is applied by the audio thread on its next block, a
  // few milliseconds; the margin covers a loaded machine without letting a
  // lost write stay on screen for long.
  echoMs: 500,
  // How long after a `bank` the page's echo of it is still expected. Adopting
  // a bank is synchronous in the page, so the echo follows within one round
  // trip; this only bounds how long a missing one stays armed.
  adoptMs: 2000,
};

// Beyond this many changed parameters one `state` is sent instead of a run of
// `param`s. A knob drag, even two clients dragging at once, moves a handful;
// a patch change moves dozens, and one `state` repaints the panel once
// instead of once per parameter.
const PARAM_BURST = 8;

// Page requests allowed to wait behind a slow daemon. Past this the page is
// told and resynchronised rather than queued without bound.
const MAX_QUEUED = 256;

// What midi.current and midi.list answer on a daemon older than the MIDI
// selection, or on one with no MIDI input. Neither stops the page being kept
// in step, so neither closes it; the page is told there is nothing to choose.
const MIDI_UNAVAILABLE = new Set(["unknown_command", "daemon_not_ready"]);

// A MIDI input id is interpolated into a command, so it must be one token
// with nothing the daemon could read as a separator or a second line. Its
// own ids are short (hw:1,0, winmm:3); the bound keeps a runaway one an
// invalid payload rather than a command too long to frame.
const MIDI_ID = /^[^\s\x00-\x1f\x7f-\x9f]{1,256}$/;

// The daemon's registry, from parameter.list. Parameters it does not register
// (see src/registry/registry.odin) have no id and cannot be read or set.
async function readRegistry(daemon, params) {
  const list = await daemon.request("parameter.list");
  const registry = { ids: [], byId: new Map(), min: [], max: [], hidden: [] };
  for (const line of list.lines) {
    const f = {};
    for (const token of line.split(" ")) {
      if (token.startsWith("label=")) break;
      const eq = token.indexOf("=");
      if (eq > 0) f[token.slice(0, eq)] = token.slice(eq + 1);
    }
    const index = Number(f.index);
    // An id is interpolated into commands, so only the shape the registry
    // uses is accepted.
    if (!/^[a-z0-9_.]+$/.test(f.id || "") || !Number.isInteger(index) ||
        index < 0 || index >= params.count) continue;
    registry.ids[index] = f.id;
    registry.byId.set(f.id, index);
    registry.min[index] = Number(f.min);
    registry.max[index] = Number(f.max);
  }
  for (let i = 0; i < params.count; i++) {
    if (registry.ids[i] === undefined) registry.hidden.push(i);
  }
  return registry;
}

function isInt(v, lo, hi) {
  return Number.isInteger(v) && v >= lo && v <= hi;
}

function clamp(v, lo, hi) {
  return Math.min(hi, Math.max(lo, v));
}

class Session {
  constructor(ws, daemon, registry, options) {
    this.ws = ws;
    this.daemon = daemon;
    this.registry = registry;
    this.params = options.params;
    this.count = options.params.count;
    this.pollMs = options.pollMs || DEFAULTS.pollMs;
    this.echoMs = options.echoMs || DEFAULTS.echoMs;
    this.adoptMs = options.adoptMs || DEFAULTS.adoptMs;
    this.log = options.log || (() => {});
    this.onClose = options.onClose || (() => {});
    this.closed = false;
    this.done = new Promise(resolve => { this.resolveDone = resolve; });

    this.chain = Promise.resolve();
    this.queued = 0;
    this.polling = false;
    this.pollTimer = null;
    this.forceFull = false;
    this.tempDirs = new Set();

    // What the daemon last reported, for spotting what moved.
    this.revision = null;
    this.bankRev = null;
    this.identity = null;
    // midi_rev, or null once the daemon has said it has no MIDI selection to
    // offer. Only a new daemon, which is a new connection, could say anything
    // else, so it is then not polled; opening the page's input list still
    // asks.
    this.midiRev = undefined;
    // The bank last sent to or adopted from the page.
    this.model = null;
    // Values for the parameters the daemon does not expose. Only loading a
    // whole patch changes them. When the identity names a slot they are that
    // slot's; otherwise the last known ones stand, Init at first, which is
    // what a fresh daemon plays. A patch loaded from a file can leave them
    // wrong here, and nothing on the socket could say so.
    this.hidden = this.params.defaults.slice();
    // What the page is believed to show, null until it has been told.
    this.browser = null;
    // index -> {value, until}: this page's writes the daemon may not have
    // applied yet. See sendChanges.
    this.expect = new Map();
    // Banks sent whose echo (see adoptionEcho) has not come back yet.
    this.adoptions = [];

    ws.on("message", text => this.receive(text));
    ws.on("close", () => {
      this.close();
      this.resolveDone();
    });
    daemon.on("close", () => this.close(1011, "daemon connection lost"));
  }

  close(code = 1000, reason = "") {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
    this.daemon.close();
    this.ws.close(code, reason);
    for (const dir of [...this.tempDirs]) this.removeTemp(dir);
    this.expect.clear();
    this.adoptions = [];
    this.onClose(this);
  }

  send(msg) {
    if (!this.closed) this.ws.send(JSON.stringify(msg));
  }

  error(kind, code, message) {
    this.send({ type: "error", for: kind, code, message });
  }

  receive(text) {
    if (this.closed) return;
    let msg;
    try {
      msg = JSON.parse(text);
    } catch (err) {
      return this.error("", "invalid_payload", "message is not JSON");
    }
    if (!msg || typeof msg !== "object" || Array.isArray(msg) || typeof msg.type !== "string") {
      return this.error("", "invalid_payload", "message needs a string type");
    }
    try {
      this.dispatch(msg);
    } catch (err) {
      this.fault(err);
    }
  }

  dispatch(msg) {
    switch (msg.type) {
      case "sync": return this.run("sync", () => this.sync());
      case "set": return this.set(msg);
      case "state": return this.state(msg);
      // Gesture brackets are for hosts that record automation. The daemon
      // records none, so there is nothing to forward -- and nothing wrong
      // with the message, so no error either.
      case "edit": return undefined;
      case "note": return this.note(msg);
      case "wheel": return this.wheel(msg);
      case "cc": return this.cc(msg);
      case "volume": return this.volume(msg);
      case "bank": return this.adopt(msg);
      case "patch-step": return this.patchStep(msg);
      case "midi-select": return this.midiSelect(msg);
      // Asked when the page opens its input list, so a device plugged in
      // since the last one shows up.
      case "midi-list": return this.run("midi-list", () => this.sendMidi());
      default:
        return this.error(msg.type.length <= 32 ? msg.type : "", "unknown_command",
          "unknown message type");
    }
  }

  // Queue one daemon conversation behind the ones before it. The chain itself
  // never rejects, or one failure would skip every conversation after it.
  run(kind, fn) {
    if (this.closed) return Promise.resolve();
    if (this.queued >= MAX_QUEUED && kind !== "poll") {
      this.forceFull = true;
      this.error(kind, "daemon_not_ready", "too many requests waiting for the daemon");
      return Promise.resolve();
    }
    this.queued++;
    const done = () => { this.queued--; };
    this.chain = this.chain
      .then(() => (this.closed ? undefined : fn()))
      .catch(err => this.failed(kind, err))
      .then(done, done);
    return this.chain;
  }

  failed(kind, err) {
    if (this.closed) return;
    if (err instanceof ConnectionError) return this.close(1011, "daemon connection lost");
    if (err instanceof DaemonError) {
      this.error(kind, err.code, err.message);
      // Without these the page cannot be kept in step with the daemon, so a
      // refusal ends the session rather than leaving a page that looks live.
      if (kind === "sync" || kind === "poll") this.close(1011, `daemon refused ${err.command}`);
      return;
    }
    this.fault(err);
  }

  // A bug, not a daemon answer. Contained to this page.
  fault(err) {
    this.log(`browser session error: ${(err && err.stack) || err}`);
    this.close(1011, "adapter error");
  }

  // -- page -> daemon ---------------------------------------------------------

  set(msg) {
    const { index, value } = msg;
    if (!isInt(index, 0, this.count - 1) || !Number.isInteger(value)) {
      return this.reject("set", "invalid_payload", "set needs an integer index and value");
    }
    const id = this.registry.ids[index];
    if (id === undefined) {
      return this.reject("set", "unknown_parameter", `parameter ${index} is not exposed by the daemon`);
    }
    if (value < this.registry.min[index] || value > this.registry.max[index]) {
      return this.reject("set", "out_of_range", "value out of range");
    }
    this.expectValue(index, value);
    if (this.browser) this.browser[index] = value;
    this.run("set", () => this.write("set", `parameter.set ${id} ${value}`, [index]));
  }

  // A whole patch at once: stepping the bank, loading a file, or the page's
  // echo of a bank it was just sent.
  state(msg) {
    const values = msg.values;
    if (!Array.isArray(values) || !values.length || values.length > this.count ||
        !values.every(v => Number.isInteger(v))) {
      return this.reject("state", "invalid_payload", "state needs an array of integer values");
    }
    const ids = this.registry.ids;
    for (let i = 0; i < values.length; i++) {
      if (ids[i] !== undefined && (values[i] < this.registry.min[i] || values[i] > this.registry.max[i])) {
        return this.reject("state", "out_of_range", `value for parameter ${i} out of range`);
      }
    }
    if (this.adoptionEcho(values)) return;

    if (this.browser) values.forEach((v, i) => { this.browser[i] = v; });
    const indices = [];
    const pairs = [];
    values.forEach((v, i) => {
      if (ids[i] === undefined) return;
      indices.push(i);
      pairs.push(`${ids[i]} ${v}`);
      this.expectValue(i, v);
    });
    // Slot k's sound, sent by value, is loaded as slot k so the daemon
    // records which patch it is. A whole patch is a replacement, not a run of
    // edits: patch.load and patch.apply both make the audio thread reset the
    // previous patch's effect tails and smoothers, which a parameter.set_many
    // batch deliberately does not, so it must never be sent as one.
    const slot = values.length === this.count
      ? bank.findSlot(this.model, values, this.identity ? this.identity.slot : -1)
      : -1;
    if (slot >= 0) {
      this.run("state", () => this.write("state", `patch.load ${slot}`, indices));
      return;
    }
    if (!pairs.length) return;
    this.run("state", async () => {
      // A sound the bank does not hold has no name the daemon could record,
      // so the identity is cleared rather than left naming the one before.
      if (await this.write("state", `patch.apply ${pairs.join(" ")}`, indices)) {
        await this.daemon.request("patch.clear");
      }
    });
  }

  // The page's reply to a bank it was sent. Adopting a bank makes the panel
  // select slot 0 (Init when that is empty) and post it as a `state`; the bank
  // came from the daemon, so that post is not a request to change the
  // daemon's sound. Dropped once per bank sent, and only when it is exactly
  // that sound.
  adoptionEcho(values) {
    const now = Date.now();
    this.adoptions = this.adoptions.filter(a => a.until > now);
    const at = this.adoptions.findIndex(a => bank.sameValues(a.values, values));
    if (at < 0) return false;
    this.adoptions.splice(0, at + 1);
    return true;
  }

  note(msg) {
    const velocity = msg.velocity === undefined ? 100 : msg.velocity;
    const channel = msg.channel === undefined ? 0 : msg.channel;
    if (typeof msg.on !== "boolean" || !isInt(msg.note, 0, 127) ||
        !isInt(velocity, 0, 127) || !isInt(channel, 0, 15)) {
      return this.error("note", "invalid_payload",
        "note needs on, note 0..127, velocity 0..127 and channel 0..15");
    }
    const status = (msg.on ? 0x90 : 0x80) | channel;
    this.run("note", () => this.daemon.request(`midi ${status} ${msg.note} ${velocity}`));
  }

  wheel(msg) {
    const v = msg.value;
    if ((msg.which !== "pitch" && msg.which !== "mod") || typeof v !== "number" || !Number.isFinite(v)) {
      return this.error("wheel", "invalid_payload", "wheel needs which pitch|mod and a number");
    }
    let command;
    if (msg.which === "pitch") {
      // -1..1 onto the 14-bit bend, centre 8192: the inverse of ui/midi.js.
      const raw = clamp(Math.round((v + 1) * 8192), 0, 16383);
      command = `midi 224 ${raw & 127} ${raw >> 7}`;
    } else {
      // Controller 1, which is what parameters 86 and 88 name by default.
      command = `midi 176 1 ${clamp(Math.round(v * 127), 0, 127)}`;
    }
    this.run("wheel", () => this.daemon.request(command));
  }

  cc(msg) {
    if (!isInt(msg.cc, 0, 127) || !isInt(msg.value, 0, 127)) {
      return this.error("cc", "invalid_payload", "cc needs cc 0..127 and value 0..127");
    }
    this.run("cc", () => this.daemon.request(`midi 176 ${msg.cc} ${msg.value}`));
  }

  volume(msg) {
    const v = msg.value;
    if (typeof v !== "number" || !Number.isFinite(v)) {
      return this.error("volume", "invalid_payload", "volume needs a number 0..1");
    }
    const milli = Math.round(clamp(v, 0, 1) * 1000);
    this.run("volume", () => this.daemon.request(`volume ${milli}`));
  }

  adopt(msg) {
    if (typeof msg.text !== "string" || !msg.text) {
      return this.error("bank", "invalid_payload", "bank needs text");
    }
    // Absent means no, as in hosts/panel/panel.odin: adopting without saving
    // is the safe half.
    const save = msg.save === true;
    this.run("bank", () => this.adoptBank(msg.text, save));
  }

  patchStep(msg) {
    if (!Number.isInteger(msg.step) || msg.step === 0) {
      return this.error("patch-step", "invalid_payload", "patch-step needs a non-zero integer step");
    }
    this.run("patch-step", () => this.step(msg.step));
  }

  // Only a request. The page keeps no selection of its own and shows what
  // the `midi` sent back says, so a refusal needs no undoing there: it is
  // reported, and the page is sent the selection the daemon kept.
  midiSelect(msg) {
    if (typeof msg.id !== "string" || !MIDI_ID.test(msg.id)) {
      return this.error("midi-select", "invalid_payload", "midi-select needs all, none or an input id");
    }
    this.run("midi-select", async () => {
      try {
        await this.daemon.request(`midi.select ${msg.id}`);
      } catch (err) {
        if (!(err instanceof DaemonError)) throw err;
        this.error("midi-select", err.code, err.message);
      }
      await this.sendMidi();
    });
  }

  // A write the page has already painted. Refused, so the page is told and
  // put back to the daemon's values rather than left showing it.
  reject(kind, code, message) {
    this.error(kind, code, message);
    this.run(kind, () => this.resync());
  }

  expectValue(index, value) {
    this.expect.set(index, { value, until: Date.now() + this.echoMs });
  }

  // True when the daemon took it. A refusal is reported and the page is put
  // back to what the daemon actually holds.
  async write(kind, command, indices) {
    try {
      await this.daemon.request(command);
    } catch (err) {
      if (!(err instanceof DaemonError)) throw err;
      for (const i of indices) this.expect.delete(i);
      this.error(kind, err.code, err.message);
      await this.resync();
      return false;
    }
    // The deadline runs from acceptance, not from when the page sent it, so
    // time spent queued behind a slow poll does not eat into it.
    const until = Date.now() + this.echoMs;
    for (const i of indices) {
      const e = this.expect.get(i);
      if (e) e.until = Math.max(e.until, until);
    }
    return true;
  }

  async adoptBank(text, save) {
    let model = null;
    try {
      model = bank.parseBank(text, this.params);
    } catch (err) {
      // The daemon decides whether it is a bank; this only loses matching.
    }
    const slot = bank.storedSlot(this.model, model, this.browser, this.registry.hidden);
    let answer;
    try {
      answer = slot >= 0
        ? await this.daemon.request(`patch.save ${slot} ${model.slots[slot].raw.trim()}`)
        : await this.loadBank(text);
    } catch (err) {
      if (!(err instanceof DaemonError)) throw err;
      this.error("bank", err.code, err.message);
      // The page is showing a bank the daemon refused; forgetting the
      // generation makes the next poll send it the daemon's own.
      this.bankRev = null;
      return;
    }
    this.model = model;
    // The page already has this bank; counting its generation as seen keeps
    // the next poll from sending it straight back. Other pages see bank_rev
    // move and are sent it.
    const rev = answer.int("bank_rev");
    if (rev !== undefined) this.bankRev = rev;
    if (save) await this.daemon.request("bank.keep");
  }

  async loadBank(text) {
    const dir = this.makeTemp();
    try {
      const file = path.join(dir, "bank.json");
      fs.writeFileSync(file, text, { mode: 0o600, flag: "wx" });
      return await this.daemon.request(`bank.load_file ${file}`);
    } finally {
      this.removeTemp(dir);
    }
  }

  async step(by) {
    const list = await this.daemon.request("bank.list");
    const filled = [];
    for (const line of list.lines) {
      const m = /^slot=(\d+) filled=([01])(?: |$)/.exec(line);
      if (m && m[2] === "1") filled.push(Number(m[1]));
    }
    filled.sort((a, b) => a - b);
    if (!filled.length) {
      this.error("patch-step", "empty_bank", "the bank has no patches to step to");
      return;
    }
    const { slot } = await this.current();
    const n = filled.length;
    // The first step lands on the nearest filled slot in that direction,
    // wherever the daemon is (an empty slot, or none); the rest walk filled
    // slots only, wrapping round the bank.
    let pos;
    if (by > 0) {
      pos = filled.findIndex(k => k > slot);
      if (pos < 0) pos = 0;
      pos += by - 1;
    } else {
      pos = filled.findLastIndex(k => k < slot);
      if (pos < 0) pos = n - 1;
      pos += by + 1;
    }
    await this.daemon.request(`patch.load ${filled[((pos % n) + n) % n]}`);
  }

  // -- daemon -> page ---------------------------------------------------------

  async sync() {
    const current = await this.current();
    await this.sendBank(current.bankRev);
    const snap = await this.snapshot(current.slot);
    this.forceFull = false;
    this.sendState(snap.values);
    this.revision = snap.revision;
    this.sendIdentity(current);
    await this.sendMidi();
    if (!this.polling) {
      this.polling = true;
      this.schedule();
    }
  }

  // Never overlapping, and never piling up: the next poll is only armed once
  // this one has finished, however long the daemon took.
  schedule() {
    if (this.closed) return;
    this.pollTimer = setTimeout(() => {
      this.pollTimer = null;
      this.run("poll", () => this.tick()).then(() => this.schedule());
    }, this.pollMs);
  }

  // One patch.current per tick says what moved. Bank first, because adopting
  // it makes the page load slot 0; the daemon's values go over that; the
  // identity goes last so it names what is now on screen. The MIDI selection
  // is apart from all three and has its own generation, midi_rev.
  async tick() {
    const current = await this.current();
    const bankMoved = current.bankRev !== this.bankRev;
    const idMoved = !this.identity || current.slot !== this.identity.slot ||
      current.bank !== this.identity.bank || current.name !== this.identity.name;
    if (bankMoved) await this.sendBank(current.bankRev);
    const full = bankMoved || this.forceFull;
    if (full || idMoved || current.revision !== this.revision || this.anyExpired()) {
      const snap = await this.snapshot(current.slot);
      if (full) {
        this.forceFull = false;
        this.sendState(snap.values);
      } else {
        this.sendChanges(snap.values);
      }
      this.revision = snap.revision;
    }
    if (bankMoved || idMoved) this.sendIdentity(current);
    if (this.midiRev !== null) {
      const midi = await this.midiCurrent();
      if (!midi || midi.rev !== this.midiRev) await this.sendMidi(midi);
    }
  }

  async resync() {
    const snap = await this.snapshot(this.identity ? this.identity.slot : -1);
    this.sendState(snap.values);
    this.revision = snap.revision;
  }

  async current() {
    const r = await this.daemon.request("patch.current");
    const slot = r.int("slot");
    const bankRev = r.int("bank_rev");
    const revision = r.int("revision");
    if (slot === undefined || bankRev === undefined || revision === undefined) {
      throw new ConnectionError("malformed patch.current answer");
    }
    let label, name;
    for (const line of r.lines) {
      if (label === undefined && line.startsWith("bank=")) label = line.slice(5);
      else if (name === undefined && line.startsWith("name=")) name = line.slice(5);
    }
    return { slot, bankRev, revision, bank: label || "", name: name || "" };
  }

  async snapshot(slot) {
    const r = await this.daemon.request("state.snapshot");
    const revision = r.int("revision");
    if (revision === undefined) throw new ConnectionError("malformed state.snapshot answer");
    const known = slot >= 0 && this.model ? this.model.slots[slot] : null;
    if (known) for (const i of this.registry.hidden) this.hidden[i] = known.values[i];
    const values = this.hidden.slice();
    for (const line of r.lines) {
      const m = /^id=(\S+) value=(-?\d+)$/.exec(line);
      const i = m ? this.registry.byId.get(m[1]) : undefined;
      if (i !== undefined) values[i] = Number(m[2]);
    }
    return { revision, values };
  }

  async sendBank(bankRev) {
    const text = await this.dumpBank();
    let model = null;
    try {
      model = bank.parseBank(text, this.params);
    } catch (err) {
      // A document the page will refuse too: nothing to match, no echo due.
    }
    this.model = model;
    this.bankRev = bankRev;
    this.send({ type: "bank", text });
    if (model) {
      this.adoptions.push({
        values: bank.adoptionValues(model, this.params),
        until: Date.now() + this.adoptMs,
      });
    }
  }

  async dumpBank() {
    const dir = this.makeTemp();
    try {
      const file = path.join(dir, "bank.json");
      await this.daemon.request(`bank.write ${file}`);
      return fs.readFileSync(file, "utf8");
    } finally {
      this.removeTemp(dir);
    }
  }

  // The whole set. Writes still in flight keep the page's value: the daemon's
  // is older, and sending it would flick the control back and forth.
  sendState(values) {
    const now = Date.now();
    const out = values.slice();
    for (const [i, e] of this.expect) {
      if (values[i] === e.value || now >= e.until) this.expect.delete(i);
      else out[i] = e.value;
    }
    this.browser = out;
    this.send({ type: "state", values: out });
  }

  // Only what differs from what the page shows. A parameter this page wrote
  // is left alone until the daemon reports that value (the audio thread has
  // applied it) or the deadline passes; after that the daemon wins, whatever
  // it says, because a write can be overtaken by another client's.
  sendChanges(values) {
    if (!this.browser) return this.sendState(values);
    const now = Date.now();
    const changed = [];
    for (let i = 0; i < values.length; i++) {
      const e = this.expect.get(i);
      if (e) {
        if (values[i] !== e.value && now < e.until) continue;
        this.expect.delete(i);
      }
      if (values[i] !== this.browser[i]) changed.push(i);
    }
    if (changed.length > PARAM_BURST) return this.sendState(values);
    for (const i of changed) {
      this.browser[i] = values[i];
      this.send({ type: "param", index: i, value: values[i] });
    }
    return undefined;
  }

  anyExpired() {
    const now = Date.now();
    for (const e of this.expect.values()) if (now >= e.until) return true;
    return false;
  }

  // The panel ignores a patch message with an empty name, so a daemon that
  // has none (fresh, or after patch.clear) would leave it showing whatever
  // the bank it just adopted selected. "Untitled" is the panel's own name for
  // a sound nobody named. What is cached stays the daemon's own word, or the
  // next poll would see a change that is not there.
  sendIdentity(current) {
    this.identity = { slot: current.slot, bank: current.bank, name: current.name };
    this.send({
      type: "patch",
      name: current.name || "Untitled",
      index: current.slot >= 0 ? current.slot : null,
      bank: current.bank,
    });
  }

  // The selection, its generation and its display name come from one
  // midi.current, so they always agree; the inputs from a fresh midi.list,
  // because a device can be plugged in or out without the selection moving.
  async sendMidi(midi) {
    if (midi === undefined) midi = await this.midiCurrent();
    const inputs = midi ? await this.midiInputs() : null;
    if (!inputs) {
      this.midiRev = null;
      this.send({ type: "midi", inputs: [], selected: null, name: null, rev: null });
      return;
    }
    this.midiRev = midi.rev;
    this.send({ type: "midi", inputs, selected: midi.selected, name: midi.name, rev: midi.rev });
  }

  async midiCurrent() {
    const r = await this.midiRequest("midi.current");
    if (!r) return null;
    const rev = r.int("midi_rev");
    const selected = r.field("selected");
    if (rev === undefined || !selected) throw new ConnectionError("malformed midi.current answer");
    const line = r.lines.find(l => l.startsWith("name="));
    return { rev, selected, name: line === undefined ? "" : line.slice(5) };
  }

  async midiInputs() {
    const r = await this.midiRequest("midi.list");
    if (!r) return null;
    const inputs = [];
    for (const line of r.lines) {
      // s: `.` alone stops at U+2028 and U+2029, which a name may hold.
      const m = /^id=(\S+) name=(.*)$/s.exec(line);
      if (m) inputs.push({ id: m[1], name: m[2] });
    }
    return inputs;
  }

  // Null when the daemon has no selection to offer. Anything else it refuses
  // is handled like a refused patch.current.
  async midiRequest(command) {
    try {
      return await this.daemon.request(command);
    } catch (err) {
      if (err instanceof DaemonError && MIDI_UNAVAILABLE.has(err.code)) return null;
      throw err;
    }
  }

  // A private directory per file handed to the daemon, so nothing else on the
  // machine can read or swap the bank in the moment between the two.
  makeTemp() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "quesynth-bridge-"));
    this.tempDirs.add(dir);
    fs.chmodSync(dir, 0o700);
    if (/[\r\n]/.test(dir)) throw new Error("temporary directory path spans lines");
    return dir;
  }

  removeTemp(dir) {
    this.tempDirs.delete(dir);
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch (err) {
      this.log(`cannot remove ${dir}: ${err.message}`);
    }
  }
}

module.exports = { Session, readRegistry };
