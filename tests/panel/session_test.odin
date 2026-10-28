package panel_tests

import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// What an instance remembers about which preset it is playing, and putting it
// back from a saved state.
//
// Everything here is on the instance alone -- a bank, a session, bytes -- so it
// runs on every platform with no plugin, no host and no web view. What each
// format adds is on top of this and is checked in tests/clap and tests/vst3.

// -- restoring: one table, five outcomes --------------------------------------

Restore_Case :: struct {
	name:      string,
	// What the instance is playing when the state arrives.
	playing:   string,
	trailer:   []u8,
	requested: bool,
	error:     panel.Restore_Error,
	// For a restore that worked: the slot, or -1 for one with none.
	program:   int,
}

@(test)
a_state_is_restored_or_refused_for_a_stated_reason :: proc(t: ^testing.T) {
	embedded_ok := bank_text("Alfmeister Bank", {0, 2, 42})
	embedded_without_the_slot := bank_text("Alfmeister Bank", {0, 2})
	embedded_mislabelled := bank_text("Somebody Else", {0, 2, 42})

	cases := [?]Restore_Case {
		// Before there was a trailer, and anything that is not one: nothing was
		// asked for, so nothing can have failed.
		{name = "no trailer", playing = "Playing", trailer = nil, program = -1},
		{name = "bytes that are not a trailer", playing = "Playing", trailer = {9, 9, 9, 9, 9, 9}, program = -1},

		// The playing bank is the bank asked for.
		{name = "a slot of the playing bank", playing = "Playing", trailer = saved_trailer(.User, 7, "Playing", "Playing 7"), requested = true, program = 7},
		{name = "slot 0 asked for by name", playing = "Playing", trailer = saved_trailer(.User, 0, "Playing", "Playing 0"), requested = true, program = 0},
		{name = "the last slot, which is empty here", playing = "Playing", trailer = saved_trailer(.User, 127, "Playing", "Last"), requested = true, error = .Invalid_Program, program = -1},

		// Not the playing bank: never the factory bank in its place.
		{name = "a bank this instance is not playing", playing = "Playing", trailer = saved_trailer(.Imported, 7, "Elsewhere", "Elsewhere 7"), requested = true, error = .Missing_Bank, program = -1},
		{name = "the bank name differs only by case", playing = "Playing", trailer = saved_trailer(.User, 7, "playing", "x"), requested = true, error = .Missing_Bank, program = -1},

		// The bank is right and the slot is not.
		{name = "an empty slot", playing = "Playing", trailer = saved_trailer(.User, 5, "Playing", "Playing 5"), requested = true, error = .Invalid_Program, program = -1},
		{name = "a slot beyond the bank", playing = "Playing", trailer = saved_trailer(.User, 4000, "Playing", "Far"), requested = true, error = .Invalid_Program, program = -1},

		// A sound with no slot behind it names no bank to look for.
		{name = "a live sound", playing = "Playing", trailer = saved_trailer(.Session, -1, "", "Untitled"), requested = true, program = -1},
		{name = "a file", playing = "Playing", trailer = saved_trailer(.File, -1, "Elsewhere", "From A File"), requested = true, program = -1},

		// A bank carried in the state.
		{name = "an embedded bank that holds the slot", playing = "Playing", trailer = saved_trailer(.Imported, 42, "Alfmeister Bank", "Alfmeister Bank 42", embedded_ok), requested = true, program = 42},
		{name = "an embedded bank without the slot", playing = "Playing", trailer = saved_trailer(.Imported, 42, "Alfmeister Bank", "Alfmeister Bank 42", embedded_without_the_slot), requested = true, error = .Invalid_Program, program = -1},
		{name = "an embedded bank that is not a bank", playing = "Playing", trailer = saved_trailer(.Imported, 2, "Alfmeister Bank", "x", "{ this is not a bank"), requested = true, error = .Host_State_Rejected, program = -1},
		{name = "an embedded bank under another name", playing = "Playing", trailer = saved_trailer(.Imported, 42, "Alfmeister Bank", "x", embedded_mislabelled), requested = true, error = .Host_State_Rejected, program = -1},

		// Not understood.
		{name = "a trailer from a newer build", playing = "Playing", trailer = newer_trailer(), requested = true, error = .State_Version_Unsupported, program = -1},
		{name = "a truncated trailer", playing = "Playing", trailer = saved_trailer(.User, 7, "Playing", "Playing 7")[:20], requested = true, error = .Host_State_Rejected, program = -1},
		{name = "an oversize trailer", playing = "Playing", trailer = oversize_trailer(), requested = true, error = .Host_State_Rejected, program = -1},
	}

	for c in cases {
		inst := new_instance(t, c.playing, {0, 1, 7}, .Saved)
		defer free(inst)
		// Something already selected, so a restore that touches the selection
		// cannot be mistaken for one that left a blank one blank.
		panel.session_select_slot(&inst.session, 1)
		before := inst.slots
		selection_before := inst.session.selection
		source_before := inst.session.bank_source

		result := panel.session_restore(&inst.session, &inst.slots, c.trailer)

		testing.expectf(t, result.requested == c.requested, "%s: requested is %v", c.name, result.requested)
		testing.expectf(t, result.error == c.error, "%s: error is %v, not %v", c.name, result.error, c.error)
		if c.error != .None {
			testing.expectf(t, !result.restored, "%s: a failed restore says it restored", c.name)
			testing.expectf(t, inst.session.restore == .Failed, "%s: the session does not say it failed", c.name)
			// The point of all of it: a restore that fails is not allowed to
			// move anything the instance is playing.
			testing.expectf(t, inst.slots == before, "%s: the bank changed under a failed restore", c.name)
			testing.expectf(t, inst.session.selection == selection_before, "%s: the selection changed under a failed restore", c.name)
			testing.expectf(t, inst.session.bank_source == source_before, "%s: the bank source changed under a failed restore", c.name)
			testing.expectf(t, !result.has_program, "%s: a failed restore moved the program", c.name)
			continue
		}
		if !c.requested {
			testing.expectf(t, inst.session.restore == .Not_Requested, "%s: a restore was recorded for nothing", c.name)
			continue
		}
		testing.expectf(t, result.restored, "%s: not restored", c.name)
		testing.expectf(t, inst.session.restore == .Restored, "%s: the session does not say it restored", c.name)
		testing.expectf(t, !inst.session.has_pending, "%s: a restored session is still holding something back", c.name)
		if c.program >= 0 {
			testing.expectf(t, result.has_program && result.program == c.program, "%s: program is %d, not %d", c.name, result.program, c.program)
		} else {
			testing.expectf(t, !result.has_program, "%s: a restore with no slot gave a program", c.name)
		}
	}
}

newer_trailer :: proc() -> []u8 {
	bytes := saved_trailer(.User, 7, "Playing", "Playing 7")
	bytes[4] = 2
	return bytes
}

oversize_trailer :: proc() -> []u8 {
	bytes := saved_trailer(.User, 7, "Playing", "Playing 7")
	bytes[10] = 0x80
	return bytes
}

@(test)
a_legacy_state_leaves_an_instance_not_knowing_what_it_plays :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_select_slot(&inst.session, 7)

	panel.session_restore(&inst.session, &inst.slots, nil)

	// Not slot 0 and not slot 7: the values just loaded are somebody else's, so
	// the instance does not claim to know where they came from.
	testing.expect(t, !panel.selection_known(&inst.session.selection), "an instance claims a selection for a state that had none")
}

// -- an embedded bank is what survives a new instance -------------------------

@(test)
an_embedded_bank_becomes_the_playing_bank_and_is_not_the_saved_one :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	bank := bank_text("Alfmeister Bank", {0, 2, 42})

	result := panel.session_restore(&inst.session, &inst.slots, saved_trailer(.Imported, 42, "Alfmeister Bank", "Alfmeister Bank 42", bank))

	testing.expect(t, result.restored, "the restore failed")
	testing.expect_value(t, patch.slots_label(&inst.slots), "Alfmeister Bank")
	testing.expect_value(t, patch.slots_name(&inst.slots, 42), "Alfmeister Bank 42")
	// Adopted, so a later save carries it again; and not Saved, which is the
	// per-user file and is never written by a restore.
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect_value(t, inst.session.bank_origin, panel.Origin.Imported)

	view := panel.selection_view(&inst.session.selection, &inst.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 42)
	testing.expect_value(t, view.label, "Alfmeister Bank")
	testing.expect_value(t, view.name, "Alfmeister Bank 42")
}

// The whole of issue #13 on the instance alone: an imported bank, a program,
// the state saved, a new instance, the state loaded.
@(test)
an_imported_bank_and_its_program_survive_a_new_instance :: proc(t: ^testing.T) {
	before := new_instance(t, "Factory", {0, 1, 2}, .Built_In)
	defer free(before)

	imported := bank_text("Alfmeister Bank", {0, 2, 42})
	result := panel.session_set_bank(&before.session, &before.slots, imported, false, .Imported, nil)
	testing.expect_value(t, result, panel.Bank_Result.Adopted)
	selected := panel.session_select(
		&before.session,
		&before.slots,
		panel.Selection{origin = .Imported, has_slot = true, slot = 42, label = named("Alfmeister Bank"), name = named("Alfmeister Bank 42")},
	)
	testing.expect(t, selected, "the selection was refused")

	saved := panel.session_trailer(&before.session, &before.slots)
	defer delete(saved)
	testing.expect(t, len(saved) > 0, "nothing was saved about an imported bank")

	// The new instance comes up the way every one does: the factory bank,
	// program 0.
	after := new_instance(t, "Factory", {0, 1, 2}, .Built_In)
	defer free(after)
	restored := panel.session_restore(&after.session, &after.slots, saved)

	testing.expect(t, restored.restored, "the restore failed")
	testing.expect(t, restored.has_program && restored.program == 42, "the program is not 42")
	testing.expect(t, after.slots == before.slots, "the bank that came back is not the bank that went")
	view := panel.selection_view(&after.session.selection, &after.slots)
	testing.expect_value(t, view.label, "Alfmeister Bank")
	testing.expect_value(t, view.slot, 42)
	testing.expect_value(t, view.name, "Alfmeister Bank 42")
	testing.expect_value(t, view.origin, panel.Origin.Imported)
}

// -- a refusal is remembered, and the next save keeps it ----------------------

@(test)
a_failed_restore_is_written_back_by_the_next_save_and_can_succeed_later :: proc(t: ^testing.T) {
	// A project saved in an instance that had a user bank, opened where that
	// bank is not there.
	lost := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(lost)
	trailer := saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true)
	result := panel.session_restore(&lost.session, &lost.slots, trailer)
	testing.expect_value(t, result.error, panel.Restore_Error.Missing_Bank)

	// The project is saved again while it is still missing.
	resaved := panel.session_trailer(&lost.session, &lost.slots)
	defer delete(resaved)
	again, status := panel.trailer_decode(resaved)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, again.origin, panel.Origin.User)
	testing.expect_value(t, again.slot, 7)
	testing.expect_value(t, panel.text_get(&again.label), "My Bank")
	testing.expect_value(t, panel.text_get(&again.name), "Glass Pad")
	// Not the factory bank carried in its place, and not claimed to be there.
	testing.expect(t, !again.embedded, "the instance wrote a bank it was not asked for")

	// And it works where the bank is.
	found := new_instance(t, "My Bank", {0, 1, 7}, .Saved)
	defer free(found)
	back := panel.session_restore(&found.session, &found.slots, resaved)
	testing.expect(t, back.restored, "the saved identity did not restore where its bank is")
	testing.expect_value(t, back.program, 7)
}

// What is playing is not what a failed restore was asking for, and writing the
// one under the other's name would put the missing bank's slot number on an
// imported bank's sound.
@(test)
a_failed_restore_does_not_put_the_playing_bank_under_the_missing_ones_name :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Imported Meanwhile", {0, 7}), false, .Imported, nil)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))

	saved := panel.session_trailer(&inst.session, &inst.slots)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, panel.text_get(&trailer.label), "My Bank")
	testing.expect(t, !trailer.embedded, "the imported bank was written as if it were My Bank")
}

@(test)
a_selection_replaces_a_failed_restore_and_a_discard_forgets_it :: proc(t: ^testing.T) {
	for how in ([]string{"select", "program change", "discard"}) {
		inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
		defer free(inst)
		panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "Gone", "Lost"))
		testing.expect(t, inst.session.has_pending, "nothing was kept")

		switch how {
		case "select":
			panel.session_select(&inst.session, &inst.slots, panel.Selection{origin = .User, has_slot = true, slot = 1, label = named("Playing")})
		case "program change":
			panel.session_select_slot(&inst.session, 1)
		case "discard":
			panel.session_discard(&inst.session)
		}

		testing.expectf(t, !inst.session.has_pending, "after a %s the failure is still pending", how)
		testing.expectf(t, inst.session.restore == .Not_Requested, "after a %s the restore still stands as %v", how, inst.session.restore)
	}
}

// The preset is called what its bank is called, as the panel was told when the
// bank was handed over: a state written while the bank was the factory one, read
// where the same bank is the user's saved copy.
@(test)
a_restored_slot_has_the_origin_of_the_bank_it_is_in :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 7}, .Saved)
	defer free(inst)

	result := panel.session_restore(&inst.session, &inst.slots, saved_trailer(.Factory, 7, "Factory", "Factory 7"))

	testing.expect(t, result.restored, "not restored")
	testing.expect_value(t, inst.session.selection.origin, panel.Origin.User)
}

// Whatever a project calls the bank it names, and whatever it says that bank
// is, a bank by name that is not the one being played is missing. Factory is
// a label like any other: a user's own bank may have it, and a project that
// names the compiled-in one is still not asking for the user's saved bank to
// be put aside. Taking it for the compiled-in bank and playing that instead
// handed the panel Factory as the bank the host keeps; see the end of
// bank_test.odin for what its next write did to the user's file.
@(test)
a_bank_by_name_that_is_not_the_one_played_is_missing_whatever_it_is_called :: proc(t: ^testing.T) {
	patch.factory_prepare()
	cases := [?]struct {
		name:    string,
		trailer: []u8,
	} {
		{"the compiled-in bank", saved_trailer(.Factory, 7, "Factory", patch.factory_name(7))},
		{"a user's bank called Factory", saved_trailer(.User, 7, "Factory", "Brass", bank_saved = true)},
		{"an imported bank called Factory", saved_trailer(.Imported, 7, "Factory", "Brass")},
		{"the factory origin under another label", saved_trailer(.Factory, 7, "Quesynth Factory", "Brass")},
		{"the factory origin and no label", saved_trailer(.Factory, 7, "", "Brass")},
	}
	for c in cases {
		inst := new_instance(t, "My Bank", {0, 1, 7}, .Saved)
		defer free(inst)
		before := inst.slots

		result := panel.session_restore(&inst.session, &inst.slots, c.trailer)

		testing.expectf(t, result.error == .Missing_Bank, "%s: error is %v", c.name, result.error)
		testing.expectf(t, inst.slots == before, "%s: the playing bank changed", c.name)
		testing.expectf(t, inst.session.bank_source == .Saved, "%s: the bank source changed", c.name)
		testing.expectf(t, inst.session.bank_origin == .User, "%s: the bank origin changed", c.name)

		// Nor does trying again find it, with the user's bank in the file.
		again, moved := panel.session_retry(&inst.session, &inst.slots, &before)
		testing.expectf(t, again.error == .Missing_Bank, "%s: a retry's error is %v", c.name, again.error)
		testing.expectf(t, !moved && inst.slots == before, "%s: a retry moved the playing bank", c.name)
	}
}

// -- trying again --------------------------------------------------------------

@(test)
a_retry_finds_the_bank_when_the_saved_file_has_it_back :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))

	saved := new_instance(t, "My Bank", {0, 7}, .Saved)
	defer free(saved)
	result, changed := panel.session_retry(&inst.session, &inst.slots, &saved.slots)

	testing.expect(t, result.restored && changed, "the retry did not restore and move the bank")
	testing.expect_value(t, result.program, 7)
	testing.expect_value(t, patch.slots_label(&inst.slots), "My Bank")
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, inst.session.bank_origin, panel.Origin.User)
	testing.expect_value(t, inst.session.restore, panel.Restore_State.Restored)
}

@(test)
a_retry_that_finds_nothing_changes_nothing_and_stays_failed :: proc(t: ^testing.T) {
	// No file at all, and a file holding some other bank: the retry is a
	// request for one bank, not for whatever is there.
	other := new_instance(t, "Not It", {0, 7}, .Saved)
	defer free(other)
	for saved in ([]^Instance{nil, other}) {
		inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
		defer free(inst)
		panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
		before := inst.slots

		found: ^patch.Slots
		if saved != nil {
			found = &saved.slots
		}
		_, changed := panel.session_retry(&inst.session, &inst.slots, found)

		testing.expect(t, !changed, "a retry that found nothing moved the bank")
		testing.expect(t, inst.slots == before, "a retry that found nothing changed the playing bank")
		testing.expect_value(t, inst.session.restore, panel.Restore_State.Failed)
		testing.expect_value(t, inst.session.restore_error, panel.Restore_Error.Missing_Bank)
		testing.expect(t, inst.session.has_pending, "a retry that failed forgot what it was retrying")
	}
}

@(test)
a_retry_succeeds_when_the_panel_has_handed_the_bank_over_since :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.Imported, 7, "Alfmeister Bank", "x"))

	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Alfmeister Bank", {0, 7}), false, .Imported, nil)
	result, changed := panel.session_retry(&inst.session, &inst.slots, nil)

	testing.expect(t, result.restored, "the retry did not find the bank that was handed over")
	testing.expect(t, !changed, "nothing was read from disk, so nothing moved")
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Adopted)
}

@(test)
a_retry_of_a_failure_that_cannot_change_does_nothing :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, newer_trailer())
	before := inst.slots

	result, changed := panel.session_retry(&inst.session, &inst.slots, nil)

	testing.expect(t, !changed && !result.restored, "a retry changed what could not change")
	testing.expect(t, inst.slots == before, "the bank changed")
	testing.expect_value(t, inst.session.restore_error, panel.Restore_Error.State_Version_Unsupported)
}

// A Program Change drops the identity a failed restore was holding. A retry
// that arrives after it has nothing to find, and must not bring the dropped
// identity back and move the instance off the program it was just put on.
@(test)
a_retry_after_a_program_change_finds_nothing_and_moves_nothing :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	panel.session_select_slot(&inst.session, 1)
	saved := new_instance(t, "My Bank", {0, 7}, .Saved)
	defer free(saved)
	before := inst.slots
	selection_before := inst.session.selection

	// Even with the bank the dropped identity named sitting in the file.
	result, changed := panel.session_retry(&inst.session, &inst.slots, &saved.slots)

	testing.expect(t, !changed && !result.restored && !result.has_program, "a retry acted on an identity that was dropped")
	testing.expect_value(t, inst.session.restore, panel.Restore_State.Not_Requested)
	testing.expect(t, inst.slots == before, "the bank changed")
	testing.expect(t, inst.session.selection == selection_before, "the selection moved")
}

// -- what the panel says it selected -----------------------------------------

@(test)
a_selection_from_the_panel_is_kept_as_it_came_and_bound_only_to_the_playing_bank :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)

	ok := panel.session_select(&inst.session, &inst.slots, panel.Selection{origin = .User, has_slot = true, slot = 7, label = named("Playing"), name = named("Edited Name")})
	testing.expect(t, ok, "refused")
	testing.expect(t, inst.session.selection.bound, "a selection in the playing bank is not bound to it")
	// The bank's own name for the slot, not the page's: writing a patch under
	// a new name has to change what the strip says.
	testing.expect_value(t, panel.selection_view(&inst.session.selection, &inst.slots).name, "Playing 7")

	ok = panel.session_select(&inst.session, &inst.slots, panel.Selection{origin = .Imported, has_slot = true, slot = 3, label = named("Not Playing"), name = named("Elsewhere 3")})
	testing.expect(t, ok, "refused")
	testing.expect(t, !inst.session.selection.bound, "a selection in another bank is bound to this one")
	view := panel.selection_view(&inst.session.selection, &inst.slots)
	testing.expect_value(t, view.label, "Not Playing")
	testing.expect_value(t, view.name, "Elsewhere 3")
}

@(test)
a_slot_that_is_not_a_slot_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_select_slot(&inst.session, 1)
	before := inst.session.selection

	for slot in ([]int{-1, 128, 100000}) {
		ok := panel.session_select(&inst.session, &inst.slots, panel.Selection{origin = .User, has_slot = true, slot = slot, label = named("Playing")})
		testing.expectf(t, !ok, "slot %d was accepted", slot)
		testing.expect(t, inst.session.selection == before, "a refused selection changed the selection")
	}
}

@(test)
a_selection_without_a_slot_or_an_origin_is_a_session_sound :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)

	panel.session_select(&inst.session, &inst.slots, panel.Selection{name = named("Untitled")})

	testing.expect_value(t, inst.session.selection.origin, panel.Origin.Session)
	testing.expect(t, !inst.session.selection.has_slot, "a selection with no slot has one")
}

// A program change selects out of the playing bank, as its origin says.
@(test)
a_program_change_selects_the_slot_in_the_playing_bank :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)

	panel.session_select_slot(&inst.session, 7)

	view := panel.selection_view(&inst.session.selection, &inst.slots)
	testing.expect_value(t, view.origin, panel.Origin.User)
	testing.expect_value(t, view.slot, 7)
	testing.expect_value(t, view.label, "Playing")
	testing.expect_value(t, view.name, "Playing 7")
}

// -- the bank the panel hands over ---------------------------------------------

@(test)
a_bank_from_the_panel_is_played_and_kept_only_when_asked :: proc(t: ^testing.T) {
	text := bank_text("Alfmeister Bank", {0, 2})

	// Playing and not saved: a bank somebody opened from a file.
	inst := new_instance(t, "Factory", {0, 1}, .Built_In)
	defer free(inst)
	result := panel.session_set_bank(&inst.session, &inst.slots, text, false, .Imported, refuse_to_write)
	testing.expect_value(t, result, panel.Bank_Result.Adopted)
	testing.expect_value(t, patch.slots_label(&inst.slots), "Alfmeister Bank")
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect_value(t, inst.session.bank_origin, panel.Origin.Imported)

	// Saved: the per-user file, whatever the page called it.
	inst2 := new_instance(t, "Factory", {0, 1}, .Built_In)
	defer free(inst2)
	result = panel.session_set_bank(&inst2.session, &inst2.slots, text, true, .Factory, write_ok)
	testing.expect_value(t, result, panel.Bank_Result.Saved)
	testing.expect_value(t, inst2.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, inst2.session.bank_origin, panel.Origin.User)

	// Asked to be saved and could not be: still played, and carried by the
	// project because nothing else has it.
	inst3 := new_instance(t, "Factory", {0, 1}, .Built_In)
	defer free(inst3)
	result = panel.session_set_bank(&inst3.session, &inst3.slots, text, true, .None, refuse_to_write)
	testing.expect_value(t, result, panel.Bank_Result.Persistence_Failed)
	testing.expect_value(t, patch.slots_label(&inst3.slots), "Alfmeister Bank")
	testing.expect_value(t, inst3.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect_value(t, inst3.session.bank_origin, panel.Origin.Imported)
}

@(test)
a_bank_that_is_not_a_bank_changes_nothing :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_select_slot(&inst.session, 7)
	before := inst.slots
	session_before := inst.session

	result := panel.session_set_bank(&inst.session, &inst.slots, "{ this is not a bank", true, .Imported, write_ok)

	testing.expect_value(t, result, panel.Bank_Result.Invalid_Bank)
	testing.expect(t, inst.slots == before, "the bank changed")
	testing.expect(t, inst.session == session_before, "the session changed")
}

// A selection means a slot of one bank. When the playing bank changes to
// another, it is no longer a slot of this one, and saving it as one would bring
// it back as somebody else's sound.
@(test)
a_selection_that_the_bank_is_taken_out_from_under_is_saved_as_a_sound_with_no_slot :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_select_slot(&inst.session, 7)

	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Other", {0, 1, 7}), false, .Imported, nil)

	saved := panel.session_trailer(&inst.session, &inst.slots)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.has_slot, "a slot of one bank was saved as a slot of another")
	testing.expect_value(t, trailer.origin, panel.Origin.Session)
	testing.expect_value(t, panel.text_get(&trailer.name), "Playing 7")
	// The bank that is playing is the one that has to come back.
	testing.expect(t, trailer.embedded, "the playing bank was not carried")
}

// The same bank written again under the same name keeps the selection, and the
// strip follows the new name of the slot.
@(test)
writing_a_patch_into_the_selected_slot_renames_the_selection :: proc(t: ^testing.T) {
	inst := new_instance(t, "Playing", {0, 1, 7}, .Saved)
	defer free(inst)
	panel.session_select_slot(&inst.session, 7)

	renamed := `{"format":"quesynth.bank","version":1,"name":"Playing","patches":[null,null,null,null,null,null,null,{"name":"Renamed","parameters":{}}]}`
	result := panel.session_set_bank(&inst.session, &inst.slots, renamed, true, .User, write_ok)

	testing.expect_value(t, result, panel.Bank_Result.Saved)
	testing.expect(t, inst.session.selection.bound, "the selection let go of its own bank")
	testing.expect_value(t, panel.selection_view(&inst.session.selection, &inst.slots).name, "Renamed")
}

// -- what is written -----------------------------------------------------------

@(test)
an_instance_that_was_told_nothing_saves_nothing_extra :: proc(t: ^testing.T) {
	for source in ([]panel.Bank_Source{.Built_In, .Saved}) {
		inst := new_instance(t, "Playing", {0, 1, 7}, source)
		defer free(inst)
		saved := panel.session_trailer(&inst.session, &inst.slots)
		testing.expectf(t, saved == nil, "%v: %d bytes were written for nothing", source, len(saved))
	}
}

@(test)
a_selection_names_the_bank_it_is_in_and_carries_it_only_when_nothing_else_has_it :: proc(t: ^testing.T) {
	cases := [?]struct {
		source:    panel.Bank_Source,
		embedded:  bool,
		saved:     bool,
	} {
		{.Built_In, false, false},
		{.Saved, false, true},
		{.Adopted, true, false},
	}
	for c in cases {
		inst := new_instance(t, "Playing", {0, 1, 7}, c.source)
		defer free(inst)
		panel.session_select_slot(&inst.session, 7)

		saved := panel.session_trailer(&inst.session, &inst.slots)
		defer delete(saved)
		trailer, status := panel.trailer_decode(saved)
		testing.expect_value(t, status, panel.Trailer_Status.Ok)
		testing.expectf(t, trailer.embedded == c.embedded, "%v: embedded is %v", c.source, trailer.embedded)
		testing.expectf(t, trailer.bank_saved == c.saved, "%v: bank saved is %v", c.source, trailer.bank_saved)
		testing.expect_value(t, trailer.slot, 7)
		testing.expect_value(t, panel.text_get(&trailer.label), "Playing")
		testing.expect_value(t, panel.text_get(&trailer.name), "Playing 7")
	}
}

@(test)
an_adopted_bank_travels_with_the_project_even_with_nothing_selected :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1}, .Built_In)
	defer free(inst)
	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Alfmeister Bank", {0, 2}), false, .Imported, nil)

	saved := panel.session_trailer(&inst.session, &inst.slots)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, trailer.embedded, "the imported bank is not in the state")
	testing.expect(t, !trailer.has_slot, "a slot was claimed for an instance that selected nothing")
	testing.expect_value(t, trailer.origin, panel.Origin.None)

	// And back on another instance it is the bank and claims no selection.
	fresh := new_instance(t, "Factory", {0, 1}, .Built_In)
	defer free(fresh)
	result := panel.session_restore(&fresh.session, &fresh.slots, saved)
	testing.expect(t, result.restored, "not restored")
	testing.expect_value(t, patch.slots_label(&fresh.slots), "Alfmeister Bank")
	testing.expect(t, !panel.selection_known(&fresh.session.selection), "a selection appeared that nobody made")
}

// -- helpers -------------------------------------------------------------------

named :: proc(s: string) -> panel.Text {
	t: panel.Text
	panel.text_set(&t, s)
	return t
}

write_ok :: proc(text: string) -> bool {
	return true
}

refuse_to_write :: proc(text: string) -> bool {
	return false
}
