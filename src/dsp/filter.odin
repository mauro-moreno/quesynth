package dsp

import "core:math"

// The filter.
//
// The contract for this slice names four responses -- low pass, high pass, band
// pass and notch -- at 12 dB and 24 dB per octave. A topology-preserving
// transform state variable filter gives all four from one set of coefficients
// and one pair of integrator states, which is why it is used here rather than a
// ladder: a ladder would have to be a second implementation to reach band pass
// and notch at all.
//
// 24 dB is two TPT sections in series, which is a cascade rather than a single
// fourth-order design. The two are not interchangeable and the difference is
// paid for in two places: each section takes the square root of the requested
// damping, because a cascade multiplies resonances (see `filter_set_damping`),
// and the 24 dB path needs its own measured damping curve, because a pair of
// two-pole resonances is not the shape of one four-pole resonance under any
// sharing of the damping at all.
Filter_Mode :: enum u8 {
	Low_Pass,
	High_Pass,
	Band_Pass,
	Notch,
}

Filter_Slope :: enum u8 {
	Slope_12,
	Slope_24,
}

// The sharpest the filter is allowed to be, as k = 1/Q.
//
// The section is unconditionally stable at any k above zero -- that is the point
// of the topology -- so this is not a stability limit. It is where f32 stops
// being able to represent the damping at all.
//
// `a1` is 1 / (1 + g*(g + k)), so the whole of k's influence on the coefficient
// arrives as the product g*k against a denominator near 1. At the bottom of the
// cutoff range g is tan(pi * 10 / 48000) = 6.5e-4, so k = 0.001 contributes
// 6.5e-7 -- about five times f32's epsilon. Below that the damping is whatever
// the rounding leaves, which is not a filter setting but a coin toss, so it is
// refused rather than accepted and silently altered.
MIN_DAMPING :: f32(0.001)

// One TPT state variable section. `ic1eq` and `ic2eq` are the two integrator
// states in Zavalishin's notation.
Svf_State :: struct {
	ic1eq: f32,
	ic2eq: f32,
}

Filter :: struct {
	stage: [2]Svf_State,
	// Coefficients, recomputed only when cutoff or resonance moves.
	g:     f32,
	k:     f32,
	a1:    f32,
	a2:    f32,
	a3:    f32,
}

filter_init :: proc "contextless" (f: ^Filter) {
	f^ = {}
	filter_set(f, 1000.0, 0.0, 48000.0)
}

filter_reset :: proc "contextless" (f: ^Filter) {
	f.stage = {}
}

// Set cutoff and resonance.
//
// Cutoff is clamped into [MIN_CUTOFF_HZ, MAX_CUTOFF_RATIO * sample_rate]
// unconditionally. Envelope amount, keyboard tracking and LFO modulation all
// add into the cutoff before this call, and their sum routinely lands past
// Nyquist on real patches; `tan` diverges there, so the clamp is the thing that
// makes "never produces NaN" a property rather than a hope.
//
// Resonance maps linearly to k = 2 - 1.93*r, i.e. Q from 0.5 up to 14. That law
// is not the reference's -- the reference's is measured, reaches Q = 950, and
// lives in `src/engine/filter_resonance_table.odin` -- and this entry point
// survives for callers that have nothing but a plain 0..1 to hand.
filter_set :: proc "contextless" (f: ^Filter, cutoff_hz, resonance, sample_rate: f32, slope := Filter_Slope.Slope_12) {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}

	fc := cutoff_hz
	if !is_finite(fc) {
		fc = MIN_CUTOFF_HZ
	}
	fc = clamp32(fc, MIN_CUTOFF_HZ, sr * MAX_CUTOFF_RATIO)

	r := resonance
	if !is_finite(r) {
		r = 0
	}
	r = clamp32(r, 0.0, 1.0)

	filter_set_damping(f, fc, 2.0 - 1.93 * r, sr, slope)
}

// Set cutoff and damping, with the resonance knob already resolved to a k.
//
// This is the form the engine uses, because the resonance curve is measured
// rather than computed: `src/engine/filter_resonance_table.odin` holds the
// damping the reference's own knob produces.
//
// `damping` is the k the *whole filter* is to have, not the k of one section,
// which is why the slope has to be known here. At 24 dB the filter is two
// identical sections in series and a cascade multiplies their peak gains, so
// giving both of them k would produce a resonance of 1/k squared. Each section
// gets the square root instead, which lands the pair on 1/k.
//
// The rule has a property worth noticing at both ends. At the top of the knob,
// k = 0.001 becomes 0.0316 per section -- a Q of 32 twice over rather than an
// impossible 1000 once. At the bottom, k = 2 becomes 1.414 per section, which is
// exactly Butterworth, so with the resonance off the 24 dB path is two cascaded
// Butterworth sections rather than two overdamped ones.
//
// Getting this wrong is not subtle. With both sections at the full k, the 24 dB
// low pass measured 26.6 dB of timbre error against the reference where the
// 12 dB low pass measured 4.1, and its output sat pinned against the limiter.
filter_set_damping :: proc "contextless" (f: ^Filter, cutoff_hz, damping, sample_rate: f32, slope := Filter_Slope.Slope_12) {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}

	fc := cutoff_hz
	if !is_finite(fc) {
		fc = MIN_CUTOFF_HZ
	}
	fc = clamp32(fc, MIN_CUTOFF_HZ, sr * MAX_CUTOFF_RATIO)

	k := damping
	if !is_finite(k) {
		k = 2.0
	}
	k = clamp32(k, MIN_DAMPING, 2.0)
	if slope == .Slope_24 {
		k = math.sqrt(k)
	}

	f.g = math.tan(math.PI * fc / sr)
	f.k = k
	f.a1 = 1.0 / (1.0 + f.g * (f.g + f.k))
	f.a2 = f.g * f.a1
	f.a3 = f.g * f.a2
}

// One section, returning all three raw outputs so the mode switch costs no
// extra state.
svf_process :: proc "contextless" (f: ^Filter, s: ^Svf_State, x: f32) -> (lp, bp, hp: f32) {
	v3 := x - s.ic2eq
	v1 := f.a1 * s.ic1eq + f.a2 * v3
	v2 := s.ic2eq + f.a2 * s.ic1eq + f.a3 * v3

	s.ic1eq = flush_denormal(2.0 * v1 - s.ic1eq)
	s.ic2eq = flush_denormal(2.0 * v2 - s.ic2eq)

	// A single non-finite sample would otherwise live in the state forever.
	if !is_finite(s.ic1eq) || !is_finite(s.ic2eq) {
		s.ic1eq = 0
		s.ic2eq = 0
		return 0, 0, 0
	}

	lp = v2
	bp = v1
	hp = x - f.k * v1 - v2
	return
}

// The raw responses, with no per-mode gain correction.
//
// There used to be one here: the band pass alone was scaled by k^0.25, fitted by
// driving a saw through it and sweeping the resonance. Two things were wrong with
// that. A saw is a harmonic comb, so as the resonance narrows its partials fall
// out of the peak and the instrument under-reads the gain -- and the correction
// is not a band-pass matter at all. Measured with noise, every response needs the
// same one: raising the resonance adds energy to a low pass and a high pass
// exactly as it does to a band pass, and all four came back within a decibel of
// each other across the whole knob.
//
// So the correction is one curve of the resonance knob, it lives in the engine
// beside the damping it belongs to -- `FILTER_OUTPUT_GAIN` -- and this layer
// returns the filter's own output.
svf_pick :: proc "contextless" (f: ^Filter, mode: Filter_Mode, lp, bp, hp: f32) -> f32 {
	switch mode {
	case .Low_Pass:
		return lp
	case .High_Pass:
		return hp
	case .Band_Pass:
		return bp
	case .Notch:
		return lp + hp
	}
	return lp
}

// Process one sample.
//
// `saturation_drive` is parameter 23 after its measured curve has been resolved
// by the engine. The reference is a peak-normalised tanh: it raises the small-
// signal gain and adds odd harmonics while leaving full-scale peaks fixed. It is
// applied once to the completed filter response. This is observable in the 24 dB
// mode: applying it per section compounds the transfer and produces 5.8 dB too
// much THD at stored 32, while the reference has the same open-filter transfer
// in both slopes. The previous soft clip plus an unrelated `1 + 2*sat` trim did
// the opposite at the top of the knob, losing 3.7 dB where the reference loses
// none.
// The drive reaches 74 at the top of the control, so the old ceiling of 20 --
// which was ample for a tanh -- would flatten the last third of the knob.
FILTER_SATURATE_MAX_DRIVE :: f32(200.0)

filter_saturate :: proc "contextless" (x, drive: f32) -> f32 {
	if !is_finite(x) {
		return 0
	}
	d := clamp32(drive, 0, FILTER_SATURATE_MAX_DRIVE)
	if d <= 0 {
		return x
	}
	// An algebraic saturator, normalised so that an input of one comes out at one,
	// which is what keeps the reference's peak fixed across the control.
	//
	// This used to be `tanh(x*d)/tanh(d)`, which was fitted from THD through an
	// open filter and is right there -- but a curve is not identified by one
	// operating point, and through a closed filter that one was up to 23 dB short
	// of the reference's harmonics. Read directly, by scattering a saturated
	// render against an unsaturated one sample for sample, the reference is this
	// instead: measured against nine candidate families at three settings it wins
	// every one of them by an order of magnitude, 0.00022, 0.00068 and 0.00241 dB
	// rms against tanh's 0.00306, 0.01707 and 0.02559.
	//
	// The difference is at the bottom of the curve, which is exactly where a
	// closed filter puts the signal: the small-signal gain here is `1 + d`, where
	// tanh's is `d/tanh(d)`, half again as steep at the middle of the knob.
	return x * (1.0 + d) / (1.0 + abs(x * d))
}

filter_process :: proc "contextless" (f: ^Filter, x: f32, mode: Filter_Mode, slope: Filter_Slope, saturation_drive: f32) -> f32 {
	input := x
	if !is_finite(input) {
		input = 0
	}

	lp, bp, hp := svf_process(f, &f.stage[0], input)
	out := svf_pick(f, mode, lp, bp, hp)

	if slope == .Slope_24 {
		lp2, bp2, hp2 := svf_process(f, &f.stage[1], out)
		out = svf_pick(f, mode, lp2, bp2, hp2)
	}

	return sanitize(filter_saturate(out, saturation_drive))
}

// A four-pole ladder, which is what the reference's 24 dB low pass is.
//
// Identified rather than assumed. Sweeping the reference across notes 24 to 100
// and fitting shapes with the corner left free -- so the fit tests the shape and
// not the cutoff table -- a cascade of four one-poles lands at 0.48 dB rms where
// the two cascaded biquads this engine used land at 1.53. Fitted state by state
// the ladder holds between 0.03 and 0.68 dB across the whole usable range.
//
// The decisive part is what resonance does. Held at cutoff 34 and swept from
// resonance 0 to 107, the fitted pole frequency stays at 114.2, 111.9 and 113.1
// Hz while the feedback runs 0.30, 2.10 and 3.20. A ladder resonates by feeding
// its output back, leaving its poles where they are; a pair of biquads resonates
// by reducing damping, which moves the -3 dB point. That is a structural
// difference and the reference is plainly on the ladder side of it.
//
// Zero-delay feedback, solved rather than iterated. Each one-pole contributes
// `y = G*x + (1-G)*s`, so the cascade is `y4 = A*u + B` with `A = G^4` and B the
// states' share, and with `u = x - k*y4` that closes to
//
//     y4 = (A*x + B) / (1 + A*k)
//
// which is exact for any feedback and needs no per-sample iteration.
LADDER_MAX_FEEDBACK :: f32(4.4)

Ladder :: struct {
	s: [4]f32,
	g: f32,
	G: f32,
	k: f32,
}

ladder_set :: proc "contextless" (l: ^Ladder, cutoff_hz, feedback, sample_rate: f32) {
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}
	fc := cutoff_hz
	if !is_finite(fc) {
		fc = MIN_CUTOFF_HZ
	}
	fc = clamp32(fc, MIN_CUTOFF_HZ, sr * MAX_CUTOFF_RATIO)

	l.g = math.tan(math.PI * fc / sr)
	l.G = l.g / (1.0 + l.g)
	k := feedback
	if !is_finite(k) {
		k = 0
	}
	l.k = clamp32(k, 0, LADDER_MAX_FEEDBACK)
}

ladder_reset :: proc "contextless" (l: ^Ladder) {
	l.s = {}
}

// No output normalisation, which is a correction to a first guess. A ladder loses
// `1/(1+k)` at DC as its feedback rises, and it was tempting to undo that. The
// reference does not undo it: its response fits `G^4/(1+k G^4)` with a *constant*
// gain at every resonance, to within 0.06 dB, and a constant gain against that
// model is exactly a filter whose DC falls away as it resonates. Measured
// directly, a note above the pole comes out at -3.6 dB at every resonance from 0
// to 127, where undoing the loss would have lifted it to +8.3 -- the compensation
// multiplies the stop band as readily as the pass band, and above the pole there
// is nothing else left to multiply.
ladder_process :: proc "contextless" (l: ^Ladder, x: f32) -> f32 {
	G := l.G
	one := 1.0 - G
	a := G * G * G * G
	b := one * (G * G * G * l.s[0] + G * G * l.s[1] + G * l.s[2] + l.s[3])

	input := x
	if !is_finite(input) {
		input = 0
	}
	y := (a * input + b) / (1.0 + a * l.k)
	u := input - l.k * y

	v := u
	for i in 0 ..< 4 {
		out := G * v + one * l.s[i]
		l.s[i] = flush_denormal(out + G * (v - l.s[i]))
		v = out
	}

	if !is_finite(l.s[0]) || !is_finite(l.s[1]) || !is_finite(l.s[2]) || !is_finite(l.s[3]) {
		l.s = {}
		return 0
	}
	return v
}
