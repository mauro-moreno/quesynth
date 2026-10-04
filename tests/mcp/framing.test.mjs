import test from "node:test";
import assert from "node:assert/strict";
import { skip } from "./support/binary.mjs";
import { startClient } from "./support/client.mjs";

const tick = () => new Promise(resolve => setTimeout(resolve, 50));
const ping = id => JSON.stringify({ jsonrpc: "2.0", id, method: "ping" });

for (const [name, separator] of [["U+2028", "\u2028"], ["U+2029", "\u2029"]]) {
  test(`${name} inside a request string does not split the request`, {skip}, async t => {
    const client = startClient(t);
    assert.deepEqual((await client.request("ping", { note: `a${separator}b` })).result, {});
    const id = `id${separator}x`;
    assert.equal((await client.request("ping", undefined, id)).id, id);
    assert.deepEqual((await client.request("ping")).result, {});
  });
}

test("a request split across stdin writes is reassembled, even inside a character", {skip}, async t => {
  const client = startClient(t);
  const line = Buffer.from(ping("s\u2028é") + "\n");
  const inside = line.indexOf(Buffer.from("\u2028")) + 1;
  client.write(line.subarray(0, 5));
  await tick();
  client.write(line.subarray(5, inside));
  await tick();
  client.write(line.subarray(inside));
  const [reply] = await client.take();
  assert.equal(reply.id, "s\u2028é");
  assert.deepEqual(reply.result, {});
});

test("several requests in one write are answered in order", {skip}, async t => {
  const client = startClient(t);
  client.write([ping(1), ping("two"), ping(3)].map(line => line + "\n").join(""));
  assert.deepEqual((await client.take(3)).map(reply => reply.id), [1, "two", 3]);
});

test("a CRLF line ending is accepted", {skip}, async t => {
  const client = startClient(t);
  client.write(ping(1) + "\r\n" + ping(2) + "\r\n");
  assert.deepEqual((await client.take(2)).map(reply => reply.id), [1, 2]);
});

test("a final request without a trailing newline is answered before exit", {skip}, async t => {
  const client = startClient(t);
  client.child.stdin.end(ping(7));
  assert.deepEqual(await client.exited, [0, null]);
  assert.deepEqual(await client.take(), [{ jsonrpc: "2.0", id: 7, result: {} }]);
  assert.equal(client.stderr(), "");
});

test("one very long request line is answered in linear time", {skip}, async t => {
  const client = startClient(t);
  const started = Date.now();
  const reply = await client.request("ping", { note: "x".repeat(8 * 1024 * 1024) });
  assert.deepEqual(reply.result, {});
  assert.ok(Date.now() - started < 4000, `took ${Date.now() - started} ms`);
  assert.deepEqual((await client.request("ping")).result, {});
});
