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

// The lowest level in a span, from 4 ms windows stepped by 1 ms, so a restart
// from silence cannot hide inside one long average. Four milliseconds is a
// whole cycle of the lowest note these tests play; a shorter window would
// read a sine's own zero crossings as dips.
lowest_level :: proc(x: []f32, from_s, to_s: f64) -> f64 {
	lowest := 1000.0
	for t := from_s; t + 0.004 <= to_s; t += 0.001 {
		lowest = min(lowest, level_at(x, t, t + 0.004))
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

// The modulation envelope starts from zero on every new key, legato included.
//
// This pins a *requested* behaviour, not the reference's. Measured with
// `s1probe behavior keys --modenv`, the reference does not restart the
// modulation envelope on a legato key change at all, and restarts it from its
// current level in mono; the manual says legato does not trigger "the VCO and
// VCA envelopes" either. The change was asked for in those terms regardless,
// and docs/synth1-behavior-errors.md records the contradiction.
//
// Mid-decay is the case that tells "from zero" apart from "re-enter the attack
// where it is": oscillator 2's pitch above the played key is the envelope, so
// right after the new key it must be close to the key itself.
@(test)
test_mod_envelope_restarts_from_zero_on_every_new_key :: proc(t: ^testing.T) {
	for mode in ([2]int{MONO, LEGATO}) {
		p := behavior_patch(mode, 0, 0, 127)
		p.values[1] = 3 // oscillator 2 triangle
		p.values[5] = 127 // oscillator 2 only
		p.values[4] = 1
		p.values[2] = 64
		p.values[3] = 64
		p.values[10] = 1 // modulation envelope on
		p.values[71] = 0 // to oscillator 2 pitch
		p.values[11] = 100
		p.values[12] = 70 // attack
		p.values[13] = 110 // a long decay: still well up at 0.5 s

		events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}}
		x := render_keys(p, events, 0.7)
		defer delete(x)

		held := pitch_at(x, 0.47, 0.49) - 60
		testing.expectf(t, held > 4, "mode %v: the envelope was not up before the key (%.2f st)", mode, held)
		restarted := pitch_at(x, 0.5005, 0.506) - 67
		testing.expectf(t, restarted < held * 0.5,
			"mode %v: the modulation envelope carried on through the new key: %.2f st before, %.2f just after",
			mode, held, restarted)
	}
}

// A fallback is not a new key, so the request above does not cover it, and
// there the reference is followed. Releasing 67 back onto a held 60 with the
// envelope mid-decay: legato carries the offset straight through (23.49 st
// before, 23.07 at +5 ms) and mono restarts the attack from where it is
// (27.43 before, 29.70 at +5 ms, rising to 33.87). Neither drops to zero.
@(test)
test_falling_back_keeps_the_mod_envelope_level :: proc(t: ^testing.T) {
	for mode in ([2]int{MONO, LEGATO}) {
		p := behavior_patch(mode, 0, 0, 127)
		p.values[1] = 3
		p.values[5] = 127
		p.values[4] = 1
		p.values[2] = 64
		p.values[3] = 64
		p.values[10] = 1
		p.values[71] = 0
		p.values[11] = 100
		p.values[12] = 70
		p.values[13] = 110

		events := []Key_Event{{0.0, 60, true}, {0.5, 67, true}, {1.0, 67, false}}
		x := render_keys(p, events, 1.2)
		defer delete(x)

		before := pitch_at(x, 0.97, 0.99) - 67
		after := pitch_at(x, 1.0005, 1.012) - 60
		testing.expectf(t, before > 4, "mode %v: the envelope was not up before the release (%.2f st)", mode, before)
		testing.expectf(t, after > before - 1,
			"mode %v: falling back dropped the modulation envelope: %.2f st before, %.2f just after",
			mode, before, after)
	}
}

// Oscillator 2's pitch through a controller assignment, after `move` has run on
// a held note.
assigned_osc2_pitch :: proc(source: int, move: proc(e: ^engine.Engine)) -> f64 {
	p := behavior_patch(MONO, 0, 0, 127)
	p.values[1] = 3
	p.values[5] = 127
	p.values[4] = 1
	p.values[2] = 64
	p.values[3] = 64
	p.values[40] = 0 // no direct bend, so only the assignment can move pitch
	p.values[86] = source
	p.values[87] = 2 // oscillator 2 pitch
	p.values[50] = 80 // +25%
	p.values[88] = 0

	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	left := make([]f32, 9600)
	defer delete(left)
	right := make([]f32, 9600)
	defer delete(right)
	engine.engine_note_on(&e, 60, 100.0 / 127.0)
	move(&e)
	engine.engine_process(&e, left, right)
	return pitch_at(left, 0.05, 0.2)
}

// Only 0xB0nn, 0xD000 and 0xE000 route anything. A source the reference does
// not route stays inert: poly aftertouch (0xA000) and program change (0xC000)
// do not turn into channel pressure or bend because their high byte is near.
// The positive controls are the two new sources at their full reading.
@(test)
test_only_pressure_and_bend_sources_follow_pressure_and_bend :: proc(t: ^testing.T) {
	press :: proc(e: ^engine.Engine) {engine.engine_channel_pressure(e, 127)}
	bend_down :: proc(e: ^engine.Engine) {engine.engine_set_pitch_bend(e, -1)}

	testing.expectf(t, abs(assigned_osc2_pitch(0xD000, press) - 89.907) < 0.15,
		"pressure source: the reference reads 89.907")
	testing.expect(t, assigned_osc2_pitch(0xE000, bend_down) < 31,
		"bend source: raw 0 should take oscillator 2 down by a full displacement")
	for source in ([]int{0xA000, 0xC000, 0x0000}) {
		testing.expectf(t, abs(assigned_osc2_pitch(source, press) - 60) < 0.01,
			"source %x moved on channel pressure", source)
		testing.expectf(t, abs(assigned_osc2_pitch(source, bend_down) - 60) < 0.01,
			"source %x moved on pitch bend", source)
	}
	// And the two new sources do not answer each other's message.
	testing.expect(t, abs(assigned_osc2_pitch(0xD000, bend_down) - 60) < 0.01,
		"a pressure source moved on pitch bend")
	testing.expect(t, abs(assigned_osc2_pitch(0xE000, press) - 60) < 0.01,
		"a bend source moved on channel pressure")
}

// Power in [lo_hz, hi_hz) of a Hann-windowed stretch, by direct DFT; slow and
// simple, which is all a band level needs.
band_power_db :: proc(x: []f32, from, n: int, lo_hz, hi_hz: f64) -> f64 {
	bin_hz := f64(SR) / f64(n)
	sum := 0.0
	for k := int(math.ceil(lo_hz / bin_hz)); f64(k) * bin_hz < hi_hz; k += 1 {
		re, im := 0.0, 0.0
		for i in 0 ..< n {
			w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
			v := f64(x[from + i]) * w
			phase := 2.0 * math.PI * f64(k) * f64(i) / f64(n)
			re += v * math.cos(phase)
			im -= v * math.sin(phase)
		}
		sum += re * re + im * im
	}
	return 10.0 * math.log10(max(sum, 1.0e-30))
}

// Echo level minus dry level in one band, for one setting of parameter 98.
first_echo_db :: proc(tone: int, lo_hz, hi_hz: f64) -> f64 {
	p := behavior_patch(0, 0, 40, 0) // a short pluck, gone before the echo
	p.values[0] = 1 // saw: energy across the band
	p.values[65] = 1 // delay on
	p.values[35] = 8 // "(8)": 250 ms at the default 120 BPM
	p.values[36] = 0 // no feedback, so the echo is the first and only one
	p.values[37] = 64 // 50% wet
	p.values[82] = 0
	p.values[98] = tone
	x := render_keys(p, []Key_Event{{0.0, 48, true}, {0.1, 48, false}}, 0.6)
	defer delete(x)
	N :: 2048
	echo := behavior_frame(0.25)
	return band_power_db(x, echo, N, lo_hz, hi_hz) - band_power_db(x, 0, N, lo_hz, hi_hz)
}

// Parameter 98 shapes the first echo, not only what is fed back. Measured with
// `s1probe behavior delaytone`, feedback 0, echo against dry per band, relative
// to tone 64: tone 0 takes the first echo down 33.6 dB at 6.4-12.8 kHz and
// tone 127 takes it down 32.4 dB at 100-400 Hz. This engine read 0.00 in every
// band at every tone, because the tone sat only in the feedback path.
@(test)
test_delay_tone_shapes_the_first_echo :: proc(t: ^testing.T) {
	flat_high := first_echo_db(64, 6400, 12800)
	dark_high := first_echo_db(0, 6400, 12800)
	testing.expectf(t, dark_high - flat_high < -10,
		"tone 0 left the first echo's top octave at %.2f dB against tone 64 (reference -33.58)",
		dark_high - flat_high)

	flat_low := first_echo_db(64, 100, 400)
	thin_low := first_echo_db(127, 100, 400)
	testing.expectf(t, thin_low - flat_low < -10,
		"tone 127 left the first echo's bottom at %.2f dB against tone 64 (reference -32.37)",
		thin_low - flat_low)
}

arp_patch :: proc(mode, gate, porta, auto: int) -> patch.Patch {
	p := behavior_patch(mode, 50, 50, 40)
	p.values[59] = 1 // arpeggiator on
	p.values[31] = 2 // up
	p.values[32] = 0 // one octave
	p.values[33] = 11 // "(8)": 250 ms at the default 120 BPM
	p.values[34] = gate
	p.values[39] = porta
	p.values[74] = auto
	return p
}

ARP_CHORD :: []Key_Event{{0.0, 60, true}, {0.0, 64, true}, {0.0, 67, true}}

// At gate 127 a step is still held when the next one starts, so mono and
// legato treat it as an overlapping key -- the manual's own advice ("Turned
// all the way to the right, the notes sound without interruption, which is
// effective in combination with legato and portamento modes"). Measured with
// `s1probe behavior arp`, chord 60 64 67, up, "(8)": legato holds the sustain
// level through every step (-0.2 to -1.2 dB within 60 ms of the boundary) and
// mono restarts the attack from that level (+1.1 to +2.3 dB, never a dip),
// where this engine started every step from silence in a fresh voice (-8.0 to
// -3.5 dB). The pitch still steps to 64 in both.
@(test)
test_arp_gate_127_steps_are_legato_or_mono_key_changes :: proc(t: ^testing.T) {
	for mode in ([2]int{MONO, LEGATO}) {
		x := render_keys(arp_patch(mode, 127, 0, 0), ARP_CHORD, 0.6)
		defer delete(x)
		before := level_at(x, 0.24, 0.245)
		lowest := lowest_level(x, 0.25, 0.28)
		peak := level_at(x, 0.275, 0.285)
		testing.expectf(t, abs(pitch_at(x, 0.27, 0.3) - 64) < 0.05,
			"mode %v: the second step did not play 64", mode)
		testing.expectf(t, lowest > before - 1.5,
			"mode %v: the step restarted from silence: %.1f dB before, %.1f lowest", mode, before, lowest)
		if mode == MONO {
			testing.expectf(t, peak - before > 8,
				"mono step did not retrigger: %.1f dB before, %.1f at +30 ms", before, peak)
		} else {
			testing.expectf(t, abs(peak - before) < 1.5,
				"legato step retriggered: %.1f dB before, %.1f at +30 ms", before, peak)
		}
	}
}

// Below gate 127 the step has been released before the next starts, so it is
// not an overlap: no auto glide, and the reference's level and pitch match the
// fresh note this engine already played (within 0.2 dB). With gate 127 and
// auto portamento the steps glide (legato reads 60.57, 61.59, 62.31 over the
// first 50 ms of the 60 -> 64 step), where this engine jumped to 63.92.
@(test)
test_arp_auto_portamento_glides_only_between_held_steps :: proc(t: ^testing.T) {
	for mode in ([2]int{MONO, LEGATO}) {
		held := render_keys(arp_patch(mode, 127, 64, 1), ARP_CHORD, 0.6)
		defer delete(held)
		gliding := pitch_at(held, 0.252, 0.265)
		testing.expectf(t, gliding > 60.3 && gliding < 63.5,
			"mode %v, gate 127: the 60 -> 64 step did not glide: %.2f just after the step", mode, gliding)

		gated := render_keys(arp_patch(mode, 64, 64, 1), ARP_CHORD, 0.6)
		defer delete(gated)
		testing.expectf(t, abs(pitch_at(gated, 0.255, 0.28) - 64) < 0.05,
			"mode %v, gate 64: a released step glided with auto portamento", mode)
	}
}

// Windowed DFT power at one frequency.
tone_power_db :: proc(x: []f32, from, n: int, hz: f64) -> f64 {
	re, im := 0.0, 0.0
	for i in 0 ..< n {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
		v := f64(x[from + i]) * w
		phase := 2.0 * math.PI * hz * f64(i) / f64(SR)
		re += v * math.cos(phase)
		im -= v * math.sin(phase)
	}
	return 10.0 * math.log10(max(re * re + im * im, 1.0e-30))
}

osc2_untracked :: proc(setup: proc(p: ^patch.Patch)) -> []f32 {
	p := behavior_patch(0, 0, 0, 127)
	p.values[1] = 3 // oscillator 2 triangle
	p.values[5] = 127 // oscillator 2 only
	p.values[4] = 0 // key tracking off
	p.values[2] = 64
	p.values[3] = 64
	setup(&p)
	return render_keys(p, []Key_Event{{0.0, 60, true}}, 1.1)
}

// With oscillator 2's key tracking off, the fine tune (parameter 72) and the
// unison detune still move it. Measured with `s1probe behavior osc2track`:
// "+50 cent" takes the reference's untracked oscillator 2 from 220.02 to
// 226.49 Hz (+50.1 cents), and unison 2 at detune 127 splits it into 213.73
// and 226.49 Hz (-50.0 and +50.1 cents). This engine ignored both. Key shift,
// the third control the request named, leaves the reference at 220.02 Hz and
// is deliberately not tested for; see docs/synth1-behavior-errors.md.
//
// The comparison is relative, in cents from this engine's own untracked
// pitch: the reference's fixed pitch (220 Hz against this engine's 261.6) is a
// separate, deferred finding.
@(test)
test_untracked_oscillator_2_takes_fine_tune_and_unison_detune :: proc(t: ^testing.T) {
	plain := osc2_untracked(proc(p: ^patch.Patch) {})
	defer delete(plain)
	base := pitch_at(plain, 0.2, 1.0)

	tuned := osc2_untracked(proc(p: ^patch.Patch) {p.values[72] = 116}) // "+50 cent"
	defer delete(tuned)
	cents := (pitch_at(tuned, 0.2, 1.0) - base) * 100
	testing.expectf(t, abs(cents - 50.1) < 2,
		"fine tune +50 cent moved untracked oscillator 2 by %.1f cents (reference +50.1)", cents)

	spread := osc2_untracked(proc(p: ^patch.Patch) {
		p.values[73] = 1 // unison on
		p.values[93] = 2 // "2" voices
		p.values[75] = 127 // full detune
	})
	defer delete(spread)
	hz := 440.0 * math.pow(f64(2), (base - 69.0) / 12.0)
	N :: 24000
	from := behavior_frame(0.5)
	centre := tone_power_db(spread, from, N, hz)
	low := tone_power_db(spread, from, N, hz * math.pow(f64(2), -50.0 / 1200.0))
	high := tone_power_db(spread, from, N, hz * math.pow(f64(2), 50.1 / 1200.0))
	testing.expectf(t, low - centre > 10 && high - centre > 10,
		"unison detune did not split untracked oscillator 2: -50c %.1f dB, centre %.1f, +50c %.1f",
		low, centre, high)
}
