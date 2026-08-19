package engine

import "../dsp"

// Parameter smoothing.
//
// A one-pole toward a target. Only the parameters that are audible as a step
// are smoothed -- filter cutoff, gains, pan, the oscillator mix and the pulse
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
