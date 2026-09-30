"use strict";
// The adapter's reading of a quesynth.bank document, which is only ever a
// cache of the one the daemon owns: kept so a `state` from the page can be
// recognised as "slot k of the bank this page was shown" (and turned into a
// patch.load the daemon records), and so the page's echo of a bank it was
// sent can be told apart from a real request.
//
// It reads a document the way ui/patchfile.js does, not the way
// src/patch/json.odin does, because what it predicts is what the *page* will
// send back after loading it.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// patch.FACTORY_SLOTS and BANK_SLOTS in ui/app.js.
const SLOTS = 128;

// Names and defaults from the page's own table, so the adapter cannot drift
// from what the page is about to do with the same document.
function loadParams(root) {
  const file = path.join(root, "ui", "params.js");
  const sandbox = { window: {} };
  vm.runInNewContext(fs.readFileSync(file, "utf8"), sandbox, { filename: file, timeout: 1000 });
  const table = sandbox.window.SYNTH1_PARAMS;
  if (!Array.isArray(table) || !table.length) throw new Error(`${file} defines no parameters`);
  const byName = new Map();
  const defaults = [];
  for (const p of table) {
    byName.set(String(p.name), p.i);
    defaults[p.i] = p.def;
  }
  return { count: table.length, byName, defaults };
}

// Throws where ui/patchfile.js loadText would, so a document this rejects is
// one the page will not adopt either (and therefore will not echo).
function parseBank(text, params) {
  const doc = JSON.parse(text);
  if (!doc || doc.format !== "quesynth.bank") throw new Error("not a quesynth.bank document");
  if (doc.version !== undefined && doc.version > 1) throw new Error("bank from a newer version");
  if (!Array.isArray(doc.patches) || !doc.patches.length) throw new Error("the bank has no patches");
  const slots = new Array(SLOTS).fill(null);
  doc.patches.slice(0, SLOTS).forEach((entry, k) => {
    if (!entry) return;
    const given = entry.parameters || {};
    for (const key of Object.keys(given)) {
      if (!params.byName.has(key)) throw new Error(`unknown parameter: ${key}`);
    }
    const values = params.defaults.slice();
    for (const [name, i] of params.byName) {
      if (Object.prototype.hasOwnProperty.call(given, name)) values[i] = Math.round(Number(given[name]));
    }
    // `raw` is what the document said, for the one place (a store) where an
    // absent name must not be mistaken for the "Patch" the page would show.
    slots[k] = {
      name: entry.name || "Patch",
      raw: typeof entry.name === "string" ? entry.name : "",
      values,
    };
  });
  return { label: doc.name || "Bank", slots };
}

function sameValues(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// The filled slot holding exactly these values: `preferred` when it does (two
// slots can hold the same sound, and the one already loaded is the one meant),
// else the lowest. -1 when none does.
function findSlot(model, values, preferred) {
  if (!model) return -1;
  const at = model.slots[preferred];
  if (at && sameValues(at.values, values)) return preferred;
  return model.slots.findIndex(s => s !== null && sameValues(s.values, values));
}

// What the page sends back after adopting the bank: slot 0, or Init when slot
// 0 is empty (loadPatch(0) in ui/app.js).
function adoptionValues(model, params) {
  return model.slots[0] ? model.slots[0].values : params.defaults;
}

function sameSlot(a, b) {
  if (!a || !b) return a === b;
  return a.name === b.name && a.raw === b.raw && sameValues(a.values, b.values);
}

// The slot a page stored its live sound into, or -1 when the document is
// anything else. The page has no message for a store: it posts the whole bank
// with one slot changed, which is what the daemon's patch.save already means
// (and records as the identity), where a whole-bank adoption would leave the
// identity naming no slot. So it must be exactly that: the same bank with ONE
// slot newly filled with a usable name and the very values the page shows.
// Anything doubtful stays a whole-bank adoption, which is always correct,
// just less informative. The parameters in `hidden` are not compared: the
// daemon cannot report them, so the page's copy is only a guess.
function storedSlot(before, after, live, hidden) {
  if (!before || !after || !live) return -1;
  if (before.label !== after.label || before.slots.length !== after.slots.length) return -1;
  let slot = -1;
  for (let i = 0; i < after.slots.length; i++) {
    if (sameSlot(before.slots[i], after.slots[i])) continue;
    if (slot >= 0) return -1;
    slot = i;
  }
  const stored = slot >= 0 ? after.slots[slot] : null;
  if (!stored || !stored.raw.trim()) return -1;
  // The name goes to the end of a command line, where these would end it.
  if (/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(stored.raw)) return -1;
  for (let i = 0; i < stored.values.length; i++) {
    if (!hidden.includes(i) && stored.values[i] !== live[i]) return -1;
  }
  return slot;
}

module.exports = {
  loadParams, parseBank, sameValues, findSlot, adoptionValues, storedSlot,
};
