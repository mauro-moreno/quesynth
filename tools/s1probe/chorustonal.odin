package s1probe

// The chorus's stereo behaviour on a real patch, band by band.
//
// This exists because the noise probe in chorusprobe.odin cannot see the defect it
// is asked about. Its width saturates above a depth of about 16 -- broadband noise
// decorrelates completely once the two taps differ by a fraction of a millisecond --
// so it reports an exact match against the reference while the bank reports the
// twelve four-tap patches sitting 0.33 short on width and 3.1 dB worse on envelope.
// A measurement that cannot distinguish the cases it is being used to choose between
// is not evidence, whatever it prints.
//
// Two things are different here.
//
// **The patch is real.** Every setting comes from the .sy1 file rather than being
// pinned: the wet level, the centre delay, the rate, the depth, the waveform, the
// filter. The affected patches turn out to cluster tightly -- all thirteen use delay
// 64 and rate 64, and eleven of the thirteen use depth 64 -- so what varies between
// them is mostly the wet level, which is exactly the axis a pinned probe destroys.
//
// **Width is reported per band.** One number cannot say *how* two channels differ, and
// the remaining defect is a question of how rather than how much. side/mid resolved by
// octave says whether our wet is too quiet everywhere, or decorrelated in the wrong
// part of the spectrum, or right in the middle and wrong at the edges -- three
// different bugs that a single figure reports identically.
//
// The chorus is isolated by rendering each engine twice, once with parameter 66 as the
// patch has it and once with it forced off. A patch can be wide for reasons that have
// nothing to do with the chorus -- unison pan spread, the delay's own stereo -- and
// without the second render those would be charged to this section.

import "core:fmt"
import "core:math"
import "core:os"
import cpatch "../../src/patch"

// Octaves rather than the 1/6-octave bands the null test uses. Fifty-odd columns of
// width readings is not a table anyone reads; eight is.
CHORUS_TONAL_BANDS :: 8
CHORUS_TONAL_LO_HZ :: 62.5

Chorus_Tonal :: struct {
	ok:       bool,
	width:    f64,
	mid_rms:  f64,
	// side/mid per octave band, and the mid level per band for context.
	band:     [CHORUS_TONAL_BANDS]f64,
	band_mid: [CHORUS_TONAL_BANDS]f64,
}

// Which octave band a frequency belongs to, or -1.
chorus_tonal_band :: proc(hz: f64) -> int {
	if hz < CHORUS_TONAL_LO_HZ {
		return -1
	}
	b := int(math.log2(hz / CHORUS_TONAL_LO_HZ))
	if b < 0 || b >= CHORUS_TONAL_BANDS {
		return -1
	}
	return b
}

analyse_chorus_tonal :: proc(audio: []f32) -> (out: Chorus_Tonal) {
	if len(audio) < FFT_SIZE * 4 {
		return
	}
	held := min(g_hold_frames, len(audio) / 2)
	if held < FFT_SIZE * 2 {
		return
	}

	mid := make([]f32, held)
	defer delete(mid)
	side := make([]f32, held)
	defer delete(side)
	for i in 0 ..< held {
		l := audio[i * 2]
		r := audio[i * 2 + 1]
		mid[i] = 0.5 * (l + r)
		side[i] = 0.5 * (l - r)
	}

	out.mid_rms = signal_rms(mid)
	m := signal_rms(mid)
	s := signal_rms(side)
	out.width = m > 0 ? s / m : 0

	// Skip the onset so the steady state is what is compared.
	from := min(int(0.1 * f64(SAMPLE_RATE)), held / 4)
	mid_power := welch_power(mid, from, held)
	defer delete(mid_power)
	side_power := welch_power(side, from, held)
	defer delete(side_power)
	if mid_power == nil || side_power == nil {
		return
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
	mid_sum: [CHORUS_TONAL_BANDS]f64
	side_sum: [CHORUS_TONAL_BANDS]f64
	for k in 1 ..< len(mid_power) {
		hz := f64(k) * bin_hz
		if hz > BAND_HI_HZ {break}
		b := chorus_tonal_band(hz)
		if b < 0 {continue}
		mid_sum[b] += mid_power[k]
		side_sum[b] += side_power[k]
	}
	for b in 0 ..< CHORUS_TONAL_BANDS {
		out.band[b] = mid_sum[b] > 0 ? math.sqrt(side_sum[b] / mid_sum[b]) : 0
		out.band_mid[b] = mid_sum[b]
	}

	out.ok = true
	return
}

cmd_choruspatch :: proc(dll: string, dir: string, names: []string, note: int, show_bands: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)

	fmt.printfln("choruspatch: the chorus on real patches, at note %d", note)
	fmt.println("  every setting is the patch's own; the chorus is isolated against a")
	fmt.println("  second render with parameter 66 forced off")
	fmt.println()
	fmt.println("patch        ref off  ref on   our off  our on   ours-ref   ref mid  our mid  mid dB")

	// Accumulated per-band totals across the patches, so a shape common to all of
	// them is visible rather than lost in per-patch noise.
	ref_band_total: [CHORUS_TONAL_BANDS]f64
	our_band_total: [CHORUS_TONAL_BANDS]f64
	counted := 0

	for name in names {
		path := fmt.tprintf("%v/%v", dir, name)
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {continue}
		defer delete(data)
		parsed, perr := cpatch.parse_sy1(data)
		if perr != .None {continue}

		off := parsed
		off.values[66] = 0

		ref_on_audio, _, ok1 := render_reference_fresh(dll, &parsed, pristine, work, u8(note))
		defer delete(ref_on_audio)
		ref_off_audio, _, ok2 := render_reference_fresh(dll, &off, pristine, work, u8(note))
		defer delete(ref_off_audio)
		if !ok1 || !ok2 {continue}

		our_on_audio := render_ours(parsed, note)
		defer delete(our_on_audio)
		our_off_audio := render_ours(off, note)
		defer delete(our_off_audio)

		ref_on := analyse_chorus_tonal(ref_on_audio)
		ref_off := analyse_chorus_tonal(ref_off_audio)
		our_on := analyse_chorus_tonal(our_on_audio)
		our_off := analyse_chorus_tonal(our_off_audio)
		if !ref_on.ok || !our_on.ok {continue}

		// The mid level as well as the width, because the two failures look identical
		// in a ratio: a wet signal that is too quiet and one that is not decorrelated
		// enough both read as a narrow image. If the mid levels agree and the widths do
		// not, the wet is loud enough and the fault is in the decorrelation.
		mid_db := 0.0
		if ref_on.mid_rms > 0 && our_on.mid_rms > 0 {
			mid_db = amplitude_db(our_on.mid_rms / ref_on.mid_rms)
		}
		fmt.printfln(
			"  %s %s %s %s %s %s %s %s %s",
			pad_left(name, 10),
			pad_left(dec3(ref_off.width), 8),
			pad_left(dec3(ref_on.width), 8),
			pad_left(dec3(our_off.width), 9),
			pad_left(dec3(our_on.width), 8),
			pad_left(sdec3(our_on.width - ref_on.width), 10),
			pad_left(dec4(ref_on.mid_rms), 9),
			pad_left(dec4(our_on.mid_rms), 8),
			pad_left(sdec1(mid_db), 8),
		)

		for b in 0 ..< CHORUS_TONAL_BANDS {
			ref_band_total[b] += ref_on.band[b]
			our_band_total[b] += our_on.band[b]
		}
		counted += 1

		if show_bands {
			fmt.printf("      ref  by octave:")
			for b in 0 ..< CHORUS_TONAL_BANDS {
				fmt.printf(" %s", pad_left(dec3(ref_on.band[b]), 7))
			}
			fmt.println()
			fmt.printf("      ours by octave:")
			for b in 0 ..< CHORUS_TONAL_BANDS {
				fmt.printf(" %s", pad_left(dec3(our_on.band[b]), 7))
			}
			fmt.println()
		}
	}

	if counted == 0 {
		return
	}

	fmt.println()
	fmt.printfln("mean side/mid by octave over %d patches, chorus on:", counted)
	fmt.printf("  band centre Hz ")
	for b in 0 ..< CHORUS_TONAL_BANDS {
		fmt.printf(" %s", pad_left(dec0(CHORUS_TONAL_LO_HZ * math.pow(2.0, f64(b) + 0.5)), 7))
	}
	fmt.println()
	fmt.printf("  reference      ")
	for b in 0 ..< CHORUS_TONAL_BANDS {
		fmt.printf(" %s", pad_left(dec3(ref_band_total[b] / f64(counted)), 7))
	}
	fmt.println()
	fmt.printf("  ours           ")
	for b in 0 ..< CHORUS_TONAL_BANDS {
		fmt.printf(" %s", pad_left(dec3(our_band_total[b] / f64(counted)), 7))
	}
	fmt.println()
	fmt.printf("  ours - ref     ")
	for b in 0 ..< CHORUS_TONAL_BANDS {
		fmt.printf(
			" %s",
			pad_left(sdec3((our_band_total[b] - ref_band_total[b]) / f64(counted)), 7),
		)
	}
	fmt.println()
}

// ------------------------------------------------------------- envelope trace

// The amplitude contour of both renders, side by side, for one patch.
//
// Built after correlation failed. The level error decomposes into two roughly equal
// halves -- our peak sits 4.35 dB below the reference's and our envelope then decays
// 4.01 dB further by the steady-state window -- but neither half correlates with any
// single parameter: resonance, both decays, both sustains, the filter envelope amount
// and the attack all come back under |r| = 0.13 against 121 patches. When a defect
// does not track any one knob, the next thing to look at is its shape.
cmd_envtrace :: proc(dll: string, dir: string, names: []string, note: int, step_ms: f64) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	frame := max(1, int(step_ms * f64(SAMPLE_RATE) / 1000.0))

	for name in names {
		path := fmt.tprintf("%v/%v", dir, name)
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {continue}
		defer delete(data)
		parsed, perr := cpatch.parse_sy1(data)
		if perr != .None {continue}

		ref, _, ok := render_reference_fresh(dll, &parsed, pristine, work, u8(note))
		defer delete(ref)
		ours := render_ours(parsed, note)
		defer delete(ours)
		if !ok || ref == nil || ours == nil {continue}

		mono :: proc(audio: []f32) -> []f32 {
			n := len(audio) / 2
			out := make([]f32, n)
			for i in 0 ..< n {
				out[i] = 0.5 * (audio[i * 2] + audio[i * 2 + 1])
			}
			return out
		}
		ref_mono := mono(ref)
		defer delete(ref_mono)
		our_mono := mono(ours)
		defer delete(our_mono)

		ref_env := frame_envelope(ref_mono, frame)
		defer delete(ref_env)
		our_env := frame_envelope(our_mono, frame)
		defer delete(our_env)
		if len(ref_env) == 0 || len(our_env) == 0 {continue}

		note_off := g_hold_frames / frame

		fmt.printfln(
			"%v at note %d, %.0f ms per column, note off at %.0f ms",
			name,
			note,
			step_ms,
			f64(note_off) * step_ms,
		)
		fmt.println("  absolute dBFS, so a level difference is visible as well as a shape one")

		count := min(len(ref_env), len(our_env))
		columns := 20
		stride := max(count / columns, 1)

		fmt.printf("     ms   ")
		for i := 0; i < count; i += stride {
			fmt.printf("%s", pad_left(fmt.tprintf("%.0f", f64(i) * step_ms), 7))
		}
		fmt.println()
		fmt.printf("     ref  ")
		for i := 0; i < count; i += stride {
			fmt.printf("%s", pad_left(dec1(amplitude_db(ref_env[i])), 7))
		}
		fmt.println()
		fmt.printf("     ours ")
		for i := 0; i < count; i += stride {
			fmt.printf("%s", pad_left(dec1(amplitude_db(our_env[i])), 7))
		}
		fmt.println()
		fmt.printf("     diff ")
		for i := 0; i < count; i += stride {
			d := amplitude_db(our_env[i]) - amplitude_db(ref_env[i])
			fmt.printf("%s", pad_left(sdec1(d), 7))
		}
		fmt.println()
		fmt.println()
	}
}
