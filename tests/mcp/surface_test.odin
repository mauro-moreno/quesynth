#+build linux
package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import standalone "../../hosts/standalone"
import "../../hosts/standalone/mcp"
import "../../src/patch"
import "../../src/registry"

// Every tool against the real control server and the real command handler, with
// the bank, archive, volume, MIDI queue and MIDI selection a running daemon
// has (daemon_test.odin). The expected replies are the wire format as the
// protocol documents it, written out here by hand; the expected effects are
// read from the engine's published state, from files this test wrote or reads
// back, and from the queue the daemon pushed into -- never from the MCP's own
// answer.
//
// Most tests have no audio thread and stand in for it by hand (render), so a
// reply that carries "the revision when it was queued" can be named exactly.

ARCHIVE :: #directory + "../zip/fixtures/nested.zip"

@(private = "file")
Reply :: struct {
	fields: string,
	lines:  []string,
}

// The tool succeeds; what the daemon said, split as the MCP returns it.
@(private = "file")
ok :: proc(t: ^testing.T, s: ^mcp.Session, d: ^Daemon, tool: string, arguments := `{}`, loc := #caller_location) -> Reply {
	text, is_error := call_tool(s, tool, arguments, d.server.path)
	if !testing.expectf(t, !is_error, "%s %s -> %s", tool, arguments, text, loc = loc) { return {} }
	body := parse_object(text)
	array, _ := body["lines"].(json.Array)
	lines := make([]string, len(array), context.temp_allocator)
	for line, i in array { lines[i] = text_of(line) }
	return {text_of(body["fields"]), lines}
}

// The daemon refuses; its code and message as they came.
@(private = "file")
refused :: proc(t: ^testing.T, s: ^mcp.Session, d: ^Daemon, tool, arguments, code, message: string, loc := #caller_location) {
	got_code, got_message := tool_error(s, tool, arguments, d.server.path)
	testing.expectf(t, got_code == code, "%s %s: code %q, want %q (%q)", tool, arguments, got_code, code, got_message, loc = loc)
	testing.expect_value(t, got_message, message, loc = loc)
}

@(private = "file")
expect_reply :: proc(t: ^testing.T, got: Reply, fields: string, lines: []string, loc := #caller_location) {
	testing.expect_value(t, got.fields, fields, loc = loc)
	if !testing.expectf(t, len(got.lines) == len(lines), "%d lines, want %d: %v", len(got.lines), len(lines), got.lines, loc = loc) { return }
	for line, i in lines { testing.expect_value(t, got.lines[i], line, loc = loc) }
}

// The audio thread's part, by hand: apply what the control thread queued.
@(private = "file")
render :: proc(d: ^Daemon) {
	standalone.live_render(d.live, nil, 0, 2)
}

@(private = "file")
index_of :: proc(id: string) -> int {
	descriptor, found := registry.registry_describe(id)
	assert(found)
	return descriptor.index
}

@(private = "file")
scratch_dir :: proc(tag: string) -> string {
	root := fmt.tprintf("/tmp/qm-surface-%s-%d", tag, posix.getpid())
	os.remove_all(root)
	assert(os.make_directory_all(root) == nil)
	return root
}

@(test)
test_the_read_tools_report_a_fresh_daemon_in_the_wire_format_of_the_protocol :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()

	expect_reply(t, ok(t, &s, d, "daemon_status"), "state=running proto=1 revision=0", {})

	info := ok(t, &s, d, "daemon_info")
	testing.expect_value(t, len(info.lines), 0)
	// The uptime is the one field that is not fixed.
	prefix := "state=running proto=1 revision=0 control_dropped=0 midi_dropped=0 sample_rate=48000 buffer=512 voices=0 max_voices=16 uptime="
	suffix := " volume=1000 backend=Test Backend"
	if testing.expectf(t, strings.has_prefix(info.fields, prefix) && strings.has_suffix(info.fields, suffix), "%q", info.fields) {
		uptime := info.fields[len(prefix):len(info.fields) - len(suffix)]
		testing.expectf(t, uptime != "" && strings.trim_left(uptime, "0123456789") == "", "uptime %q", uptime)
	}

	list := registry.registry_list()
	parameters := ok(t, &s, d, "parameter_list")
	testing.expect_value(t, parameters.fields, fmt.tprintf("count=%d", len(list)))
	if testing.expect_value(t, len(parameters.lines), len(list)) {
		for descriptor, i in list {
			lo, hi, _ := registry.registry_stored_range(descriptor)
			want := fmt.tprintf(
				"id=%s group=%s index=%d min=%d max=%d default=%d label=%s",
				descriptor.id,
				descriptor.group,
				descriptor.index,
				lo,
				hi,
				registry.registry_default(descriptor),
				descriptor.label,
			)
			testing.expect_value(t, parameters.lines[i], want)
		}
	}

	cutoff := patch.PARAMETERS[index_of("filter.cutoff")].default
	expect_reply(t, ok(t, &s, d, "parameter_get", `{"id":"filter.cutoff"}`), fmt.tprintf("value=%d revision=0", cutoff), {})
	refused(t, &s, d, "parameter_get", `{"id":"no.such.parameter"}`, "unknown_parameter", "no such parameter")

	snapshot := ok(t, &s, d, "state_snapshot")
	testing.expect_value(t, snapshot.fields, fmt.tprintf("revision=0 sample_rate=48000 buffer=512 count=%d", len(list)))
	if testing.expect_value(t, len(snapshot.lines), len(list)) {
		for descriptor, i in list {
			testing.expect_value(t, snapshot.lines[i], fmt.tprintf("id=%s value=%d", descriptor.id, patch.PARAMETERS[descriptor.index].default))
		}
	}

	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=", "name="},
	)

	listing := ok(t, &s, d, "bank_list")
	reference := new(patch.Slots)
	defer free(reference)
	patch.slots_load_factory(reference)
	filled := 0
	for f in reference.filled { if f { filled += 1 } }
	testing.expect_value(t, listing.fields, fmt.tprintf("label=Factory count=%d slots=128", filled))
	if testing.expect_value(t, len(listing.lines), 128) {
		for i in 0 ..< 128 {
			name := reference.filled[i] ? strings.clone(patch.slots_name(reference, i), context.temp_allocator) : "Init"
			name, _ = strings.replace_all(name, " ", "_", context.temp_allocator)
			testing.expect_value(t, listing.lines[i], fmt.tprintf("slot=%d filled=%d name=%s", i, reference.filled[i] ? 1 : 0, name))
		}
	}

	expect_reply(t, ok(t, &s, d, "archive_current"), "open=0 banks=0 bank=-1 patches=0 archive_rev=0", {"path=", "bank_name="})
	expect_reply(t, ok(t, &s, d, "midi_current"), "selected=all midi_rev=0", {"name=All inputs"})
	expect_reply(t, ok(t, &s, d, "midi_list"), "count=2 selected=all midi_rev=0", {"id=hw:1,0 name=Test Keys", "id=hw:2,0 name=Second  Pad"})
}

@(test)
test_parameter_set_and_unguarded_set_many_reply_when_queued_and_change_the_engine_when_applied :: proc(t: ^testing.T) {
	d := daemon_make(draining = false, full = true)
	defer daemon_free(d)
	s := ready()

	expect_reply(t, ok(t, &s, d, "parameter_set", `{"id":"filter.cutoff","value":10}`), "value=10 revision=0", {})
	// Acknowledged, not yet applied: the audio thread has not run.
	testing.expect_value(t, snapshot_of(d).revision, 0)
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 1)
	testing.expect_value(t, stored(d, "filter.cutoff"), 10)

	expect_reply(
		t,
		ok(t, &s, d, "parameter_set_many", `{"parameters":[{"id":"filter.cutoff","value":20},{"id":"filter.resonance","value":30},{"id":"filter.cutoff","value":40}]}`),
		"count=3 revision=1",
		{},
	)
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 2)
	testing.expect_value(t, stored(d, "filter.cutoff"), 40)
	testing.expect_value(t, stored(d, "filter.resonance"), 30)

	// The daemon's own judgement of ids and ranges, and nothing queued by it.
	refused(t, &s, d, "parameter_set", `{"id":"no.such.parameter","value":1}`, "unknown_parameter", "no such parameter")
	refused(t, &s, d, "parameter_set", `{"id":"filter.cutoff","value":999999}`, "out_of_range", "value out of range")
	refused(t, &s, d, "parameter_set", `{"id":"filter.cutoff","value":-1}`, "out_of_range", "value out of range")
	refused(t, &s, d, "parameter_set_many", `{"parameters":[{"id":"filter.cutoff","value":5},{"id":"no.such.parameter","value":1}]}`, "unknown_parameter", "no such parameter")
	refused(t, &s, d, "parameter_set_many", `{"parameters":[{"id":"filter.cutoff","value":5},{"id":"filter.resonance","value":999999}]}`, "out_of_range", "value out of range")
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 2)
	testing.expect_value(t, stored(d, "filter.cutoff"), 40)
}

@(test)
test_parameter_set_many_with_the_revision_is_applied_or_refused_by_the_audio_thread :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()

	expect_reply(t, ok(t, &s, d, "parameter_set_many", `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":10},{"id":"filter.resonance","value":20}]}`), "count=2 revision=1", {})
	testing.expect_value(t, stored(d, "filter.cutoff"), 10)
	testing.expect_value(t, stored(d, "filter.resonance"), 20)
	// Stale: the revision moved to 1.
	refused(t, &s, d, "parameter_set_many", `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":99}]}`, "revision_conflict", "current_revision=1")
	testing.expect_value(t, stored(d, "filter.cutoff"), 10)
	expect_reply(t, ok(t, &s, d, "parameter_set_many", `{"expected_revision":1,"parameters":[{"id":"filter.cutoff","value":99}]}`), "count=1 revision=2", {})
	testing.expect_value(t, stored(d, "filter.cutoff"), 99)
	// A bad member under a good revision changes nothing and costs no revision.
	refused(t, &s, d, "parameter_set_many", `{"expected_revision":2,"parameters":[{"id":"filter.cutoff","value":1},{"id":"no.such.parameter","value":1}]}`, "unknown_parameter", "no such parameter")
	expect_reply(t, ok(t, &s, d, "daemon_status"), "state=running proto=1 revision=2", {})
}

@(test)
test_a_patch_is_saved_loaded_applied_and_forgotten_through_the_slots_of_the_bank :: proc(t: ^testing.T) {
	d := daemon_make(draining = false, full = true)
	defer daemon_free(d)
	s := ready()
	cutoff := index_of("filter.cutoff")

	ok(t, &s, d, "parameter_set", `{"id":"filter.cutoff","value":10}`)
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 1)

	// The spaces of a name fold to underscores on the one line the daemon
	// replies on, and stay spaces in the record patch_current has for it.
	expect_reply(t, ok(t, &s, d, "patch_save", `{"slot":3,"name":"My  Lead"}`), "slot=3 name=My__Lead bank_rev=1", {})
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=3 bank_rev=1 revision=1 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=Factory", "name=My  Lead"},
	)
	listing := ok(t, &s, d, "bank_list")
	if testing.expect_value(t, len(listing.lines), 128) { testing.expect_value(t, listing.lines[3], "slot=3 filled=1 name=My__Lead") }
	// The slot holds the sound as it was when it was saved.
	testing.expect_value(t, d.bank.values[3][cutoff], 10)

	ok(t, &s, d, "parameter_set", `{"id":"filter.cutoff","value":20}`)
	render(d)
	testing.expect_value(t, stored(d, "filter.cutoff"), 20)

	expect_reply(t, ok(t, &s, d, "patch_load", `{"slot":3}`), fmt.tprintf("slot=3 name=My__Lead count=%d revision=2", patch.PARAMETER_COUNT), {})
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 3)
	testing.expect_value(t, stored(d, "filter.cutoff"), 10)

	// A patch sent by value replaces the sound and leaves the name alone.
	expect_reply(t, ok(t, &s, d, "patch_apply", `{"parameters":[{"id":"filter.cutoff","value":44}]}`), "count=1 revision=3", {})
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 4)
	testing.expect_value(t, stored(d, "filter.cutoff"), 44)
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=3 bank_rev=1 revision=4 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=Factory", "name=My  Lead"},
	)

	expect_reply(t, ok(t, &s, d, "patch_clear"), "", {})
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=1 revision=4 source=none archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=", "name="},
	)
	// Forgetting a name changes no sound.
	testing.expect_value(t, stored(d, "filter.cutoff"), 44)

	refused(t, &s, d, "patch_apply", `{"parameters":[{"id":"filter.cutoff","value":1},{"id":"no.such.parameter","value":1}]}`, "unknown_parameter", "no such parameter")
	refused(t, &s, d, "patch_apply", `{"parameters":[{"id":"filter.cutoff","value":999999}]}`, "out_of_range", "value out of range")
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 4)

	// With no name the slot keeps the one it has: an empty one is Init.
	empty := -1
	for i in 0 ..< 128 { if !d.bank.filled[i] { empty = i; break } }
	if empty >= 0 {
		expect_reply(t, ok(t, &s, d, "patch_save", fmt.tprintf(`{{"slot":%d}}`, empty)), fmt.tprintf("slot=%d name=Init bank_rev=2", empty), {})
	}
}

@(test)
test_patch_and_bank_files_are_read_and_written_by_the_daemon_at_the_paths_given :: proc(t: ^testing.T) {
	root := scratch_dir("files")
	defer os.remove_all(root)
	d := daemon_make(draining = false, full = true)
	defer daemon_free(d)
	s := ready()

	// A patch file in a directory and under a name that have spaces in them.
	patch_dir := fmt.tprintf("%s/patch dir", root)
	assert(os.make_directory_all(patch_dir) == nil)
	patch_path := fmt.tprintf("%s/lead pad.sy1", patch_dir)
	assert(os.write_entire_file_from_string(patch_path, "color=default\r\nver=113\r\n0,3\r\n") == nil)
	expect_reply(t, ok(t, &s, d, "patch_load_file", fmt.tprintf(`{{"path":%s}}`, quote_json(patch_path))), "count=1 revision=0", {"name="})
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 1)
	testing.expect_value(t, snapshot_of(d).values[0], 3)
	// Named by the file, as the file has no name of its own.
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=0 revision=1 source=file archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=file", "name=lead pad.sy1"},
	)
	refused(t, &s, d, "patch_load_file", fmt.tprintf(`{{"path":"%s/missing.sy1"}}`, root), "invalid_payload", "cannot read file")
	not_a_patch := fmt.tprintf("%s/not a patch.sy1", root)
	assert(os.write_entire_file_from_string(not_a_patch, "\x00\x01 this is not a patch") == nil)
	refused(t, &s, d, "patch_load_file", fmt.tprintf(`{{"path":%s}}`, quote_json(not_a_patch)), "invalid_payload", "cannot parse patch")

	// The bank written is the bank the daemon holds, as a JSON file.
	bank_dir := fmt.tprintf("%s/bank dir", root)
	assert(os.make_directory_all(bank_dir) == nil)
	bank_path := fmt.tprintf("%s/my bank.json", bank_dir)
	written := ok(t, &s, d, "bank_write", fmt.tprintf(`{{"path":%s}}`, quote_json(bank_path)))
	data, read_err := os.read_entire_file(bank_path, context.temp_allocator)
	if testing.expect(t, read_err == nil, "bank_write must write the file") {
		testing.expect_value(t, written.fields, fmt.tprintf("bytes=%d", len(data)))
		parsed, parse_err := patch.parse_bank_json(data, context.temp_allocator)
		testing.expect_value(t, parse_err, patch.Json_Error.None)
		testing.expect_value(t, parsed.name, "Factory")
		testing.expect_value(t, len(parsed.patches) > 0, true)
	}
	refused(t, &s, d, "bank_write", fmt.tprintf(`{{"path":"%s/no such dir/bank.json"}}`, root), "internal_error", "cannot write file")

	// A bank of two slots, one filled, written by the patch package.
	first := patch.init_patch()
	first.name = "Mini One"
	first.values[index_of("filter.cutoff")] = 33
	mini := patch.write_bank_json("Mini Bank", {first, patch.init_patch()}, {true, false}, context.temp_allocator)
	mini_path := fmt.tprintf("%s/mini bank.json", root)
	assert(os.write_entire_file_from_string(mini_path, mini) == nil)
	expect_reply(t, ok(t, &s, d, "bank_load_file", fmt.tprintf(`{{"path":%s}}`, quote_json(mini_path))), "label=Mini_Bank count=1 bank_rev=1", {})
	refused(t, &s, d, "bank_load_file", fmt.tprintf(`{{"path":"%s/missing.json"}}`, root), "invalid_payload", "cannot read or parse bank")
	refused(t, &s, d, "bank_load_file", fmt.tprintf(`{{"path":%s}}`, quote_json(patch_path)), "invalid_payload", "cannot read or parse bank")
	listing := ok(t, &s, d, "bank_list")
	testing.expect_value(t, listing.fields, "label=Mini_Bank count=1 slots=128")
	if testing.expect_value(t, len(listing.lines), 128) {
		testing.expect_value(t, listing.lines[0], "slot=0 filled=1 name=Mini_One")
		testing.expect_value(t, listing.lines[1], "slot=1 filled=0 name=Init")
	}
	// Loading a bank does not touch the sound; the sound's slot is forgotten.
	testing.expect_value(t, snapshot_of(d).revision, 1)
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=1 revision=1 source=file archive_rev=0 archive_bank=-1 archive_patch=-1",
		{"bank=file", "name=lead pad.sy1"},
	)
	refused(t, &s, d, "patch_load", `{"slot":1}`, "unknown_parameter", "slot is empty")
	expect_reply(t, ok(t, &s, d, "patch_load", `{"slot":0}`), fmt.tprintf("slot=0 name=Mini_One count=%d revision=1", patch.PARAMETER_COUNT), {})
	render(d)
	testing.expect_value(t, stored(d, "filter.cutoff"), 33)
}

// The text of a JSON string, for a path built with fmt.
@(private = "file")
quote_json :: proc(text: string) -> string {
	data, err := json.unparse(json.String(text), allocator = context.temp_allocator)
	assert(err == nil)
	return data
}

// bank_keep writes where the daemon is configured to, so it runs with
// XDG_CONFIG_HOME pointed at a scratch directory and restores it after. The
// environment is the whole process's, and this is the one test here that sets
// it.
@(test)
test_bank_keep_writes_the_daemons_own_bank_file_and_takes_no_path :: proc(t: ^testing.T) {
	root := scratch_dir("keep")
	defer os.remove_all(root)
	d := daemon_make(draining = false, full = true)
	defer daemon_free(d)
	s := ready()

	old, had := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	defer { if had { os.set_env("XDG_CONFIG_HOME", old) } else { os.unset_env("XDG_CONFIG_HOME") } }
	config := fmt.tprintf("%s/config home", root)
	assert(os.set_env("XDG_CONFIG_HOME", config) == nil)
	path := fmt.tprintf("%s/quesynth/bank.json", config)

	ok(t, &s, d, "patch_save", `{"slot":9,"name":"Kept Sound"}`)
	kept := ok(t, &s, d, "bank_keep")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if testing.expect(t, err == nil, "bank_keep must write $XDG_CONFIG_HOME/quesynth/bank.json") {
		testing.expect_value(t, kept.fields, fmt.tprintf("bytes=%d path=%s", len(data), path))
		parsed, parse_err := patch.parse_bank_json(data, context.temp_allocator)
		testing.expect_value(t, parse_err, patch.Json_Error.None)
		if testing.expect(t, len(parsed.patches) > 9) { testing.expect_value(t, parsed.patches[9].name, "Kept Sound") }
	}
	testing.expect_value(t, len(kept.lines), 0)
	// It takes nothing to say where: a path is not an argument.
	text, is_error := call_tool(&s, "bank_keep", `{"path":"/tmp/elsewhere.json"}`, d.server.path)
	testing.expect(t, is_error, text)
	testing.expect(t, !os.exists("/tmp/elsewhere.json"))
}

@(test)
test_the_archive_is_opened_browsed_loaded_adopted_and_closed_through_its_tools :: proc(t: ^testing.T) {
	d := daemon_make(draining = false, full = true)
	defer daemon_free(d)
	s := ready()
	archive := quote_json(ARCHIVE)

	refused(t, &s, d, "archive_banks", `{}`, "daemon_not_ready", "no archive open")
	refused(t, &s, d, "archive_bank", `{"index":0}`, "daemon_not_ready", "no archive open")
	refused(t, &s, d, "archive_patches", `{}`, "daemon_not_ready", "no bank open")
	refused(t, &s, d, "archive_load", `{"index":0}`, "daemon_not_ready", "no bank open")
	// Nothing open and nothing remembered: an empty path has nothing to mean.
	refused(t, &s, d, "archive_open", `{}`, "invalid_payload", "open needs a path")
	refused(t, &s, d, "archive_open", `{"path":""}`, "invalid_payload", "open needs a path")
	refused(t, &s, d, "archive_open", `{"path":"/tmp/qm-no-such-archive.zip"}`, "invalid_payload", "cannot open archive")
	expect_reply(t, ok(t, &s, d, "archive_close"), "archive_rev=0", {})

	expect_reply(t, ok(t, &s, d, "archive_open", fmt.tprintf(`{{"path":%s}}`, archive)), "banks=1 archive_rev=1", {})
	expect_reply(t, ok(t, &s, d, "archive_current"), "open=1 banks=1 bank=-1 patches=0 archive_rev=1", {fmt.tprintf("path=%s", ARCHIVE), "bank_name="})
	expect_reply(t, ok(t, &s, d, "archive_banks"), "total=1 archive_rev=1", {"bank=0 name=bankA.zip"})
	expect_reply(t, ok(t, &s, d, "archive_banks", `{"offset":5}`), "total=1 archive_rev=1", {})
	expect_reply(t, ok(t, &s, d, "archive_banks", `{"count":0}`), "total=1 archive_rev=1", {})

	expect_reply(t, ok(t, &s, d, "archive_bank", `{"index":0}`), "patches=2 bank=0 archive_rev=2", {})
	// Asking for the bank already open is not a change.
	expect_reply(t, ok(t, &s, d, "archive_bank", `{"index":0}`), "patches=2 bank=0 archive_rev=2", {})
	refused(t, &s, d, "archive_bank", `{"index":7}`, "invalid_payload", "cannot open that bank")
	expect_reply(t, ok(t, &s, d, "archive_current"), "open=1 banks=1 bank=0 patches=2 archive_rev=2", {fmt.tprintf("path=%s", ARCHIVE), "bank_name=bankA.zip"})
	both := []string{"patch=0 name=Test Patch One", "patch=1 name=Test Patch Two"}
	expect_reply(t, ok(t, &s, d, "archive_patches"), "total=2 bank=0 archive_rev=2", both)
	expect_reply(t, ok(t, &s, d, "archive_patches", `{"offset":1,"count":1}`), "total=2 bank=0 archive_rev=2", both[1:])
	expect_reply(t, ok(t, &s, d, "archive_patches", `{"count":1}`), "total=2 bank=0 archive_rev=2", both[:1])

	// Loading is the one of these that changes the sound.
	testing.expect_value(t, snapshot_of(d).revision, 0)
	loaded := ok(t, &s, d, "archive_load", `{"index":1}`)
	testing.expectf(t, strings.has_prefix(loaded.fields, "count=") && strings.has_suffix(loaded.fields, " bank=0 patch=1"), "%q", loaded.fields)
	render(d)
	testing.expect_value(t, snapshot_of(d).revision, 1)
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=0 revision=1 source=archive archive_rev=2 archive_bank=0 archive_patch=1",
		{"bank=bankA.zip", "name=Test Patch Two"},
	)
	refused(t, &s, d, "archive_load", `{"index":9}`, "invalid_payload", "patch index out of range")
	refused(t, &s, d, "archive_load", `{"index":0,"bank":3}`, "invalid_payload", "cannot open that bank")
	loaded = ok(t, &s, d, "archive_load", `{"index":0,"bank":0}`)
	testing.expectf(t, strings.has_suffix(loaded.fields, " bank=0 patch=0"), "%q", loaded.fields)
	render(d)

	// An archive is already open, so nothing is adopted.
	expect_reply(t, ok(t, &s, d, "archive_adopt", fmt.tprintf(`{{"path":%s}}`, archive)), "adopted=0 open=1 banks=1 archive_rev=2", {})
	// Omitting the path opens the remembered archive again, which closes its
	// bank.
	expect_reply(t, ok(t, &s, d, "archive_open"), "banks=1 archive_rev=3", {})
	expect_reply(t, ok(t, &s, d, "archive_current"), "open=1 banks=1 bank=-1 patches=0 archive_rev=3", {fmt.tprintf("path=%s", ARCHIVE), "bank_name="})

	// Closing forgets the archive and the path, and the sound's archive
	// indices.
	expect_reply(t, ok(t, &s, d, "archive_close"), "archive_rev=4", {})
	expect_reply(t, ok(t, &s, d, "archive_current"), "open=0 banks=0 bank=-1 patches=0 archive_rev=4", {"path=", "bank_name="})
	expect_reply(
		t,
		ok(t, &s, d, "patch_current"),
		"slot=-1 bank_rev=0 revision=2 source=archive archive_rev=4 archive_bank=-1 archive_patch=-1",
		{"bank=bankA.zip", "name=Test Patch One"},
	)
	refused(t, &s, d, "archive_open", `{}`, "invalid_payload", "open needs a path")

	// With none open and none remembered, a path offered is taken.
	refused(t, &s, d, "archive_adopt", `{"path":"/tmp/qm-no-such-archive.zip"}`, "invalid_payload", "cannot open archive")
	expect_reply(t, ok(t, &s, d, "archive_adopt", fmt.tprintf(`{{"path":%s}}`, archive)), "adopted=1 open=1 banks=1 archive_rev=5", {})
}

@(test)
test_midi_messages_go_into_the_daemons_queue_and_the_selection_is_one_for_every_client :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()

	expect_reply(t, ok(t, &s, d, "midi_send", `{"status":144,"data1":60,"data2":100}`), "", {})
	expect_reply(t, ok(t, &s, d, "midi_send", `{"status":128,"data1":60,"data2":0}`), "", {})
	// The documented layout of a message in the queue: status, data1 << 8,
	// data2 << 16.
	message, popped := standalone.midi_queue_pop(&d.midi_queue)
	testing.expect(t, popped)
	testing.expect_value(t, message, u32(144) | u32(60) << 8 | u32(100) << 16)
	message, popped = standalone.midi_queue_pop(&d.midi_queue)
	testing.expect(t, popped)
	testing.expect_value(t, message, u32(128) | u32(60) << 8)
	_, popped = standalone.midi_queue_pop(&d.midi_queue)
	testing.expect(t, !popped, "a message was queued that was not sent")

	expect_reply(t, ok(t, &s, d, "midi_select", `{"input":"hw:2,0"}`), "selected=hw:2,0 midi_rev=1", {})
	expect_reply(t, ok(t, &s, d, "midi_current"), "selected=hw:2,0 midi_rev=1", {"name=Second  Pad"})
	expect_reply(t, ok(t, &s, d, "midi_list"), "count=2 selected=hw:2,0 midi_rev=1", {"id=hw:1,0 name=Test Keys", "id=hw:2,0 name=Second  Pad"})
	// The choice already in force is no change.
	expect_reply(t, ok(t, &s, d, "midi_select", `{"input":"hw:2,0"}`), "selected=hw:2,0 midi_rev=1", {})
	refused(t, &s, d, "midi_select", `{"input":"hw:9,9"}`, "invalid_payload", "no such midi input")
	expect_reply(t, ok(t, &s, d, "midi_select", `{"input":"none"}`), "selected=none midi_rev=2", {})
	expect_reply(t, ok(t, &s, d, "midi_current"), "selected=none midi_rev=2", {"name=None"})
	// None stops the hardware, not the messages sent here.
	expect_reply(t, ok(t, &s, d, "midi_send", `{"status":144,"data1":61,"data2":90}`), "", {})
	message, popped = standalone.midi_queue_pop(&d.midi_queue)
	testing.expect(t, popped)
	testing.expect_value(t, message, u32(144) | u32(61) << 8 | u32(90) << 16)
	expect_reply(t, ok(t, &s, d, "midi_select", `{"input":"all"}`), "selected=all midi_rev=3", {})
	expect_reply(t, ok(t, &s, d, "midi_current"), "selected=all midi_rev=3", {"name=All inputs"})
}

@(test)
test_volume_is_set_for_the_audio_side_and_reported_by_daemon_info_and_moves_no_revision :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()

	testing.expect_value(t, d.live.volume.milli, u32(standalone.VOLUME_UNITY))
	expect_reply(t, ok(t, &s, d, "volume", `{"milli":0}`), "volume=0", {})
	testing.expect_value(t, d.live.volume.milli, u32(0))
	info := ok(t, &s, d, "daemon_info")
	testing.expectf(t, strings.contains(info.fields, " volume=0 backend=Test Backend"), "%q", info.fields)
	expect_reply(t, ok(t, &s, d, "volume", `{"milli":250}`), "volume=250", {})
	testing.expect_value(t, d.live.volume.milli, u32(250))
	expect_reply(t, ok(t, &s, d, "volume", `{"milli":1000}`), "volume=1000", {})
	testing.expect_value(t, d.live.volume.milli, u32(1000))
	// Not a patch parameter: no revision, and the snapshot of the sound is the
	// one it was before any of this.
	expect_reply(t, ok(t, &s, d, "daemon_status"), "state=running proto=1 revision=0", {})
	after := ok(t, &s, d, "state_snapshot")
	testing.expect_value(t, after.fields, fmt.tprintf("revision=0 sample_rate=48000 buffer=512 count=%d", len(registry.registry_list())))
	for descriptor, i in registry.registry_list() {
		testing.expect_value(t, after.lines[i], fmt.tprintf("id=%s value=%d", descriptor.id, patch.PARAMETERS[descriptor.index].default))
	}
}

@(test)
test_daemon_shutdown_asks_the_daemon_to_stop_and_the_reply_still_comes :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()
	// This raises the process's shutdown flag. Nothing in this test binary
	// reads it, and it cannot be lowered again.
	expect_reply(t, ok(t, &s, d, "daemon_shutdown"), "", {})
	testing.expect(t, standalone.shutdown_requested(), "daemon.shutdown must raise the flag the main thread waits on")
}

@(test)
test_a_daemon_without_what_a_command_needs_answers_for_itself_and_the_answer_passes_through :: proc(t: ^testing.T) {
	// A bare handler: no bank, archive, volume, MIDI queue or selection.
	d := daemon_make()
	defer daemon_free(d)
	s := ready()
	cases := []struct {
		tool:      string,
		arguments: string,
		code:      string,
		message:   string,
	} {
		{"bank_list", `{}`, "daemon_not_ready", "no bank"},
		{"patch_load", `{"slot":0}`, "daemon_not_ready", "no bank"},
		{"patch_save", `{"slot":0}`, "daemon_not_ready", "no bank"},
		{"bank_write", `{"path":"/tmp/qm-never.json"}`, "daemon_not_ready", "no bank"},
		{"bank_load_file", `{"path":"/tmp/qm-never.json"}`, "daemon_not_ready", "no bank"},
		{"bank_keep", `{}`, "daemon_not_ready", "no bank"},
		{"archive_current", `{}`, "daemon_not_ready", "no archive support"},
		{"archive_open", `{"path":"/tmp/qm-never.zip"}`, "daemon_not_ready", "no archive support"},
		{"archive_adopt", `{"path":"/tmp/qm-never.zip"}`, "daemon_not_ready", "no archive support"},
		{"archive_banks", `{}`, "daemon_not_ready", "no archive open"},
		{"midi_list", `{}`, "daemon_not_ready", "no midi input"},
		{"midi_select", `{"input":"all"}`, "daemon_not_ready", "no midi input"},
		{"midi_current", `{}`, "daemon_not_ready", "no midi input"},
		{"volume", `{"milli":500}`, "daemon_not_ready", "no audio"},
		// The daemon's own word for a queue it does not have.
		{"midi_send", `{"status":144,"data1":60,"data2":100}`, "invalid_payload", "midi needs status data1 data2"},
		{"parameter_get", `{"id":"no.such.parameter"}`, "unknown_parameter", "no such parameter"},
	}
	for c in cases { refused(t, &s, d, c.tool, c.arguments, c.code, c.message) }
	// What it can report it does: no metrics, no MIDI queue, no volume.
	expect_reply(t, ok(t, &s, d, "daemon_info"), "state=running proto=1 revision=0 control_dropped=0", {})
	expect_reply(t, ok(t, &s, d, "patch_current"), "slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1", {"bank=", "name="})
}

// The mcp package may not import the daemon, so the three limits it checks
// for the daemon are written again there. These fail the build if they move
// apart from the daemon's own...
#assert(mcp.MAX_PAIRS == standalone.TXN_STAGING_MAX)
#assert(mcp.SLOT_COUNT == patch.FACTORY_SLOTS)
#assert(mcp.VOLUME_MAX == standalone.VOLUME_UNITY)

@(private = "file")
raw :: proc(d: ^Daemon, line: string) -> string {
	payload, failure, _ := mcp.roundtrip(d.server.path, line)
	assert(failure.code == "", failure.message)
	defer delete(payload)
	return strings.clone(string(payload), context.temp_allocator)
}

// ...and this puts each limit to the real daemon: it takes what the MCP lets
// through at the limit and refuses one past it, so a limit that is too tight
// or too loose on either side shows.
@(test)
test_the_limits_checked_before_the_daemon_are_the_limits_the_daemon_enforces :: proc(t: ^testing.T) {
	d := daemon_make(full = true)
	defer daemon_free(d)
	s := ready()
	// The most pairs: 128 go through the MCP, 129 are the daemon's refusal.
	expect_reply(t, ok(t, &s, d, "parameter_set_many", pairs_json_of(mcp.MAX_PAIRS)), fmt.tprintf("count=%d revision=0", mcp.MAX_PAIRS), {})
	testing.expect_value(t, raw(d, fmt.tprintf("1 1 parameter.set_many%s", batch(mcp.MAX_PAIRS + 1))), "1 1 err transaction_failed too many parameters in one transaction")
	expect_refused(t, "parameter_set_many", {pairs_json_of(mcp.MAX_PAIRS + 1)})
	expect_refused(t, "patch_apply", {pairs_json_of(mcp.MAX_PAIRS + 1)})

	// The last slot, and the one past it.
	last := fmt.tprintf("%d", mcp.SLOT_COUNT - 1)
	testing.expect(t, strings.has_prefix(raw(d, fmt.tprintf("1 2 patch.save %s", last)), "1 2 ok"))
	testing.expect_value(t, raw(d, fmt.tprintf("1 3 patch.save %d", mcp.SLOT_COUNT)), "1 3 err invalid_payload slot out of range")
	expect_refused(t, "patch_save", {fmt.tprintf(`{{"slot":%d}}`, mcp.SLOT_COUNT)})
	testing.expect(t, strings.has_prefix(raw(d, fmt.tprintf("1 4 patch.load %s", last)), "1 4 ok"))
	testing.expect_value(t, raw(d, fmt.tprintf("1 5 patch.load %d", mcp.SLOT_COUNT)), "1 5 err invalid_payload slot out of range")
	expect_refused(t, "patch_load", {fmt.tprintf(`{{"slot":%d}}`, mcp.SLOT_COUNT)})

	// Full volume, and one thousandth past it.
	testing.expect_value(t, raw(d, fmt.tprintf("1 6 volume %d", mcp.VOLUME_MAX)), "1 6 ok volume=1000")
	testing.expect_value(t, raw(d, fmt.tprintf("1 7 volume %d", mcp.VOLUME_MAX + 1)), "1 7 err invalid_payload volume needs 0..1000")
	expect_refused(t, "volume", {fmt.tprintf(`{{"milli":%d}}`, mcp.VOLUME_MAX + 1)})

	// The bytes of a MIDI message.
	testing.expect(t, strings.has_prefix(raw(d, "1 8 midi 255 127 127"), "1 8 ok"))
	testing.expect_value(t, raw(d, "1 9 midi 256 0 0"), "1 9 err invalid_payload invalid midi bytes")
	testing.expect_value(t, raw(d, "1 10 midi 0 128 0"), "1 10 err invalid_payload invalid midi bytes")
	expect_refused(t, "midi_send", {`{"status":256,"data1":0,"data2":0}`, `{"status":0,"data1":128,"data2":0}`, `{"status":0,"data1":0,"data2":128}`})
}

@(private = "file")
batch :: proc(count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< count { strings.write_string(&b, " filter.cutoff 1") }
	return strings.to_string(b)
}

@(private = "file")
pairs_json_of :: proc(count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"parameters":[`)
	for i in 0 ..< count {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, `{"id":"filter.cutoff","value":1}`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}
