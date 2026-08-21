// s1probe fmfilter - isolate FM before and through a moving filter.
//
// The ordinary bank score cannot distinguish an FM spectrum that is wrong from
// a correct spectrum passing through the wrong cutoff. This probe renders four
// controlled variants of each supplied patch through both engines:
//
//   moving + FM      the patch, with effects disabled
//   moving, FM off   the same moving filter with parameter 45 at zero
//   open + FM        FM upstream of a neutral, wide-open filter
//   open, FM off     the unmodulated upstream control
//
// Short FFT windows follow the filter envelope over time. The first table says
// whether the raw/open FM spectrum agrees; the second subtracts that open
// control and reports only how much the moving filter rejected.
//
// With no paths, the three fixtures that exposed the defect are used:
// 012, 014 and 038 from the incoming factory bank.
//
//   s1probe fmfilter [dll] [--note <n>] [patch.sy1 ...]
package s1probe

import "core:fmt"
import "core:math"
import "core:os"

import cpatch "../../src/patch"

FM_FILTER_SECONDS :: 1.25
FM_FILTER_VARIANTS :: 4
FM_FILTER_WINDOWS :: 4
FM_FILTER_SWEEP_VALUES := [?]int{0, 16, 32, 43, 48, 64, 68, 77, 80, 96, 112, 127}

FM_Filter_Variant :: struct {
	name: string,
	mutate: proc(p: ^cpatch.Patch),
}

fm_filter_variants := [FM_FILTER_VARIANTS]FM_Filter_Variant{
	{"moving + FM", proc(p: ^cpatch.Patch) {}},
	{"moving, FM off", proc(p: ^cpatch.Patch) {set_param(p, 45, 0)}},
	{"open + FM", proc(p: ^cpatch.Patch) {
		set_param(p, 19, 127)
		set_param(p, 20, 0)
		set_param(p, 21, 63)
		set_param(p, 22, 0)
		set_param(p, 24, 0)
	}},
	{"open, FM off", proc(p: ^cpatch.Patch) {
		set_param(p, 45, 0)
		set_param(p, 19, 127)
		set_param(p, 20, 0)
		set_param(p, 21, 63)
		set_param(p, 22, 0)
		set_param(p, 24, 0)
	}},
}

fm_filter_times := [FM_FILTER_WINDOWS]f64{0.02, 0.12, 0.35, 0.80}

FM_Filter_Measure :: struct {
	ref_rms: f64,
	our_rms: f64,
	ref_centroid: f64,
	our_centroid: f64,
	spectral_db: f64,
}

fm_filter_measure :: proc(ref_audio, our_audio: []f32, at_seconds: f64) -> (m: FM_Filter_Measure, ok: bool) {
	ref_mid, _ := split_mid_side(ref_audio, 2)
	defer delete(ref_mid)
	our_mid, _ := split_mid_side(our_audio, 2)
	defer delete(our_mid)

	from := int(at_seconds * f64(SAMPLE_RATE))
	if from < 0 || from + MOD_FFT > min(len(ref_mid), len(our_mid)) {
		return {}, false
	}

	m.ref_rms = signal_rms(ref_mid[from:from + MOD_FFT])
	m.our_rms = signal_rms(our_mid[from:from + MOD_FFT])

	ref_power := make([]f64, MOD_FFT / 2 + 1)
	defer delete(ref_power)
	our_power := make([]f64, MOD_FFT / 2 + 1)
	defer delete(our_power)
	re := make([]f64, MOD_FFT)
	defer delete(re)
	im := make([]f64, MOD_FFT)
	defer delete(im)
	if !window_power(ref_mid, from, ref_power, re, im) || !window_power(our_mid, from, our_power, re, im) {
		return {}, false
	}

	bin_hz := f64(SAMPLE_RATE) / f64(MOD_FFT)
	m.ref_centroid = spectral_centroid(ref_power, bin_hz)
	m.our_centroid = spectral_centroid(our_power, bin_hz)
	ref_bands, centres := band_powers(ref_power, bin_hz)
	defer delete(ref_bands)
	defer delete(centres)
	our_bands, _ := band_powers(our_power, bin_hz)
	defer delete(our_bands)
	spectral_db, _, _, compared := band_distance_db(ref_bands, our_bands, centres)
	m.spectral_db = spectral_db
	return m, compared > 0
}

fm_filter_loss_db :: proc(moving, open: f64) -> f64 {
	if moving <= 0 || open <= 0 {
		return -999
	}
	return 20.0 * math.log10(moving / open)
}

fm_filter_disable_effects :: proc(p: ^cpatch.Patch) {
	set_param(p, 10, 0) // oscillator modulation envelope
	set_param(p, 57, 0) // LFO 1
	set_param(p, 58, 0) // LFO 2
	set_param(p, 59, 0) // arpeggiator
	set_param(p, 73, 0) // unison: one oscillator pair
	set_param(p, 65, 0) // delay
	set_param(p, 66, 0) // chorus/flanger
	set_param(p, 77, 0) // extra effect unit
}

cmd_fmfilter :: proc(dll: string, paths: []string, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	for path in paths {
		data, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.printfln("fmfilter: read failed for %v: %v", path, rerr)
			continue
		}
		base, perr := cpatch.parse_sy1(data)
		if perr != nil {
			fmt.printfln("fmfilter: parse failed for %v: %v", path, perr)
			continue
		}
		fm_filter_disable_effects(&base)

		rms: [FM_FILTER_VARIANTS][FM_FILTER_WINDOWS][2]f64
		fmt.printfln("fmfilter: %v, note %v", path, note)
		fmt.printfln("  FM %v, filter type %v, cutoff %v, resonance %v, amount %v",
			base.values[45], base.values[14], base.values[19], base.values[20], base.values[21])
		fmt.println()
		fmt.printfln("%8v  %-15v %9v %9v %9v %9v %9v", "at s", "variant", "ref rms", "our rms", "ref ctr", "our ctr", "spec dB")

		for vi in 0 ..< FM_FILTER_VARIANTS {
			p := base
			fm_filter_variants[vi].mutate(&p)
			ref_audio := probe_render(dll, &p, pristine, work, note, FM_FILTER_SECONDS, &dumped, nil)
			if ref_audio == nil {
				continue
			}
			our_audio := render_ours(p, int(note))
			for ti in 0 ..< FM_FILTER_WINDOWS {
				m, ok := fm_filter_measure(ref_audio, our_audio, fm_filter_times[ti])
				if !ok {continue}
				rms[vi][ti][0] = m.ref_rms
				rms[vi][ti][1] = m.our_rms
				fmt.printfln("%8v  %-15v %9v %9v %9v %9v %9v",
					dec2(fm_filter_times[ti]), fm_filter_variants[vi].name,
					dec4(m.ref_rms), dec4(m.our_rms), dec0(m.ref_centroid), dec0(m.our_centroid), dec2(m.spectral_db))
			}
			delete(ref_audio)
			delete(our_audio)
		}

		fmt.println()
		fmt.println("  moving/open attenuation (dB; open control removed)")
		fmt.printfln("%8v %12v %12v %12v %12v", "at s", "ref FM", "our FM", "ref no-FM", "our no-FM")
		for ti in 0 ..< FM_FILTER_WINDOWS {
			fmt.printfln("%8v %12v %12v %12v %12v",
				dec2(fm_filter_times[ti]),
				sdec2(fm_filter_loss_db(rms[0][ti][0], rms[2][ti][0])),
				sdec2(fm_filter_loss_db(rms[0][ti][1], rms[2][ti][1])),
				sdec2(fm_filter_loss_db(rms[1][ti][0], rms[3][ti][0])),
				sdec2(fm_filter_loss_db(rms[1][ti][1], rms[3][ti][1])))
		}

		fmt.println()
		fmt.println("  open-filter FM knob sweep (0.35 s window)")
		fmt.printfln("%8v %12v %12v %12v", "p45", "ref ctr", "our ctr", "spec dB")
		for value in FM_FILTER_SWEEP_VALUES {
			p := base
			fm_filter_variants[2].mutate(&p)
			set_param(&p, 45, value)
			ref_audio := probe_render(dll, &p, pristine, work, note, FM_FILTER_SECONDS, &dumped, nil)
			if ref_audio == nil {continue}
			our_audio := render_ours(p, int(note))
			m, ok := fm_filter_measure(ref_audio, our_audio, 0.35)
			delete(ref_audio)
			delete(our_audio)
			if ok {
				fmt.printfln("%8v %12v %12v %12v", value,
					dec0(m.ref_centroid), dec0(m.our_centroid), dec2(m.spectral_db))
			}
		}
		fmt.println()
		free_all(context.temp_allocator)
	}
}
