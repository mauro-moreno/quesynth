package vst3_tests

import "core:testing"

import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// How a change from the main thread reaches the audio thread.
//
// `values` is the audio thread's parameter set, and the engine is rebound from
// it at the top of a block. A `setParamNormalized`, a `setState` or a program
// selected on the controller arrives on the main thread, and writing into
// `values` -- or rebinding the engine -- from there while `process` renders is a
// race over the whole set. So the change is staged, the controller and the saved
// state report it at once, and the audio thread takes it up at the top of its
// next block. These tests drive a plugin the way a host does -- through its
// vtables, `process` included -- and ask the questions from both sides.

// -- driving it ---------------------------------------------------------------

controller_of :: proc(p: ^synth.Plugin) -> rawptr {
	return rawptr(&p.controller_vtbl)
}

make_active_plugin :: proc(t: ^testing.T) -> ^synth.Plugin {
	p := synth.make_plugin()
	if p == nil {
		return nil
	}
	testing.expect_value(t, synth.component_set_active(rawptr(p), 1), vst3.RESULT_OK)
	return p
}

// A point for one parameter in the block, which is how a host delivers
// automation to the audio thread. Both interfaces are this one struct: the
// changes list is its first field, and the queue the list hands out is the
// second, found again by subtracting its offset.
Parameter_Point :: struct {
	changes: vst3.IParameterChanges,
	queue:   vst3.IParamValueQueue,
	id:      u32,
	value:   f64,
}

POINT_CHANGES_VTBL := vst3.IParameterChanges_Vtbl {
	get_parameter_count = proc "c" (this: rawptr) -> i32 {
		return 1
	},
	get_parameter_data = proc "c" (this: rawptr, index: i32) -> ^vst3.IParamValueQueue {
		return &(^Parameter_Point)(this).queue
	},
}

POINT_QUEUE_VTBL := vst3.IParamValueQueue_Vtbl {
	get_parameter_id = proc "c" (this: rawptr) -> u32 {
		return (^Parameter_Point)(uintptr(this) - offset_of(Parameter_Point, queue)).id
	},
	get_point_count = proc "c" (this: rawptr) -> i32 {
		return 1
	},
	get_point = proc "c" (this: rawptr, index: i32, sample_offset: ^i32, value: ^f64) -> vst3.Result {
		sample_offset^ = 0
		value^ = (^Parameter_Point)(uintptr(this) - offset_of(Parameter_Point, queue)).value
		return vst3.RESULT_OK
	},
}

// One block on the audio thread: sixty-four frames of stereo, with `point`, if
// there is one, as the only parameter change in it.
process_block :: proc(t: ^testing.T, p: ^synth.Plugin, point: ^Parameter_Point = nil) {
	left, right: [64]f32
	channels := [2][^]f32{raw_data(left[:]), raw_data(right[:])}
	bus := vst3.Audio_Bus_Buffers {
		num_channels    = 2,
		channel_buffers = &channels[0],
	}
	data := vst3.Process_Data {
		symbolic_sample_size = vst3.SAMPLE_32,
		num_samples          = 64,
		num_outputs          = 1,
		outputs              = &bus,
	}
	if point != nil {
		point.changes.vtbl = &POINT_CHANGES_VTBL
		point.queue.vtbl = &POINT_QUEUE_VTBL
		data.input_parameter_changes = &point.changes
	}
	testing.expect_value(t, synth.processor_process(rawptr(&p.processor_vtbl), &data), vst3.RESULT_OK)
}

// The integers a saved state holds, read back by hand.
saved_values_of :: proc(t: ^testing.T, p: ^synth.Plugin) -> (values: [patch.PARAMETER_COUNT]i32, ok: bool) {
	out: Memory_Stream
	memory_stream_init(&out, 64)
	defer memory_stream_destroy(&out)
	if synth.component_get_state(rawptr(p), stream_of(&out)) != vst3.RESULT_OK || len(out.data) != HEADER + 4 * patch.PARAMETER_COUNT {
		testing.expect(t, false, "the state could not be saved")
		return {}, false
	}
	for i in 0 ..< patch.PARAMETER_COUNT {
		b := out.data[HEADER + 4 * i:][:4]
		values[i] = i32(u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24)
	}
	return values, true
}

// A value for `id` that is not the one it has.
other_than :: proc(current: i32) -> i32 {
	return current == 100 ? 50 : 100
}

// The engine's own copy of the stored set, which only `apply_params` and the
// engine's loading write. If this has moved, something rebound the engine.
expect_engine_holds :: proc(t: ^testing.T, p: ^synth.Plugin, values: [patch.PARAMETER_COUNT]i32, what: string) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		testing.expectf(t, p.eng.patch.values[i] == int(values[i]), "%s: the engine holds %d for parameter %d, not %d", what, p.eng.patch.values[i], i, values[i])
	}
}

// -- a parameter set on the controller -----------------------------------------

@(test)
a_parameter_set_while_active_is_staged_for_the_audio_thread :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	CUTOFF :: 19
	before := p.values
	wanted := other_than(before[CUTOFF])
	engine_before := p.eng.params

	testing.expect_value(t, synth.controller_set_param_normalized(controller_of(p), CUTOFF, synth.normalized_of(CUTOFF, wanted)), vst3.RESULT_OK)

	// Nothing the audio thread owns has been touched, and the engine has not
	// been rebound from this thread.
	testing.expect_value(t, p.values[CUTOFF], before[CUTOFF])
	expect_engine_holds(t, p, before, "after setParamNormalized")
	testing.expect(t, p.eng.params == engine_before, "setParamNormalized rebound the engine from the main thread")

	// But the main thread already has its answer: what the host reads back, and
	// what it would save, is the value it just set.
	testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), CUTOFF), synth.normalized_of(CUTOFF, wanted))
	saved, ok := saved_values_of(t, p)
	testing.expect(t, ok, "no saved state")
	testing.expect_value(t, saved[CUTOFF], wanted)

	// The audio thread takes it up at the top of its next block.
	process_block(t, p)
	testing.expect_value(t, p.values[CUTOFF], wanted)
	after := before
	after[CUTOFF] = wanted
	expect_engine_holds(t, p, after, "after the next block")
	testing.expect(t, p.eng.params != engine_before, "the audio thread did not rebind the engine to the staged value")
}

// Two sets staged before the audio thread has run: the second builds on the
// first, rather than on the audio thread's older set, so neither is lost.
@(test)
parameters_staged_before_a_block_all_arrive :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	FIRST :: 19
	SECOND :: 33
	first := other_than(p.values[FIRST])
	second := other_than(p.values[SECOND])
	synth.controller_set_param_normalized(controller_of(p), FIRST, synth.normalized_of(FIRST, first))
	synth.controller_set_param_normalized(controller_of(p), SECOND, synth.normalized_of(SECOND, second))

	process_block(t, p)
	testing.expect_value(t, p.values[FIRST], first)
	testing.expect_value(t, p.values[SECOND], second)
}

// The audio thread's own automation, in the block that picks a staged set up,
// lands on top of that set: it is the later of the two.
@(test)
a_point_in_the_block_lands_on_top_of_a_staged_value :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	CUTOFF :: 19
	staged := other_than(p.values[CUTOFF])
	automated := staged == 100 ? i32(30) : i32(100)
	synth.controller_set_param_normalized(controller_of(p), CUTOFF, synth.normalized_of(CUTOFF, staged))

	point := Parameter_Point {
		id    = CUTOFF,
		value = synth.normalized_of(CUTOFF, automated),
	}
	process_block(t, p, &point)
	testing.expect_value(t, p.values[CUTOFF], automated)
}

// -- a state load -------------------------------------------------------------

@(test)
a_state_load_while_active_is_staged_for_the_audio_thread :: proc(t: ^testing.T) {
	// `setState` on the component and `setComponentState` on the controller are
	// the same load, from two entry points a host may use.
	for through_the_controller in ([]bool{false, true}) {
		p := make_active_plugin(t)
		if p == nil {return}
		defer synth.release(p)

		before := p.values
		in_: Memory_Stream
		memory_stream_init(&in_, 64, GOLDEN_STATE[:])
		defer memory_stream_destroy(&in_)
		if through_the_controller {
			testing.expect_value(t, synth.controller_set_component_state(controller_of(p), stream_of(&in_)), vst3.RESULT_OK)
		} else {
			testing.expect_value(t, synth.component_set_state(rawptr(p), stream_of(&in_)), vst3.RESULT_OK)
		}

		golden: [patch.PARAMETER_COUNT]i32
		for v, i in GOLDEN_VALUES {
			golden[i] = v
		}
		testing.expect(t, golden != before, "the golden state is what the plugin started with, so this proves nothing")

		// Not applied from this thread...
		testing.expect_value(t, p.values, before)
		expect_engine_holds(t, p, before, "after setState")

		// ...but already what the main thread reports.
		for i in 0 ..< patch.PARAMETER_COUNT {
			got := synth.controller_get_param_normalized(controller_of(p), u32(i))
			testing.expectf(t, got == synth.normalized_of(i, golden[i]), "parameter %d reads back %v after the load, not %v", i, got, synth.normalized_of(i, golden[i]))
		}
		saved, ok := saved_values_of(t, p)
		testing.expect(t, ok, "no saved state")
		testing.expect_value(t, saved, golden)

		process_block(t, p)
		testing.expect_value(t, p.values, golden)
		expect_engine_holds(t, p, golden, "after the next block")
	}
}

// -- a program selected on the controller ---------------------------------------

@(test)
a_program_selected_on_the_controller_is_staged_for_the_audio_thread :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	text: string = `{"format":"quesynth.bank","version":1,"name":"Staged","patches":[
		{"name":"Zero","parameters":{"osc1 shape":0}},
		{"name":"One","parameters":{"osc1 shape":3,"amp gain":90}}
	]}`
	synth.plugin_set_bank(p, text, false)
	wanted, filled := patch.slots_patch(&p.slots, 1)
	testing.expect(t, filled, "slot 1 is empty")
	before := p.values
	testing.expect(t, wanted != before, "the program is what the plugin started with, so this proves nothing")

	testing.expect_value(t, synth.controller_set_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID, synth.program_normalized(1)), vst3.RESULT_OK)

	// The program is remembered at once, so the controller can report it; the
	// sound it stands for is staged.
	testing.expect_value(t, p.program, i32(1))
	testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID), synth.program_normalized(1))
	testing.expect_value(t, p.values, before)
	expect_engine_holds(t, p, before, "after selecting the program")
	for i in 0 ..< patch.PARAMETER_COUNT {
		testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), u32(i)), synth.normalized_of(i, wanted[i]))
	}

	process_block(t, p)
	testing.expect_value(t, p.values, wanted)
	expect_engine_holds(t, p, wanted, "after the next block")
}

// -- when there is no audio thread -------------------------------------------

@(test)
a_parameter_set_while_inactive_is_adopted_at_once :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	CUTOFF :: 19
	wanted := other_than(p.values[CUTOFF])
	synth.controller_set_param_normalized(controller_of(p), CUTOFF, synth.normalized_of(CUTOFF, wanted))
	testing.expect_value(t, p.values[CUTOFF], wanted)

	// And the engine, when it is built, is built from it.
	testing.expect_value(t, synth.component_set_active(rawptr(p), 1), vst3.RESULT_OK)
	testing.expect_value(t, p.eng.patch.values[CUTOFF], int(wanted))
}

// The voice pool is sized from parameter 94 and only when the engine is built,
// so a pool size staged since the last build has to be in force when the next
// one is -- not waiting for a block that comes after it.
@(test)
a_staged_polyphony_sizes_the_pool_when_the_plugin_is_reactivated :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	POLYPHONY :: 94
	voices := i32(3)
	testing.expect(t, len(p.eng.voices) != int(voices), "the pool already has that many voices, so this proves nothing")
	synth.controller_set_param_normalized(controller_of(p), POLYPHONY, synth.normalized_of(POLYPHONY, voices))

	testing.expect_value(t, synth.component_set_active(rawptr(p), 0), vst3.RESULT_OK)
	testing.expect_value(t, synth.component_set_active(rawptr(p), 1), vst3.RESULT_OK)
	testing.expect_value(t, len(p.eng.voices), int(voices))
}

@(test)
a_staged_polyphony_sizes_the_pool_when_the_sample_rate_changes :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)

	POLYPHONY :: 94
	voices := i32(3)
	testing.expect(t, len(p.eng.voices) != int(voices), "the pool already has that many voices, so this proves nothing")
	synth.controller_set_param_normalized(controller_of(p), POLYPHONY, synth.normalized_of(POLYPHONY, voices))

	setup := vst3.Process_Setup {
		symbolic_sample_size  = vst3.SAMPLE_32,
		max_samples_per_block = 64,
		sample_rate           = 48000,
	}
	testing.expect_value(t, synth.processor_setup_processing(rawptr(&p.processor_vtbl), &setup), vst3.RESULT_OK)
	testing.expect_value(t, len(p.eng.voices), int(voices))
}
