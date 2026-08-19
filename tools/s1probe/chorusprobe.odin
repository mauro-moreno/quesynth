// s1probe chorusprobe - measure the chorus depth and level curves.
//
// The chorus went in with its timing read straight off the reference's displays
// -- delay in milliseconds, rate in hertz, feedback in percent -- but two of its
// knobs are bare 0..127 and had to be guessed: parameter 53's depth, read as a
// fraction of the centre delay, and parameter 56's level, read as the wet share.
// The null test says the guesses are too shy: this engine's stereo width sits
// 0.31 below the reference's, and its level slightly under, both of which is what
// too little wet signal looks like.
//
//   s1probe chorusprobe [dll] [--sweep level|depth] [--values <list|all>]
//                             [--rate <n>] [--delay <n>] [--dump]
//
// Both curves are measured off the *side* signal, L minus R.
//
// That is the trick that makes this tractable. The dry signal is centred, so it
// cancels in the side entirely and what is left there is only the chorus's own
// output -- no need to separate wet from dry by level, and no need to model how
// they sum. The level curve is then the side's amplitude against the mid's, and
// the depth curve is the *pitch* wobble of that side signal, which a swept delay
// tap produces and which converts back to a delay swing in closed form.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"
import sengine "../../src/engine"

// A sine, so the side signal's pitch is unambiguous to track, and a rate slow
// enough that an 85 ms analysis window sees a near-steady pitch.
CHORUS_PROBE_NOTE :: u8(72)
CHORUS_PROBE_SECONDS :: 4.0

// Which chorus type the probe selects, set by --type.
g_chorus_type := 1

chorus_probe_patch :: proc(depth, level, rate, delay_time, feedback: int, type: int = 1) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 110)

	set_param(&p, 65, 0) // delay off, so only the chorus is in the side signal
	set_param(&p, 66, 1) // chorus on
	// Parameter 64 is display-keyed with displays "1", "2" and "4", so the stored
	// value is the type number itself and 0 selects none of them.
	set_param(&p, 64, type)
	set_param(&p, 52, delay_time)
	set_param(&p, 53, depth)
	set_param(&p, 54, rate)
	set_param(&p, 55, feedback)
	set_param(&p, 56, level)
	return p
}

// The side signal, L minus R, per sample.
side_signal :: proc(audio: []f32) -> []f32 {
	frames := len(audio) / 2
	out := make([]f32, frames)
	for i in 0 ..< frames {
		out[i] = 0.5 * (audio[i * 2] - audio[i * 2 + 1])
	}
	return out
}

// Mid signal, for the level ratio.
mid_signal :: proc(audio: []f32) -> []f32 {
	frames := len(audio) / 2
	out := make([]f32, frames)
	for i in 0 ..< frames {
		out[i] = 0.5 * (audio[i * 2] + audio[i * 2 + 1])
	}
	return out
}

// Peak-to-peak pitch wobble of a signal, in cents.
// Also returns the rate at which the pitch itself oscillates, which is the
// chorus LFO's actual rate.
//
// Worth having because the swing conversion divides by a rate, and it had been
// dividing by the *displayed* one. At full depth against a 29.76 ms centre delay
// that produced a swing of 32.6 ms -- larger than the centre, so the delay would
// have to go negative. A reading that is physically impossible is a reading whose
// denominator is wrong, and this measures the denominator instead of trusting it.
pitch_span_cents :: proc(x: []f32) -> (cents: f64, measured_rate_hz: f64, ok: bool) {
	if len(x) < MOD_FFT * 4 {
		return 0, 0, false
	}
	bins := MOD_FFT / 2 + 1
	power := make([]f64, bins)
	defer delete(power)
	re := make([]f64, MOD_FFT)
	defer delete(re)
	im := make([]f64, MOD_FFT)
	defer delete(im)

	bin_hz := f64(SAMPLE_RATE) / f64(MOD_FFT)
	pitches: [dynamic]f64
	defer delete(pitches)

	for from := 0; from + MOD_FFT <= len(x); from += MOD_HOP {
		if signal_rms(x[from:from + MOD_FFT]) < 1.0e-6 {
			continue
		}
		if !window_power(x, from, power, re, im) {
			break
		}
		f0 := dominant_frequency(power, bin_hz, 12000.0)
		if f0 <= 0 {
			continue
		}
		append(&pitches, 1200.0 * log2f(f0))
	}
	if len(pitches) < 8 {
		return 0, 0, false
	}

	// The LFO rate, from how often the pitch series crosses its own mean going up.
	// One crossing per LFO cycle, whatever the waveform.
	mean := 0.0
	for v in pitches {
		mean += v
	}
	mean /= f64(len(pitches))

	// Hysteresis of a twentieth of the span, so jitter around the mean does not
	// count as a cycle.
	hysteresis := span(pitches[:]) * 0.05
	crossings := 0
	above := pitches[0] > mean
	for v in pitches[1:] {
		if above && v < mean - hysteresis {
			above = false
		} else if !above && v > mean + hysteresis {
			above = true
			crossings += 1
		}
	}
	frame_s := f64(MOD_HOP) / f64(SAMPLE_RATE)
	span_s := f64(len(pitches)) * frame_s
	rate := span_s > 0 ? f64(crossings) / span_s : 0

	return span(pitches[:]), rate, true
}

// Convert a measured pitch wobble into the delay swing that produced it.
//
// A tap at delay(t) = D + A*sin(2*pi*f*t) shifts the pitch by the rate of change
// of that delay: the ratio is 1 - d(delay)/dt, whose peak excursion is 2*pi*f*A.
// So the swing follows from the wobble and the rate in closed form, with no need
// to know D.
swing_seconds_from_cents :: proc(peak_cents, rate_hz: f64) -> f64 {
	if rate_hz <= 0 {
		return 0
	}
	ratio := math.pow(f64(2.0), peak_cents / 1200.0) - 1.0
	return ratio / (2.0 * math.PI * rate_hz)
}

cmd_chorusprobe :: proc(dll: string, sweep: string, spec: string, rate, delay_time: int, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump
	dump_indices := []int{0, 5, 19, 29, 52, 53, 54, 55, 56, 64, 65, 66}

	sweeping_level := sweep != "depth"

	// The rate the depth conversion needs, read off the reference's own display so
	// it is not a second guess stacked on the first.
	rate_hz := 0.0
	{
		p := chorus_probe_patch(64, 127, rate, delay_time, 63, g_chorus_type)
		pl, ok := open_reference(dll)
		if ok {
			load_reference_patch(&pl, &p, pristine, work)
			rate_hz, _ = parse_display_number(dispatch_str(&pl, .GetParamDisplay, 54))
			close_reference(&pl)
		}
	}

	fmt.printfln("chorusprobe: sweeping the %v, rate setting %v (%v Hz), delay setting %v",
		sweeping_level ? "level" : "depth", rate, dec3(rate_hz), delay_time)
	fmt.println()
	fmt.println("Measured off the side signal, L minus R, where the centred dry signal")
	fmt.println("cancels and only the chorus's own output is left.")
	fmt.println()

	if sweeping_level {
		fmt.printfln("%8v %12v %12v %12v", "stored", "side/mid", "vs off", "mid dB")
	} else {
		fmt.println(" stored    wobble ¢   measured Hz  vs shown    swing ms")
	}

	results: [dynamic]f64
	defer delete(results)
	stored: [dynamic]int
	defer delete(stored)

	for v in values {
		// The other knob is held where it does not limit what is being swept.
		p := sweeping_level \
			? chorus_probe_patch(90, v, rate, delay_time, 63, g_chorus_type) \
			: chorus_probe_patch(v, 127, rate, delay_time, 63, g_chorus_type)

		audio := probe_render(dll, &p, pristine, work, CHORUS_PROBE_NOTE, CHORUS_PROBE_SECONDS,
			&dumped, dump_indices)
		if audio == nil {
			continue
		}
		side := side_signal(audio)
		mid := mid_signal(audio)
		delete(audio)

		if sweeping_level {
			// Skip the first 200 ms: the chorus line starts empty and takes a
			// moment to fill.
			from := int(0.2 * f64(SAMPLE_RATE))
			ratio := 0.0
			m := signal_rms(mid[from:])
			if m > 0 {
				ratio = signal_rms(side[from:]) / m
			}

			// Against the same patch with the chorus switched off. Without this
			// column a row of zeroes is ambiguous: it could mean the chorus adds
			// nothing to the side signal, or that it is not engaging at all.
			off := chorus_probe_patch(90, v, rate, delay_time, 63, g_chorus_type)
			set_param(&off, 66, 0)
			difference := -1.0
			dry_mid := 0.0
			if reference := probe_render(dll, &off, pristine, work, CHORUS_PROBE_NOTE,
				CHORUS_PROBE_SECONDS, nil, nil); reference != nil {
				dry := mid_signal(reference)
				difference = 0
				n := min(len(mid), len(dry))
				for i in from ..< n {
					d := abs(f64(mid[i]) - f64(dry[i]))
					if d > difference {
						difference = d
					}
				}
				dry_mid = signal_rms(dry[from:])
				delete(dry)
				delete(reference)
			}
			mid_change := dry_mid > 0 ? amplitude_db(m / dry_mid) : 0

			append(&results, ratio)
			append(&stored, v)
			fmt.printfln("%8v %12v %12v %12v", v, dec5(ratio), dec5(difference), sdec2(mid_change))
		} else {
			cents, measured_rate, ok := pitch_span_cents(side)
			// The swing is converted with the *measured* modulation rate, not the
			// displayed one, for the reason in the note above pitch_span_cents.
			convert_rate := measured_rate > 0 ? measured_rate : rate_hz
			swing := ok ? swing_seconds_from_cents(cents * 0.5, convert_rate) : 0
			append(&results, swing)
			append(&stored, v)
			if ok {
				fmt.printfln(
					"%s %s %s %s %s",
					pad_left(fmt.tprintf("%d", v), 7),
					pad_left(dec1(cents), 11),
					pad_left(dec2(measured_rate), 11),
					pad_left(dec2(measured_rate / max(rate_hz, 1.0e-9)), 9),
					pad_left(dec4(swing * 1000.0), 11),
				)
			} else {
				fmt.printfln("%8v %12v", v, pad_left("-", 12))
			}
		}
		delete(side)
		delete(mid)
		free_all(context.temp_allocator)
	}

	// The curve shape, normalised, against the two candidates the rest of this
	// project has run into: a linear reading of the knob and the measured
	// amplitude curve that parameters 27, 29 all share.
	full := 0.0
	for r in results {
		if r > full {
			full = r
		}
	}
	if full <= 0 {
		return
	}
	fmt.println()
	fmt.printfln("%8v %12v %12v %12v", "stored", "normalised", "linear", "gain curve")
	for r, i in results {
		v := stored[i]
		linear := f64(v) / 127.0
		gain := f64(sengine.AMP_GAIN_AMPLITUDE[clamp(v, 0, 127)]) / f64(sengine.AMP_GAIN_AMPLITUDE[127])
		fmt.printfln("%8v %12v %12v %12v", v, dec4(r / full), dec4(linear), dec4(gain))
	}
}

// Read a number out of a display string, tolerating a unit suffix.
parse_display_number :: proc(display: string) -> (value: f64, ok: bool) {
	// Reuse the engine's permissive reader by hand: leading spaces, optional
	// sign, digits, optional fraction.
	i := 0
	for i < len(display) && (display[i] == ' ' || display[i] == '\t') {
		i += 1
	}
	negative := false
	if i < len(display) && (display[i] == '+' || display[i] == '-') {
		negative = display[i] == '-'
		i += 1
	}
	start := i
	whole := 0.0
	for i < len(display) && display[i] >= '0' && display[i] <= '9' {
		whole = whole * 10 + f64(display[i] - '0')
		i += 1
	}
	if i == start {
		return 0, false
	}
	if i < len(display) && display[i] == '.' {
		i += 1
		scale := 0.1
		for i < len(display) && display[i] >= '0' && display[i] <= '9' {
			whole += f64(display[i] - '0') * scale
			scale *= 0.1
			i += 1
		}
	}
	return negative ? -whole : whole, true
}

// ------------------------------------------------- the delay, measured directly

// Track the chorus tap's delay over time, in milliseconds.
//
// The pitch-wobble method above infers the delay swing from the frequency
// modulation it causes, and it is the wrong instrument at large depths. Two of its
// readings prove it: at full depth it returns swings of 16 to 42 ms against centre
// delays of 15 to 30 ms, and a tap cannot swing further than its own centre without
// the delay going negative. The cause is that a two-stage chorus puts two
// differently-modulated tones in the side signal, and tracking the strongest bin
// hops between them, so the measured span is the sum of two excursions rather than
// either one.
//
// A delay is a time, so this measures it as one. Noise through a single tap mixed
// with the dry signal leaves an autocorrelation peak at exactly the tap's delay, and
// a window short against the LFO period but long against the delay tracks it as it
// moves. No FM approximation, no assumption about the LFO's waveform, and the answer
// comes out in milliseconds.

// 100 ms: long against a 30 ms tap, short against the LFO periods being measured.
CHORUS_TRACK_WINDOW :: 4800
CHORUS_TRACK_HOP :: 960
// The delay range parameter 52 spans, plus margin, in samples at 48 kHz.
CHORUS_TRACK_MIN_LAG :: 24
CHORUS_TRACK_MAX_LAG :: 1680

// Noise through the chorus, with the dry signal present so there is a comb to find.
chorus_noise_patch :: proc(depth, rate, delay_time, level, type: int, feedback: int = 64) -> cpatch.Patch {
	p := neutral_probe_patch()

	set_param(&p, 1, 4) // oscillator 2: noise
	set_param(&p, 5, 127) // "0 : 100" -- oscillator 2 alone
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 100)
	set_param(&p, 66, 1) // chorus on
	set_param(&p, 64, type)
	set_param(&p, 52, delay_time)
	set_param(&p, 53, depth)
	set_param(&p, 54, rate)
	set_param(&p, 55, feedback) // 64 = no feedback, display "0%"
	set_param(&p, 56, level)

	return p
}

// The lag of the strongest autocorrelation peak inside one window, interpolated.
// `lo_lag` and `hi_lag` bound the search.
//
// Bounding it is not a convenience, it is what makes the reading possible. Over a
// 4800-sample window the autocorrelation of noise has a standard deviation near
// 0.014, so searching all 1656 candidate lags puts the argmax among four-sigma
// noise peaks unless the real one is unusually strong -- which is why an unbounded
// search returned the two ends of its own range instead of a delay. The centre is
// read off parameter 52's millisecond display, so bounding around it assumes only
// what the reference already states, and leaves the swing to be measured.
chorus_peak_lag :: proc(x: []f32, from: int, lo_lag, hi_lag: int) -> (lag: f64, strength: f64) {
	if from < 0 || from + CHORUS_TRACK_WINDOW > len(x) {
		return 0, 0
	}
	w := x[from:from + CHORUS_TRACK_WINDOW]

	energy := 0.0
	for v in w {
		energy += f64(v) * f64(v)
	}
	if energy <= 0 {
		return 0, 0
	}

	low := max(lo_lag, CHORUS_TRACK_MIN_LAG)
	high := min(hi_lag, CHORUS_TRACK_MAX_LAG)
	if high <= low + 2 {
		return 0, 0
	}

	best, best_score := 0, -1.0e30
	scores := make([]f64, CHORUS_TRACK_MAX_LAG + 2, context.temp_allocator)
	for l in low ..= high {
		sum := 0.0
		for i in 0 ..< len(w) - l {
			sum += f64(w[i]) * f64(w[i + l])
		}
		scores[l] = sum / energy
		if scores[l] > best_score {
			best_score = scores[l]
			best = l
		}
	}
	if best == 0 {
		return 0, 0
	}

	offset := 0.0
	if best > low && best < high {
		a := scores[best - 1]
		b := scores[best]
		c := scores[best + 1]
		denom := a - 2.0 * b + c
		if abs(denom) > 1.0e-15 {
			offset = clamp(0.5 * (a - c) / denom, -1.0, 1.0)
		}
	}
	return f64(best) + offset, best_score
}

cmd_chorustrack :: proc(dll: string, values: []int, rate, delay_time, type: int, sweep: string) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.printfln(
		"chorustrack: tap delay read from noise autocorrelation, sweeping %v",
		sweep,
	)
	fmt.printfln("  type %v, rate setting %v, delay setting %v", type, rate, delay_time)
	fmt.println(" stored   centre ms   swing ms   min ms   max ms   swing/centre   rate Hz")

	for v in values {
		depth := sweep == "depth" ? v : g_choruswidth_depth
		delay := sweep == "delay" ? v : delay_time
		p := chorus_noise_patch(depth, rate, delay, 127, type)
		// The centre delay in samples, from parameter 52's own display.
		centre_samples := 0.0
		{
			pl, ok := open_reference(dll)
			if ok {
				load_reference_patch(&pl, &p, pristine, work)
				if ms, got := parse_display_number(dispatch_str(&pl, .GetParamDisplay, 52)); got {
					centre_samples = ms * 0.001 * f64(SAMPLE_RATE)
				}
				close_reference(&pl)
			}
		}
		if centre_samples <= 0 {continue}
		lo_lag := int(centre_samples * 0.05)
		hi_lag := int(centre_samples * 2.4)
		audio := probe_render(dll, &p, pristine, work, 60, 4.0, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		held := min(g_hold_frames, len(audio) / 2)
		left := make([]f32, held)
		defer delete(left)
		for i in 0 ..< held {
			left[i] = audio[i * 2]
		}

		lags := make([dynamic]f64)
		defer delete(lags)
		for from := 0; from + CHORUS_TRACK_WINDOW <= len(left); from += CHORUS_TRACK_HOP {
			l, strength := chorus_peak_lag(left, from, lo_lag, hi_lag)
			if l > 0 && strength > 0.02 {
				append(&lags, l)
			}
		}
		if len(lags) < 8 {
			fmt.printfln(" %s   (too few windows tracked)", pad_left(fmt.tprintf("%d", v), 5))
			continue
		}

		lo, hi, mean := lags[0], lags[0], 0.0
		for l in lags {
			lo = min(lo, l)
			hi = max(hi, l)
			mean += l
		}
		mean /= f64(len(lags))

		to_ms :: proc(samples: f64) -> f64 {return samples * 1000.0 / f64(SAMPLE_RATE)}
		centre_ms := to_ms(mean)
		swing_ms := to_ms(hi - lo) * 0.5

		// Rate from the tracked series, one upward mean crossing per cycle.
		crossings := 0
		hysteresis := (hi - lo) * 0.05
		above := lags[0] > mean
		for l in lags[1:] {
			if above && l < mean - hysteresis {
				above = false
			} else if !above && l > mean + hysteresis {
				above = true
				crossings += 1
			}
		}
		span_s := f64(len(lags)) * f64(CHORUS_TRACK_HOP) / f64(SAMPLE_RATE)
		measured_rate := span_s > 0 ? f64(crossings) / span_s : 0

		fmt.printfln(
			" %s %s %s %s %s %s %s",
			pad_left(fmt.tprintf("%d", v), 5),
			pad_left(dec2(centre_ms), 11),
			pad_left(dec3(swing_ms), 10),
			pad_left(dec2(to_ms(lo)), 8),
			pad_left(dec2(to_ms(hi)), 8),
			pad_left(dec3(centre_ms > 0 ? swing_ms / centre_ms : 0), 14),
			pad_left(dec2(measured_rate), 9),
		)
	}
}

// ------------------------------------------------------ the stereo mechanism

// How the chorus makes its stereo image.
//
// Ours makes it one way: the taps are split across the channels and modulated at
// different points of one shared LFO phase, so the two channels decorrelate only
// because the modulation moves them apart. That has a signature -- width must
// collapse as depth falls -- and it is measurably wrong. Reducing the depth to the
// measured curve took the stereo width from -0.060 to -0.072 against the reference
// and to -0.219 at a steeper exponent, always in the same direction: we are
// narrower, and getting narrower as depth drops, while the reference stays wide.
//
// So the first question is not "how wide" but "wide by what means", and one render
// settles it. At **depth zero** there is no modulation at all. If the reference is
// still wide there, its width is static -- a fixed difference between the channels,
// such as one tap being offset from the other -- and no amount of fixing the depth
// curve will produce it. If its width collapses with ours, the mechanism is the same
// and only the amount is wrong.
//
// Three readings are taken per configuration:
//
//   side/mid        the width itself, RMS of L-R against L+R
//   correlation     L against R at zero lag, normalised. Negative means one channel
//                   carries the wet inverted, which is a third way to make width
//   best lag        where L against R correlates best away from zero. If the two
//                   channels are the same signal at different delays, this is the
//                   offset between them, in milliseconds, read directly
g_choruswidth_depth := 127

cmd_choruswidth :: proc(dll: string, values: []int, sweep: string, rate, delay_time, type: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.printfln("choruswidth: sweeping %v, rate setting %v, delay setting %v", sweep, rate, delay_time)
	fmt.println("  noise through the chorus; the dry is centred so L-R is the chorus alone")
	fmt.println()
	fmt.println(" value  stages   ref w   ours w   ref corr  ours corr   ref lag ms  ours lag ms")

	for v in values {
		depth := sweep == "depth" ? v : g_choruswidth_depth
		stages := sweep == "stages" ? v : type
		delay := sweep == "delay" ? v : delay_time
		rate_v := sweep == "rate" ? v : rate
		feedback := sweep == "feedback" ? v : 64

		p := chorus_noise_patch(depth, rate_v, delay, 127, stages, feedback)
		audio := probe_render(dll, &p, pristine, work, 60, 2.0, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		held := min(g_hold_frames, len(audio) / 2)
		if held < 8192 {continue}

		left := make([]f32, held)
		defer delete(left)
		right := make([]f32, held)
		defer delete(right)
		for i in 0 ..< held {
			left[i] = audio[i * 2]
			right[i] = audio[i * 2 + 1]
		}

		mid_rms, side_rms := 0.0, 0.0
		for i in 0 ..< held {
			m := 0.5 * (f64(left[i]) + f64(right[i]))
			s := 0.5 * (f64(left[i]) - f64(right[i]))
			mid_rms += m * m
			side_rms += s * s
		}
		mid_rms = math.sqrt(mid_rms / f64(held))
		side_rms = math.sqrt(side_rms / f64(held))
		width := mid_rms > 0 ? side_rms / mid_rms : 0

		// Cross-correlation of the two channels, over the delay range the chorus
		// can reach. Skipping the first 100 ms keeps the note's onset out of it.
		from := min(int(0.1 * f64(SAMPLE_RATE)), held / 4)
		a := left[from:]
		b := right[from:]
		n := min(len(a), len(b))
		MAX_OFFSET :: 1680

		energy_a, energy_b := 0.0, 0.0
		for i in 0 ..< n {
			energy_a += f64(a[i]) * f64(a[i])
			energy_b += f64(b[i]) * f64(b[i])
		}
		norm := math.sqrt(energy_a * energy_b)
		if norm <= 0 {continue}

		correlation :: proc(a, b: []f32, lag, n: int, norm: f64) -> f64 {
			sum := 0.0
			if lag >= 0 {
				for i in 0 ..< n - lag {
					sum += f64(a[i + lag]) * f64(b[i])
				}
			} else {
				for i in 0 ..< n + lag {
					sum += f64(a[i]) * f64(b[i - lag])
				}
			}
			return sum / norm
		}

		zero := correlation(a, b, 0, n, norm)

		best_lag, best := 0, 0.0
		for lag := -MAX_OFFSET; lag <= MAX_OFFSET; lag += 1 {
			// Away from zero, so the shared dry signal is not the answer.
			if abs(lag) < 24 {continue}
			c := correlation(a, b, lag, n, norm)
			if abs(c) > abs(best) {
				best = c
				best_lag = lag
			}
		}

		// The same three readings from our engine, rendered from the identical patch
		// so the comparison is not against a remembered number.
		ours := render_ours(p, 60)
		defer delete(ours)
		our_width, our_zero, our_lag := 0.0, 0.0, 0.0
		if ours != nil {
			oheld := min(held, len(ours) / 2)
			ol := make([]f32, oheld)
			defer delete(ol)
			or := make([]f32, oheld)
			defer delete(or)
			for i in 0 ..< oheld {
				ol[i] = ours[i * 2]
				or[i] = ours[i * 2 + 1]
			}
			om, os := 0.0, 0.0
			for i in 0 ..< oheld {
				m := 0.5 * (f64(ol[i]) + f64(or[i]))
				s := 0.5 * (f64(ol[i]) - f64(or[i]))
				om += m * m
				os += s * s
			}
			om = math.sqrt(om / f64(oheld))
			os = math.sqrt(os / f64(oheld))
			our_width = om > 0 ? os / om : 0

			ofrom := min(from, oheld / 4)
			oa := ol[ofrom:]
			ob := or[ofrom:]
			on := min(len(oa), len(ob))
			ea, eb := 0.0, 0.0
			for i in 0 ..< on {
				ea += f64(oa[i]) * f64(oa[i])
				eb += f64(ob[i]) * f64(ob[i])
			}
			onorm := math.sqrt(ea * eb)
			if onorm > 0 {
				our_zero = correlation(oa, ob, 0, on, onorm)
				obest_lag, obest := 0, 0.0
				for lag := -MAX_OFFSET; lag <= MAX_OFFSET; lag += 1 {
					if abs(lag) < 24 {continue}
					c := correlation(oa, ob, lag, on, onorm)
					if abs(c) > abs(obest) {
						obest = c
						obest_lag = lag
					}
				}
				our_lag = f64(obest_lag) * 1000.0 / f64(SAMPLE_RATE)
			}
		}

		fmt.printfln(
			" %s %s %s %s %s %s %s %s",
			pad_left(fmt.tprintf("%d", v), 5),
			pad_left(fmt.tprintf("%d", stages), 7),
			pad_left(dec3(width), 7),
			pad_left(dec3(our_width), 8),
			pad_left(sdec3(zero), 10),
			pad_left(sdec3(our_zero), 10),
			pad_left(dec2(f64(best_lag) * 1000.0 / f64(SAMPLE_RATE)), 12),
			pad_left(dec2(our_lag), 12),
		)
	}
}

// s1probe chorusstability - does the chorus's width hold still over a long
// held note, or does it grow?
//
// Every other chorus measurement in this file holds a note for a few seconds,
// which is enough to read a static width but not enough to see a slow drift.
// Near-unity feedback is a real, reported symptom: a patch that sounds fine on
// a quick check "sounds like a ghost... bounces from side to side" on a note
// actually held, and gets better with feedback at its centre. That is what a
// feedback loop slowly amplifying a tiny asymmetry between the two channels'
// delay lines would sound like, and the short renders everywhere else in this
// project would not catch it.
//
//   s1probe chorusstability [dll] [--type <n>] [--delay <n>] [--depth <n>]
//                                  [--rate <n>] [--feedback <n>] [--seconds <n>]
//                                  [--file <patch.sy1>] [--note <n>]
cmd_chorusstability :: proc(dll: string, type, delay_time, depth, rate, feedback: int, seconds: f64, file: string, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	p: cpatch.Patch
	render_note := u8(60)
	if file != "" {
		data, rerr := os.read_entire_file_from_path(file, context.allocator)
		if rerr != nil {
			fmt.eprintln("chorusstability: could not read", file, rerr)
			return
		}
		parsed, perr := cpatch.parse_sy1(data)
		if perr != nil {
			fmt.eprintln("chorusstability: could not parse", file, perr)
			return
		}
		p = parsed
		render_note = note
		fmt.printfln("chorusstability: %v, note %v, %v s held", file, render_note, dec1(seconds))
	} else {
		p = chorus_noise_patch(depth, rate, delay_time, 127, type, feedback)
		render_note = 60
		fmt.printfln("chorusstability: type %v, delay %v, depth %v, rate %v, feedback %v, %v s held",
			type, delay_time, depth, rate, feedback, dec1(seconds))
	}
	dump_indices := []int{52, 53, 54, 55, 56, 64}
	dumped := false
	fmt.println("  width read in one-second windows over the hold")
	fmt.println()

	ref_audio := probe_render(dll, &p, pristine, work, render_note, seconds, &dumped, dump_indices)
	if ref_audio == nil {
		fmt.eprintln("chorusstability: the reference produced no audio")
		return
	}
	defer delete(ref_audio)
	our_audio := render_ours(p, int(render_note))
	defer delete(our_audio)

	window := SAMPLE_RATE
	windows := min(len(ref_audio), len(our_audio)) / 2 / window

	fmt.printfln("%6v %10v %10v %10v %10v %10v %10v", "second", "ref width", "our width", "ref mid", "ref side", "our mid", "our side")
	window_stats :: proc(audio: []f32, start, n: int) -> (width, mid, side: f64) {
		mid_sq, side_sq := 0.0, 0.0
		for i in 0 ..< n {
			l := f64(audio[(start + i) * 2])
			r := f64(audio[(start + i) * 2 + 1])
			m := 0.5 * (l + r)
			s := 0.5 * (l - r)
			mid_sq += m * m
			side_sq += s * s
		}
		mid = math.sqrt(mid_sq / f64(n))
		side = math.sqrt(side_sq / f64(n))
		width = mid > 0 ? side / mid : 0
		return
	}
	for w in 0 ..< windows {
		rw, rmid, rside := window_stats(ref_audio, w * window, window)
		ow, omid, oside := window_stats(our_audio, w * window, window)
		fmt.printfln("%6v %10v %10v %10v %10v %10v %10v",
			w + 1, dec3(rw), dec3(ow), dec4(rmid), dec4(rside), dec4(omid), dec4(oside))
	}
}
