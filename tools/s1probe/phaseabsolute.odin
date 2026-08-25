package s1probe

// Parameter 91, read as signed start phases against note-on.
//
// The cancellation probe in mixprobe.odin is useful for finding opposed
// oscillators, but cancellation depth is an even function of phase and cannot
// distinguish +phi from -phi. This probe renders one descending saw at a time
// and projects its fundamental with sample zero as note-on. A descending saw's
// fundamental is -0.25 turns at oscillator phase zero, a property of the
// waveform rather than of this engine, so adding 0.25 gives an absolute phase.
// The apparent phase is read at five notes and fitted against frequency: the
// intercept is the start phase, while the slope is the plugin's fixed output
// latency. The reference's own free-running oscillator 1 then defines phase
// zero; this removes the probe path's common phase without using this engine or
// the other oscillator as an origin.

import "core:fmt"
import "core:math"
import cpatch "../../src/patch"

PHASE_ABSOLUTE_NOTES := []int{36, 48, 60, 72, 84}

phase_absolute_patch :: proc(stored, oscillator: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 1) // oscillator 1: descending saw
	set_param(&p, 1, 1) // oscillator 2: the same descending saw
	set_param(&p, 2, 64) // same pitch, display "00"
	set_param(&p, 3, 66) // no fine tune, display "00 cent"
	set_param(&p, 4, 1) // oscillator 2 tracks the keyboard
	// One oscillator, never a cancellation.
	set_param(&p, 5, oscillator == 1 ? 0 : 127)
	set_param(&p, 9, 0) // no key shift
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 100) // fixed gain short of full scale
	set_param(&p, 72, 64) // no global fine tune
	set_param(&p, 91, stored)
	set_param(&p, 92, 0) // no unison phase spread
	return p
}

// Fundamental phase in turns, with absolute sample indices from note-on.
phase_absolute_projection :: proc(
	audio: []f32,
	note: int,
) -> (phase, magnitude: f64) {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)

	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	from := min(int(0.10 * f64(SAMPLE_RATE)), len(mid) / 4)
	to := min(int(1.45 * f64(SAMPLE_RATE)), len(mid))
	n := f64(to - from)
	re, im := 0.0, 0.0
	for i in from ..< to {
		// The window is only for leakage. Its sample index remains absolute.
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i - from) / n)
		a := 2.0 * math.PI * f0 * f64(i) / f64(SAMPLE_RATE)
		re += f64(mid[i]) * w * math.cos(a)
		im -= f64(mid[i]) * w * math.sin(a)
	}
	magnitude = math.sqrt(re * re + im * im) / n
	// A descending saw at oscillator phase zero projects at -0.25 turns.
	phase = math.atan2(im, re) / (2.0 * math.PI) + 0.25
	for phase < 0 {phase += 1.0}
	for phase >= 1.0 {phase -= 1.0}
	return
}

Phase_Absolute_Fit :: struct {
	intercept: f64,
	latency_samples: f64,
	rms: f64,
	phases: [5]f64,
	ok: bool,
}

phase_absolute_fit :: proc(
	dll: string,
	patch: ^cpatch.Patch,
	pristine, work: []byte,
	dumped: ^bool,
) -> Phase_Absolute_Fit {
	result: Phase_Absolute_Fit
	xs, ys: [5]f64
	for note, i in PHASE_ABSOLUTE_NOTES {
		audio := probe_render(dll, patch, pristine, work, u8(note), 1.5, dumped, nil)
		if audio == nil {return result}
		phase, magnitude := phase_absolute_projection(audio, note)
		delete(audio)
		if magnitude < 1.0e-5 {return result}
		xs[i] = 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
		ys[i] = phase
		if i > 0 {
			for ys[i] - ys[0] > 0.5 {ys[i] -= 1.0}
			for ys[i] - ys[0] < -0.5 {ys[i] += 1.0}
		}
		result.phases[i] = ys[i]
	}

	mx, my := 0.0, 0.0
	for i in 0 ..< len(xs) {
		mx += xs[i]
		my += ys[i]
	}
	mx /= f64(len(xs))
	my /= f64(len(ys))
	sxy, sxx := 0.0, 0.0
	for i in 0 ..< len(xs) {
		sxy += (xs[i] - mx) * (ys[i] - my)
		sxx += (xs[i] - mx) * (xs[i] - mx)
	}
	slope := sxy / sxx
	result.intercept = my - slope * mx
	result.latency_samples = slope * f64(SAMPLE_RATE)
	for i in 0 ..< len(xs) {
		d := ys[i] - (result.intercept + slope * xs[i])
		result.rms += d * d
	}
	result.rms = math.sqrt(result.rms / f64(len(xs)))
	for result.intercept < 0 {result.intercept += 1.0}
	for result.intercept >= 1.0 {result.intercept -= 1.0}
	result.ok = true
	return result
}

phase_signed :: proc(v: f64) -> f64 {
	result := v
	for result >= 0.5 {result -= 1.0}
	for result < -0.5 {result += 1.0}
	return result
}

cmd_phaseabsolute :: proc(dll: string, values: []int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.println("parameter 91 absolute start phase: one descending saw at a time")
	fmt.println("  phase is projected against note-on at notes 36,48,60,72,84")
	fmt.println("  phase-vs-frequency intercept removes the reference's fixed")
	fmt.println("  output latency")
	fmt.println("  the reference's free-running oscillator 1 defines phase zero")
	fmt.println("  signed phases rule out cancellation's +phi/-phi ambiguity")

	zero_patch := phase_absolute_patch(0, 1)
	zero := phase_absolute_fit(dll, &zero_patch, pristine, work, &dumped)
	if !zero.ok {
		fmt.println("no free-running oscillator-1 reading")
		return
	}
	fmt.printfln("  raw free-running oscillator-1 intercept: %+.5f turns",
		phase_signed(zero.intercept))
	fmt.println()
	fmt.println("stored  osc1 start  osc2 start  osc2-osc1  law value  law error  fit rms")

	for v in values {
		p1 := phase_absolute_patch(v, 1)
		p2 := phase_absolute_patch(v, 2)
		a := phase_absolute_fit(dll, &p1, pristine, work, &dumped)
		b := phase_absolute_fit(dll, &p2, pristine, work, &dumped)
		if !a.ok || !b.ok {
			fmt.printfln("%d  no reading", v)
			continue
		}
		osc1 := phase_signed(a.intercept - zero.intercept)
		osc2 := phase_signed(b.intercept - zero.intercept)
		delta := 0.0
		for i in 0 ..< len(a.phases) {
			d := b.phases[i] - a.phases[i]
			for d < 0 {d += 1.0}
			for d >= 1.0 {d -= 1.0}
			delta += d
		}
		delta /= f64(len(a.phases))
		if v == 0 {
			fmt.printfln("%d  %+.5f  %+.5f  %.5f  free-running  n/a  %.1e",
				v, osc1, osc2, delta, max(a.rms, b.rms))
		} else {
			law := 0.5 * f64(v - 1) / 126.0
			fmt.printfln("%d  %+.5f  %+.5f  %.5f  %.6f  %+.1e  %.1e",
				v, osc1, osc2, delta, law, delta - law,
				max(a.rms, b.rms))
		}
	}
	fmt.println()
	fmt.println("osc1 engaged readings should be -0.00125 turns at every")
	fmt.println("stored v >= 1;")
	fmt.println("the relationship should follow 0.5*(v-1)/126, not 0.5*v/127.")
}
