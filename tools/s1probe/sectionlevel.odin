package s1probe

// Which section is spending the level, on one patch.
//
// The bank run reports a patch's level error as one number, and for the patches
// where that number is large the number itself says nothing about where it comes
// from. `016.sy1` reads +2.38 dB, and its post chain has three things in it that
// can each move a level: the equaliser, the delay and the chorus.
//
// A patch is not a fixed thing, though: every parameter of it can be set, in both
// engines at once, from the same code path the bank run uses. So the question is
// answerable by subtraction. Render the patch with each section switched out and
// read what the level error does. The section that carries the error is the one
// whose removal takes it away.
//
// The equaliser has no switch, so it is neutralised instead: tone and level to
// the centre of their ranges, which is where the manual puts flat.

import "core:fmt"
import "core:os"
import cpatch "../../src/patch"

SECTION_DELAY_ON :: 65
SECTION_CHORUS_ON :: 66
SECTION_EQ_TONE :: 60
SECTION_EQ_LEVEL :: 62

Section_Case :: struct {
	name:   string,
	delay:  bool,
	chorus: bool,
	eq:     bool,
}

// The same subtraction, against one parameter instead of the three sections:
// set it to each of a list of values in both engines and watch what the level
// error does. A parameter the error does not depend on leaves it flat.
cmd_paramlevel :: proc(dll: string, path: string, param: int, values: []int, note, block: int, presets: []int) {
	set_compare_timing(block)
	base: cpatch.Patch
	// "-" reads the probe's own neutral patch instead of a file, so a control can
	// be measured without a factory patch's filter and equaliser in front of it.
	if path == "-" {
		base = neutral_probe_patch()
		set_param(&base, 19, 127) // filter wide open
		set_param(&base, 29, 100) // amp gain short of the top, so nothing clips
	} else {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			fmt.eprintfln("paramlevel: cannot read %s: %v", path, read_err)
			return
		}
		defer delete(data, context.allocator)
		parse_err: cpatch.Sy1_Error
		base, parse_err = cpatch.parse_sy1(data)
		if parse_err != .None {
			fmt.eprintfln("paramlevel: cannot parse %s: %v", path, parse_err)
			return
		}
	}
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	fmt.printfln("parameter %d on %s, note %d", param, path, path == "-" ? "the neutral probe patch" : path)
	fmt.println("  value    ref rms    our rms     level      spectral")
	for v in values {
		p := base
		// Anything held fixed for the sweep, so one control can be read without
		// the others moving underneath it.
		for i := 0; i + 1 < len(presets); i += 2 {
			set_param(&p, presets[i], presets[i + 1])
		}
		set_param(&p, param, v)
		ref, _, ok1 := render_reference_fresh(dll, &p, pristine, work, u8(note))
		defer delete(ref)
		if !ok1 {continue}
		ours := render_ours(p, note)
		defer delete(ours)
		cmp := compare_renders(ref, ours, 2, f64(SAMPLE_RATE), f64(g_hold_frames) / f64(SAMPLE_RATE))
		fmt.printfln(
			"  %s  %s   %s   %s dB   %s dB",
			pad_left(fmt.tprintf("%d", v), 5),
			pad_left(fmt.tprintf("%.5f", cmp.ref_steady_rms), 8),
			pad_left(fmt.tprintf("%.5f", cmp.our_steady_rms), 8),
			pad_left(sdec2(cmp.level_db), 7),
			pad_left(cmp.spectral_valid ? dec2(cmp.spectral_db) : "  n/a", 6),
		)
	}
}

cmd_sectionlevel :: proc(dll: string, path: string, note: int, block: int) {
	set_compare_timing(block)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("sectionlevel: cannot read %s: %v", path, read_err)
		return
	}
	// parse_sy1 borrows out of `data`, so the buffer has to outlive the patch.
	defer delete(data, context.allocator)
	base, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("sectionlevel: cannot parse %s: %v", path, parse_err)
		return
	}

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	cases := []Section_Case {
		{"everything on", true, true, true},
		{"delay off", false, true, true},
		{"chorus off", true, false, true},
		{"equaliser flat", true, true, false},
		{"all three out", false, false, false},
	}

	fmt.printfln("section level: %s, note %d", path, note)
	fmt.println("  level is ours minus the reference, so a section that is not the")
	fmt.println("  culprit leaves it where it was when it is taken out")
	fmt.println("  case                 ref rms    our rms     level      spectral")

	for c in cases {
		p := base
		if !c.delay {set_param(&p, SECTION_DELAY_ON, 0)}
		if !c.chorus {set_param(&p, SECTION_CHORUS_ON, 0)}
		if !c.eq {
			set_param(&p, SECTION_EQ_TONE, 64)
			set_param(&p, SECTION_EQ_LEVEL, 64)
		}

		ref, _, ok1 := render_reference_fresh(dll, &p, pristine, work, u8(note))
		defer delete(ref)
		if !ok1 {
			fmt.printfln("  %s   render failed", c.name)
			continue
		}
		ours := render_ours(p, note)
		defer delete(ours)

		cmp := compare_renders(
			ref,
			ours,
			2,
			f64(SAMPLE_RATE),
			f64(g_hold_frames) / f64(SAMPLE_RATE),
		)
		fmt.printfln(
			"  %s  %s   %s   %s dB   %s dB",
			arp_pad_right(c.name, 18),
			pad_left(fmt.tprintf("%.5f", cmp.ref_steady_rms), 8),
			pad_left(fmt.tprintf("%.5f", cmp.our_steady_rms), 8),
			pad_left(sdec2(cmp.level_db), 7),
			pad_left(cmp.spectral_valid ? dec2(cmp.spectral_db) : "  n/a", 6),
		)
	}
}



