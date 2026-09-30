package standalone

import "core:strings"

import "../../src/control"
import "../../src/patch"

// Which patch the daemon is playing, as every front-end names it.
//
// The daemon owns this rather than each client. Two front-ends attached to one
// daemon -- the TUI and the browser -- used to keep their own idea of "the
// current patch", so a load in one left the other naming a sound it no longer
// played. Now a load, a save or a bank change records the outcome here, and
// every client reads the same answer with patch.current.
//
// Only the control thread touches it -- every command runs on the one poll
// thread -- so it needs no lock. It sits beside the bank rather than in the
// snapshot: where a sound came from is nothing the audio thread knows or needs.
// Fixed buffers, like patch.Slots, so nothing in it has to be freed.
Patch_Identity :: struct {
	// The bank slot the sound was loaded from or saved to, or -1: a file, an
	// archive patch, a cleared identity, or a slot of a bank since replaced.
	// The zero value reads as slot 0, so the daemon starts it at -1.
	slot:     int,
	bank:     [patch.SLOT_NAME_MAX]u8,
	bank_len: int,
	name:     [patch.SLOT_NAME_MAX]u8,
	name_len: int,
	// Bumped whenever the bank's contents or label change, so a client polling
	// patch.current learns it must re-read the bank without diffing 128 slots.
	bank_rev: uint,
}

// Record where the sound now comes from. A nil identity (a bare handler in a
// test) records nothing, so a command can call this unconditionally.
@(private)
identity_set :: proc(id: ^Patch_Identity, slot: int, bank, name: string) {
	if id == nil {return}
	id.slot = slot
	identity_put(&id.bank, &id.bank_len, bank)
	identity_put(&id.name, &id.name_len, name)
}

// Truncated like a slot name. A line break becomes a space because
// patch.current carries each value as exactly one record line.
@(private = "file")
identity_put :: proc(into: ^[patch.SLOT_NAME_MAX]u8, length: ^int, text: string) {
	n := min(len(text), patch.SLOT_NAME_MAX)
	for i in 0 ..< n {
		b := text[i]
		into[i] = b == '\n' || b == '\r' ? ' ' : b
	}
	length^ = n
}

// patch.current: the identity, the bank generation and the live revision in one
// reply, so a polling client learns from a single request whether it must
// re-read the values (revision), the bank (bank_rev) or only the names. bank
// and name are record lines of their own, always both and in that order, so
// each keeps its spaces and an empty one is still unambiguous.
@(private)
control_patch_current :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	id := cc.identity
	if id == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " slot=")
	strings.write_int(out, id.slot)
	strings.write_string(out, " bank_rev=")
	strings.write_uint(out, id.bank_rev)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	strings.write_string(out, "\nbank=")
	strings.write_string(out, string(id.bank[:id.bank_len]))
	strings.write_string(out, "\nname=")
	strings.write_string(out, string(id.name[:id.name_len]))
}

// patch.clear: forget where the sound came from, for a client that has just
// replaced it with values of its own. The values are untouched and the bank has
// not changed, so neither revision moves.
@(private)
control_patch_clear :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.identity == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank")
		return
	}
	identity_set(cc.identity, -1, "", "")
	control_write_ok(out, req)
}
