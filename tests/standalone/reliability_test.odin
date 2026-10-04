#+build linux
package standalone_tests

import "base:intrinsics"

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import standalone "../../hosts/standalone"

@(private)
// Literal QCP bytes, independent of the encoder under test.
reliability_send :: proc(fd: posix.FD, text: string) {
	n := len(text)
	header := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fd, raw_data(header[:]), 4, {.NOSIGNAL})
	posix.send(fd, raw_data(text), c.size_t(n), {.NOSIGNAL})
}

@(private)
reliability_reply :: proc(fd: posix.FD) -> string {
	header: [4]u8
	if !reliability_read_exact(fd, header[:]) { return "TIMEOUT/CLOSED" }
	n := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	if n < 0 || n > 65536 { return "BAD LENGTH" }
	payload := make([]u8, n, context.temp_allocator)
	if !reliability_read_exact(fd, payload) { return "TIMEOUT/CLOSED" }
	return string(payload)
}

@(private)
reliability_read_exact :: proc(fd: posix.FD, data: []u8) -> bool {
	at := 0
	deadline := time.tick_now()
	for at < len(data) {
		if time.tick_since(deadline) > time.Second { return false }
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&fds[0], 1, 500) <= 0 { return false }
		remaining := len(data) - at
		n := posix.read(fd, raw_data(data[at:]), c.size_t(remaining))
		if n <= 0 { return false }
		at += int(n)
	}
	return true
}

@(private)
// Whether the peer closes the connection within the limit, with nothing left to
// read before the end: a read that returns 0, not a timeout and not more bytes.
reliability_hung_up :: proc(fd: posix.FD, limit: time.Duration) -> bool {
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	if posix.poll(&fds[0], 1, c.int(limit / time.Millisecond)) <= 0 { return false }
	next: [1]u8
	return posix.read(fd, raw_data(next[:]), 1) == 0
}

@(test)
test_control_server_self_terminates_when_endpoint_vanishes :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-orphan-%d.sock", posix.getpid()),
		ctx = {ring = &ring, snapshot = &snap, state = &state},
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) { return }
	defer standalone.control_server_stop(&cs)

	// A client the server has accepted, so its standing down can be seen. The
	// shutdown flag alone cannot show it: it belongs to the whole process, and
	// another test's daemon.shutdown may have raised it already.
	client, connected := connect_unix(cs.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(client)
	reliability_send(client, "1 1 daemon.status")
	status := reliability_reply(client)
	testing.expectf(t, strings.has_prefix(status, "1 1 ok"), "daemon.status -> %s", status)

	// Take the socket out from under it, exactly as a newer daemon's takeover or a
	// stray unlink would. The server must notice it no longer owns its endpoint
	// and ask the daemon to shut down, rather than keep running unreachably.
	cpath := strings.clone_to_cstring(cs.path)
	defer delete(cpath)
	posix.unlink(cpath)

	testing.expect(t, reliability_hung_up(client, 3 * time.Second), "a daemon whose socket vanished must stop serving")
	testing.expect(t, standalone.shutdown_requested(), "a daemon whose socket vanished must request shutdown")
}

@(test)
test_control_backpressure_does_not_block_other_clients :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-pressure-%d.sock", posix.getpid()),
		ctx = {ring = &ring, snapshot = &snap, state = &state},
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) { return }
	defer standalone.control_server_stop(&cs)
	slow, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) { return }
	defer posix.close(slow)
	// Small requests produce much larger replies. This fills the peer's receive
	// buffer even though it never sends a partial or oversized request.
	for _ in 0 ..< 100 { reliability_send(slow, "1 1 parameter.list") }
	time.sleep(100 * time.Millisecond)
	other, connected := connect_unix(cs.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(other)
	reliability_send(other, "1 42 daemon.status")
	testing.expect(t, strings.has_prefix(reliability_reply(other), "1 42 ok"),
		"a non-reading client must not block another client's status")
}

@(test)
test_control_socket_preserves_foreign_files :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/quesynth-foreign-%d.sock", posix.getpid())
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	fd := posix.open(cpath, {.CREAT, .EXCL, .RDWR}, posix.mode_t{.IRUSR, .IWUSR})
	if !testing.expect(t, fd >= 0) { return }
	defer posix.close(fd)
	defer posix.unlink(cpath)
	text := "not a socket"
	posix.write(fd, raw_data(text), c.size_t(len(text)))
	before: posix.stat_t
	posix.lstat(cpath, &before)
	cs := standalone.Control_Server{path = path}
	started := standalone.control_server_start(&cs)
	defer if started { standalone.control_server_stop(&cs) }
	testing.expect(t, !started, "must not replace a foreign file with a socket")
	after: posix.stat_t
	testing.expect(t, posix.lstat(cpath, &after) == .OK)
	testing.expect_value(t, after.st_ino, before.st_ino)
	testing.expect(t, posix.S_ISREG(after.st_mode))
}

@(private)
Socket_Starter :: struct {
	cs: standalone.Control_Server,
	go: ^b32,
	ok: bool,
}

@(private)
start_socket_together :: proc(data: rawptr) {
	s := (^Socket_Starter)(data)
	for !intrinsics.atomic_load(s.go) { thread.yield() }
	s.ok = standalone.control_server_start(&s.cs)
}

@(test)
test_control_socket_concurrent_start_has_one_owner :: proc(t: ^testing.T) {
	for round in 0 ..< 10 {
		path := fmt.tprintf("/tmp/quesynth-race-%d-%d.sock", posix.getpid(), round)
		if round % 2 == 0 {
			fd := reliability_bound_socket(path)
			if !testing.expect(t, fd >= 0) { return }
			posix.close(fd) // leave a stale inode, just as a killed daemon does
		}
		go: b32
		starters: [8]Socket_Starter
		threads: [8]^thread.Thread
		for &s, i in starters {
			s.cs.path = path
			s.go = &go
			threads[i] = thread.create_and_start_with_data(&s, start_socket_together)
		}
		intrinsics.atomic_store(&go, true)
		winners := 0
		for th in threads { thread.join(th); thread.destroy(th) }
		for &s in starters {
			if s.ok { winners += 1; standalone.control_server_stop(&s.cs) }
		}
		if !testing.expect_value(t, winners, 1) { return }
	}
}

@(private)
reliability_bound_socket :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return -1 }
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for b, i in path { addr.sun_path[i] = u8(b) }
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(test)
test_control_socket_live_owner_and_replaced_path_survive :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/quesynth-live-owner-%d.sock", posix.getpid())
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	defer posix.unlink(cpath)
	// A listener not using our lock must also be protected, even with a full
	// backlog (connect then reports EAGAIN, not proof of a stale socket).
	fd := reliability_bound_socket(path)
	if !testing.expect(t, fd >= 0) { return }
	defer posix.close(fd)
	posix.listen(fd, 1)
	peers: [2]posix.FD
	for &p in peers { p, _ = connect_unix(path) }
	defer for p in peers { posix.close(p) }
	before, after: posix.stat_t
	posix.lstat(cpath, &before)
	cs := standalone.Control_Server{path = path}
	testing.expect(t, !standalone.control_server_start(&cs))
	posix.lstat(cpath, &after)
	testing.expect_value(t, after.st_ino, before.st_ino)
	testing.expect(t, standalone.daemon_is_running(path))

	// Cleanup cannot delete an unrelated file installed at the old path.
	posix.unlink(cpath)
	if !testing.expect(t, standalone.control_server_start(&cs)) { return }
	posix.unlink(cpath)
	replacement := posix.open(cpath, {.CREAT, .EXCL, .RDWR}, posix.mode_t{.IRUSR, .IWUSR})
	if !testing.expect(t, replacement >= 0) { standalone.control_server_stop(&cs); return }
	defer posix.close(replacement)
	standalone.control_server_stop(&cs)
	testing.expect(t, posix.lstat(cpath, &after) == .OK && posix.S_ISREG(after.st_mode))
	testing.expect_value(t, cs.path, path)
}

@(test)
test_control_socket_preserves_symlinks_and_path_bytes :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/quesynth-link-%d.sock", posix.getpid())
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	if !testing.expect(t, posix.symlink("/missing-quesynth-target", cpath) == .OK) { return }
	defer posix.unlink(cpath)
	cs := standalone.Control_Server{path = path}
	testing.expect(t, !standalone.control_server_start(&cs))
	st: posix.stat_t
	testing.expect(t, posix.lstat(cpath, &st) == .OK && posix.S_ISLNK(st.st_mode))
	cs.path = fmt.tprintf("%s\x00suffix", path)
	testing.expect(t, !standalone.control_server_start(&cs))
	testing.expect(t, posix.lstat(cpath, &st) == .OK && posix.S_ISLNK(st.st_mode))
}

@(test)
test_control_idle_partial_disconnected_and_concurrent_clients :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-multiplex-%d.sock", posix.getpid()),
		ctx = {ring = &ring, snapshot = &snap, state = &state},
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) { return }
	defer standalone.control_server_stop(&cs)
	idle, _ := connect_unix(cs.path)
	defer posix.close(idle)
	partial, _ := connect_unix(cs.path)
	defer posix.close(partial)
	prefix := [2]u8{30, 0}
	posix.send(partial, raw_data(prefix[:]), 2, {.NOSIGNAL})
	crash, _ := connect_unix(cs.path)
	posix.send(crash, raw_data(prefix[:]), 2, {.NOSIGNAL})
	posix.close(crash)
	clients: [6]posix.FD
	for &fd in clients { fd, _ = connect_unix(cs.path) }
	defer for fd in clients { posix.close(fd) }
	for fd in clients {
		for id in 1 ..= 4 { reliability_send(fd, fmt.tprintf("1 %d daemon.status", id)) }
	}
	for fd in clients {
		for id in 1 ..= 4 {
			testing.expect(t, strings.has_prefix(reliability_reply(fd), fmt.tprintf("1 %d ok", id)))
		}
	}
	// Stop must be bounded even while idle and partial clients remain open.
	start := time.tick_now()
	standalone.control_server_stop(&cs)
	testing.expect(t, time.tick_since(start) < time.Second)
}

@(test)
test_control_overflow_reports_rejections_without_partial_transactions :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-overflow-%d.sock", posix.getpid()),
		ctx = {ring = &ring, snapshot = &snap, state = &state},
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) { return }
	defer standalone.control_server_stop(&cs)
	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) { return }
	defer posix.close(fd)
	// No audio consumer: saturate the queue through the real protocol.
	for id in 1 ..= 128 {
		reliability_send(fd, fmt.tprintf("1 %d parameter.set filter.cutoff 40", id))
		testing.expect(t, strings.has_prefix(reliability_reply(fd), fmt.tprintf("1 %d ok", id)))
	}
	reliability_send(fd, "1 129 parameter.set filter.cutoff 50")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 129 err daemon_not_ready"))
	reliability_send(fd, "1 130 parameter.set_many filter.cutoff 60 filter.resonance 30")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 130 err daemon_not_ready"))
	reliability_send(fd, "1 131 daemon.info")
	testing.expect(t, strings.contains(reliability_reply(fd), " control_dropped=2"),
		"preflight overflow must be counted, not only failed individual pushes")
	// Exactly the accepted edits, in order, each with one commit. No partial
	// overflowed transaction can leak into the consumer's next block.
	for _ in 0 ..< 128 {
		set, has_set := standalone.param_ring_pop(&ring)
		commit, has_commit := standalone.param_ring_pop(&ring)
		testing.expect(t, has_set && has_commit)
		testing.expect_value(t, set.stored, 40)
		testing.expect_value(t, set.kind, standalone.Param_Command_Kind.Set)
		testing.expect_value(t, commit.kind, standalone.Param_Command_Kind.Commit)
	}
	_, leftover := standalone.param_ring_pop(&ring)
	testing.expect(t, !leftover)
	// A subsequent transaction remains legal after capacity is released.
	reliability_send(fd, "1 132 parameter.set_many filter.cutoff 50 filter.cutoff 51")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 132 ok count=2"))
	first, _ := standalone.param_ring_pop(&ring)
	last, _ := standalone.param_ring_pop(&ring)
	testing.expect_value(t, first.stored, 50)
	testing.expect_value(t, last.stored, 51)
}
