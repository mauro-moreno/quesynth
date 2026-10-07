package s1probe

import "core:testing"

// The osc2track probe prints a frequency for the strongest two peaks and used to
// print 0.00 for "no second peak" and discard both levels. These pin what a
// reader can now tell apart, against spectra built with known peaks.

// Bin spacing of 10 Hz puts bin k at 10k Hz, so the peaks sit at round numbers.
PEAK_TEST_BIN_HZ :: 10.0

peak_test_spectrum :: proc() -> []f64 {
	return make([]f64, 100)
}

// A peak with half its power on each side, so the parabolic reading lands on the bin.
peak_test_put :: proc(power: []f64, bin: int, level: f64) {
	power[bin] = level
	power[bin - 1] = level * 0.5
	power[bin + 1] = level * 0.5
}

@(test)
test_two_peaks_reports_no_second_peak_when_there_is_one :: proc(t: ^testing.T) {
	power := peak_test_spectrum()
	defer delete(power)
	peak_test_put(power, 30, 1.0)

	a, b, _, _ := two_peaks(power, PEAK_TEST_BIN_HZ, 150, 700)
	testing.expectf(t, abs(a - 300.0) < 1.0e-9, "strongest peak at %.6f Hz, want 300", a)
	testing.expect_value(t, b, 0.0)
}

@(test)
test_two_peaks_gives_the_second_peak_level_relative_to_the_first :: proc(t: ^testing.T) {
	power := peak_test_spectrum()
	defer delete(power)
	peak_test_put(power, 30, 1.0)
	peak_test_put(power, 50, 0.01) // 20 dB down

	a, b, a_db, b_db := two_peaks(power, PEAK_TEST_BIN_HZ, 150, 700)
	testing.expectf(t, abs(a - 300.0) < 1.0e-9, "strongest peak at %.6f Hz, want 300", a)
	testing.expectf(t, abs(b - 500.0) < 1.0e-9, "second peak at %.6f Hz, want 500", b)
	testing.expectf(t, abs((b_db - a_db) + 20.0) < 1.0e-9, "second peak is %.6f dB from the first, want -20", b_db - a_db)
}

@(test)
test_two_peaks_finds_nothing_in_a_spectrum_with_no_power :: proc(t: ^testing.T) {
	// Every bin of an all-zero spectrum is "not lower than its neighbours".
	power := peak_test_spectrum()
	defer delete(power)

	a, b, _, _ := two_peaks(power, PEAK_TEST_BIN_HZ, 150, 700)
	testing.expect_value(t, a, 0.0)
	testing.expect_value(t, b, 0.0)
}

@(test)
test_peak_pair_text_marks_an_absent_peak_instead_of_printing_zero_hertz :: proc(t: ^testing.T) {
	testing.expect_value(t, peak_pair_text(220.02, 660.05, -10.0, -22.5), "  220.02   660.05  -12.5 dB")
	testing.expect_value(t, peak_pair_text(261.67, 0.0, -10.0, 0.0), "  261.67        -         -")
	testing.expect_value(t, peak_pair_text(0.0, 0.0, 0.0, 0.0), "       -        -         -")
}

@(test)
test_corr_text_prints_n_a_for_an_undefined_correlation :: proc(t: ^testing.T) {
	testing.expect_value(t, corr_text(1.0, true), " 1.000")
	testing.expect_value(t, corr_text(0.046, true), " 0.046")
	testing.expect_value(t, corr_text(-1.0, true), "-1.000")
	testing.expect_value(t, corr_text(0.0, true), " 0.000")
	testing.expect_value(t, corr_text(0.0, false), "   n/a")
}
