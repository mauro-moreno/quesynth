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
// A first-order section, bilinear rather than the shared one-pole coefficient.
//
// `one_pole_coef` is the linear approximation to 1 - exp(-2*pi*f/fs), which its
// own comment calls accurate well below Nyquist. The top of this knob is not well
// below Nyquist: at 7.2 kHz the coefficient comes out 0.94, which is very nearly
// no filter at all, and taking that away from the input leaves a high pass far
// steeper than the one asked for -- 22.6 dB too much on a patch with the sub up.
// Pre-warping the corner with a tangent instead puts the -3 dB point where the
// measurement says, at any fraction of the sample rate.
Tone :: struct {
	x_prev:   f32,
	y_prev:   f32,
	a0:       f32,
	a1:       f32,
	b1:       f32,
	coef_for: f32,
	coef_sr:  f32,
}

// The tilt is one pole whose corner sweeps, and both halves are measured.
//
// It used to be one fixed corner per side with the knob mixing dry against it,
// which is the wrong shape as well as the wrong size: at the top of the knob a
// mix can only reach the corner it was given, and ours reached 900 Hz where the
// reference reaches seven kilohertz. On a patch with the sub oscillator up -- all
// of its energy an octave down, exactly what this control is there to remove --
// that read as 12.1 dB too loud.
//
// Measured by sweeping a sine across seven octaves at each setting and reading
// the gain against the knob's own centre. Every setting is a single pole to
// within 0.05 dB across the whole sweep, so the shape is not in doubt:
//
//   tone  96   high pass at   283.6 Hz      tone   0   low pass at   200.3 Hz
//   tone 112   high pass at  1503.6 Hz      tone  16   low pass at   643.3 Hz
//   tone 127   high pass at  7198.2 Hz      tone  32   low pass at  2091.4 Hz
//
// The corner is exponential in the knob and the two halves do not share a rate:
// upward it moves 9.482 octaves across the half-knob, downward 6.663. At the
// centre both are past the audible band -- 10 Hz one way, 22 kHz the other --
// which is what makes the centre flat.
TONE_HIGHPASS_BASE_HZ :: f32(10.06)
TONE_HIGHPASS_OCTAVES :: f32(9.482)
TONE_LOWPASS_TOP_HZ :: f32(21798.0)
TONE_LOWPASS_OCTAVES :: f32(6.663)

tone_reset :: proc "contextless" (t: ^Tone) {
	t.x_prev = 0
	t.y_prev = 0
	t.a0 = 1
	t.a1 = 0
	t.b1 = 0
	t.coef_for = 0
	t.coef_sr = 0
}

// The corner for one setting of the knob, in hertz.
tone_corner_hz :: proc "contextless" (amount: f32) -> f32 {
	a := clamp32(amount, -1, 1)
	if a >= 0 {
		return TONE_HIGHPASS_BASE_HZ * math.pow(f32(2.0), TONE_HIGHPASS_OCTAVES * a)
	}
	return TONE_LOWPASS_TOP_HZ * math.pow(f32(2.0), TONE_LOWPASS_OCTAVES * a)
}

// `amount` is -1..1: negative cuts the highs, positive cuts the lows, zero is
// flat and costs one comparison.
tone_process :: proc "contextless" (t: ^Tone, x, amount, sample_rate: f32) -> f32 {
	a := clamp32(amount, -1, 1)
	if a == 0 {
		return x
	}
	if t.coef_for != a || t.coef_sr != sample_rate {
		hz := clamp32(tone_corner_hz(a), 1.0, sample_rate * 0.49)
		k := math.tan(0.5 * TAU * hz / sample_rate)
		t.b1 = (1.0 - k) / (1.0 + k)
		if a < 0 {
			t.a0 = k / (1.0 + k)
			t.a1 = t.a0
		} else {
			t.a0 = 1.0 / (1.0 + k)
			t.a1 = -t.a0
		}
		t.coef_for = a
		t.coef_sr = sample_rate
	}

	y := t.a0 * x + t.a1 * t.x_prev + t.b1 * t.y_prev
	t.x_prev = x
	t.y_prev = flush_denormal(y)
	return y
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
