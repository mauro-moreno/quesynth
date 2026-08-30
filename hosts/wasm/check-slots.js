// Does a slot only sound when it is the slot that was struck?
//
//   node hosts/wasm/check-slots.js
//
// The pad puts sixteen instruments behind one output, and the whole arrangement
// rests on one property: a message carries the cell it is for, and reaches that
// cell and no other. That is easy to get wrong in a way nothing complains about
// -- drop the argument somewhere along the chain and every pad plays pad one,
// which sounds like a synth working perfectly.
//
// So it is checked here rather than by ear. The module is instantiated exactly
// as `worklet.js` instantiates it, which is also what makes this a check of the
// imports: a missing one is a LinkError and this file is where it shows up
// without a browser being involved.
const fs = require("fs");
const path = require("path");

const bytes = fs.readFileSync(path.join(__dirname, "synth.wasm"));
const SR = 48000, BLOCK = 128, SLOTS = 16;

function rms(a) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * a[i];
  return Math.sqrt(s / a.length);
}

WebAssembly.instantiate(bytes, {
  odin_env: {
    write: () => {},
    rand_bytes: (ptr, len) => {
      const v = new Uint8Array(w.memory.buffer, ptr, len);
      for (let i = 0; i < len; i++) v[i] = (Math.random() * 256) | 0;
    },
    sin: Math.sin, cos: Math.cos, pow: Math.pow, ln: Math.log, exp: Math.exp,
  },
}).then((r) => {
  const w = r.instance.exports;
  globalThis.w = w;
  w._start();

  const ptr = w.synth_init(SR, BLOCK, SLOTS);
  const count = w.synth_slot_count();
  if (count !== SLOTS) throw new Error("asked for " + SLOTS + " slots, got " + count);

  // Views onto the module's own memory, rebuilt after anything that can grow it.
  const view = () => [
    new Float32Array(w.memory.buffer, ptr, BLOCK),
    new Float32Array(w.memory.buffer, ptr + BLOCK * 4, BLOCK),
  ];

  // Silence first: nothing has been struck, so nothing may come out.
  let quiet = 0;
  for (let b = 0; b < 40; b++) {
    w.synth_render();
    quiet = Math.max(quiet, rms(view()[0]));
  }

  // Strike one cell in the middle of the grid and let it speak.
  const SLOT = 5;
  w.synth_note_on(SLOT, 60, 100);
  let struck = 0;
  for (let b = 0; b < 400; b++) {
    w.synth_render();
    struck = Math.max(struck, rms(view()[0]));
  }
  w.synth_note_off(SLOT, 60);

  // Every other cell has to have stayed out of it. Asked of the engines
  // themselves rather than of the mix, because the mix cannot tell which of
  // sixteen contributed to it.
  const sounding = [];
  for (let s = 0; s < SLOTS; s++) if (w.synth_active_voices(s) > 0) sounding.push(s);

  // And a parameter set on one cell must not move another. Cutoff shut on slot
  // 5 and left open on slot 6: strike both and the second must be the louder.
  w.synth_all_notes_off(-1);
  w.synth_set_param(SLOT, 19, 0);
  w.synth_note_on(SLOT, 60, 100);
  let shut = 0;
  for (let b = 0; b < 200; b++) { w.synth_render(); shut = Math.max(shut, rms(view()[0])); }
  w.synth_all_notes_off(-1);
  for (let b = 0; b < 400; b++) w.synth_render();

  w.synth_note_on(SLOT + 1, 60, 100);
  let open = 0;
  for (let b = 0; b < 200; b++) { w.synth_render(); open = Math.max(open, rms(view()[0])); }
  w.synth_all_notes_off(-1);

  // Rack mixer state belongs to one slot and can silence it without changing
  // the patch stored in that slot.
  for (let b = 0; b < 400; b++) w.synth_render();
  w.synth_set_mix(SLOT + 1, 0, 0);
  w.synth_note_on(SLOT + 1, 60, 100);
  let muted = 0;
  for (let b = 0; b < 120; b++) { w.synth_render(); muted = Math.max(muted, rms(view()[0])); }
  w.synth_all_notes_off(-1);
  w.synth_set_mix(SLOT + 1, 1, 0);

  // A one-shot must return its voice without a Note Off from the controller.
  const ONE_SHOT = SLOT + 2;
  w.synth_set_param(ONE_SHOT, 25, 0);
  w.synth_set_param(ONE_SHOT, 26, 0);
  w.synth_set_param(ONE_SHOT, 27, 0);
  w.synth_set_param(ONE_SHOT, 28, 0);
  w.synth_trigger(ONE_SHOT, 60, 100);
  for (let b = 0; b < 32; b++) w.synth_render();
  const oneShotVoices = w.synth_active_voices(ONE_SHOT);

  const lines = [
    "  slots reported            " + count,
    "  idle, nothing struck      " + quiet.toFixed(6),
    "  slot " + SLOT + " struck            " + struck.toFixed(6),
    "  engines with a voice      [" + sounding.join(", ") + "]",
    "  slot " + SLOT + " with cutoff shut  " + shut.toFixed(6),
    "  slot " + (SLOT + 1) + " with cutoff open  " + open.toFixed(6),
    "  slot " + (SLOT + 1) + " muted by mixer    " + muted.toFixed(6),
    "  one-shot voices after tail  " + oneShotVoices,
  ];
  console.log(lines.join("\n"));

  const fail = [];
  if (quiet > 1e-6) fail.push("idle slots are not silent");
  if (struck < 1e-3) fail.push("a struck slot made no sound");
  if (sounding.length !== 1 || sounding[0] !== SLOT) {
    fail.push("striking slot " + SLOT + " sounded " + JSON.stringify(sounding));
  }
  if (!(open > shut * 2)) {
    fail.push("a parameter set on one slot reached another (shut " +
      shut.toFixed(6) + " vs open " + open.toFixed(6) + ")");
  }
  if (muted > 1e-6) fail.push("a zero-volume slot reached the rack output");
  if (oneShotVoices !== 0) fail.push("one-shot kept a voice gated without Note Off");

  if (fail.length) {
    console.error("\nFAILED:\n  " + fail.join("\n  "));
    process.exit(1);
  }
  console.log("\n  every message reached its own slot and no other");
}).catch((e) => {
  console.error(String(e));
  process.exit(1);
});
