package engine

import "core:math"

// Stereo position, as the reference composes it.
//
// Three things set where a voice sits: its own place in the unison stack, the
// static pan knob, and an LFO sent to pan. The reference gives each its own pair
// of gains and **multiplies** them; it does not add positions and then derive one
// pair of gains. The difference is invisible with one control and large with two:
// a stack spread hard left under a hard-left knob is silent on the right in the
// reference, where summing positions clamps at the same edge and cannot tell the
// two cases apart, and the reference's near-channel boost under an LFO survives a
// static pan where a clamped sum would swallow it.
//
// The static law and the stack's are the same one: full level in both channels at
// the centre, and the channel being moved away from falls linearly to nothing.
static_pan_gains :: proc "contextless" (position: f32) -> (left, right: f32) {
	p := clamp(position, -1, 1)
	return min(f32(1), 1 - p), min(f32(1), 1 + p)
}

// What an LFO on pan does to one channel, for `x = sum of LFO value * depth` with
// the sign of the channel: positive moves that channel up and the other down.
//
// The curve is a cubic, not the static law's straight line. Toward the channel it
// rises past unity to 1.5 at full depth, and away from it it falls as
// `(1 - x)^3` to nothing:
//
//   x         0     0.25    0.5    0.75    1.0
//   up      1.000  1.282  1.438  1.492  1.500
//   down    1.000  0.422  0.125  0.016  0.000
//
// Depth 32 of 127 reads 1.292 and 0.423 on the reference's near and far channels
// and the top of the knob 1.504 and 0.000, which is the 1.5 and 0 above.
pan_lfo_gain :: proc "contextless" (x: f32) -> f32 {
	if x >= 0 {
		u := x - 1
		return 1.5 + 0.5 * u * u * u
	}
	u := x + 1
	return u * u * u
}

// Both channels' gains move to their targets with a two millisecond half-life
// while an LFO drives pan, which is what keeps a square from clicking.
PAN_LFO_HALF_LIFE_SECONDS :: f32(0.002)

pan_lfo_smoothing :: proc "contextless" (sample_rate: f32) -> f32 {
	return 1.0 - math.pow(f32(0.5), 1.0 / (sample_rate * PAN_LFO_HALF_LIFE_SECONDS))
}
