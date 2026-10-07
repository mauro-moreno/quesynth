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
	// The filter and modulation envelopes have not been read this way.
	p.values[16] = 64
	p.values[18] = 64
	bound := engine.bind_patch(p)
	testing.expect_value(t, bound.filter_decay, engine.ENVELOPE_DECAY_SECONDS[64])
	testing.expect_value(t, bound.filter_release, engine.ENVELOPE_RELEASE_SECONDS[64])
}
