#+build linux
package standalone

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"

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
//
// Nothing here waits for the audio thread. A guarded set_many is queued and the
// connection that sent it is left owed an answer (its Wait_Ticket): it is read
// no further, and the answer is framed into its output when the audio thread's
// result for that batch comes by, or the outcome is reported unknown once
// CHECKED_WAIT_LIMIT has passed or the server stops. A patch.save whose edits
// the audio thread has not yet applied waits the same way, for the snapshot to
// show them, and saves nothing if that has not happened by then. Every other
// connection is served all the while.
//
// This thread runs as long as the daemon, so nothing frees its temporary
// allocator for it: each request gets its own, given back once it is answered.

CONTROL_READ_BUFFER :: 4096
// Short because the poll tick is also how soon a Program Change from a
// keyboard is loaded: the audio thread forwards it, and nothing wakes this
// thread for it but the timeout. Ten milliseconds is about one audio period.
CONTROL_POLL_TIMEOUT_MS :: 10
// The tick while a connection waits for the audio thread, so its answer is not
// sat on for a tenth of a period.
CONTROL_WAIT_POLL_TIMEOUT_MS :: 1
// How long a guarded batch, or a save waiting for the edits ahead of it, may
// wait for the audio thread.
CHECKED_WAIT_LIMIT :: 250 * time.Millisecond
// How long a stopping server gives its last replies to reach clients that are
// slow to read them. Short, so a client that reads nothing cannot hold up the
// shutdown: what it has not taken by then is lost with the connection.
CONTROL_STOP_FLUSH_LIMIT :: 100 * time.Millisecond
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
	// A guarded batch of this connection is queued and its answer is owed
	// (wait.serial is not 0). The request's version and id are kept, because
	// its payload is gone by the time the answer is written.
	wait:       Wait_Ticket,
	wait_req:   control.Request,
	wait_since: time.Tick,
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

// Whether the socket at the path is still the exact one this daemon bound: the
// same inode it recorded at bind. False if the file is gone, is no longer a
// socket, or was replaced -- in which case this daemon no longer owns the
// endpoint and should stand down.
@(private = "file")
control_owns_endpoint :: proc(cs: ^Control_Server) -> bool {
	cpath := strings.clone_to_cstring(cs.path)
	defer delete(cpath)
	current: posix.stat_t
	if posix.lstat(cpath, &current) != .OK || !posix.S_ISSOCK(current.st_mode) {
		return false
	}
	return current.st_dev == cs.identity.st_dev && current.st_ino == cs.identity.st_ino
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

	own_check := 0
	for intrinsics.atomic_load(&cs.running) {
		// Periodically confirm this daemon still owns its endpoint. If the socket
		// was removed or a newer daemon replaced it, this one is unreachable, so
		// shut it down rather than let it keep playing MIDI and audio no client
		// can steer -- an orphaned daemon that "keeps sounding" after its socket
		// is gone. Throttled to about once a second at the poll cadence.
		own_check += 1
		if own_check >= 1000 / CONTROL_POLL_TIMEOUT_MS {
			own_check = 0
			if !control_owns_endpoint(cs) {
				request_shutdown()
				break
			}
		}
		// Answer what the audio thread has answered, before polling, so a
		// connection closed here is not polled and its slot not reused under a
		// stale result.
		control_resolve_waits(cs, &conns, &builder)

		pollset[0] = {
			fd     = cs.listen_fd,
			events = {.IN},
		}
		nfds := 1
		waiting := false
		for ci in 0 ..< MAX_CONNECTIONS {
			if conns[ci].used {
				// A connection owed an answer is not polled for input: nothing it
				// sends may be read, or answered, before that answer. Poll still
				// reports it hung up.
				owed := control_wait_owed(conns[ci].wait)
				events: posix.Poll_Event
				if len(conns[ci].output) > 0 {
					events = {.OUT}
				} else if !owed {
					events = {.IN}
				}
				waiting ||= owed
				pollset[nfds] = {
					fd     = conns[ci].fd,
					events = events,
				}
				conn_of[nfds] = ci
				nfds += 1
			}
		}

		ready := posix.poll(&pollset[0], posix.nfds_t(nfds), waiting ? CONTROL_WAIT_POLL_TIMEOUT_MS : CONTROL_POLL_TIMEOUT_MS)
		// Every tick, a client or not: a keyboard choosing a patch needs none.
		program_select_drain(&cs.ctx)
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
				control_close(&conns[ci])
			}
		}
	}

	// Stopped, by daemon.shutdown, a signal or a lost endpoint. A connection owed
	// an answer still gets one before it closes -- the result if the audio
	// thread has posted it, otherwise the unknown outcome at once, since the
	// batch stays queued and the audio thread runs on until the stream stops --
	// and nothing more is read from it or served. Then the replies get a short
	// while to go out, so none is cut off mid-frame.
	control_resolve_waits(cs, &conns, &builder, stopping = true)
	control_flush_all(&conns)
	for ci in 0 ..< MAX_CONNECTIONS {
		if conns[ci].used {
			control_close(&conns[ci])
		}
	}
}

@(private = "file")
control_close :: proc(conn: ^Connection) {
	posix.close(conn.fd)
	control.frame_reader_destroy(&conn.reader)
	delete(conn.output)
	conn^ = {}
}

// Answer the connections owed one. Every result the audio thread has posted is
// taken, and goes to the connection whose ticket carries its serial; a result no
// connection waits for (its sender gave up or hung up) is dropped, and since a
// serial is never reused it cannot answer any other request. A save is stored
// and answered once the snapshot shows what it waited for. Then a connection
// whose limit has passed is told it was not answered in time, as is every
// connection still waiting when the server is `stopping`. A result that is
// there by now wins over the limit.
@(private = "file")
control_resolve_waits :: proc(cs: ^Control_Server, conns: ^[MAX_CONNECTIONS]Connection, builder: ^strings.Builder, stopping := false) {
	if cs.ctx.ring != nil {
		for {
			result, ok := param_ring_take_result(cs.ctx.ring)
			if !ok { break }
			for ci in 0 ..< MAX_CONNECTIONS {
				conn := &conns[ci]
				if conn.used && conn.wait.serial != 0 && conn.wait.serial == result.serial {
					control_write_checked_reply(builder, conn.wait_req, conn.wait, result)
					if !control_finish_wait(cs, conn, builder, stopping) { control_close(conn) }
					break
				}
			}
		}
	}
	for ci in 0 ..< MAX_CONNECTIONS {
		conn := &conns[ci]
		if conn.used && conn.wait.save && control_save_ready(&cs.ctx, conn.wait_req, conn.wait, builder) {
			if !control_finish_wait(cs, conn, builder, stopping) { control_close(conn) }
		}
	}
	for ci in 0 ..< MAX_CONNECTIONS {
		conn := &conns[ci]
		if conn.used && control_wait_owed(conn.wait) && (stopping || time.tick_since(conn.wait_since) >= CHECKED_WAIT_LIMIT) {
			if conn.wait.save {
				control_write_save_refused(builder, conn.wait_req)
			} else {
				control_write_checked_unknown(builder, conn.wait_req)
			}
			if !control_finish_wait(cs, conn, builder, stopping) { control_close(conn) }
		}
	}
}

// The reply to a connection's guarded request is in `builder`: queue it ahead of
// anything the connection sent after the request, which is already buffered and
// is answered now, and which may itself start another wait. A stopping server
// only queues the reply: it executes nothing more, so what was sent after the
// request is not answered.
@(private = "file")
control_finish_wait :: proc(cs: ^Control_Server, conn: ^Connection, builder: ^strings.Builder, stopping: bool) -> bool {
	conn.wait = {}
	if !control_queue_reply(conn, builder) { return false }
	if stopping { return true }
	return control_serve_frames(cs, conn, builder) && control_flush(conn, {})
}

// Frame the reply in `builder` onto the connection's output. False when that
// would take the output past its limit.
@(private = "file")
control_queue_reply :: proc(conn: ^Connection, builder: ^strings.Builder) -> bool {
	frame := control.frame_encode(transmute([]u8)strings.to_string(builder^))
	defer delete(frame)
	if len(conn.output) + len(frame) > CONTROL_OUTPUT_LIMIT { return false }
	append(&conn.output, ..frame)
	return true
}

// Answer, in order, every request already buffered for the connection, up to one
// that has to wait for the audio thread; the ones after it stay buffered until
// that is answered.
@(private = "file")
control_serve_frames :: proc(cs: ^Control_Server, conn: ^Connection, builder: ^strings.Builder) -> bool {
	for !control_wait_owed(conn.wait) {
		payload, ok, err := control.frame_reader_next(&conn.reader)
		if err { return false }
		if !ok { break }
		if !control_serve_frame(cs, conn, builder, payload) { return false }
	}
	return true
}

// One request, and its reply queued unless it has to wait. What it takes from
// the temporary allocator goes back when it is done: nothing a reply, the bank,
// the archive or the identity keeps is allocated there, and without this every
// bank.write, file load and archive listing would add to it for good.
@(private = "file")
control_serve_frame :: proc(cs: ^Control_Server, conn: ^Connection, builder: ^strings.Builder, payload: []u8) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	defer delete(payload)
	req, parsed := control.request_parse(payload)
	if parsed {
		conn.wait = control_handle(&cs.ctx, req, builder)
		if control_wait_owed(conn.wait) {
			conn.wait_req = control.Request{version = req.version, id = req.id}
			conn.wait_since = time.tick_now()
			return true
		}
	} else {
		control_write_err(builder, control.Request{version = control.PROTOCOL_VERSION},
			.Invalid_Payload, "malformed request")
	}
	return control_queue_reply(conn, builder)
}

// Drain only the bytes already readable, with bounded work and output per pass.
// A pending response disables input until flushed, preserving per-client order
// without allowing a slow reader to accumulate unbounded queued responses.
@(private = "file")
control_serve_ready :: proc(cs: ^Control_Server, conn: ^Connection, builder: ^strings.Builder, re: posix.Poll_Event) -> bool {
	if re & {.ERR, .NVAL} != {} { return false }
	if control_wait_owed(conn.wait) {
		// Owed an answer, so the socket was asked about nothing but a hang-up.
		if .HUP in re { return false }
	} else if .IN in re && len(conn.output) == 0 {
		buf: [CONTROL_READ_BUFFER]u8
		got := posix.read(conn.fd, raw_data(buf[:]), c.size_t(len(buf)))
		if got == 0 { return false }
		if got < 0 {
			return posix.errno() == .EAGAIN || posix.errno() == .EINTR
		}
		control.frame_reader_push(&conn.reader, buf[:int(got)])
		if !control_serve_frames(cs, conn, builder) { return false }
	}
	return control_flush(conn, re)
}

// Send what is pending. The result is whether the connection stays open.
@(private = "file")
control_flush :: proc(conn: ^Connection, re: posix.Poll_Event) -> bool {
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

// The last sends of a stopping server. Each connection with output left gets it
// sent as its reader takes it, for CONTROL_STOP_FLUSH_LIMIT in all at most; one
// that has nothing left to send, faults or hangs up is closed at once, and the
// caller closes whatever is still there after that.
@(private = "file")
control_flush_all :: proc(conns: ^[MAX_CONNECTIONS]Connection) {
	started := time.tick_now()
	for {
		pollset: [MAX_CONNECTIONS]posix.pollfd
		conn_of: [MAX_CONNECTIONS]int
		nfds := 0
		for ci in 0 ..< MAX_CONNECTIONS {
			if !conns[ci].used { continue }
			if len(conns[ci].output) == 0 {
				control_close(&conns[ci])
				continue
			}
			pollset[nfds] = {
				fd     = conns[ci].fd,
				events = {.OUT},
			}
			conn_of[nfds] = ci
			nfds += 1
		}
		left := CONTROL_STOP_FLUSH_LIMIT - time.tick_since(started)
		if nfds == 0 || left <= 0 { return }
		if posix.poll(&pollset[0], posix.nfds_t(nfds), c.int(left / time.Millisecond) + 1) <= 0 { continue }
		for pi in 0 ..< nfds {
			re := pollset[pi].revents
			if re == {} { continue }
			conn := &conns[conn_of[pi]]
			if re & {.ERR, .NVAL} != {} || !control_flush(conn, re) {
				control_close(conn)
			}
		}
	}
}
