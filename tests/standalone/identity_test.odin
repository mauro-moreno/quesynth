#+build linux
package standalone_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import control "../../src/control"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// The daemon-owned patch identity, bank_rev and bank.keep, driven through the
// real control_handle. The expected replies are the wire format spelled out in
// the protocol contract, and the expected names come from the sources a client
// would name them from -- the factory table, the bytes of a fixture file, an
// archive's entry -- never from the identity code's own output.

@(private = "file")
Bench :: struct {
	ring:     standalone.Param_Ring,
	snap:     standalone.Snapshot,
	state:    standalone.Daemon_State,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	archive:  standalone.Archive,
	cc:       standalone.Control_Context,
}

@(private = "file")
bench_make :: proc() -> ^Bench {
	b := new(Bench)
	patch.factory_prepare()
	patch.slots_load_factory(&b.bank)
	b.state = .Running
	// As run_daemon starts it: nothing named yet.
	b.identity = standalone.Patch_Identity{slot = -1}
	b.cc = standalone.Control_Context {
		ring     = &b.ring,
		snapshot = &b.snap,
		state    = &b.state,
		bank     = &b.bank,
		archive  = &b.archive,
		identity = &b.identity,
	}
	return b
}

@(private = "file")
bench_free :: proc(b: ^Bench) {
	standalone.archive_close(&b.archive)
	free(b)
}

// One request through the real parser and handler; the reply payload.
@(private = "file")
ask :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

// The audio thread's side of a load, which these tests do not run.
@(private = "file")
drain :: proc(r: ^standalone.Param_Ring) {
	for {
		if _, ok := standalone.param_ring_pop(r); !ok {break}
	}
}

@(private = "file")
current_reply :: proc(id, slot: int, bank_rev: uint, revision: int, bank, name: string) -> string {
	return fmt.tprintf("1 %d ok slot=%d bank_rev=%d revision=%d\nbank=%s\nname=%s", id, slot, bank_rev, revision, bank, name)
}

// A filled factory slot whose name has a space, to show names travel raw rather
// than folded to one token.
@(private = "file")
spaced_factory_slot :: proc(bank: ^patch.Slots, skip := -1) -> int {
	for i in 0 ..< patch.FACTORY_SLOTS {
		if i != skip && bank.filled[i] && strings.contains(patch.factory_name(i), " ") {return i}
	}
	return -1
}

@(test)
test_patch_current_starts_unnamed :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	standalone.snapshot_publish(&b.snap, standalone.Snapshot_Data{revision = 4})
	testing.expect_value(t, ask(&b.cc, "1 1 patch.current"), "1 1 ok slot=-1 bank_rev=0 revision=4\nbank=\nname=")
}

@(test)
test_patch_load_names_the_slot :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	k := spaced_factory_slot(&b.bank)
	if !testing.expect(t, k >= 0) {return}

	reply := ask(&b.cc, fmt.tprintf("1 1 patch.load %d", k))
	testing.expect(t, strings.has_prefix(reply, "1 1 ok"))
	testing.expect_value(t, ask(&b.cc, "1 2 patch.current"), current_reply(2, k, 0, 0, "Factory", patch.factory_name(k)))
}

@(test)
test_patch_load_file_names_the_file_patch :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)

	// The fixture's first line is "Synth1 unison four reference fixture".
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 1 patch.load_file tools/s1probe/fixtures/unison-four.sy1"), "1 1 ok"))
	testing.expect_value(t, ask(&b.cc, "1 2 patch.current"), current_reply(2, -1, 0, 0, "file", "unison four reference fixture"))
	drain(&b.ring)

	// A patch with no name of its own is named by its file.
	base := fmt.tprintf("quesynth-nameless-%d.sy1", posix.getpid())
	path := fmt.tprintf("/tmp/%s", base)
	testing.expect(t, os.write_entire_file_from_string(path, "color=default\r\nver=113\r\n0,3\r\n") == nil)
	defer os.remove(path)
	testing.expect(t, strings.has_prefix(ask(&b.cc, fmt.tprintf("1 3 patch.load_file %s", path)), "1 3 ok"))
	testing.expect_value(t, ask(&b.cc, "1 4 patch.current"), current_reply(4, -1, 0, 0, "file", base))
}

@(test)
test_archive_load_names_the_archive_bank :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	ask(&b.cc, "1 1 archive.open tests/zip/fixtures/nested.zip")
	ask(&b.cc, "1 2 archive.bank 0")

	// banks/bankA.zip holds 001.sy1 and 002.sy1, named "Synth1 Test Patch One"
	// and "Synth1 Test Patch Two" on their first lines.
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 3 archive.load 1"), "1 3 ok"))
	want := current_reply(4, -1, 0, 0, "bankA.zip", "Test Patch Two")
	testing.expect_value(t, ask(&b.cc, "1 4 patch.current"), want)

	// The names were copied, not borrowed from the archive: closing it, which
	// frees everything the archive read, leaves them intact.
	ask(&b.cc, "1 5 archive.close")
	testing.expect_value(t, ask(&b.cc, "1 4 patch.current"), want)
}

@(test)
test_patch_save_names_the_slot_and_bumps_bank_rev :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)

	testing.expect_value(t, ask(&b.cc, "1 1 patch.save 120 My Lead"), "1 1 ok slot=120 name=My_Lead bank_rev=1")
	testing.expect_value(t, ask(&b.cc, "1 2 patch.current"), current_reply(2, 120, 1, 0, "Factory", "My Lead"))

	// With no name an empty slot is saved as what the bank already calls it.
	testing.expect_value(t, ask(&b.cc, "1 3 patch.save 121"), "1 3 ok slot=121 name=Init bank_rev=2")
	testing.expect_value(t, ask(&b.cc, "1 4 patch.current"), current_reply(4, 121, 2, 0, "Factory", "Init"))
}

@(test)
test_bank_load_file_bumps_bank_rev_and_forgets_the_slot :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	k := spaced_factory_slot(&b.bank)
	if !testing.expect(t, k >= 0) {return}
	ask(&b.cc, fmt.tprintf("1 1 patch.load %d", k))

	src := new(patch.Slots)
	defer free(src)
	patch.slots_load_factory(src)
	filled := 0
	for i in 0 ..< patch.FACTORY_SLOTS {
		if src.filled[i] {filled += 1}
	}
	path := fmt.tprintf("/tmp/quesynth-idbank-%d.json", posix.getpid())
	testing.expect(t, os.write_entire_file_from_string(path, patch.slots_write_json(src, context.temp_allocator)) == nil)
	defer os.remove(path)

	reply := ask(&b.cc, fmt.tprintf("1 2 bank.load_file %s", path))
	testing.expect_value(t, reply, fmt.tprintf("1 2 ok label=Factory count=%d bank_rev=1", filled))
	// The sound is still the one it was, so it keeps its names; only the slot
	// number, which now indexes another bank, is gone.
	testing.expect_value(t, ask(&b.cc, "1 3 patch.current"), current_reply(3, -1, 1, 0, "Factory", patch.factory_name(k)))
}

@(test)
test_failed_and_unrelated_commands_leave_identity_alone :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	k := spaced_factory_slot(&b.bank)
	if !testing.expect(t, k >= 0) {return}
	ask(&b.cc, fmt.tprintf("1 1 patch.load %d", k))
	drain(&b.ring)
	ask(&b.cc, "1 2 patch.save 120 Kept")
	want := current_reply(9, 120, 1, 0, "Factory", "Kept")
	testing.expect_value(t, ask(&b.cc, "1 9 patch.current"), want)

	failing := []string {
		"1 3 patch.load 9999",
		"1 3 patch.load 121",
		"1 3 patch.load",
		"1 3 patch.load_file /tmp/quesynth-no-such-patch.sy1",
		"1 3 patch.load_file tests/zip/fixtures/nested.zip",
		"1 3 patch.save 999 Nope",
		"1 3 patch.save",
		"1 3 bank.load_file /tmp/quesynth-no-such-bank.json",
		"1 3 archive.load 0",
	}
	for line in failing {
		testing.expectf(t, strings.has_prefix(ask(&b.cc, line), "1 3 err"), "%s should fail", line)
		testing.expect_value(t, ask(&b.cc, "1 9 patch.current"), want)
	}

	// A load the audio side has no room for is refused whole, and names nothing.
	for _ in 0 ..< 200 {standalone.param_ring_push(&b.ring, standalone.Param_Command{kind = .Commit})}
	testing.expect(t, strings.has_prefix(ask(&b.cc, fmt.tprintf("1 4 patch.load %d", k)), "1 4 err daemon_not_ready"))
	testing.expect_value(t, ask(&b.cc, "1 9 patch.current"), want)
	drain(&b.ring)

	// A knob tweak edits the sound; it does not rename the patch.
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 5 parameter.set filter.cutoff 40"), "1 5 ok"))
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 6 parameter.set_many filter.cutoff 50 filter.resonance 30"), "1 6 ok"))
	testing.expect_value(t, ask(&b.cc, "1 9 patch.current"), want)
}

@(test)
test_patch_clear_forgets_the_name_only :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	ask(&b.cc, "1 1 patch.save 120 Named")
	drain(&b.ring)

	testing.expect_value(t, ask(&b.cc, "1 2 patch.clear"), "1 2 ok")
	// bank_rev stays: the bank did not change. Nothing reached the audio side.
	testing.expect_value(t, ask(&b.cc, "1 3 patch.current"), current_reply(3, -1, 1, 0, "", ""))
	_, queued := standalone.param_ring_pop(&b.ring)
	testing.expect(t, !queued)
}

@(test)
test_identity_is_optional_for_a_bare_handler :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	b.cc.identity = nil
	k := spaced_factory_slot(&b.bank)
	if !testing.expect(t, k >= 0) {return}

	testing.expect_value(t, ask(&b.cc, "1 1 patch.current"), "1 1 err daemon_not_ready no bank")
	testing.expect_value(t, ask(&b.cc, "1 2 patch.clear"), "1 2 err daemon_not_ready no bank")
	// The commands that would update it still work, and say nothing of bank_rev.
	testing.expect(t, strings.has_prefix(ask(&b.cc, fmt.tprintf("1 3 patch.load %d", k)), "1 3 ok"))
	drain(&b.ring)
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 4 patch.load_file tools/s1probe/fixtures/unison-four.sy1"), "1 4 ok"))
	drain(&b.ring)
	testing.expect_value(t, ask(&b.cc, "1 5 patch.save 120 X"), "1 5 ok slot=120 name=X")
	ask(&b.cc, "1 6 archive.open tests/zip/fixtures/nested.zip")
	ask(&b.cc, "1 7 archive.bank 0")
	testing.expect(t, strings.has_prefix(ask(&b.cc, "1 8 archive.load 0"), "1 8 ok"))
}

// One test for every bank.keep case, because each points XDG_CONFIG_HOME
// somewhere else and the environment is shared by the whole test process.
@(test)
test_bank_keep_writes_the_bank_the_daemon_starts_with :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	root := fmt.tprintf("/tmp/quesynth-keep-%d", posix.getpid())
	defer os.remove_all(root)
	old_xdg, had_xdg := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	old_home, had_home := os.lookup_env("HOME", context.temp_allocator)
	defer {
		if had_xdg {os.set_env("XDG_CONFIG_HOME", old_xdg)} else {os.unset_env("XDG_CONFIG_HOME")}
		if had_home {os.set_env("HOME", old_home)} else {os.unset_env("HOME")}
	}

	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(i % 7)}
	standalone.snapshot_publish(&b.snap, seed)
	ask(&b.cc, "1 1 patch.save 120 Kept Sound")

	// Neither the directory nor its parent exists yet, and the path has a space.
	cfg := fmt.tprintf("%s/config home", root)
	os.set_env("XDG_CONFIG_HOME", cfg)
	path := fmt.tprintf("%s/quesynth/bank.json", cfg)
	reply := ask(&b.cc, "1 2 bank.keep")
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, rerr == nil, "bank.keep must write $XDG_CONFIG_HOME/quesynth/bank.json") {return}
	testing.expect_value(t, reply, fmt.tprintf("1 2 ok bytes=%d path=%s", len(data), path))
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)), "no temporary left behind")

	// Read back by the bank parser, and by the loader the daemon starts with.
	parsed, perr := patch.parse_bank_json(data, context.temp_allocator)
	if testing.expect(t, perr == .None && len(parsed.patches) > 120) {
		testing.expect_value(t, parsed.patches[120].name, "Kept Sound")
		for i in 0 ..< patch.PARAMETER_COUNT {
			testing.expect_value(t, parsed.patches[120].values[i], i % 7)
		}
	}
	restarted := new(patch.Slots)
	defer free(restarted)
	testing.expect(t, standalone.load_bank_file(restarted, path))
	testing.expect_value(t, patch.slots_name(restarted, 120), "Kept Sound")
	// Keeping the bank does not change it.
	testing.expect_value(t, ask(&b.cc, "1 3 patch.current"), current_reply(3, 120, 1, 0, "Factory", "Kept Sound"))

	// An unwritable config directory: here a regular file stands in its way.
	blocker := fmt.tprintf("%s/not-a-dir", root)
	testing.expect(t, os.write_entire_file_from_string(blocker, "x") == nil)
	os.set_env("XDG_CONFIG_HOME", blocker)
	testing.expect_value(t, ask(&b.cc, "1 4 bank.keep"), "1 4 err internal_error cannot write file")

	// Nowhere to derive a config directory from at all.
	os.unset_env("XDG_CONFIG_HOME")
	os.unset_env("HOME")
	testing.expect_value(t, ask(&b.cc, "1 5 bank.keep"), "1 5 err internal_error no config directory")

	b.cc.bank = nil
	testing.expect_value(t, ask(&b.cc, "1 6 bank.keep"), "1 6 err daemon_not_ready no bank")
}
