// s1probe leveltable - measure the reference's amplitude curves.
//
// Two knobs decide how loud a patch is, and this project guesses at both:
//
//   parameter 29, amp gain     bound as unit^2, "squared so the knob is roughly
//                              perceptual" -- a chosen curve, by its own comment
//   parameter 27, amp sustain  bound as a plain linear unit, never questioned
//
// The null test says they are the largest systematic bias left: our renders come
// out 8.2 dB louder than the reference's on average, and correcting the
// oscillator waveforms made that worse rather than better, because saw and pulse
// carry more energy than the triangle they replaced. A level error is not
// cosmetic in a clone -- load a factory patch and it is twice as loud as the
// original.
//
//   s1probe gainprobe  [dll] [--values <list|all>] [--csv <path>]
//   s1probe leveltable [dll] [out.odin]
//
// Method, the same shape as the envelope measurement: a patch that isolates the
// amplitude, one render per setting, and the level read back out of the audio.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"

// A sine through an open filter with a flat envelope, so the output's amplitude
// is exactly the product of the two curves being measured and nothing else.
//
// Sine rather than saw or pulse for the same reason the envelope probe uses one:
// its amplitude is a property of the waveform rather than of where the analysis
// window happened to land, and our own oscillator's sine peaks at exactly 1.0,
// which makes the measured amplitude directly usable as an engine gain.
level_probe_patch :: proc(gain, sustain: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 25, 0) // instant attack
	set_param(&p, 26, 0) // no decay, so the level sits at sustain
	set_param(&p, 27, sustain)
	set_param(&p, 28, 0)
	set_param(&p, 29, gain)
	set_param(&p, 30, 0) // velocity does not scale level
	return p
}

// Amplitude of the steady portion, as a sine's peak.
//
// RMS rather than the observed peak: it averages over the whole window instead
// of reporting whichever single sample happened to be highest, and for a sine
// the two differ by a known factor.
level_amplitude :: proc(audio: []f32) -> f64 {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < SAMPLE_RATE / 4 {
		return 0
	}
	// Skip the first 100 ms, in case anything is still settling, and stop at the
	// note off.
	//
	// Stopping there is the whole point. Running to the end of the array instead
	// swept in the render's tail, which for these patches is silence -- the release
	// is zero -- and an RMS over a window that is part silence reads low by the
	// square root of the sounding fraction. With a 0.5 second hold and the tail
	// `probe_render` appends, that is sqrt(19776 / 23872) = 0.9102, and every
	// number in the generated table came out that much under the truth.
	//
	// It cost 0.81 dB on every patch in the bank and took a long time to find,
	// because the table's *shape* was unaffected: the bias is one constant factor,
	// so a gain sweep still tracked the reference perfectly and only the absolute
	// scale was wrong. The sustain curve escaped entirely, being a ratio of two
	// numbers biased identically.
	from := int(0.1 * f64(SAMPLE_RATE))
	to := min(g_hold_frames, len(mid))
	if to <= from {
		return 0
	}
	return signal_rms(mid[from:to]) * math.sqrt(f64(2.0))
}

LEVEL_PROBE_SECONDS :: 0.5

// Sweep one of the two curves. `sweep_gain` picks which; the other is held at
// its maximum so the two are separable.
sweep_level :: proc(
	dll: string,
	pristine, work: []byte,
	note: u8,
	sweep_gain: bool,
	values: []int,
	dumped: ^bool,
) -> []f64 {
	out := make([]f64, len(values))
	dump_indices := []int{0, 5, 14, 19, 25, 26, 27, 28, 29, 30}
	for v, i in values {
		p := sweep_gain ? level_probe_patch(v, 127) : level_probe_patch(127, v)
		audio := probe_render(dll, &p, pristine, work, note, LEVEL_PROBE_SECONDS, dumped, dump_indices)
		if audio == nil {
			continue
		}
		out[i] = level_amplitude(audio)
		delete(audio)
		free_all(context.temp_allocator)
	}
	return out
}

cmd_gainprobe :: proc(dll: string, spec: string, csv: string, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	gains := sweep_level(dll, pristine, work, note, true, values, &dumped)
	defer delete(gains)
	sustains := sweep_level(dll, pristine, work, note, false, values, nil)
	defer delete(sustains)

	fmt.printfln("gainprobe: note %v, sine through an open filter", note)
	fmt.println()
	fmt.printfln("%8v %12v %10v %12v %10v", "stored", "gain ampl", "gain dB", "sustain ampl", "sust dB")
	full_gain := gains[len(gains) - 1]
	full_sustain := sustains[len(sustains) - 1]
	for v, i in values {
		fmt.printfln("%8v %12v %10v %12v %10v",
			v,
			dec5(gains[i]),
			gains[i] > 0 ? sdec1(amplitude_db(gains[i])) : pad_left("-", 6),
			dec5(sustains[i]),
			sustains[i] > 0 ? sdec1(amplitude_db(sustains[i] / max(full_sustain, 1e-12))) : pad_left("-", 6))
	}
	fmt.println()
	fmt.printfln("full gain reaches an amplitude of %v; this engine's sine peaks at 1.0,",
		dec5(full_gain))
	fmt.printfln("so a gain of 1.0 at the top of the range is %v dB hot.",
		sdec2(-amplitude_db(full_gain)))

	if csv != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "stored,gain_amplitude,sustain_amplitude\n")
		for v, i in values {
			fmt.sbprintf(&b, "%v,%.8f,%.8f\n", v, gains[i], sustains[i])
		}
		if os.write_entire_file(csv, transmute([]u8)strings.to_string(b)) == nil {
			fmt.printfln("wrote %v", csv)
		}
	}
}

// Sweep both curves at every setting and write them out as Odin source.
cmd_leveltable :: proc(dll: string, out_path: string, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := parse_env_values("all")
	defer delete(values)
	if len(values) != 128 {
		fmt.eprintln("leveltable: expected 128 settings")
		os.exit(1)
	}

	fmt.println("measuring the reference's amplitude curves, two sweeps of 128 settings")
	dumped := true
	gains := sweep_level(dll, pristine, work, note, true, values, &dumped)
	defer delete(gains)
	fmt.printfln("  gain     %v of %v settings produced output", count_positive(gains), len(gains))
	sustains := sweep_level(dll, pristine, work, note, false, values, nil)
	defer delete(sustains)
	fmt.printfln("  sustain  %v of %v settings produced output", count_positive(sustains), len(sustains))

	full_gain := gains[127]
	full_sustain := sustains[127]
	if full_gain <= 0 || full_sustain <= 0 {
		fmt.eprintln("leveltable: the top of a sweep produced no output; refusing to emit a table")
		os.exit(1)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `// Code generated by "s1probe leveltable"; do not edit.
//
// The reference Synth1's two amplitude curves, indexed by the parameter's
// resolved state (its stored 0..127 value). Method is in docs/null-test.md.
//
// AMP_GAIN_AMPLITUDE is absolute, not normalised: it is the amplitude a sine
// reaches at that setting of parameter 29, measured through an open filter with
// a flat envelope. This engine's sine oscillator peaks at exactly 1.0, so the
// number is directly usable as the voice gain and it carries the reference's own
// output level with it. The previous binding used unit^2, which reaches 1.0 at
// the top of the range where the reference reaches less, and was therefore hot
// before any curve error is considered.
//
// AMP_SUSTAIN_LEVEL is relative to full sustain, because parameter 27 sets a
// fraction of the level parameter 29 already decided. It replaces a plain linear
// reading of the knob.
//
// Both were measured with the other held at maximum, which is what makes them
// separable.
package engine

AMP_TABLE_SIZE :: 128

`)

	emit_table :: proc(b: ^strings.Builder, name: string, values: []f64) {
		fmt.sbprintf(b, "%v := [AMP_TABLE_SIZE]f32{{\n", name)
		for i in 0 ..< len(values) {
			if i % 4 == 0 {
				strings.write_string(b, "\t")
			}
			fmt.sbprintf(b, "%.6f,", values[i])
			if i % 4 == 3 {
				strings.write_string(b, "\n")
			} else {
				strings.write_string(b, " ")
			}
		}
		strings.write_string(b, "}\n\n")
	}

	emit_table(&b, "AMP_GAIN_AMPLITUDE", gains)

	relative := make([]f64, len(sustains))
	defer delete(relative)
	for s, i in sustains {
		relative[i] = s / full_sustain
	}
	emit_table(&b, "AMP_SUSTAIN_LEVEL", relative)

	if os.write_entire_file(out_path, transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintfln("leveltable: could not write %v", out_path)
		os.exit(1)
	}
	fmt.printfln("wrote %v", out_path)
	fmt.printfln("gain    %v .. %v amplitude", dec5(gains[0]), dec5(gains[127]))
	fmt.printfln("sustain %v .. %v relative", dec5(relative[0]), dec5(relative[127]))
}

count_positive :: proc(values: []f64) -> int {
	n := 0
	for v in values {
		if v > 0 {
			n += 1
		}
	}
	return n
}
