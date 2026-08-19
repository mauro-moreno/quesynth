package synth_clap

import "base:runtime"
import "core:os"

import "../../src/clap"
import "../../src/patch"

// State and preset loading. Both are [main-thread] in CLAP, which is what makes
// the file read below legal: the audio thread never opens anything.

// The state blob: a four byte magic, a format version, the parameter count, and
// then one little-endian int32 per parameter.
//
// The count is recorded rather than assumed so that a state written by a build
// with a different parameter table is rejected outright instead of being read
// as a shorter or longer record of the same thing.
//
// The values are the stored .sy1 integers, written verbatim. Some of them are
// deliberately outside their own state table -- parameter 21's reference
// default is 128 in a 128-state table -- and normalising those on the way
// through would quietly change the sound of a restored session.
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

state_decode :: proc "contextless" (
	buffer: [STATE_SIZE]u8,
) -> (
	values: [PARAM_COUNT]i32,
	ok: bool,
) {
	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		if buffer[i] != magic[i] {
			return {}, false
		}
	}
	source := buffer
	if get_u32(source[4:]) != STATE_VERSION {
		return {}, false
	}
	if get_u32(source[8:]) != u32(PARAM_COUNT) {
		return {}, false
	}
	for i in 0 ..< PARAM_COUNT {
		values[i] = i32(get_u32(source[STATE_HEADER_SIZE + i * 4:]))
	}
	return values, true
}

STATE := clap.Plugin_State {
	save = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Ostream) -> bool {
		s := synth_of(plugin)
		if s == nil {
			return false
		}
		// The main thread's authoritative set is whatever it last staged; when
		// nothing is outstanding that is the same array the audio thread holds.
		values := s.values
		if staged_pending(s) {
			values = s.staged
		}
		buffer := state_encode(values)
		return stream_write_all(stream, buffer[:])
	},
	load = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Istream) -> bool {
		s := synth_of(plugin)
		if s == nil {
			return false
		}
		buffer: [STATE_SIZE]u8
		if !stream_read_all(stream, buffer[:]) {
			return false
		}
		values, ok := state_decode(buffer)
		if !ok {
			return false
		}
		stage_values(s, values)
		// The values just moved underneath the host. A blob that was rejected
		// above changed nothing, so it deliberately does not get here.
		notify_host_values(s)
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
