package s1probe

// The compressor's static curve: threshold, ratio and makeup, measured.
//
// Everything else in the effect unit was named from what it does to a pure tone,
// and that was enough for nine of the ten types. It is not enough for `comp.`.
// A compressor adds no harmonics -- that is what identified it in the first
// place -- so a single tone at a single level says nothing about where the knee
// sits or how hard it bends. The existing readings show exactly that shape of
// gap: `fxcompare` scores the compressor at 0.87 dB of spectral error, better
// than the section's own floor, and 15.19 dB of envelope error. The timbre is
// right and the dynamics are not.
//
// The instrument for a dynamics processor is a level sweep. Hold the same tone,
// move the level going in, and read the level coming out once it has settled:
//
//   below the threshold   out follows in, one for one
//   above it              out rises by 1/ratio for every dB in
//   the offset between    the makeup gain
//
// The drive is moved with `amp gain` (parameter 29), and the input level is not
// assumed from it: every point renders the same patch twice, once with the unit
// off, and the off render *is* the measurement of what arrived. That matters
// because amp gain's own curve is a measured table with a shape of its own, and
// a curve fitted against a knob position rather than against a level would carry
// that shape into the answer.
//
// Both sides are rendered in the same process, the reference through the DLL and
// ours through the statically linked engine, so the two columns are matched and
// not merely comparable.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import cpatch "../../src/patch"

// The compressor's state in parameter 78.
FX_COMP_STATE :: 5

// Where the settled level is read from, as a fraction into the held note.
//
// The attack reaches 190 ms at the top of ctl2 and the note is held for 1.5 s,
// so two thirds in is clear of the slowest attack by more than three times its
// own length. Reading a compressor's steady state inside its attack is how a
// ratio gets measured as the transient it has not finished removing yet.
COMP_SETTLED_FROM :: 0.66

// Below this the render is treated as silence rather than as a measurement.
// Amp gain reaches the bottom of its range before the sweep does.
COMP_FLOOR_DB :: -90.0

comp_settled_rms_db :: proc(audio: []f32) -> (db: f64, ok: bool) {
	if len(audio) == 0 {
		return COMP_FLOOR_DB, false
	}
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)

	held := min(g_hold_frames, len(mid))
	from := int(f64(held) * COMP_SETTLED_FROM)
	if held-from < 64 {
		return COMP_FLOOR_DB, false
	}

	sum := 0.0
	for v in mid[from:held] {
		sum += f64(v) * f64(v)
	}
	rms := math.sqrt(sum / f64(held - from))
	if rms <= 0 {
		return COMP_FLOOR_DB, false
	}
	db = amplitude_db(rms)
	return db, db > COMP_FLOOR_DB
}

comp_curve_patch :: proc(on: bool, ctl1, ctl2, level, amp_gain: int) -> cpatch.Patch {
	p := fx_probe_patch(on, FX_COMP_STATE, ctl1, ctl2, level)
	set_param(&p, 29, amp_gain)
	return p
}

Comp_Point :: struct {
	amp_gain:                   int,
	ref_in, ref_out, ref_gain:  f64,
	our_in, our_out, our_gain:  f64,
	ref_ok, our_ok:             bool,
}

// Depth doubles as a fine level control.
//
// The sweep's resolution in level is otherwise the amp gain knob's own spacing,
// which is nearly 4 dB apart at the bottom of its range and lands only three
// points inside the knee. Depth moves the level entering the leveller by
// 40/127 dB per step, so sweeping it at a fixed amp gain fills the gaps at
// 0.315 dB -- and does it *because* the collapse below has been established
// rather than assuming it: every depth is also an independent check that the
// same curve is being measured.
cmd_compcurve :: proc(
	dll: string,
	ctl1, ctl2, level, note: int,
	gains: []int,
	csv_path: string,
	depths: []int = nil,
) {
	if len(depths) > 1 {
		for d, i in depths {
			path := csv_path
			if path != "" {
				path = fmt.tprintf("%s.d%d.csv", csv_path, d)
			}
			if i > 0 {fmt.println()}
			cmd_compcurve(dll, d, ctl2, level, note, gains, path)
		}
		return
	}

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(FX_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	fmt.printfln(
		"compressor static curve: ctl1=%d (depth) ctl2=%d (attack) level=%d, note %d",
		ctl1,
		ctl2,
		level,
		note,
	)
	fmt.println("  in and out are settled RMS in dBFS; gain is out minus in, which is the curve")
	fmt.println("  amp     ref in   ref out  ref gain    our in   our out  our gain     error")

	points := make([dynamic]Comp_Point, 0, len(gains))
	defer delete(points)

	for g in gains {
		pt := Comp_Point{amp_gain = g}

		p_off := comp_curve_patch(false, ctl1, ctl2, level, g)
		p_on := comp_curve_patch(true, ctl1, ctl2, level, g)

		ref_off, _, off_ok := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
		defer delete(ref_off)
		ref_on, _, on_ok := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
		defer delete(ref_on)
		if !off_ok || !on_ok {
			fmt.eprintfln("compcurve: the reference would not render at amp gain %d", g)
			continue
		}

		ours_off := render_ours(p_off, note)
		defer delete(ours_off)
		ours_on := render_ours(p_on, note)
		defer delete(ours_on)

		ref_in, ref_in_ok := comp_settled_rms_db(ref_off)
		ref_out, ref_out_ok := comp_settled_rms_db(ref_on)
		our_in, our_in_ok := comp_settled_rms_db(ours_off)
		our_out, our_out_ok := comp_settled_rms_db(ours_on)

		pt.ref_in, pt.ref_out = ref_in, ref_out
		pt.our_in, pt.our_out = our_in, our_out
		pt.ref_ok = ref_in_ok && ref_out_ok
		pt.our_ok = our_in_ok && our_out_ok
		if pt.ref_ok {pt.ref_gain = ref_out - ref_in}
		if pt.our_ok {pt.our_gain = our_out - our_in}

		append(&points, pt)

		err := "     n/a"
		if pt.ref_ok && pt.our_ok {
			err = sdec2(pt.our_gain - pt.ref_gain, 8)
		}
		fmt.printfln(
			"  %s  %s  %s  %s  %s  %s  %s  %s",
			pad_left(fmt.tprintf("%d", g), 3),
			pad_left(pt.ref_ok ? dec2(ref_in) : "n/a", 8),
			pad_left(pt.ref_ok ? dec2(ref_out) : "n/a", 8),
			pad_left(pt.ref_ok ? sdec2(pt.ref_gain) : "n/a", 8),
			pad_left(pt.our_ok ? dec2(our_in) : "n/a", 8),
			pad_left(pt.our_ok ? dec2(our_out) : "n/a", 8),
			pad_left(pt.our_ok ? sdec2(pt.our_gain) : "n/a", 8),
			err,
		)
	}

	// The two summary numbers worth having by eye: how far apart the two curves
	// are on average, and where they are furthest apart. A mean alone hides a
	// curve that is right everywhere except across the knee, which is the one
	// place a compressor's shape actually lives.
	sum, worst := 0.0, 0.0
	worst_gain := -1
	counted := 0
	for pt in points {
		if !pt.ref_ok || !pt.our_ok {continue}
		d := abs(pt.our_gain - pt.ref_gain)
		sum += d
		counted += 1
		if d > worst {
			worst = d
			worst_gain = pt.amp_gain
		}
	}
	if counted > 0 {
		fmt.printfln(
			"  mean |error| %.2f dB over %d points, worst %.2f dB at amp gain %d",
			sum / f64(counted),
			counted,
			worst,
			worst_gain,
		)
	}

	if csv_path != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintln(
			&b,
			"ctl1,ctl2,level,note,amp_gain,ref_in_db,ref_out_db,ref_gain_db,ref_ok,our_in_db,our_out_db,our_gain_db,our_ok",
		)
		for pt in points {
			fmt.sbprintfln(
				&b,
				"%d,%d,%d,%d,%d,%.6f,%.6f,%.6f,%v,%.6f,%.6f,%.6f,%v",
				ctl1,
				ctl2,
				level,
				note,
				pt.amp_gain,
				pt.ref_in,
				pt.ref_out,
				pt.ref_gain,
				pt.ref_ok,
				pt.our_in,
				pt.our_out,
				pt.our_gain,
				pt.our_ok,
			)
		}
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("compcurve: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}

// -------------------------------------------------- the gain trajectory

// The dynamics, read as the gain itself rather than as the level.
//
// The static curve above settles the shape; it says nothing about how fast the
// gain gets there, and the envelope error is the larger half of what is wrong
// with this type. The obvious instrument -- watch the output level and time the
// overshoot -- confounds two things, because the level moving is the input moving
// *and* the gain moving.
//
// Dividing them apart is exact and needs no model of either. Render the same
// patch twice, once with the unit off, and the ratio frame by frame is the gain
// the unit applied, with the note's own envelope cancelled out of it. Both sides
// of the comparison get the same treatment, so the columns are matched even where
// the underlying amplifier envelopes are not identical.
//
// The step down that a release needs comes from the amplifier's own decay: attack
// at zero and a sustain below full scale drops the level once, cleanly, in the
// middle of a held note. A note-off would not do -- there is no signal left to
// measure the recovery on.
cmd_comptrace :: proc(
	dll: string,
	ctl1, ctl2, level, note, amp_gain, decay, sustain: int,
	step_ms: f64,
	csv_path: string,
) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(FX_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	shape :: proc(p: ^cpatch.Patch, decay, sustain, amp_gain: int) {
		set_param(p, 25, 0) // amp attack: immediate, so the step is the note itself
		set_param(p, 26, decay)
		set_param(p, 27, sustain)
		set_param(p, 29, amp_gain)
	}

	p_off := fx_probe_patch(false, FX_COMP_STATE, ctl1, ctl2, level)
	p_on := fx_probe_patch(true, FX_COMP_STATE, ctl1, ctl2, level)
	shape(&p_off, decay, sustain, amp_gain)
	shape(&p_on, decay, sustain, amp_gain)

	ref_off, _, ok1 := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
	defer delete(ref_off)
	ref_on, _, ok2 := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
	defer delete(ref_on)
	if !ok1 || !ok2 {
		fmt.eprintln("comptrace: the reference would not render")
		os.exit(1)
	}
	ours_off := render_ours(p_off, note)
	defer delete(ours_off)
	ours_on := render_ours(p_on, note)
	defer delete(ours_on)

	trace :: proc(off, on: []f32, frame: int) -> (gain_db, in_db: []f64) {
		mo, so := split_mid_side(off, 2)
		defer delete(mo)
		defer delete(so)
		mn, sn := split_mid_side(on, 2)
		defer delete(mn)
		defer delete(sn)
		held := min(g_hold_frames, min(len(mo), len(mn)))
		a := frame_envelope(mo[:held], frame)
		defer delete(a)
		b := frame_envelope(mn[:held], frame)
		defer delete(b)
		n := min(len(a), len(b))
		gain_db = make([]f64, n)
		in_db = make([]f64, n)
		for i in 0 ..< n {
			gain_db[i] = a[i] > 0 && b[i] > 0 ? amplitude_db(b[i] / a[i]) : 0
			in_db[i] = a[i] > 0 ? amplitude_db(a[i]) : COMP_FLOOR_DB
		}
		return
	}

	frame := max(1, int(step_ms * f64(SAMPLE_RATE) / 1000.0))
	ref_gain, ref_in := trace(ref_off, ref_on, frame)
	defer delete(ref_gain)
	defer delete(ref_in)
	our_gain, our_in := trace(ours_off, ours_on, frame)
	defer delete(our_gain)
	defer delete(our_in)

	n := min(len(ref_gain), len(our_gain))
	fmt.printfln(
		"compressor gain trajectory: ctl1=%d ctl2=%d level=%d note=%d amp=%d decay=%d sustain=%d",
		ctl1,
		ctl2,
		level,
		note,
		amp_gain,
		decay,
		sustain,
	)
	fmt.printfln("  every %.1f ms; gain is the unit on divided by the unit off, in dB", step_ms)
	fmt.println("     ms     in dB   ref gain  our gain     error")

	sum, worst, worst_at := 0.0, 0.0, 0.0
	for i in 0 ..< n {
		t := f64(i) * step_ms
		d := our_gain[i] - ref_gain[i]
		sum += abs(d)
		if abs(d) > worst {
			worst = abs(d)
			worst_at = t
		}
		// Printed thinned, because a millisecond grid over a second and a half is
		// more rows than anyone reads; every row still counts toward the summary.
		if i % 10 == 0 {
			fmt.printfln(
				"  %s  %s  %s  %s  %s",
				pad_left(fmt.tprintf("%.0f", t), 5),
				pad_left(dec2(ref_in[i]), 8),
				pad_left(sdec2(ref_gain[i]), 9),
				pad_left(sdec2(our_gain[i]), 9),
				pad_left(sdec2(d), 9),
			)
		}
	}
	if n > 0 {
		fmt.printfln(
			"  mean |error| %.2f dB over %d frames, worst %.2f dB at %.0f ms",
			sum / f64(n),
			n,
			worst,
			worst_at,
		)
	}

	if csv_path != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintln(&b, "ms,in_db,ref_gain_db,our_gain_db")
		for i in 0 ..< n {
			fmt.sbprintfln(
				&b,
				"%.3f,%.6f,%.6f,%.6f",
				f64(i) * step_ms,
				ref_in[i],
				ref_gain[i],
				our_gain[i],
			)
		}
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("comptrace: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}
