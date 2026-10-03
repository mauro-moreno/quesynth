import test from "node:test";
import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {spawn} from "node:child_process";
import {createRequire} from "node:module";
import {DEFAULTS, ROOT, SLOTS, writeBank} from "./support/fake-daemon.mjs";
import {startEnv, unix, until} from "./support/harness.mjs";
import {TestSocket, clientFrame, sleep} from "./support/ws-client.mjs";

const require = createRequire(import.meta.url);
const {WebSocketConnection} = require("../../hosts/standalone/browser/websocket.js");
const SERVE = new URL("../../hosts/standalone/browser/serve.js", import.meta.url).pathname;

const skip = !unix;
const SYNC = JSON.stringify({type: "sync"});

async function page(t, options) {
  const env = await startEnv(t, options);
  const ws = await env.open();
  return {env, ws};
}

// Send one violation and expect the server to close with `code`, and the
// page's daemon connection to go with it.
async function expectClose(t, frames, code) {
  const {env, ws} = await page(t);
  for (const f of [].concat(frames)) ws.sendRaw(f);
  const closed = await ws.closed;
  assert.equal(closed && closed.code, code);
  await until(() => env.daemon.connections.size === 0, 3000, "the daemon connection to close");
}

test("a ping is answered with a pong carrying the same payload", {skip}, async t => {
  const {ws} = await page(t);
  ws.sendRaw(clientFrame({opcode: 9, payload: "are you there"}));
  await until(() => ws.frames.some(f => f.opcode === 10), 3000, "a pong");
  assert.equal(ws.frames.find(f => f.opcode === 10).payload.toString(), "are you there");
  await ws.synced();
});

test("a fragmented text message is reassembled, with a ping between fragments", {skip}, async t => {
  const {ws} = await page(t);
  ws.sendRaw(clientFrame({opcode: 1, fin: false, payload: SYNC.slice(0, 4)}));
  ws.sendRaw(clientFrame({opcode: 0, fin: false, payload: SYNC.slice(4, 9)}));
  ws.sendRaw(clientFrame({opcode: 9, payload: "x"}));
  ws.sendRaw(clientFrame({opcode: 0, fin: true, payload: SYNC.slice(9)}));
  await ws.next("bank");
  await ws.next("state");
  await ws.next("patch");
});

test("a frame with a 64-bit length is read", {skip}, async t => {
  const {ws} = await page(t);
  ws.sendRaw(clientFrame({payload: SYNC, length64: true}));
  await ws.next("bank");
});

test("a message over the size limit is refused with 1009 before it is buffered", {skip}, async t => {
  const header = clientFrame({payload: Buffer.alloc(3 * 1024 * 1024), length64: true}).subarray(0, 14);
  await expectClose(t, header, 1009);
});

test("fragments that add up to more than the limit are refused with 1009", {skip}, async t => {
  const half = Buffer.alloc(1100 * 1024, 0x20);
  await expectClose(t, [clientFrame({opcode: 1, fin: false, payload: half}),
    clientFrame({opcode: 0, fin: true, payload: half})], 1009);
});

test("an unmasked client frame is refused with 1002", {skip}, async t => {
  await expectClose(t, clientFrame({payload: SYNC, mask: false}), 1002);
});

test("a binary message is refused with 1003", {skip}, async t => {
  await expectClose(t, clientFrame({opcode: 2, payload: SYNC}), 1003);
});

test("text that is not UTF-8 is refused with 1007", {skip}, async t => {
  await expectClose(t, clientFrame({payload: Buffer.from([0x7b, 0xff, 0xfe, 0x7d])}), 1007);
});

test("reserved bits, reserved opcodes and malformed control frames are refused with 1002", {skip}, async t => {
  const cases = {
    rsv: clientFrame({payload: SYNC, rsv: 4}),
    opcode: clientFrame({opcode: 3, payload: SYNC}),
    continuation: clientFrame({opcode: 0, payload: SYNC}),
    "long ping": clientFrame({opcode: 9, payload: Buffer.alloc(126)}),
    "fragmented ping": clientFrame({opcode: 9, fin: false, payload: "x"}),
    "one-byte close": clientFrame({opcode: 8, payload: Buffer.from([3])}),
    "reserved close code": clientFrame({opcode: 8, payload: Buffer.from([0x03, 0xed])}),
    "text inside a fragment": [clientFrame({opcode: 1, fin: false, payload: "{"}), clientFrame({payload: SYNC})],
  };
  for (const [name, frames] of Object.entries(cases)) {
    await t.test(name, async t2 => expectClose(t2, frames, 1002));
  }
});

test("a close from the page is echoed and the connection ends", {skip}, async t => {
  const {env, ws} = await page(t);
  await ws.synced();
  const closed = await ws.close(1000);
  assert.deepEqual(closed, {code: 1000, reason: ""});
  await until(() => env.daemon.connections.size === 0 && env.bridge.sessions === 0, 3000, "teardown");
});

test("frames of every length encoding reach a real client intact, a 128-slot bank included", {skip}, async t => {
  const {env, ws} = await page(t);
  const full = env.daemon.bank.slots.map((s, i) => ({name: `Patch ${i} "quoted" \\ é`, values: DEFAULTS.slice()}));
  env.daemon.bank.slots = full;
  assert.equal(full.length, SLOTS);
  const expected = writeBank(env.daemon.bank);
  assert.ok(expected.length > 65535 * 4);

  await ws.synced();
  const lengths = ws.frames.filter(f => f.opcode === 1).map(f => f.length);
  assert.ok(lengths[0] > 0xffff, "the bank needs a 64-bit length");
  assert.ok(lengths[1] >= 126 && lengths[1] <= 0xffff, "the state a 16-bit one");
  assert.ok(lengths[2] < 126, "the patch fits the 7-bit one");
  assert.ok(ws.frames.every(f => !f.masked), "server frames are never masked");

  if (typeof WebSocket !== "function") return t.skip("no global WebSocket in this Node");
  const socket = new WebSocket(`ws://127.0.0.1:${env.port}/control`);
  t.after(() => socket.close());
  const bank = await new Promise((resolve, reject) => {
    socket.addEventListener("open", () => socket.send(SYNC));
    socket.addEventListener("message", event => {
      const msg = JSON.parse(event.data);
      if (msg.type === "bank") resolve(msg);
    });
    socket.addEventListener("error", () => reject(new Error("websocket error")));
  });
  assert.equal(bank.text, expected);
  return undefined;
});

// -- frames with nothing in them ---------------------------------------------
//
// A browser's ws.close() with no code is the six bytes 88 80 <mask>: a masked
// close frame with no payload. An empty text frame or ping is the same shape.
// Such a frame ends exactly where a read ends, which is where a parser that
// assumes "there is always one more byte buffered" falls over.

function closePayload(code, reason = "") {
  const head = Buffer.alloc(2);
  head.writeUInt16BE(code, 0);
  return Buffer.concat([head, Buffer.from(reason)]);
}

// What the server must answer with the page gone quiet afterwards. For a
// close the reply echoes the code only (RFC 6455 section 5.5.1), and a close
// with no payload is answered with none, because 1005 may never be sent.
const EMPTY_FRAMES = {
  "close with no payload": {
    frame: clientFrame({opcode: 8}),
    closed: {code: 1005, reason: ""},
    reply: Buffer.alloc(0),
  },
  "close with a code and a reason": {
    frame: clientFrame({opcode: 8, payload: closePayload(1000, "done")}),
    closed: {code: 1000, reason: ""},
    reply: closePayload(1000),
  },
  "unmasked close with no payload": {
    frame: clientFrame({opcode: 8, mask: false}),
    closed: {code: 1002, reason: "client frames must be masked"},
  },
  "empty text": {
    frame: clientFrame({opcode: 1}),
    messages: [""],
    async settle(ws) {
      assert.equal((await ws.next("error")).code, "invalid_payload");
    },
  },
  "empty ping": {
    frame: clientFrame({opcode: 9}),
    async settle(ws) {
      await until(() => ws.frames.some(f => f.opcode === 10), 3000, "a pong");
      assert.equal(ws.frames.find(f => f.opcode === 10).length, 0);
    },
  },
  "empty pong": {
    frame: clientFrame({opcode: 10}),
    async settle(ws) {
      await sleep(50);
      assert.equal(ws.frames.some(f => f.opcode === 10), false, "a pong is never answered");
    },
  },
};

// Whole, or one byte per TCP segment with a pause, so the server reads the
// frame as separate chunks whose last one is the final byte of the frame.
async function deliver(ws, bytes, mode) {
  if (mode === "whole") return ws.sendRaw(bytes);
  ws.socket.setNoDelay(true);
  for (const byte of bytes) {
    ws.sendRaw(Buffer.from([byte]));
    await sleep(3);
  }
  return undefined;
}

for (const mode of ["whole", "byte by byte"]) {
  test(`frames with an empty payload sent ${mode} do not hurt the adapter`, {skip}, async t => {
    for (const [name, c] of Object.entries(EMPTY_FRAMES)) {
      await t.test(name, async t2 => {
        const {env, ws} = await page(t2);
        const other = await env.open();
        await other.synced();
        await ws.synced();
        assert.equal(env.daemon.connections.size, 2);

        await deliver(ws, c.frame, mode);
        if (c.closed) {
          assert.deepEqual(await ws.closed, c.closed);
          if (c.reply) {
            const replies = ws.frames.filter(f => f.opcode === 8);
            assert.equal(replies.length, 1);
            assert.deepEqual(replies[0].payload, c.reply);
          }
          await until(() => env.daemon.connections.size === 1 && env.bridge.sessions === 1, 3000,
            "this page's daemon connection to close and the other's to stay");
        } else {
          await c.settle(ws);
          await ws.synced();
          assert.equal(ws.ended, false, "the page's own connection stays open");
        }

        // Nobody else noticed, and new pages are still welcome.
        await other.synced();
        assert.equal(other.ended, false);
        const late = await env.open();
        assert.ok(late instanceof TestSocket);
        await late.synced();
      });
    }
  });
}

test("a page closing without a code does not take the adapter process down", {skip}, async t => {
  const env = await startEnv(t);
  const child = spawn(process.execPath, [SERVE, "--root", ROOT, "--socket", env.socketPath,
    "--port", "0", "--no-open"], {stdio: ["ignore", "pipe", "pipe"]});
  t.after(() => child.kill("SIGKILL"));
  let stdout = "";
  let stderr = "";
  child.stderr.on("data", c => { stderr += c; });
  const port = await new Promise((resolve, reject) => {
    child.stdout.on("data", c => {
      stdout += c;
      const m = /127\.0\.0\.1:(\d+)\/ui\/index\.html/.exec(stdout);
      if (m) resolve(Number(m[1]));
    });
    child.on("exit", () => reject(new Error("serve.js exited early")));
  });
  const exited = new Promise(resolve => child.on("exit", (code, signal) => resolve({code, signal})));

  const bystander = await TestSocket.open(port);
  t.after(() => bystander.destroy());
  await bystander.synced();
  const leaving = await TestSocket.open(port);
  await leaving.synced();
  leaving.sendRaw(Buffer.from([0x88, 0x80, 1, 2, 3, 4]));
  assert.deepEqual(await leaving.closed, {code: 1005, reason: ""});
  await until(() => env.daemon.connections.size === 1, 3000, "the closed page's daemon connection to go");

  assert.equal(child.exitCode, null, `the adapter died: ${stderr}`);
  await bystander.synced();
  const again = await TestSocket.open(port);
  t.after(() => again.destroy());
  await again.synced();
  assert.equal(stderr, "");

  child.kill("SIGTERM");
  assert.deepEqual(await exited, {code: 0, signal: null});
});

// -- the reader against every way of cutting the stream -----------------------

// Just enough of a socket for the reader: bytes in through "data", bytes out
// collected. No network, so the cuts are exactly the ones a test asks for.
class FakeSocket extends EventEmitter {
  constructor() {
    super();
    this.destroyed = false;
    this.writable = true;
    this.writableLength = 0;
    this.written = [];
  }

  setNoDelay() {}
  write(buffer) { this.written.push(Buffer.from(buffer)); return true; }
  end() {}
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.emit("close");
  }
}

// Everything the reader made of `chunks`, for comparing one cut with another.
function feed(chunks) {
  const socket = new FakeSocket();
  const connection = new WebSocketConnection(socket, null);
  const messages = [];
  connection.on("message", text => messages.push(text));
  let closed = null;
  connection.on("close", (code, reason) => { closed = {code, reason}; });
  for (const chunk of chunks) socket.emit("data", chunk);
  const state = connection.state;
  connection.destroy();
  return {messages, state, closed, sent: Buffer.concat(socket.written).toString("hex")};
}

function cutBytes(buffer) {
  return Array.from(buffer, byte => Buffer.from([byte]));
}

test("a frame with an empty payload ends the stream cleanly however it is cut", () => {
  const sentinel = clientFrame({payload: "x"});
  for (const [name, c] of Object.entries(EMPTY_FRAMES)) {
    for (const tail of [Buffer.alloc(0), sentinel]) {
      const stream = Buffer.concat([c.frame, tail]);
      const cuts = [[stream], cutBytes(stream)];
      for (let at = 1; at < stream.length; at++) cuts.push([stream.subarray(0, at), stream.subarray(at)]);
      const reference = feed([stream]);
      for (const chunks of cuts) {
        assert.deepEqual(feed(chunks), reference, `${name}, cut ${chunks.map(x => x.length)}`);
      }
      // Even a refusal leaves the connection "closing": the close frame is
      // sent and the peer is given a moment to answer.
      const ends = c.closed !== undefined;
      assert.equal(reference.state, ends ? "closing" : "open", name);
      const expected = [...(c.messages || []), ...(!ends && tail.length ? ["x"] : [])];
      assert.deepEqual(reference.messages, expected, name);
    }
  }
});

// A small deterministic generator (mulberry32), so a failure names its seed.
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (rand, list) => list[Math.floor(rand() * list.length)];
const between = (rand, lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

function randomText(rand) {
  // The lengths where an encoding changes, and zero, come up often.
  const length = rand() < 0.5
    ? pick(rand, [0, 0, 1, 2, 3, 124, 125, 126, 127])
    : rand() < 0.97 ? between(rand, 0, 400) : pick(rand, [65535, 65536, 70000]);
  const alphabet = ["a", "{", "\"", " ", "é", "€", "😀"];
  let text = "";
  for (let i = 0; i < length; i++) text += pick(rand, alphabet);
  return text;
}

function randomBytes(rand, max) {
  return Buffer.from(Array.from({length: between(rand, 0, max)}, () => between(rand, 0, 255)));
}

// A random run of frames and what a correct reader makes of them.
function randomStream(rand) {
  const frames = [];
  const messages = [];
  let sent = "";
  const control = () => {
    const payload = rand() < 0.4 ? Buffer.alloc(0) : randomBytes(rand, 125);
    if (rand() < 0.5) {
      frames.push(clientFrame({opcode: 9, payload}));
      sent += Buffer.concat([Buffer.from([0x8a, payload.length]), payload]).toString("hex");
    } else {
      frames.push(clientFrame({opcode: 10, payload}));
    }
  };
  for (let n = between(rand, 1, 12); n > 0; n--) {
    const kind = rand();
    if (kind < 0.45) {
      const text = randomText(rand);
      messages.push(text);
      frames.push(clientFrame({payload: text}));
    } else if (kind < 0.7) {
      // Fragments may be empty, and may cut a character in half.
      const text = randomText(rand);
      messages.push(text);
      const bytes = Buffer.from(text);
      const points = Array.from({length: between(rand, 1, 4)}, () => between(rand, 0, bytes.length)).sort((x, y) => x - y);
      const parts = [];
      let from = 0;
      for (const point of [...points, bytes.length]) {
        parts.push(bytes.subarray(from, point));
        from = point;
      }
      parts.forEach((part, i) => {
        frames.push(clientFrame({opcode: i === 0 ? 1 : 0, fin: i === parts.length - 1, payload: part}));
        if (i < parts.length - 1 && rand() < 0.5) control();
      });
    } else {
      control();
    }
  }
  let closed = null;
  if (rand() < 0.3) {
    const kind = pick(rand, ["none", "code", "reason"]);
    const payload = kind === "none" ? Buffer.alloc(0)
      : closePayload(pick(rand, [1000, 1001, 3000, 4999]), kind === "reason" ? "bye é" : "");
    frames.push(clientFrame({opcode: 8, payload}));
    sent += kind === "none" ? "8800" : Buffer.concat([Buffer.from([0x88, 2]), payload.subarray(0, 2)]).toString("hex");
    closed = kind === "none" ? 1005 : payload.readUInt16BE(0);
  }
  return {stream: Buffer.concat(frames), messages, sent, closed};
}

function randomCuts(rand, stream) {
  const chunks = [];
  for (let at = 0; at < stream.length;) {
    const size = pick(rand, [1, 1, 2, between(rand, 1, 8), between(rand, 1, 200), between(rand, 1, 70000)]);
    chunks.push(stream.subarray(at, at + size));
    at += size;
  }
  return chunks;
}

test("random frame sequences read the same whole or cut at random, empty payloads included", () => {
  for (let seed = 1; seed <= 300; seed++) {
    const rand = prng(seed);
    const {stream, messages, sent, closed} = randomStream(rand);
    const whole = feed([stream]);
    assert.deepEqual(whole.messages, messages, `seed ${seed}: messages`);
    assert.equal(whole.sent, sent, `seed ${seed}: replies`);
    assert.equal(whole.closed && whole.closed.code, closed === null ? 1006 : closed, `seed ${seed}: close`);
    assert.deepEqual(feed(randomCuts(rand, stream)), whole, `seed ${seed}: random cuts`);
    if (stream.length < 5000) {
      assert.deepEqual(feed(cutBytes(stream)), whole, `seed ${seed}: byte by byte`);
    }
  }
});
