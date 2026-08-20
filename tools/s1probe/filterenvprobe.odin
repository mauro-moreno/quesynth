// s1probe cutoffprobe / filtertable - measure the filter's frequency mapping.
//
// Two more chosen curves, and the null test says they are now the visible fault:
//
//   parameter 19, cutoff       bound as an exponential 20 Hz..20 kHz, "the
//                              chosen curve" by its own comment
//   parameter 21, env amount   bound as display/64, then scaled by an invented
//                              six octaves in voice_process
//
// On twenty factory patches the reference renders near silence -- peak
// amplitudes around 0.0004 against this engine's 0.24 -- and they share a
// signature: a low cutoff paired with a *negative* envelope amount. Synth1
// closes the filter almost completely on those patches and this engine does not,
// which means the six octaves are wrong, the cutoff curve is wrong, or both.
//
//   s1probe cutoffprobe [dll] [--sweep cutoff|amount] [--cutoff <n>]
//                             [--amount <n>] [--sustain <n>] [--values <list|all>]
//   s1probe filtertable [dll] [out.odin]
//
// Method: noise through the low pass, and the corner read back off the spectrum
// as the -3 dB point of the response relative to a wide-open render. That is the
// same measurement `filterprobe` uses to classify the filter types, applied to a
// sweep instead of to the five type states.
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

// Sweep both curves and write them out as Odin source.
//
// `filter_type` selects which of parameter 14's states the sweep is measured
// through. It matters because the 24 dB path is not the 12 dB path with a
// steeper slope bolted on -- see the comment on `FILTER_DAMPING_24` -- and
// there is no reason to expect its cutoff or its envelope-amount law to land
// on the same numbers. A non-zero type gets its own symbol suffix so both
// tables can be generated into the same package without colliding.
//
// `peak_resonance` switches the reading. Negative keeps the original method --
// the -3 dB corner against an open reference, at resonance 0 -- which is right
// where there is no peak to read. Zero or above reads the resonant peak's own
// frequency instead, with resonance held at that value for the whole sweep;
// see `probe_peak`'s comment for why that is the less Q-biased reading once a
// peak exists to be biased.
cmd_filtertable :: proc(dll: string, out_path: string, note: u8, filter_type: int, peak_resonance: int) {
	g_probe_filter_type = filter_type
	use_peak := peak_resonance >= 0
	if use_peak {
		g_probe_resonance = peak_resonance
	}
	suffix := filter_type == 1 ? "_24" : ""

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	open_bands, centres, open_ok := filter_open_reference(dll, pristine, work, note)
	defer delete(open_bands)
	defer delete(centres)
	if !use_peak && !open_ok {
		fmt.eprintln("filtertable: the open reference produced no spectrum")
		os.exit(1)
	}

	read_hz :: proc(
		use_peak: bool,
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
		if use_peak {
			return probe_peak(dll, pristine, work, cutoff, amount, sustain, note, dumped)
		}
		return probe_corner(dll, pristine, work, open_bands, centres, cutoff, amount, sustain, note, dumped)
	}

	fmt.printfln("measuring the filter's frequency mapping for type %v, two sweeps of 128 settings, %v",
		filter_type, use_peak ? fmt.tprintf("peak at resonance %v", peak_resonance) : "corner at resonance 0")

	// -- the cutoff curve, with the envelope contributing nothing -------------
	cutoffs := make([]f64, 128)
	defer delete(cutoffs)
	cutoff_ok := make([]bool, 128)
	defer delete(cutoff_ok)
	measured := 0
	dumped := true
	for v in 0 ..< 128 {
		hz, ok := read_hz(use_peak, dll, pristine, work, open_bands, centres, v, 63, 127, note, &dumped)
		cutoffs[v] = hz
		cutoff_ok[v] = ok
		if ok {
			measured += 1
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("  cutoff        %v of 128 settings resolved", measured)

	if use_peak {
		smooth_log(cutoffs, cutoff_ok)
	}

	// The top of the range runs past what the analysis band can see. Those
	// entries are extrapolated along the curve's own slope rather than left at a
	// floor, and the extrapolation is marked in the generated file.
	extrapolate_tail(cutoffs, cutoff_ok)
	// The peak-frequency reading can also come back empty at the *bottom* of
	// the range, where the corner reading never did -- see `extrapolate_head`.
	extrapolate_head(cutoffs, cutoff_ok)

	// -- the envelope amount, as an octave offset -----------------------------
	//
	// Measured at a mid cutoff so there is room to move in both directions, with
	// the envelope pinned at full sustain so the amount is applied in full.
	BASE_CUTOFF :: 64
	base_hz := 0.0
	if hz, ok := read_hz(use_peak, dll, pristine, work, open_bands, centres, BASE_CUTOFF, 63, 127, note, nil); ok {
		base_hz = hz
	}
	if base_hz <= 0 {
		fmt.eprintln("filtertable: could not measure the reference corner")
		os.exit(1)
	}

	offsets := make([]f64, 128)
	defer delete(offsets)
	offset_ok := make([]bool, 128)
	defer delete(offset_ok)
	measured = 0
	for v in 0 ..< 128 {
		hz, ok := read_hz(use_peak, dll, pristine, work, open_bands, centres, BASE_CUTOFF, v, 127, note, nil)
		if ok && hz > 0 {
			offsets[v] = log2f(hz / base_hz)
			offset_ok[v] = true
			measured += 1
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("  env amount    %v of 128 settings resolved", measured)

	// Fit the amount as a straight line in octaves, from the settings that were
	// not pressed against the filter's own limits.
	//
	// A table would be wrong here, unlike for the cutoff. The measured offsets
	// saturate at both ends -- not because the amount curve bends, but because
	// the corner has run into the filter's floor and ceiling at the base cutoff
	// this was measured at. Baking that saturation into a table would apply the
	// limits of one cutoff setting to every other. The engine already clamps the
	// cutoff it computes, so the honest thing to store is the unclipped law.
	slope, centre, fit_ok := fit_env_amount(offsets, offset_ok, cutoffs, base_hz)
	if !fit_ok {
		fmt.eprintln("filtertable: could not fit the envelope amount")
		os.exit(1)
	}
	fmt.printfln("  env amount    %v octaves per step, centre at %v", dec4(slope), dec1(centre))

	metric_desc := use_peak \
		? fmt.tprintf("the resonant peak's own frequency, resonance held at %v for the whole sweep", peak_resonance) \
		: "the -3 dB point against a wide-open render, resonance 0"

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, `// Code generated by "s1probe filtertable --type %v"; do not edit.
//
// The reference Synth1's filter frequency mapping for parameter 14's type %v,
// indexed by parameter 19's resolved state. Method is in docs/null-test.md; in
// short, noise through the filter with the envelope pinned flat, and the
// corner read off the spectrum as %v.
//
// FILTER_CUTOFF_HZ%v replaces a chosen exponential from 20 Hz to 20 kHz.
//
// FILTER_ENV_OCTAVES_PER_STEP%v is how far the corner moves when the envelope
// is at full level, in octaves, per setting of parameter 21. Stored 63 is the
// centre and measures as zero by construction: every entry is relative to the
// corner at that setting.
//
// Both were measured at a base cutoff of %v. The top of each sweep runs past
// what the analysis band can resolve; those entries are extrapolated along the
// curve's own final slope and are marked below.
package engine

`, filter_type, filter_type, metric_desc, suffix, suffix, BASE_CUTOFF)

	if filter_type == 0 {
		// Declared once, here, since the type-24 file shares this package and
		// indexes its own tables with the same constant.
		strings.write_string(&b, "FILTER_TABLE_SIZE :: 128\n\n")
	}

	emit_filter_table :: proc(b: ^strings.Builder, name: string, values: []f64, ok: []bool, unit: string) {
		first, last := len(ok), 0
		for i in 0 ..< len(ok) {
			if ok[i] {
				if i < first {
					first = i
				}
				last = i
			}
		}
		if first == 0 {
			fmt.sbprintf(b, "// %v. Measured through index %v; beyond that, extrapolated.\n", unit, last)
		} else {
			fmt.sbprintf(b, "// %v. Measured from index %v through %v; outside that, extrapolated.\n", unit, first, last)
		}
		fmt.sbprintf(b, "%v := [FILTER_TABLE_SIZE]f32{{\n", name)
		for i in 0 ..< len(values) {
			if i % 4 == 0 {
				strings.write_string(b, "\t")
			}
			fmt.sbprintf(b, "%.4f,", values[i])
			if i % 4 == 3 {
				strings.write_string(b, "\n")
			} else {
				strings.write_string(b, " ")
			}
		}
		strings.write_string(b, "}\n\n")
	}

	emit_filter_table(&b, fmt.tprintf("FILTER_CUTOFF_HZ%v", suffix), cutoffs, cutoff_ok, "Hertz")

	fmt.sbprintf(&b, `// How far the filter envelope moves the corner, in octaves per step of
// parameter 21, when the envelope is at full level. Measured by fitting the
// settings that were not pressed against the filter's own floor or ceiling.
//
// Stored as a law rather than a table on purpose. The measured offsets saturate
// at both ends of the sweep, but that is the corner hitting the filter's limits
// at the cutoff it was measured from, not the amount curve bending -- and a
// table would apply one cutoff setting's limits to every other. The engine
// clamps the cutoff it computes, which is where the limits belong.
FILTER_ENV_OCTAVES_PER_STEP%v :: f32(%.6f)

// The setting at which the envelope contributes nothing. Parameter 21's states
// run from "-63" upwards, so this is the state whose display reads "0".
FILTER_ENV_CENTRE_STATE%v :: %v

`, suffix, slope, suffix, int(centre + 0.5))

	if os.write_entire_file(out_path, transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintfln("filtertable: could not write %v", out_path)
		os.exit(1)
	}
	fmt.printfln("wrote %v", out_path)
	fmt.printfln("cutoff  %v Hz .. %v Hz", dec0(cutoffs[0]), dec0(cutoffs[127]))
	fmt.printfln("amount  %v .. %v octaves (centre at 63 is %v)",
		sdec2(offsets[0]), sdec2(offsets[127]), sdec2(offsets[63]))
}

// Least-squares fit of the envelope amount as octaves per step.
//
// Only the settings whose corner is clear of the filter's own range are used:
// the measurement saturates once the corner reaches the floor or the ceiling,
// and including those points would flatten the slope towards zero. The bounds
// come from the cutoff sweep itself, which is what the filter can actually
// reach.
fit_env_amount :: proc(offsets: []f64, ok: []bool, cutoffs: []f64, base_hz: f64) -> (slope, centre: f64, fitted: bool) {
	floor_hz := cutoffs[0]
	ceiling_hz := 0.0
	for hz in cutoffs {
		if hz > ceiling_hz {
			ceiling_hz = hz
		}
	}
	// A margin of a third of an octave off each limit, so a point that is merely
	// near the end is not treated as clear of it.
	//
	// `base_hz` is the corner actually measured at the offset sweep's own base
	// cutoff (parameter 19 at `BASE_CUTOFF`, envelope amount at its centre) --
	// what `offsets[]` is itself relative to -- rather than an assumed constant.
	// The two filter types do not share a cutoff curve, so they do not share this
	// number either: using one type's figure to bound the other's fit would misplace
	// the exclusion margin by however far the two curves have drifted apart at that
	// setting.
	low_limit := log2f(floor_hz / base_hz) + 0.33
	high_limit := log2f(ceiling_hz / base_hz) - 0.33

	n := 0
	sx, sy, sxx, sxy := 0.0, 0.0, 0.0, 0.0
	for i in 0 ..< len(offsets) {
		if !ok[i] || offsets[i] <= low_limit || offsets[i] >= high_limit {
			continue
		}
		x := f64(i)
		y := offsets[i]
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
		n += 1
	}
	if n < 8 {
		return 0, 0, false
	}
	denom := f64(n) * sxx - sx * sx
	if abs(denom) < 1.0e-12 {
		return 0, 0, false
	}
	slope = (f64(n) * sxy - sx * sy) / denom
	intercept := (sy - slope * sx) / f64(n)
	if abs(slope) < 1.0e-9 {
		return 0, 0, false
	}
	// Where the fitted line crosses zero: the state that contributes nothing.
	centre = -intercept / slope
	return slope, centre, true
}

// Continue a monotonic curve past the last resolved entry, along the slope of
// the entries that were resolved.
//
// The alternative -- leaving unresolved entries at zero -- would put a cliff in
// the middle of a table the engine indexes directly, which is worse than an
// honest extrapolation that the generated file names as such.
extrapolate_tail :: proc(values: []f64, ok: []bool) {
	last := -1
	for i in 0 ..< len(ok) {
		if ok[i] {
			last = i
		}
	}
	if last < 4 || last >= len(values) - 1 {
		return
	}
	// Slope over the last few resolved entries.
	first := max(last - 8, 0)
	span := f64(last - first)
	if span <= 0 {
		return
	}
	step := (values[last] - values[first]) / span
	for i in last + 1 ..< len(values) {
		values[i] = values[last] + step * f64(i - last)
	}
}

// A light centred moving average over the resolved span, in log2 space.
//
// The peak-frequency reading is noisier than the -3 dB corner it replaces for
// the 24 dB path -- a semitone or two of zigzag between adjacent settings,
// where the corner method ran smooth. That is the peak's own precision: a
// moderate-Q bump is fitted less exactly by three band-power samples than a
// wide -3 dB crossing is by the whole curve either side of it, so the same
// per-band measurement noise shows up more in one than the other. The knob's
// own curve underneath it is smooth -- a stored 0..127 with no reason to
// double back on itself -- so smoothing the reading is smoothing out this
// method's noise floor, not the filter. A three-point window, since the
// zigzag is single-step; wider would start eating real curvature.
smooth_log :: proc(values: []f64, ok: []bool) {
	first, last := -1, -1
	for i in 0 ..< len(ok) {
		if ok[i] {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 || last <= first {
		return
	}
	smoothed := make([]f64, len(values))
	defer delete(smoothed)
	for i in first ..= last {
		if !ok[i] || values[i] <= 0 {
			smoothed[i] = values[i]
			continue
		}
		sum, n := math.log2(values[i]), 1.0
		if i > first && ok[i - 1] && values[i - 1] > 0 {
			sum += math.log2(values[i - 1])
			n += 1
		}
		if i < last && ok[i + 1] && values[i + 1] > 0 {
			sum += math.log2(values[i + 1])
			n += 1
		}
		smoothed[i] = math.pow(2.0, sum / n)
	}
	for i in first ..= last {
		values[i] = smoothed[i]
	}
}

// Continue a monotonic curve backward from the first resolved entry, along
// the slope of the entries just above it.
//
// The peak-frequency reading needs this in a way the -3 dB corner never did:
// a resonant peak below the analysed band's own floor is not a low reading,
// it is nothing to read at all, so the low end of a peak-measured sweep can
// come back empty where a corner-measured one came back at the floor. Done in
// log2 space rather than `extrapolate_tail`'s linear Hz, since a linear
// backward extrapolation over several missing entries can cross zero on a
// curve this steep near the bottom of the range, and a negative frequency is
// not an honest extrapolation of anything.
extrapolate_head :: proc(values: []f64, ok: []bool) {
	first := -1
	for i in 0 ..< len(ok) {
		if ok[i] {
			first = i
			break
		}
	}
	if first < 4 {
		return
	}
	last := min(first + 8, len(values) - 1)
	if values[first] <= 0 || values[last] <= 0 || last <= first {
		return
	}
	step := (math.log2(f64(values[last])) - math.log2(f64(values[first]))) / f64(last - first)
	for i in 0 ..< first {
		values[i] = math.pow(2.0, math.log2(f64(values[first])) + step * f64(i - first))
	}
}
