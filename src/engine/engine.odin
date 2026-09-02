package engine

import "../dsp"
import "../patch"

// Layer 1: the engine.
//
// This layer owns voice allocation, parameter smoothing and the patch binding.
// It is allowed to allocate, but only in `engine_init`: the voice pool is sized
// once from parameter 94 and never grows, so `engine_process` runs with no
// allocator in reach. That is what lets the same code sit under a CLAP host and
// under an iOS audio callback.

DEFAULT_SAMPLE_RATE :: f32(48000.0)

// How long a smoothed parameter takes to cover a step. Short enough not to be
// heard as a glide, long enough to remove the zipper noise a per-block jump in
// cutoff would otherwise produce.
SMOOTHING_SECONDS :: f32(0.01)

// The slowest tempo the delay will size its buffers for.
//
// The longest musical division parameter 35 offers is a whole note, four beats,
// which at 30 BPM is eight seconds. Sizing for that means a host dropping to a
// crawl mid-song cannot ask for a delay longer than the buffer already holds --
// and the alternative, reallocating when the tempo moves, would put an allocator
// on the audio thread.
DELAY_MIN_TEMPO_BPM :: f32(30.0)
DELAY_MAX_BEATS :: f32(4.0)
// Parameter 83 spreads the two channels by up to 100 ms on top of the division.
DELAY_MAX_SPREAD_MS :: f32(100.0)

// Parameter 52's chorus delay reaches 30 ms, and the depth sweeps around it, so
// twice that plus a margin covers every setting.
CHORUS_MAX_MS :: f32(70.0)

Engine :: struct {
	sample_rate: f32,
	params:      Engine_Params,

	// Allocated once in `engine_init`, sized from parameter 94.
	voices:      []Voice,

	// The free-running LFOs. Voices with key sync run their own copy instead;
	// these are what everything else reads, so two voices started a second
	// apart stay in phase with each other.
	global_lfo:  [2]dsp.Lfo,

	cutoff_smooth: Smoother,
	gain_smooth:   Smoother,
	pan_smooth:    Smoother,

	// The effects, and the buffers their delay lines run in.
	//
	// Allocated once in `engine_init` alongside the voice pool, for the same
	// reason: `engine_process` must not reach an allocator. The lines are sized
	// for the longest time the parameters can ask for at the slowest tempo this
	// engine accepts, so a tempo change can never need a longer buffer than the
	// one it already has.
	// The patch as loaded, kept so a MIDI controller can re-derive a parameter
	// through `bind_patch` rather than through a second copy of its mapping.
	patch:         patch.Patch,
	has_patch:     bool,
	// Where each of the two assigned controllers currently sits, on 0..1.
	ctrl_value:    [2]f32,

	effect:        dsp.Effect,
	equalizer:     dsp.Equalizer,
	delay:         dsp.Delay,
	chorus:        dsp.Chorus,
	delay_left:    []f32,
	delay_right:   []f32,
	chorus_left:   []f32,
	chorus_right:  []f32,

	// -1..1, in units of `Engine_Params.pitch_bend_range`.
	pitch_bend:  f32,
	tempo_bpm:   f32,

	// Monotonic, used for voice stealing and for seeding each voice's noise.
	age:         u64,
	// The last note started, for portamento and for legato detection.
	last_note:   f32,
	// Keys physically held by the caller. This is deliberately independent of
	// voice gate state: mono and legato mode may release a voice while its key is
	// still down, and repeated note-on must not double-count that key.
	held_notes:  int,

	// The arpeggiator step clock and what it currently has sounding. Idle,
	// and costing one branch a sample, when parameter 59 is off.
	arp:         Arpeggiator,
	held_keys:   [128]bool,
}

// Allocate and configure the engine. This is the only procedure here that
// allocates.
engine_init :: proc(e: ^Engine, params: Engine_Params, sample_rate: f32) {
	engine_destroy(e)

	e.sample_rate = sample_rate > 0 ? sample_rate : DEFAULT_SAMPLE_RATE
	e.params = params
	e.tempo_bpm = 120.0
	e.pitch_bend = 0
	e.age = 0
	e.last_note = 60.0
	e.held_notes = 0
	e.held_keys = {}
	arp_reset(&e.arp)

	count := clamp_int(params.polyphony, 1, MAX_POLYPHONY)
	e.voices = make([]Voice, count)

	// The effect buffers, sized from the worst case the parameters allow.
	delay_seconds := DELAY_MAX_BEATS * 60.0 / DELAY_MIN_TEMPO_BPM + DELAY_MAX_SPREAD_MS * 0.001
	delay_samples := int(delay_seconds * e.sample_rate) + 4
	chorus_samples := int(CHORUS_MAX_MS * 0.001 * e.sample_rate) + 4

	e.delay_left = make([]f32, delay_samples)
	e.delay_right = make([]f32, delay_samples)
	e.chorus_left = make([]f32, chorus_samples)
	e.chorus_right = make([]f32, chorus_samples)
	dsp.effect_reset(&e.effect)
	dsp.equalizer_reset(&e.equalizer)
	dsp.delay_init(&e.delay, e.delay_left, e.delay_right)
	dsp.chorus_init(&e.chorus, e.chorus_left, e.chorus_right)

	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		v^ = {}
		for j in 0 ..< 2 {
			dsp.lfo_init(&v.lfo[j], 0x51F0_0001 + u32(i) * 2654435761 + u32(j))
			v.lfo[j].shape = params.lfo[j].shape
		}
	}

	for j in 0 ..< 2 {
		dsp.lfo_init(&e.global_lfo[j], 0x6C_F0_0001 + u32(j))
		e.global_lfo[j].shape = params.lfo[j].shape
	}

	smoother_init(&e.cutoff_smooth, params.filter_cutoff_state, SMOOTHING_SECONDS, e.sample_rate)
	smoother_init(&e.gain_smooth, params.amp_gain, SMOOTHING_SECONDS, e.sample_rate)
	smoother_init(&e.pan_smooth, params.pan, SMOOTHING_SECONDS, e.sample_rate)

	engine_update_lfo_rates(e)
}

engine_destroy :: proc(e: ^Engine) {
	if e.voices != nil {
		delete(e.voices)
		e.voices = nil
	}
	if e.delay_left != nil {
		delete(e.delay_left)
		delete(e.delay_right)
		delete(e.chorus_left)
		delete(e.chorus_right)
		e.delay_left = nil
		e.delay_right = nil
		e.chorus_left = nil
		e.chorus_right = nil
	}
	e.effect = {}
	e.equalizer = {}
	e.delay = {}
	e.chorus = {}
}

// Load a patch. Convenience over `bind_patch` plus `engine_init`, and the entry
// point the render tool and the plugin shells both use.
engine_load_patch :: proc(e: ^Engine, p: patch.Patch, sample_rate: f32) {
	e.patch = p
	e.has_patch = true
	for i in 0 ..< 2 {
		e.ctrl_value[i] = 0
	}
	engine_init(e, bind_patch(p), sample_rate)
}

// Change the patch under a running instrument.
//
// `engine_load_patch` cannot be used for this. It goes through `engine_init`,
// which frees and reallocates the voice pool, wipes every voice, clears the delay
// and chorus buffers and resets the pitch bend and the held keys -- so a single
// parameter change would cut whatever was sounding, along with its reverb tail.
// That is right when an instrument is being loaded and wrong on every edit after,
// and the browser build made it obvious: turning any knob silenced the note, and
// loading a patch did it ninety-nine times over.
//
// So the parameters are rebuilt and swapped in, and everything the voices are
// mid-note on is left alone. The one exception is the voice count, which cannot
// change size under a sounding note; that still goes the long way round.
// `snap` is the difference between loading a patch and turning a knob.
//
// The smoothed parameters -- cutoff, gain, pan -- glide to their target, which is
// what stops a knob from stepping audibly. Across a *patch change* that glide is
// wrong: the new sound would sweep in from the old one's cutoff over the first
// tenth of a second, which is both audible and not what the patch is. Snapping
// them is what `smoother_reset` exists for.
//
// The cost of getting this backwards is not obvious from listening to one note,
// which is why it is worth stating: rendered against the reference, a patch loaded
// without snapping came out at a peak of 0.0519 where the same patch loaded fresh
// gives 0.0333, because the note began under the wrong filter.
engine_apply_patch :: proc(e: ^Engine, p: patch.Patch, snap := false) {
	params := bind_patch(p)
	previous_ctrl := e.params.midi_ctrl
	e.patch = p
	e.has_patch = true
	for i in 0 ..< 2 {
		if previous_ctrl[i].cc != params.midi_ctrl[i].cc {
			e.ctrl_value[i] = 0
		}
	}

	count := clamp_int(params.polyphony, 1, MAX_POLYPHONY)
	if e.voices == nil || count != len(e.voices) {
		engine_init(e, params, e.sample_rate)
		engine_refresh_controllers(e)
		return
	}

	if snap {
		smoother_reset(&e.cutoff_smooth, params.filter_cutoff_state)
		smoother_reset(&e.gain_smooth, params.amp_gain)
		smoother_reset(&e.pan_smooth, params.pan)

		// And the effects' own memory, which is the part that is audible if it is
		// forgotten.
		//
		// A delay line holds a second or more of the *previous* patch. Leave it and
		// the new patch reads that content back out at its own delay time and
		// spread, which is not a subtle artefact -- it bounces the old sound
		// between the channels and lands somewhere between a ping-pong and a
		// stutter, over a patch that may have no delay at all. The chorus and the
		// phaser hold the same kind of state.
		//
		// Notes are deliberately *not* touched. A patch change should stop being
		// able to hear the last patch; it should not cut the key that is down.
		dsp.delay_reset(&e.delay)
		dsp.chorus_reset(&e.chorus)
		dsp.effect_reset(&e.effect)
		dsp.equalizer_reset(&e.equalizer)
	}

	e.params = params
	engine_refresh_controllers(e)
}

// A MIDI control change arrived.
//
// Parameters 86..89 route two controllers onto two parameters, scaled by 50 and
// 51. What the reference does with them is measured; see `Midi_Control`.
//
// The modulated parameter is applied by rebuilding the parameter block from the
// stored patch with the target's value displaced, rather than by reaching into
// `Engine_Params` and moving a field. That is deliberate: a destination can be any
// of ninety-nine parameters, and each of them has its own mapping -- a table
// lookup, a signed law, a curve -- which lives in `bind_patch` and exists exactly
// once. Poking the derived value would be a second copy of every one of those
// mappings, and the wrong one on the first curve that changed.
//
// It costs a full rebind per controller message, which is nothing: control changes
// arrive at most a few hundred times a second, and `bind_patch` reaches no
// allocator and touches no voice state.
engine_control_change :: proc(e: ^Engine, cc: int, value: int) {
	if !e.has_patch {
		return
	}

	changed := false
	for i in 0 ..< 2 {
		c := e.params.midi_ctrl[i]
		if c.cc != cc || c.target < 0 {
			continue
		}
		e.ctrl_value[i] = f32(clamp_int(value, 0, 127)) / 127.0
		changed = true
	}
	if !changed {
		return
	}

	engine_refresh_controllers(e)
}

// Rebuild the live parameter block from the stored patch and the last value of
// each controller assignment. Hosts call this after adopting automation so an
// unrelated knob edit does not erase modulation until the wheel moves again.
engine_refresh_controllers :: proc(e: ^Engine) {
	if !e.has_patch {return}
	work := e.patch
	displacement: [patch.PARAMETER_COUNT]f32
	touched: [patch.PARAMETER_COUNT]bool
	for i in 0 ..< 2 {
		c := e.params.midi_ctrl[i]
		if !controller_target_valid(c.target) || c.cc < 0 {
			continue
		}
		top := len(patch.parameter_states(c.target)) - 1
		if top <= 0 {continue}
		// Contributions are collected before rounding. Two assignments aimed at
		// one knob are additive; applying each independently would make the second
		// silently overwrite the first.
		displacement[c.target] += c.amount * e.ctrl_value[i] * f32(top)
		touched[c.target] = true
	}
	for target in 0 ..< patch.PARAMETER_COUNT {
		if !touched[target] {continue}
		top := len(patch.parameter_states(target)) - 1
		base := resolved_position(target, e.patch.values[target])
		delta := displacement[target]
		moved := base + int(delta + (delta < 0 ? -0.5 : 0.5))
		work.values[target] = stored_for_position(target, clamp_int(moved, 0, top))
	}

	// Keep everything the voices are mid-note on; only the derived parameters
	// change. `engine_init` would reallocate the voice pool and cut the sound.
	e.params = bind_patch(work)
	// Pool size is topology chosen outside the real-time path. A controller may
	// move parameter 94's displayed value, but an audio callback cannot allocate
	// or free voices.
	if len(e.voices) > 0 {
		e.params.polyphony = len(e.voices)
	}
	// A controller is a live parameter edit. Shapes and envelope settings are
	// cached on the running LFOs and voices, so rebinding Engine_Params alone
	// would leave those destinations unchanged until the next note.
	for j in 0 ..< 2 {
		e.global_lfo[j].shape = e.params.lfo[j].shape
	}
	for i in 0 ..< len(e.voices) {
		voice_apply_params(&e.voices[i], &e.params, e.sample_rate)
	}
	engine_update_lfo_rates(e)
}

// The reference's destination menu does not offer the routing controls
// themselves. Enforcing that at the engine boundary also makes malformed patch
// data inert instead of allowing a controller to rewrite its own definition.
controller_target_valid :: proc(target: int) -> bool {
	if target < 0 || target >= patch.PARAMETER_COUNT {return false}
	return target != 50 && target != 51 && (target < 86 || target > 89)
}

// The stored integer that selects a position, the inverse of `resolved_position`.
stored_for_position :: proc(index, position: int) -> int {
	if stored, ok := patch.parameter_stored_at_position(index, position); ok {
		return stored
	}
	return position
}

// Recompute the LFO increments from the current parameters and tempo.
//
// Tempo sync (parameters 67 and 69) turns the rate parameter into a division of
// the beat, so the rate has to be recomputed when the tempo changes and not
// only when a parameter does.
engine_update_lfo_rates :: proc(e: ^Engine) {
	bpm := e.tempo_bpm > 0 ? e.tempo_bpm : 120.0
	for j in 0 ..< 2 {
		lp := &e.params.lfo[j]
		hz := lp.rate_hz
		if lp.tempo_sync && lp.sync_beats > 0 {
			// One cycle every `sync_beats` beats.
			hz = (bpm / 60.0) / lp.sync_beats
		}
		dsp.lfo_set_frequency(&e.global_lfo[j], hz, e.sample_rate)
		for i in 0 ..< len(e.voices) {
			dsp.lfo_set_frequency(&e.voices[i].lfo[j], hz, e.sample_rate)
		}
	}
}

engine_set_tempo :: proc(e: ^Engine, bpm: f32) {
	e.tempo_bpm = bpm > 0 ? bpm : 120.0
	engine_update_lfo_rates(e)
}

// -1..1.
engine_set_pitch_bend :: proc(e: ^Engine, bend: f32) {
	e.pitch_bend = dsp.clamp32(bend, -1, 1)
}

engine_note_in_key_range :: proc(note: int) -> bool {
	return note >= 0 && note < 128
}

engine_mark_key_down :: proc(e: ^Engine, note: int) {
	if !engine_note_in_key_range(note) {
		return
	}
	if !e.held_keys[note] {
		e.held_keys[note] = true
		e.held_notes += 1
	}
}

engine_mark_key_up :: proc(e: ^Engine, note: int) {
	if !engine_note_in_key_range(note) {
		return
	}
	if e.held_keys[note] {
		e.held_keys[note] = false
		if e.held_notes > 0 {
			e.held_notes -= 1
		}
	}
}

engine_find_gated_voice :: proc(e: ^Engine) -> ^Voice {
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.gate {
			return v
		}
	}
	return nil
}

// Find a voice for a new note.
//
// Order: the voice already holding this note, then any idle voice, then the
// oldest sounding one. Stealing the oldest is the conventional choice and the
// only one that keeps a held chord intact while a melody plays over it.
engine_allocate_voice :: proc(e: ^Engine, note: int) -> ^Voice {
	if len(e.voices) == 0 {
		return nil
	}

	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.note == note {
			return v
		}
	}
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if !v.active {
			return v
		}
	}

	oldest := &e.voices[0]
	for i in 1 ..< len(e.voices) {
		if e.voices[i].age < oldest.age {
			oldest = &e.voices[i]
		}
	}
	return oldest
}

// `velocity` is 0..1.
engine_note_on :: proc(e: ^Engine, note: int, velocity: f32) {
	if len(e.voices) == 0 {
		return
	}

	// With the arpeggiator running, a key press is a key press and not a note:
	// it joins the set the pattern is built from, and the pattern decides when
	// anything sounds. Starting a voice here as well would leave the key
	// droning under its own arpeggio.
	if e.params.arp_on {
		engine_mark_key_down(e, note)
		e.arp.velocity = velocity
		return
	}

	// Mono and legato collapse the pool to a single sounding voice. Legato
	// additionally keeps the envelopes running when a note arrives while another
	// key is still held, which is the difference between the two modes.
	legato := false
	legato_voice: ^Voice = nil
	switch e.params.play_mode {
	case .Poly:
		// Nothing to collapse.
	case .Mono:
		for i in 0 ..< len(e.voices) {
			if e.voices[i].active {
				voice_note_off(&e.voices[i])
			}
		}
	case .Legato:
		legato = e.held_notes > 0
		if legato {
			// A legato note continues the currently sounding voice instead of
			// taking a fresh pool slot. That preserves envelope level and oscillator
			// phase through the note change, and keeps polyphony > 1 from exposing a
			// zero-valued, never-configured voice.
			legato_voice = engine_find_gated_voice(e)
		}
		for i in 0 ..< len(e.voices) {
			v := &e.voices[i]
			if v.active && v != legato_voice {
				voice_note_off(v)
			}
		}
	}

	v := legato_voice
	if v == nil {
		v = engine_allocate_voice(e, note)
	}
	if v == nil {
		return
	}

	e.age += 1
	v.age = e.age

	seed := u32(e.age * 2654435761) ~ u32(note * 40503) ~ 0x9E3779B9

	voice_note_on(
		v,
		&e.params,
		note,
		velocity,
		e.sample_rate,
		seed,
		e.last_note,
		legato,
		&e.global_lfo,
	)

	e.last_note = f32(note)
	engine_mark_key_down(e, note)
}

// Sound a note without touching the held-key set.
//
// The arpeggiator needs exactly this and nothing else: the keys it plays from
// are already down, and marking its own steps as held would feed the sequence
// back into itself -- every step would add a key, the chord would grow without
// bound, and the pattern would never repeat.
//
// It is `engine_note_on` with the key bookkeeping and the mono/legato collapse
// removed. Those belong to a player pressing a key; an arpeggiator step is a
// note, and the pool allocates for it the same way it would for any other.
engine_start_voice :: proc(e: ^Engine, note: int, velocity: f32) {
	if len(e.voices) == 0 {
		return
	}
	v := engine_allocate_voice(e, note)
	if v == nil {
		return
	}

	e.age += 1
	v.age = e.age
	seed := u32(e.age * 2654435761) ~ u32(note * 40503) ~ 0x9E3779B9

	voice_note_on(
		v,
		&e.params,
		note,
		velocity,
		e.sample_rate,
		seed,
		e.last_note,
		false,
		&e.global_lfo,
	)
	e.last_note = f32(note)
}

// Start a self-releasing voice for a drum-rack one-shot. This is an engine
// gesture rather than a delayed Note Off in a UI: attack and decay retain their
// exact patch timing, and the voice moves into release when it reaches sustain.
engine_trigger :: proc(e: ^Engine, note: int, velocity: f32) {
	if len(e.voices) == 0 {return}
	if e.params.arp_on {
		// A rack hit is a sound, not a held key used to construct an arpeggio.
		engine_start_voice(e, note, velocity)
	} else {
		engine_note_on(e, note, velocity)
		engine_mark_key_up(e, note)
	}
	newest: ^Voice = nil
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.gate && v.note == note && (newest == nil || v.age > newest.age) {
			newest = v
		}
	}
	if newest != nil {newest.one_shot = true}
}

engine_note_off :: proc(e: ^Engine, note: int) {
	engine_mark_key_up(e, note)

	// The arpeggiator owns what is sounding, so releasing a key only removes it
	// from the set the pattern is built from. Silencing the matching voice here
	// too would cut a step short whenever it happened to be playing the octave
	// copy of a key that was just let go.
	if e.params.arp_on {
		return
	}

	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.gate && v.note == note {
			voice_note_off(v)
		}
	}
}

engine_all_notes_off :: proc(e: ^Engine) {
	for i in 0 ..< len(e.voices) {
		if e.voices[i].active {
			voice_note_off(&e.voices[i])
		}
	}
	e.held_notes = 0
	e.held_keys = {}
	arp_reset(&e.arp)
}

engine_active_voice_count :: proc(e: ^Engine) -> int {
	n := 0
	for i in 0 ..< len(e.voices) {
		if e.voices[i].active {
			n += 1
		}
	}
	return n
}

// Render `len(left)` samples. The buffers are written, not accumulated, and
// must be the same length.
//
// Nothing in here allocates: the voice pool, every voice's unison stack and
// every filter's state were sized in `engine_init`.
// Turn the bound delay and chorus parameters into the sample counts and rates
// the effects want.
//
// Kept out of the sample loop because the tempo-synced delay time depends on the
// tempo and the sample rate but not on the sample, and computing it per block is
// both cheaper and the only place the tempo is known to be stable.
effect_params :: proc(
	e: ^Engine,
) -> (
	eq: dsp.Equalizer_Params,
	eq_coefficients: dsp.Biquad_Coefficients,
	fx: dsp.Effect_Params,
	delay: dsp.Delay_Params,
	chorus: dsp.Chorus_Params,
) {
	p := &e.params
	bpm := e.tempo_bpm > 0 ? e.tempo_bpm : 120.0

	eq.freq_hz = p.eq_freq_hz
	eq.gain_db = p.eq_gain_db
	eq.q = p.eq_q
	eq.tone = p.eq_tone
	// The biquad's coefficients are derived once per block rather than per sample.
	// They depend on the parameters and the sample rate, neither of which moves
	// inside a block, and the derivation costs a sine, a cosine and a power.
	eq_coefficients = dsp.peaking_coefficients(eq.freq_hz, eq.gain_db, eq.q, e.sample_rate)

	// The effect unit, derived per block for the same reason as the biquad above:
	// the decimator's step and the compressor's attack each cost a power, and
	// nothing they depend on moves inside a block.
	fx.enabled = p.effect_on
	fx.type = p.effect_type
	fx.ctl1 = p.effect_ctl1
	fx.ctl2 = p.effect_ctl2
	fx.level = dsp.clamp32(p.effect_level, 0, 1)
	fx.hold_samples = dsp.effect_hold_samples(p.effect_ctl1_steps, e.sample_rate)
	dsp.effect_derive(&fx)

	base_ms: f32
	if p.delay_beats > 0 {
		base_ms = p.delay_beats * 60000.0 / bpm
	} else {
		base_ms = p.delay_fixed_ms
	}

	// Parameter 83 offsets the two channels around that base. The buffer was
	// sized for the largest offset the parameter can hold, so this only has to
	// stay non-negative.
	to_samples :: proc(ms, sample_rate: f32, limit: int) -> f32 {
		samples := ms * 0.001 * sample_rate
		return dsp.clamp32(samples, 1.0, f32(max(limit - 2, 2)))
	}

	delay.left_samples = to_samples(base_ms + p.delay_left_ms, e.sample_rate, len(e.delay_left))
	delay.right_samples = to_samples(base_ms + p.delay_right_ms, e.sample_rate, len(e.delay_right))
	delay.feedback = p.delay_feedback
	delay.dry_wet = p.delay_dry_wet
	delay.tone = p.delay_tone
	delay.mode = p.delay_mode

	chorus.stages = p.chorus_stages
	chorus.delay_samples = to_samples(p.chorus_delay_ms, e.sample_rate, len(e.chorus_left))
	chorus.depth = p.chorus_depth
	chorus.rate_hz = p.chorus_rate_hz
	chorus.feedback = p.chorus_feedback
	chorus.level = p.chorus_level
	return
}

engine_process :: proc(e: ^Engine, left, right: []f32) {
	n := min(len(left), len(right))

	eq_params, eq_coefficients, fx_params, delay_params, chorus_params := effect_params(e)

	// Smoothed parameters are applied to a working copy so the bound patch
	// values stay the target rather than being overwritten by their own
	// smoothed output.
	//
	// The copy is made once per block rather than once per sample. It is 416
	// bytes, and copying it 48000 times a second was costing more than a whole
	// voice: `e.params` cannot change during a block -- only the host can
	// change it, and it does so between blocks -- so the only fields that need
	// rewriting per sample are the three smoothed ones below.
	params := e.params

	for i in 0 ..< n {
		// The free-running LFOs advance once per sample for the whole engine,
		// so every non-key-synced voice reads the same value.
		lfo_value: [2]f32
		for j in 0 ..< 2 {
			lfo_value[j] = dsp.lfo_process(&e.global_lfo[j])
		}

		params.filter_cutoff_state = smoother_process(&e.cutoff_smooth, e.params.filter_cutoff_state)
		params.amp_gain = smoother_process(&e.gain_smooth, e.params.amp_gain)
		params.pan = smoother_process(&e.pan_smooth, e.params.pan)

		// Per sample, and only when it is switched on. A step boundary rounded
		// to the block would land a 1/24-beat step up to a whole step late at
		// 512 frames, which is heard as swing the patch does not have.
		if params.arp_on {
			arp_process(e, &params)
		}

		sum_l: f32 = 0
		sum_r: f32 = 0

		for vi in 0 ..< len(e.voices) {
			v := &e.voices[vi]
			if !v.active {
				continue
			}
			l, r := voice_process(v, &params, e.sample_rate, e.pitch_bend, lfo_value)
			sum_l += l
			sum_r += r
		}

		// -- effects, on the summed voices ---------------------------------
		//
		// Delay before chorus, which is the order the reference's own panel and
		// manual list them in. Both run whether or not they are switched on: a
		// line that has been idle still holds whatever was last written to it,
		// and switching an effect on mid-note would otherwise flush that out as
		// a burst. Their parameter structs are rebuilt per sample from a value
		// that only changes per block, which costs nothing measurable and keeps
		// the tempo-dependent times honest when the host moves the tempo.
		out_l := dsp.sanitize(sum_l)
		out_r := dsp.sanitize(sum_r)

		// Equaliser first, then delay, then chorus, which is the order the
		// reference's own panel and manual list them in. It matters: equalising
		// before the delay colours what goes into the repeats, and after it would
		// colour the repeats themselves.
		out_l, out_r = dsp.equalizer_process(
			&e.equalizer, out_l, out_r, &eq_params, &eq_coefficients, e.sample_rate,
		)

		// The effect unit sits between the equaliser and the delay, which is where
		// the manual's section order puts it. The section carries its own dry/wet
		// level, so unlike the delay and chorus below it does not need an
		// enable test out here: at level zero it returns its input untouched, and
		// the reference behaves the same way.
		out_l, out_r = dsp.effect_process(&e.effect, out_l, out_r, &fx_params, e.sample_rate)

		wet_l, wet_r := dsp.delay_process(&e.delay, out_l, out_r, &delay_params, e.sample_rate)
		if params.delay_on {
			out_l, out_r = wet_l, wet_r
		}

		chorused_l, chorused_r := dsp.chorus_process(
			&e.chorus, out_l, out_r, &chorus_params, e.sample_rate,
		)
		if params.chorus_on {
			out_l, out_r = chorused_l, chorused_r
		}

		// A soft clip rather than a hard one: a stack of unison voices summing
		// in phase can exceed 1.0 on a loud patch, and the contract asks for a
		// stable output, not a truncated one.
		left[i] = dsp.soft_clip(out_l)
		right[i] = dsp.soft_clip(out_r)
	}
}
