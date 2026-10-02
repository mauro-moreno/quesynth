#+build linux
package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "../../hosts/standalone/mcp"

// What each tool accepts and what it sends. Every refusal is proved to be made
// before the daemon is contacted, by a stand-in that counts the connections it
// is given; every acceptance is proved by the exact line the stand-in receives.

// Characters that end a QCP request or split an operand.
@(private = "file")
CONTROLS :: []string {
	"\x00", "\x01", "\x08", "\t", "\n", "\r", "\v", "\f", "\x1b", "\x1f", "\x7f", "\u0080", "\u0085", "\u009f", "\u2028", "\u2029",
}

// Whitespace that is not a control character: what the daemon trims from the
// ends of a path, and, further down, what only splits an operand. Odin counts
// the second set as space for splitting (unicode.is_space) and not for
// trimming (strings.trim_space), and the checks follow each.
@(private = "file")
TRIMMED :: []string{" ", "\u00a0", "\u1680", "\u2000", "\u2003", "\u200a", "\u202f", "\u205f", "\u3000"}
@(private = "file")
SPLITTING_ONLY :: []string{"\u200b", "\u200e", "\u200f", "\ufeff"}

@(private = "file")
quote :: proc(text: string) -> string {
	data, err := json.unparse(json.String(text), allocator = context.temp_allocator)
	assert(err == nil)
	return data
}

// A stand-in that accepts everything with a bare ok.
OK_ALL := [?]Canned{{"", "ok"}}

// Call `tool` once per `arguments` and return what came back.
@(private = "file")
Outcome :: struct {
	code:    string,
	message: string,
	text:    string,
}

@(private = "file")
call :: proc(s: ^mcp.Session, tool, arguments, path: string) -> Outcome {
	text, is_error := call_tool(s, tool, arguments, path)
	if !is_error { return {text = text} }
	body := parse_object(text)
	return {code = text_of(body["code"]), message = text_of(body["message"]), text = text}
}

// Every one of `arguments` is refused as invalid_arguments and nothing reaches
// the daemon. `message`, when given, is what the first one says.
expect_refused :: proc(t: ^testing.T, tool: string, arguments: []string, message := "", loc := #caller_location) {
	standin: Standin
	standin_start(&standin, OK_ALL[:])
	s := ready()
	for a, i in arguments {
		outcome := call(&s, tool, a, standin.path)
		testing.expectf(t, outcome.code == "invalid_arguments", "%s %s -> %q", tool, a, outcome.text, loc = loc)
		if i == 0 && message != "" { testing.expect_value(t, outcome.message, message, loc = loc) }
	}
	standin_stop(&standin)
	testing.expectf(t, standin_connections(&standin) == 0, "%s: a refused call reached the daemon", tool, loc = loc)
}

Good :: struct {
	arguments: string,
	line:      string,
}

// Each call is accepted and puts exactly its line on the wire, in order.
@(private = "file")
expect_sent :: proc(t: ^testing.T, tool: string, good: []Good, loc := #caller_location) {
	standin: Standin
	standin_start(&standin, OK_ALL[:])
	s := ready()
	for g in good {
		outcome := call(&s, tool, g.arguments, standin.path)
		testing.expectf(t, outcome.code == "", "%s %s -> %q", tool, g.arguments, outcome.text, loc = loc)
	}
	standin_stop(&standin)
	commands := standin_commands(&standin)
	if !testing.expectf(t, len(commands) == len(good), "%s: %d calls sent %d lines", tool, len(good), len(commands), loc = loc) { return }
	for g, i in good { testing.expect_value(t, commands[i], g.line, loc = loc) }
}

// Where in the arguments one value goes and how it comes out on the line.
@(private = "file")
Shape :: struct {
	tool:        string,
	before:      string,
	after:       string,
	line_before: string,
	line_after:  string,
}

@(private = "file")
arguments_of :: proc(shape: Shape, value_json: string) -> string {
	return strings.concatenate({shape.before, value_json, shape.after}, context.temp_allocator)
}

@(private = "file")
line_of :: proc(shape: Shape, value: string) -> string {
	return strings.concatenate({shape.line_before, value, shape.line_after}, context.temp_allocator)
}

// The value of a token argument is one QCP token, whatever it is.
@(private = "file")
check_token :: proc(t: ^testing.T, shape: Shape, loc := #caller_location) {
	good := [?]string {
		"filter.cutoff", "a", "x=y", "hw:1,0", "winmm:0", "all", "none", "é.ü", "日本語", "a\u0301", "-", "0", "a/b", "'q'", "#", "\U0001f3b9",
		"a\u00adb",
	}
	goods := make([dynamic]Good, context.temp_allocator)
	for g in good { append(&goods, Good{arguments_of(shape, quote(g)), line_of(shape, g)}) }
	expect_sent(t, shape.tool, goods[:], loc)

	bad := make([dynamic]string, context.temp_allocator)
	for wrong in ([]string{`""`, `5`, `null`, `true`, `false`, `[]`, `{}`, `["a"]`, `1.5`}) { append(&bad, arguments_of(shape, wrong)) }
	for c in CONTROLS {
		append(&bad, arguments_of(shape, quote(c)))
		append(&bad, arguments_of(shape, quote(strings.concatenate({"a", c, "b"}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({c, "a"}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({"a", c}, context.temp_allocator))))
	}
	for sp in ([][]string{TRIMMED, SPLITTING_ONLY}) {
		for space in sp {
			append(&bad, arguments_of(shape, quote(space)))
			append(&bad, arguments_of(shape, quote(strings.concatenate({"a", space, "b"}, context.temp_allocator))))
			append(&bad, arguments_of(shape, quote(strings.concatenate({space, "a"}, context.temp_allocator))))
			append(&bad, arguments_of(shape, quote(strings.concatenate({"a", space}, context.temp_allocator))))
		}
	}
	expect_refused(t, shape.tool, bad[:], loc = loc)
}

// A text is read to the end of the line: spaces inside are its own, a control
// character or a line separator would end the request, and whitespace at either
// end would be trimmed into another path.
@(private = "file")
check_text :: proc(t: ^testing.T, shape: Shape, required: bool, loc := #caller_location) {
	good := [?]string {
		"a", "/tmp/a.sy1", "relative/dir/p.sy1", "my patch.sy1", "/tmp/dir with spaces/lead  pad.sy1", "a  b", "é/ü/日本.zip", "a\u00a0b",
		"a\u3000b", "a\u200bb", "a\ufeffb", "a\u2003b", ".", "..", "-", "~/x", "$HOME/x", "a;b|c&d", "'", "\"", "\\", "a\U0001f3b9b",
		"\u00e9",
	}
	goods := make([dynamic]Good, context.temp_allocator)
	for g in good { append(&goods, Good{arguments_of(shape, quote(g)), line_of(shape, g)}) }
	// The daemon does not trim these, so they are the file's own name.
	for sp in SPLITTING_ONLY {
		for g in ([]string{sp, strings.concatenate({sp, "a"}, context.temp_allocator), strings.concatenate({"a", sp}, context.temp_allocator)}) {
			append(&goods, Good{arguments_of(shape, quote(g)), line_of(shape, g)})
		}
	}
	expect_sent(t, shape.tool, goods[:], loc)

	bad := make([dynamic]string, context.temp_allocator)
	for wrong in ([]string{`5`, `null`, `true`, `false`, `[]`, `{}`, `["a"]`, `1.5`}) { append(&bad, arguments_of(shape, wrong)) }
	for c in CONTROLS {
		append(&bad, arguments_of(shape, quote(c)))
		append(&bad, arguments_of(shape, quote(strings.concatenate({"a", c, "b"}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({c, "a"}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({"a", c}, context.temp_allocator))))
	}
	for sp in TRIMMED {
		append(&bad, arguments_of(shape, quote(sp)))
		append(&bad, arguments_of(shape, quote(strings.concatenate({sp, "a"}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({"a", sp}, context.temp_allocator))))
		append(&bad, arguments_of(shape, quote(strings.concatenate({sp, "a b", sp}, context.temp_allocator))))
	}
	if required { append(&bad, arguments_of(shape, `""`)) }
	expect_refused(t, shape.tool, bad[:], loc = loc)
}

// An integer argument within [low, high] and nothing else.
@(private = "file")
check_integer :: proc(t: ^testing.T, shape: Shape, low, high: int, loc := #caller_location) {
	mid := low + (high - low) / 2
	goods := make([dynamic]Good, context.temp_allocator)
	for n in ([]int{low, high, mid, low + 1, high - 1}) {
		if n < low || n > high { continue }
		text := fmt.tprintf("%d", n)
		append(&goods, Good{arguments_of(shape, text), line_of(shape, text)})
	}
	// Spelled as a float or with an exponent, an integer is still an integer.
	if low <= 7 && high >= 7 {
		append(&goods, Good{arguments_of(shape, "7.0"), line_of(shape, "7")})
		append(&goods, Good{arguments_of(shape, "7e0"), line_of(shape, "7")})
	}
	if low <= 0 && high >= 0 { append(&goods, Good{arguments_of(shape, "-0"), line_of(shape, "0")}) }
	expect_sent(t, shape.tool, goods[:], loc)

	bad := make([dynamic]string, context.temp_allocator)
	append(&bad, arguments_of(shape, fmt.tprintf("%d", low - 1)))
	append(&bad, arguments_of(shape, fmt.tprintf("%d", high + 1)))
	for wrong in ([]string{`1.5`, `7.000001`, `"7"`, `"0"`, `""`, `null`, `true`, `false`, `[]`, `[7]`, `{}`, `1e400`, `-1e400`, `9007199254740992`, `-9007199254740992`, `1e300`}) {
		if wrong == "9007199254740992" && high >= 9007199254740992 { continue }
		append(&bad, arguments_of(shape, wrong))
	}
	expect_refused(t, shape.tool, bad[:], loc = loc)
}

@(private = "file")
NO_ARGUMENTS :: []string {
	"daemon_status", "daemon_info", "daemon_shutdown", "parameter_list", "state_snapshot", "patch_current", "patch_clear", "bank_list",
	"bank_keep", "archive_current", "archive_close", "midi_list", "midi_current",
}

@(test)
test_a_tool_without_arguments_takes_none_and_sends_only_its_command :: proc(t: ^testing.T) {
	for tool in NO_ARGUMENTS {
		spec: Tool_Spec
		for candidate in SPECS { if candidate.name == tool { spec = candidate } }
		expect_sent(t, tool, {{`{}`, spec.command}})
		// Leaving the arguments out altogether is the same call.
		standin: Standin
		standin_start(&standin, OK_ALL[:])
		s := ready()
		line := fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":%q}}}}`, tool)
		reply := send(&s, line, standin.path)
		standin_stop(&standin)
		testing.expectf(t, !strings.contains(reply, "isError"), "%s without arguments: %s", tool, reply)
		testing.expect_value(t, len(standin_commands(&standin)), 1)

		expect_refused(t, tool, {`{"anything":1}`, `{"id":"x"}`, `{"path":"/tmp/x"}`, `{"command":"volume 0"}`, `{" ":1}`}, "unknown argument: anything")
		expect_refused(t, tool, {`[]`, `null`, `5`, `"x"`, `true`}, "arguments must be an object")
	}
	testing.expect_value(t, len(NO_ARGUMENTS), 13)
}

@(test)
test_an_argument_that_is_not_declared_is_refused_by_name_whatever_else_is_wrong :: proc(t: ^testing.T) {
	// A misspelt guard must not quietly become no guard.
	expect_refused(
		t,
		"parameter_set_many",
		{`{"expected_revison":3,"parameters":[{"id":"a","value":1}]}`, `{"Expected_Revision":3,"parameters":[{"id":"a","value":1}]}`},
		"unknown argument: expected_revison",
	)
	expect_refused(t, "parameter_get", {`{"id":"a","comment":"x"}`, `{"id":"a","Id":"b"}`}, "unknown argument: comment")
	// With several the first by name is reported, not whichever hashed first.
	expect_refused(t, "parameter_get", {`{"zeta":1,"id":"a","alpha":2,"mid":3}`}, "unknown argument: alpha")
	expect_refused(t, "volume", {`{"milli":5,"loud":true}`, `{"milli":"x","loud":true}`, `{"loud":true}`}, "unknown argument: loud")
	expect_refused(t, "midi_send", {`{"status":144,"data1":60,"data2":100,"channel":1}`})
	// The two older tools keep ignoring what they do not know.
	legacy := [?]Canned {
		{"state.snapshot", "ok revision=3 count=0"},
		{"patch.current", "ok slot=-1"},
		{"parameter.list", "ok count=0"},
		{"parameter.set_many", "ok count=1 revision=4"},
	}
	standin: Standin
	standin_start(&standin, legacy[:])
	s := ready()
	text, is_error := call_tool(&s, "inspect_synth", `{"anything":[1,2,3]}`, standin.path)
	testing.expect(t, !is_error, text)
	text, is_error = call_tool(&s, "apply_parameters", `{"expected_revision":3,"parameters":[{"id":"a","value":1,"note":"x"}],"comment":"x"}`, standin.path)
	testing.expect(t, !is_error, text)
	standin_stop(&standin)
}

@(test)
test_a_missing_required_argument_is_named_and_nothing_is_sent :: proc(t: ^testing.T) {
	missing := []struct {
		tool:      string,
		arguments: string,
		message:   string,
	} {
		{"parameter_get", `{}`, "missing argument: id"},
		{"parameter_set", `{"value":1}`, "missing argument: id"},
		{"parameter_set", `{"id":"a"}`, "missing argument: value"},
		{"parameter_set_many", `{}`, "missing argument: parameters"},
		{"parameter_set_many", `{"expected_revision":0}`, "missing argument: parameters"},
		{"patch_load", `{}`, "missing argument: slot"},
		{"patch_apply", `{}`, "missing argument: parameters"},
		{"patch_load_file", `{}`, "missing argument: path"},
		{"patch_save", `{}`, "missing argument: slot"},
		{"patch_save", `{"name":"x"}`, "missing argument: slot"},
		{"bank_write", `{}`, "missing argument: path"},
		{"bank_load_file", `{}`, "missing argument: path"},
		{"archive_adopt", `{}`, "missing argument: path"},
		{"archive_bank", `{}`, "missing argument: index"},
		{"archive_load", `{}`, "missing argument: index"},
		{"archive_load", `{"bank":1}`, "missing argument: index"},
		{"midi_select", `{}`, "missing argument: input"},
		{"midi_send", `{}`, "missing argument: status"},
		{"midi_send", `{"status":144}`, "missing argument: data1"},
		{"midi_send", `{"status":144,"data1":60}`, "missing argument: data2"},
		{"volume", `{}`, "missing argument: milli"},
	}
	for m in missing { expect_refused(t, m.tool, {m.arguments}, m.message) }
}

@(test)
test_parameter_get_and_set_take_one_id_token_and_a_stored_integer :: proc(t: ^testing.T) {
	check_token(t, Shape{"parameter_get", `{"id":`, `}`, "parameter.get ", ""})
	check_token(t, Shape{"parameter_set", `{"value":-3,"id":`, `}`, "parameter.set ", " -3"})
	check_integer(t, Shape{"parameter_set", `{"id":"filter.cutoff","value":`, `}`, "parameter.set filter.cutoff ", ""}, -9007199254740991, 9007199254740991)
	expect_refused(
		t,
		"parameter_get",
		{`{"id":""}`, `{"id":"a b"}`, `{"id":5}`},
		"id must not be empty",
	)
	expect_refused(t, "parameter_get", {`{"id":"a b"}`}, "id must not contain whitespace or control characters (U+0020)")
	expect_refused(t, "parameter_get", {`{"id":"a\u0085b"}`}, "id must not contain whitespace or control characters (U+0085)")
	expect_refused(t, "parameter_get", {`{"id":7}`}, "id must be a string")
	expect_refused(t, "parameter_set", {`{"id":"a","value":1.5}`}, "value must be an integer from -9007199254740991 to 9007199254740991")
}

@(test)
test_parameter_set_many_sends_the_guard_first_then_every_pair_in_order :: proc(t: ^testing.T) {
	expect_sent(
		t,
		"parameter_set_many",
		{
			{`{"parameters":[{"id":"filter.cutoff","value":90}]}`, "parameter.set_many filter.cutoff 90"},
			{`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":90}]}`, "parameter.set_many expected_revision=0 filter.cutoff 90"},
			{
				`{"parameters":[{"id":"b","value":2},{"id":"a","value":1.0},{"id":"b","value":-7e0}],"expected_revision":12}`,
				"parameter.set_many expected_revision=12 b 2 a 1 b -7",
			},
			{`{"expected_revision":9007199254740991,"parameters":[{"id":"a","value":0}]}`, "parameter.set_many expected_revision=9007199254740991 a 0"},
			{`{"expected_revision":3.0,"parameters":[{"id":"é.ü","value":-9007199254740991}]}`, "parameter.set_many expected_revision=3 é.ü -9007199254740991"},
			// The id of a pair is one token, even one that looks like another.
			{`{"parameters":[{"id":"value","value":1},{"id":"id","value":2},{"id":"1","value":3}]}`, "parameter.set_many value 1 id 2 1 3"},
			{`{"parameters":[{"id":"expected_revision","value":1}]}`, "parameter.set_many expected_revision 1"},
		},
	)
	check_integer(t, Shape{"parameter_set_many", `{"parameters":[{"id":"a","value":1}],"expected_revision":`, `}`, "parameter.set_many expected_revision=", " a 1"}, 0, 9007199254740991)
	check_token(t, Shape{"parameter_set_many", `{"expected_revision":5,"parameters":[{"value":1,"id":`, `}]}`, "parameter.set_many expected_revision=5 ", " 1"})
	check_integer(t, Shape{"parameter_set_many", `{"parameters":[{"id":"a","value":`, `}]}`, "parameter.set_many a ", ""}, -9007199254740991, 9007199254740991)
}

@(private = "file")
pairs_json :: proc(count: int, id := "a") -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"parameters":[`)
	for i in 0 ..< count {
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"id":"%s","value":%d}}`, id, i)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

@(test)
test_batches_of_one_to_128_pairs_go_through_and_nothing_else_does :: proc(t: ^testing.T) {
	for tool in ([]string{"parameter_set_many", "patch_apply"}) {
		verb := tool == "patch_apply" ? "patch.apply" : "parameter.set_many"
		last := strings.builder_make(context.temp_allocator)
		strings.write_string(&last, verb)
		for i in 0 ..< 128 { fmt.sbprintf(&last, " a %d", i) }
		expect_sent(t, tool, {{pairs_json(1), fmt.tprintf("%s a 0", verb)}, {pairs_json(128), strings.to_string(last)}})
		expect_refused(
			t,
			tool,
			{pairs_json(129), pairs_json(0), `{"parameters":[]}`, `{"parameters":null}`, `{"parameters":{}}`, `{"parameters":"a 1"}`, `{"parameters":[[]]}`, `{"parameters":["a",1]}`},
			"parameters must be an array of 1 to 128 entries",
		)
		bad_entries := []string {
			`{"parameters":[null]}`,
			`{"parameters":[1]}`,
			`{"parameters":["a"]}`,
			`{"parameters":[{}]}`,
			`{"parameters":[{"id":"a"}]}`,
			`{"parameters":[{"value":1}]}`,
			`{"parameters":[{"id":"a","value":1,"note":"x"}]}`,
			`{"parameters":[{"id":"a","value":1,"Id":"b"}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"b"}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"","value":1}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"b c","value":1}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"b","value":1.5}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"b","value":"1"}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"b","value":null}]}`,
			`{"parameters":[{"id":"a","value":9007199254740992}]}`,
			`{"parameters":[{"id":5,"value":1}]}`,
			`{"parameters":[{"id":null,"value":1}]}`,
		}
		expect_refused(t, tool, bad_entries, "parameters[0] must be an object with id and value")
		// The entry that is wrong is the one named.
		expect_refused(t, tool, {`{"parameters":[{"id":"a","value":1},{"id":"b c","value":1}]}`}, "parameters[1].id must not contain whitespace or control characters (U+0020)")
		expect_refused(t, tool, {`{"parameters":[{"id":"a","value":1},{"id":"b","value":2.5}]}`}, "parameters[1].value must be an integer from -9007199254740991 to 9007199254740991")
		expect_refused(t, tool, {`{"parameters":[{"id":"a","value":1,"note":"x"}]}`}, "parameters[0] has an unknown key: note")
		expect_refused(t, tool, {`{"parameters":[{"id":"a"}]}`}, "parameters[0] needs id and value")
	}
	// An id the guard would swallow is refused for the one tool that has one.
	expect_refused(
		t,
		"parameter_set_many",
		{
			`{"parameters":[{"id":"expected_revision=5","value":1}]}`,
			`{"parameters":[{"id":"expected_revision=","value":1}]}`,
			`{"parameters":[{"id":"a","value":1},{"id":"expected_revision=0","value":1}]}`,
			`{"expected_revision":1,"parameters":[{"id":"expected_revision=2","value":1}]}`,
		},
		"parameters[0].id must not begin with expected_revision=",
	)
	expect_sent(t, "patch_apply", {{`{"parameters":[{"id":"expected_revision=5","value":1}]}`, "patch.apply expected_revision=5 1"}})
	check_token(t, Shape{"patch_apply", `{"parameters":[{"value":2,"id":`, `}]}`, "patch.apply ", " 2"})
	check_integer(t, Shape{"patch_apply", `{"parameters":[{"id":"a","value":`, `}]}`, "patch.apply a ", ""}, -9007199254740991, 9007199254740991)
	// patch.apply takes no guard: the daemon has none for it.
	expect_refused(t, "patch_apply", {`{"expected_revision":0,"parameters":[{"id":"a","value":1}]}`}, "unknown argument: expected_revision")
}

@(test)
test_slots_are_integers_from_0_to_127 :: proc(t: ^testing.T) {
	check_integer(t, Shape{"patch_load", `{"slot":`, `}`, "patch.load ", ""}, 0, 127)
	check_integer(t, Shape{"patch_save", `{"slot":`, `}`, "patch.save ", ""}, 0, 127)
	expect_refused(t, "patch_load", {`{"slot":128}`}, "slot must be an integer from 0 to 127")
	expect_refused(t, "patch_load", {`{"slot":-1}`}, "slot must be an integer from 0 to 127")
}

@(test)
test_patch_save_sends_a_name_verbatim_and_treats_none_or_empty_as_no_name :: proc(t: ^testing.T) {
	expect_sent(
		t,
		"patch_save",
		{
			{`{"slot":3}`, "patch.save 3"},
			{`{"slot":3,"name":""}`, "patch.save 3"},
			{`{"name":"Lead  Pad","slot":3}`, "patch.save 3 Lead  Pad"},
			{`{"slot":127,"name":"a b c"}`, "patch.save 127 a b c"},
			{`{"slot":0,"name":"Ünï"}`, "patch.save 0 Ünï"},
		},
	)
	check_text(t, Shape{"patch_save", `{"slot":9,"name":`, `}`, "patch.save 9 ", ""}, false)
	expect_refused(t, "patch_save", {`{"slot":3,"name":null}`, `{"slot":3,"name":5}`}, "name must be a string")
	expect_refused(t, "patch_save", {`{"slot":3,"name":" x"}`, `{"slot":3,"name":"x "}`}, "name must not start or end with whitespace")
	expect_refused(t, "patch_save", {`{"slot":3,"name":"a\nb"}`}, "name must not contain control characters or line separators (U+000A)")
}

@(test)
test_file_paths_are_sent_verbatim_or_refused_when_the_daemon_would_read_another :: proc(t: ^testing.T) {
	check_text(t, Shape{"patch_load_file", `{"path":`, `}`, "patch.load_file ", ""}, true)
	check_text(t, Shape{"bank_write", `{"path":`, `}`, "bank.write ", ""}, true)
	check_text(t, Shape{"bank_load_file", `{"path":`, `}`, "bank.load_file ", ""}, true)
	check_text(t, Shape{"archive_adopt", `{"path":`, `}`, "archive.adopt ", ""}, true)
	expect_refused(t, "patch_load_file", {`{"path":""}`}, "path must not be empty")
	expect_refused(t, "patch_load_file", {`{"path":"/tmp/x "}`, `{"path":" /tmp/x"}`}, "path must not start or end with whitespace")
	expect_refused(t, "patch_load_file", {`{"path":"/tmp/x\u2028y"}`}, "path must not contain control characters or line separators (U+2028)")
	expect_refused(t, "patch_load_file", {`{"path":null}`, `{"path":7}`}, "path must be a string")
}

@(test)
test_archive_open_takes_an_optional_path_and_empty_means_the_remembered_archive :: proc(t: ^testing.T) {
	expect_sent(
		t,
		"archive_open",
		{
			{`{}`, "archive.open"},
			{`{"path":""}`, "archive.open"},
			{`{"path":"/tmp/zip bank/a.zip"}`, "archive.open /tmp/zip bank/a.zip"},
			{`{"path":"a.zip"}`, "archive.open a.zip"},
		},
	)
	check_text(t, Shape{"archive_open", `{"path":`, `}`, "archive.open ", ""}, false)
	expect_refused(t, "archive_open", {`{"path":null}`, `{"path":"  "}`, `{"path":"\t"}`})
}

@(test)
test_archive_indices_and_pages_are_non_negative_integers :: proc(t: ^testing.T) {
	check_integer(t, Shape{"archive_bank", `{"index":`, `}`, "archive.bank ", ""}, 0, 9007199254740991)
	check_integer(t, Shape{"archive_load", `{"index":`, `}`, "archive.load ", ""}, 0, 9007199254740991)
	check_integer(t, Shape{"archive_load", `{"index":4,"bank":`, `}`, "archive.load 4 ", ""}, 0, 9007199254740991)
	for tool in ([]string{"archive_banks", "archive_patches"}) {
		verb := tool == "archive_banks" ? "archive.banks" : "archive.patches"
		expect_sent(
			t,
			tool,
			{
				{`{}`, verb},
				{`{"offset":0}`, fmt.tprintf("%s 0", verb)},
				{`{"offset":10}`, fmt.tprintf("%s 10", verb)},
				// The daemon reads operands by position, so a count alone
				// needs the offset that precedes it.
				{`{"count":5}`, fmt.tprintf("%s 0 5", verb)},
				{`{"count":0}`, fmt.tprintf("%s 0 0", verb)},
				{`{"offset":2,"count":3}`, fmt.tprintf("%s 2 3", verb)},
				{`{"count":3,"offset":0}`, fmt.tprintf("%s 0 3", verb)},
				{`{"offset":9007199254740991,"count":9007199254740991}`, fmt.tprintf("%s 9007199254740991 9007199254740991", verb)},
			},
		)
		check_integer(t, Shape{tool, `{"offset":`, `}`, fmt.tprintf("%s ", verb), ""}, 0, 9007199254740991)
		check_integer(t, Shape{tool, `{"offset":4,"count":`, `}`, fmt.tprintf("%s 4 ", verb), ""}, 0, 9007199254740991)
		check_integer(t, Shape{tool, `{"count":`, `}`, fmt.tprintf("%s 0 ", verb), ""}, 0, 9007199254740991)
	}
}

@(test)
test_archive_load_sends_the_bank_only_when_given :: proc(t: ^testing.T) {
	expect_sent(
		t,
		"archive_load",
		{
			{`{"index":3}`, "archive.load 3"},
			{`{"index":3,"bank":0}`, "archive.load 3 0"},
			{`{"bank":2,"index":0}`, "archive.load 0 2"},
		},
	)
	expect_refused(t, "archive_load", {`{"index":3,"bank":null}`, `{"index":3,"bank":-1}`, `{"bank":2}`})
}

@(test)
test_midi_select_takes_all_none_or_one_device_token :: proc(t: ^testing.T) {
	check_token(t, Shape{"midi_select", `{"input":`, `}`, "midi.select ", ""})
	expect_sent(t, "midi_select", {{`{"input":"all"}`, "midi.select all"}, {`{"input":"none"}`, "midi.select none"}, {`{"input":"hw:2,0"}`, "midi.select hw:2,0"}})
}

@(test)
test_midi_send_takes_three_bytes_within_their_ranges :: proc(t: ^testing.T) {
	check_integer(t, Shape{"midi_send", `{"data1":60,"data2":100,"status":`, `}`, "midi ", " 60 100"}, 0, 255)
	check_integer(t, Shape{"midi_send", `{"status":144,"data2":100,"data1":`, `}`, "midi 144 ", " 100"}, 0, 127)
	check_integer(t, Shape{"midi_send", `{"status":144,"data1":60,"data2":`, `}`, "midi 144 60 ", ""}, 0, 127)
	expect_sent(t, "midi_send", {{`{"status":144,"data1":60,"data2":100}`, "midi 144 60 100"}, {`{"status":128,"data1":60,"data2":0}`, "midi 128 60 0"}, {`{"status":255,"data1":127,"data2":127}`, "midi 255 127 127"}})
	expect_refused(t, "midi_send", {`{"status":256,"data1":0,"data2":0}`}, "status must be an integer from 0 to 255")
	expect_refused(t, "midi_send", {`{"status":0,"data1":128,"data2":0}`}, "data1 must be an integer from 0 to 127")
	expect_refused(t, "midi_send", {`{"status":0,"data1":0,"data2":-1}`}, "data2 must be an integer from 0 to 127")
}

@(test)
test_volume_is_an_integer_from_0_to_1000 :: proc(t: ^testing.T) {
	check_integer(t, Shape{"volume", `{"milli":`, `}`, "volume ", ""}, 0, 1000)
	expect_refused(t, "volume", {`{"milli":1001}`, `{"milli":-1}`, `{"milli":1000.5}`}, "milli must be an integer from 0 to 1000")
}

@(test)
test_the_older_tools_check_what_they_always_checked_and_say_the_same_things :: proc(t: ^testing.T) {
	// Their own messages, unchanged by the table they now sit beside.
	s := ready()
	code, message := tool_error(&s, "apply_parameters", `{}`)
	testing.expect_value(t, code, "invalid_arguments")
	testing.expect_value(t, message, "expected_revision and parameters array are required")
	code, message = tool_error(&s, "apply_parameters", `{"expected_revision":0,"parameters":[{"id":"a b","value":1}]}`)
	testing.expect_value(t, code, "invalid_arguments")
	testing.expect_value(t, message, "parameter id is not a QCP token")
	code, message = tool_error(&s, "apply_parameters", `{"expected_revision":0,"parameters":[{"id":"a"}]}`)
	testing.expect_value(t, code, "invalid_arguments")
	testing.expect_value(t, message, "each parameter needs an id token and an integer value")
	code, message = tool_error(&s, "inspect_synth", `[]`)
	testing.expect_value(t, code, "invalid_arguments")
	testing.expect_value(t, message, "arguments must be an object")
}
