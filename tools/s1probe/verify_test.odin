package s1probe

import "core:math"
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

@(test)
test_fmsub_gate_selection_excludes_confounded_records :: proc(t: ^testing.T) {
	base := neutral_probe_patch()
	base.values[45] = 1
	base.values[95] = 32
	testing.expect(t, fmsub_gate_selected(&base), "plain FM + sub record must be selected")

	for index in ([]int{6, 7, 73}) {
		confounded := base
		confounded.values[index] = 1
		testing.expectf(t, !fmsub_gate_selected(&confounded),
			"FM + sub record with confounder parameter %d was selected", index)
	}

	mod_env := base
	mod_env.values[10] = 1
	mod_env.values[71] = 1 // FM destination
	testing.expect(t, !fmsub_gate_selected(&mod_env), "FM modulation envelope was selected")

	lfo := base
	lfo.values[57] = 1
	lfo.values[41] = 6 // displayed destination 6: FM
	testing.expect(t, !fmsub_gate_selected(&lfo), "FM-targeting LFO was selected")
}

@(test)
test_fmsub_gate_cases_are_matched_source_transforms :: proc(t: ^testing.T) {
	source := neutral_probe_patch()
	source.values[45] = 43
	source.values[95] = 96

	original := source
	fmsub_apply_case(&original, FMSUB_CASE_ORIGINAL)
	testing.expect(t, fmsub_same_record(&source, &original), "original case changed the source record")

	fm_off := source
	fmsub_apply_case(&fm_off, FMSUB_CASE_FM_OFF)
	testing.expect_value(t, fm_off.values[45], 0)
	testing.expect_value(t, fm_off.values[95], 96)

	all_off := source
	fmsub_apply_case(&all_off, FMSUB_CASE_ALL_OFF)
	testing.expect_value(t, all_off.values[45], 0)
	testing.expect_value(t, all_off.values[95], 0)

	other := source
	other.name = "a different bank label"
	testing.expect(t, fmsub_same_record(&source, &other),
		"deduplication must use the parameter record, not patch metadata")
}

@(test)
test_fmsub_slope_distinguishes_displacement_laws :: proc(t: ^testing.T) {
	frames := 72000
	base_carrier := make([]f32, frames * 2)
	base_mix := make([]f32, frames * 2)
	fm_carrier := make([]f32, frames * 2)
	fm_mix := make([]f32, frames * 2)
	defer delete(base_carrier)
	defer delete(base_mix)
	defer delete(fm_carrier)
	defer delete(fm_mix)

	f0: f64 = 440.0 * math.pow(f64(2.0), f64((48.0 - 69.0) / 12.0))
	for law in ([]f64{0, 0.5, 1.0}) {
		for i in 0 ..< frames {
			time := f64(i) / f64(SAMPLE_RATE)
			phase := 2.0 * math.PI * f0 * time
			displacement := 0.25 * math.sin(2.0 * math.PI * 7.0 * time) + 0.4 * time
			carrier0 := f32(math.sin(phase))
			sub0 := f32(math.sin(phase / 2.0))
			carrier := f32(math.sin(phase + displacement))
			sub := f32(math.sin(phase / 2.0 + law * displacement))
			for channel in 0 ..< 2 {
				at := i * 2 + channel
				base_carrier[at] = carrier0
				base_mix[at] = (carrier0 + 4.0 * sub0) / 5.0
				fm_carrier[at] = carrier
				fm_mix[at] = (carrier + 4.0 * sub) / 5.0
			}
		}
		slope, points := fmsub_slope(base_carrier, base_mix, fm_carrier, fm_mix, 48)
		testing.expect_value(t, points, 26)
		testing.expectf(t, abs(slope - law) < 0.01,
			"known FM-to-sub law %.1f measured as %.6f", law, slope)
	}
}
