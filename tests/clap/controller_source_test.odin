package clap_tests

import "core:math"
import "core:testing"
import clap "../../src/clap"

// Parameters 86 and 88 can name channel aftertouch (53248, 0xD000) and pitch
// bend (57344, 0xE000) as well as a control change, and the reference routes
// both. Driven through the plugin's own MIDI input, with the assignment aimed
// at oscillator 2's pitch so where it moved the parameter is a frequency.
//
// The expected pitches are the reference's, from `s1probe behavior ctrl
// --source pressure|bend --sens 80` (docs/synth1-behavior-errors.md, clause 4):
// pressure 127 reads 89.907 like controller 1 at 127, and bend is bipolar,
// 29.065 at raw 0 and 89.962 at raw 16383. This plugin used to drop 0xD0 and
// left a bend-sourced assignment inert, so all three stayed at 60.

// Pitch in MIDI notes from interpolated positive-going zero crossings.
zc_midi :: proc(x: []f32) -> f64 {
	first, last := -1.0, -1.0
	count := 0
	for i in 1 ..< len(x) {
		a := f64(x[i - 1])
		b := f64(x[i])
		if a < 0 && b >= 0 {
			t := f64(i - 1) - a / (b - a)
			if first < 0 {first = t}
			last = t
			count += 1
		}
	}
	if count < 2 || last <= first {return 0}
	hz := f64(count - 1) * 48000.0 / (last - first)
	return 69.0 + 12.0 * math.log2(hz / 440.0)
}

controller_source_pitch :: proc(t: ^testing.T, source: f64, message: [3]u8) -> f64 {
	plugin := make_plugin(t)
	if plugin == nil {return 0}
	defer plugin.destroy(plugin)
	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	// Oscillator 2 alone, tracking the key, through an open filter with every
	// modulator and effect off; pitch bend range 0 so a bend cannot move the
	// pitch except through the assignment.
	settings := [][2]f64 {
		{1, 3}, {5, 127}, {4, 1}, {2, 64}, {3, 64}, {6, 0}, {7, 0}, {10, 0}, {45, 0},
		{95, 0}, {19, 127}, {20, 0}, {21, 63}, {22, 0}, {25, 0}, {27, 127}, {30, 0},
		{40, 0}, {57, 0}, {58, 0}, {59, 0}, {65, 0}, {66, 0}, {73, 0}, {77, 0},
		{91, 1}, {86, source}, {87, 2}, {50, 80}, {88, 0},
	}
	for s in settings {
		event := param_event(0, u32(s[0]), s[1])
		input_push(&input, &event)
	}
	run_block(plugin, &render, &input, &output)

	on := note_event(clap.EVENT_NOTE_ON, 0, 60, 100.0 / 127.0)
	input_push(&input, &on)
	run_block(plugin, &render, &input, &output)
	moved := midi_event(0, message[0], message[1], message[2])
	input_push(&input, &moved)
	run_block(plugin, &render, &input, &output)
	for _ in 0 ..< 16 {
		run_block(plugin, &render, &input, &output)
	}

	collected: [BLOCK * 8]f32
	for b in 0 ..< 8 {
		run_block(plugin, &render, &input, &output)
		for i in 0 ..< BLOCK {
			collected[b * BLOCK + i] = render.left[i]
		}
	}
	return zc_midi(collected[:])
}

@(test)
test_aftertouch_and_bend_move_their_controller_assignment :: proc(t: ^testing.T) {
	Case :: struct {
		label:     string,
		source:    f64,
		message:   [3]u8,
		reference: f64,
		tolerance: f64,
	}
	// The downward bend carries a wider tolerance, and the reason is not the
	// bend. A negative displacement lands about a semitone short of the
	// reference for every source: controller 1 at 127 with sensitivity -25%
	// reads 29.037 there and 30.000 here. That is the displacement law in
	// `engine_refresh_controllers`, which this change does not touch; see
	// docs/synth1-behavior-errors.md. What this case pins is that the bend is
	// bipolar -- a unipolar reading would leave raw 0 at 60.
	for c in ([]Case {
		{"controller 1 at 127 (control)", 45057, {0xB0, 1, 127}, 89.907, 0.15},
		{"channel pressure 127", 53248, {0xD0, 127, 0}, 89.907, 0.15},
		{"pitch bend raw 16383", 57344, {0xE0, 0x7F, 0x7F}, 89.962, 0.15},
		{"pitch bend raw 0", 57344, {0xE0, 0, 0}, 29.065, 1.0},
	}) {
		got := controller_source_pitch(t, c.source, c.message)
		testing.expectf(t, abs(got - c.reference) < c.tolerance,
			"%v: oscillator 2 at %.3f, the reference reads %.3f", c.label, got, c.reference)
	}
}
