package control

// Framing. A socket is a byte stream, so each message is prefixed with its
// length: [len:u32 little-endian][payload]. Length-prefixing is used rather than
// a delimiter because a payload may contain any byte -- a record line, an
// embedded newline -- and a length needs no escaping rule to stay unambiguous.
//
// One read() may return part of a frame or several frames at once, so a reader
// cannot assume one read is one message. Frame_Reader accumulates bytes and
// yields whole payloads as they complete; the codec here knows nothing about
// what a payload means, which is what lets the same framing carry a later
// transport's traffic unchanged.

FRAME_HEADER_SIZE :: 4

// A control message is tiny. This cap turns a corrupt or hostile length into a
// rejected frame rather than a huge allocation.
MAX_FRAME_PAYLOAD :: 64 * 1024

// Prefix a payload with its little-endian length. The caller owns the result.
frame_encode :: proc(payload: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, FRAME_HEADER_SIZE + len(payload), allocator)
	n := u32(len(payload))
	out[0] = u8(n)
	out[1] = u8(n >> 8)
	out[2] = u8(n >> 16)
	out[3] = u8(n >> 24)
	copy(out[FRAME_HEADER_SIZE:], payload)
	return out
}

Frame_Reader :: struct {
	buf: [dynamic]u8,
}

frame_reader_push :: proc(r: ^Frame_Reader, bytes: []u8) {
	append(&r.buf, ..bytes)
}

// Yield the next complete payload, or ok=false when more bytes are needed. err
// is true when a frame declares a payload larger than MAX_FRAME_PAYLOAD, which
// the caller should treat as a protocol fault and close the connection. The
// returned payload is freshly allocated and owned by the caller.
frame_reader_next :: proc(r: ^Frame_Reader) -> (payload: []u8, ok: bool, err: bool) {
	if len(r.buf) < FRAME_HEADER_SIZE {
		return nil, false, false
	}
	n :=
		int(r.buf[0]) |
		(int(r.buf[1]) << 8) |
		(int(r.buf[2]) << 16) |
		(int(r.buf[3]) << 24)
	if n < 0 || n > MAX_FRAME_PAYLOAD {
		return nil, false, true
	}
	if len(r.buf) < FRAME_HEADER_SIZE + n {
		return nil, false, false
	}

	payload = make([]u8, n)
	copy(payload, r.buf[FRAME_HEADER_SIZE:][:n])

	// Drop the consumed header and payload from the front of the buffer.
	remaining := len(r.buf) - (FRAME_HEADER_SIZE + n)
	if remaining > 0 {
		copy(r.buf[:], r.buf[FRAME_HEADER_SIZE + n:])
	}
	resize(&r.buf, remaining)
	return payload, true, false
}

frame_reader_destroy :: proc(r: ^Frame_Reader) {
	delete(r.buf)
}
