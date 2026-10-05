package standalone

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

import "../../src/control"
import "../../src/patch"
import "../../src/zip"

// Browsing a large patch archive without unpacking it. The corpus is an outer zip
// of many inner bank zips, each holding many .sy1 patches -- tens of thousands in
// all. Expanding that into memory would be absurd, so nothing here does: the
// archive keeps only the outer central directory (a light index) and reads on
// demand, holding at most one inner bank (tens of kilobytes) and one inflated
// patch at a time -- and, for as long as one load takes, the bank a Program
// Change reads beside it. Entries are pulled straight from the file with
// read_at, so the archive file itself is never resident either.
//
// The structure is two levels -- banks, then patches -- and the protocol mirrors
// it: open an archive, page through its banks, open one bank, page through its
// patches, load a patch. Loading applies the patch as the same atomic transaction
// a slot load uses.
//
// The archive, its open bank and the path to reopen are the daemon's, shared by
// every front-end, like the bank and the identity. A client that kept its own
// copy would be browsing something a peer has since closed or moved; archive_rev
// tells it when to look again, through the patch.current it already polls.

Archive :: struct {
	file:          ^os.File,
	// The outer central directory, kept because entry names alias into it.
	cd:            []u8,
	entries:       []zip.Entry,
	// Outer entries that are inner bank zips, in order: the browsable banks.
	bank_indices:  []int,
	open:          bool,
	// The one inner bank currently open, if any.
	bank_bytes:    []u8,
	bank:          zip.Zip,
	bank_open:     bool,
	// The open bank's position in bank_indices, read only while bank_open.
	bank_at:       int,
	// Indices within the open bank of its .sy1 patches, excluding directory and
	// other entries: the browsable, loadable patches.
	patch_indices: []int,
	// The open bank's display name, for naming a patch loaded from it. It aliases
	// the central directory like every entry name, and the directory outlives any
	// open bank, so there is nothing of its own to free.
	bank_name:     string,
	// The archive to reopen, as it was given. Kept when it fails to reopen at
	// startup: the zip may be on a disk that is not mounted yet, and forgetting
	// it then would make the user find it again. Owned.
	path:          string,
	// Where path is kept for the next start, or "" to keep nothing. Only
	// run_daemon sets it, so a test driving the handlers never writes the
	// user's config directory. Owned.
	keep_path:     string,
	// Moves once per change to the open archive or its open bank, whichever
	// client made it, so a peer knows to re-read archive.current.
	rev:           uint,
}

// Read an archive's central directory and note which entries are inner bank
// zips, without touching the archive already open. The file stays open for
// on-demand reads until the result is swapped in or released.
@(private = "file")
archive_index :: proc(path: string) -> (fresh: Archive, ok: bool) {
	// Before open: opening a FIFO waits for a writer that may never come, and
	// the daemon would wait with it.
	if !path_is_regular_file(path) {
		return
	}
	f, err := os.open(path)
	if err != nil {
		return
	}
	size, serr := os.file_size(f)
	if serr != nil || size < 22 {
		os.close(f)
		return
	}
	tail_len := min(size, 65557) // 22-byte record + 65535-byte max comment
	tail := make([]u8, tail_len, context.temp_allocator)
	tn, terr := os.read_at(f, tail, size - tail_len)
	if terr != nil {
		os.close(f)
		return
	}
	cd_offset, cd_size, count, found := zip.find_eocd(tail[:tn])
	if !found {
		os.close(f)
		return
	}
	// The directory is read into memory whole, so it must lie inside the file
	// before anything is allocated for it: cd_size is a u32 from the file.
	if i64(cd_offset) + i64(cd_size) > size {
		os.close(f)
		return
	}
	cd := make([]u8, cd_size)
	cn, cerr := os.read_at(f, cd, i64(cd_offset))
	if cerr != nil || cn != int(cd_size) {
		delete(cd)
		os.close(f)
		return
	}
	entries, parsed := zip.parse_central(cd, 0, cd_size, count)
	if !parsed {
		delete(cd)
		os.close(f)
		return
	}
	banks: [dynamic]int
	for e, i in entries {
		if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".zip") {
			append(&banks, i)
		}
	}
	fresh = {
		file         = f,
		cd           = cd,
		entries      = entries,
		bank_indices = banks[:],
		open         = true,
	}
	return fresh, true
}

// Make an indexed archive the open one, remembering path. The archive already
// open is let go only here, once the new one has indexed: a path that does not
// open must not take away the archive another client is in the middle of
// browsing.
@(private = "file")
archive_swap :: proc(a: ^Archive, path: string, fresh: Archive) {
	// Cloned before the old path goes: reopening the remembered archive passes
	// a.path itself.
	remembered := strings.clone(path)
	archive_release(a)
	delete(a.path)
	a.path = remembered
	a.file = fresh.file
	a.cd = fresh.cd
	a.entries = fresh.entries
	a.bank_indices = fresh.bank_indices
	a.open = true
}

// Open and index an archive and make it the open one, without keeping its
// path anywhere: how a start reopens the archive the last run kept.
archive_open :: proc(a: ^Archive, path: string) -> bool {
	fresh, ok := archive_index(path)
	if !ok {
		return false
	}
	archive_swap(a, path, fresh)
	return true
}

// Everything the archive holds, its remembered and kept paths included: what
// its owner calls once it is done with it. Not archive.close, which forgets the
// path but keeps counting changes.
archive_close :: proc(a: ^Archive) {
	archive_release(a)
	delete(a.path)
	delete(a.keep_path)
	a^ = {}
}

// Let go of the open archive and its bank, keeping what outlives them: the
// path to reopen, where it is kept, and the change count.
@(private = "file")
archive_release :: proc(a: ^Archive) {
	archive_close_bank(a)
	if a.open {
		delete(a.entries)
		delete(a.cd)
		delete(a.bank_indices)
		os.close(a.file)
	}
	a.file = nil
	a.cd = nil
	a.entries = nil
	a.bank_indices = nil
	a.open = false
}

@(private = "file")
archive_close_bank :: proc(a: ^Archive) {
	if a.bank_open {
		zip.zip_close(&a.bank)
		delete(a.bank_bytes)
		delete(a.patch_indices)
		a.bank_bytes = nil
		a.patch_indices = nil
		a.bank_name = ""
		a.bank_open = false
	}
}

// Read one outer entry's bytes straight from the file: local header for the data
// offset, then the data, inflated (or copied for a stored entry). Caller owns it.
@(private = "file")
archive_read_entry :: proc(a: ^Archive, e: zip.Entry, allocator := context.allocator) -> ([]u8, bool) {
	hdr: [30]u8
	hn, herr := os.read_at(a.file, hdr[:], i64(e.local_offset))
	if herr != nil || hn != 30 {
		return nil, false
	}
	if hdr[0] != 'P' || hdr[1] != 'K' || hdr[2] != 3 || hdr[3] != 4 {
		return nil, false
	}
	name_len := int(hdr[26]) | int(hdr[27]) << 8
	extra_len := int(hdr[28]) | int(hdr[29]) << 8
	data_start := i64(e.local_offset) + 30 + i64(name_len) + i64(extra_len)
	// The sizes are the central directory's own claims: bound them by the cap
	// and the file before they become an allocation.
	file_size, serr := os.file_size(a.file)
	if serr != nil || e.comp_size > zip.MAX_ENTRY_SIZE || e.uncomp_size > zip.MAX_ENTRY_SIZE ||
	   data_start + i64(e.comp_size) > file_size {
		return nil, false
	}
	comp := make([]u8, e.comp_size, context.temp_allocator)
	dn, derr := os.read_at(a.file, comp, data_start)
	if derr != nil || dn != int(e.comp_size) {
		return nil, false
	}
	return zip.inflate_entry(comp, e.method, e.uncomp_size, allocator)
}

// Open an inner bank by its index within bank_indices, replacing any open one.
// The bank already open is left as it is rather than read again, so a client
// that asks for the bank it is showing changes nothing.
archive_open_bank :: proc(a: ^Archive, bank: int) -> bool {
	if !a.open || bank < 0 || bank >= len(a.bank_indices) {
		return false
	}
	if a.bank_open && a.bank_at == bank {
		return true
	}
	bytes, z, patches, ok := archive_read_bank(a, bank)
	if !ok {
		return false
	}
	archive_close_bank(a)
	a.bank_bytes = bytes
	a.bank = z
	a.patch_indices = patches
	a.bank_name = base_name(a.entries[a.bank_indices[bank]].name)
	a.bank_at = bank
	a.bank_open = true
	return true
}

// Read an inner bank and find its patches, touching nothing open: what opening
// a bank and a Program Change from a bank not open both read, so a patch index
// means the same patch to both. The caller owns bytes, z and patches.
@(private = "file")
archive_read_bank :: proc(a: ^Archive, bank: int) -> (bytes: []u8, z: zip.Zip, patches: []int, ok: bool) {
	bytes, ok = archive_read_entry(a, a.entries[a.bank_indices[bank]], context.allocator)
	if !ok {
		return
	}
	z, ok = zip.zip_open(bytes)
	if !ok {
		delete(bytes)
		return nil, {}, nil, false
	}
	// Keep only the .sy1 patches, in order, so browsing and loading skip the
	// directory markers and stray files a bank zip carries.
	found: [dynamic]int
	for i in 0 ..< zip.zip_count(&z) {
		if strings.has_suffix(strings.to_lower(zip.zip_name(&z, i), context.temp_allocator), ".sy1") {
			append(&found, i)
		}
	}
	return bytes, z, found[:], true
}

// How many loadable patches the open bank has.
archive_patch_count :: proc(a: ^Archive) -> int {
	return len(a.patch_indices)
}

// Remember where the archive path is kept, and reopen the archive a previous
// run kept there. Not a change any client could have missed -- nobody was
// connected -- so archive_rev stays where it starts. A kept path that does not
// open stays remembered, and the file stays as it is, so the next start, or an
// archive.open with no path, tries it again.
archive_restore :: proc(a: ^Archive, keep_path: string) {
	delete(a.keep_path)
	a.keep_path = strings.clone(keep_path)
	if keep_path == "" {return}
	data, err := os.read_entire_file(keep_path, context.temp_allocator)
	if err != nil {return}
	path := string(data)
	if nl := strings.index_any(path, "\r\n"); nl >= 0 {path = path[:nl]}
	if path == "" {return}
	if !archive_open(a, path) {
		delete(a.path)
		a.path = strings.clone(path)
	}
}

// Write path where the next start reads it, or report that it could not be:
// the caller then changes nothing, so what is kept and what is open never
// disagree. True without a keep_path, which keeps nothing.
@(private = "file")
archive_keep :: proc(a: ^Archive, path: string) -> bool {
	if a.keep_path == "" {return true}
	text := strings.concatenate({path, "\n"}, context.temp_allocator)
	return write_file_atomic(a.keep_path, text)
}

// The patch's own name from inside its .sy1 (or .json), or "" if it cannot be
// read. Inflates and parses just that one entry -- one small file, not the bank --
// so listing a bank's names stays cheap. Temp-allocated.
@(private = "file")
archive_patch_name :: proc(a: ^Archive, patch_i: int) -> string {
	if patch_i < 0 || patch_i >= len(a.patch_indices) {
		return ""
	}
	data, ok := zip.zip_read(&a.bank, a.patch_indices[patch_i], context.temp_allocator)
	if !ok {
		return ""
	}
	parsed, _, pok := patch.parse_patch_any(data, context.temp_allocator)
	if !pok {
		return ""
	}
	return parsed.name
}

// The basename of a path, without directory or a trailing slash.
@(private)
base_name :: proc(path: string) -> string {
	p := path
	if strings.has_suffix(p, "/") {
		p = p[:len(p) - 1]
	}
	if slash := strings.last_index_byte(p, '/'); slash >= 0 {
		p = p[slash + 1:]
	}
	return p
}

// Index the archive at path and make it the open one, all or nothing. The
// path is kept for the next start before the swap, unless keep is false (the
// remembered path again, which the file already holds), so a path that cannot
// be kept leaves the open archive, its path, the generation and the playing
// patch's indices as they were. Writes the refusal and returns false.
@(private = "file")
archive_replace :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder, path: string, keep: bool) -> bool {
	a := cc.archive
	fresh, ok := archive_index(path)
	if !ok {
		control_write_err(out, req, .Invalid_Payload, "cannot open archive")
		return false
	}
	if keep && !archive_keep(a, path) {
		archive_release(&fresh)
		control_write_err(out, req, .Internal_Error, "cannot keep archive path")
		return false
	}
	archive_swap(a, path, fresh)
	a.rev += 1
	// Even the same path again: the file may have changed under its name, so
	// the playing patch's indices may no longer name it.
	identity_forget_archive(cc.identity)
	return true
}

// archive.open [path]: index an archive and report how many banks it holds.
// With no path, the remembered one is opened again.
@(private)
control_archive_open :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive support")
		return
	}
	path := strings.trim_space(req.rest)
	explicit := len(path) > 0
	if !explicit {
		path = cc.archive.path
	}
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "open needs a path")
		return
	}
	if !archive_replace(cc, req, out, path, explicit) {
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " banks=")
	strings.write_int(out, len(cc.archive.bank_indices))
	control_write_archive_rev(cc, out)
}

// archive.adopt <path>: take a path a client holds from before the daemon
// kept one, unless the daemon has made a choice since -- an archive open, or
// a path remembered even though it will not open. Deciding and opening are
// one request, so no peer's open can fall between a client's look and its
// hand-over.
@(private)
control_archive_adopt :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	a := cc.archive
	if a == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive support")
		return
	}
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "adopt needs a path")
		return
	}
	adopt := !a.open && a.path == ""
	if adopt && !archive_replace(cc, req, out, path, true) {
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " adopted=")
	strings.write_int(out, adopt ? 1 : 0)
	strings.write_string(out, " open=")
	strings.write_int(out, a.open ? 1 : 0)
	strings.write_string(out, " banks=")
	strings.write_int(out, a.open ? len(a.bank_indices) : 0)
	control_write_archive_rev(cc, out)
}

// archive.current: what is open, for every client to show the same archive. The
// path and the open bank's name are record lines, always both and in that
// order, raw to the line end like patch.current's names.
@(private)
control_archive_current :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	a := cc.archive
	if a == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive support")
		return
	}
	banks, bank, patches := 0, -1, 0
	if a.open {
		banks = len(a.bank_indices)
		if a.bank_open {
			bank = a.bank_at
			patches = archive_patch_count(a)
		}
	}
	control_write_ok(out, req)
	strings.write_string(out, " open=")
	strings.write_int(out, a.open ? 1 : 0)
	strings.write_string(out, " banks=")
	strings.write_int(out, banks)
	strings.write_string(out, " bank=")
	strings.write_int(out, bank)
	strings.write_string(out, " patches=")
	strings.write_int(out, patches)
	control_write_archive_rev(cc, out)
	strings.write_string(out, "\npath=")
	strings.write_string(out, a.path)
	strings.write_string(out, "\nbank_name=")
	strings.write_string(out, a.bank_open ? a.bank_name : "")
}

// archive.banks <offset> <count>: a page of bank names.
@(private)
control_archive_banks :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil || !cc.archive.open {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive open")
		return
	}
	offset, count := paged_range(req, len(cc.archive.bank_indices))
	control_write_ok(out, req)
	strings.write_string(out, " total=")
	strings.write_int(out, len(cc.archive.bank_indices))
	control_write_archive_rev(cc, out)
	for i in offset ..< offset + count {
		e := cc.archive.entries[cc.archive.bank_indices[i]]
		strings.write_byte(out, '\n')
		strings.write_string(out, "bank=")
		strings.write_int(out, i)
		// name last and raw, so it keeps its spaces for a client to read to line end.
		strings.write_string(out, " name=")
		strings.write_string(out, base_name(e.name))
	}
}

// archive.bank <index>: open a bank and report how many patches it holds. Only
// browsing: the sound and its provenance stay as they are.
@(private)
control_archive_bank :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil || !cc.archive.open {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive open")
		return
	}
	if req.operand_count < 1 {
		control_write_err(out, req, .Invalid_Payload, "bank needs an index")
		return
	}
	i, ok := parse_index(req.operands[0])
	if !ok || !archive_switch_bank(cc.archive, i) {
		control_write_err(out, req, .Invalid_Payload, "cannot open that bank")
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " patches=")
	strings.write_int(out, archive_patch_count(cc.archive))
	strings.write_string(out, " bank=")
	strings.write_int(out, i)
	control_write_archive_rev(cc, out)
}

// Open a bank for a command, counting it as a change only when the open bank
// really moved: asking for the bank already open must not send every peer off
// to re-read it.
@(private = "file")
archive_switch_bank :: proc(a: ^Archive, bank: int) -> bool {
	same := a.bank_open && a.bank_at == bank
	if !archive_open_bank(a, bank) {return false}
	if !same {a.rev += 1}
	return true
}

// archive.patches <offset> <count>: a page of patch names in the open bank.
@(private)
control_archive_patches :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil || !cc.archive.bank_open {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank open")
		return
	}
	total := archive_patch_count(cc.archive)
	offset, count := paged_range(req, total)
	control_write_ok(out, req)
	strings.write_string(out, " total=")
	strings.write_int(out, total)
	// Which bank these are, so a client paging through them can tell a peer
	// moved the open bank between two pages.
	strings.write_string(out, " bank=")
	strings.write_int(out, cc.archive.bank_at)
	control_write_archive_rev(cc, out)
	for i in offset ..< offset + count {
		// The patch's own name from inside the .sy1, falling back to the file name
		// when it carries none. name last and raw so it keeps its spaces.
		name := archive_patch_name(cc.archive, i)
		if name == "" {
			name = base_name(zip.zip_name(&cc.archive.bank, cc.archive.patch_indices[i]))
		}
		strings.write_byte(out, '\n')
		strings.write_string(out, "patch=")
		strings.write_int(out, i)
		strings.write_string(out, " name=")
		strings.write_string(out, name)
	}
}

// archive.load <index> [bank]: inflate one patch and apply it as one atomic
// transaction, exactly like loading a slot. The bank, when given, is the one the
// client is showing: a peer may have opened another since the client listed
// it, and the patch meant is the one the client's list names, so that bank is
// opened first. Without it the patch comes from the open bank, as it always did.
@(private)
control_archive_load :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	a := cc.archive
	if a == nil || (!a.bank_open && req.operand_count < 2) {
		control_write_err(out, req, .Daemon_Not_Ready, "no bank open")
		return
	}
	if req.operand_count < 1 {
		control_write_err(out, req, .Invalid_Payload, "load needs an index")
		return
	}
	i, ok := parse_index(req.operands[0])
	if !ok {
		control_write_err(out, req, .Invalid_Payload, "bad index")
		return
	}
	if req.operand_count >= 2 {
		// As archive.bank would answer: the request names a bank of the open
		// archive, and with none open there is no bank to name.
		if !a.open {
			control_write_err(out, req, .Daemon_Not_Ready, "no archive open")
			return
		}
		b, bok := parse_index(req.operands[1])
		if !bok || !archive_switch_bank(a, b) {
			control_write_err(out, req, .Invalid_Payload, "cannot open that bank")
			return
		}
	}
	applied, result := archive_load_patch(cc, &a.bank, a.patch_indices, a.bank_name, a.bank_at, i)
	switch result {
	case .Out_Of_Range:
		control_write_err(out, req, .Invalid_Payload, "patch index out of range")
		return
	case .Unreadable:
		control_write_err(out, req, .Invalid_Payload, "cannot read patch")
		return
	case .Unparseable:
		control_write_err(out, req, .Invalid_Payload, "cannot parse patch")
		return
	case .No_Parameters:
		control_write_err(out, req, .Invalid_Payload, "patch set no parameters")
		return
	case .Queue_Full, .No_Room:
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	case .Ok:
	}
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, applied)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
	strings.write_string(out, " bank=")
	strings.write_int(out, a.bank_at)
	strings.write_string(out, " patch=")
	strings.write_int(out, i)
}

@(private = "file")
Archive_Load_Result :: enum {
	Ok,
	Out_Of_Range,
	Unreadable,
	Unparseable,
	No_Parameters,
	Queue_Full,
	// Only for a load that waits: it would load, but the ring has no room
	// for a whole one yet.
	No_Room,
}

// Load patch i of an inner bank as one replacement and name it as the playing
// patch. Both archive.load and a native Program Change come here, so a patch
// cannot load one way from a client and another from a keyboard. Anything but
// Ok has queued nothing and left the identity alone. A Program Change waits
// for room rather than be refused, so it passes `wait`: a load the ring has no
// room for is then No_Room before the ring is offered anything, which would
// count it as dropped. Reads the entry into the temp allocator.
@(private = "file")
archive_load_patch :: proc(
	cc: ^Control_Context,
	z: ^zip.Zip,
	patches: []int,
	bank_name: string,
	bank, i: int,
	wait := false,
) -> (
	applied: int,
	result: Archive_Load_Result,
) {
	if i < 0 || i >= len(patches) {return 0, .Out_Of_Range}
	data, read_ok := zip.zip_read(z, patches[i], context.temp_allocator)
	if !read_ok {return 0, .Unreadable}
	parsed, perr := patch.parse_sy1(data)
	if perr != .None {return 0, .Unparseable}
	// Before any question of room: a patch that sets nothing selects nothing,
	// and must not wait for room it would never use.
	if !slice.contains(parsed.present[:], true) {return 0, .No_Parameters}
	if wait && !bank_load_has_room(cc) {return 0, .No_Room}
	values: [patch.PARAMETER_COUNT]i32
	for j in 0 ..< patch.PARAMETER_COUNT {values[j] = i32(parsed.values[j])}
	n, full := control_apply_patch(cc, values, parsed.present)
	if full {return 0, .Queue_Full}
	// Named as archive.patches lists it: its own name, else its file name.
	shown := strings.trim_space(parsed.name)
	if shown == "" {shown = base_name(zip.zip_name(z, patches[i]))}
	identity_set(cc.identity, .Archive, -1, bank_name, shown, bank, i)
	return n, .Ok
}

// A native Program Change's patch i of `bank`, a bank of the open archive: the
// one the sound is playing from, which need not be the one open, since a peer
// may have browsed another since. A Program Change must not move what every
// client is browsing -- archive.bank does that, and counts it -- so a bank
// that is not open is read beside the open one and let go at once. False when
// the patch would load but the ring has no room for a whole load: it waits, as
// a slot's load does. Anything else that does not load changes nothing.
//
// It can run on every drain tick for as long as the daemon does, outside any
// request, whose temporary allocations the control thread gives back once it
// is answered; so what this reads there goes when it returns.
@(private)
archive_program_load :: proc(cc: ^Control_Context, bank, i: int) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	a := cc.archive
	if a.bank_open && a.bank_at == bank {
		_, result := archive_load_patch(cc, &a.bank, a.patch_indices, a.bank_name, bank, i, wait = true)
		return result != .No_Room
	}
	bytes, z, patches, ok := archive_read_bank(a, bank)
	if !ok {return true}
	defer {
		zip.zip_close(&z)
		delete(bytes)
		delete(patches)
	}
	name := base_name(a.entries[a.bank_indices[bank]].name)
	_, result := archive_load_patch(cc, &z, patches, name, bank, i, wait = true)
	return result != .No_Room
}

// archive.close: release the archive and any open bank, and forget the path, so
// neither this daemon nor the next one reopens it. The kept path goes first: if
// it cannot be removed nothing is released, so what is kept and what is open
// never disagree.
@(private)
control_archive_close :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if a := cc.archive; a != nil {
		if a.keep_path != "" {
			if rerr := os.remove(a.keep_path); rerr != nil && rerr != os.General_Error.Not_Exist {
				control_write_err(out, req, .Internal_Error, "cannot forget archive path")
				return
			}
		}
		changed := a.open || a.path != ""
		archive_release(a)
		delete(a.path)
		a.path = ""
		if changed {a.rev += 1}
	}
	identity_forget_archive(cc.identity)
	control_write_ok(out, req)
	control_write_archive_rev(cc, out)
}

// The archive generation, after a command that reports it. 0 without an archive
// to count it (a bare handler in a test), as patch.current reports it then.
@(private = "file")
control_write_archive_rev :: proc(cc: ^Control_Context, out: ^strings.Builder) {
	strings.write_string(out, " archive_rev=")
	strings.write_uint(out, cc.archive != nil ? cc.archive.rev : 0)
}

// A paged (offset, count) from operands[0..1], clamped to [0, total]. A missing
// count defaults to a screenful; the count is capped so one response stays small.
@(private = "file")
paged_range :: proc(req: control.Request, total: int) -> (offset, count: int) {
	PAGE_MAX :: 256
	off := 0
	if req.operand_count >= 1 {
		if v, ok := parse_index(req.operands[0]); ok {off = v}
	}
	cnt := 64
	if req.operand_count >= 2 {
		if v, ok := parse_index(req.operands[1]); ok {cnt = v}
	}
	off = clamp(off, 0, total)
	cnt = clamp(cnt, 0, PAGE_MAX)
	if off + cnt > total {
		cnt = total - off
	}
	return off, cnt
}

@(private = "file")
parse_index :: proc(s: string) -> (int, bool) {
	n := 0
	if len(s) == 0 {
		return 0, false
	}
	for r in s {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n * 10 + int(r - '0')
	}
	return n, true
}
