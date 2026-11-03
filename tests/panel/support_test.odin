package panel_tests

import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// Banks and instances for the tests that follow, made out of text so the
// banks are the documents a person would import, not something built with the
// code under test.

// A bank document with the named slots filled and the rest empty. Each filled
// slot is called "<label> <slot>" and sounds different from every other: its
// oscillator shape and gain follow its number, so two banks that disagree about
// a slot disagree about the sound as well as the name.
bank_text :: proc(label: string, filled: []int) -> string {
	last := -1
	for slot in filled {
		last = max(last, slot)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"format":"quesynth.bank","version":1,"name":"`)
	strings.write_string(&b, label)
	strings.write_string(&b, `","patches":[`)
	for i in 0 ..= last {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		is_filled := false
		for slot in filled {
			if slot == i {
				is_filled = true
			}
		}
		if !is_filled {
			strings.write_string(&b, "null")
			continue
		}
		strings.write_string(&b, `{"name":"`)
		strings.write_string(&b, label)
		strings.write_string(&b, " ")
		strings.write_int(&b, i)
		strings.write_string(&b, `","parameters":{"osc1 shape":`)
		strings.write_int(&b, i % 4)
		strings.write_string(&b, `,"amp gain":`)
		strings.write_int(&b, 20 + i)
		strings.write_string(&b, `}}`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// Everything an instance remembers about its bank and its selection, with no
// host around it: what a format keeps on the instance, and what the restore
// works on.
Instance :: struct {
	session: panel.Session,
	slots:   patch.Slots,
}

// Heap, because a bank is fifty-odd kilobytes and a test thread's stack is not
// where to keep several.
new_instance :: proc(t: ^testing.T, label: string, filled: []int, source: panel.Bank_Source) -> ^Instance {
	inst := new(Instance)
	text := bank_text(label, filled)
	parsed, err := patch.parse_bank_json(transmute([]u8)text)
	testing.expect_value(t, err, patch.Json_Error.None)
	if err == .None {
		patch.slots_load(&inst.slots, parsed)
		patch.destroy_bank(parsed)
	}
	panel.session_init(&inst.session, source)
	return inst
}

// A trailer as a host would have saved it: what it names, and the bank it
// carries when it carries one.
saved_trailer :: proc(
	origin: panel.Origin,
	slot: int,
	label: string,
	name: string,
	embedded_bank: string = "",
	bank_saved := false,
	slot_empty := false,
) -> []u8 {
	trailer: panel.Trailer
	trailer.origin = origin
	trailer.has_slot = slot >= 0
	trailer.slot = max(slot, 0)
	trailer.bank_saved = bank_saved
	trailer.slot_empty = slot_empty
	panel.text_set(&trailer.label, label)
	panel.text_set(&trailer.name, name)
	if embedded_bank != "" {
		trailer.embedded = true
		trailer.bank_json = transmute([]u8)embedded_bank
	}
	return panel.trailer_encode(&trailer, context.temp_allocator)
}
