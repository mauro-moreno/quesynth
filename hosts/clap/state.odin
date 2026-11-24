package synth_clap

import "base:runtime"
import "core:os"

import "../../src/clap"
import "../../src/patch"
import "../panel"

// State and preset loading. Both are [main-thread] in CLAP, which is what makes
// the file read below legal: the audio thread never opens anything.

// The state blob: a four byte magic, a format version, the parameter count, and
// then one little-endian int32 per parameter.
//
// The count is recorded so that a blob outlives the parameter table it was
// written against, instead of being refused when the table changes. A state
// from a build with fewer parameters carries the ones the two share and the
// rest take their reference defaults; one from a build with more is read as far
// as this build goes and the surplus ignored. Refusing either would throw away
// a whole saved patch because a knob was added or removed. Defaults rather than
// whatever the instance held, so what a load produces never depends on what was
// loaded before it. hosts/vst3/state.odin writes this layout as its version 2;
// its version 1, from before it had a count, is not this layout.
//
// The values are the stored .sy1 integers, written verbatim. Some of them are
// deliberately outside their own state table -- parameter 21's reference
// default is 128 in a 128-state table -- and normalising those on the way
// through would quietly change the sound of a restored session.
//
// After the values, when the instance knows which preset it is on, there is a
// trailer saying so: hosts/panel/trailer.odin. The version above is not
// bumped for it. Every build that has ever read this blob stops at the last
// value, so a project saved now still loads in one of those and an older
// project loads here as a state with no trailer; a new version number would
// have made the first of those a refusal. STATE_SIZE is the size of the
// values, not of the whole blob.
STATE_MAGIC :: [4]u8{'S', '1', 'O', 'D'}
STATE_VERSION :: u32(1)
STATE_HEADER_SIZE :: 12
STATE_SIZE :: STATE_HEADER_SIZE + PARAM_COUNT * 4

put_u32 :: proc "contextless" (dst: []u8, value: u32) {
	dst[0] = u8(value)
	dst[1] = u8(value >> 8)
	dst[2] = u8(value >> 16)
	dst[3] = u8(value >> 24)
}

get_u32 :: proc "contextless" (src: []u8) -> u32 {
	return u32(src[0]) | (u32(src[1]) << 8) | (u32(src[2]) << 16) | (u32(src[3]) << 24)
}

// A host may satisfy a write with fewer bytes than asked for, so the loop is
// mandatory. A return of 0 means no progress was made; continuing would spin
// forever, so it is treated as a failure rather than retried.
stream_write_all :: proc "contextless" (stream: ^clap.Ostream, data: []u8) -> bool {
	if stream == nil || stream.write == nil {
		return false
	}
	written := 0
	for written < len(data) {
		n := stream.write(stream, raw_data(data[written:]), u64(len(data) - written))
		if n <= 0 {
			return false
		}
		written += int(n)
	}
	return true
}

// 0 from a read is end of file. A state record that ends early is truncated, not
// acceptable, so this reports failure rather than leaving the tail at zero.
stream_read_all :: proc "contextless" (stream: ^clap.Istream, data: []u8) -> bool {
	if stream == nil || stream.read == nil {
		return false
	}
	read := 0
	for read < len(data) {
		n := stream.read(stream, raw_data(data[read:]), u64(len(data) - read))
		if n <= 0 {
			return false
		}
		read += int(n)
	}
	return true
}

state_encode :: proc "contextless" (values: [PARAM_COUNT]i32) -> [STATE_SIZE]u8 {
	buffer: [STATE_SIZE]u8
	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		buffer[i] = magic[i]
	}
	put_u32(buffer[4:], STATE_VERSION)
	put_u32(buffer[8:], u32(PARAM_COUNT))
	for i in 0 ..< PARAM_COUNT {
		put_u32(buffer[STATE_HEADER_SIZE + i * 4:], u32(values[i]))
	}
	return buffer
}

// Read a state blob's values into a set of their own, without touching the
// instrument.
//
// A foreign magic, another version, or a stream that ends before the header or
// before the shared values is refused. Nothing else is: no trailing data is
// required, and the declared count is only ever an upper bound on how much is
// read -- never a size to allocate or to trust. `surplus` is how many values
// the blob has past the ones this build reads, for whatever follows them to be
// found.
state_read :: proc "contextless" (stream: ^clap.Istream) -> (values: [PARAM_COUNT]i32, surplus: int, ok: bool) {
	header: [STATE_HEADER_SIZE]u8
	if !stream_read_all(stream, header[:]) {
		return {}, 0, false
	}
	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		if header[i] != magic[i] {
			return {}, 0, false
		}
	}
	if get_u32(header[4:]) != STATE_VERSION {
		return {}, 0, false
	}

	declared := get_u32(header[8:])
	shared := int(min(declared, u32(PARAM_COUNT)))
	body: [PARAM_COUNT * 4]u8
	if !stream_read_all(stream, body[:shared * 4]) {
		return {}, 0, false
	}
	for i in 0 ..< PARAM_COUNT {
		if i < shared {
			values[i] = i32(get_u32(body[i * 4:]))
		} else {
			values[i] = i32(patch.PARAMETERS[i].default)
		}
	}
	return values, int(declared) - shared if declared > u32(PARAM_COUNT) else 0, true
}

// Whatever follows the values, as far as a trailer can be: skips the values a
// bigger build wrote, then reads at most the most a trailer can be.
//
// Read in chunks and never at a size the stream declares. A stream that ends
// early, or fails, simply ends the tail there, and what is read is for the
// trailer's own decoder to call truncated: this is the one part of loading a
// state that must never be the reason for refusing it.
state_read_tail :: proc(stream: ^clap.Istream, surplus_values: int) -> [dynamic]u8 {
	tail: [dynamic]u8
	if stream == nil || stream.read == nil {
		return tail
	}
	chunk: [4096]u8

	// The count may be absurd, and the stream is what bounds this.
	skip := u64(surplus_values) * 4
	for skip > 0 {
		n := stream.read(stream, raw_data(chunk[:]), min(skip, u64(len(chunk))))
		if n <= 0 {
			return tail
		}
		skip -= min(u64(n), skip)
	}

	for len(tail) < panel.TRAILER_READ_MAX {
		want := min(len(chunk), panel.TRAILER_READ_MAX - len(tail))
		n := stream.read(stream, raw_data(chunk[:]), u64(want))
		if n <= 0 {
			break
		}
		append(&tail, ..chunk[:min(int(n), want)])
	}
	return tail
}

STATE := clap.Plugin_State {
	save = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Ostream) -> bool {
		s := synth_of(plugin)
		if s == nil {
			return false
		}
		context = runtime.default_context()
		// The main thread's authoritative set is whatever it last staged; when
		// nothing is outstanding that is the same array the audio thread holds.
		values := s.values
		if staged_pending(s) {
			values = s.staged
		}
		buffer := state_encode(values)
		if !stream_write_all(stream, buffer[:]) {
			return false
		}
		// Which preset these values are, when the instance knows. Nothing when
		// it does not, so a state that never had one is the bytes it always was.
		trailer := panel.session_trailer(&s.session, &s.slots)
		defer delete(trailer)
		return trailer == nil || stream_write_all(stream, trailer)
	},
	load = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Istream) -> bool {
		s := synth_of(plugin)
		if s == nil {
			return false
		}
		context = runtime.default_context()
		values, surplus, ok := state_read(stream)
		if !ok {
			return false
		}
		// Read before anything is changed, so that nothing about the trailer
		// can be a reason to leave the values behind.
		tail := state_read_tail(stream, surplus)
		defer delete(tail)

		stage_values(s, values)
		// The values just moved underneath the host. A blob that was rejected
		// above changed nothing, so it deliberately does not get here.
		notify_host_values(s)

		// Then which preset they are. The sound is already in; this only says
		// where it came from, and if it cannot, says so and leaves the bank,
		// the program and the sound as they are -- never the factory bank in
		// the place of the one the project had.
		result := panel.session_restore(&s.session, &s.slots, tail[:])
		if result.has_program {
			s.program = result.program
		}
		// An editor that is open is showing the instance from before.
		if s.editor.open {
			panel.send_sync(&s.editor)
		}
		return true
	},
}

// -- preset load -------------------------------------------------------------

// The plugin's offered way to load a .sy1 file into its parameters.
//
// CLAP already has the shape of this: the host names a file and the plugin
// reads it, on the main thread. Doing it here rather than making the host parse
// the patch means the .sy1 encoding stays in one place -- src/patch -- and any
// CLAP host, not just the one in tools/claphost, can point this synthesiser at
// a Synth1 patch.
PRESET_LOAD := clap.Plugin_Preset_Load {
	from_location = proc "c" (
		plugin: ^clap.Plugin,
		location_kind: u32,
		location: cstring,
		load_key: cstring,
	) -> bool {
		context = runtime.default_context()
		s := synth_of(plugin)
		if s == nil {
			return false
		}
		// A .sy1 patch is one file holding one patch: there is no container to
		// index into, so a load key would have no meaning.
		if location_kind != clap.PRESET_DISCOVERY_LOCATION_FILE {
			return false
		}
		if location == nil {
			return false
		}
		if load_key != nil && len(string(load_key)) > 0 {
			return false
		}
		return load_sy1_file(s, string(location))
	},
}

// Read and stage a .sy1 file. [main-thread]
load_sy1_file :: proc(s: ^Synth, path: string) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(data)

	parsed, parse_err := patch.parse_sy1(data)
	if parse_err != .None {
		return false
	}

	// parse_sy1 pre-fills every index with the reference default, so a patch
	// that omits a parameter -- every ver=105 file does -- lands on the same
	// value the reference plugin would use rather than on zero.
	values: [PARAM_COUNT]i32
	for i in 0 ..< PARAM_COUNT {
		values[i] = i32(parsed.values[i])
	}
	stage_values(s, values)
	// Same reason as in state load: the host's picture of the parameters is now
	// stale, and only a rescan request tells it so.
	notify_host_values(s)
	return true
}
