#+build linux
package mcp

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../../../src/control"

// One connection per request avoids replaying a mutation after a broken socket.
// The same bounded, nonblocking QCP framing used by the TUI, without its model.
// `sent` is whether any of the request was written before a failure, which is
// what separates "nothing happened" from "may have happened" for a change.
roundtrip :: proc(path, line: string) -> (payload: []u8, failure: Failure, sent: bool) {
	if len(line) > control.MAX_FRAME_PAYLOAD {
		return nil, {"daemon_error", "request exceeds QCP frame limit"}, false
	}
	addr: posix.sockaddr_un
	if path == "" || len(path) >= len(addr.sun_path) || strings.contains(path, "\x00") {
		return nil, {"daemon_unavailable", "invalid local socket path"}, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return nil, {"daemon_unavailable", "cannot open local socket"}, false }
	defer posix.close(fd)
	if posix.fcntl(fd, .SETFL, c.int(posix.O_NONBLOCK)) < 0 {
		return nil, {"daemon_unavailable", "cannot configure local socket"}, false
	}
	start := time.tick_now()
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) { addr.sun_path[i] = path[i] }
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		if posix.errno() != .EINPROGRESS || !wait(fd, {.OUT}, start) {
			return nil, {"daemon_unavailable", "no daemon listening on the local socket"}, false
		}
		err: c.int
		err_len := posix.socklen_t(size_of(err))
		if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &err, &err_len) != .OK || err != 0 {
			return nil, {"daemon_unavailable", "cannot connect to daemon"}, false
		}
	}
	frame := control.frame_encode(transmute([]u8)line)
	defer delete(frame)
	written := 0
	for written < len(frame) {
		if !wait(fd, {.OUT}, start) { return nil, {"daemon_timeout", "QCP deadline expired"}, sent }
		n := posix.send(fd, raw_data(frame[written:]), c.size_t(len(frame[written:])), {.NOSIGNAL})
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) { continue }
		if n <= 0 { return nil, {"daemon_error", "QCP disconnected"}, sent }
		written += int(n)
		sent = true
	}
	reader: control.Frame_Reader
	defer control.frame_reader_destroy(&reader)
	buf: [4096]u8
	for {
		if !wait(fd, {.IN}, start) { return nil, {"daemon_timeout", "QCP deadline expired"}, true }
		n := posix.read(fd, raw_data(buf[:]), c.size_t(len(buf)))
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) { continue }
		if n <= 0 { return nil, {"daemon_error", "QCP disconnected"}, true }
		control.frame_reader_push(&reader, buf[:int(n)])
		reply, ok, invalid := control.frame_reader_next(&reader)
		if invalid { return nil, {"daemon_error", "invalid QCP frame length"}, true }
		if ok { return reply, {}, true }
	}
}

@(private)
wait :: proc(fd: posix.FD, events: posix.Poll_Event, start: time.Tick) -> bool {
	for {
		remaining := 500 - int(time.duration_milliseconds(time.tick_since(start)))
		if remaining <= 0 { return false }
		fds := [1]posix.pollfd{{fd = fd, events = events}}
		n := posix.poll(&fds[0], 1, c.int(remaining))
		if n < 0 && posix.errno() == .EINTR { continue }
		return n > 0 && fds[0].revents & (events | {.HUP}) != {}
	}
}
