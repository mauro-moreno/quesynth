package standalone

import "core:os"
import "core:strings"

import "../../src/control"
import "../../src/patch"
import "../../src/zip"

// Browsing a large patch archive without unpacking it. The corpus is an outer zip
// of many inner bank zips, each holding many .sy1 patches -- tens of thousands in
// all. Expanding that into memory would be absurd, so nothing here does: the
// archive keeps only the outer central directory (a light index) and reads on
// demand, holding at most one inner bank (tens of kilobytes) and one inflated
// patch at a time. Entries are pulled straight from the file with read_at, so the
// archive file itself is never resident either.
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

// Open and index an archive: read its central directory and note which entries
// are inner bank zips. The file stays open for on-demand reads until close.
//
// The archive already open is let go only once the new one has indexed: a path
// that does not open must not take away the archive another client is in the
// middle of browsing.
archive_open :: proc(a: ^Archive, path: string) -> bool {
	f, err := os.open(path)
	if err != nil {
		return false
	}
	size, serr := os.file_size(f)
	if serr != nil || size < 22 {
		os.close(f)
		return false
	}
	tail_len := min(size, 65557) // 22-byte record + 65535-byte max comment
	tail := make([]u8, tail_len, context.temp_allocator)
	tn, terr := os.read_at(f, tail, size - tail_len)
	if terr != nil {
		os.close(f)
		return false
	}
	cd_offset, cd_size, count, found := zip.find_eocd(tail[:tn])
	if !found {
		os.close(f)
		return false
	}
	cd := make([]u8, cd_size)
	cn, cerr := os.read_at(f, cd, i64(cd_offset))
	if cerr != nil || cn != int(cd_size) {
		delete(cd)
		os.close(f)
		return false
	}
	entries, parsed := zip.parse_central(cd, 0, cd_size, count)
	if !parsed {
		delete(cd)
		os.close(f)
		return false
	}
	banks: [dynamic]int
	for e, i in entries {
		if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".zip") {
			append(&banks, i)
		}
	}
	// Cloned before the old path goes: reopening the remembered archive passes
	// a.path itself.
	remembered := strings.clone(path)
	archive_release(a)
	delete(a.path)
	a.path = remembered
	a.file = f
	a.cd = cd
	a.entries = entries
	a.bank_indices = banks[:]
	a.open = true
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
	bytes, ok := archive_read_entry(a, a.entries[a.bank_indices[bank]], context.allocator)
	if !ok {
		return false
	}
	z, zok := zip.zip_open(bytes)
	if !zok {
		delete(bytes)
		return false
	}
	archive_close_bank(a)
	// Keep only the .sy1 patches, in order, so browsing and loading skip the
	// directory markers and stray files a bank zip carries.
	patches: [dynamic]int
	for i in 0 ..< zip.zip_count(&z) {
		if strings.has_suffix(strings.to_lower(zip.zip_name(&z, i), context.temp_allocator), ".sy1") {
			append(&patches, i)
		}
	}
	a.bank_bytes = bytes
	a.bank = z
	a.patch_indices = patches[:]
	a.bank_name = base_name(a.entries[a.bank_indices[bank]].name)
	a.bank_at = bank
	a.bank_open = true
	return true
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

// Write the remembered path where the next start reads it. Best effort, as the
// TUI's own settings are: the archive is open either way, and only the next
// start would miss it.
@(private = "file")
archive_keep :: proc(a: ^Archive) {
	if a.keep_path == "" {return}
	text := strings.concatenate({a.path, "\n"}, context.temp_allocator)
	_ = write_file_atomic(a.keep_path, text)
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

// archive.open [path]: index an archive and report how many banks it holds.
// With no path, the remembered one is opened again.
@(private)
control_archive_open :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive support")
		return
	}
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		path = cc.archive.path
	}
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "open needs a path")
		return
	}
	if !archive_open(cc.archive, path) {
		control_write_err(out, req, .Invalid_Payload, "cannot open archive")
		return
	}
	cc.archive.rev += 1
	archive_keep(cc.archive)
	// Even the same path again: the file may have changed under its name, so
	// the playing patch's indices may no longer name it.
	identity_forget_archive(cc.identity)
	control_write_ok(out, req)
	strings.write_string(out, " banks=")
	strings.write_int(out, len(cc.archive.bank_indices))
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
	if i < 0 || i >= archive_patch_count(a) {
		control_write_err(out, req, .Invalid_Payload, "patch index out of range")
		return
	}
	data, read_ok := zip.zip_read(&a.bank, a.patch_indices[i], context.temp_allocator)
	if !read_ok {
		control_write_err(out, req, .Invalid_Payload, "cannot read patch")
		return
	}
	parsed, perr := patch.parse_sy1(data)
	if perr != .None {
		control_write_err(out, req, .Invalid_Payload, "cannot parse patch")
		return
	}
	values: [patch.PARAMETER_COUNT]i32
	for j in 0 ..< patch.PARAMETER_COUNT {values[j] = i32(parsed.values[j])}
	applied, full := control_apply_patch(cc, values, parsed.present)
	if full {
		control_write_err(out, req, .Daemon_Not_Ready, "control queue full")
		return
	}
	if applied == 0 {
		control_write_err(out, req, .Invalid_Payload, "patch set no parameters")
		return
	}
	// Named as archive.patches lists it: its own name, else its file name.
	shown := strings.trim_space(parsed.name)
	if shown == "" {shown = base_name(zip.zip_name(&a.bank, a.patch_indices[i]))}
	identity_set(cc.identity, .Archive, -1, a.bank_name, shown, a.bank_at, i)
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

// archive.close: release the archive and any open bank, and forget the path, so
// neither this daemon nor the next one reopens it.
@(private)
control_archive_close :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if a := cc.archive; a != nil {
		changed := a.open || a.path != ""
		archive_release(a)
		delete(a.path)
		a.path = ""
		if a.keep_path != "" {_ = os.remove(a.keep_path)}
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
