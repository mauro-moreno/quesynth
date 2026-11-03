package vst3_tests

import "core:slice"
import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// Issue #13, from the host's side: the instance is made again -- the editor
// reopened, REAPER's offline then online, a project reloaded -- and it has to
// be on the same preset of the same bank as the one that was saved, with the
// same sound.
//
// Every test saves through the plugin's own IComponent state into a stream and
// loads into a second instance, which is all a host does between the two. A
// second instance starts the way every one does: the bank this machine has, on
// no preset at all.

save_session :: proc(t: ^testing.T, p: ^synth.Plugin) -> []u8 {
	out: Memory_Stream
	memory_stream_init(&out, 7)
	defer memory_stream_destroy(&out)
	testing.expect_value(t, synth.component_get_state(rawptr(p), stream_of(&out)), vst3.RESULT_OK)
	return slice.clone(out.data[:])
}

load_session :: proc(p: ^synth.Plugin, bytes: []u8) -> vst3.Result {
	in_: Memory_Stream
	memory_stream_init(&in_, 5, bytes)
	defer memory_stream_destroy(&in_)
	return synth.component_set_state(rawptr(p), stream_of(&in_))
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

// Nothing is written to the saved bank on the machine running the tests.
accept_write :: proc(text: string) -> bool {
	return true
}

// An instance the way the panel leaves one: a bank adopted or kept, a preset of
// it selected, and the sound edited a little after loading it -- which is the
// state of somebody in the middle of work.
work_in_progress :: proc(t: ^testing.T, label: string, filled: []int, slot: int, source: panel.Bank_Source) -> ^synth.Plugin {
	p := synth.make_plugin()
	if p == nil {
		return nil
	}
	saved := source == .Saved
	result := panel.session_set_bank(&p.session, &p.slots, bank_document(label, filled), saved, .Imported, accept_write)
	testing.expect(t, result == .Adopted || result == .Saved, "the bank was refused")

	selection := panel.Selection {
		origin   = .User if saved else .Imported,
		has_slot = true,
		slot     = slot,
	}
	panel.text_set(&selection.label, label)
	testing.expect(t, panel.session_select(&p.session, &p.slots, selection), "the selection was refused")
	p.program = i32(slot)

	values, filled_slot := patch.slots_patch(&p.slots, slot)
	testing.expect(t, filled_slot, "the slot is empty")
	CUTOFF :: 19
	values[CUTOFF] += 1
	synth.stage_values(p, values[:])
	return p
}

// What the host reads back for the program parameter.
program_of_instance :: proc(p: ^synth.Plugin) -> f64 {
	return synth.controller_get_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID)
}

values_of_instance :: proc(p: ^synth.Plugin) -> (values: [patch.PARAMETER_COUNT]i32) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		values[i] = synth.main_thread_value(p, i)
	}
	return
}

// -- the offline / online analogue ---------------------------------------------

@(test)
an_imported_bank_and_its_program_survive_a_new_instance :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	testing.expect(t, patch.slots_label(&after.slots) != "Alfmeister Bank", "the new instance already has the bank, so this proves nothing")

	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	// The bank, the program, the name and the sound.
	testing.expect_value(t, patch.slots_label(&after.slots), "Alfmeister Bank")
	testing.expect_value(t, after.program, i32(42))
	// What the host reads for the program parameter is the exact slot.
	testing.expect_value(t, program_of_instance(after), synth.program_normalized(42))
	view := panel.selection_view(&after.session.selection, &after.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 42)
	testing.expect_value(t, view.label, "Alfmeister Bank")
	testing.expect_value(t, view.name, "Alfmeister Bank 42")
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound is not the one that was saved")
	testing.expect(t, after.slots == before.slots, "the bank that came back is not the bank that went")
	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	// Carried by the project and not by the machine.
	testing.expect_value(t, after.session.bank_source, panel.Bank_Source.Adopted)

	// And the host's own program list, which it draws from the instance, is the
	// bank that came back.
	name: vst3.String128
	testing.expect_value(t, synth.unit_get_program_name(rawptr(&after.unit_info_vtbl), synth.PROGRAM_LIST_ID, 42, &name), vst3.RESULT_OK)
	text := vst3.utf16_to_string(&name)
	defer delete(text)
	testing.expect_value(t, text, "Alfmeister Bank 42")
}

@(test)
the_restored_bank_survives_being_saved_and_restored_again :: proc(t: ^testing.T) {
	first := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if first == nil {return}
	defer synth.release(first)
	one := save_session(t, first)
	defer delete(one)

	second := synth.make_plugin()
	if second == nil {return}
	defer synth.release(second)
	testing.expect_value(t, load_session(second, one), vst3.RESULT_OK)
	two := save_session(t, second)
	defer delete(two)

	third := synth.make_plugin()
	if third == nil {return}
	defer synth.release(third)
	testing.expect_value(t, load_session(third, two), vst3.RESULT_OK)

	testing.expect_value(t, patch.slots_label(&third.slots), "Alfmeister Bank")
	testing.expect_value(t, third.program, i32(42))
	testing.expect(t, values_of_instance(first) == values_of_instance(third), "the sound changed on the way")
}

@(test)
the_users_saved_bank_comes_back_by_name_and_is_not_carried :: proc(t: ^testing.T) {
	before := work_in_progress(t, "My Saved Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	// The per-user file is every instance's, so the state names it and does not
	// carry it.
	trailer, status := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded, "the saved bank was embedded")
	testing.expect(t, trailer.bank_saved, "the state does not say the bank is the saved one")

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.program, i32(7))
	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound is not the one that was saved")
}

// -- the bank is not there --------------------------------------------------------

@(test)
a_missing_bank_is_an_explicit_failure_that_keeps_the_sound_and_the_bank :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	// Something else is being played: not the factory bank, and not the one the
	// project asked for.
	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("Playing Meanwhile", {0, 1}), false, .Imported, nil)
	slots_before := after.slots

	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.session.restore, panel.Restore_State.Failed)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.Missing_Bank)
	// Nothing was substituted: not the factory bank, not slot 0 of anything.
	testing.expect(t, after.slots == slots_before, "a missing bank changed the bank that is playing")
	testing.expect_value(t, patch.slots_label(&after.slots), "Playing Meanwhile")
	testing.expect_value(t, after.program, i32(0))
	testing.expect_value(t, program_of_instance(after), synth.program_normalized(0))
	testing.expect(t, !panel.selection_known(&after.session.selection), "a failed restore claimed a selection")
	// And the sound is the saved sound: the values were never the question.
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound was not kept")
}

@(test)
a_failed_restore_is_saved_again_and_works_when_the_bank_is_back :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	away := synth.make_plugin()
	if away == nil {return}
	defer synth.release(away)
	testing.expect_value(t, load_session(away, saved), vst3.RESULT_OK)
	resaved := save_session(t, away)
	defer delete(resaved)

	back := synth.make_plugin()
	if back == nil {return}
	defer synth.release(back)
	panel.session_set_bank(&back.session, &back.slots, bank_document("Issue 13 Lost Bank", {0, 7}), true, .User, accept_write)
	testing.expect_value(t, load_session(back, resaved), vst3.RESULT_OK)

	testing.expect_value(t, back.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, back.program, i32(7))
	testing.expect(t, values_of_instance(before) == values_of_instance(back), "the sound changed on the way")
}

@(test)
a_slot_that_is_no_longer_filled_is_an_invalid_program_and_keeps_the_sound :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Issue 13 Thin Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	// The bank is there, and slot 7 of it is not.
	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("Issue 13 Thin Bank", {0, 1}), true, .User, accept_write)
	slots_before := after.slots

	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect(t, after.slots == slots_before, "the bank changed")
	testing.expect_value(t, after.program, i32(0))
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound was not kept")
}

// -- what a host or a different build may send -------------------------------------

// A trailer that cannot be read costs the project its label and nothing else:
// the sound is loaded, and the load is not refused.
@(test)
a_trailer_that_cannot_be_read_does_not_refuse_the_state :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)
	values := synth.STATE_SIZE

	newer := slice.clone(saved)
	defer delete(newer)
	newer[values + 4] = 2

	oversize := slice.clone(saved)
	defer delete(oversize)
	oversize[values + 11] = 0x80

	cases := [?]struct {
		name:  string,
		bytes: []u8,
		error: panel.Restore_Error,
	} {
		{"a trailer from a newer build", newer, .State_Version_Unsupported},
		{"a trailer that is cut short", saved[:values + 40], .Host_State_Rejected},
		{"a trailer cut inside its header", saved[:values + 6], .Host_State_Rejected},
		{"a trailer claiming a size past the cap", oversize, .Host_State_Rejected},
	}
	for c in cases {
		after := synth.make_plugin()
		if after == nil {return}
		defer synth.release(after)
		slots_before := after.slots

		testing.expectf(t, load_session(after, c.bytes) == vst3.RESULT_OK, "%s: the state was refused", c.name)
		testing.expectf(t, after.session.restore_error == c.error, "%s: error is %v, not %v", c.name, after.session.restore_error, c.error)
		testing.expectf(t, after.slots == slots_before, "%s: the bank changed", c.name)
		testing.expectf(t, values_of_instance(before) == values_of_instance(after), "%s: the sound was not loaded", c.name)
	}
}

// States from before any of this, byte for byte as they were: nothing asked for,
// nothing claimed, nothing reset.
@(test)
a_state_from_before_the_trailer_loads_as_it_always_did :: proc(t: ^testing.T) {
	with_tag_start := make([dynamic]u8)
	defer delete(with_tag_start)
	append(&with_tag_start, ..GOLDEN_STATE[:])
	append(&with_tag_start, 'Q', 'S', 'E')

	after_values := make([dynamic]u8)
	defer delete(after_values)
	append(&after_values, ..GOLDEN_STATE[:])
	append(&after_values, 1, 2, 3, 4, 5, 6, 7, 8, 9)

	// A version 1 state is never read past its values, whatever follows them:
	// the trailer came after version 1 stopped being written.
	legacy_with_a_trailer := make([dynamic]u8)
	defer delete(legacy_with_a_trailer)
	append(&legacy_with_a_trailer, ..LEGACY_STATE[:])
	append(&legacy_with_a_trailer, ..panel_trailer_bytes())

	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"the golden state", GOLDEN_STATE[:]},
		{"the golden state with bytes after it", after_values[:]},
		{"the golden state with bytes that start like the tag", with_tag_start[:]},
		{"a version 1 state", LEGACY_STATE[:]},
		{"a version 1 state with a trailer after it", legacy_with_a_trailer[:]},
	}
	for c in cases {
		p := synth.make_plugin()
		if p == nil {return}
		defer synth.release(p)
		// An instance that thought it knew what it was on.
		panel.session_select_slot(&p.session, 6)
		p.program = 6
		slots_before := p.slots

		testing.expectf(t, load_session(p, c.bytes) == vst3.RESULT_OK, "%s: refused", c.name)

		values := values_of_instance(p)
		for i in 0 ..< len(GOLDEN_VALUES) {
			testing.expectf(t, values[i] == GOLDEN_VALUES[i], "%s: parameter %d", c.name, i)
		}
		testing.expectf(t, p.session.restore == .Not_Requested, "%s: a restore was asked for", c.name)
		testing.expectf(t, p.slots == slots_before, "%s: the bank changed", c.name)
		testing.expectf(t, !panel.selection_known(&p.session.selection), "%s: the instance still claims to know where the sound came from", c.name)
		// Neither Factory nor slot 0: the program is whatever it was.
		testing.expectf(t, p.program == 6, "%s: the program moved to %d", c.name, p.program)
	}
}

@(test)
a_state_with_nothing_selected_is_the_bytes_it_always_was :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	saved := save_session(t, p)
	defer delete(saved)
	testing.expect_value(t, len(saved), len(GOLDEN_STATE))
}

// With a selection, everything up to the last value is what it always was, so a
// build from before reads the project and gets the sound.
@(test)
a_state_with_a_selection_starts_with_the_values_as_they_always_were :: proc(t: ^testing.T) {
	p := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if p == nil {return}
	defer synth.release(p)

	saved := save_session(t, p)
	defer delete(saved)
	testing.expect(t, len(saved) > synth.STATE_SIZE, "the selection was not saved")

	// The same sound on an instance that was never told what it is saves only
	// the values.
	bare := synth.make_plugin()
	if bare == nil {return}
	defer synth.release(bare)
	sound := values_of_instance(p)
	synth.stage_values(bare, sound[:])
	plain := save_session(t, bare)
	defer delete(plain)
	testing.expect_value(t, len(plain), synth.STATE_SIZE)
	for i in 0 ..< synth.STATE_SIZE {
		testing.expectf(t, saved[i] == plain[i], "byte %d is 0x%02X, a state without a selection has 0x%02X", i, saved[i], plain[i])
	}
}

// A build that has more parameters writes them all, and then the trailer: the
// extra ones are skipped, never read as one.
@(test)
a_trailer_after_values_this_build_does_not_have_is_still_found :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	blob := make([dynamic]u8)
	defer delete(blob)
	append(&blob, ..saved[:synth.STATE_SIZE])
	declared := u32(synth.PARAM_COUNT + 3)
	blob[8] = u8(declared)
	append(&blob, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0)
	append(&blob, ..saved[synth.STATE_SIZE:])

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	testing.expect_value(t, load_session(after, blob[:]), vst3.RESULT_OK)

	testing.expect_value(t, after.program, i32(42))
	testing.expect_value(t, patch.slots_label(&after.slots), "Alfmeister Bank")
}

// -- a program change after a restore ---------------------------------------------

// The program change a host sends, by either route, selects the exact slot of
// the bank that came back.
@(test)
a_program_change_after_a_restore_selects_the_exact_slot_of_the_restored_bank :: proc(t: ^testing.T) {
	for on_the_controller in ([]bool{false, true}) {
		before := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
		if before == nil {return}
		defer synth.release(before)
		saved := save_session(t, before)
		defer delete(saved)

		after := make_active_plugin(t)
		if after == nil {return}
		defer synth.release(after)
		testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
		wanted, filled := patch.slots_patch(&after.slots, 7)
		testing.expect(t, filled, "slot 7 of the restored bank is empty")

		if on_the_controller {
			synth.controller_set_param_normalized(controller_of(after), synth.PROGRAM_PARAM_ID, synth.program_normalized(7))
			process_block(t, after)
		} else {
			point := Parameter_Point {
				id    = synth.PROGRAM_PARAM_ID,
				value = synth.program_normalized(7),
			}
			process_block(t, after, &point)
		}

		view := panel.selection_view(&after.session.selection, &after.slots)
		testing.expectf(t, view.slot == 7 && view.label == "Alfmeister Bank" && view.name == "Alfmeister Bank 7", "controller %v: %v", on_the_controller, view)
		testing.expect_value(t, after.program, i32(7))
		testing.expect_value(t, after.values, wanted)
	}
}

panel_trailer_bytes :: proc() -> []u8 {
	trailer: panel.Trailer
	trailer.origin = .User
	trailer.has_slot = true
	trailer.slot = 3
	panel.text_set(&trailer.label, "Anything")
	panel.text_set(&trailer.name, "Anything 3")
	return panel.trailer_encode(&trailer, context.temp_allocator)
}
