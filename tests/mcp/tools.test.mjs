import test from "node:test";
import assert from "node:assert/strict";
import { daemonFixture } from "./support/daemon.mjs";
import { skip, startClient } from "./support/client.mjs";

test("typed tools send only their documented daemon command and preserve replies", {skip}, async t => {
  const daemon = await daemonFixture(t, () => "ok count=0\nname=  Ünicode = value  \nname=duplicate\n");
  const client = startClient(t, { args: ["--socket", daemon.socket] });
  await client.initialize();
  const examples = [
    ["daemon_status", {}, "daemon.status"],
    ["daemon_info", {}, "daemon.info"],
    ["parameter_list", {}, "parameter.list"],
    ["parameter_get", { id: "filter.cutoff" }, "parameter.get filter.cutoff"],
    ["parameter_set", { id: "filter.cutoff", value: 0 }, "parameter.set filter.cutoff 0"],
    ["patch_current", {}, "patch.current"],
    ["patch_load", { slot: 0 }, "patch.load 0"],
    ["patch_load_file", { path: "  /patch dir/a;$(ignored).sy1  " }, "patch.load_file   /patch dir/a;$(ignored).sy1  "],
    ["bank_list", {}, "bank.list"],
    ["bank_load_file", { path: "relative bank.json" }, "bank.load_file relative bank.json"],
    ["archive_current", {}, "archive.current"],
    ["archive_open", {}, "archive.open"],
    ["archive_open", { path: "" }, "archive.open "],
    ["archive_open", { path: "/tmp/with spaces.zip" }, "archive.open /tmp/with spaces.zip"],
    ["archive_banks", {}, "archive.banks"],
    ["archive_banks", { offset: 0, count: 0 }, "archive.banks 0 0"],
    ["archive_banks", { count: 1000 }, "archive.banks 0 1000"],
    ["archive_bank", { index: 0 }, "archive.bank 0"],
    ["archive_patches", { offset: 7 }, "archive.patches 7"],
    ["archive_load", { index: 2 }, "archive.load 2"],
    ["archive_load", { index: 2, bank: 0 }, "archive.load 2 0"],
    ["archive_close", {}, "archive.close"],
    ["midi_list", {}, "midi.list"],
    ["midi_current", {}, "midi.current"],
    ["midi_select", { id: "none" }, "midi.select none"],
    ["midi_send", { status: 192, data1: 0, data2: 0 }, "midi 192 0 0"],
  ];
  const listed = (await client.request("tools/list")).result.tools;
  assert.deepEqual(listed.map(tool => tool.name).sort(), [...new Set(examples.map(row => row[0]))].sort());
  for (const [name, args, command] of examples) {
    const response = await client.call(name, args);
    assert.equal(response.result.isError, undefined, name);
    const expected = { fields: "count=0", lines: ["name=  Ünicode = value  ", "name=duplicate", ""] };
    assert.deepEqual(response.result.structuredContent, expected, name);
    assert.deepEqual(JSON.parse(response.result.content[0].text), expected, name);
    assert.equal(daemon.commands.at(-1), command);
  }
  for (const tool of listed) {
    assert.equal(tool.inputSchema.type, "object");
    assert.equal(tool.inputSchema.additionalProperties, false);
    assert.equal(tool.outputSchema.properties.lines.type, "array");
    assert.equal(tool.annotations.openWorldHint, false);
  }
  // midi.select only opens and closes inputs; the control thread has no engine
  // to release a note with (hosts/standalone/command_handler.odin).
  const select = listed.find(tool => tool.name === "midi_select").description;
  assert.match(select, /Releases no held notes/);
  assert.doesNotMatch(select, /may be released/);
});

test("invalid tool arguments cannot reach the daemon", {skip}, async t => {
  const daemon = await daemonFixture(t);
  const client = startClient(t, { args: ["--socket", daemon.socket] });
  await client.initialize();
  const invalid = [
    ["daemon_info", { command: "daemon.shutdown" }],
    ["parameter_get", {}], ["parameter_get", { id: "" }],
    ["parameter_get", { id: "filter.cutoff 99" }],
    ["parameter_get", { id: "filter.cutoff\n" }],
    ["parameter_set", { id: "filter.cutoff", value: "4" }],
    ["parameter_set", { id: "filter.cutoff", value: 1.5 }],
    ["parameter_set", { id: "filter.cutoff", value: null }],
    ["patch_load", { slot: -1 }], ["patch_load", { slot: 128 }],
    ["archive_bank", { index: Number.MAX_SAFE_INTEGER + 1 }],
    ["archive_load", { index: 0, bank: null }],
    ["archive_banks", { count: -1 }],
    ["midi_send", { status: 256, data1: 0, data2: 0 }],
    ["midi_send", { status: 144, data1: 128, data2: 0 }],
    ["midi_send", { status: 144, data1: 0, data2: -1 }],
    ["midi_send", { status: 192, data1: 0 }],
    ["midi_select", { id: "all\tnone" }],
    ["archive_open", { path: "file.zip\n1 7 daemon.shutdown" }],
    ["bank_load_file", { path: "file.json\r" }],
    ["patch_load_file", { path: "file\u0000.sy1" }],
    ["archive_open", { path: "\ud800" }],
    ["archive_current", null], ["archive_current", []],
    ...["\u0001", "\t", "\u001b", "\u001f", "\u007f", "\u0080", "\u0085", "\u009f", "\u2028", "\u2029"].flatMap(c => [
      ["parameter_get", { id: `a${c}b` }], ["midi_select", { id: `a${c}b` }],
      ["patch_load_file", { path: `a${c}b` }], ["bank_load_file", { path: `a${c}b` }],
      ["archive_open", { path: `a${c}b` }],
    ]),
  ];
  for (const [name, args] of invalid) {
    const result = (await client.call(name, args)).result;
    assert.equal(result.isError, true, `${name} ${JSON.stringify(args)}`);
    assert.equal(JSON.parse(result.content[0].text).code, "invalid_arguments");
  }
  assert.deepEqual(daemon.commands, []);
  assert.equal((await client.call("daemon_shutdown")).error.code, -32602);
  assert.equal((await client.call("__proto__")).error.code, -32602);
});

test("paths and ids just outside the rejected ranges still reach the daemon verbatim", {skip}, async t => {
  const daemon = await daemonFixture(t);
  const client = startClient(t, { args: ["--socket", daemon.socket] });
  await client.initialize();
  const path = "a b\u00e9\u00a0\u00a1.sy1";
  for (const [name, args, command] of [
    ["patch_load_file", { path }, `patch.load_file ${path}`],
    ["bank_load_file", { path }, `bank.load_file ${path}`],
    ["parameter_get", { id: "caf\u00e9\u00a1" }, "parameter.get caf\u00e9\u00a1"],
  ]) {
    assert.equal((await client.call(name, args)).result.isError, undefined, name);
    assert.equal(daemon.commands.at(-1), command);
  }
});
