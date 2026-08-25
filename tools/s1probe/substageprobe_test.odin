package s1probe

import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_substage_default_sweeps_the_continuous_p95_curve :: proc(t: ^testing.T) {
	testing.expect_value(t, SUBSTAGE_P95_DEFAULT, "0,16,32,48,64,80,96,112,127")
}

@(test)
test_substage_signed_level_error_is_not_self_referential :: proc(t: ^testing.T) {
	positive, positive_ok := substage_db_error(2.0, 1.0)
	negative, negative_ok := substage_db_error(1.0, 2.0)
	testing.expect(t, positive_ok && negative_ok, "nonzero fabricated amplitudes must be measurable")
	testing.expectf(t, abs(positive - 6.0205999) < 0.0001, "ours-high sign changed: %.6f", positive)
	testing.expectf(t, abs(negative + 6.0205999) < 0.0001, "ours-low sign changed: %.6f", negative)
	noise, noise_ok := substage_db_error(2.0e-8, 1.0e-8, 0.2, 0.2)
	testing.expect(t, !noise_ok && noise == 0,
		"bins below -100 dB of each signal peak must not print as measurements")
	quiet, quiet_ok := substage_db_error(2.0e-8, 1.0e-8, 2.0e-8, 1.0e-8)
	testing.expect(t, quiet_ok && abs(quiet - 6.0205999) < 0.0001,
		"the guard must be signal-relative rather than a fixed amplitude floor")
	testing.expect_value(t, substage_db_text(noise, noise_ok), "-")
}

@(test)
test_substage_signed_ratio_residual :: proc(t: ^testing.T) {
	// Ours has a 2:1 sub/carrier ratio; the reference has 1:1.
	residual, ok := substage_ratio_error(2.0, 1.0, 1.0, 1.0)
	testing.expect(t, ok, "fabricated ratio must be measurable")
	testing.expectf(t, abs(residual - 6.0205999) < 0.0001, "ratio sign changed: %.6f", residual)
	zero, zero_ok := substage_ratio_error(1.0, 0.0, 1.0, 1.0)
	testing.expect(t, !zero_ok && zero == 0, "zero denominator must invalidate a ratio")
}

@(test)
test_substage_fill_errors_preserves_failed_render_status :: proc(t: ^testing.T) {
	rows := []Substage_Row{{
		p95 = 32,
		ref = Substage_Metrics{carrier=1, sub=1, rms=1, peak=1, ok=true},
		ours = Substage_Metrics{carrier=1, sub=1, rms=1, peak=1, ok=true},
		mismatches = 1,
		ok = false,
	}}
	substage_fill_errors(rows)
	testing.expect(t, !rows[0].ok,
		"metric calculation must not overwrite a failed mismatch/render control")
}

@(test)
test_substage_patch_pins_named_factorial_parameters :: proc(t: ^testing.T) {
	p := substage_patch(96, 0, 64, 64)
	testing.expect_value(t, p.values[0], 0)
	testing.expect_value(t, p.values[1], 3)
	testing.expect_value(t, p.values[2], 68)
	testing.expect_value(t, p.values[4], 1)
	testing.expect_value(t, p.values[5], 0)
	testing.expect_value(t, p.values[14], 0)
	testing.expect_value(t, p.values[19], 127)
	testing.expect_value(t, p.values[20], 0)
	testing.expect_value(t, p.values[21], 63)
	testing.expect_value(t, p.values[22], 0)
	testing.expect_value(t, p.values[23], 64)
	testing.expect_value(t, p.values[29], 64)
	testing.expect_value(t, p.values[45], 0)
	testing.expect_value(t, p.values[73], 0)
	testing.expect_value(t, p.values[76], 0)
	testing.expect_value(t, p.values[91], 1)
	testing.expect_value(t, p.values[95], 96)
	testing.expect_value(t, p.values[96], 0)
	testing.expect_value(t, p.values[97], 1)
}

@(test)
test_substage_leakage_covers_every_note_at_requested_gain :: proc(t: ^testing.T) {
	notes := []int{48, 60, 72}
	requests := substage_leakage_requests(notes, 37)
	defer delete(requests)
	testing.expect_value(t, len(requests), len(notes))
	for request, i in requests {
		testing.expect_value(t, request.note, notes[i])
		testing.expect_value(t, request.gain, 37)
	}
	p := substage_leakage_patch(37)
	testing.expect_value(t, p.values[29], 37)
	testing.expect_value(t, p.values[5], 127)
}

@(test)
test_substage_factorial_has_only_preregistered_cells :: proc(t: ^testing.T) {
	notes := []int{48, 60}
	p95s := []int{0, 32, 96}
	mixes := []int{0, 96}
	saturations := []int{0, 64}
	rows := substage_cells(notes, p95s, mixes, saturations, 64)
	defer delete(rows)
	testing.expect_value(t, len(rows), 28)
	for row in rows {
		testing.expect(t, row.p95 == 0 || row.p95 == 32 || row.p95 == 96, "unexpected p95 cell")
		testing.expect(t, row.mix == 0 || row.mix == 96 || row.mix == 127, "unexpected mix cell")
		if row.endpoint {
			testing.expect_value(t, row.mix, 127)
			testing.expect_value(t, row.saturation, 0)
		}
	}
	first := substage_find(rows[:], 60, 96, 96, 64, 64)
	testing.expect(t, first >= 0, "factorial lookup lost a primary cell")
}

@(test)
test_substage_interaction_evaluates_any_swept_p95_and_saturation_without_sign_assumption :: proc(t: ^testing.T) {
	rows := []Substage_Row{
		{note=60, p95=0, mix=0, saturation=0, gain=64, ok=true, level_carrier=1, level_carrier_ok=true},
		{note=60, p95=0, mix=0, saturation=127, gain=64, ok=true, level_carrier=2, level_carrier_ok=true},
		{note=60, p95=48, mix=0, saturation=0, gain=64, ok=true, level_carrier=4, level_carrier_ok=true, ratio_sub=0.25, ratio_sub_ok=true},
		{note=60, p95=48, mix=0, saturation=127, gain=64, ok=true, level_carrier=3, level_carrier_ok=true, ratio_sub=-0.5, ratio_sub_ok=true},
	}
	carrier, ratio, ok := substage_interaction(rows, 60, 48, 0, 0, 127, 64)
	testing.expect(t, ok, "complete custom saturation cell must be evaluated")
	testing.expect_value(t, carrier, -2.0)
	testing.expect_value(t, ratio, -0.75)
}

@(test)
test_substage_endpoint_reports_each_engine_actual_movement :: proc(t: ^testing.T) {
	rows := []Substage_Row{
		{
			note=60, p95=0, mix=127, saturation=0, gain=64, ok=true,
			ref=Substage_Metrics{osc2=1, rms=1, peak=2},
			ours=Substage_Metrics{osc2=2, rms=1, peak=2},
		},
		{
			note=60, p95=96, mix=127, saturation=0, gain=64, ok=true,
			ref=Substage_Metrics{osc2=2, rms=1, peak=2},
			ours=Substage_Metrics{osc2=1, rms=2, peak=2},
		},
	}
	endpoint := substage_endpoint(rows, 60, 0, 96, 127, 0, 64)
	testing.expect(t, endpoint.ok, "measurable endpoint pair must be valid")
	testing.expectf(t, abs(endpoint.ref_osc2 - 6.0205999) < 0.0001,
		"reference endpoint movement was not measured directly: %.6f", endpoint.ref_osc2)
	testing.expectf(t, abs(endpoint.ours_osc2 + 6.0205999) < 0.0001,
		"engine endpoint movement was not measured directly: %.6f", endpoint.ours_osc2)
	testing.expectf(t, abs(endpoint.ref_rms) < 0.0001, "reference RMS endpoint moved: %.6f", endpoint.ref_rms)
	testing.expectf(t, abs(endpoint.ours_rms - 6.0205999) < 0.0001,
		"engine RMS endpoint movement was not measured directly: %.6f", endpoint.ours_rms)
}

@(test)
test_substage_projection_window_matches_preregistered_bounds :: proc(t: ^testing.T) {
	from, to := substage_window(72000)
	testing.expect_value(t, from, 4800)
	testing.expect_value(t, to, 69600)
	f0, f2 := substage_frequency(60)
	testing.expectf(t, abs(f0 - 261.62558) < 0.001, "wrong note frequency %.6f", f0)
	testing.expectf(t, abs(f2 - f0 * math.pow(f64(2.0), f64(4.0 / 12.0))) < 0.0001, "wrong OSC2 frequency %.6f", f2)
}

@(test)
test_substage_csv_is_deterministic_signed_and_marks_invalid_metrics :: proc(t: ^testing.T) {
	rows := []Substage_Row{{
		note=60, p95=32, mix=0, saturation=0, gain=64,
		level_carrier=0.25, level_sub=-0.5,
		level_carrier_ok=true, level_sub_ok=false,
		carrier_norm=0.75, carrier_norm_ok=true, ok=true,
	}}
	text := substage_csv_text(rows)
	defer delete(text)
	testing.expect(t, len(text) > len(SUBSTAGE_CSV_HEADER), "CSV must contain a data row")
	testing.expect(t, text[:len(SUBSTAGE_CSV_HEADER)] == SUBSTAGE_CSV_HEADER, "CSV header changed")
	testing.expect(t, strings.contains(SUBSTAGE_CSV_HEADER, "C_carrier_valid") &&
		strings.contains(SUBSTAGE_CSV_HEADER, "row_ok"),
		"CSV must distinguish zero from invalid observables and retain row status")
	newlines, commas := 0, 0
	for c in text {
		if c == '\n' {newlines += 1}
		if c == ',' {commas += 1}
	}
	testing.expect_value(t, newlines, 2)
	testing.expect_value(t, commas, 72)
	testing.expect(t, strings.has_suffix(text, ",true,false,false,false,false,false,true,true\n"),
		"CSV validity flags no longer match their columns")
	testing.expect(t, text[len(SUBSTAGE_CSV_HEADER)] == '6', "CSV row order changed")
}
