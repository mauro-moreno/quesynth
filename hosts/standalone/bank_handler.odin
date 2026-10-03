package standalone

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../src/control"
import "../../src/patch"

// The bank half of the control protocol: browse the patch bank, load a patch
// (from a slot or a file) as one atomic replacement, capture the live state
// into a slot, and write the bank to disk. Loading a patch is the transaction
// Slice 7 built -- a run of Set commands -- ended by a Commit_Patch rather than
// a Commit, so the audio thread replaces the whole preset at once, clears what
// the last one left ringing, bumps the revision once, and no block ever renders
// half a patch. Everything here runs on the control thread; the bank is touched
// by nothing else, so it needs no lock.

// bank.list: the bank's label, how many slots are filled, and one record line
// per slot -- all of them, filled or empty -- with its index, name and whether it
// holds a patch, so a client can browse every slot and save into an empty one.
@(private)
control_bank_list :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	count := 0
	for i in 0 ..< patch.FACTORY_SLOTS {
		if cc.bank.filled[i] {count += 1}
	}
	control_write_ok(out, req)
	strings.write_string(out, " label=")
	control_write_token(out, patch.slots_label(cc.bank))
	strings.write_string(out, " count=")
	strings.write_int(out, count)
	strings.write_string(out, " slots=")
	strings.write_int(out, patch.FACTORY_SLOTS)
	for i in 0 ..< patch.FACTORY_SLOTS {
		strings.write_byte(out, '\n')
		strings.write_string(out, "slot=")
		strings.write_int(out, i)
		strings.write_string(out, " filled=")
		strings.write_int(out, cc.bank.filled[i] ? 1 : 0)
		strings.write_string(out, " name=")
		control_write_token(out, patch.slots_name(cc.bank, i))
	}
}

// patch.load <slot> [init]: apply the slot's values as one transaction. With
// `init` an empty slot loads as the Init patch it is listed as, the defaults,
// rather than being refused: how a front-end starts a new sound in that slot.
@(private)
control_patch_load :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	if req.operand_count < 1 {
		control_write_err(out, req, .Invalid_Payload, "load needs a slot number")
		return
	}
	slot, sok := strconv.parse_int(req.operands[0])
	if !sok {
		control_write_err(out, req, .Invalid_Payload, "slot out of range")
		return
	}
	init := req.operand_count >= 2 && req.operands[1] == "init"
	applied, result := bank_load_slot(cc, slot, init)
	switch result {
	case .No_Bank:
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	case .Out_Of_Range:
		control_write_err(out, req, .Invalid_Payload, "slot out of range")
		return
	case .Empty:
		control_write_err(out, req, .Unknown_Parameter, "slot is empty")
		return
	case .Queue_Full:
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	case .Ok:
	}
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " slot=")
	strings.write_int(out, slot)
	strings.write_string(out, " name=")
	control_write_token(out, patch.slots_name(cc.bank, slot))
	strings.write_string(out, " count=")
	strings.write_int(out, applied)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

@(private)
Bank_Load_Result :: enum {
	Ok,
	No_Bank,
	Out_Of_Range,
	Empty,
	Queue_Full,
}

// Load a bank slot as one replacement and name it as the playing patch. Both
// patch.load and a native Program Change come here, so a slot cannot load one
// way from a client and another from a keyboard. An empty slot is refused
// unless `empty_as_init` asks for the Init patch, which writes nothing to the
// bank. Anything but Ok has queued nothing and left the identity alone.
@(private)
bank_load_slot :: proc(cc: ^Control_Context, slot: int, empty_as_init := false) -> (applied: int, result: Bank_Load_Result) {
	if cc.bank == nil {return 0, .No_Bank}
	if slot < 0 || slot >= patch.FACTORY_SLOTS {return 0, .Out_Of_Range}
	values, ok := patch.slots_patch(cc.bank, slot)
	if !ok && !empty_as_init {return 0, .Empty}
	if !ok {
		init := patch.init_patch()
		for i in 0 ..< patch.PARAMETER_COUNT {values[i] = i32(init.values[i])}
	}
	present: [patch.PARAMETER_COUNT]bool
	for i in 0 ..< patch.PARAMETER_COUNT {present[i] = true}

	n, full := control_apply_patch(cc, values, present)
	if full {return 0, .Queue_Full}
	identity_set(cc.identity, .Bank, slot, patch.slots_label(cc.bank), patch.slots_name(cc.bank, slot))
	return n, .Ok
}

// Whether the ring can take bank_load_slot's whole load: every parameter and
// the commit, which covers any archive patch too. A missing ring is nothing to
// wait for; the load refuses.
@(private)
bank_load_has_room :: proc(cc: ^Control_Context) -> bool {
	return cc.ring == nil || param_ring_free_space(cc.ring) >= patch.PARAMETER_COUNT + 1
}

// patch.load_file <path>: parse a .sy1 or .json patch and apply its parameters.
@(private)
control_patch_load_file :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "load_file needs a path")
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		control_write_err(out, req, .Invalid_Payload, "cannot read file")
		return
	}
	parsed, _, pok := patch.parse_patch_any(data, context.temp_allocator)
	if !pok {
		control_write_err(out, req, .Invalid_Payload, "cannot parse patch")
		return
	}
	values: [patch.PARAMETER_COUNT]i32
	for i in 0 ..< patch.PARAMETER_COUNT {values[i] = i32(parsed.values[i])}

	applied, full := control_apply_patch(cc, values, parsed.present)
	if full {
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}
	if applied == 0 {
		control_write_err(out, req, .Invalid_Payload, "patch set no parameters")
		return
	}
	// Named as the TUI always named a file-loaded patch: by the name inside the
	// file, or by the file itself when it carries none.
	shown := strings.trim_space(parsed.name)
	if shown == "" {shown = base_name(path)}
	identity_set(cc.identity, .File, -1, "file", shown)
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, applied)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	// The patch's own name from inside the file, on its own line so it keeps its
	// spaces, for a client to show instead of the file name.
	strings.write_byte(out, '\n')
	strings.write_string(out, "name=")
	strings.write_string(out, parsed.name)
}

// patch.save <slot> [name]: capture the live sound into a bank slot. That
// includes every edit queued before the save, from any client: a set is
// answered once it is queued, so a client that sets a value and saves at once
// would otherwise store the sound from before its own set. Until the snapshot
// shows those edits the save waits for the audio thread to apply them (see
// control_save_ready). It queues nothing itself, so it moves no revision and a
// full ring cannot refuse it.
@(private)
control_patch_save :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) -> (wait: Wait_Ticket) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	if req.operand_count < 1 {
		control_write_err(out, req, .Invalid_Payload, "save needs a slot number")
		return
	}
	slot, sok := strconv.parse_int(req.operands[0])
	if !sok || slot < 0 || slot >= patch.FACTORY_SLOTS {
		control_write_err(out, req, .Invalid_Payload, "slot out of range")
		return
	}
	name := control_rest_after_first(req.rest)
	save := Wait_Ticket{save = true, slot = slot, name_len = min(len(name), patch.SLOT_NAME_MAX)}
	copy(save.name[:], name)
	// No ring, no edit can be queued: a bare handler saves the snapshot.
	if cc.ring == nil {
		control_save_into_slot(cc, req, save, snapshot_read(cc.snapshot), out)
		return
	}
	save.position = intrinsics.atomic_load_explicit(&cc.ring.tail, .Relaxed)
	if !control_save_ready(cc, req, save, out) {wait = save}
	return
}

// Store a save once the snapshot shows every edit queued before it, and write
// its reply. False, writing nothing, while it does not yet; the server asks
// again on its next tick, until the save has waited too long.
@(private)
control_save_ready :: proc(cc: ^Control_Context, req: control.Request, save: Wait_Ticket, out: ^strings.Builder) -> bool {
	snap, ready := param_ring_published(cc.ring, cc.snapshot, save.position)
	if !ready {return false}
	control_save_into_slot(cc, req, save, snap, out)
	return true
}

// What a slot held before a save, to put back when the bank cannot be kept.
@(private = "file")
Slot_Was :: struct {
	values:   [patch.PARAMETER_COUNT]i32,
	name:     [patch.SLOT_NAME_MAX]u8,
	name_len: int,
	filled:   bool,
}

// Store the save, keep the bank, and only then say so: the slot is staged in
// the bank, the whole bank is written where the next start reads it, and if
// that fails the slot goes back as it was and nothing else has moved -- not
// the identity, not bank_rev, not the sound. Archive.open does the same with
// its path (archive_replace). So a save is never answered ok for a bank the
// next start cannot find, and a refused one leaves nothing half done.
@(private = "file")
control_save_into_slot :: proc(cc: ^Control_Context, req: control.Request, save: Wait_Ticket, snap: Snapshot_Data, out: ^strings.Builder) {
	save := save
	slot := save.slot
	was := Slot_Was{cc.bank.values[slot], cc.bank.names[slot], cc.bank.name_len[slot], cc.bank.filled[slot]}
	for i in 0 ..< patch.PARAMETER_COUNT {
		cc.bank.values[slot][i] = snap.values[i]
	}
	cc.bank.filled[slot] = true
	name := string(save.name[:save.name_len])
	final := name != "" ? name : patch.slots_name(cc.bank, slot)
	put_slot_name(cc.bank, slot, final)
	if !bank_keep_write(cc) {
		cc.bank.values[slot] = was.values
		cc.bank.names[slot] = was.name
		cc.bank.name_len[slot] = was.name_len
		cc.bank.filled[slot] = was.filled
		control_write_err(out, req, .Internal_Error, "cannot keep bank")
		return
	}
	identity_set(cc.identity, .Bank, slot, patch.slots_label(cc.bank), patch.slots_name(cc.bank, slot))
	if cc.identity != nil {cc.identity.bank_rev += 1}

	control_write_ok(out, req)
	strings.write_string(out, " slot=")
	strings.write_int(out, slot)
	strings.write_string(out, " name=")
	control_write_token(out, patch.slots_name(cc.bank, slot))
	control_write_bank_rev(cc, out)
}

// Write the bank where the next start loads it from, the file bank.keep
// writes: the daemon's own copy of what was saved, so no client has to ask for
// that. False when it cannot be written; true when there is nowhere to keep it
// (no bank_keep, as in a bare handler or with no config directory), which keeps
// nothing, as a save always did. This also runs from the server's tick, for a
// save that waited, which is outside the request guard that gives each
// request's temporary memory back, so it gives back its own.
@(private = "file")
bank_keep_write :: proc(cc: ^Control_Context) -> bool {
	if cc.bank_keep == "" {return true}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	json := patch.slots_write_json(cc.bank, context.temp_allocator)
	return write_file_atomic(cc.bank_keep, json)
}

// bank.write <path>: serialize the whole bank to a JSON file.
@(private)
control_bank_write :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "write needs a path")
		return
	}
	json := patch.slots_write_json(cc.bank, context.temp_allocator)
	if os.write_entire_file_from_string(path, json) != nil {
		control_write_err(out, req, .Internal_Error, "cannot write file")
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " bytes=")
	strings.write_int(out, len(json))
}

// bank.keep: write the bank to the config path the daemon loads at startup, so
// what a front-end keeps survives a restart without any client having to know
// where that is. Written beside it and renamed over it, synced first, so a
// crash or a power cut leaves the previous bank whole rather than half of this.
@(private)
control_bank_keep :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	path, ok := config_bank_path(context.temp_allocator)
	if !ok {
		control_write_err(out, req, .Internal_Error, "no config directory")
		return
	}
	json := patch.slots_write_json(cc.bank, context.temp_allocator)
	if !write_file_atomic(path, json) {
		control_write_err(out, req, .Internal_Error, "cannot write file")
		return
	}
	// A relative XDG_CONFIG_HOME resolves against the daemon's working
	// directory, which a client need not share: report where the file went.
	if !os.is_absolute_path(path) {
		if abs, aerr := os.get_absolute_path(path, context.temp_allocator); aerr == nil {path = abs}
	}
	control_write_ok(out, req)
	strings.write_string(out, " bytes=")
	strings.write_int(out, len(json))
	// path last: it may contain spaces, so a client reads it to the line end.
	strings.write_string(out, " path=")
	strings.write_string(out, path)
}

// Also how the daemon keeps the archive path it reopens at startup.
@(private)
write_file_atomic :: proc(path, data: string) -> bool {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if err != nil {return false}
	_, werr := os.write_string(f, data)
	serr := os.sync(f)
	cerr := os.close(f)
	if werr != nil || serr != nil || cerr != nil || os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

// bank.load_file <path>: replace the browsable bank with a JSON bank from disk.
// It only changes what is browsable; the live sound is unchanged until a patch
// is loaded from the new bank.
@(private)
control_bank_load_file :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.bank == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "load needs a path")
		return
	}
	if !load_bank_file(cc.bank, path) {
		control_write_err(out, req, .Invalid_Payload, "cannot read or parse bank")
		return
	}
	count := 0
	for i in 0 ..< patch.FACTORY_SLOTS {
		if cc.bank.filled[i] {count += 1}
	}
	// The sound keeps its provenance -- it still came from that bank and patch --
	// but its slot number would now index a different bank, so it names none.
	if cc.identity != nil {
		cc.identity.slot = -1
		cc.identity.bank_rev += 1
	}
	control_write_ok(out, req)
	strings.write_string(out, " label=")
	control_write_token(out, patch.slots_label(cc.bank))
	strings.write_string(out, " count=")
	strings.write_int(out, count)
	control_write_bank_rev(cc, out)
}

// The bank generation after a command that changed the bank, last on the line.
// Absent without an identity to count it (a bare handler in a test).
@(private = "file")
control_write_bank_rev :: proc(cc: ^Control_Context, out: ^strings.Builder) {
	if cc.identity == nil {return}
	strings.write_string(out, " bank_rev=")
	strings.write_uint(out, cc.identity.bank_rev)
}

// Stage the present parameters of a patch and commit them as one replacement,
// all-or-nothing: nothing reaches the ring unless the whole batch and its
// commit fit. Values are pushed by patch index -- the same path startup loading
// takes -- so a preset applies faithfully and atomically. Commit_Patch rather
// than Commit, because a slot, a file and an archive entry are whole patches:
// the audio thread must replace the sound, not edit the one that is playing.
// Returns the number applied, and whether the ring was too full for the batch.
@(private)
control_apply_patch :: proc(
	cc: ^Control_Context,
	values: [patch.PARAMETER_COUNT]i32,
	present: [patch.PARAMETER_COUNT]bool,
) -> (
	applied: int,
	queue_full: bool,
) {
	staged: [patch.PARAMETER_COUNT]Param_Command
	n := 0
	for i in 0 ..< patch.PARAMETER_COUNT {
		if !present[i] {continue}
		staged[n] = Param_Command{kind = .Set, index = i32(i), stored = values[i]}
		n += 1
	}
	if n == 0 {return 0, false}
	if cc.ring == nil {return 0, true}
	if !control_enqueue(cc.ring, staged[:n], .Commit_Patch) {return 0, true}
	return n, false
}

// A response value with no spaces (a name, a label) written as a single token,
// spaces folded to underscores so it stays one field on the response line.
@(private)
control_write_token :: proc(out: ^strings.Builder, s: string) {
	for r in s {
		b: u8 = '?'
		if r == ' ' {
			b = '_'
		} else if r < 128 {
			b = u8(r)
		}
		strings.write_byte(out, b)
	}
}

// The text after the first whitespace-delimited token of `rest` (the slot),
// trimmed: the optional name argument of patch.save.
@(private = "file")
control_rest_after_first :: proc(rest: string) -> string {
	trimmed := strings.trim_space(rest)
	if sp := strings.index_byte(trimmed, ' '); sp >= 0 {
		return strings.trim_space(trimmed[sp + 1:])
	}
	return ""
}

@(private = "file")
put_slot_name :: proc(s: ^patch.Slots, slot: int, name: string) {
	n := min(len(name), patch.SLOT_NAME_MAX)
	for i in 0 ..< n {
		s.names[slot][i] = name[i]
	}
	s.name_len[slot] = n
}
