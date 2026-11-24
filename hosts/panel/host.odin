package panel

import "../../src/patch"

// What the panel needs from whatever is hosting it.
//
// A struct of procedures rather than an interface: there are two callers, they
// are both plugins, and the alternative is generics over something that is not
// a type.
//
// Here and not beside the web view so that the protocol -- protocol.odin, which
// is all of what the panel says and hears -- can be checked on any platform
// with no web view under it.
Host :: struct {
	user:            rawptr,

	// How many parameters there are, and how to read them.
	param_count:     int,
	read_values:     proc(user: rawptr, out: []i32),

	// The panel moved one parameter.
	set_param:       proc(user: rawptr, index: int, stored: i32),
	// The panel loaded a whole patch. One call rather than ninety-nine: a host
	// that rebound per parameter would be audible as a smear.
	set_state:       proc(user: rawptr, values: []i32),
	// The edges of a gesture, so a host can record automation for the drag
	// rather than for the samples it happened to see.
	edit:            proc(user: rawptr, index: int, begin: bool),

	note:            proc(user: rawptr, on: bool, note: int, velocity: f32),
	bend:            proc(user: rawptr, amount: f32),
	control:         proc(user: rawptr, cc: int, value: f32),
	volume:          proc(user: rawptr, amount: f32),

	// The panel's bank changed -- a patch written into a slot, a bank
	// loaded from a file. The text is a whole quesynth.bank document, and
	// is handed over as text rather than as something parsed so that what
	// is written to disk is exactly what the panel produced. The panel's
	// writer and src/patch's reader already agree; re-encoding it in the
	// middle would be a third implementation to keep in step.
	// `save` separates the two questions this message answers. The bank is
	// always adopted -- a plugin selecting patches out of a bank the panel
	// is not showing means one program number is two sounds -- but only the
	// panel's own bank is written to disk. A bank somebody opened from a
	// .zip or a folder is already on disk under its own name, and browsing
	// one should not overwrite what they had saved.
	// `origin` is what the panel calls the bank, or none from a panel that
	// does not say. The answer is what became of it, for the panel to be
	// told when it asked for the bank to be kept.
	set_bank:        proc(user: rawptr, text: string, save: bool, origin: Origin) -> Bank_Result,
	// The bank the host holds, as a quesynth.bank document. Borrowed from
	// the temporary allocator: it is written into one message and not kept.
	read_bank:       proc(user: rawptr) -> string,

	// The rest is what a host that remembers which preset it is playing
	// adds. A host that sets none of it is spoken to as it always was, in
	// messages with nothing new in them.
	//
	// The session and the bank it describes. Borrowed: read to build one
	// message and not kept.
	read_session:    proc(user: rawptr) -> Instance_View,
	// The panel loaded a preset, or says which one it is on. The host records
	// it and, if it keeps a program number, moves that.
	select:          proc(user: rawptr, selection: Selection),
	// Try the failed restore again. Answers whether the bank being played
	// changed, which the panel is then handed again.
	restore_retry:   proc(user: rawptr) -> bool,
	// The user dismissed a failed restore.
	restore_discard: proc(user: rawptr),
}

// An instance's bank and what it knows about it, as the panel is told them.
Instance_View :: struct {
	session: ^Session,
	slots:   ^patch.Slots,
}
