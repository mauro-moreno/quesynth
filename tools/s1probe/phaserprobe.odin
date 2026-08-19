package s1probe

// The four phasers, measured with an instrument that suits them.
//
// The first attempt used the same held sine as everything else in effectprobe and
// counted how often the level crossed its own mean. That instrument cannot work
// here, and its failure was not subtle: it reported 47 Hz, 6.67, 1.33, 3.67 and
// 15.33 Hz for five settings of one control, which is not a rate curve. The reason
// is structural. A single tone samples the transfer function at exactly one
// frequency, so all it can report is "a notch went past" -- and with N notches
// sweeping there are N dips per LFO cycle, which means the count moves with the
// notch *count* and the sweep *range* as much as with the rate.
//
// What is needed instead is the whole transfer function, repeatedly, over time.
// The probe here drives a **saw wave** through the unit:
//
//   * a saw is a dense harmonic comb, so one render samples the transfer function
//     at every multiple of the fundamental at once -- 40 probe frequencies from
//     131 Hz to 5.2 kHz -- and every notch is visible in every frame rather than
//     only when it happens to cross one tone
//   * a saw is deterministic, unlike noise. Dividing the harmonic magnitudes by
//     the same patch with the unit switched off gives the transfer function
//     directly, with no averaging needed to beat down a stochastic input. A noise
//     probe would need many cycles averaged per LFO phase, and the phase is not
//     known
//   * magnitudes are phase-blind, so the oscillator's own free-running start phase
//     differing between the two renders does not matter
//
// From that, three things fall out that the sine could not give: how many notches
// each type sweeps, the band they sweep across in hertz, and the rate -- taken
// from the periodicity of the notch *trajectory*, which is one cycle per LFO
// cycle regardless of how many notches there are.

import "core:fmt"
import "core:math"
import "core:os"
import cpatch "../../src/patch"

// A 2048-point window is 43 ms at 48 kHz: about a sixth of the ~277 ms sweep
// period seen earlier, so a notch moves little within one window, and its 23.4 Hz
// bins still separate harmonics 131 Hz apart by five and a half bins.
PHASER_FFT :: 2048
PHASER_HOP :: 512

// How many harmonics of the fundamental to use as probe frequencies. Eighty
// reaches 10.5 kHz. Forty was tried first and was not enough: the resonance
// sweeps past 5 kHz, so the reading clipped against the top of the window and
// the swept band came back narrower than the numbers underneath it showed.
PHASER_HARMONICS :: 80

// A dip this far below the unprocessed spectrum counts as a notch.
PHASER_NOTCH_DB :: -6.0

// And it has to stand this far clear of both neighbours to count.
//
// Without a prominence test the count is meaningless: inside a broad plateau that
// is already below the threshold, every small ripple is a local minimum, and the
// first version of this reported anywhere from 1 to 13 notches in adjacent frames
// of a response that has no comb in it at all.
PHASER_PROMINENCE_DB :: 3.0

// A saw and nothing else.
//
// The drive is deliberately lower than effectprobe's: a phaser is a linear filter
// and the point here is to measure it as one, so there is headroom rather than the
// full-scale level that made the earlier sine readings show harmonic distortion.
phaser_probe_patch :: proc(on: bool, type_state, ctl1, ctl2, level, gain: int) -> cpatch.Patch {
	p := fx_probe_patch(on, type_state, ctl1, ctl2, level)
	set_param(&p, 0, 1) // oscillator 1: saw
	// The drive is a flag rather than a constant, and the default is well below
	// full scale. The reference turned out to put a resonance of nearly +20 dB on
	// this signal, so at the gain effectprobe uses the output would be far past
	// full scale and any clipping would land in the harmonic magnitudes as a
	// transfer function that is not the filter's. Two drives can then be compared
	// to check that what is being measured is linear at all.
	set_param(&p, 29, gain)
	return p
}

// Harmonic magnitudes of one window, in power.
phaser_window_harmonics :: proc(
	x: []f32,
	from: int,
	f0: f64,
	re, im, power: []f64,
	out: []f64,
) -> bool {
	if from < 0 || from + PHASER_FFT > len(x) {
		return false
	}
	for i in 0 ..< PHASER_FFT {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(PHASER_FFT)))
		re[i] = f64(x[from + i]) * w
		im[i] = 0
	}
	fft_forward(re, im)
	for k in 0 ..< len(power) {
		power[k] = re[k] * re[k] + im[k] * im[k]
	}

	bin_hz := f64(SAMPLE_RATE) / f64(PHASER_FFT)
	for h in 0 ..< len(out) {
		hz := f64(h + 1) * f0
		centre := int(hz / bin_hz + 0.5)
		// The peak within a bin either side, so leakage from a harmonic that does
		// not land exactly on a bin is not read as a notch.
		best := 0.0
		for b in max(centre - 1, 0) ..= min(centre + 1, len(power) - 1) {
			if power[b] > best {best = power[b]}
		}
		out[h] = best
	}
	return true
}

// The mono sum of an interleaved render, over the held portion.
phaser_mono :: proc(audio: []f32) -> []f32 {
	held := min(g_hold_frames, len(audio) / 2)
	mono := make([]f32, held)
	for i in 0 ..< held {
		mono[i] = 0.5 * (audio[i * 2] + audio[i * 2 + 1])
	}
	return mono
}

// A peak this far above the unprocessed spectrum counts as a resonance.
PHASER_PEAK_DB :: 4.0

Phaser_Frame :: struct {
	// Transfer function in dB at each harmonic.
	transfer:    [PHASER_HARMONICS]f64,
	// How many separate notches, and how many separate peaks, are visible.
	notches:     int,
	peaks:       int,
	// The deepest notch and the highest peak, interpolated between harmonics.
	deepest_hz:  f64,
	deepest_db:  f64,
	highest_hz:  f64,
	highest_db:  f64,
	// Where the response is strongest and weakest, from a smoothed copy of the
	// curve. Unlike the two above these are always defined, which is what makes
	// them usable as a trajectory to take a rate from.
	//
	// Needed because the reference's resonance is broad: its summit has only one or
	// two dB of prominence over the neighbouring harmonics, so a sharp-extremum
	// test finds it in a handful of frames out of 138 and misses the sweep
	// entirely. For a broad feature the argument of the maximum is the right
	// descriptor and prominence is the wrong test.
	strongest_hz: f64,
	strongest_db: f64,
	weakest_hz:   f64,
}

// Where a feature sits between three harmonics, by parabolic interpolation, so
// the frequency is not quantised to the comb spacing.
phaser_interpolate :: proc(a, b, c: f64, h: int, f0: f64) -> f64 {
	denom := a - 2.0 * b + c
	offset := 0.0
	if abs(denom) > 1.0e-9 {
		offset = clamp(0.5 * (a - c) / denom, -1.0, 1.0)
	}
	return (f64(h + 1) + offset) * f0
}

// Locate both the notches and the peaks in one frame.
//
// Peaks are looked for as well as notches because the reference turned out not to
// produce a comb of notches at all. The response is a single broad *resonance*
// that sweeps, so a notch-only instrument reports nothing and then a rate of zero,
// which is a null result about the measurement rather than about the plugin.
phaser_analyse_frame :: proc(frame: ^Phaser_Frame, f0: f64) {
	frame.notches = 0
	frame.peaks = 0
	frame.deepest_hz, frame.deepest_db = 0, 0
	frame.highest_hz, frame.highest_db = 0, 0

	for h in 1 ..< PHASER_HARMONICS - 1 {
		db := frame.transfer[h]
		lo := frame.transfer[h - 1]
		hi := frame.transfer[h + 1]

		if db <= PHASER_NOTCH_DB && db <= lo && db <= hi {
			// Prominent enough that ripple inside a broad dip is not counted.
			if lo - db >= PHASER_PROMINENCE_DB && hi - db >= PHASER_PROMINENCE_DB {
				frame.notches += 1
				if db < frame.deepest_db {
					frame.deepest_db = db
					frame.deepest_hz = phaser_interpolate(lo, db, hi, h, f0)
				}
			}
		}

		if db >= PHASER_PEAK_DB && db >= lo && db >= hi {
			if db - lo >= PHASER_PROMINENCE_DB && db - hi >= PHASER_PROMINENCE_DB {
				frame.peaks += 1
				if db > frame.highest_db {
					frame.highest_db = db
					frame.highest_hz = phaser_interpolate(lo, db, hi, h, f0)
				}
			}
		}
	}

	// Smooth over five harmonics, then take the extremes of that. Five is about
	// 650 Hz here, narrower than the resonance and wide enough to remove the
	// harmonic-to-harmonic ripple that defeats a prominence test.
	smooth: [PHASER_HARMONICS]f64
	SMOOTH :: 2
	for h in 0 ..< PHASER_HARMONICS {
		sum, count := 0.0, 0
		for j in max(h - SMOOTH, 0) ..= min(h + SMOOTH, PHASER_HARMONICS - 1) {
			sum += frame.transfer[j]
			count += 1
		}
		smooth[h] = sum / f64(count)
	}

	best, worst := 0, 0
	for h in 1 ..< PHASER_HARMONICS {
		if smooth[h] > smooth[best] {best = h}
		if smooth[h] < smooth[worst] {worst = h}
	}
	frame.strongest_db = smooth[best]
	frame.strongest_hz =
		best > 0 && best < PHASER_HARMONICS - 1 \
		? phaser_interpolate(smooth[best - 1], smooth[best], smooth[best + 1], best, f0) \
		: f64(best + 1) * f0
	frame.weakest_hz =
		worst > 0 && worst < PHASER_HARMONICS - 1 \
		? phaser_interpolate(smooth[worst - 1], smooth[worst], smooth[worst + 1], worst, f0) \
		: f64(worst + 1) * f0
}

// The sweep period, from the autocorrelation of the whole spectrogram.
//
// This is the third instrument tried for the rate and the first that works, and
// the progression is worth keeping because each failure was informative.
//
// Counting level crossings of a held sine failed because one tone samples the
// transfer function at one frequency. Tracking the resonance's own trajectory
// failed differently: the resonance sweeps out of the analysis window at both
// ends, so the trajectory saturates into a plateau, and where two maxima compete
// the argument of the maximum jumps between them -- which read 7.47 Hz where the
// numbers underneath plainly showed a 277 ms period.
//
// Autocorrelating the full frame-by-frame transfer function needs no feature to be
// identified at all. Whatever the response is doing, it returns to the same shape
// once per LFO cycle, so the lag at which the spectrogram best matches itself *is*
// the period. Every harmonic contributes, so a resonance leaving the window at the
// top costs a little correlation rather than corrupting a tracked point.
phaser_period_frames :: proc(frames: []Phaser_Frame) -> (lag: int, correlation: f64) {
	if len(frames) < 8 {
		return 0, 0
	}

	// Mean-subtract each harmonic across time, so a fixed spectral tilt -- which is
	// the same in every frame -- cannot dominate the correlation and make every lag
	// look equally good.
	n := len(frames)
	centred := make([][PHASER_HARMONICS]f64, n)
	defer delete(centred)
	for h in 0 ..< PHASER_HARMONICS {
		mean := 0.0
		for t in 0 ..< n {
			mean += frames[t].transfer[h]
		}
		mean /= f64(n)
		for t in 0 ..< n {
			centred[t][h] = frames[t].transfer[h] - mean
		}
	}

	energy := 0.0
	for t in 0 ..< n {
		for h in 0 ..< PHASER_HARMONICS {
			energy += centred[t][h] * centred[t][h]
		}
	}
	if energy <= 0 {
		return 0, 0
	}

	// Two full windows. Adjacent frames overlap by three quarters of a window, so
	// they correlate strongly whatever the sweep is doing, and a period shorter than
	// the window itself is being integrated away rather than measured. Four hops --
	// one window -- was tried and let a 54 ms sweep report as its own subharmonic;
	// eight refuses to answer there instead, which is the better failure.
	MIN_LAG :: 8
	limit := n / 2
	r := make([]f64, limit)
	defer delete(r)

	best_lag, best := 0, -2.0
	for l in MIN_LAG ..< limit {
		sum, norm_a, norm_b := 0.0, 0.0, 0.0
		for t in 0 ..< n - l {
			for h in 0 ..< PHASER_HARMONICS {
				a := centred[t][h]
				b := centred[t + l][h]
				sum += a * b
				norm_a += a * a
				norm_b += b * b
			}
		}
		if norm_a <= 0 || norm_b <= 0 {continue}
		r[l] = sum / math.sqrt(norm_a * norm_b)
		if r[l] > best {
			best = r[l]
			best_lag = l
		}
	}
	if best_lag == 0 {
		return 0, 0
	}

	// Only a genuine interior local maximum counts as a period.
	//
	// Without this the reading is wrong in a specific and misleading way. When the
	// true period is longer than the search can reach, the correlation simply falls
	// away from the first lag examined, so the maximum lands on `MIN_LAG` itself --
	// and MIN_LAG is four hops, which is one window, which is 43 ms. Every spurious
	// "43 ms period" this probe produced was the search reporting its own lower
	// bound with a correlation of 0.99, which reads exactly like a confident answer.
	best_local, best_local_lag := -2.0, 0
	for l in MIN_LAG + 1 ..< limit - 1 {
		if r[l] <= r[l - 1] || r[l] < r[l + 1] {continue}
		if r[l] > best_local {
			best_local = r[l]
			best_local_lag = l
		}
	}
	if best_local_lag == 0 {
		return 0, 0
	}

	// Then prefer the earliest local maximum that is nearly as good.
	//
	// A signal with period P also correlates well at 2P, 3P and so on, so taking
	// the strongest peak picks a multiple of the true period whenever the later one
	// scores marginally higher. That is exactly what happened here: three of the
	// four phaser types reported 277 ms and the fourth reported 555 ms -- twice the
	// period -- at a *lower* correlation than the other three, which is the
	// signature of the error rather than of a genuinely slower sweep.
	SUBMULTIPLE_TOLERANCE :: 0.9
	for l in MIN_LAG + 1 ..< best_local_lag {
		if r[l] <= r[l - 1] || r[l] < r[l + 1] {continue}
		if r[l] >= best_local * SUBMULTIPLE_TOLERANCE {
			return l, r[l]
		}
	}
	return best_local_lag, best_local
}

// One character per harmonic, so a sweeping notch is visible as a diagonal.
phaser_glyph :: proc(db: f64) -> string {
	switch {
	case db < -24:
		return "#"
	case db < -15:
		return "="
	case db < -6:
		return "-"
	case db < -2:
		return "."
	case db > 4:
		return "^"
	}
	return " "
}

// `seconds` is a parameter and the default is long. The 1.5 s render the rest of
// effectprobe uses cannot time this section at all: autocorrelation reaches half
// the render, so 1.5 s bottoms out at 1.36 Hz, and the phasers sweep slower than
// that over much of their range. Readings of 43 ms -- this probe's own window
// length -- were the search failing on periods it could not represent.
cmd_phaserprobe :: proc(
	dll: string,
	type_state, ctl1, ctl2, level, gain: int,
	seconds: f64,
	frames_shown: int,
) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"

	off_patch := phaser_probe_patch(false, type_state, ctl1, ctl2, level, gain)
	off := probe_render(dll, &off_patch, pristine, work, g_fx_note, seconds, &dumped, nil)
	defer delete(off)
	on_patch := phaser_probe_patch(true, type_state, ctl1, ctl2, level, gain)
	on := probe_render(dll, &on_patch, pristine, work, g_fx_note, seconds, &dumped, nil)
	defer delete(on)
	if off == nil || on == nil {
		fmt.eprintln("phaserprobe: no audio")
		os.exit(1)
	}

	off_mono := phaser_mono(off)
	defer delete(off_mono)
	on_mono := phaser_mono(on)
	defer delete(on_mono)

	re := make([]f64, PHASER_FFT)
	defer delete(re)
	im := make([]f64, PHASER_FFT)
	defer delete(im)
	power := make([]f64, PHASER_FFT / 2 + 1)
	defer delete(power)
	off_h := make([]f64, PHASER_HARMONICS)
	defer delete(off_h)
	on_h := make([]f64, PHASER_HARMONICS)
	defer delete(on_h)

	// The unprocessed comb, averaged over the whole held note. A saw is stationary
	// so one average is a better denominator than a per-frame one, which would
	// carry its own window noise into every reading.
	off_mean := make([]f64, PHASER_HARMONICS)
	defer delete(off_mean)
	off_count := 0
	for from := 0; from + PHASER_FFT <= len(off_mono); from += PHASER_HOP {
		if !phaser_window_harmonics(off_mono, from, g_fx_f0, re, im, power, off_h) {break}
		for h in 0 ..< PHASER_HARMONICS {
			off_mean[h] += off_h[h]
		}
		off_count += 1
	}
	if off_count == 0 {
		fmt.eprintln("phaserprobe: the render was too short to analyse")
		os.exit(1)
	}
	for h in 0 ..< PHASER_HARMONICS {
		off_mean[h] /= f64(off_count)
	}

	frames := make([dynamic]Phaser_Frame)
	defer delete(frames)
	for from := 0; from + PHASER_FFT <= len(on_mono); from += PHASER_HOP {
		if !phaser_window_harmonics(on_mono, from, g_fx_f0, re, im, power, on_h) {break}
		frame: Phaser_Frame
		for h in 0 ..< PHASER_HARMONICS {
			frame.transfer[h] = off_mean[h] > 0 ? power_db(on_h[h] / off_mean[h]) : 0
		}
		phaser_analyse_frame(&frame, g_fx_f0)
		append(&frames, frame)
	}

	frame_ms := 1000.0 * f64(PHASER_HOP) / f64(SAMPLE_RATE)
	fmt.printfln(
		"state %d (%s) ctl1=%d ctl2=%d level=%d: saw comb through the unit, %.1f ms per row",
		type_state,
		name,
		ctl1,
		ctl2,
		level,
		frame_ms,
	)
	fmt.printfln(
		"  columns are harmonics 1..%d of %.1f Hz, so %.0f Hz to %.0f Hz",
		PHASER_HARMONICS,
		g_fx_f0,
		g_fx_f0,
		g_fx_f0 * f64(PHASER_HARMONICS),
	)
	fmt.println("  glyphs: '#' below -24 dB, '=' below -15, '-' below -6, '.' below -2, '^' above +4")

	shown := min(frames_shown, len(frames))
	fmt.printf("     ms |")
	for h in 0 ..< PHASER_HARMONICS {
		fmt.printf("%s", (h + 1) % 10 == 0 ? "|" : "-")
	}
	fmt.println("| notches  resonance")
	for i in 0 ..< shown {
		f := &frames[i]
		fmt.printf("  %s |", pad_left(fmt.tprintf("%.0f", f64(i) * frame_ms), 5))
		for h in 0 ..< PHASER_HARMONICS {
			fmt.printf("%s", phaser_glyph(f.transfer[h]))
		}
		fmt.printfln(
			"|   %s   %s Hz  %s dB",
			pad_left(fmt.tprintf("%d", f.notches), 2),
			pad_left(dec0(f.strongest_hz), 6),
			pad_left(sdec1(f.strongest_db), 6),
		)
	}

	// The glyph map only sorts each harmonic into one of five buckets, which is
	// enough to see a shape move and not enough to say what the shape is. These are
	// the numbers behind it, every second harmonic, rounded to whole decibels.
	fmt.println()
	fmt.println("  transfer in dB, every 2nd harmonic (columns are 262 Hz apart):")
	fmt.printf("     ms |")
	for h := 1; h < PHASER_HARMONICS; h += 2 {
		fmt.printf("%s", pad_left(fmt.tprintf("%.0f", f64(h + 1) * g_fx_f0 / 100.0), 4))
	}
	fmt.println("   (x100 Hz)")
	step := max(shown / 12, 1)
	for i := 0; i < shown; i += step {
		f := &frames[i]
		fmt.printf("  %s |", pad_left(fmt.tprintf("%.0f", f64(i) * frame_ms), 5))
		for h := 1; h < PHASER_HARMONICS; h += 2 {
			fmt.printf("%s", pad_left(fmt.tprintf("%.0f", f.transfer[h]), 4))
		}
		fmt.println()
	}

	// ---- the summary readings ----

	// Notch count: the mode across frames where any notch was visible at all, so
	// the instant when every notch sits between two harmonics does not count as
	// zero.
	histogram: [PHASER_HARMONICS]int
	for f in frames {
		if f.notches > 0 && f.notches < PHASER_HARMONICS {
			histogram[f.notches] += 1
		}
	}
	modal_notches, modal_count := 0, 0
	for n in 1 ..< PHASER_HARMONICS {
		if histogram[n] > modal_count {
			modal_count = histogram[n]
			modal_notches = n
		}
	}

	// Peak count, the same way.
	peak_histogram: [PHASER_HARMONICS]int
	for f in frames {
		if f.peaks > 0 && f.peaks < PHASER_HARMONICS {
			peak_histogram[f.peaks] += 1
		}
	}
	modal_peaks, modal_peak_count := 0, 0
	for n in 1 ..< PHASER_HARMONICS {
		if peak_histogram[n] > modal_peak_count {
			modal_peak_count = peak_histogram[n]
			modal_peaks = n
		}
	}

	// The swept band, taken from the smoothed resonance, which is defined in every
	// frame rather than only where a sharp extremum happens to sit on a harmonic.
	feature :: proc(f: ^Phaser_Frame, peaks: bool) -> f64 {
		return f.strongest_hz
	}
	tracking_peaks := true
	lo, hi := 0.0, 0.0
	tracked := 0
	for i in 0 ..< len(frames) {
		hz := feature(&frames[i], tracking_peaks)
		if hz <= 0 {continue}
		if tracked == 0 || hz < lo {lo = hz}
		if tracked == 0 || hz > hi {hi = hz}
		tracked += 1
	}

	// The rate, from upward crossings of the notch trajectory's own mean.
	//
	// This is the reading the single tone could not give. The trajectory advances
	// once per LFO cycle whatever the notch count, so upward crossings count
	// cycles directly rather than counting dips.
	rate := 0.0
	crossings := 0
	if tracked > 4 {
		mean := 0.0
		for i in 0 ..< len(frames) {
			hz := feature(&frames[i], tracking_peaks)
			if hz > 0 {mean += math.log2(hz)}
		}
		mean /= f64(tracked)

		above := false
		started := false
		for i in 0 ..< len(frames) {
			hz := feature(&frames[i], tracking_peaks)
			if hz <= 0 {continue}
			now := math.log2(hz) > mean
			if started && now && !above {crossings += 1}
			above = now
			started = true
		}
		span_s := f64(len(frames)) * frame_ms / 1000.0
		if span_s > 0 {rate = f64(crossings) / span_s}
	}

	fmt.println()
	fmt.printfln("  notches sweeping   %d  (in %d of %d frames)", modal_notches, modal_count, len(frames))
	fmt.printfln("  peaks sweeping     %d  (in %d of %d frames)", modal_peaks, modal_peak_count, len(frames))
	if tracked > 0 {
		fmt.printfln(
			"  swept band         %.0f Hz .. %.0f Hz  (tracking the %s)",
			lo,
			hi,
			"smoothed resonance",
		)
	}
	fmt.printfln("  sweep rate         %.2f Hz  (%d cycles of the resonance trajectory)", rate, crossings)

	// And the same reading taken without identifying any feature at all.
	//
	// Reported only when something actually swept. With a static response the
	// autocorrelation has no signal to lock onto and returns a lag set by the
	// analysis rather than by the plugin -- the spurious readings this guard
	// suppresses were 43 ms and 53 ms, which are exactly this probe's own window
	// length and five times its hop.
	period_frames, correlation := phaser_period_frames(frames[:])
	swept_octaves := lo > 0 && hi > 0 ? math.log2(hi / lo) : 0
	MIN_SWEEP_OCTAVES :: 0.25
	if swept_octaves < MIN_SWEEP_OCTAVES {
		fmt.printfln(
			"  autocorrelation    no sweep to time (the band spans %.2f octaves, under %.2f)",
			swept_octaves,
			f64(MIN_SWEEP_OCTAVES),
		)
	} else if period_frames == 0 {
		fmt.println("  autocorrelation    no period resolvable in this render length")
	} else {
		period_ms := f64(period_frames) * frame_ms
		fmt.printfln(
			"  autocorrelation    %.2f Hz  (period %.0f ms, r = %.2f)",
			1000.0 / period_ms,
			period_ms,
			correlation,
		)
	}

	// Contrast: how far the response ranges within a single frame, averaged over
	// frames, against how much it moves between frames.
	//
	// This is what tells a sweep too fast to resolve from one too slow to see. Both
	// look static to a band measurement. But a sweep faster than the analysis window
	// is *integrated* by it, so each frame reads as a broad smear with little
	// contrast; a sweep slower than the whole render stays sharp inside every frame
	// and merely does not move. High contrast plus no movement means slow. Low
	// contrast means the window is averaging over the sweep, which means fast.
	within := 0.0
	for f in frames {
		fmin, fmax := f.transfer[0], f.transfer[0]
		for h in 0 ..< PHASER_HARMONICS {
			fmin = min(fmin, f.transfer[h])
			fmax = max(fmax, f.transfer[h])
		}
		within += fmax - fmin
	}
	within /= f64(len(frames))
	fmt.printfln("  within-frame range %.1f dB  (low means the window is averaging over the sweep)", within)
}
