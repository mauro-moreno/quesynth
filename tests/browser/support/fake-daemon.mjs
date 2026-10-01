// A stand-in for the quesynth daemon's control socket, for testing the browser
// adapter without audio hardware.
//
// It speaks the real framing and envelope (src/control), answers the commands
// hosts/standalone answers, with the same response shapes and error codes, and
// keeps the same state: an engine the "audio thread" publishes into a snapshot
// with a revision, a 128-slot bank with its generation (bank_rev), the patch
// identity, master volume, a MIDI queue and the selected native MIDI input
// with its generation (midi_rev). Edits are queued like the param ring and
// only reach the snapshot when applied, so tests can hold them back and model
// audio-thread latency.
//
// The parameter ids are the real registry's, read out of
// src/registry/registry.odin; defaults come from ui/params.js. Stored ranges
// are an approximation (the widest of 0..127, the default and the table's
// stored values), which is enough to exercise the adapter's range handling.

import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import vm from "node:vm";
import {fileURLToPath} from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
export const SLOTS = 128;
const MAX_FRAME = 64 * 1024;
const NAME_MAX = 48;
const TXN_MAX = 128;

export function loadTables() {
  const sandbox = {window: {}};
  vm.runInNewContext(fs.readFileSync(path.join(ROOT, "ui", "params.js"), "utf8"), sandbox);
  const params = Array.from(sandbox.window.SYNTH1_PARAMS).map(p => {
    const stored = p.s ? Array.from(p.s) : [];
    return {
      index: p.i,
      name: p.name,
      def: p.def,
      min: Math.min(0, p.def, ...stored),
      max: Math.max(127, p.n - 1, p.def, ...stored),
    };
  });
  const source = fs.readFileSync(path.join(ROOT, "src", "registry", "registry.odin"), "utf8");
  const registry = [];
  for (const m of source.matchAll(/^\s*\{"([a-z0-9_.]+)", "([^"]*)", "([a-z0-9_]+)", (\d+),/gm)) {
    registry.push({id: m[1], label: m[2], group: m[3], index: Number(m[4])});
  }
  return {params, registry};
}

const TABLES = loadTables();
export const PARAMS = TABLES.params;
export const REGISTRY = TABLES.registry;
export const DEFAULTS = PARAMS.map(p => p.def);

// control_write_token in bank_handler.odin.
function token(s) {
  let out = "";
  for (const ch of s) out += ch === " " ? "_" : ch.codePointAt(0) < 128 ? ch : "?";
  return out;
}

function truncate(s) {
  const bytes = Buffer.from(s, "utf8");
  return bytes.length <= NAME_MAX ? s : bytes.subarray(0, NAME_MAX).toString("utf8");
}

// json_escape in src/patch/json.odin.
function escape(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\r") out += "\\r";
    else if (c < 0x20) out += "\\u" + c.toString(16).padStart(4, "0");
    else out += ch;
  }
  return out + '"';
}

// slots_write_json in src/patch/slots.odin, byte for byte (checked against a
// document the Odin writer produced in bank.test.mjs).
export function writeBank(bank) {
  let last = -1;
  bank.slots.forEach((s, i) => { if (s) last = i; });
  let out = `{\n  "format": "quesynth.bank",\n  "version": 1,\n  "name": ${escape(bank.label)},\n  "patches": [\n`;
  for (let i = 0; i <= last; i++) {
    const s = bank.slots[i];
    if (!s) {
      out += "    null";
    } else {
      const indent = "      ";
      out += "    {\n";
      out += `${indent}"name": ${escape((s.name || "Init").trim())},\n${indent}"parameters": {\n`;
      PARAMS.forEach((p, j) => {
        out += `${indent}  ${escape(p.name)}: ${s.values[j]}${j + 1 < PARAMS.length ? "," : ""}\n`;
      });
      out += `${indent}}\n    }`;
    }
    out += i + 1 <= last ? ",\n" : "\n";
  }
  return out + "  ]\n}\n";
}

// parse_bank_json + slots_load: what bank.load_file accepts and what it makes.
export function readBank(text) {
  const doc = JSON.parse(text);
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) throw new Error("not an object");
  if (doc.format !== "quesynth.bank") throw new Error("wrong format");
  if ("version" in doc && (!Number.isInteger(doc.version) || doc.version > 1)) throw new Error("version");
  if (!Array.isArray(doc.patches)) throw new Error("no patches");
  const byName = new Map(PARAMS.map(p => [p.name, p.index]));
  const slots = new Array(SLOTS).fill(null);
  doc.patches.forEach((entry, i) => {
    if (entry === null) return;
    if (typeof entry !== "object" || Array.isArray(entry)) throw new Error("entry not an object");
    const values = DEFAULTS.slice();
    if ("parameters" in entry) {
      const table = entry.parameters;
      if (!table || typeof table !== "object" || Array.isArray(table)) throw new Error("parameters");
      for (const [key, value] of Object.entries(table)) {
        if (!byName.has(key)) throw new Error(`unknown parameter ${key}`);
        if (!Number.isInteger(value)) throw new Error("bad value");
        values[byName.get(key)] = value;
      }
    }
    if (i < SLOTS) slots[i] = {name: truncate(typeof entry.name === "string" ? entry.name : ""), values};
  });
  const label = typeof doc.name === "string" && doc.name !== "" ? doc.name : "Bank";
  return {label: truncate(label), slots};
}

export const FIXTURE = fs.readFileSync(path.join(ROOT, "tests", "browser", "fixtures", "odin-bank.json"), "utf8");

function frame(text) {
  const body = Buffer.from(text, "utf8");
  const out = Buffer.alloc(4 + body.length);
  out.writeUInt32LE(body.length, 0);
  body.copy(out, 4);
  return out;
}

export class FakeDaemon {
  constructor({socketPath, keepPath, bankText = FIXTURE, maxConnections = 16, midiInputs = []} = {}) {
    this.socketPath = socketPath;
    this.keepPath = keepPath;
    this.maxConnections = maxConnections;
    this.server = null;
    this.connections = new Set();
    this.refused = 0;
    this.nextConn = 1;

    this.engine = DEFAULTS.slice();
    this.published = {revision: 0, values: DEFAULTS.slice()};
    this.queue = [];
    // "auto" applies each edit as soon as it is queued, as an idle audio
    // thread effectively does; "manual" waits for apply().
    this.applyMode = "auto";
    this.identity = {slot: -1, bank: "", name: ""};
    this.bankRev = 0;
    this.volume = 1000;
    this.midi = [];
    this.log = [];
    // What midi.list enumerates, fresh on every call, so a test changing it
    // is a device plugged in or out; null is a daemon with no MIDI backend.
    // An input with `fails: true` cannot be opened. The selection starts as
    // `all`, every input open, which is not a change: midi_rev starts at 0.
    this.midiInputs = midiInputs;
    this.midiSelected = "all";
    this.midiName = "All inputs";
    this.midiRev = 0;
    this.bank = readBank(bankText);
    // request -> undefined | {err: [code, message]} | {answer: "ok ..."} |
    // "hang" | "garbage" | "oversize" | "drop"
    this.intercept = null;
  }

  start() {
    return new Promise((resolve, reject) => {
      this.server = net.createServer(socket => this.accept(socket));
      this.server.once("error", reject);
      this.server.listen(this.socketPath, () => {
        this.server.removeListener("error", reject);
        resolve();
      });
    });
  }

  // Everything goes, including every client connection, like a killed daemon.
  stop() {
    for (const socket of this.connections) socket.destroy();
    this.connections.clear();
    const server = this.server;
    this.server = null;
    if (!server) return Promise.resolve();
    return new Promise(resolve => server.close(() => resolve()));
  }

  accept(socket) {
    socket.on("error", () => {});
    if (this.connections.size >= this.maxConnections) {
      // control_server.odin accepts and immediately closes past its limit.
      this.refused++;
      socket.destroy();
      return;
    }
    socket.conn = this.nextConn++;
    this.connections.add(socket);
    let buffer = Buffer.alloc(0);
    socket.on("close", () => this.connections.delete(socket));
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const n = buffer.readUInt32LE(0);
        if (n > MAX_FRAME) return socket.destroy();
        if (buffer.length < 4 + n) return undefined;
        const payload = buffer.subarray(4, 4 + n).toString("utf8");
        buffer = buffer.subarray(4 + n);
        this.serve(socket, payload);
      }
      return undefined;
    });
  }

  serve(socket, payload) {
    const line = payload.split("\n")[0];
    const tokens = line.split(" ").filter(Boolean);
    const version = Number(tokens[0]);
    const id = Number(tokens[1]);
    if (!/^-?\d+$/.test(tokens[0] || "") || !/^-?\d+$/.test(tokens[1] || "") || !tokens[2]) {
      socket.write(frame("1 0 err invalid_payload malformed request"));
      return;
    }
    const command = tokens[2];
    const rest = line.slice(line.indexOf(command) + command.length).trim();
    const req = {version, id, command, operands: tokens.slice(3, 7), rest, conn: socket.conn};
    this.log.push({conn: socket.conn, line: rest ? `${command} ${rest}` : command});

    const special = this.intercept ? this.intercept(req) : undefined;
    if (special === "hang") return;
    if (special === "drop") return void socket.destroy();
    if (special === "garbage") return void socket.write(frame("this is not an envelope"));
    if (special === "oversize") {
      const header = Buffer.alloc(4);
      header.writeUInt32LE(MAX_FRAME + 1, 0);
      return void socket.write(header);
    }
    let answer;
    if (special && special.err) {
      answer = `err ${special.err[0]} ${special.err[1]}`;
    } else if (special && special.answer) {
      answer = special.answer;
    } else if (version !== 1) {
      answer = "err unsupported_version unsupported protocol version";
    } else {
      answer = this.handle(req);
    }
    socket.write(frame(`1 ${id} ${answer}`));
    if (this.applyMode === "auto") this.apply();
  }

  // The audio thread draining the ring: each committed batch lands at once
  // and moves the revision by one.
  apply(batches = Infinity) {
    let n = 0;
    while (this.queue.length && n < batches) {
      for (const [index, value] of this.queue.shift()) this.engine[index] = value;
      this.published = {revision: this.published.revision + 1, values: this.engine.slice()};
      n++;
    }
    return n;
  }

  commands(verb) {
    return this.log.map(e => e.line).filter(l => !verb || l.split(" ")[0] === verb);
  }

  slotName(k) {
    const s = this.bank.slots[k];
    return s && s.name ? s.name : "Init";
  }

  // The id/value pairs of a set_many or patch.apply, validated as the daemon
  // does: the pairs, or the error answer as a string.
  pairs(req, name) {
    const describe = id => REGISTRY.find(d => d.id === id);
    const int = text => (/^[-+]?\d+$/.test(text || "") ? Number(text) : NaN);
    const t = req.rest.split(/\s+/).filter(Boolean);
    if (!t.length || t.length % 2) return `err invalid_payload ${name} needs id value pairs`;
    if (t.length / 2 > TXN_MAX) return "err transaction_failed too many parameters in one transaction";
    const batch = [];
    for (let i = 0; i < t.length; i += 2) {
      const value = int(t[i + 1]);
      if (Number.isNaN(value)) return "err invalid_payload value is not an integer";
      const d = describe(t[i]);
      if (!d) return "err unknown_parameter no such parameter";
      const p = PARAMS[d.index];
      if (value < p.min || value > p.max) return "err out_of_range value out of range";
      batch.push([d.index, value]);
    }
    return batch;
  }

  handle(req) {
    const describe = id => REGISTRY.find(d => d.id === id);
    const int = text => (/^[-+]?\d+$/.test(text || "") ? Number(text) : NaN);
    switch (req.command) {
      case "daemon.status":
        return `ok state=running proto=1 revision=${this.published.revision}`;
      case "parameter.list":
        return `ok count=${REGISTRY.length}` + REGISTRY.map(d => {
          const p = PARAMS[d.index];
          return `\nid=${d.id} group=${d.group} index=${d.index} min=${p.min} max=${p.max}` +
            ` default=${p.def} label=${d.label}`;
        }).join("");
      case "parameter.get": {
        const d = describe(req.operands[0]);
        if (!req.operands.length) return "err invalid_payload get needs a parameter id";
        if (!d) return "err unknown_parameter no such parameter";
        return `ok value=${this.published.values[d.index]} revision=${this.published.revision}`;
      }
      case "parameter.set": {
        if (req.operands.length < 2) return "err invalid_payload set needs an id and a value";
        const value = int(req.operands[1]);
        if (Number.isNaN(value)) return "err invalid_payload value is not an integer";
        const d = describe(req.operands[0]);
        if (!d) return "err unknown_parameter no such parameter";
        const p = PARAMS[d.index];
        if (value < p.min || value > p.max) return "err out_of_range value out of range";
        this.queue.push([[d.index, value]]);
        return `ok value=${value} revision=${this.published.revision}`;
      }
      case "parameter.set_many": {
        const batch = this.pairs(req, "set_many");
        if (typeof batch === "string") return batch;
        this.queue.push(batch);
        return `ok count=${batch.length} revision=${this.published.revision}`;
      }
      // A whole patch: the same grammar and validation as set_many, and the
      // same queued batch here -- the difference the real daemon makes (the
      // audio thread resets effect memory and smoothers) is not modelled, only
      // that it is a different command. The identity is left alone.
      case "patch.apply": {
        const batch = this.pairs(req, "apply");
        if (typeof batch === "string") return batch;
        this.queue.push(batch);
        return `ok count=${batch.length} revision=${this.published.revision}`;
      }
      case "state.snapshot":
        return `ok revision=${this.published.revision} sample_rate=48000 buffer=256 count=${REGISTRY.length}` +
          REGISTRY.map(d => `\nid=${d.id} value=${this.published.values[d.index]}`).join("");
      case "midi": {
        if (req.operands.length < 3) return "err invalid_payload midi needs status data1 data2";
        const [s, a, b] = req.operands.slice(0, 3).map(int);
        if ([s, a, b].some(Number.isNaN) || s < 0 || s > 255 || a < 0 || a > 127 || b < 0 || b > 127) {
          return "err invalid_payload invalid midi bytes";
        }
        this.midi.push([s, a, b]);
        return "ok";
      }
      case "volume": {
        const v = int(req.operands[0]);
        if (Number.isNaN(v) || v < 0 || v > 1000) return "err invalid_payload volume needs 0..1000";
        this.volume = v;
        return `ok volume=${v}`;
      }
      case "bank.list": {
        const count = this.bank.slots.filter(Boolean).length;
        return `ok label=${token(this.bank.label)} count=${count} slots=${SLOTS}` +
          this.bank.slots.map((s, i) => `\nslot=${i} filled=${s ? 1 : 0} name=${token(this.slotName(i))}`).join("");
      }
      case "patch.load": {
        if (!req.operands.length) return "err invalid_payload load needs a slot number";
        const k = int(req.operands[0]);
        if (Number.isNaN(k) || k < 0 || k >= SLOTS) return "err invalid_payload slot out of range";
        const s = this.bank.slots[k];
        if (!s) return "err unknown_parameter slot is empty";
        this.queue.push(s.values.map((v, i) => [i, v]));
        this.identity = {slot: k, bank: this.bank.label, name: this.slotName(k)};
        return `ok slot=${k} name=${token(this.slotName(k))} count=${PARAMS.length}` +
          ` revision=${this.published.revision}`;
      }
      case "patch.save": {
        if (!req.operands.length) return "err invalid_payload save needs a slot number";
        const k = int(req.operands[0]);
        if (Number.isNaN(k) || k < 0 || k >= SLOTS) return "err invalid_payload slot out of range";
        const space = req.rest.indexOf(" ");
        const name = space < 0 ? "" : req.rest.slice(space + 1).trim();
        const final = truncate(name || this.slotName(k));
        this.bank.slots[k] = {name: final, values: this.published.values.slice()};
        this.bankRev++;
        this.identity = {slot: k, bank: this.bank.label, name: final};
        return `ok slot=${k} name=${token(final)} bank_rev=${this.bankRev}`;
      }
      case "bank.write": {
        if (!req.rest) return "err invalid_payload write needs a path";
        const text = writeBank(this.bank);
        try {
          fs.writeFileSync(req.rest, text);
        } catch (err) {
          return "err internal_error cannot write file";
        }
        return `ok bytes=${Buffer.byteLength(text)}`;
      }
      case "bank.load_file": {
        if (!req.rest) return "err invalid_payload load needs a path";
        try {
          this.bank = readBank(fs.readFileSync(req.rest, "utf8"));
        } catch (err) {
          return "err invalid_payload cannot read or parse bank";
        }
        this.bankRev++;
        this.identity = {...this.identity, slot: -1};
        const count = this.bank.slots.filter(Boolean).length;
        return `ok label=${token(this.bank.label)} count=${count} bank_rev=${this.bankRev}`;
      }
      case "bank.keep": {
        if (!this.keepPath) return "err internal_error no config directory";
        const text = writeBank(this.bank);
        try {
          fs.mkdirSync(path.dirname(this.keepPath), {recursive: true});
          fs.writeFileSync(`${this.keepPath}.tmp`, text);
          fs.renameSync(`${this.keepPath}.tmp`, this.keepPath);
        } catch (err) {
          return "err internal_error cannot write file";
        }
        return `ok bytes=${Buffer.byteLength(text)} path=${this.keepPath}`;
      }
      case "patch.current":
        return `ok slot=${this.identity.slot} bank_rev=${this.bankRev} revision=${this.published.revision}` +
          `\nbank=${this.identity.bank}\nname=${this.identity.name}`;
      case "patch.clear":
        this.identity = {slot: -1, bank: "", name: ""};
        return "ok";
      case "midi.list":
        if (!this.midiInputs) return "err daemon_not_ready no midi input";
        return `ok count=${this.midiInputs.length} selected=${this.midiSelected} midi_rev=${this.midiRev}` +
          this.midiInputs.map(d => `\nid=${d.id} name=${d.name}`).join("");
      case "midi.select": {
        if (!this.midiInputs) return "err daemon_not_ready no midi input";
        const t = req.rest.split(" ").filter(Boolean);
        if (t.length !== 1) return "err invalid_payload midi.select needs all, none or an input id";
        // Selecting what is already selected reopens nothing and is not a
        // change, even for a device that has since been unplugged.
        if (t[0] !== this.midiSelected) {
          let name = t[0] === "all" ? "All inputs" : t[0] === "none" ? "None" : null;
          if (name === null) {
            const d = this.midiInputs.find(i => i.id === t[0]);
            if (!d) return "err invalid_payload no such midi input";
            if (d.fails) return "err internal_error cannot open midi input";
            name = d.name;
          }
          this.midiSelected = t[0];
          this.midiName = name;
          this.midiRev++;
        }
        return `ok selected=${this.midiSelected} midi_rev=${this.midiRev}`;
      }
      case "midi.current":
        if (!this.midiInputs) return "err daemon_not_ready no midi input";
        return `ok selected=${this.midiSelected} midi_rev=${this.midiRev}\nname=${this.midiName}`;
      default:
        return "err unknown_command unknown command";
    }
  }
}

// A second client on the daemon's socket, as the TUI would be: one request at
// a time, answers matched by order.
export function connectRaw(socketPath) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let buffer = Buffer.alloc(0);
    let next = 1;
    const waiting = [];
    socket.on("data", chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
        const n = buffer.readUInt32LE(0);
        const text = buffer.subarray(4, 4 + n).toString("utf8");
        buffer = buffer.subarray(4 + n);
        waiting.shift()(text);
      }
    });
    socket.once("error", reject);
    socket.once("connect", () => resolve({
      request(line) {
        return new Promise(done => {
          waiting.push(done);
          socket.write(frame(`1 ${next++} ${line}`));
        });
      },
      close() { socket.destroy(); },
    }));
  });
}
