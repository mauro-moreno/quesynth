package synth_vst3

import "../../src/vst3"

// Saving and restoring the parameter set through the host's stream.
//
// The format is deliberately the same as hosts/clap/state.odin's: a magic,
// a version, then the stored integers in parameter order, little-endian. Two
// plugin formats wrapping one engine should not disagree about what a saved
// patch is, and keeping the bytes identical means a session saved in one host
// could in principle be read by the other.

STATE_MAGIC :: [4]u8{'S', '1', 'O', 'D'}
STATE_VERSION :: u32(1)
STATE_SIZE :: 4 + 4 + PARAM_COUNT * 4

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
	for i in 0 ..< PARAM_COUNT {
		put_u32(buffer[8 + i * 4:], u32(p.values[i]))
	}
	return vst3.RESULT_OK if stream_write_all(stream, buffer[:]) else vst3.RESULT_FALSE
}

load_state :: proc(p: ^Plugin, stream: ^vst3.IBStream) -> vst3.Result {
	buffer: [STATE_SIZE]u8
	if !stream_read_all(stream, buffer[:]) {
		return vst3.RESULT_FALSE
	}

	magic := STATE_MAGIC
	for i in 0 ..< 4 {
		if buffer[i] != magic[i] {
			return vst3.RESULT_FALSE
		}
	}
	if get_u32(buffer[4:]) != STATE_VERSION {
		return vst3.RESULT_FALSE
	}

	// Written into the live set only after the whole buffer has been validated,
	// so a truncated or foreign stream leaves the instrument as it was rather
	// than half-loaded.
	for i in 0 ..< PARAM_COUNT {
		p.values[i] = i32(get_u32(buffer[8 + i * 4:]))
	}
	p.params_dirty = true
	if p.active {
		apply_params(p)
	}
	// A session being loaded under an open editor. The panel asks for the whole
	// set when it starts, which covers the ordinary case of opening the window
	// afterwards, but nothing would tell it about this.
	editor_send_state(p.editor)
	return vst3.RESULT_OK
}
