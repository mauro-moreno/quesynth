package panel_tests

import "core:encoding/json"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// The bank the host keeps is told by what is in it as well as by what it is
// called.
//
// The page keeps its banks' names unique among the banks it lists, and it does
// not list the kept one after the editor was reopened or the plugin went
// offline and online while another bank played: the host announces only the
// bank it plays. So a New bank, or a file somebody imported, can carry the kept
// bank's exact name -- and a host that took the name for the bank marked it
// persisted, so that the page's next ordinary Write replaced the user's whole
// saved file, and an offline and online brought the file back where the page's
// bank had been (specs/2026-10-27-preset-bank-ux.md 1, 3.4, 5.3, 2.4, 5.6).
// The names a host cuts at forty-eight bytes while the page compares them whole
// make the same collision from two different names.
//
// Every file is a temporary one named in the test, written by the host's own
// write and read back from disk, and every message is the bytes a page sends.

// What a page holds of the bank the host announced, and what it sends back
// when it plays that bank again: the `text` of the bank message a `sync` is
// answered with.
announced_text :: proc(t: ^testing.T, host: ^panel.Host) -> string {
	message := bank_announced(t, host)
	value, err := json.parse_string(message, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	object, _ := value.(json.Object)
	text, _ := object["text"].(json.String)
	return string(text)
}

// A bank the page made, or a file somebody imported, that is called what the
// user's saved bank is and holds other sounds.
@(test)
a_different_bank_with_the_kept_banks_name_is_played_and_not_kept :: proc(t: ^testing.T) {
	patch.factory_prepare()
	for origin in ([?]string{"user", "imported"}) {
		files := bank_files(t)
		defer bank_files_destroy(files)
		original := bank_text("Alfmeister Bank", {0, 2, 7})
		put_file(t, files.saved, original)

		f: Fake
		f.saved_path = files.saved
		f.inst = kept_instance(files.saved)
		defer fake_destroy(&f)
		host := fake_host(&f)

		panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
		testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
		bank_announced(t, &host)

		// The page's own bank, which a host that was told no better would
		// take for the user's.
		made := bank_text("Alfmeister Bank", {1, 3})
		panel.handle_message(&host, bank_message(made, false, origin))
		testing.expectf(t, f.inst.session.bank_source == .Adopted, "%s: the bank is %v, not one the host was handed", origin, f.inst.session.bank_source)
		testing.expect_value(t, f.inst.session.bank_origin, panel.origin_from_word(origin))
		testing.expect_value(t, patch.slots_label(&f.inst.slots), "Alfmeister Bank")
		testing.expect(t, f.inst.slots.filled[3] && !f.inst.slots.filled[2], "the page's bank is not what plays")
		announced := bank_announced(t, &host)
		testing.expectf(t, ends_with(announced, `"readOnly":false,"kept":false}`), "%s: %s", origin, announced)

		// It travels with the project, because nothing else holds it.
		state := panel.session_trailer(&f.inst.session, &f.inst.slots)
		defer delete(state)
		trailer, status := panel.trailer_decode(state)
		testing.expect_value(t, status, panel.Trailer_Status.Ok)
		testing.expectf(t, trailer.embedded && !trailer.bank_saved, "%s: the project does not carry the page's bank", origin)

		// Its next Write, as the page now sends it, is played and not saved.
		panel.handle_message(&host, bank_message(bank_text("Alfmeister Bank", {1, 3, 4}), false, origin))
		testing.expect_value(t, bytes_of(files.saved), original)
		for call, i in f.banks {
			testing.expectf(t, !call.save, "%s: bank message %d asked to be saved", origin, i + 1)
		}

		// The user's own bank, still kept, is recognised when it returns.
		panel.handle_message(&host, bank_message(original, false, "user"))
		testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
		testing.expect_value(t, bytes_of(files.saved), original)
	}
}

// What a page that does ask is entitled to: a write is the person's act, and
// the host does not second-guess a name.
@(test)
an_explicit_save_of_a_bank_with_the_kept_banks_name_is_still_written :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	put_file(t, files.saved, bank_text("Alfmeister Bank", {0, 2, 7}))

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	made := bank_text("Alfmeister Bank", {1, 3})
	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(made, true, "user"))

	testing.expect_value(t, bytes_of(files.saved), made)
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)
}

// Offline and online with that bank playing: the project brings back the
// page's bank, not the file that happens to be called the same.
@(test)
a_project_saved_on_a_bank_with_the_kept_banks_name_restores_that_bank_and_not_the_file :: proc(t: ^testing.T) {
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

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(bank_text("Alfmeister Bank", {1, 3}), false, "imported"))
	panel.handle_message(&host, select_message("imported", "Alfmeister Bank", 3, "Alfmeister Bank 3"))
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)

	g: Fake
	g.saved_path = files.saved
	g.inst = kept_instance(files.saved)
	defer fake_destroy(&g)
	testing.expect(t, g.inst.slots.filled[2], "the instance does not start on the user's bank, so this proves nothing")
	restored := panel.session_restore(&g.inst.session, &g.inst.slots, state)

	testing.expect(t, restored.restored, "the state was not restored")
	testing.expect_value(t, restored.program, 3)
	testing.expect_value(t, patch.slots_label(&g.inst.slots), "Alfmeister Bank")
	testing.expect(t, g.inst.slots.filled[1] && g.inst.slots.filled[3], "the page's bank did not come back")
	testing.expect(t, !g.inst.slots.filled[0] && !g.inst.slots.filled[2] && !g.inst.slots.filled[7], "the user's file came back instead")
	testing.expect_value(t, g.inst.session.bank_source, panel.Bank_Source.Adopted)
	host_again := fake_host(&g)
	announced := bank_announced(t, &host_again)
	testing.expect(t, ends_with(announced, `"readOnly":false,"kept":false}`), announced)
	testing.expect_value(t, bytes_of(files.saved), original)
}

// The file the host kept was reloaded from disk after the page copied it, so
// the page's copy is an older bank than the one the host keeps. Taking it for
// the kept one would be taking it for a bank it is not; the cost is that an
// older copy of the saved bank is a bank the host was handed.
@(test)
a_stale_copy_of_the_kept_bank_stays_a_bank_the_host_was_handed :: proc(t: ^testing.T) {
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

	// The page has the file as it was. Another bank plays, and a restore that
	// names the user's bank has to wait for it.
	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	failed := panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 2, "Alfmeister Bank", "Alfmeister Bank 2", "", true))
	testing.expect_value(t, failed.error, panel.Restore_Error.Missing_Bank)

	// The file gains a slot elsewhere, and a Retry brings it in.
	newer := bank_text("Alfmeister Bank", {0, 2, 7, 52})
	put_file(t, files.saved, newer)
	retried, changed := panel.session_retry_from(&f.inst.session, &f.inst.slots, files.saved)
	testing.expect(t, changed && retried.restored, "the retry did not bring the file in")
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect(t, f.inst.slots.filled[52], "the retry did not read the newer file")

	// The page, which never saw the newer file, plays another bank and then
	// its copy of the saved one.
	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(original, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"readOnly":false,"kept":false}`), announced)
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)
	trailer, _ := panel.trailer_decode(state)
	testing.expect(t, trailer.embedded, "an older copy of the saved bank was taken for the file")

	// The bank the retry brought in is the one that is kept, and is
	// recognised when a page that has it plays it again.
	panel.handle_message(&host, bank_message(newer, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	testing.expect_value(t, bytes_of(files.saved), newer)
}

// A file with no names in it is called Init by the host, which is what the
// page is told and sends back. The host's own copy must hash the same as the
// page's, or the bank would never be recognised again.
@(test)
a_bank_with_nameless_and_padded_patches_is_recognised_when_the_page_sends_it_back :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	original := `{"format":"quesynth.bank","version":1,"name":"Alfmeister Bank","patches":[` +
		`{"parameters":{"osc1 shape":1}},null,` +
		`{"name":"","parameters":{"osc1 shape":2}},` +
		`{"name":"   Padded Lead  ","parameters":{"osc1 shape":3}}]}`
	put_file(t, files.saved, original)

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	// What the page holds is what the host said, which is not what the file
	// says: nothing is called nothing, and nothing is padded.
	held := announced_text(t, &host)
	testing.expect(t, contains(held, `"name": "Init"`), "the nameless patch is not called Init in what the page is told")
	testing.expect(t, contains(held, `"name": "Padded Lead"`), "the padded name is not trimmed in what the page is told")

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(held, false, "user"))

	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":true}`), announced)
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)
	trailer, _ := panel.trailer_decode(state)
	testing.expect(t, !trailer.embedded, "the kept bank was embedded for want of being recognised")
	testing.expect_value(t, bytes_of(files.saved), original)
}

// A label is cut at forty-eight bytes by the host and the page compares it
// whole, so two names the page tells apart are one label here.
@(test)
a_bank_whose_label_shares_forty_eight_bytes_with_the_kept_banks_is_not_the_kept_bank :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	long := "A very long bank name that goes past the forty-eight byte limit"
	other := "A very long bank name that goes past the forty-eight byte limit (copy)"
	original := bank_text(long, {0, 2, 7})
	put_file(t, files.saved, original)

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)
	held := announced_text(t, &host)
	testing.expect_value(t, len(patch.slots_label(&f.inst.slots)), patch.SLOT_NAME_MAX)

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(bank_text(other, {1, 3}), false, "user"))
	testing.expect_value(t, patch.slots_label(&f.inst.slots), long[:patch.SLOT_NAME_MAX])
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":false}`), announced)
	testing.expect_value(t, bytes_of(files.saved), original)

	// What the page was told the kept bank is, sent back, is that bank.
	panel.handle_message(&host, bank_message(held, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
}

// The compiled-in bank is kept while there is no file, and the name Factory is
// as open to a New bank as any other.
@(test)
a_new_bank_called_factory_is_not_the_compiled_in_bank :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)

	f: Fake
	f.saved_path = files.saved
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Built_In)
	factory := announced_text(t, &host)

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(bank_text("Factory", {0, 1}), false, "user"))
	panel.handle_message(&host, select_message("user", "Factory", 1, "Factory 1"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
	announced := bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"user","readOnly":false,"kept":false}`), announced)
	state := panel.session_trailer(&f.inst.session, &f.inst.slots)
	defer delete(state)
	trailer, _ := panel.trailer_decode(state)
	testing.expect(t, trailer.embedded, "the page's bank is not in the project")

	// Offline and online: the page's bank comes back, not the compiled-in one.
	g: Fake
	g.saved_path = files.saved
	g.inst = kept_instance(files.saved)
	defer fake_destroy(&g)
	testing.expect(t, g.inst.slots.filled[2], "the instance does not start on the compiled-in bank, so this proves nothing")
	restored := panel.session_restore(&g.inst.session, &g.inst.slots, state)
	testing.expect_value(t, restored.program, 1)
	testing.expect(t, !g.inst.slots.filled[2], "the compiled-in bank came back instead of the page's")
	testing.expect_value(t, g.inst.session.bank_source, panel.Bank_Source.Adopted)

	// The compiled-in bank itself, as the page was told it, is that bank.
	panel.handle_message(&host, bank_message(factory, false, "factory"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Built_In)
	testing.expect_value(t, f.inst.session.bank_origin, panel.Origin.Factory)
	announced = bank_announced(t, &host)
	testing.expect(t, ends_with(announced, `"origin":"factory","readOnly":false,"kept":true}`), announced)
}

// A save the disk refused wrote nothing, so the bank that was refused is not
// what the file holds.
@(test)
a_save_the_disk_refused_does_not_make_that_bank_the_kept_one :: proc(t: ^testing.T) {
	patch.factory_prepare()
	files := bank_files(t)
	defer bank_files_destroy(files)
	original := bank_text("Alfmeister Bank", {0, 2, 7})
	put_file(t, files.saved, original)

	f: Fake
	f.disk_full = true
	f.inst = kept_instance(files.saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	refused := bank_text("Alfmeister Bank", {1, 3})
	replies := panel.handle_message(&host, bank_message(refused, true, "user"))
	testing.expect(t, len(replies) == 1 && contains(replies[0], `"ok":false`), "the save was not refused")
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(refused, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)

	panel.handle_message(&host, bank_message(original, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)
}

// A save the disk took is what the file holds from then on, and what was there
// before is an older bank that happens to be called the same.
@(test)
a_save_moves_what_is_recognised_to_what_was_written :: proc(t: ^testing.T) {
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

	written := bank_text("Alfmeister Bank", {0, 2, 7, 9})
	panel.handle_message(&host, bank_message(written, true, "user"))
	testing.expect_value(t, bytes_of(files.saved), written)

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(written, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Saved)

	panel.handle_message(&host, bank_message(bank_text("Third Party", {0, 1}), false, "imported"))
	panel.handle_message(&host, bank_message(original, false, "user"))
	testing.expect_value(t, f.inst.session.bank_source, panel.Bank_Source.Adopted)
	testing.expect_value(t, bytes_of(files.saved), written)
}
