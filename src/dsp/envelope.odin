package dsp

import "core:math"

// Envelope generators.
//
// Attack is linear and decay/release are exponential approaches. That split is
// deliberate: a linear attack reaches exactly 1.0 in finite time, so "attack
// finished" is a state the generator can actually enter, while an exponential
// decay is what gives the familiar shape and never has to be told where it is
// going. Synth1's own history records "modify portament effect
// (linear -> exponential)" for portamento, so exponential segments are in
// keeping with the reference even though this slice does not chase its curves.
//
// The amplitude envelope has since been read against the reference and does
// chase them: `envelope_set_fade` gives it finite decay and release segments
// (see ENVELOPE_FADE_EXPONENT). The filter and modulation envelopes have not
// been read, and stay exponential.
Envelope_Stage :: enum u8 {
	Idle,
	Attack,
	Decay,
	Sustain,
	Release,
}

// Below this the envelope is 80 dB down and is declared finished. Without a
// floor an exponential release never terminates and a voice never frees, which
// would silently turn polyphony into a leak.
ENVELOPE_FLOOR :: f32(1.0e-4)

Envelope :: struct {
	stage:         Envelope_Stage,
	value:         f32,
	// Linear increment per sample during attack.
	attack_step:   f32,
	// One-pole coefficients per sample for the two exponential segments.
	decay_coef:    f32,
	release_coef:  f32,
	sustain:       f32,
	// The fade law, set by `envelope_set_fade`. Off, decay and release are the
	// one-pole approaches above; on, they are the finite segments below.
	fade:          bool,
	decay_step:    f64,
	release_step:  f64,
	// How far through the current decay or release, 0 to 1.
	progress:      f64,
	// The level the release started from.
	release_from:  f32,
	// True while `value` lags `progress` in a fade-law decay or release, after
	// `envelope_advance`; `envelope_level` brings it up to date.
	stale:         bool,
	// The progress below which this release cannot reach the floor, worked out
	// the first time `envelope_advance` moves it.
	release_safe_below: f64,
	release_safe_set:   bool,
}

// The amplitude envelope's decay and release, measured against the reference
// (docs/synth1-envelope-filter-evidence.md): over a segment of `length` seconds
// the level is exp(-8u) * (1 - u), u the share of the length gone, so it falls
// like an exponential and reaches exactly zero at the end. A release scales it
// by the level it started from; a decay falls from 1 to the sustain level by
// the same curve. The reference reads the curve in whole 1/2048ths every 256
// samples, which this does not copy.
ENVELOPE_FADE_EXPONENT :: 8.0

// Both segments reach -60 dB in their tabled time: ln(1000) = 6.9078.
ENVELOPE_DECAY_SPAN :: f32(6.9078)

// The release keeps ln(1000), and that is now measured rather than assumed.
//
// The two segments do not share a shape in the reference. Its release ratio is 8.92
// -- per setting 8.49, 9.01, 8.97, 9.00 and 9.09 -- against the decay's 5.5, so the
// release really is close to the exponential this implements and the decay really is
// not. Splitting the constant was not tidiness; the two numbers are different.
//
// Giving the release the decay's constant before measuring it was tried by accident
// and made it 25 times too long, which the tests caught.
ENVELOPE_RELEASE_SPAN :: f32(6.9078)

segment_coef :: proc "contextless" (seconds, sample_rate, span: f32) -> f32 {
	if seconds <= 0 || sample_rate <= 0 {return 0}
	samples := seconds * sample_rate
	if samples < 1.0 {return 0}
	return math.exp(-span / samples)
}

// Times are in seconds, sustain on 0..1.
envelope_set :: proc "contextless" (e: ^Envelope, attack, decay, sustain, release, sample_rate: f32) {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}

	d := is_finite(decay) ? max(decay, f32(0)) : 0
	r := is_finite(release) ? max(release, f32(0)) : 0

	envelope_set_attack_and_sustain(e, attack, sustain, sr)
	e.fade = false
	e.decay_coef = segment_coef(d, sr, ENVELOPE_DECAY_SPAN)
	e.release_coef = segment_coef(r, sr, ENVELOPE_RELEASE_SPAN)
}

// The same, with decay and release as the fade law's segment lengths in seconds
// rather than as the time an exponential takes to fall 60 dB.
envelope_set_fade :: proc "contextless" (e: ^Envelope, attack, decay_length, sustain, release_length, sample_rate: f32) {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}

	d := is_finite(decay_length) ? max(decay_length, f32(0)) : 0
	r := is_finite(release_length) ? max(release_length, f32(0)) : 0

	envelope_set_attack_and_sustain(e, attack, sustain, sr)
	e.fade = true
	// A segment shorter than a sample still takes one.
	e.decay_step = 1.0 / max(f64(d) * f64(sr), 1.0)
	e.release_step = 1.0 / max(f64(r) * f64(sr), 1.0)
}

envelope_set_attack_and_sustain :: proc "contextless" (e: ^Envelope, attack, sustain, sr: f32) {
	envelope_level(e)
	a := is_finite(attack) ? max(attack, f32(0)) : 0
	attack_samples := a * sr
	if attack_samples < 1.0 {
		// A zero attack still takes one sample, so no note ever starts with a
		// step discontinuity.
		e.attack_step = 1.0
	} else {
		e.attack_step = 1.0 / attack_samples
	}
	e.sustain = clamp32(is_finite(sustain) ? sustain : 0, 0.0, 1.0)
}

// exp(-8u) * (1 - u), the fraction of a fade segment's starting distance that
// is left once a share u of its length has gone.
envelope_fade_left :: proc "contextless" (u: f64) -> f32 {
	return f32(math.exp(-ENVELOPE_FADE_EXPONENT * u) * (1.0 - u))
}

// The level `steps` samples on, without moving the envelope: what `envelope_process`
// would return on the last of that many calls.
//
// The finite decay and release segments are a closed form of how far through them they
// are, so those are computed directly. The attack and the exponential law accumulate
// sample by sample, and a segment boundary can fall inside the span, so those step a copy.
envelope_value_ahead :: proc "contextless" (e: ^Envelope, steps: int) -> f32 {
	if steps <= 0 {
		return envelope_level(e)
	}
	if e.fade {
		switch e.stage {
		case .Idle:
			return 0
		case .Sustain:
			return e.sustain
		case .Decay:
			progress := e.progress + f64(steps) * e.decay_step
			if progress >= 1.0 {
				return e.sustain
			}
			return e.sustain + (1.0 - e.sustain) * envelope_fade_left(progress)
		case .Release:
			progress := e.progress + f64(steps) * e.release_step
			if progress >= 1.0 {
				return 0
			}
			value := e.release_from * envelope_fade_left(progress)
			return value <= ENVELOPE_FLOOR ? 0 : value
		case .Attack:
		}
	}
	ahead := e^
	level: f32
	for _ in 0 ..< steps {
		level = envelope_process(&ahead)
	}
	return level
}

envelope_reset :: proc "contextless" (e: ^Envelope) {
	e.stage = .Idle
	e.value = 0
	e.stale = false
}

// Start a note. `retrigger` false keeps the current level, which is what a
// legato mono line needs; true restarts from silence.
envelope_gate_on :: proc "contextless" (e: ^Envelope, retrigger: bool) {
	envelope_level(e)
	if retrigger {
		e.value = 0
	}
	e.stage = .Attack
}

envelope_gate_off :: proc "contextless" (e: ^Envelope) {
	envelope_level(e)
	// A second note-off during the release must not restart it.
	if e.stage == .Idle || e.stage == .Release {
		return
	}
	e.stage = .Release
	e.progress = 0
	e.release_from = e.value
	e.release_safe_set = false
}

envelope_is_active :: proc "contextless" (e: ^Envelope) -> bool {
	return e.stage != .Idle
}

envelope_process :: proc "contextless" (e: ^Envelope) -> f32 {
	switch e.stage {
	case .Idle:
		e.value = 0

	case .Attack:
		e.value += e.attack_step
		if e.value >= 1.0 {
			e.value = 1.0
			e.stage = .Decay
			e.progress = 0
		}

	case .Decay:
		if e.fade {
			e.progress += e.decay_step
			if e.progress >= 1.0 {
				e.value = e.sustain
				e.stage = .Sustain
			} else {
				e.value = e.sustain + (1.0 - e.sustain) * envelope_fade_left(e.progress)
			}
			break
		}
		// A plain exponential approach to the sustain level.
		//
		// This was briefly replaced with a curve that aimed below the sustain, on the
		// strength of `envprobe` reporting the reference's t(-60 dB) as only 5.14
		// times its t(-6 dB) where an exponential gives 10. That reading was wrong,
		// and comparing the two contours directly is what showed it: at decay 79 the
		// reference falls 4.5 dB every 125 ms, a straight line in decibels, reaching
		// 60 dB at about 1630 ms against a tabled 1631; at decay 96 it falls 1.4 dB
		// per 125 ms, or 60 dB in 5357 ms against a tabled 5230. Both are exponentials
		// and both match their own tabled times.
		//
		// The t(-6 dB) column disagrees with those contours by a factor of 1.83 while
		// the t(-60 dB) column from the same tool agrees with them, so the fault is in
		// that column rather than in the plugin. The lesson is cheap to state and was
		// not cheap to learn: a ratio between two measurements is only as good as the
		// worse of them, and neither had been checked against the shape it described.
		e.value = e.sustain + (e.value - e.sustain) * e.decay_coef
		// Settling into an explicit Sustain stage keeps the decay multiply out
		// of the inner loop for the long held part of a note, and makes the
		// state machine's reachable states match the four the contract names.
		if abs(e.value - e.sustain) <= ENVELOPE_FLOOR {
			e.value = e.sustain
			e.stage = .Sustain
		}

	case .Sustain:
		e.value = e.sustain

	case .Release:
		if e.fade {
			e.progress += e.release_step
			e.value = envelope_release_left(e)
		} else {
			e.value *= e.release_coef
		}
		if e.value <= ENVELOPE_FLOOR {
			e.value = 0
			e.stage = .Idle
		}
	}

	e.value = sanitize(e.value)
	e.stale = false
	return e.value
}

// What a fade-law release has left at its progress, before the floor is applied.
envelope_release_left :: proc "contextless" (e: ^Envelope) -> f32 {
	return e.progress >= 1.0 ? 0 : e.release_from * envelope_fade_left(e.progress)
}

// One sample on, as `envelope_process` moves it, for a caller that does not read
// the level this sample. A fade-law segment's level costs an `exp`. A decay ends
// on its progress alone, and a release ends at the floor, which it cannot reach
// below `release_safe_below`, so there only the progress moves and the level is
// left to `envelope_level`.
envelope_advance :: proc "contextless" (e: ^Envelope) {
	if e.fade && e.stage == .Decay {
		e.progress += e.decay_step
		if e.progress >= 1.0 {
			e.value = sanitize(e.sustain)
			e.stage = .Sustain
			e.stale = false
		} else {
			e.stale = true
		}
		return
	}
	if e.fade && e.stage == .Release {
		if !e.release_safe_set {
			e.release_safe_below = envelope_release_safe_below(e.release_from)
			e.release_safe_set = true
		}
		if e.progress + e.release_step < e.release_safe_below {
			e.progress += e.release_step
			e.stale = true
			return
		}
	}
	envelope_process(e)
}

// The level, brought up to date if `envelope_advance` left it behind: what
// `envelope_process` would have returned on the last sample.
envelope_level :: proc "contextless" (e: ^Envelope) -> f32 {
	if e.stale {
		if e.stage == .Release {
			e.value = sanitize(envelope_release_left(e))
		} else {
			e.value = sanitize(e.sustain + (1.0 - e.sustain) * envelope_fade_left(e.progress))
		}
		e.stale = false
	}
	return e.value
}

// The progress below which a release from `from` stays above the floor. Found by
// bisection on the same arithmetic the release uses, then held back by a
// thousandth of the segment, across which the curve falls by close to one per
// cent: far more than the rounding that could otherwise carry a level found
// above the floor below it.
envelope_release_safe_below :: proc "contextless" (from: f32) -> f64 {
	if !(from * envelope_fade_left(0) > ENVELOPE_FLOOR) {
		return 0
	}
	above, below := f64(0), f64(1)
	for _ in 0 ..< 40 {
		middle := (above + below) * 0.5
		if from * envelope_fade_left(middle) > ENVELOPE_FLOOR {
			above = middle
		} else {
			below = middle
		}
	}
	return max(above - 1.0e-3, 0)
}
