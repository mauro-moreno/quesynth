package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// Gain in decibels of a biquad at one frequency, evaluated on the unit circle.
biquad_db :: proc(c: dsp.Biquad_Coefficients, hz, sample_rate: f64) -> f64 {
	w := 2 * math.PI * hz / sample_rate
	c1, s1 := math.cos(w), math.sin(w)
	c2, s2 := math.cos(2 * w), math.sin(2 * w)
	nr := f64(c.b0) + f64(c.b1) * c1 + f64(c.b2) * c2
	ni := -(f64(c.b1) * s1 + f64(c.b2) * s2)
	dr := 1 + f64(c.a1) * c1 + f64(c.a2) * c2
	di := -(f64(c.a1) * s1 + f64(c.a2) * s2)
	return 10 * math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
}

// Peak level, and the width in octaves between the two points at half that many
// decibels, of the equaliser's peak at the settings the reference was measured
// at: frequency stored 66 (1002 Hz), level stored 127 (+24.8 dB). The reference
// numbers are from `s1probe arch eq`, noise through the EQ against the flat
// render, and come back the same whether the level is a boost or the mirror cut.
//
//   Q stored    32      64
//   peak dB   +24.78  +24.74
//   width oct  2.83    1.83
//
// Only these two are used. The probe reads a smoothed spectrum, so where the peak
// is narrower than its resolution (Q 96 and 127 read +24.60 and +24.24 for a
// filter whose centre is +24.80 by construction) or wider than the band it looks
// in (Q 0), the reading is the instrument's and not the filter's.
@(test)
test_equalizer_peak_matches_the_reference_where_it_can_be_read :: proc(t: ^testing.T) {
	freq := engine.eq_frequency_hz(66)
	testing.expectf(t, abs(freq - 1002.1) < 0.5, "stored 66 is %v Hz", freq)

	stored := [2]int{32, 64}
	peaks := [2]f64{24.78, 24.74}
	widths := [2]f64{2.83, 1.83}
	for i in 0 ..< 2 {
		for sign in ([2]f32{1, -1}) {
			c := dsp.peaking_coefficients(freq, sign * engine.eq_gain_db(127), engine.eq_q(stored[i]), SR)
			peak := 0.0
			for step in 0 ..< 4000 {
				hz := 100.0 * math.pow(100.0, f64(step) / 3999)
				peak = max(peak, abs(biquad_db(c, hz, f64(SR))))
			}
			lower, upper := 0.0, 0.0
			for step in 0 ..< 40000 {
				hz := 20.0 * math.pow(1000.0, f64(step) / 39999)
				if abs(biquad_db(c, hz, f64(SR))) >= peak / 2 {
					if lower == 0 {lower = hz}
					upper = hz
				}
			}
			octaves := math.log2(upper / lower)
			testing.expectf(t, abs(peak - peaks[i]) < 0.1, "Q %v: peak %.2f dB, reference %.2f", stored[i], peak, peaks[i])
			testing.expectf(t, abs(octaves - widths[i]) < 0.06, "Q %v: width %.2f octaves, reference %.2f", stored[i], octaves, widths[i])
		}
	}
}

// The gain at the centre is exactly the level asked for, by construction, and a
// level of zero is the identity.
@(test)
test_equalizer_peak_hits_its_level_at_the_centre :: proc(t: ^testing.T) {
	for gain in ([?]f32{-24.8, -6, 6, 24.8}) {
		c := dsp.peaking_coefficients(2000, gain, 3, SR)
		testing.expectf(t, abs(biquad_db(c, 2000, f64(SR)) - f64(gain)) < 0.01, "level %v", gain)
	}
	flat := dsp.peaking_coefficients(2000, 0, 3, SR)
	testing.expectf(t, abs(biquad_db(flat, 500, f64(SR))) < 0.001 && abs(biquad_db(flat, 9000, f64(SR))) < 0.001, "a level of zero is not flat")
}

// The controls are the reference's formulas in the stored state.
@(test)
test_equalizer_controls_are_the_stored_state_formulas :: proc(t: ^testing.T) {
	testing.expectf(t, abs(engine.eq_frequency_hz(0) - 50) < 0.01, "got %v", engine.eq_frequency_hz(0))
	testing.expectf(t, abs(engine.eq_frequency_hz(127) - 16000) < 1, "got %v", engine.eq_frequency_hz(127))
	testing.expect_value(t, engine.eq_gain_db(64), f32(0))
	testing.expectf(t, abs(engine.eq_gain_db(127) - 24.80) < 0.01, "got %v", engine.eq_gain_db(127))
	testing.expectf(t, abs(engine.eq_gain_db(0) + 25.20) < 0.01, "got %v", engine.eq_gain_db(0))
	testing.expectf(t, abs(engine.eq_q(0) - 1) < 1e-4 && abs(engine.eq_q(127) - 10) < 1e-3, "Q %v..%v", engine.eq_q(0), engine.eq_q(127))
}

@(test)
test_tone_corners_follow_the_reference_travel :: proc(t: ^testing.T) {
	low := engine.eq_tone_setting(0)
	testing.expect_value(t, low.mode, dsp.Tone_Mode.Low_Pass)
	testing.expectf(t, abs(low.hz - 200) < 0.1, "got %v", low.hz)
	high := engine.eq_tone_setting(127)
	testing.expect_value(t, high.mode, dsp.Tone_Mode.High_Pass)
	testing.expectf(t, abs(high.hz - 7206.6) < 1, "got %v", high.hz)
	// The delay's travel is a little different and its centre is a bypass.
	testing.expect_value(t, engine.delay_tone_setting(64).mode, dsp.Tone_Mode.Off)
	testing.expectf(t, abs(engine.delay_tone_setting(63).hz - 22000) < 1, "got %v", engine.delay_tone_setting(63).hz)
	testing.expectf(t, abs(engine.delay_tone_setting(127).hz - 8000) < 1, "got %v", engine.delay_tone_setting(127).hz)
	testing.expectf(t, abs(engine.delay_tone_setting(65).hz - 10) < 0.01, "got %v", engine.delay_tone_setting(65).hz)
}

// Gain of the tone section at one frequency, from a sine.
tone_gain_db :: proc(s: dsp.Tone_Setting, hz: f64) -> f64 {
	tone: dsp.Tone
	total := 24000
	energy_in, energy_out := 0.0, 0.0
	for i in 0 ..< total {
		x := f32(math.sin(2 * math.PI * hz * f64(i) / f64(SR)))
		y := dsp.tone_process(&tone, x, s, SR)
		if i >= total / 2 {
			energy_in += f64(x * x)
			energy_out += f64(y * y)
		}
	}
	return 10 * math.log10(energy_out / energy_in)
}

// The sections are bilinear with the corner entered as 2 pi f and not
// pre-warped, so the -3 dB point of a corner at 7.2 kHz at 48 kHz is
// (sr/pi) * atan(pi f / sr) = 6.7 kHz, and the equaliser's centre, a low pass at
// 22 kHz, is 1.1 dB down at 10 kHz. Both follow from the definition.
@(test)
test_tone_sections_are_not_prewarped :: proc(t: ^testing.T) {
	corner := 7200.0
	minus_3_db := 48000.0 / math.PI * math.atan(math.PI * corner / 48000.0)
	testing.expectf(t, abs(minus_3_db - 6700) < 100, "analytic -3 dB point %v", minus_3_db)
	got := tone_gain_db({.High_Pass, f32(corner)}, minus_3_db)
	testing.expectf(t, abs(got + 3.01) < 0.1, "high pass at its -3 dB point: %.2f dB", got)

	centre := tone_gain_db({.Low_Pass, 22000}, 10000)
	testing.expectf(t, abs(centre + 1.07) < 0.1, "the centre's low pass at 10 kHz: %.2f dB", centre)
	testing.expectf(t, abs(tone_gain_db({.Low_Pass, 22000}, 100)) < 0.05, "and it is flat low down")

	testing.expect_value(t, tone_gain_db({.Off, 1000}, 1000), 0.0)
}

// A low pass whose corner is at or above half the sample rate is not in circuit.
@(test)
test_tone_is_out_of_circuit_past_its_range :: proc(t: ^testing.T) {
	testing.expect(t, !dsp.tone_is_active({.Low_Pass, 25000}, 48000), "a 25 kHz low pass at 48 kHz")
	testing.expect(t, dsp.tone_is_active({.Low_Pass, 22000}, 48000), "a 22 kHz low pass at 48 kHz")
	testing.expect(t, !dsp.tone_is_active({.High_Pass, 0.5}, 48000), "a high pass under 1 Hz")
}
