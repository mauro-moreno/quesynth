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

	slots, ok := tui.client_bank_list(&client)
	defer tui.client_bank_free(slots)
	testing.expect(t, ok)
	testing.expect(t, len(slots) > 0)
	// Each listed slot names a filled entry in the bank.
	for s in slots {
		testing.expect(t, s.slot >= 0 && s.slot < patch.FACTORY_SLOTS)
		_, filled := patch.slots_patch(bank, s.slot)
		testing.expect(t, filled)
	}

	// Loading the first listed slot enqueues its whole preset as a transaction.
	testing.expect(t, tui.client_patch_load(&client, slots[0].slot))
	seen := 0
	for {
		cmd, popped := standalone.param_ring_pop(&ring)
		if !popped { break }
		seen += 1
		if cmd.kind == .Commit { break }
	}
	testing.expect(t, seen > 1)

	tui.client_close(&client)
	standalone.control_server_stop(&cs)
}
