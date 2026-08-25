// s1probe qprobe / qtable - measure the filter's resonance curve.
//
//   s1probe qprobe [dll] [--type <0..4>] [--cutoff <n>] [--values <list|all>]
//                        [--note <n>] [--dump]
//   s1probe qtable [dll] [out.odin]
//
// The problem this exists to solve is that the instrument used everywhere else
// in this project cannot see the answer.
//
// `filterprobe` and `filtertable` read the filter off a 1/6-octave band profile.
// A 1/6-octave band has a Q of its own:
//
//     1 / (2^(1/12) - 2^(-1/12)) = 8.651
//
// so a resonance narrower than one band is smeared into a band-wide peak and
// reads back as Q ~= 8.65 no matter how sharp it really is. Measuring the
// reference that way returned 8.57, which is that ceiling to within one percent
// -- a floor on the answer that had been read as the answer. On the strength of
// it `src/dsp/filter.odin` carried a maximum Q of 14 and the null test put patch
// 117, a percussion sound built entirely from a high-Q band-pass ping, 14 dB
// clear of every other patch in the bank as the worst.
//
// Method. Drive noise through the filter and take the ratio of the power in the
// band holding the resonance to the power in a band a fixed number of octaves
// above it. For a two-pole section the peak gain rises with Q while the far
// skirt does not, and integrating over a band wider than the resonance turns
// "peak gain squared over a bandwidth proportional to 1/Q" into a band power
// proportional to Q. So the ratio tracks Q *without the peak ever having to be
// resolved*, which is exactly the constraint that defeats the band profile.
//
// The ratio is not converted to a Q by formula. The same measurement is run
// against `dsp.Filter` itself at a sweep of known damping values, and the
// reference's ratio is inverted through that calibration -- so what comes out is
// the damping our topology needs to behave like the reference, which is the
// number the engine actually consumes, rather than a Q that would then have to be
// translated across two different filter designs.
//
// That also makes the instrument self-checking. `qprobe --calibrate` recovers the
// damping of our own filter from its own render; anything other than the value it
// was given back means the observable is not measuring what it claims to.
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

// ------------------------------------------------------------ our own filter

// Long enough for several overlapping transforms, plus a run-in that is
// discarded. A filter at the top of this range takes a good fraction of a second
// to reach its steady state, and averaging that ring-in into the spectrum reads
// as a resonance shallower than the one being measured.
TOPOLOGY_SECONDS :: 4.0
TOPOLOGY_RUN_IN_SECONDS :: 0.5

// The same reading, taken from `dsp.Filter` driven directly rather than through
// the engine.
//
// Directly on purpose: the voice's gain staging, its output limiter and its
// oscillator all sit between the filter and any render, and every one of them
// could colour a ratio between two bands. What is wanted here is the topology's
// own response and nothing else.
topology_resonance :: proc(k: f64, mode: sdsp.Filter_Mode, slope: sdsp.Filter_Slope, cutoff_hz: f64, anchor_hz: f64 = 0) -> Resonance_Reading {
	total := int(TOPOLOGY_SECONDS * f64(SAMPLE_RATE))
	run_in := int(TOPOLOGY_RUN_IN_SECONDS * f64(SAMPLE_RATE))

	f: sdsp.Filter
	sdsp.filter_init(&f)
	// Set the coefficients from k directly. `filter_set` derives k from a
	// resonance on 0..1 through the very law this probe exists to replace, so
	// going through it would make the calibration circular.
	sdsp.filter_set_damping(&f, f32(cutoff_hz), f32(k), f32(SAMPLE_RATE), slope)

	rng: sdsp.Rng
	sdsp.rng_init(&rng, 0x51D0B3)

	x := make([]f32, total)
	defer delete(x)
	for i in 0 ..< total {
		x[i] = sdsp.filter_process(&f, sdsp.rng_next_bipolar(&rng), mode, slope, 0.0)
	}

	power := welch_power(x, run_in, total)
	defer delete(power)
	if power == nil {
		return {}
	}
	bands, centres := band_powers(power, f64(SAMPLE_RATE) / f64(FFT_SIZE))
	defer delete(bands)
	defer delete(centres)
	if bands == nil {
		return {}
	}
	return resonance_reading(bands, centres, slope, anchor_hz)
}

// The damping our engine ends up using for a patch, so the recovered value has
// something to be checked against.
engine_damping_for :: proc(patch: cpatch.Patch) -> f32 {
	eng: sengine.Engine
	sengine.engine_load_patch(&eng, patch, f32(SAMPLE_RATE))
	defer sengine.engine_destroy(&eng)
	return eng.params.filter_damping
}

// The same reading, through our engine's full render path.
ours_resonance :: proc(patch: cpatch.Patch, note: u8, slope: sdsp.Filter_Slope, anchor_hz: f64 = 0) -> Resonance_Reading {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(RESONANCE_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	audio := render_ours(patch, int(note))
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

// The calibration: our topology's near ratio against damping, on a log grid.
//
// Monotonic by construction -- less damping is a taller peak over an unchanged
// skirt -- which is what makes the inversion below a simple search.
Calibration :: struct {
	k:     []f64,
	ratio: []f64,
	// The same curve read at the far skirt. Inverting a reference reading through
	// both and getting two different damping values is how a path around the
	// filter would announce itself -- feedthrough lifts the far sample without
	// touching the near one, so the two would stop agreeing.
	ratio_far: []f64,
	// The band our own resonance was found in, held for every point.
	anchor_hz: f64,
}

// The sharp end of the calibration is the engine's own floor, not an arbitrary
// small number. Calibrating past what `filter_set_damping` will accept would
// invert the reference onto a damping the engine cannot be given.
K_MIN :: f64(sdsp.MIN_DAMPING)
K_MAX :: 2.0
CALIBRATION_POINTS :: 96

build_calibration :: proc(mode: sdsp.Filter_Mode, slope: sdsp.Filter_Slope, cutoff_hz: f64) -> Calibration {
	c: Calibration
	c.k = make([]f64, CALIBRATION_POINTS)
	c.ratio = make([]f64, CALIBRATION_POINTS)
	c.ratio_far = make([]f64, CALIBRATION_POINTS)

	// Where our own resonance sits, found once at the sharp end where it cannot
	// be mistaken for anything, and then held. Each engine is anchored to its own
	// corner rather than to a shared frequency: the reference's band pass centres
	// about 0.86 of where ours does, and pinning both to one band would sample
	// their skirts at different distances and charge the difference to damping.
	anchor := topology_resonance(K_MIN, mode, slope, cutoff_hz).peak_hz
	c.anchor_hz = anchor

	for i in 0 ..< CALIBRATION_POINTS {
		t := f64(i) / f64(CALIBRATION_POINTS - 1)
		k := K_MIN * math.pow(K_MAX / K_MIN, t)
		c.k[i] = k
		r := topology_resonance(k, mode, slope, cutoff_hz, anchor)
		c.ratio[i] = r.ok ? r.near_db : -1.0e9
		c.ratio_far[i] = r.far_db != 0 ? r.far_db : -1.0e9
	}
	return c
}

calibration_destroy :: proc(c: ^Calibration) {
	delete(c.k)
	delete(c.ratio)
	delete(c.ratio_far)
}

// Invert: the damping whose ratio matches `ratio_db`.
//
// The calibration runs from the sharpest damping to the flattest, so the ratio
// falls down the array. Interpolated in log k against dB, which is the space
// both axes are close to straight in.
calibration_invert :: proc(c: Calibration, ratio_db: f64, far := false) -> (k: f64, ok: bool) {
	ratios := far ? c.ratio_far : c.ratio
	last := len(c.k) - 1
	// Off either end is a real answer rather than an error: it says the reference
	// is outside anything this topology can produce, and the bound is the useful
	// thing to report. A ratio above the sharpest end is the one that matters --
	// it means the reference is resonating harder than an f32 state variable
	// filter can be asked to.
	if ratio_db > ratios[0] {
		return c.k[0], false
	}
	if ratio_db < ratios[last] {
		return c.k[last], false
	}
	for i in 1 ..= last {
		lo := ratios[i]
		hi := ratios[i - 1]
		if lo < -1.0e8 || hi < -1.0e8 {
			continue
		}
		if ratio_db <= hi && ratio_db >= lo {
			if hi == lo {
				return c.k[i], true
			}
			t := (hi - ratio_db) / (hi - lo)
			return c.k[i - 1] * math.pow(c.k[i] / c.k[i - 1], clamp(t, 0, 1)), true
		}
	}
	return c.k[last], false
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

cmd_qprobe :: proc(dll: string, filter_type, cutoff: int, spec: string, note: u8, calibrate_only: bool) {
	mode, slope := resonance_mode_for_type(filter_type)

	fmt.printfln(
		"qprobe: filter type %v (%v), cutoff %v, note %v, noise source",
		filter_type,
		filter_type_name(filter_type),
		cutoff,
		note,
	)
	near_octaves, far_octaves := skirt_octaves(slope)
	fmt.printfln(
		"  peak-to-skirt at %v and %v octaves above the resonance",
		near_octaves,
		far_octaves,
	)
	fmt.println()

	// The calibration first, so its own consistency is on the page before any
	// reference number is inverted through it. It runs at the frequency the
	// engine's own cutoff table puts this setting at, so the two engines are
	// resonating in the same part of the spectrum and the skirt samples land on
	// the same bands.
	calibration_hz := f64(sengine.FILTER_CUTOFF_HZ[clamp(cutoff, 0, sengine.FILTER_TABLE_SIZE - 1)])
	c := build_calibration(mode, slope, calibration_hz)
	defer calibration_destroy(&c)

	fmt.println("-- our topology, damping we set against damping recovered --")
	fmt.println("   k set     Q    near dB    far dB   k recovered   error")
	check_points := []f64{1.0, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001}
	for k in check_points {
		r := topology_resonance(k, mode, slope, calibration_hz, c.anchor_hz)
		if !r.ok {
			fmt.printfln("%8v %5v   %s", dec4(k), dec1(1.0 / k), "no resonance to read")
			continue
		}
		back, back_ok := calibration_invert(c, r.near_db)
		fmt.printfln(
			"%8v %5v %9v %9v %13v %7v%%",
			dec4(k),
			dec1(1.0 / k),
			dec2(r.near_db),
			dec2(r.far_db),
			back_ok ? dec4(back) : "off scale",
			dec1(100.0 * (back - k) / k),
		)
	}
	fmt.println()
	fmt.println("  Exact by construction -- the calibration and these rows come from the same")
	fmt.println("  procedure -- so what this row block checks is conditioning, not truth: the")
	fmt.println("  ratio has to keep moving as the damping falls or the inversion is guessing.")
	fmt.println()

	// The check that is not tautological.
	//
	// Above, the filter is driven directly. Here the same patch the reference is
	// given goes through `render_ours` -- oscillator, voice gain, pan law, output
	// limiter and all -- and the damping is recovered from that. The voice path
	// has no business changing a ratio between two bands, and this is where it
	// would show if it did. It is not a formality: the limiter compresses peaks,
	// which is exactly the shape this observable reads, and that is why the probe
	// patch runs at reduced gain.
	fmt.println("-- the same reading through the whole voice path --")
	fmt.println("  stored     k by the law   k recovered   error")
	engine_points := []int{0, 32, 64, 96, 112, 127}
	for v in engine_points {
		p := resonance_probe_patch(filter_type, cutoff, v)
		expected := engine_damping_for(p)
		r := ours_resonance(p, note, slope, c.anchor_hz)
		if !r.ok {
			fmt.printfln("%v %14v   %s", pad_left(fmt.tprintf("%v", v), 8), dec4(f64(expected)), "no resonance to read")
			continue
		}
		back, back_ok := calibration_invert(c, r.near_db)
		fmt.printfln(
			"%v %14v %13v %7v%%",
			pad_left(fmt.tprintf("%v", v), 8),
			dec4(f64(expected)),
			back_ok ? dec4(back) : "off scale",
			dec1(100.0 * (back - f64(expected)) / f64(expected)),
		)
	}
	fmt.println()

	if calibrate_only {
		return
	}

	values := parse_env_values(spec)
	defer delete(values)
	if len(values) == 0 {
		fmt.eprintln("qprobe: no values to sweep")
		os.exit(1)
	}

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	anchor := reference_anchor(dll, pristine, work, filter_type, cutoff, note)
	fmt.println("-- the reference --")
	fmt.printfln(
		"  resonance found at %v Hz, against ours at %v Hz",
		dec1(anchor),
		dec1(c.anchor_hz),
	)
	fmt.println("  stored   peak Hz   near dB    far dB     k needed      Q   k from far")
	for v in values {
		r := reference_resonance(dll, pristine, work, filter_type, cutoff, v, note, &dumped, anchor)
		if !r.ok {
			fmt.printfln("%v %9v   %s", pad_left(fmt.tprintf("%v", v), 8), "-", "no resonance to read")
			continue
		}
		k, k_ok := calibration_invert(c, r.near_db)
		k_far, far_ok := calibration_invert(c, r.far_db, true)
		fmt.printfln(
			"%v %9v %9v %9v %12v %6v %12v",
			pad_left(fmt.tprintf("%v", v), 8),
			dec1(r.peak_hz),
			dec2(r.near_db),
			dec2(r.far_db),
			k_ok ? dec4(k) : strings.concatenate({"<= ", dec4(k)}, context.temp_allocator),
			dec1(1.0 / k),
			r.far_db != 0 && far_ok ? dec4(k_far) : "-",
		)
		free_all(context.temp_allocator)
	}
	fmt.println()
	fmt.println("  The last two damping columns are two independent readings of the same")
	fmt.println("  quantity, taken two octaves apart on the skirt. They agree only if the")
	fmt.println("  skirt really is the section's own and nothing is arriving around it.")
}

// --------------------------------------------------------- the output level

// What the resonance does to the output level, in both engines.
//
// Separate from everything above because it is a different question with a
// different answer. The damping curve settles the *shape* of the response and
// the spectral metric is blind to gain, so a filter can match the reference's
// timbre exactly and still be ten decibels loud -- which is what happened the
// moment the real curve landed: a Q of 950 has a great deal more energy in it
// than a Q of 14, and the reference does not simply pass that through.
cmd_qlevel :: proc(dll: string, filter_type, cutoff: int, spec: string, note: u8) {
	values := parse_env_values(spec)
	defer delete(values)

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	fmt.printfln(
		"qlevel: filter type %v (%v), cutoff %v, note %v, noise source",
		filter_type,
		filter_type_name(filter_type),
		cutoff,
		note,
	)
	fmt.println("  stored     ref rms    our rms    ours - ref    our peak")
	dumped := true
	for v in values {
		p := resonance_probe_patch(filter_type, cutoff, v)

		audio := probe_render(dll, &p, pristine, work, note, RESONANCE_PROBE_SECONDS, &dumped, nil)
		if audio == nil {
			continue
		}
		ref_rms := probe_steady_rms(audio)
		delete(audio)

		set_compare_timing(COMPARE_BLOCK_DEFAULT)
		held := (int(RESONANCE_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
		g_hold_frames = held * g_block
		g_total_frames = g_hold_frames + g_block * 8
		ours := render_ours(p, int(note))
		if ours == nil {
			continue
		}
		our_rms := probe_steady_rms(ours)
		our_peak := signal_peak(ours)
		delete(ours)

		fmt.printfln(
			"%v %11v %10v %13v %11v",
			pad_left(fmt.tprintf("%v", v), 8),
			dec5(ref_rms),
			dec5(our_rms),
			ref_rms > 0 && our_rms > 0 ? sdec2(amplitude_db(our_rms / ref_rms)) : "-",
			dec4(our_peak),
		)
		free_all(context.temp_allocator)
	}
	fmt.println()
	fmt.println("  A flat column of differences is a gain constant. One that grows with the")
	fmt.println("  knob is the resonance's own energy, and needs a law and not a number.")
}

// The output gain the resonance knob needs, at every state.
//
// Measured against the engine *as currently built*, and emitted as the gain
// already compiled in multiplied by the correction still outstanding. That makes
// it a fixed point rather than a one-shot fit: run it on an engine whose gains
// are right and it reproduces them, run it on one whose gains are wrong and it
// converges. It also means a run taken across a change to the damping tables is
// measuring a mixture, so the two are regenerated together and the tool is run
// twice when the damping moves materially.
sweep_output_gain :: proc(
	dll: string,
	pristine, work: []byte,
	filter_type, cutoff: int,
	note: u8,
) -> []f64 {
	fmt.printfln("  output gain: 128 settings through the %v at cutoff %v", filter_type_name(filter_type), cutoff)

	gain := make([]f64, 128)
	dumped := true
	measured := 0
	clipped := 0
	neutral_measured := false

	for v in 0 ..< 128 {
		gain[v] = f64(sengine.FILTER_OUTPUT_GAIN[v])

		p := resonance_probe_patch(filter_type, cutoff, v)
		audio := probe_render(dll, &p, pristine, work, note, RESONANCE_PROBE_SECONDS, &dumped, nil)
		if audio == nil {
			free_all(context.temp_allocator)
			continue
		}
		ref_rms := probe_steady_rms(audio)
		delete(audio)

		set_compare_timing(COMPARE_BLOCK_DEFAULT)
		held := (int(RESONANCE_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
		g_hold_frames = held * g_block
		g_total_frames = g_hold_frames + g_block * 8
		ours := render_ours(p, int(note))
		if ours == nil {
			free_all(context.temp_allocator)
			continue
		}
		our_rms := probe_steady_rms(ours)
		// Our own output limiter would flatten a peak past full scale, and a
		// compressed render reads quiet -- which this would then correct by
		// making it louder. The probe patch runs at reduced gain so it does not
		// happen; if it ever does, the entry is left alone and counted.
		our_peak := signal_peak(ours)
		delete(ours)

		if ref_rms > 0 && our_rms > 0 && our_peak < 0.95 {
			gain[v] *= ref_rms / our_rms
			measured += 1
			if v == 0 {
				neutral_measured = true
			}
		} else if our_peak >= 0.95 {
			clipped += 1
		}
		free_all(context.temp_allocator)
	}
	if !neutral_measured || gain[0] <= 0 {
		fmt.eprintln("qtable: could not measure the neutral output gain")
		os.exit(1)
	}
	neutral := gain[0]
	for i in 0 ..< len(gain) {
		gain[i] /= neutral
	}
	// Make the table's ownership split exact rather than leaving state zero at a
	// rounded value near one: amp gain owns absolute level, resonance owns change.
	gain[0] = 1.0
	fmt.printfln("    %v of 128 corrected, %v skipped for clipping", measured, clipped)
	return gain
}

// RMS of the sustained middle of a render, mid channel.
probe_steady_rms :: proc(audio: []f32) -> f64 {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	from := int(0.2 * f64(SAMPLE_RATE))
	if from >= len(mid) {
		return 0
	}
	return signal_rms(mid[from:])
}

// ---------------------------------------------------------- the table itself

// One 128-point sweep, returned as the damping our topology needs at each state.
sweep_damping :: proc(
	dll: string,
	pristine, work: []byte,
	filter_type, cutoff: int,
	note: u8,
) -> []f64 {
	mode, slope := resonance_mode_for_type(filter_type)
	calibration_hz := f64(sengine.FILTER_CUTOFF_HZ[cutoff])

	fmt.printfln(
		"  %v: 128 settings at cutoff %v",
		filter_type_name(filter_type),
		cutoff,
	)

	c := build_calibration(mode, slope, calibration_hz)
	defer calibration_destroy(&c)

	damping := make([]f64, 128)
	resolved := make([]bool, 128)
	defer delete(resolved)
	at_floor := 0
	measured := 0
	dumped := true

	anchor := reference_anchor(dll, pristine, work, filter_type, cutoff, note)
	fmt.printfln("    resonance at %v Hz, ours at %v Hz", dec1(anchor), dec1(c.anchor_hz))

	for v in 0 ..< 128 {
		r := reference_resonance(dll, pristine, work, filter_type, cutoff, v, note, &dumped, anchor)
		if !r.ok {
			free_all(context.temp_allocator)
			continue
		}
		k, k_ok := calibration_invert(c, r.near_db)
		damping[v] = k
		resolved[v] = true
		measured += 1
		if !k_ok {
			at_floor += 1
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("    %v of 128 resolved, %v against the topology's bounds", measured, at_floor)

	if measured < 100 {
		fmt.eprintln("qtable: too few settings resolved to write a table")
		os.exit(1)
	}

	// Fill any unresolved entry from its neighbours rather than leaving a zero in
	// a table the engine indexes directly. A zero damping is not a mild error --
	// it is an undamped section.
	for v in 0 ..< 128 {
		if resolved[v] {
			continue
		}
		before := -1
		for i := v - 1; i >= 0; i -= 1 {
			if resolved[i] {
				before = i
				break
			}
		}
		after := -1
		for i in v + 1 ..< 128 {
			if resolved[i] {
				after = i
				break
			}
		}
		switch {
		case before >= 0 && after >= 0:
			t := f64(v - before) / f64(after - before)
			damping[v] = damping[before] * math.pow(damping[after] / damping[before], t)
		case before >= 0:
			damping[v] = damping[before]
		case after >= 0:
			damping[v] = damping[after]
		case:
			damping[v] = 2.0
		}
	}

	// The knob has to be monotonic: turning resonance up cannot make the filter
	// blunter. Reported rather than silently repaired, because a reversal is
	// either measurement noise -- which is worth knowing the size of -- or a real
	// feature of the reference, which is worth knowing about at all.
	reversals := 0
	worst_reversal := 0.0
	for v in 1 ..< 128 {
		if damping[v] > damping[v - 1] {
			reversals += 1
			delta := damping[v] / damping[v - 1]
			if delta > worst_reversal {
				worst_reversal = delta
			}
		}
	}
	fmt.printfln("    %v reversals, worst by a factor of %v", reversals, dec3(worst_reversal))
	return damping
}

// Both curves, and the file.
//
// Two sweeps rather than one because the 24 dB path is not the 12 dB path with
// more poles on it. Ours is two sections in series, and a cascade of two
// two-pole resonances is not the same shape as one four-pole resonance however
// the damping is shared out between them -- so the damping that makes the pair
// behave like the reference's 24 dB filter is its own measurement, and it comes
// out roughly twice the 12 dB figure at the same knob position.
//
// The 12 dB curve is measured through the band pass and the 24 dB curve through
// the low pass, because those are the only types each slope has that put an
// unambiguous peak in the spectrum. A low pass at low resonance has its maximum
// at DC rather than at the corner, which is why the 24 dB curve's first two
// entries come back against the flat end of the calibration and are bounds
// rather than readings.
cmd_qtable :: proc(dll: string, out_path: string, note: u8) {
	cutoff := QPROBE_CUTOFF_DEFAULT

	fmt.println("measuring the resonance curves")

	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	damping := sweep_damping(dll, pristine, work, QPROBE_TYPE_DEFAULT, cutoff, note)
	defer delete(damping)
	damping_24 := sweep_damping(dll, pristine, work, 1, cutoff, note)
	defer delete(damping_24)
	// Through the 12 dB low pass, which is the type with the most headroom before
	// our own limiter, and the correction is the same for all four anyway.
	gain := sweep_output_gain(dll, pristine, work, 0, cutoff, note)
	defer delete(gain)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, `// Code generated by "s1probe qtable"; do not edit.
//
// The reference Synth1's resonance curve, as the damping k = 1/Q this engine's
// state variable filter needs to match it, indexed by parameter 20's resolved
// state.
//
// It replaces a straight line, k = 2 - 1.93*r, whose top end was Q = 14. The
// real curve reaches Q = 950 and does almost all of its travel in the last
// fifteen steps of the knob: Q is 2.1 at the centre, 10 at stored 112, 24 at
// 120 and 950 at 127.
//
// Why the old number was so far out is worth keeping. It came from reading the
// resonance off a 1/6-octave band profile, and a 1/6-octave band has a Q of its
// own -- 1/(2^(1/12) - 2^(-1/12)) = 8.651. Any resonance sharper than that is
// smeared into a band-wide peak and reads back as about 8.65 whatever it is.
// The reference measured 8.57 that way, which is the instrument's ceiling to
// within one percent, and it was recorded as the reference's Q.
//
// Method is in docs/null-test.md and in tools/s1probe/resonanceprobe.odin. In
// short: noise through the filter at cutoff %v, and the ratio of the power in
// the band holding the resonance to the power in a band a fixed distance above
// it, which tracks Q without the peak ever having to be resolved. The ratio is
// inverted through the same measurement taken against dsp.Filter itself at known
// damping values, so what is stored is the damping our topology needs, not a Q
// read off one filter design and applied to another.
//
// Both tables are the damping of the *whole filter*, not of one section.
// dsp.filter_set_damping takes the square root for the 24 dB path, where two
// sections in series would otherwise multiply their resonances together.
package engine

FILTER_RESONANCE_TABLE_SIZE :: 128

// The 12 dB responses, measured through the band pass -- the only type whose
// peak is unambiguous at every setting of the knob.
//
// Stored 127 sits at dsp.MIN_DAMPING, which is where f32 stops being able to
// represent the damping at all; see the constant. The reference is at or past
// self-oscillation there, so that entry is a floor rather than a reading.
FILTER_DAMPING := [FILTER_RESONANCE_TABLE_SIZE]f32{{
`, cutoff)

	emit_damping :: proc(b: ^strings.Builder, values: []f64) {
		for i in 0 ..< 128 {
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
		strings.write_string(b, "}\n")
	}

	emit_damping(&b, damping)

	strings.write_string(&b, `
// The 24 dB low pass, measured through itself.
//
// It is roughly twice the 12 dB damping at the same knob position, and that is
// not a redundancy: a cascade of two two-pole resonances has a different shape
// from one four-pole resonance, so the damping that makes our pair behave like
// the reference's 24 dB filter is not the damping that makes one section behave
// like its 12 dB one.
//
// The first entries are bounds rather than readings. A low pass with the
// resonance off has its maximum at DC and not at the corner, so there is no peak
// to measure, and the inversion comes back against the flat end of the
// calibration.
FILTER_DAMPING_24 := [FILTER_RESONANCE_TABLE_SIZE]f32{
`)
	emit_damping(&b, damping_24)

	strings.write_string(&b, `
// The output gain that goes with the damping above, as a plain amplitude.
//
// Resonance is energy. Our filter passes it and the reference does not, so once
// the real damping curve landed we were up to eleven decibels loud at the top of
// the knob with the timbre already correct -- the spectral metric normalises
// gain away and never saw it.
//
// One table for every response and both slopes, which is a measurement and not a
// convenience: the low pass, the high pass, the band pass and the 24 dB low pass
// all need the same correction to within about a decibel across the whole knob.
// It is independent of the cutoff too, checked at three settings four octaves
// apart, which is what a normalisation of the filter's own noise gain has to be.
//
// State zero is the neutral multiplier. The absolute amp-gain table already
// includes the reference's open-filter output level, so this curve is normalised
// by its measured state-zero value and owns only resonance-dependent level.
// It replaces a k^0.25 on the band-pass output alone, fitted with a saw -- an
// instrument that under-reads a narrowing resonance because its partials fall
// out of the peak as it sharpens.
FILTER_OUTPUT_GAIN := [FILTER_RESONANCE_TABLE_SIZE]f32{
`)
	emit_damping(&b, gain)

	if os.write_entire_file(out_path, transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintfln("qtable: could not write %v", out_path)
		os.exit(1)
	}
	fmt.printfln("  wrote %v", out_path)
}
