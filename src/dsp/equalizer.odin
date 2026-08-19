package dsp

import "core:math"

// The equaliser: one parametric peak, plus a tone tilt.
//
// That is exactly what the manual describes -- "one parametric equaliser and a
// high pass / low pass filter" -- and the parameters back it up. Parameter 61
// reads out in hertz from 50 Hz to 16 kHz, parameter 62 in decibels from -25.2 to
// +24.8 with **0.0 dB at exactly stored 64**, so the knob's centre is flat by
// construction. Parameter 63 is the peak's Q and parameter 60 the tone, both bare
// 0..127.
//
// There is no on/off parameter for this section, and it does not need one: at the
// centre of the level knob the peak is flat and at the centre of the tone knob the
// tilt is flat, so a patch that leaves them alone passes through unchanged.

// Shared by the equaliser and the delay, which both offer the same one-knob
// tilt: low pass one way, high pass the other, flat in the middle.
//
// Extracted rather than written twice. It is the same control in the reference --
// the manual describes parameter 60 and parameter 98 in the same words -- and two
// copies of one law is how they drift apart.
Tone :: struct {
	low:  f32,
	high: f32,
}

// Corner frequencies for the tilt. Chosen, not measured: both displays are a bare
// 0..127 and carry no frequency. Placed so the extremes are clearly audible
// without either end silencing the signal.
TONE_LOW_HZ :: f32(700.0)
TONE_HIGH_HZ :: f32(900.0)

tone_reset :: proc "contextless" (t: ^Tone) {
	t.low = 0
	t.high = 0
}

// `amount` is -1..1: negative cuts the highs, positive cuts the lows, zero is
// flat and costs one comparison.
tone_process :: proc "contextless" (t: ^Tone, x, amount, sample_rate: f32) -> f32 {
	a := clamp32(amount, -1, 1)
	if a == 0 {
		return x
	}

	if a < 0 {
		mix := -a
		coef := one_pole_coef(TONE_LOW_HZ, sample_rate)
		// A stronger setting moves the corner down, so the cut deepens.
		t.low += (x - t.low) * (coef + (1.0 - coef) * (1.0 - mix))
		t.low = flush_denormal(t.low)
		return lerp32(x, t.low, mix)
	}

	coef := one_pole_coef(TONE_HIGH_HZ, sample_rate)
	t.high += (x - t.high) * coef
	t.high = flush_denormal(t.high)
	return lerp32(x, x - t.high, a)
}

// One channel of a peaking biquad, direct form I.
//
// Direct form I keeps the two input and two output histories separately, which
// costs one more state variable than the transposed form and in exchange does not
// need the coefficients to be re-derived when they change mid-stream: a moving
// centre frequency simply takes effect on the next sample.
Biquad :: struct {
	x1, x2: f32,
	y1, y2: f32,
}

Biquad_Coefficients :: struct {
	b0, b1, b2: f32,
	a1, a2:     f32,
}

biquad_reset :: proc "contextless" (b: ^Biquad) {
	b^ = {}
}

// The RBJ peaking-EQ coefficients.
//
// Clamped rather than trusted: the centre frequency is held below Nyquist because
// the tangent in `tan(w0/2)` -- and `sin(w0)` here -- stops being meaningful past
// it, and Q is held above zero because a zero would divide by it.
peaking_coefficients :: proc "contextless" (
	freq_hz, gain_db, q, sample_rate: f32,
) -> Biquad_Coefficients {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}
	f := freq_hz
	if !is_finite(f) {
		f = 1000.0
	}
	f = clamp32(f, 10.0, sr * 0.45)

	quality := q
	if !is_finite(quality) || quality < 0.05 {
		quality = 0.05
	}

	gain := gain_db
	if !is_finite(gain) {
		gain = 0
	}

	// A is the square root of the linear gain: the cookbook's peaking form uses
	// it on both sides so the skirt gain stays unity.
	a := math.pow(f32(10.0), gain / 40.0)
	w0 := TAU * f / sr
	cos_w0 := math.cos(w0)
	alpha := math.sin(w0) / (2.0 * quality)

	a0 := 1.0 + alpha / a
	if abs(a0) < 1.0e-12 {
		return {b0 = 1}
	}
	inv := 1.0 / a0

	return Biquad_Coefficients {
		b0 = (1.0 + alpha * a) * inv,
		b1 = (-2.0 * cos_w0) * inv,
		b2 = (1.0 - alpha * a) * inv,
		a1 = (-2.0 * cos_w0) * inv,
		a2 = (1.0 - alpha / a) * inv,
	}
}

biquad_process :: proc "contextless" (b: ^Biquad, c: ^Biquad_Coefficients, x: f32) -> f32 {
	input := x
	if !is_finite(input) {
		input = 0
	}

	y := c.b0 * input + c.b1 * b.x1 + c.b2 * b.x2 - c.a1 * b.y1 - c.a2 * b.y2

	// A single non-finite sample would otherwise live in the history forever, the
	// same hazard the state variable filter guards against.
	if !is_finite(y) {
		biquad_reset(b)
		return 0
	}

	b.x2 = b.x1
	b.x1 = input
	b.y2 = b.y1
	b.y1 = flush_denormal(y)
	return b.y1
}

Equalizer_Params :: struct {
	// Parameter 61, read straight off the display in hertz.
	freq_hz: f32,
	// Parameter 62, in decibels. Zero is flat.
	gain_db: f32,
	// Parameter 63, as a Q.
	q:       f32,
	// Parameter 60, -1..1.
	tone:    f32,
}

Equalizer :: struct {
	peak: [2]Biquad,
	tilt: [2]Tone,
}

equalizer_reset :: proc "contextless" (e: ^Equalizer) {
	biquad_reset(&e.peak[0])
	biquad_reset(&e.peak[1])
	tone_reset(&e.tilt[0])
	tone_reset(&e.tilt[1])
}

// Process one stereo sample. The peak runs first, then the tilt.
equalizer_process :: proc "contextless" (
	e: ^Equalizer,
	left_in, right_in: f32,
	p: ^Equalizer_Params,
	coefficients: ^Biquad_Coefficients,
	sample_rate: f32,
) -> (
	left, right: f32,
) {
	l := left_in
	r := right_in

	// A flat setting is the common case -- most patches leave this section alone
	// -- and skipping the biquad there keeps it honest as well as cheap: running
	// it with unity coefficients would still ring on whatever is in its history.
	if p.gain_db != 0 {
		l = biquad_process(&e.peak[0], coefficients, l)
		r = biquad_process(&e.peak[1], coefficients, r)
	}

	l = tone_process(&e.tilt[0], l, p.tone, sample_rate)
	r = tone_process(&e.tilt[1], r, p.tone, sample_rate)
	return sanitize(l), sanitize(r)
}

// Band-pass coefficients, RBJ's constant-peak-gain form.
//
// Added for the effect unit's phasers, which the reference turned out to build
// out of a swept *resonance* rather than a comb of notches: a saw-comb
// measurement showed a broad peak reaching +19 dB with attenuation either side of
// it, and no notch anywhere with any prominence. A peaking EQ is the wrong shape
// for that -- it returns to unity away from its centre where the reference falls
// away -- so this is a band pass.
bandpass_coefficients :: proc "contextless" (
	freq_hz, q, sample_rate: f32,
) -> Biquad_Coefficients {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}
	f := freq_hz
	if !is_finite(f) {
		f = 1000.0
	}
	f = clamp32(f, 10.0, sr * 0.45)

	quality := q
	if !is_finite(quality) || quality < 0.05 {
		quality = 0.05
	}

	w0 := TAU * f / sr
	alpha := math.sin(w0) / (2.0 * quality)

	a0 := 1.0 + alpha
	if abs(a0) < 1.0e-12 {
		return {b0 = 1}
	}
	inv := 1.0 / a0

	return Biquad_Coefficients {
		b0 = alpha * inv,
		b1 = 0,
		b2 = -alpha * inv,
		a1 = (-2.0 * math.cos(w0)) * inv,
		a2 = (1.0 - alpha) * inv,
	}
}
