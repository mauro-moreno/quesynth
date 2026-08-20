package engine

import "core:math"
import "../dsp"
import "../patch"

// Binding a parsed `patch.Patch` to `Engine_Params`.
//
// This is the only file in the project that decides what a Synth1 parameter
// *means*. Two rules govern all of it:
//
//   1. Where the measured state display carries a real unit, that unit is the
//      source of truth and is parsed out of the display string rather than
//      reconstructed. "-60", "+15 cent", "100 : 0" and "24" are all read as
//      numbers, so the semitone, cent and percentage ranges in this file are
//      measurements, not guesses.
//   2. Where the display is an opaque 0..127 -- filter frequency, the envelope
//      times, the gains, the LFO rate -- no unit exists to read, so a curve is
//      chosen. Every such choice is named and justified at its use site. These
//      are the parameters the sound-alike slice will have to revisit against
//      the reference render; nothing else in this file should need to move.
//
// A stored integer is resolved to a state exactly the way src/patch/value.odin
// resolves it, because that resolution is measured plugin behaviour. The one
// deliberate departure is at the end: where the plugin walks off the grid for
// an out-of-range integer, the engine clamps. An engine parameter has to be
// bounded to be usable, and parameter 21's own reference default (stored 128
// against a 128-state table) is out of range, so this path is not hypothetical.

// The position of the resolved state inside its own table, clamped to the
// table. Use this for parameters whose meaning is "how far along the range",
// never for ones whose display is a semantic identifier.
resolved_position :: proc(index, stored: int) -> int {
	position, ok := patch.parameter_position(index, stored)
	return position if ok else 0
}

// The display string of the resolved state.
resolved_display :: proc(index, stored: int) -> string {
	states := patch.parameter_states(index)
	if len(states) == 0 {return ""}
	return states[resolved_position(index, stored)].display
}

// The resolved state's display read as an integer identifier.
//
// Used where a display really is a semantic identifier rather than a position --
// the LFO destinations of parameters 41 and 46, whose displays run "1".."7" in
// order, read through this so the one-based listing maps onto a zero-based enum.
//
// It is *not* the right reading for parameters 42 and 47, which was this comment's
// previous claim. Their six states display out of order, as 0, 1, 5, 2, 3, 4, and
// that looked like a display carrying an identity the position had lost.
// `s1probe lfoshape` measured the shapes directly and they are in plain position
// order; reading the identifier bound four of the six to the wrong waveform.
resolved_display_id :: proc(index, stored: int) -> int {
	if v, ok := patch.display_integer(resolved_display(index, stored)); ok {
		return v
	}
	return resolved_position(index, stored)
}

// Position mapped onto 0..1 across the table.
unit_position :: proc(index, stored: int) -> f32 {
	states := patch.parameter_states(index)
	if len(states) <= 1 {return 0}
	return f32(resolved_position(index, stored)) / f32(len(states) - 1)
}

// The leading signed number of a display string.
//
// Deliberately permissive where src/patch/value.odin is deliberately strict.
// That file must reject "+01" and "007" because admitting them would make its
// display-keying rule fire on the wrong parameters. Here the opposite is true:
// "+15 cent", "-60", "L 100%" and "100 : 0" all need to give up their number,
// and the strict form would return nothing for three of the four.
display_leading_number :: proc(s: string) -> (value: f32, ok: bool) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}

	negative := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		negative = s[i] == '-'
		i += 1
	}

	start := i
	whole: f32 = 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		whole = whole * 10 + f32(s[i] - '0')
		i += 1
	}
	if i == start {return 0, false}

	if i < len(s) && s[i] == '.' {
		i += 1
		scale: f32 = 0.1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			whole += f32(s[i] - '0') * scale
			scale *= 0.1
			i += 1
		}
	}

	if negative {
		return -whole, true
	}
	return whole, true
}

// The resolved display read as a number, falling back to `fallback` when the
// display carries no leading number at all. Parameter 90 state "center" is the
// only in-scope display that hits the fallback.
display_number :: proc(index, stored: int, fallback: f32) -> f32 {
	if v, ok := display_leading_number(resolved_display(index, stored)); ok {
		return v
	}
	return fallback
}

// An exponential map of 0..1 onto [lo, hi]. Used for every opaque 0..127
// parameter whose perceptual scale is multiplicative: frequencies and times.
// A linear map of a 0..127 knob onto 0..8 seconds would put every usable attack
// value in the bottom two steps.
exp_map :: proc(u, lo, hi: f32) -> f32 {
	t := dsp.clamp32(u, 0, 1)
	if lo <= 0 || hi <= 0 {return dsp.lerp32(lo, hi, t)}
	// lo * (hi/lo)^t, written through pow so no log is needed.
	return lo * pow_f32(hi / lo, t)
}

pow_f32 :: proc(base, exponent: f32) -> f32 {
	return math.pow(base, exponent)
}

// Envelope times, read out of the reference.
//
// These were a chosen curve -- 1 ms to 12 s, exponential -- because the displays
// for parameters 12, 13, 15, 16, 18, 25, 26 and 28 are a bare 0..127 and say
// nothing about time. The null test measured what that guess cost: our release
// ran about a factor of five short of the reference's, on 105 of 123 factory
// patches the reference was still sounding when ours had finished, and on 15 of
// them ours had decayed to silence before the note was even released.
//
// The tables in envelope_table.odin replace the guess with the measurement.
// `s1probe envtable` regenerates them; docs/null-test.md documents the method.
// The real curve reaches 40 s at the top of the range rather than 12 s, and is
// not a single exponential: below stored 24 it flattens away from the clean
// exponential the rest of the range follows, which is why this is a table and
// not a formula.
//
// Indexed by resolved state rather than by the raw stored integer, so an
// out-of-range value in a patch file lands where the reference puts it instead
// of past the end of the table.
envelope_table_index :: proc(index, stored: int) -> int {
	return clamp_int(resolved_position(index, stored), 0, ENVELOPE_TABLE_SIZE - 1)
}

envelope_attack_time :: proc(index, stored: int) -> f32 {
	return ENVELOPE_ATTACK_SECONDS[envelope_table_index(index, stored)]
}

envelope_decay_time :: proc(index, stored: int) -> f32 {
	return ENVELOPE_DECAY_SECONDS[envelope_table_index(index, stored)]
}

envelope_release_time :: proc(index, stored: int) -> f32 {
	return ENVELOPE_RELEASE_SECONDS[envelope_table_index(index, stored)]
}

// Filter cutoff. Parameter 19's display is a bare 0..127, so the 20 Hz..20 kHz
// span is the chosen curve: it is the audible band, and it puts the reference
// default of 81 at roughly 2.5 kHz, which is a plausible open-but-not-bypassed
// setting for a factory patch.
FILTER_MIN_HZ :: f32(20.0)
FILTER_MAX_HZ :: f32(20000.0)

// Parse one of parameter 35's twenty delay-time displays into beats.
//
// The notation is the reference's own, and it is a table rather than a formula:
// "(8)" is an eighth note, "(16)+(32)" a dotted sixteenth, "(4) /3" a quarter
// triplet, and state 0 is not musical at all but a fixed "0.1 msec". The states
// are not in ascending order of time either -- state 9 is a half triplet at 1.33
// beats and state 10 a dotted eighth at 0.75 -- so reading the display is the only
// way to get this right.
//
// A quarter note is one beat, so "(N)" is 4/N beats and a triplet is two thirds
// of that.
delay_display_beats :: proc(display: string) -> (beats: f32, musical: bool) {
	if len(display) == 0 || display[0] != '(' {
		return 0, false
	}

	triplet := false
	for i in 0 ..< len(display) - 1 {
		if display[i] == '/' && display[i + 1] == '3' {
			triplet = true
			break
		}
	}

	// Sum every parenthesised division in the string.
	total: f32 = 0
	i := 0
	for i < len(display) {
		if display[i] != '(' {
			i += 1
			continue
		}
		i += 1
		value := 0
		digits := 0
		for i < len(display) && display[i] >= '0' && display[i] <= '9' {
			value = value * 10 + int(display[i] - '0')
			digits += 1
			i += 1
		}
		if digits > 0 && value > 0 {
			total += 4.0 / f32(value)
		}
	}

	if total <= 0 {
		return 0, false
	}
	if triplet {
		total *= 2.0 / 3.0
	}
	return total, true
}

// A bipolar knob's position on -1..1, with exactly zero at its centre.
//
// The centre of a 128-state knob is state **64**, not the midpoint of the range,
// and the reference says so in three different places: parameter 90 displays
// "center" at state 64 with "L 2%" at 63 and "R 2%" at 65, parameter 11 displays
// "00" there between "-01" and "+01", and parameter 62 displays exactly "0.0 db".
// So the two halves are not the same size -- 64 steps below the centre and 63
// above -- and they have to be scaled separately.
//
// The obvious `2 * unit - 1` gets this wrong. At state 64 it returns
// 2 * (64/127) - 1 = 0.0079 rather than 0, which tilted the equaliser and the
// delay's tone on every patch in the bank and put a small permanent offset on the
// pan of every voice. Small, but wrong in the same direction every time, which is
// the kind of error that hides inside an aggregate.
centred_position :: proc(index, stored: int) -> f32 {
	states := patch.parameter_states(index)
	if len(states) <= 1 {
		return 0
	}
	centre := len(states) / 2
	state := resolved_position(index, stored)
	if state == centre {
		return 0
	}
	if state < centre {
		return f32(state - centre) / f32(centre)
	}
	return f32(state - centre) / f32(len(states) - 1 - centre)
}

// Read a frequency display in hertz, honouring the kilohertz suffix.
//
// Parameter 61 switches units partway up its range: "50.0 Hz", "213.9 Hz",
// "915.0 Hz", then "3.9 KHz", "16.0 KHz". Reading the leading number alone turns
// 3.9 kHz into 3.9 Hz, which is silently three orders of magnitude wrong and puts
// the whole top half of the knob below the audible band.
display_frequency_hz :: proc(display: string) -> f32 {
	value, ok := display_leading_number(display)
	if !ok {
		return 0
	}
	for i in 0 ..< len(display) {
		if display[i] == 'k' || display[i] == 'K' {
			return value * 1000.0
		}
	}
	return value
}

// Parse parameter 83's "L : R msec" display into its two millisecond values.
delay_spread_ms :: proc(display: string) -> (left, right: f32) {
	colon := -1
	for i in 0 ..< len(display) {
		if display[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 0 {
		return 0, 0
	}
	l, l_ok := display_leading_number(display[:colon])
	r, r_ok := display_leading_number(display[colon + 1:])
	if !l_ok {
		l = 0
	}
	if !r_ok {
		r = 0
	}
	return l, r
}

// Bind a parsed patch.
//
// `p.values` is always fully populated: `patch.parse_sy1` pre-fills every index
// with `PARAMETERS[i].default` before reading the file, so a `ver=105` patch
// that omits later parameters needs no special handling here.
//
// Nothing is out of scope any more. The arpeggiator (31..34, 59) was the last
// section that was parsed, shown in the interface and bound to nothing; it is
// implemented in arpeggiator.odin from measurements taken with `s1probe
// arpprobe`, and hosts/vst3 and hosts/clap now read the host tempo it needs.
//
// The delay (35..37, 65, 82, 83, 98) and the chorus (52..56, 64, 66) used to be
// on that list; the null test made the case for them, at 19.8 dB of envelope
// error on patches that use them against 7.9 dB on patches that do not. The
// equaliser (60..63) and the extra effect unit (77..81) have since been
// implemented too, and this comment claimed otherwise for longer than it was
// true.
bind_patch :: proc(p: patch.Patch) -> Engine_Params {
	e: Engine_Params

	// -- oscillators ---------------------------------------------------------

	// Oscillator waveforms, measured rather than read off the manual's prose.
	//
	// Both manuals list oscillator 1's waveforms as "sine, triangle, saw, pulse"
	// and oscillator 2's as "triangle, saw, pulse, noise", and this file used to
	// take that listing order as the state order. It is not. `s1probe waveprobe`
	// renders each state alone through an open filter and reads its harmonic
	// series, and the series are unambiguous:
	//
	//   state 0  no harmonics at all                          sine
	//   state 1  h2..h7 at -6.0 -9.5 -12.1 -14.0 -15.6 -16.9  saw, 1/n exactly
	//   state 2  even harmonics present, and the only state
	//            whose spectrum moves when the pulse width
	//            knob moves -- by 40 dB                       pulse
	//   state 3  odd harmonics only, h3/h5/h7 at
	//            -19.1 -28.0 -33.8                            triangle, 1/n^2
	//
	// So the real order is sine, saw, pulse, triangle: three of the four states
	// were bound to the wrong waveform on both oscillators. This is the same trap
	// parameters 42 and 47 already carry a warning about -- the manual lists the
	// waveforms in a tidy order the plugin does not use.
	//
	// The pulse width knob is what makes state 2 certain rather than merely
	// likely: it is inert on every other state, which is also how the error was
	// found, by a probe that changed the width and got a bit-identical render.
	switch resolved_display_id(0, p.values[0]) {
	case 0:
		e.osc1_shape = .Sine
	case 1:
		e.osc1_shape = .Saw
	case 2:
		e.osc1_shape = .Pulse
	case:
		e.osc1_shape = .Triangle
	}

	// Parameter 1, four states displayed "1".."4", measured the same way and
	// carrying the same three waveforms in the same order, plus noise. Oscillator
	// 2 has no sine and oscillator 1 has no noise, so the two sets differ by one
	// entry at each end rather than being the same switch.
	switch resolved_display_id(1, p.values[1]) {
	case 1:
		e.osc2_shape = .Saw
	case 2:
		e.osc2_shape = .Pulse
	case 3:
		e.osc2_shape = .Triangle
	case:
		e.osc2_shape = .Noise
	}

	// Displays "-60".."+60": semitones, read directly.
	e.osc2_semitones = display_number(2, p.values[2], 0)
	// Displays "-62 cent".."+61 cent".
	e.osc2_cents = display_number(3, p.values[3], 0)
	e.osc2_key_track = resolved_position(4, p.values[4]) != 0

	// Parameter 5 displays "100 : 0".."0 : 100" as oscillator 1's share, so the
	// oscillator 2 share this struct stores is the complement of the number the
	// display leads with.
	osc1_percent := display_number(5, p.values[5], 50)
	e.osc_mix = dsp.clamp32(1.0 - osc1_percent / 100.0, 0, 1)

	e.osc_sync = resolved_position(6, p.values[6]) != 0
	e.osc_ring = resolved_position(7, p.values[7]) != 0

	// Parameter 8 displays a bare 0..127 duty index. Mapped onto 0.02..0.98 so
	// the reference default of 64 lands within a step of a square wave and
	// neither extreme collapses the pulse to DC.
	// Parameter 8 is a duty cycle from 0 to one half, not from 0 to 1.
	//
	// Measured, and it is not a close call. `s1probe waveprobe` reads the
	// harmonic series of the pulse at stored 64 as
	//
	//   h2 -3.1  h3 -9.8  h4 -41.3  h5 -13.8  h6 -12.6  h7 -17.4  dB
	//
	// and a pulse of duty d has harmonic n at sin(n*pi*d)/n. Only d = 0.252 fits:
	// it reproduces every one of those six to within 0.1 dB, including the near
	// null at the fourth harmonic, which is what pins it down -- a 50% duty would
	// put nulls at the even harmonics instead. So stored 64 is a quarter duty and
	// the knob reaches a square at its top, which is also what the manual says it
	// does ("turning right makes it wider, approaching a square wave").
	//
	// The binding this replaces spread 0.02..0.98 across the range, so it was at
	// a square where the reference is at a quarter, and past a square above that.
	e.pulse_width = unit_position(8, p.values[8]) * 0.5

	// Displays "-24".."24": semitones.
	e.key_shift = display_number(9, p.values[9], 0)
	// Displays "-62 cent".."+61 cent".
	e.fine_tune_cents = display_number(72, p.values[72], 0)

	// Parameter 45 is a bare 0..127. Taken as a modulation index on 0..1; the
	// depth in hertz is applied in voice.odin where the carrier pitch is known.
	e.osc1_fm = unit_position(45, p.values[45])

	// Parameter 76 is a bare 0..127. Read as cents of detune across the
	// oscillator 1 stack; 50 cents at full is a quarter tone, which is as wide
	// as a detune stack stays musical.
	e.osc1_detune = 50.0 * unit_position(76, p.values[76])

	// Parameters 91 and 92 are bare 0..127 phase steps. Divide by the 128-state
	// count, not the top index, so the top step lands at 127/128 of a turn rather
	// than wrapping onto the same phase as zero.
	// Parameter 91, the phase relationship between the two oscillators at note on.
	//
	// Measured. `s1probe phaseprobe` drives two pulses at the same pitch through the
	// reference and sweeps this knob: the third harmonic cancels at stored 48, the
	// second at 64, and the first and third together at 127. Those are offsets of a
	// sixth, a quarter and a half of a cycle, and they sit on one line through the
	// origin -- so the offset is half a turn across the knob, not the full turn this
	// previously assumed.
	//
	// Stored zero is not part of that line and is not a phase at all. The changelog
	// for v1.07 alpha, which added the knob, says that turned fully left "the phase
	// is not fixed (as before)", and the probe agrees: at zero the reference returns
	// a spectrum with the fundamental suppressed, which a reset to a common phase
	// cannot produce and free-running oscillators can.
	//
	// This matters for the whole factory bank, not a corner of it: every `ver=105`
	// patch omits parameter 91 entirely and so takes this default.
	OSC_PHASE_MAX_TURNS :: f32(0.5)
	{
		position := resolved_position(91, p.values[91])
		e.osc_phase_fixed = position != 0
		e.osc_phase_shift = OSC_PHASE_MAX_TURNS * f32(position) / 127.0
	}
	// Parameter 92 spreads the unison stack. The same changelog entry notes it "is
	// not effective unless the phase is fixed in the oscillator section", which is
	// enforced at the use site in voice.odin rather than here.
	e.unison_phase_shift = f32(resolved_position(92, p.values[92])) / 128.0

	// Parameter 96 has four states; the sub oscillator reuses oscillator 1's
	// documented shape order.
	switch resolved_display_id(96, p.values[96]) {
	case 0:
		e.sub_shape = .Sine
	case 1:
		e.sub_shape = .Triangle
	case 2:
		e.sub_shape = .Saw
	case:
		e.sub_shape = .Pulse
	}
	// Parameter 97 has two states: one octave down or two.
	e.sub_octave = resolved_position(97, p.values[97]) == 0 ? -12.0 : -24.0
	e.sub_gain = unit_position(95, p.values[95])

	// -- oscillator modulation envelope --------------------------------------

	e.mod_env_on = resolved_position(10, p.values[10]) != 0
	switch resolved_position(71, p.values[71]) {
	case 0:
		e.mod_env_dest = .Osc2_Pitch
	case 1:
		e.mod_env_dest = .Fm
	case:
		e.mod_env_dest = .Pulse_Width
	}
	// Displays "-64".."+63". Normalised by 64 so the centre state is exactly
	// zero modulation, which is what the readme promises.
	e.mod_env_amount = dsp.clamp32(display_number(11, p.values[11], 0) / 64.0, -1, 1)
	e.mod_env_attack = envelope_attack_time(12, p.values[12])
	e.mod_env_decay = envelope_decay_time(13, p.values[13])

	// -- filter --------------------------------------------------------------

	// Parameter 14 has five states. The readme documents four -- "low-pass
	// (12 dB), low-pass (24 dB), high-pass (12 dB) or high-pass (24 dB)" -- and
	// the v1.13 beta 2 entry in the version history adds the fifth: "A new
	// filter 'LPDL' has been added", a fourth-order diode ladder described as
	// "close to 'LP24'". This slice has no diode ladder model, so LPDL is bound
	// to the 24 dB low pass, which is the response the changelog itself calls
	// it close to.
	//
	// Band pass and notch are implemented in src/dsp and reachable through
	// `Engine_Params.filter_mode`, as the contract for this slice requires, but
	// no Synth1 filter-type state selects them: the reference plugin has no
	// band pass or notch. Inventing a mapping to reach them would corrupt every
	// patch that uses a real state.
	switch resolved_display_id(14, p.values[14]) {
	case 0:
		e.filter_mode, e.filter_slope = .Low_Pass, .Slope_12
	case 1:
		e.filter_mode, e.filter_slope = .Low_Pass, .Slope_24
	case 2:
		e.filter_mode, e.filter_slope = .High_Pass, .Slope_12
	case 3:
		// A band pass, not the 24 dB high pass the English manual describes.
		//
		// The two manuals disagree about this state: the English one calls it a
		// high pass, the Japanese one for the same version calls it a 12 dB band
		// pass. `s1probe filterprobe` settles it by driving noise through each
		// state and fitting the response. State 3's pass band is bounded at both
		// ends -- 339 to 761 Hz at one cutoff setting, 1356 to 3417 Hz at another,
		// tracking the knob -- and it falls at about 6 dB per octave on each side.
		// A high pass does not fall above its corner; state 2, which is one,
		// passes everything from 479 Hz to the top of the analysed range.
		//
		// Two poles, so ±6 dB per octave: the manual's "band pass (12 dB)" and
		// this measurement are the same filter described two ways.
		e.filter_mode, e.filter_slope = .Band_Pass, .Slope_12
	case:
		// LPDL, the diode ladder added in v1.13 beta 2. Measured at 12 to 14 dB
		// per octave with a corner well below the other types' for the same knob
		// setting, so it is neither of the slopes this filter has; the changelog
		// calls it close to LP24 and that is what it is bound to, pending a
		// ladder model. Its measured slope is closer to the 12 dB section.
		e.filter_mode, e.filter_slope = .Low_Pass, .Slope_24
	}

	e.filter_attack = envelope_attack_time(15, p.values[15])
	e.filter_decay = envelope_decay_time(16, p.values[16])
	// Parameter 17 is a linear reading of the knob, and for once that is not a
	// guess -- it is a guess that measurement confirmed.
	//
	// `s1probe cutoffprobe --sweep sustain` holds the envelope amount at a
	// strongly negative setting, sweeps the sustain, and reads off what share of
	// the available travel the corner actually takes. Measured against linear:
	//
	//   stored     16      32      48      64      80      96     112
	//   measured  0.1275  0.2549  0.3807  0.5064  0.6313  0.7575  0.8861
	//   linear    0.1260  0.2520  0.3780  0.5039  0.6299  0.7559  0.8819
	//
	// Within 0.005 the whole way. Unlike the amplitude sustain, which shares the
	// gain knob's curve, this one really is linear.
	e.filter_sustain = unit_position(17, p.values[17])
	e.filter_release = envelope_release_time(18, p.values[18])

	// Parameter 19, measured rather than chosen.
	//
	// The curve this replaces spanned 20 Hz to 20 kHz exponentially, "the audible
	// band" -- a reasonable guess that came out about a quarter of an octave
	// sharp across the whole range. `s1probe filtertable` renders noise through
	// the 12 dB low pass at every setting and reads the corner off the spectrum:
	// the real curve runs 24 Hz to about 17 kHz and, above stored 16, moves in
	// steps of very close to one semitone.
	//
	// The 24 dB path does not share that curve, and reading it the same way --
	// the -3 dB point against an open reference, at resonance 0 -- does not
	// reach it either. A first attempt built exactly that and made the bank
	// worse: 29 of 123 patches regressed, every one of them at high resonance,
	// because raising Q raises a peak near the corner and the -3 dB point,
	// defined relative to *that* render's own peak, follows it upward by over
	// an octave. `FILTER_CUTOFF_HZ_24` reads the peak's own frequency instead,
	// with resonance held at 107 for the whole sweep -- high enough for the
	// peak to exist and be sharp, clear of the handful of settings at the very
	// bottom of the range where even that resonance puts the peak below the
	// analysed floor (`extrapolate_head` covers those). See docs/null-test.md
	// for the full trail, including why the -3 dB corner is not resonance-
	// invariant on a filter with a peak and the peak's own frequency, read at
	// high Q, is a better estimate of the parameter this curve is actually
	// meant to capture.
	e.filter_cutoff_hz =
		(e.filter_slope == .Slope_24 ? FILTER_CUTOFF_HZ_24 : FILTER_CUTOFF_HZ)[
			clamp_int(resolved_position(19, p.values[19]), 0, FILTER_TABLE_SIZE - 1)]
	// That table is the low pass's corner, and the band pass does not centre on
	// it. See the constant.
	if e.filter_mode == .Band_Pass {
		e.filter_cutoff_hz *= BAND_PASS_CENTRE_RATIO
	}
	// Parameter 20, measured rather than chosen.
	//
	// The law this replaces was a straight line to a maximum Q of 14, and the
	// reference reaches Q = 950 -- almost all of it in the last fifteen steps of
	// the knob. The old number came from reading the resonance off a 1/6-octave
	// band profile, which cannot resolve a Q above 8.65 because that is the band's
	// own Q; see `filter_resonance_table.odin` and `s1probe qprobe`.
	//
	// Two curves, chosen by the slope the type above selected. Our 24 dB path is
	// two sections in series and the reference's is one four-pole design, and the
	// two shapes do not coincide under any single damping -- so the 24 dB curve is
	// its own measurement rather than the 12 dB one adjusted.
	{
		state := clamp_int(resolved_position(20, p.values[20]), 0, FILTER_RESONANCE_TABLE_SIZE - 1)
		e.filter_resonance = unit_position(20, p.values[20])
		e.filter_damping = e.filter_slope == .Slope_24 ? FILTER_DAMPING_24[state] : FILTER_DAMPING[state]
		e.filter_output_gain = FILTER_OUTPUT_GAIN[state]
	}

	// Displays "-63".."64". Divided by 64 so the positive end reaches exactly
	// 1.0 and the centre is no envelope contribution.
	// Parameter 21, in octaves, measured. Not clamped to a range here: the
	// corner it produces is clamped in `voice_process`, which is where the
	// filter's actual limits live, and clamping the amount instead would apply
	// one cutoff setting's headroom to every other.
	//
	// A second measured law for the same reason the cutoff curve above needed
	// one: the 24 dB path's octaves-per-step is its own number, and now that
	// both curves are read the same way -- the resonant peak at resonance 107
	// rather than the -3 dB corner at 0 -- 0.155091 against the 12 dB path's
	// 0.159530 is a small difference, not the large one an earlier, resonance-0
	// reading gave.
	if e.filter_slope == .Slope_24 {
		e.filter_env_octaves =
			f32(resolved_position(21, p.values[21]) - FILTER_ENV_CENTRE_STATE_24) *
			FILTER_ENV_OCTAVES_PER_STEP_24
	} else {
		e.filter_env_octaves =
			f32(resolved_position(21, p.values[21]) - FILTER_ENV_CENTRE_STATE) *
			FILTER_ENV_OCTAVES_PER_STEP
	}
	// A bare 0..127. The readme: fully right "the frequency changes an octave
	// with a one octave change in the note number played (full)", fully left
	// "leave the frequency unchanged", so the linear 0..1 reading is the
	// documented one.
	e.filter_key_track = unit_position(22, p.values[22])
	e.filter_saturation = unit_position(23, p.values[23])
	e.filter_velocity = resolved_position(24, p.values[24]) != 0

	// -- amplifier -----------------------------------------------------------

	e.amp_attack = envelope_attack_time(25, p.values[25])
	e.amp_decay = envelope_decay_time(26, p.values[26])
	e.amp_sustain = AMP_SUSTAIN_LEVEL[clamp_int(resolved_position(27, p.values[27]), 0, AMP_TABLE_SIZE - 1)]
	e.amp_release = envelope_release_time(28, p.values[28])
	// Parameter 29, measured rather than chosen.
	//
	// This was `unit^2`, "squared so the knob is roughly perceptual". The null
	// test found our renders 8 dB louder than the reference's, and
	// `s1probe leveltable` says why: a sine at full gain reaches an amplitude of
	// 0.750 in the reference, where `unit^2` reaches 1.0. That is 2.5 dB of level
	// given away at the top of the range before the curve's shape is considered,
	// and the shape is wrong too -- at the middle of the range the square is high
	// by a further 3 dB.
	//
	// The table is absolute amplitude, not a normalised fraction, so it carries
	// the reference's own output level. That works because this engine's sine
	// peaks at exactly 1.0, which is what the measurement was made against.
	//
	// Parameters 27 and 29 turn out to share one curve: swept independently, the
	// sustain knob and the gain knob produce the same amplitudes to five decimal
	// places. They are still two tables, because they are two parameters and
	// nothing guarantees the next version keeps them equal.
	e.amp_gain = AMP_GAIN_AMPLITUDE[clamp_int(resolved_position(29, p.values[29]), 0, AMP_TABLE_SIZE - 1)]
	e.amp_velocity_sens = unit_position(30, p.values[30])

	// -- LFOs ----------------------------------------------------------------

	bind_lfo(&e.lfo[0], p, 57, 42, 41, 43, 44, 67, 68)
	bind_lfo(&e.lfo[1], p, 58, 47, 46, 48, 49, 69, 70)

	// -- voice engine --------------------------------------------------------

	// Parameter 94, displayed "1".."32".
	e.polyphony = clamp_int(int(display_number(94, p.values[94], 16)), 1, MAX_POLYPHONY)

	// -- arpeggiator ---------------------------------------------------
	//
	// 31, 32, 34 and 59 are display-keyed: the stored integer *is* the
	// number the panel shows, so each reads through display_number rather
	// than through its position. 33 is not, and its position indexes the
	// measured step table directly.
	e.arp_on = display_number(59, p.values[59], 0) != 0

	// Displayed 1..4 against an enum that starts at zero.
	arp_type := clamp_int(int(display_number(31, p.values[31], 1)), 1, 4)
	e.arp_pattern = Arp_Pattern(arp_type - 1)

	// Displayed 0..3 for one to four octaves.
	e.arp_octaves = clamp_int(int(display_number(32, p.values[32], 0)), 0, 3) + 1

	e.arp_step_beats = ARP_STEP_BEATS[clamp_int(resolved_position(33, p.values[33]), 0, len(ARP_STEP_BEATS) - 1)]

	// Linear, measured: stored 64 sounds for 0.51 of the step, 127 for all
	// of it. A stored 0 is a note of no length and therefore silence.
	e.arp_gate = dsp.clamp32(f32(display_number(34, p.values[34], 64)) / 127.0, 0, 1)

	// Parameter 73 is the unison on/off switch; 93 is displayed "2".."8" and is
	// only meaningful when 73 is on, so the count collapses to a single voice
	// rather than the engine having to consult two fields everywhere.
	if resolved_position(73, p.values[73]) != 0 {
		e.unison_voices = clamp_int(int(display_number(93, p.values[93], 2)), 1, MAX_UNISON)
	} else {
		e.unison_voices = 1
	}

	// Parameter 75 is a bare 0..127, read as cents across the whole stack.
	e.unison_detune = 50.0 * unit_position(75, p.values[75])
	// Displays "-64".."63".
	e.unison_pan_spread = dsp.clamp32(display_number(84, p.values[84], 0) / 64.0, -1, 1)
	// Displays "-24".."+24": semitones.
	e.unison_pitch = display_number(85, p.values[85], 0)

	// Parameter 39 is a bare 0..127. Zero must be exactly no portamento, so the
	// exponential curve starts above it rather than covering it.
	portamento_unit := unit_position(39, p.values[39])
	if portamento_unit <= 0 {
		e.portamento_time = 0
	} else {
		e.portamento_time = exp_map(portamento_unit, 0.002, 3.0)
	}
	e.portamento_auto = resolved_position(74, p.values[74]) != 0

	switch resolved_position(38, p.values[38]) {
	case 0:
		e.play_mode = .Poly
	case 1:
		e.play_mode = .Mono
	case:
		e.play_mode = .Legato
	}

	// Displays "0".."24": semitones.
	e.pitch_bend_range = display_number(40, p.values[40], 12)

	// The two MIDI controller assignments, parameters 86..89 with 50 and 51.
	//
	// These four are the only continuous parameters in the table -- they carry a
	// raw 16-bit number rather than a state list -- so the stored integer is taken
	// as it is rather than resolved through `parameter_states`. See `Midi_Control`
	// for what the numbers mean and how that was established.
	bind_midi_ctrl :: proc(c: ^Midi_Control, p: patch.Patch, src, dest, sens: int) {
		source := p.values[src]
		// 0xB0 in the high byte is a control change; the low byte is the
		// controller number. Anything else -- aftertouch, pitch bend -- is a
		// source this engine does not route yet, and is left inert rather than
		// misread as controller zero.
		c.cc = (source >> 8) == 0xB0 ? source & 0x7F : -1
		target := p.values[dest]
		c.target = target >= 0 && target < patch.PARAMETER_COUNT ? target : -1
		// Signed, centred at the two states that both read "0%".
		c.amount = display_number(sens, p.values[sens], 0) / 100.0
	}
	bind_midi_ctrl(&e.midi_ctrl[0], p, 86, 87, 50)
	bind_midi_ctrl(&e.midi_ctrl[1], p, 88, 89, 51)

	// Parameter 90 displays "L 100%", ..., "center", ..., "R 100%". The
	// displays are not signed, so position is the honest reading: the table is
	// a left-to-right sweep and its midpoint is centre.
	// Parameter 90 displays "L 100%" .. "center" .. "R 100%", so its centre is a
	// named state and reaching it exactly matters: an off-centre pan puts a small
	// permanent offset on every voice.
	e.pan = centred_position(90, p.values[90])

	// -- equaliser -----------------------------------------------------------
	//
	// A parametric peak plus a tone tilt, which is what the manual describes and
	// what the parameters confirm. Two of the four carry real units.
	//
	// There is no on/off switch for this section and it does not need one: the
	// level display reads exactly "0.0 db" at stored 64 and the tone is flat at its
	// own centre, so a patch that leaves both alone passes through untouched.
	e.eq_freq_hz = display_frequency_hz(resolved_display(61, p.values[61]))
	e.eq_gain_db = display_number(62, p.values[62], 0)
	// Parameter 63 is a bare 0..127, described only as "flat turning left, steep
	// turning right". 0.3 to 8 spans a broad shelf-like lift through to a narrow
	// notch, which is the useful span for a single band; the curve is chosen.
	e.eq_q = exp_map(unit_position(63, p.values[63]), 0.3, 8.0)
	// Parameter 60, centred flat, same reading as the delay's tone.
	e.eq_tone = centred_position(60, p.values[60])

	// -- effect unit ---------------------------------------------------------
	//
	// Parameters 77..81. Every one of the five displays a bare integer, so there is
	// no unit anywhere in this section to read: the curves in src/dsp/effect.odin
	// come from probing the reference directly, and which of them are measured and
	// which chosen is recorded there.
	//
	// Two things are worth saying here rather than there. No patch in the factory
	// bank turns this unit on, so nothing in the null test exercises any of it.
	// And its position in the chain -- after the equaliser, before the delay -- is
	// inferred from the order the manual lists the sections in, which is the same
	// order that turned out to be right for the equaliser, delay and chorus.
	e.effect_on = resolved_position(77, p.values[77]) != 0
	// Ten states displayed "0".."9" in order, so the identifier and the position
	// agree. Read as an identifier anyway, because that is what it is.
	e.effect_type = dsp.Effect_Type(clamp_int(resolved_display_id(78, p.values[78]), 0, 9))
	e.effect_ctl1 = unit_position(79, p.values[79])
	e.effect_ctl2 = unit_position(80, p.values[80])
	// The decimator's step is a count of steps up the knob rather than a fraction
	// of it -- measured as exactly `stored - 9` samples -- so that type needs the
	// position itself and not the normalised version.
	e.effect_ctl1_steps = f32(resolved_position(79, p.values[79]))
	// Parameter 81 is a linear dry/wet crossfade, measured: the dry gain tracks
	// 1 - level/127 to within 0.003 across the range, and at level 0 the reference's
	// render is bit-identical to the unit being switched off.
	e.effect_level = unit_position(81, p.values[81])

	// -- delay ---------------------------------------------------------------
	//
	// Unusually for this file, most of this is read rather than chosen. The
	// displays carry real units: parameter 35 spells out musical divisions,
	// 83 reads out the two channel times in milliseconds, 37 is a percentage.
	e.delay_on = resolved_position(65, p.values[65]) != 0
	{
		display := resolved_display(35, p.values[35])
		beats, musical := delay_display_beats(display)
		e.delay_beats = beats
		if !musical {
			// State 0 is "0.1 msec", a fixed short time rather than a division.
			ms, ok := display_leading_number(display)
			e.delay_fixed_ms = ok ? ms : 0.1
		}
	}
	e.delay_left_ms, e.delay_right_ms = delay_spread_ms(resolved_display(83, p.values[83]))
	// Parameter 36 is a bare 0..127 and feeds that fraction of each echo back.
	// A transient at stored 100 decays by 100/127 per repeat, while stored 127
	// holds at unity, so there is no conventional just-below-one scale here.
	e.delay_feedback = unit_position(36, p.values[36])
	// Parameter 37 displays a percentage, so it is read, not mapped.
	e.delay_dry_wet = dsp.clamp32(display_number(37, p.values[37], 0) / 100.0, 0, 1)
	// Parameter 98 is a bare 0..127 with the centre flat, per the manual's
	// description of a knob that cuts highs one way and lows the other.
	e.delay_tone = centred_position(98, p.values[98])
	// Parameter 82's three states are named in the changelog rather than the
	// manual: v1.07 alpha lists them as "ノーマルステレオ(ST)、クロスフィードバック(X)、
	// ピンポン(PP)", so in order they are normal stereo, cross feedback and
	// ping-pong. A reference transient confirms that state 2 starts in the left
	// channel and alternates sides on every repeat.
	switch resolved_position(82, p.values[82]) {
	case 1:
		e.delay_mode = .Cross
	case 2:
		e.delay_mode = .Ping_Pong
	case:
		e.delay_mode = .Stereo
	}

	// -- chorus --------------------------------------------------------------
	e.chorus_on = resolved_position(66, p.values[66]) != 0
	// Parameter 64's three states display "1", "2" and "4", read here as the
	// number of stages.
	e.chorus_stages = clamp_int(resolved_display_id(64, p.values[64]), 1, dsp.CHORUS_MAX_STAGES)
	// Parameter 52 displays milliseconds, 54 hertz, 55 a signed percentage.
	e.chorus_delay_ms = max(display_number(52, p.values[52], 1.0), 0.01)
	e.chorus_rate_hz = max(display_number(54, p.values[54], 0.5), 0.0)
	e.chorus_feedback = dsp.clamp32(display_number(55, p.values[55], 0) / 100.0, -1, 1)
	// Parameter 53's depth stays a linear reading, and stays a guess.
	//
	// The measurement says the shape is nothing like linear. `chorusprobe --sweep
	// depth` isolates the chorus in the side signal and reads the pitch wobble a
	// swept tap produces, which converts back to a delay swing in closed form.
	// Normalised against full depth:
	//
	//   stored      16      32      64      96     127
	//   measured  0.004   0.012   0.050   0.202   1.000
	//   linear    0.126   0.252   0.504   0.756   1.000
	//
	// Steeply exponential. But the measurement does not settle the *scale*, only
	// the shape: at full depth the swing is 0.50 of the centre delay at a 30 ms
	// centre, 0.35 at 18.9 ms and 0.25 at 3.8 ms, so the reference is not simply
	// scaling by the centre and there is no single fraction to apply.
	//
	// Fitting the shape with half the centre as its top made the null test worse on
	// every count that matters here -- stereo width from -0.065 back out to -0.323,
	// spectral error up 0.4 dB -- which is what a right shape on a wrong scale does.
	// The shape, now applied. Two things changed since the note above was written.
	//
	// First, the rate used to convert a pitch wobble into a delay swing was the
	// *displayed* one, and that was never checked. It checks out: measuring how fast
	// the tracked pitch itself oscillates gives 0.95, 1.04 and 1.01 times the display
	// at the three rates whose period fits the analysis window. So parameter 54 needs
	// no curve at all -- it is read in hertz and the hertz are real.
	//
	// Second, and this is what unblocks the shape: the swing *is* proportional to the
	// centre delay after all. The earlier reading of 0.50, 0.35 and 0.25 of the centre
	// suggested otherwise, but the wobble per millisecond of centre delay is constant
	// -- 58.8, 60.8, 61.9 and 63.3 cents per ms across centres from 14.6 to 29.8 ms --
	// and a constant ratio is what a multiplicative law looks like. So the DSP's
	// existing "fraction of the centre delay" is the right form, and only the curve
	// from the knob to that fraction was wrong.
	//
	//   stored      16      32      64      96     127
	//   measured  0.004   0.012   0.050   0.202   1.000
	//   fitted    0.005   0.011   0.051   0.232   1.000
	//
	// The exponent is bracketed by the measurement rather than read off it, and the
	// null test picks inside the bracket. Both ends of the sweep are the least
	// trustworthy points: at full depth the instrument returns a swing larger than the
	// centre delay, which is impossible and about 1.35 times too big, and at stored 16
	// the wobble it is reading is 7 cents, near its own noise floor. Correcting the
	// top for that over-read refits the exponent at about 5.4; an under-read at the
	// bottom pushes it the other way. So the form is measured -- exponential in the
	// knob, multiplicative in the centre delay -- and the exponent is not.
	//
	// Four curves were tried across the whole bank, medians:
	//
	//                        spectral  envelope   width
	//   linear                 11.69     9.35    -0.060
	//   exp(3(u-1))             8.84     9.02    -0.072   best, and wrong at u=0
	//   anchored k=6           10.22    11.32    -0.230   best fit, too steep
	//   anchored k=2            9.24     9.32    -0.076   ships
	//
	// The floored exp(3(u-1)) form scores 0.4 dB better and is not used, because it
	// never reaches zero: it leaves 5% of depth at the bottom of the knob, where the
	// reference is measurably and exactly mono. A curve that is wrong at a point which
	// was verified directly does not get to ship for 0.4 dB.
	//
	// Anchored k=6 is the best fit to the measured shape and clearly too steep on the
	// bank, which says the shape measurement under-reads the middle of the range --
	// consistent with the wobble at stored 16 being 7 cents, near the instrument's own
	// noise floor. So k is the part chosen by the oracle; the *form*, and the zero at
	// the bottom, are measured.
	//
	// The *scale* -- whether full depth swings the tap by the whole centre delay or
	// some fraction -- is still unmeasured. Two instruments failed at it, both for
	// reasons now recorded in chorusprobe.odin, so the top of the range stays put.
	// Anchored at both ends: exactly zero at the bottom of the knob and one at the
	// top. That is not cosmetic. The reference at stored depth 0 is *exactly mono* --
	// side/mid measures 0.0000 with the channels correlating at +1.000 -- so its depth
	// there is zero, and a plain exp(k * (u - 1)) never reaches zero. It left 5% of
	// depth at the bottom, which for a broadband source is enough to decorrelate the
	// channels completely: our width at stored 0 was 0.545 against the reference's
	// 0.000.
	//
	// The exponent is measured now, and the two paragraphs above are the record of
	// what it cost to get there rather than a live justification.
	//
	// `s1probe chorusdepth` reads the tap excursion off a *tone* instead of noise.
	// A swept tap Dopplers the tone, so the demodulated phase is exactly
	// -2*pi*f0*D(t) and the delay is already in it: the peak-to-peak phase swing
	// over one sweep is 2*pi*f0*(2*swing), with no derivative and no transform, so
	// a rate of 0.99 Hz costs nothing to resolve. The wet is isolated by rendering
	// the same patch with parameter 66 on and off and subtracting, which works
	// because the source is a sine and both renders are deterministic; the
	// diagnostic that proved it reads wet/dry = 1.00 on both engines.
	//
	// It self-checks at both anchors. A static tap (stored 0) reads 0.000 on both
	// engines, and full depth reads 15.66 ms against the reference's own 15.12 ms
	// centre delay -- so full depth really does swing the tap by the whole centre
	// delay, which the paragraph above records as unmeasured. Measured curve:
	//
	//   stored      0     16      32      64      96     112     127
	//   reference  0.000  0.0071  0.0229  0.0957  0.3286  0.5957  1.0357
	//   k = 4.65   0.000  0.0077  0.0215  0.0909  0.3149  0.5733  1.0000
	//   k = 2.0    0.000  0.0449  0.1026  0.2723  0.5533  0.7567  1.0000
	//
	// k = 4.65 is the least-squares fit in log space, at 0.060 against k = 2.0's
	// 1.195 and k = 6.0's 0.678. The shipped k = 2.0 was up to **seven times too
	// deep** at the quiet end of the knob, and the four-point table that used to
	// sit here described k = 6 rather than the constant beside it -- the constant
	// had been retuned against the bank and the table left stale, which is how a
	// 7x error survived in a file that documents everything.
	//
	// Re-measured after the change, ours against the reference's, the ratio is
	// 0.97 to 1.01 across the whole knob. On the bank: spectral 7.65 -> 7.57 mean
	// and 7.15 -> 6.90 median, level +0.91 -> +0.67, null depth -3.40 -> -3.59.
	CHORUS_DEPTH_K :: f32(4.65)
	{
		u := unit_position(53, p.values[53])
		e.chorus_depth = (math.exp(CHORUS_DEPTH_K * u) - 1.0) / (math.exp(CHORUS_DEPTH_K) - 1.0)
	}
	// Parameter 56's level, on the other hand, is linear -- and that was already
	// what this read. Measured against a chorus-off render, the wet grows 0.252,
	// 0.504, 0.756, 1.000 of full across stored 32, 64, 96, 127: linear to three
	// decimal places.
	e.chorus_level = unit_position(56, p.values[56])

	return e
}

// The seven parameter indices an LFO owns, in the order the two LFOs lay them
// out. Passing them in keeps one implementation for both rather than a copy
// that can drift.
bind_lfo :: proc(
	l: ^Lfo_Params,
	p: patch.Patch,
	on_off, shape_index, dest_index, speed_index, depth_index, tempo_index, key_index: int,
) {
	l.enabled = resolved_position(on_off, p.values[on_off]) != 0

	// The position, not the display identifier, and that is measured.
	//
	// Parameters 42 and 47 store their six states in display order 0, 1, 5, 2, 3,
	// 4, and this read the display identifier on the reasoning that a display of
	// "5" out of order must be carrying the waveform's identity. It is not. The
	// out-of-order display is a red herring; the shapes are in plain state order.
	//
	// `s1probe lfoshape` points the LFO at the stereo position -- the same clean
	// bipolar observable `lforate` uses -- folds the series into one cycle at a
	// period taken from its own autocorrelation, and matches that against the five
	// deterministic candidates over every phase alignment. Measured per stored
	// value, which is what a patch actually contains:
	//
	//   stored  display  position   reference        this used to bind
	//        0      "0"         0   saw down           saw          ok
	//        1      "1"         1   triangle           triangle     ok
	//        2      "5"         2   square             random sm.   wrong
	//        3      "2"         3   sample & hold      sine         wrong
	//        4      "3"         4   random smooth      square       wrong
	//        5      "4"         5   sine               sample & h.  wrong
	//
	// Read down the position column and the readme's own list comes back exactly:
	// saw, triangle, sine, square, random (sample & hold), random (smoothed). So
	// the documentation was right about the *order* all along and this engine was
	// wrong about what the order indexes. Four of the six states were bound to the
	// wrong shape, including both random ones and the square.
	//
	// The evidence is direct rather than inferential. Saw, triangle, sine and
	// square each fold to a cycle correlating above 0.95 with their template and
	// repeat at 1.000; the two random states do not repeat at all, and are told
	// apart from each other by their largest single-frame step -- sample and hold
	// jumps a quarter of its range at once, the smoothed one never exceeds a
	// hundredth.
	switch resolved_position(shape_index, p.values[shape_index]) {
	case 0:
		l.shape = .Saw
	case 1:
		l.shape = .Triangle
	case 2:
		l.shape = .Sine
	case 3:
		l.shape = .Square
	case 4:
		l.shape = .Sample_Hold
	case:
		l.shape = .Random_Smooth
	}

	// Displays "1".."7", so the identifier is one-based.
	dest := resolved_display_id(dest_index, p.values[dest_index]) - 1
	dest = clamp_int(dest, 0, int(max(Lfo_Destination)))
	l.destination = Lfo_Destination(dest)

	// Parameter 43/48, measured rather than chosen.
	//
	// The curve this replaces spanned 0.05 Hz to 40 Hz. `s1probe lforatetable`
	// points the LFO at the stereo position and counts how often that crosses its
	// own mean, growing the render until enough cycles fit, and the real curve
	// runs 0.078 Hz to **125 Hz** -- so the engine was 1.6 times too slow at the
	// bottom of the range and 3.1 times too slow at the top. The version history's
	// "LFO maximum speed up" entry is not an exaggeration; the top of this knob is
	// an audio-rate oscillator.
	//
	// Like the filter cutoff, it moves in steps of close to one semitone: 0.083
	// octaves per step across ten and a half octaves.
	speed_unit := unit_position(speed_index, p.values[speed_index])
	l.rate_hz = LFO_RATE_HZ[clamp_int(resolved_position(speed_index, p.values[speed_index]), 0, LFO_RATE_TABLE_SIZE - 1)]

	// Tempo sync reuses the same knob to pick a musical division. No state
	// display gives the division table -- parameter 43's displays are a bare
	// 0..127 -- so this ladder is a chosen mapping, spanning four beats per
	// cycle down to a sixteenth.
	sync_divisions := [8]f32{4.0, 3.0, 2.0, 1.5, 1.0, 0.75, 0.5, 0.25}
	division := clamp_int(int(speed_unit * f32(len(sync_divisions))), 0, len(sync_divisions) - 1)
	l.sync_beats = sync_divisions[division]

	// The depth knob, twice: its linear travel, and its measured curve.
	//
	// The curve was nearly adopted once before on the strength of the old pitch
	// sweep, and rejected because that sweep reported a different full-depth figure
	// at every note -- which an LFO cannot do, so no ratio taken from it could be
	// trusted either. A curve adopted on compromised evidence is not better than
	// the guess it replaces.
	//
	// `s1probe lfopitch` removes that objection. Driving the LFO with a square
	// instead of a triangle makes the pitch two steady values rather than a sweep,
	// and the reading is then note-independent to the last printed digit. Twenty
	// settings across the range fit an anchored exponential to a tenth of a
	// semitone. See LFO_DEPTH_CURVE_K, which also says why this is kept apart from
	// `depth` rather than replacing it.
	//
	// Worth noting what the earlier attempt got right: normalised, its ratios were
	// 0.089, 0.249 and 0.535 of full at stored 32, 64 and 96, and the clean
	// measurement gives 0.086, 0.242 and 0.522. The *shape* was right all along and
	// the scale was not, which is the third time in this project that a measurement
	// has been sound about shape and wrong about what to do with it.
	l.depth = unit_position(depth_index, p.values[depth_index])
	l.pitch_depth = lfo_pitch_depth_curve(l.depth)
	l.pan_depth = lfo_pan_depth_curve(l.depth)
	l.tempo_sync = resolved_position(tempo_index, p.values[tempo_index]) != 0
	l.key_sync = resolved_position(key_index, p.values[key_index]) != 0
}

clamp_int :: proc(v, lo, hi: int) -> int {
	if v < lo {return lo}
	if v > hi {return hi}
	return v
}
