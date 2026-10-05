package vst3_tests

import "base:runtime"
import "core:testing"

import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// The saved state, checked against bytes written out by hand.
//
// Nothing here builds a blob with the plugin's own encoder and reads it back
// with its decoder: two halves of one mistake agree with each other, and that
// is how a layout error survives a whole test suite (see CONTRIBUTING). The
// reference is GOLDEN_STATE, a literal -- the shared "S1OD" format: the magic,
// a little-endian u32 version of 1, a little-endian u32 parameter count of 99,
// then one little-endian i32 per parameter in parameter order, verbatim.
//
// It is the same literal, byte for byte, as GOLDEN_STATE in
// tests/clap/clap_test.odin. The two plugin formats have to write and accept the
// same bytes, and keeping one copy in each suite -- rather than one suite
// importing the other -- is what makes a drift in either of them a failing test.
//
// The values were chosen to be distinctive rather than meaningful: each lies in
// its parameter's stored range, and a few are there for their bytes -- a
// negative one (parameter 9), the out-of-table 128 (parameter 21), and two
// 16-bit controller values.

GOLDEN_STATE := [?]u8 {
	'S', '1', 'O', 'D', // magic
	0x01, 0x00, 0x00, 0x00, // version 1
	0x63, 0x00, 0x00, 0x00, // 99 parameters
	0x03, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x11, 0x00, 0x00, 0x00,  0x18, 0x00, 0x00, 0x00, // 0..3
	0x01, 0x00, 0x00, 0x00,  0x26, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, // 4..7
	0x3B, 0x00, 0x00, 0x00,  0xFD, 0xFF, 0xFF, 0xFF,  0x01, 0x00, 0x00, 0x00,  0x50, 0x00, 0x00, 0x00, // 8..11
	0x57, 0x00, 0x00, 0x00,  0x5E, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x6C, 0x00, 0x00, 0x00, // 12..15
	0x73, 0x00, 0x00, 0x00,  0x7A, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x08, 0x00, 0x00, 0x00, // 16..19
	0x0F, 0x00, 0x00, 0x00,  0x80, 0x00, 0x00, 0x00,  0x1D, 0x00, 0x00, 0x00,  0x24, 0x00, 0x00, 0x00, // 20..23
	0x01, 0x00, 0x00, 0x00,  0x32, 0x00, 0x00, 0x00,  0x39, 0x00, 0x00, 0x00,  0x40, 0x00, 0x00, 0x00, // 24..27
	0x47, 0x00, 0x00, 0x00,  0x4E, 0x00, 0x00, 0x00,  0x55, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, // 28..31
	0x03, 0x00, 0x00, 0x00,  0x6A, 0x00, 0x00, 0x00,  0x71, 0x00, 0x00, 0x00,  0x78, 0x00, 0x00, 0x00, // 32..35
	0x7F, 0x00, 0x00, 0x00,  0x06, 0x00, 0x00, 0x00,  0x02, 0x00, 0x00, 0x00,  0x14, 0x00, 0x00, 0x00, // 36..39
	0x08, 0x00, 0x00, 0x00,  0x02, 0x00, 0x00, 0x00,  0x03, 0x00, 0x00, 0x00,  0x30, 0x00, 0x00, 0x00, // 40..43
	0x37, 0x00, 0x00, 0x00,  0x3E, 0x00, 0x00, 0x00,  0x05, 0x00, 0x00, 0x00,  0x02, 0x00, 0x00, 0x00, // 44..47
	0x53, 0x00, 0x00, 0x00,  0x5A, 0x00, 0x00, 0x00,  0x61, 0x00, 0x00, 0x00,  0x68, 0x00, 0x00, 0x00, // 48..51
	0x6F, 0x00, 0x00, 0x00,  0x76, 0x00, 0x00, 0x00,  0x7D, 0x00, 0x00, 0x00,  0x04, 0x00, 0x00, 0x00, // 52..55
	0x0B, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, // 56..59
	0x27, 0x00, 0x00, 0x00,  0x2E, 0x00, 0x00, 0x00,  0x35, 0x00, 0x00, 0x00,  0x3C, 0x00, 0x00, 0x00, // 60..63
	0x01, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, // 64..67
	0x01, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x02, 0x00, 0x00, 0x00, // 68..71
	0x7B, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x10, 0x00, 0x00, 0x00, // 72..75
	0x17, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x09, 0x00, 0x00, 0x00,  0x2C, 0x00, 0x00, 0x00, // 76..79
	0x33, 0x00, 0x00, 0x00,  0x3A, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x48, 0x00, 0x00, 0x00, // 80..83
	0x4F, 0x00, 0x00, 0x00,  0x56, 0x00, 0x00, 0x00,  0x01, 0xB1, 0x00, 0x00,  0x64, 0x02, 0x00, 0x00, // 84..87
	0x6B, 0x02, 0x00, 0x00,  0xFF, 0xFF, 0x00, 0x00,  0x79, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00, // 88..91
	0x07, 0x00, 0x00, 0x00,  0x06, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,  0x1C, 0x00, 0x00, 0x00, // 92..95
	0x03, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x31, 0x00, 0x00, 0x00, // 96..98
}

// What GOLDEN_STATE says each parameter is, written out the other way round.
GOLDEN_VALUES := [?]i32 {
	3, 0, 17, 24, 1, 38, 1, 0, 59, -3, 1, 80,
	87, 94, 1, 108, 115, 122, 1, 8, 15, 128, 29, 36,
	1, 50, 57, 64, 71, 78, 85, 0, 3, 106, 113, 120,
	127, 6, 2, 20, 8, 2, 3, 48, 55, 62, 5, 2,
	83, 90, 97, 104, 111, 118, 125, 4, 11, 0, 1, 0,
	39, 46, 53, 60, 1, 0, 1, 0, 1, 0, 1, 2,
	123, 0, 1, 16, 23, 0, 9, 44, 51, 58, 1, 72,
	79, 86, 45313, 612, 619, 65535, 121, 0, 7, 6, 1, 28,
	3, 0, 49,
}

// Bytes of the header: magic, version, count.
HEADER :: 12

// -- an in-memory IBStream ---------------------------------------------------
//
// A host's stream is allowed to move a few bytes at a time, and the plugin has
// to loop; `chunk` is how many it will move per call.

Memory_Stream :: struct {
	// First, because an `IBStream*` is the address of the vtable pointer: the
	// stream the plugin is handed is the address of this struct.
	vtbl:  ^vst3.IBStream_Vtbl,
	data:  [dynamic]u8,
	pos:   int,
	chunk: int,
	// What the callbacks allocate with. A host stream is not Odin code and has
	// no context of its own, and the test runner gives every test an allocator
	// that checks it for leaks, so it is the test's own that is kept.
	ctx:   runtime.Context,
}

MEMORY_STREAM_VTBL := vst3.IBStream_Vtbl {
	read = proc "c" (this: rawptr, buffer: rawptr, num_bytes: i32, num_read: ^i32) -> vst3.Result {
		m := (^Memory_Stream)(this)
		n := min(min(int(num_bytes), m.chunk), len(m.data) - m.pos)
		copy(([^]u8)(buffer)[:n], m.data[m.pos:][:n])
		m.pos += n
		num_read^ = i32(n)
		return vst3.RESULT_OK
	},
	write = proc "c" (this: rawptr, buffer: rawptr, num_bytes: i32, num_written: ^i32) -> vst3.Result {
		m := (^Memory_Stream)(this)
		context = m.ctx
		n := min(int(num_bytes), m.chunk)
		append(&m.data, ..([^]u8)(buffer)[:n])
		num_written^ = i32(n)
		return vst3.RESULT_OK
	},
}

memory_stream_init :: proc(m: ^Memory_Stream, chunk: int, bytes: ..[]u8) {
	m.vtbl = &MEMORY_STREAM_VTBL
	m.chunk = chunk
	m.pos = 0
	m.ctx = context
	m.data = make([dynamic]u8)
	for b in bytes {
		append(&m.data, ..b)
	}
}

memory_stream_destroy :: proc(m: ^Memory_Stream) {
	delete(m.data)
}

stream_of :: proc(m: ^Memory_Stream) -> ^vst3.IBStream {
	return (^vst3.IBStream)(m)
}

// -- helpers ------------------------------------------------------------------

default_of :: proc(i: int) -> i32 {
	return i32(patch.PARAMETERS[i].default)
}

// Put every parameter on something that is not its default, so that a load
// that leaves a parameter alone cannot be mistaken for one that set it to the
// default.
move_off_defaults :: proc(p: ^synth.Plugin) {
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = default_of(i) + 1
	}
}

expect_values_are_the_defaults_from :: proc(t: ^testing.T, p: ^synth.Plugin, from: int) {
	for i in from ..< patch.PARAMETER_COUNT {
		testing.expectf(t, p.values[i] == default_of(i), "parameter %d is %d, not its default %d", i, p.values[i], default_of(i))
	}
}

// -- the golden blob ---------------------------------------------------------

@(test)
save_state_writes_the_shared_golden_blob :: proc(t: ^testing.T) {
	// The golden values are written for this many parameters. If the table
	// grows the format has not changed but the blob has: write a new golden
	// deliberately rather than letting this one drift.
	testing.expect_value(t, patch.PARAMETER_COUNT, len(GOLDEN_VALUES))

	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)

	for i in 0 ..< len(GOLDEN_VALUES) {
		p.values[i] = GOLDEN_VALUES[i]
	}

	out: Memory_Stream
	memory_stream_init(&out, 7)
	defer memory_stream_destroy(&out)
	testing.expect_value(t, synth.component_get_state(rawptr(p), stream_of(&out)), vst3.RESULT_OK)

	testing.expect_value(t, len(out.data), len(GOLDEN_STATE))
	for i in 0 ..< min(len(out.data), len(GOLDEN_STATE)) {
		testing.expectf(t, out.data[i] == GOLDEN_STATE[i], "byte %d is 0x%02X, the golden says 0x%02X", i, out.data[i], GOLDEN_STATE[i])
	}
}

@(test)
load_state_reads_the_shared_golden_blob :: proc(t: ^testing.T) {
	p := synth.make_plugin()
	if p == nil {return}
	defer synth.release(p)
	move_off_defaults(p)

	in_: Memory_Stream
	memory_stream_init(&in_, 5, GOLDEN_STATE[:])
	defer memory_stream_destroy(&in_)
	testing.expect_value(t, synth.component_set_state(rawptr(p), stream_of(&in_)), vst3.RESULT_OK)

	for i in 0 ..< len(GOLDEN_VALUES) {
		testing.expectf(t, p.values[i] == GOLDEN_VALUES[i], "parameter %d loaded as %d, the golden says %d", i, p.values[i], GOLDEN_VALUES[i])
	}
}

// -- a blob from a build with a different parameter table --------------------

// Fewer parameters than this build has: the ones the two share are loaded, and
// every other parameter is its reference default -- not what the instance held
// beforehand.
@(test)
a_blob_with_fewer_parameters_loads_the_shared_ones_and_defaults_the_rest :: proc(t: ^testing.T) {
	SHARED :: 10

	// Ten parameters declared and exactly ten present, and ten declared with
	// the whole golden set following: the count, not how much follows, says how
	// much of it is the state.
	for with_trailing_values in ([]bool{false, true}) {
		p := synth.make_plugin()
		if p == nil {return}
		defer synth.release(p)
		move_off_defaults(p)

		blob := make([dynamic]u8)
		defer delete(blob)
		append(&blob, ..GOLDEN_STATE[:])
		blob[8] = SHARED
		if !with_trailing_values {
			resize(&blob, HEADER + SHARED * 4)
		}

		in_: Memory_Stream
		memory_stream_init(&in_, 64, blob[:])
		defer memory_stream_destroy(&in_)
		testing.expect_value(t, synth.component_set_state(rawptr(p), stream_of(&in_)), vst3.RESULT_OK)

		for i in 0 ..< SHARED {
			testing.expectf(t, p.values[i] == GOLDEN_VALUES[i], "shared parameter %d loaded as %d, the blob says %d", i, p.values[i], GOLDEN_VALUES[i])
		}
		expect_values_are_the_defaults_from(t, p, SHARED)
	}
}

// More parameters than this build has: the first PARAM_COUNT are loaded and the
// rest are ignored. The declared count is never trusted for how much to read.
@(test)
a_blob_with_more_parameters_loads_the_first_ones_and_ignores_the_rest :: proc(t: ^testing.T) {
	for declared in ([]u32{u32(patch.PARAMETER_COUNT) + 3, 0xFFFF_FFFF}) {
		p := synth.make_plugin()
		if p == nil {return}
		defer synth.release(p)
		move_off_defaults(p)

		blob := make([dynamic]u8)
		defer delete(blob)
		append(&blob, ..GOLDEN_STATE[:])
		blob[8] = u8(declared)
		blob[9] = u8(declared >> 8)
		blob[10] = u8(declared >> 16)
		blob[11] = u8(declared >> 24)
		// Three more parameters than this build has, which are what is ignored.
		// For the absurd count they are all there is, and nothing like that
		// many bytes follow: reading what the count claims would run off the end.
		append(&blob, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0)

		in_: Memory_Stream
		memory_stream_init(&in_, 64, blob[:])
		defer memory_stream_destroy(&in_)
		testing.expect_value(t, synth.component_set_state(rawptr(p), stream_of(&in_)), vst3.RESULT_OK)

		for i in 0 ..< len(GOLDEN_VALUES) {
			testing.expectf(t, p.values[i] == GOLDEN_VALUES[i], "parameter %d loaded as %d, the blob says %d (declared %d)", i, p.values[i], GOLDEN_VALUES[i], declared)
		}
	}
}

// -- what is refused, and what that leaves behind ----------------------------

@(test)
a_foreign_or_truncated_blob_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	wrong_magic := make([dynamic]u8)
	defer delete(wrong_magic)
	append(&wrong_magic, ..GOLDEN_STATE[:])
	wrong_magic[0] = 'X'

	other_version := make([dynamic]u8)
	defer delete(other_version)
	append(&other_version, ..GOLDEN_STATE[:])
	other_version[4] = 2

	// Every length short of the header, then the shared values cut one byte
	// short, a whole parameter short, and short of what a smaller count claims.
	short_of_the_header := GOLDEN_STATE[:HEADER - 1]
	no_values := GOLDEN_STATE[:HEADER]
	one_byte_short := GOLDEN_STATE[:len(GOLDEN_STATE) - 1]
	one_value_short := GOLDEN_STATE[:len(GOLDEN_STATE) - 4]
	nine_of_ten := make([dynamic]u8)
	defer delete(nine_of_ten)
	append(&nine_of_ten, ..GOLDEN_STATE[:HEADER + 9 * 4])
	nine_of_ten[8] = 10

	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"foreign magic", wrong_magic[:]},
		{"version 2", other_version[:]},
		{"an empty stream", nil},
		{"a header cut short", short_of_the_header},
		{"a header and nothing after it", no_values},
		{"the last value one byte short", one_byte_short},
		{"the last value missing", one_value_short},
		{"ten values declared and nine present", nine_of_ten[:]},
	}
	for c in cases {
		p := synth.make_plugin()
		if p == nil {return}
		defer synth.release(p)

		in_: Memory_Stream
		memory_stream_init(&in_, 64, c.bytes)
		defer memory_stream_destroy(&in_)

		testing.expectf(t, synth.component_set_state(rawptr(p), stream_of(&in_)) != vst3.RESULT_OK, "%s was accepted", c.name)
		// A fresh instrument is on its defaults, so anything the refused blob
		// had been allowed to set would show.
		for i in 0 ..< patch.PARAMETER_COUNT {
			testing.expectf(t, p.values[i] == default_of(i), "%s changed parameter %d to %d", c.name, i, p.values[i])
		}
	}
}
