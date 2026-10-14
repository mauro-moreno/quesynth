package dsp

import "core:math"

// Low frequency oscillators.
//
// The waveform set is the reference's, verbatim: Synth1's English manual
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

// The period is a whole number of samples, and the output is refreshed on a grid.
//
// The reference counts an integer position through an integer period, `sr / hz`
// truncated, and recomputes its output only at multiples of 64 samples from the
// start of the cycle, or 32 once the rate is past 10 Hz. Between those points the
// value is held, so an LFO is a staircase with a step of 1.3 ms at 48 kHz, 0.7 ms
// for a fast one. That is audible only on a fast LFO driving something sharp, but
// it is what a square's edge, a pan LFO's smoothing and the sidebands of an
// audio-rate LFO are made of.
//
// A change of rate keeps the position's place in the cycle: the position scales
// by new period over old.
LFO_GRID_SLOW :: 64
LFO_GRID_FAST :: 32
LFO_FAST_HZ :: f32(10.0)

Lfo :: struct {
	position:  int,
	period:    int,
	grid:      int,
	// The next position the output is recomputed at, and what it was last time.
	update_at: int,
	output:    f32,
	// The same output as the reference's amplifier hears it: not held but ramped
	// linearly across each step from the value before it to the new one, so a
	// modulated gain has corners at the grid and no steps. Only the amplitude
	// destination reads it; every other destination uses the held `output`.
	ramped:    f32,
	ramp_from: f32,
	ramp_at:   int,
	ramp_over: int,
	// The cycle's position as a fraction of the cycle, for anyone watching.
	phase:     f32,
	rng:       Rng,
	shape:     Lfo_Waveform,
	// Sample & hold keeps `target` for a whole cycle; the smoothed random ramps
	// from `previous` to `target` across it.
	previous:  f32,
	target:    f32,
}

lfo_init :: proc "contextless" (l: ^Lfo, seed: u32) {
	l^ = {}
	rng_init(&l.rng, seed)
	l.period = 1
	l.grid = LFO_GRID_SLOW
	l.target = rng_next_bipolar(&l.rng)
	l.previous = (0 + l.target) * 0.5
}

lfo_set_frequency :: proc "contextless" (l: ^Lfo, hz, sample_rate: f32) {
	if sample_rate <= 0 || !is_finite(hz) || hz <= 0 {
		return
	}
	old := l.period
	l.period = max(2, int(sample_rate / hz))
	// Held to a quarter of the period so a rate far past the reference's 125 Hz
	// still moves; nothing the binding can produce reaches it.
	l.grid = min(hz > LFO_FAST_HZ ? LFO_GRID_FAST : LFO_GRID_SLOW, max(1, l.period / 4))
	if old > 1 && old != l.period {
		l.position = int(f64(l.period) * f64(l.position) / f64(old))
		l.update_at = 0
	}
}

// Key sync. Restarting the position is what parameters 68 and 70 select, and the
// random shapes get a fresh target so a key-synced S&H does not begin every note on
// whatever the last note left behind.
lfo_retrigger :: proc "contextless" (l: ^Lfo) {
	l.position = 0
	l.update_at = 0
	l.phase = 0
	l.previous = l.target
	l.target = rng_next_bipolar(&l.rng)
}

// The unquantised value at a position, always on [-1, 1].
lfo_shape_value :: proc "contextless" (l: ^Lfo, position: int) -> f32 {
	last := f32(max(l.period - 1, 1))
	t := f32(position) / f32(l.period)
	switch l.shape {
	case .Saw:
		// Descending, matching the audio saw's measured direction.
		return 1.0 - 2.0 * f32(position) / last
	case .Triangle:
		return 1.0 - 4.0 * abs(t - 0.5)
	case .Sine:
		return math.sin(TAU * t)
	case .Square:
		return position < l.period / 2 ? f32(1.0) : f32(-1.0)
	case .Sample_Hold:
		return l.target
	case .Random_Smooth:
		return l.previous + (l.target - l.previous) * f32(position) / last
	}
	return 0
}

// Advance one sample and return the value, always on [-1, 1].
//
// The bound is a property every caller depends on: the binding layer scales
// this by a depth in engine units (semitones, octaves of cutoff, a gain
// fraction) and would have to re-clamp everywhere otherwise.
lfo_process :: proc "contextless" (l: ^Lfo) -> f32 {
	if l.position >= l.update_at {
		l.ramp_from = l.output
		l.output = clamp32(sanitize(lfo_shape_value(l, l.position)), -1.0, 1.0)
		l.update_at = (l.position / l.grid + 1) * l.grid
		l.ramp_at = 0
		l.ramp_over = max(1, l.update_at - l.position)
	}
	l.ramp_at += 1
	l.ramped = l.ramp_from + (l.output - l.ramp_from) * min(1.0, f32(l.ramp_at) / f32(l.ramp_over))
	l.phase = f32(l.position) / f32(l.period)
	result := l.output

	l.position += 1
	if l.position >= l.period {
		l.position = 0
		l.update_at = 0
		l.previous = l.target
		l.target = rng_next_bipolar(&l.rng)
	}
	return result
}
