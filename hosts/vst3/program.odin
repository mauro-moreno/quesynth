package synth_vst3

import "../../src/patch"

// Programs: how a VST3 host selects a patch by number.
//
// There is no MIDI event for a Program Change in VST3. A plugin declares a
// parameter carrying kIsProgramChange, and the host converts the message into a
// change to that parameter -- which means selecting a preset from the host's
// own menu arrives by exactly the same route, and automating it works too.
//
// The parameter sits one past the synth's own, so every existing id keeps its
// number: a project saved before this existed still loads.
PROGRAM_PARAM_ID :: u32(PARAM_COUNT)

// Normalised 0..1 to a slot, and back.
//
// A hundred and twenty-eight slots is a hundred and twenty-seven steps between
// them, which is what `stepCount` says; rounding rather than truncating so the
// value a host reads back for slot n gives n again.
program_of :: proc "contextless" (normalized: f64) -> int {
	if normalized <= 0 {return 0}
	if normalized >= 1 {return patch.FACTORY_SLOTS - 1}
	return int(normalized * f64(patch.FACTORY_SLOTS - 1) + 0.5)
}

program_normalized :: proc "contextless" (program: i32) -> f64 {
	slot := int(program)
	if slot <= 0 {return 0}
	if slot >= patch.FACTORY_SLOTS - 1 {return 1}
	return f64(slot) / f64(patch.FACTORY_SLOTS - 1)
}

// Load the patch in a slot.
//
// An empty slot is remembered as the current program but loads nothing: the
// number stays addressable -- program 47 is always program 47 -- and the sound
// does not change, which is better than substituting the nearest one.
select_program :: proc "contextless" (p: ^Plugin, program: int) {
	if program < 0 || program >= patch.FACTORY_SLOTS {
		return
	}
	p.program = i32(program)

	values, ok := patch.factory_patch(program)
	if !ok {
		return
	}

	changed := false
	for i in 0 ..< PARAM_COUNT {
		wanted := i32(values[i])
		if p.values[i] != wanted {
			p.values[i] = wanted
			changed = true
		}
	}
	if changed {
		p.params_dirty = true
	}
}
