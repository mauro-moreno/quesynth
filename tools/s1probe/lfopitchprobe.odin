// s1probe lfopitch - measure how far the LFO moves the pitch, using a square.
//
// `LFO_PITCH_SEMITONES` is the least trustworthy constant in the engine. It is
// the one depth `lfodepth` could not settle: at full depth it read 43.2, 42.3,
// 39.3 and 36.4 semitones at notes an octave and a half apart, and an LFO depth
// cannot depend on the note played. The value shipped is the lowest note's
// reading, on the reasoning that a truncated measurement can only read low, with
// the note-dependence recorded as unexplained.
//
//   s1probe lfopitch [dll] [--param 41|46] [--values <list|all>]
//                          [--notes <list>] [--rate <n>] [--dest <1|2>] [--dump]
//
// This measures it a different way, and the difference is the LFO's own shape.
// `lfodepth` leaves the shape at its default -- a triangle -- so the pitch is
// *sweeping* the whole time, and it recovers the range by tracking a moving tone
// across overlapping windows and taking a percentile band of the result. Two
// things go wrong with that, and between them they account for both the bias and
// the note-dependence:
//
//   - A percentile band is not a range. `span` discards the outer 5% at each end,
//     and a triangle distributes its pitch uniformly, so a full tenth of the
//     travel is thrown away before anything else happens.
//   - Tracking a swept tone costs resolution, and the cost is not the same at
//     every note. The window is 4096 points, and its bins are 11.7 Hz apart
//     whatever the note: at C5 that is 38 cents, and at C2 it is 290. The pitch
//     is also moving *within* each window, which smears the peak by an amount
//     that depends on how far the sweep travels per window.
//
// Setting the LFO to a square removes all of it. The pitch stops sweeping and
// becomes two steady values, so each can be measured with a long window at full
// precision, and the interval between them is the peak-to-peak depth by
// construction -- no percentile, no tracking, no assumption about the waveform's
// distribution. This measurement is only available now because `s1probe lfoshape`
// established which state the square actually is; the state this would have
// selected before that is sample and hold.
package s1probe

import "core:fmt"
import "core:math"

import cpatch "../../src/patch"

// The LFO shape state that measures as a square. See `lfoshape`.
LFO_PITCH_SHAPE_SQUARE :: 2

// Slow, so each half cycle comfortably outlasts the analysis window.
//
// Stored 44 is about 0.95 Hz, a half cycle of 526 ms against a 171 ms window, so
// a frame lands wholly inside one level unless it straddles an edge -- and the
// clustering below is built to discard the few that do.
LFO_PITCH_RATE :: 44
LFO_PITCH_SECONDS :: 8.0

// 171 ms at 48 kHz. Long enough that a bin is 5.9 Hz and parabolic interpolation
// on a clean sine resolves a fraction of that; short enough that several frames
// fit inside each half cycle.
LFO_PITCH_FFT :: 8192
LFO_PITCH_HOP :: 2048

lfo_pitch_patch :: proc(
	dest, depth, rate: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
) -> cpatch.Patch {
	p := neutral_probe_patch()

	if dest == 1 {
		// Oscillator 2 alone, so its own pitch is what the spectrum reports.
		// Oscillator 2 has no sine -- its four states are saw, pulse, triangle and
		// noise -- so this uses the triangle, whose harmonics fall as 1/n^2 and
		// whose fundamental therefore stays the strongest bin at any pitch.
		set_param(&p, 1, 3)
		set_param(&p, 5, 127)
	} else {
		// This destination moves both oscillators, so either will do, and
		// oscillator 1 has a real sine: one partial, nothing to mistake for it.
		set_param(&p, 0, 0)
		set_param(&p, 5, 0)
	}
	set_param(&p, 19, 127) // filter wide open
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

// The strongest spectral peak of one window, in hertz, parabolically refined.
//
// The refinement is on the log magnitude, which is the correct interpolation for
// a Gaussian-like main lobe and gets a Hann window's peak to a small fraction of
// a bin. Without it the answer is quantised to 5.9 Hz, which at a low note is
// tens of cents and would put this instrument back where the old one was.
lfo_pitch_peak_hz :: proc(x: []f32, from: int, re, im: []f64) -> (hz: f64, ok: bool) {
	n := LFO_PITCH_FFT
	if from < 0 || from + n > len(x) {
		return 0, false
	}
	for i in 0 ..< n {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
		re[i] = f64(x[from + i]) * w
		im[i] = 0
	}
	fft_forward(re, im)

	// Ignore the first few bins: DC and the window's own skirt sit there.
	best := 0.0
	best_k := 0
	for k in 3 ..< n / 2 {
		p := re[k] * re[k] + im[k] * im[k]
		if p > best {
			best = p
			best_k = k
		}
	}
	if best_k <= 0 || best <= 0 {
		return 0, false
	}

	mag :: proc(re, im: []f64, k: int) -> f64 {
		p := re[k] * re[k] + im[k] * im[k]
		return p > 1.0e-30 ? 0.5 * math.ln(p) : -69.0
	}
	y0 := mag(re, im, best_k - 1)
	y1 := mag(re, im, best_k)
	y2 := mag(re, im, best_k + 1)
	delta := 0.0
	denom := y0 - 2.0 * y1 + y2
	if abs(denom) > 1.0e-12 {
		d := 0.5 * (y0 - y2) / denom
		if abs(d) <= 1.0 {
			delta = d
		}
	}
	return (f64(best_k) + delta) * f64(SAMPLE_RATE) / f64(n), true
}

// The tracked pitch of every frame in the render.
lfo_pitch_series :: proc(audio: []f32) -> []f64 {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < LFO_PITCH_FFT * 2 {
		return nil
	}

	re := make([]f64, LFO_PITCH_FFT)
	defer delete(re)
	im := make([]f64, LFO_PITCH_FFT)
	defer delete(im)

	out: [dynamic]f64
	for from := 0; from + LFO_PITCH_FFT <= len(mid); from += LFO_PITCH_HOP {
		if hz, ok := lfo_pitch_peak_hz(mid, from, re, im); ok && hz > 0 {
			append(&out, hz)
		}
	}
	return out[:]
}

// Split a two-level series into its two levels.
//
// A square LFO puts its destination at one of two values and nowhere else, so the
// series is two tight clusters plus the handful of frames that straddle an edge.
// Splitting at the midpoint and taking the *median* of each side is what makes
// this immune to those frames: a straddling frame lands at the far edge of
// whichever cluster claims it, and a median does not care.
//
// This is the step that replaces `span`'s percentile band, and it is not the same
// idea. A percentile of a swept distribution is a guess about the waveform; a
// median of a plateau is the plateau.
//
// The split is arithmetic, so the caller passes whatever quantity is linear in
// the thing being measured -- log frequency for a pitch or a filter corner,
// decibels for a level, a signed fraction for a stereo position.
lfo_two_levels :: proc(series: []f64) -> (lo, hi: f64, ok: bool) {
	// Drop the note's own onset and release.
	trim := max(len(series) / 10, 1)
	if len(series) < trim * 2 + 8 {
		return 0, 0, false
	}
	body := series[trim:len(series) - trim]

	low := body[0]
	high := body[0]
	for v in body {
		if v < low {low = v}
		if v > high {high = v}
	}

	midpoint := 0.5 * (low + high)
	below: [dynamic]f64
	defer delete(below)
	above: [dynamic]f64
	defer delete(above)
	for v in body {
		if v < midpoint {
			append(&below, v)
		} else {
			append(&above, v)
		}
	}
	// Both levels have to be genuinely occupied, or this is not a square and the
	// answer would be an artefact of where the midpoint fell.
	if len(below) < 4 || len(above) < 4 {
		return 0, 0, false
	}

	median :: proc(v: []f64) -> f64 {
		s := make([]f64, len(v))
		defer delete(s)
		copy(s, v)
		for i in 1 ..< len(s) {
			x := s[i]
			j := i - 1
			for j >= 0 && s[j] > x {
				s[j + 1] = s[j]
				j -= 1
			}
			s[j + 1] = x
		}
		return s[len(s) / 2]
	}
	return median(below[:]), median(above[:]), true
}

// The two pitches of a square-modulated note, in hertz.
lfo_pitch_levels :: proc(series: []f64) -> (lo_hz, hi_hz: f64, ok: bool) {
	// Split in log frequency: the two levels are an interval apart, not a number
	// of hertz apart, so a midpoint in hertz would sit in the wrong place whenever
	// the interval is wide -- which here it always is.
	octaves := make([]f64, len(series))
	defer delete(octaves)
	for v, i in series {
		octaves[i] = v > 0 ? log2f(v) : -60.0
	}
	lo, hi, split := lfo_two_levels(octaves)
	if !split {
		return 0, 0, false
	}
	return math.pow(2.0, lo), math.pow(2.0, hi), true
}

// The lowest frequency this analysis can report, and the highest.
//
// Both are the instrument's own limits, not the plugin's, and a reading that
// lands on either is a bound rather than a measurement. Saying so explicitly is
// the whole reason this probe reports the two excursions separately: at any large
// depth the pair spans more than the ten octaves between them, so one side is
// always against a wall, and a "depth" computed as half the interval would fold
// that wall into the answer and look like a number.
LFO_PITCH_MIN_BIN :: 3
LFO_PITCH_FLOOR_HZ :: f64(LFO_PITCH_MIN_BIN) * f64(SAMPLE_RATE) / f64(LFO_PITCH_FFT)
LFO_PITCH_CEILING_HZ :: 0.45 * f64(SAMPLE_RATE)

Lfo_Pitch_Reading :: struct {
	ok:          bool,
	lo_hz:       f64,
	hi_hz:       f64,
	// The two excursions from the unmodulated note, in semitones. A square LFO
	// alternates between +1 and -1, so a symmetric depth puts these equal.
	up:          f64,
	down:        f64,
	// Set when that side of the sweep ran into the analysis limits above.
	up_bounded:  bool,
	down_bounded: bool,
}

lfo_pitch_read :: proc(audio: []f32, note: u8) -> Lfo_Pitch_Reading {
	r: Lfo_Pitch_Reading
	series := lfo_pitch_series(audio)
	defer delete(series)
	if series == nil {
		return r
	}
	lo, hi, ok := lfo_pitch_levels(series)
	if !ok {
		return r
	}
	// The pitch the note would sound at with the LFO switched off.
	base := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)

	r.lo_hz = lo
	r.hi_hz = hi
	r.up = 12.0 * log2f(hi / base)
	r.down = 12.0 * log2f(base / lo)
	r.up_bounded = hi >= LFO_PITCH_CEILING_HZ * 0.9
	r.down_bounded = lo <= LFO_PITCH_FLOOR_HZ * 1.05
	r.ok = true
	return r
}

// Measure one setting through both engines.
lfo_pitch_measure :: proc(
	dll: string,
	pristine, work: []byte,
	dest, depth, rate: int,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	note: u8,
	dumped: ^bool,
) -> (
	reference, ours: Lfo_Pitch_Reading,
) {
	p := lfo_pitch_patch(dest, depth, rate, shape_index, dest_index, speed_index,
		depth_index, on_index, keysync_index, temposync_index)
	dump_indices := []int{0, 1, 5, 19, 29, shape_index, dest_index, speed_index, depth_index, on_index}

	ref_audio := probe_render(dll, &p, pristine, work, note, LFO_PITCH_SECONDS, dumped, dump_indices)
	if ref_audio == nil {
		return
	}
	defer delete(ref_audio)
	our_audio := render_ours(p, int(note))
	defer delete(our_audio)

	reference = lfo_pitch_read(ref_audio, note)
	ours = lfo_pitch_read(our_audio, note)
	return
}

cmd_lfopitch :: proc(dll: string, param: int, spec: string, notes_spec: string, rate, dest: int, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	is_lfo1 := param != 46
	dest_index := is_lfo1 ? 41 : 46
	shape_index := is_lfo1 ? 42 : 47
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	depths := parse_env_values(spec)
	defer delete(depths)
	notes := parse_env_values(notes_spec)
	defer delete(notes)
	dumped := !dump

	fmt.printfln("lfopitch: parameter %v, destination %v (%v), square LFO at rate %v",
		depth_index, dest, dest == 1 ? "osc2 pitch" : "both pitches", rate)
	fmt.printfln("          %v s per render, %v-point window, two levels read as medians",
		int(LFO_PITCH_SECONDS), LFO_PITCH_FFT)
	fmt.println()
	fmt.printfln("Semitones from the unmodulated note, each way. This analysis can see %v Hz",
		dec1(LFO_PITCH_FLOOR_HZ))
	fmt.printfln("to %v Hz; a reading against either is marked * and is a bound, not a value.",
		dec0(LFO_PITCH_CEILING_HZ))
	fmt.println()

	mark :: proc(v: f64, bounded: bool) -> string {
		return pad_left(fmt.tprintf("%v%v", dec2(v), bounded ? "*" : " "), 9)
	}

	for note in notes {
		fmt.printfln("-- note %v --", note)
		fmt.printfln("%8v %10v %10v %9v %9v %9v %9v",
			"depth", "ref lo Hz", "ref hi Hz", "ref up", "ref down", "our up", "our down")
		for depth in depths {
			reference, ours := lfo_pitch_measure(
				dll, pristine, work, dest, depth, rate,
				shape_index, dest_index, speed_index, depth_index, on_index,
				keysync_index, temposync_index, u8(note), &dumped,
			)
			if !reference.ok {
				fmt.printfln("%8v %10v", depth, pad_left("-", 10))
				free_all(context.temp_allocator)
				continue
			}
			fmt.printfln("%8v %10v %10v %9v %9v %9v %9v",
				depth, dec2(reference.lo_hz), dec2(reference.hi_hz),
				mark(reference.up, reference.up_bounded),
				mark(reference.down, reference.down_bounded),
				ours.ok ? mark(ours.up, ours.up_bounded) : pad_left("-", 9),
				ours.ok ? mark(ours.down, ours.down_bounded) : pad_left("-", 9))
			free_all(context.temp_allocator)
		}
		fmt.println()
	}

	fmt.println("The `our` columns are the calibration, not a result: our engine applies")
	fmt.println("LFO_PITCH_SEMITONES exactly, so the instrument recovering that number on an")
	fmt.println("unbounded row is what says it is measuring what it claims. `up` and `down`")
	fmt.println("agreeing on those rows is what says the reference's law is symmetric.")
}
