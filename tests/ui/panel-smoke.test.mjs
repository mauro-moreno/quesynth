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

test("knob slider bounds match keyboard endpoints, and wheels expose their signed ranges", () => {
  const window = bootPanel();
  const knobs = window.document.querySelectorAll(".knob");
  assert.ok(knobs.length > 0);
  for (const knob of knobs) {
    assert.equal(knob.getAttribute("aria-valuemin"), "0");
    assert.ok(knob.hasAttribute("aria-valuemax"));
    knob.dispatchEvent(new Event("keydown", {key: "End"}));
    assert.equal(knob.getAttribute("aria-valuenow"), knob.getAttribute("aria-valuemax"));
    knob.dispatchEvent(new Event("keydown", {key: "Home"}));
    assert.equal(knob.getAttribute("aria-valuenow"), "0");
  }
  const wheels = window.document.querySelectorAll(".wheel-track");
  assert.equal(wheels.length, 2);
  for (const [index, id, min] of [[0, "pitch", -1], [1, "mod", 0]]) {
    const wheel = wheels[index];
    assert.equal(wheel.getAttribute("aria-valuemin"), String(min));
    assert.equal(wheel.getAttribute("aria-valuemax"), "1");
    window.SynthWheels.set(id, -2);
    assert.equal(Number(wheel.getAttribute("aria-valuenow")), min);
    window.SynthWheels.set(id, 2);
    assert.equal(Number(wheel.getAttribute("aria-valuenow")), 1);
  }
});

// A stored integer below a parameter's first display selects its first state, as in
// the engine (src/patch/value.odin, `display_state_below`): the reference sounds a
// stored 0 for the oscillator 2 waveform as its first waveform, and the panel has
// to show what will play. Above the range is the last state, and a value in a gap
// of the displays (chorus type 3, between 2 and 4) takes the state below it.
function checkedPosition(window, label) {
  const groups = window.document.querySelectorAll(".radio")
    .filter(group => group.getAttribute("aria-label") === label);
  assert.equal(groups.length, 1, `one "${label}" radio group`);
  const buttons = groups[0].children.filter(el => el.localName === "button");
  return buttons.findIndex(button => button.getAttribute("aria-checked") === "true");
}

test("a stored value below a parameter's first display shows its first state", () => {
  const window = bootPanel();
  const base = window.SynthPatch.values();
  const position = {};
  for (const p of window.SYNTH1_PARAMS) position[p.i] = window.SYNTH1_PARAMS.indexOf(p);
  const apply = (index, stored) => {
    const list = base.slice();
    list[position[index]] = stored;
    window.SynthPatch.apply(list, "edge");
  };
  for (const [stored, want] of [[-1, 0], [0, 0], [1, 0], [2, 1], [3, 2], [4, 3], [5, 3], [9, 3]]) {
    apply(1, stored);
    assert.equal(checkedPosition(window, "Oscillator 2 Waveform"), want, `oscillator 2 waveform, stored ${stored}`);
  }
});

// The LFO types' displays run 0, 1, 5, 2, 3, 4, so a stored value past the range is
// display 5, which is the third state, and not the last one.
test("a stored LFO type past its range shows display 5, the third state", () => {
  const window = bootPanel();
  const base = window.SynthPatch.values();
  const slot = window.SYNTH1_PARAMS.findIndex(p => p.i === 42);
  const labels = Array.from(window.document.querySelectorAll(".radio")).map(g => g.getAttribute("aria-label"));
  const radio = Array.from(window.document.querySelectorAll(".radio")).find(g => /LFO 1.*(Type|Waveform|Shape)/i.test(g.getAttribute("aria-label") || ""));
  assert.ok(radio, `an LFO 1 type radio group among ${labels.join(", ")}`);
  const checked = () => radio.children.filter(el => el.localName === "button")
    .findIndex(button => button.getAttribute("aria-checked") === "true");
  for (const [stored, want] of [[-1, 0], [0, 0], [1, 1], [5, 2], [2, 3], [4, 5], [6, 2], [9, 2], [12, 2]]) {
    const list = base.slice();
    list[slot] = stored;
    window.SynthPatch.apply(list, "edge");
    assert.equal(checked(), want, `LFO 1 type, stored ${stored}`);
  }
});
