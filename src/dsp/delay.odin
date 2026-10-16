package dsp

// The tempo-synced stereo delay.
//
// Almost every parameter here came out of the reference's own display strings
// rather than being chosen, which is unusual for this project: parameter 35's
// twenty states spell out musical divisions ("(16)+(32)" is a dotted sixteenth,
// "/3" is a division by three and not a musician's triplet -- the reference was
// swept to settle that, see engine.delay_display_beats), parameter 83 reads out
// the left and right delay times in milliseconds directly, and parameter 37 is
// a plain percentage. The binding layer parses those, so the numbers below
// arrive already in beats, milliseconds and fractions.
//
// What is still chosen is named at its use site: the feedback curve and the
// tone control's corner frequencies. The three delay types were measured with
// a short transient against the reference.

Delay_Mode :: enum u8 {
	Stereo,
	Cross,
	Ping_Pong,
}

Delay_Params :: struct {
	// Delay time per channel, in samples. The binding computes these from the
	// division table, the tempo and the left/right spread.
	left_samples:  f32,
	right_samples: f32,
	// 0..1. How much of each channel's own output returns to its input.
	feedback:      f32,
	// 0..1. The gains on the dry input and on the echo. They are independent, not a
	// crossfade: at the middle of parameter 37 both are at one.
	dry_gain:      f32,
	wet_gain:      f32,
	// Darkens the repeats one way and thins them the other; off at the centre.
	tone:          Tone_Setting,
	mode:          Delay_Mode,
}

Delay :: struct {
	line: [2]Delay_Line,
	// The tone control, per channel, on everything that comes out of a line:
	// the echo heard and the signal fed back. Shared with the equaliser: the
	// manual describes parameter 98 here and parameter 60 there in the same
	// words, so it is the same control and lives in one place.
	tone: [2]Tone,
	tap:  [2]Delay_Tap,
}

delay_init :: proc "contextless" (d: ^Delay, left, right: []f32) {
	delay_line_init(&d.line[0], left)
	delay_line_init(&d.line[1], right)
	tone_reset(&d.tone[0])
	tone_reset(&d.tone[1])
}

delay_reset :: proc "contextless" (d: ^Delay) {
	delay_line_clear(&d.line[0])
	delay_line_clear(&d.line[1])
	tone_reset(&d.tone[0])
	tone_reset(&d.tone[1])
}

// Whether the delay holds nothing at all: both lines and both tone sections at
// zero. Fed zero, such a delay outputs zero and writes zero back.
delay_is_silent :: proc "contextless" (d: ^Delay) -> bool {
	return delay_line_is_silent(&d.line[0]) && delay_line_is_silent(&d.line[1]) && tone_is_silent(&d.tone[0]) && tone_is_silent(&d.tone[1])
}

// One-pole coefficient for a corner at `hz`.
one_pole_coef :: proc "contextless" (hz, sample_rate: f32) -> f32 {
	if sample_rate <= 0 {
		return 1
	}
	// 1 - exp(-2*pi*f/fs), approximated by the linear term, which is accurate
	// well below Nyquist and cannot go unstable above it once clamped.
	c := TAU * clamp32(hz, 1.0, sample_rate * 0.45) / sample_rate
	return clamp32(c, 0.0, 1.0)
}

// Process one stereo sample. Returns the mix of dry input and delayed output.
delay_process :: proc "contextless" (
	d: ^Delay,
	left_in, right_in: f32,
	p: ^Delay_Params,
	sample_rate: f32,
) -> (
	left, right: f32,
) {
	dry := clamp32(p.dry_gain, 0, 1)
	wet := clamp32(p.wet_gain, 0, 1)
	// Nothing to do, but the lines still have to run: a patch that turns the
	// delay up mid-note should not hear whatever was left in the buffer from
	// before.
	feedback := clamp32(p.feedback, 0.0, 1.0)

	delayed_left := delay_line_read_tap(&d.line[0], &d.tap[0], p.left_samples)
	delayed_right := delay_line_read_tap(&d.line[1], &d.tap[1], p.right_samples)

	shaped_left := tone_process(&d.tone[0], delayed_left, p.tone, sample_rate)
	shaped_right := tone_process(&d.tone[1], delayed_right, p.tone, sample_rate)

	// Normal stereo keeps two independent echoes. Cross preserves the stereo
	// input but swaps the feedback paths. Ping-pong folds the input to mono into
	// the left line only, then uses the same cross feedback: the first repeat is
	// left, the second right, and they alternate from there. The fold is the
	// average, not the sum: a source in one channel only comes back at half its level
	// and a centred one at its own. Feedback is applied once per complete left-right
	// round trip: each pair of echoes has the same level.
	switch p.mode {
	case .Cross:
		delay_line_write(&d.line[0], left_in + shaped_right * feedback)
		delay_line_write(&d.line[1], right_in + shaped_left * feedback)
	case .Ping_Pong:
		delay_line_write(&d.line[0], (left_in + right_in) * 0.5 + shaped_right * feedback)
		delay_line_write(&d.line[1], shaped_left)
	case .Stereo:
		delay_line_write(&d.line[0], left_in + shaped_left * feedback)
		delay_line_write(&d.line[1], right_in + shaped_right * feedback)
	}

	// The echo heard is the shaped one, the first repeat included. With
	// feedback at zero, `s1probe behavior delaytone` reads the reference's
	// only echo 33.6 dB down at 6.4-12.8 kHz with the tone fully dark and
	// 32.4 dB down at 100-400 Hz fully bright, against the same echo at the
	// centre. This engine used to output the unshaped read, so the first echo
	// came out flat at every tone and only the repeats were coloured. At the
	// centre the tone is an identity and nothing changes.
	left = left_in * dry + shaped_left * wet
	right = right_in * dry + shaped_right * wet
	return sanitize(left), sanitize(right)
}

// One-pole coefficient for a time constant rather than a corner.
//
// Used by the compressor, whose two documented controls are an attack *time* and
// a depth, so the natural expression is seconds. `seconds` is the time to reach
// roughly 63% of a step.
one_pole_coef_time :: proc "contextless" (seconds, sample_rate: f32) -> f32 {
	if sample_rate <= 0 || seconds <= 0 {
		return 1
	}
	samples := seconds * sample_rate
	if samples < 1 {
		return 1
	}
	return clamp32(1.0 / samples, 0.0, 1.0)
}
