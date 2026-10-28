#+build windows, linux
package vst3_tests

import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/vst3"
import synth "../../hosts/vst3"

// The panel's side of the same thing, through the editor's own callbacks: the
// ones a web view's messages end in, without a window.

@(test)
the_panel_select_message_records_the_selection_and_moves_the_program_parameter :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	synth.plugin_set_bank(p, BANK_OF_THREE, false, .Imported)
	ed := synth.Editor {
		plugin = p,
	}
	host := synth.editor_host(&ed)

	panel.handle_message(&host, `{"type":"select","v":1,"origin":"imported","bank":"Selected From","slot":2,"name":"Two"}`)

	testing.expect_value(t, p.session.selection.slot, 2)
	testing.expect(t, p.session.selection.bound, "a selection in the playing bank is not bound to it")
	// The program a host reads is the slot the panel selected, exactly.
	testing.expect_value(t, p.program, i32(2))
	testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID), synth.program_normalized(2))

	// A preset from a bank this instance is not playing has no slot here.
	panel.handle_message(&host, `{"type":"select","v":1,"origin":"imported","bank":"Somewhere Else","slot":9,"name":"Nine"}`)
	testing.expect(t, !p.session.selection.bound, "a selection in another bank is bound to this one")
	testing.expect_value(t, p.program, i32(2))
}

@(test)
the_panel_is_told_what_the_instance_is_on_each_time_it_asks :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	synth.plugin_set_bank(p, BANK_OF_THREE, false, .Imported)
	synth.select_program(p, 2)
	ed := synth.Editor {
		plugin = p,
	}
	host := synth.editor_host(&ed)

	first := panel.handle_message(&host, `{"type":"sync"}`)
	second := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(first), 3)
	testing.expect_value(t, len(second), 3)
	if len(first) != 3 || len(second) != 3 {return}
	for i in 0 ..< 3 {
		testing.expect_value(t, second[i], first[i])
	}
	testing.expect_value(
		t,
		first[2],
		`{"type":"patch","name":"Two","index":2,"bank":"Selected From","v":1,"origin":"imported"}`,
	)
}

// The panel asks for everything when it opens, and the answer comes from the
// instance. After a project is loaded -- or the plugin comes back online -- it
// has to be the imported bank, the program and the name that were saved, with
// the restore said out loud; not Factory, and not slot 0.
@(test)
the_editor_opened_after_a_state_load_is_told_the_bank_the_program_and_the_restore :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
	ed := synth.Editor {
		plugin = after,
	}
	host := synth.editor_host(&ed)

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(replies), 4)
	if len(replies) != 4 {return}
	testing.expect(t, strings.has_prefix(replies[0], `{"type":"bank","text":"{`), replies[0])
	testing.expect(t, strings.has_suffix(replies[0], `,"v":1,"origin":"imported","readOnly":false}`), replies[0])
	testing.expect(t, strings.has_prefix(replies[1], `{"type":"state","values":[`), replies[1])
	testing.expect_value(
		t,
		replies[2],
		`{"type":"patch","name":"Alfmeister Bank 42","index":42,"bank":"Alfmeister Bank","v":1,"origin":"imported"}`,
	)
	testing.expect_value(
		t,
		replies[3],
		`{"type":"restore","v":1,"state":"restored","origin":"imported","bank":"Alfmeister Bank","slot":42,"name":"Alfmeister Bank 42"}`,
	)

	// Closing the editor and opening it again is the same question, and the same
	// answer: it lives on the instance.
	again := panel.handle_message(&host, `{"type":"sync"}`)
	testing.expect_value(t, len(again), len(replies))
	for i in 0 ..< min(len(again), len(replies)) {
		testing.expect_value(t, again[i], replies[i])
	}
}

@(test)
a_failed_restore_reaches_the_panel_and_a_retry_that_finds_nothing_changes_nothing :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	after := synth.make_plugin()
	if after == nil {return}
	defer synth.release(after)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
	ed := synth.Editor {
		plugin = after,
	}
	host := synth.editor_host(&ed)
	slots_before := after.slots

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	// The bank that is playing, the sound, and what went wrong: and no patch,
	// because the instance is on none.
	testing.expect_value(t, len(replies), 3)
	if len(replies) != 3 {return}
	testing.expect(t, strings.has_prefix(replies[2], `{"type":"restore","v":1,"state":"failed","error":"MissingBank","recoverable":true,`), replies[2])
	testing.expect(t, strings.has_suffix(replies[2], `"origin":"user","bank":"Issue 13 Lost Bank","slot":7,"name":"Issue 13 Lost Bank 7"}`), replies[2])

	// Retry: the saved bank on this machine is not it either.
	retried := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)
	testing.expect_value(t, len(retried), 1)
	if len(retried) == 1 {
		testing.expect_value(t, retried[0], replies[2])
	}
	testing.expect(t, after.slots == slots_before, "a retry changed the bank")
	testing.expect(t, values_of_instance(before) == values_of_instance(after), "a retry changed the sound")

	// Dismissed: it is gone, and the state saved next carries no memory of it.
	panel.handle_message(&host, `{"type":"restore-discard","v":1}`)
	testing.expect_value(t, len(panel.handle_message(&host, `{"type":"sync"}`)), 2)
	resaved := save_session(t, after)
	defer delete(resaved)
	testing.expect_value(t, len(resaved), synth.STATE_SIZE)
}

// A host that selects a program -- a Program Change from a sequencer, or the
// host's own menu -- while the project's bank is missing. The instance drops
// the failed restore, and a panel that was still showing it and asks again has
// to be answered rather than left waiting. Both ways a VST3 host selects one
// are tried: the one that arrives in `process`, and the one on the controller.
@(test)
a_retry_after_a_program_change_dropped_a_failed_restore_is_answered :: proc(t: ^testing.T) {
	before := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer synth.release(before)
	saved := save_session(t, before)
	defer delete(saved)

	for how in ([]string{"process", "controller"}) {
		after := synth.make_plugin()
		if after == nil {return}
		defer synth.release(after)
		panel.session_set_bank(&after.session, &after.slots, bank_document("Playing Meanwhile", {0, 1}), false, .Imported, nil)
		testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
		ed := synth.Editor {
			plugin = after,
		}
		host := synth.editor_host(&ed)
		shown := panel.handle_message(&host, `{"type":"sync"}`)
		testing.expectf(t, len(shown) == 3, "%s: the failure was not shown: %d messages", how, len(shown))

		if how == "process" {
			synth.select_program(after, 1)
		} else {
			synth.stage_program(after, 1)
		}
		testing.expect_value(t, after.session.restore, panel.Restore_State.Not_Requested)

		patch_message := `{"type":"patch","name":"Playing Meanwhile 1","index":1,"bank":"Playing Meanwhile","v":1,"origin":"imported"}`
		told := panel.selection_replies(&host)
		testing.expectf(t, len(told) == 1 && told[0] == patch_message, "%s: the panel was told %v", how, told[:])

		retried := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)
		testing.expectf(t, len(retried) == 2, "%s: the retry was answered with %d messages", how, len(retried))
		if len(retried) != 2 {continue}
		testing.expect_value(t, retried[0], patch_message)
		testing.expect_value(t, retried[1], `{"type":"restore","v":1,"state":"notRequested"}`)
		testing.expect_value(t, after.program, i32(1))
	}
}
