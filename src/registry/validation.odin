package registry

import "../patch"

Registry_Error :: enum {
	None,
	Unknown_Parameter,
	Out_Of_Range,
}

// The number of measured states a parameter has -- its number of positions.
registry_state_count :: proc(d: Parameter_Descriptor) -> int {
	return len(patch.parameter_states(d.index))
}

// The default stored value, from the measured table.
registry_default :: proc(d: Parameter_Descriptor) -> int {
	return patch.PARAMETERS[d.index].default
}

// The domain of stored values a client may send. Derived, never restated.
registry_stored_range :: proc(d: Parameter_Descriptor) -> (lo, hi: int, ok: bool) {
	return patch.parameter_stored_range(d.index)
}

// Check a stored value against the parameter's domain. On success `stored` is
// the value to hand the engine; on failure the error says why, so the protocol
// can map it to a machine-readable code rather than a string.
registry_validate :: proc(
	d: Parameter_Descriptor,
	value: int,
) -> (
	stored: int,
	err: Registry_Error,
) {
	lo, hi, ok := patch.parameter_stored_range(d.index)
	if !ok {
		return 0, .Unknown_Parameter
	}
	if value < lo || value > hi {
		return 0, .Out_Of_Range
	}
	return value, .None
}

// Validate by id, resolving the descriptor first.
registry_validate_id :: proc(id: string, value: int) -> (stored: int, err: Registry_Error) {
	d, ok := registry_describe(id)
	if !ok {
		return 0, .Unknown_Parameter
	}
	return registry_validate(d, value)
}

// A stored value as a normalised 0..1 position, uniform across the parameter's
// positions. This is the position law a slider or a bar meter wants, not the
// reference plugin's own measured normalisation (patch.parameter_norm), which
// is non-uniform and belongs to the VST/CLAP reporting path.
registry_normalize :: proc(d: Parameter_Descriptor, stored: int) -> f32 {
	n := registry_state_count(d)
	if n <= 1 {
		return 0
	}
	pos, ok := patch.parameter_position(d.index, stored)
	if !ok {
		return 0
	}
	return f32(pos) / f32(n - 1)
}

// The inverse of registry_normalize: a 0..1 position back to a stored value. It
// round-trips every value a position can hold, which is the domain a client
// actually moves through.
registry_denormalize :: proc(d: Parameter_Descriptor, t: f32) -> int {
	n := registry_state_count(d)
	if n <= 0 {
		return 0
	}
	clamped := t
	if clamped < 0 {
		clamped = 0
	}
	if clamped > 1 {
		clamped = 1
	}
	pos := int(clamped * f32(n - 1) + 0.5)
	if pos < 0 {
		pos = 0
	}
	if pos > n - 1 {
		pos = n - 1
	}
	stored, ok := patch.parameter_stored_at_position(d.index, pos)
	if !ok {
		return 0
	}
	return stored
}

// The reference plugin's display string for a stored value: "3.20 kHz", "25 %",
// and so on. The registry does not format these itself; each is the measured
// string the reference shows, so every client reads one consistent label.
registry_format :: proc(d: Parameter_Descriptor, stored: int) -> string {
	pos, ok := patch.parameter_position(d.index, stored)
	if !ok {
		return ""
	}
	states := patch.parameter_states(d.index)
	if pos < 0 || pos >= len(states) {
		return ""
	}
	return states[pos].display
}
