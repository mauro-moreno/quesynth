package panel_tests

import "core:fmt"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// Which bank the host keeps, and saying so.
//
// A plugin plays whatever bank the page hands it and keeps one: the per-user
// file, which every instance reads at start. The page used to take any bank
// the host announced as origin user for the one it keeps, so a New bank or a
// Duplicate made in the page -- which the host only plays, and which comes
// back announced as user after the editor is reopened -- was offered as the
// kept one, and the next ordinary Write into it replaced the user's whole file
// (specs/2026-10-27-preset-bank-ux.md 1, 3.4, 5.3, 2.4: a persisted bank must
// not be replaced without an explicit act). So the host says it: `kept`.
//
// Returning to the kept bank after playing another is the other half. The page
// sends it to be played, not saved, like every switch; a host that took that
// for a bank it was merely handed embedded a snapshot of the user's file in the
// project, and a reload then played the snapshot instead of the file.
//
// Every file here is a temporary one named in the test, written by the host's
// own write and read back from disk, and every message is the bytes a page
// sends.

// The instance a plugin starts as on a machine with a saved bank: out of it.
kept_instance :: proc(path: string) -> ^Instance {
	inst := new(Instance)
	panel.session_init(&inst.session, panel.bank_load_from(path, &inst.slots))
	return inst
}

// What the page says when it has selected a slot of the bank it plays.
select_message :: proc(origin: string, bank: string, slot: int, name: string) -> string {
	return fmt.tprintf(`{{"type":"select","v":1,"origin":"%s","bank":"%s","slot":%d,"name":"%s"}}`, origin, bank, slot, name)
}

// The first message a `sync` is answered with: the bank.
bank_announced :: proc(t: ^testing.T, host: ^panel.Host) -> string {
	replies := panel.handle_message(host, `{"type":"sync"}`)
	if !testing.expect(t, len(replies) > 0, "sync was not answered") {
		return ""
	}
	testing.expect(t, starts_with(replies[0], `{"type":"bank"`), replies[0])
	return replies[0]
}

// What the review reproduced in REAPER 7.82: New bank, Write, hide and show the
// editor, Write -- and the user's file was Scratch.
@(test)
a_bank_the_page_made_is_played_and_not_kept_across_a_reopen_and_a_state_load :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	original := bank_text("Alfmeister Bank", {0, 2, 7})
	put_file(t, files.saved, original)

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	// The editor opens on the user's own bank, which is the one the host keeps.
	opened := bank_announced(t, &host)
	testing.expect(t, ends_with(opened, `,"v":1,"origin":"user","readOnly":false,"kept":true}`), opened)

	// New bank, and a Write into it: both sent to be played and not saved.
	panel.handle_message(&host, bank_message(bank_text("Scratch", {0}), false, "user"))
	panel.handle_message(&host, select_message("user", "Scratch", 0, "Scratch 0"))
	panel.handle_message(&host, bank_message(bank_text("Scratch", {0, 1}), false, "user"))
	testing.expect_value(t, bytes_of(files.saved), original)

	// The editor is hidden and shown. The host says what it plays, and that it
	// does not keep it, though it calls it the user's.
	reopened := bank_announced(t, &host)
	testing.expect(t, ends_with(reopened, `,"v":1,"origin":"user","readOnly":false,"kept":false}`), reopened)

	// The next Write, as the page sends it now, writes nothing to the file.
	panel.handle_message(&host, bank_message(bank_text("Scratch", {0, 1, 2}), false, "user"))
	testing.expect_value(t, bytes_of(files.saved), original)
	for call, i in f.banks {
		testing.expectf(t, !call.save, "bank message %d asked to be saved", i + 1)
	}

	// The project is saved and opened again, as offline and online does it.
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)
	g: Fake
	g.saved_path = files.saved
	g.inst = kept_instance(files.saved)
	defer fake_destroy(&g)
	testing.expect(t, panel.session_restore(&g.inst.session, &g.inst.slots, state).requested, "the state carried nothing")
	testing.expect_value(t, patch.slots_label(&g.inst.slots), "Scratch")
	testing.expect_value(t, g.inst.session.bank_source, panel.Bank_Source.Adopted)
	host_again := fake_host(&g)
	back := bank_announced(t, &host_again)
	testing.expect(t, ends_with(back, `,"v":1,"origin":"user","readOnly":false,"kept":false}`), back)

	panel.handle_message(&host_again, bank_message(bank_text("Scratch", {0, 1, 2, 3}), false, "user"))
	testing.expect_value(t, bytes_of(files.saved), original)
}

// A Write the person asked for into the bank the host keeps is still kept, and
// from then on that bank is the one it keeps.
@(test)
a_bank_that_was_saved_is_the_one_the_host_keeps_from_then_on :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	put_file(t, files.saved, bank_text("Alfmeister Bank", {0, 2, 7}))

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	written := bank_text("Alfmeister Bank", {0, 2, 7, 9})
	replies := panel.handle_message(&host, bank_message(written, true, "user"))
	testing.expect_value(t, len(replies), 1)
	testing.expect_value(t, bytes_of(files.saved), written)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)

	// Keep, on a bank that was only being played, makes that the kept one.
	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	announced = bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"imported","readOnly":false,"kept":false}`), announced)
	third := bank_text("Third Party", {0, 1, 2})
	panel.handle_message(&host, bank_message(third, true, "imported"))
	testing.expect_value(t, bytes_of(files.saved), third)
	announced = bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)
}
