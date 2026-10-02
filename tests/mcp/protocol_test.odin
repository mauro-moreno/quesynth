package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "../../hosts/standalone/mcp"

// The MCP shell with no daemon behind it. The tools and resources are asked for
// QCP-backed answers at a socket path that cannot exist, so every one that
// reaches for the daemon reports it unavailable, and a request refused before
// it gets that far reports its own reason instead -- which is how these tests
// tell "validated locally" from "forwarded".

ABSENT :: "/nonexistent-quesynth-dir/quesynth.sock"

Reply_Error :: struct {
	code:    int,
	message: string,
	data:    json.Value,
	id:      json.Value,
}

@(private)
send :: proc(s: ^mcp.Session, line: string, path := ABSENT) -> string {
	return mcp.handle(s, line, path)
}

@(private)
text_of :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)
	return text
}

@(private)
flag_of :: proc(value: json.Value) -> bool {
	flag, _ := value.(json.Boolean)
	return bool(flag)
}

@(private)
parse_object :: proc(text: string) -> json.Object {
	value, err := json.parse(transmute([]u8)text, spec = .JSON, allocator = context.temp_allocator)
	assert(err == .None, text)
	object, ok := value.(json.Object)
	assert(ok, text)
	return object
}

@(private)
error_of :: proc(reply: string) -> (e: Reply_Error, ok: bool) {
	object := parse_object(reply)
	body, has := object["error"].(json.Object)
	if !has { return {}, false }
	code, _ := body["code"].(json.Float)
	message, _ := body["message"].(string)
	return Reply_Error{code = int(code), message = message, data = body["data"], id = object["id"]}, true
}

@(private)
expect_error :: proc(t: ^testing.T, reply: string, code: int, loc := #caller_location) -> Reply_Error {
	e, ok := error_of(reply)
	testing.expectf(t, ok, "expected a JSON-RPC error, got %q", reply, loc = loc)
	testing.expect_value(t, e.code, code, loc = loc)
	return e
}

@(private)
ready :: proc(version := "2025-11-25") -> mcp.Session {
	s: mcp.Session
	line := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":0,"method":"initialize","params":{{"protocolVersion":"%s","capabilities":{{}},"clientInfo":{{"name":"t","version":"1"}}}}}}`,
		version,
	)
	reply := send(&s, line)
	assert(!strings.contains(reply, `"error"`), reply)
	assert(send(&s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`) == "")
	return s
}

@(private)
call_tool :: proc(s: ^mcp.Session, name, arguments: string, path := ABSENT) -> (text: string, is_error: bool) {
	line := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":%q,"arguments":%s}}}}`,
		name,
		arguments,
	)
	reply := send(s, line, path)
	result, _ := parse_object(reply)["result"].(json.Object)
	content, _ := result["content"].(json.Array)
	first: json.Object
	if len(content) > 0 { first, _ = content[0].(json.Object) }
	return text_of(first["text"]), flag_of(result["isError"])
}

// The code and message of a tool failure; code is empty when the call succeeded.
@(private)
tool_error :: proc(s: ^mcp.Session, name, arguments: string, path := ABSENT) -> (code, message: string) {
	text, is_error := call_tool(s, name, arguments, path)
	if !is_error { return "", text }
	body := parse_object(text)
	return text_of(body["code"]), text_of(body["message"])
}

@(private)
read_resource :: proc(s: ^mcp.Session, uri, path: string) -> string {
	reply := send(s, fmt.tprintf(`{{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{{"uri":"%s"}}}}`, uri), path)
	result, _ := parse_object(reply)["result"].(json.Object)
	contents, _ := result["contents"].(json.Array)
	assert(len(contents) == 1, reply)
	first: json.Object
	if len(contents) > 0 { first, _ = contents[0].(json.Object) }
	assert(text_of(first["uri"]) == uri, reply)
	assert(text_of(first["mimeType"]) == "application/json", reply)
	return text_of(first["text"])
}

@(test)
test_ping_answers_before_initialize_and_echoes_an_integer_id_as_one :: proc(t: ^testing.T) {
	s: mcp.Session
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":7,"method":"ping"}`), `{"id":7,"jsonrpc":"2.0","result":{}}`)
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":0,"method":"ping"}`), `{"id":0,"jsonrpc":"2.0","result":{}}`)
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":-3,"method":"ping"}`), `{"id":-3,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_integer_valued_numeric_ids_in_the_safe_range_echo_as_integers :: proc(t: ^testing.T) {
	s: mcp.Session
	cases := [][2]string {
		{`1.0`, `1`},
		{`1e2`, `100`},
		{`9007199254740991`, `9007199254740991`},
		{`-9007199254740991`, `-9007199254740991`},
	}
	for c in cases {
		reply := send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"method":"ping"}}`, c[0]))
		testing.expect_value(t, reply, fmt.tprintf(`{{"id":%s,"jsonrpc":"2.0","result":{{}}}}`, c[1]))
	}
}

@(test)
test_a_string_id_is_echoed_with_quotes_controls_and_line_separators_escaped :: proc(t: ^testing.T) {
	s: mcp.Session
	reply := send(&s, "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"\\\\\u2028\u2029\u007f\u00e9\",\"method\":\"ping\"}")
	testing.expect_value(t, reply, "{\"id\":\"a\\\"\\\\\\u2028\\u2029\\u007f\u00e9\",\"jsonrpc\":\"2.0\",\"result\":{}}")
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":"","method":"ping"}`), `{"id":"","jsonrpc":"2.0","result":{}}`)
}

@(test)
test_an_id_that_cannot_be_echoed_exactly_is_an_invalid_request :: proc(t: ^testing.T) {
	s: mcp.Session
	for id in ([]string{`1.5`, `1e400`, `-1e400`, `9007199254740992`, `9007199254740993`, `12345678901234567890123`, `null`, `true`, `[1]`, `{}`}) {
		reply := send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"method":"ping"}}`, id))
		e := expect_error(t, reply, -32600)
		testing.expect_value(t, e.message, "Invalid JSON-RPC request")
		_, id_is_null := e.id.(json.Null)
		testing.expectf(t, id_is_null, "id %s: the reply id must be null, got %q", id, reply)
	}
}

@(test)
test_replies_are_byte_stable_with_keys_in_sorted_order :: proc(t: ^testing.T) {
	s := ready()
	first := send(&s, `{"jsonrpc":"2.0","id":4,"method":"tools/list"}`)
	for _ in 0 ..< 20 {
		testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":4,"method":"tools/list"}`), first)
	}
	testing.expect(t, strings.has_prefix(first, `{"id":4,"jsonrpc":"2.0","result":{"tools":[`), first)
}

@(test)
test_a_line_that_is_not_one_json_value_is_a_parse_error_with_a_null_id :: proc(t: ^testing.T) {
	s: mcp.Session
	lines := []string {
		``,
		`   `,
		`{`,
		`{"jsonrpc":"2.0","id":1,"method":"ping"} trailing`,
		`{"jsonrpc":"2.0","id":1,"method":"ping"}{"jsonrpc":"2.0","id":2,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping",}`,
		`{"jsonrpc":"2.0","id":01,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":1.,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":+1,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":"\ud800","method":"ping"}`,
		`{"jsonrpc":"2.0","id":"\udc00","method":"ping"}`,
		`{"jsonrpc":"2.0","id":"\ud800\u0041","method":"ping"}`,
		`{"jsonrpc":"2.0","id":"\q","method":"ping"}`,
		`{"jsonrpc":"2.0","id":"\u12","method":"ping"}`,
		"{\"jsonrpc\":\"2.0\",\"id\":\"a\x01b\",\"method\":\"ping\"}",
		"{\"jsonrpc\":\"2.0\",\"id\":\"a\tb\",\"method\":\"ping\"}",
		"{\"jsonrpc\":\"2.0\",\"id\":\"a\xffb\",\"method\":\"ping\"}",
		"{\"jsonrpc\":\"2.0\",\"id\":\"a\xc0\xafb\",\"method\":\"ping\"}",
		`{'jsonrpc':'2.0','id':1,'method':'ping'}`,
		`{"jsonrpc":"2.0","id":1,"method":ping}`,
	}
	for line in lines {
		e := expect_error(t, send(&s, line), -32700)
		testing.expect_value(t, e.message, "Invalid JSON")
		_, id_is_null := e.id.(json.Null)
		testing.expectf(t, id_is_null, "%q: the reply id must be null", line)
	}
}

// The library parser refuses an object that names a member twice, and the reply
// cannot carry the request's id. Its one blind spot is the name "", which it
// never stores, so that name may repeat; the manual says both.
@(test)
test_a_member_name_twice_in_one_object_is_invalid_json_and_only_the_empty_name_may_repeat :: proc(t: ^testing.T) {
	s := ready()
	refused := []string {
		`{"jsonrpc":"2.0","id":1,"method":"ping","id":2}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping","\u0069d":2}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":1,"a":2}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"parameter_get","arguments":{"id":"a","id":"b"}}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"parameter_set_many","arguments":{"parameters":[{"id":"a","value":1,"id":"b"}]}}}`,
	}
	for line in refused {
		e := expect_error(t, send(&s, line), -32700)
		_, id_is_null := e.id.(json.Null)
		testing.expectf(t, id_is_null, "%q: the reply id must be null", line)
	}
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":1,"method":"ping","":1,"":2}`), `{"id":1,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_a_surrogate_pair_escape_is_one_valid_character :: proc(t: ^testing.T) {
	s: mcp.Session
	reply := send(&s, `{"jsonrpc":"2.0","id":"\ud83d\ude00","method":"ping"}`)
	testing.expect_value(t, reply, `{"id":"\ud83d\ude00","jsonrpc":"2.0","result":{}}`)
}

@(test)
test_a_trailing_carriage_return_is_only_whitespace :: proc(t: ^testing.T) {
	s: mcp.Session
	testing.expect_value(t, send(&s, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r"), `{"id":1,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_deep_nesting_is_refused_instead_of_overflowing_the_stack :: proc(t: ^testing.T) {
	s: mcp.Session
	for pair in ([][2]string{{"[", "]"}, {`{"k":`, "}"}}) {
		open, close := pair[0], pair[1]
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":`)
		for _ in 0 ..< 200000 { strings.write_string(&b, open) }
		strings.write_string(&b, "0")
		for _ in 0 ..< 200000 { strings.write_string(&b, close) }
		strings.write_string(&b, "}}")
		expect_error(t, send(&s, strings.to_string(b)), -32700)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":`)
	for _ in 0 ..< 40 { strings.write_string(&b, "[") }
	for _ in 0 ..< 40 { strings.write_string(&b, "]") }
	strings.write_string(&b, "}}")
	testing.expect_value(t, send(&s, strings.to_string(b)), `{"id":1,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_structure_characters_inside_strings_do_not_count_toward_nesting :: proc(t: ^testing.T) {
	s: mcp.Session
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"`)
	for _ in 0 ..< 5000 { strings.write_string(&b, `[{\"`) }
	strings.write_string(&b, `"}}`)
	testing.expect_value(t, send(&s, strings.to_string(b)), `{"id":1,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_a_value_that_is_not_a_request_object_is_an_invalid_request :: proc(t: ^testing.T) {
	s: mcp.Session
	lines := []string {
		`[]`,
		`[{"jsonrpc":"2.0","id":1,"method":"ping"}]`,
		`null`,
		`"ping"`,
		`5`,
		`true`,
		`{}`,
		`{"id":1,"method":"ping"}`,
		`{"jsonrpc":"1.0","id":1,"method":"ping"}`,
		`{"jsonrpc":2,"id":1,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":1}`,
		`{"jsonrpc":"2.0","id":1,"method":5}`,
		`{"jsonrpc":"2.0","id":1,"method":null}`,
	}
	for line in lines {
		e := expect_error(t, send(&s, line), -32600)
		testing.expect_value(t, e.message, "Invalid JSON-RPC request")
		_, id_is_null := e.id.(json.Null)
		testing.expectf(t, id_is_null, "%q: the reply id must be null", line)
	}
}

@(test)
test_params_must_be_an_object_and_the_error_keeps_the_request_id :: proc(t: ^testing.T) {
	s: mcp.Session
	for params in ([]string{`[]`, `null`, `5`, `"x"`, `true`}) {
		reply := send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":"p","method":"ping","params":%s}}`, params))
		e := expect_error(t, reply, -32602)
		testing.expect_value(t, e.message, "params must be an object")
		testing.expect_value(t, text_of(e.id), "p")
	}
}

@(test)
test_notifications_are_never_answered :: proc(t: ^testing.T) {
	s: mcp.Session
	for line in ([]string {
			`{"jsonrpc":"2.0","method":"ping"}`,
			`{"jsonrpc":"2.0","method":"notifications/unknown"}`,
			`{"jsonrpc":"2.0","method":"tools/call","params":{"name":"inspect_synth"}}`,
			`{"jsonrpc":"2.0","method":"nonsense"}`,
			`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		}) {
		testing.expect_value(t, send(&s, line), "")
	}
	// An initialized notification before initialize changed nothing.
	expect_error(t, send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`), -32000)
}

@(test)
test_lifecycle_needs_initialize_then_the_initialized_notification :: proc(t: ^testing.T) {
	s: mcp.Session
	not_ready := "Initialize and send notifications/initialized first"
	for method in ([]string{"tools/list", "tools/call", "resources/list", "resources/read"}) {
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"%s","params":{{}}}}`, method)), -32000)
		testing.expect_value(t, e.message, not_ready)
	}
	init := `{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`
	reply := send(&s, init)
	testing.expect(t, strings.contains(reply, `"protocolVersion":"2025-06-18"`), reply)
	// Initialized alone is not enough: the notification has not arrived.
	expect_error(t, send(&s, `{"jsonrpc":"2.0","id":3,"method":"tools/list"}`), -32000)
	e := expect_error(t, send(&s, init), -32600)
	testing.expect_value(t, e.message, "Already initialized")
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`), "")
	listed := send(&s, `{"jsonrpc":"2.0","id":4,"method":"tools/list"}`)
	testing.expect(t, strings.contains(listed, `"tools":[`), listed)
	expect_error(t, send(&s, init), -32600)
	testing.expect_value(t, send(&s, `{"jsonrpc":"2.0","id":5,"method":"ping"}`), `{"id":5,"jsonrpc":"2.0","result":{}}`)
}

@(test)
test_initialize_answers_the_clients_version_when_supported_else_the_newest :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"2024-11-05", "2024-11-05"},
		{"2025-03-26", "2025-03-26"},
		{"2025-06-18", "2025-06-18"},
		{"2025-11-25", "2025-11-25"},
		{"2023-01-01", "2025-11-25"},
		{"", "2025-11-25"},
		{"latest", "2025-11-25"},
	}
	for c in cases {
		s: mcp.Session
		line := fmt.tprintf(
			`{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":%q,"capabilities":{{}},"clientInfo":{{"name":"t","version":"1"}}}}}}`,
			c[0],
		)
		want := fmt.tprintf(
			`{{"id":1,"jsonrpc":"2.0","result":{{"capabilities":{{"resources":{{}},"tools":{{}}}},"protocolVersion":"%s","serverInfo":{{"name":"quesynth","version":"1.0.0"}}}}}}`,
			c[1],
		)
		testing.expect_value(t, send(&s, line), want)
	}
}

@(test)
test_initialize_refuses_params_missing_what_the_protocol_requires :: proc(t: ^testing.T) {
	bad := []string {
		``,
		`,"params":{}`,
		`,"params":{"capabilities":{},"clientInfo":{"name":"t","version":"1"}}`,
		`,"params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"t","version":"1"}}`,
		`,"params":{"protocolVersion":"2025-11-25","capabilities":{}}`,
		`,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"version":"1"}}`,
		`,"params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t"}}`,
		`,"params":{"protocolVersion":20251125,"capabilities":{},"clientInfo":{"name":"t","version":"1"}}`,
		`,"params":{"protocolVersion":"2025-11-25","capabilities":[],"clientInfo":{"name":"t","version":"1"}}`,
	}
	for extra in bad {
		s: mcp.Session
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"initialize"%s}}`, extra)), -32602)
		testing.expect_value(t, e.message, "initialize needs protocolVersion, capabilities and clientInfo")
		// A refused initialize leaves the session new, so a good one still works.
		good := send(&s, `{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
		testing.expect(t, strings.contains(good, `"serverInfo"`), good)
	}
}

@(test)
test_unknown_methods_and_the_unimplemented_templates_list_are_method_not_found :: proc(t: ^testing.T) {
	s := ready()
	for method in ([]string{"nonsense", "resources/templates/list", "prompts/list", "logging/setLevel", "tools/list/extra"}) {
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"%s"}}`, method)), -32601)
		testing.expect_value(t, e.message, "Method not found")
	}
}

@(test)
test_tools_list_leads_with_the_two_older_tools_and_ignores_a_cursor :: proc(t: ^testing.T) {
	s := ready()
	reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	result, _ := parse_object(reply)["result"].(json.Object)
	tools, _ := result["tools"].(json.Array)
	// Every tool of the control protocol follows them: tools_test.odin.
	testing.expect_value(t, len(tools), 33)
	names: [2]string
	for tool, i in tools {
		object, _ := tool.(json.Object)
		schema, _ := object["inputSchema"].(json.Object)
		testing.expect_value(t, text_of(schema["type"]), "object")
		if i < len(names) { names[i], _ = object["name"].(string) }
	}
	testing.expect_value(t, names[0], "inspect_synth")
	testing.expect_value(t, names[1], "apply_parameters")
	apply, _ := tools[1].(json.Object)
	schema, _ := apply["inputSchema"].(json.Object)
	required, _ := schema["required"].(json.Array)
	testing.expect_value(t, len(required), 2)
	testing.expect_value(t, text_of(required[0]), "expected_revision")
	testing.expect_value(t, text_of(required[1]), "parameters")
	// A cursor is ignored: there is one page.
	paged := send(&s, `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"x"}}`)
	testing.expect_value(t, paged, strings.concatenate({`{"id":2,`, reply[len(`{"id":1,`):]}, context.temp_allocator))
}

@(test)
test_resources_list_names_exactly_the_two_json_resources :: proc(t: ^testing.T) {
	s := ready()
	reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"resources/list"}`)
	result, _ := parse_object(reply)["result"].(json.Object)
	resources, _ := result["resources"].(json.Array)
	testing.expect_value(t, len(resources), 2)
	uris: [2]string
	for resource, i in resources {
		object, _ := resource.(json.Object)
		uris[i], _ = object["uri"].(string)
		testing.expect_value(t, text_of(object["mimeType"]), "application/json")
	}
	testing.expect_value(t, uris[0], "quesynth://parameters")
	testing.expect_value(t, uris[1], "quesynth://patch")
}

@(test)
test_structured_content_appears_from_2025_06_18_and_mirrors_the_text :: proc(t: ^testing.T) {
	cases := []struct {
		version:    string,
		structured: bool,
	}{{"2024-11-05", false}, {"2025-03-26", false}, {"2025-06-18", true}, {"2025-11-25", true}}
	for c in cases {
		s := ready(c.version)
		reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_synth"}}`)
		result, _ := parse_object(reply)["result"].(json.Object)
		testing.expect_value(t, flag_of(result["isError"]), true)
		_, has := result["structuredContent"]
		testing.expect_value(t, has, c.structured)
		content, _ := result["content"].(json.Array)
		first, _ := content[0].(json.Object)
		testing.expect_value(t, text_of(first["type"]), "text")
		text, _ := first["text"].(string)
		body := parse_object(text)
		testing.expect_value(t, text_of(body["code"]), "daemon_unavailable")
		if c.structured {
			structured, _ := result["structuredContent"].(json.Object)
			testing.expect_value(t, len(structured), len(body))
			for key, value in body { testing.expect_value(t, text_of(structured[key]), text_of(value)) }
		}
	}
}

@(test)
test_tools_call_envelope_errors_are_protocol_errors_and_bad_arguments_are_tool_errors :: proc(t: ^testing.T) {
	s := ready()
	e := expect_error(t, send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}`), -32602)
	testing.expect_value(t, e.message, "tools/call needs a tool name")
	expect_error(t, send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":4}}`), -32602)
	// No gateway: a tool is called by its own name, never by the name of the
	// QCP command behind it.
	for command in ([]string{"midi", "daemon.status", "parameter.set", "patch.load_file", "bank.load_file", "archive.open"}) {
		e = expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"%s"}}}}`, command)), -32602)
		testing.expect_value(t, e.message, "Unknown tool")
	}
	for arguments in ([]string{`[]`, `null`, `5`, `"x"`, `true`}) {
		code, _ := tool_error(&s, "inspect_synth", arguments)
		testing.expect_value(t, code, "invalid_arguments")
	}
}

@(test)
test_inspect_synth_ignores_arguments_it_does_not_define :: proc(t: ^testing.T) {
	s := ready()
	code, _ := tool_error(&s, "inspect_synth", `{"anything":[1,2,3]}`)
	testing.expect_value(t, code, "daemon_unavailable")
}

@(test)
test_apply_parameters_refuses_bad_arguments_before_contacting_the_daemon :: proc(t: ^testing.T) {
	s := ready()
	bad := []string {
		`{}`,
		`{"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":0}`,
		`{"expected_revision":-1,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":1.5,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":"0","parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":null,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":true,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":9007199254740992,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":1e400,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":0,"parameters":{"id":"filter.cutoff","value":1}}`,
		`{"expected_revision":0,"parameters":"filter.cutoff"}`,
		`{"expected_revision":0,"parameters":null}`,
		`{"expected_revision":0,"parameters":[1]}`,
		`{"expected_revision":0,"parameters":[null]}`,
		`{"expected_revision":0,"parameters":[[]]}`,
		`{"expected_revision":0,"parameters":[{"value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff"}]}`,
		`{"expected_revision":0,"parameters":[{"id":"","value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":5,"value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":null,"value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1.5}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":"1"}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":null}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":false}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":9007199254740992}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":-9007199254740992}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1e400}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1},{"id":"filter.cutoff","value":2.5}]}`,
	}
	for arguments in bad {
		code, _ := tool_error(&s, "apply_parameters", arguments)
		testing.expectf(t, code == "invalid_arguments", "%s -> %q", arguments, code)
	}
}

@(test)
test_apply_parameters_refuses_ids_that_would_split_into_two_qcp_tokens :: proc(t: ^testing.T) {
	s := ready()
	// One entry per class the daemon's whitespace split or a line frame would
	// turn into more than one token: ASCII and Unicode spaces, every control,
	// DEL, the C1 block, and the line and paragraph separators.
	ids := []string {
		"a b", " a", "a ", "a\\tb", "a\\nb", "a\\rb", "a\\u000bb", "a\\u000cb", "a\\u0000b", "a\\u0001b", "a\\u001fb",
		"a\\u007fb", "a\\u0080b", "a\\u0085b", "a\\u009fb", "a\\u00a0b", "a\\u1680b", "a\\u2000b", "a\\u2003b",
		"a\\u200ab", "a\\u2028b", "a\\u2029b", "a\\u202fb", "a\\u205fb", "a\\u3000b",
	}
	for id in ids {
		arguments := fmt.tprintf(`{{"expected_revision":0,"parameters":[{{"id":"%s","value":1}}]}}`, id)
		code, _ := tool_error(&s, "apply_parameters", arguments)
		testing.expectf(t, code == "invalid_arguments", "id %s -> %q", id, code)
	}
}

@(test)
test_apply_parameters_accepts_what_the_daemon_alone_can_judge :: proc(t: ^testing.T) {
	s := ready()
	// Each of these reaches the (absent) daemon instead of being refused here:
	// registry membership, ranges, duplicates, order, unknown keys, integers
	// spelled as floats, non-ASCII ids, ids with punctuation, and an empty batch.
	accepted := []string {
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":"no.such.parameter","value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":2000000}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":-5}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1},{"id":"filter.cutoff","value":2}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1.0}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1e2}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":9007199254740991}]}`,
		`{"expected_revision":9007199254740991,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":3.0,"parameters":[{"id":"filter.cutoff","value":1}]}`,
		`{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":1,"note":"extra"}],"comment":"extra"}`,
		`{"expected_revision":0,"parameters":[{"id":"é.ü=1","value":1}]}`,
		`{"expected_revision":0,"parameters":[]}`,
	}
	for arguments in accepted {
		code, _ := tool_error(&s, "apply_parameters", arguments)
		testing.expectf(t, code == "daemon_unavailable", "%s -> %q", arguments, code)
	}
}

@(test)
test_resources_read_refuses_a_missing_uri_and_an_unknown_one :: proc(t: ^testing.T) {
	s := ready()
	for params in ([]string{`{}`, `{"uri":5}`, `{"uri":null}`}) {
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"resources/read","params":%s}}`, params)), -32602)
		testing.expect_value(t, e.message, "resources/read needs a uri")
	}
	e := expect_error(t, send(&s, `{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"quesynth://other"}}`), -32002)
	testing.expect_value(t, e.message, "Resource not found")
}

@(test)
test_a_resource_read_without_a_daemon_names_the_code_in_the_message_and_in_data :: proc(t: ^testing.T) {
	s := ready()
	for uri in ([]string{"quesynth://parameters", "quesynth://patch"}) {
		reply := send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{{"uri":"%s"}}}}`, uri))
		e := expect_error(t, reply, -32000)
		testing.expect(t, strings.has_prefix(e.message, "daemon_unavailable: "), e.message)
		data, is_object := e.data.(json.Object)
		testing.expectf(t, is_object, "error.data missing in %q", reply)
		testing.expect_value(t, text_of(data["code"]), "daemon_unavailable")
	}
}
