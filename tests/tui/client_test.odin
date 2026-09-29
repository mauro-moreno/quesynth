#+build linux
package tui_tests

import "core:fmt"
import "core:sys/posix"
import "core:testing"

import registry "../../src/registry"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// Exercise the real TUI client code -- the same client_connect/get/set the
// interactive UI uses -- against a live control server, with no terminal and no
// audio. This proves the front-end drives the synth through the public protocol
// and nothing else, which is the checkpoint's whole claim.

@(test)
test_tui_client_gets_and_sets_over_the_protocol :: proc(t: ^testing.T) {
	d, described := registry.registry_describe("filter.cutoff")
	testing.expect(t, described)

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	init: standalone.Snapshot_Data
	init.values[d.index] = i32(registry.registry_default(d))
	standalone.snapshot_publish(&snap, init)

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-test-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	client, connected := tui.client_connect(cs.path)
	testing.expect(t, connected)

	// A get returns the seeded default.
	value, got := tui.client_get(&client, "filter.cutoff")
	testing.expect(t, got)
	testing.expect_value(t, value, registry.registry_default(d))

	// A set is accepted and echoes the value back at once.
	lo, hi, _ := registry.registry_stored_range(d)
	target := (lo + hi) / 2
	applied, set := tui.client_set(&client, "filter.cutoff", target)
	testing.expect(t, set)
	testing.expect_value(t, applied, target)

	// The server enqueued exactly that edit for the audio thread.
	cmd, popped := standalone.param_ring_pop(&ring)
	testing.expect(t, popped)
	testing.expect_value(t, int(cmd.index), d.index)
	testing.expect_value(t, int(cmd.stored), target)

	// A rejected value leaves the client's set reporting failure.
	_, rejected := tui.client_set(&client, "filter.cutoff", hi + 10000)
	testing.expect(t, !rejected)

	tui.client_close(&client)
	standalone.control_server_stop(&cs)
}
