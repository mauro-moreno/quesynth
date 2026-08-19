package engine

// The arpeggiator: held keys played one at a time, in step with the host.
//
// Every number in here was measured out of the reference with `s1probe
// arpprobe`, which finds the attacks in a render and reads the step spacing,
// the pitch of each step and how much of each step has sound in it. The method
// and the readings are in docs/null-test.md.
//
// It is the one section of the instrument that needs musical time. A step is a
// division of the beat, so the arpeggiator reads `Engine.tempo_bpm`, and a host
// that never sets it gets the 120 BPM default rather than silence.

// How long one step lasts, in beats, for each of parameter 33's nineteen
// states.
//
// The reference names them in a notation that turns out to be plain
// arithmetic: `(N)` is a 1/N note and therefore 4/N beats, `(a)+(b)` is the sum
// of the two, and `(N) /3` is that value divided by three. The last of those is
// worth stating because it is *not* the usual triplet convention -- a musician
// writing "quarter triplet" means two thirds of a quarter, while the reference
// means one third of it. `(1) /3` measured 1.332 beats, and 4/3 is 1.3333;
// two thirds of a whole note would have been 2.667.
//
// All nineteen were measured, not just the ones that make the pattern obvious.
// The fastest six needed a percussive amplitude envelope before the steps could
// be told apart at all, because at 1/24 of a beat the reference's own release
// smears one step into the next.
ARP_STEP_BEATS := [19]f32 {
	4.0, // (1)
	3.5, // (2)+(4)+(8)
	3.0, // (2)+(4)
	2.0, // (2)
	1.75, // (4)+(8)+(16)
	1.5, // (4)+(8)
	4.0 / 3.0, // (1) /3
	1.0, // (4)
	0.875, // (8)+(16)+(32)
	0.75, // (8)+(16)
	2.0 / 3.0, // (2) /3
	0.5, // (8)
	0.375, // (16)+(32)
	1.0 / 3.0, // (4) /3
	0.25, // (16)
	1.0 / 6.0, // (8) /3
	0.125, // (32)
	1.0 / 12.0, // (16) /3
	1.0 / 24.0, // (32) /3
}

// The order the held notes are played in. Parameter 31 stores the display
// integer, which runs 1..4, so the stored value is one more than this enum.
Arp_Pattern :: enum u8 {
	Up_Down,
	Up,
	Down,
	Random,
}

// At most this many keys take part. Beyond it the highest are ignored rather
// than the sequence growing without bound; nobody holds seventeen keys, and a
// fixed ceiling is what keeps this allocation-free.
ARP_MAX_HELD :: 16

// The most octaves parameter 32 offers, and therefore the longest a sequence
// can get: sixteen keys across four octaves.
ARP_MAX_OCTAVES :: 4
ARP_MAX_STEPS :: ARP_MAX_HELD * ARP_MAX_OCTAVES

Arpeggiator :: struct {
	// Frames elapsed inside the current step. Counted up rather than down so a
	// tempo change mid-step shortens or lengthens the step in progress instead
	// of skipping it.
	phase:      f64,
	// Which step of the pattern comes next.
	step:       int,
	// The note currently gated on, or -1. Held so the gate can close it and a
	// step boundary can retrigger it, without searching the voice pool.
	sounding:   int,
	// The velocity the held key arrived with, which is what a step is played
	// at. Runtime state and not a bound parameter: it comes from a key press,
	// belongs to no patch, and kept in Engine_Params it would be a block stale
	// because the params copy is made once per block.
	velocity:   f32,
	// Set when the held set goes from empty to occupied, so the first key
	// starts a step immediately rather than waiting out the remainder of one
	// that has been running silently.
	restart:    bool,
	rng:        u32,
}

arp_reset :: proc(a: ^Arpeggiator) {
	a.phase = 0
	a.step = 0
	a.sounding = -1
	a.restart = true
	a.rng = 0x2545F491
	a.velocity = 0.8
}

// xorshift, so the random pattern is reproducible from a seed and costs
// nothing. Only used once per step.
arp_next_random :: proc(a: ^Arpeggiator) -> u32 {
	x := a.rng
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	a.rng = x
	return x
}

// The held keys, ascending. The engine already tracks which keys are down for
// legato and for the sustain pedal, so this reads that rather than keeping a
// second list that could disagree with it.
arp_collect_held :: proc(e: ^Engine, out: []int) -> int {
	count := 0
	for note in 0 ..< len(e.held_keys) {
		if !e.held_keys[note] {
			continue
		}
		if count >= len(out) {
			break
		}
		out[count] = note
		count += 1
	}
	return count
}

// How many steps one pass through the pattern takes.
//
// Up and Down is 2n-2 rather than 2n: measured as 60 64 67 64 for a three-note
// chord, so neither the top nor the bottom repeats on the turn.
arp_sequence_length :: proc(pattern: Arp_Pattern, notes: int) -> int {
	if notes <= 0 {
		return 0
	}
	#partial switch pattern {
	case .Up_Down:
		return notes <= 1 ? 1 : notes * 2 - 2
	}
	return notes
}

// Which of the `notes` positions the given step plays.
arp_position :: proc(a: ^Arpeggiator, pattern: Arp_Pattern, notes, step: int) -> int {
	if notes <= 0 {
		return 0
	}
	switch pattern {
	case .Up:
		return step % notes
	case .Down:
		return notes - 1 - (step % notes)
	case .Up_Down:
		if notes <= 1 {
			return 0
		}
		period := notes * 2 - 2
		j := step % period
		return j < notes ? j : period - j
	case .Random:
		return int(arp_next_random(a) % u32(notes))
	}
	return 0
}

// The note a step plays, or false when nothing is held.
//
// The octave range stacks whole copies of the chord above it: range 1 measured
// 60 64 67 72 76 79, so the position runs through the chord first and the
// octave second.
arp_step_note :: proc(e: ^Engine, params: ^Engine_Params, step: int) -> (int, bool) {
	held: [ARP_MAX_HELD]int
	count := arp_collect_held(e, held[:])
	if count == 0 {
		return 0, false
	}

	octaves := clamp_int(params.arp_octaves, 1, ARP_MAX_OCTAVES)
	total := count * octaves
	position := arp_position(&e.arp, params.arp_pattern, total, step)

	note := held[position % count] + 12 * (position / count)
	if note > 127 {
		note = 127
	}
	return note, true
}

// Frames in one step at the current tempo, or 0 when the tempo makes no sense.
arp_step_frames :: proc(e: ^Engine, params: ^Engine_Params) -> f64 {
	bpm := f64(e.tempo_bpm > 0 ? e.tempo_bpm : 120.0)
	beats := f64(params.arp_step_beats)
	if beats <= 0 {
		return 0
	}
	return beats * (60.0 / bpm) * f64(e.sample_rate)
}

arp_silence :: proc(e: ^Engine) {
	if e.arp.sounding < 0 {
		return
	}
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.gate && v.note == e.arp.sounding {
			voice_note_off(v)
		}
	}
	e.arp.sounding = -1
}

// One sample of arpeggiator. Called from `engine_process` before the voices are
// summed, so a step that starts on this sample is audible on it.
//
// Everything here is per sample because the step boundary has to land on the
// right one: rounding it to a block would put a 1/24-beat step up to a whole
// step late at 512 frames, which is audible as swing that is not in the patch.
arp_process :: proc(e: ^Engine, params: ^Engine_Params) {
	step_frames := arp_step_frames(e, params)
	if step_frames <= 0 {
		return
	}

	held: [ARP_MAX_HELD]int
	if arp_collect_held(e, held[:]) == 0 {
		// Nothing held: silence whatever was gated and wait, rearmed, so the
		// next key starts a step rather than landing mid-way through one.
		arp_silence(e)
		e.arp.restart = true
		e.arp.phase = 0
		return
	}

	if e.arp.restart {
		e.arp.restart = false
		e.arp.phase = 0
		e.arp.step = 0
		arp_trigger(e, params)
		return
	}

	if e.arp.phase >= step_frames {
		e.arp.phase -= step_frames
		e.arp.step += 1
		arp_trigger(e, params)
		return
	}

	// The gate closes partway through the step. Measured linear in parameter
	// 34: a stored 64 sounds for 0.51 of the step and 127 for all of it, so the
	// fraction is the stored value over 127 with no curve on it.
	if e.arp.sounding >= 0 && e.arp.phase >= step_frames * f64(params.arp_gate) {
		arp_silence(e)
	}
	e.arp.phase += 1
}

arp_trigger :: proc(e: ^Engine, params: ^Engine_Params) {
	arp_silence(e)
	note, ok := arp_step_note(e, params, e.arp.step)
	if !ok {
		return
	}
	engine_start_voice(e, note, e.arp.velocity)
	e.arp.sounding = note
	e.arp.phase += 1
}
