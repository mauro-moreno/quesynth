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
