import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank} from "./support/panel.mjs";
import {body, open} from "./support/browser.mjs";

const bank = compiledBank("Factory", ["Init", "Strings", "Brass"], 12);
const page = () => bootPanel({bank, host: null, store: true});

test("browser opens as an in-page workspace with banks visible", () => {
  const panel = page();
  open(panel);
  const workspace = panel.document.getElementById("browser-workspace");
  assert.equal(workspace.hidden, false);
  assert.equal(workspace.querySelectorAll(".browser-source").length, 1);
  assert.equal(workspace.querySelector(".browser-workspace-head h1").textContent, "Browse presets");
  assert.equal(panel.document.querySelectorAll(".modal").length, 0);
});

test("reopening changes view without replacing the persistent workspace", () => {
  const panel = page();
  open(panel);
  const workspace = panel.document.getElementById("browser-workspace");
  const browser = body(panel);
  panel.window.SynthBrowser.open({view: "slots"});
  assert.strictEqual(body(panel), browser);
  assert.equal(workspace.hidden, false);
  assert.equal(browser.getAttribute("data-view"), "slots");
  assert.equal(workspace.querySelectorAll(".browser-slot").length, 128);
});

test("workspace close returns focus to Browser and leaves focused forms modal", () => {
  const panel = page();
  const opener = panel.$("preset-browse");
  opener.focus();
  open(panel);
  panel.document.querySelector(".browser-workspace-close").click();
  assert.equal(panel.document.getElementById("browser-workspace").hidden, true);
  assert.strictEqual(panel.document.activeElement, opener);

  panel.window.SynthBrowser.saveAs();
  assert.equal(panel.document.querySelector(".modal").getAttribute("aria-label"), "Save preset as");
});
