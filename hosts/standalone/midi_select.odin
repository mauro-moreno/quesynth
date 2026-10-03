package standalone

// Which native MIDI inputs the daemon listens to, as every front-end names it.
//
// The daemon owns this rather than each client, for the reason it owns the
// patch identity: the TUI and the browser page are peers of one daemon, and a
// keyboard that each of them attached on its own would play every note twice.
// So there is one selection, here, and both read and change it with midi.list,
// midi.select and midi.current.
//
// Only the control thread touches it -- every command runs on the one poll
// thread, and the daemon's main thread only before serving starts and after it
// has stopped -- so it needs no lock. The reader threads and callbacks the
// backend runs never see it: they push into the queue exactly as they always
// have, and the audio thread drains that queue unchanged.
//
// Fixed buffers, like Patch_Identity, so nothing in it is allocated on one
// thread and freed on another.

// The two tokens that are not device ids. No backend reports either as an id.
MIDI_SELECT_ALL :: "all"
MIDI_SELECT_NONE :: "none"

MIDI_NAME_ALL :: "All inputs"
MIDI_NAME_NONE :: "None"

// Room for any id a backend makes: hw:<card>,<device> and winmm:<index> are a
// dozen bytes. A longer id could not be stored whole, so it is not selectable.
MIDI_TOKEN_MAX :: 64
// ALSA names a raw-MIDI port in at most 80 bytes, WinMM in 32 UTF-16 units.
MIDI_NAME_MAX :: 128

Midi_Selection :: struct {
	input:     ^Midi_Input,
	queue:     ^Midi_Queue,
	// "all", "none" or an id the backend listed.
	token:     [MIDI_TOKEN_MAX]u8,
	token_len: int,
	// What midi.current names: the two fixed names, or the device's name as
	// the backend listed it when it was chosen, truncated to fit.
	name:      [MIDI_NAME_MAX]u8,
	name_len:  int,
	// Bumped once per real change, so a polling peer learns from one number
	// that the other one changed the selection.
	rev:       uint,
}

Midi_Select_Result :: enum {
	Ok,
	// The token is neither all, none nor an input the backend lists now.
	Unknown_Input,
	// The input is listed but would not open; the previous selection is back.
	Open_Failed,
	// The backend cannot close what it opened, so it cannot switch at all.
	Unavailable,
}

// Open every input, as the daemon always has, and record that as the
// selection. Starting is not a change, so rev stays 0.
midi_selection_init :: proc(s: ^Midi_Selection, input: ^Midi_Input, queue: ^Midi_Queue) {
	s^ = Midi_Selection {
		input = input,
		queue = queue,
	}
	midi_selection_open(s, MIDI_SELECT_ALL)
	midi_selection_record(s, MIDI_SELECT_ALL, MIDI_NAME_ALL)
}

midi_selection_token :: proc(s: ^Midi_Selection) -> string {
	return string(s.token[:s.token_len])
}

midi_selection_name :: proc(s: ^Midi_Selection) -> string {
	return string(s.name[:s.name_len])
}

// Every input the backend reports now; the caller frees the list with
// midi_devices_free. A backend that cannot enumerate reports none.
midi_selection_list :: proc(s: ^Midi_Selection) -> []Midi_Device {
	if s.input == nil || s.input.list == nil {
		return nil
	}
	return s.input.list(s.input)
}

// Listen to `token` instead: "all", "none" or an id from midi_selection_list.
midi_selection_set :: proc(s: ^Midi_Selection, token: string) -> Midi_Select_Result {
	if s.input == nil || s.input.close_inputs == nil {
		return .Unavailable
	}
	// Already listening to exactly that. Reopening would only drop and
	// restart the reader, and a careless backend would start a second one.
	if token == midi_selection_token(s) {
		return .Ok
	}
	if len(token) > MIDI_TOKEN_MAX {
		return .Unknown_Input
	}

	devices: []Midi_Device
	defer midi_devices_free(devices)
	name := MIDI_NAME_ALL
	switch token {
	case MIDI_SELECT_ALL:
	case MIDI_SELECT_NONE:
		name = MIDI_NAME_NONE
	case:
		// Checked against what is plugged in now, not against a list a client
		// read before the controller was unplugged.
		devices = midi_selection_list(s)
		known := false
		for d in devices {
			if d.id == token {
				name = d.name
				known = true
				break
			}
		}
		if !known {
			return .Unknown_Input
		}
	}

	// Close before open: no device ever has two readers, and every event the
	// old set pushed is in the queue before the first one from the new set.
	s.input.close_inputs(s.input)
	if !midi_selection_open(s, token) {
		s.input.close_inputs(s.input)
		midi_selection_open(s, midi_selection_token(s))
		return .Open_Failed
	}
	midi_selection_record(s, token, name)
	s.rev += 1
	return .Ok
}

@(private = "file")
midi_selection_open :: proc(s: ^Midi_Selection, token: string) -> bool {
	switch token {
	case MIDI_SELECT_NONE:
		return true
	case MIDI_SELECT_ALL:
		return s.input.open != nil && s.input.open(s.input, s.queue)
	case:
		return s.input.open_device != nil && s.input.open_device(s.input, s.queue, token)
	}
}

@(private = "file")
midi_selection_record :: proc(s: ^Midi_Selection, token, name: string) {
	s.token_len = copy(s.token[:], token)
	s.name_len = copy(s.name[:], name)
}
