// The preset strip is written three times: in ui/index.html, in ui/pad.html, and
// by hand in the stand-in DOM that boots the panel under test. They have to be
// the same strip. A button that exists in one shell and not the other leaves the
// second one quietly lacking it, and a skeleton that has drifted makes every
// other test a test of something the page does not have.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {UI} from "./support/panel.mjs";
import {createWindow, mountIndexSkeleton} from "./support/dom.mjs";

const VOID = new Set(["input", "br", "img", "link", "meta", "hr"]);

// Enough HTML for the markup under test: tags, quoted or bare attributes,
// comments, text. Whitespace between elements is layout and is dropped; inside
// text it is collapsed, as a browser renders it.
function parse(html) {
  const root = {tag: "#root", attrs: {}, kids: []};
  const stack = [root];
  const token = /<!--[\s\S]*?-->|<\/([a-zA-Z0-9]+)\s*>|<([a-zA-Z0-9]+)((?:\s+[^\s>=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*\/?>|([^<]+)/g;
  for (let m; (m = token.exec(html));) {
    if (m[0].startsWith("<!--")) continue;
    if (m[1]) { stack.pop(); continue; }
    if (m[2]) {
      const attrs = {};
      for (const a of m[3].matchAll(/([^\s>=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
        attrs[a[1]] = a[2] ?? a[3] ?? a[4] ?? "";
      }
      const el = {tag: m[2].toLowerCase(), attrs, kids: []};
      stack[stack.length - 1].kids.push(el);
      if (!VOID.has(el.tag)) stack.push(el);
      continue;
    }
    const text = m[4].replace(/\s+/g, " ");
    if (text.trim() !== "") stack[stack.length - 1].kids.push(stack.length ? text : text);
  }
  return root;
}

// A tree of one element, from either source, in one shape.
function shape(el) {
  const kids = [];
  for (const kid of el.kids) {
    if (typeof kid === "string") {
      const last = kids.length - 1;
      if (typeof kids[last] === "string") kids[last] += kid; else kids.push(kid);
    } else kids.push(shape(kid));
  }
  return {tag: el.tag, attrs: el.attrs, kids: kids.map(k => typeof k === "string" ? k.replace(/\s+/g, " ") : k)};
}

function fromDom(el) {
  const attrs = {};
  for (const [name, value] of el.attributes) attrs[name] = value;
  const kids = el.childNodes.map(n => n.nodeType === 3 ? n.data : fromDom(n));
  return {tag: el.localName, attrs, kids};
}

function trim(node) {
  if (typeof node === "string") return node;
  const kids = node.kids.map(trim).filter(k => typeof k !== "string" || k.trim() !== "");
  return {...node, kids};
}

function strip(file) {
  const html = fs.readFileSync(path.join(UI, file), "utf8");
  const found = [];
  (function walk(n) {
    if (typeof n === "string") return;
    if (n.attrs && n.attrs.id === "bank") found.push(n);
    n.kids.forEach(walk);
  })(parse(html));
  assert.equal(found.length, 1, `${file} has one #bank`);
  return shape(trim(found[0]));
}

test("the strip is the same in both shells", () => {
  assert.deepEqual(strip("pad.html"), strip("index.html"));
});

test("the stand-in DOM builds the strip index.html has, attribute for attribute", () => {
  const window = createWindow();
  mountIndexSkeleton(window.document);
  const built = fromDom(window.document.getElementById("bank"));
  // Text nodes of the shim are exactly the strings written; the real page's are
  // collapsed, so compare after the same collapse.
  assert.deepEqual(shape(trim(built)), strip("index.html"));
});

test("the specification's words are in both shells' markup, whole", () => {
  for (const file of ["index.html", "pad.html"]) {
    const html = fs.readFileSync(path.join(UI, file), "utf8").replace(/\s+/g, " ");
    for (const words of [
      'Could not restore <code class="restore-id" id="restore-failed-id"></code>. The current sound was kept.',
      "The saved bank is unavailable. Load Factory / Init instead?",
      ">Retry<", ">Choose bank<", ">Load Factory / Init<", ">Keep current sound<",
      'id="restore-banner" role="alert"',
      'id="bank-status" role="status"',
    ]) {
      assert.ok(html.includes(words), `${file}: ${words}`);
    }
  }
});

test("every control in the strip has an accessible name that contains what is printed on it", () => {
  const found = [];
  (function walk(n) {
    if (typeof n === "string") return;
    if (n.tag === "button") found.push(n);
    n.kids.forEach(walk);
  })(strip("index.html"));
  assert.ok(found.length >= 14, "the strip's buttons were found");
  for (const button of found) {
    const printed = button.kids.filter(k => typeof k === "string").join("").trim();
    const name = button.attrs["aria-label"] || printed;
    assert.notEqual(name, "", "a button with no name");
    if (button.attrs["aria-label"] && printed) {
      assert.ok(button.attrs["aria-label"].toLowerCase().includes(printed.toLowerCase().replace(/\.\.\.$/, "")),
        `"${button.attrs["aria-label"]}" does not contain its visible text "${printed}"`);
    }
  }
});
