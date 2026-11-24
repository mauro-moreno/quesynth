// The transport and the version-1 handshake (ui/bridge.js).
//
// The rule that matters: a page only speaks the new messages to a host that has
// spoken a version itself, and a transport that throws is a refused write, not a
// crash in the page's own message handler.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {createWindow} from "./support/dom.mjs";
import {UI, plain} from "./support/panel.mjs";

function bridge({post, before} = {}) {
  const window = createWindow();
  const sent = [];
  if (post !== null) window.synthPost = post || (text => { sent.push(JSON.parse(text)); });
  if (before) before(window);
  const file = path.join(UI, "bridge.js");
  vm.runInContext(fs.readFileSync(file, "utf8"), vm.createContext(window), {filename: file});
  const got = [];
  window.SynthBridge.onMessage(m => got.push(m));
  return {window, bridge: window.SynthBridge, sent, got};
}

test("the version this page speaks is stated, and a host that has said nothing is a legacy host", () => {
  const {bridge: b} = bridge();
  assert.equal(b.PROTOCOL, 1);
  assert.equal(b.version(), 0);
});

test("the first message with a version settles it, before any handler sees that message", () => {
  const {window, bridge: b, got} = bridge();
  let during = null;
  b.onMessage(() => { during = b.version(); });
  window.synthReceive(JSON.stringify({type: "state", values: []}));
  assert.equal(b.version(), 0, "a message with no version says nothing");
  window.synthReceive(JSON.stringify({type: "patch", name: "x", v: 1}));
  assert.equal(b.version(), 1);
  assert.equal(during, 1, "so a handler's reply to it can already be a version-1 message");
  assert.equal(got.length, 2);
});

test("a host newer than this page is spoken to in this page's version", () => {
  const {window, bridge: b} = bridge();
  window.synthReceive({type: "patch", v: 7});
  assert.equal(b.version(), 1);
});

test("nothing but a positive number counts as a version", () => {
  const {window, bridge: b} = bridge();
  for (const v of ["1", true, null, 0, -1, {}]) window.synthReceive({type: "patch", v});
  assert.equal(b.version(), 0);
});

test("a version-1 message is refused, and not sent, to a host that has not said it speaks them", () => {
  const {bridge: b, sent} = bridge();
  assert.equal(b.sendV1({type: "select"}), false);
  assert.equal(b.select("user", "My Bank", 3, "x"), false);
  assert.equal(b.restoreRetry(), false);
  assert.equal(b.restoreDiscard(), false);
  assert.deepEqual(sent, [], "the host never hears a type it would answer with an error");
});

test("once the host speaks, version-1 messages carry their version and the caller's message is left alone", () => {
  const {window, bridge: b, sent} = bridge();
  window.synthReceive({type: "bank", text: "{}", v: 1});
  const mine = {type: "restore-retry"};
  assert.equal(b.sendV1(mine), true);
  assert.deepEqual(plain(mine), {type: "restore-retry"}, "the object passed in is not edited");
  assert.equal(b.select("user", "My Bank", 42, "Glass Pad"), true);
  assert.equal(b.select("session", "", null, "Untitled"), true);
  assert.equal(b.restoreRetry(), true);
  assert.equal(b.restoreDiscard(), true);
  assert.deepEqual(plain(sent), [
    {v: 1, type: "restore-retry"},
    {v: 1, type: "select", origin: "user", bank: "My Bank", slot: 42, name: "Glass Pad"},
    {v: 1, type: "select", origin: "session", bank: "", slot: null, name: "Untitled"},
    {v: 1, type: "restore-retry"},
    {v: 1, type: "restore-discard"},
  ]);
});

test("a transport that throws is a refused write with the reason kept, not an exception", () => {
  let broken = true;
  const {window, bridge: b} = bridge({post: () => { if (broken) throw new Error("the view is gone"); }});
  assert.equal(b.error(), null);
  assert.doesNotThrow(() => assert.equal(b.setParam(1, 2), false));
  assert.equal(b.error(), "the view is gone");
  assert.doesNotThrow(() => assert.equal(b.requestState(), false));
  window.synthReceive({type: "patch", v: 1});
  assert.doesNotThrow(() => assert.equal(b.select("user", "x", 1, "y"), false));
  broken = false;
  assert.equal(b.setParam(1, 2), true);
  assert.equal(b.error(), null, "cleared by the next write that goes through");
});

test("a thrown string is recorded too", () => {
  const {bridge: b} = bridge({post: () => { throw "closed"; }});
  assert.equal(b.send({type: "sync"}), false);
  assert.equal(b.error(), "closed");
});

test("with no host at all a send is false and not an error", () => {
  const {bridge: b} = bridge({post: null});
  assert.equal(b.connected, false);
  assert.equal(b.send({type: "sync"}), false);
  assert.equal(b.error(), null);
  assert.equal(b.sendV1({type: "x"}), false);
});

test("a host inside the page is told apart by having claimed SynthVolume before the bridge looked", () => {
  assert.equal(bridge({before: w => { w.SynthVolume = () => {}; }}).bridge.inPage, true);
  assert.equal(bridge().bridge.inPage, false, "the bridge's own forwarder does not count");
  assert.equal(bridge({post: null, before: w => { w.SynthVolume = () => {}; }}).bridge.inPage, false, "no host, no host in the page");
});

test("the header of bridge.js documents every version-1 message", () => {
  const text = fs.readFileSync(path.join(UI, "bridge.js"), "utf8");
  const header = text.slice(0, text.indexOf("(function"));
  for (const word of ['"type":"select"', '"type":"restore-retry"', '"type":"restore-discard"', '"type":"restore"',
    '"type":"bank-saved"', '"origin"', '"readOnly"', "MissingBank", "InvalidProgram", "HostStateRejected",
    "StateVersionUnsupported", "PersistenceFailed", "bank, state, patch"]) {
    assert.ok(header.includes(word), `the header of bridge.js does not mention ${word}`);
  }
  // The section this change wrote is held to the repository's 80 columns; the
  // older text above it was not and is not this test's business.
  const written = header.slice(header.indexOf("// Version 1"));
  for (const line of written.split("\n")) assert.ok(line.length <= 80, `over 80 columns: ${line}`);
});
