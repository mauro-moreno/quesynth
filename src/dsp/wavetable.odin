package dsp

import "core:math"

// Band-limited wavetables, built the way the reference builds its own.
//
// This is the reference's own construction (its `CVco::buildWaveTables` and
// `CVco::selectWaveTable`), not something fitted to renders. The
// reference does not band-limit at run time at all: it sums each waveform's
// Fourier series once, at load, into 2048-sample tables, one per band, and plays
// them back by linear interpolation. Reproducing that is what lets the null test
// see the same spectrum rather than a PolyBLEP approximation of it -- the Gibbs
// ripple of an unwindowed series, the harmonic budget fixed at 22050 Hz whatever
// the sample rate, and the step in brightness at every band boundary.
//
// The bands:
//
//   - Quarter-octave steps up from A0, f = 27.5 * 512^(i/36), for as long as
//     22050/f still leaves sixteen or more harmonics. That is 23 bands, from
//     27.5 Hz (801 harmonics) to 1244.5 Hz (17).
//   - Then one band per harmonic count from where that stopped down to one, at
//     f = 22050/H. That is 14 more, 1575 Hz (14 harmonics) to 22050 Hz (1).
//
// Thirty-seven in all. The constants are the reference's own, and the band
// frequencies are computed in the same mix of single and double precision it
// uses, because the picker compares a note's frequency against them exactly.
//
// The bank is immutable once built and holds no per-voice state, so any number of
// oscillators can read one. It is caller-owned like everything else in this
// layer: the engine allocates one and builds it once, outside the audio path.

WAVETABLE_SIZE :: 2048
WAVETABLE_MASK :: WAVETABLE_SIZE - 1
// Room for the bands, with a little headroom; the reference's rule produces
// exactly 37 at 22050 Hz, and each band costs 16 KB across the two shapes.
WAVETABLE_MAX_BANDS :: 40

// The harmonic budget. The reference uses 22050 at every sample rate, so at 48 or
// 96 kHz its tables stop short of Nyquist rather than reaching it.
WAVETABLE_NYQUIST_HZ :: f32(22050.0)
WAVETABLE_BASE_HZ :: f64(27.5)
WAVETABLE_SPAN :: f64(512.0)
// 1/36 as the reference stores it, in single precision.
WAVETABLE_STEP :: f32(0.02777777798473835)
WAVETABLE_QUARTER_OCTAVE_BANDS :: 36
// Below this many harmonics the quarter-octave spacing gives way to one band per
// harmonic count.
WAVETABLE_MIN_SPACED_HARMONICS :: 16
WAVETABLE_INV_PI :: f64(0.3183098861837907)

Wavetable :: [WAVETABLE_SIZE]f32

Wavetable_Bank :: struct {
	band_count:   int,
	// Ascending. A band is the table built for a fundamental at this frequency.
	band_hz:      [WAVETABLE_MAX_BANDS]f32,
	harmonics:    [WAVETABLE_MAX_BANDS]int,
	// At or below this frequency the picker takes one band richer than the one it
	// lands on; see `wavetable_band`.
	richer_below: f32,
	sine:         Wavetable,
	// Descending, 1 at phase 0+: (2/pi) * sum sin(kx)/k.
	saw:          [WAVETABLE_MAX_BANDS]Wavetable,
	// Zero rising at phase 0: (8/pi^2) * sum over odd k of +-sin(kx)/k^2.
	triangle:     [WAVETABLE_MAX_BANDS]Wavetable,
	ready:        bool,
}

// Fill `b`. Deterministic and allocation-free; a few million multiply-adds, so it
// belongs in initialisation and never on the audio thread.
wavetable_build :: proc "contextless" (b: ^Wavetable_Bank) {
	b^ = {}

	// -- the bands -----------------------------------------------------------
	//
	// Single precision where the reference is single, double where it is double.
	// The quarter-octave frequency is exp(double(i * step) * ln 512) * 27.5,
	// rounded to float; the harmonic count is the float quotient truncated.
	log_span := math.ln(WAVETABLE_SPAN)
	count := 0
	previous := 0
	harmonics := 0
	for i in 0 ..< WAVETABLE_QUARTER_OCTAVE_BANDS {
		hz := f32(math.exp(f64(f32(i) * WAVETABLE_STEP) * log_span) * WAVETABLE_BASE_HZ)
		quotient := WAVETABLE_NYQUIST_HZ / hz
		if quotient < 1 {
			quotient = 1
		}
		harmonics = int(quotient)
		if harmonics < WAVETABLE_MIN_SPACED_HARMONICS {
			break
		}
		if harmonics != previous {
			b.band_hz[count] = hz
			count += 1
			previous = harmonics
		}
	}
	b.richer_below = f32(max(int(WAVETABLE_NYQUIST_HZ) / max(harmonics, 1), 1))
	for h := harmonics; h > 0 && count < WAVETABLE_MAX_BANDS; h -= 1 {
		hz := WAVETABLE_NYQUIST_HZ / f32(h)
		if hz < 1 {
			hz = 1
		}
		b.band_hz[count] = hz
		count += 1
	}
	b.band_count = count

	// The harmonic count each table is summed to is recomputed from its band's
	// frequency, as the reference does, rather than carried over -- for the bands
	// placed at 22050/H the float round trip is what decides it.
	for i in 0 ..< count {
		quotient := WAVETABLE_NYQUIST_HZ / b.band_hz[i]
		if quotient < 1 {
			quotient = 1
		}
		b.harmonics[i] = int(quotient)
	}

	// -- the sine ------------------------------------------------------------
	for n in 0 ..< WAVETABLE_SIZE {
		b.sine[n] = f32(math.sin(f64(n) * (2.0 * math.PI) * (1.0 / f64(WAVETABLE_SIZE))))
	}

	// -- the series ----------------------------------------------------------
	//
	// Every band's series is a prefix of the next richer band's, and the reference
	// sums each one from k = 1 upward in single precision. So one running sum,
	// copied out as k reaches each band's harmonic count, produces bit-identical
	// tables for a fraction of the work of summing every band from scratch.
	saw_sum: Wavetable
	triangle_sum: Wavetable
	top := 0
	for i in 0 ..< count {
		top = max(top, b.harmonics[i])
	}
	for k in 1 ..= top {
		index := 0
		inv_k := f32(k)
		for n in 0 ..< WAVETABLE_SIZE {
			saw_sum[n] = saw_sum[n] + b.sine[index] / inv_k
			index = (index + k) & WAVETABLE_MASK
		}
		if k & 1 == 1 {
			k_squared := f32(k * k)
			index = 0
			if k & 3 == 1 {
				for n in 0 ..< WAVETABLE_SIZE {
					triangle_sum[n] = triangle_sum[n] + b.sine[index] / k_squared
					index = (index + k) & WAVETABLE_MASK
				}
			} else {
				for n in 0 ..< WAVETABLE_SIZE {
					triangle_sum[n] = triangle_sum[n] - b.sine[index] / k_squared
					index = (index + k) & WAVETABLE_MASK
				}
			}
		}
		for i in 0 ..< count {
			if b.harmonics[i] != k {
				continue
			}
			for n in 0 ..< WAVETABLE_SIZE {
				b.saw[i][n] = f32(f64(saw_sum[n] * 2.0) * WAVETABLE_INV_PI)
				b.triangle[i][n] = f32(
					f64(triangle_sum[n] * 8.0) * WAVETABLE_INV_PI * WAVETABLE_INV_PI,
				)
			}
		}
	}

	b.ready = true
}

// The band to play a fundamental of `hz` from.
//
// The reference's rule, exactly: the first band whose frequency is above the
// note's, which always fits under 22050 Hz. Then, at or below 1575 Hz and when the
// note does not sit exactly on a band, one band richer -- whose top harmonics run
// up to a quarter-octave past 22050 Hz, so low notes trade a little aliasing for
// brightness. Above 1575 Hz the bands are a harmonic apart and it keeps the safe one.
wavetable_band :: proc "contextless" (b: ^Wavetable_Bank, hz: f32) -> int {
	if b.band_count <= 0 {
		return 0
	}
	lo := 0
	hi := b.band_count - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if hz >= b.band_hz[mid] {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if hz != b.band_hz[lo] && hz <= b.richer_below && lo > 0 {
		lo -= 1
	}
	return lo
}

// One table at a phase in turns, linearly interpolated.
//
// The reference holds its phase in 27-bit fixed point and interpolates on the low
// 16 bits; this reads the same table at a float phase, which differs from it only
// below the sixteenth fractional bit.
//
// The phase is on 0..1, which every oscillator path guarantees, so truncation is
// the floor and the mask only has to catch a phase of exactly 1.
wavetable_read :: proc "contextless" (table: ^Wavetable, phase: f32) -> f32 {
	x := phase * f32(WAVETABLE_SIZE)
	whole := int(x)
	frac := x - f32(whole)
	i := whole & WAVETABLE_MASK
	a := table[i]
	c := table[(i + 1) & WAVETABLE_MASK]
	return a + (c - a) * frac
}
