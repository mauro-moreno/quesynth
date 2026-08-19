package s1probe

// Parameter 5, the oscillator mix.
//
// The display reads "100 : 0" through "0 : 100", so the *ratio* is stated in the
// reference's own units and needs no measurement. What the display does not say is
// what those percentages do to the signal, and there are several laws that all
// honour the same numbers: a linear crossfade in amplitude, an equal-power
// crossfade, or two independent gains that do not sum to unity at all.
//
// The binding assumed the first. Two-oscillator bank patches disagree with the
// reference about harmonic balance by 3 to 13 dB, which is the size of error a
// wrong crossfade law would produce, so it is worth measuring rather than assuming.
//
// The measurement is made easy by one choice: **oscillator 1 is a sine**. A sine has
// exactly one partial, so with oscillator 2 an octave above it the two
// contributions occupy different frequencies entirely and each one's gain can be
// read off its own fundamental as the knob sweeps. No separation problem, no
// assumption about the law being tested.

import "core:fmt"
import "core:math"
import "core:os"
import cpatch "../../src/patch"

MIX_PARAM :: 5
MIX_PROBE_NOTE :: u8(60)

// Two sines and nothing else in the way.
//
// Oscillator 2 has no sine, so it gets a triangle: its fundamental carries most of
// its energy and its harmonics land at 1046 Hz and above, nowhere near either
// frequency being read. The waveform's own fundamental amplitude is a constant
// factor across the whole sweep, so it cancels when each curve is normalised to its
// own maximum.
mix_probe_patch :: proc(stored: int) -> cpatch.Patch {
	p := neutral_probe_patch()

	set_param(&p, 0, 0) // oscillator 1: sine
	set_param(&p, 1, 3) // oscillator 2: triangle
	set_param(&p, 2, 77) // oscillator 2 up an octave, display "+12"
	set_param(&p, 3, 66) // no fine tune, display "00 cent"
	set_param(&p, 4, 1) // oscillator 2 tracks the keyboard
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 100) // a fixed drive, short of full scale
	set_param(&p, 72, 64) // no global fine tune
	set_param(&p, MIX_PARAM, stored)

	return p
}

cmd_mixprobe :: proc(dll: string, values: []int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	f1 := 440.0 * math.pow(2.0, (f64(MIX_PROBE_NOTE) - 69.0) / 12.0)
	f2 := f1 * 2.0

	fmt.printfln(
		"oscillator mix (parameter %d): osc1 a sine at %.1f Hz, osc2 a triangle at %.1f Hz",
		MIX_PARAM,
		f1,
		f2,
	)
	fmt.println("  each level is read off its own fundamental, so the two are independent")

	Reading :: struct {
		stored:    int,
		display:   string,
		osc1_db:   f64,
		osc2_db:   f64,
		total_db:  f64,
	}
	readings := make([dynamic]Reading)
	defer delete(readings)

	for v in values {
		p := mix_probe_patch(v)
		audio := probe_render(dll, &p, pristine, work, MIX_PROBE_NOTE, 1.5, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		mid, side := split_mid_side(audio, 2)
		defer delete(mid)
		defer delete(side)
		held := min(g_hold_frames, len(mid))
		from := min(int(0.1 * f64(SAMPLE_RATE)), held / 4)
		power := welch_power(mid, from, held)
		defer delete(power)
		if power == nil {continue}
		bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

		p1 := power_at_hz(power, bin_hz, f1)
		p2 := power_at_hz(power, bin_hz, f2)

		append(
			&readings,
			Reading {
				stored = v,
				display = mix_display(v),
				osc1_db = power_db(p1),
				osc2_db = power_db(p2),
				total_db = power_db(p1 + p2),
			},
		)
	}

	if len(readings) == 0 {
		fmt.eprintln("mixprobe: no readings")
		os.exit(1)
	}

	// Normalise each curve to its own maximum, which removes both the waveform's
	// fundamental amplitude and any fixed gain in the path.
	peak1, peak2 := -1.0e9, -1.0e9
	for r in readings {
		if r.osc1_db > peak1 {peak1 = r.osc1_db}
		if r.osc2_db > peak2 {peak2 = r.osc2_db}
	}

	fmt.println()
	fmt.println(" stored  display     osc1 dB   osc2 dB    osc1 gain  osc2 gain   sum   sum of squares")
	for r in readings {
		g1 := math.pow(10.0, (r.osc1_db - peak1) / 20.0)
		g2 := math.pow(10.0, (r.osc2_db - peak2) / 20.0)
		fmt.printfln(
			"  %s  %s  %s  %s   %s  %s  %s   %s",
			pad_left(fmt.tprintf("%d", r.stored), 4),
			pad_left(r.display, 9),
			pad_left(dec1(r.osc1_db - peak1), 8),
			pad_left(dec1(r.osc2_db - peak2), 8),
			pad_left(dec3(g1), 9),
			pad_left(dec3(g2), 9),
			pad_left(dec3(g1 + g2), 6),
			pad_left(dec3(g1 * g1 + g2 * g2), 8),
		)
	}

	// Which law fits. A linear crossfade keeps `sum` at one; an equal-power
	// crossfade keeps `sum of squares` at one. Whichever column is flat is the law.
	sum_error, power_error := 0.0, 0.0
	counted := 0
	for r in readings {
		g1 := math.pow(10.0, (r.osc1_db - peak1) / 20.0)
		g2 := math.pow(10.0, (r.osc2_db - peak2) / 20.0)
		sum_error += abs(g1 + g2 - 1.0)
		power_error += abs(g1 * g1 + g2 * g2 - 1.0)
		counted += 1
	}
	fmt.println()
	fmt.printfln(
		"  mean |sum - 1|            %.4f   (0 means a linear crossfade in amplitude)",
		sum_error / f64(counted),
	)
	fmt.printfln(
		"  mean |sum of squares - 1| %.4f   (0 means an equal-power crossfade)",
		power_error / f64(counted),
	)
}

// Parameter 5's display for a stored value.
mix_display :: proc(stored: int) -> string {
	states := cpatch.parameter_states(MIX_PARAM)
	if len(states) == 0 {return ""}
	i := clamp(stored, 0, len(states) - 1)
	return states[i].display
}

// ------------------------------------------------------- oscillator phase

// Parameter 91, and the relationship it sets between the two oscillators.
//
// This probe exists because of an impossible reading. Patch 068 mixes two pulses at
// the *same* pitch and the reference returns a spectrum whose second harmonic is
// 11.4 dB **above** its fundamental. No single pulse wave can do that: for a duty
// cycle d the ratio of the two is |cos(pi*d)|, which is at most one whatever d is.
// The only way to get there with two oscillators is for them to cancel at the
// fundamental while adding at the second harmonic, which is what happens when they
// sit half a cycle apart -- a phase offset inverts the odd harmonics and leaves the
// even ones alone.
//
// So the question is whether the reference's default phase relationship is the one
// our engine assumes. Both oscillators are given the same pitch and the same narrow
// pulse width, and parameter 91 is swept: if the fundamental dips somewhere, that
// setting is where the two are opposed, and where the dip sits relative to the
// parameter's default says what the default means.
phase_probe_patch :: proc(stored: int) -> cpatch.Patch {
	p := neutral_probe_patch()

	set_param(&p, 0, 2) // oscillator 1: pulse
	set_param(&p, 1, 2) // oscillator 2: pulse
	set_param(&p, 2, 64) // same pitch, display "00"
	set_param(&p, 3, 66) // no fine tune
	set_param(&p, 4, 1) // keyboard tracking on
	set_param(&p, 5, 64) // an even mix, display "50 : 50"
	// A narrow pulse, so both the first and second harmonics are present to be
	// compared. A square would have no second harmonic to read at all.
	set_param(&p, 8, 29)
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 100)
	set_param(&p, 72, 64)
	set_param(&p, 91, stored)

	return p
}

cmd_phaseprobe :: proc(dll: string, values: []int, note: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	f1 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)

	fmt.printfln("oscillator phase (parameter 91): two pulses at %.1f Hz, mixed 50:50", f1)
	fmt.printfln("  parameter 91's default is %d", cpatch.PARAMETERS[91].default)
	fmt.println("  h1 suppressed against h2 means the two oscillators are opposed")
	fmt.println()
	fmt.println(" stored  display        h1 dB    h2 dB    h3 dB   h2 - h1")

	for v in values {
		p := phase_probe_patch(v)
		audio := probe_render(dll, &p, pristine, work, u8(note), 1.5, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		mid, side := split_mid_side(audio, 2)
		defer delete(mid)
		defer delete(side)
		held := min(g_hold_frames, len(mid))
		from := min(int(0.1 * f64(SAMPLE_RATE)), held / 4)
		power := welch_power(mid, from, held)
		defer delete(power)
		if power == nil {continue}
		bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

		h1 := power_db(power_at_hz(power, bin_hz, f1))
		h2 := power_db(power_at_hz(power, bin_hz, f1 * 2.0))
		h3 := power_db(power_at_hz(power, bin_hz, f1 * 3.0))

		display := ""
		{
			states := cpatch.parameter_states(91)
			pos := clamp(v, 0, len(states) - 1)
			if len(states) > 0 {display = states[pos].display}
		}

		fmt.printfln(
			"  %s  %s  %s %s %s  %s",
			pad_left(fmt.tprintf("%d", v), 4),
			pad_left(display, 10),
			pad_left(dec1(h1), 8),
			pad_left(dec1(h2), 8),
			pad_left(dec1(h3), 8),
			pad_left(sdec1(h2 - h1), 8),
		)
	}
}
