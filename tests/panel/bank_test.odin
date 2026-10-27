package panel_tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// Where the saved bank is, and reading it back for a retry.
//
// Nothing here touches the real bank on the machine running the tests, and
// nothing reads the environment either: the environment is shared by every
// test in the process, and a test that changed it would be changing what every
// other one saw.

@(test)
off_windows_the_bank_is_under_the_per_user_data_directory :: proc(t: ^testing.T) {
	join :: proc(parts: ..string) -> string {
		joined, _ := filepath.join(parts, context.temp_allocator)
		return joined
	}

	cases := [?]struct {
		name:     string,
		local:    string,
		xdg:      string,
		home:     string,
		expected: string,
	} {
		{"XDG_DATA_HOME", "", "/data", "/home/u", join("/data", "Quesynth", "user-bank.json")},
		{"no XDG_DATA_HOME", "", "", "/home/u", join("/home/u", ".local", "share", "Quesynth", "user-bank.json")},
		// A relative one is to be ignored, and would be the working directory
		// again.
		{"a relative XDG_DATA_HOME", "", "data", "/home/u", join("/home/u", ".local", "share", "Quesynth", "user-bank.json")},
		// Windows' variable means nothing to a Unix.
		{"LOCALAPPDATA set", "C:\\Users\\u\\AppData\\Local", "", "/home/u", join("/home/u", ".local", "share", "Quesynth", "user-bank.json")},
		// What it was before, as the last resort and not the first.
		{"nothing at all", "", "", "", "user-bank.json"},
	}
	for c in cases {
		path := panel.bank_path_in(false, c.local, c.xdg, c.home)
		defer delete(path)
		testing.expectf(t, path == c.expected, "%s: %q, not %q", c.name, path, c.expected)
	}
}

@(test)
on_windows_the_bank_is_where_it_always_was :: proc(t: ^testing.T) {
	expected, _ := filepath.join({"C:\\Users\\u\\AppData\\Local", "Quesynth", "user-bank.json"}, context.temp_allocator)
	path := panel.bank_path_in(true, "C:\\Users\\u\\AppData\\Local", "/data", "/home/u")
	defer delete(path)
	testing.expect_value(t, path, expected)

	// XDG means nothing there, and without LOCALAPPDATA it is the old fallback.
	bare := panel.bank_path_in(true, "", "/data", "/home/u")
	defer delete(bare)
	testing.expect_value(t, bare, "user-bank.json")
}

// -- the saved bank, read back -------------------------------------------------

temp_file :: proc(name: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = os.get_env("TEMP", context.temp_allocator)
	}
	if dir == "" {
		dir = "/tmp"
	}
	joined, _ := filepath.join({dir, name}, context.temp_allocator)
	return joined
}

@(test)
a_saved_bank_is_read_back_and_a_missing_one_is_the_built_in_one :: proc(t: ^testing.T) {
	patch.factory_prepare()
	path := temp_file("quesynth-test-bank-source.json")
	defer os.remove(path)
	os.remove(path)

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(path, slots), panel.Bank_Source.Built_In)
	testing.expect_value(t, patch.slots_label(slots), "Factory")

	testing.expect(t, panel.bank_write_to(path, bank_text("My Bank", {0, 7})), "the bank was not written")
	testing.expect_value(t, panel.bank_load_from(path, slots), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_label(slots), "My Bank")

	// A file that is not a bank is not the saved bank, and is not an error.
	testing.expect(t, panel.bank_write_to(path, "this is not json"), "write failed")
	testing.expect_value(t, panel.bank_load_from(path, slots), panel.Bank_Source.Built_In)
}

// What a retry reads must not be replaced by the factory bank when there is
// nothing to read: the factory bank is not what it is looking for.
@(test)
reading_a_bank_that_is_not_there_leaves_the_slots_alone :: proc(t: ^testing.T) {
	path := temp_file("quesynth-test-bank-absent.json")
	os.remove(path)

	inst := new_instance(t, "Untouched", {0}, .Saved)
	defer free(inst)
	before := inst.slots

	testing.expect(t, !panel.bank_read_from(path, &inst.slots), "a bank was read from nothing")
	testing.expect(t, inst.slots == before, "the slots changed")
}

@(test)
a_retry_reads_the_saved_bank_file_for_the_bank_it_wants :: proc(t: ^testing.T) {
	path := temp_file("quesynth-test-bank-retry.json")
	defer os.remove(path)
	os.remove(path)

	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))

	// Nothing on disk: still missing, nothing moved.
	_, moved := panel.session_retry_from(&inst.session, &inst.slots, path)
	testing.expect(t, !moved, "the bank moved with no file to read")
	testing.expect_value(t, inst.session.restore_error, panel.Restore_Error.Missing_Bank)

	// The user's bank is put back where it was.
	testing.expect(t, panel.bank_write_to(path, bank_text("My Bank", {0, 7})), "the bank was not written")
	result, changed := panel.session_retry_from(&inst.session, &inst.slots, path)

	testing.expect(t, result.restored && changed, "the retry did not find the bank that is there now")
	testing.expect_value(t, patch.slots_label(&inst.slots), "My Bank")
	testing.expect_value(t, result.program, 7)
}
