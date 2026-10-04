#+build linux
package tui_tests

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

import patch "../../src/patch"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The daemon refuses a save it cannot keep, and one whose earlier edits did not
// reach the sound in time. S in the TUI then has to say why, in the footer, as
// a refused archive request does: a refusal that only returned false left the
// screen as if S had done nothing. The daemon here is a real control server
// whose bank file cannot be written while a regular file stands where its
// directory belongs, so the refusal is the daemon's own words.
@(test)
test_a_refused_save_says_why_and_a_saved_one_clears_it :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/quesynth-tui-savenotice-%d", posix.getpid())
	os.remove_all(root)
	if !testing.expect(t, os.make_directory_all(root) == nil) {return}
	defer os.remove_all(root)
	blocker := fmt.tprintf("%s/config", root)
	if !testing.expect(t, os.write_entire_file_from_string(blocker, "not a directory") == nil) {return}

	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	identity := standalone.Patch_Identity{slot = -1}
	cs: standalone.Control_Server
	cs.path = fmt.tprintf("%s/daemon.sock", root)
	cs.ctx = standalone.Control_Context {
		ring      = &ring,
		snapshot  = &snap,
		state     = &state,
		bank      = bank,
		identity  = &identity,
		bank_keep = fmt.tprintf("%s/quesynth/bank.json", blocker),
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	client, ok := tui.client_connect(cs.path)
	if !testing.expect(t, ok) {return}
	defer tui.client_close(&client)

	testing.expect(t, !tui.client_patch_save(&client, 16, "Refused"))
	testing.expect_value(t, client.notice, "cannot keep bank")
	// A refusal is an answer: the connection stays up and is still served.
	testing.expect(t, client.fd >= 0, "a refused save must not close the connection")
	p, read := tui.client_provenance(&client, context.temp_allocator)
	testing.expect(t, read, "the connection must still be served after a refusal")
	testing.expect_value(t, p.bank_rev, 0)
	testing.expect(t, !bank.filled[16], "a refused save stores nothing")

	// Once the directory can be made, the same save is kept, and the reason
	// shown for the last one goes.
	if !testing.expect(t, os.remove(blocker) == nil) {return}
	testing.expect(t, tui.client_patch_save(&client, 16, "Kept"))
	testing.expect_value(t, client.notice, "")
	testing.expect_value(t, patch.slots_name(bank, 16), "Kept")
	testing.expect(t, os.exists(cs.ctx.bank_keep), "the accepted save is kept")
}
