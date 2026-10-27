// Managing banks from the browser: making, opening, renaming, copying,
// exporting and closing them, and what each says about where it came from.
//
// The contract (specs/2026-10-27-preset-bank-ux.md, 3.3): bank actions are
// explicit and separate from loading. New, import (a bank, a folder, a ZIP, a
// .sy1), rename where ownership permits, duplicate, export, close from the
// session, and a visible source and read-only status. The factory bank and the
// host's archives are read-only. A refusal says why and changes nothing, and
// closing a bank never touches the sound that is playing.

import test from "node:test";
import assert from "node:assert/strict";
import {bootPanel, compiledBank, plain, sound} from "./support/panel.mjs";
import {folder, patches, sy1, zip} from "./support/files.mjs";
import {
  all, badges, body, choose, dialog, dialogs, disabled, feedback, focused, front, heading, label, open, press, settle, sourceNames,
  sourceRow, submit, tool, type, wait, withFiles,
} from "./support/browser.mjs";

const FACTORY = compiledBank("Quesynth Factory", ["Init", "Strings", "Brass", "Bells", null, "Choir"], 70);
const patch = (n, seed) => ({n, v: sound(seed)});
const encoder = new TextEncoder();
const json = value => encoder.encode(JSON.stringify(value));

// The browser build, so the factory bank can be written to, with a bank of the
// person's own and one opened from a file.
function banks({store = true} = {}) {
  const page = withFiles(bootPanel({bank: FACTORY, host: null, store}));
  const api = page.window.SynthBank;
  api.newBank("My Bank");
  api.writePreset({bank: "My Bank", slot: 1, name: "Warm Keys"});
  api.writePreset({bank: "My Bank", slot: 3, name: "Glass Pad"});
  api.importBank("Alfmeister Bank", [patch("Zither", 5), null, patch("Harp", 6)]);
  api.loadPreset({bank: 0, slot: 1});
  return page;
}

// Everything an import, a refusal or a cancelled question must leave alone.
const world = page => plain({
  banks: page.window.SynthBank.list().map(b => [b.label, b.origin, b.used]),
  current: page.window.SynthBank.current(),
  selection: page.window.SynthBank.selection(),
  values: page.values(),
  slots: page.window.SynthBank.slots(),
});

// ------------------------------------------------------------------ the badges

test("each bank says where it came from, and a bank that cannot be written to says so", () => {
  const bare = bootPanel({bank: FACTORY, host: null});
  bare.window.SynthBank.newBank("Mine");
  bare.window.SynthBank.importBank("Theirs", [patch("Zither", 5)]);
  open(bare);
  assert.deepEqual(badges(sourceRow(bare, "Quesynth Factory")), ["Factory", "Read-only"], "nothing keeps what is written to it");
  assert.deepEqual(badges(sourceRow(bare, "Mine")), ["User"]);
  assert.deepEqual(badges(sourceRow(bare, "Theirs")), ["Imported"]);

  const kept = banks();
  open(kept);
  assert.deepEqual(badges(sourceRow(kept, "Quesynth Factory")), ["Factory"], "the browser build keeps its factory bank");
});

test("a bank from the host's archive is an archive bank and read-only", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: 0, patches: ["Pad"]});
  open(page);
  assert.deepEqual(badges(sourceRow(page, "a.zip")), ["Archive", "Read-only"]);
  sourceRow(page, "a.zip").click();
  assert.equal(body(page).querySelector(".browser-bank-tools").hidden, true, "there is nothing to rename, copy or close in an archive");
});

// ------------------------------------------------------------------- new bank

test("New bank... asks for a name, makes an empty bank of the person's own, and looks at it", () => {
  const page = banks();
  open(page);
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());
  const make = heading(page, "New bank...");
  make.focus();
  make.click();

  const field = page.document.querySelector('[aria-label="Name for the new bank"]');
  assert.equal(focused(page), field, "the name is what is asked for");
  assert.equal(field.value, "New Bank");
  type(page, field, "Pads");
  submit(page.document.querySelector(".browser-form"));

  assert.deepEqual(sourceNames(page).slice(-1), ["Pads"]);
  assert.deepEqual(badges(sourceRow(page, "Pads")), ["User"]);
  assert.equal(sourceRow(page, "Pads").querySelector(".browser-source-count").textContent, "0");
  assert.equal(page.window.SynthBank.label(), "Pads", "it is the bank in view");
  assert.equal(page.document.querySelector(".browser-form"), null, "the form has done its job");
  assert.equal(focused(page), make, "and the focus is back on the button that asked");
  assert.match(feedback(page).textContent, /^Made Pads\./);
  assert.deepEqual(page.values(), values, "and the sound that is playing was not touched");
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);
});

test("a name that is already taken is made unique, and a name that cannot be used is refused with the form left open", () => {
  const page = banks();
  open(page);
  heading(page, "New bank...").click();
  const field = page.document.querySelector(".browser-form-name");
  type(page, field, "My Bank");
  submit(page.document.querySelector(".browser-form"));
  assert.ok(sourceNames(page).includes("My Bank 2"), "two banks called the same thing would be two rows nobody can tell apart");

  const before = world(page);
  heading(page, "New bank...").click();
  type(page, page.document.querySelector(".browser-form-name"), "   ");
  submit(page.document.querySelector(".browser-form"));
  assert.ok(page.document.querySelector(".browser-form"), "the form stays so the name can be fixed");
  assert.match(feedback(page).textContent, /A bank's name cannot be empty\. \(InvalidName\)/);
  assert.equal(feedback(page).getAttribute("data-kind"), "error");
  assert.deepEqual(world(page), before);
});

test("Escape and Cancel close the form and not the dialog, and put the focus back", () => {
  const page = banks();
  open(page);
  const make = heading(page, "New bank...");
  make.click();
  press(page.document.querySelector(".browser-form-name"), "Escape");
  assert.equal(page.document.querySelector(".browser-form"), null);
  assert.ok(dialog(page), "the dialog is still open");
  assert.equal(focused(page), make);

  make.click();
  all(page, ".browser-form button").find(b => label(b) === "Cancel").click();
  assert.equal(page.document.querySelector(".browser-form"), null);
  assert.equal(sourceNames(page).length, 3, "and no bank was made");
  assert.ok(dialog(page));
});

// --------------------------------------------------------------------- rename

test("Rename... renames the bank in view, and a bank that was playing from it is still the one playing", () => {
  const page = banks();
  page.window.SynthBank.loadPreset({bank: "My Bank", slot: 3});
  open(page);
  sourceRow(page, "My Bank").click();
  assert.equal(tool(page, "Rename...").parentNode.parentNode.querySelector(".browser-bank-tools-name").textContent, "My Bank");
  tool(page, "Rename...").click();
  const field = page.document.querySelector(".browser-form-name");
  assert.equal(field.value, "My Bank");
  type(page, field, "Better Bank");
  submit(page.document.querySelector(".browser-form"));

  assert.ok(sourceNames(page).includes("Better Bank") && !sourceNames(page).includes("My Bank"));
  assert.equal(page.text("bank-name"), "Better Bank");
  assert.equal(plain(page.window.SynthBank.selection()).bank, "Better Bank");
  assert.equal(page.text("bank-patch"), "003:Glass Pad");
  assert.match(feedback(page).textContent, /^Renamed My Bank to Better Bank\./);
  assert.equal(page.document.querySelector(".browser-form"), null);
});

test("an opened bank can be renamed, and a name that is taken is refused beside the form", () => {
  const page = banks();
  open(page);
  sourceRow(page, "Alfmeister Bank").click();
  tool(page, "Rename...").click();
  type(page, page.document.querySelector(".browser-form-name"), "My Bank");
  submit(page.document.querySelector(".browser-form"));
  assert.match(feedback(page).textContent, /A bank called My Bank is already open\. \(InvalidName\)/);
  assert.ok(page.document.querySelector(".browser-form"));
  assert.deepEqual(sourceNames(page).filter(n => n === "Alfmeister Bank").length, 1);

  type(page, page.document.querySelector(".browser-form-name"), "Alfie");
  submit(page.document.querySelector(".browser-form"));
  assert.ok(sourceNames(page).includes("Alfie"));
});

test("the factory bank cannot be renamed: the button looks unavailable, and pressing it gets the reason", () => {
  const page = banks();
  open(page);
  sourceRow(page, "Quesynth Factory").click();
  assert.ok(disabled(tool(page, "Rename...")));
  assert.match(tool(page, "Rename...").title, /cannot be renamed/);
  const before = world(page);
  tool(page, "Rename...").click();
  assert.equal(page.document.querySelector(".browser-form"), null);
  assert.match(feedback(page).textContent, /Quesynth Factory belongs to the host and cannot be renamed\. \(ReadOnlyBank\)/);
  assert.deepEqual(world(page), before);
});

test("a bank the host keeps cannot be renamed either, and the refusal is read in the dialog", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "bank", v: 1, origin: "user", readOnly: false, text: JSON.stringify({
    format: "quesynth.bank", version: 1, name: "Hosted", patches: [{name: "Alpha", parameters: {}}]})});
  open(page);
  sourceRow(page, "Hosted").click();
  tool(page, "Rename...").click();
  type(page, page.document.querySelector(".browser-form-name"), "Mine Now");
  submit(page.document.querySelector(".browser-form"));
  assert.match(feedback(page).textContent, /Hosted belongs to the host and cannot be renamed\. \(ReadOnlyBank\)/);
  assert.ok(sourceNames(page).includes("Hosted"));
  assert.ok(page.document.querySelector(".browser-form") === null, "another name would not help, so the form does not wait for one");
  assert.ok(focused(page) === tool(page, "Rename..."), "and the focus is back on the button that asked");
});

// ------------------------------------------------------------------ duplicate

test("Duplicate makes a writable copy of any bank, the read-only factory bank included, and leaves the original alone", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  open(page);
  const values = page.values();
  const selection = plain(page.window.SynthBank.selection());
  sourceRow(page, "Quesynth Factory").click();
  tool(page, "Duplicate").click();

  assert.deepEqual(sourceNames(page), ["Quesynth Factory", "Quesynth Factory copy"]);
  assert.deepEqual(badges(sourceRow(page, "Quesynth Factory copy")), ["User"], "a copy is the person's, and can be written to");
  assert.deepEqual(badges(sourceRow(page, "Quesynth Factory")), ["Factory", "Read-only"]);
  assert.equal(page.window.SynthBank.label(), "Quesynth Factory copy", "and it is the one in view");
  assert.match(feedback(page).textContent, /^Copied Quesynth Factory to Quesynth Factory copy\./);
  assert.deepEqual(page.values(), values);
  assert.deepEqual(plain(page.window.SynthBank.selection()), selection);

  page.window.SynthBank.select(0, true);
  assert.deepEqual(plain(page.window.SynthBank.slots()).slice(0, 6).map(s => s && s.name), ["Init", "Strings", "Brass", "Bells", null, "Choir"]);
  assert.equal(page.window.SynthBank.writePreset({bank: "Quesynth Factory copy", slot: 4, name: "Mine"}).ok, true);
  assert.equal(page.window.SynthBank.writePreset({bank: "Quesynth Factory", slot: 4, name: "Mine"}).ok, false);
});

test("a second copy gets its own name rather than replacing the first", () => {
  const page = banks();
  open(page);
  sourceRow(page, "My Bank").click();
  tool(page, "Duplicate").click();
  sourceRow(page, "My Bank").click();
  tool(page, "Duplicate").click();
  assert.deepEqual(sourceNames(page).filter(n => /^My Bank/.test(n)), ["My Bank", "My Bank copy", "My Bank copy 2"]);
});

// --------------------------------------------------------------------- export

test("Export bank writes the bank that is in view, and not the one that is playing", async () => {
  const page = banks();
  open(page);
  sourceRow(page, "Alfmeister Bank").click();
  tool(page, "Export bank").click();
  assert.equal(page.downloads.length, 1);
  const doc = JSON.parse(await page.downloads[0].text());
  assert.equal(doc.format, "quesynth.bank");
  assert.equal(doc.name, "Alfmeister Bank");
  assert.deepEqual(doc.patches.map(p => p && p.name), ["Zither", null, "Harp"], "interior empties stay where they are");
  assert.match(feedback(page).textContent, /^Exported Alfmeister Bank \(2 patches\)\./);

  sourceRow(page, "My Bank").click();
  tool(page, "Export bank").click();
  assert.equal(JSON.parse(await page.downloads[1].text()).name, "My Bank");
});

// ----------------------------------------------------------------- close bank

test("Close bank takes a bank that was opened out of the session without touching the sound that was playing from it", () => {
  const page = banks();
  page.window.SynthBank.loadPreset({bank: "Alfmeister Bank", slot: 2});
  open(page);
  const values = page.values();
  sourceRow(page, "Alfmeister Bank").click();
  tool(page, "Close bank").click();

  assert.ok(!sourceNames(page).includes("Alfmeister Bank"));
  assert.equal(dialogs(page).length, 1, "a bank that is somebody's file is closed without a question");
  assert.deepEqual(page.values(), values, "the sound is as it was");
  assert.deepEqual(plain(page.window.SynthBank.selection()),
    {origin: "session", source: "none", bank: "", slot: null, presetName: "Harp", archive: null},
    "it has no slot behind it any more");
  assert.match(feedback(page).textContent, /^Closed Alfmeister Bank\./);
});

test("a bank the person made is asked about first, because closing it is the one way to lose what is in it", async () => {
  const page = banks();
  open(page);
  sourceRow(page, "My Bank").click();
  const before = world(page);
  tool(page, "Close bank").click();

  const question = front(page);
  assert.equal(question.getAttribute("role"), "alertdialog");
  assert.equal(question.getAttribute("aria-label"), "Close My Bank?");
  const text = question.querySelector(".modal-message").textContent;
  assert.match(text, /My Bank has 2 presets and is not saved anywhere else/);
  assert.match(text, /does not change/);
  assert.equal(label(focused(page)), "Cancel", "the safe answer is the easy one");
  assert.deepEqual(world(page), before, "nothing has happened yet");

  all(page, ".modal-foot button").find(b => label(b) === "Cancel" && question.contains(b)).click();
  await settle();
  assert.ok(sourceNames(page).includes("My Bank"), "Cancel keeps it");
  assert.deepEqual(world(page), before);

  tool(page, "Close bank").click();
  all(page, ".modal-foot button").find(b => label(b) === "Close bank" && front(page).contains(b)).click();
  await settle();
  assert.ok(!sourceNames(page).includes("My Bank"));
  assert.equal(dialogs(page).length, 1);
});

test("a bank that was opened from a file is asked about too once something has been written into it, and not before", async () => {
  const page = banks();
  open(page);
  const api = page.window.SynthBank;
  api.writePreset({bank: "Alfmeister Bank", slot: 1, name: "Mine"});
  sourceRow(page, "Alfmeister Bank").click();
  const edited = plain(api.list()).find(b => b.label === "Alfmeister Bank");
  assert.equal(edited.edited, true, "the panel says so, as it says everything else about a bank");
  tool(page, "Close bank").click();

  const question = front(page);
  assert.equal(question.getAttribute("aria-label"), "Close Alfmeister Bank?");
  assert.match(question.querySelector(".modal-message").textContent,
    /Alfmeister Bank was opened from a file, and what has been written into it since is not saved anywhere else/);
  assert.ok(sourceNames(page).includes("Alfmeister Bank"), "nothing has happened yet");

  all(page, ".modal-foot button").find(b => label(b) === "Cancel" && question.contains(b)).click();
  await settle();
  assert.ok(sourceNames(page).includes("Alfmeister Bank"));

  const other = banks();
  open(other);
  other.window.SynthBank.copySlot({bank: "My Bank", slot: 1}, {bank: "Alfmeister Bank", slot: 4});
  sourceRow(other, "Alfmeister Bank").click();
  tool(other, "Close bank").click();
  assert.equal(front(other).getAttribute("aria-label"), "Close Alfmeister Bank?", "a copy into it counts as well");
});

test("a bank of the person's own with nothing in it closes without a question", () => {
  const page = banks();
  page.window.SynthBank.newBank("Scratch");
  open(page);
  sourceRow(page, "Scratch").click();
  tool(page, "Close bank").click();
  assert.equal(dialogs(page).length, 1);
  assert.ok(!sourceNames(page).includes("Scratch"));
});

test("the last bank cannot be closed, nor can the factory bank, and pressing the button says why", () => {
  const page = bootPanel({bank: FACTORY, host: null});
  open(page);
  sourceRow(page, "Quesynth Factory").click();
  assert.ok(disabled(tool(page, "Close bank")));
  assert.match(tool(page, "Close bank").title, /last bank cannot be closed/);
  tool(page, "Close bank").click();
  assert.match(feedback(page).textContent, /The last bank cannot be closed\. \(ReadOnlyBank\)/);
  assert.deepEqual(sourceNames(page), ["Quesynth Factory"]);

  page.window.SynthBank.newBank("Second");
  sourceRow(page, "Quesynth Factory").click();
  assert.ok(disabled(tool(page, "Close bank")));
  tool(page, "Close bank").click();
  assert.match(feedback(page).textContent, /Quesynth Factory cannot be closed\. \(ReadOnlyBank\)/);
  assert.equal(sourceNames(page).length, 2);
});

// -------------------------------------------------------------------- importing

test("Import file... adds a bank and does nothing else: not the bank in view, not the sound, nothing sent", async () => {
  const page = banks();
  open(page);
  const before = world(page);
  page.forget();
  await choose(page, heading(page, "Import file..."), {name: "Strings Pack.zip", bytes: zip(patches(3))});

  assert.deepEqual(sourceNames(page).slice(-1), ["Strings Pack"]);
  assert.deepEqual(badges(sourceRow(page, "Strings Pack")), ["Imported"]);
  assert.equal(sourceRow(page, "Strings Pack").querySelector(".browser-source-count").textContent, "3");
  assert.deepEqual({...world(page), banks: before.banks}, {...before, banks: before.banks});
  assert.equal(world(page).current, before.current, "the bank in view is where it was");
  assert.deepEqual(world(page).values, before.values);
  assert.deepEqual(world(page).selection, before.selection);
  assert.deepEqual(page.sent, []);
  assert.match(feedback(page).textContent, /^Opened 3 patches\./);
  assert.equal(feedback(page).getAttribute("data-kind"), "ok");
});

test("a bank that did not fit says how many were left out, as a warning", async () => {
  const page = banks();
  open(page);
  await choose(page, heading(page, "Import file..."), {name: "ok.zip", bytes: zip(patches(130))});
  assert.equal(feedback(page).textContent,
    "Opened 128 patches (2 left out). 2 patches did not fit a bank's 128 slots and were left out.");
  assert.equal(feedback(page).getAttribute("data-kind"), "warn");
  assert.equal(sourceRow(page, "ok").querySelector(".browser-source-count").textContent, "128");
});

test("a folder is opened the same way, in the order of its names", async () => {
  const page = banks();
  open(page);
  await choose(page, heading(page, "Import folder..."), folder("Drums", ["10.sy1", "9.sy1", "2.sy1", "notes.txt"]), "input[webkitdirectory]");
  assert.deepEqual(badges(sourceRow(page, "Drums")), ["Imported"]);
  page.window.SynthBank.select(page.window.SynthBank.list().findIndex(b => b.label === "Drums"), true);
  assert.deepEqual(plain(page.window.SynthBank.slots()).slice(0, 4).map(s => s && s.name), ["2", "9", "10", null]);
});

test("every way a file can be refused is read in the dialog with its code, and nothing is changed", async () => {
  const page = banks();
  open(page);
  const before = world(page);
  const bank = patchesList => ({format: "quesynth.bank", version: 1, name: "Bad", patches: patchesList});
  const cases = [
    ["InvalidBank", {name: "unknown.json", bytes: json(bank([{name: "A", parameters: {bogus: 1}}]))}, /unknown parameter: bogus/],
    ["InvalidBank", {name: "empty.json", bytes: json(bank([]))}, /the bank has no patches/],
    ["TooManySlots", {name: "big.json", bytes: json(bank(Array.from({length: 129}, () => ({name: "P", parameters: {}}))))}, /129 patches and a bank holds 128/],
    ["UnsupportedFormat", {name: "newer.json", bytes: json({...bank([{name: "A", parameters: {}}]), version: 99})}, /written by a newer version \(99\)/],
    ["UnsupportedFormat", {name: "other.json", bytes: json({format: "something.else"})}, /not a quesynth\.patch file/],
    ["ReadFailed", {name: "x.sy1", bytes: sy1("X", 3), unreadable: true}, /could not read the file/],
  ];
  for (const [code, file, message] of cases) {
    await choose(page, heading(page, "Import file..."), file);
    assert.match(feedback(page).textContent, message, file.name);
    assert.ok(feedback(page).textContent.endsWith(`(${code})`), `${file.name}: ${feedback(page).textContent}`);
    assert.equal(feedback(page).getAttribute("data-kind"), "error");
    assert.equal(feedback(page).getAttribute("role"), "status");
    assert.deepEqual(world(page), before, file.name);
  }
});

test("a single patch file is not a bank: it becomes the sound, as a file", async () => {
  const page = banks();
  open(page);
  await choose(page, heading(page, "Import file..."), {name: "Lonely.sy1", bytes: sy1("Lonely", 33)});
  assert.equal(plain(page.window.SynthBank.selection()).origin, "file");
  assert.equal(plain(page.window.SynthBank.selection()).presetName, "Lonely");
  assert.equal(sourceNames(page).length, 3, "no bank was added");
});

test("the strip's Import bank... opens the same picker, and a refusal there is a dialog that must be read", async () => {
  const page = banks();
  const menu = page.$("preset-menu");
  menu.focus();
  menu.click();
  const before = world(page);
  page.document.querySelector('[data-action="import-bank"]').click();
  const input = page.document.querySelector('input[type="file"]');
  input.files = [{name: "bad.json", bytes: json({format: "quesynth.bank", version: 1, name: "Bad", patches: []})}];
  input.onchange();
  await wait();

  const alert = front(page);
  assert.equal(alert.getAttribute("role"), "alertdialog");
  assert.equal(alert.getAttribute("aria-label"), "Could not open that file");
  assert.match(alert.querySelector(".modal-message").textContent, /the bank has no patches\s*Nothing was changed\. \(InvalidBank\)/);
  assert.deepEqual(world(page), before);
  press(focused(page), "Escape");
  assert.equal(focused(page), menu, "and focus is back on the menu button that asked");

  page.document.querySelector('[data-action="import-bank"]').click();
  input.files = [{name: "good.zip", bytes: zip(patches(2))}];
  input.onchange();
  await wait();
  assert.equal(dialogs(page).length, 0, "a bank that opened needs no dialog");
  assert.equal(page.text("bank-status"), "Opened 2 patches.");
  assert.ok(plain(page.window.SynthBank.list()).some(b => b.label === "good"));
});

test("while a shared archive is open a ZIP is not opened in the page, and the dialog says where to open it", async () => {
  const page = withFiles(bootPanel({bank: FACTORY}));
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip"], bank: 0, patches: ["Pad"]});
  open(page);
  const sent = page.sent.length;
  await choose(page, heading(page, "Import file..."), {name: "x.zip", bytes: zip(patches(2))});
  assert.match(feedback(page).textContent, /Open this ZIP by its path in the Archive field in Patches\. ?\(UnsupportedFormat\)$/);
  assert.equal(page.sent.length, sent);
});

test("Import is offered where a bank is being browsed and nowhere a destination is being chosen", () => {
  const page = banks();
  open(page);
  assert.deepEqual(all(page, ".browser-heading .browser-heading-actions button").map(label), ["New bank...", "Import file...", "Import folder..."]);
  page.window.SynthBrowser.write();
  assert.deepEqual(all(page, ".browser-heading .browser-heading-actions button").map(label), ["New bank..."]);
  assert.equal(body(page).querySelector(".browser-bank-tools").hidden, true);
});

test("the archive area is as it was: a path, Open and Close, and what the host said", () => {
  const page = bootPanel({bank: FACTORY});
  page.send({type: "archive", rev: 1, open: true, path: "/p.zip", banks: ["a.zip", "b.zip"], bank: null, patches: []});
  open(page);
  const area = body(page).querySelector(".browser-archive");
  assert.equal(area.hidden, false);
  assert.equal(body(page).querySelector(".browser-archive-path").value, "/p.zip");
  assert.equal(area.querySelector(".browser-status").textContent, "2 banks · read-only");
  page.forget();
  area.querySelector('[aria-label="Close archive"]').click();
  assert.deepEqual(page.sent, [{type: "archive-close"}]);
  page.window.SynthBrowser.write();
  assert.equal(body(page).querySelector(".browser-archive").hidden, true, "never offered where a destination is chosen");
});
