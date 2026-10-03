import test from "node:test";
import assert from "node:assert/strict";
import {DEFAULTS, REGISTRY, connectRaw, writeBank} from "./support/fake-daemon.mjs";
import {startEnv, unix, until} from "./support/harness.mjs";

const HIDDEN = DEFAULTS.map((_, i) => i).filter(i => !REGISTRY.some(d => d.index === i));

async function withPeer(t, env) {
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  return peer;
}

test("sync answers bank, then state, then patch: 99 dense values and no slot", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  await peer.request("parameter.set_many filter.cutoff 12 amp.attack 99 osc1.shape 3");
  const ws = await env.open();
  ws.send({type: "sync"});
  await until(() => ws.received.length >= 3, 3000, "three messages");
  const [bank, state, patch] = ws.received;
  assert.deepEqual([bank.type, state.type, patch.type], ["bank", "state", "patch"]);
  assert.equal(bank.text, writeBank(env.daemon.bank));
  assert.equal(state.values.length, 99);
  assert.ok(state.values.every(Number.isInteger));
  assert.deepEqual(state.values, env.daemon.published.values);
  assert.equal(state.values[19], 12);
  // The panel ignores an empty name, so a daemon with none is shown as the
  // panel's own "Untitled".
  assert.deepEqual(patch, {type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
  assert.equal(HIDDEN.length, 7, "the registry leaves seven parameters out");
});

test("after a patch.load the page is told the slot, and unexposed parameters come from it", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  await peer.request("patch.load 5");
  const ws = await env.open();
  const {state, patch} = await ws.synced();
  assert.deepEqual(patch, {type: "patch", name: "Bells", index: 5, bank: "My Bank", source: "bank", archive: null});
  assert.deepEqual(state.values, env.daemon.bank.slots[5].values);
  for (const i of HIDDEN) assert.equal(state.values[i], env.daemon.engine[i]);
});

test("a fresh daemon's sound is Untitled, and staying so is not a change to announce", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const ws = await env.open();
  const {patch} = await ws.synced();
  assert.deepEqual(patch, {type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
  assert.deepEqual(env.daemon.identity, {slot: -1, bank: "", name: "", source: "none", archiveBank: -1, archivePatch: -1}, "the daemon's own word is unchanged");
  assert.deepEqual(await ws.quiet(120, "patch"), [], "the empty identity is not re-sent every poll");
});

test("a file-like state clears the identity and a second page is told Untitled", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  await peer.request("patch.load 5");
  const writer = await env.open();
  await writer.synced();
  const reader = await env.open();
  const {patch} = await reader.synced();
  assert.equal(patch.name, "Bells");
  const values = env.daemon.bank.slots[5].values.slice();
  values[19] = (values[19] + 1) % 128;
  writer.send({type: "state", values});
  assert.deepEqual(await reader.next("patch"), {type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
  assert.deepEqual(env.daemon.identity, {slot: -1, bank: "", name: "", source: "none", archiveBank: -1, archivePatch: -1});
});

test("one parameter changed by another client arrives as a param", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  const ws = await env.open();
  await ws.synced();
  await peer.request("parameter.set filter.cutoff 33");
  assert.deepEqual(await ws.next("param"), {type: "param", index: 19, value: 33});
  assert.deepEqual(await ws.quiet(60), [], "nothing else moved");
});

test("many parameters changed by another client arrive as one state", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  const ws = await env.open();
  await ws.synced();
  const moved = REGISTRY.slice(0, 20).map(d => `${d.id} ${d.index === 0 ? 1 : 3}`);
  await peer.request(`parameter.set_many ${moved.join(" ")}`);
  const state = await ws.next("state");
  assert.deepEqual(state.values, env.daemon.published.values);
  assert.deepEqual(await ws.quiet(60), [], "no param messages as well");
});

test("a TUI-style patch.load sends state and patch, and no bank", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  const ws = await env.open();
  await ws.synced();
  await peer.request("patch.load 5");
  const state = await ws.next("state");
  assert.deepEqual(state.values, env.daemon.bank.slots[5].values);
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Bells", index: 5, bank: "My Bank", source: "bank", archive: null});
  assert.deepEqual(await ws.quiet(100, "bank"), []);
});

test("a patch.save by another client sends the bank, then state, then patch", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const peer = await withPeer(t, env);
  const ws = await env.open();
  await ws.synced();
  const before = ws.received.length;
  await peer.request("patch.save 20 My Sound");
  const bank = await ws.next("bank");
  assert.equal(bank.text, writeBank(env.daemon.bank));
  assert.equal(JSON.parse(bank.text).patches[20].name, "My Sound");
  await ws.next("state");
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "My Sound", index: 20, bank: "My Bank", source: "bank", archive: null});
  assert.deepEqual(ws.received.slice(before).map(m => m.type), ["bank", "state", "patch"]);
});
