#+build windows, linux
package vst3_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// A slot with nothing in it is a slot, and the page lets a person select one:
// the arrows step onto it, a click lands on it, clearing the selected slot
// leaves the selection there, and the strip reads "071:Init". An instance saved
// then has to come back on it with its bank. Restoring refused the slot before
// it adopted the bank the state carried, so the bank was thrown away with it,
// the instance fell back to its own, and the next save had no bank to carry.
//
// The selection goes in through the panel's own `select` message, on the
// editor's callbacks, and the instance is saved and loaded through IComponent as
// a host does it: what is checked is what the page and the host do and not what
// the session is told directly.

// The message the page sends when it has selected a slot.
select_in_the_page :: proc(origin: string, bank: string, slot: int, name: string) -> string {
	return fmt.tprintf(`{{"type":"select","v":1,"origin":"%s","bank":"%s","slot":%d,"name":"%s"}}`, origin, bank, slot, name)
}

// A sound in the instance that is not any slot's, as work in progress is.
play_edited_sound :: proc(p: ^synth.Plugin) {
	values, _ := patch.slots_patch(&p.slots, 0)
	CUTOFF :: 19
	values[CUTOFF] += 1
	synth.stage_values(p, values[:])
}

// The compiled-in bank and nothing else, whatever this machine has saved.
play_the_built_in_bank :: proc(p: ^synth.Plugin) {
	patch.factory_prepare()
	patch.slots_load_factory(&p.slots)
	panel.session_init(&p.session, .Built_In)
}

@(test)
an_empty_slot_of_an_imported_bank_survives_a_new_instance :: proc(t: ^testing.T) {
	before := synth.make_plugin()
	if before == nil {return}
	defer synth.release(before)
	// A bank somebody opened from a file: played, and kept nowhere else.
	imported := bank_document("Alfmeister Bank", {0, 7, 42})
	testing.expect_value(t, panel.session_set_bank(&before.session, &before.slots, imported, false, .Imported, nil), panel.Bank_Result.Adopted)
	ed := synth.Editor {
		plugin = before,
	}
	host := synth.editor_host(&ed)
	panel.handle_message(&host, select_in_the_page("imported", "Alfmeister Bank", 71, "Init"))
	play_edited_sound(before)
	testing.expect(t, !before.slots.filled[71], "slot 71 is not empty, so this proves nothing")
	testing.expect_value(t, before.program, i32(71))
	saved := save_session(t, before)
	defer delete(saved)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	testing.expect(t, patch.slots_label(&after.slots) != "Alfmeister Bank", "the new instance already has the bank, so this proves nothing")
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, patch.slots_label(&after.slots), "Alfmeister Bank")
	testing.expect(t, after.slots == before.slots, "the imported bank that came back is not the one that went")
	testing.expect_value(t, after.program, i32(71))
	// What the host reads for the program parameter is the exact slot.
	testing.expect_value(t, program_of_instance(after), synth.program_normalized(71))
	view := panel.selection_view(&after.session.selection, &after.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 71)
	testing.expect_value(t, view.name, "Init")
	testing.expect_value(t, after.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound is not the one that was saved")

	// The next save still carries the bank, and a third instance gets it: what
	// came back the first time is not lost the second.
	again := save_session(t, after)
	defer delete(again)
	trailer, status := panel.trailer_decode(again[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, trailer.embedded && trailer.slot_empty && trailer.slot == 71, "the next save lost the bank or the empty slot")
	third := synth.make_plugin()
	if third == nil {return}
	defer synth.release(third)
	testing.expect_value(t, load_session(third, again), vst3.RESULT_OK)
	testing.expect_value(t, patch.slots_label(&third.slots), "Alfmeister Bank")
	testing.expect_value(t, third.program, i32(71))
	testing.expect_value(t, third.session.restore, panel.Restore_State.Restored)

	// And the editor that opens on it is told where it is, not that something
	// failed: the strip reads the empty slot's own name.
	opened := synth.Editor {
		plugin = after,
	}
	editor := synth.editor_host(&opened)
	replies := panel.handle_message(&editor, `{"type":"sync"}`)
	testing.expect_value(t, len(replies), 4)
	if len(replies) == 4 {
		testing.expect_value(
			t,
			replies[2],
			`{"type":"patch","name":"Init","index":71,"bank":"Alfmeister Bank","v":1,"origin":"imported"}`,
		)
		testing.expect_value(
			t,
			replies[3],
			`{"type":"restore","v":1,"state":"restored","origin":"imported","bank":"Alfmeister Bank","slot":71,"name":"Init"}`,
		)
	}
}

@(test)
an_empty_slot_of_the_users_saved_bank_comes_back_by_name :: proc(t: ^testing.T) {
	before := synth.make_plugin()
	if before == nil {return}
	defer synth.release(before)
	testing.expect_value(t, panel.session_set_bank(&before.session, &before.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write), panel.Bank_Result.Saved)
	ed := synth.Editor {
		plugin = before,
	}
	host := synth.editor_host(&ed)
	panel.handle_message(&host, select_in_the_page("user", "My Saved Bank", 3, "Init"))
	play_edited_sound(before)
	testing.expect_value(t, before.program, i32(3))
	saved := save_session(t, before)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded && trailer.bank_saved && trailer.slot_empty, "the saved bank is not named by its empty slot")

	// The machine the project was saved on: it has that bank.
	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, after.program, i32(3))
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound is not the one that was saved")
}

// One step back from the first preset is the last slot, which the compiled-in
// bank has nothing in. It is not a failed restore and it is not something to
// retry: the strip says "127:Init" and nothing is wrong.
@(test)
an_empty_slot_of_the_built_in_bank_comes_back_without_a_banner :: proc(t: ^testing.T) {
	before := synth.make_plugin()
	if before == nil {return}
	defer synth.release(before)
	play_the_built_in_bank(before)
	ed := synth.Editor {
		plugin = before,
	}
	host := synth.editor_host(&ed)
	label := patch.slots_label(&before.slots)
	panel.handle_message(&host, select_in_the_page("factory", label, 127, "Init"))
	play_edited_sound(before)
	testing.expect(t, !before.slots.filled[127], "slot 127 of the built-in bank is not empty, so this proves nothing")
	testing.expect_value(t, before.program, i32(127))
	saved := save_session(t, before)
	defer delete(saved)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	play_the_built_in_bank(after)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)

	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, after.program, i32(127))
	testing.expect_value(t, after.session.bank_source, panel.Bank_Source.Built_In)
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "the sound is not the one that was saved")
	opened := synth.Editor {
		plugin = after,
	}
	editor := synth.editor_host(&opened)
	for reply in panel.handle_message(&editor, `{"type":"sync"}`) {
		testing.expectf(t, !strings.contains(reply, `"failed"`), "the editor is told of a failure: %s", reply)
	}
}

// What InvalidProgram is for, from the host's side: the state named a slot with
// a sound in it, and the bank has nothing there now. An empty slot that was
// selected is no excuse for it, and neither is a number that is not a slot.
@(test)
a_slot_that_was_filled_when_saved_and_is_empty_now_is_still_an_invalid_program :: proc(t: ^testing.T) {
	before := synth.make_plugin()
	if before == nil {return}
	defer synth.release(before)
	panel.session_set_bank(&before.session, &before.slots, bank_document("Thin Bank", {0, 7}), true, .User, accept_write)
	ed := synth.Editor {
		plugin = before,
	}
	host := synth.editor_host(&ed)
	panel.handle_message(&host, select_in_the_page("user", "Thin Bank", 7, "Thin Bank 7"))
	saved := save_session(t, before)
	defer delete(saved)
	trailer, _ := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect(t, !trailer.slot_empty, "a slot with a sound in it was saved as empty")

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("Thin Bank", {0, 1}), true, .User, accept_write)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect_value(t, after.program, i32(0))
}

@(test)
a_number_that_is_not_a_slot_is_an_invalid_program_even_when_saved_as_empty :: proc(t: ^testing.T) {
	before := synth.make_plugin()
	if before == nil {return}
	defer synth.release(before)
	panel.session_set_bank(&before.session, &before.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	saved := save_session(t, before)
	defer delete(saved)

	// A state no build writes: slot 128 of a bank, marked empty.
	forged: panel.Trailer
	forged.origin = .User
	forged.has_slot = true
	forged.slot = patch.FACTORY_SLOTS
	forged.slot_empty = true
	forged.bank_saved = true
	panel.text_set(&forged.label, "My Saved Bank")
	panel.text_set(&forged.name, "Init")
	tail := panel.trailer_encode(&forged)
	defer delete(tail)
	state := slice.concatenate([][]u8{saved[:synth.STATE_SIZE], tail})
	defer delete(state)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	panel.session_set_bank(&after.session, &after.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect_value(t, load_session(after, state), vst3.RESULT_OK)
	testing.expect_value(t, after.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect_value(t, after.program, i32(0))
}
