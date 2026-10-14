package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// Gain in decibels of one section at one frequency, from a sine long enough to
// settle. Every number the tests below compare against was read off the
// reference plugin with `s1probe arch filtertype --values 64,<resonance>`:
// noise through its two-pole types at cutoff 64, transfer against the open
// filter, at the octaves around 585.2 Hz. Cutoff 64 is position 515 on the
// reference's axis.
section_gain_db :: proc(mode: dsp.Filter_Mode, resonance: f32, hz: f64) -> f64 {
	c: dsp.Chamberlin
	dsp.chamberlin_set_cutoff(&c, engine.filter_index_hz(engine.filter_knob_index(64)), SR)
	total := 24000
	energy_in, energy_out := 0.0, 0.0
	for i in 0 ..< total {
		x := f32(math.sin(2 * math.PI * hz * f64(i) / f64(SR)))
		y := dsp.chamberlin_process(&c, x, resonance, mode)
		if i >= total / 2 {
			energy_in += f64(x * x)
			energy_out += f64(y * y)
		}
	}
	return 10 * math.log10(energy_out / energy_in)
}

expect_gain :: proc(t: ^testing.T, mode: dsp.Filter_Mode, resonance: f32, octaves: f64, want: f64, what: string) {
	got := section_gain_db(mode, resonance, 585.2 * math.pow(2.0, octaves))
	testing.expectf(t, abs(got - want) < 0.6, "%v at %+.0f octaves: %.2f dB, reference %.2f dB", what, octaves, got, want)
}

@(test)
test_chamberlin_low_pass_matches_the_reference_at_resonance_zero :: proc(t: ^testing.T) {
	expect_gain(t, .Low_Pass, 0, 1, -13.9, "low pass")
	expect_gain(t, .Low_Pass, 0, 2, -26.5, "low pass")
	expect_gain(t, .Low_Pass, 0, 3, -38.7, "low pass")
}

// Stored 80 is a resonance of 80/127. The reference loses 0.1 dB at the corner
// and 18.2 dB an octave above it; a trim that did not come with the resonance
// would put the corner several decibels high.
@(test)
test_chamberlin_resonance_is_the_knob_position_with_an_input_trim :: proc(t: ^testing.T) {
	r := f32(80) / 127
	expect_gain(t, .Low_Pass, r, 0, -0.1, "low pass, resonance 80")
	expect_gain(t, .Low_Pass, r, 1, -18.2, "low pass, resonance 80")
	expect_gain(t, .Low_Pass, r, 2, -31.4, "low pass, resonance 80")
	expect_gain(t, .Band_Pass, r, 1, -10.8, "band pass, resonance 80")
	expect_gain(t, .High_Pass, r, -2, -25.7, "high pass, resonance 80")
}

@(test)
test_chamberlin_high_and_band_pass_taps :: proc(t: ^testing.T) {
	expect_gain(t, .High_Pass, 0, -3, -33.3, "high pass")
	expect_gain(t, .High_Pass, 0, -1, -8.4, "high pass")
	expect_gain(t, .Band_Pass, 0, -3, -16.6, "band pass")
	expect_gain(t, .Band_Pass, 0, 2, -13.0, "band pass")
}

// The output is held to +/-20 once the resonance is above 0.9, and not below it.
@(test)
test_chamberlin_clamps_a_runaway_output_only_when_resonant :: proc(t: ^testing.T) {
	c: dsp.Chamberlin
	dsp.chamberlin_set_cutoff(&c, 500, SR)
	peak := f32(0)
	for i in 0 ..< 20000 {
		x := f32(i % 7 == 0 ? 3000.0 : 0.0)
		y := dsp.chamberlin_process(&c, x, 1.0, .Low_Pass)
		peak = max(peak, abs(y))
	}
	testing.expect_value(t, peak, f32(20))

	d: dsp.Chamberlin
	dsp.chamberlin_set_cutoff(&d, 500, SR)
	unclamped := f32(0)
	for i in 0 ..< 200 {
		y := dsp.chamberlin_process(&d, i == 0 ? f32(10.0) : 0.0, 0.5, .Low_Pass)
		unclamped = max(unclamped, abs(y))
	}
	testing.expectf(t, unclamped > 0 && unclamped < 20, "got %v", unclamped)
}

@(test)
test_chamberlin_survives_non_finite_input :: proc(t: ^testing.T) {
	c: dsp.Chamberlin
	dsp.chamberlin_set_cutoff(&c, 1000, SR)
	nan := f32(math.nan_f32())
	for _ in 0 ..< 10 {
		y := dsp.chamberlin_process(&c, nan, 0.5, .Low_Pass)
		testing.expect(t, !math.is_nan(y) && !math.is_inf(y), "a non-finite input reached the output")
	}
	testing.expect(t, !math.is_nan(c.lp) && !math.is_nan(c.bp), "a non-finite input stayed in the state")
}
