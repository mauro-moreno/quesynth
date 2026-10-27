// The dialog shell and the two questions asked through it: "are you sure?" and
// "this did not work". What matters about both is that the safe answer is the
// easy one, that the keyboard cannot leave them, and that whoever opened them
// gets focus back.

import test from "node:test";
import assert from "node:assert/strict";
import {Event} from "./support/dom.mjs";
import {PANEL, bootPanel} from "./support/panel.mjs";

const page = () => bootPanel({host: null, scripts: PANEL.filter(name => name !== "browser.js")});
const dialogs = p => p.document.querySelectorAll(".modal");
const buttons = root => root.querySelectorAll("button");
const label = el => el.textContent.trim();
const key = (p, k, init = {}) => {
  const e = new Event("keydown", {key: k, ...init});
  p.document.dispatchEvent(e);
  return e;
};
const settled = promise => {
  const state = {done: false};
  promise.then(value => { state.done = true; state.value = value; });
  return state;
};
// Promise callbacks run after the current task; give them one.
const tick = () => new Promise(resolve => setImmediate(resolve));

test("a confirmation names what is about to happen and resolves true only for the confirm button", async () => {
  const p = page();
  const answer = settled(p.window.SynthModal.confirm({
    title: "Overwrite slot 042?", message: ["Alfmeister Bank / 042 already holds Foo.", "Replace it?"],
    confirmLabel: "Overwrite",
  }));
  const [dialog] = dialogs(p);
  assert.equal(dialog.getAttribute("role"), "alertdialog");
  assert.equal(dialog.getAttribute("aria-modal"), "true");
  assert.equal(dialog.getAttribute("aria-label"), "Overwrite slot 042?");
  const described = p.document.getElementById(dialog.getAttribute("aria-describedby"));
  assert.equal(described.querySelectorAll("p").length, 2, "each line of the message is its own paragraph");
  assert.deepEqual(buttons(dialog).map(label), ["CLOSE", "Cancel", "Overwrite"]);

  buttons(dialog)[2].click();
  await tick();
  assert.deepEqual(answer, {done: true, value: true});
  assert.equal(dialogs(p).length, 0);
});

test("every way of dismissing a confirmation is a no", async () => {
  for (const dismiss of [
    p => key(p, "Escape"),
    p => buttons(dialogs(p)[0])[1].click(),
    p => buttons(dialogs(p)[0])[0].click(),
    p => p.document.querySelector(".modal-back").dispatchEvent(Object.assign(new Event("click"), {target: p.document.querySelector(".modal-back")})),
  ]) {
    const p = page();
    const answer = settled(p.window.SynthModal.confirm({title: "Sure?", message: "x"}));
    dismiss(p);
    await tick();
    assert.deepEqual(answer, {done: true, value: false});
    assert.equal(dialogs(p).length, 0);
  }
});

test("focus starts on Cancel, so that Enter on an unread question is not an overwrite", async () => {
  const p = page();
  p.window.SynthModal.confirm({title: "Sure?", message: "x", confirmLabel: "Overwrite"});
  assert.equal(label(p.document.activeElement), "Cancel");
  p.window.SynthModal.close();
  p.window.SynthModal.confirm({title: "Sure?", message: "x", confirmLabel: "Overwrite", focus: "confirm"});
  assert.equal(label(p.document.activeElement), "Overwrite");
});

test("Tab and Shift+Tab stay inside the dialog", () => {
  const p = page();
  p.window.SynthModal.confirm({title: "Sure?", message: "x"});
  const [close, cancel, ok] = buttons(dialogs(p)[0]);
  ok.focus();
  assert.equal(key(p, "Tab").defaultPrevented, true);
  assert.equal(p.document.activeElement, close, "forward from the last goes to the first");
  assert.equal(key(p, "Tab", {shiftKey: true}).defaultPrevented, true);
  assert.equal(p.document.activeElement, ok, "and back from the first goes to the last");
  cancel.focus();
  assert.equal(key(p, "Tab").defaultPrevented, false, "in between, the browser moves focus as usual");
  // Focus that has somehow escaped is pulled back in.
  p.document.body.focus();
  assert.equal(key(p, "Tab").defaultPrevented, true);
  assert.equal(p.document.activeElement, close);
});

test("focus returns to whatever opened the dialog, however it closes", async () => {
  const p = page();
  const opener = p.$("preset-save");
  for (const close of [p => key(p, "Escape"), p => buttons(dialogs(p)[0])[1].click(), p => buttons(dialogs(p)[0])[2].click()]) {
    opener.focus();
    p.window.SynthModal.confirm({title: "Sure?", message: "x"});
    assert.notEqual(p.document.activeElement, opener);
    close(p);
    await tick();
    assert.equal(p.document.activeElement, opener);
  }
});

test("an error dialog waits to be read, and resolves when it is closed", async () => {
  const p = page();
  const opener = p.$("preset-menu");
  opener.focus();
  const done = settled(p.window.SynthModal.alert({title: "Could not save", message: "The disk is full."}));
  const [dialog] = dialogs(p);
  assert.equal(dialog.getAttribute("role"), "alertdialog");
  assert.equal(label(p.document.activeElement), "OK");
  assert.equal(p.document.getElementById(dialog.getAttribute("aria-describedby")).textContent, "The disk is full.");
  key(p, "Escape");
  await tick();
  assert.equal(done.done, true);
  assert.equal(p.document.activeElement, opener);
});

test("a question over the browser stacks on it: only the front one hears the keyboard, and the one under survives", async () => {
  const p = page();
  const body = p.document.createElement("div");
  const search = p.document.createElement("input");
  body.appendChild(search);
  p.window.SynthModal.show("Patches", body, [{label: "Done", onClick: close => close()}]);
  search.focus();

  const answer = settled(p.window.SynthModal.confirm({title: "Overwrite?", message: "x"}));
  assert.equal(dialogs(p).length, 2);
  assert.equal(p.window.SynthModal.isOpen(), true);

  // The browser is behind the question: Tab cannot reach it.
  const [, cancel, ok] = buttons(dialogs(p)[1]);
  ok.focus();
  key(p, "Tab");
  assert.ok(dialogs(p)[1].contains(p.document.activeElement));

  key(p, "Escape");
  await tick();
  assert.deepEqual(answer, {done: true, value: false});
  assert.equal(dialogs(p).length, 1, "Escape answered the question and only the question");
  assert.equal(p.document.activeElement, search, "and focus is back in the browser, on the field it had");
  assert.ok(p.document.body.classList.contains("modal-open"), "the page behind is still locked");

  key(p, "Escape");
  assert.equal(dialogs(p).length, 0);
  assert.ok(!p.document.body.classList.contains("modal-open"));
  void cancel;
});

test("opening an ordinary dialog still replaces whatever is open, as it always did", () => {
  const p = page();
  p.window.SynthModal.show("One", p.document.createElement("div"), []);
  p.window.SynthModal.show("Two", p.document.createElement("div"), []);
  assert.deepEqual(dialogs(p).map(d => d.getAttribute("aria-label")), ["Two"]);
});

test("a dialog's own onClose runs once, after it is gone", () => {
  const p = page();
  const seen = [];
  p.window.SynthModal.show("One", p.document.createElement("div"), [], {onClose: () => seen.push(dialogs(p).length)});
  p.window.SynthModal.close();
  p.window.SynthModal.close();
  assert.deepEqual(seen, [0]);
});
