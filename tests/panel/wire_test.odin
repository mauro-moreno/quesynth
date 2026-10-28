package panel_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "../../hosts/panel"
import "../../src/patch"

// The wire, held against a file neither side wrote its half of.
//
// protocol_test.odin states the messages in Odin and tests/ui states them in
// JavaScript, each by a different hand, so a field one side spells differently
// would pass both. fixtures/wire-v1.json is the one copy, and
// tests/ui/preset-wire.test.mjs replays it from the page's end. Here it is
// replayed from the host's: each exchange feeds the host the exact strings the
// page was seen to send and requires what comes back to be the exact strings in
// the file, byte for byte, in order. The strings were not produced by this
// code at test time, which is the only reason a match means anything.
//
// The host is the double protocol_test.odin already uses, over the shared
// session procedures every format calls, with a full set of ninety-nine
// parameters: the page reads a `state` by position, so three would prove less.

WIRE_FIXTURE :: #load("fixtures/wire-v1.json", string)

// Every scenario in the file has a test below, so a scenario added to the file
// and left unplayed on this side is a failure, not silence.
WIRE_SCENARIOS :: [?]string {
	"reopen-imported-bank",
	"reopen-user-bank",
	"legacy-state-without-a-selection",
	"restore-fails-missing-bank",
	"restore-fails-invalid-program",
	"restore-fails-host-state-rejected",
	"restore-fails-state-version-unsupported",
	"restore-fails-then-factory-init-is-chosen",
	"restore-retry-finds-the-bank",
	"bank-restored-with-nothing-selected-in-it",
	"write-that-could-not-be-saved",
	"bank-the-host-cannot-read",
	"names-that-need-escaping",
	"host-that-keeps-no-selection",
	"program-change-ends-a-failed-restore",
	"retry-after-the-host-dropped-the-failed-restore",
	"a-selection-and-a-failed-restore-arrive-together",
}

// `using` and first, so that the pointer the callbacks of fake_host receive is
// also a pointer to this.
Wire :: struct {
	using fake: Fake,
	stored:     [patch.PARAMETER_COUNT]i32,
}

@(test)
the_fixture_has_exactly_the_scenarios_this_side_plays :: proc(t: ^testing.T) {
	root := wire_root(t)
	list, _ := root["scenarios"].(json.Array)
	names := WIRE_SCENARIOS
	testing.expect_value(t, len(list), len(names))
	for item in list {
		scenario, _ := item.(json.Object)
		name := wire_str(scenario, "name")
		found := false
		for known in names {
			found ||= known == name
		}
		testing.expectf(t, found, "the fixture has a scenario %q that no test here plays", name)
	}
	testing.expect_value(t, wire_int_of(root["protocol"]), 1)
}

@(test)
reopening_after_an_imported_bank_and_program_survived :: proc(t: ^testing.T) {
	play_wire(t, "reopen-imported-bank")
}

@(test)
reopening_on_the_users_own_bank_and_writing_into_it :: proc(t: ^testing.T) {
	play_wire(t, "reopen-user-bank")
}

@(test)
a_state_saved_before_selections_existed_reports_no_patch_and_no_restore :: proc(t: ^testing.T) {
	play_wire(t, "legacy-state-without-a-selection")
}

@(test)
a_missing_bank_is_reported_retried_and_dismissed :: proc(t: ^testing.T) {
	play_wire(t, "restore-fails-missing-bank")
}

@(test)
an_empty_slot_is_reported_as_an_invalid_program :: proc(t: ^testing.T) {
	play_wire(t, "restore-fails-invalid-program")
}

@(test)
an_unreadable_selection_is_reported_without_inventing_one :: proc(t: ^testing.T) {
	play_wire(t, "restore-fails-host-state-rejected")
}

@(test)
a_selection_from_a_newer_build_is_reported_without_inventing_one :: proc(t: ^testing.T) {
	play_wire(t, "restore-fails-state-version-unsupported")
}

@(test)
choosing_factory_init_after_a_failure_tells_the_host_a_sound_with_no_slot :: proc(t: ^testing.T) {
	play_wire(t, "restore-fails-then-factory-init-is-chosen")
}

@(test)
a_retry_that_finds_the_bank_answers_with_bank_patch_and_restore :: proc(t: ^testing.T) {
	play_wire(t, "restore-retry-finds-the-bank")
}

@(test)
a_bank_restored_with_no_selection_in_it_says_so_and_names_no_slot :: proc(t: ^testing.T) {
	play_wire(t, "bank-restored-with-nothing-selected-in-it")
}

@(test)
a_write_the_disk_refuses_is_answered_and_still_played :: proc(t: ^testing.T) {
	play_wire(t, "write-that-could-not-be-saved")
}

@(test)
a_bank_that_is_not_a_bank_is_answered_without_a_name :: proc(t: ^testing.T) {
	play_wire(t, "bank-the-host-cannot-read")
}

@(test)
names_with_quotes_backslashes_controls_and_non_ascii_arrive_as_one_message :: proc(t: ^testing.T) {
	play_wire(t, "names-that-need-escaping")
}

@(test)
a_host_with_no_session_is_spoken_to_as_it_always_was :: proc(t: ^testing.T) {
	play_wire(t, "host-that-keeps-no-selection")
}

@(test)
a_program_change_lets_go_of_a_failed_restore_and_the_panel_is_told_the_patch :: proc(t: ^testing.T) {
	play_wire(t, "program-change-ends-a-failed-restore")
}

@(test)
a_retry_after_a_silent_program_change_is_answered_with_the_patch_and_no_restore :: proc(t: ^testing.T) {
	play_wire(t, "retry-after-the-host-dropped-the-failed-restore")
}

@(test)
a_patch_is_followed_by_the_failure_the_host_still_holds :: proc(t: ^testing.T) {
	play_wire(t, "a-selection-and-a-failed-restore-arrive-together")
}

// -- playing one scenario -----------------------------------------------------

play_wire :: proc(t: ^testing.T, name: string) {
	scenario, found := wire_scenario(t, name)
	if !found {
		return
	}
	config, _ := scenario["host"].(json.Object)
	exchanges, _ := scenario["exchanges"].(json.Array)
	testing.expectf(t, len(exchanges) > 0, "%s: the scenario has no exchanges", name)

	w := new(Wire)
	defer {
		fake_destroy(&w.fake)
		free(w)
	}
	host := wire_setup(t, w, config)

	for item, n in exchanges {
		exchange, _ := item.(json.Object)
		place := fmt.tprintf("%s, exchange %d", name, n + 1)

		// What an exchange did is what this one did, not the conversation so
		// far.
		clear(&w.selected)
		clear(&w.banks)
		w.retries = 0
		w.discards = 0

		// The host's own turn comes first: what it does by itself, which the
		// page is not asked to have seen before it speaks.
		answered := make([dynamic]string, context.temp_allocator)
		wire_host_does(t, place, &w.fake, &host, exchange, &answered)

		said, _ := exchange["page_to_host"].(json.Array)
		page_does, _ := exchange["page_does"].(json.Object)
		testing.expectf(t, len(said) > 0 || wire_bool(page_does, "idle"), "%s: the page says nothing", place)
		for message in said {
			text, _ := message.(json.String)
			append(&answered, ..panel.handle_message(&host, string(text))[:])
		}

		expected, _ := exchange["host_to_page"].(json.Array)
		wire_expect_messages(t, place, answered[:], expected)
		effect, _ := exchange["host_effect"].(json.Object)
		wire_expect_host(t, place, w, effect)
	}
}

WIRE_HOST_DOES_KEYS :: [?]string{"program_change", "announce"}

// What the host does by itself in an exchange, before it hears the page:
//
//   program_change  a MIDI Program Change reaches the instance on the audio
//                   thread: the session selects the slot and posts nothing
//   announce        the main thread tells an open editor, as send_selection
//                   does after one, and the answer is what it posts
wire_host_does :: proc(
	t: ^testing.T,
	place: string,
	w: ^Fake,
	host: ^panel.Host,
	exchange: json.Object,
	answered: ^[dynamic]string,
) {
	does, has := exchange["host_does"].(json.Object)
	if !has {
		return
	}
	keys := WIRE_HOST_DOES_KEYS
	for key, _ in does {
		known := false
		for k in keys {
			known ||= k == key
		}
		testing.expectf(t, known, "%s: the fixture has a host_does key this test does not play: %s", place, key)
	}
	if slot, has_slot := does["program_change"]; has_slot {
		panel.session_select_slot(&w.inst.session, wire_int_of(slot))
	}
	if wire_bool(does, "announce") {
		append(answered, ..panel.selection_replies(host)[:])
	}
}

// What the host's instance is, as the scenario says.
wire_setup :: proc(t: ^testing.T, w: ^Wire, config: json.Object) -> panel.Host {
	values, _ := config["values"].(json.Array)
	testing.expect_value(t, len(values), patch.PARAMETER_COUNT)
	for value, i in values {
		if i < len(w.stored) {
			w.stored[i] = i32(wire_int_of(value))
		}
	}

	bank, _ := config["bank"].(json.Object)
	w.inst = wire_instance(t, bank, wire_source(wire_str(bank, "source")))
	if file, has_file := config["file"].(json.Object); has_file {
		w.file = wire_instance(t, file, .Saved)
	}
	w.disk_full = wire_bool(config, "disk_full")

	// A Program Change that came before the state did, as one can: the
	// failure then lands on an instance that already has a preset.
	if slot, has_slot := config["selected_slot"]; has_slot {
		panel.session_select_slot(&w.inst.session, wire_int_of(slot))
	}
	if saved, has_saved := config["saved_state"].(json.Object); has_saved {
		panel.session_restore(&w.inst.session, &w.inst.slots, wire_saved_state(saved))
	}
	keeps, has_keeps := config["keeps_selection"].(json.Boolean)
	return wire_host(w, bool(keeps) if has_keeps else true)
}

wire_host :: proc(w: ^Wire, keeps_selection: bool) -> panel.Host {
	h := fake_host(&w.fake, keeps_selection)
	h.param_count = patch.PARAMETER_COUNT
	h.read_values = proc(user: rawptr, out: []i32) {
		w := (^Wire)(user)
		copy(out, w.stored[:])
	}
	// What a format does with a whole patch: it becomes the sound.
	h.set_state = proc(user: rawptr, values: []i32) {
		w := (^Wire)(user)
		copy(w.stored[:], values)
	}
	return h
}

wire_source :: proc(word: string) -> panel.Bank_Source {
	switch word {
	case "built_in":
		return .Built_In
	case "saved":
		return .Saved
	}
	return .Adopted
}

// A bank made out of the document a person would import. Names come from the
// file, so the sounds can be called what the specification calls them, and are
// escaped by the standard library: the document is the input of this test, and
// the code under test is not to write it.
wire_instance :: proc(t: ^testing.T, bank: json.Object, source: panel.Bank_Source) -> ^Instance {
	inst := new(Instance)
	text := wire_bank_text(bank)
	parsed, err := patch.parse_bank_json(transmute([]u8)text)
	testing.expect_value(t, err, patch.Json_Error.None)
	if err == .None {
		patch.slots_load(&inst.slots, parsed)
		patch.destroy_bank(parsed)
	}
	panel.session_init(&inst.session, source)
	return inst
}

wire_bank_text :: proc(bank: json.Object) -> string {
	patches, _ := bank["patches"].(json.Array)
	last := -1
	for item in patches {
		one, _ := item.(json.Object)
		last = max(last, wire_int_of(one["slot"]))
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"format":"quesynth.bank","version":1,"name":`)
	wire_quote(&b, wire_str(bank, "label"))
	strings.write_string(&b, `,"patches":[`)
	for slot in 0 ..= last {
		if slot > 0 {
			strings.write_byte(&b, ',')
		}
		name, filled := "", false
		for item in patches {
			one, _ := item.(json.Object)
			if wire_int_of(one["slot"]) == slot {
				name, filled = wire_str(one, "name"), true
			}
		}
		if !filled {
			strings.write_string(&b, "null")
			continue
		}
		// Each sound differs from every other in two parameters, so two banks
		// that disagree about a slot disagree about the sound as well.
		strings.write_string(&b, `{"name":`)
		wire_quote(&b, name)
		strings.write_string(&b, `,"parameters":{"osc1 shape":`)
		strings.write_int(&b, slot % 4)
		strings.write_string(&b, `,"amp gain":`)
		strings.write_int(&b, 20 + slot)
		strings.write_string(&b, `}}`)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

wire_quote :: proc(b: ^strings.Builder, text: string) {
	quoted, _ := json.marshal(text, allocator = context.temp_allocator)
	strings.write_string(b, string(quoted))
}

// The bytes a format would have saved after the parameter values.
wire_saved_state :: proc(config: json.Object) -> []u8 {
	slot := -1
	if _, has_slot := config["slot"].(json.Integer); has_slot {
		slot = wire_int_of(config["slot"])
	}
	embedded := ""
	if bank, has_bank := config["embeds"].(json.Object); has_bank {
		embedded = wire_bank_text(bank)
	}
	bytes := saved_trailer(
		panel.origin_from_word(wire_str(config, "origin")),
		slot,
		wire_str(config, "bank"),
		wire_str(config, "name"),
		embedded,
		wire_bool(config, "bank_saved"),
	)
	switch wire_str(config, "damage") {
	case "truncated":
		return bytes[:20]
	case "newer_version":
		bytes[4] = 2
	}
	return bytes
}

// -- what is compared ---------------------------------------------------------

wire_expect_messages :: proc(t: ^testing.T, place: string, got: []string, expected: json.Array) {
	if len(got) != len(expected) {
		testing.expectf(t, false, "%s: the host answered %d messages and the fixture has %d", place, len(got), len(expected))
		for text, i in got {
			fmt.eprintfln("  host %d: %s", i, wire_clip(text))
		}
		return
	}
	for item, i in expected {
		want, _ := item.(json.String)
		if got[i] == string(want) {
			continue
		}
		at := wire_first_difference(got[i], string(want))
		testing.expectf(
			t,
			false,
			"%s: message %d differs from the fixture at byte %d\n  host:    %s\n  fixture: %s",
			place,
			i + 1,
			at,
			wire_clip(got[i][at:]),
			wire_clip(string(want)[at:]),
		)
	}
}

wire_first_difference :: proc(a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

wire_clip :: proc(text: string) -> string {
	return text if len(text) <= 160 else strings.concatenate({text[:160], "..."}, context.temp_allocator)
}

WIRE_HOST_EFFECT_KEYS :: [?]string {
	"selected",
	"selection",
	"program",
	"restore",
	"error",
	"pending",
	"retries",
	"discards",
	"banks",
	"bank_label",
	"bank_origin",
	"values",
	"patches",
}

// The observable effect on the instance. A key the exchange does not mention
// is not looked at; one it mentions is held exactly, and one nobody reads is a
// failure, because a misspelt key would otherwise be a check that never runs.
wire_expect_host :: proc(t: ^testing.T, place: string, w: ^Wire, effect: json.Object) {
	keys := WIRE_HOST_EFFECT_KEYS
	for key, _ in effect {
		known := false
		for k in keys {
			known ||= k == key
		}
		testing.expectf(t, known, "%s: the fixture's host_effect has a key this test does not read: %s", place, key)
	}

	if selected, has := effect["selected"].(json.Array); has {
		testing.expectf(t, len(w.selected) == len(selected), "%s: the host was told %d selections, not %d", place, len(w.selected), len(selected))
		for item, i in selected {
			if i >= len(w.selected) {
				break
			}
			want, _ := item.(json.Object)
			got := w.selected[i]
			testing.expect_value(t, panel.origin_word(got.origin), wire_str(want, "origin"))
			testing.expect_value(t, panel.text_get(&got.label), wire_str(want, "bank"))
			testing.expect_value(t, panel.text_get(&got.name), wire_str(want, "name"))
			wire_expect_slot(t, place, got.has_slot, got.slot, want["slot"])
		}
	}

	if want, has := effect["selection"]; has {
		session := &w.inst.session
		if _, is_null := want.(json.Null); is_null {
			testing.expectf(t, !panel.selection_known(&session.selection), "%s: the instance claims to know what it plays", place)
		} else if object, ok := want.(json.Object); ok {
			testing.expectf(t, panel.selection_known(&session.selection), "%s: the instance has no selection", place)
			view := panel.selection_view(&session.selection, &w.inst.slots)
			testing.expect_value(t, panel.origin_word(view.origin), wire_str(object, "origin"))
			testing.expect_value(t, view.label, wire_str(object, "bank"))
			testing.expect_value(t, view.name, wire_str(object, "name"))
			wire_expect_slot(t, place, view.has_slot, view.slot, object["slot"])
		}
	}

	// The program a host would report: the slot it is on, or none.
	if want, has := effect["program"]; has {
		sel := &w.inst.session.selection
		wire_expect_slot(t, place, sel.has_slot, sel.slot, want)
	}

	if want, has := effect["restore"].(json.String); has {
		got: string
		switch w.inst.session.restore {
		case .Not_Requested:
			got = "notRequested"
		case .Restored:
			got = "restored"
		case .Failed:
			got = "failed"
		}
		testing.expect_value(t, got, string(want))
	}
	if want, has := effect["error"].(json.String); has {
		testing.expect_value(t, panel.restore_error_word(w.inst.session.restore_error), string(want))
	}
	if want, has := effect["pending"].(json.Boolean); has {
		testing.expectf(t, w.inst.session.has_pending == bool(want), "%s: a failed restore is held for a retry: %v, not %v", place, w.inst.session.has_pending, bool(want))
	}
	if want, has := effect["retries"]; has {
		testing.expect_value(t, w.retries, wire_int_of(want))
	}
	if want, has := effect["discards"]; has {
		testing.expect_value(t, w.discards, wire_int_of(want))
	}

	if banks, has := effect["banks"].(json.Array); has {
		testing.expectf(t, len(w.banks) == len(banks), "%s: the host was handed %d banks, not %d", place, len(w.banks), len(banks))
		for item, i in banks {
			if i >= len(w.banks) {
				break
			}
			want, _ := item.(json.Object)
			got := w.banks[i]
			testing.expectf(t, got.save == wire_bool(want, "save"), "%s: bank %d save: %v", place, i + 1, got.save)
			// A page from before origins existed says none, which is not
			// the word for a session.
			testing.expect_value(t, got.origin, panel.origin_from_word(wire_str(want, "origin")))
		}
	}
	if want, has := effect["bank_label"].(json.String); has {
		testing.expect_value(t, patch.slots_label(&w.inst.slots), string(want))
	}
	if want, has := effect["bank_origin"].(json.String); has {
		testing.expect_value(t, panel.origin_word(w.inst.session.bank_origin), string(want))
	}

	if values, has := effect["values"].(json.Array); has {
		testing.expect_value(t, len(values), patch.PARAMETER_COUNT)
		for value, i in values {
			if i < len(w.stored) {
				testing.expectf(t, int(w.stored[i]) == wire_int_of(value), "%s: parameter %d is %d, not %d", place, i, w.stored[i], wire_int_of(value))
			}
		}
	}

	// What the playing bank holds in a slot: the page wrote it as a document,
	// and this is what the host read out of that document.
	if patches, has := effect["patches"].(json.Array); has {
		for item in patches {
			want, _ := item.(json.Object)
			slot := wire_int_of(want["slot"])
			stored, filled := patch.slots_patch(&w.inst.slots, slot)
			testing.expectf(t, filled, "%s: slot %d of the playing bank is empty", place, slot)
			testing.expect_value(t, patch.slots_name(&w.inst.slots, slot), wire_str(want, "name"))
			values, _ := want["values"].(json.Array)
			testing.expect_value(t, len(values), patch.PARAMETER_COUNT)
			for value, i in values {
				if i < len(stored) {
					testing.expectf(t, int(stored[i]) == wire_int_of(value), "%s: slot %d parameter %d is %d, not %d", place, slot, i, stored[i], wire_int_of(value))
				}
			}
		}
	}
}

// A slot that is an integer, or null for none: the two are different words on
// the wire and one thing here.
wire_expect_slot :: proc(t: ^testing.T, place: string, has_slot: bool, slot: int, want: json.Value) {
	if _, is_null := want.(json.Null); is_null {
		testing.expectf(t, !has_slot, "%s: a slot appeared where the fixture has null", place)
		return
	}
	testing.expectf(t, has_slot && slot == wire_int_of(want), "%s: slot is %v/%d, the fixture says %v", place, has_slot, slot, want)
}

// -- reading the fixture ------------------------------------------------------

wire_root :: proc(t: ^testing.T) -> json.Object {
	// Integers as integers: a slot of 42 is not a float that happens to be one.
	value, err := json.parse_string(WIRE_FIXTURE, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, _ := value.(json.Object)
	return root
}

wire_scenario :: proc(t: ^testing.T, name: string) -> (scenario: json.Object, found: bool) {
	list, _ := wire_root(t)["scenarios"].(json.Array)
	for item in list {
		candidate, _ := item.(json.Object)
		if wire_str(candidate, "name") == name {
			return candidate, true
		}
	}
	testing.expectf(t, false, "the fixture has no scenario called %q", name)
	return {}, false
}

wire_str :: proc(object: json.Object, key: string) -> string {
	text, _ := object[key].(json.String)
	return string(text)
}

wire_bool :: proc(object: json.Object, key: string) -> bool {
	flag, _ := object[key].(json.Boolean)
	return bool(flag)
}

wire_int_of :: proc(value: json.Value) -> int {
	#partial switch n in value {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return min(int)
}
