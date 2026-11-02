// A bank's name is the one the host can hold.
//
// The host keeps a bank's label in SLOT_NAME_MAX (48) bytes and cuts a longer
// one at a character boundary (src/patch/slots.odin, put_name), and every
// `bank-saved`, `bank` and `patch` it sends names the bank by that cut label.
// The page held the whole name, so its answer to Keep matched nothing: the bank
// just kept was never marked persisted, the one kept before still was, and the
// next Write into that one sent "save": true and replaced the file the person
// had just kept (REAPER 7.82: a 63-byte imported bank, kept, then replaced by
// Alfmeister Bank). Specs/2026-10-27-preset-bank-ux.md 5.3 and 13.
//
// So a name a person types is refused over 48 bytes, as a preset's is, and a
// name the page makes up -- after a file, a copy, a ' 2' -- is cut as the host
// would cut it.

import test from "node:test";
import assert from "node:assert/strict";
import {bankText, bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {patches, zip} from "./support/files.mjs";

const PAGE_FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const USER = Array.from({length: 60}, (_, i) => `Mine ${i}`);

// put_name, byte for byte: at most 48 bytes, and back to the start of the
// character the cut fell in.
const SLOT_NAME_MAX = 48;
function hostCut(text) {
  const bytes = Buffer.from(text, "utf8");
  let n = Math.min(bytes.length, SLOT_NAME_MAX);
  while (n > 0 && n < bytes.length && (bytes[n] & 0xc0) === 0x80) n--;
  return bytes.subarray(0, n).toString("utf8");
}
const bytes = text => Buffer.byteLength(text, "utf8");

// 63 bytes, as a file the reviewers imported was named.
const LONG = "Alfmeister Collected Pads and Strings Volume 2 Remastered 2026!";

const hostBank = (label, names, origin, base, kept) =>
  ({type: "bank", text: bankText(label, names, base), v: 1, origin, readOnly: false, kept});

// A version 1 host with its saved bank, Alfmeister Bank.
function hosted() {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank("Alfmeister Bank", USER, "user", 10, true));
  page.forget();
  return page;
}

// What hosts/panel answers each `bank` with "save": true: `bank-saved` naming
// the bank by slots_label, the label it stored -- cut.
function answerSaves(page) {
  for (const m of page.ofType("bank").filter(m => m.save)) {
    page.send({type: "bank-saved", v: 1, ok: true, bank: hostCut(JSON.parse(m.text).name)});
  }
  page.forget();
}

const rows = page => plain(page.window.SynthBank.list());
const persisted = page => rows(page).filter(r => r.persisted).map(r => r.label);
const at = (page, label) => rows(page).findIndex(r => r.label === label);
const saves = page => page.ofType("bank").filter(m => m.save).map(m => JSON.parse(m.text).name);

async function importLong(page, name = LONG) {
  const result = await page.window.SynthPatchFile.importBytes(zip(patches(3)), `${name}.zip`);
  page.forget();
  return result;
}

// ------------------------------------------- the reviewers' sequence, end to end

test("Keep of a bank imported under a long name makes it the only one the host keeps", async () => {
  assert.equal(bytes(LONG), 63);
  const page = hosted();
  const added = await importLong(page);
  page.window.SynthBank.select(added.index, true);
  assert.equal(page.window.SynthBank.keep(), true);
  answerSaves(page);
  assert.deepEqual(persisted(page), [hostCut(LONG)]);
});

test("after that Keep, a Write into the bank kept before is played and not saved over it", async () => {
  const page = hosted();
  const added = await importLong(page);
  page.window.SynthBank.select(added.index, true);
  page.window.SynthBank.keep();
  answerSaves(page);

  const wrote = plain(page.window.SynthBank.writePreset({bank: "Alfmeister Bank", slot: 70, name: "New"}));
  assert.equal(wrote.ok, true);
  assert.deepEqual(saves(page), [], "Alfmeister Bank is no longer the bank the host keeps");
  assert.equal(page.ofType("bank").length, 1, "but it was sent to be played");
});

test("an import named after a long file shows the label the host will hold", async () => {
  const page = hosted();
  const added = await importLong(page);
  assert.equal(added.label, hostCut(LONG));
  assert.equal(bytes(added.label), 48);
  assert.equal(rows(page)[added.index].label, hostCut(LONG));
});

test("the host announcing the kept bank after a sync leaves one row for it, not two", async () => {
  const page = hosted();
  const added = await importLong(page);
  page.window.SynthBank.select(added.index, true);
  page.window.SynthBank.keep();
  answerSaves(page);
  const before = rows(page).length;

  page.send(hostBank(hostCut(LONG), ["P000", "P001", "P002"], "user", 0, true));
  assert.equal(rows(page).length, before);
  assert.deepEqual(rows(page).filter(r => r.label.startsWith("Alfmeister Collected")).map(r => r.label),
    [hostCut(LONG)]);
  assert.deepEqual(persisted(page), [hostCut(LONG)]);
});

// ------------------------------------------------------- names a person types

const NAME_49 = "Ünïcödé Bänk " + "x".repeat(31);   // 49 bytes in 44 characters
const NAME_48 = "Ünïcödé Bänk " + "x".repeat(30);

test("New bank refuses a name over 48 bytes, says why, and makes nothing", () => {
  assert.deepEqual([bytes(NAME_49), NAME_49.length], [49, 44]);
  const page = hosted();
  const before = rows(page);
  const made = plain(page.window.SynthBank.newBank(NAME_49));
  assert.deepEqual([made.ok, made.action, made.error.code], [false, "new-bank", "InvalidName"]);
  assert.match(made.error.message, /49 bytes.*48/);
  assert.match(page.text("bank-status"), /49 bytes.*48/);
  assert.deepEqual(rows(page), before);
  assert.deepEqual(page.sent, []);
});

test("New bank takes a name of exactly 48 bytes as it is", () => {
  assert.equal(bytes(NAME_48), 48);
  const page = hosted();
  const made = plain(page.window.SynthBank.newBank(NAME_48));
  assert.deepEqual([made.ok, made.label], [true, NAME_48]);
});

test("Rename refuses a name over 48 bytes and leaves the bank as it was", () => {
  const page = hosted();
  const made = page.window.SynthBank.newBank("Scratch");
  const before = rows(page);
  const renamed = plain(page.window.SynthBank.renameBank(made.index, NAME_49));
  assert.deepEqual([renamed.ok, renamed.error.code], [false, "InvalidName"]);
  assert.match(renamed.error.message, /49 bytes.*48/);
  assert.deepEqual(rows(page), before);

  const fits = plain(page.window.SynthBank.renameBank(made.index, NAME_48));
  assert.deepEqual([fits.ok, fits.label], [true, NAME_48]);
});

// ---------------------------------------------------- names the page makes up

test("an import whose name has a character across byte 48 is cut before it, as the host cuts", async () => {
  for (const name of ["A".repeat(47) + "é and more", "B".repeat(46) + "😀 and more", "C".repeat(46) + "€uro"]) {
    const page = hosted();
    const added = await importLong(page, name);
    assert.equal(added.label, hostCut(name), name);
    assert.ok(bytes(added.label) < 48, `${name}: the character that did not fit is left out whole`);
  }
});

test("Duplicate of a 46-byte bank gets a name that fits and is not taken", () => {
  const page = hosted();
  const label = "D".repeat(46);
  const made = page.window.SynthBank.newBank(label);
  const first = plain(page.window.SynthBank.duplicateBank(made.index));
  const second = plain(page.window.SynthBank.duplicateBank(made.index));
  assert.equal(first.ok && second.ok, true);
  for (const copy of [first.label, second.label]) {
    assert.ok(bytes(copy) <= 48, copy);
    assert.equal(hostCut(copy), copy);
  }
  assert.match(first.label, /^D+ copy$/);
  assert.notEqual(first.label, second.label);
  assert.equal(new Set(rows(page).map(r => r.label)).size, rows(page).length);
});

test("two imports of the same long name are two banks the host can tell apart", async () => {
  const page = hosted();
  const one = await importLong(page);
  const two = await importLong(page);
  assert.notEqual(hostCut(one.label), hostCut(two.label));
  assert.ok(bytes(two.label) <= 48, two.label);
  assert.match(two.label, / 2$/);
});

// --------------------------------- a name that is already long, from elsewhere

// A host that does not cut -- or a bank from before this -- can still put a
// long name in the list. The host's answers name it cut, and they are matched
// by that.
test("a long-named bank a host sent is matched by the cut label the host answers with", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank("Alfmeister Bank", USER, "user", 10, true));
  page.send(hostBank(LONG, ["One", "Two"], "user", 30, false));
  page.window.SynthBank.select(at(page, LONG), true);
  page.forget();
  page.window.SynthBank.keep();
  answerSaves(page);
  assert.deepEqual(persisted(page), [LONG]);

  page.window.SynthBank.writePreset({bank: "Alfmeister Bank", slot: 70, name: "New"});
  assert.deepEqual(saves(page), []);
});

// Two banks the host would hold under one label cannot both be open: the host
// could not tell which one it was answering about. The later one takes the
// place of the first, as a bank sent again under its own name does.
test("a second host bank with the same cut label replaces the first rather than sitting beside it", () => {
  const page = bootPanel({bank: PAGE_FACTORY});
  page.send(hostBank(LONG, ["One"], "user", 30, true));
  page.send(hostBank(LONG.slice(0, 50) + " Other", ["Two"], "user", 40, true));
  const long = rows(page).filter(r => r.label.startsWith("Alfmeister Collected"));
  assert.equal(long.length, 1);
  assert.deepEqual(persisted(page), [long[0].label]);
  assert.equal(plain(page.window.SynthBank.slots())[0].name, "Two", "the later one is the one shown");
});
