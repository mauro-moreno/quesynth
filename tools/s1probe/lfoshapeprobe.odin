// s1probe lfoshape - measure the LFO waveform states, parameters 42 and 47.
//
// The destinations of parameters 41 and 46 were measured by `lfoprobe`, and the
// rate of 43 and 48 by `lforatetable`. The *shapes* never were. `binding.odin`
// maps them from the English readme's list -- "saw, triangle, sine, square,
// random(sample & hold) or random (smoothed)" -- read onto the display
// identifier, and that is a guess of exactly the kind this project has already
// been caught by twice: parameters 0 and 1 turned out to list their waveforms in
// an order the plugin does not use, and 41's and 46's destinations did too.
//
//   s1probe lfoshape [dll] [--param 42|47] [--values <list|all>]
//                          [--speed <n>] [--note <n>] [--dump]
//
// Method: point the LFO at the stereo position, which is what `lforate` already
// established gives a bipolar scalar per frame that nothing else in the voice can
// contaminate, and read the waveform straight off it. The period comes from the
// series' own autocorrelation rather than from the rate table, so this measures
// shape without assuming the rate; the same autocorrelation peak's height is the
// statistic that separates the four deterministic shapes from the two random
// ones.
//
// Every state is rendered through our engine as well, under identical conditions,
// because the question is not "what shape is this" in the abstract but "does our
// binding produce the reference's shape for the same stored integer". A verdict
// that came only from classifying the reference would still leave the mapping
// layer -- display identifier versus state position -- untested.
package s1probe

import "core:fmt"
import "core:math"

import cpatch "../../src/patch"

// One millisecond, sampling the LFO at 1 kHz, and a high note so a frame holds a
// whole cycle of the note it is measuring the RMS of. Both are `lforate`'s, for
// its reasons.
LFO_SHAPE_FRAME_MS :: 1.0
LFO_SHAPE_NOTE :: u8(96)

// Stored 70 is about 3 Hz on the measured rate curve. Fast enough that a render
// of a few seconds holds enough cycles to tell a repeating shape from a random
// one, slow enough that a 1 ms frame puts several hundred points in each cycle.
LFO_SHAPE_SPEED :: 70
LFO_SHAPE_SECONDS :: 6.0

// Points in the folded cycle. Enough to see a corner, few enough to print.
LFO_SHAPE_BUCKETS :: 24

// A shape has to move this far, peak to peak, before it is called a waveform
// rather than an inert state.
LFO_SHAPE_MIN_RANGE :: 0.05

// How hard to drive the LFO.
//
// Not full. At depth 127 the reference's pan reaches the rails and stays there
// for a third of the cycle, which flattens the top of every shape: a triangle
// arrives as a trapezoid and a sine as a flat-topped sine, and the two stop being
// separable. The shape has to be read where the observable is still linear.
g_lfo_shape_depth := 64

// Which destination to watch, as parameter 41/46's stored value.
//
// Pan is the default because it is the cleanest observable in the voice. It
// cannot settle one question, though: the *direction* of the saw. A sign flip of
// the LFO is indistinguishable from a sign flip of the destination it drives, and
// pan has no absolute sense -- "left" is a convention on both sides of the
// comparison, so matching it only proves the two conventions were composed the
// same way, not that either is right.
//
// Volume does have an absolute sense. Louder is louder in any convention, so a
// saw read off the amplitude says which way the reference's saw really runs. That
// is the one thing this probe measures through destination 4.
g_lfo_shape_dest := 7

lfo_shape_patch :: proc(
	shape, speed: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 110)

	set_param(&p, on_index, 1)
	set_param(&p, dest_index, g_lfo_shape_dest)
	set_param(&p, speed_index, speed)
	set_param(&p, depth_index, g_lfo_shape_depth)
	set_param(&p, shape_index, shape)
	set_param(&p, keysync_index, 1) // same starting phase every render
	set_param(&p, temposync_index, 0)
	return p
}

// Loudness per frame, in decibels.
//
// The observable for destination 4. Decibels rather than raw amplitude because
// the reference's volume law is itself unmeasured: reading a shape through an
// unknown monotonic curve can bend a triangle into something sine-shaped, and
// working in decibels at least puts both engines on the same axis. The one thing
// it cannot bend is the direction of a ramp, which is what this observable is
// here to settle.
lfo_amp_series :: proc(audio: []f32, frame_len: int) -> []f64 {
	if frame_len <= 0 || len(audio) < frame_len * 4 {
		return nil
	}
	frames := len(audio) / (frame_len * 2)
	out := make([]f64, frames)
	for f in 0 ..< frames {
		base := f * frame_len * 2
		sum := 0.0
		for i in 0 ..< frame_len {
			m := 0.5 * (f64(audio[base + i * 2]) + f64(audio[base + i * 2 + 1]))
			sum += m * m
		}
		rms := math.sqrt(sum / f64(frame_len))
		out[f] = rms > 1.0e-9 ? 20.0 * math.log10(rms) : -180.0
	}
	return out
}

// The series this run reads its shapes off.
lfo_observable :: proc(audio: []f32, frame_len: int) -> []f64 {
	if g_lfo_shape_dest == 4 {
		return lfo_amp_series(audio, frame_len)
	}
	return pan_series(audio, frame_len)
}

// Mean and peak-to-peak range of a series.
lfo_series_stats :: proc(x: []f64) -> (mean, range: f64) {
	if len(x) == 0 {
		return 0, 0
	}
	lo := x[0]
	hi := x[0]
	for v in x {
		mean += v
		if v < lo {lo = v}
		if v > hi {hi = v}
	}
	mean /= f64(len(x))
	return mean, hi - lo
}

// Normalised autocorrelation of the mean-removed series at one lag.
lfo_autocorr :: proc(x: []f64, mean: f64, lag: int) -> f64 {
	n := len(x) - lag
	if n < 8 {
		return 0
	}
	num, da, db := 0.0, 0.0, 0.0
	for i in 0 ..< n {
		a := x[i] - mean
		b := x[i + lag] - mean
		num += a * b
		da += a * a
		db += b * b
	}
	if da <= 0 || db <= 0 {
		return 0
	}
	return num / math.sqrt(da * db)
}

// The period in frames, as the autocorrelation's first peak past its first
// negative excursion.
//
// The naive version of this -- the earliest lag whose correlation is near the
// maximum -- does not work, and failed here before it was fixed. At 1 ms frames a
// few-hertz LFO moves about a hundredth of its range per frame, so the series is
// smooth on the scale of the lags being searched and its autocorrelation is still
// above 0.9 at a fifth of a period. The earliest-near-best rule therefore returned
// whatever the bottom of the search range happened to be, and the fold that used
// it averaged the waveform into a flat line: several states reported a full 2.0 of
// range and a folded cycle that never left +/-0.05.
//
// Waiting for the correlation to go negative first is the standard fix and it is
// sound for every shape here: a zero-mean periodic signal is anti-correlated with
// itself somewhere inside the first cycle -- at a quarter period for a square, at
// half for a sine -- so the first peak after that crossing is the fundamental and
// not a fraction of it.
//
// The returned strength is that peak's height, and it is the statistic that does
// the real work: a shape that repeats scores near 1, and sample and hold, which
// has a period in its *timing* but not in its *values*, does not.
lfo_period :: proc(x: []f64, mean: f64, hi_lag: int) -> (period: f64, strength: f64, ok: bool) {
	limit := min(hi_lag, len(x) / 3)
	if limit < 8 {
		return 0, 0, false
	}

	// Walk out until the series is anti-correlated with itself.
	first_negative := -1
	for lag in 2 ..= limit {
		if lfo_autocorr(x, mean, lag) < 0 {
			first_negative = lag
			break
		}
	}
	// Never goes negative: nothing periodic in range.
	if first_negative < 0 {
		return 0, 0, false
	}

	best := -2.0
	for lag in first_negative ..= limit {
		c := lfo_autocorr(x, mean, lag)
		if c > best {
			best = c
		}
	}
	if best <= 0 {
		return 0, 0, false
	}

	// The first local peak that gets close to the best, rather than the best
	// itself. The distinction is not academic: the true period is rarely a whole
	// number of frames, so a lag some whole number of cycles out -- where the
	// fractional part happens to realign with the integer lag grid -- can correlate
	// *better* than the period does. Our own LFO at this setting runs at 4.623 Hz,
	// a period of 216.3 frames, and lag 1515 is 7.003 periods: taking the global
	// maximum read it as 0.66 Hz and folded a clean sine into alternating noise.
	threshold := best * 0.8
	best_lag := 0
	for lag in first_negative + 1 ..< limit {
		c := lfo_autocorr(x, mean, lag)
		if c < threshold {
			continue
		}
		if c >= lfo_autocorr(x, mean, lag - 1) && c >= lfo_autocorr(x, mean, lag + 1) {
			best_lag = lag
			break
		}
	}
	if best_lag <= 0 {
		return 0, 0, false
	}

	// Parabolic refinement, so the period is not quantised to whole frames. Folding
	// twenty-five cycles at a period rounded to the nearest frame smears the
	// waveform by a good fraction of a bucket.
	refined := f64(best_lag)
	{
		y0 := lfo_autocorr(x, mean, best_lag - 1)
		y1 := lfo_autocorr(x, mean, best_lag)
		y2 := lfo_autocorr(x, mean, best_lag + 1)
		denom := y0 - 2.0 * y1 + y2
		if abs(denom) > 1.0e-12 {
			delta := 0.5 * (y0 - y2) / denom
			if abs(delta) <= 1.0 {
				refined += delta
			}
		}
	}
	return refined, lfo_autocorr(x, mean, best_lag), true
}

// Average the series into one cycle of `buckets` points.
lfo_fold :: proc(x: []f64, period: f64, buckets: int) -> []f64 {
	cycle := make([]f64, buckets)
	counts := make([]int, buckets)
	defer delete(counts)
	if period <= 0 {
		return cycle
	}
	for v, i in x {
		phase := math.mod(f64(i) / period, 1.0)
		b := int(phase * f64(buckets))
		if b < 0 || b >= buckets {
			continue
		}
		cycle[b] += v
		counts[b] += 1
	}
	for b in 0 ..< buckets {
		if counts[b] > 0 {
			cycle[b] /= f64(counts[b])
		}
	}
	return cycle
}

// The five deterministic candidates, sampled at phase `t` on [0, 1).
//
// Inverting a triangle, a sine or a square is the same as shifting it half a
// cycle, so the phase search below covers those and they need no separate entry.
// A saw is the exception: no shift turns a descending ramp into an ascending one,
// so both directions are listed and the measurement gets to choose.
LFO_TEMPLATE_NAMES := []string{"saw down", "saw up", "triangle", "sine", "square"}

lfo_template_value :: proc(kind: int, t: f64) -> f64 {
	switch kind {
	case 0:
		return 1.0 - 2.0 * t
	case 1:
		return 2.0 * t - 1.0
	case 2:
		return 1.0 - 4.0 * abs(t - 0.5)
	case 3:
		return math.sin(2.0 * math.PI * t)
	case 4:
		return t < 0.5 ? 1.0 : -1.0
	}
	return 0
}

lfo_correlation :: proc(a, b: []f64) -> f64 {
	if len(a) != len(b) || len(a) == 0 {
		return 0
	}
	ma, mb := 0.0, 0.0
	for i in 0 ..< len(a) {
		ma += a[i]
		mb += b[i]
	}
	ma /= f64(len(a))
	mb /= f64(len(b))
	num, da, db := 0.0, 0.0, 0.0
	for i in 0 ..< len(a) {
		x := a[i] - ma
		y := b[i] - mb
		num += x * y
		da += x * x
		db += y * y
	}
	if da <= 0 || db <= 0 {
		return 0
	}
	return num / math.sqrt(da * db)
}

// The best-matching template for a folded cycle, over every phase alignment.
lfo_classify :: proc(cycle: []f64) -> (name: string, corr: f64) {
	buckets := len(cycle)
	if buckets == 0 {
		return "-", 0
	}
	probe := make([]f64, buckets)
	defer delete(probe)

	best := -2.0
	best_kind := 0
	for kind in 0 ..< len(LFO_TEMPLATE_NAMES) {
		for shift in 0 ..< buckets {
			for i in 0 ..< buckets {
				t := (f64((i + shift) % buckets) + 0.5) / f64(buckets)
				probe[i] = lfo_template_value(kind, t)
			}
			c := lfo_correlation(cycle, probe)
			if c > best {
				best = c
				best_kind = kind
			}
		}
	}
	return LFO_TEMPLATE_NAMES[best_kind], best
}

// The largest single-frame move, as a fraction of the series' whole range.
//
// This is what separates the two random states from each other. Sample and hold
// is piecewise constant and then jumps the whole way at once, so it has a step
// near 1; the smoothed random walks continuously and never does. Counting *flat*
// frames instead was tried and is useless at this frame rate -- a few-hertz LFO
// moves about a hundredth of its range per millisecond, so every shape is flat by
// any threshold loose enough to tolerate noise.
lfo_max_step :: proc(x: []f64, range: f64) -> f64 {
	if len(x) < 2 || range <= 0 {
		return 0
	}
	worst := 0.0
	for i in 1 ..< len(x) {
		d := abs(x[i] - x[i - 1])
		if d > worst {
			worst = d
		}
	}
	return worst / range
}

Lfo_Shape_Reading :: struct {
	ok:      bool,
	moving:  bool,
	hz:      f64,
	repeat:  f64,
	step:    f64,
	range:   f64,
	verdict: string,
	corr:    f64,
	cycle:   []f64,
}

// Classify one pan series.
lfo_read_shape :: proc(series: []f64) -> Lfo_Shape_Reading {
	r: Lfo_Shape_Reading

	// Trim the ends: the note's own onset and release are not the LFO.
	trim := max(len(series) / 20, 1)
	if len(series) < trim * 2 + 32 {
		return r
	}
	body := series[trim:len(series) - trim]

	mean, range := lfo_series_stats(body)
	r.range = range
	r.ok = true
	if range < LFO_SHAPE_MIN_RANGE {
		r.verdict = "inert"
		r.cycle = make([]f64, LFO_SHAPE_BUCKETS)
		return r
	}
	r.moving = true
	r.step = lfo_max_step(body, range)

	// Lags out to 0.5 Hz at this frame rate; the bottom of the range is set by
	// the autocorrelation's own first negative excursion rather than by a bound.
	frames_per_second := 1000.0 / LFO_SHAPE_FRAME_MS
	period, strength, found := lfo_period(body, mean, int(frames_per_second / 0.5))
	r.repeat = strength

	// A shape that does not repeat is one of the two random states, and the two
	// are told apart by whether it steps or walks.
	//
	// The threshold sits well below a real step because the reference slews its
	// edges rather than jumping: its *square* only manages 0.28 of its range in one
	// frame. What the two random states actually have between them is more than a
	// factor of twenty -- 0.25 against 0.01 -- so anything inside that gap works and
	// nothing near either end does.
	random_verdict :: proc(step: f64) -> string {
		return step > 0.10 ? "sample & hold" : "random smooth"
	}

	// No periodicity at all: still one of the two random states, and the step
	// statistic says which without needing a period.
	if !found {
		r.verdict = random_verdict(r.step)
		r.cycle = make([]f64, LFO_SHAPE_BUCKETS)
		return r
	}
	r.hz = frames_per_second / period
	r.cycle = lfo_fold(body, period, LFO_SHAPE_BUCKETS)

	if strength < 0.75 {
		r.verdict = random_verdict(r.step)
		r.corr = strength
		return r
	}
	r.verdict, r.corr = lfo_classify(r.cycle)
	return r
}

// Render one state through both engines and read the shape off each.
lfo_shape_measure :: proc(
	dll: string,
	pristine, work: []byte,
	shape, speed: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	note: u8,
	dumped: ^bool,
) -> (
	reference, ours: Lfo_Shape_Reading,
) {
	frame_len := int(LFO_SHAPE_FRAME_MS * 0.001 * f64(SAMPLE_RATE))
	p := lfo_shape_patch(shape, speed, shape_index, dest_index, speed_index,
		depth_index, on_index, keysync_index, temposync_index)
	dump_indices := []int{0, 5, 19, 29, shape_index, dest_index, speed_index, depth_index, on_index}

	ref_audio := probe_render(dll, &p, pristine, work, note, LFO_SHAPE_SECONDS, dumped, dump_indices)
	if ref_audio == nil {
		return
	}
	defer delete(ref_audio)

	// `probe_render` has set the timing globals, so this renders the same span.
	our_audio := render_ours(p, int(note))
	defer delete(our_audio)

	ref_series := lfo_observable(ref_audio, frame_len)
	defer delete(ref_series)
	our_series := lfo_observable(our_audio, frame_len)
	defer delete(our_series)
	if ref_series == nil || our_series == nil {
		return
	}

	reference = lfo_read_shape(ref_series)
	ours = lfo_read_shape(our_series)
	return
}

// The static pan control, read through the same instrument.
//
// This is a calibration, not a curiosity. Everything below compares the sign of
// two waveforms, and if the two engines disagreed about which way the pan control
// points then every shape would appear inverted and a saw would be "corrected"
// into the wrong direction. Reading a fixed hard-left patch through both says
// whether that risk is real before any of it is acted on.
lfo_shape_pan_check :: proc(dll: string, pristine, work: []byte, note: u8) {
	frame_len := int(LFO_SHAPE_FRAME_MS * 0.001 * f64(SAMPLE_RATE))

	report :: proc(label: string, audio: []f32, frame_len: int) -> f64 {
		series := pan_series(audio, frame_len)
		defer delete(series)
		if series == nil {
			return 0
		}
		mean, _ := lfo_series_stats(series)
		return mean
	}

	fmt.println("pan polarity check: parameter 90 hard left and hard right, LFO off")
	fmt.printfln("%10v %12v %12v", "param 90", "reference", "ours")
	for setting in ([]int{0, 127}) {
		p := neutral_probe_patch()
		set_param(&p, 0, 0)
		set_param(&p, 5, 0)
		set_param(&p, 19, 127)
		set_param(&p, 29, 110)
		set_param(&p, 90, setting)

		ref_audio := probe_render(dll, &p, pristine, work, note, 1.0, nil, nil)
		if ref_audio == nil {
			continue
		}
		our_audio := render_ours(p, int(note))
		label := setting == 0 ? "L 100%" : "R 100%"
		fmt.printfln("%10v %12v %12v", label,
			sdec3(report(label, ref_audio, frame_len)),
			sdec3(report(label, our_audio, frame_len)))
		delete(ref_audio)
		delete(our_audio)
	}
	fmt.println("  positive is more left. The two must agree in sign for the shapes below")
	fmt.println("  to be comparable at all.")
	fmt.println()
}

cmd_lfoshape :: proc(dll: string, param: int, spec: string, speed: int, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	is_lfo1 := param != 47
	shape_index := is_lfo1 ? 42 : 47
	dest_index := is_lfo1 ? 41 : 46
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	watching := g_lfo_shape_dest == 4 ? "volume, read as loudness in dB" : "pan, read as stereo position"
	fmt.printfln("lfoshape: parameter %v, destination %v (%v)",
		shape_index, g_lfo_shape_dest, watching)
	fmt.printfln("          depth %v, speed %v, note %v, %v s per render, %v ms frames, %v points per cycle",
		g_lfo_shape_depth, speed, note, int(LFO_SHAPE_SECONDS),
		int(LFO_SHAPE_FRAME_MS), LFO_SHAPE_BUCKETS)
	fmt.println()

	if g_lfo_shape_dest != 4 {
		lfo_shape_pan_check(dll, pristine, work, note)
	}

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	states := cpatch.parameter_states(shape_index)

	for v in values {
		reference, ours := lfo_shape_measure(dll, pristine, work, v, speed,
			shape_index, dest_index, speed_index, depth_index, on_index,
			keysync_index, temposync_index, note, &dumped)
		defer delete(reference.cycle)
		defer delete(ours.cycle)

		display := ""
		if v >= 0 && v < len(states) {
			display = states[v].display
		}
		fmt.printfln("stored %v, the state whose display reads %q", v, display)
		if !reference.ok || !ours.ok {
			fmt.println("  could not be measured")
			fmt.println()
			continue
		}

		line :: proc(label: string, r: Lfo_Shape_Reading) {
			fmt.printfln("  %-10v %8v Hz  repeat %v  step %v  range %v   -> %v (%v)",
				label, dec2(r.hz), dec3(r.repeat), dec2(r.step), dec2(r.range),
				r.verdict, dec3(r.corr))
		}
		line("reference", reference)
		line("ours", ours)

		if reference.moving && len(reference.cycle) == LFO_SHAPE_BUCKETS {
			fmt.printf("  ref cycle ")
			for b in 0 ..< LFO_SHAPE_BUCKETS {
				fmt.printf("%v", sdec2(reference.cycle[b], 6))
			}
			fmt.println()
		}
		if ours.moving && len(ours.cycle) == LFO_SHAPE_BUCKETS {
			fmt.printf("  our cycle ")
			for b in 0 ..< LFO_SHAPE_BUCKETS {
				fmt.printf("%v", sdec2(ours.cycle[b], 6))
			}
			fmt.println()
		}
		fmt.println()
		free_all(context.temp_allocator)
	}

	fmt.println("The folded cycles start at an arbitrary phase, so compare their shape and")
	fmt.println("their sign, not where they begin. A verdict is the best-correlating template")
	fmt.println("over every phase alignment; saw up and saw down are listed separately because")
	fmt.println("no shift turns one into the other.")
}
