#+build linux
package mcp_tests

import "core:encoding/json"
import "core:strings"
import "core:testing"

// QCP can carry arbitrary bytes; JSON cannot represent malformed UTF-8 without
// changing them. A broken reply must not turn into a successful, lossy result.
@(test)
test_invalid_utf8_replies_are_structured_errors_and_never_replayed :: proc(t: ^testing.T) {
	for reply in ([]string{
		"ok name=a\xc3",
		"ok count=1\nname=Caf\xe9",
		"err internal_error Caf\xe9",
		"err bad\xe9 message",
		"ok name=\xed\xa0\x80",
	}) {
		for tool in ([]string{"patch_current", "patch_save"}) {
			standin: Standin
			standin_start(&standin, []Canned{{"", reply}})
			s := ready()
			args := tool == "patch_save" ? `{"slot":0}` : `{}`
			text, is_error := call_tool(&s, tool, args, standin.path)
			standin_stop(&standin)
			if testing.expectf(t, is_error, "%s: malformed QCP was returned as success: %q", tool, text) {
				failure := parse_object(text)
				testing.expect_value(t, text_of(failure["code"]), "daemon_error")
				testing.expect_value(t, strings.contains(text_of(failure["message"]), "may have been applied"), tool == "patch_save")
			}
			testing.expect_value(t, standin_connections(&standin), 1)
		}
	}
}

@(test)
test_daemon_error_tokens_not_in_the_control_enum_are_preserved :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, []Canned{{"", "err brand_new_code Caf\u00e9  says no"}})
	s := ready()
	for sample in SAMPLES {
		code, message := tool_error(&s, sample.tool, sample.arguments, standin.path)
		testing.expect_value(t, code, "brand_new_code")
		testing.expect_value(t, message, "Caf\u00e9  says no")
	}
	for tool in ([]string{"inspect_synth", "apply_parameters"}) {
		args := tool == "apply_parameters" ? `{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1}]}` : `{}`
		code, message := tool_error(&s, tool, args, standin.path)
		testing.expect_value(t, code, "brand_new_code")
		testing.expect_value(t, message, "Caf\u00e9  says no")
	}
	standin_stop(&standin)
	testing.expect_value(t, standin_connections(&standin), len(SAMPLES) + 2)
}

@(test)
test_direct_replies_preserve_whitespace_and_unicode_while_legacy_keeps_its_shape :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, []Canned{
		{"patch.current", "ok  name=Caf\u00e9 e\u0301 \U0001f3b9\ufffd  \nsecond  \n\n first \n"},
		{"state.snapshot", "ok  revision=7 count=0  "},
		{"parameter.list", "ok  count=0  "},
		{"parameter.set_many", "err brand_new_code  Caf\u00e9 says no  "},
	})
	s := ready()
	text, is_error := call_tool(&s, "patch_current", `{}`, standin.path)
	testing.expect(t, !is_error)
	got := parse_object(text)
	testing.expect_value(t, text_of(got["fields"]), " name=Caf\u00e9 e\u0301 \U0001f3b9\ufffd  ")
	lines, _ := got["lines"].(json.Array)
	if testing.expect_value(t, len(lines), 4) {
		for want, i in ([]string{"second  ", "", " first ", ""}) { testing.expect_value(t, text_of(lines[i]), want) }
	}
	code, message := tool_error(&s, "parameter_set_many", `{"parameters":[{"id":"filter.cutoff","value":1}]}`, standin.path)
	testing.expect_value(t, code, "brand_new_code")
	testing.expect_value(t, message, " Caf\u00e9 says no  ")
	code, message = tool_error(&s, "apply_parameters", `{"expected_revision":7,"parameters":[{"id":"filter.cutoff","value":1}]}`, standin.path)
	testing.expect_value(t, code, "brand_new_code")
	testing.expect_value(t, message, "Caf\u00e9 says no")
	text, is_error = call_tool(&s, "inspect_synth", `{}`, standin.path)
	testing.expect(t, !is_error)
	legacy := parse_object(text)
	state := legacy["state"].(json.Object)
	patch := legacy["patch"].(json.Object)
	testing.expect_value(t, text_of(state["fields"]), "revision=7 count=0")
	testing.expect_value(t, text_of(patch["fields"]), "name=Caf\u00e9 e\u0301 \U0001f3b9\ufffd")
	standin_stop(&standin)
}

// Each reply is one the daemon's own handlers cannot make, but a client has to
// read: a bare envelope, and tokens followed by more than one space.
@(test)
test_a_bare_or_padded_envelope_loses_exactly_one_separator_space :: proc(t: ^testing.T) {
	Case :: struct {
		reply:   string,
		fields:  string,
		code:    string,
		message: string,
	}
	for c in ([]Case {
		{"ok", "", "", ""},
		{"ok ", "", "", ""},
		{"ok  ", " ", "", ""},
		{"ok   a=1  ", "  a=1  ", "", ""},
		{"err", "", "internal_error", ""},
		{"err brand_new_code", "", "brand_new_code", ""},
		{"err brand_new_code ", "", "brand_new_code", ""},
		{"err  brand_new_code   no  ", "", "brand_new_code", "  no  "},
	}) {
		standin: Standin
		standin_start(&standin, []Canned{{"", c.reply}})
		s := ready()
		text, is_error := call_tool(&s, "parameter_list", `{}`, standin.path)
		standin_stop(&standin)
		got := parse_object(text)
		if c.code == "" {
			testing.expectf(t, !is_error, "%q: %s", c.reply, text)
			testing.expect_value(t, text_of(got["fields"]), c.fields)
		} else {
			testing.expectf(t, is_error, "%q: %s", c.reply, text)
			testing.expect_value(t, text_of(got["code"]), c.code)
			testing.expect_value(t, text_of(got["message"]), c.message)
		}
	}
}

@(test)
test_resources_keep_their_trimmed_fields_and_take_the_daemons_error_token :: proc(t: ^testing.T) {
	standin: Standin
	standin_start(&standin, []Canned{{"parameter.list", "ok   count=0  "}})
	s := ready()
	got := parse_object(read_resource(&s, "quesynth://parameters", standin.path))
	testing.expect_value(t, text_of(got["fields"]), "count=0")
	standin_stop(&standin)

	standin_start(&standin, []Canned{{"", "err brand_new_code  Caf\u00e9  "}})
	reply := send(&s, `{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"quesynth://parameters"}}`, standin.path)
	e := expect_error(t, reply, -32000)
	testing.expect_value(t, e.message, "brand_new_code: Caf\u00e9")
	standin_stop(&standin)
}
