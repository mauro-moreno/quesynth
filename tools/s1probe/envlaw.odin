package s1probe

// s1probe arch envlaw - the amplitude envelope's length and curve laws, read
// out of the audio and set against the existing envelope_table.odin.
//
//   attack      0.0005 * 56000^(v/127) seconds
//   decay       0.01 * 6000^(v/127) seconds, level exp(-8u) * (1 - u), u = t/length
//   release     the same length and curve, from the level the note-off found
//
// Method. The reference's amplitude envelope is not read per sample. It is a
// whole number of 1/2048ths, recomputed every 256 samples ("a tick") and
// ramped linearly between ticks. Dividing a render by a flat render of the same
// note (attack 0, sustain 127) removes the oscillator and the filter, leaving
// that envelope; a line fitted inside each tick gives the integer at the tick's
// two ends, and the integers are compared with floor(2048 * law) exactly rather
// than fitted. A free-parameter fit cannot tell a curve from its neighbour at
// this level of detail: with the end of the fade left free, a fit settles on
// 0.94 of the length and looks as good as the law it is approximating.
//
// `--what knots` lists every knot read and the law's value for it.
//
// The attack is read against the steady sine the same render settles into,
// because its own control has an attack. Nothing here assumes what the engine
// does: both engines are read the same way.
import "core:fmt"
import "core:math"

import sengine "../../src/engine"
import cpatch "../../src/patch"

ENVLAW_TICK :: 256
ENVLAW_FULL :: 2048.0
ENVLAW_K :: 8.0
// A zero attack still lasts 0.0005 * 56000^0 seconds, and the decay starts when
// it ends.
ENVLAW_ATTACK0_SAMPLES :: 24
// Where 2048 * exp(-8u) * (1 - u) drops under one whole number.
ENVLAW_FIRST_ZERO_U :: 0.7714
ENVLAW_NOTE :: 84
// Largest gap, in 1/2048ths, two lines may leave at a knot and still agree.
ENVLAW_AGREE :: 0.1

envlaw_attack_seconds :: proc(v: int) -> f64 {
	return 0.0005 * math.pow(f64(56000), f64(v) / 127)
}

envlaw_length_seconds :: proc(v: int) -> f64 {
	return 0.01 * math.pow(f64(6000), f64(v) / 127)
}

// exp(-k u) * (1 - u) for u in [0, 1); 1 before the segment, 0 after it.
envlaw_fade :: proc(u, k: f64) -> f64 {
	return envlaw_fade_to(u, k, 1)
}

// The same with the fade reaching zero at u = end.
envlaw_fade_to :: proc(u, k, end: f64) -> f64 {
	if u <= 0 {return 1}
	if u >= end {return 0}
	return math.exp(-k * u) * (1 - u / end)
}

envlaw_patch :: proc(segment: Env_Segment, stored: int) -> cpatch.Patch {
	p := arch_sine_patch()
	switch segment {
	case .Attack:
		set_param(&p, 25, stored)
		set_param(&p, 26, 0)
		set_param(&p, 27, 127)
		set_param(&p, 28, 0)
	case .Decay:
		set_param(&p, 25, 0)
		set_param(&p, 26, stored)
		set_param(&p, 27, 0)
		set_param(&p, 28, 0)
	case .Release:
		set_param(&p, 25, 0)
		set_param(&p, 26, 0)
		set_param(&p, 27, 127)
		set_param(&p, 28, stored)
	}
	return p
}

// ------------------------------------------------------------------ knots

// The envelope at the ends of every 256-sample tick of x from `start`, in
// 1/2048ths (full level 2048), NaN where a tick has too few readable samples.
// `c` is the flat control; only samples where it is at least a fifth of its
// peak are used, so a division never sits near a zero crossing.
envlaw_knots :: proc(x, c: []f32, start, count: int) -> []f64 {
	gate := 0.2 * signal_peak(c)
	first := make([]f64, count)
	last := make([]f64, count)
	defer delete(first)
	defer delete(last)
	for q in 0 ..< count {
		first[q] = math.nan_f64()
		last[q] = math.nan_f64()
		from := start + q * ENVLAW_TICK
		to := min(from + ENVLAW_TICK, min(len(x), len(c)))
		if from >= to {continue}
		xs, ys: [dynamic]f64
		defer delete(xs)
		defer delete(ys)
		for n in from ..< to {
			if abs(f64(c[n])) < gate {continue}
			append(&xs, f64(n - from) / ENVLAW_TICK)
			append(&ys, f64(x[n]) / f64(c[n]))
		}
		if len(xs) < 8 {continue}
		slope, intercept, _ := arch_fit_line(xs[:], ys[:])
		first[q] = intercept
		last[q] = intercept + slope
	}
	knots := make([]f64, count + 1)
	for k in 0 ..= count {
		have_next := k < count && !math.is_nan(first[k])
		have_prev := k >= 1 && !math.is_nan(last[k - 1])
		switch {
		case have_next && have_prev:
			// Two lines that disagree about a knot are not both straight up to
			// it: a bend lies inside one of the ticks. A knot is read only where
			// they agree to within a tenth of a step.
			if abs(first[k] - last[k - 1]) * ENVLAW_FULL > ENVLAW_AGREE {
				knots[k] = math.nan_f64()
			} else {
				knots[k] = ENVLAW_FULL * 0.5 * (first[k] + last[k - 1])
			}
		case have_next: knots[k] = ENVLAW_FULL * first[k]
		case have_prev: knots[k] = ENVLAW_FULL * last[k - 1]
		case: knots[k] = math.nan_f64()
		}
	}
	return knots
}

// ------------------------------------------------------------------ law

// One falling segment as a prediction of the knots. Knot j sits at sample
// 256 j from the first knot; `base` is where u = 0 falls, in the same samples.
Envlaw_Segment :: struct {
	base:   f64,
	length: f64,
	from:   f64,
	to:     f64,
	k:      f64,
	// Where the fade reaches zero, as a share of the length; 0 is 1.
	end:    f64,
	// Without the linear fade, and without an end: the plain exponential.
	pure:   bool,
}

envlaw_predict :: proc(s: Envlaw_Segment, j: int) -> f64 {
	u := (f64(j * ENVLAW_TICK) - s.base) / s.length
	g := s.pure ? (u <= 0 ? 1.0 : math.exp(-s.k * u)) : envlaw_fade_to(u, s.k, s.end > 0 ? s.end : 1.0)
	return s.to + (s.from - s.to) * g
}

Envlaw_Match :: struct {
	read:     int,
	exact:    int,
	// Largest whole-number gap between a knot and the prediction.
	miss:     int,
	// Largest |dB| between a knot and the prediction less half a step (the
	// average floor), over the knots the prediction puts at 32 or above.
	worst_db: f64,
}

envlaw_match :: proc(knots: []f64, first, last: int, s: Envlaw_Segment) -> (m: Envlaw_Match) {
	for j in first ..= min(last, len(knots) - 1) {
		measured := knots[j]
		if math.is_nan(measured) {continue}
		predicted := envlaw_predict(s, j)
		m.read += 1
		whole := math.floor(predicted + 1.0e-6)
		if whole == math.round(measured) {m.exact += 1}
		m.miss = max(m.miss, int(abs(math.round(measured) - whole)))
		if predicted >= 32 && measured > 0 {
			m.worst_db = max(m.worst_db, abs(20 * math.log10(measured / (predicted - 0.5))))
		}
	}
	return
}

// The exponent that makes the most knots come out exactly, and the share that
// do. A run of equally good exponents is reported by its middle.
envlaw_best_k :: proc(knots: []f64, first, last: int, s: Envlaw_Segment, lo, hi, step: f64) -> (k, share: f64) {
	trial := s
	best := -1
	sum, count := 0.0, 0
	for x := lo; x <= hi + step * 0.5; x += step {
		trial.k = x
		m := envlaw_match(knots, first, last, trial)
		if m.exact > best {
			best = m.exact
			sum = x
			count = 1
			share = m.read > 0 ? f64(m.exact) / f64(m.read) : 0
		} else if m.exact == best {
			sum += x
			count += 1
		}
	}
	return sum / f64(max(count, 1)), share
}

// Where the fade must reach zero for the most knots to come out exactly, as a
// share of the length, with the exponent held; the middle of a run of equals.
envlaw_best_end :: proc(knots: []f64, first, last: int, s: Envlaw_Segment, lo, hi, step: f64) -> (end, share: f64) {
	trial := s
	best := -1
	sum, count := 0.0, 0
	for x := lo; x <= hi + step * 0.5; x += step {
		trial.end = x
		m := envlaw_match(knots, first, last, trial)
		if m.exact > best {
			best = m.exact
			sum = x
			count = 1
			share = m.read > 0 ? f64(m.exact) / f64(m.read) : 0
		} else if m.exact == best {
			sum += x
			count += 1
		}
	}
	return sum / f64(max(count, 1)), share
}

// The first tick from which the envelope reads zero and stays there.
envlaw_first_zero :: proc(knots: []f64) -> int {
	for j in 1 ..< len(knots) - 3 {
		if knots[j] < 0.5 && knots[j + 1] < 0.5 && knots[j + 2] < 0.5 {return j}
	}
	return -1
}

// The sample after the last one that is not exactly zero, in either channel.
envlaw_last_sound :: proc(audio: []f32, from: int) -> int {
	for i := len(audio) / 2 - 1; i >= from; i -= 1 {
		if audio[i * 2] != 0 || audio[i * 2 + 1] != 0 {return i + 1}
	}
	return -1
}

// ------------------------------------------------------------------ attack

// The envelope's level at every sample that the settled sine can be divided
// at, up to 600 samples after the formula's ramp ends. The sine is the one the
// render settles into after `formula_samples` + 3000 samples, fitted for
// amplitude and phase, so no control with an attack of its own is needed.
envlaw_attack_levels :: proc(x: []f32, formula_samples: f64) -> (ns, levels: []f64) {
	n0 := int(formula_samples) + 3000
	n1 := n0 + 8000
	if n1 > len(x) {return}
	w := 2 * math.PI * note_hz(ENVLAW_NOTE) / SAMPLE_RATE
	ss, cc, sc, xs_, xc := 0.0, 0.0, 0.0, 0.0, 0.0
	for n in n0 ..< n1 {
		s, c := math.sin(w * f64(n)), math.cos(w * f64(n))
		ss += s * s
		cc += c * c
		sc += s * c
		xs_ += f64(x[n]) * s
		xc += f64(x[n]) * c
	}
	det := ss * cc - sc * sc
	a := (xs_ * cc - xc * sc) / det
	b := (xc * ss - xs_ * sc) / det
	amp := math.hypot(a, b)
	if amp <= 0 {return}
	count := make([dynamic]f64)
	level := make([dynamic]f64)
	for n in 0 ..< min(int(formula_samples) + 600, len(x)) {
		model := a * math.sin(w * f64(n)) + b * math.cos(w * f64(n))
		if abs(model) < 0.25 * amp {continue}
		append(&count, f64(n))
		append(&level, f64(x[n]) / model)
	}
	return count[:], level[:]
}

// How long the attack's ramp takes, in samples, from a line fitted through the
// part of it between a tenth and nine tenths of full level.
envlaw_attack_fit :: proc(x: []f32, formula_samples: f64) -> (samples, rms: f64) {
	samples, rms = math.nan_f64(), math.nan_f64()
	ns, levels := envlaw_attack_levels(x, formula_samples)
	defer delete(ns)
	defer delete(levels)
	mid_n, mid_level: [dynamic]f64
	defer delete(mid_n)
	defer delete(mid_level)
	for n, i in ns {
		if levels[i] > 0.1 && levels[i] < 0.9 {
			append(&mid_n, n)
			append(&mid_level, levels[i])
		}
	}
	if len(mid_n) > 2 {
		slope, _, line_rms := arch_fit_line(mid_n[:], mid_level[:])
		samples = 1 / slope
		rms = line_rms
	}
	return
}

// The ramp's length and the approach constant together, in samples: levels
// fitted by min(1, n / ramp) * (1 - exp(-n / tau)), a ramp under a one-pole
// approach. Where the ramp is no longer than a few approach constants the line
// above reads the approach instead of the ramp, and this does not.
envlaw_attack_model :: proc(x: []f32, formula_samples: f64) -> (ramp, tau, rms: f64) {
	ramp, tau, rms = math.nan_f64(), math.nan_f64(), math.nan_f64()
	ns, levels := envlaw_attack_levels(x, formula_samples)
	defer delete(ns)
	defer delete(levels)
	if len(ns) < 20 {return}
	sse :: proc(ns, levels: []f64, ramp, tau: f64) -> f64 {
		total := 0.0
		for n, i in ns {
			d := levels[i] - min(1.0, n / ramp) * (1 - math.exp(-n / tau))
			total += d * d
		}
		return total
	}
	best := max(f64)
	for r := 0.5 * formula_samples; r <= 2.0 * formula_samples; r *= 1.005 {
		for t := 40.0; t <= 100.0; t += 2 {
			if s := sse(ns, levels, r, t); s < best {
				best = s
				ramp = r
				tau = t
			}
		}
	}
	centre_r, centre_t := ramp, tau
	for r := centre_r * 0.994; r <= centre_r * 1.006; r += centre_r * 0.0002 {
		for t := centre_t - 2; t <= centre_t + 2; t += 0.1 {
			if s := sse(ns, levels, r, t); s < best {
				best = s
				ramp = r
				tau = t
			}
		}
	}
	rms = math.sqrt(best / f64(len(ns)))
	return
}

// ------------------------------------------------------------------ command

// Where a decay starts after stored attack 0: the reference's attack takes the
// formula's 24 samples, this engine's the table's 0.0035 s.
envlaw_zero_attack_samples :: proc(side: int) -> f64 {
	if side == 0 {return ENVLAW_ATTACK0_SAMPLES}
	return f64(sengine.envelope_attack_time(25, 0)) * SAMPLE_RATE
}

envlaw_note_events :: proc(segment: Env_Segment) -> []Script_Event {
	events := make([]Script_Event, segment == .Release ? 2 : 1, context.temp_allocator)
	events[0] = script_on(0, ENVLAW_NOTE)
	if segment == .Release {events[1] = script_off(0.3, ENVLAW_NOTE)}
	return events
}

envlaw_stage_seconds :: proc(segment: Env_Segment, v: int) -> f64 {
	if segment == .Attack {return envlaw_attack_seconds(v) * 1.5 + 0.5}
	return (segment == .Release ? 0.3 : 0.0) + ENVLAW_FIRST_ZERO_U * envlaw_length_seconds(v) + 0.6
}

envlaw_table_seconds :: proc(segment: Env_Segment, v: int) -> f64 {
	switch segment {
	case .Attack: return f64(sengine.envelope_attack_time(25, v))
	case .Decay: return f64(sengine.envelope_decay_time(26, v))
	case .Release: return f64(sengine.envelope_release_time(28, v))
	}
	return 0
}

cmd_arch_envlaw :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	values := o.values[:]
	if len(values) == 0 {values = []int{0, 16, 32, 48, 64, 80, 96, 112, 127}}
	fmt.printfln("arch envlaw: sine note %v, velocity 100, 48 kHz; values %v", ENVLAW_NOTE, values)
	fmt.println("  line: the ramp's length from a line through its 10-90% part. model: the ramp and the approach tau,")
	fmt.println("  both fitted, to min(1, n/ramp) * (1 - exp(-n/tau)), n in samples from note on (ramps up to 8000")
	fmt.println("  samples). Both against the formula and against envelope_table's 90% time / 0.9.")
	fmt.println()
	fmt.printfln("  %-4v | %9v %9v | %-30v | %-32v | %-23v", "v", "formula s", "table s", "ref line s  /form /table   rms", "ref model s  /form   tau      rms", "ours line s  /form /table")
	for v in values {
		formula := envlaw_attack_seconds(v)
		table := envlaw_table_seconds(.Attack, v)
		p := envlaw_patch(.Attack, v)
		ref, ours := arch_render(dll, &p, c, envlaw_note_events(.Attack), envlaw_stage_seconds(.Attack, v))
		write_pair(o.wav, fmt.tprintf("envlaw-attack-%v", v), ref, ours)
		cells: [3]string
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, 0)
			samples, rms := envlaw_attack_fit(x, formula * SAMPLE_RATE)
			seconds := samples / SAMPLE_RATE
			if side == 0 {
				cells[0] = fmt.tprintf("%v %v %v %v", dec4(seconds, 10), dec4(seconds / formula, 7), dec4(seconds / table, 7), pad_left(fmt.tprintf("%.1e", rms), 8))
				if formula * SAMPLE_RATE <= 8000 {
					ramp, tau, model_rms := envlaw_attack_model(x, formula * SAMPLE_RATE)
					cells[1] = fmt.tprintf("%v %v %v %v", dec4(ramp / SAMPLE_RATE, 10), dec4(ramp / SAMPLE_RATE / formula, 7), dec1(tau, 6),
						pad_left(fmt.tprintf("%.1e", model_rms), 8))
				} else {
					cells[1] = fmt.tprintf("%v", pad_left("-", 10 + 1 + 7 + 1 + 6 + 1 + 8))
				}
			} else {
				cells[2] = fmt.tprintf("%v %v %v", dec4(seconds, 10), dec4(seconds / formula, 7), dec4(seconds / table, 7))
			}
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %v | %9v %9v | %v | %v | %v", pad_left(fmt.tprintf("%v", v), 4), dec4(formula, 9), dec4(table, 9), cells[0], cells[1], cells[2])
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("arch envlaw: decay (sustain 0) and release (from sustain 127 at 0.3 s)")
	fmt.println("  knots: the envelope at every 256th sample, read against a flat render of the same note and counted")
	fmt.println("  against floor(2048 * (1 - u) * exp(-8 u)), u = (t - segment start) / formula length; a decay starts when")
	fmt.println("  its attack ends: sample 24 in the reference, the table's 0.0035 s in this engine.")
	fmt.println("  exact: knots equal to the prediction / knots read; miss: the largest gap in whole steps; dB: largest")
	fmt.println("  gap above 32/2048 less half a step. A knot is read only where the lines on both sides of it agree.")
	fmt.println("  k: the exponent with most knots exact; fade: where the fade must reach zero for that, as a share of the")
	fmt.println("  length; pure: the share exact for the best plain exponential of that length with no fade. zero: first")
	fmt.println("  tick the envelope reads 0 / formula length; tail: ticks the output goes on after it before it is exactly")
	fmt.println("  silent.")
	fmt.println()
	fmt.printfln("  %-12v | %9v | %-58v | %-18v | %-31v", "segment", "formula s", "ref   read  exact miss    dB      k  fade   pure   zero tail", "table s  /formula", "ours  read  exact    dB   zero")
	for segment in ([2]Env_Segment{.Decay, .Release}) {
		longest := 0.0
		for v in values {longest = max(longest, envlaw_stage_seconds(segment, v))}
		flat := envlaw_patch(.Attack, 0)
		fr, fo := arch_render(dll, &flat, c, []Script_Event{script_on(0, ENVLAW_NOTE)}, longest)
		for v in values {
			length := envlaw_length_seconds(v)
			p := envlaw_patch(segment, v)
			ev := envlaw_note_events(segment)
			ref, ours := arch_render(dll, &p, c, ev, envlaw_stage_seconds(segment, v))
			write_pair(o.wav, fmt.tprintf("envlaw-%v-%v", segment, v), ref, ours)
			start := segment == .Release ? ev[1].frame : 0
			cells: [2]string
			for audio, side in ([2][]f32{ref, ours}) {
				control := script_channel(side == 0 ? fr : fo, 0)
				x := script_channel(audio, 0)
				ticks := (min(len(x), len(control)) - start) / ENVLAW_TICK - 1
				knots := envlaw_knots(x, control, start, ticks)
				seg := Envlaw_Segment{base = segment == .Decay ? envlaw_zero_attack_samples(side) : 0, length = length * SAMPLE_RATE, from = ENVLAW_FULL, to = 0, k = ENVLAW_K}
				zero := envlaw_first_zero(knots)
				last := zero >= 0 ? zero : len(knots) - 1
				m := envlaw_match(knots, 1, last, seg)
				if o.what == "knots" {
					for j in 1 ..= min(last, len(knots) - 1) {
						fmt.printfln("    %v %v %v knot %v read %.3f law %.3f", segment, v, side == 0 ? "ref" : "ours", j, knots[j], envlaw_predict(seg, j))
					}
				}
				share := f64(m.exact) / f64(max(m.read, 1))
				zero_cell := zero >= 0 ? dec4(f64(zero * ENVLAW_TICK) / SAMPLE_RATE / length, 7) : pad_left("-", 7)
				if side == 0 {
					k_best, _ := envlaw_best_k(knots, 1, last, seg, 7.0, 9.0, 0.001)
					fade_end, _ := envlaw_best_end(knots, 1, last, seg, 0.9, 1.1, 0.001)
					plain := seg
					plain.pure = true
					_, pure_share := envlaw_best_k(knots, 1, last, plain, 2.0, 14.0, 0.01)
					end := envlaw_last_sound(audio, start)
					end_ticks := zero >= 0 && end > 0 ? fmt.tprintf("%v", (end - start - zero * ENVLAW_TICK) / ENVLAW_TICK) : "-"
					cells[0] = fmt.tprintf("%v %v %v %v %v %v %v %v %v", pad_left(fmt.tprintf("%v", m.read), 5), dec3(share, 6), pad_left(fmt.tprintf("%v", m.miss), 4),
						dec2(m.worst_db, 6), dec3(k_best, 6), dec3(fade_end, 5), dec3(pure_share, 5), zero_cell, pad_left(end_ticks, 4))
				} else {
					cells[1] = fmt.tprintf("%v %v %v %v", pad_left(fmt.tprintf("%v", m.read), 5), dec3(share, 6), dec2(m.worst_db, 6), zero_cell)
				}
				delete(knots)
				delete(control)
				delete(x)
			}
			table := envlaw_table_seconds(segment, v)
			fmt.printfln("  %-12v | %9v | %v | %v %v | %v", fmt.tprintf("%v %v", segment, v), dec4(length, 9), cells[0], dec4(table, 8), dec3(table / length, 8), cells[1])
			arch_free_pair(ref, ours)
			free_all(context.temp_allocator)
		}
		arch_free_pair(fr, fo)
	}
	envlaw_levels(dll, c, o)
}

// Decay to a sustain, and release from a level other than full: the law
// scaled by where it starts and ends. A decay falls from 2048 to the sustain
// by 2048 + (sustain - 2048) * fade; a release by level * fade.
envlaw_levels :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	length := envlaw_length_seconds(64)
	samples := length * SAMPLE_RATE
	fmt.println()
	fmt.println("arch envlaw: other levels, decay and release stored 64 (0.8016 s)")
	fmt.println("  decay: falls from 2048 to the sustain the reference settles on (its last 20 knots); release: from")
	fmt.println("  the whole number the note-off finds. Predicted tick by tick as before; read and exact count knots.")
	fmt.println()
	fmt.printfln("  %-30v | %-38v | %-26v", "case", "ref   level  read  exact miss    dB", "ours  level  read    dB")
	flat := envlaw_patch(.Attack, 0)
	fr, fo := arch_render(dll, &flat, c, []Script_Event{script_on(0, ENVLAW_NOTE)}, 2.4)
	Case :: struct {
		name:    string,
		attack:  int,
		decay:   int,
		sustain: int,
		off:     f64,
	}
	cases := []Case {
		{"decay to sustain stored 32", 0, 64, 32, -1},
		{"decay to sustain stored 64", 0, 64, 64, -1},
		{"decay to sustain stored 96", 0, 64, 96, -1},
		{"release from sustain stored 64", 0, 0, 64, 0.3},
		{"release in decay 80 (0 sustain)", 0, 80, 0, 0.5},
		{"release in attack 96", 96, 0, 127, 0.5},
	}
	for cs in cases {
		p := arch_sine_patch()
		set_param(&p, 25, cs.attack)
		set_param(&p, 26, cs.decay)
		set_param(&p, 27, cs.sustain)
		set_param(&p, 28, 64)
		release := cs.off >= 0
		events := make([]Script_Event, release ? 2 : 1, context.temp_allocator)
		events[0] = script_on(0, ENVLAW_NOTE)
		if release {events[1] = script_off(cs.off, ENVLAW_NOTE)}
		ref, ours := arch_render(dll, &p, c, events, release ? cs.off + 1.8 : 1.4)
		write_pair(o.wav, fmt.tprintf("envlaw-level-%v", cs.name), ref, ours)
		start := release ? events[1].frame : 0
		cells: [2]string
		for audio, side in ([2][]f32{ref, ours}) {
			control := script_channel(side == 0 ? fr : fo, 0)
			x := script_channel(audio, 0)
			ticks := (min(len(x), len(control)) - start) / ENVLAW_TICK - 1
			knots := envlaw_knots(x, control, start, ticks)
			seg := Envlaw_Segment{length = samples, from = ENVLAW_FULL, to = 0, k = ENVLAW_K}
			last := len(knots) - 1
			if release {
				seg.from = side == 0 ? math.round(knots[0]) : knots[0]
				zero := envlaw_first_zero(knots)
				if zero >= 0 {last = zero}
			} else {
				seg.base = envlaw_zero_attack_samples(side)
				sum, n := 0.0, 0.0
				for j in len(knots) - 21 ..< len(knots) - 1 {
					if !math.is_nan(knots[j]) {
						sum += knots[j]
						n += 1
					}
				}
				seg.to = side == 0 ? math.round(sum / n) : sum / n
				last = int(samples / ENVLAW_TICK) + 40
			}
			m := envlaw_match(knots, 1, last, seg)
			level := release ? seg.from : seg.to
			if side == 0 {
				cells[0] = fmt.tprintf("%v %v %v %v %v", dec0(level, 6), pad_left(fmt.tprintf("%v", m.read), 5), dec3(f64(m.exact) / f64(max(m.read, 1)), 6),
					pad_left(fmt.tprintf("%v", m.miss), 4), dec2(m.worst_db, 6))
			} else {
				cells[1] = fmt.tprintf("%v %v %v", dec1(level, 7), pad_left(fmt.tprintf("%v", m.read), 5), dec2(m.worst_db, 6))
			}
			delete(knots)
			delete(control)
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-30v | %v | %v", cs.name, cells[0], cells[1])
		free_all(context.temp_allocator)
	}
	arch_free_pair(fr, fo)
}
