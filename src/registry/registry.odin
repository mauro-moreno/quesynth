package registry

// The full set of user-controllable parameters, each bound to its measured
// src/patch index. Ids are stable API identifiers and must not change with a UI
// redesign; labels and grouping may. The index on each row is the one authority
// for that parameter's range, default, states and display -- the registry never
// restates them (Invariant 7); a test pins each id to the measured name at its
// index, so a table reindex cannot silently repoint an id.
//
// Seven of the ninety-nine parameters are deliberately absent. Polyphony (94)
// is daemon configuration, not patch state (plan §37); the four controller
// routing fields (86..89) and the two controller sensitivities (50, 51) are the
// modulation matrix's own wiring, which the engine already refuses as a
// modulation target, so exposing them as ordinary controls would be wrong.
//
// Fields are positional: id, label, group, index, kind, unit, scale. The unit
// and scale are advisory hints for a client's formatting and gesture choices;
// they never change how a value is stored, validated or displayed, which all
// come from the measured table.
DESCRIPTORS := [?]Parameter_Descriptor {
	// -- oscillator 1 --------------------------------------------------------
	{"osc1.shape", "Shape", "osc1", 0, .Enum, .None, .Enumerated},
	{"osc1.fm", "FM", "osc1", 45, .Float, .None, .Linear},
	{"osc1.detune", "Detune", "osc1", 76, .Float, .Cents, .Linear},
	{"osc1.phase", "Phase", "osc1", 91, .Float, .None, .Linear},
	{"osc1.sub.gain", "Sub Gain", "osc1", 95, .Float, .None, .Linear},
	{"osc1.sub.shape", "Sub Shape", "osc1", 96, .Enum, .None, .Enumerated},
	{"osc1.sub.octave", "Sub Octave", "osc1", 97, .Boolean, .None, .Stepped},

	// -- oscillator 2 --------------------------------------------------------
	{"osc2.shape", "Shape", "osc2", 1, .Enum, .None, .Enumerated},
	{"osc2.pitch", "Pitch", "osc2", 2, .Integer, .Semitones, .Linear},
	{"osc2.fine", "Fine Tune", "osc2", 3, .Float, .Cents, .Linear},
	{"osc2.kbd_track", "Kbd Track", "osc2", 4, .Boolean, .None, .Stepped},
	{"osc2.sync", "Sync", "osc2", 6, .Boolean, .None, .Stepped},
	{"osc2.ring_mod", "Ring Mod", "osc2", 7, .Boolean, .None, .Stepped},

	// -- shared oscillator + mod envelope ------------------------------------
	{"osc.mix", "Mix", "osc", 5, .Float, .None, .Linear},
	{"osc.pulse_width", "Pulse Width", "osc", 8, .Float, .None, .Linear},
	{"osc.key_shift", "Key Shift", "osc", 9, .Integer, .Semitones, .Linear},
	{"osc.fine", "Fine Tune", "osc", 72, .Float, .Cents, .Linear},
	{"osc.mod_env.dest", "Mod Env Dest", "osc", 71, .Enum, .None, .Enumerated},
	{"osc.mod_env.on", "Mod Env", "osc", 10, .Boolean, .None, .Stepped},
	{"osc.mod_env.amount", "Mod Env Amount", "osc", 11, .Float, .None, .Linear},
	{"osc.mod_env.attack", "Mod Env Attack", "osc", 12, .Float, .None, .Linear},
	{"osc.mod_env.decay", "Mod Env Decay", "osc", 13, .Float, .None, .Linear},

	// -- unison --------------------------------------------------------------
	{"unison.mode", "Mode", "unison", 73, .Boolean, .None, .Stepped},
	{"unison.detune", "Detune", "unison", 75, .Float, .Cents, .Linear},
	{"unison.pan_spread", "Pan Spread", "unison", 84, .Float, .None, .Linear},
	{"unison.pitch", "Pitch", "unison", 85, .Integer, .Semitones, .Linear},
	{"unison.phase", "Phase", "unison", 92, .Float, .None, .Linear},
	{"unison.voices", "Voices", "unison", 93, .Integer, .None, .Linear},

	// -- filter --------------------------------------------------------------
	{"filter.type", "Type", "filter", 14, .Enum, .None, .Enumerated},
	{"filter.attack", "Attack", "filter", 15, .Float, .None, .Linear},
	{"filter.decay", "Decay", "filter", 16, .Float, .None, .Linear},
	{"filter.sustain", "Sustain", "filter", 17, .Float, .None, .Linear},
	{"filter.release", "Release", "filter", 18, .Float, .None, .Linear},
	{"filter.cutoff", "Cutoff", "filter", 19, .Float, .Hertz, .Logarithmic},
	{"filter.resonance", "Resonance", "filter", 20, .Float, .Percent, .Linear},
	{"filter.env_amount", "Env Amount", "filter", 21, .Float, .None, .Linear},
	{"filter.kbd_track", "Kbd Track", "filter", 22, .Float, .None, .Linear},
	{"filter.saturation", "Saturation", "filter", 23, .Float, .None, .Linear},
	{"filter.velocity", "Velocity", "filter", 24, .Boolean, .None, .Stepped},

	// -- amplifier -----------------------------------------------------------
	{"amp.attack", "Attack", "amp", 25, .Float, .None, .Linear},
	{"amp.decay", "Decay", "amp", 26, .Float, .None, .Linear},
	{"amp.sustain", "Sustain", "amp", 27, .Float, .None, .Linear},
	{"amp.release", "Release", "amp", 28, .Float, .None, .Linear},
	{"amp.velocity", "Velocity", "amp", 30, .Float, .None, .Linear},

	// -- LFO 1 ---------------------------------------------------------------
	{"lfo1.dest", "Destination", "lfo1", 41, .Enum, .None, .Enumerated},
	{"lfo1.shape", "Shape", "lfo1", 42, .Enum, .None, .Enumerated},
	{"lfo1.rate", "Rate", "lfo1", 43, .Float, .None, .Linear},
	{"lfo1.depth", "Depth", "lfo1", 44, .Float, .None, .Linear},
	{"lfo1.on", "On", "lfo1", 57, .Boolean, .None, .Stepped},
	{"lfo1.tempo_sync", "Tempo Sync", "lfo1", 67, .Boolean, .None, .Stepped},
	{"lfo1.key_sync", "Key Sync", "lfo1", 68, .Boolean, .None, .Stepped},

	// -- LFO 2 ---------------------------------------------------------------
	{"lfo2.dest", "Destination", "lfo2", 46, .Enum, .None, .Enumerated},
	{"lfo2.shape", "Shape", "lfo2", 47, .Enum, .None, .Enumerated},
	{"lfo2.rate", "Rate", "lfo2", 48, .Float, .None, .Linear},
	{"lfo2.depth", "Depth", "lfo2", 49, .Float, .None, .Linear},
	{"lfo2.on", "On", "lfo2", 58, .Boolean, .None, .Stepped},
	{"lfo2.tempo_sync", "Tempo Sync", "lfo2", 69, .Boolean, .None, .Stepped},
	{"lfo2.key_sync", "Key Sync", "lfo2", 70, .Boolean, .None, .Stepped},

	// -- arpeggiator ---------------------------------------------------------
	{"arp.type", "Type", "arp", 31, .Enum, .None, .Enumerated},
	{"arp.octaves", "Octaves", "arp", 32, .Integer, .None, .Linear},
	{"arp.beat", "Beat", "arp", 33, .Enum, .None, .Enumerated},
	{"arp.gate", "Gate", "arp", 34, .Float, .None, .Linear},
	{"arp.on", "On", "arp", 59, .Boolean, .None, .Stepped},

	// -- effect unit ---------------------------------------------------------
	{"fx.effect.on", "On", "fx", 77, .Boolean, .None, .Stepped},
	{"fx.effect.type", "Type", "fx", 78, .Enum, .None, .Enumerated},
	{"fx.effect.ctl1", "Control 1", "fx", 79, .Float, .None, .Linear},
	{"fx.effect.ctl2", "Control 2", "fx", 80, .Float, .None, .Linear},
	{"fx.effect.mix", "Mix", "fx", 81, .Float, .None, .Linear},

	// -- delay ---------------------------------------------------------------
	{"delay.time", "Time", "delay", 35, .Float, .None, .Linear},
	{"delay.feedback", "Feedback", "delay", 36, .Float, .None, .Linear},
	{"delay.mix", "Dry/Wet", "delay", 37, .Float, .None, .Linear},
	{"delay.on", "On", "delay", 65, .Boolean, .None, .Stepped},
	{"delay.type", "Type", "delay", 82, .Enum, .None, .Enumerated},
	{"delay.spread", "Spread", "delay", 83, .Float, .None, .Linear},
	{"delay.tone", "Tone", "delay", 98, .Float, .None, .Linear},

	// -- chorus --------------------------------------------------------------
	{"chorus.delay", "Delay", "chorus", 52, .Float, .None, .Linear},
	{"chorus.depth", "Depth", "chorus", 53, .Float, .None, .Linear},
	{"chorus.rate", "Rate", "chorus", 54, .Float, .None, .Linear},
	{"chorus.feedback", "Feedback", "chorus", 55, .Float, .None, .Linear},
	{"chorus.level", "Level", "chorus", 56, .Float, .None, .Linear},
	{"chorus.type", "Type", "chorus", 64, .Enum, .None, .Enumerated},
	{"chorus.on", "On", "chorus", 66, .Boolean, .None, .Stepped},

	// -- equaliser -----------------------------------------------------------
	{"eq.tone", "Tone", "eq", 60, .Float, .None, .Linear},
	{"eq.freq", "Frequency", "eq", 61, .Float, .Hertz, .Logarithmic},
	{"eq.gain", "Level", "eq", 62, .Float, .Decibel, .Linear},
	{"eq.q", "Q", "eq", 63, .Float, .None, .Linear},

	// -- global --------------------------------------------------------------
	{"master.volume", "Volume", "global", 29, .Float, .Decibel, .Linear},
	{"global.play_mode", "Play Mode", "global", 38, .Enum, .None, .Enumerated},
	{"global.portamento", "Portamento", "global", 39, .Float, .None, .Linear},
	{"global.bend_range", "Bend Range", "global", 40, .Integer, .Semitones, .Linear},
	{"global.portamento_auto", "Porta Auto", "global", 74, .Boolean, .None, .Stepped},
	{"global.pan", "Pan", "global", 90, .Float, .None, .Linear},
}

// The registered parameters, in registration order.
registry_list :: proc() -> []Parameter_Descriptor {
	return DESCRIPTORS[:]
}

// The descriptor for an id, or ok=false when no parameter has that id.
registry_describe :: proc(id: string) -> (Parameter_Descriptor, bool) {
	for d in DESCRIPTORS {
		if d.id == id {
			return d, true
		}
	}
	return {}, false
}
