// s1probe compare - the null test.
//
// Renders the same patch twice, once through the reference Synth1 binary and
// once through src/engine, under conditions that are identical by construction,
// and reports how far apart they are. This is the oracle docs/architecture.md
// promised: until it existed, every acceptance gate in the project asserted only
// that the engine produced *a* sound, which is a test the engine could pass
// while being wrong about every design decision it had to guess.
//
//   s1probe compare [dll] <patch.sy1 | directory> [options]
//   s1probe summarise <compare.csv>
//
//     --wav <dir>     write ref/ours/residual WAVs for each patch
//     --csv <path>    append one row per patch, written as each patch finishes
//     --note <n>      MIDI note to play (default 60, middle C)
//     --limit <n>     stop after n patches
//     --offset <n>    skip the first n patches, for resuming a run
//     --skip <names>  comma-separated patch files to leave out
//     --block <n>     frames per process() call
//     --self          control run: compare the reference against itself
//     --no-floor      skip the second reference render
//     --verbose       full per-patch detail instead of one line each
//     --isolate       render in a child process even for a single patch; this
//                     is already the default for a run of more than one, so a
//                     patch that crashes the reference costs one row, not the run
//     --no-isolate    render in this process, for attaching a debugger to it
//
// The interesting output is the summary. Per-patch numbers say which patch is
// wrong; the aggregates say *what* is wrong, because a mapping error that is
// systematic shows up as the same bias on every patch at once.
//
// Start with `--self`. It compares the reference against a second render of
// itself and should report zero on every metric; anything else means the
// harness is measuring itself rather than the engine.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import sengine "../../src/engine"
import cpatch "../../src/patch"

// Both renders are driven in blocks of this size so the note off lands on the
// same sample in each. Getting that wrong would put the reference's note off up
// to a block after ours and charge the difference to the release curve, which
// is one of the things being measured.
//
// The default is the block size the plugin was told about at load time. VST 2.4
// calls that a maximum rather than a requirement, but a plugin of this vintage
// may still assume it is handed exactly that many frames, so departing from it
// is not free; `--block` exists to test that assumption rather than trust it.
COMPARE_BLOCK_DEFAULT :: BLOCK

// The note every comparison plays unless told otherwise. Named so isolate.odin
// can tell "the default" from "explicitly asked for 60" when rebuilding a
// child command line.
COMPARE_NOTE_DEFAULT :: u8(60)

COMPARE_HOLD_SECONDS :: 1.5
COMPARE_TAIL_SECONDS :: 1.0

// Resolved once per run from the chosen block size. Both the hold and the total
// are whole numbers of blocks so the note off lands on a block boundary, and
// therefore on the identical sample in both engines.
g_block: int = COMPARE_BLOCK_DEFAULT
g_hold_frames: int
g_total_frames: int

set_compare_timing :: proc(block: int) {
	g_block = max(block, 1)
	blocks_held := (int(COMPARE_HOLD_SECONDS * SAMPLE_RATE) + g_block - 1) / g_block
	blocks_tail := (int(COMPARE_TAIL_SECONDS * SAMPLE_RATE) + g_block - 1) / g_block
	g_hold_frames = blocks_held * g_block
	g_total_frames = (blocks_held + blocks_tail) * g_block
}

// The reference is sent MIDI, so velocity is a 7-bit integer. Our engine takes
// a fraction, and it has to be the same fraction rather than a convenient 1.0:
// parameter 30 scales level by velocity, so a mismatch here would be reported
// as a level error on every patch that uses it.
COMPARE_VELOCITY_MIDI :: u8(100)
COMPARE_VELOCITY :: f32(100.0) / 127.0

Row :: struct {
	name:             string,
	c:                Comparison,
	// The reference compared against a second render of itself, through the
	// identical path. This is the measurement's own noise floor, and it is
	// measured per patch rather than assumed.
	//
	// It is worth keeping even though it currently comes out at exactly zero for
	// every patch -- the second render is bit-identical, so the null is -240 dB
	// and every other metric is 0.00. That is a property of the fresh-instance
	// isolation in `open_reference`, not a given: the earlier suspend-and-resume
	// reset left the chorus, the delay line and the free-running LFOs wherever
	// the previous render had put them, and the floor under it was 2.1 dB of
	// spectral and 3.7 dB of envelope error. Anything that regresses that
	// isolation shows up here first, as a floor that stops being zero.
	floor:            Comparison,
	has_floor:        bool,
	param_mismatches: int,
}

// Every reference render gets a freshly loaded plugin, and the library is
// unloaded again afterwards.
//
// The obvious cheaper reset -- suspend and resume between renders, which is what
// VST 2.4 gives a host for exactly this -- was tried first and does not survive
// contact with this binary. Synth1 segfaults after between ten and twenty
// suspend/resume cycles regardless of which patches are involved: the failure
// tracks the cycle count, not the patch. Reloading the library sidesteps that,
// and buys two things beyond not crashing:
//
//   - Determinism. The chorus, the delay line and the free-running LFOs start
//     from their initial state rather than wherever the previous render left
//     them. Measured: two renders of the same patch come out bit-identical, so
//     the harness has no noise floor at all and every difference the tool
//     reports is genuinely the engine's. Under suspend-and-resume the same
//     control run reported 2.1 dB of spectral and 3.7 dB of envelope error
//     against itself.
//   - Isolation. No patch can influence the render of the next one.
//
// It costs a LoadLibrary per render, which against a 2.5 second render is
// nothing worth optimising.
open_reference :: proc(dll: string) -> (Plugin, bool) {
	host_transport_reset()
	g_instantiations += 1
	return load(dll)
}

close_reference :: proc(p: ^Plugin) {
	unload(p)
}

// The reference's arpeggiator segfaults, and it takes this process with it.
//
// Five of the 128 factory patches die inside Synth1 during `processReplacing`:
// 095 Cosmos, 098 Behind the mask, 100 Sequence, 101 Sequence2 and 106 Rhythm.
// Every one of them has the arpeggiator switched on, and the arpeggiator is
// the cause rather than a correlation -- switching it off in 100 makes that
// patch render, and switching it on in 001, which has never crashed, makes 001
// crash. It dies about a sixteenth note into the render, which at 120 BPM is
// exactly where the first arpeggiator step falls.
//
// Fourteen host-side explanations have now been tried and none of them is it.
// Three by hand -- the MIDI event list outliving the dispatch (fixed anyway in
// main.odin, because the contract says so), a frozen transport, and announcing
// kVstTransportChanged -- and eleven by `hostprobe`, which varies one thing per
// case in a child process: what `audioMasterTempoAt`, `audioMasterWantMidi` and
// `audioMasterProcessEvents` answer, whether the transport claims to be
// rolling, whether an empty `effProcessEvents` is dispatched before every
// block, whether the retained list is zeroed after each dispatch, the block
// length, and whether the state chunk is pushed before the resume, after it, or
// with a suspend-and-resume cycle behind it. All of them die, and on a patch
// with the arpeggiator off all of them render the same peak, so none of them is
// changing the audio either.
//
// `paramcrash` narrows it from the other side: of the twenty-eight parameters
// where 095 differs from the plugin's own factory chunk, restoring exactly one
// makes it render, and that one is 59, the arpeggiator switch.
//
// This was first misread as a cumulative instantiation limit, because two
// full-bank runs stopped after exactly 94 patches. They stopped there because
// 095 is the 95th patch, not because of any count. It was then misread as one
// bad patch, because 095 is the only one an interrupted run ever reached.
//
// So the fault is inside a twenty-year-old binary this project cannot patch,
// and the defence is isolation -- now the default for any run of more than one
// patch, rather than a flag somebody has to know to pass. A patch that kills
// the reference costs its own row. `--skip` and `--offset` still work and are
// no longer the only thing standing between a bank run and a dead process.
g_instantiations: int

// Push all 99 effective values into the reference through its own state chunk,
// and report how many did not read back as expected. This includes defaults for
// records absent from the source: those defaults are part of the rendered state
// too, and skipping them would let an unverified value affect the comparison.
//
// This is the same path `verify` uses and for the same reason: setParameter
// saturates at 1.0 while the loader genuinely reports values above it. The
// read-back count is carried into the comparison so an audio difference caused
// by the patch not loading is never mistaken for an engine difference.
load_reference_patch :: proc(p: ^Plugin, parsed: ^cpatch.Patch, pristine, work: []byte) -> int {
	e := p.eff
	copy(work, pristine)
	for i in 0 ..< cpatch.PARAMETER_COUNT {
		write_le_u32(work, CHUNK_VALUE_BASE + i * CHUNK_VALUE_STRIDE, u32(i32(parsed.values[i])))
	}
	e.dispatcher(e, i32(Op.SetChunk), 0, len(work), raw_data(work), 0)

	mismatches := 0
	for i in 0 ..< cpatch.PARAMETER_COUNT {
		expected, resolved := cpatch.parameter_norm(i, parsed.values[i])
		if !resolved || expected != e.get_parameter(e, i32(i)) {
			mismatches += 1
		}
	}
	return mismatches
}

render_reference :: proc(p: ^Plugin, note: u8) -> []f32 {
	return render_reference_note(p, note, COMPARE_VELOCITY_MIDI)
}

// Render the reference. Interleaved, `g_total_frames` frames.
render_reference_note :: proc(p: ^Plugin, note: u8, velocity: u8) -> []f32 {
	e := p.eff
	channels := int(e.num_outputs)
	if channels < 1 {
		channels = 2
	}

	chans := make([][]f32, channels)
	ptrs := make([][^]f32, channels)
	defer {
		for c in chans {
			delete(c)
		}
		delete(chans)
		delete(ptrs)
	}
	for i in 0 ..< channels {
		chans[i] = make([]f32, g_block)
		ptrs[i] = raw_data(chans[i])
	}

	inputs := max(int(e.num_inputs), 1)
	in_chans := make([][]f32, inputs)
	in_ptrs := make([][^]f32, inputs)
	defer {
		for c in in_chans {
			delete(c)
		}
		delete(in_chans)
		delete(in_ptrs)
	}
	for i in 0 ..< inputs {
		in_chans[i] = make([]f32, g_block)
		in_ptrs[i] = raw_data(in_chans[i])
	}

	out := make([]f32, g_total_frames * 2)

	// Both renders of a patch start from bar one, so anything the plugin drives
	// from musical time lands in the same place in each. Without this the
	// tempo-synced delay alone would put a floor under the comparison.
	host_transport_reset()
	send_midi(p, 0x90, note, velocity, 0)

	for pos := 0; pos < g_total_frames; pos += g_block {
		// The hold is a whole number of blocks, so this lands the note off on
		// exactly the same sample our engine uses.
		if pos == g_hold_frames {
			send_midi(p, 0x80, note, 0, 0)
		}
		for i in 0 ..< channels {
			for j in 0 ..< g_block {
				chans[i][j] = 0
			}
		}
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), i32(g_block))
		host_transport_advance(g_block)
		for j in 0 ..< g_block {
			frame := pos + j
			out[frame * 2] = chans[0][j]
			out[frame * 2 + 1] = channels > 1 ? chans[1][j] : chans[0][j]
		}
	}
	return out
}

// Load the plugin, push a patch into it, render, and unload. The whole
// reference side of one measurement, with no state carried in or out.
render_reference_fresh :: proc(
	dll: string,
	parsed: ^cpatch.Patch,
	pristine, work: []byte,
	note: u8,
) -> (
	audio: []f32,
	mismatches: int,
	ok: bool,
) {
	p, loaded := open_reference(dll)
	if !loaded {
		return nil, 0, false
	}
	defer close_reference(&p)

	mismatches = load_reference_patch(&p, parsed, pristine, work)
	return render_reference(&p, note), mismatches, true
}

// Render our engine under the same conditions. Interleaved, same length.
render_ours :: proc(parsed: cpatch.Patch, note: int) -> []f32 {
	return render_ours_velocity(parsed, note, COMPARE_VELOCITY)
}

// The same, with the velocity chosen rather than fixed. Only `velprobe` needs
// that; everything else wants the single velocity the null test standardised
// on, which is what the wrapper above preserves.
render_ours_velocity :: proc(parsed: cpatch.Patch, note: int, velocity: f32) -> []f32 {
	eng: sengine.Engine
	sengine.engine_load_patch(&eng, parsed, f32(SAMPLE_RATE))
	defer sengine.engine_destroy(&eng)

	left := make([]f32, g_total_frames)
	defer delete(left)
	right := make([]f32, g_total_frames)
	defer delete(right)

	// Driven in the same block size as the reference. The engine's inner loop is
	// per sample and carries no block state, so this changes nothing about the
	// output; it is done anyway so that if that ever stops being true, the
	// comparison does not start lying about why.
	sengine.engine_note_on(&eng, note, velocity)
	for pos := 0; pos < g_total_frames; pos += g_block {
		if pos == g_hold_frames {
			sengine.engine_note_off(&eng, note)
		}
		end := pos + g_block
		sengine.engine_process(&eng, left[pos:end], right[pos:end])
	}

	out := make([]f32, g_total_frames * 2)
	for i in 0 ..< g_total_frames {
		out[i * 2] = left[i]
		out[i * 2 + 1] = right[i]
	}
	return out
}

// ------------------------------------------------------------------ reporting

log2f :: proc(x: f64) -> f64 {
	if x <= 0 {
		return 0
	}
	return math.ln(x) / math.ln(f64(2.0))
}

// Cents between two frequencies. Zero when either is missing, so a patch whose
// spectrum has no clear peak below 2 kHz does not contribute a fake error.
cents_between :: proc(ours, ref: f64) -> (cents: f64, ok: bool) {
	if ours <= 0 || ref <= 0 {
		return 0, false
	}
	return 1200.0 * log2f(ours / ref), true
}

median :: proc(values: []f64) -> f64 {
	if len(values) == 0 {
		return 0
	}
	sorted := slice.clone(values)
	defer delete(sorted)
	slice.sort(sorted)
	n := len(sorted)
	if n % 2 == 1 {
		return sorted[n / 2]
	}
	return 0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
}

mean :: proc(values: []f64) -> f64 {
	if len(values) == 0 {
		return 0
	}
	sum := 0.0
	for v in values {
		sum += v
	}
	return sum / f64(len(values))
}

// Odin's fmt pads a numeric field with zeros when given a width, which turns a
// column of decibel figures into 015.93. Numbers are therefore rendered to text
// first and padded as text.
pad_left :: proc(s: string, width: int) -> string {
	if len(s) >= width {
		return s
	}
	return fmt.tprintf("%v%v", strings.repeat(" ", width - len(s), context.temp_allocator), s)
}

dec0 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.0f", v), width)}
dec4 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.4f", v), width)}
dec5 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.5f", v), width)}
dec6 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.6f", v), width)}
sdec0 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%+.0f", v), width)}
dec1 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.1f", v), width)}
dec2 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.2f", v), width)}
dec3 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%.3f", v), width)}
sdec1 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%+.1f", v), width)}
sdec2 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%+.2f", v), width)}
sdec3 :: proc(v: f64, width := 0) -> string {return pad_left(fmt.tprintf("%+.3f", v), width)}

release_text :: proc(ms: f64, width := 0) -> string {
	if ms < 0 {
		return pad_left(">tail", width)
	}
	return dec0(ms, width)
}

print_verbose :: proc(row: Row) {
	c := row.c
	fmt.printfln("%v", row.name)
	fmt.printfln(
		"  level       ref rms %v  ours %v  -> %v dB   (peak %v / %v)",
		dec5(c.ref_rms), dec5(c.our_rms), sdec2(c.level_db), dec4(c.ref_peak), dec4(c.our_peak))
	fmt.printfln(
		"  null        %v dB at lag %v samples, correlation %v, fitted gain %v",
		dec2(c.null_db), c.best_lag, dec4(c.correlation), dec4(c.null_gain))
	if c.spectral_valid {
		fmt.printfln(
			"  spectrum    %v dB mean over %v bands, worst %v dB at %v Hz",
			dec2(c.spectral_db), c.bands_compared,
			dec1(c.spectral_worst_db), dec0(c.spectral_worst_hz))
	} else {
		fmt.printfln(
			"  spectrum    not comparable: sustain-window rms ref %v, ours %v",
			dec6(c.ref_steady_rms), dec6(c.our_steady_rms))
	}
	fmt.printfln(
		"  centroid    ref %v Hz  ours %v Hz  (%v octaves)",
		dec0(c.ref_centroid_hz), dec0(c.our_centroid_hz),
		sdec2(log2f(c.our_centroid_hz / max(c.ref_centroid_hz, 1.0e-9))))
	cents, cents_ok := cents_between(c.our_fundamental_hz, c.ref_fundamental_hz)
	fmt.printfln(
		"  fundamental ref %v Hz  ours %v Hz  (%v)",
		dec2(c.ref_fundamental_hz), dec2(c.our_fundamental_hz),
		cents_ok ? fmt.tprintf("%v cents", sdec0(cents)) : "not comparable")
	fmt.printfln(
		"  envelope    %v dB mean;  time to peak ref %v ms / ours %v ms;  release ref %v ms / ours %v ms",
		dec2(c.envelope_db), dec0(c.ref_attack_ms), dec0(c.our_attack_ms),
		release_text(c.ref_release_ms), release_text(c.our_release_ms))
	fmt.printfln("  stereo      side/mid ref %v  ours %v", dec3(c.ref_width), dec3(c.our_width))
	if row.has_floor {
		f := row.floor
		fmt.printfln(
			"  floor       reference against itself: spectrum %v dB, envelope %v dB, level %v dB",
			dec2(f.spectral_db), dec2(f.envelope_db), sdec2(f.level_db))
	}
	if row.param_mismatches > 0 {
		fmt.printfln("  WARNING    %v parameters did not load into the reference", row.param_mismatches)
	}
	if c.ref_silent {
		fmt.println("  WARNING    the reference render is silent")
	}
	if c.our_silent {
		fmt.println("  WARNING    our render is silent")
	}
	if c.our_non_finite > 0 {
		fmt.printfln("  WARNING    our render contains %v non-finite samples", c.our_non_finite)
	}
	fmt.println()
}

print_summary :: proc(rows: []Row) {
	if len(rows) == 0 {
		fmt.println("no patches compared")
		return
	}

	spectral: [dynamic]f64;   defer delete(spectral)
	envelope: [dynamic]f64;   defer delete(envelope)
	level: [dynamic]f64;      defer delete(level)
	nulls: [dynamic]f64;      defer delete(nulls)
	floor_spectral: [dynamic]f64; defer delete(floor_spectral)
	floor_envelope: [dynamic]f64; defer delete(floor_envelope)
	floor_level: [dynamic]f64;    defer delete(floor_level)
	// Patches where the engine is no further from the reference than a second
	// reference render is. Nothing more can be measured about these here.
	at_floor := 0
	// Patches where our render had already decayed to silence before the
	// steady-state window, so there was no timbre left to compare.
	no_spectrum := 0
	centroid_oct: [dynamic]f64; defer delete(centroid_oct)
	cents: [dynamic]f64;      defer delete(cents)
	release_ratio: [dynamic]f64; defer delete(release_ratio)
	attack_delta: [dynamic]f64;  defer delete(attack_delta)
	width_delta: [dynamic]f64;   defer delete(width_delta)

	ref_silent := 0
	our_silent := 0
	non_finite := 0
	param_bad := 0
	in_tune := 0
	octave_out := 0
	pitch_unclear := 0

	for row in rows {
		c := row.c
		if row.param_mismatches > 0 {
			param_bad += 1
		}
		if c.ref_silent {
			ref_silent += 1
		}
		if c.our_silent {
			our_silent += 1
		}
		if c.our_non_finite > 0 {
			non_finite += 1
		}
		if c.ref_silent || c.our_silent {
			continue
		}

		if c.spectral_valid {
			append(&spectral, c.spectral_db)
		} else {
			no_spectrum += 1
		}
		append(&envelope, c.envelope_db)
		append(&level, c.level_db)
		append(&nulls, c.null_db)
		append(&width_delta, c.our_width - c.ref_width)

		if row.has_floor && !row.floor.ref_silent && !row.floor.our_silent && row.floor.spectral_valid {
			append(&floor_spectral, row.floor.spectral_db)
			append(&floor_envelope, row.floor.envelope_db)
			append(&floor_level, row.floor.level_db)
			if c.spectral_valid && c.spectral_db <= row.floor.spectral_db {
				at_floor += 1
			}
		}

		if c.ref_centroid_hz > 0 && c.our_centroid_hz > 0 {
			append(&centroid_oct, log2f(c.our_centroid_hz / c.ref_centroid_hz))
		}
		// Tuning, from the log-frequency alignment of the two spectra rather than
		// from comparing each render's loudest partial. The old reading called eight
		// bank patches an octave out when all eight were exactly in tune and merely
		// disagreed about which harmonic was loudest -- by as little as 3.5 dB.
		//
		// A low correlation is excluded rather than reported: it means the two
		// spectra do not resemble each other under any shift, which is a statement
		// about timbre, and a detuning read off it would be noise.
		if c.pitch_confidence >= PITCH_CONFIDENCE_MIN {
			append(&cents, c.pitch_cents)
			if abs(c.pitch_cents) < 10.0 {
				in_tune += 1
			}
			if abs(abs(c.pitch_cents) - 1200.0) < 60.0 {
				octave_out += 1
			}
		} else {
			pitch_unclear += 1
		}
		if c.ref_release_ms > 0 && c.our_release_ms > 0 {
			append(&release_ratio, log2f(c.our_release_ms / c.ref_release_ms))
		}
		if c.ref_attack_ms >= 0 && c.our_attack_ms >= 0 {
			append(&attack_delta, c.our_attack_ms - c.ref_attack_ms)
		}
	}

	fmt.println()
	fmt.println("================================ summary ================================")
	fmt.printfln("patches compared            : %v", len(rows))
	fmt.printfln("reference silent            : %v", ref_silent)
	fmt.printfln("ours silent                 : %v", our_silent)
	fmt.printfln("ours non-finite             : %v", non_finite)
	fmt.printfln("patches that failed to load : %v", param_bad)
	fmt.printfln("ours silent by the sustain  : %v  (no timbre left to compare)", no_spectrum)
	fmt.println()

	fmt.println("-- how close are we, per patch --")
	fmt.printfln("spectral error   mean %v dB   median %v dB   (0 = identical timbre)",
		dec2(mean(spectral[:]), 6), dec2(median(spectral[:]), 6))
	fmt.printfln("envelope error   mean %v dB   median %v dB   (0 = identical contour)",
		dec2(mean(envelope[:]), 6), dec2(median(envelope[:]), 6))
	fmt.printfln("level error      mean %v dB   median %v dB",
		sdec2(mean(level[:]), 6), sdec2(median(level[:]), 6))
	fmt.printfln("null depth       mean %v dB   median %v dB   (0 = no cancellation)",
		dec2(mean(nulls[:]), 6), dec2(median(nulls[:]), 6))
	fmt.println()

	if len(floor_spectral) > 0 {
		fmt.println("-- measurement floor: the reference against a second render of itself --")
		fmt.printfln("spectral floor   mean %v dB   median %v dB",
			dec2(mean(floor_spectral[:]), 6), dec2(median(floor_spectral[:]), 6))
		fmt.printfln("envelope floor   mean %v dB   median %v dB",
			dec2(mean(floor_envelope[:]), 6), dec2(median(floor_envelope[:]), 6))
		fmt.printfln("level floor      mean %v dB   median %v dB",
			sdec2(mean(floor_level[:]), 6), sdec2(median(floor_level[:]), 6))
		fmt.printfln("patches already at the floor: %v/%v", at_floor, len(floor_spectral))
		fmt.println()
		fmt.println("A patch at the floor is as close as this test can resolve. The gap")
		fmt.println("between the two blocks above is the part that is genuinely ours.")
		fmt.println()
	}

	// These are the numbers that turn a guess into a measurement. A systematic
	// bias here is a mapping constant that is wrong by exactly that much, and it
	// is the same wrong on every patch; scatter with no bias means the mapping
	// is right on average and something patch-specific is off instead.
	// Each line carries the number of patches it was computed from. Not
	// decoration: these aggregates are over different subsets, because a metric
	// is only included where both renders produced something to compare. The
	// release figure in particular is computed only from patches where *both*
	// tails finish inside the render, which on this bank is a handful rather
	// than all of them -- and a mean over nine patches printed next to a mean
	// over a hundred, with nothing to tell them apart, invites exactly the
	// conclusion the data cannot support.
	fmt.println("-- systematic bias, i.e. which mapping constant is wrong --")
	fmt.printfln("brightness       mean %v octaves  median %v   n=%v  (our centroid vs reference)",
		sdec2(mean(centroid_oct[:]), 6), sdec2(median(centroid_oct[:]), 6), len(centroid_oct))
	fmt.printfln(
		"tuning           mean %v cents    median %v   n=%v  (%v within 10 cents, %v an octave out)",
		sdec1(mean(cents[:]), 6),
		sdec1(median(cents[:]), 6),
		len(cents),
		in_tune,
		octave_out,
	)
	if pitch_unclear > 0 {
		fmt.printfln(
			"                 %v more excluded: the two spectra do not align under any shift,",
			pitch_unclear,
		)
		fmt.println("                 which is a timbre difference and not a tuning one")
	}
	fmt.printfln("release length   mean %v octaves  median %v   n=%v  (our 60 dB time vs reference)",
		sdec2(mean(release_ratio[:]), 6), sdec2(median(release_ratio[:]), 6), len(release_ratio))
	fmt.printfln("time to peak     mean %v ms       median %v   n=%v",
		sdec1(mean(attack_delta[:]), 6), sdec1(median(attack_delta[:]), 6), len(attack_delta))
	fmt.printfln("stereo width     mean %v          median %v   n=%v  (side/mid, ours minus reference)",
		sdec3(mean(width_delta[:]), 6), sdec3(median(width_delta[:]), 6), len(width_delta))
	fmt.println()
	if len(release_ratio) * 4 < len(rows) {
		fmt.printfln("The release figure is from %v of %v patches: on the rest the reference's",
			len(release_ratio), len(rows))
		fmt.println("tail outlasts the render, so there is no 60 dB time to compare against.")
		fmt.println()
	}

	// Worst offenders by timbre, which is the metric that most often points at
	// a feature that is missing rather than a constant that is off.
	ranked := slice.clone(rows)
	defer delete(ranked)
	slice.sort_by(ranked, proc(a, b: Row) -> bool {
		// An incomparable spectrum sorts last rather than first: its stored zero
		// is the absence of a measurement, not a good one.
		av := a.c.spectral_valid ? a.c.spectral_db : -1.0
		bv := b.c.spectral_valid ? b.c.spectral_db : -1.0
		return av > bv
	})
	fmt.println("-- worst 10 by spectral error --")
	shown := min(10, len(ranked))
	for i in 0 ..< shown {
		r := ranked[i]
		if !r.c.spectral_valid {
			continue
		}
		fmt.printfln("  %-16v %v dB   worst band %v Hz (%v dB)   envelope %v dB",
			r.name, dec2(r.c.spectral_db, 6), dec0(r.c.spectral_worst_hz, 5),
			dec1(r.c.spectral_worst_db, 5), dec2(r.c.envelope_db, 5))
	}
	fmt.println("=========================================================================")
}

CSV_HEADER :: "patch,spectral_valid,spectral_db,spectral_worst_db,spectral_worst_hz,envelope_db,level_db,null_db,correlation,lag,ref_centroid_hz,our_centroid_hz,ref_f0_hz,our_f0_hz,pitch_cents,pitch_confidence,ref_attack_ms,our_attack_ms,ref_release_ms,our_release_ms,ref_width,our_width,ref_peak,our_peak,ref_steady_rms,our_steady_rms,param_mismatches,ref_silent,our_silent,has_floor,floor_spectral_valid,floor_spectral_db,floor_envelope_db,floor_level_db"

skip_patch :: proc(list, name: string) -> bool {
	if list == "" {
		return false
	}
	entries := strings.split(list, ",")
	defer delete(entries)
	for entry in entries {
		if strings.trim_space(entry) == name {
			return true
		}
	}
	return false
}

// Start the CSV: write the header, unless we are continuing into a file that
// already has one.
csv_begin :: proc(path: string, resuming: bool) -> bool {
	if resuming {
		if prior, err := os.read_entire_file(path, context.allocator); err == nil {
			defer delete(prior, context.allocator)
			if len(prior) > 0 {
				return true
			}
		}
	}
	header := fmt.tprintf("%v\n", CSV_HEADER)
	return os.write_entire_file(path, transmute([]u8)header) == nil
}

// Append one finished patch.
//
// Per patch rather than once at the end, because the reference can take the
// whole process down mid-run and a report that only exists in memory does not
// survive that. With this, a crash costs exactly the patch it happened on.
csv_append_row :: proc(path: string, row: Row) -> bool {
	handle, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err != nil {
		return false
	}
	defer os.close(handle)
	line := csv_row_text(row)
	defer delete(line)
	_, write_err := os.write_string(handle, line)
	return write_err == nil
}

csv_row_text :: proc(row: Row) -> string {
	b := strings.builder_make()
	{
		r := row
		c := r.c
		fmt.sbprintf(
			&b,
			"%v,%v,%.4f,%.4f,%.1f,%.4f,%.4f,%.4f,%.6f,%v," +
			"%.1f,%.1f,%.3f,%.3f,%.2f,%.4f,%.1f,%.1f,%.1f,%.1f," +
			"%.4f,%.4f,%.6f,%.6f,%.8f,%.8f,%v,%v,%v,%v," +
			"%v,%.4f,%.4f,%.4f\n",
			r.name, c.spectral_valid, c.spectral_db, c.spectral_worst_db, c.spectral_worst_hz,
			c.envelope_db, c.level_db, c.null_db, c.correlation, c.best_lag,
			c.ref_centroid_hz, c.our_centroid_hz, c.ref_fundamental_hz, c.our_fundamental_hz,
			c.pitch_cents, c.pitch_confidence,
			c.ref_attack_ms, c.our_attack_ms, c.ref_release_ms, c.our_release_ms,
			c.ref_width, c.our_width, c.ref_peak, c.our_peak,
			c.ref_steady_rms, c.our_steady_rms,
			r.param_mismatches, c.ref_silent, c.our_silent,
			r.has_floor, r.floor.spectral_valid,
			r.floor.spectral_db, r.floor.envelope_db, r.floor.level_db,
		)
	}
	return strings.to_string(b)
}

// Rebuild the rows a previous run wrote, so a bank measured across several
// processes still produces one report.
read_csv :: proc(path: string) -> (rows: [dynamic]Row, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return nil, false
	}
	defer delete(data, context.allocator)

	lines := strings.split_lines(string(data))
	defer delete(lines)
	if len(lines) < 2 {
		return nil, false
	}

	// Columns are looked up by header name rather than by position, so a file
	// written by a build with a different column order still reads correctly.
	headers := strings.split(strings.trim_space(lines[0]), ",")
	defer delete(headers)
	column := proc(headers: []string, name: string) -> int {
		for h, i in headers {
			if h == name {
				return i
			}
		}
		return -1
	}

	num :: proc(fields: []string, idx: int) -> f64 {
		if idx < 0 || idx >= len(fields) {
			return 0
		}
		v, _ := strconv.parse_f64(strings.trim_space(fields[idx]))
		return v
	}
	flag :: proc(fields: []string, idx: int) -> bool {
		if idx < 0 || idx >= len(fields) {
			return false
		}
		return strings.trim_space(fields[idx]) == "true"
	}

	i_name := column(headers, "patch")
	i_sv := column(headers, "spectral_valid")
	i_sd := column(headers, "spectral_db")
	i_swd := column(headers, "spectral_worst_db")
	i_swh := column(headers, "spectral_worst_hz")
	i_env := column(headers, "envelope_db")
	i_lvl := column(headers, "level_db")
	i_null := column(headers, "null_db")
	i_rc := column(headers, "ref_centroid_hz")
	i_oc := column(headers, "our_centroid_hz")
	i_rf := column(headers, "ref_f0_hz")
	i_of := column(headers, "our_f0_hz")
	i_pc := column(headers, "pitch_cents")
	i_pq := column(headers, "pitch_confidence")
	i_ra := column(headers, "ref_attack_ms")
	i_oa := column(headers, "our_attack_ms")
	i_rr := column(headers, "ref_release_ms")
	i_or := column(headers, "our_release_ms")
	i_rw := column(headers, "ref_width")
	i_ow := column(headers, "our_width")
	i_rs := column(headers, "ref_silent")
	i_os := column(headers, "our_silent")
	i_pm := column(headers, "param_mismatches")
	i_hf := column(headers, "has_floor")
	i_fv := column(headers, "floor_spectral_valid")
	i_fs := column(headers, "floor_spectral_db")
	i_fe := column(headers, "floor_envelope_db")
	i_fl := column(headers, "floor_level_db")

	for line in lines[1:] {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		fields := strings.split(trimmed, ",")
		defer delete(fields)
		if i_name < 0 || i_name >= len(fields) {
			continue
		}

		r: Row
		r.name = strings.clone(fields[i_name])
		r.c.spectral_valid = flag(fields, i_sv)
		r.c.spectral_db = num(fields, i_sd)
		r.c.spectral_worst_db = num(fields, i_swd)
		r.c.spectral_worst_hz = num(fields, i_swh)
		r.c.envelope_db = num(fields, i_env)
		r.c.level_db = num(fields, i_lvl)
		r.c.null_db = num(fields, i_null)
		r.c.ref_centroid_hz = num(fields, i_rc)
		r.c.our_centroid_hz = num(fields, i_oc)
		r.c.ref_fundamental_hz = num(fields, i_rf)
		r.c.our_fundamental_hz = num(fields, i_of)
		r.c.pitch_cents = num(fields, i_pc)
		r.c.pitch_confidence = num(fields, i_pq)
		r.c.ref_attack_ms = num(fields, i_ra)
		r.c.our_attack_ms = num(fields, i_oa)
		r.c.ref_release_ms = num(fields, i_rr)
		r.c.our_release_ms = num(fields, i_or)
		r.c.ref_width = num(fields, i_rw)
		r.c.our_width = num(fields, i_ow)
		r.c.ref_silent = flag(fields, i_rs)
		r.c.our_silent = flag(fields, i_os)
		r.param_mismatches = int(num(fields, i_pm))
		r.has_floor = flag(fields, i_hf)
		r.floor.spectral_valid = flag(fields, i_fv)
		r.floor.spectral_db = num(fields, i_fs)
		r.floor.envelope_db = num(fields, i_fe)
		r.floor.level_db = num(fields, i_fl)
		append(&rows, r)
	}
	return rows, true
}

cmd_summarise :: proc(path: string) {
	rows, ok := read_csv(path)
	if !ok {
		fmt.eprintfln("summarise: cannot read %q", path)
		os.exit(1)
	}
	defer {
		for r in rows {
			delete(r.name)
		}
		delete(rows)
	}
	fmt.printfln("summarising %v patch(es) from %v", len(rows), path)
	print_summary(rows[:])
}

// ------------------------------------------------------------------- command

Compare_Options :: struct {
	wav_dir: string,
	csv:     string,
	note:    u8,
	limit:   int,
	verbose:  bool,
	// Skip the second reference render. Faster, but every result then has no
	// measurement floor beside it and cannot be read on its own.
	no_floor: bool,
	// Skip this many patches before starting. With `--csv` this is what makes a
	// bank larger than one process's instantiation budget measurable: run it in
	// chunks that append to one file, then `--summarise` the file.
	offset:   int,
	// Comma-separated patch file names to leave out, for patches the reference
	// binary cannot render without crashing.
	skip:     string,
	// Render each patch in a child process, so a patch that crashes the
	// reference costs one row instead of the rest of the run. See isolate.odin.
	// On for any run of more than one patch; this asks for it on a single one.
	isolate:  bool,
	// Off again, for the one case that wants this process to do the rendering:
	// a debugger attached to the run that is expected to die.
	no_isolate: bool,
	// Set by isolate.odin on the children it spawns. Suppresses the preamble,
	// the table header and the summary, so a child contributes exactly its own
	// row and the parent owns everything around it.
	child:    bool,
	// Frames per process() call. 0 uses the size the plugin was told at load.
	block:    int,
	// Control mode: render the reference twice instead of comparing against our
	// engine. Every number it prints is the harness's own noise floor -- the
	// error this test reports for two renders that are by definition identical
	// in every design decision. Without it there is no way to tell a 16 dB
	// spectral error caused by the engine from one caused by the measurement.
	self:    bool,
}

cmd_compare :: proc(dll, target: string, opt: Compare_Options) {
	// A child announces nothing about loading the library: the parent already
	// did, and one line per patch across a bank is pages of it.
	if opt.child {
		g_quiet_load = true
	}
	set_compare_timing(opt.block > 0 ? opt.block : COMPARE_BLOCK_DEFAULT)

	// One load up front, purely to read the factory state chunk that every patch
	// is written into and to report the plugin's latency. It is unloaded again
	// before any measuring starts, so no instance outlives the render it serves.
	pristine: []byte
	initial_delay: i32
	{
		p, plugin_ok := load(dll)
		if !plugin_ok {
			os.exit(1)
		}
		pristine = get_chunk_copy(&p, 0)
		initial_delay = p.eff.initial_delay
		unload(&p)
	}
	if len(pristine) == 0 {
		fmt.eprintln("compare: the plugin returned an empty state chunk")
		os.exit(1)
	}
	defer delete(pristine)

	// Each render loads the library again; announcing it 300 times is noise.
	g_quiet_load = true
	if CHUNK_VALUE_BASE + (cpatch.PARAMETER_COUNT - 1) * CHUNK_VALUE_STRIDE + 4 > len(pristine) {
		fmt.eprintfln("compare: state chunk is %v bytes, too small for %v parameters",
			len(pristine), cpatch.PARAMETER_COUNT)
		os.exit(1)
	}
	work := make([]byte, len(pristine))
	defer delete(work)

	// Collect the patch list: a single file or every .sy1 in a directory.
	paths: [dynamic]string
	defer {
		for s in paths {
			delete(s)
		}
		delete(paths)
	}

	if strings.has_suffix(strings.to_lower(target), ".sy1") {
		append(&paths, strings.clone(target))
	} else {
		entries, dir_err := os.read_directory_by_path(target, -1, context.allocator)
		if dir_err != nil {
			fmt.eprintfln("compare: cannot read %q: %v", target, dir_err)
			os.exit(1)
		}
		defer os.file_info_slice_delete(entries, context.allocator)
		for info in entries {
			if strings.has_suffix(info.name, ".sy1") {
				append(&paths, strings.clone(info.fullpath))
			}
		}
		slice.sort(paths[:])
	}

	if len(paths) == 0 {
		fmt.eprintfln("compare: no .sy1 files at %q", target)
		os.exit(1)
	}
	total_available := len(paths)
	if opt.offset > 0 {
		if opt.offset >= len(paths) {
			fmt.eprintfln("compare: offset %v is past the %v patches at %q",
				opt.offset, len(paths), target)
			os.exit(1)
		}
		ordered_remove_range(&paths, 0, opt.offset)
	}
	if opt.limit > 0 && opt.limit < len(paths) {
		resize(&paths, opt.limit)
	}

	if opt.wav_dir != "" {
		_ = os.make_directory(opt.wav_dir)
	}
	// A child always appends: the parent wrote the header before it spawned
	// anything, and a child that truncated would leave the file holding only
	// whichever patch happened to finish last.
	if opt.csv != "" && !csv_begin(opt.csv, opt.offset > 0 || opt.child) {
		fmt.eprintfln("compare: cannot write %v", opt.csv)
		os.exit(1)
	}

	// Each patch in its own process. The children print their own rows, so the
	// output reads as one run; the parent only notices which of them died.
	//
	// On by default for any run of more than one patch, which is the change that
	// stops a bank run dying. It used to be opt-in, so the default behaviour of
	// this tool was to stop at the first patch that kills the reference and
	// leave every patch after it unmeasured -- and the documented way round that
	// was `--skip` with five file names in it, which only helps somebody who
	// already knows which five. `tools/s1probe hostprobe` and `paramcrash` say
	// what the crash is: the arpeggiator, inside the reference, whatever this
	// host tells it. It is not ours to fix, so the harness stops depending on it
	// not happening.
	isolating := !opt.child && !opt.no_isolate && (opt.isolate || len(paths) > 1)
	if isolating {
		exe, exe_ok := self_path()
		if !exe_ok {
			fmt.eprintln("compare: cannot find this executable to isolate with")
			os.exit(1)
		}
		defer delete(exe)

		fmt.printfln("comparing %v patch(es) against %v, one process each", len(paths), dll)
		fmt.println()
		if !opt.verbose {
			fmt.printfln("%-16v %8v %8v %8v %8v  %-13v %-13v",
				"patch", "spec dB", "env dB", "lvl dB", "null dB", "centroid Hz", "release ms")
			fmt.println(strings.repeat("-", 88, context.temp_allocator))
		}
		crashed: [dynamic]string
		defer delete(crashed)

		for path in paths {
			name := path
			if idx := strings.last_index_any(path, "/\\"); idx >= 0 {
				name = path[idx + 1:]
			}
			if skip_patch(opt.skip, name) {
				fmt.printfln("%-16v skipped", name)
				continue
			}
			code, spawned := run_isolated(exe, dll, path, opt)
			if !spawned {
				fmt.eprintfln("%-16v could not start a child process", name)
				continue
			}
			if code != 0 {
				fmt.printfln("%-16v %v", name, exit_reason(code))
				append(&crashed, name)
			}
		}

		if len(crashed) > 0 {
			fmt.printfln("\n%v patch(es) killed the reference:", len(crashed))
			for name in crashed {
				fmt.printfln("  %v", name)
			}
			fmt.println("The run completed anyway; see the note above g_instantiations.")
		}
		return
	}

	// A child renders one patch and prints one row. Everything around the rows
	// -- the preamble, the header, the summary at the end -- belongs to whoever
	// spawned it, or the output would repeat once per patch.
	if !opt.child {
		fmt.printfln("comparing %v patch(es) against %v", len(paths), dll)
		fmt.printfln("note %v, velocity %v, %.1f s held + %.1f s tail at %v Hz",
			opt.note, COMPARE_VELOCITY_MIDI,
			f64(g_hold_frames) / f64(SAMPLE_RATE),
			f64(g_total_frames - g_hold_frames) / f64(SAMPLE_RATE),
			SAMPLE_RATE)
		fmt.printfln("reference reports %v samples of initial delay", initial_delay)
		if opt.self {
			fmt.println()
			fmt.println("CONTROL RUN: both sides are the reference plugin. Everything printed")
			fmt.println("below is the harness's own noise floor, not an engine defect.")
		}
		fmt.println()

		if !opt.verbose {
			fmt.printfln("%-16v %8v %8v %8v %8v  %-13v %-13v",
				"patch", "spec dB", "env dB", "lvl dB", "null dB", "centroid Hz", "release ms")
			fmt.println(strings.repeat("-", 88, context.temp_allocator))
		}
	}

	rows: [dynamic]Row
	defer {
		for r in rows {
			delete(r.name)
		}
		delete(rows)
	}

	residual := make([]f32, g_total_frames)
	defer delete(residual)

	for path, patch_index in paths {
		name := path
		if idx := strings.last_index_any(path, "/\\"); idx >= 0 {
			name = path[idx + 1:]
		}

		if skip_patch(opt.skip, name) {
			fmt.printfln("%-16v skipped", name)
			continue
		}

		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			fmt.eprintfln("%v: cannot read: %v", name, read_err)
			continue
		}
		// parse_sy1 borrows out of `data`, so the buffer has to outlive the patch.
		parsed, parse_err := cpatch.parse_sy1(data)
		if parse_err != .None {
			fmt.eprintfln("%v: cannot parse: %v", name, parse_err)
			delete(data, context.allocator)
			continue
		}

		ref_audio, mismatches, ref_ok := render_reference_fresh(dll, &parsed, pristine, work, opt.note)
		if !ref_ok {
			fmt.eprintfln("%v: could not load the reference plugin", name)
			delete(data, context.allocator)
			continue
		}

		// A second reference render through the identical path, so the floor
		// measures the whole harness rather than the plugin being run twice from
		// a warm state.
		second_ref: []f32
		if opt.self || !opt.no_floor {
			second, _, second_ok := render_reference_fresh(dll, &parsed, pristine, work, opt.note)
			if second_ok {
				second_ref = second
			}
		}
		defer delete(second_ref)

		our_audio: []f32
		if opt.self {
			if second_ref == nil {
				fmt.eprintfln("%v: control run needs a second reference render", name)
				delete(ref_audio)
				delete(data, context.allocator)
				continue
			}
			our_audio = second_ref
		} else {
			our_audio = render_ours(parsed, int(opt.note))
		}

		for i in 0 ..< len(residual) {
			residual[i] = 0
		}
		c := compare_renders(
			ref_audio,
			our_audio,
			2,
			f64(SAMPLE_RATE),
			f64(g_hold_frames) / f64(SAMPLE_RATE),
			residual,
		)

		row := Row {
			name             = strings.clone(name),
			c                = c,
			param_mismatches = mismatches,
		}
		// In --self mode the comparison *is* the floor, so measuring it twice
		// would only assert that the same call returns the same answer.
		if second_ref != nil && !opt.self {
			row.floor = compare_renders(
				ref_audio,
				second_ref,
				2,
				f64(SAMPLE_RATE),
				f64(g_hold_frames) / f64(SAMPLE_RATE),
			)
			row.has_floor = true
		}
		append(&rows, row)
		if opt.csv != "" {
			if !csv_append_row(opt.csv, row) {
				fmt.eprintfln("compare: could not append to %v", opt.csv)
			}
		}

		if opt.wav_dir != "" {
			stem := name
			if idx := strings.last_index(stem, "."); idx > 0 {
				stem = stem[:idx]
			}
			wav_write_f32(fmt.tprintf("%v/%v.ref.wav", opt.wav_dir, stem), ref_audio, 2, SAMPLE_RATE)
			wav_write_f32(fmt.tprintf("%v/%v.ours.wav", opt.wav_dir, stem), our_audio, 2, SAMPLE_RATE)
			wav_write_f32(fmt.tprintf("%v/%v.residual.wav", opt.wav_dir, stem), residual, 1, SAMPLE_RATE)
		}

		if opt.verbose {
			print_verbose(row)
		} else {
			flag := ""
			if c.our_silent {
				flag = "  SILENT"
			} else if !c.spectral_valid {
				flag = "  NO SUSTAIN"
			} else if c.our_non_finite > 0 {
				flag = "  NON-FINITE"
			} else if mismatches > 0 {
				flag = "  LOAD FAILED"
			}
			spec := c.spectral_valid ? dec2(c.spectral_db, 8) : pad_left("n/a", 8)
			fmt.printfln("%-16v %v %v %v %v  %v/%-7v %v/%v%v",
				name, spec, dec2(c.envelope_db, 8),
				sdec2(c.level_db, 8), dec2(c.null_db, 8),
				dec0(c.ref_centroid_hz, 5), dec0(c.our_centroid_hz),
				release_text(c.ref_release_ms), release_text(c.our_release_ms),
				flag)
		}

		delete(ref_audio)
		// In control mode `our_audio` aliases `second_ref`, which the deferred
		// delete above already owns.
		if !opt.self {
			delete(our_audio)
		}
		delete(data, context.allocator)
		free_all(context.temp_allocator)
	}

	if opt.csv != "" {
		fmt.printfln("wrote %v rows to %v", len(rows), opt.csv)
	}
	if opt.wav_dir != "" {
		fmt.printfln("wrote per-patch WAVs to %v", opt.wav_dir)
	}
	if opt.child {
		return
	}
	if len(rows) < total_available - opt.offset {
		fmt.printfln("note: %v of %v patches in range were skipped",
			(total_available - opt.offset) - len(rows), total_available - opt.offset)
	}

	print_summary(rows[:])
}

// Drop the first `count` paths, freeing them: the entries are owned clones, so
// shifting over them without a delete would leak one string per skipped patch.
ordered_remove_range :: proc(a: ^[dynamic]string, from, count: int) {
	n := len(a)
	if count <= 0 || from < 0 || from >= n {
		return
	}
	remove := min(count, n - from)
	for i in from ..< from + remove {
		delete(a[i])
	}
	for i in from ..< n - remove {
		a[i] = a[i + remove]
	}
	resize(a, n - remove)
}

// Parse the compare-specific options out of the argument tail, returning the
// target path and the options.
parse_compare_args :: proc(args: []string) -> (target: string, opt: Compare_Options, ok: bool) {
	opt.note = COMPARE_NOTE_DEFAULT
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--wav":
			if i + 1 >= len(args) {return "", opt, false}
			opt.wav_dir = args[i + 1]
			i += 2
		case "--csv":
			if i + 1 >= len(args) {return "", opt, false}
			opt.csv = args[i + 1]
			i += 2
		case "--note":
			if i + 1 >= len(args) {return "", opt, false}
			n, _ := strconv.parse_int(args[i + 1])
			opt.note = u8(clamp(n, 0, 127))
			i += 2
		case "--limit":
			if i + 1 >= len(args) {return "", opt, false}
			opt.limit, _ = strconv.parse_int(args[i + 1])
			i += 2
		case "--verbose":
			opt.verbose = true
			i += 1
		case "--self":
			opt.self = true
			i += 1
		case "--child":
			opt.child = true
			i += 1
		case "--isolate":
			opt.isolate = true
			i += 1
		case "--no-isolate":
			opt.no_isolate = true
			i += 1
		case "--no-floor":
			opt.no_floor = true
			i += 1
		case "--block":
			if i + 1 >= len(args) {return "", opt, false}
			opt.block, _ = strconv.parse_int(args[i + 1])
			i += 2
		case "--offset":
			if i + 1 >= len(args) {return "", opt, false}
			opt.offset, _ = strconv.parse_int(args[i + 1])
			i += 2
		case "--skip":
			if i + 1 >= len(args) {return "", opt, false}
			opt.skip = args[i + 1]
			i += 2
		case:
			if target != "" {
				return "", opt, false
			}
			target = a
			i += 1
		}
	}
	if target == "" {
		return "", opt, false
	}
	return target, opt, true
}

pad_right :: proc(s: string, width: int) -> string {
	if len(s) >= width {
		return s
	}
	return fmt.tprintf("%v%v", s, strings.repeat(" ", width - len(s), context.temp_allocator))
}
