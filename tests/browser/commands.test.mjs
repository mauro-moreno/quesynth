import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {DEFAULTS, FIXTURE, PARAMS, REGISTRY, connectRaw, writeBank} from "./support/fake-daemon.mjs";
import {startEnv, strayTempDirs, unix, until} from "./support/harness.mjs";
import {sleep} from "./support/ws-client.mjs";

const skip = !unix;
// Everything that changes the daemon, as opposed to reading it.
const WRITES = new Set(["parameter.set", "parameter.set_many", "patch.load", "patch.clear", "patch.save",
  "bank.load_file", "bank.keep", "midi", "volume"]);

function writes(daemon) {
  return daemon.commands().filter(line => WRITES.has(line.split(" ")[0]));
}

async function page(t, options) {
  const env = await startEnv(t, options);
  const ws = await env.open();
  const synced = await ws.synced();
  return {env, ws, daemon: env.daemon, synced};
}

function bankWith(edit) {
  const doc = JSON.parse(FIXTURE);
  edit(doc);
  return JSON.stringify(doc, null, 2) + "\n";
}

// -- browser -> daemon --------------------------------------------------------

test("set becomes parameter.set, and another page and client see it", {skip}, async t => {
  const {env, ws, daemon} = await page(t);
  const other = await env.open();
  await other.synced();
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  ws.send({type: "set", index: 19, value: 77});
  assert.deepEqual(await other.next("param"), {type: "param", index: 19, value: 77});
  assert.deepEqual(writes(daemon), ["parameter.set filter.cutoff 77"]);
  assert.match(await peer.request("parameter.get filter.cutoff"), / ok value=77 /);
  assert.deepEqual(await ws.quiet(80), [], "the writer is not sent its own value back");
});

test("a whole-patch state no slot holds becomes set_many, then patch.clear", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const values = DEFAULTS.slice();
  values[19] = 3;
  values[25] = 7;
  ws.send({type: "state", values});
  await until(() => writes(daemon).length === 2, 3000, "two writes");
  const pairs = values.map((v, i) => [i, v]).filter(([i]) => REGISTRY.some(d => d.index === i))
    .map(([i, v]) => `${REGISTRY.find(d => d.index === i).id} ${v}`);
  assert.deepEqual(writes(daemon), [`parameter.set_many ${pairs.join(" ")}`, "patch.clear"]);
  assert.equal(daemon.published.values[19], 3);
  assert.equal(daemon.published.values[25], 7);
});

test("notes reach the daemon's MIDI queue as exact bytes", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "note", on: true, note: 60, velocity: 100});
  ws.send({type: "note", on: false, note: 60, velocity: 0});
  ws.send({type: "note", on: true, note: 127, velocity: 1, channel: 15});
  ws.send({type: "note", on: true, note: 0});
  await until(() => daemon.midi.length === 4, 3000, "four notes");
  assert.deepEqual(daemon.midi, [[144, 60, 100], [128, 60, 0], [159, 127, 1], [144, 0, 100]]);
});

test("pitch and mod wheels become exact 14-bit bend and CC1 bytes", {skip}, async t => {
  const {ws, daemon} = await page(t);
  for (const value of [-1, 0, 0.5, 1, 0.25, -0.5]) ws.send({type: "wheel", which: "pitch", value});
  for (const value of [0, 0.5, 1]) ws.send({type: "wheel", which: "mod", value});
  await until(() => daemon.midi.length === 9, 3000, "nine wheel moves");
  assert.deepEqual(daemon.midi, [
    [224, 0, 0], [224, 0, 64], [224, 0, 96], [224, 127, 127], [224, 0, 80], [224, 0, 32],
    [176, 1, 0], [176, 1, 64], [176, 1, 127],
  ]);
});

test("cc becomes a controller change on the MIDI queue", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "cc", cc: 74, value: 12});
  ws.send({type: "cc", cc: 7, value: 127});
  await until(() => daemon.midi.length === 2, 3000, "two controllers");
  assert.deepEqual(daemon.midi, [[176, 74, 12], [176, 7, 127]]);
});

test("volume on 0..1 becomes volume in thousandths, clamped", {skip}, async t => {
  const {env, ws, daemon} = await page(t);
  const seen = [];
  for (const value of [0, 0.5, 1, 1.7, -0.2, 0.3333]) {
    ws.send({type: "volume", value});
    await until(() => daemon.commands("volume").length === seen.length + 1, 3000, "volume");
    seen.push(daemon.volume);
  }
  assert.deepEqual(seen, [0, 500, 1000, 1000, 0, 333]);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  assert.match(await peer.request("volume 250"), / ok volume=250$/, "another client drives the same volume");
});

// -- the state rules ----------------------------------------------------------

test("the adoption echo is dropped exactly once, and only when it is slot 0", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const slot0 = daemon.bank.slots[0].values;
  const slot4 = daemon.bank.slots[4].values;
  ws.send({type: "state", values: slot4});
  await until(() => writes(daemon).length === 1, 3000, "slot 4 load");
  assert.deepEqual(writes(daemon), ["patch.load 4"], "a state that is not the echo is not dropped");
  ws.send({type: "state", values: slot0});
  await sleep(80);
  assert.deepEqual(writes(daemon), ["patch.load 4"], "the echo changed nothing");
  ws.send({type: "state", values: slot0});
  await until(() => writes(daemon).length === 2, 3000, "second slot 0");
  assert.deepEqual(writes(daemon), ["patch.load 4", "patch.load 0"], "the second one is a request");
});

test("with slot 0 empty the adoption echo is the Init patch", {skip}, async t => {
  const {ws, daemon} = await page(t, {daemon: {bankText: bankWith(doc => { doc.patches[0] = null; })}});
  ws.send({type: "state", values: DEFAULTS});
  await sleep(80);
  assert.deepEqual(writes(daemon), []);
  ws.send({type: "state", values: DEFAULTS});
  await until(() => writes(daemon).length === 2, 3000, "Init by value");
  assert.match(writes(daemon)[0], /^parameter\.set_many /);
  assert.equal(writes(daemon)[1], "patch.clear");
});

test("an adoption echo that never comes stops being expected", {skip}, async t => {
  const {ws, daemon} = await page(t, {adoptMs: 60});
  await sleep(120);
  ws.send({type: "state", values: daemon.bank.slots[0].values});
  await until(() => writes(daemon).length === 1, 3000, "slot 0 load");
  assert.deepEqual(writes(daemon), ["patch.load 0"]);
});

test("a state that is a filled slot's sound becomes patch.load and moves the identity", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "state", values: daemon.bank.slots[0].values});
  await sleep(50);
  ws.send({type: "state", values: daemon.bank.slots[7].values});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Brass", index: 7, bank: "My Bank"});
  assert.deepEqual(writes(daemon), ["patch.load 7"]);
  assert.equal(daemon.identity.slot, 7);
});

test("a sound two slots hold loads the slot already current, else the lowest", {skip}, async t => {
  const {env, ws, daemon} = await page(t, {daemon: {bankText: bankWith(doc => { doc.patches[9] = doc.patches[4]; })}});
  ws.send({type: "state", values: daemon.bank.slots[0].values});
  const shared = daemon.bank.slots[4].values;
  ws.send({type: "state", values: shared});
  await until(() => writes(daemon).length === 1, 3000, "first load");
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 9");
  await ws.next(m => m.type === "patch" && m.index === 9);
  ws.send({type: "state", values: shared});
  await until(() => writes(daemon).length === 3, 3000, "second load");
  assert.deepEqual(writes(daemon), ["patch.load 4", "patch.load 9", "patch.load 9"]);
});

test("a sound no slot holds clears the identity the daemon was showing", {skip}, async t => {
  const {env, ws, daemon} = await page(t);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 5");
  await ws.next(m => m.type === "patch" && m.index === 5);
  const values = daemon.bank.slots[5].values.slice();
  values[19] = (values[19] + 1) % 128;
  ws.send({type: "state", values});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Untitled", index: null, bank: ""});
  assert.deepEqual(daemon.identity, {slot: -1, bank: "", name: ""});
});

test("malformed state arrays are refused and the page is put back", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const bad = [
    {values: "nope"}, {values: [1, 2, "3"]}, {values: []}, {values: new Array(100).fill(0)},
    {values: [1.5]}, {values: DEFAULTS.map((v, i) => (i === 19 ? 100000 : v))}, {},
  ];
  for (const fields of bad) {
    ws.send({type: "state", ...fields});
    const error = await ws.next("error");
    assert.equal(error.for, "state");
    assert.ok(["invalid_payload", "out_of_range"].includes(error.code), error.code);
    assert.deepEqual((await ws.next("state")).values, daemon.published.values, "resynchronised");
  }
  assert.deepEqual(writes(daemon), []);
});

// -- banks from the page ------------------------------------------------------

test("a bank from the page is adopted from a private file holding its exact text", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const text = bankWith(doc => { doc.name = "Page Bank"; doc.patches[30] = doc.patches[1]; });
  let seen = null;
  daemon.intercept = req => {
    if (req.command !== "bank.load_file") return undefined;
    seen = {
      path: req.rest,
      text: fs.readFileSync(req.rest, "utf8"),
      file: fs.statSync(req.rest).mode & 0o777,
      dir: fs.statSync(req.rest.slice(0, req.rest.lastIndexOf("/"))).mode & 0o777,
    };
    return undefined;
  };
  ws.send({type: "bank", text});
  await until(() => daemon.bank.label === "Page Bank", 3000, "adoption");
  assert.equal(seen.text, text);
  assert.equal(seen.file, 0o600);
  assert.equal(seen.dir, 0o700);
  // Removed once the daemon has answered, which is after it read the file.
  await until(() => !fs.existsSync(seen.path), 3000, "the file to be removed");
  assert.deepEqual(strayTempDirs(), []);
  await sleep(40);
  assert.deepEqual(writes(daemon), [`bank.load_file ${seen.path}`], "no keep without save");
});

test("a bank sent with save:true is also kept", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "bank", text: bankWith(doc => { doc.name = "Kept"; }), save: true});
  await until(() => daemon.commands("bank.keep").length === 1, 3000, "keep");
  assert.deepEqual(writes(daemon).map(l => l.split(" ")[0]), ["bank.load_file", "bank.keep"]);
  assert.equal(fs.readFileSync(daemon.keepPath, "utf8"), writeBank(daemon.bank));
  ws.send({type: "bank", text: bankWith(doc => { doc.name = "Kept"; }), save: "yes"});
  await until(() => daemon.commands("bank.load_file").length === 2, 3000, "second adopt");
  await sleep(40);
  assert.equal(daemon.commands("bank.keep").length, 1, "only save === true keeps");
});

test("a page's bank is not echoed to it, but reaches every other page", {skip}, async t => {
  const {env, ws, daemon} = await page(t);
  const other = await env.open();
  await other.synced();
  ws.send({type: "bank", text: bankWith(doc => { doc.name = "Shared"; })});
  const bank = await other.next("bank");
  assert.equal(JSON.parse(bank.text).name, "Shared");
  assert.equal(bank.text, writeBank(daemon.bank));
  assert.deepEqual(await ws.quiet(150, "bank"), []);
});

// A page stores by posting its whole bank with one slot changed (the panel's
// SynthBank.store). `state` is the page's live sound.
const HIDDEN = PARAMS.map(p => p.index).filter(i => !REGISTRY.some(d => d.index === i));

function stored(state, changes, label) {
  const doc = JSON.parse(FIXTURE);
  if (label !== undefined) doc.name = label;
  for (const [slot, name, edit] of changes) {
    const values = state.slice();
    if (edit) edit(values);
    const entry = {parameters: Object.fromEntries(PARAMS.map(p => [p.name, values[p.index]]))};
    if (name !== undefined) entry.name = name;
    doc.patches[slot] = entry;
  }
  return JSON.stringify(doc, null, 2) + "\n";
}

function verbs(daemon) {
  return writes(daemon).map(line => line.split(" ")[0]);
}

test("storing into one slot is a patch.save, so the slot becomes the identity everywhere", {skip}, async t => {
  const {env, ws, daemon, synced} = await page(t);
  const other = await env.open();
  await other.synced();
  const live = synced.state.values;

  ws.send({type: "bank", text: stored(live, [[20, "My Lead"]])});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "My Lead", index: 20, bank: "My Bank"});
  assert.deepEqual(writes(daemon), ["patch.save 20 My Lead"]);
  assert.deepEqual(daemon.identity, {slot: 20, bank: "My Bank", name: "My Lead"});
  assert.equal(daemon.bank.slots[20].name, "My Lead");

  // The other page is sent the bank the store changed, then the identity.
  const bank = await other.next("bank");
  assert.equal(bank.text, writeBank(daemon.bank));
  assert.deepEqual(await other.next("patch"), {type: "patch", name: "My Lead", index: 20, bank: "My Bank"});
  // The sender is not sent its own bank back, and the identity sticks.
  assert.deepEqual(await ws.quiet(150, m => m.type === "bank" || m.type === "patch"), []);
  assert.deepEqual(daemon.identity, {slot: 20, bank: "My Bank", name: "My Lead"});

  // The store updated what this page is known to hold: a second one is
  // recognised as a store against it.
  ws.send({type: "bank", text: stored(live, [[20, "My Lead"], [21, "Second"]])});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Second", index: 21, bank: "My Bank"});
  assert.deepEqual(writes(daemon), ["patch.save 20 My Lead", "patch.save 21 Second"]);
});

test("a store holds the knob the page has just turned, and overwrites a filled slot", {skip}, async t => {
  const {ws, daemon, synced} = await page(t);
  const live = synced.state.values.slice();
  live[19] = 55;
  ws.send({type: "set", index: 19, value: 55});
  ws.send({type: "bank", text: stored(live, [[4, "Pluck 2"]])});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Pluck 2", index: 4, bank: "My Bank"});
  assert.deepEqual(writes(daemon), ["parameter.set filter.cutoff 55", "patch.save 4 Pluck 2"]);
  assert.equal(daemon.bank.slots[4].values[19], 55);
});

test("a store differing only in parameters the daemon hides is still a patch.save", {skip}, async t => {
  const {ws, daemon, synced} = await page(t);
  const text = stored(synced.state.values, [[20, "  Padded  ", values => {
    for (const i of HIDDEN) values[i] = (values[i] + 1) % 128;
  }]]);
  ws.send({type: "bank", text});
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Padded", index: 20, bank: "My Bank"});
  assert.deepEqual(writes(daemon), ["patch.save 20 Padded"], "the name is trimmed");
});

test("anything but a plain store is adopted as a whole bank", {skip}, async t => {
  const cutoff = values => { values[19] = (values[19] + 1) % 128; };
  const cases = {
    "a slot cleared": () => bankWith(doc => { doc.patches[5] = null; }),
    "two slots stored": live => stored(live, [[20, "One"], [21, "Two"]]),
    "a different bank label": live => stored(live, [[20, "One"]], "Somebody's Bank"),
    "values other than the live sound": live => stored(live, [[20, "One", cutoff]]),
    "no name": live => stored(live, [[20, undefined]]),
    "a blank name": live => stored(live, [[20, "   "]]),
    "a tab in the name": live => stored(live, [[20, "Two\tWords"]]),
    "a line break in the name": live => stored(live, [[20, "Two\nLines"]]),
  };
  // A daemon each: after one adoption the bank is no longer the one the
  // next text was made from, which would pass for the wrong reason.
  for (const [what, make] of Object.entries(cases)) {
    await t.test(what, async st => {
      const {ws, daemon, synced} = await page(st);
      ws.send({type: "bank", text: make(synced.state.values)});
      await until(() => writes(daemon).length > 0, 3000, "the adoption");
      await sleep(40);
      assert.deepEqual(verbs(daemon), ["bank.load_file"]);
      assert.equal(daemon.identity.slot, -1);
    });
  }
});

test("a store sent with save:true is kept, as a whole-bank adoption is", {skip}, async t => {
  const {ws, daemon, synced} = await page(t);
  ws.send({type: "bank", text: stored(synced.state.values, [[20, "Kept Lead"]]), save: true});
  await until(() => daemon.commands("bank.keep").length === 1, 3000, "keep");
  assert.deepEqual(writes(daemon), ["patch.save 20 Kept Lead", "bank.keep"]);
  assert.equal(fs.readFileSync(daemon.keepPath, "utf8"), writeBank(daemon.bank));
  ws.send({type: "bank", text: stored(synced.state.values, [[20, "Kept Lead"], [21, "Two"]]), save: "yes"});
  await until(() => daemon.commands("patch.save").length === 2, 3000, "second store");
  await sleep(40);
  assert.equal(daemon.commands("bank.keep").length, 1, "only save === true keeps");
});

test("a refused store is reported and the page gets the daemon's bank back", {skip}, async t => {
  const {ws, daemon, synced} = await page(t);
  daemon.intercept = req => (req.command === "patch.save"
    ? {err: ["invalid_payload", "slot out of range"]} : undefined);
  ws.send({type: "bank", text: stored(synced.state.values, [[20, "Lost"]])});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "bank", code: "invalid_payload", message: "slot out of range"});
  assert.equal((await ws.next("bank")).text, writeBank(daemon.bank));
  assert.equal(daemon.bank.slots[20], null);
});

test("a bank the daemon cannot parse is refused and the page gets the daemon's back", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const before = writeBank(daemon.bank);
  ws.send({type: "bank", text: "{ this is not json"});
  const error = await ws.next("error");
  assert.deepEqual(error, {type: "error", for: "bank", code: "invalid_payload",
    message: "cannot read or parse bank"});
  assert.equal((await ws.next("bank")).text, before);
  assert.deepEqual(strayTempDirs(), []);
});

// -- patch-step ---------------------------------------------------------------

test("patch-step walks filled slots both ways and wraps round the bank", {skip}, async t => {
  const {env, ws, daemon} = await page(t);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  // The fixture fills 0, 1, 3..15 and 127.
  const cases = [[-1, 1, 0], [-1, -1, 127], [1, 1, 3], [3, -1, 1], [127, 1, 0], [0, -1, 127], [15, 2, 0], [0, -3, 14]];
  for (const [from, step, to] of cases) {
    if (from < 0) await peer.request("patch.clear");
    else await peer.request(`patch.load ${from}`);
    const loads = daemon.commands("patch.load").length;
    ws.send({type: "patch-step", step});
    await until(() => daemon.commands("patch.load").length > loads, 3000, "a step");
    assert.equal(daemon.identity.slot, to, `${from} ${step > 0 ? "+" : ""}${step}`);
  }
});

test("patch-step on an empty bank, or with no step, is an error", {skip}, async t => {
  const empty = '{"format": "quesynth.bank", "version": 1, "name": "Empty", "patches": []}\n';
  const {ws, daemon} = await page(t, {daemon: {bankText: empty}});
  ws.send({type: "patch-step", step: 1});
  assert.equal((await ws.next("error")).code, "empty_bank");
  ws.send({type: "patch-step", step: 0});
  assert.equal((await ws.next("error")).code, "invalid_payload");
  ws.send({type: "patch-step", step: "1"});
  assert.equal((await ws.next("error")).code, "invalid_payload");
  assert.deepEqual(writes(daemon), []);
});

// -- everything else ----------------------------------------------------------

test("edit is acknowledged with no daemon traffic and no error", {skip}, async t => {
  const {ws, daemon} = await page(t);
  daemon.log = [];
  ws.send({type: "edit", index: 19, begin: true});
  ws.send({type: "edit", index: 19, begin: false});
  ws.send({type: "edit"});
  await sleep(80);
  assert.deepEqual(daemon.commands().filter(l => l !== "patch.current"), []);
  assert.deepEqual(ws.drain(), []);
});

test("unknown types and malformed JSON get an error and the socket stays open", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "frobnicate"});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "frobnicate", code: "unknown_command", message: "unknown message type"});
  for (const text of ["not json", "[1,2]", "null", '{"type":5}', "{}", '"sync"']) {
    ws.send(text);
    const error = await ws.next("error");
    assert.equal(error.for, "");
    assert.equal(error.code, "invalid_payload", text);
  }
  ws.send('{"type":"__proto__"}');
  assert.equal((await ws.next("error")).code, "unknown_command");
  await ws.synced();
  assert.deepEqual(writes(daemon), []);
});

test("fields are validated before any daemon command is built", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const bad = [
    {type: "set", index: 19, value: "1\n1 9 daemon.shutdown"},
    {type: "set", index: "19", value: 1},
    {type: "set", index: 19.5, value: 1},
    {type: "set", index: 99, value: 1},
    {type: "set", index: 19, value: 1e9},
    {type: "set", index: 94, value: 1},
    {type: "note", on: true, note: "60 0\n1 9 daemon.shutdown", velocity: 1},
    {type: "note", on: 1, note: 60},
    {type: "note", on: true, note: 128},
    {type: "note", on: true, note: 60, velocity: 64.5},
    {type: "note", on: true, note: 60, channel: 16},
    {type: "wheel", which: "pitch", value: "0.5"},
    {type: "wheel", which: "expression", value: 0.5},
    {type: "wheel", which: "mod", value: null},
    {type: "cc", cc: 128, value: 1},
    {type: "cc", cc: 1, value: -1},
    {type: "volume", value: "loud"},
    {type: "bank", text: 42},
    {type: "bank"},
  ];
  for (const msg of bad) {
    ws.send(msg);
    const error = await ws.next("error");
    assert.equal(error.for, msg.type, JSON.stringify(msg));
  }
  // Infinity cannot be written in JSON, but a number too big for a double
  // parses to it.
  ws.send('{"type":"volume","value":1e400}');
  assert.equal((await ws.next("error")).for, "volume");
  ws.send('{"type":"wheel","which":"pitch","value":-1e400}');
  assert.equal((await ws.next("error")).for, "wheel");
  await sleep(60);
  assert.deepEqual(writes(daemon), []);
  assert.equal(daemon.commands().filter(l => /\n|shutdown/.test(l)).length, 0);
});
