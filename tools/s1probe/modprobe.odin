// s1probe filterprobe / lfoprobe - measure what a parameter's states actually do.
//
// Two parameters in this project are bound from prose rather than from
// measurement, and the prose disagrees with itself:
//
//   - Parameter 14, filter type. The English manual calls the fourth state a
//     24 dB high pass; the Japanese manual for the same version calls it a
//     12 dB band pass. `src/engine/binding.odin` follows the English one.
//   - Parameters 41 and 46, LFO destination. The English manual lists five
//     destinations, the Japanese lists six, and the measured table has seven
//     states. `src/engine/params.odin` guesses the last two and says so.
//
// Neither is settled by reading harder. These subcommands drive each state and
// read back what moved.
//
//   s1probe filterprobe [dll] [--cutoff <n>] [--res <n>] [--note <n>] [--dump]
//   s1probe lfoprobe    [dll] [--param 41|46] [--rate <n>] [--note <n>] [--dump]
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import cpatch "../../src/patch"

// The base every probe patch is built on: everything that could colour a
// measurement, switched off.
//
// This is shared rather than repeated per probe because "which stored integer
// means off" is exactly the kind of detail that drifts between two copies. It
// has already been wrong once here -- parameter 21 is a direct state index whose
// states start at "-63", so the obvious stored 0 selects *full negative* filter
// envelope amount rather than none.
//
// Nothing in it is assumed: `--dump` on any probe prints what the plugin says
// the patch is, and that is how the parameter 21 error was found.
neutral_probe_patch :: proc() -> cpatch.Patch {
	p: cpatch.Patch
	for i in 0 ..< cpatch.PARAMETER_COUNT {
		p.values[i] = cpatch.PARAMETERS[i].default
		p.present[i] = true
	}

	// -- oscillators ---------------------------------------------------------
	set_param(&p, 6, 0) // sync off
	set_param(&p, 7, 0) // ring off
	set_param(&p, 10, 0) // osc modulation envelope off
	set_param(&p, 45, 0) // osc1 FM off
	set_param(&p, 95, 0) // sub oscillator silent

	// -- filter: not moving --------------------------------------------------
	set_param(&p, 20, 0) // no resonance
	set_param(&p, 21, 63) // envelope amount, display "0": no modulation
	set_param(&p, 22, 0) // no keyboard tracking, so cutoff is note-independent
	set_param(&p, 23, 0) // no saturation
	set_param(&p, 24, 0) // velocity does not touch the filter
	set_param(&p, 15, 0) // filter envelope pinned flat: attack
	set_param(&p, 16, 0) // decay
	set_param(&p, 17, 127) // sustain at maximum
	set_param(&p, 18, 0) // release

	// -- amplifier: a flat gate ----------------------------------------------
	set_param(&p, 25, 0) // instant attack
	set_param(&p, 26, 0) // no decay
	set_param(&p, 27, 127) // full sustain
	set_param(&p, 28, 0) // instant release
	set_param(&p, 30, 0) // velocity does not scale level

	// -- everything downstream of the voice ----------------------------------
	set_param(&p, 37, 0) // delay dry/wet 0%
	set_param(&p, 44, 0) // lfo1 depth
	set_param(&p, 49, 0) // lfo2 depth
	set_param(&p, 57, 0) // lfo1 off
	set_param(&p, 58, 0) // lfo2 off
	set_param(&p, 59, 0) // arpeggiator off
	set_param(&p, 66, 0) // chorus off
	set_param(&p, 77, 0) // extra effect unit off

	// -- voice behaviour -----------------------------------------------------
	set_param(&p, 39, 0) // no portamento
	set_param(&p, 73, 0) // unison off

	return p
}

// Starting pulse width for the LFO probe, set by --pw.
g_probe_pw: int = 64

set_param :: proc(p: ^cpatch.Patch, index, value: int) {
	p.values[index] = value
}

// Render one patch through a freshly loaded reference, for `seconds` of held
// note. Interleaved stereo.
probe_render :: proc(
	dll: string,
	patch: ^cpatch.Patch,
	pristine, work: []byte,
	note: u8,
	seconds: f64,
	dumped: ^bool,
	dump_indices: []int,
) -> []f32 {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(seconds * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	// A short tail only; these probes measure the held portion.
	g_total_frames = g_hold_frames + g_block * 8

	p, ok := open_reference(dll)
	if !ok {
		return nil
	}
	defer close_reference(&p)

	load_reference_patch(&p, patch, pristine, work)
	if dumped != nil && !dumped^ {
		dump_probe_patch(&p, dump_indices)
		dumped^ = true
	}
	return render_reference_note(&p, note, PROBE_VELOCITY_MIDI)
}

// Load the factory state chunk once, for every probe that needs one.
probe_open_chunk :: proc(dll: string) -> (pristine, work: []byte) {
	p, ok := load(dll)
	if !ok {
		os.exit(1)
	}
	pristine = get_chunk_copy(&p, 0)
	unload(&p)
	if len(pristine) == 0 {
		fmt.eprintln("probe: the plugin returned an empty state chunk")
		os.exit(1)
	}
	work = make([]byte, len(pristine))
	g_quiet_load = true
	return
}

// ------------------------------------------------------------ short-window FFT

// The analysis in analysis.odin uses a 16384-point transform, which is 341 ms --
// far too long to watch an LFO move. These probes use a shorter window and slide
// it, trading frequency resolution for the ability to see change over time.
MOD_FFT :: 4096
MOD_HOP :: 1024

// Power spectrum of one window, Hann weighted. `power` must hold MOD_FFT/2+1.
window_power :: proc(x: []f32, from: int, power: []f64, re, im: []f64) -> bool {
	if from < 0 || from + MOD_FFT > len(x) {
		return false
	}
	for i in 0 ..< MOD_FFT {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(MOD_FFT)))
		re[i] = f64(x[from + i]) * w
		im[i] = 0
	}
	fft_forward(re, im)
	for k in 0 ..< len(power) {
		power[k] = re[k] * re[k] + im[k] * im[k]
	}
	return true
}

// Robust peak-to-peak of a series: the 5th to 95th percentile, over the middle
// of the render.
//
// Not the plain minimum and maximum. Two things spoil those. The note's onset and
// release sit inside the first and last analysis windows, which put a floor of
// about 6 dB on any level measurement even when nothing is being modulated at
// all; and a corner estimated from a noise source jitters window to window,
// which min-to-max turns into a spurious two octaves. Trimming the ends and
// taking percentiles removes both, and a destination that genuinely does nothing
// then reads as nothing.
span :: proc(values: []f64) -> f64 {
	// A tenth off each end, so the note's edges are outside the measurement.
	trim := max(len(values) / 10, 1)
	if len(values) < trim * 2 + 4 {
		return 0
	}
	middle := values[trim:len(values) - trim]

	sorted := make([]f64, len(middle))
	defer delete(sorted)
	copy(sorted, middle)
	// Insertion sort: these are at most a few hundred entries.
	for i in 1 ..< len(sorted) {
		v := sorted[i]
		j := i - 1
		for j >= 0 && sorted[j] > v {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = v
	}

	lo_index := len(sorted) * 5 / 100
	hi_index := len(sorted) - 1 - lo_index
	if hi_index <= lo_index {
		return sorted[len(sorted) - 1] - sorted[0]
	}
	return sorted[hi_index] - sorted[lo_index]
}

// -------------------------------------------------------------- filter probe

FILTER_STATE_COUNT :: 5

Filter_Response :: struct {
	state:        int,
	display:      string,
	// Band response in dB relative to the wide-open render.
	bands:        []f64,
	centres:      []f64,
	peak_hz:      f64,
	low_edge_hz:  f64,
	high_edge_hz: f64,
	low_slope:    f64, // dB per octave below the peak
	low_ok:       bool,
	high_ok:      bool,
	high_slope:   f64, // dB per octave above the peak
	verdict:      string,
}

// Slope of the response in dB per octave over [lo_hz, hi_hz], by least squares
// against log2(frequency). Bands with no data are skipped.
band_slope :: proc(bands, centres: []f64, lo_hz, hi_hz: f64) -> (slope: f64, ok: bool) {
	n := 0
	sx, sy, sxx, sxy := 0.0, 0.0, 0.0, 0.0
	for b in 0 ..< min(len(bands), len(centres)) {
		hz := centres[b]
		if hz < lo_hz || hz > hi_hz || bands[b] <= -900 {
			continue
		}
		x := log2f(hz)
		y := bands[b]
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
		n += 1
	}
	if n < 3 {
		return 0, false
	}
	denom := f64(n) * sxx - sx * sx
	if abs(denom) < 1.0e-12 {
		return 0, false
	}
	return (f64(n) * sxy - sx * sy) / denom, true
}

// Name the response from its two asymptotic slopes.
//
// `low_ok` and `high_ok` say whether each side had enough bands to fit. When the
// peak sits at the very bottom or top of the analysed range there is no room on
// that side, and the response has to be named from the other one -- reporting
// "unclassifiable" for a textbook low pass whose peak is simply at DC would be
// the tool failing, not the filter being strange.
//
// Slopes are reported in poles as well as dB per octave, because that is where
// the manual's own naming lives and the two do not line up the way one might
// expect: a two-pole band pass falls at 6 dB per octave on each side, not 12, so
// "band pass (12 dB)" in the manual and ±6 dB/oct here are the same filter.
classify_filter :: proc(
	low_edge, high_edge, low_slope, high_slope: f64,
	low_ok, high_ok: bool,
) -> string {
	poles :: proc(slope: f64) -> f64 {
		return abs(slope) / 6.0
	}

	// The response is named from where its pass band ends, not from whether a
	// slope clears a threshold. A slope test alone gets the band pass wrong: its
	// skirts measure -5.5 and +6.2 dB per octave, so any threshold at 6 admits
	// one side and rejects the other and the filter comes out a high pass. The
	// pass band, on the other hand, is unambiguous -- 339 to 761 Hz, bounded at
	// both ends, against 479 Hz to the top of the analysed range for the real
	// high pass.
	bounded_below := low_edge > BAND_LO_HZ * 2.0
	bounded_above := high_edge > 0 && high_edge < BAND_HI_HZ * 0.5

	switch {
	case bounded_below && bounded_above:
		return fmt.tprintf(
			"BAND PASS, %v-%v Hz, %v/%v dB per octave",
			dec0(low_edge), dec0(high_edge), sdec0(low_slope), sdec0(high_slope),
		)
	case bounded_above && high_ok:
		return fmt.tprintf("low pass, %v dB/oct (%v-pole)", dec0(-high_slope), dec0(poles(high_slope)))
	case bounded_below && low_ok:
		return fmt.tprintf("high pass, %v dB/oct (%v-pole)", dec0(low_slope), dec0(poles(low_slope)))
	case:
		return "flat, or no usable slope"
	}
}

cmd_filterprobe :: proc(dll: string, cutoff, resonance: int, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	dump_indices := []int{0, 1, 5, 14, 19, 20, 21, 22, 23, 25, 26, 27, 28, 29, 37, 57, 58, 66, 77}
	dumped := !dump

	// Noise through the filter: a flat source, so what comes out is the filter's
	// own response. Parameter 1's states are display-keyed "1".."4" -- triangle,
	// saw, pulse, noise -- so 4 is noise, and the mix is put fully on
	// oscillator 2 to hear it alone.
	base := neutral_probe_patch()
	set_param(&base, 1, 4) // osc2: noise
	set_param(&base, 5, 127) // mix: oscillator 2 alone
	set_param(&base, 29, 110) // gain, short of maximum to leave headroom
	set_param(&base, 20, clamp(resonance, 0, 127))

	SECONDS :: 1.2

	// The reference render: the same noise with the filter wide open. Dividing
	// by it removes both the source's spectrum and the amplifier, leaving the
	// filter. A wide-open low pass is not perfectly flat, so this is an
	// approximation -- but it is the same approximation for every state, which
	// is what the comparison needs.
	open := base
	set_param(&open, 14, 0)
	set_param(&open, 19, 127)
	open_audio := probe_render(dll, &open, pristine, work, note, SECONDS, &dumped, dump_indices)
	if open_audio == nil {
		fmt.eprintln("filterprobe: could not render the open reference")
		os.exit(1)
	}
	defer delete(open_audio)

	open_bands, centres, open_ok := probe_band_levels(open_audio)
	defer delete(open_bands)
	defer delete(centres)
	if !open_ok {
		fmt.eprintln("filterprobe: the open reference produced no spectrum")
		os.exit(1)
	}

	fmt.printfln("filterprobe: cutoff %v, resonance %v, note %v, noise source",
		cutoff, resonance, note)
	fmt.println()

	responses := make([]Filter_Response, FILTER_STATE_COUNT)
	defer {
		for r in responses {
			delete(r.bands)
			delete(r.centres)
			delete(r.display)
		}
		delete(responses)
	}

	for state in 0 ..< FILTER_STATE_COUNT {
		p := base
		set_param(&p, 14, state)
		set_param(&p, 19, clamp(cutoff, 0, 127))

		audio := probe_render(dll, &p, pristine, work, note, SECONDS, nil, nil)
		if audio == nil {
			continue
		}
		defer delete(audio)

		bands, band_centres, ok := probe_band_levels(audio)
		defer delete(band_centres)
		if !ok {
			delete(bands)
			continue
		}

		// Relative to the open render, in dB.
		relative := make([]f64, len(bands))
		for b in 0 ..< len(bands) {
			if bands[b] <= 0 || b >= len(open_bands) || open_bands[b] <= 0 {
				relative[b] = -999
			} else {
				relative[b] = power_db(bands[b] / open_bands[b])
			}
		}
		delete(bands)

		r := Filter_Response {
			state   = state,
			bands   = relative,
			centres = make([]f64, len(centres)),
		}
		copy(r.centres, centres)

		// The peak of the response locates the corner without assuming which
		// side is the pass band.
		best := -1.0e9
		for b in 0 ..< len(relative) {
			if relative[b] > -900 && relative[b] > best {
				best = relative[b]
				r.peak_hz = centres[b]
			}
		}
		if r.peak_hz > 0 {
			// The slope is fitted outside the pass band, not either side of the
			// peak. For a low pass the peak is at DC, so "an octave below the
			// peak" is not a place -- an earlier version anchored on the peak and
			// duly reported the 24 dB low pass as flat, having fitted a straight
			// line across its pass band.
			//
			// The edges are the -3 dB points relative to the maximum, and the fit
			// starts two octaves outside them so it is in the asymptotic region
			// rather than on the shoulder.
			peak_db := -1.0e9
			for b in 0 ..< len(relative) {
				if relative[b] > -900 && relative[b] > peak_db {
					peak_db = relative[b]
				}
			}
			edge_db := peak_db - 3.0
			low_edge := 0.0
			high_edge := 0.0
			for b in 0 ..< len(relative) {
				if relative[b] <= -900 || relative[b] < edge_db {
					continue
				}
				if low_edge == 0 {
					low_edge = centres[b]
				}
				high_edge = centres[b]
			}
			r.low_edge_hz = low_edge
			r.high_edge_hz = high_edge

			if low_edge > 0 {
				low, low_ok := band_slope(relative, centres, BAND_LO_HZ, low_edge / 4.0)
				if low_ok {r.low_slope = low}
				r.low_ok = low_ok
			}
			if high_edge > 0 {
				high, high_ok := band_slope(relative, centres, high_edge * 4.0, BAND_HI_HZ)
				if high_ok {r.high_slope = high}
				r.high_ok = high_ok
			}
			r.verdict = strings.clone(classify_filter(r.low_edge_hz, r.high_edge_hz, r.low_slope, r.high_slope, r.low_ok, r.high_ok))
		} else {
			r.verdict = strings.clone("silent")
		}
		responses[state] = r
		free_all(context.temp_allocator)
	}

	// -- the response curves, an octave apart --------------------------------
	fmt.println("response relative to the open filter, dB")
	header := strings.builder_make()
	defer strings.builder_destroy(&header)
	fmt.sbprintf(&header, "%-10v", "Hz")
	for state in 0 ..< FILTER_STATE_COUNT {
		fmt.sbprintf(&header, " %8v", fmt.tprintf("type %v", state))
	}
	fmt.println(strings.to_string(header))

	probe_hz := []f64{50, 100, 200, 400, 800, 1600, 3200, 6400, 12800}
	for hz in probe_hz {
		line := strings.builder_make()
		defer strings.builder_destroy(&line)
		fmt.sbprintf(&line, "%-10v", dec0(hz))
		for state in 0 ..< FILTER_STATE_COUNT {
			r := responses[state]
			value := -999.0
			if len(r.centres) > 0 {
				// Nearest band centre.
				best_b := 0
				best_d := 1.0e18
				for b in 0 ..< len(r.centres) {
					d := abs(log2f(r.centres[b] / hz))
					if d < best_d {
						best_d = d
						best_b = b
					}
				}
				value = r.bands[best_b]
			}
			fmt.sbprintf(&line, " %8v", value <= -900 ? "-" : dec1(value))
		}
		fmt.println(strings.to_string(line))
	}
	fmt.println()

	fmt.println("state   -3dB band Hz     low slope    high slope   response")
	for state in 0 ..< FILTER_STATE_COUNT {
		r := responses[state]
		fmt.printfln("  %v   %v  %v dB/oct %v dB/oct   %v",
			state,
			pad_left(fmt.tprintf("%v-%v", dec0(r.low_edge_hz), dec0(r.high_edge_hz)), 13),
			r.low_ok ? sdec1(r.low_slope, 9) : pad_left("-", 9),
			r.high_ok ? sdec1(r.high_slope, 10) : pad_left("-", 10),
			r.verdict)
	}
	fmt.println()
	fmt.println("The English manual calls state 3 a 24 dB high pass; the Japanese manual")
	fmt.println("for the same version calls it a 12 dB band pass. The slopes above decide.")
}

// Band powers of the sustained middle of a render.
probe_band_levels :: proc(audio: []f32) -> (bands, centres: []f64, ok: bool) {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < FFT_SIZE * 2 {
		return nil, nil, false
	}
	// Skip the first 100 ms so the filter has settled.
	from := int(0.1 * f64(SAMPLE_RATE))
	power := welch_power(mid, from, len(mid))
	defer delete(power)
	if power == nil {
		return nil, nil, false
	}
	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	bands, centres = band_powers(power, bin_hz)
	return bands, centres, bands != nil
}

// ----------------------------------------------------------------- LFO probe

LFO_STATE_COUNT :: 7

// What one destination did to one configuration.
Lfo_Observation :: struct {
	amplitude_db:  f64,
	pan:           f64,
	pitch_cents:   f64,
	centroid_oct:  f64,
	// How much the balance between high and low content moved, in dB.
	//
	// The centroid is a poor detector of a change in *harmonic* balance: a pulse
	// whose width is being swept gains and loses whole harmonics while its centre
	// of mass barely shifts, and the first version of this probe reported the
	// pulse-width destination as doing nothing at all. The ratio of energy above
	// and below a fixed split moves properly for both width and cutoff.
	timbre_db:     f64,
	silent:        bool,
}

// Where the high/low split for `timbre_db` sits. Above the fundamental of the
// probe note and well inside the filter's range, so both a width sweep and a
// cutoff sweep cross it.
TIMBRE_SPLIT_HZ :: 1500.0

// Watch a render for the things an LFO destination could be moving.
observe_modulation :: proc(audio: []f32) -> Lfo_Observation {
	o: Lfo_Observation

	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < MOD_FFT * 2 {
		o.silent = true
		return o
	}

	frames := 1 + (len(mid) - MOD_FFT) / MOD_HOP
	if frames < 4 {
		o.silent = true
		return o
	}

	levels := make([]f64, frames)
	defer delete(levels)
	pans := make([]f64, frames)
	defer delete(pans)
	pitches := make([]f64, frames)
	defer delete(pitches)
	centroids := make([]f64, frames)
	defer delete(centroids)
	timbres := make([]f64, frames)
	defer delete(timbres)

	bins := MOD_FFT / 2 + 1
	power := make([]f64, bins)
	defer delete(power)
	re := make([]f64, MOD_FFT)
	defer delete(re)
	im := make([]f64, MOD_FFT)
	defer delete(im)

	bin_hz := f64(SAMPLE_RATE) / f64(MOD_FFT)
	channels := 2
	usable := 0

	for f in 0 ..< frames {
		from := f * MOD_HOP
		if !window_power(mid, from, power, re, im) {
			break
		}

		rms := signal_rms(mid[from:from + MOD_FFT])
		if rms < 1.0e-5 {
			continue
		}
		levels[usable] = amplitude_db(rms)

		// Stereo position, as the side-to-mid ratio over the same window.
		l_rms := 0.0
		r_rms := 0.0
		for i in from ..< from + MOD_FFT {
			frame := i * channels
			if frame + 1 >= len(audio) {
				break
			}
			l := f64(audio[frame])
			r := f64(audio[frame + 1])
			l_rms += l * l
			r_rms += r * r
		}
		total := math.sqrt(l_rms) + math.sqrt(r_rms)
		pans[usable] = total > 0 ? (math.sqrt(l_rms) - math.sqrt(r_rms)) / total : 0

		f0 := dominant_frequency(power, bin_hz, 12000.0)
		pitches[usable] = f0 > 0 ? 1200.0 * log2f(f0) : 0
		centroids[usable] = log2f(max(spectral_centroid(power, bin_hz), 1.0))

		low_energy := 0.0
		high_energy := 0.0
		for k in 1 ..< len(power) {
			hz := f64(k) * bin_hz
			if hz < BAND_LO_HZ || hz > BAND_HI_HZ {
				continue
			}
			if hz < TIMBRE_SPLIT_HZ {
				low_energy += power[k]
			} else {
				high_energy += power[k]
			}
		}
		timbres[usable] = power_db(max(high_energy, 1.0e-30) / max(low_energy, 1.0e-30))
		usable += 1
	}

	if usable < 4 {
		o.silent = true
		return o
	}

	o.amplitude_db = span(levels[:usable])
	o.pan = span(pans[:usable])
	o.pitch_cents = span(pitches[:usable])
	o.centroid_oct = span(centroids[:usable])
	o.timbre_db = span(timbres[:usable])
	return o
}

Lfo_Config :: enum {
	Osc1_Alone,
	Osc2_Alone,
	Sine_Carrier,
	Osc1_Open,
}

lfo_config_name :: proc(c: Lfo_Config) -> string {
	switch c {
	case .Osc1_Alone:
		return "osc1 pulse"
	case .Osc2_Alone:
		return "osc2 pulse"
	case .Sine_Carrier:
		return "osc1 sine"
	case .Osc1_Open:
		return "pulse open"
	}
	return "?"
}

// The patch one LFO destination is tested with, in one configuration.
lfo_probe_patch :: proc(
	config: Lfo_Config,
	dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index: int,
	state: int,
	rate: u8,
) -> cpatch.Patch {
	p := neutral_probe_patch()

	// Two clearly separated pitches, so "which oscillator moved" is a question
	// the spectrum can answer. Oscillator 2 is put a fifth up and slightly out of
	// tune, which also makes any FM sidebands inharmonic rather than hiding among
	// the harmonics.
	set_param(&p, 2, 64 + 7) // osc2 pitch, +7 semitones from centre
	set_param(&p, 3, 90) // osc2 fine tune, off the harmonic grid
	set_param(&p, 8, g_probe_pw) // pulse width, varied by --pw

	switch config {
	case .Osc1_Alone:
		set_param(&p, 0, 3) // osc1: pulse
		set_param(&p, 5, 0) // oscillator 1 alone
	case .Osc2_Alone:
		set_param(&p, 1, 3) // osc2: pulse
		set_param(&p, 5, 127) // oscillator 2 alone
	case .Sine_Carrier:
		set_param(&p, 0, 0) // osc1: sine
		set_param(&p, 5, 0)
	case .Osc1_Open:
		set_param(&p, 0, 3) // osc1: pulse
		set_param(&p, 5, 0)
	}

	// The filter is left half open so a cutoff destination has somewhere to move;
	// wide open, it would barely register.
	//
	// That same filter is why the fourth configuration exists. A pulse width
	// sweep does its work in the harmonics well above the fundamental, which is
	// exactly what a low pass at this setting removes.
	set_param(&p, 14, 0) // low pass 12
	set_param(&p, 19, config == .Osc1_Open ? 127 : 70)
	set_param(&p, 29, 110)

	set_param(&p, on_index, 1)
	set_param(&p, dest_index, state)
	set_param(&p, speed_index, int(rate))
	set_param(&p, depth_index, 127)
	set_param(&p, keysync_index, 1) // start from the same phase every time
	set_param(&p, temposync_index, 0)

	return p
}

cmd_lfoprobe :: proc(dll: string, param: int, rate, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	// LFO 1 lives at 41/43/44/57/68, LFO 2 at 46/48/49/58/70.
	is_lfo1 := param != 46
	dest_index := is_lfo1 ? 41 : 46
	speed_index := is_lfo1 ? 43 : 48
	depth_index := is_lfo1 ? 44 : 49
	on_index := is_lfo1 ? 57 : 58
	keysync_index := is_lfo1 ? 68 : 70
	temposync_index := is_lfo1 ? 67 : 69

	dump_indices := []int {
		0, 1, 2, 5, 8, 14, 19, 21, 45,
		dest_index, speed_index, depth_index, on_index, keysync_index, temposync_index,
	}
	dumped := !dump

	SECONDS :: 3.0

	fmt.printfln("lfoprobe: parameter %v (%v), rate %v, depth 127, note %v",
		dest_index, cpatch.PARAMETERS[dest_index].name, rate, note)
	fmt.println()
	fmt.println("Each destination is driven at full depth and the render watched for what")
	fmt.println("moves. Three configurations, because several destinations are invisible in")
	fmt.println("any one of them:")
	fmt.println("  osc1 pulse  oscillator 1 alone, a pulse wave")
	fmt.println("  osc2 pulse  oscillator 2 alone, so oscillator 2's own pitch is visible")
	fmt.println("  osc1 sine   oscillator 1 alone as a sine: pulse width has nothing to act")
	fmt.println("              on, so a timbre change here is FM rather than width")
	fmt.println()

	configs := []Lfo_Config{.Osc1_Alone, .Osc2_Alone, .Sine_Carrier, .Osc1_Open}

	// One render per configuration with the LFO switched off, kept to compare
	// every destination against.
	//
	// This is the column that decides whether a row of zeroes means "this
	// destination does nothing here" or "these metrics cannot see what it did".
	// A metric can be blind; a sample-by-sample difference against the same patch
	// with the modulation turned off cannot.
	baselines := make([][]f32, len(configs))
	defer {
		for b in baselines {
			delete(b)
		}
		delete(baselines)
	}
	for config, ci in configs {
		p := lfo_probe_patch(config, dest_index, speed_index, depth_index, on_index,
			keysync_index, temposync_index, 1, rate)
		set_param(&p, on_index, 0)
		set_param(&p, depth_index, 0)
		baselines[ci] = probe_render(dll, &p, pristine, work, note, SECONDS, nil, nil)
	}

	fmt.printfln("%-6v %-12v %9v %7v %9v %9v %9v %9v",
		"state", "config", "amp dB", "pan", "pitch c", "centroid", "timbre dB", "vs off")
	fmt.println(strings.repeat("-", 80, context.temp_allocator))

	for state in 1 ..= LFO_STATE_COUNT {
		for config, ci in configs {
			p := lfo_probe_patch(config, dest_index, speed_index, depth_index, on_index,
				keysync_index, temposync_index, state, rate)

			audio := probe_render(dll, &p, pristine, work, note, SECONDS, &dumped, dump_indices)
			if audio == nil {
				continue
			}
			o := observe_modulation(audio)

			// The decisive column: does this render differ from the same patch
			// with the LFO off, at all, anywhere?
			difference := -1.0
			if baselines[ci] != nil {
				difference = 0
				n := min(len(audio), len(baselines[ci]))
				for i in 0 ..< n {
					d := abs(f64(audio[i]) - f64(baselines[ci][i]))
					if d > difference {
						difference = d
					}
				}
			}
			delete(audio)

			// `state` is padded as text: Odin pads a numeric field with zeros
			// even when left-aligned, which turns state 1 into "100000".
			label := pad_right(fmt.tprintf("%v", state), 6)
			if o.silent {
				fmt.printfln("%v %-12v %9v", label, lfo_config_name(config), "silent")
			} else {
				fmt.printfln("%v %-12v %9v %7v %9v %9v %9v %9v",
					label, lfo_config_name(config),
					dec2(o.amplitude_db), dec3(o.pan), dec0(o.pitch_cents),
					dec3(o.centroid_oct), dec2(o.timbre_db),
					difference < 0 ? "-" : dec5(difference))
			}
			free_all(context.temp_allocator)
		}
	}

	fmt.println()
	fmt.println("Reading it: a destination that moves oscillator 1's pitch shows cents on")
	fmt.println("the osc1 rows and not the osc2 row, and one that moves both shows cents on")
	fmt.println("both. Cutoff shows as centroid without pitch. Volume shows as amp dB.")
	fmt.println("Pulse width shows as centroid on the pulse rows but not on the sine row;")
	fmt.println("FM shows on the sine row too. Pan shows as pan.")
}

// --------------------------------------------------------------- wave probe

// Identify each oscillator waveform state from its harmonic series.
//
// This exists because the LFO probe turned up something it was not looking for:
// with oscillator 1 set to shape state 3 -- which this project binds as the
// pulse wave, following the manual's listing order of "sine, triangle, saw,
// pulse" -- changing the pulse width parameter from 10 to 120 left the render
// bit-identical. A pulse whose width does nothing is not a pulse, so the
// listing order cannot be assumed to be the state order, exactly as it could
// not be for the LFO destinations.
//
// The harmonic series names each waveform without ambiguity:
//
//   sine      nothing above the fundamental
//   triangle  odd harmonics only, falling about 12 dB per harmonic
//   saw       every harmonic, falling about 6 dB per doubling
//   pulse     at 50% width, odd harmonics only, falling like a saw's
//   noise     no harmonic structure at all
//
// Triangle and pulse are both odd-only, so the rate of fall is what separates
// them; pulse is additionally the one whose spectrum moves with the width.
cmd_waveprobe :: proc(dll: string, note: u8, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	dump_indices := []int{0, 1, 5, 8, 14, 19, 21, 25, 27, 29}
	dumped := !dump

	fmt.printfln("waveprobe: note %v, filter wide open, harmonics relative to the fundamental",
		note)
	fmt.println()
	fmt.printfln("%-18v %8v %7v %7v %7v %7v %7v %7v %9v %9v",
		"oscillator/state", "f0 Hz", "h2", "h3", "h4", "h5", "h6", "h7", "width?", "rms")
	fmt.println(strings.repeat("-", 92, context.temp_allocator))

	// Oscillator 1's states are 0..3; oscillator 2's are display-keyed 1..4.
	for osc in 0 ..< 2 {
		shape_index := osc == 0 ? 0 : 1
		low := osc == 0 ? 0 : 1
		for state in low ..< low + 4 {
			harmonics: [8]f64
			f0: f64
			rms: f64
			widths: [2][8]f64
			for pass in 0 ..< 2 {
				p := neutral_probe_patch()
				set_param(&p, shape_index, state)
				set_param(&p, 5, osc == 0 ? 0 : 127)
				set_param(&p, 19, 127) // filter wide open
				set_param(&p, 29, 110)
				// Two pulse widths, so a width-sensitive waveform is identified
				// by its own behaviour rather than by its position in a list.
				set_param(&p, 8, pass == 0 ? 64 : 20)

				audio := probe_render(dll, &p, pristine, work, note, 1.2, &dumped, dump_indices)
				if audio == nil {
					continue
				}
				h, fundamental := harmonic_levels(audio)
				if pass == 0 {
					mid, side := split_mid_side(audio, 2)
					rms = signal_rms(mid[int(0.1 * f64(SAMPLE_RATE)):])
					delete(mid)
					delete(side)
				}
				delete(audio)
				widths[pass] = h
				if pass == 0 {
					harmonics = h
					f0 = fundamental
				}
			}

			// How far the harmonic series moved between the two widths.
			width_shift := 0.0
			for n in 1 ..< 8 {
				if widths[0][n] > -90 && widths[1][n] > -90 {
					width_shift = max(width_shift, abs(widths[0][n] - widths[1][n]))
				}
			}

			label := fmt.tprintf("osc%v state %v", osc + 1, state)
			fmt.printfln("%-18v %8v %7v %7v %7v %7v %7v %7v %9v %9v",
				label, dec1(f0),
				harmonic_text(harmonics[1]), harmonic_text(harmonics[2]),
				harmonic_text(harmonics[3]), harmonic_text(harmonics[4]),
				harmonic_text(harmonics[5]), harmonic_text(harmonics[6]),
				dec1(width_shift), dec5(rms))
			free_all(context.temp_allocator)
		}
	}
	fmt.println()
	fmt.println("'width?' is how far the harmonic series moved when the pulse width knob was")
	fmt.println("changed from 64 to 20. Only the pulse wave should respond to it.")
}

harmonic_text :: proc(db: f64) -> string {
	if db <= -90 {
		return pad_left("-", 7)
	}
	return dec1(db, 7)
}

// Levels of the first eight harmonics, in dB relative to the fundamental.
harmonic_levels :: proc(audio: []f32) -> (levels: [8]f64, f0: f64) {
	for i in 0 ..< 8 {
		levels[i] = -999
	}

	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	if len(mid) < FFT_SIZE * 2 {
		return
	}

	power := welch_power(mid, int(0.1 * f64(SAMPLE_RATE)), len(mid))
	defer delete(power)
	if power == nil {
		return
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	f0 = dominant_frequency(power, bin_hz, 2000.0)
	if f0 <= 0 {
		return
	}

	// Energy in a narrow window around each harmonic, so a little detuning or
	// leakage does not lose it.
	fundamental := 0.0
	for n in 1 ..= 8 {
		centre := f0 * f64(n)
		if centre > BAND_HI_HZ {
			break
		}
		lo := int((centre - bin_hz * 3) / bin_hz)
		hi := int((centre + bin_hz * 3) / bin_hz)
		sum := 0.0
		for k in max(lo, 1) ..= min(hi, len(power) - 1) {
			sum += power[k]
		}
		if n == 1 {
			fundamental = sum
			levels[0] = 0
			continue
		}
		levels[n - 1] = fundamental > 0 && sum > 0 ? power_db(sum / fundamental) : -999
	}
	return
}

// ------------------------------------------------------------------ arguments

parse_probe_int :: proc(args: []string, i: int, out: ^int) -> bool {
	if i >= len(args) {
		return false
	}
	v, ok := strconv.parse_int(args[i])
	if !ok {
		return false
	}
	out^ = v
	return true
}
