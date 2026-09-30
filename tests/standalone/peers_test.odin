#+build linux
package standalone_tests

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import engine "../../src/engine"
import patch "../../src/patch"
import registry "../../src/registry"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// Two front-ends on one daemon, as `quesynth` and `quesynth --browser` run
// them: the TUI through its real client library, and a bare framed socket
// standing in for the browser adapter. Between them sit one real control server
// and one real Live whose live_render the test calls in place of the audio
// device, so every edit crosses the actual ring into the engine and comes back
// through the published snapshot. Each peer must see what the other did -- the
// daemon is the one authority, and neither client keeps its own.

@(private = "file")
PEER_BLOCK :: 256

@(private = "file")
Daemon :: struct {
	live:     standalone.Live,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	state:    standalone.Daemon_State,
	out:      [PEER_BLOCK * 2]f32,
	cs:       standalone.Control_Server,
}

// Wired the way run_daemon wires it, minus the device and MIDI hardware.
@(private = "file")
daemon_start :: proc(tag: string) -> (^Daemon, bool) {
	d := new(Daemon)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	engine.engine_load_patch(&d.live.eng, p, 48000)
	d.live.left = make([]f32, PEER_BLOCK)
	d.live.right = make([]f32, PEER_BLOCK)
	d.live.volume.milli = standalone.VOLUME_UNITY
	d.live.volume_prev = standalone.VOLUME_UNITY
	standalone.midi_queue_init(&d.live.queue)
	init: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {init.values[i] = i32(engine.engine_patch_value(&d.live.eng, i))}
	standalone.snapshot_publish(&d.live.snapshot, init)
	patch.factory_prepare()
	patch.slots_load_factory(&d.bank)
	d.identity = standalone.Patch_Identity{slot = -1}
	d.state = .Running
	d.cs.path = fmt.tprintf("/tmp/quesynth-peers-%s-%d.sock", tag, posix.getpid())
	d.cs.ctx = standalone.Control_Context {
		ring     = &d.live.ring,
		snapshot = &d.live.snapshot,
		state    = &d.state,
		midi     = &d.live.queue,
		bank     = &d.bank,
		identity = &d.identity,
		volume   = &d.live.volume,
	}
	return d, standalone.control_server_start(&d.cs)
}

@(private = "file")
daemon_stop :: proc(d: ^Daemon) {
	standalone.control_server_stop(&d.cs)
	engine.engine_destroy(&d.live.eng)
	delete(d.live.left)
	delete(d.live.right)
	free(d)
}

// One audio block: drains the ring, applies each commit, republishes.
@(private = "file")
audio_block :: proc(d: ^Daemon) {
	standalone.live_render(&d.live, raw_data(d.out[:]), PEER_BLOCK, 2)
}

// The browser peer's reading of a reply, by plain string search, so the two
// peers here do not share a parser.
@(private = "file")
raw_field :: proc(reply, key: string) -> string {
	envelope := reply
	if nl := strings.index_byte(reply, '\n'); nl >= 0 {envelope = reply[:nl]}
	for token in strings.split(envelope, " ", context.temp_allocator) {
		if strings.has_prefix(token, key) && len(token) > len(key) && token[len(key)] == '=' {
			return token[len(key) + 1:]
		}
	}
	return "<absent>"
}

@(private = "file")
raw_record :: proc(reply, key: string) -> string {
	lines := strings.split(reply, "\n", context.temp_allocator)
	for line in lines[1:] {
		if strings.has_prefix(line, key) && len(line) > len(key) && line[len(key)] == '=' {
			return line[len(key) + 1:]
		}
	}
	return "<absent>"
}

@(private = "file")
raw_value :: proc(snapshot, id: string) -> int {
	marker := fmt.tprintf("\nid=%s value=", id)
	at := strings.index(snapshot, marker)
	if at < 0 {return min(int)}
	rest := snapshot[at + len(marker):]
	if nl := strings.index_byte(rest, '\n'); nl >= 0 {rest = rest[:nl]}
	v, _ := strconv.parse_int(rest)
	return v
}

@(private = "file")
raw_ask :: proc(fd: posix.FD, line: string) -> string {
	reliability_send(fd, line)
	return reliability_reply(fd)
}

@(private = "file")
tui_rows :: proc() -> []tui.Row {
	descriptors := registry.registry_list()
	rows := make([]tui.Row, len(descriptors))
	for d, i in descriptors {
		rows[i].desc = d
		rows[i].value = registry.registry_default(d)
	}
	return rows
}

@(private = "file")
row_value :: proc(rows: []tui.Row, id: string) -> int {
	for r in rows {
		if r.desc.id == id {return r.value}
	}
	return min(int)
}

// A value in range and different from the one the daemon holds now.
@(private = "file")
another_value :: proc(d: ^Daemon, id: string) -> int {
	desc, _ := registry.registry_describe(id)
	lo, hi, _ := registry.registry_stored_range(desc)
	now := engine.engine_patch_value(&d.live.eng, desc.index)
	return now == lo ? hi : lo
}

@(private = "file")
factory_slot_with_space :: proc(skip := -1) -> int {
	for i in 0 ..< patch.FACTORY_SLOTS {
		if i != skip && strings.contains(patch.factory_name(i), " ") {
			if _, filled := patch.factory_patch(i); filled {return i}
		}
	}
	return -1
}

@(test)
test_peers_see_each_others_parameter_edits :: proc(t: ^testing.T) {
	d, started := daemon_start("params")
	defer daemon_stop(d)
	if !testing.expect(t, started) {return}
	client, connected := tui.client_connect(d.cs.path)
	defer tui.client_close(&client)
	browser, reached := connect_unix(d.cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(browser)
	rows := tui_rows()
	defer delete(rows)

	// TUI -> browser.
	start := tui.client_info(&client).revision
	cutoff := another_value(d, "filter.cutoff")
	_, set := tui.client_set(&client, "filter.cutoff", cutoff)
	testing.expect(t, set)
	audio_block(d)
	cutoff_desc, _ := registry.registry_describe("filter.cutoff")
	testing.expect_value(t, engine.engine_patch_value(&d.live.eng, cutoff_desc.index), cutoff)
	snap := raw_ask(browser, "1 1 state.snapshot")
	testing.expect_value(t, raw_field(snap, "revision"), fmt.tprintf("%d", start + 1))
	testing.expect_value(t, raw_value(snap, "filter.cutoff"), cutoff)

	// Browser -> TUI.
	reso := another_value(d, "filter.resonance")
	testing.expect(t, strings.has_prefix(raw_ask(browser, fmt.tprintf("1 2 parameter.set filter.resonance %d", reso)), "1 2 ok"))
	audio_block(d)
	testing.expect_value(t, tui.client_info(&client).revision, start + 2)
	testing.expect(t, tui.client_load_snapshot(&client, rows))
	testing.expect_value(t, row_value(rows, "filter.resonance"), reso)
	testing.expect_value(t, row_value(rows, "filter.cutoff"), cutoff)
}

@(test)
test_peers_share_one_patch_identity :: proc(t: ^testing.T) {
	d, started := daemon_start("identity")
	defer daemon_stop(d)
	if !testing.expect(t, started) {return}
	client, connected := tui.client_connect(d.cs.path)
	defer tui.client_close(&client)
	browser, reached := connect_unix(d.cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(browser)
	rows := tui_rows()
	defer delete(rows)
	k := factory_slot_with_space()
	k2 := factory_slot_with_space(k)
	if !testing.expect(t, k >= 0 && k2 >= 0) {return}

	// The browser loads a slot; the TUI names it and plays its values.
	testing.expect(t, strings.has_prefix(raw_ask(browser, fmt.tprintf("1 1 patch.load %d", k)), "1 1 ok"))
	audio_block(d)
	{
		slot, bank, name, bank_rev, revision, ok := tui.client_patch_current(&client)
		defer {delete(bank); delete(name)}
		testing.expect(t, ok)
		testing.expect_value(t, slot, k)
		testing.expect_value(t, bank, "Factory")
		testing.expect_value(t, name, patch.factory_name(k))
		testing.expect_value(t, bank_rev, 0)
		testing.expect_value(t, revision, 1) // the whole preset is one step
	}
	testing.expect(t, tui.client_load_snapshot(&client, rows))
	want, _ := patch.factory_patch(k)
	for r in rows {
		testing.expectf(t, r.value == want[r.desc.index], "%s: %d, factory %d", r.desc.id, r.value, want[r.desc.index])
	}

	// A knob tweak in the TUI edits the sound but does not rename the patch.
	cutoff := another_value(d, "filter.cutoff")
	_, set := tui.client_set(&client, "filter.cutoff", cutoff)
	testing.expect(t, set)
	audio_block(d)
	current := raw_ask(browser, "1 2 patch.current")
	testing.expect_value(t, raw_field(current, "slot"), fmt.tprintf("%d", k))
	testing.expect_value(t, raw_field(current, "revision"), "2")
	testing.expect_value(t, raw_record(current, "name"), patch.factory_name(k))

	// The TUI loads another; the browser sees the new name and the new values.
	testing.expect(t, tui.client_patch_load(&client, k2))
	audio_block(d)
	current = raw_ask(browser, "1 3 patch.current")
	testing.expect_value(t, raw_field(current, "slot"), fmt.tprintf("%d", k2))
	testing.expect_value(t, raw_field(current, "revision"), "3")
	testing.expect_value(t, raw_record(current, "bank"), "Factory")
	testing.expect_value(t, raw_record(current, "name"), patch.factory_name(k2))
	want2, _ := patch.factory_patch(k2)
	testing.expect_value(t, raw_value(raw_ask(browser, "1 4 state.snapshot"), "filter.cutoff"), want2[cutoff_index()])
}

@(private = "file")
cutoff_index :: proc() -> int {
	desc, _ := registry.registry_describe("filter.cutoff")
	return desc.index
}

@(test)
test_peers_see_each_others_bank_saves :: proc(t: ^testing.T) {
	d, started := daemon_start("banksave")
	defer daemon_stop(d)
	if !testing.expect(t, started) {return}
	client, connected := tui.client_connect(d.cs.path)
	defer tui.client_close(&client)
	browser, reached := connect_unix(d.cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(browser)

	testing.expect_value(t, raw_field(raw_ask(browser, "1 1 patch.current"), "bank_rev"), "0")
	testing.expect(t, tui.client_patch_save(&client, 120, "Shared Save"))
	current := raw_ask(browser, "1 2 patch.current")
	testing.expect_value(t, raw_field(current, "bank_rev"), "1")
	testing.expect_value(t, raw_field(current, "slot"), "120")
	testing.expect_value(t, raw_record(current, "name"), "Shared Save")
	testing.expect(t, strings.contains(raw_ask(browser, "1 3 bank.list"), "\nslot=120 filled=1 name=Shared_Save"))

	testing.expect(t, strings.has_suffix(raw_ask(browser, "1 4 patch.save 121 From Browser"), " bank_rev=2"))
	slot, bank, name, bank_rev, _, ok := tui.client_patch_current(&client)
	defer {delete(bank); delete(name)}
	testing.expect(t, ok)
	testing.expect_value(t, bank_rev, 2)
	testing.expect_value(t, slot, 121)
	testing.expect_value(t, name, "From Browser")
	slots, label, listed := tui.client_bank_list(&client)
	defer {tui.client_bank_free(slots); delete(label)}
	testing.expect(t, listed && len(slots) > 121 && slots[121].filled)
}

@(test)
test_a_peer_transaction_is_one_step_for_the_other :: proc(t: ^testing.T) {
	d, started := daemon_start("txn")
	defer daemon_stop(d)
	if !testing.expect(t, started) {return}
	client, connected := tui.client_connect(d.cs.path)
	defer tui.client_close(&client)
	browser, reached := connect_unix(d.cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(browser)
	rows := tui_rows()
	defer delete(rows)

	cutoff := another_value(d, "filter.cutoff")
	reso := another_value(d, "filter.resonance")
	attack := another_value(d, "amp.attack")
	before := tui.client_info(&client).revision
	line := fmt.tprintf("1 1 parameter.set_many filter.cutoff %d filter.resonance %d amp.attack %d", cutoff, reso, attack)
	testing.expect(t, strings.has_prefix(raw_ask(browser, line), "1 1 ok count=3"))
	audio_block(d)
	testing.expect_value(t, tui.client_info(&client).revision, before + 1)
	testing.expect(t, tui.client_load_snapshot(&client, rows))
	testing.expect_value(t, row_value(rows, "filter.cutoff"), cutoff)
	testing.expect_value(t, row_value(rows, "filter.resonance"), reso)
	testing.expect_value(t, row_value(rows, "amp.attack"), attack)
}

@(test)
test_a_peer_dropping_mid_request_leaves_the_other_working :: proc(t: ^testing.T) {
	d, started := daemon_start("drop")
	defer daemon_stop(d)
	if !testing.expect(t, started) {return}
	client, connected := tui.client_connect(d.cs.path)
	defer tui.client_close(&client)
	if !testing.expect(t, connected) {return}
	k := factory_slot_with_space()
	if !testing.expect(t, k >= 0) {return}
	testing.expect(t, tui.client_patch_load(&client, k))
	audio_block(d)

	// The browser peer dies with a large reply owed to it and half of the next
	// request sent: the daemon's write hits a closed socket.
	browser, reached := connect_unix(d.cs.path)
	if !testing.expect(t, reached) {return}
	reliability_send(browser, "1 1 bank.list")
	half := [2]u8{40, 0}
	posix.send(browser, raw_data(half[:]), c.size_t(len(half)), {.NOSIGNAL})
	posix.close(browser)

	// The TUI carries on, identity intact.
	cutoff := another_value(d, "filter.cutoff")
	_, set := tui.client_set(&client, "filter.cutoff", cutoff)
	testing.expect(t, set)
	audio_block(d)
	slot, bank, name, _, revision, ok := tui.client_patch_current(&client)
	defer {delete(bank); delete(name)}
	testing.expect(t, ok)
	testing.expect_value(t, slot, k)
	testing.expect_value(t, name, patch.factory_name(k))
	testing.expect_value(t, revision, 2)

	// Now the TUI dies the same way, and a fresh browser connection finds the
	// same daemon state it left.
	reliability_send(client.fd, "1 99 bank.list")
	tui.client_close(&client)
	again, back := connect_unix(d.cs.path)
	if !testing.expect(t, back) {return}
	defer posix.close(again)
	current := raw_ask(again, "1 1 patch.current")
	testing.expect_value(t, raw_field(current, "slot"), fmt.tprintf("%d", k))
	testing.expect_value(t, raw_field(current, "revision"), "2")
	testing.expect_value(t, raw_value(raw_ask(again, "1 2 state.snapshot"), "filter.cutoff"), cutoff)
}
