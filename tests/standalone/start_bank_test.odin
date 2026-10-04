#+build linux
package standalone_tests

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import patch "../../src/patch"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// A daemon counts the bank file it loads at start -- the --bank one, or the
// bank.json its saves kept -- as the first change to its bank: bank_rev starts
// at 1 then, and at 0 only on the factory bank. The TUI loads the User bank of
// its config.conf only into a bank nobody has chosen, bank_rev 0
// (tui_load_user_bank). While a daemon started at 0 on a kept bank.json too, a
// TUI attaching after a restart loaded its User bank over the bank the daemon
// had just restored, so a saved patch was gone from the live bank, and from
// bank.json at the next save.
//
// The start is daemon_start_bank, what run_daemon calls. Each server here is
// wired with the identity and the kept bank file it returns, as run_daemon
// wires them minus the device, and the TUI side is the TUI's own client
// library. The banks are written by hand, and what is expected of them comes
// from what the test wrote.

@(private = "file")
start_dir_count: u32

@(private = "file")
start_dir_make :: proc() -> string {
	dir := fmt.aprintf("/tmp/quesynth-start-%d-%d", posix.getpid(), intrinsics.atomic_add(&start_dir_count, 1))
	os.remove_all(dir)
	assert(os.make_directory_all(dir) == nil)
	return dir
}

@(private = "file")
start_dir_free :: proc(dir: string) {
	os.remove_all(dir)
	delete(dir)
}

// A bank file holding one patch, `name`, in slot 0, under `label`.
@(private = "file")
start_bank_file :: proc(path, label, name: string) -> bool {
	only := patch.init_patch()
	only.name = name
	text := patch.write_bank_json(label, []patch.Patch{only}, nil, context.temp_allocator)
	return os.write_entire_file_from_string(path, text) == nil
}

@(private = "file")
Started :: struct {
	bank:     patch.Slots,
	ring:     standalone.Param_Ring,
	snap:     standalone.Snapshot,
	state:    standalone.Daemon_State,
	identity: standalone.Patch_Identity,
	keep:     string,
	cs:       standalone.Control_Server,
}

// A daemon's control side after a start given `bank_path`, the --bank operand
// ("" for none), with its bank.json at `config_bank` ("" for no config
// directory).
@(private = "file")
started_serve :: proc(dir, tag, bank_path, config_bank: string) -> (^Started, bool) {
	s := new(Started)
	guarded: bool
	s.identity, s.keep, guarded = standalone.daemon_start_bank(&s.bank, bank_path, config_bank)
	s.state = .Running
	s.cs.path = fmt.tprintf("%s/%s.sock", dir, tag)
	s.cs.ctx = standalone.Control_Context {
		ring              = &s.ring,
		snapshot          = &s.snap,
		state             = &s.state,
		bank              = &s.bank,
		identity          = &s.identity,
		bank_keep         = s.keep,
		bank_keep_guarded = guarded,
	}
	if !standalone.control_server_start(&s.cs) {
		delete(s.keep)
		free(s)
		return nil, false
	}
	return s, true
}

@(private = "file")
started_stop :: proc(s: ^Started) {
	standalone.control_server_stop(&s.cs)
	delete(s.keep)
	free(s)
}

@(private = "file")
started_ask :: proc(s: ^Started, line: string) -> string {
	fd, ok := connect_unix(s.cs.path)
	if !ok {return "CONNECT FAILED"}
	defer posix.close(fd)
	reliability_send(fd, line)
	return reliability_reply(fd)
}

// A TUI attaching with `user_bank` as the User bank of its config.conf.
@(private = "file")
tui_attach :: proc(s: ^Started, user_bank: string) -> (loaded: bool, connected: bool) {
	client, ok := tui.client_connect(s.cs.path)
	if !ok {return false, false}
	defer tui.client_close(&client)
	return tui.tui_load_user_bank(&client, user_bank), true
}

// The bank.list line of one slot.
@(private = "file")
slot_line :: proc(reply: string, slot: int) -> string {
	prefix := fmt.tprintf("slot=%d ", slot)
	for line in strings.split_lines(reply, context.temp_allocator) {
		if strings.has_prefix(line, prefix) {return line}
	}
	return ""
}

@(test)
test_a_start_from_a_bank_file_keeps_a_tui_user_bank_off_it :: proc(t: ^testing.T) {
	dir := start_dir_make()
	defer start_dir_free(dir)
	named := fmt.tprintf("%s/named bank.json", dir)
	broken := fmt.tprintf("%s/broken.json", dir)
	user := fmt.tprintf("%s/user bank.json", dir)
	if !testing.expect(t, start_bank_file(named, "Named Bank", "Named")) {return}
	if !testing.expect(t, os.write_entire_file_from_string(broken, "{ not a bank") == nil) {return}
	if !testing.expect(t, start_bank_file(user, "User Bank", "User")) {return}

	Case :: struct {
		bank_path: string,
		bank_rev:  int,
		loads:     bool,
		label:     string,
	}
	cases := []Case {
		// A bank file the start loaded: the bank is chosen, and a User bank
		// is not loaded over it.
		{named, 1, false, "Named_Bank"},
		// None that loads, missing or unreadable: the factory bank, which
		// nobody chose, so the User bank still replaces it.
		{fmt.tprintf("%s/missing.json", dir), 0, true, "User_Bank"},
		{broken, 0, true, "User_Bank"},
	}
	for want, i in cases {
		s, ok := started_serve(dir, fmt.tprintf("case%d", i), want.bank_path, "")
		if !testing.expect(t, ok) {return}
		defer started_stop(s)

		testing.expect_value(t, started_ask(s, "1 1 patch.current"), fmt.tprintf(
			"1 1 ok slot=-1 bank_rev=%d revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
			want.bank_rev,
		))
		loaded, connected := tui_attach(s, user)
		testing.expect(t, connected)
		testing.expectf(t, loaded == want.loads, "start from %s: User bank loaded=%v", want.bank_path, loaded)
		list := started_ask(s, "1 2 bank.list")
		testing.expect(t, strings.has_prefix(list, fmt.tprintf("1 2 ok label=%s count=1 ", want.label)), list[:min(len(list), 60)])
	}
}

@(test)
test_a_saved_patch_is_still_in_the_bank_after_a_restart_with_a_user_bank :: proc(t: ^testing.T) {
	dir := start_dir_make()
	defer start_dir_free(dir)
	keep := fmt.tprintf("%s/config/quesynth/bank.json", dir)
	user := fmt.tprintf("%s/user bank.json", dir)
	if !testing.expect(t, start_bank_file(user, "User Bank", "User")) {return}

	// The first start finds no bank.json yet. A TUI attaches and loads its
	// User bank; a patch is saved into it, which the daemon keeps.
	first, fok := started_serve(dir, "first", "", keep)
	if !testing.expect(t, fok) {return}
	loaded, connected := tui_attach(first, user)
	testing.expect(t, connected && loaded, "a TUI loads its User bank into a fresh daemon")
	testing.expect_value(t, started_ask(first, "1 1 patch.save 16 Tui Save"), "1 1 ok slot=16 name=Tui_Save bank_rev=2")
	started_stop(first)

	// The restart loads that bank.json, and a TUI attaches again.
	second, sok := started_serve(dir, "second", "", keep)
	if !testing.expect(t, sok) {return}
	defer started_stop(second)
	testing.expect(t, strings.has_prefix(started_ask(second, "1 1 patch.current"), "1 1 ok slot=-1 bank_rev=1 "))
	loaded, connected = tui_attach(second, user)
	testing.expect(t, connected)
	testing.expect(t, !loaded, "the User bank must not be loaded over the bank the daemon kept")

	list := started_ask(second, "1 2 bank.list")
	testing.expect(t, strings.has_prefix(list, "1 2 ok label=User_Bank count=2 "), list[:min(len(list), 60)])
	testing.expect_value(t, slot_line(list, 0), "slot=0 filled=1 name=User")
	testing.expect_value(t, slot_line(list, 16), "slot=16 filled=1 name=Tui_Save")

	// The next save keeps the earlier one beside it on disk too.
	testing.expect_value(t, started_ask(second, "1 3 patch.save 17 Next"), "1 3 ok slot=17 name=Next bank_rev=2")
	kept := new(patch.Slots)
	defer free(kept)
	if testing.expect(t, standalone.load_bank_file(kept, keep), "bank.json must load") {
		testing.expect_value(t, patch.slots_name(kept, 16), "Tui Save")
		testing.expect_value(t, patch.slots_name(kept, 17), "Next")
		testing.expect(t, kept.filled[16] && kept.filled[17])
	}
}
