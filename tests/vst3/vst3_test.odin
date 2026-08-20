#+build windows
package vst3_tests

import "core:testing"

import "../../src/patch"
import synth "../../hosts/vst3"

@(test)
stored_values_survive_vst3_normalization :: proc(t: ^testing.T) {
	for c in ([]struct {index, stored: int} {
		{64, 4},      // display-keyed, not state position 2
		{33, 64},     // beyond the measured state table
		{21, 128},    // out-of-table reference default
		{86, 45057},  // 16-bit MIDI source B001
		{89, 65535},
	}) {
		normalized := synth.normalized_of(c.index, i32(c.stored))
		got := synth.stored_of(c.index, normalized)
		testing.expect_value(t, got, i32(c.stored))
	}
}

// The VST3 half of the bank, checked the way the CLAP half is.
//
// These two formats do the same thing by different routes and the checking was
// lopsided: tests/clap could call the CLAP host's bank handling directly, while
// the VST3's lived on the Editor -- which needs a web view, which needs WebView2
// beside the binary, so nothing could reach it. "It should do the same" is only
// worth saying if the same thing is checked, so it moved onto the plugin and
// this is the check.

@(test)
a_bank_from_the_panel_is_adopted :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	testing.expect(t, p != nil, "no plugin")
	if p == nil {return}
	defer synth.release(p)

	before := patch.slots_name(&p.slots, 0)

	text: string = `{"format":"quesynth.bank","version":1,"name":"From The Panel","patches":[
		{"name":"Panel Patch","parameters":{"osc1 shape":1}},
		null,
		{"name":"Third","parameters":{"osc1 shape":3}}
	]}`

	// save = false on purpose: the writing half is checked in tests/panel
	// against a temporary file, and doing it here would write over the bank
	// belonging to whoever is running the tests.
	synth.plugin_set_bank(p, text, false)

	testing.expect_value(t, patch.slots_label(&p.slots), "From The Panel")
	testing.expect_value(t, patch.slots_name(&p.slots, 0), "Panel Patch")
	testing.expect_value(t, patch.slots_name(&p.slots, 2), "Third")
	testing.expectf(
		t,
		patch.slots_name(&p.slots, 0) != before || before == "Panel Patch",
		"the bank did not change: slot 0 is still %v",
		before,
	)

	// The gap is a gap, so program 1 selects nothing.
	_, filled := patch.slots_patch(&p.slots, 1)
	testing.expect(t, !filled, "the empty slot came back filled")
}

// And what all of it is for: a program change plays out of the bank the panel
// handed over, not the one the plugin started with.
@(test)
a_program_change_uses_the_adopted_bank :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	text: string = `{"format":"quesynth.bank","version":1,"name":"Adopted","patches":[
		{"name":"Zero","parameters":{"osc1 shape":0}},
		{"name":"One","parameters":{"osc1 shape":2,"amp gain":90}}
	]}`
	synth.plugin_set_bank(p, text, false)

	wanted, ok := patch.slots_patch(&p.slots, 1)
	testing.expect(t, ok, "slot 1 is empty")
	if !ok {return}

	synth.select_program(p, 1)

	same := true
	for i in 0 ..< patch.PARAMETER_COUNT {
		if p.values[i] != wanted[i] {same = false}
	}
	testing.expect(t, same, "a program change did not load the patch from the adopted bank")
}

// A bank that will not parse leaves the one that is playing alone.
//
// Refused rather than half-applied: a plugin that emptied its bank because a
// message was malformed would lose every program number at once.
//
// The leak check reports five bytes here and they are not ours. core:encoding
// /json allocates as it scans and what it built before giving up is not
// reachable from the value it hands back, so destroy_value cannot free it --
// moving that defer above the error return, which is where it belongs and is
// where it now is, did not change the number. Five bytes per malformed bank,
// and a malformed bank means a bug somewhere that matters more.
@(test)
a_broken_bank_changes_nothing :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	before_label := patch.slots_label(&p.slots)
	before_name := patch.slots_name(&p.slots, 0)

	synth.plugin_set_bank(p, "{ this is not a bank", false)

	testing.expect_value(t, patch.slots_label(&p.slots), before_label)
	testing.expect_value(t, patch.slots_name(&p.slots, 0), before_name)
}

// What the panel is handed back has to be a bank the panel can read, or the
// interface comes up showing the one compiled into the page while the plugin
// plays something else.
@(test)
what_goes_back_to_the_panel_is_a_bank :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	text: string = `{"format":"quesynth.bank","version":1,"name":"Round Trip","patches":[
		{"name":"Alpha","parameters":{"osc1 shape":1}},
		null,
		{"name":"Gamma","parameters":{"osc1 shape":3}}
	]}`
	synth.plugin_set_bank(p, text, false)

	out := synth.plugin_read_bank(p)
	testing.expect(t, out != "", "nothing came back")

	again, err := patch.parse_bank_json(transmute([]u8)out)
	testing.expect_value(t, err, patch.Json_Error.None)
	if err != .None {return}
	defer patch.destroy_bank(again)

	back: patch.Slots
	patch.slots_load(&back, again)
	testing.expect_value(t, patch.slots_label(&back), "Round Trip")
	testing.expect_value(t, patch.slots_name(&back, 0), "Alpha")
	testing.expect_value(t, patch.slots_name(&back, 2), "Gamma")
	_, filled := patch.slots_patch(&back, 1)
	testing.expect(t, !filled, "the gap did not survive the trip back")
}
