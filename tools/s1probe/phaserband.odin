package s1probe

// What the phasers' depth control actually does, measured without a spectrum.
//
// The swept band is the one reading in this section that was never finished, and
// the reason is visible in the numbers it produced:
//
//   ctl1        0     16     32     64     96    127
//   band     2800   2923   3057   3304    131    131   Hz
//            2800   6839   7781  10465  10465  10465
//
// 131 Hz and 10465 Hz are not the sweep's edges. They are the saw probe's own:
// its fundamental is 130.8 Hz and it uses eighty harmonics, so 131 and 10465 are
// the lowest and the highest frequencies that instrument can see at all. Above
// ctl1 32 the resonance leaves it, and every reading after that is the window
// reporting its own size.
//
// Widening the window does not fix it. Harmonics have to be resolvable, so a
// lower fundamental needs a longer FFT, and a longer FFT smears a corner that is
// moving -- the two requirements pull against each other, and a sweep is exactly
// the case where both bite at once.
//
// So drop the spectrum. A resonance passing over a tone announces itself in that
// tone's own level: the response at the corner is about +24 dB and the skirt
// below it is -13 dB, so a single sine held at frequency f rises by that much,
// briefly, once per sweep -- but only if the corner reaches f at all. Sweeping f
// and asking whether the peak ever arrives maps the swept band directly, at a
// resolution set by the spacing of the notes and by nothing else.
//
// Reading the *peak* of the ratio rather than its mean is what makes it robust.
// A mean confounds the band with how long the corner dwells near f, and the dwell
// is weighted heavily toward the turning points of a sinusoidal sweep.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

// Enough of a render to hold several complete sweeps. Settable, because how long
// "several" is depends entirely on the rate being swept at.
g_phaser_band_seconds := 3.0

// The ratio is read in frames, and the frame has to suit both ends of a sweep
// spanning nine octaves: long enough to hold a few periods of the note being
// measured, short enough to resolve the corner passing over it.
phaser_band_frame :: proc(f0: f64) -> int {
	periods := 3.0 / f0
	return max(1, int(max(0.008, periods) * f64(SAMPLE_RATE)))
}

Phaser_Band_Row :: struct {
	note:         int,
	hz:           f64,
	ref_peak_db:  f64,
	ref_floor_db: f64,
	our_peak_db:  f64,
	our_floor_db: f64,
	ok:           bool,
}

// The on/off ratio in decibels, frame by frame, with the note's own level and
// envelope divided out. Returned as a high and a low percentile rather than a
// maximum and a minimum: one bad frame at a sweep's turning point should not
// decide where a band edge is.
phaser_band_extremes :: proc(off, on: []f32, frame: int) -> (peak, floor: f64, ok: bool) {
	if off == nil || on == nil {
		return 0, 0, false
	}
	mo, so := split_mid_side(off, 2)
	defer delete(mo)
	defer delete(so)
	mn, sn := split_mid_side(on, 2)
	defer delete(mn)
	defer delete(sn)

	held := min(g_hold_frames, min(len(mo), len(mn)))
	if held < frame * 8 {
		return 0, 0, false
	}
	a := frame_envelope(mo[:held], frame)
	defer delete(a)
	b := frame_envelope(mn[:held], frame)
	defer delete(b)

	n := min(len(a), len(b))
	// The first frames are the amplifier's attack, not the sweep.
	from := n / 8
	ratios := make([dynamic]f64, 0, n)
	defer delete(ratios)
	for i in from ..< n {
		if a[i] > 0 && b[i] > 0 {
			append(&ratios, amplitude_db(b[i] / a[i]))
		}
	}
	if len(ratios) < 8 {
		return 0, 0, false
	}
	slice.sort(ratios[:])
	// The high end is a near-maximum, not a comfortable percentile. The question
	// this instrument answers is whether the corner ever reaches this note, and a
	// corner sweeping past spends very few frames over any one of them -- at the
	// 95th percentile a real peak that is genuinely there reads as a miss.
	return ratios[len(ratios) - 1 - len(ratios) / 64], ratios[len(ratios) * 5 / 100], true
}

cmd_phaserband :: proc(
	dll: string,
	type_state, ctl1, ctl2, level: int,
	notes: []int,
	csv_path: string,
) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(g_phaser_band_seconds * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"phaser swept band: %s (state %d) ctl1=%d ctl2=%d level=%d",
		name,
		type_state,
		ctl1,
		ctl2,
		level,
	)
	fmt.println("  one held sine per row; peak and floor are the unit on over the unit off, in dB")
	fmt.println("  note      Hz    ref peak  ref floor   our peak  our floor")

	rows := make([dynamic]Phaser_Band_Row, 0, len(notes))
	defer delete(rows)

	for note in notes {
		hz := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
		row := Phaser_Band_Row {
			note = note,
			hz   = hz,
		}

		p_off := fx_probe_patch(false, type_state, ctl1, ctl2, level)
		p_on := fx_probe_patch(true, type_state, ctl1, ctl2, level)

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

		frame := phaser_band_frame(hz)
		rp, rf, rok := phaser_band_extremes(ref_off, ref_on, frame)
		op, of, ook := phaser_band_extremes(ours_off, ours_on, frame)
		row.ref_peak_db, row.ref_floor_db = rp, rf
		row.our_peak_db, row.our_floor_db = op, of
		row.ok = rok && ook
		append(&rows, row)

		fmt.printfln(
			"  %s  %s  %s  %s  %s  %s",
			pad_left(fmt.tprintf("%d", note), 4),
			pad_left(dec0(hz), 6),
			pad_left(rok ? sdec2(rp) : "n/a", 9),
			pad_left(rok ? sdec2(rf) : "n/a", 10),
			pad_left(ook ? sdec2(op) : "n/a", 10),
			pad_left(ook ? sdec2(of) : "n/a", 10),
		)
	}

	// The band, read off the peaks: the corner reaches a note if that note ever
	// sees something close to the resonance's own height. The threshold is
	// referenced to the tallest peak in this sweep rather than to an absolute
	// figure, so it does not assume the height the shape measurement gave.
	tallest := -1000.0
	for r in rows {
		if r.ok && r.ref_peak_db > tallest {
			tallest = r.ref_peak_db
		}
	}
	if tallest > -1000 {
		PHASER_BAND_EDGE_DB :: 6.0
		lo, hi := 0.0, 0.0
		for r in rows {
			if !r.ok || r.ref_peak_db < tallest - PHASER_BAND_EDGE_DB {
				continue
			}
			if lo == 0 {
				lo = r.hz
			}
			hi = r.hz
		}
		if lo > 0 {
			fmt.printfln(
				"  reference: tallest %+.2f dB, band %.0f..%.0f Hz within %.0f dB of it, %.2f octaves",
				tallest,
				lo,
				hi,
				PHASER_BAND_EDGE_DB,
				math.log2(hi / lo),
			)
		}
	}

	if csv_path != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintln(
			&b,
			"type,ctl1,ctl2,level,note,hz,ref_peak_db,ref_floor_db,our_peak_db,our_floor_db,ok",
		)
		for r in rows {
			fmt.sbprintfln(
				&b,
				"%d,%d,%d,%d,%d,%.4f,%.6f,%.6f,%.6f,%.6f,%v",
				type_state,
				ctl1,
				ctl2,
				level,
				r.note,
				r.hz,
				r.ref_peak_db,
				r.ref_floor_db,
				r.our_peak_db,
				r.our_floor_db,
				r.ok,
			)
		}
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("phaserband: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}
