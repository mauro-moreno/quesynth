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

// Parameter 23's measured drive curve.
//
// A sine through an open, non-resonant filter identifies both halves of the
// law independently. The reference keeps the waveform's peak fixed at every
// setting and every downstream gain, while its harmonic series approaches a
// square wave. That is a peak-normalised tanh:
//
//     y = tanh(drive * x) / tanh(drive)
//
// The values below invert the measured THD at each knot. Linear interpolation
// is deliberate: the knots are at most eight states apart across the curved
// part of the control, making the interpolation error smaller than the probe's
// 0.1 dB THD resolution. Stored 109 and 122 are included because the two worst
// factory outliers use those exact settings.
FILTER_SATURATION_STATES := [?]int{
	0, 2, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64,
	72, 80, 88, 96, 104, 109, 112, 120, 122, 124, 127,
}
FILTER_SATURATION_DRIVE := [?]f32{
	0.0, 0.110344, 0.156102, 0.238590, 0.319932, 0.403366,
	0.588754, 0.812051, 1.088197, 1.418726, 1.827576, 2.321027,
	2.917104, 3.711868, 4.771326, 6.096842, 8.177998, 9.634074,
	10.250473, 13.854322, 15.213064, 15.9, 16.879008,
}

filter_saturation_drive :: proc(stored: int) -> f32 {
	state := resolved_position(23, stored)
	if state <= FILTER_SATURATION_STATES[0] {
		return FILTER_SATURATION_DRIVE[0]
	}
	last := len(FILTER_SATURATION_STATES) - 1
	if state >= FILTER_SATURATION_STATES[last] {
		return FILTER_SATURATION_DRIVE[last]
	}
	for i in 0 ..< last {
		lo_state := FILTER_SATURATION_STATES[i]
		hi_state := FILTER_SATURATION_STATES[i + 1]
		if state <= hi_state {
			t := f32(state - lo_state) / f32(hi_state - lo_state)
			return dsp.lerp32(FILTER_SATURATION_DRIVE[i], FILTER_SATURATION_DRIVE[i + 1], t)
		}
	}
	return FILTER_SATURATION_DRIVE[last]
}

// Where the 24 dB response moves from its resonance-0 corner surface to the
// high-Q peak surface. The transition was measured at cutoff states 44, 64, 80
// and 110. At each resonance the four log-frequency fractions agreed closely;
// these are their means:
//
//   resonance       0       4       8      16      32      64     107
//   blend       0.0000  0.2405  0.4332  0.7000  0.8773  0.9835  1.0000
//
// Interpolation is linear between measured controller states here and
// geometric between the two frequency tables below. Frequencies and cutoff
// ratios live in octaves, so an arithmetic Hz blend would be the wrong space.
FILTER_CUTOFF_24_RESONANCE_STATES := [?]int{0, 4, 8, 16, 32, 64, 107}
FILTER_CUTOFF_24_RESONANCE_BLEND := [?]f32{0.0, 0.2405, 0.4332, 0.7000, 0.8773, 0.9835, 1.0}

// Converting the reference's audible corner target into the coefficient this
// engine's two-section topology needs. At low Q its -3 dB corner is consistently
// 0.80 of the supplied coefficient, so the resonance-0 surface needs 1.255x.
// The factor was measured from cutoff 44 through 110 at every resonance knot;
// it reaches unity once the resonant peak, rather than the cascade's corner
// ratio, anchors the response.
FILTER_CUTOFF_24_TOPOLOGY_SCALE := [?]f32{1.255, 1.259, 1.264, 1.267, 1.165, 1.0, 1.0}

// The same conversion for the 12 dB low pass, which had none.
//
// Measured as the gain our stopband carries over the reference's: +2.86 dB at
// cutoff 40 and +3.00 at 64 with the resonance off, running to +3.69 at
// resonance 96. On a 12 dB per octave slope that is 0.24 octaves of corner, and
// 2^-0.24 is the factor below. The passband agrees to within half a decibel
// either side of the change, which is what says this is a corner and not a gain.
FILTER_CUTOFF_12_LOW_PASS_RATIO :: f32(0.846)

filter_cutoff_24_resonance_blend :: proc(stored: int) -> f32 {
	state := resolved_position(20, stored)
	if state <= FILTER_CUTOFF_24_RESONANCE_STATES[0] {
		return FILTER_CUTOFF_24_RESONANCE_BLEND[0]
	}
	last := len(FILTER_CUTOFF_24_RESONANCE_STATES) - 1
	if state >= FILTER_CUTOFF_24_RESONANCE_STATES[last] {
		return FILTER_CUTOFF_24_RESONANCE_BLEND[last]
	}
	for i in 0 ..< last {
		lo_state := FILTER_CUTOFF_24_RESONANCE_STATES[i]
		hi_state := FILTER_CUTOFF_24_RESONANCE_STATES[i + 1]
		if state <= hi_state {
			t := f32(state - lo_state) / f32(hi_state - lo_state)
			return dsp.lerp32(FILTER_CUTOFF_24_RESONANCE_BLEND[i], FILTER_CUTOFF_24_RESONANCE_BLEND[i + 1], t)
		}
	}
	return FILTER_CUTOFF_24_RESONANCE_BLEND[last]
}

filter_cutoff_24_topology_scale :: proc(stored: int) -> f32 {
	state := resolved_position(20, stored)
	if state <= FILTER_CUTOFF_24_RESONANCE_STATES[0] {
		return FILTER_CUTOFF_24_TOPOLOGY_SCALE[0]
	}
	last := len(FILTER_CUTOFF_24_RESONANCE_STATES) - 1
	if state >= FILTER_CUTOFF_24_RESONANCE_STATES[last] {
		return FILTER_CUTOFF_24_TOPOLOGY_SCALE[last]
	}
	for i in 0 ..< last {
		lo_state := FILTER_CUTOFF_24_RESONANCE_STATES[i]
		hi_state := FILTER_CUTOFF_24_RESONANCE_STATES[i + 1]
		if state <= hi_state {
			t := f32(state - lo_state) / f32(hi_state - lo_state)
			return dsp.lerp32(FILTER_CUTOFF_24_TOPOLOGY_SCALE[i], FILTER_CUTOFF_24_TOPOLOGY_SCALE[i + 1], t)
		}
	}
	return FILTER_CUTOFF_24_TOPOLOGY_SCALE[last]
}

// Near the 20 Hz DSP floor the filter's measured corner converges on its
// coefficient frequency, so the low-Q topology compensation must converge on
// one too. It reaches the full measured factor by cutoff state 20; applying the
// factor unchanged at state zero raises the audible floor from 23 to 28 Hz.
filter_cutoff_24_effective_topology_scale :: proc(scale, state: f32) -> f32 {
	return dsp.lerp32(1, scale, dsp.clamp32(state / 20.0, 0, 1))
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
// "(8)" is an eighth note, "(16)+(32)" a dotted sixteenth, "(4) /3" a third of
// a quarter, and state 0 is not musical at all but a fixed "0.1 msec". Nothing
// about the state index says which of those shapes a state takes, so reading
// the display is the only way to get this right.
//
// A quarter note is one beat, so "(N)" is 4/N beats and "+" sums. "/3" then
// divides that sum by three -- literally three, not the musician's two thirds.
// This parser took the musical convention on trust, and it was wrong. Sweeping
// all twenty states through the reference (percussive click, 100 % wet, no
// feedback, at the harness's 120 BPM) measured every "/3" state at exactly half
// what this code played: state 1 "(32) /3" arrives at 20.90 ms, which is
// 0.125/3 beats and not 0.125*2/3, and state 13 "(1) /3" at 666.73 ms, which is
// 4/3 beats and not 8/3. All fourteen non-triplet states were already exact, so
// the sum arithmetic was never in doubt -- only this one factor was.
//
// Parameter 33 reads the same notation and ARP_STEP_BEATS, measured separately
// with `s1probe arpprobe`, has always divided by three. The nineteen musical
// states here are that table reversed. The two had disagreed by a factor of two
// since both were written, and the only test of this parser asserted the
// assumed convention, so nothing could catch it; tests/dsp now pins both.
//
// A second thing the wrong factor cost: this comment used to claim the states
// were not in ascending order of time. They are. Measured end to end the twenty
// run 0.19, 20.90, 41.73, 62.56, 83.40, 125.06, 166.73, 187.56, 250.06, 333.40,
// 375.06, 437.56, 500.06, 666.73, 750.06, 875.06, 1000.06, 1500.06, 1750.06,
// 2000.06 ms, monotonic throughout -- the readings carry a constant +0.06 ms of
// the reference's own delay-line offset. Only the doubled triplets made state 9
// look like it overshot state 10.
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
		total /= 3.0
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

	// Parameter 5's display rounds the underlying gain and is not the audio law.
	// `s1probe mixprobe --values 0,32,64,96,127`, with each curve anchored at
	// both unity endpoints, reads oscillator 2 at 0.25197, 0.50394 and 0.75591.
	// Those are stored/127 (and oscillator 1 is its complement), above the
	// display's 0.25 and 0.50 but below its 0.76. The gains sum to 1.00000 at
	// every setting; mean equal-power error is 0.3104, excluding both the rounded
	// display percentage and an equal-power crossfade.
	e.osc_mix = dsp.clamp32(f32(p.values[5]) / 127.0, 0, 1)

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

	// Parameter 45 is a bare 0..127. Preserve its linear knob position here: LFO
	// and modulation-envelope destinations move in controller space, then
	// voice.odin converts the result through the measured nonlinear FM curve
	// where the carrier increment is known.
	e.osc1_fm = unit_position(45, p.values[45])

	// Parameter 76 creates nine components inside OSC1 (and its sub), even with
	// outer unison disabled. Its measured base step is 20*stored/127 cents; the
	// audio path applies the signed factors {-7,-5,-3,-1,0,+1,+3,+5,+7}.
	e.osc1_detune = 20.0 * unit_position(76, p.values[76])

	// Parameter 91 is the phase relationship between the two oscillators at note
	// on. Stored zero leaves the phase free; the v1.07 alpha changelog says that
	// turned fully left "the phase is not fixed (as before)".
	//
	// The rest was read absolutely, not from cancellation depth. `s1probe
	// phaseabsolute --values 0,1,16,32,48,64,96,127` projects each oscillator
	// alone against note-on at five notes and separates fixed output latency by
	// its frequency slope. It reads 16 -> 0.05952, 32 -> 0.12302, 48 -> 0.18651,
	// 64 -> 0.25000, 96 -> 0.37698 and 127 -> 0.50000 turns, exact to 5e-6:
	// half a turn over the 126 engaged intervals. The old 0.5*v/127 agrees at the
	// ends but misses the middle by up to 0.002 turns. Harmonic cancellation is
	// even in phase and could not reveal that offset.
	//
	// Every `ver=105` factory patch omits parameter 91 and takes stored zero, so
	// the bank cannot select this law; the absolute reading and its signed test do.
	OSC_PHASE_MAX_TURNS :: f32(0.5)
	{
		position := resolved_position(91, p.values[91])
		e.osc_phase_fixed = position != 0
		if e.osc_phase_fixed {
			e.osc_phase_shift = OSC_PHASE_MAX_TURNS * f32(position - 1) / 126.0
		}
	}
	// Parameter 92 scales the measured per-layer phase offsets. The reference
	// reaches the signed offsets at stored 127; zero leaves every fixed-phase
	// layer aligned. It is only effective when parameter 91 fixes the oscillator
	// relationship, enforced at the use site in voice.odin.
	e.unison_phase_shift = f32(resolved_position(92, p.values[92])) / 127.0

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
	// Parameter 97 has two states, and they are "0oct" and "-1oct" -- not the
	// one-octave-down and two-octaves-down this used to assume. The vendor's own
	// v1.12 parameter list is explicit ("97 - osc1 sub octave: 0 - 0oct, the same
	// pitch as the Oscillator 1; 1 - -1oct, one octave under"), and the reference
	// is unambiguous about both states. At stored 0, with a sine carrier and a
	// full-gain sine sub, switching the sub in and out changes the reference's
	// render by -142.5 dB -- float rounding, which is what a normalised mix of
	// two identical signals gives and nothing else does. The same null appears
	// for a saw carrier with a saw sub and a triangle with a triangle, at two
	// gains. At stored 1 the sub's fundamental appears at f0/2 and there is
	// nothing at f0/4. Stored 2..127 render identically to stored 1.
	//
	// The old mapping put the sub an octave below the truth in both states, which
	// is what made the reference look like it "produces nothing at f0/2": it was
	// being asked for the wrong state and read in the wrong bin. No factory patch
	// sets parameter 95, so the bank the null test gates on cannot see any of
	// this -- 4284 of the 16698 patches in the shared banks do set it, 2450 of
	// them in the "-1oct" state, and those are what it is gated on instead.
	e.sub_octave = resolved_position(97, p.values[97]) == 0 ? 0.0 : -12.0
	// The sub's own level, and where it sits in the oscillator mix. Both read off
	// the reference rather than taken from the version history's prose.
	//
	// The history only says "when the amount of the suboscillator is raised, the
	// entire volume is automatically adjusted not to grow", which does not say by
	// how much, or what "the entire volume" covers. The reference's law is
	//
	//     out = ((1-m)*(osc1 + a*sub) + m*osc2) / (1 + a*(1-m))
	//
	// with m the oscillator mix and `a = 4 * stored95 / 127`. The sub belongs to
	// oscillator 1 -- the parameter is named "osc1 sub gain" and it means it --
	// and the automatic compensation divides by the weight the sub actually
	// carries, which is why the mix appears in the denominator.
	//
	// Three readings, each isolating one part of it:
	//
	// * `a`, at mix "100 : 0" and "-1oct", where the sub sits at f0/2 and
	//   oscillator 1 at f0 so they are separate bins. A sine sub against a sine
	//   carrier at note 48 gives |sub|/|carrier| = 0.25197, 0.50394, 1.00789,
	//   1.51184, 2.01579, 2.51974, 3.02369, 4.00010 at stored 8, 16, 32, 48, 64,
	//   80, 96, 127 -- that is 4*stored/127 to 3e-5 across the whole knob. The
	//   same render gives `1 + a` a second way, as the carrier with the sub off
	//   over the carrier with it on, and the two agree to five decimals.
	//
	// * the division, at "0oct", where the sub runs at oscillator 1's own pitch.
	//   With the sub's shape matching oscillator 1's, switching a full-gain sub
	//   in and out changes the reference's render by -142.5 dB. Only a mix
	//   normalised by its own weights returns the carrier exactly like that;
	//   holding the carrier and adding the sub cannot.
	//
	// * the `(1-m)`, re-read by `s1probe mixprobe` at five mix settings with two
	//   saws four semitones apart so no sub partial lands on oscillator 2. Its
	//   own partial is pulled down by 0.27838, 0.36768, 0.54173, 0.70962, 1.00000
	//   at stored mix 32, 64, 96, 112, 127, against this law's 0.27843, 0.36783,
	//   0.54181, 0.70962, 1.00000. A denominator of `1 + a` alone predicts a flat
	//   0.22399 and is excluded. At mix "0 : 100" the sub vanishes entirely and
	//   the reference's render is bit-identical with the sub at full gain.
	//
	// What was here before, `mix*(1 - 0.5*g) + sub*g`, had the right shape and
	// none of the three: at full gain it lifted the carrier by 3 dB where the
	// reference drops it by 14, undersold the sub by the same reasoning, and kept
	// the sub audible with oscillator 1 mixed out.
	SUB_GAIN_AT_FULL :: f32(4.0)
	{
		// Folded into the two factors the audio path multiplies by, so that path
		// holds no divide. `e.osc_mix` is already set above and cannot move at
		// runtime, so this is a per-patch quantity and not a per-sample one.
		w := SUB_GAIN_AT_FULL * unit_position(95, p.values[95]) * (1.0 - e.osc_mix)
		e.sub_gain = w / (1.0 + w)
		e.sub_carrier_gain = 1.0 / (1.0 + w)
	}

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
	// The 24 dB path needs two surfaces. `FILTER_CUTOFF_HZ_24_LOW_RESONANCE`
	// reads the -3 dB corner at resonance 0; `FILTER_CUTOFF_HZ_24` reads the
	// peak at resonance 107. Substituting either globally is wrong: the first
	// regressed 29 high-Q patches, while the second leaves resonance-0 corners
	// 1.1 octaves high around the middle of the knob. A six-resonance sweep
	// measured how the audible corner travels between them, and the helper
	// above resolves that transition in log-frequency space.
	cutoff_state := clamp_int(resolved_position(19, p.values[19]), 0, FILTER_TABLE_SIZE - 1)
	e.filter_cutoff_state = f32(cutoff_state)
	if e.filter_slope == .Slope_24 {
		blend := filter_cutoff_24_resonance_blend(p.values[20])
		topology_scale := filter_cutoff_24_topology_scale(p.values[20])
		base_topology_scale := filter_cutoff_24_effective_topology_scale(topology_scale, f32(cutoff_state))
		e.filter_cutoff_surface_blend = blend
		e.filter_cutoff_topology_scale = topology_scale
		e.filter_cutoff_hz = base_topology_scale * exp_map(
			blend,
			FILTER_CUTOFF_HZ_24_LOW_RESONANCE[cutoff_state],
			FILTER_CUTOFF_HZ_24[cutoff_state],
		)
	} else {
		e.filter_cutoff_surface_blend = 0
		e.filter_cutoff_topology_scale = 1
		e.filter_cutoff_hz = FILTER_CUTOFF_HZ[cutoff_state]
		// See FILTER_CUTOFF_12_LOW_PASS_RATIO and `filter_cutoff_at_state`, which
		// is where the cutoff a voice actually runs on is resolved.
		if e.filter_mode == .Low_Pass {
			e.filter_cutoff_hz *= FILTER_CUTOFF_12_LOW_PASS_RATIO
		}
	}
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
		e.filter_output_gain =
			e.filter_slope == .Slope_24 ? FILTER_OUTPUT_GAIN_24[state] : FILTER_OUTPUT_GAIN[state]
	}

	// Parameter 21 displays -63..64, with stored 63 as zero. Controlled sweeps
	// reveal the underlying law more directly than an octave fit: every amount
	// step moves the full envelope endpoint by exactly two parameter-19 states.
	// Sampling the cutoff table after that movement naturally reproduces both
	// the nearly constant high-Q octave slope and the varying low-Q slope.
	e.filter_env_cutoff_states =
		f32(resolved_position(21, p.values[21]) - FILTER_ENV_CENTRE_STATE) * 2.0
	// A bare 0..127. The readme: fully right "the frequency changes an octave
	// with a one octave change in the note number played (full)", fully left
	// "leave the frequency unchanged", so the linear 0..1 reading is the
	// documented one.
	e.filter_key_track = unit_position(22, p.values[22])
	e.filter_saturation_drive = filter_saturation_drive(p.values[23])
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

	// Parameter 75's outer half-span is one exponential in the stored value.
	//
	// The constants are a fit to 36 layout-verified readings from
	// `s1probe unisonprobe` -- stored 6..127 at note 84 and 2..96 at note 108 --
	// and not an endpoint anchor. Worst relative error 0.22%, RMS 0.066%, which
	// is the precision the two notes agree to (0.13% where they overlap), so the
	// residual is the probe's and not the law's.
	//
	// A quadratic in the knob position fits only the top of the range: at the
	// factory default of stored 22 it reads 1.50 cents of half-span against the
	// reference's 3.239, and the linear law before it read 4.331.
	//
	// `unison_detune` holds the full span, which the symmetric -0.5..+0.5 layer
	// layout in voice.odin halves.
	detune_position := f32(resolved_position(75, p.values[75]))
	e.unison_detune = 2.0 * 7.83036 * (math.pow(f32(2.0), detune_position / 44.0306) - 1.0)
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
