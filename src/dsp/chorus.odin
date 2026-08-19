package dsp

import "core:math"

// The stereo chorus, which is also the flanger.
//
// One structure covers both because the reference does not separate them: the
// manual calls the section "chorus/flanger", and the parameters make the
// difference. Parameter 52's delay time reads out in milliseconds from 0.05 to
// 30, parameter 54's rate from 0.01 Hz to **400 Hz**, and parameter 55's feedback
// from -99% to +97%. A 30 ms tap swept slowly with no feedback is a chorus; a
// 0.2 ms tap with 90% feedback is a flanger; and a 400 Hz sweep is neither, it is
// a ring modulator with delay. All three fall out of the same three knobs.
//
// Parameter 64 has three states displayed "1", "2" and "4", which is the number
// of stages -- the one effect parameter here whose meaning is inferred rather
// than read off a unit, and the inference is that a chorus with more voices is
// what those numbers count.
CHORUS_MAX_STAGES :: 4

// How far the right channel's tap set sits from the left's, in turns.
//
// Fitted to two measured widths at once, which is what makes it a single constant
// rather than two: the reference reads 0.538 with one tap per channel and 0.418 with
// two, and this is the offset that reproduces both. See the sweep in chorus.odin.
CHORUS_CHANNEL_PHASE :: f32(0.25)

Chorus_Params :: struct {
	// Number of modulated taps, 1, 2 or 4.
	stages:      int,
	// Centre delay in samples, from parameter 52's millisecond display.
	delay_samples: f32,
	// How far the tap swings, as a fraction of the centre delay.
	depth:       f32,
	// Sweep rate in hertz, from parameter 54's display.
	rate_hz:     f32,
	// -1..1, from parameter 55's percentage display. Negative inverts.
	feedback:    f32,
	// 0..1, how much of the wet signal joins the dry.
	level:       f32,
}

Chorus :: struct {
	line:  [2]Delay_Line,
	// One phase, shared. Each stage and each channel reads it at its own offset,
	// which is what makes the image wide rather than two mono choruses.
	phase: f32,
}

chorus_init :: proc "contextless" (c: ^Chorus, left, right: []f32) {
	delay_line_init(&c.line[0], left)
	delay_line_init(&c.line[1], right)
	c.phase = 0
}

chorus_reset :: proc "contextless" (c: ^Chorus) {
	delay_line_clear(&c.line[0])
	delay_line_clear(&c.line[1])
	c.phase = 0
}

// Process one stereo sample.
//
// Each stage taps the line at the centre delay swept by a sine, and the stages
// are spread evenly around the sweep so that four of them are ninety degrees
// apart. The two channels are offset a further quarter cycle from each other:
// that quadrature is the whole reason a chorus sounds wide, and without it the
// two channels move together and the result is mono with vibrato.
chorus_process :: proc "contextless" (
	c: ^Chorus,
	left_in, right_in: f32,
	p: ^Chorus_Params,
	sample_rate: f32,
) -> (
	left, right: f32,
) {
	stages := clamp_int_dsp(p.stages, 1, CHORUS_MAX_STAGES)
	level := clamp32(p.level, 0, 1)

	// The feedback is the knob's percentage, and the ceiling on it is measured.
	//
	// `s1probe chorusfb` turns the chorus into a static comb -- depth zero, longest
	// centre delay -- strikes it, and reads the loop gain off how fast the tail
	// decays, since a feedback loop with a fixed delay decays geometrically. Across
	// the middle of the knob the reference and this engine already agreed to within
	// a couple of percent, which is what confirms the law is the display over a
	// hundred:
	//
	//   stored        8      16      32      48      96     112     127
	//   display     -87%    -74%    -50%    -25%     50%     74%     97%
	//   reference   0.879   0.766   0.511   0.273   0.511   0.766   0.980
	//   this        0.877   0.754   0.512   0.295   0.513   0.766   0.953
	//
	// The ends were the exception, and this clamp was why. At stored 0 -- which is
	// what **124 of the 128 factory patches carry** -- the reference's tail does not
	// decay at all: 0.0 dB per second, a loop gain of 1.000, ringing until something
	// stops it. A clamp at 0.95 turned that into 14 dB per second, so on almost the
	// whole bank this engine's chorus was too damped, contributing less wet signal
	// and less decorrelation than the reference's. It reads as the chorus being too
	// quiet and too narrow, which is exactly what the null test kept saying.
	//
	// Held a hair under unity rather than at it. The reference measures 1.000 within
	// the instrument's resolution and may well sit exactly there, but a delay loop at
	// unity has no answer to the energy already in it, and this engine has to stay
	// bounded for the tests that say so. 0.99 rings for about twenty seconds at the
	// longest centre delay, which is the audible behaviour without the hazard.
	feedback := clamp32(p.feedback, -0.99, 0.99)
	depth := clamp32(p.depth, 0, 1)

	// Advance the shared sweep.
	if sample_rate > 0 && is_finite(p.rate_hz) {
		c.phase += clamp32(abs(p.rate_hz), 0.0, sample_rate * 0.49) / sample_rate
		if c.phase >= 1.0 {
			c.phase -= f32(int(c.phase))
		}
	}

	centre := p.delay_samples
	if !is_finite(centre) || centre < 1.0 {
		centre = 1.0
	}
	swing := centre * depth

	wet_left: f32 = 0
	wet_right: f32 = 0

	// One tap goes to both channels; more than one is split between them.
	//
	// Parameter 64's three settings are 1, 2 and 4, and they are not three stage
	// counts feeding a stereo pair -- they are three *tap* counts split across the
	// channels, which is a different thing and audibly so. Measured on the
	// reference, with the side signal isolated so only the chorus is in it:
	//
	//   type 1   no side signal at all, and one tap's worth of wet
	//   type 2   a wide side signal, and one tap's worth of wet
	//   type 4   a narrower side signal, and *two* taps' worth of wet
	//
	// So type 1 is a mono chorus, type 2 sends one tap to each channel, and type 4
	// sends two to each. That explains all three readings: the per-channel level
	// goes 1, 1, 2, and type 4 is narrower than type 2 because averaging two
	// opposed sweeps into one channel takes some of the difference back out.
	//
	// An earlier version treated the number as stages, gave every type a channel
	// offset, and divided by the count to hold the level steady. That made type 1
	// stereo when it should be mono and flattened the level difference between 2
	// and 4, which is why this engine's stereo width sat well under the
	// reference's.
	if stages == 1 {
		sweep := math.sin(TAU * c.phase)
		tap := delay_line_read(&c.line[0], centre + swing * sweep)
		// The same tap to both channels: mono, and no side signal.
		wet_left = tap
		wet_right = tap
		delay_line_write(&c.line[0], left_in + wet_left * feedback)
		delay_line_write(&c.line[1], right_in + wet_right * feedback)
		left = left_in + wet_left * level
		right = right_in + wet_right * level
		return sanitize(left), sanitize(right)
	}

	// Taps are dealt to the channels by *channel*, not by alternating index, and the
	// right channel's whole set is offset from the left's by one phase constant.
	//
	// The arrangement this replaces alternated even taps to the left and odd to the
	// right, which is the same thing for two taps and a different thing for four:
	// it made four taps *wider* than two, and the reference makes them narrower.
	// Measured side/mid against tap count:
	//
	//   taps          1       2       4
	//   reference   0.000   0.538   0.418
	//   alternating 0.000   0.546   0.676
	//
	// Both engines agree that one tap is mono and two are wide. The disagreement at
	// four is the point: putting more sweeps into each channel should take
	// difference back out, because each channel then carries a spread of delays
	// rather than a single one, and a spread resembles the other channel's spread
	// more than one delay resembles another. Dealing per channel does that; the
	// alternating form does not, because it hands each channel a symmetric pair
	// whose spread swings in quadrature with the other channel's.
	//
	// Part of what made four taps read wider is not decorrelation at all: two taps
	// per channel is twice the wet against an unchanged dry, so the side grows
	// against the mid for free. The reference carries that same doubling -- its type
	// 4 has two taps' worth of wet per channel -- and still comes out narrower, so
	// its channels must be markedly more alike than the alternating form's.
	per_channel := max(stages / 2, 1)
	for channel in 0 ..< 2 {
		base := channel == 0 ? f32(0) : CHORUS_CHANNEL_PHASE
		for j in 0 ..< per_channel {
			// Each channel's own taps spread evenly around the cycle.
			offset := base + f32(j) / f32(per_channel)
			sweep := math.sin(TAU * (c.phase + offset))
			tap := delay_line_read(&c.line[channel], centre + swing * sweep)
			if channel == 0 {
				wet_left += tap
			} else {
				wet_right += tap
			}
		}
	}

	// Averaged per channel, so two taps carry the same wet level as one.
	//
	// This is what makes four taps narrower than two rather than wider, and it does it
	// for two reasons at once. The level stops doubling, so the side signal stops
	// growing against an unchanged dry for free. And averaging two opposed sweeps
	// leaves each channel closer to a fixed delay than either tap is on its own, so
	// the channels resemble each other more.
	//
	// Not averaging was tried and is what produced 0.676 against the reference's
	// 0.418. The inter-channel phase was swept from a quarter turn to nearly a half
	// first, on the theory that the offset was the lever; it moved the width by 0.006
	// in total, which ruled it out and left the level.
	//
	// Two independent measurements agree. Against the reference directly, four taps
	// now match to three decimals -- width 0.418 against 0.418, and the channels
	// correlating at 0.700 against 0.701. And on the factory bank, split by the tap
	// count each patch actually uses, the spectral error of the twelve patches this
	// touches falls from 21.98 dB to 10.15 dB, which takes them from by far the worst
	// group to the same place as everything else. The other 111 patches do not move.
	//
	// What did not improve is those same twelve patches' stereo width, which goes from
	// 0.225 to 0.332 narrower than the reference, and their envelope error, up 3.1 dB.
	// So the tap *levels* are now right and something about how the two channels
	// differ still is not. The direct probe cannot see it: its width saturates above a
	// depth of about 16 with a noise source, which is why it reads an exact match
	// where the bank reads a gap.
	if per_channel > 1 {
		scale := f32(1.0) / f32(per_channel)
		wet_left *= scale
		wet_right *= scale
	}

	delay_line_write(&c.line[0], left_in + wet_left * feedback)
	delay_line_write(&c.line[1], right_in + wet_right * feedback)

	left = left_in + wet_left * level
	right = right_in + wet_right * level
	return sanitize(left), sanitize(right)
}

// Layer 0 has no integer clamp of its own, and importing one would mean importing
// the engine.
clamp_int_dsp :: proc "contextless" (v, lo, hi: int) -> int {
	if v < lo {return lo}
	if v > hi {return hi}
	return v
}
