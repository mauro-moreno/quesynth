package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// Gain of the 24 dB ladder at one frequency. It has no nonlinearity, so levels
// are comparable to the reference's, which were read off `s1probe arch
// filtertype --values 64,<resonance>`: noise through type 1 at cutoff 64,
// transfer against the open filter, at the octaves around 585.2 Hz. Cutoff 64 is
// position 515 on the reference's axis.
ladder_gain_db :: proc(resonance: f32, hz: f64) -> f64 {
	l: dsp.Moog_Ladder
	dsp.moog_ladder_set(&l, engine.filter_index_hz(engine.filter_knob_index(64)), resonance, SR)
	total := 48000
	energy_in, energy_out := 0.0, 0.0
	for i in 0 ..< total {
		x := f32(0.01 * math.sin(2 * math.PI * hz * f64(i) / f64(SR)))
		y := dsp.moog_ladder_process(&l, x)
		if i >= total / 2 {
			energy_in += f64(x * x)
			energy_out += f64(y * y)
		}
	}
	return 10 * math.log10(energy_out / energy_in)
}

expect_ladder_gain :: proc(t: ^testing.T, stored: int, octaves: f64, want: f64) {
	got := ladder_gain_db(f32(stored) / 127, 585.2 * math.pow(2.0, octaves))
	testing.expectf(t, abs(got - want) < 0.5, "resonance %v at %+.0f octaves: %.2f dB, reference %.2f dB", stored, octaves, got, want)
}

@(test)
test_moog_ladder_matches_the_reference_at_resonance_zero :: proc(t: ^testing.T) {
	expect_ladder_gain(t, 0, -1, -3.8)
	expect_ladder_gain(t, 0, 0, -11.9)
	expect_ladder_gain(t, 0, 1, -27.8)
	expect_ladder_gain(t, 0, 2, -49.2)
}

// The resonant peak and the loss of level below it, which the knob's single
// exponential in the corner produces without a table: stored 64 is -6.3 dB at the
// corner and -6.2 an octave below, stored 107 is +2.3 and -9.7.
@(test)
test_moog_ladder_resonance_follows_the_knob :: proc(t: ^testing.T) {
	expect_ladder_gain(t, 64, -1, -6.2)
	expect_ladder_gain(t, 64, 0, -6.3)
	expect_ladder_gain(t, 64, 1, -27.7)
	expect_ladder_gain(t, 107, -1, -9.7)
	expect_ladder_gain(t, 107, 0, +2.3)
	expect_ladder_gain(t, 107, 1, -27.7)
}

// Past a resonance of 0.9 the output is held to +/-20, and the held value is what
// feeds back.
@(test)
test_moog_ladder_clamps_a_runaway_output :: proc(t: ^testing.T) {
	l: dsp.Moog_Ladder
	dsp.moog_ladder_set(&l, 3000, 1.0, SR)
	peak := f32(0)
	for i in 0 ..< 20000 {
		y := dsp.moog_ladder_process(&l, i % 11 == 0 ? f32(500) : 0)
		peak = max(peak, abs(y))
	}
	testing.expect_value(t, peak, f32(20))
}

// A corner that is moving is followed, not jumped to: after a step the
// coefficients are still on their way a few samples later and have arrived
// within a few milliseconds.
@(test)
test_moog_ladder_smooths_its_coefficients :: proc(t: ^testing.T) {
	l: dsp.Moog_Ladder
	dsp.moog_ladder_set(&l, 500, 0.2, SR)
	start := l.p
	dsp.moog_ladder_set(&l, 5000, 0.2, SR)
	testing.expect_value(t, l.p, start)
	for _ in 0 ..< 10 {
		dsp.moog_ladder_process(&l, 0)
	}
	testing.expect(t, l.p > start && l.p < l.p_target, "the coefficient jumped or did not move")
	for _ in 0 ..< 480 {
		dsp.moog_ladder_process(&l, 0)
	}
	testing.expectf(t, abs(l.p - l.p_target) < 0.01 * abs(l.p_target - start), "p %v, target %v", l.p, l.p_target)
}

@(test)
test_moog_ladder_survives_non_finite_input :: proc(t: ^testing.T) {
	l: dsp.Moog_Ladder
	dsp.moog_ladder_set(&l, 800, 0.5, SR)
	nan := f32(math.nan_f32())
	for i in 0 ..< 100 {
		y := dsp.moog_ladder_process(&l, i == 3 ? nan : f32(0.2))
		testing.expect(t, !math.is_nan(y) && !math.is_inf(y), "a non-finite sample reached the output")
	}
}
