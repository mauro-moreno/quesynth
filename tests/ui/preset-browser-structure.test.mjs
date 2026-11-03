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
import {all, body, chip, label, open, option, options, press, searchBox, star, tab} from "./support/browser.mjs";

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
