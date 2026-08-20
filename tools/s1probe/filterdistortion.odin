// s1probe filterdistortion - how much harmonic distortion does the reference's
// filter add to a pure tone, as a function of resonance and level.
//
// Built to replace guessing at a drive constant with a measured curve.
// `oscspectrum` and the chorus-stability sections of docs/null-test.md trace a
// broadband skirt in the reference's 24 dB filter output to a nonlinearity in
// the resonant path -- signal-dependent, filter-specific, needs harmonic
// content to show up as anything audible downstream. This drives a bare sine
// through the filter, so any harmonic energy measured afterward was created by
// the filter itself and by nothing upstream of it, and reads it back as THD
// against level and resonance both, since a ladder's saturation is a function
// of both.
//
//   s1probe filterdistortion [dll] [--cutoff <n>] [--note <n>] [--type <n>]
//                                   [--values <resonances>] [--level <n>]
package s1probe

import "core:fmt"

import cpatch "../../src/patch"
import sdsp "../../src/dsp"

filter_distortion_patch :: proc(filter_type, cutoff, resonance, gain: int, saturation := 0) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine, alone
	set_param(&p, 5, 0)
	set_param(&p, 14, filter_type)
	set_param(&p, 19, cutoff)
	set_param(&p, 20, resonance)
	set_param(&p, 21, 63) // envelope amount: none, so cutoff does not move
	set_param(&p, 22, 0) // no keyboard tracking
	set_param(&p, 23, saturation)
	set_param(&p, 29, gain)
	return p
}

// Sweep parameter 23 itself. The filter is held open and non-resonant so the
// only changing nonlinearity is the explicitly labelled saturation control.
// Several downstream amplifier gains are measured as a placement check. They
// scale RMS and peak without changing normalised THD, proving parameter 29 is
// after this transfer rather than changing where the sine meets its knee.
cmd_filtersaturation :: proc(dll: string, filter_type, cutoff, resonance: int, note: u8, saturation_spec, gain_spec: string) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	saturations := parse_env_values(saturation_spec)
	defer delete(saturations)
	gains := parse_env_values(gain_spec)
	defer delete(gains)

	f0 := f64(sdsp.note_to_hz(f32(note)))
	dumped := false
	dump_indices := []int{0, 5, 14, 19, 20, 21, 22, 23, 29}

	fmt.printfln("filtersaturation: type %v, cutoff %v, resonance %v, note %v (%v Hz)",
		filter_type, cutoff, resonance, note, dec1(f0))
	fmt.println("  sine through an open, non-moving filter; each row is normalised later")
	fmt.println("  against saturation 0 at the same input gain")
	fmt.println()
	fmt.printfln("%6v %6v %10v %10v %10v %10v %10v %10v %10v %10v",
		"gain", "sat", "ref THD", "our THD", "ref fund", "our fund",
		"ref RMS", "our RMS", "ref peak", "our peak")

	for gain in gains {
		for saturation in saturations {
			p := filter_distortion_patch(filter_type, cutoff, resonance, gain, saturation)
			ref_audio := probe_render(dll, &p, pristine, work, note, FILTER_DISTORTION_SECONDS, &dumped, dump_indices)
			if ref_audio == nil {
				continue
			}
			our_audio := render_ours(p, int(note))

			ref_thd, _, _, ref_fund, ref_ok := measure_thd(ref_audio, f0)
			our_thd, _, _, our_fund, our_ok := measure_thd(our_audio, f0)
			ref_rms := signal_rms(ref_audio)
			our_rms := signal_rms(our_audio)
			ref_peak := signal_peak(ref_audio)
			our_peak := signal_peak(our_audio)
			delete(ref_audio)
			delete(our_audio)

			if !ref_ok || !our_ok {
				fmt.printfln("%6v %6v %10v", gain, saturation, "-")
				continue
			}
			fmt.printfln("%6v %6v %10v %10v %10v %10v %10v %10v %10v %10v",
				gain, saturation, dec1(ref_thd), dec1(our_thd), dec1(ref_fund), dec1(our_fund),
				dec4(ref_rms), dec4(our_rms), dec4(ref_peak), dec4(our_peak))
			free_all(context.temp_allocator)
		}
	}
}

FILTER_DISTORTION_SECONDS :: 1.5

measure_thd :: proc(audio: []f32, f0: f64) -> (thd_db, even_db, odd_db, fundamental_db: f64, ok: bool) {
	mid, _ := split_mid_side(audio, 2)
	defer delete(mid)
	held := len(mid)
	if held < FFT_SIZE * 2 {
		return 0, 0, 0, 0, false
	}
	from := int(0.3 * f64(SAMPLE_RATE))
	if from >= held - FFT_SIZE {
		from = 0
	}
	power := welch_power(mid, from, held)
	defer delete(power)
	if power == nil {
		return 0, 0, 0, 0, false
	}
	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	r := harmonic_report(power, bin_hz, f0)
	if r.fundamental <= 0 {
		return 0, 0, 0, 0, false
	}
	return r.thd_db, r.even_db, r.odd_db, power_db(r.fundamental), true
}

cmd_filterdistortion :: proc(dll: string, filter_type, cutoff: int, note: u8, spec: string, gain: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := parse_env_values(spec)
	defer delete(values)

	f0 := f64(sdsp.note_to_hz(f32(note)))
	dumped := false
	dump_indices := []int{0, 5, 14, 19, 20, 21, 22, 29}

	fmt.printfln("filterdistortion: type %v, cutoff %v, note %v (%v Hz), gain %v",
		filter_type, cutoff, note, dec1(f0), gain)
	fmt.println("  bare sine through the filter; harmonics measured downstream are the")
	fmt.println("  filter's own, since nothing upstream of it has any")
	fmt.println()
	fmt.printfln("%8v %10v %10v %10v %10v %10v %10v %10v %10v %10v %10v",
		"resonance", "ref THD", "our THD", "ref even", "our even", "ref odd", "our odd",
		"ref fund", "our fund", "ref peak", "our peak")

	for v in values {
		p := filter_distortion_patch(filter_type, cutoff, v, gain)
		ref_audio := probe_render(dll, &p, pristine, work, note, FILTER_DISTORTION_SECONDS, &dumped, dump_indices)
		if ref_audio == nil {
			continue
		}
		our_audio := render_ours(p, int(note))

		ref_thd, ref_even, ref_odd, ref_fund, ref_ok := measure_thd(ref_audio, f0)
		our_thd, our_even, our_odd, our_fund, our_ok := measure_thd(our_audio, f0)
		ref_peak := amplitude_db(signal_peak(ref_audio))
		our_peak := amplitude_db(signal_peak(our_audio))
		delete(ref_audio)
		delete(our_audio)

		if !ref_ok || !our_ok {
			fmt.printfln("%8v %10v", v, "-")
			continue
		}
		fmt.printfln("%8v %10v %10v %10v %10v %10v %10v %10v %10v %10v %10v",
			v, dec1(ref_thd), dec1(our_thd), dec1(ref_even), dec1(our_even), dec1(ref_odd), dec1(our_odd),
			dec1(ref_fund), dec1(our_fund), dec1(ref_peak), dec1(our_peak))
		free_all(context.temp_allocator)
	}
}
