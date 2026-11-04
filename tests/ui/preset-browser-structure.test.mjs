// How the browser is put together: the sound that is playing above both views,
// the details beside what is chosen, and where each thing a person might do
// is kept.
//
// The contract is docs/bank-patch-ux-audit.md. It changes how the browser is
// arranged and says nothing new about what it does, so what is here is about
// where things are: whether the answer to "what am I on?" is on the screen
// without reading a bank list, whether a row says only what a row needs to,
// whether an action that is not used every visit is out of the way and still
// reachable by name, and whether the controls that are folded away are really
// out of the way of the keyboard and of a screen reader and not just out of
// sight. The behaviour behind each of them has its own file.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {Event} from "./support/dom.mjs";
import {all, body, chip, dialog, focused, label, open, option, options, press, searchBox, star, tab} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);

// The browser build, so the factory bank can be written to.
const browser = (extra = {}) => bootPanel({bank: FACTORY, host: null, store: true, ...extra});

const now = page => body(page).querySelector(".browser-now");
const details = page => body(page).querySelector(".browser-details");
const facts = page => {
  const out = {};
  const list = details(page).querySelector(".browser-detail-facts");
  const parts = list.children;
  for (let i = 0; i < parts.length; i += 2) out[label(parts[i])] = label(parts[i + 1]);
  return out;
};

// ------------------------------------------------------- the current sound

test("the sound that is playing is named above the tabs, in the preset view and in the slot view alike", () => {
  const page = browser();
  open(page);
  const header = body(page).querySelector(".browser-current");
  assert.equal(header.getAttribute("aria-label"), "Current sound");
  assert.match(label(now(page)), /^Playing 000 Init · Factory \/ Quesynth Factory$/);
  assert.ok(header.contains(now(page)));
  assert.equal(page.document.querySelector('[role="tabpanel"]').contains(now(page)), false,
    "it is above the views, so a view cannot take it away");

  const before = now(page);
  tab(page, "Slots").click();
  assert.equal(now(page), before, "the same header, not a second one");
  assert.match(label(now(page)), /^Playing 000 Init · Factory \/ Quesynth Factory$/);
  assert.equal(now(page).getAttribute("role"), "status");
});

test("the header follows the sound while the slot view is the one in front", () => {
  const page = browser();
  open(page, {view: "slots"});
  page.window.SynthBank.loadPreset({bank: 0, slot: 2});
  assert.match(label(now(page)), /^Playing 002 Brass · Factory \/ Quesynth Factory$/);
  page.window.SynthPatch.setParam(19, 0.9);
  page.window.SynthBrowser.refresh();
  assert.equal(now(page).getAttribute("data-status"), "dirty");
  assert.match(label(now(page)), /Unsaved changes$/);
});

test("a destination dialog has no header of a sound that is playing: it is choosing a place", () => {
  const page = browser();
  page.window.SynthBrowser.write();
  assert.equal(body(page).querySelector(".browser-current"), null);
  assert.equal(body(page).querySelector(".browser-now"), null);
  assert.equal(body(page).querySelector(".browser-details"), null);
});

// ------------------------------------------------------------- the details

test("the details say where the preset the arrows are on comes from, without playing it", () => {
  const page = browser();
  open(page);
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Init", "the preset that is playing, to begin with");
  assert.deepEqual(facts(page), {Source: "Factory", Bank: "Quesynth Factory", Slot: "000", Status: "Playing"});

  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(page.document.activeElement, "ArrowDown");
  press(page.document.activeElement, "ArrowDown");
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Brass");
  assert.deepEqual(facts(page), {Source: "Factory", Bank: "Quesynth Factory", Slot: "002"}, "not playing: no status to say");
  assert.equal(plain(page.window.SynthBank.selection()).slot, 0, "and reading it loaded nothing");
});

test("the details are a button that says whether they are open and what they open", () => {
  const page = browser();
  open(page);
  const toggle = details(page).querySelector(".browser-details-toggle");
  const content = page.document.getElementById(toggle.getAttribute("aria-controls"));
  assert.ok(content, "aria-controls names something that is there");
  assert.ok(details(page).contains(content));
  assert.equal(toggle.getAttribute("aria-expanded"), "true", "beside the list there is room for them");
  assert.equal(content.hidden, false);
  toggle.click();
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  assert.equal(content.hidden, true, "shut is hidden, and not only out of sight");
  toggle.click();
  assert.equal(content.hidden, false);
});

test("in the slot view the details are of the slot that is playing, and an empty slot is said to be empty", () => {
  const page = browser();
  open(page, {view: "slots"});
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Init");
  assert.deepEqual(facts(page), {Source: "Factory", Bank: "Quesynth Factory", Slot: "000", Status: "Playing"});
  page.window.SynthBank.load(4);
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Empty slot");
  assert.equal(facts(page).Slot, "004");
});

test("every option in the list is still a row of the listbox, whatever is beside it", () => {
  const page = browser();
  open(page);
  assert.equal(options(page).length, 5);
  assert.ok(option(page, "Brass"));
  assert.equal(all(page, '[role="tabpanel"] [role="listbox"]').length, 1);
});

// ---------------------------------------------------------------- the rows

const patch = (n, seed) => ({n, v: sound(seed)});

test("a row is a number, a name and one quiet line of where it is, and no badge", () => {
  const page = browser();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 3, name: "Glass Pad"});
  page.window.SynthBank.importBank("Alfmeister Bank", [patch("Zither", 5), null, patch("Harp", 6)]);
  open(page);
  for (const row of options(page)) {
    assert.equal(row.querySelectorAll(".browser-result-num").length, 1);
    assert.equal(row.querySelectorAll(".browser-result-name").length, 1);
    assert.equal(row.querySelectorAll(".browser-result-meta").length, 1, "one line, however much is known");
    assert.equal(row.querySelectorAll(".browser-badge").length, 0, label(row.querySelector(".browser-result-name")));
  }
  assert.equal(label(option(page, "Glass Pad").querySelector(".browser-result-meta")), "User / My Bank");
  assert.equal(label(option(page, "Zither").querySelector(".browser-result-meta")), "Imported / Alfmeister Bank");
});

test("a row that cannot be written to says so in words on its line, not in a badge", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  open(page);
  const row = option(page, "Brass");
  assert.equal(label(row.querySelector(".browser-result-state")), "Read-only");
  assert.ok(row.querySelector(".browser-result-line").contains(row.querySelector(".browser-result-state")));
  assert.equal(row.querySelectorAll(".browser-badge").length, 0);
});

test("only the two states that change what a click does are badges, and a row has at most one", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  page.send({type: "patch", name: "Strings", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
  open(page);
  option(page, "Bass").click();
  const loading = option(page, "Bass");
  assert.deepEqual([...loading.querySelectorAll(".browser-badge")].map(label), ["Loading…"]);
  assert.match(label(loading.querySelector(".browser-result-state")), /Read-only/, "and what was already true is still said");
  for (const row of options(page)) assert.ok(row.querySelectorAll(".browser-badge").length <= 1);
});

test("a preset that is not there is the other badge, and the details do not offer to load it", () => {
  const page = browser();
  const bank = page.window.SynthBank;
  open(page);
  star(page, "Brass").click();
  bank.loadPreset({bank: 0, slot: 1});
  bank.writePreset({bank: 0, slot: 2, name: "Horn", overwrite: true});
  chip(page, "Favorites").click();
  assert.deepEqual([...option(page, "Brass").querySelectorAll(".browser-badge")].map(label), ["Unavailable"]);

  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Brass");
  assert.equal(facts(page).Status, "Unavailable");
  assert.equal(details(page).querySelectorAll(".browser-action").length, 0);
});

// ------------------------------------------------------------ Load, in details

test("Load in the details loads what the arrows have reached, and is not offered for what is already playing", () => {
  const page = browser();
  open(page);
  const offered = () => details(page).querySelectorAll(".browser-action").map(label);
  assert.deepEqual(offered(), [], "Init is the sound that is playing");

  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(page.document.activeElement, "ArrowDown");
  press(page.document.activeElement, "ArrowDown");
  assert.deepEqual(offered(), ["Load"]);
  const load = details(page).querySelector(".browser-action");
  assert.equal(load.getAttribute("aria-label"), "Load Brass");
  assert.equal(plain(page.window.SynthBank.selection()).slot, 0, "moving is not loading");

  load.click();
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Brass");
  assert.deepEqual(offered(), [], "there is nothing left to load");
  assert.equal(page.document.activeElement, option(page, "Brass"), "and the focus is on the row, which is still there");
});

// ---------------------------------------------------------------- the slots

const cells = page => all(page, ".browser-slot");
const cell = (page, name) => cells(page).find(b => label(b.querySelector(".browser-slot-name")) === name);
const focusOn = (page, el) => { el.focus(); el.dispatchEvent(new Event("focus")); };

// A bank with a preset in the first slots and a gap, so that what is empty is
// among what is not.
function bank() {
  const page = browser();
  page.window.SynthBank.newBank("My Bank");
  for (const [slot, name] of [[0, "Alpha"], [1, "Bravo"], [3, "Delta"]]) page.window.SynthBank.writePreset({bank: "My Bank", slot, name});
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 3});
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  return page;
}

test("the slot view lists all 128 slots by index, 000 to 127, and an empty one is a dash", () => {
  const page = bank();
  open(page, {view: "slots"});
  assert.equal(cells(page).length, 128);
  assert.deepEqual(cells(page).map(b => label(b.querySelector(".browser-slot-num"))),
    Array.from({length: 128}, (_, i) => String(i).padStart(3, "0")));
  assert.equal(label(cell(page, "Delta").querySelector(".browser-slot-num")), "003");
  assert.equal(label(cells(page)[2].querySelector(".browser-slot-name")), "—");
  assert.ok(cells(page)[2].classList.contains("empty"));
  assert.ok(cells(page).every(b => b.tagName === "BUTTON"), "and every one is a control, empty or not");
});

test("a slot is its index and its name and nothing else: no tools on it, whatever it holds", () => {
  const page = bank();
  open(page, {view: "slots"});
  for (const b of cells(page)) {
    assert.deepEqual([...b.children].map(c => c.className), ["browser-slot-num", "browser-slot-name"]);
    assert.equal(b.parentNode.className, "browser-grid", "and it is not wrapped in a cell that carries more");
  }
  assert.equal(all(page, ".browser-slot-tool, .browser-slot-tools, .browser-cell").length, 0);
});

test("Copy and Move are in the details, in a menu that is shut until it is asked for", () => {
  const page = bank();
  open(page, {view: "slots"});
  const trigger = details(page).querySelector(".browser-more");
  assert.ok(trigger, "the slot that is playing is a preset in a bank of the page's own");
  assert.equal(label(trigger), "More");
  assert.equal(trigger.getAttribute("aria-label"), "More actions for Delta");
  assert.equal(trigger.getAttribute("aria-haspopup"), "menu");
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  const list = page.document.getElementById(trigger.getAttribute("aria-controls"));
  assert.equal(list.getAttribute("role"), "menu");
  assert.equal(list.getAttribute("aria-label"), "Slot actions");
  assert.equal(list.hidden, true, "shut is hidden, so a keyboard or a screen reader does not meet it");
  assert.deepEqual([...list.children].map(i => [i.getAttribute("role"), label(i), i.getAttribute("aria-label")]),
    [["menuitem", "Copy", "Copy Delta to..."], ["menuitem", "Move", "Move Delta to..."]]);
});

test("the menu opens on a click and on the arrows, moves with the arrows, Home and End, and shuts on Escape, Tab and a click elsewhere", () => {
  const page = bank();
  open(page, {view: "slots"});
  const trigger = details(page).querySelector(".browser-more");
  const list = page.document.getElementById(trigger.getAttribute("aria-controls"));
  const [copy, move] = [...list.children];

  trigger.focus();
  trigger.click();
  assert.equal(list.hidden, false);
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  assert.equal(focused(page), copy, "the focus moves in, to the first");
  press(copy, "ArrowDown");
  assert.equal(focused(page), move);
  press(move, "ArrowDown");
  assert.equal(focused(page), copy, "round");
  press(copy, "ArrowUp");
  assert.equal(focused(page), move);
  press(move, "Home");
  assert.equal(focused(page), copy);
  press(copy, "End");
  assert.equal(focused(page), move);

  const escape = press(move, "Escape");
  assert.equal(escape.defaultPrevented, true);
  assert.equal(list.hidden, true);
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(focused(page), trigger, "and the focus goes back to the button");
  assert.ok(dialog(page), "Escape took the menu and not the dialog");

  press(trigger, "ArrowDown");
  assert.equal(list.hidden, false);
  assert.equal(focused(page), copy);
  press(copy, "Tab");
  assert.equal(list.hidden, true, "Tab leaves it and shuts it");

  press(trigger, "ArrowUp");
  assert.equal(focused(page), move, "up from the button opens it on the last");
  page.document.dispatchEvent(new Event("click", {bubbles: true}));
  assert.equal(list.hidden, true, "a click elsewhere shuts it");
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
});

test("Escape on the button of an open menu shuts the menu before it shuts the dialog", () => {
  const page = bank();
  open(page, {view: "slots"});
  const trigger = details(page).querySelector(".browser-more");
  press(trigger, "ArrowDown");
  trigger.focus();
  press(trigger, "Escape");
  assert.ok(dialog(page), "the dialog is still there");
  assert.equal(page.document.getElementById(trigger.getAttribute("aria-controls")).hidden, true);
  press(trigger, "Escape");
  assert.equal(dialog(page), null);
});

test("choosing Copy gives the focus to the button first, so the dialog it opens gives it back there", async () => {
  const page = bank();
  open(page, {view: "slots"});
  const trigger = details(page).querySelector(".browser-more");
  trigger.click();
  const copy = page.document.querySelector('[aria-label="Copy Delta to..."]');
  copy.click();
  assert.equal(all(page, ".modal").length, 2, "the picker is over the browser");
  assert.equal(page.document.getElementById(trigger.getAttribute("aria-controls")).hidden, true);
  press(focused(page), "Escape");
  assert.equal(all(page, ".modal").length, 1);
  assert.equal(focused(page), trigger);
});

test("a slot that has the focus, and not the one that is playing, is what the details are about, and is not loaded", () => {
  const page = bank();
  open(page, {view: "slots"});
  const before = plain(page.window.SynthBank.selection());
  focusOn(page, cell(page, "Bravo"));
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Bravo");
  assert.deepEqual(facts(page), {Source: "User", Bank: "My Bank", Slot: "001"});
  assert.deepEqual(details(page).querySelectorAll(".browser-action").map(label), ["Load"]);
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-label"), "More actions for Bravo");
  assert.ok(cell(page, "Bravo").classList.contains("inspected"));
  assert.deepEqual(plain(page.window.SynthBank.selection()), before, "looking is not loading");
  assert.equal(label(now(page)).startsWith("Playing 003 Delta"), true, "and the header still says what is playing");

  details(page).querySelector(".browser-action").click();
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Bravo");
  assert.deepEqual(facts(page).Status, "Playing");
  assert.equal(details(page).querySelectorAll(".browser-action").length, 0, "nothing is left to load");
  assert.equal(focused(page), cell(page, "Bravo"), "and the focus is on the slot, which is still there");
});

test("asking about a slot with a right click opens its menu, and an empty slot or an archive's has none to open", () => {
  const page = bank();
  open(page, {view: "slots"});
  const before = plain(page.window.SynthBank.selection());
  const asked = cell(page, "Alpha").dispatchEvent(new Event("contextmenu", {bubbles: true, cancelable: true}));
  assert.equal(asked, false, "the browser's own menu is not wanted over it");
  const trigger = details(page).querySelector(".browser-more");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  assert.equal(focused(page), page.document.querySelector('[aria-label="Copy Alpha to..."]'));
  assert.deepEqual(plain(page.window.SynthBank.selection()), before);

  cells(page)[2].dispatchEvent(new Event("contextmenu", {bubbles: true}));
  assert.equal(details(page).querySelectorAll(".browser-more").length, 0, "slot 002 holds nothing to take");
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Empty slot");
});

test("a click on a slot still loads it and a double click loads it and closes the browser", () => {
  const page = bank();
  open(page, {view: "slots"});
  cell(page, "Alpha").click();
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Alpha");
  assert.ok(dialog(page));
  cell(page, "Bravo").dispatchEvent(new Event("dblclick", {bubbles: true}));
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Bravo");
  assert.equal(dialog(page), null);
});

// ---------------------------------------------------- choosing a destination

test("a destination is still a slot to choose with the form beneath, said to be a destination, and adds nothing to a slot", () => {
  const page = bank();
  page.window.SynthBrowser.write();
  assert.equal(label(body(page).querySelector(".browser-destination")), "Choose destination");
  assert.equal(cells(page).length, 128);
  assert.equal(all(page, ".browser-more, .browser-menuitem, .browser-action, .browser-details").length, 0);
  assert.ok(body(page).querySelector(".browser-save"));
  for (const b of cells(page)) assert.deepEqual([...b.children].map(c => c.className), ["browser-slot-num", "browser-slot-name"]);
  assert.equal(body(page).querySelectorAll(".browser-tab").length, 0);
  cells(page)[7].click();
  assert.equal(label(body(page).querySelector(".browser-save-slot")), "Slot 007");
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Delta", "choosing a place loads nothing");
});
