package standalone

import "core:strings"

import "../../src/control"

// The MIDI input half of the control protocol: enumerate the native inputs,
// choose which of them the daemon listens to, and report that choice, over the
// daemon's one Midi_Selection. Distinct from the `midi` command, which injects
// a message into the queue and does not care where the inputs stand.

// midi.list: every input the backend reports now -- nothing is cached, so a
// controller plugged in since the last call is there -- with one record line
// per input. all and none are tokens, not inputs, so they are never records.
@(private)
control_midi_list :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	s := cc.midi_select
	if s == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no midi input")
		return
	}
	devices := midi_selection_list(s)
	defer midi_devices_free(devices)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, len(devices))
	control_write_midi_selection(out, s)
	for d in devices {
		strings.write_string(out, "\nid=")
		strings.write_string(out, d.id)
		// name last: it has spaces, so a client reads it to the line end.
		strings.write_string(out, " name=")
		control_write_line(out, d.name)
	}
}

// midi.select <all|none|id>: listen to that from now on.
@(private)
control_midi_select :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	s := cc.midi_select
	if s == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no midi input")
		return
	}
	if req.operand_count != 1 {
		control_write_err(out, req, .Invalid_Payload, "midi.select needs all, none or an input id")
		return
	}
	switch midi_selection_set(s, req.operands[0]) {
	case .Ok:
		control_write_ok(out, req)
		control_write_midi_selection(out, s)
	case .Unknown_Input:
		control_write_err(out, req, .Invalid_Payload, "no such midi input")
	case .Open_Failed:
		control_write_err(out, req, .Internal_Error, "cannot open midi input")
	case .Unavailable:
		control_write_err(out, req, .Daemon_Not_Ready, "no midi input")
	}
}

// midi.current: the selection and its generation, cheap enough for a peer to
// poll beside patch.current. The name is a record line so it keeps its spaces.
@(private)
control_midi_current :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	s := cc.midi_select
	if s == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no midi input")
		return
	}
	control_write_ok(out, req)
	control_write_midi_selection(out, s)
	strings.write_string(out, "\nname=")
	control_write_line(out, midi_selection_name(s))
}

@(private = "file")
control_write_midi_selection :: proc(out: ^strings.Builder, s: ^Midi_Selection) {
	strings.write_string(out, " selected=")
	strings.write_string(out, midi_selection_token(s))
	strings.write_string(out, " midi_rev=")
	strings.write_uint(out, s.rev)
}

// A device name is whatever the driver says. A line break in it becomes a space
// because every value here is carried as exactly one line.
@(private = "file")
control_write_line :: proc(out: ^strings.Builder, text: string) {
	for i in 0 ..< len(text) {
		b := text[i]
		strings.write_byte(out, b == '\n' || b == '\r' ? ' ' : b)
	}
}
