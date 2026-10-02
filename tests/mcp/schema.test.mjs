import test from "node:test";
import assert from "node:assert/strict";
import { availableParallelism, tmpdir } from "node:os";
import { skip } from "./support/binary.mjs";
import { startClient } from "./support/client.mjs";

// The patterns in tools/list are what a client checks a value against before it
// calls. They are only worth having if they say what the server says, so every
// Unicode scalar value is put to both: the pattern here, in JavaScript, and the
// built binary, over stdio, with no daemon behind it. A value the binary does
// not refuse is answered daemon_unavailable; one it refuses, invalid_arguments.
//
// Two classes of character matter and they are different. A token (an id) is
// split on any whitespace Odin knows, including U+200B, U+200E, U+200F and
// U+FEFF. A path or a name has the whitespace the daemon trims cut from its
// ends, which is narrower. Neither \s nor a guess would do, which is why this
// is exhaustive rather than a list of the interesting ones.

const LAST = 0x10ffff;
const scalars = [];
for (let c = 0; c <= LAST; c += 1) if (c < 0xd800 || c > 0xdfff) scalars.push(c);

function chunks(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

const text = c => String.fromCodePoint(c);
const hex = c => c.toString(16).toUpperCase().padStart(4, "0");

async function setup(t) {
  const client = startClient(t, { cwd: tmpdir() });
  await client.initialize();
  const tools = (await client.request("tools/list")).result.tools;
  const property = (tool, name) => tools.find(candidate => candidate.name === tool).inputSchema.properties[name];
  const pattern = schema => new RegExp(schema.pattern, "u");
  return {
    client,
    token: pattern(property("parameter_get", "id")),
    pairId: pattern(property("parameter_set_many", "parameters").items.properties.id),
    path: pattern(property("patch_load_file", "path")),
    optional: pattern(property("archive_open", "path")),
    name: pattern(property("patch_save", "name")),
  };
}

// Whether the binary refuses the call, from the one reply to it.
const refused = response => response.result.isError === true && JSON.parse(response.result.content[0].text).code === "invalid_arguments";

// Many requests written at once, their replies read in order.
async function pipeline(client, calls) {
  let id = 1000;
  client.write(calls.map(([name, args]) => JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }) + "\n").join(""));
  return client.take(calls.length);
}

test("the patterns for ids are the binary's rule for ids, for every Unicode scalar value", {skip}, async t => {
  const { client, token, pairId } = await setup(t);
  assert.equal(token.source, pairId.source);
  // A batch of ids is one request; it is refused at the first bad one, and the
  // message names which and by what code point.
  const rejected = new Set();
  for (const batch of chunks(scalars, 128)) {
    let rest = batch;
    while (rest.length > 0) {
      const reply = (await pipeline(client, [["parameter_set_many", { parameters: rest.map(c => ({ id: text(c), value: 1 })) }]]))[0];
      if (!refused(reply)) break;
      const { message } = JSON.parse(reply.result.content[0].text);
      const found = /^parameters\[(\d+)\]\.id must (?:not be empty|not contain whitespace or control characters \(U\+([0-9A-F]+)\))$/.exec(message);
      assert.ok(found, message);
      const index = Number(found[1]);
      assert.equal(hex(rest[index]), found[2], message);
      rejected.add(rest[index]);
      rest = rest.slice(index + 1);
    }
  }
  let wrong = [];
  for (const c of scalars) {
    if (token.test(text(c)) === rejected.has(c)) wrong.push(hex(c));
  }
  assert.deepEqual(wrong, [], "the pattern and the binary disagree on these code points");
  assert.ok(rejected.size > 20 && rejected.size < 120, String(rejected.size));

  // The same rule on the other tool that takes one token, at three positions.
  const sample = scalars.filter(c => c < 0x3100 || c % 97 === 0);
  const replies = await pipeline(client, sample.flatMap(c => [["parameter_get", { id: text(c) }], ["midi_select", { input: `a${text(c)}b` }]]));
  sample.forEach((c, i) => {
    assert.equal(refused(replies[2 * i]), rejected.has(c), `parameter_get U+${hex(c)}`);
    assert.equal(refused(replies[2 * i + 1]), rejected.has(c), `midi_select U+${hex(c)}`);
  });
});

// The interior of a text: all but a control character or a line separator.
async function interior(client, list) {
  const rejected = new Set();
  for (const batch of chunks(list, 4096)) {
    let rest = batch;
    while (rest.length > 0) {
      const reply = (await pipeline(client, [["patch_load_file", { path: `a${rest.map(text).join("")}a` }]]))[0];
      if (!refused(reply)) break;
      const { message } = JSON.parse(reply.result.content[0].text);
      const found = /^path must not contain control characters or line separators \(U\+([0-9A-F]+)\)$/.exec(message);
      assert.ok(found, message);
      const bad = rest.find(c => hex(c) === found[1]);
      assert.notEqual(bad, undefined, message);
      rejected.add(bad);
      rest = rest.slice(rest.indexOf(bad) + 1);
    }
  }
  return rejected;
}

test("the patterns for paths and names are the binary's rule at the ends and inside, for every Unicode scalar value", {skip}, async t => {
  const { client, path, optional, name } = await setup(t);
  const inside = await interior(client, scalars);
  const wrong = [];
  for (const c of scalars) {
    if (path.test(`a${text(c)}a`) === inside.has(c)) wrong.push(`inside U+${hex(c)}`);
    if (optional.test(`a${text(c)}a`) === inside.has(c)) wrong.push(`optional inside U+${hex(c)}`);
    if (name.test(`a${text(c)}a`) === inside.has(c)) wrong.push(`name inside U+${hex(c)}`);
  }
  assert.deepEqual(wrong, []);
  assert.ok(inside.size > 20 && inside.size < 120, String(inside.size));

  // At the ends. What is refused inside is refused there too, so only the rest
  // are put at the front and at the back of a path, one of each in a request,
  // and every one of them takes each place once. A request that is refused is
  // asked again one end at a time, since it does not say which end it was.
  const edge = scalars.filter(c => !inside.has(c));
  const requests = [];
  for (let i = 0; i < edge.length; i += 2) {
    const other = edge[i + 1] ?? edge[i];
    requests.push([edge[i], other]);
    if (other !== edge[i]) requests.push([other, edge[i]]);
  }
  const workers = Math.max(1, Math.min(8, availableParallelism()));
  const front = new Set();
  const back = new Set();
  await Promise.all(Array.from({ length: workers }, async (_, w) => {
    const own = w === 0 ? client : (await setup(t)).client;
    const mine = requests.filter((_, i) => i % workers === w);
    for (const batch of chunks(mine, 2000)) {
      const replies = await pipeline(own, batch.map(([first, last]) => ["patch_load_file", { path: `${text(first)}a${text(last)}` }]));
      const again = [];
      batch.forEach(([first, last], i) => { if (refused(replies[i])) again.push(["front", first], ["back", last]); });
      const singles = await pipeline(own, again.map(([end, c]) => ["patch_load_file", { path: end === "front" ? `${text(c)}a` : `a${text(c)}` }]));
      again.forEach(([end, c], i) => { if (refused(singles[i])) (end === "front" ? front : back).add(c); });
    }
  }));
  const disagreements = [];
  for (const c of edge) {
    if (path.test(`${text(c)}a`) === front.has(c)) disagreements.push(`front U+${hex(c)}`);
    if (path.test(`a${text(c)}`) === back.has(c)) disagreements.push(`back U+${hex(c)}`);
  }
  assert.deepEqual(disagreements, []);
  // The same whitespace at either end: the set the daemon trims.
  assert.deepEqual([...front].sort((a, b) => a - b), [...back].sort((a, b) => a - b));
  assert.ok(front.size > 5 && front.size < 40, String(front.size));

  // What is refused inside is refused at the ends too, by the pattern as by
  // the binary.
  const outside = [...inside];
  const replies = await pipeline(client, outside.flatMap(c => [["patch_load_file", { path: `${text(c)}a` }], ["patch_load_file", { path: `a${text(c)}` }]]));
  outside.forEach((c, i) => {
    assert.equal(refused(replies[2 * i]), true, `front U+${hex(c)}`);
    assert.equal(refused(replies[2 * i + 1]), true, `back U+${hex(c)}`);
    assert.equal(path.test(`${text(c)}a`) || path.test(`a${text(c)}`), false, `U+${hex(c)}`);
  });

  // The optional pattern and the name's are the same rule with the empty string
  // let through, on the same characters.
  const probe = [...front, ...inside, ...scalars.filter(c => c % 211 === 0)];
  const answers = await pipeline(client, probe.flatMap(c => [["archive_open", { path: `${text(c)}a` }], ["patch_save", { slot: 0, name: `a${text(c)}` }]]));
  probe.forEach((c, i) => {
    assert.equal(refused(answers[2 * i]), !optional.test(`${text(c)}a`), `archive_open U+${hex(c)}`);
    assert.equal(refused(answers[2 * i + 1]), !name.test(`a${text(c)}`), `patch_save U+${hex(c)}`);
  });

  // The empty string: refused for a required path, taken as "leave it out" for
  // an optional one, which the optional pattern lets through and the other not.
  assert.equal(path.test(""), false);
  assert.equal(optional.test(""), true);
  assert.equal(name.test(""), true);
  const [a, b] = await pipeline(client, [["patch_load_file", { path: "" }], ["archive_open", { path: "" }]]);
  assert.equal(refused(a), true);
  assert.equal(refused(b), false);
  // And whitespace alone is not a path.
  for (const c of [0x20, 0xa0, 0x3000]) assert.equal(path.test(text(c)), false);
});
