// The preset browser: what it lists, how it narrows, and what each state of it
// says.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 3.2 and 9): the browser
// opens on a view of presets, searches names across what is already known,
// filters by where a sound came from, and keeps the bank and slot view as the
// second of two coordinated views. Empty slots stay addressable there. A click
// loads a preset in normal mode and only chooses a destination in write mode.
// Lazy banks and unopened archives stay unread however much is searched.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {Event} from "./support/dom.mjs";
import {all, body, chip, feedback, label, names, open, option, options, pressed, searchBox, selected, settle, star, tab, type} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);

// The browser build: store.js is there, so the factory bank can be written to.
const browser = (extra = {}) => bootPanel({bank: FACTORY, host: null, store: true, ...extra});

const patch = (n, seed) => ({n, v: sound(seed)});

// A page holding every kind of preset there is: the factory bank, a bank of the
// person's own, one opened from a file, and a sound loaded from a patch file.
function everything() {
  const page = browser();
  const bank = page.window.SynthBank;
  bank.newBank("My Bank");
  bank.writePreset({bank: "My Bank", slot: 3, name: "Glass Pad"});
  bank.writePreset({bank: "My Bank", slot: 1, name: "Warm Keys"});
  bank.importBank("Alfmeister Bank", [patch("Zither", 5), null, patch("Harp", 6)]);
  page.window.SynthPatch.apply(sound(99), "Loose Ends");
  return page;
}

// ---------------------------------------------------------------- the views

test("the browser opens on its preset view, and Slots is the bank and slot view it has always had", () => {
  const page = browser();
  open(page);
  assert.equal(body(page).getAttribute("data-view"), "presets");
  assert.equal(tab(page, "Presets").getAttribute("aria-selected"), "true");
  assert.equal(tab(page, "Slots").getAttribute("aria-selected"), "false");
  assert.equal(all(page, ".browser-slot").length, 0, "the preset view has no slot grid");
  assert.deepEqual(names(page), ["Init", "Strings", "Brass", "Bells", "Choir"], "and an empty slot is not a preset");

  tab(page, "Slots").click();
  assert.equal(body(page).getAttribute("data-view"), "slots");
  assert.equal(tab(page, "Slots").getAttribute("aria-selected"), "true");
  assert.equal(options(page).length, 0);
  assert.equal(all(page, ".browser-slot").length, 128);
  assert.equal(all(page, ".browser-source").length, 1, "the banks are listed down the left, as they were");
  assert.equal(page.document.querySelector(".browser-bank-name").textContent, "Quesynth Factory");
  assert.equal(page.document.querySelector(".browser-slot.on .browser-slot-num").textContent, "000");

  tab(page, "Presets").click();
  assert.equal(body(page).getAttribute("data-view"), "presets");
  assert.equal(options(page).length, 5);
});

test("open({ view: \"slots\" }) goes straight to the slot view", () => {
  const page = browser();
  open(page, {view: "slots"});
  assert.equal(body(page).getAttribute("data-view"), "slots");
  assert.equal(tab(page, "Slots").getAttribute("aria-selected"), "true");
  assert.equal(all(page, ".browser-slot").length, 128);
  assert.equal(options(page).length, 0);
});

test("any request that is not for the slot view opens the preset view", () => {
  const page = browser();
  for (const asked of [undefined, {}, {view: "presets"}, {view: "bogus"}, null]) {
    page.window.SynthBrowser.open(asked);
    assert.equal(body(page).getAttribute("data-view"), "presets", String(JSON.stringify(asked)));
  }
});

// -------------------------------------------------------------- source filters

test("the five source filters and the two personal ones are toggle buttons, and none pressed means everything", () => {
  const page = everything();
  open(page);
  const filters = ["Factory", "User", "Imported", "Archives", "Current session", "Favorites", "Recent"];
  assert.deepEqual(all(page, ".browser-chip").map(label), filters);
  for (const name of filters) assert.equal(chip(page, name).getAttribute("aria-pressed"), "false", name);
  assert.equal(chip(page, "Factory").tagName, "BUTTON");

  assert.deepEqual(names(page), [
    "Init", "Strings", "Brass", "Bells", "Choir", "Warm Keys", "Glass Pad", "Zither", "Harp", "Loose Ends",
  ]);
});

test("a pressed source shows only what came from it, and several pressed show their union", () => {
  const page = everything();
  open(page);

  chip(page, "Factory").click();
  assert.ok(pressed(chip(page, "Factory")));
  assert.deepEqual(names(page), ["Init", "Strings", "Brass", "Bells", "Choir"]);

  chip(page, "Factory").click();
  chip(page, "User").click();
  assert.ok(!pressed(chip(page, "Factory")));
  assert.deepEqual(names(page), ["Warm Keys", "Glass Pad"]);

  chip(page, "Imported").click();
  assert.deepEqual(names(page), ["Warm Keys", "Glass Pad", "Zither", "Harp"], "pressing another adds to the first");

  chip(page, "User").click();
  chip(page, "Imported").click();
  chip(page, "Current session").click();
  assert.deepEqual(names(page), ["Loose Ends"], "a sound opened from a file is the current session's");

  chip(page, "Current session").click();
  assert.equal(names(page).length, 10, "unpressed again, everything is back");
});

test("Archives lists the open archive bank's patches, and nothing from an archive that is not open", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  open(page);
  chip(page, "Archives").click();
  assert.deepEqual(names(page), ["Pad", "Bass"]);
  assert.match(option(page, "Pad").textContent, /Archive \/ b\.zip/);

  page.send({type: "archive", rev: 2, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: null, patches: []});
  assert.deepEqual(names(page), []);
  assert.equal(body(page).querySelector(".browser-empty").hidden, false);
});

// ---------------------------------------------------------------------- search

test("search narrows by name as you type, ignores case, and says how many are left", () => {
  const page = everything();
  open(page);
  type(page, searchBox(page), "r");
  assert.deepEqual(names(page), ["Strings", "Brass", "Choir", "Warm Keys", "Zither", "Harp"]);
  assert.equal(body(page).querySelector(".browser-count").textContent, "6 presets");

  type(page, searchBox(page), "  BRA ");
  assert.deepEqual(names(page), ["Brass"]);
  assert.equal(body(page).querySelector(".browser-count").textContent, "1 preset");

  type(page, searchBox(page), "");
  assert.equal(names(page).length, 10);
});

test("search covers every bank that is open, and combines with the source filters", () => {
  const page = everything();
  open(page);
  type(page, searchBox(page), "a");
  assert.deepEqual(names(page), ["Brass", "Warm Keys", "Glass Pad", "Harp"]);
  chip(page, "User").click();
  assert.deepEqual(names(page), ["Warm Keys", "Glass Pad"]);
});

test("a search with no answer says so in words, and so does a list with nothing to show", () => {
  const page = browser();
  open(page);
  type(page, searchBox(page), "zzz");
  assert.deepEqual(names(page), []);
  const empty = body(page).querySelector(".browser-empty");
  assert.equal(empty.hidden, false);
  assert.match(empty.textContent, /No preset is called anything like .zzz./);
  assert.equal(body(page).querySelector(".browser-count").textContent, "0 presets");

  type(page, searchBox(page), "");
  chip(page, "Imported").click();
  assert.match(empty.textContent, /No preset comes from the sources chosen/);

  // A bank with nothing in it, and the sound being a slot of it: no preset anywhere.
  const bare = bootPanel({host: null});
  bare.window.SynthBank.newBank("Nothing");
  bare.window.SynthBank.load(0);
  open(bare);
  assert.deepEqual(names(bare), []);
  assert.match(body(bare).querySelector(".browser-empty").textContent, /no presets here yet/i);
});

test("the order is the panel's own and does not move: origin, then the order banks were opened, then slot", () => {
  const page = everything();
  page.window.SynthBank.importBank("Another", [patch("Aardvark", 1)]);
  open(page);
  const expected = plain(page.window.SynthBank.presets()).map(p => p.name);
  assert.deepEqual(names(page), expected);
  assert.deepEqual(names(page), [
    "Init", "Strings", "Brass", "Bells", "Choir", "Warm Keys", "Glass Pad", "Zither", "Harp", "Aardvark", "Loose Ends",
  ], "Warm Keys is slot 1 and Glass Pad slot 3: by slot, not by when they were written");

  // Repainting for any reason leaves it as it was, and favourites do not reorder it.
  page.window.SynthBrowser.refresh();
  star(page, "Harp").click();
  assert.deepEqual(names(page), expected);
  chip(page, "Favorites").click();
  assert.deepEqual(names(page), ["Harp"]);
});

test("each row says its number, its name and where it is from", () => {
  const page = everything();
  open(page);
  const row = option(page, "Glass Pad");
  assert.equal(row.querySelector(".browser-result-num").textContent, "003");
  assert.equal(row.querySelector(".browser-result-meta").textContent, "User / My Bank");
  assert.equal(option(page, "Brass").querySelector(".browser-result-num").textContent, "002");
  assert.equal(option(page, "Zither").querySelector(".browser-result-meta").textContent, "Imported / Alfmeister Bank");
  assert.equal(option(page, "Harp").querySelector(".browser-result-num").textContent, "002", "an interior empty slot keeps its number");
  assert.equal(option(page, "Loose Ends").querySelector(".browser-result-num").textContent, "", "a sound with no slot has no number");
  assert.equal(option(page, "Loose Ends").querySelector(".browser-result-meta").textContent, "File");
});

// ---------------------------------------------------------------- loading

test("a click loads the preset through the panel, and the row that is playing is the one that says so", () => {
  const page = browser();
  open(page);
  assert.deepEqual(selected(page), ["Init"]);
  const strings = page.window.SynthBank.slots()[1].name;
  option(page, strings).click();

  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "factory", source: "bank", bank: "Quesynth Factory", slot: 1, presetName: "Strings", archive: null});
  assert.equal(page.text("bank-patch"), "001:Strings");
  assert.deepEqual(page.values(), sound(71));
  assert.deepEqual(selected(page), ["Strings"]);
  assert.equal(option(page, "Strings").getAttribute("aria-selected"), "true");
  assert.equal(option(page, "Init").getAttribute("aria-selected"), "false");
  assert.match(label(feedback(page)), /^Loaded Strings from Quesynth Factory \/ 001\./);
});

test("the row that is playing follows the selection when something else moves it: NEXT, or the host", () => {
  const page = browser();
  open(page);
  page.document.querySelector('.bank-step[data-step="1"]').click();
  assert.deepEqual(selected(page), ["Strings"]);
  page.send({type: "patch", name: "Bells", index: 3, bank: "Quesynth Factory"});
  assert.deepEqual(selected(page), ["Bells"]);
});

test("an archive preset stays loading until the host answers, and the selection moves only then", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  page.send({type: "patch", name: "Strings", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
  page.forget();
  open(page);
  const before = plain(page.window.SynthBank.selection());
  const values = page.values();

  option(page, "Bass").click();
  assert.deepEqual(page.ofType("archive-load"), [{type: "archive-load", bank: 1, index: 1}]);
  assert.equal(page.window.SynthBank.status(), "loading");
  assert.deepEqual(plain(page.window.SynthBank.selection()), before, "nothing has moved yet");
  assert.deepEqual(page.values(), values);
  assert.deepEqual(selected(page), ["Strings"], "and the list still says Strings is playing");
  assert.equal(option(page, "Bass").getAttribute("aria-busy"), "true");
  assert.match(option(page, "Bass").textContent, /Loading…/);
  assert.match(body(page).querySelector(".browser-now").textContent, /Playing 001 Strings .*Loading…/);
  assert.equal(body(page).querySelector(".browser-now").getAttribute("data-status"), "loading");

  page.send({type: "patch", name: "Bass", index: null, bank: "b.zip", source: "archive", archive: {bank: 1, patch: 1}});
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "archive", source: "archive", bank: "b.zip", slot: null, presetName: "Bass", archive: {bank: 1, patch: 1}});
  assert.deepEqual(selected(page), ["Bass"]);
  assert.equal(option(page, "Bass").getAttribute("aria-busy"), null);
  assert.doesNotMatch(option(page, "Bass").textContent, /Loading/);
  assert.equal(body(page).querySelector(".browser-now").getAttribute("data-status"), "readonly");
});

test("a host that refuses an archive load leaves the selection where it was, and the refusal is read in the dialog", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  page.send({type: "patch", name: "Strings", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
  open(page);
  option(page, "Pad").click();
  page.send({type: "error", for: "archive-load", message: "that zip is damaged"});

  assert.deepEqual(selected(page), ["Strings"]);
  assert.equal(option(page, "Pad").getAttribute("aria-busy"), null);
  assert.notEqual(page.window.SynthBank.status(), "loading", "no longer waiting");
  assert.match(label(feedback(page)), /did not load that patch: that zip is damaged \(HostRejected\)/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");
  assert.equal(feedback(page).getAttribute("role"), "status");
});

// --------------------------------------------------------------------- states

test("a read-only preset says so on its row and in the line that says what is playing", () => {
  const bare = bootPanel({bank: FACTORY, host: null});
  open(bare);
  assert.match(option(bare, "Brass").textContent, /Read-only/);
  assert.match(body(bare).querySelector(".browser-now").textContent, /Playing 000 Init · Factory \/ Quesynth Factory · Read-only/);
  assert.equal(body(bare).querySelector(".browser-now").getAttribute("data-status"), "readonly");

  const writable = browser();
  open(writable);
  assert.doesNotMatch(option(writable, "Brass").textContent, /Read-only/, "the browser build keeps its factory bank, so it can be written");
});

test("an edited sound says it is unsaved, beside what it was loaded from", () => {
  const page = browser();
  open(page);
  page.window.SynthPatch.setParam(19, 0.9);
  page.window.SynthBrowser.refresh();
  assert.match(body(page).querySelector(".browser-now").textContent, /Playing 000 Init · Factory \/ Quesynth Factory · Unsaved changes/);
  assert.equal(body(page).querySelector(".browser-now").getAttribute("data-status"), "dirty");
});

test("a restore that failed is shown as unavailable, and the list carries on as it was", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "restore", v: 1, state: "failed", error: "MissingBank", recoverable: true,
    origin: "imported", bank: "Alfmeister Bank", slot: 42, name: "Foo"});
  open(page);
  assert.equal(body(page).querySelector(".browser-now").getAttribute("data-status"), "unavailable");
  assert.match(body(page).querySelector(".browser-now").textContent, /Unavailable: MissingBank/);
  assert.deepEqual(names(page), ["Init", "Strings", "Brass", "Bells", "Choir", "Untitled"],
    "the bank is as it was, and the sound that is playing is still listed as the current session's");
});

test("a refusal is read in the dialog with its name, not only in the strip behind it", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  open(page);
  page.window.SynthBank.writePreset({bank: 0, slot: 1, name: "x"});
  assert.match(label(feedback(page)), /is read-only\. \(ReadOnlyBank\)$/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");
});

test("what the host said about the archive is shown beside the list, as an error", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: false, path: "/gone.zip", banks: [], bank: null, patches: []});
  open(page);
  page.send({type: "error", for: "archive-open", message: "no such file"});
  const notes = all(page, ".browser-note").map(n => [n.getAttribute("data-kind"), label(n)]);
  assert.deepEqual(notes.filter(([kind]) => kind === "error"), [["error", "no such file"]]);
});

// ----------------------------------------------------- what is not read, and why

test("searching never reads a bank that is listed but not open, and says that it did not", async () => {
  const page = browser();
  let reads = 0;
  page.window.SynthBank.addLazy("Unopened Bank", () => { reads++; return Promise.resolve([patch("Hidden", 1)]); });
  open(page);

  for (const text of ["h", "hidden", "", "x"]) type(page, searchBox(page), text);
  for (const name of ["Factory", "User", "Imported", "Archives", "Current session", "Favorites", "Recent"]) chip(page, name).click();
  assert.equal(reads, 0, "nothing was read");
  assert.ok(!names(page).includes("Hidden"));
  const hints = all(page, ".browser-note").filter(n => n.getAttribute("data-kind") === "hint").map(label);
  assert.match(hints[0], /1 bank is listed but not open, so its presets are not searched/);

  // Opening it is the person's act, and then it is searched.
  for (const name of ["Factory", "User", "Imported", "Archives", "Current session", "Favorites", "Recent"]) {
    if (pressed(chip(page, name))) chip(page, name).click();
  }
  type(page, searchBox(page), "");
  const row = all(page, ".browser-source").find(r => /Unopened Bank/.test(r.textContent));
  row.click();
  await settle();
  assert.equal(reads, 1);
  assert.ok(names(page).includes("Hidden"));
  assert.equal(all(page, ".browser-note").filter(n => n.getAttribute("data-kind") === "hint").length, 0);
});

test("an archive that is present but not open is not asked for anything by a search, and the list says to open it", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: null, patches: []});
  page.forget();
  open(page);
  for (const text of ["pad", "bass", ""]) type(page, searchBox(page), text);
  chip(page, "Archives").click();
  assert.deepEqual(page.sent.filter(m => /^archive-/.test(m.type)), [], "no bank was asked for");
  const hint = all(page, ".browser-note").map(label).find(text => /Archive banks are searched once they are open/.test(text));
  assert.ok(hint, "the list says how to get archive presets into it");

  page.send({type: "archive", rev: 2, open: false, path: "/p.zip", banks: [], bank: null, patches: []});
  assert.ok(all(page, ".browser-note").map(label).some(text => /The archive is not open/.test(text)));
});

// ------------------------------------------------------------------ write mode

test("in write mode a click chooses a destination and loads nothing", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "state", values: sound(40), v: 1}); // a host that speaks version 1
  page.send({type: "patch", name: "Strings", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
  page.forget();
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());

  page.window.SynthBrowser.write();
  assert.equal(body(page).getAttribute("data-view"), "slots", "a destination is a slot");
  assert.equal(all(page, '[role="tab"]').length, 0, "and there is no preset view to be confused with it");
  const slots = all(page, ".browser-slot");
  assert.equal(slots.length, 128, "every slot, the empty ones as well");
  slots[2].click();
  slots[4].click();

  assert.equal(all(page, ".browser-slot.target").length, 1);
  assert.equal(page.document.querySelector(".browser-save-slot").textContent, "Slot 004");
  assert.deepEqual(page.values(), values, "the sound is the one that was being written");
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
  assert.deepEqual(page.sent, [], "and nothing was sent to the host");
});

test("choosing a bank to write into does not load it either", () => {
  const page = browser();
  page.window.SynthBank.newBank("Mine");
  page.window.SynthBank.select(0, true);
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());
  page.window.SynthBrowser.write();
  all(page, ".browser-source").find(r => /Mine/.test(r.textContent)).click();
  assert.equal(page.document.querySelector(".browser-bank-name").textContent, "Mine");
  assert.deepEqual(page.values(), values);
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
});

test("in the preset view, clicking a bank looks at it and does not load anything", () => {
  const page = everything();
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());
  open(page);
  assert.equal(page.window.SynthBank.label(), "My Bank");
  all(page, ".browser-source").find(r => /Alfmeister/.test(r.textContent)).click();
  assert.deepEqual(page.values(), values);
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
  assert.equal(page.window.SynthBank.label(), "Alfmeister Bank", "it is looking there now");
});

// ----------------------------------------------------------------- empty slots

test("the slot view lists all 128 slots in order, and an empty one keeps its number and can be chosen", () => {
  const page = browser();
  page.window.SynthBank.importBank("Gaps", [patch("First", 1), null, null, patch("Fourth", 4)]);
  open(page, {view: "slots"});
  all(page, ".browser-source").find(r => /Gaps/.test(r.textContent)).click();

  const slots = all(page, ".browser-slot");
  assert.equal(slots.length, 128);
  assert.deepEqual(slots.slice(0, 5).map(s => s.querySelector(".browser-slot-num").textContent), ["000", "001", "002", "003", "004"]);
  assert.deepEqual(slots.slice(0, 5).map(s => s.classList.contains("empty")), [false, true, true, false, true]);
  assert.equal(slots[3].querySelector(".browser-slot-name").textContent, "Fourth");
  assert.equal(slots[1].querySelector(".browser-slot-name").textContent, "—");
});

test("an empty slot can be the destination of a write, and the write lands in exactly that slot", () => {
  const page = browser();
  page.window.SynthBank.importBank("Gaps", [patch("First", 1), null, null, patch("Fourth", 4)]);
  page.window.SynthBank.select(page.window.SynthBank.list().findIndex(b => b.label === "Gaps"), true);
  page.window.SynthBrowser.write();
  all(page, ".browser-slot")[2].click();
  assert.ok(all(page, ".browser-slot")[2].classList.contains("target"));
  assert.ok(all(page, ".browser-slot")[2].classList.contains("empty"));
  page.document.querySelector(".browser-save-name").value = "Third";
  page.document.querySelector(".browser-save").dispatchEvent(new Event("submit"));
  assert.deepEqual(plain(page.window.SynthBank.slots()).slice(0, 5).map(s => s && s.name), ["First", null, "Third", "Fourth", null]);
});
