// The whole panel, booted from its own scripts in the stand-in DOM, with a fake
// host that speaks the wire protocol of ui/bridge.js.
//
// Nothing here knows what the panel does with a message. The host is a pair of
// functions: what the page posted is written down as parsed JSON, and `send`
// delivers a message the way a native host does. So a test states the protocol
// (what the host said, what the page may reply) and the panel is free to change
// everything between the two.

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {fileURLToPath} from "node:url";
import {Event, createWindow, mountIndexSkeleton} from "./dom.mjs";

export const UI = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "ui");

// The order ui/index.html loads them in, minus host.js and bank.js (a test says
// what bank is compiled into the page) and minus the scripts that need a real
// browser (midi.js, options.js).
export const PANEL = ["params.js", "layout.js", "bridge.js", "app.js", "sy1.js", "patchfile.js", "modal.js", "browser.js"];

function run(scripts, context) {
  for (const name of scripts) {
    const file = path.join(UI, name);
    vm.runInContext(fs.readFileSync(file, "utf8"), context, {filename: file});
  }
}

// The 99 stored integers of a patch with every parameter at its default, as
// plain numbers: the realm of the vm's arrays is not this one's.
export function defaults() {
  return Array.from(createParams(), p => p.def);
}

// The name each parameter has in a `quesynth.bank` document, by index.
export const PARAM_NAMES = Array.from(createParams(), p => p.name);

// Anything read out of the page, as a value of this realm, so that `deepEqual`
// does not fail on the prototype of an array the vm made.
export function plain(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

// A sound that is recognisably somebody's: the defaults with the cutoff moved.
// `seed` is the cutoff, so two sounds with different seeds differ.
export function sound(seed) {
  const values = defaults();
  values[19] = seed;
  return values;
}

// A compiled-in bank: `names` are the patches, in slot order, `null` an empty
// slot. Each patch's cutoff is its slot number plus `base`.
export function compiledBank(label, names, base = 10) {
  return {label, patches: names.map((n, i) => n === null ? null : {n, v: sound(base + i)})};
}

// A `quesynth.bank` document as a host sends it, with the same cutoff rule.
export function bankText(label, names, base = 10) {
  const params = Array.from(createParams());
  return JSON.stringify({
    format: "quesynth.bank", version: 1, name: label,
    patches: names.map((n, i) => {
      if (n === null) return null;
      const parameters = {};
      const values = sound(base + i);
      params.forEach((p, k) => { parameters[p.name] = values[k]; });
      return {name: n, parameters};
    }),
  });
}

function createParams() {
  const window = createWindow();
  vm.runInContext(fs.readFileSync(path.join(UI, "params.js"), "utf8"), vm.createContext(window));
  return window.SYNTH1_PARAMS;
}

// Boot the panel.
//
//   host      "generic" (window.synthPost, what the standalone daemon's page and
//             the wasm build use), "webview2" (what a Windows plugin has),
//             or null for no host at all.
//   bank      what bank.js would have compiled into the page, or undefined.
//   store     true to load store.js over an in-memory localStorage, which is
//             the browser build.
//   scripts   the page's scripts, in order.
//   before    called with the window before any script runs.
export function bootPanel({host = "generic", bank, store = false, scripts = PANEL, before} = {}) {
  const window = createWindow();
  mountIndexSkeleton(window.document);
  const sent = [];
  let deliver = null;

  if (host === "generic") {
    window.synthPost = text => { sent.push(JSON.parse(text)); };
  } else if (host === "webview2") {
    window.chrome = {
      webview: {
        postMessage: text => { sent.push(JSON.parse(text)); },
        addEventListener: (type, fn) => { if (type === "message") deliver = fn; },
      },
    };
  }

  if (bank) window.SYNTH1_BANK = bank;
  const files = new Map();
  window.localStorage = {
    getItem: key => files.has(key) ? files.get(key) : null,
    setItem: (key, value) => { files.set(key, String(value)); },
    removeItem: key => { files.delete(key); },
  };
  if (before) before(window);

  const context = vm.createContext(window);
  run(scripts.slice(0, scripts.indexOf("app.js") + 1), context);
  const rest = scripts.slice(scripts.indexOf("app.js") + 1);
  if (store) rest.push("store.js");
  run(rest, context);
  window.document.dispatchEvent(new Event("DOMContentLoaded"));

  const doc = window.document;
  const page = {
    window, document: doc, sent, files,
    // Delivered the way a native host does: as a JSON string.
    send(message) {
      const text = JSON.stringify(message);
      if (deliver) deliver({data: text}); else window.synthReceive(text);
    },
    ofType: type => sent.filter(m => m.type === type),
    forget: () => { sent.length = 0; },
    $: id => doc.getElementById(id),
    text: id => doc.getElementById(id).textContent,
    key(key, init = {}) {
      const event = new Event("keydown", {key, ...init});
      doc.dispatchEvent(event);
      return event;
    },
    values: () => Array.from(window.SynthPatch.values()),
  };
  return page;
}

// The messages a plugin host answers `sync` with, in the order the protocol
// fixes: bank, state, patch, then restore if one was requested.
export function syncAnswer({label = "Alfmeister Bank", names, origin = "imported", readOnly = false,
  state, slot, name, restore} = {}) {
  const out = [{type: "bank", text: bankText(label, names), v: 1, origin, readOnly}];
  if (state) out.push({type: "state", values: state});
  if (slot !== undefined) out.push({type: "patch", name, index: slot, bank: label, v: 1, origin});
  if (restore) out.push(restore);
  return out;
}
