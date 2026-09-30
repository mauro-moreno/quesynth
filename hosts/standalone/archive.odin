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

Archive :: struct {
	file:         ^os.File,
	// The outer central directory, kept because entry names alias into it.
	cd:           []u8,
	entries:      []zip.Entry,
	// Outer entries that are inner bank zips, in order: the browsable banks.
	bank_indices: []int,
	open:         bool,
	// The one inner bank currently open, if any.
	bank_bytes:    []u8,
	bank:          zip.Zip,
	bank_open:     bool,
	// Indices within the open bank of its .sy1 patches, excluding directory and
	// other entries: the browsable, loadable patches.
	patch_indices: []int,
	// The open bank's display name, for naming a patch loaded from it. It aliases
	// the central directory like every entry name, and the directory outlives any
	// open bank, so there is nothing of its own to free.
	bank_name:     string,
}

// Open and index an archive: read its central directory and note which entries
// are inner bank zips. The file stays open for on-demand reads until close.
archive_open :: proc(a: ^Archive, path: string) -> bool {
	archive_close(a)
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
	a.file = f
	a.cd = cd
	a.entries = entries
	a.bank_indices = banks[:]
	a.open = true
	return true
}

archive_close :: proc(a: ^Archive) {
	archive_close_bank(a)
	if a.open {
		delete(a.entries)
		delete(a.cd)
		delete(a.bank_indices)
		os.close(a.file)
	}
	a^ = {}
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
archive_open_bank :: proc(a: ^Archive, bank: int) -> bool {
	if !a.open || bank < 0 || bank >= len(a.bank_indices) {
		return false
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
	a.bank_open = true
	return true
}

// How many loadable patches the open bank has.
archive_patch_count :: proc(a: ^Archive) -> int {
	return len(a.patch_indices)
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

// archive.open <path>: index an archive and report how many banks it holds.
@(private)
control_archive_open :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil {
		control_write_err(out, req, .Daemon_Not_Ready, "no archive support")
		return
	}
	path := strings.trim_space(req.rest)
	if len(path) == 0 {
		control_write_err(out, req, .Invalid_Payload, "open needs a path")
		return
	}
	if !archive_open(cc.archive, path) {
		control_write_err(out, req, .Invalid_Payload, "cannot open archive")
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " banks=")
	strings.write_int(out, len(cc.archive.bank_indices))
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

// archive.bank <index>: open a bank and report how many patches it holds.
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
	if !ok || !archive_open_bank(cc.archive, i) {
		control_write_err(out, req, .Invalid_Payload, "cannot open that bank")
		return
	}
	control_write_ok(out, req)
	strings.write_string(out, " patches=")
	strings.write_int(out, archive_patch_count(cc.archive))
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

// archive.load <index>: inflate one patch from the open bank and apply it as one
// atomic transaction, exactly like loading a slot.
@(private)
control_archive_load :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive == nil || !cc.archive.bank_open {
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
	if i < 0 || i >= archive_patch_count(cc.archive) {
		control_write_err(out, req, .Invalid_Payload, "patch index out of range")
		return
	}
	data, read_ok := zip.zip_read(&cc.archive.bank, cc.archive.patch_indices[i], context.temp_allocator)
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
	if shown == "" {shown = base_name(zip.zip_name(&cc.archive.bank, cc.archive.patch_indices[i]))}
	identity_set(cc.identity, -1, cc.archive.bank_name, shown)
	snap := snapshot_read(cc.snapshot)
	control_write_ok(out, req)
	strings.write_string(out, " count=")
	strings.write_int(out, applied)
	strings.write_string(out, " revision=")
	strings.write_int(out, snap.revision)
}

// archive.close: release the archive and any open bank.
@(private)
control_archive_close :: proc(cc: ^Control_Context, req: control.Request, out: ^strings.Builder) {
	if cc.archive != nil {
		archive_close(cc.archive)
	}
	control_write_ok(out, req)
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
