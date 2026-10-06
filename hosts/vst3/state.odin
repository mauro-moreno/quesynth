package synth_vst3

import "../../src/patch"
import "../../src/vst3"

// Saving and restoring the parameter set through the host's stream.
//
// Version 2, the one written: a magic, the version, the parameter count, then
// one little-endian integer per parameter in parameter order.
//
// The count is what lets a blob outlive the parameter table it was written
// against. A state from a build with fewer parameters carries the ones the two
// share and the rest take their reference defaults; one from a build with more
// is read as far as this build goes and the surplus ignored. Refusing either
// would throw away a whole saved patch because a knob was added or removed.
// Defaults rather than whatever the instance held, so what a load produces
// never depends on what was loaded before it.
//
// Version 1 is what every build before the count wrote -- the magic, the
// version, and the values straight after it -- and it is still read, so a
// session saved by one of those builds loads as it was saved. Adding the count
// under the same version number read that session's first value as a count
// and every value after it one place out.
//
// hosts/clap/state.odin writes the counted layout under its own version 1: the
// CLAP blob had its count from the start, and each format numbers its own
// versions.
//
// The values are the stored .sy1 integers, written verbatim -- see
// hosts/clap/state.odin for why they are not normalised on the way through.

STATE_MAGIC :: [4]u8{'S', '1', 'O', 'D'}
STATE_VERSION :: u32(2)
STATE_VERSION_UNCOUNTED :: u32(1)
STATE_HEADER_SIZE :: 12
STATE_UNCOUNTED_HEADER_SIZE :: 8
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

// A stream is allowed to satisfy a request partially, so both directions loop
// until the whole buffer has moved or the stream stops making progress. A
// short read that is treated as success is a corrupt patch that loads quietly.
stream_write_all :: proc "contextless" (stream: ^vst3.IBStream, data: []u8) -> bool {
	if stream == nil {
		return false
	}
	offset := 0
	for offset < len(data) {
		written: i32
		remaining := i32(len(data) - offset)
		if stream.vtbl.write(stream, rawptr(&data[offset]), remaining, &written) != vst3.RESULT_OK {
			return false
		}
		if written <= 0 {
			return false
		}
		offset += int(written)
	}
	return true
}

stream_read_all :: proc "contextless" (stream: ^vst3.IBStream, data: []u8) -> bool {
	if stream == nil {
		return false
	}
	offset := 0
	for offset < len(data) {
		read: i32
		remaining := i32(len(data) - offset)
		if stream.vtbl.read(stream, rawptr(&data[offset]), remaining, &read) != vst3.RESULT_OK {
			return false
		}
		if read <= 0 {
			return false
		}
		offset += int(read)
	}
	return true
}

save_state :: proc(p: ^Plugin, stream: ^vst3.IBStream) -> vst3.Result {
	buffer: [STATE_SIZE]u8
	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		buffer[i] = magic[i]
	}
	put_u32(buffer[4:], STATE_VERSION)
	put_u32(buffer[8:], u32(PARAM_COUNT))
	for i in 0 ..< PARAM_COUNT {
		// The main thread's picture: a value staged a moment ago and not yet
		// adopted by the audio thread is what the host should be handed, not
		// the one it replaces.
		put_u32(buffer[STATE_HEADER_SIZE + i * 4:], u32(main_thread_value(p, i)))
	}
	return vst3.RESULT_OK if stream_write_all(stream, buffer[:]) else vst3.RESULT_FALSE
}

// Read a state blob into a set of its own, without touching the instrument.
//
// A foreign magic, a version other than 1 or 2, or a stream that ends before
// the header or before the shared values is refused. Nothing else is: no
// trailing data is required, and the declared count is only ever an upper
// bound on how much is read -- never a size to allocate or to trust. Version 1
// declares nothing, and every one of its values is a shared one.
state_read :: proc "contextless" (stream: ^vst3.IBStream) -> (values: [PARAM_COUNT]i32, ok: bool) {
	header: [STATE_HEADER_SIZE]u8
	if !stream_read_all(stream, header[:STATE_UNCOUNTED_HEADER_SIZE]) {
		return {}, false
	}
	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		if header[i] != magic[i] {
			return {}, false
		}
	}

	shared: int
	switch get_u32(header[4:]) {
	case STATE_VERSION:
		if !stream_read_all(stream, header[STATE_UNCOUNTED_HEADER_SIZE:]) {
			return {}, false
		}
		shared = int(min(get_u32(header[8:]), u32(PARAM_COUNT)))
	case STATE_VERSION_UNCOUNTED:
		shared = PARAM_COUNT
	case:
		return {}, false
	}

	body: [PARAM_COUNT * 4]u8
	if !stream_read_all(stream, body[:shared * 4]) {
		return {}, false
	}
	for i in 0 ..< PARAM_COUNT {
		if i < shared {
			values[i] = i32(get_u32(body[i * 4:]))
		} else {
			values[i] = i32(patch.PARAMETERS[i].default)
		}
	}
	return values, true
}

load_state :: proc(p: ^Plugin, stream: ^vst3.IBStream) -> vst3.Result {
	// Read in full before anything is staged, so a truncated or foreign stream
	// leaves the instrument as it was rather than half-loaded.
	values, ok := state_read(stream)
	if !ok {
		return vst3.RESULT_FALSE
	}
	// Handed to the audio thread, not written under it; and not applied from
	// here either. The main thread's picture is the new set from this call on.
	stage_values(p, values[:])
	// A session being loaded under an open editor. The panel asks for the whole
	// set when it starts, which covers the ordinary case of opening the window
	// afterwards, but nothing would tell it about this.
	editor_send_state(p.editor)
	return vst3.RESULT_OK
}
