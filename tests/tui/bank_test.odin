#+build linux
package tui_tests

import "core:fmt"
import "core:sys/posix"
import "core:testing"

import patch "../../src/patch"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The TUI's bank client, against a live control server holding the factory bank:
// list the slots and load one, the same calls the bank browser makes.

@(test)
test_tui_client_lists_and_loads_bank :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-bank-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
		bank     = bank,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	client, connected := tui.client_connect(cs.path)
	testing.expect(t, connected)

	slots, label, ok := tui.client_bank_list(&client)
	defer tui.client_bank_free(slots)
	defer delete(label)
	testing.expect(t, ok)
	// Every slot is listed, filled and empty alike.
	testing.expect_value(t, len(slots), patch.FACTORY_SLOTS)
	// A slot listed as filled is filled in the bank; find the first one.
	first := -1
	for s, i in slots {
		if s.filled {
			_, is_filled := patch.slots_patch(bank, s.slot)
			testing.expect(t, is_filled)
			if first < 0 {first = i}
		}
	}
	if !testing.expect(t, first >= 0) {return}

	// Loading the first filled slot enqueues its whole preset as a transaction.
	testing.expect(t, tui.client_patch_load(&client, slots[first].slot))
	seen := 0
	last: standalone.Param_Command_Kind
	for {
		cmd, popped := standalone.param_ring_pop(&ring)
		if !popped { break }
		seen += 1
		last = cmd.kind
		if cmd.kind == .Commit_Patch { break }
	}
	testing.expect(t, seen > 1)
	testing.expect_value(t, last, standalone.Param_Command_Kind.Commit_Patch)

	tui.client_close(&client)
	standalone.control_server_stop(&cs)
}
