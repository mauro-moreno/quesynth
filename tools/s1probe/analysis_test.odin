package s1probe

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

// Known-answer tests for the null-test analysis.
//
// The point of these is that a comparison tool is only as trustworthy as its
// metrics. A spectral distance that quietly reports 0 dB for two different
// timbres would make the clone look finished; one that reports 12 dB for two
// identical renders would send someone chasing a defect that is not there.
// Every metric here is therefore checked against a signal whose answer is known
// before the reference binary is involved at all.

TEST_SR :: 48000.0

test_sine :: proc(n: int, hz, amplitude, phase: f64) -> []f32 {
	x := make([]f32, n)
	for i in 0 ..< n {
		t := f64(i) / TEST_SR
		x[i] = f32(amplitude * math.sin(2.0 * math.PI * hz * t + phase))
	}
	return x
}

// A deterministic noise source, so a failure is reproducible.
test_noise :: proc(n: int, seed: u32) -> []f32 {
	x := make([]f32, n)
	state := seed | 1
	for i in 0 ..< n {
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		x[i] = f32(f64(state >> 8) * (1.0 / 8388608.0) - 1.0)
	}
	return x
}

// Interleave a mono signal into an identical stereo pair.
test_stereo :: proc(mono: []f32) -> []f32 {
	out := make([]f32, len(mono) * 2)
	for i in 0 ..< len(mono) {
		out[i * 2] = mono[i]
		out[i * 2 + 1] = mono[i]
	}
	return out
}

// Shift `x` later by `d` samples, zero-filling the front.
test_delay :: proc(x: []f32, d: int) -> []f32 {
	out := make([]f32, len(x))
	for i in d ..< len(x) {
		out[i] = x[i - d]
	}
	return out
}

// ---------------------------------------------------------------------- FFT

@(test)
test_fft_puts_a_sinusoid_in_its_own_bin :: proc(t: ^testing.T) {
	n := 1024
	// Exactly 64 cycles in the frame, so the tone lands on bin 64 with no leak.
	bin := 64
	re := make([]f64, n)
	defer delete(re)
	im := make([]f64, n)
	defer delete(im)
	for i in 0 ..< n {
		re[i] = math.cos(2.0 * math.PI * f64(bin) * f64(i) / f64(n))
	}

	fft_forward(re, im)

	peak_bin := 0
	peak_power := 0.0
	for k in 0 ..< n / 2 + 1 {
		p := re[k] * re[k] + im[k] * im[k]
		if p > peak_power {
			peak_power = p
			peak_bin = k
		}
	}
	testing.expect_value(t, peak_bin, bin)

	// Every other bin must be numerically empty, which is the property the
	// spectral metric depends on: leakage would smear a tone across bands.
	for k in 0 ..< n / 2 + 1 {
		if k == bin {
			continue
		}
		p := re[k] * re[k] + im[k] * im[k]
		testing.expectf(t, p < peak_power * 1.0e-12, "bin %v holds %v against peak %v", k, p, peak_power)
	}
}

@(test)
test_fft_conserves_energy :: proc(t: ^testing.T) {
	n := 512
	src := test_noise(n, 0xC0FFEE)
	defer delete(src)

	re := make([]f64, n)
	defer delete(re)
	im := make([]f64, n)
	defer delete(im)

	time_energy := 0.0
	for i in 0 ..< n {
		re[i] = f64(src[i])
		time_energy += re[i] * re[i]
	}

	fft_forward(re, im)

	freq_energy := 0.0
	for k in 0 ..< n {
		freq_energy += re[k] * re[k] + im[k] * im[k]
	}
	freq_energy /= f64(n)

	// Parseval, to within accumulated rounding.
	rel := abs(freq_energy - time_energy) / time_energy
	testing.expectf(t, rel < 1.0e-10, "Parseval violated: time %v, freq %v", time_energy, freq_energy)
}

// ------------------------------------------------------------ null / align

@(test)
test_alignment_recovers_a_known_delay :: proc(t: ^testing.T) {
	n := 48000
	ref := test_sine(n, 220.0, 0.5, 0.0)
	defer delete(ref)
	// Noise rather than a second sinusoid: a periodic signal correlates just as
	// well at every whole period, so only an aperiodic one pins a unique lag.
	src := test_noise(n, 12345)
	defer delete(src)
	delayed := test_delay(src, 37)
	defer delete(delayed)

	lag, corr := best_alignment(src, delayed, 480)
	testing.expect_value(t, lag, 37)
	testing.expectf(t, corr > 0.99, "correlation at the true lag was only %v", corr)
}

@(test)
test_null_cancels_a_scaled_and_delayed_copy :: proc(t: ^testing.T) {
	n := 48000
	src := test_noise(n, 99)
	defer delete(src)
	delayed := test_delay(src, 17)
	defer delete(delayed)
	// Half the level, so the fitted gain has to do real work.
	scaled := make([]f32, n)
	defer delete(scaled)
	for i in 0 ..< n {
		scaled[i] = delayed[i] * 0.5
	}

	lag, _ := best_alignment(src, scaled, 480)
	testing.expect_value(t, lag, 17)

	gain, res_rms, ref_rms := null_residual(src, scaled, lag, nil)
	testing.expectf(t, abs(gain - 2.0) < 1.0e-3, "expected a fitted gain of 2, got %v", gain)

	null_db := amplitude_db(res_rms / ref_rms)
	testing.expectf(t, null_db < -100.0, "a scaled delayed copy should null deeply, got %v dB", null_db)
}

@(test)
test_null_of_unrelated_signals_is_shallow :: proc(t: ^testing.T) {
	n := 48000
	a := test_noise(n, 1)
	defer delete(a)
	b := test_noise(n, 2)
	defer delete(b)

	lag, _ := best_alignment(a, b, 480)
	_, res_rms, ref_rms := null_residual(a, b, lag, nil)
	null_db := amplitude_db(res_rms / ref_rms)

	// Two unrelated signals cannot cancel. Anything deeper than a fraction of a
	// dB here would mean the metric is fitting noise, and every real result
	// would be optimistic.
	testing.expectf(t, null_db > -1.0, "unrelated signals nulled by %v dB", null_db)
}

// ------------------------------------------------------------------ spectrum

@(test)
test_dominant_frequency_recovers_a_tone :: proc(t: ^testing.T) {
	n := 4 * FFT_SIZE
	tone := test_sine(n, 261.63, 0.5, 0.0) // middle C
	defer delete(tone)

	power := welch_power(tone, 0, n)
	defer delete(power)
	testing.expect(t, power != nil, "welch_power returned nothing for a long tone")

	bin_hz := TEST_SR / f64(FFT_SIZE)
	f0 := dominant_frequency(power, bin_hz, 2000.0)
	testing.expectf(t, abs(f0 - 261.63) < 1.0, "recovered %v Hz instead of 261.63", f0)
}

@(test)
test_identical_spectra_have_zero_band_distance :: proc(t: ^testing.T) {
	n := 4 * FFT_SIZE
	src := test_noise(n, 7)
	defer delete(src)

	power := welch_power(src, 0, n)
	defer delete(power)
	bin_hz := TEST_SR / f64(FFT_SIZE)

	bands, centres := band_powers(power, bin_hz)
	defer delete(bands)
	defer delete(centres)

	mean_db, worst_db, _, compared := band_distance_db(bands, bands, centres)
	testing.expect(t, compared > 30, "too few bands were compared to mean anything")
	testing.expectf(t, mean_db < 1.0e-9, "identical spectra differed by %v dB", mean_db)
	testing.expectf(t, worst_db < 1.0e-9, "identical spectra had a worst band of %v dB", worst_db)
}

@(test)
test_band_distance_ignores_level_but_sees_tilt :: proc(t: ^testing.T) {
	n := 4 * FFT_SIZE
	src := test_noise(n, 11)
	defer delete(src)

	// Same signal, 12 dB quieter: a level change, not a timbre change.
	quiet := make([]f32, n)
	defer delete(quiet)
	for i in 0 ..< n {
		quiet[i] = src[i] * 0.25
	}

	// Same signal through a one-pole low pass: a timbre change at the same
	// broad level.
	filtered := make([]f32, n)
	defer delete(filtered)
	state := f32(0)
	for i in 0 ..< n {
		state += 0.05 * (src[i] - state)
		filtered[i] = state
	}

	bin_hz := TEST_SR / f64(FFT_SIZE)

	ref_power := welch_power(src, 0, n)
	defer delete(ref_power)
	quiet_power := welch_power(quiet, 0, n)
	defer delete(quiet_power)
	filtered_power := welch_power(filtered, 0, n)
	defer delete(filtered_power)

	ref_bands, centres := band_powers(ref_power, bin_hz)
	defer delete(ref_bands)
	defer delete(centres)
	quiet_bands, qc := band_powers(quiet_power, bin_hz)
	defer delete(quiet_bands)
	defer delete(qc)
	filtered_bands, fc := band_powers(filtered_power, bin_hz)
	defer delete(filtered_bands)
	defer delete(fc)

	level_only, _, _, _ := band_distance_db(ref_bands, quiet_bands, centres)
	timbre, _, _, _ := band_distance_db(ref_bands, filtered_bands, centres)

	testing.expectf(t, level_only < 0.01, "a pure level change scored %v dB of timbre error", level_only)
	testing.expectf(t, timbre > 6.0, "a one-pole low pass only scored %v dB", timbre)
}

@(test)
test_centroid_orders_bright_above_dark :: proc(t: ^testing.T) {
	n := 4 * FFT_SIZE
	bright := test_sine(n, 4000.0, 0.5, 0.0)
	defer delete(bright)
	dark := test_sine(n, 200.0, 0.5, 0.0)
	defer delete(dark)

	bin_hz := TEST_SR / f64(FFT_SIZE)
	bright_power := welch_power(bright, 0, n)
	defer delete(bright_power)
	dark_power := welch_power(dark, 0, n)
	defer delete(dark_power)

	bc := spectral_centroid(bright_power, bin_hz)
	dc := spectral_centroid(dark_power, bin_hz)
	testing.expectf(t, bc > dc, "centroids out of order: bright %v, dark %v", bc, dc)
	testing.expectf(t, abs(bc - 4000.0) < 50.0, "bright centroid was %v", bc)
	testing.expectf(t, abs(dc - 200.0) < 50.0, "dark centroid was %v", dc)
}

// ------------------------------------------------------------------ envelope

@(test)
test_envelope_distance_sees_a_different_decay :: proc(t: ^testing.T) {
	n := 48000
	frame := int(ENVELOPE_FRAME_MS * 0.001 * TEST_SR)

	fast := make([]f32, n)
	defer delete(fast)
	slow := make([]f32, n)
	defer delete(slow)
	for i in 0 ..< n {
		t_s := f64(i) / TEST_SR
		carrier := math.sin(2.0 * math.PI * 440.0 * t_s)
		fast[i] = f32(math.exp(-8.0 * t_s) * carrier)
		slow[i] = f32(math.exp(-2.0 * t_s) * carrier)
	}

	fast_env := frame_envelope(fast, frame)
	defer delete(fast_env)
	slow_env := frame_envelope(slow, frame)
	defer delete(slow_env)

	same, _ := envelope_distance_db(fast_env, fast_env)
	different, compared := envelope_distance_db(fast_env, slow_env)

	testing.expectf(t, same < 1.0e-9, "an envelope differed from itself by %v dB", same)
	testing.expect(t, compared > 50, "too few envelope frames were compared")
	testing.expectf(t, different > 5.0, "a 4x decay difference only scored %v dB", different)
}

@(test)
test_release_time_is_measured_from_note_off :: proc(t: ^testing.T) {
	n := 48000
	frame := int(ENVELOPE_FRAME_MS * 0.001 * TEST_SR)
	note_off := n / 2

	// Flat while held, then a decay whose 60 dB point is known analytically:
	// exp(-k*t) reaches -60 dB at t = ln(1000)/k. With k = 20 that is 345 ms.
	x := make([]f32, n)
	defer delete(x)
	for i in 0 ..< n {
		t_s := f64(i) / TEST_SR
		carrier := math.sin(2.0 * math.PI * 440.0 * t_s)
		if i < note_off {
			x[i] = f32(carrier)
		} else {
			x[i] = f32(math.exp(-20.0 * (t_s - f64(note_off) / TEST_SR)) * carrier)
		}
	}

	env := frame_envelope(x, frame)
	defer delete(env)

	release := envelope_release_ms(env, note_off / frame, ENVELOPE_FRAME_MS)
	expected := 1000.0 * math.ln(f64(1000.0)) / 20.0
	testing.expectf(
		t,
		abs(release - expected) < 2.0 * ENVELOPE_FRAME_MS,
		"release measured %v ms, expected about %v ms",
		release,
		expected,
	)
}

// ----------------------------------------------------------------- top level

@(test)
test_comparing_a_render_with_itself_is_a_perfect_match :: proc(t: ^testing.T) {
	n := 3 * FFT_SIZE
	mono := test_noise(n, 4242)
	defer delete(mono)
	stereo := test_stereo(mono)
	defer delete(stereo)

	c := compare_renders(stereo, stereo, 2, TEST_SR, f64(n) / TEST_SR)

	testing.expect_value(t, c.best_lag, 0)
	testing.expectf(t, c.null_db < -100.0, "self-comparison nulled by only %v dB", c.null_db)
	testing.expectf(t, abs(c.level_db) < 1.0e-9, "self-comparison had a level error of %v dB", c.level_db)
	testing.expectf(t, c.spectral_db < 1.0e-9, "self-comparison had %v dB of spectral error", c.spectral_db)
	testing.expectf(t, c.envelope_db < 1.0e-9, "self-comparison had %v dB of envelope error", c.envelope_db)
	testing.expect(t, !c.ref_silent && !c.our_silent, "a noise render was reported as silent")
	testing.expect_value(t, c.our_non_finite, 0)
}

@(test)
test_comparison_separates_level_error_from_timbre_error :: proc(t: ^testing.T) {
	n := 3 * FFT_SIZE
	mono := test_noise(n, 5150)
	defer delete(mono)
	ref := test_stereo(mono)
	defer delete(ref)

	// Half amplitude, identical spectrum.
	quiet_mono := make([]f32, n)
	defer delete(quiet_mono)
	for i in 0 ..< n {
		quiet_mono[i] = mono[i] * 0.5
	}
	quiet := test_stereo(quiet_mono)
	defer delete(quiet)

	c := compare_renders(ref, quiet, 2, TEST_SR, f64(n) / TEST_SR)

	// The level error is reported where it belongs, and nowhere else: the gain
	// fit means a quiet-but-correct render still nulls, and the normalised
	// spectrum still matches.
	testing.expectf(t, abs(c.level_db + 6.0206) < 0.01, "expected -6 dB of level error, got %v", c.level_db)
	testing.expectf(t, c.null_db < -100.0, "a pure gain change should still null, got %v dB", c.null_db)
	testing.expectf(t, c.spectral_db < 1.0e-9, "a pure gain change scored %v dB of timbre error", c.spectral_db)
}

@(test)
test_a_render_that_dies_before_the_window_is_not_a_perfect_match :: proc(t: ^testing.T) {
	// The reference sustains for the whole note; ours decays to nothing inside
	// the first 100 ms. That is the largest disagreement a synthesiser can have
	// about an envelope, and it must never be reported as a spectral match.
	sample_rate := TEST_SR
	hold := 1.0
	n := int(1.5 * sample_rate)

	ref_mono := test_noise(n, 31337)
	defer delete(ref_mono)
	ref := test_stereo(ref_mono)
	defer delete(ref)

	our_mono := make([]f32, n)
	defer delete(our_mono)
	for i in 0 ..< n {
		t_s := f64(i) / sample_rate
		our_mono[i] = f32(f64(ref_mono[i]) * math.exp(-60.0 * t_s))
	}
	ours := test_stereo(our_mono)
	defer delete(ours)

	c := compare_renders(ref, ours, 2, sample_rate, hold)

	testing.expect(
		t,
		!c.spectral_valid,
		"a render that is silent through the steady-state window reported a valid spectrum",
	)
	testing.expectf(
		t,
		c.envelope_db > 10.0,
		"an envelope that collapses should score heavily, got %v dB",
		c.envelope_db,
	)
}

@(test)
test_comparison_reports_a_silent_render :: proc(t: ^testing.T) {
	n := 3 * FFT_SIZE
	mono := test_noise(n, 8080)
	defer delete(mono)
	ref := test_stereo(mono)
	defer delete(ref)
	silence := make([]f32, n * 2)
	defer delete(silence)

	c := compare_renders(ref, silence, 2, TEST_SR, f64(n) / TEST_SR)

	testing.expect(t, c.our_silent, "a silent render was not flagged")
	testing.expect(t, !c.ref_silent, "the reference was wrongly flagged silent")
	// The remaining metrics must stay at zero rather than being computed
	// against nothing, because a spectral error of 0 dB here would read as a
	// perfect match on a render that produces no sound at all.
	testing.expect_value(t, c.spectral_db, 0)
	testing.expect_value(t, c.envelope_db, 0)
}

// ------------------------------------------------------- harmonic structure
//
// Each test below builds a signal whose harmonic content is known by
// construction, so the metric is checked against arithmetic rather than against
// another render. These have to pass before any reading taken off the reference
// means anything.

// A mono power spectrum of a signal, the way the probes compute one.
test_power :: proc(mono: []f32) -> []f64 {
	return welch_power(mono, 0, len(mono))
}

test_bin_hz :: proc() -> f64 {
	return TEST_SR / f64(FFT_SIZE)
}

@(test)
test_harmonic_report_finds_a_pure_tone_and_nothing_else :: proc(t: ^testing.T) {
	f0 := 1000.0
	x := test_sine(4 * FFT_SIZE, f0, 0.5, 0)
	defer delete(x)
	power := test_power(x)
	defer delete(power)

	r := harmonic_report(power, test_bin_hz(), f0)

	testing.expect(t, r.fundamental > 0, "the fundamental was not found")
	// A single sine has no harmonics and no inharmonic content, so both must sit
	// far below the fundamental. The residue is leakage from the Hann window.
	testing.expect(t, r.thd_db < -60, fmt.tprintf("a pure sine reported %.1f dB of harmonics", r.thd_db))
	testing.expect(
		t,
		r.inharmonic_db < -60,
		fmt.tprintf("a pure sine reported %.1f dB of inharmonic content", r.inharmonic_db),
	)
}

@(test)
test_harmonic_report_separates_even_from_odd :: proc(t: ^testing.T) {
	f0 := 500.0
	n := 4 * FFT_SIZE

	// f0 plus a second harmonic 20 dB down and a third 40 dB down. Amplitude
	// ratios of 0.1 and 0.01 are -20 and -40 dB of power.
	even := test_sine(n, f0, 1.0, 0)
	defer delete(even)
	h2 := test_sine(n, 2 * f0, 0.1, 0)
	defer delete(h2)
	h3 := test_sine(n, 3 * f0, 0.01, 0)
	defer delete(h3)
	for i in 0 ..< n {
		even[i] += h2[i] + h3[i]
	}

	power := test_power(even)
	defer delete(power)
	r := harmonic_report(power, test_bin_hz(), f0)

	testing.expect(t, abs(r.even_db - -20.0) < 1.0, fmt.tprintf("even harmonics read %.2f dB, wanted -20", r.even_db))
	testing.expect(t, abs(r.odd_db - -40.0) < 1.0, fmt.tprintf("odd harmonics read %.2f dB, wanted -40", r.odd_db))
	// Total harmonic content is dominated by the louder of the two.
	testing.expect(t, abs(r.thd_db - -20.0) < 1.0, fmt.tprintf("THD read %.2f dB, wanted -20", r.thd_db))
	testing.expect(t, r.inharmonic_db < -60, "a harmonic series leaked into the inharmonic bucket")
}

@(test)
test_harmonic_report_puts_a_ring_modulator_in_the_inharmonic_bucket :: proc(t: ^testing.T) {
	// A carrier at 1000 Hz ring-modulated by 317 Hz: sidebands at 683 and 1317,
	// no energy at either original frequency. 317 is deliberately not a simple
	// ratio of 1000, so neither sideband can land in a harmonic window.
	n := 4 * FFT_SIZE
	lo := test_sine(n, 683.0, 0.5, 0)
	defer delete(lo)
	hi := test_sine(n, 1317.0, 0.5, 0)
	defer delete(hi)
	for i in 0 ..< n {
		lo[i] += hi[i]
	}

	power := test_power(lo)
	defer delete(power)
	r := harmonic_report(power, test_bin_hz(), 1000.0)

	// The fundamental is empty, so everything is inharmonic and the ratio is
	// large and positive rather than negative.
	testing.expect(
		t,
		r.inharmonic_db > 20,
		fmt.tprintf("ring modulation read only %.1f dB of inharmonic content", r.inharmonic_db),
	)
}

@(test)
test_harmonic_report_sees_low_frequency_loss :: proc(t: ^testing.T) {
	f0 := 1000.0
	n := 4 * FFT_SIZE
	x := test_sine(n, f0, 1.0, 0)
	defer delete(x)
	low := test_sine(n, 200.0, 0.1, 0) // -20 dB, below f0/2
	defer delete(low)

	bare := test_power(x)
	defer delete(bare)
	r_bare := harmonic_report(bare, test_bin_hz(), f0)

	for i in 0 ..< n {
		x[i] += low[i]
	}
	with_low := test_power(x)
	defer delete(with_low)
	r_low := harmonic_report(with_low, test_bin_hz(), f0)

	testing.expect(t, r_bare.sub_fundamental_db < -60, "a bare sine reported energy below f0/2")
	testing.expect(
		t,
		abs(r_low.sub_fundamental_db - -20.0) < 1.0,
		fmt.tprintf("sub-fundamental energy read %.2f dB, wanted -20", r_low.sub_fundamental_db),
	)
}

@(test)
test_spectral_peaks_recovers_ring_modulator_sidebands :: proc(t: ^testing.T) {
	n := 4 * FFT_SIZE
	lo := test_sine(n, 683.0, 0.5, 0)
	defer delete(lo)
	hi := test_sine(n, 1317.0, 0.5, 0)
	defer delete(hi)
	for i in 0 ..< n {
		lo[i] += hi[i]
	}

	power := test_power(lo)
	defer delete(power)
	peaks := spectral_peaks(power, test_bin_hz(), 8, -40)
	defer delete(peaks)

	testing.expect(t, len(peaks) >= 2, fmt.tprintf("expected two sidebands, found %d peaks", len(peaks)))
	if len(peaks) < 2 {
		return
	}

	// Sorted loudest first and both are equal here, so order by frequency
	// before checking. The recovered modulation frequency is half the gap.
	a, b := peaks[0].hz, peaks[1].hz
	if a > b {
		a, b = b, a
	}
	testing.expect(t, abs(a - 683.0) < 3.0, fmt.tprintf("lower sideband read %.1f Hz, wanted 683", a))
	testing.expect(t, abs(b - 1317.0) < 3.0, fmt.tprintf("upper sideband read %.1f Hz, wanted 1317", b))
	testing.expect(
		t,
		abs((b - a) * 0.5 - 317.0) < 3.0,
		fmt.tprintf("recovered modulation frequency %.1f Hz, wanted 317", (b - a) * 0.5),
	)
}

@(test)
test_spectral_peaks_does_not_split_one_lobe :: proc(t: ^testing.T) {
	// A single tone placed deliberately between two bins, where a Hann window
	// spreads it over several. It must still be reported once.
	f0 := 1000.0 + 0.5 * (TEST_SR / f64(FFT_SIZE))
	x := test_sine(4 * FFT_SIZE, f0, 0.5, 0)
	defer delete(x)
	power := test_power(x)
	defer delete(power)

	peaks := spectral_peaks(power, test_bin_hz(), 8, -40)
	defer delete(peaks)

	testing.expect_value(t, len(peaks), 1)
	if len(peaks) == 1 {
		testing.expect(t, abs(peaks[0].hz - f0) < 3.0, fmt.tprintf("peak read %.1f Hz, wanted %.1f", peaks[0].hz, f0))
	}
}

// ------------------------------------------------------- staircase structure

@(test)
test_hold_run_length_recovers_a_known_step :: proc(t: ^testing.T) {
	// A sine sampled and held every 7 samples.
	n := 8192
	src := test_sine(n, 220.0, 0.8, 0)
	defer delete(src)
	held := make([]f32, n)
	defer delete(held)
	for i in 0 ..< n {
		held[i] = src[(i / 7) * 7]
	}

	length, confidence := hold_run_length(held, 1)

	testing.expect_value(t, length, 7)
	testing.expect(t, confidence > 0.9, fmt.tprintf("confidence was only %.2f", confidence))
}

@(test)
test_hold_run_length_reports_no_confidence_on_a_continuous_signal :: proc(t: ^testing.T) {
	// A signal that was never held must not be handed a step length, or a rate
	// would be reported for an effect that is switched off.
	x := test_noise(8192, 4242)
	defer delete(x)

	length, confidence := hold_run_length(x, 1)

	testing.expect(
		t,
		length <= 1 || confidence < 0.5,
		fmt.tprintf("a continuous signal reported a %d-sample hold at confidence %.2f", length, confidence),
	)
}

@(test)
test_distinct_levels_counts_a_quantiser :: proc(t: ^testing.T) {
	// Four bits, signed: 16 levels. A full-scale sine visits all of them.
	n := 8192
	x := test_sine(n, 110.0, 1.0, 0)
	defer delete(x)
	step := f32(2.0 / 16.0)
	for i in 0 ..< n {
		x[i] = math.floor(x[i] / step) * step
	}

	// floor() of a full-scale sine lands on 16 distinct levels.
	levels := distinct_levels(x, 256)

	testing.expect(t, levels >= 15 && levels <= 17, fmt.tprintf("counted %d levels, wanted 16", levels))
}

@(test)
test_distinct_levels_saturates_on_an_unquantised_signal :: proc(t: ^testing.T) {
	x := test_sine(8192, 110.0, 1.0, 0)
	defer delete(x)
	testing.expect_value(t, distinct_levels(x, 256), 256)
}

// ------------------------------------------------------------ relative pitch

// A harmonic series at `f0` with per-harmonic amplitudes.
test_series :: proc(n: int, f0: f64, amplitudes: []f64) -> []f32 {
	out := make([]f32, n)
	for a, i in amplitudes {
		if a <= 0 {continue}
		h := test_sine(n, f0 * f64(i + 1), a, 0)
		defer delete(h)
		for j in 0 ..< n {
			out[j] += h[j]
		}
	}
	return out
}

@(test)
test_pitch_shift_is_zero_for_identical_spectra :: proc(t: ^testing.T) {
	x := test_series(4 * FFT_SIZE, 220.0, []f64{1.0, 0.5, 0.33, 0.25, 0.2, 0.16})
	defer delete(x)
	power := test_power(x)
	defer delete(power)

	cents, confidence := pitch_shift_cents(power, power, test_bin_hz())

	testing.expect(t, abs(cents) < 5.0, fmt.tprintf("identical spectra reported %.1f cents", cents))
	// The confidence returned is the smaller of the correlation and the margin over
	// the best rival peak, so even two identical harmonic spectra do not reach 1.0:
	// a harmonic series correlates with itself an octave away, and that rival is
	// subtracted. What matters is that the margin is decisively positive.
	testing.expect(t, confidence > 0.5, fmt.tprintf("confidence was only %.2f", confidence))
}

@(test)
test_pitch_shift_recovers_a_known_detune :: proc(t: ^testing.T) {
	amps := []f64{1.0, 0.5, 0.33, 0.25, 0.2, 0.16}
	ref := test_series(4 * FFT_SIZE, 220.0, amps)
	defer delete(ref)
	ref_power := test_power(ref)
	defer delete(ref_power)

	// Half a semitone up, an octave up, and an octave down.
	for want in ([]f64{50.0, 1200.0, -1200.0}) {
		hz := 220.0 * math.pow(2.0, want / 1200.0)
		ours := test_series(4 * FFT_SIZE, hz, amps)
		defer delete(ours)
		our_power := test_power(ours)
		defer delete(our_power)

		cents, confidence := pitch_shift_cents(ref_power, our_power, test_bin_hz())
		testing.expect(
			t,
			abs(cents - want) < 30.0,
			fmt.tprintf("a %.0f cent detune read as %.1f cents", want, cents),
		)
		testing.expect(t, confidence > 0.5, fmt.tprintf("confidence at %.0f cents was %.2f", want, confidence))
	}
}

@(test)
test_pitch_shift_ignores_which_harmonic_is_loudest :: proc(t: ^testing.T) {
	// The case that defeated the metric this replaced, reproduced from the bank.
	// Patch 110 has its first two harmonics 1.8 dB apart in the reference and
	// 1.7 dB apart the other way in our render, and that was enough for a
	// loudest-bin reading to report a full octave of detuning. Both signals here
	// are at the same pitch, so the only correct answer is zero.
	n := 4 * FFT_SIZE
	ref := test_series(n, 261.63, []f64{0.81, 1.0, 0.58, 0.70, 0.41, 0.50})
	defer delete(ref)
	ours := test_series(n, 261.63, []f64{1.0, 0.82, 0.47, 0.53, 0.29, 0.33})
	defer delete(ours)

	ref_power := test_power(ref)
	defer delete(ref_power)
	our_power := test_power(ours)
	defer delete(our_power)

	cents, _ := pitch_shift_cents(ref_power, our_power, test_bin_hz())
	testing.expect(
		t,
		abs(cents) < 30.0,
		fmt.tprintf("two renders at the same pitch reported %.1f cents of detuning", cents),
	)

	// And the old reading really would have been an octave out, which is what
	// makes this test worth having rather than merely passing.
	ref_dominant := dominant_frequency(ref_power, test_bin_hz(), BAND_HI_HZ)
	our_dominant := dominant_frequency(our_power, test_bin_hz(), BAND_HI_HZ)
	old_cents := 1200.0 * math.log2(our_dominant / ref_dominant)
	testing.expect(
		t,
		abs(old_cents) > 1000.0,
		fmt.tprintf("expected the loudest-bin reading to be an octave out, it read %.1f cents", old_cents),
	)
}

// --------------------------------------------------------------- csv integrity

@(test)
test_csv_row_has_exactly_as_many_fields_as_the_header :: proc(t: ^testing.T) {
	// This exists because the check it performs was skipped once and cost a whole
	// bank run. Two columns were added to the header and two values to the row, but
	// the format string was left with its original count -- so every row carried
	// two values through the wrong specifiers and the summary quietly reported a
	// stereo width of -47.9 where the truth was -0.07, along with wrong counts on
	// four other metrics. Nothing errored.
	row: Row
	row.name = "test.sy1"
	text := csv_row_text(row)
	defer delete(text)

	header_fields := strings.count(CSV_HEADER, ",") + 1
	row_fields := strings.count(strings.trim_space(text), ",") + 1

	testing.expect_value(t, row_fields, header_fields)
}
