package patch

import "base:intrinsics"

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
	// Seqlock for the main-thread bank replacement. Audio readers retry rather
	// than observing a partially copied ~50 KB bank.
	revision: u64,
}

@(private = "file")
put_name :: proc "contextless" (into: ^[SLOT_NAME_MAX]u8, length: ^int, text: string) {
	n := min(len(text), SLOT_NAME_MAX)
	// Not through the middle of a character. A name cut there is not UTF-8,
	// and it goes on to be sent to the panel and written into saved states,
	// where a reader that wants text refuses it -- which for a bank's label
	// meant a project that could never find its bank again.
	for n > 0 && n < len(text) && text[n] & 0xC0 == 0x80 {
		n -= 1
	}
	for i in 0 ..< n {
		into[i] = text[i]
	}
	length^ = n
}

// The writer's half of the seqlock. The release fence keeps the payload writes
// that follow from becoming visible before the odd revision does; without it
// a weakly ordered CPU (Apple Silicon) can show a reader half a bank under a
// revision that still looks settled.
@(private = "file")
slots_begin_write :: proc "contextless" (s: ^Slots) -> u64 {
	revision := intrinsics.atomic_load_explicit(&s.revision, .Relaxed) + 1
	if revision & 1 == 0 {revision += 1}
	intrinsics.atomic_store_explicit(&s.revision, revision, .Relaxed)
	intrinsics.atomic_thread_fence(.Release)
	return revision
}

@(private = "file")
slots_end_write :: proc "contextless" (s: ^Slots, revision: u64) {
	intrinsics.atomic_store_explicit(&s.revision, revision + 1, .Release)
}

// Fill from a parsed bank.
//
// An empty slot stays empty: it is addressable, and there is nothing in it.
// Slots past the end of a short bank stay empty too, which is what pads a
// sixteen-entry file back out to a hundred and twenty-eight.
slots_load :: proc(s: ^Slots, bank: Bank) {
	if s == nil {return}
	revision := slots_begin_write(s)
	// Clear payload only; copying a zero Slots here would overwrite the
	// seqlock and briefly publish an even revision over half-written data.
	s.values = {}
	s.filled = {}
	s.names = {}
	s.name_len = {}
	s.label = {}
	s.label_len = 0
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
	slots_end_write(s, revision)
}

// Fill from the bank compiled into the binary. What a plugin starts with when
// nothing has been saved yet.
slots_load_factory :: proc(s: ^Slots) {
	if s == nil {return}
	revision := slots_begin_write(s)
	// Clear payload only; preserve the odd lock state while filling it.
	s.values = {}
	s.filled = {}
	s.names = {}
	s.name_len = {}
	s.label = {}
	s.label_len = 0
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
	slots_end_write(s, revision)
}

// Replace a live bank under the same seqlock used by slots_load.
slots_replace :: proc(dst, src: ^Slots) {
	if dst == nil || src == nil {return}
	revision := slots_begin_write(dst)
	next := src^
	next.revision = revision
	dst^ = next
	slots_end_write(dst, revision)
}

// Contextless, because a program change arrives on the audio thread.
slots_patch :: proc "contextless" (s: ^Slots, slot: int) -> (values: [PARAMETER_COUNT]i32, ok: bool) {
	if s == nil || slot < 0 || slot >= FACTORY_SLOTS {return {}, false}
	for {
		before := intrinsics.atomic_load_explicit(&s.revision, .Acquire)
		if before & 1 != 0 {continue}
		filled := s.filled[slot]
		if filled {values = s.values[slot]}
		intrinsics.atomic_thread_fence(.Acquire)
		after := intrinsics.atomic_load_explicit(&s.revision, .Relaxed)
		if before == after {return values, filled}
	}
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
