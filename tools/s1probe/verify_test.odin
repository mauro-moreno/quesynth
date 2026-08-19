package s1probe

import "core:testing"
import spatch "../../src/patch"

// The chunk slot arithmetic verify writes through. Getting this wrong would
// silently compare parameters against the wrong stored integers, so pin it.
@(test)
test_chunk_slots_are_distinct_and_ordered :: proc(t: ^testing.T) {
	testing.expect_value(t, CHUNK_VALUE_BASE + 0 * CHUNK_VALUE_STRIDE, 572)
	testing.expect_value(t, CHUNK_VALUE_BASE + 33 * CHUNK_VALUE_STRIDE, 836)
	testing.expect_value(t, CHUNK_VALUE_BASE + 98 * CHUNK_VALUE_STRIDE, 1356)

	// Every live parameter gets its own four bytes.
	seen: map[int]bool
	defer delete(seen)
	for i in 0 ..< spatch.PARAMETER_COUNT {
		off := CHUNK_VALUE_BASE + i * CHUNK_VALUE_STRIDE
		testing.expect(t, !(off in seen), "chunk slots must not alias")
		seen[off] = true
	}
	testing.expect_value(t, len(seen), spatch.PARAMETER_COUNT)
}

@(test)
test_chunk_round_trips_signed_stored_values :: proc(t: ^testing.T) {
	// Index 9 is the one parameter factory patches store negative values for,
	// so the slot has to carry a two's-complement i32 intact.
	buf := make([]byte, 64)
	defer delete(buf)
	for v in ([]int{-24, -1, 0, 24, 127, 128}) {
		write_le_u32(buf, 0, u32(i32(v)))
		testing.expect_value(t, int(i32(read_le_u32(buf, 0))), v)
	}
}

// verify reports whether a stored value sat on a state or needed the
// out-of-range rule. The split is informational, but a wrong answer here would
// misdescribe the run, so check both sides against known cases.
@(test)
test_verify_lands_on_state_split :: proc(t: ^testing.T) {
	// Display-keyed: index 41 displays "1".."7", so 1 and 5 land, 0 and 8 do not.
	testing.expect_value(t, verify_lands_on_state(41, 1), true)
	testing.expect_value(t, verify_lands_on_state(41, 5), true)
	testing.expect_value(t, verify_lands_on_state(41, 0), false)
	testing.expect_value(t, verify_lands_on_state(41, 8), false)

	// Direct state index: index 33 has 19 states, so the values ten factory
	// patches store are genuinely off the table.
	testing.expect_value(t, verify_lands_on_state(33, 11), true)
	testing.expect_value(t, verify_lands_on_state(33, 35), false)
	testing.expect_value(t, verify_lands_on_state(33, 42), false)
	testing.expect_value(t, verify_lands_on_state(33, 64), false)

	// Index 2 is a direct state index over its whole 0..127 range.
	testing.expect_value(t, verify_lands_on_state(2, 64), true)
	testing.expect_value(t, verify_lands_on_state(2, 127), true)
	testing.expect_value(t, verify_lands_on_state(2, 128), false)

	// Continuous parameters have no states at all.
	testing.expect_value(t, verify_lands_on_state(86, 0), false)
}

// The whole point of the retarget: verify must compare normalised values, not
// display text. After a chunk load the display echoes the raw stored integer,
// so a display comparison would pass on a value that selects the wrong state.
@(test)
test_expected_norm_disagrees_with_display_echo :: proc(t: ^testing.T) {
	// 111.sy1 stores 46,0. The display reads back "0" but the plugin sits on
	// the top state, 0.8, not on state 0's 0.2.
	norm, ok := spatch.parameter_norm(46, 0)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, norm, f32(0.800000012))

	states := spatch.parameter_states(46)
	testing.expect_value(t, len(states), 7)
	testing.expect(t, states[0].norm != norm, "state 0 must not be what 46,0 selects")
}
