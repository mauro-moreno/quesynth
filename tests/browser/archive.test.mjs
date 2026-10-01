// The daemon's patch archive through the adapter: the `archive` message a
// page is sent, the four requests it can make, and how the archive and the
// playing patch's provenance stay shared between pages and other clients.
//
// The expected names, paths and indices come from the stand-in archive in
// fake-daemon.mjs, whose answers follow hosts/standalone/archive.odin and
// identity.odin; the expected messages are the JSON contract written out in
// hosts/standalone/browser/README.md, never the adapter's own output.

import test from "node:test";
import assert from "node:assert/strict";
import {ARCHIVE, ARCHIVE_PATH, DEFAULTS, connectRaw, makeArchive} from "./support/fake-daemon.mjs";
import {startEnv, strayTempDirs, unix, until} from "./support/harness.mjs";
import {sleep} from "./support/ws-client.mjs";

const skip = !unix;
const NAMES = ARCHIVE.map(b => b.name);
const patchNames = bank => ARCHIVE[bank].patches.map(p => p.name);

async function page(t, options) {
  const env = await startEnv(t, options);
  const ws = await env.open();
  const synced = await ws.synced();
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  return {env, ws, peer, daemon: env.daemon, synced};
}

// What the adapter sends for an archive, built from the stand-in's data.
function view(rev, bank = null, path = ARCHIVE_PATH) {
  return {
    type: "archive", rev, open: true, path, banks: NAMES, bank,
    patches: bank === null ? [] : patchNames(bank),
  };
}

function closed(rev, path = "") {
  return {type: "archive", rev, open: false, path, banks: [], bank: null, patches: []};
}

// Everything the adapter asked the archive, in order.
function archiveCommands(daemon) {
  return daemon.commands().filter(line => line.startsWith("archive."));
}

// What changes the daemon's archive or sound, as opposed to reading them.
function archiveWrites(daemon) {
  return daemon.commands().filter(line => /^archive\.(open|bank|load|close)\b/.test(line) ||
    /^(bank\.load_file|bank\.keep|patch\.)/.test(line) && line !== "patch.current");
}

// -- the stand-in ---------------------------------------------------------------

test("the stand-in daemon answers the archive verbs as the protocol says", {skip}, async t => {
  const env = await startEnv(t);
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  const ask = async line => (await peer.request(line)).replace(/^1 \d+ /, "");
  assert.equal(await ask("archive.current"), "ok open=0 banks=0 bank=-1 patches=0 archive_rev=0\npath=\nbank_name=");
  assert.equal(await ask("patch.current"),
    "ok slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=");
  assert.equal(await ask("archive.open"), "err invalid_payload open needs a path");
  assert.equal(await ask("archive.banks 0 10"), "err daemon_not_ready no archive open");
  assert.equal(await ask("archive.bank 0"), "err daemon_not_ready no archive open");
  assert.equal(await ask("archive.patches"), "err daemon_not_ready no bank open");
  assert.equal(await ask("archive.load 0"), "err daemon_not_ready no bank open");
  assert.equal(await ask("archive.load 0 0"), "err daemon_not_ready no archive open");
  assert.equal(await ask(`archive.open ${ARCHIVE_PATH}`), "ok banks=3 archive_rev=1");
  assert.equal(await ask("archive.open /no/such.zip"), "err invalid_payload cannot open archive");
  assert.equal(await ask("archive.banks 1 5"),
    "ok total=3 archive_rev=1\nbank=1 name=bankB.zip\nbank=2 name=empty.zip");
  assert.equal(await ask("archive.bank 3"), "err invalid_payload cannot open that bank");
  assert.equal(await ask("archive.bank 0"), "ok patches=8 bank=0 archive_rev=2");
  assert.equal(await ask("archive.bank 0"), "ok patches=8 bank=0 archive_rev=2", "the open bank is no change");
  assert.equal(await ask("archive.patches 1 2"),
    "ok total=8 bank=0 archive_rev=2\npatch=1 name=miniPoli_01\npatch=2 name=  Spaced  Lead ");
  assert.equal(await ask("archive.current"),
    `ok open=1 banks=3 bank=0 patches=8 archive_rev=2\npath=${ARCHIVE_PATH}\nbank_name=aaa bbb Thanks Ms Ichiro 01.zip`);
  assert.equal(await ask("archive.load 2"), "ok count=99 revision=0 bank=0 patch=2");
  assert.equal(await ask("patch.current"),
    "ok slot=-1 bank_rev=0 revision=1 source=archive archive_rev=2 archive_bank=0 archive_patch=2" +
    "\nbank=aaa bbb Thanks Ms Ichiro 01.zip\nname=Spaced  Lead");
  assert.equal(await ask("archive.load 9 1"), "err invalid_payload patch index out of range");
  assert.equal(await ask("archive.current").then(a => a.split("\n")[0]),
    "ok open=1 banks=3 bank=1 patches=3 archive_rev=3", "the named bank is opened before the index is checked");
  assert.equal(await ask("archive.load 1 7"), "err invalid_payload cannot open that bank");
  assert.equal(await ask("archive.load x 1"), "err invalid_payload bad index");
  assert.equal(await ask("archive.close"), "ok archive_rev=4");
  assert.equal(await ask("archive.close"), "ok archive_rev=4", "nothing open or remembered is no change");
  assert.equal(await ask("patch.current"),
    "ok slot=-1 bank_rev=0 revision=1 source=archive archive_rev=4 archive_bank=-1 archive_patch=-1" +
    "\nbank=aaa bbb Thanks Ms Ichiro 01.zip\nname=Spaced  Lead");
});

test("the stand-in's archive.adopt takes a path only while the daemon has chosen none", {skip}, async t => {
  const env = await startEnv(t, {daemon: {archives: {[ARCHIVE_PATH]: ARCHIVE, "/gone.zip": ARCHIVE}}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  const ask = async line => (await peer.request(line)).replace(/^1 \d+ /, "");
  assert.equal(await ask("archive.adopt"), "err invalid_payload adopt needs a path");
  assert.equal(await ask("archive.adopt /no/such.zip"), "err invalid_payload cannot open archive");
  assert.equal(await ask("archive.current"), "ok open=0 banks=0 bank=-1 patches=0 archive_rev=0\npath=\nbank_name=");
  assert.equal(await ask(`archive.adopt ${ARCHIVE_PATH}`), "ok adopted=1 open=1 banks=3 archive_rev=1");
  assert.equal(await ask("archive.adopt /gone.zip"), "ok adopted=0 open=1 banks=3 archive_rev=1");
  assert.equal(env.daemon.archive.path, ARCHIVE_PATH);
  // A remembered path that will not open is a choice too.
  env.daemon.archive = {banks: null, bank: -1, path: "/media/usb/unmounted.zip", rev: 0};
  assert.equal(await ask(`archive.adopt ${ARCHIVE_PATH}`), "ok adopted=0 open=0 banks=0 archive_rev=0");
  assert.equal(env.daemon.archive.path, "/media/usb/unmounted.zip");
});

test("the stand-in's persistence knob refuses open, adopt and close as the daemon does, changing nothing", {skip}, async t => {
  const env = await startEnv(t, {daemon: {keepFails: true, archives: {[ARCHIVE_PATH]: ARCHIVE, "/other.zip": ARCHIVE}}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  const ask = async line => (await peer.request(line)).replace(/^1 \d+ /, "");
  const closedView = "ok open=0 banks=0 bank=-1 patches=0 archive_rev=0\npath=\nbank_name=";
  assert.equal(await ask(`archive.adopt ${ARCHIVE_PATH}`), "err internal_error cannot keep archive path");
  assert.equal(await ask(`archive.open ${ARCHIVE_PATH}`), "err internal_error cannot keep archive path");
  assert.equal(await ask("archive.current"), closedView);
  env.daemon.keepFails = false;
  assert.equal(await ask(`archive.open ${ARCHIVE_PATH}`), "ok banks=3 archive_rev=1");
  env.daemon.keepFails = true;
  assert.equal(await ask("archive.open /other.zip"), "err internal_error cannot keep archive path");
  assert.equal(await ask("archive.open"), "ok banks=3 archive_rev=2", "the remembered path is already kept");
  assert.equal(await ask("archive.close"), "err internal_error cannot forget archive path");
  assert.equal((await ask("archive.current")).split("\n")[0], "ok open=1 banks=3 bank=-1 patches=0 archive_rev=2");
});

// -- daemon -> page ---------------------------------------------------------------

test("sync sends the archive after the patch, closed and with the path it remembers", {skip}, async t => {
  const {synced, ws} = await page(t, {daemon: {archivePath: "/media/usb/unmounted.zip"}});
  assert.deepEqual(synced.archive, closed(0, "/media/usb/unmounted.zip"));
  assert.deepEqual(await ws.quiet(100, "archive"), [], "an archive that has not moved is not sent again");
});

test("sync sends an open archive whole: every bank, the open one and its patches, raw", {skip}, async t => {
  const env = await startEnv(t, {daemon: {archivePath: ARCHIVE_PATH}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("archive.bank 0");
  const ws = await env.open();
  const {archive} = await ws.synced();
  assert.deepEqual(archive, view(1, 0));
  assert.equal(archive.patches[2], "  Spaced  Lead ", "names keep their spaces");
});

test("a fresh daemon's archive is closed with nothing remembered", {skip}, async t => {
  const {synced} = await page(t);
  assert.deepEqual(synced.archive, closed(0));
});

test("bank and patch names are paged 256 at a time until the total", {skip}, async t => {
  const many = makeArchive([
    ...Array.from({length: 299}, (_, i) => [`bank ${i}.zip`, ["one"]]),
    ["big.zip", Array.from({length: 600}, (_, i) => `patch ${i}`)],
  ]);
  const env = await startEnv(t, {daemon: {archives: {"/big.zip": many}, archivePath: "/big.zip"}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("archive.bank 299");
  env.daemon.log = [];
  const ws = await env.open();
  const {archive} = await ws.synced();
  assert.equal(archive.banks.length, 300);
  assert.equal(archive.banks[299], "big.zip");
  assert.equal(archive.patches.length, 600);
  assert.deepEqual(archive.patches.slice(254, 258), ["patch 254", "patch 255", "patch 256", "patch 257"]);
  assert.equal(archive.patches[599], "patch 599");
  assert.deepEqual(archiveCommands(env.daemon).slice(0, 6), [
    "archive.current", "archive.banks 0 256", "archive.banks 256 256",
    "archive.patches 0 256", "archive.patches 256 256", "archive.patches 512 256",
  ]);
});

test("a read the archive moves under starts again and sends one consistent view", {skip}, async t => {
  const many = makeArchive(Array.from({length: 300}, (_, i) => [`bank ${i}.zip`, [`first of ${i}`, `second of ${i}`]]));
  const env = await startEnv(t, {daemon: {archives: {"/big.zip": many}, archivePath: "/big.zip"}});
  let moved = false;
  // A peer opening another bank between the adapter's two pages.
  env.daemon.intercept = req => {
    if (!moved && req.command === "archive.banks" && req.operands[0] === "256") {
      moved = true;
      env.daemon.archive.bank = 7;
      env.daemon.archive.rev++;
    }
    return undefined;
  };
  const ws = await env.open();
  const {archive} = await ws.synced();
  assert.ok(moved);
  assert.equal(archive.rev, 1);
  assert.equal(archive.bank, 7);
  assert.equal(archive.banks.length, 300);
  assert.deepEqual(archive.patches, ["first of 7", "second of 7"]);
  assert.equal(env.daemon.commands("archive.current").length, 2, "read again from the top");
  assert.deepEqual(await ws.quiet(100, "archive"), [], "and not again on the next poll");
});

test("a read that keeps moving is sent after three tries and read again on the next poll", {skip}, async t => {
  const many = makeArchive(Array.from({length: 300}, (_, i) => [`bank ${i}.zip`, ["one"]]));
  const env = await startEnv(t, {daemon: {archives: {"/big.zip": many}, archivePath: "/big.zip"}});
  let moves = 0;
  env.daemon.intercept = req => {
    if (moves < 3 && req.command === "archive.banks" && req.operands[0] === "256") {
      moves++;
      env.daemon.archive.rev++;
    }
    return undefined;
  };
  const ws = await env.open();
  const {archive} = await ws.synced();
  assert.equal(moves, 3);
  assert.equal(archive.rev, 2, "the generation the last try began at");
  assert.equal(archive.banks.length, 256, "what it had when the archive moved again");
  const again = await ws.next("archive");
  assert.deepEqual(again, {type: "archive", rev: 3, open: true, path: "/big.zip",
    banks: many.map(b => b.name), bank: null, patches: []});
});

// -- page -> daemon ---------------------------------------------------------------

test("archive-open opens a path, or the remembered one, and answers with the archive", {skip}, async t => {
  const {ws, daemon} = await page(t);
  ws.send({type: "archive-open", path: ARCHIVE_PATH});
  assert.deepEqual(await ws.next("archive"), view(1));
  assert.deepEqual(archiveWrites(daemon), [`archive.open ${ARCHIVE_PATH}`]);
  assert.deepEqual(await ws.quiet(100, "archive"), [], "the page's own change is not sent to it twice");
  ws.send({type: "archive-open"});
  assert.deepEqual(await ws.next("archive"), view(2));
  ws.send({type: "archive-open", path: ""});
  assert.deepEqual(await ws.next("archive"), view(3));
  assert.deepEqual(archiveWrites(daemon), [`archive.open ${ARCHIVE_PATH}`, "archive.open", "archive.open"]);
});

test("archive-bank browses a bank and leaves the sound and its provenance alone", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("patch.load 5");
  await ws.next(m => m.type === "patch" && m.index === 5);
  ws.drain();
  const revision = daemon.published.revision;
  ws.send({type: "archive-bank", index: 1});
  assert.deepEqual(await ws.next("archive"), view(1, 1));
  assert.deepEqual(archiveWrites(daemon), ["patch.load 5", "archive.bank 1"]);
  assert.equal(daemon.published.revision, revision, "browsing loads nothing");
  assert.equal(daemon.identity.slot, 5);
  assert.deepEqual(await ws.quiet(100, m => m.type === "patch" || m.type === "state"), []);
});

test("archive-load loads the patch the page's list names and the page is told where it came from", {skip}, async t => {
  const {ws, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  ws.send({type: "archive-load", bank: 0, index: 2});
  assert.deepEqual(await ws.next("archive"), view(1, 0), "the bank was opened for it");
  assert.deepEqual(await ws.next(m => m.type === "param" && m.index === 19),
    {type: "param", index: 19, value: ARCHIVE[0].patches[2].values[19]});
  assert.deepEqual(await ws.next("patch"), {
    type: "patch", name: "Spaced  Lead", index: null, bank: "aaa bbb Thanks Ms Ichiro 01.zip",
    source: "archive", archive: {bank: 0, patch: 2},
  });
  assert.deepEqual(archiveWrites(daemon), ["archive.load 2 0"]);
  assert.deepEqual(daemon.published.values, ARCHIVE[0].patches[2].values);
});

test("archive-load names the page's bank even after a peer opened another", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  ws.send({type: "archive-bank", index: 0});
  await ws.next(m => m.type === "archive" && m.bank === 0);
  await peer.request("archive.bank 1");
  // Sent before the page has heard of the peer's bank: its list is bank 0's.
  ws.send({type: "archive-load", bank: 0, index: 4});
  await until(() => daemon.identity.source === "archive", 3000, "the load");
  assert.deepEqual(daemon.published.values, ARCHIVE[0].patches[4].values);
  assert.equal(daemon.identity.name, "Organ");
  assert.equal(daemon.archive.bank, 0);
});

test("archive-close closes and forgets, and the playing patch keeps its names but no indices", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("archive.load 1 1");
  const loaded = await ws.next(m => m.type === "patch" && m.source === "archive");
  assert.deepEqual(loaded.archive, {bank: 1, patch: 1});
  await ws.next("archive");
  ws.send({type: "archive-close"});
  assert.deepEqual(await ws.next("archive"), closed(2));
  assert.deepEqual(await ws.next("patch"), {
    type: "patch", name: "Bass", index: null, bank: "bankB.zip", source: "archive", archive: null,
  });
  assert.equal(daemon.archive.path, "");
});

test("archive requests are validated before any command is built", {skip}, async t => {
  const {ws, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  daemon.log = [];
  const bad = [
    {type: "archive-open", path: 5},
    {type: "archive-open", path: null},
    {type: "archive-open", path: ["/x.zip"]},
    {type: "archive-open", path: "/x.zip\n1 9 daemon.shutdown"},
    {type: "archive-open", path: "/x.zip\r"},
    {type: "archive-open", path: "/x\u0000.zip"},
    {type: "archive-open", path: "/x\u007f.zip"},
    {type: "archive-open", path: "/x\u0085.zip"},
    {type: "archive-open", path: "/x\u2028.zip"},
    {type: "archive-open", path: "/x\u2029.zip"},
    {type: "archive-open", path: "/" + "é".repeat(2048)},
    // Not UTF-8 at all: it would reach the daemon as U+FFFD, another path.
    {type: "archive-open", path: "/x\ud800.zip"},
    {type: "archive-bank"},
    {type: "archive-bank", index: -1},
    {type: "archive-bank", index: 1.5},
    {type: "archive-bank", index: "1"},
    {type: "archive-bank", index: 2 ** 53},
    {type: "archive-bank", index: null},
    {type: "archive-load", bank: 0},
    {type: "archive-load", index: 0},
    {type: "archive-load", bank: -1, index: 0},
    {type: "archive-load", bank: 0, index: "0"},
    {type: "archive-load", bank: 0.5, index: 0},
    {type: "archive-load", bank: 0, index: 1e300},
  ];
  for (const msg of bad) {
    ws.send(msg);
    const error = await ws.next("error");
    assert.equal(error.for, msg.type, JSON.stringify(msg));
    assert.equal(error.code, "invalid_payload", JSON.stringify(msg));
  }
  await sleep(60);
  assert.deepEqual(archiveWrites(daemon), []);
  assert.deepEqual(ws.drain().filter(m => m.type === "archive"), [], "a refused message changes nothing to show");
  // The longest path that fits is one the daemon is asked about.
  const longest = "/" + "a".repeat(4095);
  ws.send({type: "archive-open", path: longest});
  assert.equal((await ws.next("error")).message, "cannot open archive");
  assert.deepEqual(archiveWrites(daemon), [`archive.open ${longest}`]);
});

test("a refused request is reported, then the page is sent the archive the daemon kept", {skip}, async t => {
  const {ws, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  ws.send({type: "archive-bank", index: 1});
  await ws.next("archive");
  const cases = [
    [{type: "archive-open", path: "/no/such.zip"}, "invalid_payload", "cannot open archive", view(1, 1)],
    [{type: "archive-bank", index: 3}, "invalid_payload", "cannot open that bank", view(1, 1)],
    [{type: "archive-load", bank: 1, index: 3}, "invalid_payload", "patch index out of range", view(1, 1)],
    // The daemon opens the bank the page names before it checks the index.
    [{type: "archive-load", bank: 0, index: 8}, "invalid_payload", "patch index out of range", view(2, 0)],
    [{type: "archive-load", bank: 9, index: 0}, "invalid_payload", "cannot open that bank", view(2, 0)],
  ];
  for (const [msg, code, message, kept] of cases) {
    ws.send(msg);
    assert.deepEqual(await ws.next("error"), {type: "error", for: msg.type, code, message});
    assert.deepEqual(await ws.next("archive"), kept, JSON.stringify(msg));
  }
  ws.send({type: "archive-close"});
  await ws.next("archive");
  ws.send({type: "archive-bank", index: 0});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "archive-bank", code: "daemon_not_ready", message: "no archive open"});
  assert.deepEqual(await ws.next("archive"), closed(3));
  assert.equal(daemon.identity.source, "none", "nothing was loaded");
  assert.ok(!ws.ended, "the page stays connected");
});

test("a daemon that cannot keep the path refuses the page's open and close, and the page is sent the archive it still has", {skip}, async t => {
  const other = makeArchive([["x.zip", ["only"]]]);
  const {ws, daemon} = await page(t, {daemon: {
    archivePath: ARCHIVE_PATH, keepFails: true, archives: {[ARCHIVE_PATH]: ARCHIVE, "/other.zip": other},
  }});
  ws.send({type: "archive-load", bank: 1, index: 1});
  await until(() => daemon.identity.source === "archive", 3000, "the load");
  await sleep(100);
  ws.drain();
  const kept = view(1, 1);

  ws.send({type: "archive-open", path: "/other.zip"});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "archive-open", code: "internal_error", message: "cannot keep archive path"});
  assert.deepEqual(await ws.next("archive"), kept, "the view the page already had");
  ws.send({type: "archive-close"});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "archive-close", code: "internal_error", message: "cannot forget archive path"});
  assert.deepEqual(await ws.next("archive"), kept);

  assert.equal(daemon.archive.rev, 1, "archive_rev did not move");
  assert.equal(daemon.archive.path, ARCHIVE_PATH);
  assert.deepEqual(daemon.identity.archivePatch, 1, "the playing patch still points into the open archive");
  assert.ok(!ws.ended, "the page stays connected");

  // The same requests go through once the daemon can keep the path again.
  daemon.keepFails = false;
  ws.send({type: "archive-open", path: "/other.zip"});
  assert.deepEqual(await ws.next("archive"),
    {type: "archive", rev: 2, open: true, path: "/other.zip", banks: ["x.zip"], bank: null, patches: []});
});

// -- older daemons ------------------------------------------------------------------

test("a daemon from before the shared archive is never asked for one and the page is never sent one", {skip}, async t => {
  const env = await startEnv(t, {daemon: {legacy: true}});
  const ws = await env.open();
  ws.send({type: "sync"});
  await until(() => ws.received.some(m => m.type === "midi"), 3000, "the sync");
  assert.deepEqual(ws.received.map(m => m.type), ["bank", "state", "patch", "midi"]);
  assert.deepEqual(ws.received[2], {type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
  ws.drain();
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  await peer.request("patch.load 5");
  assert.deepEqual(await ws.next("patch"),
    {type: "patch", name: "Bells", index: 5, bank: "My Bank", source: "bank", archive: null});
  for (const msg of [{type: "archive-open", path: ARCHIVE_PATH}, {type: "archive-bank", index: 0},
    {type: "archive-load", bank: 0, index: 0}, {type: "archive-close"}]) {
    ws.send(msg);
    assert.deepEqual(await ws.next("error"),
      {type: "error", for: msg.type, code: "unknown_command", message: "unknown command"});
  }
  await sleep(60);
  assert.deepEqual(ws.drain().filter(m => m.type === "archive"), []);
  assert.deepEqual(archiveCommands(env.daemon), ["archive.current", "archive.current", "archive.current",
    "archive.current"], "asked only what cannot change anything");
});

test("a request sent before sync is not run on a daemon from before the shared archive", {skip}, async t => {
  const env = await startEnv(t, {daemon: {legacy: true}});
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  // Such a daemon has archive verbs of its own, and with a bank open its
  // archive.load would load from it, reading only the index.
  assert.equal(await peer.request(`archive.open ${ARCHIVE_PATH}`), "1 1 ok banks=3");
  assert.equal(await peer.request("archive.bank 0"), "1 2 ok patches=8");
  const ws = await env.open();
  for (const msg of [{type: "archive-load", bank: 0, index: 1}, {type: "archive-close"}]) {
    ws.send(msg);
    assert.deepEqual(await ws.next("error"),
      {type: "error", for: msg.type, code: "unknown_command", message: "unknown command"});
  }
  await sleep(60);
  assert.deepEqual(archiveWrites(env.daemon), [`archive.open ${ARCHIVE_PATH}`, "archive.bank 0"], "only the peer's");
  assert.equal(env.daemon.identity.source, "none", "nothing was loaded");
  assert.deepEqual(ws.drain().filter(m => m.type === "archive"), []);
});

test("an older daemon's provenance is worked out from the names it gives", {skip}, async t => {
  const env = await startEnv(t, {daemon: {legacy: true}});
  const ws = await env.open();
  await ws.synced();
  const cases = [
    [{slot: -1, bank: "file", name: "Lead"}, "file"],
    [{slot: -1, bank: "aaa bbb Thanks Ms Ichiro 01.ZIP", name: "05_fx"}, "archive"],
    // A bank replaced under a slot load: the label stays, the slot goes.
    [{slot: -1, bank: "My Bank", name: "Bells"}, "bank"],
    [{slot: 3, bank: "My Bank", name: "Pluck"}, "bank"],
  ];
  for (const [identity, source] of cases) {
    env.daemon.identity = {...identity, source: "none", archiveBank: -1, archivePatch: -1};
    const patch = await ws.next("patch");
    assert.equal(patch.source, source, JSON.stringify(identity));
    assert.equal(patch.archive, null);
  }
});

test("a daemon with no archive support answers through the page's requests", {skip}, async t => {
  const env = await startEnv(t, {daemon: {archives: null}});
  const ws = await env.open();
  const {archive} = await ws.synced();
  assert.equal(archive, null);
  ws.send({type: "archive-open", path: ARCHIVE_PATH});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "archive-open", code: "daemon_not_ready", message: "no archive support"});
  await sleep(60);
  assert.deepEqual(ws.drain().filter(m => m.type === "archive"), []);
  assert.deepEqual(env.daemon.commands("archive.open"), []);
});

// -- provenance ---------------------------------------------------------------------

test("the patch message says where the sound came from, for every source", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("patch.load 3");
  assert.deepEqual(await ws.next("patch"),
    {type: "patch", name: 'Bass "Deep" \\ Ü\ttab', index: 3, bank: "My Bank", source: "bank", archive: null});
  // Patch 3 of an archive bank is not slot 3: the index stays null.
  await peer.request("archive.load 3 0");
  assert.deepEqual(await ws.next("patch"), {type: "patch", name: "Bells", index: null,
    bank: "aaa bbb Thanks Ms Ichiro 01.zip", source: "archive", archive: {bank: 0, patch: 3}});
  daemon.identity = {slot: -1, bank: "file", name: "From Disk", source: "file", archiveBank: -1, archivePatch: -1};
  assert.deepEqual(await ws.next("patch"),
    {type: "patch", name: "From Disk", index: null, bank: "file", source: "file", archive: null});
  await peer.request("patch.clear");
  assert.deepEqual(await ws.next("patch"),
    {type: "patch", name: "Untitled", index: null, bank: "", source: "none", archive: null});
});

test("browsing another archive bank, by any client, moves no provenance", {skip}, async t => {
  const {ws, peer} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("archive.load 6 0");
  const loaded = await ws.next(m => m.type === "patch" && m.source === "archive");
  assert.deepEqual(loaded.archive, {bank: 0, patch: 6});
  await ws.next("archive");
  await peer.request("archive.bank 1");
  assert.deepEqual(await ws.next("archive"), view(2, 1));
  ws.send({type: "archive-bank", index: 2});
  assert.deepEqual(await ws.next("archive"), {...view(3, 2), patches: []});
  assert.deepEqual(await ws.quiet(100, "patch"), [], "the sound still came from bank 0, patch 6");
});

// -- patch-step -----------------------------------------------------------------------

test("patch-step walks the archive bank the sound came from and wraps round it", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("archive.load 7 0");
  for (const [step, to] of [[1, 0], [-1, 7], [3, 2], [-11, 7]]) {
    const loads = daemon.commands("archive.load").length;
    ws.send({type: "patch-step", step});
    await until(() => daemon.commands("archive.load").length > loads, 3000, "a step");
    assert.equal(daemon.identity.archivePatch, to, `${step}`);
    assert.equal(daemon.identity.archiveBank, 0);
  }
  // Even with another bank open since: it is the sound's bank that is walked.
  await peer.request("archive.bank 1");
  ws.send({type: "patch-step", step: 1});
  await until(() => daemon.identity.archivePatch === 0, 3000, "the step");
  assert.equal(daemon.identity.archiveBank, 0);
  assert.deepEqual(daemon.published.values, ARCHIVE[0].patches[0].values);
  assert.deepEqual(daemon.commands("patch.load"), [], "never the ordinary bank");
});

test("patch-step from an archive patch whose archive has gone walks the ordinary bank", {skip}, async t => {
  const {ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  await peer.request("archive.load 1 0");
  await peer.request("archive.close");
  ws.send({type: "patch-step", step: 1});
  await until(() => daemon.identity.source === "bank", 3000, "the step");
  assert.deepEqual(daemon.commands("patch.load"), ["patch.load 0"]);
});

// -- sharing ------------------------------------------------------------------------------

test("an archive one page opens and browses reaches every page and client", {skip}, async t => {
  const {env, ws, peer, daemon} = await page(t);
  const other = await env.open();
  await other.synced();
  ws.send({type: "archive-open", path: ARCHIVE_PATH});
  assert.deepEqual(await other.next("archive"), view(1));
  ws.send({type: "archive-bank", index: 0});
  assert.deepEqual(await other.next("archive"), view(2, 0));
  assert.equal((await peer.request("archive.current")).split("\n")[0], "1 1 ok open=1 banks=3 bank=0 patches=8 archive_rev=2");
  // And what a peer does there reaches both pages.
  await peer.request("archive.bank 1");
  assert.deepEqual(await ws.next(m => m.type === "archive" && m.rev === 3), view(3, 1));
  assert.deepEqual(await other.next("archive"), view(3, 1));
  assert.equal(daemon.archive.bank, 1);
});

test("ordinary bank and patch changes from any client leave the shared archive as it was", {skip}, async t => {
  const {env, ws, peer, daemon} = await page(t, {daemon: {archivePath: ARCHIVE_PATH}});
  ws.send({type: "archive-bank", index: 1});
  await ws.next("archive");
  const other = await env.open();
  const {archive} = await other.synced();
  assert.deepEqual(archive, view(1, 1));
  await peer.request("patch.load 5");
  await peer.request("patch.save 20 Kept");
  await peer.request("patch.clear");
  // A whole bank from the other page, through the same file the adapter uses.
  other.send({type: "bank", text: JSON.stringify({
    format: "quesynth.bank", version: 1, name: "Another Bank", patches: [{name: "Only", parameters: {}}],
  })});
  await until(() => daemon.bank.label === "Another Bank", 3000, "the bank");
  other.send({type: "state", values: DEFAULTS.map((v, i) => (i === 19 ? 3 : v))});
  await until(() => daemon.commands("patch.apply").length === 1, 3000, "the apply");
  await sleep(100);
  assert.deepEqual(await peer.request("archive.current"),
    `1 4 ok open=1 banks=3 bank=1 patches=3 archive_rev=1\npath=${ARCHIVE_PATH}\nbank_name=bankB.zip`);
  assert.deepEqual(ws.drain().filter(m => m.type === "archive"), []);
  assert.deepEqual(other.drain().filter(m => m.type === "archive"), []);
  assert.deepEqual(strayTempDirs(), []);
});

test("nothing about an archive goes through a bank file", {skip}, async t => {
  const {ws, daemon} = await page(t);
  daemon.log = [];
  ws.send({type: "archive-open", path: ARCHIVE_PATH});
  ws.send({type: "archive-bank", index: 0});
  ws.send({type: "archive-load", bank: 0, index: 1});
  ws.send({type: "patch-step", step: 1});
  ws.send({type: "archive-close"});
  await until(() => daemon.commands("archive.close").length === 1, 3000, "the close");
  await sleep(60);
  assert.deepEqual(daemon.commands().filter(l => /^bank\.(load_file|write|keep)/.test(l)), []);
  assert.deepEqual(strayTempDirs(), []);
  assert.equal(daemon.identity.name, "Spaced  Lead", "the step loaded patch 2 before closing");
});
