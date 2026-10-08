package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"

// ---------------------------------------------------------------------------
// Wavetables
//
// The bank reproduces the reference's `CVco::buildWaveTables`, so these pin it
// to what that code produces rather than to what a band-limited oscillator
// ought to look like in general.
// ---------------------------------------------------------------------------

build_bank :: proc() -> ^dsp.Wavetable_Bank {
	b := new(dsp.Wavetable_Bank)
	dsp.wavetable_build(b)
	return b
}

// The reference's band layout at 22050 Hz: 23 quarter-octave bands from A0 while
// sixteen or more harmonics fit, then one band per harmonic count from 14 to 1.
@(test)
test_wavetable_band_layout_matches_reference :: proc(t: ^testing.T) {
	b := build_bank()
	defer free(b)

	testing.expect_value(t, b.band_count, 37)
	testing.expect_value(t, b.richer_below, f32(1575))

	want_harmonics := [37]int {
		801, 674, 566, 476, 400, 337, 283, 238, 200, 168, 141, 119, 100, 84, 70, 59,
		50, 42, 35, 29, 25, 21, 17, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1,
	}
	for i in 0 ..< 37 {
		testing.expectf(
			t,
			b.harmonics[i] == want_harmonics[i],
			"band %d: %d harmonics, want %d",
			i,
			b.harmonics[i],
			want_harmonics[i],
		)
	}

	// Quarter octaves from A0 for the spaced half...
	for i in 0 ..< 23 {
		want := 27.5 * math.pow(2.0, f64(i) / 4.0)
		testing.expectf(
			t,
			abs(f64(b.band_hz[i]) - want) < 0.01,
			"band %d at %v Hz, want %v",
			i,
			b.band_hz[i],
			want,
		)
	}
	// ...then 22050/H.
	for i in 23 ..< 37 {
		want := f32(22050.0) / f32(want_harmonics[i])
		testing.expect_value(t, b.band_hz[i], want)
	}

	// Ascending, which the picker's binary search relies on.
	for i in 1 ..< b.band_count {
		testing.expect(t, b.band_hz[i] > b.band_hz[i - 1])
	}
}

// Each table is its unwindowed Fourier series: (2/pi) sum sin(kx)/k for the saw,
// (8/pi^2) sum over odd k of +-sin(kx)/k^2 for the triangle, to the band's count.
@(test)
test_wavetable_tables_are_their_series :: proc(t: ^testing.T) {
	b := build_bank()
	defer free(b)

	for band in ([]int{0, 16, 30, 36}) {
		h := b.harmonics[band]
		worst_saw: f64 = 0
		worst_triangle: f64 = 0
		for n in 0 ..< dsp.WAVETABLE_SIZE {
			x := 2.0 * math.PI * f64(n) / f64(dsp.WAVETABLE_SIZE)
			saw: f64 = 0
			triangle: f64 = 0
			for k in 1 ..= h {
				saw += math.sin(f64(k) * x) / f64(k)
				if k & 1 == 1 {
					sign: f64 = k & 3 == 1 ? 1 : -1
					triangle += sign * math.sin(f64(k) * x) / f64(k * k)
				}
			}
			saw *= 2.0 / math.PI
			triangle *= 8.0 / (math.PI * math.PI)
			worst_saw = max(worst_saw, abs(saw - f64(b.saw[band][n])))
			worst_triangle = max(worst_triangle, abs(triangle - f64(b.triangle[band][n])))
		}
		// Single-precision accumulation over up to 801 terms.
		testing.expectf(t, worst_saw < 1.0e-4, "band %d saw off by %v", band, worst_saw)
		testing.expectf(
			t,
			worst_triangle < 1.0e-5,
			"band %d triangle off by %v",
			band,
			worst_triangle,
		)
	}

	// The conventions the oscillator relies on: the saw falls from +1 just after
	// phase 0 (with the series' Gibbs overshoot on a rich band), and the triangle
	// crosses zero rising at phase 0 and peaks a quarter turn later.
	testing.expect(t, b.saw[0][1] > 1.0)
	testing.expect(t, abs(b.triangle[0][0]) < 1.0e-6)
	testing.expect(t, b.triangle[0][dsp.WAVETABLE_SIZE / 4] > 0.99)
}

// The picker: the first band above the note, then one richer at or below 1575 Hz.
@(test)
test_wavetable_band_picker :: proc(t: ^testing.T) {
	b := build_bank()
	defer free(b)

	// 300 Hz sits between the 261.6 Hz and 311.1 Hz bands. The upper one is the
	// safe one; below 1575 Hz the reference steps back to the richer lower one.
	testing.expect_value(t, b.harmonics[dsp.wavetable_band(b, 300.0)], 84)

	// 3000 Hz sits between 2756.25 Hz (8 harmonics) and 3150 Hz (7). Above the
	// threshold the safe band is kept.
	testing.expect_value(t, b.harmonics[dsp.wavetable_band(b, 3000.0)], 7)

	// Above the threshold nothing the picker returns reaches past 22050 Hz.
	for hz := f32(1600); hz < 20000; hz *= 1.01 {
		band := dsp.wavetable_band(b, hz)
		top := f32(b.harmonics[band]) * hz
		testing.expectf(t, top <= 22050.0, "%v Hz picked %d harmonics, top %v Hz", hz, b.harmonics[band], top)
	}

	// Out of range in both directions lands on a real band.
	testing.expect_value(t, dsp.wavetable_band(b, 0.0), 0)
	testing.expect_value(t, dsp.wavetable_band(b, 1.0e9), b.band_count - 1)
}

// An oscillator with the bank attached reads it, keeps it across a note's
// re-init, and every shape stays bounded, audible and -- for the pulse -- DC-free.
@(test)
test_oscillator_plays_from_wavetables :: proc(t: ^testing.T) {
	b := build_bank()
	defer free(b)

	o: dsp.Oscillator
	dsp.oscillator_set_bank(&o, b)
	dsp.oscillator_init(&o, 42)
	testing.expect(t, o.bank == b, "oscillator_init dropped the bank")

	dsp.oscillator_set_frequency(&o, 100.0, SR)
	band := o.band
	testing.expect_value(t, band, dsp.wavetable_band(b, 100.0))

	dsp.oscillator_set_phase(&o, 0.3)
	want := dsp.wavetable_read(&b.saw[band], 0.3)
	testing.expect_value(t, dsp.oscillator_value(&o, .Saw, 0.5), want)

	for shape in dsp.Waveform {
		dsp.oscillator_init(&o, 7)
		dsp.oscillator_set_frequency(&o, 261.6256, SR)
		peak: f32 = 0
		sum: f64 = 0
		count := 0
		for _ in 0 ..< 4800 {
			dsp.oscillator_advance(&o)
			v := dsp.oscillator_value(&o, shape, 0.3)
			testing.expectf(t, finite(v), "%v produced %v", shape, v)
			peak = max(peak, abs(v))
			sum += f64(v)
			count += 1
		}
		testing.expectf(t, peak > 0.1 && peak <= 1.2, "%v peak %v", shape, peak)
		if shape == .Pulse {
			testing.expectf(t, abs(sum / f64(count)) < 0.01, "pulse carried DC %v", sum / f64(count))
		}
	}

	// A bank that was never built is refused rather than read as silence.
	unbuilt := new(dsp.Wavetable_Bank)
	defer free(unbuilt)
	dsp.oscillator_set_bank(&o, unbuilt)
	testing.expect(t, o.bank == nil)
}
