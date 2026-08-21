package dsp

import "core:math"

// Oscillators.
//
// The waveform set is the union of what the two Synth1 oscillators offer.
// Synth1's English manual describes generator 1 as "sine, triangle, saw or
// pulse" and generator 2 as "triangle, saw, pulse or noise", so neither
// oscillator reaches all five; the binding layer is what restricts each one to
// its own four. Keeping one enum here means the sub oscillator, which has its
// own four-state shape parameter, does not need a third vocabulary.
Waveform :: enum u8 {
	Sine,
	Triangle,
	Saw,
	Pulse,
	Noise,
}

// Phase runs on 0..1 turns rather than radians. Every discontinuity correction
// below is expressed as a fraction of one sample's phase advance, and that is
// only cheap in turns.
Oscillator :: struct {
	phase:     f32,
	// Phase advance per sample, in turns. Positive; the descending saw gets its
	// direction from the waveform expression, not from the increment.
	increment: f32,
	rng:       Rng,
	// Held between samples so the noise waveform keeps one value per sample
	// instead of one per read.
	noise:     f32,
}

oscillator_init :: proc "contextless" (o: ^Oscillator, seed: u32) {
	o^ = {}
	rng_init(&o.rng, seed)
}

oscillator_set_phase :: proc "contextless" (o: ^Oscillator, phase: f32) {
	p := phase
	if !is_finite(p) {
		p = 0
	}
	p = math.mod(p, 1.0)
	if p < 0 {
		p += 1.0
	}
	o.phase = p
}

// Cutting the increment off below Nyquist keeps the PolyBLEP correction width
// (`dt`) under 1/2, which is the condition for the two correction branches
// below not to overlap. Past that point the residual is a discontinuity the
// correction cannot express, and it folds back as broadband noise.
oscillator_set_frequency :: proc "contextless" (o: ^Oscillator, hz, sample_rate: f32) {
	if sample_rate <= 0 || !is_finite(hz) {
		o.increment = 0
		return
	}
	f := clamp32(abs(hz), 0.0, sample_rate * 0.49)
	o.increment = f / sample_rate
}

// The PolyBLEP residual: the difference between an ideal band-limited step and
// the naive one, over the sample on each side of the discontinuity. It is what
// keeps saw and pulse from being an aliasing mush at high notes, which the
// contract's "structurally correct, stable" bar requires even though exact
// sound-alike accuracy is a later slice.
poly_blep :: proc "contextless" (t, dt: f32) -> f32 {
	if dt <= 0 {return 0}
	if t < dt {
		x := t / dt
		return x + x - x * x - 1.0
	}
	if t > 1.0 - dt {
		x := (t - 1.0) / dt
		return x * x + x + x + 1.0
	}
	return 0
}

// Advance one sample. `wrapped` reports that the phase crossed a cycle boundary
// during this sample and `wrap_frac` says where inside the sample it happened,
// on 0..1. Hard sync needs both: resetting the slave at the sample boundary
// instead of at the true crossing is the classic source of sync jitter.
oscillator_advance :: proc "contextless" (o: ^Oscillator) -> (wrapped: bool, wrap_frac: f32) {
	o.phase += o.increment
	if o.phase >= 1.0 {
		over := o.phase - 1.0
		o.phase = over
		if o.increment > 0 {
			// How far back inside the sample the crossing was, as a fraction.
			wrap_frac = clamp32(over / o.increment, 0.0, 1.0)
		}
		wrapped = true
	}
	if !is_finite(o.phase) {
		o.phase = 0
	}
	// Sampled once per sample so `Noise` is a proper sample-rate source rather
	// than something whose spectrum depends on how many times it is read.
	o.noise = rng_next_bipolar(&o.rng)
	return
}

// Advance one sample with an extra phase displacement, in turns.
//
// This is frequency modulation rather than phase modulation: the displacement is
// accumulated into the running phase instead of being applied to a copy of it,
// so the phase carries the integral of the modulator. That is what the reference
// does -- its author's own description of the oscillator section gives the phase
// update as
//
//     osc1_phase = osc1_phase + osc1_delta + (osc2_out * fmAmount * 2048/2)
//
// on a 2048-entry table. That settles accumulation and direction; it does not
// identify the mapping from the panel's 0..127 position to `fmAmount`, which is
// measured separately in voice.odin.
//
// A displacement can be negative and larger than the increment, so unlike
// `oscillator_advance` the phase can move backwards across the cycle boundary.
// Both directions are wrapped. `wrapped` reports only a forward crossing, which
// is what hard sync is defined against.
oscillator_advance_modulated :: proc "contextless" (
	o: ^Oscillator,
	phase_offset: f32,
) -> (
	wrapped: bool,
	wrap_frac: f32,
) {
	offset := phase_offset
	if !is_finite(offset) {
		offset = 0
	}

	o.phase += o.increment + offset
	if o.phase >= 1.0 {
		over := o.phase - 1.0
		// Modulation can push the phase more than a whole cycle forward in one
		// sample, so the excess is reduced rather than assumed to be under 1.
		o.phase = over - f32(int(over))
		step := o.increment + offset
		if step > 0 {
			wrap_frac = clamp32(over / step, 0.0, 1.0)
		}
		wrapped = true
	} else if o.phase < 0 {
		o.phase = o.phase - f32(int(o.phase)) + 1.0
		if o.phase >= 1.0 {
			o.phase -= 1.0
		}
	}
	if !is_finite(o.phase) {
		o.phase = 0
	}
	o.noise = rng_next_bipolar(&o.rng)
	return
}

// Reset the slave oscillator because the master wrapped `wrap_frac` of a sample
// ago. Advancing by that fraction of the increment puts the slave where it
// would be if the reset had landed at the true zero crossing.
oscillator_sync :: proc "contextless" (o: ^Oscillator, wrap_frac: f32) {
	o.phase = clamp32(wrap_frac, 0.0, 1.0) * o.increment
}

// The waveform value at the current phase, on roughly -1..1.
//
// The saw descends. That is measured behaviour, not a convention: the Synth1
// version history records "The saw wave was changed from rising type to the
// descent type" with "The amplitude value by 0 phases changed from 0 to +1",
// which is exactly `1 - 2*phase`. The sub oscillator relies on that phase
// relationship, so getting the sign right here matters beyond politeness.
oscillator_value :: proc "contextless" (o: ^Oscillator, shape: Waveform, pulse_width: f32) -> f32 {
	t := o.phase
	dt := o.increment

	switch shape {
	case .Sine:
		return math.sin(TAU * t)

	case .Triangle:
		// No discontinuity in the waveform itself, only in its derivative, so
		// its alias energy falls off fast enough to leave uncorrected.
		return 1.0 - 4.0 * abs(t - 0.5)

	case .Saw:
		v := 1.0 - 2.0 * t
		// Descending, so the correction adds where a rising saw would subtract.
		v += poly_blep(t, dt)
		return v

	case .Pulse:
		// The difference of two saws, one delayed by the pulse width.
		//
		// Not a naive `t < pw ? 1 : -1` with two corrections bolted on. That form
		// carries a DC offset of 2*pw - 1, which is nearly the whole waveform at
		// an extreme width -- and DC walks straight through a low pass. It made
		// factory patches that pair a narrow or wide pulse with a closed filter
		// come out at full level here while the reference rendered near silence:
		// 080.sy1 sets a 98% width behind a 24 dB low pass at 17 Hz, which should
		// put a middle C 95 dB down, and this engine played it at 0.25.
		//
		// Two saws differenced are DC-free by construction, whatever the width.
		// It is also what the reference does; its author's description of the
		// oscillator section says the pulse has no wavetable of its own and is
		// made by shifting a saw against itself, the shift being the width.
		//
		// Each saw carries its own PolyBLEP, so both edges stay band-limited and
		// the signs work out without special-casing: the delayed saw is
		// subtracted, and so is its correction.
		pw := clamp32(pulse_width, 0.01, 0.99)
		t2 := t - pw
		if t2 < 0 {
			t2 += 1.0
		}
		leading := 1.0 - 2.0 * t + poly_blep(t, dt)
		trailing := 1.0 - 2.0 * t2 + poly_blep(t2, dt)
		// Halved, so the pulse swings one peak to peak where the saw swings two.
		//
		// That ratio is measured, not assumed. At the same gain the reference's
		// saw comes out at an RMS of 0.3299 and its pulse at 0.2484; for a
		// DC-free pulse of duty d and half-amplitude a the RMS is 2a*sqrt(d(1-d)),
		// which at the measured quarter duty puts the pulse's half-amplitude at
		// half the saw's. Undoing this scaling makes every pulse patch 6 dB hot.
		return 0.5 * (leading - trailing)

	case .Noise:
		return o.noise
	}
	return 0
}
