package zip_tests

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
