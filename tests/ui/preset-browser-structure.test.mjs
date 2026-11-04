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
import {
  all, body, chip, dialog, feedback, focused, front, label, open, option, options, press, searchBox, slotTool, star, submit, tab, tool, type,
} from "./support/browser.mjs";

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
  const page = bootPanel({bank: FACTORY, host: null}); // nothing keeps the factory bank: its rows are read-only
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
  assert.equal(label(trigger), "Slot actions");
  assert.equal(trigger.getAttribute("aria-label"), "Slot actions for Delta");
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
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-label"), "Slot actions for Bravo");
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

test("the menu key and Shift+F10 on a slot ask about it the way a right click does, and do not load it", () => {
  const page = bank();
  open(page, {view: "slots"});
  const before = plain(page.window.SynthBank.selection());
  const trigger = () => details(page).querySelector(".browser-more");
  focusOn(page, cell(page, "Bravo"));
  const menuKey = press(cell(page, "Bravo"), "ContextMenu");
  assert.equal(menuKey.defaultPrevented, true, "so the browser does not open its own");
  assert.equal(trigger().getAttribute("aria-expanded"), "true");
  assert.equal(focused(page), page.document.querySelector('[aria-label="Copy Bravo to..."]'));
  press(focused(page), "Escape");
  assert.equal(focused(page), trigger());

  press(cell(page, "Alpha"), "F10", {shiftKey: true});
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-label"), "Slot actions for Alpha");
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-expanded"), "true");
  press(cell(page, "Delta"), "F10");
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Alpha", "F10 alone is not the menu key");
  assert.deepEqual(plain(page.window.SynthBank.selection()), before);
});

test("with an archive open, the slot view still says what is playing, beside the bank it is browsing, and so does the header", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad", "Bass"]});
  page.send({type: "patch", name: "Strings", index: 1, bank: "Quesynth Factory", source: "bank", v: 1, origin: "factory"});
  open(page, {view: "slots"});
  all(page, ".browser-source").find(r => /a\.zip/.test(r.textContent)).click();
  assert.equal(label(body(page).querySelector(".browser-playing")), "Playing: Strings \u00b7 Quesynth Factory \u00b7 slot 1");
  assert.match(label(body(page).querySelector(".browser-bank-name")), /^Browsing: a\.zip/);
  assert.match(label(now(page)), /^Playing 001 Strings \u00b7 Factory \/ Quesynth Factory/);
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
  assert.equal(all(page, ".browser-details, .browser-action, [data-tool]").length, 0);
  assert.equal(all(page, "button").filter(b => /^(Copy|Move) /.test(b.getAttribute("aria-label") || "")).length, 0);
  assert.ok(body(page).querySelector(".browser-save"));
  for (const b of cells(page)) assert.deepEqual([...b.children].map(c => c.className), ["browser-slot-num", "browser-slot-name"]);
  assert.equal(body(page).querySelectorAll(".browser-tab").length, 0);
  cells(page)[7].click();
  assert.equal(label(body(page).querySelector(".browser-save-slot")), "Slot 007");
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Delta", "choosing a place loads nothing");
});

// ------------------------------------------------- the filters and the banks

const pane = page => body(page).querySelector(".browser-sources");
const toggle = page => body(page).querySelector(".browser-filters-toggle");
const narrowWindow = window => {
  window.matchMedia = media => ({media, matches: /max-width:\s*620px/.test(media), addEventListener() {}, removeEventListener() {}});
};
const phone = () => browser({before: narrowWindow});
const menuOf = (owner) => ({trigger: owner.querySelector(".browser-more"), list: owner.querySelector('[role="menu"]')});
const named = el => el.getAttribute("aria-label") || label(el);
const itemsOf = list => [...list.children].map(label);

test("the banks and the filters are behind a button that says Browse, and says whether it is open and what it opens", () => {
  const page = browser();
  open(page);
  assert.equal(label(toggle(page)), "Browse");
  assert.equal(toggle(page).getAttribute("aria-controls"), pane(page).id);
  assert.ok(pane(page).id, "the pane has an id for it to name");
  assert.equal(toggle(page).getAttribute("aria-expanded"), "true", "with room beside the workspace, it is open to begin with");
  assert.equal(pane(page).hidden, false);
  assert.ok(pane(page).querySelector(".browser-source"), "and it has the banks in it");
  assert.equal(pane(page).querySelectorAll(".browser-chip").length, 7, "and the filters");

  toggle(page).click();
  assert.equal(toggle(page).getAttribute("aria-expanded"), "false");
  assert.equal(pane(page).hidden, true, "shut is hidden: neither the Tab order nor a screen reader meets what is in it");
  toggle(page).click();
  assert.equal(pane(page).hidden, false);
});

test("the pane is where the filters are, and it says on its button when the list has been narrowed", () => {
  const page = browser();
  open(page);
  assert.ok(pane(page).contains(chip(page, "Favorites")));
  assert.ok(pane(page).contains(chip(page, "Factory")));
  assert.equal(label(toggle(page)), "Browse");
  chip(page, "Factory").click();
  chip(page, "Recent").click();
  assert.equal(label(toggle(page)), "Browse · 2", "narrowed by two, and it is the button that is in view");
  chip(page, "Recent").click();
  assert.equal(label(toggle(page)), "Browse · 1");
  chip(page, "Factory").click();
  assert.equal(label(toggle(page)), "Browse");
});

test("a filter that is pressed is still pressed when the other tab has been and gone", () => {
  const page = browser();
  open(page);
  chip(page, "Favorites").click();
  tab(page, "Slots").click();
  assert.equal(pane(page).querySelector('[aria-label="Filters"]').hidden, true, "filters are of the presets, so the slot view has none");
  tab(page, "Presets").click();
  assert.equal(pane(page).querySelector('[aria-label="Filters"]').hidden, false);
  assert.equal(chip(page, "Favorites").getAttribute("aria-pressed"), "true", "the list is still narrowed, and the button says so");
  assert.equal(label(toggle(page)), "Browse · 1");
});

test("the notes that send a person to the banks say where they are now: under Browse", () => {
  const page = browser();
  page.window.SynthBank.addLazy("Unopened Bank", () => Promise.resolve([patch("Hidden", 1)]));
  open(page);
  const hints = all(page, ".browser-note").filter(n => n.getAttribute("data-kind") === "hint").map(label).join(" ");
  assert.match(hints, /Open one under Browse to include it/);
  assert.doesNotMatch(hints, /in Banks/);
});

test("on a phone the pane is shut to begin with, and the workspace is the only thing in the column", () => {
  const page = phone();
  open(page);
  assert.equal(toggle(page).getAttribute("aria-expanded"), "false");
  assert.equal(pane(page).hidden, true);
  assert.equal(details(page).querySelector(".browser-details-toggle").getAttribute("aria-expanded"), "false");
  assert.equal(details(page).querySelector(".browser-details-body").hidden, true, "and the details are a section that opens");
  assert.equal(focused(page), searchBox(page), "the search is what the dialog opens on");
  assert.equal(options(page).length, 5, "the list is there, and not under three panes");
});

test("opening the sheet on a phone moves the focus into it, Escape shuts it and gives the focus back, and the dialog stays", () => {
  const page = phone();
  open(page);
  toggle(page).focus();
  toggle(page).click();
  assert.equal(pane(page).hidden, false);
  assert.ok(pane(page).contains(focused(page)), "the focus is in the sheet");
  assert.equal(toggle(page).getAttribute("aria-expanded"), "true");

  const escape = press(focused(page), "Escape");
  assert.equal(escape.defaultPrevented, true);
  assert.equal(pane(page).hidden, true);
  assert.equal(toggle(page).getAttribute("aria-expanded"), "false");
  assert.equal(focused(page), toggle(page));
  assert.ok(dialog(page), "Escape took the sheet and not the dialog");
  press(toggle(page), "Escape");
  assert.equal(dialog(page), null, "and the next one takes the dialog");
});

test("on a phone, choosing a bank shuts the sheet over what it was chosen to look at", () => {
  const page = phone();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha"});
  open(page, {view: "slots"});
  toggle(page).click();
  all(page, ".browser-source").find(r => label(r.querySelector(".browser-source-name")) === "My Bank").click();
  assert.equal(page.window.SynthBank.label(), "My Bank");
  assert.equal(pane(page).hidden, true);
  assert.equal(focused(page), toggle(page));
});

test("in the pane beside the workspace, Escape is not for the pane: it goes on to the dialog", () => {
  const page = browser();
  open(page);
  const row = all(page, ".browser-source")[0];
  row.focus();
  press(row, "Escape");
  assert.equal(dialog(page), null);
});

test("the pane's actions are not on view: a heading and a bank say a name and a menu button each", () => {
  const page = bank();
  open(page);
  const heading = pane(page).querySelector(".browser-heading");
  const visible = all(page, ".browser-sources button").filter(b => {
    for (let el = b; el && el !== pane(page); el = el.parentNode) if (el.hidden) return false;
    return true;
  });
  assert.deepEqual(visible.filter(b => b.getAttribute("role") === "menuitem").map(label), [], "no action is a button on view");
  assert.equal(heading.querySelectorAll("button").length, 4, "the menu button and its three items");
  assert.equal(heading.querySelectorAll(".browser-heading-actions").length, 0);
});

test("New bank... and the imports are in a menu of their own, with the semantics of the others", () => {
  const page = bank();
  open(page);
  const {trigger, list} = menuOf(pane(page).querySelector(".browser-heading"));
  assert.equal(label(trigger), "Add bank");
  assert.equal(named(trigger), "Add bank", "its name is the words on it");
  assert.equal(trigger.getAttribute("aria-haspopup"), "menu");
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(trigger.getAttribute("aria-controls"), list.id);
  assert.equal(list.getAttribute("role"), "menu");
  assert.equal(list.hidden, true);
  assert.deepEqual(itemsOf(list), ["New bank...", "Import file...", "Import folder..."]);
  assert.ok([...list.children].every(i => i.getAttribute("role") === "menuitem"));

  trigger.click();
  assert.equal(list.hidden, false);
  assert.equal(focused(page), list.children[0]);
  press(list.children[0], "ArrowUp");
  assert.equal(focused(page), list.children[2], "round");
  press(list.children[2], "Escape");
  assert.equal(list.hidden, true);
  assert.equal(focused(page), trigger);
  assert.ok(dialog(page));
});

test("what is done to the bank in view is in its menu, named for it, and says why when it does not apply", () => {
  const page = bank();
  open(page);
  const tools = pane(page).querySelector(".browser-bank-tools");
  const {trigger, list} = menuOf(tools);
  assert.equal(label(tools.querySelector(".browser-bank-tools-name")), "My Bank");
  assert.equal(trigger.getAttribute("aria-label"), "Bank actions for My Bank");
  assert.equal(list.getAttribute("aria-label"), "Bank actions");
  assert.equal(list.hidden, true);
  assert.deepEqual(itemsOf(list), ["Rename...", "Duplicate", "Export bank", "Close bank"]);

  page.window.SynthBank.select(0, true);
  page.window.SynthBrowser.refresh();
  const rename = [...menuOf(tools).list.children].find(i => label(i) === "Rename...");
  assert.equal(rename.getAttribute("aria-disabled"), "true", "the factory bank is not renamed");
  assert.match(rename.title, /belongs to the instrument/);
  assert.equal(label(tools.querySelector(".browser-bank-tools-name")), "Quesynth Factory");
});

test("a destination has a button that says Banks, no filters, and a menu with only New bank...", () => {
  const page = bank();
  page.window.SynthBrowser.write();
  assert.equal(label(toggle(page)), "Banks");
  assert.equal(toggle(page).getAttribute("aria-controls"), pane(page).id);
  assert.equal(pane(page).querySelectorAll(".browser-chip").length, 0);
  assert.deepEqual(itemsOf(menuOf(pane(page).querySelector(".browser-heading")).list), ["New bank..."]);
  assert.equal(pane(page).querySelector(".browser-bank-tools").hidden, true);
});

test("on a phone a destination's banks are a sheet too, and a bank chosen in it is the one the slots are of", () => {
  const page = bootPanel({bank: FACTORY, host: null, store: true, before: narrowWindow});
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.newBank("Second Bank");
  page.window.SynthBrowser.write();
  assert.equal(pane(page).hidden, true);
  toggle(page).click();
  assert.equal(pane(page).hidden, false);
  all(page, ".browser-source").find(r => label(r.querySelector(".browser-source-name")) === "My Bank").click();
  assert.equal(pane(page).hidden, true);
  assert.equal(page.window.SynthBank.label(), "My Bank");
  assert.equal(focused(page), toggle(page));
  assert.equal(label(body(page).querySelector(".browser-save-slot")), "Slot 000");
});

// ------------------------------------------- what each part of the pane is for

const titles = page => [...pane(page).querySelectorAll(".browser-section-title")];
const sectionOf = el => {
  for (let node = el; node; node = node.parentNode) if (node.classList && node.classList.contains("browser-section")) return node;
  return null;
};
const onView = (page, scope) => [...scope.querySelectorAll("button")].filter(b => {
  for (let el = b; el && el !== pane(page); el = el.parentNode) if (el.hidden) return false;
  return true;
});

test("the pane says what each part of it is for -- Sources, Manage banks, Banks, in that order -- in headings that are words and nothing to press", () => {
  const page = bank();
  open(page);
  assert.deepEqual(titles(page).map(label), ["Sources", "Manage banks", "Banks"]);
  for (const t of titles(page)) {
    assert.match(t.tagName, /^H[1-6]$/, "a heading, so that it is found as one");
    assert.equal(t.querySelectorAll("button, input, a, [tabindex]").length, 0);
    assert.equal(t.getAttribute("tabindex"), null);
  }
  const [sources, manage, banks] = titles(page).map(sectionOf);
  assert.deepEqual([...pane(page).children].map(c => c === sources ? "sources" : c === manage ? "manage" : c === banks ? "banks" : c.className),
    ["sources", "manage", "banks"], "the pane is those three and nothing beside them");

  assert.equal(sources.querySelectorAll(".browser-chip").length, 7, "Sources are the filters");
  assert.ok(sources.contains(chip(page, "Favorites")));
  assert.ok([...sources.querySelectorAll("button")].every(b => b.classList.contains("browser-chip")), "and nothing else is pressed there");

  assert.ok(banks.querySelector(".browser-search"), "Banks are the search of them");
  assert.ok(all(page, ".browser-source").length > 1 && all(page, ".browser-source").every(r => banks.contains(r)), "and the list");
  assert.ok([...banks.querySelectorAll("button")].every(b => b.classList.contains("browser-source")), "with nothing to do to one among them");

  assert.ok(manage.contains(pane(page).querySelector(".browser-heading .browser-more")), "Manage banks is where a bank is made...");
  assert.ok(manage.contains(pane(page).querySelector(".browser-bank-tools")), "...and what is done to the one in view");
  assert.ok(manage.contains(pane(page).querySelector(".browser-archive")), "...and the archive");
});

test("Sources go with their filters: in the preset view, and not in the slot view, which has none", () => {
  const page = bank();
  open(page);
  const sources = sectionOf(titles(page)[0]);
  assert.equal(sources.hidden, false);
  tab(page, "Slots").click();
  assert.equal(sources.hidden, true, "no heading is left standing over nothing");
  assert.deepEqual(titles(page).filter(t => !sectionOf(t).hidden).map(label), ["Manage banks", "Banks"]);
  tab(page, "Presets").click();
  assert.equal(sources.hidden, false);
  assert.equal(chip(page, "Factory").getAttribute("aria-pressed"), "false", "and the filters are as they were");
});

test("a destination has Manage banks and Banks and no Sources: it is choosing a place, not narrowing a list", () => {
  const page = bank();
  page.window.SynthBrowser.write();
  assert.deepEqual(titles(page).map(label), ["Manage banks", "Banks"]);
  const manage = sectionOf(titles(page)[0]);
  assert.deepEqual(itemsOf(menuOf(manage.querySelector(".browser-heading")).list), ["New bank..."]);
  assert.equal(manage.querySelector(".browser-bank-tools").hidden, true);
  assert.equal(manage.querySelector(".browser-archive").hidden, true, "and an archive is not somewhere to put a sound");
});

test("the archive's path, Open and Close are still a labelled form, under Manage banks, and there only when there is an archive", () => {
  const without = browser();
  open(without);
  assert.equal(body(without).querySelector(".browser-archive").hidden, true);

  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  open(page);
  const archive = body(page).querySelector(".browser-archive");
  assert.equal(archive.hidden, false);
  const manage = sectionOf(titles(page).find(t => label(t) === "Manage banks"));
  assert.ok(manage && manage.contains(archive), "it is in Manage banks");
  assert.equal(label(archive.querySelector("label")), "Archive");
  assert.ok(archive.querySelector('input[aria-label="Archive path"]'));
  assert.deepEqual([...archive.querySelectorAll("button")].map(b => b.getAttribute("aria-label")), ["Open archive", "Close archive"]);
  assert.equal(archive.querySelectorAll('[role="menu"], [role="menuitem"]').length, 0, "a form, and not a menu of actions");
});

test("a menu button says what it is a menu of, and its name has those words in it and names the thing it is for", () => {
  const page = bank();
  open(page);
  const add = menuOf(pane(page).querySelector(".browser-heading"));
  const tools = menuOf(pane(page).querySelector(".browser-bank-tools"));
  assert.equal(label(add.trigger), "Add bank");
  assert.equal(named(add.trigger), "Add bank");
  assert.equal(label(tools.trigger), "Bank actions");
  assert.equal(named(tools.trigger), "Bank actions for My Bank");
  page.window.SynthBank.select(0, true);
  page.window.SynthBrowser.refresh();
  assert.equal(named(tools.trigger), "Bank actions for Quesynth Factory", "it follows the bank in view");
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  page.window.SynthBrowser.refresh();

  tab(page, "Slots").click();
  const slot = details(page).querySelector(".browser-more");
  assert.equal(label(slot), "Slot actions");
  assert.equal(named(slot), "Slot actions for Delta");

  for (const trigger of [add.trigger, tools.trigger, slot]) {
    assert.ok(named(trigger).startsWith(label(trigger)), `"${named(trigger)}" starts with the words on the button, "${label(trigger)}"`);
  }
  assert.deepEqual([add, tools].map(m => m.list.getAttribute("aria-label")), ["Add a bank", "Bank actions"], "the lists are named as they were");
  assert.equal(page.document.getElementById(slot.getAttribute("aria-controls")).getAttribute("aria-label"), "Slot actions");
});

test("no button in the dialog is called just More, Add or Filters: each says what it is for", () => {
  const page = bank();
  open(page);
  tab(page, "Slots").click();
  const words = all(page, ".modal button").map(label);
  for (const generic of ["More", "Add", "Filters"]) assert.ok(!words.includes(generic), `a button says ${generic}`);
  const destination = bank();
  destination.window.SynthBrowser.write();
  const there = all(destination, ".modal button").map(label);
  for (const generic of ["More", "Add", "Filters"]) assert.ok(!there.includes(generic), `a button in a destination says ${generic}`);
});

test("what is on view in the pane is the filters, the banks and two menu buttons: every other action is behind one of them", () => {
  const page = bank();
  open(page);
  const rest = onView(page, pane(page)).filter(b => !b.classList.contains("browser-chip") && !b.classList.contains("browser-source"));
  assert.deepEqual(rest.map(named), ["Add bank", "Bank actions for My Bank"]);
  assert.ok(rest.every(b => b.getAttribute("aria-haspopup") === "menu"));
  assert.equal(onView(page, pane(page)).filter(b => b.getAttribute("role") === "menuitem").length, 0);
});

// A zip of banks lists a hundred and seventy-five, and every one is a button
// and a Tab stop: what is done to banks has to come before them, or reaching it
// would take a Tab for each.
test("the menu buttons come before the list of banks, so that reaching them does not take a Tab for each bank", () => {
  const stops = extra => {
    const page = browser();
    for (let i = 0; i < extra; i++) page.window.SynthBank.newBank("Bank " + i);
    open(page);
    const tabStops = [...pane(page).querySelectorAll("button, input")].filter(el => {
      for (let node = el; node && node !== pane(page); node = node.parentNode) if (node.hidden) return false;
      return true;
    });
    return {
      banks: all(page, ".browser-source").length,
      first: tabStops[0],
      add: tabStops.indexOf(menuOf(pane(page).querySelector(".browser-heading")).trigger),
      tools: tabStops.indexOf(menuOf(pane(page).querySelector(".browser-bank-tools")).trigger),
      row: tabStops.indexOf(all(page, ".browser-source")[0]),
    };
  };
  const few = stops(2);
  const many = stops(40);
  assert.ok(many.banks >= 30 && many.banks > few.banks);
  assert.equal(many.add, few.add, "Add bank is the same number of Tabs in, however many banks there are");
  assert.equal(many.tools, few.tools, "and so is Bank actions");
  assert.ok(many.add < many.row && many.tools < many.row, "and both are before the first bank");
});

test("what replaces or removes something is the last item of its menu and set apart from the others: Close bank, and Move", () => {
  const page = bank();
  open(page);
  const tools = menuOf(pane(page).querySelector(".browser-bank-tools"));
  const add = menuOf(pane(page).querySelector(".browser-heading"));
  assert.deepEqual([...tools.list.querySelectorAll(".destructive")].map(label), ["Close bank"]);
  assert.equal(label([...tools.list.children].at(-1)), "Close bank");
  assert.equal(add.list.querySelectorAll(".destructive").length, 0, "making a bank takes nothing away");

  tab(page, "Slots").click();
  const slot = menuOf(details(page));
  assert.deepEqual([...slot.list.querySelectorAll(".destructive")].map(label), ["Move"]);
  assert.equal(label([...slot.list.children].at(-1)), "Move");

  for (const list of [tools.list, slot.list]) {
    assert.ok([...list.children].every(i => i.getAttribute("role") === "menuitem"), "every child is an item the arrows land on");
  }
  tools.trigger.click();
  press(focused(page), "End");
  assert.equal(label(focused(page)), "Close bank", "the arrows still reach it");
  press(focused(page), "ArrowDown");
  assert.equal(label(focused(page)), "Rename...", "and go round");
});

// -------------------------------------------------- press and hold, on a touch screen

// A clock the test owns: what the page asks to run later is kept with how long
// it asked to wait, and runs when the test says that long has passed.
function timers(window) {
  const queue = [];
  let next = 0;
  window.setTimeout = (fn, ms) => { queue.push({id: ++next, fn, ms: ms || 0}); return next; };
  window.clearTimeout = id => { const at = queue.findIndex(t => t.id === id); if (at >= 0) queue.splice(at, 1); };
  window.pending = () => queue.map(t => t.ms);
  window.elapse = ms => { for (const t of queue.filter(t => t.ms <= ms)) { queue.splice(queue.indexOf(t), 1); t.fn(); } };
}
const touchy = () => browser({before: timers});
const pointer = (type, init = {}) => new Event(type, {bubbles: true, pointerType: "touch", clientX: 100, clientY: 100, ...init});
const HOLD = 480;
const held = page => page.window.pending().filter(ms => ms >= 300 && ms <= 800);

test("a touch held on a slot asks about it as a right click does, and the release does not load it", () => {
  const page = touchy();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha"});
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 1, name: "Bravo"});
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 0});
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  open(page, {view: "slots"});
  const before = plain(page.window.SynthBank.selection());

  cell(page, "Bravo").dispatchEvent(pointer("pointerdown"));
  assert.equal(held(page).length, 1, "a hold has been started");
  assert.ok(held(page)[0] >= 400 && held(page)[0] <= 600, `and it is ${held(page)[0]}ms`);
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-expanded"), "false", "nothing yet");

  page.window.elapse(HOLD);
  const trigger = details(page).querySelector(".browser-more");
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Bravo");
  assert.equal(trigger.getAttribute("aria-label"), "Slot actions for Bravo");
  assert.equal(trigger.getAttribute("aria-expanded"), "true", "its menu is open");
  assert.equal(focused(page), page.document.querySelector('[aria-label="Copy Bravo to..."]'));
  assert.deepEqual(plain(page.window.SynthBank.selection()), before, "and it was not loaded");

  cell(page, "Bravo").dispatchEvent(pointer("pointerup"));
  focusOn(page, cell(page, "Bravo")); // a browser focuses the button the finger is lifted from
  cell(page, "Bravo").click();
  assert.deepEqual(plain(page.window.SynthBank.selection()), before, "the click the release makes does not load it");
  assert.ok(dialog(page));
  assert.equal(trigger.getAttribute("aria-expanded"), "true", "nor does it shut the menu, as a click elsewhere would");
  assert.equal(focused(page), page.document.querySelector('[aria-label="Copy Bravo to..."]'), "and the focus is back in the menu");

  cell(page, "Bravo").click();
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Bravo", "only that one click: the next is a load");
});

test("a quick tap is still a load, and a hold that was let go of in time is nothing", () => {
  const page = touchy();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha"});
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 1, name: "Bravo"});
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 0});
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  open(page, {view: "slots"});

  cell(page, "Bravo").dispatchEvent(pointer("pointerdown"));
  cell(page, "Bravo").dispatchEvent(pointer("pointerup"));
  assert.equal(held(page).length, 0, "let go: the hold is cancelled");
  cell(page, "Bravo").click();
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Bravo", "a tap loads");

  cell(page, "Alpha").dispatchEvent(pointer("pointerdown"));
  cell(page, "Alpha").dispatchEvent(pointer("pointerup"));
  page.window.elapse(1000);
  assert.equal(details(page).querySelector(".browser-more").getAttribute("aria-expanded"), "false", "and nothing opens late");
});

test("a hold is not one if the finger moves more than a few pixels, or the browser takes the touch for a scroll or the finger leaves", () => {
  const page = touchy();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha"});
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 1, name: "Bravo"});
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 0});
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  open(page, {view: "slots"});
  const bravo = () => cell(page, "Bravo");
  const trigger = () => details(page).querySelector(".browser-more");

  bravo().dispatchEvent(pointer("pointerdown"));
  bravo().dispatchEvent(pointer("pointermove", {clientX: 104, clientY: 97}));
  assert.equal(held(page).length, 1, "a finger is never perfectly still");
  bravo().dispatchEvent(pointer("pointermove", {clientX: 100, clientY: 112}));
  assert.equal(held(page).length, 0, "twelve pixels is a scroll");
  page.window.elapse(1000);
  assert.equal(trigger().getAttribute("aria-label"), "Slot actions for Alpha");

  for (const type of ["pointercancel", "pointerleave"]) {
    bravo().dispatchEvent(pointer("pointerdown"));
    assert.equal(held(page).length, 1, type);
    bravo().dispatchEvent(pointer(type));
    assert.equal(held(page).length, 0, type);
  }
  page.window.elapse(1000);
  assert.equal(label(details(page).querySelector(".browser-detail-name")), "Alpha");
});

test("a mouse never starts a hold, a pen does, and a native contextmenu on top of one changes nothing", () => {
  const page = touchy();
  page.window.SynthBank.newBank("My Bank");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha"});
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 1, name: "Bravo"});
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 0});
  page.window.SynthBank.select(plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank"), true);
  open(page, {view: "slots"});
  const before = plain(page.window.SynthBank.selection());

  cell(page, "Bravo").dispatchEvent(pointer("pointerdown", {pointerType: "mouse"}));
  assert.equal(held(page).length, 0, "a mouse has a right button");

  cell(page, "Bravo").dispatchEvent(pointer("pointerdown", {pointerType: "pen"}));
  assert.equal(held(page).length, 1);
  page.window.elapse(HOLD);
  const trigger = details(page).querySelector(".browser-more");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  const native = cell(page, "Bravo").dispatchEvent(new Event("contextmenu", {bubbles: true, cancelable: true}));
  assert.equal(native, false, "the browser's own menu is kept off");
  assert.equal(trigger.getAttribute("aria-expanded"), "true", "the menu is still open, not toggled shut");
  assert.equal(page.document.querySelectorAll('[aria-label="Copy Bravo to..."]').length, 1);
  cell(page, "Bravo").dispatchEvent(pointer("pointerup", {pointerType: "pen"}));
  cell(page, "Bravo").click();
  assert.deepEqual(plain(page.window.SynthBank.selection()), before);
});

test("a destination has no press and hold: a touch there is a tap that chooses", () => {
  const page = touchy();
  page.window.SynthBrowser.write();
  cells(page)[7].dispatchEvent(pointer("pointerdown"));
  assert.equal(held(page).length, 0);
  cells(page)[7].dispatchEvent(pointer("pointerup"));
  cells(page)[7].click();
  assert.equal(label(body(page).querySelector(".browser-save-slot")), "Slot 007");
});

test("the details say how to look at a slot without loading it, in one sentence that includes the hold", () => {
  const page = bank();
  open(page, {view: "slots"});
  const hint = label(details(page).querySelector(".browser-detail-hint"));
  assert.match(hint, /press and hold/);
  assert.match(hint, /menu key/);
  assert.match(hint, /right-click/);
  assert.equal((hint.match(/\./g) || []).length, 1, hint);
});

// ----------------------------------------------- the window crossing 620px

// A matchMedia the test owns: the width query has an answer it can change, and
// whoever listens is told, as a browser tells them.
function resizable(window) {
  const listeners = new Set();
  const query = {
    media: "(max-width: 620px)", matches: false,
    addEventListener(type, fn) { if (type === "change") listeners.add(fn); },
    removeEventListener(type, fn) { if (type === "change") listeners.delete(fn); },
  };
  window.resize = narrow => { query.matches = narrow; for (const fn of [...listeners]) fn({matches: narrow, media: query.media}); };
  window.listening = () => listeners.size;
  window.matchMedia = media => media === query.media ? query : {media, matches: false, addEventListener() {}, removeEventListener() {}};
}
const sizing = () => browser({before: resizable});
const state = page => ({
  pane: !pane(page).hidden,
  toggle: toggle(page).getAttribute("aria-expanded"),
  details: !details(page).querySelector(".browser-details-body").hidden,
  detailsToggle: details(page).querySelector(".browser-details-toggle").getAttribute("aria-expanded"),
});

test("shrinking the window across 620px with the dialog open shuts the pane and the details, as if it had been opened narrow", () => {
  const page = sizing();
  open(page);
  assert.deepEqual(state(page), {pane: true, toggle: "true", details: true, detailsToggle: "true"});
  page.window.resize(true);
  assert.deepEqual(state(page), {pane: false, toggle: "false", details: false, detailsToggle: "false"},
    "the pane would otherwise be a sheet over the list");
  assert.equal(options(page).length, 5, "the list is there");
});

test("widening it opens them again, as at build time, and a person's own choice does not outlast a crossing", () => {
  const page = sizing();
  open(page);
  toggle(page).click();
  assert.equal(state(page).pane, false, "shut by the person on a wide window");
  page.window.resize(true);
  toggle(page).click();
  assert.equal(state(page).pane, true, "opened by the person on a narrow one");
  page.window.resize(false);
  assert.deepEqual(state(page), {pane: true, toggle: "true", details: true, detailsToggle: "true"});
  page.window.resize(true);
  page.window.resize(true);
  assert.equal(state(page).pane, false, "and a change that is not a crossing is not one more");
});

test("a window that was narrow to begin with, and the dialog of a destination, follow the same crossing", () => {
  const phoneFirst = browser({before: window => { resizable(window); window.resize(true); }});
  open(phoneFirst);
  assert.deepEqual(state(phoneFirst), {pane: false, toggle: "false", details: false, detailsToggle: "false"});
  phoneFirst.window.resize(false);
  assert.deepEqual(state(phoneFirst), {pane: true, toggle: "true", details: true, detailsToggle: "true"});

  const page = sizing();
  page.window.SynthBrowser.write();
  assert.equal(pane(page).hidden, false);
  page.window.resize(true);
  assert.equal(pane(page).hidden, true);
  assert.equal(toggle(page).getAttribute("aria-expanded"), "false");
  page.window.resize(false);
  assert.equal(pane(page).hidden, false);
});

test("focus that was in the pane when the window narrows goes to its button", () => {
  const page = sizing();
  open(page);
  chip(page, "Favorites").focus();
  page.window.resize(true);
  assert.equal(focused(page), toggle(page));
});

test("focus that was in the details goes to their button and the menu open there is shut; focus on a slot stays", () => {
  const page = sizing();
  open(page, {view: "slots"});
  const slotCell = cell(page, "Init");
  focusOn(page, slotCell);
  const trigger = details(page).querySelector(".browser-more");
  trigger.click();
  assert.ok(details(page).contains(focused(page)), "the focus is in the menu in the details");

  page.window.resize(true);
  assert.equal(focused(page), details(page).querySelector(".browser-details-toggle"));
  assert.equal(page.document.getElementById(trigger.getAttribute("aria-controls")).hidden, true);
  assert.equal(trigger.getAttribute("aria-expanded"), "false");

  page.window.resize(false);
  slotCell.focus();
  page.window.resize(true);
  assert.equal(focused(page), slotCell, "a slot is in neither, and keeps it");
});

test("the browser listens for the crossing while it is open and stops when it is closed", () => {
  const page = sizing();
  assert.equal(page.window.listening(), 0);
  open(page);
  assert.equal(page.window.listening(), 1);
  page.window.SynthBrowser.write();
  assert.equal(page.window.listening(), 1, "a destination replaces it, and takes its place");
  press(page.document.activeElement, "Escape");
  assert.equal(page.window.listening(), 0, "nothing is left listening once the dialog is gone");
  page.window.resize(true);
  page.window.resize(false);
});

test("a matchMedia that has only the old addListener is listened to the same way", () => {
  const listeners = new Set();
  const page = browser({before: window => {
    const query = {
      media: "(max-width: 620px)", matches: false,
      addListener(fn) { listeners.add(fn); },
      removeListener(fn) { listeners.delete(fn); },
    };
    window.matchMedia = media => media === query.media ? query : {media, matches: false};
    window.shrink = () => { query.matches = true; for (const fn of [...listeners]) fn(); };
  }});
  open(page);
  assert.equal(listeners.size, 1);
  page.window.shrink();
  assert.equal(pane(page).hidden, true);
  press(page.document.activeElement, "Escape");
  assert.equal(listeners.size, 0);
});

// ------------------------------------------- what a dialog is for, and what to press in it

const title = page => label(front(page).querySelector(".modal-title"));
const footer = page => [...front(page).querySelectorAll(".modal-foot .modal-action")];
const primaries = page => [...front(page).querySelectorAll(".modal-action.primary")].map(label);
const destructive = page => [...front(page).querySelectorAll(".modal-action.destructive")].map(label);
const pickerSlot = (page, i) => front(page).querySelectorAll(".browser-slot")[i];
const pressFoot = (page, words) => footer(page).find(b => label(b) === words).click();

test("each dialog is titled for the task it is for, and is named by that title", () => {
  const cases = [
    ["browsing", page => open(page), "Browse presets"],
    ["Write", page => page.window.SynthBrowser.write(), "Write to slot"],
    ["Save As", page => page.window.SynthBrowser.saveAs(), "Save preset as"],
    ["Copy", page => { open(page, {view: "slots"}); slotTool(page, "Copy", "Alpha").click(); }, "Copy Alpha to..."],
    ["Move", page => { open(page, {view: "slots"}); slotTool(page, "Move", "Alpha").click(); }, "Move Alpha to..."],
  ];
  for (const [what, show, words] of cases) {
    const page = bank();
    show(page);
    assert.equal(title(page), words, what);
    assert.equal(front(page).getAttribute("aria-label"), words, what);
  }
});

test("each dialog has one primary action, where it belongs, and what is beside it is quieter", () => {
  const browse = bank();
  open(browse);
  assert.deepEqual(footer(browse).map(label), ["Export", "Done"]);
  assert.deepEqual(primaries(browse), ["Done"]);

  const slots = bank();
  open(slots, {view: "slots"});
  focusOn(slots, cell(slots, "Bravo"));
  const actions = details(slots).querySelector(".browser-detail-actions");
  assert.deepEqual(actions.querySelectorAll(".browser-action").map(label), ["Load"], "in the details, Load is the one");
  assert.equal(actions.querySelector(".browser-more").classList.contains("browser-action"), false, "and the menu beside it is not another");

  const write = bank();
  write.window.SynthBrowser.write();
  assert.deepEqual(primaries(write), ["Write"], "in a destination, the form's");
  assert.deepEqual(footer(write).map(label), ["Cancel"]);

  const move = bank();
  open(move, {view: "slots"});
  slotTool(move, "Move", "Alpha").click();
  assert.deepEqual(footer(move).map(label), ["Cancel", "Move here"]);
  assert.deepEqual(primaries(move), ["Move here"]);
});

test("a question that replaces or removes something sets its confirm in the destructive tier, and is still the one primary", async () => {
  const overwrite = bank();
  overwrite.window.SynthBrowser.write();
  pickerSlot(overwrite, 1).click();
  submit(overwrite.document.querySelector(".browser-save"));
  assert.equal(front(overwrite).getAttribute("aria-label"), "Overwrite slot 001?");
  assert.deepEqual(destructive(overwrite), ["Overwrite"], "writing over another sound");
  assert.deepEqual(primaries(overwrite), ["Overwrite"]);
  assert.equal(footer(overwrite).find(b => label(b) === "Cancel").classList.contains("destructive"), false);

  const move = bank();
  open(move, {view: "slots"});
  slotTool(move, "Move", "Alpha").click();
  pressFoot(move, "Move here");
  assert.equal(front(move).getAttribute("aria-label"), "Move Alpha?");
  assert.deepEqual(destructive(move), ["Move"], "a move, even into an empty slot, empties the one it came from");

  const over = bank();
  open(over, {view: "slots"});
  slotTool(over, "Copy", "Alpha").click();
  pickerSlot(over, 1).click();
  pressFoot(over, "Copy here");
  assert.deepEqual(destructive(over), ["Overwrite"], "a copy onto something");

  const close = bank();
  open(close);
  tool(close, "Close bank").click();
  assert.equal(front(close).getAttribute("aria-label"), "Close My Bank?");
  assert.deepEqual(destructive(close), ["Close bank"], "closing a bank that holds what is in no file");
  assert.deepEqual(primaries(close), ["Close bank"]);
});

test("a copy into an empty slot takes nothing away, so its question is not in the destructive tier", () => {
  const page = bank();
  open(page, {view: "slots"});
  slotTool(page, "Copy", "Alpha").click();
  pressFoot(page, "Copy here");
  assert.equal(front(page).getAttribute("aria-label"), "Copy Alpha?");
  assert.deepEqual(destructive(page), []);
  assert.deepEqual(primaries(page), ["Copy"]);
});

// ---------------------------------------------- where what an action said is read

test("when browsing, what the last action said is under the tabs and over the workspace, where the details and the pane being shut do not hide it", () => {
  const page = browser();
  const api = page.window.SynthBank;
  open(page);
  star(page, "Brass").click();
  api.loadPreset({bank: 0, slot: 1});
  api.writePreset({bank: 0, slot: 2, name: "Horn", overwrite: true});
  chip(page, "Favorites").click();
  option(page, "Brass").click();
  const said = feedback(page);
  assert.equal(said.hidden, false);
  assert.match(label(said), /Brass is not available now/);

  const kids = [...body(page).children];
  assert.equal(kids.indexOf(said), kids.indexOf(body(page).querySelector(".browser-bar")) + 1, "directly under the tabs");
  assert.equal(kids.indexOf(body(page).querySelector(".browser-main")), kids.indexOf(said) + 1, "and over the workspace, not under it");
  assert.equal(pane(page).contains(said) || details(page).contains(said), false, "and not in what a narrow window shuts");
  assert.equal(all(page, '.modal [role="status"]').filter(el => label(el) === label(said)).length, 1, "said once, in one status region");
});

test("choosing where to put something says what happened beside the form or the line that was asked, and not apart from it", () => {
  const write = bank();
  write.window.SynthBrowser.write();
  type(write, write.document.querySelector(".browser-save-name"), "");
  submit(write.document.querySelector(".browser-save"));
  assert.match(label(feedback(write)), /A name cannot be empty/);
  let kids = [...body(write).children];
  assert.equal(kids.indexOf(feedback(write)), kids.indexOf(body(write).querySelector(".browser-save")) + 1, "under the form");
  assert.equal(kids.indexOf(feedback(write)), kids.length - 1);

  const move = bank();
  open(move, {view: "slots"});
  slotTool(move, "Move", "Alpha").click();
  const picker = front(move).querySelector(".browser");
  kids = [...picker.children];
  assert.equal(kids.indexOf(picker.querySelector(".browser-feedback")), kids.indexOf(picker.querySelector(".browser-transfer")) + 1, "under the line that says what a move would do");
});
