package mcp_tests

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../hosts/standalone/mcp"

// What tools/list must say, written out by hand from the control protocol and
// the design -- not read back from the tool table -- so a tool added, renamed
// or mis-described in the table fails here instead of agreeing with itself.

HANDLER_SOURCE :: #directory + "../../hosts/standalone/command_handler.odin"

SAFE :: 9007199254740991

// How one argument is declared: its JSON type, whether it is required, and the
// inclusive bounds of an integer.
Arg_Spec :: struct {
	name:     string,
	type:     enum {Integer, Token, Text, Pairs},
	required: bool,
	min, max: int,
}

Tool_Spec :: struct {
	name:        string,
	// The QCP command the tool sends; empty for the two tools that make
	// several requests.
	command:     string,
	args:        []Arg_Spec,
	read_only:   bool,
	destructive: bool,
	idempotent:  bool,
}

SPECS := [?]Tool_Spec {
	{name = "inspect_synth", read_only = true, idempotent = true},
	{
		name = "apply_parameters",
		destructive = true,
		idempotent = true,
	},
	{name = "daemon_status", command = "daemon.status", read_only = true, idempotent = true},
	{name = "daemon_info", command = "daemon.info", read_only = true, idempotent = true},
	{name = "daemon_shutdown", command = "daemon.shutdown", destructive = true, idempotent = true},
	{name = "parameter_list", command = "parameter.list", read_only = true, idempotent = true},
	{
		name = "parameter_get",
		command = "parameter.get",
		args = {{name = "id", type = .Token, required = true}},
		read_only = true,
		idempotent = true,
	},
	{
		name = "parameter_set",
		command = "parameter.set",
		args = {{name = "id", type = .Token, required = true}, {name = "value", type = .Integer, required = true, min = -SAFE, max = SAFE}},
		destructive = true,
		idempotent = true,
	},
	{
		name = "parameter_set_many",
		command = "parameter.set_many",
		args = {{name = "expected_revision", type = .Integer, min = 0, max = SAFE}, {name = "parameters", type = .Pairs, required = true}},
		destructive = true,
		idempotent = true,
	},
	{name = "state_snapshot", command = "state.snapshot", read_only = true, idempotent = true},
	{
		name = "patch_load",
		command = "patch.load",
		args = {{name = "slot", type = .Integer, required = true, min = 0, max = 127}},
		destructive = true,
	},
	{
		name = "patch_apply",
		command = "patch.apply",
		args = {{name = "parameters", type = .Pairs, required = true}},
		destructive = true,
	},
	{
		name = "patch_load_file",
		command = "patch.load_file",
		args = {{name = "path", type = .Text, required = true}},
		destructive = true,
	},
	{
		name = "patch_save",
		command = "patch.save",
		args = {{name = "slot", type = .Integer, required = true, min = 0, max = 127}, {name = "name", type = .Text}},
		destructive = true,
		idempotent = true,
	},
	{name = "patch_current", command = "patch.current", read_only = true, idempotent = true},
	{name = "patch_clear", command = "patch.clear", destructive = true, idempotent = true},
	{name = "bank_list", command = "bank.list", read_only = true, idempotent = true},
	{
		name = "bank_write",
		command = "bank.write",
		args = {{name = "path", type = .Text, required = true}},
		destructive = true,
		idempotent = true,
	},
	{
		name = "bank_load_file",
		command = "bank.load_file",
		args = {{name = "path", type = .Text, required = true}},
		destructive = true,
		idempotent = true,
	},
	{name = "bank_keep", command = "bank.keep", destructive = true, idempotent = true},
	{
		name = "archive_open",
		command = "archive.open",
		args = {{name = "path", type = .Text}},
		destructive = true,
		idempotent = true,
	},
	{
		name = "archive_adopt",
		command = "archive.adopt",
		args = {{name = "path", type = .Text, required = true}},
		idempotent = true,
	},
	{name = "archive_current", command = "archive.current", read_only = true, idempotent = true},
	{
		name = "archive_banks",
		command = "archive.banks",
		args = {{name = "offset", type = .Integer, min = 0, max = SAFE}, {name = "count", type = .Integer, min = 0, max = SAFE}},
		read_only = true,
		idempotent = true,
	},
	{
		name = "archive_bank",
		command = "archive.bank",
		args = {{name = "index", type = .Integer, required = true, min = 0, max = SAFE}},
		idempotent = true,
	},
	{
		name = "archive_patches",
		command = "archive.patches",
		args = {{name = "offset", type = .Integer, min = 0, max = SAFE}, {name = "count", type = .Integer, min = 0, max = SAFE}},
		read_only = true,
		idempotent = true,
	},
	{
		name = "archive_load",
		command = "archive.load",
		args = {{name = "index", type = .Integer, required = true, min = 0, max = SAFE}, {name = "bank", type = .Integer, min = 0, max = SAFE}},
		destructive = true,
	},
	{name = "archive_close", command = "archive.close", destructive = true, idempotent = true},
	{name = "midi_list", command = "midi.list", read_only = true, idempotent = true},
	{
		name = "midi_select",
		command = "midi.select",
		args = {{name = "input", type = .Token, required = true}},
		idempotent = true,
	},
	{name = "midi_current", command = "midi.current", read_only = true, idempotent = true},
	{
		name = "midi_send",
		command = "midi",
		args = {
			{name = "status", type = .Integer, required = true, min = 0, max = 255},
			{name = "data1", type = .Integer, required = true, min = 0, max = 127},
			{name = "data2", type = .Integer, required = true, min = 0, max = 127},
		},
	},
	{
		name = "volume",
		command = "volume",
		args = {{name = "milli", type = .Integer, required = true, min = 0, max = 1000}},
		idempotent = true,
	},
}

// The one reply schema of every tool but the two older ones.
REPLY_OUTPUT :: `{"additionalProperties":false,"properties":{"fields":{"description":"The text after ok on the first line of the daemon's reply.","type":"string"},"lines":{"description":"The record lines that follow it, unchanged and in the daemon's order.","items":{"type":"string"},"type":"array"}},"required":["fields","lines"],"type":"object"}`

@(private = "file")
RECORDS_OUTPUT :: `{"additionalProperties":false,"properties":{"fields":{"type":"string"},"lines":{"items":{"type":"string"},"type":"array"}},"required":["fields","lines"],"type":"object"}`

// Numbers parse as doubles here, as they do in a client.
@(private = "file")
number_of :: proc(value: json.Value) -> int {
	switch v in value {
	case json.Float: return int(v)
	case json.Integer: return int(v)
	case json.Null, json.Boolean, json.String, json.Array, json.Object: return min(int)
	}
	return min(int)
}

// A JSON false that is there, not merely absent.
@(private = "file")
is_false :: proc(value: json.Value) -> bool {
	flag, is_boolean := value.(json.Boolean)
	return is_boolean && !bool(flag)
}

@(private = "file")
listed_tools :: proc(s: ^mcp.Session) -> json.Array {
	reply := send(s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	result, _ := parse_object(reply)["result"].(json.Object)
	tools, _ := result["tools"].(json.Array)
	return tools
}

@(private = "file")
tool_named :: proc(tools: json.Array, name: string) -> (tool: json.Object, found: bool) {
	for entry in tools {
		object, _ := entry.(json.Object)
		if text_of(object["name"]) == name { return object, true }
	}
	return nil, false
}

@(private = "file")
encoded :: proc(value: json.Value) -> string {
	data, err := json.unparse(value, {sort_maps_by_key = true}, allocator = context.temp_allocator)
	assert(err == nil)
	return data
}

// The `case "<command>":` lines of control_handle, which is what the daemon
// dispatches on, read from its source.
@(private = "file")
handler_commands :: proc() -> [dynamic]string {
	bytes, err := os.read_entire_file(HANDLER_SOURCE, context.temp_allocator)
	assert(err == nil)
	commands := make([dynamic]string, context.temp_allocator)
	text := string(bytes)
	start := strings.index(text, "control_handle :: proc(")
	assert(start >= 0)
	text = text[start:]
	// The procedure ends at the first line that closes at column zero.
	end := strings.index(text, "\n}\n")
	assert(end >= 0)
	for line in strings.split_lines(text[:end], context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, `case "`) { continue }
		rest := trimmed[len(`case "`):]
		quote := strings.index_byte(rest, '"')
		assert(quote > 0)
		append(&commands, rest[:quote])
	}
	return commands
}

@(test)
test_the_handler_dispatches_the_thirty_one_commands_this_server_was_written_against :: proc(t: ^testing.T) {
	commands := handler_commands()
	// If the daemon gains or loses a command this fails, and the tool table,
	// SPECS and the manual need to follow before the number here moves.
	testing.expect_value(t, len(commands), 31)
}

@(test)
test_every_command_the_handler_dispatches_has_exactly_one_tool_and_no_tool_has_another :: proc(t: ^testing.T) {
	commands := handler_commands()
	for command in commands {
		owners := 0
		for &tool in mcp.TOOLS {
			if tool.handler == .Command && tool.command == command { owners += 1 }
		}
		testing.expectf(t, owners == 1, "command %q has %d tools", command, owners)
	}
	for &tool in mcp.TOOLS {
		switch tool.handler {
		case .Command:
			known := false
			for command in commands { known ||= command == tool.command }
			testing.expectf(t, known, "tool %q sends %q, which the handler does not dispatch", tool.name, tool.command)
		case .Inspect, .Apply:
			testing.expectf(t, tool.command == "", "%q builds its own requests", tool.name)
		}
	}
	// The same, from the independent table of what each tool is meant to send.
	for spec in SPECS {
		if spec.command == "" { continue }
		known := false
		for command in commands { known ||= command == spec.command }
		testing.expectf(t, known, "SPECS has %q sending %q, which the handler does not dispatch", spec.name, spec.command)
		tool := mcp.find_tool(spec.name)
		if testing.expectf(t, tool != nil, "%q is not in the tool table", spec.name) {
			testing.expect_value(t, tool.command, spec.command)
		}
	}
}

@(test)
test_tools_list_has_thirty_three_uniquely_named_tools_in_the_documented_order :: proc(t: ^testing.T) {
	s := ready()
	tools := listed_tools(&s)
	testing.expect_value(t, len(tools), 33)
	testing.expect_value(t, len(SPECS), 33)
	seen := make(map[string]bool, context.temp_allocator)
	for entry, i in tools {
		object, _ := entry.(json.Object)
		name := text_of(object["name"])
		testing.expectf(t, !seen[name], "%q is listed twice", name)
		seen[name] = true
		if i < len(SPECS) { testing.expect_value(t, name, SPECS[i].name) }
		testing.expectf(t, text_of(object["description"]) != "", "%q has no description", name)
	}
}

@(test)
test_no_tool_takes_a_command_a_line_or_a_free_form_list_of_operands :: proc(t: ^testing.T) {
	s := ready()
	tools := listed_tools(&s)
	// What a gateway needs to be told. A tool with one of these, whatever its
	// type, could carry a command, so none may exist.
	forbidden := []string {
		"command", "cmd", "verb", "line", "raw", "qcp", "request", "operands", "operand", "argv", "args", "arguments",
		"shell", "exec", "script", "url", "uri", "host", "port", "payload", "text", "message",
	}
	for entry in tools {
		tool, _ := entry.(json.Object)
		name := text_of(tool["name"])
		schema, _ := tool["inputSchema"].(json.Object)
		properties, _ := schema["properties"].(json.Object)
		for key in properties {
			for word in forbidden { testing.expectf(t, key != word, "%q takes an argument named %q", name, key) }
		}
		if name == "inspect_synth" || name == "apply_parameters" { continue }
		// Closed: an argument that is not declared is refused.
		testing.expectf(t, is_false(schema["additionalProperties"]), "%q does not close its arguments", name)
	}
	// And a name the table does not hold cannot be called by any spelling of
	// a QCP command.
	for command in handler_commands() {
		// volume is both a command and the tool that sends it.
		if mcp.find_tool(command) != nil { continue }
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":%q,"arguments":{{}}}}}}`, command)), -32602)
		testing.expect_value(t, e.message, "Unknown tool")
	}
	for name in ([]string{"", "qcp", "command", "send_command", "run", "exec", "shell", "call", "raw", "daemon.status", "Daemon_Status"}) {
		e := expect_error(t, send(&s, fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":%q,"arguments":{{}}}}}}`, name)), -32602)
		testing.expect_value(t, e.message, "Unknown tool")
	}
}

@(test)
test_annotations_are_exactly_the_documented_table_on_every_tool :: proc(t: ^testing.T) {
	s := ready()
	tools := listed_tools(&s)
	for spec in SPECS {
		tool, found := tool_named(tools, spec.name)
		if !testing.expectf(t, found, "%q is not listed", spec.name) { continue }
		annotations, is_object := tool["annotations"].(json.Object)
		if !testing.expectf(t, is_object, "%q has no annotations", spec.name) { continue }
		testing.expectf(t, len(annotations) == 4, "%q has %d hints", spec.name, len(annotations))
		hints := [?]struct {
			name: string,
			want: bool,
		}{{"readOnlyHint", spec.read_only}, {"destructiveHint", spec.destructive}, {"idempotentHint", spec.idempotent}, {"openWorldHint", false}}
		for hint in hints {
			got, is_boolean := annotations[hint.name].(json.Boolean)
			testing.expectf(t, is_boolean, "%q: %s is not a boolean", spec.name, hint.name)
			testing.expectf(t, bool(got) == hint.want, "%q: %s is %v, want %v", spec.name, hint.name, bool(got), hint.want)
		}
		// The definitions: a read-only tool is never destructive, and what is
		// destructive is never read-only.
		testing.expectf(t, !(spec.read_only && spec.destructive), "%q is both read-only and destructive", spec.name)
	}
}

@(private = "file")
expect_property :: proc(t: ^testing.T, tool: string, properties: json.Object, a: Arg_Spec) {
	property, found := properties[a.name].(json.Object)
	if !testing.expectf(t, found, "%q declares no argument %q", tool, a.name) { return }
	testing.expectf(t, text_of(property["description"]) != "", "%q.%s has no description", tool, a.name)
	switch a.type {
	case .Integer:
		testing.expect_value(t, text_of(property["type"]), "integer")
		minimum, maximum := number_of(property["minimum"]), number_of(property["maximum"])
		testing.expectf(t, minimum == a.min && maximum == a.max, "%q.%s runs %d..%d, want %d..%d", tool, a.name, minimum, maximum, a.min, a.max)
	case .Token:
		testing.expect_value(t, text_of(property["type"]), "string")
		testing.expect_value(t, text_of(property["pattern"]), mcp.TOKEN_PATTERN)
		testing.expect_value(t, number_of(property["minLength"]), 1)
	case .Text:
		testing.expect_value(t, text_of(property["type"]), "string")
		_, has_min := property["minLength"]
		if a.required {
			testing.expect_value(t, text_of(property["pattern"]), mcp.TEXT_PATTERN)
			testing.expect_value(t, number_of(property["minLength"]), 1)
		} else {
			// Empty means "leave it out", so it must be allowed.
			testing.expect_value(t, text_of(property["pattern"]), mcp.OPTIONAL_TEXT_PATTERN)
			testing.expect(t, !has_min, "an optional text must allow the empty string")
		}
	case .Pairs:
		testing.expect_value(t, text_of(property["type"]), "array")
		testing.expect_value(t, number_of(property["minItems"]), 1)
		testing.expect_value(t, number_of(property["maxItems"]), 128)
		items, _ := property["items"].(json.Object)
		testing.expect_value(t, text_of(items["type"]), "object")
		testing.expectf(t, is_false(items["additionalProperties"]), "%q does not close its pairs", tool)
		required, _ := items["required"].(json.Array)
		testing.expect_value(t, encoded(required), `["id","value"]`)
		entry, _ := items["properties"].(json.Object)
		testing.expect_value(t, len(entry), 2)
		id, _ := entry["id"].(json.Object)
		testing.expect_value(t, text_of(id["pattern"]), mcp.TOKEN_PATTERN)
		value, _ := entry["value"].(json.Object)
		testing.expect_value(t, text_of(value["type"]), "integer")
		lowest, highest := number_of(value["minimum"]), number_of(value["maximum"])
		testing.expectf(t, lowest == -SAFE && highest == SAFE, "%q pair values run %d..%d", tool, lowest, highest)
	}
}

@(test)
test_input_schemas_declare_exactly_the_documented_arguments_and_nothing_else :: proc(t: ^testing.T) {
	s := ready()
	tools := listed_tools(&s)
	for spec in SPECS[2:] {
		tool, found := tool_named(tools, spec.name)
		if !testing.expectf(t, found, "%q is not listed", spec.name) { continue }
		schema, _ := tool["inputSchema"].(json.Object)
		testing.expect_value(t, text_of(schema["type"]), "object")
		properties, has_properties := schema["properties"].(json.Object)
		testing.expectf(t, has_properties, "%q has no properties object", spec.name)
		testing.expectf(t, len(properties) == len(spec.args), "%q declares %d arguments, want %d", spec.name, len(properties), len(spec.args))
		required_names := make([dynamic]string, context.temp_allocator)
		for a in spec.args {
			expect_property(t, spec.name, properties, a)
			if a.required { append(&required_names, a.name) }
		}
		required, has_required := schema["required"].(json.Array)
		if len(required_names) == 0 {
			// Nothing to require: the key is left out rather than empty.
			testing.expectf(t, !has_required, "%q lists required arguments", spec.name)
			continue
		}
		testing.expectf(t, has_required, "%q lists no required arguments", spec.name)
		got := make([dynamic]string, context.temp_allocator)
		for name in required { append(&got, text_of(name)) }
		testing.expect_value(t, strings.join(got[:], ",", context.temp_allocator), strings.join(required_names[:], ",", context.temp_allocator))
	}
}

@(test)
test_the_two_older_tools_keep_their_descriptions_and_input_schemas_byte_for_byte :: proc(t: ^testing.T) {
	// Copied from the tools/list of the release before the full surface: the
	// words and schemas a client wrote its calls against. Matched in the reply
	// itself, since a parsed number would not show how it was written.
	s := ready()
	reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	fragments := []string {
		`{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":true},"description":"Read current parameter values, the daemon's registry and sounding patch identity. No audio is started.","inputSchema":{"properties":{},"type":"object"},"name":"inspect_synth",`,
		`{"annotations":{"destructiveHint":true,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":false},"description":"Atomically edit stored integer parameters if the daemon revision still matches. Duplicate IDs apply in order, last wins. Inspect again after an uncertain transport failure; mutations are never retried.","inputSchema":{"properties":{"expected_revision":{"minimum":0,"type":"integer"},"parameters":{"items":{"properties":{"id":{"type":"string"},"value":{"type":"integer"}},"required":["id","value"],"type":"object"},"type":"array"}},"required":["expected_revision","parameters"],"type":"object"},"name":"apply_parameters",`,
	}
	for fragment in fragments { testing.expectf(t, strings.contains(reply, fragment), "tools/list lacks %s", fragment) }
}

@(test)
test_every_tool_declares_the_output_it_returns :: proc(t: ^testing.T) {
	s := ready()
	tools := listed_tools(&s)
	for spec in SPECS {
		tool, _ := tool_named(tools, spec.name)
		output, has_output := tool["outputSchema"].(json.Object)
		if !testing.expectf(t, has_output, "%q has no outputSchema", spec.name) { continue }
		switch spec.name {
		case "inspect_synth":
			want := `{"additionalProperties":false,"properties":{"parameters":` + RECORDS_OUTPUT + `,"patch":` + RECORDS_OUTPUT + `,"revision":{"type":"integer"},"state":` + RECORDS_OUTPUT + `},"required":["revision","state","patch","parameters"],"type":"object"}`
			testing.expect_value(t, encoded(output), want)
		case "apply_parameters":
			testing.expect_value(
				t,
				encoded(output),
				`{"additionalProperties":false,"properties":{"count":{"type":"integer"},"revision":{"type":"integer"}},"required":["count","revision"],"type":"object"}`,
			)
		case:
			testing.expect_value(t, encoded(output), REPLY_OUTPUT)
		}
	}
}

@(test)
test_tools_list_is_the_same_for_every_protocol_version_and_cursor :: proc(t: ^testing.T) {
	versions := []string{"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}
	reference: string
	for version, i in versions {
		s := ready(version)
		reply := send(&s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
		if i == 0 { reference = reply }
		testing.expectf(t, reply == reference, "tools/list differs for %s", version)
	}
}
