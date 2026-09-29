#+build linux
package standalone

import "base:intrinsics"
import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:thread"

import "../../src/control"

// The control server: a Unix-domain socket, an accept loop on its own thread,
// and one connection served at a time. It is the only thing in the daemon that
// speaks the protocol, and it reaches the engine only through the command ring
// and the snapshot in its Control_Context -- never directly. Nothing here runs
// on the audio thread.

CONTROL_READ_BUFFER :: 4096
CONTROL_POLL_TIMEOUT_MS :: 100

Control_Server :: struct {
	ctx:       Control_Context,
	path:      string,
	listen_fd: posix.FD,
	running:   b32,
	thread:    ^thread.Thread,
}

// Bind the socket and spawn the accept thread. Returns false if the socket
// could not be created, bound or listened on; the daemon treats that as "no
// control surface" rather than a fatal error, so audio still runs.
control_server_start :: proc(cs: ^Control_Server) -> bool {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(cs.path) >= len(addr.sun_path) {
		posix.close(fd)
		return false
	}
	for i in 0 ..< len(cs.path) {
		addr.sun_path[i] = cs.path[i]
	}
	addr.sun_path[len(cs.path)] = 0

	// Remove a stale socket from a previous run before binding, or bind fails
	// with EADDRINUSE against a file no daemon is listening on.
	cpath := strings.clone_to_cstring(cs.path)
	posix.unlink(cpath)
	delete(cpath)

	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return false
	}
	if posix.listen(fd, 8) != .OK {
		posix.close(fd)
		return false
	}

	cs.listen_fd = fd
	intrinsics.atomic_store(&cs.running, true)
	cs.thread = thread.create_and_start_with_data(cs, control_server_run)
	return true
}

// Stop the accept thread, close the socket and remove it from the filesystem.
control_server_stop :: proc(cs: ^Control_Server) {
	if cs.thread == nil {
		return
	}
	intrinsics.atomic_store(&cs.running, false)
	thread.join(cs.thread)
	thread.destroy(cs.thread)
	cs.thread = nil

	posix.close(cs.listen_fd)
	cpath := strings.clone_to_cstring(cs.path)
	posix.unlink(cpath)
	delete(cpath)
}

@(private = "file")
control_server_run :: proc(data: rawptr) {
	cs := (^Control_Server)(data)
	for intrinsics.atomic_load(&cs.running) {
		// poll with a timeout so the loop wakes to re-check `running` even with
		// no client knocking, rather than blocking in accept forever.
		fds := [1]posix.pollfd{{fd = cs.listen_fd, events = {.IN}}}
		n := posix.poll(&fds[0], 1, CONTROL_POLL_TIMEOUT_MS)
		if n <= 0 {
			continue
		}
		if .IN not_in fds[0].revents {
			continue
		}
		client := posix.accept(cs.listen_fd, nil, nil)
		if client < 0 {
			continue
		}
		control_serve(cs, client)
		posix.close(client)
	}
}

@(private = "file")
control_serve :: proc(cs: ^Control_Server, client: posix.FD) {
	reader: control.Frame_Reader
	defer control.frame_reader_destroy(&reader)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	buf: [CONTROL_READ_BUFFER]u8
	for intrinsics.atomic_load(&cs.running) {
		got := posix.read(client, raw_data(buf[:]), c.size_t(len(buf)))
		if got <= 0 {
			return // peer closed, or an error: drop the connection
		}
		control.frame_reader_push(&reader, buf[:got])

		for {
			payload, ok, err := control.frame_reader_next(&reader)
			if err {
				return // a framing fault taints the stream; close it
			}
			if !ok {
				break
			}

			req, parsed := control.request_parse(payload)
			if parsed {
				control_handle(&cs.ctx, req, &builder)
			} else {
				bad := control.Request {
					version = control.PROTOCOL_VERSION,
					id      = 0,
				}
				control_write_err(&builder, bad, .Invalid_Payload, "malformed request")
			}
			delete(payload)

			frame := control.frame_encode(transmute([]u8)strings.to_string(builder))
			control_write_all(client, frame)
			delete(frame)
		}
	}
}

@(private = "file")
control_write_all :: proc(fd: posix.FD, data: []u8) {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.write(fd, raw_data(data[sent:]), c.size_t(remaining))
		if n <= 0 {
			return
		}
		sent += int(n)
	}
}
