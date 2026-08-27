package s1probe

// The phaser's sweep rate, measured where a spectrum cannot follow it.
//
// The rate law is fitted from ctl2 48 to 112 and extrapolated above that, and the
// top of the knob is where the phaser's remaining error lives. It cannot be
// checked with either instrument that already exists, and both fail the same way:
// they need a spectrum, and resolving a 16 Hz comb takes a 341 ms window, which
// at ctl2 127 is longer than the whole sweep period. Tracking the resonance's
// trajectory returns 15.56 Hz there and autocorrelating the spectrogram returns
// 5.21, against a law that says 18.6 -- three numbers, no agreement.
//
// A rate does not need a spectrum. Hold one tone inside the swept band and its
// amplitude rises and falls once per sweep, and an amplitude envelope can be
// sampled as finely as you like: at 2 kHz, four periods is two milliseconds, so a
// 64 ms sweep is thirty points rather than a fifth of one window.
//
// The first phaser instrument in this project was a held tone and it failed. It
// counted how often the level crossed its own mean, and with several features
// sweeping there are several crossings per cycle, so the count moved with the
// feature count and the sweep range as much as with the rate. Counting is the
// part that was wrong, not the tone. **Autocorrelating** the envelope needs no
// feature to be identified and does not care how many dips there are per cycle:
// whatever shape the envelope has, it repeats once per sweep, and the lag where
// it best matches itself is the period.
//
// Two guards, both learned from the instrument that measured the rate at the
// slower settings:
//
//   * autocorrelation has an octave error, since a signal with period P also
//     matches itself at 2P. The earliest strong maximum is taken, not the tallest.
//   * when the true period is longer than the search, correlation falls away
//     from the first lag examined and the maximum lands on the search's own lower
//     bound, which reads as a confident answer. A result at either bound is
//     reported as unresolvable instead.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

// The envelope is sampled at four periods of the probe tone or one millisecond,
// whichever is longer. Short enough to hold thirty points inside the fastest
// sweep the law predicts.
PHASER_RATE_MIN_FRAME_MS :: 1.0
PHASER_RATE_TONE_PERIODS :: 4.0

// A sweep has to repeat this many times inside the render before a period is
// believed. Below it the answer is a fit to one and a bit cycles.
PHASER_RATE_MIN_CYCLES :: 3.0

// How far down from the strongest correlation still counts as a real maximum,
// which is what lets the earliest one win over the tallest.
PHASER_RATE_ACCEPT :: 0.72

// How far the correlation must fall before a maximum counts as a period rather
// than as the tail of the correlation's own start.
PHASER_RATE_TROUGH :: 0.4

phaser_rate_envelope :: proc(off, on: []f32, frame: int) -> []f64 {
	mo, so := split_mid_side(off, 2)
	defer delete(mo)
	defer delete(so)
	mn, sn := split_mid_side(on, 2)
	defer delete(mn)
	defer delete(sn)

	held := min(g_hold_frames, min(len(mo), len(mn)))
	if held < frame * 8 {
		return nil
	}
	a := frame_envelope(mo[:held], frame)
	defer delete(a)
	b := frame_envelope(mn[:held], frame)
	defer delete(b)

	n := min(len(a), len(b))
	// The unit on over the unit off, so the note's own envelope divides out and
	// what is left is the sweep.
	out := make([dynamic]f64, 0, n)
	for i in 0 ..< n {
		if a[i] > 0 && b[i] > 0 {
			append(&out, amplitude_db(b[i] / a[i]))
		}
	}
	return out[:]
}

// The period of a periodic envelope, in frames, or zero when it cannot be read.
phaser_rate_period :: proc(env: []f64, min_lag, max_lag: int) -> (lag: int, r: f64) {
	if len(env) < 8 || max_lag <= min_lag {
		return 0, 0
	}
	mean := 0.0
	for v in env {
		mean += v
	}
	mean /= f64(len(env))

	energy := 0.0
	for v in env {
		d := v - mean
		energy += d * d
	}
	if energy <= 0 {
		return 0, 0
	}

	hi := min(max_lag, len(env) - 4)
	if hi <= min_lag {
		return 0, 0
	}
	corr := make([]f64, hi + 1)
	defer delete(corr)
	for l in min_lag ..= hi {
		s := 0.0
		for i in 0 ..< len(env) - l {
			s += (env[i] - mean) * (env[i + l] - mean)
		}
		corr[l] = s / energy
	}

	best := 0.0
	for l in min_lag ..= hi {
		if corr[l] > best {best = corr[l]}
	}
	if best <= 0 {
		return 0, 0
	}
	// A slowly varying envelope correlates with itself at every short lag, so the
	// correlation leaves the first lag near one and decays; its first local
	// maximum is then the search's own starting point rather than a period. This
	// caught the guard below out -- it tests the bounds, but the scan can only
	// return min_lag + 1, which is one inside them, so a monotone decay came back
	// as a confident 200 Hz at every rate slower than 1 Hz.
	//
	// The fix is to require the correlation to fall away first. A real period is a
	// maximum that follows a trough, so the scan starts only once the correlation
	// has dropped well below where it began.
	fell := false
	start := corr[min_lag]
	for l in min_lag + 1 ..< hi {
		if !fell {
			if corr[l] < start * PHASER_RATE_TROUGH && corr[l] < PHASER_RATE_TROUGH {
				fell = true
			}
			continue
		}
		if corr[l] >= corr[l - 1] && corr[l] >= corr[l + 1] && corr[l] >= best * PHASER_RATE_ACCEPT {
			return l, corr[l]
		}
	}
	return 0, 0
}

cmd_phaserrate :: proc(
	dll: string,
	type_state, ctl1, level, note, gain: int,
	values: []int,
	seconds: f64,
	csv_path: string,
	block: int = COMPARE_BLOCK_DEFAULT,
	envelope_path: string = "",
) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(block)
	held := (int(seconds * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	hz := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	frame_ms := max(PHASER_RATE_MIN_FRAME_MS, PHASER_RATE_TONE_PERIODS * 1000.0 / hz)
	frame := max(1, int(frame_ms * f64(SAMPLE_RATE) / 1000.0))

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"phaser sweep rate: %s (state %d) ctl1=%d level=%d, tone at %.0f Hz, %.1f s, %d-frame blocks",
		name,
		type_state,
		ctl1,
		level,
		hz,
		seconds,
		g_block,
	)
	fmt.printfln("  envelope sampled every %.2f ms; the law is 0.0226 * 2^(9.685 * ctl2/127)", frame_ms)
	fmt.println("  ctl2     law      reference        ours")

	rows := make([dynamic][4]f64, 0, len(values))
	defer delete(rows)

	for ctl2 in values {
		p_off := fx_probe_patch(false, type_state, ctl1, ctl2, level)
		p_on := fx_probe_patch(true, type_state, ctl1, ctl2, level)
		set_param(&p_off, 29, gain)
		set_param(&p_on, 29, gain)

		ref_off, _, ok1 := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
		defer delete(ref_off)
		ref_on, _, ok2 := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
		defer delete(ref_on)
		if !ok1 || !ok2 {
			continue
		}
		ours_off := render_ours(p_off, note)
		defer delete(ours_off)
		ours_on := render_ours(p_on, note)
		defer delete(ours_on)

		ref_env := phaser_rate_envelope(ref_off, ref_on, frame)
		defer delete(ref_env)
		our_env := phaser_rate_envelope(ours_off, ours_on, frame)
		defer delete(our_env)

		// The search runs from a lag that still holds several envelope points to
		// one that still fits the required number of cycles into the render.
		min_lag := 4
		max_lag := int(f64(len(ref_env)) / PHASER_RATE_MIN_CYCLES)

		read :: proc(env: []f64, min_lag, max_lag: int, frame_ms: f64) -> (rate, r: f64) {
			lag, c := phaser_rate_period(env, min_lag, max_lag)
			if lag <= min_lag || lag >= max_lag {
				return 0, c
			}
			return 1000.0 / (f64(lag) * frame_ms), c
		}
		if envelope_path != "" && len(values) == 1 {
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			fmt.sbprintln(&b, "ms,reference_db,ours_db")
			n := min(len(ref_env), len(our_env))
			for i in 0 ..< n {
				fmt.sbprintfln(&b, "%.4f,%.6f,%.6f", f64(i) * frame_ms, ref_env[i], our_env[i])
			}
			if os.write_entire_file(envelope_path, transmute([]u8)strings.to_string(b)) == nil {
				fmt.printfln("  wrote %s", envelope_path)
			}
		}

		ref_rate, ref_r := read(ref_env, min_lag, max_lag, frame_ms)
		our_rate, our_r := read(our_env, min_lag, max_lag, frame_ms)

		law := 0.0226 * math.pow(2.0, 9.685 * f64(ctl2) / 127.0)
		append(&rows, [4]f64{f64(ctl2), law, ref_rate, our_rate})

		show :: proc(rate, r: f64) -> string {
			if rate <= 0 {
				return "  unresolvable"
			}
			return fmt.tprintf("%s Hz r=%.2f", pad_left(dec2(rate), 6), r)
		}
		fmt.printfln(
			"  %s  %s   %s   %s",
			pad_left(fmt.tprintf("%d", ctl2), 4),
			pad_left(dec2(law), 6),
			pad_left(show(ref_rate, ref_r), 18),
			pad_left(show(our_rate, our_r), 18),
		)
	}

	if csv_path != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintln(&b, "ctl2,law_hz,reference_hz,ours_hz")
		for r in rows {
			fmt.sbprintfln(&b, "%.0f,%.6f,%.6f,%.6f", r[0], r[1], r[2], r[3])
		}
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("phaserrate: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}
