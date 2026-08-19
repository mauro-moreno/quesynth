// s1probe lfosquare - the cutoff, volume and pan depths, read off a square LFO.
//
// `s1probe lfopitch` settled the pitch depth by driving the LFO with a square
// instead of a triangle: the destination stops sweeping and sits at two steady
// values, so each can be measured at leisure and the interval between them is the
// depth by construction. It also found the depth knob to be exponential rather
// than linear, and that curve was applied to the pitch destinations *only*,
// because the other three had been measured with the old sweeping method and two
// of them plainly disagreed.
//
//   s1probe lfosquare [dll] [--param 41|46] [--dest 3|4|7] [--values <list|all>]
//                           [--note <n>] [--rate <n>] [--dump]
//
// This is that follow-up. The same square, pointed at the filter cutoff, the
// volume and the stereo position, to find out whether one depth curve drives
// every destination or the pitch really is its own thing.
//
// The answer is that there is no shared curve: all four destinations differ, and
// the cutoff and the volume are not even bipolar. Each reports in its own unit:
//
//   cutoff   octaves above the unmodulated corner   LFO_CUTOFF_OCTAVES
//   volume   decibels removed at the trough         no constant; linear in amplitude
//   pan      peak deviation, -1..1                  LFO_PAN_DEPTH_VALUES
package s1probe

import "core:fmt"
import "core:math"
import "core:os"

import cpatch "../../src/patch"
import sengine "../../src/engine"

// A centroid is proportional to the corner only in the middle of the range, and
// the cutoff sweep runs off both ends of that middle. So the centroid is not used
// as a measure of the corner directly -- it is calibrated against the reference's
// own static cutoff curve and inverted through that.
//
// This is the pattern `qprobe` already uses for the resonance, and for the same
// reason: an observable that is monotonic in the quantity of interest does not have
// to be linear in it, provided the same instrument reads a known sweep first.
//
// It also makes the instrument's blind spots explicit rather than silent. Closing
// the filter eventually leaves the centroid measuring the residue instead of the
// signal -- the low half of the square reads 396 Hz whatever the depth, exactly the
// unmodulated value -- and a calibration curve that has gone flat says so, where a
// bare proportionality would have quietly halved that into the answer.
LFO_SQ_CAL_STEP :: 4
LFO_SQ_CAL_SECONDS :: 4.0

Lfo_Square_Calibration :: struct {
	// The observable, at each sampled setting of the parameter being calibrated.
	centroid: [dynamic]f64,
	// What that setting actually is, in whatever unit the caller wants back.
	value:    [dynamic]f64,
}

lfo_square_calibrate :: proc(dll: string, pristine, work: []byte, note: u8) -> Lfo_Square_Calibration {
	cal: Lfo_Square_Calibration
	for v := 0; v < 128; v += LFO_SQ_CAL_STEP {
		p := neutral_probe_patch()
		set_param(&p, 1, 4) // osc2: noise
		set_param(&p, 5, 127)
		set_param(&p, 14, 0) // low pass, 12 dB
		set_param(&p, 19, v)
		set_param(&p, 20, 0)
		set_param(&p, 29, 110)

		audio := probe_render(dll, &p, pristine, work, note, LFO_SQ_CAL_SECONDS, nil, nil)
		if audio == nil {
			continue
		}
		series := lfo_square_centroid_series(audio)
		delete(audio)
		if len(series) < 2 {
			delete(series)
			continue
		}
		s := 0.0
		for x in series {
			s += x
		}
		delete(series)

		c := s / f64(len(series))
		hz := f64(sengine.FILTER_CUTOFF_HZ[v])
		// Monotonic only: a calibration that doubles back cannot be inverted, and
		// where the centroid has stopped responding it does exactly that.
		if len(cal.centroid) > 0 && c <= cal.centroid[len(cal.centroid) - 1] {
			continue
		}
		append(&cal.centroid, c)
		append(&cal.value, log2f(hz))
		free_all(context.temp_allocator)
	}
	return cal
}

// A measured centroid converted to the corner that produced it.
//
// Returns ok=false outside the calibrated span, which is the honest answer when
// the filter has closed past the point where the centroid still moves.
lfo_square_invert :: proc(cal: ^Lfo_Square_Calibration, centroid: f64) -> (value: f64, ok: bool) {
	n := len(cal.centroid)
	if n < 4 {
		return 0, false
	}
	if centroid < cal.centroid[0] || centroid > cal.centroid[n - 1] {
		return 0, false
	}
	for i in 1 ..< n {
		if centroid <= cal.centroid[i] {
			lo_c := cal.centroid[i - 1]
			hi_c := cal.centroid[i]
			if hi_c <= lo_c {
				return cal.value[i], true
			}
			t := (centroid - lo_c) / (hi_c - lo_c)
			return cal.value[i - 1] + t * (cal.value[i] - cal.value[i - 1]), true
		}
	}
	return cal.value[n - 1], true
}

// The cutoff needs a far slower LFO and a much longer render than the others.
//
// Its corner is read through a Welch estimate spanning 32768 samples, which is
// 683 ms of audio, and a window that straddles an edge of the square holds some of
// both levels. The half cycle therefore has to be several times 683 ms, not merely
// longer than it. Stored 8 is about 0.12 Hz -- a half cycle of 4.2 seconds, which
// fits two dozen hops with room to discard the ones near an edge.
//
// This was first tried at stored 30, a half cycle of 1.04 s, on the reasoning that
// one window fits inside it. One barely does, and two thirds of the hops landed on
// an edge; the sweep came back non-monotonic and largely unreadable. The old
// `lfodepth` used a rate this slow for exactly this reason and it was right to.
LFO_SQ_CUTOFF_RATE :: 8
LFO_SQ_CUTOFF_SECONDS :: 40.0
// The base cutoff the modulation is measured from, overridable with --base.
//
// Not a detail: whether the modulation is bipolar or only ever opens the filter
// is decided by moving this. At a base near the top of the range an upward-only
// modulation has nowhere to go and must fall silent, where a bipolar one still
// has its whole downward half.
g_lfo_sq_cutoff_base := 64

// Volume and pan are read frame by frame and need neither.
LFO_SQ_RATE :: 44
LFO_SQ_SECONDS :: 8.0
LFO_SQ_FRAME_MS :: 1.0

lfo_square_patch :: proc(
	dest, depth, rate: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
) -> cpatch.Patch {
	p := neutral_probe_patch()

	if dest == 3 {
		// Noise through the low pass, the same source every other filter
		// measurement in this project uses, with the corner set mid-range so it has
		// room to move both ways.
		set_param(&p, 1, 4) // osc2: noise
		set_param(&p, 5, 127)
		set_param(&p, 14, 0) // low pass, 12 dB
		set_param(&p, 19, g_lfo_sq_cutoff_base)
		set_param(&p, 20, 0) // no resonance, so the corner is not a peak
	} else {
		// A sine, so the level and the stereo position are clean.
		set_param(&p, 0, 0)
		set_param(&p, 5, 0)
		set_param(&p, 19, 127)
	}
	set_param(&p, 29, 110)

	set_param(&p, on_index, 1)
	set_param(&p, dest_index, dest)
	set_param(&p, shape_index, LFO_PITCH_SHAPE_SQUARE)
	set_param(&p, speed_index, rate)
	set_param(&p, depth_index, depth)
	set_param(&p, keysync_index, 1)
	set_param(&p, temposync_index, 0)
	return p
}

// The spectral centroid of noise through the low pass, window by window, in
// octaves.
//
// This replaces reading the -3 dB corner, and the reason is worth recording
// because the corner is what every other filter measurement in this project uses.
// A corner is a *crossing*: it is found by walking the band profile until the
// response falls 3 dB, so it depends on a handful of bands near the threshold and
// inherits all of their noise. Through the reference at a swept cutoff it was too
// unreliable to work with at all -- the corner series repeated at 0.18 where our
// own engine's repeated at 0.82, so the periodicity of a plainly periodic signal
// was being lost in the estimator rather than in the signal.
//
// A centroid is an *average*: every bin contributes, so it is smooth, always
// defined, and has far lower variance. For noise through a fixed slope it tracks
// the corner proportionally, which is all this needs -- the constant of
// proportionality cancels when the two levels are subtracted, so no calibration is
// required and none is assumed.
lfo_square_centroid_series :: proc(audio: []f32) -> []f64 {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < FFT_SIZE * 2 {
		return nil
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	out: [dynamic]f64
	step := FFT_SIZE / 2
	for from := 0; from + FFT_SIZE * 2 <= len(mid); from += step {
		power := welch_power(mid, from, from + FFT_SIZE * 2)
		if power == nil {
			continue
		}
		hz := spectral_centroid(power, bin_hz)
		delete(power)
		append(&out, hz > 0 ? log2f(hz) : log2f(BAND_LO_HZ))
	}
	return out[:]
}

// The filter corner, window by window, in octaves. Kept for reference; the
// centroid above is what the cutoff sweep actually uses.
lfo_square_corner_series :: proc(audio: []f32, open_bands, centres: []f64) -> []f64 {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < FFT_SIZE * 2 {
		return nil
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	out: [dynamic]f64
	step := FFT_SIZE / 2
	for from := 0; from + FFT_SIZE * 2 <= len(mid); from += step {
		power := welch_power(mid, from, from + FFT_SIZE * 2)
		if power == nil {
			continue
		}
		bands, band_centres := band_powers(power, bin_hz)
		hz, hit := measure_corner(bands, open_bands, centres)
		delete(bands)
		delete(band_centres)
		delete(power)
		// Unresolved windows keep their slot, holding the last good value.
		//
		// Dropping them instead breaks the phase assignment downstream, which reads
		// a window's time off its index and would silently re-time every window
		// after a gap. At the deep end of the sweep the corner leaves the analysed
		// band for a whole half cycle at a time, so the gaps are neither rare nor
		// randomly placed -- they are exactly the low half of the square.
		if hit && hz > 0 {
			append(&out, log2f(hz))
		} else if len(out) > 0 {
			append(&out, out[len(out) - 1])
		} else {
			append(&out, log2f(BAND_LO_HZ))
		}
	}
	return out[:]
}

// Set by --trace, to see what the corner estimator is actually producing rather
// than only whether it was accepted.
g_lfo_square_trace: bool

// Two levels, split by *when* each sample was taken rather than by its value.
//
// `lfo_two_levels` cannot be used on the filter corner, and finding that out cost
// a whole run. A corner estimated from a noise source jitters by the better part
// of an octave window to window -- this file's own history records an unmodulated
// sweep reading two octaves of movement -- and splitting a noisy series at its
// midpoint sorts *the noise itself* into a high group and a low group. That is not
// a weak measurement, it is a biased one: it manufactures a separation of about
// twice the noise amplitude out of a signal that has none. The first version of
// this probe duly reported 1.54 octaves of cutoff modulation at depth zero.
//
// Assigning each window to a half cycle by its timestamp removes the bias
// completely, because the assignment no longer looks at the value it is about to
// average. The period comes from the series' own autocorrelation, so nothing is
// assumed about the rate; when there is no periodicity to find, there is no
// modulation, which is the answer depth zero should give and now does.
//
// The middle half of each half cycle is used and the quarters around each edge are
// dropped, since a window that straddles an edge holds some of both levels.
lfo_levels_by_phase :: proc(series: []f64) -> (lo, hi: f64, ok: bool) {
	trim := max(len(series) / 10, 1)
	if len(series) < trim * 2 + 16 {
		return 0, 0, false
	}
	body := series[trim:len(series) - trim]

	mean := 0.0
	for v in body {
		mean += v
	}
	mean /= f64(len(body))

	period, strength, found := lfo_period(body, mean, len(body) / 3)
	if g_lfo_square_trace {
		fmt.eprintfln("    [trace] %v windows, period %v, repeat %v, found %v",
			len(body), dec1(period), dec3(strength), found)
	}
	// Nothing repeating: the destination is not moving.
	// A square repeats near perfectly; anything less is the estimator's own noise
	// finding a pattern in itself, which is precisely what this procedure exists to
	// refuse.
	if !found || strength < 0.7 || period < 4 {
		return 0, 0, false
	}

	first: [dynamic]f64
	defer delete(first)
	second: [dynamic]f64
	defer delete(second)
	for v, i in body {
		phase := math.mod(f64(i) / period, 1.0)
		switch {
		case phase >= 0.15 && phase <= 0.35:
			append(&first, v)
		case phase >= 0.65 && phase <= 0.85:
			append(&second, v)
		}
	}
	if len(first) < 3 || len(second) < 3 {
		return 0, 0, false
	}

	mean_of :: proc(v: []f64) -> f64 {
		s := 0.0
		for x in v {
			s += x
		}
		return s / f64(len(v))
	}
	a := mean_of(first[:])
	b := mean_of(second[:])
	return min(a, b), max(a, b), true
}

// The stereo position a pan value produces, inverted.
//
// `pan_series` reports (L-R)/(L+R), which is not the pan value: the reference's
// pan law holds the near channel at full level and attenuates the far one, so the
// observable is p/(2-|p|) and has to be inverted to recover p. Doing that here
// rather than comparing the raw ratios is what lets this report a number in the
// same unit `LFO_PAN_RANGE` is written in.
//
// The inversion is the one place in this probe that assumes a model. It is the
// reference's own measured law rather than a convenience -- see the pan law at the
// bottom of `voice_process`, where the 0.50/0.75/1.00 mid levels it was fitted to
// are recorded -- but a reading near the ends is still worth distrusting, because
// the law flattens there and small errors in the ratio become large ones in p.
lfo_pan_from_ratio :: proc(s: f64) -> f64 {
	x := clamp(s, -0.999, 0.999)
	// Positive ratio means more left, which this engine calls a negative pan.
	if x >= 0 {
		return -2.0 * x / (1.0 + x)
	}
	return -2.0 * x / (1.0 - x)
}

Lfo_Square_Reading :: struct {
	ok:      bool,
	lo:      f64,
	hi:      f64,
	// Half the interval, except for volume where the constant is peak to peak.
	value:   f64,
	bounded: bool,
}

lfo_square_read :: proc(
	audio: []f32,
	dest: int,
	open_bands, centres: []f64,
) -> Lfo_Square_Reading {
	r: Lfo_Square_Reading
	frame_len := int(LFO_SQ_FRAME_MS * 0.001 * f64(SAMPLE_RATE))

	series: []f64
	switch dest {
	case 3:
		series = lfo_square_centroid_series(audio)
	case 4:
		series = lfo_amp_series(audio, frame_len)
	case:
		series = pan_series(audio, frame_len)
	}
	defer delete(series)
	if series == nil || len(series) < 16 {
		return r
	}

	lo, hi: f64
	ok: bool
	if dest == 3 {
		lo, hi, ok = lfo_levels_by_phase(series)
	} else {
		lo, hi, ok = lfo_two_levels(series)
	}
	if !ok {
		return r
	}
	r.lo = lo
	r.hi = hi
	r.ok = true

	switch dest {
	case 3:
		// Already in octaves; half the interval is the peak deviation.
		r.value = (hi - lo) * 0.5
		// The centroid tracks the corner only while the corner is inside the
		// analysed band. Once it leaves, the centroid stops moving with it and the
		// reading compresses towards a bound rather than being wrong outright.
		r.bounded = lo <= log2f(BAND_LO_HZ * 2.0) || hi >= log2f(BAND_HI_HZ * 0.5)
	case 4:
		// Decibels, and this constant is peak to peak rather than a deviation.
		r.value = hi - lo
	case:
		// The two stereo positions, converted back through the pan law.
		p_lo := lfo_pan_from_ratio(lo)
		p_hi := lfo_pan_from_ratio(hi)
		r.value = abs(p_hi - p_lo) * 0.5
		// Hard left or hard right: past this the law cannot distinguish depths.
		r.bounded = lo <= -0.985 || hi >= 0.985
	}
	return r
}

lfo_square_measure :: proc(
	dll: string,
	pristine, work: []byte,
	open_bands, centres: []f64,
	dest, depth, rate: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	note: u8,
	dumped: ^bool,
) -> (
	reference, ours: Lfo_Square_Reading,
) {
	seconds := dest == 3 ? f64(LFO_SQ_CUTOFF_SECONDS) : f64(LFO_SQ_SECONDS)
	p := lfo_square_patch(dest, depth, rate, shape_index, dest_index, speed_index,
		depth_index, on_index, keysync_index, temposync_index)
	dump_indices := []int{0, 1, 5, 14, 19, 20, 29, shape_index, dest_index, speed_index, depth_index, on_index}

	ref_audio := probe_render(dll, &p, pristine, work, note, seconds, dumped, dump_indices)
	if ref_audio == nil {
		return
	}
	defer delete(ref_audio)
	our_audio := render_ours(p, int(note))
	defer delete(our_audio)

	reference = lfo_square_read(ref_audio, dest, open_bands, centres)
	ours = lfo_square_read(our_audio, dest, open_bands, centres)
	return
}

lfo_square_unit :: proc(dest: int) -> string {
	switch dest {
	case 3:
		return "octaves, peak deviation"
	case 4:
		return "dB, peak to peak"
	}
	return "pan units, peak deviation"
}

cmd_lfosquare :: proc(dll: string, param, dest: int, spec: string, note: u8, rate: int, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	open_bands, centres, open_ok := filter_open_reference(dll, pristine, work, note)
	defer delete(open_bands)
	defer delete(centres)
	if !open_ok {
		fmt.eprintln("lfosquare: the open reference produced no spectrum")
		os.exit(1)
	}

	is_lfo1 := param != 46
	dest_index := is_lfo1 ? 41 : 46
	shape_index := is_lfo1 ? 42 : 47
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	use_rate := rate > 0 ? rate : (dest == 3 ? LFO_SQ_CUTOFF_RATE : LFO_SQ_RATE)
	depths := parse_env_values(spec)
	defer delete(depths)
	dumped := !dump

	fmt.printfln("lfosquare: parameter %v, destination %v (%v), square LFO at rate %v, note %v",
		depth_index, dest, lfo_depth_state_name(dest), use_rate, note)
	fmt.printfln("           reported in %v; * marks a reading against this method's limits",
		lfo_square_unit(dest))
	fmt.println()
	fmt.printfln("%8v %11v %11v %11v %11v %10v %10v",
		"depth", "ref lo", "ref hi", "reference", "ours", "ref/full", "curve")
	fmt.println()

	// The unmodulated centroid, which the two levels are measured against.
	//
	// The cutoff needs this and the other destinations do not, because its low side
	// stops moving well before its high side does: as the filter closes, the
	// centroid of what comes out stops tracking the corner and settles on the
	// residue instead. Reported as a single half-interval that asymmetry is
	// invisible and halves into the answer; reported as two excursions from a known
	// centre it is obvious, which is the same lesson `lfopitch` learned about its
	// own floor.
	cal: Lfo_Square_Calibration
	defer delete(cal.centroid)
	defer delete(cal.value)
	base: f64 = 0
	if dest == 3 {
		cal = lfo_square_calibrate(dll, pristine, work, note)
		if len(cal.centroid) < 4 {
			fmt.eprintln("lfosquare: the cutoff calibration did not resolve")
			os.exit(1)
		}
		fmt.printfln("centroid calibration: %v points, centroid %v..%v Hz for corners %v..%v Hz",
			len(cal.centroid),
			dec0(math.pow(2.0, cal.centroid[0])),
			dec0(math.pow(2.0, cal.centroid[len(cal.centroid) - 1])),
			dec0(math.pow(2.0, cal.value[0])),
			dec0(math.pow(2.0, cal.value[len(cal.value) - 1])))
		base = f64(log2f(f64(sengine.FILTER_CUTOFF_HZ[g_lfo_sq_cutoff_base])))
		fmt.printfln("unmodulated corner:   %v Hz", dec1(math.pow(2.0, base)))
		fmt.println()
	}

	// The measured full-depth reading, so the column of normalised values below is
	// against the reference's own top of range rather than against a constant this
	// engine already believes.
	full: f64 = 0
	{
		reference, _ := lfo_square_measure(
			dll, pristine, work, open_bands, centres, dest, 127, use_rate,
			shape_index, dest_index, speed_index, depth_index, on_index,
			keysync_index, temposync_index, note, &dumped,
		)
		if reference.ok {
			if dest == 3 { if hc, hok := lfo_square_invert(&cal, reference.hi); hok { full = hc - base } } else { full = reference.value }
		}
		free_all(context.temp_allocator)
	}

	for depth in depths {
		reference, ours := lfo_square_measure(
			dll, pristine, work, open_bands, centres, dest, depth, use_rate,
			shape_index, dest_index, speed_index, depth_index, on_index,
			keysync_index, temposync_index, note, &dumped,
		)
		if !reference.ok {
			fmt.printfln("%8v %11v", depth, pad_left("-", 11))
			free_all(context.temp_allocator)
			continue
		}
		// What the pitch destination's measured curve would predict, normalised.
		u := f64(depth) / 127.0
		k := 2.3
		curve := (math.exp(k * u) - 1.0) / (math.exp(k) - 1.0)
		// For the cutoff, quote the upward excursion through the calibration: its
		// downward one measures the residue rather than the depth.
		value := reference.value
		our_value := ours.value
		bounded := reference.bounded
		lo_shown := reference.lo
		hi_shown := reference.hi
		if dest == 3 {
			hi_corner, hi_ok := lfo_square_invert(&cal, reference.hi)
			lo_corner, _ := lfo_square_invert(&cal, reference.lo)
			lo_shown = lo_corner
			hi_shown = hi_corner
			value = hi_ok ? hi_corner - base : 0
			bounded = !hi_ok
			if ours.ok {
				if oc, ook := lfo_square_invert(&cal, ours.hi); ook {
					our_value = oc - base
				}
			}
		}
		fmt.printfln("%8v %11v %11v %11v %11v %10v %10v",
			depth, dec3(lo_shown), dec3(hi_shown),
			pad_left(fmt.tprintf("%v%v", dec3(value), bounded ? "*" : " "), 11),
			ours.ok ? dec3(our_value) : "-",
			full > 0 ? dec3(value / full) : "-",
			dec3(curve))
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("`ref/full` is this destination's own depth curve, normalised against its")
	fmt.println("full-depth reading. `curve` is the exponential measured on the pitch")
	fmt.println("destinations. If the two columns agree, one depth curve drives everything.")
}
