package dsp_tests

import "core:math"
import "core:testing"

import "../../src/engine"

chunk_engine :: proc() -> engine.Engine {
	p := default_patch()
	p.values[25] = 0 // instant attack
	p.values[26] = 64 // a long decay
	p.values[27] = 0 // down to nothing
	p.values[65] = 0 // delay off
	p.values[66] = 0 // chorus off
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	return e
}

render_frames :: proc(e: ^engine.Engine, n: int) {
	left := make([]f32, n)
	right := make([]f32, n)
	defer delete(left)
	defer delete(right)
	engine.engine_process(e, left, right)
}

// The amplitude envelope is a whole number of 1/2048ths at the end of every render
// chunk, joined by straight lines. The first chunk of a note is exempt: it follows
// the envelope exactly, since the reference reaches full level in 3.3 ms and a
// ramp across all 256 samples would take 5.3.
@(test)
test_amplitude_envelope_ends_a_chunk_on_a_whole_step :: proc(t: ^testing.T) {
	e := chunk_engine()
	defer engine.engine_destroy(&e)
	engine.engine_note_on(&e, 60, 1.0)
	render_frames(&e, 4000)
	v := &e.voices[0]
	testing.expect(t, v.active, "the note is not sounding")
	steps := f64(v.amp_now) * 2048
	testing.expectf(t, abs(steps - math.round(steps)) < 1e-3, "chunk end at %v steps of 1/2048", steps)

	// And a call of another length ends its own chunk the same way.
	render_frames(&e, 777)
	steps = f64(v.amp_now) * 2048
	testing.expectf(t, abs(steps - math.round(steps)) < 1e-3, "chunk end at %v steps of 1/2048", steps)
}

@(test)
test_first_chunk_of_a_note_follows_the_envelope_exactly :: proc(t: ^testing.T) {
	e := chunk_engine()
	defer engine.engine_destroy(&e)
	engine.engine_note_on(&e, 60, 1.0)
	render_frames(&e, 200)
	v := &e.voices[0]
	testing.expect_value(t, v.amp_now, v.amp_env.value)
}

// The envelope's own state is not touched by the lookahead, so a note-off between
// calls finds it where the ramp had got to and the release starts from there.
@(test)
test_note_off_between_calls_releases_from_the_current_level :: proc(t: ^testing.T) {
	e := chunk_engine()
	defer engine.engine_destroy(&e)
	engine.engine_note_on(&e, 60, 1.0)
	render_frames(&e, 3000)
	v := &e.voices[0]
	before := v.amp_env.value
	engine.engine_note_off(&e, 60)
	testing.expect_value(t, v.amp_env.value, before)
	render_frames(&e, 4)
	testing.expect(t, v.amp_env.value <= before, "the release did not start from the level the note was at")
}
