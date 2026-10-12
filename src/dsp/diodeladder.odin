package dsp

import "core:math"

// The reference's fifth filter type, "LPDL": a four-stage ladder with a
// saturating input node, in double precision.
//
// It is the one type the 12 dB section and the 24 dB ladder do not cover, and it
// is not close to either: measured at resonance 0 it is 20.8 dB down at the
// corner, falls at 5.7 dB per octave below it and 15.6 above, where the 24 dB
// ladder is 12 dB down at the corner and 22.8 dB per octave above.
//
// The structure is a zero-delay-feedback ladder whose four stage gains are
// solved in closed form from one one-pole coefficient `g/(1+g)`, with the
// feedback taken through
//
//   - a Pade tanh, x * (x^2 + 27) / (9 x^2 + 27), clipped to +/-1 beyond +/-3,
//     on the summed input;
//   - a one-pole at 120 Hz that is subtracted from the loop, which is what keeps
//     the resonance from eating the bass;
//   - a feedback gain of 15 * resonance, and an output gain that rises with the
//     resonance by 1 + 3 * resonance.
//
// At sample rates up to 48 kHz the section is run twice per sample with the
// input present on the first step only and zero on the second, which doubles
// the rate the loop is solved at and costs a factor of two in level that the
// output gain puts back. The corner is 1.5 times the reference axis's frequency
// for the same position, held under 0.45 of the sample rate.
DIODE_LADDER_FEEDBACK_GAIN :: f64(15.0)
DIODE_LADDER_CORNER_SCALE :: f64(1.5)
DIODE_LADDER_NYQUIST_FRACTION :: f64(0.45)
DIODE_LADDER_FEEDBACK_HIGH_PASS_HZ :: f64(120.0)
DIODE_LADDER_INPUT_STEP :: f64(9.0 / 7.0)
DIODE_LADDER_OUTPUT_BASE :: f32(0.65)
DIODE_LADDER_OUTPUT_PER_RESONANCE :: f32(0.2)
DIODE_LADDER_OVERSAMPLE_UP_TO_HZ :: f32(48000.0)

Diode_Ladder :: struct {
	stage_a: f64,
	stage_b: f64,
	stage_c: f64,
	stage_d: f64,
	hold:    f64,

	// What the coefficients below were computed for.
	hz:         f32,
	resonance:  f32,
	rate:       f32,
	valid:      bool,
	oversample: int,

	g:         f64,
	h:         f64,
	k_inv_g1:  f64,
	c2:        f64,
	c3:        f64,
	c4:        f64,
	c16:       f64,
	c17:       f64,
	c18:       f64,
	c19:       f64,
	c24:       f64,
	c34:       f64,
	c37:       f64,
	c38:       f64,
	c20:       f64,
	c21:       f64,
	c25:       f64,
	feedback:  f64,
	loop_gain: f64,
	out_gain:  f64,
}

diode_ladder_reset :: proc "contextless" (l: ^Diode_Ladder) {
	l.stage_a = 0
	l.stage_b = 0
	l.stage_c = 0
	l.stage_d = 0
	l.hold = 0
}

// `hz` is the frequency the reference's axis gives for the current position;
// the section's own 1.5x is applied here.
diode_ladder_set :: proc "contextless" (l: ^Diode_Ladder, hz, resonance, sample_rate: f32) {
	if l.valid && hz == l.hz && resonance == l.resonance && sample_rate == l.rate {
		return
	}
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}
	l.hz = hz
	l.resonance = resonance
	l.rate = sample_rate
	l.valid = true

	l.oversample = sr <= DIODE_LADDER_OVERSAMPLE_UP_TO_HZ ? 2 : 1
	rate := f64(sr) * f64(l.oversample)
	corner := min(f64(hz) * DIODE_LADDER_CORNER_SCALE, f64(sr) * DIODE_LADDER_NYQUIST_FRACTION)
	res := f64(clamp32(resonance, 0, 1))
	k := res * DIODE_LADDER_FEEDBACK_GAIN

	pre := math.tan(corner * math.PI / rate)
	l.k_inv_g1 = 1.0 / (pre + 1.0)
	l.g = l.k_inv_g1 * pre
	l.h = l.g * 0.5
	two_h := l.h * 2.0

	c37_base := 1.0 / (1.0 - l.h * l.h)
	l.c16 = c37_base * l.h
	l.c3 = l.c16 * l.h
	c2_base := 1.0 / (1.0 - l.c3)
	l.c4 = c2_base * l.h
	l.c17 = two_h / (1.0 - two_h * l.c4)
	l.c18 = l.c3 * l.c4
	c19_base := 1.0 / (1.0 - l.c4 * l.h)
	l.c38 = c37_base * l.k_inv_g1
	l.c37 = c37_base * l.h
	l.c34 = two_h * c19_base
	l.c24 = c2_base * l.h
	l.c19 = c19_base * l.k_inv_g1
	l.c2 = c2_base * l.k_inv_g1

	hold_pre := math.tan(DIODE_LADDER_FEEDBACK_HIGH_PASS_HZ * math.PI / rate)
	hold_inv := 1.0 / (hold_pre + 1.0)
	l.c20 = hold_pre * 2.0 * hold_inv
	l.c21 = -hold_inv
	l.loop_gain = hold_inv * k
	l.feedback = k
	l.c25 = 1.0 / (l.loop_gain * l.c18 * l.c17 + 1.0)
	l.out_gain =
		f64(f32(l.oversample) * DIODE_LADDER_OUTPUT_BASE) *
		(k * f64(DIODE_LADDER_OUTPUT_PER_RESONANCE) + 1.0)
}

finite64 :: proc "contextless" (x: f64) -> bool {
	return !math.is_nan(x) && !math.is_inf(x)
}

diode_tanh :: proc "contextless" (x: f64) -> f64 {
	if x < -3.0 {
		return -1.0
	}
	if x > 3.0 {
		return 1.0
	}
	return ((x * x + 27.0) * x) / (x * 9.0 * x + 27.0)
}

diode_ladder_process :: proc "contextless" (l: ^Diode_Ladder, x: f32) -> f32 {
	input := is_finite(x) ? f64(x) : 0.0
	a, b, c, d, hold := l.stage_a, l.stage_b, l.stage_c, l.stage_d, l.hold
	out := f64(0)

	for step in 0 ..< l.oversample {
		drive := step == 0 ? input : 0.0

		s35 := a * l.k_inv_g1
		s22 := b * l.c38 + s35 * l.c37
		s23 := c * l.c2 + s22 * l.c24
		s31 := d * l.c19 + s23 * l.c34
		node :=
			((drive - (s23 * l.c3 + s31 * l.c18 + s22 * l.h + s35) * l.loop_gain) - hold * l.c21) *
			l.c25
		t := diode_tanh(node)

		s31 = t * DIODE_LADDER_INPUT_STEP * l.c17 + s31
		s23 = s31 * l.c4 + s23
		s22 = s23 * l.c16 + s22
		s35 = s22 * l.h + s35

		c = ((s22 + s31) * 0.5 - c) * l.g + s23
		b = ((s35 + s23) * 0.5 - b) * l.g + s22
		a = (s22 * 0.5 - a) * l.g + s35
		hold = hold + (s35 * l.feedback - hold) * l.c20
		d = ((s23 + t * DIODE_LADDER_INPUT_STEP) - d) * l.g + s31
		out = s22
	}

	if !finite64(a) || !finite64(b) || !finite64(c) || !finite64(d) || !finite64(hold) {
		diode_ladder_reset(l)
		return 0
	}
	l.stage_a, l.stage_b, l.stage_c, l.stage_d, l.hold = a, b, c, d, hold
	return f32(out * l.out_gain)
}
