package engine

import "core:math"
import "../dsp"

// One sounding note.
//
// A voice owns a stack of up to MAX_UNISON detuned copies of the whole
// oscillator section, each with its own filter. Sharing one filter across the
// stack would be cheaper and wrong: the unison detune exists to make the stack
// beat against itself, and a shared filter would collapse the stereo spread
// that parameter 84 asks for.
//
// The three envelopes and the two LFOs are per voice, not per unison copy. They
// are control signals for the note as a whole; running eight independent copies
// of the amplitude envelope would only waste work.

// One detuned copy of the oscillator section.
Unison_Voice :: struct {
	osc1:      dsp.Oscillator,
	osc2:      dsp.Oscillator,
	sub:       dsp.Oscillator,
	filter:    dsp.Filter,
	// Offset in cents from the voice's pitch.
	detune:    f32,
	// Extra offset applied to oscillator 1 only, from parameter 76.
	osc1_trim: f32,
	// -1..1.
	pan:       f32,
}

Voice :: struct {
	active:       bool,
	// True while the key is held. A voice stays active after this goes false
	// for as long as the amplitude envelope is still releasing.
	gate:         bool,
	note:         int,
	velocity:     f32,
	// Portamento glides `current_note` toward `target_note`; both are in MIDI
	// note numbers so a fractional value is a legal in-between pitch.
	target_note:  f32,
	current_note: f32,
	glide_coef:   f32,

	amp_env:      dsp.Envelope,
	filter_env:   dsp.Envelope,
	mod_env:      dsp.Envelope,
	lfo:          [2]dsp.Lfo,

	unison:       [MAX_UNISON]Unison_Voice,
	unison_count: int,

	// Monotonic stamp used to pick the oldest voice when all are busy.
	age:          u64,
}

// Lay out the unison stack: detune, pan and, when requested, start phase.
//
// The detune spread is symmetric about the note, so a stack never shifts the
// perceived pitch of the note it is thickening. With one voice the spread is
// zero and the voice sits dead centre, which is why unison off is expressed as
// a count of 1 rather than as a separate code path.
voice_configure_unison :: proc(v: ^Voice, p: ^Engine_Params, seed: u32, reset_phase: bool) {
	count := clamp_int(p.unison_voices, 1, MAX_UNISON)
	old_count := v.unison_count
	v.unison_count = count

	for i in 0 ..< count {
		u := &v.unison[i]

		// -0.5 .. +0.5 across the stack, exactly 0 for a single voice.
		spread: f32 = 0
		if count > 1 {
			spread = f32(i) / f32(count - 1) - 0.5
		}

		u.detune = spread * p.unison_detune
		u.osc1_trim = spread * p.osc1_detune
		u.pan = dsp.clamp32(2.0 * spread * p.unison_pan_spread, -1, 1)

		if reset_phase || i >= old_count {
			voice_seed := seed + u32(i) * 2654435761

			// Phases are carried over unless parameter 91 asks for them to be
			// fixed, so the oscillators have to be initialised without losing
			// where they were.
			osc1_phase := u.osc1.phase
			osc2_phase := u.osc2.phase
			sub_phase := u.sub.phase
			fresh := i >= old_count

			dsp.oscillator_init(&u.osc1, voice_seed ~ 0x1)
			dsp.oscillator_init(&u.osc2, voice_seed ~ 0x2)
			dsp.oscillator_init(&u.sub, voice_seed ~ 0x3)
			dsp.filter_init(&u.filter)

			// Parameter 91 fixes the phase *relationship between the oscillators*
			// at note on, and turned fully down it does not fix anything at all.
			//
			// All three of those words were wrong here before. The old code set
			// osc1, osc2 and the sub to the same phase, which cannot change any
			// relationship -- a common start phase is inaudible in a steady tone --
			// and it did so even at parameter 91 of zero, which forced the two
			// oscillators into perfect coherence.
			//
			// That is not merely a different choice from the reference's, it is the
			// pathological one: two identical waveforms at identical pitch in exact
			// phase put every partial at its maximum. On patch 068, which mixes two
			// pulses at the same pitch, the reference returns a second harmonic
			// 11.4 dB *above* its fundamental -- and no pulse wave can do that,
			// since the ratio of the two is |cos(pi * duty)|, at most one for any
			// duty. Only cancellation between the oscillators reaches it.
			//
			// The manual is explicit about zero: "turned fully left, the phase is
			// not fixed (as before)". And the offset for the rest of the range is
			// measured -- `s1probe phaseprobe` sweeps it against two same-pitch
			// pulses and finds three nulls that fall on one line through the
			// origin, the third harmonic cancelling at stored 48, the second at 64
			// and the first at 127.
			if p.osc_phase_fixed {
				base_phase := p.osc_phase_shift
				// Parameter 92 spreads the stack, and the manual notes it "is not
				// effective unless the phase is fixed in the oscillator section",
				// so it lives inside this branch.
				stack_phase := p.unison_phase_shift * f32(i) / f32(MAX_UNISON)
				dsp.oscillator_set_phase(&u.osc1, stack_phase)
				// Only oscillator 2 carries the offset, because the parameter is a
				// relationship and not a position.
				dsp.oscillator_set_phase(&u.osc2, stack_phase + base_phase)
				dsp.oscillator_set_phase(&u.sub, stack_phase)
			} else if !fresh {
				// Free-running: pick up where the previous note left off.
				dsp.oscillator_set_phase(&u.osc1, osc1_phase)
				dsp.oscillator_set_phase(&u.osc2, osc2_phase)
				dsp.oscillator_set_phase(&u.sub, sub_phase)
			} else {
				// A voice with no history, and parameter 91 not fixing anything. The
				// reference is not silent about this case even though it is nominally
				// free-running: measured at three notes an octave apart, oscillator 2
				// sits a fixed distance behind oscillator 1, and the reading does not
				// move with pitch.
				//
				// It is fitted from how far each harmonic is pulled down against the
				// same patch with the phase fixed and no offset. Two harmonics agree:
				// the fundamental comes back 14.5 dB down, which needs 158 degrees,
				// and the third comes back 5.0 dB down, which at 158 degrees predicts
				// 5.4. Starting both oscillators at zero instead -- which is what this
				// did before -- is the one relationship that maximises every partial.
				//
				// The caveat is recorded rather than hidden: this is the offset after a
				// fresh load and a fixed silence, which is the condition the null test
				// renders under. A host that has had the plugin running for minutes
				// would find genuinely free-running oscillators somewhere else.
				dsp.oscillator_set_phase(&u.osc1, 0)
				dsp.oscillator_set_phase(&u.osc2, OSC_PHASE_FREE_TURNS)
				dsp.oscillator_set_phase(&u.sub, 0)
			}
		}
	}
}

// Push the current parameter block into the voice's envelopes.
voice_apply_params :: proc(v: ^Voice, p: ^Engine_Params, sample_rate: f32) {
	dsp.envelope_set(&v.amp_env, p.amp_attack, p.amp_decay, p.amp_sustain, p.amp_release, sample_rate)
	dsp.envelope_set(
		&v.filter_env,
		p.filter_attack,
		p.filter_decay,
		p.filter_sustain,
		p.filter_release,
		sample_rate,
	)
	// The modulation envelope exposes only attack (12) and decay (13) in the
	// reference; there is no sustain or release parameter for it. It is
	// therefore driven as an ADSR with sustain pinned to 0 and release equal to
	// its decay, which is the standard AD reading: the segment falls to silence
	// after the attack and a key release cannot make it rise again.
	dsp.envelope_set(&v.mod_env, p.mod_env_attack, p.mod_env_decay, 0, p.mod_env_decay, sample_rate)

	for i in 0 ..< 2 {
		v.lfo[i].shape = p.lfo[i].shape
	}
}

voice_note_on :: proc(
	v: ^Voice,
	p: ^Engine_Params,
	note: int,
	velocity: f32,
	sample_rate: f32,
	seed: u32,
	glide_from: f32,
	legato: bool,
	global_lfo: ^[2]dsp.Lfo,
) {
	v.active = true
	v.gate = true
	v.note = note
	v.velocity = dsp.clamp32(velocity, 0, 1)
	v.target_note = f32(note)

	// Portamento. `glide_from` is where the pitch starts; the caller supplies
	// the previous note for a mono line and the new note itself when there is
	// nothing to glide from. Parameter 74 ("portament auto mode") restricts the
	// glide to legato playing, which is why it is the caller's `legato` flag
	// that decides rather than the time alone.
	glide := p.portamento_time > 0 && (!p.portamento_auto || legato)
	if glide {
		v.current_note = glide_from
		// A one-pole reaching 99.9% of the interval in the portamento time.
		// The version history records "modify portament effect
		// (linear -> exponential)", so the exponential approach is the
		// reference's own shape.
		// Portamento is a glide, not an envelope segment, so it keeps the plain
		// exponential span rather than the decay's measured shape.
		v.glide_coef = dsp.segment_coef(p.portamento_time, sample_rate, dsp.ENVELOPE_RELEASE_SPAN)
	} else {
		v.current_note = v.target_note
		v.glide_coef = 0
	}

	// A legato note keeps the envelopes and existing oscillator phases where they
	// are, which is the whole point of the mode; every other case restarts them.
	// The unison layout is still refreshed on every note-on so a fresh or resized
	// voice can never enter the audio path with unison_count == 0.
	retrigger := !legato
	voice_configure_unison(v, p, seed, retrigger)
	voice_apply_params(v, p, sample_rate)

	dsp.envelope_gate_on(&v.amp_env, retrigger)
	dsp.envelope_gate_on(&v.filter_env, retrigger)
	if p.mod_env_on {
		dsp.envelope_gate_on(&v.mod_env, retrigger)
	} else {
		dsp.envelope_reset(&v.mod_env)
	}

	for i in 0 ..< 2 {
		if p.lfo[i].key_sync {
			dsp.lfo_retrigger(&v.lfo[i])
		} else {
			// Not key synced: adopt the free-running phase so every voice
			// hears the same LFO position regardless of when it started.
			v.lfo[i].phase = global_lfo[i].phase
			v.lfo[i].held = global_lfo[i].held
			v.lfo[i].current = global_lfo[i].current
		}
		v.lfo[i].shape = p.lfo[i].shape
	}
}

voice_note_off :: proc(v: ^Voice) {
	v.gate = false
	dsp.envelope_gate_off(&v.amp_env)
	dsp.envelope_gate_off(&v.filter_env)
	dsp.envelope_gate_off(&v.mod_env)
}

// A voice is finished when its amplitude envelope has, not when the key is
// released. Freeing it any earlier truncates the release tail.
voice_is_finished :: proc(v: ^Voice) -> bool {
	return !dsp.envelope_is_active(&v.amp_env)
}

CENTS_PER_SEMITONE :: f32(100.0)

// Render one sample of this voice into a stereo pair.
//
// `lfo_value` carries the two free-running LFO values the engine advanced once
// for the whole block; a key-synced LFO ignores them and advances its own.
voice_process :: proc(
	v: ^Voice,
	p: ^Engine_Params,
	sample_rate: f32,
	pitch_bend: f32,
	global_lfo_value: [2]f32,
) -> (
	left: f32,
	right: f32,
) {
	if !v.active {
		return 0, 0
	}

	// -- control rate, once per sample ---------------------------------------

	if v.glide_coef > 0 {
		v.current_note = v.target_note + (v.current_note - v.target_note) * v.glide_coef
		if abs(v.current_note - v.target_note) < 1.0e-4 {
			v.current_note = v.target_note
			v.glide_coef = 0
		}
	}

	amp_env := dsp.envelope_process(&v.amp_env)
	filter_env := dsp.envelope_process(&v.filter_env)
	mod_env: f32 = 0
	if p.mod_env_on {
		mod_env = dsp.envelope_process(&v.mod_env) * p.mod_env_amount
	}

	// The modulation destinations, accumulated before anything uses them so a
	// destination selected by two sources adds rather than the later winning.
	mod_osc2_semitones: f32 = 0
	mod_osc1_semitones: f32 = 0
	mod_cutoff_octaves: f32 = 0
	mod_amplitude: f32 = 1
	mod_pulse_width: f32 = 0
	mod_fm: f32 = 0
	mod_pan: f32 = 0

	switch p.mod_env_dest {
	case .Osc2_Pitch:
		// The full amount is a wide sweep; 24 semitones is two octaves, which
		// is the range this kind of pitch envelope is normally asked for.
		mod_osc2_semitones += mod_env * 24.0
	case .Fm:
		mod_fm += mod_env
	case .Pulse_Width:
		mod_pulse_width += mod_env * 0.45
	}

	// The destinations below are measured; the *depths* they are scaled by are
	// not, and that distinction now dominates.
	//
	// Correcting the destination mapping against `s1probe lfoprobe` made the null
	// test's spectral error worse, by 1.4 dB. That is not evidence the mapping is
	// wrong -- it was measured by comparing each state's render against the same
	// patch with the LFO switched off, which is about as direct as evidence gets.
	// It is evidence that a correct destination driven by an invented depth can
	// be further from the reference than a wrong destination that happened to be
	// mild. Display 2 used to be bound to the filter cutoff and is really both
	// oscillators' pitch, so it now swings a full octave of pitch where it used
	// to sweep a filter; display 4 used to be pulse width and is really volume,
	// so it now swings 27 dB.
	//
	// Every constant in this loop -- the 12 semitones, the 4 octaves, the 0.5 in
	// the amplitude law -- is a guess, and measuring them is the next thing this
	// engine needs.
	for i in 0 ..< 2 {
		lp := &p.lfo[i]
		if !lp.enabled || lp.depth <= 0 {
			continue
		}
		value := lp.key_sync ? dsp.lfo_process(&v.lfo[i]) : global_lfo_value[i]
		amount := value * lp.depth

		// The pitch destinations take the depth knob through its measured curve
		// rather than its linear travel; every other destination below is still on
		// the linear reading. LFO_DEPTH_CURVE_K says why the two are not yet the
		// same thing.
		pitch_amount := value * lp.pitch_depth

		switch lp.destination {
		case .Osc2_Pitch:
			mod_osc2_semitones += pitch_amount * LFO_PITCH_SEMITONES
		case .Both_Pitch:
			// Measured: this destination moves both oscillators together, by the
			// same interval. It is the one the English readme omits entirely.
			mod_osc1_semitones += pitch_amount * LFO_PITCH_SEMITONES
			mod_osc2_semitones += pitch_amount * LFO_PITCH_SEMITONES
		case .Filter_Cutoff:
			// Unipolar, and measured. `(1 + value)/2` is 1 at the top of the cycle
			// and 0 at the bottom, so this only ever opens the filter -- the corner
			// at the bottom of the cycle is the patch's own, not below it. See
			// LFO_CUTOFF_OCTAVES, where the evidence is set out; the short version
			// is that the low half of a square sits on the unmodulated corner at
			// every depth and at every base cutoff tried.
			mod_cutoff_octaves += (1.0 + value) * 0.5 * lp.depth * LFO_CUTOFF_OCTAVES
		case .Amplitude:
			// Unipolar too, and linear in amplitude rather than in decibels: the
			// knob position is the fraction of the level removed at the bottom of
			// the cycle, so full depth reaches silence there. Measured; see the
			// note above LFO_PAN_DEPTH_STEPS for why the decibel constant this
			// replaces was an artefact of the instrument that produced it.
			mod_amplitude *= 1.0 - lp.depth * 0.5 * (1.0 - value)
		case .Inert:
			// State 5 does nothing in the reference, and neither does this.
		case .Fm:
			// Measured, and it is the odd one of the seven: unipolar like the
			// cutoff and the volume, but scaled by the *headroom above the knob*
			// rather than by a constant.
			//
			// The objection recorded here before -- that an FM index is not a
			// quantity the spectrum reports -- was true and not fatal. Parameter 45
			// is a knob whose settings can be rendered one at a time, so the
			// spectrum never has to yield an index; it only has to tell one setting
			// of that knob from another. `s1probe lfofm` sweeps it with the LFO off
			// to calibrate the carrier's centroid, then reads the LFO's own
			// excursion back in units of the knob it is modulating.
			//
			// The low half of the square sits exactly on the knob's own value at
			// every depth, so nothing here ever reduces the FM. What rises is
			// linear in the depth, and its slope is the distance left to the top:
			//
			//   parameter 45 at   0.000   0.252   0.504
			//   measured slope     0.99    0.745   0.497
			//   1 - that value     1.000   0.748   0.496
			//
			// So a full-depth LFO drives the FM amount to maximum from wherever the
			// knob left it, and a half-depth one covers half the remaining
			// distance. `amount` is not used because it carries the bipolar swing
			// this destination does not have.
			mod_fm += (1.0 + value) * 0.5 * lp.depth * (1.0 - p.osc1_fm)
		case .Pan:
			// Negated, and that sign is measured rather than chosen.
			//
			// A sign flip of the LFO cannot be distinguished from a sign flip of
			// the destination it drives, so matching the reference on pan alone
			// would only prove the two conventions compose the same way. Volume
			// breaks the tie, because loud is loud under any convention: driven
			// through destination 4 with a saw, both engines' loudness ramps down
			// and jumps back up, folding to cycles that agree within a decibel. So
			// our saw runs the right way and the LFO itself is right.
			//
			// Watched on pan, though, the same saw moved the reference's image
			// left to right and ours right to left. With the LFO ruled out, that
			// is this destination's own sign -- and the static pan control is not
			// the culprit either, since parameter 90 hard left reads positive on
			// both. See `s1probe lfoshape --dest 4`.
			//
			// The depth is its own measured curve rather than the linear reading,
			// and it reaches a fully hard image at the top of the knob where this
			// used to stop at 0.927. Unlike the two destinations above, this one
			// really is bipolar and symmetric: the two halves of a square land at
			// plus and minus the same value at every depth measured.
			mod_pan -= value * lp.pan_depth
		}
	}

	// -- pitch ---------------------------------------------------------------

	// Everything that shifts the note is summed in semitones and converted
	// once, so detune, bend, key shift and modulation compose exactly.
	base_note :=
		v.current_note +
		p.key_shift +
		p.unison_pitch +
		pitch_bend * p.pitch_bend_range +
		p.fine_tune_cents / CENTS_PER_SEMITONE

	pulse_width := dsp.clamp32(p.pulse_width + mod_pulse_width, 0.02, 0.98)

	// -- filter cutoff -------------------------------------------------------

	// Keyboard tracking is measured from C3, an octave below middle C.
	//
	// This used to read from middle C, on the reasoning that a patch should sit on
	// its nominal cutoff at the note it was probably designed around. The
	// reference disagrees, and says so plainly: `s1probe cutoffprobe --sweep note`
	// puts the corner at 585 Hz at every note with tracking off, and at 585 Hz at
	// *note 48* with tracking full, rising exactly one octave per octave from
	// there. At middle C full tracking therefore adds a whole octave, where this
	// engine was adding none.
	//
	// That was a full octave of missing brightness on every patch with the
	// tracking knob up, and through a 24 dB filter it is 24 dB of missing output:
	// it is why several patches with tracking at maximum rendered near silence
	// here while the reference sounded.
	//
	// The tracking *amount* is left linear, which is right at both ends -- 0 and
	// 1.01 octaves per octave at the extremes -- but measures slightly convex in
	// between: 0.589 octaves at stored 64 against the 0.504 a linear reading
	// gives. Around a semitone, and not yet modelled.
	track_octaves := p.filter_key_track * (base_note - FILTER_TRACK_REFERENCE_NOTE) / 12.0

	env_octaves := p.filter_env_octaves
	if p.filter_velocity {
		// Parameter 24: "Select whether the amount of envelope variation
		// changes according to the velocity of the note played."
		env_octaves *= v.velocity
	}
	// The envelope's own contribution, already in octaves: the binding measured
	// how far a step of parameter 21 moves the corner, so there is no scaling
	// constant left to choose here. There used to be one -- six octaves at full
	// amount -- and it was the reason a patch with a low cutoff and a negative
	// amount stayed audible in this engine while the reference fell silent. The
	// real range is about ten octaves either way.
	//
	// That raw range is a law fitted clear of the filter's own limits, and at a
	// cutoff with little headroom it overshoots them: parameter 19 at 80 has
	// 5.9 octaves to the floor, not the law's 10.05. Scaling the raw law by a
	// fractional envelope value and clamping only the final Hz sends that
	// fraction past a wall the reference's own envelope never sees --
	// `s1probe cutoffprobe --sweep sustain --cutoff 80 --amount 0 --type 1
	// --res 107` measures a mid sustain landing at 453 Hz where that gives
	// 246 Hz, because the reference reaches full depth at 6.02 octaves of real
	// travel and takes its fraction of *that*, not of the law's 10.05. So the
	// full-depth excursion is clamped first, against the knob's own range
	// rather than the general DSP safety floor, and the envelope's fraction is
	// taken of whatever excursion survives that.
	// The wall the excursion clamps against is the 24 dB path's own floor and
	// ceiling when that is the path in use, not the 12 dB path's.
	cutoff_floor := p.filter_slope == .Slope_24 ? FILTER_CUTOFF_HZ_24[0] : FILTER_CUTOFF_HZ[0]
	cutoff_ceiling: f32
	if p.filter_slope == .Slope_24 {
		cutoff_ceiling = FILTER_CUTOFF_HZ_24[FILTER_TABLE_SIZE - 1]
	} else {
		cutoff_ceiling = FILTER_CUTOFF_HZ[FILTER_TABLE_SIZE - 1]
	}
	full_env_cutoff := dsp.clamp32(
		p.filter_cutoff_hz * math.pow(f32(2.0), env_octaves),
		cutoff_floor,
		cutoff_ceiling,
	)
	achievable_env_octaves := math.log2(full_env_cutoff / p.filter_cutoff_hz)
	cutoff_octaves := track_octaves + achievable_env_octaves * filter_env + mod_cutoff_octaves
	cutoff := p.filter_cutoff_hz * math.pow(f32(2.0), cutoff_octaves)
	cutoff = dsp.clamp32(cutoff, dsp.MIN_CUTOFF_HZ, sample_rate * dsp.MAX_CUTOFF_RATIO)

	// -- amplitude -----------------------------------------------------------

	// Parameter 30, measured rather than assumed.
	//
	// The law this replaces was `1 - sens * (1 - velocity)`: a fade that is
	// linear in *amplitude*, with the knob as its depth. It was a guess, and it
	// made the instrument feel dead under a real controller. At stored 22 --
	// which 107 of the 128 factory patches carry -- it spans 1.6 dB from the
	// softest playable note to the hardest, where the reference spans 5.2.
	//
	// `s1probe velprobe` drives one note at a sweep of velocities through a
	// patch where only the amplifier can move -- sine, filter open, filter
	// envelope flat, filter velocity switch off -- and reads the level back.
	// Two things fall out, and both are clean:
	//
	// The shape is linear in *decibels*, not in amplitude. At stored 22 the
	// reference's attenuation goes -5.16, -3.89, -2.58, -1.27, 0.00 dB across
	// velocities 1, 32, 64, 96, 127, which is -depth * (1 - velocity) to within
	// three hundredths of a decibel at every point.
	//
	// The depth is linear in the knob. Measured at seven settings:
	//
	//   stored     0     22     43     64     85    106    127
	//   depth dB  0.00   5.16  10.08  15.00  19.92  24.84  29.77
	//
	// which is 29.77 * (stored/127) to within a hundredth of a decibel
	// throughout. So the whole parameter is one constant: the attenuation at
	// zero velocity and full sensitivity.
	//
	// The old law was not merely shallow, it was wrong in both directions --
	// at the top of the knob it reached 42 dB against the reference's 29.8.
	VELOCITY_DEPTH_DB :: f32(29.77)
	velocity_attenuation_db := VELOCITY_DEPTH_DB * p.amp_velocity_sens * (1.0 - v.velocity)
	velocity_gain := math.pow(f32(10.0), -velocity_attenuation_db / 20.0)
	gain := amp_env * p.amp_gain * velocity_gain * mod_amplitude

	// The stack is summed, so without this a unison of eight would be eight
	// times louder than a single voice.
	stack_scale := f32(1.0) / math.sqrt(f32(v.unison_count))

	fm_index := dsp.clamp32(p.osc1_fm + mod_fm, 0, 1)

	// -- audio rate ----------------------------------------------------------

	for i in 0 ..< v.unison_count {
		u := &v.unison[i]

		note1 := base_note + (u.detune + u.osc1_trim) / CENTS_PER_SEMITONE + mod_osc1_semitones
		osc1_hz := dsp.note_to_hz(note1)

		osc2_hz: f32
		if p.osc2_key_track {
			note2 :=
				base_note +
				u.detune / CENTS_PER_SEMITONE +
				p.osc2_semitones +
				(p.osc2_cents / CENTS_PER_SEMITONE) +
				mod_osc2_semitones
			osc2_hz = dsp.note_to_hz(note2)
		} else {
			// Tracking off: "sound is output at a uniform frequency". The pitch
			// offset still applies, it is just measured from a fixed middle C
			// instead of from the note played.
			note2 :=
				60.0 +
				p.osc2_semitones +
				(p.osc2_cents / CENTS_PER_SEMITONE) +
				mod_osc2_semitones
			osc2_hz = dsp.note_to_hz(note2)
		}

		dsp.oscillator_set_frequency(&u.osc1, osc1_hz, sample_rate)
		dsp.oscillator_set_frequency(&u.osc2, osc2_hz, sample_rate)
		dsp.oscillator_set_frequency(&u.sub, dsp.note_to_hz(note1 + p.sub_octave), sample_rate)

		// Oscillator 2 advances first because it is the FM modulator: its output
		// displaces oscillator 1's phase within the same sample.
		//
		// The direction is the reference's, and it is not the one this file
		// originally implemented. The run objective said "FM from oscillator 1",
		// so oscillator 1 was made the modulator, with a note that the readme
		// disagreed and that the oracle slice should settle it. It is settled,
		// twice over, by the author of the reference:
		//
		//   - The manual, on the FM knob: "oscillator 2 is the modulator,
		//     oscillator 1 is the carrier."
		//   - His write-up of Synth1's oscillator section, which gives the phase
		//     update as osc1_phase += osc1_delta + osc2_out * fmAmount * 2048/2.
		//
		// So oscillator 2 modulates oscillator 1, the displacement is up to half
		// a cycle at full amount, and it accumulates into the phase.
		dsp.oscillator_advance(&u.osc2)
		dsp.oscillator_advance(&u.sub)

		// Read before oscillator 1 is advanced, and before hard sync can reset
		// this oscillator below: the modulator's contribution to this sample is
		// its state at the top of the sample.
		osc2_value := dsp.oscillator_value(&u.osc2, p.osc2_shape, pulse_width)

		// Ring takes precedence: the readme and the manual agree that "FM
		// modulation is only possible when ring modulation is off".
		fm_offset: f32 = 0
		if fm_index > 0 && !p.osc_ring {
			fm_offset = osc2_value * fm_index * 0.5
		}
		wrapped, wrap_frac := dsp.oscillator_advance_modulated(&u.osc1, fm_offset)

		if p.osc_sync && wrapped {
			// Parameter 6: "when on, oscillator 2's phase is reset in step with
			// oscillator 1's frequency" -- oscillator 1 is the master.
			dsp.oscillator_sync(&u.osc2, wrap_frac)
		}

		osc1_value := dsp.oscillator_value(&u.osc1, p.osc1_shape, pulse_width)

		if p.osc_ring {
			// Parameter 7: "the output of oscillator 2 is subjected to ring
			// modulation". Ring and FM are mutually exclusive just above, so
			// this always multiplies the two unmodulated oscillator outputs.
			// Both are bounded to -1..1, so the product is too.
			osc2_value *= osc1_value
		}

		mixed := osc1_value * (1.0 - p.osc_mix) + osc2_value * p.osc_mix

		if p.sub_gain > 0 {
			sub_value := dsp.oscillator_value(&u.sub, p.sub_shape, 0.5)
			// The version history: "When the amount of the suboscillator is
			// raised, the entire volume is automatically adjusted not to grow."
			mixed = mixed * (1.0 - 0.5 * p.sub_gain) + sub_value * p.sub_gain
		}

		dsp.filter_set_damping(&u.filter, cutoff, p.filter_damping, sample_rate, p.filter_slope)
		filtered := dsp.filter_process(
			&u.filter,
			mixed,
			p.filter_mode,
			p.filter_slope,
			p.filter_saturation_drive,
		)

		sample := filtered * p.filter_output_gain * gain * stack_scale

		// The reference's pan law: full level in both channels at the centre, and
		// panning attenuates the channel you are moving away from.
		//
		// Measured, and it replaces an equal-power law that cost 3 dB on every patch
		// in the bank. Sweeping parameter 90 through the reference and reading the
		// mid level gives 6.0 dB from hard left to centre; an equal-power law gives
		// 3.0 and that is what ours gave. The half-panned point settles which of the
		// two laws produces the 6 dB, since they disagree there too:
		//
		//   pan             -1.0    -0.5     0.0
		//   this law, mid    0.50    0.75    1.00
		//   predicted dB    -6.0    -2.5     0.0
		//   measured        -6.0    -2.5     0.0
		//
		// This was the larger half of the level error -- our peak sat 4.35 dB under
		// the reference's across the bank, and 3 dB of it was here, on every patch at
		// once, including a bare sine with the filter open and every effect off.
		//
		// It does mean the total power rises by 3 dB as a voice moves to the centre,
		// which is what an equal-power law exists to avoid. That is the reference's
		// behaviour and the point of this engine is to reproduce it.
		pan := dsp.clamp32(u.pan + p.pan + mod_pan, -1, 1)
		left += sample * min(f32(1.0), 1.0 - pan)
		right += sample * min(f32(1.0), 1.0 + pan)
	}

	if voice_is_finished(v) {
		v.active = false
	}

	return dsp.sanitize(left), dsp.sanitize(right)
}
