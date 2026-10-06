package zip_tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import zip "../../src/zip"

// The reader against a nested fixture shaped like the real bank archive: an outer
// zip holding an inner bank zip STORED, the inner holding DEFLATE-compressed
// patch files. This is the two-level, lazy path the daemon walks.

@(test)
test_zip_opens_and_lists_outer :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file("tests/zip/fixtures/nested.zip", context.temp_allocator)
	if !testing.expect(t, rerr == nil) {return}
	z, ok := zip.zip_open(data, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	defer zip.zip_close(&z)

	testing.expect_value(t, zip.zip_count(&z), 2)
	found_inner := false
	for i in 0 ..< zip.zip_count(&z) {
		if zip.zip_name(&z, i) == "banks/bankA.zip" {found_inner = true}
	}
	testing.expect(t, found_inner)
}

@(test)
test_zip_reads_stored_inner_then_deflated_patch :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file("tests/zip/fixtures/nested.zip", context.temp_allocator)
	if !testing.expect(t, rerr == nil) {return}
	outer, ok := zip.zip_open(data, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	defer zip.zip_close(&outer)

	// Pull the inner bank out of the outer archive (stored, so a plain copy).
	inner_index := -1
	for i in 0 ..< zip.zip_count(&outer) {
		if strings.has_suffix(zip.zip_name(&outer, i), ".zip") {inner_index = i}
	}
	if !testing.expect(t, inner_index >= 0) {return}
	inner_bytes, read_ok := zip.zip_read(&outer, inner_index, context.temp_allocator)
	if !testing.expect(t, read_ok) {return}
	defer delete(inner_bytes, context.temp_allocator)

	// Index the inner bank and inflate one patch.
	inner, inner_ok := zip.zip_open(inner_bytes, context.temp_allocator)
	if !testing.expect(t, inner_ok) {return}
	defer zip.zip_close(&inner)
	testing.expect_value(t, zip.zip_count(&inner), 4)
	patch_index := -1
	for i in 0 ..< zip.zip_count(&inner) {
		if strings.has_suffix(zip.zip_name(&inner, i), "001.sy1") {patch_index = i}
	}
	if !testing.expect(t, patch_index >= 0) {return}
	content, cok := zip.zip_read(&inner, patch_index, context.temp_allocator)
	if !testing.expect(t, cok) {return}
	defer delete(content, context.temp_allocator)
	testing.expect(t, strings.contains(string(content), "color=green"))
	testing.expect(t, strings.contains(string(content), "0,3"))
}

@(test)
test_zip_rejects_non_zip :: proc(t: ^testing.T) {
	junk := []u8{'n', 'o', 't', ' ', 'a', ' ', 'z', 'i', 'p'}
	_, ok := zip.zip_open(junk, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_zip_close_uses_the_allocator_that_opened_it :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("tests/zip/fixtures/nested.zip", context.temp_allocator)
	if !testing.expect(t, err == nil) { return }
	owner, other: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, runtime.heap_allocator())
	mem.tracking_allocator_init(&other, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&owner)
	defer mem.tracking_allocator_destroy(&other)
	other.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	alloc := mem.Allocator{mem.tracking_allocator_proc, &owner}
	other_alloc := mem.Allocator{mem.tracking_allocator_proc, &other}
	for explicit in ([]bool{false, true}) {
		context.allocator = alloc
		z: zip.Zip
		ok: bool
		if explicit { z, ok = zip.zip_open(data, alloc) } else { z, ok = zip.zip_open(data) }
		if !testing.expect(t, ok) { continue }
		entries := z.entries
		context.allocator = other_alloc
		zip.zip_close(&z)
		testing.expect_value(t, len(owner.allocation_map), 0)
		testing.expect_value(t, len(other.bad_free_array), 0)
		testing.expect_value(t, zip.zip_count(&z), 0)
		// Keep a failing regression from leaking its fixture allocation.
		if len(owner.allocation_map) > 0 { delete(entries, alloc) }
		zip.zip_close(&z)
	}
	zero: zip.Zip
	zip.zip_close(&zero)
}

// Hardening against hostile archives. The crafted archives below are laid out
// by hand from the ZIP spec's fixed offsets (APPNOTE 4.3.7, 4.3.12, 4.3.16),
// not by the reader's own code, around deflate streams written out as literal
// bytes.

// Deflate "hello" as one final stored block: header, LEN, NLEN, data.
@(private = "file")
STORED_HELLO := [?]u8{0x01, 0x05, 0x00, 0xfa, 0xff, 'h', 'e', 'l', 'l', 'o'}

// 5000 'a's as one final fixed-Huffman block, from a reference zlib.
@(private = "file")
DEFLATE_A_5000 := [?]u8 {
	0xed, 0xc1, 0x31, 0x01, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0xac, 0xeb, 0x5f, 0xc2, 0x14, 0x7e, 0x40,
	0x01, 0x00, 0x00, 0x00, 0x00, 0x6f, 0x03,
}

@(private = "file")
put16 :: proc(b: ^[dynamic]u8, v: int) {
	append(b, u8(v), u8(v >> 8))
}

@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: int) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
set32 :: proc(b: []u8, off, v: int) {
	b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

// A one-entry archive named "e" whose local and central headers both carry
// `comp` and the given sizes, so a test can make them lie about `uncomp`.
@(private = "file")
craft_zip :: proc(method: int, comp: []u8, uncomp: int) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, 'P', 'K', 3, 4)
	put16(&b, 20); put16(&b, 0); put16(&b, method); put16(&b, 0); put16(&b, 0)
	put32(&b, 0); put32(&b, len(comp)); put32(&b, uncomp); put16(&b, 1); put16(&b, 0)
	append(&b, 'e')
	append(&b, ..comp)
	cd := len(b)
	append(&b, 'P', 'K', 1, 2)
	put16(&b, 20); put16(&b, 20); put16(&b, 0); put16(&b, method); put16(&b, 0); put16(&b, 0)
	put32(&b, 0); put32(&b, len(comp)); put32(&b, uncomp)
	put16(&b, 1); put16(&b, 0); put16(&b, 0); put16(&b, 0); put16(&b, 0); put32(&b, 0); put32(&b, 0)
	append(&b, 'e')
	cd_size := len(b) - cd
	append(&b, 'P', 'K', 5, 6)
	put16(&b, 0); put16(&b, 0); put16(&b, 1); put16(&b, 1)
	put32(&b, cd_size); put32(&b, cd); put16(&b, 0)
	return b[:]
}

// Offsets within the 22-byte record that ends craft_zip's archives.
@(private = "file")
EOCD_DISK :: 4
@(private = "file")
EOCD_COUNT :: 10
@(private = "file")
EOCD_SIZE :: 12
@(private = "file")
EOCD_COMMENT :: 20

@(private = "file")
tracked :: proc(track: ^mem.Tracking_Allocator) -> mem.Allocator {
	mem.tracking_allocator_init(track, runtime.heap_allocator())
	return mem.Allocator{mem.tracking_allocator_proc, track}
}

// A fake end record in the archive comment, with a stray disk number, must not
// stop the scan: it does not end the file, so it is not the end record.
@(test)
test_zip_skips_a_fake_end_record_in_the_comment :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file("tests/zip/fixtures/nested.zip", context.temp_allocator)
	if !testing.expect(t, rerr == nil) {return}
	// The fixture's own record ends it with no comment.
	fake := [?]u8{'P', 'K', 5, 6, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0}
	forged := make([]u8, len(data) + len(fake), context.temp_allocator)
	copy(forged, data)
	copy(forged[len(data):], fake[:])
	forged[len(data) - 2] = len(fake)
	z, ok := zip.zip_open(forged, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	defer zip.zip_close(&z)
	testing.expect_value(t, zip.zip_count(&z), 2)
}

// A record that really ends the file but names another disk is a multi-disk
// archive, and stays rejected.
@(test)
test_zip_rejects_a_multi_disk_end_record :: proc(t: ^testing.T) {
	data, rerr := os.read_entire_file("tests/zip/fixtures/nested.zip", context.temp_allocator)
	if !testing.expect(t, rerr == nil) {return}
	forged := make([]u8, len(data), context.temp_allocator)
	copy(forged, data)
	forged[len(data) - 22 + EOCD_DISK] = 1
	_, ok := zip.zip_open(forged, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_zip_deflate_must_inflate_to_exactly_the_declared_size :: proc(t: ^testing.T) {
	comp := DEFLATE_A_5000[:]
	exact, eok := zip.zip_open(craft_zip(zip.METHOD_DEFLATE, comp, 5000), context.temp_allocator)
	if !testing.expect(t, eok) {return}
	defer zip.zip_close(&exact)
	out, ok := zip.zip_read(&exact, 0, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(out), 5000)
	testing.expect(t, len(out) == 5000 && out[0] == 'a' && out[4999] == 'a')

	// The central directory claims fewer or more bytes than the stream makes.
	for declared in ([]int{4999, 5001, 10, 0}) {
		z, zok := zip.zip_open(craft_zip(zip.METHOD_DEFLATE, comp, declared), context.temp_allocator)
		if !testing.expect(t, zok) {continue}
		defer zip.zip_close(&z)
		_, rok := zip.zip_read(&z, 0, context.temp_allocator)
		testing.expectf(t, !rok, "declared %d accepted", declared)
	}
}

// A stream declared tiny that inflates to 3 MiB is a decompression bomb:
// 3066 bytes of deflate. It must be refused without the 4 MiB zlib would
// otherwise grow to, and without leaking what it did take.
@(test)
test_zip_deflate_bomb_is_refused_within_a_bounded_allocation :: proc(t: ^testing.T) {
	// A fixed-Huffman block from a reference zlib: one literal, then 3047 bytes
	// of zeros that are length-258 copies, then the end of block.
	bomb := make([dynamic]u8, context.temp_allocator)
	append(&bomb, 0xed, 0xc1, 0x01, 0x0d, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0xac, 0xef, 0x5f, 0xc2, 0x1c, 0x6e, 0x40, 0x01)
	for _ in 0 ..< 3047 {append(&bomb, 0)}
	append(&bomb, 0x7c, 0x1b)

	// zlib's working memory is what the budget bounds, so it is tracked apart
	// from the output.
	track, scratch_track: mem.Tracking_Allocator
	alloc := tracked(&track)
	scratch := tracked(&scratch_track)
	defer mem.tracking_allocator_destroy(&track)
	defer mem.tracking_allocator_destroy(&scratch_track)

	_, ok := zip.inflate_entry(bomb[:], zip.METHOD_DEFLATE, 10, alloc, scratch)
	testing.expect(t, !ok)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	testing.expectf(t, scratch_track.peak_memory_allocated < 2 << 20, "scratch peak %d", scratch_track.peak_memory_allocated)

	// Declared right, it is a real 3 MiB entry and inflates in full.
	out, ok2 := zip.inflate_entry(bomb[:], zip.METHOD_DEFLATE, 3 << 20, alloc, scratch)
	testing.expect(t, ok2)
	testing.expect_value(t, len(out), 3 << 20)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	delete(out, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// zlib does not report a stored block that no longer fits: it drops the bytes
// and carries on to a "finished" stream. Eighteen full stored blocks (1.1 MB)
// against a declared 10 bytes must still be refused, within the bounded buffer.
@(test)
test_zip_stored_blocks_past_the_declared_size_are_refused :: proc(t: ^testing.T) {
	stream := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< 18 {
		append(&stream, i == 17 ? 0x01 : 0x00, 0xff, 0xff, 0x00, 0x00)
		for _ in 0 ..< 65535 {append(&stream, 0x42)}
	}
	track, scratch_track: mem.Tracking_Allocator
	alloc := tracked(&track)
	scratch := tracked(&scratch_track)
	defer mem.tracking_allocator_destroy(&track)
	defer mem.tracking_allocator_destroy(&scratch_track)
	_, ok := zip.inflate_entry(stream[:], zip.METHOD_DEFLATE, 10, alloc, scratch)
	testing.expect(t, !ok)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	testing.expectf(t, scratch_track.peak_memory_allocated < 3 << 20, "scratch peak %d", scratch_track.peak_memory_allocated)

	// Declared one block short, which is past zlib's 1 MiB minimum, the buffer
	// fills to exactly the declared size and the last block is dropped, so the
	// length agrees and only the refused allocation says the stream ran over.
	_, short_ok := zip.inflate_entry(stream[:], zip.METHOD_DEFLATE, 17 * 65535, alloc, scratch)
	testing.expect(t, !short_ok)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)

	// Declared right, the same stream is a real 18-block entry.
	out, ok2 := zip.inflate_entry(stream[:], zip.METHOD_DEFLATE, 18 * 65535, alloc, scratch)
	testing.expect(t, ok2)
	testing.expect_value(t, len(out), 18 * 65535)
	testing.expect_value(t, len(scratch_track.allocation_map), 0)
	delete(out, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_zip_stored_and_deflate_agree_on_a_small_entry :: proc(t: ^testing.T) {
	for method in ([]int{zip.METHOD_STORE, zip.METHOD_DEFLATE}) {
		// A stored entry holds the text itself; a deflate one holds the block.
		comp := method == zip.METHOD_STORE ? STORED_HELLO[5:] : STORED_HELLO[:]
		z, ok := zip.zip_open(craft_zip(method, comp, 5), context.temp_allocator)
		if !testing.expect(t, ok) {continue}
		defer zip.zip_close(&z)
		out, rok := zip.zip_read(&z, 0, context.temp_allocator)
		testing.expect(t, rok)
		testing.expect_value(t, string(out), "hello")
	}
}

@(test)
test_zip_repeated_reads_into_an_arena_keep_only_their_output :: proc(t: ^testing.T) {
	exact, eok := zip.zip_open(craft_zip(zip.METHOD_DEFLATE, DEFLATE_A_5000[:], 5000), context.temp_allocator)
	if !testing.expect(t, eok) {return}
	defer zip.zip_close(&exact)
	short, sok := zip.zip_open(craft_zip(zip.METHOD_DEFLATE, DEFLATE_A_5000[:], 4999), context.temp_allocator)
	if !testing.expect(t, sok) {return}
	defer zip.zip_close(&short)

	arena: runtime.Arena
	if !testing.expect(t, runtime.arena_init(&arena, 0, runtime.heap_allocator()) == nil) {return}
	defer runtime.arena_destroy(&arena)
	alloc := runtime.arena_allocator(&arena)

	READS :: 16
	outs: [2 * READS][]u8
	for i in 0 ..< 2 * READS {
		ok, rok: bool
		before: uint
		if i < READS {
			outs[i], ok = zip.zip_read(&exact, 0, alloc)
			before = arena.total_used
			_, rok = zip.zip_read(&short, 0, alloc)
		} else {
			context.allocator = alloc
			outs[i], ok = zip.zip_read(&exact, 0)
			before = arena.total_used
			_, rok = zip.zip_read(&short, 0)
		}
		testing.expect(t, ok)
		testing.expect(t, !rok)
		testing.expectf(t, arena.total_used == before, "refused read %d kept %d bytes", i, arena.total_used - before)
	}
	for out, i in outs {
		testing.expectf(t, len(out) == 5000 && strings.count(string(out), "a") == 5000, "read %d", i)
	}
	testing.expectf(
		t,
		arena.total_used >= 2 * READS * 5000 && arena.total_used <= 2 * READS * (5000 + 64),
		"arena holds %d bytes after %d reads of 5000",
		arena.total_used,
		2 * READS,
	)
}

// A declared size over the cap is refused before anything is allocated, even
// though the stream behind it is tiny.
@(test)
test_zip_refuses_a_declared_size_over_the_cap_without_allocating :: proc(t: ^testing.T) {
	track, scratch_track: mem.Tracking_Allocator
	alloc := tracked(&track)
	scratch := tracked(&scratch_track)
	defer mem.tracking_allocator_destroy(&track)
	defer mem.tracking_allocator_destroy(&scratch_track)

	over := u32(zip.MAX_ENTRY_SIZE + 1)
	_, dok := zip.inflate_entry(STORED_HELLO[:], zip.METHOD_DEFLATE, over, alloc, scratch)
	testing.expect(t, !dok)
	_, sok := zip.inflate_entry(STORED_HELLO[5:], zip.METHOD_STORE, over, alloc, scratch)
	testing.expect(t, !sok)
	_, hok := zip.inflate_entry(STORED_HELLO[:], zip.METHOD_DEFLATE, 0xffff_ffff, alloc, scratch)
	testing.expect(t, !hok)
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, scratch_track.total_allocation_count, 0)
}

// A forged central directory is refused before it is allocated for: a count
// no directory this small could hold, and a directory that runs past the end.
@(test)
test_zip_refuses_a_forged_directory_before_allocating :: proc(t: ^testing.T) {
	good := craft_zip(zip.METHOD_STORE, STORED_HELLO[5:], 5)
	eocd := len(good) - 22
	track: mem.Tracking_Allocator
	alloc := tracked(&track)
	defer mem.tracking_allocator_destroy(&track)

	count := make([]u8, len(good), context.temp_allocator)
	copy(count, good)
	count[eocd + EOCD_COUNT], count[eocd + EOCD_COUNT + 1] = 0xff, 0xff
	_, ok := zip.zip_open(count, alloc)
	testing.expect(t, !ok)

	size := make([]u8, len(good), context.temp_allocator)
	copy(size, good)
	set32(size, eocd + EOCD_SIZE, 0xffff_ffff)
	_, ok = zip.zip_open(size, alloc)
	testing.expect(t, !ok)

	testing.expect_value(t, track.total_allocation_count, 0)

	// The honest archive opens, so the refusals are the forgeries'.
	z, gok := zip.zip_open(good, alloc)
	testing.expect(t, gok)
	zip.zip_close(&z)
}
