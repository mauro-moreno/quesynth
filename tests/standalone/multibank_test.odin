#+build linux
package standalone_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import control "../../src/control"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// The archive as one more bank every front-end shares: what is open, which bank
// of it is open, where the playing patch came from, and the path the daemon
// reopens at startup. The expected replies are the wire format the protocol
// contract spells out; the expected names and values come from the fixture's
// own bytes, written by Python's zipfile rather than by anything here:
//
//   tests/standalone/fixtures/banks.zip
//     banks/Alpha.zip        stored    Alpha/ (directory), Alpha/001.sy1
//                                      "Alpha One" (0,1,2 = 1,10,20),
//                                      Alpha/readme.txt, Alpha/002.sy1
//                                      "Alpha Two" (2,20,30)
//     notes.txt              stored    not a bank
//     banks/Beta Bank.zip    deflated  001.sy1 "Beta One" (3,30,40), 002.sy1
//                                      "Beta Two" (0,40,50), 003.sy1 "Beta
//                                      Three" (1,50,60)

@(private = "file")
BANKS :: "tests/standalone/fixtures/banks.zip"

@(private = "file")
Multi :: struct {
	ring:     standalone.Param_Ring,
	snap:     standalone.Snapshot,
	state:    standalone.Daemon_State,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	archive:  standalone.Archive,
	cc:       standalone.Control_Context,
}

@(private = "file")
multi_make :: proc() -> ^Multi {
	m := new(Multi)
	patch.factory_prepare()
	patch.slots_load_factory(&m.bank)
	m.state = .Running
	m.identity = standalone.Patch_Identity{slot = -1}
	m.cc = standalone.Control_Context {
		ring     = &m.ring,
		snapshot = &m.snap,
		state    = &m.state,
		bank     = &m.bank,
		archive  = &m.archive,
		identity = &m.identity,
	}
	return m
}

@(private = "file")
multi_free :: proc(m: ^Multi) {
	standalone.archive_close(&m.archive)
	free(m)
}

@(private = "file")
multi_ask :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

// What the audio thread would take off the ring: each Set, then the commit.
@(private = "file")
multi_drain :: proc(r: ^standalone.Param_Ring) -> (sets: [dynamic]standalone.Param_Command, commits: int) {
	sets.allocator = context.temp_allocator
	for {
		cmd, ok := standalone.param_ring_pop(r)
		if !ok {break}
		if cmd.kind == .Set {append(&sets, cmd)} else {commits += 1}
	}
	return
}

@(private = "file")
archive_reply :: proc(id: int, open: int, banks, bank, patches: int, rev: uint, path, bank_name: string) -> string {
	return fmt.tprintf(
		"1 %d ok open=%d banks=%d bank=%d patches=%d archive_rev=%d\npath=%s\nbank_name=%s",
		id, open, banks, bank, patches, rev, path, bank_name,
	)
}

@(private = "file")
provenance :: proc(
	id, slot: int,
	bank_rev: uint,
	source: string,
	archive_rev: uint,
	archive_bank, archive_patch: int,
	bank, name: string,
) -> string {
	return fmt.tprintf(
		"1 %d ok slot=%d bank_rev=%d revision=0 source=%s archive_rev=%d archive_bank=%d archive_patch=%d\nbank=%s\nname=%s",
		id, slot, bank_rev, source, archive_rev, archive_bank, archive_patch, bank, name,
	)
}

@(test)
test_archive_current_follows_what_is_open :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	cc := &m.cc

	testing.expect_value(t, multi_ask(cc, "1 1 archive.current"), archive_reply(1, 0, 0, -1, 0, 0, "", ""))

	testing.expect_value(t, multi_ask(cc, fmt.tprintf("1 2 archive.open %s", BANKS)), "1 2 ok banks=2 archive_rev=1")
	testing.expect_value(t, multi_ask(cc, "1 3 archive.current"), archive_reply(3, 1, 2, -1, 0, 1, BANKS, ""))
	testing.expect_value(t, multi_ask(cc, "1 4 archive.banks 0 10"),
		"1 4 ok total=2 archive_rev=1\nbank=0 name=Alpha.zip\nbank=1 name=Beta Bank.zip")

	testing.expect_value(t, multi_ask(cc, "1 5 archive.bank 1"), "1 5 ok patches=3 bank=1 archive_rev=2")
	testing.expect_value(t, multi_ask(cc, "1 6 archive.current"), archive_reply(6, 1, 2, 1, 3, 2, BANKS, "Beta Bank.zip"))
	testing.expect_value(t, multi_ask(cc, "1 7 archive.patches 0 10"),
		"1 7 ok total=3 bank=1 archive_rev=2\npatch=0 name=Beta One\npatch=1 name=Beta Two\npatch=2 name=Beta Three")

	// The bank already open is no change, so no peer is sent to re-read it.
	testing.expect_value(t, multi_ask(cc, "1 8 archive.bank 1"), "1 8 ok patches=3 bank=1 archive_rev=2")
	testing.expect_value(t, multi_ask(cc, "1 9 archive.bank 0"), "1 9 ok patches=2 bank=0 archive_rev=3")
	// A bank that is not there changes nothing either.
	testing.expect_value(t, multi_ask(cc, "1 10 archive.bank 2"), "1 10 err invalid_payload cannot open that bank")
	testing.expect_value(t, multi_ask(cc, "1 11 archive.current"), archive_reply(11, 1, 2, 0, 2, 3, BANKS, "Alpha.zip"))

	// Closing forgets the path too; closing nothing is no change.
	testing.expect_value(t, multi_ask(cc, "1 12 archive.close"), "1 12 ok archive_rev=4")
	testing.expect_value(t, multi_ask(cc, "1 13 archive.current"), archive_reply(13, 0, 0, -1, 0, 4, "", ""))
	testing.expect_value(t, multi_ask(cc, "1 14 archive.close"), "1 14 ok archive_rev=4")
	testing.expect_value(t, multi_ask(cc, "1 15 archive.open"), "1 15 err invalid_payload open needs a path")

	cc.archive = nil
	testing.expect_value(t, multi_ask(cc, "1 16 archive.current"), "1 16 err daemon_not_ready no archive support")
}

@(test)
test_a_failed_archive_open_keeps_the_open_archive :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	cc := &m.cc
	multi_ask(cc, fmt.tprintf("1 1 archive.open %s", BANKS))
	multi_ask(cc, "1 2 archive.bank 1")
	before := archive_reply(9, 1, 2, 1, 3, 2, BANKS, "Beta Bank.zip")
	testing.expect_value(t, multi_ask(cc, "1 9 archive.current"), before)

	// A missing file, and a file that is no zip: another client's mistake must
	// not take this archive away from whoever is browsing it.
	missing := fmt.tprintf("1 3 archive.open /tmp/quesynth-no-such-archive-%d.zip", posix.getpid())
	testing.expect_value(t, multi_ask(cc, missing), "1 3 err invalid_payload cannot open archive")
	testing.expect_value(t, multi_ask(cc, "1 4 archive.open tools/s1probe/fixtures/unison-four.sy1"),
		"1 4 err invalid_payload cannot open archive")
	testing.expect_value(t, multi_ask(cc, "1 9 archive.current"), before)
	testing.expect(t, strings.has_suffix(multi_ask(cc, "1 5 archive.patches 2 1"), "\npatch=2 name=Beta Three"))
	testing.expect(t, strings.has_prefix(multi_ask(cc, "1 6 archive.load 2"), "1 6 ok count=3 revision=0 bank=1 patch=2"))
}

@(test)
test_archive_open_without_a_path_reopens_the_remembered_one :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	cc := &m.cc
	multi_ask(cc, fmt.tprintf("1 1 archive.open %s", BANKS))
	multi_ask(cc, "1 2 archive.bank 1")
	testing.expect_value(t, multi_ask(cc, "1 3 archive.open"), "1 3 ok banks=2 archive_rev=3")
	testing.expect_value(t, multi_ask(cc, "1 4 archive.current"), archive_reply(4, 1, 2, -1, 0, 3, BANKS, ""))
}

@(test)
test_archive_load_opens_the_bank_the_client_shows :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	cc := &m.cc
	multi_ask(cc, fmt.tprintf("1 1 archive.open %s", BANKS))
	multi_ask(cc, "1 2 archive.bank 0")

	// The client lists Beta Bank while the open bank is Alpha: the patch its
	// list names is Beta Two, not Alpha Two.
	testing.expect_value(t, multi_ask(cc, "1 3 archive.load 1 1"), "1 3 ok count=3 revision=0 bank=1 patch=1")
	sets, commits := multi_drain(&m.ring)
	testing.expect_value(t, len(sets), 3)
	testing.expect_value(t, commits, 1)
	want := [3]i32{0, 40, 50}
	for cmd, k in sets {
		testing.expect_value(t, int(cmd.index), k)
		testing.expect_value(t, cmd.stored, want[k])
	}
	testing.expect_value(t, multi_ask(cc, "1 4 archive.current"), archive_reply(4, 1, 2, 1, 3, 3, BANKS, "Beta Bank.zip"))

	// The bank already open: no change to count.
	testing.expect_value(t, multi_ask(cc, "1 5 archive.load 0 1"), "1 5 ok count=3 revision=0 bank=1 patch=0")
	multi_drain(&m.ring)
	// One operand loads from the open bank, as it always did.
	testing.expect_value(t, multi_ask(cc, "1 6 archive.load 2"), "1 6 ok count=3 revision=0 bank=1 patch=2")
	multi_drain(&m.ring)
	testing.expect_value(t, multi_ask(cc, "1 7 archive.current"), archive_reply(7, 1, 2, 1, 3, 3, BANKS, "Beta Bank.zip"))

	// A bank that cannot be opened loads nothing and leaves the open bank.
	testing.expect_value(t, multi_ask(cc, "1 8 archive.load 0 7"), "1 8 err invalid_payload cannot open that bank")
	testing.expect_value(t, multi_ask(cc, "1 9 archive.load 0 x"), "1 9 err invalid_payload cannot open that bank")
	sets, commits = multi_drain(&m.ring)
	testing.expect_value(t, len(sets) + commits, 0)
	testing.expect_value(t, multi_ask(cc, "1 10 archive.current"), archive_reply(10, 1, 2, 1, 3, 3, BANKS, "Beta Bank.zip"))
	testing.expect_value(t, multi_ask(cc, "1 11 patch.current"), provenance(11, -1, 0, "archive", 3, 1, 2, "Beta Bank.zip", "Beta Three"))

	// With no archive open there is no bank to name.
	multi_ask(cc, "1 12 archive.close")
	testing.expect_value(t, multi_ask(cc, "1 13 archive.load 0 0"), "1 13 err daemon_not_ready no archive open")
	testing.expect_value(t, multi_ask(cc, "1 14 archive.load 0"), "1 14 err daemon_not_ready no bank open")
}

@(test)
test_provenance_is_where_the_sound_came_from_not_what_is_browsed :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	cc := &m.cc
	k := -1
	for i in 0 ..< patch.FACTORY_SLOTS {
		if m.bank.filled[i] {k = i; break}
	}
	if !testing.expect(t, k >= 0) {return}

	multi_ask(cc, fmt.tprintf("1 1 archive.open %s", BANKS))
	multi_ask(cc, "1 2 archive.bank 1")
	testing.expect(t, strings.has_prefix(multi_ask(cc, "1 3 archive.load 2"), "1 3 ok"))
	multi_drain(&m.ring)
	playing := provenance(9, -1, 0, "archive", 2, 1, 2, "Beta Bank.zip", "Beta Three")
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), playing)

	// Browsing another bank, and listing it, moves what is open but not where
	// the sound came from.
	multi_ask(cc, "1 4 archive.bank 0")
	multi_ask(cc, "1 5 archive.patches 0 10")
	multi_ask(cc, "1 5 archive.banks 0 10")
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 0, "archive", 3, 1, 2, "Beta Bank.zip", "Beta Three"))
	quiet, commits := multi_drain(&m.ring)
	testing.expect_value(t, len(quiet) + commits, 0)

	// The ordinary bank is replaced: the sound is still the archive's.
	path := fmt.tprintf("/tmp/quesynth-multibank-%d.json", posix.getpid())
	testing.expect(t, os.write_entire_file_from_string(path, patch.slots_write_json(&m.bank, context.temp_allocator)) == nil)
	defer os.remove(path)
	testing.expect(t, strings.has_prefix(multi_ask(cc, fmt.tprintf("1 6 bank.load_file %s", path)), "1 6 ok"))
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 1, "archive", 3, 1, 2, "Beta Bank.zip", "Beta Three"))

	// Reopening the archive, even the same one, stops pointing into it; the
	// names stay, because they still say what is playing.
	multi_ask(cc, fmt.tprintf("1 7 archive.open %s", BANKS))
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 1, "archive", 4, -1, -1, "Beta Bank.zip", "Beta Three"))
	testing.expect(t, strings.has_prefix(multi_ask(cc, "1 8 archive.load 1 0"), "1 8 ok"))
	multi_drain(&m.ring)
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 1, "archive", 5, 0, 1, "Alpha.zip", "Alpha Two"))
	multi_ask(cc, "1 10 archive.close")
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 1, "archive", 6, -1, -1, "Alpha.zip", "Alpha Two"))

	// The other sources, each with its own name, and none points into an archive.
	multi_ask(cc, fmt.tprintf("1 11 archive.open %s", BANKS))
	multi_ask(cc, "1 12 archive.load 0 0")
	multi_drain(&m.ring)
	testing.expect(t, strings.has_prefix(multi_ask(cc, fmt.tprintf("1 13 patch.load %d", k)), "1 13 ok"))
	multi_drain(&m.ring)
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"),
		provenance(9, k, 1, "bank", 8, -1, -1, patch.slots_label(&m.bank), patch.slots_name(&m.bank, k)))
	testing.expect(t, strings.has_prefix(multi_ask(cc, "1 14 patch.load_file tools/s1probe/fixtures/unison-four.sy1"), "1 14 ok"))
	multi_drain(&m.ring)
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 1, "file", 8, -1, -1, "file", "unison four reference fixture"))
	testing.expect(t, strings.has_prefix(multi_ask(cc, "1 15 patch.save 120 Kept"), "1 15 ok"))
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, 120, 2, "bank", 8, -1, -1, patch.slots_label(&m.bank), "Kept"))
	testing.expect_value(t, multi_ask(cc, "1 16 patch.clear"), "1 16 ok")
	testing.expect_value(t, multi_ask(cc, "1 9 patch.current"), provenance(9, -1, 2, "none", 8, -1, -1, "", ""))
	// None of them moved the archive.
	testing.expect_value(t, multi_ask(cc, "1 17 archive.current"), archive_reply(17, 1, 2, 0, 2, 8, BANKS, "Alpha.zip"))
}

// The path is kept in a file of the test's own, never the user's: only
// run_daemon points an archive at the config directory.
@(test)
test_the_archive_path_is_kept_for_the_next_start :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/quesynth-archive-keep-%d", posix.getpid())
	defer os.remove_all(root)
	keep := fmt.tprintf("%s/config dir/quesynth/archive.path", root)

	first := multi_make()
	defer multi_free(first)
	// Nothing kept yet: nothing to open, nothing remembered.
	standalone.archive_restore(&first.archive, keep)
	testing.expect_value(t, multi_ask(&first.cc, "1 1 archive.current"), archive_reply(1, 0, 0, -1, 0, 0, "", ""))

	// Kept as given -- relative, unnormalised -- with the directory made for it.
	multi_ask(&first.cc, fmt.tprintf("1 2 archive.open %s", BANKS))
	data, err := os.read_entire_file(keep, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), BANKS + "\n")

	// The next start reopens it; reopening is not a change anyone missed.
	second := multi_make()
	defer multi_free(second)
	standalone.archive_restore(&second.archive, keep)
	testing.expect_value(t, multi_ask(&second.cc, "1 3 archive.current"), archive_reply(3, 1, 2, -1, 0, 0, BANKS, ""))

	// A handler with nowhere to keep the path writes nothing, here or anywhere.
	other := multi_make()
	defer multi_free(other)
	multi_ask(&other.cc, fmt.tprintf("1 4 archive.open %s", FIXTURE_NESTED))
	data, err = os.read_entire_file(keep, context.temp_allocator)
	testing.expect_value(t, string(data), BANKS + "\n")

	// Closing forgets it for good.
	multi_ask(&first.cc, "1 5 archive.close")
	testing.expect(t, !os.exists(keep))

	// A kept archive that does not open -- an unmounted disk -- stays kept and
	// remembered, so it is tried again rather than forgotten.
	missing := fmt.tprintf("%s/elsewhere/gone.zip", root)
	testing.expect(t, os.write_entire_file_from_string(keep, fmt.tprintf("%s\n", missing)) == nil)
	third := multi_make()
	defer multi_free(third)
	standalone.archive_restore(&third.archive, keep)
	testing.expect_value(t, multi_ask(&third.cc, "1 6 archive.current"), archive_reply(6, 0, 0, -1, 0, 0, missing, ""))
	testing.expect_value(t, multi_ask(&third.cc, "1 7 archive.open"), "1 7 err invalid_payload cannot open archive")
	data, err = os.read_entire_file(keep, context.temp_allocator)
	testing.expect_value(t, string(data), fmt.tprintf("%s\n", missing))

	// Forgetting one that never opened is still a change, and nothing is kept.
	testing.expect_value(t, multi_ask(&third.cc, "1 8 archive.close"), "1 8 ok archive_rev=1")
	testing.expect_value(t, multi_ask(&third.cc, "1 9 archive.current"), archive_reply(9, 0, 0, -1, 0, 1, "", ""))
	testing.expect(t, !os.exists(keep))
}

@(private = "file")
FIXTURE_NESTED :: "tests/zip/fixtures/nested.zip"

// Two clients on one real control server. One browses and loads from the
// archive; everything the other does to the ordinary bank and the sound --
// including a keyboard's Program Change, which needs no client -- leaves the
// archive, its open bank and its path where they were.
@(test)
test_peers_share_the_archive_and_ordinary_changes_leave_it_open :: proc(t: ^testing.T) {
	m := multi_make()
	defer multi_free(m)
	queue: standalone.Midi_Queue
	standalone.midi_queue_init(&queue)
	program := standalone.Program_Select{queue = &queue}
	m.cc.program = &program
	cs := standalone.Control_Server{path = fmt.tprintf("/tmp/quesynth-multibank-%d.sock", posix.getpid()), ctx = m.cc}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	a, aok := connect_unix(cs.path)
	b, bok := connect_unix(cs.path)
	if !testing.expect(t, aok && bok) {return}
	defer {posix.close(a); posix.close(b)}
	say :: proc(fd: posix.FD, line: string) -> string {
		reliability_send(fd, line)
		return reliability_reply(fd)
	}
	// Closed by the server thread that opened it, so it is freed with the
	// allocator that made it.
	defer say(a, "1 99 archive.close")

	testing.expect_value(t, say(a, fmt.tprintf("1 1 archive.open %s", BANKS)), "1 1 ok banks=2 archive_rev=1")
	testing.expect_value(t, say(a, "1 2 archive.bank 1"), "1 2 ok patches=3 bank=1 archive_rev=2")
	testing.expect_value(t, say(a, "1 3 archive.load 2 1"), "1 3 ok count=3 revision=0 bank=1 patch=2")
	multi_drain(&m.ring)

	open := archive_reply(1, 1, 2, 1, 3, 2, BANKS, "Beta Bank.zip")
	testing.expect_value(t, say(b, "1 1 archive.current"), open)
	testing.expect_value(t, say(b, "1 2 patch.current"), provenance(2, -1, 0, "archive", 2, 1, 2, "Beta Bank.zip", "Beta Three"))

	path := fmt.tprintf("/tmp/quesynth-multibank-peer-%d.json", posix.getpid())
	testing.expect(t, os.write_entire_file_from_string(path, patch.slots_write_json(&m.bank, context.temp_allocator)) == nil)
	defer os.remove(path)
	ordinary := []string {
		"1 3 patch.load 3",
		"1 4 patch.save 120 Peer Save",
		fmt.tprintf("1 5 bank.load_file %s", path),
		"1 6 patch.load_file tools/s1probe/fixtures/unison-four.sy1",
		"1 7 patch.apply filter.cutoff 40",
		"1 8 patch.clear",
	}
	for line in ordinary {
		testing.expectf(t, strings.contains(say(b, line), " ok"), "%s should succeed", line)
		multi_drain(&m.ring)
		testing.expectf(t, say(a, "1 1 archive.current") == open, "%s moved the archive", line)
	}

	// A keyboard selects slot 5 on channel 1. The server loads it on its own
	// poll tick; the archive stays where it was.
	testing.expect(t, standalone.midi_queue_push(&queue, standalone.midi_pack(0xC0, 5, 0)))
	deadline := time.tick_now()
	current := ""
	for time.tick_since(deadline) < time.Second {
		multi_drain(&m.ring)
		current = say(b, "1 9 patch.current")
		if strings.has_prefix(current, "1 9 ok slot=5 ") {break}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, strings.has_prefix(current, "1 9 ok slot=5 bank_rev=2 revision=0 source=bank archive_rev=2 archive_bank=-1 archive_patch=-1\n"), current)
	testing.expect_value(t, say(a, "1 1 archive.current"), open)

	// And the other way: B browses, A sees the open bank move and the
	// generation with it, while the sound's provenance stays the slot.
	testing.expect_value(t, say(b, "1 10 archive.bank 0"), "1 10 ok patches=2 bank=0 archive_rev=3")
	testing.expect_value(t, say(a, "1 1 archive.current"), archive_reply(1, 1, 2, 0, 2, 3, BANKS, "Alpha.zip"))
	testing.expect(t, strings.has_prefix(say(a, "1 9 patch.current"), "1 9 ok slot=5 bank_rev=2 revision=0 source=bank archive_rev=3 archive_bank=-1 archive_patch=-1\n"))
	testing.expect_value(t, say(a, "1 11 archive.patches 0 2"), "1 11 ok total=2 bank=0 archive_rev=3\npatch=0 name=Alpha One\npatch=1 name=Alpha Two")
}
