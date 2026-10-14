package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"

// The reference passes +41.2 dBFS untouched (eight in-phase unison layers with an
// equaliser peak of +24.8 dB, `s1probe arch clip`), so the limiter must not touch
// anything up to there.
@(test)
test_output_limiter_is_transparent_through_the_reference_peaks :: proc(t: ^testing.T) {
	for dbfs in ([?]f64{-60, -6, 0, 19, 30.1, 36, 41.2}) {
		x := f32(math.pow(10.0, dbfs / 20))
		testing.expect_value(t, dsp.soft_clip(x), x)
		testing.expect_value(t, dsp.soft_clip(-x), -x)
	}
}

// And it still bounds what is not.
@(test)
test_output_limiter_still_bounds_runaway_output :: proc(t: ^testing.T) {
	for x in ([?]f32{300, 1000, 1.0e6, 1.0e30}) {
		y := dsp.soft_clip(x)
		testing.expectf(t, y > dsp.SOFT_CLIP_KNEE && y <= 2 * dsp.SOFT_CLIP_KNEE, "%v became %v", x, y)
		testing.expect_value(t, dsp.soft_clip(-x), -y)
	}
	testing.expect_value(t, dsp.soft_clip(math.nan_f32()), f32(0))
	testing.expect_value(t, dsp.soft_clip(math.inf_f32(1)), f32(0))
}

// Slope one at the knee: no step where the two halves meet.
@(test)
test_output_limiter_is_continuous_at_the_knee :: proc(t: ^testing.T) {
	below := dsp.soft_clip(dsp.SOFT_CLIP_KNEE - 0.001)
	above := dsp.soft_clip(dsp.SOFT_CLIP_KNEE + 0.001)
	testing.expectf(t, abs((above - below) - 0.002) < 0.0005, "step of %v across the knee", above - below)
}
