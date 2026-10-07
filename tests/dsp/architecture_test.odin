package dsp_tests

import "core:math"
import "core:testing"

// Public render regression for the independently measured effect/EQ order.
// arch fxorder: sine note 48, a.d.2 64/64/127, EQ 129.8 Hz +24.8 dB.
// Reference EQ-on minus EQ-flat: H1 +24.79 dB, H3 +7.01 dB. Independent
// EQ-only renders at the two frequencies give the same gains. EQ ahead of
// distortion instead gives +0.02/+0.17 dB: its boost is saturated away.
@(test)
test_equalizer_shapes_harmonics_after_the_effect :: proc(t: ^testing.T) {
	line_db :: proc(x: []f32, hz: f64) -> f64 {
		re, im := 0.0, 0.0
		from, to := int(0.3 * f64(SR)), int(1.4 * f64(SR))
		for i in from ..< to {
			w := 0.5 - 0.5 * math.cos(2 * math.PI * f64(i - from) / f64(to - from))
			phase := 2 * math.PI * hz * f64(i) / f64(SR)
			re += f64(x[i]) * w * math.cos(phase)
			im += f64(x[i]) * w * math.sin(phase)
		}
		return 10 * math.log10(re * re + im * im)
	}
	levels: [2][2]f64
	for on in 0 ..< 2 {
		p := behavior_patch(0, 0, 0, 127)
		p.values[29] = 127
		p.values[60] = 64
		p.values[61] = 21 // measured display 129.8 Hz
		p.values[62] = on == 1 ? 127 : 64
		p.values[63] = 64
		p.values[77] = 1
		p.values[78] = 1 // analogue distortion 2
		p.values[79] = 64
		p.values[80] = 64
		p.values[81] = 127
		x := render_keys(p, []Key_Event{{0, 48, true}}, 1.5)
		f0 := 440.0 * math.pow(f64(2.0), (48.0 - 69.0) / 12.0)
		levels[on] = {line_db(x, f0), line_db(x, 3 * f0)}
		delete(x)
	}
	testing.expectf(t, abs(levels[1][0] - levels[0][0] - 24.79) < 0.4,
		"fundamental EQ gain: %v dB, reference 24.79", levels[1][0] - levels[0][0])
	// The engine's Q differs from the reference (arch eq); the independent
	// peak-at-f0 gain above pins order without requiring that Q correction.
	testing.expectf(t, levels[1][1] - levels[0][1] > 1,
		"EQ must also boost the generated third harmonic, got %v dB", levels[1][1] - levels[0][1])
}
