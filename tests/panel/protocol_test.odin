package panel_tests

import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// What the page is told, and in what order; and what happens when it speaks.
//
// The messages are compared byte for byte. The page reads fields by name, so
// a reordering would pass any parsing check, but the order is the contract the
// design states and a reader of a captured log depends on it -- and the order
// of the *messages* is not a detail at all: see `sync`.

PARAMS :: 3

// A host as the protocol sees one: the callbacks a format provides, over an
// instance, recording what it is asked. It does what the real ones do, through
// the same shared procedures.
Fake :: struct {
	inst:      ^Instance,
	values:    [PARAMS]i32,
	// What the per-user bank file would hold now, for a retry to find.
	file:      ^Instance,
	// Whether the file can be written.
	disk_full: bool,
	selected:  [dynamic]panel.Selection,
	banks:     [dynamic]Bank_Call,
	retries:   int,
	discards:  int,
}

Bank_Call :: struct {
	save:   bool,
	origin: panel.Origin,
}

fake_host :: proc(f: ^Fake, with_session := true) -> panel.Host {
	h := panel.Host {
		user        = rawptr(f),
		param_count = PARAMS,
		read_values = proc(user: rawptr, out: []i32) {
			f := (^Fake)(user)
			for i in 0 ..< min(len(out), PARAMS) {
				out[i] = f.values[i]
			}
		},
		read_bank   = proc(user: rawptr) -> string {
			f := (^Fake)(user)
			return patch.slots_write_json(&f.inst.slots, context.temp_allocator)
		},
		set_bank    = proc(user: rawptr, text: string, save: bool, origin: panel.Origin) -> panel.Bank_Result {
			f := (^Fake)(user)
			append(&f.banks, Bank_Call{save, origin})
			write := refuse_to_write if f.disk_full else write_ok
			return panel.session_set_bank(&f.inst.session, &f.inst.slots, text, save, origin, write)
		},
	}
	if with_session {
		h.read_session = proc(user: rawptr) -> panel.Instance_View {
			f := (^Fake)(user)
			return {&f.inst.session, &f.inst.slots}
		}
		h.select = proc(user: rawptr, selection: panel.Selection) {
			f := (^Fake)(user)
			append(&f.selected, selection)
			panel.session_select(&f.inst.session, &f.inst.slots, selection)
		}
		h.restore_retry = proc(user: rawptr) -> bool {
			f := (^Fake)(user)
			f.retries += 1
			found: ^patch.Slots
			if f.file != nil {
				found = &f.file.slots
			}
			_, changed := panel.session_retry(&f.inst.session, &f.inst.slots, found)
			return changed
		}
		h.restore_discard = proc(user: rawptr) {
			f := (^Fake)(user)
			f.discards += 1
			panel.session_discard(&f.inst.session)
		}
	}
	return h
}

fake_destroy :: proc(f: ^Fake) {
	free(f.inst)
	free(f.file)
	delete(f.selected)
	delete(f.banks)
}

// -- sync -----------------------------------------------------------------------

// The reopened editor, after an imported bank and a program have survived: the
// four things it needs, in the order it can use them.
@(test)
sync_answers_bank_then_state_then_patch_then_restore :: proc(t: ^testing.T) {
	f: Fake
	f.values = {5, 6, 7}
	f.inst = new_instance(t, "Factory", {0, 1}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(
		&f.inst.session,
		&f.inst.slots,
		saved_trailer(.Imported, 42, "Alfmeister Bank", "Alfmeister Bank 42", bank_text("Alfmeister Bank", {0, 42})),
	)
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(replies), 4)
	if len(replies) != 4 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"bank","text":"{`), "the first message is not the bank")
	testing.expect(t, ends_with(replies[0], `,"v":1,"origin":"imported","readOnly":false}`), replies[0])
	testing.expect_value(t, replies[1], `{"type":"state","values":[5,6,7]}`)
	testing.expect_value(
		t,
		replies[2],
		`{"type":"patch","name":"Alfmeister Bank 42","index":42,"bank":"Alfmeister Bank","v":1,"origin":"imported"}`,
	)
	testing.expect_value(
		t,
		replies[3],
		`{"type":"restore","v":1,"state":"restored","origin":"imported","bank":"Alfmeister Bank","slot":42,"name":"Alfmeister Bank 42"}`,
	)
}

// An instance nobody has told anything is not on slot 0, and a page told it
// was would load it over the sound that is playing.
@(test)
sync_with_no_selection_sends_no_patch_and_no_restore :: proc(t: ^testing.T) {
	f: Fake
	f.values = {5, 6, 7}
	f.inst = new_instance(t, "Factory", {0, 1}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(replies), 2)
	if len(replies) != 2 {return}
	testing.expect(t, ends_with(replies[0], `,"v":1,"origin":"factory","readOnly":false}`), replies[0])
	testing.expect_value(t, replies[1], `{"type":"state","values":[5,6,7]}`)
}

@(test)
sync_after_a_failed_restore_says_so_without_inventing_a_selection :: proc(t: ^testing.T) {
	f: Fake
	f.values = {5, 6, 7}
	f.inst = new_instance(t, "Factory", {0, 1}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	// The bank that is playing, the sound, and the failure -- and no patch:
	// the sound was kept, and the instance does not know what it is.
	testing.expect_value(t, len(replies), 3)
	if len(replies) != 3 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"bank"`), replies[0])
	testing.expect(t, starts_with(replies[1], `{"type":"state"`), replies[1])
	testing.expect_value(
		t,
		replies[2],
		`{"type":"restore","v":1,"state":"failed","error":"MissingBank","recoverable":true,` +
		`"message":"The bank this sound was saved from is not available.",` +
		`"origin":"user","bank":"My Bank","slot":7,"name":"Glass Pad"}`,
	)
}

// Each of the four failures, as the page reads it: which, whether trying again
// could help, and -- only when the state said -- what it was trying to restore.
@(test)
a_restore_failure_says_which_and_whether_it_can_be_retried :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:        string,
		trailer:     []u8,
		error:       string,
		recoverable: bool,
		identity:    bool,
	} {
		{"missing bank", saved_trailer(.User, 7, "Gone", "Lost"), "MissingBank", true, true},
		{"invalid program", saved_trailer(.User, 5, "Playing", "Lost"), "InvalidProgram", true, true},
		{"rejected", saved_trailer(.User, 7, "Playing", "Lost")[:20], "HostStateRejected", false, false},
		{"newer", newer_trailer(), "StateVersionUnsupported", false, false},
	}
	for c in cases {
		f: Fake
		f.inst = new_instance(t, "Playing", {0, 1, 7}, .Saved)
		defer fake_destroy(&f)
		panel.session_restore(&f.inst.session, &f.inst.slots, c.trailer)
		host := fake_host(&f)

		replies := panel.handle_message(&host, `{"type":"sync"}`)

		message := replies[len(replies) - 1] if len(replies) > 0 else ""
		testing.expectf(t, starts_with(message, `{"type":"restore","v":1,"state":"failed","error":"`), "%s: the last message is %s", c.name, message)
		wanted := strings.concatenate({`"error":"`, c.error, `"`}, context.temp_allocator)
		testing.expectf(t, contains(message, wanted), "%s: %s", c.name, message)
		recoverable := `"recoverable":true` if c.recoverable else `"recoverable":false`
		testing.expectf(t, contains(message, recoverable), "%s: %s", c.name, message)
		testing.expectf(t, contains(message, `"origin":`) == c.identity, "%s: %s", c.name, message)
		testing.expectf(t, contains(message, `"slot":`) == c.identity, "%s: %s", c.name, message)
	}
}

// A host with no memory of what it plays is spoken to as it always was: the
// bank with nothing new in it, then the state.
@(test)
a_host_that_keeps_no_selection_gets_the_messages_it_always_did :: proc(t: ^testing.T) {
	f: Fake
	f.values = {5, 6, 7}
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f, with_session = false)

	replies := panel.handle_message(&host, `{"type":"sync"}`)

	testing.expect_value(t, len(replies), 2)
	if len(replies) != 2 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"bank","text":"{`), replies[0])
	testing.expect(t, ends_with(replies[0], `\n"}`), replies[0])
	testing.expect(t, !contains(replies[0], `"v":1`), "a legacy host was told it speaks version 1")
	testing.expect(t, !contains(replies[0], `"origin"`), "a legacy host was told an origin")
	testing.expect_value(t, replies[1], `{"type":"state","values":[5,6,7]}`)
}

@(test)
names_with_quotes_and_control_characters_stay_one_message :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)
	panel.session_select(
		&f.inst.session,
		&f.inst.slots,
		panel.Selection{origin = .File, name = named("Say \"hi\"\\\n\t\x01"), label = named("Bank \"B\"")},
	)

	view := host.read_session(host.user)
	message, ok := panel.message_patch(view)

	testing.expect(t, ok, "no message")
	testing.expect_value(
		t,
		message,
		`{"type":"patch","name":"Say \"hi\"\\\n\t\u0001","index":null,"bank":"Bank \"B\"","v":1,"origin":"file"}`,
	)
}

// -- the page speaks ------------------------------------------------------------

@(test)
a_select_message_reaches_the_host_as_the_selection_it_names :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "My Bank", {0, 1, 7}, .Saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"select","v":1,"origin":"user","bank":"My Bank","slot":7,"name":"Glass Pad"}`)

	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, len(f.selected), 1)
	if len(f.selected) != 1 {return}
	got := f.selected[0]
	testing.expect_value(t, got.origin, panel.Origin.User)
	testing.expect(t, got.has_slot && got.slot == 7, "the slot was lost")
	testing.expect_value(t, panel.text_get(&got.label), "My Bank")
	testing.expect_value(t, panel.text_get(&got.name), "Glass Pad")
}

@(test)
a_select_message_with_a_null_slot_is_a_selection_with_no_slot :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "My Bank", {0, 1, 7}, .Saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	panel.handle_message(&host, `{"type":"select","v":1,"origin":"file","bank":"","slot":null,"name":"Opened"}`)

	testing.expect_value(t, len(f.selected), 1)
	if len(f.selected) != 1 {return}
	testing.expect(t, !f.selected[0].has_slot, "a null slot became a slot")
	testing.expect_value(t, f.selected[0].origin, panel.Origin.File)
}

@(test)
a_select_message_to_a_host_that_cannot_use_it_is_ignored :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "My Bank", {0, 1, 7}, .Saved)
	defer fake_destroy(&f)
	host := fake_host(&f, with_session = false)

	replies := panel.handle_message(&host, `{"type":"select","v":1,"origin":"user","bank":"My Bank","slot":7,"name":"Glass Pad"}`)

	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, len(f.selected), 0)
}

@(test)
messages_that_are_not_messages_do_nothing :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "My Bank", {0, 1, 7}, .Saved)
	defer fake_destroy(&f)
	host := fake_host(&f)

	for text in ([]string{"", "not json", "[]", "42", `{}`, `{"type":5}`, `{"type":"nonsense"}`, `{"type":"select"`}) {
		replies := panel.handle_message(&host, text)
		testing.expectf(t, len(replies) == 0, "%q was answered", text)
	}
	testing.expect_value(t, len(f.selected), 0)
	testing.expect_value(t, len(f.banks), 0)
}

@(test)
a_retry_that_finds_the_bank_answers_with_the_bank_the_patch_and_the_restore :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	f.file = new_instance(t, "My Bank", {0, 7}, .Saved)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)

	testing.expect_value(t, f.retries, 1)
	testing.expect_value(t, len(replies), 3)
	if len(replies) != 3 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"bank","text":"{`), replies[0])
	testing.expect(t, ends_with(replies[0], `,"v":1,"origin":"user","readOnly":false}`), replies[0])
	testing.expect_value(
		t,
		replies[1],
		`{"type":"patch","name":"My Bank 7","index":7,"bank":"My Bank","v":1,"origin":"user"}`,
	)
	testing.expect_value(
		t,
		replies[2],
		`{"type":"restore","v":1,"state":"restored","origin":"user","bank":"My Bank","slot":7,"name":"My Bank 7"}`,
	)
}

@(test)
a_retry_that_fails_again_answers_with_the_failure_and_nothing_else :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"restore","v":1,"state":"failed","error":"MissingBank"`), replies[0])
}

// A Program Change is a choice like any other: the instance lets go of a failed
// restore, and the page that was still showing it has to be told when it asks.
// Until it was, the retry was not answered at all and the banner waited on it
// for good.
@(test)
a_retry_after_a_program_change_dropped_the_failure_is_answered :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	panel.session_select_slot(&f.inst.session, 1)
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)

	// Where the instance is now, then that it is restoring nothing.
	testing.expect_value(t, len(replies), 2)
	if len(replies) != 2 {return}
	testing.expect_value(
		t,
		replies[0],
		`{"type":"patch","name":"Factory 1","index":1,"bank":"Factory","v":1,"origin":"factory"}`,
	)
	testing.expect_value(t, replies[1], `{"type":"restore","v":1,"state":"notRequested"}`)
	// And nothing was brought back: the identity the Program Change replaced
	// is gone, not parked for the retry to find.
	testing.expect_value(t, f.inst.session.restore, panel.Restore_State.Not_Requested)
	testing.expect(t, !f.inst.session.has_pending, "a retry resurrected the identity a program change dropped")
}

// An instance nobody has told anything has no preset to name, and still owes
// the page an answer: silence is what left it waiting.
@(test)
a_retry_with_nothing_to_retry_and_no_selection_is_answered_with_the_restore_alone :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"restore-retry","v":1}`)

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect_value(t, replies[0], `{"type":"restore","v":1,"state":"notRequested"}`)
}

// What a host that moved itself tells an open panel, which is what
// send_selection posts.
@(test)
a_program_change_is_announced_with_the_patch_alone_once_nothing_is_held_back :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	panel.session_select_slot(&f.inst.session, 1)
	host := fake_host(&f)

	replies := panel.selection_replies(&host)

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect_value(
		t,
		replies[0],
		`{"type":"patch","name":"Factory 1","index":1,"bank":"Factory","v":1,"origin":"factory"}`,
	)
}

// The page takes a patch as the end of any failure it was showing. A state
// load that failed after the Program Change, before the panel was told of it,
// leaves the host holding both; the failure has to follow the patch so that
// the page is not left believing it is gone.
@(test)
an_announced_selection_is_followed_by_a_failure_the_host_still_holds :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	panel.session_select_slot(&f.inst.session, 1)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	host := fake_host(&f)

	replies := panel.selection_replies(&host)

	testing.expect_value(t, len(replies), 2)
	if len(replies) != 2 {return}
	testing.expect(t, starts_with(replies[0], `{"type":"patch","name":"Factory 1"`), replies[0])
	testing.expect_value(
		t,
		replies[1],
		`{"type":"restore","v":1,"state":"failed","error":"MissingBank","recoverable":true,` +
		`"message":"The bank this sound was saved from is not available.",` +
		`"origin":"user","bank":"My Bank","slot":7,"name":"Glass Pad"}`,
	)
}

@(test)
an_instance_with_no_selection_announces_nothing :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)

	testing.expect_value(t, len(panel.selection_replies(&host)), 0)
	host_without_a_session := fake_host(&f, with_session = false)
	testing.expect_value(t, len(panel.selection_replies(&host_without_a_session)), 0)
}

@(test)
a_discard_reaches_the_host_and_is_not_answered :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0, 1, 7}, .Built_In)
	defer fake_destroy(&f)
	panel.session_restore(&f.inst.session, &f.inst.slots, saved_trailer(.User, 7, "My Bank", "Glass Pad", bank_saved = true))
	host := fake_host(&f)

	replies := panel.handle_message(&host, `{"type":"restore-discard","v":1}`)

	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, f.discards, 1)
	// And it is gone: the next time the page asks there is nothing to show.
	again := panel.handle_message(&host, `{"type":"sync"}`)
	testing.expect_value(t, len(again), 2)
}

// -- the bank the page hands over ------------------------------------------------

@(test)
a_bank_message_stores_its_origin_and_is_answered_only_when_it_asked_to_be_kept :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)
	text := bank_text("Alfmeister Bank", {0, 2})

	// Adopted: no answer, and the origin is the host's to keep.
	replies := panel.handle_message(&host, bank_message(text, false, "imported"))
	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, len(f.banks), 1)
	testing.expect_value(t, f.banks[0].origin, panel.Origin.Imported)
	testing.expect(t, !f.banks[0].save, "a bank that did not ask to be saved was saved")
	testing.expect_value(t, f.inst.session.bank_origin, panel.Origin.Imported)

	// A page from before the origin existed.
	replies = panel.handle_message(&host, bank_message(text, false, ""))
	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, f.banks[1].origin, panel.Origin.None)
}

@(test)
a_bank_that_is_kept_is_answered_ok :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, bank_message(bank_text("My Bank", {0, 2}), true, "user"))

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect_value(t, replies[0], `{"type":"bank-saved","v":1,"ok":true,"bank":"My Bank"}`)
}

@(test)
a_bank_that_could_not_be_written_says_so_and_is_still_played :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	f.disk_full = true
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, bank_message(bank_text("My Bank", {0, 2}), true, "user"))

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect_value(
		t,
		replies[0],
		`{"type":"bank-saved","v":1,"ok":false,"error":"PersistenceFailed",` +
		`"message":"The bank is in use but could not be written to disk.","bank":"My Bank"}`,
	)
	testing.expect_value(t, patch.slots_label(&f.inst.slots), "My Bank")
}

@(test)
a_bank_that_is_not_a_bank_says_so_and_changes_nothing :: proc(t: ^testing.T) {
	f: Fake
	f.inst = new_instance(t, "Factory", {0}, .Built_In)
	defer fake_destroy(&f)
	host := fake_host(&f)

	replies := panel.handle_message(&host, bank_message("{ this is not a bank", true, "user"))

	testing.expect_value(t, len(replies), 1)
	if len(replies) != 1 {return}
	testing.expect_value(
		t,
		replies[0],
		`{"type":"bank-saved","v":1,"ok":false,"error":"InvalidBank","message":"The bank could not be read."}`,
	)
	testing.expect_value(t, patch.slots_label(&f.inst.slots), "Factory")
}

// -- helpers ----------------------------------------------------------------------

// A bank message as the page sends it, with the text escaped into the JSON.
bank_message :: proc(text: string, save: bool, origin: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"bank","v":1,`)
	if origin != "" {
		strings.write_string(&b, `"origin":"`)
		strings.write_string(&b, origin)
		strings.write_string(&b, `",`)
	}
	strings.write_string(&b, `"save":`)
	strings.write_string(&b, "true" if save else "false")
	strings.write_string(&b, `,"text":"`)
	for c in transmute([]u8)text {
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

starts_with :: proc(text, prefix: string) -> bool {
	return strings.has_prefix(text, prefix)
}

ends_with :: proc(text, suffix: string) -> bool {
	return strings.has_suffix(text, suffix)
}

contains :: proc(text, part: string) -> bool {
	return strings.contains(text, part)
}
