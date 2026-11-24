#+build !windows
package panel_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// The procs a plugin really calls -- bank_load when an instance is made,
// session_retry_saved from its editor, bank_write from the panel -- find the
// bank through the environment and the host's working directory. A test cannot
// change either without changing it for every test running beside it, and the
// old place for the bank is the working directory itself.
//
// So they are run in a process of their own: this binary again, with the
// environment and working directory a host gives a plugin, and a home that
// holds nothing. The same test is the parent and the child, told apart by one
// variable, which is how it can run with no more than the test runner.
//
// Not on Windows, where the old place is not looked at (checked by name in
// bank_test.odin) and where the bank is under LOCALAPPDATA.
//
// Two cases, because the old place was two places: beside the working
// directory, and under LOCALAPPDATA for whoever's environment set it, which
// main preferred to the working directory on every platform. Each child runs
// every test in the package, there being no way to ask the runner for one, so
// each test says which case it is a child for and stays out of the others --
// or a child would start children of its own, without end.

CHILD :: "QUESYNTH_TEST_BANK_CHILD"
CASE :: "QUESYNTH_TEST_BANK_CASE"

@(test)
a_plugin_started_beside_an_old_bank_plays_it_and_leaves_it_as_it_was :: proc(t: ^testing.T) {
	if root := os.get_env(CHILD, context.temp_allocator); root != "" {
		if os.get_env(CASE, context.temp_allocator) == "working-directory" {
			in_the_host(t, root)
		}
		return
	}

	root, made := os.make_directory_temp("", "quesynth-bank-host-*", context.allocator)
	if !testing.expect_value(t, made, nil) {
		return
	}
	defer {
		os.remove_all(root)
		delete(root)
	}
	home := path_in(root, "home")
	working := path_in(root, "cwd")
	testing.expect_value(t, os.make_directory_all(home), nil)
	original := bank_text("My Linux Bank", {0, 2, 7})
	put_file(t, path_in(working, "user-bank.json"), original)

	// What a host's environment amounts to here: a home with no data directory
	// in it, and neither XDG_DATA_HOME nor LOCALAPPDATA to say otherwise.
	in_a_host_process(t, root, "working-directory", home, working, "")

	// From out here: the old file is as it was, and what was saved is where a
	// bank belongs.
	testing.expect_value(t, bytes_of(path_in(working, "user-bank.json")), original)
	testing.expect_value(t, bytes_of(path_in(home, ".local", "share", "Quesynth", "user-bank.json")), bank_text("My Linux Bank", {0, 2, 7, 9}))
}

// The same, for somebody on Linux or macOS whose environment sets
// LOCALAPPDATA: main kept the bank under it there, in preference to the
// working directory, and a build that looked only beside the working directory
// played the factory bank over it. A different bank beside the working
// directory is there to say that the variable decides, as it did.
@(test)
a_plugin_whose_environment_sets_localappdata_plays_the_bank_it_kept_there :: proc(t: ^testing.T) {
	if root := os.get_env(CHILD, context.temp_allocator); root != "" {
		if os.get_env(CASE, context.temp_allocator) == "localappdata" {
			in_the_host(t, root)
		}
		return
	}

	root, made := os.make_directory_temp("", "quesynth-bank-host-*", context.allocator)
	if !testing.expect_value(t, made, nil) {
		return
	}
	defer {
		os.remove_all(root)
		delete(root)
	}
	home := path_in(root, "home")
	working := path_in(root, "cwd")
	local := path_in(root, "local")
	testing.expect_value(t, os.make_directory_all(home), nil)
	original := bank_text("My Linux Bank", {0, 2, 7})
	put_file(t, path_in(local, "Quesynth", "user-bank.json"), original)
	decoy := bank_text("Beside The Working Directory", {0, 1})
	put_file(t, path_in(working, "user-bank.json"), decoy)

	in_a_host_process(t, root, "localappdata", home, working, local)

	testing.expect_value(t, bytes_of(path_in(local, "Quesynth", "user-bank.json")), original)
	testing.expect_value(t, bytes_of(path_in(working, "user-bank.json")), decoy)
	testing.expect_value(t, bytes_of(path_in(home, ".local", "share", "Quesynth", "user-bank.json")), bank_text("My Linux Bank", {0, 2, 7, 9}))
}

// This binary again, as a host would start a plugin.
in_a_host_process :: proc(t: ^testing.T, root, case_name, home, working, local: string) {
	exe, found := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, found, nil) {
		return
	}
	defer delete(exe)

	env := make([dynamic]string, context.temp_allocator)
	append(&env, fmt.tprintf("HOME=%s", home), fmt.tprintf("%s=%s", CHILD, root), fmt.tprintf("%s=%s", CASE, case_name))
	if local != "" {
		append(&env, fmt.tprintf("LOCALAPPDATA=%s", local))
	}
	if tmp := os.get_env("TMPDIR", context.temp_allocator); tmp != "" {
		append(&env, fmt.tprintf("TMPDIR=%s", tmp))
	}
	state, stdout, stderr, ran := os.process_exec(os.Process_Desc{working_dir = working, command = {exe}, env = env[:]}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, ran, nil)
	// The child runs every test in the package, so its exit code is about all
	// of them. What it says about this one is whether it got to the end with
	// nothing wrong.
	testing.expectf(t, bytes_of(path_in(root, "ran")) == "ok", "the host process did not finish cleanly (exit %d):\n%s%s", state.exit_code, stdout, stderr)
}

// What a plugin does, in order, with the old bank the only one there is.
in_the_host :: proc(t: ^testing.T, root: string) {
	patch.factory_prepare()

	// An instance is made.
	slots := new(patch.Slots)
	defer free(slots)
	testing.expect_value(t, panel.bank_load(slots), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_label(slots), "My Linux Bank")
	testing.expect_value(t, patch.slots_name(slots, 7), "My Linux Bank 7")

	// A project names that bank, and the bank is not the one this instance
	// started with; the editor's retry looks where the start did.
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)
	panel.session_restore(&inst.session, &inst.slots, saved_trailer(.User, 7, "My Linux Bank", "My Linux Bank 7", bank_saved = true))
	testing.expect_value(t, inst.session.restore_error, panel.Restore_Error.Missing_Bank)
	result, changed := panel.session_retry_saved(&inst.session, &inst.slots)
	testing.expect(t, result.restored && changed, "the retry did not find the bank the host kept it in")

	// The panel writes a patch, and the bank is kept.
	testing.expect(t, panel.bank_write(bank_text("My Linux Bank", {0, 2, 7, 9})), "the bank was not written")

	// And the next instance has it, from the place it was written to.
	again := new(patch.Slots)
	defer free(again)
	testing.expect_value(t, panel.bank_load(again), panel.Bank_Source.Saved)
	testing.expect_value(t, patch.slots_name(again, 9), "My Linux Bank 9")

	if t.error_count == 0 {
		put_file(t, path_in(root, "ran"), "ok")
	}
}

path_in :: proc(parts: ..string) -> string {
	joined, _ := filepath.join(parts, context.temp_allocator)
	return joined
}
