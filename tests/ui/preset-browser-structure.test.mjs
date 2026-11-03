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
import {bootPanel, compiledBank, plain} from "./support/panel.mjs";
import {all, body, label, open, option, options, press, searchBox, tab} from "./support/browser.mjs";

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
