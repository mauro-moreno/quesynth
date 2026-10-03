import test from "node:test";
import assert from "node:assert/strict";
import {DEFAULTS, connectRaw} from "./support/fake-daemon.mjs";
import {startEnv, unix, until} from "./support/harness.mjs";
import {sleep} from "./support/ws-client.mjs";

const skip = !unix;

async function page(t, options) {
  const env = await startEnv(t, options);
  const ws = await env.open();
  await ws.synced();
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  return {env, ws, peer, daemon: env.daemon};
}

test("a burst of sets never gets a stale value back while the audio thread catches up", {skip}, async t => {
  // A deadline far past the test, so only suppression can keep it quiet.
  const {ws, daemon} = await page(t, {echoMs: 3000});
  daemon.applyMode = "manual";
  for (const value of [10, 20, 30, 40]) ws.send({type: "set", index: 19, value});
  await until(() => daemon.queue.length === 4, 3000, "four queued edits");
  // One edit per poll, so every intermediate value is published and seen.
  for (let i = 0; i < 4; i++) {
    daemon.apply(1);
    await sleep(60);
  }
  assert.equal(daemon.published.values[19], 40);
  assert.deepEqual(ws.drain().filter(m => m.type === "param" || m.type === "state"), []);
});

test("once the deadline passes the daemon's value wins", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {echoMs: 500});
  daemon.applyMode = "manual";
  ws.send({type: "set", index: 19, value: 50});
  await until(() => daemon.queue.length === 1, 3000, "the page's edit");
  await peer.request("parameter.set filter.cutoff 60");
  daemon.apply();
  const started = Date.now();
  assert.deepEqual(await ws.quiet(150, "param"), [], "held back inside the deadline");
  assert.deepEqual(await ws.next("param"), {type: "param", index: 19, value: 60});
  assert.ok(Date.now() - started >= 300, "not before the deadline");
});

test("a value the daemon refuses is reported and the page is put back", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {echoMs: 5000});
  daemon.intercept = req => (req.command === "parameter.set" && req.operands[1] === "100"
    ? {err: ["out_of_range", "value out of range"]} : undefined);
  ws.send({type: "set", index: 19, value: 100});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "set", code: "out_of_range", message: "value out of range"});
  const state = await ws.next("state");
  assert.deepEqual(state.values, daemon.published.values);
  assert.equal(state.values[19], DEFAULTS[19]);
  // The refused write no longer shields the parameter: a change from
  // elsewhere shows at once, well inside the five-second deadline.
  await peer.request("parameter.set filter.cutoff 5");
  assert.deepEqual(await ws.next("param", 1000), {type: "param", index: 19, value: 5});
});

test("a whole patch the daemon refuses is reported and the page is put back", {skip}, async t => {
  const {ws, daemon} = await page(t);
  daemon.intercept = req => (req.command === "patch.apply"
    ? {err: ["daemon_not_ready", "control queue full"]} : undefined);
  const values = DEFAULTS.map((v, i) => (i === 19 ? 3 : v));
  ws.send({type: "state", values});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "state", code: "daemon_not_ready", message: "control queue full"});
  assert.deepEqual((await ws.next("state")).values, daemon.published.values);
  await sleep(40);
  assert.deepEqual(daemon.commands("patch.clear"), [], "the identity is left alone");
});
