package s1probe

// Every resonance the phasers make, and where each one goes.
//
// Two instruments came before this and each answered one question and blocked on
// the next. The saw comb (`phaserprobe`) reads a whole transfer function from one
// render, which is what identified the section as resonant rather than notched --
// but its fundamental sets the lowest frequency it can see, and above ctl1 32 the
// resonance leaves it. The held tone (`phaserband`) has no such floor and found
// the resonances the comb had missed, which is what showed the count is the type
// index -- but it reports one number per note, so several resonances sweeping at
// once collapse into a single "band" that is really their union.
//
// What is left is the question the structure actually turns on: where is *each*
// resonance, and how does each one move. That needs the whole transfer function
// **and** time resolution, which is exactly the pair the earlier note called
// irreconcilable:
//
//   harmonics have to be resolvable, so a lower fundamental needs a longer FFT,
//   and a longer FFT smears a corner that is moving
//
// It is reconcilable, by moving the third variable. Nothing requires the sweep to
// run at a musical rate while it is being measured. At ctl2 = 16 the LFO period
// is about 19 seconds, so a 341 ms window sees the comb move less than two per
// cent of one cycle -- a static comb, in effect, photographed a hundred times
// across a sweep. The rate law is already measured and is independent of depth,
// so slowing it down changes nothing else about what is being read.
//
// The window is long enough to resolve a 16 Hz fundamental, so the whole comb is
// visible at once, from the 65 Hz resonance ph4 puts at the bottom to the 7 kHz
// one it puts at the top.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

// A power of two, and large: at note 12 the harmonics are 16.35 Hz apart and the
// bins have to separate them. 16384 gives 2.93 Hz bins, five and a half to a
// harmonic, and lasts 341 ms.
g_comb_fft := 16384

// The lowest note that carries a usable comb. Low on purpose: the fundamental is
// the resolution floor, and ph4's lowest resonance sits at 65 Hz.
COMB_NOTE :: 12

// Nothing above this is analysed.
//
// Set close to Nyquist rather than to the highest resonance seen so far, which
// is the mistake the depth table in this section already made once: at 13 kHz
// the deepest sweeps returned 12559 and 12672 Hz, both of them the ceiling
// rather than the sweep, and fourteen frames of the deepest returned nothing at
// all because the resonance had left the range being looked at.
COMB_TOP_HZ :: 20000.0

// A local maximum has to stand this far above the saddle on each side of it, and
// this far above the unprocessed spectrum, before it is a resonance rather than
// ripple. Both thresholds were needed: the first version used height alone and
// reported every wobble on the shoulder of a real peak.
COMB_PROMINENCE_DB :: 4.0
COMB_HEIGHT_DB :: 2.0

// More than a four-stage chain can produce, so overrunning it means the peak test
// is admitting something it should not.
COMB_MAX_PEAKS :: 12

Comb_Frame :: struct {
	ms:    f64,
	count: int,
	hz:    [COMB_MAX_PEAKS]f64,
	db:    [COMB_MAX_PEAKS]f64,
}

// The transfer function at one instant, sampled at every harmonic of the saw.
comb_transfer :: proc(
	on_mono: []f32,
	from: int,
	f0: f64,
	off_mean: []f64,
	re, im, power, scratch, out: []f64,
) -> bool {
	if from < 0 || from + g_comb_fft > len(on_mono) {
		return false
	}
	for i in 0 ..< g_comb_fft {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(g_comb_fft)))
		re[i] = f64(on_mono[from + i]) * w
		im[i] = 0
	}
	fft_forward(re, im)
	for k in 0 ..< len(power) {
		power[k] = re[k] * re[k] + im[k] * im[k]
	}

	bin_hz := f64(SAMPLE_RATE) / f64(g_comb_fft)
	for h in 0 ..< len(out) {
		hz := f64(h + 1) * f0
		centre := int(hz / bin_hz + 0.5)
		best := 0.0
		for b in max(centre - 1, 0) ..= min(centre + 1, len(power) - 1) {
			if power[b] > best {
				best = power[b]
			}
		}
		scratch[h] = best
		out[h] = off_mean[h] > 0 && best > 0 ? power_db(best / off_mean[h]) : -120.0
	}
	return true
}

// Local maxima with prominence, lowest first.
//
// Prominence rather than a bare threshold, and measured against the saddle on
// each side rather than the immediate neighbours: a resonance standing on the
// shoulder of a taller one has neighbours that are both lower than it while it is
// not a separate feature at all, and the immediate-neighbour test admits it.
comb_find_peaks :: proc(transfer: []f64, f0: f64, frame: ^Comb_Frame) {
	frame.count = 0
	for h in 1 ..< len(transfer) - 1 {
		if transfer[h] <= transfer[h - 1] || transfer[h] < transfer[h + 1] {
			continue
		}
		if transfer[h] < COMB_HEIGHT_DB {
			continue
		}

		left := transfer[h]
		for i := h - 1; i >= 0; i -= 1 {
			if transfer[i] > transfer[h] {
				break
			}
			if transfer[i] < left {
				left = transfer[i]
			}
		}
		right := transfer[h]
		for i := h + 1; i < len(transfer); i += 1 {
			if transfer[i] > transfer[h] {
				break
			}
			if transfer[i] < right {
				right = transfer[i]
			}
		}
		if transfer[h] - max(left, right) < COMB_PROMINENCE_DB {
			continue
		}

		if frame.count >= COMB_MAX_PEAKS {
			frame.count = COMB_MAX_PEAKS + 1
			return
		}
		frame.hz[frame.count] = phaser_interpolate(
			transfer[h - 1],
			transfer[h],
			transfer[h + 1],
			h,
			f0,
		)
		frame.db[frame.count] = transfer[h]
		frame.count += 1
	}
}

comb_analyse :: proc(off, on: []f32, f0: f64, harmonics: int) -> []Comb_Frame {
	off_mono := phaser_mono(off)
	defer delete(off_mono)
	on_mono := phaser_mono(on)
	defer delete(on_mono)

	re := make([]f64, g_comb_fft)
	defer delete(re)
	im := make([]f64, g_comb_fft)
	defer delete(im)
	power := make([]f64, g_comb_fft / 2 + 1)
	defer delete(power)
	scratch := make([]f64, harmonics)
	defer delete(scratch)
	transfer := make([]f64, harmonics)
	defer delete(transfer)

	// The unprocessed comb, averaged over the whole render. A saw is stationary,
	// so one average is a better denominator than a per-window one, which would
	// carry its own window noise into every reading.
	off_mean := make([]f64, harmonics)
	defer delete(off_mean)
	flat := make([]f64, harmonics)
	defer delete(flat)
	for i in 0 ..< harmonics {
		flat[i] = 1
	}
	count := 0
	hop := g_comb_fft / 2
	for from := 0; from + g_comb_fft <= len(off_mono); from += hop {
		if !comb_transfer(off_mono, from, f0, flat, re, im, power, scratch, transfer) {
			break
		}
		for h in 0 ..< harmonics {
			off_mean[h] += scratch[h]
		}
		count += 1
	}
	if count == 0 {
		return nil
	}
	for h in 0 ..< harmonics {
		off_mean[h] /= f64(count)
	}

	frames := make([dynamic]Comb_Frame, 0, 128)
	for from := 0; from + g_comb_fft <= len(on_mono); from += hop {
		if !comb_transfer(on_mono, from, f0, off_mean, re, im, power, scratch, transfer) {
			break
		}
		f := Comb_Frame {
			ms = f64(from) * 1000.0 / f64(SAMPLE_RATE),
		}
		comb_find_peaks(transfer, f0, &f)
		append(&frames, f)
	}
	return frames[:]
}

cmd_phasercomb :: proc(
	dll: string,
	type_state, ctl1, ctl2, level, gain: int,
	seconds: f64,
	show: bool,
	csv_path: string,
) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(seconds * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	f0 := 440.0 * math.pow(2.0, (f64(COMB_NOTE) - 69.0) / 12.0)
	harmonics := min(int(COMB_TOP_HZ / f0), g_comb_fft / 2 - 2)

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"phaser comb: %s (state %d) ctl1=%d ctl2=%d level=%d, saw at %.2f Hz, %d harmonics",
		name,
		type_state,
		ctl1,
		ctl2,
		level,
		f0,
		harmonics,
	)
	fmt.printfln(
		"  %d-point window (%.0f ms), %.1f s render",
		g_comb_fft,
		f64(g_comb_fft) * 1000.0 / f64(SAMPLE_RATE),
		seconds,
	)

	off_patch := phaser_probe_patch(false, type_state, ctl1, ctl2, level, gain)
	on_patch := phaser_probe_patch(true, type_state, ctl1, ctl2, level, gain)

	ref_off, _, ok1 := render_reference_fresh(dll, &off_patch, pristine, work, u8(COMB_NOTE))
	defer delete(ref_off)
	ref_on, _, ok2 := render_reference_fresh(dll, &on_patch, pristine, work, u8(COMB_NOTE))
	defer delete(ref_on)
	if !ok1 || !ok2 {
		fmt.eprintln("phasercomb: the reference would not render")
		os.exit(1)
	}
	ours_off := render_ours(off_patch, COMB_NOTE)
	defer delete(ours_off)
	ours_on := render_ours(on_patch, COMB_NOTE)
	defer delete(ours_on)

	ref := comb_analyse(ref_off, ref_on, f0, harmonics)
	defer delete(ref)
	ours := comb_analyse(ours_off, ours_on, f0, harmonics)
	defer delete(ours)
	if len(ref) == 0 {
		fmt.eprintln("phasercomb: nothing to analyse")
		os.exit(1)
	}

	report :: proc(label: string, frames: []Comb_Frame, show: bool) {
		if len(frames) == 0 {
			return
		}
		// How many resonances, as a histogram rather than an average: the count is
		// the structural reading and a mean of it would hide a frame that found
		// six where every other frame found four.
		hist: [COMB_MAX_PEAKS + 2]int
		for f in frames {
			hist[min(f.count, COMB_MAX_PEAKS + 1)] += 1
		}
		fmt.printfln("  -- %s, %d frames --", label, len(frames))
		fmt.printf("  resonances per frame:")
		for n in 0 ..= COMB_MAX_PEAKS + 1 {
			if hist[n] > 0 {
				fmt.printf(
					"  %s%d x%d",
					n > COMB_MAX_PEAKS ? ">" : "",
					min(n, COMB_MAX_PEAKS),
					hist[n],
				)
			}
		}
		fmt.println()

		// Each resonance tracked by its rank from the bottom. That is the right
		// key while the count is stable, and the count is printed above so a
		// reader can see whether it is.
		most := 0
		for f in frames {
			if f.count <= COMB_MAX_PEAKS && f.count > most {
				most = f.count
			}
		}
		if most == 0 {
			fmt.println("  no resonances found")
			return
		}
		// Does the render actually contain a whole sweep?
		//
		// This is the same trap the band probe fell into and it has to be caught
		// here rather than remembered: a render shorter than one LFO cycle returns
		// a monotone ramp, and its endpoints read as the sweep's extremes when they
		// are only where the recording stopped. It cost a depth curve once already
		// -- ctl1 16 read 0.79 octaves truncated against 1.28 measured over three
		// cycles. Counting the turning points of the lowest resonance's own
		// trajectory settles it, and two of them mean at least one full cycle was
		// seen between them.
		turns := 0
		{
			lo, hi := f64(1e18), f64(-1e18)
			for f in frames {
				if f.count == 0 || f.count > COMB_MAX_PEAKS {continue}
				lo = min(lo, f.hz[0])
				hi = max(hi, f.hz[0])
			}
			if hi > lo {
				// A reversal only counts once the trajectory has moved a tenth of
				// its own range back the other way, so ripple on a slow limb does
				// not read as a turning point.
				margin := (hi - lo) * 0.1
				rising := true
				extreme := f64(0)
				started := false
				for f in frames {
					if f.count == 0 || f.count > COMB_MAX_PEAKS {continue}
					v := f.hz[0]
					if !started {
						extreme, started = v, true
						continue
					}
					if rising {
						if v > extreme {extreme = v}
						if extreme - v > margin {
							turns += 1
							rising = false
							extreme = v
						}
					} else {
						if v < extreme {extreme = v}
						if v - extreme > margin {
							turns += 1
							rising = true
							extreme = v
						}
					}
				}
			}
		}
		if turns < 2 {
			fmt.printfln(
				"  WARNING: %d turning points in this render, so the sweep did not complete a",
				turns,
			)
			fmt.println(
				"  cycle and every span below is a lower bound. Lengthen the render or raise ctl2.",
			)
		}

		fmt.println("  rank      low       high     span     seen")
		for r in 0 ..< most {
			lo, hi := f64(1e18), f64(0)
			seen := 0
			for f in frames {
				if f.count <= r || f.count > COMB_MAX_PEAKS {
					continue
				}
				seen += 1
				if f.hz[r] < lo {
					lo = f.hz[r]
				}
				if f.hz[r] > hi {
					hi = f.hz[r]
				}
			}
			if seen == 0 {
				continue
			}
			fmt.printfln(
				"  %s  %s Hz  %s Hz  %s oct  %s/%d",
				pad_left(fmt.tprintf("%d", r + 1), 4),
				pad_left(dec1(lo), 8),
				pad_left(dec1(hi), 8),
				pad_left(dec2(lo > 0 && hi > 0 ? math.log2(hi / lo) : f64(0)), 6),
				pad_left(fmt.tprintf("%d", seen), 5),
				len(frames),
			)
		}

		if show {
			fmt.println("  every frame, lowest resonance first:")
			for f in frames {
				fmt.printf("  %s ms  n=%d ", pad_left(dec0(f.ms), 6), f.count)
				for i in 0 ..< min(f.count, COMB_MAX_PEAKS) {
					fmt.printf(" %s", pad_left(dec0(f.hz[i]), 6))
				}
				fmt.println()
			}
		}
	}

	report("reference", ref, show)
	report("ours", ours, show)

	if csv_path != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintln(&b, "engine,type,ctl1,ctl2,level,ms,rank,hz,db")
		emit :: proc(b: ^strings.Builder, engine: string, frames: []Comb_Frame, t, c1, c2, l: int) {
			for f in frames {
				for i in 0 ..< min(f.count, COMB_MAX_PEAKS) {
					fmt.sbprintfln(
						b,
						"%s,%d,%d,%d,%d,%.3f,%d,%.4f,%.4f",
						engine,
						t,
						c1,
						c2,
						l,
						f.ms,
						i + 1,
						f.hz[i],
						f.db[i],
					)
				}
			}
		}
		emit(&b, "reference", ref, type_state, ctl1, ctl2, level)
		emit(&b, "ours", ours, type_state, ctl1, ctl2, level)
		if os.write_entire_file(csv_path, transmute([]u8)strings.to_string(b)) != nil {
			fmt.eprintfln("phasercomb: could not write %s", csv_path)
		} else {
			fmt.printfln("  wrote %s", csv_path)
		}
	}
}
