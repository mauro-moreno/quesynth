#+build linux
package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "../../hosts/standalone/mcp"

// The MCP's QCP client against a stand-in daemon: what it sends, what it makes
// of each reply, and that no failure ever makes it send a mutation twice.

@(private = "file")
inspect_canned := [?]Canned {
	{
		"state.snapshot",
		"ok revision=3 count=2\nid=filter.cutoff value=64\nid=filter.resonance value=10",
	},
	{
		"patch.current",
		"ok slot=-1 bank_rev=0 revision=3 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=Lead  Pad ",
	},
	{
		"parameter.list",
		"ok count=2\nid=filter.cutoff group=filter index=19 min=0 max=127 default=81 label=Cutoff\nid=filter.resonance group=filter index=20 min=0 max=127 default=0 label=Resonance",
	},
	{"parameter.set_many", "ok count=2 revision=4"},
}

@(private = "file")
STATE_JSON :: `{"fields":"revision=3 count=2","lines":["id=filter.cutoff value=64","id=filter.resonance value=10"]}`
@(private = "file")
PATCH_JSON :: `{"fields":"slot=-1 bank_rev=0 revision=3 source=none archive_rev=0 archive_bank=-1 archive_patch=-1","lines":["bank=","name=Lead  Pad "]}`
@(private = "file")
PARAMETERS_JSON :: `{"fields":"count=2","lines":["id=filter.cutoff group=filter index=19 min=0 max=127 default=81 label=Cutoff","id=filter.resonance group=filter index=20 min=0 max=127 default=0 label=Resonance"]}`

@(private = "file")
APPLY :: `{"expected_revision":3,"parameters":[{"id":"filter.cutoff","value":90},{"id":"filter.resonance","value":5}]}`

@(test)
test_inspect_synth_reads_state_patch_and_registry_in_order_and_returns_them_verbatim :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	s := ready()
	text, is_error := call_tool(&s, "inspect_synth", `{}`, standin.path)
	standin_stop(&standin)
	testing.expect(t, !is_error, text)
	want := `{"parameters":` + PARAMETERS_JSON + `,"patch":` + PATCH_JSON + `,"revision":3,"state":` + STATE_JSON + `}`
	testing.expect_value(t, text, want)
	testing.expect_value(t, len(standin_commands(&standin)), 3)
	commands := standin_commands(&standin)
	testing.expect_value(t, commands[0], "state.snapshot")
	testing.expect_value(t, commands[1], "patch.current")
	testing.expect_value(t, commands[2], "parameter.list")
}

@(test)
test_the_resources_read_the_daemon_and_nothing_else :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	s := ready()
	parameters := read_resource(&s, "quesynth://parameters", standin.path)
	patch := read_resource(&s, "quesynth://patch", standin.path)
	standin_stop(&standin)
	testing.expect_value(t, parameters, PARAMETERS_JSON)
	testing.expect_value(t, patch, `{"patch":` + PATCH_JSON + `,"revision":3,"state":` + STATE_JSON + `}`)
	commands := standin_commands(&standin)
	testing.expect_value(t, len(commands), 3)
	testing.expect_value(t, commands[0], "parameter.list")
	testing.expect_value(t, commands[1], "state.snapshot")
	testing.expect_value(t, commands[2], "patch.current")
}

@(test)
test_a_reply_arriving_in_pieces_is_reassembled :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	standin_set(&standin, .Trickle)
	s := ready()
	text, is_error := call_tool(&s, "apply_parameters", APPLY, standin.path)
	standin_stop(&standin)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":2,"revision":4}`)
}

@(test)
test_apply_parameters_sends_one_set_many_with_the_revision_and_every_pair_in_order :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	s := ready()
	text, is_error := call_tool(&s, "apply_parameters", APPLY, standin.path)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":2,"revision":4}`)

	// Zero is a revision; duplicates and order go through untouched; integers
	// spelled as floats are sent as integers.
	call_tool(
		&s,
		"apply_parameters",
		`{"expected_revision":0,"parameters":[{"id":"filter.resonance","value":1.0},{"id":"filter.cutoff","value":1e2},{"id":"filter.resonance","value":-7}]}`,
		standin.path,
	)
	standin_stop(&standin)
	commands := standin_commands(&standin)
	testing.expect_value(t, len(commands), 2)
	testing.expect_value(t, commands[0], "parameter.set_many expected_revision=3 filter.cutoff 90 filter.resonance 5")
	testing.expect_value(
		t,
		commands[1],
		"parameter.set_many expected_revision=0 filter.resonance 1 filter.cutoff 100 filter.resonance -7",
	)
}

@(test)
test_a_stale_revision_is_reported_with_the_daemons_own_code_and_current_revision :: proc(t: ^testing.T) {
	canned := [?]Canned{{"parameter.set_many", "err revision_conflict current_revision=7"}}
	standin: Standin
	standin_start(&standin, canned[:])
	s := ready()
	code, message := tool_error(&s, "apply_parameters", APPLY, standin.path)
	standin_stop(&standin)
	testing.expect_value(t, code, "revision_conflict")
	testing.expect_value(t, message, "current_revision=7")
}

@(test)
test_every_daemon_error_token_reaches_the_client_verbatim :: proc(t: ^testing.T) {
	tokens := []string {
		"invalid_payload",
		"unknown_parameter",
		"out_of_range",
		"daemon_not_ready",
		"transaction_failed",
		"unsupported_version",
		"unknown_command",
		"internal_error",
		"revision_conflict",
	}
	for token in tokens {
		canned := [?]Canned{{"parameter.set_many", fmt.tprintf("err %s the daemon says so", token)}}
		standin: Standin
		standin_start(&standin, canned[:])
		s := ready()
		code, message := tool_error(&s, "apply_parameters", APPLY, standin.path)
		standin_stop(&standin)
		testing.expect_value(t, code, token)
		testing.expect_value(t, message, "the daemon says so")
	}
}

@(test)
test_a_failed_read_is_a_tool_error_and_the_next_call_reaches_the_daemon_again :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	standin_set(&standin, .Disconnect)
	s := ready()
	code, message := tool_error(&s, "inspect_synth", `{}`, standin.path)
	testing.expect_value(t, code, "daemon_error")
	// Nothing was changed, so nothing is said about a change.
	testing.expect_value(t, message, "QCP disconnected")
	standin_set(&standin, .Answer)
	text, is_error := call_tool(&s, "inspect_synth", `{}`, standin.path)
	standin_stop(&standin)
	testing.expect(t, !is_error, text)
	testing.expect(t, strings.has_prefix(text, `{"parameters":`), text)
}

@(test)
test_no_transport_failure_replays_a_mutation_and_each_later_call_reconnects :: proc(t: ^testing.T) {
	cases := []struct {
		behavior: Behavior,
		code:     string,
		message:  string,
	} {
		{.Disconnect, "daemon_error", "QCP disconnected"},
		{.Oversized_Length, "daemon_error", "invalid QCP frame length"},
		{.Garbage_Payload, "daemon_error", "invalid QCP response"},
		{.Wrong_Id, "daemon_error", "invalid QCP response"},
		{.Truncated_Frame, "daemon_error", "QCP disconnected"},
		{.Hang, "daemon_timeout", "QCP deadline expired"},
	}
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	s := ready()
	attempts := 0
	for c in cases {
		standin_set(&standin, c.behavior)
		before := time.tick_now()
		code, message := tool_error(&s, "apply_parameters", APPLY, standin.path)
		elapsed := time.tick_since(before)
		attempts += 1
		testing.expectf(t, code == c.code, "%v: code %q", c.behavior, code)
		testing.expectf(t, strings.contains(message, c.message), "%v: message %q", c.behavior, message)
		// A change that was written says it may have been applied.
		testing.expectf(t, strings.contains(message, "the change may have been applied"), "%v: message %q", c.behavior, message)
		testing.expectf(t, elapsed < 1500 * time.Millisecond, "%v took %v", c.behavior, elapsed)

		standin_set(&standin, .Answer)
		text, is_error := call_tool(&s, "apply_parameters", APPLY, standin.path)
		testing.expectf(t, !is_error, "%v: the next call must work, got %q", c.behavior, text)
		attempts += 1
	}
	standin_stop(&standin)
	// Exactly one request per call: the failed one was never sent again, and
	// every call opened its own connection.
	commands := standin_commands(&standin)
	testing.expect_value(t, len(commands), attempts)
	testing.expect_value(t, standin_connections(&standin), attempts)
	for command in commands { testing.expect(t, strings.has_prefix(command, "parameter.set_many ")) }
}

@(test)
test_a_daemon_that_never_answers_is_given_up_on_at_the_deadline :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	standin_set(&standin, .Hang)
	s := ready()
	before := time.tick_now()
	code, _ := tool_error(&s, "inspect_synth", `{}`, standin.path)
	elapsed := time.tick_since(before)
	standin_stop(&standin)
	testing.expect_value(t, code, "daemon_timeout")
	testing.expectf(t, elapsed >= 400 * time.Millisecond && elapsed < 1500 * time.Millisecond, "gave up after %v", elapsed)
}

@(test)
test_an_unreachable_daemon_is_unavailable_for_tools_and_resources :: proc(t: ^testing.T) {
	stale := stale_socket()
	defer {
		posix.unlink(strings.clone_to_cstring(stale, context.temp_allocator))
		delete(stale)
	}
	paths := []string{ABSENT, stale, "", strings.repeat("x", 200, context.temp_allocator), "/tmp/with\x00nul"}
	for path in paths {
		s := ready()
		code, message := tool_error(&s, "inspect_synth", `{}`, path)
		testing.expectf(t, code == "daemon_unavailable", "path %q: %q", path, code)
		testing.expectf(t, message != "" && !strings.contains(message, "may have been applied"), "path %q: %q", path, message)
		code, _ = tool_error(&s, "apply_parameters", APPLY, path)
		testing.expectf(t, code == "daemon_unavailable", "path %q: %q", path, code)
		reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"quesynth://patch"}}`, path)
		e := expect_error(t, reply, -32000)
		data, _ := e.data.(json.Object)
		testing.expect_value(t, text_of(data["code"]), "daemon_unavailable")
		// The session is unharmed.
		testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":2,"method":"ping"}`), `{"id":2,"jsonrpc":"2.0","result":{}}`)
	}
}

@(test)
test_a_request_over_the_frame_limit_is_refused_locally_and_nothing_is_sent :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	s := ready()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"expected_revision":3,"parameters":[`)
	id := strings.repeat("x", 1000, context.temp_allocator)
	for i in 0 ..< 70 {
		if i > 0 { strings.write_string(&b, ",") }
		fmt.sbprintf(&b, `{{"id":"%s","value":1}}`, id)
	}
	strings.write_string(&b, `]}`)
	code, message := tool_error(&s, "apply_parameters", strings.to_string(b), standin.path)
	testing.expect_value(t, code, "daemon_error")
	testing.expect_value(t, message, "request exceeds QCP frame limit")
	testing.expect_value(t, standin_connections(&standin), 0)

	// The next, ordinary request works.
	text, is_error := call_tool(&s, "apply_parameters", APPLY, standin.path)
	standin_stop(&standin)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, standin_connections(&standin), 1)
}

@(test)
test_the_transport_returns_an_owned_payload_and_leaks_nothing :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, inspect_canned[:])
	payload, failure, sent := mcp.roundtrip(standin.path, "1 5 parameter.set_many expected_revision=3 filter.cutoff 90")
	standin_stop(&standin)
	testing.expect_value(t, failure.code, "")
	testing.expect(t, sent)
	testing.expect_value(t, string(payload), "1 5 ok count=2 revision=4")
	delete(payload)

	// Refusals allocate nothing the caller must free, and nothing was sent.
	payload, failure, sent = mcp.roundtrip(ABSENT, "1 5 daemon.status")
	testing.expect_value(t, failure.code, "daemon_unavailable")
	testing.expect(t, payload == nil)
	testing.expect(t, !sent)
}
