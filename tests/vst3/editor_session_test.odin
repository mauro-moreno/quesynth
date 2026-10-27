#+build windows, linux
package vst3_tests

import "core:testing"

import "../../hosts/panel"
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
