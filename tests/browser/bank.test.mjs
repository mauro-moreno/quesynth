import test from "node:test";
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {FIXTURE, ROOT, readBank, writeBank} from "./support/fake-daemon.mjs";

const require = createRequire(import.meta.url);
const bank = require("../../hosts/standalone/browser/bank.js");
const params = bank.loadParams(ROOT);

// odin-bank.json was written by src/patch's own slots_write_json (see
// fixtures/genbank), so these read what a real daemon's bank.write produces.

test("the adapter reads a bank the Odin writer produced, slot for slot", () => {
  const model = bank.parseBank(FIXTURE, params);
  assert.equal(model.label, "My Bank");
  assert.equal(model.slots.length, 128);
  assert.equal(model.slots[2], null, "an empty slot between filled ones stays empty");
  assert.equal(model.slots[3].name, 'Bass "Deep" \\ Ü\ttab');
  assert.equal(model.slots[127].name, "Last");
  assert.equal(model.slots[127].values[19], 5);
  assert.equal(model.slots.filter(Boolean).length, 16);
  for (const slot of model.slots.filter(Boolean)) assert.equal(slot.values.length, 99);
});

test("the fake daemon's bank writer is byte-identical to the Odin writer", () => {
  assert.equal(writeBank(readBank(FIXTURE)), FIXTURE);
});

test("the echo the page sends after adopting is slot 0, or Init when slot 0 is empty", () => {
  const model = bank.parseBank(FIXTURE, params);
  assert.deepEqual(bank.adoptionValues(model, params), model.slots[0].values);
  const doc = JSON.parse(FIXTURE);
  doc.patches[0] = null;
  const hole = bank.parseBank(JSON.stringify(doc), params);
  assert.deepEqual(bank.adoptionValues(hole, params), params.defaults);
});

test("a sound held by two slots is matched to the loaded one, else the lowest", () => {
  const doc = JSON.parse(FIXTURE);
  doc.patches[9] = doc.patches[4];
  const model = bank.parseBank(JSON.stringify(doc), params);
  const values = model.slots[4].values;
  assert.equal(bank.findSlot(model, values, -1), 4);
  assert.equal(bank.findSlot(model, values, 9), 9);
  assert.equal(bank.findSlot(model, params.defaults.map(v => v + 1), -1), -1);
  assert.equal(bank.findSlot(null, values, -1), -1);
});

test("documents the page would refuse are refused, so no echo is expected of them", () => {
  const doc = JSON.parse(FIXTURE);
  assert.throws(() => bank.parseBank("{", params));
  assert.throws(() => bank.parseBank(JSON.stringify({...doc, format: "quesynth.patch"}), params));
  assert.throws(() => bank.parseBank(JSON.stringify({...doc, version: 2}), params));
  assert.throws(() => bank.parseBank(JSON.stringify({...doc, patches: []}), params));
  assert.throws(() => bank.parseBank(JSON.stringify({...doc, patches: [{parameters: {nope: 1}}]}), params));
});
