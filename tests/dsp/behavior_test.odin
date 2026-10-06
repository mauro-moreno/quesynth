package dsp_tests

// What the engine does between notes: mono and legato key handling,
// portamento on overlapping keys, the modulation envelope on a new key, and
// the arpeggiator driving the same transitions.
//
// The expected values are the reference's, read with `s1probe behavior` (see
// docs/synth1-behavior-errors.md for the commands and the full tables), except
// where a test says it pins a requested behaviour the reference does not have.
// Every test drives the public engine entry points and reads the rendered
// audio, not voice state, so it cannot pass by agreeing with itself about a
// field.

import "core:math"
import "core:testing"

import "../../src/engine"
import "../../src/patch"

// A sine on oscillator 1 through an open, unmodulated filter, every effect and
// modulator off: pitch and level in the render are the voice's and nothing
// else's. Mirrors `neutral_probe_patch` in tools/s1probe/modprobe.odin.
behavior_patch :: proc(mode, attack, decay, sustain: int) -> patch.Patch {
	p := default_patch()
	p.values[0] = 0 // oscillator 1 sine
	p.values[5] = 0 // oscillator 1 only
	p.values[6] = 0
	p.values[7] = 0
	p.values[10] = 0 // modulation envelope off
	p.values[45] = 0
	p.values[95] = 0
	p.values[19] = 127 // filter open
	p.values[20] = 0
	p.values[21] = 63 // filter envelope amount "0"
	p.values[22] = 0
	p.values[23] = 0
	p.values[24] = 0
	p.values[15] = 0
	p.values[16] = 0
	p.values[17] = 127
	p.values[18] = 0
	p.values[25] = attack
	p.values[26] = decay
	p.values[27] = sustain
	p.values[28] = 0 // instant release
	p.values[29] = 100
	p.values[30] = 0
	p.values[37] = 0
	p.values[57] = 0 // both LFOs off
	p.values[58] = 0
	p.values[59] = 0 // arpeggiator off
	p.values[65] = 0 // delay off
	p.values[66] = 0 // chorus off
	p.values[77] = 0
	p.values[38] = mode
	p.values[39] = 0 // no portamento
	p.values[74] = 0
	p.values[73] = 0 // unison off
	p.values[91] = 1 // fixed oscillator phase
	return p
}

Key_Event :: struct {
	seconds: f64,
	note:    int,
	on:      bool,
}

behavior_frame :: proc(seconds: f64) -> int {
	return int(seconds * f64(SR))
}

// Render the left channel of `p` through a key script, applying each event at
// its exact sample.
render_keys :: proc(p: patch.Patch, events: []Key_Event, seconds: f64) -> []f32 {
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	total := behavior_frame(seconds)
	left := make([]f32, total)
	right := make([]f32, total)
	defer delete(right)

	pos := 0
	next := 0
	for pos < total {
		for next < len(events) && behavior_frame(events[next].seconds) <= pos {
			ev := events[next]
			if ev.on {
				engine.engine_note_on(&e, ev.note, 100.0 / 127.0)
			} else {
				engine.engine_note_off(&e, ev.note)
			}
			next += 1
		}
		end := min(pos + 256, total)
		if next < len(events) {
			end = min(end, behavior_frame(events[next].seconds))
		}
		engine.engine_process(&e, left[pos:end], right[pos:end])
		pos = end
	}
	return left
}

// Pitch, in MIDI notes, from interpolated positive-going zero crossings.
// Exact for the sine `behavior_patch` renders; 0 when there is no tone.
pitch_at :: proc(x: []f32, from_s, to_s: f64) -> f64 {
	lo := max(behavior_frame(from_s), 1)
	hi := min(behavior_frame(to_s), len(x))
	first, last := -1.0, -1.0
	count := 0
	for i in lo ..< hi {
		a := f64(x[i - 1])
		b := f64(x[i])
		if a < 0 && b >= 0 {
			t := f64(i - 1) - a / (b - a)
			if first < 0 {first = t}
			last = t
			count += 1
		}
	}
	if count < 2 || last <= first {return 0}
	hz := f64(count - 1) * f64(SR) / (last - first)
	return 69.0 + 12.0 * math.log2(hz / 440.0)
}

level_at :: proc(x: []f32, from_s, to_s: f64) -> f64 {
	lo := max(behavior_frame(from_s), 0)
	hi := min(behavior_frame(to_s), len(x))
	if hi <= lo {return -200}
	sum := 0.0
	for i in lo ..< hi {
		sum += f64(x[i]) * f64(x[i])
	}
	rms := math.sqrt(sum / f64(hi - lo))
	return rms > 1.0e-10 ? 20.0 * math.log10(rms) : -200
}

// The lowest 1 ms level in a span, so a restart from silence cannot hide
// inside a window average.
lowest_level :: proc(x: []f32, from_s, to_s: f64) -> f64 {
	lowest := 1000.0
	for t := from_s; t + 0.001 <= to_s; t += 0.001 {
		lowest = min(lowest, level_at(x, t, t + 0.001))
	}
	return lowest
}

MONO :: 1
LEGATO :: 2

// The reference, newest key 67 released while 60 is still held: both modes
// fall back to 60 (60.00 at +5 ms). Mono restarts the attack (-28.8 dB before,
// -10.0 dB at +30 ms); legato leaves the level where it was (-28.7 dB before,
// -28.8 at +30 ms). This engine went silent in both.
@(test)
test_releasing_the_newest_key_falls_back_to_the_held_one :: proc(t: ^testing.T) {
	events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}, {1.0, 67, false}}
	for mode in ([2]int{MONO, LEGATO}) {
		x := render_keys(behavior_patch(mode, 50, 50, 40), events, 1.4)
		defer delete(x)

		before := level_at(x, 0.97, 0.98)
		pitch := pitch_at(x, 1.015, 1.045)
		testing.expectf(t, abs(pitch - 60) < 0.05,
			"mode %v: after releasing 67 with 60 held the voice plays %.2f, not 60", mode, pitch)

		peak := level_at(x, 1.025, 1.035)
		if mode == MONO {
			testing.expectf(t, peak - before > 10,
				"mono fallback did not retrigger: %.1f dB before, %.1f at +30 ms (reference -28.8 -> -10.0)",
				before, peak)
		} else {
			testing.expectf(t, abs(peak - before) < 1.5,
				"legato fallback moved the level: %.1f dB before, %.1f at +30 ms (reference -28.7 -> -28.8)",
				before, peak)
		}
	}
}

// Releasing a key that is not sounding changes nothing (the reference holds
// 67.00 at -28.6 dB through `off 60` in both modes).
@(test)
test_releasing_a_key_that_is_not_sounding_changes_nothing :: proc(t: ^testing.T) {
	events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}, {1.0, 60, false}}
	for mode in ([2]int{MONO, LEGATO}) {
		x := render_keys(behavior_patch(mode, 50, 50, 40), events, 1.3)
		defer delete(x)
		before := level_at(x, 0.97, 0.98)
		testing.expectf(t, abs(pitch_at(x, 1.015, 1.045) - 67) < 0.05,
			"mode %v: releasing the held 60 moved the pitch", mode)
		testing.expectf(t, abs(level_at(x, 1.025, 1.035) - before) < 1.5,
			"mode %v: releasing the held 60 moved the level", mode)
	}
}

// A repeated note-on makes that key the newest: after 60, 67, 60 again,
// releasing 60 falls back to 67 (the reference reads 67.00 at +5 ms).
@(test)
test_a_repeated_key_becomes_the_newest :: proc(t: ^testing.T) {
	events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}, {1.0, 60, true}, {1.5, 60, false}}
	for mode in ([2]int{MONO, LEGATO}) {
		x := render_keys(behavior_patch(mode, 50, 50, 40), events, 1.8)
		defer delete(x)
		testing.expectf(t, abs(pitch_at(x, 1.015, 1.045) - 60) < 0.05,
			"mode %v: the repeated 60 did not sound", mode)
		testing.expectf(t, abs(pitch_at(x, 1.515, 1.545) - 67) < 0.05,
			"mode %v: releasing the repeated 60 did not fall back to 67", mode)
	}
}

// The overlapping note-on obeys the same rule as the fallback. Reference, `on
// 67` with 60 held: legato stays at the sustain level (-28.6 dB at +5 and +30
// ms); mono restarts the attack from where the envelope is, never dropping
// below it (-17.4 at +5 ms, -10.0 at +30 ms). This engine re-entered the
// attack in legato and started mono from silence in a fresh voice.
@(test)
test_an_overlapping_key_retriggers_mono_from_its_level_and_not_legato :: proc(t: ^testing.T) {
	events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}}
	for mode in ([2]int{MONO, LEGATO}) {
		x := render_keys(behavior_patch(mode, 50, 50, 40), events, 0.7)
		defer delete(x)
		before := level_at(x, 0.47, 0.48)
		lowest := lowest_level(x, 0.5, 0.53)
		peak := level_at(x, 0.525, 0.535)
		if mode == MONO {
			testing.expectf(t, lowest > before - 1.5,
				"mono overlap restarted from silence: %.1f dB before, %.1f lowest", before, lowest)
			testing.expectf(t, peak - before > 10,
				"mono overlap did not retrigger: %.1f dB before, %.1f at +30 ms", before, peak)
		} else {
			testing.expectf(t, abs(peak - before) < 1.5,
				"legato overlap retriggered: %.1f dB before, %.1f at +30 ms", before, peak)
		}
	}
}

// Parameter 74 limits portamento to keys that overlap, and that is an overlap
// in mono as much as in legato. The reference, mono, portamento 64, auto on,
// 72 pressed over a held 60: 62.34 at +5 ms, 65.00 at +30, 71.96 at +300. With
// the keys separated it is 72.00 from the start. Releasing 72 back onto 60
// glides too (69.85 at +5 ms). This engine jumped in mono either way.
//
// The bound is loose on purpose: the portamento *time* law is a chosen curve
// that settles faster than the reference's, and is not what this tests.
@(test)
test_auto_portamento_glides_on_overlapping_keys_in_mono :: proc(t: ^testing.T) {
	p := behavior_patch(MONO, 0, 0, 127)
	p.values[39] = 64
	p.values[74] = 1

	overlap := []Key_Event{{0.0, 60, true}, {0.5, 72, true}, {1.0, 72, false}}
	x := render_keys(p, overlap, 1.3)
	defer delete(x)
	rising := pitch_at(x, 0.505, 0.515)
	testing.expectf(t, rising > 60.5 && rising < 71.5,
		"72 over a held 60 did not glide: %.2f at +5 ms (reference 62.34)", rising)
	falling := pitch_at(x, 1.005, 1.015)
	testing.expectf(t, falling > 60.5 && falling < 71.5,
		"falling back from 72 to 60 did not glide: %.2f at +5 ms (reference 69.85)", falling)

	separate := []Key_Event{{0.0, 60, true}, {0.45, 60, false}, {0.5, 72, true}}
	y := render_keys(p, separate, 0.7)
	defer delete(y)
	jump := pitch_at(y, 0.505, 0.515)
	testing.expectf(t, abs(jump - 72) < 0.05,
		"separated keys glided with auto portamento on: %.2f at +5 ms (reference 72.00)", jump)
}
