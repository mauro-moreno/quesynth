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
// values produced by the replacement path itself.
@(private = "file")
Program_Rig :: struct {
	live: standalone.Live,
	bank: patch.Slots,
	identity: standalone.Patch_Identity,
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
		program = &r.program,
	}
	return r
}

@(private = "file")
program_rig_free :: proc(r: ^Program_Rig) {
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
program_expect_slot :: proc(t: ^testing.T, r: ^Program_Rig, slot, revision: int) {
	values, filled := patch.factory_patch(slot)
	if !testing.expect(t, filled) {return}
	snap := standalone.snapshot_read(&r.live.snapshot)
	testing.expect_value(t, snap.revision, revision)
	for v, i in values {
		testing.expect_value(t, snap.values[i], i32(v))
		testing.expect_value(t, engine.engine_patch_value(&r.live.eng, i), v)
	}
	testing.expect_value(t, program_ask(r, "1 1 patch.current"), fmt.tprintf(
		"1 1 ok slot=%d bank_rev=0 revision=%d\nbank=Factory\nname=%s",
		slot, revision, patch.factory_name(slot),
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
		"1 1 ok slot=127 bank_rev=0 revision=3\nbank=Bank\nname=Init")
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
			"1 1 ok slot=120 bank_rev=9 revision=1\nbank=User bank with spaces\nname=New held sound")
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
		"1 1 ok slot=6 bank_rev=0 revision=1\nbank=Factory\nname=Organ")
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
		"1 3 ok slot=7 bank_rev=0 revision=2\nbank=Factory\nname=%s", patch.factory_name(7)))
	values, _ := patch.factory_patch(7)
	for v, i in values {testing.expect_value(t, r.live.eng.patch.values[i], v)}
}
