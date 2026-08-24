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

// Parameter 45 is a position, not a linear modulation index. The open-filter
// sweep in `s1probe fmfilter` stays nearly flat through the lower quarter and
// then rises sharply: states 43, 68 and 77 resolve to peak deviations of 0.249,
// 3.091 and 6.124 carrier frequencies. A power law fits the complete sweep and
// the three moving-filter fixtures; a linear reading sends their centroids into
// the 3--6 kHz range and lets the filter reject 12--23 dB too much signal.
FM_FREQUENCY_DEPTH_MAX :: f32(96.0)
FM_FREQUENCY_DEPTH_EXPONENT :: f32(5.5)

// Parameter 91's engaged oscillator-1 origin. `s1probe phaseabsolute --values
// 0,1,16,32,48,64,96,127` projects one oscillator at a time against note-on at
// five notes, then separates the reference's fixed output latency by its
// frequency slope. Oscillator 1 reads -0.00125 turns for every engaged value;
// cancellation depth cannot see this common signed shift. This origin is
// deliberately separate from the free-running OSC_PHASE_FREE_TURNS
// relationship.
OSC_PHASE_FIXED_START_TURNS :: f32(-0.00125)

fm_frequency_depth :: proc(position: f32) -> f32 {
	u := dsp.clamp32(position, 0, 1)
	return FM_FREQUENCY_DEPTH_MAX * math.pow(u, FM_FREQUENCY_DEPTH_EXPONENT)
}

// Resolve a possibly fractional parameter-19 state on the same cutoff surface
// selected at patch binding. Geometric interpolation is the natural operation
// for frequency, both between adjacent states and between the measured low-Q
// and high-Q 24 dB curves.
filter_cutoff_at_state :: proc(p: ^Engine_Params, state: f32) -> f32 {
	bounded := dsp.clamp32(state, 0, f32(FILTER_TABLE_SIZE - 1))
	lo := int(math.floor(bounded))
	hi := clamp_int(lo + 1, 0, FILTER_TABLE_SIZE - 1)
	fraction := bounded - f32(lo)

	if p.filter_slope == .Slope_24 {
		low_q := exp_map(
			fraction,
			FILTER_CUTOFF_HZ_24_LOW_RESONANCE[lo],
			FILTER_CUTOFF_HZ_24_LOW_RESONANCE[hi],
		)
		high_q := exp_map(
			fraction,
			FILTER_CUTOFF_HZ_24[lo],
			FILTER_CUTOFF_HZ_24[hi],
		)
		cutoff := filter_cutoff_24_effective_topology_scale(
			p.filter_cutoff_topology_scale,
			bounded,
		) * exp_map(
			p.filter_cutoff_surface_blend,
			low_q,
			high_q,
		)
		return cutoff
	}

	cutoff := exp_map(fraction, FILTER_CUTOFF_HZ[lo], FILTER_CUTOFF_HZ[hi])
	if p.filter_mode == .Band_Pass {
		cutoff *= BAND_PASS_CENTRE_RATIO
	}
	return cutoff
}

// Lay out the unison stack: measured pitch, pan and phase laws. The stack
// keeps one oscillator pair per layer; its level is the reference's sum, not
// an equal-power normalisation.
//
// The reference gives every layer the same nominal oscillator level. Its
// free-running start phases are stable for a fresh voice, and the phase knob
// scales those same signed offsets when oscillator phase is fixed.
//
// The detune and pan spreads stay symmetric about the note. A single voice has
// no spread and sits dead centre.

unison_phase_offset :: proc(index: int, amount: f32) -> f32 {
	i := clamp_int(index, 0, MAX_UNISON - 1)
	factor: f32
	switch i {
	case 0: factor = 0.000000
	case 1: factor = 0.174481
	case 2: factor = 0.988523
	case 3: factor = 0.166238
	case 4: factor = 0.875969
	case 5: factor = 0.779655
	case 6: factor = 0.375859
	case: factor = 0.837608
	}
	return amount * factor
}

unison_layer_pitch :: proc(index: int, pitch: f32) -> f32 {
	// The reference's unison-pitch control alternates two pitch groups. At a
	// non-zero setting half the layers remain at the note and the other half
	// move by the displayed interval.
	return pitch if index % 2 == 1 else 0
}

unison_stack_scale :: proc(count: int) -> f32 {
	// Synth1 sums the layers at unity. Keep the argument so the call site makes
	// the count-dependent intent explicit and so this law has a signed test.
	_ = count
	return 1.0
}
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
			// not fixed (as before)". For engaged values, `s1probe phaseabsolute`
			// reads oscillator 1 itself at -0.00125 turns and oscillator 2 ahead by
			// 0.5*(v-1)/126. Reading each alone against note-on makes both signs
			// visible; the earlier same-pitch cancellation probe could see neither
			// the common start nor the sign of the relationship.
			if p.osc_phase_fixed {
				base_phase := p.osc_phase_shift
				// Parameter 92 scales a measured, signed per-layer spread.
				stack_phase := unison_phase_offset(i, p.unison_phase_shift)
				dsp.oscillator_set_phase(&u.osc1, stack_phase + OSC_PHASE_FIXED_START_TURNS)
				dsp.oscillator_set_phase(&u.osc2,
					stack_phase + OSC_PHASE_FIXED_START_TURNS + base_phase)
				dsp.oscillator_set_phase(&u.sub, stack_phase)
			} else if !fresh {
				// Free-running: pick up where the previous note left off.
				dsp.oscillator_set_phase(&u.osc1, osc1_phase)
				dsp.oscillator_set_phase(&u.osc2, osc2_phase)
				dsp.oscillator_set_phase(&u.sub, sub_phase)
			} else {
				// A fresh layer uses the measured offsets reached at maximum
				// unison phase spread. Oscillator 2 keeps its intra-pair offset.
				stack_phase := unison_phase_offset(i, 1.0)
				dsp.oscillator_set_phase(&u.osc1, stack_phase)
				dsp.oscillator_set_phase(&u.osc2, stack_phase + OSC_PHASE_FREE_TURNS)
				dsp.oscillator_set_phase(&u.sub, stack_phase)
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

	env_cutoff_states := p.filter_env_cutoff_states
	if p.filter_velocity {
		// Parameter 24: "Select whether the amount of envelope variation
		// changes according to the velocity of the note played."
		env_cutoff_states *= v.velocity
	}
	// Clamp the full envelope destination in controller-state space first, then
	// take the envelope fraction of the achievable state travel. This ordering
	// is observable near either end of the cutoff knob. For example, cutoff 44
	// and amount 31 request -64 states: the endpoint stops at state 0, sustain
	// 73 takes 57.5% of the surviving 44-state trip, and lands near state 19.
	full_env_state := dsp.clamp32(
		p.filter_cutoff_state + env_cutoff_states,
		0,
		f32(FILTER_TABLE_SIZE - 1),
	)
	achievable_env_states := full_env_state - p.filter_cutoff_state
	cutoff_state := p.filter_cutoff_state + achievable_env_states * filter_env
	cutoff := filter_cutoff_at_state(p, cutoff_state)
	cutoff *= math.pow(f32(2.0), track_octaves + mod_cutoff_octaves)
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

	// Synth1 sums the unison layers at unity; there is no count trim.
	stack_scale := unison_stack_scale(v.unison_count)

	fm_position := dsp.clamp32(p.osc1_fm + mod_fm, 0, 1)

	// -- audio rate ----------------------------------------------------------

	for i in 0 ..< v.unison_count {
		u := &v.unison[i]

		layer_pitch := unison_layer_pitch(i, p.unison_pitch)
		note1 := base_note + layer_pitch +
			(u.detune + u.osc1_trim) / CENTS_PER_SEMITONE + mod_osc1_semitones
		osc1_hz := dsp.note_to_hz(note1)

		osc2_hz: f32
		if p.osc2_key_track {
			note2 :=
				base_note + layer_pitch +
				u.detune / CENTS_PER_SEMITONE +
				p.osc2_semitones +
				(p.osc2_cents / CENTS_PER_SEMITONE) +
				mod_osc2_semitones
			osc2_hz = dsp.note_to_hz(note2)
		} else {
			// Tracking off fixes oscillator 2's base note, but unison pitch
			// still separates the alternating layers.
			note2 :=
				60.0 + layer_pitch +
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
		// So oscillator 2 modulates oscillator 1 and the displacement accumulates
		// into the phase. The panel position is converted to its measured frequency
		// depth below; it is not itself a phase offset.
		dsp.oscillator_advance(&u.osc2)
		dsp.oscillator_advance(&u.sub)

		// Read before oscillator 1 is advanced, and before hard sync can reset
		// this oscillator below: the modulator's contribution to this sample is
		// its state at the top of the sample.
		osc2_value := dsp.oscillator_value(&u.osc2, p.osc2_shape, pulse_width)

		// Ring takes precedence: the readme and the manual agree that "FM
		// modulation is only possible when ring modulation is off".
		fm_offset: f32 = 0
		if fm_position > 0 && !p.osc_ring {
			fm_offset = osc2_value * fm_frequency_depth(fm_position) * u.osc1.increment
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
			// Both factors are measured, and they carry the oscillator mix with
			// them because the sub is oscillator 1's -- see sub_gain in
			// binding.odin. The line here used to be
			// `mixed*(1 - 0.5*gain) + sub*gain`, which raised the carrier by up to
			// 3 dB instead of dividing it down, and left the sub audible with
			// oscillator 1 mixed out where the reference silences it.
			mixed = mixed * p.sub_carrier_gain + sub_value * p.sub_gain
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
