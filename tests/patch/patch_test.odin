package patch_tests

import "core:testing"
import patch "../../src/patch"

@(test)
test_sy1_fields_and_defaults :: proc(t: ^testing.T) {
	text := "Synth1  Test Name  \r\ncolor=violet\r\nver=105\r\n0,17\r\n45,0"
	data := transmute([]byte)text
	got, err := patch.parse_sy1(data)
	testing.expect_value(t, err, patch.Sy1_Error.None)
	testing.expect_value(t, got.name, " Test Name  ")
	testing.expect_value(t, got.color, "violet")
	testing.expect_value(t, got.version, 105)
	testing.expect_value(t, got.values[0], 17)
	testing.expect_value(t, got.present[0], true)
	testing.expect_value(t, got.present[45], true)
	testing.expect_value(t, got.present[1], false)
	testing.expect_value(t, got.values[1], patch.PARAMETERS[1].default)
	testing.expect_value(t, got.present[2], false)
	testing.expect_value(t, got.values[2], 64)
	testing.expect_value(t, got.present[21], false)
	testing.expect_value(t, got.values[21], 128)
}

@(test)
test_sy1_index_errors :: proc(t: ^testing.T) {
	text_99 := "Synth1 x\ncolor=default\nver=105\n99,1\n"
	_, err_99 := patch.parse_sy1(transmute([]byte)text_99)
	testing.expect_value(t, err_99, patch.Sy1_Error.Index_Out_Of_Range)

	text_100 := "Synth1 x\ncolor=default\nver=105\n100,1\n"
	_, err_100 := patch.parse_sy1(transmute([]byte)text_100)
	testing.expect_value(t, err_100, patch.Sy1_Error.Index_Out_Of_Range)

	text := "Synth1 x\ncolor=default\nver=105\n0,nope\n"
	_, err := patch.parse_sy1(transmute([]byte)text)
	testing.expect_value(t, err, patch.Sy1_Error.Invalid_Value)
}

@(test)
test_sy1_lf_and_crlf :: proc(t: ^testing.T) {
	crlf := "Synth1 x\r\ncolor=default\r\nver=105\r\n0,7\r\n45,2\r\n"
	lf := "Synth1 x\ncolor=default\nver=105\n0,7\n45,2\n"
	a, aerr := patch.parse_sy1(transmute([]byte)crlf)
	b, berr := patch.parse_sy1(transmute([]byte)lf)
	testing.expect_value(t, aerr, patch.Sy1_Error.None)
	testing.expect_value(t, berr, patch.Sy1_Error.None)
	testing.expect_value(t, a.name, b.name)
	testing.expect_value(t, a.color, b.color)
	testing.expect_value(t, a.version, b.version)
	testing.expect_value(t, a.values[0], b.values[0])
	testing.expect_value(t, a.values[45], b.values[45])
}

@(test)
test_sy1_blank_lines :: proc(t: ^testing.T) {
	text := "Synth1 x\ncolor=default\nver=105\n0,7\n\n45,2\n\n"
	got, err := patch.parse_sy1(transmute([]byte)text)
	testing.expect_value(t, err, patch.Sy1_Error.None)
	testing.expect_value(t, got.values[0], 7)
	testing.expect_value(t, got.values[45], 2)
	testing.expect_value(t, got.present[0], true)
	testing.expect_value(t, got.present[45], true)
}

@(test)
test_sy1_record_whitespace :: proc(t: ^testing.T) {
	plain := "Synth1 x\ncolor=default\nver=105\n0,7\n45,2"
	padded := "Synth1 x\ncolor=default\nver=105\n  0  ,  7  \n\t45\t,\t2\t"
	a, aerr := patch.parse_sy1(transmute([]byte)plain)
	b, berr := patch.parse_sy1(transmute([]byte)padded)
	testing.expect_value(t, aerr, patch.Sy1_Error.None)
	testing.expect_value(t, berr, patch.Sy1_Error.None)
	testing.expect_value(t, b.values[0], a.values[0])
	testing.expect_value(t, b.values[45], a.values[45])
	testing.expect_value(t, b.present[0], a.present[0])
	testing.expect_value(t, b.present[45], a.present[45])
}

@(test)
test_sy1_whitespace_range_error :: proc(t: ^testing.T) {
	text_99 := "Synth1 x\ncolor=default\nver=105\n  99,1  "
	_, err_99 := patch.parse_sy1(transmute([]byte)text_99)
	testing.expect_value(t, err_99, patch.Sy1_Error.Index_Out_Of_Range)

	text_100 := "Synth1 x\ncolor=default\nver=105\n100,1"
	_, err_100 := patch.parse_sy1(transmute([]byte)text_100)
	testing.expect_value(t, err_100, patch.Sy1_Error.Index_Out_Of_Range)
}

@(test)
test_sy1_malformed_records :: proc(t: ^testing.T) {
	no_comma := "Synth1 x\ncolor=default\nver=105\n0 1"
	_, no_comma_err := patch.parse_sy1(transmute([]byte)no_comma)
	testing.expect_value(t, no_comma_err, patch.Sy1_Error.Malformed_Line)

	two_commas := "Synth1 x\ncolor=default\nver=105\n0,1,2"
	_, two_commas_err := patch.parse_sy1(transmute([]byte)two_commas)
	testing.expect_value(t, two_commas_err, patch.Sy1_Error.Malformed_Line)

	empty_value := "Synth1 x\ncolor=default\nver=105\n0,"
	_, empty_value_err := patch.parse_sy1(transmute([]byte)empty_value)
	testing.expect_value(t, empty_value_err, patch.Sy1_Error.Malformed_Line)

	non_numeric := "Synth1 x\ncolor=default\nver=105\n0,nope"
	_, non_numeric_err := patch.parse_sy1(transmute([]byte)non_numeric)
	testing.expect_value(t, non_numeric_err, patch.Sy1_Error.Invalid_Value)
}

@(test)
test_generated_default_ordinals :: proc(t: ^testing.T) {
	testing.expect_value(t, patch.PARAMETERS[2].default, 64)
	testing.expect_value(t, patch.PARAMETERS[3].default, 81)
	// The reference genuinely defaults one step above its top state, on the
	// free-running grid, so the stored default is 128 against 128 states.
	testing.expect_value(t, patch.PARAMETERS[21].default, 128)
	testing.expect_value(t, patch.PARAMETERS[37].default, 20)
	testing.expect_value(t, patch.PARAMETERS[41].default, 2)
	testing.expect_value(t, patch.PARAMETERS[54].default, 50)
	testing.expect_value(t, patch.PARAMETERS[61].default, 64)
	testing.expect_value(t, patch.PARAMETERS[83].default, 66)
}

// The generated table must carry the measured state tables, not a step count.
@(test)
test_generated_state_tables :: proc(t: ^testing.T) {
	testing.expect_value(t, patch.PARAMETER_COUNT, 99)
	testing.expect_value(t, patch.PARAMETER_STATE_COUNT, 7350)

	testing.expect_value(t, len(patch.parameter_states(0)), 4)
	testing.expect_value(t, len(patch.parameter_states(9)), 49)
	testing.expect_value(t, len(patch.parameter_states(33)), 19)
	testing.expect_value(t, len(patch.parameter_states(35)), 20)
	testing.expect_value(t, len(patch.parameter_states(41)), 7)
	testing.expect_value(t, len(patch.parameter_states(64)), 3)
	testing.expect_value(t, len(patch.parameter_states(2)), 128)

	// Index 94 is unnamed in the plugin but is real.
	testing.expect_value(t, patch.PARAMETERS[94].name, "polyphony")

	// 86..89 are continuous and carry no state table at all, so nothing can
	// slice one out of them by accident.
	for index in ([]int{86, 87, 88, 89}) {
		testing.expect_value(t, patch.PARAMETERS[index].continuous, true)
		testing.expect_value(t, len(patch.parameter_states(index)), 0)
	}
}

// The 179-mismatch bug. Indices 41 and 46 have canonical norms 0.2..0.8, which
// no uniform formula produces: (n + 0.5) / 7 gives 0.214.., 0.357.., 0.5, ...
// Reading the canonical value out of the state table is the only correct way.
@(test)
test_lfo_destination_norms_are_not_uniform :: proc(t: ^testing.T) {
	for index in ([]int{41, 46}) {
		// Stored 1 selects the state displaying "1", whose norm is 0.2.
		norm_1, ok_1 := patch.parameter_norm(index, 1)
		testing.expect_value(t, ok_1, true)
		testing.expect_value(t, norm_1, f32(0.200000003))

		norm_5, ok_5 := patch.parameter_norm(index, 5)
		testing.expect_value(t, ok_5, true)
		testing.expect_value(t, norm_5, f32(0.600000024))

		// A uniform step count would have produced these instead; if the
		// implementation ever regresses to arithmetic, these become equal.
		uniform_1 := (f32(1) + 0.5) / f32(7)
		uniform_5 := (f32(5) + 0.5) / f32(7)
		testing.expect(t, norm_1 != uniform_1, "41/46 stored 1 must not be (n+0.5)/7")
		testing.expect(t, norm_5 != uniform_5, "41/46 stored 5 must not be (n+0.5)/7")
	}
}

// Resolution order: rule 1 for index 1, rule 2 for index 2. Neither alone works.
@(test)
test_resolution_order_display_match_then_state_index :: proc(t: ^testing.T) {
	// Index 1 displays "1".."4" over 4 states. Stored 4 is a display, not an
	// index: treating it as an index would overflow the table.
	norm_4, ok_4 := patch.parameter_norm(1, 4)
	testing.expect_value(t, ok_4, true)
	testing.expect_value(t, norm_4, patch.parameter_states(1)[3].norm)
	testing.expect_value(t, patch.PARAMETERS[1].display_keyed, true)

	// Index 2 displays -60..+60 over 128 states. Stored 64 matches no display,
	// so it is a direct state index.
	norm_64, ok_64 := patch.parameter_norm(2, 64)
	testing.expect_value(t, ok_64, true)
	testing.expect_value(t, norm_64, f32(0.50390625))
	testing.expect_value(t, norm_64, patch.parameter_states(2)[64].norm)
	testing.expect_value(t, patch.PARAMETERS[2].display_keyed, false)
}

// Measured out-of-range behaviour for indices 33 and 35: the plugin does not
// clamp. It keeps walking the uniform grid, well past 1.0.
@(test)
test_out_of_range_continues_the_grid :: proc(t: ^testing.T) {
	beat_35, ok_35 := patch.parameter_norm(33, 35)
	testing.expect_value(t, ok_35, true)
	testing.expect_value(t, beat_35, f32(1.868421078))

	beat_42, ok_42 := patch.parameter_norm(33, 42)
	testing.expect_value(t, ok_42, true)
	testing.expect_value(t, beat_42, f32(2.236841917))

	beat_64, ok_64 := patch.parameter_norm(33, 64)
	testing.expect_value(t, ok_64, true)
	testing.expect_value(t, beat_64, f32(3.394736767))

	delay_27, ok_27 := patch.parameter_norm(35, 27)
	testing.expect_value(t, ok_27, true)
	testing.expect_value(t, delay_27, f32(1.375))

	delay_40, ok_40 := patch.parameter_norm(35, 40)
	testing.expect_value(t, ok_40, true)
	testing.expect_value(t, delay_40, f32(2.025000095))

	// These genuinely leave 0..1, which is why verify cannot drive the plugin
	// through setParameter: that call saturates.
	testing.expect(t, beat_64 > 1.0, "index 33 stored 64 reads back above 1.0")
	testing.expect(t, delay_40 > 1.0, "index 35 stored 40 reads back above 1.0")
}

// Measured out-of-range behaviour for display-keyed parameters: saturate at the
// top state, at both ends. 111.sy1 stores 46,0 and the plugin lands on state 6.
@(test)
test_out_of_range_clamps_to_top_state :: proc(t: ^testing.T) {
	states_46 := patch.parameter_states(46)
	norm_0, ok_0 := patch.parameter_norm(46, 0)
	testing.expect_value(t, ok_0, true)
	testing.expect_value(t, norm_0, f32(0.800000012))
	testing.expect_value(t, norm_0, states_46[len(states_46) - 1].norm)
	// Not state 0, which is what a direct state index would have selected.
	testing.expect(t, norm_0 != states_46[0].norm, "46,0 is not state 0")

	// Index 64 displays 1, 2, 4: display "3" does not exist, so stored 3 is
	// out of range and saturates rather than selecting a third state.
	states_64 := patch.parameter_states(64)
	norm_3, ok_3 := patch.parameter_norm(64, 3)
	testing.expect_value(t, ok_3, true)
	testing.expect_value(t, norm_3, f32(0.875))
	testing.expect_value(t, norm_3, states_64[len(states_64) - 1].norm)
}

// 86..89 are not on the 0..127 convention: they read back a 1/65536 grid.
@(test)
test_continuous_parameters :: proc(t: ^testing.T) {
	testing.expect_value(t, patch.CONTINUOUS_DENOMINATOR, 65536)
	for index in ([]int{86, 87, 88, 89}) {
		norm_0, ok_0 := patch.parameter_norm(index, 0)
		testing.expect_value(t, ok_0, true)
		testing.expect_value(t, norm_0, f32(1) / f32(65536))

		norm_127, ok_127 := patch.parameter_norm(index, 127)
		testing.expect_value(t, ok_127, true)
		testing.expect_value(t, norm_127, f32(128) / f32(65536))

		// Emphatically not the 0..127 switch convention.
		testing.expect(t, norm_127 < 0.01, "continuous parameters are not 0..127 states")
	}
}

// Display matching is strict: one integer must have exactly one spelling, or
// rule 1 fires on parameters that are really direct state indices.
@(test)
test_display_integer_is_strict :: proc(t: ^testing.T) {
	value, ok := patch.display_integer("-24")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, -24)

	zero, zero_ok := patch.display_integer("0")
	testing.expect_value(t, zero_ok, true)
	testing.expect_value(t, zero, 0)

	// Rejected forms, each of which appears in a real display string.
	for text in ([]string{"+01", "00", "-0", "007", "", "+15 cent", "0.99 Hz", "L 100%", "(16)+(32)", " 3"}) {
		_, bad := patch.display_integer(text)
		testing.expect(t, !bad, "display_integer must reject non-canonical text")
	}
}

@(test)
test_parameter_norm_rejects_indices_outside_the_table :: proc(t: ^testing.T) {
	_, low := patch.parameter_norm(-1, 0)
	testing.expect_value(t, low, false)
	_, high := patch.parameter_norm(patch.PARAMETER_COUNT, 0)
	testing.expect_value(t, high, false)
}

write_be_u32 :: proc(data: []byte, at: int, value: u32) {
	data[at] = byte(value >> 24)
	data[at+1] = byte(value >> 16)
	data[at+2] = byte(value >> 8)
	data[at+3] = byte(value)
}

init_fxb_header :: proc(data: []byte, byte_size, fx_magic: u32) {
	write_be_u32(data, 0, 0x43636e4b) // CcnK
	write_be_u32(data, 4, byte_size)
	write_be_u32(data, 8, fx_magic)
	write_be_u32(data, 12, 1)
	write_be_u32(data, 16, 0x53314e54)
	write_be_u32(data, 20, 1)
	write_be_u32(data, 24, 128)
}

@(test)
test_fxb_layouts :: proc(t: ^testing.T) {
	// Valid chunk whose declared container ends exactly at its payload.
	chunk := make([]byte, 163)
	defer delete(chunk)
	init_fxb_header(chunk, 155, 0x46424368) // FBCh, declared end 163
	write_be_u32(chunk, 156, 3)
	chunk[160] = 0x11
	chunk[161] = 0x22
	chunk[162] = 0x33
	bank, err := patch.parse_fxb(chunk)
	testing.expect_value(t, err, patch.Fxb_Error.None)
	testing.expect_value(t, bank.kind, patch.Fxb_Kind.Chunk_Bank)
	testing.expect_value(t, len(bank.chunk), 3)
	testing.expect_value(t, bank.chunk[0], byte(0x11))
	testing.expect_value(t, bank.chunk[2], byte(0x33))

	// Backing bytes after a valid declared container are ignored.
	extra := make([]byte, 170)
	defer delete(extra)
	init_fxb_header(extra, 155, 0x46424368)
	write_be_u32(extra, 156, 3)
	extra[160] = 0x44
	extra[161] = 0x55
	extra[162] = 0x66
	extra[163] = 0x77
	extra[164] = 0x88
	extra_bank, extra_err := patch.parse_fxb(extra)
	testing.expect_value(t, extra_err, patch.Fxb_Error.None)
	testing.expect_value(t, len(extra_bank.chunk), 3)
	testing.expect_value(t, extra_bank.chunk[0], byte(0x44))
	testing.expect_value(t, extra_bank.chunk[2], byte(0x66))

	// A chunk extending beyond the declared container is rejected.
	short_declared := make([]byte, 163)
	defer delete(short_declared)
	init_fxb_header(short_declared, 148, 0x46424368) // declared end 156
	write_be_u32(short_declared, 156, 3)
	short_bank, short_err := patch.parse_fxb(short_declared)
	testing.expect_value(t, short_err, patch.Fxb_Error.Truncated)
	testing.expect_value(t, len(short_bank.chunk), 0)

	short_payload := make([]byte, 164)
	defer delete(short_payload)
	init_fxb_header(short_payload, 155, 0x46424368) // declared end 163
	write_be_u32(short_payload, 156, 4)
	short_payload_bank, short_payload_err := patch.parse_fxb(short_payload)
	testing.expect_value(t, short_payload_err, patch.Fxb_Error.Truncated)
	testing.expect_value(t, len(short_payload_bank.chunk), 0)

	program := make([]byte, 156)
	defer delete(program)
	init_fxb_header(program, 148, 0x4678426b) // FxBk
	program_bank, program_err := patch.parse_fxb(program)
	testing.expect_value(t, program_err, patch.Fxb_Error.None)
	testing.expect_value(t, program_bank.kind, patch.Fxb_Kind.Program_Bank)
	testing.expect_value(t, len(program_bank.chunk), 0)

	_, short_program_err := patch.parse_fxb(program[:100])
	testing.expect_value(t, short_program_err, patch.Fxb_Error.Truncated)
}

// -- the JSON patch and bank format ------------------------------------------

// A patch survives being written and read back with every parameter intact.
//
// This is the property the format exists for, and it is checked over all
// ninety-nine parameters rather than a sample: the failure mode of a name-keyed
// format is one name that does not round-trip, and a spot check is exactly what
// would miss it.
@(test)
json_patch_round_trips :: proc(t: ^testing.T) {
	original: patch.Patch
	original.name = "Round Trip"
	for i in 0 ..< patch.PARAMETER_COUNT {
		// Values that are neither the default nor all the same, so a writer
		// that emitted a constant, or the default table, would fail here.
		original.values[i] = (i * 7 + 3) % 128
		original.present[i] = true
	}

	text := patch.write_patch_json(original)
	defer delete(text)

	restored, err := patch.parse_patch_json(transmute([]u8)text)
	defer patch.destroy_patch(restored)
	testing.expect_value(t, err, patch.Json_Error.None)
	testing.expect_value(t, restored.name, "Round Trip")
	for i in 0 ..< patch.PARAMETER_COUNT {
		if restored.values[i] != original.values[i] {
			testing.expectf(
				t,
				false,
				"parameter %v (%v): wrote %v, read %v",
				i,
				patch.PARAMETERS[i].name,
				original.values[i],
				restored.values[i],
			)
			return
		}
	}
}

// Every parameter name is unique, which is what makes a name-keyed object a
// safe encoding at all. If two ever collided, one would silently overwrite the
// other on write and the round trip above would start failing in a way that
// looked like a reader bug.
@(test)
json_parameter_names_are_unique :: proc(t: ^testing.T) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		for j in i + 1 ..< patch.PARAMETER_COUNT {
			if patch.PARAMETERS[i].name == patch.PARAMETERS[j].name {
				testing.expectf(t, false, "parameters %v and %v share the name %q", i, j, patch.PARAMETERS[i].name)
				return
			}
		}
		testing.expect_value(t, patch.parameter_index(patch.PARAMETERS[i].name), i)
	}
}

// A name this build does not know is refused rather than ignored. Silently
// dropping it would load something that is not the patch in the file.
@(test)
json_rejects_unknown_parameter :: proc(t: ^testing.T) {
	text: string = `{"format":"quesynth.patch","version":1,"name":"x","parameters":{"not a real parameter":1}}`
	bad, err := patch.parse_patch_json(transmute([]u8)text)
	defer patch.destroy_patch(bad)
	testing.expect_value(t, err, patch.Json_Error.Unknown_Parameter)
}

// A missing parameter takes its default, which is what lets a file written by
// version 1 still load after a parameter is added.
@(test)
json_missing_parameter_takes_default :: proc(t: ^testing.T) {
	text: string = `{"format":"quesynth.patch","version":1,"name":"x","parameters":{"osc1 shape":3}}`
	p, err := patch.parse_patch_json(transmute([]u8)text)
	defer patch.destroy_patch(p)
	testing.expect_value(t, err, patch.Json_Error.None)
	testing.expect_value(t, p.values[0], 3)
	testing.expect_value(t, p.values[1], patch.PARAMETERS[1].default)
	testing.expect(t, p.present[0], "a named parameter should be marked present")
	testing.expect(t, !p.present[1], "an omitted parameter should not be marked present")
}

// The header is checked, so a bank cannot be loaded as a patch and a future
// version cannot be read as if it were this one.
@(test)
json_checks_the_header :: proc(t: ^testing.T) {
	bank_text: string = `{"format":"quesynth.bank","version":1}`
	_, wrong := patch.parse_patch_json(transmute([]u8)bank_text)
	testing.expect_value(t, wrong, patch.Json_Error.Wrong_Format)

	future_text: string = `{"format":"quesynth.patch","version":99}`
	_, future := patch.parse_patch_json(transmute([]u8)future_text)
	testing.expect_value(t, future, patch.Json_Error.Unsupported_Version)

	broken_text: string = `not json at all`
	_, broken := patch.parse_patch_json(transmute([]u8)broken_text)
	testing.expect_value(t, broken, patch.Json_Error.Invalid_Json)
}

// A bank carries its patches in order and each one keeps its own values.
@(test)
json_bank_round_trips :: proc(t: ^testing.T) {
	patches := make([]patch.Patch, 3)
	defer delete(patches)
	names := [?]string{"First", "Second", "Third"}
	for i in 0 ..< 3 {
		patches[i].name = names[i]
		for j in 0 ..< patch.PARAMETER_COUNT {
			patches[i].values[j] = (i * 31 + j) % 128
			patches[i].present[j] = true
		}
	}

	text := patch.write_bank_json("Test Bank", patches)
	defer delete(text)

	bank, err := patch.parse_bank_json(transmute([]u8)text)
	defer patch.destroy_bank(bank)
	testing.expect_value(t, err, patch.Json_Error.None)
	testing.expect_value(t, bank.name, "Test Bank")
	testing.expect_value(t, len(bank.patches), 3)
	for i in 0 ..< len(bank.patches) {
		testing.expect_value(t, bank.patches[i].name, names[i])
		for j in 0 ..< patch.PARAMETER_COUNT {
			testing.expect_value(t, bank.patches[i].values[j], patches[i].values[j])
		}
	}
}

// A whole number written as a float is accepted, because a file produced by a
// language whose numbers are all doubles will say 64.0; a fraction is not,
// because there is no state between two stored integers.
@(test)
json_number_forms :: proc(t: ^testing.T) {
	whole_text: string = `{"format":"quesynth.patch","version":1,"parameters":{"osc1 shape":2.0}}`
	whole, whole_err := patch.parse_patch_json(transmute([]u8)whole_text)
	defer patch.destroy_patch(whole)
	testing.expect_value(t, whole_err, patch.Json_Error.None)
	testing.expect_value(t, whole.values[0], 2)

	fraction_text: string = `{"format":"quesynth.patch","version":1,"parameters":{"osc1 shape":2.5}}`
	_, fraction_err := patch.parse_patch_json(transmute([]u8)fraction_text)
	testing.expect_value(t, fraction_err, patch.Json_Error.Bad_Value)
}
