package standalone

import "base:intrinsics"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../src/control"
import "../../src/patch"

// The bank half of the control protocol: browse the patch bank, load a patch
// (from a slot or a file) as one atomic transaction, capture the live state into
// a slot, and write the bank to disk. Loading a patch is exactly the transaction
// Slice 7 built -- a run of Set commands ended by a Commit -- so the audio thread
// applies a whole preset at once and bumps the revision once, and no block ever
// renders half a patch. Everything here runs on the control thread; the bank is
// touched by nothing else, so it needs no lock.

// bank.list: the bank's label, how many slots are filled, and one record line
// per filled slot with its index and name.
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
	for i in 0 ..< patch.FACTORY_SLOTS {
		if !cc.bank.filled[i] {continue}
		strings.write_byte(out, '\n')
		strings.write_string(out, "slot=")
		strings.write_int(out, i)
		strings.write_string(out, " name=")
		control_write_token(out, patch.slots_name(cc.bank, i))
	}
}

// patch.load <slot>: apply the slot's values as one transaction.
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
	if !sok || slot < 0 || slot >= patch.FACTORY_SLOTS {
		control_write_err(out, req, .Invalid_Payload, "slot out of range")
		return
	}
	values, ok := patch.slots_patch(cc.bank, slot)
	if !ok {
		control_write_err(out, req, .Unknown_Parameter, "slot is empty")
		return
	}
	present: [patch.PARAMETER_COUNT]bool
	for i in 0 ..< patch.PARAMETER_COUNT {present[i] = true}

	applied, full := control_apply_patch(cc, values, present)
	if full {
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
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
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, applied)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

// patch.save <slot> [name]: capture the live snapshot into a bank slot.
@(private)
control_patch_save :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
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

	snap := snapshot_read(cc.snapshot)
	for i in 0 ..< patch.PARAMETER_COUNT {
		cc.bank.values[slot][i] = snap.values[i]
	}
	cc.bank.filled[slot] = true
	final := name != "" ? name : patch.slots_name(cc.bank, slot)
	put_slot_name(cc.bank, slot, final)

	control_write_ok(out, req)
	strings.write_string(out, " slot=")
	strings.write_int(out, slot)
	strings.write_string(out, " name=")
	control_write_token(out, patch.slots_name(cc.bank, slot))
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
	control_write_ok(out, req)
	strings.write_string(out, " label=")
	control_write_token(out, patch.slots_label(cc.bank))
	strings.write_string(out, " count=")
	strings.write_int(out, count)
}

// Stage the present parameters of a patch and commit them as one transaction,
// all-or-nothing: nothing reaches the ring unless the whole batch and its commit
// fit. Values are pushed by patch index -- the same path startup loading takes --
// so a preset applies faithfully and atomically. Returns the number applied, and
// whether the ring was too full to take the batch.
@(private = "file")
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
	if param_ring_free_space(cc.ring) < n + 1 {
		intrinsics.atomic_add_explicit(&cc.ring.dropped, 1, .Relaxed)
		return 0, true
	}
	for i in 0 ..< n {
		param_ring_push(cc.ring, staged[i])
	}
	param_ring_push(cc.ring, Param_Command{kind = .Commit})
	return n, false
}

// A response value with no spaces (a name, a label) written as a single token,
// spaces folded to underscores so it stays one field on the response line.
@(private = "file")
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
