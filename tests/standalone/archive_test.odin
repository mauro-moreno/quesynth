#+build linux
package standalone_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import patch "../../src/patch"
import standalone "../../hosts/standalone"

// The archive protocol end to end over the socket, against the nested fixture:
// open the outer archive, page its banks, open a bank, page its patches, and load
// one as a transaction. This is the lazy two-level path the daemon walks over the
// real corpus, at fixture scale.

@(private = "file")
FIXTURE :: "tests/zip/fixtures/nested.zip"

@(private = "file")
archive_server :: proc(ring: ^standalone.Param_Ring, snap: ^standalone.Snapshot, tag: string) -> (standalone.Control_Server, ^standalone.Archive) {
	state := new(standalone.Daemon_State)
	state^ = .Running
	arch := new(standalone.Archive)
	cs := standalone.Control_Server {
		path = fmt.tprintf("/tmp/quesynth-%s-%d.sock", tag, posix.getpid()),
		ctx = {ring = ring, snapshot = snap, state = state, archive = arch},
	}
	return cs, arch
}

// The archive was opened on the control thread, which has the plain heap, not the
// tracking allocator this thread's tests run under.
@(private = "file")
archive_free :: proc(arch: ^standalone.Archive) {
	{
		context.allocator = runtime.heap_allocator()
		standalone.archive_close(arch)
	}
	free(arch)
}

@(test)
test_archive_open_lists_banks_and_patches :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs, arch := archive_server(&ring, &snap, "arclist")
	defer archive_free(arch)
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	reliability_send(fd, fmt.tprintf("1 1 archive.open %s", FIXTURE))
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 1 ok banks=1"))

	reliability_send(fd, "1 2 archive.banks 0 10")
	banks := reliability_reply(fd)
	testing.expect(t, strings.contains(banks, "total=1"))
	testing.expect(t, strings.contains(banks, "\nbank=0 name=bankA.zip"))

	reliability_send(fd, "1 3 archive.bank 0")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 3 ok patches=2"))

	reliability_send(fd, "1 4 archive.patches 0 10")
	patches := reliability_reply(fd)
	testing.expect(t, strings.contains(patches, "total=2"))
	testing.expect(t, strings.contains(patches, "\npatch=0 name=Test Patch One"))
}

@(test)
test_archive_load_applies_patch_as_transaction :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs, arch := archive_server(&ring, &snap, "arcload")
	defer archive_free(arch)
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	reliability_send(fd, fmt.tprintf("1 1 archive.open %s", FIXTURE))
	reliability_reply(fd)
	reliability_send(fd, "1 2 archive.bank 0")
	reliability_reply(fd)

	// 001.sy1 sets params 0,1,2 to 3,64,90.
	reliability_send(fd, "1 3 archive.load 0")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 3 ok"))

	want := [3]i32{3, 64, 90}
	for k in 0 ..< 3 {
		cmd, popped := standalone.param_ring_pop(&ring)
		testing.expect(t, popped)
		testing.expect_value(t, cmd.kind, standalone.Param_Command_Kind.Set)
		testing.expect_value(t, int(cmd.index), k)
		testing.expect_value(t, cmd.stored, want[k])
	}
	commit, has_commit := standalone.param_ring_pop(&ring)
	testing.expect(t, has_commit)
	testing.expect_value(t, commit.kind, standalone.Param_Command_Kind.Commit_Patch)
}

@(test)
test_archive_bad_paths_and_indices :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	cs, arch := archive_server(&ring, &snap, "arcbad")
	defer archive_free(arch)
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)

	fd, ok := connect_unix(cs.path)
	if !testing.expect(t, ok) {return}
	defer posix.close(fd)

	// Browsing before opening, and opening a missing file, both fail cleanly.
	reliability_send(fd, "1 1 archive.banks 0 10")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 1 err daemon_not_ready"))
	reliability_send(fd, "1 2 archive.open /tmp/quesynth-no-such-archive.zip")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 2 err invalid_payload"))

	// A patch load with no bank open is refused; nothing reaches the ring.
	reliability_send(fd, "1 3 archive.load 0")
	testing.expect(t, strings.has_prefix(reliability_reply(fd), "1 3 err daemon_not_ready"))
	_, any := standalone.param_ring_pop(&ring)
	testing.expect(t, !any)
}
