import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import {LAYOUT_SOURCE, LAYOUT_TABLE, generate, readLayout} from "../../tools/tuilayout.mjs";

// The TUI's tabs and headings come from hosts/standalone/tui/layout.odin,
// which tools/tuilayout.mjs writes from ui/layout.js. These hold the checked-in
// table to the panel's layout as the page itself evaluates it.

const table = fs.readFileSync(LAYOUT_TABLE, "utf8");

// The table read back: each section line, then one line per group.
function readTable(text) {
  const sections = [];
  for (const line of text.split("\n")) {
    const section = /^\t\{("(?:[^"\\]|\\.)*"), \{$/.exec(line);
    if (section) {
      sections.push({title: JSON.parse(section[1]), groups: []});
      continue;
    }
    const group = /^\t\t\{("(?:[^"\\]|\\.)*"), \{([\d, ]*)\}\},$/.exec(line);
    if (group) {
      sections.at(-1).groups.push({
        label: JSON.parse(group[1]),
        params: group[2] ? group[2].split(", ").map(Number) : [],
      });
    }
  }
  return sections;
}

test("the TUI's layout table is regenerated from ui/layout.js", () => {
  assert.equal(table, generate(), "run `node tools/tuilayout.mjs`");
});

test("the table has every panel section, group and control, in the panel's order", () => {
  const panel = readLayout();
  assert.ok(panel.length > 0);
  assert.deepEqual(readTable(table), panel);
  const controls = panel.flatMap(section => section.groups.flatMap(group => group.params));
  assert.equal(new Set(controls).size, controls.length, "a control is placed twice");
});

// The rows' labels: one line per control after `PANEL_LABELS`, held to the
// label each control of the page prints, read from the page's own layout.
test("the table names every control as the panel prints it", () => {
  const lines = table.slice(table.indexOf("PANEL_LABELS")).split("\n");
  const labels = new Map();
  for (const line of lines) {
    const entry = /^\t\{(\d+), ("(?:[^"\\]|\\.)*")\},$/.exec(line);
    if (entry) labels.set(Number(entry[1]), JSON.parse(entry[2]));
  }
  const context = vm.createContext({window: {}});
  vm.runInContext(fs.readFileSync(LAYOUT_SOURCE, "utf8"), context);
  const controls = Array.from(context.window.SYNTH1_LAYOUT).flatMap(panel =>
    Array.from(panel.groups || [{controls: panel.controls}]).flatMap(group => Array.from(group.controls)));
  assert.equal(labels.size, controls.length);
  for (const control of controls) assert.equal(labels.get(control.p), control.label, `parameter ${control.p}`);
  assert.equal(labels.get(0), "Waveform");
  assert.equal(labels.get(29), "Gain");
});
