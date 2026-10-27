// The panel's idea of what is playing: origin, status, selection, and when it
// may and may not touch the sound.
//
// What these check is the vocabulary of the specification (section 6) as the
// panel exposes it -- `SynthBank.selection()`, `status()`, `readOnly()` -- and
// the invariants that go with it, through the strip a person reads and the
// messages a host receives. None of it looks at how app.js keeps the state.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, bankText, defaults, plain, sound, syncAnswer} from "./support/panel.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const NAMES = Array.from({length: 50}, (_, i) => i === 42 ? "Foo" : `Imported ${i}`);

// Slot 42 of the host's bank holds the sound `sound(10 + 42)`, and the host says
// that is what it is playing: an unedited preset.
const hostPage = (options = {}) => {
  const page = bootPanel({bank: FACTORY, ...options});
  for (const m of syncAnswer({names: NAMES, state: sound(52), slot: 42, name: "Foo"})) page.send(m);
  page.forget();
  return page;
};

// The archive a daemon shares, and the sound it says is playing from it.
const ARCHIVE = {type: "archive", rev: 1, open: true, path: "/srv/banks.zip", banks: ["a.zip", "b.zip"], bank: 1,
  patches: ["Pad", "Bass", "Keys"]};

test("which startup applies: the page that holds the sound loads slot 0, the host's page does not", () => {
  // The browser build: store.js is there, the page is the only authority.
  const browser = bootPanel({bank: FACTORY, host: null, store: true});
  assert.deepEqual(plain(browser.window.SynthBank.selection()),
    {origin: "factory", source: "bank", bank: "Quesynth Factory", slot: 0, presetName: "Strings", archive: null});
  assert.equal(browser.text("bank-patch"), "000:Strings");

  // A wasm engine in the page (the pad): its host claims SynthVolume, holds
  // nothing the page did not send it, and is sent slot 0 as it always was.
  const inPage = bootPanel({bank: FACTORY, before: w => { w.SynthVolume = () => {}; }});
  assert.equal(inPage.window.SynthBridge.inPage, true);
  assert.equal(inPage.ofType("state").length, 1, "the engine in the page is told its sound");
  assert.equal(inPage.window.SynthBank.selection().slot, 0);

  // A plugin: the host has the sound.
  const plugin = bootPanel({bank: FACTORY});
  assert.equal(plugin.window.SynthBridge.inPage, false);
  assert.equal(plugin.ofType("state").length, 0);
  assert.equal(plugin.window.SynthBank.selection().origin, "session");
  assert.equal(plugin.text("bank-patch"), "Untitled", "nothing is loaded until the host says what is");
});

test("a webview host is a plugin too", () => {
  const page = bootPanel({bank: FACTORY, host: "webview2"});
  assert.equal(page.window.SynthBridge.host, "webview2");
  assert.equal(page.ofType("state").length, 0);
  page.send({type: "state", values: sound(99), v: 1});
  assert.deepEqual(page.values(), sound(99));
});

test("a slot is only ever a factory, user or imported preset's, and a file or the session has none", () => {
  const page = hostPage();
  const sel = () => plain(page.window.SynthBank.selection());

  assert.equal(sel().slot, 42);
  assert.equal(sel().origin, "imported");

  // The host says the sound has no slot behind it: a slot in the message is
  // not enough to give one to an origin that cannot have it.
  page.send({type: "patch", name: "Loose", index: 7, bank: "x", v: 1, origin: "session"});
  assert.deepEqual(sel(), {origin: "session", source: "none", bank: "x", slot: null, presetName: "Loose", archive: null});
  page.send({type: "patch", name: "A file", index: 7, bank: "", v: 1, origin: "file"});
  assert.equal(sel().slot, null);
  assert.equal(sel().source, "file");

  // A patch file the person opens is a file, with no slot.
  page.window.SynthPatch.apply(sound(5), "From a file");
  assert.deepEqual(sel(), {origin: "file", source: "file", bank: "", slot: null, presetName: "From a file", archive: null});

  // A slot in a bank is a slot again.
  page.window.SynthBank.load(3);
  assert.equal(sel().slot, 3);
  assert.equal(sel().origin, "imported");
});

test("an archive preset has no slot and carries its two indexes", () => {
  const page = hostPage();
  page.send(ARCHIVE);
  page.send({type: "patch", name: "Bass", index: null, bank: "b.zip", source: "archive", archive: {bank: 1, patch: 1}});
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "archive", source: "archive", bank: "b.zip", slot: null, presetName: "Bass", archive: {bank: 1, patch: 1}});
  assert.equal(page.text("bank-patch"), "001:Bass", "the archive patch's own index leads the name");
  assert.equal(page.window.SynthBank.readOnly(), true, "an archive is read-only whatever else is true");
  assert.equal(page.window.SynthBank.index(), -1, "an archive patch is not an ordinary slot");
});

test("origins: factory is the compiled-in bank, a bank somebody opens is imported, the host says its own", () => {
  const page = hostPage();
  const rows = plain(page.window.SynthBank.list());
  assert.deepEqual(rows.map(r => [r.label, r.origin]), [["Quesynth Factory", "factory"], ["Alfmeister Bank", "imported"]]);
  assert.equal(page.window.SynthBank.origin(1), "imported");
  assert.equal(page.window.SynthBank.origin(7), null);
  assert.equal(page.window.SynthBank.originLabel("session"), "Current session");
  assert.equal(page.window.SynthBank.bankInfo(0).kind, "bank");
});

test("the strip keeps its two original elements as they were and says the rest in new ones", () => {
  const page = hostPage();
  assert.equal(page.text("bank-patch"), "042:Foo", "exactly NNN:Name");
  assert.equal(page.text("bank-name"), "Alfmeister Bank", "exactly the bank's label");
  assert.equal(page.text("bank-origin"), "Imported");
  assert.equal(page.$("bank-origin").getAttribute("data-origin"), "imported");
  assert.ok(page.$("bank-dirty").hasAttribute("hidden"));

  page.window.SynthPatch.setParam(19, 0.2);
  assert.ok(!page.$("bank-dirty").hasAttribute("hidden"), "an edit shows the marker");
  assert.equal(page.$("bank-dirty").textContent, "*");
  assert.equal(page.$("bank-dirty").getAttribute("aria-label"), "Unsaved changes");
  assert.equal(page.text("bank-patch"), "042:Foo", "and never inside the name");
  assert.equal(page.$("bank").getAttribute("data-status"), "dirty");
});

test("status is one value: loading, then unavailable, then dirty, then read-only, then clean", () => {
  // Read-only and clean: the factory bank in a page with nothing to keep it.
  const factory = bootPanel({bank: FACTORY, host: null});
  assert.equal(factory.window.SynthBank.status(), "readonly");
  assert.equal(factory.window.SynthBank.readOnly(), true);
  // Dirty beats it, and read-only is still said on its own.
  factory.window.SynthPatch.setParam(19, 0.2);
  assert.equal(factory.window.SynthBank.status(), "dirty");
  assert.equal(factory.window.SynthBank.readOnly(), true);
  factory.window.SynthBank.load(1);
  assert.equal(factory.window.SynthBank.status(), "readonly");

  const page = hostPage();
  assert.equal(page.window.SynthBank.status(), "clean");
  page.window.SynthPatch.setParam(19, 0.2);
  assert.equal(page.window.SynthBank.status(), "dirty");
  // Put back as it was: clean again, with no save in between.
  page.send({type: "param", index: 19, value: sound(10 + 42)[19]});
  assert.equal(page.window.SynthBank.status(), "clean");

  // A load in flight beats everything.
  page.send(ARCHIVE);
  page.window.SynthBank.select(2, false);
  page.forget();
  page.window.SynthBank.loadBrowsed(1);
  assert.equal(page.window.SynthBank.status(), "loading");
  assert.deepEqual(plain(page.sent), [{type: "archive-load", bank: 1, index: 1}]);
  assert.equal(page.window.SynthBank.selection().origin, "imported", "the selection moves when the host answers");
  page.send({type: "patch", name: "Bass", index: null, bank: "b.zip", source: "archive", archive: {bank: 1, patch: 1}});
  assert.equal(page.window.SynthBank.status(), "readonly", "answered: archive, so read-only");
  assert.equal(page.window.SynthBank.selection().origin, "archive");
});

test("dirty means the sound differs from the slot, and says nothing about the host's project", () => {
  const page = hostPage();
  page.window.SynthPatch.setParam(19, 0.2);
  assert.equal(page.window.SynthBank.status(), "dirty");
  assert.deepEqual(page.ofType("save"), []);
  // The only thing a knob sends is the knob.
  assert.deepEqual(page.sent.map(m => m.type).filter(t => t !== "set" && t !== "edit"), []);
  assert.ok(!/project|saved/i.test(page.$("bank-dirty").getAttribute("aria-label").replace("Unsaved changes", "")));
});

test("a sound with no slot is dirty against what it was loaded with, and a whole host sound resets that", () => {
  const page = hostPage();
  page.send({type: "patch", name: "Untitled", index: null, bank: "", v: 1});
  assert.equal(page.window.SynthBank.selection().origin, "session");
  assert.equal(page.window.SynthBank.status(), "clean", "the sound the host just sent is what it is");
  page.window.SynthPatch.setParam(19, 0.2);
  assert.equal(page.window.SynthBank.status(), "dirty");
  page.send({type: "state", values: sound(7)});
  assert.equal(page.window.SynthBank.status(), "clean", "a new whole sound from the host is a new starting point");
});

test("a host patch that names no sound keeps the panel's own sound and name, as the current session", () => {
  const page = hostPage();
  page.window.SynthPatch.apply(sound(5), "Mine");
  page.forget();
  page.send({type: "patch", index: null, v: 1});
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "session", source: "none", bank: "", slot: null, presetName: "Mine", archive: null});
  assert.deepEqual(page.values(), sound(5));
});

test("choosing a destination in write mode never loads it, and the selection stays where it was", () => {
  const page = hostPage();
  page.window.SynthBank.select(0, true);
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory", "the browser is looking at the factory bank");
  assert.deepEqual(plain(page.sent), [], "nothing is sent: not a state, not a bank, not a selection");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "imported", source: "bank", bank: "Alfmeister Bank", slot: 42, presetName: "Foo", archive: null});
  assert.equal(page.window.SynthBank.index(), -1, "a browser looking elsewhere marks nothing as playing");
  assert.equal(page.text("bank-patch"), "042:Foo");
});

test("interior empty slots stay addressable: an empty slot loads as Init at its own number", () => {
  const page = bootPanel({bank: {label: "Gappy", patches: [{n: "A", v: sound(1)}, null, {n: "C", v: sound(3)}]}, host: null});
  assert.deepEqual(plain(page.window.SynthBank.slots().slice(0, 4)), [{name: "A"}, null, {name: "C"}, null]);
  page.window.SynthBank.load(1);
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "factory", source: "bank", bank: "Gappy", slot: 1, presetName: "Init", archive: null});
  assert.deepEqual(page.values(), defaults());
  assert.equal(page.text("bank-patch"), "001:Init");
  assert.equal(page.window.SynthBank.status(), "readonly", "an empty slot in a read-only bank");
});

test("NEXT and PREV step from the selection, and from the ends when there is none", () => {
  const page = bootPanel({bank: FACTORY});
  const click = step => page.document.querySelector(`.bank-step[data-step="${step}"]`).click();
  click(1);
  assert.equal(page.text("bank-patch"), "000:Strings", "nothing loaded yet: the first press goes to slot 0");
  click(1);
  assert.equal(page.text("bank-patch"), "001:Brass");
  click(-1); click(-1);
  assert.equal(page.text("bank-patch"), "127:Init", "and wraps");

  const fresh = bootPanel({bank: FACTORY});
  fresh.document.querySelector('.bank-step[data-step="-1"]').click();
  assert.equal(fresh.text("bank-patch"), "127:Init", "PREV from nothing goes to the last slot, not one before it");
});

test("a host that says v:1 is sent the selection after the sound, and the bank before it", () => {
  const page = hostPage();
  page.forget();
  // A bank the host does not hold: it has to be given first.
  page.window.SynthBank.load(5);
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["state", "select"],
    "the host's own bank is the one in view: nothing to publish");
  assert.deepEqual(plain(page.sent[1]),
    {type: "select", v: 1, origin: "imported", bank: "Alfmeister Bank", slot: 5, name: "Imported 5"});
});

test("an older host is sent no version-1 message, whatever the page does", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "bank", text: bankText("My Bank", NAMES)});
  page.send({type: "state", values: sound(99)});
  page.send({type: "patch", name: "Imported 9", index: 9, bank: "My Bank"});
  page.forget();
  page.window.SynthBank.load(1);
  page.window.SynthPatch.apply(sound(3), "A file");
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["state", "state"]);
  assert.equal(page.window.SynthBridge.version(), 0);
});

test("the strip says where a legacy host's selection comes from without being told an origin", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "bank", text: bankText("My Bank", NAMES)});
  page.send({type: "patch", name: "Imported 9", index: 9, bank: "My Bank", source: "bank", archive: null});
  assert.equal(page.window.SynthBank.selection().origin, "user", "the daemon's ordinary bank is the user's");
  assert.equal(page.window.SynthBank.selection().slot, 9);
  assert.equal(page.$("bank").getAttribute("data-source"), "bank");
  page.send({type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
  assert.equal(page.$("bank").getAttribute("data-source"), "none");
  assert.equal(page.text("bank-patch"), "Untitled");
});
