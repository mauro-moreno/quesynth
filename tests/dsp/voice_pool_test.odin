package dsp_tests

import "core:math/bits"
import "core:testing"

import "../../src/engine"

// The layers each of three notes ends with, after all three have been pressed and
// held. `s1probe arch voices`, in-phase unison, notes 60, 72 and 84: the reference
// counts layers against polyphony and takes a voice from the oldest note's lowest
// layer first.
layers_after_three_notes :: proc(t: ^testing.T, polyphony, unison: int) -> [3]int {
	p := default_patch()
	p.values[73] = unison > 1 ? 1 : 0 // one layer is unison off
	p.values[94] = polyphony
	p.values[93] = unison
	bound := engine.bind_patch(p)
	testing.expect_value(t, bound.polyphony, polyphony)
	testing.expect_value(t, bound.unison_voices, unison)
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	notes := [3]int{60, 72, 84}
	left := make([]f32, 4800)
	right := make([]f32, 4800)
	defer delete(left)
	defer delete(right)
	for note in notes {
		engine.engine_note_on(&e, note, 1.0)
		engine.engine_process(&e, left, right)
	}

	result: [3]int
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if !v.active {
			continue
		}
		for note, index in notes {
			if v.note == note {
				result[index] += int(bits.count_ones(v.live_layers))
			}
		}
	}
	return result
}

@(test)
test_pool_is_counted_in_layers :: proc(t: ^testing.T) {
	cases := [?]struct {
		polyphony, unison: int,
		want:              [3]int,
	}{
		{3, 2, {0, 1, 2}},
		{4, 2, {0, 2, 2}},
		{5, 2, {1, 2, 2}},
		{6, 2, {2, 2, 2}},
		{2, 2, {0, 0, 2}},
		{4, 4, {0, 0, 4}},
		{7, 4, {0, 3, 4}},
	}
	for c in cases {
		got := layers_after_three_notes(t, c.polyphony, c.unison)
		testing.expectf(t, got == c.want, "poly %v x unison %v: %v layers, reference %v", c.polyphony, c.unison, got, c.want)
	}
}

// With a single voice and two layers a note keeps only the last layer: each layer
// past the pool's size takes the voice of the one before it.
@(test)
test_a_note_wider_than_the_pool_keeps_its_last_layers :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[73] = 1 // unison on
	p.values[94] = 1
	p.values[93] = 2
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	engine.engine_note_on(&e, 60, 1.0)
	voice := &e.voices[0]
	testing.expect_value(t, voice.live_layers, u32(0b10))
}

// A single layer per note behaves as a note per voice always did: the pool of N
// holds N notes and the N+1th takes the oldest.
@(test)
test_one_layer_per_note_is_one_voice_per_note :: proc(t: ^testing.T) {
	got := layers_after_three_notes(t, 2, 1)
	testing.expect_value(t, got, [3]int{0, 1, 1})
	got = layers_after_three_notes(t, 3, 1)
	testing.expect_value(t, got, [3]int{1, 1, 1})
}

// Which notes are still sounding after a sequence of presses and releases, with
// one voice per note.
notes_sounding :: proc(polyphony: int, script: []int) -> [dynamic]int {
	p := default_patch()
	p.values[94] = polyphony
	p.values[28] = 127 // a release long enough to outlast the script
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	left := make([]f32, 480)
	right := make([]f32, 480)
	defer delete(left)
	defer delete(right)
	// A positive entry presses that key, a negative one releases it.
	for step in script {
		if step > 0 {
			engine.engine_note_on(&e, step, 1.0)
		} else {
			engine.engine_note_off(&e, -step)
		}
		engine.engine_process(&e, left, right)
	}
	sounding: [dynamic]int
	for i in 0 ..< len(e.voices) {
		if e.voices[i].active {
			append(&sounding, e.voices[i].note)
		}
	}
	return sounding
}

contains :: proc(notes: [dynamic]int, note: int) -> bool {
	for n in notes {
		if n == note {return true}
	}
	return false
}

// A note in release is free as soon as the round-robin scan reaches its slot: the
// fifth note of four slots takes the released first note, not a held one.
@(test)
test_a_released_note_is_taken_before_a_held_one :: proc(t: ^testing.T) {
	sounding := notes_sounding(4, {60, 62, 64, 65, -60, 67})
	defer delete(sounding)
	testing.expect(t, !contains(sounding, 60), "the released note kept its voice")
	for held in ([]int{62, 64, 65, 67}) {
		testing.expectf(t, contains(sounding, held), "held note %v lost its voice", held)
	}
}

// With every slot held, the oldest is taken, and the scan carries on from there.
@(test)
test_with_every_slot_held_the_oldest_is_taken :: proc(t: ^testing.T) {
	sounding := notes_sounding(4, {60, 62, 64, 65, 67, 69})
	defer delete(sounding)
	testing.expect(t, !contains(sounding, 60) && !contains(sounding, 62), "the two oldest notes kept their voices")
	for held in ([]int{64, 65, 67, 69}) {
		testing.expectf(t, contains(sounding, held), "note %v lost its voice", held)
	}
}

// A released note nobody has needed the slot of yet keeps ringing.
@(test)
test_a_released_note_rings_on_while_slots_remain :: proc(t: ^testing.T) {
	sounding := notes_sounding(6, {60, -60, 62, 64})
	defer delete(sounding)
	testing.expect(t, contains(sounding, 60), "a release tail was cut with slots to spare")
}
