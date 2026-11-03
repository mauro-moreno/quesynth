// What the panel does with the host's answer to "restore the bank and program
// this project was saved with".
//
// The contract (specs/2026-10-27-preset-bank-ux.md, sections 3.4 and 5.6): a
// failed restore keeps the sound that is playing, says so in words that name the
// bank and slot, offers a way out, and never loads the factory bank unless the
// person clicks for it.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, defaults, plain, sound, syncAnswer} from "./support/panel.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const NAMES = Array.from({length: 50}, (_, i) => i === 42 ? "Foo" : `Imported ${i}`);
const WANTED = {origin: "imported", bank: "Alfmeister Bank", slot: 42, name: "Foo"};

// A plugin whose project asked for the bank `Alfmeister Bank`, which is gone: the
// host kept playing the factory bank, and answered the sync with the failure.
function missingBank(extra = {}) {
  const page = bootPanel({bank: FACTORY});
  const hostSound = sound(99);
  const failure = {type: "restore", v: 1, state: "failed", error: "MissingBank", recoverable: true,
    message: "no bank named Alfmeister Bank", ...WANTED, ...extra};
  for (const m of syncAnswer({label: "Quesynth Factory", names: ["Strings", "Brass", "Bells"], origin: "factory",
    state: hostSound, restore: failure})) page.send(m);
  return {page, hostSound};
}

const banner = page => page.$("restore-banner");
const shown = element => !element.hasAttribute("hidden");

test("a failed restore keeps the sound, the selection and the bank, and loads nothing", () => {
  const {page, hostSound} = missingBank();
  assert.deepEqual(page.values(), hostSound);
  assert.deepEqual(page.sent.filter(m => m.type === "state" || m.type === "select"), []);
  assert.equal(page.window.SynthBank.selection().origin, "session", "no selection was reported, so none is invented");
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory", "the bank in view is the host's, not a guess");
  assert.deepEqual(plain(page.window.SynthBank.restoreState()), {
    state: "failed", error: "MissingBank", recoverable: true,
    message: "no bank named Alfmeister Bank", ...WANTED,
  });
  assert.equal(page.window.SynthBank.status(), "unavailable");
});

test("the failure reads as the specification words it, with the bank and slot in a code element", () => {
  const {page} = missingBank();
  assert.ok(shown(banner(page)));
  assert.equal(banner(page).getAttribute("role"), "alert");

  const line = page.$("restore-failed-text");
  assert.equal(line.textContent, "Could not restore Alfmeister Bank / 042. The current sound was kept.");
  const code = line.querySelector("code");
  assert.equal(code.textContent, "Alfmeister Bank / 042", "the slot is zero padded to three digits");

  const buttons = page.$("restore-failed").querySelectorAll("button").filter(b => shown(b)).map(b => b.textContent);
  assert.deepEqual(buttons, ["Retry", "Choose bank"]);

  const missing = page.$("restore-missing");
  assert.ok(shown(missing));
  assert.equal(missing.querySelector("p").textContent, "The saved bank is unavailable. Load Factory / Init instead?");
  assert.deepEqual(missing.querySelectorAll("button").map(b => b.textContent), ["Load Factory / Init", "Keep current sound"]);
});

test("only a missing bank offers the factory; other failures do not", () => {
  const {page} = missingBank({error: "InvalidProgram", message: "slot 42 is empty"});
  assert.ok(shown(page.$("restore-failed")));
  assert.ok(!shown(page.$("restore-missing")), "InvalidProgram is not a reason to offer Factory / Init");
  assert.ok(shown(page.$("restore-dismiss")), "something has to dismiss it when there is no second line");
});

test("a failure the host says cannot be retried does not offer Retry", () => {
  const {page} = missingBank({error: "StateVersionUnsupported", recoverable: false, message: "newer project"});
  assert.equal(page.window.SynthBank.restoreState().recoverable, false);
  assert.ok(page.$("restore-retry").disabled, "retrying cannot change the answer");
});

test("a failure without a slot names only the bank, and without either says what it can", () => {
  const {page} = missingBank({slot: null, name: undefined});
  assert.equal(page.$("restore-failed-text").textContent, "Could not restore Alfmeister Bank. The current sound was kept.");
  const bare = missingBank({slot: null, bank: undefined, name: undefined}).page;
  assert.equal(bare.$("restore-failed-text").textContent, "Could not restore the saved preset. The current sound was kept.");
});

test("Retry asks the host again and shows nothing final until it answers", () => {
  const {page, hostSound} = missingBank();
  page.forget();
  assert.equal(page.window.SynthBank.restore.retry().ok, true);
  assert.deepEqual(plain(page.sent), [{type: "restore-retry", v: 1}]);
  assert.equal(page.window.SynthBank.restoreState().state, "restoring");
  assert.equal(page.window.SynthBank.status(), "loading");
  assert.deepEqual(page.values(), hostSound, "waiting does not touch the sound");

  // The bank came back: the host answers with the restore and its selection.
  page.send({type: "bank", text: syncAnswer({names: NAMES})[0].text, v: 1, origin: "imported", readOnly: false, kept: false});
  page.send({type: "patch", name: "Foo", index: 42, bank: "Alfmeister Bank", v: 1, origin: "imported"});
  page.send({type: "restore", v: 1, state: "restored", ...WANTED});
  assert.equal(page.window.SynthBank.restoreState().state, "restored");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "imported", source: "bank", bank: "Alfmeister Bank", slot: 42, presetName: "Foo", archive: null});
  assert.ok(!shown(page.$("restore-failed")));
  assert.equal(page.$("restore-ok").textContent, "Restored Imported / Alfmeister Bank / 042 Foo");
  assert.deepEqual(page.sent.slice(1).filter(m => m.type === "state" || m.type === "select"), []);
});

test("Keep current sound tells the host to forget the identity and changes nothing else", () => {
  const {page, hostSound} = missingBank();
  page.forget();
  page.$("restore-keep").click();
  assert.deepEqual(plain(page.sent), [{type: "restore-discard", v: 1}]);
  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)));
  assert.deepEqual(page.values(), hostSound);
});

test("Choose bank opens the browser and leaves the banner up until something is chosen", () => {
  const {page} = missingBank();
  let opened = 0;
  page.window.SynthBrowser = {open: () => { opened++; }};
  page.$("restore-choose").click();
  assert.equal(opened, 1);
  assert.ok(shown(banner(page)), "browsing is not choosing");
  assert.deepEqual(page.sent.filter(m => /^restore-/.test(m.type)), []);
});

test("Load Factory / Init is an explicit act: nothing loads before the click, and the click does what it says", () => {
  const {page} = missingBank();
  page.forget();
  assert.deepEqual(page.sent, [], "showing the failure sent nothing");
  page.$("restore-factory").click();

  assert.deepEqual(page.values(), defaults(), "the reference Init patch: every parameter at its default");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "factory", source: "bank", bank: "Quesynth Factory", slot: null, presetName: "Init", archive: null});
  assert.equal(page.text("bank-patch"), "Init");
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["state", "select"]);
  assert.deepEqual(plain(page.sent[1]),
    {type: "select", v: 1, origin: "factory", bank: "Quesynth Factory", slot: null, name: "Init"});
  assert.equal(page.window.SynthBank.restoreState().state, "notRequested", "the choice resolves the failure");
  assert.ok(!shown(banner(page)));
});

test("choosing a preset after a failure replaces the pending identity", () => {
  const {page} = missingBank();
  page.forget();
  page.window.SynthBank.load(1);
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["state", "select"],
    "a select replaces what the host was holding for a retry");
  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)));
});

test("a host that never said v:1 is never sent the new messages, and Retry says why not", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "state", values: sound(99)});
  page.forget();
  const result = page.window.SynthBank.restore.retry();
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "HostRejected");
  page.window.SynthBank.restore.discard();
  page.window.SynthBank.load(1);
  assert.deepEqual(page.sent.map(m => m.type), ["state"], "a legacy host hears only what it always heard");
});

test("a restore that contradicts the retry in flight is reported, not silently adopted as the answer", () => {
  const {page} = missingBank();
  page.window.SynthBank.restore.retry();
  page.send({type: "restore", v: 1, state: "restored", origin: "user", bank: "Somewhere Else", slot: 3, name: "Other"});
  assert.equal(page.window.SynthBank.restoreState().conflict, true);
  assert.equal(page.window.SynthBank.restoreState().state, "restored", "the host is authoritative");
});

test("loading a preset while a retry is in flight is refused as a conflict", () => {
  const {page} = missingBank();
  page.window.SynthBank.restore.retry();
  const result = page.window.SynthBank.loadPreset({bank: 0, slot: 1});
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "RestorationConflict");
});

test("an unknown restore error code is shown as the host rejecting the state, never as a made-up reason", () => {
  const {page} = missingBank({error: "Surprise", recoverable: undefined});
  assert.equal(page.window.SynthBank.restoreState().error, "HostStateRejected");
});

test("a bank restored with nothing selected in it leaves the selection and the sound as they are", () => {
  const {page, hostSound} = missingBank();
  page.send({type: "restore", v: 1, state: "restored", origin: "user", bank: "Quesynth Factory", slot: null, name: ""});
  assert.equal(page.window.SynthBank.restoreState().state, "restored");
  assert.equal(page.window.SynthBank.selection().origin, "session");
  assert.deepEqual(page.values(), hostSound);
  assert.equal(page.$("restore-ok").textContent, "Restored User / Quesynth Factory");
});

// -- the host drops the recovery it was holding ----------------------------------
//
// A MIDI Program Change is a choice like any other, and the host's session lets
// go of a failed restore when one arrives. The page has to follow, or it shows a
// Retry for something the host no longer holds.

// What a plugin sends when a Program Change moved it to Brass: the sound, then
// the selection. The bank in `missingBank` is the host's, so its cutoffs are
// those of `bankText`.
function programChange(page) {
  page.send({type: "state", values: sound(11)});
  page.send({type: "patch", name: "Brass", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
}

test("a Program Change the host reports ends a failed restore, as a person choosing a preset does", () => {
  const {page} = missingBank();
  programChange(page);

  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)), "the banner is still up for a recovery the host dropped");
  assert.equal(page.window.SynthBank.status(), "clean");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "factory", source: "bank", bank: "Quesynth Factory", slot: 1, presetName: "Brass", archive: null});
  assert.deepEqual(page.sent.filter(m => m.type === "state" || m.type === "select"), [],
    "following the host sends the host nothing");
});

test("a Program Change reported while a retry waits leaves the answer to resolve it, and the host always gives one", () => {
  const {page} = missingBank();
  page.window.SynthBank.restore.retry();
  programChange(page);
  assert.equal(page.window.SynthBank.restoreState().state, "restoring",
    "the retry is still waiting on the host, whose answer carries a patch ahead of its restore");
  assert.equal(page.window.SynthBank.selection().presetName, "Brass", "though the host's selection is the page's");

  page.send({type: "restore", v: 1, state: "notRequested"});
  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)));
  assert.equal(page.window.SynthBank.loadPreset({bank: 0, slot: 2}).ok, true,
    "loading is not refused as a conflict with a restore nobody is waiting for");
});

test("Retry after the host dropped the recovery is answered and resolves", () => {
  const {page} = missingBank();
  page.forget();
  // The page was never told: the host dropped it between the failure and the click.
  assert.equal(page.window.SynthBank.restore.retry().ok, true);
  assert.equal(page.window.SynthBank.restoreState().state, "restoring");
  assert.equal(page.$("restore-banner").getAttribute("aria-busy"), "true");

  // What the host answers a retry with when it holds nothing to retry: where it
  // is now, and that it is not restoring anything.
  page.send({type: "state", values: sound(11)});
  page.send({type: "patch", name: "Brass", index: 1, bank: "Quesynth Factory", v: 1, origin: "factory"});
  page.send({type: "restore", v: 1, state: "notRequested"});

  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)));
  assert.equal(page.$("restore-banner").getAttribute("aria-busy"), "false");
  assert.equal(page.window.SynthBank.status(), "clean", "nothing is waiting any more");
  assert.equal(page.window.SynthBank.loadPreset({bank: 0, slot: 2}).ok, true);
});

test("a host with nothing selected answers a retry with the restore alone, and that resolves it", () => {
  const {page, hostSound} = missingBank();
  page.window.SynthBank.restore.retry();
  page.send({type: "restore", v: 1, state: "notRequested"});

  assert.equal(page.window.SynthBank.restoreState().state, "notRequested");
  assert.ok(!shown(banner(page)));
  assert.equal(page.window.SynthBank.selection().origin, "session", "no selection is invented");
  assert.deepEqual(page.values(), hostSound, "and the sound is the one it was");
});

test("a sync that names a selection and then a failed restore still shows the failure", () => {
  // The order a host answers `sync` in is bank, state, patch, restore, and a
  // patch is what ends a failure on the page. The restore after it is the
  // host saying the failure still stands, so it must win.
  const {page} = missingBank();
  const names = ["Strings", "Brass", "Bells"];
  const again = {type: "restore", v: 1, state: "failed", error: "InvalidProgram", recoverable: true,
    message: "slot 42 is empty", ...WANTED};
  for (const m of syncAnswer({label: "Quesynth Factory", names, origin: "factory", state: sound(10),
    slot: 0, name: "Strings", restore: again})) page.send(m);

  assert.equal(page.window.SynthBank.restoreState().state, "failed");
  assert.equal(page.window.SynthBank.restoreState().error, "InvalidProgram");
  assert.ok(shown(banner(page)));
  assert.equal(page.$("restore-failed-text").textContent, "Could not restore Alfmeister Bank / 042. The current sound was kept.");
  assert.equal(page.window.SynthBank.selection().presetName, "Strings", "and the host's selection is the page's");
});

test("a retry answered with the patch first still reports a restore of another preset as a conflict", () => {
  // The order the host answers in: bank, patch, restore. The patch must not
  // end the retry the restore is about to be compared with.
  const {page} = missingBank();
  page.window.SynthBank.restore.retry();
  page.send({type: "patch", name: "Other", index: 3, bank: "Somewhere Else", v: 1, origin: "user"});
  page.send({type: "restore", v: 1, state: "restored", origin: "user", bank: "Somewhere Else", slot: 3, name: "Other"});
  assert.equal(page.window.SynthBank.restoreState().state, "restored");
  assert.equal(page.window.SynthBank.restoreState().conflict, true);
});

test("a patch with no selection in it leaves a failed restore standing", () => {
  const {page} = missingBank();
  page.send({type: "patch", index: null, v: 1});
  assert.equal(page.window.SynthBank.restoreState().state, "failed");
  assert.ok(shown(banner(page)));
});
