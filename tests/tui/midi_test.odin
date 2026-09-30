#+build linux
package tui_tests

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

import registry "../../src/registry"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The TUI's half of the daemon's MIDI input selection. The replies are written
// out by hand in the wire format the protocol contract gives -- the same
// literals the daemon's own tests expect it to produce -- so the parsers are
// checked against the contract, not against the code that answers them.

// A client whose next request is answered with `reply` from the far end of a
// socket pair; the caller closes `far`.
@(private = "file")
canned :: proc(reply: string) -> (client: tui.Client, far: posix.FD) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK {return tui.Client{fd = -1}, -1}
	write_frame(fds[1], reply)
	return tui.Client{fd = fds[0], next_id = 1}, fds[1]
}

// Framing written out by hand as well -- the documented little-endian u32
// length, then the payload -- rather than borrowed from the codec.
@(private = "file")
write_frame :: proc(fd: posix.FD, text: string) {
	n := len(text)
	header := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fd, raw_data(header[:]), 4, {.NOSIGNAL})
	posix.send(fd, raw_data(text), c.size_t(n), {.NOSIGNAL})
}

// The next frame's payload, or "" when none arrives within a second.
@(private = "file")
read_frame :: proc(fd: posix.FD) -> string {
	header: [4]u8
	if !read_exact(fd, header[:]) {return ""}
	n := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	text := make([]u8, n, context.temp_allocator)
	if !read_exact(fd, text) {return ""}
	return string(text)
}

@(private = "file")
read_exact :: proc(fd: posix.FD, data: []u8) -> bool {
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

@(test)
test_client_midi_list_keeps_names_raw :: proc(t: ^testing.T) {
	client, far := canned(
		"1 1 ok count=3 selected=hw:3,0 midi_rev=1\nid=hw:1,0 name=Launchkey Mini MK3 MIDI\nid=hw:2,0 name=USB  MIDI Interface \nid=hw:3,0 name=USB MIDI Interface",
	)
	defer posix.close(far)
	defer tui.client_close(&client)
	devices, selected, midi_rev, ok := tui.client_midi_list(&client)
	defer {tui.client_midi_free(devices); delete(selected)}
	testing.expect(t, ok)
	testing.expect_value(t, selected, "hw:3,0")
	testing.expect_value(t, midi_rev, 1)
	if !testing.expect_value(t, len(devices), 3) {return}
	testing.expect_value(t, devices[0].id, "hw:1,0")
	testing.expect_value(t, devices[0].name, "Launchkey Mini MK3 MIDI")
	// Spaces inside and at the end of a name are part of it, and two
	// controllers of one model differ only by id.
	testing.expect_value(t, devices[1].id, "hw:2,0")
	testing.expect_value(t, devices[1].name, "USB  MIDI Interface ")
	testing.expect_value(t, devices[2].id, "hw:3,0")
	testing.expect_value(t, devices[2].name, "USB MIDI Interface")
}

@(test)
test_client_midi_list_with_no_inputs :: proc(t: ^testing.T) {
	client, far := canned("1 1 ok count=0 selected=all midi_rev=0")
	defer posix.close(far)
	defer tui.client_close(&client)
	devices, selected, midi_rev, ok := tui.client_midi_list(&client)
	defer {tui.client_midi_free(devices); delete(selected)}
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 0)
	testing.expect_value(t, selected, "all")
	testing.expect_value(t, midi_rev, 0)
}

@(test)
test_client_midi_select_sends_the_token :: proc(t: ^testing.T) {
	client, far := canned("1 1 ok selected=hw:2,0 midi_rev=1")
	defer posix.close(far)
	defer tui.client_close(&client)
	testing.expect(t, tui.client_midi_select(&client, "hw:2,0"))
	testing.expect_value(t, read_frame(far), "1 1 midi.select hw:2,0")
}

@(test)
test_client_midi_select_refused_is_not_a_disconnect :: proc(t: ^testing.T) {
	// Every refusal the contract lists, and an older daemon that has no such
	// command: well-formed answers, so the connection stays up.
	refusals := []string {
		"1 1 err invalid_payload no such midi input",
		"1 1 err invalid_payload midi.select needs all, none or an input id",
		"1 1 err internal_error cannot open midi input",
		"1 1 err daemon_not_ready no midi input",
		"1 1 err unknown_command unknown command",
	}
	for reply in refusals {
		client, far := canned(reply)
		defer posix.close(far)
		defer tui.client_close(&client)
		testing.expect(t, !tui.client_midi_select(&client, "hw:9,0"), reply)
		testing.expect(t, client.fd >= 0, reply)
	}
}

@(test)
test_client_midi_current_names_the_selection :: proc(t: ^testing.T) {
	replies := []struct {
		reply, selected, name: string,
		rev:                   uint,
	} {
		{"1 1 ok selected=hw:3,0 midi_rev=1\nname=USB  MIDI Interface ", "hw:3,0", "USB  MIDI Interface ", 1},
		{"1 1 ok selected=all midi_rev=0\nname=All inputs", "all", "All inputs", 0},
		{"1 1 ok selected=none midi_rev=2\nname=None", "none", "None", 2},
	}
	for r in replies {
		client, far := canned(r.reply)
		defer posix.close(far)
		defer tui.client_close(&client)
		selected, name, midi_rev, ok := tui.client_midi_current(&client)
		defer {delete(selected); delete(name)}
		testing.expect(t, ok, r.reply)
		testing.expect_value(t, selected, r.selected)
		testing.expect_value(t, name, r.name)
		testing.expect_value(t, midi_rev, r.rev)
	}
}

@(test)
test_client_midi_current_refused_is_not_a_disconnect :: proc(t: ^testing.T) {
	// A daemon with no MIDI backend, and one from before these commands.
	for reply in ([2]string{"1 1 err daemon_not_ready no midi input", "1 1 err unknown_command unknown command"}) {
		client, far := canned(reply)
		defer posix.close(far)
		defer tui.client_close(&client)
		selected, name, _, ok := tui.client_midi_current(&client)
		defer {delete(selected); delete(name)}
		testing.expect(t, !ok, reply)
		testing.expect_value(t, name, "")
		testing.expect(t, client.fd >= 0, reply)
	}
}

// A daemon that went away mid-request: the connection is closed, as every
// other request closes it, so the synth screen reports the disconnect.
@(test)
test_midi_calls_close_the_client_when_the_daemon_goes :: proc(t: ^testing.T) {
	for call in 0 ..< 3 {
		fds: [2]posix.FD
		if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, {}, &fds) == .OK) {return}
		client := tui.Client{fd = fds[0], next_id = 1}
		defer tui.client_close(&client)
		posix.close(fds[1])
		ok := true
		switch call {
		case 0:
			devices, selected, _, listed := tui.client_midi_list(&client)
			tui.client_midi_free(devices)
			delete(selected)
			ok = listed
		case 1:
			ok = tui.client_midi_select(&client, "all")
		case 2:
			selected, name, _, current := tui.client_midi_current(&client)
			delete(selected)
			delete(name)
			ok = current
		}
		testing.expect(t, !ok)
		testing.expect_value(t, client.fd, -1)
	}
}

// A stand-in for ALSA, since a CI box has no raw-MIDI hardware: three inputs
// that always open, two of them one model told apart only by id. The daemon's
// real Midi_Selection runs over it, so what is under test is the selection
// and the protocol, not a driver.
@(private = "file")
fake_inputs := [3][2]string {
	{"hw:1,0", "Launchkey Mini MK3 MIDI"},
	{"hw:2,0", "USB MIDI Interface"},
	{"hw:3,0", "USB MIDI Interface"},
}

@(private = "file")
fake_list :: proc(m: ^standalone.Midi_Input) -> []standalone.Midi_Device {
	devices := make([]standalone.Midi_Device, len(fake_inputs))
	for d, i in fake_inputs {
		devices[i] = standalone.Midi_Device {
			id   = strings.clone(d[0]),
			name = strings.clone(d[1]),
		}
	}
	return devices
}

@(private = "file")
fake_open :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue) -> bool {return true}

@(private = "file")
fake_open_device :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue, id: string) -> bool {return true}

@(private = "file")
fake_close_inputs :: proc(m: ^standalone.Midi_Input) {}

// The browser's side: a bare socket that frames by hand and compares the
// daemon's raw bytes, so it shares no code with the TUI client it checks.
@(private = "file")
raw_connect :: proc(path: string) -> (posix.FD, bool) {
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
raw_ask :: proc(fd: posix.FD, line: string) -> string {
	write_frame(fd, line)
	return read_frame(fd)
}

@(test)
test_tui_and_a_peer_share_the_daemons_midi_selection :: proc(t: ^testing.T) {
	queue: standalone.Midi_Queue
	standalone.midi_queue_init(&queue)
	input := standalone.Midi_Input {
		open         = fake_open,
		list         = fake_list,
		open_device  = fake_open_device,
		close_inputs = fake_close_inputs,
		close        = fake_close_inputs,
	}
	selection: standalone.Midi_Selection
	standalone.midi_selection_init(&selection, &input, &queue)

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-midi-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring        = &ring,
		snapshot    = &snap,
		state       = &state,
		midi        = &queue,
		midi_select = &selection,
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)
	client, connected := tui.client_connect(cs.path)
	defer tui.client_close(&client)
	peer, reached := raw_connect(cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(peer)

	devices, selected, midi_rev, listed := tui.client_midi_list(&client)
	defer {tui.client_midi_free(devices); delete(selected)}
	testing.expect(t, listed)
	testing.expect_value(t, selected, "all")
	testing.expect_value(t, midi_rev, 0)
	if testing.expect_value(t, len(devices), 3) {
		testing.expect_value(t, devices[0].id, "hw:1,0")
		testing.expect_value(t, devices[0].name, "Launchkey Mini MK3 MIDI")
		testing.expect_value(t, devices[2].id, "hw:3,0")
		testing.expect_value(t, devices[2].name, "USB MIDI Interface")
	}

	// The TUI picks one; the other front-end's next poll sees it.
	testing.expect(t, tui.client_midi_select(&client, "hw:3,0"))
	testing.expect_value(t, raw_ask(peer, "1 1 midi.current"), "1 1 ok selected=hw:3,0 midi_rev=1\nname=USB MIDI Interface")

	// The other one picks none; the TUI reads that, not anything it chose.
	testing.expect_value(t, raw_ask(peer, "1 2 midi.select none"), "1 2 ok selected=none midi_rev=2")
	token, name, rev, current := tui.client_midi_current(&client)
	defer {delete(token); delete(name)}
	testing.expect(t, current)
	testing.expect_value(t, token, "none")
	testing.expect_value(t, name, "None")
	testing.expect_value(t, rev, 2)

	// Refused, and the connection and the selection both survive it.
	testing.expect(t, !tui.client_midi_select(&client, "hw:9,0"))
	testing.expect(t, client.fd >= 0)
	testing.expect_value(t, raw_ask(peer, "1 3 midi.current"), "1 3 ok selected=none midi_rev=2\nname=None")
	testing.expect(t, tui.client_midi_select(&client, "all"))
	testing.expect_value(t, raw_ask(peer, "1 4 midi.current"), "1 4 ok selected=all midi_rev=3\nname=All inputs")
}

// The MIDI screen's (*) mark while the screen is open: it starts from the
// token midi.list gave, and a peer's change must reach it on the next tick
// without R. The server is the real one, so the peer's select is the daemon's.
@(test)
test_midi_screen_mark_follows_a_peers_selection :: proc(t: ^testing.T) {
	queue: standalone.Midi_Queue
	standalone.midi_queue_init(&queue)
	input := standalone.Midi_Input {
		open         = fake_open,
		list         = fake_list,
		open_device  = fake_open_device,
		close_inputs = fake_close_inputs,
		close        = fake_close_inputs,
	}
	selection: standalone.Midi_Selection
	standalone.midi_selection_init(&selection, &input, &queue)

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-midimark-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring        = &ring,
		snapshot    = &snap,
		state       = &state,
		midi        = &queue,
		midi_select = &selection,
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)
	client, connected := tui.client_connect(cs.path)
	defer tui.client_close(&client)
	peer, reached := raw_connect(cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(peer)

	devices, selected, _, listed := tui.client_midi_list(&client)
	defer {tui.client_midi_free(devices); delete(selected)}
	if !testing.expect(t, listed) {return}
	testing.expect_value(t, selected, "all")

	testing.expect_value(t, raw_ask(peer, "1 1 midi.select hw:2,0"), "1 1 ok selected=hw:2,0 midi_rev=1")
	testing.expect(t, tui.tui_refresh_midi_selected(&client, &selected))
	testing.expect_value(t, selected, "hw:2,0")

	testing.expect_value(t, raw_ask(peer, "1 2 midi.select none"), "1 2 ok selected=none midi_rev=2")
	testing.expect(t, tui.tui_refresh_midi_selected(&client, &selected))
	testing.expect_value(t, selected, "none")
}

// A refused read -- a daemon with no MIDI backend, one from before
// midi.current -- and a dropped connection both leave the mark on the
// daemon's last answer rather than on no row at all; only the drop closes
// the client, which the loop then reports as a disconnect.
@(test)
test_midi_screen_mark_stays_when_the_read_fails :: proc(t: ^testing.T) {
	for reply in ([2]string{"1 1 err daemon_not_ready no midi input", "1 1 err unknown_command unknown command"}) {
		client, far := canned(reply)
		defer posix.close(far)
		defer tui.client_close(&client)
		selected := strings.clone("hw:3,0")
		defer delete(selected)
		testing.expect(t, !tui.tui_refresh_midi_selected(&client, &selected), reply)
		testing.expect_value(t, selected, "hw:3,0")
		testing.expect(t, client.fd >= 0, reply)
	}

	fds: [2]posix.FD
	if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, {}, &fds) == .OK) {return}
	client := tui.Client{fd = fds[0], next_id = 1}
	defer tui.client_close(&client)
	posix.close(fds[1])
	selected := strings.clone("hw:3,0")
	defer delete(selected)
	testing.expect(t, !tui.tui_refresh_midi_selected(&client, &selected))
	testing.expect_value(t, selected, "hw:3,0")
	testing.expect_value(t, client.fd, -1)
}

// What one draw put on the terminal. stdout is swapped for a pipe between
// begin and end; the renderers write with plain write(2), so nothing is left
// buffered when it is swapped back. A pipe has no size, so the screen is the
// 80x24 fallback.
@(private = "file")
Capture :: struct {
	saved: posix.FD,
	pipe:  [2]posix.FD,
}

// stdout is one per process and the runner runs tests on several threads,
// so every swap in this package holds this, identity_test.odin's included.
// Unheld, two captures took each other's screens, and one waited forever on
// a pipe whose write end the other had saved as "stdout".
@(private)
stdout_capture: sync.Mutex

@(private = "file")
capture_begin :: proc() -> (cap: Capture) {
	sync.mutex_lock(&stdout_capture)
	if posix.pipe(&cap.pipe) != .OK {
		sync.mutex_unlock(&stdout_capture)
		return Capture{saved = -1}
	}
	cap.saved = posix.dup(posix.STDOUT_FILENO)
	posix.dup2(cap.pipe[1], posix.STDOUT_FILENO)
	return cap
}

@(private = "file")
capture_end :: proc(cap: Capture) -> string {
	if cap.saved < 0 {return ""}
	posix.dup2(cap.saved, posix.STDOUT_FILENO)
	posix.close(cap.saved)
	posix.close(cap.pipe[1])
	sync.mutex_unlock(&stdout_capture)
	defer posix.close(cap.pipe[0])
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n := posix.read(cap.pipe[0], raw_data(buf[:]), c.size_t(len(buf)))
		if n <= 0 {break}
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}

@(private = "file")
plain_theme :: proc() -> tui.Theme {
	theme := tui.theme_defaults()
	theme.enabled = false
	return theme
}

@(private = "file")
midi_screen :: proc(devices: []tui.Midi_Device, selected: string, cursor: int, refused := -1) -> string {
	cap := capture_begin()
	tui.render_midi(devices, selected, cursor, refused, plain_theme())
	return capture_end(cap)
}

// Each line, in this order, as whole framed rows of the screen.
@(private = "file")
expect_rows :: proc(t: ^testing.T, screen: string, rows: ..string, loc := #caller_location) {
	at := 0
	for row in rows {
		framed := fmt.tprintf("│ %s", row)
		i := strings.index(screen[at:], framed)
		if !testing.expectf(t, i >= 0, "no row %q after the previous one in %q", row, screen, loc = loc) {return}
		// The rest of the row is padding up to the right border.
		rest := screen[at + i + len(framed):]
		testing.expectf(t, strings.has_prefix(strings.trim_left(rest, " "), "│"), "row %q runs on in %q", row, screen, loc = loc)
		at += i + len(framed)
	}
}

@(private = "file")
two_models := []tui.Midi_Device {
	{id = "hw:1,0", name = "Launchkey Mini MK3 MIDI"},
	{id = "hw:2,0", name = "USB MIDI Interface"},
	{id = "hw:3,0", name = "USB MIDI Interface"},
}

@(test)
test_midi_screen_lists_every_input_between_all_and_none :: proc(t: ^testing.T) {
	screen := midi_screen(two_models, "hw:3,0", 0)
	testing.expect(t, strings.contains(screen, "Quesynth — MIDI input"), screen)
	// The cursor and the daemon's choice are two marks on two rows, and only
	// the daemon's choice gets (*).
	expect_rows(
		t,
		screen,
		"> ( ) All inputs",
		"  ( ) Launchkey Mini MK3 MIDI  hw:1,0",
		"  ( ) USB MIDI Interface  hw:2,0",
		"  (*) USB MIDI Interface  hw:3,0",
		"  ( ) None",
	)
	testing.expect_value(t, strings.count(screen, "(*)"), 1)
	testing.expect(t, !strings.contains(screen, "no MIDI inputs"), screen)
	testing.expect(t, !strings.contains(screen, "refused"), screen)

	moved := midi_screen(two_models, "all", 4)
	expect_rows(t, moved, "  (*) All inputs", "  ( ) USB MIDI Interface  hw:3,0", "> ( ) None")
}

@(test)
test_midi_screen_with_no_inputs_still_offers_all_and_none :: proc(t: ^testing.T) {
	screen := midi_screen(nil, "none", 1)
	expect_rows(t, screen, "  ( ) All inputs", "      (no MIDI inputs found)", "> (*) None")
}

@(test)
test_midi_screen_names_a_refused_choice :: proc(t: ^testing.T) {
	screen := midi_screen(two_models, "hw:1,0", 2, refused = 2)
	testing.expect(t, strings.contains(screen, "the daemon refused USB MIDI Interface (hw:2,0)"), screen)
	// Still the daemon's own choice that is marked, not the refused one.
	expect_rows(t, screen, "  (*) Launchkey Mini MK3 MIDI  hw:1,0", "> ( ) USB MIDI Interface  hw:2,0")

	none := midi_screen(two_models, "all", 4, refused = 4)
	testing.expect(t, strings.contains(none, "the daemon refused None"), none)
}

// The synth screen, as identity_test.odin draws it, with a MIDI line.
@(private = "file")
synth_screen :: proc(midi: string, connected := true) -> string {
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
	tui.render(rows, groups, 0, 0, tui.Metrics{ok = connected}, "/tmp/quesynth.sock", "Factory", "Solo Lead", midi, plain_theme())
	return capture_end(cap)
}

@(test)
test_synth_screen_shows_the_daemons_midi_input :: proc(t: ^testing.T) {
	screen := synth_screen("USB MIDI Interface")
	expect_rows(t, screen, "patch: Solo Lead   bank: Factory", "midi: USB MIDI Interface")
	testing.expect(t, strings.contains(screen, "M midi"), screen)

	// Unknown -- a daemon without midi.current, or a refused read -- is left
	// out rather than shown as some input, and so is a daemon gone away.
	for gone in ([2]string{synth_screen(""), synth_screen("USB MIDI Interface", connected = false)}) {
		testing.expect(t, strings.contains(gone, "patch: Solo Lead"), gone)
		testing.expect(t, !strings.contains(gone, "midi:"), gone)
	}
}
