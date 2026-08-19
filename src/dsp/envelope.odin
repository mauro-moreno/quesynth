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
}

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

	a := is_finite(attack) ? max(attack, f32(0)) : 0
	d := is_finite(decay) ? max(decay, f32(0)) : 0
	r := is_finite(release) ? max(release, f32(0)) : 0

	attack_samples := a * sr
	if attack_samples < 1.0 {
		// A zero attack still takes one sample, so no note ever starts with a
		// step discontinuity.
		e.attack_step = 1.0
	} else {
		e.attack_step = 1.0 / attack_samples
	}

	e.decay_coef = segment_coef(d, sr, ENVELOPE_DECAY_SPAN)
	e.release_coef = segment_coef(r, sr, ENVELOPE_RELEASE_SPAN)
	e.sustain = clamp32(is_finite(sustain) ? sustain : 0, 0.0, 1.0)
}

envelope_reset :: proc "contextless" (e: ^Envelope) {
	e.stage = .Idle
	e.value = 0
}

// Start a note. `retrigger` false keeps the current level, which is what a
// legato mono line needs; true restarts from silence.
envelope_gate_on :: proc "contextless" (e: ^Envelope, retrigger: bool) {
	if retrigger {
		e.value = 0
	}
	e.stage = .Attack
}

envelope_gate_off :: proc "contextless" (e: ^Envelope) {
	if e.stage != .Idle {
		e.stage = .Release
	}
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
		}

	case .Decay:
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
		e.value *= e.release_coef
		if e.value <= ENVELOPE_FLOOR {
			e.value = 0
			e.stage = .Idle
		}
	}

	e.value = sanitize(e.value)
	return e.value
}
