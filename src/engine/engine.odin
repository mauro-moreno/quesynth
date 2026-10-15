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

// The output gain moves to a new value in a straight line over one render chunk, 256
// samples, from the first sample after the change. That ramp sits ahead of the effects: a
// gain change reaches the echo a delay later, as measured (`s1probe arch gainstep`, where
// the reference's gain falls linearly across 256 samples).
//
// A second stage, behind the effects, is the fade-in of the first note after a load.
// It halves its distance to full every millisecond, 48 samples at 48 kHz, which is a time
// constant of 69.25 samples.
// The effects see the unfaded signal -- the chorus, the equaliser, the effect unit and
// the delay all take the dry output divided by the fade -- and only the output carries
// it. It starts at -0.0023 and not at zero: the reference's first note after a load
// follows 1 - exp(-(n + 0.84) / 69.25) times a linear ramp of exactly 24 samples, where
// this was 1 - exp(-(n + 1) / 69.48), and the difference is 0.8 parts in a thousand at
// its worst.
GAIN_SMOOTHER_HALF_LIFE_SECONDS :: f32(0.001)
GAIN_SMOOTHER_START :: f32(-0.002311)

// Parameter 35's first state, "0.1 msec", the shortest delay time.
DELAY_SHORTEST_MS :: f32(0.1)

// A full wheel travel, from the rest position to the top, takes about 42 ms: the
// reference moves the bend about four 14-bit units a sample, 23.75 full scales a
// second as measured. The rate is in wheel units, so the time to bend a given number of
// semitones depends on the wheel's travel and not on parameter 40's range: the same
// 33.6 ms from 10 to 90% at a range of 2, 12 and 24.
PITCH_BEND_SLEW_PER_SECOND :: f32(23.75)

// Oscillator 2's pitch edit slides linearly over fifty milliseconds whatever its size
// (39.7 ms from 10 to 90% for three semitones as for twelve). The other pitch controls,
// key shift, fine tune and master tune, move at once.
PITCH_SLIDE_SECONDS :: f32(0.05)

Pitch_Slide :: struct {
	value:   f32,
	start:   f32,
	target:  f32,
	counter: int,
}

pitch_slide_set :: proc(s: ^Pitch_Slide, value: f32, sample_rate: f32) {
	s^ = {value = value, start = value, target = value, counter = int(PITCH_SLIDE_SECONDS * sample_rate)}
}

// Aim at a new target: from wherever it has got to, over the full time.
pitch_slide_aim :: proc(s: ^Pitch_Slide, target: f32) {
	if target != s.target {
		s.start = s.value
		s.target = target
		s.counter = 0
	}
}

pitch_slide_step :: proc(s: ^Pitch_Slide, sample_rate: f32) -> f32 {
	total := max(int(PITCH_SLIDE_SECONDS * sample_rate), 1)
	if s.counter < total {
		s.counter += 1
		s.value = s.start + (s.target - s.start) * f32(s.counter) / f32(total)
	} else {
		s.value = s.target
	}
	return s.value
}

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

	gain_smooth:   Ramp,
	load_fade:     Smoother,
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
	// Where each of the two assigned controllers currently sits: 0..1 for a
	// control change or aftertouch, -1..1 for pitch bend.
	ctrl_value:    [2]f32,

	effect:        dsp.Effect,
	equalizer:     dsp.Equalizer,
	delay:         dsp.Delay,
	chorus:        dsp.Chorus,
	delay_left:    []f32,
	delay_right:   []f32,
	chorus_left:   []f32,
	chorus_right:  []f32,

	// -1..1, in units of `Engine_Params.pitch_bend_range`: where the wheel is. The
	// pitch follows it at a fixed rate in wheel units, whatever the bend range, and
	// `pitch_bend_applied` is where it has got to.
	pitch_bend:  f32,
	pitch_bend_applied: f32,
	// Oscillator 2's pitch, which slides to a new value over fifty milliseconds when
	// it is edited.
	osc2_pitch:  Pitch_Slide,
	tempo_bpm:   f32,

	// Monotonic, used for voice stealing and for seeding each voice's noise.
	age:         u64,
	// The last note started, for portamento and for legato detection.
	last_note:   f32,
	// Keys physically held by the caller. This is deliberately independent of
	// voice gate state: mono and legato mode may release a voice while its key is
	// still down, and repeated note-on must not double-count that key.
	held_notes:  int,
	// The voice pool as the reference keeps it: `polyphony` slots, each holding one
	// layer of one note, handed out round-robin from the one after the last. See
	// `engine_acquire_voice`.
	slots:         [MAX_POLYPHONY]Pool_Slot,
	slot_next:     int,
	slot_stamp:    u64,
	pending_slots: [MAX_UNISON]int,

	// The arpeggiator step clock and what it currently has sounding. Idle,
	// and costing one branch a sample, when parameter 59 is off.
	arp:         Arpeggiator,
	held_keys:   [128]bool,
	// When each held key went down, from `key_clock`. Mono and legato fall
	// back to the newest key still held when the sounding one is released, so
	// press order has to be kept and not only the set; a repeated note-on of
	// a held key makes it the newest. Meaningless for a key not in `held_keys`.
	key_order:   [128]u64,
	key_clock:   u64,

	// The reference's band-limited oscillator tables; see `dsp.Wavetable_Bank`.
	// About 650 KB. By default the engine builds its own on the first
	// `engine_init` and keeps it across every later one -- a re-init can happen
	// on the audio thread when the voice pool resizes, and building there would
	// be both an allocation and a few milliseconds of work. A host running
	// several engines builds one bank and hands it to each with
	// `engine_share_wavetables`; the engine then only borrows it.
	wavetables:        ^dsp.Wavetable_Bank,
	wavetables_shared: bool,
}

// Allocate and configure the engine. This is the only procedure here that
// allocates.
engine_init :: proc(e: ^Engine, params: Engine_Params, sample_rate: f32) {
	engine_release_buffers(e)

	if e.wavetables == nil {
		e.wavetables = new(dsp.Wavetable_Bank)
		dsp.wavetable_build(e.wavetables)
		e.wavetables_shared = false
	}

	e.sample_rate = sample_rate > 0 ? sample_rate : DEFAULT_SAMPLE_RATE
	e.params = params
	e.tempo_bpm = 120.0
	e.pitch_bend = 0
	e.pitch_bend_applied = 0
	pitch_slide_set(&e.osc2_pitch, params.osc2_semitones, e.sample_rate)
	e.age = 0
	e.last_note = 60.0
	e.held_notes = 0
	e.held_keys = {}
	e.key_order = {}
	e.key_clock = 0
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

	e.slots = {}
	e.slot_next = 0
	e.slot_stamp = 0
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		v^ = {}
		voice_set_wavetables(v, e.wavetables)
	}

	for j in 0 ..< 2 {
		dsp.lfo_init(&e.global_lfo[j], 0x6C_F0_0001 + u32(j))
		e.global_lfo[j].shape = params.lfo[j].shape
	}

	// The output starts at zero and rises to full, as the reference's does when it is
	// loaded: the first note after a load comes in under a one-pole of about 70
	// samples, which a note on a settled engine does not. That is the whole of what
	// looked like a per-note onset factor of 1 - exp(-n / 69): a second note, on the
	// same voice or another, reaches full level at once. The gain itself starts at the
	// patch's value, so only the fade is heard.
	ramp_init(&e.gain_smooth, params.amp_gain)
	smoother_init_half_life(&e.load_fade, GAIN_SMOOTHER_START, GAIN_SMOOTHER_HALF_LIFE_SECONDS, e.sample_rate)
	smoother_init(&e.pan_smooth, params.pan, SMOOTHING_SECONDS, e.sample_rate)

	engine_update_lfo_rates(e)
}

engine_destroy :: proc(e: ^Engine) {
	engine_release_buffers(e)
	engine_drop_wavetables(e)
}

// Borrow a bank the host built and owns, so that many engines play from one set
// of tables rather than each holding its own copy. The bank must be built and
// must outlive every engine that borrows it. Call it before `engine_init`, or
// after: a pool that already exists is pointed at the bank straight away.
engine_share_wavetables :: proc(e: ^Engine, bank: ^dsp.Wavetable_Bank) {
	if bank == nil || !bank.ready || bank == e.wavetables {
		return
	}
	engine_drop_wavetables(e)
	e.wavetables = bank
	e.wavetables_shared = true
	for i in 0 ..< len(e.voices) {
		voice_set_wavetables(&e.voices[i], bank)
	}
}

// Free the engine's own bank. A borrowed one is only let go, never freed.
engine_drop_wavetables :: proc(e: ^Engine) {
	if e.wavetables != nil && !e.wavetables_shared {
		free(e.wavetables)
	}
	e.wavetables = nil
	e.wavetables_shared = false
}

// Everything `engine_init` reallocates. The wavetables are not among it: they do
// not depend on the patch, the pool size or the sample rate.
engine_release_buffers :: proc(e: ^Engine) {
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
// change size under a sounding note; that still goes the long way round, unless
// `keep_voice_pool` says it may not.
// `snap` is the difference between loading a patch and turning a knob.
//
// The smoothed parameters -- gain, pan -- glide to their target, which is
// what stops a knob from stepping audibly. Across a *patch change* that glide is
// wrong: the new sound would sweep in from the old one's cutoff over the first
// tenth of a second, which is both audible and not what the patch is. Snapping
// them is what `smoother_reset` and `ramp_init` exist for.
//
// What a patch change does not repeat is the first note's fade-in (`load_fade`): that
// belongs to a freshly loaded instance, and starts in `engine_init` only.
//
// The cost of getting this backwards is not obvious from listening to one note,
// which is why it is worth stating: rendered against the reference, a patch loaded
// without snapping came out at a peak of 0.0519 where the same patch loaded fresh
// gives 0.0333, because the note began under the wrong filter.
//
// A controller's position is the one piece of performance state a patch change
// has to decide about, and it belongs to the physical controller, not to the
// patch. A slot that still listens to the same CC number keeps where that
// controller sits: the wheel has not moved, and forgetting it would make the
// new patch jump the next time it is touched. A slot reassigned to another
// number starts at zero, because the old number's position says nothing about
// a controller that has not been heard from, and carrying it over would bend
// the new patch by a wheel nobody is holding. The plugin hosts' apply_params
// follow the same rule, and the standalone daemon relies on it for every load.
//
// `keep_voice_pool` is for a caller on the audio thread, which is where the
// standalone daemon replaces a patch. Resizing goes through `engine_init`,
// which allocates and frees and wipes every voice, the held keys and the pitch
// bend: an allocator on the audio path and a cut to the key that is down, the
// two things a patch change there must never do. So the pool keeps the size it
// was given before the stream started, and parameter 94 is what the daemon
// treats it as -- configuration, not patch state. The patch still records its
// own value for it, so a snapshot or a save reports the patch as it was
// written. Only an engine with no pool at all is given one.
engine_apply_patch :: proc(e: ^Engine, p: patch.Patch, snap := false, keep_voice_pool := false) {
	params := bind_patch(p)
	previous_ctrl := e.params.midi_ctrl
	e.patch = p
	e.has_patch = true
	for i in 0 ..< 2 {
		if !midi_ctrl_same_source(previous_ctrl[i], params.midi_ctrl[i]) {
			e.ctrl_value[i] = 0
		}
	}

	count := clamp_int(params.polyphony, 1, MAX_POLYPHONY)
	if e.voices == nil || (!keep_voice_pool && count != len(e.voices)) {
		engine_init(e, params, e.sample_rate)
		engine_refresh_controllers(e)
		return
	}

	e.params = params
	engine_refresh_controllers(e)

	if snap {
		// After the controllers, not before: a controller kept across the
		// change displaces the target, and snapping to the patch's undisplaced
		// value would sweep the new sound from there to where the wheel sits.
		smoother_reset(&e.pan_smooth, e.params.pan)
		ramp_init(&e.gain_smooth, e.params.amp_gain)
		pitch_slide_set(&e.osc2_pitch, e.params.osc2_semitones, e.sample_rate)

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
		if c.source != .Control || c.cc != cc || c.target < 0 {
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

// MIDI channel pressure (aftertouch), 0..127. An assignment whose source is
// 53248 (0xD000) takes it exactly as it would a control change at that value;
// see `Midi_Source`.
engine_channel_pressure :: proc(e: ^Engine, value: int) {
	engine_route_source(e, .Pressure, f32(clamp_int(value, 0, 127)) / 127.0)
}

// Move every assignment listening to `source` to `value` and rebind.
engine_route_source :: proc(e: ^Engine, source: Midi_Source, value: f32) {
	if !e.has_patch {
		return
	}
	changed := false
	for i in 0 ..< 2 {
		c := e.params.midi_ctrl[i]
		if c.source != source || c.target < 0 {
			continue
		}
		e.ctrl_value[i] = value
		changed = true
	}
	if changed {
		engine_refresh_controllers(e)
	}
}

// Whether two assignments listen to the same physical controller, which is
// what decides if a controller's position survives a patch change. The hosts
// that keep their own copy of that rule ask this rather than comparing
// controller numbers, which every non-CC source shares as -1.
midi_ctrl_same_source :: proc(a, b: Midi_Control) -> bool {
	return a.source == b.source && a.cc == b.cc
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
		if !controller_target_valid(c.target) || c.source == .None {
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

// Set one stored parameter and rebind, keeping every sounding voice.
//
// This is the engine side of an external control edit: the protocol's
// parameter.set ends here. It deliberately takes the same path a MIDI control
// change already does -- write the stored value into the patch and rebuild the
// live parameters through `engine_refresh_controllers`, which reaches no
// allocator and never resizes the voice pool, so it is safe on the audio
// thread. `engine_apply_patch` is the wrong tool for a single control: it can
// reallocate the pool and cut the sound. That is for loading a patch.
engine_set_stored :: proc(e: ^Engine, index, stored: int) {
	if index < 0 || index >= patch.PARAMETER_COUNT {return}
	if !e.has_patch {return}
	e.patch.values[index] = stored
	engine_refresh_controllers(e)
}

// The stored integer currently held for a parameter -- the value a get returns.
// Reads the base patch, not the controller-displaced live block, so a get
// reflects what was set rather than where a moving wheel happens to sit.
engine_patch_value :: proc(e: ^Engine, index: int) -> int {
	if index < 0 || index >= patch.PARAMETER_COUNT {return 0}
	return e.patch.values[index]
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
	}
}

engine_set_tempo :: proc(e: ^Engine, bpm: f32) {
	e.tempo_bpm = bpm > 0 ? bpm : 120.0
	engine_update_lfo_rates(e)
}

// -1..1. Also the position of any assignment whose source is pitch bend,
// 57344 (0xE000), which is bipolar about the rest position; see
// `Midi_Source`. The pitch is still bent by parameter 40's range too. Whether
// the reference does both at once is not measured: its probe sets the range
// to zero.
engine_set_pitch_bend :: proc(e: ^Engine, bend: f32) {
	e.pitch_bend = dsp.clamp32(bend, -1, 1)
	engine_route_source(e, .Bend, e.pitch_bend)
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
		// The two LFOs are shared by every voice, and a key-synced one restarts only
		// when the key just pressed is the only one held: a key pressed over another
		// leaves it running, whatever is sounding.
		if e.held_notes == 1 {
			for j in 0 ..< 2 {
				if e.params.lfo[j].key_sync {
					dsp.lfo_retrigger(&e.global_lfo[j])
				}
			}
		}
	}
	e.key_clock += 1
	e.key_order[note] = e.key_clock
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

// The most recently pressed key still held, if any.
engine_newest_held_key :: proc(e: ^Engine) -> (note: int, ok: bool) {
	newest: u64 = 0
	for key in 0 ..< len(e.held_keys) {
		if e.held_keys[key] && (!ok || e.key_order[key] > newest) {
			note = key
			newest = e.key_order[key]
			ok = true
		}
	}
	return
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

// One voice of the pool: a layer of a note, and when it was handed out.
Pool_Slot :: struct {
	used:  bool,
	// Index into `Engine.voices`, or -1 while the slot is being filled.
	voice: int,
	layer: int,
	// The note's `age`, so a slot whose voice has since been reused by another
	// note is recognised as stale.
	age:   u64,
	stamp: u64,
}

engine_slot_live :: proc(e: ^Engine, index: int) -> bool {
	s := &e.slots[index]
	if !s.used {
		return false
	}
	if s.voice < 0 {
		return true
	}
	v := &e.voices[s.voice]
	return v.active && v.age == s.age && v.live_layers & (u32(1) << u32(s.layer)) != 0
}

// A slot is free when nothing in it is held by a key: empty, stale, or a note
// that has been released and is only ringing out.
engine_slot_free :: proc(e: ^Engine, index: int) -> bool {
	if !engine_slot_live(e, index) {
		return true
	}
	s := &e.slots[index]
	return s.voice >= 0 && !e.voices[s.voice].gate
}

engine_take_slot :: proc(e: ^Engine, index: int) {
	if engine_slot_live(e, index) && e.slots[index].voice >= 0 {
		s := &e.slots[index]
		v := &e.voices[s.voice]
		v.live_layers &= ~(u32(1) << u32(s.layer))
		if v.live_layers == 0 {
			v.active = false
		}
	}
	e.slots[index].used = false
}

// The reference's pool is counted in layers, not notes: polyphony is the number
// of voices, and a note takes one per unison layer. A layer takes the first slot
// not held by a key, scanning round-robin from the slot after the last one handed
// out, so a note in release is free the moment the scan reaches it; when every
// slot is held, it takes the oldest. With 3 voices and 2 layers a third note finds
// one voice free, steals the oldest voice for its second layer, and ends with two
// layers while the first keeps none (`s1probe arch voices`: poly 3 x unison 2 reads
// 0 / 1 / 2 layers for three notes, poly 7 x 4 reads 0 / 3 / 4). A note wanting
// more layers than there are voices keeps only its last ones.
engine_acquire_voice :: proc(e: ^Engine, note: int, same: ^Voice) -> ^Voice {
	poly := len(e.voices)
	wanted := clamp_int(e.params.unison_voices, 1, MAX_UNISON)
	keep := min(wanted, poly)

	// A note pressed again while it still sounds gives its own slots back first, and takes
	// them again before looking anywhere else: scanning on from `slot_next` could reach a
	// released, ringing note before them and cut it off while its own slot sat unused.
	freed: [MAX_POLYPHONY]int
	freed_count := 0
	if same != nil {
		for i in 0 ..< poly {
			s := &e.slots[i]
			if s.used && s.voice >= 0 && e.voices[s.voice].age == s.age && &e.voices[s.voice] == same {
				s.used = false
				freed[freed_count] = i
				freed_count += 1
			}
		}
	}

	for k in 0 ..< keep {
		chosen := -1
		if k < freed_count {
			chosen = freed[k]
		}
		for step in 0 ..< poly {
			if chosen >= 0 {break}
			index := (e.slot_next + step) % poly
			if engine_slot_free(e, index) {
				chosen = index
				break
			}
		}
		if chosen < 0 {
			for index in 0 ..< poly {
				s := &e.slots[index]
				if s.voice >= 0 && (chosen < 0 || s.stamp < e.slots[chosen].stamp) {
					chosen = index
				}
			}
		}
		engine_take_slot(e, chosen)
		e.slot_stamp += 1
		e.slots[chosen] = {used = true, voice = -1, stamp = e.slot_stamp}
		e.pending_slots[k] = chosen
		e.slot_next = (chosen + 1) % poly
	}

	if same != nil {
		return same
	}
	for i in 0 ..< poly {
		if !e.voices[i].active {
			return &e.voices[i]
		}
	}
	return nil
}

// Seat the note in the slots `engine_acquire_voice` picked.
engine_settle_layers :: proc(e: ^Engine, v: ^Voice) {
	wanted := v.unison_count
	keep := min(wanted, len(e.voices))
	index := -1
	for i in 0 ..< len(e.voices) {
		if &e.voices[i] == v {
			index = i
		}
	}
	v.live_layers = 0
	for k in 0 ..< keep {
		layer := wanted - keep + k
		slot := &e.slots[e.pending_slots[k]]
		slot.voice = index
		slot.layer = layer
		slot.age = v.age
		v.live_layers |= u32(1) << u32(layer)
	}
}

// Find a voice for a new note.
//
// The voice already holding this note is reused, and the layers it needs are
// taken from the pool as above. If the pool somehow has no entry free the oldest
// sounding voice is taken.
engine_allocate_voice :: proc(e: ^Engine, note: int) -> ^Voice {
	if len(e.voices) == 0 {
		return nil
	}

	same: ^Voice
	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.note == note {
			same = v
			break
		}
	}
	if v := engine_acquire_voice(e, note, same); v != nil {
		return v
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

	// Mono and legato collapse the pool to a single sounding voice. A key
	// pressed while another is held moves that voice to the new key rather
	// than starting a note; see `engine_move_line`.
	switch e.params.play_mode {
	case .Poly:
		// Nothing to collapse.
	case .Mono, .Legato:
		if e.held_notes > 0 {
			if line := engine_find_gated_voice(e); line != nil {
				engine_mark_key_down(e, note)
				engine_move_line(e, line, note, velocity)
				return
			}
		}
		for i in 0 ..< len(e.voices) {
			if e.voices[i].active {
				voice_note_off(&e.voices[i])
			}
		}
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
		.Fresh,
		false,
	)
	engine_settle_layers(e, v)

	e.last_note = f32(note)
	engine_mark_key_down(e, note)
}

// Move the sounding mono or legato voice to another key: a new key pressed
// over a held one, or the fallback when the sounding key is released and
// another is still down. Measured in the reference with `s1probe behavior
// keys`: both take the same path, mono restarting the amplitude and filter
// attacks from their current level and legato leaving them alone (see
// `Note_Start`).
//
// Every move is an overlap -- a key is held across it by construction -- so
// auto portamento glides in mono as well as in legato. The reference does:
// mono, portamento 64, auto on, 72 over a held 60 reads 62.34, 65.00 and
// 71.96 at +5, +30 and +300 ms, and falling back to 60 glides the same way.
//
// The voice keeps its velocity on a fallback: the key it returns to was
// struck before, and what level it was struck at is not tracked. Whether the
// reference re-reads it has not been measured.
engine_move_line :: proc(e: ^Engine, v: ^Voice, note: int, velocity: f32) {
	legato := e.params.play_mode == .Legato
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
		legato ? .Legato : .Retrigger,
		true,
	)
	e.last_note = f32(note)
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
		.Fresh,
		false,
	)
	engine_settle_layers(e, v)
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
		if !(v.active && v.gate && v.note == note) {
			continue
		}
		// Mono and legato return to the newest key still held, which the
		// reference does in both modes: releasing 67 over a held 60 plays 60
		// again, where this used to fall silent.
		if e.params.play_mode != .Poly {
			if held, ok := engine_newest_held_key(e); ok {
				engine_move_line(e, v, held, v.velocity)
				continue
			}
		}
		voice_note_off(v)
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

// The size of the voice pool -- the most voices this engine can sound at once.
// Fixed in engine_init and never grown, so reading it as a metric is stable.
engine_max_voices :: proc(e: ^Engine) -> int {
	return len(e.voices)
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


	// The reference's delay lengths are whole samples: the beat division's and then
	// parameter 83's offset, each truncated, and added. At 120 bpm the divisions are
	// whole already, and the offsets measured as whole numbers at every position. A
	// length that is a whole number in exact arithmetic must not fall a sample short
	// to float rounding, so the product is taken in double precision with a margin.
	// The first state, "0.1 msec", is not a base time that the offset adds to but a
	// floor under it: four samples with no offset, and the offset itself once that
	// is longer.
	to_whole :: proc(samples: f64) -> f32 {
		return f32(int(samples + 1.0e-3))
	}
	whole_length :: proc(beats, tempo_bpm, offset_ms, sample_rate: f32, length: int) -> f32 {
		offset := to_whole(f64(offset_ms) * 0.001 * f64(sample_rate))
		samples: f32
		if beats > 0 {
			samples = to_whole(f64(beats) * 60.0 * f64(sample_rate) / f64(tempo_bpm)) + offset
		} else {
			samples = max(to_whole(f64(DELAY_SHORTEST_MS) * 0.001 * f64(sample_rate)), offset)
		}
		return dsp.clamp32(samples, 1.0, f32(max(length - 2, 2)))
	}

	delay.left_samples = whole_length(p.delay_beats, bpm, p.delay_left_ms, e.sample_rate, len(e.delay_left))
	delay.right_samples = whole_length(p.delay_beats, bpm, p.delay_right_ms, e.sample_rate, len(e.delay_right))
	delay.feedback = p.delay_feedback
	delay.dry_gain = p.delay_dry_gain
	delay.wet_gain = p.delay_wet_gain
	delay.tone = p.delay_tone
	delay.mode = p.delay_mode

	chorus.stages = p.chorus_stages
	chorus.delay_samples = dsp.clamp32(p.chorus_delay_seconds * e.sample_rate, 1.0, f32(max(len(e.chorus_left) / 2 - 2, 2)))
	chorus.depth = p.chorus_depth
	chorus.rate_hz = p.chorus_rate_hz
	chorus.feedback = p.chorus_feedback
	chorus.level = p.chorus_level
	return
}

// What moves once a sample whether anything sounds or not: the smoothed gain, pan
// and oscillator 2 pitch, the load fade, the bend, and the free-running LFOs, which
// advance once a sample for the whole engine so every voice reads the same value.
engine_step_controls :: proc(
	e: ^Engine,
	params: ^Engine_Params,
) -> (
	lfo_value: [2]f32,
	lfo_ramped: [2]f32,
	load_fade: f32,
) {
	for j in 0 ..< 2 {
		lfo_value[j] = dsp.lfo_process(&e.global_lfo[j])
		lfo_ramped[j] = e.global_lfo[j].ramped
	}

	params.amp_gain = ramp_process(&e.gain_smooth, e.params.amp_gain, CHUNK_FRAMES)
	load_fade = smoother_process(&e.load_fade, 1)
	params.pan = smoother_process(&e.pan_smooth, e.params.pan)
	params.osc2_semitones = pitch_slide_step(&e.osc2_pitch, e.sample_rate)
	bend_step := PITCH_BEND_SLEW_PER_SECOND / e.sample_rate
	if abs(e.pitch_bend - e.pitch_bend_applied) <= bend_step {
		e.pitch_bend_applied = e.pitch_bend
	} else {
		e.pitch_bend_applied += e.pitch_bend > e.pitch_bend_applied ? bend_step : -bend_step
	}
	return
}

// The whole of a block in which nothing can sound, going into effects that hold
// nothing. Kept out of `engine_process` so that the loop that renders voices is
// compiled as it was without it.
engine_render_silence :: #force_no_inline proc(
	e: ^Engine,
	params: ^Engine_Params,
	chorus_params: ^dsp.Chorus_Params,
	left, right: []f32,
	n: int,
) {
	chunk := Chunk{0, min(CHUNK_FRAMES, n)}
	for i in 0 ..< n {
		if chunk.position >= chunk.length {
			chunk = Chunk{0, min(CHUNK_FRAMES, n - i)}
			dsp.chorus_begin_chunk(&e.chorus)
		}
		_, _, load_fade := engine_step_controls(e, params)
		if params.chorus_on {
			dsp.chorus_process_silence(&e.chorus, chorus_params, e.sample_rate)
		}
		left[i] = dsp.soft_clip(0 * load_fade)
		right[i] = dsp.soft_clip(0 * load_fade)
		chunk.position += 1
	}
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
	// rewriting per sample are the smoothed ones below: the gain, the pan and
	// oscillator 2's pitch.
	params := e.params

	dsp.chorus_begin_block(&e.chorus, params.chorus_on)
	// Only a note event or the arpeggiator starts a voice, so with the arpeggiator
	// off and nothing sounding at the top of the block, nothing sounds in it and the
	// pool is not scanned sample by sample.
	sounding := params.arp_on || engine_active_voice_count(e) > 0
	pitch_slide_aim(&e.osc2_pitch, params.osc2_semitones)
	chunk := Chunk{0, min(CHUNK_FRAMES, n)}
	dsp.chorus_begin_chunk(&e.chorus)

	// A block in which nothing can sound, going into effects that hold nothing, is
	// silence from end to end; see the same test below, sample by sample.
	if !sounding &&
	   !fx_params.enabled &&
	   dsp.equalizer_is_silent(&e.equalizer, &eq_params) &&
	   dsp.delay_is_silent(&e.delay) &&
	   (!params.chorus_on || dsp.chorus_is_silent(&e.chorus)) {
		engine_render_silence(e, &params, &chorus_params, left, right, n)
		return
	}

	for i in 0 ..< n {
		if chunk.position >= chunk.length {
			chunk = Chunk{0, min(CHUNK_FRAMES, n - i)}
			dsp.chorus_begin_chunk(&e.chorus)
		}
		lfo_value, lfo_ramped, load_fade := engine_step_controls(e, &params)

		// Per sample, and only when it is switched on. A step boundary rounded
		// to the block would land a 1/24-beat step up to a whole step late at
		// 512 frames, which is heard as swing the patch does not have.
		if params.arp_on {
			age_before := e.age
			sounding_before := e.arp.sounding
			arp_process(e, &params)
			// A step that starts a note, or one whose gate closes, starts a chunk, as a
			// note-on or note-off event does: the amplitude ramp otherwise keeps heading
			// for the gate-on level to the end of the chunk and the release starts late.
			if e.age != age_before || e.arp.sounding != sounding_before {
				chunk = Chunk{0, min(CHUNK_FRAMES, n - i)}
				dsp.chorus_begin_chunk(&e.chorus)
			}
		}

		sum_l: f32 = 0
		sum_r: f32 = 0
		voiced := false

		for vi in 0 ..< len(e.voices) {
			if !sounding {
				break
			}
			v := &e.voices[vi]
			if !v.active {
				continue
			}
			voiced = true
			l, r := voice_process(v, &params, e.sample_rate, e.pitch_bend_applied, lfo_value, lfo_ramped, chunk)
			sum_l += l
			sum_r += r
		}

		// -- effects, on the summed voices ---------------------------------
		//
		// Delay before chorus, which is the order the reference's own panel and
		// manual list them in. The delay runs whether or not it is switched on: a
		// line that has been idle still holds whatever was last written to it,
		// and switching it on mid-note would otherwise flush that out as a burst.
		// The chorus runs only while it is on, and clears its lines when it is
		// switched on (`chorus_begin_block`), so it starts from silence either way.
		// Their parameter structs are rebuilt per block from values that only change
		// per block, which keeps the tempo-dependent times honest when the host moves
		// the tempo.
		out_l := dsp.sanitize(sum_l)
		out_r := dsp.sanitize(sum_r)

		// Silence into effects that hold nothing: every section would return zero
		// and write zeros into lines of zeros, which read the same from wherever
		// their write heads stand, so only the chorus's oscillator has to move. The
		// effect unit carries state that runs without input, so it has to be off.
		if !voiced &&
		   !fx_params.enabled &&
		   dsp.equalizer_is_silent(&e.equalizer, &eq_params) &&
		   dsp.delay_is_silent(&e.delay) &&
		   (!params.chorus_on || dsp.chorus_is_silent(&e.chorus)) {
			if params.chorus_on {
				dsp.chorus_process_silence(&e.chorus, &chorus_params, e.sample_rate)
			}
			left[i] = dsp.soft_clip(out_l * load_fade)
			right[i] = dsp.soft_clip(out_r * load_fade)
			chunk.position += 1
			continue
		}

		// The effect unit comes first. The manual lists it after the equaliser,
		// but the reference does not run it there: with a distortion on, an
		// equaliser peak at the fundamental raises the output's fundamental by
		// the peak's full gain (+24.79 dB) and its third harmonic by what the
		// same peak gives a linear signal at 3 f0, which is what an equaliser
		// after the nonlinearity does; ahead of it the boost is saturated away
		// (+0.02 dB). `s1probe arch fxorder` and
		// docs/synth1-architecture-evidence.md, T1a. The section carries its own
		// dry/wet level, so unlike the delay and chorus below it does not need an
		// enable test out here: at level zero it returns its input untouched, and
		// the reference behaves the same way.
		out_l, out_r = dsp.effect_process(&e.effect, out_l, out_r, &fx_params, e.sample_rate)

		// Then equaliser, delay, chorus, which is the order the reference's own
		// panel and manual list them in. It matters: equalising before the delay
		// colours what goes into the repeats, and after it would colour the
		// repeats themselves. The same probe's echo keeps the dry hit's harmonic
		// balance, so the effect unit is ahead of the delay too.
		out_l, out_r = dsp.equalizer_process(
			&e.equalizer, out_l, out_r, &eq_params, &eq_coefficients, e.sample_rate,
		)

		wet_l, wet_r := dsp.delay_process(&e.delay, out_l, out_r, &delay_params, e.sample_rate)
		if params.delay_on {
			out_l, out_r = wet_l, wet_r
		}

		if params.chorus_on {
			out_l, out_r = dsp.chorus_process(
				&e.chorus, out_l, out_r, &chorus_params, e.sample_rate,
			)
		}

		out_l *= load_fade
		out_r *= load_fade

		// A soft clip rather than a hard one: a stack of unison voices summing
		// in phase can exceed 1.0 on a loud patch, and the contract asks for a
		// stable output, not a truncated one.
		left[i] = dsp.soft_clip(out_l)
		right[i] = dsp.soft_clip(out_r)
		chunk.position += 1
	}
}
