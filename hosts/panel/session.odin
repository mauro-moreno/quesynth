package panel

import "../../src/patch"

// Which preset an instance is playing, and what became of the last attempt to
// put it back.
//
// This lives on the instance and not on the panel, which is the point of it.
// The editor is created and destroyed as often as a host likes -- every time a
// floating FX window is closed and opened -- and what the instance was playing
// has to outlive that. The panel used to be the only thing that knew, and it
// answered a reopen by loading slot 0.
//
// Nothing here touches the sound. The parameter values are the host's, saved
// and restored by every format as they always were; this is the label on them.
// That is also why a restore that fails is harmless to the sound: it only
// fails to say where the sound came from.

// Where a preset, or a bank, comes from. The same words ui/bridge.js and the
// trailer use.
Origin :: enum u8 {
	None,
	Factory,
	User,
	Imported,
	Archive,
	File,
	Session,
}

// None has no word of its own on the wire: a sound with no known source is a
// session sound.
origin_word :: proc "contextless" (origin: Origin) -> string {
	switch origin {
	case .Factory:
		return "factory"
	case .User:
		return "user"
	case .Imported:
		return "imported"
	case .Archive:
		return "archive"
	case .File:
		return "file"
	case .None, .Session:
		return "session"
	}
	return "session"
}

origin_from_word :: proc(word: string) -> Origin {
	switch word {
	case "factory":
		return .Factory
	case "user":
		return .User
	case "imported":
		return .Imported
	case "archive":
		return .Archive
	case "file":
		return .File
	case "session":
		return .Session
	}
	return .None
}

// A name that fits in the trailer's one length byte, held in the instance.
TEXT_MAX :: 255

Text :: struct {
	bytes: [TEXT_MAX]u8,
	len:   u8,
}

// Cut at a character boundary: a bank called something in a language that
// needs three bytes a letter must not come back as invalid UTF-8 in a message
// that a web page then refuses.
text_set :: proc "contextless" (t: ^Text, text: string) {
	n := min(len(text), TEXT_MAX)
	for n > 0 && n < len(text) && text[n] & 0xC0 == 0x80 {
		n -= 1
	}
	for i in 0 ..< n {
		t.bytes[i] = text[i]
	}
	t.len = u8(n)
}

// Borrowed from `t`: valid until it changes.
text_get :: proc "contextless" (t: ^Text) -> string {
	return string(t.bytes[:t.len])
}

// What an instance is playing: which slot of which bank, under which name.
Selection :: struct {
	// None: nothing is known. A state from before the trailer, or an instance
	// nobody has selected anything on. It is never read as slot 0.
	origin:     Origin,
	has_slot:   bool,
	slot:       int,
	// A selection the instance made itself -- a program change, a restore --
	// names a slot of the bank it is playing out of, and its label and name
	// are read from that bank when they are asked for. They are not copied:
	// writing a patch into the slot has to change what the strip says, and a
	// program change arrives on the audio thread, which copies nothing.
	//
	// One that came from the panel carries its own, and is bound only while
	// the bank it names is the bank being played.
	bound:      bool,
	// The slot had nothing in it, in its bank, when the state this came out of
	// was saved. Only a selection read from a trailer has it, which is what a
	// failed restore holds on to; a live one is asked of the bank when it is
	// saved, because a slot can be written into or cleared after it is
	// selected, and the state has to say what was true when it was written.
	slot_empty: bool,
	label:      Text,
	name:       Text,
}

selection_known :: proc "contextless" (sel: ^Selection) -> bool {
	return sel.origin != .None
}

// A selection in the words the wire uses, borrowed from the selection or from
// the bank it names.
Selection_View :: struct {
	origin:   Origin,
	has_slot: bool,
	slot:     int,
	label:    string,
	name:     string,
}

selection_view :: proc(sel: ^Selection, slots: ^patch.Slots) -> Selection_View {
	view := Selection_View {
		origin   = sel.origin,
		has_slot = sel.has_slot,
		slot     = sel.slot,
	}
	if sel.bound && sel.has_slot {
		view.label = patch.slots_label(slots)
		view.name = patch.slots_name(slots, sel.slot)
	} else {
		view.label = text_get(&sel.label)
		view.name = text_get(&sel.name)
	}
	return view
}

// Where the bank an instance plays out of came from, which decides whether a
// saved state has to carry it.
Bank_Source :: enum u8 {
	// Compiled into the binary. Identical in every instance.
	Built_In,
	// The per-user bank file, which every instance and both formats share.
	Saved,
	// Handed over by the panel and not kept: a bank somebody opened from a
	// file. It exists in this instance's memory and nowhere else, so the
	// project has to carry it or it is gone with the instance.
	Adopted,
}

Restore_State :: enum u8 {
	Not_Requested,
	Restored,
	Failed,
}

// Spelled as the spec spells them, because these are what the panel shows.
Restore_Error :: enum u8 {
	None,
	Missing_Bank,
	Invalid_Program,
	Host_State_Rejected,
	State_Version_Unsupported,
}

restore_error_word :: proc "contextless" (error: Restore_Error) -> string {
	switch error {
	case .Missing_Bank:
		return "MissingBank"
	case .Invalid_Program:
		return "InvalidProgram"
	case .Host_State_Rejected:
		return "HostStateRejected"
	case .State_Version_Unsupported:
		return "StateVersionUnsupported"
	case .None:
		return ""
	}
	return ""
}

// Whether trying again could end differently: a bank can come back, or be
// chosen; a stream that was refused is the same stream next time.
restore_error_recoverable :: proc "contextless" (error: Restore_Error) -> bool {
	return error == .Missing_Bank || error == .Invalid_Program
}

Session :: struct {
	selection:       Selection,
	// What the bank being played is called on the wire.
	bank_origin:     Origin,
	bank_source:     Bank_Source,
	restore:         Restore_State,
	restore_error:   Restore_Error,
	// What a failed restore was asked for, kept until something replaces it so
	// that the next save writes it back and a retry has something to retry.
	// Only ever set along with a failure.
	has_pending:     bool,
	pending:         Selection,
	pending_saved:   bool,
}

// A new instance, after it has loaded the bank it starts with.
session_init :: proc "contextless" (s: ^Session, source: Bank_Source) {
	s^ = {}
	s.bank_source = source
	s.bank_origin = .User if source == .Saved else .Factory
}

// -- selecting ---------------------------------------------------------------

// The instance selected a slot of the bank it is playing: a Program Change.
//
// The audio thread calls this, so it writes a handful of words and nothing
// else. A program change is a choice like any other and ends whatever restore
// was waiting to be retried.
session_select_slot :: proc "contextless" (s: ^Session, slot: int) {
	s.selection.origin = s.bank_origin if s.bank_origin != .None else .Factory
	s.selection.has_slot = true
	s.selection.slot = slot
	s.selection.bound = true
	s.has_pending = false
	s.restore = .Not_Requested
	s.restore_error = .None
}

// The panel says what it selected.
//
// A slot that is not one of the hundred and twenty-eight is refused, not
// clamped: an identity that names the wrong slot is worse than none.
session_select :: proc(s: ^Session, slots: ^patch.Slots, request: Selection) -> bool {
	sel := request
	if sel.has_slot && (sel.slot < 0 || sel.slot >= patch.FACTORY_SLOTS) {
		return false
	}
	if sel.origin == .None {
		sel.origin = s.bank_origin if sel.has_slot else .Session
	}
	selection_bind(&sel, slots)
	s.selection = sel
	session_forget_restore(s)
	return true
}

// Bound when it names the bank being played, which is the only case where its
// slot means anything to this instance.
@(private)
selection_bind :: proc(sel: ^Selection, slots: ^patch.Slots) {
	sel.bound = sel.has_slot && text_get(&sel.label) == patch.slots_label(slots)
}

session_forget_restore :: proc "contextless" (s: ^Session) {
	s.has_pending = false
	s.pending = {}
	s.restore = .Not_Requested
	s.restore_error = .None
}

// -- the bank ----------------------------------------------------------------

Bank_Result :: enum u8 {
	// Adopted, and nothing more was asked.
	Adopted,
	// Adopted and written to the per-user bank file.
	Saved,
	// Not a bank. Nothing changed.
	Invalid_Bank,
	// Adopted, but the file could not be written. It is still played, and being
	// held only in memory it travels with the project instead.
	Persistence_Failed,
}

// The panel's bank, played from now on, and kept when it asked for that.
//
// `write` is the one thing that differs between formats: where the per-user
// bank file is. The Audio Unit has its own.
session_set_bank :: proc(
	s: ^Session,
	slots: ^patch.Slots,
	text: string,
	save: bool,
	origin: Origin,
	write: proc(text: string) -> bool,
) -> Bank_Result {
	parsed, err := patch.parse_bank_json(transmute([]u8)text)
	if err != .None {
		// Refused rather than written: a bank that will not parse would come
		// back as no bank at all on the next start.
		return .Invalid_Bank
	}
	defer patch.destroy_bank(parsed)

	// A selection that was bound to the bank about to go keeps what it was
	// called, so that it can be told it no longer names this one.
	sel := &s.selection
	if sel.bound && sel.has_slot {
		text_set(&sel.label, patch.slots_label(slots))
		text_set(&sel.name, patch.slots_name(slots, sel.slot))
	}

	// Always played, only sometimes kept. A plugin selecting patches out of a
	// bank the panel is not showing means one program number is two sounds;
	// writing to disk is the separate question, and only the panel's own bank
	// answers yes to it.
	patch.slots_load(slots, parsed)
	selection_bind(sel, slots)

	if save && write != nil && write(text) {
		// The per-user file is the user's bank, whatever the page called it:
		// it is what a new instance reads back.
		s.bank_source = .Saved
		s.bank_origin = .User
		return .Saved
	}
	s.bank_source = .Adopted
	s.bank_origin = origin if origin != .None else .Imported
	return .Persistence_Failed if save else .Adopted
}

// -- saving ------------------------------------------------------------------

// The trailer for a state save, or nil when there is nothing to say.
//
// Nothing to say is an instance that has never been told what it is playing
// and is playing a bank every instance has anyway. Its state is then exactly
// the bytes it always was.
session_trailer :: proc(s: ^Session, slots: ^patch.Slots, allocator := context.allocator) -> []u8 {
	t: Trailer
	label := patch.slots_label(slots)

	if s.has_pending {
		// What a failed restore was asked for, written back until something
		// replaces it, so that saving the project does not turn a bank that is
		// only missing for now into one that was never there.
		p := &s.pending
		t.origin = p.origin
		t.has_slot = p.has_slot
		t.slot = p.slot
		t.label = p.label
		t.name = p.name
		t.slot_empty = p.has_slot && p.slot_empty
		if p.has_slot && text_get(&p.label) != label {
			// It names a bank this instance is not playing, so what the
			// instance is playing is not the bank this identity belongs to.
			t.bank_saved = s.pending_saved
			return trailer_encode(&t, allocator)
		}
	} else if selection_known(&s.selection) {
		view := selection_view(&s.selection, slots)
		if view.has_slot && view.label != label {
			// A slot of some other bank than the one playing is not a slot of
			// this one, and written as one it would come back as somebody
			// else's sound.
			t.origin = .Session
			text_set(&t.name, view.name)
		} else {
			t.origin = view.origin
			t.has_slot = view.has_slot
			t.slot = view.slot
			text_set(&t.label, view.label)
			text_set(&t.name, view.name)
			// Asked of the bank being saved and not of the selection, which
			// may have been made before the slot was written into or
			// cleared. An empty slot reads as "Init", as it does in the
			// page, so the name written is the one the strip shows.
			t.slot_empty = view.has_slot && !slot_is_filled(slots, view.slot)
		}
	} else if s.bank_source == .Adopted {
		// No selection, but a bank nothing else will bring back. The origin
		// stays none: nothing was selected, and a restore must not make it so.
		text_set(&t.label, label)
	} else {
		return nil
	}

	switch s.bank_source {
	case .Built_In:
	case .Saved:
		t.bank_saved = true
	case .Adopted:
		json := patch.slots_write_json(slots, allocator)
		defer delete(json, allocator)
		t.embedded = true
		t.bank_json = transmute([]u8)json
		return trailer_encode(&t, allocator)
	}
	return trailer_encode(&t, allocator)
}

// -- restoring ---------------------------------------------------------------

Restore_Result :: struct {
	// The state carried a selection trailer.
	requested:   bool,
	restored:    bool,
	error:       Restore_Error,
	// The slot the instance is now on, when the restore put it on one.
	has_program: bool,
	program:     int,
}

// Put an instance back on the preset a saved state names.
//
// `bytes` is what followed the parameter values. The sound is not an input
// and is not touched: the values were restored by the format before this ran
// and nothing here may take them back. A restore that fails changes nothing
// about what is playing -- not the bank, not the program, not the sound. It
// only keeps what it was asked for.
//
//   no trailer          nothing to restore; and an instance no longer claims to
//                       know what the sound it now holds came from
//   not understood      HostStateRejected, or StateVersionUnsupported for a
//                       trailer from a newer build
//   embedded bank       parsed and, if it holds the slot, played from now on,
//                       and never written to disk
//   a bank by name      the playing bank must be that bank, else MissingBank
//   a slot              must be one of the 128, and filled unless the state
//                       says it was empty when it was saved, else
//                       InvalidProgram. An empty slot is a slot the page can
//                       select, so that selection comes back too: the bank
//                       is adopted and the program is the slot, the sound
//                       staying what the host restored
session_restore :: proc(s: ^Session, slots: ^patch.Slots, bytes: []u8) -> Restore_Result {
	t, status := trailer_decode(bytes)

	switch status {
	case .Absent:
		s.selection = {}
		session_forget_restore(s)
		return {}
	case .Unknown_Version:
		return restore_failed(s, nil, false, .State_Version_Unsupported)
	case .Truncated, .Oversize, .Malformed:
		return restore_failed(s, nil, false, .Host_State_Rejected)
	case .Ok:
	}

	wanted := selection_of(&t)
	label := text_get(&t.label)

	target := slots
	candidate: ^patch.Slots
	defer free(candidate)
	if t.embedded {
		parsed, err := patch.parse_bank_json(t.bank_json)
		if err != .None {
			return restore_failed(s, &wanted, t.bank_saved, .Host_State_Rejected)
		}
		defer patch.destroy_bank(parsed)
		candidate = new(patch.Slots)
		patch.slots_load(candidate, parsed)
		target = candidate
		// A trailer that says one bank and carries another is not one this
		// build wrote.
		if t.has_slot && patch.slots_label(candidate) != label {
			return restore_failed(s, &wanted, t.bank_saved, .Host_State_Rejected)
		}
	} else if t.has_slot && patch.slots_label(slots) != label {
		return restore_failed(s, &wanted, t.bank_saved, .Missing_Bank)
	}

	// After the bank was looked at and not before: an embedded bank is what
	// the project carries, and refusing the slot first threw it away with the
	// bank that was all there.
	if t.has_slot && !slot_restorable(target, t.slot, t.slot_empty) {
		return restore_failed(s, &wanted, t.bank_saved, .Invalid_Program)
	}

	if t.embedded {
		slots^ = candidate^
		s.bank_source = .Adopted
		// What the page called it when it handed it over is not in the state;
		// an adopted bank that held a slot is somebody's imported bank.
		s.bank_origin = t.origin if t.origin == .User || t.origin == .Imported else .Imported
	}
	return restore_succeeded(s, wanted)
}

@(private)
selection_of :: proc(t: ^Trailer) -> Selection {
	sel := Selection {
		origin     = t.origin,
		has_slot   = t.has_slot,
		slot       = t.slot,
		label      = t.label,
		name       = t.name,
		slot_empty = t.slot_empty,
	}
	return sel
}

@(private)
slot_is_filled :: proc "contextless" (slots: ^patch.Slots, slot: int) -> bool {
	return slot >= 0 && slot < patch.FACTORY_SLOTS && slots.filled[slot]
}

// Whether a state that named `slot` can be put back on `slots`.
//
// A slot with nothing in it is a slot all the same -- interior empty slots stay
// addressable -- and a state saved while one was selected says so. What it must
// not do is excuse a state that named a sound: that slot being empty now is a
// sound that went missing, which is what InvalidProgram is for. A number that
// is no slot at all is never restorable, whatever the state says of it.
@(private)
slot_restorable :: proc "contextless" (slots: ^patch.Slots, slot: int, was_empty: bool) -> bool {
	if slot < 0 || slot >= patch.FACTORY_SLOTS {
		return false
	}
	return was_empty || slots.filled[slot]
}

@(private)
restore_failed :: proc(s: ^Session, wanted: ^Selection, bank_saved: bool, error: Restore_Error) -> Restore_Result {
	s.restore = .Failed
	s.restore_error = error
	s.has_pending = wanted != nil
	s.pending = wanted^ if wanted != nil else {}
	s.pending_saved = bank_saved
	return Restore_Result{requested = true, error = error}
}

@(private)
restore_succeeded :: proc(s: ^Session, wanted: Selection) -> Restore_Result {
	sel := wanted
	// A slot of the bank being played is called what that bank is called. The
	// state may say otherwise -- written when the bank was the factory one, read
	// where it is the user's saved copy of it -- and the panel has been told the
	// bank's origin, so two names for one bank would be two banks to it.
	if sel.has_slot && s.bank_origin != .None {
		sel.origin = s.bank_origin
	}
	// What the state names is the bank being played, by the checks above, so
	// the label and name are the bank's from here on.
	sel.bound = sel.has_slot
	sel.slot_empty = false
	s.selection = sel
	s.has_pending = false
	s.pending = {}
	s.restore = .Restored
	s.restore_error = .None

	result := Restore_Result {
		requested = true,
		restored  = true,
	}
	if sel.has_slot {
		result.has_program = true
		result.program = sel.slot
	}
	return result
}

// Try a failed restore again. `saved` is the per-user bank as the file holds
// it now, or nil when there is no file.
//
// A bank that was missing may have come back, either in the file or in the
// panel having handed it over since, and an instance has to be able to say so.
// The saved bank is taken only if it is the bank that was asked for: the
// retry is the user asking for that bank, not for whatever the file holds.
// Returns whether the bank being played changed.
session_retry :: proc(s: ^Session, slots: ^patch.Slots, saved: ^patch.Slots) -> (result: Restore_Result, bank_changed: bool) {
	if s.restore != .Failed || !s.has_pending || !restore_error_recoverable(s.restore_error) {
		return Restore_Result{requested = s.restore != .Not_Requested, error = s.restore_error}, false
	}

	wanted := s.pending
	label := text_get(&wanted.label)
	target := slots
	from_file := false
	if wanted.has_slot && patch.slots_label(slots) != label {
		if saved == nil || patch.slots_label(saved) != label {
			return restore_failed(s, &wanted, s.pending_saved, .Missing_Bank), false
		}
		target = saved
		from_file = true
	}
	if wanted.has_slot && !slot_restorable(target, wanted.slot, wanted.slot_empty) {
		return restore_failed(s, &wanted, s.pending_saved, .Invalid_Program), false
	}

	if from_file {
		slots^ = saved^
		s.bank_source = .Saved
		s.bank_origin = .User
		bank_changed = true
	}
	return restore_succeeded(s, wanted), bank_changed
}

// The user dismissed it. Nothing is put back and nothing is remembered.
session_discard :: proc "contextless" (s: ^Session) {
	session_forget_restore(s)
}
