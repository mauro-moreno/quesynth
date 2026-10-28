package panel

import "core:encoding/json"
import "core:strings"

import "../../src/patch"

// What the panel says and what it is told, with no web view anywhere in it.
//
// The types are the ones listed at the top of ui/bridge.js. This file turns a
// message from the page into calls on a Host, and a Host's answers into the
// messages the page is sent, in the order it has to receive them. It posts
// nothing and owns no window: handle_message returns the replies as text and
// panel.odin, which knows the web view, carries them. That is what lets the
// order and the exact bytes be checked on every platform, and an order is a
// thing worth checking -- see `sync`.
//
// Every message to the page that carries something new is stamped "v":1, which
// is how a page learns the host can be told about selections: it sends those
// only after it has seen one. A host that answers none of the new callbacks
// gets the messages it always did, with nothing added.

// -- messages from the panel -------------------------------------------------

// Everything the interface sends arrives here as one JSON object, and what
// comes back is what to post in answer, in order. Borrowed from the temporary
// allocator.
handle_message :: proc(h: ^Host, text: string) -> [dynamic]string {
	replies := make([dynamic]string, context.temp_allocator)
	if h == nil || h.user == nil {
		return replies
	}

	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		return replies
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return replies
	}

	kind, has_kind := json_string(object, "type")
	if !has_kind {
		return replies
	}

	switch kind {
	case "sync":
		// The bank first, then the sound.
		//
		// The panel comes up showing the bank compiled into the page, which
		// in a plugin is only what a browser would have used -- the real one
		// is the file the host loaded. Sending it here replaces that copy
		// before anything is played, and sending it *before* the state
		// matters: loading a bank in the panel selects its first patch, which
		// would otherwise overwrite the sound this message is about to send.
		//
		// Then which patch that sound is, and what became of the last
		// restore, after the state for the same reason: they describe it.
		// Neither is sent when the host has nothing to say. A selection it
		// does not know is not slot 0, and a page told it was would load it.
		append_sync(h, &replies)

	case "set":
		index, has_index := json_int(object, "index")
		stored, has_value := json_int(object, "value")
		if !has_index || !has_value || index < 0 || int(index) >= h.param_count {
			return replies
		}
		if h.set_param != nil {
			h.set_param(h.user, int(index), i32(stored))
		}

	case "state":
		// A whole patch at once: stepping the bank, or loading a file.
		//
		// This case was missing from the VST3 editor once, and the symptom was
		// oddly specific -- the panel showed the new patch and the sound did
		// not change. The panel repaints its own controls locally and only then
		// tells the host, so everything visible worked while nothing audible
		// did. It is handled in one place now, which is the point of this file.
		list, has_list := object["values"]
		if !has_list {
			return replies
		}
		array, is_array := list.(json.Array)
		if !is_array {
			return replies
		}
		count := min(len(array), h.param_count)
		values := make([]i32, count, context.temp_allocator)
		for i in 0 ..< count {
			stored, ok := json_value_int(array[i])
			if !ok {
				continue
			}
			values[i] = i32(stored)
		}
		if h.set_state != nil {
			h.set_state(h.user, values)
		}

	case "edit":
		index, has_index := json_int(object, "index")
		begin, has_begin := json_bool(object, "begin")
		if !has_index || !has_begin || index < 0 || int(index) >= h.param_count {
			return replies
		}
		if h.edit != nil {
			h.edit(h.user, int(index), begin)
		}

	case "note":
		note, has_note := json_int(object, "note")
		on, has_on := json_bool(object, "on")
		if !has_note || !has_on {
			return replies
		}
		velocity, has_velocity := json_int(object, "velocity")
		if !has_velocity {
			velocity = 100
		}
		if h.note != nil {
			h.note(h.user, on, int(note), f32(velocity) / 127.0)
		}

	case "wheel":
		which, has_which := json_string(object, "which")
		amount, has_amount := json_float(object, "value")
		if !has_which || !has_amount {
			return replies
		}
		if which == "pitch" {
			if h.bend != nil {
				h.bend(h.user, f32(amount))
			}
		} else if h.control != nil {
			// Controller 1, which is what parameters 86 and 88 name by default.
			h.control(h.user, 1, f32(amount * 127.0))
		}

	case "volume":
		amount, has_amount := json_float(object, "value")
		if !has_amount {
			return replies
		}
		if h.volume != nil {
			h.volume(h.user, f32(clamp(amount, 0, 1)))
		}

	case "bank":
		// A whole bank, as text. Only ever a few tens of kilobytes and only
		// when somebody writes a patch, so there is nothing to be clever
		// about here.
		text, has_text := json_string(object, "text")
		if !has_text || h.set_bank == nil {
			return replies
		}
		// Absent means no: a message without the flag is one from an older
		// panel, and adopting without saving is the safe half.
		save, _ := json_bool(object, "save")
		origin: Origin
		if word, has_word := json_string(object, "origin"); has_word {
			origin = origin_from_word(word)
		}
		result := h.set_bank(h.user, text, save, origin)
		// Told what became of it only when it was asked to be kept: that is
		// the one request whose failure the person who made it would not
		// otherwise see.
		if save {
			append(&replies, message_bank_saved(h, result))
		}

	case "select":
		// Which preset the panel just loaded. Only a panel that has been told
		// the host can use it sends one, so a host that cannot is never
		// asked.
		if h.select == nil {
			return replies
		}
		selection: Selection
		if word, has_word := json_string(object, "origin"); has_word {
			selection.origin = origin_from_word(word)
		}
		if label, has_label := json_string(object, "bank"); has_label {
			text_set(&selection.label, label)
		}
		if name, has_name := json_string(object, "name"); has_name {
			text_set(&selection.name, name)
		}
		// A null slot and no slot are the same thing: a preset with no place
		// in a bank.
		if slot, has_slot := json_int(object, "slot"); has_slot {
			selection.has_slot = true
			selection.slot = int(slot)
		}
		h.select(h.user, selection)

	case "restore-retry":
		if h.restore_retry == nil {
			return replies
		}
		changed := h.restore_retry(h.user)
		// Answered with what the page needs to show the result: the bank if it
		// moved, where the instance now is, and how the restore stands. A
		// retry that failed again is the last of those alone.
		//
		// Always answered. The page marks the banner busy when it asks and
		// shows nothing final until it hears, so a retry with nothing left to
		// retry -- a Program Change let the failure go before the page was
		// told -- has to say so, or the banner waits for good.
		view, versioned := session_view(h)
		if !versioned {
			return replies
		}
		if changed && h.read_bank != nil {
			if text := h.read_bank(h.user); text != "" {
				append(&replies, message_bank(text, &view))
			}
		}
		// Where the instance is, whenever the restore is over: restored, or
		// not held any more. A failure that stands leaves the sound and the
		// selection as the page already has them.
		if view.session.restore != .Failed {
			if message, ok := message_patch(view); ok {
				append(&replies, message)
			}
		}
		if message, ok := message_restore_answer(view); ok {
			append(&replies, message)
		}

	case "restore-discard":
		if h.restore_discard != nil {
			h.restore_discard(h.user)
		}

	case "cc":
		cc, has_cc := json_int(object, "cc")
		amount, has_amount := json_int(object, "value")
		if !has_cc || !has_amount {
			return replies
		}
		if h.control != nil {
			h.control(h.user, int(cc), f32(amount))
		}
	}
	return replies
}

// -- messages to the panel ---------------------------------------------------

// The messages that answer `sync`, in the order the page has to receive them.
// Also what a host sends an open panel after a state load changes what it is
// playing: the same four things have changed.
sync_replies :: proc(h: ^Host) -> [dynamic]string {
	replies := make([dynamic]string, context.temp_allocator)
	if h != nil && h.user != nil {
		append_sync(h, &replies)
	}
	return replies
}

// What a host that moved the instance to another preset itself -- a MIDI
// Program Change -- tells an open panel after the sound: which preset it is
// on, in a message of its own.
//
// The page takes a patch as the host having moved on, and lets go of a failed
// restore it was showing. A failure the host still holds -- the state load
// that failed can land between the Program Change and this message -- is said
// again after the patch, so that the page does not believe it gone.
selection_replies :: proc(h: ^Host) -> [dynamic]string {
	replies := make([dynamic]string, context.temp_allocator)
	if view, versioned := session_view(h); versioned {
		if message, ok := message_patch(view); ok {
			append(&replies, message)
			if view.session.restore == .Failed {
				if again, held := message_restore(view); held {
					append(&replies, again)
				}
			}
		}
	}
	return replies
}

@(private)
append_sync :: proc(h: ^Host, replies: ^[dynamic]string) {
	view, versioned := session_view(h)
	// Nil is how message_bank says it has no session to speak of.
	shown: ^Instance_View
	if versioned {
		shown = &view
	}
	if h.read_bank != nil {
		if text := h.read_bank(h.user); text != "" {
			append(replies, message_bank(text, shown))
		}
	}
	if message, ok := message_state(h); ok {
		append(replies, message)
	}
	if versioned {
		if message, ok := message_patch(view); ok {
			append(replies, message)
		}
		if message, ok := message_restore(view); ok {
			append(replies, message)
		}
	}
}

// The host's session, when it keeps one.
@(private)
session_view :: proc(h: ^Host) -> (view: Instance_View, ok: bool) {
	if h == nil || h.read_session == nil {
		return {}, false
	}
	view = h.read_session(h.user)
	return view, view.session != nil && view.slots != nil
}

// The whole parameter set in one message, which is what the panel asks for when
// it loads. One message rather than ninety-nine because the panel rebuilds its
// controls from it in a single pass.
message_state :: proc(h: ^Host) -> (message: string, ok: bool) {
	if h == nil || h.read_values == nil || h.param_count <= 0 {
		return "", false
	}
	values := make([]i32, h.param_count, context.temp_allocator)
	h.read_values(h.user, values)

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"state","values":[`)
	for v, i in values {
		if i > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, int(v))
	}
	strings.write_string(&builder, `]}`)
	return strings.to_string(builder), true
}

// One parameter that changed somewhere else -- an automation lane, or the
// host's own generic panel -- so the web view follows instead of going stale.
message_param :: proc(index: int, stored: i32) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"param","index":`)
	strings.write_int(&builder, index)
	strings.write_string(&builder, `,"value":`)
	strings.write_int(&builder, int(stored))
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// The bank the plugin holds, handed to the panel.
//
// Sent when the panel asks for state, because in a plugin the bank on disk
// is the real one and the copy compiled into the page is only what a browser
// would have used. Without this the panel would show the factory bank while
// a program change played something else -- which is what it did.
//
// With a session it also says where the bank came from and that it is the
// host's to write to: a plugin keeps whatever the panel asks it to, so nothing
// the host sends is read-only.
message_bank :: proc(text: string, view: ^Instance_View) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"bank","text":`)
	write_json_string(&builder, text)
	if view != nil && view.session != nil {
		strings.write_string(&builder, `,"v":1,"origin":`)
		write_json_string(&builder, origin_word(view.session.bank_origin))
		strings.write_string(&builder, `,"readOnly":false`)
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// Which patch is loaded, by name and by number.
//
// Sent alongside the state after something other than the panel changes the
// sound -- a MIDI program change, most often. Without it every knob moves and
// the strip goes on naming the patch from before, which is the sort of half-lie
// that is worse than no update at all: the interface looks like it is telling
// you what you are playing.
//
// The protocol at the top of ui/bridge.js has always had this message; for a
// long time nothing on this side ever sent one.
//
// Nothing when the instance has no selection. A patch message that said slot 0
// would be believed, and the page would load it.
message_patch :: proc(view: Instance_View) -> (message: string, ok: bool) {
	if view.session == nil || view.slots == nil || !selection_known(&view.session.selection) {
		return "", false
	}
	selection := selection_view(&view.session.selection, view.slots)

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"patch","name":`)
	write_json_string(&builder, selection.name)
	strings.write_string(&builder, `,"index":`)
	write_json_slot(&builder, selection)
	strings.write_string(&builder, `,"bank":`)
	write_json_string(&builder, selection.label)
	strings.write_string(&builder, `,"v":1,"origin":`)
	write_json_string(&builder, origin_word(selection.origin))
	strings.write_byte(&builder, '}')
	return strings.to_string(builder), true
}

// How the last state load's attempt to put the instance back stands.
//
// Nothing when nothing was attempted. A failure says which, whether trying
// again could end differently, and what it was trying to restore when the
// state said: a state too damaged to read names nothing, and none of the last
// four fields is invented for it.
message_restore :: proc(view: Instance_View) -> (message: string, ok: bool) {
	if view.session == nil || view.slots == nil {
		return "", false
	}
	s := view.session

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"restore","v":1,"state":`)
	identity: Selection_View
	named := false
	switch s.restore {
	case .Not_Requested:
		return "", false
	case .Restored:
		strings.write_string(&builder, `"restored"`)
		if selection_known(&s.selection) {
			identity = selection_view(&s.selection, view.slots)
		} else {
			// A bank restored with nothing selected in it.
			identity = Selection_View {
				origin = s.bank_origin,
				label  = patch.slots_label(view.slots),
			}
		}
		named = true
	case .Failed:
		strings.write_string(&builder, `"failed","error":`)
		write_json_string(&builder, restore_error_word(s.restore_error))
		strings.write_string(&builder, `,"recoverable":`)
		strings.write_string(&builder, "true" if restore_error_recoverable(s.restore_error) else "false")
		strings.write_string(&builder, `,"message":`)
		write_json_string(&builder, restore_error_message(s.restore_error))
		if s.has_pending {
			identity = selection_view(&s.pending, view.slots)
			named = true
		}
	}
	if named {
		strings.write_string(&builder, `,"origin":`)
		write_json_string(&builder, origin_word(identity.origin))
		strings.write_string(&builder, `,"bank":`)
		write_json_string(&builder, identity.label)
		strings.write_string(&builder, `,"slot":`)
		write_json_slot(&builder, identity)
		strings.write_string(&builder, `,"name":`)
		write_json_string(&builder, identity.name)
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder), true
}

// The answer to a retry: how the restore stands, and, when nothing is being
// restored, that.
//
// A host holds nothing to restore when none was asked for or when the
// instance has moved to another preset since -- a Program Change lets go of a
// failure. That is an answer the page is waiting for, unlike at `sync`, where
// there is nothing to say and the message is left out: a retry marks the
// banner busy, and only a message resolves it.
message_restore_answer :: proc(view: Instance_View) -> (message: string, ok: bool) {
	if view.session == nil || view.slots == nil {
		return "", false
	}
	if view.session.restore == .Not_Requested {
		return `{"type":"restore","v":1,"state":"notRequested"}`, true
	}
	return message_restore(view)
}

@(private)
restore_error_message :: proc(error: Restore_Error) -> string {
	switch error {
	case .Missing_Bank:
		return "The bank this sound was saved from is not available."
	case .Invalid_Program:
		return "The bank no longer has a patch in the saved slot."
	case .Host_State_Rejected:
		return "The saved selection could not be read."
	case .State_Version_Unsupported:
		return "The saved selection was written by a newer version of Quesynth."
	case .None:
		return ""
	}
	return ""
}

// What became of a bank the panel asked to be kept.
//
// The page marks a patch it wrote as kept for this session only, and says so,
// when the answer is no. Silence would let it claim the write succeeded.
message_bank_saved :: proc(h: ^Host, result: Bank_Result) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"bank-saved","v":1,"ok":`)
	strings.write_string(&builder, "true" if result == .Saved else "false")
	switch result {
	case .Saved:
	case .Persistence_Failed, .Adopted:
		strings.write_string(
			&builder,
			`,"error":"PersistenceFailed","message":"The bank is in use but could not be written to disk."`,
		)
	case .Invalid_Bank:
		strings.write_string(&builder, `,"error":"InvalidBank","message":"The bank could not be read."`)
	}
	// The bank's own name, when there is one to give: an unreadable bank has
	// none, and the one still playing is not it.
	if result != .Invalid_Bank {
		if view, ok := session_view(h); ok {
			strings.write_string(&builder, `,"bank":`)
			write_json_string(&builder, patch.slots_label(view.slots))
		}
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// -- writing JSON ------------------------------------------------------------

@(private)
write_json_slot :: proc(builder: ^strings.Builder, selection: Selection_View) {
	if selection.has_slot {
		strings.write_int(builder, selection.slot)
	} else {
		strings.write_string(builder, "null")
	}
}

// A JSON string, quoted and escaped.
//
// Patch names come out of somebody else's bank and are not this project's to
// vouch for: one containing a quote or a backslash would otherwise produce a
// message the panel cannot parse, and the symptom would be the name silently
// never updating for that one patch.
@(private)
write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\r':
			strings.write_string(builder, `\r`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			// Control characters have to be escaped as well; everything else,
			// UTF-8 included, goes through as bytes.
			if c < 0x20 {
				strings.write_string(builder, `\u00`)
				// Odin will not index a constant string, so the digits are a
				// variable.
				hex := "0123456789abcdef"
				strings.write_byte(builder, hex[(c >> 4) & 0xF])
				strings.write_byte(builder, hex[c & 0xF])
			} else {
				strings.write_byte(builder, c)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// -- reading JSON ------------------------------------------------------------
//
// Small readers rather than a struct and a reflection pass: the messages have
// five shapes between them, and a missing field has to be distinguishable from
// a field that is present and zero.

@(private)
json_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	return string(text), is_string
}

// A number out of a bare JSON value.
//
// The helpers below are keyed by name, which is what every message here needs
// except one: the `state` message carries an array, and its elements have no
// keys to look up.
@(private)
json_value_int :: proc(value: json.Value) -> (int, bool) {
	#partial switch v in value {
	case json.Integer:
		return int(v), true
	case json.Float:
		return int(v), true
	}
	return 0, false
}

@(private)
json_float :: proc(object: json.Object, key: string) -> (f64, bool) {
	value, found := object[key]
	if !found {
		return 0, false
	}
	#partial switch v in value {
	case json.Float:
		return f64(v), true
	case json.Integer:
		return f64(v), true
	}
	return 0, false
}

@(private)
json_int :: proc(object: json.Object, key: string) -> (i64, bool) {
	amount, ok := json_float(object, key)
	if !ok {
		return 0, false
	}
	return i64(amount), true
}

@(private)
json_bool :: proc(object: json.Object, key: string) -> (bool, bool) {
	value, found := object[key]
	if !found {
		return false, false
	}
	flag, is_bool := value.(json.Boolean)
	return bool(flag), is_bool
}
