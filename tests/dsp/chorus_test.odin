package dsp_tests

import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// The chorus's structure and laws. The structure is the reference's own, and
// `s1probe arch chorus` checks it: it renders the same patch with the
// section on and off in both engines and cancels one engine's wet against the other's:
// every type, depth, rate, delay and feedback setting agrees with the reference to the
// floor set by the two dry sources (-31 dB on two unison sines), with levels within
// 0.1 dB, where the right channel of types 1 and 2 and all of type 4 did not cancel
// at all before.

chorus_fixture :: proc(stages: int, delay, depth, rate, feedback: f32) -> (dsp.Chorus, dsp.Chorus_Params, [2][]f32) {
	buffers := [2][]f32{make([]f32, 4096), make([]f32, 4096)}
	c: dsp.Chorus
	dsp.chorus_init(&c, buffers[0], buffers[1])
	p := dsp.Chorus_Params {
		stages        = stages,
		delay_samples = delay,
		depth         = depth,
		rate_hz       = rate,
		feedback      = feedback,
		level         = 1.0,
	}
	return c, p, buffers
}

// Where, after an impulse at sample 0, each channel's wet peaks.
chorus_echo_positions :: proc(stages: int, delay, depth, rate: f32, left_impulse, right_impulse: bool) -> (left_at, right_at: int, left_peak, right_peak: f32) {
	c, p, buffers := chorus_fixture(stages, delay, depth, rate, 0)
	defer delete(buffers[0])
	defer delete(buffers[1])
	dsp.chorus_begin_block(&c, true)
	for i in 0 ..< 1500 {
		x := f32(0)
		if i == 0 {x = 1}
		l, r := dsp.chorus_process(&c, left_impulse ? x : 0, right_impulse ? x : 0, &p, 48000)
		if i > 0 {
			if abs(l) > left_peak {left_peak, left_at = abs(l), i}
			if abs(r) > right_peak {right_peak, right_at = abs(r), i}
		}
	}
	return
}

// Type 1 reads each channel's own line: a signal in the left alone gives no wet in
// the right. The engine used to send the left line to both channels.
@(test)
test_chorus_type_1_keeps_the_channels_apart :: proc(t: ^testing.T) {
	_, _, left_peak, right_peak := chorus_echo_positions(1, 400, 0.5, 0.01, true, false)
	testing.expect(t, left_peak > 0.5, "the left wet is missing")
	testing.expect_value(t, right_peak, f32(0))
}

// Type 2 sweeps the right channel with the cosine: it starts at its peak and the tap
// is `delay - excursion * osc`, so the right channel's echo arrives an excursion
// early (here 200 samples) where the left, which starts at the sine's zero, arrives
// on the delay. The engine's right channel swept the other way round.
@(test)
test_chorus_type_2_right_channel_starts_early :: proc(t: ^testing.T) {
	left_at, right_at, _, _ := chorus_echo_positions(2, 400, 0.5, 0.01, true, true)
	testing.expectf(t, abs(left_at - 400) <= 1, "left echo at %v, want 400", left_at)
	testing.expectf(t, abs(right_at - 200) <= 1, "right echo at %v, want 200", right_at)
}

// Type 4 mixes four taps into both channels. With no sweep the taps coincide, and a
// signal in one line reaches both outputs at unity: 0.9 + 0.1 from the left line and
// 0.3 + 0.7 from the right.
@(test)
test_chorus_type_4_mixes_both_lines_into_both_outputs :: proc(t: ^testing.T) {
	_, _, left_peak, right_peak := chorus_echo_positions(4, 400, 0, 1.0, true, false)
	testing.expectf(t, abs(left_peak - 1.0) < 1e-4 && abs(right_peak - 1.0) < 1e-4, "left line: %v / %v", left_peak, right_peak)
	_, _, left_peak, right_peak = chorus_echo_positions(4, 400, 0, 1.0, false, true)
	testing.expectf(t, abs(left_peak - 1.0) < 1e-4 && abs(right_peak - 1.0) < 1e-4, "right line: %v / %v", left_peak, right_peak)
}

// The sweep is cut back so a tap never moves faster than a sample per sample: at
// 400 Hz and full depth on 30 ms it is 19 samples wide, not 1440.
@(test)
test_chorus_excursion_is_limited_by_the_rate :: proc(t: ^testing.T) {
	testing.expect_value(t, dsp.chorus_excursion(1440, 1.0, 400, 48000), 19)
	testing.expect_value(t, dsp.chorus_excursion(1440, 1.0, 2, 48000), 1440)
	testing.expect_value(t, dsp.chorus_excursion(1440, 0.5, 2, 48000), 720)
	testing.expect_value(t, dsp.chorus_excursion(1440, 0, 2, 48000), 0)
}

// Switching the section on empties the lines, as the reference does.
@(test)
test_chorus_starts_empty_when_switched_on :: proc(t: ^testing.T) {
	c, p, buffers := chorus_fixture(2, 400, 0.5, 2, 0.5)
	defer delete(buffers[0])
	defer delete(buffers[1])
	dsp.chorus_begin_block(&c, true)
	for _ in 0 ..< 600 {
		dsp.chorus_process(&c, 1, 1, &p, 48000)
	}
	dsp.chorus_begin_block(&c, false)
	dsp.chorus_begin_block(&c, true)
	l, r := dsp.chorus_process(&c, 0, 0, &p, 48000)
	testing.expect_value(t, l, f32(0))
	testing.expect_value(t, r, f32(0))
}

// The parameter laws. The delay is 0.05 * 300 ^ ((2u) ^ 0.6) ms
// below the middle of the knob and 30u ms from it up; the displays read 15.12 ms at 64
// and 30.00 at 127.
@(test)
test_chorus_parameter_laws :: proc(t: ^testing.T) {
	near :: proc(t: ^testing.T, got, want, tolerance: f32, what: string) {
		testing.expectf(t, abs(got - want) <= tolerance, "%v: %v, want %v", what, got, want)
	}
	near(t, engine.chorus_delay_seconds(0), 0.00005, 1e-7, "delay at 0")
	near(t, engine.chorus_delay_seconds(1), 0.00008, 1e-6, "delay at 1")
	near(t, engine.chorus_delay_seconds(32), 0.00219, 1e-5, "delay at 32")
	near(t, engine.chorus_delay_seconds(63), 0.01460, 1e-5, "delay at 63, the top of the exponential half")
	near(t, engine.chorus_delay_seconds(64), 0.01512, 1e-5, "delay at 64, the linear half")
	near(t, engine.chorus_delay_seconds(127), 0.030, 1e-6, "delay at 127")
	near(t, engine.chorus_rate_hz(64), 2.94, 0.01, "rate at 64")
	near(t, engine.chorus_rate_hz(127), 400, 0.5, "rate at 127")
	near(t, engine.chorus_rate_hz(0), 0.01, 1e-6, "rate at 0")
	near(t, engine.chorus_depth_fraction(0), 0, 1e-7, "depth at 0")
	near(t, engine.chorus_depth_fraction(127), 1, 1e-5, "depth at 127")
	near(t, engine.chorus_feedback_gain(0), -0.99, 1e-6, "feedback at 0")
	near(t, engine.chorus_feedback_gain(64), 0, 1e-7, "feedback at 64")
	near(t, engine.chorus_feedback_gain(127), 0.9745, 1e-4, "feedback at 127")
}

// The sweep oscillator is put back at (0, 0.9999) at the start of a render chunk if its
// cosine has risen above 0.9999, and not otherwise. The check belongs to the chunk and not
// the host block: `s1probe arch chorus` at sweep rates of 100 and 120 nulled to -39 and
// -42 dB against the reference with it once per block and to -56 dB, the floor of the dry
// source, with it per chunk.
@(test)
test_chorus_oscillator_restarts_at_a_chunk_start_only_when_it_has_grown :: proc(t: ^testing.T) {
	c, _, buffers := chorus_fixture(2, 400, 0.5, 100, 0)
	defer delete(buffers[0])
	defer delete(buffers[1])
	c.sine = 0.3
	c.cosine = 0.9998
	dsp.chorus_begin_chunk(&c)
	testing.expect_value(t, c.sine, f32(0.3))
	testing.expect_value(t, c.cosine, f32(0.9998))
	c.cosine = 1.0005
	dsp.chorus_begin_chunk(&c)
	testing.expect_value(t, c.sine, f32(0))
	testing.expect_value(t, c.cosine, dsp.CHORUS_OSCILLATOR_PEAK)
}

// Several chunks in one call restart the oscillator at each of their starts: a block of
// 600 frames has chunks of 256, 256 and 88.
@(test)
test_chorus_checks_its_oscillator_at_every_chunk_of_a_block :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[66] = 1
	p.values[54] = 100
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	e.chorus.cosine = 1.5
	left := make([]f32, 600)
	right := make([]f32, 600)
	defer delete(left)
	defer delete(right)
	engine.engine_process(&e, left, right)
	testing.expectf(t, e.chorus.cosine < 1.01, "the oscillator was left at %v", e.chorus.cosine)
}
