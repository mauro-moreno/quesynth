import test from "node:test";
import assert from "node:assert/strict";
import { daemonFixture, frame, synthModel } from "./support/daemon.mjs";
import { skip } from "./support/binary.mjs";
import { errorOf, resultOf, startClient } from "./support/client.mjs";

const apply = { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 40 }] };
const setManyCount = daemon => daemon.commands.filter(command => command.startsWith("parameter.set_many")).length;

test("daemon refusals come through with the daemon's own code and message", {skip}, async t => {
  let refusal = "err daemon_not_ready control queue full";
  const daemon = await daemonFixture(t, () => refusal);
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  assert.deepEqual(errorOf(await client.call("apply_parameters", apply)), { code: "daemon_not_ready", message: "control queue full" });
  refusal = "err transaction_failed too many parameters";
  assert.deepEqual(errorOf(await client.call("apply_parameters", apply)), { code: "transaction_failed", message: "too many parameters" });
  refusal = "err daemon_not_ready no audio";
  assert.deepEqual(errorOf(await client.call("inspect_synth")), { code: "daemon_not_ready", message: "no audio" });
  assert.deepEqual(daemon.commands, ["parameter.set_many expected_revision=0 filter.cutoff 40",
    "parameter.set_many expected_revision=0 filter.cutoff 40", "state.snapshot"]);
});

test("a reply that is not what the tool needs is a daemon_error, not a made-up result", {skip}, async t => {
  const model = synthModel();
  let reply;
  const daemon = await daemonFixture(t, command => reply?.(command) ?? model.answer(command));
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  reply = command => command === "state.snapshot" ? "ok count=0" : undefined;
  assert.equal(errorOf(await client.call("inspect_synth")).code, "daemon_error");
  reply = command => command.startsWith("parameter.set_many") ? "ok" : undefined;
  assert.equal(errorOf(await client.call("apply_parameters", apply)).code, "daemon_error");
  reply = undefined;
  assert.equal(resultOf(await client.call("inspect_synth")).revision, 0);
});

test("a failure in the middle of inspect_synth stops it there", {skip}, async t => {
  const model = synthModel();
  const daemon = await daemonFixture(t, (command, peer) => {
    if (command !== "patch.current") return model.answer(command);
    peer.end();
    return undefined;
  });
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  assert.equal(errorOf(await client.call("inspect_synth")).code, "daemon_error");
  assert.deepEqual(daemon.commands, ["state.snapshot", "patch.current"]);
});

test("timeouts and broken replies never replay a mutation and a later call recovers", {skip}, async t => {
  const model = synthModel();
  let behavior = "ok";
  const daemon = await daemonFixture(t, (command, peer, id) => {
    switch (behavior) {
      case "hang": return undefined;
      case "disconnect": peer.end(); return undefined;
      case "malformed": peer.write(Buffer.from([1, 0, 0, 0, 0])); return undefined;
      case "oversized": peer.write(Buffer.from([1, 0, 1, 0])); return undefined;
      case "mismatch": peer.write(frame(`1 ${id + 1} ok count=1 revision=1`)); return undefined;
      default: return model.answer(command);
    }
  });
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  const expected = { hang: "daemon_timeout", disconnect: "daemon_error", malformed: "daemon_error", oversized: "daemon_error", mismatch: "daemon_error" };

  let sent = 0;
  for (const mode of Object.keys(expected)) {
    behavior = mode;
    const started = Date.now();
    const error = errorOf(await client.call("apply_parameters", apply));
    assert.equal(error.code, expected[mode], mode);
    assert.ok(Date.now() - started < 3000, `${mode} took ${Date.now() - started} ms`);
    // The request was written, so the outcome is unknown and the message says so.
    assert.match(error.message, /request was sent and the change may have been applied/, mode);
    assert.equal(setManyCount(daemon), ++sent, `${mode}: mutation sent once, never replayed`);

    const read = errorOf(await client.call("inspect_synth"));
    assert.equal(read.code, expected[mode], `${mode} on a read`);
    assert.doesNotMatch(read.message, /may have been applied/, `${mode}: a read changes nothing`);
    behavior = "ok";
    assert.equal(resultOf(await client.call("inspect_synth")).revision, 0, `recovered after ${mode}`);
  }
  assert.equal(setManyCount(daemon), sent);
  assert.equal(model.revision, 0);
});

test("a request over the QCP frame limit is refused locally and the server keeps working", {skip}, async t => {
  const model = synthModel();
  const daemon = await daemonFixture(t, model.answer);
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  const huge = { expected_revision: 0, parameters: [{ id: "x".repeat(70_000), value: 1 }] };
  const refused = errorOf(await client.call("apply_parameters", huge));
  assert.equal(refused.code, "daemon_error");
  assert.doesNotMatch(refused.message, /may have been applied/, "nothing was sent");
  assert.deepEqual(daemon.commands, []);
  assert.equal(resultOf(await client.call("inspect_synth")).revision, 0);
});

test("the server survives the daemon going away and coming back", {skip}, async t => {
  const daemon = await daemonFixture(t, synthModel().answer);
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  assert.equal(resultOf(await client.call("inspect_synth")).revision, 0);
  await daemon.stop();
  assert.equal(errorOf(await client.call("inspect_synth")).code, "daemon_unavailable");
  assert.equal(errorOf(await client.call("apply_parameters", apply)).code, "daemon_unavailable");
  assert.deepEqual((await client.request("ping")).result, {});
  await daemon.start();
  assert.equal(resultOf(await client.call("inspect_synth")).revision, 0);
  assert.deepEqual(resultOf(await client.call("apply_parameters", apply)), { count: 1, revision: 1 });
});
