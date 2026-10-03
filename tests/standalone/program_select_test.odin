#+build linux
package standalone_tests

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import control "../../src/control"
import engine "../../src/engine"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// Literal wire bytes and packed words are independent of midi_pack. Loads
// are checked against the factory data and a freshly loaded engine, not against
// values produced by the replacement path itself. Archive loads are checked
// against the fixture's own bytes, written by Python's zipfile (see
// multibank_test.odin), and against what archive.load makes of the same patch.
@(private = "file")
Program_Rig :: struct {
	live: standalone.Live,
	bank: patch.Slots,
	identity: standalone.Patch_Identity,
	archive: standalone.Archive,
	program: standalone.Program_Select,
	state: standalone.Daemon_State,
	cc: standalone.Control_Context,
}

@(private = "file")
program_defaults :: proc() -> (p: patch.Patch) {
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	return
}

@(private = "file")
program_rig :: proc(p: patch.Patch) -> ^Program_Rig {
	r := new(Program_Rig)
	engine.engine_load_patch(&r.live.eng, p, 48000)
	r.live.left = make([]f32, 256)
	r.live.right = make([]f32, 256)
	r.live.volume.milli = standalone.VOLUME_UNITY
	r.live.volume_prev = standalone.VOLUME_UNITY
	standalone.midi_queue_init(&r.live.queue)
	standalone.midi_queue_init(&r.live.select_queue)
	initial: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {initial.values[i] = i32(p.values[i])}
	standalone.snapshot_publish(&r.live.snapshot, initial)
	patch.factory_prepare()
	patch.slots_load_factory(&r.bank)
	r.identity.slot = -1
	r.state = .Running
	r.program.queue = &r.live.select_queue
	r.cc = {
		ring = &r.live.ring, snapshot = &r.live.snapshot, state = &r.state,
		midi = &r.live.queue, bank = &r.bank, identity = &r.identity,
		archive = &r.archive, program = &r.program,
	}
	return r
}

@(private = "file")
program_rig_free :: proc(r: ^Program_Rig) {
	standalone.archive_close(&r.archive)
	engine.engine_destroy(&r.live.eng)
	delete(r.live.left)
	delete(r.live.right)
	free(r)
}

@(private = "file")
program_audio :: proc(r: ^Program_Rig, frames := 0) -> (peak: f32) {
	out: [512]f32
	standalone.live_render(&r.live, raw_data(out[:]), frames, 2)
	for v in out {peak = max(peak, abs(v))}
	return
}

@(private = "file")
program_send :: proc(r: ^Program_Rig, words: []u32) {
	for w in words {assert(standalone.midi_queue_push(&r.live.queue, w))}
	program_audio(r)
	standalone.program_select_drain(&r.cc)
}

@(private = "file")
program_ask :: proc(r: ^Program_Rig, line: string) -> string {
	req, ok := control.request_parse(transmute([]u8)line)
	assert(ok)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(&r.cc, req, &out)
	return strings.to_string(out)
}

@(private = "file")
program_expect_slot :: proc(t: ^testing.T, r: ^Program_Rig, slot, revision: int, archive_rev: uint = 0) {
	values, filled := patch.factory_patch(slot)
	if !testing.expect(t, filled) {return}
	snap := standalone.snapshot_read(&r.live.snapshot)
	testing.expect_value(t, snap.revision, revision)
	for v, i in values {
		testing.expect_value(t, snap.values[i], i32(v))
		testing.expect_value(t, engine.engine_patch_value(&r.live.eng, i), v)
	}
	testing.expect_value(t, program_ask(r, "1 1 patch.current"), fmt.tprintf(
		"1 1 ok slot=%d bank_rev=0 revision=%d source=bank archive_rev=%d archive_bank=-1 archive_patch=-1\nbank=Factory\nname=%s",
		slot, revision, archive_rev, patch.factory_name(slot),
	))
}

@(private = "file")
PROGRAM_ARCHIVE :: "tests/standalone/fixtures/banks.zip"

@(private = "file")
Program_Fixture :: struct {
	bank_name, name: string,
	values:          [3]int,
}

// Archive patch i of `bank`, as the fixture's bytes spell it: each sets
// parameters 0, 1 and 2 and nothing else.
@(private = "file")
program_fixture :: proc(bank, i: int) -> Program_Fixture {
	alpha := [?]Program_Fixture{
		{"Alpha.zip", "Alpha One", {1, 10, 20}},
		{"Alpha.zip", "Alpha Two", {2, 20, 30}},
	}
	beta := [?]Program_Fixture{
		{"Beta Bank.zip", "Beta One", {3, 30, 40}},
		{"Beta Bank.zip", "Beta Two", {0, 40, 50}},
		{"Beta Bank.zip", "Beta Three", {1, 50, 60}},
	}
	return bank == 0 ? alpha[i] : beta[i]
}

@(private = "file")
program_open_archive :: proc(t: ^testing.T, r: ^Program_Rig) {
	testing.expect_value(t, program_ask(r, "1 1 archive.open " + PROGRAM_ARCHIVE), "1 1 ok banks=2 archive_rev=1")
}

// Load a patch the way a client does, and let the audio thread apply it.
@(private = "file")
program_play_archive :: proc(t: ^testing.T, r: ^Program_Rig, bank, i: int) {
	reply := program_ask(r, fmt.tprintf("1 1 archive.load %d %d", i, bank))
	testing.expectf(t, strings.has_prefix(reply, "1 1 ok count=3 "), "archive.load %d %d: %s", i, bank, reply)
	program_audio(r)
}

@(private = "file")
program_archive_current :: proc(bank, patches: int, rev: uint, bank_name: string) -> string {
	return fmt.tprintf(
		"1 2 ok open=1 banks=2 bank=%d patches=%d archive_rev=%d\npath=%s\nbank_name=%s",
		bank, patches, rev, PROGRAM_ARCHIVE, bank_name,
	)
}

// Archive patch i of `bank` over `under`, the values it was loaded on top of:
// an archive entry names only some parameters, and the rest keep theirs.
@(private = "file")
program_expect_archive :: proc(
	t: ^testing.T,
	r: ^Program_Rig,
	bank, i, revision: int,
	archive_rev: uint,
	under: [patch.PARAMETER_COUNT]int,
) {
	f := program_fixture(bank, i)
	want := under
	for v, k in f.values {want[k] = v}
	snap := standalone.snapshot_read(&r.live.snapshot)
	testing.expect_value(t, snap.revision, revision)
	for v, k in want {
		testing.expect_value(t, snap.values[k], i32(v))
		testing.expect_value(t, engine.engine_patch_value(&r.live.eng, k), v)
	}
	testing.expect_value(t, program_ask(r, "1 1 patch.current"), fmt.tprintf(
		"1 1 ok slot=-1 bank_rev=0 revision=%d source=archive archive_rev=%d archive_bank=%d archive_patch=%d\nbank=%s\nname=%s",
		revision, archive_rev, bank, i, f.bank_name, f.name,
	))
}

@(test)
test_native_program_wire_decode :: proc(t: ^testing.T) {
	q: standalone.Midi_Queue
	standalone.midi_queue_init(&q)
	port := standalone.Alsa_Midi_Port{queue = &q}
	// One data byte finishes each PC, including its running-status repeat.
	// Realtime bytes may interrupt a CC without cancelling its status.
	wire := [?]u8{0xB3, 0, 0xF8, 1, 32, 2, 0xC3, 6, 7, 0xBF, 0, 0, 32, 0, 0xCF, 8}
	for b in wire {standalone.alsa_midi_byte(&port, b)}
	want := [?]u32{0x0100B3, 0x0220B3, 0x0006C3, 0x0007C3, 0x0000BF, 0x0020BF, 0x0008CF}
	for w in want {
		got, ok := standalone.midi_queue_pop(&q)
		testing.expect(t, ok)
		testing.expect_value(t, got, w)
	}
	_, extra := standalone.midi_queue_pop(&q)
	testing.expect(t, !extra)
	// System common cancels running status; unpaired data cannot become a PC.
	for b in ([?]u8{0xF0, 9, 0xF7, 10}) {standalone.alsa_midi_byte(&port, b)}
	_, extra = standalone.midi_queue_pop(&q)
	testing.expect(t, !extra)
}

@(test)
test_native_program_forwarding_preserves_performance_messages :: proc(t: ^testing.T) {
	p := program_defaults()
	p.values[86], p.values[87], p.values[50] = 0xB000, 19, 127
	p.values[88], p.values[89], p.values[51] = 0xB020, 90, 127
	r := program_rig(p)
	defer program_rig_free(r)
	before := r.live.eng.params
	words := [?]u32{0x7F00B5, 0x7F20B5, 0x0006C5}
	for w in words {standalone.midi_queue_push(&r.live.queue, w)}
	program_audio(r)
	testing.expect_value(t, r.live.eng.params, before)
	testing.expect_value(t, r.live.eng.ctrl_value, [2]f32{})
	for w in words {
		got, ok := standalone.midi_queue_pop(&r.live.select_queue)
		testing.expect(t, ok)
		testing.expect_value(t, got, w)
	}
	p.values[86], p.values[88] = 0xB001, 0xB04A
	engine.engine_apply_patch(&r.live.eng, p, keep_voice_pool = true)
	for w in ([?]u32{0x7F01B4, 0x404ABF, 0x643C92, 0x6000E2}) {
		standalone.midi_queue_push(&r.live.queue, w)
	}
	program_audio(r)
	testing.expect_value(t, r.live.eng.ctrl_value, [2]f32{1, 64.0 / 127})
	testing.expect(t, r.live.eng.params.filter_cutoff_hz != before.filter_cutoff_hz)
	testing.expect_value(t, r.live.eng.held_notes, 1)
	testing.expect_value(t, r.live.eng.pitch_bend, f32(0.5))
	_, extra := standalone.midi_queue_pop(&r.live.select_queue)
	testing.expect(t, !extra, "ordinary performance messages were forwarded")
	standalone.live_handle_midi(&r.live, 0x003C92)
	testing.expect_value(t, r.live.eng.held_notes, 0)
	standalone.live_handle_midi(&r.live, 0x643E9F)
	standalone.live_handle_midi(&r.live, 0x003E8F)
	testing.expect_value(t, r.live.eng.held_notes, 0)
}

@(test)
test_native_program_preserves_order_and_repeated_loads :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_send(r, {0x0003C0, 0x0006C0})
	// Selection stages complete loads; only the audio thread changes sound.
	testing.expect_value(t, r.live.revision, 0)
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	program_send(r, {0x0006C0, 0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 4)
}

@(test)
test_native_program_bank_sequence :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_send(r, {0x0003C0})
	program_audio(r)
	program_expect_slot(t, r, 3, 1)

	// Either half alone is pending, never a load. Nonzero banks are absent.
	program_send(r, {0x0100B0, 0x0220B0})
	program_audio(r)
	program_expect_slot(t, r, 3, 1)
	program_send(r, {0x0006C0, 0x0000B0, 0x0007C0})
	program_audio(r)
	program_expect_slot(t, r, 3, 1) // LSB=2 survived both PCs and MSB=0.
	program_send(r, {0x0020B0, 0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	program_send(r, {0x0007C0})
	program_audio(r)
	program_expect_slot(t, r, 7, 3)

	// PC before the bank change loads; the PC after it does not.
	program_send(r, {0x0003C0, 0x7F00B0, 0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 3, 4)
	program_send(r, {0x0020B0, 0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 3, 4) // MSB=127 survived LSB-only update.
	program_send(r, {0x0000B0, 0xFF07C0})
	program_audio(r)
	program_expect_slot(t, r, 7, 5) // PC has no third data byte.
}

@(test)
test_native_program_channels_are_independent :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	// Make every channel unavailable, using alternating halves.
	for c in 0 ..< 16 {
		cc := c % 2 == 0 ? u32(0x0100B0) : u32(0x0120B0)
		program_send(r, {cc + u32(c)})
	}
	for c in 0 ..< 16 {
		program_send(r, {0x0006C0 + u32(c)})
		program_audio(r)
	}
	testing.expect_value(t, r.live.revision, 0)
	for c in 0 ..< 16 {
		cc := c % 2 == 0 ? u32(0x0000B0) : u32(0x0020B0)
		program_send(r, {cc + u32(c), 0x0006C0 + u32(c)})
		program_audio(r)
		program_expect_slot(t, r, 6, c + 1)
		// The next channel is still unavailable, until its own update.
		if c < 15 {
			program_send(r, {0x0003C0 + u32(c + 1)})
			program_audio(r)
			program_expect_slot(t, r, 6, c + 1)
		}
	}
}

@(test)
test_native_program_failed_targets_leave_patch_unchanged :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_send(r, {0x0003C0})
	program_audio(r)
	r.bank.filled[120] = false
	for word in ([?]u32{0x0078C0, 0x0080C0, 0x00FFC0, 0x8000B0, 0xFF20B0}) {
		program_send(r, {word})
		program_audio(r)
		program_expect_slot(t, r, 3, 1)
	}
	// Malformed bank data did not change pending bank 0.
	program_send(r, {0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	r.cc.bank = nil
	program_send(r, {0x0007C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	r.cc.bank = &r.bank
	r.bank = {}
	program_send(r, {0x0007C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 2)

	// The highest legal slot is accepted, even in a user bank with no name.
	r.bank.filled[127] = true
	values, _ := patch.factory_patch(3)
	for v, i in values {r.bank.values[127][i] = i32(v)}
	program_send(r, {0x007FCF})
	program_audio(r)
	testing.expect_value(t, r.live.revision, 3)
	testing.expect_value(t, program_ask(r, "1 1 patch.current"),
		"1 1 ok slot=127 bank_rev=0 revision=3 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Bank\nname=Init")
	for v, i in values {testing.expect_value(t, r.live.eng.patch.values[i], v)}

	// An inert control context or absent ring cannot change the sound.
	r.cc.program = nil
	standalone.program_select_drain(&r.cc)
	r.cc.program = &r.program
	r.program.queue = nil
	standalone.program_select_drain(&r.cc)
	r.program.queue = &r.live.select_queue
	r.cc.ring = nil
	before := r.identity
	program_send(r, {0x007FC0})
	program_audio(r)
	testing.expect_value(t, r.identity, before)
	testing.expect_value(t, r.live.revision, 3)
	// A missing ring drops the load rather than holding it, so once the ring
	// is back only the next PC loads.
	r.cc.ring = &r.live.ring
	program_send(r, {0x007FC0})
	program_audio(r)
	testing.expect_value(t, r.live.revision, 4)
}

@(test)
test_native_program_queue_pressure_defers_loads_until_the_ring_has_room :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	// The control ring fits two whole patches, not three. The third waits
	// whole, neither refused, nor partly staged, nor overtaken by later words.
	program_send(r, {0x0003C0, 0x0006C0, 0x0007C0})
	free_space := standalone.param_ring_free_space(&r.live.ring)
	standalone.program_select_drain(&r.cc)
	for w in ([?]u32{0x0120B0, 0x0009C0}) {standalone.live_handle_midi(&r.live, w)}
	standalone.program_select_drain(&r.cc)
	testing.expect_value(t, standalone.param_ring_free_space(&r.live.ring), free_space)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	// Room again: the held 7 loads first, then LSB=1 makes the 9 miss.
	standalone.program_select_drain(&r.cc)
	program_audio(r)
	program_expect_slot(t, r, 7, 3)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))

	// Forwarding also has a bounded queue, here filled with LSB=0 so only the
	// overflow keeps the PC out. A refused PC changes no sound.
	for _ in 0 ..< standalone.MIDI_QUEUE_CAPACITY {
		standalone.live_handle_midi(&r.live, 0x0020B0)
	}
	standalone.live_handle_midi(&r.live, 0x0003C0)
	testing.expect_value(t, standalone.midi_queue_dropped(&r.live.select_queue), u32(1))
	standalone.program_select_drain(&r.cc)
	program_audio(r)
	program_expect_slot(t, r, 7, 3)
}

@(test)
test_native_program_held_load_resolves_against_the_current_bank :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_send(r, {0x0003C0, 0x0006C0, 0x0008C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	// Slot 8 emptied while its PC waited: nothing loads from the old bank,
	// and the queue is not stuck behind it.
	r.bank.filled[8] = false
	standalone.program_select_drain(&r.cc)
	program_audio(r)
	program_expect_slot(t, r, 6, 2)
	program_send(r, {0x0005C0})
	program_audio(r)
	program_expect_slot(t, r, 5, 3)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))
}

@(test)
test_native_program_replaces_atomically_and_keeps_the_held_note :: proc(t: ^testing.T) {
	from := program_defaults()
	from.values[65], from.values[66], from.values[77] = 1, 1, 1
	from.values[36], from.values[37], from.values[78] = 120, 64, 6
	from.values[86], from.values[87], from.values[50] = 0xB001, 19, 127
	from.values[88] = 0
	from.values[19], from.values[29], from.values[90] = 10, 90, 20
	for source in ([?]int{0xB001, 0xB002}) {
		r := program_rig(from)
		defer program_rig_free(r)
		e := &r.live.eng
		program_send(r, {0x643C92, 0x6000E2, 0x7F01B2})
		for _ in 0 ..< 40 {program_audio(r, 256)}
		pool, size := raw_data(e.voices), len(e.voices)
		voices := engine.engine_active_voice_count(e)
		if !testing.expect(t, voices > 0 && e.held_notes == 1) {return}
		ringing := false
		for v in e.delay_left {if v != 0 {ringing = true; break}}
		if !testing.expect(t, ringing, "no prior effect memory to clear") {return}

		to := from
		to.values[19], to.values[29], to.values[90], to.values[94] = 60, 40, 110, 4
		to.values[86] = source
		r.bank.filled[120] = true
		for v, i in to.values {r.bank.values[120][i] = i32(v)}
		r.bank.label_len = copy(r.bank.label[:], "User bank with spaces")
		r.bank.name_len[120] = copy(r.bank.names[120][:], "New held sound")
		r.identity.bank_rev = 9
		program_send(r, {0x0078C2})
		// No parameter has changed on the control thread.
		for v, i in from.values {testing.expect_value(t, e.patch.values[i], v)}
		program_audio(r)
		snap := standalone.snapshot_read(&r.live.snapshot)
		testing.expect_value(t, snap.revision, 1)
		for v, i in to.values {testing.expect_value(t, snap.values[i], i32(v))}
		testing.expect_value(t, program_ask(r, "1 1 patch.current"),
			"1 1 ok slot=120 bank_rev=9 revision=1 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=User bank with spaces\nname=New held sound")
		for buffer in ([?][]f32{e.delay_left, e.delay_right, e.chorus_left, e.chorus_right}) {
			for v in buffer {
				if !testing.expect_value(t, v, f32(0)) {break}
			}
		}
		fresh: engine.Engine
		engine.engine_load_patch(&fresh, to, 48000)
		defer engine.engine_destroy(&fresh)
		testing.expect_value(t, e.effect, fresh.effect)
		testing.expect_value(t, e.equalizer, fresh.equalizer)
		want := to
		if source == 0xB001 {want.values[19] = 127}
		bound := engine.bind_patch(want)
		bound.polyphony = size
		testing.expect_value(t, e.params, bound)
		testing.expect_value(t, e.ctrl_value[0], source == 0xB001 ? f32(1) : f32(0))
		testing.expect_value(t, e.cutoff_smooth.value, bound.filter_cutoff_state)
		testing.expect_value(t, e.gain_smooth.value, bound.amp_gain)
		testing.expect_value(t, e.pan_smooth.value, bound.pan)
		testing.expect(t, raw_data(e.voices) == pool && len(e.voices) == size)
		testing.expect_value(t, engine.engine_active_voice_count(e), voices)
		testing.expect_value(t, e.held_notes, 1)
		testing.expect_value(t, e.pitch_bend, f32(0.5))
		testing.expect(t, program_audio(r, 256) > 0, "held note stopped sounding")
		program_send(r, {0x003C82})
		testing.expect_value(t, e.held_notes, 0)
	}
}

@(test)
test_native_program_control_server_drains_and_accepts_injection :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	standalone.midi_queue_push(&r.live.queue, 0x0006CF)
	program_audio(r)
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-program-%d-%p.sock", posix.getpid(), r),
		ctx = r.cc,
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)
	for _ in 0 ..< 100 {
		program_audio(r)
		if r.live.revision == 1 {break}
		time.sleep(5 * time.Millisecond)
	}
	// Nothing has connected: the control thread loads native PCs on its tick.
	testing.expect_value(t, r.live.revision, 1)
	fd, connected := connect_unix(cs.path)
	if !testing.expect(t, connected) {return}
	defer posix.close(fd)
	reliability_send(fd, "1 1 patch.current")
	testing.expect_value(t, reliability_reply(fd),
		"1 1 ok slot=6 bank_rev=0 revision=1 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Factory\nname=Organ")
	reliability_send(fd, "1 2 midi 192 7 0")
	testing.expect_value(t, reliability_reply(fd), "1 2 ok")
	for _ in 0 ..< 100 {
		program_audio(r)
		if r.live.revision == 2 {break}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, r.live.revision, 2)
	reliability_send(fd, "1 3 patch.current")
	testing.expect_value(t, reliability_reply(fd), fmt.tprintf(
		"1 3 ok slot=7 bank_rev=0 revision=2 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Factory\nname=%s", patch.factory_name(7)))
	values, _ := patch.factory_patch(7)
	for v, i in values {testing.expect_value(t, r.live.eng.patch.values[i], v)}
}

// What patch.current, archive.current, the revision and the drop count were
// before a Program Change that should change none of them.
@(private = "file")
program_expect_unchanged :: proc(
	t: ^testing.T,
	r: ^Program_Rig,
	playing, open: string,
	revision: int,
	loc := #caller_location,
) {
	testing.expect_value(t, r.live.revision, revision, loc = loc)
	testing.expect_value(t, program_ask(r, "1 3 patch.current"), playing, loc = loc)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open, loc = loc)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0), loc = loc)
}

// The report: a keyboard that never sent Bank Select changed the patch, and
// the sound left the archive bank it was playing for the ordinary bank's
// slot. A channel that has chosen no bank stays in the bank of the sound.
@(test)
test_native_program_stays_in_the_archive_bank_the_sound_came_from :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	program_play_archive(t, r, 1, 0)
	browsing := program_ask(r, "1 2 archive.current")
	testing.expect_value(t, browsing, program_archive_current(1, 3, 2, "Beta Bank.zip"))

	program_send(r, {0x0001C0})
	testing.expect_value(t, r.live.revision, 1)
	program_audio(r)
	program_expect_archive(t, r, 1, 1, 2, 2, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), browsing)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))

	// The values archive.load gives for the same patch over the same sound.
	ref := program_rig(program_defaults())
	defer program_rig_free(ref)
	program_open_archive(t, ref)
	program_play_archive(t, ref, 1, 0)
	program_play_archive(t, ref, 1, 1)
	testing.expect_value(t, standalone.snapshot_read(&r.live.snapshot), standalone.snapshot_read(&ref.live.snapshot))

	// Any channel that chose no bank, any patch of it, a repeat too.
	program_send(r, {0x0002C5, 0x0000CF})
	program_audio(r)
	program_expect_archive(t, r, 1, 0, 4, 2, program_defaults().values)
	program_send(r, {0x0000C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 0, 5, 2, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), browsing)
}

// An open archive alone does not capture Program Changes: only a sound that
// came from it does, and only while that archive is still the one open.
@(test)
test_native_program_selects_the_ordinary_bank_unless_the_sound_came_from_the_archive :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	testing.expect_value(t, program_ask(r, "1 2 archive.bank 1"), "1 2 ok patches=3 bank=1 archive_rev=2")
	open := program_archive_current(1, 3, 2, "Beta Bank.zip")

	// Nothing loaded yet.
	program_send(r, {0x0001C0})
	program_audio(r)
	program_expect_slot(t, r, 1, 1, 2)
	// A client's slot, then a file.
	testing.expect(t, strings.has_prefix(program_ask(r, "1 3 patch.load 3"), "1 3 ok"))
	program_audio(r)
	program_send(r, {0x0004C0})
	program_audio(r)
	program_expect_slot(t, r, 4, 3, 2)
	testing.expect(t, strings.has_prefix(program_ask(r, "1 4 patch.load_file tools/s1probe/fixtures/unison-four.sy1"), "1 4 ok"))
	program_audio(r)
	program_send(r, {0x0005C0})
	program_audio(r)
	program_expect_slot(t, r, 5, 5, 2)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)

	// An archive sound whose archive was then replaced, even by itself, and
	// one whose archive was closed: the names stay, the bank is gone.
	program_play_archive(t, r, 1, 1)
	testing.expect_value(t, program_ask(r, "1 5 archive.open"), "1 5 ok banks=2 archive_rev=3")
	program_send(r, {0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 7, 3)
	program_play_archive(t, r, 1, 1)
	testing.expect_value(t, program_ask(r, "1 6 archive.close"), "1 6 ok archive_rev=5")
	program_send(r, {0x0007C0})
	program_audio(r)
	program_expect_slot(t, r, 7, 9, 5)
}

// Bank Select 0 asks for the ordinary bank on purpose, so it is honoured from
// an archive sound too, and it lasts as the halves do. Each channel decides
// for itself, from the same sound.
@(test)
test_native_program_after_bank_select_zero_selects_the_ordinary_bank :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	program_play_archive(t, r, 1, 1)
	open := program_archive_current(1, 3, 2, "Beta Bank.zip")

	// LSB alone on channel 0: chosen, but no load of its own.
	program_send(r, {0x0020B0})
	program_audio(r)
	program_expect_archive(t, r, 1, 1, 1, 2, program_defaults().values)
	program_send(r, {0x0003C0})
	program_audio(r)
	program_expect_slot(t, r, 3, 2, 2)

	// Back in the archive: channel 1 never chose, channel 0 still has.
	factory3, _ := patch.factory_patch(3)
	program_play_archive(t, r, 1, 1)
	program_send(r, {0x0002C1})
	program_audio(r)
	program_expect_archive(t, r, 1, 2, 4, 2, factory3)
	program_send(r, {0x0004C0})
	program_audio(r)
	program_expect_slot(t, r, 4, 5, 2)

	// MSB alone on channel 2.
	program_play_archive(t, r, 1, 1)
	program_send(r, {0x0000B2, 0x0005C2})
	program_audio(r)
	program_expect_slot(t, r, 5, 7, 2)

	// One archive sound, two channels, two banks.
	factory5, _ := patch.factory_patch(5)
	program_play_archive(t, r, 1, 1)
	program_send(r, {0x0000C1})
	program_audio(r)
	program_expect_archive(t, r, 1, 0, 9, 2, factory5)
	program_send(r, {0x0006C0})
	program_audio(r)
	program_expect_slot(t, r, 6, 10, 2)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)
}

// A chosen bank other than 0 is still a bank that does not exist, whatever
// the sound is playing from, and its halves persist like any others.
@(test)
test_native_program_on_a_chosen_bank_other_than_zero_changes_nothing :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	program_play_archive(t, r, 1, 1)
	playing := program_ask(r, "1 3 patch.current")
	open := program_archive_current(1, 3, 2, "Beta Bank.zip")

	// Bank 1 on channel 0, 128 on channel 1, 127 on channel 2.
	program_send(r, {0x0120B0, 0x0002C0, 0x0100B1, 0x0002C1, 0x7F20B2, 0x0002C2})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 1)
	// Each sends the half it already had at 0: the other half stays.
	program_send(r, {0x0000B0, 0x0002C0, 0x0020B1, 0x0002C1, 0x0000B2, 0x0002C2})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 1)

	// And the half each lacked brings it to bank 0, the ordinary bank.
	program_send(r, {0x0020B0, 0x0002C0})
	program_audio(r)
	program_expect_slot(t, r, 2, 2, 2)
	program_play_archive(t, r, 1, 1)
	program_send(r, {0x0000B1, 0x0003C1})
	program_audio(r)
	program_expect_slot(t, r, 3, 4, 2)
	program_play_archive(t, r, 1, 1)
	program_send(r, {0x0020B2, 0x0004C2})
	program_audio(r)
	program_expect_slot(t, r, 4, 6, 2)
}

// Nothing that does not make a whole patch loads, from the open bank or one
// read beside it, and the next Program Change still does. The entries are
// tampered with in memory because the fixture has no broken patch; the open
// bank's are then refused by archive.load in the same words.
@(test)
test_native_program_failed_archive_targets_change_nothing :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	program_play_archive(t, r, 1, 1)
	playing := program_ask(r, "1 3 patch.current")
	open := program_ask(r, "1 2 archive.current")

	// Past the end of a three-patch bank, data bytes the wire cannot carry,
	// and Bank Select data it cannot carry either, which chooses nothing.
	for word in ([?]u32{0x0003C0, 0x0005C0, 0x007FCF, 0x0080C0, 0x00FFC0, 0x8000B0, 0xFF20B0}) {
		program_send(r, {word})
		program_audio(r)
		program_expect_unchanged(t, r, playing, open, 1)
	}
	program_send(r, {0x0002C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 2, 2, 2, program_defaults().values)

	// A missing ring drops the load rather than holding it, so once the ring
	// is back only the next Program Change loads.
	r.cc.ring = nil
	program_send(r, {0x0001C0})
	r.cc.ring = &r.live.ring
	program_audio(r)
	program_expect_archive(t, r, 1, 2, 2, 2, program_defaults().values)
	program_send(r, {0x0000C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 0, 3, 2, program_defaults().values)

	// Alpha holds a directory marker at 0 and a readme at 2 beside its
	// patches: no bytes at all, and a name with no parameters.
	program_play_archive(t, r, 0, 0)
	playing = program_ask(r, "1 3 patch.current")
	open = program_ask(r, "1 2 archive.current")
	saved := [2]int{r.archive.patch_indices[0], r.archive.patch_indices[1]}
	testing.expect_value(t, saved, [2]int{1, 3})
	r.archive.patch_indices[0], r.archive.patch_indices[1] = 0, 2
	program_send(r, {0x0000C0, 0x0001C0})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 4)
	testing.expect_value(t, program_ask(r, "1 4 archive.load 0"), "1 4 err invalid_payload cannot parse patch")
	testing.expect_value(t, program_ask(r, "1 5 archive.load 1"), "1 5 err invalid_payload patch set no parameters")
	r.archive.patch_indices[0], r.archive.patch_indices[1] = saved[0], saved[1]
	// A patch whose local header no longer lines up cannot be read.
	r.archive.bank.entries[saved[1]].local_offset += 1
	program_send(r, {0x0001C0})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 4)
	testing.expect_value(t, program_ask(r, "1 6 archive.load 1"), "1 6 err invalid_payload cannot read patch")
	r.archive.bank.entries[saved[1]].local_offset -= 1
	program_send(r, {0x0001C0})
	program_audio(r)
	program_expect_archive(t, r, 0, 1, 5, 3, program_defaults().values)

	// Beta, read beside the open Alpha: past its end, and unreadable.
	program_play_archive(t, r, 1, 1)
	testing.expect_value(t, program_ask(r, "1 7 archive.bank 0"), "1 7 ok patches=2 bank=0 archive_rev=5")
	playing = program_ask(r, "1 3 patch.current")
	open = program_ask(r, "1 2 archive.current")
	program_send(r, {0x0003C0})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 6)
	beta := &r.archive.entries[r.archive.bank_indices[1]]
	beta.local_offset += 1
	program_send(r, {0x0000C0})
	program_audio(r)
	program_expect_unchanged(t, r, playing, open, 6)
	beta.local_offset -= 1
	program_send(r, {0x0000C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 0, 7, 5, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)

	// Neither kind waits for room it would never use: with the ring short of
	// a whole load, what is behind them is read at once.
	program_play_archive(t, r, 0, 0)
	for _ in 0 ..< 40 {standalone.live_handle_midi(&r.live, 0x0000C0)}
	standalone.program_select_drain(&r.cc)
	testing.expect_value(t, standalone.param_ring_free_space(&r.live.ring), standalone.PARAM_RING_CAPACITY - 40 * 4)
	for tamper in ([?]int{2, 0}) {
		r.archive.patch_indices[1] = tamper
		for w in ([?]u32{0x0001C0, 0x0020BF}) {standalone.live_handle_midi(&r.live, w)}
		standalone.program_select_drain(&r.cc)
		_, unread := standalone.midi_queue_pop(&r.live.select_queue)
		testing.expectf(t, !unread, "entry %d waited for room", tamper)
	}
	r.archive.patch_indices[1] = saved[1]
	program_audio(r)
	program_expect_archive(t, r, 0, 0, 48, 5, program_defaults().values)
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))
}

// A peer browsing another bank moves what is open, not where the sound came
// from: the keyboard keeps playing that bank, and what the peer is looking
// at does not move under it.
@(test)
test_native_program_loads_from_the_playing_bank_while_a_peer_browses_another :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	program_open_archive(t, r)
	program_play_archive(t, r, 1, 1)
	testing.expect_value(t, program_ask(r, "1 5 archive.bank 0"), "1 5 ok patches=2 bank=0 archive_rev=3")
	open := program_archive_current(0, 2, 3, "Alpha.zip")
	listed := "1 6 ok total=2 bank=0 archive_rev=3\npatch=0 name=Alpha One\npatch=1 name=Alpha Two"
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)

	program_send(r, {0x0002C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 2, 2, 3, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)
	testing.expect_value(t, program_ask(r, "1 6 archive.patches 0 10"), listed)
	program_send(r, {0x0000C0, 0x0001C0})
	program_audio(r)
	program_expect_archive(t, r, 1, 1, 4, 3, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)

	// A client's load from the open bank makes it the bank the sound plays.
	testing.expect(t, strings.has_prefix(program_ask(r, "1 7 archive.load 1"), "1 7 ok count=3 revision=4 bank=0 patch=1"))
	program_audio(r)
	program_send(r, {0x0000C0})
	program_audio(r)
	program_expect_archive(t, r, 0, 0, 6, 3, program_defaults().values)
	testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)
}

// Archive loads wait for ring room as slot loads do -- whole, in order, never
// counted as dropped, and resolved again when room returns -- whether the
// bank is the open one or one read beside it. What selects nothing never
// waits.
@(test)
test_native_program_archive_loads_wait_for_ring_room :: proc(t: ^testing.T) {
	for peer in ([?]bool{false, true}) {
		r := program_rig(program_defaults())
		defer program_rig_free(r)
		program_open_archive(t, r)
		program_play_archive(t, r, 1, 1)
		rev: uint = 2
		if peer {
			program_ask(r, "1 5 archive.bank 0")
			rev = 3
		}
		open := program_ask(r, "1 2 archive.current")

		// Three Sets and a commit each: after forty, less room is left than
		// a whole slot needs.
		for i in 0 ..< 40 {standalone.live_handle_midi(&r.live, 0x0000C0 | u32(i % 3) << 8)}
		standalone.program_select_drain(&r.cc)
		short := standalone.param_ring_free_space(&r.live.ring)
		testing.expect_value(t, short, standalone.PARAM_RING_CAPACITY - 40 * 4)
		// Past the end: nothing waits, so what is behind is read at once.
		for w in ([?]u32{0x0005C0, 0x007FC0, 0x0020BF}) {standalone.live_handle_midi(&r.live, w)}
		standalone.program_select_drain(&r.cc)
		_, unread := standalone.midi_queue_pop(&r.live.select_queue)
		testing.expectf(t, !unread, "a Program Change that selects nothing held the queue (peer=%v)", peer)
		// A load that would fit waits, whole, with nothing behind it read.
		for w in ([?]u32{0x0002C0, 0x0120B0, 0x0001C0}) {standalone.live_handle_midi(&r.live, w)}
		standalone.program_select_drain(&r.cc)
		standalone.program_select_drain(&r.cc)
		testing.expect_value(t, standalone.param_ring_free_space(&r.live.ring), short)
		testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))
		program_audio(r)
		program_expect_archive(t, r, 1, 0, 41, rev, program_defaults().values)
		// Room again: the held 2 loads first, then LSB=1 makes the 1 miss.
		standalone.program_select_drain(&r.cc)
		program_audio(r)
		program_expect_archive(t, r, 1, 2, 42, rev, program_defaults().values)
		testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)

		// A long burst ends on its last Program Change, every one loaded.
		for i in 0 ..< 100 {standalone.live_handle_midi(&r.live, 0x0000C2 | u32(i % 3) << 8)}
		for _ in 0 ..< 4 {
			standalone.program_select_drain(&r.cc)
			program_audio(r)
		}
		program_expect_archive(t, r, 1, 0, 142, rev, program_defaults().values)
		testing.expect_value(t, program_ask(r, "1 2 archive.current"), open)
		testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))

		// Resolved again when room returns: the archive closed while it
		// waited, so it is the ordinary slot.
		for i in 0 ..< 41 {standalone.live_handle_midi(&r.live, 0x0000C2 | u32(i % 3) << 8)}
		standalone.program_select_drain(&r.cc)
		program_ask(r, "1 9 archive.close")
		program_audio(r)
		standalone.program_select_drain(&r.cc)
		program_audio(r)
		program_expect_slot(t, r, 1, 183, rev + 1)
		testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), u32(0))
	}
}

// As a slot's load: the key that is down keeps sounding, and nothing of the
// previous patch's effects is heard under the next.
@(test)
test_native_program_from_the_archive_replaces_atomically_and_keeps_the_held_note :: proc(t: ^testing.T) {
	from := program_defaults()
	from.values[65], from.values[66], from.values[77] = 1, 1, 1
	from.values[36], from.values[37], from.values[78] = 120, 64, 6
	from.values[19], from.values[29], from.values[90] = 10, 90, 20
	r := program_rig(from)
	defer program_rig_free(r)
	e := &r.live.eng
	program_open_archive(t, r)
	// Beta One names only the oscillators, so the effects stay on.
	program_play_archive(t, r, 1, 0)
	program_send(r, {0x643C92, 0x6000E2})
	for _ in 0 ..< 40 {program_audio(r, 256)}
	pool, size := raw_data(e.voices), len(e.voices)
	voices := engine.engine_active_voice_count(e)
	if !testing.expect(t, voices > 0 && e.held_notes == 1) {return}
	ringing := false
	for v in e.delay_left {if v != 0 {ringing = true; break}}
	if !testing.expect(t, ringing, "no prior effect memory to clear") {return}

	program_send(r, {0x0001C2})
	program_audio(r)
	program_expect_archive(t, r, 1, 1, 2, 2, from.values)
	for buffer in ([?][]f32{e.delay_left, e.delay_right, e.chorus_left, e.chorus_right}) {
		for v in buffer {
			if !testing.expect_value(t, v, f32(0)) {break}
		}
	}
	to := from
	for v, k in program_fixture(1, 1).values {to.values[k] = v}
	fresh: engine.Engine
	engine.engine_load_patch(&fresh, to, 48000)
	defer engine.engine_destroy(&fresh)
	testing.expect_value(t, e.effect, fresh.effect)
	testing.expect_value(t, e.equalizer, fresh.equalizer)
	testing.expect(t, raw_data(e.voices) == pool && len(e.voices) == size)
	testing.expect_value(t, engine.engine_active_voice_count(e), voices)
	testing.expect_value(t, e.held_notes, 1)
	testing.expect_value(t, e.pitch_bend, f32(0.5))
	testing.expect(t, program_audio(r, 256) > 0, "held note stopped sounding")
	program_send(r, {0x003C82})
	testing.expect_value(t, e.held_notes, 0)
}

// The report as a user met it, over a real socket: archive.open, archive.load
// 1 1, then `midi 192 0 0`, with no Bank Select ever sent. The control thread
// loads it on its own tick, and a peer browsing elsewhere changes nothing.
@(test)
test_native_program_over_the_socket_keeps_the_archive_bank :: proc(t: ^testing.T) {
	r := program_rig(program_defaults())
	defer program_rig_free(r)
	cs := standalone.Control_Server{
		path = fmt.tprintf("/tmp/quesynth-program-archive-%d-%p.sock", posix.getpid(), r),
		ctx = r.cc,
	}
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)
	fd, connected := connect_unix(cs.path)
	if !testing.expect(t, connected) {return}
	defer posix.close(fd)
	say :: proc(fd: posix.FD, line: string) -> string {
		reliability_send(fd, line)
		return reliability_reply(fd)
	}
	// Closed by the server thread that opened it, so it is freed with the
	// allocator that made it.
	defer say(fd, "1 99 archive.close")
	await :: proc(r: ^Program_Rig, revision: int) {
		for _ in 0 ..< 100 {
			program_audio(r)
			if r.live.revision == revision {break}
			time.sleep(5 * time.Millisecond)
		}
	}

	testing.expect_value(t, say(fd, "1 1 archive.open " + PROGRAM_ARCHIVE), "1 1 ok banks=2 archive_rev=1")
	testing.expect_value(t, say(fd, "1 2 archive.bank 1"), "1 2 ok patches=3 bank=1 archive_rev=2")
	testing.expect_value(t, say(fd, "1 3 archive.load 1 1"), "1 3 ok count=3 revision=0 bank=1 patch=1")
	await(r, 1)
	testing.expect_value(t, say(fd, "1 4 midi 192 0 0"), "1 4 ok")
	await(r, 2)
	testing.expect_value(t, say(fd, "1 5 patch.current"),
		"1 5 ok slot=-1 bank_rev=0 revision=2 source=archive archive_rev=2 archive_bank=1 archive_patch=0\nbank=Beta Bank.zip\nname=Beta One")
	testing.expect_value(t, say(fd, "1 6 archive.current"),
		"1 6 ok open=1 banks=2 bank=1 patches=3 archive_rev=2\npath=" + PROGRAM_ARCHIVE + "\nbank_name=Beta Bank.zip")

	testing.expect_value(t, say(fd, "1 7 archive.bank 0"), "1 7 ok patches=2 bank=0 archive_rev=3")
	testing.expect_value(t, say(fd, "1 8 midi 192 2 0"), "1 8 ok")
	await(r, 3)
	testing.expect_value(t, say(fd, "1 9 patch.current"),
		"1 9 ok slot=-1 bank_rev=0 revision=3 source=archive archive_rev=3 archive_bank=1 archive_patch=2\nbank=Beta Bank.zip\nname=Beta Three")
	testing.expect_value(t, say(fd, "1 10 archive.current"),
		"1 10 ok open=1 banks=2 bank=0 patches=2 archive_rev=3\npath=" + PROGRAM_ARCHIVE + "\nbank_name=Alpha.zip")
	values := program_defaults().values
	for v, k in program_fixture(1, 2).values {values[k] = v}
	for v, i in values {testing.expect_value(t, r.live.eng.patch.values[i], v)}
}
