#+build linux
package tui_tests

import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

import registry "../../src/registry"
import tui "../../hosts/standalone/tui"

// The TUI's reading of the daemon's patch identity, and what the synth screen
// makes of it. The replies are written out by hand in the wire format the
// protocol contract gives, so the parser is checked against the contract rather
// than against the daemon code that happens to produce them.

// Answer the client's next request with a canned reply on the far end of a
// socket pair, then ask for patch.current.
@(private = "file")
current_from :: proc(reply: string) -> (slot: int, bank, name: string, bank_rev: uint, revision: int, ok: bool, open: bool) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK {return}
	defer posix.close(fds[1])
	client := tui.Client{fd = fds[0], next_id = 1}
	defer tui.client_close(&client)
	n := len(reply)
	header := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fds[1], raw_data(header[:]), 4, {.NOSIGNAL})
	posix.send(fds[1], raw_data(reply), c.size_t(n), {.NOSIGNAL})
	slot, bank, name, bank_rev, revision, ok = tui.client_patch_current(&client)
	open = client.fd >= 0
	return
}

@(test)
test_client_patch_current_keeps_names_raw :: proc(t: ^testing.T) {
	slot, bank, name, bank_rev, revision, ok, _ := current_from("1 1 ok slot=7 bank_rev=3 revision=12\nbank=My  Bank \nname=Lead With Spaces")
	defer {delete(bank); delete(name)}
	testing.expect(t, ok)
	testing.expect_value(t, slot, 7)
	testing.expect_value(t, bank_rev, 3)
	testing.expect_value(t, revision, 12)
	// Spaces inside and at the end of a value are part of it.
	testing.expect_value(t, bank, "My  Bank ")
	testing.expect_value(t, name, "Lead With Spaces")
}

@(test)
test_client_patch_current_reads_an_empty_identity :: proc(t: ^testing.T) {
	slot, bank, name, bank_rev, revision, ok, _ := current_from("1 1 ok slot=-1 bank_rev=0 revision=0\nbank=\nname=")
	defer {delete(bank); delete(name)}
	testing.expect(t, ok)
	testing.expect_value(t, slot, -1)
	testing.expect_value(t, bank_rev, 0)
	testing.expect_value(t, revision, 0)
	testing.expect_value(t, bank, "")
	testing.expect_value(t, name, "")
}

@(test)
test_client_patch_current_refused_is_not_a_disconnect :: proc(t: ^testing.T) {
	// An older daemon, or one with no bank: a well-formed refusal, so the
	// connection stays up and only the identity is unknown.
	_, bank, name, _, _, ok, open := current_from("1 1 err daemon_not_ready no bank")
	defer {delete(bank); delete(name)}
	testing.expect(t, !ok)
	testing.expect(t, open)
}

// Draw the synth screen once with the given identity and return what reached
// the terminal. stdout is swapped for a pipe for the duration; render writes
// with plain write(2), so nothing is left buffered when it is swapped back.
@(private = "file")
render_with :: proc(bank, name: string) -> string {
	descriptors := registry.registry_list()
	rows := make([]tui.Row, len(descriptors))
	defer delete(rows)
	for d, i in descriptors {
		rows[i].desc = d
		rows[i].value = registry.registry_default(d)
	}
	groups := tui.build_groups(rows)
	defer tui.free_groups(groups)
	theme := tui.theme_defaults()
	theme.enabled = false

	// Held for the whole swap; see stdout_capture in midi_test.odin.
	sync.mutex_lock(&stdout_capture)
	defer sync.mutex_unlock(&stdout_capture)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {return ""}
	saved := posix.dup(posix.STDOUT_FILENO)
	posix.dup2(fds[1], posix.STDOUT_FILENO)
	tui.render(rows, groups, 0, 0, tui.Metrics{ok = true}, "/tmp/quesynth.sock", bank, name, "", theme)
	posix.dup2(saved, posix.STDOUT_FILENO)
	posix.close(saved)
	posix.close(fds[1])
	defer posix.close(fds[0])

	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n := posix.read(fds[0], raw_data(buf[:]), c.size_t(len(buf)))
		if n <= 0 {break}
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}

@(test)
test_synth_screen_names_the_daemons_patch :: proc(t: ^testing.T) {
	unnamed := render_with("", "")
	testing.expect(t, strings.contains(unnamed, "patch: (unsaved)"), unnamed)
	testing.expect(t, !strings.contains(unnamed, "bank:"), unnamed)

	named := render_with("Factory", "Solo Lead")
	testing.expect(t, strings.contains(named, "patch: Solo Lead   bank: Factory"), named)

	// No name reads as unsaved, whatever the bank is called.
	cleared := render_with("Factory", "")
	testing.expect(t, strings.contains(cleared, "patch: (unsaved)   bank: Factory"), cleared)
}
