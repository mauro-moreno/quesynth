package s1probe

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import cpatch "../../src/patch"

// hostprobe - which of this host's answers is the arpeggiator crash.
//
//   s1probe hostprobe [dll] <patch.sy1>              # every case, one child each
//   s1probe hostprobe [dll] <patch.sy1> --case 2     # one case, in this process
//
// Five factory patches segfault inside `Synth1 VST64.dll` during
// `processReplacing`, a sixteenth note into the render, and every one of them
// has the arpeggiator on -- switching it off in 100 makes that patch render, and
// switching it on in 001 makes 001 crash. The fault is inside the reference, so
// the question worth asking is not "where in the plugin" but **what does the
// arpeggiator ask this host for that nothing else asks for, and is the answer a
// lie?**
//
// A VST 2.4 host has two ways to tell a plugin the tempo: `audioMasterGetTime`,
// which hands back a `VstTimeInfo`, and `audioMasterTempoAt`, the VST 2.0 call
// that returns the tempo at a sample position as **BPM x 10000**. This host
// implemented the first and answered the second with zero -- and zero is not a
// missing feature, it is a tempo. A step length derived from it is a division by
// nothing, and whatever comes out of that is what indexes the step.
//
// That is a hypothesis, not a finding, so it is measured rather than argued.
// Each case below changes exactly one thing the host claims and renders a patch
// that is known to crash. A case that renders is the answer that was wrong.
//
// The child process is not a nicety. The failure is an access violation inside
// a loaded DLL, so a case that still crashes takes the process with it: the
// parent spawns one child per case and reads the exit code, exactly as
// `--isolate` does for a bank run.
// When the patch is pushed, relative to the plugin being resumed.
//
// A VST 2.4 plugin is allowed to allocate in `effMainsChanged(1)`, and what it
// allocates is sized from the state it holds at that moment. This harness has
// always resumed first and pushed the patch afterwards, which means every
// section the factory chunk has switched *off* -- the arpeggiator among them --
// was switched on after the plugin last had a chance to prepare for it.
Lifecycle :: enum {
	// Resume, then push the chunk. What this host has always done.
	Chunk_After_Resume,
	// Push the chunk while suspended, then resume. What a host loading a
	// project does.
	Chunk_Before_Resume,
	// Push the chunk, then suspend and resume once, so the plugin prepares
	// again with the patch already in it.
	Resume_Cycle_After_Chunk,
}

// What the host claims, as data rather than as code, so a case is a row.
Host_Answers :: struct {
	name:              string,
	// What `audioMasterTempoAt` returns. The VST 2.0 convention is BPM x 10000.
	tempo_at:          int,
	// `audioMasterWantMidi`, which a plugin sending MIDI out asks about.
	want_midi:         int,
	// `audioMasterProcessEvents`, the plugin handing events back to the host.
	process_events:    int,
	// Whether `VstTimeInfo` claims the transport is rolling.
	transport_playing: bool,
	lifecycle:         Lifecycle,
	// Dispatch an empty `effProcessEvents` before every block, which is what a
	// host with no MIDI to deliver does rather than dispatching nothing.
	empty_events:      bool,
	// Zero the retained event list once the plugin has taken it, so a plugin
	// that kept the pointer cannot read the same note again next block.
	clear_events:      bool,
	// Frames per `processReplacing` call. Zero means the compare default.
	block:             int,
}

// The answers a real host gives.
//
// `tempo_at` was zero, which is not a missing answer but a wrong one; it is
// corrected here because a host answering it at all must answer it honestly.
// The probe below shows it is not the crash: the reference ignores it.
HOST_ANSWERS_DEFAULT :: Host_Answers {
	name              = "default",
	tempo_at          = int(HOST_TEMPO * 10000),
	want_midi         = 0,
	process_events    = 0,
	transport_playing = true,
	lifecycle         = .Chunk_After_Resume,
}

// One knob each, so a surviving case names one cause rather than a combination.
HOST_CASES := [?]Host_Answers {
	// What this host has always done, kept first so the crash stays visible.
	{name = "as-shipped", tempo_at = 0, transport_playing = true},
	{name = "tempoat-bpm-x10000", tempo_at = int(HOST_TEMPO * 10000), transport_playing = true},
	{name = "want-midi", want_midi = 1, transport_playing = true},
	{name = "process-events", process_events = 1, transport_playing = true},
	{name = "transport-stopped", transport_playing = false},
	{name = "empty-events-per-block", transport_playing = true, empty_events = true},
	{name = "clear-event-list", transport_playing = true, clear_events = true},
	{name = "block-64", transport_playing = true, block = 64},
	{name = "block-1024", transport_playing = true, block = 1024},
	{name = "chunk-before-resume", transport_playing = true, lifecycle = .Chunk_Before_Resume},
	{name = "resume-cycle-after-chunk", transport_playing = true, lifecycle = .Resume_Cycle_After_Chunk},
}

// Read by `host_cb`. A global because the callback is a C function pointer the
// plugin holds, with nowhere to carry a case in.
g_host_answers := HOST_ANSWERS_DEFAULT

cmd_hostprobe :: proc(dll: string, patch_path: string, single_case: int) {
	if single_case >= 0 {
		if single_case >= len(HOST_CASES) {
			fmt.eprintfln("hostprobe: no case %v", single_case)
			os.exit(2)
		}
		os.exit(run_host_case(dll, patch_path, single_case) ? 0 : 1)
	}

	exe, exe_ok := self_path()
	if !exe_ok {
		fmt.eprintln("hostprobe: cannot find this executable")
		os.exit(1)
	}

	fmt.printfln("hostprobe %s", patch_path)
	fmt.printfln("%-26s %-10s %s", "case", "result", "detail")

	survived := 0
	for c, i in HOST_CASES {
		code, spawned := run_host_child(exe, dll, patch_path, i)
		switch {
		case !spawned:
			fmt.printfln("%-26s %-10s %s", c.name, "error", "cannot spawn a child")
		case code == 0:
			survived += 1
			fmt.printfln("%-26s %-10s %s", c.name, "PLAYED", host_case_detail(c))
		case code == EXIT_SILENT:
			// Renders, makes no sound. Not a fix -- a different question.
			fmt.printfln("%-26s %-10s %s", c.name, "silent", host_case_detail(c))
		case:
			fmt.printfln("%-26s %-10s %s", c.name, "died", exit_reason(code))
		}
	}
	fmt.printfln("cases: %v, rendered: %v", len(HOST_CASES), survived)
}

host_case_detail :: proc(c: Host_Answers) -> string {
	return fmt.tprintf(
		"tempoAt=%v wantMidi=%v processEvents=%v playing=%v",
		c.tempo_at,
		c.want_midi,
		c.process_events,
		c.transport_playing,
	)
}

// One case, in this process, rendering the patch the way `compare` does.
run_host_case :: proc(dll, patch_path: string, index: int) -> bool {
	g_quiet_load = true
	g_host_answers = HOST_CASES[index]
	set_compare_timing(COMPARE_BLOCK_DEFAULT)

	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("hostprobe: cannot read %q: %v", patch_path, read_err)
		return false
	}
	parsed, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("hostprobe: cannot parse %q: %v", patch_path, parse_err)
		return false
	}

	// The factory chunk every patch is written into, read from an instance that
	// is gone again before anything is measured.
	pristine: []byte
	{
		p, ok := load(dll)
		if !ok {return false}
		pristine = get_chunk_copy(&p, 0)
		unload(&p)
	}
	if len(pristine) == 0 {
		fmt.eprintln("hostprobe: the plugin returned an empty state chunk")
		return false
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	// The lifecycle case decides when the patch is pushed relative to resume,
	// which is the whole point of the newer cases.
	c := HOST_CASES[index]
	p: Plugin
	loaded: bool
	switch c.lifecycle {
	case .Chunk_After_Resume:
		p, loaded = open_reference(dll)
		if !loaded {return false}
		load_reference_patch(&p, &parsed, pristine, work)
	case .Chunk_Before_Resume:
		host_transport_reset()
		p, loaded = load_suspended(dll)
		if !loaded {return false}
		load_reference_patch(&p, &parsed, pristine, work)
		plugin_resume(&p)
	case .Resume_Cycle_After_Chunk:
		p, loaded = open_reference(dll)
		if !loaded {return false}
		load_reference_patch(&p, &parsed, pristine, work)
		plugin_suspend(&p)
		plugin_resume(&p)
	}
	defer close_reference(&p)

	audio := hostprobe_render(&p, COMPARE_NOTE_DEFAULT, c)
	peak: f32 = 0
	for v in audio {
		a := v < 0 ? -v : v
		if a > peak {peak = a}
	}
	fmt.eprintfln("hostprobe: case %v peak %.4f", c.name, peak)

	// A silent render is not a surviving render. A case that stops the crash by
	// stopping the note has answered a different question, and counting it as a
	// pass is how the first version of this probe reported a fix it did not
	// have. The exit code is what the parent reads, so the distinction has to
	// live there.
	if peak < SILENCE_FLOOR {
		os.exit(EXIT_SILENT)
	}
	return true
}

// Below this a render made no sound. The reference's quietest factory patch
// peaks two orders of magnitude above it.
SILENCE_FLOOR :: f32(1e-5)

// A child that rendered nothing exits with this rather than with zero, so the
// parent can tell "the crash is gone" from "the note is gone".
EXIT_SILENT :: 3

// The probe's own render, rather than compare's.
//
// compare's render is a measured path and must not grow options; this one needs
// to vary the block length and how the event list is delivered, which are two
// of the things being probed.
hostprobe_render :: proc(p: ^Plugin, note: u8, c: Host_Answers) -> []f32 {
	e := p.eff
	block := c.block > 0 ? c.block : g_block
	channels := max(int(e.num_outputs), 1)
	inputs := max(int(e.num_inputs), 1)

	chans := make([][]f32, channels)
	ptrs := make([][^]f32, channels)
	for i in 0 ..< channels {
		chans[i] = make([]f32, block)
		ptrs[i] = raw_data(chans[i])
	}
	in_chans := make([][]f32, inputs)
	in_ptrs := make([][^]f32, inputs)
	for i in 0 ..< inputs {
		in_chans[i] = make([]f32, block)
		in_ptrs[i] = raw_data(in_chans[i])
	}

	total := (g_total_frames / block) * block
	hold := (g_hold_frames / block) * block
	out := make([]f32, total * 2)

	host_transport_reset()

	// The note events go inside the loop, on the block they belong to, so the
	// "empty list" case cannot overwrite the note-on before it is ever
	// processed. The first version of this probe did exactly that and reported
	// a silent render as a success -- which is the failure mode CONTRIBUTING.md
	// names: a test whose own input is built by the thing under test.
	empty: VstEvents
	for pos := 0; pos < total; pos += block {
		switch {
		case pos == 0:
			send_midi(p, 0x90, note, COMPARE_VELOCITY_MIDI, 0)
		case pos == hold:
			send_midi(p, 0x80, note, 0, 0)
		case c.empty_events:
			// What a host with nothing to deliver does: dispatch an empty list
			// rather than dispatching nothing at all.
			e.dispatcher(e, i32(Op.ProcessEvents), 0, 0, &empty, 0)
		}
		if c.clear_events {
			g_midi_events.num_events = 0
		}

		// Every eighth block, so a child that dies leaves behind how far it
		// got. The first arpeggiator step is the interesting boundary.
		if (pos / block) % 8 == 0 {
			fmt.eprintfln("hostprobe: frame %v of %v", pos, total)
		}

		for i in 0 ..< channels {
			for j in 0 ..< block {chans[i][j] = 0}
		}
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), i32(block))
		host_transport_advance(block)
		for j in 0 ..< block {
			frame := pos + j
			out[frame * 2] = chans[0][j]
			out[frame * 2 + 1] = channels > 1 ? chans[1][j] : chans[0][j]
		}
	}
	return out
}
run_host_child :: proc(exe, dll, patch_path: string, index: int) -> (u32, bool) {
	b := strings.builder_make(context.temp_allocator)
	quote(&b, exe)
	strings.write_string(&b, "hostprobe ")
	quote(&b, dll)
	quote(&b, patch_path)
	fmt.sbprintf(&b, "--case %v ", index)
	return spawn_and_wait(strings.to_string(b))
}

// `--case N` off the tail of a hostprobe command line.
parse_host_case :: proc(args: []string) -> (patch_path: string, single_case: int, ok: bool) {
	single_case = -1
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--case":
			if i + 1 >= len(args) {return "", -1, false}
			value, parsed := strconv.parse_int(args[i + 1])
			if !parsed {return "", -1, false}
			single_case = value
			i += 2
		case:
			if patch_path != "" {return "", -1, false}
			patch_path = args[i]
			i += 1
		}
	}
	return patch_path, single_case, patch_path != ""
}

// -- the other axis: which value in the patch is it -------------------------
//
//   s1probe paramcrash [dll] <patch.sy1>            # one child per parameter
//   s1probe paramcrash [dll] <patch.sy1> --param 59 # one parameter, here
//
// The host answers turned out to make no difference at all -- every case above
// renders a non-arpeggiated patch to the same peak, and every one of them dies
// on an arpeggiated one -- so the question moves to what is being pushed into
// the plugin rather than what the plugin is being told about the world.
//
// A `.sy1` file holds stored integers with no ceiling on them, and this harness
// writes them straight into the reference's own state chunk. That is the point
// of using the chunk: it is the plugin's own loader. But it also means a value
// the plugin's own interface could never produce reaches it, and a value used
// as an index is the shape of fault that kills a process on the step that first
// reads it.
//
// So: restore one parameter at a time to the value the plugin's own factory
// chunk holds, and render. A case that survives names the parameter whose
// stored value the reference cannot digest. A run where only the arpeggiator
// switch survives says the crash needs nothing but the arpeggiator being on,
// and the search moves back to how this host drives it.
cmd_paramcrash :: proc(dll: string, patch_path: string, single: int) {
	if single >= 0 {
		os.exit(run_param_case(dll, patch_path, single) ? 0 : 1)
	}

	exe, exe_ok := self_path()
	if !exe_ok {
		fmt.eprintln("paramcrash: cannot find this executable")
		os.exit(1)
	}

	// Which parameters are worth trying: the ones where the file disagrees with
	// the factory chunk. Restoring a parameter that already holds the factory
	// value cannot change anything.
	parsed, pristine, ok := read_patch_and_chunk(dll, patch_path)
	if !ok {
		os.exit(1)
	}
	defer delete(pristine)

	fmt.printfln("paramcrash %s", patch_path)
	fmt.printfln("%-4s %-26s %-10s %-10s %s", "idx", "parameter", "file", "factory", "result")
	fmt.println("--------------------------------------------------------------------------")

	tried, survived := 0, 0
	for i in 0 ..< cpatch.PARAMETER_COUNT {
		factory := int(i32(read_le_u32(pristine, CHUNK_VALUE_BASE + i * CHUNK_VALUE_STRIDE)))
		if factory == parsed.values[i] {
			continue
		}
		tried += 1
		code, spawned := run_param_child(exe, dll, patch_path, i)
		result := "died"
		if !spawned {
			result = "spawn failed"
		} else if code == 0 {
			result = "RENDERED"
			survived += 1
		} else {
			result = exit_reason(code)
		}
		fmt.printfln(
			"%-4d %-26s %-10d %-10d %s",
			i,
			cpatch.PARAMETERS[i].name,
			parsed.values[i],
			factory,
			result,
		)
	}

	fmt.println("--------------------------------------------------------------------------")
	fmt.printfln("parameters tried: %v, rendered: %v", tried, survived)
}

// The patch, and the factory state chunk it would be written into.
read_patch_and_chunk :: proc(
	dll, patch_path: string,
) -> (
	parsed: cpatch.Patch,
	pristine: []byte,
	ok: bool,
) {
	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("paramcrash: cannot read %q: %v", patch_path, read_err)
		return {}, nil, false
	}
	parse_err: cpatch.Sy1_Error
	parsed, parse_err = cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("paramcrash: cannot parse %q: %v", patch_path, parse_err)
		return {}, nil, false
	}

	g_quiet_load = true
	p, loaded := load(dll)
	if !loaded {
		return {}, nil, false
	}
	pristine = get_chunk_copy(&p, 0)
	unload(&p)
	if len(pristine) == 0 {
		fmt.eprintln("paramcrash: the plugin returned an empty state chunk")
		return {}, nil, false
	}
	return parsed, pristine, true
}

// One parameter restored to its factory value, then rendered.
run_param_case :: proc(dll, patch_path: string, index: int) -> bool {
	if index < 0 || index >= cpatch.PARAMETER_COUNT {
		fmt.eprintfln("paramcrash: %v is not a parameter", index)
		return false
	}
	set_compare_timing(COMPARE_BLOCK_DEFAULT)

	parsed, pristine, ok := read_patch_and_chunk(dll, patch_path)
	if !ok {return false}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	parsed.values[index] = int(i32(read_le_u32(pristine, CHUNK_VALUE_BASE + index * CHUNK_VALUE_STRIDE)))

	p, loaded := open_reference(dll)
	if !loaded {return false}
	defer close_reference(&p)

	load_reference_patch(&p, &parsed, pristine, work)
	audio := render_reference(&p, COMPARE_NOTE_DEFAULT)
	defer delete(audio)

	peak: f32 = 0
	for v in audio {
		a := v < 0 ? -v : v
		if a > peak {peak = a}
	}
	fmt.eprintfln("paramcrash: %v restored, rendered, peak %.4f", cpatch.PARAMETERS[index].name, peak)
	return true
}

run_param_child :: proc(exe, dll, patch_path: string, index: int) -> (u32, bool) {
	b := strings.builder_make(context.temp_allocator)
	quote(&b, exe)
	strings.write_string(&b, "paramcrash ")
	quote(&b, dll)
	quote(&b, patch_path)
	fmt.sbprintf(&b, "--param %v ", index)
	return spawn_and_wait(strings.to_string(b))
}

// `--param N` off the tail of a paramcrash command line.
parse_param_case :: proc(args: []string) -> (patch_path: string, single: int, ok: bool) {
	single = -1
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--param":
			if i + 1 >= len(args) {return "", -1, false}
			value, parsed := strconv.parse_int(args[i + 1])
			if !parsed {return "", -1, false}
			single = value
			i += 2
		case:
			if patch_path != "" {return "", -1, false}
			patch_path = args[i]
			i += 1
		}
	}
	return patch_path, single, patch_path != ""
}
