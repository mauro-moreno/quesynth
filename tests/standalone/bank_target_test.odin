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
	dir := target_dir_make()
	defer target_dir_free(dir)
	named := fmt.tprintf("%s/named.json", dir)
	if !testing.expect(t, target_bank_file(named, "Named Bank", "Earlier")) {return}
	named_before := target_bytes(named)
	config_bank, cok := target_config_bank(dir)
	if !testing.expect(t, cok) {return}
	json_before := target_bytes(config_bank)
	d, ok := target_start(dir, "d", named, config_bank)
	if !testing.expect(t, ok) {return}
	defer target_stop(d)

	target_send_all(d.client, "1 1 parameter.set filter.cutoff 77", "1 2 patch.save 120 Waited Lead")
	queued := false
	for _ in 0 ..< 1000 {
		if standalone.PARAM_RING_CAPACITY - standalone.param_ring_free_space(&d.live.ring) >= 2 {queued = true;break}
		time.sleep(time.Millisecond)
	}
	if !testing.expect(t, queued) {return}
	testing.expect_value(t, reliability_reply(d.client), "1 1 ok value=77 revision=0")
	time.sleep(30 * time.Millisecond)
	// Waiting for the edit ahead of it: nothing is stored or written yet.
	testing.expect_value(t, target_bytes(named), named_before)

	standalone.live_render(&d.live, raw_data(d.out[:]), TARGET_BLOCK, 2)
	testing.expect_value(t, reliability_reply(d.client), "1 2 ok slot=120 name=Waited_Lead bank_rev=2")
	cutoff, found := registry.registry_describe("filter.cutoff")
	if !testing.expect(t, found) {return}
	kept, read := target_read(named)
	if testing.expect(t, read, "the save that waited is not in the --bank file") {
		testing.expect_value(t, patch.slots_name(kept, 0), "Earlier")
		testing.expect(t, kept.filled[120])
		testing.expect_value(t, patch.slots_name(kept, 120), "Waited Lead")
		testing.expect_value(t, kept.values[120][cutoff.index], 77)
		free(kept)
	}
	testing.expect_value(t, target_bytes(config_bank), json_before)
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
