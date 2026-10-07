package s1probe

import "core:math"
import "core:testing"

// The `s1probe arch envlaw` instrument, fed signals whose answers are known by
// construction. The signals are written here from the formulas, not by the
// code that reads them, and the reading is compared with the whole number the
// formula gives rather than with a tolerance chosen to pass.

// A sine under an envelope that is a whole number of 1/2048ths at every 256th
// sample and a straight line between, which is what the reference's amplitude
// envelope turns out to be; and the same sine alone as the control.
envlaw_synth :: proc(length_samples: f64, ticks: int, fade: bool) -> (x, control: []f32) {
	count := ticks * ENVLAW_TICK
	x = make([]f32, count)
	control = make([]f32, count)
	w := 2 * math.PI * 1046.5 / 48000.0
	knot :: proc(j: int, length_samples: f64, fade: bool) -> f64 {
		u := (f64(j * 256) - 24) / length_samples
		if !fade {return 2048 * math.exp(-u * 6.9078)}
		if u <= 0 {return 2048}
		if u >= 1 {return 0}
		return math.floor(2048 * math.exp(-8 * u) * (1 - u))
	}
	for n in 0 ..< count {
		j := n / 256
		t := f64(n % 256) / 256
		e := knot(j, length_samples, fade) * (1 - t) + knot(j + 1, length_samples, fade) * t
		if !fade {e = knot(0, length_samples, fade) * math.exp(-f64(n) * 6.9078 / length_samples)}
		s := math.sin(w * f64(n) + 0.3)
		control[n] = f32(s)
		x[n] = f32(s * e / 2048)
	}
	return
}

@(test)
test_envlaw_reads_every_tick_of_a_fade_decay_exactly :: proc(t: ^testing.T) {
	length := 0.1 * 48000.0
	x, control := envlaw_synth(length, 24, true)
	defer delete(x)
	defer delete(control)
	knots := envlaw_knots(x, control, 0, 22)
	defer delete(knots)
	seg := Envlaw_Segment{base = 24, length = length, from = 2048, to = 0, k = 8}
	zero := envlaw_first_zero(knots)
	testing.expect(t, zero > 10, "the envelope never reads zero")
	m := envlaw_match(knots, 1, zero, seg)
	testing.expectf(t, m.read == zero && m.exact == m.read, "%v of %v knots exact", m.exact, m.read)
	k, share := envlaw_best_k(knots, 1, zero, seg, 7, 9, 0.001)
	testing.expectf(t, abs(k - 8) < 0.01 && share == 1, "best exponent %v with %v exact", k, share)
	plain := seg
	plain.pure = true
	_, plain_share := envlaw_best_k(knots, 1, zero, plain, 2, 14, 0.01)
	testing.expectf(t, plain_share < 0.5, "a plain exponential reads %v exact against a decay with a fade", plain_share)
}

@(test)
test_envlaw_tells_a_plain_exponential_from_the_fade_law :: proc(t: ^testing.T) {
	// What the engine did before: a smooth exponential, 60 dB down in the length.
	length := 0.8 * 48000.0
	x, control := envlaw_synth(length, 160, false)
	defer delete(x)
	defer delete(control)
	knots := envlaw_knots(x, control, 0, 150)
	defer delete(knots)
	seg := Envlaw_Segment{base = 24, length = length, from = 2048, to = 0, k = 8}
	m := envlaw_match(knots, 1, 100, seg)
	testing.expectf(t, m.read > 50, "only %v knots were readable", m.read)
	testing.expectf(t, m.exact * 2 < m.read, "%v of %v knots of a plain exponential came out exact against the fade law", m.exact, m.read)
	testing.expectf(t, m.worst_db > 1.5, "worst gap %v dB", m.worst_db)
}

@(test)
test_envlaw_attack_fit_reads_the_length_of_a_plain_ramp :: proc(t: ^testing.T) {
	w := 2 * math.PI * note_hz(ENVLAW_NOTE) / SAMPLE_RATE
	// A 0.02 s ramp, then full level.
	long := make([]f32, 16000)
	defer delete(long)
	for n in 0 ..< len(long) {
		long[n] = f32(0.6 * math.sin(w * f64(n)) * min(1.0, f64(n) / 960))
	}
	samples, rms := envlaw_attack_fit(long, 960)
	testing.expectf(t, abs(samples - 960) < 1, "ramp read as %v samples, want 960", samples)
	testing.expectf(t, rms < 0.01, "ramp residual %v", rms)
}

// A ramp of 300 samples under an approach of 70 is read by a line as about 270
// samples, because the approach bends it; the model reads both back.
@(test)
test_envlaw_attack_model_separates_the_ramp_from_the_onset_approach :: proc(t: ^testing.T) {
	w := 2 * math.PI * note_hz(ENVLAW_NOTE) / SAMPLE_RATE
	x := make([]f32, 16000)
	defer delete(x)
	for n in 0 ..< len(x) {
		x[n] = f32(0.6 * math.sin(w * f64(n)) * min(1.0, f64(n) / 300) * (1 - math.exp(-f64(n) / 70)))
	}
	line, _ := envlaw_attack_fit(x, 300)
	testing.expectf(t, abs(line - 300) > 15, "a line read the ramp as %v samples, so the approach did not bend it", line)
	ramp, tau, _ := envlaw_attack_model(x, 300)
	testing.expectf(t, abs(ramp - 300) < 2, "ramp read as %v samples, want 300", ramp)
	testing.expectf(t, abs(tau - 70) < 1, "approach read as %v samples, want 70", tau)
}
