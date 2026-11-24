package panel_tests

import "core:testing"

import "../../hosts/panel"

// The selection trailer, checked against bytes written out by hand.
//
// Nothing here builds a blob with the encoder and reads it back with the
// decoder and stops there: two halves of one mistake agree with each other
// (CONTRIBUTING.md has the two times that cost days). The references are
// literals laid out from the format as hosts/panel/trailer.odin documents it,
// and the encoder is held to producing exactly them.

// "QSEL", version 1, a 22 byte payload: user, slot present, slot 42, the bank
// "My Bank", the patch "Glass Pad".
GOLDEN_SLOT := [?]u8 {
	'Q', 'S', 'E', 'L',
	0x01, 0x00, 0x00, 0x00, // trailer version 1
	0x16, 0x00, 0x00, 0x00, // payload of 22 bytes
	0x02, // origin: user
	0x01, // flags: slot present
	0x2A, 0x00, // slot 42
	0x07, 'M', 'y', ' ', 'B', 'a', 'n', 'k',
	0x09, 'G', 'l', 'a', 's', 's', ' ', 'P', 'a', 'd',
}

// The same with a bank carried: imported, slot and embedded bank, slot 1, the
// bank "B", the patch "N", and four bytes of bank which the decoder does not
// read as anything, so they need not be a bank here.
GOLDEN_EMBEDDED := [?]u8 {
	'Q', 'S', 'E', 'L',
	0x01, 0x00, 0x00, 0x00,
	0x10, 0x00, 0x00, 0x00, // payload of 16 bytes
	0x03, // origin: imported
	0x03, // flags: slot present, bank embedded
	0x01, 0x00, // slot 1
	0x01, 'B',
	0x01, 'N',
	0x04, 0x00, 0x00, 0x00, 'A', 'B', 'C', 'D', // the bank
}

// A file with no slot: file, no flags, bank "", patch "Pad". Bank saved, which
// is the third flag bit, set to prove it is read and not only the first two.
GOLDEN_SLOTLESS := [?]u8 {
	'Q', 'S', 'E', 'L',
	0x01, 0x00, 0x00, 0x00,
	0x09, 0x00, 0x00, 0x00, // payload of 9 bytes
	0x05, // origin: file
	0x04, // flags: bank saved
	0x00, 0x00,
	0x00, // no bank name
	0x03, 'P', 'a', 'd',
}

// The same slot of the same kind of bank, empty when it was saved: the fourth
// flag bit, beside slot present. "Init" is what an empty slot is called.
GOLDEN_EMPTY_SLOT := [?]u8 {
	'Q', 'S', 'E', 'L',
	0x01, 0x00, 0x00, 0x00,
	0x11, 0x00, 0x00, 0x00, // payload of 17 bytes
	0x03, // origin: imported
	0x09, // flags: slot present, slot was empty
	0x47, 0x00, // slot 71
	0x07, 'M', 'y', ' ', 'B', 'a', 'n', 'k',
	0x04, 'I', 'n', 'i', 't',
}

@(test)
the_empty_slot_golden_decodes_to_what_it_says :: proc(t: ^testing.T) {
	decoded, status := panel.trailer_decode(GOLDEN_EMPTY_SLOT[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, decoded.has_slot, "the slot flag was not read")
	testing.expect_value(t, decoded.slot, 71)
	testing.expect(t, decoded.slot_empty, "the slot-empty flag was not read")
	testing.expect_value(t, panel.text_get(&decoded.name), "Init")
	testing.expect(t, !decoded.embedded && !decoded.bank_saved, "another flag appeared beside it")
}

// What a trailer written before the bit existed says is what it said: the slot
// was not marked empty, so a slot with nothing in it is the bank's fault.
@(test)
the_older_goldens_do_not_say_the_slot_was_empty :: proc(t: ^testing.T) {
	for blob in ([][]u8{GOLDEN_SLOT[:], GOLDEN_EMBEDDED[:], GOLDEN_SLOTLESS[:]}) {
		decoded, status := panel.trailer_decode(blob)
		testing.expect_value(t, status, panel.Trailer_Status.Ok)
		testing.expect(t, !decoded.slot_empty, "the slot-empty flag appeared from nowhere")
	}
}

// Like the slot field, the bit means nothing without a slot: a selection with
// no slot cannot have an empty one.
@(test)
the_empty_flag_without_a_slot_is_not_read :: proc(t: ^testing.T) {
	bytes := GOLDEN_SLOTLESS
	bytes[13] = 0x08 // flags: slot was empty, and no slot
	decoded, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !decoded.slot_empty, "an empty slot appeared on a trailer with no slot")
}

// The bits after it are still free for a later build to use, and are ignored.
@(test)
flag_bits_nobody_has_named_yet_are_ignored :: proc(t: ^testing.T) {
	bytes := GOLDEN_EMPTY_SLOT
	bytes[13] = 0x09 | 0xF0
	decoded, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, decoded.has_slot && decoded.slot_empty && !decoded.embedded && !decoded.bank_saved, "an unnamed bit changed what was read")
}

@(test)
the_slot_golden_decodes_to_what_it_says :: proc(t: ^testing.T) {
	decoded, status := panel.trailer_decode(GOLDEN_SLOT[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, decoded.origin, panel.Origin.User)
	testing.expect(t, decoded.has_slot, "the slot flag was not read")
	testing.expect_value(t, decoded.slot, 42)
	testing.expect_value(t, panel.text_get(&decoded.label), "My Bank")
	testing.expect_value(t, panel.text_get(&decoded.name), "Glass Pad")
	testing.expect(t, !decoded.embedded, "a trailer with no bank came back with one")
	testing.expect(t, !decoded.bank_saved, "the bank-saved flag appeared from nowhere")
}

@(test)
the_embedded_golden_decodes_with_its_bank :: proc(t: ^testing.T) {
	decoded, status := panel.trailer_decode(GOLDEN_EMBEDDED[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, decoded.origin, panel.Origin.Imported)
	testing.expect_value(t, decoded.slot, 1)
	testing.expect(t, decoded.embedded, "the embedded flag was not read")
	testing.expect_value(t, string(decoded.bank_json), "ABCD")
}

@(test)
the_slotless_golden_reads_the_saved_flag_and_ignores_the_slot_field :: proc(t: ^testing.T) {
	decoded, status := panel.trailer_decode(GOLDEN_SLOTLESS[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, decoded.origin, panel.Origin.File)
	testing.expect(t, !decoded.has_slot, "a slotless trailer came back with a slot")
	testing.expect(t, decoded.bank_saved, "the bank-saved flag was not read")
	testing.expect_value(t, panel.text_get(&decoded.label), "")
	testing.expect_value(t, panel.text_get(&decoded.name), "Pad")
}

// The slot field of a trailer that says it has no slot is not read, whatever it
// holds: it is how a slot that was never there cannot become slot 0.
@(test)
a_slot_field_without_its_flag_is_not_a_slot :: proc(t: ^testing.T) {
	bytes := GOLDEN_SLOT
	bytes[13] = 0x00 // flags: nothing
	decoded, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !decoded.has_slot, "a slot appeared from a field that was switched off")
}

@(test)
the_encoder_writes_the_goldens_byte_for_byte :: proc(t: ^testing.T) {
	slot: panel.Trailer
	slot.origin = .User
	slot.has_slot = true
	slot.slot = 42
	panel.text_set(&slot.label, "My Bank")
	panel.text_set(&slot.name, "Glass Pad")

	embedded: panel.Trailer
	embedded.origin = .Imported
	embedded.has_slot = true
	embedded.slot = 1
	embedded.embedded = true
	embedded.bank_json = transmute([]u8)string("ABCD")
	panel.text_set(&embedded.label, "B")
	panel.text_set(&embedded.name, "N")

	slotless: panel.Trailer
	slotless.origin = .File
	slotless.bank_saved = true
	panel.text_set(&slotless.name, "Pad")

	empty: panel.Trailer
	empty.origin = .Imported
	empty.has_slot = true
	empty.slot = 71
	empty.slot_empty = true
	panel.text_set(&empty.label, "My Bank")
	panel.text_set(&empty.name, "Init")

	// The bit with no slot is not written either.
	slotless_empty := slotless
	slotless_empty.slot_empty = true

	cases := [?]struct {
		name:     string,
		trailer:  ^panel.Trailer,
		expected: []u8,
	} {
		{"an empty slot", &empty, GOLDEN_EMPTY_SLOT[:]},
		{"an empty flag and no slot", &slotless_empty, GOLDEN_SLOTLESS[:]},
		{"a slot", &slot, GOLDEN_SLOT[:]},
		{"an embedded bank", &embedded, GOLDEN_EMBEDDED[:]},
		{"a file", &slotless, GOLDEN_SLOTLESS[:]},
	}
	for c in cases {
		written := panel.trailer_encode(c.trailer)
		defer delete(written)
		testing.expectf(t, len(written) == len(c.expected), "%s: wrote %d bytes, the golden is %d", c.name, len(written), len(c.expected))
		for i in 0 ..< min(len(written), len(c.expected)) {
			testing.expectf(t, written[i] == c.expected[i], "%s: byte %d is 0x%02X, the golden says 0x%02X", c.name, i, written[i], c.expected[i])
		}
	}
}

@(test)
a_trailer_survives_its_own_round_trip_in_every_shape :: proc(t: ^testing.T) {
	// Two-byte and three-byte characters, a quote, and the longest name there
	// is: what a real bank is called, and what a cut in the wrong place breaks.
	long: [panel.TEXT_MAX]u8
	for i in 0 ..< len(long) {
		long[i] = 'x'
	}
	names := [?]string{"", "Pad", "Näsa \"Quote\"", "日本語のバンク", string(long[:])}

	for origin in ([]panel.Origin{.None, .Factory, .User, .Imported, .Archive, .File, .Session}) {
		for name in names {
			for has_slot in ([]bool{false, true}) {
				for embedded in ([]bool{false, true}) {
					source: panel.Trailer
					source.origin = origin
					source.has_slot = has_slot
					source.slot = 127 if has_slot else 0
					source.embedded = embedded
					source.bank_saved = !embedded
					source.slot_empty = has_slot && origin != .User
					source.bank_json = transmute([]u8)string("{\"bank\": true}") if embedded else nil
					panel.text_set(&source.label, name)
					panel.text_set(&source.name, name)

					bytes := panel.trailer_encode(&source)
					defer delete(bytes)
					back, status := panel.trailer_decode(bytes)
					testing.expect_value(t, status, panel.Trailer_Status.Ok)
					testing.expect_value(t, back.origin, origin)
					testing.expect_value(t, back.has_slot, has_slot)
					testing.expect_value(t, back.slot, source.slot)
					testing.expect_value(t, panel.text_get(&back.label), panel.text_get(&source.label))
					testing.expect_value(t, panel.text_get(&back.name), panel.text_get(&source.name))
					testing.expect_value(t, back.embedded, embedded)
					testing.expect_value(t, back.bank_saved, source.bank_saved)
					testing.expect_value(t, back.slot_empty, source.slot_empty)
					testing.expect_value(t, string(back.bank_json), string(source.bank_json))
				}
			}
		}
	}
}

// Text is cut where a character ends, so what a bank was called is never
// turned into bytes a web page refuses.
@(test)
a_name_too_long_for_a_trailer_is_cut_at_a_character :: proc(t: ^testing.T) {
	// 254 bytes of ASCII and then a three-byte character that does not fit.
	text := make([dynamic]u8)
	defer delete(text)
	for _ in 0 ..< panel.TEXT_MAX - 1 {
		append(&text, 'x')
	}
	append(&text, ..transmute([]u8)string("日"))

	stored: panel.Text
	panel.text_set(&stored, string(text[:]))
	testing.expect_value(t, len(panel.text_get(&stored)), panel.TEXT_MAX - 1)
}

// -- what is not a trailer, and what is a trailer that cannot be read ---------

@(test)
bytes_that_are_not_a_trailer_are_not_one :: proc(t: ^testing.T) {
	// A state from before there was one has nothing after its values. So do
	// states from builds with a different parameter table, which may have
	// more values there, and nothing here is allowed to find a trailer in
	// them.
	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"nothing", nil},
		{"a few bytes of the tag", {'Q', 'S', 'E'}},
		{"the surplus values of a bigger build", {1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0}},
		{"the tag in the wrong case", {'q', 's', 'e', 'l', 1, 0, 0, 0, 0, 0, 0, 0}},
		{"a different tag", {'S', '1', 'O', 'D', 1, 0, 0, 0, 0, 0, 0, 0}},
	}
	for c in cases {
		_, status := panel.trailer_decode(c.bytes)
		testing.expectf(t, status == .Absent, "%s: %v, not Absent", c.name, status)
	}
}

@(test)
a_trailer_from_another_version_is_told_apart_from_a_broken_one :: proc(t: ^testing.T) {
	for version in ([]u8{0, 2, 9, 0xFF}) {
		bytes := GOLDEN_SLOT
		bytes[4] = version
		_, status := panel.trailer_decode(bytes[:])
		testing.expectf(t, status == .Unknown_Version, "version %d: %v", version, status)
	}

	// Whatever else it holds: a version this build does not know may use the
	// length for something else, and is not read any further.
	bytes := GOLDEN_SLOT
	bytes[4] = 2
	bytes[11] = 0xFF // a length that would be oversize
	_, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Unknown_Version)
}

// Cut anywhere, a trailer that has begun is truncated, and says so rather than
// reading what is not there or a part of it as a whole.
@(test)
a_trailer_cut_short_at_any_length_is_truncated :: proc(t: ^testing.T) {
	for blob in ([][]u8{GOLDEN_SLOT[:], GOLDEN_EMBEDDED[:], GOLDEN_SLOTLESS[:]}) {
		for length in 4 ..< len(blob) {
			_, status := panel.trailer_decode(blob[:length])
			testing.expectf(t, status == .Truncated, "cut to %d of %d bytes: %v", length, len(blob), status)
		}
	}
}

// A payload whose length is honest and whose contents are not: a name that runs
// past the end, a bank longer than what is left.
@(test)
lengths_inside_the_payload_are_checked_against_the_payload :: proc(t: ^testing.T) {
	label_runs_over := GOLDEN_SLOT
	label_runs_over[16] = 0xFF
	name_runs_over := GOLDEN_SLOT
	name_runs_over[24] = 0xFF
	bank_runs_over := GOLDEN_EMBEDDED
	bank_runs_over[20] = 0xFF
	bank_runs_over[21] = 0xFF
	bank_runs_over[22] = 0xFF
	bank_runs_over[23] = 0xFF
	bank_length_missing := GOLDEN_EMBEDDED
	bank_length_missing[8] = 0x08 // the payload ends where the bank's length should be
	payload_too_short := GOLDEN_SLOT
	payload_too_short[8] = 0x03

	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"a bank name longer than the payload", label_runs_over[:]},
		{"a patch name longer than the payload", name_runs_over[:]},
		{"a bank four gigabytes long", bank_runs_over[:]},
		{"an embedded bank with no length", bank_length_missing[:20]},
		{"a payload with no room for its own fixed fields", payload_too_short[:]},
	}
	for c in cases {
		_, status := panel.trailer_decode(c.bytes)
		testing.expectf(t, status == .Truncated, "%s: %v", c.name, status)
	}
}

// The cap is on what the trailer claims, and it is checked before anything is
// read or allocated for it.
@(test)
a_trailer_claiming_more_than_the_cap_is_oversize :: proc(t: ^testing.T) {
	for length in ([]u32{panel.TRAILER_PAYLOAD_MAX + 1, 0x7FFF_FFFF, 0xFFFF_FFFF}) {
		bytes := GOLDEN_SLOT
		bytes[8] = u8(length)
		bytes[9] = u8(length >> 8)
		bytes[10] = u8(length >> 16)
		bytes[11] = u8(length >> 24)
		_, status := panel.trailer_decode(bytes[:])
		testing.expectf(t, status == .Oversize, "a payload of %d: %v", length, status)
	}

	// Exactly the cap is allowed, and the bytes it promised are not there.
	bytes := GOLDEN_SLOT
	bytes[8] = 0x00
	bytes[9] = 0x00
	bytes[10] = 0x40
	bytes[11] = 0x00
	_, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Truncated)
}

@(test)
a_complete_trailer_that_this_build_cannot_have_written_is_malformed :: proc(t: ^testing.T) {
	bad_origin := GOLDEN_SLOT
	bad_origin[12] = 0x07
	bad_label := GOLDEN_SLOT
	bad_label[17] = 0xFF // not UTF-8
	bad_name := GOLDEN_SLOT
	bad_name[26] = 0xC0 // an overlong lead byte

	cases := [?]struct {
		name:  string,
		bytes: []u8,
	} {
		{"an origin that does not exist", bad_origin[:]},
		{"a bank name that is not text", bad_label[:]},
		{"a patch name that is not text", bad_name[:]},
	}
	for c in cases {
		_, status := panel.trailer_decode(c.bytes)
		testing.expectf(t, status == .Malformed, "%s: %v", c.name, status)
	}
}

// Whatever follows the payload is for a later layout of the same version to
// use, and is not an error.
@(test)
bytes_after_the_payload_are_ignored :: proc(t: ^testing.T) {
	bytes := make([dynamic]u8)
	defer delete(bytes)
	append(&bytes, ..GOLDEN_SLOT[:])
	append(&bytes, 1, 2, 3, 4, 5)

	decoded, status := panel.trailer_decode(bytes[:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect_value(t, decoded.slot, 42)
}

// A bank that would take the trailer past the cap is left out of it. A reader
// refuses the whole trailer at the cap, and the identity is worth more than
// the bank.
@(test)
a_bank_too_big_for_the_cap_is_left_out_rather_than_poisoning_the_trailer :: proc(t: ^testing.T) {
	big := make([]u8, panel.TRAILER_PAYLOAD_MAX)
	defer delete(big)

	source: panel.Trailer
	source.origin = .Imported
	source.has_slot = true
	source.slot = 3
	source.embedded = true
	source.bank_json = big
	panel.text_set(&source.label, "Huge")
	panel.text_set(&source.name, "Pad")

	bytes := panel.trailer_encode(&source)
	defer delete(bytes)
	back, status := panel.trailer_decode(bytes)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !back.embedded, "a bank over the cap was written")
	testing.expect_value(t, back.slot, 3)
	testing.expect_value(t, panel.text_get(&back.label), "Huge")
}
