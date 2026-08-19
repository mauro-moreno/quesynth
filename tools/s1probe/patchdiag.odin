// s1probe patchdiag - isolate which parameter of one patch causes a level gap.
//
// Ad hoc: loads a .sy1 file, renders the reference and this engine once as-is,
// then re-renders after zeroing one group of parameters at a time, and prints
// the peak and RMS of each variant so the group that closes the gap is visible
// directly rather than guessed at.
//
//   s1probe patchdiag [dll] <patch.sy1> [--note <n>]
package s1probe

import "core:fmt"
import "core:math"
import "core:os"

import cpatch "../../src/patch"

Diag_Variant :: struct {
	name:    string,
	mutate:  proc(p: ^cpatch.Patch),
}

patchdiag_variants := []Diag_Variant{
	{"baseline", proc(p: ^cpatch.Patch) {}},
	{"FM off (45->0)", proc(p: ^cpatch.Patch) { set_param(p, 45, 0) }},
	{"filter env neutral (21->63)", proc(p: ^cpatch.Patch) { set_param(p, 21, 63) }},
	{"filter wide open (19->127,20->0)", proc(p: ^cpatch.Patch) { set_param(p, 19, 127); set_param(p, 20, 0) }},
	{"amp sustain full (27->127)", proc(p: ^cpatch.Patch) { set_param(p, 27, 127) }},
	{"osc2 pitch 0 (9->64)", proc(p: ^cpatch.Patch) { set_param(p, 9, 64) }},
	{"osc2 key track on (4->1)", proc(p: ^cpatch.Patch) {}},
	{"pulse width flat (36->64)", proc(p: ^cpatch.Patch) { set_param(p, 36, 64) }},
	{"FM off + filter open", proc(p: ^cpatch.Patch) {
		set_param(p, 45, 0); set_param(p, 19, 127); set_param(p, 20, 0)
	}},
}

cmd_patchdiag :: proc(dll: string, path: string, note: u8) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		fmt.println("read failed:", rerr)
		return
	}
	base, perr := cpatch.parse_sy1(data)
	if perr != nil {
		fmt.println("parse error:", perr)
		return
	}

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.printfln("patchdiag: %v, note %v", path, note)
	fmt.println()
	fmt.printfln("%-34v %10v %10v %10v %10v", "variant", "ref peak", "ref rms", "our peak", "our rms")

	for variant in patchdiag_variants {
		p := base
		variant.mutate(&p)

		ref_audio := probe_render(dll, &p, pristine, work, note, 1.6, &dumped, nil)
		if ref_audio == nil {
			continue
		}
		our_audio := render_ours(p, int(note))

		ref_peak, ref_rms := level_stats(ref_audio)
		our_peak, our_rms := level_stats(our_audio)
		delete(ref_audio)
		delete(our_audio)

		fmt.printfln("%-34v %10v %10v %10v %10v",
			variant.name, dec4(ref_peak), dec4(ref_rms), dec4(our_peak), dec4(our_rms))
		free_all(context.temp_allocator)
	}
}

level_stats :: proc(audio: []f32) -> (peak, rms: f64) {
	if len(audio) == 0 {
		return 0, 0
	}
	sum := 0.0
	for v in audio {
		a := abs(f64(v))
		if a > peak {
			peak = a
		}
		sum += f64(v) * f64(v)
	}
	rms = math.sqrt(sum / f64(len(audio)))
	return
}
