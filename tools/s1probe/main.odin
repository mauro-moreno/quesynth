// s1probe - offline interrogation of the reference Synth1 VST2 binary.
//
// Purpose: extract ground truth (parameter table, program names, rendered
// audio) so the Odin clone can be validated against measurement instead of
// guesswork. This tool is a development aid only and is not part of the
// shipped synth.
//
//   s1probe dump   [dll]                 -> docs/synth1-params.{json,md}
//   s1probe render [dll] <prog> <out.wav>
//   s1probe patch  [dll] <file.sy1> <out.wav>
package s1probe

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import win "core:sys/windows"
import spatch "../../src/patch"

DEFAULT_DLL :: "ext/synth1/Synth1/Synth1 VST64.dll"
SAMPLE_RATE :: 48000
BLOCK :: 512

g_time: VstTimeInfo

// Where the transport is, in samples. Advanced by whatever is rendering and
// reset to zero at the start of each render.
//
// The original version of this host answered audioMasterGetTime with a struct
// whose sample position never moved and whose only valid flag was the tempo.
// Anything in the plugin that is driven by musical time -- the arpeggiator, the
// tempo-synced delay, a tempo-synced LFO -- was therefore reading a transport
// frozen at bar one, beat one, forever. That is not a small inaccuracy: a
// render made under it is not the render the plugin would produce in a real
// host, so it is not a legitimate thing to compare against.
g_sample_pos: f64

// VstTimeInfo flags. Only the ones this host can honestly claim are set.
VST_TRANSPORT_PLAYING :: i32(1 << 1)
VST_NANOS_VALID :: i32(1 << 8)
VST_PPQ_VALID :: i32(1 << 9)
VST_TEMPO_VALID :: i32(1 << 10)
VST_BARS_VALID :: i32(1 << 11)
VST_TIMESIG_VALID :: i32(1 << 13)

HOST_TEMPO :: 120.0

host_transport_reset :: proc "contextless" () {
	g_sample_pos = 0
}

host_transport_advance :: proc "contextless" (frames: int) {
	g_sample_pos += f64(frames)
}

host_cb :: proc "c" (e: ^AEffect, opcode: i32, index: i32, value: int, ptr: rawptr, opt: f32) -> int {
	switch HostOp(opcode) {
	case .Version:
		return 2400
	case .CurrentId:
		return 0
	case .GetSampleRate:
		return SAMPLE_RATE
	case .GetBlockSize:
		return BLOCK
	case .GetCurrentProcessLevel:
		return 2 // realtime
	case .GetAutomationState:
		return 0
	case .GetLanguage:
		return 1 // english
	case .GetTime:
		seconds := g_sample_pos / f64(SAMPLE_RATE)
		beats := seconds * (HOST_TEMPO / 60.0)
		// Four beats to the bar, per the time signature reported below.
		bar := f64(int(beats / 4.0)) * 4.0

		g_time.sample_pos = g_sample_pos
		g_time.sample_rate = f64(SAMPLE_RATE)
		g_time.nano_seconds = seconds * 1.0e9
		g_time.ppq_pos = beats
		g_time.tempo = HOST_TEMPO
		g_time.bar_start_pos = bar
		g_time.time_sig_numerator = 4
		g_time.time_sig_denominator = 4
		g_time.flags =
			VST_NANOS_VALID |
			VST_PPQ_VALID |
			VST_TEMPO_VALID |
			VST_BARS_VALID |
			VST_TIMESIG_VALID
		if g_host_answers.transport_playing {
			g_time.flags |= VST_TRANSPORT_PLAYING
		}
		return int(uintptr(rawptr(&g_time)))
	case .CanDo:
		return 1
	// The VST 2.0 way of asking the tempo, and the one the reference's
	// arpeggiator uses. It is answered in BPM x 10000, which is the convention;
	// answering zero -- as this host did -- hands the plugin a tempo of nothing
	// and it dies on its first step. See tools/s1probe/hostprobe.odin.
	case .TempoAt:
		return g_host_answers.tempo_at
	case .WantMidi:
		return g_host_answers.want_midi
	case .ProcessEvents:
		return g_host_answers.process_events
	case .Automate, .Idle, .PinConnected,
	     .SizeWindow, .GetInputLatency, .GetOutputLatency, .GetVendorString,
	     .GetProductString, .GetVendorVersion, .UpdateDisplay, .BeginEdit, .EndEdit:
		return 0
	}
	return 0
}

Plugin :: struct {
	eff: ^AEffect,
	mod: win.HMODULE,
}

buf_str :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {n += 1}
	return strings.clone(string(b[:n]))
}

dispatch_str :: proc(p: ^Plugin, op: Op, index: i32) -> string {
	b: [512]u8
	p.eff.dispatcher(p.eff, i32(op), index, 0, &b[0], 0)
	return buf_str(b[:])
}

// Set by callers that load the library many times over, so the entry-point
// announcement below stays a one-off diagnostic rather than pages of noise.
g_quiet_load: bool

// Open the library and tell it about the world, stopping short of resuming it.
//
// Split out of `load` because *when* the state chunk is pushed, relative to
// `effMainsChanged`, is itself a thing worth probing: a plugin is entitled to
// size its internal buffers when it is resumed, and a section switched on by a
// chunk that arrives afterwards has never been prepared. See hostprobe.odin.
load_suspended :: proc(path: string) -> (p: Plugin, ok: bool) {
	wpath := win.utf8_to_wstring(path)
	mod := win.LoadLibraryW(wpath)
	if mod == nil {
		fmt.eprintfln("LoadLibraryW failed for %q (err %v)", path, win.GetLastError())
		return {}, false
	}
	entry_names := []cstring{"VSTPluginMain", "main", "MAIN"}
	entry: VstEntry
	for name in entry_names {
		if addr := win.GetProcAddress(mod, name); addr != nil {
			entry = cast(VstEntry)addr
			if !g_quiet_load {
				fmt.eprintfln("[s1probe] entry point: %v", name)
			}
			break
		}
	}
	if entry == nil {
		fmt.eprintln("no VST2 entry point exported")
		return {}, false
	}
	eff := entry(host_cb)
	if eff == nil || eff.magic != MAGIC {
		fmt.eprintfln("bad AEffect (magic %x)", eff == nil ? 0 : eff.magic)
		return {}, false
	}
	p = Plugin{eff = eff, mod = mod}
	eff.dispatcher(eff, i32(Op.Open), 0, 0, nil, 0)
	eff.dispatcher(eff, i32(Op.SetSampleRate), 0, 0, nil, f32(SAMPLE_RATE))
	eff.dispatcher(eff, i32(Op.SetBlockSize), 0, BLOCK, nil, 0)
	return p, true
}

// Ready to render: the plugin may allocate here, and everything it allocates is
// sized from what it has been told and from the state it currently holds.
plugin_resume :: proc(p: ^Plugin) {
	p.eff.dispatcher(p.eff, i32(Op.MainsChanged), 0, 1, nil, 0)
	p.eff.dispatcher(p.eff, i32(Op.StartProcess), 0, 0, nil, 0)
}

plugin_suspend :: proc(p: ^Plugin) {
	p.eff.dispatcher(p.eff, i32(Op.StopProcess), 0, 0, nil, 0)
	p.eff.dispatcher(p.eff, i32(Op.MainsChanged), 0, 0, nil, 0)
}

load :: proc(path: string) -> (p: Plugin, ok: bool) {
	p, ok = load_suspended(path)
	if !ok {
		return {}, false
	}
	plugin_resume(&p)
	return p, true
}

unload :: proc(p: ^Plugin) {
	plugin_suspend(p)
	p.eff.dispatcher(p.eff, i32(Op.Close), 0, 0, nil, 0)
	win.FreeLibrary(p.mod)
}

// ------------------------------------------------------------------ dump

json_escape :: proc(s: string, b: ^strings.Builder) {
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 || c > 0x7e {
				strings.write_string(b, fmt.tprintf("\\u%04x", u32(c)))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
}

cmd_dump :: proc(dll: string) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)

	e := p.eff
	name := dispatch_str(&p, .GetEffectName, 0)
	vendor := dispatch_str(&p, .GetVendorString, 0)
	product := dispatch_str(&p, .GetProductString, 0)
	ver := e.dispatcher(e, i32(Op.GetVendorVersion), 0, 0, nil, 0)

	fmt.printfln("effect      : %v", name)
	fmt.printfln("vendor      : %v", vendor)
	fmt.printfln("product     : %v", product)
	fmt.printfln("version     : %v", ver)
	fmt.printfln("unique_id   : %08x", e.unique_id)
	fmt.printfln("num_params  : %v", e.num_params)
	fmt.printfln("num_programs: %v", e.num_programs)
	fmt.printfln("in/out      : %v / %v", e.num_inputs, e.num_outputs)
	fmt.printfln("flags       : %032b (synth=%v chunks=%v replacing=%v)",
		e.flags,
		e.flags & FLAG_IS_SYNTH != 0,
		e.flags & FLAG_PROGRAM_CHUNKS != 0,
		e.flags & FLAG_CAN_REPLACING != 0)

	jb := strings.builder_make()
	defer strings.builder_destroy(&jb)
	mb := strings.builder_make()
	defer strings.builder_destroy(&mb)

	strings.write_string(&jb, "{\n")
	fmt.sbprintf(&jb, "  \"effect\": \"")
	json_escape(name, &jb)
	fmt.sbprintf(&jb, "\",\n  \"version\": %v,\n", ver)
	fmt.sbprintf(&jb, "  \"unique_id\": \"%08x\",\n", e.unique_id)
	fmt.sbprintf(&jb, "  \"num_params\": %v,\n", e.num_params)
	fmt.sbprintf(&jb, "  \"num_programs\": %v,\n", e.num_programs)
	strings.write_string(&jb, "  \"params\": [\n")

	strings.write_string(&mb, "# Synth1 reference parameter table\n\n")
	fmt.sbprintf(&mb, "Extracted from `%v` (version %v, %v parameters).\n\n", dll, ver, e.num_params)
	strings.write_string(&mb, "| idx | name | default | display | label |\n")
	strings.write_string(&mb, "|----:|------|--------:|---------|-------|\n")

	for i in 0 ..< e.num_params {
		pname := dispatch_str(&p, .GetParamName, i)
		disp := dispatch_str(&p, .GetParamDisplay, i)
		label := dispatch_str(&p, .GetParamLabel, i)
		val := e.get_parameter(e, i)

		if i > 0 {strings.write_string(&jb, ",\n")}
		fmt.sbprintf(&jb, "    {{\"index\": %v, \"name\": \"", i)
		json_escape(pname, &jb)
		strings.write_string(&jb, "\", \"default\": ")
		fmt.sbprintf(&jb, "%.6f, \"display\": \"", val)
		json_escape(disp, &jb)
		strings.write_string(&jb, "\", \"label\": \"")
		json_escape(label, &jb)
		strings.write_string(&jb, "\"}")

		fmt.sbprintf(&mb, "| %v | %v | %.4f | %v | %v |\n", i, pname, val, disp, label)
		fmt.printfln("param %3v  %-24v = %.4f  %-12v %v", i, pname, val, disp, label)
	}
	strings.write_string(&jb, "\n  ],\n  \"programs\": [\n")

	strings.write_string(&mb, "\n## Programs\n\n| idx | name |\n|----:|------|\n")
	for i in 0 ..< e.num_programs {
		b: [512]u8
		e.dispatcher(e, i32(Op.GetProgramNameIdx), i, 0, &b[0], 0)
		pn := buf_str(b[:])
		if i > 0 {strings.write_string(&jb, ",\n")}
		fmt.sbprintf(&jb, "    {{\"index\": %v, \"name\": \"", i)
		json_escape(pn, &jb)
		strings.write_string(&jb, "\"}")
		fmt.sbprintf(&mb, "| %v | %v |\n", i, pn)
	}
	strings.write_string(&jb, "\n  ]\n}\n")

	_ = os.make_directory("docs")
	_ = os.write_entire_file("docs/synth1-params.json", transmute([]u8)strings.to_string(jb))
	_ = os.write_entire_file("docs/synth1-params.md", transmute([]u8)strings.to_string(mb))
	fmt.eprintfln("[s1probe] wrote docs/synth1-params.json and docs/synth1-params.md")
}

// The `ranges` subcommand used to live here. It counted distinct display runs
// while sweeping and called the result a step count, which undercounts states
// whenever two adjacent states render the same text, and it assumed the value
// mapping was uniform quantisation. Both were wrong. `s1states` measures the
// real state tables and `s1probe mapping` measures how a stored integer selects
// one; see docs/synth1-param-encoding.md.

// --------------------------------------------------------------- verify

Verify_Stats :: struct {
	compared:          int,
	on_state:          int,
	out_of_range:      int,
	mismatches:        int,
	samples:           int,
	mismatch_by_index: [spatch.PARAMETER_COUNT]int,
}

// Does this stored integer land on a state, or does it need the out-of-range
// rule? Reporting only; it changes no comparison.
verify_lands_on_state :: proc(index, stored: int) -> bool {
	states := spatch.parameter_states(index)
	if len(states) == 0 {return false}
	if spatch.PARAMETERS[index].display_keyed {
		for s in states {
			if d, ok := spatch.display_integer(s.display); ok && d == stored {
				return true
			}
		}
		return false
	}
	return stored >= 0 && stored < len(states)
}

// Compare every parameter the file specifies against the reference.
//
// The oracle is Synth1's own loader. The patch's raw stored integers are
// written into the plugin's state chunk and handed back with effSetChunk, so
// the read-back is what Synth1 itself would produce for this file. Driving the
// plugin with setParameter cannot do this job: it saturates at 1.0, while the
// loader genuinely reports values above 1.0 for the out-of-range integers ten
// factory patches store in index 33 and five store in index 35.
//
// The comparison is on the normalised value, not the display text. After a
// chunk load the display echoes the raw stored integer, so display equality can
// hold while the selected state is wrong -- index 1 storing 0 reads display "0"
// yet sits on the top state.
verify_patch :: proc(p: ^Plugin, name: string, parsed: ^spatch.Patch, pristine, work: []byte, stats: ^Verify_Stats) -> int {
	e := p.eff

	// Establish the whole plugin state from the patch before reading anything.
	// Parameters the file omits still get their reference default, so a stale
	// value from the previous file can never be mistaken for a match.
	copy(work, pristine)
	for i in 0 ..< spatch.PARAMETER_COUNT {
		write_le_u32(work, CHUNK_VALUE_BASE + i * CHUNK_VALUE_STRIDE, u32(i32(parsed.values[i])))
	}
	e.dispatcher(e, i32(Op.SetChunk), 0, len(work), raw_data(work), 0)

	patch_mismatches := 0
	for i in 0 ..< spatch.PARAMETER_COUNT {
		// Only what the file actually specifies is compared, but everything it
		// specifies is compared.
		if !parsed.present[i] {continue}

		value := parsed.values[i]
		expected, resolved := spatch.parameter_norm(i, value)
		actual := e.get_parameter(e, i32(i))

		stats.compared += 1
		if verify_lands_on_state(i, value) {
			stats.on_state += 1
		} else {
			stats.out_of_range += 1
		}
		if resolved && expected == actual {continue}

		patch_mismatches += 1
		stats.mismatches += 1
		stats.mismatch_by_index[i] += 1
		if stats.samples < 20 {
			fmt.printfln(
				"mismatch sample: %s index %v (%s), file value %v, expected %.9f, reference %.9f, display %q",
				name, i, spatch.PARAMETERS[i].name, value, expected, actual,
				dispatch_str(p, .GetParamDisplay, i32(i)))
			stats.samples += 1
		}
	}
	return patch_mismatches
}

cmd_verify :: proc(dll, dir: string) {
	p, plugin_ok := load(dll)
	if !plugin_ok {os.exit(1)}
	defer unload(&p)

	pristine := get_chunk_copy(&p, 0)
	if len(pristine) == 0 {
		fmt.eprintln("verify: the plugin returned an empty state chunk")
		os.exit(1)
	}
	defer delete(pristine)
	if CHUNK_VALUE_BASE + (spatch.PARAMETER_COUNT - 1) * CHUNK_VALUE_STRIDE + 4 > len(pristine) {
		fmt.eprintfln("verify: state chunk is %v bytes, too small for %v parameters",
			len(pristine), spatch.PARAMETER_COUNT)
		os.exit(1)
	}
	work := make([]byte, len(pristine))
	defer delete(work)

	entries, dir_err := os.read_directory_by_path(dir, -1, context.allocator)
	if dir_err != nil {
		fmt.eprintfln("verify: cannot read %q: %v", dir, dir_err)
		os.exit(1)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	total := 0
	parsed_count := 0
	errors := 0
	stats: Verify_Stats
	for info in entries {
		if !strings.has_suffix(info.name, ".sy1") {continue}
		total += 1
		data, read_err := os.read_entire_file(info.fullpath, context.allocator)
		if read_err != nil {
			errors += 1
			fmt.printfln("%s: error reading: %v", info.name, read_err)
			continue
		}
		// parse_sy1 does not copy: the returned Patch borrows `name` and `color`
		// straight out of `data`, so the buffer has to outlive every use of the
		// parsed patch rather than being released right after parsing.
		parsed, parse_err := spatch.parse_sy1(data)
		if parse_err != .None {
			delete(data, context.allocator)
			errors += 1
			fmt.printfln("%s: error: %v", info.name, parse_err)
			continue
		}
		parsed_count += 1
		compared_before := stats.compared
		mismatch_before := stats.mismatches
		verify_patch(&p, info.name, &parsed, pristine, work, &stats)
		fmt.printfln("%s: compared %v parameters, mismatches: %v",
			info.name, stats.compared - compared_before, stats.mismatches - mismatch_before)
		delete(data, context.allocator)
	}

	fmt.printfln("parsed: %v/%v", parsed_count, total)
	fmt.printfln("errors: %v", errors)
	fmt.printfln("compared: %v (on a state: %v, out of range: %v)",
		stats.compared, stats.on_state, stats.out_of_range)
	fmt.println("mismatch breakdown:")
	for i in 0 ..< spatch.PARAMETER_COUNT {
		fmt.printfln("index %v (%s): %v", i, spatch.PARAMETERS[i].name, stats.mismatch_by_index[i])
	}
	fmt.printfln("mismatches: %v", stats.mismatches)
	if errors != 0 || stats.mismatches != 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------- render


// The event a `send_midi` call describes, and the list that points at it.
//
// Deliberately not locals. `effProcessEvents` hands the plugin a pointer into
// this memory and the plugin is entitled to read it until the matching
// `processReplacing` returns -- which is *after* the call that delivered it.
// Built on the stack, as this was, the frame is gone before the plugin ever
// renders a sample, and what happens next depends entirely on whether the
// plugin copied the event out during the dispatch.
//
// Synth1 copies a plain note out during the dispatch, so nothing here has ever
// depended on the lifetime and no measurement changes because of this. It is
// fixed because the contract says so, not because a bug was traced to it: the
// arpeggiator crash that prompted the search survives this fix, and lives
// inside the reference binary rather than here. See compare.odin.
//
// One event at a time is enough: nothing here sends a chord.
g_midi_event: VstMidiEvent
g_midi_events: VstEvents

send_midi :: proc(p: ^Plugin, status, d1, d2: u8, delta: i32) {
	one := [1]u8{d1}
	send_midi_notes(p, status, one[:], d2, delta)
}

// Several notes in one event list, which is the only way to hold a chord.
//
// Dispatching `effProcessEvents` once per note looked equivalent and is not:
// Synth1 keeps the most recent list rather than accumulating them, so three
// separate note-ons before a single `processReplacing` leave one note held and
// the other two silently dropped. The arpeggiator probe found this by
// arpeggiating a three-note chord and getting the same pitch on every step --
// the last note sent.
//
// The event array is sized by VstEvents, which this host declares with room for
// sixteen; anything beyond that is dropped here rather than overrunning it.
g_midi_chord: [16]VstMidiEvent

send_midi_notes :: proc(p: ^Plugin, status: u8, notes: []u8, velocity: u8, delta: i32) {
	count := min(len(notes), len(g_midi_chord))
	for i in 0 ..< count {
		g_midi_chord[i] = VstMidiEvent {
			type         = 1,
			byte_size    = size_of(VstMidiEvent),
			delta_frames = delta,
			midi_data    = {status, notes[i], velocity, 0},
		}
		g_midi_events.events[i] = &g_midi_chord[i]
	}
	g_midi_events.num_events = i32(count)
	p.eff.dispatcher(p.eff, i32(Op.ProcessEvents), 0, 0, &g_midi_events, 0)
}

render :: proc(p: ^Plugin, note: u8, hold_sec, tail_sec: f32) -> []f32 {
	e := p.eff
	nch := int(e.num_outputs)
	if nch < 1 {nch = 2}

	chans := make([][]f32, nch)
	ptrs := make([][^]f32, nch)
	for i in 0 ..< nch {
		chans[i] = make([]f32, BLOCK)
		ptrs[i] = raw_data(chans[i])
	}
	// silent input scratch (Synth1 has no audio inputs, but be safe)
	nin := int(e.num_inputs)
	in_chans := make([][]f32, max(nin, 1))
	in_ptrs := make([][^]f32, max(nin, 1))
	for i in 0 ..< len(in_chans) {
		in_chans[i] = make([]f32, BLOCK)
		in_ptrs[i] = raw_data(in_chans[i])
	}

	total := int((hold_sec + tail_sec) * SAMPLE_RATE)
	hold := int(hold_sec * SAMPLE_RATE)
	out := make([dynamic]f32, 0, total * nch)

	host_transport_reset()
	send_midi(p, 0x90, note, 100, 0)
	sent_off := false

	pos := 0
	for pos < total {
		if !sent_off && pos >= hold {
			send_midi(p, 0x80, note, 0, 0)
			sent_off = true
		}
		for i in 0 ..< nch {
			for j in 0 ..< BLOCK {chans[i][j] = 0}
		}
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), BLOCK)
		host_transport_advance(BLOCK)
		for j in 0 ..< BLOCK {
			for i in 0 ..< nch {
				append(&out, chans[i][j])
			}
		}
		pos += BLOCK
	}
	return out[:]
}

peak_rms :: proc(s: []f32) -> (peak, rms: f32) {
	sum: f64
	for v in s {
		a := abs(v)
		if a > peak {peak = a}
		sum += f64(v) * f64(v)
	}
	if len(s) > 0 {
		rms = f32((sum / f64(len(s))) * 0.5)
	}
	return
}

cmd_render :: proc(dll: string, prog: int, out_path: string) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)

	if prog >= 0 {
		p.eff.dispatcher(p.eff, i32(Op.SetProgram), 0, prog, nil, 0)
	}
	pname := dispatch_str(&p, .GetProgramName, 0)
	fmt.printfln("program %v: %v", prog, pname)

	buf := render(&p, 60, 1.5, 1.0)
	peak, rms := peak_rms(buf)
	fmt.printfln("rendered %v frames, peak %.5f, mean-sq %.8f", len(buf) / int(p.eff.num_outputs), peak, rms)
	if peak < 1e-6 {
		fmt.eprintln("WARNING: output is silent")
	}
	wav_write_f32(out_path, buf, int(p.eff.num_outputs), SAMPLE_RATE)
	fmt.printfln("wrote %v", out_path)
}

// ------------------------------------------------------------------ main

usage :: proc() {
	fmt.eprintln("usage:")
	fmt.eprintln("  s1probe dump   [dll]")

	fmt.eprintln("  s1probe render [dll] <program-index> <out.wav>")
	fmt.eprintln("  s1probe verify [dll] <directory>")
	fmt.eprintln("  s1probe compare [dll] <patch.sy1 | directory> [--wav <dir>] [--csv <path>]")
	fmt.eprintln("                        [--note <n>] [--limit <n>] [--offset <n>] [--block <n>]")
	fmt.eprintln("                        [--verbose] [--self] [--no-floor]")
	fmt.eprintln("                        [--fmsub-gate <original|fm-off|fm-sub-off>]")
	fmt.eprintln("  s1probe summarise <compare.csv>")
	fmt.eprintln("  s1probe envprobe [dll] <attack|decay|release> [--values <list|all>]")
	fmt.eprintln("                        [--hold <ms>] [--tail <ms>] [--note <n>]")
	fmt.eprintln("                        [--csv <path>] [--dump]")
	fmt.eprintln("  s1probe filterprobe [dll] [--cutoff <n>] [--res <n>] [--note <n>] [--dump]")
	fmt.eprintln("  s1probe qprobe  [dll] [--type <0..4>] [--cutoff <n>] [--values <list|all>]")
	fmt.eprintln("                        [--note <n>] [--calibrate]")
	fmt.eprintln("  s1probe qtable  [dll] [out.odin]")
	fmt.eprintln("  s1probe qlevel  [dll] [--type <0..4>] [--cutoff <n>] [--values <list>]")
	fmt.eprintln("  s1probe lfoprobe [dll] [--param <41|46>] [--rate <n>] [--note <n>] [--dump]")
	fmt.eprintln("  s1probe lfoshape [dll] [--param <42|47>] [--values <list|all>]")
	fmt.eprintln("                        [--speed <n>] [--note <n>] [--dump]")
	fmt.eprintln("  s1probe lfopitch [dll] [--param <41|46>] [--values <list|all>]")
	fmt.eprintln("                        [--notes <list>] [--rate <n>] [--dest <1|2>] [--dump]")
	fmt.eprintln("  s1probe mapping [dll]")
	fmt.eprintln("  s1probe mixprobe [dll] [--values <list>]")
	fmt.eprintln("  s1probe fmsubprobe [dll] [--values <list>] [--note <n>]")
	fmt.eprintln("  s1probe phaseprobe [dll] [--values <list>]")
	fmt.eprintln("  s1probe phaseabsolute [dll] [--values <list>]")
	fmt.eprintln("  s1probe unisonprobe [dll] [--fixture <patch.sy1>] [--values <list>] [--note <n>]")
	fmt.eprintln("  s1probe choruspatch [dll] [--dir <bank>] [--note <n>] [--bands] <patch.sy1>...")
	fmt.eprintln("  s1probe patchdiag   [dll] <patch.sy1> [--note <n>]")
	fmt.eprintln("                          -- peak/RMS of one patch, ref vs. ours, with a fixed")
	fmt.eprintln("                             set of one-parameter-at-a-time variants")
	fmt.eprintln("  s1probe fmfilter    [dll] [--note <n>] [patch.sy1 ...]")
	fmt.eprintln("                          -- FM spectrum before and through a moving filter")
	fmt.eprintln("  s1probe filtersaturation [dll] [--values <list>] [--gains <list>]")
	fmt.eprintln("                          [--type <n>] [--cutoff <n>] [--res <n>] [--note <n>]")
    fmt.eprintln("  s1probe substageprobe [dll] [--notes <list>] [--p95 <list>] [--mix <list>]")
    fmt.eprintln("                          [--saturation <list>] [--gain <n>] [--csv <path>]")
	fmt.eprintln("                          [--shape <0..3>] [--width <0..127>]")
	fmt.eprintln("  -- the extra effect unit, parameters 77..81 --")
	fmt.eprintln("  s1probe fxprobe   [dll] [--config <name>] [--note <n>] [--dump]")
	fmt.eprintln("  s1probe fxsweep   [dll] [--type <0..9>] [--ctl <1|2|3>] [--values <list>]")
	fmt.eprintln("                          [--other <n>] [--level <n>] [--note <n>]")
	fmt.eprintln("  s1probe fxcorner  [dll] [--type <0..2>] [--drive <n>] [--values <list>]")
	fmt.eprintln("  s1probe fxenv     [dll] [--type <0..9>] [--ctl1 <n>] [--ctl2 <n>]")
	fmt.eprintln("                          [--level <n>] [--step <ms>]")
	fmt.eprintln("  s1probe fxcompare [dll] [--ctl1 <n>] [--ctl2 <n>] [--level <n>] [--note <n>]")
	fmt.eprintln("  s1probe compcurve [dll] [--ctl1 <n>] [--ctl2 <n>] [--level <n>] [--note <n>]")
	fmt.eprintln("                    [--gains <list>] [--depths <list>] [--csv <path>]")
	fmt.eprintln("  s1probe fxcurve [dll] [--type <0..3>] [--ctl2 <n>] [--level <n>] [--note <n>]")
	fmt.eprintln("                  [--gain <n>] [--drives <list>] [--csv <path>]")
	fmt.eprintln("  s1probe phaserrate [dll] [--type <6..9>] [--ctl1 <n>] [--level <n>]")
	fmt.eprintln("                     [--note <n>] [--values <list>] [--seconds <s>] [--csv <path>]")
	fmt.eprintln("  s1probe phasercomb [dll] [--type <6..9>] [--ctl1 <n>] [--ctl2 <n>]")
	fmt.eprintln("                     [--level <n>] [--gain <n>] [--seconds <s>] [--fft <n>]")
	fmt.eprintln("                     [--show] [--csv <path>] [--curve <path>]")
	fmt.eprintln("  s1probe phaserband [dll] [--type <6..9>] [--ctl1 <n>] [--ctl2 <n>]")
	fmt.eprintln("                     [--notes <list>] [--csv <path>]")
	fmt.eprintln("  s1probe comptrace [dll] [--ctl1 <n>] [--ctl2 <n>] [--amp <n>] [--decay <n>]")
	fmt.eprintln("                    [--sustain <n>] [--step <ms>] [--csv <path>]")
	fmt.eprintln("  s1probe deciprobe [dll] [--ctl <1|2>] [--values <list>] [--other <n>]")
	fmt.eprintln("  s1probe runhist   [dll] [--type <n>] [--ctl1 <n>] [--ctl2 <n>] [--level <n>]")
	fmt.eprintln("  s1probe phaserprobe [dll] [--type <6..9>] [--ctl1 <n>] [--ctl2 <n>]")
	fmt.eprintln("                          [--level <n>] [--gain <n>] [--seconds <n>] [--rows <n>]")
	fmt.eprintln("  -- throwaway diagnostics --")
	fmt.eprintln("  s1probe chunkdump [dll]")
	fmt.eprintln("  s1probe chunkload [dll] <file.sy1> [index]")
	fmt.eprintln("  s1probe drivers   [dll] <target> <driver>")
	fmt.eprintln("  s1probe coerce    [dll] <target> <value>...")
	os.exit(2)
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {usage()}

	cmd := args[0]
	rest := args[1:]

	dll := DEFAULT_DLL
    if cmd == "verify" || cmd == "compare" || cmd == "envprobe" || cmd == "envtable" || cmd == "filterprobe" || cmd == "qprobe" || cmd == "qtable" || cmd == "qlevel" || cmd == "lfoprobe" || cmd == "lfoshape" || cmd == "lfopitch" || cmd == "lfosquare" || cmd == "lfofm" || cmd == "waveprobe" || cmd == "gainprobe" || cmd == "leveltable" || cmd == "cutoffprobe" || cmd == "filtertable" || cmd == "lfodepth" || cmd == "lforate" || cmd == "lforatetable" || cmd == "chorusprobe" || cmd == "chorusfb" || cmd == "chorustrack" || cmd == "choruswidth" || cmd == "choruspatch" || cmd == "envtrace" || cmd == "bandprofile" || cmd == "fxprobe" || cmd == "fxsweep" || cmd == "deciprobe" || cmd == "runhist" || cmd == "fxcorner" || cmd == "fxenv" || cmd == "fxcompare" || cmd == "phaserprobe" || cmd == "tuningcheck" || cmd == "mixprobe" || cmd == "phaseprobe" || cmd == "phaseabsolute" || cmd == "unisonprobe" || cmd == "patchdiag" || cmd == "fmfilter" || cmd == "peakprobe" || cmd == "chorusstability" || cmd == "oscspectrum" || cmd == "filterdistortion" || cmd == "filtersaturation" || cmd == "progparam" || cmd == "chorusphase" || cmd == "chorusdepth" || cmd == "velprobe" || cmd == "arpprobe" || cmd == "fmsubprobe" || cmd == "substageprobe" || cmd == "compcurve" || cmd == "comptrace" || cmd == "phaserband" || cmd == "phasercomb" || cmd == "phaserrate" || cmd == "fxcurve" || cmd == "fxharm" {
        if len(rest) >= 1 && (cmd == "fmfilter" || cmd == "unisonprobe" || cmd == "substageprobe" || len(rest) >= 2) && strings.has_suffix(strings.to_lower(rest[0]), ".dll") {
			dll = rest[0]
			rest = rest[1:]
		}
	} else if len(rest) > 0 && strings.has_suffix(strings.to_lower(rest[0]), ".dll") {
		dll = rest[0]
		rest = rest[1:]
	}

	switch cmd {
	case "dump":
		cmd_dump(dll)
	case "mapping":
		cmd_mapping(dll)
	case "render":
		if len(rest) < 2 {usage()}
		prog, _ := strconv.parse_int(rest[0])
		cmd_render(dll, prog, rest[1])
	case "verify":
		if len(rest) < 1 {usage()}
		cmd_verify(dll, rest[0])
	case "compare":
		target, opt, opt_ok := parse_compare_args(rest)
		if !opt_ok {usage()}
		cmd_compare(dll, target, opt)
	case "hostprobe":
		patch_path, single_case, args_ok := parse_host_case(rest)
		if !args_ok {usage()}
		cmd_hostprobe(dll, patch_path, single_case)
	case "paramcrash":
		patch_path, single, args_ok := parse_param_case(rest)
		if !args_ok {usage()}
		cmd_paramcrash(dll, patch_path, single)
	case "summarise", "summarize":
		if len(rest) < 1 {usage()}
		cmd_summarise(rest[0])
	case "envprobe":
		if len(rest) < 1 {usage()}
		segment: Env_Segment
		switch rest[0] {
		case "attack":
			segment = .Attack
		case "decay":
			segment = .Decay
		case "release":
			segment = .Release
		case:
			usage()
		}
		eopt: Envprobe_Options
		i := 1
		for i < len(rest) {
			switch rest[i] {
			case "--values":
				if i + 1 >= len(rest) {usage()}
				eopt.values = rest[i + 1]
				i += 2
			case "--hold":
				if i + 1 >= len(rest) {usage()}
				eopt.hold_ms, _ = strconv.parse_int(rest[i + 1])
				i += 2
			case "--tail":
				if i + 1 >= len(rest) {usage()}
				eopt.tail_ms, _ = strconv.parse_int(rest[i + 1])
				i += 2
			case "--note":
				if i + 1 >= len(rest) {usage()}
				n, _ := strconv.parse_int(rest[i + 1])
				eopt.note = u8(clamp(n, 0, 127))
				i += 2
			case "--csv":
				if i + 1 >= len(rest) {usage()}
				eopt.csv = rest[i + 1]
				i += 2
			case "--dump":
				eopt.dump = true
				i += 1
			case:
				usage()
			}
		}
		cmd_envprobe(dll, segment, eopt)
	case "filterprobe":
		cutoff := 64
		resonance := 0
		fnote := 60
		fdump := false
		i := 0
		for i < len(rest) {
			switch rest[i] {
			case "--cutoff":
				if !parse_probe_int(rest, i + 1, &cutoff) {usage()}
				i += 2
			case "--res":
				if !parse_probe_int(rest, i + 1, &resonance) {usage()}
				i += 2
			case "--note":
				if !parse_probe_int(rest, i + 1, &fnote) {usage()}
				i += 2
			case "--dump":
				fdump = true
				i += 1
			case:
				usage()
			}
		}
		cmd_filterprobe(dll, cutoff, resonance, u8(clamp(fnote, 0, 127)), fdump)
	case "phaseprobe":
		phvals := "0,8,16,32,48,64,80,96,112,127"
		phnote := int(MIX_PROBE_NOTE)
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					phvals = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &phnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_phaseprobe(dll, parse_env_values(phvals), phnote)
	case "phaseabsolute":
		pavals := "0,1,16,32,48,64,96,127"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					pavals = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_phaseabsolute(dll, parse_env_values(pavals))
	case "unisonprobe":
		upfixture := UNISON_FIXTURE_DEFAULT
		upvalues := "16,22,32,64,96,127"
		upnote := 84
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--fixture":
					if i + 1 >= len(rest) {usage()}
					upfixture = rest[i + 1]
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					upvalues = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &upnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_unisonprobe(dll, upfixture, parse_env_values(upvalues), u8(clamp(upnote, 0, 127)))
	case "mixprobe":
		mvals := "0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,127"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					mvals = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_mixprobe(dll, parse_env_values(mvals))
	case "fmsubprobe":
		fsv := "0,16,24,32,43"
		fsnote := int(FMSUB_NOTE)
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					fsv = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fsnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_fmsubprobe(dll, parse_env_values(fsv), u8(clamp(fsnote, 0, 127)))
    case "substageprobe":
        ssnotes := "60"
        ssp95 := SUBSTAGE_P95_DEFAULT
        ssmix := "0,96"
        sssaturation := "0,64"
        ssgain := 64
        sscsv := ""
        {
            i := 0
            for i < len(rest) {
                switch rest[i] {
                case "--notes":
                    if i + 1 >= len(rest) {usage()}
                    ssnotes = rest[i + 1]
                    i += 2
                case "--p95":
                    if i + 1 >= len(rest) {usage()}
                    ssp95 = rest[i + 1]
                    i += 2
                case "--mix":
                    if i + 1 >= len(rest) {usage()}
                    ssmix = rest[i + 1]
                    i += 2
                case "--saturation":
                    if i + 1 >= len(rest) {usage()}
                    sssaturation = rest[i + 1]
                    i += 2
                case "--gain":
                    if !parse_probe_int(rest, i + 1, &ssgain) {usage()}
                    i += 2
                case "--csv":
                    if i + 1 >= len(rest) {usage()}
                    sscsv = rest[i + 1]
                    i += 2
                case:
                    usage()
                }
            }
        }
        ssnotes_values := parse_env_values(ssnotes)
        defer delete(ssnotes_values)
        ssp95_values := parse_env_values(ssp95)
        defer delete(ssp95_values)
        ssmix_values := parse_env_values(ssmix)
        defer delete(ssmix_values)
        sssaturation_values := parse_env_values(sssaturation)
        defer delete(sssaturation_values)
        cmd_substageprobe(dll, sscsv, ssnotes_values, ssp95_values, ssmix_values, sssaturation_values, clamp(ssgain, 0, 127))
	case "tuningcheck":
		tcnote := 60
		tcpath := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--note":
					if !parse_probe_int(rest, i + 1, &tcnote) {usage()}
					i += 2
				case:
					if tcpath != "" {usage()}
					tcpath = rest[i]
					i += 1
				}
			}
		}
		if tcpath == "" {usage()}
		cmd_tuningcheck(dll, tcpath, tcnote)
	case "phaserprobe":
		pptype := 6
		ppctl1 := 64
		ppctl2 := 64
		pplevel := 127
		ppnote := int(FX_PROBE_NOTE)
		pprows := 48
		ppgain := 48
		ppsecs := 8
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &pptype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &ppctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &ppctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &pplevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &ppnote) {usage()}
					i += 2
				case "--rows":
					if !parse_probe_int(rest, i + 1, &pprows) {usage()}
					i += 2
				case "--gain":
					if !parse_probe_int(rest, i + 1, &ppgain) {usage()}
					i += 2
				case "--seconds":
					if !parse_probe_int(rest, i + 1, &ppsecs) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(ppnote)
		cmd_phaserprobe(dll, pptype, ppctl1, ppctl2, pplevel, ppgain, f64(ppsecs), pprows)
	case "fxcurve":
		fctype, fcctl2, fclevel := 0, 127, 127
		fcnote, fcgain := 36, 127
		fcdrives := "0,32,64,96,127"
		fccsv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &fctype) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &fcctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &fclevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fcnote) {usage()}
					i += 2
				case "--gain":
					if !parse_probe_int(rest, i + 1, &fcgain) {usage()}
					i += 2
				case "--drives":
					if i + 1 >= len(rest) {usage()}
					fcdrives = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					fccsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(fcnote)
		cmd_fxcurve(dll, fctype, 0, fcctl2, fclevel, fcnote, fcgain, parse_env_values(fcdrives), fccsv)
	case "fxharm":
		fhtype, fhctl2, fhlevel, fhnote := 0, 127, 127, 48
		fhdrives := "0,16,32,48,64,80,96,112,127"
		fhgains := "127"
		fhcsv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &fhtype) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &fhctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &fhlevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fhnote) {usage()}
					i += 2
				case "--drives":
					if i + 1 >= len(rest) {usage()}
					fhdrives = rest[i + 1]
					i += 2
				case "--gains":
					if i + 1 >= len(rest) {usage()}
					fhgains = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					fhcsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(fhnote)
		cmd_fxharm(dll, fhtype, fhctl2, fhlevel, fhnote, parse_env_values(fhdrives), parse_env_values(fhgains), fhcsv)
	case "phaserrate":
		prtype, prctl1, prlevel := 6, 64, 127
		prnote, prgain := 96, 127
		prsec := 6
		prvals := "48,64,80,96,104,112,120,127"
		prcsv := ""
		prblock := COMPARE_BLOCK_DEFAULT
		prenv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &prtype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &prctl1) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &prlevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &prnote) {usage()}
					i += 2
				case "--gain":
					if !parse_probe_int(rest, i + 1, &prgain) {usage()}
					i += 2
				case "--seconds":
					if !parse_probe_int(rest, i + 1, &prsec) {usage()}
					i += 2
				case "--block":
					if !parse_probe_int(rest, i + 1, &prblock) {usage()}
					i += 2
				case "--envelope":
					if i + 1 >= len(rest) {usage()}
					prenv = rest[i + 1]
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					prvals = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					prcsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_phaserrate(
			dll,
			prtype,
			prctl1,
			prlevel,
			prnote,
			prgain,
			parse_env_values(prvals),
			f64(prsec),
			prcsv,
			prblock,
			prenv,
		)
	case "phasercomb":
		pctype, pcctl1, pcctl2, pclevel := 6, 0, 16, 127
		pcgain := 96
		pcsec := 20
		pcshow := false
		pccsv := ""
		pccurve := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &pctype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &pcctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &pcctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &pclevel) {usage()}
					i += 2
				case "--gain":
					if !parse_probe_int(rest, i + 1, &pcgain) {usage()}
					i += 2
				case "--seconds":
					if !parse_probe_int(rest, i + 1, &pcsec) {usage()}
					i += 2
				case "--fft":
					if !parse_probe_int(rest, i + 1, &g_comb_fft) {usage()}
					i += 2
				case "--show":
					pcshow = true
					i += 1
				case "--curve":
					if i + 1 >= len(rest) {usage()}
					pccurve = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					pccsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_phasercomb(dll, pctype, pcctl1, pcctl2, pclevel, pcgain, f64(pcsec), pcshow, pccsv, pccurve)
	case "phaserband":
		pbtype, pbctl1, pbctl2, pblevel := 6, 64, 80, 127
		pbnotes := "24,27,30,33,36,39,42,45,48,51,54,57,60,63,66,69,72,75,78,81,84,87,90,93,96,99,102,105,108,111,114,117,120"
		pbcsv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &pbtype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &pbctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &pbctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &pblevel) {usage()}
					i += 2
				case "--notes":
					if i + 1 >= len(rest) {usage()}
					pbnotes = rest[i + 1]
					i += 2
				case "--seconds":
					pbsec := 3
					if !parse_probe_int(rest, i + 1, &pbsec) {usage()}
					g_phaser_band_seconds = f64(pbsec)
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					pbcsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_phaserband(dll, pbtype, pbctl1, pbctl2, pblevel, parse_env_values(pbnotes), pbcsv)
	case "comptrace":
		ctctl1, ctctl2, ctlevel := 64, 64, 127
		ctnote := int(FX_PROBE_NOTE)
		ctamp, ctdecay, ctsustain := 127, 40, 48
		ctstep := 1
		ctcsv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &ctctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &ctctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &ctlevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &ctnote) {usage()}
					i += 2
				case "--amp":
					if !parse_probe_int(rest, i + 1, &ctamp) {usage()}
					i += 2
				case "--decay":
					if !parse_probe_int(rest, i + 1, &ctdecay) {usage()}
					i += 2
				case "--sustain":
					if !parse_probe_int(rest, i + 1, &ctsustain) {usage()}
					i += 2
				case "--step":
					if !parse_probe_int(rest, i + 1, &ctstep) {usage()}
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					ctcsv = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(ctnote)
		cmd_comptrace(dll, ctctl1, ctctl2, ctlevel, ctnote, ctamp, ctdecay, ctsustain, f64(ctstep), ctcsv)
	case "compcurve":
		ccctl1 := 64
		ccctl2 := 0
		cclevel := 127
		ccnote := int(FX_PROBE_NOTE)
		ccgains := "0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,127"
		cccsv := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &ccctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &ccctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &cclevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &ccnote) {usage()}
					i += 2
				case "--gains":
					if i + 1 >= len(rest) {usage()}
					ccgains = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					cccsv = rest[i + 1]
					i += 2
				case "--depths":
					if i + 1 >= len(rest) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(ccnote)
		ccdepths := ""
		{
			i := 0
			for i < len(rest) {
				if rest[i] == "--depths" && i + 1 < len(rest) {
					ccdepths = rest[i + 1]
				}
				i += 1
			}
		}
		cmd_compcurve(
			dll,
			ccctl1,
			ccctl2,
			cclevel,
			ccnote,
			parse_env_values(ccgains),
			cccsv,
			ccdepths != "" ? parse_env_values(ccdepths) : nil,
		)
	case "fxcompare":
		fcctl1 := 64
		fcctl2 := 64
		fclevel := 127
		fcnote := int(FX_PROBE_NOTE)
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &fcctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &fcctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &fclevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fcnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(fcnote)
		cmd_fxcompare(dll, fcctl1, fcctl2, fclevel, fcnote)
	case "fxenv":
		etype := 6
		ectl1 := 64
		ectl2 := 64
		elevel := 127
		estep := 10
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &etype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &ectl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &ectl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &elevel) {usage()}
					i += 2
				case "--step":
					if !parse_probe_int(rest, i + 1, &estep) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_fxenv(dll, etype, ectl1, ectl2, elevel, f64(estep))
	case "fxcorner":
		ctype := 2
		cdrive := 96
		cvals := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &ctype) {usage()}
					i += 2
				case "--drive":
					if !parse_probe_int(rest, i + 1, &cdrive) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cvals = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_fxcorner(dll, ctype, parse_env_values(cvals), cdrive)
	case "runhist":
		rtype := 3
		rctl1 := 127
		rctl2 := 0
		rlevel := 127
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &rtype) {usage()}
					i += 2
				case "--ctl1":
					if !parse_probe_int(rest, i + 1, &rctl1) {usage()}
					i += 2
				case "--ctl2":
					if !parse_probe_int(rest, i + 1, &rctl2) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &rlevel) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_runhist(dll, rtype, rctl1, rctl2, rlevel)
	case "deciprobe":
		dctl := 1
		dother := 0
		dnote := int(FX_PROBE_NOTE)
		dvals := ""
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--ctl":
					if !parse_probe_int(rest, i + 1, &dctl) {usage()}
					i += 2
				case "--other":
					if !parse_probe_int(rest, i + 1, &dother) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &dnote) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					dvals = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(dnote)
		cmd_deciprobe(dll, dctl, parse_env_values(dvals), dother)
	case "fxsweep":
		fxtype := 0
		fxctl := 1
		fxother := 64
		fxlevel := 127
		fxsnote := int(FX_PROBE_NOTE)
		fxvals := "0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,127"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &fxtype) {usage()}
					i += 2
				case "--ctl":
					if !parse_probe_int(rest, i + 1, &fxctl) {usage()}
					i += 2
				case "--other":
					if !parse_probe_int(rest, i + 1, &fxother) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &fxlevel) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fxsnote) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					fxvals = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		set_fx_note(fxsnote)
		cmd_fxsweep(dll, fxtype, fxctl, parse_env_values(fxvals), fxother, fxlevel)
	case "fxprobe":
		fxconfig := ""
		fxnote := int(FX_PROBE_NOTE)
		fxdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--config":
					if i + 1 >= len(rest) {usage()}
					fxconfig = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fxnote) {usage()}
					i += 2
		case "--dump":
					fxdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		set_fx_note(fxnote)
		cmd_fxprobe(dll, fxconfig, fxdump)
	case "lfoprobe":
		param := 41
		lrate := 40
		lnote := 60
		ldump := false
		i := 0
		for i < len(rest) {
			switch rest[i] {
			case "--param":
				if !parse_probe_int(rest, i + 1, &param) {usage()}
				i += 2
			case "--pw":
				if !parse_probe_int(rest, i + 1, &g_probe_pw) {usage()}
				i += 2
			case "--rate":
				if !parse_probe_int(rest, i + 1, &lrate) {usage()}
				i += 2
			case "--note":
				if !parse_probe_int(rest, i + 1, &lnote) {usage()}
				i += 2
			case "--dump":
				ldump = true
				i += 1
			case:
				usage()
			}
		}
		cmd_lfoprobe(dll, param, u8(clamp(lrate, 0, 127)), u8(clamp(lnote, 0, 127)), ldump)
	case "gainprobe":
		gspec := ""
		gcsv := ""
		gnote := 60
		gdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					gspec = rest[i + 1]
					i += 2
				case "--csv":
					if i + 1 >= len(rest) {usage()}
					gcsv = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &gnote) {usage()}
					i += 2
				case "--dump":
					gdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_gainprobe(dll, gspec, gcsv, u8(clamp(gnote, 0, 127)), gdump)
	case "cutoffprobe":
		csweep := "cutoff"
		ccut := 64
		camt := 63
		csus := 127
		cspec := ""
		cnote := 60
		cdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--sweep":
					if i + 1 >= len(rest) {usage()}
					csweep = rest[i + 1]
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &ccut) {usage()}
					i += 2
				case "--amount":
					if !parse_probe_int(rest, i + 1, &camt) {usage()}
					i += 2
				case "--sustain":
					if !parse_probe_int(rest, i + 1, &csus) {usage()}
					i += 2
				case "--ktrack":
					if !parse_probe_int(rest, i + 1, &g_probe_ktrack) {usage()}
					i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &g_probe_filter_type) {usage()}
					i += 2
				case "--res":
					if !parse_probe_int(rest, i + 1, &g_probe_resonance) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cspec = rest[i + 1]
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &g_chorusfb_level) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &cnote) {usage()}
					i += 2
				case "--dump":
					cdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_cutoffprobe(dll, csweep, ccut, camt, csus, cspec, u8(clamp(cnote, 0, 127)), cdump)
	case "filtertable":
		ftype := 0
		fout := ""
		fpeak := -1
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &ftype) {usage()}
					i += 2
				case "--peak":
					if !parse_probe_int(rest, i + 1, &fpeak) {usage()}
					i += 2
				case:
					if fout == "" {
						fout = rest[i]
						i += 1
					} else {
						usage()
					}
				}
			}
		}
		if fout == "" {
			fout = ftype == 1 ? "src/engine/filter_table_24.odin" : "src/engine/filter_table.odin"
		}
		cmd_filtertable(dll, fout, 60, ftype, fpeak)
	case "lfopitch":
		pparam := 41
		pspec := "0,16,32,48,64,80,96,112,127"
		pnotes := "36,48,60,72"
		prate := LFO_PITCH_RATE
		pdest := 2
		pdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &pparam) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					pspec = rest[i + 1]
					i += 2
				case "--notes":
					if i + 1 >= len(rest) {usage()}
					pnotes = rest[i + 1]
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &prate) {usage()}
					i += 2
				case "--dest":
					if !parse_probe_int(rest, i + 1, &pdest) {usage()}
					i += 2
				case "--dump":
					pdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lfopitch(dll, pparam, pspec, pnotes, prate, pdest, pdump)
	case "lfofm":
		fparam := 41
		fspec := "0,8,16,32,48,64,80,96,112,127"
		fnote := 60
		frate := 0
		fdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &fparam) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					fspec = rest[i + 1]
					i += 2
				case "--base":
					if !parse_probe_int(rest, i + 1, &g_lfo_fm_base) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fnote) {usage()}
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &frate) {usage()}
					i += 2
				case "--dump":
					fdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lfofm(dll, fparam, fspec, u8(clamp(fnote, 0, 127)), frate, fdump)
	case "lfosquare":
		qparam := 41
		qdest := 3
		qspec := "0,8,16,24,32,48,64,80,96,112,127"
		qnote := 60
		qrate := 0
		qdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &qparam) {usage()}
					i += 2
				case "--dest":
					if !parse_probe_int(rest, i + 1, &qdest) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					qspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &qnote) {usage()}
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &qrate) {usage()}
					i += 2
				case "--base":
					if !parse_probe_int(rest, i + 1, &g_lfo_sq_cutoff_base) {usage()}
					i += 2
				case "--trace":
					g_lfo_square_trace = true
					i += 1
				case "--dump":
					qdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lfosquare(dll, qparam, qdest, qspec, u8(clamp(qnote, 0, 127)), qrate, qdump)
	case "lfoshape":
		sparam := 42
		sspec := "all"
		sspeed := LFO_SHAPE_SPEED
		snote := int(LFO_SHAPE_NOTE)
		sdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &sparam) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					sspec = rest[i + 1]
					i += 2
				case "--speed":
					if !parse_probe_int(rest, i + 1, &sspeed) {usage()}
					i += 2
				case "--depth":
					if !parse_probe_int(rest, i + 1, &g_lfo_shape_depth) {usage()}
					i += 2
				case "--dest":
					if !parse_probe_int(rest, i + 1, &g_lfo_shape_dest) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &snote) {usage()}
					i += 2
				case "--dump":
					sdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lfoshape(dll, sparam, sspec, sspeed, u8(clamp(snote, 0, 127)), sdump)
	case "qprobe":
		qtype := QPROBE_TYPE_DEFAULT
		qcut := QPROBE_CUTOFF_DEFAULT
		qspec := ""
		qnote := 60
		qcal := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &qtype) {usage()}
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &qcut) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					qspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &qnote) {usage()}
					i += 2
				case "--calibrate":
					qcal = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_qprobe(dll, clamp(qtype, 0, 4), clamp(qcut, 0, 127), qspec, u8(clamp(qnote, 0, 127)), qcal)
	case "peakprobe":
		pktype := 1
		pkcut := 80
		pkspec := "0,20,40,60,80,96,107,120,127"
		pknote := 60
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &pktype) {usage()}
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &pkcut) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					pkspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &pknote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_peakprobe(dll, clamp(pktype, 0, 4), clamp(pkcut, 0, 127), pkspec, u8(clamp(pknote, 0, 127)))
	case "qlevel":
		ltype := QPROBE_TYPE_DEFAULT
		lcut := QPROBE_CUTOFF_DEFAULT
		lspec := ""
		lnote := 60
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &ltype) {usage()}
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &lcut) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					lspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &lnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_qlevel(dll, clamp(ltype, 0, 4), clamp(lcut, 0, 127), lspec, u8(clamp(lnote, 0, 127)))
	case "qtable":
		qout := "src/engine/filter_resonance_table.odin"
		if len(rest) >= 1 {qout = rest[0]}
		cmd_qtable(dll, qout, 60)
	case "lfodepth":
		dparam := 41
		dspec := "0,16,32,48,64,80,96,112,127"
		dnote := 60
		drate := 20
		ddump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &dparam) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					dspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &dnote) {usage()}
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &drate) {usage()}
					i += 2
				case "--dump":
					ddump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lfodepth(dll, dparam, dspec, u8(clamp(dnote, 0, 127)), drate, ddump)
	case "arpprobe":
		{
			base := ARP_DEFAULT_BASE
			atype, arange, abeat, agate := 0, 0, 11, 64
			seconds := 4.0
			sweep := false
			notes: [dynamic]u8
			append(&notes, 60, 64, 67)
			defer delete(notes)
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--base":
					if i + 1 >= len(rest) {usage()}
					base = rest[i + 1]; i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &atype) {usage()}
					i += 2
				case "--range":
					if !parse_probe_int(rest, i + 1, &arange) {usage()}
					i += 2
				case "--gate":
					if !parse_probe_int(rest, i + 1, &agate) {usage()}
					i += 2
				case "--beat":
					if i + 1 >= len(rest) {usage()}
					if rest[i + 1] == "all" {
						sweep = true
					} else if !parse_probe_int(rest, i + 1, &abeat) {usage()}
					i += 2
				case "--seconds":
					if i + 1 >= len(rest) {usage()}
					seconds, _ = strconv.parse_f64(rest[i + 1]); i += 2
				case "--notes":
					if i + 1 >= len(rest) {usage()}
					clear(&notes)
					for field in strings.split(rest[i + 1], ",", context.temp_allocator) {
						if n, n_ok := strconv.parse_int(strings.trim_space(field)); n_ok {
							append(&notes, u8(clamp(n, 0, 127)))
						}
					}
					i += 2
				case:
					usage()
				}
			}
			cmd_arpprobe(dll, base, atype, arange, abeat, agate, notes[:], seconds, sweep)
		}
	case "lforate":
		rparam := 43
		rspec := "0,16,32,48,64,80,96,112,127"
		rnote := int(RATE_PROBE_NOTE)
		rsync := false
		rdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--param":
					if !parse_probe_int(rest, i + 1, &rparam) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					rspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &rnote) {usage()}
					i += 2
				case "--tempo-sync":
					rsync = true
					i += 1
				case "--dump":
					rdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_lforate(dll, rparam, rspec, u8(clamp(rnote, 0, 127)), rsync, rdump)
	case "lforatetable":
		rout := "src/engine/lfo_rate_table.odin"
		if len(rest) >= 1 {rout = rest[0]}
		cmd_lforatetable(dll, rout, RATE_PROBE_NOTE)
	case "bandprofile":
		bpdir := "ext/synth1/Synth1/soundbank00"
		bpnote := 60
		bplimit := 0
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--dir":
					if i + 1 >= len(rest) {usage()}
					bpdir = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &bpnote) {usage()}
					i += 2
				case "--limit":
					if !parse_probe_int(rest, i + 1, &bplimit) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_bandprofile(dll, bpdir, bpnote, bplimit)
	case "envtrace":
		etdir := "ext/synth1/Synth1/soundbank00"
		etnote := 60
		etstep := 25
		etnames: [dynamic]string
		defer delete(etnames)
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--dir":
					if i + 1 >= len(rest) {usage()}
					etdir = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &etnote) {usage()}
					i += 2
				case "--step":
					if !parse_probe_int(rest, i + 1, &etstep) {usage()}
					i += 2
				case:
					append(&etnames, rest[i])
					i += 1
				}
			}
		}
		if len(etnames) == 0 {usage()}
		cmd_envtrace(dll, etdir, etnames[:], etnote, f64(etstep))
	case "choruspatch":
		cpdir := "ext/synth1/Synth1/soundbank00"
		cpnote := 60
		cpbands := false
		cpnames: [dynamic]string
		defer delete(cpnames)
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--dir":
					if i + 1 >= len(rest) {usage()}
					cpdir = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &cpnote) {usage()}
					i += 2
				case "--bands":
					cpbands = true
					i += 1
				case:
					append(&cpnames, rest[i])
					i += 1
				}
			}
		}
		if len(cpnames) == 0 {usage()}
		cmd_choruspatch(dll, cpdir, cpnames[:], cpnote, cpbands)
	case "choruswidth":
		cwvals := "0,16,32,64,96,127"
		cwrate := 63
		cwdelay := 126
		cwtype := 2
		cwsweep := "depth"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cwvals = rest[i + 1]
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &cwrate) {usage()}
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &cwdelay) {usage()}
					i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &cwtype) {usage()}
					i += 2
				case "--sweep":
					if i + 1 >= len(rest) {usage()}
					cwsweep = rest[i + 1]
					i += 2
				case "--depth":
					if !parse_probe_int(rest, i + 1, &g_choruswidth_depth) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_choruswidth(dll, parse_env_values(cwvals), cwsweep, cwrate, cwdelay, cwtype)
	case "velprobe":
		vpsens := 22
		vpvals := "1,16,32,48,64,80,96,112,127"
		vpnote := 60
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--sens":
					if !parse_probe_int(rest, i + 1, &vpsens) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					vpvals = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &vpnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_velprobe(dll, vpsens, parse_env_values(vpvals), u8(clamp(vpnote, 0, 127)))
	case "chorusdepth":
		cdvals := "0,16,32,48,64,80,96,112,127"
		cdrate := 50
		cddelay := 64
		cdnote := 72
		cdsec := 6.0
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cdvals = rest[i + 1]
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &cdrate) {usage()}
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &cddelay) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &cdnote) {usage()}
					i += 2
				case "--seconds":
					if i + 1 >= len(rest) {usage()}
					v, ok := strconv.parse_f64(rest[i + 1])
					if !ok {usage()}
					cdsec = v
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_chorusdepth(dll, parse_env_values(cdvals), cdrate, cddelay, u8(clamp(cdnote, 0, 127)), cdsec)
	case "chorusphase":
		cpvals := "19,26,50,56,64,80"
		cpdelay := 64
		cptype := 2
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cpvals = rest[i + 1]
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &cpdelay) {usage()}
					i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &cptype) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_chorusphase(dll, parse_env_values(cpvals), cpdelay, cptype)
	case "chorusstability":
		cstype := 2
		csdelay := 64
		csdepth := 64
		csrate := 64
		csfeedback := 0
		csseconds := 20.0
		csfile := ""
		csnote := 60
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &cstype) {usage()}
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &csdelay) {usage()}
					i += 2
				case "--depth":
					if !parse_probe_int(rest, i + 1, &csdepth) {usage()}
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &csrate) {usage()}
					i += 2
				case "--feedback":
					if !parse_probe_int(rest, i + 1, &csfeedback) {usage()}
					i += 2
				case "--seconds":
					if i + 1 >= len(rest) {usage()}
					v, ok := strconv.parse_f64(rest[i + 1])
					if !ok {usage()}
					csseconds = v
					i += 2
				case "--file":
					if i + 1 >= len(rest) {usage()}
					csfile = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &csnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_chorusstability(dll, cstype, csdelay, csdepth, csrate, csfeedback, csseconds, csfile, u8(clamp(csnote, 0, 127)))
	case "progparam":
		ppprog := 0
		ppindices := "55"
		ppcount := 1
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--program":
					if !parse_probe_int(rest, i + 1, &ppprog) {usage()}
					i += 2
				case "--indices":
					if i + 1 >= len(rest) {usage()}
					ppindices = rest[i + 1]
					i += 2
				case "--count":
					if !parse_probe_int(rest, i + 1, &ppcount) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_progparam(dll, ppprog, parse_index_list(ppindices), ppcount)
	case "filterdistortion":
		fdtype := 1
		fdcutoff := 80
		fdnote := 60
		fdspec := "0,16,32,48,64,80,96,112,127"
		fdgain := 110
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &fdtype) {usage()}
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &fdcutoff) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fdnote) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					fdspec = rest[i + 1]
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &fdgain) {usage()}
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_filterdistortion(dll, fdtype, fdcutoff, u8(clamp(fdnote, 0, 127)), fdspec, fdgain)
	case "filtersaturation":
		fstype := 0
		fscutoff := 127
		fsres := 0
		fsnote := 60
		fsshape := 0
		fswidth := 64
		fsvalues := "0,16,32,48,64,80,96,109,112,122,127"
		fsgains := "32,64,96,127"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--type":
					if !parse_probe_int(rest, i + 1, &fstype) {usage()}
					i += 2
				case "--cutoff":
					if !parse_probe_int(rest, i + 1, &fscutoff) {usage()}
					i += 2
				case "--res":
					if !parse_probe_int(rest, i + 1, &fsres) {usage()}
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &fsnote) {usage()}
					i += 2
				case "--shape":
					if !parse_probe_int(rest, i + 1, &fsshape) {usage()}
					i += 2
				case "--width":
					if !parse_probe_int(rest, i + 1, &fswidth) {usage()}
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					fsvalues = rest[i + 1]
					i += 2
				case "--gains":
					if i + 1 >= len(rest) {usage()}
					fsgains = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_filtersaturation(
			dll, fstype, fscutoff, fsres, clamp(fsshape, 0, 3), clamp(fswidth, 0, 127),
			u8(clamp(fsnote, 0, 127)), fsvalues, fsgains,
		)
	case "oscspectrum":
		if len(rest) < 1 {usage()}
		ospath := rest[0]
		osnote := 60
		oslo := 150.0
		oshi := 350.0
		osat := 0.3
		{
			i := 1
			for i < len(rest) {
				switch rest[i] {
				case "--note":
					if !parse_probe_int(rest, i + 1, &osnote) {usage()}
					i += 2
				case "--lo":
					if i + 1 >= len(rest) {usage()}
					v, ok := strconv.parse_f64(rest[i + 1])
					if !ok {usage()}
					oslo = v
					i += 2
				case "--hi":
					if i + 1 >= len(rest) {usage()}
					v, ok := strconv.parse_f64(rest[i + 1])
					if !ok {usage()}
					oshi = v
					i += 2
				case "--at":
					if i + 1 >= len(rest) {usage()}
					v, ok := strconv.parse_f64(rest[i + 1])
					if !ok {usage()}
					osat = v
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_oscspectrum(dll, ospath, u8(clamp(osnote, 0, 127)), oslo, oshi, osat)
	case "chorustrack":
		ctvals := "0,16,32,48,64,80,96,112,127"
		ctrate := 63
		ctdelay := 126
		cttype := 2
		ctsweep := "depth"
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					ctvals = rest[i + 1]
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &ctrate) {usage()}
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &ctdelay) {usage()}
					i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &cttype) {usage()}
					i += 2
				case "--sweep":
					if i + 1 >= len(rest) {usage()}
					ctsweep = rest[i + 1]
					i += 2
				case:
					usage()
				}
			}
		}
		cmd_chorustrack(dll, parse_env_values(ctvals), ctrate, ctdelay, cttype, ctsweep)
	case "chorusfb":
		{
			cspec := "0,8,16,32,48,63,64,80,96,112,127"
			cnote := 60
			cdump := false
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--values":
					if i + 1 >= len(rest) {usage()}
					cspec = rest[i + 1]
					i += 2
				case "--note":
					if !parse_probe_int(rest, i + 1, &cnote) {usage()}
					i += 2
				case "--level":
					if !parse_probe_int(rest, i + 1, &g_chorusfb_level) {usage()}
					i += 2
				case "--dump":
					cdump = true
					i += 1
				case:
					usage()
				}
			}
			cmd_chorusfb(dll, cspec, u8(clamp(cnote, 0, 127)), cdump)
		}
	case "patchdiag":
		{
			if len(rest) < 1 {usage()}
			pdpath := rest[0]
			pdnote := 60
			i := 1
			for i < len(rest) {
				switch rest[i] {
				case "--note":
					if !parse_probe_int(rest, i + 1, &pdnote) {usage()}
					i += 2
				case:
					usage()
				}
			}
			cmd_patchdiag(dll, pdpath, u8(clamp(pdnote, 0, 127)))
		}
	case "fmfilter":
		{
			ffnote := 60
			ffpaths: [dynamic]string
			defer delete(ffpaths)
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--note":
					if !parse_probe_int(rest, i + 1, &ffnote) {usage()}
					i += 2
				case:
					append(&ffpaths, rest[i])
					i += 1
				}
			}
			if len(ffpaths) == 0 {
				append(&ffpaths,
					"patches/incoming/soundbank00/012.sy1",
					"patches/incoming/soundbank00/014.sy1",
					"patches/incoming/soundbank00/038.sy1")
			}
			cmd_fmfilter(dll, ffpaths[:], u8(clamp(ffnote, 0, 127)))
		}
	case "chorusprobe":
		hsweep := "level"
		hspec := "0,16,32,48,64,80,96,112,127"
		hrate := 20
		hdelay := 100
		hdump := false
		{
			i := 0
			for i < len(rest) {
				switch rest[i] {
				case "--sweep":
					if i + 1 >= len(rest) {usage()}
					hsweep = rest[i + 1]
					i += 2
				case "--values":
					if i + 1 >= len(rest) {usage()}
					hspec = rest[i + 1]
					i += 2
				case "--rate":
					if !parse_probe_int(rest, i + 1, &hrate) {usage()}
					i += 2
				case "--delay":
					if !parse_probe_int(rest, i + 1, &hdelay) {usage()}
					i += 2
				case "--type":
					if !parse_probe_int(rest, i + 1, &g_chorus_type) {usage()}
					i += 2
				case "--dump":
					hdump = true
					i += 1
				case:
					usage()
				}
			}
		}
		cmd_chorusprobe(dll, hsweep, hspec, hrate, hdelay, hdump)
	case "leveltable":
		lout := "src/engine/level_table.odin"
		if len(rest) >= 1 {lout = rest[0]}
		cmd_leveltable(dll, lout, 60)
	case "waveprobe":
		wnote := 60
		wdump := false
		i := 0
		for i < len(rest) {
			switch rest[i] {
			case "--note":
				if !parse_probe_int(rest, i + 1, &wnote) {usage()}
				i += 2
			case "--dump":
				wdump = true
				i += 1
			case:
				usage()
			}
		}
		cmd_waveprobe(dll, u8(clamp(wnote, 0, 127)), wdump)
	case "envtable":
		out := "src/engine/envelope_table.odin"
		if len(rest) >= 1 {
			out = rest[0]
		}
		cmd_envtable(dll, out)
	case "chunkdump":
		cmd_chunkdump(dll)
	case "chunkload":
		if len(rest) < 1 {usage()}
		index := 0
		if len(rest) >= 2 {index, _ = strconv.parse_int(rest[1])}
		cmd_chunkload(dll, rest[0], i32(index))
	case "drivers":
		if len(rest) < 2 {usage()}
		target, _ := strconv.parse_int(rest[0])
		driver, _ := strconv.parse_int(rest[1])
		cmd_drivers(dll, i32(target), i32(driver))
	case "assigns":
		{
			lim := 56
			if len(rest) >= 1 {lim, _ = strconv.parse_int(rest[0])}
			cmd_assigns(dll, lim)
		}
	case "states":
		if len(rest) < 1 {usage()}
		{
			idx, _ := strconv.parse_int(rest[0])
			cmd_states(dll, i32(idx))
		}
	case "coerce":
		if len(rest) < 2 {usage()}
		target, _ := strconv.parse_int(rest[0])
		values: [dynamic]int
		for a in rest[1:] {
			v, _ := strconv.parse_int(a)
			append(&values, v)
		}
		cmd_coerce(dll, i32(target), values[:])
	case "chunkmap":
		ci := 0
		if len(rest) >= 1 {ci, _ = strconv.parse_int(rest[0])}
		cmd_chunkmap(dll, i32(ci))
	case "chunkpoke":
		if len(rest) < 4 {usage()}
		ci, _ := strconv.parse_int(rest[0])
		base, _ := strconv.parse_int(rest[1])
		stride, _ := strconv.parse_int(rest[2])
		pairs: [dynamic][2]int
		for a in rest[3:] {
			c := strings.index_byte(a, ':')
			if c < 0 {usage()}
			pi, _ := strconv.parse_int(a[:c])
			pv, _ := strconv.parse_int(a[c+1:])
			append(&pairs, [2]int{pi, pv})
		}
		cmd_chunkpoke(dll, i32(ci), base, stride, pairs[:])
	case "chunkscan":
		if len(rest) < 4 {usage()}
		ci, _ := strconv.parse_int(rest[0])
		pi, _ := strconv.parse_int(rest[1])
		lo, _ := strconv.parse_int(rest[2])
		hi, _ := strconv.parse_int(rest[3])
		cmd_chunkscan(dll, i32(ci), pi, lo, hi)
	case "chunkclass":
		ci := 0
		if len(rest) >= 1 {ci, _ = strconv.parse_int(rest[0])}
		cmd_chunkclass(dll, i32(ci))
	case "oracletable":
		if len(rest) < 2 {usage()}
		lo, _ := strconv.parse_int(rest[0])
		hi, _ := strconv.parse_int(rest[1])
		cmd_oracletable(dll, 0, lo, hi)
	case "setget":
		if len(rest) < 2 {usage()}
		pi, _ := strconv.parse_int(rest[0])
		vals: [dynamic]f64
		for a in rest[1:] {
			v, _ := strconv.parse_f64(a)
			append(&vals, v)
		}
		cmd_setget(dll, pi, vals[:])
	case:
		usage()
	}
}
