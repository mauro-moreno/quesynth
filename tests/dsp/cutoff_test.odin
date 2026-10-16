package dsp_tests

import "core:math"
import "core:testing"

import "../../src/engine"
import "../../src/patch"

// The knob's position on the 1024-step axis: stored 127 is the top usable step,
// and the endpoints of the axis are 15 Hz and 16 kHz.
@(test)
test_filter_axis_endpoints :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.filter_knob_index(0), f32(0))
	testing.expect_value(t, engine.filter_knob_index(127), f32(1023))
	testing.expect_value(t, engine.filter_knob_index(64), f32(515))
	testing.expectf(t, abs(engine.filter_index_hz(0) - 15) < 1e-3, "got %v", engine.filter_index_hz(0))
	testing.expectf(t, abs(engine.filter_index_hz(1024) - 16000) < 1, "got %v", engine.filter_index_hz(1024))
}

// Tracking amount (1 + a)^((note - 48) / 12): half travel is log2(1.5) octaves
// per octave, not half of one.
@(test)
test_filter_tracking_amount_is_not_linear :: proc(t: ^testing.T) {
	knob := f32(400)
	for amount in ([?]f32{0.25, 0.504, 1.0}) {
		shift := engine.filter_track_shift(knob, amount, 60)
		octaves := math.log2(engine.filter_index_hz(knob + shift) / engine.filter_index_hz(knob))
		want := math.log2(1.0 + amount)
		testing.expectf(t, abs(octaves - want) < 0.01, "amount %v: %v octaves, want %v", amount, octaves, want)
	}
	testing.expect_value(t, engine.filter_track_shift(knob, 0, 90), f32(0))
}

// Tracking stops at the ends of the axis.
@(test)
test_filter_tracking_holds_at_the_ends :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.filter_track_shift(1000, 1.0, 120), f32(24))
	testing.expect_value(t, engine.filter_track_shift(20, 1.0, 0), f32(-20))
}

// A cutoff LFO takes a fraction of the travel left above the position, so the
// same depth opens a low knob by many steps and a high one by few, and full depth
// reaches the top from anywhere. Reference, noise through a 12 dB low pass with a
// square LFO: bases 32 and 88, depth 32/127 -> 23.8 and 9.8 states, against
// depth/127 * (127 - base) = 23.9 and 9.8.
@(test)
test_filter_lfo_depth_is_a_fraction_of_the_room :: proc(t: ^testing.T) {
	depth := f32(32) / 127
	for base_state in ([?]f32{32, 56, 88}) {
		base := engine.filter_knob_index(base_state)
		moved := engine.filter_modulate_index(base, depth * engine.FILTER_INDEX_STEPS)
		states := (moved - base) * 127 / engine.FILTER_INDEX_MAX
		want := depth * (127 - base_state)
		testing.expectf(t, abs(states - want) < 0.3, "base %v: opened %v states, want %v", base_state, states, want)
	}
	testing.expect_value(t, engine.filter_modulate_index(10, engine.FILTER_INDEX_STEPS), engine.FILTER_INDEX_MAX)
	testing.expect_value(t, engine.filter_modulate_index(700, 0), f32(700))
}

// The envelope amount is held to the room each side of the knob before the level
// is applied.
@(test)
test_filter_envelope_amount_is_held_to_the_axis :: proc(t: ^testing.T) {
	// Cutoff 44 with amount 31 asks for -64 states: the endpoint stops at the
	// bottom, and a sustain of 73/127 takes that fraction of the surviving trip.
	base := engine.filter_knob_index(44)
	asked := f32(-64) * 8
	shift := engine.filter_env_shift(base, asked, 73.0 / 127.0)
	testing.expectf(t, abs(shift - (-base * 73.0 / 127.0)) < 1e-3, "got %v", shift)
	testing.expect_value(t, engine.filter_env_shift(base, 100000, 1), engine.FILTER_INDEX_STEPS - base)
	testing.expect_value(t, engine.filter_env_shift(base, 500, 0), f32(0))
}

// An edit takes fifty milliseconds and is linear: the same time for a small step
// as for a large one, from the position the edit found.
@(test)
test_filter_ramp_is_fifty_milliseconds_and_linear :: proc(t: ^testing.T) {
	length := engine.cutoff_ramp_samples(SR)
	testing.expect_value(t, length, 2400)

	for step in ([?]f32{40, 400}) {
		r: engine.Cutoff_Ramp
		engine.cutoff_ramp_step(&r, 300, 10, 0, 0, length)
		for _ in 0 ..< 100 {
			testing.expect_value(t, engine.cutoff_ramp_step(&r, 300, 10, 0, 0, length), f32(300))
		}
		target := f32(300) + step
		first := engine.cutoff_ramp_step(&r, target, 11, 0, 0, length)
		testing.expect_value(t, first, f32(300))
		reached_half, reached_end := -1, -1
		position := first
		for i in 1 ..< length + 10 {
			position = engine.cutoff_ramp_step(&r, target, 11, 0, 0, length)
			if reached_half < 0 && position >= 300 + step / 2 { reached_half = i }
			if reached_end < 0 && position >= target { reached_end = i }
		}
		testing.expectf(t, abs(f32(reached_half) - f32(length) / 2) < 30, "half at %v of %v", reached_half, length)
		testing.expectf(t, abs(reached_end - length) < 3, "end at %v of %v", reached_end, length)
		testing.expect_value(t, position, target)
	}
}

// A note starts at its target.
@(test)
test_filter_ramp_does_not_glide_a_fresh_note :: proc(t: ^testing.T) {
	r: engine.Cutoff_Ramp
	testing.expect_value(t, engine.cutoff_ramp_step(&r, 123, 5, 0, 0, 2400), f32(123))
	engine.cutoff_ramp_reset(&r)
	testing.expect_value(t, engine.cutoff_ramp_step(&r, 900, 99, 0, 0, 2400), f32(900))
}

// Something still moving (an envelope or an LFO) is followed during the ramp, not
// frozen at the value it had when the edit arrived.
@(test)
test_filter_ramp_follows_a_moving_target :: proc(t: ^testing.T) {
	length := 2400
	r: engine.Cutoff_Ramp
	engine.cutoff_ramp_step(&r, 100, 1, 0, 0, length)
	engine.cutoff_ramp_step(&r, 100, 2, 0, 0, length)
	latest := f32(0)
	for i in 0 ..< length {
		target := f32(100) + f32(i) * 0.1
		latest = engine.cutoff_ramp_step(&r, target, 2, 0, 0, length)
	}
	testing.expectf(t, latest > 100, "the ramp did not follow its target: %v", latest)
	testing.expect_value(t, engine.cutoff_ramp_step(&r, 500, 2, 0, 0, length), f32(500))
}

// The corner a note started under these settings has.
fresh_corner :: proc(p: patch.Patch, note: int, bend: f32) -> f32 {
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	engine.engine_set_pitch_bend(&e, bend)
	render_frames(&e, 4800)
	engine.engine_note_on(&e, note, 1)
	render_frames(&e, 1)
	return e.voices[0].axis_hz_cache
}

// The corner follows a knob, tracking or bend edit made mid-note to where a note
// started under those settings has it, once the edit's ramp and the bend's slew
// are over. Each edit lands in its own block and is checked on its own, so a
// voice that kept the corner it derived before any one of them is caught.
@(test)
test_filter_corner_follows_mid_note_knob_tracking_and_bend_edits :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[21] = 63 // no filter envelope
	p.values[57] = 0 // LFO 1 off
	p.values[58] = 0 // LFO 2 off
	p.values[19] = 90
	p.values[22] = 0
	NOTE :: 72
	STAGE :: 4800

	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	testing.expect_value(t, e.params.filter_env_cutoff_states, f32(0))
	testing.expect(t, e.params.pitch_bend_range > 0, "bend does not move the note")
	engine.engine_note_on(&e, NOTE, 1)
	render_frames(&e, STAGE)
	testing.expect_value(t, e.voices[0].axis_hz_cache, fresh_corner(p, NOTE, 0))

	Edit :: struct {
		index, stored: int,
		bend:          f32,
	}
	bend: f32 = 0
	for edit in ([?]Edit{{19, 40, 0}, {22, 127, 0}, {-1, 0, 1}}) {
		before := e.voices[0].axis_hz_cache
		if edit.index >= 0 {
			engine.engine_set_stored(&e, edit.index, edit.stored)
			p.values[edit.index] = edit.stored
		} else {
			bend = edit.bend
			engine.engine_set_pitch_bend(&e, bend)
		}
		render_frames(&e, STAGE)
		want := fresh_corner(p, NOTE, bend)
		testing.expect(t, e.voices[0].active, "the note is not sounding")
		testing.expectf(t, before != want, "edit %v does not move the corner: %v", edit, before)
		testing.expectf(t, e.voices[0].axis_hz_cache == want, "after edit %v: corner %v, want %v", edit, e.voices[0].axis_hz_cache, want)
	}
}

// A voice that reads its settled cutoff position back plays exactly what one that works
// it out every sample does. Both engines get the same events one frame at a time, and
// the second has its held position thrown away before each frame, so it always takes the
// long way. The edits land after the envelopes have settled, since that is when the held
// position is in use, and each one is something the position is derived from.
//
// The filter envelope has no attack or decay and a sustain of full level, so a note that
// starts again on the same key and velocity begins on the very position the last one
// ended on. That is the one case where the held position and the note's reset ramp are
// both in play: the knob edit shortly after it must glide, because the new note's ramp
// was armed, and it only does if starting a note clears the held position.
@(test)
test_held_cutoff_position_plays_what_working_it_out_does :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[15] = 0 // filter attack
	p.values[16] = 0 // filter decay
	p.values[17] = 127 // filter sustain: full level
	p.values[26] = 0 // amp decay
	p.values[28] = 0 // amp release
	p.values[21] = 80 // filter envelope amount: 64 is none, so this opens the filter
	p.values[24] = 1 // filter velocity switch
	p.values[19] = 30
	p.values[57] = 1 // LFO 1 on the cutoff (stored 3; the default, 2, is pitch)
	p.values[41] = 3
	p.values[44] = 80
	p.values[43] = 110

	held, fresh: engine.Engine
	engine.engine_load_patch(&held, p, SR)
	engine.engine_load_patch(&fresh, p, SR)
	defer engine.engine_destroy(&held)
	defer engine.engine_destroy(&fresh)

	Event :: struct {
		at:            int,
		index, stored: int,
		note:          int,
		bend:          f32,
	}
	NOTE_ON :: -1
	BEND :: -2
	NOTE_OFF :: -3
	events := [?]Event {
		{0, NOTE_ON, 0, 60, 0},
		{12000, 19, 20, 0, 0},
		{18000, 22, 70, 0, 0},
		{24000, 21, 92, 0, 0},
		{30000, 24, 0, 0, 0},
		{36000, BEND, 0, 0, 1},
		{42000, NOTE_ON, 0, 67, 0},
		{48000, 19, 45, 0, 0},
		{50000, NOTE_OFF, 0, 67, 0},
		{51000, 44, 0, 0, 0},
		{54000, NOTE_ON, 0, 60, 0},
		{54300, 19, 35, 0, 0},
	}
	next := 0
	hits := 0
	left, right: [2][1]f32
	for frame in 0 ..< 58000 {
		for next < len(events) && events[next].at == frame {
			ev := events[next]
			next += 1
			for e in ([?]^engine.Engine{&held, &fresh}) {
				switch ev.index {
				case NOTE_ON:
					engine.engine_note_on(e, ev.note, 0.8)
				case BEND:
					engine.engine_set_pitch_bend(e, ev.bend)
				case NOTE_OFF:
					engine.engine_note_off(e, ev.note)
				case:
					engine.engine_set_stored(e, ev.index, ev.stored)
				}
			}
		}
		for i in 0 ..< len(fresh.voices) {
			fresh.voices[i].cutoff_settled = false
		}
		for i in 0 ..< len(held.voices) {
			if held.voices[i].active && held.voices[i].cutoff_settled {
				hits += 1
			}
		}
		engine.engine_process(&held, left[0][:], right[0][:])
		engine.engine_process(&fresh, left[1][:], right[1][:])
		same := transmute(u32)left[0][0] == transmute(u32)left[1][0] &&
			transmute(u32)right[0][0] == transmute(u32)right[1][0]
		if !same {
			testing.expectf(t, false, "frame %v: held %v, worked out %v", frame, left[0][0], left[1][0])
			return
		}
	}
	testing.expectf(t, hits > 20000, "the held position was used on only %v voice-samples", hits)
}
