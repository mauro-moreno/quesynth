package s1probe

import "core:math"
import "core:testing"

@(test)
test_substage_signed_level_error_is_not_self_referential :: proc(t: ^testing.T) {
	positive, positive_ok := substage_db_error(2.0, 1.0)
	negative, negative_ok := substage_db_error(1.0, 2.0)
	testing.expect(t, positive_ok && negative_ok, "nonzero fabricated amplitudes must be measurable")
	testing.expectf(t, abs(positive - 6.0205999) < 0.0001, "ours-high sign changed: %.6f", positive)
	testing.expectf(t, abs(negative + 6.0205999) < 0.0001, "ours-low sign changed: %.6f", negative)
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
test_substage_projection_window_matches_preregistered_bounds :: proc(t: ^testing.T) {
	from, to := substage_window(72000)
	testing.expect_value(t, from, 4800)
	testing.expect_value(t, to, 69600)
	f0, f2 := substage_frequency(60)
	testing.expectf(t, abs(f0 - 261.62558) < 0.001, "wrong note frequency %.6f", f0)
	testing.expectf(t, abs(f2 - f0 * math.pow(f64(2.0), f64(4.0 / 12.0))) < 0.0001, "wrong OSC2 frequency %.6f", f2)
}

@(test)
test_substage_csv_is_deterministic_and_signed :: proc(t: ^testing.T) {
    rows := []Substage_Row{{note=60, p95=32, mix=0, saturation=0, gain=64, level_carrier=0.25, level_sub=-0.5}}
    text := substage_csv_text(rows)
    defer delete(text)
    testing.expect(t, len(text) > len(SUBSTAGE_CSV_HEADER), "CSV must contain a data row")
    testing.expect(t, text[:len(SUBSTAGE_CSV_HEADER)] == SUBSTAGE_CSV_HEADER, "CSV header changed")
    newlines := 0
    for c in text {if c == '\n' {newlines += 1}}
    testing.expect_value(t, newlines, 2)
    testing.expect(t, text[len(SUBSTAGE_CSV_HEADER)] == '6', "CSV row order changed")
}
