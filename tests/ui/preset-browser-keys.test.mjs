// The preset browser by keyboard and by name: what a person who cannot see it,
// or cannot point at it, can do with it.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 9): keyboard navigation,
// Escape, focus return and screen-reader labels work. Concretely here: the
// results are a listbox of options with a roving focus, Enter chooses, Escape
// clears a search before it closes, Tab cannot leave the dialog, focus goes
// back to whatever opened it, and every control has a name.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {all, body, chip, dialog, feedback, focused, heading, label, names, open, option, options, press, pressed, searchBox, selected, slotTool, star, tab, type} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);
const browser = () => bootPanel({bank: FACTORY, host: null, store: true});

// ------------------------------------------------------------------- the names

test("the results are a listbox of options, and what is playing is the one that is selected", () => {
  const page = browser();
  open(page);
  const list = page.document.querySelector('[role="listbox"]');
  assert.equal(list.getAttribute("aria-label"), "Presets");
  assert.equal(options(page).length, 5);
  for (const o of options(page)) assert.ok(["true", "false"].includes(o.getAttribute("aria-selected")));
  assert.deepEqual(selected(page), ["Init"]);
  assert.ok(options(page).every(o => list.contains(o)));
});

test("every control in the browser has a name, in both views and in the destination dialog", () => {
  const page = browser();
  page.window.SynthBank.newBank("Second");
  const named = el => (el.getAttribute("aria-label") || label(el) || el.getAttribute("title") || "").length > 0;
  const nameless = () => all(page, ".modal button, .modal input, .modal [role='option'], .modal [role='tab']")
    .filter(el => !named(el)).map(el => `${el.tagName} ${el.className}`);

  open(page);
  assert.deepEqual(nameless(), [], "preset view");
  tab(page, "Slots").click();
  assert.deepEqual(nameless(), [], "slot view");
  heading(page, "New bank...").click();
  assert.deepEqual(nameless(), [], "the form that names a bank");
  page.window.SynthBrowser.write();
  assert.deepEqual(nameless(), [], "write dialog");
  page.window.SynthBrowser.saveAs();
  assert.deepEqual(nameless(), [], "save as dialog");
  page.window.SynthBank.newBank("Third");
  open(page, {view: "slots"});
  page.window.SynthBank.writePreset({bank: "Third", slot: 0, name: "Alpha"});
  slotTool(page, "Copy", "Alpha").click();
  assert.deepEqual(nameless(), [], "the dialog that chooses where a copy goes");
  assert.ok(all(page, ".browser-slot-tool").length > 0);
});

test("each filter says whether it is pressed, each star says which preset it is for, and the statuses are status regions", () => {
  const page = browser();
  open(page);
  for (const c of all(page, ".browser-chip")) assert.ok(["true", "false"].includes(c.getAttribute("aria-pressed")), label(c));
  for (const name of names(page)) {
    assert.equal(star(page, name).getAttribute("aria-pressed"), "false");
    assert.equal(star(page, name).tagName, "BUTTON");
  }
  assert.equal(body(page).querySelector(".browser-now").getAttribute("role"), "status");
  assert.equal(body(page).querySelector(".browser-count").getAttribute("role"), "status");
  assert.equal(feedback(page).getAttribute("role"), "status");
  assert.equal(searchBox(page).getAttribute("aria-label"), "Search presets by name");
  assert.equal(searchBox(page).type, "search");
  assert.equal(page.document.querySelector('[role="tablist"]').getAttribute("aria-label"), "Browser view");
  assert.equal(page.document.querySelector('[role="tabpanel"]').getAttribute("aria-labelledby"), tab(page, "Presets").id);
  tab(page, "Slots").click();
  assert.equal(page.document.querySelector('[role="tabpanel"]').getAttribute("aria-labelledby"), tab(page, "Slots").id);
});

test("the search box has the focus when the browser opens on presets", () => {
  const page = browser();
  open(page);
  assert.equal(focused(page), searchBox(page));
});

// ------------------------------------------------------------------- the arrows

test("Arrow Down from the search box goes to the row that is playing, and the arrows, Home and End move between rows", () => {
  const page = browser();
  open(page);
  page.window.SynthBank.loadPreset({bank: 0, slot: 2});
  searchBox(page).focus();

  assert.equal(press(searchBox(page), "ArrowDown").defaultPrevented, true);
  assert.equal(focused(page), option(page, "Brass"), "Brass is playing");
  press(focused(page), "ArrowDown");
  assert.equal(focused(page), option(page, "Bells"));
  press(focused(page), "ArrowDown");
  assert.equal(focused(page), option(page, "Choir"));
  press(focused(page), "ArrowDown");
  assert.equal(focused(page), option(page, "Choir"), "and it stops at the end rather than going round");
  press(focused(page), "Home");
  assert.equal(focused(page), option(page, "Init"));
  press(focused(page), "End");
  assert.equal(focused(page), option(page, "Choir"));
  press(focused(page), "ArrowUp");
  assert.equal(focused(page), option(page, "Bells"));
  press(focused(page), "Home");
  press(focused(page), "ArrowUp");
  assert.equal(focused(page), searchBox(page), "up from the top goes back to the search box");
});

test("the list is one tab stop, wherever you are in it, and the star beside that row is the next", () => {
  const page = browser();
  open(page);
  const stops = () => all(page, '.browser-result, .browser-star').filter(el => el.getAttribute("tabindex") === "0")
    .map(el => el.getAttribute("role") === "option" ? el.querySelector(".browser-result-name").textContent : "star " + el.getAttribute("aria-label"));
  assert.deepEqual(stops(), ["Init", "star Favorite Init"]);
  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(focused(page), "ArrowDown");
  press(focused(page), "ArrowDown");
  assert.deepEqual(stops(), ["Brass", "star Favorite Brass"]);
});

test("Enter and Space load the row that has the focus, and the focus stays on it", () => {
  const page = browser();
  open(page);
  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(focused(page), "ArrowDown");
  press(focused(page), "ArrowDown");
  assert.deepEqual(plain(page.window.SynthBank.selection()).slot, 0, "moving is not loading");

  const entered = press(focused(page), "Enter");
  assert.equal(entered.defaultPrevented, true);
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Brass");
  assert.deepEqual(page.values(), sound(72));
  assert.equal(focused(page), option(page, "Brass"), "the list was repainted under the focus and gave it back");
  assert.deepEqual(selected(page), ["Brass"]);

  press(focused(page), "ArrowDown");
  press(focused(page), " ");
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Bells");
});

test("Arrow Down from the search box on a narrowed list goes to the first row when nothing in it is playing", () => {
  const page = browser();
  open(page);
  type(page, searchBox(page), "o");
  assert.deepEqual(names(page), ["Choir"]);
  press(searchBox(page), "ArrowDown");
  assert.equal(focused(page), option(page, "Choir"));
  type(page, searchBox(page), "e");
  assert.deepEqual(names(page), ["Bells"]);
});

test("Enter in the search box moves into the list and does not load anything", () => {
  const page = browser();
  open(page);
  type(page, searchBox(page), "bra");
  const before = plain(page.window.SynthBank.selection());
  press(searchBox(page), "Enter");
  assert.equal(focused(page), option(page, "Brass"));
  assert.deepEqual(plain(page.window.SynthBank.selection()), before);
});

test("the stars are reached with Tab and pressed with Enter, and the focus stays on the star", () => {
  const page = browser();
  open(page);
  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(focused(page), "ArrowDown");
  // The browser moves focus to the star on Tab; it presses it on Enter, which for a
  // button is a click.
  star(page, "Strings").focus();
  star(page, "Strings").click();
  assert.equal(star(page, "Strings").getAttribute("aria-pressed"), "true");
  assert.equal(focused(page), star(page, "Strings"), "the row was repainted and the focus came back to the star");
  press(focused(page), "ArrowDown");
  assert.equal(focused(page), star(page, "Brass"), "the arrows move between rows from the star as well");
});

test("un-starring the last favorite in Favorites hands the focus to the next row, or the search box when none is left", () => {
  const page = browser();
  open(page);
  star(page, "Strings").click();
  star(page, "Bells").click();
  chip(page, "Favorites").click();
  assert.deepEqual(names(page), ["Strings", "Bells"]);

  star(page, "Strings").focus();
  star(page, "Strings").click();
  assert.deepEqual(names(page), ["Bells"]);
  assert.equal(focused(page), star(page, "Bells"));

  star(page, "Bells").click();
  assert.deepEqual(names(page), []);
  assert.equal(focused(page), searchBox(page));
});

// ------------------------------------------------------------------ the tabs

test("the two views are tabs: one is in the tab order, and the arrows move between them", () => {
  const page = browser();
  open(page);
  assert.equal(tab(page, "Presets").getAttribute("tabindex"), "0");
  assert.equal(tab(page, "Slots").getAttribute("tabindex"), "-1");
  tab(page, "Presets").focus();
  press(tab(page, "Presets"), "ArrowRight");
  assert.equal(body(page).getAttribute("data-view"), "slots");
  assert.equal(focused(page), tab(page, "Slots"));
  assert.equal(tab(page, "Slots").getAttribute("aria-selected"), "true");
  assert.equal(tab(page, "Slots").getAttribute("tabindex"), "0");
  assert.equal(tab(page, "Presets").getAttribute("tabindex"), "-1");
  press(tab(page, "Slots"), "ArrowLeft");
  assert.equal(body(page).getAttribute("data-view"), "presets");
  assert.equal(focused(page), tab(page, "Presets"));
  press(tab(page, "Presets"), "End");
  assert.equal(body(page).getAttribute("data-view"), "slots");
  press(tab(page, "Slots"), "Home");
  assert.equal(body(page).getAttribute("data-view"), "presets");
});

// -------------------------------------------------------------------- Escape

test("Escape clears the search first, and closes only when there is nothing left to clear", () => {
  const page = browser();
  const opener = page.$("preset-browse");
  open(page);
  type(page, searchBox(page), "br");
  assert.deepEqual(names(page), ["Brass"]);

  const first = press(searchBox(page), "Escape");
  assert.equal(first.defaultPrevented, true);
  assert.ok(dialog(page), "the dialog is still there");
  assert.equal(searchBox(page).value, "");
  assert.equal(names(page).length, 5);
  assert.equal(focused(page), searchBox(page));

  press(searchBox(page), "Escape");
  assert.equal(dialog(page), null, "and the second press closes it");
  assert.equal(focused(page), opener, "with focus back on what opened it");
});

test("Escape from a row clears the search too, and puts the focus in the box", () => {
  const page = browser();
  open(page);
  type(page, searchBox(page), "br");
  press(searchBox(page), "ArrowDown");
  assert.equal(focused(page), option(page, "Brass"));
  press(focused(page), "Escape");
  assert.ok(dialog(page));
  assert.equal(searchBox(page).value, "");
  assert.equal(focused(page), searchBox(page));
  press(focused(page), "Escape");
  assert.equal(dialog(page), null);
});

test("with no search to clear, Escape closes the browser at once", () => {
  const page = browser();
  const opener = page.$("preset-browse");
  open(page);
  press(searchBox(page), "Escape");
  assert.equal(dialog(page), null);
  assert.equal(focused(page), opener);
});

test("Escape in the slot view closes it, as it always did", () => {
  const page = browser();
  const opener = page.$("preset-browse");
  open(page, {view: "slots"});
  press(all(page, ".browser-slot")[3], "Escape");
  assert.equal(dialog(page), null);
  assert.equal(focused(page), opener);
});

// ------------------------------------------------------------ focus and Tab

test("focus goes back to whatever opened the browser, however it is closed", () => {
  for (const close of [
    page => press(searchBox(page), "Escape"),
    page => all(page, ".modal-foot button").find(b => label(b) === "Done").click(),
    page => page.document.querySelector(".modal-close").click(),
  ]) {
    const page = browser();
    const opener = page.$("preset-menu");
    open(page, undefined, "preset-menu");
    close(page);
    assert.equal(dialog(page), null);
    assert.equal(focused(page), opener);
  }
});

test("Tab cannot leave the browser: it goes round from the last control to the first and back", () => {
  const page = browser();
  open(page);
  const controls = all(page, ".modal button, .modal input, .modal [tabindex]").filter(el => el.getAttribute("tabindex") !== "-1");
  const first = controls[0], last = controls[controls.length - 1];
  assert.equal(label(first), "CLOSE");
  assert.equal(label(last), "Done");

  last.focus();
  assert.equal(press(last, "Tab").defaultPrevented, true);
  assert.equal(focused(page), first);
  assert.equal(press(first, "Tab", {shiftKey: true}).defaultPrevented, true);
  assert.equal(focused(page), last);
});

test("a question asked over the browser leaves the browser as it was when it is answered", async () => {
  const page = browser();
  open(page);
  type(page, searchBox(page), "br");
  press(searchBox(page), "ArrowDown");
  const answer = page.window.SynthModal.confirm({title: "Sure?", message: "x"});
  assert.equal(all(page, ".modal").length, 2);
  press(focused(page), "Escape");
  assert.equal(await answer, false);
  assert.equal(all(page, ".modal").length, 1);
  assert.equal(searchBox(page).value, "br", "the search was not cleared by the answer");
  assert.equal(focused(page), option(page, "Brass"), "and the focus is back on the row it was on");
});

test("the preset a keyboard user chose is the one the strip shows, with the same name", () => {
  const page = browser();
  open(page);
  searchBox(page).focus();
  press(searchBox(page), "ArrowDown");
  press(focused(page), "End");
  press(focused(page), "Enter");
  assert.equal(page.text("bank-patch"), "005:Choir");
  assert.ok(pressed(chip(page, "Factory")) === false);
});
