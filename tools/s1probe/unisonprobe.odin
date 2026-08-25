package s1probe

// Reproducible external-reference measurements for the unison stack. Every
// render opens a fresh Synth1 instance through probe_render or
// render_reference_fresh; no oscillator, envelope or effect state survives
// from one row to the next.

import "core:fmt"
import "core:math"
import "core:os"

import cpatch "../../src/patch"

UNISON_FIXTURE_DEFAULT :: "tools/s1probe/fixtures/unison-four.sy1"
UNISON_DETUNE_SECONDS :: 12.0
UNISON_DETUNE_FFT :: 524288

// The reference's four-layer stack sits at these fractions of the full detune
// span. The probe checks the reading against the layout instead of assuming it,
// so a row whose layers the transform could not separate is reported as
// unresolved rather than printed as a number.
UNISON_LAYOUT :: [4]f64{-0.5, -1.0 / 6.0, 1.0 / 6.0, 0.5}

// Phases of different frequencies only share an origin if that origin is
// note-on, and a frequency estimate's phase lever arm grows with the window's
// centre, so the pairing window starts at the note and stays short. Four
// seconds of Hann resolves 0.5 Hz, hence the 2 Hz spacing floor.
UNISON_PAIR_SECONDS :: 4.0
UNISON_PAIR_MIN_SPACING_HZ :: 2.0

Unison_Phasor :: struct {
	re, im: f64,
	ok: bool,
}

unison_mid :: proc(audio: []f32) -> []f32 {
	frames := len(audio) / 2
	mid := make([]f32, frames)
	for i in 0 ..< frames {
		mid[i] = (audio[i * 2] + audio[i * 2 + 1]) * 0.5
	}
	return mid
}

// Resolve several close fundamentals without assuming their cents law. The
// longest sweep uses a 10.9-second Hann window, which separates the four tones
// even at stored 16 where adjacent layers are less than 1 Hz apart.
unison_spectral_peaks :: proc(
	signal: []f32,
	sample_rate, centre_hz, half_width_hz: f64,
	want: int,
	fft_limit := UNISON_DETUNE_FFT,
) -> (peaks: [dynamic]f64, ok: bool) {
	n := 1
	for n * 2 <= len(signal) && n * 2 <= fft_limit {
		n *= 2
	}
	if n < 4096 || want < 1 {
		return nil, false
	}
	from := len(signal) - n
	re := make([]f64, n)
	defer delete(re)
	im := make([]f64, n)
	defer delete(im)
	for i in 0 ..< n {
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i) / f64(n - 1))
		re[i] = f64(signal[from + i]) * w
	}
	fft_forward(re, im)
	bin_hz := sample_rate / f64(n)
	lo := max(1, int((centre_hz - half_width_hz) / bin_hz))
	hi := min(n / 2 - 1, int((centre_hz + half_width_hz) / bin_hz) + 1)
	power := make([]f64, n / 2 + 1)
	defer delete(power)
	for k in lo - 1 ..= hi + 1 {
		power[k] = re[k] * re[k] + im[k] * im[k]
	}

	chosen := make([]bool, n / 2 + 1)
	defer delete(chosen)
	for _ in 0 ..< want {
		best_k := -1
		best_power := 0.0
		for k in lo ..= hi {
			if chosen[k] || power[k] <= power[k - 1] || power[k] < power[k + 1] {
				continue
			}
			if power[k] > best_power {
				best_k = k
				best_power = power[k]
			}
		}
		if best_k < 0 || best_power <= 0 {
			delete(peaks)
			return nil, false
		}
		// Log-power parabolic interpolation is stable across large amplitude
		// differences and removes the remaining FFT-bin quantisation.
		a := math.ln(max(power[best_k - 1], 1.0e-300))
		b := math.ln(max(power[best_k], 1.0e-300))
		c := math.ln(max(power[best_k + 1], 1.0e-300))
		den := a - 2.0 * b + c
		delta := 0.0
		if abs(den) > 1.0e-20 {
			delta = 0.5 * (a - c) / den
		}
		append(&peaks, (f64(best_k) + delta) * bin_hz)
		// Suppress this main lobe, but not a neighbouring unison tone.
		for j in max(lo, best_k - 1) ..= min(hi, best_k + 1) {
			chosen[j] = true
		}
	}
	// The requested count is at most eight, so an insertion sort is clearer
	// than importing a generic comparator solely for this report.
	for i in 1 ..< len(peaks) {
		v := peaks[i]
		j := i
		for j > 0 && peaks[j - 1] > v {
			peaks[j] = peaks[j - 1]
			j -= 1
		}
		peaks[j] = v
	}
	return peaks, true
}

unison_steady_rms :: proc(audio: []f32) -> (f64, bool) {
	mid := unison_mid(audio)
	defer delete(mid)
	to := min(len(mid), g_hold_frames)
	from := max(0, to - SAMPLE_RATE)
	if to - from < SAMPLE_RATE / 2 {
		return 0, false
	}
	sum := 0.0
	for x in mid[from:to] {
		sum += f64(x) * f64(x)
	}
	return math.sqrt(sum / f64(to - from)), true
}

unison_phasor :: proc(audio: []f32, hz: f64) -> Unison_Phasor {
	mid := unison_mid(audio)
	defer delete(mid)
	to := min(len(mid), g_hold_frames)
	from := max(0, to - SAMPLE_RATE)
	if to - from < SAMPLE_RATE / 2 {
		return {}
	}
	re, im := 0.0, 0.0
	n := f64(to - from)
	for i in from ..< to {
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i - from) / n)
		a := 2.0 * math.PI * hz * f64(i) / f64(SAMPLE_RATE)
		re += f64(mid[i]) * w * math.cos(a)
		im -= f64(mid[i]) * w * math.sin(a)
	}
	return {re = re, im = im, ok = re * re + im * im > 1.0e-16}
}

unison_turns :: proc(v: Unison_Phasor) -> f64 {
	x := math.atan2(v.im, v.re) / (2.0 * math.PI)
	for x < 0 {x += 1.0}
	for x >= 1 {x -= 1.0}
	return x
}

// The same projection over a chosen window. `unison_phasor` reads the steady
// tail, which is right for a stack whose layers share one frequency; a detuned
// stack needs an early window instead, for the lever-arm reason above.
unison_phasor_window :: proc(audio: []f32, hz: f64, from, to: int) -> Unison_Phasor {
	mid := unison_mid(audio)
	defer delete(mid)
	lo := max(0, from)
	hi := min(len(mid), to)
	if hi - lo < SAMPLE_RATE / 4 {
		return {}
	}
	re, im := 0.0, 0.0
	n := f64(hi - lo)
	for i in lo ..< hi {
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i - lo) / n)
		a := 2.0 * math.PI * hz * f64(i) / f64(SAMPLE_RATE)
		re += f64(mid[i]) * w * math.cos(a)
		im -= f64(mid[i]) * w * math.sin(a)
	}
	return {re = re, im = im, ok = re * re + im * im > 1.0e-16}
}

// Signed turns of `v` ahead of `origin`, as a phasor product rather than a
// difference of two wrapped angles.
unison_relative_turns :: proc(v, origin: Unison_Phasor) -> f64 {
	return unison_turns(
		Unison_Phasor{
			re = v.re * origin.re + v.im * origin.im,
			im = v.im * origin.re - v.re * origin.im,
			ok = true,
		},
	)
}

// One detuned render, read four ways: the layers' cents against the note,
// whether they land on the reference's layout, their closest spacing, and --
// when that spacing lets an early window tell them apart -- each layer's start
// phase against the lowest layer's. The last of those is what pairs a phase
// with a detune slot. Equal stack RMS at zero detune cannot do it, because any
// permutation of one phase set sums to the same magnitude.
Unison_Layers :: struct {
	cents:      [4]f64,
	turns:      [4]f64,
	half_span:  f64,
	spacing_hz: f64,
	resolved:   bool,
	paired:     bool,
}

unison_read_layers :: proc(audio: []f32, f0: f64) -> (out: Unison_Layers, ok: bool) {
	mid := unison_mid(audio)
	defer delete(mid)
	// Wide enough for the +/-50 cents the knob reaches at its top, at any note.
	half_width := max(f0 * 0.045, 12.0)
	peaks, peaks_ok := unison_spectral_peaks(
		mid[:min(len(mid), g_hold_frames)],
		f64(SAMPLE_RATE),
		f0,
		half_width,
		4,
	)
	defer delete(peaks)
	if !peaks_ok {
		return {}, false
	}
	for hz, i in peaks {
		out.cents[i] = 1200.0 * math.log2(hz / f0)
	}
	out.half_span = 0.5 * (abs(out.cents[0]) + abs(out.cents[3]))
	out.spacing_hz = peaks[1] - peaks[0]
	for i in 1 ..< 4 {
		out.spacing_hz = min(out.spacing_hz, peaks[i] - peaks[i - 1])
	}
	// A layout tolerance proportional to the span, with a floor for the
	// smallest settings, where the transform's own resolution dominates.
	layout := UNISON_LAYOUT
	tolerance := max(0.02 * out.half_span, 0.002)
	out.resolved = out.half_span > 0
	for fraction, i in layout {
		if abs(out.cents[i] - 2.0 * fraction * out.half_span) > tolerance {
			out.resolved = false
		}
	}
	if !out.resolved || out.spacing_hz < UNISON_PAIR_MIN_SPACING_HZ {
		return out, true
	}
	window := int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE))
	origin := unison_phasor_window(audio, peaks[0], 0, window)
	if !origin.ok {
		return out, true
	}
	out.paired = true
	for hz, i in peaks {
		layer := unison_phasor_window(audio, hz, 0, window)
		if !layer.ok {
			out.paired = false
			break
		}
		out.turns[i] = unison_relative_turns(layer, origin)
	}
	return out, true
}

// Read the complete OSC1 parameter-76 construction. `peak_count` can include
// outer parameter-75 layers as well as the nine inner components, so
// interaction and voice-count claims use the same signed peak reader as the
// one-voice law.
unison_read_component_field :: proc(
	audio: []f32,
	f0: f64,
	peak_count: int,
) -> (peaks: [dynamic]f64, ok: bool) {
	mid := unison_mid(audio)
	defer delete(mid)
	peaks, ok = unison_spectral_peaks(
		mid[:min(len(mid), g_hold_frames)],
		f64(SAMPLE_RATE), f0, max(f0 * 0.20, 12.0), peak_count,
	)
	if !ok {
		delete(peaks)
		return nil, false
	}
	return peaks, true
}

unison_read_inner_components :: proc(
	audio: []f32,
	f0: f64,
) -> (peaks: [dynamic]f64, ok: bool) {
	return unison_read_component_field(audio, f0, 9)
}

unison_render :: proc(
	dll: string,
	p: ^cpatch.Patch,
	pristine, work: []byte,
	note: u8,
	seconds: f64,
) -> []f32 {
	dumped := true
	return probe_render(dll, p, pristine, work, note, seconds, &dumped, nil)
}

unison_require :: proc(ok: bool, what: string) {
	if !ok {
		fmt.eprintfln("unisonprobe: required reading failed: %s", what)
		os.exit(1)
	}
}

cmd_unisonprobe :: proc(dll, fixture: string, values: []int, note: u8) {
	data, read_err := os.read_entire_file(fixture, context.allocator)
	if read_err != nil {
		fmt.eprintfln("unisonprobe: cannot read %q: %v", fixture, read_err)
		os.exit(1)
	}
	defer delete(data, context.allocator)
	base, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("unisonprobe: cannot parse %q: %v", fixture, parse_err)
		os.exit(1)
	}
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)

	fmt.printfln("unison reference probe: fixture=%s note=%d (%.4f Hz)", fixture, note, f0)
	fmt.println()
	fmt.println("detune: signed four-layer cents against the note, and the null at the null")
	fmt.println("test's own 1.5 s hold. `layout` checks the reading against the reference's")
	fmt.println("-1/2, -1/6, +1/6, +1/2 span before any of the row is believed.")
	for stored in values {
		p := base
		set_param(&p, 73, 1)
		set_param(&p, 93, 4)
		set_param(&p, 75, stored)
		set_param(&p, 85, 24)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		unison_require(audio != nil, fmt.tprintf("detune stored %d render", stored))
		layers, layers_ok := unison_read_layers(audio, f0)
		delete(audio)
		unison_require(layers_ok, fmt.tprintf("detune stored %d peaks", stored))

		set_compare_timing(COMPARE_BLOCK_DEFAULT)
		ref, mismatches, ref_ok := render_reference_fresh(dll, &p, pristine, work, note)
		unison_require(
			ref_ok && ref != nil && mismatches == 0,
			fmt.tprintf("detune stored %d reference render", stored),
		)
		ours := render_ours(p, int(note))
		unison_require(ours != nil, fmt.tprintf("detune stored %d engine render", stored))
		c := compare_renders(ref, ours, 2, f64(SAMPLE_RATE), COMPARE_HOLD_SECONDS)
		delete(ref)
		delete(ours)

		if !layers.resolved {
			fmt.printfln(
				"stored %3v  layers %+.3f %+.3f %+.3f %+.3f cents  UNRESOLVED at %.2f Hz spacing  level %+.3f  null %.2f dB",
				stored, layers.cents[0], layers.cents[1], layers.cents[2],
				layers.cents[3], layers.spacing_hz, c.level_db, c.null_db,
			)
			continue
		}
		fmt.printfln(
			"stored %3v  layers %+.3f %+.3f %+.3f %+.3f cents  half-span %.3f  layout ok  level %+.3f  null %.2f dB",
			stored, layers.cents[0], layers.cents[1], layers.cents[2], layers.cents[3],
			layers.half_span, c.level_db, c.null_db,
		)
		if layers.paired {
			fmt.printfln(
				"            start phase of each layer against the lowest: %+.4f %+.4f %+.4f %+.4f turns",
				layers.turns[0], layers.turns[1], layers.turns[2], layers.turns[3],
			)
		}
	}

	fmt.println()
	fmt.println("parameter 76: nine signed OSC1 components (one outer voice)")
	fmt.println("inner law is centre plus +/-1,3,5,7 times 20*stored/127 cents")
	for stored in ([]int{0, 8, 16, 20, 32, 64, 96, 127}) {
		p := base
		set_param(&p, 73, 0)
		set_param(&p, 93, 1)
		set_param(&p, 75, 0)
		set_param(&p, 76, stored)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		unison_require(audio != nil, fmt.tprintf("p76 stored %d render", stored))
		rms, rms_ok := unison_steady_rms(audio)
		if rms_ok {fmt.printfln("stored %3v  external RMS %.6f", stored, rms)}
		peaks, peaks_ok := unison_read_inner_components(audio, f0)
		if stored == 0 {
			// A single tone cannot supply nine local maxima; do not report FFT
			// sidelobes as components.
			peaks_ok = false
		}
		if peaks_ok {
			fmt.printfln("stored %3v  cents:", stored)
			for hz in peaks {
				fmt.printfln("            %+.3f", 1200.0 * math.log2(hz / f0))
			}
			fmt.println("            phase turns / magnitude")
			origin := unison_phasor_window(audio, peaks[len(peaks) / 2], 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			for hz in peaks {
				ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
				fmt.printfln("            %+.4f  %.6f", unison_relative_turns(ph, origin), math.sqrt(ph.re * ph.re + ph.im * ph.im))
			}
		} else {
			fmt.printfln("stored %3v  unresolved", stored)
		}
		delete(peaks)
		delete(audio)
	}
	fmt.println("sub parameter 76 isolation: one voice, -1 octave")
	for stored in ([]int{0, 127}) {
		p := base
		set_param(&p, 73, 0)
		set_param(&p, 93, 1)
		set_param(&p, 75, 0)
		set_param(&p, 76, stored)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		set_param(&p, 95, 110)
		set_param(&p, 97, 1)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		unison_require(audio != nil, fmt.tprintf("sub p76 stored %d render", stored))
		if stored == 0 {
			ph := unison_phasor_window(audio, f0 * 0.5, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			fmt.printfln("sub stored 000  centre magnitude %.6f", math.sqrt(ph.re * ph.re + ph.im * ph.im))
		} else {
			sub_peaks, sub_ok := unison_read_inner_components(audio, f0 * 0.5)
			if sub_ok {
				fmt.println("sub stored 127  cents / phase / magnitude:")
				sub_origin := unison_phasor_window(audio, sub_peaks[len(sub_peaks) / 2], 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
				for hz in sub_peaks {
					ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
					fmt.printfln("            %+.3f  %+.4f  %.6f",
						1200.0 * math.log2(hz / (f0 * 0.5)), unison_relative_turns(ph, sub_origin),
						math.sqrt(ph.re * ph.re + ph.im * ph.im))
				}
			} else {
				fmt.println("sub stored 127 unresolved")
			}
			delete(sub_peaks)
		}
		delete(audio)
	}
	fmt.println("p91 interaction: one voice, p76=127")
	for phase in ([]int{0, 1}) {
		p := base
		set_param(&p, 73, 0)
		set_param(&p, 93, 1)
		set_param(&p, 75, 0)
		set_param(&p, 76, 127)
		set_param(&p, 91, phase)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		peaks, peaks_ok := unison_read_inner_components(audio, f0)
		unison_require(peaks_ok, fmt.tprintf("p91 %d p76 component field", phase))
		origin := unison_phasor_window(audio, peaks[len(peaks) / 2], 0,
			int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
		fmt.printfln("p91 %d signed cents / phase against centre:", phase)
		for hz in peaks {
			ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			fmt.printfln("            %+.3f  %+.4f",
				1200.0 * math.log2(hz / f0), unison_relative_turns(ph, origin))
		}
		delete(peaks)
		delete(audio)
	}

	fmt.println("p75 Cartesian interaction: two voices, p75=64, p76=127")
	{
		p := base
		set_param(&p, 73, 1)
		set_param(&p, 93, 2)
		set_param(&p, 75, 64)
		set_param(&p, 76, 127)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		peaks, peaks_ok := unison_read_component_field(audio, f0, 18)
		unison_require(peaks_ok, "two-voice p75/p76 Cartesian field")
		fmt.println("18 signed cents / phase against lowest component:")
		origin := unison_phasor_window(audio, peaks[0], 0,
			int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
		for hz in peaks {
			ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			fmt.printfln("            %+.3f  %+.4f",
				1200.0 * math.log2(hz / f0), unison_relative_turns(ph, origin))
		}
		delete(peaks)
		delete(audio)
	}

	fmt.println("p76 voice-count control: p75=64, p76=127")
	for count in ([]int{1, 2, 4}) {
		p := base
		set_param(&p, 73, count > 1 ? 1 : 0)
		set_param(&p, 93, count)
		set_param(&p, 75, 64)
		set_param(&p, 76, 127)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		peaks, peaks_ok := unison_read_component_field(audio, f0, count * 9)
		unison_require(peaks_ok, fmt.tprintf("p76 voice-count %d field", count))
		fmt.printfln("voices %d  components %d  first/last %+.3f / %+.3f cents",
			count, len(peaks), 1200.0 * math.log2(peaks[0] / f0),
			1200.0 * math.log2(peaks[len(peaks) - 1] / f0))
		if count == 4 {
			origin := unison_phasor_window(audio, peaks[0], 0,
				int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			fmt.println("four-voice signed cents / phase against lowest component:")
			for hz in peaks {
				ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
				fmt.printfln("            %+.3f  %+.4f",
					1200.0 * math.log2(hz / f0), unison_relative_turns(ph, origin))
			}
		}
		delete(peaks)
		delete(audio)
	}

	fmt.println("controlled fixture field: four voices, p75=22, p76=20")
	if note < 96 {
		// Two Cartesian pairs are only 0.18 cents apart. At lower notes that is
		// below this FFT's bin width; do not turn sidelobes into claimed tones.
		fmt.println("skipped below note 96: the closest pair is not resolvable")
	} else {
		p := base
		set_param(&p, 73, 1)
		set_param(&p, 93, 4)
		set_param(&p, 75, 22)
		set_param(&p, 76, 20)
		set_param(&p, 85, 24)
		set_param(&p, 1, 1)
		set_param(&p, 5, 0)
		audio := unison_render(dll, &p, pristine, work, note, UNISON_DETUNE_SECONDS)
		peaks, peaks_ok := unison_read_component_field(audio, f0, 36)
		unison_require(peaks_ok, "controlled p75=22 p76=20 field")
		origin := unison_phasor_window(audio, peaks[0], 0,
			int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
		fmt.println("36 signed cents / phase against lowest component:")
		for hz in peaks {
			ph := unison_phasor_window(audio, hz, 0, int(UNISON_PAIR_SECONDS * f64(SAMPLE_RATE)))
			fmt.printfln("            %+.3f  %+.4f",
				1200.0 * math.log2(hz / f0), unison_relative_turns(ph, origin))
		}
		delete(peaks)
		delete(audio)
	}
	fmt.println("zero-detune stack: steady RMS and ratio to one voice")
	one_rms := 0.0
	for count in 1 ..= 8 {
		p := base
		set_param(&p, 73, count > 1 ? 1 : 0)
		set_param(&p, 93, count)
		set_param(&p, 75, 0)
		set_param(&p, 76, 0)
		set_param(&p, 91, 0)
		set_param(&p, 92, 0)
		audio := unison_render(dll, &p, pristine, work, note, 1.5)
		rms, rms_ok := unison_steady_rms(audio)
		unison_require(rms_ok, fmt.tprintf("voice count %d RMS", count))
		if count == 1 {one_rms = rms}
		fmt.printfln("voices %d  rms %.5f  ratio %.4f", count, rms, rms / one_rms)
		delete(audio)
	}

	fmt.println()
	fmt.println("parameter 92 with phase fixed: four-voice RMS ratio")
	phase_one := 0.0
	for amount in ([]int{0, 64, 127}) {
		p := base
		set_param(&p, 73, 0)
		set_param(&p, 93, 1)
		set_param(&p, 75, 0)
		set_param(&p, 76, 0)
		set_param(&p, 91, 1)
		set_param(&p, 92, amount)
		one_audio := unison_render(dll, &p, pristine, work, note, 1.5)
		one, one_ok := unison_steady_rms(one_audio)
		unison_require(one_ok, fmt.tprintf("phase amount %d one-voice RMS", amount))
		delete(one_audio)
		if amount == 0 {phase_one = one}
		set_param(&p, 73, 1)
		set_param(&p, 93, 4)
		four_audio := unison_render(dll, &p, pristine, work, note, 1.5)
		four, four_ok := unison_steady_rms(four_audio)
		unison_require(four_ok, fmt.tprintf("phase amount %d four-voice RMS", amount))
		fmt.printfln("stored %v  rms %.5f  ratio %.4f", amount, four, four / phase_one)
		delete(four_audio)
	}

	for amount in ([]int{64, 127}) {
		fmt.printfln("parameter 92 stored %d: signed layer phase offsets", amount)
		previous: Unison_Phasor
		origin: Unison_Phasor
		for count in 1 ..= 8 {
			p := base
			set_param(&p, 73, count > 1 ? 1 : 0)
			set_param(&p, 93, count)
			set_param(&p, 75, 0)
			set_param(&p, 76, 0)
			set_param(&p, 91, 1)
			set_param(&p, 92, amount)
			audio := unison_render(dll, &p, pristine, work, note, 1.5)
			cumulative := unison_phasor(audio, f0)
			delete(audio)
			unison_require(cumulative.ok, fmt.tprintf("phase amount %d layer %d projection", amount, count - 1))
			layer := cumulative
			if count > 1 {
				layer.re -= previous.re
				layer.im -= previous.im
			}
			if count == 1 {origin = layer}
			relative := Unison_Phasor{
				re = layer.re * origin.re + layer.im * origin.im,
				im = layer.im * origin.re - layer.re * origin.im,
				ok = true,
			}
			fmt.printfln("layer %d  %+.6f turns", count - 1, unison_turns(relative))
			previous = cumulative
		}
	}
	fmt.println()
	fmt.println("parameter 85: signed pitch groups")
	for stored in ([]int{12, 36}) {
		p := base
		set_param(&p, 73, 1)
		set_param(&p, 93, 4)
		set_param(&p, 75, 0)
		set_param(&p, 76, 0)
		set_param(&p, 85, stored)
		audio := unison_render(dll, &p, pristine, work, note, 2.0)
		mid := unison_mid(audio)
		peaks, peaks_ok := unison_spectral_peaks(mid[:min(len(mid), g_hold_frames)],
			f64(SAMPLE_RATE), f0, f0 * 1.1, 2, 65536)
		unison_require(peaks_ok, fmt.tprintf("pitch stored %d groups", stored))
		fmt.printfln("stored %v  groups %+.3f / %+.3f semitones", stored,
			12.0 * math.log2(peaks[0] / f0), 12.0 * math.log2(peaks[1] / f0))
		delete(peaks)
		delete(mid)
		delete(audio)
	}

	fmt.println()
	fmt.println("fixture reference-vs-ours comparison")
	for enabled in ([]bool{true, false}) {
		p := base
		set_param(&p, 73, enabled ? 1 : 0)
		set_param(&p, 93, 4)
		set_param(&p, 75, 0)
		set_param(&p, 76, 0)
		set_compare_timing(COMPARE_BLOCK_DEFAULT)
		ref, mismatches, ref_ok := render_reference_fresh(dll, &p, pristine, work, note)
		unison_require(ref_ok && ref != nil && mismatches == 0,
			enabled ? "fixture reference render" : "unison-off reference render")
		ours := render_ours(p, int(note))
		unison_require(ours != nil, enabled ? "fixture engine render" : "unison-off engine render")
		c := compare_renders(ref, ours, 2, f64(SAMPLE_RATE), COMPARE_HOLD_SECONDS)
		fmt.printfln("%-11s level %+.4f dB  null %.4f dB",
			enabled ? "four voices" : "unison off", c.level_db, c.null_db)
		delete(ref)
		delete(ours)
	}
}
