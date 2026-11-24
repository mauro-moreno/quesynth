// Favorites and recently used: the person's own, kept where nothing that
// describes the instrument can read them.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 8 phase 3 and 11): they are
// UI-only. Never serialized into plugin state, never embedded in an exported
// bank, never sent to a host. ui/store.js keeps them under a key of their own;
// a build without it (every plugin) keeps them for the life of the editor. A
// favorite whose preset is gone is shown as unavailable and is never loaded and
// never swapped for something else that has the same name.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound, syncAnswer} from "./support/panel.mjs";
import {all, body, chip, feedback, label, names, open, option, options, pressed, searchBox, selected, star, type} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);
const BIG = compiledBank("Big", Array.from({length: 30}, (_, i) => `P${String(i).padStart(2, "0")}`), 10);
const browser = (extra = {}) => bootPanel({bank: FACTORY, host: null, store: true, ...extra});

const NUL = "\u0000";
const keyFor = (slot, name, bank = "Quesynth Factory", origin = "factory") => [origin, bank, String(slot), name].join(NUL);
// The panel keeps its master volume in local storage in every build; that is not ours.
const ours = page => [...page.files.keys()].filter(key => key.startsWith("quesynth."));
const prefsOf = page => JSON.parse(page.files.get("quesynth.prefs.v1"));
const show = (page, which) => {
  const on = chip(page, which);
  if (!pressed(on)) on.click();
};

// ------------------------------------------------------------------- favorites

test("a star adds a preset to Favorites and a second press takes it out", () => {
  const page = browser();
  open(page);
  assert.equal(star(page, "Brass").getAttribute("aria-pressed"), "false");
  star(page, "Brass").click();
  assert.equal(star(page, "Brass").getAttribute("aria-pressed"), "true");
  assert.equal(star(page, "Strings").getAttribute("aria-pressed"), "false");

  chip(page, "Favorites").click();
  assert.ok(pressed(chip(page, "Favorites")));
  assert.deepEqual(names(page), ["Brass"]);
  star(page, "Brass").click();
  assert.deepEqual(names(page), []);
  assert.match(body(page).querySelector(".browser-empty").textContent, /No favorites yet/);
  chip(page, "Favorites").click();
  assert.equal(names(page).length, 5);
});

test("Favorites keeps the panel's order, not the order they were starred in", () => {
  const page = browser();
  open(page);
  star(page, "Choir").click();
  star(page, "Strings").click();
  star(page, "Bells").click();
  show(page, "Favorites");
  assert.deepEqual(names(page), ["Strings", "Bells", "Choir"]);
  type(page, searchBox(page), "i");
  assert.deepEqual(names(page), ["Strings", "Choir"], "and it is searched like the rest");
});

test("a favorite from anywhere is found under its own source filter", () => {
  const page = browser();
  page.window.SynthBank.importBank("Elsewhere", [{n: "Zither", v: sound(1)}]);
  open(page);
  star(page, "Zither").click();
  star(page, "Brass").click();
  show(page, "Favorites");
  show(page, "Imported");
  assert.deepEqual(names(page), ["Zither"]);
});

test("the star is not offered for the sound that has no place to come back to", () => {
  const page = browser();
  page.window.SynthPatch.apply(sound(88), "Loose");
  open(page);
  assert.ok(option(page, "Loose"));
  assert.equal(star(page, "Loose"), null);
  assert.ok(star(page, "Brass"));
});

// ---------------------------------------------------------------------- recent

test("Recent is the presets played, most recent first, and one played again moves to the front", () => {
  const page = browser();
  open(page);
  const bank = page.window.SynthBank;
  for (const slot of [1, 2, 3]) bank.loadPreset({bank: 0, slot});
  show(page, "Recent");
  assert.deepEqual(names(page), ["Bells", "Brass", "Strings"]);

  bank.loadPreset({bank: 0, slot: 1});
  assert.deepEqual(names(page), ["Strings", "Bells", "Brass"], "no repeats, and the one just played is first");
});

test("every way a person loads a preset is recorded: a click, the strip's NEXT, and a call to loadPreset", () => {
  const page = browser();
  open(page);
  show(page, "Recent");
  assert.deepEqual(names(page), []);
  assert.match(body(page).querySelector(".browser-empty").textContent, /Nothing has been played from here yet/);

  page.document.querySelector('.bank-step[data-step="1"]').click();      // Strings
  assert.deepEqual(names(page), ["Strings"]);
  page.window.SynthBank.loadPreset({bank: "Quesynth Factory", slot: 3}); // Bells
  assert.deepEqual(names(page), ["Bells", "Strings"]);
  chip(page, "Recent").click();
  option(page, "Choir").click();
  show(page, "Recent");
  assert.deepEqual(names(page), ["Choir", "Bells", "Strings"]);
});

test("what is not a preset is not remembered: a refused load, an empty slot, the factory Init, a file", () => {
  const page = browser();
  const bank = page.window.SynthBank;
  bank.loadPreset({bank: 0, slot: 4});     // refused: empty
  bank.loadPreset({bank: 9, slot: 0});     // refused: no such bank
  bank.load(4);                            // an empty slot loads as Init, which is not a preset
  page.window.SynthPatch.apply(sound(3), "Loose");
  page.window.SynthBank.restore.loadFactoryInit();
  open(page);
  show(page, "Recent");
  assert.deepEqual(names(page), []);
});

test("Recent holds twenty, and the twenty-first pushes out the oldest", () => {
  const page = bootPanel({bank: BIG, host: null, store: true});
  const bank = page.window.SynthBank;
  for (let slot = 0; slot < 25; slot++) bank.loadPreset({bank: 0, slot});
  open(page);
  show(page, "Recent");
  const expected = Array.from({length: 20}, (_, i) => `P${String(24 - i).padStart(2, "0")}`);
  assert.deepEqual(names(page), expected);
  assert.equal(prefsOf(page).recent.length, 20);
  assert.equal(prefsOf(page).recent[0], keyFor(24, "P24", "Big"));
  assert.equal(prefsOf(page).recent[19], keyFor(5, "P05", "Big"));
});

test("Recent and Favorites together show the recent ones that are favorites, in the recent order", () => {
  const page = browser();
  const bank = page.window.SynthBank;
  open(page);
  star(page, "Strings").click();
  star(page, "Choir").click();
  for (const slot of [1, 2, 5, 3]) bank.loadPreset({bank: 0, slot});
  show(page, "Recent");
  show(page, "Favorites");
  assert.deepEqual(names(page), ["Choir", "Strings"]);
  chip(page, "Favorites").click();
  assert.deepEqual(names(page), ["Bells", "Choir", "Brass", "Strings"]);
});

test("an archive preset is recorded when the host has answered, and not when it was asked for", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad", "Bass"]});
  open(page);
  option(page, "Bass").click();
  show(page, "Recent");
  assert.deepEqual(names(page), [], "still loading");
  page.send({type: "patch", name: "Bass", index: null, bank: "a.zip", source: "archive", archive: {bank: 0, patch: 1}});
  assert.deepEqual(names(page), ["Bass"]);

  // A program change somebody else made is not the person's own choice.
  page.send({type: "patch", name: "Pad", index: null, bank: "a.zip", source: "archive", archive: {bank: 0, patch: 0}});
  assert.deepEqual(names(page), ["Bass"]);
});

// ------------------------------------------------------------- what is not there

test("a favorite whose preset has been rewritten is shown as unavailable, and nothing is loaded in its place", () => {
  const page = browser();
  const bank = page.window.SynthBank;
  open(page);
  star(page, "Brass").click();
  show(page, "Favorites");
  assert.deepEqual(selected(page), []);

  // The slot is now somebody else's sound, and another slot holds a copy of Brass.
  bank.loadPreset({bank: 0, slot: 1});
  bank.writePreset({bank: 0, slot: 2, name: "Horn", overwrite: true});
  bank.copySlot({bank: 0, slot: 3}, {bank: 0, slot: 5}, {overwrite: true});
  bank.writePreset({bank: 0, slot: 3, name: "Brass", overwrite: true});
  chip(page, "Favorites").click();
  chip(page, "Favorites").click();
  assert.deepEqual(names(page), ["Brass"], "the favorite is still listed, once");

  const row = option(page, "Brass");
  assert.equal(row.getAttribute("aria-disabled"), "true");
  assert.ok(row.classList.contains("unavailable"));
  assert.match(row.textContent, /Unavailable/);
  assert.equal(row.querySelector(".browser-result-num").textContent, "002", "it says where it was");
  assert.equal(star(page, "Brass").getAttribute("aria-pressed"), "true", "and can be un-starred");

  const before = plain(bank.selection());
  const values = page.values();
  row.click();
  assert.deepEqual(plain(bank.selection()), before, "a click loads nothing");
  assert.deepEqual(page.values(), values);
  assert.match(label(feedback(page)), /Brass is not available now, so it was not loaded/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");

  star(page, "Brass").click();
  assert.deepEqual(names(page), [], "un-starred, it is gone");
});

test("an unavailable favorite is not loadable by the keyboard either, and the same name elsewhere is not it", () => {
  const page = browser();
  page.window.SynthBank.importBank("Other", [{n: "Brass", v: sound(9)}]);
  open(page);
  star(page, "Brass").click();    // the first Brass, in the factory bank
  page.window.SynthBank.writePreset({bank: 0, slot: 2, name: "Horn", overwrite: true});
  show(page, "Favorites");
  const rows = options(page);
  assert.equal(rows.length, 1, "the other bank's Brass is not a favorite");
  assert.equal(rows[0].getAttribute("aria-disabled"), "true");
  assert.match(rows[0].querySelector(".browser-result-meta").textContent, /Factory \/ Quesynth Factory/);
});

test("a recent whose bank was closed stays in the list as unavailable, in its place", () => {
  const page = browser();
  const bank = page.window.SynthBank;
  bank.importBank("Short Lived", [{n: "Ephemeral", v: sound(4)}]);
  bank.loadPreset({bank: "Short Lived", slot: 0});
  bank.loadPreset({bank: 0, slot: 1});
  const index = plain(bank.list()).findIndex(b => b.label === "Short Lived");
  assert.equal(bank.removeBank(index).ok, true);
  open(page);
  show(page, "Recent");
  assert.deepEqual(names(page), ["Strings", "Ephemeral"]);
  assert.equal(option(page, "Ephemeral").getAttribute("aria-disabled"), "true");
  assert.equal(option(page, "Strings").getAttribute("aria-disabled"), null);
});

// ---------------------------------------------------------------------- keeping

test("with store.js they are kept under their own key, and read back when the browser is next opened", () => {
  const page = browser();
  open(page);
  star(page, "Brass").click();
  page.window.SynthBank.loadPreset({bank: 0, slot: 1});
  assert.deepEqual(prefsOf(page), {
    favorites: [keyFor(2, "Brass")],
    recent: [keyFor(1, "Strings")],
  });

  const next = browser({before: w => w.localStorage.setItem("quesynth.prefs.v1", JSON.stringify({
    favorites: [keyFor(3, "Bells")], recent: [keyFor(5, "Choir"), keyFor(1, "Strings")],
  }))});
  open(next);
  show(next, "Favorites");
  assert.deepEqual(names(next), ["Bells"]);
  chip(next, "Favorites").click();
  show(next, "Recent");
  assert.deepEqual(names(next), ["Choir", "Strings"], "most recent first, as it was stored");
});

test("what store.js is given is cleaned: text only, no repeats, twenty recent at most; and garbage is forgotten", () => {
  const page = browser();
  const store = page.window.SynthStore;
  assert.deepEqual(plain(store.prefs()), {favorites: [], recent: []});

  const many = Array.from({length: 30}, (_, i) => "k" + i);
  store.setPrefs({favorites: ["a", "a", 7, "", null, "b"], recent: many});
  assert.deepEqual(plain(store.prefs()).favorites, ["a", "b"]);
  assert.deepEqual(plain(store.prefs()).recent, many.slice(0, 20));
  assert.deepEqual(prefsOf(page).favorites, ["a", "b"]);

  const broken = browser({before: w => w.localStorage.setItem("quesynth.prefs.v1", "{not json")});
  assert.deepEqual(plain(broken.window.SynthStore.prefs()), {favorites: [], recent: []});
  const odd = browser({before: w => w.localStorage.setItem("quesynth.prefs.v1", JSON.stringify({favorites: "no", recent: {}}))});
  assert.deepEqual(plain(odd.window.SynthStore.prefs()), {favorites: [], recent: []});
});

test("forgetting the sound does not forget the favorites, and neither is in the other's key", () => {
  const page = browser();
  open(page);
  star(page, "Brass").click();
  page.window.SynthStore.flush();
  assert.ok(page.files.has("quesynth.state.v1"));
  assert.ok(page.files.has("quesynth.prefs.v1"));
  page.window.SynthStore.forget();
  assert.ok(!page.files.has("quesynth.state.v1"));
  assert.deepEqual(prefsOf(page).favorites, [keyFor(2, "Brass")]);
});

test("without store.js they last as long as the editor does, and nothing is written anywhere", () => {
  const page = bootPanel({bank: FACTORY});
  assert.equal(page.window.SynthStore, undefined);
  open(page);
  star(page, "Brass").click();
  page.window.SynthBank.loadPreset({bank: 0, slot: 1});
  page.window.SynthBrowser.open();
  show(page, "Favorites");
  assert.ok(names(page).includes("Brass"), "closing and opening the browser does not lose them");
  chip(page, "Favorites").click();
  show(page, "Recent");
  assert.deepEqual(names(page), ["Strings"]);
  assert.deepEqual(ours(page), [], "nothing of ours was written to local storage");
});

// ---------------------------------------------------------------------- leaking

// Everything a favorite or a recent could have got into, said before and after.
function observe(page) {
  return {
    bankText: page.window.SynthPatchFile.bankText(0),
    state: (page.window.SynthStore ? (page.window.SynthStore.flush(), page.files.get("quesynth.state.v1")) : null) || null,
    sent: JSON.stringify(page.sent),
  };
}

test("favorites and recents never reach the bank, the stored state or an export", () => {
  const page = browser();
  open(page);
  const before = observe(page);
  star(page, "Brass").click();
  star(page, "Choir").click();
  for (const slot of [3, 5, 1]) page.window.SynthBank.loadPreset({bank: 0, slot});
  page.window.SynthBank.loadPreset({bank: 0, slot: 0});
  const after = observe(page);

  assert.notEqual(prefsOf(page).favorites.length, 0, "they are in their own key");
  assert.equal(after.bankText, before.bankText, "the bank is what it was");
  const doc = JSON.parse(after.bankText);
  assert.deepEqual(Object.keys(doc), ["format", "version", "name", "patches"]);
  for (const text of [after.bankText, after.state]) {
    assert.doesNotMatch(text, /favorit|recent/i);
    assert.ok(!text.includes(keyFor(2, "Brass")));
  }
  assert.deepEqual(Object.keys(JSON.parse(after.state)).sort(), ["current", "factory", "midi", "v"]);
});

test("favorites and recents never reach a host: no message carries them, and starring sends nothing at all", () => {
  const page = bootPanel({bank: FACTORY});
  for (const m of syncAnswer({label: "My Bank", names: ["Alpha", "Bravo", null, "Delta"], origin: "user", state: sound(10), slot: 0, name: "Alpha"})) page.send(m);
  page.forget();
  open(page);
  star(page, "Alpha").click();
  star(page, "Delta").click();
  assert.deepEqual(page.sent, [], "starring is not a message");

  option(page, "Bravo").click();
  option(page, "Delta").click();
  const text = JSON.stringify(page.sent);
  assert.ok(page.sent.length > 0, "loading a preset does tell the host");
  assert.doesNotMatch(text, /favorit|recent/i);
  for (const message of page.sent) {
    assert.ok(["state", "select", "bank"].includes(message.type), message.type);
    assert.ok(!JSON.stringify(message).includes(NUL), "a preset key is nobody's business but the browser's");
  }
  assert.deepEqual(ours(page), []);
  assert.doesNotMatch(page.window.SynthPatchFile.bankText(1), /favorit|recent/i);
});
