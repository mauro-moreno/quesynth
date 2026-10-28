// Which bank a write may ask the host to save.
//
// The host keeps one saved bank per instrument, and a `bank` message with
// "save": true replaces it whole (specs/2026-10-27-preset-bank-ux.md: 1, 3.4,
// 5.3 and 2.4). So at most one bank in the page may carry that standing, the
// one the host most recently called its own, and nothing but a person writing
// that bank's content may spend it.
//
// The recovery path is where it went wrong. An instance whose saved bank file
// is missing starts on the compiled-in `Factory`, which the host sends as
// origin factory and not read-only; the person puts the file back and presses
// Retry, and the host sends `Alfmeister Bank` as origin user. Both are banks
// the host calls its own, and the page kept `Factory` writable beside it.
// Loading one Factory preset then sent Factory with "save": true, and the host
// wrote it over the user's file: a 119-patch bank became 16 patches.

import test from "node:test";
import assert from "node:assert/strict";
import {bankText, bootPanel, compiledBank, plain, sound, syncAnswer} from "./support/panel.mjs";

// What bank.js compiled into the page. The host's own is called `Factory`.
const PAGE_FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const HOST_FACTORY = ["Init", "Strings", "Brass", "Bells", "Pluck", "Lead"];
const USER = Array.from({length: 60}, (_, i) => i === 42 ? "Foo" : i % 7 === 3 ? null : `Mine ${i}`);
const WANTED = {origin: "user", bank: "Alfmeister Bank", slot: 42, name: "Foo"};

// The messages the host sends for a bank, as wire-v1.json spells them.
const hostBank = (label, names, origin, base) =>
  ({type: "bank", text: bankText(label, names, base), v: 1, origin, readOnly: false});

// The page of an instance that started on the compiled-in Factory because its
// saved bank was missing, was shown the failure, and was Retried after the
// file came back: the host answers the retry with the user's bank, the patch
// and the restore.
function afterRetry() {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank("Factory", HOST_FACTORY, "factory", 30));
  page.send({type: "state", values: sound(99)});
  page.send({type: "restore", v: 1, state: "failed", error: "MissingBank", recoverable: true,
    message: "no bank named Alfmeister Bank", ...WANTED});
  assert.equal(page.window.SynthBank.restore.retry().ok, true);
  page.send(hostBank("Alfmeister Bank", USER, "user", 10));
  page.send({type: "patch", name: "Foo", index: 42, bank: "Alfmeister Bank", v: 1, origin: "user"});
  page.send({type: "restore", v: 1, state: "restored", ...WANTED});
  page.forget();
  return page;
}

const rows = page => plain(page.window.SynthBank.list());
const persisted = page => rows(page).filter(r => r.persisted).map(r => r.label);
const at = (page, label) => rows(page).findIndex(r => r.label === label);
// What each `bank` the page posted asked of the host: [label, save].
const banks = page => page.ofType("bank").map(m => [JSON.parse(m.text).name, m.save]);
const saves = page => banks(page).filter(([, save]) => save).map(([label]) => label);
const clickStep = (page, step) => page.document.querySelector(`.bank-step[data-step="${step}"]`).click();

test("after Retry brings the user's bank, only that bank is the one the host keeps", () => {
  const page = afterRetry();
  assert.deepEqual(rows(page).map(r => r.label), ["Quesynth Factory", "Factory", "Alfmeister Bank"]);
  assert.deepEqual(persisted(page), ["Alfmeister Bank"]);
});

test("a preset of the stale Factory is played, never saved over the user's bank", () => {
  const page = afterRetry();
  const factory = at(page, "Factory");

  assert.equal(page.window.SynthBank.loadPreset({bank: "Factory", slot: 4}).ok, true);
  assert.deepEqual(banks(page), [["Factory", false]], "played, and not kept");

  page.forget();
  clickStep(page, 1);
  clickStep(page, -1);
  assert.deepEqual(plain(page.sent.filter(m => m.type === "state").length), 2, "NEXT and PREV did load");
  assert.deepEqual(saves(page), []);

  page.forget();
  page.window.SynthBank.select(at(page, "Alfmeister Bank"), true);
  page.window.SynthBank.select(factory);
  page.window.SynthBank.load(2);
  assert.deepEqual(saves(page), [], "switching to Factory and choosing in it");
});

test("Save and Write into the stale Factory are session-only changes: allowed, and not kept", () => {
  const page = afterRetry();
  const api = page.window.SynthBank;
  api.loadPreset({bank: "Factory", slot: 2});
  page.window.SynthPatch.setParam(19, 0.5);
  page.forget();

  const saved = plain(api.save());
  assert.deepEqual([saved.ok, saved.action, saved.bank, saved.slot], [true, "save", "Factory", 2]);
  const wrote = plain(api.writePreset({bank: "Factory", slot: 9, name: "Mine"}));
  assert.deepEqual([wrote.ok, wrote.bank, wrote.slot], [true, "Factory", 9]);

  assert.ok(banks(page).length > 0, "the host was given the edited bank to play");
  assert.deepEqual(saves(page), []);
  assert.deepEqual(persisted(page), ["Alfmeister Bank"]);
});

test("copying and moving into or out of the stale Factory keeps only the user's bank", () => {
  const page = afterRetry();
  const api = page.window.SynthBank;

  assert.equal(api.copySlot({bank: "Alfmeister Bank", slot: 0}, {bank: "Factory", slot: 10}).ok, true);
  assert.deepEqual(saves(page), [], "into Factory");

  page.forget();
  assert.equal(api.copySlot({bank: "Factory", slot: 1}, {bank: "Alfmeister Bank", slot: 3}).ok, true);
  assert.deepEqual(saves(page), ["Alfmeister Bank"], "out of Factory, into the user's bank");

  page.forget();
  assert.equal(api.moveSlot({bank: "Factory", slot: 10}, {bank: "Alfmeister Bank", slot: 10}).ok, true);
  assert.deepEqual(saves(page), ["Alfmeister Bank"], "a move changes both banks, and keeps the one that is kept");
});

test("a write into the user's bank is still kept, as that bank, with its interior empties", () => {
  const page = afterRetry();
  const wrote = plain(page.window.SynthBank.writePreset({bank: "Alfmeister Bank", slot: 3, name: "Filled"}));
  assert.equal(wrote.ok, true);

  assert.deepEqual(saves(page), ["Alfmeister Bank"]);
  const bank = page.ofType("bank").find(m => m.save);
  assert.deepEqual([bank.v, bank.origin], [1, "user"]);
  const doc = JSON.parse(bank.text);
  assert.equal(doc.patches.length, 59, "the trailing empties go, the interior ones stay");
  assert.deepEqual(doc.patches.map((p, i) => [i, p]).filter(([, p]) => p === null).map(([i]) => i),
    [10, 17, 24, 31, 38, 45, 52], "slot 3 was filled; every other gap is still a gap");
  assert.equal(doc.patches[42].name, "Foo");
});

test("two banks the host calls its own in a row: the later is the one it keeps", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank("Factory", HOST_FACTORY, "factory", 30));
  assert.deepEqual(persisted(page), ["Factory"]);
  page.send(hostBank("My Bank", USER, "user", 10));
  assert.deepEqual(persisted(page), ["My Bank"]);

  // Nothing about the first one is lost: it is still there to play and edit.
  assert.equal(page.window.SynthBank.bankInfo(at(page, "Factory")).used, HOST_FACTORY.length);
  assert.equal(page.window.SynthBank.writePreset({bank: "Factory", slot: 9, name: "Mine"}).ok, true);
  assert.deepEqual(saves(page), []);
});

test("a bank the host embeds from somebody's file does not take the saved bank's standing", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank("My Bank", USER, "user", 10));
  page.send(hostBank("Third Party", ["One", "Two"], "imported", 50));
  assert.deepEqual(persisted(page), ["My Bank"], "the host still keeps the file it kept");
});

test("a host's bank sent again under its own name is still the one it keeps, once", () => {
  const page = afterRetry();
  page.send(hostBank("Alfmeister Bank", USER, "user", 10));
  assert.deepEqual(persisted(page), ["Alfmeister Bank"]);
});

test("Keep makes the kept bank the only one a write may save, and Factory is not it", () => {
  const page = afterRetry();
  const api = page.window.SynthBank;
  const added = api.importBank("Third Party", [{n: "One", v: sound(1)}]);
  api.select(added.index, true);

  assert.equal(api.keep(), true);
  assert.deepEqual(saves(page), ["Third Party"]);
  page.send({type: "bank-saved", v: 1, ok: true, bank: "Third Party"});
  assert.deepEqual(persisted(page), ["Third Party"]);

  page.forget();
  api.loadPreset({bank: "Factory", slot: 1});
  api.loadPreset({bank: "Alfmeister Bank", slot: 0});
  assert.deepEqual(saves(page), [], "neither of the banks the host kept before is sent to be saved by a load");

  api.writePreset({bank: "Alfmeister Bank", slot: 1, name: "Edit", overwrite: true});
  assert.deepEqual(saves(page), [], "and a write into one is not asked to be kept either");
  api.writePreset({bank: "Third Party", slot: 1, name: "Two"});
  assert.deepEqual(saves(page), ["Third Party"]);
});

test("a Keep the host could not make leaves the bank it kept as the one it keeps", () => {
  const page = afterRetry();
  const api = page.window.SynthBank;
  const added = api.importBank("Third Party", [{n: "One", v: sound(1)}]);
  api.select(added.index, true);
  api.keep();
  page.send({type: "bank-saved", v: 1, ok: false, error: "PersistenceFailed", message: "disk full", bank: "Third Party"});
  assert.deepEqual(persisted(page), ["Alfmeister Bank"]);
});

test("a host that never said it keeps a bank is never sent one to keep by a load", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send({type: "bank", text: bankText("Factory", HOST_FACTORY, 30)});
  page.send({type: "bank", text: bankText("My Bank", USER, 10)});
  assert.deepEqual(persisted(page), []);
  page.forget();
  page.window.SynthBank.loadPreset({bank: "Factory", slot: 1});
  assert.deepEqual(banks(page), [["Factory", false]]);
});

test("the restore that brought the bank back is not itself a write", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  for (const m of syncAnswer({label: "Factory", names: HOST_FACTORY, origin: "factory", state: sound(99),
    restore: {type: "restore", v: 1, state: "failed", error: "MissingBank", recoverable: true, ...WANTED}})) page.send(m);
  page.window.SynthBank.restore.retry();
  page.send(hostBank("Alfmeister Bank", USER, "user", 10));
  page.send({type: "patch", name: "Foo", index: 42, bank: "Alfmeister Bank", v: 1, origin: "user"});
  page.send({type: "restore", v: 1, state: "restored", ...WANTED});
  assert.deepEqual(page.sent.filter(m => m.type === "bank"), [], "sent apart from the sync and the retry");
});
