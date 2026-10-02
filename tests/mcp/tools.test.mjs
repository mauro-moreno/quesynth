import test from "node:test";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { readFileSync } from "node:fs";
import { daemonFixture, synthModel } from "./support/daemon.mjs";
import { CALLS, TOOL_NAMES, annotationsOf, handlerCommands } from "./support/surface.mjs";
import { skip } from "./support/binary.mjs";
import { errorOf, resultOf, startClient } from "./support/client.mjs";

const SET_MANY = "parameter.set_many";

async function ready(t, model = synthModel(), answer = model.answer) {
  const daemon = await daemonFixture(t, answer);
  // Not the repository root: the launch must not depend on the working directory.
  const client = startClient(t, { runtime: daemon.runtime, cwd: tmpdir() });
  await client.initialize();
  return { daemon, client, model };
}

test("the tools are the thirty-three of the control protocol, with no way to send a command", {skip}, async t => {
  const { client } = await ready(t);
  const tools = (await client.request("tools/list")).result.tools;
  assert.deepEqual(tools.map(tool => tool.name), TOOL_NAMES);
  for (const tool of tools) {
    assert.equal(tool.inputSchema.type, "object", tool.name);
    assert.deepEqual(tool.annotations, annotationsOf(tool.name), tool.name);
    assert.equal(typeof tool.description, "string", tool.name);
    assert.equal(tool.outputSchema.type, "object", tool.name);
  }
  // The two older tools are described exactly as they always were.
  const [inspect, apply] = ["inspect_synth", "apply_parameters"].map(name => tools.find(tool => tool.name === name));
  assert.deepEqual(inspect.inputSchema, { type: "object", properties: {} });
  assert.deepEqual(apply.inputSchema, {
    type: "object", required: ["expected_revision", "parameters"],
    properties: {
      expected_revision: { type: "integer", minimum: 0 },
      parameters: {
        type: "array",
        items: { type: "object", required: ["id", "value"], properties: { id: { type: "string" }, value: { type: "integer" } } },
      },
    },
  });
  // Every other tool closes its arguments, and none of them is a command.
  for (const tool of tools.slice(2)) {
    assert.equal(tool.inputSchema.additionalProperties, false, tool.name);
    for (const key of Object.keys(tool.inputSchema.properties)) {
      assert.ok(!/^(command|cmd|verb|line|raw|qcp|request|operands?|args|argv|arguments|shell|exec|script|url|host|port|payload)$/.test(key), `${tool.name}.${key}`);
    }
  }
});

test("every command the daemon dispatches on has exactly one tool, and each tool sends its own", {skip}, async t => {
  const { daemon, client } = await ready(t, synthModel(), () => "ok");
  const commands = handlerCommands(readFileSync(new URL("../../hosts/standalone/command_handler.odin", import.meta.url), "utf8"));
  assert.equal(commands.length, 31);
  assert.deepEqual(CALLS.map(([, , line]) => line.split(" ")[0]).sort(), [...commands].sort());
  assert.deepEqual(CALLS.map(([name]) => name), TOOL_NAMES.slice(2));
  for (const [name, args, line] of CALLS) {
    const before = daemon.commands.length;
    resultOf(await client.call(name, args));
    assert.deepEqual(daemon.commands.slice(before), [line], name);
  }
});

test("inspect_synth reads the daemon's snapshot, patch and registry and keeps its records verbatim", {skip}, async t => {
  const model = synthModel();
  model.revision = 6;
  model.values["filter.cutoff"] = 99;
  model.patch = "slot=3 bank_rev=2 revision=6 source=bank archive_rev=5 archive_bank=-1 archive_patch=-1\n" +
    "bank=  My Bank = x \nname=Ünicode  Name = value  ";
  const { daemon, client } = await ready(t, model);
  const result = resultOf(await client.call("inspect_synth"));
  assert.deepEqual(daemon.commands, ["state.snapshot", "patch.current", "parameter.list"]);
  assert.equal(result.revision, 6);
  assert.deepEqual(result.state, {
    fields: "revision=6 count=3",
    lines: ["id=filter.cutoff value=99", "id=filter.resonance value=0", "id=osc1.shape value=2"],
  });
  assert.deepEqual(result.patch, {
    fields: "slot=3 bank_rev=2 revision=6 source=bank archive_rev=5 archive_bank=-1 archive_patch=-1",
    lines: ["bank=  My Bank = x ", "name=Ünicode  Name = value  "],
  });
  assert.deepEqual(result.parameters, {
    fields: "count=3",
    lines: [
      "id=filter.cutoff group=filter index=19 min=0 max=127 default=81 label=Cutoff",
      "id=filter.resonance group=filter index=20 min=0 max=127 default=0 label=Resonance",
      "id=osc1.shape group=osc1 index=0 min=0 max=3 default=2 label=Shape",
    ],
  });
});

test("the resources read the same daemon state", {skip}, async t => {
  const model = synthModel();
  model.revision = 4;
  const { daemon, client } = await ready(t, model);
  const read = async uri => {
    const { contents } = (await client.request("resources/read", { uri })).result;
    assert.equal(contents.length, 1);
    assert.equal(contents[0].uri, uri);
    assert.equal(contents[0].mimeType, "application/json");
    return JSON.parse(contents[0].text);
  };

  const parameters = await read("quesynth://parameters");
  assert.deepEqual(daemon.commands, ["parameter.list"]);
  assert.equal(parameters.lines.length, 3);
  assert.equal(parameters.lines[0], "id=filter.cutoff group=filter index=19 min=0 max=127 default=81 label=Cutoff");

  daemon.commands.length = 0;
  const patch = await read("quesynth://patch");
  assert.deepEqual(daemon.commands, ["state.snapshot", "patch.current"]);
  assert.equal(patch.revision, 4);
  assert.equal(patch.patch.lines[0], "bank=");
  assert.equal(patch.state.lines.length, 3);
});

test("apply_parameters sends the whole batch in one command and moves the revision once", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const before = resultOf(await client.call("inspect_synth")).revision;
  assert.equal(before, 0);
  daemon.commands.length = 0;
  const applied = resultOf(await client.call("apply_parameters", {
    expected_revision: before,
    parameters: [{ id: "filter.cutoff", value: 40 }, { id: "filter.resonance", value: 20 }],
  }));
  assert.deepEqual(applied, { count: 2, revision: 1 });
  assert.deepEqual(daemon.commands, [`${SET_MANY} expected_revision=0 filter.cutoff 40 filter.resonance 20`]);
  assert.deepEqual(model.values, { "filter.cutoff": 40, "filter.resonance": 20, "osc1.shape": 2 });

  const after = resultOf(await client.call("inspect_synth"));
  assert.equal(after.revision, applied.revision);
  assert.deepEqual(after.state.lines.slice(0, 2), ["id=filter.cutoff value=40", "id=filter.resonance value=20"]);
});

test("a stale expected_revision is refused and the daemon's state is unchanged", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const edit = value => ({ expected_revision: 0, parameters: [{ id: "filter.cutoff", value }] });
  assert.deepEqual(resultOf(await client.call("apply_parameters", edit(40))), { count: 1, revision: 1 });

  const conflict = errorOf(await client.call("apply_parameters", edit(80)));
  assert.equal(conflict.code, "revision_conflict");
  assert.match(JSON.stringify(conflict), /current_revision\D+1\b/);
  assert.equal(model.revision, 1);
  assert.equal(model.values["filter.cutoff"], 40);
  // The refusal came from the daemon after one command; the MCP did not retry or reread.
  assert.equal(daemon.commands.filter(command => command.startsWith(SET_MANY)).length, 2);

  // Retrying with the revision the daemon reported succeeds.
  assert.deepEqual(
    resultOf(await client.call("apply_parameters", { ...edit(80), expected_revision: 1 })),
    { count: 1, revision: 2 },
  );
});

test("order and duplicate ids are forwarded as given and the daemon decides which wins", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const applied = resultOf(await client.call("apply_parameters", {
    expected_revision: 0,
    parameters: [{ id: "osc1.shape", value: 1 }, { id: "filter.cutoff", value: 5 }, { id: "osc1.shape", value: 3 }],
  }));
  assert.deepEqual(applied, { count: 3, revision: 1 });
  assert.equal(daemon.commands.at(-1), `${SET_MANY} expected_revision=0 osc1.shape 1 filter.cutoff 5 osc1.shape 3`);
  assert.equal(model.values["osc1.shape"], 3);
});

test("integer-valued numbers and Unicode ids reach the daemon as written", {skip}, async t => {
  const { daemon, client } = await ready(t, synthModel(), () => "ok count=2 revision=1");
  client.write(JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "apply_parameters", arguments: { expected_revision: 0, parameters: [] } },
  }).replace("[]", '[{"id":"a","value":1.0},{"id":"caf\u00e9\u00a1","value":1e2},{"id":"b","value":-5}]') + "\n");
  const [reply] = await client.take();
  assert.equal(reply.result.isError, undefined, JSON.stringify(reply));
  assert.deepEqual(daemon.commands, [`${SET_MANY} expected_revision=0 a 1 caf\u00e9\u00a1 100 b -5`]);
});

test("the daemon's own refusals come through verbatim and nothing is checked locally", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const apply = parameters => client.call("apply_parameters", { expected_revision: 0, parameters });
  assert.deepEqual(errorOf(await apply([{ id: "filter.cutoff", value: 5 }, { id: "filter.cutoff", value: 200 }])),
    { code: "out_of_range", message: "filter.cutoff" });
  assert.deepEqual(errorOf(await apply([{ id: "no.such", value: 1 }])), { code: "unknown_parameter", message: "no.such" });
  assert.equal(daemon.commands.filter(command => command.startsWith(SET_MANY)).length, 2);
  assert.equal(model.revision, 0);
  assert.equal(model.values["filter.cutoff"], 81);
});

test("an empty parameters array is never reported as applied", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const error = errorOf(await client.call("apply_parameters", { expected_revision: 0, parameters: [] }));
  assert.ok(["invalid_arguments", "invalid_payload"].includes(error.code), error.code);
  assert.deepEqual(daemon.commands.filter(command => !command.startsWith(SET_MANY + " expected_revision=0")), []);
  assert.equal(model.revision, 0);
});

test("invalid arguments never reach the daemon", {skip}, async t => {
  const { daemon, client } = await ready(t);
  const ok = { id: "filter.cutoff", value: 1 };
  const separators = [" ", "\t", "\n", "\r", "\u000b", "\u000c", "\u0000", "\u0001", "\u001b", "\u001f", "\u007f",
    "\u0080", "\u0085", "\u009f", "\u00a0", "\u1680", "\u2000", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000"];
  const invalid = [
    {},
    { parameters: [ok] },
    { expected_revision: 0 },
    ...[-1, 1.5, "0", null, true, [0], {}].map(expected_revision => ({ expected_revision, parameters: [ok] })),
    ...[{}, "x", null, 5, true].map(parameters => ({ expected_revision: 0, parameters })),
    ...[5, null, "a", [], [[]]].map(entry => ({ expected_revision: 0, parameters: [entry] })),
    ...[{ value: 1 }, { id: "a" }, { id: 5, value: 1 }, { id: null, value: 1 }, { id: "", value: 1 },
      { id: "a", value: "1" }, { id: "a", value: 1.5 }, { id: "a", value: null }, { id: "a", value: true },
      { id: "a", value: [1] }, { id: "a", value: {} }].map(entry => ({ expected_revision: 0, parameters: [ok, entry] })),
    ...separators.flatMap(c => [`a${c}b`, `${c}a`, `a${c}`, c].map(id => ({ expected_revision: 0, parameters: [{ id, value: 1 }] }))),
  ];
  for (const args of invalid) {
    const error = errorOf(await client.call("apply_parameters", args));
    assert.equal(error.code, "invalid_arguments", JSON.stringify(args));
  }
  for (const args of [[], "x", null]) {
    const response = await client.request("tools/call", { name: "apply_parameters", arguments: args });
    assert.equal(errorOf(response).code, "invalid_arguments", JSON.stringify(args));
  }
  assert.equal(errorOf(await client.request("tools/call", { name: "apply_parameters" })).code, "invalid_arguments");
  assert.deepEqual(daemon.commands, []);
});

// JSON.parse and the library parser of the server differ on one thing: a member
// named "" is kept by one and dropped by the other, and a call that spelt one
// must not be read as though it had not. The schemas close the arguments and
// the pairs, so it is refused as any other name that is not declared.
test("an argument or a pair key named with the empty string is refused as unknown and nothing reaches the daemon", {skip}, async t => {
  const { daemon, client, model } = await ready(t);
  const refusal = async (name, args) => errorOf(await client.call(name, args));
  const ok = { id: "filter.cutoff", value: 90 };
  const unknownArgument = { code: "invalid_arguments", message: "unknown argument: " };

  assert.deepEqual(await refusal("daemon_status", { "": 1 }), unknownArgument);
  assert.deepEqual(await refusal("parameter_get", { id: "filter.cutoff", "": 1 }), unknownArgument);
  assert.deepEqual(await refusal("parameter_get", { "": "x" }), unknownArgument);
  assert.deepEqual(await refusal("volume", { milli: 5, "": 0 }), unknownArgument);
  for (const tool of ["parameter_set_many", "patch_apply"]) {
    assert.deepEqual(await refusal(tool, { parameters: [{ ...ok, "": 0 }] }),
      { code: "invalid_arguments", message: "parameters[0] has an unknown key: " }, tool);
    assert.deepEqual(await refusal(tool, { parameters: [ok, { ...ok, "": 0 }] }),
      { code: "invalid_arguments", message: "parameters[1] has an unknown key: " }, tool);
    assert.deepEqual(await refusal(tool, { parameters: [ok], "": 0 }), unknownArgument, tool);
  }
  assert.deepEqual(await refusal("parameter_set_many", { expected_revision: 0, parameters: [{ ...ok, "": 0 }] }),
    { code: "invalid_arguments", message: "parameters[0] has an unknown key: " });

  // The same names written out, with a duplicate that JSON.stringify cannot make.
  const line = text => `{"jsonrpc":"2.0","id":901,"method":"tools/call","params":${text}}\n`;
  for (const [params, message] of [
    ['{"name":"daemon_status","arguments":{"":1,"":2}}', "unknown argument: "],
    ['{"name":"daemon_status","\\u0061rguments":{"":1}}', "unknown argument: "],
    ['{"arguments":{"":1},"name":"daemon_status"}', "unknown argument: "],
    ['{"name":"parameter_set_many","arguments":{"par\\u0061meters":[{"id":"filter.cutoff","value":1,"":0}]}}', "parameters[0] has an unknown key: "],
  ]) {
    client.write(line(params));
    const [reply] = await client.take();
    assert.deepEqual(errorOf(reply), { code: "invalid_arguments", message }, params);
  }

  // Nothing was applied, and nothing was sent.
  assert.equal(model.revision, 0);
  assert.equal(model.values["filter.cutoff"], 81);
  assert.deepEqual(daemon.commands, []);
});

test("an empty member name elsewhere in a request is accepted, and the older tools ignore it as they ignore any name", {skip}, async t => {
  const model = synthModel();
  const { daemon, client } = await ready(t, model, command => (command === "daemon.status" ? "ok" : model.answer(command)));
  assert.deepEqual(resultOf(await client.request("tools/call", { name: "daemon_status", arguments: {}, _meta: { "": 1 } })), { fields: "", lines: [] });
  assert.deepEqual(resultOf(await client.request("tools/call", { name: "daemon_status", arguments: {}, "": 1 })), { fields: "", lines: [] });
  assert.deepEqual(resultOf(await client.request("tools/call", { name: "daemon_status", arguments: {}, _meta: { arguments: { "": 1 } } })), { fields: "", lines: [] });
  assert.equal(resultOf(await client.call("inspect_synth", { "": 1 })).revision, 0);
  assert.deepEqual(resultOf(await client.call("apply_parameters", { expected_revision: 0, "": 1, parameters: [{ id: "filter.cutoff", value: 4, "": 0 }] })), { count: 1, revision: 1 });
  assert.equal(daemon.commands.filter(command => command === "daemon.status").length, 3);

  const fresh = startClient(t);
  const initialized = await fresh.request("initialize", {
    protocolVersion: "2025-11-25", capabilities: { "": {} }, clientInfo: { name: "quesynth-test", version: "1", "": 2 }, "": 3,
  });
  assert.equal(initialized.error, undefined, JSON.stringify(initialized));
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
});
