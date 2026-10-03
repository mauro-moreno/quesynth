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
// otherwise a bank left in the config directory by a previous run. Neither is an
// error if absent or unreadable -- the factory bank is already loaded.
apply_user_bank :: proc(bank: ^patch.Slots, bank_path: string) {
	source := bank_path
	owned := false
	if source == "" {
		cfg, ok := config_bank_path(context.allocator)
		if !ok {
			return
		}
		if !os.exists(cfg) {
			delete(cfg)
			return
		}
		source = cfg
		owned = true
	}
	defer if owned {
		delete(source)
	}
	if load_bank_file(bank, source) {
		fmt.printfln("bank   %s", source)
	} else {
		fmt.eprintfln("bank   could not load %s; using the factory bank", source)
	}
}
