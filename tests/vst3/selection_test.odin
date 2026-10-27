package vst3_tests

import "core:testing"

import "../../hosts/panel"
import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// Which preset an instance says it is on. A host selects a program by changing
// a parameter; what the instance reports afterwards is what a saved project
// carries and what the panel is told.

BANK_OF_THREE := `{"format":"quesynth.bank","version":1,"name":"Selected From","patches":[
	{"name":"Zero","parameters":{"osc1 shape":0}},
	null,
	{"name":"Two","parameters":{"osc1 shape":3,"amp gain":90}}
]}`

@(test)
a_program_selects_the_exact_slot_of_the_bank_being_played :: proc(t: ^testing.T) {
	// The two routes a host has: a change that arrives in `process`, which is
	// the audio thread, and one set on the controller, which is the main one.
	for on_the_controller in ([]bool{false, true}) {
		p := make_active_plugin(t)
		if p == nil {return}
		defer synth.release(p)
		testing.expect_value(t, synth.plugin_set_bank(p, BANK_OF_THREE, false, .Imported), panel.Bank_Result.Adopted)
		testing.expect(t, !panel.selection_known(&p.session.selection), "a new instance claims to be on a preset")

		if on_the_controller {
			synth.controller_set_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID, synth.program_normalized(2))
		} else {
			point := Parameter_Point {
				id    = synth.PROGRAM_PARAM_ID,
				value = synth.program_normalized(2),
			}
			process_block(t, p, &point)
		}

		view := panel.selection_view(&p.session.selection, &p.slots)
		testing.expectf(t, view.has_slot && view.slot == 2, "controller %v: slot %d", on_the_controller, view.slot)
		testing.expect_value(t, view.origin, panel.Origin.Imported)
		testing.expect_value(t, view.label, "Selected From")
		testing.expect_value(t, view.name, "Two")
		// And the parameter a host reads says the same slot.
		testing.expect_value(t, synth.controller_get_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID), synth.program_normalized(2))
	}
}

// An empty slot is remembered as the program, as it always was, and selects
// nothing: the sound is still the one before it, and that is what it is still
// called.
@(test)
a_program_on_an_empty_slot_leaves_the_selection_where_it_was :: proc(t: ^testing.T) {
	p := make_active_plugin(t)
	if p == nil {return}
	defer synth.release(p)
	synth.plugin_set_bank(p, BANK_OF_THREE, false, .Imported)

	synth.controller_set_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID, synth.program_normalized(2))
	synth.controller_set_param_normalized(controller_of(p), synth.PROGRAM_PARAM_ID, synth.program_normalized(1))

	testing.expect_value(t, p.session.selection.slot, 2)
	testing.expect_value(t, p.program, i32(1))
}
