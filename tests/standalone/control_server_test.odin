#+build linux
package standalone_tests

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:testing"

import control "../../src/control"
import registry "../../src/registry"
import standalone "../../hosts/standalone"

// End to end over a real Unix socket, with no audio device: the test owns the
// ring and the snapshot and stands in for the audio thread, draining what the
// server enqueues and republishing the snapshot. That exercises the whole
// socket -> framing -> protocol -> handler -> ring -> snapshot path a client
// drives, which is the boundary this slice introduces, while staying runnable
// on a headless CI box.

@(private = "file")
connect_unix :: proc(path: string) -> (posix.FD, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

@(private = "file")
send_frame :: proc(fd: posix.FD, payload: string) {
	frame := control.frame_encode(transmute([]u8)payload)
	defer delete(frame)
	posix.write(fd, raw_data(frame), c.size_t(len(frame)))
}

// Read one framed response. The caller owns the returned payload.
@(private = "file")
read_frame :: proc(fd: posix.FD) -> ([]u8, bool) {
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

@(test)
test_control_server_set_then_get_over_a_socket :: proc(t: ^testing.T) {
	d, described := registry.registry_describe("filter.cutoff")
	testing.expect(t, described)

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running

	// Seed the snapshot with the parameter's default, as the daemon does at
	// startup before any edit.
	init: standalone.Snapshot_Data
	init.values[d.index] = i32(registry.registry_default(d))
	standalone.snapshot_publish(&snap, init)

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-test-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	fd, connected := connect_unix(cs.path)
	testing.expect(t, connected)

	// A get returns the seeded default.
	send_frame(fd, "1 1 parameter.get filter.cutoff")
	got, got_ok := read_frame(fd)
	testing.expect(t, got_ok)
	resp1, ok1 := control.response_parse(got)
	testing.expect(t, ok1)
	testing.expect_value(t, resp1.status, control.Status.Ok)
	value1, has1 := control.response_field(resp1.fields, "value")
	testing.expect(t, has1)
	default_str := fmt.tprintf("%d", registry.registry_default(d))
	testing.expect_value(t, value1, default_str)
	delete(got)

	// A set is accepted and enqueued, not applied by the control thread.
	lo, hi, _ := registry.registry_stored_range(d)
	target := (lo + hi) / 2
	send_frame(fd, fmt.tprintf("1 2 parameter.set filter.cutoff %d", target))
	set_resp, set_ok := read_frame(fd)
	testing.expect(t, set_ok)
	resp2, ok2 := control.response_parse(set_resp)
	testing.expect(t, ok2)
	testing.expect_value(t, resp2.status, control.Status.Ok)
	delete(set_resp)

	// Stand in for the audio thread: drain the ring and republish.
	cmd, popped := standalone.param_ring_pop(&ring)
	testing.expect(t, popped)
	testing.expect_value(t, int(cmd.index), d.index)
	testing.expect_value(t, int(cmd.stored), target)
	applied := init
	applied.values[d.index] = cmd.stored
	applied.revision = 1
	standalone.snapshot_publish(&snap, applied)

	// A get now reflects the applied value.
	send_frame(fd, "1 3 parameter.get filter.cutoff")
	got2, got2_ok := read_frame(fd)
	testing.expect(t, got2_ok)
	resp3, ok3 := control.response_parse(got2)
	testing.expect(t, ok3)
	value3, has3 := control.response_field(resp3.fields, "value")
	testing.expect(t, has3)
	target_str := fmt.tprintf("%d", target)
	testing.expect_value(t, value3, target_str)
	delete(got2)

	// The client closes before the server is stopped, so the stop's thread join
	// does not wait on a live connection.
	posix.close(fd)
	standalone.control_server_stop(&cs)
}

@(test)
test_control_server_survives_an_invalid_command :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	standalone.snapshot_publish(&snap, standalone.Snapshot_Data{})

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-test-bad-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	fd, connected := connect_unix(cs.path)
	testing.expect(t, connected)

	// An unknown command is answered with a structured error, not a crash.
	send_frame(fd, "1 9 does.not.exist")
	payload, ok := read_frame(fd)
	testing.expect(t, ok)
	resp, parsed := control.response_parse(payload)
	testing.expect(t, parsed)
	testing.expect_value(t, resp.status, control.Status.Err)
	testing.expect_value(t, resp.error, control.Error_Code.Unknown_Command)
	delete(payload)

	// The server still answers a valid request on the same connection.
	send_frame(fd, "1 10 daemon.status")
	status_payload, status_ok := read_frame(fd)
	testing.expect(t, status_ok)
	resp2, parsed2 := control.response_parse(status_payload)
	testing.expect(t, parsed2)
	testing.expect_value(t, resp2.status, control.Status.Ok)
	delete(status_payload)

	posix.close(fd)
	standalone.control_server_stop(&cs)
}

@(test)
test_control_server_set_many_enqueues_one_transaction :: proc(t: ^testing.T) {
	cutoff, _ := registry.registry_describe("filter.cutoff")
	reso, _ := registry.registry_describe("filter.resonance")

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	standalone.snapshot_publish(&snap, standalone.Snapshot_Data{})

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-test-many-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	fd, connected := connect_unix(cs.path)
	testing.expect(t, connected)

	send_frame(fd, "1 1 parameter.set_many filter.cutoff 50 filter.resonance 30")
	payload, ok := read_frame(fd)
	testing.expect(t, ok)
	resp, parsed := control.response_parse(payload)
	testing.expect(t, parsed)
	testing.expect_value(t, resp.status, control.Status.Ok)
	count, has_count := control.response_field(resp.fields, "count")
	testing.expect(t, has_count)
	testing.expect_value(t, count, "2")
	delete(payload)

	// The whole batch reached the ring as two Sets then one Commit, in order.
	c1, ok1 := standalone.param_ring_pop(&ring)
	testing.expect(t, ok1)
	testing.expect_value(t, c1.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, int(c1.index), cutoff.index)
	testing.expect_value(t, int(c1.stored), 50)
	c2, ok2 := standalone.param_ring_pop(&ring)
	testing.expect(t, ok2)
	testing.expect_value(t, c2.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, int(c2.index), reso.index)
	testing.expect_value(t, int(c2.stored), 30)
	c3, ok3 := standalone.param_ring_pop(&ring)
	testing.expect(t, ok3)
	testing.expect_value(t, c3.kind, standalone.Param_Command_Kind.Commit)
	_, empty := standalone.param_ring_pop(&ring)
	testing.expect(t, !empty)

	posix.close(fd)
	standalone.control_server_stop(&cs)
}

@(test)
test_control_server_set_many_rejects_the_whole_batch :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	standalone.snapshot_publish(&snap, standalone.Snapshot_Data{})

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-test-reject-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	fd, connected := connect_unix(cs.path)
	testing.expect(t, connected)

	// The second member is out of range, so the whole transaction is refused and
	// nothing at all reaches the ring.
	send_frame(fd, "1 1 parameter.set_many filter.cutoff 50 filter.resonance 999999")
	payload, ok := read_frame(fd)
	testing.expect(t, ok)
	resp, parsed := control.response_parse(payload)
	testing.expect(t, parsed)
	testing.expect_value(t, resp.status, control.Status.Err)
	testing.expect_value(t, resp.error, control.Error_Code.Out_Of_Range)
	delete(payload)

	_, has := standalone.param_ring_pop(&ring)
	testing.expect(t, !has)

	posix.close(fd)
	standalone.control_server_stop(&cs)
}

@(test)
test_control_server_state_snapshot_returns_all_values :: proc(t: ^testing.T) {
	cutoff, _ := registry.registry_describe("filter.cutoff")

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	seed: standalone.Snapshot_Data
	seed.revision = 5
	seed.values[cutoff.index] = 77
	standalone.snapshot_publish(&snap, seed)

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-test-snap-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	fd, connected := connect_unix(cs.path)
	testing.expect(t, connected)

	send_frame(fd, "1 1 state.snapshot")
	payload, ok := read_frame(fd)
	testing.expect(t, ok)
	resp, parsed := control.response_parse(payload)
	testing.expect(t, parsed)
	testing.expect_value(t, resp.status, control.Status.Ok)
	revision, has_rev := control.response_field(resp.fields, "revision")
	testing.expect(t, has_rev)
	testing.expect_value(t, revision, "5")

	// The seeded value appears as a record line in the body.
	body := string(resp.body)
	testing.expect(t, contains(body, "id=filter.cutoff value=77"))
	delete(payload)

	posix.close(fd)
	standalone.control_server_stop(&cs)
}

@(private = "file")
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}
