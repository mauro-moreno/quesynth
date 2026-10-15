package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// The amplitude envelope's decay and release, held to the numbers the reference
// produced. `s1probe arch envlaw` reads the reference's envelope as a whole
// number of 1/2048ths every 256 samples; the integers below are those readings
// for stored decay and release 64, whose length is 0.01 * 6000^(64/127) =
// 0.80159 s. An exponential 60 dB down in the old table's time misses every one
// of them by tens of percent, so none of these can pass by being close to it.
// The engine does not floor to 1/2048ths, so a reading E is matched by a level
// in [E - 1, E + 2) of them.

amp_length :: proc(stored: int) -> f32 {
	return f32(0.01 * math.pow(f64(6000), f64(stored) / 127))
}

expect_ticks :: proc(t: ^testing.T, e: ^dsp.Envelope, first_sample: int, ticks: []int, readings: []int, what: string) {
	done := 0
	for tick, i in ticks {
		target := tick * 256 - first_sample
		for done < target {
			dsp.envelope_process(e)
			done += 1
		}
		level := dsp.envelope_process(e) * 2048
		done += 1
		want := f32(readings[i])
		testing.expectf(t, level >= want - 1 && level < want + 2, "%v: tick %v reads %v/2048 in the reference, %v here", what, tick, readings[i], level)
	}
}

@(test)
test_amp_decay_matches_the_references_measured_ticks :: proc(t: ^testing.T) {
	// Attack 0 is 0.0005 s, 24 samples; the decay runs from there.
	e: dsp.Envelope
	dsp.envelope_set_fade(&e, 0.0005, amp_length(64), 0, 0.1, SR)
	dsp.envelope_gate_on(&e, true)
	expect_ticks(t, &e, 0, []int{20, 40, 60, 75, 90, 100, 110}, []int{615, 179, 50, 19, 6, 3, 1}, "decay to 0")
}

@(test)
test_amp_decay_settles_on_the_sustain_by_the_same_curve :: proc(t: ^testing.T) {
	// Sustain 496/2048, which is what the reference's stored 64 settles at.
	e: dsp.Envelope
	dsp.envelope_set_fade(&e, 0.0005, amp_length(64), 496.0 / 2048, 0.1, SR)
	dsp.envelope_gate_on(&e, true)
	expect_ticks(t, &e, 0, []int{20, 40, 80, 100, 140, 160}, []int{962, 632, 506, 498, 496, 496}, "decay to 496/2048")
}

@(test)
test_amp_release_scales_the_curve_by_the_level_it_started_from :: proc(t: ^testing.T) {
	// Released from 304/2048 and from 528/2048, as the reference was; the note
	// sits on a sustain of that level after a one-sample decay.
	starts := []int{304, 528}
	readings := [2][]int{{286, 239, 115, 43, 5}, {497, 415, 201, 75, 10}}
	for start, which in starts {
		e: dsp.Envelope
		dsp.envelope_set_fade(&e, 0, 0, f32(start) / 2048, amp_length(64), SR)
		dsp.envelope_gate_on(&e, true)
		for _ in 0 ..< 4800 {dsp.envelope_process(&e)}
		testing.expect_value(t, e.stage, dsp.Envelope_Stage.Sustain)
		dsp.envelope_gate_off(&e)
		// The first call after a note-off is 1/N of the way through the release.
		done := 0
		for tick, i in ([]int{1, 4, 16, 32, 64}) {
			for done < tick * 256 {
				dsp.envelope_process(&e)
				done += 1
			}
			level := e.value * 2048
			want := f32(readings[which][i])
			testing.expectf(t, level >= want - 1 && level < want + 2,
				"release from %v/2048: tick %v reads %v/2048 in the reference, %v here", start, tick, readings[which][i], level)
		}
	}
}

@(test)
test_amp_fade_segments_end_exactly_at_their_length :: proc(t: ^testing.T) {
	length := amp_length(64)
	samples := int(length * SR)

	// A decay from full level to a sustain of a half arrives on it, exactly,
	// when its length is up, and not before.
	e: dsp.Envelope
	dsp.envelope_set_fade(&e, 0.0005, length, 0.5, length, SR)
	dsp.envelope_gate_on(&e, true)
	for _ in 0 ..< 24 + int(0.95 * f32(samples)) {dsp.envelope_process(&e)}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Decay)
	testing.expectf(t, e.value > 0.5, "the decay had already reached the sustain: %v", e.value)
	for _ in 0 ..< int(0.05 * f32(samples)) + 4 {dsp.envelope_process(&e)}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Sustain)
	testing.expect_value(t, e.value, 0.5)

	// A release from that level is still sounding at half its length and is
	// finished by its end.
	dsp.envelope_gate_off(&e)
	for _ in 0 ..< samples / 2 {dsp.envelope_process(&e)}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Release)
	testing.expect(t, e.value > 0.001, "the release was already silent at half its length")
	for _ in 0 ..< samples / 2 + 4 {dsp.envelope_process(&e)}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Idle)
	testing.expect_value(t, e.value, 0.0)
}

@(test)
test_a_second_note_off_does_not_restart_the_release :: proc(t: ^testing.T) {
	e: dsp.Envelope
	dsp.envelope_set_fade(&e, 0, 0, 1, amp_length(64), SR)
	dsp.envelope_gate_on(&e, true)
	for _ in 0 ..< 100 {dsp.envelope_process(&e)}
	dsp.envelope_gate_off(&e)
	for _ in 0 ..< 10000 {dsp.envelope_process(&e)}
	before := e.value
	dsp.envelope_gate_off(&e)
	after := dsp.envelope_process(&e)
	testing.expectf(t, after < before, "a second note-off lifted the release from %v to %v", before, after)
}

@(test)
test_amp_decay_and_release_lengths_follow_the_measured_law :: proc(t: ^testing.T) {
	p := default_patch()
	for stored in ([]int{0, 64, 127}) {
		p.values[26] = stored
		p.values[28] = stored
		bound := engine.bind_patch(p)
		want := amp_length(stored)
		testing.expectf(t, abs(bound.amp_decay - want) <= 1.0e-6 * want, "decay %v gave %v s, want %v", stored, bound.amp_decay, want)
		testing.expectf(t, abs(bound.amp_release - want) <= 1.0e-6 * want, "release %v gave %v s, want %v", stored, bound.amp_release, want)
	}
	// The filter and modulation envelopes follow the same law, read from the cutoff's
	// and the pitch's own traces (`s1probe arch filterenv`, `arch modenv`).
	p.values[13] = 90
	p.values[16] = 64
	p.values[18] = 64
	bound := engine.bind_patch(p)
	testing.expect_value(t, bound.filter_decay, amp_length(64))
	testing.expect_value(t, bound.filter_release, amp_length(64))
	testing.expect_value(t, bound.mod_env_decay, amp_length(90))
}

// The modulation envelope on oscillator 2's pitch reaches 60 semitones at full amount
// and follows the fade law: predicted from the attack and decay lengths alone, the
// reference reads 28.97 against 28.5 at 150 ms and 5.59 against 5.59 at 1 s for an
// amount of 96, attack 64, decay 90.
@(test)
test_modulation_envelope_depth_is_sixty_semitones :: proc(t: ^testing.T) {
	e: dsp.Envelope
	dsp.envelope_set_fade(&e, 0.1235, 4.75, 0, 4.75, 48000)
	dsp.envelope_gate_on(&e, true)
	level: f32
	for _ in 0 ..< 7200 {level = dsp.envelope_process(&e)} // 150 ms
	pitch := engine.MOD_ENV_PITCH_SEMITONES * 0.5 * level
	testing.expectf(t, abs(pitch - 28.5) < 0.6, "pitch at 150 ms: %v semitones, want about 28.5", pitch)
	for _ in 0 ..< 40800 {level = dsp.envelope_process(&e)} // 1 s
	pitch = engine.MOD_ENV_PITCH_SEMITONES * 0.5 * level
	testing.expectf(t, abs(pitch - 5.59) < 0.15, "pitch at 1 s: %v semitones, want 5.59", pitch)
}

// The modulation envelope's pulse width is a share of the way to the end it heads for,
// not an offset. Each row is a reference reading: the static knob setting (of 127, duty
// = setting / 254) that cancels against the modulated render, for a base setting and an
// amount of the envelope at its peak (0.976 of full over the measured window). The
// readings are whole steps of a knob and the engine's own are one step high on positive
// amounts and one low on negative, so the tolerance is two steps.
@(test)
test_modulation_envelope_pulse_width_is_a_share_of_the_room_left :: proc(t: ^testing.T) {
	rows := [?][3]f32 {
		{32, 72, 58}, {32, 76, 72}, {32, 84, 98}, {32, 88, 112},
		{64, 72, 86}, {64, 80, 110},
		{96, 56, 85}, {96, 48, 73}, {96, 32, 50},
		{64, 56, 56}, {64, 48, 49}, {64, 40, 41}, {64, 16, 18},
	}
	for row in rows {
		duty := row[0] / 254.0
		amount := (row[1] - 64.0) / 64.0 * 0.976
		got := engine.modulated_pulse_width(duty, amount) * 254.0
		testing.expectf(t, abs(got - row[2]) <= 2.0, "base %v amount %v: the engine reaches %v, the reference %v", row[0], row[1], got, row[2])
	}
	testing.expect_value(t, engine.modulated_pulse_width(0.25, 0), f32(0.25))
}

// An envelope moved by `envelope_advance` is at every step the one moved by
// `envelope_process`: the same stage, progress and level, through decays cut
// short by a key release, legato and fresh restarts, edits of the sustain and the
// times in the middle of a decay (one followed at once by a release), lookaheads
// and resets.
@(test)
test_envelope_advance_keeps_what_process_would :: proc(t: ^testing.T) {
	eager, lazy: dsp.Envelope
	set :: proc(e: ^dsp.Envelope, decay, sustain, release: f32) {
		dsp.envelope_set_fade(e, 0.002, decay, sustain, release, SR)
	}
	set(&eager, 0.05, 0.3, 0.02)
	set(&lazy, 0.05, 0.3, 0.02)
	dsp.envelope_gate_on(&eager, true)
	dsp.envelope_gate_on(&lazy, true)
	seed: u32 = 11
	next :: proc(seed: ^u32, below: int) -> int {
		seed^ = seed^ * 1664525 + 1013904223
		return int(seed^ >> 8) % below
	}
	decaying := 0
	for step in 0 ..< 60000 {
		switch next(&seed, 4000) {
		case 0:
			dsp.envelope_gate_off(&eager)
			dsp.envelope_gate_off(&lazy)
		case 1, 2:
			retrigger := next(&seed, 2) == 0
			dsp.envelope_gate_on(&eager, retrigger)
			dsp.envelope_gate_on(&lazy, retrigger)
		case 3, 4, 5:
			decay := f32(next(&seed, 100) + 1) * 0.001
			sustain := f32(next(&seed, 128)) / 127
			set(&eager, decay, sustain, 0.03)
			set(&lazy, decay, sustain, 0.03)
		case 6:
			ahead := next(&seed, 300)
			testing.expect_value(t, dsp.envelope_value_ahead(&lazy, ahead), dsp.envelope_value_ahead(&eager, ahead))
		case 7:
			dsp.envelope_reset(&eager)
			dsp.envelope_reset(&lazy)
		case 10:
			// A reset and a legato start between the same two samples start from zero.
			dsp.envelope_reset(&eager)
			dsp.envelope_reset(&lazy)
			dsp.envelope_gate_on(&eager, false)
			dsp.envelope_gate_on(&lazy, false)
		case 8, 9:
			// An edit and a key release between the same two samples: the release
			// starts from the level the old settings had reached.
			sustain := f32(next(&seed, 128)) / 127
			set(&eager, 0.04, sustain, 0.03)
			set(&lazy, 0.04, sustain, 0.03)
			dsp.envelope_gate_off(&eager)
			dsp.envelope_gate_off(&lazy)
		}
		if eager.stage == .Decay {
			decaying += 1
		}
		dsp.envelope_process(&eager)
		dsp.envelope_advance(&lazy)
		if next(&seed, 50) != 0 {
			continue
		}
		level := dsp.envelope_level(&lazy)
		same :=
			lazy.stage == eager.stage &&
			lazy.progress == eager.progress &&
			transmute(u32)level == transmute(u32)eager.value
		if !same {
			testing.expectf(t, false, "step %v: advanced %v %v %v, processed %v %v %v",
				step, lazy.stage, lazy.progress, level, eager.stage, eager.progress, eager.value)
			return
		}
	}
	testing.expectf(t, decaying > 10000, "only %v steps were in a decay", decaying)
}
