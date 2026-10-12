package dsp_tests

import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"

// The free-running rate is `1500^(s/127) / 12` Hz: 0.0833 Hz at the bottom and
// 125 Hz at the top. The reference's own sweep reads 2.49 Hz at stored 59, where
// the crossing-count table this replaces said 2.448.
@(test)
test_lfo_rate_is_the_exponential_of_the_stored_state :: proc(t: ^testing.T) {
	testing.expectf(t, abs(engine.lfo_rate_hz(0) - 1.0 / 12.0) < 1e-5, "got %v", engine.lfo_rate_hz(0))
	testing.expectf(t, abs(engine.lfo_rate_hz(127) - 125.0) < 0.01, "got %v", engine.lfo_rate_hz(127))
	testing.expectf(t, abs(engine.lfo_rate_hz(59) - 2.49) < 0.02, "got %v", engine.lfo_rate_hz(59))
	for s in 1 ..< 128 {
		ratio := engine.lfo_rate_hz(s) / engine.lfo_rate_hz(s - 1)
		testing.expectf(t, abs(ratio - math.pow(f32(1500), 1.0 / 127.0)) < 1e-3, "step %v ratio %v", s, ratio)
	}
}

// Tempo sync picks from thirty divisions, `(s * 30) >> 7`, in 24ths of a beat.
@(test)
test_lfo_tempo_sync_division_table :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.LFO_SYNC_TICKS[0], 1536)
	testing.expect_value(t, engine.LFO_SYNC_TICKS[29], 1)
	testing.expect_value(t, len(engine.LFO_SYNC_TICKS), 30)
	for i in 1 ..< 30 {
		testing.expectf(t, engine.LFO_SYNC_TICKS[i] < engine.LFO_SYNC_TICKS[i - 1], "entry %v is not shorter than the one before", i)
	}
	// Stored 127 is index 29, a twenty-fourth of a beat.
	p := default_patch()
	p.values[43] = 127
	p.values[67] = 1
	testing.expectf(t, abs(engine.bind_patch(p).lfo[0].sync_beats - 1.0 / 24.0) < 1e-6, "got %v", engine.bind_patch(p).lfo[0].sync_beats)
	p.values[43] = 0
	testing.expectf(t, abs(engine.bind_patch(p).lfo[0].sync_beats - 64.0) < 1e-4, "got %v", engine.bind_patch(p).lfo[0].sync_beats)
}

// The period is a whole number of samples, `sr / hz` truncated.
@(test)
test_lfo_period_is_a_whole_number_of_samples :: proc(t: ^testing.T) {
	l: dsp.Lfo
	dsp.lfo_init(&l, 1)
	rate := f32(2.49)
	dsp.lfo_set_frequency(&l, rate, SR)
	testing.expect_value(t, l.period, int(SR / rate))
	dsp.lfo_set_frequency(&l, 125.0, SR)
	testing.expect_value(t, l.period, 384)
}

// The output is refreshed on a grid from the start of each cycle, 64 samples for a
// slow LFO and 32 past 10 Hz, and held between. A saw makes the steps visible: it
// changes only at multiples of the grid.
@(test)
test_lfo_output_is_held_on_a_grid :: proc(t: ^testing.T) {
	for case_ in ([2][2]f32{{2.0, 64}, {20.0, 32}}) {
		l: dsp.Lfo
		dsp.lfo_init(&l, 1)
		l.shape = .Saw
		dsp.lfo_set_frequency(&l, case_[0], SR)
		testing.expect_value(t, l.grid, int(case_[1]))
		previous := dsp.lfo_process(&l)
		changes_at: [dynamic]int
		defer delete(changes_at)
		for _ in 1 ..< 2000 {
			v := dsp.lfo_process(&l)
			if v != previous {
				append(&changes_at, l.position - 1)
			}
			previous = v
		}
		testing.expect(t, len(changes_at) > 5, "the saw did not move")
		for position in changes_at {
			testing.expectf(t, position % int(case_[1]) == 0, "a change at sample %v is off the %v grid", position, int(case_[1]))
		}
	}
}

// Smoothed random ramps between its last two random values across a cycle, where
// the one-pole it replaces chased the target and never arrived.
@(test)
test_smoothed_random_ramps_linearly_across_a_cycle :: proc(t: ^testing.T) {
	l: dsp.Lfo
	dsp.lfo_init(&l, 7)
	l.shape = .Random_Smooth
	dsp.lfo_set_frequency(&l, 5.0, SR)
	// Run one cycle so previous and target are both random draws.
	for _ in 0 ..< l.period {
		dsp.lfo_process(&l)
	}
	start := dsp.lfo_process(&l)
	for _ in 0 ..< l.period / 2 {
		dsp.lfo_process(&l)
	}
	middle := dsp.lfo_process(&l)
	for _ in 0 ..< l.period / 2 - 2 {
		dsp.lfo_process(&l)
	}
	end := dsp.lfo_process(&l)
	testing.expectf(t, abs(middle - (start + end) * 0.5) < 0.1, "start %v middle %v end %v", start, middle, end)
}
