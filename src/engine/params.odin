package engine

import "core:math"
import "../dsp"

// Layer 1 parameter vocabulary.
//
// Everything here is in engine units -- hertz, seconds, semitones, cents, a
// signed fraction -- never in stored .sy1 integers and never in VST normalised
// values. The whole point of the split is that `Voice` never has to know that a
// filter cutoff arrived as the integer 81, and `binding.odin` is the single
// place where that translation is written down and justified.

MAX_UNISON :: 8
MAX_POLYPHONY :: 32

// How far the LFO moves each destination at full depth, measured with
// `s1probe lfodepth`.
//
// These were guesses -- twelve semitones, four octaves, a law that ducked the
// amplitude all the way to silence, unity for pan -- and correcting the
// destination mapping without them was what made the null test worse.
//
// The measurement drives one destination at one depth and reads the range the
// observable moves over, peak to peak, so the LFO's shape and starting phase drop
// out. Per depth setting, at note C5:
//
//   depth    pitch      cutoff    volume     pan
//      32   3.77 st   1.34 oct   1.75 dB   0.386
//      64  10.54 st   1.91 oct   4.01 dB   0.669
//      96  22.66 st   2.17 oct   7.13 dB   0.842
//     127  42.33 st   2.50 oct  11.93 dB   0.927
//
// The cutoff column carries a noise floor of about 0.6 octaves, because its
// corner is estimated from a noise source; the figure below is the full-depth
// reading with that removed in quadrature. The others read as nothing at depth
// zero, which is the check that they are measuring the modulation and not the
// note's own edges.
// The pitch figure in that table is superseded, and so is the caveat that used to
// stand here about it varying with the note played. It does not vary. The sweep
// did.
//
// `s1probe lfopitch` sets the LFO to a **square**, which stops the pitch sweeping
// and makes it two steady values that can each be measured at full precision --
// the interval between them is then the depth by construction, with no percentile
// band and no tracking of a moving tone. That measurement is only available now
// because `s1probe lfoshape` established which state the square is; before it,
// this setting selected sample and hold.
//
// Read that way, at full depth the pitch goes to **exactly five octaves above the
// note** -- 2093.09 Hz at note 36, 4186.07 at 48, 8371.94 at 60, each of them the
// played note times 32.00 -- and the same distance below. It is note-independent
// to the last digit the instrument prints, and it is symmetric: the up and down
// excursions agree within 0.03 semitones at every setting where both are inside
// the analysis range.
//
// The old method's two faults account for the old answer. `span` reports a 5th to
// 95th percentile band rather than a range, and a triangle distributes its pitch
// uniformly, so a tenth of the travel was discarded before anything else. And
// tracking a swept tone costs resolution unevenly: the window's bins are 11.7 Hz
// apart at every note, which is 38 cents at C5 and 290 at C2.
LFO_PITCH_SEMITONES :: f32(60.0)

// The depth knob is not linear, and this is the curve it follows.
//
// Twenty settings measured across the range fit `(exp(k*u) - 1) / (exp(k) - 1)`
// at k = 2.3 to within 0.10 semitones of 60 -- below what the instrument itself
// resolves. The anchored form is the same one the chorus depth uses, and it is
// anchored for the same reason: it must be exactly zero at zero, because a depth
// of zero is no modulation at all.
//
//   stored      4     16     32     56     80    104    127
//   measured 0.47   2.15   5.16  11.72  21.75  37.22  60.00  semitones
//   this law 0.50   2.25   5.25  11.75  21.78  37.28  60.00
//
// k is pinned rather than bracketed: 2.2 and 2.4 are off by 0.65 and 0.45
// semitones at stored 64 where 2.3 is off by 0.09, so the measurement determines
// it to about +/-0.03.
//
// It is applied to the pitch destinations **only**, and that restraint is
// deliberate rather than tidy. The same curve very likely drives every
// destination -- one modulation amount scaled per destination is the obvious
// design, and the volume column of the table above is closer to this curve than
// to a linear reading at all three of its points. But the cutoff and pan columns
// are not, and both of those instruments are known to saturate: the pan reading
// is against the stereo rails by depth 48, which `s1probe lfoshape` shows
// directly. Re-measuring those two with a square LFO -- the same trick that
// settled pitch -- is what would license moving them, and until then applying an
// unverified curve to three destinations on the strength of a fourth would be
// exactly the mistake this file has recorded twice.
//
// Full depth is unaffected either way: the curve is 1.0 at the top of the knob,
// so only intermediate settings move.
LFO_DEPTH_CURVE_K :: f32(2.3)

// The depth knob's 0..1 position mapped through that curve.
lfo_pitch_depth_curve :: proc(unit: f32) -> f32 {
	u := dsp.clamp32(unit, 0, 1)
	return (math.exp(LFO_DEPTH_CURVE_K * u) - 1.0) / (math.exp(LFO_DEPTH_CURVE_K) - 1.0)
}
// The filter cutoff, measured the same way and **unipolar**.
//
// `s1probe lfosquare --dest 3` reads the corner in each half of a square, through
// a centroid calibrated against the reference's own static cutoff sweep -- the
// -3 dB crossing every other filter measurement here uses turned out far too noisy
// to survive being split into two levels.
//
// The finding that matters is not the number. The low half of the square sits at
// **exactly the unmodulated corner** at every depth, and still does with the base
// moved from 585 Hz to 7 kHz, so this destination never closes the filter -- it
// only opens it. That also explains an old observation in
// `docs/reference-notes.md` which had no explanation at the time: with the cutoff
// wide open the LFO produces a bit-identical render, which a bipolar modulation
// could not do because its downward half would still have somewhere to go.
//
//   depth              8      32      64      96
//   octaves up     0.317   1.262   2.553   3.881
//   / (depth/127)   5.03    5.01    5.07    5.13
//
// Linear in the knob, to about 2%. The full-depth figure is the slope of that
// line rather than a reading, because at full depth the corner is pushed past the
// top of the filter's own range and cannot be observed.
LFO_CUTOFF_OCTAVES :: f32(5.06)

// The volume duck, which is **linear in amplitude and reaches silence**.
//
// This restores what a previous pass replaced. That pass measured a swept
// triangle through a percentile band, concluded the reference ducked by 11.93 dB,
// and recorded that the law it was replacing -- ducking to silence -- went "about
// 40 dB deeper than the reference goes". The percentile band is exactly what
// cannot see a momentary silence.
//
// Read off a square, the upper level sits at the unmodulated level at every depth,
// so like the cutoff this destination is unipolar; and the *amplitude* removed is
// the knob position, to three decimal places:
//
//   depth                 8     32     64     96    127
//   amplitude removed 0.063  0.251  0.504  0.756  1.000
//   depth / 127       0.063  0.252  0.504  0.756  1.000
//
// So there is no decibel constant here at all. At full depth the note is silent at
// the bottom of the LFO's cycle, which is why this needs no scaling factor and why
// the one it had was wrong.

// The stereo position, bipolar and symmetric -- unlike the two above -- and
// reaching a hard-panned image at full depth rather than the 0.927 measured
// before.
//
// The curve is strongly concave, which is the opposite of the pitch destination's,
// and it is the reason this is a table. Measured as the pan value our own law
// needs in order to reproduce the reference's channel ratio, which makes it
// independent of what the reference does internally:
//
//   depth   8    16    24    32    48    64    80    96   112   127
//   pan  .243  .425  .565  .673  .823  .913  .964  .990  .999 1.000
//
// The last two are against the rails -- an image cannot be panned harder than hard
// -- so they are bounds. Everything from 96 up is within a hundredth of full.
LFO_PAN_DEPTH_STEPS := [10]int{8, 16, 24, 32, 48, 64, 80, 96, 112, 127}
LFO_PAN_DEPTH_VALUES := [10]f32{0.243, 0.425, 0.565, 0.673, 0.823, 0.913, 0.964, 0.990, 0.999, 1.000}

// The pan depth for a knob position on 0..1, interpolated between the measured
// points and running to zero at the bottom.
lfo_pan_depth_curve :: proc(unit: f32) -> f32 {
	u := dsp.clamp32(unit, 0, 1) * 127.0
	if u <= 0 {
		return 0
	}
	prev_step := f32(0)
	prev_value := f32(0)
	for i in 0 ..< len(LFO_PAN_DEPTH_STEPS) {
		step := f32(LFO_PAN_DEPTH_STEPS[i])
		value := LFO_PAN_DEPTH_VALUES[i]
		if u <= step {
			span := step - prev_step
			if span <= 0 {
				return value
			}
			t := (u - prev_step) / span
			return prev_value + t * (value - prev_value)
		}
		prev_step = step
		prev_value = value
	}
	return 1.0
}

// The note the filter's keyboard tracking is measured from: C3, an octave below
// middle C. Measured -- see the use site in `voice_process`.
FILTER_TRACK_REFERENCE_NOTE :: f32(48.0)

// Where the band pass centres, against the corner `FILTER_CUTOFF_HZ` records.
//
// That table was measured on the 12 dB *low pass*, as its own header says, and
// the reference's band pass does not centre on the same frequency for the same
// knob setting -- it sits about a minor third below. Ours centred exactly on the
// table, so every band-pass patch was two and a half semitones sharp.
//
// Measured at five cutoff settings spanning five octaves, with the resonance at
// maximum so the peak is unmistakable, as the reference's peak over ours:
//
//   stored      17      32      48      64      80
//   ratio    0.868   0.868   0.860   0.855   0.844
//
// One constant rather than a table, because the drift across the five is 2.8%
// and in one direction -- real, but a twentieth of what it is correcting, and
// small enough that a table would be fitting the last decimal of a corner
// estimate. The drift is recorded rather than modelled. Stored 96 was measured
// and thrown out: the tracker returned 1242 Hz where the peak is near 2400, which
// is a lock on the wrong feature and not a filter that moved.
BAND_PASS_CENTRE_RATIO :: f32(0.859)


// Parameter 38. The measured table has three states and the readme's voice
// display lists poly, mono and legato behaviour, so the three map in order.
Play_Mode :: enum u8 {
	Poly,
	Mono,
	Legato,
}

// Parameters 41 and 46, seven measured states displayed "1".."7", each
// identified by driving it at full depth and watching what moved.
//
// The documentation was no help and was partly wrong. The English readme lists
// five destinations, the Japanese manual for the same build lists six and
// includes one the English omits, and neither mentions the seventh. Worse, the
// order they list is not the order of the states -- the same trap parameters 0,
// 1, 42 and 47 all carry.
//
// `s1probe lfoprobe` renders each state in four configurations and compares each
// render against the same patch with the LFO switched off, so "this destination
// does nothing" is distinguishable from "these metrics cannot see it":
//
//   1  only oscillator 2's render changes                  oscillator 2 pitch
//   2  both oscillators' pitch moves, ~10100 cents         both pitches
//   3  changes only while the filter has room to move;
//      bit-identical with the cutoff wide open             filter cutoff
//   4  27 dB of level swing, no pitch, no timbre           volume
//   5  bit-identical to the LFO being off, in every
//      configuration and at every pulse width tried        nothing at all
//   6  only oscillator 1 changes, and it changes for a
//      sine carrier too, so it is not pulse width          FM amount
//   7  the stereo image swings the full width              pan
//
// State 5 is where the Japanese manual puts pulse width. It is inert in v1.13
// beta 3: not merely subtle, but producing a bit-identical render. Whatever the
// intent, this build does not implement it, and neither does this enum.
Lfo_Destination :: enum u8 {
	Osc2_Pitch,
	Both_Pitch,
	Filter_Cutoff,
	Amplitude,
	// State 5. Kept as a named member so the display-to-state mapping stays a
	// straight index and a patch selecting it is silently correct.
	Inert,
	Fm,
	Pan,
}

// Parameter 71, three measured states. The readme is explicit: "Select pitch of
// oscillator2, FM or pulse width as the destinaion of modulation env."
Osc_Mod_Destination :: enum u8 {
	Osc2_Pitch,
	Fm,
	Pulse_Width,
}

// One of the two MIDI controller assignments, parameters 86..89 with 50 and 51.
//
// Measured, and none of it was in the extracted parameter table. Those four are
// the only parameters this project treats as continuous -- they read back as a
// raw fraction of 65536 rather than as a state list -- so nothing about them was
// known beyond the numbers stored in a patch.
//
//   86, 88  the source, as a 16-bit MIDI status and data byte. 45057 is 0xB001:
//           a control change on channel 1, controller 1, which is the modulation
//           wheel. That is what every factory patch carries, because no factory
//           patch stores these at all and 0xB001 is the default.
//   87, 89  the destination, and it is simply **the parameter index**. Stored 44
//           and 43 are what the plugin's own panel shows as "lfo1 depth" and
//           "lfo1 speed", and parameters 44 and 43 are lfo1 depth and lfo1 speed.
//           The dropdown offering a shorter, reordered list of destinations is a
//           display, not the encoding.
//   50, 51  the sensitivity, a signed percentage from -100 to +100 centred at
//           stored 63 and 64, which both read "0%".
//
// How the destination was settled is worth recording, because the obvious method
// does not work: assigning a destination, sending the controller and reading every
// parameter back finds *nothing moved*. The plugin applies the modulation
// internally without disturbing the parameter it reports, so `s1probe assigns`
// returns nothing for all 52 destinations. The two anchors above are what settle
// it instead.
Midi_Control :: struct {
	// Controller number, or -1 when the source is not a control change.
	cc:     int,
	// Parameter index this controller moves, or -1 for none.
	target: int,
	// -1..1. Negative inverts, and the centre is no effect.
	amount: f32,
}

Lfo_Params :: struct {
	enabled:     bool,
	shape:       dsp.Lfo_Waveform,
	destination: Lfo_Destination,
	// Free-running rate. Ignored when `tempo_sync` is set.
	rate_hz:     f32,
	// Cycle length in beats when `tempo_sync` is set.
	sync_beats:  f32,
	// The knob's linear position, which is what the cutoff, volume, pan and FM
	// destinations still scale by.
	depth:       f32,
	// The same knob through each destination's own measured depth curve.
	//
	// There are three of these because there is no shared curve, and that is now a
	// measurement rather than an assumption. Driven with a square, the four
	// destinations disagree completely: the pitch is exponential in the knob, the
	// cutoff is linear in octaves, the volume is linear in amplitude, and the pan
	// is steeply concave. `depth` itself stays as the raw linear reading, which is
	// what the cutoff, volume and FM destinations use directly.
	pitch_depth: f32,
	pan_depth:   f32,
	key_sync:    bool,
	tempo_sync:  bool,
}

Engine_Params :: struct {
	// -- oscillators ---------------------------------------------------------
	osc1_shape:         dsp.Waveform,
	osc2_shape:         dsp.Waveform,
	// Parameter 2, in semitones, read straight off the state display.
	osc2_semitones:     f32,
	// Parameter 3, in cents.
	osc2_cents:         f32,
	// Parameter 4. When false oscillator 2 ignores the note number entirely and
	// runs at a fixed pitch, which is what the readme means by "sound is output
	// at a uniform frequency".
	osc2_key_track:     bool,
	// Parameter 5, as the oscillator 2 share: 0 is oscillator 1 alone, 1 is
	// oscillator 2 alone.
	osc_mix:            f32,
	osc_sync:           bool,
	osc_ring:           bool,
	// Parameter 8, as a duty cycle on 0..1.
	pulse_width:        f32,
	// Parameter 9, in semitones.
	key_shift:          f32,
	// Parameter 72, in cents, applied to both oscillators.
	fine_tune_cents:    f32,
	// Parameter 45, as a modulation index on 0..1.
	osc1_fm:            f32,
	// Parameter 76, in cents, spread across the oscillator 1 unison stack.
	osc1_detune:        f32,
	// Parameter 91, as the turns oscillator 2 starts ahead of oscillator 1. Only
	// meaningful when `osc_phase_fixed` is set; at stored zero the reference does not
	// fix the phase at all and the oscillators free-run.
	osc_phase_shift:    f32,
	osc_phase_fixed:    bool,
	sub_shape:          dsp.Waveform,
	// Parameter 97, in semitones below oscillator 1: -12 or -24.
	sub_octave:         f32,
	sub_gain:           f32,

	// -- oscillator modulation envelope --------------------------------------
	mod_env_on:         bool,
	mod_env_dest:       Osc_Mod_Destination,
	// Parameter 11, signed on -1..1; the readme's centre setting is no
	// modulation and left of centre lowers the destination.
	mod_env_amount:     f32,
	mod_env_attack:     f32,
	mod_env_decay:      f32,

	// -- filter --------------------------------------------------------------
	filter_mode:        dsp.Filter_Mode,
	filter_slope:       dsp.Filter_Slope,
	filter_cutoff_hz:   f32,
	// Parameter 20 on 0..1, kept because it is the knob's own position and
	// several things want to know it, and the same knob resolved to the filter's
	// damping k = 1/Q, which is what the audio path consumes. Resolved once at
	// patch load rather than per sample: it is a table lookup and the table does
	// not move while a note is sounding.
	filter_resonance:   f32,
	filter_damping:     f32,
	// The output gain that goes with that damping. Resonance adds energy, and the
	// reference does not simply pass it through; measured, and the same curve for
	// every response and both slopes.
	filter_output_gain: f32,
	// Parameter 21, signed on -1..1.
	// Parameter 21, as the octaves the corner moves when the envelope is at full
	// level. Signed; negative closes the filter as the envelope rises.
	//
	// Octaves rather than a -1..1 fraction because that is what was measured:
	// `s1probe filtertable` fits 0.1595 octaves per step, so the knob reaches
	// about +10.2 and -10.1 octaves at its ends. The fraction this replaced was
	// scaled by an invented six octaves in `voice_process`, which is why patches
	// pairing a low cutoff with a negative amount would not close.
	filter_env_octaves: f32,
	// Parameter 22, 0..1, where 1 is one octave of cutoff per octave of note.
	filter_key_track:   f32,
	filter_saturation:  f32,
	filter_velocity:    bool,
	filter_attack:      f32,
	filter_decay:       f32,
	filter_sustain:     f32,
	filter_release:     f32,

	// -- amplifier -----------------------------------------------------------
	amp_attack:         f32,
	amp_decay:          f32,
	amp_sustain:        f32,
	amp_release:        f32,
	amp_gain:           f32,
	amp_velocity_sens:  f32,

	// -- LFOs ----------------------------------------------------------------
	lfo:                [2]Lfo_Params,

	// -- equaliser -----------------------------------------------------------
	//
	// One parametric band and a tone tilt. Frequency and gain are read straight
	// off the reference's displays, in hertz and decibels; the Q curve and the
	// tone's corners are chosen.
	//
	// Zero gain is flat, which is what stored 64 displays, so there is no separate
	// bypass for this section.
	eq_freq_hz:         f32,
	eq_gain_db:         f32,
	eq_q:               f32,
	// Parameter 60, signed on -1..1.
	eq_tone:            f32,

	// -- effect unit ---------------------------------------------------------
	//
	// Parameters 77..81: one slot, ten types, two general-purpose controls and a
	// level. All five displays are bare integers, so every curve behind these is
	// measured or chosen in src/dsp/effect.odin rather than read off a unit.
	effect_on:          bool,
	effect_type:        dsp.Effect_Type,
	// Both controls as 0..1 positions, and ctl1 again as a raw step count for the
	// decimator, whose measured law is in steps rather than fractions.
	effect_ctl1:        f32,
	effect_ctl2:        f32,
	effect_ctl1_steps:  f32,
	// Parameter 81, 0..1: a linear dry/wet crossfade.
	effect_level:       f32,

	// -- delay ---------------------------------------------------------------
	//
	// Times are kept in beats and milliseconds rather than samples, because that
	// is what the reference's own displays give and because a tempo-synced delay
	// has to be recomputed when the tempo moves, not when a note starts.
	delay_on:           bool,
	// Parameter 35. Cycle length in beats, or zero when the state selects the
	// fixed short setting rather than a musical division.
	delay_beats:        f32,
	// Parameter 35 state 0, in milliseconds.
	delay_fixed_ms:     f32,
	// Parameter 83, the left and right offsets in milliseconds.
	delay_left_ms:      f32,
	delay_right_ms:     f32,
	delay_feedback:     f32,
	delay_dry_wet:      f32,
	// Parameter 98, signed on -1..1.
	delay_tone:         f32,
	// Parameter 82: normal stereo, cross feedback, or ping-pong.
	delay_mode:         dsp.Delay_Mode,

	// -- chorus --------------------------------------------------------------
	chorus_on:          bool,
	chorus_stages:      int,
	// Parameter 52, in milliseconds.
	chorus_delay_ms:    f32,
	chorus_depth:       f32,
	chorus_rate_hz:     f32,
	// Parameter 55, signed on -1..1.
	chorus_feedback:    f32,
	chorus_level:       f32,

	// -- voice engine --------------------------------------------------------
	// Parameter 94.
	polyphony:          int,
	// Parameter 93, already reduced to 1 when parameter 73 turns unison off.
	unison_voices:      int,
	// Parameter 75, in cents across the whole stack.
	unison_detune:      f32,
	// Parameter 84, signed on -1..1.
	unison_pan_spread:  f32,
	// Parameter 92, in turns.
	unison_phase_shift: f32,
	// Parameter 85, in semitones: the pitch offset of the unison stack.
	unison_pitch:       f32,
	// Parameter 39, in seconds.
	portamento_time:    f32,
	// Parameter 74.
	portamento_auto:    bool,
	play_mode:          Play_Mode,

	// -- arpeggiator ---------------------------------------------------
	//
	// Measured with `s1probe arpprobe`; see src/engine/arpeggiator.odin for
	// what each of these came out as and how.
	arp_on:             bool,
	arp_pattern:        Arp_Pattern,
	// 1..4. Whole copies of the chord stacked above it.
	arp_octaves:        int,
	// One step, in beats. The engine turns it into frames with the tempo.
	arp_step_beats:     f32,
	// How much of a step the note sounds for, on 0..1.
	arp_gate:           f32,
	// Parameter 40, in semitones.
	pitch_bend_range:   f32,
	// The two MIDI controller assignments. See `Midi_Control`.
	midi_ctrl:          [2]Midi_Control,
	// Parameter 90, signed on -1..1.
	pan:                f32,
}

// Where oscillator 2 starts relative to oscillator 1 when parameter 91 is not
// fixing the phase, in turns.
//
// Measured. See the note at the use site in voice.odin: 158 degrees, fitted from
// two harmonics and confirmed to be the same at three notes an octave apart.
//
// Kept at the measured figure rather than tuned against the null test. 0.480 was
// tried across the whole bank and is indistinguishable -- envelope error 11.19
// against 11.25 dB, spectral median 11.74 against 11.69 -- so there is no evidence
// to prefer anything over the reading.
OSC_PHASE_FREE_TURNS :: f32(0.440)
