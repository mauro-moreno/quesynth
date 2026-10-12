package patch

// Turning a stored .sy1 integer into the normalised value the reference plugin
// reports for it.
//
// Everything here is driven by the measured state tables in params.odin. A
// normalised value is never reconstructed arithmetically for a state that
// exists: `(n + 0.5) / state_count` disagrees with the plugin on ten
// parameters, silently, and lfo1/lfo2 destination alone accounted for most of
// the mismatches that motivated this code. The only arithmetic left is the
// deliberate continuation of the uniform grid past the end of a table, which is
// what the plugin itself does for a stored integer no state can hold.
//
// The resolution order is the one in docs/synth1-param-encoding.md, with the
// per-parameter facts that document leaves open supplied by measurement:
//
//   1. When the parameter is display-keyed, the stored integer selects the
//      state whose display equals it.
//   2. Otherwise the stored integer is a direct state index.
//   3. A stored integer that neither rule places is out of range, and the
//      plugin either saturates at the top state or keeps walking the grid.
//
// Whether a parameter is display-keyed, and which out-of-range behaviour it
// has, are properties of the plugin rather than of the state table, so both are
// measured by `s1probe mapping` and generated into params.odin.

// A display is a plain integer only in the strict sense: an optional minus sign
// followed by digits, with no leading plus and no leading zeros.
//
// The strictness is load-bearing. Index 2 renders as "00" and "+01" and index 3
// as "+15 cent"; neither keys off its display text, and admitting those forms
// would make rule 1 fire on parameters that are really direct state indices.
// It is `contextless` because the CLAP parameter adapter derives each
// parameter's advertised range from these displays inside a contextless
// callback. The body never touched the context.
display_integer :: proc "contextless" (s: string) -> (value: int, ok: bool) {
	if len(s) == 0 {return 0, false}

	digits := s
	negative := false
	if s[0] == '-' {
		negative = true
		digits = s[1:]
	}
	if len(digits) == 0 {return 0, false}
	for i in 0 ..< len(digits) {
		if digits[i] < '0' || digits[i] > '9' {return 0, false}
	}
	// Reject "007" and "-0": one integer must have exactly one spelling, or
	// display matching stops being a function.
	if len(digits) > 1 && digits[0] == '0' {return 0, false}
	if negative && digits == "0" {return 0, false}

	magnitude := 0
	for i in 0 ..< len(digits) {
		magnitude = magnitude * 10 + int(digits[i] - '0')
	}
	if negative {
		return -magnitude, true
	}
	return magnitude, true
}

// The measured state table for a parameter; empty when the parameter is
// continuous and therefore has no states.
parameter_states :: proc "contextless" (index: int) -> []Parameter_State {
	if index < 0 || index >= PARAMETER_COUNT {return nil}
	p := PARAMETERS[index]
	return PARAMETER_STATES[p.state_offset:][:p.state_count]
}

// The complete domain of integers a host must preserve for a parameter.
//
// This is deliberately not just 0..state_count-1. Display-keyed parameters
// store the displayed number (chorus stages stores 1, 2 or 4), parameters that
// continue their measured grid accept the whole 7-bit .sy1 range, and the four
// controller-assignment fields are genuine 16-bit values. Keeping this rule in
// the patch package gives every host one answer for state <-> plain conversion.
parameter_stored_range :: proc "contextless" (index: int) -> (lo, hi: int, ok: bool) {
	if index < 0 || index >= PARAMETER_COUNT {return 0, 0, false}
	p := PARAMETERS[index]
	if p.continuous {
		return 0, CONTINUOUS_DENOMINATOR - 1, true
	}

	lo, hi = 0, p.state_count - 1
	if p.display_keyed {
		found := false
		states := PARAMETER_STATES[p.state_offset:][:p.state_count]
		for state in states {
			value, is_int := display_integer(state.display)
			if !is_int {continue}
			if !found {
				lo, hi, found = value, value, true
			} else {
				lo = min(lo, value)
				hi = max(hi, value)
			}
		}
		if found {lo = min(lo, 0)}
	} else if p.out_of_range == .Continue_Grid {
		hi = max(hi, 127)
	}

	// A reference default is part of the live domain even when it sits one step
	// beyond the measured table (parameter 21 is the concrete case).
	lo = min(lo, p.default)
	hi = max(hi, p.default)
	return lo, hi, true
}

// The table position selected by a stored integer. This is the shared inverse
// used by host display adapters and by controller motion, and it is the state the
// engine sounds. It follows the display-keyed rule of parameter_norm for every
// stored integer that has a display, and differs from it where there is none: see
// `display_state_clamped` for what the reference's sound does there.
parameter_position :: proc "contextless" (index, stored: int) -> (position: int, ok: bool) {
	states := parameter_states(index)
	if len(states) == 0 {return 0, false}
	p := PARAMETERS[index]
	if p.display_keyed {
		for state, i in states {
			if value, is_int := display_integer(state.display); is_int && value == stored {
				return i, true
			}
		}
		if clamped, found := display_state_clamped(states, stored); found {
			return clamped, true
		}
	} else if stored >= 0 && stored < len(states) {
		return stored, true
	}
	if stored < 0 {return 0, true}
	return len(states) - 1, true
}

// For a display-keyed parameter, the state a stored integer that matches none of
// the displays sounds as: the integer is clamped into the range the displays span
// and then looked up, so below the range it is the state with the smallest display,
// and otherwise the state with the largest display under it. That is the last state
// past the end of an ascending range, and the lower neighbour in a gap (chorus type
// 3, between displays 2 and 4, sounds as 2). Where the displays are not in order the
// answer is still by value and not by position: the LFO types run 0, 1, 5, 2, 3, 4,
// so a stored 6 or more sounds as display 5, which is the third state and not the
// last.
//
// This is what the reference's *sound* does, and it is not what its read-back
// reports. `getParameter` answers the top state for a stored 0 on every one of
// these parameters (`parameter_norm` models that, and is right about it), but a
// render at stored 0 is identical to one at the first display, and stored values
// above the range are identical to the last. Measured on one note with only that
// parameter changed, for oscillator 2 shape, both LFO destinations, both LFO types,
// chorus type, unison voices and polyphony.
display_state_clamped :: proc "contextless" (states: []Parameter_State, stored: int) -> (position: int, found: bool) {
	at_or_below, lowest := -1, -1
	below_value, lowest_value := 0, 0
	for state, i in states {
		value, is_int := display_integer(state.display)
		if !is_int {continue}
		if lowest < 0 || value < lowest_value {
			lowest, lowest_value = i, value
		}
		if value <= stored && (at_or_below < 0 || value > below_value) {
			at_or_below, below_value = i, value
		}
	}
	if at_or_below >= 0 {return at_or_below, true}
	if lowest >= 0 {return lowest, true}
	return 0, false
}

// The stored integer selecting a table position, inverse to parameter_position
// for every measured state.
parameter_stored_at_position :: proc "contextless" (index, position: int) -> (stored: int, ok: bool) {
	states := parameter_states(index)
	if position < 0 || position >= len(states) {return 0, false}
	if PARAMETERS[index].display_keyed {
		if value, is_int := display_integer(states[position].display); is_int {
			return value, true
		}
	}
	return position, true
}

// The value the plugin reports for a state index, including indices past the
// end of the table.
//
// The operation order is measured, not chosen: the plugin forms the reciprocal
// once and scales both terms by it. Dividing by the state count instead lands
// one ulp away on several stored values, index 33 storing 42 being the clearest.
parameter_grid_norm :: proc(state, state_count: int) -> f32 {
	step := f32(1) / f32(state_count)
	return f32(state) * step + 0.5 * step
}

// The normalised value the reference plugin reports after loading `stored` into
// `index`. `ok` is false only for a parameter index outside the live table.
parameter_norm :: proc(index, stored: int) -> (norm: f32, ok: bool) {
	if index < 0 || index >= PARAMETER_COUNT {return 0, false}
	p := PARAMETERS[index]

	// 86..89 are not on the state convention at all: they read back a 1/65536
	// grid across their whole range rather than a small set of states.
	if p.continuous {
		return f32(stored + 1) / f32(CONTINUOUS_DENOMINATOR), true
	}

	states := PARAMETER_STATES[p.state_offset:][:p.state_count]
	if len(states) == 0 {return 0, false}

	if p.display_keyed {
		for s in states {
			if d, is_int := display_integer(s.display); is_int && d == stored {
				return s.norm, true
			}
		}
	} else if stored >= 0 && stored < len(states) {
		return states[stored].norm, true
	}

	// No state holds this integer.
	if p.out_of_range == .Clamp_To_Top {
		return states[len(states) - 1].norm, true
	}

	// Free-running: the stored integer stays on the table's own uniform grid,
	// shifted so the lowest display sits on state 0. The result deliberately
	// leaves 0..1 for a value far enough out, exactly as the plugin's does.
	offset := 0
	if p.display_keyed {
		if base, is_int := display_integer(states[0].display); is_int {
			offset = -base
		}
	}
	return parameter_grid_norm(stored + offset, len(states)), true
}
