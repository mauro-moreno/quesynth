package dsp

import "core:math"

// The reference's two-pole filter: a Chamberlin state variable section stepped
// twice per sample.
//
// It is not the topology-preserving form `Filter` uses, and the two do not agree
// on anything that matters. This one has no tangent in its coefficient -- the
// step is `2 sin(pi fc / (2 sr))`, a half-rate step, because each sample is two
// integration steps -- so the corner is not warped the way a bilinear one is,
// and its damping is `1 - resonance` directly, which makes the resonance knob's
// own position the whole of the Q law: stored 64 is a Q of about 2 and the top of
// the knob has no damping at all.
//
// The resonance also trims the input, by `1 - 0.7 * resonance`. That is the
// reason a resonant reference filter does not get louder the way a raw state
// variable one does, and it is why this section needs no output gain table of its
// own.
//
// Past a resonance of 0.9 the output is held to +/-20, which is the only thing
// that keeps an undamped section from running away; the clamp is on the output
// and the states are left to ring.
CHAMBERLIN_INPUT_TRIM :: f32(0.7)
CHAMBERLIN_CLAMP_FROM :: f32(0.9)
CHAMBERLIN_CLAMP_LEVEL :: f32(20.0)

Chamberlin :: struct {
	lp:   f32,
	bp:   f32,
	hz:   f32,
	rate: f32,
	step: f32,
}

chamberlin_reset :: proc "contextless" (c: ^Chamberlin) {
	c.lp = 0
	c.bp = 0
}

// The coefficient is a sine, so it is kept until the corner or the sample rate
// moves. The cutoff arrives as a whole step of the reference's axis, which only
// changes while it is being swept.
chamberlin_set_cutoff :: proc "contextless" (c: ^Chamberlin, hz, sample_rate: f32) {
	if hz == c.hz && sample_rate == c.rate && c.step != 0 {
		return
	}
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}
	c.hz = hz
	c.rate = sample_rate
	c.step = 2.0 * math.sin(math.PI * clamp32(hz, 0, sr * 0.5) / (2.0 * sr))
}

chamberlin_process :: proc "contextless" (c: ^Chamberlin, x, resonance: f32, mode: Filter_Mode) -> f32 {
	res := clamp32(resonance, 0.0, 1.0)
	damping := res - 1.0
	input := x
	if !is_finite(input) {
		input = 0
	}
	input *= 1.0 - CHAMBERLIN_INPUT_TRIM * res

	step := c.step
	c.lp += step * c.bp
	c.bp += ((input - c.lp) + c.bp * damping) * step
	c.lp += step * c.bp
	hp := (input - c.lp) + c.bp * damping
	c.bp += hp * step

	c.lp = flush_denormal(c.lp)
	c.bp = flush_denormal(c.bp)
	if !is_finite(c.lp) || !is_finite(c.bp) {
		c.lp = 0
		c.bp = 0
		return 0
	}

	out: f32
	switch mode {
	case .Low_Pass:
		out = c.lp
	case .High_Pass:
		out = hp
	case .Band_Pass:
		out = c.bp
	case .Notch:
		out = c.lp + hp
	}
	if res > CHAMBERLIN_CLAMP_FROM {
		out = clamp32(out, -CHAMBERLIN_CLAMP_LEVEL, CHAMBERLIN_CLAMP_LEVEL)
	}
	return out
}
