package s1probe

// Measure whether Synth1's FM phase displacement reaches the sub oscillator.
// The full-gain sub is useful here because its measured normalisation lets the
// carrier and sub be separated without treating this engine as the oracle:
//     sub = (5 * (carrier + 4 * sub) / 5 - carrier) / 4
// At -1oct, the phase-displacement slope distinguishes the three live laws.

import "core:fmt"
import "core:math"
import cpatch "../../src/patch"

FMSUB_NOTE :: u8(48)
FMSUB_HOP :: 2048

fmsub_probe_patch :: proc(fm, octave: int, sub_on, ring: bool) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // oscillator 1: sine
	set_param(&p, 1, 1) // oscillator 2: triangle, a visible modulator
	set_param(&p, 2, 40) // oscillator 2: -24 semitones
	set_param(&p, 3, 66) // oscillator 2: 0 cents
	set_param(&p, 4, 1) // oscillator 2 tracks the keyboard
	set_param(&p, 5, 0) // oscillator 1 alone; the sub is oscillator 1's
	set_param(&p, 6, 0) // hard sync off
	set_param(&p, 7, ring ? 1 : 0)
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 100) // fixed gain with headroom
	set_param(&p, 45, fm)
	set_param(&p, 72, 64) // global fine tune centered
	set_param(&p, 95, sub_on ? 127 : 0)
	set_param(&p, 96, 0) // sub: sine
	set_param(&p, 97, octave)
	set_param(&p, 91, 1) // fixed, equal oscillator start phase
	return p
}

fmsub_mid :: proc(audio: []f32) -> []f32 {
	mid, side := split_mid_side(audio, 2)
	delete(side)
	return mid
}

// Recover the analytic phase with a Hilbert transform. The old one-period
// moving average attenuated the sub's modulation twice as much as OSC1's,
// because a sub period is twice as long; that made its slope depend on the
// analyser rather than the reference signal.
fmsub_phase_track :: proc(mid: []f32, hz: f64) -> []f64 {
	if hz <= 0 || len(mid) < 2 {return nil}
	n := 1
	for n << 1 <= len(mid) {n <<= 1}
	re := make([]f64, n)
	im := make([]f64, n)
	defer delete(im)
	for i in 0 ..< n {re[i] = f64(mid[i])}
	fft_forward(re, im)
	for k in 1 ..< n / 2 {
		re[k] *= 2
		im[k] *= 2
	}
	for k in n / 2 + 1 ..< n {
		re[k] = 0
		im[k] = 0
	}
	for i in 0 ..< n {im[i] = -im[i]}
	fft_forward(re, im)
	for i in 0 ..< n {
		re[i] /= f64(n)
		im[i] = -im[i] / f64(n)
	}
	result := make([]f64, n)
	prev := math.atan2(im[0], re[0])
	result[0] = prev
	for i in 1 ..< n {
		cur := math.atan2(im[i], re[i])
		d := cur - prev
		for d > math.PI {d -= 2.0 * math.PI}
		for d < -math.PI {d += 2.0 * math.PI}
		result[i] = result[i - 1] + d
		prev = cur
	}
	delete(re)
	return result
}


Fmsub_Difference :: struct {
	max: f32,
	rms: f64,
}

fmsub_difference :: proc(a, b: []f32) -> (result: Fmsub_Difference) {
	n := min(len(a), len(b))
	if n == 0 {return}
	sum := 0.0
	for i in 0 ..< n {
		d := abs(a[i] - b[i])
		if d > result.max {result.max = d}
		sum += f64(d) * f64(d)
	}
	result.rms = math.sqrt(sum / f64(n))
	return
}

fmsub_law :: proc(slope: f64, points: int) -> string {
	if points == 0 {return "control"}
	if abs(slope - 0.5) < abs(slope) && abs(slope - 0.5) < abs(slope - 1.0) {
		return "fractional"
	}
	if abs(slope - 1.0) < abs(slope) {return "absolute"}
	return "off"
}

fmsub_isolate_sub :: proc(mix, carrier: []f32) -> []f32 {
	result := make([]f32, min(len(mix), len(carrier)))
	for i in 0 ..< len(result) {result[i] = (5.0 * mix[i] - carrier[i]) / 4.0}
	return result
}

fmsub_slope :: proc(
	base_carrier, base_mix, fm_carrier, fm_mix: []f32,
	note: u8,
) -> (slope: f64, points: int) {
	carrier0 := fmsub_mid(base_carrier)
	mix0 := fmsub_mid(base_mix)
	carrier := fmsub_mid(fm_carrier)
	mix := fmsub_mid(fm_mix)
	defer delete(carrier0)
	defer delete(mix0)
	defer delete(carrier)
	defer delete(mix)
	sub0 := fmsub_isolate_sub(mix0, carrier0)
	sub := fmsub_isolate_sub(mix, carrier)
	defer delete(sub0)
	defer delete(sub)

	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	carrier_phase0 := fmsub_phase_track(carrier0, f0)
	carrier_phase := fmsub_phase_track(carrier, f0)
	sub_phase0 := fmsub_phase_track(sub0, f0 / 2.0)
	sub_phase := fmsub_phase_track(sub, f0 / 2.0)
	defer delete(carrier_phase0)
	defer delete(carrier_phase)
	defer delete(sub_phase0)
	defer delete(sub_phase)

	from := int(0.20 * f64(SAMPLE_RATE))
	to := min(int(1.30 * f64(SAMPLE_RATE)), min(len(carrier_phase), len(sub_phase)))
	sum_x, sum_y, sum_xx, sum_xy := 0.0, 0.0, 0.0, 0.0
	for i := from; i < to; i += FMSUB_HOP {
		x := carrier_phase[i] - carrier_phase0[i]
		y := sub_phase[i] - sub_phase0[i]
		if abs(x) < 1.0e-5 {continue}
		sum_x += x
		sum_y += y
		sum_xx += x * x
		sum_xy += x * y
		points += 1
	}
	if points > 1 {
		n := f64(points)
		denominator := sum_xx - sum_x * sum_x / n
		if denominator > 0 {slope = (sum_xy - sum_x * sum_y / n) / denominator}
	}
	return
}

cmd_fmsubprobe :: proc(dll: string, values: []int, note: u8) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.printfln("FM-to-sub probe: oscillator 2 triangle at -24 semitones, note %v", note)
	fmt.println("  oscillator 1 is a sine; the sub is a full-gain sine")
	fmt.println("  -1oct candidates: absolute displacement 1, fractional deviation 0.5, off 0")
	fmt.println()

	zero_base_carrier := fmsub_probe_patch(0, 0, false, false)
	zero_base_mix := fmsub_probe_patch(0, 0, true, false)
	minus_base_carrier := fmsub_probe_patch(0, 1, false, false)
	minus_base_mix := fmsub_probe_patch(0, 1, true, false)
	base_carrier0 := probe_render(dll, &zero_base_carrier, pristine, work, note, 1.5, &dumped, nil)
	base_mix0 := probe_render(dll, &zero_base_mix, pristine, work, note, 1.5, &dumped, nil)
	base_carrier1 := probe_render(dll, &minus_base_carrier, pristine, work, note, 1.5, &dumped, nil)
	base_mix1 := probe_render(dll, &minus_base_mix, pristine, work, note, 1.5, &dumped, nil)
	if base_carrier0 == nil || base_mix0 == nil || base_carrier1 == nil || base_mix1 == nil {
		fmt.eprintln("fmsubprobe: reference render failed")
		return
	}
	defer delete(base_carrier0)
	defer delete(base_mix0)
	defer delete(base_carrier1)
	defer delete(base_mix1)

	fmt.println(" stored   -1oct slope   windows   nearest law   0oct max      0oct RMS")
	for fm in values {
		p0c := fmsub_probe_patch(fm, 0, false, false)
		p0m := fmsub_probe_patch(fm, 0, true, false)
		p1c := fmsub_probe_patch(fm, 1, false, false)
		p1m := fmsub_probe_patch(fm, 1, true, false)
		c0 := probe_render(dll, &p0c, pristine, work, note, 1.5, &dumped, nil)
		m0 := probe_render(dll, &p0m, pristine, work, note, 1.5, &dumped, nil)
		c1 := probe_render(dll, &p1c, pristine, work, note, 1.5, &dumped, nil)
		m1 := probe_render(dll, &p1m, pristine, work, note, 1.5, &dumped, nil)
		if c0 == nil || m0 == nil || c1 == nil || m1 == nil {
			if c0 != nil {delete(c0)}
			if m0 != nil {delete(m0)}
			if c1 != nil {delete(c1)}
			if m1 != nil {delete(m1)}
			continue
		}
		slope, points := fmsub_slope(base_carrier1, base_mix1, c1, m1, note)
		difference := fmsub_difference(c0, m0)
		fmt.printfln(" %6d   %+.6f   %5d   %-10v   %.9f   %.9f",
			fm, slope, points, fmsub_law(slope, points), difference.max, difference.rms)
		delete(c0)
		delete(m0)
		delete(c1)
		delete(m1)
	}

	fmt.println()
	fmt.println(" ring suppression: difference from FM-off, full-gain sub")
	fmt.println(" stored   0oct max      0oct RMS      -1oct max     -1oct RMS")
	for fm in ([]int{43, 77}) {
		row := [2]Fmsub_Difference{}
		for octave in 0 ..< 2 {
			off := fmsub_probe_patch(0, octave, true, true)
			on := fmsub_probe_patch(fm, octave, true, true)
			a := probe_render(dll, &off, pristine, work, note, 1.5, &dumped, nil)
			b := probe_render(dll, &on, pristine, work, note, 1.5, &dumped, nil)
			if a != nil && b != nil {row[octave] = fmsub_difference(a, b)}
			if a != nil {delete(a)}
			if b != nil {delete(b)}
		}
		fmt.printfln(" %6d   %.9f   %.9f   %.9f   %.9f",
			fm, row[0].max, row[0].rms, row[1].max, row[1].rms)
	}
}
