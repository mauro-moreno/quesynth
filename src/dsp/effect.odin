package dsp

import "core:math"

// The extra effect unit: parameters 77..81.
//
// One slot, ten types, two general-purpose controls and a level. The plugin's own
// LCD names them:
//
//   a.d.1  a.d.2  d.d.  deci.  r.m.  comp.  ph1  ph2  ph3  ph4
//
// This is the least documented section in the reference. The English readme does
// not mention it. The Japanese manual names only the first six and stops -- the
// four phasers arrived in v1.07 ("Phaserの追加") and the type table was never
// updated for them. And **no patch in the factory bank switches the unit on**, so
// the 128-patch null test cannot see this code at all: it can catch a regression
// and nothing else. Everything below therefore comes from direct probes against
// the reference rather than from the bank, and `tools/s1probe/effectprobe.odin`
// holds the method.
//
// What was measured, and what was chosen, is marked at every constant. The short
// version is that the level law, the ring modulator's frequency, the decimator's
// step and depth, the shared low-pass corner and the compressor's attack are
// measurements in real units, as are the phasers' structure, centre frequency and
// rate law; the three distortion transfer curves are chosen.

// ---------------------------------------------------------------------- types

Effect_Type :: enum u8 {
	// "a.d.1": the manual's analogue distortion, with low-frequency loss from
	// negative feedback and even-order harmonics.
	Analog_1,
	// "a.d.2": the second analogue distortion.
	Analog_2,
	// "d.d.": the digital one.
	Digital,
	// "deci.": sample-rate and bit-depth reduction.
	Decimator,
	// "r.m.": ring modulator.
	Ring_Mod,
	// "comp.": compressor.
	Compressor,
	// "ph1".."ph4": phasers -- a swept resonance, not a notch comb. They differ in
	// the frequency it is centred on.
	Phaser_1,
	Phaser_2,
	Phaser_3,
	Phaser_4,
}

// ------------------------------------------------------------ measured curves

// The shared low-pass, for `ctl2` on 0..1.
//
// Measured, and exactly: all three distortions carry the same second-order low-pass, a
// biquad of the usual bilinear-prewarped kind with a Q of 3.0 and a corner that follows
// 399.92 Hz * 2^(0.04191 * ctl2), ctl2 being the stored 0..127. Probed in the linear
// regime -- noise at a quiet level through the lowest drive, so the transfer function is
// the filter's and not the shaper's -- and fitted to the reference's complex response,
// magnitude and phase together, over 250 Hz to 20 kHz. The fit lands within 0.3 per cent
// rms in log magnitude and phase at every one of six settings, the corner within 0.01 per
// cent of that law, and Q at 2.99 to 3.00 at all of them (`s1probe arch fadedump
// --values 6,<ctl2>,<type>`). d.d. against a.d.2 is a flat -0.2 dB and 0 degrees from 300
// Hz to 14 kHz at every ctl2, and a.d.1 against a.d.2 is the same curve at every ctl2, so
// the filter is common and a.d.1's difference is a stage that does not depend on ctl2.
//
//   ctl2         0     32      64      96     112      127
//   corner   399.9   1013    2567    6504   10352    16003  Hz
//
// An earlier version took the corner from white noise as the point where the response had
// fallen 3 dB, and called the filter one pole. That corner is real, 451.9 Hz at the bottom
// and 2901 at stored 64, but it is where this resonant response crosses -3 dB and not where
// the filter sits: a one-pole there rings nothing, and the reference's rings, which a null
// of a held distorted sine finds at -11 dB where this reaches -30 and better.
EFFECT_LOWPASS_MIN_HZ :: f32(399.92)
EFFECT_LOWPASS_OCTAVES :: f32(5.3226)
EFFECT_LOWPASS_Q :: f32(3.0)

effect_lowpass_hz :: proc "contextless" (ctl2: f32) -> f32 {
	return EFFECT_LOWPASS_MIN_HZ * math.pow(f32(2.0), EFFECT_LOWPASS_OCTAVES * clamp32(ctl2, 0, 1))
}

// The ring modulator's frequency, in hertz, for `ctl1` on 0..1.
//
// Measured, and the one control in this whole section that gives up a real unit
// directly: multiplying a carrier f0 by a modulator fm leaves partials at
// |f0 - fm| and f0 + fm, so the sidebands state fm outright. Fourteen settings
// spanning the range came out at a constant 1.762 times per 8 steps, which is
// 0.101 octaves per step:
//
//   ctl1       24     32     40     48     56     64     72     80 ...  127
//   fm        5.5    9.6   17.0   29.8   52.6   92.7    163  287.5 ... 7869  Hz
//
// Below about ctl1 24 the two sidebands are closer together than the analysis
// grid can resolve, but the fundamental still smears the way a few-hertz
// modulation would, and the fit extrapolates to roughly 1 Hz at zero.
EFFECT_RING_MIN_HZ :: f32(1.049)
EFFECT_RING_OCTAVES :: f32(12.83)

effect_ring_hz :: proc "contextless" (ctl1: f32) -> f32 {
	return EFFECT_RING_MIN_HZ * math.pow(f32(2.0), EFFECT_RING_OCTAVES * clamp32(ctl1, 0, 1))
}

// The decimator's hold, in samples at 48 kHz, for a stored `ctl1` on 0..127.
//
// Measured, in the time domain, because the spectrum is the wrong instrument: as
// the rate sweeps, images cross in and out of the harmonic windows, so harmonic
// and inharmonic totals swing by 15 dB between adjacent settings while the
// control moves smoothly. The output is literally a staircase, so the step was
// read off the samples instead, and it came out exact at every setting tried:
//
//   ctl1       56    64    72    80    88    96   104   112   120   127
//   hold       47    55    63    71    79    87    95   103   111   118  samples
//
// That is `ctl1 - 9`, with no decimation at or below 9.
//
// One caveat is recorded rather than hidden: this was measured at 48 kHz only, so
// whether the reference holds for a fixed number of *samples* or for a fixed
// *time* is not established. It is treated as a time here -- the manual calls the
// control a sampling frequency, which is a rate and not a sample count -- so the
// two readings agree exactly at 48 kHz and the audible result is preserved at
// other rates.
EFFECT_DECIMATE_OFFSET :: f32(9.0)
EFFECT_DECIMATE_REFERENCE_SR :: f32(48000.0)

effect_hold_samples :: proc "contextless" (ctl1_stored, sample_rate: f32) -> f32 {
	steps := ctl1_stored - EFFECT_DECIMATE_OFFSET
	if steps <= 1 {
		return 0
	}
	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = EFFECT_DECIMATE_REFERENCE_SR
	}
	return steps * sr / EFFECT_DECIMATE_REFERENCE_SR
}

// The decimator's quantisation, as the number of levels, for `ctl2` on 0..1.
//
// Measured by counting distinct output values with the rate reduction switched
// off, so only the quantiser was in play. The count halves every 8 steps through
// the reliable part of the range -- one bit per 8 steps -- and stops falling near
// the top:
//
//   ctl2       64     72     80     88     96    104    112    120
//   levels   4301   2236   1214    613    308    159    105     73
//
// Both ends carry a known bias and are treated as bounds rather than readings:
// below ctl2 32 the counter saturates against its own limit, and at the very top
// the count reflects how many levels a sine of this amplitude actually visits
// rather than how many exist. So the depth is taken as 16 bits falling to 6.
EFFECT_QUANTIZE_MAX_BITS :: f32(16.0)
EFFECT_QUANTIZE_MIN_BITS :: f32(6.0)
// Below this the quantiser is bypassed outright, which keeps a nominally
// 16-bit setting from costing a rounding step on every sample.
EFFECT_QUANTIZE_BYPASS_BITS :: f32(15.0)

// The decimator's quantiser, measured from what it does rather than what it looks
// like.
//
// Counting distinct output values is the obvious reading and it is wrong. It said
// 8.55 bits at ctl2 96, and an 8.55-bit quantiser driven at 82.5 per cent of full
// scale has a total error 51 dB down, while the reference's third harmonic there
// comes back at -36.0. No step size produces a harmonic fifteen decibels above
// its own total error, so the count is not the step: something downstream is
// multiplying the distinct values without undoing the distortion.
//
// The harmonics are the step. Fitted against h3, h5 and h7 of a quantised sine:
//
//   ctl2       32     48     64     80     96    112    127
//   counted 15.32  14.03  12.35  10.53   8.55   6.99   6.47  bits
//   actual  10.60   8.55   7.35   5.55   3.55   2.10   1.60
//   rms      1.24   1.38   0.64   0.47   0.26   3.15   6.11  dB
//
// Five bits coarser through the middle, and at the top of the knob it is down to
// three levels. Below ctl2 32 the harmonics sit at the render's own floor, 102 dB
// down, so the depth there is a lower bound rather than a reading and the table
// holds it flat. The two settings at the top fit worst, which is where a step
// that coarse puts its harmonics past Nyquist -- the same limit d.d. runs into.
EFFECT_QUANTIZE_KNOTS :: [9]f32{0.0, 16.0, 32.0, 48.0, 64.0, 80.0, 96.0, 112.0, 127.0}
EFFECT_QUANTIZE_BITS :: [9]f32 {
	14.00, 12.30, 10.60, 8.55, 7.35, 5.55, 3.55, 2.10, 1.60,
}

effect_quantize_bits :: proc "contextless" (ctl2: f32) -> f32 {
	knots := EFFECT_QUANTIZE_KNOTS
	bits := EFFECT_QUANTIZE_BITS
	c := clamp32(ctl2, 0, 1) * 127.0
	for i in 1 ..< len(knots) {
		if c <= knots[i] {
			span := knots[i] - knots[i - 1]
			t := span > 0 ? (c - knots[i - 1]) / span : 0
			return bits[i - 1] + (bits[i] - bits[i - 1]) * t
		}
	}
	return bits[len(bits) - 1]
}

// The compressor's attack, in seconds, for `ctl2` on 0..1.
//
// Measured from how long the note's overshoot takes to fall back within 1 dB of
// its settled level: 2 ms at the bottom of the range to 190 ms at the top. The
// reading is quantised by the 2 ms analysis frame at the fast end and is noisy in
// the middle, so an exponential is fitted through the two ends rather than a
// table being built from points that would not support one.
//
// Two independent readings confirm the control is an attack time and not
// something else. The overshoot grows monotonically with it across all seventeen
// settings, 0.9 dB to 39.8 dB, which is what a compressor that takes longer to
// clamp must do. And harmonic distortion *falls* across the same sweep, -6.7 dB
// to -59.9 dB: a fast attack moves the gain within a single cycle and so bends the
// waveform, a slow one cannot.
EFFECT_COMP_MIN_ATTACK_S :: f32(0.002)
EFFECT_COMP_MAX_ATTACK_S :: f32(0.190)

effect_comp_attack_s :: proc "contextless" (ctl2: f32) -> f32 {
	t := clamp32(ctl2, 0, 1)
	return EFFECT_COMP_MIN_ATTACK_S *
		math.pow(f32(2.0), t * math.log2(EFFECT_COMP_MAX_ATTACK_S / EFFECT_COMP_MIN_ATTACK_S))
}

// ------------------------------------------------------------- chosen curves

// How hard the three distortions are driven at the top of ctl1.
//
// Chosen. The displays are a bare 0..127 and the transfer curves themselves are
// not recoverable from a spectrum without assuming a shape first. What *was*
// measured is which harmonics each type produces, and that is what the three
// shapers below are built to reproduce:
//
//   a.d.1  even harmonics dominate at low drive, -22.6 dB against -43.1 dB odd,
//          and the fundamental is cut by 2.6 dB
//   a.d.2  purely odd, -46.5 dB against -103 dB even, and the fundamental is
//          *boosted* by 5.5 dB rather than cut
//   d.d.   the most aggressive, reaching more harmonic energy than fundamental
//
// So a.d.1 is asymmetric with a low-frequency loss, a.d.2 is symmetric, and d.d.
// clips hard. The drive range is chosen to put the measured harmonic ratios in
// roughly the right place at mid knob.
// The two analogue distortions, measured.
//
// All three shapes here were written from their names and never measured: a.d.1
// an asymmetric tanh with a hand-picked offset, a.d.2 a plain tanh, d.d. a hard
// clip, over a drive that ran exponentially from 1 to 64. They scored 6.5, 7.4
// and 14.3 dB of spectral error, the worst of any section.
//
// A spectrum cannot be inverted into a curve, but harmonics can be read off one
// directly. `tools/s1probe/fxcurve.odin` holds the method; the short version is
// that a memoryless curve driven by a sine puts power only at multiples of f0,
// and the amplitude of each is a fixed function of the drive, so measuring them
// across the whole of ctl1 separates the curve's shape from its drive without
// assuming either. The input was checked rather than assumed: the probe's tone
// is a sine to within -104 dB, so every harmonic measured is the unit's own.
//
// Both types are `gain * tanh(drive * x + bias)`, with the bias at zero for a.d.2
// -- which is what makes it the symmetric one. Fitted against harmonics one to
// five over fourteen drive settings, a.d.2 lands within 0.16 dB and a.d.1 within
// 1.50 dB.
//
// The single largest error was the drive. It saturates: a.d.2's odd harmonics
// stop moving at ctl1 80 and are identical from there to 127, and the fitted
// drive tops out at 5.4 where the old law was still climbing to 64. Everything
// above ctl1 80 was therefore over-driven by more than a factor of ten.
EFFECT_AD_KNOTS :: [14]f32 {
	0.0, 8.0, 16.0, 24.0, 32.0, 40.0, 48.0, 56.0, 64.0, 72.0, 80.0, 96.0, 112.0, 127.0,
}
// a.d.2's two columns were refitted against the reference once its low-pass was known
// exactly (see EFFECT_LOWPASS_MIN_HZ): they had been fitted through a one-pole low-pass that
// is not the reference's, which hid how far the drive keeps climbing. It does not saturate at
// ctl1 80 but at about 57 by ctl1 96, and the null of a held sine at ctl2 127 improved by 3 to
// 13 dB at every ctl1 from 40 up. Fitted in the time domain against `s1probe arch fadedump
// --values 1,127,<ctl1>`, with the first knot, where drive and gain trade off against each
// other, keeping its old drive.
EFFECT_AD2_DRIVE :: [14]f32 {
	0.2818, 0.6425, 1.3158, 2.2048, 3.5001, 5.5656, 9.0016,
	14.6572, 23.6063, 35.1219, 46.2247, 57.1646, 58.894, 59.0187,
}
EFFECT_AD2_GAIN :: [14]f32 {
	3.553, 1.7095, 1.0417, 0.8690, 0.8252, 0.8192, 0.8209,
	0.8229, 0.8242, 0.8253, 0.8261, 0.8271, 0.8274, 0.8274,
}

// Read one of the tables above at a knob position on 0..1, linearly between the
// knots it was measured at.
effect_ad_table :: proc "contextless" (table: [14]f32, ctl1: f32) -> f32 {
	knots := EFFECT_AD_KNOTS
	c := clamp32(ctl1, 0, 1) * 127.0
	for i in 1 ..< len(knots) {
		if c <= knots[i] {
			span := knots[i] - knots[i - 1]
			t := span > 0 ? (c - knots[i - 1]) / span : 0
			return table[i - 1] + (table[i] - table[i - 1]) * t
		}
	}
	return table[len(table) - 1]
}

// d.d. is a triangle wavefolder, read off its own curve rather than fitted.
//
// Recovering a curve needs the harmonics' phases, which the magnitude probe
// throws away. A memoryless curve's harmonics are all real once the input's own
// phase is removed -- that is what memoryless means -- so dividing by the measured
// response and rotating gives the curve back with no family assumed at all, and
// the phase left over measures how much of the reading is neither. d.d. comes
// back at 0.030 to 0.042 up to ctl1 64, against a.d.2's 0.011 to 0.042, so it is
// memoryless and the curve is exact rather than fitted.
//
// What it draws is a fold, and a straight one. At ctl1 16 it rises along a slope
// of 1.2 to a peak of 0.83 at x = 0.69 and then comes back down; a triangle
// predicts 0.662 at x = 0.83 and the measurement is 0.651. A sine fold was fitted
// first, against Bessel magnitudes, and is wrong: a fold of any shape looks like
// that from a distance.
//
// Fitted against the odd harmonics with the response held fixed, ctl1 16 to 48
// lands within 0.19 to 0.88 dB, and the fold depth is a clean exponential: 1.50,
// 2.52, 4.15, 6.99, 11.52, a ratio of 1.66 every eight steps. Above ctl1 48 the
// fitted depth scatters and the law is extrapolated through it, because that is
// where the reading fails and not the law -- a fold that deep puts harmonics past
// Nyquist, they alias back to frequencies that are not multiples of f0, and the
// phase residual rises to 0.30 and then 0.61. The reference aliases them too,
// its output at full drive collapsing to -23 dB with the energy spread
// inharmonically, so a memoryless fold reproduces that by doing the same thing.
EFFECT_DD_DRIVE :: [14]f32 {
	0.5400, 0.8628, 1.5106, 2.5096, 4.1696, 6.9264, 11.5085,
	19.1165, 31.7586, 53.0190, 88.1870, 244.100, 675.700, 1768.50,
}
EFFECT_DD_GAIN :: [14]f32 {
	1.8430, 1.2365, 0.8560, 0.7185, 0.6673, 0.6486, 0.6401,
	0.6235, 0.5763, 0.6370, 0.6370, 0.6370, 0.6370, 0.6370,
}

// The rest of the section keeps the old exponential drive.
EFFECT_DRIVE_MIN :: f32(1.0)
EFFECT_DRIVE_MAX :: f32(64.0)

effect_drive :: proc "contextless" (ctl1: f32) -> f32 {
	t := clamp32(ctl1, 0, 1)
	return EFFECT_DRIVE_MIN * math.pow(f32(2.0), t * math.log2(EFFECT_DRIVE_MAX / EFFECT_DRIVE_MIN))
}

// a.d.1's low-frequency loss, as the corner of a fixed high pass.
//
// Chosen in value, measured in existence: the fundamental at 130 Hz comes back
// 2.6 dB down, and the manual attributes that to negative feedback. The corner is
// placed low enough to account for that without thinning the signal.
// a.d.1 is a clipper inside a feedback loop, which is what the manual calls it.
//
// It is the one type here that is not memoryless. Its harmonics' phases say so
// outright -- 0.146 to 0.439 where a.d.2 reads 0.011 to 0.042 -- and that is why
// every curve fitted to it failed: no curve of any shape was ever going to.
//
// A loop explains what the curves could not. The distortion grows with frequency,
// because the feedback rolls off and stops linearising; the tail decays like 1/k,
// because what is inside the loop is a hard clip; and the even harmonics peak in
// the middle of the knob and fade, because the bias matters less as the drive
// grows. Fitted over h1 to h11 across twelve settings it reaches 2.51 dB, against
// 3.91 for the best memoryless family, and from ctl1 56 upward it is inside 1.1.
//
// What it does not yet reproduce is the response away from the note it was fitted
// at. The loop's own low-frequency loss is a decibel where the reference measures
// forty, so its corner is not this loop's corner and something else is blocking
// the bottom. The harmonics at 131 Hz are right and the shape of the response is
// not, which is recorded rather than papered over.
// The response, measured where the loop is straight, and it is not the loop's.
//
// A feedback loop is a high pass in its own right, and its loss is set by the
// loop gain -- so if a.d.1's bottom end were the loop's doing it would deepen as
// the knob drives the loop harder. It does not move at all:
//
//   ctl1        0     64    127
//   33 Hz   -40.9  -37.2  -37.4 dB
//   65 Hz   -18.2  -15.8  -15.9
//   131 Hz   -2.6   -3.1   -3.1
//
// So it is a fixed filter. Measured at fourteen frequencies it is the shared
// two-pole high pass with one more two-pole section on top and a shelf: about
// 23 dB per octave below 90 Hz, a shoulder at -2.5 dB from 116 to 147 Hz, then a
// climb of some three dB per octave to a plateau of +7.2 dB. Fitted with the
// shared section held at its own measured value it lands within 0.20 dB at every
// one of the fourteen. Written as one feedback loop instead it reaches 0.71 dB at
// best, so the loop is not what shapes it and the two are separate in series.
//
// That section was refitted in two stages, against a time-domain null and then against the
// reference's complex transfer function measured in the linear regime (`s1probe arch fadedump
// --values 6,127,0`), and what follows is the second. With the shared high pass and low-pass
// divided out and the shelf and the loop below held as fitted, the remainder is a third-order
// section: a pair of zeros at 8.50 +- j11.89 Hz, a real zero at -16.54 kHz, poles at -15.73 Hz,
// -246.8 Hz and -9.255 kHz, and a gain of 2.069 at infinity, within 0.23 dB rms of the
// reference. They are stored as analog roots and rebuilt by the bilinear transform at the
// running sample rate, which at 48 kHz is the fit.
// The section's roots follow ctl1: they are tabulated per knot, as analog frequencies in hertz, and
// read linearly between the knots. See the tables below, `EFFECT_AD1_POST_*`.

// What stands in front of that section is a one-pole shelf and then a loop around a tanh.
// The shelf is a gain plus what a low pass at its pole leaves behind: (1 + s/wz)/(1 + s/wp)
// is exactly G + (1 - G) * lowpass(wp), with G = wp/wz.
//
// The loop, the shelf and the nonlinearity were fitted together by simulating the whole
// chain against the reference's harmonics, from sines at six pitches, six levels and
// fourteen settings of ctl1 (`s1probe arch ad1sweep`, `arch ad1fit`). The linear remainder
// is divided out analytically at each harmonic, so only what has memory is searched. A hard
// clip, which this had been, comes out at 9.1 dB rms in log harmonic magnitude over three
// settings of ctl1, a cubic soft clip at 4.6 and a sine at 4.6; tanh comes out at 3.4 over all
// fourteen, 1.6 to 2.4 dB across the middle of the knob and 4 to 5.5 at its ends. Its
// even harmonics come from the loop's rest point, which sits well up the curve.
// A weak quadratic between the shared high pass and the section after the loop. Past ctl1 80
// the loop's clipper is a square wave with equal halves and almost no even harmonics, yet the
// reference's second harmonic is -17 dB at 65 Hz and falls to -43 dB at 1 kHz, whatever the
// level once the loop is saturated. A quadratic acting on the high pass's output makes that:
// a square wave squared is constant, so it only turns the droop and ringing the high pass puts
// on the wave into even harmonics, large at low pitch and gone at high. Where it sits matters
// as much as how big it is. Behind the whole chain its second harmonic comes out 110 to 135
// degrees from the reference's and makes the null worse; behind the high pass the phases
// agree and the best coefficient is 0.114 to 0.122 across four pitches for the second
// harmonic (0.063 to 0.088 for the fourth), which is where this takes it.
EFFECT_ANALOG1_MID_QUADRATIC :: f32(0.10)
EFFECT_ANALOG1_QUADRATIC_MEAN_HZ :: f32(10.0)

// Per knot of ctl1, fitted knot by knot (`s1probe arch ad1fit`): the drive, the loop gain, where the
// loop rests, the feedback corner, the shelf's gain and corner, and the gain after it. The
// objective is the energy of the complex difference over harmonics 1 to 16, each held-sine
// configuration weighted by its own energy, which is what a null of a held sine measures. Fitting
// it that way, and letting every one of those follow the knob, took a.d.1 above ctl1 48 from -10
// to -14 dB to -17 to -26 dB. The loop gain climbs from about 3 at the bottom to 7 in the upper
// middle and 10 at the top; the feedback corner sits near 77 Hz above ctl1 48 and the shelf is
// nearly flat there. The rest point is where the tanh's input settles, and the offset taken off
// its output so that rest is zero. The section after the loop is refitted at every knot from the
// linear response with that knot's shelf and loop divided out, and its roots tabulated
// alongside. Knot 0 keeps an earlier fit, whose post-loop section followed its shelf more
// closely.
EFFECT_AD1_DRIVE :: [14]f32 {
	0.8881, 1.2357, 1.5887, 3.11, 5.9244, 9.6271, 19.0219,
	32.4531, 57.7338, 94.777, 163.712, 519.69, 2484.93, 6045.24,
}
EFFECT_AD1_GAIN :: [14]f32 {
	1.06846, 0.50701, 0.33535, 0.21682, 0.17398, 0.17489, 0.14929,
	0.14762, 0.13714, 0.13751, 0.13285, 0.12761, 0.08526, 0.09796,
}
EFFECT_AD1_LOOP_GAIN :: [14]f32 {
	2.5838, 4.1998, 4.1949, 4.0617, 4.667, 4.9412, 6.404,
	6.5684, 7.0335, 7.0026, 7.3677, 8.4547, 11.3146, 9.8803,
}
EFFECT_AD1_REST :: [14]f32 {
	0.8621, 0.7793, 0.8554, 0.7273, 0.748, 0.7137, 0.6787,
	0.666, 0.6795, 0.6591, 0.6691, 0.7111, 0.9723, 0.8743,
}
EFFECT_AD1_FEEDBACK_HZ :: [14]f32 {
	118.44, 88.8, 71.55, 78.76, 86.7, 80.67, 77.11,
	77.11, 77.11, 77.11, 77.11, 66.77, 77.11, 77.11,
}
EFFECT_AD1_SHELF_GAIN :: [14]f32 {
	1.1305, 1.0027, 1.4371, 1.4371, 1.3056, 1.2746, 1.0923,
	1.1188, 1.0411, 1.0411, 1.0411, 1.0411, 0.7621, 0.9234,
}
EFFECT_AD1_SHELF_HZ :: [14]f32 {
	224.7, 135.7, 508.1, 559.3, 409.4, 381, 390.2,
	484.2, 380.9, 484.2, 586.7, 841, 6467.8, 4512.5,
}
EFFECT_AD1_POST_ZERO_RE_HZ :: [14]f32 {
	10.4052, 12.2689, 12.7358, 11.9207, 11.5824, 12.1617, 12.1124,
	11.714, 11.9184, 11.7849, 11.5581, 12.7293, 11.7368, 11.7082,
}
EFFECT_AD1_POST_ZERO_IM_HZ :: [14]f32 {
	14.9069, 16.6292, 16.3178, 15.8998, 15.9476, 16.4123, 16.2272,
	15.7764, 16.0194, 15.8607, 15.5952, 16.3043, 15.842, 15.8055,
}
EFFECT_AD1_POST_ZERO_REAL_HZ :: [14]f32 {
	16186.9, 13437.6, 12926.2, 13956.1, 14927.2, 13790.7, 14068.3,
	14705.3, 14460.6, 14635.7, 14818.4, 12599.9, 13315.9, 14675,
}
EFFECT_AD1_POST_POLE_1_HZ :: [14]f32 {
	5.8762, 2.42197, 4.27854, 0.887727, 0.37095, 2.11336, 1.88744,
	0.18732, 1.0649, 0.490617, 0.472872, 4.48343, 0.32362, 0.198263,
}
EFFECT_AD1_POST_POLE_2_HZ :: [14]f32 {
	404.239, 355.152, 293.32, 249.427, 236.694, 234.193, 215.723,
	200.903, 207.349, 203.196, 195.165, 200.249, 200.623, 199.375,
}
EFFECT_AD1_POST_POLE_3_HZ :: [14]f32 {
	9290.56, 8129.95, 7750.48, 8172.9, 8834.21, 8360.69, 8456.26,
	8656.95, 8604.51, 8645.52, 8667.19, 7691.7, 8484.35, 9058.87,
}
EFFECT_AD1_POST_GAIN :: [14]f32 {
	2.43866, 2.56034, 2.01819, 1.67013, 1.85043, 1.84936, 2.04082,
	1.93956, 2.12084, 2.0629, 2.07675, 2.27355, 3.52431, 2.96445,
}

// The unit's own response, measured where its curve is straight.
//
// At ctl1 0 the two analogue types and d.d. are linear -- a.d.2's third harmonic
// sits 46 dB down and does not move with the input level -- so the gain at the
// fundamental, swept across eight octaves, is the chain's frequency response with
// nothing else in it. a.d.2 and d.d. return the same shape, a peak of +5.5 dB at
// 131 Hz falling 24 dB over the two octaves below it and flat above 500 Hz, which
// is a two-pole high pass and nothing else: fitted, it lands within 0.07 dB at
// every one of eight frequencies.
//
//   32.7 Hz  -18.5 / -18.5      523 Hz  +0.3 / +0.3
//   65.4 Hz   -3.5 /  -3.4     1046 Hz  +0.1 / +0.1
//    131 Hz   +5.5 /  +5.5     2093 Hz  +0.1 / +0.1
//    262 Hz   +1.2 /  +1.3     4186 Hz  +0.2 / +0.1
//
// This replaces the one-pole high pass above, which was placed by choosing a
// corner that produced the one loss that had been measured.
EFFECT_AD_HIGHPASS_HZ :: f32(99.9)
EFFECT_AD_HIGHPASS_Q :: f32(2.26)

// d.d. shares that response, a decibel quieter.
EFFECT_DD_MAKEUP :: f32(0.896)

// One two-pole high pass, transposed direct form II, per channel.
effect_ad_highpass :: proc "contextless" (
	state: ^[2][2]f32,
	l, r, fc, q, sr: f32,
) -> (
	out_l, out_r: f32,
) {
	k := effect_ad_highpass_coefficients(fc, q, sr)
	return effect_ad_highpass_run(state, l, r, &k)
}

effect_ad_highpass_coefficients :: proc "contextless" (fc, q, sr: f32) -> [5]f32 {
	w := TAU * clamp32(fc, 1.0, sr * 0.45) / sr
	cs := math.cos(w)
	alpha := math.sin(w) / (2.0 * max(q, 0.01))
	a0 := 1.0 + alpha
	b0 := (1.0 + cs) * 0.5 / a0
	b1 := -(1.0 + cs) / a0
	b2 := b0
	a1 := -2.0 * cs / a0
	a2 := (1.0 - alpha) / a0
	return {b0, b1, b2, a1, a2}
}

// The same section with its coefficients held in `e` with the corner, Q and rate
// they were derived for, which do not move from sample to sample.
effect_ad_highpass_held :: proc "contextless" (e: ^Effect, l, r, fc, q, sr: f32) -> (out_l, out_r: f32) {
	key := [3]f32{fc, q, sr}
	if e.ad_highpass_key != key {
		e.ad_highpass_coefficients = effect_ad_highpass_coefficients(fc, q, sr)
		e.ad_highpass_key = key
	}
	return effect_ad_highpass_run(&e.ad_highpass, l, r, &e.ad_highpass_coefficients)
}

effect_ad_highpass_run :: proc "contextless" (state: ^[2][2]f32, l, r: f32, k: ^[5]f32) -> (out_l, out_r: f32) {
	b0, b1, b2, a1, a2 := k[0], k[1], k[2], k[3], k[4]
	step :: proc "contextless" (z: ^[2]f32, x, b0, b1, b2, a1, a2: f32) -> f32 {
		y := b0 * x + z[0]
		z[0] = flush_denormal(b1 * x - a1 * y + z[1])
		z[1] = flush_denormal(b2 * x - a2 * y)
		return y
	}
	return step(&state[0], l, b0, b1, b2, a1, a2), step(&state[1], r, b0, b1, b2, a1, a2)
}

// a.d.1's post-loop section: a biquad holding the zero pair and two of the poles, then a
// first-order section with the last zero and pole, rebuilt from analog roots by the bilinear
// transform. Transposed direct form II; three states per channel.
effect_analog1_post :: proc "contextless" (
	e: ^Effect,
	l, r: f32,
	roots: ^[7]f32,
	sr: f32,
) -> (
	out_l, out_r: f32,
) {
	key := [8]f32{roots[0], roots[1], roots[2], roots[3], roots[4], roots[5], roots[6], sr}
	if e.ad1_post_key != key {
		tau := 2.0 * math.PI
		sigma := tau * f64(roots[0])
		omega := tau * f64(roots[1])
		zero_real := tau * f64(roots[2])
		pole_1 := tau * f64(roots[3])
		pole_2 := tau * f64(roots[4])
		pole_3 := tau * f64(roots[5])
		post_gain := f64(roots[6])
		c := 2.0 * f64(sr)

		n2, n1, n0 := 1.0, -2.0 * sigma, sigma * sigma + omega * omega
		d2, d1, d0 := 1.0, pole_1 + pole_2, pole_1 * pole_2
		a0 := d2 * c * c + d1 * c + d0
		first_den := c + pole_3
		e.ad1_post_coefficients = {
			f32(post_gain * (n2 * c * c + n1 * c + n0) / a0),
			f32(post_gain * (2.0 * n0 - 2.0 * n2 * c * c) / a0),
			f32(post_gain * (n2 * c * c - n1 * c + n0) / a0),
			f32((2.0 * d0 - 2.0 * d2 * c * c) / a0),
			f32((d2 * c * c - d1 * c + d0) / a0),
			f32((c + zero_real) / first_den),
			f32((zero_real - c) / first_den),
			f32((pole_3 - c) / first_den),
		}
		e.ad1_post_key = key
	}
	k := e.ad1_post_coefficients
	b0, b1, b2, a1, a2, f0, f1, fa1 := k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]

	step :: proc "contextless" (z: ^[3]f32, x, b0, b1, b2, a1, a2, f0, f1, fa1: f32) -> f32 {
		y := b0 * x + z[0]
		z[0] = flush_denormal(b1 * x - a1 * y + z[1])
		z[1] = flush_denormal(b2 * x - a2 * y)
		w := f0 * y + z[2]
		z[2] = flush_denormal(f1 * y - fa1 * w)
		return w
	}
	return step(&e.ad1_post[0], l, b0, b1, b2, a1, a2, f0, f1, fa1), step(&e.ad1_post[1], r, b0, b1, b2, a1, a2, f0, f1, fa1)
}

// The compressor's static curve, and what `comp.` actually is.
//
// Measured, and it is not the threshold-and-ratio compressor this was first
// written as. `tools/s1probe/compcurve.odin` holds the method; the short version
// is that a dynamics processor cannot be identified from one tone at one level,
// which is the reading every other type in this section was named from. Move the
// level going in and read the level coming out once it has settled, and the shape
// states itself:
//
//   ctl1 = 64, note 48, settled RMS in dBFS
//     in    -42.0  -35.3  -27.1  -17.0  -10.0   -4.7
//     out   -12.9  -11.2  -10.8  -10.7  -10.7  -10.7
//
// The output does not move. Across a 37 dB span of input it sits within a tenth
// of a decibel of -10.74 dBFS, which is a **leveller**: gain reduction tracking
// input one for one, not a ratio bending it. The implementation it replaces had a
// threshold at 0.25 and a ratio reaching 20:1, and read +10.9 dB of flat makeup
// where the reference was giving +30.
//
// The second half of the reading is what `ctl1` does. Plot every depth against
// the level *after* its own makeup gain and the curves collapse onto one line:
// over 115 points at seven depths the cross-depth residual is 0.0024 dB mean and
// 0.088 dB worst, and that worst point is the knee, where interpolating between
// neighbours is hardest. So depth is not a threshold, a ratio or a knee. It is an
// input gain, and it is linear in decibels across exactly 40 of them:
//
//   ctl1        0     16     32     64
//   makeup  +10.00 +15.04 +20.08 +30.16  dB, and 10 + 40*(ctl1/127) fits all four
//
// Predicting the three depths that were held back -- 96, 112 and 127, where even
// the quietest render is already compressing so the makeup cannot be read off
// directly -- puts all twelve rows within 0.02 dB of the measurement.
//
// Two independent checks that this is the whole law. Notes 36 and 72, three
// octaves apart, reproduce note 48 to three decimals, so nothing here is
// frequency weighted. And the level knob moves every point by the same amount --
// 0.23625 dB per step, 30.0 dB across the range, which is the crossfade law
// already measured for this type -- so it is an output gain sitting after all of
// this and not part of it.
EFFECT_COMP_MAKEUP_MIN_DB :: f32(10.0)
EFFECT_COMP_MAKEUP_RANGE_DB :: f32(40.0)

effect_comp_makeup :: proc "contextless" (ctl1: f32) -> f32 {
	db := EFFECT_COMP_MAKEUP_MIN_DB + EFFECT_COMP_MAKEUP_RANGE_DB * clamp32(ctl1, 0, 1)
	return math.pow(f32(10.0), db / 20.0)
}

// The leveller itself: gain in decibels against the level arriving at it, also in
// decibels, on a one-decibel grid.
//
// A table rather than a formula because no formula was found that fits. The curve
// is exactly unity below -15.3 dB -- the renders there are identity to four
// decimal places, which is a real threshold and not a soft approach to one -- and
// then bends over into limiting far more sharply than a soft knee does while
// still taking twenty decibels to get there. Every closed form tried was either
// too gentle at the corner or still compressing below the threshold: a
// peak-normalised algebraic saturator at any exponent, tanh, 1-exp, and the
// standard quadratic soft knee. The measurement is dense enough not to need one.
//
// Against the 118 points behind it this reconstructs to 0.0018 dB mean and
// 0.0426 dB worst, that worst again at the knee.
EFFECT_COMP_TABLE_LO_DB :: f32(-16.0)
EFFECT_COMP_TABLE_HI_DB :: f32(24.0)
// Where the output settles once it is limiting, and the value the table runs into
// at its top: above it every further decibel in is a decibel of gain reduction.
EFFECT_COMP_CEILING_DB :: f32(-10.739)

EFFECT_COMP_GAIN_DB := [41]f32 {
	0.0000, 0.0000, -0.1352, -0.4606, -0.9336, -1.5142, -2.1612,
	-2.8852, -3.6553, -4.4727, -5.3294, -6.2090, -7.1144, -8.0391,
	-8.9787, -9.9312, -10.8920, -11.8612, -12.8367, -13.8171, -14.8017,
	-15.7890, -16.7790, -17.7710, -18.7647, -19.7597, -20.7556, -21.7523,
	-22.7497, -23.7476, -24.7459, -25.7446, -26.7435, -27.7426, -28.7419,
	-29.7414, -30.7409, -31.7405, -32.7402, -33.7399, -34.7398,
}

// The gain the leveller applies to a signal sitting at `level`, as a linear
// amplitude. `level` is an RMS, because that is what the curve above was read in.
effect_comp_gain :: proc "contextless" (level: f32) -> f32 {
	if level <= 0 {
		return 1
	}
	db := 20.0 * math.log10(level)
	if db <= EFFECT_COMP_TABLE_LO_DB {
		return 1
	}
	gain_db: f32
	if db >= EFFECT_COMP_TABLE_HI_DB {
		gain_db = EFFECT_COMP_CEILING_DB - db
	} else {
		pos := db - EFFECT_COMP_TABLE_LO_DB
		i := int(pos)
		f := pos - f32(i)
		gain_db = EFFECT_COMP_GAIN_DB[i] + (EFFECT_COMP_GAIN_DB[i + 1] - EFFECT_COMP_GAIN_DB[i]) * f
	}
	return math.pow(f32(10.0), gain_db / 20.0)
}
// The detector is symmetric: one time constant, and ctl2 sets it.
//
// Measured twice over, from two directions. A detector that rises and falls at
// different rates settles off-centre on a signal that ripples, and the size of
// that bias is a reading in itself: with a 190 ms attack against a 120 ms
// release this engine settled 0.68 dB above the reference at every level in the
// limiting region, and making the two equal took that to 0.00 dB at every one.
// A steady tone cannot be levelled to the same place by an asymmetric detector.
//
// And the recovery after a level step slows down as ctl2 rises, which a fixed
// release cannot do. Timing the gain's return with the amplifier's own decay
// providing the step:
//
//   ctl2         32     48     80     96
//   attack      6.3   11.2   35.2   62.5  ms, the law already measured
//   recovery     ~9    ~16    ~49    ~80  ms, first-order fit to the trajectory
//
// One knob, one time constant, both directions. The recovery reads about 1.35
// times the attack rather than exactly equal, and that factor is not adopted:
// the two are measured through different mappings -- the attack from an
// overshoot in level, the recovery from a gain trajectory through the knee --
// and the residual is well inside what those mappings differ by. What is
// implemented is the symmetry the settled-level control proves.

// The phasers: a swept resonance, and both of its control laws.
//
// These began as guesses and are now measured, with one part still approximate.
// Getting there took three instruments, and the first two failing is the reason
// the numbers below can be trusted.
//
// The reference does **not** produce a comb of notches. Driving a saw wave through
// it and dividing the harmonic magnitudes by the same patch with the unit off
// gives a broad *resonance* reaching +19 dB with attenuation either side, and no
// notch anywhere in any frame that stands 3 dB clear of its neighbours. So this is
// a swept band pass and not the allpass-plus-dry chain it was first written as.
// Two drives 6 dB apart returned the same transfer function, which is the check
// that a linear filter is what is being measured.
//
//   ctl1, the depth. At zero the resonance is *static at 2800 Hz*, to a measured
//   span of 0.00 octaves, which is what fixes the centre frequency. Raising it
//   widens the sweep, and the rate is unchanged at every setting -- 3.61, 3.61,
//   3.47, 3.61, 3.61 Hz -- so the two controls are independent.
//
//     ctl1        0     16     32     64     96    127
//     band     2800   2923   3057   3304    131    131   Hz
//              2800   6839   7781  10465  10465  10465
//
//   ctl2, the rate. Exponential, at 2.33 times per 16 steps:
//
//     ctl2       48     64     80     96    112
//     rate     0.27   0.65   1.51   3.61   7.81   Hz
//
// The rate extremes are extrapolated from that fit rather than measured: below
// ctl2 48 the period passes 4 seconds and above 112 it approaches the analysis
// window, and at both ends the probe reports that it cannot resolve a period
// instead of guessing one. The depth *curve* is the part still approximate -- the
// 131 Hz readings are the analysis window's floor rather than the sweep's, so at
// high depth the extent is a lower bound, and the exponent below is fitted through
// the two settings that were not window-limited.
// What separates ph1 from ph4 **is** the number of sections, and the reading that
// said otherwise had only found the tallest peak of each. Sweeping a held tone
// down to 55 Hz instead of a saw comb down to 131 finds the rest, and they count
// out exactly one per type:
//
//   type      ph1    ph2    ph3    ph4
//   tall     2794   4186   5920   7040   Hz
//   others     --    262  110,   65, 156,
//                          262      262   Hz, each 9 to 20 dB clear of both
//                                        neighbours
//
// So this is a comb, and the shipped stage count below has been right since the
// first guess. What is missing is what turns an allpass chain's notches into
// resonances -- feedback -- and parameter 81 is what sets it; see the level law
// note further down. The superseded reading was:
//
//   type      ph1    ph2    ph3    ph4
//   centre   2878   3924   5494   6540   Hz
//   peak      +23    +26    +25    +24   dB
//
// That measurement replaced two wrong guesses in a row. The first was 1 to 4
// allpass sections summed with dry, which makes notches; the second was 1 to 4
// cascaded band passes, which was worse still -- error rose monotonically with the
// stage count, 10.0, 22.6, 31.9 and 39.6 dB, and the output came out 20 dB quiet,
// because a cascade of band passes removes everything away from its centre while
// the reference only drops 13 dB.
//
// A third guess followed those two -- a single swept resonance, read off that
// shape -- and it was wrong in the same way: fitted to where the resonance is
// rather than to the response. What settled the structure was fitting the whole
// measured curve, and the constants below are what came out of it.
// The rate, refitted with an instrument that does not need a spectrum.
//
// The original law came from autocorrelating a spectrogram, which is limited by
// the analysis window at the fast end and needs the resonance to stay inside it
// at the slow one. Reading the envelope of a held tone instead -- `phaserrate` --
// measures the same thing with neither constraint:
//
//   ctl2        48     64     80     96    112
//   measured  0.27   0.64   1.51   3.47   8.55  Hz
//   this law  0.270  0.637  1.506  3.559  8.411
//   the old   0.286  0.666  1.551  3.614  8.419
//
// Worst deviation 2.6 per cent against the old law's 5.8. It is a small change
// and it matters more than its size: the comparison render is a second and a
// half, so a few per cent of rate is a few per cent of a cycle of phase error by
// the end of it, and the phase is what the level metric sees.
EFFECT_PHASER_MIN_RATE_HZ :: f32(0.02160)
EFFECT_PHASER_RATE_OCTAVES :: f32(9.7584)

// The circuit, fitted to the measured response rather than guessed.
//
// `tools/phaserfit.py` holds the fitting; the short version is that five numbers
// and a section count reproduce all four types' measured transfer functions to
// about 2 dB rms. It is a cascade of *identical* first-order allpass sections --
// not the staggered ones two earlier attempts assumed -- with one more section
// well above the audio band, positive feedback around the whole chain, and the
// output a fixed sum of dry and wet:
//
//   v   = x + g * A(v)
//   out = d * x + w * A(v)
//
// The check that matters is not the fit. It is that the corner alone predicts
// where every resonance lands, through nothing but the phase accumulating
// 180 degrees per section and the loop resonating wherever it passes a multiple
// of 360:
//
//   sections   resonances predicted from 254.8 Hz, against the comb probe
//    2 (ph1)    2753                                          vs 2771
//    4 (ph2)     253   3918                                   vs  251  3899
//    8 (ph3)     105    254    606   5606                     vs  104   255   605  5457
//   12 (ph4)      68    147    254    439    931   6943       vs   66   147   256   441   932  6613
//
// Thirteen resonances across four types, most within one per cent, from one
// frequency. The section counts are not fitted either: 2, 4, 8 and 12 accumulate
// enough phase for exactly 1, 2, 4 and 6 resonances above DC, which is what the
// probe counted.
EFFECT_PHASER_CORNER_REST_HZ :: f32(254.61)

// Where the sweep is centred, in the corner's own terms.
//
// Not the rest position, and the gap is measured rather than tidied away: the
// corner sits at its rest frequency with the depth at zero and sweeps about this
// one the moment the knob leaves it.
//
// Both this and the span are read by inverting the circuit on the reference's own
// resonances rather than by assuming the resonance is the corner -- which is what
// the earlier reading did, and it is why ph1 appeared to sweep half as far as the
// other types. Inverted, the seven measured depths give a centre of 1272, 1266,
// 1275, 1271, 1271, 1283 and 1162 Hz and a span of 0.0516, 0.0500, 0.0506, 0.0504,
// 0.0510, 0.0499 and 0.0492 octaves per step. That discontinuity is what produces the start-up
// transient recorded in the null test -- the corner slews from where it rests up
// into the band, taking 14 seconds at the shallowest depth and none at all at the
// deepest, where the band already contains the rest point.
EFFECT_PHASER_CORNER_CENTRE_HZ :: f32(1333.5)

// The sweep's width: 0.050 octaves per step of the depth knob.
//
// One law for all four types. It looked like two for a while -- ph1's resonance
// moves only half as far as ph2 to ph4's lowest one at the same depth -- and the
// explanation is in the arctangent rather than in the plugin. ph1's single
// resonance sits where its two sections have already turned 339 of their 360
// degrees, so the phase is deep into saturation and the resonance moves at half
// the corner's rate; the others' lowest resonances sit low, where the response is
// still linear, and track the corner one for one. Doubling this corner moves
// ph1's resonance 0.505 octaves.
EFFECT_PHASER_SPAN_OCTAVES :: f32(6.320)

// The sweep is not symmetric about its centre: it reaches further down than up,
// 0.02615 octaves per step against 0.02361.
//
// Assuming symmetry cost one setting badly. ph2's lowest resonance follows the
// corner, and at full depth it lands near 130 Hz -- which is the note fxcompare
// renders. A symmetric band puts the corner's bottom at 140.7 Hz where the
// reference's is at 133.3, and a resonance that sharp, 7 Hz off a tone, is the
// difference between +24 dB and almost nothing: 17.9 dB of level error at that
// one setting while its timbre was within 3.
//
// Fitted against the corner bands recovered by inverting the circuit on the
// reference's own resonances at seven depths, one shared centre and two slopes
// put every edge within 0.072 octaves, against 0.179 for the symmetric form, and
// the bottom at ctl1 127 at 133.4 Hz against 133.3 measured.
EFFECT_PHASER_SPAN_UP_SHARE :: f32(0.4745)

// What parameter 81 does, which is two different things either side of its
// midpoint and neither of them a level.
//
// Below level 64 it is a crossfade and the feedback is flatly zero: dry falls
// from one to a half while wet rises from nothing to a half. At 64 it arrives at
// a plain 50/50 sum of the input and the chain, and from there to the top the mix
// does not move at all -- fitted independently at seven settings it sits at
// 0.4983 and 0.4977, which is a half to three decimal places -- while the
// feedback rises **linearly**:
//
//   level      80      96     104     112     118     122     127
//   measured  0.2505  0.4977  0.6209  0.7439  0.8361  0.8977  0.9747
//   the law   0.2510  0.4985  0.6217  0.7447  0.8367  0.8981  0.9747
//
// worst deviation 0.0008 over seven settings. A straight line from the knob's
// midpoint, which is what an author writes and not what a fit stumbles into.
EFFECT_PHASER_FEEDBACK_MAX :: f32(0.9747)
EFFECT_PHASER_MIX_KNEE :: f32(64.0 / 127.0)

// The sweep runs at control rate, one step per 512 samples, and the reference's
// own block sets that number rather than the host's. Every period measured on a
// held tone is a whole number of these: 40, 27, 17, 13, 10, 8 and 6 blocks at
// ctl2 88 to 127, each within 0.02 of an integer.
EFFECT_PHASER_CONTROL_BLOCK :: 512

// The demanded rate, rounded down to one whose period is a whole number of
// control blocks.
effect_phaser_block_rate :: proc "contextless" (rate, sr: f32) -> f32 {
	if rate <= 0 {
		return rate
	}
	per_block := sr / f32(EFFECT_PHASER_CONTROL_BLOCK)
	blocks := math.ceil(per_block / rate)
	if blocks < 1 {
		blocks = 1
	}
	return per_block / blocks
}

effect_phaser_feedback :: proc "contextless" (level: f32) -> f32 {
	l := clamp32(level, 0, 1)
	if l <= EFFECT_PHASER_MIX_KNEE {
		return 0
	}
	return EFFECT_PHASER_FEEDBACK_MAX *
		(l - EFFECT_PHASER_MIX_KNEE) / (1.0 - EFFECT_PHASER_MIX_KNEE)
}

effect_phaser_mix :: proc "contextless" (level: f32) -> (dry, wet: f32) {
	l := clamp32(level, 0, 1)
	if l >= EFFECT_PHASER_MIX_KNEE {
		return 0.5, 0.5
	}
	t := l / EFFECT_PHASER_MIX_KNEE
	return 1.0 - 0.5 * t, 0.5 * t
}

// One first-order allpass section.
//
// Each section passes every frequency at full level and rotates its phase from
// nothing at DC to half a turn at Nyquist. A cascade of them accumulates that
// rotation, and with the chain fed back on itself the loop resonates wherever the
// total passes a whole turn -- which is where the comb comes from and why the
// section count sets how many teeth it has.
Allpass1 :: struct {
	z: f32,
}

allpass1_process :: proc "contextless" (a: ^Allpass1, x, coefficient: f32) -> f32 {
	y := coefficient * x + a.z
	a.z = flush_denormal(x - coefficient * y)
	return y
}

// How many allpass sections each phaser type carries.
//
// 2, 4, 8 and 12, which is what the fit converged on from free corners and what
// the resonance count independently requires: each section contributes half a
// turn, so these accumulate enough for exactly 1, 2, 4 and 6 resonances above DC,
// and that is what the comb probe counted.
EFFECT_MAX_PHASER_STAGES :: 12

effect_phaser_stages :: proc "contextless" (type: Effect_Type) -> int {
	switch type {
	case .Phaser_1:
		return 2
	case .Phaser_2:
		return 4
	case .Phaser_3:
		return 8
	case .Phaser_4:
		return 12
	case .Analog_1, .Analog_2, .Digital, .Decimator, .Ring_Mod, .Compressor:
		return 0
	}
	return 0
}

// ---------------------------------------------------------------------------
// WHAT THE EARLIER ATTEMPTS GOT WRONG, KEPT BECAUSE IT IS WHY THIS ONE IS RIGHT
//
// Three structures preceded this one. An allpass chain summed with dry, which
// makes notches where the reference makes resonances. A cascade of band passes,
// which was worse -- error rose monotonically with the stage count and the output
// came out 20 dB quiet. And a single swept resonance, which tied on timbre and
// lost 10 to 13 dB on level, and was parked rather than shipped.
//
// All three failed for the same reason: they were fitted to where the resonances
// are. Resonance positions leave the structure wildly underdetermined -- three
// different section layouts reproduced ph4's six resonances to within 5 per cent
// of each other while sounding different in between. What settled it was fitting
// the whole measured magnitude curve, which rules structures out rather than
// merely accommodating them:
//
//   a pure feedback loop cannot notch deeper than 1/(1+g), which is -6 dB even
//   as g approaches one, and the reference notches -12.15 dB at 262 Hz. So there
//   is a dry path summed with the wet one.
//
//   the response rises toward DC -- +6.04 dB at 16 Hz and still climbing, with
//   that -12.15 notch above it -- which is a resonance at zero frequency, and
//   which is what tells positive feedback from the negative sign that would put
//   a minimum there instead.
//
// The parked resonant version lost on level because the level knob is not a
// level. It is a crossfade for two thirds of its travel and feedback for the
// last third, and no amount of output gain reproduces that.
// ---------------------------------------------------------------------------

// The top of the rate knob, where the exponential stops.
//
// The law was fitted from ctl2 48 to 112 and extrapolated above that, and the
// extrapolation is wrong: the reference's sweep does not keep accelerating. Read
// with an instrument that does not need a spectrum -- the envelope of a held tone,
// autocorrelated, which is what `phaserrate` does -- it saturates:
//
//   ctl2      108    112    116    118    120    122    124    126    127
//   law      6.81   8.42  10.40  11.56  12.85  14.28  15.88  17.65  18.60  Hz
//   measured 6.71   8.55   9.35  10.42  11.76  13.33  15.62  15.62  15.62
//
// (the law's row above is the one this replaced; the refit moves it by a few per
// cent and does not touch where it saturates)
//
// 15.62 Hz is 48000/3072, and every period below the cap is an integer number of
// 512-sample blocks -- 14, 11, 10, 9, 8, 7 and then 6, which is the floor. So the
// reference's sweep advances once per block and cannot go faster than six of them
// to a cycle.
//
// The cap is a fit to the commoner of two behaviours rather than a law. Measured
// across depth at ctl2 127 the reference runs at 15.62 Hz at ctl1 16, 24, 48, 64,
// 96 and 112 and at 18.87 -- the uncapped law -- at 32, 80 and 127, and nothing
// measured so far separates those two sets. Capping is right at more depths than
// it is wrong, 4.74 dB mean across that column against 5.66 without it, and
// removing it inverts which depths are right rather than improving them.
//
// The block quantisation this once claimed is not there. Rendered at 256, 512 and
// 1024 frames to the block the periods do not move -- 53.0 ms at ctl1 32 and 64.0
// at ctl1 64, the same three times over -- and 53.0 ms is not a whole number of
// 1024-sample blocks. They sat near multiples of 512 by coincidence.
//
// What the cap really is: the sweep widens at some depths and not at others, and
// where it widens it also slows by the same factor, 1.208 against the 1.206
// applied below. A relaxation oscillator ramping at a fixed rate takes longer over
// a longer journey, so capping the rate and widening the span are one behaviour
// seen twice. Why it widens at ctl1 16, 24, 48, 64, 96 and 112 but not at 32, 80
// and 127 is not known, and this engine widens at all of them.
EFFECT_PHASER_MAX_RATE_HZ :: f32(15.625)

// How much wider the sweep runs than its span, once the rate has saturated.
effect_phaser_span_widening :: proc "contextless" (ctl2: f32) -> f32 {
	demanded :=
		EFFECT_PHASER_MIN_RATE_HZ *
		math.pow(f32(2.0), EFFECT_PHASER_RATE_OCTAVES * clamp32(ctl2, 0, 1))
	if demanded <= EFFECT_PHASER_MAX_RATE_HZ {
		return 1
	}
	return demanded / EFFECT_PHASER_MAX_RATE_HZ
}

effect_phaser_rate_hz :: proc "contextless" (ctl2: f32) -> f32 {
	rate :=
		EFFECT_PHASER_MIN_RATE_HZ *
		math.pow(f32(2.0), EFFECT_PHASER_RATE_OCTAVES * clamp32(ctl2, 0, 1))
	return min(rate, EFFECT_PHASER_MAX_RATE_HZ)
}

// ----------------------------------------------------------------- parameters

Effect_Params :: struct {
	enabled:       bool,
	type:          Effect_Type,
	// Both controls as 0..1 positions.
	ctl1:          f32,
	ctl2:          f32,
	// Parameter 81 on 0..1.
	level:         f32,
	// The dry and wet gains, derived from `level` *and the type*. See
	// `effect_mix`.
	dry:           f32,
	wet:           f32,

	// Derived from the two controls, in the units named above.
	lowpass_hz:    f32,
	ad1_loop_gain: f32,
	ad1_feedback_hz: f32,
	ad1_shelf_gain: f32,
	ad1_shelf_hz: f32,
	ad1_rest:      f32,
	ad1_post:      [7]f32,
	drive:         f32,
	shape_bias:    f32,
	shape_gain:    f32,
	ring_hz:       f32,
	hold_samples:  f32,
	quantize_bits: f32,
	comp_attack_s: f32,
	comp_makeup:   f32,
	phaser_rate_hz:   f32,
	phaser_span_oct:  f32,
	phaser_feedback:  f32,
	phaser_dry:       f32,
	phaser_wet:       f32,
	phaser_stages:    int,
}

// The dry and wet gains for one type at one level setting.
//
// Parameter 81 does not mean the same thing for every type, and the manual says
// so in a clause easy to read past: "level: 効果の量、または原音とのバランスを調整
// します" -- the *amount* of the effect, **or** the balance with the original
// sound. The "or" is load-bearing. Three different laws were measured.
//
// This was got wrong first time round by measuring the ring modulator and
// generalising. That type was picked precisely because its dry and wet spectra
// are disjoint, which is what made the crossfade readable -- and it is one of only
// two types where a crossfade is what happens. The direct A/B against the
// reference is what caught it: at level 0 the ten types should all have been
// identical to a bypass, and only two were.
//
//   deci., r.m.   a dry/wet crossfade. At level 0 the reference's render is
//                 *bit-identical* to the unit switched off.
//
//                   level        0     16     32     48     64     80     96   127
//                   dry gain  1.000  0.871  0.750  0.624  0.496  0.372  0.245    0
//                   1 - L/127 1.000  0.874  0.748  0.622  0.496  0.370  0.244    0
//
//   the three      wet only, no dry at all, at a gain linear in amplitude. Every
//   distortions    shape reading -- harmonic totals, even/odd split, inharmonic
//                  content -- is *identical* at all nine level settings, so the
//                  knob is a pure output gain and not a drive.
//
//                   level        0     16     32     48     64     80     96   127
//                   wet gain  0.015  0.140  0.264  0.385  0.513  0.632  0.760  1.0
//                   L/127     0.000  0.126  0.252  0.378  0.504  0.630  0.756  1.0
//
//   comp.          wet only again, but at a gain linear in *decibels*: a constant
//                  3.8 dB per 16 steps over a 30 dB range. Measured, and
//                  deliberately not made to match the distortions, because nine
//                  points say it does not.
//
// a.d.2, d.d. and the four phasers were not swept individually. The two remaining
// distortions get a.d.1's law: they share every other control law with it, and
// their level-0 renders show no dry either (the fundamental comes back 28.6 and
// 55.2 dB down). The phasers are the loose end -- at level 0 they are *louder*
// than bypass and broadband, which fits neither law, and is recorded in the notes
// as unfinished rather than papered over.
EFFECT_COMP_LEVEL_RANGE_DB :: f32(30.0)

effect_mix :: proc "contextless" (type: Effect_Type, level: f32) -> (dry, wet: f32) {
	l := clamp32(level, 0, 1)
	switch type {
	case .Decimator, .Ring_Mod:
		return 1.0 - l, l
	case .Compressor:
		// Linear in decibels, so level 0 is 30 dB down rather than silent.
		return 0, math.pow(f32(10.0), -EFFECT_COMP_LEVEL_RANGE_DB * (1.0 - l) / 20.0)
	case .Analog_1, .Analog_2, .Digital:
		return 0, l
	case .Phaser_1, .Phaser_2, .Phaser_3, .Phaser_4:
		// The phasers read parameter 81 themselves -- it sets their feedback and
		// their own dry/wet balance, neither of which is an output gain -- so the
		// unit's mix passes their output through untouched.
		return 0, 1
	}
	return 0, l
}

// Fill in everything derived. Called once per block, off the audio path.
effect_derive :: proc "contextless" (p: ^Effect_Params) {
	p.dry, p.wet = effect_mix(p.type, p.level)
	p.lowpass_hz = effect_lowpass_hz(p.ctl2)
	p.drive = effect_drive(p.ctl1)
	p.shape_bias = 0
	p.shape_gain = 1
	#partial switch p.type {
	case .Analog_1:
		p.drive = effect_ad_table(EFFECT_AD1_DRIVE, p.ctl1)
		p.shape_gain = effect_ad_table(EFFECT_AD1_GAIN, p.ctl1)
		p.ad1_loop_gain = effect_ad_table(EFFECT_AD1_LOOP_GAIN, p.ctl1)
		p.ad1_feedback_hz = effect_ad_table(EFFECT_AD1_FEEDBACK_HZ, p.ctl1)
		p.ad1_shelf_gain = effect_ad_table(EFFECT_AD1_SHELF_GAIN, p.ctl1)
		p.ad1_shelf_hz = effect_ad_table(EFFECT_AD1_SHELF_HZ, p.ctl1)
		p.ad1_rest = effect_ad_table(EFFECT_AD1_REST, p.ctl1)
		p.ad1_post = {
			effect_ad_table(EFFECT_AD1_POST_ZERO_RE_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_ZERO_IM_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_ZERO_REAL_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_POLE_1_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_POLE_2_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_POLE_3_HZ, p.ctl1),
			effect_ad_table(EFFECT_AD1_POST_GAIN, p.ctl1),
		}
	case .Analog_2:
		p.drive = effect_ad_table(EFFECT_AD2_DRIVE, p.ctl1)
		p.shape_gain = effect_ad_table(EFFECT_AD2_GAIN, p.ctl1)
	case .Digital:
		p.drive = effect_ad_table(EFFECT_DD_DRIVE, p.ctl1)
		p.shape_gain = effect_ad_table(EFFECT_DD_GAIN, p.ctl1) * EFFECT_DD_MAKEUP
	}
	p.ring_hz = effect_ring_hz(p.ctl1)
	p.quantize_bits = effect_quantize_bits(p.ctl2)
	p.comp_attack_s = effect_comp_attack_s(p.ctl2)
	p.comp_makeup = effect_comp_makeup(p.ctl1)
	p.phaser_rate_hz = effect_phaser_rate_hz(p.ctl2)
	// The sweep widens where the rate is capped.
	//
	// Below the cap the two agree and this is one. Above it the reference's sweep
	// reaches lower than its span alone allows, and by more the further past the
	// cap the knob is asked to go: at ctl2 124, where the law exceeds the cap by
	// under two per cent, its response at 2960 Hz is the same +8 dB as at ctl2 112,
	// and at 127, where the law asks for nineteen per cent more than the cap can
	// give, it jumps to +21.4 -- at the same measured rate. The extent follows how
	// far the corner would travel in half a period at the rate demanded, while the
	// period is what saturates.
	p.phaser_span_oct =
		EFFECT_PHASER_SPAN_OCTAVES *
		clamp32(p.ctl1, 0, 1) *
		effect_phaser_span_widening(p.ctl2)
	p.phaser_feedback = effect_phaser_feedback(p.level)
	p.phaser_dry, p.phaser_wet = effect_phaser_mix(p.level)
	p.phaser_stages = effect_phaser_stages(p.type)
}

// --------------------------------------------------------------------- state

Effect :: struct {
	// The shared low-pass on the three distortions, a biquad in transposed direct form
	// II, two states per channel, and the coefficients last derived with the corner and
	// sample rate they were derived for: the settings move per block, not per sample.
	lowpass:   [2][2]f32,
	lowpass_key: [2]f32,
	lowpass_coefficients: [4]f32,
	// a.d.1's own pole, as the low content to subtract.
	highpass:  [2]f32,
	// The two-pole high pass the analogue types and d.d. share, two states per
	// channel.
	ad_highpass: [2][2]f32,
	ad_highpass_key: [3]f32,
	ad_highpass_coefficients: [5]f32,
	// a.d.1's feedback loop: two poles of the output, per channel.
	ad1_loop:    [2][2]f32,
	// and the response after it, and the low pass the shelf is built from.
	ad1_post:    [2][3]f32,
	ad1_post_key: [8]f32,
	ad1_post_coefficients: [8]f32,
	// The running mean of the squared term, taken back out of it.
	ad1_quadratic_mean: [2]f32,
	ad1_shelf:    [2]f32,
	// The ring modulator's own oscillator.
	ring_phase: f32,
	// The decimator: the value being held and how much of the step is left.
	hold_value: [2]f32,
	hold_left:  f32,
	// The compressor's detector, held as a mean square so that its settled value
	// for a tone is that tone's RMS -- which is the quantity the static curve was
	// measured in. A mean-absolute detector settles at 2/pi of the amplitude
	// instead of 1/sqrt(2), which would sit the whole curve 0.9 dB off.
	envelope:   f32,
	// The phasers: the sections, and the feedback each channel carries back into
	// its own chain. That feedback is delayed by one sample, which is not an
	// implementation compromise but part of the measurement -- modelling the loop
	// without it puts every resonance too high and costs a factor of ten in fit.
	allpass:    [2][EFFECT_MAX_PHASER_STAGES]Allpass1,
	phaser_fb:  [2]f32,
	// The corner, in octaves above one hertz, because it is slewed rather than
	// assigned and a ramp in octaves is what the measurement found. Starts at the
	// rest position, which is what produces the start-up transient.
	// The corner, in octaves above one hertz, with the direction it is travelling
	// and whether it has been placed yet. There is no LFO phase: the sweep turns
	// on reaching a limit, not on a clock.
	corner_oct:    f32,
	corner_rising: bool,
	corner_set:    bool,
	corner_tick:   int,
	// What the sweep's limits and step come to, with the depth, rate and sample
	// rate they came from.
	sweep_key:     [3]f32,
	sweep_valid:   bool,
	sweep:         Phaser_Sweep,
}

Phaser_Sweep :: struct {
	rest_oct: f32,
	top:      f32,
	bottom:   f32,
	slew:     f32,
}

// Where the phaser's corner rests, the limits it turns at and how far it moves a
// sample, in octaves above one hertz.
phaser_sweep :: proc "contextless" (span_oct, rate_hz, sr: f32) -> Phaser_Sweep {
	up := span_oct * EFFECT_PHASER_SPAN_UP_SHARE
	down := span_oct - up
	centre := math.log2(EFFECT_PHASER_CORNER_CENTRE_HZ)
	return {
		rest_oct = math.log2(EFFECT_PHASER_CORNER_REST_HZ),
		top      = centre + up,
		bottom   = centre - down,
		slew     = 2.0 * span_oct * effect_phaser_block_rate(rate_hz, sr) / sr,
	}
}

effect_reset :: proc "contextless" (e: ^Effect) {
	e^ = {}
}

// -------------------------------------------------------------------- shapers

// a.d.1: asymmetric, so it produces even harmonics.
//
// The asymmetry is what makes the harmonics even. A shaper that is odd-symmetric
// -- f(-x) = -f(x) -- can only produce odd harmonics, however hard it is driven,
// which is why a.d.2 below reads as purely odd and this one does not.
// One sample of the loop: the clip sees the input less what the feedback has
// integrated, and the feedback is two poles of the output.
effect_shape_analog1 :: proc "contextless" (
	state: ^[2]f32,
	x, drive, gain, coef, loop_gain, rest: f32,
) -> f32 {
	// The drive is outside the feedback, so the loop gain is fixed and the
	// response it shapes does not move with the knob. Written the other way --
	// drive * (x - G * s) -- the loop's own loss is 1 + drive * G, which deepened
	// by 20 dB across the knob against a reference whose loss does not move at
	// all.
	//
	// The state is offset so that rest is zero rather than the operating point:
	// with the feedback settled, v = REST and the output is REST, so carrying
	// (output - REST) leaves a loop that starts silent instead of thumping its way
	// down from the rail.
	v := drive * x - loop_gain * state[0] + rest
	y := math.tanh(v) - math.tanh(rest)
	state[0] += (y - state[0]) * coef
	state[0] = flush_denormal(state[0])
	return gain * y
}

// a.d.2: the same curve with no bias, so odd-symmetric and purely odd harmonics.
effect_shape_analog2 :: proc "contextless" (x, drive, gain: f32) -> f32 {
	return gain * math.tanh(x * drive)
}

// d.d.: the fold. A triangle of period four, reflecting at every odd integer.
effect_fold :: proc "contextless" (u: f32) -> f32 {
	v := math.mod(u, f32(4.0))
	if v < 0 {
		v += 4.0
	}
	if v <= 1.0 {
		return v
	}
	if v <= 3.0 {
		return 2.0 - v
	}
	return v - 4.0
}

effect_shape_digital :: proc "contextless" (x, drive, gain: f32) -> f32 {
	return gain * effect_fold(x * drive)
}

// ------------------------------------------------------------------- process

// Process one stereo sample.
//
// `enabled` and a wet gain of zero are both fast paths that return the input
// untouched, which is what makes the section transparent: the reference's own
// level-0 render is bit-identical to the unit being off, and so is this.
effect_process :: proc "contextless" (
	e: ^Effect,
	left_in, right_in: f32,
	p: ^Effect_Params,
	sample_rate: f32,
) -> (
	left, right: f32,
) {
	if !p.enabled {
		return left_in, right_in
	}
	// With no wet signal there is nothing for the effect to contribute, so the
	// processing is skipped -- but the dry gain still applies, and it is not always
	// one. For the decimator and the ring modulator level 0 leaves dry at unity and
	// this returns the input untouched, matching the reference's bit-identical
	// bypass. For the distortions level 0 leaves dry at *zero*, and the reference
	// goes quiet there too.
	if p.wet == 0 {
		return p.dry * left_in, p.dry * right_in
	}

	sr := sample_rate
	if !is_finite(sr) || sr <= 0 {
		sr = 48000.0
	}

	wl := left_in
	wr := right_in

	switch p.type {
	case .Analog_1:
		// The shelf goes in front and the steep high pass behind, and which side
		// each sits on is forced rather than chosen. The loss has to survive the
		// clip -- put it all in front and a drive of three hundred turns a 33 Hz
		// input cut by 44 dB back into a square wave, which reads +32.6 dB against
		// the reference. The tilt has to *not* survive it, because a shelf behind
		// the clip multiplies every harmonic the loop makes and the fit falls from
		// 2.84 dB to 5.30. Split, the response lands within 0.61 dB and the
		// harmonics within 3.95, and the high pass is above 131 Hz by then so it
		// barely touches them.
		shelf := one_pole_coef(p.ad1_shelf_hz, sr)
		e.ad1_shelf[0] += (wl - e.ad1_shelf[0]) * shelf
		e.ad1_shelf[1] += (wr - e.ad1_shelf[1]) * shelf
		e.ad1_shelf[0] = flush_denormal(e.ad1_shelf[0])
		e.ad1_shelf[1] = flush_denormal(e.ad1_shelf[1])
		sg := p.ad1_shelf_gain
		wl = sg * wl + (1.0 - sg) * e.ad1_shelf[0]
		wr = sg * wr + (1.0 - sg) * e.ad1_shelf[1]

		coef := one_pole_coef(p.ad1_feedback_hz, sr)
		wl = effect_shape_analog1(&e.ad1_loop[0], wl, p.drive, p.shape_gain, coef, p.ad1_loop_gain, p.ad1_rest)
		wr = effect_shape_analog1(&e.ad1_loop[1], wr, p.drive, p.shape_gain, coef, p.ad1_loop_gain, p.ad1_rest)

		wl, wr = effect_ad_highpass_held(
			e,
			wl,
			wr,
			EFFECT_AD_HIGHPASS_HZ,
			EFFECT_AD_HIGHPASS_Q,
			sr,
		)
		// The squared term carries a constant, and the section after it has a pole under
		// 1 Hz and a gain of tens at DC, so a constant here would be a slow thump on
		// every note-on and note-off. Only its varying part is wanted.
		mean_coef := one_pole_coef(EFFECT_ANALOG1_QUADRATIC_MEAN_HZ, sr)
		square_l := wl * wl
		square_r := wr * wr
		e.ad1_quadratic_mean[0] += (square_l - e.ad1_quadratic_mean[0]) * mean_coef
		e.ad1_quadratic_mean[1] += (square_r - e.ad1_quadratic_mean[1]) * mean_coef
		e.ad1_quadratic_mean[0] = flush_denormal(e.ad1_quadratic_mean[0])
		e.ad1_quadratic_mean[1] = flush_denormal(e.ad1_quadratic_mean[1])
		wl += EFFECT_ANALOG1_MID_QUADRATIC * (square_l - e.ad1_quadratic_mean[0])
		wr += EFFECT_ANALOG1_MID_QUADRATIC * (square_r - e.ad1_quadratic_mean[1])
		wl, wr = effect_analog1_post(e, wl, wr, &p.ad1_post, sr)
		wl, wr = effect_lowpass(e, wl, wr, p.lowpass_hz, sr)

	case .Analog_2:
		wl = effect_shape_analog2(wl, p.drive, p.shape_gain)
		wr = effect_shape_analog2(wr, p.drive, p.shape_gain)
		wl, wr = effect_ad_highpass_held(
			e,
			wl,
			wr,
			EFFECT_AD_HIGHPASS_HZ,
			EFFECT_AD_HIGHPASS_Q,
			sr,
		)
		wl, wr = effect_lowpass(e, wl, wr, p.lowpass_hz, sr)

	case .Digital:
		wl = effect_shape_digital(wl, p.drive, p.shape_gain)
		wr = effect_shape_digital(wr, p.drive, p.shape_gain)
		wl, wr = effect_ad_highpass_held(
			e,
			wl,
			wr,
			EFFECT_AD_HIGHPASS_HZ,
			EFFECT_AD_HIGHPASS_Q,
			sr,
		)
		wl, wr = effect_lowpass(e, wl, wr, p.lowpass_hz, sr)

	case .Decimator:
		// Sample and hold. A step of zero means no rate reduction, and the input
		// passes to the quantiser unheld.
		if p.hold_samples >= 1 {
			if e.hold_left <= 0 {
				e.hold_value[0] = wl
				e.hold_value[1] = wr
				e.hold_left += p.hold_samples
			}
			e.hold_left -= 1
			wl = e.hold_value[0]
			wr = e.hold_value[1]
		}
		if p.quantize_bits < EFFECT_QUANTIZE_BYPASS_BITS {
			step := 2.0 / math.pow(f32(2.0), p.quantize_bits)
			if step > 0 {
				wl = math.round(wl / step) * step
				wr = math.round(wr / step) * step
			}
		}

	case .Ring_Mod:
		// ctl2 is deliberately unread. The reference's second control is inert for
		// this type at every setting -- five settings gave bit-identical renders --
		// and the manual says so too.
		modulator := math.sin(TAU * e.ring_phase)
		e.ring_phase += p.ring_hz / sr
		e.ring_phase -= math.floor(e.ring_phase)
		wl *= modulator
		wr *= modulator

	case .Compressor:
		// Depth first, as an input gain, because that is where the measurement
		// puts it: every depth's curve collapses onto one curve when it is plotted
		// against the level *after* this gain. It is not make-up applied at the
		// end -- doing it there would leave the leveller seeing a different signal
		// at every depth and the collapse would not hold.
		wl *= p.comp_makeup
		wr *= p.comp_makeup

		// The detector, on the mean square of the pair. One detector and one gain
		// for both channels: two would move the image whenever the two sides
		// differed, and the unit is a single slot.
		square := 0.5 * (wl * wl + wr * wr)
		coef := one_pole_coef_time(p.comp_attack_s, sr)
		e.envelope += (square - e.envelope) * coef
		e.envelope = flush_denormal(e.envelope)

		gain := effect_comp_gain(math.sqrt(max(e.envelope, 0)))
		wl *= gain
		wr *= gain

	case .Phaser_1, .Phaser_2, .Phaser_3, .Phaser_4:
		sweep_key := [3]f32{p.phaser_span_oct, p.phaser_rate_hz, sr}
		if !e.sweep_valid || e.sweep_key != sweep_key {
			e.sweep = phaser_sweep(p.phaser_span_oct, p.phaser_rate_hz, sr)
			e.sweep_key = sweep_key
			e.sweep_valid = true
		}
		rest_oct := e.sweep.rest_oct
		top := e.sweep.top
		bottom := e.sweep.bottom

		if !e.corner_set {
			e.corner_oct = rest_oct
			// Which way it sets off, and the reference decides it by where the rest
			// point falls relative to the band rather than by a phase. Below the
			// band it climbs in; inside it, it descends. Held at 2489 Hz, just under
			// the 2771 Hz resonance the corner rests at, the reference's response
			// falls at ctl1 32 and 64 and rises at 96 and 127 -- up, up, down, down,
			// which is exactly where the rest point crosses the band's lower edge.
			e.corner_rising = rest_oct < bottom
			e.corner_set = true
		}

		if p.phaser_span_oct <= 0 {
			// Depth at zero: no modulation, and the corner sits where it rests.
			e.corner_oct = rest_oct
		} else {
			// The sweep is a relaxation oscillator, not a clocked one: the corner
			// ramps at a fixed rate and turns when it arrives at a limit rather than
			// when a phase says so.
			//
			// In steady state the two are the same -- the ramp covers the span in
			// half a period either way -- and they differ in one place, which is the
			// first limb after a note. The corner starts at its rest point, which is
			// not on the band's edge, so what it has to travel is not a limb's
			// worth. A clock turns it around on time; a limit turns it around when it
			// arrives; and the reference does the second, its resonance still
			// descending at 734 ms where a clocked sweep had turned at 543.
			//
			// Nothing here guards against snapping to a limit from outside the band,
			// because choosing the starting direction above makes it impossible: a
			// corner resting below the band sets off upward and does not meet the
			// lower limit until it has been to the top, by which time it is inside.
			// Guarding it explicitly instead was tried and disabled the lower limit
			// for good, which let the corner run away downward and cost 29 dB at the
			// one setting where the widened span puts the rest point outside.
			// The rate is quantised so that a period is a whole number of control
			// blocks, which is the one thing the held-tone probe reads directly:
			// every period the reference produces is an integer number of them, 40,
			// 27, 17, 13, 10, 8 and 6 at ctl2 88 to 127, each within 0.02 of an
			// integer, and each the demanded period rounded up.
			//
			// Two other readings were tried and are wrong. Stepping the corner once
			// per block cost 16 dB: at ctl2 96 a block is a quarter of an octave and
			// the comb would jump that far in one sample. Turning at the first
			// boundary past the limit instead is right in kind but accumulates -- the
			// overshoot is carried into the next limb, which lengthens the one after,
			// and the period settled two blocks long at every rate (30 blocks against
			// the reference's 27, 20 against 17, 8 against 6).
			//
			// Rounding up is also what the top of the knob was: the rate does not
			// stop climbing at 15.6 Hz because anything caps it, but because ctl2 124
			// and 127 both demand a period between five and six blocks and both get
			// six. And it explains the one pattern that had no reading as a law --
			// the sweep runs wide at ctl1 28, 32 and 38 and not at 30, 34 or 36,
			// which is no ordering in depth at all. At ctl2 127 the demand is 5.04
			// blocks, four per cent above the tie, so a rate that varies with depth by
			// under one per cent lands on either side of it and rounding turns that
			// into a fifth of a period. The step is taken
			// and the limit is tested at the same instant, so the corner turns
			// wherever the block boundary finds it -- past the limit, not on it --
			// and both the period and the excursion round up to what the boundary
			// allows. It explains three measurements at once that had been recorded
			// as separate defects: the period is always a whole number of blocks;
			// the excursion runs wider than the band by the overshoot, measured at
			// 1.208 where this predicts 1.19; and the rate stops climbing near 15.6
			// Hz, which is not a cap but the top of the staircase, two limbs of
			// three blocks.
			//
			// It also accounts for the one pattern that made no sense as a law. The
			// widening appears at some depths and not others, alternating -- ctl1
			// 28, 32 and 38 wide, 30, 34 and 36 not -- which is no ordering in depth
			// at all. Here it needs none: the limit is where depth puts it, and
			// whether a boundary lands just short of it or just past it turns over
			// from one depth to the next.
			slew := e.sweep.slew
			if e.corner_rising {
				e.corner_oct += slew
				if e.corner_oct >= top {
					e.corner_oct = top
					e.corner_rising = false
				}
			} else {
				e.corner_oct -= slew
				if e.corner_oct <= bottom {
					e.corner_oct = bottom
					e.corner_rising = true
				}
			}
		}

		corner := math.pow(f32(2.0), e.corner_oct)
		t := math.tan(0.5 * TAU * clamp32(corner, 10.0, sr * 0.45) / sr)
		coefficient := (t - 1.0) / (t + 1.0)
		stages := clamp(p.phaser_stages, 1, EFFECT_MAX_PHASER_STAGES)
		vl := wl + p.phaser_feedback * e.phaser_fb[0]
		vr := wr + p.phaser_feedback * e.phaser_fb[1]
		for s in 0 ..< stages {
			vl = allpass1_process(&e.allpass[0][s], vl, coefficient)
			vr = allpass1_process(&e.allpass[1][s], vr, coefficient)
		}
		e.phaser_fb[0] = flush_denormal(vl)
		e.phaser_fb[1] = flush_denormal(vr)

		wl = p.phaser_dry * wl + p.phaser_wet * vl
		wr = p.phaser_dry * wr + p.phaser_wet * vr
	}

	l := p.dry * left_in + p.wet * wl
	r := p.dry * right_in + p.wet * wr
	return sanitize(l), sanitize(r)
}

effect_lowpass :: proc "contextless" (
	e: ^Effect,
	l, r, corner_hz, sample_rate: f32,
) -> (
	f32,
	f32,
) {
	key := [2]f32{corner_hz, sample_rate}
	if e.lowpass_key != key {
		w := TAU * clamp32(corner_hz, 1.0, sample_rate * 0.45) / sample_rate
		cs := math.cos(w)
		alpha := math.sin(w) / (2.0 * EFFECT_LOWPASS_Q)
		a0 := 1.0 + alpha
		e.lowpass_coefficients = {(1.0 - cs) * 0.5 / a0, (1.0 - cs) / a0, -2.0 * cs / a0, (1.0 - alpha) / a0}
		e.lowpass_key = key
	}
	b0, b1, a1, a2 := e.lowpass_coefficients[0], e.lowpass_coefficients[1], e.lowpass_coefficients[2], e.lowpass_coefficients[3]

	step :: proc "contextless" (z: ^[2]f32, x, b0, b1, a1, a2: f32) -> f32 {
		y := b0 * x + z[0]
		z[0] = flush_denormal(b1 * x - a1 * y + z[1])
		z[1] = flush_denormal(b0 * x - a2 * y)
		return y
	}
	return step(&e.lowpass[0], l, b0, b1, a1, a2), step(&e.lowpass[1], r, b0, b1, a1, a2)
}
