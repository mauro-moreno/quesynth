package registry

// Slice 2 registers three parameters, deliberately: enough to prove IDs,
// metadata, validation and the engine bridge end to end without migrating the
// whole synth. Slice 5 fills the table out into the full grouped set.
//
// The ids are stable API identifiers and must not change with a UI redesign;
// the labels may. The index comments name the measured parameter each id binds
// to; a test asserts the id still points at that name, so a table reindex
// cannot silently repoint an id.
DESCRIPTORS := [?]Parameter_Descriptor {
	{
		id = "master.volume",
		label = "Volume",
		group = "global",
		index = 29, // amp gain
		kind = .Float,
		unit = .Decibel,
		scale = .Linear,
	},
	{
		id = "filter.cutoff",
		label = "Cutoff",
		group = "filter",
		index = 19, // *filter freq
		kind = .Float,
		unit = .Hertz,
		scale = .Logarithmic,
	},
	{
		id = "filter.resonance",
		label = "Resonance",
		group = "filter",
		index = 20, // *filter resonance
		kind = .Float,
		unit = .Percent,
		scale = .Linear,
	},
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
