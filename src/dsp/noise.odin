package dsp

// The noise source.
//
// Layer 0 may not use core:math/rand: that package reaches a package-level
// default generator, and this layer owns no mutable global state. An `Rng` is
// embedded in whatever struct needs one, so noise is per-voice and a render is
// bit-reproducible from its seeds.
//
// Synth1's own history records "Noise generator on each voice", so per-voice
// state is also the reference behaviour rather than merely the convenient one.

// Marsaglia xorshift32. Chosen for having no multiply, no table and a single
// word of state; its spectral quality is far beyond what an audio noise source
// resolves.
Rng :: struct {
	state: u32,
}

// A zero state is the one fixed point of xorshift32 and would emit silence
// forever, so it is replaced rather than trusted.
rng_init :: proc "contextless" (r: ^Rng, seed: u32) {
	r.state = seed
	if r.state == 0 {
		r.state = 0x9E3779B9
	}
}

rng_next_u32 :: proc "contextless" (r: ^Rng) -> u32 {
	x := r.state
	if x == 0 {
		x = 0x9E3779B9
	}
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	r.state = x
	return x
}

// Uniform on [-1, 1). The 24-bit mantissa is taken from the high bits, which
// are the better-mixed end of xorshift32's output word.
rng_next_bipolar :: proc "contextless" (r: ^Rng) -> f32 {
	bits := rng_next_u32(r) >> 8 // 24 bits
	unit := f32(bits) * (1.0 / 8388608.0) // 0 .. 2
	return unit - 1.0
}

// Uniform on [0, 1).
rng_next_unit :: proc "contextless" (r: ^Rng) -> f32 {
	bits := rng_next_u32(r) >> 8
	return f32(bits) * (1.0 / 16777216.0)
}
