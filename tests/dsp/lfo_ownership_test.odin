package dsp_tests

import "core:testing"

import "../../src/dsp"
import "../../src/engine"

lfo_sync_engine :: proc(key_sync: bool) -> engine.Engine {
	p := default_patch()
	p.values[57] = 1 // LFO 1 on
	p.values[68] = key_sync ? 1 : 0
	p.values[43] = 60 // a rate where a cycle takes a good fraction of a second
	p.values[73] = 0
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	return e
}

render_samples :: proc(e: ^engine.Engine, n: int) {
	left := make([]f32, n)
	right := make([]f32, n)
	defer delete(left)
	defer delete(right)
	engine.engine_process(e, left, right)
}

// The two LFOs are shared by every voice, and a key-synced one restarts only when
// the key just pressed is the only one held. `s1probe arch lfophase`, poly 16 with
// note 60 at 0 s and note 72 at 0.5 s: the second note's first saw jump is on the
// first note's cycle (-0.252 turns from its own onset), not restarted.
@(test)
test_a_second_key_does_not_restart_a_synced_lfo :: proc(t: ^testing.T) {
	e := lfo_sync_engine(true)
	defer engine.engine_destroy(&e)

	engine.engine_note_on(&e, 60, 1.0)
	testing.expect_value(t, dsp.lfo_phase(&e.global_lfo[0]), f32(0))
	render_samples(&e, 12000)
	before := dsp.lfo_phase(&e.global_lfo[0])
	testing.expect(t, before > 0, "the LFO did not run while a key was held")

	engine.engine_note_on(&e, 72, 1.0)
	testing.expect_value(t, dsp.lfo_phase(&e.global_lfo[0]), before)
}

// With every key up, the next key is the only one held and restarts it, whatever
// is still sounding in release.
@(test)
test_a_lone_key_restarts_a_synced_lfo_even_over_a_release_tail :: proc(t: ^testing.T) {
	e := lfo_sync_engine(true)
	defer engine.engine_destroy(&e)

	engine.engine_note_on(&e, 60, 1.0)
	render_samples(&e, 12000)
	engine.engine_note_off(&e, 60)
	render_samples(&e, 100)
	testing.expect(t, dsp.lfo_phase(&e.global_lfo[0]) > 0, "the LFO did not run")

	engine.engine_note_on(&e, 64, 1.0)
	testing.expect_value(t, dsp.lfo_phase(&e.global_lfo[0]), f32(0))
}

// A free-running LFO is never restarted by a key.
@(test)
test_a_free_running_lfo_ignores_keys :: proc(t: ^testing.T) {
	e := lfo_sync_engine(false)
	defer engine.engine_destroy(&e)

	render_samples(&e, 12000)
	before := dsp.lfo_phase(&e.global_lfo[0])
	testing.expect(t, before > 0, "the LFO did not run")
	engine.engine_note_on(&e, 60, 1.0)
	testing.expect_value(t, dsp.lfo_phase(&e.global_lfo[0]), before)
}
