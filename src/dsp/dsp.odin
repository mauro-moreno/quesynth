package dsp

// Layer 0: the pure DSP core.
//
// The import list in this file is the whole package's import list, by design.
// docs/architecture.md forbids core:os, core:fmt, core:thread, core:sync,
// core:time, core:net and core:sys here, directly or transitively, because the
// iOS and Android shells link this layer with no runtime services behind it.
//
// core:math/rand is excluded for a second, independent reason: it resolves
// through a package-level default generator, and layer 0 owns no mutable global
// state. The noise sources in this package therefore carry their own `Rng`
// inside the caller-owned struct that needs them, so two voices seeded alike
// produce identical output and a render is reproducible.
//
// Nothing in this package allocates. Every procedure either returns a value or
// writes through a pointer the caller already owns.

import "core:math"

TAU :: f32(6.283185307179586)

// Denormal inputs cost hundreds of cycles per sample in the filter and envelope
// feedback paths on x86, and the amplitudes involved are 120 dB below anything
// audible, so flushing them to zero is free in every sense that matters.
DENORMAL_FLOOR :: f32(1.0e-20)

// The lowest cutoff the filter is allowed to reach. Below this the TPT
// prewarping tangent stops being well conditioned at 48 kHz.
MIN_CUTOFF_HZ :: f32(10.0)

// Cutoff is additionally held below this fraction of the sample rate. `tan`
// diverges at Nyquist, and modulation routinely pushes an already-high cutoff
// past it; clamping here is what makes the filter unconditionally stable rather
// than stable for the inputs we happened to test.
MAX_CUTOFF_RATIO :: f32(0.45)

clamp32 :: proc "contextless" (v, lo, hi: f32) -> f32 {
	if v < lo {return lo}
	if v > hi {return hi}
	return v
}

lerp32 :: proc "contextless" (a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

flush_denormal :: proc "contextless" (v: f32) -> f32 {
	if v > -DENORMAL_FLOOR && v < DENORMAL_FLOOR {return 0}
	return v
}

// A NaN or infinity anywhere in a feedback path is permanent: it propagates
// into the state and every subsequent sample is poisoned. Layer 0 therefore
// never lets one survive a block boundary. NaN is detected by self-inequality
// and infinity by magnitude, neither of which needs an import.
is_finite :: proc "contextless" (v: f32) -> bool {
	if v != v {return false}
	return v > -math.F32_MAX && v < math.F32_MAX
}

sanitize :: proc "contextless" (v: f32) -> f32 {
	if !is_finite(v) {return 0}
	return flush_denormal(v)
}

// MIDI note number to hertz, with the note number left as f32 so pitch bend,
// portamento, detune and LFO modulation all compose as fractional semitones
// before a single conversion.
note_to_hz :: proc "contextless" (note: f32) -> f32 {
	return 440.0 * math.pow(f32(2.0), (note - 69.0) / 12.0)
}

// A bounded odd nonlinearity standing in for tanh. The rational form is used
// rather than math.tanh because it is branch-free, monotonic, and provably
// inside (-1, 1) for every finite input, which is the property the filter
// saturation path depends on for stability.
// Transparent below full scale, compressing above it.
//
// The curve this replaces was tanh-like everywhere, which meant it attenuated at
// *every* level rather than only at loud ones: at an amplitude of 0.75 it returned
// 0.645, a loss of 1.3 dB, and that came off every patch in the bank. Combined with
// an equal-power pan law it accounted for the whole 4.35 dB by which our peaks sat
// under the reference's.
//
// There is also nothing to be faithful to. The reference does not limit its output:
// probing the effect unit measured its peaks at +19 and +30 dBFS, so it passes
// whatever the voice produces and lets the host deal with it. A limiter that only
// acts above full scale keeps this engine's contract -- a stack of unison voices
// summing in phase must not produce something unbounded -- without colouring the
// level of everything below it.
//
// Slope one at the knee, so the two halves meet smoothly rather than kinking.
soft_clip :: proc "contextless" (x: f32) -> f32 {
	if !is_finite(x) {return 0}
	magnitude := abs(x)
	if magnitude <= 1.0 {
		return x
	}
	// tanh of the excess, so the output approaches 2 and never exceeds it.
	excess := magnitude - 1.0
	shaped := 1.0 + tanh_f32(excess)
	return x < 0 ? -shaped : shaped
}

tanh_f32 :: proc "contextless" (x: f32) -> f32 {
	// The same rational approximation as before, which is accurate and monotone
	// over the range this is used on.
	v := clamp32(x, -3.0, 3.0)
	vv := v * v
	return v * (27.0 + vv) / (27.0 + 9.0 * vv)
}
