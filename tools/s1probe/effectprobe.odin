package s1probe

// The extra effect unit: parameters 77..81.
//
// This section is the least documented and the least observable in the whole
// plugin. The English readme does not mention it at all. The Japanese manual for
// the same build names six types -- a.d.1, a.d.2, d.d., deci., r.m. and comp. --
// and gives the meaning of the two controls for each, but parameter 78 has *ten*
// states, so four are unaccounted for. And no patch in the factory bank turns
// the unit on, which means the 128-patch null test cannot see this feature at
// all: it can catch a regression and nothing else.
//
// So the identification has to come from the signal. Every type here is a
// nonlinearity or a gain change, and a nonlinearity is named by what it does to
// a pure tone:
//
//   a waveshaper       adds harmonics at exact multiples of f0
//   negative feedback  takes energy away below f0
//   a ring modulator   removes f0 and puts sidebands either side of it
//   a decimator        adds partials at no multiple of f0 at all
//   a compressor       adds nothing, and changes the envelope
//
// `fxprobe` renders a single sine through each of the ten states and reports
// those five readings side by side, against the same patch with the unit off.
//
// The ten states, in order, are:
//
//   0 a.d.1   1 a.d.2   2 d.d.   3 deci.   4 r.m.   5 comp.
//   6 ph1     7 ph2     8 ph3    9 ph4
//
// The last four are phasers, which is why the manual's list stops at six: the
// changelog adds "Phaserの追加" in v1.07 and the type table was never updated for
// it. The names come from the plugin's own LCD; the probe corroborates every one
// of them independently, which matters because the state *order* of parameters
// 0, 1, 41, 42, 46 and 47 all disagree with the order the documentation lists:
//
//   a.d.1  even harmonics dominate at low drive, and the fundamental is cut --
//          both of the things the manual attributes to it, negative feedback
//          taking the low end and even-order harmonics
//   a.d.2  purely odd harmonics, 57 dB below them the even ones, and the
//          fundamental is boosted rather than cut. A symmetric shaper, and the
//          exact complement of a.d.1
//   d.d.   the most aggressive of the three, and ctl2 walks the spectral peak
//          from the 3rd harmonic to the 39th, which is a low-pass corner
//   deci.  inharmonic content climbs from -40 to -3 dB with ctl1. Nothing that
//          only reshapes a waveform can do that; aliasing can
//   r.m.   the fundamental is annihilated, 102 dB down, with sidebands either
//          side of it, and ctl2 is inert at every setting -- the manual says
//          r.m. has no second control
//   comp.  the note overshoots its own settled level by up to 29 dB, and the
//          overshoot grows with both controls: depth and attack time
//   ph1    total harmonic distortion of -89.5 dB. A linear filter, 77 dB
//          cleaner than the compressor beside it, which is what an allpass
//          chain should read and no distortion could

import "core:fmt"
import "core:math"
import "core:os"
import cpatch "../../src/patch"

FX_STATE_COUNT :: 10

// C3, an octave below middle C.
//
// Low on purpose. The reference does not oversample its distortion, so a clipped
// tone folds its high harmonics back into the band; at a high fundamental those
// folded partials miss the harmonic windows and ordinary waveshaping reads as
// inharmonic content. At 130 Hz there are 122 harmonics inside the 16 kHz
// analysis band, MAX_HARMONIC covers all of them, and the only partials left in
// the inharmonic bucket are ones no waveshaper could have produced.
FX_PROBE_NOTE :: u8(48)
FX_PROBE_F0 :: 130.8128

// The note actually probed, and its fundamental. Settable so a reading can be
// repeated at another pitch: an effect whose behaviour depends on the note is a
// different thing from one that does not, and the only way to tell is to move.
g_fx_note := FX_PROBE_NOTE
g_fx_f0 := FX_PROBE_F0

// Long enough for several 16384-point windows inside the held note.
FX_PROBE_SECONDS :: 1.5

// The unit's own parameters.
FX_ON :: 77
FX_TYPE :: 78
FX_CTL1 :: 79
FX_CTL2 :: 80
FX_LEVEL :: 81

// A single sine and nothing else.
//
// A nonlinearity's output depends on its input level, so the drive has to be
// pinned rather than left at whatever the patch default is: `amp gain` is set
// explicitly here, and every reading in this file is taken at that one level.
fx_probe_patch :: proc(on: bool, type_state, ctl1, ctl2, level: int) -> cpatch.Patch {
	p := neutral_probe_patch()

	set_param(&p, 0, 0) // oscillator 1: sine
	set_param(&p, 5, 0) // "100 : 0" -- oscillator 1 alone
	set_param(&p, 8, 64) // pulse width, unused by a sine, left mid
	set_param(&p, 19, 127) // filter wide open
	set_param(&p, 29, 127) // amp gain at maximum, so the drive level is known
	set_param(&p, 72, 64) // fine tune centred

	set_param(&p, FX_ON, on ? 1 : 0)
	set_param(&p, FX_TYPE, type_state)
	set_param(&p, FX_CTL1, ctl1)
	set_param(&p, FX_CTL2, ctl2)
	set_param(&p, FX_LEVEL, level)

	return p
}

// What one state did to the sine.
Fx_Observation :: struct {
	ok:            bool,
	// Peak and RMS of the whole render, in dB, absolute.
	peak_db:       f64,
	rms_db:        f64,
	// Absolute power of the fundamental, so the low-frequency loss the manual
	// attributes to one of the distortions can be read as a change in the tone
	// that was actually played rather than as a ratio.
	fundamental:   f64,
	// Harmonic structure, all relative to the fundamental.
	thd_db:        f64,
	even_db:       f64,
	odd_db:        f64,
	inharmonic_db: f64,
	below_f0_db:   f64,
	// The strongest partial in band. A ring modulator moves this off f0.
	dominant_hz:   f64,
	// Side-channel energy relative to mid: is the unit doing anything in stereo?
	side_db:       f64,
	// Envelope shape over the held note: the loudest early frame against the
	// settled level. A compressor with an attack time overshoots and then pulls
	// back, so this is positive for it and near zero for everything else.
	overshoot_db:  f64,
	// How long the overshoot took to come back within 1 dB of the settled level.
	// For the compressor this is its attack time, in milliseconds and measured
	// rather than chosen. Zero when there was no overshoot to decay.
	settle_ms:     f64,
	// The two strongest peaks, lowest first, for reading sideband positions.
	peak1_hz:      f64,
	peak2_hz:      f64,
}

// How much of the held note counts as "early" when looking for an overshoot.
FX_ATTACK_MS :: 60.0
// Where the settled level is read from, as a fraction into the held note.
FX_SETTLED_FROM :: 0.5

observe_effect :: proc(audio: []f32) -> (obs: Fx_Observation) {
	if len(audio) < FFT_SIZE * 4 {
		return
	}

	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)

	held := min(g_hold_frames, len(mid))
	if held < FFT_SIZE * 2 {
		return
	}

	// Skip the first 100 ms: the point of the spectral readings is the steady
	// state, and any attack behaviour is measured separately below.
	from := int(0.1 * f64(SAMPLE_RATE))
	if from >= held - FFT_SIZE {
		from = 0
	}

	power := welch_power(mid, from, held)
	defer delete(power)
	if power == nil {
		return
	}
	bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

	r := harmonic_report(power, bin_hz, g_fx_f0)
	obs.fundamental = r.fundamental
	obs.thd_db = r.thd_db
	obs.even_db = r.even_db
	obs.odd_db = r.odd_db
	obs.inharmonic_db = r.inharmonic_db
	obs.below_f0_db = r.sub_fundamental_db
	obs.dominant_hz = dominant_frequency(power, bin_hz, BAND_HI_HZ)

	peaks := spectral_peaks(power, bin_hz, 2, -30)
	defer delete(peaks)
	if len(peaks) >= 1 {
		obs.peak1_hz = peaks[0].hz
	}
	if len(peaks) >= 2 {
		obs.peak2_hz = peaks[1].hz
		if obs.peak2_hz < obs.peak1_hz {
			obs.peak1_hz, obs.peak2_hz = obs.peak2_hz, obs.peak1_hz
		}
	}

	obs.peak_db = amplitude_db(signal_peak(audio))
	obs.rms_db = amplitude_db(signal_rms(mid[:held]))

	side_power := welch_power(side, from, held)
	defer delete(side_power)
	if side_power != nil {
		mid_total, side_total: f64
		for k in 1 ..< len(power) {
			hz := f64(k) * bin_hz
			if hz < BAND_LO_HZ {continue}
			if hz > BAND_HI_HZ {break}
			mid_total += power[k]
			side_total += side_power[k]
		}
		obs.side_db = mid_total > 0 ? power_db(side_total / mid_total) : 0
	}

	// Envelope shape. Frames are short here because an attack time of a few
	// milliseconds has to be visible.
	frame := int(0.002 * f64(SAMPLE_RATE))
	env := frame_envelope(mid[:held], frame)
	defer delete(env)
	if len(env) > 8 {
		early_frames := min(int(FX_ATTACK_MS / 2.0), len(env) / 2)
		early := 0.0
		for i in 0 ..< early_frames {
			if env[i] > early {early = env[i]}
		}
		settled, settled_count := 0.0, 0
		for i in int(f64(len(env)) * FX_SETTLED_FROM) ..< len(env) {
			settled += env[i]
			settled_count += 1
		}
		if settled_count > 0 && settled > 0 && early > 0 {
			mean := settled / f64(settled_count)
			obs.overshoot_db = amplitude_db(early / mean)

			// Where the overshoot ends. Measured from the peak frame rather than
			// from the note-on, because the compressor cannot start reducing gain
			// until it has something to react to.
			if obs.overshoot_db > 1.0 {
				peak_frame := 0
				for i in 0 ..< early_frames {
					if env[i] == early {
						peak_frame = i
						break
					}
				}
				for i in peak_frame ..< len(env) {
					if amplitude_db(env[i] / mean) <= 1.0 {
						obs.settle_ms = f64(i - peak_frame) * 1000.0 * f64(frame) / f64(SAMPLE_RATE)
						break
					}
				}
			}
		}
	}

	obs.ok = true
	return
}

fx_identical :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {return false}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {return false}
	}
	return true
}

// One configuration of the two controls, so a type whose signature only appears
// at one end of a control is not missed.
Fx_Config :: struct {
	name:             string,
	ctl1, ctl2, level: int,
}

FX_CONFIGS := []Fx_Config {
	{"mid ctl, full level", 64, 64, 127},
	{"ctl1 min", 0, 64, 127},
	{"ctl1 max", 127, 64, 127},
	{"ctl2 min", 64, 0, 127},
	{"ctl2 max", 64, 127, 127},
}

cmd_fxprobe :: proc(dll: string, config_filter: string, dump: bool) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	dumped := !dump
	dump_indices := []int{FX_ON, FX_TYPE, FX_CTL1, FX_CTL2, FX_LEVEL}

	render :: proc(
		dll: string,
		pristine, work: []byte,
		on: bool,
		type_state, ctl1, ctl2, level: int,
		dumped: ^bool,
		dump_indices: []int,
	) -> []f32 {
		p := fx_probe_patch(on, type_state, ctl1, ctl2, level)
		return probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, dumped, dump_indices)
	}

	fmt.printfln("effect unit: identifying the %d states of parameter %d", FX_STATE_COUNT, FX_TYPE)
	fmt.printfln(
		"  a single sine at note %d (%.1f Hz), amp gain at maximum, everything else off",
		g_fx_note,
		g_fx_f0,
	)
	fmt.println(
		"  every column is dB relative to the fundamental except peak/rms (absolute) and dom (Hz)",
	)

	for cfg in FX_CONFIGS {
		if config_filter != "" && cfg.name != config_filter {continue}

		off := render(dll, pristine, work, false, 0, cfg.ctl1, cfg.ctl2, cfg.level, &dumped, dump_indices)
		defer delete(off)
		if off == nil {
			fmt.eprintln("fxprobe: the reference produced no audio with the unit off")
			os.exit(1)
		}
		base := observe_effect(off)

		fmt.println()
		fmt.printfln("-- %s (ctl1=%d ctl2=%d level=%d) --", cfg.name, cfg.ctl1, cfg.ctl2, cfg.level)
		fmt.println(
			"state   peak    rms   fund    thd   even    odd  inharm    dom Hz  overshoot  peaks (Hz)",
		)
		fmt.printfln(
			"  off %s %s %s %s %s %s %s %s %s",
			pad_left(dec1(base.peak_db), 7),
			pad_left(dec1(base.rms_db), 6),
			pad_left("  0.0", 6),
			pad_left(dec1(base.thd_db), 6),
			pad_left(dec1(base.even_db), 6),
			pad_left(dec1(base.odd_db), 6),
			pad_left(dec1(base.inharmonic_db), 7),
			pad_left(dec1(base.dominant_hz), 9),
			pad_left(dec1(base.overshoot_db), 10),
		)

		for state in 0 ..< FX_STATE_COUNT {
			on := render(dll, pristine, work, true, state, cfg.ctl1, cfg.ctl2, cfg.level, &dumped, dump_indices)
			defer delete(on)
			if on == nil {continue}

			o := observe_effect(on)
			same := fx_identical(off, on)

			// The fundamental against the same note with the unit off. This is the
			// column that shows a low-frequency loss, which no ratio can: every
			// other harmonic reading is normalised by the fundamental and so is
			// blind to the fundamental itself moving.
			fund_db := 0.0
			if base.fundamental > 0 && o.fundamental > 0 {
				fund_db = power_db(o.fundamental / base.fundamental)
			}

			fmt.printfln(
				"  %s %s %s %s %s %s %s %s %s %s  %s %s%s",
				pad_left(fmt.tprintf("%d", state), 3),
				pad_left(dec1(o.peak_db), 7),
				pad_left(dec1(o.rms_db), 6),
				pad_left(dec1(fund_db), 6),
				pad_left(dec1(o.thd_db), 6),
				pad_left(dec1(o.even_db), 6),
				pad_left(dec1(o.odd_db), 6),
				pad_left(dec1(o.inharmonic_db), 7),
				pad_left(dec1(o.dominant_hz), 9),
				pad_left(dec1(o.overshoot_db), 10),
				pad_left(dec0(o.peak1_hz), 6),
				pad_left(dec0(o.peak2_hz), 6),
				same ? "   IDENTICAL TO OFF" : "",
			)
		}
	}
}

// Retarget the probe at another note, deriving the fundamental from equal
// temperament rather than taking it on trust.
set_fx_note :: proc(note: int) {
	n := clamp(note, 0, 127)
	g_fx_note = u8(n)
	g_fx_f0 = 440.0 * math.pow(2.0, (f64(n) - 69.0) / 12.0)
}

// -------------------------------------------------------------- control sweep

FX_TYPE_NAMES := []string {
	"a.d.1",
	"a.d.2",
	"d.d.",
	"deci.",
	"r.m.",
	"comp.",
	"ph1",
	"ph2",
	"ph3",
	"ph4",
}

// The modulation frequency implied by a pair of sidebands straddling the
// fundamental, or zero when the two strongest peaks do not straddle it.
//
// Ring modulation by fm moves a carrier at f0 to f0-fm and f0+fm and leaves
// nothing between, so the half-separation of those two peaks is fm in hertz.
// That makes r.m.'s first control the one parameter of this whole section whose
// curve can be read in a real unit rather than chosen -- the same standard the
// rest of the project holds itself to.
// There are two branches, and using only the first is wrong over most of the
// range. Multiplying a carrier f0 by a modulator fm gives partials at |f0 - fm|
// and f0 + fm. While fm < f0 those straddle the carrier, so their half-separation
// is fm and their centre is f0. Once fm > f0 the lower one has reflected through
// zero and the pair sits at fm - f0 and fm + f0: now the *centre* is fm and the
// half-separation has pinned to f0. Reading the half-separation throughout would
// report a modulation frequency that rises to f0 and then stops, which is what
// the first version of this did.
sideband_frequency :: proc(lo, hi, f0: f64) -> f64 {
	if lo <= 0 || hi <= 0 || hi <= lo {return 0}
	centre := 0.5 * (lo + hi)
	half := 0.5 * (hi - lo)

	// Whichever of the two readings is nearer f0 identifies which branch this is:
	// the other reading is then the modulation frequency.
	if abs(centre - f0) < abs(half - f0) {
		return half
	}
	return centre
}

// Sweep one control across its range for one type.
cmd_fxsweep :: proc(dll: string, type_state: int, control: int, values: []int, other, level: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	dumped := true
	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"

	fmt.printfln(
		"effect %d (%s): sweeping ctl%d, the other control at %d, level %d",
		type_state,
		name,
		control,
		other,
		level,
	)
	fmt.printfln("  single sine at note %d (%.1f Hz)", g_fx_note, g_fx_f0)

	off_patch := fx_probe_patch(false, type_state, other, other, level)
	off := probe_render(dll, &off_patch, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
	defer delete(off)
	if off == nil {
		fmt.eprintln("fxsweep: the reference produced no audio with the unit off")
		os.exit(1)
	}
	base := observe_effect(off)

	fmt.println(" ctl   peak    rms   fund    thd   even    odd  inharm    dom Hz  overshoot  settle ms   peaks (Hz)   sideband")
	for v in values {
		// Control 3 is the level knob, swept the same way as the other two so a
		// "level" that turns out to be a dry/wet mix can be told from one that
		// scales the effect: for a ring modulator the dry and wet spectra are
		// disjoint, so a mix shows up as the fundamental coming back.
		ctl1 := control == 1 ? v : other
		ctl2 := control == 2 ? v : other
		lv := control == 3 ? v : level
		p := fx_probe_patch(true, type_state, ctl1, ctl2, lv)
		on := probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
		defer delete(on)
		if on == nil {continue}

		o := observe_effect(on)
		fund_db := 0.0
		if base.fundamental > 0 && o.fundamental > 0 {
			fund_db = power_db(o.fundamental / base.fundamental)
		}
		fm := sideband_frequency(o.peak1_hz, o.peak2_hz, g_fx_f0)

		fmt.printfln(
			" %s %s %s %s %s %s %s %s %s %s %s   %s %s  %s%s",
			pad_left(fmt.tprintf("%d", v), 3),
			pad_left(dec1(o.peak_db), 7),
			pad_left(dec1(o.rms_db), 6),
			pad_left(dec1(fund_db), 6),
			pad_left(dec1(o.thd_db), 6),
			pad_left(dec1(o.even_db), 6),
			pad_left(dec1(o.odd_db), 6),
			pad_left(dec1(o.inharmonic_db), 7),
			pad_left(dec1(o.dominant_hz), 9),
			pad_left(dec1(o.overshoot_db), 10),
			pad_left(o.settle_ms > 0 ? dec1(o.settle_ms) : "-", 10),
			pad_left(dec0(o.peak1_hz), 6),
			pad_left(dec0(o.peak2_hz), 6),
			pad_left(fm > 0 ? dec1(fm) : "-", 8),
			fx_identical(off, on) ? "   IDENTICAL TO OFF" : "",
		)
	}
}

// ------------------------------------------------------------ decimator probe

// Read the decimator's two controls off the waveform.
//
// The spectrum is the wrong instrument here -- see the note in analysis.odin --
// so this reads the step length and the level count straight out of the rendered
// samples. Both need the unit fully wet, which is why `level` is pinned at 127.
cmd_deciprobe :: proc(dll: string, control: int, values: []int, other: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	DECI :: 3
	fmt.printfln("deci. (state %d): sweeping ctl%d with the other control at %d, fully wet", DECI, control, other)
	fmt.printfln("  single sine at note %d (%.1f Hz), read in the time domain", g_fx_note, g_fx_f0)
	fmt.println(" ctl   hold  conf     rate Hz   levels   bits")

	for v in values {
		ctl1 := control == 1 ? v : other
		ctl2 := control == 2 ? v : other
		p := fx_probe_patch(true, DECI, ctl1, ctl2, 127)
		audio := probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		// The left channel only: a stereo interleave would read as a hold of one.
		held := min(g_hold_frames, len(audio) / 2)
		left := make([]f32, held)
		defer delete(left)
		for i in 0 ..< held {
			left[i] = audio[i * 2]
		}

		// Skip the first 100 ms so the note's own onset is not measured.
		from := min(int(0.1 * f64(SAMPLE_RATE)), held / 2)
		window := left[from:]

		length, confidence := hold_run_length(window, 1)
		levels := distinct_levels(window, 65536)

		rate := "-"
		if length > 0 && confidence > 0.5 {
			rate = dec1(f64(SAMPLE_RATE) / f64(length))
		}
		bits := "-"
		if levels > 0 && levels < 65536 {
			bits = dec2(math.log2(f64(levels)))
		}

		fmt.printfln(
			" %s %s %s %s %s %s",
			pad_left(fmt.tprintf("%d", v), 3),
			pad_left(fmt.tprintf("%d", length), 6),
			pad_left(dec2(confidence), 5),
			pad_left(rate, 11),
			pad_left(fmt.tprintf("%d", levels), 8),
			pad_left(bits, 6),
		)
	}
}

// The distribution of run lengths, not just its mode.
//
// Worth having as a command of its own: the mode alone said the decimator's step
// was exactly ctl1-9 samples at all ten settings tried, which is a suspiciously
// tidy answer to sit on when the same reading also claimed the mode covered only
// a third of the signal. Either the steps are ragged or the reading is wrong, and
// the histogram is what tells them apart.
cmd_runhist :: proc(dll: string, type_state, ctl1, ctl2, level: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	p := fx_probe_patch(true, type_state, ctl1, ctl2, level)
	audio := probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
	defer delete(audio)
	if audio == nil {
		fmt.eprintln("runhist: no audio")
		os.exit(1)
	}

	held := min(g_hold_frames, len(audio) / 2)
	from := min(int(0.1 * f64(SAMPLE_RATE)), held / 2)
	left := make([]f32, held - from)
	defer delete(left)
	for i in 0 ..< len(left) {
		left[i] = audio[(from + i) * 2]
	}

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln("state %d (%s) ctl1=%d ctl2=%d level=%d, %d samples", type_state, name, ctl1, ctl2, level, len(left))

	counts: map[int]int
	defer delete(counts)
	run := 1
	runs := 0
	for i in 1 ..< len(left) {
		if left[i] == left[i - 1] {
			run += 1
			continue
		}
		counts[run] += 1
		runs += 1
		run = 1
	}

	fmt.printfln("  %d runs of equal consecutive samples", runs)
	fmt.println("  length   runs   samples   share")
	shown := 0
	for length := 1; length <= 4096 && shown < 12; length += 1 {
		c, ok := counts[length]
		if !ok {continue}
		shown += 1
		fmt.printfln(
			"  %s %s %s   %s%%",
			pad_left(fmt.tprintf("%d", length), 6),
			pad_left(fmt.tprintf("%d", c), 6),
			pad_left(fmt.tprintf("%d", c * length), 9),
			pad_left(dec1(100.0 * f64(c * length) / f64(len(left))), 5),
		)
	}

	// Printed from a point chosen to span a step boundary rather than from the
	// start, which lands in the middle of one hold and shows nothing.
	start := 0
	for i in 1 ..< min(len(left), 8192) {
		if left[i] != left[i - 1] {
			start = max(0, i - 4)
			break
		}
	}
	fmt.printfln("  120 samples from %d, spanning a step boundary:", start)
	for i in start ..< min(start + 120, len(left)) {
		if (i - start) % 8 == 0 {fmt.printf("   ")}
		fmt.printf(" %s", dec6(f64(left[i])))
		if (i - start) % 8 == 7 {fmt.println()}
	}
	fmt.println()
}

// --------------------------------------------------------- distortion low-pass

// The three distortions all carry a low-pass on their output -- the manual gives
// ctl2 as "LOWパスフィルターのカットオフ周波数" for a.d.1, a.d.2 and d.d. alike --
// and a corner frequency is one of the few things in this section with a real
// unit, so it gets measured rather than chosen.
//
// A sine is the wrong probe for it: the only frequencies available to test the
// filter with are the distortion's own harmonics, whose levels move as the drive
// moves, so filter and drive cannot be separated. Noise tests every band at once.
// Distorting noise leaves it broadband, so what the corner measurement sees is
// the filter alone.
fx_noise_patch :: proc(on: bool, type_state, ctl1, ctl2, level: int) -> cpatch.Patch {
	p := fx_probe_patch(on, type_state, ctl1, ctl2, level)
	set_param(&p, 1, 4) // oscillator 2: noise
	set_param(&p, 5, 127) // "0 : 100" -- oscillator 2 alone
	return p
}

cmd_fxcorner :: proc(dll: string, type_state: int, values: []int, drive: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln("state %d (%s): low-pass corner against ctl2, drive (ctl1) at %d", type_state, name, drive)
	fmt.println("  white noise in, so the reading is the filter and not the harmonic series")

	// The reference for "unfiltered" is the same distortion with ctl2 wide open.
	// Taking it from the effect being off instead would fold the distortion's own
	// spectral tilt into the corner estimate.
	open_patch := fx_noise_patch(true, type_state, drive, 127, 127)
	open_audio := probe_render(dll, &open_patch, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
	defer delete(open_audio)
	if open_audio == nil {
		fmt.eprintln("fxcorner: no audio with the filter open")
		os.exit(1)
	}
	open_bands, centres, open_ok := probe_band_levels(open_audio)
	defer delete(open_bands)
	defer delete(centres)
	if !open_ok {
		fmt.eprintln("fxcorner: could not analyse the open reference")
		os.exit(1)
	}

	fmt.println(" ctl2    corner Hz")
	for v in values {
		p := fx_noise_patch(true, type_state, drive, v, 127)
		audio := probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
		defer delete(audio)
		if audio == nil {continue}

		bands, band_centres, ok := probe_band_levels(audio)
		defer delete(bands)
		defer delete(band_centres)
		if !ok {continue}

		corner, corner_ok := measure_corner(bands, open_bands, centres)
		fmt.printfln(
			" %s %s",
			pad_left(fmt.tprintf("%d", v), 4),
			pad_left(corner_ok ? dec1(corner) : "-", 12),
		)
	}
}

// ------------------------------------------------------------- envelope trace

// The level over time, in dB against the render's own mean.
//
// This exists to settle one question that decides the whole shape of the phaser
// implementation: does it sweep on its own? A phaser with an internal LFO makes
// the level rise and fall periodically as its notches walk across the harmonic
// series; a static allpass chain gives a flat line. Steady-state spectra cannot
// tell the two apart, because a slow sweep and a fixed comb average to a similar
// place over a 1.4 second window.
cmd_fxenv :: proc(dll: string, type_state, ctl1, ctl2, level: int, step_ms: f64) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)
	dumped := true

	p := fx_probe_patch(true, type_state, ctl1, ctl2, level)
	audio := probe_render(dll, &p, pristine, work, g_fx_note, FX_PROBE_SECONDS, &dumped, nil)
	defer delete(audio)
	if audio == nil {
		fmt.eprintln("fxenv: no audio")
		os.exit(1)
	}

	mid, side := split_mid_side(audio, 2)
	defer delete(mid)
	defer delete(side)
	held := min(g_hold_frames, len(mid))

	frame := max(1, int(step_ms * f64(SAMPLE_RATE) / 1000.0))
	env := frame_envelope(mid[:held], frame)
	defer delete(env)
	if len(env) == 0 {
		return
	}

	mean := 0.0
	for v in env {
		mean += v
	}
	mean /= f64(len(env))

	name := type_state >= 0 && type_state < len(FX_TYPE_NAMES) ? FX_TYPE_NAMES[type_state] : "?"
	fmt.printfln(
		"state %d (%s) ctl1=%d ctl2=%d level=%d: level in dB against its own mean, every %.0f ms",
		type_state,
		name,
		ctl1,
		ctl2,
		level,
		step_ms,
	)

	// An implied rate, so the trace does not have to be read by eye. Counting
	// crossings of the mean is enough here because the sweep is smooth and
	// one-per-cycle; hysteresis keeps a flat trace from reporting a rate at all.
	crossings := 0
	above := env[0] > mean
	HYSTERESIS :: 0.05
	for v in env[1:] {
		if above && v < mean * (1.0 - HYSTERESIS) {
			above = false
			crossings += 1
		} else if !above && v > mean * (1.0 + HYSTERESIS) {
			above = true
			crossings += 1
		}
	}
	span_s := f64(len(env)) * step_ms / 1000.0
	rate := span_s > 0 ? f64(crossings) / (2.0 * span_s) : 0
	fmt.printfln("  %d crossings of the mean over %.2f s -> %.2f Hz", crossings, span_s, rate)

	// Printed as a sparkline of numbers rather than a plot: an oscillation is
	// obvious in the sign pattern and its period is countable off the columns.
	for i in 0 ..< len(env) {
		if i % 16 == 0 {
			fmt.printf("  %sms ", pad_left(fmt.tprintf("%.0f", f64(i) * step_ms), 5))
		}
		fmt.printf(" %s", pad_left(env[i] > 0 ? dec1(amplitude_db(env[i] / mean)) : "-inf", 6))
		if i % 16 == 15 {fmt.println()}
	}
	fmt.println()
}

// -------------------------------------------------------------- direct A/B

// Our engine against the reference, on patches that switch the effect unit on.
//
// This exists because the 128-patch null test cannot serve as this feature's
// oracle. Not one factory patch turns the unit on, so the bank comparison can
// only confirm that nothing regressed -- a real but weak statement. The patches
// here are synthesised instead, and both renders happen in this process: the
// reference through the loaded DLL, ours through the statically linked engine.
//
// One trap this walks around, learned the hard way earlier in the project: the
// engine is linked into this tool, so a stale s1probe silently measures a stale
// engine. Rebuild before reading anything here.
cmd_fxcompare :: proc(dll: string, ctl1, ctl2, level: int, note: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(FX_PROBE_SECONDS * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	fmt.printfln(
		"effect unit: ours against the reference, ctl1=%d ctl2=%d level=%d, note %d",
		ctl1,
		ctl2,
		level,
		note,
	)
	fmt.println("  spectral and envelope are dB of error, 0 is identical; level is ours minus theirs")
	fmt.println("state  name    spectral  envelope     level    null")

	worst := -1.0
	total := 0.0
	counted := 0

	for state in 0 ..< FX_STATE_COUNT {
		p := fx_probe_patch(true, state, ctl1, ctl2, level)

		ref, _, ok := render_reference_fresh(dll, &p, pristine, work, u8(note))
		defer delete(ref)
		if !ok || ref == nil {continue}

		ours := render_ours(p, note)
		defer delete(ours)
		if ours == nil {continue}

		residual := make([]f32, len(ref))
		defer delete(residual)
		c := compare_renders(
			ref,
			ours,
			2,
			f64(SAMPLE_RATE),
			f64(g_hold_frames) / f64(SAMPLE_RATE),
			residual,
		)

		name := FX_TYPE_NAMES[state]
		spectral := c.spectral_valid ? dec2(c.spectral_db) : "  n/a"
		fmt.printfln(
			"  %s  %s %s %s %s %s",
			pad_left(fmt.tprintf("%d", state), 3),
			pad_left(name, 6),
			pad_left(spectral, 9),
			pad_left(dec2(c.envelope_db), 9),
			pad_left(sdec2(c.level_db), 9),
			pad_left(dec2(c.null_db), 7),
		)

		if c.spectral_valid {
			total += c.spectral_db
			counted += 1
			if c.spectral_db > worst {worst = c.spectral_db}
		}
	}

	if counted > 0 {
		fmt.printfln("  mean spectral %.2f dB over %d types, worst %.2f dB", total / f64(counted), counted, worst)
	}
}

// --------------------------------------------------------------- tuning check

// Is the pitch wrong, or is it the balance between partials?
//
// The null test's tuning column reports the *strongest* partial in each render.
// That is the right reading for catching a wrong octave, and the wrong reading for
// deciding what caused one: two renders can carry the same harmonic series at the
// same frequencies and still disagree about which member of it is loudest. A patch
// mixing two oscillators an octave apart will flip its reported f0 for a few
// percent of mix error, with the pitch perfectly correct.
//
// So this prints the whole series for both renders, at multiples of the note
// actually played. If both sides have energy at the fundamental and the difference
// is which harmonic dominates, the defect is a level balance and not tuning.
cmd_tuningcheck :: proc(dll: string, path: string, note: int) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("tuningcheck: cannot read %q", path)
		os.exit(1)
	}
	defer delete(data)
	parsed, perr := cpatch.parse_sy1(data)
	if perr != .None {
		fmt.eprintfln("tuningcheck: cannot parse %q: %v", path, perr)
		os.exit(1)
	}

	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	held := (int(2.0 * f64(SAMPLE_RATE)) + g_block - 1) / g_block
	g_hold_frames = held * g_block
	g_total_frames = g_hold_frames + g_block * 8

	ref, _, ok := render_reference_fresh(dll, &parsed, pristine, work, u8(note))
	defer delete(ref)
	ours := render_ours(parsed, note)
	defer delete(ours)
	if !ok || ref == nil || ours == nil {
		fmt.eprintln("tuningcheck: no audio")
		os.exit(1)
	}

	f0 := 440.0 * math.pow(2.0, (f64(note) - 69.0) / 12.0)
	fmt.printfln("%v at note %d (%.2f Hz)", path, note, f0)

	series :: proc(audio: []f32, f0: f64) -> (levels: [13]f64, dominant: f64) {
		mid, side := split_mid_side(audio, 2)
		defer delete(mid)
		defer delete(side)
		from := min(int(0.1 * f64(SAMPLE_RATE)), len(mid) / 4)
		power := welch_power(mid, from, min(g_hold_frames, len(mid)))
		defer delete(power)
		if power == nil {return}
		bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)

		r := harmonic_report(power, bin_hz, f0)
		strongest := 0.0
		for h in 1 ..= 12 {
			if r.harmonic[h] > strongest {strongest = r.harmonic[h]}
		}
		for h in 1 ..= 12 {
			levels[h] = strongest > 0 ? power_db(r.harmonic[h] / strongest) : -999
		}
		dominant = dominant_frequency(power, bin_hz, BAND_HI_HZ)
		return
	}

	ref_levels, ref_dom := series(ref, f0)
	our_levels, our_dom := series(ours, f0)

	fmt.println("  harmonic levels, dB below each render's own strongest harmonic")
	fmt.printf("  harmonic  ")
	for h in 1 ..= 12 {
		fmt.printf("%7d", h)
	}
	fmt.println()
	fmt.printf("  reference ")
	for h in 1 ..= 12 {
		fmt.printf("%7s", dec1(ref_levels[h]))
	}
	fmt.println()
	fmt.printf("  ours      ")
	for h in 1 ..= 12 {
		fmt.printf("%7s", dec1(our_levels[h]))
	}
	fmt.println()
	fmt.printf("  delta     ")
	for h in 1 ..= 12 {
		fmt.printf("%7s", sdec1(our_levels[h] - ref_levels[h]))
	}
	fmt.println()

	fmt.printfln(
		"  strongest partial: reference %.1f Hz (harmonic %.2f), ours %.1f Hz (harmonic %.2f)",
		ref_dom,
		ref_dom / f0,
		our_dom,
		our_dom / f0,
	)
	// The reading that decides it: if both have a fundamental within a few dB of
	// their own peak, the note is in tune and only the balance differs.
	fmt.printfln(
		"  fundamental present in both: reference %.1f dB down, ours %.1f dB down",
		-ref_levels[1],
		-our_levels[1],
	)

	// The competing peaks of the tuning correlation, so the octave ambiguity is
	// visible rather than inferred from which side won.
	{
		ref_mid, ref_side := split_mid_side(ref, 2)
		defer delete(ref_mid)
		defer delete(ref_side)
		our_mid, our_side := split_mid_side(ours, 2)
		defer delete(our_mid)
		defer delete(our_side)
		from := min(int(0.1 * f64(SAMPLE_RATE)), len(ref_mid) / 4)
		rp := welch_power(ref_mid, from, min(g_hold_frames, len(ref_mid)))
		defer delete(rp)
		op := welch_power(our_mid, from, min(g_hold_frames, len(our_mid)))
		defer delete(op)
		if rp != nil && op != nil {
			bin_hz := f64(SAMPLE_RATE) / f64(FFT_SIZE)
			scores := pitch_shift_scores(rp, op, bin_hz)
			defer delete(scores)
			if scores != nil {
				fmt.printf("  tuning correlation at ")
				for cents in ([]int{-2400, -1200, -700, 0, 700, 1200, 2400}) {
					idx := PITCH_MAX_SHIFT + (cents * PITCH_STEPS_PER_OCTAVE) / 1200
					if idx < 0 || idx >= len(scores) || scores[idx] < -1.0 {continue}
					fmt.printf("%+d:%.3f  ", cents, scores[idx])
				}
				fmt.println()
				cents, conf := pitch_shift_cents(rp, op, bin_hz)
				fmt.printfln("  reported: %+.1f cents at confidence %.2f", cents, conf)
			}
		}
	}
}
