#+build linux
package standalone_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import control "../../src/control"
import engine "../../src/engine"
import patch "../../src/patch"
import registry "../../src/registry"
import standalone "../../hosts/standalone"

// Loading a patch replaces it on the audio thread. Whatever the previous patch
// left in the effects, the smoothers or a reassigned controller must not be
// heard under the next one, and the key that is down must keep sounding. These
// drive each way a patch reaches the daemon end to end without a device: the
// real control_handle, the ring, live_render, the engine and the snapshot.
//
// What the result should be never comes from the replacement code. It comes
// from the patches built here, bound with bind_patch; from the bytes of the
// archive fixture; and from an engine that loaded the same patch fresh and so
// never heard the one before it.

@(private = "file")
BLOCK :: 256

// A factory bank slot that is empty, so a test can fill it with its own patch.
@(private = "file")
SPARE_SLOT :: 120

@(private = "file")
CC1 :: 0xB001

@(private = "file")
CC2 :: 0xB002

// What a live daemon is made of, minus the device: a Live the audio callback
// renders, and the control context sharing its ring and snapshot.
@(private = "file")
Rig :: struct {
	live:     standalone.Live,
	state:    standalone.Daemon_State,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	archive:  standalone.Archive,
	cc:       standalone.Control_Context,
}

@(private = "file")
rig_make :: proc(p: patch.Patch) -> ^Rig {
	r := new(Rig)
	engine.engine_load_patch(&r.live.eng, p, 48000)
	r.live.left = make([]f32, BLOCK)
	r.live.right = make([]f32, BLOCK)
	r.live.volume.milli = standalone.VOLUME_UNITY
	r.live.volume_prev = standalone.VOLUME_UNITY
	// As run_daemon publishes it before the first edit.
	first: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {first.values[i] = i32(p.values[i])}
	standalone.snapshot_publish(&r.live.snapshot, first)
	patch.factory_prepare()
	patch.slots_load_factory(&r.bank)
	r.state = .Running
	r.identity = standalone.Patch_Identity{slot = -1}
	r.cc = standalone.Control_Context {
		ring     = &r.live.ring,
		snapshot = &r.live.snapshot,
		state    = &r.state,
		bank     = &r.bank,
		archive  = &r.archive,
		identity = &r.identity,
	}
	return r
}

@(private = "file")
rig_free :: proc(r: ^Rig) {
	standalone.archive_close(&r.archive)
	engine.engine_destroy(&r.live.eng)
	delete(r.live.left)
	delete(r.live.right)
	free(r)
}

// One request through the real parser and handler; the reply payload.
@(private = "file")
ask_live :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

// One stereo block through the real callback; its loudest sample.
@(private = "file")
render :: proc(r: ^Rig) -> (peak: f32) {
	out: [BLOCK * 2]f32
	standalone.live_render(&r.live, raw_data(out[:]), BLOCK, 2)
	for v in out {peak = max(peak, abs(v))}
	return
}

// The top of the audio callback and nothing else: queues drained, edits
// applied, the snapshot republished. A zero-length block renders nothing, so
// what the load did can be read before a sample moves any of it.
@(private = "file")
apply :: proc(r: ^Rig) {
	out: [2]f32
	standalone.live_render(&r.live, raw_data(out[:]), 0, 2)
}

@(private = "file")
midi :: proc(r: ^Rig, status, data1, data2: u8) {
	standalone.live_handle_midi(&r.live, standalone.midi_pack(status, data1, data2))
}

@(private = "file")
silent :: proc(buffer: []f32) -> bool {
	for v in buffer {
		if v != 0 {return false}
	}
	return true
}

// Every section that holds memory switched on and holding a lot of it, the amp
// release at zero so the note is gone long before its tails, and controller
// slot 1 listening to `source` at full positive amount on the cutoff. Slot 2
// listens to nothing, so only slot 1 can move anything.
@(private = "file")
tail_patch :: proc(source: int) -> (p: patch.Patch) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
		p.present[i] = true
	}
	p.values[28] = 0 // amp release
	p.values[65] = 1 // delay on
	p.values[36] = 120 // delay feedback
	p.values[37] = 64 // delay dry/wet
	p.values[66] = 1 // chorus on
	p.values[77] = 1 // effect on
	p.values[78] = 6 // ph1, a phaser
	p.values[81] = 127 // effect level
	p.values[86] = source
	p.values[87] = 19
	p.values[50] = 127
	p.values[88] = 0
	return
}

// The patch playing before each load.
@(private = "file")
first_patch :: proc() -> patch.Patch {
	p := tail_patch(CC1)
	p.values[0] = 2
	p.values[19] = 10
	p.values[29] = 90
	p.values[90] = 20
	return p
}

// The patch a slot or a file replaces it with: every smoothed target moved, and
// a polyphony the pool was not built for.
@(private = "file")
second_patch :: proc(source: int) -> patch.Patch {
	p := tail_patch(source)
	p.values[19] = 60
	p.values[29] = 40
	p.values[90] = 110
	p.values[94] = 4
	return p
}

// Leave the previous patch ringing: a note played into its tails and let go,
// its voice finished, and controller 1 pushed all the way up.
@(private = "file")
leave_ringing :: proc(t: ^testing.T, r: ^Rig) -> bool {
	midi(r, 0x90, 60, 127)
	for _ in 0 ..< 40 {render(r)}
	midi(r, 0x80, 60, 0)
	for _ in 0 ..< 400 {
		render(r)
		if engine.engine_active_voice_count(&r.live.eng) == 0 {break}
	}
	midi(r, 0xB0, 1, 127)
	still := f32(0)
	for _ in 0 ..< 4 {still = render(r)}
	quiet := testing.expect_value(t, engine.engine_active_voice_count(&r.live.eng), 0)
	ringing := testing.expect(t, still > 0, "the first patch left nothing ringing")
	tails := testing.expect(t, !silent(r.live.eng.delay_left) && !silent(r.live.eng.chorus_left), "no tail to clear")
	wheel := testing.expect_value(t, r.live.eng.ctrl_value[0], f32(1))
	return quiet && ringing && tails && wheel
}

@(private = "file")
Entry :: enum {
	Slot,
	File,
	Archive,
	Apply,
}

// The pairs patch.apply carries for a whole patch: every parameter the daemon
// exposes, as the browser adapter sends them.
@(private = "file")
apply_command :: proc(id: int, to: patch.Patch) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "1 %d patch.apply", id)
	for d in registry.registry_list() {
		fmt.sbprintf(&b, " %s %d", d.id, to.values[d.index])
	}
	return strings.to_string(b)
}

// Load `to` through one entry point, and say what the engine's patch must then
// be and how many Sets the load stages. A slot and a file carry all ninety-nine
// values. The archive fixture's 002.sy1 names only parameters 0..2, as 1, 32
// and 10, and patch.apply only what the registry exposes; what a load does not
// name keeps the value it had.
@(private = "file")
load_by :: proc(
	t: ^testing.T,
	r: ^Rig,
	entry: Entry,
	from, to: patch.Patch,
) -> (
	expected: patch.Patch,
	sets: int,
	ok: bool,
) {
	reply: string
	switch entry {
	case .Slot:
		for i in 0 ..< patch.PARAMETER_COUNT {r.bank.values[SPARE_SLOT][i] = i32(to.values[i])}
		r.bank.filled[SPARE_SLOT] = true
		reply = ask_live(&r.cc, fmt.tprintf("1 1 patch.load %d", SPARE_SLOT))
		expected, sets = to, patch.PARAMETER_COUNT
	case .File:
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "Synth1 replacement\r\ncolor=default\r\nver=113\r\n")
		for i in 0 ..< patch.PARAMETER_COUNT {fmt.sbprintf(&b, "%d,%d\r\n", i, to.values[i])}
		path := fmt.tprintf("/tmp/quesynth-replace-%d-%p.sy1", posix.getpid(), r)
		if !testing.expect(t, os.write_entire_file_from_string(path, strings.to_string(b)) == nil) {
			return
		}
		defer os.remove(path)
		reply = ask_live(&r.cc, fmt.tprintf("1 1 patch.load_file %s", path))
		expected, sets = to, patch.PARAMETER_COUNT
	case .Archive:
		ask_live(&r.cc, "1 1 archive.open tests/zip/fixtures/nested.zip")
		ask_live(&r.cc, "1 1 archive.bank 0")
		reply = ask_live(&r.cc, "1 1 archive.load 1")
		expected = from
		expected.values[0], expected.values[1], expected.values[2] = 1, 32, 10
		sets = 3
	case .Apply:
		reply = ask_live(&r.cc, apply_command(1, to))
		expected = from
		for d in registry.registry_list() {expected.values[d.index] = to.values[d.index]}
		sets = len(registry.registry_list())
	}
	ok = testing.expectf(t, strings.has_prefix(reply, "1 1 ok"), "%v refused: %s", entry, reply)
	return
}

// What a command left on the ring, in order, put back so the audio side still
// finds it.
@(private = "file")
ring_contents :: proc(ring: ^standalone.Param_Ring) -> []standalone.Param_Command {
	cmds := make([dynamic]standalone.Param_Command, context.temp_allocator)
	for {
		cmd, ok := standalone.param_ring_pop(ring)
		if !ok {break}
		append(&cmds, cmd)
	}
	for cmd in cmds {standalone.param_ring_push(ring, cmd)}
	return cmds[:]
}

// Only Sets, then exactly one Commit_Patch, last.
@(private = "file")
expect_replacement :: proc(t: ^testing.T, cmds: []standalone.Param_Command, sets: int, entry: Entry) {
	testing.expectf(t, len(cmds) == sets + 1, "%v queued %d commands, not %d Sets and a commit", entry, len(cmds), sets)
	for cmd, i in cmds {
		want := i == len(cmds) - 1 ? standalone.Param_Command_Kind.Commit_Patch : standalone.Param_Command_Kind.Set
		testing.expectf(t, cmd.kind == want, "%v: command %d is %v, not %v", entry, i, cmd.kind, want)
	}
}

// Each entry point, and whether controller slot 1 still listens to controller 1
// after it. A slot and a file here reassign it to controller 2; an archive
// entry that does not name the routing and patch.apply, which cannot carry it,
// leave it on controller 1 -- and the wheel stays where it is.
@(private = "file")
ENTRIES := [?]struct {
	entry: Entry,
	kept:  bool,
}{{.Slot, false}, {.File, false}, {.Archive, true}, {.Apply, true}}

@(test)
test_every_patch_load_replaces_the_patch_on_the_audio_thread :: proc(t: ^testing.T) {
	from := first_patch()
	to := second_patch(CC2)
	for c in ENTRIES {
		r := rig_make(from)
		defer rig_free(r)
		if !leave_ringing(t, r) {return}
		pool := raw_data(r.live.eng.voices)
		size := len(r.live.eng.voices)
		revision := standalone.snapshot_read(&r.live.snapshot).revision

		expected, sets, loaded := load_by(t, r, c.entry, from, to)
		if !loaded {continue}
		expect_replacement(t, ring_contents(&r.live.ring), sets, c.entry)
		apply(r)

		// Applied once, and the snapshot is the patch that was loaded.
		snap := standalone.snapshot_read(&r.live.snapshot)
		testing.expectf(t, snap.revision == revision + 1, "%v: revision %d after %d", c.entry, snap.revision, revision)
		for i in 0 ..< patch.PARAMETER_COUNT {
			if snap.values[i] != i32(expected.values[i]) {
				testing.expectf(t, false, "%v: parameter %d reads %d, the patch says %d", c.entry, i, snap.values[i], expected.values[i])
				break
			}
		}

		// Nothing of the previous patch is left to read back out.
		e := &r.live.eng
		fresh: engine.Engine
		engine.engine_load_patch(&fresh, expected, 48000)
		defer engine.engine_destroy(&fresh)
		for buffer in ([?][]f32{e.delay_left, e.delay_right, e.chorus_left, e.chorus_right}) {
			testing.expectf(t, silent(buffer), "%v: a delay line still holds the previous patch", c.entry)
		}
		testing.expectf(t, e.effect == fresh.effect, "%v: the effect unit kept the previous patch's state", c.entry)
		testing.expectf(t, e.equalizer == fresh.equalizer, "%v: the equaliser kept the previous patch's state", c.entry)
		testing.expectf(t, e.delay.tone == fresh.delay.tone, "%v: the delay tone kept its state", c.entry)
		testing.expectf(t, e.chorus.phase == fresh.chorus.phase, "%v: the chorus kept its phase", c.entry)

		// The smoothers stand at what the new patch plays, with the wheel
		// where it still is when its slot kept listening to it.
		want := expected
		if c.kept {want.values[19] = 127}
		bound := engine.bind_patch(want)
		testing.expectf(t, e.cutoff_smooth.value == bound.filter_cutoff_state, "%v: cutoff glides from %v to %v", c.entry, e.cutoff_smooth.value, bound.filter_cutoff_state)
		testing.expectf(t, e.gain_smooth.value == bound.amp_gain, "%v: gain glides from %v to %v", c.entry, e.gain_smooth.value, bound.amp_gain)
		testing.expectf(t, e.pan_smooth.value == bound.pan, "%v: pan glides from %v to %v", c.entry, e.pan_smooth.value, bound.pan)

		// The pool the daemon started with, whatever parameter 94 now says.
		testing.expectf(t, raw_data(e.voices) == pool && len(e.voices) == size, "%v: the voice pool was rebuilt", c.entry)

		// And with no key down, the next block is silence, not the last tail.
		peak := render(r)
		testing.expectf(t, peak == 0, "%v: the previous patch is still heard at %v", c.entry, peak)
	}
}

// A slot reassigned to another controller number forgets the old wheel: the new
// patch plays exactly as written. One that still listens to the same number
// keeps it, displaced from the new patch's own base, because the wheel has not
// moved. That is the rule engine_apply_patch and the plugin hosts share.
@(test)
test_a_patch_load_keeps_a_controller_only_while_its_slot_listens_to_it :: proc(t: ^testing.T) {
	from := first_patch()
	Case :: struct {
		entry:  Entry,
		source: int,
		kept:   bool,
	}
	cases := [?]Case {
		{.Slot, CC2, false},
		{.File, CC2, false},
		{.Slot, CC1, true},
		{.File, CC1, true},
		{.Archive, CC1, true},
		{.Apply, CC2, true}, // the routing is not exposed, so it stays on CC1
	}
	for c in cases {
		r := rig_make(from)
		defer rig_free(r)
		if !leave_ringing(t, r) {return}
		expected, _, loaded := load_by(t, r, c.entry, from, second_patch(c.source))
		if !loaded {continue}
		apply(r)

		e := &r.live.eng
		want := expected
		if c.kept {
			want.values[19] = 127
			testing.expectf(t, e.ctrl_value[0] == 1, "%v %x: the wheel was forgotten", c.entry, c.source)
		} else {
			testing.expectf(t, e.ctrl_value[0] == 0, "%v %x: a controller the patch no longer listens to kept %v", c.entry, c.source, e.ctrl_value[0])
		}
		bound := engine.bind_patch(want)
		bound.polyphony = len(e.voices)
		testing.expectf(t, e.params == bound, "%v %x: the engine does not play the loaded patch", c.entry, c.source)
		testing.expectf(t, e.params.filter_cutoff_hz == bound.filter_cutoff_hz, "%v %x: cutoff %v, the patch says %v", c.entry, c.source, e.params.filter_cutoff_hz, bound.filter_cutoff_hz)
	}
}

// The contrast that shows what the replacement removes. The same values sent
// as ordinary edits -- parameter.set_many, then parameter.set -- leave the
// previous patch's tails in the lines and audible, glide the smoothed targets,
// keep the wheel, and commit with Commit, as before replacement existed.
@(test)
test_ordinary_edits_keep_the_tails_and_the_glide :: proc(t: ^testing.T) {
	from := first_patch()
	to := second_patch(CC2)
	r := rig_make(from)
	defer rig_free(r)
	if !leave_ringing(t, r) {return}
	e := &r.live.eng
	revision := standalone.snapshot_read(&r.live.snapshot).revision

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "1 1 parameter.set_many")
	for d in registry.registry_list() {fmt.sbprintf(&b, " %s %d", d.id, to.values[d.index])}
	count := len(registry.registry_list())
	testing.expect_value(t, ask_live(&r.cc, strings.to_string(b)), fmt.tprintf("1 1 ok count=%d revision=%d", count, revision))
	cmds := ring_contents(&r.live.ring)
	testing.expect_value(t, len(cmds), count + 1)
	testing.expect_value(t, cmds[len(cmds) - 1].kind, standalone.Param_Command_Kind.Commit)

	smoothed := [3]f32{e.cutoff_smooth.value, e.gain_smooth.value, e.pan_smooth.value}
	apply(r)
	testing.expect_value(t, standalone.snapshot_read(&r.live.snapshot).revision, revision + 1)
	testing.expect_value(t, standalone.snapshot_read(&r.live.snapshot).values[19], i32(to.values[19]))
	testing.expect(t, !silent(e.delay_left), "an edit cleared the delay")
	testing.expect(t, !silent(e.chorus_left), "an edit cleared the chorus")
	testing.expect_value(t, e.cutoff_smooth.value, smoothed[0])
	testing.expect_value(t, e.gain_smooth.value, smoothed[1])
	testing.expect_value(t, e.pan_smooth.value, smoothed[2])
	testing.expect_value(t, e.ctrl_value[0], f32(1))
	testing.expect(t, render(r) > 0, "the previous patch's tail stopped under an edit")

	testing.expect_value(t, ask_live(&r.cc, "1 2 parameter.set filter.cutoff 30"), fmt.tprintf("1 2 ok value=30 revision=%d", revision + 1))
	cmds = ring_contents(&r.live.ring)
	testing.expect_value(t, len(cmds), 2)
	testing.expect_value(t, cmds[1].kind, standalone.Param_Command_Kind.Commit)
	apply(r)
	testing.expect_value(t, standalone.snapshot_read(&r.live.snapshot).revision, revision + 2)
	testing.expect(t, !silent(e.delay_left), "an edit cleared the delay")
	testing.expect(t, render(r) > 0, "the previous patch's tail stopped under an edit")
}

// A key held through a load keeps sounding: same voice, same pool, still gated,
// still counted as held, the bend where it was -- even when the loaded patch
// asks for another polyphony, which the daemon does not allocate for.
@(test)
test_a_patch_load_keeps_the_held_note :: proc(t: ^testing.T) {
	from := first_patch()
	to := second_patch(CC2)
	for c in ENTRIES {
		r := rig_make(from)
		defer rig_free(r)
		e := &r.live.eng
		midi(r, 0x90, 60, 100)
		midi(r, 0xE0, 0, 96)
		render(r)
		render(r)
		pool := raw_data(e.voices)
		size := len(e.voices)
		sounding := engine.engine_active_voice_count(e)
		bend := e.pitch_bend
		if !testing.expect(t, sounding > 0 && bend != 0) {return}

		if _, _, loaded := load_by(t, r, c.entry, from, to); !loaded {continue}
		apply(r)

		testing.expectf(t, raw_data(e.voices) == pool && len(e.voices) == size, "%v: the voice pool was rebuilt", c.entry)
		testing.expectf(t, engine.engine_active_voice_count(e) == sounding, "%v: %d voices sound, not %d", c.entry, engine.engine_active_voice_count(e), sounding)
		testing.expectf(t, e.held_notes == 1, "%v: %d keys held, not 1", c.entry, e.held_notes)
		testing.expectf(t, e.pitch_bend == bend, "%v: the bend moved to %v", c.entry, e.pitch_bend)
		held := false
		for &v in e.voices {
			if v.active && v.gate && v.note == 60 {held = true}
		}
		testing.expectf(t, held, "%v: the held note was cut", c.entry)
		testing.expectf(t, render(r) > 0, "%v: the held note stopped sounding", c.entry)
	}
}

// patch.apply takes set_many's grammar and refuses the same things, in its own
// words, leaving the ring untouched every time.
@(test)
test_patch_apply_grammar_and_refusals :: proc(t: ^testing.T) {
	r := rig_make(first_patch())
	defer rig_free(r)

	too_many := strings.builder_make(context.temp_allocator)
	strings.write_string(&too_many, "1 6 patch.apply")
	for _ in 0 ..< standalone.TXN_STAGING_MAX + 1 {strings.write_string(&too_many, " filter.cutoff 1")}

	refusals := [?][2]string {
		{"1 1 patch.apply", "1 1 err invalid_payload apply needs id value pairs"},
		{"1 2 patch.apply filter.cutoff", "1 2 err invalid_payload apply needs id value pairs"},
		{"1 3 patch.apply filter.cutoff 10 amp.attack", "1 3 err invalid_payload apply needs id value pairs"},
		{"1 4 patch.apply filter.cutoff 10 amp.attack x", "1 4 err invalid_payload value is not an integer"},
		{"1 5 patch.apply filter.cutoff 10 no.such 3", "1 5 err unknown_parameter no such parameter"},
		{strings.to_string(too_many), "1 6 err transaction_failed too many parameters in one transaction"},
		{"1 7 patch.apply filter.cutoff 999", "1 7 err out_of_range value out of range"},
		// set_many shares the code and keeps its own words.
		{"1 10 parameter.set_many filter.cutoff", "1 10 err invalid_payload set_many needs id value pairs"},
	}
	for c in refusals {
		testing.expect_value(t, ask_live(&r.cc, c[0]), c[1])
		testing.expectf(t, len(ring_contents(&r.live.ring)) == 0, "%s reached the ring", c[0])
	}

	// No room for the pairs and their commit: refused, counted once, nothing
	// queued.
	for _ in 0 ..< standalone.PARAM_RING_CAPACITY - 1 {
		standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Commit})
	}
	dropped := standalone.param_ring_dropped(&r.live.ring)
	testing.expect_value(t, ask_live(&r.cc, "1 8 patch.apply filter.cutoff 10"), "1 8 err daemon_not_ready control queue full")
	testing.expect_value(t, standalone.param_ring_dropped(&r.live.ring), dropped + 1)
	testing.expect_value(t, len(ring_contents(&r.live.ring)), standalone.PARAM_RING_CAPACITY - 1)
	for {
		if _, ok := standalone.param_ring_pop(&r.live.ring); !ok {break}
	}

	// Accepted: count is the pairs given, duplicates go as given and in order,
	// and the later one is what the patch ends up holding.
	testing.expect_value(t, ask_live(&r.cc, "1 9 patch.apply filter.cutoff 10 filter.cutoff 20 amp.attack 5"), "1 9 ok count=3 revision=0")
	cmds := ring_contents(&r.live.ring)
	want := [?]standalone.Param_Command {
		{kind = .Set, index = 19, stored = 10},
		{kind = .Set, index = 19, stored = 20},
		{kind = .Set, index = 25, stored = 5},
		{kind = .Commit_Patch},
	}
	if testing.expect_value(t, len(cmds), len(want)) {
		for i in 0 ..< len(want) {testing.expect_value(t, cmds[i], want[i])}
	}
	apply(r)
	snap := standalone.snapshot_read(&r.live.snapshot)
	testing.expect_value(t, snap.revision, 1)
	testing.expect_value(t, snap.values[19], 20)
	testing.expect_value(t, snap.values[25], 5)
}

// patch.apply names no patch: which one is playing stays whatever the client
// says next (the browser adapter clears it), not something apply decides.
@(test)
test_patch_apply_leaves_the_identity_alone :: proc(t: ^testing.T) {
	r := rig_make(first_patch())
	defer rig_free(r)
	k := -1
	for i in 0 ..< patch.FACTORY_SLOTS {
		if r.bank.filled[i] {k = i; break}
	}
	if !testing.expect(t, k >= 0) {return}
	testing.expect(t, strings.has_prefix(ask_live(&r.cc, fmt.tprintf("1 1 patch.load %d", k)), "1 1 ok"))
	apply(r)
	before := ask_live(&r.cc, "1 2 patch.current")
	testing.expect(t, strings.has_prefix(ask_live(&r.cc, "1 3 patch.apply filter.cutoff 10"), "1 3 ok"))
	testing.expect_value(t, ask_live(&r.cc, "1 2 patch.current"), before)
}

// The ring side of a replacement, as transaction_test.odin pins it for edits: a
// split replacement waits for its commit, a Commit_Patch is never staged as an
// edit, and a replacement that changes nothing still clears what was ringing.
@(test)
test_a_replacement_commits_once_and_is_never_staged :: proc(t: ^testing.T) {
	from := first_patch()
	r := rig_make(from)
	defer rig_free(r)

	standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Set, index = 19, stored = 50})
	testing.expect(t, !standalone.live_drain_control(&r.live))
	testing.expect_value(t, r.live.revision, 0)
	testing.expect_value(t, engine.engine_patch_value(&r.live.eng, 19), from.values[19])

	standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Commit_Patch})
	testing.expect(t, standalone.live_drain_control(&r.live))
	testing.expect_value(t, r.live.revision, 1)
	testing.expect_value(t, r.live.txn_count, 0)
	testing.expect_value(t, engine.engine_patch_value(&r.live.eng, 19), 50)

	// Staged as an edit, the Commit_Patch would become a Set of parameter 0 to
	// zero for the Commit after it to apply.
	standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Commit_Patch})
	standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Commit})
	testing.expect(t, standalone.live_drain_control(&r.live))
	testing.expect_value(t, r.live.revision, 3)
	testing.expect_value(t, r.live.txn_count, 0)
	testing.expect_value(t, engine.engine_patch_value(&r.live.eng, 0), from.values[0])

	if !leave_ringing(t, r) {return}
	standalone.param_ring_push(&r.live.ring, standalone.Param_Command{kind = .Commit_Patch})
	apply(r)
	testing.expect_value(t, standalone.snapshot_read(&r.live.snapshot).revision, 4)
	testing.expect(t, silent(r.live.eng.delay_left) && silent(r.live.eng.chorus_left), "an unchanged patch kept its tails")
	testing.expect_value(t, render(r), 0)
}
