package patch

import "core:sync"

// The factory bank, carried inside the binary.
//
// A Program Change selects a patch by number, so a plugin has to have patches
// to select -- and it has to have them with no editor open, because a host can
// send a program change to a plugin whose window has never been shown. The
// panel owns a bank in the browser build; a plugin has no panel to own one, so
// the bank is compiled in.
//
// Embedded rather than read from a file beside the plugin. A CLAP plugin on
// Windows is a single file with no bundle to put a bank inside, so reading one
// would mean inventing an install location and then being wrong about it on
// somebody's machine. Fifty kilobytes in the binary costs nothing and cannot go
// missing.
//
// Here rather than in either host because both want it and the answer must not
// differ between them: the same file tools/factorybank writes and the panel
// reads, so every build has the same sounds under the same numbers. That is the
// whole point of addressing them by number.
FACTORY_JSON := #load("../../patches/quesynth/factory.json")

// A bank is a hundred and twenty-eight slots, however few hold a sound. See
// ui/app.js on why that number.
FACTORY_SLOTS :: 128

@(private = "file")
factory_values: [FACTORY_SLOTS][PARAMETER_COUNT]int
@(private = "file")
factory_filled: [FACTORY_SLOTS]bool

// The names, copied rather than borrowed.
//
// destroy_bank frees what the parser cloned, so holding its strings would be
// holding freed memory. A fixed buffer per slot avoids owning an allocation for
// the life of the process and keeps this readable from the audio thread, which
// is where a program change arrives. Longer names are cut rather than refused:
// a name is a label, and a truncated label still selects the right sound.
@(private = "file")
NAME_MAX :: 48
@(private = "file")
factory_names: [FACTORY_SLOTS][NAME_MAX]u8
@(private = "file")
factory_name_len: [FACTORY_SLOTS]int
@(private = "file")
factory_once: sync.Once

@(private = "file")
build_factory :: proc() {
	bank, err := parse_bank_json(FACTORY_JSON)
	if err != .None {
		// Left empty. A program change then selects nothing rather than
		// selecting rubbish, and the instrument goes on working.
		return
	}
	defer destroy_bank(bank)

	for p, i in bank.patches {
		if i >= FACTORY_SLOTS {break}
		// An empty slot stays empty. It is still addressable -- program 47 is
		// always program 47 -- but there is nothing to load out of it.
		if bank.filled != nil && i < len(bank.filled) && !bank.filled[i] {continue}
		factory_values[i] = p.values
		factory_filled[i] = true

		name := p.name
		length := min(len(name), NAME_MAX)
		for j in 0 ..< length {
			factory_names[i][j] = name[j]
		}
		factory_name_len[i] = length
	}
}

// Read the bank in. Call from a plugin's init, which is allowed to allocate.
//
// Once per process however many instances a host makes: sixteen copies of the
// plugin would otherwise parse the same fifty kilobytes sixteen times for an
// answer that cannot differ.
factory_prepare :: proc() {
	sync.once_do(&factory_once, build_factory)
}

// What to call a slot.
//
// An empty one is named rather than left blank, because a host's program menu
// has to have an entry for it: a gap would make the numbering in that menu stop
// matching the numbering everywhere else, and the number is the whole point.
factory_name :: proc "contextless" (slot: int) -> string {
	if slot < 0 || slot >= FACTORY_SLOTS {return "—"}
	if !factory_filled[slot] || factory_name_len[slot] == 0 {return "Init"}
	return string(factory_names[slot][:factory_name_len[slot]])
}

// The patch in a slot, and whether there is one.
//
// Contextless, because a program change arrives on the audio thread and
// everything on that path has to be callable without establishing a context.
// It only reads what factory_prepare left behind.
factory_patch :: proc "contextless" (slot: int) -> (values: [PARAMETER_COUNT]int, ok: bool) {
	if slot < 0 || slot >= FACTORY_SLOTS {return {}, false}
	if !factory_filled[slot] {return {}, false}
	return factory_values[slot], true
}
