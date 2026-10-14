package dsp

import "core:math"

// The reference's 24 dB low pass: four one-pole stages in cascade with the last
// one's output fed back to the input, the familiar Moog-style ladder.
//
// It is the reference's own coefficient set and not a design of ours. For a
// corner `fc` and sample rate `sr`, with `f = 2 fc / sr`:
//
//   k = 3.6 f - 1.6 f^2 - 1            the stage's own feedback
//   p = (k + 1) / 2                    the stage gain
//   r = resonance * exp((1 - 0.5 (4.3 f - 2.5 f^2)) * 1.386249)
//
// `r` is the loop gain. The exponential is what makes the resonance knob a
// straight line in the reference's own units while the loop gain it asks for
// grows with the corner, so there is no resonance table here: the knob is
// `state/127` and the rest follows from the corner.
//
// All three are smoothed per sample toward their targets, with 98% of a step
// covered in a millisecond, which is what keeps a moving corner from clicking.
// The first coefficients after a note starts are the targets themselves.
//
// Past a resonance of 0.9 the output is held to +/-20, and the held value is
// what feeds back, so it also bounds the loop.
MOOG_LADDER_K_LINEAR :: f64(3.6)
MOOG_LADDER_K_QUADRATIC :: f64(1.6)
MOOG_LADDER_R_LINEAR :: f64(4.3)
MOOG_LADDER_R_QUADRATIC :: f32(2.5)
MOOG_LADDER_R_SCALE :: f64(1.386249)
MOOG_LADDER_SMOOTH_REMAINDER :: f64(0.02)
MOOG_LADDER_SMOOTH_SECONDS :: f64(0.001)
MOOG_LADDER_CLAMP_FROM :: f32(0.9)
MOOG_LADDER_CLAMP_LEVEL :: f32(20.0)

Moog_Ladder :: struct {
	input_before: f32,
	y1:           f32,
	y2:           f32,
	y3:           f32,
	y4:           f32,

	// The coefficients in use and the ones they are moving toward.
	k:        f32,
	p:        f32,
	r:        f32,
	k_target: f32,
	p_target: f32,
	r_target: f32,
	smooth:   f32,
	primed:   bool,

	hz:        f32,
	resonance: f32,
	rate:      f32,
	valid:     bool,
}

MOOG_LADDER_NYQUIST_FRACTION :: f64(0.45)

moog_ladder_reset :: proc "contextless" (l: ^Moog_Ladder) {
	l.input_before = 0
	l.y1 = 0
	l.y2 = 0
	l.y3 = 0
	l.y4 = 0
	l.primed = false
	l.valid = false
}

moog_ladder_set :: proc "contextless" (l: ^Moog_Ladder, hz, resonance, sample_rate: f32) {
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

	// Held under the same fraction of the sample rate as the diode ladder: at 22.05 kHz the
	// top of the cutoff axis would otherwise put the coefficient past one and the filter
	// diverges. At 44.1 kHz and above the axis stays below it and nothing changes.
	held_hz := min(f64(hz), MOOG_LADDER_NYQUIST_FRACTION * f64(sr))
	f := f64(f32(held_hz * 2.0 / f64(sr)))
	k := f * MOOG_LADDER_K_LINEAR - f * MOOG_LADDER_K_QUADRATIC * f - 1.0
	l.k_target = f32(k)
	l.p_target = (l.k_target + 1.0) * 0.5

	shape := f * MOOG_LADDER_R_LINEAR - f * f64(MOOG_LADDER_R_QUADRATIC) * f
	scale := math.exp((1.0 - shape * 0.5) * MOOG_LADDER_R_SCALE)
	l.r_target = f32(scale) * clamp32(resonance, 0, 1)

	l.smooth = f32(1.0 - math.pow(MOOG_LADDER_SMOOTH_REMAINDER, 1.0 / (MOOG_LADDER_SMOOTH_SECONDS * f64(sr))))
	if !l.primed {
		l.k, l.p, l.r = l.k_target, l.p_target, l.r_target
		l.primed = true
	}
}

moog_ladder_process :: proc "contextless" (l: ^Moog_Ladder, x: f32) -> f32 {
	input := is_finite(x) ? x : 0.0
	newest := input - l.y4 * l.r
	n1 := (newest + l.input_before) * l.p - l.y1 * l.k
	n2 := (n1 + l.y1) * l.p - l.y2 * l.k
	n3 := (n2 + l.y2) * l.p - l.y3 * l.k
	n4 := (n3 + l.y3) * l.p - l.y4 * l.k

	out := n4
	if l.resonance > MOOG_LADDER_CLAMP_FROM {
		out = clamp32(out, -MOOG_LADDER_CLAMP_LEVEL, MOOG_LADDER_CLAMP_LEVEL)
	}

	l.input_before = newest
	l.y1, l.y2, l.y3, l.y4 = n1, n2, n3, out
	l.k += (l.k_target - l.k) * l.smooth
	l.p += (l.p_target - l.p) * l.smooth
	l.r += (l.r_target - l.r) * l.smooth

	if !is_finite(l.y1) || !is_finite(l.y2) || !is_finite(l.y3) || !is_finite(l.y4) {
		l.input_before = 0
		l.y1, l.y2, l.y3, l.y4 = 0, 0, 0, 0
		return 0
	}
	l.y1 = flush_denormal(l.y1)
	l.y2 = flush_denormal(l.y2)
	l.y3 = flush_denormal(l.y3)
	l.y4 = flush_denormal(l.y4)
	return out
}
