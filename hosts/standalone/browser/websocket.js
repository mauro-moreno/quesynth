"use strict";
// The server half of RFC 6455, for one kind of peer: the panel's page, which
// only ever sends text. Written here rather than taken from npm because the
// adapter ships beside the binary with no install step, and the part of the
// protocol a local panel needs is small enough to get exactly right.

const crypto = require("crypto");
const http = require("http");
const { EventEmitter } = require("events");
const { isUtf8 } = require("buffer");

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// A full 128-slot bank is about 400 KB of pretty-printed JSON, and escaping
// it into a `bank` message adds roughly a fifth. Two mebibytes holds that
// four times over, so the biggest thing the panel sends always fits, while a
// runaway page still cannot make the adapter buffer without bound.
const MAX_MESSAGE = 2 * 1024 * 1024;

// A page that stops reading (a frozen tab) must not make the adapter hold its
// output forever; past this much unsent data the connection is dropped and the
// page reconnects to a fresh snapshot.
const MAX_BACKLOG = 8 * 1024 * 1024;

// How long a close handshake may take before the socket is simply destroyed.
const CLOSE_TIMEOUT_MS = 1000;

const TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xa;

// Null when the request is a version 13 opening handshake, otherwise why not.
function checkHandshake(req) {
  if (req.method !== "GET") return { status: 405, message: "websocket needs GET" };
  if (String(req.headers.upgrade || "").toLowerCase() !== "websocket") {
    return { status: 400, message: "not a websocket upgrade" };
  }
  const tokens = String(req.headers.connection || "").toLowerCase().split(",");
  if (!tokens.some(t => t.trim() === "upgrade")) {
    return { status: 400, message: "connection header lacks upgrade" };
  }
  if (req.headers["sec-websocket-version"] !== "13") {
    return { status: 426, message: "websocket version 13 only",
      headers: { "Sec-WebSocket-Version": "13" } };
  }
  // The key is 16 random bytes in base64, which is always 24 characters.
  if (!/^[A-Za-z0-9+/]{22}==$/.test(String(req.headers["sec-websocket-key"] || ""))) {
    return { status: 400, message: "bad sec-websocket-key" };
  }
  return null;
}

// Answer an upgrade request with a plain HTTP error and hang up. Used for every
// refusal, including 503 when the daemon is down, which is what tells the page
// to back off and retry rather than treat the adapter as broken.
function rejectUpgrade(socket, status, message, headers) {
  if (socket.destroyed) return;
  const body = `${message || http.STATUS_CODES[status] || "error"}\n`;
  let head = `HTTP/1.1 ${status} ${http.STATUS_CODES[status] || "Error"}\r\n` +
    "Connection: close\r\nContent-Type: text/plain; charset=utf-8\r\n" +
    `Content-Length: ${Buffer.byteLength(body)}\r\n`;
  for (const [name, value] of Object.entries(headers || {})) head += `${name}: ${value}\r\n`;
  socket.end(`${head}\r\n${body}`, () => socket.destroy());
}

// Complete a handshake checkHandshake accepted and wrap the socket.
function acceptUpgrade(req, socket, head) {
  const accept = crypto.createHash("sha1")
    .update(req.headers["sec-websocket-key"] + GUID).digest("base64");
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
    `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  return new WebSocketConnection(socket, head);
}

function encodeFrame(opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length < 0x10000) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  header[0] = 0x80 | opcode;
  return Buffer.concat([header, payload]);
}

// 1005, 1006 and 1015 are reserved for reporting and must never be sent.
function validCloseCode(code) {
  return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1011) ||
    (code >= 3000 && code <= 4999);
}

// Events: "message" (text), "close" (code, reason) exactly once.
class WebSocketConnection extends EventEmitter {
  constructor(socket, head) {
    super();
    this.socket = socket;
    this.state = "open";
    this.chunks = [];
    this.buffered = 0;
    // Set once nothing more read can matter: a close frame came, or a fault.
    this.stopped = false;
    this.fragments = null;
    this.fragmentBytes = 0;
    this.closeCode = 1006;
    this.closeReason = "";
    this.closeTimer = null;
    this.emittedClose = false;

    socket.setNoDelay(true);
    socket.on("data", chunk => this.receive(chunk));
    // A reset, or a write to a vanished peer: nothing to report but the close.
    socket.on("error", () => this.destroy());
    socket.on("end", () => this.destroy());
    socket.on("close", () => this.finish());
    if (head && head.length) {
      // Deferred so the owner can attach "message" before the first one.
      process.nextTick(() => this.receive(head));
    }
  }

  send(text) {
    if (this.state !== "open") return false;
    return this.write(encodeFrame(TEXT, Buffer.from(String(text), "utf8")));
  }

  // Start a close handshake. The peer echoes it and the socket ends; a peer
  // that never answers is cut off after CLOSE_TIMEOUT_MS.
  close(code = 1000, reason = "") {
    if (this.state !== "open") return;
    this.state = "closing";
    this.closeCode = code;
    this.closeReason = reason;
    let text = Buffer.from(String(reason), "utf8");
    // A control frame carries at most 125 bytes, two of them the code.
    if (text.length > 123) text = text.subarray(0, 123);
    const payload = Buffer.alloc(2 + text.length);
    payload.writeUInt16BE(code, 0);
    text.copy(payload, 2);
    this.write(encodeFrame(CLOSE, payload));
    this.closeTimer = setTimeout(() => this.destroy(), CLOSE_TIMEOUT_MS);
    this.closeTimer.unref();
  }

  destroy() {
    if (this.state !== "closed") this.state = "closed";
    clearTimeout(this.closeTimer);
    if (!this.socket.destroyed) this.socket.destroy();
  }

  write(buffer) {
    const socket = this.socket;
    if (socket.destroyed || !socket.writable) return false;
    if (socket.writableLength + buffer.length > MAX_BACKLOG) {
      this.destroy();
      return false;
    }
    socket.write(buffer);
    return true;
  }

  finish() {
    this.state = "closed";
    clearTimeout(this.closeTimer);
    this.chunks = [];
    this.fragments = null;
    if (this.emittedClose) return;
    this.emittedClose = true;
    this.emit("close", this.closeCode, this.closeReason);
  }

  // A protocol violation (RFC 6455 section 7.1.7): say why and end the
  // connection now, since nothing more read from it can be trusted.
  fail(code, reason) {
    this.chunks = [];
    this.buffered = 0;
    this.stopped = true;
    if (this.state !== "open") return this.destroy();
    this.close(code, reason);
    this.socket.end();
    return undefined;
  }

  take(n) {
    // An empty payload is read after its mask, which can leave no chunk at
    // all; there is nothing to take, so the list must not be consulted.
    if (n === 0) return Buffer.alloc(0);
    const first = this.chunks[0];
    let out;
    if (n <= first.length) {
      out = first.subarray(0, n);
      if (n === first.length) this.chunks.shift();
      else this.chunks[0] = first.subarray(n);
    } else {
      out = Buffer.allocUnsafe(n);
      let at = 0;
      while (at < n) {
        const chunk = this.chunks[0];
        const k = Math.min(chunk.length, n - at);
        chunk.copy(out, at, 0, k);
        at += k;
        if (k === chunk.length) this.chunks.shift();
        else this.chunks[0] = chunk.subarray(k);
      }
    }
    this.buffered -= n;
    return out;
  }

  peek(n) {
    if (this.chunks[0].length >= n) return this.chunks[0];
    return Buffer.concat(this.chunks, Math.min(this.buffered, 14));
  }

  receive(chunk) {
    if (this.stopped || this.state === "closed") return;
    this.chunks.push(chunk);
    this.buffered += chunk.length;
    // Frames are parsed as they complete, so what is buffered is never more
    // than one frame in progress, and that frame's size is checked first.
    while (!this.stopped && this.state !== "closed" && this.buffered >= 2) {
      const h = this.peek(2);
      const fin = (h[0] & 0x80) !== 0;
      const opcode = h[0] & 0x0f;
      const masked = (h[1] & 0x80) !== 0;
      let length = h[1] & 0x7f;
      if (h[0] & 0x70) return this.fail(1002, "reserved bits set");
      if ((opcode > BINARY && opcode < CLOSE) || opcode > PONG) {
        return this.fail(1002, "reserved opcode");
      }
      const control = opcode >= CLOSE;
      if (control && (!fin || length > 125)) return this.fail(1002, "bad control frame");
      if (!masked) return this.fail(1002, "client frames must be masked");
      if (!control) {
        if (opcode === 0 && !this.fragments) return this.fail(1002, "unexpected continuation");
        if (opcode !== 0 && this.fragments) return this.fail(1002, "expected continuation");
        if (opcode === BINARY) return this.fail(1003, "text messages only");
      }

      let headerLength = 2;
      if (length === 126) headerLength = 4;
      else if (length === 127) headerLength = 10;
      if (this.buffered < headerLength + 4) return;
      const header = this.peek(headerLength);
      if (length === 126) {
        length = header.readUInt16BE(2);
      } else if (length === 127) {
        const high = header.readUInt32BE(2);
        if (high & 0x80000000) return this.fail(1002, "bad frame length");
        // Anything with the high word set is past four gigabytes.
        length = high ? Infinity : header.readUInt32BE(6);
      }
      if (!control && this.fragmentBytes + length > MAX_MESSAGE) {
        return this.fail(1009, "message too big");
      }
      if (this.buffered < headerLength + 4 + length) return;

      this.take(headerLength);
      const mask = this.take(4);
      const payload = Buffer.from(this.take(length));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];

      if (control) this.control(opcode, payload);
      else this.data(fin, payload);
    }
  }

  data(fin, payload) {
    if (!this.fragments) this.fragments = [];
    this.fragments.push(payload);
    this.fragmentBytes += payload.length;
    if (!fin) return;
    const message = Buffer.concat(this.fragments, this.fragmentBytes);
    this.fragments = null;
    this.fragmentBytes = 0;
    if (!isUtf8(message)) return this.fail(1007, "text is not utf-8");
    // Dropped once a close is under way: the page has been told goodbye.
    if (this.state !== "open") return;
    try {
      this.emit("message", message.toString("utf8"));
    } catch (err) {
      this.fail(1011, "internal error");
    }
  }

  control(opcode, payload) {
    if (opcode === PING) {
      if (this.state === "open") this.write(encodeFrame(PONG, payload));
      return;
    }
    if (opcode === PONG) return;
    if (payload.length === 1) return this.fail(1002, "bad close payload");
    let code = 1005;
    if (payload.length >= 2) {
      code = payload.readUInt16BE(0);
      if (!validCloseCode(code)) return this.fail(1002, "bad close code");
      if (!isUtf8(payload.subarray(2))) return this.fail(1007, "close reason is not utf-8");
    }
    if (this.state === "open") {
      this.state = "closing";
      this.closeCode = code;
      this.closeReason = payload.subarray(2).toString("utf8");
      this.write(encodeFrame(CLOSE, code === 1005 ? Buffer.alloc(0) : payload.subarray(0, 2)));
    }
    // The server closes TCP first (RFC 6455 section 7.1.1), then waits a
    // moment for the peer to do likewise before destroying.
    this.chunks = [];
    this.buffered = 0;
    this.stopped = true;
    this.socket.end();
    clearTimeout(this.closeTimer);
    this.closeTimer = setTimeout(() => this.destroy(), CLOSE_TIMEOUT_MS);
    this.closeTimer.unref();
  }
}

module.exports = { checkHandshake, rejectUpgrade, acceptUpgrade, WebSocketConnection };
