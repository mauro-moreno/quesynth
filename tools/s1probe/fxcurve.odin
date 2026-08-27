package s1probe

// The distortions' transfer curves, measured rather than chosen.
//
// Three of the four shapes in the effect unit were written from their names and
// never measured: a.d.1 is an asymmetric tanh with a hand-picked offset, a.d.2 a
// plain tanh, d.d. a hard clip. They score 6.5, 7.4 and 14.3 dB of spectral
// error, which is the worst of any section, and no amount of comparing spectra
// says what curve to write instead -- a spectrum is what the curve did to one
// particular signal, and inverting that is guesswork.
//
// A waveshaper is memoryless, so its curve can be read directly. Render the same
// patch twice, once with the unit off and once on, and the two renders are sample
// aligned because the same synth made both. Scatter the second against the first
// and the result *is* the curve: no fitting, no assumption about its family, one
// point per sample.
//
// What the scatter also shows is whether the thing is memoryless at all. A pure
// curve draws a line; anything with a filter in it draws a loop, because the
// output then depends on where the input was as well as where it is. The width of
// that loop is reported alongside the curve, so a shape is never fitted through
// what is actually a filter.
//
// The tone is a low sine so that the harmonics the shaping creates stay below the
// unit's own low pass, which would otherwise open the loop by itself.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import cpatch "../../src/patch"

// Bins across the input range. Odd, so one bin is centred on zero.
FXCURVE_BINS :: 257

// Which part of the held note is used. The start is skipped so the amplitude
// envelope has settled, and the end so the release never enters.
FXCURVE_FROM :: 0.30
FXCURVE_TO :: 0.90

Fx_Curve :: struct {
	x:      []f64, // bin centre, the input
	y:      []f64, // mean output in that bin
	lo:     []f64, // and its spread, which is the loop
	hi:     []f64,
	n:      []int,
	peak:   f64, // the largest input seen
	loop:   f64, // widest spread, as a fraction of the output range
	filled: int,
}

fx_curve_free :: proc(c: ^Fx_Curve) {
	delete(c.x);delete(c.y);delete(c.lo);delete(c.hi);delete(c.n)
}

// Scatter `on` against `off`, both interleaved stereo, and bin the result.
fx_curve_measure :: proc(off, on: []f32, peak_hint: f64 = 0) -> Fx_Curve {
	c: Fx_Curve
	mo, so := split_mid_side(off, 2)
	defer delete(mo)
	defer delete(so)
	mn, sn := split_mid_side(on, 2)
	defer delete(mn)
	defer delete(sn)

	held := min(g_hold_frames, min(len(mo), len(mn)))
	from := int(f64(held) * FXCURVE_FROM)
	to := int(f64(held) * FXCURVE_TO)
	if to - from < 64 {
		return c
	}

	peak := peak_hint
	if peak <= 0 {
		for i in from ..< to {
			if a := abs(f64(mo[i])); a > peak {peak = a}
		}
	}
	if peak <= 0 {
		return c
	}
	c.peak = peak

	c.x = make([]f64, FXCURVE_BINS)
	c.y = make([]f64, FXCURVE_BINS)
	c.lo = make([]f64, FXCURVE_BINS)
	c.hi = make([]f64, FXCURVE_BINS)
	c.n = make([]int, FXCURVE_BINS)
	for i in 0 ..< FXCURVE_BINS {
		c.x[i] = peak * (2.0 * f64(i) / f64(FXCURVE_BINS - 1) - 1.0)
		c.lo[i] = 1.0e30
		c.hi[i] = -1.0e30
	}

	for i in from ..< to {
		xv := f64(mo[i])
		yv := f64(mn[i])
		t := (xv / peak + 1.0) * 0.5
		if t < 0 || t > 1 {
			continue
		}
		b := int(t * f64(FXCURVE_BINS - 1) + 0.5)
		if b < 0 || b >= FXCURVE_BINS {
			continue
		}
		c.y[b] += yv
		c.n[b] += 1
		if yv < c.lo[b] {c.lo[b] = yv}
		if yv > c.hi[b] {c.hi[b] = yv}
	}

	ymin, ymax := 1.0e30, -1.0e30
	for i in 0 ..< FXCURVE_BINS {
		if c.n[i] > 0 {
			c.y[i] /= f64(c.n[i])
			c.filled += 1
			if c.y[i] < ymin {ymin = c.y[i]}
			if c.y[i] > ymax {ymax = c.y[i]}
		}
	}
	span := ymax - ymin
	if span > 0 {
		for i in 0 ..< FXCURVE_BINS {
			// The spread within a bin, ignoring the ends where a sine spends
			// enough time that a bin is wide in input as well as output.
			if c.n[i] > 8 && abs(c.x[i]) < 0.9 * peak {
				if w := (c.hi[i] - c.lo[i]) / span; w > c.loop {c.loop = w}
			}
		}
	}
	return c
}

cmd_fxcurve :: proc(
	dll: string,
	type_state, ctl1, ctl2, level, note, gain: int,
	drives: []int,
	csv_path: string,
) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"transfer curve: %s (state %d) ctl2=%d level=%d, sine at note %d",
		name,
		type_state,
		ctl2,
		level,
		note,
	)
	fmt.println("  the loop column is how far from memoryless the unit is: 0 is a curve, high is a filter")
	fmt.println("  ctl1   in peak    out peak   gain at 0   loop     ours: out peak   loop")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "ctl1,x,reference_y,reference_lo,reference_hi,ours_y,samples")

	for d in drives {
		p_off := fx_probe_patch(false, type_state, d, ctl2, level)
		p_on := fx_probe_patch(true, type_state, d, ctl2, level)
		set_param(&p_off, 29, gain)
		set_param(&p_on, 29, gain)

		ref_off, _, ok1 := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
		defer delete(ref_off)
		ref_on, _, ok2 := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
		defer delete(ref_on)
		if !ok1 || !ok2 {
			fmt.printfln("  %4d   render failed", d)
			continue
		}
		ours_off := render_ours(p_off, note)
		defer delete(ours_off)
		ours_on := render_ours(p_on, note)
		defer delete(ours_on)

		rc := fx_curve_measure(ref_off, ref_on)
		defer fx_curve_free(&rc)
		// Ours is binned on the reference's own input peak, so the two columns
		// are the same curve sampled at the same places.
		oc := fx_curve_measure(ours_off, ours_on, rc.peak)
		defer fx_curve_free(&oc)
		if rc.filled == 0 {
			fmt.printfln("  %4d   no signal", d)
			continue
		}

		// The slope through the origin, over the middle tenth of the range.
		slope :: proc(c: ^Fx_Curve) -> f64 {
			num, den := 0.0, 0.0
			for i in 0 ..< FXCURVE_BINS {
				if c.n[i] > 0 && abs(c.x[i]) < 0.05 * c.peak {
					num += c.x[i] * c.y[i]
					den += c.x[i] * c.x[i]
				}
			}
			return den > 0 ? num / den : 0
		}
		outpeak :: proc(c: ^Fx_Curve) -> f64 {
			m := 0.0
			for i in 0 ..< FXCURVE_BINS {
				if c.n[i] > 0 && abs(c.y[i]) > m {m = abs(c.y[i])}
			}
			return m
		}

		fmt.printfln(
			"  %s   %s    %s     %s   %s          %s   %s",
			pad_left(fmt.tprintf("%d", d), 4),
			pad_left(dec3(rc.peak), 7),
			pad_left(dec3(outpeak(&rc)), 7),
			pad_left(dec3(slope(&rc)), 7),
			pad_left(dec3(rc.loop), 6),
			pad_left(dec3(outpeak(&oc)), 7),
			pad_left(dec3(oc.loop), 6),
		)

		if csv_path != "" {
			for i in 0 ..< FXCURVE_BINS {
				if rc.n[i] > 0 {
					oy := oc.n[i] > 0 ? oc.y[i] : 0
					fmt.sbprintfln(
						&b,
						"%d,%.8f,%.8f,%.8f,%.8f,%.8f,%d",
						d,
						rc.x[i],
						rc.y[i],
						rc.lo[i],
						rc.hi[i],
						oy,
						rc.n[i],
					)
				}
			}
		}
	}

	if csv_path != "" {
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("fxcurve: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}

// ------------------------------------------------------- the frequency domain
//
// The time-domain scatter above says what the unit is not: at 2 kHz a single
// sample is sixteen degrees of phase, so the map is scrambled by any delay, and
// at the frequencies where the loop is widest the curve doubles back on itself.
// Reading a shape out of that is not possible and was not attempted.
//
// The harmonics are immune to it. A memoryless curve driven by a sine of
// amplitude A puts power only at multiples of f0, and the amplitude of the k-th
// is the k-th Chebyshev coefficient of the curve at that A. Whatever filtering
// follows multiplies each harmonic by a fixed number -- fixed because f0 is
// fixed -- so measuring at one f0 across a range of A separates the curve's
// shape from the filter's gain without needing either in advance.
FXHARM_MAX :: 12

fx_harm_amplitudes :: proc(audio: []f32, f0: f64) -> (amp: [FXHARM_MAX + 1]f64, ok: bool) {
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	from := min(int(0.1 * f64(SAMPLE_RATE)), len(mid) / 4)
	power := welch_power(mid, from, min(g_hold_frames, len(mid)))
	defer delete(power)
	if power == nil {
		return amp, false
	}
	r := harmonic_report(power, f64(SAMPLE_RATE) / f64(FFT_SIZE), f0)
	for k in 1 ..= FXHARM_MAX {
		// Power to amplitude, so the numbers compose the way a curve does.
		amp[k] = math.sqrt(max(r.harmonic[k], 0))
	}
	return amp, true
}

cmd_fxharm :: proc(
	dll: string,
	type_state, ctl2, level, note: int,
	drives, gains: []int,
	csv_path: string,
) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"harmonics: %s (state %d) ctl2=%d level=%d, sine at %.1f Hz",
		name,
		type_state,
		ctl2,
		level,
		f0,
	)
	fmt.println("  every harmonic in dB relative to the input's own fundamental, so h1 is the gain")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "ctl1,gain,in_amp,harmonic,reference_amp,ours_amp")

	for g in gains {
		fmt.printfln("  amp gain %d", g)
		fmt.println("   ctl1   in       h1     h2     h3     h4     h5     h6     h7     h8")
		for d in drives {
			p_off := fx_probe_patch(false, type_state, d, ctl2, level)
			p_on := fx_probe_patch(true, type_state, d, ctl2, level)
			set_param(&p_off, 29, g)
			set_param(&p_on, 29, g)

			ref_off, _, ok1 := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
			defer delete(ref_off)
			ref_on, _, ok2 := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
			defer delete(ref_on)
			if !ok1 || !ok2 {
				continue
			}
			ours_on := render_ours(p_on, note)
			defer delete(ours_on)

			a_off, k1 := fx_harm_amplitudes(ref_off, f0)
			a_on, k2 := fx_harm_amplitudes(ref_on, f0)
			a_ours, _ := fx_harm_amplitudes(ours_on, f0)
			if !k1 || !k2 || a_off[1] <= 0 {
				continue
			}

			// What went in, on the same scale: the tone the synth actually made,
			// which is not a pure sine and must not be fitted into the shaper.
			off_line := "   off  "
			for k in 1 ..= 8 {
				v := a_off[k] / a_off[1]
				off_line = fmt.tprintf("%s %s", off_line, pad_left(v > 1.0e-6 ? dec1(20.0 * math.log10(v)) : "  -inf", 6))
			}
			fmt.println(off_line)

			line := fmt.tprintf("   %s  %s", pad_left(fmt.tprintf("%d", d), 4), dec3(a_off[1]))
			for k in 1 ..= 8 {
				v := a_on[k] / a_off[1]
				line = fmt.tprintf(
					"%s %s",
					line,
					pad_left(v > 1.0e-6 ? dec1(20.0 * math.log10(v)) : "  -inf", 6),
				)
			}
			fmt.println(line)

			if csv_path != "" {
				for k in 1 ..= FXHARM_MAX {
					fmt.sbprintfln(
						&b,
						"%d,%d,%.8f,%d,%.10f,%.10f",
						d,
						g,
						a_off[1],
						k,
						a_on[k],
						a_ours[k],
					)
				}
			}
		}
	}

	if csv_path != "" {
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("fxharm: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}

// ------------------------------------------------------ the curve, recovered
//
// Fitting families failed for three of the four types, and it failed the same way
// each time: a family that matched the first few harmonics missed the tail, and
// the tail is most of what a spectrum sees. The fault is in the method rather
// than in the families. A curve should not be guessed at and scored; it should be
// read.
//
// It can be. Everything needed is in the phases, which the harmonic probe above
// throws away when it takes power. Drive the unit with a sine `A cos(wt + p)`.
// A memoryless curve puts out `sum D_k cos(k(wt + p))` with every `D_k` **real** --
// that is what memoryless means, that nothing lags -- and a filter after it
// multiplies each by `H(k f0)`, which is known once the response has been
// measured. So take the complex coefficient of each harmonic, divide by `H`, and
// rotate by the input's own phase: what is left is `D_k`, and the curve is the sum.
//
// The imaginary part that survives is the instrument's own check. For a
// memoryless curve behind the right filter it is zero, and whatever it is
// measures how much of the reading is neither.
FXSHAPE_HARMONICS :: 40
FXSHAPE_POINTS :: 257

Fx_Complex :: [2]f64

fx_cmul :: proc "contextless" (a, b: Fx_Complex) -> Fx_Complex {
	return {a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0]}
}
fx_cdiv :: proc "contextless" (a, b: Fx_Complex) -> Fx_Complex {
	d := b[0] * b[0] + b[1] * b[1]
	if d == 0 {
		return {0, 0}
	}
	return {(a[0] * b[0] + a[1] * b[1]) / d, (a[1] * b[0] - a[0] * b[1]) / d}
}

// The response fitted at ctl1 0, where every type here is linear: a two-pole high
// pass, optionally one more pole behind it, and a makeup gain.
Fx_Response :: struct {
	fc, q:   f64,
	pole_hz: f64, // zero for none
	makeup:  f64,
}

fx_response_at :: proc "contextless" (r: Fx_Response, f: f64) -> Fx_Complex {
	// The analogue prototype, which is what the magnitudes were fitted against.
	x := f / r.fc
	num := Fx_Complex{-x * x, 0}
	den := Fx_Complex{1.0 - x * x, x / r.q}
	h := fx_cdiv(num, den)
	if r.pole_hz > 0 {
		y := f / r.pole_hz
		h = fx_cmul(h, fx_cdiv(Fx_Complex{0, y}, Fx_Complex{1, y}))
	}
	return {h[0] * r.makeup, h[1] * r.makeup}
}

// The complex amplitude of one harmonic, at a frequency that need not land on a
// bin: a Hann-windowed sum against the exact frequency, so a non-integer number
// of periods in the window costs nothing.
fx_harmonic_at :: proc(x: []f32, f, sr: f64) -> Fx_Complex {
	n := len(x)
	if n < 16 {
		return {0, 0}
	}
	re, im, norm := 0.0, 0.0, 0.0
	for i in 0 ..< n {
		w := 0.5 - 0.5 * math.cos(TAU_F64 * f64(i) / f64(n - 1))
		phase := -TAU_F64 * f * f64(i) / sr
		re += w * f64(x[i]) * math.cos(phase)
		im += w * f64(x[i]) * math.sin(phase)
		norm += w
	}
	if norm <= 0 {
		return {0, 0}
	}
	return {2.0 * re / norm, 2.0 * im / norm}
}

TAU_F64 :: 6.283185307179586

cmd_fxshape :: proc(
	dll: string,
	type_state, ctl2, level, note, gain: int,
	drives: []int,
	resp: Fx_Response,
	csv_path: string,
	harmonics_path: string = "",
) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	sr := f64(SAMPLE_RATE)
	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"transfer curve, recovered: %s (state %d) ctl2=%d level=%d, sine at %.1f Hz",
		name,
		type_state,
		ctl2,
		level,
		f0,
	)
	fmt.printfln(
		"  dividing out a two-pole high pass at %.1f Hz, Q %.2f%s, makeup %.3f",
		resp.fc,
		resp.q,
		resp.pole_hz > 0 ? fmt.tprintf(", one more pole at %.0f Hz", resp.pole_hz) : "",
		resp.makeup,
	)
	fmt.println("  the residual is what is left over after a memoryless curve: 0 is one, 1 is none of one")
	fmt.println("  ctl1   in      out     residual   harmonics used")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "ctl1,x,y")

	// The coefficients before anything is divided out, so a filter can be fitted
	// against them offline instead of guessed at and re-rendered.
	hb := strings.builder_make()
	defer strings.builder_destroy(&hb)
	fmt.sbprintln(&hb, "ctl1,k,re,im,in_amp,in_phase")

	for d in drives {
		p_off := fx_probe_patch(false, type_state, d, ctl2, level)
		p_on := fx_probe_patch(true, type_state, d, ctl2, level)
		set_param(&p_off, 29, gain)
		set_param(&p_on, 29, gain)

		ref_off, _, ok1 := render_reference_fresh(dll, &p_off, pristine, work, u8(note))
		defer delete(ref_off)
		ref_on, _, ok2 := render_reference_fresh(dll, &p_on, pristine, work, u8(note))
		defer delete(ref_on)
		if !ok1 || !ok2 {
			continue
		}
		mo, so := split_mid_side(ref_off, 2)
		defer delete(mo)
		defer delete(so)
		mn, sn := split_mid_side(ref_on, 2)
		defer delete(mn)
		defer delete(sn)

		held := min(g_hold_frames, min(len(mo), len(mn)))
		from := min(int(0.15 * sr), held / 4)
		to := min(from + int(0.5 * sr), held)
		if to - from < 4096 {
			continue
		}

		// The input's own fundamental fixes both the amplitude and the phase that
		// everything else is measured against.
		c_in := fx_harmonic_at(mo[from:to], f0, sr)
		amp := math.sqrt(c_in[0] * c_in[0] + c_in[1] * c_in[1])
		if amp <= 0 {
			continue
		}
		phase := math.atan2(c_in[1], c_in[0])

		coeff: [FXSHAPE_HARMONICS + 1]f64
		real_sum, imag_sum := 0.0, 0.0
		used := 0
		for k in 1 ..= FXSHAPE_HARMONICS {
			f := f0 * f64(k)
			if f >= sr * 0.45 {
				break
			}
			c := fx_harmonic_at(mn[from:to], f, sr)
			if math.sqrt(c[0] * c[0] + c[1] * c[1]) < amp * 1.0e-4 {
				continue
			}
			if harmonics_path != "" {
				fmt.sbprintfln(&hb, "%d,%d,%.10f,%.10f,%.8f,%.8f", d, k, c[0], c[1], amp, phase)
			}
			c = fx_cdiv(c, fx_response_at(resp, f))
			// Undo the input's phase, k times over: a memoryless curve's harmonic
			// rides on k times the fundamental's phase.
			rot := Fx_Complex{math.cos(f64(k) * phase), -math.sin(f64(k) * phase)}
			c = fx_cmul(c, rot)
			coeff[k] = c[0]
			real_sum += c[0] * c[0]
			imag_sum += c[1] * c[1]
			used += 1
		}
		residual := real_sum + imag_sum > 0 ? math.sqrt(imag_sum / (real_sum + imag_sum)) : 1.0

		out_peak := 0.0
		for i in 0 ..< FXSHAPE_POINTS {
			t := TAU_F64 * f64(i) / f64(FXSHAPE_POINTS)
			x := amp * math.cos(t)
			y := 0.0
			for k in 1 ..= FXSHAPE_HARMONICS {
				y += coeff[k] * math.cos(f64(k) * t)
			}
			if abs(y) > out_peak {out_peak = abs(y)}
			if csv_path != "" {
				fmt.sbprintfln(&b, "%d,%.8f,%.8f", d, x, y)
			}
		}

		fmt.printfln(
			"  %s  %s  %s     %s      %d",
			pad_left(fmt.tprintf("%d", d), 4),
			pad_left(dec3(amp), 6),
			pad_left(dec3(out_peak), 6),
			pad_left(dec3(residual), 6),
			used,
		)
	}

	if csv_path != "" {
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("fxshape: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
	if harmonics_path != "" {
		if os.write_entire_file(harmonics_path, transmute([]u8)strings.to_string(hb)) != nil {
			fmt.eprintfln("fxshape: could not write %s", harmonics_path)
		} else {
			fmt.printfln("  wrote %s", harmonics_path)
		}
	}
}
