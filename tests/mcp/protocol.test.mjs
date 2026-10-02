import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { daemonFixture, synthModel } from "./support/daemon.mjs";
import { skip, quesynthBinary } from "./support/binary.mjs";
import { config, errorOf, startClient } from "./support/client.mjs";

const production = new URL("../../hosts/standalone/mcp/", import.meta.url);

test(".mcp.json launches quesynth --mcp and no Node server remains", () => {
  assert.deepEqual(config, { mcpServers: { quesynth: { command: "quesynth", args: ["--mcp"] } } });
  for (const file of ["serve.js", "tools.js"]) assert.equal(existsSync(new URL(file, production)), false, file);
  assert.deepEqual(readdirSync(production).filter(file => file.endsWith(".js")), []);
});

test("--mcp takes no operands and the usage lists it", {skip}, () => {
  const refused = spawnSync(quesynthBinary(), ["--mcp", "--bank", "bank.json"], { encoding: "utf8", timeout: 5000 });
  assert.equal(refused.status, 2);
  assert.equal(refused.stdout, "");
  assert.match(refused.stderr, /unexpected extra argument "--bank"/);
  const help = spawnSync(quesynthBinary(), ["--help"], { encoding: "utf8", timeout: 5000 });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /quesynth --mcp\s+\S/);
});

test("the launch initializes, lists and answers without a running daemon", {skip}, async t => {
  const client = startClient(t, { cwd: tmpdir() });
  const initialized = await client.initialize();
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.deepEqual(initialized.result.capabilities, { tools: {}, resources: {} });
  assert.equal(initialized.result.serverInfo.name, "quesynth");
  const tools = (await client.request("tools/list")).result.tools;
  assert.deepEqual(tools.map(tool => tool.name).sort(), ["apply_parameters", "inspect_synth"]);
  const resources = (await client.request("resources/list")).result.resources;
  assert.deepEqual(resources.map(resource => resource.uri).sort(), ["quesynth://parameters", "quesynth://patch"]);
  assert.ok(resources.every(resource => resource.mimeType === "application/json"));
  assert.deepEqual((await client.request("ping")).result, {});

  assert.equal(errorOf(await client.call("inspect_synth")).code, "daemon_unavailable");
  const apply = { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 1 }] };
  assert.equal(errorOf(await client.call("apply_parameters", apply)).code, "daemon_unavailable");
  for (const uri of ["quesynth://parameters", "quesynth://patch"]) {
    const { error } = await client.request("resources/read", { uri });
    assert.equal(error.code, -32000, uri);
    assert.match(error.message, /^daemon_unavailable: /);
    assert.deepEqual(error.data, { code: "daemon_unavailable" });
  }
  assert.deepEqual((await client.request("ping")).result, {});
  client.child.stdin.end();
  assert.deepEqual(await client.exited, [0, null]);
  assert.equal(client.stderr(), "");
  // A client of the daemon's socket, not its owner: like --stop it may make the
  // empty quesynth directory, and it never makes a socket or a file.
  const created = readdirSync(client.runtime);
  assert.ok(created.length === 0 || (created.length === 1 && created[0] === "quesynth"), String(created));
  if (created.length === 1) assert.deepEqual(readdirSync(join(client.runtime, "quesynth")), []);
});

test("QUESYNTH_SOCKET is not read: the daemon is found through XDG_RUNTIME_DIR", {skip}, async t => {
  const daemon = await daemonFixture(t, synthModel().answer);
  const client = startClient(t, { env: { QUESYNTH_SOCKET: daemon.socket } });
  await client.initialize();
  assert.equal(errorOf(await client.call("inspect_synth")).code, "daemon_unavailable");
  assert.deepEqual(daemon.commands, []);
});

test("lifecycle refusals and malformed input leave stdio usable", {skip}, async t => {
  const client = startClient(t);
  // Ready only after initialize and then the notification, in that order.
  client.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  assert.deepEqual((await client.request("ping")).result, {});
  for (const method of ["tools/list", "tools/call", "resources/list", "resources/read"]) {
    assert.equal((await client.request(method)).error.code, -32000, method);
  }

  client.write("{broken json}\nnull\n[]\n\n");
  client.send({ jsonrpc: "1.0", method: "ping", id: 60 });
  client.send({ jsonrpc: "2.0", method: "ping", id: null });
  client.send({ jsonrpc: "2.0", method: 5, id: 61 });
  const replies = await client.take(7);
  assert.deepEqual(replies.map(reply => reply.error.code), [-32700, -32600, -32600, -32700, -32600, -32600, -32600]);
  for (const reply of [replies[0], replies[1], replies[2], replies[3], replies[5]]) assert.equal(reply.id, null);
  assert.ok(replies.every(reply => reply.jsonrpc === "2.0"));

  assert.equal((await client.request("initialize", {})).error.code, -32602);
  const clientInfo = { name: "test", version: "1" };
  for (const params of [
    { capabilities: {}, clientInfo },
    { protocolVersion: 20251125, capabilities: {}, clientInfo },
    { protocolVersion: "2025-11-25", clientInfo },
    { protocolVersion: "2025-11-25", capabilities: {} },
    { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test" } },
  ]) assert.equal((await client.request("initialize", params)).error.code, -32602, JSON.stringify(params));
  const initialized = await client.request("initialize", {
    protocolVersion: "unknown-version", capabilities: {}, clientInfo,
  });
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.equal((await client.request("tools/list")).error.code, -32000);
  client.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  assert.equal((await client.request("tools/list")).result.tools.length, 2);
  assert.equal((await client.request("initialize", {})).error.code, -32600);

  assert.equal((await client.request("unknown-method")).error.code, -32601);
  assert.equal((await client.request("resources/templates/list")).error.code, -32601);
  assert.equal((await client.request("ping", [1])).error.code, -32602);
  assert.equal((await client.request("tools/call", null)).error.code, -32602);
  assert.equal((await client.request("tools/call", { name: 4 })).error.code, -32602);
  for (const name of ["daemon_shutdown", "__proto__", "run_command", "read_file"]) {
    assert.equal((await client.call(name)).error.code, -32602, name);
  }
  assert.equal((await client.request("resources/read", {})).error.code, -32602);
  assert.equal((await client.request("resources/read", { uri: 3 })).error.code, -32602);
  assert.equal((await client.request("resources/read", { uri: "quesynth://nothing" })).error.code, -32002);

  // A notification is never answered, whatever its method.
  client.send({ jsonrpc: "2.0", method: "tools/call", params: { name: "inspect_synth" } });
  client.send({ jsonrpc: "2.0", method: "notifications/unknown" });
  client.send({ jsonrpc: "2.0", method: "ping" });
  assert.equal((await client.request("ping", undefined, "string-id")).id, "string-id");
});

test("malformed JSON is a parse error, not a crash, and nothing ill-formed reaches the daemon", {skip}, async t => {
  const daemon = await daemonFixture(t, synthModel().answer);
  const client = startClient(t, { runtime: daemon.runtime });
  await client.initialize();
  const ping = '{"jsonrpc":"2.0","id":1,"method":"ping"}';
  const grammar = [
    `${ping} x`, `${ping}${ping}`, ping.slice(0, -1), ping.replace("}", ",}"), ping.replace('"id":1', '"id":01'),
    ping.replace('"ping"', "'ping'"), ping.replace('"ping"', '"pi\u0001ng"'), ping.replace("1", "NaN"),
    "[".repeat(100_000), '{"a":'.repeat(100_000),
  ];
  const prefix = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"apply_parameters",' +
    '"arguments":{"expected_revision":0,"parameters":[{"id":"';
  const withId = id => Buffer.concat([Buffer.from(prefix), Buffer.from(id), Buffer.from('","value":1}]}}}\n')]);
  for (const line of grammar) client.write(line + "\n");
  assert.deepEqual((await client.take(grammar.length)).map(reply => reply.error.code), grammar.map(() => -32700));

  // A lone surrogate has no UTF-8 form, so it is refused whole rather than forwarded as U+FFFD.
  const illFormed = [withId("a\\ud800b"), withId("a\\udc00b"), withId("a\\ud800\\u0041b"), withId(Buffer.from([0x61, 0xff, 0x62]))];
  for (const line of illFormed) client.write(line);
  const replies = await client.take(illFormed.length);
  for (const reply of replies) assert.ok(reply.error?.code === -32700 || reply.error?.code === -32600, JSON.stringify(reply));
  assert.deepEqual(daemon.commands, []);
  assert.deepEqual((await client.request("ping")).result, {});
});

test("a request id comes back as the same string or number", {skip}, async t => {
  const client = startClient(t);
  const ids = [0, 1, -5, 2 ** 31, Number.MAX_SAFE_INTEGER, "", "7", "id", "a\"b\\c\n\t", "é 😀", "x\u2028y", "\u007f"];
  for (const id of ids) assert.deepEqual((await client.request("ping", undefined, id)).result, {}, JSON.stringify(id));
});

test("an integer request id is echoed as an integer on the wire", {skip}, async t => {
  const client = startClient(t);
  client.write('{"jsonrpc":"2.0","id":7,"method":"ping"}\n{"jsonrpc":"2.0","id":-12,"method":"ping"}\n');
  await client.take(2);
  assert.match(client.raw[0], /"id":7[,}]/);
  assert.match(client.raw[1], /"id":-12[,}]/);
});

test("results follow the negotiated protocol version", {skip}, async t => {
  const daemon = await daemonFixture(t, synthModel().answer);
  for (const version of ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]) {
    const structured = version >= "2025-06-18";
    const client = startClient(t, { runtime: daemon.runtime });
    assert.equal((await client.initialize(version)).result.protocolVersion, version);

    const success = (await client.call("inspect_synth")).result;
    assert.equal(success.isError, undefined, version);
    assert.equal("structuredContent" in success, structured, version);
    if (structured) assert.deepEqual(success.structuredContent, JSON.parse(success.content[0].text), version);

    const failure = (await client.call("apply_parameters", { expected_revision: -1, parameters: [] })).result;
    assert.equal(failure.isError, true, version);
    assert.equal(JSON.parse(failure.content[0].text).code, "invalid_arguments");
    assert.equal("structuredContent" in failure, structured, version);
    if (structured) assert.deepEqual(failure.structuredContent, JSON.parse(failure.content[0].text), version);

    const resource = (await client.request("resources/read", { uri: "quesynth://parameters" })).result.contents[0];
    assert.deepEqual(Object.keys(resource).sort(), ["mimeType", "text", "uri"], version);
    assert.equal(typeof JSON.parse(resource.text), "object", version);
  }
  for (const version of ["2024-10-01", "2026-01-01", "unknown-version"]) {
    const client = startClient(t, { runtime: daemon.runtime });
    assert.equal((await client.initialize(version)).result.protocolVersion, "2025-11-25", version);
  }
});
