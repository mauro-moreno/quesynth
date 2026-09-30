// The daemon's MIDI input selection, seen through the adapter and the real
// panel. The daemon reads the devices itself, so a page hosted by it must
// never open Web MIDI as well: the same keyboard would be heard twice. The
// page only shows the daemon's selection and asks to change it.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {Event, createWindow, mountIndexSkeleton} from "../ui/support/dom.mjs";
import {ROOT, connectRaw} from "./support/fake-daemon.mjs";
import {startEnv, unix, until} from "./support/harness.mjs";
import {sleep} from "./support/ws-client.mjs";

const skip = !unix;
const skipPage = !unix || typeof WebSocket !== "function";

// Two inputs whose names have spaces; the ids are the ALSA ones.
const INPUTS = [
  {id: "hw:1,0", name: "Launchkey MK3 MIDI 1"},
  {id: "hw:2,0", name: "USB Keyboard"},
];

async function page(t, options = {}) {
  const env = await startEnv(t, {...options, daemon: {midiInputs: INPUTS.slice(), ...options.daemon}});
  const ws = await env.open();
  const {midi} = await ws.synced();
  return {env, ws, daemon: env.daemon, midi};
}

async function withPeer(t, env) {
  const peer = await connectRaw(env.socketPath);
  t.after(() => peer.close());
  return peer;
}

function midiCommands(daemon) {
  return daemon.commands().filter(line => line.startsWith("midi."));
}

// -- the stand-in daemon ------------------------------------------------------

// Everything below trusts the stand-in to answer as the daemon does, so its
// answers are checked against the protocol's own text, written out by hand.
test("the stand-in daemon speaks midi.list, midi.select and midi.current as the protocol says", {skip}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: [...INPUTS, {id: "hw:3,0", name: "Broken", fails: true}]}});
  const peer = await withPeer(t, env);
  assert.equal(await peer.request("midi.current"), "1 1 ok selected=all midi_rev=0\nname=All inputs");
  assert.equal(await peer.request("midi.list"),
    "1 2 ok count=3 selected=all midi_rev=0\nid=hw:1,0 name=Launchkey MK3 MIDI 1\n" +
    "id=hw:2,0 name=USB Keyboard\nid=hw:3,0 name=Broken");
  assert.equal(await peer.request("midi.select hw:2,0"), "1 3 ok selected=hw:2,0 midi_rev=1");
  assert.equal(await peer.request("midi.select hw:2,0"), "1 4 ok selected=hw:2,0 midi_rev=1");
  assert.equal(await peer.request("midi.current"), "1 5 ok selected=hw:2,0 midi_rev=1\nname=USB Keyboard");
  assert.equal(await peer.request("midi.select"),
    "1 6 err invalid_payload midi.select needs all, none or an input id");
  assert.equal(await peer.request("midi.select all none"),
    "1 7 err invalid_payload midi.select needs all, none or an input id");
  assert.equal(await peer.request("midi.select hw:9,0"), "1 8 err invalid_payload no such midi input");
  assert.equal(await peer.request("midi.select hw:3,0"), "1 9 err internal_error cannot open midi input");
  assert.equal(await peer.request("midi.select none"), "1 10 ok selected=none midi_rev=2");
  assert.equal(await peer.request("midi.current"), "1 11 ok selected=none midi_rev=2\nname=None");
  env.daemon.midiInputs = [];
  assert.equal(await peer.request("midi.list"), "1 12 ok count=0 selected=none midi_rev=2");
  env.daemon.midiInputs = null;
  for (const [n, line] of [[13, "midi.list"], [14, "midi.select all"], [15, "midi.current"]]) {
    assert.equal(await peer.request(line), `1 ${n} err daemon_not_ready no midi input`);
  }
});

// -- daemon -> page -----------------------------------------------------------

test("sync ends with the daemon's MIDI selection and its inputs", {skip}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: INPUTS.slice()}});
  const ws = await env.open();
  ws.send({type: "sync"});
  await until(() => ws.received.length >= 4, 3000, "four messages");
  assert.deepEqual(ws.received.map(m => m.type), ["bank", "state", "patch", "midi"]);
  assert.deepEqual(ws.received[3], {
    type: "midi",
    inputs: [{id: "hw:1,0", name: "Launchkey MK3 MIDI 1"}, {id: "hw:2,0", name: "USB Keyboard"}],
    selected: "all",
    name: "All inputs",
    rev: 0,
  });
  // Then polled, which is only midi.current until midi_rev moves.
  assert.deepEqual(midiCommands(env.daemon).slice(0, 2), ["midi.current", "midi.list"]);
});

// The daemon ends a record line at \n alone and carries the name raw to it.
// To JavaScript U+2028 and U+2029 end a line too, and a device's USB product
// string may hold either: such an input must not drop out of the page's list.
test("every input the daemon lists reaches the page, its name as written", {skip}, async t => {
  const odd = [{id: "hw:1,0", name: "  Pad  "}, {id: "hw:10,1", name: "Sep\u2028arator\u2029"}];
  const env = await startEnv(t, {daemon: {midiInputs: odd.slice()}});
  const ws = await env.open();
  const {midi} = await ws.synced();
  assert.deepEqual(midi.inputs, odd);
});

test("a selection another client makes reaches every page, and only once", {skip}, async t => {
  const {env, ws} = await page(t);
  const other = await env.open();
  await other.synced();
  const peer = await withPeer(t, env);
  assert.equal(await peer.request("midi.select hw:2,0"), "1 1 ok selected=hw:2,0 midi_rev=1");
  const expected = {type: "midi", inputs: INPUTS, selected: "hw:2,0", name: "USB Keyboard", rev: 1};
  assert.deepEqual(await ws.next("midi"), expected);
  assert.deepEqual(await other.next("midi"), expected);
  assert.deepEqual(await ws.quiet(120, "midi"), [], "a midi_rev that has not moved is not announced");
});

test("midi-list asks the daemon again, so an input plugged in since shows up", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const lists = daemon.commands("midi.list").length;
  daemon.midiInputs.push({id: "hw:3,0", name: "Pad Controller"});
  assert.deepEqual(await ws.quiet(100, "midi"), [], "plugging in moves no midi_rev");
  assert.equal(daemon.commands("midi.list").length, lists, "the poll does not enumerate");
  ws.send({type: "midi-list"});
  assert.deepEqual(await ws.next("midi"), {
    type: "midi", inputs: [...INPUTS, {id: "hw:3,0", name: "Pad Controller"}], selected: "all", name: "All inputs", rev: 0,
  });
  assert.equal(daemon.commands("midi.list").length, lists + 1);
});

// -- page -> daemon -----------------------------------------------------------

test("midi-select becomes midi.select, answered with the daemon's selection", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const steps = [["hw:2,0", "USB Keyboard", 1], ["none", "None", 2], ["all", "All inputs", 3], ["all", "All inputs", 3]];
  for (const [id, name, rev] of steps) {
    ws.send({type: "midi-select", id});
    assert.deepEqual(await ws.next("midi"), {type: "midi", inputs: INPUTS, selected: id, name, rev});
  }
  assert.deepEqual(daemon.commands("midi.select"),
    ["midi.select hw:2,0", "midi.select none", "midi.select all", "midi.select all"]);
  assert.deepEqual(await ws.quiet(100, "midi"), [], "the page's own change is not announced to it twice");
});

test("a midi-select id that is not one plain token is refused before any command is built", {skip}, async t => {
  const {ws, daemon} = await page(t);
  const bad = [
    {}, {id: 1}, {id: null}, {id: ""}, {id: ["all"]}, {id: "hw:1,0 hw:2,0"},
    {id: "all\n1 9 daemon.shutdown"}, {id: "hw:1,0\r"}, {id: "a\tb"}, {id: "\u0000all"},
    {id: "all\u0085"}, {id: "all\u00a0"}, {id: "x".repeat(257)},
  ];
  for (const fields of bad) {
    ws.send({type: "midi-select", ...fields});
    assert.deepEqual(await ws.next("error"), {type: "error", for: "midi-select", code: "invalid_payload",
      message: "midi-select needs all, none or an input id"}, JSON.stringify(fields));
  }
  await ws.synced();
  assert.deepEqual(daemon.commands("midi.select"), []);
  assert.equal(daemon.midiSelected, "all");
});

test("a selection the daemon refuses is reported, and the page is sent the one it kept", {skip}, async t => {
  const broken = {id: "hw:3,0", name: "Broken", fails: true};
  const {ws, daemon} = await page(t, {daemon: {midiInputs: [...INPUTS, broken]}});
  const kept = {type: "midi", inputs: [...INPUTS, {id: "hw:3,0", name: "Broken"}], selected: "all",
    name: "All inputs", rev: 0};
  ws.send({type: "midi-select", id: "hw:9,0"});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "midi-select", code: "invalid_payload", message: "no such midi input"});
  assert.deepEqual(await ws.next("midi"), kept);
  ws.send({type: "midi-select", id: "hw:3,0"});
  assert.deepEqual(await ws.next("error"),
    {type: "error", for: "midi-select", code: "internal_error", message: "cannot open midi input"});
  assert.deepEqual(await ws.next("midi"), kept);
  assert.deepEqual(daemon.commands("midi.select"), ["midi.select hw:9,0", "midi.select hw:3,0"]);
  assert.equal(ws.ended, false);
});

// -- daemons with nothing to select -------------------------------------------

const UNAVAILABLE = {type: "midi", inputs: [], selected: null, name: null, rev: null};

for (const [what, daemon, code] of [
  // What the daemon answers any command it does not have.
  ["an older daemon that has no MIDI selection", {intercept: req => (req.command.startsWith("midi.")
    ? {err: ["unknown_command", "unknown command"]} : undefined)}, "unknown_command"],
  ["a daemon with no MIDI input", {midiInputs: null}, "daemon_not_ready"],
]) {
  test(`${what} leaves the page open and told there is nothing to select`, {skip}, async t => {
    const env = await startEnv(t, {daemon: {midiInputs: daemon.midiInputs === null ? null : INPUTS.slice()}});
    env.daemon.intercept = daemon.intercept || null;
    const peer = await withPeer(t, env);
    const ws = await env.open();
    const {midi} = await ws.synced();
    assert.deepEqual(midi, UNAVAILABLE);

    // Still kept in step, where a refused patch.current would have closed it.
    await peer.request("parameter.set filter.cutoff 33");
    assert.deepEqual(await ws.next("param"), {type: "param", index: 19, value: 33});
    const asked = env.daemon.commands("midi.current").length;
    await new Promise(resolve => setTimeout(resolve, 120));
    assert.equal(env.daemon.commands("midi.current").length, asked, "an answer that cannot change is not polled");

    ws.send({type: "midi-select", id: "all"});
    const error = await ws.next("error");
    assert.deepEqual([error.for, error.code], ["midi-select", code]);
    assert.deepEqual(await ws.next("midi"), UNAVAILABLE);
    ws.send({type: "midi-list"});
    assert.deepEqual(await ws.next("midi"), UNAVAILABLE);
    assert.equal(ws.ended, false);
    assert.equal(env.bridge.sessions, 1);
  });
}

// -- the real panel -----------------------------------------------------------

// ui/index.html's scripts in its order, without the two the adapter withholds,
// as in panel-native.test.mjs. Without host.js it is a page no host claims
// MIDI for: a plain browser, the WebAssembly build, a plugin's web view.
const SCRIPTS = ["host.js", "params.js", "layout.js", "bridge.js", "app.js", "midi.js", "sy1.js",
  "midimap.js", "patchfile.js", "modal.js", "browser.js", "options.js"];

// Web MIDI as a browser would offer it, with every touch written down:
// reading navigator.requestMIDIAccess at all, and any property of the access
// object or of an input read or written. `raw` are the inputs themselves, to
// look at without being recorded.
function webMidi(window, devices) {
  const touched = [];
  const watch = (name, target) => new Proxy(target, {
    get(t, key) { touched.push(`${name}.${String(key)}`); return t[key]; },
    set(t, key, value) { touched.push(`${name}.${String(key)} =`); t[key] = value; return true; },
    has(t, key) { touched.push(`${name} has ${String(key)}`); return key in t; },
    defineProperty(t, key, d) { touched.push(`${name} define ${String(key)}`); return Reflect.defineProperty(t, key, d); },
  });
  const raw = devices.map(d => ({...d, state: "connected", onmidimessage: undefined}));
  const inputs = raw.map((input, i) => watch(`input${i}`, input));
  const access = watch("access", {inputs: new Map(inputs.map((input, i) => [raw[i].id, input])), onstatechange: null});
  let requests = 0;
  const request = () => {
    requests++;
    return Promise.resolve(access);
  };
  Object.defineProperty(window.navigator, "requestMIDIAccess", {
    get() {
      touched.push("navigator.requestMIDIAccess");
      return request;
    },
  });
  return {touched, raw, inputs, get requests() { return requests; }};
}

// The stand-in DOM keeps a text node's text in `data` and has no nodeValue,
// which a real DOM makes the same thing. midi.js writes the button's label
// through nodeValue, so without this no label would ever seem to change.
function withNodeValue(document) {
  const text = Object.getPrototypeOf(document.createTextNode(""));
  if (Object.getOwnPropertyDescriptor(text, "nodeValue")) return;
  Object.defineProperty(text, "nodeValue", {
    get() { return this.data; },
    set(value) { this.data = String(value); },
  });
}

function bootPanel({port, hosted, devices = [{id: "web-1", name: "Keystation 49"}, {id: "web-2", name: "Pad Box"}]}) {
  const window = createWindow();
  withNodeValue(window.document);
  mountIndexSkeleton(window.document);
  const midi = webMidi(window, devices);
  const sent = [];
  const sockets = [];
  if (hosted) {
    window.location = {protocol: "http:", host: `127.0.0.1:${port}`};
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
  } else {
    // A host that forwards messages and claims nothing, as a plugin's web
    // view does, so what the page posts can be seen.
    window.synthPost = text => sent.push(JSON.parse(text));
  }
  const context = vm.createContext(window);
  for (const name of hosted ? SCRIPTS : SCRIPTS.slice(1)) {
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
  const button = window.document.getElementById("midi-toggle");
  return {
    window,
    sent,
    got,
    midi,
    button,
    label: () => button.textContent,
    list: () => window.document.querySelector(".midi-list"),
    // Each line of the open list: its text, and aria-current on a button.
    rows: () => window.document.querySelector(".midi-list").children
      .map(el => [el.textContent, el.localName === "button" ? el.getAttribute("aria-current") : el.className]),
    close: () => sockets.forEach(s => s.close()),
  };
}

async function hostedPage(t, env) {
  const p = bootPanel({port: env.port, hosted: true});
  t.after(() => p.close());
  await until(() => p.got.some(m => m.type === "midi"), 5000, "the daemon's MIDI selection");
  return p;
}

test("a page the daemon hosts never touches Web MIDI, whatever is done to it", {skip: skipPage}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: INPUTS.slice()}});
  const p = await hostedPage(t, env);
  p.button.click();
  await until(() => p.got.filter(m => m.type === "midi").length === 2, 3000, "the fresh list");
  p.list().children[1].click();
  await until(() => env.daemon.midiSelected === "hw:1,0", 3000, "the selection");
  // Handed an input directly, as a test or another script could.
  p.window.SynthMidi.connect(p.midi.inputs[0]);
  p.window.SynthMidi.connect(null);
  await sleep(100);

  assert.deepEqual(p.midi.touched, [], "not even navigator.requestMIDIAccess is read");
  assert.equal(p.midi.requests, 0);
  assert.equal(p.midi.raw[0].onmidimessage, undefined, "no input is ever listened to");
  assert.equal(p.window.SynthMidi.connected(), null);
  assert.equal(p.label(), "Launchkey MK3 MIDI 1", "the button still says what the daemon has");
  // What reached the daemon's MIDI queue from this page: nothing.
  assert.deepEqual(env.daemon.midi, []);
});

test("the MIDI button shows the daemon's selection, and choosing an input only asks for it", {skip: skipPage}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: INPUTS.slice()}});
  const p = await hostedPage(t, env);
  assert.equal(p.label(), "All MIDI");
  assert.deepEqual(p.sent.filter(m => m.type.startsWith("midi")), [], "nothing asked at load: sync brings it");

  p.button.click();
  assert.deepEqual(p.sent.at(-1), {type: "midi-list"});
  assert.ok(p.list().classList.contains("open"));
  assert.deepEqual(p.rows(), [
    ["All inputs", "true"], ["Launchkey MK3 MIDI 1", "false"], ["USB Keyboard", "false"], ["None", "false"],
  ]);

  const before = p.sent.length;
  p.list().children[2].click();
  assert.deepEqual(p.sent.slice(before), [{type: "midi-select", id: "hw:2,0"}]);
  assert.equal(p.list().classList.contains("open"), false);
  assert.equal(p.label(), "All MIDI", "nothing is shown until the daemon answers");
  await until(() => p.label() === "USB Keyboard", 3000, "the daemon's answer on the button");
  assert.equal(env.daemon.midiSelected, "hw:2,0");
  const listed = p.got.length;
  p.button.click();
  assert.deepEqual(p.rows(), [
    ["All inputs", "false"], ["Launchkey MK3 MIDI 1", "false"], ["USB Keyboard", "true"], ["None", "false"],
  ]);
  await until(() => p.got.length > listed, 3000, "the answer to midi-list");

  // A choice the daemon refuses leaves the page showing what the daemon has.
  env.daemon.intercept = req => (req.command === "midi.select" ? {err: ["internal_error", "cannot open midi input"]} : undefined);
  const answers = p.got.length;
  p.list().children[3].click();
  assert.deepEqual(p.sent.at(-1), {type: "midi-select", id: "none"});
  await until(() => p.got.slice(answers).some(m => m.type === "midi"), 3000, "the daemon's selection again");
  assert.deepEqual(p.got.slice(answers).map(m => m.type), ["error", "midi"]);
  assert.equal(p.label(), "USB Keyboard");
  p.button.click();
  assert.deepEqual(p.rows().map(r => r[1]), ["false", "false", "true", "false"]);
});

test("a selection made elsewhere moves the button and an open list", {skip: skipPage}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: INPUTS.slice()}});
  const peer = await withPeer(t, env);
  const p = await hostedPage(t, env);
  await peer.request("midi.select none");
  await until(() => p.label() === "MIDI off", 3000, "none on the button");
  p.button.click();
  assert.deepEqual(p.rows().map(r => r[1]), ["false", "false", "false", "true"]);
  await peer.request("midi.select hw:1,0");
  await until(() => p.rows()[1][1] === "true", 3000, "the open list to follow");
  assert.equal(p.label(), "Launchkey MK3 MIDI 1");
  assert.ok(p.list().classList.contains("open"));
});

test("inputs that share a name are told apart by id, on the row and on the button", {skip: skipPage}, async t => {
  const twins = [
    {id: "hw:1,0", name: "USB MIDI Interface"},
    {id: "hw:2,0", name: "USB MIDI Interface"},
    {id: "hw:3,0", name: "Pad Box"},
  ];
  const env = await startEnv(t, {daemon: {midiInputs: twins}});
  const p = await hostedPage(t, env);
  p.button.click();
  assert.deepEqual(p.rows(), [
    ["All inputs", "true"], ["USB MIDI Interface (hw:1,0)", "false"], ["USB MIDI Interface (hw:2,0)", "false"],
    ["Pad Box", "false"], ["None", "false"],
  ]);

  const before = p.sent.length;
  p.list().children[2].click();
  assert.deepEqual(p.sent.slice(before), [{type: "midi-select", id: "hw:2,0"}]);
  await until(() => p.label() === "USB MIDI Interface (hw:2,0)", 3000, "the disambiguated button");

  p.list().children[3].click();
  await until(() => p.label() === "Pad Box", 3000, "the unique name alone on the button");
});

test("with no inputs the list says so and still offers all and none", {skip: skipPage}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: []}});
  const p = await hostedPage(t, env);
  p.button.click();
  assert.deepEqual(p.rows(), [["All inputs", "true"], ["No inputs found", "midi-none"], ["None", "false"]]);
});

test("a page on an older daemon has no selection to show, and still no Web MIDI", {skip: skipPage}, async t => {
  const env = await startEnv(t, {daemon: {midiInputs: INPUTS.slice()}});
  env.daemon.intercept = req => (req.command.startsWith("midi.") ? {err: ["unknown_command", "unknown command"]} : undefined);
  const p = await hostedPage(t, env);
  assert.equal(p.label(), "MIDI");
  p.button.click();
  await until(() => p.got.filter(m => m.type === "midi").length === 2, 3000, "the answer to midi-list");
  assert.deepEqual(p.rows(), [["Selection unavailable", "midi-none"]]);
  assert.deepEqual(p.midi.touched, []);
  assert.equal(p.window.document.documentElement.dataset.hostError, undefined, "still connected");
});

test("a page no host claims MIDI for opens Web MIDI itself, as it always has", async () => {
  const p = bootPanel({hosted: false});
  const w = p.window;
  assert.equal(w.SynthBridge.host, "generic");
  assert.equal(p.label(), "MIDI");
  assert.equal(p.midi.requests, 0, "nothing is asked for before the button is pressed");

  p.button.click();
  assert.equal(p.midi.requests, 1);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(p.rows(), [["Keystation 49", "false"], ["Pad Box", "false"]]);
  p.list().children[0].click();
  assert.equal(p.midi.raw[0].onmidimessage, w.SynthMidi.handleMessage);
  assert.equal(p.label(), "Keystation 49");
  assert.equal(w.SynthMidi.connected(), "Keystation 49");

  // Attached from outside, it moves the one handler rather than adding one.
  w.SynthMidi.connect(p.midi.inputs[1]);
  assert.equal(p.midi.raw[0].onmidimessage, null);
  assert.equal(p.midi.raw[1].onmidimessage, w.SynthMidi.handleMessage);
  p.midi.raw[1].onmidimessage({data: [0x90, 60, 100]});
  assert.deepEqual(p.sent.at(-1), {type: "note", on: true, note: 60, velocity: 100, channel: 0});
  assert.deepEqual(p.sent.filter(m => m.type.startsWith("midi")), [], "no host selection is asked for");
});
