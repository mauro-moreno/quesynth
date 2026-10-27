package clap_tests

import "core:testing"

import clap "../../src/clap"
import panel "../../hosts/panel"
import patch "../../src/patch"
import synth "../../hosts/clap"

// Which preset an instance says it is on. A Program Change arrives as MIDI and
// selects out of the bank the instance is playing; what the instance then
// reports is what a saved project carries and what the panel is told.

// Drive one MIDI event through the plugin the way a host would.
send_midi :: proc(plugin: ^clap.Plugin, events: ..clap.Event_Midi) {
	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)
	for event in events {
		e := event
		input_push(&input, &e)
	}
	run_block(plugin, &render, &input, &output)
}

active_plugin :: proc(t: ^testing.T) -> ^clap.Plugin {
	plugin := make_plugin(t)
	if plugin == nil {return nil}
	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	plugin.start_processing(plugin)
	return plugin
}

finish :: proc(plugin: ^clap.Plugin) {
	plugin.stop_processing(plugin)
	plugin.deactivate(plugin)
	plugin.destroy(plugin)
}

@(test)
test_a_program_change_selects_the_exact_slot_of_the_bank_being_played :: proc(t: ^testing.T) {
	plugin := active_plugin(t)
	if plugin == nil {return}
	defer finish(plugin)
	s := synth.synth_of(plugin)

	// Nobody has selected anything on a new instance, and it does not claim
	// slot 0.
	testing.expect(t, !panel.selection_known(&s.session.selection), "a new instance claims to be on a preset")

	send_midi(plugin, midi_event(0, 0xC0, 6, 0))

	view := panel.selection_view(&s.session.selection, &s.slots)
	testing.expect_value(t, view.slot, 6)
	testing.expect(t, view.has_slot, "the selection has no slot")
	testing.expect_value(t, view.label, patch.slots_label(&s.slots))
	testing.expect_value(t, view.name, patch.slots_name(&s.slots, 6))
	testing.expect_value(t, s.program, 6)
}

// A bank that does not exist is not a bank to select from, so the selection
// does not move to it -- and does not move to bank zero's slot either.
@(test)
test_bank_select_other_than_zero_selects_nothing :: proc(t: ^testing.T) {
	plugin := active_plugin(t)
	if plugin == nil {return}
	defer finish(plugin)
	s := synth.synth_of(plugin)

	send_midi(plugin, midi_event(0, 0xB0, 0, 0), midi_event(0, 0xB0, 32, 1), midi_event(0, 0xC0, 6, 0))

	testing.expect(t, !panel.selection_known(&s.session.selection), "a program change into a bank that does not exist selected something")
	testing.expect_value(t, s.program, 0)

	// And bank zero again, in the same breath, is the bank that exists.
	send_midi(plugin, midi_event(0, 0xB0, 32, 0), midi_event(0, 0xC0, 6, 0))
	testing.expect_value(t, s.session.selection.slot, 6)
}

@(test)
test_a_program_change_on_an_empty_slot_leaves_the_selection_where_it_was :: proc(t: ^testing.T) {
	plugin := active_plugin(t)
	if plugin == nil {return}
	defer finish(plugin)
	s := synth.synth_of(plugin)

	send_midi(plugin, midi_event(0, 0xC0, 6, 0))
	_, filled := patch.slots_patch(&s.slots, 120)
	testing.expect(t, !filled, "slot 120 was expected to be empty")
	send_midi(plugin, midi_event(0, 0xC0, 120, 0))

	// The sound is still slot 6's, so that is what it is still called.
	testing.expect_value(t, s.session.selection.slot, 6)
	testing.expect_value(t, s.program, 6)
}
