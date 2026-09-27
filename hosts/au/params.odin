#+build darwin
package synth_au

import "../../src/patch"

// The parameter adapter, the same shape hosts/clap uses: the whole plugin keeps
// one representation for a value, the stored .sy1 integer, and tells the host the
// range. An Audio Unit parameter is a Float32 within [min, max]; a stored integer
// fits that exactly, so the value carried across the AU edge is the integer as a
// float and no second representation is introduced.

PARAM_COUNT :: patch.PARAMETER_COUNT

param_range :: proc "contextless" (index: int) -> (lo, hi: int) {
	ok: bool
	lo, hi, ok = patch.parameter_stored_range(index)
	if !ok {
		return 0, 0
	}
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

// Clamp a host-supplied float onto the parameter's integer grid.
param_clamp :: proc "contextless" (index: int, value: f32) -> int {
	if value != value {
		return param_default(index)
	}
	lo := param_min(index)
	hi := param_max(index)
	if value <= f32(lo) {
		return lo
	}
	if value >= f32(hi) {
		return hi
	}
	return int(value)
}
