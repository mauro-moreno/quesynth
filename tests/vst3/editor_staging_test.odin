#+build windows, linux
package vst3_tests

import "core:testing"

import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// The editor's side of the same handover. It runs on the interface thread,
// which for this purpose is the main thread: what it reads and what it writes
// have to be the staged set, or a state loaded under an open editor shows the
// old patch, and a knob turned just after it is overwritten when the audio
// thread adopts the load.
//
// Only the Editor's own host callbacks are exercised, with an Editor that has a
// plugin and nothing else: they are what the web view's messages end in, and
// need no window.

// The host's ear for what the editor reports, which is every call the editor
// makes to it.
Recording_Handler :: struct {
	// First: this is the `IComponentHandler*` the plugin is handed.
	vtbl:   ^vst3.IComponentHandler_Vtbl,
	ids:    [patch.PARAMETER_COUNT]u32,
	values: [patch.PARAMETER_COUNT]f64,
	count:  int,
}

RECORDING_HANDLER_VTBL := vst3.IComponentHandler_Vtbl {
	perform_edit = proc "c" (this: rawptr, id: u32, value_normalized: f64) -> vst3.Result {
		h := (^Recording_Handler)(this)
		if h.count < len(h.ids) {
			h.ids[h.count] = id
			h.values[h.count] = value_normalized
			h.count += 1
		}
		return vst3.RESULT_OK
	},
}

golden_set :: proc() -> (golden: [patch.PARAMETER_COUNT]i32) {
	for v, i in GOLDEN_VALUES {
		golden[i] = v
	}
	return
}

@(test)
the_editor_reads_and_builds_on_a_staged_state_load :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	ed := synth.Editor {
		plugin = p,
	}
	user := rawptr(&ed)

	in_: Memory_Stream
	memory_stream_init(&in_, 64, GOLDEN_STATE[:])
	defer memory_stream_destroy(&in_)
	testing.expect_value(t, synth.component_set_state(rawptr(p), stream_of(&in_)), vst3.RESULT_OK)
	golden := golden_set()

	// What the panel is shown when it asks for the whole set: the loaded
	// state, not the patch the audio thread has not yet let go of.
	shown: [patch.PARAMETER_COUNT]i32
	synth.editor_read_values(user, shown[:])
	testing.expect_value(t, shown, golden)

	// A knob turned before the audio thread has run is on top of the load, and
	// does not take the load back with it.
	CUTOFF :: 19
	turned := other_than(golden[CUTOFF])
	synth.editor_set_param(user, CUTOFF, turned)
	process_block(t, p)

	expected := golden
	expected[CUTOFF] = turned
	testing.expect_value(t, p.values, expected)
}

@(test)
a_patch_from_the_editor_is_staged_over_what_is_pending :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	ed := synth.Editor {
		plugin = p,
	}
	user := rawptr(&ed)
	handler := Recording_Handler {
		vtbl = &RECORDING_HANDLER_VTBL,
	}
	p.handler = &handler

	// A value staged from the controller and not yet adopted, and then a
	// partial patch from the panel that does not mention it.
	CUTOFF :: 19
	staged := other_than(p.values[CUTOFF])
	synth.controller_set_param_normalized(controller_of(p), CUTOFF, synth.normalized_of(CUTOFF, staged))

	patch_from_the_panel := [?]i32{3, 0, 17}
	before := p.values
	synth.editor_set_state(user, patch_from_the_panel[:])

	// Staged, not written under the audio thread.
	testing.expect_value(t, p.values, before)

	// The host is told what the panel set, as the values they are now.
	testing.expect_value(t, handler.count, len(patch_from_the_panel))
	for i in 0 ..< min(handler.count, len(patch_from_the_panel)) {
		testing.expect_value(t, handler.ids[i], u32(i))
		testing.expect_value(t, handler.values[i], synth.normalized_of(i, patch_from_the_panel[i]))
	}

	process_block(t, p)
	expected := before
	expected[CUTOFF] = staged
	for v, i in patch_from_the_panel {
		expected[i] = v
	}
	testing.expect_value(t, p.values, expected)
}

@(test)
a_single_edit_from_the_editor_is_staged_and_reported :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	ed := synth.Editor {
		plugin = p,
	}
	handler := Recording_Handler {
		vtbl = &RECORDING_HANDLER_VTBL,
	}
	p.handler = &handler

	CUTOFF :: 19
	before := p.values
	turned := other_than(before[CUTOFF])
	synth.editor_set_param(rawptr(&ed), CUTOFF, turned)

	testing.expect_value(t, p.values, before)
	testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), CUTOFF), synth.normalized_of(CUTOFF, turned))
	testing.expect_value(t, handler.count, 1)
	testing.expect_value(t, handler.ids[0], u32(CUTOFF))
	testing.expect_value(t, handler.values[0], synth.normalized_of(CUTOFF, turned))

	process_block(t, p)
	testing.expect_value(t, p.values[CUTOFF], turned)
}
