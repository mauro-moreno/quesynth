package zip

import "core:bytes"
import "core:compress/zlib"
import "core:mem"

// A minimal, read-only ZIP reader, enough to browse a bank archive and pull one
// entry at a time without decompressing the rest. It reads the central directory
// into a light index and inflates a single entry on demand, so a zip of many
// thousands of patches costs an index and one decompressed entry, never the whole
// archive expanded in memory.
//
// Scope: no ZIP64, no encryption, and the two storage methods these banks use --
// stored (0) and deflate (8). Multi-disk archives are rejected. The central
// directory and local headers are parsed by the spec's fixed offsets; anything
// unexpected fails cleanly rather than guessing.

METHOD_STORE :: 0
METHOD_DEFLATE :: 8

@(private)
SIG_EOCD :: 0x06054b50 // end of central directory
@(private)
SIG_CENTRAL :: 0x02014b50 // central directory file header
@(private)
SIG_LOCAL :: 0x04034b50 // local file header

// One catalogued entry. `name` points into the central-directory bytes the index
// was parsed from, so those bytes must outlive the entry.
Entry :: struct {
	name:         string,
	method:       u16,
	comp_size:    u32,
	uncomp_size:  u32,
	local_offset: u32,
}

@(private)
read_u16 :: proc(b: []u8, off: int) -> (u16, bool) {
	if off < 0 || off + 2 > len(b) {
		return 0, false
	}
	return u16(b[off]) | u16(b[off + 1]) << 8, true
}

@(private)
read_u32 :: proc(b: []u8, off: int) -> (u32, bool) {
	if off < 0 || off + 4 > len(b) {
		return 0, false
	}
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24, true
}

// Locate the end-of-central-directory record by scanning back from the end of
// `data` for its signature. Returns the central directory's offset and size and
// the entry count. `data` must be the whole archive (or at least its tail through
// the end); offsets are archive-absolute.
find_eocd :: proc(data: []u8) -> (cd_offset: u32, cd_size: u32, count: int, ok: bool) {
	if len(data) < 22 {
		return 0, 0, 0, false
	}
	// The record is 22 bytes plus a comment of up to 65535; scan that window.
	start := len(data) - 22
	limit := max(0, len(data) - 22 - 65535)
	for i := start; i >= limit; i -= 1 {
		sig, _ := read_u32(data, i)
		if sig != SIG_EOCD {
			continue
		}
		disk, _ := read_u16(data, i + 4)
		cd_disk, _ := read_u16(data, i + 6)
		total, _ := read_u16(data, i + 10)
		size, _ := read_u32(data, i + 12)
		offset, _ := read_u32(data, i + 16)
		comment_len, _ := read_u16(data, i + 20)
		// A real EOCD ends exactly at its stated comment length and is on a
		// single disk; anything else is a false signature match in the data.
		if disk != 0 || cd_disk != 0 {
			return 0, 0, 0, false
		}
		if i + 22 + int(comment_len) != len(data) {
			continue
		}
		return offset, size, int(total), true
	}
	return 0, 0, 0, false
}

// Parse the central directory occupying `data[cd_offset:cd_offset+cd_size]` into
// entries. Names alias into `data`. `count` is the EOCD's promised entry count.
parse_central :: proc(
	data: []u8,
	cd_offset, cd_size: u32,
	count: int,
	allocator := context.allocator,
) -> (
	entries: []Entry,
	ok: bool,
) {
	if int(cd_offset) + int(cd_size) > len(data) {
		return nil, false
	}
	out := make([dynamic]Entry, 0, count, allocator)
	off := int(cd_offset)
	end := int(cd_offset) + int(cd_size)
	for len(out) < count {
		if off + 46 > end {
			break
		}
		sig, _ := read_u32(data, off)
		if sig != SIG_CENTRAL {
			break
		}
		method, _ := read_u16(data, off + 10)
		comp, _ := read_u32(data, off + 20)
		uncomp, _ := read_u32(data, off + 24)
		name_len, _ := read_u16(data, off + 28)
		extra_len, _ := read_u16(data, off + 30)
		comment_len, _ := read_u16(data, off + 32)
		local_off, _ := read_u32(data, off + 42)
		name_start := off + 46
		name_end := name_start + int(name_len)
		if name_end > end {
			break
		}
		append(
			&out,
			Entry {
				name = string(data[name_start:name_end]),
				method = method,
				comp_size = comp,
				uncomp_size = uncomp,
				local_offset = local_off,
			},
		)
		off = name_end + int(extra_len) + int(comment_len)
	}
	if len(out) != count {
		delete(out)
		return nil, false
	}
	return out[:], true
}

// The byte range of an entry's compressed data within the whole archive `data`,
// found by reading its local header (whose name and extra lengths may differ from
// the central record's).
entry_data_range :: proc(data: []u8, e: Entry) -> (start, size: int, ok: bool) {
	base := int(e.local_offset)
	sig, sok := read_u32(data, base)
	if !sok || sig != SIG_LOCAL {
		return 0, 0, false
	}
	name_len, _ := read_u16(data, base + 26)
	extra_len, _ := read_u16(data, base + 28)
	start = base + 30 + int(name_len) + int(extra_len)
	size = int(e.comp_size)
	if start < 0 || start + size > len(data) {
		return 0, 0, false
	}
	return start, size, true
}

// Decompress `comp` (an entry's raw stored/deflated bytes) into `uncomp_size`
// bytes. The caller owns the returned slice.
inflate_entry :: proc(
	comp: []u8,
	method: u16,
	uncomp_size: u32,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	switch method {
	case METHOD_STORE:
		if int(uncomp_size) != len(comp) {
			return nil, false
		}
		out := make([]u8, len(comp), allocator)
		copy(out, comp)
		return out, true
	case METHOD_DEFLATE:
		buf: bytes.Buffer
		if zlib.inflate_from_byte_array(comp, &buf, true, int(uncomp_size)) != nil {
			bytes.buffer_destroy(&buf)
			return nil, false
		}
		src := bytes.buffer_to_bytes(&buf)
		out := make([]u8, len(src), allocator)
		copy(out, src)
		bytes.buffer_destroy(&buf)
		return out, true
	}
	return nil, false
}

// A whole in-memory archive: the bytes plus the parsed index. Use for an archive
// small enough to hold at once, such as one inner bank extracted from an outer.
Zip :: struct {
	data:    []u8,
	entries: []Entry,
	allocator: mem.Allocator,
}

// Index an in-memory archive. `data` is borrowed, not copied; keep it alive for
// the Zip's lifetime. Entry names alias into it.
zip_open :: proc(data: []u8, allocator := context.allocator) -> (z: Zip, ok: bool) {
	cd_offset, cd_size, count, found := find_eocd(data)
	if !found {
		return {}, false
	}
	entries, parsed := parse_central(data, cd_offset, cd_size, count, allocator)
	if !parsed {
		return {}, false
	}
	return Zip{data = data, entries = entries, allocator = allocator}, true
}

zip_close :: proc(z: ^Zip) {
	if z.entries != nil { delete(z.entries, z.allocator) }
	z^ = {}
}

zip_count :: proc(z: ^Zip) -> int {
	return len(z.entries)
}

zip_name :: proc(z: ^Zip, index: int) -> string {
	if index < 0 || index >= len(z.entries) {
		return ""
	}
	return z.entries[index].name
}

// Decompress one entry by index. The caller owns the returned slice.
zip_read :: proc(z: ^Zip, index: int, allocator := context.allocator) -> ([]u8, bool) {
	if index < 0 || index >= len(z.entries) {
		return nil, false
	}
	e := z.entries[index]
	start, size, ok := entry_data_range(z.data, e)
	if !ok {
		return nil, false
	}
	return inflate_entry(z.data[start:start + size], e.method, e.uncomp_size, allocator)
}
