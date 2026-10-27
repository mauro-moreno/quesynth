package clap_tests

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"

import clap "../../src/clap"
import panel "../../hosts/panel"
import patch "../../src/patch"
import synth "../../hosts/clap"

// Issue #13, from the host's side: the instance is made again -- the editor
// reopened in REAPER, the plugin taken offline and online, a project loaded --
// and it has to be on the same preset of the same bank as the one that was
// saved, with the same sound.
//
// Every test saves through the plugin's own state extension into a stream and
// loads into a second instance, which is all a host does between the two. A
// second instance starts the way every one does: the bank this machine has, on
// no preset at all.

// A stream that hands over a few bytes at a time, with the context it needs
// kept in itself: the shared one in clap_test.odin is a global that tests
// running side by side overwrite.
Saved_Stream :: struct {
	out:   clap.Ostream,
	input: clap.Istream,
	data:  [dynamic]u8,
	read:  int,
	chunk: int,
	ctx:   runtime.Context,
}

saved_stream_init :: proc(m: ^Saved_Stream, chunk: int, bytes: ..[]u8) {
	m.data = make([dynamic]u8)
	m.chunk = chunk
	m.ctx = context
	for b in bytes {
		append(&m.data, ..b)
	}
	m.out = clap.Ostream {
		ctx = m,
		write = proc "c" (stream: ^clap.Ostream, buffer: rawptr, size: u64) -> i64 {
			m := (^Saved_Stream)(stream.ctx)
			context = m.ctx
			n := min(int(size), m.chunk)
			append(&m.data, ..([^]u8)(buffer)[:n])
			return i64(n)
		},
	}
	m.input = clap.Istream {
		ctx = m,
		read = proc "c" (stream: ^clap.Istream, buffer: rawptr, size: u64) -> i64 {
			m := (^Saved_Stream)(stream.ctx)
			n := min(min(int(size), m.chunk), len(m.data) - m.read)
			copy(([^]u8)(buffer)[:n], m.data[m.read:][:n])
			m.read += n
			return i64(n)
		},
	}
}

// What a host would keep: the state, saved whole.
save_state :: proc(t: ^testing.T, plugin: ^clap.Plugin) -> []u8 {
	stream: Saved_Stream
	saved_stream_init(&stream, 7)
	defer delete(stream.data)
	testing.expect(t, state_of(plugin).save(plugin, &stream.out), "state.save failed")
	return slice.clone(stream.data[:])
}

// ... and handed to an instance. Says whether the instance took it.
load_saved :: proc(plugin: ^clap.Plugin, bytes: []u8) -> bool {
	stream: Saved_Stream
	saved_stream_init(&stream, 5, bytes)
	defer delete(stream.data)
	return state_of(plugin).load(plugin, &stream.input)
}

all_values :: proc(t: ^testing.T, plugin: ^clap.Plugin) -> (values: [patch.PARAMETER_COUNT]int) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		values[i] = value_of(t, plugin, i)
	}
	return
}

// A bank document whose slots are named "<label> <slot>" and sound different
// from each other.
bank_document :: proc(label: string, filled: []int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"format":"quesynth.bank","version":1,"name":"`)
	strings.write_string(&b, label)
	strings.write_string(&b, `","patches":[`)
	last := 0
	for slot in filled {
		last = max(last, slot)
	}
	for i in 0 ..= last {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		is_filled := false
		for slot in filled {
			is_filled ||= slot == i
		}
		if !is_filled {
			strings.write_string(&b, "null")
			continue
		}
		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, label)
		strings.write_string(&b, ` `)
		strings.write_int(&b, i)
		strings.write_string(&b, `","parameters":{"osc1 shape":`)
		strings.write_int(&b, i % 4)
		strings.write_string(&b, `,"amp gain":`)
		strings.write_int(&b, 20 + i)
		strings.write_string(&b, `}}`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// An instance the way the panel leaves one: a bank adopted or kept, a preset of
// it selected, and the sound edited a little after loading it -- which is the
// state of somebody in the middle of work.
work_in_progress :: proc(
	t: ^testing.T,
	label: string,
	filled: []int,
	slot: int,
	source: panel.Bank_Source,
) -> (
	plugin: ^clap.Plugin,
	s: ^synth.Synth,
) {
	plugin = make_plugin(t)
	if plugin == nil {
		return nil, nil
	}
	s = synth.synth_of(plugin)

	saved := source == .Saved
	result := panel.session_set_bank(&s.session, &s.slots, bank_document(label, filled), saved, .Imported, accept_write)
	testing.expect(t, result == .Adopted || result == .Saved, "the bank was refused")

	selection := panel.Selection {
		origin   = .User if saved else .Imported,
		has_slot = true,
		slot     = slot,
	}
	panel.text_set(&selection.label, label)
	testing.expect(t, panel.session_select(&s.session, &s.slots, selection), "the selection was refused")
	s.program = slot

	values, filled_slot := patch.slots_patch(&s.slots, slot)
	testing.expect(t, filled_slot, "the slot is empty")
	CUTOFF :: 19
	values[CUTOFF] += 1
	synth.stage_values(s, values)
	return
}

// Nothing is written to the saved bank on the machine running the tests.
accept_write :: proc(text: string) -> bool {
	return true
}

// -- the offline / online analogue ---------------------------------------------

@(test)
test_an_imported_bank_and_its_program_survive_a_new_instance :: proc(t: ^testing.T) {
	before, a := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	testing.expect(t, patch.slots_label(&b.slots) != "Alfmeister Bank", "the new instance already has the bank, so this proves nothing")

	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	// The bank, the program, the name and the sound.
	testing.expect_value(t, patch.slots_label(&b.slots), "Alfmeister Bank")
	testing.expect_value(t, b.program, 42)
	view := panel.selection_view(&b.session.selection, &b.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 42)
	testing.expect_value(t, view.label, "Alfmeister Bank")
	testing.expect_value(t, view.name, "Alfmeister Bank 42")
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound is not the one that was saved")
	testing.expect(t, b.slots == a.slots, "the bank that came back is not the bank that went")
	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	// Carried by the project and not by the machine: it is still not the
	// user's saved bank.
	testing.expect_value(t, b.session.bank_source, panel.Bank_Source.Adopted)
}

// And again, because offline/online is something people do repeatedly, and an
// imported bank that survived once and then was dropped is still gone.
@(test)
test_the_restored_bank_survives_being_saved_and_restored_again :: proc(t: ^testing.T) {
	first, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if first == nil {return}
	defer first.destroy(first)
	one := save_state(t, first)
	defer delete(one)

	second := make_plugin(t)
	if second == nil {return}
	defer second.destroy(second)
	testing.expect(t, load_saved(second, one), "the first state was refused")
	two := save_state(t, second)
	defer delete(two)

	third := make_plugin(t)
	if third == nil {return}
	defer third.destroy(third)
	testing.expect(t, load_saved(third, two), "the second state was refused")

	c := synth.synth_of(third)
	testing.expect_value(t, patch.slots_label(&c.slots), "Alfmeister Bank")
	testing.expect_value(t, c.program, 42)
	testing.expect(t, all_values(t, first) == all_values(t, third), "the sound changed on the way")
}

@(test)
test_the_users_saved_bank_comes_back_by_name_and_is_not_carried :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "My Saved Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	// The per-user file is every instance's, so the state names it and does not
	// carry it: a bank embedded in every project would be a second copy that
	// disagrees with the file the next time somebody writes a patch.
	trailer, status := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded, "the saved bank was embedded")
	testing.expect(t, trailer.bank_saved, "the state does not say the bank is the saved one")

	// An instance that has that bank: the machine the project was saved on.
	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.program, 7)
	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound is not the one that was saved")
}

// -- the bank is not there --------------------------------------------------------

@(test)
test_a_missing_bank_is_an_explicit_failure_that_keeps_the_sound_and_the_bank :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	// The bank is not on this machine, and something else is: an imported bank
	// that is being played. Not the factory bank, and not the one the project
	// asked for.
	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("Playing Meanwhile", {0, 1}), false, .Imported, nil)
	slots_before := b.slots

	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.session.restore, panel.Restore_State.Failed)
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.Missing_Bank)
	// Nothing was substituted: not the factory bank, not slot 0 of anything.
	testing.expect(t, b.slots == slots_before, "a missing bank changed the bank that is playing")
	testing.expect_value(t, patch.slots_label(&b.slots), "Playing Meanwhile")
	testing.expect_value(t, b.program, 0)
	testing.expect(t, !panel.selection_known(&b.session.selection), "a failed restore claimed a selection")
	// And the sound is the saved sound: the values were never the question.
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound was not kept")
}

// What was asked for is kept, so saving the project again while the bank is
// still missing does not turn a bank that is away into one that never was.
@(test)
test_a_failed_restore_is_saved_again_and_works_when_the_bank_is_back :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	away := make_plugin(t)
	if away == nil {return}
	defer away.destroy(away)
	testing.expect(t, load_saved(away, saved), "the saved state was refused")
	resaved := save_state(t, away)
	defer delete(resaved)

	back := make_plugin(t)
	if back == nil {return}
	defer back.destroy(back)
	b := synth.synth_of(back)
	panel.session_set_bank(&b.session, &b.slots, bank_document("Issue 13 Lost Bank", {0, 7}), true, .User, accept_write)
	testing.expect(t, load_saved(back, resaved), "the second state was refused")

	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, b.program, 7)
	testing.expect(t, all_values(t, before) == all_values(t, back), "the sound changed on the way")
}

@(test)
test_a_slot_that_is_no_longer_filled_is_an_invalid_program_and_keeps_the_sound :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Issue 13 Thin Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	// The bank is there, and slot 7 of it is not.
	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("Issue 13 Thin Bank", {0, 1}), true, .User, accept_write)
	slots_before := b.slots

	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect(t, b.slots == slots_before, "the bank changed")
	testing.expect_value(t, b.program, 0)
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound was not kept")
}

// -- what a host or a different build may send -------------------------------------

// A trailer that cannot be read costs the project its label and nothing else:
// the sound is loaded, and the load is not refused.
@(test)
test_a_trailer_that_cannot_be_read_does_not_refuse_the_state :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)
	values := synth.STATE_SIZE

	newer_bytes := slice.clone(saved)
	defer delete(newer_bytes)
	newer_bytes[values + 4] = 2

	oversize_bytes := slice.clone(saved)
	defer delete(oversize_bytes)
	oversize_bytes[values + 11] = 0x80

	cases := [?]struct {
		name:  string,
		bytes: []u8,
		error: panel.Restore_Error,
	} {
		{"a trailer from a newer build", newer_bytes, .State_Version_Unsupported},
		{"a trailer that is cut short", saved[:values + 40], .Host_State_Rejected},
		{"a trailer cut inside its header", saved[:values + 6], .Host_State_Rejected},
		{"a trailer claiming a size past the cap", oversize_bytes, .Host_State_Rejected},
	}
	for c in cases {
		after := make_plugin(t)
		if after == nil {return}
		defer after.destroy(after)
		b := synth.synth_of(after)
		slots_before := b.slots

		testing.expectf(t, load_saved(after, c.bytes), "%s: the state was refused", c.name)
		testing.expectf(t, b.session.restore_error == c.error, "%s: error is %v, not %v", c.name, b.session.restore_error, c.error)
		testing.expectf(t, b.slots == slots_before, "%s: the bank changed", c.name)
		testing.expectf(t, all_values(t, before) == all_values(t, after), "%s: the sound was not loaded", c.name)
	}
}

// States from before any of this, byte for byte as they were: nothing asked for,
// nothing claimed, nothing reset.
@(test)
test_a_state_from_before_the_trailer_loads_as_it_always_did :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"the golden state", GOLDEN_STATE[:]},
		// Whatever followed the values was never read, and is not now.
		{"the golden state with bytes after it", append_bytes(GOLDEN_STATE[:], 1, 2, 3, 4, 5, 6, 7, 8, 9)},
		{"the golden state with bytes that start like the tag", append_bytes(GOLDEN_STATE[:], 'Q', 'S', 'E')},
	}
	for c in cases {
		plugin := make_plugin(t)
		if plugin == nil {return}
		defer plugin.destroy(plugin)
		s := synth.synth_of(plugin)
		// An instance that thought it knew what it was on.
		panel.session_select_slot(&s.session, 6)
		s.program = 6
		slots_before := s.slots

		testing.expectf(t, load_saved(plugin, c.bytes), "%s: refused", c.name)

		for i in 0 ..< len(GOLDEN_VALUES) {
			testing.expectf(t, value_of(t, plugin, i) == int(GOLDEN_VALUES[i]), "%s: parameter %d", c.name, i)
		}
		testing.expectf(t, s.session.restore == .Not_Requested, "%s: a restore was asked for", c.name)
		testing.expectf(t, s.slots == slots_before, "%s: the bank changed", c.name)
		testing.expectf(t, !panel.selection_known(&s.session.selection), "%s: the instance still claims to know where the sound came from", c.name)
		// Neither Factory nor slot 0: the program is whatever it was.
		testing.expectf(t, s.program == 6, "%s: the program moved to %d", c.name, s.program)
	}
}

@(test)
test_a_state_with_nothing_selected_is_the_bytes_it_always_was :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	saved := save_state(t, plugin)
	defer delete(saved)
	testing.expect_value(t, len(saved), synth.STATE_SIZE)
}

// With a selection, everything up to the last value is what it always was, so a
// build from before reads the project and gets the sound.
@(test)
test_a_state_with_a_selection_starts_with_the_values_as_they_always_were :: proc(t: ^testing.T) {
	plugin, s := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	saved := save_state(t, plugin)
	defer delete(saved)
	testing.expect(t, len(saved) > synth.STATE_SIZE, "the selection was not saved")

	values: [synth.PARAM_COUNT]i32
	for i in 0 ..< synth.PARAM_COUNT {
		values[i] = i32(value_of(t, plugin, i))
	}
	legacy := synth.state_encode(values)
	for i in 0 ..< synth.STATE_SIZE {
		testing.expectf(t, saved[i] == legacy[i], "byte %d is 0x%02X, a state without a selection has 0x%02X", i, saved[i], legacy[i])
	}
	_ = s
}

// A build that has more parameters writes them all, and then the trailer: the
// extra ones are skipped, never read as one.
@(test)
test_a_trailer_after_values_this_build_does_not_have_is_still_found :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	blob := make([dynamic]u8)
	defer delete(blob)
	append(&blob, ..saved[:synth.STATE_SIZE])
	declared := u32(synth.PARAM_COUNT + 3)
	blob[8] = u8(declared)
	append(&blob, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0)
	append(&blob, ..saved[synth.STATE_SIZE:])

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	testing.expect(t, load_saved(after, blob[:]), "refused")

	b := synth.synth_of(after)
	testing.expect_value(t, b.program, 42)
	testing.expect_value(t, patch.slots_label(&b.slots), "Alfmeister Bank")
}

// -- a program change after a restore ---------------------------------------------

@(test)
test_a_program_change_after_a_restore_selects_the_exact_slot_of_the_restored_bank :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := active_plugin(t)
	if after == nil {return}
	defer finish(after)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	b := synth.synth_of(after)

	wanted, filled := patch.slots_patch(&b.slots, 7)
	testing.expect(t, filled, "slot 7 of the restored bank is empty")
	send_midi(after, midi_event(0, 0xC0, 7, 0))

	view := panel.selection_view(&b.session.selection, &b.slots)
	testing.expect_value(t, view.slot, 7)
	testing.expect_value(t, view.label, "Alfmeister Bank")
	testing.expect_value(t, view.name, "Alfmeister Bank 7")
	testing.expect_value(t, b.program, 7)
	same := true
	for i in 0 ..< synth.PARAM_COUNT {
		if b.values[i] != wanted[i] {same = false}
	}
	testing.expect(t, same, "the program change did not load slot 7 of the restored bank")
}

// Bank select other than 0 is still ignored after a restore, as before: there
// is one bank, and it is the one the project came back with.
@(test)
test_midi_bank_select_other_than_zero_is_still_ignored_after_a_restore :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := active_plugin(t)
	if after == nil {return}
	defer finish(after)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	b := synth.synth_of(after)
	// A block with nothing in it, for the audio thread to take up the loaded
	// sound before it is compared with itself.
	send_midi(after)
	values_before := b.values

	send_midi(after, midi_event(0, 0xB0, 0, 0), midi_event(0, 0xB0, 32, 1), midi_event(0, 0xC0, 7, 0))

	testing.expect(t, b.values == values_before, "a program change into bank 1 was obeyed")
	testing.expect_value(t, b.session.selection.slot, 42)
	testing.expect_value(t, b.program, 42)
}

append_bytes :: proc(base: []u8, extra: ..u8) -> []u8 {
	out := make([]u8, len(base) + len(extra), context.temp_allocator)
	copy(out, base)
	copy(out[len(base):], extra)
	return out
}
