// s1probe lfofm - how far the LFO moves the FM amount.
//
// The last chosen constant in the LFO loop. `voice_process` adds the LFO's output
// straight onto the FM index with a scaling of one, and says so: "the FM index is
// not a quantity the spectrum reports directly, so this stays at unity and is the
// one depth in this list still chosen rather than measured".
//
//   s1probe lfofm [dll] [--param 41|46] [--values <list|all>] [--base <n>]
//                       [--note <n>] [--rate <n>] [--dump]
//
// That objection is real but it is not fatal, and the way round it is the one this
// project has now used twice. An FM index has no unit the spectrum reports -- but
// **parameter 45 does**, because it is a knob whose settings can be rendered one at
// a time. So the spectrum does not have to yield an index; it only has to
// distinguish one setting of parameter 45 from another. Sweeping that knob with the
// LFO off calibrates the observable, and the LFO's own excursion is then read back
// in units of the knob it is modulating.
//
// The observable is the spectral centroid of the carrier, which is what FM moves:
// sidebands appear at multiples of the modulator's frequency and carry energy away
// from the fundamental, so the centre of mass climbs monotonically with the index.
// It is the same instrument the cutoff sweep ended up using, for the same reason --
// an average over the whole spectrum rather than a feature located within it.
package s1probe

import "core:fmt"
import "core:os"

import cpatch "../../src/patch"

// The FM sweep is read through the same long windows as the cutoff, so it needs
// the same very slow LFO for a window to sit inside one half of the square.
LFO_FM_RATE :: 8
LFO_FM_SECONDS :: 40.0
LFO_FM_CAL_SECONDS :: 4.0
LFO_FM_CAL_STEP :: 4

// Where parameter 45 sits while the LFO modulates it.
//
// Mid range by default, and that is the setting that decides the polarity
// question. The cutoff and the volume both turned out to modulate in one direction
// only; if FM does the same, the low half of the square will sit on this value
// whatever the depth, and if it is bipolar the low half will fall below it.
g_lfo_fm_base := 64

lfo_fm_patch :: proc(
	base_fm, depth, rate: int,
	lfo_on: bool,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
) -> cpatch.Patch {
	p := neutral_probe_patch()

	// A sine carrier alone, so the only thing in the spectrum is what FM put
	// there. Oscillator 2 is the modulator and is not mixed into the output; it
	// has no sine of its own, so it gets the triangle, whose own harmonics fall
	// as 1/n^2 and so contribute least to the sidebands' spread.
	set_param(&p, 0, 0) // osc1: sine, the carrier
	set_param(&p, 1, 3) // osc2: triangle, the modulator
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 6, 0) // no sync
	set_param(&p, 7, 0) // ring off: the manual is explicit that ring beats FM
	set_param(&p, 19, 127) // filter wide open, so nothing shapes the sidebands
	set_param(&p, 29, 110)
	set_param(&p, 45, base_fm)

	set_param(&p, on_index, lfo_on ? 1 : 0)
	set_param(&p, dest_index, 6) // FM amount
	set_param(&p, shape_index, LFO_PITCH_SHAPE_SQUARE)
	set_param(&p, speed_index, rate)
	set_param(&p, depth_index, depth)
	set_param(&p, keysync_index, 1)
	set_param(&p, temposync_index, 0)
	return p
}

// Sweep parameter 45 with the LFO off and record where the centroid goes.
//
// The result is inverted later, so all that matters is that it is monotonic; where
// it stops climbing the knob has stopped doing anything the spectrum can see, and
// a flat calibration says so instead of hiding it.
lfo_fm_calibrate :: proc(
	dll: string,
	pristine, work: []byte,
	shape_index, dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	note: u8,
) -> Lfo_Square_Calibration {
	cal: Lfo_Square_Calibration
	for v := 0; v < 128; v += LFO_FM_CAL_STEP {
		p := lfo_fm_patch(v, 0, LFO_FM_RATE, false, shape_index, dest_index,
			speed_index, depth_index, on_index, keysync_index, temposync_index)
		audio := probe_render(dll, &p, pristine, work, note, LFO_FM_CAL_SECONDS, nil, nil)
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
		if len(cal.centroid) > 0 && c <= cal.centroid[len(cal.centroid) - 1] {
			continue
		}
		append(&cal.centroid, c)
		// Kept in the knob's own normalised units, which is what the engine's
		// `osc1_fm` is: stored / 127.
		append(&cal.value, f64(v) / 127.0)
		free_all(context.temp_allocator)
	}
	return cal
}

cmd_lfofm :: proc(dll: string, param: int, spec: string, note: u8, rate: int, dump: bool) {
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

	use_rate := rate > 0 ? rate : LFO_FM_RATE
	depths := parse_env_values(spec)
	defer delete(depths)
	dumped := !dump

	fmt.printfln("lfofm: parameter %v driving the FM amount, square LFO at rate %v, note %v",
		depth_index, use_rate, note)
	fmt.printfln("       parameter 45 held at %v (%v of full) while the LFO moves it",
		g_lfo_fm_base, dec3(f64(g_lfo_fm_base) / 127.0))
	fmt.println()

	cal := lfo_fm_calibrate(dll, pristine, work, shape_index, dest_index, speed_index,
		depth_index, on_index, keysync_index, temposync_index, note)
	defer delete(cal.centroid)
	defer delete(cal.value)
	if len(cal.centroid) < 4 {
		fmt.eprintln("lfofm: the FM calibration did not resolve")
		os.exit(1)
	}
	fmt.printfln("calibration: %v monotonic points, parameter 45 from %v to %v of full",
		len(cal.centroid), dec3(cal.value[0]), dec3(cal.value[len(cal.value) - 1]))
	fmt.println()

	base := f64(g_lfo_fm_base) / 127.0
	fmt.printfln("%8v %11v %11v %10v %10v %10v",
		"depth", "lo (p45)", "hi (p45)", "up", "down", "ours up")
	for depth in depths {
		p := lfo_fm_patch(g_lfo_fm_base, depth, use_rate, true, shape_index, dest_index,
			speed_index, depth_index, on_index, keysync_index, temposync_index)
		dump_indices := []int{0, 1, 5, 7, 19, 29, 45, shape_index, dest_index, speed_index, depth_index, on_index}
		ref_audio := probe_render(dll, &p, pristine, work, note, LFO_FM_SECONDS, &dumped, dump_indices)
		if ref_audio == nil {
			continue
		}
		our_audio := render_ours(p, int(note))

		read :: proc(audio: []f32, cal: ^Lfo_Square_Calibration) -> (lo, hi: f64, ok: bool) {
			series := lfo_square_centroid_series(audio)
			defer delete(series)
			if len(series) < 16 {
				return 0, 0, false
			}
			// By phase, not by value: the same bias that manufactured cutoff
			// modulation out of a noisy corner applies to any observable read off a
			// square, and is avoided the same way.
			lo_c, hi_c, split := lfo_levels_by_phase(series)
			if !split {
				return 0, 0, false
			}
			lo_v, lo_ok := lfo_square_invert(cal, lo_c)
			hi_v, hi_ok := lfo_square_invert(cal, hi_c)
			return lo_v, hi_v, lo_ok && hi_ok
		}

		lo, hi, ok := read(ref_audio, &cal)
		our_lo, our_hi, our_ok := read(our_audio, &cal)
		delete(ref_audio)
		delete(our_audio)

		if !ok {
			fmt.printfln("%8v %11v", depth, pad_left("-", 11))
			free_all(context.temp_allocator)
			continue
		}
		fmt.printfln("%8v %11v %11v %10v %10v %10v",
			depth, dec3(lo), dec3(hi), sdec3(hi - base), sdec3(base - lo),
			our_ok ? sdec3(our_hi - base) : "-")
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("Both columns are in parameter 45's own normalised units, which is what")
	fmt.println("`osc1_fm` carries. `up` and `down` differing says the modulation is not")
	fmt.println("symmetric; `down` pinned at zero across the sweep says it is one-directional,")
	fmt.println("which is what the cutoff and volume destinations both turned out to be.")
}
