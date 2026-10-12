package dsp

// The filter section's shared vocabulary and its output stage.
//
// The filters themselves are `Chamberlin` (the two-pole types), `Moog_Ladder` (the
// 24 dB low pass) and `Diode_Ladder` (the fifth type); each is the reference's own
// structure, and this file holds only what they have in common.

Filter_Mode :: enum u8 {
	Low_Pass,
	High_Pass,
	Band_Pass,
	Notch,
}

Filter_Slope :: enum u8 {
	Slope_12,
	Slope_24,
}

// The filters' output saturation.
//
// `saturation_drive` is parameter 23 after its measured curve has been resolved
// by the engine. The reference is a peak-normalised tanh: it raises the small-
// signal gain and adds odd harmonics while leaving full-scale peaks fixed. It is
// applied once to the completed filter response. This is observable in the 24 dB
// mode: applying it per section compounds the transfer and produces 5.8 dB too
// much THD at stored 32, while the reference has the same open-filter transfer
// in both slopes. The previous soft clip plus an unrelated `1 + 2*sat` trim did
// the opposite at the top of the knob, losing 3.7 dB where the reference loses
// none.
// The drive reaches 74 at the top of the control, so the old ceiling of 20 --
// which was ample for a tanh -- would flatten the last third of the knob.
FILTER_SATURATE_MAX_DRIVE :: f32(200.0)

filter_saturate :: proc "contextless" (x, drive: f32) -> f32 {
	if !is_finite(x) {
		return 0
	}
	d := clamp32(drive, 0, FILTER_SATURATE_MAX_DRIVE)
	if d <= 0 {
		return x
	}
	// An algebraic saturator, normalised so that an input of one comes out at one,
	// which is what keeps the reference's peak fixed across the control.
	//
	// This used to be `tanh(x*d)/tanh(d)`, which was fitted from THD through an
	// open filter and is right there -- but a curve is not identified by one
	// operating point, and through a closed filter that one was up to 23 dB short
	// of the reference's harmonics. Read directly, by scattering a saturated
	// render against an unsaturated one sample for sample, the reference is this
	// instead: measured against nine candidate families at three settings it wins
	// every one of them by an order of magnitude, 0.00022, 0.00068 and 0.00241 dB
	// rms against tanh's 0.00306, 0.01707 and 0.02559.
	//
	// The difference is at the bottom of the curve, which is exactly where a
	// closed filter puts the signal: the small-signal gain here is `1 + d`, where
	// tanh's is `d/tanh(d)`, half again as steep at the middle of the knob.
	return x * (1.0 + d) / (1.0 + abs(x * d))
}
