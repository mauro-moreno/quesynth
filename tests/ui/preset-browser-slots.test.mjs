// Copying and moving a preset from the slot view.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 8 phase 4, 11 and 12): copy
// and move are explicit operations between slots, with overwrite confirmation;
// the confirmation comes BEFORE the write; post-commit undo is deferred. The
// panel is the one that knows what is allowed (a read-only destination, the
// same slot, a move out of a read-only bank) and says so; the browser asks
// first, and shows what the panel answered.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {all, badges, dialogs, feedback, focused, front, label, open, press, settle, slotTool} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);
const within = (el, selector) => [...el.querySelectorAll(selector)];
const names = (page, bank, count = 8) => {
  const api = page.window.SynthBank;
  const was = api.current();
  api.select(plain(api.list()).findIndex(b => b.label === bank), true);
  const out = plain(api.slots()).slice(0, count).map(s => s && s.name);
  api.select(was, true);
  return out;
};

// My Bank: Alpha, Bravo, -, Delta, -. Second Bank: Occupied, -. The browser
// build, so the factory bank is writable, looking at My Bank.
function app({store = true} = {}) {
  const page = bootPanel({bank: FACTORY, host: null, store});
  const api = page.window.SynthBank;
  api.newBank("My Bank");
  for (const [slot, name] of [[0, "Alpha"], [1, "Bravo"], [3, "Delta"]]) api.writePreset({bank: "My Bank", slot, name});
  api.newBank("Second Bank");
  api.writePreset({bank: "Second Bank", slot: 0, name: "Occupied"});
  api.loadPreset({bank: "My Bank", slot: 3});
  api.select(plain(api.list()).findIndex(b => b.label === "My Bank"), true);
  return page;
}

const picker = page => front(page).querySelector(".browser");
const pickerBank = (page, name) => within(picker(page), ".browser-source")
  .find(r => r.querySelector(".browser-source-name").textContent === name);
const pickerSlot = (page, i) => within(picker(page), ".browser-slot")[i];
const sentence = page => picker(page).querySelector(".browser-transfer").textContent;
const foot = (page, text) => within(front(page), ".modal-foot button").find(b => label(b) === text);

// What the page must not have lost or gained when a question was not answered yes.
const world = page => plain({
  names: ["My Bank", "Second Bank", "Quesynth Factory"].map(b => names(page, b)),
  values: page.values(),
  selection: page.window.SynthBank.selection(),
  current: page.window.SynthBank.current(),
});

// -------------------------------------------------------------------- the tools

test("every preset in a slot can be copied or moved, and an empty slot has nothing to take", () => {
  const page = app();
  open(page, {view: "slots"});
  const tools = all(page, ".browser-slot-tool");
  assert.equal(tools.length, 6, "two for each of Alpha, Bravo and Delta");
  assert.deepEqual(tools.map(t => t.getAttribute("aria-label")),
    ["Copy Alpha to...", "Move Alpha to...", "Copy Bravo to...", "Move Bravo to...", "Copy Delta to...", "Move Delta to..."]);
  assert.deepEqual(tools.map(label), ["Copy", "Move", "Copy", "Move", "Copy", "Move"], "the name on it is part of the name it has");
  assert.equal(all(page, ".browser-slot.empty").length, 125);
  assert.equal(all(page, ".browser-cell").filter(c => c.querySelector(".browser-slot.empty") && c.querySelector(".browser-slot-tool")).length, 0);
});

test("the preset view and a destination have no Copy and Move of their own", () => {
  const page = app();
  open(page);
  assert.equal(all(page, ".browser-slot-tool").length, 0);
  page.window.SynthBrowser.write();
  assert.equal(all(page, ".browser-slot-tool").length, 0);
});

test("a patch in the host's archive is not held here to copy, so none of them offers it", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad", "Bass"]});
  open(page, {view: "slots"});
  assert.ok(all(page, ".browser-slot-tool").length > 0, "the page's own bank still does");
  within(page.document, ".browser-source").find(r => /a\.zip/.test(r.textContent)).click();
  assert.equal(all(page, ".browser-slot-tool").length, 0);
});

// ------------------------------------------------------------------------ copy

test("Copy to... asks where, then asks whether, and only then writes", async () => {
  const page = app();
  open(page, {view: "slots"});
  const tool = slotTool(page, "Copy", "Bravo");
  tool.focus();
  tool.click();
  const before = world(page);
  page.forget();

  assert.equal(dialogs(page).length, 2, "over the browser, not instead of it");
  assert.equal(front(page).getAttribute("aria-label"), "Copy Bravo to...");
  assert.equal(sentence(page), "Copy Bravo from My Bank / 001 to My Bank / 002, which is empty.",
    "it starts on the first empty slot of the bank the preset is in");
  assert.deepEqual(within(picker(page), ".browser-source").map(r => r.querySelector(".browser-source-name").textContent),
    ["Quesynth Factory", "My Bank", "Second Bank"], "every bank, to choose from");
  assert.equal(within(picker(page), ".browser-tab").length, 0, "a destination is a slot: no preset view");

  pickerBank(page, "Second Bank").click();
  assert.equal(sentence(page), "Copy Bravo from My Bank / 001 to Second Bank / 001, which is empty.");
  pickerSlot(page, 5).click();
  assert.equal(sentence(page), "Copy Bravo from My Bank / 001 to Second Bank / 005, which is empty.");
  assert.equal(within(picker(page), ".browser-slot.target").length, 1);
  assert.deepEqual(world(page), {...before, current: plain(page.window.SynthBank.current())}, "choosing a place changes nothing");

  foot(page, "Copy here").click();
  const question = front(page);
  assert.equal(dialogs(page).length, 3);
  assert.equal(question.getAttribute("role"), "alertdialog");
  assert.equal(question.getAttribute("aria-label"), "Copy Bravo?");
  assert.deepEqual(within(question, ".modal-message p").map(p => p.textContent),
    ["Copy Bravo from My Bank / 001 to Second Bank / 005.", "Second Bank / 005 is empty."]);
  assert.equal(label(focused(page)), "Cancel");
  assert.equal(names(page, "Second Bank")[5], null, "it has not been written: that is what the question is for");
  assert.deepEqual(page.sent, []);

  foot(page, "Copy").click();
  await settle();
  assert.equal(dialogs(page).length, 1, "the picker closed behind it");
  assert.equal(names(page, "Second Bank")[5], "Bravo");
  assert.deepEqual(names(page, "My Bank"), before.names[0], "the original is where it was");
  assert.deepEqual(page.values(), before.values, "and the sound that is playing is not changed by a copy");
  assert.deepEqual(plain(page.window.SynthBank.selection()), before.selection);
  assert.equal(feedback(page).textContent, "Copied Bravo from My Bank / 001 to Second Bank / 005.");
  assert.equal(page.window.SynthBank.label(), "My Bank", "the browser is looking where it was");
  assert.equal(focused(page), slotTool(page, "Copy", "Bravo"), "and the focus is back on the button that asked");
});

test("Cancel, at either question, changes nothing, and the picker is left as it was to choose again", async () => {
  const page = app();
  open(page, {view: "slots"});
  const before = world(page);
  const last = plain(page.window.SynthBank.lastResult());
  slotTool(page, "Copy", "Bravo").click();
  pickerBank(page, "Second Bank").click();
  pickerSlot(page, 5).click();

  foot(page, "Copy here").click();
  foot(page, "Cancel").click();
  await settle();
  assert.equal(dialogs(page).length, 2, "the question is gone and the picker is not");
  assert.equal(within(picker(page), ".browser-slot.target")[0], pickerSlot(page, 5), "with the choice still made");
  assert.equal(names(page, "Second Bank")[5], null);

  foot(page, "Cancel").click();
  assert.equal(dialogs(page).length, 1);
  assert.deepEqual(world(page), before);
  assert.equal(page.window.SynthBank.label(), "My Bank", "even looking elsewhere is put back");
  assert.equal(focused(page), slotTool(page, "Copy", "Bravo"));
  assert.deepEqual(plain(page.window.SynthBank.lastResult()), last, "no copy was ever attempted, so nothing was reported");
});

test("Escape and the backdrop are Cancel for the question as well", async () => {
  const page = app();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  foot(page, "Copy here").click();
  assert.equal(dialogs(page).length, 3);
  page.document.dispatchEvent(Object.assign(new page.window.Event("keydown"), {key: "Escape"}));
  await settle();
  assert.equal(dialogs(page).length, 2);
  assert.equal(names(page, "My Bank")[2], null, "nothing was copied into the first empty slot");
});

test("a destination that holds a preset says so before it is asked, and asks in words that name it", async () => {
  const page = app();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Bravo").click();
  pickerBank(page, "Second Bank").click();
  pickerSlot(page, 0).click();
  assert.equal(sentence(page), "Copy Bravo from My Bank / 001 to Second Bank / 000, which holds Occupied and would be replaced.");
  const before = world(page);

  foot(page, "Copy here").click();
  assert.deepEqual(within(front(page), ".modal-message p").map(p => p.textContent), [
    "Copy Bravo from My Bank / 001 to Second Bank / 000.",
    "Second Bank / 000 already holds Occupied. It will be replaced.",
  ]);
  assert.equal(within(front(page), ".modal-foot button").map(label).at(-1), "Overwrite");
  assert.equal(label(focused(page)), "Cancel", "an overwrite has to be reached for");

  foot(page, "Cancel").click();
  await settle();
  assert.deepEqual(world(page), before, "refused, Occupied is still there");

  foot(page, "Copy here").click();
  foot(page, "Overwrite").click();
  await settle();
  assert.equal(names(page, "Second Bank")[0], "Bravo");
  assert.equal(feedback(page).getAttribute("data-kind"), "ok");
});

test("an empty slot between two presets is a destination like any other, and the numbers around it do not move", async () => {
  const page = app();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  pickerSlot(page, 2).click();
  assert.ok(pickerSlot(page, 2).classList.contains("empty"));
  foot(page, "Copy here").click();
  foot(page, "Copy").click();
  await settle();
  assert.deepEqual(names(page, "My Bank", 5), ["Alpha", "Bravo", "Alpha", "Delta", null]);
});

// ------------------------------------------------------------------------ move

test("Move to... says that the original will be emptied, and does it as one change", async () => {
  const page = app();
  open(page, {view: "slots"});
  const values = page.values();
  assert.equal(plain(page.window.SynthBank.selection()).slot, 3, "Delta is the preset that is playing");
  slotTool(page, "Move", "Delta").click();
  assert.equal(front(page).getAttribute("aria-label"), "Move Delta to...");
  pickerBank(page, "Second Bank").click();
  pickerSlot(page, 4).click();
  assert.equal(sentence(page), "Move Delta from My Bank / 003 to Second Bank / 004, which is empty.");

  foot(page, "Move here").click();
  assert.equal(front(page).getAttribute("aria-label"), "Move Delta?");
  assert.deepEqual(within(front(page), ".modal-message p").map(p => p.textContent), [
    "Move Delta from My Bank / 003 to Second Bank / 004.", "Second Bank / 004 is empty.", "My Bank / 003 will be emptied.",
  ]);
  assert.equal(names(page, "My Bank")[3], "Delta", "not yet");
  foot(page, "Move").click();
  await settle();

  assert.deepEqual(names(page, "My Bank", 5), ["Alpha", "Bravo", null, null, null]);
  assert.equal(names(page, "Second Bank")[4], "Delta");
  assert.equal(feedback(page).textContent, "Moved Delta from My Bank / 003 to Second Bank / 004.");
  assert.deepEqual(page.values(), values);
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "user", source: "bank", bank: "Second Bank", slot: 4, presetName: "Delta", archive: null},
    "the sound that was moved is now at its new address, and the selection went with it");
});

// -------------------------------------------------------- what the panel refuses

test("a move out of a read-only bank is refused in the panel's words, and the picker stays for another try", async () => {
  const page = app({store: false});
  const api = page.window.SynthBank;
  api.select(0, true);
  open(page, {view: "slots"});
  slotTool(page, "Move", "Strings").click();
  assert.deepEqual(badges(pickerBank(page, "Quesynth Factory")), ["Factory", "Read-only"]);
  pickerBank(page, "My Bank").click();
  const before = world(page);
  foot(page, "Move here").click();
  foot(page, "Move").click();
  await settle();

  assert.match(feedback(page).textContent, /Quesynth Factory is read-only, so nothing can be moved out of it\. \(ReadOnlyBank\)/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");
  assert.equal(dialogs(page).length, 2, "the picker is still there");
  assert.deepEqual(world(page), before);
  assert.equal(page.text("bank-status"), "Quesynth Factory is read-only, so nothing can be moved out of it.", "and the strip says it too");
});

test("a copy out of a read-only bank is allowed", async () => {
  const page = app({store: false});
  page.window.SynthBank.select(0, true);
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Strings").click();
  pickerBank(page, "My Bank").click();
  pickerSlot(page, 7).click();
  foot(page, "Copy here").click();
  foot(page, "Copy").click();
  await settle();
  assert.equal(names(page, "My Bank", 8)[7], "Strings");
  assert.deepEqual(names(page, "Quesynth Factory", 6), ["Init", "Strings", "Brass", "Bells", null, "Choir"]);
});

test("a read-only destination is listed and marked, and choosing it gets the panel's refusal and changes nothing", async () => {
  const page = app({store: false});
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  assert.deepEqual(badges(pickerBank(page, "Quesynth Factory")), ["Factory", "Read-only"]);
  pickerBank(page, "Quesynth Factory").click();
  pickerSlot(page, 4).click();
  const before = world(page);
  foot(page, "Copy here").click();
  foot(page, "Copy").click();
  await settle();
  assert.match(feedback(page).textContent, /Quesynth Factory is read-only\. \(ReadOnlyBank\)/);
  assert.equal(dialogs(page).length, 2);
  assert.deepEqual(world(page), before);
});

test("the same slot is refused, in words, after the question", async () => {
  const page = app();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  pickerSlot(page, 0).click();
  assert.ok(pickerSlot(page, 0).classList.contains("source"), "the slot it came from is marked in the picker");
  const before = world(page);
  foot(page, "Copy here").click();
  foot(page, "Overwrite").click();
  await settle();
  assert.match(feedback(page).textContent, /That is the same slot\. \(InvalidSlot\)/);
  assert.deepEqual(world(page), before);
});

test("there is no undo to offer after the fact: the answer was asked for before", async () => {
  const page = app();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  foot(page, "Copy here").click();
  foot(page, "Copy").click();
  await settle();
  const controls = all(page, "button, [role='button']").map(label).join(" ");
  assert.doesNotMatch(controls, /undo/i);
  assert.equal(within(feedback(page), "button").length, 0);
});

// ------------------------------------------------------------- the one door

test("a copy and a move each go through their own call on the panel, once, and through nothing that writes a slot by itself", async () => {
  const page = app();
  const api = page.window.SynthBank;
  const calls = [];
  for (const name of ["copySlot", "moveSlot", "writePreset", "store", "clear"]) {
    const real = api[name];
    api[name] = (...args) => { calls.push(name); return real.apply(api, args); };
  }
  open(page, {view: "slots"});

  slotTool(page, "Copy", "Alpha").click();
  foot(page, "Copy here").click();
  foot(page, "Copy").click();
  await settle();
  assert.deepEqual(calls, ["copySlot"]);

  calls.length = 0;
  slotTool(page, "Move", "Bravo").click();
  pickerBank(page, "Second Bank").click();
  pickerSlot(page, 7).click();
  foot(page, "Move here").click();
  foot(page, "Move").click();
  await settle();
  assert.deepEqual(calls, ["moveSlot"], "one change, not a copy and then a clear");
  assert.equal(names(page, "Second Bank", 8)[7], "Bravo");
  assert.equal(names(page, "My Bank", 2)[1], null);
});

// ---------------------------------------------------------------- the keyboard

test("Tab stays in the dialog that is in front, and Escape takes them away one at a time, the focus going back each time", async () => {
  const page = app();
  open(page, {view: "slots"});
  const tool = slotTool(page, "Copy", "Bravo");
  tool.focus();
  tool.click();

  const controls = () => all(page, ".modal button, .modal input").filter(el => front(page).contains(el) && el.getAttribute("tabindex") !== "-1");
  const last = controls().at(-1);
  last.focus();
  assert.equal(press(last, "Tab").defaultPrevented, true);
  assert.ok(front(page).contains(focused(page)), "the picker is not a way out to the browser under it");

  foot(page, "Copy here").click();
  const question = front(page);
  const [first, , end] = [...question.querySelectorAll("button")];
  end.focus();
  press(end, "Tab");
  assert.ok(focused(page) === first, "nor is the question");

  press(focused(page), "Escape");
  await settle();
  assert.equal(dialogs(page).length, 2);
  assert.equal(front(page).getAttribute("aria-label"), "Copy Bravo to...");
  press(focused(page), "Escape");
  assert.equal(dialogs(page).length, 1);
  assert.ok(focused(page) === slotTool(page, "Copy", "Bravo"), "and the person is where they started");
});
