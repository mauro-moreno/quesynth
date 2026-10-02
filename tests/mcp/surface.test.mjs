import test from "node:test";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { daemonFixture } from "./support/daemon.mjs";
import { skip } from "./support/binary.mjs";
import { startClient } from "./support/client.mjs";
import { CALLS } from "./support/surface.mjs";

// One call of every tool through the built binary, over stdio, against a
// stand-in daemon that answers each request with a reply the test chose. What
// the daemon receives is the line a QCP client would send; what the client
// receives is the daemon's reply, or its refusal, in the shape the tool lists.

const REPLY = "ok count=2  volume=7 \nid=a value=1 \n\nname=Lead  Pad  \u00e9\n";
const RECORDS = { fields: "count=2  volume=7 ", lines: ["id=a value=1 ", "", "name=Lead  Pad  \u00e9"] };

// 2024-11-05 has no structured content; 2025-06-18 and after do.
for (const version of ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]) {
  const structured = version >= "2025-06-18";

  test(`every tool returns the daemon's reply untouched as fields and lines (${version})`, {skip}, async t => {
    const daemon = await daemonFixture(t, () => REPLY);
    const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
    await client.initialize(version);
    for (const [name, args, line] of CALLS) {
      const before = daemon.commands.length;
      const { result } = await client.call(name, args);
      assert.deepEqual(daemon.commands.slice(before), [line], name);
      assert.equal(result.isError, undefined, name);
      assert.deepEqual(JSON.parse(result.content[0].text), RECORDS, name);
      assert.equal(result.content.length, 1, name);
      if (structured) assert.deepEqual(result.structuredContent, RECORDS, name);
      else assert.equal(result.structuredContent, undefined, name);
    }
  });

  test(`every tool returns the daemon's refusal as a code and a message, flagged as an error (${version})`, {skip}, async t => {
    const daemon = await daemonFixture(t, () => "err daemon_not_ready no bank,  really");
    const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
    await client.initialize(version);
    for (const [name, args] of CALLS) {
      const { result } = await client.call(name, args);
      const failure = { code: "daemon_not_ready", message: "no bank,  really" };
      assert.equal(result.isError, true, name);
      assert.deepEqual(JSON.parse(result.content[0].text), failure, name);
      if (structured) assert.deepEqual(result.structuredContent, failure, name);
      else assert.equal(result.structuredContent, undefined, name);
    }
  });
}

test("a call that fails validation sends nothing, for every tool", {skip}, async t => {
  const daemon = await daemonFixture(t, () => "ok");
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  for (const [name, args] of CALLS) {
    // An argument the tool does not declare, then each declared one given a
    // value of a type it does not take.
    const calls = [{ ...args, undeclared: 1 }];
    for (const key of Object.keys(args)) {
      const { [key]: _, ...rest } = args;
      // An optional argument may be left out; a required one may not.
      calls.push({ ...rest, [key]: null }, { ...rest, [key]: {} }, { ...rest, [key]: [] }, { ...rest, [key]: true });
    }
    for (const call of calls) {
      const { result } = await client.call(name, call);
      assert.equal(result.isError, true, `${name} ${JSON.stringify(call)}`);
      assert.equal(JSON.parse(result.content[0].text).code, "invalid_arguments", `${name} ${JSON.stringify(call)}`);
    }
  }
  assert.deepEqual(daemon.commands, []);
});

test("with no daemon every tool says so, and says nothing about a change", {skip}, async t => {
  const client = startClient(t, { cwd: tmpdir() });
  await client.initialize();
  for (const [name, args] of CALLS) {
    const { result } = await client.call(name, args);
    assert.equal(result.isError, true, name);
    const failure = JSON.parse(result.content[0].text);
    assert.equal(failure.code, "daemon_unavailable", name);
    assert.ok(!failure.message.includes("may have been applied"), name);
  }
});

test("a change lost after it was sent is said to be unsure and is sent once; a read is not", {skip}, async t => {
  const daemon = await daemonFixture(t, (command, peer) => {
    peer.destroy();
    return undefined;
  });
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const readOnly = new Set(["daemon_status", "daemon_info", "parameter_list", "parameter_get", "state_snapshot", "patch_current",
    "bank_list", "archive_current", "archive_banks", "archive_patches", "midi_list", "midi_current"]);
  for (const [name, args, line] of CALLS) {
    const before = daemon.commands.length;
    const { result } = await client.call(name, args);
    assert.deepEqual(daemon.commands.slice(before), [line], `${name} was sent once`);
    const failure = JSON.parse(result.content[0].text);
    assert.equal(failure.code, "daemon_error", name);
    assert.equal(failure.message.includes("the change may have been applied"), !readOnly.has(name), `${name}: ${failure.message}`);
  }
});
