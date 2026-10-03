// Writes tests/browser/fixtures/odin-bank.json with the daemon's own bank
// writer, so the adapter's tests read a document the real daemon produces
// rather than one built by the code under test:
//
//     odin run tests/browser/fixtures/genbank > tests/browser/fixtures/odin-bank.json
//
// The factory bank, with the shapes a hand-written fixture would miss: an
// empty slot between filled ones, a name that needs escaping and is not
// ASCII, a label with a space, and a patch in the last of the 128 slots.
package genbank

import "core:fmt"

import "../../../../src/patch"

put :: proc(into: ^[patch.SLOT_NAME_MAX]u8, length: ^int, text: string) {
	n := min(len(text), patch.SLOT_NAME_MAX)
	for i in 0 ..< n {into[i] = text[i]}
	length^ = n
}

main :: proc() {
	patch.factory_prepare()
	s := new(patch.Slots)
	patch.slots_load_factory(s)
	s.filled[2] = false
	put(&s.names[3], &s.name_len[3], "Bass \"Deep\" \\ Ü\ttab")
	put(&s.label, &s.label_len, "My Bank")
	s.values[127] = s.values[0]
	s.values[127][19] = 5
	s.filled[127] = true
	put(&s.names[127], &s.name_len[127], "Last")
	fmt.print(patch.slots_write_json(s))
}
