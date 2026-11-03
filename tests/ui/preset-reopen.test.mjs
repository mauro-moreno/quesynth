// Issue #13: reopening a plugin's editor, or toggling REAPER offline and online,
// resets the program and the bank.
//
// The page-side cause was that the panel treated whatever bank it was handed as
// a reason to select slot 0 and tell the host so. The host's real sound and
// program were overwritten by a message nobody asked for, on every editor open.
// The host here is a fake that speaks the wire protocol and nothing else, so
// these tests say what a host may rely on and not how the panel keeps it.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, bankText, plain, sound, syncAnswer} from "./support/panel.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const NAMES = Array.from({length: 50}, (_, i) => i === 42 ? "Foo" : `Imported ${i}`);

// What the page posted that reaches the sound or the program, by type.
const writes = page => page.sent.filter(m => m.type === "state" || m.type === "select").map(m => m.type);

test("a plugin page does not send slot 0 of its compiled-in bank when it opens", () => {
  const page = bootPanel({bank: FACTORY});
  assert.deepEqual(writes(page), [],
    "the host's sound is the host's: opening the editor is not a request to change it");
  assert.equal(page.ofType("sync").length, 1, "the page asks the host for what it has");
});

test("adopting the host's bank does not select slot 0 or tell the host so", () => {
  const page = bootPanel({bank: FACTORY});
  const hostSound = sound(99);
  for (const message of syncAnswer({names: NAMES, state: hostSound, slot: 42, name: "Foo"})) page.send(message);

  assert.deepEqual(writes(page), [], "nothing the host sent comes back as a state or a selection");
  assert.deepEqual(page.values(), hostSound, "the sound is the host's, not slot 0 of its bank");
  assert.equal(page.text("bank-patch"), "042:Foo");
  assert.equal(page.text("bank-name"), "Alfmeister Bank");
  assert.equal(page.window.SynthBank.index(), 42);
});

test("a bank that arrives after the host's state leaves the host's sound alone", () => {
  // Offline/online delivers the pieces of a sync in whatever order the host
  // thread produced them; the sound must not depend on it.
  const page = bootPanel({bank: FACTORY});
  const hostSound = sound(99);
  page.send({type: "state", values: hostSound});
  page.send({type: "bank", text: bankText("Alfmeister Bank", NAMES), v: 1, origin: "imported", readOnly: false, kept: false});
  assert.deepEqual(page.values(), hostSound);
  assert.deepEqual(writes(page), []);
});

test("a host patch message selects its slot, and the page's own stepping continues from there", () => {
  const page = bootPanel({bank: FACTORY});
  for (const message of syncAnswer({names: NAMES, state: sound(99), slot: 42, name: "Foo"})) page.send(message);

  page.send({type: "patch", name: "Imported 7", index: 7, bank: "Alfmeister Bank", v: 1, origin: "imported"});
  assert.equal(page.text("bank-patch"), "007:Imported 7");
  assert.equal(page.window.SynthBank.index(), 7);

  page.window.document.querySelector('.bank-step[data-step="1"]').click();
  assert.equal(page.text("bank-patch"), "008:Imported 8", "NEXT steps from the slot the host named");
});

test("a host with no bank.js page behaves the same: the daemon's page never held a bank", () => {
  const page = bootPanel({});
  for (const message of syncAnswer({names: NAMES, state: sound(99), slot: 42, name: "Foo"})) page.send(message);
  assert.deepEqual(writes(page), []);
  assert.deepEqual(page.values(), sound(99));
});
