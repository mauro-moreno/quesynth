"use strict";
// A client for the daemon's control socket: the framing of
// src/control/codec.odin and the envelope of src/control/message.odin.

const net = require("net");
const { EventEmitter } = require("events");

const PROTOCOL_VERSION = 1;
// src/control/codec.odin MAX_FRAME_PAYLOAD. A longer frame from the daemon is
// not a big answer, it is a stream that has lost its framing.
const MAX_FRAME = 64 * 1024;
const DEFAULT_TIMEOUT_MS = 3000;

// The daemon answered, and the answer was no. `code` is its Error_Code token.
class DaemonError extends Error {
  constructor(code, message, command) {
    super(message || code);
    this.name = "DaemonError";
    this.code = code;
    this.command = command;
  }
}

// The connection itself is gone or unusable; every later request fails too.
class ConnectionError extends Error {
  constructor(message) {
    super(message);
    this.name = "ConnectionError";
    this.code = "daemon_unavailable";
  }
}

class Response {
  constructor(fields, lines) {
    this.fields = fields;
    this.lines = lines;
  }

  // A key=value token of the envelope line, or undefined.
  field(key) {
    for (const token of this.fields.split(" ")) {
      if (token.startsWith(key + "=")) return token.slice(key.length + 1);
    }
    return undefined;
  }

  // A field that is last on its line because its value may hold spaces.
  rest(key) {
    const at = (" " + this.fields).indexOf(" " + key + "=");
    return at < 0 ? undefined : this.fields.slice(at + key.length + 1);
  }

  int(key) {
    const text = this.field(key);
    return text !== undefined && /^-?\d+$/.test(text) ? Number(text) : undefined;
  }
}

function parseEnvelope(text) {
  const newline = text.indexOf("\n");
  const envelope = newline < 0 ? text : text.slice(0, newline);
  const lines = newline < 0 ? [] : text.slice(newline + 1).split("\n");
  const m = /^ *(\d+) +(-?\d+) +(ok|err)(?: +(.*))?$/.exec(envelope);
  if (!m || Number(m[1]) !== PROTOCOL_VERSION) return null;
  const rest = (m[4] || "").trim();
  if (m[3] === "ok") return { id: Number(m[2]), ok: true, response: new Response(rest, lines) };
  const space = rest.indexOf(" ");
  return {
    id: Number(m[2]),
    ok: false,
    code: space < 0 ? rest : rest.slice(0, space),
    message: space < 0 ? "" : rest.slice(space + 1),
  };
}

// Events: "close" (error) exactly once, when the connection is gone for any
// reason, after every pending request has been rejected. Never "error": a
// daemon going away is an expected event for a front-end, not a crash.
class DaemonClient extends EventEmitter {
  constructor(socketPath, options = {}) {
    super();
    this.timeoutMs = options.timeoutMs || DEFAULT_TIMEOUT_MS;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.closed = false;
    this.socket = net.createConnection(socketPath);
    this.socket.on("data", chunk => this.receive(chunk));
    this.socket.on("error", err => this.shutdown(new ConnectionError(err.message)));
    this.socket.on("end", () => this.shutdown(new ConnectionError("daemon closed the connection")));
    this.socket.on("close", () => this.shutdown(new ConnectionError("daemon connection closed")));
  }

  // Resolves with a Response, rejects with DaemonError for an `err` answer or
  // ConnectionError when the connection fails, including by timing out.
  request(command) {
    if (this.closed) return Promise.reject(new ConnectionError("daemon connection closed"));
    // Requests are single-line; a newline would smuggle a second one past
    // whatever validated the first.
    if (/[\r\n\0]/.test(command)) return Promise.reject(new TypeError("command spans lines"));
    const id = this.nextId++;
    const payload = Buffer.from(`${PROTOCOL_VERSION} ${id} ${command}`, "utf8");
    if (payload.length > MAX_FRAME) return Promise.reject(new TypeError("command too long"));
    const frame = Buffer.alloc(4 + payload.length);
    frame.writeUInt32LE(payload.length, 0);
    payload.copy(frame, 4);
    const verb = command.split(" ", 1)[0];
    return new Promise((resolve, reject) => {
      // One late answer means the daemon is wedged or the stream is out of
      // step; either way nothing after it can be trusted, so the connection
      // is dropped rather than left to pile up requests.
      const timer = setTimeout(() => {
        this.shutdown(new ConnectionError(`daemon did not answer ${verb} within ${this.timeoutMs} ms`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer, verb });
      this.socket.write(frame);
    });
  }

  close() {
    this.shutdown(new ConnectionError("daemon connection closed"));
  }

  receive(chunk) {
    if (this.closed) return;
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    while (this.buffer.length >= 4) {
      const n = this.buffer.readUInt32LE(0);
      if (n > MAX_FRAME) return this.shutdown(new ConnectionError("oversized frame from daemon"));
      if (this.buffer.length < 4 + n) return;
      const text = this.buffer.subarray(4, 4 + n).toString("utf8");
      this.buffer = this.buffer.subarray(4 + n);
      const answer = parseEnvelope(text);
      const entry = answer && this.pending.get(answer.id);
      // An answer to nothing asked means the two ends disagree about the
      // stream; the request it belonged to would only time out later.
      if (!entry) return this.shutdown(new ConnectionError("malformed response from daemon"));
      this.pending.delete(answer.id);
      clearTimeout(entry.timer);
      if (answer.ok) entry.resolve(answer.response);
      else entry.reject(new DaemonError(answer.code, answer.message, entry.verb));
    }
  }

  shutdown(err) {
    if (this.closed) return;
    this.closed = true;
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(err);
    }
    this.pending.clear();
    this.buffer = Buffer.alloc(0);
    this.socket.destroy();
    this.emit("close", err);
  }
}

module.exports = { DaemonClient, DaemonError, ConnectionError };
