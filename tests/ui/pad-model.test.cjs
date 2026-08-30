"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const model = require("../../ui/pad-model.js");

const PARAMETERS = [
  { i: 0, def: 10 },
  { i: 1, def: 20 },
  { i: 2, def: 30 },
];

function kitWithNote(note = 36) {
  const kit = model.createKit(PARAMETERS);
  kit.pads.forEach((pad) => {
    pad.note = 127;
  });
  kit.pads[0].note = note;
  return kit;
}

test("createPad returns the complete rack-slot defaults", () => {
  assert.deepEqual(model.createPad(2, PARAMETERS), {
    id: "pad-3",
    name: "Pad 3",
    note: 38,
    root_note: 60,
    trigger_mode: "gate",
    velocity: 1,
    volume: 1,
    pan: 0,
    choke_group: 0,
    enabled: true,
    mute: false,
    solo: false,
    patch_name: "Init",
    patch_bank: "",
    patch_index: null,
    values: [10, 20, 30],
  });
});

test("createKit creates sixteen independent pads and patch arrays", () => {
  const first = model.createKit(PARAMETERS);
  const second = model.createKit(PARAMETERS);

  assert.equal(first.format, model.FORMAT);
  assert.equal(first.version, model.VERSION);
  assert.equal(first.name, "Untitled Kit");
  assert.equal(first.mapping, "chromatic");
  assert.equal(first.midi_channel, "omni");
  assert.equal(first.selected, 0);
  assert.equal(first.pads.length, model.PAD_COUNT);
  assert.deepEqual(first.pads.map((pad) => pad.note),
    Array.from({ length: model.PAD_COUNT }, (_, index) => model.FIRST_NOTE + index));

  assert.notStrictEqual(first.pads[0], first.pads[1]);
  assert.notStrictEqual(first.pads[0].values, first.pads[1].values);
  assert.notStrictEqual(first.pads[0], second.pads[0]);
  assert.notStrictEqual(first.pads[0].values, second.pads[0].values);

  first.pads[0].name = "Changed";
  first.pads[0].values[0] = 99;
  assert.equal(first.pads[1].name, "Pad 2");
  assert.equal(first.pads[1].values[0], 10);
  assert.equal(second.pads[0].name, "Pad 1");
  assert.equal(second.pads[0].values[0], 10);
});

test("normalizePad trims identity fields, rounds numbers, and clamps rack metadata", () => {
  const longName = `  ${"n".repeat(60)}  `;
  const pad = model.normalizePad({
    id: "custom-id",
    name: longName,
    note: 200.4,
    root_note: -8.7,
    trigger_mode: "one-shot",
    velocity: 4,
    volume: -1,
    pan: 3,
    choke_group: 20,
    enabled: 0,
    mute: 1,
    solo: "yes",
    patch: { name: "  Source Patch  ", bank: "Factory", index: 300 },
    values: [1.2, Number.NaN, 28.7, Number.POSITIVE_INFINITY],
  }, 4, PARAMETERS);

  assert.equal(pad.id, "custom-id");
  assert.equal(pad.name, "n".repeat(48));
  assert.equal(pad.note, 127);
  assert.equal(pad.root_note, 0);
  assert.equal(pad.trigger_mode, "one-shot");
  assert.equal(pad.velocity, 2);
  assert.equal(pad.volume, 0);
  assert.equal(pad.pan, 1);
  assert.equal(pad.choke_group, 8);
  assert.equal(pad.enabled, false);
  assert.equal(pad.mute, true);
  assert.equal(pad.solo, true);
  assert.equal(pad.patch_name, "  Source Patch  ");
  assert.equal(pad.patch_bank, "Factory");
  assert.equal(pad.patch_index, 127);
  assert.deepEqual(pad.values, [1, 20, 29]);
});

test("normalizePad supplies safe fallbacks and accepts supported patch value shapes", () => {
  const fallback = model.normalizePad({
    id: "",
    name: "   ",
    note: Number.NaN,
    root_note: "bad",
    trigger_mode: "other",
    velocity: Number.POSITIVE_INFINITY,
    volume: undefined,
    pan: Number.NaN,
    choke_group: "bad",
  }, 3, PARAMETERS);

  assert.equal(fallback.id, "pad-4");
  assert.equal(fallback.name, "Pad 4");
  assert.equal(fallback.note, 39);
  assert.equal(fallback.root_note, 60);
  assert.equal(fallback.trigger_mode, "gate");
  assert.equal(fallback.velocity, 0);
  assert.equal(fallback.volume, 1);
  assert.equal(fallback.pan, -1);
  assert.equal(fallback.choke_group, 0);
  assert.deepEqual(fallback.values, [10, 20, 30]);

  assert.deepEqual(
    model.normalizePad({ patch: { values: [4, 5, 6] } }, 0, PARAMETERS).values,
    [4, 5, 6],
  );
  assert.deepEqual(
    model.normalizePad({ patch_values: [7, 8, 9] }, 0, PARAMETERS).values,
    [7, 8, 9],
  );
});

test("normalizeKit clamps selection and channel and always returns sixteen normalized pads", () => {
  const kit = model.normalizeKit({
    name: `  ${"K".repeat(90)}  `,
    mapping: "custom",
    midi_channel: 99,
    selected: -20,
    pads: [{ note: 42, name: "Hat" }],
  }, PARAMETERS);

  assert.equal(kit.name, "K".repeat(80));
  assert.equal(kit.mapping, "custom");
  assert.equal(kit.midi_channel, 15);
  assert.equal(kit.selected, 0);
  assert.equal(kit.pads.length, model.PAD_COUNT);
  assert.equal(kit.pads[0].note, 42);
  assert.equal(kit.pads[0].name, "Hat");
  assert.equal(kit.pads[15].name, "Pad 16");

  assert.equal(model.normalizeKit({ midi_channel: "", selected: 99 }, PARAMETERS).midi_channel, "omni");
  assert.equal(model.normalizeKit({ midi_channel: "4" }, PARAMETERS).midi_channel, 4);
  assert.equal(model.normalizeKit({ selected: 99 }, PARAMETERS).selected, 15);
  assert.equal(model.normalizeKit({ mapping: "unknown" }, PARAMETERS).mapping, "chromatic");
});

test("noteName normalizes note input and uses MIDI octave numbering", () => {
  assert.equal(model.noteName(0), "C-1");
  assert.equal(model.noteName(36), "C2");
  assert.equal(model.noteName(60), "C4");
  assert.equal(model.noteName(127), "G9");
  assert.equal(model.noteName(999), "G9");
  assert.equal(model.noteName("invalid"), "C4");
});

test("applyMapping installs GM notes, names, channel, and hi-hat choke group", () => {
  const kit = model.createKit(PARAMETERS);
  const returned = model.applyMapping(kit, "gm");

  assert.strictEqual(returned, kit);
  assert.equal(kit.mapping, "gm");
  assert.equal(kit.midi_channel, 9);
  assert.deepEqual(kit.pads.map((pad) => pad.note),
    [36, 37, 38, 39, 41, 42, 45, 46, 48, 49, 51, 56, 54, 75, 69, 70]);
  assert.equal(kit.pads[0].name, "Kick");
  assert.equal(kit.pads[5].name, "Closed Hat");
  assert.equal(kit.pads[7].name, "Open Hat");
  assert.equal(kit.pads[5].choke_group, 1);
  assert.equal(kit.pads[7].choke_group, 1);
  assert.equal(kit.pads[0].choke_group, 0);
});

test("applyMapping restores chromatic notes and omni channel and custom preserves assignments", () => {
  const kit = model.createKit(PARAMETERS);
  model.applyMapping(kit, "gm");
  model.applyMapping(kit, "chromatic");

  assert.equal(kit.mapping, "chromatic");
  assert.equal(kit.midi_channel, "omni");
  assert.deepEqual(kit.pads.map((pad) => pad.note),
    Array.from({ length: 16 }, (_, index) => 36 + index));

  kit.pads[0].note = 91;
  model.applyMapping(kit, "anything-else");
  assert.equal(kit.mapping, "custom");
  assert.equal(kit.pads[0].note, 91);
});

test("targetsForNote honors omni and exact zero-based MIDI channels", () => {
  const kit = kitWithNote(48);

  assert.deepEqual(model.targetsForNote(kit, 48, 0), [0]);
  assert.deepEqual(model.targetsForNote(kit, 48, 15), [0]);
  assert.deepEqual(model.targetsForNote(kit, 48, undefined), [0]);

  kit.midi_channel = 9;
  assert.deepEqual(model.targetsForNote(kit, 48, 9), [0]);
  assert.deepEqual(model.targetsForNote(kit, 48, "9"), [0]);
  assert.deepEqual(model.targetsForNote(kit, 48, 8), []);
  assert.deepEqual(model.targetsForNote(kit, 48, undefined), [0]);
  assert.deepEqual(model.targetsForNote(kit, 49, 9), []);
});

test("noteOnEvents routes a trigger note to the pad's independent root note", () => {
  const kit = kitWithNote(36);
  kit.pads[0].root_note = 67;

  assert.deepEqual(model.noteOnEvents(kit, 36, 104, 2), [{
    type: "note",
    on: true,
    slot: 0,
    note: 67,
    velocity: 104,
    trigger_mode: "gate",
  }]);
});

test("noteOnEvents scales, rounds, and clamps playable velocity", () => {
  const kit = kitWithNote(36);

  kit.pads[0].velocity = 0.5;
  assert.equal(model.noteOnEvents(kit, 36, 101)[0].velocity, 51);

  kit.pads[0].velocity = 2;
  assert.equal(model.noteOnEvents(kit, 36, 100)[0].velocity, 127);

  kit.pads[0].velocity = 0;
  assert.equal(model.noteOnEvents(kit, 36, 100)[0].velocity, 1);
  assert.equal(model.noteOnEvents(kit, 36, 0)[0].velocity, 1);
});

test("duplicate note assignments layer pads in stable slot order", () => {
  const kit = kitWithNote(55);
  kit.pads[1].note = 55;
  kit.pads[0].root_note = 60;
  kit.pads[1].root_note = 72;
  kit.pads[0].velocity = 1;
  kit.pads[1].velocity = 0.5;

  assert.deepEqual(model.targetsForNote(kit, 55, 0), [0, 1]);
  assert.deepEqual(model.noteOnEvents(kit, 55, 80, 0), [
    { type: "note", on: true, slot: 0, note: 60, velocity: 80, trigger_mode: "gate" },
    { type: "note", on: true, slot: 1, note: 72, velocity: 40, trigger_mode: "gate" },
  ]);
});

test("disabled and muted pads never target, and enabled solo pads suppress non-solo pads", () => {
  const kit = kitWithNote(44);
  kit.pads[1].note = 44;
  kit.pads[2].note = 44;

  kit.pads[0].enabled = false;
  kit.pads[1].mute = true;
  assert.deepEqual(model.targetsForNote(kit, 44), [2]);

  kit.pads[0].enabled = true;
  kit.pads[1].mute = false;
  kit.pads[1].solo = true;
  assert.deepEqual(model.targetsForNote(kit, 44), [1]);

  kit.pads[1].mute = true;
  assert.deepEqual(model.targetsForNote(kit, 44), []);

  kit.pads[1].enabled = false;
  assert.deepEqual(model.targetsForNote(kit, 44), [0, 2]);
});

test("noteOffEvents releases gate routes and leaves one-shot routes running", () => {
  const routes = [
    { type: "note", on: true, slot: 2, note: 60, velocity: 90, trigger_mode: "gate" },
    { type: "note", on: true, slot: 3, note: 61, velocity: 90, trigger_mode: "one-shot" },
  ];

  assert.deepEqual(model.noteOffEvents(routes), [
    { type: "note", on: false, slot: 2, note: 60, velocity: 0 },
  ]);
  assert.deepEqual(model.noteOffEvents(), []);
});

test("choke events precede the triggering note and target every other group member", () => {
  const kit = kitWithNote(42);
  kit.pads[0].root_note = 64;
  kit.pads[0].choke_group = 3;
  kit.pads[1].choke_group = 3;
  kit.pads[2].choke_group = 3;
  kit.pads[3].choke_group = 4;

  assert.deepEqual(model.noteOnEvents(kit, 42, 96), [
    { type: "panic", slot: 1, reason: "choke" },
    { type: "panic", slot: 2, reason: "choke" },
    { type: "note", on: true, slot: 0, note: 64, velocity: 96, trigger_mode: "gate" },
  ]);
});

test("qkitObject produces the public versioned schema without sharing patch arrays", () => {
  const kit = model.createKit(PARAMETERS);
  kit.name = "Electronic Kit";
  kit.mapping = "custom";
  kit.midi_channel = 4;
  kit.pads[0].name = "Bass Drum";
  kit.pads[0].values[0] = 88;

  const encoded = model.qkitObject(kit, PARAMETERS);
  assert.equal(encoded.format, "quesynth-kit");
  assert.equal(encoded.version, 1);
  assert.equal(encoded.name, "Electronic Kit");
  assert.equal(encoded.mapping, "custom");
  assert.equal(encoded.midi_channel, 4);
  assert.equal(encoded.pads.length, 16);
  assert.equal(encoded.pads[0].name, "Bass Drum");
  assert.deepEqual(encoded.pads[0].patch, {
    format: "quesynth-patch",
    name: "Init",
    bank: "",
    index: null,
    values: [88, 20, 30],
  });
  assert.equal(Object.hasOwn(encoded, "selected"), false);
  assert.equal(Object.hasOwn(encoded.pads[0], "values"), false);

  encoded.pads[0].patch.values[0] = 1;
  assert.equal(kit.pads[0].values[0], 88);
});

test("stringify and parse round-trip all persistent kit and pad properties", () => {
  const kit = model.createKit(PARAMETERS);
  kit.name = "Round Trip";
  kit.mapping = "custom";
  kit.midi_channel = 12;
  Object.assign(kit.pads[3], {
    id: "snare-layer",
    note: 38,
    name: "Snare Layer",
    root_note: 71,
    trigger_mode: "one-shot",
    velocity: 1.25,
    volume: 0.75,
    pan: -0.4,
    choke_group: 5,
    enabled: false,
    mute: true,
    solo: true,
    patch_name: "Snare 07",
    patch_bank: "Drums",
    patch_index: 7,
    values: [91, 81, 71],
  });

  const text = model.stringify(kit, PARAMETERS);
  assert.equal(text.endsWith("\n"), true);
  const parsed = model.parse(text, PARAMETERS);

  assert.equal(parsed.format, model.FORMAT);
  assert.equal(parsed.version, model.VERSION);
  assert.equal(parsed.name, "Round Trip");
  assert.equal(parsed.mapping, "custom");
  assert.equal(parsed.midi_channel, 12);
  assert.equal(parsed.selected, 0);
  assert.deepEqual(parsed.pads[3], kit.pads[3]);
});

test("parse validates JSON, format, and exact supported version", () => {
  assert.throws(() => model.parse("not json", PARAMETERS), SyntaxError);
  assert.throws(
    () => model.parse({ format: "other", version: model.VERSION }, PARAMETERS),
    /Not a Quesynth kit/,
  );
  assert.throws(
    () => model.parse({ format: model.FORMAT }, PARAMETERS),
    /Unsupported Quesynth kit version: undefined/,
  );
  assert.throws(
    () => model.parse({ format: model.FORMAT, version: model.VERSION + 1 }, PARAMETERS),
    /Unsupported Quesynth kit version: 2/,
  );
});

test("parse normalizes a minimal valid qkit instead of retaining input references", () => {
  const raw = {
    format: model.FORMAT,
    version: model.VERSION,
    name: "Minimal",
    pads: [{ note: 35, patch: { values: [1, 2, 3] } }],
  };
  const parsed = model.parse(raw, PARAMETERS);

  assert.equal(parsed.pads.length, 16);
  assert.equal(parsed.pads[0].note, 35);
  assert.deepEqual(parsed.pads[0].values, [1, 2, 3]);
  assert.notStrictEqual(parsed.pads[0], raw.pads[0]);
  assert.notStrictEqual(parsed.pads[0].values, raw.pads[0].patch.values);

  parsed.pads[0].values[0] = 99;
  assert.equal(raw.pads[0].patch.values[0], 1);
});

test("clonePad deeply clones and normalizes a slot", () => {
  const original = model.createPad(5, PARAMETERS);
  original.id = "source-pad";
  original.name = "Source";
  original.values = [5, 6, 7];

  const clone = model.clonePad(original, PARAMETERS);
  assert.deepEqual(clone, original);
  assert.notStrictEqual(clone, original);
  assert.notStrictEqual(clone.values, original.values);

  clone.name = "Clone";
  clone.values[0] = 100;
  assert.equal(original.name, "Source");
  assert.equal(original.values[0], 5);
});
