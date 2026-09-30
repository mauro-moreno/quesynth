// A WebSocket client on a bare TCP socket, so tests can send what no real
// browser would: unmasked frames, 64-bit lengths, reserved bits, bad UTF-8.

import crypto from "node:crypto";
import net from "node:net";

export function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Build one client frame. Everything a well-behaved client does is the
// default; each option breaks one rule.
export function clientFrame({opcode = 1, payload = "", fin = true, mask = true, rsv = 0, length64 = false} = {}) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), "utf8");
  let header;
  if (body.length < 126 && !length64) {
    header = Buffer.from([0, body.length]);
  } else if (body.length < 0x10000 && !length64) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  header[0] = (fin ? 0x80 : 0) | (rsv << 4) | opcode;
  if (!mask) return Buffer.concat([header, body]);
  header[1] |= 0x80;
  const key = crypto.randomBytes(4);
  const masked = Buffer.from(body);
  for (let i = 0; i < masked.length; i++) masked[i] ^= key[i & 3];
  return Buffer.concat([header, key, masked]);
}

// Send a raw HTTP request and collect whatever comes back until the socket
// ends. For the non-upgrade and refused-upgrade cases.
export function rawHttp(port, text) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(port, "127.0.0.1");
    const chunks = [];
    socket.on("data", c => chunks.push(c));
    socket.on("error", reject);
    socket.on("close", () => {
      const all = Buffer.concat(chunks).toString("latin1");
      const status = Number((/^HTTP\/1\.1 (\d+)/.exec(all) || [])[1] || 0);
      resolve({status, text: all});
    });
    socket.write(text);
  });
}

export function upgradeRequest(port, {path = "/control", host = `127.0.0.1:${port}`, origin, headers = {}} = {}) {
  const lines = [
    `GET ${path} HTTP/1.1`,
    `Host: ${host}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString("base64")}`,
    "Sec-WebSocket-Version: 13",
  ];
  if (origin !== undefined) lines.push(`Origin: ${origin}`);
  for (const [name, value] of Object.entries(headers)) lines.push(`${name}: ${value}`);
  return lines.join("\r\n") + "\r\n\r\n";
}

export class TestSocket {
  // Resolves with a TestSocket on 101, or with {status, text} otherwise.
  static open(port, options = {}) {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(port, "127.0.0.1");
      let head = Buffer.alloc(0);
      const onData = chunk => {
        head = Buffer.concat([head, chunk]);
        const end = head.indexOf("\r\n\r\n");
        if (end < 0) return;
        const text = head.subarray(0, end).toString("latin1");
        const status = Number(/^HTTP\/1\.1 (\d+)/.exec(text)[1]);
        socket.removeListener("data", onData);
        if (status !== 101) {
          const rest = [head];
          socket.on("data", c => rest.push(c));
          socket.on("close", () => resolve({status, text: Buffer.concat(rest).toString("latin1")}));
          return;
        }
        resolve(new TestSocket(socket, head.subarray(end + 4)));
      };
      socket.on("data", onData);
      socket.once("error", reject);
      socket.write(upgradeRequest(port, options));
    });
  }

  constructor(socket, rest) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.inbox = [];
    this.received = [];
    this.frames = [];
    this.waiters = [];
    this.closeFrame = null;
    this.sentClose = false;
    this.ended = false;
    this.closed = new Promise(resolve => {
      socket.on("close", () => {
        this.ended = true;
        resolve(this.closeFrame);
        this.wake();
      });
    });
    socket.on("error", () => {});
    socket.on("data", chunk => this.receive(chunk));
    if (rest.length) this.receive(rest);
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < 2) return;
      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      let length = b1 & 0x7f;
      let at = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        at = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        at = 10;
      }
      if (b1 & 0x80) at += 4;
      if (this.buffer.length < at + length) return;
      const payload = Buffer.from(this.buffer.subarray(at, at + length));
      this.buffer = this.buffer.subarray(at + length);
      const opcode = b0 & 0x0f;
      this.frames.push({opcode, fin: (b0 & 0x80) !== 0, masked: (b1 & 0x80) !== 0, length, payload});
      if (opcode === 1) {
        const msg = JSON.parse(payload.toString("utf8"));
        this.inbox.push(msg);
        this.received.push(msg);
        this.wake();
      } else if (opcode === 8) {
        this.closeFrame = {
          code: payload.length >= 2 ? payload.readUInt16BE(0) : 1005,
          reason: payload.subarray(2).toString("utf8"),
        };
        // As a browser does: echo the code and let the server end TCP.
        if (!this.sentClose) {
          this.sentClose = true;
          this.socket.write(clientFrame({opcode: 8, payload: payload.subarray(0, 2)}));
        }
        this.wake();
      }
    }
  }

  wake() {
    for (const w of this.waiters.splice(0)) w();
  }

  send(msg) {
    this.socket.write(clientFrame({payload: typeof msg === "string" ? msg : JSON.stringify(msg)}));
  }

  sendRaw(buffer) {
    this.socket.write(buffer);
  }

  // The next unread message matching `match` (a type name or a predicate).
  next(match, timeoutMs = 3000) {
    const test = typeof match === "function" ? match : m => m.type === match;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${match}`)), timeoutMs);
      const look = () => {
        const at = this.inbox.findIndex(test);
        if (at >= 0) {
          clearTimeout(timer);
          resolve(this.inbox.splice(at, 1)[0]);
        } else if (this.ended) {
          clearTimeout(timer);
          reject(new Error(`socket closed while waiting for ${match}`));
        } else {
          this.waiters.push(look);
        }
      };
      look();
    });
  }

  // Unread messages matching, after letting `ms` pass.
  async quiet(ms, match = () => true) {
    await sleep(ms);
    const test = typeof match === "function" ? match : m => m.type === match;
    return this.inbox.filter(test);
  }

  drain() {
    return this.inbox.splice(0);
  }

  // The handshake a page does on load: sync, then bank, state, patch.
  async synced() {
    this.send({type: "sync"});
    const bank = await this.next("bank");
    const state = await this.next("state");
    const patch = await this.next("patch");
    return {bank, state, patch};
  }

  close(code = 1000) {
    const payload = Buffer.alloc(2);
    payload.writeUInt16BE(code, 0);
    this.sentClose = true;
    this.socket.write(clientFrame({opcode: 8, payload}));
    return this.closed;
  }

  destroy() {
    this.socket.destroy();
  }
}
