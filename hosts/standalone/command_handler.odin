package standalone

import "base:intrinsics"
import "core:strconv"
import "core:strings"

import "../../src/control"
import "../../src/registry"

// What the control server may reach: a ring to push edits onto (the audio
// thread applies them), a snapshot to read current values from, and the atomic
// daemon state. It holds no engine pointer, so a command can never call the
// engine directly -- the realtime boundary is expressed in the type.
Control_Context :: struct {
	ring:     ^Param_Ring,
	snapshot: ^Snapshot,
	state:    ^Daemon_State,
}

// Handle one request, writing the response payload (unframed) into `out`. This
// is the whole of the control thread's authority: a set validates then pushes
// onto the ring; a get, list or status reads the snapshot and the atomic state.
// It never touches the engine.
control_handle :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if req.version != control.PROTOCOL_VERSION {
		control_write_err(out, req, .Unsupported_Version, "unsupported protocol version")
		return
	}

	switch req.command {
	case "daemon.status":
		control_status(cc, req, out)
	case "daemon.shutdown":
		// The one command that is a lifecycle action rather than a query. It
		// raises the same flag Ctrl-C does; the main thread tears the daemon
		// down. Kept here so `quesynth --stop` is just another client.
		request_shutdown()
		control_write_ok(out, req)
	case "parameter.list":
		control_list(cc, req, out)
	case "parameter.get":
		control_get(cc, req, out)
	case "parameter.set":
		control_set(cc, req, out)
	case:
		control_write_err(out, req, .Unknown_Command, "unknown command")
	}
}

@(private = "file")
control_status :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	state := intrinsics.atomic_load_explicit(cc.state, .Acquire)
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " state=")
	strings.write_string(out, daemon_state_name(state))
	strings.write_string(out, " proto=")
	strings.write_int(out, control.PROTOCOL_VERSION)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

@(private = "file")
control_list :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	list := registry.registry_list()
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, len(list))
	for d in list {
		lo, hi, _ := registry.registry_stored_range(d)
		strings.write_byte(out, '\n')
		strings.write_string(out, "id=")
		strings.write_string(out, d.id)
		strings.write_string(out, " group=")
		strings.write_string(out, d.group)
		strings.write_string(out, " index=")
		strings.write_int(out, d.index)
		strings.write_string(out, " min=")
		strings.write_int(out, lo)
		strings.write_string(out, " max=")
		strings.write_int(out, hi)
		strings.write_string(out, " default=")
		strings.write_int(out, registry.registry_default(d))
		// label last, so a future multi-word label needs no quoting.
		strings.write_string(out, " label=")
		strings.write_string(out, d.label)
	}
}

@(private = "file")
control_get :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if req.operand_count < 1 {
		control_write_err(out, req, .Invalid_Payload, "get needs a parameter id")
		return
	}
	d, found := registry.registry_describe(req.operands[0])
	if !found {
		control_write_err(out, req, .Unknown_Parameter, "no such parameter")
		return
	}
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " value=")
	strings.write_int(out, int(snap.values[d.index]))
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

@(private = "file")
control_set :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if req.operand_count < 2 {
		control_write_err(out, req, .Invalid_Payload, "set needs an id and a value")
		return
	}
	value, vok := strconv.parse_int(req.operands[1])
	if !vok {
		control_write_err(out, req, .Invalid_Payload, "value is not an integer")
		return
	}
	d, found := registry.registry_describe(req.operands[0])
	if !found {
		control_write_err(out, req, .Unknown_Parameter, "no such parameter")
		return
	}
	stored, verr := registry.registry_validate(d, value)
	if verr == .Out_Of_Range {
		control_write_err(out, req, .Out_Of_Range, "value out of range")
		return
	}
	if verr != .None {
		control_write_err(out, req, .Unknown_Parameter, "no such parameter")
		return
	}
	if !param_ring_push(cc.ring, Param_Command{index = i32(d.index), stored = i32(stored)}) {
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}
	// The revision is the accepted marker: the audio thread bumps it when it
	// applies the command. A get after this reflects the new value once the
	// audio thread has drained the ring.
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " value=")
	strings.write_int(out, stored)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

// Envelope writers. Every response begins `<version> <id> <status>`.
control_write_ok :: proc(out: ^strings.Builder, req: control.Request) {
	control_write_envelope(out, req, "ok")
}

control_write_err :: proc(
	out: ^strings.Builder,
	req: control.Request,
	code: control.Error_Code,
	message: string,
) {
	control_write_envelope(out, req, "err")
	strings.write_byte(out, ' ')
	strings.write_string(out, control.error_code_name(code))
	if len(message) > 0 {
		strings.write_byte(out, ' ')
		strings.write_string(out, message)
	}
}

@(private = "file")
control_write_envelope :: proc(out: ^strings.Builder, req: control.Request, status: string) {
	strings.builder_reset(out)
	strings.write_int(out, control.PROTOCOL_VERSION)
	strings.write_byte(out, ' ')
	strings.write_int(out, req.id)
	strings.write_byte(out, ' ')
	strings.write_string(out, status)
}
