// The strip beside the preset: Browser, Save and the menu of everything else.
//
// What is checked is what a person at a keyboard or a screen reader depends on:
// each control does what its name says, the menu behaves as a menu does, and
// focus is never left on something that has just been hidden.

import test from "node:test";
import assert from "node:assert/strict";
import {Event} from "./support/dom.mjs";
import {PANEL, bootPanel, compiledBank, sound, syncAnswer} from "./support/panel.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);

const open = page => !page.$("preset-menu-list").hasAttribute("hidden");
const focused = page => page.document.activeElement;
const keydown = (el, key, init = {}) => {
  const e = new Event("keydown", {key, ...init});
  el.dispatchEvent(e);
  return e;
};

// A browser that records what was asked of it.
function browser(page, extra = {}) {
  const calls = [];
  page.window.SynthBrowser = {
    open: () => calls.push("open"), write: () => calls.push("write"), saveAs: () => calls.push("saveAs"),
    importBank: () => calls.push("importBank"), ...extra,
  };
  return calls;
}

test("Browser opens the preset browser, as clicking the preset itself does", () => {
  const page = bootPanel({bank: FACTORY});
  const calls = browser(page);
  page.$("preset-browse").click();
  page.document.querySelector(".bank-read").click();
  assert.deepEqual(calls, ["open", "open"]);
});

test("without a browser the old patch list still opens, so a trimmed panel can still change patch", () => {
  const page = bootPanel({bank: FACTORY, scripts: PANEL.filter(name => name !== "browser.js")});
  assert.equal(page.window.SynthBrowser, undefined);
  page.$("preset-browse").click();
  assert.ok(page.document.getElementById("bank-list").classList.contains("open"));
});

test("the menu is a menu button: it says so, opens on click, and puts focus inside", () => {
  const page = bootPanel({bank: FACTORY});
  const menu = page.$("preset-menu");
  assert.equal(menu.getAttribute("aria-haspopup"), "menu");
  assert.equal(menu.getAttribute("aria-expanded"), "false");
  assert.equal(menu.getAttribute("aria-controls"), "preset-menu-list");
  assert.equal(page.$("preset-menu-list").getAttribute("role"), "menu");
  assert.equal(menu.textContent, "More", "a word, not a glyph");

  menu.click();
  assert.ok(open(page));
  assert.equal(menu.getAttribute("aria-expanded"), "true");
  assert.equal(focused(page).textContent, "Save As...");
  menu.click();
  assert.ok(!open(page), "and a second click closes it");
});

test("the arrow keys, Home and End move between items and wrap, and Arrow Down on the button opens it", () => {
  const page = bootPanel({bank: FACTORY});
  const menu = page.$("preset-menu");
  keydown(menu, "ArrowUp");
  assert.equal(focused(page).textContent, "Write to slot...", "ArrowUp from the button goes in at the end");
  keydown(focused(page), "ArrowDown");
  assert.equal(focused(page).textContent, "Save As...", "and wraps");
  keydown(focused(page), "ArrowUp");
  assert.equal(focused(page).textContent, "Write to slot...");
  keydown(focused(page), "Home");
  assert.equal(focused(page).textContent, "Save As...");
  keydown(focused(page), "End");
  assert.equal(focused(page).textContent, "Write to slot...");
  assert.equal(keydown(focused(page), "ArrowDown").defaultPrevented, true, "so the page does not scroll");
});

test("Escape closes the menu and returns focus to the button that opened it", () => {
  const page = bootPanel({bank: FACTORY});
  page.$("preset-menu").click();
  keydown(focused(page), "Escape");
  assert.ok(!open(page));
  assert.equal(focused(page), page.$("preset-menu"));
});

test("Tab leaves the menu closed, and so does a click anywhere else", () => {
  const page = bootPanel({bank: FACTORY});
  page.$("preset-menu").click();
  keydown(focused(page), "Tab");
  assert.ok(!open(page));
  page.$("preset-menu").click();
  assert.ok(open(page));
  page.document.dispatchEvent(new Event("click"));
  assert.ok(!open(page));
});

test("choosing an item closes the menu and gives focus back to the button before the action runs", () => {
  const page = bootPanel({bank: FACTORY});
  const seen = [];
  page.window.SynthBrowser = {saveAs: () => seen.push([focused(page).id, open(page)])};
  page.$("preset-menu").click();
  focused(page).click();
  assert.deepEqual(seen, [["preset-menu", false]],
    "a dialog opened by the action takes the button, not a hidden item, as where focus returns to");
});

test("each item does its own thing, and only asks the browser for what the browser owns", () => {
  const page = bootPanel({bank: FACTORY});
  const calls = browser(page);
  const exported = [];
  page.window.SynthPatchFile = {savePatch: () => exported.push("patch"), saveBank: () => exported.push("bank"),
    pick: () => exported.push("pick")};
  const item = action => page.document.querySelector(`#preset-menu-list [data-action="${action}"]`);

  item("save-as").click();
  item("write").click();
  item("export-patch").click();
  item("export-bank").click();
  item("import-bank").click();
  assert.deepEqual(calls, ["saveAs", "write", "importBank"]);
  assert.deepEqual(exported, ["patch", "bank"]);

  // A browser that does not offer the newer entry points is not asked for them.
  const older = bootPanel({bank: FACTORY});
  const asked = [];
  older.window.SynthBrowser = {open: () => {}, write: () => asked.push("write")};
  older.window.SynthPatchFile = {pick: () => asked.push("pick")};
  older.document.querySelector('#preset-menu-list [data-action="save-as"]').click();
  older.document.querySelector('#preset-menu-list [data-action="import-bank"]').click();
  assert.deepEqual(asked, ["write", "pick"], "Save As is the Write view, and Import is the file picker");
});

test("an action the build does not have says so instead of doing nothing", () => {
  const page = bootPanel({bank: FACTORY});
  page.window.SynthPatchFile = {};
  page.document.querySelector('#preset-menu-list [data-action="export-bank"]').click();
  assert.equal(page.$("bank-status").hasAttribute("hidden"), false);
  assert.match(page.text("bank-status"), /not available/);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "error");
  assert.equal(page.$("bank-status").getAttribute("role"), "status");
});

test("the status line is a polite live region and is quiet when there is nothing to say", () => {
  const page = bootPanel({bank: FACTORY});
  const line = page.$("bank-status");
  assert.equal(line.getAttribute("aria-live"), "polite");
  assert.ok(line.hasAttribute("hidden"));
  page.window.SynthBank.announce("Something happened.", "ok");
  assert.equal(line.textContent, "Something happened.");
  assert.ok(!line.hasAttribute("hidden"));
  page.window.SynthBank.announce("");
  assert.ok(line.hasAttribute("hidden"));
});

test("a message that is not an error fades; an error stays until the next one", () => {
  const page = bootPanel({bank: FACTORY});
  page.window.timers.length = 0;
  page.window.SynthBank.announce("Fine.", "ok");
  page.window.SynthBank.announce("Broken.", "error");
  const fades = page.window.timers.length;
  page.window.timers.forEach(fn => fn());
  assert.equal(page.text("bank-status"), "Broken.", "the error is still there");
  page.window.SynthBank.announce("Fine again.", "ok");
  page.window.timers.slice(fades).forEach(fn => fn());
  assert.ok(page.$("bank-status").hasAttribute("hidden"));
});

test("the restore banner is up when a host says so and is reachable by keyboard in reading order", () => {
  const page = bootPanel({bank: FACTORY});
  for (const m of syncAnswer({label: "Quesynth Factory", names: ["Strings"], origin: "factory", state: sound(9),
    restore: {type: "restore", v: 1, state: "failed", error: "MissingBank", bank: "Alfmeister Bank", slot: 42, name: "Foo"}})) page.send(m);
  const buttons = page.$("restore-banner").querySelectorAll("button").filter(b => !b.hidden).map(b => b.id);
  assert.deepEqual(buttons, ["restore-retry", "restore-choose", "restore-factory", "restore-keep"]);
  page.$("restore-retry").focus();
  assert.equal(focused(page).id, "restore-retry", "a button the banner shows can be focused");
});
