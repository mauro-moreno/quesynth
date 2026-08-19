// s1probe chorusfb - measure the chorus feedback law, parameter 55.
//
//   s1probe chorusfb [dll] [--values <list|all>] [--note <n>] [--dump]
//
// This is the parameter that matters most in the bank and was never measured.
// 124 of the 128 factory patches store 55 = 0, which is the bottom of its range
// and displays "-99 %", and the null test says the engine is badly wrong there:
// on patch 001, feedback at the stored 0 gives 12.00 dB of envelope error and a
// stereo width of 0.638 against the reference's 0.910, where the same patch with
// 55 moved to its centre gives 4.02 dB and 0.242 against 0.391. Three times the
// error, at the setting almost every patch uses.
//
// The value is not being misread -- editing a patch's 55 changes the reference's
// own render too, so both engines apply the same number. What is wrong is what
// this engine *does* with it: `chorus_process` feeds the tap back as
// `input + tap * feedback` clamped at 0.95, which at the bottom of the knob is a
// hard resonator. The reference is evidently gentler. This measures how gentle.
//
// Method. The chorus is turned into a plain static comb -- depth zero so the tap
// stops sweeping, the longest centre delay so a round trip is easy to resolve --
// and struck with a short note. What is left afterwards is a feedback loop ringing
// down, and each pass round it multiplies by the feedback. So the decay of that
// tail, per round trip, *is* the feedback:
//
//     |feedback| = 10 ^ (dB per round trip / 20)
//
// Nothing about the reference's internals is assumed; only that a feedback loop
// with a fixed delay decays geometrically, which is what makes it a loop.
//
// The sign is not measurable this way and does not need to be: a decay rate is the
// same either way round, and the display already says which side of zero the knob
// is on.
package s1probe

import "core:fmt"
import "core:math"

import cpatch "../../src/patch"
import sengine "../../src/engine"

// The longest centre delay, so a round trip is 30 ms rather than a fraction of a
// millisecond. At the short end the loop rings so fast that the decay is over
// before the analysis frame has resolved it.
CHORUSFB_DELAY :: 127
CHORUSFB_SECONDS :: 2.0
CHORUSFB_FRAME_MS :: 5.0

// The wet level the comb is measured at, overridable with --level.
//
// Not a detail. If the reference applies its feedback after the level control
// rather than to the tap, then a quiet chorus has a quieter loop, and a law
// measured only at full wet would be wrong everywhere else -- which is what the
// bank says happens on the patches whose chorus is barely audible.
g_chorusfb_level := 127

chorusfb_patch :: proc(feedback: int) -> cpatch.Patch {
	p := neutral_probe_patch()

	// A sine, so the only thing in the tail is what the loop put there.
	set_param(&p, 0, 0)
	set_param(&p, 5, 0)
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 110)

	// A strike rather than a note: instant attack, fast decay, no sustain. What
	// is measured is the ring after it, so the excitation wants to be over.
	set_param(&p, 25, 0)
	set_param(&p, 26, 24)
	set_param(&p, 27, 0)
	set_param(&p, 28, 0)

	// The chorus as a static comb.
	set_param(&p, 66, 1) // on
	set_param(&p, 64, 1) // type 1: mono, so no channel offset in the way
	set_param(&p, 52, CHORUSFB_DELAY) // longest centre delay
	set_param(&p, 53, 0) // depth zero: the tap does not move
	set_param(&p, 54, 0) // slowest rate, for the same reason
	set_param(&p, 55, feedback)
	set_param(&p, 56, g_chorusfb_level)

	// Everything else that could ring or colour the tail.
	set_param(&p, 65, 0) // delay off
	set_param(&p, 77, 0) // extra effect off
	set_param(&p, 20, 0) // no filter resonance
	return p
}

// The decay of the tail, in decibels per second.
//
// Fitted by least squares over the part of the tail that is clear of both ends:
// the excitation at the start, and the noise floor at the bottom. Returns ok=false
// when there is not enough decay to fit, which is the honest answer at a feedback
// of zero -- there is no loop to measure.
chorusfb_decay_db_per_s :: proc(audio: []f32) -> (slope: f64, ok: bool) {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)

	frame := int(CHORUSFB_FRAME_MS * 0.001 * f64(SAMPLE_RATE))
	env := frame_envelope(mid, frame)
	defer delete(env)
	if len(env) < 16 {
		return 0, false
	}

	// The loudest frame, which is the strike.
	peak := 0.0
	peak_at := 0
	for v, i in env {
		if v > peak {
			peak = v
			peak_at = i
		}
	}
	if peak <= 0 {
		return 0, false
	}

	peak_db := amplitude_db(peak)
	// Start a little after the strike so the envelope is the loop and not the
	// note, and stop before the floor.
	from := peak_at + 4
	n := 0
	sx, sy, sxx, sxy := 0.0, 0.0, 0.0, 0.0
	for i in from ..< len(env) {
		if env[i] <= 0 {
			continue
		}
		db := amplitude_db(env[i])
		if db > peak_db - 3.0 {
			continue // still the strike
		}
		if db < peak_db - 60.0 {
			break // into the floor
		}
		t := f64(i) * CHORUSFB_FRAME_MS * 0.001
		sx += t
		sy += db
		sxx += t * t
		sxy += t * db
		n += 1
	}
	if n < 8 {
		return 0, false
	}
	denom := f64(n) * sxx - sx * sx
	if abs(denom) < 1.0e-12 {
		return 0, false
	}
	return (f64(n) * sxy - sx * sy) / denom, true
}

// Turn a decay rate into the feedback that produced it.
chorusfb_from_decay :: proc(slope_db_per_s, round_trip_s: f64) -> f64 {
	if round_trip_s <= 0 {
		return 0
	}
	per_trip := slope_db_per_s * round_trip_s
	g := math.pow(10.0, per_trip / 20.0)
	return clamp(g, 0.0, 1.0)
}

cmd_chorusfb :: proc(dll: string, spec: string, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	// The round trip is the centre delay, which parameter 52 states in
	// milliseconds. Read rather than assumed.
	round_trip_ms := f64(sengine.display_number(52, CHORUSFB_DELAY, 30.0))
	round_trip_s := round_trip_ms * 0.001

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	fmt.printfln("chorusfb: parameter 55 as a static comb, note %v, wet level %v", note, g_chorusfb_level)
	fmt.printfln("          centre delay %v ms, depth 0, full wet: one round trip is %v ms",
		dec2(round_trip_ms), dec2(round_trip_ms))
	fmt.println()
	fmt.printfln("%8v %10v %11v %11v %11v %11v",
		"stored", "display", "ref dB/s", "ref |fb|", "our dB/s", "our |fb|")

	for v in values {
		p := chorusfb_patch(v)
		dump_indices := []int{0, 5, 19, 25, 26, 27, 52, 53, 54, 55, 56, 64, 65, 66}
		ref_audio := probe_render(dll, &p, pristine, work, note, CHORUSFB_SECONDS, &dumped, dump_indices)
		if ref_audio == nil {
			continue
		}
		our_audio := render_ours(p, int(note))

		ref_slope, ref_ok := chorusfb_decay_db_per_s(ref_audio)
		our_slope, our_ok := chorusfb_decay_db_per_s(our_audio)
		delete(ref_audio)
		delete(our_audio)

		display := ""
		states := cpatch.parameter_states(55)
		if v >= 0 && v < len(states) {
			display = states[v].display
		}

		fmt.printfln("%8v %10v %11v %11v %11v %11v",
			v, display,
			ref_ok ? dec1(ref_slope) : "-",
			ref_ok ? dec3(chorusfb_from_decay(ref_slope, round_trip_s)) : "-",
			our_ok ? dec1(our_slope) : "-",
			our_ok ? dec3(chorusfb_from_decay(our_slope, round_trip_s)) : "-")
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("|fb| is the decay per round trip read back as a gain, so it is the feedback")
	fmt.println("the loop actually has rather than the number on the knob. Where the two |fb|")
	fmt.println("columns differ, that difference is the defect.")
}
