package synth_vst3

import "../../src/patch"
import "../../src/vst3"

// Which parameter a MIDI controller moves.
//
// VST3 has no event for a controller message. The host asks this, once, for
// every controller it might see, and from then on a controller arrives as an
// ordinary parameter change -- automatable, drawn on a lane, saved with the
// project. A plugin that does not answer never hears a controller at all, which
// is what this one did until now.
//
// That makes the mapping the *same* thing here as the assignments in
// ui/midimap.js, arrived at by a different route, so the numbers are the same
// numbers and for the same reason: they are the MIDI 1.0 Sound Controllers, and
// they are what a keyboard's knobs send when it is set to "filter" and
// "envelope".
//
//   CC 71   Timbre / Harmonic Content   -> filter resonance
//   CC 72   Release Time                -> amp release
//   CC 73   Attack Time                 -> amp attack
//   CC 74   Brightness                  -> filter cutoff
//   CC 75   Decay Time                  -> amp decay
//   CC 93   Effects 3 Depth, chorus     -> chorus level
//   CC 10   Pan                         -> pan
//
// Not CC 1 and not CC 7. The modulation wheel belongs to the engine's own
// controller assignment, which is patch data and can point anywhere the patch
// says; claiming it here would nail it to one parameter for every sound. CC 7
// is Channel Volume and is the host's to apply.
//
// Parameter ids are the .sy1 parameter numbers, which is what
// controller_get_parameter_info reports, so the id handed back is one the host
// already knows.

@(private = "file")
STANDARD_CONTROLLERS := [?]struct {
	controller: i16,
	name:       string,
} {
	{71, "*filter resonance"},
	{72, "amp release"},
	{73, "amp attack"},
	{74, "*filter freq"},
	{75, "amp decay"},
	{93, "chorus level"},
	{10, "pan"},
}

midi_map_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	p := from_midi_map(this)
	context = p.ctx
	return query_interface(p, iid, obj)
}

midi_map_add_ref :: proc "c" (this: rawptr) -> u32 {
	p := from_midi_map(this)
	p.ref_count += 1
	return u32(p.ref_count)
}

midi_map_release :: proc "c" (this: rawptr) -> u32 {
	return release(from_midi_map(this))
}

// The host asks once per controller, per bus, per channel.
//
// The same answer on every channel: this is one instrument on one part, not a
// multitimbral rack, so a controller means the same thing whichever channel it
// arrives on. A controller with no assignment returns RESULT_FALSE rather than
// an error -- "nothing here", which is a normal answer and not a fault.
midi_map_get_assignment :: proc "c" (
	this: rawptr,
	bus: i32,
	channel: i16,
	controller: i16,
	id: ^u32,
) -> vst3.Result {
	if id == nil {
		return vst3.INVALID_ARGUMENT
	}
	if bus != 0 {
		return vst3.RESULT_FALSE
	}

	p := from_midi_map(this)
	context = p.ctx

	for entry in STANDARD_CONTROLLERS {
		if entry.controller != controller {
			continue
		}
		index := patch.parameter_index(entry.name)
		// A name this build does not have is a mistake in the table above, not
		// something to hand the host a wrong id for.
		if index < 0 {
			return vst3.RESULT_FALSE
		}
		id^ = u32(index)
		return vst3.RESULT_OK
	}

	return vst3.RESULT_FALSE
}

MIDI_MAP_VTBL := vst3.IMidi_Mapping_Vtbl {
	query_interface                = midi_map_query_interface,
	add_ref                        = midi_map_add_ref,
	release                        = midi_map_release,
	get_midi_controller_assignment = midi_map_get_assignment,
}
