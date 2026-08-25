// Matched reference/engine factorial for the sub oscillator and filter saturation.
//
// This probe keeps the two laws under test separate from the corpus comparator:
// every cell is a fresh reference instance, both sides use the same patch and
// timing, and signed residuals are calculated from measured amplitudes rather
// than from an engine-side prediction.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import cpatch "../../src/patch"
import sdsp "../../src/dsp"

SUBSTAGE_SECONDS :: 1.5
SUBSTAGE_FROM_SECONDS :: 0.10
SUBSTAGE_TO_SECONDS :: 1.45
SUBSTAGE_P95_DEFAULT :: "0,16,32,48,64,80,96,112,127"
// Ordinary signed observables must stand at least 100 dB above each render's
// peak-relative floor. The dedicated leakage check intentionally reads lower.
SUBSTAGE_RELATIVE_FLOOR :: 1.0e-5

Substage_Metrics :: struct {
	carrier: f64,
	sub: f64,
	osc2: f64,
	thd: f64,
	rms: f64,
	peak: f64,
	finite: int,
	ok: bool,
}

Substage_Row :: struct {
	note: int,
	p95: int,	mix: int,	saturation: int,	gain: int,
	endpoint: bool,
	ref: Substage_Metrics,
	ours: Substage_Metrics,
	mismatches: int,
	ok: bool,
	level_carrier: f64,
	level_sub: f64,
	level_osc2: f64,
	level_rms: f64,
	level_peak: f64,
	ratio_sub: f64,
	carrier_norm: f64,
	level_carrier_ok: bool,
	level_sub_ok: bool,
	level_osc2_ok: bool,
	level_rms_ok: bool,
	level_peak_ok: bool,
	ratio_sub_ok: bool,
	carrier_norm_ok: bool,
}

Substage_Leakage :: struct {
	ref_f0: f64,	ref_sub: f64,
	ours_f0: f64,	ours_sub: f64,
	ok: bool,
}

Substage_Leakage_Request :: struct {
	note: int,
	gain: int,
}

Substage_Endpoint :: struct {
	ref_osc2: f64,
	ours_osc2: f64,
	ref_rms: f64,
	ours_rms: f64,
	ok: bool,
}

substage_clamp :: proc(v: int) -> int {return clamp(v, 0, 127)}

// The patch is deliberately explicit at every stage named by the experiment.
// Values not listed here stay at neutral_probe_patch's measured-safe defaults.
substage_patch :: proc(p95, mix, saturation, gain: int) -> cpatch.Patch {
    p := neutral_probe_patch()
    set_param(&p, 0, 0) // OSC1 sine
    set_param(&p, 1, 3) // OSC2 triangle
    set_param(&p, 2, 68) // OSC2 +4 semitones
	set_param(&p, 3, 66) // OSC2 fine tune centered
	set_param(&p, 4, 1) // OSC2 keyboard tracking
	set_param(&p, 5, substage_clamp(mix))
	set_param(&p, 6, 0)
	set_param(&p, 7, 0)
	set_param(&p, 8, 64) // pulse width centered
	set_param(&p, 14, 0) // LP12
	set_param(&p, 19, 127) // filter cutoff open
	set_param(&p, 20, 0) // resonance off
	set_param(&p, 21, 63) // filter envelope amount zero
	set_param(&p, 22, 0) // filter keyboard tracking off
	set_param(&p, 23, substage_clamp(saturation))
	set_param(&p, 24, 0)
	set_param(&p, 25, 0)
	set_param(&p, 26, 0)
	set_param(&p, 27, 127)
	set_param(&p, 28, 0)
	set_param(&p, 29, substage_clamp(gain))
	set_param(&p, 30, 0)
	set_param(&p, 37, 0)
	set_param(&p, 44, 0)
	set_param(&p, 45, 0)
	set_param(&p, 49, 0)
	set_param(&p, 57, 0)
	set_param(&p, 58, 0)
	set_param(&p, 59, 0)
	set_param(&p, 60, 64) // EQ tone flat
	set_param(&p, 61, 64) // EQ frequency centered
	set_param(&p, 62, 64) // EQ level centered
	set_param(&p, 63, 64) // EQ Q centered
	set_param(&p, 66, 0)
	set_param(&p, 73, 0)
	set_param(&p, 76, 0) // one OSC1 component
	set_param(&p, 77, 0)
	set_param(&p, 91, 1) // fixed phase
	set_param(&p, 95, substage_clamp(p95))
	set_param(&p, 96, 0) // sub sine
	set_param(&p, 97, 1) // sub -1 octave
	return p
}

substage_frequency :: proc(note: int) -> (f0, f2: f64) {
	f0 = f64(sdsp.note_to_hz(f32(note)))
    f2 = f0 * math.pow(f64(2.0), f64(4.0 / 12.0))
	return
}

substage_window :: proc(n: int) -> (from, to: int) {
	from = min(int(SUBSTAGE_FROM_SECONDS * f64(SAMPLE_RATE)), n / 4)
	to = min(int(SUBSTAGE_TO_SECONDS * f64(SAMPLE_RATE)), n)
	return
}

substage_amplitude :: proc(mid: []f32, f0: f64, from, to: int) -> f64 {
	if f0 <= 0 || to <= from {return 0}
	n := f64(to - from)
	re, im := 0.0, 0.0
	for i := from; i < to; i += 1 {
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i - from) / n)
		a := 2.0 * math.PI * f0 * f64(i) / f64(SAMPLE_RATE)
		re += f64(mid[i]) * w * math.cos(a)
		im -= f64(mid[i]) * w * math.sin(a)
	}
	return 4.0 * math.sqrt(re * re + im * im) / n
}

substage_thd :: proc(mid: []f32, f0: f64, from, to: int) -> (f64, bool) {
	power := welch_power(mid, from, to)
	if power == nil {return 0, false}
	defer delete(power)
	r := harmonic_report(power, f64(SAMPLE_RATE) / f64(FFT_SIZE), f0)
	if r.fundamental <= 0 {return 0, false}
	return r.thd_db, true
}

substage_measure :: proc(audio: []f32, note: int) -> Substage_Metrics {
	result: Substage_Metrics
	result.finite = non_finite_count(audio)
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	from, to := substage_window(len(mid))
	if to <= from {return result}
	f0, f2 := substage_frequency(note)
	result.carrier = substage_amplitude(mid, f0, from, to)
	result.sub = substage_amplitude(mid, f0 / 2.0, from, to)
	result.osc2 = substage_amplitude(mid, f2, from, to)
	thd, thd_ok := substage_thd(mid, f0, from, to)
    result.thd = thd
    result.rms = signal_rms(mid[from:to])
    result.peak = signal_peak(mid[from:to])
    result.ok = thd_ok && result.finite == 0 && result.peak < 0.8
    return result
}

substage_measurable :: proc(amplitude, signal_peak: f64) -> bool {
	return signal_peak > 1.0e-12 && amplitude > signal_peak * SUBSTAGE_RELATIVE_FLOOR
}

substage_db_error :: proc(
	ours, reference: f64,
	ours_signal := 1.0,
	reference_signal := 1.0,
) -> (f64, bool) {
	if !substage_measurable(ours, ours_signal) || !substage_measurable(reference, reference_signal) {
		return 0, false
	}
	return 20.0 * math.log10(ours / reference), true
}

substage_ratio_error :: proc(
	ours_num, ours_den, ref_num, ref_den: f64,
	ours_num_signal := 1.0,
	ours_den_signal := 1.0,
	ref_num_signal := 1.0,
	ref_den_signal := 1.0,
) -> (f64, bool) {
	if !substage_measurable(ours_num, ours_num_signal) ||
		!substage_measurable(ours_den, ours_den_signal) ||
		!substage_measurable(ref_num, ref_num_signal) ||
		!substage_measurable(ref_den, ref_den_signal) {
		return 0, false
	}
	return 20.0 * math.log10((ours_num / ours_den) / (ref_num / ref_den)), true
}

substage_cells :: proc(notes, p95s, mixes, saturations: []int, gain: int) -> []Substage_Row {
	rows: [dynamic]Substage_Row
	for note in notes {
		for p95 in p95s {
			for mix in mixes {
				for saturation in saturations {
					append(&rows, Substage_Row{note=note, p95=p95, mix=mix, saturation=saturation, gain=gain})
				}
			}
		}
		// The p5=127 endpoint is a separate control, not part of the factorial.
		append(&rows, Substage_Row{note=note, p95=0, mix=127, saturation=0, gain=gain, endpoint=true})
		append(&rows, Substage_Row{note=note, p95=96, mix=127, saturation=0, gain=gain, endpoint=true})
	}
	return rows[:]
}

substage_find :: proc(rows: []Substage_Row, note, p95, mix, saturation, gain: int) -> int {
    for row, i in rows {
		if row.note == note && row.p95 == p95 && row.mix == mix && row.saturation == saturation && row.gain == gain {
			return i
		}
	}
	return -1
}

substage_interaction :: proc(
	rows: []Substage_Row,
	note, p95, mix, saturation_off, saturation_on, gain: int,
) -> (carrier, ratio: f64, ok: bool) {
	r0 := substage_find(rows, note, p95, mix, saturation_off, gain)
	r1 := substage_find(rows, note, p95, mix, saturation_on, gain)
	o0 := substage_find(rows, note, 0, mix, saturation_off, gain)
	o1 := substage_find(rows, note, 0, mix, saturation_on, gain)
	if r0 < 0 || r1 < 0 || o0 < 0 || o1 < 0 {return}
	if !rows[r0].ok || !rows[r1].ok || !rows[o0].ok || !rows[o1].ok ||
		!rows[r0].level_carrier_ok || !rows[r1].level_carrier_ok ||
		!rows[o0].level_carrier_ok || !rows[o1].level_carrier_ok ||
		!rows[r0].ratio_sub_ok || !rows[r1].ratio_sub_ok {
		return
	}
	carrier = (rows[r1].level_carrier - rows[o1].level_carrier) -
		(rows[r0].level_carrier - rows[o0].level_carrier)
	ratio = rows[r1].ratio_sub - rows[r0].ratio_sub
	ok = true
	return
}

substage_endpoint :: proc(
	rows: []Substage_Row,
	note, p95_off, p95_on, mix, saturation, gain: int,
) -> (result: Substage_Endpoint) {
	off := substage_find(rows, note, p95_off, mix, saturation, gain)
	on := substage_find(rows, note, p95_on, mix, saturation, gain)
	if off < 0 || on < 0 || !rows[off].ok || !rows[on].ok {return}
	ref_osc2_ok, ours_osc2_ok, ref_rms_ok, ours_rms_ok: bool
	result.ref_osc2, ref_osc2_ok = substage_db_error(
		rows[on].ref.osc2, rows[off].ref.osc2, rows[on].ref.peak, rows[off].ref.peak,
	)
	result.ours_osc2, ours_osc2_ok = substage_db_error(
		rows[on].ours.osc2, rows[off].ours.osc2, rows[on].ours.peak, rows[off].ours.peak,
	)
	result.ref_rms, ref_rms_ok = substage_db_error(
		rows[on].ref.rms, rows[off].ref.rms, rows[on].ref.peak, rows[off].ref.peak,
	)
	result.ours_rms, ours_rms_ok = substage_db_error(
		rows[on].ours.rms, rows[off].ours.rms, rows[on].ours.peak, rows[off].ours.peak,
	)
	result.ok = ref_osc2_ok && ours_osc2_ok && ref_rms_ok && ours_rms_ok
	return
}

substage_fill_errors :: proc(rows: []Substage_Row) {
	for i in 0 ..< len(rows) {
		r := &rows[i]
		if !r.ok {continue}
		r.level_carrier, r.level_carrier_ok = substage_db_error(r.ours.carrier, r.ref.carrier, r.ours.peak, r.ref.peak)
		r.level_sub, r.level_sub_ok = substage_db_error(r.ours.sub, r.ref.sub, r.ours.peak, r.ref.peak)
		r.level_osc2, r.level_osc2_ok = substage_db_error(r.ours.osc2, r.ref.osc2, r.ours.peak, r.ref.peak)
		r.level_rms, r.level_rms_ok = substage_db_error(r.ours.rms, r.ref.rms, r.ours.peak, r.ref.peak)
		r.level_peak, r.level_peak_ok = substage_db_error(r.ours.peak, r.ref.peak, r.ours.peak, r.ref.peak)
		if r.p95 > 0 {
			r.ratio_sub, r.ratio_sub_ok = substage_ratio_error(
				r.ours.sub, r.ours.carrier, r.ref.sub, r.ref.carrier,
				r.ours.peak, r.ours.peak, r.ref.peak, r.ref.peak,
			)
		}
	}
    for i in 0 ..< len(rows) {
        r := &rows[i]
        if r.p95 == 0 || r.endpoint {continue}
        off := substage_find(rows, r.note, 0, r.mix, r.saturation, r.gain)
		if off >= 0 && r.ok && rows[off].ok {
			r.carrier_norm, r.carrier_norm_ok = substage_ratio_error(
				r.ours.carrier, rows[off].ours.carrier, r.ref.carrier, rows[off].ref.carrier,
				r.ours.peak, rows[off].ours.peak, r.ref.peak, rows[off].ref.peak,
			)
		}
    }
}

substage_leakage_requests :: proc(notes: []int, gain: int) -> []Substage_Leakage_Request {
	requests: [dynamic]Substage_Leakage_Request
	for note in notes {
		append(&requests, Substage_Leakage_Request{note=note, gain=gain})
	}
	return requests[:]
}

substage_leakage_patch :: proc(gain: int) -> cpatch.Patch {
	// OSC2 has no sine state in this plugin. Triangle's intended harmonics do
	// not land at f0 or f0/2, so these bins test isolation leakage.
	p := substage_patch(0, 127, 0, gain)
	set_param(&p, 1, 3)
	return p
}

substage_leakage :: proc(dll: string, pristine, work: []byte, note, gain: int) -> (result: Substage_Leakage) {
	p := substage_leakage_patch(gain)
	ref_audio, mismatches, ref_ok := render_reference_fresh(dll, &p, pristine, work, u8(note))
	if !ref_ok {return}
	defer delete(ref_audio)
	our_audio := render_ours(p, note)
	defer delete(our_audio)
	ref := substage_measure(ref_audio, note)
	ours := substage_measure(our_audio, note)
	if mismatches != 0 || ref.finite != 0 || ours.finite != 0 ||
		!substage_measurable(ref.osc2, ref.peak) || !substage_measurable(ours.osc2, ours.peak) ||
		ref.peak >= 0.8 || ours.peak >= 0.8 {
		return
	}
	// Leakage intentionally reads below the ordinary peak-relative floor, but
	// only relative to the isolated, audible OSC2 fundamental checked above.
	result.ref_f0 = amplitude_db(ref.carrier / ref.osc2)
	result.ref_sub = amplitude_db(ref.sub / ref.osc2)
	result.ours_f0 = amplitude_db(ours.carrier / ours.osc2)
	result.ours_sub = amplitude_db(ours.sub / ours.osc2)
	result.ok = true
	return
}

SUBSTAGE_CSV_HEADER :: "note,p95,mix,saturation,gain,endpoint,ref_carrier,our_carrier,ref_sub,our_sub,ref_osc2,our_osc2,ref_thd,our_thd,ref_rms,our_rms,ref_peak,our_peak,mismatches,ref_nonfinite,our_nonfinite,E_carrier,E_sub,E_osc2,E_thd,E_rms,E_peak,R_sub,C_carrier,E_carrier_valid,E_sub_valid,E_osc2_valid,E_rms_valid,E_peak_valid,R_sub_valid,C_carrier_valid,row_ok\n"

substage_csv_text :: proc(rows: []Substage_Row) -> string {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_string(&b, SUBSTAGE_CSV_HEADER)
    for r in rows {
		fmt.sbprintf(&b, "%v,%v,%v,%v,%v,%v,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.6f,%.6f,%.9f,%.9f,%.9f,%.9f,%v,%v,%v,%+.6f,%+.6f,%+.6f,%+.6f,%+.6f,%+.6f,%+.6f,%+.6f,%v,%v,%v,%v,%v,%v,%v,%v\n",
			r.note, r.p95, r.mix, r.saturation, r.gain, r.endpoint,
			r.ref.carrier, r.ours.carrier, r.ref.sub, r.ours.sub, r.ref.osc2, r.ours.osc2,
			r.ref.thd, r.ours.thd, r.ref.rms, r.ours.rms, r.ref.peak, r.ours.peak,
			r.mismatches, r.ref.finite, r.ours.finite, r.level_carrier, r.level_sub,
			r.level_osc2, r.ours.thd - r.ref.thd, r.level_rms, r.level_peak, r.ratio_sub, r.carrier_norm,
			r.level_carrier_ok, r.level_sub_ok, r.level_osc2_ok, r.level_rms_ok, r.level_peak_ok,
			r.ratio_sub_ok, r.carrier_norm_ok, r.ok)
    }
    return strings.clone(strings.to_string(b))
}

substage_write_csv :: proc(path: string, rows: []Substage_Row) -> bool {
    text := substage_csv_text(rows)
    defer delete(text)
    return os.write_entire_file(path, transmute([]u8)text) == nil
}

substage_db_text :: proc(value: f64, ok: bool) -> string {
	return ok ? fmt.tprintf("%+.4f", value) : "-"
}

cmd_substageprobe :: proc(dll, csv_path: string, notes, p95s, mixes, saturations: []int, gain: int) {
	if len(notes) == 0 || len(p95s) == 0 || len(mixes) == 0 || len(saturations) == 0 {
		fmt.eprintln("substageprobe: each sweep must have at least one value")
		os.exit(1)
	}
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	rows := substage_cells(notes, p95s, mixes, saturations, gain)
	defer delete(rows)
	fmt.printfln("substageprobe: %v cells, notes %v, gain %v", len(rows), notes, gain)
	fmt.println("  signed E = 20 log10(ours/reference); positive means ours is high")
	for i := 0; i < len(rows); i += 1 {
		r := &rows[i]
		p := substage_patch(r.p95, r.mix, r.saturation, r.gain)
		ref_audio, mismatches, ref_ok := render_reference_fresh(dll, &p, pristine, work, u8(r.note))
		if ref_ok {
			r.ref = substage_measure(ref_audio, r.note)
			delete(ref_audio)
		}
		ours_audio := render_ours(p, r.note)
		r.ours = substage_measure(ours_audio, r.note)
		delete(ours_audio)
		r.mismatches = mismatches
		r.ok = ref_ok && r.ref.ok && r.ours.ok && mismatches == 0
	}
	substage_fill_errors(rows[:])
	for r in rows {
		fmt.printfln(" note %v p95 %v mix %v sat %v%s  Ecarrier %8v  Esub %8v  Eosc2 %8v  R %8v  C %8v  THD ref/ours %+.3f/%+.3f  peak %.4f/%.4f  %s",
			r.note, r.p95, r.mix, r.saturation, r.endpoint ? " endpoint" : "",
			substage_db_text(r.level_carrier, r.level_carrier_ok),
			substage_db_text(r.level_sub, r.level_sub_ok),
			substage_db_text(r.level_osc2, r.level_osc2_ok),
			substage_db_text(r.ratio_sub, r.ratio_sub_ok),
			substage_db_text(r.carrier_norm, r.carrier_norm_ok),
			r.ref.thd, r.ours.thd, r.ref.peak, r.ours.peak, r.ok ? "ok" : "INVALID")
	}

	// Named, signed controls. These are printed from matched cells, not fitted
	// to the corpus, and are the only values that can open an engine mutation.
	fmt.println()
	max_carrier_interaction, max_ratio_interaction := 0.0, 0.0
	valid_interactions := 0
	for note in notes {
		for saturation in saturations {
			if saturation == 0 {continue}
			for p95 in p95s {
				if p95 == 0 {continue}
				for mix in mixes {
					ix, ir, interaction_ok := substage_interaction(rows[:], note, p95, mix, 0, saturation, gain)
					if !interaction_ok {
						fmt.printfln(" interaction note %v p95 %v mix %v sat 0->%v: INVALID", note, p95, mix, saturation)
						continue
					}
					max_carrier_interaction = max(max_carrier_interaction, abs(ix))
					max_ratio_interaction = max(max_ratio_interaction, abs(ir))
					valid_interactions += 1
					fmt.printfln(" interaction note %v p95 %v mix %v sat 0->%v: I_carrier %+.6f dB, I_R %+.6f dB",
						note, p95, mix, saturation, ix, ir)
				}
			}
		}
	}
	fmt.printfln(" interaction curve: %v valid cells, max |I_carrier| %.6f dB, max |I_R| %.6f dB",
		valid_interactions, max_carrier_interaction, max_ratio_interaction)
	for note in notes {
		endpoint := substage_endpoint(rows[:], note, 0, 96, 127, 0, gain)
		if endpoint.ok {
			fmt.printfln(" endpoint note %v: osc2 ref/ours on-minus-off %+.6f/%+.6f dB, rms %+.6f/%+.6f dB", note,
				endpoint.ref_osc2, endpoint.ours_osc2, endpoint.ref_rms, endpoint.ours_rms)
		} else {
			fmt.printfln(" endpoint note %v: INVALID", note)
		}
	}
	for note in notes {
		for saturation in saturations {
			if saturation == 0 {continue}
			z0 := substage_find(rows[:], note, 0, 0, 0, gain)
			z1 := substage_find(rows[:], note, 0, 0, saturation, gain)
			if z0 >= 0 && z1 >= 0 && rows[z0].ok && rows[z1].ok {
				fmt.printfln(" saturation note %v p95 0 mix 0 sat 0->%v: ref THD movement %+.6f dB, ours %+.6f dB",
					note, saturation, rows[z1].ref.thd - rows[z0].ref.thd, rows[z1].ours.thd - rows[z0].ours.thd)
			}
		}
	}
	leakage_requests := substage_leakage_requests(notes, gain)
	defer delete(leakage_requests)
	for request in leakage_requests {
		leak := substage_leakage(dll, pristine, work, request.note, request.gain)
		if leak.ok {
			fmt.printfln(" leakage note %v gain %v: ref f0/f2 %+.3f dB, ref sub/f2 %+.3f dB, ours f0/f2 %+.3f dB, ours sub/f2 %+.3f dB",
				request.note, request.gain, leak.ref_f0, leak.ref_sub, leak.ours_f0, leak.ours_sub)
		} else {
			fmt.printfln(" leakage note %v gain %v: INVALID", request.note, request.gain)
		}
	}
	if csv_path != "" {
		if substage_write_csv(csv_path, rows[:]) {fmt.printfln("wrote %v", csv_path)}
		else {fmt.eprintfln("substageprobe: could not write %v", csv_path)}
	}
}
