#+build linux
package tui_tests

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import patch "../../src/patch"
import registry "../../src/registry"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The bank navigator: the daemon's ordinary bank and the open archive's banks
// as one list, each opened onto its patches, beside the provenance of the
// sound, which browsing never changes. The wire replies are written out by
// hand in the format the protocol contract gives, and the screens are held to
// the lines the contract asks for, so the client and the navigator are checked
// against the contract rather than against the code that produces their input.
//
// The archive is tests/standalone/fixtures/banks.zip, whose bytes
// tests/standalone/multibank_test.odin describes: banks/Alpha.zip holds
// "Alpha One" and "Alpha Two", banks/Beta Bank.zip "Beta One", "Beta Two" and
// "Beta Three".

@(private = "file")
BANKS :: "tests/standalone/fixtures/banks.zip"

// Framing written out by hand -- the documented little-endian u32 length,
// then the payload -- rather than borrowed from the codec.
@(private = "file")
put_frame :: proc(fd: posix.FD, text: string) {
	n := len(text)
	header := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fd, raw_data(header[:]), 4, {.NOSIGNAL})
	posix.send(fd, raw_data(text), c.size_t(n), {.NOSIGNAL})
}

// The next frame's payload, or "" when none arrives within a second.
@(private = "file")
take_frame :: proc(fd: posix.FD) -> string {
	header: [4]u8
	if !take_exact(fd, header[:]) {return ""}
	n := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	text := make([]u8, n, context.temp_allocator)
	if !take_exact(fd, text) {return ""}
	return string(text)
}

@(private = "file")
take_exact :: proc(fd: posix.FD, data: []u8) -> bool {
	at := 0
	for at < len(data) {
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&fds[0], 1, 1000) <= 0 {return false}
		remaining := len(data) - at
		n := posix.read(fd, raw_data(data[at:]), c.size_t(remaining))
		if n <= 0 {return false}
		at += int(n)
	}
	return true
}

// A client whose next request is answered with `reply` from the far end of a
// socket pair, where the test also reads what the client sent. The caller
// closes `far`.
@(private = "file")
answering :: proc(reply: string) -> (client: tui.Client, far: posix.FD) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK {return tui.Client{fd = -1}, -1}
	put_frame(fds[1], reply)
	return tui.Client{fd = fds[0], next_id = 1}, fds[1]
}

@(test)
test_client_provenance_reads_where_the_sound_came_from :: proc(t: ^testing.T) {
	Case :: struct {
		reply:                       string,
		source:                      tui.Source,
		slot, a_bank, a_patch:       int,
		archive_rev, bank_rev:       uint,
		bank, name:                  string,
	}
	cases := []Case {
		{
			"1 1 ok slot=-1 bank_rev=2 revision=5 source=archive archive_rev=3 archive_bank=1 archive_patch=2\nbank=Beta Bank.zip\nname=Beta Three",
			.Archive, -1, 1, 2, 3, 2, "Beta Bank.zip", "Beta Three",
		},
		// From an archive since closed: the names still say what plays, but
		// the indices point into nothing.
		{
			"1 1 ok slot=-1 bank_rev=2 revision=5 source=archive archive_rev=4 archive_bank=-1 archive_patch=-1\nbank=Beta Bank.zip\nname=Beta Three",
			.Archive, -1, -1, -1, 4, 2, "Beta Bank.zip", "Beta Three",
		},
		{
			"1 1 ok slot=5 bank_rev=0 revision=1 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=My  Bank \nname=Solo Lead",
			.Bank, 5, -1, -1, 0, 0, "My  Bank ", "Solo Lead",
		},
		{
			"1 1 ok slot=-1 bank_rev=0 revision=1 source=file archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=file\nname=unison four reference fixture",
			.File, -1, -1, -1, 0, 0, "file", "unison four reference fixture",
		},
		{
			"1 1 ok slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
			.None, -1, -1, -1, 0, 0, "", "",
		},
		// A daemon from before the shared archive sends none of the later
		// fields: no source and no archive, never a guessed one.
		{"1 1 ok slot=7 bank_rev=3 revision=12\nbank=Factory\nname=Lead", .None, 7, -1, -1, 0, 3, "Factory", "Lead"},
	}
	for want in cases {
		client, far := answering(want.reply)
		p, ok := tui.client_provenance(&client)
		testing.expect(t, ok, want.reply)
		testing.expect_value(t, take_frame(far), "1 1 patch.current")
		testing.expect_value(t, p.source, want.source)
		testing.expect_value(t, p.slot, want.slot)
		testing.expect_value(t, p.archive_bank, want.a_bank)
		testing.expect_value(t, p.archive_patch, want.a_patch)
		testing.expect_value(t, p.archive_rev, want.archive_rev)
		testing.expect_value(t, p.bank_rev, want.bank_rev)
		testing.expect_value(t, p.bank, want.bank)
		testing.expect_value(t, p.name, want.name)
		tui.provenance_free(&p)
		tui.client_close(&client)
		posix.close(far)
	}
}

@(test)
test_client_archive_current_reads_the_shared_archive :: proc(t: ^testing.T) {
	Case :: struct {
		reply:                   string,
		open:                    bool,
		banks, bank, patches:    int,
		rev:                     uint,
		path, bank_name:         string,
	}
	cases := []Case {
		// The path is raw to the line end, its spaces kept.
		{
			"1 1 ok open=1 banks=2 bank=1 patches=3 archive_rev=7\npath=/tmp/My  Banks.zip \nbank_name=Beta Bank.zip",
			true, 2, 1, 3, 7, "/tmp/My  Banks.zip ", "Beta Bank.zip",
		},
		{"1 1 ok open=1 banks=2 bank=-1 patches=0 archive_rev=1\npath=" + BANKS + "\nbank_name=", true, 2, -1, 0, 1, BANKS, ""},
		// Remembered but not open: the zip may be on a disk not mounted yet.
		{"1 1 ok open=0 banks=0 bank=-1 patches=0 archive_rev=0\npath=/media/usb/gone.zip\nbank_name=", false, 0, -1, 0, 0, "/media/usb/gone.zip", ""},
		{"1 1 ok open=0 banks=0 bank=-1 patches=0 archive_rev=4\npath=\nbank_name=", false, 0, -1, 0, 4, "", ""},
	}
	for want in cases {
		client, far := answering(want.reply)
		state, ok := tui.client_archive_current(&client)
		testing.expect(t, ok, want.reply)
		testing.expect_value(t, take_frame(far), "1 1 archive.current")
		testing.expect_value(t, state.open, want.open)
		testing.expect_value(t, state.banks, want.banks)
		testing.expect_value(t, state.bank, want.bank)
		testing.expect_value(t, state.patches, want.patches)
		testing.expect_value(t, state.rev, want.rev)
		testing.expect_value(t, state.path, want.path)
		testing.expect_value(t, state.bank_name, want.bank_name)
		tui.archive_state_free(&state)
		tui.client_close(&client)
		posix.close(far)
	}

	// A daemon with no archive, or one from before archive.current: a refusal,
	// not a disconnect, and nothing open.
	for reply in ([2]string{"1 1 err daemon_not_ready no archive support", "1 1 err unknown_command unknown command"}) {
		client, far := answering(reply)
		state, ok := tui.client_archive_current(&client)
		testing.expect(t, !ok, reply)
		testing.expect(t, !state.open, reply)
		testing.expect_value(t, state.bank, -1)
		testing.expect(t, client.fd >= 0, reply)
		tui.client_close(&client)
		posix.close(far)
	}
}

// What the client puts on the wire for the archive requests it changed.
@(test)
test_client_archive_requests_name_the_bank_shown :: proc(t: ^testing.T) {
	client, far := answering("1 1 ok count=3 revision=0 bank=2 patch=7")
	defer posix.close(far)
	defer tui.client_close(&client)
	testing.expect(t, tui.client_archive_load(&client, 7, 2))
	testing.expect_value(t, take_frame(far), "1 1 archive.load 7 2")

	// No bank is the older form: whatever bank the daemon has open.
	put_frame(far, "1 2 ok count=3 revision=0 bank=2 patch=1")
	testing.expect(t, tui.client_archive_load(&client, 1))
	testing.expect_value(t, take_frame(far), "1 2 archive.load 1")

	put_frame(far, "1 3 err invalid_payload cannot open that bank")
	testing.expect(t, !tui.client_archive_load(&client, 0, 9))
	testing.expect_value(t, take_frame(far), "1 3 archive.load 0 9")
	testing.expect(t, client.fd >= 0)

	// No path reopens the one the daemon remembers.
	put_frame(far, "1 4 ok banks=2 archive_rev=5")
	banks, opened := tui.client_archive_open(&client, "")
	testing.expect(t, opened)
	testing.expect_value(t, banks, 2)
	testing.expect_value(t, take_frame(far), "1 4 archive.open")

	put_frame(far, "1 5 ok banks=2 archive_rev=6")
	_, opened = tui.client_archive_open(&client, "/tmp/My Banks.zip")
	testing.expect(t, opened)
	testing.expect_value(t, take_frame(far), "1 5 archive.open /tmp/My Banks.zip")
}

@(private = "file")
from_slot :: proc(slot: int) -> tui.Provenance {
	return {slot = slot, source = .Bank, bank = "Factory", name = "Solo Lead", archive_bank = -1, archive_patch = -1}
}

@(private = "file")
from_archive :: proc(bank, index: int) -> tui.Provenance {
	return {slot = -1, source = .Archive, bank = "Beta Bank.zip", name = "Beta Three", archive_bank = bank, archive_patch = index}
}

@(test)
test_a_row_plays_only_in_the_bank_the_sound_came_from :: proc(t: ^testing.T) {
	ORDINARY :: tui.ORDINARY
	// Ordinary slot 2 is not archive patch 2, in either direction.
	slot := from_slot(2)
	testing.expect(t, tui.nav_playing(slot, ORDINARY, 2))
	testing.expect(t, !tui.nav_playing(slot, 0, 2))
	testing.expect(t, !tui.nav_playing(slot, 1, 2))
	testing.expect(t, !tui.nav_playing(slot, ORDINARY, 3))

	beta := from_archive(1, 2)
	testing.expect(t, tui.nav_playing(beta, 1, 2))
	testing.expect(t, !tui.nav_playing(beta, ORDINARY, 2))
	testing.expect(t, !tui.nav_playing(beta, 0, 2))
	testing.expect(t, !tui.nav_playing(beta, 1, 1))

	// No position, no row: an archive since closed, a bank since replaced, a
	// file, nothing.
	nowhere := []tui.Provenance {
		from_archive(-1, -1),
		{slot = -1, source = .Bank, archive_bank = -1, archive_patch = -1},
		{slot = -1, source = .File, archive_bank = -1, archive_patch = -1},
		{slot = -1, archive_bank = -1, archive_patch = -1},
	}
	for p in nowhere {
		for bank in ([3]int{ORDINARY, 0, 1}) {
			for row in 0 ..< 3 {testing.expectf(t, !tui.nav_playing(p, bank, row), "%v plays %d/%d", p, bank, row)}
		}
	}
}

@(test)
test_provenance_names_the_bank_and_the_place_in_it :: proc(t: ^testing.T) {
	testing.expect_value(t, tui.provenance_line(from_slot(5)), "patch: Solo Lead   bank: Factory   slot 5")
	testing.expect_value(t, tui.provenance_line(from_archive(1, 2)), "patch: Beta Three   bank: Beta Bank.zip   archive #2")
	testing.expect_value(t, tui.provenance_line(from_archive(-1, -1)), "patch: Beta Three   bank: Beta Bank.zip")
	file := tui.Provenance{slot = -1, source = .File, bank = "file", name = "unison four", archive_bank = -1, archive_patch = -1}
	testing.expect_value(t, tui.provenance_line(file), "patch: unison four   bank: file")
	replaced := tui.Provenance{slot = -1, source = .Bank, bank = "Factory", name = "Solo Lead", archive_bank = -1, archive_patch = -1}
	testing.expect_value(t, tui.provenance_line(replaced), "patch: Solo Lead   bank: Factory")
	testing.expect_value(t, tui.provenance_line({slot = -1, archive_bank = -1, archive_patch = -1}), "patch: (unsaved)")

	testing.expect_value(t, tui.playing_line(from_slot(5)), "playing: Solo Lead | Factory | slot 5")
	testing.expect_value(t, tui.playing_line(from_archive(1, 2)), "playing: Beta Three | Beta Bank.zip | archive #2")
	testing.expect_value(t, tui.playing_line(file), "playing: unison four | file")

	// And on the synth screen, as drawn.
	descriptors := registry.registry_list()
	rows := make([]tui.Row, len(descriptors))
	defer delete(rows)
	for d, i in descriptors {
		rows[i].desc = d
		rows[i].value = registry.registry_default(d)
	}
	groups := tui.build_groups(rows)
	defer tui.free_groups(groups)
	cap := capture_begin()
	tui.render(rows, groups, 0, 0, tui.Metrics{ok = true}, "/tmp/quesynth.sock", from_archive(1, 2), "", plain_theme())
	screen := capture_end(cap)
	expect_rows(t, screen, "patch: Beta Three   bank: Beta Bank.zip   archive #2")
}

// The navigator as the daemon's answers leave it: the factory-sized ordinary
// bank with slots 2 and 5 filled, and the fixture archive with Beta Bank open.
// Everything is temp-allocated; nav_free is not for this one.
@(private = "file")
fixture_nav :: proc() -> tui.Navigator {
	slots := make([]tui.Bank_Slot, patch.FACTORY_SLOTS, context.temp_allocator)
	for &s, i in slots {s = {slot = i, name = "Init"}}
	slots[2] = {slot = 2, name = "Two", filled = true}
	slots[5] = {slot = 5, name = "Solo Lead", filled = true}
	return tui.Navigator {
		browsing = tui.ORDINARY,
		slots = slots,
		label = "Factory",
		archive = {open = true, banks = 2, bank = 1, patches = 3, rev = 2, path = BANKS, bank_name = "Beta Bank.zip"},
		bank_names = slice.clone([]string{"Alpha.zip", "Beta Bank.zip"}, context.temp_allocator),
		patch_names = slice.clone([]string{"Beta One", "Beta Two", "Beta Three"}, context.temp_allocator),
	}
}

@(private = "file")
navigator_screen :: proc(nav: ^tui.Navigator, prov: tui.Provenance) -> string {
	cap := capture_begin()
	tui.render_navigator(nav, prov, plain_theme())
	return capture_end(cap)
}

@(test)
test_banks_level_lists_the_ordinary_bank_then_the_archives :: proc(t: ^testing.T) {
	nav := fixture_nav()
	screen := navigator_screen(&nav, from_archive(1, 2))
	testing.expect(t, strings.contains(screen, "Quesynth — Browsing banks"), screen)
	expect_rows(
		t,
		screen,
		">  Factory  2/128",
		"   0000  Alpha.zip",
		"   0001  Beta Bank.zip",
		"1/3   Enter browse   O patch file   L bank file   Z archive   Esc hide",
		"playing: Beta Three | Beta Bank.zip | archive #2",
		"archive: " + BANKS,
	)
	// A bank is not a patch: nothing at this level is marked as playing.
	testing.expect(t, !strings.contains(screen, "*"), screen)

	// Remembered but not open: the path is named on a line of its own the
	// cursor cannot land on.
	nav.archive = {bank = -1, path = "/media/usb/gone.zip"}
	nav.bank_names = nil
	gone := navigator_screen(&nav, from_slot(5))
	expect_rows(
		t,
		gone,
		">  Factory  2/128",
		"   archive not open: /media/usb/gone.zip   Z opens another",
		"1/1   Enter browse   O patch file   L bank file   Z archive   Esc hide",
		"playing: Solo Lead | Factory | slot 5",
		"no archive - Z opens one",
	)

	nav.archive = {bank = -1}
	none := navigator_screen(&nav, from_slot(5))
	expect_rows(
		t,
		none,
		">  Factory  2/128",
		"   no archive   Z opens one",
		"1/1   Enter browse   O patch file   L bank file   Z archive   Esc hide",
	)
}

@(test)
test_patches_level_marks_the_cursor_and_the_sound_apart :: proc(t: ^testing.T) {
	nav := fixture_nav()
	nav.level = .Patches
	nav.browsing = 1
	nav.bank_row = 2
	screen := navigator_screen(&nav, from_archive(1, 2))
	testing.expect(t, strings.contains(screen, "Quesynth — Browsing: Beta Bank.zip"), screen)
	expect_rows(
		t,
		screen,
		">  00000  Beta One",
		"   00001  Beta Two",
		" * 00002  Beta Three",
		"1/3   Enter load   O patch file   Z archive   Esc banks",
		"playing: Beta Three | Beta Bank.zip | archive #2",
	)
	nav.cursor = 2
	expect_rows(t, navigator_screen(&nav, from_archive(1, 2)), ">* 00002  Beta Three")

	// Ordinary slot 2 playing marks nothing in an archive bank, and Beta
	// Three playing marks nothing in the ordinary bank.
	nav.cursor = 0
	slot_two := navigator_screen(&nav, from_slot(2))
	testing.expect(t, !strings.contains(slot_two, "*"), slot_two)

	nav.browsing = tui.ORDINARY
	nav.bank_row = 0
	nav.cursor = 5
	ordinary := navigator_screen(&nav, from_archive(1, 2))
	testing.expect(t, strings.contains(ordinary, "Quesynth — Browsing: Factory"), ordinary)
	expect_rows(
		t,
		ordinary,
		"   002  Two",
		">  005  Solo Lead",
		"6/128   Enter load   S save   O patch file   L bank file   Esc banks",
	)
	testing.expect(t, !strings.contains(ordinary, "*"), ordinary)
	expect_rows(t, navigator_screen(&nav, from_slot(2)), " * 002  Two", ">  005  Solo Lead")
}

@(test)
test_navigator_levels_remember_where_they_were :: proc(t: ^testing.T) {
	nav := fixture_nav()
	beta := from_archive(1, 2)

	// The first time: the banks, on the bank the sound came from.
	tui.nav_open(&nav, beta)
	testing.expect(t, nav.shown)
	testing.expect_value(t, nav.level, tui.Nav_Level.Banks)
	testing.expect_value(t, nav.cursor, 2)

	// Into it, on the patch that is playing; the cursor stays on the list.
	tui.nav_descend(&nav, 1, beta)
	testing.expect_value(t, nav.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav.browsing, 1)
	testing.expect_value(t, nav.cursor, 2)
	tui.nav_move(&nav, 5)
	testing.expect_value(t, nav.cursor, 2)
	tui.nav_move(&nav, -1)
	testing.expect_value(t, nav.cursor, 1)

	// Hidden -- B, or a load -- and opened again: the same list and row,
	// whatever is playing by then.
	nav.shown = false
	tui.nav_open(&nav, from_slot(5))
	testing.expect_value(t, nav.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav.browsing, 1)
	testing.expect_value(t, nav.cursor, 1)

	// Esc: up, on the bank just left; Esc again hides.
	tui.nav_escape(&nav)
	testing.expect_value(t, nav.level, tui.Nav_Level.Banks)
	testing.expect_value(t, nav.cursor, 2)
	testing.expect(t, nav.shown)
	tui.nav_escape(&nav)
	testing.expect(t, !nav.shown)

	// The ordinary bank opens on its playing slot -- and not on slot 2 when
	// the sound is archive patch 2.
	tui.nav_open(&nav, from_slot(5))
	testing.expect_value(t, nav.cursor, 2)
	tui.nav_descend(&nav, tui.ORDINARY, from_slot(5))
	testing.expect_value(t, nav.browsing, tui.ORDINARY)
	testing.expect_value(t, nav.cursor, 5)
	tui.nav_escape(&nav)
	testing.expect_value(t, nav.cursor, 0)
	tui.nav_descend(&nav, tui.ORDINARY, beta)
	testing.expect_value(t, nav.cursor, 0)
}

@(test)
test_navigator_follows_the_daemons_open_bank :: proc(t: ^testing.T) {
	nav := fixture_nav()
	beta := from_archive(1, 2)
	tui.nav_descend(&nav, 1, beta)

	// Still the bank the daemon has open: same row, names read again.
	testing.expect(t, tui.nav_follow(&nav))
	testing.expect_value(t, nav.browsing, 1)
	testing.expect_value(t, nav.cursor, 2)

	// A peer opened Alpha: the list follows it, from the top.
	nav.archive.bank = 0
	testing.expect(t, tui.nav_follow(&nav))
	testing.expect_value(t, nav.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav.browsing, 0)
	testing.expect_value(t, nav.cursor, 0)
	tui.nav_escape(&nav)
	testing.expect_value(t, nav.cursor, 1)

	// A peer opened another archive, with no bank open yet: back to the banks.
	tui.nav_descend(&nav, 0, beta)
	nav.archive.bank = -1
	testing.expect(t, !tui.nav_follow(&nav))
	testing.expect_value(t, nav.level, tui.Nav_Level.Banks)
	testing.expect_value(t, nav.cursor, 1)

	// Or closed it: the archive's rows go and the cursor stays on a row.
	nav.archive.bank = 1
	tui.nav_descend(&nav, 1, beta)
	nav.archive = {bank = -1}
	nav.bank_names = nil
	testing.expect(t, !tui.nav_follow(&nav))
	testing.expect_value(t, nav.level, tui.Nav_Level.Banks)
	testing.expect_value(t, nav.cursor, 0)

	// Browsing the ordinary bank stays there whatever the archive does.
	nav.archive = {open = true, banks = 2, bank = 1, path = BANKS}
	nav.bank_names = slice.clone([]string{"Alpha.zip", "Beta Bank.zip"}, context.temp_allocator)
	tui.nav_descend(&nav, tui.ORDINARY, from_slot(5))
	nav.archive.bank = 0
	testing.expect(t, !tui.nav_follow(&nav))
	testing.expect_value(t, nav.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav.browsing, tui.ORDINARY)
	testing.expect_value(t, nav.cursor, 5)
}

// A daemon's control server with the factory bank, the archive and the
// identity, and no audio thread: the test drains the ring itself.
@(private = "file")
Rig :: struct {
	ring:     standalone.Param_Ring,
	snap:     standalone.Snapshot,
	state:    standalone.Daemon_State,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	archive:  standalone.Archive,
	cs:       standalone.Control_Server,
}

// archive=false stands in for a daemon that cannot answer archive.current.
@(private = "file")
rig_start :: proc(tag: string, archive := true) -> (^Rig, bool) {
	r := new(Rig)
	patch.factory_prepare()
	patch.slots_load_factory(&r.bank)
	r.state = .Running
	r.identity = {slot = -1}
	r.cs.path = fmt.tprintf("/tmp/quesynth-tui-%s-%d.sock", tag, posix.getpid())
	r.cs.ctx = standalone.Control_Context {
		ring     = &r.ring,
		snapshot = &r.snap,
		state    = &r.state,
		bank     = &r.bank,
		archive  = archive ? &r.archive : nil,
		identity = &r.identity,
	}
	return r, standalone.control_server_start(&r.cs)
}

@(private = "file")
rig_stop :: proc(r: ^Rig) {
	standalone.control_server_stop(&r.cs)
	standalone.archive_close(&r.archive)
	free(r)
}

// What the audio thread would take off the ring: the patch replacements.
@(private = "file")
replacements :: proc(r: ^standalone.Param_Ring) -> (commits: int) {
	for {
		cmd, ok := standalone.param_ring_pop(r)
		if !ok {break}
		if cmd.kind == .Commit_Patch {commits += 1}
	}
	return
}

// A peer that shares no code with the TUI client: a bare socket, framed by
// hand, compared byte for byte.
@(private = "file")
wire_connect :: proc(path: string) -> (posix.FD, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return -1, false}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) {addr.sun_path[i] = path[i]}
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

@(private = "file")
wire_ask :: proc(fd: posix.FD, line: string) -> string {
	put_frame(fd, line)
	return take_frame(fd)
}

// One refresh tick with the navigator up, as the run loop does it.
@(private = "file")
tick :: proc(client: ^tui.Client, nav: ^tui.Navigator, prov: ^tui.Provenance) {
	tui.tui_read_provenance(client, prov)
	tui.tui_sync_navigator(client, nav, prov^)
}

@(private = "file")
expect_names :: proc(t: ^testing.T, got: []string, want: ..string, loc := #caller_location) {
	if !testing.expect_value(t, len(got), len(want), loc = loc) {return}
	for name, i in want {testing.expect_value(t, got[i], name, loc = loc)}
}

// Two TUIs on one daemon. What one browses, the other sees, because the open
// bank is the daemon's; what plays stays what was loaded, whoever browses
// what; and nothing either does to the ordinary bank closes the archive.
@(test)
test_two_tuis_share_the_open_bank_but_not_the_sound :: proc(t: ^testing.T) {
	r, started := rig_start("nav-peers")
	defer rig_stop(r)
	if !testing.expect(t, started) {return}
	a, aok := tui.client_connect(r.cs.path)
	b, bok := tui.client_connect(r.cs.path)
	defer {tui.client_close(&a); tui.client_close(&b)}
	peer, pok := wire_connect(r.cs.path)
	if !testing.expect(t, aok && bok && pok) {return}
	defer posix.close(peer)
	// Closed by the server thread that opened it, so it is freed with the
	// allocator that made it.
	defer wire_ask(peer, "1 99 archive.close")

	nav_a := tui.Navigator{browsing = tui.ORDINARY, archive = {bank = -1}}
	nav_b := tui.Navigator{browsing = tui.ORDINARY, archive = {bank = -1}}
	prov_a := tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}
	prov_b := tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}
	defer {
		tui.nav_free(&nav_a)
		tui.nav_free(&nav_b)
		tui.provenance_free(&prov_a)
		tui.provenance_free(&prov_b)
	}
	// B opens its navigator: the ordinary bank, and no archive yet.
	tui.tui_read_provenance(&b, &prov_b)
	tui.tui_sync_navigator(&b, &nav_b, prov_b, true)
	testing.expect_value(t, nav_b.label, "Factory")
	testing.expect_value(t, len(nav_b.slots), patch.FACTORY_SLOTS)
	testing.expect(t, !nav_b.archive.open)
	testing.expect_value(t, tui.nav_bank_count(&nav_b), 1)

	// A opens the archive and enters Beta Bank. B's next tick has the
	// archive's banks under its ordinary one, and Beta Bank open.
	_, opened := tui.client_archive_open(&a, BANKS)
	testing.expect(t, opened)
	tick(&a, &nav_a, &prov_a)
	testing.expect(t, tui.tui_browse_bank(&a, &nav_a, 1, prov_a))
	testing.expect_value(t, nav_a.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav_a.browsing, 1)
	expect_names(t, nav_a.patch_names, "Beta One", "Beta Two", "Beta Three")
	tick(&b, &nav_b, &prov_b)
	testing.expect_value(t, tui.nav_bank_count(&nav_b), 3)
	expect_names(t, nav_b.bank_names, "Alpha.zip", "Beta Bank.zip")
	testing.expect_value(t, nav_b.archive.bank, 1)
	testing.expect_value(t, wire_ask(peer, "1 1 archive.current"),
		"1 1 ok open=1 banks=2 bank=1 patches=3 archive_rev=2\npath=tests/standalone/fixtures/banks.zip\nbank_name=Beta Bank.zip")
	// Browsing loaded nothing.
	testing.expect_value(t, replacements(&r.ring), 0)
	testing.expect_value(t, wire_ask(peer, "1 2 patch.current"),
		"1 2 ok slot=-1 bank_rev=0 revision=0 source=none archive_rev=2 archive_bank=-1 archive_patch=-1\nbank=\nname=")

	// A loads Beta Three from its list, as one replacement; B names it and
	// where it is.
	nav_a.cursor = 2
	testing.expect(t, tui.tui_load_cursor(&a, &nav_a))
	testing.expect_value(t, replacements(&r.ring), 1)
	tick(&b, &nav_b, &prov_b)
	testing.expect_value(t, tui.provenance_line(prov_b), "patch: Beta Three   bank: Beta Bank.zip   archive #2")

	// B browses Alpha. A was browsing Beta, so it follows the open bank;
	// what plays is still Beta Three, and no Alpha row is marked as it.
	tick(&b, &nav_b, &prov_b)
	testing.expect(t, tui.tui_browse_bank(&b, &nav_b, 0, prov_b))
	tick(&a, &nav_a, &prov_a)
	testing.expect_value(t, nav_a.browsing, 0)
	testing.expect_value(t, nav_a.cursor, 0)
	expect_names(t, nav_a.patch_names, "Alpha One", "Alpha Two")
	testing.expect_value(t, tui.provenance_line(prov_a), "patch: Beta Three   bank: Beta Bank.zip   archive #2")
	for row in 0 ..< len(nav_a.patch_names) {testing.expect(t, !tui.nav_playing(prov_a, nav_a.browsing, row))}
	testing.expect(t, tui.nav_playing(prov_a, 1, 2))

	// A list a peer has made stale still loads what it names: the open bank
	// moves back to Beta before A's next tick, and A's Alpha list loads Alpha
	// Two, not Beta Two.
	testing.expect_value(t, wire_ask(peer, "1 3 archive.bank 1"), "1 3 ok patches=3 bank=1 archive_rev=4")
	nav_a.cursor = 1
	testing.expect(t, tui.tui_load_cursor(&a, &nav_a))
	testing.expect_value(t, replacements(&r.ring), 1)
	testing.expect_value(t, wire_ask(peer, "1 4 patch.current"),
		"1 4 ok slot=-1 bank_rev=0 revision=0 source=archive archive_rev=5 archive_bank=0 archive_patch=1\nbank=Alpha.zip\nname=Alpha Two")

	// B loads an ordinary slot. The archive and its open bank stay for A,
	// which still browses Alpha; only the playing slot moved.
	k := -1
	for i in 0 ..< patch.FACTORY_SLOTS {
		if r.bank.filled[i] {k = i; break}
	}
	if !testing.expect(t, k >= 0) {return}
	testing.expect(t, tui.client_patch_load(&b, k))
	testing.expect_value(t, replacements(&r.ring), 1)
	tick(&a, &nav_a, &prov_a)
	testing.expect_value(t, tui.provenance_line(prov_a), fmt.tprintf("patch: %s   bank: Factory   slot %d", patch.factory_name(k), k))
	testing.expect(t, nav_a.archive.open)
	testing.expect_value(t, nav_a.level, tui.Nav_Level.Patches)
	testing.expect_value(t, nav_a.browsing, 0)
	testing.expect(t, tui.nav_playing(prov_a, tui.ORDINARY, k))
	testing.expect(t, !tui.nav_playing(prov_a, 0, k))
	testing.expect_value(t, wire_ask(peer, "1 5 archive.current"),
		"1 5 ok open=1 banks=2 bank=0 patches=2 archive_rev=5\npath=tests/standalone/fixtures/banks.zip\nbank_name=Alpha.zip")
}

// A refusal is an answer, not a disconnect or an invisible false return.
@(test)
test_archive_persistence_refusals_are_kept_for_the_tui :: proc(t: ^testing.T) {
	for action in 0 ..< 3 {
		message := action == 2 ? "cannot forget archive path" : "cannot keep archive path"
		client, far := answering(fmt.tprintf("1 1 err internal_error %s", message))
		defer {tui.client_close(&client); posix.close(far)}
		switch action {
		case 0:
			_, ok := tui.client_archive_open(&client, BANKS)
			testing.expect(t, !ok)
		case 1:
			testing.expect(t, !tui.tui_hand_over_archive(&client, BANKS))
		case 2:
			testing.expect(t, !tui.client_archive_close(&client))
		}
		testing.expect_value(t, client.notice, message)
		testing.expect(t, client.fd >= 0)
		cap := capture_begin()
		tui.render_notice(client.notice, plain_theme())
		screen := capture_end(cap)
		testing.expect(t, strings.contains(screen, fmt.tprintf("Error: %s", message)))
	}
}

@(test)
test_legacy_handoff_is_one_daemon_authoritative_request :: proc(t: ^testing.T) {
	for adopted in 0 ..< 2 {
		client, far := answering(fmt.tprintf("1 1 ok adopted=%d open=1 banks=2 archive_rev=1", adopted))
		defer {tui.client_close(&client); posix.close(far)}
		testing.expect_value(t, tui.tui_hand_over_archive(&client, BANKS), adopted == 1)
		testing.expect_value(t, take_frame(far), "1 1 archive.adopt tests/standalone/fixtures/banks.zip")
		testing.expect_value(t, client.next_id, 2)
	}
}

@(test)
test_legacy_archive_path_is_handed_to_the_daemon :: proc(t: ^testing.T) {
	r, started := rig_start("nav-legacy")
	defer rig_stop(r)
	if !testing.expect(t, started) {return}
	client, cok := tui.client_connect(r.cs.path)
	defer tui.client_close(&client)
	peer, pok := wire_connect(r.cs.path)
	if !testing.expect(t, cok && pok) {return}
	defer posix.close(peer)
	defer wire_ask(peer, "1 99 archive.close")

	testing.expect(t, tui.tui_hand_over_archive(&client, BANKS))
	taken := "ok open=1 banks=2 bank=-1 patches=0 archive_rev=1\npath=tests/standalone/fixtures/banks.zip\nbank_name="
	testing.expect_value(t, wire_ask(peer, "1 1 archive.current"), fmt.tprintf("1 1 %s", taken))

	// The daemon remembers one now: a leftover never replaces it.
	testing.expect(t, !tui.tui_hand_over_archive(&client, "tests/zip/fixtures/nested.zip"))
	testing.expect_value(t, wire_ask(peer, "1 2 archive.current"), fmt.tprintf("1 2 %s", taken))

	// One that does not open is not taken, so config.conf keeps it.
	testing.expect_value(t, wire_ask(peer, "1 3 archive.close"), "1 3 ok archive_rev=2")
	missing := fmt.tprintf("/tmp/quesynth-no-such-archive-%d.zip", posix.getpid())
	testing.expect(t, !tui.tui_hand_over_archive(&client, missing))
	testing.expect(t, !tui.tui_hand_over_archive(&client, ""))
	testing.expect_value(t, wire_ask(peer, "1 4 archive.current"),
		"1 4 ok open=0 banks=0 bank=-1 patches=0 archive_rev=2\npath=\nbank_name=")
	testing.expect(t, client.fd >= 0)
}

// What tui.run does at start with an `archive =` line an older TUI left in
// config.conf, over `text` as that file: the file afterwards, and the path the
// TUI still holds for a later save.
@(private = "file")
migrate :: proc(client: ^tui.Client, file, text: string) -> (after, held: string) {
	_ = os.write_entire_file_from_string(file, text)
	config := tui.config_load()
	defer tui.config_free(&config)
	tui.tui_migrate_archive(client, &config)
	data, _ := os.read_entire_file(file, context.temp_allocator)
	return string(data), strings.clone(config.archive_path, context.temp_allocator)
}

// The legacy line leaves config.conf only once the daemon has taken its path,
// and nothing else in the file goes with it; while the hand-off fails the file
// is left byte for byte as it was. One test for every case, because each
// points XDG_CONFIG_HOME at a scratch directory and the environment is shared
// by the whole test process.
@(test)
test_legacy_archive_line_leaves_config_conf_only_once_the_daemon_takes_it :: proc(t: ^testing.T) {
	r, started := rig_start("nav-migrate")
	defer rig_stop(r)
	old, old_started := rig_start("nav-migrate-old", archive = false)
	defer rig_stop(old)
	if !testing.expect(t, started && old_started) {return}
	client, cok := tui.client_connect(r.cs.path)
	defer tui.client_close(&client)
	peer, pok := wire_connect(r.cs.path)
	if !testing.expect(t, cok && pok) {return}
	defer posix.close(peer)
	defer wire_ask(peer, "1 99 archive.close")

	root := fmt.tprintf("/tmp/quesynth-tui-migrate-%d", posix.getpid())
	defer os.remove_all(root)
	old_xdg, had_xdg := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	old_home, had_home := os.lookup_env("HOME", context.temp_allocator)
	defer {
		if had_xdg {os.set_env("XDG_CONFIG_HOME", old_xdg)} else {os.unset_env("XDG_CONFIG_HOME")}
		if had_home {os.set_env("HOME", old_home)} else {os.unset_env("HOME")}
	}
	os.set_env("XDG_CONFIG_HOME", root)
	if !testing.expect(t, os.make_directory_all(fmt.tprintf("%s/quesynth", root)) == nil) {return}
	file := fmt.tprintf("%s/quesynth/config.conf", root)
	none := "ok open=0 banks=0 bank=-1 patches=0 archive_rev=0\npath=\nbank_name="

	// Paths that do not open: missing, not a zip, a directory.
	missing := fmt.tprintf("/tmp/quesynth-no-such-archive-%d.zip", posix.getpid())
	for path, i in ([]string{missing, "patches/quesynth/factory.json", "tests"}) {
		text := fmt.tprintf("# Quesynth front-end settings.\narchive = %s\nbank = /tmp/my bank.json\n", path)
		after, held := migrate(&client, file, text)
		testing.expect_value(t, after, text)
		testing.expect_value(t, held, path)
		testing.expect_value(t, wire_ask(peer, fmt.tprintf("1 %d archive.current", i + 1)), fmt.tprintf("1 %d %s", i + 1, none))
	}

	// A daemon that cannot answer archive.current, and a connection that has
	// dropped: nothing is handed over, so nothing leaves the file.
	legacy := fmt.tprintf("# Quesynth front-end settings.\narchive = %s\nbank = /tmp/my bank.json\n", BANKS)
	older, ook := tui.client_connect(old.cs.path)
	defer tui.client_close(&older)
	if testing.expect(t, ook) {
		after, held := migrate(&older, file, legacy)
		testing.expect_value(t, after, legacy)
		testing.expect_value(t, held, BANKS)
	}
	dropped := tui.Client{fd = -1}
	defer tui.client_close(&dropped)
	after, held := migrate(&dropped, file, legacy)
	testing.expect_value(t, after, legacy)
	testing.expect_value(t, held, BANKS)
	testing.expect_value(t, wire_ask(peer, "1 4 archive.current"), fmt.tprintf("1 4 %s", none))

	// Taken: only the archive line goes.
	after, held = migrate(&client, file, legacy)
	testing.expect_value(t, after, "# Quesynth front-end settings.\nbank = /tmp/my bank.json\n")
	testing.expect_value(t, held, "")
	taken := "ok open=1 banks=2 bank=-1 patches=0 archive_rev=1\npath=tests/standalone/fixtures/banks.zip\nbank_name="
	testing.expect_value(t, wire_ask(peer, "1 5 archive.current"), fmt.tprintf("1 5 %s", taken))

	// The daemon remembers one now: a leftover is not handed over and stays.
	leftover := "archive = tests/zip/fixtures/nested.zip\nbank = /tmp/my bank.json\n"
	after, held = migrate(&client, file, leftover)
	testing.expect_value(t, after, leftover)
	testing.expect_value(t, held, "tests/zip/fixtures/nested.zip")
	testing.expect_value(t, wire_ask(peer, "1 6 archive.current"), fmt.tprintf("1 6 %s", taken))

	// A file the user edited by hand: their comment, a key this TUI does not
	// know and a last line with no newline all stay as they were.
	testing.expect_value(t, wire_ask(peer, "1 7 archive.close"), "1 7 ok archive_rev=2")
	edited := fmt.tprintf("# my own note\n\narchive = %s\nbank = /tmp/my bank.json\ncolour = blue", BANKS)
	after, held = migrate(&client, file, edited)
	testing.expect_value(t, after, "# my own note\n\nbank = /tmp/my bank.json\ncolour = blue")
	testing.expect_value(t, held, "")
	testing.expect_value(t, wire_ask(peer, "1 8 archive.current"),
		"1 8 ok open=1 banks=2 bank=-1 patches=0 archive_rev=3\npath=tests/standalone/fixtures/banks.zip\nbank_name=")
	testing.expect(t, client.fd >= 0)

	check_config_edits(t, file)
	check_config_symlink_and_mode(t, file)
	check_archive_setting_edits(t, file)
}

// Called under the migration test's isolated config environment, since the
// environment is process-wide even when the runner uses several threads.
@(private = "file")
check_config_edits :: proc(t: ^testing.T, file: string) {
	handwritten := "# keep my note\r\n\r\narchive = /later.zip\r\n  bank\t= /old.json\r\ncolour = blue\r\ncolour = green"
	testing.expect(t, os.write_entire_file_from_string(file, handwritten) == nil)
	settings := tui.config_load()
	defer tui.config_free(&settings)
	delete(settings.bank_path)
	settings.bank_path = strings.clone("/new bank.json")
	old, opened := os.open(file)
	if !testing.expect(t, opened == nil) { return }
	defer os.close(old)
	testing.expect(t, tui.config_save(settings))
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "# keep my note\r\n\r\narchive = /later.zip\r\n  bank\t= /new bank.json\r\ncolour = blue\r\ncolour = green")
	tui.config_drop_archive()
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "# keep my note\r\n\r\n  bank\t= /new bank.json\r\ncolour = blue\r\ncolour = green")
	// The old descriptor still sees the entire old file: neither successful
	// edit truncated or rewrote the inode a reader was using.
	before := make([]u8, len(handwritten), context.temp_allocator)
	n, err := os.read_at(old, before, 0)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(before[:n]), handwritten)

	// Only the last bank key is effective; preserve earlier duplicates and
	// trailing whitespace. Clearing it must not reactivate an earlier value.
	duplicate := "bank=first\nbank = second \t\r\nunknown = raw"
	testing.expect(t, os.write_entire_file_from_string(file, duplicate) == nil)
	testing.expect(t, tui.config_save(tui.Config{}))
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "bank=first\nbank =  \t\r\nunknown = raw")
	cleared := tui.config_load()
	testing.expect_value(t, cleared.bank_path, "")
	tui.config_free(&cleared)

	// A failed read cannot be treated as an absent config and overwritten.
	testing.expect(t, os.remove(file) == nil)
	testing.expect(t, os.make_directory(file) == nil)
	testing.expect(t, !tui.config_save(settings))
	testing.expect(t, !tui.config_drop_archive())
	testing.expect(t, os.is_directory(file))
	testing.expect(t, os.remove(file) == nil)
	testing.expect(t, tui.config_save(settings))
	data, _ = os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "bank = /new bank.json\n")

	// Read-only directory, writable file: a direct truncating write would
	// succeed here, but no atomic replacement is possible. Not a root test.
	if posix.geteuid() != 0 {
		dir := file[:strings.last_index_byte(file, '/')]
		testing.expect(t, os.chmod(dir, {.Read_User, .Execute_User}) == nil)
		defer os.chmod(dir, {.Read_User, .Write_User, .Execute_User})
		testing.expect(t, !tui.config_save(tui.Config{bank_path = "/refused"}))
		data, _ = os.read_entire_file(file, context.temp_allocator)
		testing.expect_value(t, string(data), "bank = /new bank.json\n")
	}
}

// The permission bits (setuid, setgid and sticky too) of what is at `path`,
// read from the file system itself, or max(u32) when it cannot be read.
@(private = "file")
mode_of :: proc(path: string) -> u32 {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK { return max(u32) }
	return transmute(u32)(st.st_mode & ~posix.S_IFMT)
}

// Names a failed or finished write could have left behind in `dirs`.
@(private = "file")
temp_files_in :: proc(dirs: []string) -> (found: [dynamic]string) {
	found = make([dynamic]string, context.temp_allocator)
	for dir in dirs {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		for e in entries {
			if strings.contains(e.name, ".tmp") { append(&found, fmt.tprintf("%s/%s", dir, e.name)) }
		}
	}
	return
}

// config.conf kept in a dotfiles checkout is a link, and its owner may keep it
// private or read-only. An edit is written through the link to the file it
// names and replaces that file with one of the same mode; the link, however
// long the chain, stays what it was. Everything is read back from the file
// system: link text, type, mode, content, the descriptor of the replaced inode.
// Called under the migration test's isolated config environment.
@(private = "file")
check_config_symlink_and_mode :: proc(t: ^testing.T, file: string) {
	root := file[:strings.last_index(file, "/quesynth/")]
	conf := fmt.tprintf("%s/quesynth", root)
	dots := fmt.tprintf("%s/dots", root)
	elsewhere := fmt.tprintf("%s/elsewhere", root)
	for d in ([]string{dots, elsewhere}) { testing.expect(t, os.make_directory_all(d) == nil) }
	dirs := []string{conf, dots, elsewhere}
	old := "# mine\r\narchive = /old.zip\nbank = /old.json\nunknown = x"
	saved := "# mine\r\narchive = /old.zip\nbank = /new bank.json\nunknown = x"
	dropped := "# mine\r\nbank = /new bank.json\nunknown = x"

	Layout :: enum { Plain, Relative, Absolute, Chain, Dangling }
	for layout in Layout {
		for mode in ([]u32{0o600, 0o640, 0o400, 0o4640}) {
			if layout == .Dangling && mode != 0o600 { continue }
			name := fmt.tprintf("%v %o", layout, mode)
			target, links := file, []string{}
			switch layout {
			case .Plain:
			case .Relative:
				target = fmt.tprintf("%s/real.conf", dots)
				links = []string{"../dots/real.conf"}
			case .Absolute:
				target = fmt.tprintf("%s/real.conf", elsewhere)
				links = []string{target}
			case .Chain:
				target = fmt.tprintf("%s/real.conf", elsewhere)
				links = []string{"../dots/hop.conf", "../elsewhere/real.conf"}
			case .Dangling:
				target = fmt.tprintf("%s/new.conf", dots)
				links = []string{"../dots/new.conf"}
			}
			hop := fmt.tprintf("%s/hop.conf", dots)
			_ = os.remove(file)
			_ = os.remove(hop)
			_ = os.remove(target)
			if len(links) > 0 {
				testing.expect(t, os.symlink(links[0], file) == nil)
			}
			if len(links) > 1 {
				testing.expect(t, os.symlink(links[1], hop) == nil)
			}
			old_fd: ^os.File
			if layout != .Dangling {
				testing.expect(t, os.write_entire_file_from_string(target, old) == nil)
				testing.expect(t, posix.chmod(strings.clone_to_cstring(target, context.temp_allocator), transmute(posix.mode_t)mode) == .OK)
				fd, oerr := os.open(target)
				testing.expect(t, oerr == nil)
				old_fd = fd
			}

			settings := tui.Config{bank_path = "/new bank.json"}
			for step in 0 ..< 2 {
				ok := step == 0 ? tui.config_save(settings) : tui.config_drop_archive()
				testing.expectf(t, ok, "%s: edit %d refused", name, step)
				want := layout == .Dangling ? "bank = /new bank.json\n" : (step == 0 ? saved : dropped)
				data, _ := os.read_entire_file(target, context.temp_allocator)
				testing.expect_value(t, string(data), want)
				if layout != .Dangling { testing.expect_value(t, mode_of(target), mode) }
				// Each link is still a link, to the same text.
				if len(links) > 0 {
					info, lerr := os.lstat(file, context.temp_allocator)
					testing.expectf(t, lerr == nil && info.type == .Symlink, "%s: config.conf is no longer a link", name)
					text, _ := os.read_link(file, context.temp_allocator)
					testing.expect_value(t, text, links[0])
				}
				if len(links) > 1 {
					text, _ := os.read_link(hop, context.temp_allocator)
					testing.expect_value(t, text, links[1])
				}
				testing.expectf(t, len(temp_files_in(dirs)) == 0, "%s: left %v", name, temp_files_in(dirs))
			}
			if old_fd != nil {
				// The inode a reader had open was replaced, not rewritten.
				before := make([]u8, len(old), context.temp_allocator)
				n, rerr := os.read_at(old_fd, before, 0)
				testing.expect(t, rerr == nil)
				testing.expect_value(t, string(before[:n]), old)
				os.close(old_fd)
			}
		}
	}

	// A loop of links is refused and left as it is, not followed for ever.
	_ = os.remove(file)
	a, b := fmt.tprintf("%s/a.conf", dots), fmt.tprintf("%s/b.conf", dots)
	_ = os.remove(a)
	_ = os.remove(b)
	testing.expect(t, os.symlink("b.conf", a) == nil)
	testing.expect(t, os.symlink("a.conf", b) == nil)
	testing.expect(t, os.symlink("../dots/a.conf", file) == nil)
	testing.expect(t, !tui.config_save(tui.Config{bank_path = "/new bank.json"}))
	text, _ := os.read_link(file, context.temp_allocator)
	testing.expect_value(t, text, "../dots/a.conf")
	testing.expect_value(t, len(temp_files_in(dirs)), 0)
	for p in ([]string{file, a, b, fmt.tprintf("%s/hop.conf", dots)}) { _ = os.remove(p) }
	for p in ([]string{"real.conf", "new.conf"}) {
		_ = os.remove(fmt.tprintf("%s/%s", dots, p))
		_ = os.remove(fmt.tprintf("%s/%s", elsewhere, p))
	}
}

@(private = "file")
check_archive_setting_edits :: proc(t: ^testing.T, file: string) {
	text := "# my note\r\n\r\narchive = /old.zip\r\nunknown = x\narchive=/last.zip\nbank = /unchanged.json\nunknown = y"
	want := "# my note\r\n\r\nunknown = x\nbank = /unchanged.json\nunknown = y"
	for path in ([]string{"/new.zip", ""}) {
		for accepted in ([]bool{false, true}) {
			testing.expect(t, os.write_entire_file_from_string(file, text) == nil)
			settings := tui.config_load()
			defer tui.config_free(&settings)
			reply := accepted ? "1 1 ok archive_rev=2" : "1 1 err internal_error cannot keep archive path"
			client, far := answering(reply)
			defer {tui.client_close(&client); posix.close(far)}
			testing.expect_value(t, tui.tui_set_archive(&client, &settings, path), accepted)
			data, _ := os.read_entire_file(file, context.temp_allocator)
			testing.expect_value(t, string(data), accepted ? want : text)
			testing.expect_value(t, settings.archive_path, accepted ? "" : "/last.zip")
			testing.expect_value(t, take_frame(far), path == "" ? "1 1 archive.close" : "1 1 archive.open /new.zip")
		}
	}

	// No legacy line: an accepted edit has nothing to drop, so config.conf is
	// left alone -- byte for byte, not created when absent, not even read when
	// it cannot be or there is no config directory -- and no notice claims it
	// could not be updated.
	mine := "# mine\r\n\r\nbank = /unchanged.json\nunknown = z"
	xdg := file[:strings.last_index(file, "/quesynth/")]
	for setup in 0 ..< 4 {
		for path in ([]string{"/new.zip", ""}) {
			switch setup {
			case 0:
				testing.expect(t, os.write_entire_file_from_string(file, mine) == nil)
			case 1:
				testing.expect(t, os.remove(file) == nil || !os.exists(file))
			case 2:
				testing.expect(t, os.make_directory(file) == nil)
			case 3:
				os.unset_env("XDG_CONFIG_HOME")
				os.unset_env("HOME")
			}
			settings := tui.Config{}
			client, far := answering("1 1 ok archive_rev=2")
			defer {tui.client_close(&client); posix.close(far)}
			testing.expect(t, tui.tui_set_archive(&client, &settings, path))
			testing.expect_value(t, client.notice, "")
			testing.expect_value(t, take_frame(far), path == "" ? "1 1 archive.close" : "1 1 archive.open /new.zip")
			switch setup {
			case 0:
				data, _ := os.read_entire_file(file, context.temp_allocator)
				testing.expect_value(t, string(data), mine)
			case 1:
				testing.expect(t, !os.exists(file))
			case 2:
				testing.expect(t, os.is_directory(file))
				testing.expect(t, os.remove(file) == nil)
			case 3:
				os.set_env("XDG_CONFIG_HOME", xdg)
				testing.expect(t, !os.exists(file))
			}
		}
	}
}
