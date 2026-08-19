// Null-test analysis: how far is our render from the reference render?
//
// This file is deliberately free of the plugin host, the filesystem and the
// engine. It takes two blocks of samples and returns numbers, so it can be
// unit-tested against synthesised signals whose answer is known in advance
// (see analysis_test.odin) rather than only against the reference binary.
//
// Why more than one metric:
//
// A raw sample-by-sample null is the strictest test and the least informative
// one. Two synthesisers that agree on every design decision but start their
// oscillators a fraction of a cycle apart null at 0 dB, and so do two that
// disagree about everything. The null depth is reported because when it *is*
// deep the argument is over, but the metrics that actually locate a defect are
// the three that ignore phase:
//
//   spectral_db   timbre: is the harmonic balance right? Answers the filter
//                 curve, the FM direction and the oscillator mix.
//   envelope_db   shape over time: is the amplitude contour right? Answers the
//                 attack/decay/sustain/release mapping directly.
//   centroid/f0   gross errors: a wrong octave, a filter an octave off, a
//                 ring/sync path that changed the spectrum's centre of mass.
//
// All three are level-independent, so a patch that is simply too loud reports
// its gain error in `level_db` and does not smear that error across everything
// else.
package s1probe

import "core:math"

// The steady-state window is analysed with a long FFT because the low end is
// where the sub oscillator and the fundamental live: at 48 kHz a 16384-point
// transform resolves 2.93 Hz, which keeps the 1/6-octave bands below 100 Hz
// populated. A shorter transform would silently drop them.
FFT_SIZE :: 16384
FFT_HOP :: 4096

// Comparison band. The lower edge is below the lowest note a factory patch
// reaches through the sub oscillator; the upper is where the reference's own
// output has rolled off and both renders are dominated by their respective
// anti-aliasing residue rather than by anything musical.
BAND_LO_HZ :: 20.0
BAND_HI_HZ :: 16000.0

// Sixth-octave bands rather than raw FFT bins. Linear bins would put 85% of the
// comparison above 2 kHz purely because that is where most bins are, which
// weights the metric by the arithmetic of the transform instead of by what a
// listener resolves.
BAND_RATIO :: 1.1224620483093730 // 2^(1/6)

// Bins more than this far below a spectrum's own peak are noise floor for that
// render, and their ratio to the other render's noise floor is not a musical
// difference. Clamping keeps two silent bins from reporting a 200 dB error.
SPECTRUM_FLOOR_DB :: -80.0

// Envelope frame length. Long enough to average out the waveform, short enough
// to resolve a fast attack.
ENVELOPE_FRAME_MS :: 5.0
ENVELOPE_FLOOR_DB :: -60.0

// How far the null search is allowed to slide one render against the other.
// 10 ms is far more than any plausible reporting difference in initial delay
// and still far less than one cycle of anything below 100 Hz, so a spurious
// alignment on a sub-oscillator period is not reachable.
MAX_LAG_MS :: 10.0

Comparison :: struct {
	frames:             int,
	sample_rate:        f64,

	// -- level ---------------------------------------------------------------
	ref_peak:           f64,
	our_peak:           f64,
	ref_rms:            f64,
	our_rms:            f64,
	// 20*log10(our_rms / ref_rms). Positive means we are louder.
	level_db:           f64,

	// -- time-domain null ----------------------------------------------------
	// The lag and gain that minimise the residual, and what is left after both.
	best_lag:           int,
	null_gain:          f64,
	correlation:        f64,
	// 20*log10(rms(residual) / rms(ref)). Always <= 0 because the gain is
	// fitted; -inf would be a bit-exact match, 0 dB is no cancellation at all.
	null_db:            f64,

	// -- steady-state spectrum ----------------------------------------------
	// Mean absolute sixth-octave difference in dB after both spectra are
	// normalised to equal energy. This is the timbre number.
	//
	// Only meaningful when `spectral_valid` is set. A render that has decayed to
	// silence before the steady-state window has no spectrum to normalise, and
	// the distance to a spectrum that does not exist is not zero -- it is
	// undefined. Reporting the zero would turn the loudest possible disagreement,
	// one render sustaining and the other already silent, into a perfect score.
	spectral_valid:     bool,
	spectral_db:        f64,
	// RMS inside the steady-state window, per render. What `spectral_valid` is
	// decided from, and worth reporting on its own: a sustain that is present in
	// one render and absent in the other is the finding.
	ref_steady_rms:     f64,
	our_steady_rms:     f64,
	// The worst single band, and where it is.
	spectral_worst_db:  f64,
	spectral_worst_hz:  f64,
	bands_compared:     int,
	ref_centroid_hz:    f64,
	our_centroid_hz:    f64,
	ref_fundamental_hz: f64,
	our_fundamental_hz: f64,
	// How far our spectrum sits from the reference's along a log-frequency axis, in
	// cents, with the normalised correlation that produced it. This is the tuning
	// reading; the two fields above are the *brightest partial*, which is a
	// different thing and was previously being asked to serve as both.
	pitch_cents:        f64,
	pitch_confidence:   f64,

	// -- amplitude envelope --------------------------------------------------
	// Mean absolute difference in dB between the two peak-normalised envelopes.
	envelope_db:        f64,
	ref_attack_ms:      f64,
	our_attack_ms:      f64,
	// Time from note off to 60 dB below the level at note off. -1 when the tail
	// never gets there inside the render.
	ref_release_ms:     f64,
	our_release_ms:     f64,

	// -- stereo --------------------------------------------------------------
	// RMS(side) / RMS(mid). Reveals unison pan spread and stereo effects.
	ref_width:          f64,
	our_width:          f64,

	// -- health --------------------------------------------------------------
	ref_silent:         bool,
	our_silent:         bool,
	our_non_finite:     int,
}

SILENCE_PEAK :: 1.0e-6

// A render whose steady-state window sits below this is not sustaining, and its
// spectrum there is arithmetic on a decayed tail rather than a timbre.
//
// The obvious test -- "is the summed power exactly zero" -- is not enough. An
// exponential decay reaches 1e-11 rather than 0, so it still produces a
// perfectly well-formed spectrum, normalises to unit energy like any other, and
// scores a respectable timbre match against whatever it is compared with. The
// threshold is absolute, at roughly -100 dBFS, so a genuinely quiet patch is
// still measured and a dead one is not.
WINDOW_SILENCE_RMS :: 1.0e-5

// ---------------------------------------------------------------------- FFT

// Iterative radix-2 Cooley-Tukey, in place, decimation in time.
//
// Written here rather than pulled from a library because the tool must build
// with nothing but the Odin compiler, which is the same constraint the rest of
// the repository works under. Twiddles are advanced recurrently; at 16384
// points the accumulated f64 error is around 1e-12, which is 200 dB below the
// smallest difference any metric here reports.
fft_forward :: proc(re, im: []f64) {
	n := len(re)
	if n < 2 || len(im) != n || n & (n - 1) != 0 {
		return
	}

	// Bit-reversal permutation.
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for bit != 0 && j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}

	length := 2
	for length <= n {
		half := length / 2
		angle := -2.0 * math.PI / f64(length)
		wr := math.cos(angle)
		wi := math.sin(angle)
		for start := 0; start < n; start += length {
			cr := 1.0
			ci := 0.0
			for k in 0 ..< half {
				a := start + k
				b := a + half
				vr := re[b] * cr - im[b] * ci
				vi := re[b] * ci + im[b] * cr
				re[b] = re[a] - vr
				im[b] = im[a] - vi
				re[a] += vr
				im[a] += vi
				next_cr := cr * wr - ci * wi
				ci = cr * wi + ci * wr
				cr = next_cr
			}
		}
		length <<= 1
	}
}

// ------------------------------------------------------------------- basics

amplitude_db :: proc(x: f64) -> f64 {
	if x <= 1.0e-12 {
		return -240.0
	}
	return 20.0 * math.log10(x)
}

power_db :: proc(x: f64) -> f64 {
	if x <= 1.0e-24 {
		return -240.0
	}
	return 10.0 * math.log10(x)
}

signal_peak :: proc(x: []f32) -> f64 {
	p := 0.0
	for v in x {
		a := abs(f64(v))
		if a > p {
			p = a
		}
	}
	return p
}

signal_rms :: proc(x: []f32) -> f64 {
	if len(x) == 0 {
		return 0
	}
	sum := 0.0
	for v in x {
		d := f64(v)
		sum += d * d
	}
	return math.sqrt(sum / f64(len(x)))
}

non_finite_count :: proc(x: []f32) -> int {
	n := 0
	for v in x {
		if v != v || v > math.F32_MAX || v < -math.F32_MAX {
			n += 1
		}
	}
	return n
}

// Mid and side of an interleaved buffer. A mono file yields a silent side.
split_mid_side :: proc(interleaved: []f32, channels: int) -> (mid, side: []f32) {
	if channels <= 0 {
		return nil, nil
	}
	frames := len(interleaved) / channels
	mid = make([]f32, frames)
	side = make([]f32, frames)
	for i in 0 ..< frames {
		l := interleaved[i * channels]
		r := channels > 1 ? interleaved[i * channels + 1] : l
		mid[i] = 0.5 * (l + r)
		side[i] = 0.5 * (l - r)
	}
	return
}

// ------------------------------------------------------------- null / align

// The lag, in samples, at which `ours` best matches `ref`, together with the
// normalised correlation there.
//
// Searched by brute force. The window is 10 ms and the analysed region is about
// a second, so this is a few million multiply-adds per patch: not worth an FFT
// cross-correlation, and a direct search cannot get its bookkeeping wrong.
best_alignment :: proc(ref, ours: []f32, max_lag: int) -> (lag: int, correlation: f64) {
	n := min(len(ref), len(ours))
	if n == 0 {
		return 0, 0
	}

	best_corr := -2.0
	best_lag := 0

	for candidate in -max_lag ..= max_lag {
		// Overlapping region for this shift: ref[i] against ours[i + candidate].
		lo := max(0, -candidate)
		hi := min(n, n - candidate)
		if hi - lo < n / 2 {
			continue
		}

		dot := 0.0
		ref_energy := 0.0
		our_energy := 0.0
		for i in lo ..< hi {
			a := f64(ref[i])
			b := f64(ours[i + candidate])
			dot += a * b
			ref_energy += a * a
			our_energy += b * b
		}
		if ref_energy <= 0 || our_energy <= 0 {
			continue
		}
		corr := dot / math.sqrt(ref_energy * our_energy)
		if corr > best_corr {
			best_corr = corr
			best_lag = candidate
		}
	}

	if best_corr < -1.0 {
		return 0, 0
	}
	return best_lag, best_corr
}

// Fit the single gain that minimises |ref - g*ours| at a fixed lag, and report
// what is left. Fitting the gain is what separates "wrong level" from "wrong
// sound": without it every patch whose amplitude mapping is slightly off would
// report a shallow null for a reason that `level_db` already covers.
null_residual :: proc(
	ref, ours: []f32,
	lag: int,
	residual: []f32,
) -> (
	gain: f64,
	residual_rms: f64,
	ref_rms: f64,
) {
	n := min(len(ref), len(ours))
	lo := max(0, -lag)
	hi := min(n, n - lag)
	if hi <= lo {
		return 0, 0, 0
	}

	dot := 0.0
	our_energy := 0.0
	for i in lo ..< hi {
		a := f64(ref[i])
		b := f64(ours[i + lag])
		dot += a * b
		our_energy += b * b
	}
	gain = our_energy > 0 ? dot / our_energy : 0

	ref_sum := 0.0
	res_sum := 0.0
	for i in lo ..< hi {
		a := f64(ref[i])
		b := f64(ours[i + lag])
		d := a - gain * b
		ref_sum += a * a
		res_sum += d * d
		if residual != nil && i < len(residual) {
			residual[i] = f32(d)
		}
	}
	count := f64(hi - lo)
	return gain, math.sqrt(res_sum / count), math.sqrt(ref_sum / count)
}

// ------------------------------------------------------------------ spectrum

// Welch-averaged power spectrum of x[from:to], Hann windowed. Returns power per
// bin, length FFT_SIZE/2 + 1. Nil when the region is shorter than one frame.
welch_power :: proc(x: []f32, from, to: int) -> []f64 {
	lo := max(0, from)
	hi := min(len(x), to)
	if hi - lo < FFT_SIZE {
		return nil
	}

	bins := FFT_SIZE / 2 + 1
	power := make([]f64, bins)

	window := make([]f64, FFT_SIZE)
	defer delete(window)
	window_energy := 0.0
	for i in 0 ..< FFT_SIZE {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(FFT_SIZE)))
		window[i] = w
		window_energy += w * w
	}

	re := make([]f64, FFT_SIZE)
	defer delete(re)
	im := make([]f64, FFT_SIZE)
	defer delete(im)

	frames := 0
	for start := lo; start + FFT_SIZE <= hi; start += FFT_HOP {
		for i in 0 ..< FFT_SIZE {
			re[i] = f64(x[start + i]) * window[i]
			im[i] = 0
		}
		fft_forward(re, im)
		for k in 0 ..< bins {
			power[k] += re[k] * re[k] + im[k] * im[k]
		}
		frames += 1
	}

	if frames == 0 {
		delete(power)
		return nil
	}
	// Normalise out the frame count and the window's energy so the result is
	// comparable between regions of different length.
	scale := 1.0 / (f64(frames) * window_energy)
	for k in 0 ..< bins {
		power[k] *= scale
	}
	return power
}

// Sixth-octave band powers over BAND_LO_HZ..BAND_HI_HZ.
//
// A band with no FFT bin centre inside it is reported as -1 rather than 0, so
// the caller can exclude it instead of comparing two fabricated zeroes. That
// happens at the bottom of the range, where the bands are narrower than a bin.
band_powers :: proc(power: []f64, bin_hz: f64) -> (bands: []f64, centres: []f64) {
	if len(power) == 0 || bin_hz <= 0 {
		return nil, nil
	}

	count := 0
	for edge := BAND_LO_HZ; edge < BAND_HI_HZ; edge *= BAND_RATIO {
		count += 1
	}
	if count == 0 {
		return nil, nil
	}

	bands = make([]f64, count)
	centres = make([]f64, count)

	lower := BAND_LO_HZ
	for b in 0 ..< count {
		upper := lower * BAND_RATIO
		centres[b] = math.sqrt(lower * upper)

		sum := 0.0
		bins := 0
		first := int(math.ceil(lower / bin_hz))
		for k := max(first, 1); k < len(power); k += 1 {
			hz := f64(k) * bin_hz
			if hz >= upper {
				break
			}
			sum += power[k]
			bins += 1
		}
		bands[b] = bins > 0 ? sum : -1.0
		lower = upper
	}
	return
}

// Mean absolute sixth-octave difference in dB, after normalising both spectra
// to equal total energy over the compared bands.
//
// Normalising is what makes this a timbre metric: a render that is 3 dB loud
// but spectrally identical scores 0 here and reports its 3 dB in `level_db`.
band_distance_db :: proc(
	ref_bands, our_bands, centres: []f64,
) -> (
	mean_db: f64,
	worst_db: f64,
	worst_hz: f64,
	compared: int,
) {
	n := min(len(ref_bands), len(our_bands))
	if n == 0 {
		return 0, 0, 0, 0
	}

	ref_total := 0.0
	our_total := 0.0
	for b in 0 ..< n {
		if ref_bands[b] < 0 || our_bands[b] < 0 {
			continue
		}
		ref_total += ref_bands[b]
		our_total += our_bands[b]
	}
	if ref_total <= 0 || our_total <= 0 {
		return 0, 0, 0, 0
	}

	// Floors are taken from each spectrum's own peak band, so "this band is
	// noise floor" is judged per render rather than against a shared absolute.
	ref_max := 0.0
	our_max := 0.0
	for b in 0 ..< n {
		if ref_bands[b] > ref_max {
			ref_max = ref_bands[b]
		}
		if our_bands[b] > our_max {
			our_max = our_bands[b]
		}
	}
	ref_floor := ref_max / ref_total * math.pow(f64(10.0), f64(SPECTRUM_FLOOR_DB) / 10.0)
	our_floor := our_max / our_total * math.pow(f64(10.0), f64(SPECTRUM_FLOOR_DB) / 10.0)

	sum := 0.0
	for b in 0 ..< n {
		if ref_bands[b] < 0 || our_bands[b] < 0 {
			continue
		}
		a := max(ref_bands[b] / ref_total, ref_floor)
		c := max(our_bands[b] / our_total, our_floor)
		d := abs(power_db(a) - power_db(c))
		sum += d
		compared += 1
		if d > worst_db {
			worst_db = d
			worst_hz = b < len(centres) ? centres[b] : 0
		}
	}
	if compared == 0 {
		return 0, 0, 0, 0
	}
	return sum / f64(compared), worst_db, worst_hz, compared
}

// Power-weighted mean frequency over the compared band.
spectral_centroid :: proc(power: []f64, bin_hz: f64) -> f64 {
	if len(power) == 0 || bin_hz <= 0 {
		return 0
	}
	num := 0.0
	den := 0.0
	for k in 1 ..< len(power) {
		hz := f64(k) * bin_hz
		if hz < BAND_LO_HZ {
			continue
		}
		if hz > BAND_HI_HZ {
			break
		}
		num += hz * power[k]
		den += power[k]
	}
	return den > 0 ? num / den : 0
}

// The strongest bin below `limit_hz`, parabolically interpolated against its
// neighbours so the answer is not quantised to the 2.93 Hz bin grid. A wrong
// octave, a detune that landed in semitones, or a sub oscillator drowning the
// fundamental all show up here as a plain frequency difference.
dominant_frequency :: proc(power: []f64, bin_hz: f64, limit_hz: f64) -> f64 {
	if len(power) < 3 || bin_hz <= 0 {
		return 0
	}
	best := 0
	best_power := 0.0
	for k in 1 ..< len(power) - 1 {
		hz := f64(k) * bin_hz
		if hz < BAND_LO_HZ {
			continue
		}
		if hz > limit_hz {
			break
		}
		if power[k] > best_power {
			best_power = power[k]
			best = k
		}
	}
	if best == 0 {
		return 0
	}

	// Parabolic interpolation on the log magnitudes of the three-point peak.
	a := power_db(power[best - 1])
	b := power_db(power[best])
	c := power_db(power[best + 1])
	denom := a - 2.0 * b + c
	offset := 0.0
	if abs(denom) > 1.0e-12 {
		offset = 0.5 * (a - c) / denom
		offset = clamp(offset, -1.0, 1.0)
	}
	return (f64(best) + offset) * bin_hz
}

// ------------------------------------------------------------------ envelope

// Frame-by-frame RMS.
frame_envelope :: proc(x: []f32, frame_len: int) -> []f64 {
	if frame_len <= 0 || len(x) < frame_len {
		return nil
	}
	count := len(x) / frame_len
	env := make([]f64, count)
	for f in 0 ..< count {
		sum := 0.0
		base := f * frame_len
		for i in 0 ..< frame_len {
			d := f64(x[base + i])
			sum += d * d
		}
		env[f] = math.sqrt(sum / f64(frame_len))
	}
	return env
}

// Mean absolute difference between two envelopes, each normalised to its own
// peak and expressed in dB with a floor.
//
// Frames where both renders are below the floor are skipped: two silences agree
// trivially, and counting them would let a long tail dilute a real disagreement
// during the note.
envelope_distance_db :: proc(ref_env, our_env: []f64) -> (mean_db: f64, compared: int) {
	n := min(len(ref_env), len(our_env))
	if n == 0 {
		return 0, 0
	}

	ref_max := 0.0
	our_max := 0.0
	for f in 0 ..< n {
		if ref_env[f] > ref_max {
			ref_max = ref_env[f]
		}
		if our_env[f] > our_max {
			our_max = our_env[f]
		}
	}
	if ref_max <= 0 || our_max <= 0 {
		return 0, 0
	}

	sum := 0.0
	for f in 0 ..< n {
		a := amplitude_db(ref_env[f] / ref_max)
		b := amplitude_db(our_env[f] / our_max)
		if a < ENVELOPE_FLOOR_DB && b < ENVELOPE_FLOOR_DB {
			continue
		}
		a = max(a, ENVELOPE_FLOOR_DB)
		b = max(b, ENVELOPE_FLOOR_DB)
		sum += abs(a - b)
		compared += 1
	}
	if compared == 0 {
		return 0, 0
	}
	return sum / f64(compared), compared
}

// Time from the start of the render to the loudest frame before note off.
envelope_attack_ms :: proc(env: []f64, note_off_frame: int, frame_ms: f64) -> f64 {
	limit := min(note_off_frame, len(env))
	if limit <= 0 {
		return -1
	}
	best := 0
	best_value := -1.0
	for f in 0 ..< limit {
		if env[f] > best_value {
			best_value = env[f]
			best = f
		}
	}
	return f64(best) * frame_ms
}

// Time from note off until the tail is 60 dB below the level at note off.
// -1 when the render ends first, which is itself a finding.
envelope_release_ms :: proc(env: []f64, note_off_frame: int, frame_ms: f64) -> f64 {
	if note_off_frame < 0 || note_off_frame >= len(env) {
		return -1
	}
	at_off := env[note_off_frame]
	if at_off <= 0 {
		return 0
	}
	target := at_off * math.pow(f64(10.0), f64(ENVELOPE_FLOOR_DB) / 20.0)
	for f in note_off_frame ..< len(env) {
		if env[f] <= target {
			return f64(f - note_off_frame) * frame_ms
		}
	}
	return -1
}

// ----------------------------------------------------------------- top level

// Compare two interleaved renders of the same patch under the same conditions.
//
// `residual` is optional; when supplied it receives the aligned, gain-fitted
// difference of the mid signals, which is what you listen to when a number
// looks wrong and you want to know what is left over.
compare_renders :: proc(
	ref_interleaved, our_interleaved: []f32,
	channels: int,
	sample_rate: f64,
	hold_seconds: f64,
	residual: []f32 = nil,
) -> Comparison {
	c: Comparison
	c.sample_rate = sample_rate

	if channels <= 0 || sample_rate <= 0 {
		return c
	}

	ref_mid, ref_side := split_mid_side(ref_interleaved, channels)
	defer delete(ref_mid)
	defer delete(ref_side)
	our_mid, our_side := split_mid_side(our_interleaved, channels)
	defer delete(our_mid)
	defer delete(our_side)

	c.frames = min(len(ref_mid), len(our_mid))
	if c.frames == 0 {
		return c
	}

	// -- level ---------------------------------------------------------------

	c.ref_peak = signal_peak(ref_interleaved)
	c.our_peak = signal_peak(our_interleaved)
	c.ref_rms = signal_rms(ref_mid)
	c.our_rms = signal_rms(our_mid)
	c.ref_silent = c.ref_peak < SILENCE_PEAK
	c.our_silent = c.our_peak < SILENCE_PEAK
	c.our_non_finite = non_finite_count(our_interleaved)
	c.level_db = c.ref_rms > 0 && c.our_rms > 0 ? amplitude_db(c.our_rms / c.ref_rms) : 0

	ref_side_rms := signal_rms(ref_side)
	our_side_rms := signal_rms(our_side)
	c.ref_width = c.ref_rms > 0 ? ref_side_rms / c.ref_rms : 0
	c.our_width = c.our_rms > 0 ? our_side_rms / c.our_rms : 0

	if c.ref_silent || c.our_silent {
		// Every remaining metric is a ratio against something that is not there.
		// Reporting zeros would read as agreement, so they are left at their zero
		// value and the caller keys off the silence flags.
		return c
	}

	// -- time-domain null ----------------------------------------------------

	// The lag is searched over the first second only. That is where the attack
	// transient is, so it is both the most informative region for alignment and
	// a fixed cost per patch rather than one that grows with the release tail.
	// The residual below then uses that lag over the whole render.
	max_lag := int(MAX_LAG_MS * 0.001 * sample_rate)
	align_to := min(c.frames, int(1.0 * sample_rate))
	c.best_lag, c.correlation = best_alignment(ref_mid[:align_to], our_mid[:align_to], max_lag)
	gain, res_rms, ref_rms := null_residual(
		ref_mid[:c.frames],
		our_mid[:c.frames],
		c.best_lag,
		residual,
	)
	c.null_gain = gain
	c.null_db = ref_rms > 0 ? amplitude_db(res_rms / ref_rms) : 0

	// -- steady-state spectrum ----------------------------------------------

	// The window starts after the attack has settled and ends before note off,
	// so neither transient is averaged into what is meant to be the sustained
	// timbre. The envelope metric is where the transients are judged.
	steady_from := int(0.40 * sample_rate)
	steady_to := int(hold_seconds * sample_rate)
	if steady_to - steady_from < FFT_SIZE {
		// Short hold: analyse whatever is inside the note.
		steady_from = 0
		steady_to = min(c.frames, int(hold_seconds * sample_rate))
	}

	bin_hz := sample_rate / f64(FFT_SIZE)

	window_lo := clamp(steady_from, 0, c.frames)
	window_hi := clamp(steady_to, window_lo, c.frames)
	c.ref_steady_rms = signal_rms(ref_mid[window_lo:window_hi])
	c.our_steady_rms = signal_rms(our_mid[window_lo:window_hi])
	sustaining := c.ref_steady_rms > WINDOW_SILENCE_RMS && c.our_steady_rms > WINDOW_SILENCE_RMS

	ref_power := welch_power(ref_mid[:c.frames], steady_from, steady_to)
	our_power := welch_power(our_mid[:c.frames], steady_from, steady_to)
	defer delete(ref_power)
	defer delete(our_power)

	if ref_power != nil && our_power != nil && sustaining {
		ref_bands, centres := band_powers(ref_power, bin_hz)
		our_bands, our_centres := band_powers(our_power, bin_hz)
		defer delete(ref_bands)
		defer delete(centres)
		defer delete(our_bands)
		defer delete(our_centres)

		c.spectral_db, c.spectral_worst_db, c.spectral_worst_hz, c.bands_compared =
			band_distance_db(ref_bands, our_bands, centres)
		c.spectral_valid = c.bands_compared > 0

		c.ref_centroid_hz = spectral_centroid(ref_power, bin_hz)
		c.our_centroid_hz = spectral_centroid(our_power, bin_hz)
		c.ref_fundamental_hz = dominant_frequency(ref_power, bin_hz, 2000.0)
		c.our_fundamental_hz = dominant_frequency(our_power, bin_hz, 2000.0)
		c.pitch_cents, c.pitch_confidence = pitch_shift_cents(ref_power, our_power, bin_hz)
	}

	// -- envelope ------------------------------------------------------------

	frame_len := int(ENVELOPE_FRAME_MS * 0.001 * sample_rate)
	ref_env := frame_envelope(ref_mid[:c.frames], frame_len)
	our_env := frame_envelope(our_mid[:c.frames], frame_len)
	defer delete(ref_env)
	defer delete(our_env)

	if ref_env != nil && our_env != nil {
		c.envelope_db, _ = envelope_distance_db(ref_env, our_env)
		note_off_frame := int(hold_seconds * sample_rate) / frame_len
		c.ref_attack_ms = envelope_attack_ms(ref_env, note_off_frame, ENVELOPE_FRAME_MS)
		c.our_attack_ms = envelope_attack_ms(our_env, note_off_frame, ENVELOPE_FRAME_MS)
		c.ref_release_ms = envelope_release_ms(ref_env, note_off_frame, ENVELOPE_FRAME_MS)
		c.our_release_ms = envelope_release_ms(our_env, note_off_frame, ENVELOPE_FRAME_MS)
	}

	return c
}

// ------------------------------------------------------- harmonic structure

// A nonlinearity is identified by what it adds to a pure tone, so the metrics
// below all describe a spectrum relative to one known fundamental. Feed them a
// render of a single sine and every number is attributable to the effect under
// test.
//
// Everything is reported in dB relative to the fundamental, which makes the
// readings independent of the drive level and of any make-up gain the effect
// applies -- both of which move while a control is swept.

// How many multiples of the fundamental to account for.
//
// Deliberately large. The first version of this used twelve, which forced the
// probes onto a high fundamental so that twelve multiples would span the band --
// and that made the metric lie. Distortion inside the reference is not
// oversampled, so a clipped 1397 Hz sine puts harmonics above Nyquist that fold
// back to |k*f0 - n*48000|, and because 48000 is not a multiple of 1397 those
// folded partials land between the harmonic windows. Ordinary waveshaping then
// read as inharmonic content, which is the signature of a completely different
// effect. A low fundamental with enough windows to cover the band keeps folded
// harmonics inside the harmonic buckets where they belong.
MAX_HARMONIC :: 128

// Half-width of the window claimed by each harmonic, as a fraction of the
// fundamental. Wide enough to hold a Hann main lobe plus the reference's own
// tuning error, narrow enough that the 2f0 window cannot reach 3f0.
HARMONIC_TOLERANCE :: 0.06

Harmonic_Report :: struct {
	// Absolute power of the fundamental, for a level comparison across renders.
	fundamental:      f64,
	// Power at k * f0, indexed by k; [0] and [1] hold zero and the fundamental.
	harmonic:         [MAX_HARMONIC + 1]f64,
	// Summed power of harmonics 2, 4, 6.. and 3, 5, 7.., in dB relative to the
	// fundamental. a.d.1 is documented as favouring even harmonics, so the
	// difference between these two is a type signature and not a curiosity.
	even_db:          f64,
	odd_db:           f64,
	// All harmonics above the first, relative to the fundamental.
	thd_db:           f64,
	// Everything in band that fell inside no harmonic window, relative to the
	// fundamental. A waveshaper leaves this near the noise floor; ring
	// modulation and decimation both put most of their output here.
	inharmonic_db:    f64,
	// Band-limited total, so a control that only changes loudness is visible.
	total:            f64,
	// Power below f0/2 relative to the fundamental: the low-frequency loss the
	// manual attributes to a.d.1's negative feedback.
	sub_fundamental_db: f64,
}

// `f0` is the expected fundamental in hertz. Windows are centred on exact
// multiples of it rather than on measured peaks: a peak search would follow a
// ring modulator's sidebands and report them as harmonics.
harmonic_report :: proc(power: []f64, bin_hz, f0: f64) -> (report: Harmonic_Report) {
	if len(power) < 3 || bin_hz <= 0 || f0 <= 0 {
		return
	}

	tolerance := f0 * HARMONIC_TOLERANCE
	even, odd, inharmonic, sub: f64

	for k in 1 ..< len(power) {
		hz := f64(k) * bin_hz
		if hz < BAND_LO_HZ {
			continue
		}
		if hz > BAND_HI_HZ {
			break
		}
		report.total += power[k]

		// Which harmonic window, if any, contains this bin.
		index := int(hz / f0 + 0.5)
		matched := index >= 1 && index <= MAX_HARMONIC && abs(hz - f64(index) * f0) <= tolerance

		if matched {
			report.harmonic[index] += power[k]
			if index >= 2 {
				if index % 2 == 0 {
					even += power[k]
				} else {
					odd += power[k]
				}
			}
		} else {
			inharmonic += power[k]
		}

		if hz < f0 * 0.5 {
			sub += power[k]
		}
	}

	report.fundamental = report.harmonic[1]
	if report.fundamental <= 0 {
		return
	}

	report.even_db = power_db(even / report.fundamental)
	report.odd_db = power_db(odd / report.fundamental)
	report.thd_db = power_db((even + odd) / report.fundamental)
	report.inharmonic_db = power_db(inharmonic / report.fundamental)
	report.sub_fundamental_db = power_db(sub / report.fundamental)
	return
}

Peak :: struct {
	hz: f64,
	db: f64, // relative to the strongest peak found
}

// The strongest local maxima in the spectrum, parabolically interpolated and
// returned loudest first.
//
// This is the reading that names a ring modulator: a carrier at f0 modulated by
// fm puts peaks at f0-fm and f0+fm and leaves nothing at f0, so the two
// strongest peaks straddle a gap and their half-separation is the modulation
// frequency in hertz. `harmonic_report` cannot see that -- both sidebands land
// in its inharmonic bucket -- which is why this exists alongside it.
//
// `min_rel_db` discards peaks quieter than that many dB below the strongest, so
// the caller is not handed a list of noise-floor bumps. Peaks closer together
// than one harmonic tolerance are merged, keeping the louder, so a single Hann
// lobe cannot be reported as several peaks.
spectral_peaks :: proc(
	power: []f64,
	bin_hz: f64,
	count: int,
	min_rel_db: f64,
	allocator := context.allocator,
) -> []Peak {
	if len(power) < 3 || bin_hz <= 0 || count <= 0 {
		return nil
	}

	found := make([dynamic]Peak, allocator)

	strongest := 0.0
	for k in 1 ..< len(power) - 1 {
		hz := f64(k) * bin_hz
		if hz < BAND_LO_HZ || hz > BAND_HI_HZ {
			continue
		}
		if power[k] > strongest {
			strongest = power[k]
		}
	}
	if strongest <= 0 {
		return found[:]
	}

	for k in 1 ..< len(power) - 1 {
		hz := f64(k) * bin_hz
		if hz < BAND_LO_HZ || hz > BAND_HI_HZ {
			continue
		}
		if power[k] < power[k - 1] || power[k] < power[k + 1] {
			continue
		}
		db := power_db(power[k] / strongest)
		if db < min_rel_db {
			continue
		}

		a := power_db(power[k - 1])
		b := power_db(power[k])
		c := power_db(power[k + 1])
		denom := a - 2.0 * b + c
		offset := 0.0
		if abs(denom) > 1.0e-12 {
			offset = clamp(0.5 * (a - c) / denom, -1.0, 1.0)
		}
		append(&found, Peak{hz = (f64(k) + offset) * bin_hz, db = db})
	}

	// Loudest first.
	for i in 1 ..< len(found) {
		p := found[i]
		j := i - 1
		for j >= 0 && found[j].db < p.db {
			found[j + 1] = found[j]
			j -= 1
		}
		found[j + 1] = p
	}

	// Merge lobes, then truncate.
	kept := make([dynamic]Peak, allocator)
	for p in found {
		if len(kept) >= count {
			break
		}
		merged := false
		for q in kept {
			if abs(q.hz - p.hz) <= q.hz * HARMONIC_TOLERANCE {
				merged = true
				break
			}
		}
		if !merged {
			append(&kept, p)
		}
	}

	delete(found)
	return kept[:]
}

// ------------------------------------------------------- staircase structure

// Sample-rate and bit-depth reduction are the two effects in the plugin whose
// parameters are far easier to read in the time domain than in the spectrum.
//
// Inferring them spectrally means locating images at |k*fs' +- f0| and solving
// for fs', and the readings bounce: as fs' sweeps, images cross in and out of
// the harmonic windows, so the harmonic and inharmonic totals swing by 15 dB
// between adjacent settings while the underlying control moves smoothly. But a
// decimator's output is literally a staircase, so the step length gives the rate
// and the number of distinct step heights gives the depth. Both are exact.
//
// Both readings need a fully wet signal. With any dry mixed back in, the
// staircase is buried under a continuous signal and neither is recoverable.

// The dominant run length of consecutive identical samples, and the fraction of
// the signal that agrees with it.
//
// `confidence` is what makes this safe to act on: a signal that was never
// sample-and-held has runs of length 1 almost everywhere, and reporting a rate
// from that would be inventing one. Anything below about 0.5 should be read as
// "not decimated" rather than as a rate.
hold_run_length :: proc(x: []f32, stride: int) -> (length: int, confidence: f64) {
	if len(x) < 64 || stride <= 0 {
		return 0, 0
	}

	// Runs longer than this are treated as silence or a stuck signal rather than
	// as a sample-and-hold step.
	MAX_RUN :: 4096
	histogram: [MAX_RUN + 1]int

	run := 1
	total := 0
	for i := stride; i < len(x); i += stride {
		if x[i] == x[i - stride] {
			run += 1
			continue
		}
		if run <= MAX_RUN {
			histogram[run] += 1
			total += run
		}
		run = 1
	}
	if total == 0 {
		return 0, 0
	}

	best, best_samples := 0, 0
	for r in 1 ..= MAX_RUN {
		samples := histogram[r] * r
		if samples > best_samples {
			best_samples = samples
			best = r
		}
	}
	return best, f64(best_samples) / f64(total)
}

// How many distinct sample values the signal takes, counted up to `limit`.
//
// A quantiser to n bits can only emit 2^n levels, so this is the depth read
// directly. Returns `limit` when the count reaches it, which means "not
// quantised, or too finely to matter".
distinct_levels :: proc(x: []f32, limit: int, allocator := context.allocator) -> int {
	if len(x) == 0 || limit <= 0 {
		return 0
	}
	seen := make(map[f32]bool, limit * 2, allocator)
	defer delete(seen)
	for v in x {
		if len(seen) >= limit {
			return limit
		}
		seen[v] = true
	}
	return len(seen)
}

// ------------------------------------------------------------ relative pitch

// How far our render is detuned from the reference's, in cents.
//
// This replaced a reading that took each render's loudest bin as its pitch and
// compared the two. That is a fine way to find the brightest partial and a bad way
// to measure tuning, and the difference is not academic: it reported eight bank
// patches as exactly an octave out when every one of them carried the same harmonic
// series at the same frequencies in both renders. On one of them a **3.5 dB**
// difference in the balance between the first two harmonics was enough to flip
// which was loudest, and so to flip the reported pitch by an octave.
//
// The method here cannot make that mistake because it never picks a partial. If our
// spectrum is the reference's shifted along a log-frequency axis, then the shift
// that best aligns the two *is* the detuning, whatever the relative heights of the
// partials are. Resampling both spectra onto a log-frequency grid turns a frequency
// ratio into a translation, and a cross-correlation finds it.
//
// `confidence` is the normalised correlation at the winning shift. A low value
// means the two spectra do not resemble each other under any shift, which is a
// statement about timbre rather than tuning, and the caller should not report a
// detuning from it.

// Steps per octave on the log-frequency grid: 25 cents each.
PITCH_STEPS_PER_OCTAVE :: 48
// How far to search, in steps. 60 covers an octave and a quarter either way, so a
// genuine octave error is inside the range rather than at its edge.
PITCH_MAX_SHIFT :: 60
// The grid's span. Starts above the lowest analysis band so that a downward shift
// has somewhere to come from.
PITCH_LO_HZ :: 40.0
PITCH_HI_HZ :: 12000.0

// Power at an arbitrary frequency, taking the strongest bin within half a step so
// a partial that falls between grid points is not missed.
power_at_hz :: proc(power: []f64, bin_hz, hz: f64) -> f64 {
	if len(power) == 0 || bin_hz <= 0 || hz <= 0 {
		return 0
	}
	// Half a grid step either side, in bins.
	half := hz * (math.pow(2.0, 0.5 / f64(PITCH_STEPS_PER_OCTAVE)) - 1.0)
	lo := int((hz - half) / bin_hz)
	hi := int((hz + half) / bin_hz) + 1
	best := 0.0
	for k in max(lo, 1) ..= min(hi, len(power) - 1) {
		if power[k] > best {best = power[k]}
	}
	return best
}

// Resample a power spectrum onto the log-frequency grid, in dB, mean-subtracted.
log_frequency_profile :: proc(power: []f64, bin_hz: f64, allocator := context.allocator) -> []f64 {
	steps := int(math.log2(f64(PITCH_HI_HZ) / f64(PITCH_LO_HZ)) * f64(PITCH_STEPS_PER_OCTAVE))
	if steps <= 2 * PITCH_MAX_SHIFT {
		return nil
	}
	profile := make([]f64, steps, allocator)

	for i in 0 ..< steps {
		hz := PITCH_LO_HZ * math.pow(2.0, f64(i) / f64(PITCH_STEPS_PER_OCTAVE))
		profile[i] = power_db(power_at_hz(power, bin_hz, hz))
		// Clamped from below so that empty regions of the spectrum contribute a
		// constant rather than an arbitrarily large negative number, which would
		// otherwise dominate the correlation.
		if profile[i] < SPECTRUM_FLOOR_DB {
			profile[i] = SPECTRUM_FLOOR_DB
		}
	}

	// Whiten: subtract a moving average taken over an octave, which is a high pass
	// along the log-frequency axis. What is left is where the partials are, with the
	// overall spectral slope removed.
	//
	// This is not a refinement, it is the step that makes the metric measure tuning
	// at all. Without it the correlation is dominated by the slope: our renders are
	// darker than the reference's, so a *downward* shift lines our roll-off up with
	// theirs and scores better than no shift. On two in-tune bank patches the curve
	// fell monotonically from -1200 through 0 -- 0.777, 0.705, 0.654 on one of them
	// -- so the reading was reporting the tilt and calling it an octave of detuning.
	// After whitening, only the positions of the partials can move the score.
	WHITEN_HALF_WIDTH :: PITCH_STEPS_PER_OCTAVE / 2
	smooth := make([]f64, steps, context.temp_allocator)
	for i in 0 ..< steps {
		sum, count := 0.0, 0
		for j in max(i - WHITEN_HALF_WIDTH, 0) ..= min(i + WHITEN_HALF_WIDTH, steps - 1) {
			sum += profile[j]
			count += 1
		}
		smooth[i] = sum / f64(count)
	}
	for i in 0 ..< steps {
		profile[i] -= smooth[i]
	}
	return profile
}

// The whole correlation curve, so the caller can see the competing peaks rather
// than only the winner. Indexed by shift + PITCH_MAX_SHIFT.
pitch_shift_scores :: proc(
	ref_power, our_power: []f64,
	bin_hz: f64,
	allocator := context.allocator,
) -> []f64 {
	ref := log_frequency_profile(ref_power, bin_hz)
	defer delete(ref)
	our := log_frequency_profile(our_power, bin_hz)
	defer delete(our)
	if ref == nil || our == nil {
		return nil
	}

	steps := len(ref)
	scores := make([]f64, 2 * PITCH_MAX_SHIFT + 1, allocator)
	for i in 0 ..< len(scores) {
		scores[i] = -2.0
	}
	for s in -PITCH_MAX_SHIFT ..= PITCH_MAX_SHIFT {
		// Overlap only, so a shift is not rewarded for running off the end.
		lo := max(0, -s)
		hi := min(steps, steps - s)
		if hi - lo < steps / 2 {
			continue
		}

		sum, norm_a, norm_b := 0.0, 0.0, 0.0
		for i in lo ..< hi {
			a := ref[i]
			b := our[i + s]
			sum += a * b
			norm_a += a * a
			norm_b += b * b
		}
		if norm_a <= 0 || norm_b <= 0 {
			continue
		}

		scores[s + PITCH_MAX_SHIFT] = sum / math.sqrt(norm_a * norm_b)
	}
	return scores
}

// How far our render sits from the reference's, in cents.
pitch_shift_cents :: proc(
	ref_power, our_power: []f64,
	bin_hz: f64,
) -> (
	cents: f64,
	confidence: f64,
) {
	scores := pitch_shift_scores(ref_power, our_power, bin_hz)
	defer delete(scores)
	if scores == nil {
		return 0, 0
	}

	// A harmonic series correlates well with itself shifted by an octave -- its
	// partials 2, 4, 6 land on 1, 2, 3 -- so the curve has near-equal peaks at 0 and
	// at plus and minus 1200 cents, and which one wins is decided by exactly the
	// amplitude balance this metric is supposed to be blind to. This is the same
	// ambiguity that defeated the loudest-bin reading, in a different guise.
	//
	// Resolved by penalising distance from zero, so an octave has to be genuinely
	// better to be reported rather than merely tied. The penalty is set from measured
	// curves: on bank patches that are in tune, zero shift trails the spurious octave
	// peak by well under this, and a real octave error beats it by much more.
	best_index := -1
	for i in 0 ..< len(scores) {
		if scores[i] < -1.0 {continue}
		penalised := scores[i] - pitch_zero_bias(i)
		if best_index < 0 || penalised > scores[best_index] - pitch_zero_bias(best_index) {
			best_index = i
		}
	}
	if best_index < 0 {
		return 0, 0
	}

	// Parabolic interpolation, so the answer is not quantised to 25 cents.
	offset := 0.0
	if best_index > 0 && best_index < len(scores) - 1 {
		a := scores[best_index - 1]
		b := scores[best_index]
		c := scores[best_index + 1]
		denom := a - 2.0 * b + c
		if abs(denom) > 1.0e-12 {
			offset = clamp(0.5 * (a - c) / denom, -1.0, 1.0)
		}
	}

	// Require the winning peak to stand clear of any rival more than half an octave
	// away. Absolute correlation alone is not enough to trust a reading: patch 091
	// scored 0.72 at +700 cents with 0.62 at -700 and -0.30 at zero, which is not a
	// tuning measurement, it is two bad alignments of two spectra that do not match.
	// Both were wrong -- the patch is exactly in tune and its timbre is what differs.
	HALF_OCTAVE :: PITCH_STEPS_PER_OCTAVE / 2
	rival := -2.0
	for i in 0 ..< len(scores) {
		if scores[i] < -1.0 {continue}
		if abs(i - best_index) < HALF_OCTAVE {continue}
		if scores[i] > rival {rival = scores[i]}
	}
	margin := rival > -2.0 ? scores[best_index] - rival : scores[best_index]

	shift := f64(best_index - PITCH_MAX_SHIFT) + offset
	// The confidence returned is the smaller of the two tests, so a caller applying
	// one threshold gets both guarantees.
	return shift * 1200.0 / f64(PITCH_STEPS_PER_OCTAVE), min(scores[best_index], margin)
}

// Below this correlation the log-frequency alignment is not reporting a tuning
// difference, it is reporting that the two spectra share no partial structure under
// any shift.
//
// Set low deliberately. Whitening removes the shared spectral envelope, which is
// most of the correlated energy, so absolute values fall: bank patches that are
// exactly in tune score between 0.32 and 0.94 after it. A threshold picked for the
// un-whitened curve would exclude most of the bank.
PITCH_CONFIDENCE_MIN :: 0.25

// The penalty applied to a candidate shift, in correlation units, for being far
// from zero. Chosen from the measured curves rather than assumed -- see the note
// in `pitch_shift_cents`.
PITCH_ZERO_BIAS_PER_OCTAVE :: 0.10

pitch_zero_bias :: proc(index: int) -> f64 {
	octaves := abs(f64(index - PITCH_MAX_SHIFT)) / f64(PITCH_STEPS_PER_OCTAVE)
	return PITCH_ZERO_BIAS_PER_OCTAVE * octaves
}
