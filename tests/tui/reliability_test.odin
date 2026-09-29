#+build linux
package tui_tests

import "core:c"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import tui "../../hosts/standalone/tui"

@(private)
Slow_Peer :: struct { fd: posix.FD, trickle: bool }

@(private)
slow_peer :: proc(data: rawptr) {
	peer := (^Slow_Peer)(data)
	defer posix.close(peer.fd)
	// Stay alive long enough for the old unbounded client to exceed the bound.
	for i in 0 ..< 6 {
		if peer.trickle {
			b: u8 = i == 0 ? 50 : 0
			posix.send(peer.fd, &b, 1, {.NOSIGNAL})
		}
		time.sleep(200 * time.Millisecond)
	}
}

@(test)
test_client_transport_wait_has_a_total_deadline :: proc(t: ^testing.T) {
	for trickle in ([2]bool{false, true}) {
		fds: [2]posix.FD
		if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, {}, &fds) == .OK) { return }
		client := tui.Client{fd = fds[0], next_id = 1}
		defer tui.client_close(&client)
		peer := Slow_Peer{fd = fds[1], trickle = trickle}
		th := thread.create_and_start_with_data(&peer, slow_peer)
		start := time.tick_now()
		info := tui.client_info(&client)
		elapsed := time.tick_since(start)
		thread.join(th)
		thread.destroy(th)
		testing.expect(t, !info.ok)
		testing.expect(t, elapsed < time.Second, "a silent/trickling daemon must not prevent quitting")
		testing.expect_value(t, client.fd, -1)
	}
}

@(test)
test_client_rejects_wrong_response_identity :: proc(t: ^testing.T) {
	for text in ([3]string{"1 999 ok value=42", "2 1 ok value=42", "garbage"}) {
		fds: [2]posix.FD
		if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, {}, &fds) == .OK) { return }
		defer posix.close(fds[1])
		client := tui.Client{fd = fds[0], next_id = 1}
		defer tui.client_close(&client)
		header := [4]u8{u8(len(text)), 0, 0, 0}
		posix.send(fds[1], raw_data(header[:]), 4, {.NOSIGNAL})
		posix.send(fds[1], raw_data(text), c.size_t(len(text)), {.NOSIGNAL})
		_, ok := tui.client_get(&client, "filter.cutoff")
		testing.expect(t, !ok, "a stale/wrong-version response cannot acknowledge this request")
		testing.expect_value(t, client.fd, -1)
	}
}
