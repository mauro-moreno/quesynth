import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {ROOT} from "./support/fake-daemon.mjs";

const SOURCE = fs.readFileSync(path.join(ROOT, "hosts", "standalone", "browser", "host.js"), "utf8");
const SYNC = '{"type":"sync"}';

// A page with host.js loaded into it, where the test plays the network and
// the clock.
function boot() {
  const sockets = [];
  const timers = [];
  const warnings = [];
  const received = [];
  const listeners = {};

  class FakeWebSocket {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.sent = [];
      this.handlers = {};
      sockets.push(this);
    }
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
    send(text) {
      if (this.readyState !== 1) throw new Error("send on a socket that is not open");
      this.sent.push(text);
    }
    close() { this.readyState = 3; this.closedByPage = true; }
    fire(type, event = {}) { for (const fn of this.handlers[type] || []) fn(event); }
    accept() { this.readyState = 1; this.fire("open"); }
    deliver(data) { this.fire("message", {data}); }
    lose() {
      this.readyState = 3;
      this.fire("error");
      this.fire("close", {code: 1006});
    }
  }

  const window = {
    document: {documentElement: {dataset: {}}},
    location: {protocol: "http:", host: "127.0.0.1:8177"},
    WebSocket: FakeWebSocket,
    JSON,
    console: {warn: (...args) => warnings.push(args)},
    setTimeout(fn, ms) {
      timers.push({fn, ms, live: true});
      return timers.length;
    },
    clearTimeout(id) {
      if (timers[id - 1]) timers[id - 1].live = false;
    },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    synthReceive: text => received.push(text),
  };
  window.window = window;
  vm.runInNewContext(SOURCE, window, {filename: "host.js"});

  return {
    window,
    sockets,
    warnings,
    received,
    get socket() { return sockets[sockets.length - 1]; },
    live() { return timers.filter(t => t.live); },
    // Fire the one pending reconnect timer and return its delay.
    tick() {
      const pending = timers.filter(t => t.live);
      assert.equal(pending.length, 1, "exactly one reconnect timer pending");
      pending[0].live = false;
      pending[0].fn();
      return pending[0].ms;
    },
    dispatch(type, event = {}) { for (const fn of listeners[type] || []) fn(event); },
    post(msg) { window.synthPost(JSON.stringify(msg)); },
  };
}

test("messages posted before the first open are queued, then sent in order after one sync", () => {
  const page = boot();
  assert.equal(page.socket.url, "ws://127.0.0.1:8177/control");
  page.post({type: "volume", value: 0.64});
  page.post({type: "sync"});
  page.post({type: "set", index: 19, value: 80});
  page.post({type: "cc", cc: 1, value: 3});
  page.socket.accept();
  assert.deepEqual(page.socket.sent.map(s => JSON.parse(s).type), ["sync", "volume", "set", "cc"],
    "the page's own queued sync is folded into the one sent on open");
  page.post({type: "note", on: true, note: 60, velocity: 1});
  assert.equal(JSON.parse(page.socket.sent[4]).type, "note", "sent at once when open");
});

test("the queue before the first open is bounded, dropping the oldest", () => {
  const page = boot();
  for (let i = 0; i < 300; i++) page.post({type: "set", index: 19, value: i});
  page.socket.accept();
  const values = page.socket.sent.slice(1).map(s => JSON.parse(s).value);
  assert.equal(values.length, 256);
  assert.equal(values[0], 44);
  assert.equal(values[255], 299);
});

test("every open, first or later, starts with a sync", () => {
  const page = boot();
  page.socket.accept();
  assert.deepEqual(page.socket.sent, [SYNC]);
  page.socket.lose();
  page.tick();
  page.socket.accept();
  assert.deepEqual(page.socket.sent, [SYNC]);
  assert.equal(page.sockets.length, 2);
});

test("messages posted while disconnected after the first open are dropped, never replayed", () => {
  const page = boot();
  page.socket.accept();
  page.socket.lose();
  page.post({type: "set", index: 19, value: 5});
  page.tick();
  page.post({type: "set", index: 19, value: 6});
  assert.equal(page.socket.readyState, 0, "still connecting");
  page.socket.accept();
  assert.deepEqual(page.socket.sent, [SYNC]);
});

test("reconnection backs off from 250 ms to a 5 s cap, and resets after a working connection", () => {
  const page = boot();
  const delays = [];
  for (let i = 0; i < 7; i++) {
    page.socket.lose();
    delays.push(page.tick());
  }
  assert.deepEqual(delays, [250, 500, 1000, 2000, 4000, 5000, 5000]);

  // Accepted and dropped at once, as when the daemon refuses the sync: no
  // reset, or a broken daemon would be retried four times a second.
  page.socket.accept();
  page.socket.lose();
  assert.equal(page.tick(), 5000);

  page.socket.accept();
  page.socket.deliver('{"type":"bank","text":"{}"}');
  page.socket.lose();
  assert.equal(page.tick(), 250);
});

test("hostError is set when the connection drops and cleared when it opens", () => {
  const page = boot();
  const dataset = page.window.document.documentElement.dataset;
  assert.equal(dataset.hostError, undefined);
  page.socket.lose();
  assert.equal(dataset.hostError, "daemon");
  page.tick();
  assert.equal(dataset.hostError, "daemon", "still down while connecting");
  page.socket.accept();
  assert.equal("hostError" in dataset, false);
  page.socket.fire("error");
  assert.equal(dataset.hostError, "daemon");
});

test("error messages from the adapter are logged with console.warn", () => {
  const page = boot();
  page.socket.accept();
  const text = '{"type":"error","for":"set","code":"out_of_range","message":"value out of range"}';
  page.socket.deliver(text);
  assert.deepEqual(page.warnings, [["quesynth daemon:", "set", "out_of_range", "value out of range"]]);
  assert.deepEqual(page.received, [text], "still passed on; the panel ignores the type");
});

test("frames that are not strings, or not JSON, are ignored without throwing", () => {
  const page = boot();
  page.socket.accept();
  assert.doesNotThrow(() => {
    page.socket.deliver(new ArrayBuffer(4));
    page.socket.deliver(undefined);
    page.socket.deliver('{"type":"error", broken');
  });
  assert.deepEqual(page.warnings, []);
  assert.deepEqual(page.received, ['{"type":"error", broken'], "only the string reached the panel");
});

test("pagehide closes the socket and leaves no timer running; pageshow from the cache reconnects", () => {
  const page = boot();
  page.socket.accept();
  page.socket.lose();
  assert.equal(page.live().length, 1);
  page.dispatch("pagehide");
  assert.equal(page.live().length, 0);
  assert.equal(page.sockets.length, 1, "no reconnection after pagehide");

  const other = boot();
  other.socket.accept();
  other.dispatch("pagehide");
  assert.equal(other.socket.closedByPage, true);
  other.socket.fire("close", {code: 1005});
  assert.equal(other.live().length, 0, "its close does not schedule a reconnect");
  other.dispatch("pageshow", {persisted: true});
  assert.equal(other.sockets.length, 2);
  other.socket.accept();
  assert.deepEqual(other.socket.sent, [SYNC]);
});
