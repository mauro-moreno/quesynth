package synth_clap

import "core:strconv"

import "../../src/patch"

// The parameter adapter.
//
// The whole plugin uses one representation for a parameter value: the stored
// .sy1 integer. That is the same number a patch file holds, the same number
// `patch.parameter_norm` resolves against the measured state tables, and the
// same number `engine.bind_patch` reads. Carrying anything else -- a 0..1
// normalised value, say -- would mean two conversions per parameter and a
// rounding question at every one of them, and would make the state blob and the
// patch file disagree about what a parameter is.
//
// CLAP is happy with this: a stepped parameter's plain value is an integer, and
// the host is told the range.

PARAM_COUNT :: patch.PARAMETER_COUNT

// The stored integer is 7-bit.
//
// No measured state table in src/patch/params.odin exceeds 128 entries, and
// docs/synth1-param-encoding.md records the reference's stored values over
// 0..135 while noting that no factory patch leaves 0..127. The four continuous
// parameters are the sole exception and carry their own denominator.
STORED_MAX_7BIT :: 127

// The span of display integers across a parameter's states.
//
// This only means anything for a display-keyed parameter, where the stored
// integer *is* the number the reference shows rather than a position in the
// table. `patch.display_integer` decides what counts, and its strictness is
// load-bearing: "00", "+01" and "+15 cent" are deliberately not integers, so a
// parameter that merely looks numeric does not acquire a span it never had.
//
// `ok` is false for a parameter no state of which displays a strict integer.
// All 75 display-keyed parameters in the current table produce a span.
param_display_span :: proc "contextless" (index: int) -> (lo, hi: int, ok: bool) {
	p := patch.PARAMETERS[index]
	if p.continuous {
		return 0, 0, false
	}
	states := patch.PARAMETER_STATES[p.state_offset:][:p.state_count]
	for state in states {
		value, is_int := patch.display_integer(state.display)
		if !is_int {
			continue
		}
		if !ok {
			lo, hi, ok = value, value, true
			continue
		}
		if value < lo {
			lo = value
		}
		if value > hi {
			hi = value
		}
	}
	return
}

// The advertised range of a parameter, as the stored .sy1 integers it accepts.
//
// The range has to hold every stored integer a real patch contains, or the host
// clamps one on the way back in and the patch changes sound. Six parameters in
// the factory bank did exactly that under the earlier rule of 0..state_count-1,
// so the range is derived per parameter from what src/patch says the stored
// integer means:
//
//   display-keyed  The stored integer is the displayed number, so the domain is
//                  the span of display integers, not the span of table
//                  positions. Index 9 shows "-24".."24" and stores exactly
//                  that; index 64's displays are "1", "2", "4", so its domain
//                  reaches 4 even though it holds three states.
//
//                  The bottom is still pulled down to 0, because a display-keyed
//                  parameter legitimately stores 0 even where its displays start
//                  at "1": 111.sy1 contains `46,0`, and
//                  docs/synth1-param-encoding.md notes index 1 storing 0 "shows
//                  0 while actually sitting on the top state". Those parameters
//                  saturate at the top state at both ends, so 0 resolves exactly
//                  as any lower integer would and clamping there loses nothing.
//
//   direct index   The stored integer is a table position, so the domain is the
//                  table -- except when the parameter runs free. A
//                  .Continue_Grid parameter reports a distinct value for every
//                  integer past its table, and the encoding notes say the tables
//                  for indices 33 and 35 "stop at 19 and 20 entries only because
//                  setParameter's 0..1 domain cannot reach beyond that. That is
//                  a limit of the sweep, not of the parameter." Patches store 64
//                  at index 33 and 40 at index 35. Those parameters therefore
//                  get the full 7-bit stored domain; index 85 is the third such
//                  parameter and is widened with them. A .Clamp_To_Top parameter
//                  needs no widening: every integer past its table resolves to
//                  the top state, which is what clamping at the top produces.
//
// The default is measured, never rewritten, so the range is finally stretched to
// contain it. Index 21 has 128 states and a default of 128 and is the only
// parameter that needs it; the condition is written generally so a regenerated
// table cannot reintroduce the problem quietly.
//
// This changes the advertised range of eleven parameters against the plain table
// rule: 1, 9, 31, 33, 35, 41, 46, 64, 85, 93 and 94. Every stored value in the
// 138 patches under patches/incoming lands inside the result, which tests/clap
// asserts.
param_range :: proc "contextless" (index: int) -> (lo, hi: int) {
	ok: bool
	lo, hi, ok = patch.parameter_stored_range(index)
	if !ok {return 0, 0}
	return lo, hi
}

param_min :: proc "contextless" (index: int) -> int {
	lo, _ := param_range(index)
	return lo
}

param_max :: proc "contextless" (index: int) -> int {
	_, hi := param_range(index)
	return hi
}

param_default :: proc "contextless" (index: int) -> int {
	return patch.PARAMETERS[index].default
}

param_name :: proc "contextless" (index: int) -> string {
	return patch.PARAMETERS[index].name
}

// Bring a host-supplied plain value onto the parameter's grid.
//
// CLAP defines a stepped parameter's double as converted to an integer by a
// cast, so truncation is the specified rounding. A non-finite value is rejected
// by the caller rather than silently becoming zero.
param_clamp :: proc "contextless" (index: int, value: f64) -> (stored: int, ok: bool) {
	if value != value {
		return 0, false
	}
	lo := param_min(index)
	hi := param_max(index)
	if value <= f64(lo) {
		return lo, true
	}
	if value >= f64(hi) {
		return hi, true
	}
	return int(value), true
}

// The text a host should show for a stored value.
//
// Where the measured state table holds a display string that is not simply the
// integer -- "100 : 0" for the oscillator mix, "L 100%" for pan -- that string
// is the reference plugin's own text and is used verbatim. Display-keyed
// parameters store the displayed integer itself, so their text and their value
// are the same characters either way.
param_text :: proc "contextless" (index: int, stored: int) -> (text: string, ok: bool) {
	p := patch.PARAMETERS[index]
	if p.continuous {
		return "", false
	}
	if p.display_keyed {
		return "", false
	}
	states := patch.PARAMETER_STATES[p.state_offset:][:p.state_count]
	if stored < 0 || stored >= len(states) {
		return "", false
	}
	return states[stored].display, true
}

// Parse host text back into a stored integer.
//
// This has to be the inverse of `param_text`, because a host converts a value
// to text, hands that same text back, and expects to land on the value it
// started from. Reading the text as a plain number is not that inverse: state 3
// of parameter 2 displays "-58", and parsing "-58" as a number lands on the
// bottom of the range instead of on state 3.
//
// So a direct-index parameter is parsed against its measured displays first.
// The first state whose display matches wins; displays repeat ("-60" is both
// state 0 and state 1 of parameter 2), and taking the first keeps the parse a
// function, which is what makes text -> value -> text stable.
//
// A display-keyed parameter is not parsed that way, and must not be: its stored
// integer *is* the number it shows, so the state whose display reads "5" is
// selected by the value 5, not by that state's position. Parameter 9 shows
// "-24".."24", which puts "5" at position 29; matching on the display there
// would answer 29 to a question whose answer is 5. The same goes for the four
// continuous parameters, which have no displays at all.
param_parse :: proc(index: int, text: string) -> (stored: int, ok: bool) {
	if index < 0 || index >= PARAM_COUNT {
		return 0, false
	}
	p := patch.PARAMETERS[index]
	if !p.continuous && !p.display_keyed {
		states := patch.PARAMETER_STATES[p.state_offset:][:p.state_count]
		for state, position in states {
			if state.display == text {
				return position, true
			}
		}
	}

	// No display explains the text. It is either a parameter whose text is the
	// number itself, or a value outside the table, which `param_text` also
	// renders as a bare number.
	value := strconv.parse_int(text, 10) or_return
	return param_clamp(index, f64(value))
}
