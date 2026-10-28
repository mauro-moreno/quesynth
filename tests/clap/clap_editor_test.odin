#+build windows, linux
package clap_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import panel "../../hosts/panel"
import patch "../../src/patch"
import synth "../../hosts/clap"

// The editor-facing half of the CLAP adapter, which exists only where there is a
// web view: Windows and Linux.
//
// gui_set_bank is a callback the panel calls, so it lives in
// hosts/clap/gui.odin behind the same build tags. The rest of clap_test.odin
// drives the plugin through its CLAP vtables and builds on every platform; this
// one test reaches the editor callback directly and so is gated the same way the
// code it exercises is. It needs no web view, only the code that is built with
// one. The shared helpers (make_plugin and the rest) are in the same
// clap_tests package and are visible here.

// A bank sent by the panel has to reach the thing that answers program changes.
//
// This is the wiring the interface depends on and the one place it cannot be seen
// from: the panel sends a bank, the host adopts it, and from then on a program
// change has to select out of *that* bank. Everything about it is invisible from
// outside the plugin -- the only symptom of it being wrong is a sound that does
// not match what is on screen.
//
// Deliberately with save = false. The saving half is checked in tests/panel
// against a temporary file; doing it here would write over the bank belonging to
// whoever is running the tests.
@(test)
test_a_bank_from_the_panel_is_adopted :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")
	if s == nil {return}

	// What the plugin starts with: the bank compiled in, or one saved on
	// this machine. Either way, not the one below.
	before := patch.slots_name(&s.slots, 0)

	text: string = `{"format":"quesynth.bank","version":1,"name":"From The Panel","patches":[
		{"name":"Panel Patch","parameters":{"osc1 shape":1}},
		null,
		{"name":"Third","parameters":{"osc1 shape":3}}
	]}`

	synth.gui_set_bank(rawptr(s), text, false, .None)

	testing.expect_value(t, patch.slots_label(&s.slots), "From The Panel")
	testing.expect_value(t, patch.slots_name(&s.slots, 0), "Panel Patch")
	testing.expect_value(t, patch.slots_name(&s.slots, 2), "Third")
	testing.expectf(
		t,
		patch.slots_name(&s.slots, 0) != before || before == "Panel Patch",
		"the bank did not change: slot 0 is still %v",
		before,
	)

	// And the gap is a gap, so program 1 selects nothing.
	_, filled := patch.slots_patch(&s.slots, 1)
	testing.expect(t, !filled, "the empty slot came back filled")

	// The point of all of it: a program change now plays out of this bank.
	wanted, ok := patch.slots_patch(&s.slots, 2)
	testing.expect(t, ok, "slot 2 is empty")
	if !ok {return}
	synth.program_change(s, 2)
	same := true
	for i in 0 ..< synth.PARAM_COUNT {
		if s.values[i] != wanted[i] {same = false}
	}
	testing.expect(t, same, "a program change did not load the patch from the new bank")
}

// The bank the panel handed over is the one a Program Change selects from, and
// the one the selection then names -- not the bank the instance started with.
@(test)
test_a_program_change_after_an_adopted_bank_selects_that_banks_slot :: proc(t: ^testing.T) {
	plugin := active_plugin(t)
	if plugin == nil {return}
	defer finish(plugin)
	s := synth.synth_of(plugin)

	text: string = `{"format":"quesynth.bank","version":1,"name":"From The Panel","patches":[
		{"name":"Panel Patch","parameters":{"osc1 shape":1}},
		null,
		{"name":"Third","parameters":{"osc1 shape":3}}
	]}`
	testing.expect_value(t, synth.gui_set_bank(rawptr(s), text, false, .Imported), panel.Bank_Result.Adopted)

	send_midi(plugin, midi_event(0, 0xC0, 2, 0))

	view := panel.selection_view(&s.session.selection, &s.slots)
	testing.expect_value(t, view.origin, panel.Origin.Imported)
	testing.expect_value(t, view.slot, 2)
	testing.expect_value(t, view.label, "From The Panel")
	testing.expect_value(t, view.name, "Third")

	host := synth.gui_host(s)
	patch_message, ok := panel.message_patch(host.read_session(host.user))
	testing.expect(t, ok, "no patch message")
	testing.expect_value(
		t,
		patch_message,
		`{"type":"patch","name":"Third","index":2,"bank":"From The Panel","v":1,"origin":"imported"}`,
	)
}

// What the panel says it selected is what the instance is on, and a slot of the
// bank being played is also the program a host would report.
@(test)
test_the_panel_select_message_records_the_selection_and_the_program :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)
	s := synth.synth_of(plugin)
	host := synth.gui_host(s)

	label := patch.slots_label(&s.slots)
	message := panel_select_message(label, 6, patch.slots_name(&s.slots, 6))
	panel.handle_message(&host, message)

	testing.expect_value(t, s.session.selection.slot, 6)
	testing.expect(t, s.session.selection.bound, "a selection in the playing bank is not bound to it")
	testing.expect_value(t, s.program, 6)

	// A preset from some other bank is a selection, and not a program of this
	// one.
	panel.handle_message(&host, panel_select_message("Not Playing Here", 9, "Elsewhere"))
	testing.expect_value(t, s.session.selection.slot, 9)
	testing.expect(t, !s.session.selection.bound, "a selection in another bank is bound to this one")
	testing.expect_value(t, s.program, 6)
}

// The editor closing and opening again is the panel asking for everything
// again, and what it is told depends on the instance and not on the panel.
@(test)
test_reopening_the_editor_is_told_the_same_thing_again :: proc(t: ^testing.T) {
	plugin := active_plugin(t)
	if plugin == nil {return}
	defer finish(plugin)
	s := synth.synth_of(plugin)
	host := synth.gui_host(s)

	send_midi(plugin, midi_event(0, 0xC0, 6, 0))
	first := panel.handle_message(&host, `{"type":"sync"}`)
	// The editor is destroyed and made again: nothing of the instance is.
	second := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(first), 3)
	testing.expect_value(t, len(second), len(first))
	for i in 0 ..< min(len(first), len(second)) {
		testing.expect_value(t, second[i], first[i])
	}
	if len(first) == 3 {
		testing.expect(t, strings.has_prefix(first[2], `{"type":"patch","name":`), first[2])
	}
}

// A select message as the page sends it.
panel_select_message :: proc(bank: string, slot: int, name: string) -> string {
	return fmt.tprintf(`{{"type":"select","v":1,"origin":"user","bank":"%s","slot":%d,"name":"%s"}}`, bank, slot, name)
}

// -- what the reopened editor is told after a state load -----------------------
//
// The panel asks for everything when it opens, and the answer comes from the
// instance. After a project is loaded -- or the plugin comes back online -- it
// has to be the imported bank, the program and the name that were saved, with
// the restore said out loud; not Factory, and not slot 0.

@(test)
test_the_editor_opened_after_a_state_load_is_told_the_bank_the_program_and_the_restore :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Alfmeister Bank", {0, 7, 42}, 42, .Adopted)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	host := synth.gui_host(synth.synth_of(after))

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
test_a_failed_restore_reaches_the_panel_and_a_retry_that_finds_nothing_changes_nothing :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := make_plugin(t)
	if after == nil {return}
	defer after.destroy(after)
	b := synth.synth_of(after)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	host := synth.gui_host(b)
	slots_before := b.slots

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
	testing.expect(t, b.slots == slots_before, "a retry changed the bank")
	testing.expect(t, all_values(t, before) == all_values(t, after), "a retry changed the sound")

	// Dismissed: it is gone, and the state saved next carries no memory of it.
	panel.handle_message(&host, `{"type":"restore-discard","v":1}`)
	testing.expect_value(t, len(panel.handle_message(&host, `{"type":"sync"}`)), 2)
	resaved := save_state(t, after)
	defer delete(resaved)
	testing.expect_value(t, len(resaved), synth.STATE_SIZE)
}

// The project's bank is missing, and then a MIDI Program Change arrives -- a
// sequencer that sends one at the top of a song does exactly this. The
// instance drops the failed restore, because choosing a program is a choice,
// and the panel that was showing it has to be able to find that out. Asking
// again used to get no answer at all, which left the banner waiting on it.
//
// Through the real callbacks and a real block: the Program Change is an event
// process() consumes, and the panel's messages are the ones the host answers.
@(test)
test_a_retry_after_a_program_change_dropped_a_failed_restore_is_answered :: proc(t: ^testing.T) {
	before, _ := work_in_progress(t, "Issue 13 Lost Bank", {0, 7}, 7, .Saved)
	if before == nil {return}
	defer before.destroy(before)
	saved := save_state(t, before)
	defer delete(saved)

	after := active_plugin(t)
	if after == nil {return}
	defer finish(after)
	b := synth.synth_of(after)
	panel.session_set_bank(&b.session, &b.slots, bank_document("Playing Meanwhile", {0, 1}), false, .Imported, nil)
	testing.expect(t, load_saved(after, saved), "the saved state was refused")
	host := synth.gui_host(b)

	shown := panel.handle_message(&host, `{"type":"sync"}`)
	testing.expect_value(t, len(shown), 3)
	if len(shown) != 3 {return}
	testing.expect(t, strings.has_prefix(shown[2], `{"type":"restore","v":1,"state":"failed","error":"MissingBank"`), shown[2])

	send_midi(after, midi_event(0, 0xC0, 1, 0))
	testing.expect_value(t, b.program, 1)
	testing.expect_value(t, b.session.restore, panel.Restore_State.Not_Requested)

	// What the main thread then tells an open editor: the patch, and nothing
	// about a failure the host no longer holds.
	patch_message := `{"type":"patch","name":"Playing Meanwhile 1","index":1,"bank":"Playing Meanwhile","v":1,"origin":"imported"}`
	told := panel.selection_replies(&host)
	testing.expect_value(t, len(told), 1)
	if len(told) == 1 {
		testing.expect_value(t, told[0], patch_message)
	}

	// A page that missed that and asks again is answered with where the
	// instance is and that it is restoring nothing.
	retried := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)
	testing.expect_value(t, len(retried), 2)
	if len(retried) != 2 {return}
	testing.expect_value(t, retried[0], patch_message)
	testing.expect_value(t, retried[1], `{"type":"restore","v":1,"state":"notRequested"}`)
	testing.expect_value(t, b.program, 1)
	testing.expect_value(t, patch.slots_label(&b.slots), "Playing Meanwhile")
}
