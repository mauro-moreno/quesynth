#+build windows, linux
package clap_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import clap "../../src/clap"
import panel "../../hosts/panel"
import patch "../../src/patch"
import synth "../../hosts/clap"

// A slot with nothing in it is a slot, and the page lets a person select one:
// the arrows step onto it, a click lands on it, clearing the selected slot
// leaves the selection there, and the strip reads "071:Init". An instance saved
// then has to come back on it with its bank. Restoring refused the slot before
// it adopted the bank the state carried, so the bank was thrown away with it,
// the instance fell back to its own, and the next save had no bank to carry.
//
// The selection goes in through the panel's own `select` message and the
// instance is saved and loaded as a host does it, so what is checked is what
// the page and the host do and not what the session is told directly.

// The message the page sends when it has selected a slot.
select_in_the_page :: proc(origin: string, bank: string, slot: int, name: string) -> string {
	return fmt.tprintf(`{{"type":"select","v":1,"origin":"%s","bank":"%s","slot":%d,"name":"%s"}}`, origin, bank, slot, name)
}

// A sound in the instance that is not any slot's, as work in progress is.
play_edited_sound :: proc(s: ^synth.Synth) {
	values, _ := patch.slots_patch(&s.slots, 0)
	CUTOFF :: 19
	values[CUTOFF] += 1
	synth.stage_values(s, values)
}

// The compiled-in bank and nothing else, whatever this machine has saved.
play_the_built_in_bank :: proc(s: ^synth.Synth) {
	patch.factory_prepare()
	patch.slots_load_factory(&s.slots)
	panel.session_init(&s.session, .Built_In)
}

@(test)
test_an_empty_slot_of_an_imported_bank_survives_a_new_instance :: proc(t: ^testing.T) {
	before := make_plugin(t)
	if before == nil {return}
	defer before.destroy(before)
	a := synth.synth_of(before)
	// A bank somebody opened from a file: played, and kept nowhere else.
	imported := bank_document("Alfmeister Bank", {0, 7, 42})
	testing.expect_value(t, panel.session_set_bank(&a.session, &a.slots, imported, false, .Imported, nil), panel.Bank_Result.Adopted)
	host := synth.gui_host(a)
	panel.handle_message(&host, select_in_the_page("imported", "Alfmeister Bank", 71, "Init"))
	play_edited_sound(a)
	testing.expect(t, !a.slots.filled[71], "slot 71 is not empty, so this proves nothing")
	testing.expect_value(t, a.program, 71)
	saved := save_state(t, before)
	defer delete(saved)

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	testing.expect(t, patch.slots_label(&b.slots) != "Alfmeister Bank", "the new instance already has the bank, so this proves nothing")
	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, patch.slots_label(&b.slots), "Alfmeister Bank")
	testing.expect(t, b.slots == a.slots, "the imported bank that came back is not the one that went")
	testing.expect_value(t, b.program, 71)
	view := panel.selection_view(&b.session.selection, &b.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 71)
	testing.expect_value(t, view.name, "Init")
	testing.expect_value(t, b.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound is not the one that was saved")

	// The next save still carries the bank, and a third instance gets it: what
	// came back the first time is not lost the second.
	again := save_state(t, after)
	defer delete(again)
	trailer, status := panel.trailer_decode(again[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, trailer.embedded && trailer.slot_empty && trailer.slot == 71, "the next save lost the bank or the empty slot")
	third := make_plugin(t)
	if third == nil {return}
	defer third.destroy(third)
	testing.expect(t, load_saved(third, again), "the second state was refused")
	c := synth.synth_of(third)
	testing.expect_value(t, patch.slots_label(&c.slots), "Alfmeister Bank")
	testing.expect_value(t, c.program, 71)
	testing.expect_value(t, c.session.restore, panel.Restore_State.Restored)

	// And the editor that opens on it is told where it is, not that something
	// failed: the strip reads the empty slot's own name.
	editor := synth.gui_host(b)
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
test_an_empty_slot_of_the_users_saved_bank_comes_back_by_name :: proc(t: ^testing.T) {
	before := make_plugin(t)
	if before == nil {return}
	defer before.destroy(before)
	a := synth.synth_of(before)
	testing.expect_value(t, panel.session_set_bank(&a.session, &a.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write), panel.Bank_Result.Saved)
	host := synth.gui_host(a)
	panel.handle_message(&host, select_in_the_page("user", "My Saved Bank", 3, "Init"))
	play_edited_sound(a)
	testing.expect_value(t, a.program, 3)
	saved := save_state(t, before)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded && trailer.bank_saved && trailer.slot_empty, "the saved bank is not named by its empty slot")

	// The machine the project was saved on: it has that bank.
	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, b.program, 3)
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound is not the one that was saved")
}

// One step back from the first preset is the last slot, which the compiled-in
// bank has nothing in. It is not a failed restore and it is not something to
// retry: the strip says "127:Init" and nothing is wrong.
@(test)
test_an_empty_slot_of_the_built_in_bank_comes_back_without_a_banner :: proc(t: ^testing.T) {
	before := make_plugin(t)
	if before == nil {return}
	defer before.destroy(before)
	a := synth.synth_of(before)
	play_the_built_in_bank(a)
	host := synth.gui_host(a)
	label := patch.slots_label(&a.slots)
	panel.handle_message(&host, select_in_the_page("factory", label, 127, "Init"))
	play_edited_sound(a)
	testing.expect(t, !a.slots.filled[127], "slot 127 of the built-in bank is not empty, so this proves nothing")
	testing.expect_value(t, a.program, 127)
	saved := save_state(t, before)
	defer delete(saved)

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	play_the_built_in_bank(b)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")

	testing.expect_value(t, b.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.None)
	testing.expect_value(t, b.program, 127)
	testing.expect_value(t, b.session.bank_source, panel.Bank_Source.Built_In)
	testing.expect(t, all_values(t, before) == all_values(t, after), "the sound is not the one that was saved")
	editor := synth.gui_host(b)
	for reply in panel.handle_message(&editor, `{"type":"sync"}`) {
		testing.expectf(t, !strings.contains(reply, `"failed"`), "the editor is told of a failure: %s", reply)
	}
}

// What InvalidProgram is for, from the host's side: the state named a slot with
// a sound in it, and the bank has nothing there now. An empty slot that was
// selected is no excuse for it, and neither is a number that is not a slot.
@(test)
test_a_slot_that_was_filled_when_saved_and_is_empty_now_is_still_an_invalid_program :: proc(t: ^testing.T) {
	before := make_plugin(t)
	if before == nil {return}
	defer before.destroy(before)
	a := synth.synth_of(before)
	panel.session_set_bank(&a.session, &a.slots, bank_document("Thin Bank", {0, 7}), true, .User, accept_write)
	host := synth.gui_host(a)
	panel.handle_message(&host, select_in_the_page("user", "Thin Bank", 7, "Thin Bank 7"))
	saved := save_state(t, before)
	defer delete(saved)
	trailer, _ := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect(t, !trailer.slot_empty, "a slot with a sound in it was saved as empty")

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("Thin Bank", {0, 1}), true, .User, accept_write)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect_value(t, b.program, 0)
}

@(test)
test_a_number_that_is_not_a_slot_is_an_invalid_program_even_when_saved_as_empty :: proc(t: ^testing.T) {
	before := make_plugin(t)
	if before == nil {return}
	defer before.destroy(before)
	a := synth.synth_of(before)
	panel.session_set_bank(&a.session, &a.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	saved := save_state(t, before)
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

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("My Saved Bank", {0, 7}), true, .User, accept_write)
	testing.expect(t, load_saved(after, state), "the state was refused")
	testing.expect_value(t, b.session.restore_error, panel.Restore_Error.Invalid_Program)
	testing.expect_value(t, b.program, 0)
}
