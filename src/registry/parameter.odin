package registry

// The parameter registry: stable string IDs and the semantic metadata a
// generic client needs to display and manipulate an engine parameter, laid over
// the measured parameter table in src/patch.
//
// The registry adds names, groups and semantic hints; it never restates a
// range. Every numeric fact -- the domain of stored values, the default, the
// normalised position, the display string -- is read from src/patch at the
// bound VST index, so the measured table stays the one authoritative source
// (docs/standalone-daemon-plan.md, Invariant 7). That is why a descriptor
// carries an `index` rather than a `minimum`/`maximum` of its own, and why this
// package imports src/patch but never src/engine: a client links the registry
// to understand the synth without linking the audio engine.

Parameter_Kind :: enum {
	Float,
	Integer,
	Boolean,
	Enum,
}

// A semantic hint for a client's formatting and gesture choices. It does not
// change how a value is stored or validated; it says what the number means.
Parameter_Unit :: enum {
	None,
	Hertz,
	Decibel,
	Percent,
	Cents,
	Seconds,
	Semitones,
}

// How a normalised 0..1 control position maps onto the value. Advisory in this
// slice; a later slice uses it to shape a client's slider law.
Parameter_Scale :: enum {
	Linear,
	Logarithmic,
	Exponential,
	Stepped,
	Enumerated,
}

Parameter_Descriptor :: struct {
	id:    string,
	label: string,
	group: string,
	// The src/patch VST parameter index this id binds to. Every numeric fact is
	// derived from the measured table at this index.
	index: int,
	kind:  Parameter_Kind,
	unit:  Parameter_Unit,
	scale: Parameter_Scale,
}
