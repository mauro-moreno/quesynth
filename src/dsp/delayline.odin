package dsp

// A fractional delay line.
//
// Layer 0 owns no memory, so the buffer belongs to the caller: the engine sizes
// it once at initialisation and hands it over. Nothing here allocates, and
// nothing here needs to know how long the buffer is beyond reading `len`.
//
// The read is linearly interpolated. That matters for the chorus rather than the
// delay: a chorus sweeps its tap continuously, and stepping the tap in whole
// samples turns a smooth sweep into a staircase whose steps are audible as a
// zipper on the pitch.
Delay_Line :: struct {
	buffer: []f32,
	// Where the next sample will be written.
	write:  int,
}

delay_line_init :: proc "contextless" (d: ^Delay_Line, buffer: []f32) {
	d.buffer = buffer
	d.write = 0
	delay_line_clear(d)
}

delay_line_clear :: proc "contextless" (d: ^Delay_Line) {
	for i in 0 ..< len(d.buffer) {
		d.buffer[i] = 0
	}
	d.write = 0
}

delay_line_write :: proc "contextless" (d: ^Delay_Line, value: f32) {
	if len(d.buffer) == 0 {
		return
	}
	d.buffer[d.write] = sanitize(value)
	d.write += 1
	if d.write >= len(d.buffer) {
		d.write = 0
	}
}

// Read `delay` samples back from the write head, interpolating between the two
// neighbouring samples.
//
// The delay is clamped into the buffer rather than wrapped: a delay longer than
// the line is a caller error, and silently wrapping it would produce a plausible
// but wrong echo instead of an obviously clamped one.
delay_line_read :: proc "contextless" (d: ^Delay_Line, delay: f32) -> f32 {
	n := len(d.buffer)
	if n == 0 {
		return 0
	}

	want := delay
	if !is_finite(want) {
		want = 0
	}
	// One sample of headroom at each end: the interpolation reads two samples,
	// and a zero delay would otherwise read the sample about to be overwritten.
	want = clamp32(want, 1.0, f32(n - 2))

	whole := int(want)
	frac := want - f32(whole)

	first := d.write - whole
	for first < 0 {
		first += n
	}
	second := first - 1
	if second < 0 {
		second += n
	}

	a := d.buffer[first]
	b := d.buffer[second]
	return lerp32(a, b, frac)
}
