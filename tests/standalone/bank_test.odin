#+build linux
package standalone_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import control "../../src/control"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// The bank half of the protocol, end to end over the socket: browse, load a slot
// as one atomic transaction, load a file, capture the live state into a slot, and
// write the bank out. The test owns the ring and the bank and stands in for the
// audio thread by draining what the server enqueues.

@(private = "file")
bank_server :: proc(bank: ^patch.Slots, ring: ^standalone.Param_Ring, snap: ^standalone.Snapshot, tag: string) -> standalone.Control_Server {
	state := new(standalone.Daemon_State)
	state^ = .Running
	cs := standalone.Control_Server {
		path = fmt.tprintf("/tmp/quesynth-%s-%d.sock", tag, posix.getpid()),
		ctx = {ring = ring, snapshot = snap, state = state, bank = bank},
	}
	return cs
}

@(test)
test_bank_list_reports_filled_slots :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs := bank_server(bank, &ring, &snap, "banklist")
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	reliability_send(fd, "1 1 bank.list")
	reply := reliability_reply(fd)
	testing.expect(t, strings.has_prefix(reply, "1 1 ok"))
	testing.expect(t, strings.contains(reply, "label="))
	// The factory bank has at least one filled slot, each on its own record line.
	testing.expect(t, strings.contains(reply, "\nslot="))
}

@(test)
test_patch_load_applies_slot_as_one_transaction :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	first := -1
	for i in 0 ..< patch.FACTORY_SLOTS {
		if bank.filled[i] {first = i; break}
	}
	if !testing.expect(t, first >= 0) {return}
	want, filled := patch.slots_patch(bank, first)
	if !testing.expect(t, filled) {return}

	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs := bank_server(bank, &ring, &snap, "patchload")
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	reliability_send(fd, fmt.tprintf("1 1 patch.load %d", first))
	reply := reliability_reply(fd)
	testing.expect(t, strings.has_prefix(reply, "1 1 ok"))
	testing.expect(t, strings.contains(reply, fmt.tprintf("slot=%d", first)))
	testing.expect(t, strings.contains(reply, fmt.tprintf("count=%d", patch.PARAMETER_COUNT)))

	// The whole preset reached the ring as PARAMETER_COUNT Sets then one Commit,
	// in parameter-index order, each value the slot's.
	for i in 0 ..< patch.PARAMETER_COUNT {
		cmd, popped := standalone.param_ring_pop(&ring)
		testing.expect(t, popped)
		testing.expect_value(t, cmd.kind, standalone.Param_Command_Kind.Set)
		testing.expect_value(t, int(cmd.index), i)
		testing.expect_value(t, cmd.stored, want[i])
	}
	commit, has_commit := standalone.param_ring_pop(&ring)
	testing.expect(t, has_commit)
	testing.expect_value(t, commit.kind, standalone.Param_Command_Kind.Commit)
	_, leftover := standalone.param_ring_pop(&ring)
	testing.expect(t, !leftover)
}

@(test)
test_patch_load_rejects_bad_slots :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs := bank_server(bank, &ring, &snap, "patchbad")
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	reliability_send(fd, "1 1 patch.load 9999")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 1 err invalid_payload"))
	// An empty slot is addressable but has nothing to load.
	reliability_send(fd, "1 2 patch.load 120")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 2 err unknown_parameter"))
	_, any := standalone.param_ring_pop(&ring)
	testing.expect(t, !any)
}

@(test)
test_patch_save_captures_live_state :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	seed: standalone.Snapshot_Data
	seed.revision = 3
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(i % 90)}
	standalone.snapshot_publish(&snap, seed)

	cs := bank_server(bank, &ring, &snap, "patchsave")
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	// Slot 120 starts empty; save the live state into it under a name.
	reliability_send(fd, "1 1 patch.save 120 My Lead")
	reply := reliability_reply(fd)
	testing.expect(t, strings.has_prefix(reply, "1 1 ok"))
	testing.expect(t, strings.contains(reply, "name=My_Lead"))

	// The slot now holds exactly the snapshot's values and is browsable.
	stored, filled := patch.slots_patch(bank, 120)
	testing.expect(t, filled)
	for i in 0 ..< patch.PARAMETER_COUNT {
		testing.expect_value(t, stored[i], i32(i % 90))
	}
	testing.expect_value(t, patch.slots_name(bank, 120), "My Lead")
}

@(test)
test_patch_load_file_and_bank_write_round_trip :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs := bank_server(bank, &ring, &snap, "patchfile")
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	// Load a real fixture patch by path; it applies as a transaction.
	reliability_send(fd, "1 1 patch.load_file tools/s1probe/fixtures/unison-four.sy1")
	reply := reliability_reply(fd)
	testing.expect(t, strings.has_prefix(reply, "1 1 ok"))
	drained := 0
	for {
		cmd, popped := standalone.param_ring_pop(&ring)
		if !popped {break}
		drained += 1
		if cmd.kind == .Commit {break}
	}
	testing.expect(t, drained > 1) // at least one Set plus the Commit

	// Write the bank to a temp path and confirm it parses back as a bank.
	out_path := fmt.tprintf("/tmp/quesynth-bankout-%d.json", posix.getpid())
	cout := strings.clone_to_cstring(out_path)
	defer delete(cout)
	defer posix.unlink(cout)
	reliability_send(fd, fmt.tprintf("1 2 bank.write %s", out_path))
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 2 ok"))
	data, rerr := os.read_entire_file(out_path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	_, perr := patch.parse_bank_json(data, context.temp_allocator)
	testing.expect(t, perr == .None)
}
