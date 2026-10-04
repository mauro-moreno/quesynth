#+build linux
package tui_tests

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"

import patch "../../src/patch"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The User bank in config.conf is loaded as a TUI attaches only while the
// daemon is still on the factory bank it started with (bank_rev 0). Loading it
// on every attach replaced the live bank, and with it every save into it that
// was not written to that very file -- from this TUI before a relaunch, another
// TUI or a browser. Read here off the wire, as the daemon would see it, and on
// a real control server, as a user would: the save is still in the bank.

// A daemon stand-in on its own thread: it answers each request with the next
// scripted reply and records every request line, then waits a while for any
// request it has no reply for, which is one the TUI should not have sent.
@(private = "file")
Stand_In :: struct {
	fd:        posix.FD,
	replies:   []string,
	heard:     [4][512]u8,
	heard_len: [4]int,
	count:     int,
}

@(private = "file")
stand_in_read :: proc(fd: posix.FD, data: []u8, timeout_ms: c.int) -> bool {
	at := 0
	for at < len(data) {
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&fds[0], 1, timeout_ms) <= 0 {return false}
		remaining := len(data) - at
		n := posix.read(fd, raw_data(data[at:]), c.size_t(remaining))
		if n <= 0 {return false}
		at += int(n)
	}
	return true
}

@(private = "file")
stand_in_run :: proc(data: rawptr) {
	s := (^Stand_In)(data)
	for s.count < len(s.heard) {
		// Long enough for the client's next request while it is scripted;
		// after that, how long an unwanted one has to show up.
		wait: c.int = s.count < len(s.replies) ? 1000 : 300
		header: [4]u8
		if !stand_in_read(s.fd, header[:], wait) {return}
		n := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		if n > len(s.heard[0]) || !stand_in_read(s.fd, s.heard[s.count][:n], wait) {return}
		s.heard_len[s.count] = n
		s.count += 1
		if s.count > len(s.replies) {continue}
		reply := s.replies[s.count - 1]
		m := len(reply)
		frame := [4]u8{u8(m), u8(m >> 8), u8(m >> 16), u8(m >> 24)}
		posix.send(s.fd, raw_data(frame[:]), 4, {.NOSIGNAL})
		posix.send(s.fd, raw_data(reply), c.size_t(m), {.NOSIGNAL})
	}
}

@(private = "file")
heard :: proc(s: ^Stand_In, i: int) -> string {
	return string(s.heard[i][:s.heard_len[i]])
}

@(test)
test_the_user_bank_loads_only_into_a_bank_nobody_has_changed :: proc(t: ^testing.T) {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	Case :: struct {
		current: string,
		loads:   bool,
	}
	cases := []Case {
		// Just started on the factory bank: no --bank and no bank.json loaded.
		{"1 1 ok slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=", true},
		// A save, or a bank loaded since, or at start: that bank stays.
		{"1 1 ok slot=120 bank_rev=1 revision=4 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Factory\nname=Kept", false},
		{"1 1 ok slot=-1 bank_rev=7 revision=9 source=file archive_rev=2 archive_bank=-1 archive_patch=-1\nbank=file\nname=Lead", false},
		// A daemon that will not say: its bank is not risked either.
		{"1 1 err unknown_command unknown command", false},
	}
	for want in cases {
		fds: [2]posix.FD
		if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, {}, &fds) == .OK) {return}
		client := tui.Client{fd = fds[0], next_id = 1}
		stand_in := Stand_In{fd = fds[1], replies = []string{want.current, "1 2 ok label=User count=1 bank_rev=1"}}
		if !want.loads {stand_in.replies = stand_in.replies[:1]}
		th := thread.create_and_start_with_data(&stand_in, stand_in_run)
		loaded := tui.tui_load_user_bank(&client, "my banks/user bank.json")
		thread.join(th)
		thread.destroy(th)
		tui.client_close(&client)
		posix.close(fds[1])

		testing.expect_value(t, loaded, want.loads)
		if !testing.expect_value(t, stand_in.count, want.loads ? 2 : 1) {continue}
		testing.expect_value(t, heard(&stand_in, 0), "1 1 patch.current")
		if want.loads {
			testing.expect_value(t, heard(&stand_in, 1), fmt.tprintf("1 2 bank.load_file %s/my banks/user bank.json", cwd))
		}
	}
}

// One wire request to a real control server, framed by hand.
@(private = "file")
bank_ask :: proc(path, line: string) -> string {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return ""}
	defer posix.close(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) {addr.sun_path[i] = path[i]}
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {return ""}
	n := len(line)
	frame := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fd, raw_data(frame[:]), 4, {.NOSIGNAL})
	posix.send(fd, raw_data(line), c.size_t(n), {.NOSIGNAL})
	header: [4]u8
	if !stand_in_read(fd, header[:], 1000) {return ""}
	m := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	text := make([]u8, m, context.temp_allocator)
	if !stand_in_read(fd, text, 1000) {return ""}
	return string(text)
}

// The bank.list lines of the slots that hold a patch, after the header.
@(private = "file")
filled_slots :: proc(reply: string) -> (header: string, filled: [dynamic]string) {
	filled = make([dynamic]string, context.temp_allocator)
	lines := strings.split_lines(reply, context.temp_allocator)
	for line in lines[1:] {
		if strings.contains(line, " filled=1 ") {append(&filled, line)}
	}
	return lines[0], filled
}

@(test)
test_a_save_survives_the_next_tui_attaching :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	identity := standalone.Patch_Identity{slot = -1}
	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-userbank-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
		bank     = bank,
		identity = &identity,
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	// The User bank: one patch, under a label the factory bank does not have.
	only := patch.init_patch()
	only.name = "Only"
	file := fmt.tprintf("/tmp/quesynth-tui-userbank-%d.json", posix.getpid())
	defer os.remove(file)
	text := patch.write_bank_json("User Bank", []patch.Patch{only}, nil, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file_from_string(file, text) == nil) {return}

	// The first TUI on a fresh daemon loads it.
	first, fok := tui.client_connect(cs.path)
	if !testing.expect(t, fok) {return}
	testing.expect(t, tui.tui_load_user_bank(&first, file))
	tui.client_close(&first)
	header, filled := filled_slots(bank_ask(cs.path, "1 1 bank.list"))
	testing.expect_value(t, header, "1 1 ok label=User_Bank count=1 slots=128")
	testing.expect_value(t, len(filled), 1)

	// Something is saved into it; then a TUI attaches again, as a relaunch or
	// a second TUI does. The bank it finds keeps the save.
	testing.expect_value(t, bank_ask(cs.path, "1 2 patch.save 120 Kept"), "1 2 ok slot=120 name=Kept bank_rev=2")
	second, sok := tui.client_connect(cs.path)
	if !testing.expect(t, sok) {return}
	testing.expect(t, !tui.tui_load_user_bank(&second, file))
	tui.client_close(&second)
	header, filled = filled_slots(bank_ask(cs.path, "1 3 bank.list"))
	testing.expect_value(t, header, "1 3 ok label=User_Bank count=2 slots=128")
	if testing.expect_value(t, len(filled), 2) {
		testing.expect_value(t, filled[1], "slot=120 filled=1 name=Kept")
	}
	testing.expect(t, strings.contains(bank_ask(cs.path, "1 4 patch.current"), " bank_rev=2 "))
}
