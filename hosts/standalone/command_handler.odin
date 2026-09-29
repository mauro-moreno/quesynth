package standalone

import "base:intrinsics"
import "core:strconv"
import "core:strings"
import "core:time"

import "../../src/control"
import "../../src/patch"
import "../../src/registry"

// What the control server may reach: a ring to push edits onto (the audio
// thread applies them), a snapshot to read current values from, and the atomic
// daemon state. It holds no engine pointer, so a command can never call the
// engine directly -- the realtime boundary is expressed in the type.
Control_Context :: struct {
	ring:     ^Param_Ring,
	snapshot: ^Snapshot,
	state:    ^Daemon_State,
	// Static runtime facts plus the audio thread's live voice count. May be nil
	// (a bare handler in a test); daemon.info reports only what it can then.
	metrics:  ^Daemon_Metrics,
	// Optional existing MIDI overflow counter; no extra audio-thread work.
	midi:     ^Midi_Queue,
	// The patch bank the daemon browses, loads from and saves to. Read and
	// written only on the control thread, so it needs no lock. nil in a bare
	// handler test, where the bank commands report they are unavailable.
	bank:     ^patch.Slots,
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
	case "daemon.info":
		control_info(cc, req, out)
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
	case "parameter.set_many":
		control_set_many(cc, req, out)
	case "state.snapshot":
		control_state_snapshot(cc, req, out)
	case "bank.list":
		control_bank_list(cc, req, out)
	case "patch.load":
		control_patch_load(cc, req, out)
	case "patch.load_file":
		control_patch_load_file(cc, req, out)
	case "patch.save":
		control_patch_save(cc, req, out)
	case "bank.write":
		control_bank_write(cc, req, out)
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
control_info :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	state := intrinsics.atomic_load_explicit(cc.state, .Acquire)
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " state=")
	strings.write_string(out, daemon_state_name(state))
	strings.write_string(out, " proto=")
	strings.write_int(out, control.PROTOCOL_VERSION)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	if cc.ring != nil {
		strings.write_string(out, " control_dropped=")
		strings.write_uint(out, uint(param_ring_dropped(cc.ring)))
	}
	if cc.midi != nil {
		strings.write_string(out, " midi_dropped=")
		strings.write_uint(out, uint(midi_queue_dropped(cc.midi)))
	}
	if cc.metrics != nil {
		m := cc.metrics
		voices := intrinsics.atomic_load_explicit(&m.active_voices, .Relaxed)
		uptime := int(time.duration_seconds(time.tick_since(m.start_tick)))
		strings.write_string(out, " sample_rate=")
		strings.write_int(out, m.sample_rate)
		strings.write_string(out, " buffer=")
		strings.write_int(out, m.buffer_size)
		strings.write_string(out, " voices=")
		strings.write_int(out, int(voices))
		strings.write_string(out, " max_voices=")
		strings.write_int(out, m.max_voices)
		strings.write_string(out, " uptime=")
		strings.write_int(out, uptime)
		// backend last: an endpoint name like "ALSA (default)" has spaces, so a
		// client reads the rest of the line as its value.
		strings.write_string(out, " backend=")
		strings.write_string(out, m.backend)
	}
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
	if param_ring_free_space(cc.ring) < 2 {
		intrinsics.atomic_add_explicit(&cc.ring.dropped, 1, .Relaxed)
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}
	param_ring_push(cc.ring, Param_Command{kind = .Set, index = i32(d.index), stored = i32(stored)})
	param_ring_push(cc.ring, Param_Command{kind = .Commit})
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

@(private = "file")
control_set_many :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	tokens := strings.fields(req.rest)
	defer delete(tokens)
	if len(tokens) == 0 || len(tokens) % 2 != 0 {
		control_write_err(out, req, .Invalid_Payload, "set_many needs id value pairs")
		return
	}
	count := len(tokens) / 2
	if count > TXN_STAGING_MAX {
		control_write_err(out, req, .Transaction_Failed, "too many parameters in one transaction")
		return
	}

	// Validate every member before enqueuing any, so the first bad member
	// rejects the whole transaction and a batch never lands half-applied.
	staged: [TXN_STAGING_MAX]Param_Command
	for i in 0 ..< count {
		value, vok := strconv.parse_int(tokens[i * 2 + 1])
		if !vok {
			control_write_err(out, req, .Invalid_Payload, "value is not an integer")
			return
		}
		d, found := registry.registry_describe(tokens[i * 2])
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
		staged[i] = Param_Command{kind = .Set, index = i32(d.index), stored = i32(stored)}
	}

	// Enqueue the whole batch and its commit, or nothing: checking free space
	// first keeps a partial transaction off the ring.
	if param_ring_free_space(cc.ring) < count + 1 {
		intrinsics.atomic_add_explicit(&cc.ring.dropped, 1, .Relaxed)
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}
	for i in 0 ..< count {
		param_ring_push(cc.ring, staged[i])
	}
	param_ring_push(cc.ring, Param_Command{kind = .Commit})

	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, count)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

@(private = "file")
control_state_snapshot :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	snap := snapshot_read(cc.snapshot)
	list := registry.registry_list()
	control_write_ok(out, req)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	if cc.metrics != nil {
		strings.write_string(out, " sample_rate=")
		strings.write_int(out, cc.metrics.sample_rate)
		strings.write_string(out, " buffer=")
		strings.write_int(out, cc.metrics.buffer_size)
	}
	strings.write_string(out, " count=")
	strings.write_int(out, len(list))
	// One record line per registered parameter, in registry order.
	for d in list {
		strings.write_byte(out, '\n')
		strings.write_string(out, "id=")
		strings.write_string(out, d.id)
		strings.write_string(out, " value=")
		strings.write_int(out, int(snap.values[d.index]))
	}
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
