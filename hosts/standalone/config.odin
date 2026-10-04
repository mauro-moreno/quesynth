package standalone

import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/patch"

// Where a user's own bank lives when they have not named one, and how a bank
// file becomes the daemon's browsable Slots. A bank saved with bank.write to the
// config path is picked up here on the next start, so edits survive a restart.

// $XDG_CONFIG_HOME/quesynth/bank.json, or ~/.config/quesynth/bank.json. ok is
// false when neither environment variable is set. The path is allocated.
config_bank_path :: proc(allocator := context.allocator) -> (string, bool) {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/quesynth/bank.json", x, allocator = allocator), true
	}
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return fmt.aprintf("%s/.config/quesynth/bank.json", h, allocator = allocator), true
	}
	return "", false
}

// $XDG_CONFIG_HOME/quesynth/archive.path, or ~/.config/quesynth/archive.path:
// the archive the daemon reopens at startup, so every front-end finds the same
// one open without being told where it is. Allocated, as above.
config_archive_path :: proc(allocator := context.allocator) -> (string, bool) {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/quesynth/archive.path", x, allocator = allocator), true
	}
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return fmt.aprintf("%s/.config/quesynth/archive.path", h, allocator = allocator), true
	}
	return "", false
}

// Read a JSON bank file and load it into `bank`, replacing what was there.
// Returns false on a read or parse error, leaving `bank` untouched.
load_bank_file :: proc(bank: ^patch.Slots, path: string) -> bool {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return false
	}
	parsed, perr := patch.parse_bank_json(data, context.temp_allocator)
	if perr != .None {
		return false
	}
	patch.slots_load(bank, parsed)
	return true
}

// Load a user bank over the factory one at startup: the --bank path if given,
// otherwise `config_bank`, a bank.json left in the config directory by a
// previous run ("" when there is no config directory). Neither is an error if
// absent or unreadable -- the factory bank is already loaded. True when a bank
// file was loaded.
apply_user_bank :: proc(bank: ^patch.Slots, bank_path, config_bank: string) -> bool {
	source := bank_path
	if source == "" {
		if config_bank == "" || !os.exists(config_bank) {
			return false
		}
		source = config_bank
	}
	if load_bank_file(bank, source) {
		fmt.printfln("bank   %s", source)
		return true
	}
	fmt.eprintfln("bank   could not load %s; using the factory bank", source)
	return false
}

// The bank a daemon starts with, the identity that goes beside it, and the
// file it keeps that bank in. The factory bank, unless a user bank replaces it:
// the --bank file if given, otherwise `config_bank`, the bank.json a previous
// run kept (config_bank_path, "" when there is no config directory). Failure
// is not fatal -- the factory bank stays loaded to fall back to.
//
// Loading a bank file is the first change to the bank, so bank_rev starts at 1
// then and at 0 only on the factory bank, which nobody chose. A front-end with
// a bank of its own goes by that: the TUI loads its User bank only into a bank
// at 0, so it never loads it over one a save kept or one --bank named. No
// patch is named yet: one given on the command line was not loaded from a slot.
//
// `keep` is the file the start read or tried, so a save is there at the next
// start with the same --bank, or with none: the --bank file made absolute
// against the working directory, otherwise config_bank ("" keeps nothing). A
// daemon started with --bank never writes bank.json. A --bank file the start
// did not load may be somebody else's file rather than a bank, so
// keep_guarded is true then: it is replaced only while it is absent or empty
// (bank_file_replaceable), until the daemon has written it once. `keep` is
// allocated.
daemon_start_bank :: proc(bank: ^patch.Slots, bank_path, config_bank: string) -> (start: Patch_Identity, keep: string, keep_guarded: bool) {
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	loaded := apply_user_bank(bank, bank_path, config_bank)
	start = Patch_Identity{slot = -1, bank_rev = loaded ? 1 : 0}
	if bank_path == "" {
		return start, strings.clone(config_bank), false
	}
	keep = start_absolute_path(bank_path)
	if !loaded && !bank_file_replaceable(keep) {
		fmt.eprintfln("bank   patch.save and bank.keep will not overwrite %s; move it away or start with another --bank", bank_path)
	}
	return start, keep, !loaded
}

// `path` under the working directory when it is relative, so bank.keep can
// report a path that a client in another directory can use. Not cleaned and no
// link resolved, so it names the same file `path` did at start:
// os.get_absolute_path opens the file, and a --bank file need not exist yet.
// Allocated.
@(private = "file")
start_absolute_path :: proc(path: string) -> string {
	if os.is_absolute_path(path) {
		return strings.clone(path)
	}
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || cwd == "" {
		return strings.clone(path)
	}
	sep := strings.has_suffix(cwd, os.Path_Separator_String) ? "" : os.Path_Separator_String
	return strings.concatenate({cwd, sep, path})
}
