// s1probe lforate - measure the LFO's speed curve.
//
// Parameter 43 and 48 are a bare 0..127, so the display says nothing about time and
// the rate was read off this probe: point the LFO at the stereo position, count how
// often it crosses its own mean, and the curve comes out. It turned out to be
// `1500^(s/127) / 12` Hz exactly (`lfo_rate_hz`), which the counts, being a
// staircase of whole crossings, only approached to within 1.7%.
//
//   s1probe lforate      [dll] [--param 43|48] [--values <list|all>] [--dump]
//
// Method: point the LFO at the stereo position, which gives a clean bipolar
// scalar per frame that no amount of amplitude or filter behaviour can
// contaminate, then count how often that scalar crosses its own mean. Two
// crossings to a cycle. The render grows until enough cycles are in it to
// measure, so the same code covers a sixteen-second sweep and a twenty-hertz one.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"

// Frames for the pan series, and the note the probe plays.
//
// One millisecond, which samples the LFO at 1 kHz. Five was the first choice and
// it was not enough: this LFO reaches audio rate. At 5 ms the sweep read 52 Hz at
// stored 112 and then *38* at 127 -- lower at a higher setting, which is the
// series aliasing rather than the LFO slowing down. The curve extrapolates to
// about 130 Hz at the top, and the version history's "LFO maximum speed up" entry
// says that is deliberate.
//
// A frame has to hold at least a cycle of the note for its channel RMS to mean
// anything, so a 1 ms frame needs a high note: C7 fits two cycles into one.
RATE_FRAME_MS :: 1.0
RATE_PROBE_NOTE :: u8(96)

// How long the render starts at and how far it may grow.
//
// The bottom of the range is slow: at a chosen 0.05 Hz it would need forty
// seconds for two cycles. Growing on demand keeps the fast end cheap.
RATE_SECONDS_START :: 4.0
RATE_SECONDS_MAX :: 96.0
// Enough crossings that a half-cycle of error is small.
RATE_MIN_CROSSINGS :: 7

lfo_rate_patch :: proc(
	speed: int,
	dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	tempo_sync: bool,
) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 110)

	set_param(&p, on_index, 1)
	set_param(&p, dest_index, 7) // pan: a clean bipolar observable
	set_param(&p, speed_index, speed)
	set_param(&p, depth_index, 127)
	set_param(&p, keysync_index, 1) // same starting phase every render
	set_param(&p, temposync_index, tempo_sync ? 1 : 0)
	return p
}

// Stereo position per frame, on -1..1.
pan_series :: proc(audio: []f32, frame_len: int) -> []f64 {
	if frame_len <= 0 || len(audio) < frame_len * 4 {
		return nil
	}
	frames := len(audio) / (frame_len * 2)
	out := make([]f64, frames)
	for f in 0 ..< frames {
		base := f * frame_len * 2
		left := 0.0
		right := 0.0
		for i in 0 ..< frame_len {
			l := f64(audio[base + i * 2])
			r := f64(audio[base + i * 2 + 1])
			left += l * l
			right += r * r
		}
		l_rms := math.sqrt(left / f64(frame_len))
		r_rms := math.sqrt(right / f64(frame_len))
		total := l_rms + r_rms
		out[f] = total > 0 ? (l_rms - r_rms) / total : 0
	}
	return out
}

// Count crossings of the series' own mean, with hysteresis.
//
// The hysteresis is what keeps a noisy frame from being counted as a cycle: the
// series has to travel a real fraction of its own range to one side and then to
// the other before a crossing is recorded.
count_crossings :: proc(series: []f64) -> (crossings: int, usable: bool) {
	if len(series) < 8 {
		return 0, false
	}

	// Mean and range over the middle of the render, away from the note's edges.
	trim := max(len(series) / 20, 1)
	middle := series[trim:len(series) - trim]
	if len(middle) < 8 {
		return 0, false
	}
	mean := 0.0
	lo := middle[0]
	hi := middle[0]
	for v in middle {
		mean += v
		if v < lo {lo = v}
		if v > hi {hi = v}
	}
	mean /= f64(len(middle))
	range := hi - lo
	// Nothing is moving: not a rate, and not an error either.
	if range < 0.05 {
		return 0, false
	}

	threshold := range * 0.25
	// -1 below the low mark, +1 above the high mark, 0 in between.
	state := 0
	for v in middle {
		d := v - mean
		if d > threshold {
			if state == -1 {
				crossings += 1
			}
			state = 1
		} else if d < -threshold {
			if state == 1 {
				crossings += 1
			}
			state = -1
		}
	}
	return crossings, true
}

// Measure one speed setting, growing the render until enough cycles fit.
measure_lfo_rate :: proc(
	dll: string,
	pristine, work: []byte,
	speed: int,
	dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	tempo_sync: bool,
	note: u8,
	dumped: ^bool,
) -> (
	hz: f64,
	ok: bool,
) {
	frame_len := int(RATE_FRAME_MS * 0.001 * f64(SAMPLE_RATE))
	dump_indices := []int{0, 5, 19, 29, dest_index, speed_index, depth_index, on_index, temposync_index}

	seconds := f64(RATE_SECONDS_START)
	for {
		p := lfo_rate_patch(speed, dest_index, speed_index, depth_index, on_index,
			keysync_index, temposync_index, tempo_sync)
		audio := probe_render(dll, &p, pristine, work, note, seconds, dumped, dump_indices)
		if audio == nil {
			return 0, false
		}
		series := pan_series(audio, frame_len)
		delete(audio)
		if series == nil {
			return 0, false
		}
		crossings, usable := count_crossings(series)
		// The analysed span is the trimmed middle, which is what the crossings
		// were counted over.
		trim := max(len(series) / 20, 1)
		analysed := f64(len(series) - trim * 2) * RATE_FRAME_MS * 0.001
		delete(series)

		if !usable {
			return 0, false
		}
		if crossings >= RATE_MIN_CROSSINGS || seconds >= RATE_SECONDS_MAX {
			if crossings < 2 {
				return 0, false
			}
			// Two crossings to a cycle.
			return f64(crossings) / (2.0 * analysed), true
		}
		seconds *= 2.0
	}
}

cmd_lforate :: proc(dll: string, param: int, spec: string, note: u8, tempo_sync: bool, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	is_lfo1 := param != 48
	dest_index := is_lfo1 ? 41 : 46
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	fmt.printfln("lforate: parameter %v, note %v, tempo sync %v, host tempo %v BPM",
		speed_index, note, tempo_sync, int(HOST_TEMPO))
	fmt.println()
	fmt.printfln("%8v %10v %12v %10v", "stored", "Hz", "period s", tempo_sync ? "beats" : "vs chosen")
	for v in values {
		hz, ok := measure_lfo_rate(dll, pristine, work, v, dest_index, speed_index,
			depth_index, on_index, keysync_index, temposync_index, tempo_sync, note, &dumped)
		if !ok {
			fmt.printfln("%8v %10v", v, pad_left("-", 10))
			free_all(context.temp_allocator)
			continue
		}
		// What the engine's chosen curve would have said, for comparison.
		chosen := 0.05 * math.pow(f64(40.0) / 0.05, f64(v) / 127.0)
		extra := tempo_sync \
			? dec3((HOST_TEMPO / 60.0) / hz) \
			: fmt.tprintf("%vx", dec2(hz / chosen))
		fmt.printfln("%8v %10v %12v %10v", v, dec4(hz), dec3(1.0 / hz), extra)
		free_all(context.temp_allocator)
	}
}
