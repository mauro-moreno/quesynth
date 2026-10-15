package dsp_tests

import "core:testing"

import "../../src/dsp"
import "../../src/engine"
import "../../src/patch"

// A line reads as silent only while every sample in it is zero, through writes
// of every kind of value, feedback added to the newest sample, and clears; and a
// buffer's length of zeros written makes it read as silent again.
@(test)
test_delay_line_knows_when_it_holds_nothing :: proc(t: ^testing.T) {
	buffer := make([]f32, 97)
	defer delete(buffer)
	line: dsp.Delay_Line
	dsp.delay_line_init(&line, buffer)
	testing.expect(t, dsp.delay_line_is_silent(&line), "a cleared line is not silent")
	values := [?]f32{0, 0.5, -0.25, 1.0e-30, -1.0e-30, 3, 0, 0, -0.0}
	seed: u32 = 7
	next :: proc(seed: ^u32, below: int) -> int {
		seed^ = seed^ * 1664525 + 1013904223
		return int(seed^ >> 8) % below
	}
	silent_steps := 0
	for step in 0 ..< 20000 {
		action := next(&seed, 200)
		value := values[next(&seed, len(values))]
		switch {
		case action == 0:
			dsp.delay_line_clear(&line)
		case action == 1:
			for _ in 0 ..< len(buffer) {
				dsp.delay_line_write(&line, 0)
			}
			testing.expectf(t, dsp.delay_line_is_silent(&line), "step %v: a buffer of zeros does not read as silent", step)
		case action < 60:
			dsp.chorus_feed(&line, value)
		case action < 120:
			dsp.delay_line_write(&line, 0)
		case:
			dsp.delay_line_write(&line, value)
		}
		if !dsp.delay_line_is_silent(&line) {
			continue
		}
		silent_steps += 1
		for sample, i in buffer {
			if sample != 0 {
				testing.expectf(t, false, "step %v: the line reads as silent and holds %v at %v", step, sample, i)
				return
			}
		}
	}
	testing.expectf(t, silent_steps > 500, "only %v steps were silent, too few to say anything", silent_steps)
}

// Two engines whose output is the same by construction: the effect unit at
// level 0 on the ring modulator returns its input untouched, but with it on the
// engine never takes the path that skips silent effects. Every sample of both is
// compared bit for bit, block by block.
Twin :: struct {
	skips, runs: engine.Engine,
	left, right: [2][]f32,
}

twin_load :: proc(t: ^testing.T, tw: ^Twin, p: patch.Patch) {
	running := p
	running.values[77] = 1 // effect unit on
	running.values[78] = 4 // ring modulator
	running.values[81] = 0 // level 0
	engine.engine_load_patch(&tw.skips, p, SR)
	engine.engine_load_patch(&tw.runs, running, SR)
	testing.expect(t, !tw.skips.params.effect_on, "the skipping engine has its effect unit on")
	testing.expect(t, tw.runs.params.effect_on && tw.runs.params.effect_type == .Ring_Mod && tw.runs.params.effect_level == 0,
		"the running engine's effect unit is not a level-0 ring modulator")
	for k in 0 ..< 2 {
		tw.left[k] = make([]f32, 128)
		tw.right[k] = make([]f32, 128)
	}
}

twin_destroy :: proc(tw: ^Twin) {
	engine.engine_destroy(&tw.skips)
	engine.engine_destroy(&tw.runs)
	for k in 0 ..< 2 {
		delete(tw.left[k])
		delete(tw.right[k])
	}
}

twin_render :: proc(t: ^testing.T, tw: ^Twin, seconds: f32) -> bool {
	blocks := int(seconds * SR) / 128
	for b in 0 ..< blocks {
		engine.engine_process(&tw.skips, tw.left[0], tw.right[0])
		engine.engine_process(&tw.runs, tw.left[1], tw.right[1])
		for i in 0 ..< 128 {
			same :=
				transmute(u32)tw.left[0][i] == transmute(u32)tw.left[1][i] &&
				transmute(u32)tw.right[0][i] == transmute(u32)tw.right[1][i]
			if !same {
				testing.expectf(t, false, "block %v sample %v: %v %v against %v %v",
					b, i, tw.left[0][i], tw.right[0][i], tw.left[1][i], tw.right[1][i])
				return false
			}
		}
	}
	return true
}

// Whether the skipping engine is where it skips: nothing sounding and every
// effect's memory at zero.
twin_skipping :: proc(tw: ^Twin) -> bool {
	every_section := dsp.Equalizer_Params{gain_db = 1}
	return engine.engine_active_voice_count(&tw.skips) == 0 &&
		dsp.equalizer_is_silent(&tw.skips.equalizer, &every_section) &&
		dsp.delay_is_silent(&tw.skips.delay) &&
		dsp.chorus_is_silent(&tw.skips.chorus)
}

// A note through the delay with feedback, its tone, an equaliser peak and the
// chorus, then silence long enough for every line to empty, then another note:
// skipping the silent effects changes no sample of any of it.
@(test)
test_skipping_silent_effects_changes_nothing :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[62] = 96 // equaliser peak boosted, so its biquad runs
	p.values[98] = 30 // delay tone off centre, so it runs
	p.values[36] = 64 // delay feedback
	p.values[65] = 1 // delay on
	p.values[66] = 1 // chorus on
	tw: Twin
	twin_load(t, &tw, p)
	defer twin_destroy(&tw)

	testing.expect(t, twin_skipping(&tw), "a fresh engine is not silent")
	if !twin_render(t, &tw, 0.25) {return}
	engine.engine_note_on(&tw.skips, 60, 0.9)
	engine.engine_note_on(&tw.runs, 60, 0.9)
	if !twin_render(t, &tw, 0.5) {return}
	testing.expect(t, !twin_skipping(&tw), "the note left nothing in the effects")
	engine.engine_note_off(&tw.skips, 60)
	engine.engine_note_off(&tw.runs, 60)
	if !twin_render(t, &tw, 30) {return}
	testing.expect(t, twin_skipping(&tw), "the effects never emptied, so nothing was skipped")
	if !twin_render(t, &tw, 0.25) {return}
	engine.engine_note_on(&tw.skips, 67, 0.7)
	engine.engine_note_on(&tw.runs, 67, 0.7)
	if !twin_render(t, &tw, 0.5) {return}
	engine.engine_note_off(&tw.skips, 67)
	engine.engine_note_off(&tw.runs, 67)
	twin_render(t, &tw, 1)
}

// The arpeggiator starts its notes inside the block, after the engine has
// decided nothing is sounding at the top of it: the first step out of silence
// must reach the effects on the sample it starts.
@(test)
test_skipping_silent_effects_keeps_the_arpeggiators_first_step :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[59] = 1 // arpeggiator on
	p.values[65] = 1 // delay on
	p.values[66] = 1 // chorus on
	tw: Twin
	twin_load(t, &tw, p)
	defer twin_destroy(&tw)

	if !twin_render(t, &tw, 0.1) {return}
	testing.expect(t, twin_skipping(&tw), "a fresh engine is not silent")
	for note in ([?]int{48, 55, 60}) {
		engine.engine_note_on(&tw.skips, note, 0.8)
		engine.engine_note_on(&tw.runs, note, 0.8)
	}
	if !twin_render(t, &tw, 2) {return}
	testing.expect(t, engine.engine_active_voice_count(&tw.skips) > 0 || !twin_skipping(&tw), "the arpeggiator never sounded")
	for note in ([?]int{48, 55, 60}) {
		engine.engine_note_off(&tw.skips, note)
		engine.engine_note_off(&tw.runs, note)
	}
	twin_render(t, &tw, 1)
}

// Each piece of memory the effects keep, left non-zero on its own in an engine
// with nothing playing, keeps the effects running: the skipping engine plays it
// out exactly as the running one does.
@(test)
test_skipping_silent_effects_waits_for_every_section_to_empty :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[60] = 30 // equaliser tone off centre
	p.values[62] = 96 // equaliser peak boosted
	p.values[98] = 30 // delay tone off centre
	p.values[65] = 1 // delay on
	p.values[66] = 1 // chorus on
	Leftover :: enum {
		Delay_Line_Left,
		Delay_Line_Right,
		Delay_Tone_Input,
		Delay_Tone_Output,
		Equaliser_Tone_Input,
		Equaliser_Tone_Output,
		Equaliser_Peak_Input,
		Equaliser_Peak_Output,
		Chorus_Line_Left,
		Chorus_Line_Right,
	}
	for leftover in Leftover {
		tw: Twin
		twin_load(t, &tw, p)
		defer twin_destroy(&tw)
		if !twin_render(t, &tw, 0.05) {return}
		testing.expect(t, twin_skipping(&tw), "a fresh engine is not silent")
		for e in ([?]^engine.Engine{&tw.skips, &tw.runs}) {
			switch leftover {
			case .Delay_Line_Left:
				dsp.delay_line_write(&e.delay.line[0], 0.5)
			case .Delay_Line_Right:
				dsp.delay_line_write(&e.delay.line[1], 0.5)
			case .Delay_Tone_Input:
				e.delay.tone[0].x_prev = 0.5
			case .Delay_Tone_Output:
				e.delay.tone[1].y_prev = 0.5
			case .Equaliser_Tone_Input:
				e.equalizer.tilt[0].x_prev = 0.5
			case .Equaliser_Tone_Output:
				e.equalizer.tilt[1].y_prev = 0.5
			case .Equaliser_Peak_Input:
				e.equalizer.peak[0].x2 = 0.5
			case .Equaliser_Peak_Output:
				e.equalizer.peak[1].y1 = 0.5
			case .Chorus_Line_Left:
				dsp.chorus_feed(&e.chorus.line[0], 0.5)
			case .Chorus_Line_Right:
				dsp.chorus_feed(&e.chorus.line[1], 0.5)
			}
		}
		testing.expectf(t, !twin_skipping(&tw), "%v: still reads as silent", leftover)
		if !twin_render(t, &tw, 1.5) {
			testing.expectf(t, false, "%v was skipped", leftover)
			return
		}
	}
}

// The effect unit moves without input -- the phaser's sweep, the ring
// modulator's oscillator, the compressor's detector -- so with it on nothing is
// skipped, sounding or not.
@(test)
test_skipping_silent_effects_leaves_a_running_effect_unit_alone :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[77] = 1 // effect unit on
	p.values[78] = 6 // phaser 1
	p.values[81] = 64
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	testing.expect(t, e.params.effect_on && e.params.effect_type == .Phaser_1, "the effect unit is not a phaser")
	render_frames(&e, 4800)
	testing.expect(t, e.effect.corner_set, "the phaser's sweep did not run while nothing sounded")
}
