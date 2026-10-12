package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// Gain of the fifth filter type at one frequency, from a sine on the linear part
// of its input node.
//
// The reference numbers below were read off the reference with `s1probe arch
// filtertype --values 64,<resonance>`: noise through type 4 at cutoff 64,
// transfer against the open filter, at the octaves around 585.2 Hz (cutoff 64 is
// position 515 on the reference's axis). That noise is loud enough to bend the
// input node, so an absolute level from a quiet sine is about a decibel above it
// and means nothing here. What is compared is the *difference* between two
// frequencies, which is the shape and does not depend on the level.
diode_gain_db :: proc(resonance: f32, hz: f64) -> f64 {
	l: dsp.Diode_Ladder
	dsp.diode_ladder_set(&l, engine.filter_index_hz(engine.filter_knob_index(64)), resonance, SR)
	total := 48000
	energy_in, energy_out := 0.0, 0.0
	for i in 0 ..< total {
		x := f32(0.01 * math.sin(2 * math.PI * hz * f64(i) / f64(SR)))
		y := dsp.diode_ladder_process(&l, x)
		if i >= total / 2 {
			energy_in += f64(x * x)
			energy_out += f64(y * y)
		}
	}
	return 10 * math.log10(energy_out / energy_in)
}

expect_diode_shape :: proc(t: ^testing.T, resonance: f32, from_octave, to_octave: f64, want: f64) {
	a := diode_gain_db(resonance, 585.2 * math.pow(2.0, from_octave))
	b := diode_gain_db(resonance, 585.2 * math.pow(2.0, to_octave))
	testing.expectf(
		t,
		abs((b - a) - want) < 0.8,
		"resonance %.2f, %+.0f to %+.0f octaves: %.2f dB, reference %.2f dB",
		resonance, from_octave, to_octave, b - a, want,
	)
}

// Resonance 0: -5.7 at -2 octaves, -20.8 at the corner, -31.9 and -63.0 at +1 and
// +3.
@(test)
test_diode_ladder_shape_matches_the_reference_at_resonance_zero :: proc(t: ^testing.T) {
	expect_diode_shape(t, 0, -2, 0, -15.1)
	expect_diode_shape(t, 0, 0, 1, -11.1)
	expect_diode_shape(t, 0, 1, 3, -31.1)
}

// The slope above the corner stays near 15 dB per octave as the resonance rises,
// which a four-pole ladder of the other kind does not do: stored 80 is -22.3 and
// -37.1 dB at +1 and +2 octaves, stored 110 is -20.3 and -35.2.
@(test)
test_diode_ladder_slope_above_the_corner_holds_with_resonance :: proc(t: ^testing.T) {
	expect_diode_shape(t, f32(80) / 127, 1, 2, -14.8)
	expect_diode_shape(t, f32(110) / 127, 1, 2, -14.9)
}

// And the resonance raises the corner against the stopband, as the reference's
// does: the corner stands 11.1 dB over the octave above it at stored 0, 16.5 at
// stored 80 and 20.2 at stored 110.
@(test)
test_diode_ladder_resonance_lifts_the_corner_over_the_stopband :: proc(t: ^testing.T) {
	spread :: proc(resonance: f32) -> f64 {
		return diode_gain_db(resonance, 585.2) - diode_gain_db(resonance, 1170.4)
	}
	flat, mid, high := spread(0), spread(f32(80) / 127), spread(f32(110) / 127)
	testing.expectf(t, mid > flat + 4 && high > mid + 2, "corner over +1 octave: %v, %v, %v", flat, mid, high)
}

// Up to 48 kHz the section runs twice per sample, above it once.
@(test)
test_diode_ladder_oversamples_up_to_48_khz :: proc(t: ^testing.T) {
	l: dsp.Diode_Ladder
	dsp.diode_ladder_set(&l, 500, 0.3, 48000)
	testing.expect_value(t, l.oversample, 2)
	dsp.diode_ladder_set(&l, 500, 0.3, 44100)
	testing.expect_value(t, l.oversample, 2)
	dsp.diode_ladder_set(&l, 500, 0.3, 96000)
	testing.expect_value(t, l.oversample, 1)
}

// The input node saturates: a hundredfold louder input is nowhere near a hundred
// times louder at the output.
@(test)
test_diode_ladder_saturates_its_input :: proc(t: ^testing.T) {
	peak_for :: proc(amplitude: f32) -> f32 {
		l: dsp.Diode_Ladder
		dsp.diode_ladder_set(&l, 2000, 0.2, SR)
		peak := f32(0)
		for i in 0 ..< 4800 {
			x := amplitude * f32(math.sin(2 * math.PI * 200.0 * f64(i) / f64(SR)))
			peak = max(peak, abs(dsp.diode_ladder_process(&l, x)))
		}
		return peak
	}
	quiet, loud := peak_for(0.05), peak_for(5.0)
	testing.expectf(t, loud / quiet < 60, "a hundred times the input gave %v times the output", loud / quiet)
}

@(test)
test_diode_ladder_survives_non_finite_input_and_full_resonance :: proc(t: ^testing.T) {
	l: dsp.Diode_Ladder
	dsp.diode_ladder_set(&l, 800, 1.0, SR)
	nan := f32(math.nan_f32())
	for i in 0 ..< 200 {
		y := dsp.diode_ladder_process(&l, i == 5 ? nan : f32(0.3))
		testing.expect(t, !math.is_nan(y) && !math.is_inf(y), "a non-finite sample reached the output")
	}
}
