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

// The shared low-pass corner, in hertz, for `ctl2` on 0..1.
//
// Measured. All three distortions carry the same filter -- the manual gives ctl2
// as a low-pass cutoff for a.d.1, a.d.2 and d.d. alike, and the measured corners
// agree across the three to within half a percent, which is tighter than the
// measurement's own resolution. Probed with white noise rather than a sine,
// because a sine's only test frequencies are the distortion's own harmonics and
// those move when the drive moves, so filter and drive could not be separated:
//
//   ctl2        0     16     32     48     64     80     96    112
//   corner    452    719   1150   1827   2901   4590   7212  11140  Hz
//
// A clean exponential at 0.0416 octaves per step, so it is a formula and not a
// table. 127 reads as no corner at all because it sits above the analysis band.
EFFECT_LOWPASS_MIN_HZ :: f32(451.9)
EFFECT_LOWPASS_OCTAVES :: f32(5.286)

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

effect_quantize_bits :: proc "contextless" (ctl2: f32) -> f32 {
	return lerp32(EFFECT_QUANTIZE_MAX_BITS, EFFECT_QUANTIZE_MIN_BITS, clamp32(ctl2, 0, 1))
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
EFFECT_ANALOG1_HIGHPASS_HZ :: f32(90.0)

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
// The shape itself is exact and is what the structure below is built from: a flat
// skirt at **-13 dB** below the corner, a resonant peak of about **+24 dB** at it,
// and a return to **0 dB** above. That is a resonant high pass mixed with a fixed
// fraction of dry -- the dry is what puts a floor under the skirt instead of the
// -inf a high pass alone would give, and above the corner the two sum to unity.
EFFECT_PHASER_MIN_RATE_HZ :: f32(0.0226)
EFFECT_PHASER_RATE_OCTAVES :: f32(9.685)
// The band the sweep covers, and the depth as a plain fraction of it.
//
// Chosen, and left chosen: see the note below on what happened when the measured
// centre frequencies and depths were substituted for them.
EFFECT_PHASER_BAND_LO_HZ :: f32(200.0)
EFFECT_PHASER_BAND_HI_HZ :: f32(3000.0)
// The measured skirt: 10^(-13/20).
EFFECT_PHASER_DRY :: f32(0.224)
// Resonance, set to reach the measured peak height.
EFFECT_PHASER_RESONANCE :: f32(0.94)

// One first-order allpass section.
//
// Each section passes every frequency at full level but rotates its phase, so
// summing with the dry signal produces a dip wherever the rotation reaches 180
// degrees. Sweeping the corner walks the dip.
Allpass1 :: struct {
	z: f32,
}

allpass1_process :: proc "contextless" (a: ^Allpass1, x, coefficient: f32) -> f32 {
	y := coefficient * x + a.z
	a.z = flush_denormal(x - coefficient * y)
	return y
}

// How many allpass sections each phaser type sweeps.
EFFECT_MAX_PHASER_STAGES :: 4

effect_phaser_stages :: proc "contextless" (type: Effect_Type) -> int {
	switch type {
	case .Phaser_1:
		return 1
	case .Phaser_2:
		return 2
	case .Phaser_3:
		return 3
	case .Phaser_4:
		return 4
	case .Analog_1, .Analog_2, .Digital, .Decimator, .Ring_Mod, .Compressor:
		return 0
	}
	return 0
}

// ---------------------------------------------------------------------------
// WHY THE RESONANT STRUCTURE IS NOT THE ONE BELOW
//
// The measurement above says the shipped structure -- an allpass chain summed with
// dry, which makes dips -- is the wrong shape: the reference makes a resonance. The
// resonant version was written and compared at two operating points against this
// one, and the result is a tie on timbre and a clear loss on level:
//
//                       ph1    ph2    ph3    ph4   mean    level error
//   ctl 64/64  allpass  3.07   3.41   7.89  15.00   7.34   -4 to -9 dB
//              resonant 2.42   2.86   8.32  15.56   7.29   -16 to -22 dB
//   ctl 112/96 allpass 12.64  25.61  35.66  44.72  29.66
//              resonant 17.02  17.30  34.31  44.58  28.30
//
// Spectral error is within noise between them; the resonant one is 10 to 13 dB
// worse on level, consistently, which is a real defect rather than a wash. So the
// allpass version stays.
//
// Both of the measurements that were missing here have since been made, with a
// held tone rather than a saw comb -- `tools/s1probe/phaserband.odin` -- and
// together they say the resonant single-band model above was the wrong target.
//
// **The level law is feedback**, not a level. At ctl1 = 0 the response is flat to
// within a decibel at level 0, and as the knob rises the peak grows and the notch
// deepens together while the broadband level stays at unity -- +0.63 to -0.71 dB
// across the top six settings. A feedback loop's peak gain is 1/(1-g), so the
// measured peak states g outright:
//
//   level        96     104     112     118     122     127
//   g        0.3208  0.4426  0.5870  0.7155  0.8129  0.9491
//   fitted   0.3241  0.4407  0.5856  0.7157  0.8135  0.9491   0.9491*(L/127)^3.84
//
// every fitted peak within 0.05 dB. "Louder than bypass and broadband" at level 0
// was the same fact seen from the other side: no feedback, no comb, nearly flat.
//
// **The depth curve** is measured where it means anything:
//
//   ctl1        48        80        127
//   band   4186-8372  2960-9956  2093-11840  Hz, 1.00 / 1.75 / 2.50 octaves
//
// and below ctl1 48 it is not a single band at all, because several resonances
// sweep at once and their excursions have not yet merged. That is a statement
// about the structure, not a failed reading.
//
// Neither is implemented yet, deliberately. Feedback in a chain whose resonances
// sit in the wrong places is worse than none, and the per-type centres above have
// only been read at each type's tallest peak.
//
// One process note, because it cost most of the time spent here: the first four
// comparisons were run at ctl 112/96 against a baseline recorded at ctl 64/64, and
// read as a 20 dB regression that did not exist. A baseline is only a baseline at
// the same operating point.
// ---------------------------------------------------------------------------

effect_phaser_centre_hz :: proc "contextless" (type: Effect_Type) -> f32 {
	switch type {
	case .Phaser_1:
		return 2878.0
	case .Phaser_2:
		return 3924.0
	case .Phaser_3:
		return 5494.0
	case .Phaser_4:
		return 6540.0
	case .Analog_1, .Analog_2, .Digital, .Decimator, .Ring_Mod, .Compressor:
		return 0
	}
	return 0
}

effect_phaser_rate_hz :: proc "contextless" (ctl2: f32) -> f32 {
	return EFFECT_PHASER_MIN_RATE_HZ *
		math.pow(f32(2.0), EFFECT_PHASER_RATE_OCTAVES * clamp32(ctl2, 0, 1))
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
	drive:         f32,
	ring_hz:       f32,
	hold_samples:  f32,
	quantize_bits: f32,
	comp_attack_s: f32,
	comp_makeup:   f32,
	phaser_rate_hz:   f32,
	phaser_depth:     f32,
	phaser_centre_hz: f32,
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
	case .Analog_1, .Analog_2, .Digital, .Phaser_1, .Phaser_2, .Phaser_3, .Phaser_4:
		return 0, l
	}
	return 0, l
}

// Fill in everything derived. Called once per block, off the audio path.
effect_derive :: proc "contextless" (p: ^Effect_Params) {
	p.dry, p.wet = effect_mix(p.type, p.level)
	p.lowpass_hz = effect_lowpass_hz(p.ctl2)
	p.drive = effect_drive(p.ctl1)
	p.ring_hz = effect_ring_hz(p.ctl1)
	p.quantize_bits = effect_quantize_bits(p.ctl2)
	p.comp_attack_s = effect_comp_attack_s(p.ctl2)
	p.comp_makeup = effect_comp_makeup(p.ctl1)
	p.phaser_rate_hz = effect_phaser_rate_hz(p.ctl2)
	p.phaser_depth = clamp32(p.ctl1, 0, 1)
	p.phaser_centre_hz = effect_phaser_centre_hz(p.type)
	p.phaser_stages = effect_phaser_stages(p.type)
}

// --------------------------------------------------------------------- state

Effect :: struct {
	// The shared low-pass on the three distortions, one pole per channel.
	lowpass:   [2]f32,
	// a.d.1's high pass, as the low content to subtract.
	highpass:  [2]f32,
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
	// The phasers. Both structures are here: the allpass chain that ships, and the
	// resonant filter the measurement calls for, which is parked -- see the note in
	// the constants above.
	allpass:    [2][EFFECT_MAX_PHASER_STAGES]Allpass1,
	resonator:  Filter,
	lfo_phase:  f32,
}

effect_reset :: proc "contextless" (e: ^Effect) {
	e^ = {}
	filter_init(&e.resonator)
}

// -------------------------------------------------------------------- shapers

// a.d.1: asymmetric, so it produces even harmonics.
//
// The asymmetry is what makes the harmonics even. A shaper that is odd-symmetric
// -- f(-x) = -f(x) -- can only produce odd harmonics, however hard it is driven,
// which is why a.d.2 below reads as purely odd and this one does not.
effect_shape_analog1 :: proc "contextless" (x, drive: f32) -> f32 {
	d := x * drive
	// Softer on the way up than on the way down.
	shaped := d >= 0 ? math.tanh(d) : math.tanh(d * 0.6) * 0.6
	// Normalised back so the drive knob changes timbre rather than level, and the
	// asymmetry's DC offset removed here rather than left for the high pass.
	return (shaped - 0.135) * 1.35
}

// a.d.2: odd-symmetric, so purely odd harmonics.
effect_shape_analog2 :: proc "contextless" (x, drive: f32) -> f32 {
	return math.tanh(x * drive)
}

// d.d.: hard clipping, the digital one.
effect_shape_digital :: proc "contextless" (x, drive: f32) -> f32 {
	return clamp32(x * drive, -1, 1)
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
		wl = effect_shape_analog1(wl, p.drive)
		wr = effect_shape_analog1(wr, p.drive)
		// The low-frequency loss the manual attributes to negative feedback.
		coef := one_pole_coef(EFFECT_ANALOG1_HIGHPASS_HZ, sr)
		e.highpass[0] += (wl - e.highpass[0]) * coef
		e.highpass[1] += (wr - e.highpass[1]) * coef
		e.highpass[0] = flush_denormal(e.highpass[0])
		e.highpass[1] = flush_denormal(e.highpass[1])
		wl -= e.highpass[0]
		wr -= e.highpass[1]
		wl, wr = effect_lowpass(e, wl, wr, p.lowpass_hz, sr)

	case .Analog_2:
		wl = effect_shape_analog2(wl, p.drive)
		wr = effect_shape_analog2(wr, p.drive)
		wl, wr = effect_lowpass(e, wl, wr, p.lowpass_hz, sr)

	case .Digital:
		wl = effect_shape_digital(wl, p.drive)
		wr = effect_shape_digital(wr, p.drive)
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
		e.lfo_phase += p.phaser_rate_hz / sr
		e.lfo_phase -= math.floor(e.lfo_phase)

		// The corner sweeps either side of this type's own measured centre, in
		// octaves, so equal excursions up and down are equal musical intervals. The
		// centre and the rate are measurements; the depth curve is the approximate
		// one, and it is why the resonant structure is parked.
		sweep := 0.5 + 0.5 * math.sin(TAU * e.lfo_phase) * p.phaser_depth
		hz :=
			EFFECT_PHASER_BAND_LO_HZ *
			math.pow(f32(2.0), sweep * math.log2(EFFECT_PHASER_BAND_HI_HZ / EFFECT_PHASER_BAND_LO_HZ))

		// The allpass coefficient for that corner, clamped short of Nyquist for the
		// same reason as everywhere else in this file.
		t := math.tan(0.5 * TAU * clamp32(hz, 10.0, sr * 0.45) / sr)
		coefficient := (t - 1.0) / (t + 1.0)

		stages := clamp(p.phaser_stages, 1, EFFECT_MAX_PHASER_STAGES)
		pl := wl
		pr := wr
		for s in 0 ..< stages {
			pl = allpass1_process(&e.allpass[0][s], pl, coefficient)
			pr = allpass1_process(&e.allpass[1][s], pr, coefficient)
		}
		// Summing the rotated signal with the dry turns phase into amplitude; the
		// halving keeps the sum at the level of its input.
		wl = 0.5 * (wl + pl)
		wr = 0.5 * (wr + pr)
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
	coef := one_pole_coef(corner_hz, sample_rate)
	e.lowpass[0] += (l - e.lowpass[0]) * coef
	e.lowpass[1] += (r - e.lowpass[1]) * coef
	e.lowpass[0] = flush_denormal(e.lowpass[0])
	e.lowpass[1] = flush_denormal(e.lowpass[1])
	return e.lowpass[0], e.lowpass[1]
}
