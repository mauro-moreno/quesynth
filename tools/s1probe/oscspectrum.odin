// s1probe oscspectrum - compare the raw oscillator spectrum of a patch between
// the reference and this engine, bin by bin, over a chosen frequency window.
//
// Built for one question: 001.sy1's chorus, held at near-unity feedback, locks
// into a seven-second resonant cycle in the reference and does not in this
// engine, and the lock disappears in both when the patch is reduced to a bare
// sine -- so it depends on harmonic content the chorus is fed, not on the
// chorus itself. This renders the same patch with the chorus switched off, so
// what is compared is the oscillator's own spectrum, and prints power in each
// FFT bin across the window the reference's feedback loop resonates in, so a
// difference in exactly where the energy sits is visible directly rather than
// inferred from the chorus's behaviour on top of it.
//
//   s1probe oscspectrum [dll] <patch.sy1> [--note <n>] [--lo <hz>] [--hi <hz>]
//                             [--at <seconds>]
package s1probe

import "core:fmt"
import "core:os"

import cpatch "../../src/patch"

cmd_oscspectrum :: proc(dll: string, path: string, note: u8, lo_hz, hi_hz, at_seconds: f64) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		fmt.println("oscspectrum: read failed:", rerr)
		return
	}
	p, perr := cpatch.parse_sy1(data)
	if perr != nil {
		fmt.println("oscspectrum: parse failed:", perr)
		return
	}
	// The chorus off, so what is measured is what feeds it, not its own effect.
	set_param(&p, 66, 0)

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	seconds := at_seconds + 0.5
	dumped := false
	dump_indices := []int{0, 1, 5, 45, 64, 66}
	ref_audio := probe_render(dll, &p, pristine, work, note, seconds, &dumped, dump_indices)
	if ref_audio == nil {
		fmt.eprintln("oscspectrum: the reference produced no audio")
		return
	}
	defer delete(ref_audio)
	our_audio := render_ours(p, int(note))
	defer delete(our_audio)

	ref_mid, _ := split_mid_side(ref_audio, 2)
	defer delete(ref_mid)
	our_mid, _ := split_mid_side(our_audio, 2)
	defer delete(our_mid)

	from := int(at_seconds * f64(SAMPLE_RATE))
	held := min(g_hold_frames, len(ref_mid), len(our_mid))
	ref_power := welch_power(ref_mid, from, held)
	defer delete(ref_power)
	our_power := welch_power(our_mid, from, held)
	defer delete(our_power)
	if ref_power == nil || our_power == nil {
		fmt.eprintln("oscspectrum: not enough audio for an FFT window")
		return
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

	ref_peak, our_peak := 0.0, 0.0
	for v in ref_power {
		if v > ref_peak {ref_peak = v}
	}
	for v in our_power {
		if v > our_peak {our_peak = v}
	}

	fmt.printfln("oscspectrum: %v, note %v, chorus forced off", path, note)
	fmt.printfln("  bin width %v Hz, window %v-%v Hz", dec2(bin_hz), dec0(lo_hz), dec0(hi_hz))
	fmt.println()
	fmt.printfln("%10v %12v %12v %10v", "Hz", "ref dB", "our dB", "diff dB")
	lo_bin := max(0, int(lo_hz / bin_hz))
	hi_bin := min(len(ref_power) - 1, int(hi_hz / bin_hz))
	for k in lo_bin ..= hi_bin {
		hz := f64(k) * bin_hz
		rdb := ref_peak > 0 && ref_power[k] > 0 ? power_db(ref_power[k] / ref_peak) : -999
		odb := our_peak > 0 && k < len(our_power) && our_power[k] > 0 ? power_db(our_power[k] / our_peak) : -999
		fmt.printfln("%10v %12v %12v %10v", dec1(hz), dec1(rdb), dec1(odb), sdec1(rdb - odb))
	}
}
