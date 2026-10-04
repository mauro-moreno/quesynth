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
	// Where the bank is written after each patch.save, and by bank.keep, so a
	// saved patch is still there after a restart without any client having to
	// ask for that: the --bank file the daemon started with, or else bank.json
	// (daemon_start_bank). Only run_daemon sets it, as it does the archive's
	// keep_path: "" keeps nothing, which is what every test driving a handler
	// or a server gets unless it names a file, so none of them writes the
	// user's config directory. Owned by whoever set it.
	bank_keep: string,
	// bank_keep is a --bank file this daemon neither loaded nor has written
	// yet, so it may be somebody else's: it is replaced only while it is
	// absent or empty. The first write clears it.
	bank_keep_guarded: bool,
	// The browsable bank is not the one kept in bank_keep: bank.load_file
	// replaced it with another file's. A save then puts its one slot into the
	// kept bank as it is on disk, rather than writing this bank over it, so
	// browsing another bank never costs the kept one its other slots.
	// bank.keep adopts this bank as the kept one and clears it, and a load
	// over the untouched factory bank never sets it.
	bank_detached: bool,
	// A patch archive opened for browsing, indexed lazily. nil when unsupported.
	archive:  ^Archive,
	// Which patch the sound came from, beside the bank that names it and, like
	// the bank, control-thread only. nil in a bare handler test, where the
	// commands that read it report they are unavailable and the ones that
	// update it skip the update.
	identity: ^Patch_Identity,
	// The master volume the audio thread reads each block. The pointer is to the
	// one atomic and nothing else, so storing it is all this thread can do to
	// the audio side. nil in a bare handler test: no audio to turn down.
	volume:   ^Master_Volume,
	// Which native MIDI inputs are open, shared by every front-end and, like
	// the identity, control-thread only. nil where there is no MIDI backend (a
	// bare handler test, a platform without one): midi.list, midi.select and
	// midi.current then report that there is no MIDI input.
	midi_select: ^Midi_Selection,
	// The running Bank Select of every MIDI channel, and the queue the audio
	// thread forwards Bank Select and Program Change into. Drained on this
	// thread, like the bank it loads from. nil in a bare handler test, where a
	// Program Change loads nothing.
	program:  ^Program_Select,
}

// What a request that cannot be answered yet leaves with its caller. Only the
// audio thread can say whether a guarded set_many applies, so after the batch is
// queued the reply waits for the audio thread's result. A patch.save waits too,
// while edits queued ahead of it are not yet in the snapshot: it must store
// them, not the sound from before them. The control thread never blocks for
// either: the ticket names what to look for, and the caller answers when that
// comes, or says it did not come in time.
Wait_Ticket :: struct {
	serial: u64, // the serial of the queued Commit_Checked; 0 when nothing is pending
	count:  int, // the pairs in the batch, which the ok reply states
	// A waiting patch.save: the ring tail when it arrived, which the snapshot
	// must show everything before, and its slot and name. The name is held
	// here, cut to what a slot keeps, because the request it came in is freed
	// once it has been handled.
	save:     bool,
	position: u32,
	slot:     int,
	name:     [patch.SLOT_NAME_MAX]u8,
	name_len: int,
}

// Whether the ticket is a request still owed an answer.
@(private)
control_wait_owed :: proc(wait: Wait_Ticket) -> bool {
	return wait.serial != 0 || wait.save
}

// Handle one request, writing the response payload (unframed) into `out`. This
// is the whole of the control thread's authority: a set validates then pushes
// onto the ring; a get, list or status reads the snapshot and the atomic state.
// It never touches the engine, and it never waits.
//
// Every request is answered in `out` before this returns, except a guarded
// parameter.set_many that was validated and queued, and a patch.save that has
// to wait for the edits ahead of it: those write nothing and return the ticket
// for their answer (see control_write_checked_reply and control_save_ready).
control_handle :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) -> (wait: Wait_Ticket) {
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
		return control_set_many(cc, req, out)
	case "midi":
		control_midi(cc, req, out)
	case "midi.list":
		control_midi_list(cc, req, out)
	case "midi.select":
		control_midi_select(cc, req, out)
	case "midi.current":
		control_midi_current(cc, req, out)
	case "state.snapshot":
		control_state_snapshot(cc, req, out)
	case "bank.list":
		control_bank_list(cc, req, out)
	case "patch.load":
		control_patch_load(cc, req, out)
	case "patch.apply":
		control_patch_apply(cc, req, out)
	case "patch.load_file":
		control_patch_load_file(cc, req, out)
	case "patch.save":
		return control_patch_save(cc, req, out)
	case "bank.write":
		control_bank_write(cc, req, out)
	case "bank.load_file":
		control_bank_load_file(cc, req, out)
	case "bank.keep":
		control_bank_keep(cc, req, out)
	case "patch.current":
		control_patch_current(cc, req, out)
	case "patch.clear":
		control_patch_clear(cc, req, out)
	case "volume":
		control_volume(cc, req, out)
	case "archive.open":
		control_archive_open(cc, req, out)
	case "archive.adopt":
		control_archive_adopt(cc, req, out)
	case "archive.current":
		control_archive_current(cc, req, out)
	case "archive.banks":
		control_archive_banks(cc, req, out)
	case "archive.bank":
		control_archive_bank(cc, req, out)
	case "archive.patches":
		control_archive_patches(cc, req, out)
	case "archive.load":
		control_archive_load(cc, req, out)
	case "archive.close":
		control_archive_close(cc, req, out)
	case:
		control_write_err(out, req, .Unknown_Command, "unknown command")
	}
	return
}


// Inject one packed MIDI message from a local front-end such as the browser.
// It enters the same queue as ALSA/WinMM, so the audio thread remains the only
// caller of the engine.
@(private = "file")
control_midi :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.midi == nil || req.operand_count < 3 {
		control_write_err(out, req, .Invalid_Payload, "midi needs status data1 data2")
		return
	}
	status, sok := strconv.parse_int(req.operands[0])
	data1, aok := strconv.parse_int(req.operands[1])
	data2, bok := strconv.parse_int(req.operands[2])
	if !sok || !aok || !bok || status < 0 || status > 255 || data1 < 0 || data1 > 127 || data2 < 0 || data2 > 127 {
		control_write_err(out, req, .Invalid_Payload, "invalid midi bytes")
		return
	}
	if !midi_queue_push(cc.midi, midi_pack(u8(status), u8(data1), u8(data2))) {
		control_write_err(out, req, .Daemon_Not_Ready, "midi queue full")
		return
	}
	control_write_ok(out, req)
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
	}
	if cc.volume != nil {
		strings.write_string(out, " volume=")
		strings.write_uint(out, uint(intrinsics.atomic_load_explicit(&cc.volume.milli, .Relaxed)))
	}
	if cc.metrics != nil {
		// backend last: an endpoint name like "ALSA (default)" has spaces, so a
		// client reads the rest of the line as its value.
		strings.write_string(out, " backend=")
		strings.write_string(out, cc.metrics.backend)
	}
}

// volume <milli>: the listener's level, not part of the sound. So it is no
// patch parameter: it bypasses the ring, is absent from state.snapshot and moves
// no revision. Storing the atomic is the whole of the control side; the audio
// thread ramps to it over its next block.
@(private = "file")
control_volume :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.volume == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no audio")
		return
	}
	milli, ok := 0, false
	if req.operand_count >= 1 {
		milli, ok = strconv.parse_int(req.operands[0])
	}
	if !ok || milli < 0 || milli > VOLUME_UNITY {
		control_write_err(out, req, .Invalid_Payload, "volume needs 0..1000")
		return
	}
	intrinsics.atomic_store_explicit(&cc.volume.milli, u32(milli), .Relaxed)
	control_write_ok(out, req)
	strings.write_string(out, " volume=")
	strings.write_int(out, milli)
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
	value, vok := parse_parameter_value(req.operands[1])
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
control_set_many :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) -> Wait_Ticket {
	return control_pairs_transaction(cc, req, out, .Commit, "set_many needs id value pairs")
}

// patch.apply: a whole patch sent by value, which is how a front-end that holds
// one loads it -- the browser page opening a patch file of its own. The grammar
// and the validation are set_many's; only the commit differs, so the audio
// thread replaces the patch rather than editing it. Which patch it is stays for
// the client to say: patch.load names a slot, this names nothing.
@(private = "file")
control_patch_apply :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	control_pairs_transaction(cc, req, out, .Commit_Patch, "apply needs id value pairs")
}

// A parameter value is decimal digits with leading zeroes and an optional single
// minus sign: no plus, base prefix or separator. Check before multiplying,
// including the extra unit of magnitude min(int) has, rather than letting
// strconv.parse_int accept those spellings and wrap past the largest int.
@(private = "file")
parse_parameter_value :: proc(raw: string) -> (int, bool) {
	text := raw
	negative := len(text) > 0 && text[0] == '-'
	if negative { text = text[1:] }
	if text == "" { return 0, false }
	limit := uint(max(int))
	if negative { limit += 1 }
	value: uint
	for c in transmute([]u8)text {
		if c < '0' || c > '9' { return 0, false }
		digit := uint(c - '0')
		if value > (limit - digit) / 10 { return 0, false }
		value = value * 10 + digit
	}
	if negative {
		if value == uint(max(int)) + 1 { return min(int), true }
		return -int(value), true
	}
	return int(value), true
}

// The revision a guard names. strconv.parse_int takes a sign, a base prefix and
// underscores and wraps past the largest int, so a token it accepted could name
// a revision other than the one written, and the guard would pass for it.
@(private = "file")
parse_revision :: proc(text: string) -> (revision: int, ok: bool) {
	if text == "" { return 0, false }
	for c in transmute([]u8)text {
		digit := int(c) - '0'
		if digit < 0 || digit > 9 || revision > (max(int) - digit) / 10 { return 0, false }
		revision = revision * 10 + digit
	}
	return revision, true
}

// `id value` pairs, validated as a whole and enqueued as one transaction ended
// by `commit`. Duplicates are staged as given, in order, so the later one wins.
@(private = "file")
control_pairs_transaction :: proc(
	cc: ^Control_Context,
	req: control.Request,
	out: ^strings.Builder,
	commit: Param_Command_Kind,
	needs_pairs: string,
) -> (wait: Wait_Ticket) {
	all_tokens := strings.fields(req.rest)
	defer delete(all_tokens)
	tokens := all_tokens
	expected := -1
	if commit == .Commit && len(tokens) > 0 && strings.has_prefix(tokens[0], "expected_revision=") {
		ok: bool
		expected, ok = parse_revision(tokens[0][len("expected_revision="):])
		if !ok {
			control_write_err(out, req, .Invalid_Payload, "expected_revision needs a nonnegative integer")
			return
		}
		tokens = tokens[1:]
	}
	if len(tokens) == 0 || len(tokens) % 2 != 0 {
		control_write_err(out, req, .Invalid_Payload, needs_pairs)
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
		value, vok := parse_parameter_value(tokens[i * 2 + 1])
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

	if expected >= 0 {
		return control_checked_transaction(cc, req, out, staged[:count], expected)
	}

	if !control_enqueue(cc.ring, staged[:count], commit) {
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}

	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, count)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	return
}

// A set_many whose sender names the revision it saw. The batch goes on the ring
// ended by Commit_Checked, and the audio thread -- the only one that knows the
// revision in ring order, after every edit queued ahead of this one -- applies
// it or discards it, publishes the state, and only then posts its result. Once
// the batch is queued nothing is written to `out`: the ticket stands for the
// reply, which the caller writes when the result arrives, so a success is never
// reported for a batch that was refused and a refusal carries the revision that
// beat it. Any refusal made before the batch is queued is answered here.
@(private = "file")
control_checked_transaction :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder, sets: []Param_Command, expected: int) -> Wait_Ticket {
	ring := cc.ring
	if ring == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no audio")
		return {}
	}
	if param_ring_free_space(ring) < len(sets) + 1 {
		intrinsics.atomic_add_explicit(&ring.dropped, 1, .Relaxed)
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return {}
	}
	ring.checked_serial += 1
	serial := ring.checked_serial
	for cmd in sets { param_ring_push(ring, cmd) }
	param_ring_push(ring, Param_Command{kind = .Commit_Checked, expected_revision = expected, serial = serial})
	return Wait_Ticket{serial = serial, count = len(sets)}
}

// The reply to a guarded set_many once the audio thread has answered it. `req`
// needs only the version and id of the request the ticket came from, which is
// all a reply carries of it.
control_write_checked_reply :: proc(out: ^strings.Builder, req: control.Request, ticket: Wait_Ticket, result: Checked_Result) {
	if !result.applied {
		control_write_err(out, req, .Revision_Conflict, "current_revision=")
		strings.write_int(out, result.revision)
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, ticket.count)
	strings.write_string(out, " revision=")
	strings.write_int(out, result.revision)
}

// The reply to a guarded set_many whose result did not come in time. The batch
// stays queued and may still apply, so this says nothing about whether it did.
control_write_checked_unknown :: proc(out: ^strings.Builder, req: control.Request) {
	control_write_err(out, req, .Daemon_Not_Ready, "commit outcome unknown; inspect state before retrying")
}

// The reply to a waiting patch.save whose edits did not reach the snapshot in
// time, or that still waited when the server stopped. Unlike a guarded batch's
// outcome this one is known: nothing was stored, and the save can be sent
// again.
@(private)
control_write_save_refused :: proc(out: ^strings.Builder, req: control.Request) {
	control_write_err(out, req, .Daemon_Not_Ready, "earlier edits not applied; nothing saved")
}

// Enqueue a whole transaction -- its Sets, then the commit that says what kind
// of transaction it is -- or nothing: checking free space first keeps a partial
// transaction off the ring, and a refusal is counted once, not once per Set.
@(private)
control_enqueue :: proc(ring: ^Param_Ring, sets: []Param_Command, commit: Param_Command_Kind) -> bool {
	if param_ring_free_space(ring) < len(sets) + 1 {
		intrinsics.atomic_add_explicit(&ring.dropped, 1, .Relaxed)
		return false
	}
	for cmd in sets {
		param_ring_push(ring, cmd)
	}
	param_ring_push(ring, Param_Command{kind = commit})
	return true
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
