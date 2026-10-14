package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// Fits a.d.1's loop to the reference's harmonics, offline, against the CSV `arch ad1sweep`
// wrote and the linear response `build/ad1_hfull.csv` holds.
//
// The model is the engine's own: a one-pole shelf, then a loop in which a clipper sees the
// drive times the shelf's output less a low-passed copy of its own output plus a bias, then
// whatever linear filtering is left. That last part is not simulated. The steady state of a sine
// through the loop is periodic, so each harmonic of the loop's output is read off a DFT and
// multiplied by the linear response that makes the whole chain's small-signal gain equal the
// reference's measured one: |H_ref(k f0)| over the shelf's and the loop's own small-signal
// gain there. Only the loop and its clipper are left to fit, and they are the part that has
// memory.
//
// `s1probe arch ad1fit [--values shape]`, shape 0 hard clip, 1 tanh, 2 cubic, 3 sine.

AD1_SR :: 48000.0
AD1_HARMONICS :: 16
@(rodata)
AD1_CTL1S := [14]int{0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 96, 112, 127}
AD1_KNOTS :: 14
AD1_SHARED :: 0
AD1_PER_KNOT :: 6
AD1_FLOOR_DB :: -46.0

Ad1_Config :: struct {
	ctl1:  int,
	hz:    f64,
	amp:   f64,
	phase: f64,
	meas:  [AD1_HARMONICS]complex128,
	hfull: [AD1_HARMONICS]complex128,
}

Ad1_Model :: struct {
	loop_gain:   f64,
	feedback_hz: f64,
	feedback2_hz: f64,
	forward_hz:  f64,
	blocker_hz:  f64,
	pre_hp_hz:   f64,
	bias:        f64,
	shelf_gain:  f64,
	shelf_hz:    f64,
	shape:       int,
	drive:       f64,
	asymmetry:   f64,
}

ad1_nl :: proc(v: f64, shape: int, asymmetry := 0.0) -> f64 {
	switch shape {
	case 4:
		t := math.tanh(v)
		return t + asymmetry * t * t
	case 0:
		return clamp(v, -1.0, 1.0)
	case 1:
		return math.tanh(v)
	case 2:
		u := clamp(v, -1.0, 1.0)
		return u - u * u * u / 3.0
	case 3:
		return math.sin(clamp(v, -1.0, 1.0) * math.PI / 2.0)
	}
	return v
}

ad1_note_hz :: proc(note: int) -> f64 {
	return 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
}

ad1_load :: proc() -> (configs: [dynamic]Ad1_Config, ok: bool) {
	sweep, sweep_err := os.read_entire_file("build/ad1sweep_type0.csv", context.allocator)
	hfull_data, hfull_err := os.read_entire_file("build/ad1_hfull.csv", context.allocator)
	if sweep_err != nil || hfull_err != nil {
		fmt.eprintln("ad1fit: build/ad1sweep_type0.csv and build/ad1_hfull.csv are needed")
		return
	}
	defer delete(sweep)
	defer delete(hfull_data)

	hfull: map[[2]int]complex128
	defer delete(hfull)
	for line, i in strings.split_lines(string(hfull_data), context.temp_allocator) {
		if i == 0 || len(line) == 0 {continue}
		cols := strings.split(line, ",", context.temp_allocator)
		note, _ := strconv.parse_int(cols[0])
		k, _ := strconv.parse_int(cols[1])
		re, _ := strconv.parse_f64(cols[2])
		im, _ := strconv.parse_f64(cols[3])
		hfull[{note, k}] = complex(re, im)
	}

	Key :: [3]int
	index: map[Key]int
	defer delete(index)
	for line, i in strings.split_lines(string(sweep), context.temp_allocator) {
		if i == 0 || len(line) == 0 {continue}
		cols := strings.split(line, ",", context.temp_allocator)
		note, _ := strconv.parse_int(cols[0])
		ctl1, _ := strconv.parse_int(cols[1])
		gain, _ := strconv.parse_int(cols[2])
		k, _ := strconv.parse_int(cols[3])
		dry_re, _ := strconv.parse_f64(cols[4])
		dry_im, _ := strconv.parse_f64(cols[5])
		ref_re, _ := strconv.parse_f64(cols[6])
		ref_im, _ := strconv.parse_f64(cols[7])
		if k > AD1_HARMONICS || gain == 16 || gain == 48 || note == 84 {continue}
		key := Key{note, ctl1, gain}
		slot, found := index[key]
		if !found {
			append(&configs, Ad1_Config{ctl1 = ctl1, hz = ad1_note_hz(note), amp = math.sqrt(dry_re * dry_re + dry_im * dry_im), phase = math.atan2(dry_im, dry_re)})
			slot = len(configs) - 1
			index[key] = slot
		}
		configs[slot].meas[k - 1] = complex(ref_re, ref_im)
		configs[slot].hfull[k - 1] = hfull[{note, k}]
	}
	ok = true
	return
}

// The steady-state complex harmonics of the loop's output, in absolute sample time with the
// input a cosine at phase zero, so they compare with the reference's after its own phase is
// divided out.
ad1_simulate :: proc(m: Ad1_Model, c: Ad1_Config) -> (h: [AD1_HARMONICS]complex128, ok: bool) {
	total :: 9600
	skip :: 4800
	w := 2.0 * math.PI * c.hz / AD1_SR
	shelf_c := clamp(2.0 * math.PI * m.shelf_hz / AD1_SR, 0.0, 1.0)
	loop_c := clamp(2.0 * math.PI * m.feedback_hz / AD1_SR, 0.0, 1.0)
	loop2_c := clamp(2.0 * math.PI * m.feedback2_hz / AD1_SR, 0.0, 1.0)
	forward_c := clamp(2.0 * math.PI * m.forward_hz / AD1_SR, 0.0, 1.0)
	blocker_c := clamp(2.0 * math.PI * m.blocker_hz / AD1_SR, 0.0, 1.0)
	pre_hp_c := clamp(2.0 * math.PI * m.pre_hp_hz / AD1_SR, 0.0, 1.0)
	rest := ad1_nl(m.bias, m.shape, m.asymmetry)

	rotation: [AD1_HARMONICS]complex128
	phasor: [AD1_HARMONICS]complex128
	for k in 0 ..< AD1_HARMONICS {
		rotation[k] = complex(math.cos(w * f64(k + 1)), -math.sin(w * f64(k + 1)))
		angle := -w * f64(k + 1) * f64(skip)
		phasor[k] = complex(math.cos(angle), math.sin(angle))
	}
	acc: [AD1_HARMONICS]complex128

	z1, s, s2, u, dc, pre_dc, window_sum: f64
	for n in 0 ..< total {
		x := c.amp * math.cos(w * f64(n))
		z1 += (x - z1) * shelf_c
		y1_raw := m.shelf_gain * x + (1.0 - m.shelf_gain) * z1
		pre_dc += (y1_raw - pre_dc) * pre_hp_c
		y1 := y1_raw - pre_dc
		dc += (s2 - dc) * blocker_c
		u += ((m.drive * y1 - m.loop_gain * (s2 - dc) + m.bias) - u) * forward_c
		y := ad1_nl(u, m.shape, m.asymmetry) - rest
		s += (y - s) * loop_c
		s2 += (s - s2) * loop2_c
		if !(abs(s2) < 1.0e6) {return h, false}
		if n >= skip {
			t := f64(n - skip) / f64(total - skip)
			window := 0.5 - 0.5 * math.cos(2.0 * math.PI * t)
			window_sum += window
			for k in 0 ..< AD1_HARMONICS {
				acc[k] += complex(y * window, 0) * phasor[k]
				phasor[k] *= rotation[k]
			}
		}
	}
	for k in 0 ..< AD1_HARMONICS {
		h[k] = acc[k] * complex(2.0 / window_sum, 0)
	}
	return h, true
}

// shelf * loop at `hz`, small signal, complex.
ad1_small_signal :: proc(m: Ad1_Model, hz: f64) -> complex128 {
	w := 2.0 * math.PI * hz / AD1_SR
	zi := complex(math.cos(w), -math.sin(w))
	shelf_c := clamp(2.0 * math.PI * m.shelf_hz / AD1_SR, 0.0, 1.0)
	loop_c := clamp(2.0 * math.PI * m.feedback_hz / AD1_SR, 0.0, 1.0)
	shelf := complex(m.shelf_gain, 0) + complex(1.0 - m.shelf_gain, 0) * complex(shelf_c, 0) / (1.0 - complex(1.0 - shelf_c, 0) * zi)
	h := 1.0e-4
	slope := (ad1_nl(m.bias + h, m.shape, m.asymmetry) - ad1_nl(m.bias - h, m.shape, m.asymmetry)) / (2.0 * h)
	loop2_c := clamp(2.0 * math.PI * m.feedback2_hz / AD1_SR, 0.0, 1.0)
	forward_c := clamp(2.0 * math.PI * m.forward_hz / AD1_SR, 0.0, 1.0)
	forward := complex(forward_c, 0) / (1.0 - complex(1.0 - forward_c, 0) * zi)
	blocker_c := clamp(2.0 * math.PI * m.blocker_hz / AD1_SR, 0.0, 1.0)
	blocked := (1.0 - zi) / (1.0 - complex(1.0 - blocker_c, 0) * zi)
	feedback := blocked * forward * complex(slope * m.loop_gain * loop_c * loop2_c, 0) * zi / ((1.0 - complex(1.0 - loop_c, 0) * zi) * (1.0 - complex(1.0 - loop2_c, 0) * zi))
	loop := forward * complex(slope * m.drive, 0) / (1.0 + feedback)
	pre_hp_c := clamp(2.0 * math.PI * m.pre_hp_hz / AD1_SR, 0.0, 1.0)
	pre_hp := (1.0 - zi) / (1.0 - complex(1.0 - pre_hp_c, 0) * zi)
	return shelf * pre_hp * loop
}

// Mean squared complex-log error of one ctl1's configurations. The real part is the log of the
// magnitude ratio and has the common scale removed; the imaginary part is the phase difference,
// wrapped, with nothing removed, because the scale is a real number.
// The linear objective is the energy of the complex difference over the harmonics, which is what
// a held-sine null measures, each configuration weighted by its own harmonic energy and one real
// scale per knot solved in closed form. A negative `phase_weight` selects it.
ad1_error_linear :: proc(m: Ad1_Model, configs: []Ad1_Config, ctl1: int) -> (error: f64, scale: f64) {
	numerator, denominator: f64
	count := 0
	models: [dynamic][AD1_HARMONICS]complex128
	targets: [dynamic][AD1_HARMONICS]complex128
	weights: [dynamic]f64
	defer delete(models)
	defer delete(targets)
	defer delete(weights)
	for c in configs {
		if c.ctl1 != ctl1 {continue}
		h, ok := ad1_simulate(m, c)
		if !ok {return 1.0e9, 1}
		model_row, target_row: [AD1_HARMONICS]complex128
		energy := 0.0
		for k in 0 ..< AD1_HARMONICS {
			if abs(c.hfull[k]) == 0 {continue}
			post := c.hfull[k] / ad1_small_signal(m, c.hz * f64(k + 1))
			model_row[k] = h[k] * post
			target_row[k] = c.meas[k] * complex(math.cos(-f64(k + 1) * c.phase), math.sin(-f64(k + 1) * c.phase))
			energy += real(target_row[k]) * real(target_row[k]) + imag(target_row[k]) * imag(target_row[k])
		}
		if energy < 1.0e-18 {continue}
		append(&models, model_row)
		append(&targets, target_row)
		append(&weights, 1.0 / energy)
		for k in 0 ..< AD1_HARMONICS {
			numerator += (1.0 / energy) * real(model_row[k] * complex(real(target_row[k]), -imag(target_row[k])))
			denominator += (1.0 / energy) * (real(model_row[k]) * real(model_row[k]) + imag(model_row[k]) * imag(model_row[k]))
		}
		count += 1
	}
	if count == 0 || denominator <= 0 {return 1.0e9, 1}
	scale = numerator / denominator
	total := 0.0
	for i in 0 ..< len(models) {
		for k in 0 ..< AD1_HARMONICS {
			d := targets[i][k] - complex(scale, 0) * models[i][k]
			total += weights[i] * (real(d) * real(d) + imag(d) * imag(d))
		}
	}
	return total / f64(count), scale
}

ad1_error :: proc(m: Ad1_Model, configs: []Ad1_Config, ctl1: int, phase_weight: f64 = 1.0) -> (error: f64, scale: f64) {
	if phase_weight < 0 {return ad1_error_linear(m, configs, ctl1)}
	reals: [dynamic]f64
	imags: [dynamic]f64
	defer delete(reals)
	defer delete(imags)
	missing := 0
	for c in configs {
		if c.ctl1 != ctl1 {continue}
		h, ok := ad1_simulate(m, c)
		if !ok {return 1.0e9, 1}
		reference_first := abs(c.meas[0])
		for k in 0 ..< AD1_HARMONICS {
			if abs(c.hfull[k]) == 0 {continue}
			if k > 0 && abs(c.meas[k]) < reference_first * math.pow(10.0, AD1_FLOOR_DB / 20.0) {continue}
			post := c.hfull[k] / complex(1, 0) / ad1_small_signal(m, c.hz * f64(k + 1))
			model := h[k] * post
			measured := c.meas[k] * complex(math.cos(-f64(k + 1) * c.phase), math.sin(-f64(k + 1) * c.phase))
			if abs(model) < 1.0e-9 || abs(measured) < 1.0e-9 {
				missing += 1
				continue
			}
			ratio := measured / model
			append(&reals, math.ln(abs(ratio)))
			append(&imags, math.atan2(imag(ratio), real(ratio)))
		}
	}
	if len(reals) == 0 {return 1.0e9, 1}
	mean := 0.0
	for e in reals {mean += e}
	mean /= f64(len(reals))
	sum := 0.0
	for i in 0 ..< len(reals) {
		sum += (reals[i] - mean) * (reals[i] - mean) + phase_weight * imags[i] * imags[i]
	}
	count := len(reals) + missing
	return (sum + 100.0 * f64(missing)) / f64(count), math.exp(mean)
}

AD1_PHASE_WEIGHT := 0.5

Ad1_Vector :: [AD1_SHARED + AD1_PER_KNOT * AD1_KNOTS]f64

ad1_model_from :: proc(q: Ad1_Vector, shape: int, knot: int) -> Ad1_Model {
	base := AD1_SHARED + AD1_PER_KNOT * knot
	return Ad1_Model {
		feedback_hz = math.exp(q[base + 3]),
		feedback2_hz = 30000.0,
		forward_hz = 30000.0,
		blocker_hz = 0.001,
		pre_hp_hz = 0.001,
		shelf_gain = math.exp(q[base + 4]),
		shelf_hz = math.exp(q[base + 5]),
		drive = math.exp(q[base]),
		loop_gain = math.exp(q[base + 1]),
		bias = q[base + 2],
		shape = shape,
	}
}

ad1_total :: proc(q: Ad1_Vector, shape: int, configs: []Ad1_Config) -> f64 {
	total := 0.0
	for i in 0 ..< AD1_KNOTS {
		e, _ := ad1_error(ad1_model_from(q, shape, i), configs, AD1_CTL1S[i], AD1_PHASE_WEIGHT)
		total += e
	}
	return total / f64(AD1_KNOTS)
}

// `s1probe arch ad1fit --values shape[,iterations[,start_loop_gain_x100]]`: per-knot drive, loop gain
// and bias, with the feedback corner and the shelf shared.
cmd_arch_ad1fit :: proc(o: ^Arch_Options) {
	shape := len(o.values) > 0 ? o.values[0] : 1
	iterations := len(o.values) > 1 ? o.values[1] : 50
	start_lg := 3.82
	if len(o.values) > 3 && o.values[3] == 1 {AD1_PHASE_WEIGHT = -1.0}
	all_configs, ok := ad1_load()
	if !ok {return}
	defer delete(all_configs)

	configs: [dynamic]Ad1_Config
	defer delete(configs)
	for c in all_configs {
		append(&configs, c)
	}

	fmt.printfln("ad1fit: %v configurations, shape %v, per-knot loop gain and bias", len(configs), shape)
	q: Ad1_Vector
	drives_low := [AD1_KNOTS]f64{0.8881, 1.3932, 2.2771, 3.9536, 6.842, 10.8545, 18.6238, 28.8453, 55.8665, 117.0476, 213.4299, 887.4434, 1791.8025, 3209.0119}
	gains_low := [AD1_KNOTS]f64{2.5838, 3.3037, 3.4621, 4.0617, 4.7804, 4.5979, 4.9321, 4.4621, 5.3664, 6.8935, 7.6813, 10.5, 10.5, 10.5}
	rests_low := [AD1_KNOTS]f64{0.8621, 0.8993, 0.8554, 0.8473, 0.868, 0.8337, 0.7987, 0.8361, 0.8403, 0.8646, 0.8878, 1.0619, 0.8523, 0.7543}
	drives_lin := [AD1_KNOTS]f64{0.6739, 1.0607, 1.9322, 3.6048, 6.4878, 11.3776, 19.0219, 32.4531, 57.7338, 94.777, 163.7123, 519.6903, 2484.9292, 6815.9894}
	gains_lin := [AD1_KNOTS]f64{5.6263, 5.618, 4.5636, 4.7344, 5.5989, 6.3734, 6.404, 6.5684, 7.0335, 7.0026, 7.3677, 7.8674, 11.3146, 9.8803}
	rests_lin := [AD1_KNOTS]f64{0.9567, 0.9665, 0.7872, 0.7014, 0.7026, 0.6964, 0.6787, 0.666, 0.6795, 0.6591, 0.6691, 0.7111, 0.9723, 0.8743}
	for d in 0 ..< AD1_KNOTS {
		base := AD1_SHARED + AD1_PER_KNOT * d
		if d <= 5 {
			q[base] = math.ln(drives_low[d])
			q[base + 1] = math.ln(gains_low[d])
			q[base + 2] = rests_low[d]
			q[base + 3] = math.ln(118.44)
			q[base + 4] = math.ln(1.1305)
			q[base + 5] = math.ln(224.7)
		} else {
			q[base] = math.ln(drives_lin[d])
			q[base + 1] = math.ln(gains_lin[d])
			q[base + 2] = rests_lin[d]
			q[base + 3] = math.ln(77.11)
			q[base + 4] = math.ln(1.0411)
			q[base + 5] = math.ln(520.4)
		}
	}
	_ = start_lg

	steps: Ad1_Vector
	for i in 0 ..< len(q) {steps[i] = 0.12}
	current := ad1_total(q, shape, configs[:])
	fmt.printfln("  start: rms %.3f", math.sqrt(current))
	for it in 0 ..< iterations {
		improved := false
		for i in 0 ..< len(q) {
			for sign in ([2]f64{1, -1}) {
				trial := q
				trial[i] += sign * steps[i]
				e := ad1_total(trial, shape, configs[:])
				if e < current {
					current = e
					q = trial
					improved = true
				}
			}
		}
		if !improved {
			for i in 0 ..< len(q) {steps[i] *= 0.6}
			if steps[0] < 0.003 {break}
		}
		if it % 5 == 4 {fmt.printfln("  iteration %v: rms %.3f", it + 1, math.sqrt(current))}
	}
	fmt.printfln("best: rms complex-log error %.3f", math.sqrt(current))
	for i in 0 ..< AD1_KNOTS {
		m := ad1_model_from(q, shape, i)
		e, scale := ad1_error(m, configs[:], AD1_CTL1S[i], AD1_PHASE_WEIGHT)
		magnitude_only, _ := ad1_error(m, configs[:], AD1_CTL1S[i], 0.0)
		fmt.printfln("  ctl1 %3v: drive %.4f  loop gain %.4f  bias %.4f  scale %.4f  gain %.5f  feedback %.2f  shelf gain %.4f  shelf corner %.1f  err %.3f  (magnitude alone %.3f = %.1f dB)", AD1_CTL1S[i], m.drive, m.loop_gain, m.bias, scale, scale / m.drive, m.feedback_hz, m.shelf_gain, m.shelf_hz, math.sqrt(e), math.sqrt(magnitude_only), math.sqrt(magnitude_only) * 8.686)
	}
}
