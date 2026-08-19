// s1probe chorusdepth - measure the chorus's tap excursion against a *tone*,
// at any rate, and compare the two engines.
//
// The instrument docs/null-test.md says is missing. `chorusprobe` reads the
// depth off the side signal's pitch wobble, which needs the two channels' taps
// to differ, and returns nothing at all at the slow rates the factory bank
// actually uses. `chorustrack` autocorrelates noise and reports a sweep rate of
// 5.10 Hz where the true rate is 0.99, so its excursion figures cannot be
// trusted there either. Neither can answer whether this engine's chorus is as
// deep as the reference's at stored depth 64 and 0.99 Hz, which is exactly the
// configuration three bank patches regress on.
//
//   s1probe chorusdepth [dll] [--values <depths>] [--rate <n>] [--delay <n>]
//                              [--note <n>] [--seconds <n>]
//
// Method. A swept delay tap is a Doppler shift, and for a tone the relationship
// is closed-form rather than statistical. With
//
//     D(t) = centre + swing * sin(2*pi*r*t)
//
// the output phase is 2*pi*f0*(t - D(t)), so the instantaneous frequency is
//
//     f(t) = f0 * (1 - dD/dt) = f0 * (1 - swing * 2*pi*r * cos(2*pi*r*t))
//
// and the peak deviation gives the excursion back exactly:
//
//     swing = peak_deviation / (f0 * 2*pi*r)
//
// Two things make that measurable in practice.
//
// **The wet is isolated by subtraction.** The chorus always sums its tap onto an
// unattenuated dry signal, so no parameter setting yields the tap alone. Rendering
// the same patch twice -- once with parameter 66 on, once off -- and subtracting
// gives exactly the wet contribution, because everything upstream is deterministic
// for a sine source. Type 1 is used so that wet is a *single* swept tap and the
// closed form above applies without averaging two of them.
//
// **The frequency is read by quadrature demodulation, not by a transform.** The
// signal is multiplied by cos and -sin at the nominal f0, low-passed to drop the
// sum term at 2*f0, and the arctangent of the result is the phase relative to a
// fixed reference. Differentiating that phase gives the deviation directly. A
// transform would have to resolve sidebands spaced by the sweep rate -- 0.99 Hz,
// a third of one bin at this project's FFT size -- which is precisely why the
// existing probes fail at slow rates. Demodulation does not care about the rate
// at all; it only has to be slow next to f0.
package s1probe

import "core:fmt"
import "core:math"

import cpatch "../../src/patch"
import sdsp "../../src/dsp"
import sengine "../../src/engine"

CHORUS_DEPTH_NOTE :: u8(72)

chorus_depth_patch :: proc(depth, rate, delay_time, level: int, chorus_on: bool) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // osc1: sine, alone -- the closed form assumes one tone
	set_param(&p, 5, 0)
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 20, 0)
	set_param(&p, 29, 100)
	set_param(&p, 65, 0) // delay off
	set_param(&p, 77, 0) // effect unit off
	set_param(&p, 66, chorus_on ? 1 : 0)
	set_param(&p, 64, 1) // type 1: one tap, mono
	set_param(&p, 52, delay_time)
	set_param(&p, 53, depth)
	set_param(&p, 54, rate)
	set_param(&p, 55, 64) // feedback centred, display "0 %": a single pass
	set_param(&p, 56, level)
	return p
}

// The peak-to-peak excursion of the tone's *phase*, in radians.
//
// Differentiating the phase into a frequency, which the header's closed form
// invites, does not survive contact with the data: one sample of a 0.99 Hz
// sweep moves the phase by around a millionth of a radian, which is below the
// arctangent's own noise, so the derivative is noise multiplied by the sample
// rate. Measured that way a *static* tap read as 135 ms of swing on a 15 ms
// delay line.
//
// The phase does not need differentiating. The demodulated phase relative to a
// fixed f0 reference is
//
//     phi(t) = -2*pi*f0*D(t)
//
// so the delay is already in it, scaled by a constant. The peak-to-peak swing
// of phi over a whole sweep is 2*pi*f0*(2*swing), and
//
//     swing = (phi_max - phi_min) / (4*pi*f0)
//
// with no derivative anywhere. A static tap gives a constant phase and reads
// zero, which is the property the derivative version failed.
//
// A linear trend is removed first. It is there whenever the played note is not
// exactly the frequency being demodulated at -- the residual is a phase ramp --
// and it would otherwise be counted as excursion.
chorus_depth_phase_excursion :: proc(wet: []f32, f0: f64, from: int) -> (rad: f64, ok: bool) {
	n := len(wet)
	if n <= from + 4096 || f0 <= 0 {
		return 0, false
	}

	energy := 0.0
	for i in from ..< n {
		energy += f64(wet[i]) * f64(wet[i])
	}
	if math.sqrt(energy / f64(n - from)) < 1.0e-6 {
		return 0, false
	}

	m := n - from
	w := 2.0 * math.PI * f0 / f64(SAMPLE_RATE)
	iq := make([]f64, m * 2)
	defer delete(iq)
	for k in 0 ..< m {
		phase := w * f64(from + k)
		iq[k * 2] = f64(wet[from + k]) * math.cos(phase)
		iq[k * 2 + 1] = -f64(wet[from + k]) * math.sin(phase)
	}

	// Boxcar over one period of f0, twice: removes the image at 2*f0 while
	// passing any sweep rate this is used at.
	span := max(int(f64(SAMPLE_RATE) / f0), 2)
	smooth :: proc(iq: []f64, m, span, comp: int) {
		acc := 0.0
		out := make([]f64, m)
		defer delete(out)
		for k in 0 ..< m {
			acc += iq[k * 2 + comp]
			if k >= span {
				acc -= iq[(k - span) * 2 + comp]
			}
			out[k] = acc / f64(min(k + 1, span))
		}
		for k in 0 ..< m {
			iq[k * 2 + comp] = out[k]
		}
	}
	for pass in 0 ..< 2 {
		smooth(iq, m, span, 0)
		smooth(iq, m, span, 1)
	}

	settle := span * 4
	if m <= settle + 1024 {
		return 0, false
	}
	count := m - settle
	phase := make([]f64, count)
	defer delete(phase)

	// Unwrapped, so an excursion wider than a turn is still one number.
	prev := math.atan2(iq[settle * 2 + 1], iq[settle * 2])
	acc := prev
	phase[0] = acc
	for k in 1 ..< count {
		cur := math.atan2(iq[(settle + k) * 2 + 1], iq[(settle + k) * 2])
		d := cur - prev
		for d > math.PI {d -= 2.0 * math.PI}
		for d < -math.PI {d += 2.0 * math.PI}
		acc += d
		phase[k] = acc
		prev = cur
	}

	// Remove the linear trend: a tuning offset between the note and f0 shows up
	// as a ramp and is not excursion.
	sx, sy, sxx, sxy := 0.0, 0.0, 0.0, 0.0
	for k in 0 ..< count {
		x := f64(k)
		sx += x
		sy += phase[k]
		sxx += x * x
		sxy += x * phase[k]
	}
	nf := f64(count)
	denom := nf * sxx - sx * sx
	slope := 0.0
	intercept := sy / nf
	if abs(denom) > 1.0e-9 {
		slope = (nf * sxy - sx * sy) / denom
		intercept = (sy - slope * sx) / nf
	}

	lo, hi := 1.0e30, -1.0e30
	for k in 0 ..< count {
		v := phase[k] - (slope * f64(k) + intercept)
		if v < lo {lo = v}
		if v > hi {hi = v}
	}
	if lo > hi {
		return 0, false
	}
	return hi - lo, true
}

// One engine's excursion at one setting, in milliseconds.
chorus_depth_swing_ms :: proc(on, off: []f32, f0, rate_hz: f64) -> (ms: f64, ok: bool) {
	n := min(len(on), len(off)) / 2
	// Only the held portion. Past the note off the tone decays into the noise
	// floor, where the demodulated phase is meaningless and wanders without
	// bound -- and an unbounded wander is exactly what a peak-to-peak excursion
	// measurement will happily report as a very deep chorus.
	if g_hold_frames > 0 && g_hold_frames < n {
		n = g_hold_frames
	}
	n -= min(n / 20, 4800)
	if n < 8192 {
		return 0, false
	}
	// The wet alone: the same render with the chorus switched off, subtracted.
	wet := make([]f32, n)
	defer delete(wet)
	for i in 0 ..< n {
		wet[i] = on[i * 2] - off[i * 2]
	}
	from := min(int(0.5 * f64(SAMPLE_RATE)), n / 4)
	rad, rad_ok := chorus_depth_phase_excursion(wet, f0, from)
	if !rad_ok {
		return 0, false
	}
	// phi peak-to-peak = 2*pi*f0*(2*swing)
	return rad / (4.0 * math.PI * f0) * 1000.0, true
}

cmd_chorusdepth :: proc(dll: string, values: []int, rate, delay_time: int, note: u8, seconds: f64) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	f0 := f64(sdsp.note_to_hz(f32(note)))
	rate_hz := f64(sengine.display_number(54, rate, 1.0))
	centre_ms := f64(sengine.display_number(52, delay_time, 15.0))

	fmt.printfln("chorusdepth: rate %v (%v Hz), delay %v (%v ms centre), note %v (%v Hz), %v s",
		rate, dec2(rate_hz), delay_time, dec2(centre_ms), note, dec1(f0), dec1(seconds))
	fmt.println("  type 1, one swept tap; wet isolated by subtracting a chorus-off render")
	fmt.println("  swing is the tap excursion either side of centre, from the pitch it Dopplers")
	fmt.println()
	fmt.printfln("%8v %12v %12v %12v %12v %10v",
		"stored", "ref swing", "our swing", "ref depth", "our depth", "ratio")

	for v in values {
		on_p := chorus_depth_patch(v, rate, delay_time, 127, true)
		off_p := chorus_depth_patch(v, rate, delay_time, 127, false)

		ref_on := probe_render(dll, &on_p, pristine, work, note, seconds, &dumped, nil)
		ref_off := probe_render(dll, &off_p, pristine, work, note, seconds, &dumped, nil)
		our_on := render_ours(on_p, int(note))
		our_off := render_ours(off_p, int(note))
		defer delete(ref_on)
		defer delete(ref_off)
		defer delete(our_on)
		defer delete(our_off)
		if ref_on == nil || ref_off == nil {
			continue
		}

		ref_ms, ref_ok := chorus_depth_swing_ms(ref_on, ref_off, f0, rate_hz)
		our_ms, our_ok := chorus_depth_swing_ms(our_on, our_off, f0, rate_hz)

		ref_frac := centre_ms > 0 ? ref_ms / centre_ms : 0
		our_frac := centre_ms > 0 ? our_ms / centre_ms : 0
		ratio := ref_ms > 1.0e-6 ? our_ms / ref_ms : 0

		fmt.printfln("%8v %12v %12v %12v %12v %10v",
			v,
			ref_ok ? dec3(ref_ms) : "-",
			our_ok ? dec3(our_ms) : "-",
			ref_ok ? dec4(ref_frac) : "-",
			our_ok ? dec4(our_frac) : "-",
			ref_ok && our_ok ? dec2(ratio) : "-")
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("`depth` is the excursion as a fraction of the centre delay, which is the")
	fmt.println("quantity `binding.odin`'s CHORUS_DEPTH_K curve produces. `ratio` is ours")
	fmt.println("over the reference's: 1.00 is a match, and anything else is the defect.")
}
