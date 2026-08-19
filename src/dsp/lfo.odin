package dsp

import "core:math"

// Low frequency oscillators.
//
// The waveform set is the reference's, verbatim: docs/synth1-readme-eng.txt
// lists "saw, triangle, sine, square, random(sample & hold) or random
// (smoothed)" for both LFOs, and the measured state table for parameters 42 and
// 47 has exactly six states.
//
// The enum is written in that documented order, and `s1probe lfoshape` has since
// confirmed the order is exactly right -- indexed by state *position*. Those two
// parameters display their states out of order, as 0, 1, 5, 2, 3, 4, which the
// binding layer used to treat as the real identity; it is not, and reading it
// that way bound four of the six states to the wrong shape. See `bind_lfo`.
//
// The LFO is a separate type from `Oscillator` rather than a reuse of it
// because the two have opposite requirements. An audio oscillator wants
// band-limited edges; an LFO wants its exact corners, since its output is a
// control signal and PolyBLEP overshoot on a square LFO would be an audible
// pitch or cutoff blip rather than an anti-alias measure.
Lfo_Waveform :: enum u8 {
	Saw,
	Triangle,
	Sine,
	Square,
	Sample_Hold,
	Random_Smooth,
}

Lfo :: struct {
	phase:     f32,
	increment: f32,
	rng:       Rng,
	shape:     Lfo_Waveform,
	// Sample & hold keeps `held`; the smoothed random walks `current` toward it.
	held:      f32,
	current:   f32,
}

lfo_init :: proc "contextless" (l: ^Lfo, seed: u32) {
	l^ = {}
	rng_init(&l.rng, seed)
	l.held = rng_next_bipolar(&l.rng)
	l.current = l.held
}

lfo_set_frequency :: proc "contextless" (l: ^Lfo, hz, sample_rate: f32) {
	if sample_rate <= 0 || !is_finite(hz) {
		l.increment = 0
		return
	}
	// Held below Nyquist for the same reason the audio oscillator is: past it
	// the phase sequence stops representing the intended rate at all.
	f := clamp32(abs(hz), 0.0, sample_rate * 0.49)
	l.increment = f / sample_rate
}

// Key sync. Restarting the phase is what parameters 68 and 70 select, and the
// random shapes get a fresh held value so a key-synced S&H does not begin every
// note on whatever the last note left behind.
lfo_retrigger :: proc "contextless" (l: ^Lfo) {
	l.phase = 0
	l.held = rng_next_bipolar(&l.rng)
	l.current = l.held
}

// Advance one sample and return the value, always on [-1, 1].
//
// The bound is a property every caller depends on: the binding layer scales
// this by a depth in engine units (semitones, octaves of cutoff, a gain
// fraction) and would have to re-clamp everywhere otherwise.
lfo_process :: proc "contextless" (l: ^Lfo) -> f32 {
	l.phase += l.increment
	wrapped := false
	if l.phase >= 1.0 {
		l.phase -= 1.0
		if l.phase >= 1.0 {
			l.phase = 0
		}
		wrapped = true
	}
	if !is_finite(l.phase) {
		l.phase = 0
	}

	t := l.phase
	value: f32 = 0

	switch l.shape {
	case .Saw:
		// Descending, matching the audio saw's measured direction.
		value = 1.0 - 2.0 * t
	case .Triangle:
		value = 1.0 - 4.0 * abs(t - 0.5)
	case .Sine:
		value = math.sin(TAU * t)
	case .Square:
		value = t < 0.5 ? f32(1.0) : f32(-1.0)
	case .Sample_Hold:
		if wrapped {
			l.held = rng_next_bipolar(&l.rng)
		}
		value = l.held
	case .Random_Smooth:
		if wrapped {
			l.held = rng_next_bipolar(&l.rng)
		}
		// One-pole toward the held target, time-constant tied to the LFO rate
		// so the smoothing tracks the shape rather than the sample rate.
		coef := clamp32(l.increment * 8.0, 0.0, 1.0)
		l.current += (l.held - l.current) * coef
		value = l.current
	}

	return clamp32(sanitize(value), -1.0, 1.0)
}
