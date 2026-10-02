import test from "node:test";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { daemonFixture } from "./support/daemon.mjs";
import { skip } from "./support/binary.mjs";
import { startClient } from "./support/client.mjs";
import { CALLS, TOOL_NAMES } from "./support/surface.mjs";
import { problems } from "./support/schema.mjs";

// A client that checks structuredContent against a tool's outputSchema does not
// look at isError first, so the schema has to describe the failures the server
// returns as well as the successes. These tests take each tool's schema from
// tools/list and put real results through it, from the built binary.

async function schemas(client) {
  const tools = (await client.request("tools/list")).result.tools;
  return Object.fromEntries(tools.map(tool => [tool.name, tool.outputSchema]));
}

const structured = response => response.result.structuredContent;

// What each tool returns when the daemon answers it, so both a success and a
// refusal can be checked against the one schema. inspect_synth reads three
// commands and apply_parameters checks its acknowledgement, so each needs a
// reply that satisfies them.
const CALL_FOR = { inspect_synth: {}, apply_parameters: { expected_revision: 3, parameters: [{ id: "filter.cutoff", value: 9 }] } };
const calls = [...Object.entries(CALL_FOR).map(([name, args]) => [name, args]), ...CALLS.map(([name, args]) => [name, args])];

function success(command) {
  if (command.startsWith("state.snapshot")) return "ok revision=3 count=1\nid=filter.cutoff value=64";
  if (command.startsWith("patch.current")) return "ok slot=-1 revision=3\nbank=\nname=";
  if (command.startsWith("parameter.list")) return "ok count=1\nid=filter.cutoff group=filter index=19 min=0 max=127 default=81 label=Cutoff";
  if (command.startsWith("parameter.set_many")) return "ok count=1 revision=4";
  return "ok count=2 volume=7\nid=a value=1\n\nname=Lead  Pad";
}

test("the 33 tools each have an outputSchema that is one closed object listing both shapes", {skip}, async t => {
  const daemon = await daemonFixture(t, success);
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const all = await schemas(client);
  assert.deepEqual(Object.keys(all), TOOL_NAMES);
  for (const [name, schema] of Object.entries(all)) {
    assert.equal(schema.type, "object", name);
    assert.equal(schema.additionalProperties, false, name);
    assert.equal(schema.properties.code.type, "string", name);
    assert.equal(schema.properties.message.type, "string", name);
    assert.equal(schema.oneOf.length, 2, name);
    assert.deepEqual(schema.oneOf[1], { required: ["code", "message"] }, name);
    // Every property is declared at the top level; a branch only says which are required.
    for (const branch of schema.oneOf) {
      assert.deepEqual(Object.keys(branch), ["required"], name);
      for (const key of branch.required) assert.ok(key in schema.properties, `${name}: ${key}`);
    }
    assert.equal(schema.properties.code.enum, undefined, `${name}: the daemon's tokens are not enumerated here`);
  }
  assert.deepEqual(all.inspect_synth.oneOf[0].required, ["revision", "state", "patch", "parameters"]);
  assert.deepEqual(all.apply_parameters.oneOf[0].required, ["count", "revision"]);
  for (const name of TOOL_NAMES.filter(n => n !== "inspect_synth" && n !== "apply_parameters")) {
    assert.deepEqual(all[name].oneOf[0].required, ["fields", "lines"], name);
  }
});

test("every tool's real success result satisfies its outputSchema", {skip}, async t => {
  const daemon = await daemonFixture(t, success);
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const all = await schemas(client);
  for (const [name, args] of calls) {
    const response = await client.call(name, args);
    assert.equal(response.result.isError, undefined, `${name}: ${JSON.stringify(response)}`);
    assert.deepEqual(problems(all[name], structured(response)), [], name);
  }
});

test("every tool's real failure result satisfies its outputSchema: a daemon refusal, bad arguments, no daemon", {skip}, async t => {
  const daemon = await daemonFixture(t, () => "err out_of_range value out of range");
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const all = await schemas(client);
  const down = startClient(t, { cwd: tmpdir() });
  await down.initialize();
  for (const [name, args] of calls) {
    const refused = await client.call(name, args);
    assert.equal(refused.result.isError, true, name);
    assert.equal(structured(refused).code, "out_of_range", name);
    assert.deepEqual(problems(all[name], structured(refused)), [], `${name} refused`);

    const invalid = await client.call(name, { ...args, undeclared: 1 });
    // The two older tools ignore a key they do not declare, and then reach the daemon.
    assert.equal(invalid.result.isError, true, name);
    assert.deepEqual(problems(all[name], structured(invalid)), [], `${name} invalid`);

    const absent = await down.call(name, args);
    assert.equal(structured(absent).code, "daemon_unavailable", name);
    assert.deepEqual(problems(all[name], structured(absent)), [], `${name} unavailable`);
  }
});

test("invalid_arguments, daemon_timeout and daemon_error results satisfy the schema too", {skip}, async t => {
  // A daemon that hangs up on one command and never answers another.
  const daemon = await daemonFixture(t, (command, peer) => {
    if (command === "daemon.status") return undefined;
    peer.destroy();
    return undefined;
  });
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const all = await schemas(client);
  const slow = await client.call("daemon_status");
  assert.equal(structured(slow).code, "daemon_timeout");
  assert.deepEqual(problems(all.daemon_status, structured(slow)), []);
  const lost = await client.call("parameter_get", { id: "filter.cutoff" });
  assert.equal(structured(lost).code, "daemon_error");
  assert.deepEqual(problems(all.parameter_get, structured(lost)), []);
  const bad = await client.call("parameter_get", {});
  assert.equal(structured(bad).code, "invalid_arguments");
  assert.deepEqual(problems(all.parameter_get, structured(bad)), []);
});

test("the schema refuses a success with extra keys, a failure without a message, and both shapes at once", async () => {
  const synthetic = {
    type: "object",
    properties: { fields: { type: "string" }, lines: { type: "array", items: { type: "string" } }, code: { type: "string" }, message: { type: "string" } },
    additionalProperties: false,
    oneOf: [{ required: ["fields", "lines"] }, { required: ["code", "message"] }],
  };
  assert.deepEqual(problems(synthetic, { fields: "", lines: [] }), []);
  assert.deepEqual(problems(synthetic, { code: "x", message: "" }), []);
  assert.notDeepEqual(problems(synthetic, { fields: "", lines: [], extra: 1 }), []);
  assert.notDeepEqual(problems(synthetic, { code: "x" }), []);
  assert.notDeepEqual(problems(synthetic, { fields: "", lines: [], code: "x", message: "y" }), []);
  assert.notDeepEqual(problems(synthetic, {}), []);
  assert.notDeepEqual(problems(synthetic, { fields: "", lines: [1] }), []);
});

test("every tool's own schema, from tools/list, refuses those three malformed payloads", {skip}, async t => {
  const daemon = await daemonFixture(t, success);
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  const all = await schemas(client);
  for (const [name, args] of calls) {
    const good = structured(await client.call(name, args));
    assert.deepEqual(problems(all[name], good), [], name);
    assert.notDeepEqual(problems(all[name], { ...good, extra: 1 }), [], `${name}: extra key`);
    assert.notDeepEqual(problems(all[name], { code: "daemon_error" }), [], `${name}: failure without message`);
    assert.notDeepEqual(problems(all[name], { message: "no code" }), [], `${name}: failure without code`);
    assert.notDeepEqual(problems(all[name], { ...good, code: "daemon_error", message: "both" }), [], `${name}: both shapes`);
    assert.notDeepEqual(problems(all[name], {}), [], `${name}: neither shape`);
  }
});
