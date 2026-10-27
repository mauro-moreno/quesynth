package panel

import "core:unicode/utf8"

// What a plugin's saved state says about which preset it was playing.
//
// Every format already saves the sound: the ninety-nine stored integers. What
// no format saved was *where the sound came from*, so a new instance -- the
// editor reopened, REAPER's offline then online, a project reloaded -- came
// back playing the right values with the program number and the bank it had
// at start, which is slot 0 of Factory or of the saved user bank. Issue #13 is
// that, seen from the interface.
//
// The identity is a trailer after the values, one layout for VST3, CLAP and
// the Audio Unit, and this file is the only copy of it. A trailer rather than
// a new version of any blob: every build that wrote or reads these blobs stops
// at the last value, so a project saved now still loads in an older build and
// an older project still loads here, as a state with no trailer.
//
//   "QSEL"(4) | trailer version u32 LE | payload length u32 LE | payload
//
//   payload, version 1:
//     origin u8     0 none, 1 factory, 2 user, 3 imported, 4 archive, 5 file,
//                   6 session
//     flags u8      bit 0 slot present, bit 1 bank embedded, bit 2 bank saved
//     slot u16 LE   ignored without bit 0
//     label_len u8, label     the bank's name
//     name_len u8, name       the patch's name
//     [bank_len u32 LE, bank] a quesynth.bank document, only with bit 1
//
// Nothing in a state blob is to be trusted, and this is the one part of it
// that carries lengths. The payload length is capped, every read is bounds
// checked against the bytes that are actually there, and nothing is ever
// allocated at a size the blob declares.

TRAILER_TAG :: [4]u8{'Q', 'S', 'E', 'L'}
TRAILER_VERSION :: u32(1)
TRAILER_HEADER_SIZE :: 12

// A bank is a few hundred kilobytes at most; four megabytes is not a bank
// anybody saved, it is a stream that is not what it says it is.
TRAILER_PAYLOAD_MAX :: 4 * 1024 * 1024

// The most a reader ever needs of the bytes after the values.
TRAILER_READ_MAX :: TRAILER_HEADER_SIZE + TRAILER_PAYLOAD_MAX

Trailer_Flag :: enum u8 {
	Slot       = 0,
	Embedded   = 1,
	Bank_Saved = 2,
}

Trailer_Flags :: bit_set[Trailer_Flag;u8]

Trailer :: struct {
	origin:     Origin,
	has_slot:   bool,
	slot:       int,
	label:      Text,
	name:       Text,
	embedded:   bool,
	// The playing bank was the saved user bank. Only identity is written then;
	// the flag is kept so a failed restore writes back what it was given.
	bank_saved: bool,
	// A slice of the bytes that were decoded, never a copy: valid while they
	// are. Empty unless `embedded`.
	bank_json:  []u8,
}

// Why a decode did not produce a trailer, told apart because each means
// something different to the person looking at a failed restore.
Trailer_Status :: enum u8 {
	// Nothing after the values, or something that is not ours: older builds
	// and older projects, which load exactly as they always did.
	Absent,
	Ok,
	// Ours, written by a build that knows more than this one.
	Unknown_Version,
	// Ours, and the bytes stop before the layout says they should.
	Truncated,
	// Ours, and it claims more than the cap allows.
	Oversize,
	// Ours and complete, and what it says is not something this build can
	// have written.
	Malformed,
}

@(private)
put_u16 :: proc(dst: []u8, value: u16) {
	dst[0] = u8(value)
	dst[1] = u8(value >> 8)
}

@(private)
put_u32 :: proc(dst: []u8, value: u32) {
	dst[0] = u8(value)
	dst[1] = u8(value >> 8)
	dst[2] = u8(value >> 16)
	dst[3] = u8(value >> 24)
}

@(private)
get_u16 :: proc(src: []u8) -> u16 {
	return u16(src[0]) | (u16(src[1]) << 8)
}

@(private)
get_u32 :: proc(src: []u8) -> u32 {
	return u32(src[0]) | (u32(src[1]) << 8) | (u32(src[2]) << 16) | (u32(src[3]) << 24)
}

// Read the trailer out of whatever followed the parameter values.
//
// Tolerant on purpose: a blob from before the trailer existed has nothing
// here, and one from a build with a different parameter table can have values
// here that this build does not read. Neither is an error, and both come back
// as Absent. Only bytes that start with the tag are held to the layout.
trailer_decode :: proc(bytes: []u8) -> (t: Trailer, status: Trailer_Status) {
	tag := TRAILER_TAG
	if len(bytes) < len(tag) {
		return {}, .Absent
	}
	for i in 0 ..< len(tag) {
		if bytes[i] != tag[i] {
			return {}, .Absent
		}
	}
	if len(bytes) < TRAILER_HEADER_SIZE {
		return {}, .Truncated
	}

	// Before the length is looked at: a version this build does not know may
	// mean something else by it.
	if get_u32(bytes[4:]) != TRAILER_VERSION {
		return {}, .Unknown_Version
	}
	length := get_u32(bytes[8:])
	if length > TRAILER_PAYLOAD_MAX {
		return {}, .Oversize
	}
	if len(bytes) - TRAILER_HEADER_SIZE < int(length) {
		return {}, .Truncated
	}

	// Bytes after the declared payload are ignored, for a later version that
	// appends something; what is inside it is held to the layout.
	payload := bytes[TRAILER_HEADER_SIZE:][:length]
	if len(payload) < 4 {
		return {}, .Truncated
	}

	if payload[0] > u8(max(Origin)) {
		return {}, .Malformed
	}
	t.origin = Origin(payload[0])
	// Bits this build does not know are ignored, not refused: the version is
	// what says the layout changed.
	flags := transmute(Trailer_Flags)(payload[1] & 0b111)
	t.has_slot = .Slot in flags
	t.embedded = .Embedded in flags
	t.bank_saved = .Bank_Saved in flags
	if t.has_slot {
		t.slot = int(get_u16(payload[2:]))
	}

	at := 4
	label, ok := read_short_text(payload, &at)
	if !ok {
		return {}, .Truncated
	}
	name: string
	name, ok = read_short_text(payload, &at)
	if !ok {
		return {}, .Truncated
	}
	// Names go into a JSON message and out to a web page, which has no use for
	// bytes that are not text.
	if !utf8.valid_string(label) || !utf8.valid_string(name) {
		return {}, .Malformed
	}
	text_set(&t.label, label)
	text_set(&t.name, name)

	if t.embedded {
		if len(payload) - at < 4 {
			return {}, .Truncated
		}
		size := get_u32(payload[at:])
		at += 4
		if int(size) > len(payload) - at {
			return {}, .Truncated
		}
		t.bank_json = payload[at:][:size]
	}
	return t, .Ok
}

@(private)
read_short_text :: proc(payload: []u8, at: ^int) -> (text: string, ok: bool) {
	if at^ >= len(payload) {
		return "", false
	}
	size := int(payload[at^])
	if size > len(payload) - at^ - 1 {
		return "", false
	}
	text = string(payload[at^ + 1:][:size])
	at^ += 1 + size
	return text, true
}

// The trailer as bytes, or nil when there is nothing to say.
//
// A bank too large for the cap is left out rather than written: a reader would
// refuse the whole trailer, and the identity is worth more than the bank.
trailer_encode :: proc(t: ^Trailer, allocator := context.allocator) -> []u8 {
	label := text_get(&t.label)
	name := text_get(&t.name)

	fixed := 4 + 1 + len(label) + 1 + len(name)
	embedded := t.embedded && fixed + 4 + len(t.bank_json) <= TRAILER_PAYLOAD_MAX
	size := fixed
	if embedded {
		size += 4 + len(t.bank_json)
	}

	out := make([]u8, TRAILER_HEADER_SIZE + size, allocator)
	tag := TRAILER_TAG
	for i in 0 ..< len(tag) {
		out[i] = tag[i]
	}
	put_u32(out[4:], TRAILER_VERSION)
	put_u32(out[8:], u32(size))

	payload := out[TRAILER_HEADER_SIZE:]
	payload[0] = u8(t.origin)
	flags: Trailer_Flags
	if t.has_slot {
		flags += {.Slot}
		put_u16(payload[2:], u16(t.slot))
	}
	if embedded {
		flags += {.Embedded}
	}
	if t.bank_saved {
		flags += {.Bank_Saved}
	}
	payload[1] = transmute(u8)flags

	at := 4
	payload[at] = u8(len(label))
	copy(payload[at + 1:], transmute([]u8)label)
	at += 1 + len(label)
	payload[at] = u8(len(name))
	copy(payload[at + 1:], transmute([]u8)name)
	at += 1 + len(name)
	if embedded {
		put_u32(payload[at:], u32(len(t.bank_json)))
		copy(payload[at + 4:], t.bank_json)
	}
	return out
}
