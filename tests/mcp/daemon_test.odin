#+build linux
package mcp_tests

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import standalone "../../hosts/standalone"
import "../../hosts/standalone/mcp"
import "../../src/engine"
import "../../src/patch"
import "../../src/registry"

// The MCP against the real control server. The test owns the ring and the
// snapshot and stands in for the audio thread by calling live_render, which is
// the code that really applies a transaction and judges its expected revision,
// so everything between the MCP's stdio and the engine's parameters is real
// except the sound card.

Daemon :: struct {
	live:       ^standalone.Live,
	state:      standalone.Daemon_State,
	identity:   standalone.Patch_Identity,
	server:     standalone.Control_Server,
	done:       b32,
	audio:      ^thread.Thread,
	// What a running daemon also hands its control server, present only when
	// daemon_make(full = true) asked for it: the bank, the archive, the master
	// volume, the runtime facts, a MIDI queue nothing else drains and a MIDI
	// selection over two made-up inputs.
	bank:       patch.Slots,
	archive:    standalone.Archive,
	metrics:    standalone.Daemon_Metrics,
	midi_queue: standalone.Midi_Queue,
	input:      standalone.Midi_Input,
	selection:  standalone.Midi_Selection,
}

@(private = "file")
daemon_audio :: proc(data: rawptr) {
	d := (^Daemon)(data)
	for !intrinsics.atomic_load(&d.done) {
		standalone.live_render(d.live, nil, 0, 2)
		time.sleep(time.Millisecond)
	}
}

daemon_make :: proc(draining := true, full := false) -> ^Daemon {
	d := new(Daemon)
	d.live = new(standalone.Live)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT { p.values[i] = patch.PARAMETERS[i].default }
	engine.engine_load_patch(&d.live.eng, p, 48000)
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT { seed.values[i] = i32(engine.engine_patch_value(&d.live.eng, i)) }
	standalone.snapshot_publish(&d.live.snapshot, seed)
	d.state = .Running
	d.identity = standalone.Patch_Identity{slot = -1}
	d.server.path = standin_path("daemon")
	d.server.ctx = standalone.Control_Context {
		ring     = &d.live.ring,
		snapshot = &d.live.snapshot,
		state    = &d.state,
		identity = &d.identity,
	}
	if full { daemon_make_full(d) }
	assert(standalone.control_server_start(&d.server))
	if draining { daemon_start_audio(d) }
	return d
}

// What run_daemon builds beyond the engine: the factory bank, no archive open,
// full volume, the facts daemon.info reports, and every MIDI input open.
@(private = "file")
daemon_make_full :: proc(d: ^Daemon) {
	patch.factory_prepare()
	patch.slots_load_factory(&d.bank)
	d.metrics = standalone.Daemon_Metrics {
		sample_rate = 48000,
		buffer_size = 512,
		max_voices  = 16,
		backend     = "Test Backend",
		start_tick  = time.tick_now(),
	}
	d.live.metrics = &d.metrics
	d.live.volume.milli = standalone.VOLUME_UNITY
	d.live.volume_prev = standalone.VOLUME_UNITY
	standalone.midi_queue_init(&d.midi_queue)
	d.input = standalone.Midi_Input {
		open         = fake_open,
		list         = fake_list,
		open_device  = fake_open_device,
		close_inputs = fake_close,
		close        = fake_close,
	}
	standalone.midi_selection_init(&d.selection, &d.input, &d.midi_queue)
	d.server.ctx.bank = &d.bank
	d.server.ctx.archive = &d.archive
	d.server.ctx.metrics = &d.metrics
	d.server.ctx.midi = &d.midi_queue
	d.server.ctx.volume = &d.live.volume
	d.server.ctx.midi_select = &d.selection
}

// Two inputs, one with a name that has two spaces in it. Nothing is opened:
// the tests read the selection, not what a reader thread would push.
@(private = "file")
fake_open :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue) -> bool {
	return true
}

@(private = "file")
fake_list :: proc(m: ^standalone.Midi_Input) -> []standalone.Midi_Device {
	devices := make([]standalone.Midi_Device, 2)
	devices[0] = {strings.clone("hw:1,0"), strings.clone("Test Keys")}
	devices[1] = {strings.clone("hw:2,0"), strings.clone("Second  Pad")}
	return devices
}

@(private = "file")
fake_open_device :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue, id: string) -> bool {
	return id == "hw:1,0" || id == "hw:2,0"
}

@(private = "file")
fake_close :: proc(m: ^standalone.Midi_Input) {}

@(private = "file")
daemon_start_audio :: proc(d: ^Daemon) {
	d.audio = thread.create_and_start_with_data(d, daemon_audio)
}

daemon_free :: proc(d: ^Daemon) {
	standalone.control_server_stop(&d.server)
	if d.audio != nil {
		intrinsics.atomic_store(&d.done, true)
		thread.join(d.audio)
		thread.destroy(d.audio)
	}
	lock := strings.clone_to_cstring(fmt.tprintf("%s.lock", d.server.path), context.temp_allocator)
	posix.unlink(lock)
	delete(d.server.path)
	// The archive's memory was allocated on the control thread, which has the
	// plain heap, not the tracking allocator this thread's tests run under.
	{
		context.allocator = runtime.heap_allocator()
		standalone.archive_close(&d.archive)
	}
	engine.engine_destroy(&d.live.eng)
	free(d.live)
	free(d)
}

snapshot_of :: proc(d: ^Daemon) -> standalone.Snapshot_Data {
	return standalone.snapshot_read(&d.live.snapshot)
}

stored :: proc(d: ^Daemon, id: string) -> int {
	descriptor, found := registry.registry_describe(id)
	assert(found)
	return int(snapshot_of(d).values[descriptor.index])
}

@(private = "file")
inspect :: proc(s: ^mcp.Session, path: string) -> json.Object {
	text, is_error := call_tool(s, "inspect_synth", `{}`, path)
	assert(!is_error, text)
	return parse_object(text)
}

@(private = "file")
revision_of :: proc(inspected: json.Object) -> int {
	revision, _ := inspected["revision"].(json.Float)
	return int(revision)
}

@(private = "file")
state_lines :: proc(inspected: json.Object) -> json.Array {
	state, _ := inspected["state"].(json.Object)
	lines, _ := state["lines"].(json.Array)
	return lines
}

@(private = "file")
state_value :: proc(inspected: json.Object, id: string) -> string {
	prefix := fmt.tprintf("id=%s value=", id)
	for line in state_lines(inspected) {
		if strings.has_prefix(text_of(line), prefix) { return text_of(line)[len(prefix):] }
	}
	return ""
}

@(private = "file")
apply_one :: proc(s: ^mcp.Session, path: string, expected: int, id: string, value: int) -> (text: string, is_error: bool) {
	arguments := fmt.tprintf(`{{"expected_revision":%d,"parameters":[{{"id":"%s","value":%d}}]}}`, expected, id, value)
	return call_tool(s, "apply_parameters", arguments, path)
}

@(test)
test_inspect_synth_reports_the_daemons_registry_values_and_patch :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	inspected := inspect(&s, d.server.path)
	testing.expect_value(t, revision_of(inspected), 0)

	list := registry.registry_list()
	lines := state_lines(inspected)
	testing.expect_value(t, len(lines), len(list))
	for descriptor, i in list {
		if i >= len(lines) { break }
		// The expected values come from the patch table the engine was loaded
		// with, not from anything the MCP or the daemon reported.
		want := fmt.tprintf("id=%s value=%d", descriptor.id, patch.PARAMETERS[descriptor.index].default)
		testing.expect_value(t, text_of(lines[i]), want)
	}

	parameters, _ := inspected["parameters"].(json.Object)
	records, _ := parameters["lines"].(json.Array)
	testing.expect_value(t, len(records), len(list))
	first := list[0]
	lo, hi, _ := registry.registry_stored_range(first)
	want_first := fmt.tprintf(
		"id=%s group=%s index=%d min=%d max=%d default=%d label=%s",
		first.id,
		first.group,
		first.index,
		lo,
		hi,
		registry.registry_default(first),
		first.label,
	)
	testing.expect_value(t, text_of(records[0]), want_first)

	patch_record, _ := inspected["patch"].(json.Object)
	fields := text_of(patch_record["fields"])
	testing.expect(t, strings.contains(fields, "slot=-1"), fields)
	testing.expect(t, strings.contains(fields, "source=none"), fields)
	testing.expect(t, strings.contains(fields, "revision=0"), fields)
}

@(test)
test_apply_parameters_changes_the_daemon_and_inspect_and_the_resources_see_it :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	before := inspect(&s, d.server.path)
	arguments := fmt.tprintf(
		`{{"expected_revision":%d,"parameters":[{{"id":"filter.cutoff","value":10}},{{"id":"filter.resonance","value":20}}]}}`,
		revision_of(before),
	)
	text, is_error := call_tool(&s, "apply_parameters", arguments, d.server.path)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":2,"revision":1}`)

	// The edit is in the engine's published state, which is what the daemon
	// answers every reader from.
	testing.expect_value(t, stored(d, "filter.cutoff"), 10)
	testing.expect_value(t, stored(d, "filter.resonance"), 20)
	testing.expect_value(t, snapshot_of(d).revision, 1)

	after := inspect(&s, d.server.path)
	testing.expect_value(t, revision_of(after), 1)
	testing.expect_value(t, state_value(after, "filter.cutoff"), "10")
	testing.expect_value(t, state_value(after, "filter.resonance"), "20")
	testing.expect_value(t, state_value(before, "filter.cutoff"), fmt.tprintf("%d", patch.PARAMETERS[registry_index("filter.cutoff")].default))

	resource := parse_object(read_resource(&s, "quesynth://patch", d.server.path))
	testing.expect_value(t, revision_of(resource), 1)
	testing.expect_value(t, state_value(resource, "filter.cutoff"), "10")
	parameters := parse_object(read_resource(&s, "quesynth://parameters", d.server.path))
	testing.expect(t, strings.has_prefix(text_of(parameters["fields"]), "count="))
}

@(private = "file")
registry_index :: proc(id: string) -> int {
	descriptor, found := registry.registry_describe(id)
	assert(found)
	return descriptor.index
}

@(test)
test_a_stale_revision_is_refused_and_the_daemon_is_left_untouched :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	text, is_error := apply_one(&s, d.server.path, 0, "filter.cutoff", 10)
	testing.expect(t, !is_error, text)

	cutoff := stored(d, "filter.cutoff")
	code, message := tool_error(&s, "apply_parameters", `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":99},{"id":"filter.resonance","value":99}]}`, d.server.path)
	testing.expect_value(t, code, "revision_conflict")
	testing.expect_value(t, message, "current_revision=1")
	testing.expect_value(t, stored(d, "filter.cutoff"), cutoff)
	testing.expect_value(t, snapshot_of(d).revision, 1)
	testing.expect_value(t, standalone.param_ring_dropped(&d.live.ring), u32(0))

	// A request that names the revision it was shown goes through.
	text, is_error = apply_one(&s, d.server.path, 1, "filter.cutoff", 99)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":1,"revision":2}`)
}

@(test)
test_a_bad_member_changes_nothing_even_when_the_revision_matches :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	cutoff := stored(d, "filter.cutoff")
	cases := [][2]string {
		{`[{"id":"filter.cutoff","value":10},{"id":"no.such.parameter","value":1}]`, "unknown_parameter"},
		{`[{"id":"filter.cutoff","value":10},{"id":"filter.resonance","value":999999}]`, "out_of_range"},
		{`[{"id":"filter.cutoff","value":10},{"id":"filter.resonance","value":-1}]`, "out_of_range"},
		{`[]`, "invalid_payload"},
	}
	for c in cases {
		arguments := fmt.tprintf(`{{"expected_revision":0,"parameters":%s}}`, c[0])
		code, _ := tool_error(&s, "apply_parameters", arguments, d.server.path)
		testing.expectf(t, code == c[1], "%s -> %q", c[0], code)
		testing.expect_value(t, snapshot_of(d).revision, 0)
		testing.expect_value(t, stored(d, "filter.cutoff"), cutoff)
	}
	// None of them used up the revision.
	text, is_error := apply_one(&s, d.server.path, 0, "filter.cutoff", 10)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":1,"revision":1}`)
}

@(test)
test_duplicate_ids_apply_in_order_and_the_last_value_wins :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	text, is_error := call_tool(
		&s,
		"apply_parameters",
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":10},{"id":"filter.resonance","value":3},{"id":"filter.cutoff","value":20}]}`,
		d.server.path,
	)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":3,"revision":1}`)
	testing.expect_value(t, stored(d, "filter.cutoff"), 20)
	testing.expect_value(t, stored(d, "filter.resonance"), 3)
}

@(test)
test_an_edit_from_another_client_makes_the_revision_in_hand_stale :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	shown := revision_of(inspect(&s, d.server.path))

	// Another front-end, speaking QCP directly, moves the sound.
	payload, failure, _ := mcp.roundtrip(d.server.path, "1 1 parameter.set filter.cutoff 77")
	testing.expect_value(t, failure.code, "")
	testing.expect(t, strings.has_prefix(string(payload), "1 1 ok"), string(payload))
	delete(payload)

	code, message := tool_error(&s, "apply_parameters", fmt.tprintf(`{{"expected_revision":%d,"parameters":[{{"id":"filter.resonance","value":5}}]}}`, shown), d.server.path)
	testing.expect_value(t, code, "revision_conflict")
	testing.expect_value(t, message, fmt.tprintf("current_revision=%d", shown + 1))
	testing.expect_value(t, stored(d, "filter.cutoff"), 77)
}

Racer :: struct {
	path:      string,
	expected:  int,
	value:     int,
	go:        ^b32,
	ready:     ^int,
	succeeded: bool,
	conflict:  bool,
}

@(private = "file")
race :: proc(data: rawptr) {
	r := (^Racer)(data)
	s := ready()
	intrinsics.atomic_add(r.ready, 1)
	for !intrinsics.atomic_load(r.go) { time.sleep(100 * time.Microsecond) }
	text, is_error := apply_one(&s, r.path, r.expected, "filter.cutoff", r.value)
	r.succeeded = !is_error
	if is_error { r.conflict = text_of(parse_object(text)["code"]) == "revision_conflict" }
}

@(test)
test_clients_racing_on_one_revision_get_exactly_one_success :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	for round in 0 ..< 8 {
		shown := revision_of(inspect(&s, d.server.path))
		go: b32
		ready_count: int
		racers: [4]Racer
		threads: [4]^thread.Thread
		for i in 0 ..< len(racers) {
			racers[i] = Racer{path = d.server.path, expected = shown, value = 10 + i, go = &go, ready = &ready_count}
			threads[i] = thread.create_and_start_with_data(&racers[i], race)
		}
		for intrinsics.atomic_load(&ready_count) < len(racers) { time.sleep(time.Millisecond) }
		intrinsics.atomic_store(&go, true)
		for th in threads {
			thread.join(th)
			thread.destroy(th)
		}
		wins, conflicts := 0, 0
		winner := -1
		for r, i in racers {
			if r.succeeded { wins += 1; winner = i }
			if r.conflict { conflicts += 1 }
		}
		testing.expectf(t, wins == 1 && conflicts == 3, "round %d: %d wins, %d conflicts", round, wins, conflicts)
		testing.expect_value(t, snapshot_of(d).revision, shown + 1)
		if winner >= 0 { testing.expect_value(t, stored(d, "filter.cutoff"), 10 + winner) }
	}
}

@(test)
test_the_daemon_going_away_and_coming_back_needs_no_new_mcp_session :: proc(t: ^testing.T) {
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	testing.expect_value(t, revision_of(inspect(&s, d.server.path)), 0)

	standalone.control_server_stop(&d.server)
	code, _ := tool_error(&s, "inspect_synth", `{}`, d.server.path)
	testing.expect_value(t, code, "daemon_unavailable")
	code, _ = tool_error(&s, "apply_parameters", `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1}]}`, d.server.path)
	testing.expect_value(t, code, "daemon_unavailable")
	testing.expect_value(t, snapshot_of(d).revision, 0)

	testing.expect(t, standalone.control_server_start(&d.server))
	text, is_error := apply_one(&s, d.server.path, 0, "filter.cutoff", 1)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, revision_of(inspect(&s, d.server.path)), 1)
}

@(test)
test_a_batch_the_audio_side_does_not_reach_is_an_unknown_outcome_not_a_success :: proc(t: ^testing.T) {
	d := daemon_make(draining = false)
	defer daemon_free(d)
	s := ready()
	started := time.tick_now()
	code, message := tool_error(&s, "apply_parameters", `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1}]}`, d.server.path)
	elapsed := time.tick_since(started)
	testing.expect_value(t, code, "daemon_not_ready")
	testing.expect_value(t, message, "commit outcome unknown; inspect state before retrying")
	testing.expect(t, elapsed < 1500 * time.Millisecond, "the daemon answers within the MCP deadline")

	// Reads still work, and say the change has not happened yet.
	testing.expect_value(t, revision_of(inspect(&s, d.server.path)), 0)
	daemon_start_audio(d)
	for _ in 0 ..< 1000 {
		if snapshot_of(d).revision == 1 { break }
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, revision_of(inspect(&s, d.server.path)), 1)
	testing.expect_value(t, stored(d, "filter.cutoff"), 1)
}
