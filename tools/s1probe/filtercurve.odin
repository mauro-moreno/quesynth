package s1probe

// The filter saturation's transfer curve, read rather than assumed.
//
// The drive law was fitted from THD through an open filter, and it is exact
// there: the reference's -26.5, -13.9, -8.9 and -7.2 dB come back digit for
// digit. Through a closed one the same curve is up to 23 dB short of the
// reference's harmonics, and docs/null-test.md records why no drive table fixes
// that -- once the signal is deep in clipping the open measurement stops
// constraining the drive at all, and the scale that lands the closed case at the
// middle of the knob costs 7 dB of the open control. What is left is that the
// curve is the wrong shape: it must match `tanh` where the signal is large and
// bend harder than `tanh` where it is small.
//
// That is readable directly, by the same trick `fxshape` uses on the effect unit.
// Render one patch twice, saturation off and on. Both renders come from the same
// synth, sample for sample, so scattering the second against the first is the
// curve itself -- one point per sample, no fitting and no assumed family.
//
// The filter is left open on purpose. The saturation control also opens the
// corner, so through a closed filter the two renders differ by a filter as well
// as by a curve, and the scatter would be a loop rather than a line. Open, the
// corner is already above the note and cannot move anywhere that matters, so the
// only difference left is the shaping. A sine sweeps its whole range on the way
// past, so the small-signal part of the curve is sampled just as densely as the
// peaks -- which is the part in question.
//
//   s1probe filtercurve [dll] [--cutoff <n>] [--note <n>] [--values <sats>]

import "core:fmt"
import "core:math"

FILTER_CURVE_SECONDS :: 1.5

// Best-fit peak-normalised tanh through a measured curve, by its drive alone.
filter_curve_fit_tanh :: proc(c: ^Fx_Curve) -> (drive, rms: f64) {
	best_d, best_e := 0.0, 1.0e30
	d := 0.05
	for d < 60.0 {
		// scale so the fit matches at the peak, which is what the reference's own
		// normalisation does
		norm := math.tanh(d)
		e, n := 0.0, 0
		for i in 0 ..< len(c.x) {
			if c.n[i] == 0 {
				continue
			}
			pred := c.peak * math.tanh(c.x[i] / c.peak * d) / norm
			e += (c.y[i] - pred) * (c.y[i] - pred)
			n += 1
		}
		if n > 0 {
			e = math.sqrt(e / f64(n))
			if e < best_e {best_e, best_d = e, d}
		}
		d *= 1.02
	}
	return best_d, best_e
}

cmd_filtercurve :: proc(dll: string, filter_type, cutoff, resonance, gain: int, note: u8, spec: string) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	sats := parse_env_values(spec)
	defer delete(sats)
	dumped := false

	fmt.printfln("filtercurve: type %v, cutoff %v, resonance %v, gain %v, note %v",
		filter_type, cutoff, resonance, gain, note)
	fmt.println("  scatter of saturation-on against saturation-off, both from the same render")
	fmt.println()

	off := filter_distortion_patch(filter_type, cutoff, resonance, gain, 0, 0, 64)
	ref_off := probe_render(dll, &off, pristine, work, note, FILTER_CURVE_SECONDS, &dumped, nil)
	if ref_off == nil {
		fmt.eprintln("filtercurve: the reference would not render the unsaturated patch")
		return
	}
	defer delete(ref_off)
	our_off := render_ours(off, int(note))
	defer delete(our_off)

	for sat in sats {
		on := filter_distortion_patch(filter_type, cutoff, resonance, gain, sat, 0, 64)
		ref_on := probe_render(dll, &on, pristine, work, note, FILTER_CURVE_SECONDS, &dumped, nil)
		if ref_on == nil {
			continue
		}
		our_on := render_ours(on, int(note))

		rc := fx_curve_measure(ref_off, ref_on)
		oc := fx_curve_measure(our_off, our_on)
		rd, re := filter_curve_fit_tanh(&rc)
		od, oe := filter_curve_fit_tanh(&oc)

		fmt.printfln("  saturation %v", sat)
		fmt.printfln("    reference: peak in %.4f, loop width %.4f, best tanh drive %.2f, fit rms %.5f",
			rc.peak, rc.loop, rd, re)
		fmt.printfln("    ours:      peak in %.4f, loop width %.4f, best tanh drive %.2f, fit rms %.5f",
			oc.peak, oc.loop, od, oe)
		fmt.println("        x/peak    reference     ours      tanh(fit)   ref-tanh")
		for i in 0 ..< len(rc.x) {
			if rc.n[i] == 0 || i % 2 != 0 {
				continue
			}
			t := rc.peak * math.tanh(rc.x[i] / rc.peak * rd) / math.tanh(rd)
			oy := 0.0
			if i < len(oc.y) && oc.n[i] > 0 {oy = oc.y[i]}
			fmt.printfln("      %8v %11v %10v %11v %10v",
				dec3(rc.x[i] / rc.peak), dec5(rc.y[i]), dec5(oy), dec5(t), dec5(rc.y[i] - t))
		}
		fx_curve_free(&rc)
		fx_curve_free(&oc)
		delete(ref_on)
		delete(our_on)
		free_all(context.temp_allocator)
	}
}
