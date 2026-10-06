// s1probe noiseprobe - what oscillator 2's noise does under hard sync.
//
// Two claims about the reference need settling before this engine copies them,
// and neither is in the English manual:
//
//   - The changelog for v1.05a lists "modify sync noise reset" (the Japanese
//     readme: "Sync時のノイズリセット方法に問題があったのを修正" -- the noise
//     reset method during sync was wrong and was fixed). That says a synced
//     noise oscillator *is* reset, which turns it into a repeating waveform at
//     oscillator 1's period rather than an endless fresh stream. It does not say
//     how strictly it repeats.
//   - Noise has no pitch, so oscillator 2's pitch controls and every modulation
//     routed at them should leave the output alone. That is a prediction, not
//     documentation, and the mod wheel, the modulation envelope and both LFOs
//     all reach oscillator 2's pitch.
//
// So this measures three things on the reference itself:
//
//   A. repeatability -- is a noise render reproducible at all across two fresh
//      plugin loads? Nothing below means anything if it is not.
//   B. periodicity -- normalised autocorrelation of the render, searched over a
//      range of lags. A reset stream correlates at oscillator 1's period; a free
//      stream correlates nowhere.
//   C. invariance -- every oscillator-2 pitch route driven to an extreme, each
//      compared against the same patch with that route neutral.
//
// Usage:
//   s1probe noiseprobe [dll] [--note <n>] [--notes <list>] [--seconds <s>] [--dump]
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import cpatch "../../src/patch"

// The two sync settings, as a variable because Odin will not range over a
// literal array.
noiseprobe_sync_states := [2]bool{false, true}

// Long enough that the autocorrelation window spans many cycles of the lowest
// note probed, short enough to keep a dozen renders quick.
NOISEPROBE_SECONDS :: 1.0

// The analysis window skips the attack, where the amplifier envelope is still
// moving and would colour the correlation.
NOISEPROBE_SKIP_SECONDS :: 0.15

// The base patch: oscillator 2 alone, as noise, through an open filter and a
// flat gate, with oscillator 1 still running as the sync master.
noiseprobe_patch :: proc(sync: bool) -> cpatch.Patch {
	p := neutral_probe_patch()

	// Parameter 1 is display-keyed, so the stored integer is the display id.
	// Display "4" is the noise state; see docs/reference-notes.md on why the
	// manual's listing order is not the state order.
	set_param(&p, 1, 4) // oscillator 2 = noise
	set_param(&p, 0, 1) // oscillator 1 = saw, so the master has a clean wrap
	set_param(&p, 5, 127) // mix hard right: oscillator 2 only
	set_param(&p, 6, sync ? 1 : 0)
	set_param(&p, 4, 1) // oscillator 2 key tracking on
	// Both oscillator-2 pitch controls pinned to their centre display, so the
	// invariance table's variants are departures from a known zero rather than
	// from the plugin's default, which is "+04 cent" on parameter 3.
	set_param(&p, 2, 64) // display "00" semitones
	set_param(&p, 3, 64) // display "00 cent"
	set_param(&p, 19, 127) // filter wide open, so nothing shapes the noise
	set_param(&p, 29, 100) // gain
	set_param(&p, 95, 0) // sub oscillator silent

	// Parameter 91 position 0 is free-running start phase; any other position
	// pins it. Pinned, so a render is a function of the patch and not of how
	// long the plugin has been loaded.
	set_param(&p, 91, 1)

	return p
}

// Normalised autocorrelation at one lag, on -1..1.
noiseprobe_autocorr :: proc(x: []f32, lag: int) -> f64 {
	n := len(x) - lag
	if lag <= 0 || n <= 0 {
		return 0
	}
	num, ea, eb := 0.0, 0.0, 0.0
	for i in 0 ..< n {
		u := f64(x[i])
		v := f64(x[i + lag])
		num += u * v
		ea += u * u
		eb += v * v
	}
	if ea <= 0 || eb <= 0 {
		return 0
	}
	return num / math.sqrt(ea * eb)
}

// The strongest correlation over a lag range, and where it sits.
noiseprobe_best_lag :: proc(x: []f32, lo, hi: int) -> (best: f64, at: int) {
	best = -2
	for lag in max(lo, 1) ..= hi {
		r := noiseprobe_autocorr(x, lag)
		if r > best {
			best = r
			at = lag
		}
	}
	return
}

// The shortest lag whose correlation clears `threshold`.
//
// Reported instead of the strongest lag because every multiple of a repeat
// period correlates, and the strongest of them is decided by how close that
// multiple lands to a whole sample rather than by the period itself. At note 60
// the period is 183.47 samples, so lag 367 is 0.06 samples out where lag 183 is
// 0.47 out, and the second harmonic of the period wins a search for the maximum.
// The first crossing is the fundamental.
noiseprobe_first_lag :: proc(x: []f32, lo, hi: int, threshold: f64) -> (r: f64, at: int) {
	for lag in max(lo, 1) ..= hi {
		v := noiseprobe_autocorr(x, lag)
		if v >= threshold {
			return v, lag
		}
	}
	return 0, 0
}

// How far apart two renders are, sample for sample.
noiseprobe_diff :: proc(a, b: []f32) -> (max_abs: f64, rms: f64) {
	n := min(len(a), len(b))
	if n == 0 {
		return 0, 0
	}
	sum := 0.0
	for i in 0 ..< n {
		d := abs(f64(a[i]) - f64(b[i]))
		max_abs = max(max_abs, d)
		sum += d * d
	}
	return max_abs, math.sqrt(sum / f64(n))
}

// The mid channel of a render, from the end of the attack onwards. The caller
// owns the returned slice.
noiseprobe_window :: proc(audio: []f32) -> []f32 {
	mid, side := split_mid_side(audio, 2)
	delete(side)
	skip := int(NOISEPROBE_SKIP_SECONDS * f64(SAMPLE_RATE))
	if skip >= len(mid) {
		return mid
	}
	w := make([]f32, len(mid) - skip)
	copy(w, mid[skip:])
	delete(mid)
	return w
}

noiseprobe_hz :: proc(note: int) -> f64 {
	return 440.0 * math.pow(2.0, f64(note - 69) / 12.0)
}

// One named variant of the base patch, used by the invariance table.
Noise_Variant :: struct {
	label: string,
	apply: proc(p: ^cpatch.Patch),
}

cmd_noiseprobe :: proc(dll: string, notes: []int, seconds: f64, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	dump_indices := []int{0, 1, 2, 3, 4, 5, 6, 10, 11, 19, 29, 41, 44, 57, 71, 91}
	dumped := !dump

	note := notes[0]
	f0 := noiseprobe_hz(note)
	period := f64(SAMPLE_RATE) / f0

	fmt.printfln(
		"noiseprobe: oscillator 2 = noise, mixed alone, filter open, %v s per render",
		dec1(seconds),
	)
	fmt.printfln("  note %v is %v Hz, one oscillator-1 cycle is %v samples at %v Hz",
		note, dec1(f0), dec1(period), SAMPLE_RATE)
	fmt.println()

	// -- A. is a noise render reproducible at all? ---------------------------

	fmt.println("A. repeatability -- the same patch rendered twice, each in a fresh plugin load")
	fmt.printfln("   %-10v %14v %14v", "sync", "max|diff|", "rms diff")
	fmt.printfln("   %v", strings.repeat("-", 40, context.temp_allocator))

	repeatable: [2]bool
	for sync_on, si in noiseprobe_sync_states {
		p := noiseprobe_patch(sync_on)
		a := probe_render(dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices)
		b := probe_render(dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices)
		if a == nil || b == nil {
			fmt.eprintln("   render failed")
			os.exit(1)
		}
		max_abs, rms := noiseprobe_diff(a, b)
		repeatable[si] = max_abs == 0
		fmt.printfln("   %-10v %14v %14v", sync_on ? "on" : "off", dec5(max_abs), dec5(rms))
		delete(a)
		delete(b)
	}
	fmt.println()
	if !repeatable[0] || !repeatable[1] {
		fmt.println("   NOTE: renders are not bit-identical, so section C's diffs carry that floor.")
		fmt.println()
	}

	// -- B. does the stream repeat, and at what period? ----------------------

	fmt.println("B. periodicity -- normalised autocorrelation of the held note, reference")
	fmt.println("   against this engine on the same patch")
	fmt.printfln("   %-6v %-8v %9v %10v %10v %9v %11v",
		"note", "sync", "osc1 lag", "ref r@osc1", "our r@osc1", "ref 1st lag", "our 1st lag")
	fmt.printfln("   %v", strings.repeat("-", 72, context.temp_allocator))

	for n in notes {
		nf0 := noiseprobe_hz(n)
		nperiod := f64(SAMPLE_RATE) / nf0
		// Search a wide band around the expected period so a wrong period is
		// reported rather than missed.
		lo := int(nperiod * 0.4)
		hi := int(nperiod * 3.0)
		for sync_on in noiseprobe_sync_states {
			p := noiseprobe_patch(sync_on)
			audio := probe_render(dll, &p, pristine, work, u8(n), seconds, &dumped, dump_indices)
			if audio == nil {
				continue
			}
			w := noiseprobe_window(audio)
			delete(audio)

			at_period := noiseprobe_autocorr(w, int(math.round(nperiod)))
			_, first_at := noiseprobe_first_lag(w, lo, hi, 0.5)

			// The same patch through this engine, so the two columns are a
			// comparison and not two separately quoted numbers.
			ours := render_ours(p, n)
			our_w := noiseprobe_window(ours)
			delete(ours)
			our_at_period := noiseprobe_autocorr(our_w, int(math.round(nperiod)))
			_, our_first_at := noiseprobe_first_lag(our_w, lo, hi, 0.5)
			delete(our_w)

			fmt.printfln("   %-6v %-8v %9v %10v %10v %9v %11v",
				n, sync_on ? "on" : "off",
				dec1(nperiod), dec5(at_period), dec5(our_at_period),
				first_at, our_first_at)
			delete(w)
			free_all(context.temp_allocator)
		}
	}
	fmt.println()
	fmt.println("   A reset stream correlates at oscillator 1's own period; a free stream")
	fmt.println("   correlates nowhere, so no lag in the search band reaches 0.5 and the")
	fmt.println("   '1st lag' column stays at 0. The two engines agreeing on that lag is the")
	fmt.println("   claim: the repeat tracks the master, octave for octave.")
	fmt.println()

	// -- C. does anything aimed at oscillator 2's pitch move the noise? ------

	variants := []Noise_Variant {
		// Parameters 2 and 3 are direct state indices, not display-keyed, so the
		// stored value is a position in a 128-entry table centred on 64. The
		// labels below are the displays those positions actually resolve to.
		{"osc2 pitch +11 st", proc(p: ^cpatch.Patch) {set_param(p, 2, 76)}},
		{"osc2 pitch -11 st", proc(p: ^cpatch.Patch) {set_param(p, 2, 52)}},
		{"osc2 pitch -60 st", proc(p: ^cpatch.Patch) {set_param(p, 2, 0)}},
		{"osc2 fine +34 cent", proc(p: ^cpatch.Patch) {set_param(p, 3, 100)}},
		{"osc2 track off", proc(p: ^cpatch.Patch) {set_param(p, 4, 0)}},
		{
			"mod env -> osc2 pitch",
			proc(p: ^cpatch.Patch) {
				set_param(p, 10, 1) // modulation envelope on
				set_param(p, 71, 0) // destination: oscillator 2 pitch
				set_param(p, 11, 127) // amount, display "+63"
				set_param(p, 12, 0) // instant attack
				set_param(p, 13, 100) // a decay long enough to sweep the note
			},
		},
		{
			"lfo1 -> osc2 pitch",
			proc(p: ^cpatch.Patch) {
				set_param(p, 57, 1) // lfo1 on
				set_param(p, 41, 1) // destination display "1": oscillator 2 pitch
				set_param(p, 42, 2) // a shape that sweeps rather than steps
				set_param(p, 43, 80) // a rate well inside the render
				set_param(p, 44, 127) // full depth
			},
		},
	}

	fmt.println("C. invariance -- each oscillator-2 pitch route at an extreme, against the")
	fmt.println("   same patch with that route neutral")
	fmt.printfln("   %-24v %14v %14v %14v %14v",
		"variant", "off max|d|", "off rms", "on max|d|", "on rms")
	fmt.printfln("   %v", strings.repeat("-", 84, context.temp_allocator))

	baselines: [2][]f32
	for sync_on, si in noiseprobe_sync_states {
		p := noiseprobe_patch(sync_on)
		baselines[si] = probe_render(
			dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices,
		)
	}
	defer for b in baselines {
		delete(b)
	}

	for v in variants {
		cells: [2][2]f64
		for sync_on, si in noiseprobe_sync_states {
			p := noiseprobe_patch(sync_on)
			v.apply(&p)
			audio := probe_render(
				dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices,
			)
			if audio == nil || baselines[si] == nil {
				continue
			}
			m, r := noiseprobe_diff(baselines[si], audio)
			cells[si] = {m, r}
			delete(audio)
		}
		fmt.printfln("   %-24v %14v %14v %14v %14v",
			v.label,
			dec5(cells[0][0]), dec5(cells[0][1]),
			dec5(cells[1][0]), dec5(cells[1][1]))
		free_all(context.temp_allocator)
	}

	fmt.println()
	fmt.println("   A zero row is a route that does not reach the noise output. For contrast,")
	fmt.println("   the same variants are rendered below with oscillator 2 set to a saw, where")
	fmt.println("   every one of them is supposed to move the sound.")
	fmt.println()

	// The control. Without it, a column of zeros is as good an account of "the
	// probe never changed the parameter" as of "the parameter does nothing".
	fmt.printfln("   %-24v %14v %14v", "variant (osc2 = saw)", "off max|d|", "on max|d|")
	fmt.printfln("   %v", strings.repeat("-", 54, context.temp_allocator))

	saw_baselines: [2][]f32
	for sync_on, si in noiseprobe_sync_states {
		p := noiseprobe_patch(sync_on)
		set_param(&p, 1, 1) // oscillator 2 = saw
		saw_baselines[si] = probe_render(
			dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices,
		)
	}
	defer for b in saw_baselines {
		delete(b)
	}

	for v in variants {
		cells: [2]f64
		for sync_on, si in noiseprobe_sync_states {
			p := noiseprobe_patch(sync_on)
			set_param(&p, 1, 1)
			v.apply(&p)
			audio := probe_render(
				dll, &p, pristine, work, u8(note), seconds, &dumped, dump_indices,
			)
			if audio == nil || saw_baselines[si] == nil {
				continue
			}
			m, _ := noiseprobe_diff(saw_baselines[si], audio)
			cells[si] = m
			delete(audio)
		}
		fmt.printfln("   %-24v %14v %14v", v.label, dec5(cells[0]), dec5(cells[1]))
		free_all(context.temp_allocator)
	}
}

// --------------------------------------------------------------- arguments

noiseprobe_parse_notes :: proc(s: string) -> []int {
	out: [dynamic]int
	for field in strings.split(s, ",", context.temp_allocator) {
		trimmed := strings.trim_space(field)
		if trimmed == "" {
			continue
		}
		if v, ok := strconv.parse_int(trimmed); ok {
			append(&out, clamp(v, 0, 127))
		}
	}
	return out[:]
}
