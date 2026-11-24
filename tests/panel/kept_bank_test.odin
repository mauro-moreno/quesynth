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

// -- going back to the bank the host keeps -------------------------------------

// What the review reproduced: a Write to slot 52 reverted slot 0 from what a
// newer file said to what the project had embedded.
@(test)
returning_to_the_kept_bank_plays_it_again_and_embeds_nothing :: proc(t: ^testing.T) {
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

	// A preset of an imported bank is played, and then one of the kept bank
	// again: what the page sends for a switch of bank, each time to be played.
	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
	panel.handle_message(&host, bank_message(original, false, "user"))
	panel.handle_message(&host, select_message("user", "Alfmeister Bank", 2, "Alfmeister Bank 2"))

	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, f.inst.session.bank_origin, panel.Origin.User)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)
	testing.expect_value(t, bytes_of(files.saved), original)

	// The project names the bank and carries nothing of it.
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)
	trailer, status := panel.trailer_decode(state)
	testing.expect_value(t, status, panel.Trailer_Status.Ok)
	testing.expect(t, !trailer.embedded, "a snapshot of the kept bank was put in the project")
	testing.expect(t, trailer.bank_saved && trailer.has_slot && trailer.slot == 2, "the project does not name the kept bank and its slot")

	// The file moves on elsewhere. What a reload plays is the file as it is
	// then, not what the page showed.
	newer := bank_text("Alfmeister Bank", {0, 2, 7, 52})
	put_file(t, files.saved, newer)
	g: Fake
	g.saved_path = files.saved
	g.inst = kept_instance(files.saved)
	defer fake_destroy(&g)
	testing.expect(t, !f.inst.slots.filled[52], "the playing copy already has slot 52, so this proves nothing")
	restored := panel.session_restore(&g.inst.session, &g.inst.slots, state)
	testing.expect(t, restored.restored, "the state was not restored")
	testing.expect_value(t, restored.program, 2)
	testing.expect(t, g.inst.slots.filled[52], "a slot the file gained is empty after a reload")
	testing.expect_value(t, g.inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, bytes_of(files.saved), newer)
}

// The rule is the label and what the bank holds, so that a bank that only
// shares the name is not taken for it (kept_content_test.odin). What is
// recognised here is a bank of the kept one's name and content; a bank of any
// other name is a bank the host was handed.
@(test)
only_the_bank_the_host_keeps_is_recognised_when_it_comes_back :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		start:    panel.Bank_Source,
		// Between the start and the bank that comes back.
		between:  string,
		save:     bool,
		breaks:   bool,
		returns:  string,
		expected: panel.Bank_Source,
		// What the bank is called after: the kept bank's own, or what the page
		// said it was when the host was only handed it.
		origin:   panel.Origin,
	}
	cases := [?]Case {
		{name = "the user's bank, after another", start = .Saved, between = "Third Party", returns = "Alfmeister Bank", expected = .Saved, origin = .User},
		{name = "the compiled-in bank, after another", start = .Built_In, between = "Third Party", returns = "Factory", expected = .Built_In, origin = .Factory},
		{name = "a bank of another name", start = .Saved, between = "Third Party", returns = "Somebody Else", expected = .Adopted, origin = .User},
		{name = "the same name in another case", start = .Saved, between = "Third Party", returns = "alfmeister bank", expected = .Adopted, origin = .User},
		{name = "the compiled-in bank when a file is what is kept", start = .Saved, between = "Third Party", returns = "Factory", expected = .Adopted, origin = .User},
		{name = "the user's bank when no file is", start = .Built_In, between = "Third Party", returns = "Alfmeister Bank", expected = .Adopted, origin = .User},
		{name = "a save the disk refused", start = .Saved, between = "Third Party", save = true, breaks = true, returns = "Alfmeister Bank", expected = .Saved, origin = .User},
	}
	for c in cases {
		start := "Alfmeister Bank" if c.start == .Saved else "Factory"
		inst := new_instance(t, start, {0, 1, 7}, c.start)
		defer free(inst)
		write := refuse_to_write if c.breaks else write_ok

		panel.session_set_bank(&inst.session, &inst.slots, bank_text(c.between, {0, 1}), c.save, .Imported, write)
		testing.expectf(t, inst.session.bank_source == .Adopted, "%s: %s is not being played as a bank the host was handed", c.name, c.between)

		result := panel.session_set_bank(&inst.session, &inst.slots, bank_text(c.returns, {0, 1, 7}), false, .User, nil)
		testing.expectf(t, result == .Adopted, "%s: the answer is %v", c.name, result)
		testing.expectf(t, inst.session.bank_source == c.expected, "%s: the bank is %v, not %v", c.name, inst.session.bank_source, c.expected)
		testing.expectf(t, inst.session.bank_origin == c.origin, "%s: the origin is %v, not %v", c.name, inst.session.bank_origin, c.origin)
		// The page's copy is what plays, whichever it was.
		testing.expect_value(t, patch.slots_label(&inst.slots), c.returns)

		state := panel.session_trailer(&inst.session, &inst.slots)
		defer delete(state)
		trailer, _ := panel.trailer_decode(state)
		testing.expectf(t, trailer.embedded == (c.expected == .Adopted), "%s: embedded is %v", c.name, trailer.embedded)
	}
}

// Saving a bank makes it the kept one, and the one that was is a bank like any
// other from then on.
@(test)
a_save_moves_which_bank_is_recognised_when_it_comes_back :: proc(t: ^testing.T) {
	inst := new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer free(inst)

	panel.session_set_bank(&inst.session, &inst.slots, bank_text("My Bank", {0, 7}), true, .User, write_ok)
	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Third Party", {0, 1}), false, .Imported, nil)
	panel.session_set_bank(&inst.session, &inst.slots, bank_text("My Bank", {0, 7}), false, .User, nil)
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Saved)

	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Third Party", {0, 1}), false, .Imported, nil)
	panel.session_set_bank(&inst.session, &inst.slots, bank_text("Factory", {0, 1}), false, .Factory, nil)
	testing.expect_value(t, inst.session.bank_source, panel.Bank_Source.Adopted)
}

// A project that embedded a bank replaces the bank the instance started on,
// and the one it started on is the one the host keeps. It has to be known by
// then, or sending it back -- the page learns of it from a Retry, or has it
// open from before -- would be taken for a bank the host was handed.
@(test)
the_kept_bank_is_remembered_across_a_restore_that_replaced_it :: proc(t: ^testing.T) {
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

	scratch := bank_text("Scratch", {0, 1})
	restored := panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 1, "Scratch", "Scratch 1", scratch))
	testing.expect(t, restored.restored, "the embedded bank was not restored")
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)

	panel.handle_message(&host, bank_message(original, false, "user"))

	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)
	testing.expect_value(t, bytes_of(files.saved), original)
}
