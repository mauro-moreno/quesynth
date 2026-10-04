#+build linux
package standalone_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "../../src/engine"
import patch "../../src/patch"
import "../../src/registry"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// A daemon started with --bank F keeps its bank in F: every patch.save writes
// the whole bank there, and bank.keep does too, so the next start with the same
// --bank finds the saved slot. It used to write bank.json whatever the start
// had loaded: the save was not in F at the next --bank F start, and bank.json
// was replaced by F's bank, losing what it held before. F is a file somebody
// named, so the daemon replaces it only if it loaded it, has written it itself
// since, or finds nothing in it.
//
// Each daemon here starts through daemon_start_bank, as run_daemon starts one,
// and is wired with what that returns, as run_daemon wires it minus the device.
// Its bank.json is a scratch path given to that start, never the user's. What
// is expected comes from what the tests wrote, and a kept file is read back
// through load_bank_file, the daemon's own start-up reader.

@(private = "file")
target_dir_count: u32

@(private = "file")
target_dir_make :: proc() -> string {
	dir := fmt.aprintf("/tmp/quesynth-target-%d-%d", posix.getpid(), intrinsics.atomic_add(&target_dir_count, 1))
	os.remove_all(dir)
	assert(os.make_directory_all(dir) == nil)
	return dir
}

@(private = "file")
target_dir_free :: proc(dir: string) {
	os.remove_all(dir)
	delete(dir)
}

// What the live sound holds for parameter i until a test renders a block:
// distinct, so a slot that kept the wrong values cannot pass for the right
// ones, and not the factory's or Init's.
@(private = "file")
target_value :: proc(i: int) -> i32 {
	return i32((i * 7 + 3) % 101)
}

// A bank file under `label` holding one Init patch per name, from slot 0 on.
@(private = "file")
target_bank_file :: proc(path, label: string, names: ..string) -> bool {
	patches := make([]patch.Patch, len(names), context.temp_allocator)
	for name, i in names {
		patches[i] = patch.init_patch()
		patches[i].name = name
	}
	return os.write_entire_file_from_string(path, patch.write_bank_json(label, patches, nil, context.temp_allocator)) == nil
}

// The bank.json a daemon with no --bank would load and keep, holding a patch of
// its own so that losing it shows.
@(private = "file")
target_config_bank :: proc(dir: string) -> (path: string, ok: bool) {
	path = fmt.tprintf("%s/config/quesynth/bank.json", dir)
	if os.make_directory_all(fmt.tprintf("%s/config/quesynth", dir)) != nil {return path, false}
	return path, target_bank_file(path, "Json Bank", "Json Only")
}

@(private = "file")
target_bytes :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<unreadable>"
}

// The file read the way a start reads it.
@(private = "file")
target_read :: proc(path: string) -> (^patch.Slots, bool) {
	fresh := new(patch.Slots)
	if !standalone.load_bank_file(fresh, path) {
		free(fresh)
		return nil, false
	}
	return fresh, true
}

@(private = "file")
target_expect_saved :: proc(t: ^testing.T, bank: ^patch.Slots, slot: int, name: string) {
	testing.expectf(t, bank.filled[slot], "slot %d is empty", slot)
	testing.expect_value(t, patch.slots_name(bank, slot), name)
	sound: [patch.PARAMETER_COUNT]i32
	for i in 0 ..< patch.PARAMETER_COUNT {sound[i] = target_value(i)}
	testing.expectf(t, bank.values[slot] == sound, "slot %d does not hold the sound that was saved", slot)
}

@(private = "file")
TARGET_BLOCK :: 64

@(private = "file")
Target :: struct {
	live:     standalone.Live,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	state:    standalone.Daemon_State,
	keep:     string,
	out:      [TARGET_BLOCK * 2]f32,
	cs:       standalone.Control_Server,
	client:   posix.FD,
}

// A daemon started with `bank_path` as its --bank operand ("" for none) and
// its bank.json at `config_bank` ("" for no config directory), with one client
// connected. A save stores target_value's sound until the test renders a
// block, which applies what is queued as the audio thread would.
@(private = "file")
target_start :: proc(dir, tag, bank_path, config_bank: string) -> (^Target, bool) {
	d := new(Target)
	guarded: bool
	d.identity, d.keep, guarded = standalone.daemon_start_bank(&d.bank, bank_path, config_bank)
	engine.engine_load_patch(&d.live.eng, patch.init_patch(), 48000)
	d.live.left = make([]f32, TARGET_BLOCK)
	d.live.right = make([]f32, TARGET_BLOCK)
	d.live.volume.milli = standalone.VOLUME_UNITY
	d.live.volume_prev = standalone.VOLUME_UNITY
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = target_value(i)}
	standalone.snapshot_publish(&d.live.snapshot, seed)
	d.state = .Running
	d.cs.path = fmt.tprintf("%s/%s.sock", dir, tag)
	d.cs.ctx = standalone.Control_Context {
		ring              = &d.live.ring,
		snapshot          = &d.live.snapshot,
		state             = &d.state,
		bank              = &d.bank,
		identity          = &d.identity,
		bank_keep         = d.keep,
		bank_keep_guarded = guarded,
	}
	d.client = -1
	if !standalone.control_server_start(&d.cs) {
		target_stop(d)
		return nil, false
	}
	connected: bool
	d.client, connected = connect_unix(d.cs.path)
	if !connected {
		target_stop(d)
		return nil, false
	}
	return d, true
}

@(private = "file")
target_stop :: proc(d: ^Target) {
	if d.client >= 0 {posix.close(d.client)}
	standalone.control_server_stop(&d.cs)
	engine.engine_destroy(&d.live.eng)
	delete(d.live.left)
	delete(d.live.right)
	delete(d.keep)
	free(d)
}

// One request on the connection the daemon was started with; its reply.
@(private = "file")
target_ask :: proc(d: ^Target, line: string) -> string {
	reliability_send(d.client, line)
	return reliability_reply(d.client)
}

// The bank.list line of one slot.
@(private = "file")
target_slot_line :: proc(list: string, slot: int) -> string {
	prefix := fmt.tprintf("slot=%d ", slot)
	for line in strings.split_lines(list, context.temp_allocator) {
		if strings.has_prefix(line, prefix) {return line}
	}
	return ""
}

@(private = "file")
target_nothing_current :: proc(id: int, bank_rev: int) -> string {
	return fmt.tprintf(
		"1 %d ok slot=-1 bank_rev=%d revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
		id,
		bank_rev,
	)
}

@(test)
test_a_save_under_bank_is_in_that_file_at_its_next_start :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	named := fmt.tprintf("%s/my bank.json", dir)
	if !testing.expect(t, target_bank_file(named, "Named Bank", "Earlier", "Also Earlier")) {return}
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)

	first, fok := target_start(dir, "first", named, config_bank)
	if !testing.expect(t, fok) {return}
	testing.expect_value(t, target_ask(first, "1 1 patch.save 120 Kept Lead"), "1 1 ok slot=120 name=Kept_Lead bank_rev=2")
	target_stop(first)

	// The file holds what it held, and the save beside it.
	kept, read := target_read(named)
	if testing.expect(t, read, "the --bank file no longer loads") {
		testing.expect_value(t, patch.slots_label(kept), "Named Bank")
		testing.expect_value(t, patch.slots_name(kept, 0), "Earlier")
		testing.expect_value(t, patch.slots_name(kept, 1), "Also Earlier")
		testing.expect(t, kept.filled[0] && kept.filled[1])
		target_expect_saved(t, kept, 120, "Kept Lead")
		free(kept)
	}
	testing.expect_value(t, target_bytes(config_bank), json_before)

	// The next start with the same --bank has the slot, and plays it.
	second, sok := target_start(dir, "second", named, config_bank)
	if !testing.expect(t, sok) {return}
	defer target_stop(second)
	testing.expect_value(t, target_ask(second, "1 1 patch.current"), target_nothing_current(1, 1))
	target_expect_saved(t, &second.bank, 120, "Kept Lead")
	testing.expect(t, strings.has_prefix(target_ask(second, "1 2 patch.load 120"), "1 2 ok slot=120 name=Kept_Lead "))
	testing.expect_value(t, target_bytes(config_bank), json_before)
}

@(test)
test_bank_keep_under_bank_writes_that_file_and_never_bank_json :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	named := fmt.tprintf("%s/kept.json", dir)
	other := fmt.tprintf("%s/other bank.json", dir)
	if !testing.expect(t, target_bank_file(named, "Named Bank", "Earlier")) {return}
	if !testing.expect(t, target_bank_file(other, "Other Bank", "Other")) {return}
	// No config directory has been made: nothing may make one.
	config_bank := fmt.tprintf("%s/config/quesynth/bank.json", dir)

	// Given relative to the working directory, which the tests run in.
	cwd, werr := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, werr == nil) {return}
	relative := strings.concatenate({strings.repeat("../", strings.count(cwd, "/"), context.temp_allocator), named[1:]}, context.temp_allocator)
	d, ok := target_start(dir, "d", relative, config_bank)
	if !testing.expect(t, ok) {return}
	defer target_stop(d)

	testing.expect_value(t, target_ask(d, "1 1 patch.save 5 Fifth"), "1 1 ok slot=5 name=Fifth bank_rev=2")
	testing.expect(t, strings.has_prefix(target_ask(d, fmt.tprintf("1 2 bank.load_file %s", other)), "1 2 ok label=Other_Bank count=1 "))
	reply := target_ask(d, "1 3 bank.keep")
	data := target_bytes(named)
	fields := strings.split_n(reply, " path=", 2, context.temp_allocator)
	if testing.expect_value(t, len(fields), 2) {
		testing.expect_value(t, fields[0], fmt.tprintf("1 3 ok bytes=%d", len(data)))
		testing.expectf(t, os.is_absolute_path(fields[1]), "path=%s is not absolute", fields[1])
		testing.expect_value(t, target_bytes(fields[1]), data)
	}
	kept, read := target_read(named)
	if testing.expect(t, read) {
		testing.expect_value(t, patch.slots_label(kept), "Other Bank")
		testing.expect_value(t, patch.slots_name(kept, 0), "Other")
		testing.expect(t, !kept.filled[5], "bank.keep wrote the bank it replaced")
		free(kept)
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/config", dir)), "a daemon started with --bank made a config directory")
}

@(test)
test_a_bank_file_that_does_not_exist_yet_is_made_by_the_first_save :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	fresh := fmt.tprintf("%s/new banks/fresh.json", dir)
	config_bank := fmt.tprintf("%s/config/quesynth/bank.json", dir)

	first, fok := target_start(dir, "first", fresh, config_bank)
	if !testing.expect(t, fok) {return}
	// A daemon that keeps nothing, to show the replies do not depend on it.
	plain, pok := target_start(dir, "plain", "", "")
	if !testing.expect(t, pok) {target_stop(first);return}
	defer target_stop(plain)
	testing.expect_value(t, target_ask(first, "1 1 patch.save 120 Fresh"), "1 1 ok slot=120 name=Fresh bank_rev=1")
	testing.expect_value(t, target_ask(plain, "1 1 patch.save 120 Fresh"), "1 1 ok slot=120 name=Fresh bank_rev=1")
	for line in ([]string{"1 2 patch.save 121", "1 3 patch.save 0 Over Factory", "1 4 patch.current"}) {
		testing.expect_value(t, target_ask(first, line), target_ask(plain, line))
	}
	target_stop(first)
	testing.expect(t, !os.exists(fmt.tprintf("%s/config", dir)), "a daemon started with --bank made a config directory")

	// The whole bank is in the new file: the factory's slots and the saves.
	kept, read := target_read(fresh)
	if testing.expect(t, read, "the first save did not make the --bank file") {
		target_expect_saved(t, kept, 120, "Fresh")
		target_expect_saved(t, kept, 121, "Init")
		target_expect_saved(t, kept, 0, "Over Factory")
		for i in 1 ..< patch.FACTORY_SLOTS {
			if i == 120 || i == 121 {continue}
			testing.expectf(t, kept.filled[i] == plain.bank.filled[i], "slot %d changed its filled state", i)
			testing.expect_value(t, patch.slots_name(kept, i), patch.slots_name(&plain.bank, i))
		}
		free(kept)
	}

	second, sok := target_start(dir, "second", fresh, config_bank)
	if !testing.expect(t, sok) {return}
	defer target_stop(second)
	testing.expect_value(t, target_ask(second, "1 1 patch.current"), target_nothing_current(1, 1))
	target_expect_saved(t, &second.bank, 120, "Fresh")
}

@(test)
test_a_bank_file_the_daemon_did_not_load_is_never_replaced :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)
	notes := fmt.tprintf("%s/notes.json", dir)
	if !testing.expect(t, os.write_entire_file_from_string(notes, "{ my notes, not a bank") == nil) {return}
	folder := fmt.tprintf("%s/folder.json", dir)
	if !testing.expect(t, os.make_directory_all(folder) == nil) {return}
	if !testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/inside", folder), "kept") == nil) {return}

	for path, i in ([]string{notes, folder}) {
		d, ok := target_start(dir, fmt.tprintf("case%d", i), path, config_bank)
		if !testing.expect(t, ok) {return}
		defer target_stop(d)
		before := new(patch.Slots)
		defer free(before)
		before^ = d.bank
		identity := d.identity
		filled := 0
		for !d.bank.filled[filled] {filled += 1}

		testing.expect_value(t, target_ask(d, "1 1 patch.save 120 Lost"), "1 1 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, fmt.tprintf("1 2 patch.save %d Over", filled)), "1 2 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, "1 3 bank.keep"), "1 3 err internal_error cannot write file")
		// Refused, and still served: nothing moved.
		testing.expect_value(t, target_ask(d, "1 4 patch.current"), target_nothing_current(4, 0))
		testing.expect(t, d.bank == before^, "a refused save left a mark on the bank")
		testing.expect(t, d.identity == identity, "a refused save changed which patch is playing")

		testing.expect_value(t, target_bytes(notes), "{ my notes, not a bank")
		testing.expect(t, os.is_dir(folder))
		testing.expect_value(t, target_bytes(fmt.tprintf("%s/inside", folder)), "kept")
		testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)), "a temporary bank was left beside it")
		testing.expect_value(t, target_bytes(config_bank), json_before)
	}
}

@(test)
test_an_empty_bank_file_is_written_and_one_made_since_the_start_is_not :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)

	// Empty: there is nothing in it to lose. Once the daemon has written it,
	// it is the daemon's file, though the start did not load it.
	empty := fmt.tprintf("%s/empty.json", dir)
	if !testing.expect(t, os.write_entire_file_from_string(empty, "") == nil) {return}
	e, eok := target_start(dir, "empty", empty, config_bank)
	if !testing.expect(t, eok) {return}
	defer target_stop(e)
	testing.expect_value(t, target_ask(e, "1 1 patch.save 120 First"), "1 1 ok slot=120 name=First bank_rev=1")
	testing.expect_value(t, target_ask(e, "1 2 patch.save 121 Second"), "1 2 ok slot=121 name=Second bank_rev=2")
	testing.expect_value(t, target_ask(e, "1 3 bank.keep"), fmt.tprintf("1 3 ok bytes=%d path=%s", len(target_bytes(empty)), empty))
	kept, read := target_read(empty)
	if testing.expect(t, read) {
		target_expect_saved(t, kept, 120, "First")
		target_expect_saved(t, kept, 121, "Second")
		free(kept)
	}

	// Missing at the start, and made by somebody else before the first save.
	late := fmt.tprintf("%s/late.json", dir)
	l, lok := target_start(dir, "late", late, config_bank)
	if !testing.expect(t, lok) {return}
	defer target_stop(l)
	if !testing.expect(t, os.write_entire_file_from_string(late, "somebody else's") == nil) {return}
	before := new(patch.Slots)
	defer free(before)
	before^ = l.bank
	testing.expect_value(t, target_ask(l, "1 1 patch.save 120 Lost"), "1 1 err internal_error cannot keep bank")
	testing.expect_value(t, target_ask(l, "1 2 bank.keep"), "1 2 err internal_error cannot write file")
	testing.expect_value(t, target_ask(l, "1 3 patch.current"), target_nothing_current(3, 0))
	testing.expect(t, l.bank == before^, "a refused save left a mark on the bank")
	testing.expect_value(t, target_bytes(late), "somebody else's")
	testing.expect_value(t, target_bytes(config_bank), json_before)
}

@(private = "file")
target_send_all :: proc(fd: posix.FD, lines: ..string) {
	wire := make([dynamic]u8, context.temp_allocator)
	for line in lines {
		n := len(line)
		append(&wire, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(&wire, ..transmute([]u8)line)
	}
	posix.send(fd, raw_data(wire[:]), c.size_t(len(wire)), {.NOSIGNAL})
}

@(test)
test_a_save_that_waited_under_bank_is_kept_in_that_file :: proc(t: ^testing.T) {
	for mode in ([]string{"attached", "detached", "detached-failure"}) {
		dir := target_dir_make()
		defer target_dir_free(dir)
		named := fmt.tprintf("%s/named.json", dir)
		other := fmt.tprintf("%s/other.json", dir)
		if !testing.expect(t, target_bank_file(named, "Named Bank", "Earlier")) {return}
		if !testing.expect(t, target_sparse_bank_file(other, "Other Bank", 40, "Other", 41)) {return}
		named_before, other_before := target_bytes(named), target_bytes(other)
		config_bank, cok := target_config_bank(dir)
		if !testing.expect(t, cok) {return}
		json_before := target_bytes(config_bank)
		d, ok := target_start(dir, "d", named, config_bank)
		if !testing.expect(t, ok) {return}
		defer target_stop(d)
		bank_rev := 2
		if mode != "attached" {
			testing.expect_value(t, target_ask(d, fmt.tprintf("1 0 bank.load_file %s", other)), "1 0 ok label=Other_Bank count=1 bank_rev=2")
			bank_rev = 3
		}
		before := new_clone(d.bank)
		defer free(before)
		identity := d.identity
		blocker := fmt.tprintf("%s.tmp", named)
		if mode == "detached-failure" {
			if !testing.expect(t, os.make_directory_all(blocker) == nil) {return}
			testing.expect_value(t, target_ask(d, "1 0 bank.keep"), "1 0 err internal_error cannot write file")
			testing.expect_value(t, target_ask(d, "1 0 patch.save 40 Refused"), "1 0 err internal_error cannot keep bank")
			testing.expect(t, d.bank == before^ && d.identity == identity)
		}

		target_send_all(d.client, "1 1 parameter.set filter.cutoff 77", "1 2 patch.save 120 Waited Lead")
		queued := false
		for _ in 0 ..< 1000 {
			if standalone.PARAM_RING_CAPACITY - standalone.param_ring_free_space(&d.live.ring) >= 2 {queued = true;break}
			time.sleep(time.Millisecond)
		}
		if !testing.expect(t, queued) {return}
		testing.expect_value(t, reliability_reply(d.client), "1 1 ok value=77 revision=0")
		time.sleep(30 * time.Millisecond)
		testing.expect_value(t, target_bytes(named), named_before)
		fds := [1]posix.pollfd{{fd = d.client, events = {.IN}}}
		testing.expect_value(t, posix.poll(&fds[0], 1, 0), 0)

		standalone.live_render(&d.live, raw_data(d.out[:]), TARGET_BLOCK, 2)
		if mode == "detached-failure" {
			testing.expect_value(t, reliability_reply(d.client), "1 2 err internal_error cannot keep bank")
			testing.expect(t, d.bank == before^ && d.identity == identity)
			testing.expect_value(t, target_bytes(named), named_before)
			if !testing.expect(t, os.remove(blocker) == nil) {return}
			testing.expect_value(t, target_ask(d, "1 3 patch.save 120 Waited Lead"), "1 3 ok slot=120 name=Waited_Lead bank_rev=3")
		} else {
			testing.expect_value(t, reliability_reply(d.client), fmt.tprintf("1 2 ok slot=120 name=Waited_Lead bank_rev=%d", bank_rev))
		}
		cutoff, found := registry.registry_describe("filter.cutoff")
		if !testing.expect(t, found) {return}
		sound := standalone.snapshot_read(&d.live.snapshot)
		testing.expect_value(t, sound.values[cutoff.index], 77)
		testing.expect_value(t, sound.revision, 1)
		kept, read := target_read(named)
		if testing.expect(t, read, "the save that waited is not in the --bank file") {
			testing.expect_value(t, patch.slots_label(kept), "Named Bank")
			testing.expect_value(t, patch.slots_name(kept, 0), "Earlier")
			testing.expect(t, kept.filled[120] && !kept.filled[40])
			testing.expect_value(t, patch.slots_name(kept, 120), "Waited Lead")
			testing.expect_value(t, kept.values[120], sound.values)
			free(kept)
		}
		testing.expect_value(t, target_bytes(other), other_before)
		testing.expect_value(t, target_bytes(config_bank), json_before)
	}
}

@(test)
test_without_bank_a_save_is_kept_in_bank_json_and_bank_still_wins_at_start :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	config_bank := fmt.tprintf("%s/config/quesynth/bank.json", dir)

	first, fok := target_start(dir, "first", "", config_bank)
	if !testing.expect(t, fok) {return}
	testing.expect_value(t, target_ask(first, "1 1 patch.save 120 Json Save"), "1 1 ok slot=120 name=Json_Save bank_rev=1")
	reply := target_ask(first, "1 2 bank.keep")
	testing.expect_value(t, reply, fmt.tprintf("1 2 ok bytes=%d path=%s", len(target_bytes(config_bank)), config_bank))
	target_stop(first)

	second, sok := target_start(dir, "second", "", config_bank)
	if !testing.expect(t, sok) {return}
	testing.expect_value(t, target_ask(second, "1 1 patch.current"), target_nothing_current(1, 1))
	target_expect_saved(t, &second.bank, 120, "Json Save")
	target_stop(second)

	// A --bank file is still what a start loads, over bank.json.
	named := fmt.tprintf("%s/named.json", dir)
	if !testing.expect(t, target_bank_file(named, "Named Bank", "Earlier")) {return}
	third, tok := target_start(dir, "third", named, config_bank)
	if !testing.expect(t, tok) {return}
	defer target_stop(third)
	list := target_ask(third, "1 1 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 1 ok label=Named_Bank count=1 "), list[:min(len(list), 60)])
	testing.expect_value(t, target_slot_line(list, 120), "slot=120 filled=0 name=Init")
}

// The TUI, through its own client library, with a User bank in its config.conf.
@(private = "file")
target_tui :: proc(d: ^Target, user_bank: string) -> (client: tui.Client, loaded: bool, connected: bool) {
	client, connected = tui.client_connect(d.cs.path)
	if !connected {return}
	loaded = tui.tui_load_user_bank(&client, user_bank)
	return
}

@(test)
test_a_tui_save_under_bank_is_there_when_a_tui_attaches_after_a_restart :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	named := fmt.tprintf("%s/tui bank.json", dir)
	user := fmt.tprintf("%s/user bank.json", dir)
	if !testing.expect(t, target_bank_file(user, "User Bank", "User")) {return}
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)

	// The --bank file does not exist yet, so the start is on the factory bank
	// and the TUI loads its User bank into it before saving.
	first, fok := target_start(dir, "first", named, config_bank)
	if !testing.expect(t, fok) {return}
	client, loaded, connected := target_tui(first, user)
	testing.expect(t, connected && loaded, "a TUI loads its User bank into a fresh daemon")
	testing.expect(t, tui.client_patch_save(&client, 16, "Tui Save"))
	testing.expect_value(t, client.notice, "")
	tui.client_close(&client)
	target_stop(first)

	second, sok := target_start(dir, "second", named, config_bank)
	if !testing.expect(t, sok) {return}
	defer target_stop(second)
	client, loaded, connected = target_tui(second, user)
	testing.expect(t, connected)
	testing.expect(t, !loaded, "the User bank must not be loaded over the --bank file the daemon loaded")
	tui.client_close(&client)
	list := target_ask(second, "1 1 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 1 ok label=User_Bank count=2 "), list[:min(len(list), 60)])
	testing.expect_value(t, target_slot_line(list, 0), "slot=0 filled=1 name=User")
	testing.expect_value(t, target_slot_line(list, 16), "slot=16 filled=1 name=Tui_Save")
	testing.expect_value(t, target_bytes(config_bank), json_before)

	// A --bank file the daemon may not replace: S says why, and the TUI is
	// still served.
	notes := fmt.tprintf("%s/notes.json", dir)
	if !testing.expect(t, os.write_entire_file_from_string(notes, "not a bank") == nil) {return}
	third, tok := target_start(dir, "third", notes, config_bank)
	if !testing.expect(t, tok) {return}
	defer target_stop(third)
	client, loaded, connected = target_tui(third, user)
	defer tui.client_close(&client)
	testing.expect(t, connected && loaded)
	testing.expect(t, !tui.client_patch_save(&client, 16, "Refused"))
	testing.expect_value(t, client.notice, "cannot keep bank")
	p, read := tui.client_provenance(&client, context.temp_allocator)
	testing.expect(t, read, "the connection must still be served after a refusal")
	testing.expect_value(t, p.bank_rev, 1)
	testing.expect(t, !third.bank.filled[16], "a refused save stores nothing")
	testing.expect_value(t, target_bytes(notes), "not a bank")
	testing.expect_value(t, target_bytes(config_bank), json_before)
}

@(test)
test_exporting_the_selected_file_makes_save_and_keep_work_without_restart :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)
	cwd, werr := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, werr == nil) {return}

	for invalid in ([]bool{false, true}) {
		for mode in ([]string{"absolute", "relative", "dot", "symlink", "hardlink"}) {
			named := fmt.tprintf("%s/%v-%s bank.json", dir, invalid, mode)
			if invalid && !testing.expect(t, os.write_entire_file_from_string(named, "not a bank") == nil) {return}
			first, fok := target_start(dir, "first", named, config_bank)
			if !testing.expect(t, fok) {return}
			path := named
			switch mode {
			case "relative":
				path = strings.concatenate({strings.repeat("../", strings.count(cwd, "/"), context.temp_allocator), named[1:]}, context.temp_allocator)
			case "dot":
				path = fmt.tprintf("%s/../%s", dir, named[len("/tmp/"):])
			case "symlink":
				path = fmt.tprintf("%s/export-link.json", dir)
				os.remove(path)
				if !testing.expect(t, os.symlink(named, path) == nil) {target_stop(first);return}
			case "hardlink":
				if !invalid && !testing.expect(t, os.write_entire_file_from_string(named, "late notes") == nil) {target_stop(first);return}
				path = fmt.tprintf("%s/export-hardlink.json", dir)
				os.remove(path)
				if !testing.expect(t, os.link(named, path) == nil) {target_stop(first);return}
			}
			before := new_clone(first.bank)
			identity := first.identity
			sound := standalone.snapshot_read(&first.live.snapshot)
			free_space := standalone.param_ring_free_space(&first.live.ring)
			testing.expect_value(t, target_ask(first, fmt.tprintf("1 1 bank.write %s", path)), fmt.tprintf("1 1 ok bytes=%d", len(target_bytes(named))))
			testing.expect(t, first.bank == before^, "export changed the bank")
			free(before)
			testing.expect(t, first.identity == identity, "export changed identity or bank_rev")
			testing.expect(t, standalone.snapshot_read(&first.live.snapshot) == sound, "export changed the audio snapshot")
			testing.expect_value(t, standalone.param_ring_free_space(&first.live.ring), free_space)
			testing.expect_value(t, target_ask(first, "1 2 patch.current"), target_nothing_current(2, 0))
			testing.expect_value(t, target_ask(first, "1 3 patch.save 12 AfterExport"), "1 3 ok slot=12 name=AfterExport bank_rev=1")
			testing.expect_value(t, target_ask(first, "1 4 bank.keep"), fmt.tprintf("1 4 ok bytes=%d path=%s", len(target_bytes(named)), named))
			target_stop(first)

			second, sok := target_start(dir, "second", named, config_bank)
			if !testing.expect(t, sok) {return}
			target_expect_saved(t, &second.bank, 12, "AfterExport")
			testing.expect_value(t, target_ask(second, "1 1 patch.current"), target_nothing_current(1, 1))
			testing.expect(t, strings.has_prefix(target_ask(second, "1 2 patch.load 12"), "1 2 ok slot=12 name=AfterExport "))
			target_stop(second)
			testing.expect_value(t, target_bytes(config_bank), json_before)
		}
	}
}

@(test)
test_other_exports_failed_exports_and_loading_do_not_own_the_selected_file :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)
	for invalid in ([]bool{false, true}) {
		named := fmt.tprintf("%s/%v guarded.json", dir, invalid)
		if invalid && !testing.expect(t, os.write_entire_file_from_string(named, "not a bank") == nil) {return}
		d, ok := target_start(dir, fmt.tprintf("negative-%v", invalid), named, config_bank)
		if !testing.expect(t, ok) {return}
		defer target_stop(d)
		if !invalid && !testing.expect(t, os.write_entire_file_from_string(named, "not a bank") == nil) {return}
		other := fmt.tprintf("%s/%v other.json", dir, invalid)
		before := new_clone(d.bank)
		defer free(before)
		identity := d.identity
		sound := standalone.snapshot_read(&d.live.snapshot)
		testing.expect_value(t, target_ask(d, fmt.tprintf("1 1 bank.write %s", other)), fmt.tprintf("1 1 ok bytes=%d", len(target_bytes(other))))
		other_before := target_bytes(other)
		testing.expect_value(t, target_ask(d, "1 2 patch.save 12 Refused"), "1 2 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, "1 3 bank.keep"), "1 3 err internal_error cannot write file")
		testing.expect_value(t, target_bytes(named), "not a bank")
		testing.expect(t, d.bank == before^ && d.identity == identity, "unrelated export or refused save changed bank/identity")
		testing.expect(t, standalone.snapshot_read(&d.live.snapshot) == sound, "unrelated export changed audio")

		if !testing.expect(t, os.remove(named) == nil && os.make_directory_all(named) == nil) {return}
		testing.expect_value(t, target_ask(d, fmt.tprintf("1 4 bank.write %s", named)), "1 4 err internal_error cannot write file")
		if !testing.expect(t, os.remove(named) == nil && os.write_entire_file_from_string(named, "not a bank") == nil) {return}
		testing.expect_value(t, target_ask(d, "1 5 patch.save 12 Refused"), "1 5 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, "1 6 bank.keep"), "1 6 err internal_error cannot write file")
		testing.expect(t, d.bank == before^ && d.identity == identity, "failed export or refused save changed bank/identity")
		testing.expect(t, standalone.snapshot_read(&d.live.snapshot) == sound, "failed export changed audio")

		testing.expect(t, strings.has_prefix(target_ask(d, fmt.tprintf("1 7 bank.load_file %s", other)), "1 7 ok label="))
		testing.expect_value(t, target_ask(d, "1 8 patch.save 12 Refused"), "1 8 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, "1 9 bank.keep"), "1 9 err internal_error cannot write file")
		testing.expect_value(t, target_bytes(named), "not a bank")
		testing.expect_value(t, target_bytes(other), other_before)
		if !testing.expect(t, os.write_entire_file_from_string(named, other_before) == nil) {return}
		testing.expect(t, strings.has_prefix(target_ask(d, fmt.tprintf("1 10 bank.load_file %s", named)), "1 10 ok label="))
		testing.expect_value(t, target_ask(d, "1 11 patch.save 12 Refused"), "1 11 err internal_error cannot keep bank")
		testing.expect_value(t, target_ask(d, "1 12 bank.keep"), "1 12 err internal_error cannot write file")
		testing.expect_value(t, target_bytes(named), other_before)
		testing.expect_value(t, target_bytes(config_bank), json_before)
	}
}

@(private = "file")
target_sparse_bank_file :: proc(path, label: string, slot: int, name: string, cutoff: int) -> bool {
	return os.write_entire_file_from_string(path, fmt.tprintf(
		`{{"format":"quesynth.bank","version":1,"name":"%s","patches":[%s{{"name":"%s","parameters":{{"*filter freq":%d}}}]}}`,
		label, strings.repeat("null,", slot, context.temp_allocator), name, cutoff,
	)) == nil
}

@(test)
test_detached_saves_preserve_the_selected_bank_across_restart :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	named := fmt.tprintf("%s/selected.json", dir)
	other := fmt.tprintf("%s/other.json", dir)
	config_bank := fmt.tprintf("%s/bank.json", dir)
	if !testing.expect(t, target_sparse_bank_file(named, "Selected Bank", 30, "Seed", 31)) {return}
	if !testing.expect(t, target_sparse_bank_file(other, "Other Bank", 40, "Other", 41)) {return}
	if !testing.expect(t, target_sparse_bank_file(config_bank, "Json Bank", 121, "JsonOnly", 23)) {return}
	json_before, other_before := target_bytes(config_bank), target_bytes(other)
	cutoff, found := registry.registry_describe("filter.cutoff")
	if !testing.expect(t, found) {return}
	first, fok := target_start(dir, "first", named, config_bank)
	if !testing.expect(t, fok) {return}
	seed := first.bank.values[30]
	testing.expect_value(t, seed[cutoff.index], 31)
	testing.expect_value(t, target_ask(first, fmt.tprintf("1 1 bank.load_file %s", other)), "1 1 ok label=Other_Bank count=1 bank_rev=2")
	saved: [2][patch.PARAMETER_COUNT]i32
	for value, i in ([]int{77, 88}) {
		slot := 7 + i
		name := i == 0 ? "DetachedSave" : "DetachedAgain"
		testing.expect_value(t, target_ask(first, fmt.tprintf("1 2 parameter.set filter.cutoff %d", value)), fmt.tprintf("1 2 ok value=%d revision=%d", value, i))
		standalone.live_render(&first.live, raw_data(first.out[:]), TARGET_BLOCK, 2)
		sound := standalone.snapshot_read(&first.live.snapshot)
		saved[i] = sound.values
		testing.expect_value(t, target_ask(first, fmt.tprintf("1 3 patch.save %d %s", slot, name)), fmt.tprintf("1 3 ok slot=%d name=%s bank_rev=%d", slot, name, 3 + i))
		testing.expect(t, standalone.snapshot_read(&first.live.snapshot) == sound, "saving changed audio or revision")
		testing.expect_value(t, target_ask(first, "1 4 patch.current"), fmt.tprintf("1 4 ok slot=%d bank_rev=%d revision=%d source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Other Bank\nname=%s", slot, 3 + i, i + 1, name))
	}
	list := target_ask(first, "1 5 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 5 ok label=Other_Bank count=3 slots=128\n"))
	testing.expect_value(t, target_slot_line(list, 30), "slot=30 filled=0 name=Init")
	testing.expect_value(t, target_slot_line(list, 40), "slot=40 filled=1 name=Other")
	target_stop(first)

	second, sok := target_start(dir, "second", named, config_bank)
	if !testing.expect(t, sok) {return}
	testing.expect_value(t, target_ask(second, "1 1 patch.current"), target_nothing_current(1, 1))
	list = target_ask(second, "1 2 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 2 ok label=Selected_Bank count=3 slots=128\n"))
	testing.expect_value(t, target_slot_line(list, 30), "slot=30 filled=1 name=Seed")
	testing.expect_value(t, second.bank.values[30], seed)
	testing.expect_value(t, target_slot_line(list, 40), "slot=40 filled=0 name=Init")
	for name, i in ([]string{"DetachedSave", "DetachedAgain"}) {
		testing.expect_value(t, target_slot_line(list, 7 + i), fmt.tprintf("slot=%d filled=1 name=%s", 7 + i, name))
		testing.expect_value(t, second.bank.values[7 + i], saved[i])
		testing.expect(t, strings.has_prefix(target_ask(second, fmt.tprintf("1 3 patch.load %d", 7 + i)), fmt.tprintf("1 3 ok slot=%d name=%s ", 7 + i, name)))
		standalone.live_render(&second.live, raw_data(second.out[:]), TARGET_BLOCK, 2)
		testing.expect_value(t, standalone.snapshot_read(&second.live.snapshot).values, saved[i])
	}
	target_stop(second)
	testing.expect_value(t, target_bytes(other), other_before)
	testing.expect_value(t, target_bytes(config_bank), json_before)

	plain, pok := target_start(dir, "plain", "", config_bank)
	if !testing.expect(t, pok) {return}
	defer target_stop(plain)
	list = target_ask(plain, "1 1 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 1 ok label=Json_Bank count=1 slots=128\n"))
	testing.expect_value(t, target_slot_line(list, 121), "slot=121 filled=1 name=JsonOnly")
	testing.expect_value(t, plain.bank.values[121][cutoff.index], 23)
	testing.expect_value(t, target_bytes(config_bank), json_before)
}

@(test)
test_an_initial_export_or_keep_is_not_an_untouched_factory_bank :: proc(t: ^testing.T) {
	dir := target_dir_make()
	defer target_dir_free(dir)
	other := fmt.tprintf("%s/other.json", dir)
	if !testing.expect(t, target_sparse_bank_file(other, "Other Bank", 40, "Other", 41)) {return}
	other_before := target_bytes(other)
	for mode in ([]string{"export", "keep", "no-flag"}) {
		named := fmt.tprintf("%s/%s.json", dir, mode)
		first, fok := target_start(dir, "first", mode == "no-flag" ? "" : named, named)
		if !testing.expect(t, fok) {return}
		factory := new_clone(first.bank)
		identity := first.identity
		sound := standalone.snapshot_read(&first.live.snapshot)
		line := mode == "export" ? fmt.tprintf("1 1 bank.write %s", named) : "1 1 bank.keep"
		testing.expect(t, strings.has_prefix(target_ask(first, line), "1 1 ok bytes="))
		testing.expect(t, first.identity == identity && standalone.snapshot_read(&first.live.snapshot) == sound)
		testing.expect_value(t, target_ask(first, "1 2 patch.current"), target_nothing_current(2, 0))
		testing.expect_value(t, target_ask(first, fmt.tprintf("1 3 bank.load_file %s", other)), "1 3 ok label=Other_Bank count=1 bank_rev=1")
		testing.expect_value(t, target_ask(first, "1 4 patch.save 7 DetachedSave"), "1 4 ok slot=7 name=DetachedSave bank_rev=2")
		target_stop(first)
		second, sok := target_start(dir, "second", mode == "no-flag" ? "" : named, named)
		if !testing.expect(t, sok) {free(factory);return}
		testing.expect_value(t, patch.slots_label(&second.bank), "Factory")
		for slot in 0 ..< patch.FACTORY_SLOTS {
			if slot == 7 {continue}
			testing.expect_value(t, second.bank.filled[slot], factory.filled[slot])
			testing.expect_value(t, patch.slots_name(&second.bank, slot), patch.slots_name(factory, slot))
			if factory.filled[slot] {testing.expect_value(t, second.bank.values[slot], factory.values[slot])}
		}
		target_expect_saved(t, &second.bank, 7, "DetachedSave")
		target_stop(second)
		free(factory)
		testing.expect_value(t, target_bytes(other), other_before)
	}
}
