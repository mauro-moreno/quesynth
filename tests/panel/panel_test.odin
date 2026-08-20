#+build windows
package panel_tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../../src/patch"
import "../../hosts/panel"

// The bank on disk: the link between the panel writing a patch and the plugin
// still having it tomorrow.
//
// The two ends of this were checkable and the middle was not. The panel produces
// a bank document -- watched going out over the bridge -- and a plugin loads one
// from the file and plays out of it -- watched through tools/vst3host reporting
// the program names. What sat between them was the host taking the text it was
// handed and putting it on disk, and nothing exercised that at all.
//
// Which is where the interesting failure lives: not in the format, but in
// writing it. A half-written file, a rename that does not replace, a directory
// that is not there the first time.

@(private)
temp_bank :: proc(t: ^testing.T, name: string) -> string {
	dir := os.get_env("TEMP", context.allocator)
	defer delete(dir)
	if dir == "" {
		return ""
	}
	// A subdirectory that does not exist yet, on purpose: the first save on a
	// machine has to create one, and that is a step easy to leave out and never
	// notice, because the second run onwards works.
	joined, err := filepath.join({dir, "quesynth-test", name}, context.allocator)
	if err != nil {
		return ""
	}
	return joined
}

@(test)
bank_survives_a_write_and_a_read :: proc(t: ^testing.T) {
	path := temp_bank(t, "bank-round-trip.json")
	testing.expect(t, path != "", "no temporary directory to write into")
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)

	// A sparse bank, because the gaps are what a careless writer loses.
	text: string = `{"format":"quesynth.bank","version":1,"name":"Kept","patches":[
		{"name":"Alpha","parameters":{"osc1 shape":1}},
		null,
		{"name":"Gamma","parameters":{"osc1 shape":3}}
	]}`

	testing.expect(t, panel.bank_write_to(path, text), "the bank was not written")
	testing.expect(t, os.exists(path), "the file is not there after writing it")

	slots: patch.Slots
	panel.bank_load_from(path, &slots)

	testing.expect_value(t, patch.slots_label(&slots), "Kept")
	testing.expect_value(t, patch.slots_name(&slots, 0), "Alpha")
	testing.expect_value(t, patch.slots_name(&slots, 2), "Gamma")

	// The gap is still a gap. A reader that dropped it would have moved Gamma
	// to slot 1, and every program change aimed at 2 with it.
	_, filled := patch.slots_patch(&slots, 1)
	testing.expect(t, !filled, "the empty slot came back filled")

	first, has_first := patch.slots_patch(&slots, 0)
	testing.expect(t, has_first, "slot 0 came back empty")
	if has_first {
		testing.expect_value(t, first[0], i32(1))
	}
}

// Saving twice must leave the second bank, not the first and not both.
//
// The write goes through a temporary file and a rename so a crash cannot leave
// half a bank. Rename does not replace on Windows, so the old file is removed
// first -- which is the one moment there is no bank on disk, and the reason the
// new one is written before it happens rather than after.
@(test)
bank_replaces_what_was_there :: proc(t: ^testing.T) {
	path := temp_bank(t, "bank-replace.json")
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)

	first: string = `{"format":"quesynth.bank","version":1,"name":"First","patches":[
		{"name":"One","parameters":{}}
	]}`
	second: string = `{"format":"quesynth.bank","version":1,"name":"Second","patches":[
		{"name":"Two","parameters":{}},
		{"name":"Three","parameters":{}}
	]}`

	testing.expect(t, panel.bank_write_to(path, first), "the first write failed")
	testing.expect(t, panel.bank_write_to(path, second), "the second write failed")

	slots: patch.Slots
	panel.bank_load_from(path, &slots)
	testing.expect_value(t, patch.slots_label(&slots), "Second")
	testing.expect_value(t, patch.slots_name(&slots, 0), "Two")
	testing.expect_value(t, patch.slots_name(&slots, 1), "Three")

	// And nothing of the first is left beside it.
	//
	// Concatenated, not joined: filepath.join would make "<path>/.new", a
	// hidden file inside a directory that is not one, and the check would pass
	// whatever the code did.
	temp := strings.concatenate({path, ".new"}, context.temp_allocator)
	testing.expect(t, !os.exists(temp), "the temporary file was left behind")
}

// A file that is not a bank must not take the instrument down with it.
//
// It is treated as absent: the factory bank compiled into the binary is used
// instead, and the file is left alone so whatever is wrong with it can still be
// looked at. Refusing to start over a bad convenience file would be worse than
// forgetting.
@(test)
a_broken_bank_falls_back_to_the_factory :: proc(t: ^testing.T) {
	path := temp_bank(t, "bank-broken.json")
	if path == "" {return}
	defer delete(path)
	defer os.remove(path)

	testing.expect(t, panel.bank_write_to(path, "this is not json at all"), "write failed")

	patch.factory_prepare()
	slots: patch.Slots
	panel.bank_load_from(path, &slots)

	// The factory bank's first patch, which is what a fresh install plays.
	testing.expect_value(t, patch.slots_name(&slots, 0), patch.factory_name(0))
	testing.expect(t, os.exists(path), "the unreadable file was deleted")
}

// And no file at all is the ordinary case on a machine that has never saved.
@(test)
no_bank_file_is_the_factory :: proc(t: ^testing.T) {
	path := temp_bank(t, "bank-that-does-not-exist.json")
	if path == "" {return}
	defer delete(path)
	os.remove(path)

	patch.factory_prepare()
	slots: patch.Slots
	panel.bank_load_from(path, &slots)
	testing.expect_value(t, patch.slots_name(&slots, 0), patch.factory_name(0))
}
