// s1probe chorusphase - is this engine's chorus sweep in step with the
// reference's, and does that change with the rate?
//
// The bank regressed on a handful of chorus patches when parameter 54 was
// converted from stored 64 to stored 50, which is 2.94 Hz down to 0.99 Hz.
// `choruswidth` says the width and the channel correlation match at both, so
// the rate *mapping* is not wrong. What a slower sweep changes is how much of
// one cycle fits inside the 1.5 s the null test analyses: 4.4 cycles at 2.94 Hz
// against 1.5 at 0.99. With only one and a half cycles in the window, where the
// sweep *starts* stops averaging out, so a phase offset between the two engines
// that is invisible at the faster rate can dominate at the slower one.
//
// This isolates the chorus into the side signal -- the dry is centred, so L-R
// is the wet alone -- and cross-correlates the reference's against this
// engine's to read the offset between the two sweeps directly.
//
//   s1probe chorusphase [dll] [--values <rates>] [--delay <n>] [--type <n>]
package s1probe

import "core:fmt"
import "core:math"

cmd_chorusphase :: proc(dll: string, values: []int, delay_time, type: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	fmt.printfln("chorusphase: delay setting %v, type %v", delay_time, type)
	fmt.println("  side signal (L-R) is the chorus alone; lag is reference against ours")
	fmt.println()
	fmt.printfln("%8v %10v %12v %12v %12v", "rate", "Hz", "best lag ms", "corr at best", "corr at zero")

	for v in values {
		p := chorus_noise_patch(64, v, delay_time, 127, type)
		hz := f64(0)
		{
			pl, ok := open_reference(dll)
			if ok {
				load_reference_patch(&pl, &p, pristine, work)
				if h, got := parse_display_number(dispatch_str(&pl, .GetParamDisplay, 54)); got {
					hz = h
				}
				close_reference(&pl)
			}
		}

		ref := probe_render(dll, &p, pristine, work, 60, 4.0, &dumped, nil)
		if ref == nil {continue}
		ours := render_ours(p, 60)
		defer delete(ref)
		defer delete(ours)

		n := min(len(ref), len(ours)) / 2
		if n < 8192 {continue}
		// The side signal of each: the chorus with the dry removed.
		a := make([]f64, n); defer delete(a)
		b := make([]f64, n); defer delete(b)
		for i in 0 ..< n {
			a[i] = f64(ref[i * 2]) - f64(ref[i * 2 + 1])
			b[i] = f64(ours[i * 2]) - f64(ours[i * 2 + 1])
		}
		// Envelope of each, so what is compared is the sweep and not the noise
		// carried on it. A 10 ms frame is short against every rate swept here.
		frame := int(0.010 * f64(SAMPLE_RATE))
		m := n / frame
		if m < 32 {continue}
		ea := make([]f64, m); defer delete(ea)
		eb := make([]f64, m); defer delete(eb)
		for k in 0 ..< m {
			sa, sb := 0.0, 0.0
			for j in 0 ..< frame {
				sa += a[k * frame + j] * a[k * frame + j]
				sb += b[k * frame + j] * b[k * frame + j]
			}
			ea[k] = math.sqrt(sa / f64(frame))
			eb[k] = math.sqrt(sb / f64(frame))
		}
		ma, mb := 0.0, 0.0
		for k in 0 ..< m {ma += ea[k]; mb += eb[k]}
		ma /= f64(m); mb /= f64(m)
		va, vb := 0.0, 0.0
		for k in 0 ..< m {va += (ea[k]-ma)*(ea[k]-ma); vb += (eb[k]-mb)*(eb[k]-mb)}
		norm := math.sqrt(va * vb)
		if norm <= 0 {continue}

		best, best_lag, zero := -2.0, 0, 0.0
		max_lag := min(m / 3, 400)
		for lag := -max_lag; lag <= max_lag; lag += 1 {
			s := 0.0
			for k in 0 ..< m {
				j := k + lag
				if j < 0 || j >= m {continue}
				s += (ea[k]-ma) * (eb[j]-mb)
			}
			c := s / norm
			if lag == 0 {zero = c}
			if c > best {best = c; best_lag = lag}
		}
		fmt.printfln("%8v %10v %12v %12v %12v",
			v, dec2(hz), dec1(f64(best_lag) * 10.0), dec3(best), dec3(zero))
		free_all(context.temp_allocator)
	}
}
