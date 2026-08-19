// s1probe velprobe - how loud is a note as a function of velocity?
//
// Parameter 30 is "amp velocity sens", and `voice_process` reads it as
//
//     gain *= 1 - sens * (1 - velocity)
//
// which is a guess at the shape: it makes velocity a linear fade in amplitude
// whose depth is the knob. 107 of the 128 factory patches carry stored 22, and
// under that law the whole span from a whisper to a slam is 1.2 dB -- little
// enough that a player on a real controller may reasonably report that the
// instrument does not respond to velocity at all. Whether that is faithful or a
// defect is a measurement, not an opinion.
//
//   s1probe velprobe [dll] [--sens <n>] [--values <velocities>] [--note <n>]
package s1probe

import "core:fmt"

import "core:math"

import cpatch "../../src/patch"

velprobe_patch :: proc(sens: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // sine, alone
	set_param(&p, 5, 0)
	set_param(&p, 19, 127) // filter open, envelope flat
	set_param(&p, 20, 0)
	set_param(&p, 24, 0) // filter velocity switch off, so only the amp path is in play
	set_param(&p, 29, 100)
	set_param(&p, 30, sens)
	return p
}

cmd_velprobe :: proc(dll: string, sens: int, values: []int, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	p := velprobe_patch(sens)
	fmt.printfln("velprobe: parameter 30 at stored %v, note %v", sens, note)
	fmt.println("  a sine with the filter open and its envelope flat: only the amplifier moves")
	fmt.println()
	fmt.printfln("%10v %12v %12v %12v %12v", "velocity", "ref dB", "our dB", "ref rel", "our rel")

	ref_top, our_top := 0.0, 0.0
	for v in values {
		set_compare_timing(COMPARE_BLOCK_DEFAULT)
		held := (int(1.0 * f64(SAMPLE_RATE)) + g_block - 1) / g_block
		g_hold_frames = held * g_block
		g_total_frames = g_hold_frames + g_block * 8

		pl, ok := open_reference(dll)
		if !ok {continue}
		load_reference_patch(&pl, &p, pristine, work)
		if !dumped {
			dump_probe_patch(&pl, []int{0, 5, 19, 24, 29, 30})
			dumped = true
		}
		ref := render_reference_note(&pl, note, u8(clamp(v, 0, 127)))
		close_reference(&pl)

		ours := render_ours_velocity(p, int(note), f32(v) / 127.0)
		defer delete(ref)
		defer delete(ours)

		r := amplitude_db(signal_rms_interleaved(ref))
		o := amplitude_db(signal_rms_interleaved(ours))
		if v == values[len(values) - 1] {
			ref_top, our_top = r, o
		}
		fmt.printfln("%10v %12v %12v %12v %12v", v, dec2(r), dec2(o),
			ref_top != 0 ? sdec2(r - ref_top) : "-", our_top != 0 ? sdec2(o - our_top) : "-")
		free_all(context.temp_allocator)
	}
	fmt.println()
	fmt.println("`rel` is each engine against its own loudest row, so the two columns can be")
	fmt.println("compared without the gain difference between the engines getting in the way.")
}

signal_rms_interleaved :: proc(x: []f32) -> f64 {
	if len(x) < 2 {return 0}
	s, n := 0.0, 0
	for i := 0; i + 1 < len(x); i += 2 {
		m := 0.5 * (f64(x[i]) + f64(x[i + 1]))
		s += m * m
		n += 1
	}
	return n > 0 ? math.sqrt(s / f64(n)) : 0
}
