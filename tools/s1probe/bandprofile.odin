package s1probe

// Where in the spectrum we differ from the reference, averaged over patches.
//
// The null test reports one number per patch for timbre and the frequency of its
// single worst band. That is enough to say a patch is wrong and not enough to say
// what is wrong with it, and the two are different questions: a hundred patches whose
// worst band happens to sit below 600 Hz might each be wrong for their own reason, or
// they might all be wrong in the same direction for one reason.
//
// This averages the *signed* band difference across patches. Both spectra are
// normalised to equal energy first, exactly as the spectral metric does, so what comes
// out is a statement about balance rather than about level -- which is already
// measured separately and, since the gain table was fixed, largely settled.
//
// A flat profile would mean the remaining timbre error is patch-specific. A profile
// with a consistent shape means there is one more systematic thing to find.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import cpatch "../../src/patch"

BAND_PROFILE_BANDS :: 9
BAND_PROFILE_LO_HZ :: 31.25

band_profile_index :: proc(hz: f64) -> int {
	if hz < BAND_PROFILE_LO_HZ {
		return -1
	}
	b := int(math.log2(hz / BAND_PROFILE_LO_HZ))
	if b < 0 || b >= BAND_PROFILE_BANDS {
		return -1
	}
	return b
}

// Energy-normalised band levels in dB, or ok = false when there is nothing to weigh.
band_profile_of :: proc(audio: []f32) -> (levels: [BAND_PROFILE_BANDS]f64, ok: bool) {
	if len(audio) < FFT_SIZE * 4 {
		return
	}
	held := min(g_hold_frames, len(audio) / 2)
	if held < FFT_SIZE * 2 {
		return
	}
	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)

	from := min(int(0.1 * f64(SAMPLE_RATE)), held / 4)
	power := welch_power(mid, from, held)
	defer delete(power)
	if power == nil {
		return
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	sums: [BAND_PROFILE_BANDS]f64
	total := 0.0
	for k in 1 ..< len(power) {
		hz := f64(k) * bin_hz
		if hz > BAND_HI_HZ {break}
		b := band_profile_index(hz)
		if b < 0 {continue}
		sums[b] += power[k]
		total += power[k]
	}
	if total <= 0 {
		return
	}
	for b in 0 ..< BAND_PROFILE_BANDS {
		levels[b] = power_db(sums[b] / total)
	}
	return levels, true
}

cmd_bandprofile :: proc(dll: string, dir: string, note: int, limit: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	set_compare_timing(COMPARE_BLOCK_DEFAULT)

	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintfln("bandprofile: cannot read %q", dir)
		os.exit(1)
	}
	defer delete(entries)

	totals: [BAND_PROFILE_BANDS]f64
	absolute: [BAND_PROFILE_BANDS]f64
	counted := 0
	full_sum, content_sum, band_frac := 0.0, 0.0, 0.0
	content_n := 0

	for info in entries {
		if !strings.has_suffix(info.name, ".sy1") {continue}
		if limit > 0 && counted >= limit {break}
		// The patches that kill the reference outright, as elsewhere.
		if info.name == "095.sy1" || info.name == "098.sy1" || info.name == "100.sy1" ||
		   info.name == "101.sy1" || info.name == "106.sy1" {
			continue
		}

		data, read_err := os.read_entire_file(info.fullpath, context.allocator)
		if read_err != nil {continue}
		defer delete(data)
		parsed, perr := cpatch.parse_sy1(data)
		if perr != .None {continue}

		ref, _, ok := render_reference_fresh(dll, &parsed, pristine, work, u8(note))
		defer delete(ref)
		if !ok || ref == nil {continue}
		ours := render_ours(parsed, note)
		defer delete(ours)
		if ours == nil {continue}

		ref_levels, ok1 := band_profile_of(ref)
		our_levels, ok2 := band_profile_of(ours)
		if !ok1 || !ok2 {continue}

		for b in 0 ..< BAND_PROFILE_BANDS {
			d := our_levels[b] - ref_levels[b]
			totals[b] += d
			absolute[b] += abs(d)
		}
		counted += 1

		// The same timbre distance the null test reports, and the same distance
		// computed only over bands where the reference actually has something.
		//
		// At note 60 a patch's fundamental is 261 Hz, so about a fifth of the
		// 1/6-octave bands from 20 Hz up lie below it and hold nothing but each
		// engine's own residue. The metric averages every band equally, so a
		// difference between two noise floors scores exactly like a difference
		// between two harmonics.
		{
			rb, rc, rok := probe_band_levels(ref)
			defer delete(rb)
			defer delete(rc)
			ob, oc, ook := probe_band_levels(ours)
			defer delete(ob)
			defer delete(oc)
			if rok && ook && len(rb) == len(ob) {
				full, _, _, _ := band_distance_db(rb, ob, rc)
				full_sum += full

				// Selectivity, when a single patch is being looked at.
				if limit == 1 {
					rf, rq, rok2 := peak_and_q(rb, rc)
					of2, oq, ook2 := peak_and_q(ob, oc)
					if rok2 {
						fmt.printfln("  reference peak %.0f Hz, Q %.2f", rf, rq)
					}
					if ook2 {
						fmt.printfln("  ours      peak %.0f Hz, Q %.2f", of2, oq)
					}
				}

				// Restricted: bands within 60 dB of the reference's loudest.
				peak := 0.0
				for v in rb {
					if v > peak {peak = v}
				}
				cut := peak * math.pow(f64(10.0), f64(-6.0))
				rt, ot := 0.0, 0.0
				for i in 0 ..< len(rb) {
					if rb[i] > 0 {rt += rb[i]}
					if ob[i] > 0 {ot += ob[i]}
				}
				if rt > 0 && ot > 0 {
					sum, used := 0.0, 0
					for i in 0 ..< len(rb) {
						if rb[i] < cut {continue}
						a := rb[i] / rt
						c := max(ob[i] / ot, 1.0e-14)
						sum += abs(power_db(a) - power_db(c))
						used += 1
					}
					if used > 0 {
						content_sum += sum / f64(used)
						band_frac += f64(used) / f64(len(rb))
						content_n += 1
					}
				}
			}
		}
	}

	if counted == 0 {
		fmt.eprintln("bandprofile: nothing measured")
		return
	}

	fmt.printfln("band profile over %d patches at note %d, energy-normalised", counted, note)
	fmt.println("  a signed mean near zero with a large absolute mean means scatter,")
	fmt.println("  a signed mean that tracks the absolute one means a systematic tilt")
	fmt.println()
	fmt.printf("  band centre Hz")
	for b in 0 ..< BAND_PROFILE_BANDS {
		fmt.printf(" %s", pad_left(dec0(BAND_PROFILE_LO_HZ * math.pow(2.0, f64(b) + 0.5)), 7))
	}
	fmt.println()
	fmt.printf("  signed mean  ")
	for b in 0 ..< BAND_PROFILE_BANDS {
		fmt.printf(" %s", pad_left(sdec1(totals[b] / f64(counted)), 7))
	}
	fmt.println()
	fmt.printf("  absolute mean")
	for b in 0 ..< BAND_PROFILE_BANDS {
		fmt.printf(" %s", pad_left(dec1(absolute[b] / f64(counted)), 7))
	}
	fmt.println()

	if content_n > 0 {
		fmt.println()
		fmt.printfln(
			"  timbre distance, all bands        %.2f dB",
			full_sum / f64(content_n),
		)
		fmt.printfln(
			"  timbre distance, bands with signal %.2f dB   (%.0f%% of bands kept)",
			content_sum / f64(content_n),
			100.0 * band_frac / f64(content_n),
		)
	}
}

// The resonant peak's centre and width, from a 1/6-octave response.
//
// Reported for both engines so a selectivity difference is a number rather than an
// impression. Q is the centre divided by the -3 dB width, which is the definition
// the filter's own resonance parameter is trying to set.
peak_and_q :: proc(bands, centres: []f64) -> (centre_hz, q: f64, ok: bool) {
	if len(bands) < 4 || len(bands) != len(centres) {
		return 0, 0, false
	}
	peak := 0
	for b in 1 ..< len(bands) {
		if bands[b] > bands[peak] {peak = b}
	}
	if bands[peak] <= 0 {
		return 0, 0, false
	}
	half := bands[peak] * 0.5 // -3 dB in power

	// Walk out either side to the half-power crossing, interpolating in log
	// frequency so the answer is not quantised to the band grid.
	lo := f64(0)
	for b := peak; b > 0; b -= 1 {
		if bands[b - 1] < half {
			t := (half - bands[b - 1]) / max(bands[b] - bands[b - 1], 1e-30)
			lo = centres[b - 1] * math.pow(centres[b] / centres[b - 1], t)
			break
		}
	}
	hi := f64(0)
	for b := peak; b < len(bands) - 1; b += 1 {
		if bands[b + 1] < half {
			t := (half - bands[b + 1]) / max(bands[b] - bands[b + 1], 1e-30)
			hi = centres[b + 1] / math.pow(centres[b + 1] / centres[b], t)
			break
		}
	}
	if lo <= 0 || hi <= lo {
		return centres[peak], 0, false
	}
	return centres[peak], centres[peak] / (hi - lo), true
}
