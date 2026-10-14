package dsp_tests

import "core:testing"

import "../../src/engine"

// The static law: full level at the centre, the channel moved away from falls
// linearly. `s1probe arch pan`, each control alone: pan 32 reads 1.002/0.501 and
// pan 0 reads 1.002/0.000 against the same line at centre (the 0.002 is the probe's).
@(test)
test_static_pan_law :: proc(t: ^testing.T) {
	left, right := engine.static_pan_gains(0)
	testing.expect_value(t, left, f32(1))
	testing.expect_value(t, right, f32(1))
	left, right = engine.static_pan_gains(-0.5)
	testing.expect_value(t, left, f32(1))
	testing.expect_value(t, right, f32(0.5))
	left, right = engine.static_pan_gains(1)
	testing.expect_value(t, left, f32(0))
	testing.expect_value(t, right, f32(1))
	left, right = engine.static_pan_gains(7)
	testing.expect_value(t, left, f32(0))
}

// The LFO's own law, a cubic. Square LFO on pan at depth 32 and 127 of 127: the
// reference's near and far channels read 1.292 / 0.423 and 1.504 / 0.000.
@(test)
test_pan_lfo_law_matches_the_reference :: proc(t: ^testing.T) {
	d32 := f32(32) / 127
	testing.expectf(t, abs(engine.pan_lfo_gain(d32) - 1.292) < 0.01, "near at depth 32: %v", engine.pan_lfo_gain(d32))
	testing.expectf(t, abs(engine.pan_lfo_gain(-d32) - 0.423) < 0.01, "far at depth 32: %v", engine.pan_lfo_gain(-d32))
	testing.expectf(t, abs(engine.pan_lfo_gain(1) - 1.5) < 0.01, "near at full depth: %v", engine.pan_lfo_gain(1))
	testing.expectf(t, abs(engine.pan_lfo_gain(-1)) < 0.001, "far at full depth: %v", engine.pan_lfo_gain(-1))
	testing.expect_value(t, engine.pan_lfo_gain(0), f32(1))
}

// The three controls multiply. Reference, two layers at spread 96 with pan 32 on
// the half-line that sits left: L 1.002, R 0.251; and on the right line L 0.501,
// R 0.501. Summing positions gives 1.000/0.000 and 1.000/1.000.
@(test)
test_pan_controls_multiply :: proc(t: ^testing.T) {
	spread := f32(96 - 64) / 64
	pan := f32(32 - 64) / 64

	layer_left, layer_right := engine.static_pan_gains(-spread)
	static_left, static_right := engine.static_pan_gains(pan)
	testing.expectf(t, abs(layer_left * static_left - 1.0) < 0.01 && abs(layer_right * static_right - 0.25) < 0.01, "left line %v / %v", layer_left * static_left, layer_right * static_right)

	layer_left, layer_right = engine.static_pan_gains(spread)
	testing.expectf(t, abs(layer_left * static_left - 0.5) < 0.01 && abs(layer_right * static_right - 0.5) < 0.01, "right line %v / %v", layer_left * static_left, layer_right * static_right)

	// With an LFO on top: LFO 32 + pan 32 reads 1.292 / 0.211, and 0.423 / 0.646 in
	// the other half.
	d32 := f32(32) / 127
	testing.expectf(t, abs(static_left * engine.pan_lfo_gain(d32) - 1.292) < 0.01, "got %v", static_left * engine.pan_lfo_gain(d32))
	testing.expectf(t, abs(static_right * engine.pan_lfo_gain(-d32) - 0.211) < 0.01, "got %v", static_right * engine.pan_lfo_gain(-d32))
	testing.expectf(t, abs(static_right * engine.pan_lfo_gain(d32) - 0.646) < 0.01, "got %v", static_right * engine.pan_lfo_gain(d32))
}

@(test)
test_pan_lfo_smoothing_has_a_two_millisecond_half_life :: proc(t: ^testing.T) {
	k := engine.pan_lfo_smoothing(48000)
	remaining := f32(1)
	for _ in 0 ..< 96 {
		remaining *= 1 - k
	}
	testing.expectf(t, abs(remaining - 0.5) < 0.001, "after 2 ms: %v", remaining)
}
