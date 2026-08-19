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

// The instrument, and the patch it was loaded from.
//
// One global set rather than a handle passed back and forth: there is exactly one
// instrument in a page, and a handle would only be a pointer the caller could get
// wrong.
g_engine: engine.Engine
g_patch: patch.Patch
g_ready: bool

// The block the audio callback reads. Planar, left then right, because that is
// the shape an AudioWorklet hands out and converting on either side would be work
// done for nothing.
g_block: int
g_audio: []f32

// The sample rate is whatever the browser's audio context decided, which is 44100
// on some machines and 48000 on others. Nothing here assumes either.
@(export)
synth_init :: proc "c" (sample_rate: f32, block: i32) -> [^]f32 {
	context = wasm_context()

	if g_audio != nil {
		delete(g_audio)
	}
	g_block = int(block)
	g_audio = make([]f32, g_block * 2)

	// The reference's own defaults, so the page opens on a real instrument rather
	// than on a silent one.
	for i in 0 ..< patch.PARAMETER_COUNT {
		g_patch.values[i] = patch.PARAMETERS[i].default
		g_patch.present[i] = true
	}
	engine.engine_load_patch(&g_engine, g_patch, sample_rate)
	g_ready = true
	return raw_data(g_audio)
}

// Set one parameter, in the stored integer the .sy1 format and the interface both
// use.
//
// `engine_apply_patch` rather than `engine_load_patch`: an edit must not cut the
// note that is sounding while it is being made.
@(export)
synth_set_param :: proc "c" (index: i32, stored: i32) {
	context = wasm_context()
	if !g_ready || index < 0 || int(index) >= patch.PARAMETER_COUNT {
		return
	}
	g_patch.values[index] = int(stored)
	g_patch.present[index] = true
	engine.engine_apply_patch(&g_engine, g_patch)
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
synth_apply_patch :: proc "c" () {
	context = wasm_context()
	if !g_ready {return}
	for i in 0 ..< patch.PARAMETER_COUNT {
		g_patch.values[i] = int(g_incoming[i])
		g_patch.present[i] = true
	}
	// A whole patch, so the smoothed parameters snap rather than sweeping in
	// from whatever the last patch left them at.
	engine.engine_apply_patch(&g_engine, g_patch, true)
}

@(export)
synth_note_on :: proc "c" (note: i32, velocity: i32) {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_note_on(&g_engine, int(note), f32(velocity) / 127.0)
}

@(export)
synth_note_off :: proc "c" (note: i32) {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_note_off(&g_engine, int(note))
}

@(export)
synth_all_notes_off :: proc "c" () {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_all_notes_off(&g_engine)
}

// The pitch wheel, on -1..1. How far that bends is parameter 40's business.
@(export)
synth_pitch_bend :: proc "c" (bend: f32) {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_set_pitch_bend(&g_engine, bend)
}

// A control change. The two assignments in parameters 86..89 decide what, if
// anything, this moves.
@(export)
synth_control_change :: proc "c" (cc: i32, value: i32) {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_control_change(&g_engine, int(cc), int(value))
}

@(export)
synth_set_tempo :: proc "c" (bpm: f32) {
	context = wasm_context()
	if !g_ready {return}
	engine.engine_set_tempo(&g_engine, bpm)
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
	engine.engine_process(&g_engine, left, right)
}

@(export)
synth_active_voices :: proc "c" () -> i32 {
	context = wasm_context()
	if !g_ready {return 0}
	return i32(engine.engine_active_voice_count(&g_engine))
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
