// s1probe envprobe - measure the reference's envelope time curve.
//
// `src/engine/binding.odin` maps a stored 0..127 envelope parameter onto
// seconds through a curve its own comment admits is invented: 1 ms to 12 s,
// exponential, "chosen, not measured". The null test says that curve is the
// engine's largest single defect. This subcommand replaces the guess with a
// measurement.
//
//   s1probe envprobe [dll] <attack|decay|release> [options]
//
//     --values <list|all>  stored values to sweep (default: a 20-point spread)
//     --hold <ms>          how long the note is held
//     --tail <ms>          how long to render after note off
//     --note <n>           MIDI note (default 108, C8)
//     --csv <path>         write the measured table
//     --dump               print what the plugin says the probe patch is set to
//
// Method: build a patch that isolates the amplitude envelope, sweep one of its
// segments, render each setting through the reference, and read the segment's
// duration back out of the audio. Nothing here infers a curve from a formula;
// the numbers come out of the binary.
package s1probe

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import cpatch "../../src/patch"

Env_Segment :: enum {
	Attack,
	Decay,
	Release,
}

// C8. The analysis frame has to hold at least one cycle for the peak within it
// to be the envelope rather than a point on the waveform, so the note sets the
// finest resolution available: at middle C that floor is 3.8 ms, at C8 it is
// 0.24 ms. The fastest settings of every segment land in single-digit
// milliseconds, and at C6 the bottom of the release curve came out visibly
// quantised -- 9.6, 8.5, 8.7, 9.6 ms across the first four settings, a
// non-monotonic wobble the width of exactly one frame.
//
// The times themselves do not depend on the note. Measured: the same sweep at
// C6 and at C8 agrees to within 0.3 ms everywhere, which is what licenses
// choosing the note purely for resolution.
PROBE_NOTE :: u8(108)
PROBE_VELOCITY_MIDI :: u8(127)

// One analysis frame, and so the resolution of every time reported. Derived from
// the note rather than fixed, for the reason above.
g_probe_frame_ms: f64 = 1.0

set_probe_frame :: proc(note: u8) {
	hz := 440.0 * math.pow(f64(2.0), (f64(note) - 69.0) / 12.0)
	if hz <= 0 {
		g_probe_frame_ms = 1.0
		return
	}
	// A little over one period, so a frame's peak is the cycle's peak.
	g_probe_frame_ms = max(1.25 * 1000.0 / hz, 0.05)
}

// The probe patch.
//
// Everything that could colour or smear the amplitude over time is switched off,
// because the measurement reads the amplitude over time and cannot tell the
// envelope from something else shaping it. The filter is opened rather than
// bypassed and its envelope amount zeroed; the delay, chorus, extra effect unit,
// both LFOs, the arpeggiator, portamento, unison and the sub oscillator are all
// off; velocity sensitivity is zeroed so the fixed velocity cannot scale
// anything.
//
// The oscillator is a sine rather than a saw. A saw's peak within a frame
// depends on where the frame lands in the cycle; a sine's does not, and the
// point of this patch is to make the output's amplitude equal the envelope.
probe_patch :: proc(segment: Env_Segment, stored: int) -> cpatch.Patch {
	p := neutral_probe_patch()

	// -- oscillator: one sine ------------------------------------------------
	//
	// A sine rather than a saw. A saw's peak within a frame depends on where the
	// frame lands in the cycle; a sine's does not, and the point of this patch is
	// to make the output's amplitude equal the envelope.
	set_param(&p, 0, 0) // osc1 shape: sine
	set_param(&p, 5, 0) // osc mix: 100 : 0, oscillator 1 alone

	// -- filter: open, and not moving ----------------------------------------
	set_param(&p, 19, 127) // cutoff wide open

	// -- amplifier ------------------------------------------------------------
	set_param(&p, 29, 127) // full gain, for signal to noise

	// -- the segment under test ----------------------------------------------
	//
	// Each segment is isolated by making the other three degenerate, so the only
	// thing shaping the output is the one being measured.
	switch segment {
	case .Attack:
		// Sustain at maximum, so after the attack the level simply stays there
		// and the decay never runs.
		set_param(&p, 25, stored)
		set_param(&p, 26, 0)
		set_param(&p, 27, 127)
		set_param(&p, 28, 0)
	case .Decay:
		// Sustain at zero, so the decay runs all the way to silence.
		set_param(&p, 25, 0)
		set_param(&p, 26, stored)
		set_param(&p, 27, 0)
		set_param(&p, 28, 0)
	case .Release:
		// Instant attack, sustain at maximum: the note sits at full level until
		// note off, and everything after that is the release.
		set_param(&p, 25, 0)
		set_param(&p, 26, 0)
		set_param(&p, 27, 127)
		set_param(&p, 28, stored)
	}

	return p
}

// Peak amplitude per frame.
//
// Peak rather than RMS: at these frame lengths RMS is still partly measuring
// the waveform, and the peak of a sine over a whole cycle is its amplitude.
peak_envelope :: proc(x: []f32, frame_len: int) -> []f64 {
	if frame_len <= 0 || len(x) < frame_len {
		return nil
	}
	count := len(x) / frame_len
	env := make([]f64, count)
	for f in 0 ..< count {
		base := f * frame_len
		peak := 0.0
		for i in 0 ..< frame_len {
			a := abs(f64(x[base + i]))
			if a > peak {
				peak = a
			}
		}
		env[f] = peak
	}
	return env
}

// The frame at which the envelope first reaches `fraction` of `reference`,
// linearly interpolated between the two straddling frames so the answer is not
// quantised to the frame grid.
crossing_frame :: proc(env: []f64, from: int, reference, fraction: f64, rising: bool) -> (f64, bool) {
	if len(env) == 0 || reference <= 0 {
		return 0, false
	}
	target := reference * fraction
	start := clamp(from, 0, len(env) - 1)
	for f in start + 1 ..< len(env) {
		hit := rising ? (env[f] >= target) : (env[f] <= target)
		if !hit {
			continue
		}
		previous := env[f - 1]
		current := env[f]
		if current == previous {
			return f64(f), true
		}
		// Where between the two frames the target actually sits.
		t := (target - previous) / (current - previous)
		return f64(f - 1) + clamp(t, 0, 1), true
	}
	return 0, false
}

// What one setting of one segment measured.
//
// The three crossings are what say whether the segment is exponential. For an
// exponential the time to fall a given number of decibels is proportional to
// that number, so t(-60 dB) is exactly ten times t(-6 dB). A linear ramp gives a
// completely different ratio, so this distinguishes the two without assuming
// either.
Env_Measurement :: struct {
	stored:    int,
	ok:        bool,
	// Attack: time from note on to 90% of the final level.
	// Decay and release: time from the segment's start to -60 dB.
	time_ms:   f64,
	// Intermediate crossings, in the same units.
	t_early:   f64, // attack: to 10%.  decay/release: to -6 dB
	t_mid:     f64, // attack: to 50%.  decay/release: to -20 dB
	peak:      f64,
}

measure_segment :: proc(
	audio: []f32,
	channels: int,
	sample_rate: f64,
	hold_frames: int,
	segment: Env_Segment,
	stored: int,
) -> Env_Measurement {
	m := Env_Measurement {
		stored = stored,
	}

	mid, side := split_mid_side(audio, channels)
	defer delete(mid)
	defer delete(side)

	frame_len := int(g_probe_frame_ms * 0.001 * sample_rate)
	env := peak_envelope(mid, frame_len)
	defer delete(env)
	if len(env) == 0 {
		return m
	}

	for v in env {
		if v > m.peak {
			m.peak = v
		}
	}
	if m.peak < 1.0e-5 {
		return m
	}

	// Attack and decay both run while the note is held, so both must be measured
	// strictly inside the hold. Letting the search run past note off measures the
	// release instead and still returns a plausible number: an unconstrained
	// version of this reported the decay saturating at 510 ms and the attack at
	// 450 ms for every setting above the middle of the range, which is exactly
	// the length of the hold it happened to be using. Truncation has to be a
	// failure, so that the caller grows the render and asks again.
	held := clamp(hold_frames, 0, len(env))

	if segment == .Attack {
		if held < 8 {
			return m
		}
		window := env[:held]
		// The level the note settles at, rather than the running peak, so a
		// little overshoot cannot shorten the reported time.
		settled := window[held - 2]
		if settled <= 0 {
			return m
		}
		// The attack must have finished inside the hold. If the level is still
		// climbing at the end, whatever t90 says is an artefact of where the note
		// off landed.
		earlier := window[held * 4 / 5]
		if earlier <= 0 || abs(settled - earlier) / settled > 0.01 {
			return m
		}

		t10, ok10 := crossing_frame(window, 0, settled, 0.1, true)
		t50, ok50 := crossing_frame(window, 0, settled, 0.5, true)
		t90, ok90 := crossing_frame(window, 0, settled, 0.9, true)
		if !ok10 || !ok50 || !ok90 {
			return m
		}
		m.t_early = t10 * g_probe_frame_ms
		m.t_mid = t50 * g_probe_frame_ms
		m.time_ms = t90 * g_probe_frame_ms
		m.ok = true
		return m
	}

	// Decay starts at note on and must finish before note off; release starts at
	// note off and has the rest of the render.
	start := 0
	window := env
	if segment == .Release {
		start = held
		if start >= len(env) {
			return m
		}
	} else {
		if held < 8 {
			return m
		}
		window = env[:held]
	}
	// The level the segment falls from: the peak within a few frames of its
	// start, so a one-frame ripple at the boundary is not taken as the origin.
	origin := 0.0
	for f in start ..< min(start + 5, len(window)) {
		if window[f] > origin {
			origin = window[f]
		}
	}
	if origin <= 0 {
		return m
	}

	// -6 dB, -20 dB, -60 dB.
	t6, ok6 := crossing_frame(window, start, origin, 0.5011872, false)
	t20, ok20 := crossing_frame(window, start, origin, 0.1, false)
	t60, ok60 := crossing_frame(window, start, origin, 0.001, false)
	if !ok6 || !ok20 || !ok60 {
		// A segment longer than the render is a real answer, but not a number.
		return m
	}
	m.t_early = (t6 - f64(start)) * g_probe_frame_ms
	m.t_mid = (t20 - f64(start)) * g_probe_frame_ms
	m.time_ms = (t60 - f64(start)) * g_probe_frame_ms
	m.ok = true
	return m
}

// Report what the plugin thinks the probe patch is, rather than what this file
// intended it to be. Every "off" above is an assumption about a stored integer's
// meaning, and this is the cheap way to find out which ones are wrong.
dump_probe_patch :: proc(p: ^Plugin, indices: []int) {
	fmt.println("probe patch, as the reference reports it:")
	for i in indices {
		fmt.printfln("  %3v %-24v = %v",
			i, cpatch.PARAMETERS[i].name, dispatch_str(p, .GetParamDisplay, i32(i)))
	}
	fmt.println()
}

PROBE_DUMP_INDICES := []int {
	0, 5, 6, 7, 10, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
	25, 26, 27, 28, 29, 30, 37, 44, 45, 49, 59, 66, 73, 77, 95,
}

// How much room the segment under test is given, and how far that is allowed to
// grow.
//
// The measured release spans four orders of magnitude -- about 10 ms at stored 0
// and 40 s at 127 -- so a fixed render length is either too short for the top of
// the range or wasteful for all of it. Each setting starts small and the room
// doubles until the segment fits, which makes the sweep fast where the envelope
// is fast and correct where it is slow.
PROBE_ROOM_START_MS :: 500
PROBE_ROOM_MAX_MS :: 96000

// Room for the parts of the render that are not under test: enough to establish
// a level to measure from, and no more.
PROBE_SETTLE_MS :: 300

set_probe_timing :: proc(segment: Env_Segment, room_ms: int) {
	set_compare_timing(COMPARE_BLOCK_DEFAULT)
	blocks :: proc(ms: int) -> int {
		return (ms * SAMPLE_RATE / 1000 + g_block - 1) / g_block
	}
	// Attack and decay both run while the note is held; release runs after it.
	hold_ms := segment == .Release ? PROBE_SETTLE_MS : room_ms
	tail_ms := segment == .Release ? room_ms : PROBE_SETTLE_MS
	held := blocks(hold_ms)
	g_hold_frames = held * g_block
	g_total_frames = (held + blocks(tail_ms)) * g_block
}

probe_env_frames_held :: proc() -> int {
	return g_hold_frames / int(g_probe_frame_ms * 0.001 * f64(SAMPLE_RATE))
}

// Render one setting, growing the render until the segment fits inside it.
probe_one :: proc(
	dll: string,
	pristine, work: []byte,
	segment: Env_Segment,
	stored: int,
	note: u8,
	start_room_ms: int,
	dump: ^bool,
) -> (
	m: Env_Measurement,
	room_ms: int,
) {
	room_ms = max(start_room_ms, PROBE_ROOM_START_MS)
	for {
		set_probe_timing(segment, room_ms)
		patch := probe_patch(segment, stored)

		p, plugin_ok := open_reference(dll)
		if !plugin_ok {
			m.stored = stored
			return m, room_ms
		}
		load_reference_patch(&p, &patch, pristine, work)
		if dump != nil && !dump^ {
			dump_probe_patch(&p, PROBE_DUMP_INDICES)
			dump^ = true
		}
		audio := render_reference_note(&p, note, PROBE_VELOCITY_MIDI)
		close_reference(&p)

		m = measure_segment(audio, 2, f64(SAMPLE_RATE), probe_env_frames_held(), segment, stored)
		delete(audio)

		if m.ok || room_ms >= PROBE_ROOM_MAX_MS {
			return m, room_ms
		}
		room_ms *= 2
	}
}

Envprobe_Options :: struct {
	values:  string,
	hold_ms: int,
	tail_ms: int,
	note:    u8,
	csv:     string,
	dump:    bool,
}

parse_env_values :: proc(spec: string) -> []int {
	out: [dynamic]int
	if spec == "all" {
		for v in 0 ..< 128 {
			append(&out, v)
		}
		return out[:]
	}
	if spec == "" {
		// A spread dense at the bottom, where an exponential curve moves fastest.
		spread := []int{0, 1, 2, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 127}
		for v in spread {
			append(&out, v)
		}
		return out[:]
	}
	parts := strings.split(spec, ",")
	defer delete(parts)
	for part in parts {
		if v, ok := strconv.parse_int(strings.trim_space(part)); ok {
			append(&out, clamp(v, 0, 127))
		}
	}
	return out[:]
}

cmd_envprobe :: proc(dll: string, segment: Env_Segment, opt: Envprobe_Options) {
	values := parse_env_values(opt.values)
	defer delete(values)
	if len(values) == 0 {
		fmt.eprintln("envprobe: no values to sweep")
		os.exit(1)
	}

	// One load per render, for the reasons in compare.odin.
	pristine: []byte
	{
		p, plugin_ok := load(dll)
		if !plugin_ok {
			os.exit(1)
		}
		pristine = get_chunk_copy(&p, 0)
		unload(&p)
	}
	if len(pristine) == 0 {
		fmt.eprintln("envprobe: the plugin returned an empty state chunk")
		os.exit(1)
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	note := opt.note != 0 ? opt.note : PROBE_NOTE
	set_probe_frame(note)

	fmt.printfln("envprobe %v: %v values, note %v, render grows to fit each setting",
		segment, len(values), note)
	fmt.println()

	g_quiet_load = true

	measurements: [dynamic]Env_Measurement
	defer delete(measurements)

	dumped := !opt.dump
	// Each setting starts from the room the previous one needed. The curve is
	// monotonic, so this is almost always right first time and the doubling
	// above is only a safety net.
	room_ms := opt.hold_ms > 0 ? opt.hold_ms : PROBE_ROOM_START_MS
	for stored in values {
		m, used := probe_one(dll, pristine, work, segment, stored, note, room_ms, &dumped)
		room_ms = used
		append(&measurements, m)

		if m.ok {
			fmt.printfln("  %3v  %v ms   (early %v, mid %v)  peak %v",
				stored, dec1(m.time_ms, 9), dec1(m.t_early, 8), dec1(m.t_mid, 9), dec4(m.peak))
		} else {
			fmt.printfln("  %3v  %v        (does not fit in %v s, or output is silent; peak %v)",
				stored, pad_left("-", 9), dec0(f64(used) / 1000.0), dec4(m.peak))
		}
		free_all(context.temp_allocator)
	}

	fmt.println()
	report_env_shape(measurements[:], segment)

	if opt.csv != "" {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "stored,ok,time_ms,t_early_ms,t_mid_ms,peak\n")
		for m in measurements {
			fmt.sbprintf(&b, "%v,%v,%.3f,%.3f,%.3f,%.6f\n",
				m.stored, m.ok, m.time_ms, m.t_early, m.t_mid, m.peak)
		}
		if os.write_entire_file(opt.csv, transmute([]u8)strings.to_string(b)) == nil {
			fmt.printfln("wrote %v", opt.csv)
		} else {
			fmt.eprintfln("envprobe: could not write %v", opt.csv)
		}
	}
}

// ------------------------------------------------------- generated table

// Sweep all three segments and write the measured curve out as Odin source.
//
// A table rather than a fitted formula, for the same reason src/patch/params.odin
// is a table: the measured curve is very nearly a clean exponential above stored
// 24 and demonstrably is not below it, and a formula that is right over four
// fifths of the range and quietly wrong over the rest is how the current
// hand-picked curve got there in the first place.
cmd_envtable :: proc(dll: string, out_path: string) {
	opt: Envprobe_Options
	opt.values = "all"

	fmt.println("measuring the reference envelope, three segments of 128 settings")
	fmt.println()

	attack := sweep_segment(dll, .Attack, opt)
	defer delete(attack)
	decay := sweep_segment(dll, .Decay, opt)
	defer delete(decay)
	release := sweep_segment(dll, .Release, opt)
	defer delete(release)

	if len(attack) != 128 || len(decay) != 128 || len(release) != 128 {
		fmt.eprintln("envtable: a sweep did not return 128 settings")
		os.exit(1)
	}
	for set in ([][]Env_Measurement{attack, decay, release}) {
		for m in set {
			if !m.ok {
				fmt.eprintfln("envtable: setting %v did not resolve; refusing to emit a partial table", m.stored)
				os.exit(1)
			}
		}
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, `// Code generated by "s1probe envtable"; do not edit.
//
// Measured envelope segment times for the reference Synth1 binary, in seconds,
// indexed by the parameter's resolved state (its stored 0..127 value).
//
// Method, in full, is in docs/null-test.md. In short: a patch that isolates the
// amplitude envelope -- sine oscillator, filter open and its envelope pinned
// flat, no effects, no LFOs, velocity sensitivity zeroed -- is rendered through
// the reference once per setting, and the segment's duration is read back out of
// the audio. The render grows until the segment fits inside it.
//
// The two shapes were measured rather than assumed, and both match what
// src/dsp/envelope.odin already does:
//
//   - The attack is a straight line. Across every setting slow enough to
//     resolve, the time to reach half level is 0.556 of the time to reach 90%,
//     which is the linear ratio exactly; an exponential approach would give
//     0.30. ATTACK_SECONDS below is therefore the measured 90% time divided by
//     0.9, i.e. the time the same straight line takes to reach full level, which
//     is what envelope_set expects.
//   - Decay and release are exponential. DECAY_SECONDS and RELEASE_SECONDS are
//     the measured times to fall 60 dB, which is exactly what dsp.segment_coef
//     is defined to cover.
//
// Decay and release come out within about 5% of each other across the range and
// are still kept apart, because 5% is larger than anything else left in this
// table and there is no reason to average away a difference that was measured.
package engine

ENVELOPE_TABLE_SIZE :: 128

`)

	emit_table :: proc(b: ^strings.Builder, name: string, values: []f64, scale: f64) {
		// A variable, not a constant: Odin will not index a compile-time constant
		// array with a runtime index, and every read of these is by a parameter's
		// resolved state.
		fmt.sbprintf(b, "%v := [ENVELOPE_TABLE_SIZE]f32{{\n", name)
		for i in 0 ..< len(values) {
			if i % 4 == 0 {
				strings.write_string(b, "\t")
			}
			fmt.sbprintf(b, "%.6f,", values[i] * scale)
			if i % 4 == 3 {
				strings.write_string(b, "\n")
			} else {
				strings.write_string(b, " ")
			}
		}
		strings.write_string(b, "}\n\n")
	}

	times := make([]f64, 128)
	defer delete(times)

	// Seconds, and for the attack the full-level time rather than the 90% time.
	for m, i in attack {
		times[i] = m.time_ms / 0.9
	}
	emit_table(&b, "ENVELOPE_ATTACK_SECONDS", times, 0.001)
	for m, i in decay {
		times[i] = m.time_ms
	}
	emit_table(&b, "ENVELOPE_DECAY_SECONDS", times, 0.001)
	for m, i in release {
		times[i] = m.time_ms
	}
	emit_table(&b, "ENVELOPE_RELEASE_SECONDS", times, 0.001)

	if os.write_entire_file(out_path, transmute([]u8)strings.to_string(b)) != nil {
		fmt.eprintfln("envtable: could not write %v", out_path)
		os.exit(1)
	}
	fmt.printfln("wrote %v", out_path)
	fmt.printfln("attack  %v ms .. %v ms", dec2(attack[0].time_ms / 0.9), dec0(attack[127].time_ms / 0.9))
	fmt.printfln("decay   %v ms .. %v ms", dec2(decay[0].time_ms), dec0(decay[127].time_ms))
	fmt.printfln("release %v ms .. %v ms", dec2(release[0].time_ms), dec0(release[127].time_ms))
}

sweep_segment :: proc(dll: string, segment: Env_Segment, opt: Envprobe_Options) -> []Env_Measurement {
	values := parse_env_values(opt.values)
	defer delete(values)

	pristine: []byte
	{
		p, plugin_ok := load(dll)
		if !plugin_ok {
			os.exit(1)
		}
		pristine = get_chunk_copy(&p, 0)
		unload(&p)
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	g_quiet_load = true
	note := opt.note != 0 ? opt.note : PROBE_NOTE
	set_probe_frame(note)

	out := make([]Env_Measurement, len(values))
	room_ms := PROBE_ROOM_START_MS
	dumped := true
	for stored, i in values {
		m, used := probe_one(dll, pristine, work, segment, stored, note, room_ms, &dumped)
		room_ms = used
		out[i] = m
		free_all(context.temp_allocator)
	}
	fmt.printfln("  %-8v %v of %v settings resolved", segment, count_ok(out), len(out))
	return out
}

count_ok :: proc(ms: []Env_Measurement) -> int {
	n := 0
	for m in ms {
		if m.ok {
			n += 1
		}
	}
	return n
}

// Say what shape the measured segment has, rather than leaving it to be eyeballed.
report_env_shape :: proc(measurements: []Env_Measurement, segment: Env_Segment) {
	// The ratio is taken over the settings slow enough to resolve. At the fast
	// end of every sweep the early crossing lands within a frame or two of note
	// on, so its ratio is reporting the analysis resolution rather than the
	// envelope, and averaging those in moves the answer a long way. Ten frames
	// is the cutoff.
	usable := 0
	ratio_sum := 0.0
	for m in measurements {
		if !m.ok || m.t_early <= 0 || m.t_mid < 10.0 * g_probe_frame_ms {
			continue
		}
		usable += 1
		// Attack: t50/t90, which separates a straight ramp from a curve without
		// depending on the noisy 10% crossing. Decay and release: t(-60)/t(-6).
		ratio_sum += segment == .Attack ? m.t_mid / m.time_ms : m.time_ms / m.t_early
	}
	if usable == 0 {
		fmt.println("no usable measurements: widen the render, or check --dump")
		return
	}

	mean := ratio_sum / f64(usable)
	if segment == .Attack {
		fmt.printfln("mean t50/t90 ratio over %v resolvable settings: %v", usable, dec3(mean))
		fmt.println("(a linear ramp gives 0.556; an exponential approach gives about 0.301)")
		return
	}
	fmt.printfln("mean t(-60 dB)/t(-6 dB) ratio over %v resolvable settings: %v", usable, dec2(mean))
	fmt.println("(an exponential decay gives exactly 10.0; a linear fade gives about 2.0)")
}
