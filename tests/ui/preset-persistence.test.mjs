// Writing a sound into a bank, copying and moving between slots, Save and Save
// As, and what is said about all of it.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 5.3): the live sound is
// written to exactly the slot asked for, or the write is refused and nothing
// changes. A refusal is visible and has one of five names. A write is never an
// accident of looking: the only doors are Save, Save As, Write, and a copy or
// move somebody confirmed.

import test from "node:test";
import assert from "node:assert/strict";
import {PANEL, PARAM_NAMES, bootPanel, compiledBank, bankText, plain, sound, syncAnswer} from "./support/panel.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const MINE = ["Alpha", "Bravo", null, "Delta", null, "Foxtrot"];

// A plugin whose host keeps `My Bank` for this instrument and says it is
// playing slot `slot` of it, unedited.
function plugin({slot = 0, names = MINE, label = "My Bank", origin = "user", readOnly = false} = {}) {
  const page = bootPanel({bank: FACTORY});
  const base = 10;
  const state = slot === null ? sound(99) : sound(base + slot);
  for (const m of syncAnswer({label, names, origin, readOnly, state, slot: slot === null ? undefined : slot,
    name: slot === null ? undefined : names[slot] ?? "Init"})) page.send(m);
  page.forget();
  return page;
}

const bankIndex = (page, label) => plain(page.window.SynthBank.list()).findIndex(b => b.label === label);
const words = page => page.text("bank-status");
const storedAt = (page, index, slot) => {
  const was = page.window.SynthBank.current();
  page.window.SynthBank.select(index, true);
  const name = plain(page.window.SynthBank.slots())[slot];
  if (was !== index) page.window.SynthBank.select(was, true);
  return name;
};
const errorCode = result => result.ok ? "ok" : result.error.code;

// ----------------------------------------------------------------- writePreset

test("writePreset writes the live sound to exactly the slot asked for, and says so", () => {
  const page = plugin({slot: 0});
  page.window.SynthPatch.setParam(19, 0.5);
  const live = page.values();
  const at = bankIndex(page, "My Bank");
  const result = plain(page.window.SynthBank.writePreset({bank: at, slot: 2, name: "Charlie"}));

  assert.equal(result.ok, true);
  assert.deepEqual([result.action, result.bank, result.slot, result.name], ["write", "My Bank", 2, "Charlie"]);
  assert.equal(storedAt(page, at, 2).name, "Charlie");
  assert.equal(storedAt(page, at, 1).name, "Bravo", "and nothing else");
  assert.equal(words(page), "Saved Charlie to My Bank / 002.");
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "ok");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "user", source: "bank", bank: "My Bank", slot: 2, presetName: "Charlie", archive: null});
  assert.equal(page.text("bank-patch"), "002:Charlie");
  assert.deepEqual(page.values(), live, "writing does not change the sound");
  assert.equal(page.window.SynthBank.status(), "clean", "and what was edited is now what the slot holds");
  assert.ok(page.$("bank-dirty").hasAttribute("hidden"));
});

test("a write onto a sound needs overwrite: true, and without it nothing changes at all", () => {
  const page = plugin({slot: 1});
  page.window.SynthPatch.setParam(19, 0.5);
  const at = bankIndex(page, "My Bank");
  const selection = plain(page.window.SynthBank.selection());
  const values = page.values();
  page.forget();

  for (const overwrite of [undefined, false, "yes", 1]) {
    const refused = page.window.SynthBank.writePreset({bank: at, slot: 0, name: "Zulu", overwrite});
    assert.equal(errorCode(refused), "OverwriteDenied", `overwrite: ${String(overwrite)}`);
  }
  assert.equal(storedAt(page, at, 0).name, "Alpha");
  assert.deepEqual(page.sent, [], "nothing was sent to the host");
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
  assert.deepEqual(page.values(), values);
  assert.equal(page.window.SynthBank.status(), "dirty", "the edit is still unsaved");
  assert.match(words(page), /already holds Alpha/);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "error");

  assert.equal(page.window.SynthBank.writePreset({bank: at, slot: 0, name: "Zulu", overwrite: true}).ok, true);
  assert.equal(storedAt(page, at, 0).name, "Zulu");
});

test("an empty slot needs no overwrite", () => {
  const page = plugin();
  assert.equal(page.window.SynthBank.writePreset({bank: bankIndex(page, "My Bank"), slot: 4, name: "Echo"}).ok, true);
});

test("InvalidSlot: not an integer in 0..127, or not a bank that is open", () => {
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  for (const slot of [-1, 128, 1.5, NaN, Infinity, "3", null, undefined, {}]) {
    assert.equal(errorCode(page.window.SynthBank.writePreset({bank: at, slot, name: "x", overwrite: true})), "InvalidSlot",
      `slot ${String(slot)}`);
  }
  for (const bank of [-1, 99, 1.5, "No Such Bank", null, undefined, {}]) {
    assert.equal(errorCode(page.window.SynthBank.writePreset({bank, slot: 3, name: "x", overwrite: true})), "InvalidSlot",
      `bank ${String(bank)}`);
  }
  assert.equal(errorCode(page.window.SynthBank.writePreset()), "InvalidSlot");
  assert.equal(errorCode(page.window.SynthBank.writePreset({bank: at, slot: 127, name: "Last"})), "ok", "127 is a slot");
  assert.equal(errorCode(page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "ByName", overwrite: true})), "ok",
    "a bank may be named by its label");
});

test("ReadOnlyBank: the factory bank where nothing keeps it, an archive, and a bank not yet opened", () => {
  const bare = bootPanel({bank: FACTORY, host: null});
  const before = plain(bare.window.SynthBank.slots());
  const refused = bare.window.SynthBank.writePreset({bank: 0, slot: 5, name: "Mine"});
  assert.equal(errorCode(refused), "ReadOnlyBank");
  assert.deepEqual(plain(bare.window.SynthBank.slots()), before);
  assert.match(bare.text("bank-status"), /Quesynth Factory is read-only/);

  // The same factory bank, where the browser build's store keeps it, is writable.
  const browser = bootPanel({bank: FACTORY, host: null, store: true});
  assert.equal(errorCode(browser.window.SynthBank.writePreset({bank: 0, slot: 5, name: "Mine"})), "ok");

  // A host's bank that the host says is read-only is.
  const locked = plugin({readOnly: true});
  assert.equal(errorCode(locked.window.SynthBank.writePreset({bank: bankIndex(locked, "My Bank"), slot: 4, name: "x"})), "ReadOnlyBank");

  // An archive bank, however it is named.
  const daemon = plugin();
  daemon.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 0, patches: ["Pad"]});
  assert.equal(errorCode(daemon.window.SynthBank.writePreset({bank: 1, slot: 0, name: "x", overwrite: true})), "ReadOnlyBank");

  // A bank that is listed but has not been read has no slots to write to yet.
  const lazy = plugin();
  lazy.window.SynthBank.addLazy("Unopened", () => Promise.reject(new Error("must not be read")));
  assert.equal(errorCode(lazy.window.SynthBank.writePreset({bank: "Unopened", slot: 0, name: "x"})), "ReadOnlyBank");
  assert.match(lazy.text("bank-status"), /Open Unopened/);
});

test("InvalidName: empty, only spaces, a control character, or over 48 UTF-8 bytes", () => {
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  const write = name => errorCode(page.window.SynthBank.writePreset({bank: at, slot: 4, name, overwrite: true}));
  for (const bad of ["", "   ", "\t", "a\nb", "tab\there", "nul\u0000", "del\u007f", "next\u0085line", 42, null, {}]) {
    assert.equal(write(bad), "InvalidName", JSON.stringify(bad));
  }
  assert.equal(storedAt(page, at, 4), null, "no refused write left anything behind");

  assert.equal(write("a".repeat(48)), "ok", "48 bytes is the most a slot keeps");
  assert.equal(write("a".repeat(49)), "InvalidName");
  assert.equal(write("é".repeat(24)), "ok", "24 two-byte letters are 48 bytes");
  assert.equal(write("é".repeat(25)), "InvalidName", "and 25 are 50");
  assert.equal(write("😀".repeat(12)), "ok", "an emoji is four bytes");
  assert.equal(write("😀".repeat(13)), "InvalidName");
  assert.match(plain(page.window.SynthBank.lastResult()).error.message, /52 bytes; the most a slot keeps is 48/);
  assert.equal(write("  padded  "), "ok");
  assert.equal(storedAt(page, at, 4).name, "padded", "spaces round a name are not part of it");
});

test("a write with no name uses the sound's own", () => {
  const page = plugin({slot: 1});
  const result = page.window.SynthBank.writePreset({bank: bankIndex(page, "My Bank"), slot: 4});
  assert.equal(result.name, "Bravo");
});

test("a refusal names its cause first: a bad slot before a read-only bank before a bad name before an overwrite", () => {
  const bare = bootPanel({bank: FACTORY, host: null});
  assert.equal(errorCode(bare.window.SynthBank.writePreset({bank: 0, slot: 999, name: ""})), "InvalidSlot");
  assert.equal(errorCode(bare.window.SynthBank.writePreset({bank: 0, slot: 1, name: ""})), "ReadOnlyBank");
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  assert.equal(errorCode(page.window.SynthBank.writePreset({bank: at, slot: 0, name: ""})), "InvalidName");
  assert.equal(errorCode(page.window.SynthBank.writePreset({bank: at, slot: 0, name: "ok"})), "OverwriteDenied");
});

test("every outcome is reported to whoever asked to hear, and the last is kept for whoever missed it", () => {
  const page = plugin();
  const heard = [];
  const stop = page.window.SynthBank.onResult(r => heard.push([r.ok, r.action]));
  const at = bankIndex(page, "My Bank");
  page.window.SynthBank.writePreset({bank: at, slot: 4, name: "Echo"});
  page.window.SynthBank.writePreset({bank: at, slot: 4, name: "Echo"});
  stop();
  page.window.SynthBank.writePreset({bank: at, slot: 4, name: "Echo", overwrite: true});
  assert.deepEqual(heard, [[true, "write"], [false, "write"]]);
  assert.equal(page.window.SynthBank.lastResult().ok, true);
});

// ------------------------------------------------- what the host is told

test("a write into the bank the host keeps is sent to it, to be saved, before the selection", () => {
  const page = plugin({slot: 0});
  page.window.SynthBank.writePreset({bank: bankIndex(page, "My Bank"), slot: 4, name: "Echo"});
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["bank", "select"], "no state: the sound did not change");
  const bank = page.sent[0];
  assert.deepEqual([bank.save, bank.v, bank.origin], [true, 1, "user"]);
  assert.deepEqual(JSON.parse(bank.text).patches.map(p => p && p.name), ["Alpha", "Bravo", null, "Delta", "Echo", "Foxtrot"]);
  assert.deepEqual(plain(page.sent[1]), {type: "select", v: 1, origin: "user", bank: "My Bank", slot: 4, name: "Echo"});
});

test("a write into a bank somebody opened is sent to be played, never to be saved over the host's", () => {
  const page = plugin({slot: 0});
  const added = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}, null]);
  page.forget();
  page.window.SynthBank.writePreset({bank: added.index, slot: 1, name: "Mine"});
  const bank = page.sent.find(m => m.type === "bank");
  assert.deepEqual([bank.save, bank.origin], [false, "imported"]);
  assert.equal(page.window.SynthBank.selection().bank, "Third Party");
});

test("saving a bank the host does not play makes it play again what the panel is playing", () => {
  const page = plugin({slot: 0});
  const added = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}]);
  page.window.SynthBank.loadPreset({bank: added.index, slot: 0});
  page.forget();
  page.window.SynthBank.copySlot({bank: added.index, slot: 0}, {bank: "My Bank", slot: 4});
  assert.deepEqual(plain(page.sent.map(m => [m.type, m.type === "bank" ? JSON.parse(m.text).name : "", m.save])),
    [["bank", "My Bank", true], ["bank", "Third Party", false]],
    "the host's bank is saved, then the one being played is put back in the host's hands");
});

test("an older host is sent a bank to keep only for bank zero, as it always was", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "bank", text: bankText("Quesynth Factory", ["Strings", "Brass"], 70)});
  page.forget();
  page.window.SynthBank.writePreset({bank: 0, slot: 5, name: "Mine"});
  assert.deepEqual(page.sent.map(m => [m.type, m.save]), [["bank", true]]);
  assert.equal("v" in page.sent[0] || "origin" in page.sent[0], false, "and none of the version-1 fields");
});

test("a bank the host sends with no origin to speak of is never one the panel asks it to save over its own", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "bank", text: bankText("Odd", MINE), v: 1, origin: "session", readOnly: false});
  page.send({type: "patch", name: "Alpha", index: 0, bank: "Odd", v: 1, origin: "session"});
  page.forget();
  assert.equal(page.window.SynthBank.bankInfo(1).persisted, false);
  page.window.SynthBank.writePreset({bank: "Odd", slot: 4, name: "Echo"});
  assert.equal(page.sent.find(m => m.type === "bank").save, false);
});

test("a host that cannot keep the bank is not claimed to have", () => {
  const page = plugin({slot: 0});
  page.window.SynthBank.writePreset({bank: bankIndex(page, "My Bank"), slot: 4, name: "Echo"});
  page.send({type: "bank-saved", v: 1, ok: false, error: "PersistenceFailed", message: "disk full", bank: "My Bank"});

  const failed = page.window.SynthBank.lastResult();
  assert.deepEqual([failed.ok, failed.error.code], [false, "PersistenceFailed"]);
  assert.match(page.text("bank-status"), /Could not save My Bank in the host \(disk full\)\. The change is kept for this session only\./);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "error");
  assert.equal(storedAt(page, bankIndex(page, "My Bank"), 4).name, "Echo", "the sound is in the bank here, as it was asked to be");
  assert.equal(page.window.SynthBank.bankInfo(bankIndex(page, "My Bank")).saveError, " (disk full)");

  // And it is only a failure until the host manages.
  page.window.SynthBank.writePreset({bank: bankIndex(page, "My Bank"), slot: 4, name: "Echo", overwrite: true});
  page.send({type: "bank-saved", v: 1, ok: true, bank: "My Bank"});
  assert.equal(page.window.SynthBank.bankInfo(bankIndex(page, "My Bank")).saveError, "");
});

test("an InvalidBank answer is a different failure from a disk that would not take it", () => {
  const page = plugin();
  page.send({type: "bank-saved", v: 1, ok: false, error: "InvalidBank", message: "not a bank", bank: "My Bank"});
  assert.equal(page.window.SynthBank.lastResult().error.code, "InvalidBank");
  page.send({type: "bank-saved", v: 1, ok: false, bank: "My Bank"});
  assert.equal(page.window.SynthBank.lastResult().error.code, "PersistenceFailed", "anything else is a persistence failure");
});

test("a daemon that refuses the bank it was sent says so, in the same words", () => {
  const page = plugin();
  page.send({type: "error", for: "bank", code: "invalid_payload", message: "bank needs text"});
  assert.equal(page.window.SynthBank.lastResult().error.code, "PersistenceFailed");
  assert.match(page.text("bank-status"), /did not take the bank \(bank needs text\)/);
});

test("a bank that was kept becomes the one the host comes back to", () => {
  const page = plugin({slot: 0});
  const added = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}]);
  page.window.SynthBank.select(added.index, true);
  page.forget();
  assert.equal(page.window.SynthBank.keep(), true);
  assert.deepEqual(plain(page.sent.map(m => [m.type, m.save, m.v])), [["bank", true, 1]]);
  page.send({type: "bank-saved", v: 1, ok: true, bank: "Third Party"});
  assert.equal(page.window.SynthBank.bankInfo(added.index).persisted, true);
  assert.equal(page.window.SynthBank.bankInfo(bankIndex(page, "My Bank")).persisted, false);
});

test("Keep, like Export, does not include an edit and says that it does not", () => {
  const page = plugin({slot: 1});
  page.window.SynthPatch.setParam(19, 0.5);
  page.window.SynthBank.keep();
  assert.match(page.text("bank-status"), /Kept My Bank\. Unsaved changes to Bravo were not included\./);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "warn");
  const kept = JSON.parse(page.sent.find(m => m.type === "bank").text);
  assert.equal(kept.patches[1].parameters[PARAM_NAMES[19]], 11, "slot 1 as stored, not as edited");
});

// ----------------------------------------------------------------- Save / Save As

test("Save writes back to the preset's own slot, with no question, when it may", () => {
  const page = plugin({slot: 1});
  page.window.SynthPatch.setParam(19, 0.5);
  const asked = [];
  page.window.SynthBrowser = {saveAs: () => asked.push("saveAs"), write: () => asked.push("write"), open: () => {}};

  const result = page.window.SynthBank.save();
  assert.deepEqual([result.ok, result.action, result.slot, result.name, result.overwrote], [true, "save", 1, "Bravo", true]);
  assert.deepEqual(asked, [], "it did not ask where");
  assert.equal(page.window.SynthBank.status(), "clean");
  assert.deepEqual(plain(page.sent.map(m => m.type).filter(t => t !== "set")), ["bank", "select"]);

  // The strip's own button is the same thing.
  page.window.SynthPatch.setParam(19, 0.7);
  page.$("preset-save").click();
  assert.equal(page.window.SynthBank.status(), "clean");
  assert.deepEqual(asked, []);
  assert.equal(page.$("preset-save").getAttribute("data-route"), "write");
  assert.match(page.$("preset-save").title, /Save to My Bank \/ 001/);
});

test("Save opens Save As for anything that is not a slot it may overwrite", () => {
  const ask = page => {
    const asked = [];
    page.window.SynthBrowser = {saveAs: () => asked.push("saveAs"), write: () => asked.push("write"), open: () => {}};
    const result = page.window.SynthBank.save();
    return {asked, result: plain(result), banks: plain(page.window.SynthBank.list())};
  };

  // Imported: somebody else's file.
  const imported = plugin({slot: 1, origin: "imported"});
  imported.window.SynthPatch.setParam(19, 0.5);
  const before = plain(imported.window.SynthBank.slots());
  const got = ask(imported);
  assert.deepEqual(got.asked, ["saveAs"]);
  assert.deepEqual([got.result.ok, got.result.action, got.result.pending], [true, "save-as", true]);
  assert.deepEqual(plain(imported.window.SynthBank.slots()), before, "and nothing was written");
  assert.equal(imported.$("preset-save").getAttribute("data-route"), "save-as");
  assert.deepEqual(imported.sent.filter(m => m.type === "bank"), []);

  // Read-only factory.
  const bare = bootPanel({bank: FACTORY, host: null});
  assert.deepEqual(ask(bare).asked, ["saveAs"]);

  // A file, a session, an archive, a bank the host says is read-only: no slot, or a slot that may not be written.
  const file = plugin();
  file.window.SynthPatch.apply(sound(3), "From a file");
  assert.deepEqual(ask(file).asked, ["saveAs"]);
  const session = plugin({slot: null});
  assert.deepEqual(ask(session).asked, ["saveAs"]);
  const locked = plugin({slot: 1, readOnly: true});
  assert.deepEqual(ask(locked).asked, ["saveAs"]);
  const archive = plugin();
  archive.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  archive.send({type: "patch", name: "Pad", index: null, bank: "a.zip", source: "archive", archive: {bank: 0, patch: 0}});
  assert.deepEqual(ask(archive).asked, ["saveAs"]);
});

test("Save As falls back to the Write view where the browser has no Save As of its own, and to a refusal with neither", () => {
  const page = plugin({slot: null});
  const asked = [];
  page.window.SynthBrowser = {write: () => asked.push("write"), open: () => {}};
  assert.equal(page.window.SynthBank.save().ok, true);
  assert.deepEqual(asked, ["write"]);

  const trimmed = bootPanel({bank: FACTORY, host: null, scripts: PANEL.filter(name => name !== "browser.js")});
  const result = trimmed.window.SynthBank.save();
  assert.equal(errorCode(result), "InvalidSlot");
  assert.match(trimmed.text("bank-status"), /nowhere to choose a destination/);
});

// --------------------------------------------------------------- copy and move

test("copy puts the preset in another slot and leaves the source, the sound and the selection alone", () => {
  const page = plugin({slot: 0});
  const at = bankIndex(page, "My Bank");
  const values = page.values();
  page.forget();
  const result = plain(page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 4}));
  assert.deepEqual([result.ok, result.action, result.name, result.overwrote], [true, "copy", "Delta", false]);
  assert.equal(storedAt(page, at, 3).name, "Delta");
  assert.equal(storedAt(page, at, 4).name, "Delta");
  assert.deepEqual(page.values(), values);
  assert.equal(page.window.SynthBank.selection().slot, 0);
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["bank"], "the host hears the bank once, and nothing about a sound");
  assert.equal(page.text("bank-status"), "Copied Delta from My Bank / 003 to My Bank / 004.");
});

test("a copy is a copy: editing one afterwards does not edit the other", () => {
  const page = plugin({slot: 0});
  const at = bankIndex(page, "My Bank");
  page.window.SynthBank.copySlot({bank: at, slot: 0}, {bank: at, slot: 4});
  page.window.SynthBank.load(4);
  page.window.SynthPatch.setParam(19, 0.9);
  page.window.SynthBank.writePreset({bank: at, slot: 4, name: "Alpha", overwrite: true});
  page.window.SynthBank.load(0);
  assert.equal(page.window.SynthBank.status(), "clean", "slot 0 is what it was");
});

test("onto a sound it needs overwrite: true, and refused it changes nothing", () => {
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  page.forget();
  const refused = page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 0});
  assert.equal(errorCode(refused), "OverwriteDenied");
  assert.equal(storedAt(page, at, 0).name, "Alpha");
  assert.deepEqual(page.sent, []);
  const moved = page.window.SynthBank.moveSlot({bank: at, slot: 3}, {bank: at, slot: 0});
  assert.equal(errorCode(moved), "OverwriteDenied");
  assert.equal(storedAt(page, at, 3).name, "Delta", "and a refused move does not clear its source");

  assert.equal(page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 0}, {overwrite: true}).overwrote, true);
  assert.equal(storedAt(page, at, 0).name, "Delta");
});

test("move is a copy and then a clear, committed together, and the selection goes with the sound it was", () => {
  const page = plugin({slot: 3});
  const at = bankIndex(page, "My Bank");
  page.forget();
  const result = plain(page.window.SynthBank.moveSlot({bank: at, slot: 3}, {bank: at, slot: 4}));
  assert.deepEqual([result.ok, result.action], [true, "move"]);
  assert.equal(storedAt(page, at, 3), null);
  assert.equal(storedAt(page, at, 4).name, "Delta");
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["bank", "select"], "published once, as one change");
  assert.equal(JSON.parse(page.sent[0].text).patches[3], null, "the host never sees the copy without the clear");
  assert.equal(page.window.SynthBank.selection().slot, 4);
  assert.equal(page.text("bank-patch"), "004:Delta");
  assert.equal(page.window.SynthBank.status(), "clean");
});

test("moving some other slot leaves the selection where it is", () => {
  const page = plugin({slot: 0});
  const at = bankIndex(page, "My Bank");
  page.window.SynthBank.moveSlot({bank: at, slot: 3}, {bank: at, slot: 4});
  assert.equal(page.window.SynthBank.selection().slot, 0);
  assert.equal(page.window.SynthBank.status(), "clean");
});

test("copying onto the slot that is playing leaves the sound and shows that it no longer matches", () => {
  const page = plugin({slot: 0});
  const at = bankIndex(page, "My Bank");
  page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 0}, {overwrite: true});
  assert.equal(page.window.SynthBank.status(), "dirty");
  assert.equal(page.window.SynthBank.selection().slot, 0);
});

test("the same slot is refused, an empty source is refused, and neither changes anything", () => {
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  page.forget();
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 3}, {overwrite: true})), "InvalidSlot");
  assert.equal(errorCode(page.window.SynthBank.moveSlot({bank: at, slot: 3}, {bank: at, slot: 3}, {overwrite: true})), "InvalidSlot");
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: at, slot: 2}, {bank: at, slot: 4})), "InvalidPreset", "slot 2 is empty");
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: at, slot: 3}, {bank: at, slot: 128})), "InvalidSlot");
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: 9, slot: 3}, {bank: at, slot: 4})), "InvalidSlot");
  assert.equal(storedAt(page, at, 3).name, "Delta");
  assert.deepEqual(page.sent, []);
});

test("a read-only source may be copied from but not moved from, and a read-only destination takes neither", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  const mine = page.window.SynthBank.newBank("Mine");
  const free = mine.index;
  const factory = bankIndex(page, "Quesynth Factory");

  const copied = page.window.SynthBank.copySlot({bank: factory, slot: 1}, {bank: free, slot: 9});
  assert.equal(copied.ok, true, "Factory / Brass may be copied out");
  assert.equal(storedAt(page, free, 9).name, "Brass");

  assert.equal(errorCode(page.window.SynthBank.moveSlot({bank: factory, slot: 1}, {bank: free, slot: 10})), "ReadOnlyBank");
  assert.equal(storedAt(page, factory, 1).name, "Brass", "the factory bank still has it");
  assert.equal(storedAt(page, free, 10), null);

  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: free, slot: 9}, {bank: factory, slot: 40})), "ReadOnlyBank");
  assert.equal(errorCode(page.window.SynthBank.moveSlot({bank: free, slot: 9}, {bank: factory, slot: 40})), "ReadOnlyBank");
  assert.equal(storedAt(page, free, 9).name, "Brass", "a refused move did not clear it");
});

test("a copy or move that breaks several rules gives the same refusal every time: what is taken, then where it goes, then the overwrite", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  const api = page.window.SynthBank;
  const mine = api.newBank("Mine").index;
  api.writePreset({bank: mine, slot: 0, name: "Zero"});
  api.writePreset({bank: mine, slot: 1, name: "One"});
  api.addLazy("Unopened", () => Promise.reject(new Error("must not be read")));
  const factory = bankIndex(page, "Quesynth Factory");
  const message = result => result.ok ? "ok" : result.error.message;

  // The source is judged before the read-only destination it is going to.
  assert.equal(errorCode(api.copySlot({bank: "Unopened", slot: 0}, {bank: factory, slot: 40})), "UnavailableSource");
  assert.equal(errorCode(api.copySlot({bank: mine, slot: 2}, {bank: factory, slot: 40})), "InvalidPreset", "slot 2 is empty");
  // The destination before the overwrite it would have asked about.
  assert.equal(errorCode(api.copySlot({bank: mine, slot: 0}, {bank: factory, slot: 1})), "ReadOnlyBank");
  assert.match(message(api.copySlot({bank: mine, slot: 0}, {bank: "Unopened", slot: 1})), /^Open Unopened before writing/);
  // A move's own rule, that it may not leave a read-only bank, comes after the
  // destination is judged and before the overwrite.
  assert.match(message(api.moveSlot({bank: factory, slot: 1}, {bank: "Unopened", slot: 0})), /^Open Unopened before writing/);
  assert.match(message(api.moveSlot({bank: factory, slot: 1}, {bank: mine, slot: 0})), /so nothing can be moved out of it/);
  assert.equal(errorCode(api.moveSlot({bank: mine, slot: 0}, {bank: mine, slot: 1})), "OverwriteDenied");
});

test("a bank not yet read, and a patch in the archive, are not there to copy from or to", () => {
  const page = plugin();
  page.window.SynthBank.addLazy("Unopened", () => Promise.reject(new Error("must not be read")));
  const at = bankIndex(page, "My Bank");
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: "Unopened", slot: 0}, {bank: at, slot: 4})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: at, slot: 0}, {bank: "Unopened", slot: 4})), "ReadOnlyBank");
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  assert.equal(errorCode(page.window.SynthBank.copySlot({bank: 1, slot: 0}, {bank: 0, slot: 4})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.moveSlot({bank: 1, slot: 0}, {bank: 0, slot: 4})), "ReadOnlyBank");
});

test("interior empty slots keep their numbers through a copy, a move and a host round trip", () => {
  const page = plugin();
  const at = bankIndex(page, "My Bank");
  page.window.SynthBank.copySlot({bank: at, slot: 0}, {bank: at, slot: 40});
  page.window.SynthBank.moveSlot({bank: at, slot: 5}, {bank: at, slot: 20});
  const doc = JSON.parse(page.sent.findLast(m => m.type === "bank").text);
  const where = doc.patches.map((p, i) => p && [i, p.name]).filter(Boolean);
  assert.deepEqual(where, [[0, "Alpha"], [1, "Bravo"], [3, "Delta"], [20, "Foxtrot"], [40, "Alpha"]]);
  assert.equal(doc.patches.length, 41, "trailing empties are the only ones dropped");
  assert.equal(doc.patches[2], null);
  assert.equal(doc.patches[5], null);
});

// -------------------------------------------------------------- bank management

test("bankInfo says what each bank is, where it came from, and whether it can be written", () => {
  const page = plugin();
  const rows = plain(page.window.SynthBank.list()).map(r => ({label: r.label, origin: r.origin, readOnly: r.readOnly, used: r.used,
    closable: r.closable, kind: r.kind, persisted: r.persisted, playing: r.playing, loading: r.loading, unavailable: r.unavailable}));
  assert.deepEqual(rows, [
    {label: "Quesynth Factory", origin: "factory", readOnly: true, used: 3, closable: false, kind: "bank", persisted: false,
      playing: false, loading: false, unavailable: false},
    {label: "My Bank", origin: "user", readOnly: false, used: 4, closable: false, kind: "bank", persisted: true,
      playing: true, loading: false, unavailable: false},
  ]);
  assert.equal(page.window.SynthBank.bankInfo(5), null);
});

test("a new bank is the user's own, empty, writable, and does not move the selection or the sound", () => {
  const page = plugin({slot: 1});
  const values = page.values();
  page.forget();
  const made = plain(page.window.SynthBank.newBank("Scratch"));
  assert.deepEqual([made.ok, made.label], [true, "Scratch"]);
  const info = plain(page.window.SynthBank.bankInfo(made.index));
  assert.deepEqual([info.origin, info.readOnly, info.used, info.closable], ["user", false, 0, true]);
  assert.equal(page.window.SynthBank.current(), made.index, "the browser is looking at it");
  assert.equal(page.window.SynthBank.selection().bank, "My Bank");
  assert.deepEqual(page.values(), values);
  assert.deepEqual(page.sent, [], "a bank nobody has chosen anything in is not the host's business");
  assert.equal(page.window.SynthBank.newBank("Scratch").label, "Scratch 2", "two banks are never called the same");
  assert.equal(page.window.SynthBank.create("Legacy"), made.index + 2, "the older call still answers with an index");
  assert.equal(errorCode(page.window.SynthBank.newBank("")), "InvalidName");
  assert.equal(errorCode(page.window.SynthBank.newBank("bad\nname")), "InvalidName");
});

test("rename: a bank the panel owns may be, one the host or the factory owns may not, and names stay distinct", () => {
  const page = plugin({slot: 1});
  const a = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}]);
  const b = page.window.SynthBank.newBank("Scratch");
  assert.equal(errorCode(page.window.SynthBank.renameBank(0, "x")), "ReadOnlyBank", "factory");
  assert.equal(errorCode(page.window.SynthBank.renameBank(bankIndex(page, "My Bank"), "x")), "ReadOnlyBank", "the host's");
  assert.equal(errorCode(page.window.SynthBank.renameBank(a.index, "Scratch")), "InvalidName", "taken");
  assert.equal(errorCode(page.window.SynthBank.renameBank(a.index, "  ")), "InvalidName");
  assert.equal(errorCode(page.window.SynthBank.renameBank(99, "x")), "InvalidSlot");
  assert.equal(page.window.SynthBank.renameBank(a.index, "Third Party").ok, true, "to itself is nothing to do");

  assert.equal(page.window.SynthBank.renameBank(b.index, "Sketches").ok, true);
  assert.equal(page.window.SynthBank.bankInfo(b.index).label, "Sketches");
  assert.equal(page.window.SynthBank.label(b.index), "Sketches");

  // A selection in it follows the name.
  page.window.SynthBank.loadPreset({bank: a.index, slot: 0});
  page.window.SynthBank.renameBank(a.index, "Renamed");
  assert.equal(page.window.SynthBank.selection().bank, "Renamed");
  assert.equal(page.text("bank-name"), "Renamed");
});

test("duplicate makes a writable copy of the user's own that shares nothing with the original", () => {
  const page = plugin();
  const original = bankIndex(page, "My Bank");
  const copy = plain(page.window.SynthBank.duplicateBank(original));
  assert.deepEqual([copy.ok, copy.label], [true, "My Bank copy"]);
  const info = plain(page.window.SynthBank.bankInfo(copy.index));
  assert.deepEqual([info.origin, info.readOnly, info.used, info.persisted, info.closable], ["user", false, 4, false, true]);
  page.window.SynthBank.writePreset({bank: copy.index, slot: 0, name: "Changed", overwrite: true});
  assert.equal(storedAt(page, original, 0).name, "Alpha", "the original is untouched");
  assert.equal(page.window.SynthBank.duplicateBank(original).label, "My Bank copy 2");
  assert.equal(page.window.SynthBank.duplicateBank(0).ok, true, "a read-only bank can be copied into one that is not");
  page.window.SynthBank.addLazy("Unopened", () => Promise.reject(new Error("must not be read")));
  assert.equal(errorCode(page.window.SynthBank.duplicateBank("Unopened")), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.duplicateBank(99)), "InvalidSlot");
});

test("closing a bank never closes the last, the host's or the factory's, and never touches the sound", () => {
  const page = plugin({slot: 1});
  const a = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}]);
  assert.equal(errorCode(page.window.SynthBank.removeBank(0)), "ReadOnlyBank", "factory");
  assert.equal(errorCode(page.window.SynthBank.removeBank(bankIndex(page, "My Bank"))), "ReadOnlyBank", "the host's");
  assert.equal(errorCode(page.window.SynthBank.removeBank(99)), "InvalidSlot");

  // Playing from it: the selection loses its slot, and the sound is as it was.
  page.window.SynthBank.loadPreset({bank: a.index, slot: 0});
  page.window.SynthPatch.setParam(19, 0.5);
  const values = page.values();
  page.forget();
  const removed = plain(page.window.SynthBank.removeBank(a.index));
  assert.deepEqual([removed.ok, removed.label], [true, "Third Party"]);
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "session", source: "none", bank: "", slot: null, presetName: "One", archive: null});
  assert.deepEqual(page.values(), values, "the sound did not change");
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["select"], "and the host is told only that it has no slot now");
  assert.deepEqual(plain(page.window.SynthBank.list()).map(b => b.label), ["Quesynth Factory", "My Bank"]);
  assert.equal(page.window.SynthBank.status(), "dirty", "still an edit, now of a sound with no slot");

  const lone = bootPanel({bank: null, host: null});
  assert.equal(errorCode(lone.window.SynthBank.removeBank(0)), "ReadOnlyBank", "the last bank");
});

test("closing a bank below the one in view keeps the view on the same bank", () => {
  const page = plugin();
  const a = page.window.SynthBank.importBank("A", [{n: "One", v: sound(1)}]);
  const b = page.window.SynthBank.importBank("B", [{n: "Two", v: sound(2)}]);
  page.window.SynthBank.select(b.index, true);
  page.window.SynthBank.removeBank(a.index);
  assert.equal(page.window.SynthBank.label(), "B");
  assert.equal(page.window.SynthBank.current(), bankIndex(page, "B"));
});

// ------------------------------------------------------------- load a preset

test("loadPreset loads a slot of a bank the panel holds, and the host hears the bank, the sound and the selection", () => {
  const page = plugin({slot: 0});
  const added = page.window.SynthBank.importBank("Third Party", [{n: "One", v: sound(1)}, {n: "Two", v: sound(2)}]);
  page.forget();
  const result = plain(page.window.SynthBank.loadPreset({bank: added.index, slot: 1}));
  assert.deepEqual([result.ok, result.action, result.pending, result.name, result.slot], [true, "load", false, "Two", 1]);
  assert.deepEqual(page.values(), sound(2));
  assert.equal(page.window.SynthBank.current(), added.index, "the bank in view follows what was loaded");
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["bank", "state", "select"]);
  assert.equal(page.sent[0].save, false);
  assert.equal(plain(page.window.SynthBank.selection()).origin, "imported");
  assert.equal(page.text("bank-status"), "Loaded Two from Third Party / 001.");
});

test("loadPreset refuses what is not there, and changes nothing when it does", () => {
  const page = plugin({slot: 1});
  const at = bankIndex(page, "My Bank");
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());
  page.forget();
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: at, slot: 2})), "InvalidPreset", "an empty slot is not a preset");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: at, slot: 200})), "InvalidPreset");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: at, slot: "1"})), "InvalidPreset");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: 77, slot: 1})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: "Nope", slot: 1})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.loadPreset(null)), "InvalidPreset");
  let loads = 0;
  page.window.SynthBank.addLazy("Unopened", () => { loads++; return Promise.resolve([]); });
  assert.equal(errorCode(page.window.SynthBank.loadPreset({bank: "Unopened", slot: 0})), "UnavailableSource");
  assert.equal(loads, 0, "loading a preset never opens a bank");
  assert.deepEqual(page.values(), values);
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
  assert.deepEqual(page.sent, []);
});

test("an archive preset is asked of the host, shows loading, and is selected only when the host says so", () => {
  const page = plugin({slot: 0});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  const before = plain(page.window.SynthBank.selection());
  page.forget();

  const result = plain(page.window.SynthBank.loadPreset({archive: {bank: 1, patch: 1}}));
  assert.deepEqual([result.ok, result.pending, result.archive], [true, true, {bank: 1, patch: 1}]);
  assert.deepEqual(plain(page.sent), [{type: "archive-load", bank: 1, index: 1}]);
  assert.equal(page.window.SynthBank.status(), "loading");
  assert.deepEqual(plain(page.window.SynthBank.selection()), before, "not before the host answers");
  assert.equal(page.text("bank-patch"), "000:Alpha");

  page.send({type: "patch", name: "Bass", index: null, bank: "b.zip", source: "archive", archive: {bank: 1, patch: 1}});
  assert.equal(page.window.SynthBank.status(), "readonly");
  assert.equal(page.text("bank-patch"), "001:Bass");

  // An archive row named as a bank and a slot is the same request.
  page.forget();
  assert.equal(page.window.SynthBank.loadPreset({bank: 2, slot: 0}).pending, true);
  assert.deepEqual(plain(page.sent), [{type: "archive-load", bank: 1, index: 0}]);
});

test("the host refusing an archive load leaves the selection and says so in a named code", () => {
  const page = plugin({slot: 0});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  const before = plain(page.window.SynthBank.selection());
  page.window.SynthBank.loadPreset({archive: {bank: 0, patch: 0}});
  page.send({type: "error", for: "archive-load", code: "invalid_payload", message: "patch index out of range"});
  assert.equal(page.window.SynthBank.lastResult().error.code, "HostRejected");
  assert.match(page.text("bank-status"), /did not load that patch: patch index out of range/);
  assert.equal(page.window.SynthBank.status(), "clean", "no longer loading");
  assert.deepEqual(plain(page.window.SynthBank.selection()), before);
});

test("archive loads are refused where there is no archive, or the preset is not in it", () => {
  const page = plugin();
  assert.equal(errorCode(page.window.SynthBank.loadPreset({archive: {bank: 0, patch: 0}})), "UnavailableSource");
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  page.forget();
  assert.equal(errorCode(page.window.SynthBank.loadPreset({archive: {bank: 5, patch: 0}})), "UnavailableSource");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({archive: {bank: 0, patch: 9}})), "InvalidPreset", "past the names the host sent");
  assert.equal(errorCode(page.window.SynthBank.loadPreset({archive: {bank: 0, patch: -1}})), "InvalidPreset");
  assert.deepEqual(page.sent, []);
});

// ------------------------------------------------------------ the preset index

test("presets() lists every preset the panel can load, in one fixed order", () => {
  const page = plugin({slot: 1});
  page.window.SynthBank.importBank("Zeta", [{n: "Z0", v: sound(1)}, null, {n: "Z2", v: sound(2)}]);
  page.window.SynthBank.importBank("Alpha Bank", [{n: "A0", v: sound(1)}]);
  const list = plain(page.window.SynthBank.presets());
  assert.deepEqual(list.map(p => [p.origin, p.bank, p.slot, p.name]), [
    ["factory", "Quesynth Factory", 0, "Strings"], ["factory", "Quesynth Factory", 1, "Brass"],
    ["factory", "Quesynth Factory", 2, "Bells"],
    ["user", "My Bank", 0, "Alpha"], ["user", "My Bank", 1, "Bravo"], ["user", "My Bank", 3, "Delta"],
    ["user", "My Bank", 5, "Foxtrot"],
    ["imported", "Zeta", 0, "Z0"], ["imported", "Zeta", 2, "Z2"], ["imported", "Alpha Bank", 0, "A0"],
  ], "origin rank, then the order banks were opened in, then slot; empty slots are not presets");
  assert.deepEqual(plain(page.window.SynthBank.presets()), list, "and the same twice");
  assert.deepEqual(list.map(p => p.readOnly), [true, true, true, false, false, false, false, false, false, false]);
  const loadable = list.filter(p => p.bankIndex >= 0 && p.slot !== null);
  for (const p of loadable) assert.equal(page.window.SynthBank.loadPreset({bank: p.bankIndex, slot: p.slot}).ok, true, p.key);
});

test("a preset's key is made of what names it, so a renamed bank or a rewritten slot is a different preset", () => {
  const page = plugin();
  const key = () => plain(page.window.SynthBank.presets()).find(p => p.name === "Alpha").key;
  assert.equal(key(), "user\u0000My Bank\u00000\u0000Alpha");
  page.window.SynthBank.writePreset({bank: "My Bank", slot: 0, name: "Alpha 2", overwrite: true});
  assert.equal(plain(page.window.SynthBank.presets()).some(p => p.key === "user\u0000My Bank\u00000\u0000Alpha"), false);
});

test("a bank that is listed but not read adds no names, and listing never reads it", async () => {
  const page = plugin();
  let reads = 0;
  page.window.SynthBank.addLazy("Archive Of Things", () => { reads++; return Promise.resolve([{n: "Hidden", v: sound(1)}]); });
  assert.equal(plain(page.window.SynthBank.presets()).some(p => p.bank === "Archive Of Things"), false);
  page.window.SynthBank.list();
  page.window.SynthBank.bankInfo(2);
  assert.equal(reads, 0);
  assert.equal(page.window.SynthBank.bankInfo(2).used, null, "and says plainly that it does not know how many");

  await new Promise(resolve => page.window.SynthBank.select(2, true, (err, state) => { if (state !== "loading") resolve(); }));
  assert.equal(reads, 1);
  assert.deepEqual(plain(page.window.SynthBank.presets()).filter(p => p.bank === "Archive Of Things").map(p => p.name), ["Hidden"],
    "once it has been opened, its names are known");
});

test("a bank that could not be read says so and can be tried again", async () => {
  const page = plugin();
  let fail = true;
  page.window.SynthBank.addLazy("Flaky", () => fail ? Promise.reject(new Error("the archive is damaged")) : Promise.resolve([{n: "Back", v: sound(1)}]));
  const first = await new Promise(resolve => page.window.SynthBank.select(2, true, (err, state) => { if (state !== "loading") resolve(err); }));
  assert.equal(first.message, "the archive is damaged");
  const info = plain(page.window.SynthBank.bankInfo(2));
  assert.deepEqual([info.unavailable, info.error, info.used], [true, "the archive is damaged", null]);
  fail = false;
  await new Promise(resolve => page.window.SynthBank.select(2, true, (err, state) => { if (state !== "loading") resolve(); }));
  assert.equal(page.window.SynthBank.bankInfo(2).unavailable, false);
  assert.equal(page.window.SynthBank.bankInfo(2).used, 1);
});

test("an open archive bank's names are presets, the playing session sound is one too, and an archive never has a slot", () => {
  const page = plugin({slot: null});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 1, patches: ["Pad", "Bass"]});
  const list = plain(page.window.SynthBank.presets());
  assert.deepEqual(list.map(p => [p.origin, p.name, p.slot, p.archive, p.bankIndex]), [
    ["user", "Alpha", 0, null, 0], ["user", "Bravo", 1, null, 0], ["user", "Delta", 3, null, 0], ["user", "Foxtrot", 5, null, 0],
    ["archive", "Pad", null, {bank: 1, patch: 0}, 2], ["archive", "Bass", null, {bank: 1, patch: 1}, 2],
    ["session", "Untitled", null, null, -1],
  ].map(x => x), "factory is not here: with an archive open the host's bank is the ordinary one");
  assert.equal(list.at(-1).live, true);
  assert.equal(list.find(p => p.name === "Bass").key, "archive\u0000b.zip\u0000a1.1\u0000Bass");
  assert.equal(list.find(p => p.name === "Bass").readOnly, true);
});

test("presets() holds nothing a bank file would not: names, positions and where they came from, and no parameter values", () => {
  const page = plugin();
  for (const p of plain(page.window.SynthBank.presets())) {
    assert.deepEqual(Object.keys(p).sort(), ["archive", "bank", "bankIndex", "key", "live", "name", "origin", "readOnly", "slot", "source"]);
  }
});
