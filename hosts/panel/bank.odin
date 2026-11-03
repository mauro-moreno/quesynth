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
//
// Elsewhere, where the platform keeps per-user data: $XDG_DATA_HOME, or
// ~/.local/share without it. Off Windows this used to follow LOCALAPPDATA when
// it was set and otherwise fell back to a file beside whatever the host's
// working directory happened to be, which is not a place -- REAPER's is
// wherever it was launched from -- and a bank saved there was gone the next
// time a project was opened from somewhere else. That is why nothing is
// written to either any more; the banks already there are another matter, see
// bank_legacy_path.
bank_path :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	return bank_path_in(ODIN_OS == .Windows, local, data, home, allocator)
}

// The same, from what the environment said. Split out for the reason
// bank_load_from is: so each answer can be checked without owning the
// environment, which a test shares with every other test.
bank_path_in :: proc(windows: bool, local_app_data, xdg_data_home, home: string, allocator := context.allocator) -> string {
	parts: []string
	if windows {
		if local_app_data != "" {
			parts = {local_app_data, "Quesynth", "user-bank.json"}
		}
	} else if len(xdg_data_home) > 0 && xdg_data_home[0] == '/' {
		// A relative XDG_DATA_HOME is to be ignored, by the specification: it
		// would be relative to whatever the working directory is, which is
		// exactly the thing this is here to stop depending on. Checked by
		// hand because this branch is the non-Windows one whichever platform
		// is asking.
		parts = {xdg_data_home, "Quesynth", "user-bank.json"}
	} else if home != "" {
		parts = {home, ".local", "share", "Quesynth", "user-bank.json"}
	}
	if parts == nil {
		return strings.clone("user-bank.json", allocator)
	}
	joined, err := filepath.join(parts, allocator)
	if err != nil {
		return strings.clone("user-bank.json", allocator)
	}
	return joined
}

// Where the bank was before it had a place of its own: exactly where the
// build before the move looked for it. Under LOCALAPPDATA, on every platform,
// whenever that variable was set, and a file beside the host's working
// directory only when it was not. Linux and macOS users whose environment sets
// it kept their bank there, and every build until the move read and wrote it
// there.
//
// Read, never written. It is a poor place for a bank, which is why bank_path
// stopped using it, but it is where somebody's bank already is. A build that
// did not look there would play the factory bank over it, and a Program Change
// in a project saved before there was a selection to save -- which names no
// bank to miss -- would pick the factory sound of that number where the user's
// own used to be, with nothing to say so. So it is a second place to read from
// and nothing else: the file is not moved, copied or removed, the first save
// goes to bank_path, and from then on that one is the bank.
//
// Nothing on Windows. The bank was under LOCALAPPDATA there, which is what
// bank_path still answers, and the file in the working directory was only the
// fallback for it being empty, which bank_path also still answers.
bank_legacy_path :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	return bank_legacy_path_in(ODIN_OS == .Windows, local, allocator)
}

// The same, from what the environment said, for either platform. Split out for
// the reason bank_path_in is. Always allocated, so that the caller deletes it
// whichever of the three answers it is.
bank_legacy_path_in :: proc(windows: bool, local_app_data: string, allocator := context.allocator) -> string {
	if windows {
		return strings.clone("", allocator)
	}
	if local_app_data != "" {
		joined, err := filepath.join({local_app_data, "Quesynth", "user-bank.json"}, allocator)
		if err == nil {
			return joined
		}
	}
	return strings.clone("user-bank.json", allocator)
}

// Load the saved bank, or the one compiled into the binary when there is none.
//
// A file that will not parse is treated as absent rather than as an error. It
// is a convenience, and refusing to start an instrument over it would be worse
// than forgetting -- but it is not deleted either, so whatever is wrong with it
// can still be looked at.
//
// Says which of the two it found, because the answer decides whether a saved
// project has to carry the bank: the compiled-in one is every instance's, and
// the file is every instance's on this machine and nobody else's.
bank_load :: proc(slots: ^patch.Slots) -> Bank_Source {
	path := bank_path()
	defer delete(path)
	legacy := bank_legacy_path()
	defer delete(legacy)
	return bank_load_from(path, slots, legacy)
}

// The same, from a named file, and from `legacy` when there is none. Without
// one, which is what the Audio Unit passes, `path` is the only place looked at.
//
// Split out so it can be checked without writing over the bank on the machine
// running the check. A test that had to use the real path would either be a
// test nobody dares run or a test that eats somebody's patches.
bank_load_from :: proc(path: string, slots: ^patch.Slots, legacy := "") -> Bank_Source {
	if bank_read_from(path, slots, legacy) {
		return .Saved
	}
	patch.slots_load_factory(slots)
	return .Built_In
}

// Read the saved bank if there is one, and leave `slots` alone if there is
// not. What a retry wants: it is looking for one bank, and the factory one is
// not it.
//
// `legacy` is read only when there is no file at `path`. A file that is there
// and will not parse is not no file: it is where this build keeps the bank, and
// an older one found beside it would be played over a newer one that is only
// damaged, and written over it by the next save.
bank_read_from :: proc(path: string, slots: ^patch.Slots, legacy := "") -> bool {
	if legacy != "" && !os.exists(path) {
		return read_bank_file(legacy, slots)
	}
	return read_bank_file(path, slots)
}

@(private)
read_bank_file :: proc(path: string, slots: ^patch.Slots) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(data)

	parsed, err := patch.parse_bank_json(data)
	if err != .None {
		return false
	}
	defer patch.destroy_bank(parsed)
	patch.slots_load(slots, parsed)
	return true
}

// A failed restore tried again, against the saved bank as the file holds it
// now. The bank may have been put back since the state was loaded. Looks where
// bank_load_from does, in the same order, for the same reason.
session_retry_from :: proc(s: ^Session, slots: ^patch.Slots, path: string, legacy := "") -> (Restore_Result, bool) {
	saved := new(patch.Slots)
	defer free(saved)
	return session_retry(s, slots, saved if bank_read_from(path, saved, legacy) else nil)
}

// The same, against this machine's saved bank.
session_retry_saved :: proc(s: ^Session, slots: ^patch.Slots) -> (Restore_Result, bool) {
	path := bank_path()
	defer delete(path)
	legacy := bank_legacy_path()
	defer delete(legacy)
	return session_retry_from(s, slots, path, legacy)
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
	if !make_directories(filepath.dir(path)) {
		return false
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
	if !make_directories(filepath.dir(path)) {
		return false
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

// The directory and the ones above it that are not there yet.
//
// One level was enough when the file was under a folder every Windows user has.
// ~/.local/share is not something to rely on existing, and a first save that
// fails for that reason is a bank that was never kept.
@(private)
make_directories :: proc(dir: string) -> bool {
	if dir == "" || dir == "." || os.exists(dir) {
		return true
	}
	if parent := filepath.dir(dir); parent != dir && !make_directories(parent) {
		return false
	}
	if err := os.make_directory(dir); err != nil && !os.exists(dir) {
		return false
	}
	return true
}
