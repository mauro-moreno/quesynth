#+build linux
package mcp_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

import "../../src/control"

// A stand-in for the daemon's control socket, so the MCP's own QCP client can
// be driven through every way a daemon can misbehave. It speaks the real
// framing (src/control) and nothing else: it answers a request from a table of
// canned replies, or fails in the way the test asks for, and it records every
// command line it was sent so a test can prove what did and did not reach it.

Behavior :: enum {
	Answer,
	Disconnect,
	Hang,
	Oversized_Length,
	Garbage_Payload,
	Wrong_Id,
	Truncated_Frame,
	Trickle,
}

Canned :: struct {
	prefix: string,
	reply:  string,
}

Standin :: struct {
	path:        string,
	listen_fd:   posix.FD,
	thread:      ^thread.Thread,
	running:     b32,
	behavior:    Behavior,
	connections: int,
	canned:      []Canned,
	// Written by the server thread only and read by a test after standin_stop,
	// in fixed storage so no allocation crosses between the two threads.
	command_text:  [64][1024]u8,
	command_len:   [64]int,
	command_count: int,
}

@(private = "file")
standin_serial: int

standin_path :: proc(tag: string) -> string {
	n := intrinsics.atomic_add(&standin_serial, 1)
	return fmt.aprintf("/tmp/qm-%s-%d-%d.sock", tag, posix.getpid(), n)
}

standin_start :: proc(s: ^Standin, canned: []Canned, tag := "standin") {
	s.path = standin_path(tag)
	s.canned = canned
	posix.unlink(strings.clone_to_cstring(s.path, context.temp_allocator))
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(s.path) { addr.sun_path[i] = s.path[i] }
	s.listen_fd = posix.socket(.UNIX, .STREAM)
	assert(s.listen_fd >= 0)
	assert(posix.bind(s.listen_fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK)
	assert(posix.listen(s.listen_fd, 16) == .OK)
	intrinsics.atomic_store(&s.running, true)
	s.thread = thread.create_and_start_with_data(s, standin_run)
}

standin_stop :: proc(s: ^Standin) {
	intrinsics.atomic_store(&s.running, false)
	thread.join(s.thread)
	thread.destroy(s.thread)
	posix.close(s.listen_fd)
	posix.unlink(strings.clone_to_cstring(s.path, context.temp_allocator))
	delete(s.path)
}

standin_set :: proc(s: ^Standin, behavior: Behavior) {
	intrinsics.atomic_store(&s.behavior, behavior)
}

standin_connections :: proc(s: ^Standin) -> int {
	return intrinsics.atomic_load(&s.connections)
}

// The commands received so far, in order. Call after standin_stop.
standin_commands :: proc(s: ^Standin) -> []string {
	out := make([]string, s.command_count, context.temp_allocator)
	for i in 0 ..< s.command_count { out[i] = string(s.command_text[i][:s.command_len[i]]) }
	return out
}

// A path nothing is listening on but that still exists as a socket, as a daemon
// that died without cleaning up leaves behind.
stale_socket :: proc() -> string {
	path := standin_path("stale")
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) { addr.sun_path[i] = path[i] }
	fd := posix.socket(.UNIX, .STREAM)
	assert(posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK)
	posix.close(fd)
	return path
}

@(private = "file")
standin_run :: proc(data: rawptr) {
	s := (^Standin)(data)
	for intrinsics.atomic_load(&s.running) {
		listener := posix.pollfd{fd = s.listen_fd, events = {.IN}}
		if posix.poll(&listener, 1, 5) <= 0 { continue }
		client := posix.accept(s.listen_fd, nil, nil)
		if client < 0 { continue }
		intrinsics.atomic_add(&s.connections, 1)
		standin_serve(s, client)
		posix.close(client)
	}
}

@(private = "file")
standin_serve :: proc(s: ^Standin, client: posix.FD) {
	reader: control.Frame_Reader
	defer control.frame_reader_destroy(&reader)
	payload: []u8
	buf: [4096]u8
	for payload == nil {
		ready := posix.pollfd{fd = client, events = {.IN}}
		if posix.poll(&ready, 1, 2000) <= 0 { return }
		n := posix.read(client, raw_data(buf[:]), c.size_t(len(buf)))
		if n <= 0 { return }
		control.frame_reader_push(&reader, buf[:int(n)])
		got, ok, invalid := control.frame_reader_next(&reader)
		if invalid { return }
		if ok { payload = got }
	}
	defer delete(payload)

	// "1 <id> <command...>", kept as it was written after the version and id,
	// so a space the daemon would trim is still there to be seen.
	request, parsed := control.request_parse(payload)
	if !parsed { return }
	command := string(payload)
	for _ in 0 ..< 2 {
		space := strings.index_byte(command, ' ')
		if space < 0 { break }
		command = command[space + 1:]
	}
	if s.command_count < len(s.command_text) {
		s.command_len[s.command_count] = copy(s.command_text[s.command_count][:], command)
		s.command_count += 1
	}

	reply := "err unknown_command no canned reply"
	for c in s.canned {
		if strings.has_prefix(command, c.prefix) {
			reply = c.reply
			break
		}
	}

	switch intrinsics.atomic_load(&s.behavior) {
	case .Answer:
		standin_send(client, fmt.tprintf("1 %d %s", request.id, reply), 0)
	case .Wrong_Id:
		standin_send(client, fmt.tprintf("1 %d %s", request.id + 1, reply), 0)
	case .Trickle:
		standin_send(client, fmt.tprintf("1 %d %s", request.id, reply), 1)
	case .Disconnect:
	case .Hang:
		// Hold the connection until the client gives up and closes it.
		for {
			ready := posix.pollfd{fd = client, events = {.IN}}
			if posix.poll(&ready, 1, 2000) <= 0 { return }
			if posix.read(client, raw_data(buf[:]), c.size_t(len(buf))) <= 0 { return }
		}
	case .Oversized_Length:
		header := [4]u8{0x01, 0x00, 0x01, 0x00}
		posix.write(client, raw_data(header[:]), 4)
		standin_wait_for_close(client)
	case .Garbage_Payload:
		standin_send(client, "this is not a response", 0)
	case .Truncated_Frame:
		frame := control.frame_encode(transmute([]u8)fmt.tprintf("1 %d %s", request.id, reply))
		defer delete(frame)
		posix.write(client, raw_data(frame), c.size_t(len(frame) - 3))
	}
}

@(private = "file")
standin_wait_for_close :: proc(client: posix.FD) {
	buf: [64]u8
	for {
		ready := posix.pollfd{fd = client, events = {.IN}}
		if posix.poll(&ready, 1, 1000) <= 0 { return }
		if posix.read(client, raw_data(buf[:]), c.size_t(len(buf))) <= 0 { return }
	}
}

// Write one framed payload. `chunk` of zero sends it in one write; otherwise it
// goes out that many bytes at a time with a pause, so the client must reassemble
// a frame from partial reads.
@(private = "file")
standin_send :: proc(client: posix.FD, payload: string, chunk: int) {
	frame := control.frame_encode(transmute([]u8)payload)
	defer delete(frame)
	if chunk <= 0 {
		posix.write(client, raw_data(frame), c.size_t(len(frame)))
		return
	}
	for sent := 0; sent < len(frame); sent += chunk {
		end := min(sent + chunk, len(frame))
		posix.write(client, raw_data(frame[sent:end]), c.size_t(end - sent))
		time.sleep(500 * time.Microsecond)
	}
}
