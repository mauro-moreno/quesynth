#+build windows, linux
package vst3_tests

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"
import "../../src/vst3"
import synth "../../hosts/vst3"

// Which bank the plugin keeps, as the page is told it and as a project carries
// it. A bank the person made in the page is played by the host and kept by
// nobody, however the page calls it, so after the editor is reopened or the
// plugin goes offline and online the host says it is not kept (`kept` false) and
// the page's next write of it is sent to be played and not saved. And the bank
// the host does keep, played again after another, is not copied into the
// project: the project names the file, and a reload plays the file as it is by
// then. Both were wrong in REAPER 7.82, and both ended with the user's saved
// bank overwritten by a stale or a scratch copy.
//
// The per-user file is a temporary one named here and handed to the host's own
// write, so nothing is written to the bank on the machine running the test, and
// the file is read back from disk to see whether anything was written to it.

@(private = "file", thread_local)
kept_file: string

@(private = "file")
write_kept_file :: proc(text: string) -> bool {
	return panel.bank_write_to(kept_file, text)
}

// What the editor's host does with a bank, against the test's file.
@(private = "file")
set_bank_in_the_file :: proc(user: rawptr, text: string, save: bool, origin: panel.Origin) -> panel.Bank_Result {
	ed := (^synth.Editor)(user)
	return panel.session_set_bank(&ed.plugin.session, &ed.plugin.slots, text, save, origin, write_kept_file)
}

// The per-user bank file of a machine that has one.
@(private = "file")
machine_with_a_saved_bank :: proc(t: ^testing.T, text: string) -> (root: string) {
	root, _ = os.make_directory_temp("", "quesynth-kept-test-*", context.allocator)
	kept_file, _ = filepath.join({root, "user-bank.json"}, context.allocator)
	testing.expect_value(t, os.write_entire_file(kept_file, transmute([]u8)text), nil)
	return
}

@(private = "file")
file_text :: proc() -> string {
	data, _ := os.read_entire_file(kept_file, context.temp_allocator)
	return string(data)
}

// An instance the way the plugin starts on that machine: out of the file.
@(private = "file")
start_on_the_saved_bank :: proc() -> ^synth.Plugin {
	p := synth.make_plugin()
	if p == nil {
		return nil
	}
	panel.session_init(&p.session, panel.bank_load_from(kept_file, &p.slots))
	return p
}

// The editor's host over the plugin. The editor itself is the caller's, so
// that it outlives the host.
@(private = "file")
editor_for :: proc(ed: ^synth.Editor) -> panel.Host {
	host := synth.editor_host(ed)
	host.set_bank = set_bank_in_the_file
	return host
}

// The bytes a page sends for a bank.
@(private = "file")
page_bank :: proc(text: string, save: bool, origin: string) -> string {
	post, _ := json.marshal(
		struct {
			type:   string,
			text:   string,
			save:   bool,
			v:      int,
			origin: string,
		}{"bank", text, save, 1, origin},
		allocator = context.temp_allocator,
	)
	return string(post)
}

@(private = "file")
announced_bank :: proc(t: ^testing.T, host: ^panel.Host) -> string {
	replies := panel.handle_message(host, `{"type":"sync"}`)
	if !testing.expect(t, len(replies) > 0, "sync was not answered") {
		return ""
	}
	return replies[0]
}

@(test)
a_bank_the_page_made_is_not_kept_after_a_reopen_or_an_offline_online :: proc(t: ^testing.T) {
	patch.factory_prepare()
	original := bank_document("Alfmeister Bank", {0, 2, 7})
	root := machine_with_a_saved_bank(t, original)
	defer os.remove_all(root)

	before := start_on_the_saved_bank()
	if before == nil {return}
	defer synth.release(before)
	ed := synth.Editor {
		plugin = before,
	}
	host := editor_for(&ed)
	opened := announced_bank(t, &host)
	testing.expect(t, strings.has_suffix(opened, `,"v":1,"origin":"user","readOnly":false,"kept":true}`), opened)

	// New bank and a Write into it, as the page sends them: to be played.
	panel.handle_message(&host, page_bank(bank_document("Scratch", {0}), false, "user"))
	panel.handle_message(&host, select_in_the_page("user", "Scratch", 0, "Scratch 0"))
	panel.handle_message(&host, page_bank(bank_document("Scratch", {0, 1}), false, "user"))
	testing.expect_value(t, file_text(), original)

	// The editor is hidden and shown.
	reopened := announced_bank(t, &host)
	testing.expect(t, strings.has_suffix(reopened, `,"v":1,"origin":"user","readOnly":false,"kept":false}`), reopened)
	panel.handle_message(&host, page_bank(bank_document("Scratch", {0, 1, 2}), false, "user"))
	testing.expect_value(t, file_text(), original)

	// Offline and online: the state is saved, and a new instance loads it.
	saved := save_session(t, before)
	defer delete(saved)
	after := start_on_the_saved_bank()
	if after == nil {return}
	defer synth.release(after)
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, patch.slots_label(&after.slots), "Scratch")
	testing.expect_value(t, after.session.bank_source, panel.Bank_Source.Adopted)

	opened_again := synth.Editor {
		plugin = after,
	}
	host_again := editor_for(&opened_again)
	back := announced_bank(t, &host_again)
	testing.expect(t, strings.has_suffix(back, `,"v":1,"origin":"user","readOnly":false,"kept":false}`), back)
	panel.handle_message(&host_again, page_bank(bank_document("Scratch", {0, 1, 2, 3}), false, "user"))
	testing.expect_value(t, file_text(), original)
}

@(test)
the_kept_bank_played_again_after_another_is_named_by_the_project_and_not_copied_into_it :: proc(t: ^testing.T) {
	patch.factory_prepare()
	original := bank_document("Alfmeister Bank", {0, 2, 7})
	root := machine_with_a_saved_bank(t, original)
	defer os.remove_all(root)

	before := start_on_the_saved_bank()
	if before == nil {return}
	defer synth.release(before)
	ed := synth.Editor {
		plugin = before,
	}
	host := editor_for(&ed)

	// A preset of an imported bank, then one of the kept bank again, each sent
	// to be played and not saved.
	panel.handle_message(&host, page_bank(bank_document("Third Party", {0, 1}), false, "imported"))
	testing.expect_value(t, before.session.bank_source, panel.Bank_Source.Adopted)
	panel.handle_message(&host, page_bank(original, false, "user"))
	panel.handle_message(&host, select_in_the_page("user", "Alfmeister Bank", 2, "Alfmeister Bank 2"))
	testing.expect_value(t, before.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, file_text(), original)

	saved := save_session(t, before)
	defer delete(saved)
	trailer, status := panel.trailer_decode(saved[synth.STATE_SIZE:])
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded && trailer.bank_saved, "the project carries a copy of the kept bank instead of naming it")

	// The file gains a slot elsewhere. The project is opened: what plays is the
	// file as it is now.
	newer := bank_document("Alfmeister Bank", {0, 2, 7, 52})
	testing.expect_value(t, os.write_entire_file(kept_file, transmute([]u8)newer), nil)
	after := start_on_the_saved_bank()
	if after == nil {return}
	defer synth.release(after)
	testing.expect(t, !before.slots.filled[52], "the playing copy has slot 52, so this proves nothing")
	testing.expect_value(t, load_session(after, saved), vst3.RESULT_OK)
	testing.expect_value(t, after.session.restore, panel.Restore_State.Restored)
	testing.expect_value(t, after.program, i32(2))
	testing.expect(t, after.slots.filled[52], "a slot the file gained is empty after the reload")
	testing.expect_value(t, after.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, file_text(), newer)
}
