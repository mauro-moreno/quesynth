#+build windows
package clap_tests

import "core:testing"

import patch "../../src/patch"
import synth "../../hosts/clap"

// The editor-facing half of the CLAP adapter, which exists only on Windows.
//
// gui_set_bank is a callback the WebView2 panel calls, so it lives in
// hosts/clap/gui.odin behind #+build windows. The rest of clap_test.odin drives
// the plugin through its CLAP vtables and builds on every platform; this one test
// reaches the editor callback directly and so is gated the same way the code it
// exercises is. The shared helpers (make_plugin and the rest) are in the same
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

	synth.gui_set_bank(rawptr(s), text, false)

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
