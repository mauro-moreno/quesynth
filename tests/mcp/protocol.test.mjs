import test from "node:test";
import assert from "node:assert/strict";
import { skip, startClient } from "./support/client.mjs";

test("the project launch initializes and lists tools without a running daemon", {skip}, async t => {
  const client = startClient(t, { args: ["--socket", "/no/quesynth/socket"] });
  const initialized = await client.initialize();
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.deepEqual(initialized.result.capabilities, { tools: {} });
  assert.equal(initialized.result.serverInfo.name, "quesynth");
  const listed = await client.request("tools/list");
  assert.ok(listed.result.tools.some(tool => tool.name === "daemon_status"));
  const status = await client.call("daemon_status");
  assert.equal(status.result.isError, true);
  assert.match(status.result.content[0].text, /daemon_unavailable/);
  assert.deepEqual((await client.request("ping")).result, {});
  client.child.stdin.end();
  assert.deepEqual(await client.exited, [0, null]);
  assert.equal(client.stderr(), "");
});

test("JSON-RPC errors and lifecycle refusals leave stdio usable", {skip}, async t => {
  const client = startClient(t);
  assert.deepEqual((await client.request("ping")).result, {});
  assert.equal((await client.request("tools/list")).error.code, -32000);
  client.child.stdin.write("{broken json}\nnull\n[]\n");
  client.send({ jsonrpc: "1.0", method: "ping", id: 60 });
  client.send({ jsonrpc: "2.0", method: "ping", id: null });
  await client.request("ping");
  assert.equal(client.messages.filter(m => m.error?.code === -32700).length, 1);
  assert.equal(client.messages.filter(m => m.error?.code === -32600).length, 4);
  assert.equal((await client.request("initialize", {})).error.code, -32602);
  const initialized = await client.request("initialize", {
    protocolVersion: "unknown-version", capabilities: {}, clientInfo: { name: "test", version: "1" },
  });
  assert.equal(initialized.result.protocolVersion, "2025-11-25");
  assert.equal((await client.request("tools/list")).error.code, -32000);
  client.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  assert.ok((await client.request("tools/list")).result.tools.length);
  assert.equal((await client.request("initialize", {})).error.code, -32600);
  assert.equal((await client.request("unknown-method")).error.code, -32601);
  assert.equal((await client.request("tools/call", null)).error.code, -32602);
  assert.equal((await client.request("tools/call", { name: 4 })).error.code, -32602);
  const before = client.messages.length;
  client.send({ jsonrpc: "2.0", method: "tools/call", params: { name: "midi_send" } });
  client.send({ jsonrpc: "2.0", method: "notifications/unknown" });
  await client.request("ping", undefined, "string-id");
  assert.equal(client.messages.length, before + 1);
  assert.equal(client.messages.at(-1).id, "string-id");
});

test("negotiated legacy versions use text results and modern versions add structured content", {skip}, async t => {
  const { daemonFixture } = await import("./support/daemon.mjs");
  const daemon = await daemonFixture(t, () => "ok state=running proto=1 revision=0");
  for (const version of ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]) {
    const client = startClient(t, { args: ["--socket", daemon.socket] });
    assert.equal((await client.initialize(version)).result.protocolVersion, version);
    const tool = (await client.request("tools/list")).result.tools[0];
    const result = (await client.call("daemon_status")).result;
    const expected = { fields: "state=running proto=1 revision=0", lines: [] };
    assert.deepEqual(JSON.parse(result.content[0].text), expected);
    assert.equal(Object.hasOwn(tool, "outputSchema"), version >= "2025-06-18");
    assert.equal(Object.hasOwn(tool, "annotations"), version >= "2025-03-26");
    assert.deepEqual(result.structuredContent, version >= "2025-06-18" ? expected : undefined);
  }
});
