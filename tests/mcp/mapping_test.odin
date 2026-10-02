#+build linux
package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// What comes back for every tool: the daemon's reply as it was, the daemon's
// refusal as a code and a message, and what is said when the daemon cannot be
// reached or stops answering. Against a stand-in, so each reply is one the
// test chose and each request one it can read.

Sample :: struct {
	tool:      string,
	arguments: string,
	line:      string,
}

// One valid call of every tool that sends a single QCP request, and the line it
// must send. The two older tools make several requests and are covered beside
// the stand-in in qcp_test.odin.
SAMPLES := [?]Sample {
	{"daemon_status", `{}`, "daemon.status"},
	{"daemon_info", `{}`, "daemon.info"},
	{"daemon_shutdown", `{}`, "daemon.shutdown"},
	{"parameter_list", `{}`, "parameter.list"},
	{"parameter_get", `{"id":"filter.cutoff"}`, "parameter.get filter.cutoff"},
	{"parameter_set", `{"id":"filter.cutoff","value":90}`, "parameter.set filter.cutoff 90"},
	{"parameter_set_many", `{"expected_revision":7,"parameters":[{"id":"filter.cutoff","value":90},{"id":"filter.resonance","value":5}]}`, "parameter.set_many expected_revision=7 filter.cutoff 90 filter.resonance 5"},
	{"state_snapshot", `{}`, "state.snapshot"},
	{"patch_load", `{"slot":12}`, "patch.load 12"},
	{"patch_apply", `{"parameters":[{"id":"filter.cutoff","value":90}]}`, "patch.apply filter.cutoff 90"},
	{"patch_load_file", `{"path":"/tmp/my patches/lead.sy1"}`, "patch.load_file /tmp/my patches/lead.sy1"},
	{"patch_save", `{"slot":3,"name":"Lead  Pad"}`, "patch.save 3 Lead  Pad"},
	{"patch_current", `{}`, "patch.current"},
	{"patch_clear", `{}`, "patch.clear"},
	{"bank_list", `{}`, "bank.list"},
	{"bank_write", `{"path":"/tmp/bank.json"}`, "bank.write /tmp/bank.json"},
	{"bank_load_file", `{"path":"/tmp/bank.json"}`, "bank.load_file /tmp/bank.json"},
	{"bank_keep", `{}`, "bank.keep"},
	{"archive_open", `{"path":"/tmp/corpus.zip"}`, "archive.open /tmp/corpus.zip"},
	{"archive_adopt", `{"path":"/tmp/corpus.zip"}`, "archive.adopt /tmp/corpus.zip"},
	{"archive_current", `{}`, "archive.current"},
	{"archive_banks", `{"offset":2,"count":3}`, "archive.banks 2 3"},
	{"archive_bank", `{"index":1}`, "archive.bank 1"},
	{"archive_patches", `{"offset":2,"count":3}`, "archive.patches 2 3"},
	{"archive_load", `{"index":4,"bank":1}`, "archive.load 4 1"},
	{"archive_close", `{}`, "archive.close"},
	{"midi_list", `{}`, "midi.list"},
	{"midi_select", `{"input":"hw:2,0"}`, "midi.select hw:2,0"},
	{"midi_current", `{}`, "midi.current"},
	{"midi_send", `{"status":144,"data1":60,"data2":100}`, "midi 144 60 100"},
	{"volume", `{"milli":250}`, "volume 250"},
}

@(private = "file")
read_only_tool :: proc(name: string) -> bool {
	for spec in SPECS { if spec.name == name { return spec.read_only } }
	panic(name)
}

@(test)
test_every_tool_that_sends_one_request_has_a_sample_and_its_line_starts_with_its_command :: proc(t: ^testing.T) {
	// Every tool of the surface but the two older ones, once each.
	covered := make(map[string]bool, context.temp_allocator)
	for sample in SAMPLES {
		testing.expectf(t, !covered[sample.tool], "%q has two samples", sample.tool)
		covered[sample.tool] = true
	}
	for spec in SPECS {
		if spec.command == "" { continue }
		testing.expectf(t, covered[spec.name], "%q has no sample", spec.name)
	}
	testing.expect_value(t, len(SAMPLES), len(SPECS) - 2)

	for sample in SAMPLES {
		standin: Standin
		standin_start(&standin, OK_ALL[:])
		s := ready()
		text, is_error := call_tool(&s, sample.tool, sample.arguments, standin.path)
		standin_stop(&standin)
		testing.expectf(t, !is_error, "%s: %s", sample.tool, text)
		commands := standin_commands(&standin)
		if !testing.expectf(t, len(commands) == 1, "%s sent %d requests", sample.tool, len(commands)) { continue }
		testing.expect_value(t, commands[0], sample.line)
		command := commands[0]
		if space := strings.index_byte(command, ' '); space >= 0 { command = command[:space] }
		for spec in SPECS { if spec.name == sample.tool { testing.expect_value(t, command, spec.command) } }
		testing.expect_value(t, standin_connections(&standin), 1)
	}
}

@(private = "file")
ANSWER :: "ok a=1  b=2 \nfirst  line \n\nname=Lead  Pad \nquote\"é\\"

@(private = "file")
ANSWER_JSON :: `{"fields":"a=1  b=2 ","lines":["first  line ","","name=Lead  Pad ","quote\"é\\"]}`

@(test)
test_the_daemons_reply_comes_back_as_fields_and_lines_untouched_for_every_tool :: proc(t: ^testing.T) {
	for sample in SAMPLES {
		canned := [?]Canned{{"", ANSWER}}
		standin: Standin
		standin_start(&standin, canned[:])
		s := ready()
		text, is_error := call_tool(&s, sample.tool, sample.arguments, standin.path)
		standin_stop(&standin)
		testing.expectf(t, !is_error, "%s: %s", sample.tool, text)
		testing.expect_value(t, text, ANSWER_JSON)
	}
}

@(test)
test_a_bare_ok_has_no_fields_and_no_lines :: proc(t: ^testing.T) {
	for reply in ([]string{"ok", "ok ", "ok\n"}) {
		canned := [?]Canned{{"", reply}}
		standin: Standin
		standin_start(&standin, canned[:])
		s := ready()
		text, is_error := call_tool(&s, "patch_clear", `{}`, standin.path)
		standin_stop(&standin)
		testing.expectf(t, !is_error, "%q: %s", reply, text)
		testing.expect_value(t, text, `{"fields":"","lines":[]}`)
	}
}

@(test)
test_the_result_is_structured_from_2025_06_18_and_text_alone_before :: proc(t: ^testing.T) {
	for version in ([]string{"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}) {
		canned := [?]Canned{{"", ANSWER}}
		standin: Standin
		standin_start(&standin, canned[:])
		s := ready(version)
		reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"daemon_info","arguments":{}}}`, standin.path)
		standin_stop(&standin)
		result, _ := parse_object(reply)["result"].(json.Object)
		content, _ := result["content"].(json.Array)
		first, _ := content[0].(json.Object)
		testing.expect_value(t, text_of(first["text"]), ANSWER_JSON)
		structured, has := result["structuredContent"].(json.Object)
		testing.expect_value(t, has, version >= "2025-06-18")
		if has {
			testing.expect_value(t, text_of(structured["fields"]), "a=1  b=2 ")
			lines, _ := structured["lines"].(json.Array)
			testing.expect_value(t, len(lines), 4)
			testing.expect_value(t, text_of(lines[3]), `quote"é\`)
		}
		testing.expect(t, !flag_of(result["isError"]), reply)
	}
}

@(test)
test_the_daemons_refusal_is_a_code_and_a_message_for_every_tool :: proc(t: ^testing.T) {
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
	for sample, i in SAMPLES {
		token := tokens[i % len(tokens)]
		canned := [?]Canned{{"", fmt.tprintf("err %s the daemon says  so, and more", token)}}
		standin: Standin
		standin_start(&standin, canned[:])
		s := ready()
		code, message := tool_error(&s, sample.tool, sample.arguments, standin.path)
		standin_stop(&standin)
		testing.expectf(t, code == token, "%s: code %q, want %q", sample.tool, code, token)
		testing.expect_value(t, message, "the daemon says  so, and more")
		// It reached the daemon once, and a refusal is not an unknown outcome.
		testing.expect_value(t, standin_connections(&standin), 1)
		testing.expectf(t, !strings.contains(message, "may have been applied"), "%s: %q", sample.tool, message)
	}
	// With no message the message is empty, not made up.
	canned := [?]Canned{{"", "err internal_error"}}
	standin: Standin
	standin_start(&standin, canned[:])
	s := ready()
	code, message := tool_error(&s, "bank_keep", `{}`, standin.path)
	standin_stop(&standin)
	testing.expect_value(t, code, "internal_error")
	testing.expect_value(t, message, "")
}

@(test)
test_an_error_result_is_flagged_and_structured_the_same_way :: proc(t: ^testing.T) {
	canned := [?]Canned{{"", "err daemon_not_ready no bank"}}
	standin: Standin
	standin_start(&standin, canned[:])
	for version in ([]string{"2024-11-05", "2025-11-25"}) {
		s := ready(version)
		reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bank_list","arguments":{}}}`, standin.path)
		result, _ := parse_object(reply)["result"].(json.Object)
		testing.expect_value(t, flag_of(result["isError"]), true)
		_, has := result["structuredContent"]
		testing.expect_value(t, has, version == "2025-11-25")
		content, _ := result["content"].(json.Array)
		first, _ := content[0].(json.Object)
		testing.expect_value(t, text_of(first["text"]), `{"code":"daemon_not_ready","message":"no bank"}`)
	}
	standin_stop(&standin)
}

@(test)
test_a_daemon_that_is_not_there_is_unavailable_for_every_tool_and_nothing_is_said_about_a_change :: proc(t: ^testing.T) {
	for sample in SAMPLES {
		s := ready()
		code, message := tool_error(&s, sample.tool, sample.arguments)
		testing.expectf(t, code == "daemon_unavailable", "%s: %q", sample.tool, code)
		testing.expectf(t, message != "" && !strings.contains(message, "may have been applied"), "%s: %q", sample.tool, message)
	}
}

@(test)
test_a_request_lost_after_it_was_written_is_unsure_for_a_change_and_plain_for_a_read :: proc(t: ^testing.T) {
	for sample in SAMPLES {
		standin: Standin
		standin_start(&standin, OK_ALL[:])
		standin_set(&standin, .Disconnect)
		s := ready()
		code, message := tool_error(&s, sample.tool, sample.arguments, standin.path)
		// Once, not again: nothing retries a request that was written.
		testing.expect_value(t, standin_connections(&standin), 1)
		standin_stop(&standin)
		testing.expectf(t, code == "daemon_error", "%s: %q", sample.tool, code)
		if read_only_tool(sample.tool) {
			testing.expect_value(t, message, "QCP disconnected")
		} else {
			testing.expect_value(t, message, "QCP disconnected; the request was sent and the change may have been applied")
		}
	}
}

@(test)
test_a_reply_that_is_not_qcp_is_a_daemon_error_and_unsure_for_a_change :: proc(t: ^testing.T) {
	for behavior in ([]Behavior{.Garbage_Payload, .Wrong_Id, .Oversized_Length, .Truncated_Frame}) {
		for tool in ([]string{"daemon_status", "midi_send"}) {
			sample: Sample
			for candidate in SAMPLES { if candidate.tool == tool { sample = candidate } }
			standin: Standin
			standin_start(&standin, OK_ALL[:])
			standin_set(&standin, behavior)
			s := ready()
			code, message := tool_error(&s, tool, sample.arguments, standin.path)
			testing.expect_value(t, standin_connections(&standin), 1)
			standin_stop(&standin)
			testing.expectf(t, code == "daemon_error", "%v %s: %q", behavior, tool, code)
			unsure := strings.contains(message, "the change may have been applied")
			testing.expectf(t, unsure == !read_only_tool(tool), "%v %s: %q", behavior, tool, message)
		}
	}
}

@(test)
test_a_daemon_that_never_answers_times_out_for_a_new_tool_without_a_second_request :: proc(t: ^testing.T) {
	for tool in ([]string{"archive_current", "volume"}) {
		sample: Sample
		for candidate in SAMPLES { if candidate.tool == tool { sample = candidate } }
		standin: Standin
		standin_start(&standin, OK_ALL[:])
		standin_set(&standin, .Hang)
		s := ready()
		before := time.tick_now()
		code, message := tool_error(&s, tool, sample.arguments, standin.path)
		elapsed := time.tick_since(before)
		testing.expect_value(t, standin_connections(&standin), 1)
		standin_stop(&standin)
		testing.expect_value(t, code, "daemon_timeout")
		testing.expectf(t, elapsed >= 400 * time.Millisecond && elapsed < 1500 * time.Millisecond, "%s gave up after %v", tool, elapsed)
		testing.expect_value(t, strings.contains(message, "may have been applied"), !read_only_tool(tool))
	}
}

@(test)
test_a_line_over_the_frame_limit_is_refused_before_it_is_sent_for_every_way_to_make_one :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, OK_ALL[:])
	s := ready()
	long := strings.repeat("x", 70000, context.temp_allocator)
	cases := []struct {
		tool:      string,
		arguments: string,
	} {
		{"patch_load_file", fmt.tprintf(`{{"path":"%s"}}`, long)},
		{"bank_write", fmt.tprintf(`{{"path":"%s"}}`, long)},
		{"archive_open", fmt.tprintf(`{{"path":"%s"}}`, long)},
		{"patch_save", fmt.tprintf(`{{"slot":1,"name":"%s"}}`, long)},
		{"parameter_get", fmt.tprintf(`{{"id":"%s"}}`, long)},
		{"midi_select", fmt.tprintf(`{{"input":"%s"}}`, long)},
	}
	for c in cases {
		code, message := tool_error(&s, c.tool, c.arguments, standin.path)
		testing.expectf(t, code == "daemon_error", "%s: %q", c.tool, code)
		testing.expect_value(t, message, "request exceeds QCP frame limit")
	}
	// 128 pairs can pass the frame limit on their own, with long ids.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"parameters":[`)
	id := strings.repeat("y", 600, context.temp_allocator)
	for i in 0 ..< 128 {
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"id":"%s","value":1}}`, id)
	}
	strings.write_string(&b, `]}`)
	for tool in ([]string{"parameter_set_many", "patch_apply"}) {
		code, message := tool_error(&s, tool, strings.to_string(b), standin.path)
		testing.expectf(t, code == "daemon_error" && message == "request exceeds QCP frame limit", "%s: %q %q", tool, code, message)
	}
	testing.expect_value(t, standin_connections(&standin), 0)
	// The session is unharmed.
	text, is_error := call_tool(&s, "daemon_status", `{}`, standin.path)
	standin_stop(&standin)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, standin_connections(&standin), 1)
}

@(test)
test_the_older_tools_are_not_called_through_the_table_and_keep_their_results :: proc(t: ^testing.T) {
	// inspect_synth keeps its several requests and apply_parameters its
	// acknowledgement check; neither returns {fields, lines}.
	canned := [?]Canned {
		{"state.snapshot", "ok revision=3 count=0"},
		{"patch.current", "ok slot=-1\nbank=\nname="},
		{"parameter.list", "ok count=0"},
		{"parameter.set_many", "ok count=1 revision=4"},
	}
	standin: Standin
	standin_start(&standin, canned[:])
	s := ready()
	text, is_error := call_tool(&s, "apply_parameters", `{"expected_revision":3,"parameters":[{"id":"a","value":1}]}`, standin.path)
	testing.expect(t, !is_error, text)
	testing.expect_value(t, text, `{"count":1,"revision":4}`)
	text, is_error = call_tool(&s, "inspect_synth", `{}`, standin.path)
	testing.expect(t, !is_error, text)
	testing.expect(t, strings.has_prefix(text, `{"parameters":`), text)
	standin_stop(&standin)
	commands := standin_commands(&standin)
	testing.expect_value(t, len(commands), 4)
	testing.expect_value(t, commands[0], "parameter.set_many expected_revision=3 a 1")
	testing.expect_value(t, commands[1], "state.snapshot")
}
