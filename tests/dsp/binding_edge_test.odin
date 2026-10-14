package dsp_tests

import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// What the engine plays for a stored integer outside a parameter's displays, for
// the parameters whose displays do not start at zero. Each expectation is one the
// reference's own renders agree with (one note, only that parameter changed; see
// `display_state_below` in src/patch/value.odin): a value below the range sounds as
// the first state, above it as the last, and in a gap as the state below.
@(test)
test_oscillator_2_waveform_below_its_range_is_its_first :: proc(t: ^testing.T) {
	for stored in ([]int{-1, 0, 1}) {
		p := default_patch()
		p.values[1] = stored
		testing.expectf(t, engine.bind_patch(p).osc2_shape == .Saw, "stored %v sounded as %v", stored, engine.bind_patch(p).osc2_shape)
	}
	for stored in ([]int{4, 5, 9}) {
		p := default_patch()
		p.values[1] = stored
		testing.expectf(t, engine.bind_patch(p).osc2_shape == .Noise, "stored %v sounded as %v", stored, engine.bind_patch(p).osc2_shape)
	}
}

@(test)
test_unison_voices_and_polyphony_clamp_into_their_displays :: proc(t: ^testing.T) {
	for stored in ([]int{-1, 0, 1, 2}) {
		p := default_patch()
		p.values[73] = 1 // unison on, or the voice count is one
		p.values[93] = stored
		testing.expect_value(t, engine.bind_patch(p).unison_voices, 2)
	}
	for stored in ([]int{8, 9, 12}) {
		p := default_patch()
		p.values[73] = 1 // unison on, or the voice count is one
		p.values[93] = stored
		testing.expect_value(t, engine.bind_patch(p).unison_voices, 8)
	}
	for stored in ([]int{-1, 0, 1}) {
		p := default_patch()
		p.values[94] = stored
		testing.expect_value(t, engine.bind_patch(p).polyphony, 1)
	}
}

@(test)
test_lfo_destination_and_chorus_type_clamp_into_their_displays :: proc(t: ^testing.T) {
	for index in ([]int{41, 46}) {
		first, last := 0, 0
		p := default_patch()
		p.values[index] = 1
		first = int(engine.bind_patch(p).lfo[index == 41 ? 0 : 1].destination)
		p.values[index] = 7
		last = int(engine.bind_patch(p).lfo[index == 41 ? 0 : 1].destination)
		for stored in ([]int{-1, 0}) {
			p.values[index] = stored
			testing.expect_value(t, int(engine.bind_patch(p).lfo[index == 41 ? 0 : 1].destination), first)
		}
		for stored in ([]int{8, 12}) {
			p.values[index] = stored
			testing.expect_value(t, int(engine.bind_patch(p).lfo[index == 41 ? 0 : 1].destination), last)
		}
	}

	// Chorus type 3 is not a display (1, 2 and 4 are); it sounds as 2.
	p := default_patch()
	p.values[64] = 2
	two := engine.bind_patch(p).chorus_stages
	p.values[64] = 3
	testing.expect_value(t, engine.bind_patch(p).chorus_stages, two)
	p.values[64] = 0
	zero := engine.bind_patch(p).chorus_stages
	p.values[64] = 1
	testing.expect_value(t, engine.bind_patch(p).chorus_stages, zero)
}

// Stored 6 and above on an LFO type sounds as display 5 (a sine), not as the last
// state (a smoothed random): the reference's renders for 5, 6, 7, 9 and 12 are one.
@(test)
test_lfo_type_past_its_range_is_a_sine :: proc(t: ^testing.T) {
	for stored in ([]int{5, 6, 7, 9, 12}) {
		p := default_patch()
		p.values[42] = stored
		p.values[47] = stored
		b := engine.bind_patch(p)
		testing.expectf(t, b.lfo[0].shape == .Sine && b.lfo[1].shape == .Sine, "stored %v: %v / %v", stored, b.lfo[0].shape, b.lfo[1].shape)
	}
	for stored in ([]int{-1, 0}) {
		p := default_patch()
		p.values[42] = stored
		testing.expect_value(t, engine.bind_patch(p).lfo[0].shape, dsp.Lfo_Waveform.Saw)
	}
}
