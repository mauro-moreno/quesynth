// Reading a filter's resonance off the reference, and the peak probe.
//
//   s1probe peakprobe [dll] [--type <0..4>] [--cutoff <n>] [--values <list|all>]
//                           [--note <n>]
//
// A 1/6-octave band profile has a Q of its own,
//
//     1 / (2^(1/12) - 2^(-1/12)) = 8.651
//
// so a resonance narrower than one band is smeared into a band-wide peak and reads
// back as about 8.65 however sharp it is. The reading here takes the ratio of the
// power in the band holding the resonance to the power in a band a fixed number of
// octaves above it, which tracks Q without the peak ever being resolved. The
// resonance curve itself turned out to be `1 - state/127` in damping, exactly, so
// the tables this once generated are gone and what is left is the instrument.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import sdsp "../../src/dsp"
import sengine "../../src/engine"
import cpatch "../../src/patch"

// The patch the resonance is measured through: noise alone into the filter, the
// filter envelope pinned flat so the corner does not move, tracking off so the
// corner does not depend on the note, and the amplifier a plain gate.
//
// The gain is held below maximum deliberately. At the top of the resonance knob
// the reference's own output reaches an amplitude of 1.6, and this engine's
// output limiter would compress a peak that size -- which would flatten the very
// thing being measured. Everything here is a ratio between two bands of one
// render, so a lower gain costs nothing.
resonance_probe_patch :: proc(filter_type, cutoff, resonance: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 1, 4) // osc2: noise
	set_param(&p, 5, 127) // oscillator 2 alone
	set_param(&p, 14, filter_type)
	set_param(&p, 19, cutoff)
	set_param(&p, 20, resonance)
	set_param(&p, 21, 63) // envelope amount, display "0"
	set_param(&p, 22, 0) // no keyboard tracking
	set_param(&p, 29, 64) // headroom, see above
	return p
}

RESONANCE_PROBE_SECONDS :: 1.6

// How far above the resonance the skirt is sampled.
//
// Two distances rather than one, because they answer different questions and
// disagreeing is informative. Two octaves is close enough to be certain it is on
// the section's own skirt; four is far enough that a feedthrough path -- a fixed
// fraction of the input arriving around the filter, which the reference's band
// pass does appear to have at the very top of its range -- would show up as the
// two distances recovering different damping values.
// The distances are per slope, because what matters is how far *down* the skirt
// the sample lands, not how far along it. Two octaves below a 12 dB corner is
// 12 dB down; below a 24 dB corner it is 24, and four octaves is 48 -- which for
// the reference's 24 dB low pass put the far sample 91 dB under the peak, at the
// render's own noise floor rather than on the filter. The cross-check caught it:
// the two distances recovered damping values a factor of 33 apart.
SKIRT_OCTAVES_NEAR_12 :: 2.0
SKIRT_OCTAVES_FAR_12 :: 4.0
SKIRT_OCTAVES_NEAR_24 :: 1.0
SKIRT_OCTAVES_FAR_24 :: 2.0

skirt_octaves :: proc(slope: sdsp.Filter_Slope) -> (near, far: f64) {
	if slope == .Slope_24 {
		return SKIRT_OCTAVES_NEAR_24, SKIRT_OCTAVES_FAR_24
	}
	return SKIRT_OCTAVES_NEAR_12, SKIRT_OCTAVES_FAR_12
}

Resonance_Reading :: struct {
	peak_hz:  f64,
	near_db:  f64,
	far_db:   f64,
	ok:       bool,
}

// Sum of a band and its immediate neighbours.
//
// A resonance narrower than the band grid can land on an edge and split itself
// between two bands, which moves a single-band reading by up to 3 dB for no
// reason connected to the filter. Half an octave is still far narrower than the
// two octaves separating it from the skirt sample.
band_neighbourhood :: proc(bands: []f64, index: int) -> (power: f64, ok: bool) {
	total := 0.0
	found := 0
	for i in max(index - 1, 0) ..= min(index + 1, len(bands) - 1) {
		if bands[i] > 0 {
			total += bands[i]
			found += 1
		}
	}
	return total, found > 0
}

band_nearest :: proc(centres: []f64, hz: f64) -> int {
	best := -1
	best_distance := 1.0e30
	for i in 0 ..< len(centres) {
		d := abs(math.ln(centres[i] / hz))
		if d < best_distance {
			best_distance = d
			best = i
		}
	}
	return best
}

// The peak-to-skirt ratios of one band profile.
//
// `anchor_hz` pins which band holds the resonance instead of taking the loudest.
// Without it the sweep has a discontinuity in it that belongs to the instrument
// and not to the filter: at the bottom of the resonance knob a band pass's
// maximum is broad and nearly flat, so which band wins is decided by noise, and
// when it moves the skirt sample moves with it. That showed up as one reversal
// in an otherwise smooth 128-point curve, a 14% step at stored 21, exactly where
// the loudest band jumped from 269 Hz to 214.
//
// The corner does not move when the resonance knob turns -- only the height of
// the peak on it does -- so the band is found once where the peak is
// unmistakable, at the top of the knob, and held for the whole sweep.
resonance_reading :: proc(bands, centres: []f64, slope: sdsp.Filter_Slope, anchor_hz: f64 = 0) -> Resonance_Reading {
	out: Resonance_Reading

	peak_index := -1
	if anchor_hz > 0 {
		peak_index = band_nearest(centres, anchor_hz)
	} else {
		peak_power := 0.0
		for i in 0 ..< len(bands) {
			if bands[i] > peak_power {
				peak_power = bands[i]
				peak_index = i
			}
		}
	}
	if peak_index < 0 || peak_index >= len(centres) {
		return out
	}
	out.peak_hz = centres[peak_index]

	peak, peak_ok := band_neighbourhood(bands, peak_index)
	if !peak_ok || peak <= 0 {
		return out
	}

	read_skirt :: proc(bands, centres: []f64, peak, peak_hz, octaves: f64) -> (db: f64, ok: bool) {
		hz := peak_hz * math.pow(2.0, octaves)
		// Past the analysed band there is nothing to read, and a reading taken
		// against the last band would be a floor rather than a skirt.
		if hz > BAND_HI_HZ * 0.8 {
			return 0, false
		}
		index := band_nearest(centres, hz)
		if index < 0 {
			return 0, false
		}
		skirt, skirt_ok := band_neighbourhood(bands, index)
		if !skirt_ok || skirt <= 0 {
			return 0, false
		}
		return power_db(peak / skirt), true
	}

	near_octaves, far_octaves := skirt_octaves(slope)
	near, near_ok := read_skirt(bands, centres, peak, out.peak_hz, near_octaves)
	far, far_ok := read_skirt(bands, centres, peak, out.peak_hz, far_octaves)
	out.near_db = near
	out.far_db = far
	out.ok = near_ok
	if !far_ok {
		out.far_db = 0
	}
	return out
}

// ------------------------------------------------------------- the reference

reference_resonance :: proc(
	dll: string,
	pristine, work: []byte,
	filter_type, cutoff, resonance: int,
	note: u8,
	dumped: ^bool,
	anchor_hz: f64 = 0,
) -> Resonance_Reading {
	_, slope := resonance_mode_for_type(filter_type)
	p := resonance_probe_patch(filter_type, cutoff, resonance)
	dump_indices := []int{1, 5, 14, 15, 16, 17, 19, 20, 21, 22, 25, 27, 29}
	audio := probe_render(dll, &p, pristine, work, note, RESONANCE_PROBE_SECONDS, dumped, dump_indices)
	if audio == nil {
		return {}
	}
	defer delete(audio)

	bands, centres, ok := probe_band_levels(audio)
	defer delete(bands)
	defer delete(centres)
	if !ok {
		return {}
	}
	return resonance_reading(bands, centres, slope, anchor_hz)
}

// Where the reference's own resonance sits, read at the top of the knob where
// the peak cannot be mistaken for the broad maximum of an unresonant filter.
reference_anchor :: proc(
	dll: string,
	pristine, work: []byte,
	filter_type, cutoff: int,
	note: u8,
) -> f64 {
	r := reference_resonance(dll, pristine, work, filter_type, cutoff, 127, note, nil)
	return r.peak_hz
}

// ------------------------------------------------------------------ commands

// The filter type states, as `filterprobe` measured them and as
// `docs/reference-notes.md` records: the Japanese manual is right and state 3 is
// a band pass, not a 24 dB high pass.
resonance_mode_for_type :: proc(filter_type: int) -> (sdsp.Filter_Mode, sdsp.Filter_Slope) {
	switch filter_type {
	case 0:
		return .Low_Pass, .Slope_12
	case 1:
		return .Low_Pass, .Slope_24
	case 2:
		return .High_Pass, .Slope_12
	case 3:
		return .Band_Pass, .Slope_12
	case 4:
		return .Low_Pass, .Slope_24 // LPDL, bound to LP24 pending a ladder model
	}
	return .Low_Pass, .Slope_12
}

filter_type_name :: proc(filter_type: int) -> string {
	switch filter_type {
	case 0:
		return "low pass 12"
	case 1:
		return "low pass 24"
	case 2:
		return "high pass 12"
	case 3:
		return "band pass 12"
	case 4:
		return "LPDL"
	}
	return "?"
}

// The band pass is the default because its resonance is the only one of the four
// whose peak is unambiguous: a low pass at low resonance has no peak at all, so
// "the band holding the resonance" is not a thing that can be found.
QPROBE_TYPE_DEFAULT :: 3
// Mid range, so both skirt samples fit inside the analysed band with the
// resonance well clear of its floor.
QPROBE_CUTOFF_DEFAULT :: 48

// The resonant peak's own frequency, sub-band, rather than the -3 dB point
// `measure_corner` reads.
//
// The bands are laid out in a fixed ratio (`analysis.odin`'s `BAND_RATIO`), so
// they are evenly spaced in log frequency and the band *index* stands in for
// log-frequency the same way a bin index stands in for linear frequency in
// `dominant_frequency` -- the parabolic fit on the three bands around the
// loudest one is the same fit, just read back through the bands' own ratio
// instead of a bin width.
//
// Needs no open reference, unlike `measure_corner`: the peak is a property of
// this one render, not of how it compares to a wide-open one.
peak_hz_interpolated :: proc(bands, centres: []f64) -> (hz: f64, ok: bool) {
	if len(bands) < 3 {
		return 0, false
	}
	best := -1
	best_power := 0.0
	for i in 0 ..< len(bands) {
		if bands[i] > best_power {
			best_power = bands[i]
			best = i
		}
	}
	if best <= 0 || best >= len(bands) - 1 {
		// The loudest band is at an edge of the analysed range: not a peak,
		// the top or bottom of a monotonic slope running off the edge of what
		// was measured.
		return 0, false
	}

	a := power_db(bands[best - 1])
	b := power_db(bands[best])
	c := power_db(bands[best + 1])
	denom := a - 2.0 * b + c
	if abs(denom) < 1.0e-12 {
		return centres[best], true
	}
	offset := clamp(0.5 * (a - c) / denom, -0.5, 0.5)
	ratio := offset >= 0 ? centres[best + 1] / centres[best] : centres[best] / centres[best - 1]
	return centres[best] * math.pow(ratio, abs(offset)), true
}

// s1probe peakprobe - is the resonant peak's frequency the thing to build a
// cutoff table from instead of the -3 dB corner?
//
// `s1probe cutoffprobe`'s corner is not resonance-invariant: at parameter 19
// stored 80, the 24 dB path's -3 dB corner reads 637 Hz at resonance 0 and
// 1402 Hz at resonance 107, over an octave apart, because raising Q raises a
// peak near the corner and the -3 dB point is defined relative to *that*
// render's own peak, not to a fixed reference. Building `FILTER_CUTOFF_HZ_24`
// at resonance 0 and using it at every resonance made 29 of 123 bank patches
// worse, concentrated exactly on high resonance -- see docs/null-test.md.
//
// This sweeps resonance at one cutoff and type and reads the peak's own
// frequency instead, to see whether *that* number holds still as Q rises,
// which is what it would mean for the underlying parameter-19 frequency to be
// unchanged and only the measurement of it to have moved.
//
//   s1probe peakprobe [dll] [--type <0..4>] [--cutoff <n>] [--values <list>]
//                           [--note <n>]
cmd_peakprobe :: proc(dll: string, filter_type, cutoff: int, spec: string, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := parse_env_values(spec)
	defer delete(values)

	fmt.printfln("peakprobe: filter type %v (%v), cutoff %v, note %v",
		filter_type, filter_type_name(filter_type), cutoff, note)
	fmt.println("  sweeping resonance; reading the resonant peak's own frequency rather than")
	fmt.println("  the -3 dB corner, which is not resonance-invariant on a peaked filter")
	fmt.println()
	fmt.printfln("%10v %10v %10v", "resonance", "peak Hz", "vs top")

	read_peak :: proc(dll: string, pristine, work: []byte, filter_type, cutoff, resonance: int, note: u8, dumped: ^bool) -> (hz: f64, ok: bool) {
		p := resonance_probe_patch(filter_type, cutoff, resonance)
		dump_indices := []int{1, 5, 14, 19, 20, 21, 22, 29}
		audio := probe_render(dll, &p, pristine, work, note, RESONANCE_PROBE_SECONDS, dumped, dump_indices)
		if audio == nil {
			return 0, false
		}
		defer delete(audio)
		bands, centres, band_ok := probe_band_levels(audio)
		defer delete(bands)
		defer delete(centres)
		if !band_ok {
			return 0, false
		}
		return peak_hz_interpolated(bands, centres)
	}

	dumped := false
	// The reference point every row is read against: the top of the knob, where
	// the peak is sharpest and least likely to be mistaken for anything else.
	top_hz, top_ok := read_peak(dll, pristine, work, filter_type, cutoff, 127, note, &dumped)

	for v in values {
		hz, ok := read_peak(dll, pristine, work, filter_type, cutoff, v, note, &dumped)
		if !ok {
			fmt.printfln("%10v %10v %10v", v, "-", "no peak")
			free_all(context.temp_allocator)
			continue
		}
		fmt.printfln("%10v %10v %10v", v, dec1(hz), top_ok && top_hz > 0 ? sdec2(log2f(hz / top_hz)) : "-")
		free_all(context.temp_allocator)
	}
}
