import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {fileURLToPath} from "node:url";
import {Event, createWindow, mountIndexSkeleton} from "./support/dom.mjs";

const UI = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "ui");

// The order ui/index.html loads them in, minus host.js (so the bridge stays
// standalone) and the collaborators app.js treats as optional.
const PANEL_SCRIPTS = ["params.js", "layout.js", "bridge.js", "app.js"];

function bootPanel() {
  const window = createWindow();
  mountIndexSkeleton(window.document);
  const context = vm.createContext(window);
  for (const name of PANEL_SCRIPTS) {
    const file = path.join(UI, name);
    vm.runInContext(fs.readFileSync(file, "utf8"), context, {filename: file});
  }
  window.document.dispatchEvent(new Event("DOMContentLoaded"));
  return window;
}

function layoutInThisRealm(window) {
  return Array.from(window.SYNTH1_LAYOUT);
}

function controlsOf(panel) {
  const groups = panel.groups || [{label: null, controls: panel.controls || []}];
  return Array.from(groups).flatMap(group => Array.from(group.controls));
}

function resolvableSections(window) {
  const indices = new Set(window.SYNTH1_PARAMS.map(p => p.i));
  return layoutInThisRealm(window)
    .map(panel => ({
      title: panel.title,
      controls: controlsOf(panel).filter(spec => indices.has(spec.p)).length,
    }))
    .filter(section => section.controls > 0);
}

function childrenWithClass(element, className) {
  return element.children.filter(child => child.classList.contains(className));
}

function builtControls(section) {
  return childrenWithClass(section, "groups")
    .flatMap(row => childrenWithClass(row, "group"))
    .flatMap(group => childrenWithClass(group, "controls"))
    .flatMap(grid => childrenWithClass(grid, "control"));
}

test("the real panel boots from its scripts and DOMContentLoaded without throwing", () => {
  let window;
  assert.doesNotThrow(() => { window = bootPanel(); });
  assert.equal(typeof window.SynthPatch, "object", "app.js ran and published SynthPatch");
  assert.equal(typeof window.QuesynthIcon, "function");
});

test("with no host injected the bridge runs standalone", () => {
  const window = bootPanel();
  assert.equal(window.SynthBridge.host, "standalone");
  assert.equal(window.SynthBridge.connected, false);
  assert.equal(window.document.querySelector(".brand").title, "Host: standalone");
});

test("the generated parameter table and the hand-written layout are both present", () => {
  const window = bootPanel();
  const params = window.SYNTH1_PARAMS;
  assert.equal(params.length, 99);
  assert.equal(new Set(params.map(p => p.i)).size, 99, "parameter indices are unique");
  assert.ok(window.SYNTH1_LAYOUT.length > 0);
});

test("every layout control names a parameter that params.js defines", () => {
  const window = bootPanel();
  const indices = new Set(window.SYNTH1_PARAMS.map(p => p.i));
  const unresolved = layoutInThisRealm(window).flatMap(panel =>
    controlsOf(panel)
      .filter(spec => !Number.isInteger(spec.p) || !indices.has(spec.p))
      .map(spec => `${panel.title}: ${spec.label || spec.name} (p=${spec.p})`));
  assert.deepEqual(unresolved, [], "layout.js has drifted from the generated params.js");
});

test("#panels gets one section per resolvable layout entry, each with its controls", () => {
  const window = bootPanel();
  const expected = resolvableSections(window);
  const panels = window.document.getElementById("panels");
  const sections = panels.children.filter(el => el.localName === "section" && el.classList.contains("panel"));

  assert.equal(sections.length, expected.length);
  assert.equal(sections.length, window.SYNTH1_LAYOUT.length, "no layout section was dropped");
  assert.deepEqual(
    sections.map(section => ({
      title: section.querySelector("h2").textContent,
      controls: builtControls(section).length,
    })),
    expected);

  const total = sections.reduce((sum, section) => sum + builtControls(section).length, 0);
  const expectedTotal = expected.reduce((sum, section) => sum + section.controls, 0);
  assert.equal(total, expectedTotal);
  assert.ok(total >= 90, `expected most of the 99 parameters on the panel, got ${total}`);
  console.log(`panel smoke: ${sections.length} sections, ${total} controls`);
});

test("the navigator gets one button per built section, titled like the section", () => {
  const window = bootPanel();
  const inner = window.document.querySelector("#navigator .nav-inner");
  const buttons = inner.children.filter(el => el.localName === "button");
  const titles = window.document.getElementById("panels").children
    .map(section => section.querySelector("h2").textContent);

  assert.ok(titles.length > 0);
  assert.equal(buttons.length, titles.length);
  assert.deepEqual(buttons.map(button => button.textContent), titles);
});
