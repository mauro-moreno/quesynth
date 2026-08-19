// s1probe lfodepth - measure how far the LFO actually moves each destination.
//
// `s1probe lfoprobe` identified what each of the seven destination states does.
// It did not measure how *much*, and every scaling constant in the LFO loop of
// `voice_process` is still a guess: twelve semitones of pitch, four octaves of
// cutoff, a half-depth amplitude law, unity for FM and pan. Correcting the
// destination mapping against measurement made the null test worse for exactly
// this reason -- a right destination driven by a wrong depth can be further from
// the reference than a wrong destination that happened to be mild.
//
//   s1probe lfodepth [dll] [--param 41|46] [--values <list|all>] [--note <n>]
//                          [--rate <n>] [--dump]
//   s1probe lfodepthtable [dll] [out.odin]
//
// Method: drive one destination at one depth, render, and read the *range* the
// observable moved over -- peak to peak, so the LFO's waveform and starting
// phase do not matter. Half that range is the peak deviation, which is what the
// engine's scaling constants mean.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"

// The destinations worth sweeping: the ones whose effect is directly observable.
//
// State 5 is inert and state 6 is FM, whose depth is not a quantity the spectrum
// reports directly -- it would have to be matched against known settings of
// parameter 45, which is a different measurement.
LFO_DEPTH_STATES := []int{1, 2, 3, 4, 7}

lfo_depth_state_name :: proc(state: int) -> string {
	switch state {
	case 1:
		return "osc2 pitch"
	case 2:
		return "both pitch"
	case 3:
		return "cutoff"
	case 4:
		return "volume"
	case 7:
		return "pan"
	}
	return "?"
}

// A cutoff sweep needs a much longer render than the others: the corner is read
// with the same 16384-point transform the rest of the filter work uses, which is
// 341 ms, so the LFO has to be slow enough to sit still inside a window and the
// render long enough to still cover a whole cycle.
LFO_DEPTH_SECONDS :: 3.0
LFO_CUTOFF_SECONDS :: 10.0
LFO_CUTOFF_RATE :: 8

lfo_depth_patch :: proc(
	state, depth: int,
	dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	rate: int,
) -> cpatch.Patch {
	p := neutral_probe_patch()

	switch state {
	case 1:
		// Oscillator 2 alone, so its own pitch is what the spectrum reports.
		//
		// A triangle, not a saw. The pitch is read as the strongest bin, and a
		// saw swept over several octaves defeats that: at the bottom of the sweep
		// its fundamental lands in the first few FFT bins where a harmonic can be
		// stronger, and the reported depth then depends on the note played -- 42,
		// 36 and 30 semitones at three notes an octave apart, which an LFO depth
		// cannot be. A triangle's harmonics fall as 1/n^2, so its fundamental
		// stays the strongest bin across the whole sweep.
		set_param(&p, 1, 3) // osc2: triangle
		set_param(&p, 5, 127)
		set_param(&p, 19, 127) // filter open
	case 2:
		// Oscillator 1 alone; this destination moves both, so either will do, and
		// oscillator 1 has a sine -- one partial, nothing to confuse.
		set_param(&p, 0, 0) // osc1: sine
		set_param(&p, 5, 0)
		set_param(&p, 19, 127)
	case 3:
		// Noise through the low pass, the same source the filter measurements
		// use, so the corner can be read off the spectrum.
		set_param(&p, 1, 4) // osc2: noise
		set_param(&p, 5, 127)
		set_param(&p, 14, 0) // low pass 12
		set_param(&p, 19, 64) // mid cutoff, room to move both ways
		set_param(&p, 20, 0)
	case:
		// Volume and pan: a sine, so level and stereo position are clean.
		set_param(&p, 0, 0)
		set_param(&p, 5, 0)
		set_param(&p, 19, 127)
	}

	set_param(&p, 29, 110)
	set_param(&p, on_index, 1)
	set_param(&p, dest_index, state)
	set_param(&p, speed_index, rate)
	set_param(&p, depth_index, depth)
	set_param(&p, keysync_index, 1)
	set_param(&p, temposync_index, 0)
	return p
}

// The octave range the corner moves over, measured window by window.
//
// The corner is read in overlapping windows across the whole render and the
// extremes taken, so the LFO's shape and starting phase drop out -- there is no
// need to know where in its cycle the render began.
cutoff_span_octaves :: proc(audio: []f32, open_bands, centres: []f64) -> (octaves: f64, ok: bool) {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < FFT_SIZE * 2 {
		return 0, false
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

	corners: [dynamic]f64
	defer delete(corners)

	step := FFT_SIZE / 2
	for from := 0; from + FFT_SIZE * 2 <= len(mid); from += step {
		power := welch_power(mid, from, from + FFT_SIZE * 2)
		if power == nil {
			continue
		}
		bands, band_centres := band_powers(power, bin_hz)
		hz, hit := measure_corner(bands, open_bands, centres)
		delete(bands)
		delete(band_centres)
		delete(power)
		if !hit || hz <= 0 {
			continue
		}
		// Kept in octaves, so the percentile range below is already the answer.
		append(&corners, log2f(hz))
	}

	if len(corners) < 8 {
		return 0, false
	}
	// A percentile range over the collected corners, not min to max. A corner
	// estimated from a noise source jitters window to window, and min-to-max
	// reports that jitter: an unmodulated sweep came out at two octaves.
	return span(corners[:]), true
}

Lfo_Depth_Row :: struct {
	state:   int,
	depth:   int,
	// The peak deviation, in the destination's own units: semitones for pitch,
	// octaves for cutoff, dB for volume, a -1..1 fraction for pan.
	value:   f64,
	ok:      bool,
}

measure_lfo_depth :: proc(
	dll: string,
	pristine, work: []byte,
	open_bands, centres: []f64,
	state, depth: int,
	dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	rate: int,
	note: u8,
	dumped: ^bool,
) -> Lfo_Depth_Row {
	row := Lfo_Depth_Row {
		state = state,
		depth = depth,
	}

	is_cutoff := state == 3
	seconds := is_cutoff ? f64(LFO_CUTOFF_SECONDS) : f64(LFO_DEPTH_SECONDS)
	use_rate := is_cutoff ? LFO_CUTOFF_RATE : rate

	p := lfo_depth_patch(state, depth, dest_index, speed_index, depth_index,
		on_index, keysync_index, temposync_index, use_rate)
	dump_indices := []int{0, 1, 5, 14, 19, 29, dest_index, speed_index, depth_index, on_index}
	audio := probe_render(dll, &p, pristine, work, note, seconds, dumped, dump_indices)
	if audio == nil {
		return row
	}
	defer delete(audio)

	if is_cutoff {
		span, ok := cutoff_span_octaves(audio, open_bands, centres)
		// Half the range is the peak deviation either side of the nominal cutoff.
		row.value = span * 0.5
		row.ok = ok
		return row
	}

	o := observe_modulation(audio)
	if o.silent {
		return row
	}
	switch state {
	case 1, 2:
		// Cents peak to peak, reported as semitones of peak deviation.
		row.value = o.pitch_cents * 0.5 / 100.0
		row.ok = o.pitch_cents > 1.0
	case 4:
		row.value = o.amplitude_db
		row.ok = o.amplitude_db > 0.05
	case 7:
		row.value = o.pan * 0.5
		row.ok = o.pan > 0.005
	}
	return row
}

cmd_lfodepth :: proc(dll: string, param: int, spec: string, note: u8, rate: int, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	open_bands, centres, open_ok := filter_open_reference(dll, pristine, work, note)
	defer delete(open_bands)
	defer delete(centres)
	if !open_ok {
		fmt.eprintln("lfodepth: the open reference produced no spectrum")
		os.exit(1)
	}

	is_lfo1 := param != 46
	dest_index := is_lfo1 ? 41 : 46
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	fmt.printfln("lfodepth: parameter %v, note %v, rate %v", depth_index, note, rate)
	fmt.println()
	fmt.println("Peak deviation per destination: semitones for pitch, octaves for cutoff,")
	fmt.println("dB for volume, a fraction of full width for pan.")
	fmt.println()

	for state in LFO_DEPTH_STATES {
		fmt.printfln("-- state %v, %v --", state, lfo_depth_state_name(state))
		for depth in values {
			row := measure_lfo_depth(
				dll, pristine, work, open_bands, centres, state, depth,
				dest_index, speed_index, depth_index, on_index, keysync_index,
				temposync_index, rate, note, &dumped,
			)
			if row.ok {
				fmt.printfln("   depth %v  %v", pad_left(fmt.tprintf("%v", depth), 4), dec3(row.value))
			} else {
				fmt.printfln("   depth %v  %v", pad_left(fmt.tprintf("%v", depth), 4), pad_left("-", 8))
			}
			free_all(context.temp_allocator)
		}
		fmt.println()
	}
}
