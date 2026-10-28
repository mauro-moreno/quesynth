package panel_tests

import "core:encoding/json"
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

// -- the place the bank was kept before it had one ---------------------------
//
// Before the per-user directory the bank was a file beside the host's working
// directory, and the Linux editors read and wrote it there. Somebody who has
// one is not told to move it: a bank is read from where it is, so that
// upgrading does not play the factory bank over the user's own.
//
// None of this names the process's working directory, which is the one thing
// the old place depended on and the one thing a test cannot own: each test gets
// a directory of its own and names both places in it.

Bank_Files :: struct {
	root:   string,
	// Where the bank lives now. Its directory is not made until something is
	// written, as on a machine that has never saved one.
	saved:  string,
	// Where it was.
	legacy: string,
}

bank_files :: proc(t: ^testing.T) -> Bank_Files {
	root, err := os.make_directory_temp("", "quesynth-bank-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	join :: proc(parts: ..string) -> string {
		joined, _ := filepath.join(parts, context.temp_allocator)
		return joined
	}
	return Bank_Files{root = root, saved = join(root, "data", "Quesynth", "user-bank.json"), legacy = join(root, "cwd", "user-bank.json")}
}

bank_files_destroy :: proc(files: Bank_Files) {
	os.remove_all(files.root)
	delete(files.root)
}

// A file put where only a person or an older build would have put it.
put_file :: proc(t: ^testing.T, path: string, text: string) {
	if dir := filepath.dir(path); !os.exists(dir) {
		testing.expect_value(t, os.make_directory_all(dir), nil)
	}
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)text), nil)
}

bytes_of :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(test)
a_bank_only_the_old_place_holds_is_the_saved_bank :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	// Interior empties, which are what a copy that compacted would lose.
	text := bank_text("My Linux Bank", {0, 2, 7})
	put_file(t, files.legacy, text)

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(files.saved, slots, files.legacy), panel.Bank_Source.Saved)

	expected := new_instance(t, "My Linux Bank", {0, 2, 7}, .Saved)
	defer free(expected)
	testing.expect_value(t, patch.slots_label(slots), "My Linux Bank")
	testing.expect_value(t, patch.slots_name(slots, 0), "My Linux Bank 0")
	testing.expect_value(t, patch.slots_name(slots, 2), "My Linux Bank 2")
	testing.expect_value(t, patch.slots_name(slots, 7), "My Linux Bank 7")
	testing.expect(t, !slots.filled[1] && !slots.filled[3], "an empty slot between two filled ones was filled")
	testing.expect(t, slots^ == expected.slots, "the bank that was read is not the bank that was in the file")

	// Read, and nothing more: not moved, not copied, not rewritten.
	testing.expect_value(t, bytes_of(files.legacy), text)
	testing.expect(t, !os.exists(files.saved), "reading the old file made a new one")
}

// The objective, from the instance's side: a project saved before there was a
// selection to save says nothing about its bank, so what a Program Change means
// is whatever bank the instance starts with.
@(test)
a_program_change_after_the_upgrade_selects_out_of_the_users_own_bank :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	put_file(t, files.legacy, bank_text("My Linux Bank", {0, 2, 7}))

	inst := new(Instance)
	defer free(inst)
	source := panel.bank_load_from(files.saved, &inst.slots, files.legacy)
	panel.session_init(&inst.session, source)
	panel.session_restore(&inst.session, &inst.slots, nil)
	panel.session_select_slot(&inst.session, 2)

	view := panel.selection_view(&inst.session.selection, &inst.slots)
	testing.expect_value(t, view.origin, panel.Origin.User)
	testing.expect_value(t, view.label, "My Linux Bank")
	testing.expect_value(t, view.name, "My Linux Bank 2")

	// And it is kept as the bank on this machine: named by a saved project,
	// not carried in it.
	saved := panel.session_trailer(&inst.session, &inst.slots)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, trailer.bank_saved && !trailer.embedded, "the bank was not treated as the user's saved bank")
}

@(test)
the_file_at_the_new_place_wins_over_the_old_one :: proc(t: ^testing.T) {
	files := bank_files(t)
	defer bank_files_destroy(files)
	put_file(t, files.legacy, bank_text("Old Place", {0, 1}))
	put_file(t, files.saved, bank_text("New Place", {0, 3}))

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(files.saved, slots, files.legacy), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_label(slots), "New Place")
	testing.expect_value(t, patch.slots_name(slots, 3), "New Place 3")

	// A retry reads in the same order.
	other := new(patch.Slots)
	defer free(other)
	testing.expect(t, panel.bank_read_from(files.saved, other, files.legacy), "nothing was read")
	testing.expect_value(t, patch.slots_label(other), "New Place")
}

@(test)
with_neither_file_the_bank_is_the_built_in_one_and_nothing_is_made :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(files.saved, slots, files.legacy), panel.Bank_Source.Built_In)
	testing.expect_value(t, patch.slots_label(slots), "Factory")

	// A retry is looking for one bank, and leaves the playing one alone.
	inst := new_instance(t, "Untouched", {0}, .Saved)
	defer free(inst)
	before := inst.slots
	testing.expect(t, !panel.bank_read_from(files.saved, &inst.slots, files.legacy), "a bank was read from nothing")
	testing.expect(t, inst.slots == before, "the slots changed")

	testing.expect(t, !os.exists(files.saved) && !os.exists(files.legacy), "a load made a file")
}

// What happened before, and still does: a file that will not parse is as good
// as none. It is a file at the new place, which is where this build keeps the
// bank, so the old one is not a second opinion about it -- a bank from before
// the move would be played over a newer one that only happens to be damaged,
// and the next save would put it where the damaged one was.
@(test)
a_new_file_that_will_not_parse_is_not_a_reason_to_read_the_old_one :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	put_file(t, files.legacy, bank_text("Old Place", {0, 1}))
	put_file(t, files.saved, "this is not json")

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(files.saved, slots, files.legacy), panel.Bank_Source.Built_In)
	testing.expect_value(t, patch.slots_label(slots), "Factory")
	testing.expect_value(t, bytes_of(files.saved), "this is not json")
}

// Windows never read a file beside the working directory unless LOCALAPPDATA
// was empty, and then it was the only place there was. What is looked at is
// decided by the platform and not by whether a file happens to be there.
@(test)
the_old_place_is_looked_at_off_windows_and_not_on_it :: proc(t: ^testing.T) {
	testing.expect_value(t, panel.bank_legacy_path_in(true), "")
	// Relative, as it was: the working directory is the point of it.
	testing.expect_value(t, panel.bank_legacy_path_in(false), "user-bank.json")
}

@(test)
a_retry_finds_a_bank_only_the_old_place_holds :: proc(t: ^testing.T) {
	files := bank_files(t)
	defer bank_files_destroy(files)

	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Linux Bank", "My Linux Bank 7", bank_saved = true))

	_, moved := panel.session_retry_from(&inst.session, &inst.slots, files.saved, files.legacy)
	testing.expect(t, !moved, "the bank moved with nothing to read")
	testing.expect_value(t, inst.session.restore_error, panel.Restore_Error.Missing_Bank)

	// The user's bank was beside the host's working directory all along.
	put_file(t, files.legacy, bank_text("My Linux Bank", {0, 2, 7}))
	result, changed := panel.session_retry_from(&inst.session, &inst.slots, files.saved, files.legacy)

	testing.expect(t, result.restored && changed, "the retry did not find the bank that is there")
	testing.expect_value(t, patch.slots_label(&inst.slots), "My Linux Bank")
	testing.expect_value(t, result.program, 7)
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Saved)
}

// No migration, by anybody: the first write after a load from the old place
// goes to the new one, where the bank now lives, and the old file is left for
// the person who put it there.
@(test)
a_save_after_a_load_from_the_old_place_goes_to_the_new_place_and_leaves_the_old_one :: proc(t: ^testing.T) {
	files := bank_files(t)
	defer bank_files_destroy(files)
	original := bank_text("My Linux Bank", {0, 2, 7})
	put_file(t, files.legacy, original)

	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load_from(files.saved, slots, files.legacy), panel.Bank_Source.Saved)

	edited := bank_text("My Linux Bank", {0, 2, 7, 9})
	testing.expect(t, panel.bank_write_to(files.saved, edited), "the bank was not written")

	testing.expect_value(t, bytes_of(files.saved), edited)
	testing.expect_value(t, bytes_of(files.legacy), original)

	// And from then on the new one is the bank, edit and all.
	again := new(patch.Slots)
	defer free(again)
	testing.expect_value(t, panel.bank_load_from(files.saved, again, files.legacy), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_name(again, 9), "My Linux Bank 9")
}

// -- a project that names the built-in bank, opened beside a saved one -------
//
// A project saved while an instance played the compiled-in Factory names it
// and carries nothing. Opened where this machine's saved bank is another one,
// that is a bank the instance is not playing: MissingBank, with the user's
// bank still the one played and the one the panel is handed. Playing Factory
// instead made the panel take Factory for the bank the host keeps, and its
// next write of a single slot replaced the user's whole bank file with it.

// Where this test's saved bank is, for the host's write to find. One per test
// thread, so no other test sees it.
@(private = "file", thread_local)
saved_bank_path: string

@(private = "file")
write_saved_bank :: proc(text: string) -> bool {
	return panel.bank_write_to(saved_bank_path, text)
}

@(test)
a_project_naming_the_built_in_bank_leaves_the_saved_bank_whole_through_a_write :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	original := bank_text("Alfmeister Bank", {0, 2, 7})
	put_file(t, files.saved, original)
	saved_bank_path = files.saved

	// An instance starts with the user's bank, as CLAP and VST3 make one.
	inst := new(Instance)
	defer free(inst)
	panel.session_init(&inst.session, panel.bank_load_from(files.saved, &inst.slots))
	user := new(patch.Slots)
	defer free(user)
	user^ = inst.slots
	testing.expect_value(t, patch.slots_label(user), "Alfmeister Bank")
	host := panel.Host {
		user = rawptr(inst),
		read_bank = proc(user: rawptr) -> string {
			inst := (^Instance)(user)
			return patch.slots_write_json(&inst.slots, context.temp_allocator)
		},
		set_bank = proc(user: rawptr, text: string, save: bool, origin: panel.Origin) -> panel.Bank_Result {
			inst := (^Instance)(user)
			return panel.session_set_bank(&inst.session, &inst.slots, text, save, origin, write_saved_bank)
		},
		read_session = proc(user: rawptr) -> panel.Instance_View {
			inst := (^Instance)(user)
			return {&inst.session, &inst.slots}
		},
	}

	// The project names the compiled-in bank by the label and origin it has.
	result := panel.session_restore(&inst.session, &inst.slots, saved_trailer(.Factory, 5, "Factory", patch.factory_name(5)))
	testing.expect_value(t, result.error, panel.Restore_Error.Missing_Bank)
	testing.expect(t, !result.restored && !result.has_program, "the restore put another bank in")
	testing.expect(t, inst.slots == user^, "the user's bank is no longer the one played")
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, inst.session.bank_origin, panel.Origin.User)

	// The editor opens, and the bank it is handed is the user's own.
	replies := panel.handle_message(&host, `{"type":"sync"}`)
	if !testing.expect(t, len(replies) > 0, "the editor was handed nothing") {
		return
	}
	message, err := json.parse_string(replies[0], allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	fields, _ := message.(json.Object)
	kind, _ := fields["type"].(json.String)
	origin, _ := fields["origin"].(json.String)
	handed, _ := fields["text"].(json.String)
	testing.expect_value(t, kind, "bank")
	testing.expect_value(t, origin, "user")
	page := new(patch.Slots)
	defer free(page)
	if bank, bad := patch.parse_bank_json(transmute([]u8)handed); testing.expect_value(t, bad, patch.Json_Error.None) {
		patch.slots_load(page, bank)
		patch.destroy_bank(bank)
	}
	testing.expect_value(t, patch.slots_label(page), "Alfmeister Bank")
	testing.expect_value(t, bytes_of(files.saved), original)

	// The panel writes a sound into an empty slot of the bank it was handed and
	// asks for that bank to be kept, which is what a write sends.
	WRITTEN :: 20
	testing.expect(t, !page.filled[WRITTEN], "the slot written to was not empty")
	sound := user.values[2]
	put_slot(page, WRITTEN, sound, "Written Pad")
	post, _ := json.marshal(
		struct {
			type:   string,
			text:   string,
			save:   bool,
			v:      int,
			origin: string,
		}{"bank", patch.slots_write_json(page, context.temp_allocator), true, 1, origin},
		allocator = context.temp_allocator,
	)
	panel.handle_message(&host, string(post))

	// What the file holds is the user's bank with that one slot written, and
	// it is what the next instance starts with.
	expected := new(patch.Slots)
	defer free(expected)
	expected^ = user^
	put_slot(expected, WRITTEN, sound, "Written Pad")
	next := new(patch.Slots)
	defer free(next)
	testing.expect_value(t, panel.bank_load_from(files.saved, next), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_label(next), "Alfmeister Bank")
	testing.expect(t, next^ == expected^, "the saved bank is not the user's bank with the one slot written")
}

@(private = "file")
put_slot :: proc(s: ^patch.Slots, slot: int, values: [patch.PARAMETER_COUNT]i32, name: string) {
	s.values[slot] = values
	s.filled[slot] = true
	s.name_len[slot] = copy(s.names[slot][:], name)
}
