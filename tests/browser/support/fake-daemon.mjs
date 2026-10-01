// A stand-in for the quesynth daemon's control socket, for testing the browser
// adapter without audio hardware.
//
// It speaks the real framing and envelope (src/control), answers the commands
// hosts/standalone answers, with the same response shapes and error codes, and
// keeps the same state: an engine the "audio thread" publishes into a snapshot
// with a revision, a 128-slot bank with its generation (bank_rev), the patch
// identity and where it came from, master volume, a MIDI queue, the selected
// native MIDI input with its generation (midi_rev), and a patch archive with
// its open bank, remembered path and generation (archive_rev). Edits are
// queued like the param ring and only reach the snapshot when applied, so
// tests can hold them back and model audio-thread latency.
//
// The parameter ids are the real registry's, read out of
// src/registry/registry.odin; defaults come from ui/params.js. Stored ranges
// are an approximation (the widest of 0..127, the default and the table's
// stored values), which is enough to exercise the adapter's range handling.
//
// The archive is held in memory -- banks of named patches, under the paths
// archive.open accepts -- rather than read from a zip, because what the
// adapter depends on is the protocol around it (hosts/standalone/archive.odin
// and identity.odin), not the inflating.

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

// identity_put in identity.odin: a line break would end the record line it
// travels on.
function identityText(s) {
  return truncate(s).replace(/[\r\n]/g, " ");
}

// One patch of a stand-in archive: its name as archive.patches lists it, and
// values a load applies that differ per bank and patch, so a test can tell
// which one landed.
export function archivePatch(bank, patch, name) {
  const values = DEFAULTS.slice();
  values[19] = (17 + 29 * bank + 5 * patch) % 128;
  values[20] = (3 + 7 * bank + 11 * patch) % 128;
  return {name, values};
}

// [[bank name, [patch name, ...]], ...] as archive banks, in archive order.
export function makeArchive(banks) {
  return banks.map(([name, patches], b) => ({name, patches: patches.map((p, i) => archivePatch(b, i, p))}));
}

// Spaces in the path and in the names, because both travel raw to the end of
// a record line and a client that split on them would lose half.
export const ARCHIVE_PATH = "/srv/quesynth/patch banks.zip";
export const ARCHIVE = makeArchive([
  ["aaa bbb Thanks Ms Ichiro 01.zip",
    ["05_fx", "miniPoli_01", "  Spaced  Lead ", "Bells", "Organ", "Brass", "Sweep", "Last One"]],
  ["bankB.zip", ["Pad 2", "Bass", "Keys"]],
  ["empty.zip", []],
]);

// Digits only, as parse_index in archive.odin reads an index.
function archiveIndex(text) {
  return /^\d+$/.test(text || "") ? Number(text) : null;
}

// paged_range in archive.odin: a missing or unreadable operand takes its
// default, and the page is clamped to what there is.
function paged(req, total) {
  const off = archiveIndex(req.operands[0]);
  const cnt = archiveIndex(req.operands[1]);
  const offset = Math.min(Math.max(off === null ? 0 : off, 0), total);
  const count = Math.min(Math.min(cnt === null ? 64 : cnt, 256), total - offset);
  return [offset, count];
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
  constructor({
    socketPath, keepPath, bankText = FIXTURE, maxConnections = 16, midiInputs = [],
    archives = {[ARCHIVE_PATH]: ARCHIVE}, archivePath = "", legacy = false, keepFails = false,
  } = {}) {
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
    this.identity = {slot: -1, bank: "", name: "", source: "none", archiveBank: -1, archivePatch: -1};
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
    // The archives archive.open can open, path -> banks; null is a daemon with
    // no archive support (a bare handler), whose archive verbs refuse.
    this.archives = archives;
    // A daemon from before archives were shared: patch.current carries none
    // of the fields after revision, and its archive verbs are the older ones
    // (handleOldArchive).
    this.legacy = legacy;
    // The daemon cannot write or remove the file that keeps the archive path:
    // archive.open of a path, an adopting archive.adopt and archive.close then
    // answer as archive.odin does and change nothing.
    this.keepFails = keepFails;
    // The open archive (banks, or null), its open bank, the path it
    // remembers and archive_rev. archivePath is what a previous run kept: it
    // is remembered, and opened if it can be, without counting as a change.
    this.archive = {banks: null, bank: -1, path: "", rev: 0};
    if (archives && archivePath) {
      this.archive.path = archivePath;
      if (Object.hasOwn(archives, archivePath)) this.archive.banks = archives[archivePath];
    }
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
        this.identity = {slot: k, bank: this.bank.label, name: this.slotName(k), source: "bank",
          archiveBank: -1, archivePatch: -1};
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
        this.identity = {slot: k, bank: this.bank.label, name: final, source: "bank",
          archiveBank: -1, archivePatch: -1};
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
      case "patch.current": {
        const id = this.identity;
        let answer = `ok slot=${id.slot} bank_rev=${this.bankRev} revision=${this.published.revision}`;
        if (!this.legacy) {
          const archived = id.source === "archive";
          answer += ` source=${id.source} archive_rev=${this.archives ? this.archive.rev : 0}` +
            ` archive_bank=${archived ? id.archiveBank : -1} archive_patch=${archived ? id.archivePatch : -1}`;
        }
        return answer + `\nbank=${id.bank}\nname=${id.name}`;
      }
      case "patch.clear":
        this.identity = {slot: -1, bank: "", name: "", source: "none", archiveBank: -1, archivePatch: -1};
        return "ok";
      case "archive.current":
      case "archive.open":
      case "archive.adopt":
      case "archive.banks":
      case "archive.bank":
      case "archive.patches":
      case "archive.load":
      case "archive.close":
        return this.legacy ? this.handleOldArchive(req) : this.handleArchive(req);
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

  // The archive verbs, as archive.odin answers them, refusals included.
  handleArchive(req) {
    const a = this.archive;
    const supported = this.archives !== null;
    const ops = req.operands;
    switch (req.command) {
      case "archive.current": {
        if (!supported) return "err daemon_not_ready no archive support";
        const open = a.banks !== null;
        const bank = open ? a.bank : -1;
        return `ok open=${open ? 1 : 0} banks=${open ? a.banks.length : 0} bank=${bank}` +
          ` patches=${bank >= 0 ? a.banks[bank].patches.length : 0} archive_rev=${a.rev}` +
          `\npath=${a.path}\nbank_name=${bank >= 0 ? a.banks[bank].name : ""}`;
      }
      case "archive.open": {
        if (!supported) return "err daemon_not_ready no archive support";
        const path = req.rest || a.path;
        if (!path) return "err invalid_payload open needs a path";
        // A failure leaves the archive that was open, and its bank, alone.
        if (!Object.hasOwn(this.archives, path)) return "err invalid_payload cannot open archive";
        // Reopening the remembered path writes nothing: the file holds it.
        if (req.rest && this.keepFails) return "err internal_error cannot keep archive path";
        this.replaceArchive(path);
        return `ok banks=${a.banks.length} archive_rev=${a.rev}`;
      }
      case "archive.adopt": {
        if (!supported) return "err daemon_not_ready no archive support";
        if (!req.rest) return "err invalid_payload adopt needs a path";
        // Any choice already made stands, a remembered path that will not open
        // included.
        const adopt = a.banks === null && a.path === "";
        if (adopt) {
          if (!Object.hasOwn(this.archives, req.rest)) return "err invalid_payload cannot open archive";
          if (this.keepFails) return "err internal_error cannot keep archive path";
          this.replaceArchive(req.rest);
        }
        return `ok adopted=${adopt ? 1 : 0} open=${a.banks !== null ? 1 : 0}` +
          ` banks=${a.banks !== null ? a.banks.length : 0} archive_rev=${a.rev}`;
      }
      case "archive.banks": {
        if (!supported || a.banks === null) return "err daemon_not_ready no archive open";
        const [offset, count] = paged(req, a.banks.length);
        let answer = `ok total=${a.banks.length} archive_rev=${a.rev}`;
        for (let i = offset; i < offset + count; i++) answer += `\nbank=${i} name=${a.banks[i].name}`;
        return answer;
      }
      case "archive.bank": {
        if (!supported || a.banks === null) return "err daemon_not_ready no archive open";
        if (!ops.length) return "err invalid_payload bank needs an index";
        const i = archiveIndex(ops[0]);
        if (i === null || i >= a.banks.length) return "err invalid_payload cannot open that bank";
        // Asking for the bank already open is not a change.
        if (a.bank !== i) {
          a.bank = i;
          a.rev++;
        }
        return `ok patches=${a.banks[i].patches.length} bank=${i} archive_rev=${a.rev}`;
      }
      case "archive.patches": {
        if (!supported || a.bank < 0) return "err daemon_not_ready no bank open";
        const patches = a.banks[a.bank].patches;
        const [offset, count] = paged(req, patches.length);
        let answer = `ok total=${patches.length} bank=${a.bank} archive_rev=${a.rev}`;
        for (let i = offset; i < offset + count; i++) answer += `\npatch=${i} name=${patches[i].name}`;
        return answer;
      }
      case "archive.load": {
        if (!supported || (a.bank < 0 && ops.length < 2)) return "err daemon_not_ready no bank open";
        if (!ops.length) return "err invalid_payload load needs an index";
        const i = archiveIndex(ops[0]);
        if (i === null) return "err invalid_payload bad index";
        if (ops.length >= 2) {
          if (a.banks === null) return "err daemon_not_ready no archive open";
          const b = archiveIndex(ops[1]);
          if (b === null || b >= a.banks.length) return "err invalid_payload cannot open that bank";
          // The bank the client is showing is opened first, as archive.bank
          // would, even if the index then turns out to be out of range.
          if (a.bank !== b) {
            a.bank = b;
            a.rev++;
          }
        }
        const bank = a.banks[a.bank];
        if (i >= bank.patches.length) return "err invalid_payload patch index out of range";
        const p = bank.patches[i];
        this.queue.push(p.values.map((v, j) => [j, v]));
        this.identity = {slot: -1, bank: identityText(bank.name), name: identityText(p.name.trim()),
          source: "archive", archiveBank: a.bank, archivePatch: i};
        return `ok count=${PARAMS.length} revision=${this.published.revision} bank=${a.bank} patch=${i}`;
      }
      case "archive.close": {
        if (supported && this.keepFails) return "err internal_error cannot forget archive path";
        if (supported) {
          const changed = a.banks !== null || a.path !== "";
          a.banks = null;
          a.bank = -1;
          a.path = "";
          if (changed) a.rev++;
        }
        this.forgetArchive();
        return `ok archive_rev=${supported ? a.rev : 0}`;
      }
      default:
        return "err unknown_command unknown command";
    }
  }

  // The archive verbs as archive.odin answered them before the archive was
  // shared: no archive.current, no remembered path to reopen, archive.load
  // reading only its index, and no generation, bank or patch in an answer.
  // Not modelled: there a failed archive.open also closed the open archive.
  // The adapter is never to send one of these to such a daemon, and its tests
  // look at whether it did.
  handleOldArchive(req) {
    if (req.command === "archive.current" || req.command === "archive.adopt") {
      return "err unknown_command unknown command";
    }
    if (req.command === "archive.open" && !req.rest) return "err invalid_payload open needs a path";
    const operands = req.command === "archive.load" ? req.operands.slice(0, 1) : req.operands;
    const answer = this.handleArchive({...req, operands});
    if (!answer.startsWith("ok")) return answer;
    if (req.command === "archive.close") return "ok";
    const [head, ...records] = answer.split("\n");
    const fields = head.split(" ").slice(1).filter(f => !/^(archive_rev|bank|patch)=/.test(f));
    return ["ok " + fields.join(" "), ...records].join("\n");
  }

  // The open archive becomes the one at path, with no bank open, and the
  // playing patch stops pointing into it.
  replaceArchive(path) {
    const a = this.archive;
    a.banks = this.archives[path];
    a.bank = -1;
    a.path = path;
    a.rev++;
    this.forgetArchive();
  }

  // The archive that supplied the sound is gone or replaced: the names still
  // say what is playing, but its indices would name another archive's patch.
  forgetArchive() {
    this.identity = {...this.identity, archiveBank: -1, archivePatch: -1};
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
