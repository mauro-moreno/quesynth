// The real panel, booted from its own scripts, against the real adapter in
// front of a fake daemon: the whole browser path except the browser.
//
// The scripts are ui/index.html's, in its order, with the adapter's host.js
// and without the two it withholds (store.js and bank.js), which is exactly
// what a browser gets from serve.js. The stand-in DOM is tests/ui's; the
// WebSocket is Node's own, speaking to the adapter over TCP.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {Event, createWindow, mountIndexSkeleton} from "../ui/support/dom.mjs";
import {ROOT, ARCHIVE, ARCHIVE_PATH, connectRaw} from "./support/fake-daemon.mjs";
import {startEnv, unix, until} from "./support/harness.mjs";
import {sleep} from "./support/ws-client.mjs";

const SCRIPTS = ["host.js", "params.js", "layout.js", "bridge.js", "app.js", "midi.js", "sy1.js",
  "midimap.js", "patchfile.js", "modal.js", "browser.js", "options.js"];
const WRITES = new Set(["parameter.set", "parameter.set_many", "patch.apply", "patch.load", "patch.clear", "patch.save",
  "bank.load_file", "bank.keep", "midi", "volume"]);

function bootPanel(port) {
  const window = createWindow();
  mountIndexSkeleton(window.document);
  window.location = {protocol: "http:", host: `127.0.0.1:${port}`};
  const sent = [];
  const sockets = [];
  // Node's WebSocket, recording what the page sends through it.
  window.WebSocket = class extends WebSocket {
    constructor(url) {
      super(url);
      sockets.push(this);
    }
    send(text) {
      sent.push(JSON.parse(text));
      super.send(text);
    }
  };
  const context = vm.createContext(window);
  for (const name of SCRIPTS) {
    const file = name === "host.js"
      ? path.join(ROOT, "hosts", "standalone", "browser", "host.js")
      : path.join(ROOT, "ui", name);
    vm.runInContext(fs.readFileSync(file, "utf8"), context, {filename: file});
  }
  window.document.dispatchEvent(new Event("DOMContentLoaded"));
  const got = [];
  const deliver = window.synthReceive;
  window.synthReceive = text => {
    got.push(JSON.parse(text));
    deliver(text);
  };
  return {window, sent, got, close: () => sockets.forEach(s => s.close())};
}

// What the adapter's own daemon connection changed, leaving out the peer.
function writes(daemon) {
  const adapter = daemon.log.find(e => e.line === "parameter.list").conn;
  return daemon.log.filter(e => e.conn === adapter && WRITES.has(e.line.split(" ")[0])).map(e => e.line);
}

test("the real panel runs hosted on the daemon: synced, live both ways, and never an authority", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t);
  const daemon = env.daemon;
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 4");
  daemon.log = [];

  const page = bootPanel(env.port);
  t.after(() => page.close());
  const w = page.window;
  const shown = () => w.document.getElementById("bank-patch").textContent;
  assert.equal(w.SynthBridge.host, "generic");
  assert.equal(w.SynthBank.hosted(), true, "no store.js: the page keeps nothing of its own");

  await until(() => page.got.some(m => m.type === "patch"), 5000, "the page to be synced");
  await sleep(150);

  // (a) Startup writes nothing but the volume; the page's echo of the bank
  // it was sent is dropped by the adapter.
  assert.deepEqual(writes(daemon), ["volume 640"]);
  assert.deepEqual(page.sent.map(m => m.type), ["sync", "volume", "state"],
    "one sync, the startup volume, and the adoption echo");
  assert.deepEqual(page.sent[2].values, daemon.bank.slots[0].values, "the echo is slot 0");

  // (e) The daemon's bank is the page's bank.
  assert.equal(w.SynthBank.label(), "My Bank");
  assert.equal(w.SynthBank.slots()[3].name, 'Bass "Deep" \\ Ü\ttab');
  assert.equal(w.SynthBank.slots()[2], null);

  // (b) The page shows the daemon's sound, all 99 values, and its identity.
  assert.deepEqual(Array.from(w.SynthPatch.values()), daemon.published.values);
  assert.equal(shown(), "004:Pluck");

  // (c) A change made by another client appears in the page.
  await peer.request("parameter.set filter.cutoff 17");
  await until(() => w.SynthPatch.values()[19] === 17, 3000, "the peer's change in the page");

  // (d) A change made in the page reaches the daemon.
  w.SynthPatch.setParam(19, 0.5);
  const mine = w.SynthPatch.values()[19];
  assert.notEqual(mine, 17);
  await until(() => daemon.published.values[19] === mine, 3000, "the page's change in the daemon");
  assert.deepEqual(writes(daemon).slice(1), [`parameter.set filter.cutoff ${mine}`]);

  // (f) A patch loaded elsewhere moves what the page shows. The load may
  // land before the adapter has seen the page's own cutoff write applied;
  // that one parameter then keeps the page's value until the echo window
  // closes, and only then takes the daemon's.
  await peer.request("patch.load 5");
  await until(() => shown() === "005:Bells", 3000, "the patch strip");
  const slot5 = daemon.bank.slots[5].values;
  await until(() => w.SynthPatch.values().every((v, i) => v === slot5[i]), 3000, "slot 5's sound");

  // And the page's own NEXT, which loads by value, lands in the daemon as a
  // slot load, so every client agrees on the identity.
  w.document.querySelector('.bank-step[data-step="1"]').click();
  await until(() => daemon.identity.slot === 6, 3000, "NEXT to load slot 6");
  assert.equal(writes(daemon).at(-1), "patch.load 6");
  await until(() => shown() === "006:Organ", 3000, "the strip after NEXT");
  assert.deepEqual(Array.from(w.SynthPatch.values()), daemon.published.values);
});

test("a fresh daemon plays Init, and the strip says so instead of the bank's first patch", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t);
  const page = bootPanel(env.port);
  t.after(() => page.close());
  const shown = () => page.window.document.getElementById("bank-patch").textContent;
  await until(() => page.got.some(m => m.type === "patch"), 5000, "the page to be synced");
  await sleep(150);
  assert.deepEqual(env.daemon.identity, {slot: -1, bank: "", name: "", source: "none", archiveBank: -1, archivePatch: -1});
  assert.equal(shown(), "Untitled", "not 000:Strings, which is what adopting the bank selected");
  assert.deepEqual(Array.from(page.window.SynthPatch.values()), env.daemon.published.values);
});

test("storing a patch from the panel keeps the slot and the name on the strip and in the daemon", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t);
  const daemon = env.daemon;
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 4");
  const page = bootPanel(env.port);
  t.after(() => page.close());
  const w = page.window;
  const shown = () => w.document.getElementById("bank-patch").textContent;
  await until(() => page.got.some(m => m.type === "patch"), 5000, "the page to be synced");
  await sleep(150);
  assert.equal(shown(), "004:Pluck");
  const before = writes(daemon).length;
  const banks = page.got.filter(m => m.type === "bank").length;

  assert.equal(w.SynthBank.store(20, "My Lead"), true);
  assert.equal(shown(), "020:My Lead");
  await until(() => daemon.identity.slot === 20, 3000, "the store to reach the daemon");
  // Many polls, which is where the strip used to flip back to the name the
  // daemon had before the store.
  await sleep(300);
  assert.equal(shown(), "020:My Lead");
  assert.deepEqual(daemon.identity, {slot: 20, bank: "My Bank", name: "My Lead", source: "bank", archiveBank: -1, archivePatch: -1});
  assert.deepEqual(writes(daemon).slice(before), ["patch.save 20 My Lead"], "a store is not a whole-bank adoption");
  assert.equal(daemon.bank.slots[20].name, "My Lead");
  assert.equal(page.got.filter(m => m.type === "bank").length, banks, "the bank is not echoed back");
  assert.deepEqual(page.got.filter(m => m.type === "patch").at(-1),
    {type: "patch", name: "My Lead", index: 20, bank: "My Bank", source: "bank", archive: null});
});

test("the hosted bank dialog browses the shared archive without replacing the ordinary bank", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 5");
  const page = bootPanel(env.port);
  t.after(() => page.close());
  const w = page.window, doc = w.document;
  await until(() => page.got.some(m => m.type === "archive"), 5000, "archive capability");
  assert.deepEqual(Array.from(w.SynthBank.list(), b => b.label), ["My Bank"], "no placeholder bank");
  w.SynthBrowser.open();
  const sources = () => doc.querySelectorAll(".browser-source");
  const slots = () => doc.querySelectorAll(".browser-slot");
  const shown = () => doc.getElementById("bank-patch").textContent;
  const marked = () => doc.querySelectorAll(".browser-slot.on");
  const pathField = doc.querySelector(".browser-archive-path");
  assert.equal(slots().length, 128);
  assert.equal(marked()[0].querySelector(".browser-slot-num").textContent, "005");
  pathField.value = ARCHIVE_PATH;
  doc.querySelector('[aria-label="Open archive"]').click();
  await until(() => sources().length === 4, 3000, "ordinary plus three archive banks");
  assert.deepEqual(sources().map(s => s.querySelector(".browser-source-name").textContent),
    ["My Bank", ...ARCHIVE.map(b => b.name)]);
  const revision = env.daemon.published.revision;
  sources()[1].click();
  await until(() => slots().length === 8, 3000, "archive bank 0's patches");
  assert.equal(env.daemon.published.revision, revision, "browsing loads nothing");
  assert.equal(shown(), "005:Bells");
  assert.equal(doc.getElementById("bank-name").textContent, "My Bank");
  assert.match(doc.querySelector(".browser-bank-name").textContent, /^Browsing: aaa bbb/);
  assert.match(doc.querySelector(".browser-playing").textContent, /Playing: Bells · My Bank · slot 5/);
  assert.equal(marked().length, 0, "ordinary slot 5 is not archive patch 5");
  slots()[3].click();
  await until(() => doc.getElementById("bank").dataset.source === "archive", 3000, "archive provenance");
  assert.equal(shown(), "003:Bells");
  assert.equal(w.SynthBank.index(), -1, "no stale ordinary slot");
  assert.equal(marked()[0].querySelector(".browser-slot-num").textContent, "003");
  assert.equal(page.sent.at(-1).type, "archive-load");
  assert.equal(env.daemon.commands("archive.load").at(-1), "archive.load 3 0");
  assert.equal(env.daemon.bank.label, "My Bank");
  assert.deepEqual(env.daemon.commands("bank.load_file"), [], "no flattened bank");

  // A peer's browse moves the open bank, but not the playing patch.
  await peer.request("archive.bank 1");
  await until(() => slots().length === 3, 3000, "the peer's bank");
  assert.equal(marked().length, 0);
  assert.equal(shown(), "003:Bells");
  sources()[0].click();
  assert.equal(slots().length, 128);
  assert.equal(marked().length, 0);
  await peer.request("patch.load 6");
  await until(() => shown() === "006:Organ", 3000, "ordinary load from peer");
  assert.equal(sources().length, 4, "archive banks survive a cross-client ordinary load");
  assert.equal(marked()[0].querySelector(".browser-slot-num").textContent, "006");
  assert.equal(doc.getElementById("bank").dataset.source, "bank");
  await peer.request("archive.bank 0");
  await sleep(60);
  assert.equal(slots().length, 128, "ordinary browsing does not follow archive navigation");

  // ZIP input is deliberately not the panel's old local parser in this mode.
  const sent = page.sent.length;
  await assert.rejects(w.SynthPatchFile.loadBytes(new Uint8Array([80, 75, 3, 4]), "banks.zip"),
    /Archive field in Patches/);
  assert.equal(page.sent.length, sent);
  assert.deepEqual(env.daemon.commands("bank.load_file"), []);

  // A replacement ordinary bank stays in its one row, with the archive next
  // to it, even while the archive is being browsed.
  sources()[1].click();
  await until(() => slots().length === 8, 3000, "archive bank 0 again");
  const bankFile = path.join(env.dir, "replacement.json");
  fs.writeFileSync(bankFile, JSON.stringify({format: "quesynth.bank", version: 1,
    name: "Replacement", patches: [{name: "Only", parameters: {}}]}));
  const before = page.got.length;
  await peer.request(`bank.load_file ${bankFile}`);
  // The identity always follows a new bank, which on its own shows slot 0.
  await until(() => page.got.slice(before).some(m => m.type === "patch"), 3000, "the bank and its identity");
  assert.ok(sources()[0].textContent.includes("Replacement"), "replaced ordinary row");
  assert.equal(sources().length, 4);
  assert.equal(slots().length, 8, "still browsing the archive");
  assert.equal(shown(), "Organ", "old slot invalidated, old provenance name retained");
  assert.equal(doc.getElementById("bank-name").textContent, "My Bank");

  doc.querySelector('[aria-label="Close archive"]').click();
  await until(() => sources().length === 1, 3000, "closed archive");
  assert.equal(slots().length, 128);
  assert.equal(pathField.value, "");
});

test("the hosted WRITE dialog targets only the ordinary bank while an archive patch is playing", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t, {daemon: {archivePath: ARCHIVE_PATH}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("archive.load 1 1");
  const page = bootPanel(env.port);
  t.after(() => page.close());
  const w = page.window, doc = w.document;
  await until(() => page.got.some(m => m.type === "archive"), 5000, "archive capability");
  w.SynthBrowser.open();
  doc.querySelectorAll(".browser-source")[2].click();
  await until(() => w.SynthBank.browsing().bank === 1 && !w.SynthBank.browsing().loading, 3000);
  w.SynthBrowser.write();
  assert.equal(doc.querySelectorAll(".browser-source").length, 1);
  assert.equal(doc.querySelectorAll(".browser-slot").length, 128);
  assert.ok(doc.querySelector(".browser-archive").hidden);
  doc.querySelectorAll(".browser-slot")[20].click();
  doc.querySelector(".browser-save-name").value = "Archive Copy";
  doc.querySelector(".browser-save").dispatchEvent(new Event("submit"));
  await until(() => env.daemon.identity.slot === 20, 3000, "saved to ordinary slot");
  assert.equal(env.daemon.identity.source, "bank");
  assert.deepEqual(env.daemon.commands("patch.save"), ["patch.save 20 Archive Copy"]);
  assert.equal(env.daemon.bank.slots[20].values[19], ARCHIVE[1].patches[1].values[19]);
  assert.equal(env.daemon.archive.bank, 1);
});

test("on a daemon from before the shared archive the hosted page keeps its own zip handling", {
  skip: !unix || typeof WebSocket !== "function",
}, async t => {
  const env = await startEnv(t, {daemon: {legacy: true}});
  const page = bootPanel(env.port);
  t.after(() => page.close());
  const w = page.window;
  await until(() => page.got.some(m => m.type === "midi"), 5000, "the sync");
  assert.equal(w.SynthBank.archive(), null);
  assert.equal(w.document.getElementById("bank").dataset.source, "none");
  const zip = new Uint8Array(fs.readFileSync(path.join(ROOT, "tests", "zip", "fixtures", "nested.zip")));
  assert.equal(await w.SynthPatchFile.loadBytes(zip, "nested.zip"), "1 banks");
  assert.equal(Array.from(w.SynthBank.list()).at(-1).label, "bankA", "listed by the page, unopened");
  assert.deepEqual(page.sent.filter(m => /^archive-/.test(m.type)), []);
});
