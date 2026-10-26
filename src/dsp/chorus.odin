package dsp

import "core:math"

// The stereo chorus, which is also the flanger.
//
// One structure covers both, as in the reference: parameter 52's delay time runs
// from 0.05 to 30 ms, parameter 54's rate from 0.01 Hz to 400 Hz, and parameter
// 55's feedback from -99% to +97%. A long tap swept slowly is a chorus, a short one
// with feedback is a flanger, and a 400 Hz sweep is neither.
//
// The shape of it, which is the reference's own:
//
// - Two lines, one per channel, each holding the channel's input times the level.
//   The level is applied on the way in, so the wet that comes out is already at its
//   own level and the feedback carries it.
// - One quadrature oscillator, a pair (sine, cosine) stepped by the magic-circle
//   recurrence `s -= k*c; c += k*s` with `k = 2 sin(pi f / sr)`. It starts at
//   (0, 0.9999) and is put back there at the start of a block if the cosine has
//   crept above 0.9999. The sine it hands out runs *negative* first, so a tap read
//   `delay - excursion * osc` behind the newest sample sweeps *longer* first on the
//   sine side and *shorter* first on the cosine side.
// - The sweep's excursion is a whole number of samples: the delay in whole samples
//   times the depth, truncated, and cut back so the tap never moves faster than one
//   sample per sample. The delay itself is a whole number of samples too.
// - Three arrangements of taps by parameter 64 (1, 2 or 4):
//     1  both channels read their own line at the sine's position,
//     2  the left reads at the sine's position and the right at the cosine's,
//     4  four taps, the sine's and the cosine's positions and each one's mirror
//        about the centre, mixed into both channels through a fixed matrix whose
//        rows sum to 2.
//   Feedback comes from the unmirrored taps only.
CHORUS_MAX_STAGES :: 4

// The cosine is held at this when the oscillator starts, and the oscillator is
// started again whenever the cosine rises above it at the start of a block.
CHORUS_OSCILLATOR_PEAK :: f32(0.9999)

// The four-tap arrangement's mixing weights. Each output takes all four taps and
// the two outputs take them in different proportions, which is what makes four taps
// narrower than two: each channel carries a spread of delays from both lines.
CHORUS_MIX_A :: f32(0.1)
CHORUS_MIX_B :: f32(0.3)
CHORUS_MIX_C :: f32(0.7)
CHORUS_MIX_D :: f32(0.9)

Chorus_Params :: struct {
	// 1, 2 or 4: how the taps are arranged. Anything else plays as 2.
	stages:        int,
	// Centre delay in samples; the chorus uses its whole samples.
	delay_samples: f32,
	// The sweep's reach as a fraction of the centre delay, 0..1.
	depth:         f32,
	// Sweep rate in hertz.
	rate_hz:       f32,
	// -0.99..0.99. Negative inverts.
	feedback:      f32,
	// 0..1, the level of the wet that joins the dry.
	level:         f32,
}

Chorus :: struct {
	line:    [2]Delay_Line,
	sine:    f32,
	cosine:  f32,
	enabled: bool,
	sweep:   Chorus_Sweep,
}

// The sweep's centre, reach and oscillator step, with the settings they were
// derived from: they only move with the delay, depth or rate knob.
Chorus_Sweep :: struct {
	delay_samples: f32,
	depth:         f32,
	rate_hz:       f32,
	sample_rate:   f32,
	valid:         bool,
	centre:        f32,
	scale:         f32,
	step:          f32,
}

chorus_sweep :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, sample_rate: f32) -> ^Chorus_Sweep {
	s := &c.sweep
	if !s.valid ||
	   p.delay_samples != s.delay_samples ||
	   p.depth != s.depth ||
	   p.rate_hz != s.rate_hz ||
	   sample_rate != s.sample_rate {
		centre_samples := int(p.delay_samples)
		if centre_samples < 1 {
			centre_samples = 1
		}
		s.centre = f32(centre_samples)
		s.scale = f32(chorus_excursion(centre_samples, p.depth, p.rate_hz, sample_rate)) * 65536.0
		s.step = 0
		if sample_rate > 0 && is_finite(p.rate_hz) {
			s.step = 2.0 * math.sin(math.PI * clamp32(abs(p.rate_hz), 0, sample_rate * 0.49) / sample_rate)
		}
		s.delay_samples = p.delay_samples
		s.depth = p.depth
		s.rate_hz = p.rate_hz
		s.sample_rate = sample_rate
		s.valid = true
	}
	return s
}

chorus_init :: proc "contextless" (c: ^Chorus, left, right: []f32) {
	delay_line_init(&c.line[0], left)
	delay_line_init(&c.line[1], right)
	c.sine = 0
	c.cosine = CHORUS_OSCILLATOR_PEAK
	c.enabled = false
}

chorus_reset :: proc "contextless" (c: ^Chorus) {
	delay_line_clear(&c.line[0])
	delay_line_clear(&c.line[1])
	c.sine = 0
	c.cosine = CHORUS_OSCILLATOR_PEAK
	c.enabled = false
}

// Called once at the start of a block with whether the section is on. Switching it
// on empties the lines, which is how the reference starts a chorus: whatever was in
// them from the last time it ran is not heard. The oscillator is not touched by
// that, and stands still while the section is off, because nothing steps it.
chorus_begin_block :: proc "contextless" (c: ^Chorus, enabled: bool) {
	if enabled && !c.enabled {
		delay_line_clear(&c.line[0])
		delay_line_clear(&c.line[1])
	}
	c.enabled = enabled
}

// Called at the start of every render chunk, which is at most 256 frames and restarts at
// every host block and every note event, not once per block: the oscillator is put back
// at (0, 0.9999) there if its cosine has crept above 0.9999. The magic-circle recurrence
// gains amplitude slowly, so how often this fires depends on how many chunk starts the
// cosine's peak lands on, and at a sweep of a hundred hertz and more that is a different
// set of moments from a once-per-block check.
chorus_begin_chunk :: proc "contextless" (c: ^Chorus) {
	if c.cosine > CHORUS_OSCILLATOR_PEAK {
		c.sine = 0
		c.cosine = CHORUS_OSCILLATOR_PEAK
	}
}

// How far the sweep reaches, in whole samples.
//
// The depth is a fraction of the centre delay, and it is cut back when the sweep is
// so fast and wide that the tap would move faster than one sample per sample: a
// sine of amplitude A and period T moves at 2 pi A / T, so past A = T / (2 pi) the
// amplitude is scaled to T / (2 pi) and no further. That is why a 400 Hz sweep at
// full depth is a few samples wide and not a few hundred.
chorus_excursion :: proc "contextless" (centre: int, depth, rate_hz, sample_rate: f32) -> int {
	reach := int(f32(centre) * clamp32(depth, 0, 1))
	if reach < 1 {
		return 0
	}
	scale := 1.0
	if rate_hz > 0 && is_finite(rate_hz) && sample_rate > 0 {
		period := f64(int(sample_rate / rate_hz))
		limit := f64(reach * 2) * math.PI
		if limit > period {
			scale = period / limit
		}
	}
	return int(f32(reach) * f32(scale))
}

// A tap `back` samples behind the newest sample of the line, which has just been
// written: zero is the newest, and the fraction interpolates towards older ones.
chorus_tap :: proc "contextless" (line: ^Delay_Line, back: f32) -> f32 {
	return delay_line_read(line, back + 1.0)
}

// Add to the newest sample of a line, which is how the feedback joins what was
// just written.
chorus_feed :: proc "contextless" (line: ^Delay_Line, amount: f32) {
	n := len(line.buffer)
	if n == 0 {
		return
	}
	newest := line.write - 1
	if newest < 0 {
		newest += n
	}
	fed := sanitize(line.buffer[newest] + amount)
	line.buffer[newest] = fed
	if fed != 0 {
		line.zero_run = 0
	}
}

chorus_is_silent :: proc "contextless" (c: ^Chorus) -> bool {
	return delay_line_is_silent(&c.line[0]) && delay_line_is_silent(&c.line[1])
}

// One sample of zero input through a chorus that `chorus_is_silent`: every tap
// reads zero and every write leaves a zero where a zero was, so only the
// oscillator moves, exactly as `chorus_process` moves it.
chorus_process_silence :: proc "contextless" (c: ^Chorus, p: ^Chorus_Params, sample_rate: f32) {
	step := chorus_sweep(c, p, sample_rate).step
	c.sine = c.sine - step * c.cosine
	c.cosine = c.sine * step + c.cosine
}

// Process one stereo sample.
chorus_process :: proc "contextless" (
	c: ^Chorus,
	left_in, right_in: f32,
	p: ^Chorus_Params,
	sample_rate: f32,
) -> (
	left, right: f32,
) {
	level := clamp32(p.level, 0, 1)
	feedback := clamp32(p.feedback, -0.99, 0.99)

	sweep := chorus_sweep(c, p, sample_rate)
	centre := sweep.centre
	scale := sweep.scale
	step := sweep.step
	c.sine = c.sine - step * c.cosine
	c.cosine = c.sine * step + c.cosine
	sweep_sine := f32(int(scale * c.sine)) / 65536.0
	sweep_cosine := f32(int(scale * c.cosine)) / 65536.0

	delay_line_write(&c.line[0], left_in * level)
	delay_line_write(&c.line[1], right_in * level)

	wet_left, wet_right: f32
	switch p.stages {
	case 1:
		wet_left = chorus_tap(&c.line[0], centre - sweep_sine)
		wet_right = chorus_tap(&c.line[1], centre - sweep_sine)
		chorus_feed(&c.line[0], wet_left * feedback)
		chorus_feed(&c.line[1], wet_right * feedback)
	case 4:
		left_near := chorus_tap(&c.line[0], centre - sweep_sine)
		left_far := chorus_tap(&c.line[0], centre + sweep_sine)
		right_near := chorus_tap(&c.line[1], centre - sweep_cosine)
		right_far := chorus_tap(&c.line[1], centre + sweep_cosine)
		wet_left = right_far * CHORUS_MIX_B + left_near * CHORUS_MIX_D + left_far * CHORUS_MIX_A + right_near * CHORUS_MIX_C
		wet_right = right_near * CHORUS_MIX_B + left_near * CHORUS_MIX_A + left_far * CHORUS_MIX_D + right_far * CHORUS_MIX_C
		chorus_feed(&c.line[0], left_near * feedback)
		chorus_feed(&c.line[1], right_near * feedback)
	case:
		wet_left = chorus_tap(&c.line[0], centre - sweep_sine)
		wet_right = chorus_tap(&c.line[1], centre - sweep_cosine)
		chorus_feed(&c.line[0], wet_left * feedback)
		chorus_feed(&c.line[1], wet_right * feedback)
	}

	return sanitize(left_in + wet_left), sanitize(right_in + wet_right)
}
