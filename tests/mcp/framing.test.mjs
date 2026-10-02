import test from "node:test";
import assert from "node:assert/strict";
import { skip, startClient } from "./support/client.mjs";

const tick = () => new Promise(resolve => setTimeout(resolve, 50));

for (const [name, separator] of [["U+2028", "\u2028"], ["U+2029", "\u2029"]]) {
  test(`${name} inside a request string does not split the request`, {skip}, async t => {
    const client = startClient(t);
    const ping = await client.request("ping", { note: `a${separator}b` });
    assert.deepEqual(ping.result, {});
    const id = `id${separator}x`;
    const echoed = await client.request("ping", undefined, id);
    assert.equal(echoed.id, id);
    assert.deepEqual(echoed.result, {});
    assert.deepEqual((await client.request("ping")).result, {});
    assert.equal(client.messages.length, 3);
    assert.equal(client.messages.filter(m => m.error?.code === -32700).length, 0);
  });
}

test("a separator split across stdin writes is reassembled", {skip}, async t => {
  const client = startClient(t);
  const line = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: "s\u2028s", method: "ping" }) + "\n");
  const cut = line.indexOf(Buffer.from("\u2028")) + 1;
  client.child.stdin.write(line.subarray(0, cut));
  await tick();
  client.child.stdin.write(line.subarray(cut));
  assert.deepEqual((await client.request("ping")).result, {});
  assert.deepEqual(client.messages.map(m => m.id), ["s\u2028s", 1]);
});

test("a final request without a trailing newline is answered before exit", {skip}, async t => {
  const client = startClient(t);
  client.child.stdin.end(JSON.stringify({ jsonrpc: "2.0", id: 7, method: "ping" }));
  assert.deepEqual(await client.exited, [0, null]);
  assert.deepEqual(client.messages, [{ jsonrpc: "2.0", id: 7, result: {} }]);
});
