#+build windows
package panel

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../src/patch"

// The bank on disk, which is what a plugin remembers between sessions.
//
// The browser keeps its bank in local storage and the plugins keep theirs here,
// and the split is deliberate: in a plugin the host owns the *sound* -- VST3
// and CLAP both save the current patch into the project through
// getState/setState -- but nothing in either format saves a bank. A bank is not
// part of a song; it is part of the instrument, the same way it is on hardware.
//
// One file, shared by every instance and both formats. That is a decision and
// not an accident: a sound written into slot 40 from one track should be in
// slot 40 everywhere, including in the other plugin format, because that is
// what "slot 40" is supposed to mean. The cost is that two instances writing at
// once is last-writer-wins, which is worth saying out loud and is not worth a
// lock: writing a patch is something a person does, one at a time.

// Under the user's local app data, beside the web view's profile. Not beside
// the plugin: a bundle in Program Files is not writable, and a bank is per-user
// anyway.
bank_path :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if local == "" {
		return strings.clone("user-bank.json", allocator)
	}
	joined, err := filepath.join({local, "Quesynth", "user-bank.json"}, allocator)
	if err != nil {
		return strings.clone("user-bank.json", allocator)
	}
	return joined
}

// Load the saved bank, or the one compiled into the binary when there is none.
//
// A file that will not parse is treated as absent rather than as an error. It
// is a convenience, and refusing to start an instrument over it would be worse
// than forgetting -- but it is not deleted either, so whatever is wrong with it
// can still be looked at.
bank_load :: proc(slots: ^patch.Slots) {
	path := bank_path()
	defer delete(path)
	bank_load_from(path, slots)
}

// The same, from a named file.
//
// Split out so it can be checked without writing over the bank on the machine
// running the check. A test that had to use the real path would either be a
// test nobody dares run or a test that eats somebody's patches.
bank_load_from :: proc(path: string, slots: ^patch.Slots) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		patch.slots_load_factory(slots)
		return
	}
	defer delete(data)

	parsed, err := patch.parse_bank_json(data)
	if err != .None {
		patch.slots_load_factory(slots)
		return
	}
	defer patch.destroy_bank(parsed)
	patch.slots_load(slots, parsed)
}

// Write the bank out, creating the directory the first time.
//
// Through a temporary file and a rename, so a crash or a full disk leaves the
// previous bank rather than half of the new one. A bank is the only thing here
// a person cannot get back by rebuilding.
bank_save :: proc(slots: ^patch.Slots) -> bool {
	path := bank_path()
	defer delete(path)

	// A slice of `path`, not an allocation: filepath.dir takes no allocator
	// and its result must not be freed. Getting that wrong crashed the VST3
	// editor once already.
	dir := filepath.dir(path)
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil && !os.exists(dir) {
			return false
		}
	}

	text := patch.slots_write_json(slots)
	defer delete(text)

	temp := strings.concatenate({path, ".new"}, context.temp_allocator)
	if err := os.write_entire_file(temp, transmute([]u8)text); err != nil {
		return false
	}

	// Replaced rather than written over. os.rename will not overwrite on
	// Windows, so the old one goes first -- which is the one moment the bank is
	// not on disk, and why the new one is already written before it happens.
	if os.exists(path) {
		os.remove(path)
	}
	if err := os.rename(temp, path); err != nil {
		return false
	}
	return true
}

// Write a bank document exactly as it was handed over.
//
// The text comes from the panel's own writer, and src/patch's reader is already
// checked against it -- tests/patch covers the empty slots that make the two
// easy to disagree about. Re-encoding it here would be a third implementation
// of one format, which is the thing this project keeps being bitten by.
bank_write :: proc(text: string) -> bool {
	path := bank_path()
	defer delete(path)
	return bank_write_to(path, text)
}

// The same, to a named file. Split out for the reason bank_load_from is.
bank_write_to :: proc(path: string, text: string) -> bool {
	dir := filepath.dir(path)
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil && !os.exists(dir) {
			return false
		}
	}

	temp := strings.concatenate({path, ".new"}, context.temp_allocator)
	if err := os.write_entire_file(temp, transmute([]u8)text); err != nil {
		return false
	}
	if os.exists(path) {
		os.remove(path)
	}
	return os.rename(temp, path) == nil
}
