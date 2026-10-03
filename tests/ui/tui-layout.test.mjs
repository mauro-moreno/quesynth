import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {LAYOUT_TABLE, generate, readLayout} from "../../tools/tuilayout.mjs";

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
