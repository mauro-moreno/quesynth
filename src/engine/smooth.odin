package engine

import "core:math"

import "../dsp"

// Parameter smoothing.
//
// A one-pole toward a target. Only the parameters that are audible as a step
// are smoothed -- gains, pan, the oscillator mix and the pulse
// width -- because smoothing a switch such as filter type or a waveform would
// mean interpolating between two things that have no midpoint.
//
// The smoothers live in the engine rather than in layer 0 for the reason
// docs/architecture.md gives: layer 0 is the primitives, layer 1 is the glue
// that decides when a primitive's coefficients may change.
Smoother :: struct {
	value: f32,
	coef:  f32,
}

// `seconds` is the time to cover 99.9% of a step.
smoother_init :: proc(s: ^Smoother, initial, seconds, sample_rate: f32) {
	s.value = initial
	smoother_set_time(s, seconds, sample_rate)
}

smoother_set_time :: proc(s: ^Smoother, seconds, sample_rate: f32) {
	// The plain exponential span: this is a parameter smoother, not an envelope
	// segment, so it has none of the decay's measured shape.
	s.coef = dsp.segment_coef(seconds, sample_rate, dsp.ENVELOPE_RELEASE_SPAN)
}

// Jump without gliding. Used when a patch is loaded: the first note after a
// patch change must start at the new cutoff, not sweep up to it from the old.
smoother_reset :: proc(s: ^Smoother, value: f32) {
	s.value = value
}

smoother_process :: proc(s: ^Smoother, target: f32) -> f32 {
	s.value = target + (s.value - target) * s.coef
	s.value = dsp.sanitize(s.value)
	return s.value
}

// A smoother whose distance to the target halves every `seconds`, started at `initial`.
smoother_init_half_life :: proc(s: ^Smoother, initial, seconds, sample_rate: f32) {
	s.value = initial
	s.coef = math.pow(f32(0.5), 1.0 / max(seconds * sample_rate, 1.0))
}

// A value that moves to a new target in a straight line over a fixed number of samples,
// started the moment the target is seen to have changed. A target that moves again
// mid-ramp starts a new ramp from where the value is.
Ramp :: struct {
	value:     f32,
	target:    f32,
	step:      f32,
	remaining: int,
}

ramp_init :: proc(r: ^Ramp, value: f32) {
	r^ = Ramp{value = value, target = value}
}

ramp_process :: proc(r: ^Ramp, target: f32, samples: int) -> f32 {
	if target != r.target {
		r.target = target
		r.remaining = max(samples, 1)
		r.step = (target - r.value) / f32(r.remaining)
	}
	if r.remaining > 0 {
		r.remaining -= 1
		r.value = r.remaining == 0 ? r.target : r.value + r.step
	}
	r.value = dsp.sanitize(r.value)
	return r.value
}
