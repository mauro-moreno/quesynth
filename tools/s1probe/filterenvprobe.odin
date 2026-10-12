// s1probe cutoffprobe - read the filter's corner off the reference.
//
//   s1probe cutoffprobe [dll] [--sweep cutoff|amount|note|sustain] [--cutoff <n>]
//                             [--amount <n>] [--sustain <n>] [--values <list|all>]
//
// Method: noise through the low pass, and the corner read back off the spectrum
// as the -3 dB point of the response relative to a wide-open render. The corner it
// reports is where the response is 3 dB down, which sits above the filter's own
// natural frequency for a section with a Q of one; the cutoff axis in
// `src/engine/cutoff.odin` is the natural frequency.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"

// The patch the corner is measured through.
//
// The filter envelope is pinned to a constant rather than switched off: with the
// attack and decay instant and the sustain held, the envelope sits at a known
// level for the whole render, so whatever the amount knob does is applied in
// full and does not move while it is being measured. Setting the amount to its
// centre (stored 63, display "0") is what makes the base cutoff curve separable
// from the envelope's contribution.
// Keyboard tracking for the probe patch. `neutral_probe_patch` pins it off so
// the corner is note-independent; the tracking sweep needs it back.
g_probe_ktrack := 0

// Filter type and resonance for the probe patch. Default to the plain 12 dB
// low pass with no resonance, which is what every existing sweep assumes; a
// caller chasing a defect specific to the 24 dB path or to a resonant corner
// overrides these.
g_probe_filter_type := 0
g_probe_resonance := 0

filter_probe_patch :: proc(cutoff, amount, sustain: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 22, g_probe_ktrack)
	set_param(&p, 1, 4) // osc2: noise, a flat source
	set_param(&p, 5, 127) // oscillator 2 alone
	set_param(&p, 14, g_probe_filter_type)
	set_param(&p, 19, cutoff)
	set_param(&p, 20, g_probe_resonance)
	set_param(&p, 21, amount)
	set_param(&p, 15, 0) // filter envelope: instant attack
	set_param(&p, 16, 0) // no decay
	set_param(&p, 17, sustain) // held here for the whole render
	set_param(&p, 18, 0)
	set_param(&p, 29, 110)
	return p
}

// The -3 dB corner of a low pass, from the band response relative to an open
// render. Returns ok=false when the corner is outside the analysed band, which
// happens at both ends of the sweep and is a real answer rather than an error.
measure_corner :: proc(bands, open_bands, centres: []f64) -> (hz: f64, ok: bool) {
	if len(bands) == 0 || len(open_bands) == 0 {
		return 0, false
	}

	relative := make([]f64, len(bands))
	defer delete(relative)
	peak := -1.0e9
	for b in 0 ..< len(bands) {
		if bands[b] <= 0 || b >= len(open_bands) || open_bands[b] <= 0 {
			relative[b] = -999
			continue
		}
		relative[b] = power_db(bands[b] / open_bands[b])
		if relative[b] > peak {
			peak = relative[b]
		}
	}
	if peak < -900 {
		return 0, false
	}

	// The highest band still within 3 dB of the pass band, with the crossing
	// interpolated between that band and the next.
	//
	// Without the interpolation the answer is quantised to the 1/6-octave band
	// grid -- two semitones -- which is coarse enough to be the dominant error in
	// a curve whose whole point is where it sits in frequency. The first version
	// of this measurement reported the envelope amount moving in exact steps of
	// 2.00 octaves, which was the grid talking, not the filter.
	target := peak - 3.0
	edge := 0.0
	last_in := -1
	for b in 0 ..< len(relative) {
		if relative[b] > -900 && relative[b] >= target {
			last_in = b
		}
	}
	if last_in < 0 {
		return 0, false
	}
	edge = centres[last_in]
	// Interpolate in log frequency against the first band below the target.
	for b in last_in + 1 ..< len(relative) {
		if relative[b] <= -900 {
			continue
		}
		above := relative[last_in]
		below := relative[b]
		if above == below {
			break
		}
		t := (above - target) / (above - below)
		edge = centres[last_in] * math.pow(centres[b] / centres[last_in], clamp(t, 0, 1))
		break
	}
	if edge <= 0 {
		return 0, false
	}
	// A corner sitting on the last band means the real one is above the analysed
	// range and this is a floor, not a measurement.
	if edge >= BAND_HI_HZ * 0.7 {
		return edge, false
	}
	return edge, true
}

FILTER_PROBE_SECONDS :: 1.2

// Render one filter setting and return its corner.
probe_corner :: proc(
	dll: string,
	pristine, work: []byte,
	open_bands, centres: []f64,
	cutoff, amount, sustain: int,
	note: u8,
	dumped: ^bool,
) -> (
	hz: f64,
	ok: bool,
) {
	p := filter_probe_patch(cutoff, amount, sustain)
	dump_indices := []int{1, 5, 14, 15, 16, 17, 18, 19, 20, 21, 22, 25, 27, 29}
	audio := probe_render(dll, &p, pristine, work, note, FILTER_PROBE_SECONDS, dumped, dump_indices)
	if audio == nil {
		return 0, false
	}
	defer delete(audio)

	bands, band_centres, band_ok := probe_band_levels(audio)
	defer delete(bands)
	defer delete(band_centres)
	if !band_ok {
		return 0, false
	}
	return measure_corner(bands, open_bands, centres)
}

// The resonant peak's own frequency, read through the same probe patch
// `probe_corner` uses, rather than the -3 dB point against an open reference.
//
// Needs `g_probe_resonance` set to something the peak can actually be found on
// -- see `peak_hz_interpolated`'s note that a low pass at low resonance has no
// peak at all -- and exists because the -3 dB corner is not what a Q-biased
// reading like that gives when the filter has one: the peak's own frequency
// only approaches the true corner as resonance rises, so a corner measured with
// resonance held at its own maximum is the least Q-biased reading available,
// where the corner measured with resonance at 0 is Q-biased by construction on
// a filter with no peak to speak of. `docs/null-test.md` has the numbers.
probe_peak :: proc(
	dll: string,
	pristine, work: []byte,
	cutoff, amount, sustain: int,
	note: u8,
	dumped: ^bool,
) -> (
	hz: f64,
	ok: bool,
) {
	p := filter_probe_patch(cutoff, amount, sustain)
	dump_indices := []int{1, 5, 14, 15, 16, 17, 18, 19, 20, 21, 22, 25, 27, 29}
	audio := probe_render(dll, &p, pristine, work, note, FILTER_PROBE_SECONDS, dumped, dump_indices)
	if audio == nil {
		return 0, false
	}
	defer delete(audio)

	bands, band_centres, band_ok := probe_band_levels(audio)
	defer delete(bands)
	defer delete(band_centres)
	if !band_ok {
		return 0, false
	}
	return peak_hz_interpolated(bands, band_centres)
}

// The wide-open render every corner is measured against.
filter_open_reference :: proc(
	dll: string,
	pristine, work: []byte,
	note: u8,
) -> (
	bands, centres: []f64,
	ok: bool,
) {
	p := filter_probe_patch(127, 63, 127)
	audio := probe_render(dll, &p, pristine, work, note, FILTER_PROBE_SECONDS, nil, nil)
	if audio == nil {
		return nil, nil, false
	}
	defer delete(audio)
	return probe_band_levels(audio)
}

// This engine's side of `probe_corner` and `filter_open_reference`: the same
// -3 dB corner, read off `render_ours` instead of the reference, and
// normalised against this engine's own wide-open render rather than the
// reference's -- comparing against the reference's open band levels would
// charge this engine for any gain difference between the two at full open,
// which is a different question from where the corner sits.
open_ours :: proc(note: u8) -> (bands, centres: []f64, ok: bool) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(FILTER_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	p := filter_probe_patch(127, 63, 127)
	audio := render_ours(p, int(note))
	if audio == nil {
		return nil, nil, false
	}
	defer delete(audio)
	return probe_band_levels(audio)
}

corner_ours :: proc(open_bands, centres: []f64, cutoff, amount, sustain: int, note: u8) -> (hz: f64, ok: bool) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(FILTER_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	p := filter_probe_patch(cutoff, amount, sustain)
	audio := render_ours(p, int(note))
	if audio == nil {
		return 0, false
	}
	defer delete(audio)
	bands, band_centres, band_ok := probe_band_levels(audio)
	defer delete(bands)
	defer delete(band_centres)
	if !band_ok {
		return 0, false
	}
	return measure_corner(bands, open_bands, centres)
}

cmd_cutoffprobe :: proc(dll: string, sweep: string, cutoff, amount, sustain: int, spec: string, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	open_bands, centres, open_ok := filter_open_reference(dll, pristine, work, note)
	defer delete(open_bands)
	defer delete(centres)
	if !open_ok {
		fmt.eprintln("cutoffprobe: the open reference produced no spectrum")
		os.exit(1)
	}

	values := parse_env_values(spec)
	defer delete(values)
	dumped := !dump

	// A third mode: hold the filter still and sweep the *note*, which is how the
	// keyboard-tracking law and -- more to the point -- the note it tracks from
	// are measured. `voice_process` assumes middle C, and that assumption is a
	// chosen one; several patches whose tracking is at maximum come out far too
	// dark here, which is what a wrong reference note would do.
	if sweep == "note" {
		fmt.printfln("cutoffprobe: sweeping the note, cutoff %v, keyboard tracking %v",
			cutoff, g_probe_ktrack)
		fmt.println()
		fmt.printfln("%8v %10v %12v", "note", "corner Hz", "vs note 60")
		reference := 0.0
		if hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, 63, sustain, 60, &dumped); ok {
			reference = hz
		}
		notes := []u8{24, 36, 48, 60, 72, 84, 96}
		for n in notes {
			hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, 63, sustain, n, &dumped)
			if !ok {
				fmt.printfln("%8v %10v %12v", n, hz > 0 ? dec0(hz) : "-", "out of range")
				continue
			}
			octaves := reference > 0 ? log2f(hz / reference) : 0
			fmt.printfln("%8v %10v %12v", n, dec0(hz), sdec2(octaves))
			free_all(context.temp_allocator)
		}
		fmt.println()
		fmt.println("Full tracking should give one octave of corner per octave of note. Where")
		fmt.println("the line crosses zero is the note the reference tracks from.")
		return
	}

	// A fourth mode: sweep the filter envelope's sustain level.
	//
	// The amplitude envelope's sustain got a measured curve; this one is still a
	// linear reading of the knob, and it is an envelope-shape parameter -- it sets
	// where the filter sits for the whole held portion of every note, so a wrong
	// curve here is a wrong contour rather than merely a wrong colour.
	//
	// The envelope amount is held at a strongly negative setting so the corner has
	// a long way to travel, and the sustain fraction is read off as the share of
	// that travel actually taken.
	if sweep == "sustain" {
		fmt.printfln("cutoffprobe: sweeping the filter envelope sustain, cutoff %v, amount %v, type %v, resonance %v",
			cutoff, amount, g_probe_filter_type, g_probe_resonance)
		fmt.println()
		at_zero := 0.0
		at_full := 0.0
		if hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, amount, 0, note, &dumped); ok {
			at_zero = hz
		}
		if hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, amount, 127, note, nil); ok {
			at_full = hz
		}
		if at_zero <= 0 || at_full <= 0 {
			fmt.eprintln("cutoffprobe: could not measure the ends of the sustain range")
			return
		}
		full_travel := log2f(at_full / at_zero)
		fmt.printfln("sustain 0 puts the corner at %v Hz, sustain 127 at %v Hz: %v octaves of travel",
			dec0(at_zero), dec0(at_full), sdec2(full_travel))

		our_open_bands, our_centres, our_open_ok := open_ours(note)
		defer delete(our_open_bands)
		defer delete(our_centres)
		fmt.println()
		fmt.printfln("%8v %10v %12v %12v %10v %10v", "stored", "corner Hz", "fraction", "if linear", "our Hz", "our oct")
		for v in values {
			hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, amount, v, note, nil)
			our_hz, our_ok := 0.0, false
			if our_open_ok {
				our_hz, our_ok = corner_ours(our_open_bands, our_centres, cutoff, amount, v, note)
			}
			if !ok {
				fmt.printfln("%8v %10v", v, pad_left("-", 10))
				continue
			}
			fraction := log2f(hz / at_zero) / full_travel
			our_oct := our_ok && hz > 0 ? sdec2(log2f(our_hz / hz)) : "-"
			fmt.printfln("%8v %10v %12v %12v %10v %10v",
				v, dec0(hz), dec4(fraction), dec4(f64(v) / 127.0), our_ok ? dec0(our_hz) : "-", our_oct)
			free_all(context.temp_allocator)
		}
		return
	}

	sweeping_cutoff := sweep != "amount"
	fmt.printfln("cutoffprobe: sweeping %v, note %v, filter type %v, resonance %v",
		sweeping_cutoff ? "the cutoff knob" : "the envelope amount", note,
		g_probe_filter_type, g_probe_resonance)
	if sweeping_cutoff {
		fmt.printfln("             envelope amount held at %v, sustain %v", amount, sustain)
	} else {
		fmt.printfln("             cutoff held at %v, sustain %v", cutoff, sustain)
	}
	fmt.println()

	reference_hz := 0.0
	if !sweeping_cutoff {
		// The corner with the amount at its centre, which every offset is
		// measured against.
		if hz, ok := probe_corner(dll, pristine, work, open_bands, centres, cutoff, 63, sustain, note, &dumped); ok {
			reference_hz = hz
		}
		fmt.printfln("amount 63 (display \"0\") puts the corner at %v Hz", dec0(reference_hz))
		fmt.println()
	}

	our_open_bands, our_centres, our_open_ok := open_ours(note)
	defer delete(our_open_bands)
	defer delete(our_centres)
	fmt.printfln("%8v %10v %12v %10v %10v", "stored", "corner Hz",
		sweeping_cutoff ? "octaves" : "offset oct", "our Hz", "our oct")
	for v in values {
		hz, ok := probe_corner(
			dll, pristine, work, open_bands, centres,
			sweeping_cutoff ? v : cutoff,
			sweeping_cutoff ? amount : v,
			sustain, note, &dumped,
		)
		if !ok {
			fmt.printfln("%8v %10v %12v", v, hz > 0 ? dec0(hz) : "-", "out of range")
			continue
		}
		our_hz, our_ok := 0.0, false
		if our_open_ok {
			our_hz, our_ok = corner_ours(
				our_open_bands, our_centres,
				sweeping_cutoff ? v : cutoff,
				sweeping_cutoff ? amount : v,
				sustain, note,
			)
		}
		octaves := reference_hz > 0 ? log2f(hz / reference_hz) : log2f(hz / 20.0)
		our_oct := our_ok && hz > 0 ? sdec2(log2f(our_hz / hz)) : "-"
		fmt.printfln("%8v %10v %12v %10v %10v", v, dec0(hz), sdec2(octaves),
			our_ok ? dec0(our_hz) : "-", our_oct)
		free_all(context.temp_allocator)
	}
}
