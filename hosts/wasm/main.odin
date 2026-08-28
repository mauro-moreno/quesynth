// The synth as a WebAssembly module, for the browser build.
//
//   odin build hosts/wasm -target:js_wasm32 -out:hosts/wasm/synth.wasm
//
// This is the same `src/engine` the plugin and the desktop application run. It is
// not a reimplementation and not a subset: the point of building it this way is
// that the interface in `ui/` can be exercised against the real instrument on any
// machine with a browser, including the phone it is meant to run on, without
// anybody installing a plugin host.
//
// The surface is deliberately thin. Everything crossing the boundary is a number,
// because the interface already speaks in the stored integers the `.sy1` format
// uses and there is no reason to serialise anything richer.
//
// Only six functions are imported from the host -- `write`, `rand_bytes`, and four
// from libm -- which `host.js` supplies in a dozen lines. The Odin JavaScript
// runtime is not needed and is not shipped.
package main

import "base:runtime"
import "../../src/engine"
import "../../src/patch"

// How many instruments a page can hold.
//
// One, for the synth panel. Sixteen for the pad, which is a four by four grid
// with a whole Quesynth behind every cell -- the point of it being that a drum
// sound is a synth patch, so a pad is not a sampler with a grid drawn on it but
// sixteen of this instrument that happen to be laid out in a square.
//
// Fixed at compile time rather than allocated, because the count is small and
// known and the alternative is a pointer the caller can get wrong.
MAX_SLOTS :: 16

// The instruments, and the patches they were loaded from.
g_engines: [MAX_SLOTS]engine.Engine
g_patches: [MAX_SLOTS]patch.Patch
g_slots: int
g_ready: bool

// How much longer a silent slot keeps being rendered.
//
// A slot with no voices sounding is not necessarily finished: the delay and the
// chorus have tails, and cutting a slot the instant its last voice ends would
// chop the reverb off every hit. So a slot runs on for a while after it falls
// silent and is then skipped entirely, which is what keeps sixteen engines
// affordable -- a pad grid is mostly idle, and an idle slot that is skipped costs
// nothing rather than costing a full effect chain.
SLOT_TAIL_SECONDS :: 2.0
g_slot_tail: [MAX_SLOTS]int
g_tail_blocks: int

// Where a slot's own output is rendered before being summed into the mix. One
// buffer reused by every slot, because they are rendered one after another.
g_slot_left: []f32
g_slot_right: []f32

slot_ok :: proc "contextless" (slot: i32) -> bool {
	return slot >= 0 && int(slot) < g_slots
}

// The block the audio callback reads. Planar, left then right, because that is
// the shape an AudioWorklet hands out and converting on either side would be work
// done for nothing.
g_block: int
g_audio: []f32

// The sample rate is whatever the browser's audio context decided, which is 44100
// on some machines and 48000 on others. Nothing here assumes either.
//
// `slots` is how many instruments the page wants: one for the synth panel,
// sixteen for the pad. Anything outside 1..MAX_SLOTS is clamped rather than
// refused, because a host that asks for nonsense should still make a sound.
@(export)
synth_init :: proc "c" (sample_rate: f32, block: i32, slots: i32) -> [^]f32 {
	context = wasm_context()

	if g_audio != nil {
		delete(g_audio)
	}
	if g_slot_left != nil {
		delete(g_slot_left)
		delete(g_slot_right)
	}
	g_block = int(block)
	g_audio = make([]f32, g_block * 2)
	g_slot_left = make([]f32, g_block)
	g_slot_right = make([]f32, g_block)

	g_slots = clamp(int(slots), 1, MAX_SLOTS)
	g_tail_blocks = int(SLOT_TAIL_SECONDS * f64(sample_rate) / f64(max(g_block, 1))) + 1

	// The reference's own defaults, so the page opens on a real instrument rather
	// than on a silent one.
	for s in 0 ..< g_slots {
		for i in 0 ..< patch.PARAMETER_COUNT {
			g_patches[s].values[i] = patch.PARAMETERS[i].default
			g_patches[s].present[i] = true
		}
		engine.engine_load_patch(&g_engines[s], g_patches[s], sample_rate)
		g_slot_tail[s] = 0
	}
	g_ready = true
	return raw_data(g_audio)
}

// How many slots this module was started with, so a page can ask rather than
// assume.
@(export)
synth_slot_count :: proc "c" () -> i32 {
	return i32(g_slots)
}

// Set one parameter, in the stored integer the .sy1 format and the interface both
// use.
//
// `engine_apply_patch` rather than `engine_load_patch`: an edit must not cut the
// note that is sounding while it is being made.
@(export)
synth_set_param :: proc "c" (slot: i32, index: i32, stored: i32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) || index < 0 || int(index) >= patch.PARAMETER_COUNT {
		return
	}
	g_patches[slot].values[index] = int(stored)
	g_patches[slot].present[index] = true
	engine.engine_apply_patch(&g_engines[slot], g_patches[slot])
}

// Where a whole patch is written before `synth_apply_patch` reads it.
//
// A patch is ninety-nine numbers and every one of them arriving as its own call
// would rebind the instrument ninety-nine times to reach one sound. The caller
// fills this buffer and applies it once.
g_incoming: [patch.PARAMETER_COUNT]i32

@(export)
synth_patch_buffer :: proc "c" () -> [^]i32 {
	return raw_data(g_incoming[:])
}

@(export)
synth_apply_patch :: proc "c" (slot: i32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	for i in 0 ..< patch.PARAMETER_COUNT {
		g_patches[slot].values[i] = int(g_incoming[i])
		g_patches[slot].present[i] = true
	}
	// A whole patch, so the smoothed parameters snap rather than sweeping in
	// from whatever the last patch left them at.
	engine.engine_apply_patch(&g_engines[slot], g_patches[slot], true)
}

@(export)
synth_note_on :: proc "c" (slot: i32, note: i32, velocity: i32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	engine.engine_note_on(&g_engines[slot], int(note), f32(velocity) / 127.0)
	// A hit restarts the slot's tail, so it is rendered again even if it had
	// fallen silent and been skipped.
	g_slot_tail[slot] = g_tail_blocks
}

@(export)
synth_note_off :: proc "c" (slot: i32, note: i32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	engine.engine_note_off(&g_engines[slot], int(note))
}

@(export)
synth_all_notes_off :: proc "c" () {
	context = wasm_context()
	if !g_ready {return}
	for s in 0 ..< g_slots {
		engine.engine_all_notes_off(&g_engines[s])
	}
}

// The pitch wheel, on -1..1. How far that bends is parameter 40's business.
@(export)
synth_pitch_bend :: proc "c" (slot: i32, bend: f32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	engine.engine_set_pitch_bend(&g_engines[slot], bend)
}

// A control change. The two assignments in parameters 86..89 decide what, if
// anything, this moves.
@(export)
synth_control_change :: proc "c" (slot: i32, cc: i32, value: i32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	engine.engine_control_change(&g_engines[slot], int(cc), int(value))
}

@(export)
synth_set_tempo :: proc "c" (slot: i32, bpm: f32) {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return}
	engine.engine_set_tempo(&g_engines[slot], bpm)
}

// Fill the block. The audio callback calls this and reads the buffer it was given
// at init; nothing is allocated or freed here.
@(export)
synth_render :: proc "c" () {
	context = wasm_context()
	if !g_ready || g_audio == nil {
		return
	}
	left := g_audio[:g_block]
	right := g_audio[g_block:]

	// One slot is the common case and there is nothing to sum, so it renders
	// straight into the output rather than through the mix buffer.
	if g_slots == 1 {
		engine.engine_process(&g_engines[0], left, right)
		return
	}

	for i in 0 ..< g_block {
		left[i] = 0
		right[i] = 0
	}
	for s in 0 ..< g_slots {
		if engine.engine_active_voice_count(&g_engines[s]) > 0 {
			g_slot_tail[s] = g_tail_blocks
		} else if g_slot_tail[s] > 0 {
			g_slot_tail[s] -= 1
		} else {
			// Silent and past its tail: skipped whole. This is what makes a grid
			// of sixteen affordable, since most of them are idle most of the time.
			continue
		}
		engine.engine_process(&g_engines[s], g_slot_left, g_slot_right)
		for i in 0 ..< g_block {
			left[i] += g_slot_left[i]
			right[i] += g_slot_right[i]
		}
	}
}

@(export)
synth_active_voices :: proc "c" (slot: i32) -> i32 {
	context = wasm_context()
	if !g_ready || !slot_ok(slot) {return 0}
	return i32(engine.engine_active_voice_count(&g_engines[slot]))
}

// A context for the exported entry points.
//
// Every `proc "c"` crossing the boundary needs one before it can touch anything
// that allocates or asserts, because the C calling convention does not carry
// Odin's implicit context. This returns the one the runtime set up at `_start`.
wasm_context :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

main :: proc() {}
