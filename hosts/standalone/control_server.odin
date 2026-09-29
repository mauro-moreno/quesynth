#+build linux
package standalone

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"

import "../../src/control"

// The control server: a Unix-domain socket and one thread that multiplexes every
// connection with poll. It is the only thing in the daemon that speaks the
// protocol, and it reaches the engine only through the command ring and the
// snapshot in its Control_Context -- never directly. Nothing here runs on the
// audio thread.
//
// One poll thread remains the sole command-ring producer. Both directions are
// nonblocking: readiness to read says nothing about a peer's willingness to read
// our response. Bound pending output and disconnect a client that exceeds it.

CONTROL_READ_BUFFER :: 4096
CONTROL_POLL_TIMEOUT_MS :: 100
MAX_CONNECTIONS :: 16
CONTROL_OUTPUT_LIMIT :: 256 * 1024

Control_Server :: struct {
	ctx:       Control_Context,
	path:      string,
	listen_fd: posix.FD,
	lock_fd:   posix.FD,
	bound:     bool,
	identity:  posix.stat_t,
	running:   b32,
	thread:    ^thread.Thread,
}

@(private = "file")
Connection :: struct {
	fd:     posix.FD,
	reader: control.Frame_Reader,
	output: [dynamic]u8,
	sent:   int,
	used:   bool,
}

// Claim the endpoint before opening audio. Keep the adjacent advisory lock for
// its entire lifetime, including cleanup. Never unlink the lock file: replacing
// its inode would let two concurrent starters each hold an "exclusive" lock.
control_server_bind :: proc(cs: ^Control_Server) -> bool {
	if cs.bound { return true }
	addr: posix.sockaddr_un
	if len(cs.path) == 0 || len(cs.path) >= len(addr.sun_path) || strings.contains(cs.path, "\x00") {
		return false
	}
	cpath := strings.clone_to_cstring(cs.path)
	defer delete(cpath)
	clock := fmt.caprintf("%s.lock", cs.path)
	defer delete(clock)
	lock := posix.open(clock, {.CREAT, .RDWR, .NOFOLLOW, .NONBLOCK, .CLOEXEC},
		posix.mode_t{.IRUSR, .IWUSR})
	if lock < 0 { return false }
	claimed := false
	defer if !claimed { posix.close(lock) }
	ls, named_lock: posix.stat_t
	if posix.fstat(lock, &ls) != .OK || !posix.S_ISREG(ls.st_mode) ||
		ls.st_uid != posix.getuid() || ls.st_nlink != 1 { return false }
	if linux.flock(linux.Fd(lock), {.EX, .NB}) != nil { return false }
	if posix.lstat(clock, &named_lock) != .OK ||
		ls.st_dev != named_lock.st_dev || ls.st_ino != named_lock.st_ino { return false }

	addr.sun_family = .UNIX
	for i in 0 ..< len(cs.path) { addr.sun_path[i] = cs.path[i] }
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return false }
	defer if !claimed { posix.close(fd) }
	if posix.fcntl(fd, .SETFL, c.int(posix.O_NONBLOCK)) < 0 { return false }

	stale: posix.stat_t
	if posix.lstat(cpath, &stale) == .OK {
		// A failed probe alone does not prove staleness: permissions, a full
		// listen backlog or a foreign regular file must never authorize unlink.
		if !posix.S_ISSOCK(stale.st_mode) || stale.st_uid != posix.getuid() { return false }
		probe := posix.socket(.UNIX, .STREAM)
		if probe < 0 { return false }
		defer posix.close(probe)
		if posix.fcntl(probe, .SETFL, c.int(posix.O_NONBLOCK)) < 0 { return false }
		if posix.connect(probe, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK {
			return false
		}
		if posix.errno() != .ECONNREFUSED { return false }
		current: posix.stat_t
		if posix.lstat(cpath, &current) != .OK || current.st_dev != stale.st_dev ||
			current.st_ino != stale.st_ino { return false }
		if posix.unlink(cpath) != .OK { return false }
	} else if posix.errno() != .ENOENT {
		return false
	}
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		return false
	}
	if posix.lstat(cpath, &cs.identity) != .OK { return false }
	defer if !claimed { control_unlink_owned(cs) }
	if posix.chmod(cpath, {.IRUSR, .IWUSR}) != .OK || posix.listen(fd, MAX_CONNECTIONS) != .OK {
		return false
	}
	cs.listen_fd = fd
	cs.lock_fd = lock
	cs.bound = true
	claimed = true
	return true
}

// Binding is separate so the daemon can own its endpoint before acquiring the
// audio device, while the serving thread starts only once its context is ready.
control_server_start :: proc(cs: ^Control_Server) -> bool {
	if cs.thread != nil { return false }
	if !control_server_bind(cs) { return false }
	intrinsics.atomic_store(&cs.running, true)
	cs.thread = thread.create_and_start_with_data(cs, control_server_run)
	return true
}

@(private = "file")
control_unlink_owned :: proc(cs: ^Control_Server) {
	cpath := strings.clone_to_cstring(cs.path)
	defer delete(cpath)
	current: posix.stat_t
	if posix.lstat(cpath, &current) == .OK && posix.S_ISSOCK(current.st_mode) &&
		current.st_dev == cs.identity.st_dev && current.st_ino == cs.identity.st_ino {
		posix.unlink(cpath)
	}
}

control_server_stop :: proc(cs: ^Control_Server) {
	if !cs.bound { return }
	if cs.thread != nil {
		intrinsics.atomic_store(&cs.running, false)
		thread.join(cs.thread)
		thread.destroy(cs.thread)
		cs.thread = nil
	}
	posix.close(cs.listen_fd)
	control_unlink_owned(cs)
	posix.close(cs.lock_fd)
	cs.bound = false
}

@(private = "file")
control_server_run :: proc(data: rawptr) {
	cs := (^Control_Server)(data)

	conns: [MAX_CONNECTIONS]Connection
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// pollset[0] is always the listen socket; the rest track active connections.
	pollset: [MAX_CONNECTIONS + 1]posix.pollfd
	conn_of: [MAX_CONNECTIONS + 1]int // pollset index -> connection index

	for intrinsics.atomic_load(&cs.running) {
		pollset[0] = {
			fd     = cs.listen_fd,
			events = {.IN},
		}
		nfds := 1
		for ci in 0 ..< MAX_CONNECTIONS {
			if conns[ci].used {
				pollset[nfds] = {
					fd     = conns[ci].fd,
					events = len(conns[ci].output) > 0 ? posix.Poll_Event{.OUT} : posix.Poll_Event{.IN},
				}
				conn_of[nfds] = ci
				nfds += 1
			}
		}

		ready := posix.poll(&pollset[0], posix.nfds_t(nfds), CONTROL_POLL_TIMEOUT_MS)
		if ready <= 0 {
			continue
		}

		// A knock on the listen socket: accept into a free slot, or refuse if
		// the daemon is already holding the maximum number of connections.
		if .IN in pollset[0].revents {
			client := posix.accept(cs.listen_fd, nil, nil)
			if client >= 0 {
				if posix.fcntl(client, .SETFL, c.int(posix.O_NONBLOCK)) < 0 {
					posix.close(client)
					continue
				}
				slot := -1
				for ci in 0 ..< MAX_CONNECTIONS {
					if !conns[ci].used {
						slot = ci
						break
					}
				}
				if slot >= 0 {
					conns[slot] = Connection {
						fd   = client,
						used = true,
					}
				} else {
					posix.close(client)
				}
			}
		}

		// Every readable (or hung-up) connection gets one non-blocking service
		// pass. A connection that closed or faulted is torn down and its slot
		// freed; the others are untouched.
		for pi in 1 ..< nfds {
			re := pollset[pi].revents
			if re == {} {
				continue
			}
			ci := conn_of[pi]
			if !control_serve_ready(cs, &conns[ci], &builder, re) {
				posix.close(conns[ci].fd)
				control.frame_reader_destroy(&conns[ci].reader)
				delete(conns[ci].output)
				conns[ci] = {}
			}
		}
	}

	for ci in 0 ..< MAX_CONNECTIONS {
		if conns[ci].used {
			posix.close(conns[ci].fd)
			control.frame_reader_destroy(&conns[ci].reader)
			delete(conns[ci].output)
		}
	}
}

// Drain only the bytes already readable, with bounded work and output per pass.
// A pending response disables input until flushed, preserving per-client order
// without allowing a slow reader to accumulate unbounded queued responses.
@(private = "file")
control_serve_ready :: proc(cs: ^Control_Server, conn: ^Connection, builder: ^strings.Builder, re: posix.Poll_Event) -> bool {
	if re & {.ERR, .NVAL} != {} { return false }
	if .IN in re && len(conn.output) == 0 {
		buf: [CONTROL_READ_BUFFER]u8
		got := posix.read(conn.fd, raw_data(buf[:]), c.size_t(len(buf)))
		if got == 0 { return false }
		if got < 0 {
			return posix.errno() == .EAGAIN || posix.errno() == .EINTR
		}
		control.frame_reader_push(&conn.reader, buf[:int(got)])
		for {
			payload, ok, err := control.frame_reader_next(&conn.reader)
			if err { return false }
			if !ok { break }
			req, parsed := control.request_parse(payload)
			if parsed {
				control_handle(&cs.ctx, req, builder)
			} else {
				control_write_err(builder, control.Request{version = control.PROTOCOL_VERSION},
					.Invalid_Payload, "malformed request")
			}
			delete(payload)
			frame := control.frame_encode(transmute([]u8)strings.to_string(builder^))
			if len(conn.output) + len(frame) > CONTROL_OUTPUT_LIMIT {
				delete(frame)
				return false
			}
			append(&conn.output, ..frame)
			delete(frame)
		}
	}
	if len(conn.output) > 0 {
		data := conn.output[conn.sent:]
		// MSG_NOSIGNAL confines a reset/broken pipe to this connection, rather
		// than killing the daemon and its otherwise independent audio thread.
		n := posix.send(conn.fd, raw_data(data), c.size_t(len(data)), {.NOSIGNAL})
		if n < 0 {
			return posix.errno() == .EAGAIN || posix.errno() == .EINTR
		}
		if n == 0 { return false }
		conn.sent += int(n)
		if conn.sent == len(conn.output) {
			clear(&conn.output)
			conn.sent = 0
		}
	}
	return .HUP not_in re
}
