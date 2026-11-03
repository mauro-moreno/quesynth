// Opening and exporting banks and patches: what a file may do to the panel, and
// what the panel may put in one.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 5.4 and 5.5): an import adds
// a validated bank and replaces nothing; an invalid file leaves the banks, the
// selection and the sound exactly as they were; an export keeps every slot where
// it was and never presents part of a bank as the whole of it.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, bankText, compiledBank, plain, sound, syncAnswer, PARAM_NAMES} from "./support/panel.mjs";
import {FakeFileReader, folder, patches, sy1, zip} from "./support/files.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);
const encoder = new TextEncoder();
const text = value => encoder.encode(typeof value === "string" ? value : JSON.stringify(value));

// A page with a plugin host that has a selection, so that "nothing changed"
// has something to mean, and with what a browser gives a download or a file
// picker standing in for them.
function app({slot = 1, host = "generic"} = {}) {
  const page = bootPanel({bank: FACTORY, host});
  const downloads = [];
  page.downloads = downloads;
  page.window.Blob = Blob;
  page.window.URL = {createObjectURL: blob => { downloads.push({blob}); return `blob:${downloads.length}`; }, revokeObjectURL() {}};
  page.window.FileReader = FakeFileReader;
  const append = page.document.body.appendChild.bind(page.document.body);
  page.document.body.appendChild = node => {
    if (node.localName === "a" && downloads.length) downloads.at(-1).name = node.download;
    return append(node);
  };
  if (slot !== null) {
    for (const m of syncAnswer({label: "My Bank", names: ["Alpha", "Bravo", null, "Delta"], origin: "user",
      state: sound(10 + slot), slot, name: ["Alpha", "Bravo", null, "Delta"][slot]})) page.send(m);
  }
  page.forget();
  return page;
}

// Everything an import must leave alone, as a value.
const world = page => plain({
  banks: page.window.SynthBank.list().map(b => [b.label, b.origin, b.used]),
  current: page.window.SynthBank.current(),
  selection: page.window.SynthBank.selection(),
  status: page.window.SynthBank.status(),
  values: page.values(),
  strip: [page.text("bank-patch"), page.text("bank-name"), page.text("bank-origin")],
  sent: page.sent,
});

const code = async promise => { try { await promise; return "ok"; } catch (err) { return err.code || `(no code) ${err.message}`; } };
const slotsOf = (page, label) => {
  const was = page.window.SynthBank.current();
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === label);
  page.window.SynthBank.select(at, true);
  const out = plain(page.window.SynthBank.slots());
  page.window.SynthBank.select(was, true);
  return out;
};
const exported = async page => {
  const last = page.downloads.at(-1);
  return {name: last.name, text: await last.blob.text()};
};

// ----------------------------------------------------------- what an import is

test("an import adds a bank as imported and changes nothing else: not the bank in view, not the sound, not the host", async () => {
  const page = app();
  const before = world(page);
  const result = await page.window.SynthPatchFile.importBytes(text({format: "quesynth.bank", version: 1, name: "Third Party",
    patches: [{name: "One", parameters: {}}, null, {name: "Three", parameters: {[PARAM_NAMES[19]]: 33}}]}), "third.json");

  assert.deepEqual([result.kind, result.label, result.count, result.leftOut, result.message], ["bank", "Third Party", 2, 0, "2 patches"]);
  const after = world(page);
  assert.deepEqual(after.banks, [...before.banks, ["Third Party", "imported", 2]]);
  assert.deepEqual({...after, banks: null}, {...before, banks: null}, "the selection, the sound, the strip and the host are as they were");
  assert.deepEqual(after.sent, [], "no state, no select, no bank");
  assert.equal(page.ofType("state").length, 0);
});

test("the legacy entry points answer with the line a person reads, and add the same bank", async () => {
  const page = app();
  assert.equal(page.window.SynthPatchFile.load(JSON.stringify({format: "quesynth.bank", version: 1, name: "A",
    patches: [{name: "One", parameters: {}}]})), "1 patches");
  assert.equal(await page.window.SynthPatchFile.loadBytes(zip([...patches(3)]), "bank.zip"), "3 patches");
  assert.deepEqual(plain(page.window.SynthBank.list()).map(b => b.label), ["Quesynth Factory", "My Bank", "A", "bank"]);
});

test("a bank named like one that is open is added beside it, never over it", async () => {
  const page = app();
  const doc = name => text({format: "quesynth.bank", version: 1, name, patches: [{name: "One", parameters: {}}]});
  await page.window.SynthPatchFile.importBytes(doc("Same"), "a.json");
  await page.window.SynthPatchFile.importBytes(doc("Same"), "b.json");
  await page.window.SynthPatchFile.importBytes(doc("My Bank"), "c.json");
  await page.window.SynthPatchFile.importBytes(doc("Same"), "d.json");
  assert.deepEqual(plain(page.window.SynthBank.list()).map(b => [b.label, b.origin]), [
    ["Quesynth Factory", "factory"], ["My Bank", "user"], ["Same", "imported"], ["Same 2", "imported"],
    ["My Bank 2", "imported"], ["Same 3", "imported"],
  ]);
  assert.equal(plain(page.window.SynthBank.selection()).bank, "My Bank", "and the host's bank was not touched");
});

test("a patch file is not a bank import: it becomes the sound, as a file, and the host is told", async () => {
  const page = app();
  const result = await page.window.SynthPatchFile.importBytes(sy1("Single", 44), "single.sy1");
  assert.deepEqual([result.kind, result.name], ["patch", "Single"]);
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "file", source: "file", bank: "", slot: null, presetName: "Single", archive: null});
  assert.equal(page.values()[19], 44);
  assert.deepEqual(plain(page.sent.map(m => m.type)), ["state", "select"]);
  assert.equal(page.window.SynthBank.list().length, 2, "no bank was added");

  const json = await page.window.SynthPatchFile.importBytes(text({format: "quesynth.patch", version: 1, name: "As JSON",
    parameters: {[PARAM_NAMES[19]]: 55}}), "x.json");
  assert.equal(json.name, "As JSON");
  assert.equal(page.values()[19], 55);
  assert.equal(page.window.SynthBank.selection().origin, "file");
});

// ---------------------------------------------------------------- bad files

const GOOD = {name: "G", parameters: {}};
const bankDoc = patchList => ({format: "quesynth.bank", version: 1, name: "Bad", patches: patchList});
const CASES = [
  ["not JSON at all", () => text("{ nope"), "InvalidBank", /JSON|position|Expected/i],
  ["JSON with no format", () => text({hello: 1}), "UnsupportedFormat", /not a quesynth\.patch file/],
  ["another format", () => text({format: "something.else", version: 1}), "UnsupportedFormat", /not a quesynth\.patch file/],
  ["a newer version of the bank format", () => text({...bankDoc([GOOD]), version: 2}), "UnsupportedFormat", /written by a newer version \(2\)/],
  ["a newer version of the patch format", () => text({format: "quesynth.patch", version: 9, parameters: {}}), "UnsupportedFormat", /newer version \(9\)/],
  ["a bank with no patches", () => text(bankDoc([])), "InvalidBank", /the bank has no patches/],
  ["a bank whose patches are not a list", () => text({...bankDoc(null)}), "InvalidBank", /the bank has no patches/],
  ["an unknown parameter in the third patch", () => text(bankDoc([GOOD, GOOD, {name: "X", parameters: {nope: 1}}])), "InvalidBank", /unknown parameter: nope/],
  ["an unknown parameter in a patch file", () => text({format: "quesynth.patch", version: 1, parameters: {nope: 1}}), "InvalidBank", /unknown parameter: nope/],
  ["more than a bank holds", () => text(bankDoc(Array.from({length: 129}, () => GOOD))), "TooManySlots", /129 patches and a bank holds 128/],
  ["more than a bank holds, the extra ones empty", () => text(bankDoc([...Array.from({length: 128}, () => GOOD), null])), "TooManySlots", /129/],
  ["text that is no patch", () => text("hello there"), "UnsupportedFormat", /not a \.sy1 file/],
  ["a patch with a malformed line", () => text("Synth1 Broken\nver=107\n19,twelve\n"), "InvalidBank", /malformed line/],
  ["a patch with a parameter out of range", () => text("Synth1 Broken\nver=107\n500,1\n"), "InvalidBank", /out of range/],
  ["a zip that is not one", () => Uint8Array.from([0x50, 0x4b, 3, 4, 1, 2, 3]), "InvalidBank", /not a zip file/],
  ["a zip with nothing in it that is a patch", () => zip([{name: "readme.txt", bytes: text("hi")}]), "InvalidBank", /no \.sy1 patches in the archive/],
  ["a zip with one broken patch among good ones", () => zip([...patches(3), {name: "Broken.sy1", bytes: text("Synth1 Broken\n19,x\n")}, ...patches(2, {prefix: "Q"})]),
    "InvalidBank", /malformed line/],
];

for (const [what, make, expected, message] of CASES) {
  test(`${what} is refused as ${expected}, with its own message, and leaves everything as it was`, async () => {
    const page = app();
    page.window.SynthPatch.setParam(19, 0.5);
    page.forget();
    const before = world(page);
    const error = await page.window.SynthPatchFile.importBytes(make(), "file").then(() => null, err => err);
    assert.ok(error, "it was refused");
    assert.equal(error.code, expected);
    assert.match(error.message, message);
    assert.deepEqual(world(page), before);
  });
}

test("a file that cannot be read is ReadFailed, in a folder or from the picker, and changes nothing", async () => {
  const page = app();
  const before = world(page);
  const files = folder("Bank", ["a.sy1", "b.sy1", "c.sy1"]);
  files[1].unreadable = true;
  const error = await page.window.SynthPatchFile.importFolder(files).then(() => null, err => err);
  assert.equal(error.code, "ReadFailed");
  assert.equal(error.message, "could not read b.sy1");
  assert.deepEqual(world(page), before, "the two it could read were not added without the third");

  const result = await new Promise(resolve => {
    page.window.SynthPatchFile.pick((err, what) => resolve({err, what}));
    const input = page.document.querySelector('input[type="file"]');
    input.files = [{name: "x.sy1", bytes: sy1("X", 3), unreadable: true}];
    input.onchange();
  });
  assert.equal(result.err.code, "ReadFailed");
  assert.equal(result.err.message, "could not read the file");
  assert.match(page.text("bank-status"), /could not read the file/);
});

test("a folder with nothing in it, or one broken patch, is refused whole", async () => {
  const page = app();
  const before = world(page);
  assert.equal(await code(page.window.SynthPatchFile.importFolder(folder("Empty", ["notes.txt"]))), "InvalidBank");
  const broken = folder("Bank", ["a.sy1", "b.sy1"]);
  broken[1].bytes = text("Synth1 Broken\n19,x\n");
  assert.equal(await code(page.window.SynthPatchFile.importFolder(broken)), "InvalidBank");
  assert.deepEqual(world(page), before);
});

test("while the host's shared archive is open, a bank cannot be opened in the page, by zip or by JSON", async () => {
  const page = app();
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  page.forget();
  const before = world(page);
  assert.equal(await code(page.window.SynthPatchFile.importBytes(zip(patches(2)), "x.zip")), "UnsupportedFormat");
  assert.equal(await code(page.window.SynthPatchFile.importBytes(text(bankDoc([GOOD])), "x.json")), "UnsupportedFormat");
  assert.deepEqual(world(page), before);
  await assert.rejects(page.window.SynthPatchFile.loadBytes(zip(patches(2)), "x.zip"), /Archive field in Patches/);
});

test("the picker says what happened in the strip, whichever way it went, and hands the error on with its code", async () => {
  const page = app();
  const pick = file => new Promise(resolve => {
    page.window.SynthPatchFile.pick((err, what) => resolve({err, what}));
    const input = page.document.querySelector('input[type="file"]');
    input.files = [file];
    input.onchange();
  });
  const good = await pick({name: "ok.zip", bytes: zip(patches(130))});
  assert.equal(good.what, "128 patches (2 left out)");
  assert.equal(page.text("bank-status"), "Opened 128 patches (2 left out).");
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "warn", "a bank that did not fit is a warning, not a success");
  const bad = await pick({name: "bad.json", bytes: text(bankDoc([]))});
  assert.equal(bad.err.code, "InvalidBank");
  assert.equal(page.text("bank-status"), "the bank has no patches");
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "error");
});

// ----------------------------------------------------------------- order, overflow

test("a zip's patches keep the order the archive lists them in, 128 of them, and the rest are counted", async () => {
  const page = app();
  const entries = patches(130).reverse();
  const result = await page.window.SynthPatchFile.importBytes(zip(entries), "big.zip");
  assert.deepEqual([result.label, result.count, result.leftOut, result.message], ["big", 128, 2, "128 patches (2 left out)"]);
  const slots = slotsOf(page, "big");
  assert.equal(slots.length, 128);
  assert.deepEqual(slots.slice(0, 3).map(s => s.name), ["P129", "P128", "P127"], "archive order, not alphabetical");
  assert.equal(slots[127].name, "P002", "and the first 128 of it");
  assert.equal(slots.includes(null), false);
});

test("exactly 128 is a full bank with nothing left out", async () => {
  const page = app();
  const result = await page.window.SynthPatchFile.importBytes(zip(patches(128)), "full.zip");
  assert.deepEqual([result.count, result.leftOut, result.message], [128, 0, "128 patches"]);
  const json = await page.window.SynthPatchFile.importBytes(text(bankDoc(Array.from({length: 128}, (_, i) => ({name: `J${i}`, parameters: {}})))), "j.json");
  assert.equal(json.count, 128);
});

test("a folder is ordered by its file names as numbers, the same whichever way the browser lists them", async () => {
  const names = ["P10.sy1", "P2.sy1", "p1.sy1", "P1.sy1", "P20.sy1", "readme.txt", "A.sy1", "a.sy1"];
  const first = app(), second = app();
  const a = await first.window.SynthPatchFile.importFolder(folder("My Folder", names));
  await second.window.SynthPatchFile.importFolder(folder("My Folder", [...names].reverse()));
  assert.equal(a.label, "My Folder");
  const order = slotsOf(first, "My Folder").filter(Boolean).map(s => s.name);
  assert.deepEqual(order, ["A", "a", "P1", "p1", "P2", "P10", "P20"], "numeric, case-insensitive, with a tie broken the same way each time");
  assert.deepEqual(slotsOf(second, "My Folder").filter(Boolean).map(s => s.name), order);
});

test("a folder is named after its own directory however the files were listed", async () => {
  const page = app();
  const files = [
    {name: "b.sy1", webkitRelativePath: "Root/Z Sub/b.sy1", bytes: sy1("b", 1)},
    {name: "a.sy1", webkitRelativePath: "Root/A Sub/a.sy1", bytes: sy1("a", 1)},
  ];
  const one = await page.window.SynthPatchFile.importFolder(files);
  const two = await app().window.SynthPatchFile.importFolder([...files].reverse());
  assert.equal(one.label, "A Sub");
  assert.equal(two.label, "A Sub");
});

test("a folder with more than 128 patches keeps the first 128 in order and says how many it left out", async () => {
  const page = app();
  const files = patches(131).map(p => ({name: p.name, webkitRelativePath: `Big/${p.name}`, bytes: p.bytes}));
  const result = await page.window.SynthPatchFile.importFolder(files.reverse());
  assert.deepEqual([result.label, result.count, result.leftOut, result.message], ["Big", 128, 3, "128 patches (3 left out)"]);
  const slots = slotsOf(page, "Big");
  assert.equal(slots[0].name, "P000");
  assert.equal(slots[127].name, "P127");
  assert.equal(await page.window.SynthPatchFile.loadFolder(files), "128 patches (3 left out)");
});

// ------------------------------------------------------------------- lazy banks

function nested({inner = 3, over = 0} = {}) {
  const banks = Array.from({length: inner}, (_, i) => ({
    name: `bank${String.fromCharCode(67 - i)}.zip`,
    bytes: zip(patches(i === 0 ? 128 + over : 5, {prefix: String.fromCharCode(67 - i)})),
  }));
  return zip(banks);
}

test("a zip of zips is listed and not opened: no inner archive is read until somebody picks one", async () => {
  const page = app();
  let opened = 0;
  const readZip = page.window.SynthSy1.readZip;
  page.window.SynthSy1.readZip = bytes => { opened++; return readZip(bytes); };
  const result = await page.window.SynthPatchFile.importBytes(nested(), "collection.zip");
  assert.deepEqual([result.kind, result.count, result.message], ["banks", 3, "3 banks"]);
  const readForTheOuterFile = opened;

  const rows = plain(page.window.SynthBank.list()).slice(2);
  assert.deepEqual(rows.map(r => [r.label, r.origin, r.used, r.kind]), [
    ["bankA", "imported", null, "bank"], ["bankB", "imported", null, "bank"], ["bankC", "imported", null, "bank"],
  ], "sorted by name, each with no count because none has been read");
  page.window.SynthBank.presets();
  page.window.SynthBank.list();
  assert.equal(page.window.SynthBank.writePreset({bank: "bankA", slot: 0, name: "x"}).ok, false);
  assert.equal(opened, readForTheOuterFile, "listing, naming and refusing a write read nothing");
  assert.equal(plain(page.window.SynthBank.presets()).some(p => /^bank/.test(p.bank)), false, "and no names are claimed for them");

  // Picking one reads that one.
  await new Promise(resolve => page.window.SynthBank.select(3, true, (err, state) => { if (state !== "loading") resolve(); }));
  assert.equal(opened, readForTheOuterFile + 1);
  assert.equal(page.window.SynthBank.bankInfo(3).used, 5);
});

test("a bank opened from a zip of zips that held more than 128 says how many it left out", async () => {
  const page = app();
  await page.window.SynthPatchFile.importBytes(nested({over: 4}), "collection.zip");
  assert.deepEqual(plain(page.window.SynthBank.list()).slice(2).map(b => b.label), ["bankA", "bankB", "bankC"]);
  await new Promise(resolve => page.window.SynthBank.select(4, true, (err, state) => { if (state !== "loading") resolve(); }));
  const info = plain(page.window.SynthBank.bankInfo(4));
  assert.deepEqual([info.label, info.used, info.leftOut], ["bankC", 128, 4]);
  assert.equal(plain(page.window.SynthBank.bankInfo(2)).leftOut, 0, "a bank that fit says nothing");
});

test("importing a collection twice lists its banks twice, under names that tell them apart", async () => {
  const page = app();
  await page.window.SynthPatchFile.importBytes(nested({inner: 2}), "c.zip");
  await page.window.SynthPatchFile.importBytes(nested({inner: 2}), "c.zip");
  assert.deepEqual(plain(page.window.SynthBank.list()).slice(2).map(b => b.label), ["bankB", "bankC", "bankB 2", "bankC 2"]);
});

// ------------------------------------------------------------------ export

test("exporting a bank and importing it again gives the same slots in the same places, interior empties included", async () => {
  const page = app({host: null, slot: null});
  const made = page.window.SynthBank.newBank("Round Trip");
  for (const [slot, name, cut] of [[3, "Three", 0.1], [40, "Forty", 0.6], [41, "Forty One", 0.9]]) {
    page.window.SynthPatch.setParam(19, cut);
    assert.equal(page.window.SynthBank.writePreset({bank: made.index, slot, name}).ok, true);
  }
  const at = page.window.SynthBank.current();
  const result = page.window.SynthPatchFile.saveBank(at);
  assert.deepEqual([result.ok, result.count, result.unsaved], [true, 3, false]);
  const one = await exported(page);
  assert.equal(one.name, "Round Trip.json");

  const doc = JSON.parse(one.text);
  assert.deepEqual(doc.patches.map((p, i) => p && i), [null, null, null, 3, ...Array(36).fill(null), 40, 41], "null where nothing is, up to the last sound");
  assert.equal(doc.patches.length, 42, "trailing empties are the only thing dropped");

  const back = await page.window.SynthPatchFile.importBytes(encoder.encode(one.text), "Round Trip.json");
  assert.equal(back.label, "Round Trip 2");
  const was = slotsOf(page, "Round Trip");
  const now = slotsOf(page, "Round Trip 2");
  assert.deepEqual(now, was, "every slot where it was, every name as it was");
  assert.deepEqual(now.map((s, i) => s && i).filter(i => i !== null), [3, 40, 41]);

  // And once more: the same bytes, apart from the bank's own name.
  const again = page.window.SynthPatchFile.saveBank(plain(page.window.SynthBank.list()).findIndex(b => b.label === "Round Trip 2"));
  assert.equal(again.ok, true);
  const two = JSON.parse((await exported(page)).text);
  assert.deepEqual({...two, name: doc.name}, doc, "the exported file of an imported file is the file");
});

test("a bank's values survive the round trip exactly, not just its names", async () => {
  const page = app({host: null, slot: null});
  const made = page.window.SynthBank.newBank("Values");
  page.window.SynthPatch.apply(sound(77), "Seventy Seven");
  page.window.SynthBank.writePreset({bank: made.index, slot: 5, name: "Seventy Seven"});
  page.window.SynthPatchFile.saveBank(made.index);
  await page.window.SynthPatchFile.importBytes(encoder.encode((await exported(page)).text), "v.json");
  page.window.SynthBank.loadPreset({bank: "Values 2", slot: 5});
  assert.deepEqual(page.values(), sound(77));
});

test("exporting stores what is stored: an edit in progress is not substituted into its slot, and the export says so", async () => {
  const page = app({slot: 1});
  page.window.SynthPatch.setParam(19, 0.5);
  assert.equal(page.window.SynthBank.status(), "dirty");
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank");
  const result = page.window.SynthPatchFile.saveBank(at);
  assert.deepEqual([result.ok, result.unsaved, result.warning], [true, true, true]);
  assert.equal(result.message, "Exported My Bank (3 patches). Unsaved changes to Bravo were not included.");
  assert.equal(page.text("bank-status"), result.message);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "warn");
  const doc = JSON.parse((await exported(page)).text);
  assert.equal(doc.patches[1].parameters[PARAM_NAMES[19]], 11, "slot 1 as it was stored");
  assert.equal(page.window.SynthBank.status(), "dirty", "and still unsaved afterwards");
  assert.equal(page.window.SynthPatchFile.bankText(at).includes('"filter cutoff": 64'), false);
});

test("an export of an unedited sound has nothing to warn about", async () => {
  const page = app({slot: 1});
  const result = page.window.SynthPatchFile.saveBank();
  assert.equal(result.message, "Exported My Bank (3 patches).");
  assert.equal(result.unsaved, false);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "ok");
});

test("exporting a bank an import cut at 128 says so, as a warning, and does not present it as the whole", async () => {
  const page = app();
  await page.window.SynthPatchFile.importBytes(zip(patches(130)), "big.zip");
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === "big");
  assert.equal(plain(page.window.SynthBank.bankInfo(at)).leftOut, 2, "the omission is kept on the bank, not only said once at import");

  const result = page.window.SynthPatchFile.saveBank(at);
  assert.deepEqual([result.ok, result.count, result.leftOut, result.warning], [true, 128, 2, true]);
  assert.equal(result.message, "Exported big (128 patches). 2 patches of the original were left out when it was opened.");
  assert.equal(page.text("bank-status"), result.message);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "warn");
  assert.equal(JSON.parse((await exported(page)).text).patches.length, 128, "and the file holds what the bank holds");
});

test("a folder cut at 128 warns on export, one patch short in the singular, and a bank that fit does not", async () => {
  const page = app();
  const files = n => patches(n).map(p => ({name: p.name, webkitRelativePath: `Dir/${p.name}`, bytes: p.bytes}));
  await page.window.SynthPatchFile.importFolder(files(129));
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === "Dir");
  const cut = page.window.SynthPatchFile.saveBank(at);
  assert.equal(cut.message, "Exported Dir (128 patches). 1 patch of the original was left out when it was opened.");
  assert.equal(cut.warning, true);

  await page.window.SynthPatchFile.importFolder(files(128));
  const whole = page.window.SynthPatchFile.saveBank(plain(page.window.SynthBank.list()).findIndex(b => b.label === "Dir 2"));
  assert.equal(whole.message, "Exported Dir 2 (128 patches).");
  assert.deepEqual([whole.warning, whole.leftOut], [false, 0]);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "ok");
});

test("a bank read out of a zip of zips that held more than 128 warns on export too", async () => {
  const page = app();
  await page.window.SynthPatchFile.importBytes(nested({over: 4}), "collection.zip");
  await new Promise(resolve => page.window.SynthBank.select(4, true, (err, state) => { if (state !== "loading") resolve(); }));
  const result = page.window.SynthPatchFile.saveBank(4);
  assert.equal(result.message, "Exported bankC (128 patches). 4 patches of the original were left out when it was opened.");
  assert.equal(result.warning, true);
});

test("a bank that has not been opened is not exported as an empty one, and neither is a row of the archive", () => {
  const page = app();
  page.window.SynthBank.addLazy("Unopened", () => Promise.reject(new Error("must not be read")));
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === "Unopened");
  const result = page.window.SynthPatchFile.saveBank(at);
  assert.deepEqual([result.ok, result.error.code], [false, "UnavailableSource"]);
  assert.equal(page.downloads.length, 0, "nothing was written");
  assert.equal(page.window.SynthPatchFile.bankText(at), "", "and nothing is offered to a host to keep");
  assert.match(page.text("bank-status"), /has not been opened/);

  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  assert.equal(page.window.SynthPatchFile.saveBank(1).error.code, "UnavailableSource");
  assert.equal(page.downloads.length, 0);
});

test("a download that fails is reported as an export that failed, and clears nothing", () => {
  const page = app();
  page.window.URL.createObjectURL = () => { throw new Error("no blobs here"); };
  const result = page.window.SynthPatchFile.saveBank();
  assert.deepEqual([result.ok, result.error.code], [false, "ExportFailed"]);
  assert.match(page.text("bank-status"), /Could not write the file: no blobs here/);
});

test("exporting a patch writes the sound that is playing, as a patch file, under its own name", async () => {
  const page = app({slot: 1});
  page.window.SynthPatch.setParam(19, 0.5);
  const live = page.values();
  const result = page.window.SynthPatchFile.savePatch();
  assert.deepEqual([result.ok, result.name, result.cleared], [true, "Bravo", false]);
  const file = await exported(page);
  assert.equal(file.name, "Bravo.json");
  const doc = JSON.parse(file.text);
  assert.deepEqual([doc.format, doc.version, doc.name], ["quesynth.patch", 1, "Bravo"]);
  assert.equal(doc.parameters[PARAM_NAMES[19]], live[19], "the edit is in it: it is the sound, not the slot");
  assert.deepEqual(Object.keys(doc.parameters), PARAM_NAMES, "complete, in parameter order");
  assert.equal(page.window.SynthBank.status(), "dirty", "a sound from a slot is still not what the slot holds");
  assert.equal(page.text("bank-status"), "Exported Bravo.");

  // It can be read back.
  const back = await page.window.SynthPatchFile.importBytes(encoder.encode(file.text), "Bravo.json");
  assert.equal(back.kind, "patch");
  assert.deepEqual(page.values(), live);
});

test("exporting a sound with no slot makes it what it was exported as, so it is no longer unsaved", async () => {
  const page = app();
  await page.window.SynthPatchFile.importBytes(sy1("Loose", 40), "loose.sy1");
  page.window.SynthPatch.setParam(19, 0.8);
  assert.equal(page.window.SynthBank.status(), "dirty");
  const result = page.window.SynthPatchFile.savePatch();
  assert.equal(result.cleared, true);
  assert.equal(page.window.SynthBank.status(), "clean");
  assert.ok(page.$("bank-dirty").hasAttribute("hidden"));
  page.window.SynthPatch.setParam(19, 0.1);
  assert.equal(page.window.SynthBank.status(), "dirty", "and a further edit is unsaved again");
});

test("a file name from a patch name never carries what a file system objects to", async () => {
  const page = app();
  page.window.SynthPatch.apply(sound(3), "Solo/Lead: <1>");
  page.window.SynthPatchFile.savePatch();
  assert.equal((await exported(page)).name, "Solo_Lead_ _1_.json");
});

// ------------------------------------------------- what a host hands over

test("a bank from the host is adopted as it always was: more than 128 patches are cut, and a bad one changes nothing", () => {
  const page = bootPanel({bank: FACTORY});
  const names = Array.from({length: 130}, (_, i) => `N${i}`);
  page.send({type: "bank", text: bankText("Long", names), v: 1, origin: "user", readOnly: false, kept: false});
  assert.equal(page.window.SynthBank.bankInfo(1).used, 128);

  const before = plain(page.window.SynthBank.list());
  page.send({type: "bank", text: "{ not json", v: 1});
  page.send({type: "bank", text: JSON.stringify({format: "quesynth.bank", version: 1, patches: []}), v: 1});
  assert.deepEqual(plain(page.window.SynthBank.list()), before);
  assert.match(page.text("bank-status"), /The host sent a bank this panel could not read/);
  assert.equal(page.$("bank-status").getAttribute("data-kind"), "error");
});

test("the text a host is sent to keep is the bank and nothing else: no favourites, no recents, no selection", () => {
  const page = app({slot: 1});
  const at = plain(page.window.SynthBank.list()).findIndex(b => b.label === "My Bank");
  const doc = JSON.parse(page.window.SynthPatchFile.bankText(at));
  assert.deepEqual(Object.keys(doc), ["format", "version", "name", "patches"]);
  for (const patch of doc.patches.filter(Boolean)) assert.deepEqual(Object.keys(patch), ["name", "parameters"]);
});
