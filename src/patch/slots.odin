package patch

// A bank a plugin can hold, change and save.
//
// The embedded factory bank in factory.odin is one copy for the whole process
// and never changes; this is per instance and does. It exists because a plugin
// had two banks that were not the same bank: the panel browsed and wrote into
// one compiled into the page, while a program change read the one compiled into
// the binary. They started identical, because both are generated from
// patches/quesynth/factory.json, and diverged the moment anybody wrote a patch
// -- the panel's changed, the plugin's did not, and neither was saved.
//
// So there is one now, and it lives here: the host loads it, program changes
// read it, the panel is handed it, and what the panel sends back is written to
// a file and loaded into it again.
//
// Values as i32 rather than int, which is what both hosts keep their parameters
// in and halves what an instance carries. Names in a fixed buffer, for the
// reason given in factory.odin.

SLOT_NAME_MAX :: 48

Slots :: struct {
	values:   [FACTORY_SLOTS][PARAMETER_COUNT]i32,
	filled:   [FACTORY_SLOTS]bool,
	names:    [FACTORY_SLOTS][SLOT_NAME_MAX]u8,
	name_len: [FACTORY_SLOTS]int,
	// What the bank calls itself, for the panel's strip.
	label:    [SLOT_NAME_MAX]u8,
	label_len: int,
}

@(private = "file")
put_name :: proc "contextless" (into: ^[SLOT_NAME_MAX]u8, length: ^int, text: string) {
	n := min(len(text), SLOT_NAME_MAX)
	for i in 0 ..< n {
		into[i] = text[i]
	}
	length^ = n
}

// Fill from a parsed bank.
//
// An empty slot stays empty: it is addressable, and there is nothing in it.
// Slots past the end of a short bank stay empty too, which is what pads a
// sixteen-entry file back out to a hundred and twenty-eight.
slots_load :: proc(s: ^Slots, bank: Bank) {
	s^ = {}
	put_name(&s.label, &s.label_len, bank.name if bank.name != "" else "Bank")

	for p, i in bank.patches {
		if i >= FACTORY_SLOTS {break}
		if bank.filled != nil && i < len(bank.filled) && !bank.filled[i] {continue}
		for j in 0 ..< PARAMETER_COUNT {
			s.values[i][j] = i32(p.values[j])
		}
		s.filled[i] = true
		put_name(&s.names[i], &s.name_len[i], p.name)
	}
}

// Fill from the bank compiled into the binary. What a plugin starts with when
// nothing has been saved yet.
slots_load_factory :: proc(s: ^Slots) {
	s^ = {}
	put_name(&s.label, &s.label_len, "Factory")
	for i in 0 ..< FACTORY_SLOTS {
		values, ok := factory_patch(i)
		if !ok {continue}
		for j in 0 ..< PARAMETER_COUNT {
			s.values[i][j] = i32(values[j])
		}
		s.filled[i] = true
		put_name(&s.names[i], &s.name_len[i], factory_name(i))
	}
}

// Contextless, because a program change arrives on the audio thread.
slots_patch :: proc "contextless" (s: ^Slots, slot: int) -> (values: [PARAMETER_COUNT]i32, ok: bool) {
	if s == nil || slot < 0 || slot >= FACTORY_SLOTS {return {}, false}
	if !s.filled[slot] {return {}, false}
	return s.values[slot], true
}

slots_name :: proc "contextless" (s: ^Slots, slot: int) -> string {
	if s == nil || slot < 0 || slot >= FACTORY_SLOTS {return "—"}
	if !s.filled[slot] || s.name_len[slot] == 0 {return "Init"}
	return string(s.names[slot][:s.name_len[slot]])
}

slots_label :: proc "contextless" (s: ^Slots) -> string {
	if s == nil || s.label_len == 0 {return "Bank"}
	return string(s.label[:s.label_len])
}

// The bank as a file.
//
// Trailing empty slots are dropped and empty ones in the middle are written as
// null, which is what keeps the numbering: see the note in ui/patchfile.js on
// why position is meaning.
slots_write_json :: proc(s: ^Slots, allocator := context.allocator) -> string {
	last := -1
	for i in 0 ..< FACTORY_SLOTS {
		if s.filled[i] {last = i}
	}

	patches := make([]Patch, last + 1, context.temp_allocator)
	filled := make([]bool, last + 1, context.temp_allocator)
	for i in 0 ..< last + 1 {
		filled[i] = s.filled[i]
		if !s.filled[i] {continue}
		p: Patch
		p.name = slots_name(s, i)
		p.version = SY1_BIPOLAR_VERSION
		for j in 0 ..< PARAMETER_COUNT {
			p.values[j] = int(s.values[i][j])
			p.present[j] = true
		}
		patches[i] = p
	}
	return write_bank_json(slots_label(s), patches, filled, allocator)
}
