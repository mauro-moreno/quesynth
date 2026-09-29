package tui

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:sys/posix"

import "../../../src/control"

// The protocol client half of the TUI. It speaks only the public control
// protocol over the Unix socket -- it imports src/control and src/registry, and
// never src/engine or the daemon package. That is the whole point of the slice:
// if the TUI can drive the synth through this and nothing else, so can any
// future client.

Client :: struct {
	fd:      posix.FD,
	next_id: int,
}

client_connect :: proc(path: string) -> (Client, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return {}, false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		posix.close(fd)
		return {}, false
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return {}, false
	}
	return Client{fd = fd, next_id = 1}, true
}

client_close :: proc(cl: ^Client) {
	if cl.fd >= 0 {
		posix.close(cl.fd)
		cl.fd = -1
	}
}

// The current stored value of a parameter. ok=false on a transport error, which
// the caller reads as "the daemon went away".
client_get :: proc(cl: ^Client, id: string) -> (value: int, ok: bool) {
	line := fmt.tprintf("%d %d parameter.get %s", control.PROTOCOL_VERSION, cl.next_id, id)
	cl.next_id += 1
	return client_value_request(cl, line)
}

// Set a parameter and return the value the daemon accepted (echoed back at
// once, before the audio thread applies it). ok=false on a transport error or a
// rejected value.
client_set :: proc(cl: ^Client, id: string, value: int) -> (applied: int, ok: bool) {
	line := fmt.tprintf(
		"%d %d parameter.set %s %d",
		control.PROTOCOL_VERSION,
		cl.next_id,
		id,
		value,
	)
	cl.next_id += 1
	return client_value_request(cl, line)
}

// Send a request and read the "value=" field of an ok response.
@(private)
client_value_request :: proc(cl: ^Client, line: string) -> (value: int, ok: bool) {
	payload, sent := client_roundtrip(cl, line)
	if !sent {
		return 0, false
	}
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok {
		return 0, false
	}
	value_str, has := control.response_field(resp.fields, "value")
	if !has {
		return 0, false
	}
	return strconv.parse_int(value_str)
}

@(private)
client_roundtrip :: proc(cl: ^Client, line: string) -> (payload: []u8, ok: bool) {
	frame := control.frame_encode(transmute([]u8)line)
	defer delete(frame)
	if !client_write_all(cl.fd, frame) {
		return nil, false
	}
	return client_read_frame(cl.fd)
}

@(private)
client_write_all :: proc(fd: posix.FD, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.write(fd, raw_data(data[sent:]), c.size_t(remaining))
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

@(private)
client_read_frame :: proc(fd: posix.FD) -> ([]u8, bool) {
	reader: control.Frame_Reader
	defer control.frame_reader_destroy(&reader)
	buf: [1024]u8
	for {
		n := posix.read(fd, raw_data(buf[:]), c.size_t(len(buf)))
		if n <= 0 {
			return nil, false
		}
		control.frame_reader_push(&reader, buf[:int(n)])
		payload, ok, err := control.frame_reader_next(&reader)
		if err {
			return nil, false
		}
		if ok {
			return payload, true
		}
	}
}
