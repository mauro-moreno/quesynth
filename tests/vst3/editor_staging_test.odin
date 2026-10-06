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

// A knob turned on the panel, as `during` runs it.
Editor_Knob :: struct {
	ed:     rawptr,
	index:  int,
	stored: i32,
}

turn_on_the_editor :: proc(user: rawptr) {
	k := (^Editor_Knob)(user)
	synth.editor_set_param(k.ed, k.index, k.stored)
}

// A knob turned on the panel while a block applies the host's automation of
// another parameter, or a program change: the panel is shown both between the
// blocks, and the next block takes up the knob without taking the block's own
// change back.
@(test)
an_editor_knob_turned_during_a_block_keeps_that_blocks_automation_and_program :: proc(t: ^testing.T) {
	for program_change in ([]bool{false, true}) {
		p := make_active_plugin(t)
		if p == nil {return}
		defer synth.release(p)
		ed := synth.Editor {
			plugin = p,
		}
		synth.plugin_set_bank(p, TWO_PATCH_BANK, false)

		AUTOMATED :: 19
		TURNED :: 33
		before := p.values
		expected := before
		point: Parameter_Point
		if program_change {
			program, filled := patch.slots_patch(&p.slots, 1)
			testing.expect(t, filled, "slot 1 is empty")
			expected = program
			point = Parameter_Point {
				id    = synth.PROGRAM_PARAM_ID,
				value = synth.program_normalized(1),
			}
		} else {
			expected[AUTOMATED] = other_than(before[AUTOMATED])
			point = Parameter_Point {
				id    = AUTOMATED,
				value = synth.normalized_of(AUTOMATED, expected[AUTOMATED]),
			}
		}
		testing.expect(t, expected != before, "the block changes nothing, so this proves nothing")
		expected[TURNED] = other_than(expected[TURNED])

		knob := Editor_Knob{rawptr(&ed), TURNED, expected[TURNED]}
		point.during = turn_on_the_editor
		point.user = &knob
		process_block(t, p, &point)

		shown: [patch.PARAMETER_COUNT]i32
		synth.editor_read_values(rawptr(&ed), shown[:])
		testing.expectf(t, shown == expected, "program change %v: the panel is shown %v between the blocks, not %v", program_change, shown, expected)

		process_block(t, p)
		testing.expectf(t, p.values == expected, "program change %v: the next block holds %v, not %v", program_change, p.values, expected)
		expect_engine_holds(t, p, expected, "after the next block")
	}
}
