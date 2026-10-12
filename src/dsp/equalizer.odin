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
// The tone control: one first-order section, a low pass one way and a high pass
// the other.
//
// Both are bilinear sections with the corner entered as `2 pi f` and the sample
// rate as `2 sr`, *not* pre-warped, so the corner the knob names is where the
// analogue prototype has its -3 dB point and the digital one sits below it by
// the usual tangent: 6.7 kHz where the knob says 7.2 at 48 kHz. That is what the
// reference does and this does the same; a tangent that put the -3 dB point
// where the knob says would be a better filter and a different one.
//
// Neither end is flat on its own. The equaliser's tone at its centre is a low
// pass at 22 kHz, which at 48 kHz is 1.1 dB down at 10 kHz, and it stays in
// circuit as long as that corner is under half the sample rate; the high pass is
// in circuit above 1 Hz. The delay's tone is bypassed at its centre.
Tone_Mode :: enum u8 {
	Off,
	Low_Pass,
	High_Pass,
}

Tone_Setting :: struct {
	mode: Tone_Mode,
	hz:   f32,
}

Tone :: struct {
	x_prev:   f32,
	y_prev:   f32,
	b:        f32,
	a:        f32,
	for_mode: Tone_Mode,
	for_hz:   f32,
	for_rate: f32,
}

tone_reset :: proc "contextless" (t: ^Tone) {
	t^ = {}
}

tone_is_active :: proc "contextless" (s: Tone_Setting, sample_rate: f32) -> bool {
	switch s.mode {
	case .Off:
		return false
	case .Low_Pass:
		return s.hz < sample_rate * 0.5
	case .High_Pass:
		return s.hz > 1.0
	}
	return false
}

tone_process :: proc "contextless" (t: ^Tone, x: f32, s: Tone_Setting, sample_rate: f32) -> f32 {
	if !tone_is_active(s, sample_rate) {
		return x
	}
	if t.for_mode != s.mode || t.for_hz != s.hz || t.for_rate != sample_rate {
		two_sr := f64(sample_rate) * 2.0
		corner := f64(s.hz * 2.0) * math.PI
		inv := 1.0 / (corner + two_sr)
		t.b = f32(s.mode == .Low_Pass ? corner * inv : two_sr * inv)
		t.a = f32((two_sr - corner) * inv)
		t.for_mode = s.mode
		t.for_hz = s.hz
		t.for_rate = sample_rate
	}

	edge := s.mode == .Low_Pass ? x + t.x_prev : x - t.x_prev
	y := edge * t.b + t.y_prev * t.a
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

// The reference's peaking filter, which is not the cookbook one.
//
// It is a matched pole-zero design. The analogue prototype has a numerator and a
// denominator damping, `1/2Q` and `G/2Q` with `G` the gain at the centre as an
// amplitude ratio, swapped for a cut; each is mapped to the z plane by
// `z = exp(sT)`, which gives a pole pair at radius `exp(-w0 T zeta)` and angle
// `w0 T sqrt(1 - zeta^2)`, or a pair on the real axis with a hyperbolic cosine
// once the damping is past one. The numerator is then scaled so that the gain at
// `w0` is exactly `G`.
//
// Two consequences. The shape is not symmetric between boost and cut the way a
// cookbook peak is, and `q` here is the reference's own `10^(state/127)`, which
// runs from 1 to 10, not the 0.3-to-8 this took before: the fitted Q that stood
// in for it ranged over 0.23 to 2.28 and left 0.3 dB of residual that no Q
// could remove.
//
// The centre is held below Nyquist because the section is not meaningful past it.
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
	f = clamp32(f, 1.0, sr * 0.49)

	quality := q
	if !is_finite(quality) || quality < 0.05 {
		quality = 0.05
	}

	gain := gain_db
	if !is_finite(gain) {
		gain = 0
	}

	step := 1.0 / f64(sr)
	w0 := f64(f) * 2.0 * math.PI
	amplitude := math.pow(f64(10.0), f64(gain) * 0.05)
	half_over_q := 1.0 / (f64(quality) * 2.0)
	numerator_damping, denominator_damping: f64
	if amplitude >= 1.0 {
		denominator_damping = half_over_q
		numerator_damping = half_over_q * amplitude
	} else {
		numerator_damping = half_over_q
		denominator_damping = half_over_q / amplitude
	}

	pair :: proc "contextless" (damping, w0, step: f64) -> (c1, c2: f64) {
		radius := math.exp(-(w0 * step * damping))
		angle: f64
		if abs(damping) <= 1.0 {
			angle = math.cos(math.sqrt(1.0 - damping * damping) * step * w0)
		} else {
			angle = math.cosh(math.sqrt(damping * damping - 1.0) * step * w0)
		}
		return angle * radius * -2.0, radius * radius
	}
	n1, n2 := pair(numerator_damping, w0, step)
	d1, d2 := pair(denominator_damping, w0, step)

	x := w0 * step
	cx, sx := math.cos(x), math.sin(x)
	magnitude :: proc "contextless" (c1, c2, cx, sx: f64) -> f64 {
		real := (c2 + 1.0) * cx + c1
		imag := (c2 - 1.0) * sx
		return math.sqrt(real * real + imag * imag)
	}
	scale := magnitude(d1, d2, cx, sx) * amplitude / magnitude(n1, n2, cx, sx)

	return Biquad_Coefficients {
		b0 = f32(scale),
		b1 = f32(scale * n1),
		b2 = f32(scale * n2),
		a1 = f32(d1),
		a2 = f32(d2),
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
	// Parameter 60, as the corner and side it names.
	tone:    Tone_Setting,
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
