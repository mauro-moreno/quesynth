import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import {connectRaw} from "./support/fake-daemon.mjs";
import {startEnv, strayTempDirs, unix, until} from "./support/harness.mjs";
import {TestSocket, clientFrame, sleep, upgradeRequest} from "./support/ws-client.mjs";

const skip = !unix;

test("the upgrade is refused with 503 when there is no daemon socket", {skip}, async t => {
  const env = await startEnv(t);
  await env.daemon.stop();
  const refused = await env.open();
  assert.equal(refused.status, 503);
  assert.match(refused.text, /daemon unavailable/);
  assert.equal(env.bridge.sessions, 0);
});

test("the upgrade is refused with 503 when the daemon is at its connection cap", {skip}, async t => {
  const env = await startEnv(t, {daemon: {maxConnections: 1}});
  const peer = await connectRaw(env.socketPath);
  assert.equal((await env.open()).status, 503);
  assert.ok(env.daemon.refused >= 1, "the daemon turned the adapter away");
  peer.close();
  await until(() => env.daemon.connections.size === 0, 3000, "the peer to leave");
  const ws = await env.open();
  assert.ok(ws instanceof TestSocket);
  await ws.synced();
});

test("an abrupt browser reset mid-frame closes that page's daemon connection", {skip}, async t => {
  const env = await startEnv(t);
  const ws = await env.open();
  await ws.synced();
  assert.equal(env.daemon.connections.size, 1);
  ws.sendRaw(clientFrame({payload: JSON.stringify({type: "set", index: 19, value: 1})}).subarray(0, 5));
  await sleep(20);
  ws.socket.resetAndDestroy();
  await until(() => env.daemon.connections.size === 0, 3000, "the daemon connection to close");
  await until(() => env.bridge.sessions === 0, 3000, "the session to go");
  const next = await env.open();
  await next.synced();
});

test("a daemon killed mid-session closes the page with 1011; later pages get 503 until it returns", {skip}, async t => {
  const env = await startEnv(t);
  const ws = await env.open();
  await ws.synced();
  await env.daemon.stop();
  assert.equal((await ws.closed).code, 1011);
  assert.equal((await env.open()).status, 503);
  assert.equal((await env.open()).status, 503);
  await env.daemon.start();
  const back = await env.open();
  assert.ok(back instanceof TestSocket, "reconnects once the daemon is back");
  await back.synced();
});

for (const [fault, what] of [["garbage", "a garbage frame"], ["oversize", "an oversized frame"]]) {
  test(`a daemon answering with ${what} closes the session cleanly`, {skip}, async t => {
    const env = await startEnv(t);
    const ws = await env.open();
    await ws.synced();
    env.daemon.intercept = req => (req.command === "patch.current" ? fault : undefined);
    assert.equal((await ws.closed).code, 1011);
    await until(() => env.daemon.connections.size === 0, 3000, "the daemon connection to close");
    env.daemon.intercept = null;
    const next = await env.open();
    await next.synced();
  });
}

test("a daemon that never answers times the session out and leaves nothing behind", {skip}, async t => {
  const env = await startEnv(t, {requestTimeoutMs: 200});
  const ws = await env.open();
  await ws.synced();
  // Hung in the middle of a bank dump, when a temporary directory exists.
  env.daemon.intercept = req => (req.command === "bank.write" ? "hang" : undefined);
  const started = Date.now();
  ws.send({type: "sync"});
  assert.equal((await ws.closed).code, 1011);
  assert.ok(Date.now() - started < 2000, "gave up after the request timeout");
  await until(() => env.daemon.connections.size === 0, 3000, "the daemon connection to close");
  assert.equal(env.bridge.sessions, 0);
  assert.deepEqual(strayTempDirs(), []);
});

test("a page that leaves while its daemon connection is opening leaves nothing behind", {skip}, async t => {
  const env = await startEnv(t, {requestTimeoutMs: 5000});
  env.daemon.intercept = req => (req.command === "parameter.list" ? "hang" : undefined);
  const socket = net.createConnection(env.port, "127.0.0.1");
  socket.on("error", () => {});
  socket.write(upgradeRequest(env.port));
  await until(() => env.daemon.connections.size === 1, 3000, "the adapter to reach the daemon");
  socket.destroy();
  // Well inside the five-second request timeout: the page leaving is noticed.
  await until(() => env.daemon.connections.size === 0, 2500, "the half-open daemon connection to close");
});

test("many pages opening and closing leave no daemon connections", {skip}, async t => {
  const env = await startEnv(t);
  const pages = [];
  for (let i = 0; i < 12; i++) pages.push(await env.open());
  await Promise.all(pages.map(p => p.synced()));
  assert.equal(env.daemon.connections.size, 12);
  pages.forEach((p, i) => (i % 2 ? p.destroy() : p.close()));
  for (let i = 0; i < 20; i++) {
    const p = await env.open();
    if (i % 2) p.send({type: "sync"});
    if (i % 3) p.destroy();
    else await p.close();
  }
  await until(() => env.daemon.connections.size === 0, 3000, "every daemon connection to close");
  await until(() => env.bridge.sessions === 0, 3000, "every session to go");
  assert.deepEqual(strayTempDirs(), []);
});

test("an unexpected error in one page closes that page only", {skip}, async t => {
  const env = await startEnv(t);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  const healthy = await env.open();
  await healthy.synced();
  const broken = await env.open();
  // The daemon says it wrote the bank and did not, so reading it back fails
  // with an error that is neither a daemon answer nor a lost connection.
  env.daemon.intercept = req => (req.command === "bank.write" ? {answer: "ok bytes=0"} : undefined);
  broken.send({type: "sync"});
  assert.deepEqual(await broken.closed, {code: 1011, reason: "adapter error"});
  assert.ok(env.logs.some(l => l.startsWith("browser session error")), "the fault is logged");
  env.daemon.intercept = null;
  await peer.request("parameter.set filter.cutoff 9");
  assert.deepEqual(await healthy.next("param"), {type: "param", index: 19, value: 9});
  assert.equal(env.bridge.sessions, 1);
  assert.deepEqual(strayTempDirs(), []);
});
