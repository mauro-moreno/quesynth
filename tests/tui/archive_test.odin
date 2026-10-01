#+build linux
package tui_tests

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The TUI's archive client against a live server holding the nested fixture: open,
// list banks, open a bank, list patches, load one -- the calls the browser makes.

@(test)
test_tui_archive_browse_and_load :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	arch := new(standalone.Archive)
	defer {standalone.archive_close(arch);free(arch)}

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-tui-arc-%d.sock", posix.getpid())
	cs.ctx = standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
		archive  = arch,
	}
	testing.expect(t, standalone.control_server_start(&cs))

	client, connected := tui.client_connect(cs.path)
	testing.expect(t, connected)

	banks, ok := tui.client_archive_open(&client, "tests/zip/fixtures/nested.zip")
	testing.expect(t, ok)
	testing.expect_value(t, banks, 1)

	bank_names, bok := tui.client_archive_names(&client, "archive.banks")
	defer tui.client_names_free(bank_names)
	testing.expect(t, bok)
	testing.expect_value(t, len(bank_names), 1)
	testing.expect_value(t, bank_names[0], "bankA.zip")

	patches, pok := tui.client_archive_bank(&client, 0)
	testing.expect(t, pok)
	testing.expect_value(t, patches, 2) // only the two .sy1 files

	patch_names, nok := tui.client_archive_names(&client, "archive.patches")
	defer tui.client_names_free(patch_names)
	testing.expect(t, nok)
	testing.expect_value(t, len(patch_names), 2)
	testing.expect_value(t, patch_names[0], "Test Patch One")

	// What every peer reads: the archive open, its bank open, the path as given.
	current, cok := tui.client_archive_current(&client)
	defer tui.archive_state_free(&current)
	testing.expect(t, cok)
	testing.expect(t, current.open)
	testing.expect_value(t, current.banks, 1)
	testing.expect_value(t, current.bank, 0)
	testing.expect_value(t, current.patches, 2)
	testing.expect_value(t, current.rev, 2)
	testing.expect_value(t, current.path, "tests/zip/fixtures/nested.zip")
	testing.expect_value(t, current.bank_name, "bankA.zip")

	// From the open bank, and from the bank named: each one replacement.
	for bank in ([2]int{-1, 0}) {
		testing.expect(t, tui.client_archive_load(&client, 0, bank))
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
	}
	// A bank the archive does not have loads nothing.
	testing.expect(t, !tui.client_archive_load(&client, 0, 1))
	_, queued := standalone.param_ring_pop(&ring)
	testing.expect(t, !queued)

	testing.expect(t, tui.client_archive_close(&client))
	tui.client_close(&client)
	standalone.control_server_stop(&cs)
}
