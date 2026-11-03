// Save As and Write: choosing where the sound that is playing goes.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 3.1, 5.3 and 8 phase 4):
// Save on something that cannot take it opens Save As; Save As and Write are the
// explicit, slot-targeting operations; both go through write_preset_to_slot
// only; overwriting asks first; a read-only bank refuses; and the edit marker
// is cleared by a write that happened and by nothing else.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {
  all, badges, dialog, dialogs, feedback, focused, front, heading, label, press, settle, sourceNames, sourceRow, submit, type,
} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);
const field = page => page.document.querySelector(".browser-save-name");
const where = page => page.document.querySelector(".browser-save-slot").textContent;
const slot = (page, i) => all(page, ".browser-slot")[i];
const target = page => all(page, ".browser-slot").findIndex(s => s.classList.contains("target"));
const bankNames = (page, bank, count = 6) => {
  const api = page.window.SynthBank;
  const was = api.current();
  api.select(plain(api.list()).findIndex(b => b.label === bank), true);
  const out = plain(api.slots()).slice(0, count).map(s => s && s.name);
  api.select(was, true);
  return out;
};

// My Bank: Alpha, Bravo, -, Delta. Playing Bravo, edited. The browser build.
function app({store = true} = {}) {
  const page = bootPanel({bank: FACTORY, host: null, store});
  const api = page.window.SynthBank;
  api.newBank("My Bank");
  for (const [at, name] of [[0, "Alpha"], [1, "Bravo"], [3, "Delta"]]) api.writePreset({bank: "My Bank", slot: at, name});
  api.loadPreset({bank: "My Bank", slot: 1});
  page.window.SynthPatch.setParam(19, 0.9);
  // Whatever calls `store` goes round the one door, which is what these tests are about.
  api.store = () => { throw new Error("the browser wrote through store() and not writePreset()"); };
  return page;
}

// ---------------------------------------------------------------------- Save As

test("Save As opens on the first empty slot of the bank, with the name of the sound in a field that has the focus", () => {
  const page = app();
  const opener = page.$("preset-save");
  opener.focus();
  page.window.SynthBrowser.saveAs();

  assert.equal(front(page).getAttribute("aria-label"), "Save As");
  assert.equal(page.document.querySelector(".browser").getAttribute("data-mode"), "saveas");
  assert.equal(all(page, '[role="tab"]').length, 0, "a destination is a slot");
  assert.equal(page.document.querySelector(".browser-bank-name").textContent, "My Bank");
  assert.equal(target(page), 2, "slots 0 and 1 are taken, so the first empty one is 2");
  assert.equal(where(page), "Slot 002");
  assert.equal(focused(page), field(page));
  assert.equal(field(page).value, "Bravo");
  assert.equal(label(page.document.querySelector(".browser-save .modal-action")), "Save");
  assert.equal(all(page, ".browser-slot").length, 128, "every slot is there to be chosen, the empty ones as well");
});

test("Save As offers the banks that can take a preset, and New bank... for one that does not exist yet", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  const api = page.window.SynthBank;
  api.newBank("Mine");
  api.importBank("Theirs", [{n: "Zither", v: sound(5)}]);
  api.select(0, true);
  page.window.SynthBrowser.saveAs();
  assert.deepEqual(sourceNames(page), ["Mine", "Theirs"], "the factory bank has nowhere to keep it, so it is not offered");
  assert.deepEqual(all(page, ".browser-heading .browser-heading-actions button").map(label), ["New bank..."]);
  assert.equal(api.label(), "Mine", "and the one in view is one that can take it");
});

test("an archive is never offered as somewhere to save", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  page.send({type: "bank", v: 1, origin: "user", readOnly: false, text: JSON.stringify({
    format: "quesynth.bank", version: 1, name: "Hosted", patches: [{name: "Alpha", parameters: {}}]})});
  page.window.SynthBrowser.saveAs();
  assert.deepEqual(sourceNames(page), ["Hosted"]);
  assert.equal(page.document.querySelector(".browser-archive").hidden, true);
  page.window.SynthBrowser.write();
  assert.deepEqual(sourceNames(page), ["Hosted"], "nor is it in Write, which lists every bank that is not one");
});

test("Save As writes to an empty slot with no question, says so, and clears the edit marker", () => {
  const page = app();
  assert.equal(page.window.SynthBank.status(), "dirty");
  page.window.SynthBrowser.saveAs();
  type(page, field(page), "Charlie");
  submit(page.document.querySelector(".browser-save"));

  assert.equal(dialogs(page).length, 0, "no question was asked, and the dialog is done");
  assert.deepEqual(bankNames(page, "My Bank"), ["Alpha", "Bravo", "Charlie", "Delta", null, null]);
  assert.equal(page.text("bank-status"), "Saved Charlie to My Bank / 002.");
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "ok");
  assert.equal(page.window.SynthBank.status(), "clean", "what was written is what the slot now holds");
  assert.ok(page.$("bank-dirty").hasAttribute("hidden"));
  assert.equal(page.text("bank-patch"), "002:Charlie");
});

test("Save As on a slot that holds something asks first, names it, and Cancel writes nothing and leaves the edit alone", async () => {
  const page = app();
  page.window.SynthBrowser.saveAs();
  slot(page, 0).click();
  assert.equal(where(page), "Slot 000");
  type(page, field(page), "Charlie");
  submit(page.document.querySelector(".browser-save"));

  const question = front(page);
  assert.equal(dialogs(page).length, 2, "over the dialog that asked, which is still there");
  assert.equal(question.getAttribute("role"), "alertdialog");
  assert.equal(question.getAttribute("aria-label"), "Overwrite slot 000?");
  assert.deepEqual([...question.querySelectorAll(".modal-message p")].map(p => p.textContent),
    ["My Bank / 000 already holds Alpha.", "Writing Charlie there will replace it."]);
  assert.equal(label(focused(page)), "Cancel");
  assert.equal(bankNames(page, "My Bank")[0], "Alpha", "not yet");

  [...question.querySelectorAll("button")].find(b => label(b) === "Cancel").click();
  await settle();
  assert.equal(dialogs(page).length, 1);
  assert.equal(bankNames(page, "My Bank")[0], "Alpha");
  assert.equal(page.window.SynthBank.status(), "dirty", "the edit is still unsaved");
  assert.equal(focused(page), field(page), "and the person is back in the name they were typing");
  assert.equal(field(page).value, "Charlie");

  submit(page.document.querySelector(".browser-save"));
  [...front(page).querySelectorAll("button")].find(b => label(b) === "Overwrite").click();
  await settle();
  assert.equal(dialogs(page).length, 0);
  assert.equal(bankNames(page, "My Bank")[0], "Charlie");
  assert.equal(page.window.SynthBank.status(), "clean");
});

test("a name that cannot be used is refused beside the field, and the dialog, the slot and the edit stay as they were", () => {
  const page = app();
  page.window.SynthBrowser.saveAs();
  for (const [text, message] of [
    ["   ", /A name cannot be empty\. \(InvalidName\)/],
    ["x".repeat(49), /That name is 49 bytes; the most a slot keeps is 48\. \(InvalidName\)/],
    ["Tab\tin it", /control characters\. \(InvalidName\)/],
  ]) {
    type(page, field(page), text);
    submit(page.document.querySelector(".browser-save"));
    assert.match(feedback(page).textContent, message);
    assert.equal(feedback(page).getAttribute("data-kind"), "error");
    assert.equal(focused(page), field(page));
    assert.equal(dialogs(page).length, 1);
  }
  assert.deepEqual(bankNames(page, "My Bank"), ["Alpha", "Bravo", null, "Delta", null, null]);
  assert.equal(page.window.SynthBank.status(), "dirty");
});

test("a name that somebody typed is theirs, and choosing another slot does not take it back", () => {
  const page = app();
  page.window.SynthBrowser.saveAs();
  assert.equal(field(page).value, "Bravo");
  slot(page, 5).click();
  assert.equal(field(page).value, "Bravo", "a name nobody changed is the name of the sound being written");
  type(page, field(page), "Mine");
  slot(page, 6).click();
  assert.equal(field(page).value, "Mine");
  assert.equal(where(page), "Slot 006");
});

test("New bank... makes the place to save when there is none, and the dialog goes on in it", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  page.window.SynthPatch.setParam(19, 0.9);
  page.window.SynthBrowser.saveAs();
  assert.deepEqual(sourceNames(page), []);
  assert.match(page.document.querySelector(".browser-empty").textContent, /No bank here can take a new preset yet/);
  const save = page.document.querySelector(".browser-save .modal-action");
  assert.ok(save.disabled, "and there is nothing yet to press Save on");

  heading(page, "New bank...").click();
  type(page, page.document.querySelector(".browser-form-name"), "Fresh");
  submit(page.document.querySelector(".browser-form"));
  assert.deepEqual(sourceNames(page), ["Fresh"]);
  assert.equal(all(page, ".browser-slot").length, 128);
  assert.ok(!save.disabled);
  assert.equal(target(page), 0, "an empty bank starts at its first slot");

  type(page, field(page), "First Sound");
  submit(page.document.querySelector(".browser-save"));
  assert.equal(dialogs(page).length, 0);
  assert.deepEqual(bankNames(page, "Fresh", 2), ["First Sound", null]);
});

test("Save, on a sound that has nowhere to go back to, opens this dialog; on one that has, it does not", () => {
  const page = app();
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 0});
  page.$("preset-save").click();
  assert.equal(dialogs(page).length, 0, "a user bank's own slot is written in place");

  page.window.SynthBank.importBank("Theirs", [{n: "Zither", v: sound(5)}]);
  page.window.SynthBank.loadPreset({bank: "Theirs", slot: 0});
  page.$("preset-save").focus();
  page.$("preset-save").click();
  assert.equal(front(page).getAttribute("aria-label"), "Save As", "somebody else's bank is not overwritten");
  assert.equal(focused(page), field(page));
});

test("Save As goes through writePreset and nothing else: its answer is what the panel reported", () => {
  const page = app();
  const seen = [];
  page.window.SynthBank.onResult(r => seen.push(plain(r)));
  page.window.SynthBrowser.saveAs();
  type(page, field(page), "Charlie");
  submit(page.document.querySelector(".browser-save"));
  assert.equal(seen.length, 1);
  assert.deepEqual([seen[0].ok, seen[0].action, seen[0].bank, seen[0].slot, seen[0].name, seen[0].overwrote],
    [true, "write", "My Bank", 2, "Charlie", false]);
});

// ------------------------------------------------------------------------ Write

test("Write keeps the legacy default: the sound's own slot, with every bank listed and the read-only ones marked", () => {
  const page = app({store: false});
  page.window.SynthBrowser.write();
  assert.equal(front(page).getAttribute("aria-label"), "Write");
  assert.equal(label(page.document.querySelector(".browser-save .modal-action")), "Write");
  assert.equal(target(page), 1, "the preset that is playing is Bravo, in slot 1");
  assert.equal(where(page), "Slot 001");
  assert.equal(field(page).value, "Bravo");
  assert.equal(focused(page), field(page));
  assert.deepEqual(sourceNames(page), ["Quesynth Factory", "My Bank"]);
  assert.deepEqual(badges(sourceRow(page, "Quesynth Factory")), ["Factory", "Read-only"]);
  assert.deepEqual(badges(sourceRow(page, "My Bank")), ["User"]);
});

test("Write onto the sound's own slot writes it with no question: that is what Write is for", () => {
  const page = app();
  page.window.SynthBrowser.write();
  submit(page.document.querySelector(".browser-save"));
  assert.equal(dialogs(page).length, 0);
  assert.equal(page.text("bank-status"), "Saved Bravo to My Bank / 001.");
  assert.equal(page.window.SynthBank.status(), "clean");
});

test("Write onto another preset's slot asks, and the answer decides", async () => {
  const page = app();
  page.window.SynthBrowser.write();
  slot(page, 3).click();
  type(page, field(page), "Echo");
  submit(page.document.querySelector(".browser-save"));
  assert.equal(front(page).getAttribute("aria-label"), "Overwrite slot 003?");
  assert.match(front(page).querySelector(".modal-message").textContent, /My Bank \/ 003 already holds Delta/);
  press(focused(page), "Escape");
  await settle();
  assert.equal(bankNames(page, "My Bank")[3], "Delta");
  assert.equal(dialogs(page).length, 1);
  assert.equal(page.window.SynthBank.status(), "dirty");
});

test("Write into a read-only bank is refused in the panel's words, in the dialog and in the strip, and nothing changes", () => {
  const page = app({store: false});
  page.window.SynthBrowser.write();
  sourceRow(page, "Quesynth Factory").click();
  slot(page, 4).click();
  submit(page.document.querySelector(".browser-save"));

  assert.equal(dialogs(page).length, 1, "the dialog stays so that somewhere else can be chosen");
  assert.match(feedback(page).textContent, /Quesynth Factory is read-only\. \(ReadOnlyBank\)/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");
  assert.equal(page.text("bank-status"), "Quesynth Factory is read-only.");
  assert.deepEqual(bankNames(page, "Quesynth Factory"), ["Init", "Strings", "Brass", "Bells", null, "Choir"]);
  assert.equal(page.window.SynthBank.status(), "dirty", "a write that did not happen does not clear the marker");

  sourceRow(page, "My Bank").click();
  slot(page, 5).click();
  submit(page.document.querySelector(".browser-save"));
  assert.equal(dialogs(page).length, 0);
  assert.equal(bankNames(page, "My Bank")[5], "Bravo");
});

test("Write also goes through writePreset only, whichever slot it lands in", () => {
  const page = app();
  page.window.SynthBrowser.write();
  slot(page, 5).click();
  submit(page.document.querySelector(".browser-save"));
  const last = plain(page.window.SynthBank.lastResult());
  assert.deepEqual([last.ok, last.action, last.bank, last.slot], [true, "write", "My Bank", 5]);
  assert.equal(dialog(page), null);
});

// ------------------------------------------------------- what Cancel leaves alone

// NEXT steps through the bank in view, so a dialog that moved the bank in view
// and was then cancelled would change what the arrows do.
const stepNext = page => page.document.querySelector('.bank-step[data-step="1"]').click();

test("cancelling Save As, with the Escape key or the Cancel button, leaves the bank in view and so what NEXT does as it was", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  page.window.SynthBank.newBank("Mine");
  page.window.SynthBank.select(0, true);
  page.window.SynthBank.loadPreset({bank: "Quesynth Factory", slot: 1});
  page.window.SynthPatch.setParam(19, 0.9);

  const opener = page.$("preset-save");
  opener.focus();
  page.window.SynthBrowser.saveAs();
  assert.equal(page.window.SynthBank.label(), "Mine", "the dialog looks in a bank that can take the sound");
  press(focused(page), "Escape");
  assert.equal(dialogs(page).length, 0);
  assert.ok(focused(page) === opener, "and the focus is back on the button that asked");
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory", "and puts it back");

  page.window.SynthBrowser.saveAs();
  [...front(page).querySelectorAll(".modal-foot button")].find(b => label(b) === "Cancel").click();
  assert.equal(page.window.SynthBank.current(), 0);
  stepNext(page);
  assert.equal(page.text("bank-patch"), "002:Brass", "NEXT goes on from where the sound is");
});

test("cancelling Write puts back the bank that was looked at to choose another", () => {
  const page = app();
  const was = page.window.SynthBank.current();
  page.window.SynthBrowser.write();
  sourceRow(page, "Quesynth Factory").click();
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory");
  press(focused(page), "Escape");
  assert.equal(page.window.SynthBank.current(), was);
});

test("a write that happened leaves the bank it went to in view, because that is where the sound now is", () => {
  const page = app();
  page.window.SynthBrowser.write();
  sourceRow(page, "Quesynth Factory").click();
  slot(page, 4).click();
  submit(page.document.querySelector(".browser-save"));
  assert.equal(dialogs(page).length, 0);
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory");
  assert.equal(plain(page.window.SynthBank.selection()).bank, "Quesynth Factory");
  stepNext(page);
  assert.equal(page.text("bank-patch"), "005:Choir");
});
