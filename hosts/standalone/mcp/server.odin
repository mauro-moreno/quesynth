#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "../../../src/control"

// `quesynth --mcp`: a Model Context Protocol server on stdin and stdout that is
// nothing but a client of the daemon's control socket. It holds no engine, no
// registry and no patch -- every value it reports comes from the daemon in a
// QCP reply, and what it checks itself is only that a request is well formed
// enough not to be misread on the daemon's side (tools.odin). It makes no sound
// and starts no daemon, so it answers the protocol with the daemon down and
// reports the daemon unavailable where it needs one.
//
// What it offers is the tool table in tools.odin: one typed tool for each
// command the daemon takes, and inspect_synth and apply_parameters, which make
// several requests or check an acknowledgement and so are written out here.
//
// Each QCP request gets its own short connection (transport_linux.odin). A
// request that was written is therefore never repeated by a reconnect: a change
// whose outcome is unknown is reported as such, and the caller decides.
//
// The only state kept between requests is how far the MCP handshake has got.

Session :: struct {
	phase: enum {New, Initialized, Ready},
	version: string,
}

PROTOCOL_VERSION :: "2025-11-25"

RESOURCES :: `{"resources":[
 {"uri":"quesynth://parameters","name":"parameters","description":"Daemon parameter registry: IDs, groups, indices, stored ranges, defaults and labels.","mimeType":"application/json"},
 {"uri":"quesynth://patch","name":"patch","description":"Sounding patch identity and current parameter values, read from the daemon.","mimeType":"application/json"}
]}`

// Keys are written in sorted order so a reply is the same bytes every time.
@(private)
encode :: proc(value: json.Value) -> string {
	data, err := json.unparse(value, {sort_maps_by_key = true}, allocator = context.temp_allocator)
	assert(err == nil)
	return data
}

@(private)
parse :: proc(text: string) -> json.Value {
	value, err := json.parse(transmute([]u8)text, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	assert(err == .None)
	return value
}

@(private)
rpc_error :: proc(id: json.Value, code: int, message: string, data: json.Value = nil) -> string {
	error := json.Object{"code" = json.Integer(code), "message" = message}
	if data != nil { error["data"] = data }
	return encode(json.Object{"jsonrpc" = "2.0", "id" = id, "error" = error})
}

@(private)
result :: proc(id: json.Value, value: json.Value) -> string {
	return encode(json.Object{"jsonrpc" = "2.0", "id" = id, "result" = value})
}

// Numbers parse as doubles, so only integers a double holds exactly are
// accepted: a larger one would have been rounded before it was read.
@(private)
MAX_SAFE_INTEGER :: 9007199254740991

@(private)
integer :: proc(value: json.Value) -> (int, bool) {
	if v, ok := value.(json.Float); ok && v >= -MAX_SAFE_INTEGER && v <= MAX_SAFE_INTEGER {
		n := int(v)
		return n, f64(n) == v
	}
	return 0, false
}

// The library parser accepts text after the value, trailing commas and
// malformed numbers, cuts a string short at a bad escape or a raw control
// character, turns a lone surrogate into U+FFFD, and recurses without limit.
// So each line is checked against the JSON grammar first, with nesting capped,
// and only a line that passes is parsed.
@(private)
MAX_JSON_DEPTH :: 100

@(private)
well_formed :: proc(text: string, empty: ^[dynamic]Where) -> bool {
	i := 0
	if !scan_value(text, &i, 0, {place = .Message}, empty) { return false }
	skip_space(text, &i)
	return i == len(text)
}

// The parser also keeps no member whose name is "", so a call that spelt one
// would be judged as though it had not. The scan that reads every byte anyway
// records each one inside the `arguments` of a call, so that put_back_empty_names
// can restore it for the checks that refuse a name the tool does not declare.
// Only two places matter: the arguments themselves, and an object in an array
// that one of them holds, where a pair stands. Any other object an argument can
// hold is refused for its type, whatever its members are called.
@(private)
Place :: enum {Elsewhere, Message, Params, Arguments, Member, Entry}

@(private)
Where :: struct {
	place: Place,
	// Member and Entry: the member of the arguments that is, or holds, this value.
	argument: string,
	// Entry: its position in that member's array.
	index: int,
}

// Names are compared as the parser stores them, escapes decoded, so
// "\u0061rguments" is the member `arguments` here as it is there.
@(private)
member_of :: proc(at: Where, raw_name: string) -> Where {
	name :: proc(raw: string) -> string {
		decoded, _ := json.unquote_string(json.Token{kind = .String, text = raw}, .JSON, context.temp_allocator)
		return decoded
	}
	switch at.place {
	case .Message: if name(raw_name) == "params" { return {place = .Params} }
	case .Params: if name(raw_name) == "arguments" { return {place = .Arguments} }
	case .Arguments: return {place = .Member, argument = name(raw_name)}
	case .Member, .Entry, .Elsewhere:
	}
	return {}
}

@(private)
element_of :: proc(at: Where, index: int) -> Where {
	if at.place != .Member { return {} }
	return {place = .Entry, argument = at.argument, index = index}
}

@(private)
put_back_empty_names :: proc(args: ^json.Object, empty: []Where) {
	for at in empty {
		if at.place == .Arguments {
			args[""] = json.Null{}
			continue
		}
		entries, is_array := args[at.argument].(json.Array)
		if !is_array { continue }
		entry, is_object := entries[at.index].(json.Object)
		if !is_object { continue }
		entry[""] = json.Null{}
		entries[at.index] = entry
	}
}

@(private)
skip_space :: proc(text: string, i: ^int) {
	for i^ < len(text) && (text[i^] == ' ' || text[i^] == '\t' || text[i^] == '\r' || text[i^] == '\n') { i^ += 1 }
}

@(private)
scan_value :: proc(text: string, i: ^int, depth: int, at: Where, empty: ^[dynamic]Where) -> bool {
	skip_space(text, i)
	if i^ >= len(text) { return false }
	switch text[i^] {
	case '{':
		if depth >= MAX_JSON_DEPTH { return false }
		i^ += 1
		skip_space(text, i)
		if i^ < len(text) && text[i^] == '}' { i^ += 1; return true }
		for {
			skip_space(text, i)
			start := i^
			if !scan_string(text, i) { return false }
			name := text[start:i^]
			skip_space(text, i)
			if i^ >= len(text) || text[i^] != ':' { return false }
			i^ += 1
			if name == `""` && (at.place == .Arguments || at.place == .Entry) { append(empty, at) }
			if !scan_value(text, i, depth + 1, member_of(at, name), empty) { return false }
			skip_space(text, i)
			if i^ >= len(text) { return false }
			c := text[i^]
			i^ += 1
			if c == '}' { return true }
			if c != ',' { return false }
		}
	case '[':
		if depth >= MAX_JSON_DEPTH { return false }
		i^ += 1
		skip_space(text, i)
		if i^ < len(text) && text[i^] == ']' { i^ += 1; return true }
		for index := 0; ; index += 1 {
			if !scan_value(text, i, depth + 1, element_of(at, index), empty) { return false }
			skip_space(text, i)
			if i^ >= len(text) { return false }
			c := text[i^]
			i^ += 1
			if c == ']' { return true }
			if c != ',' { return false }
		}
	case '"': return scan_string(text, i)
	case 't': return scan_word(text, i, "true")
	case 'f': return scan_word(text, i, "false")
	case 'n': return scan_word(text, i, "null")
	}
	return scan_number(text, i)
}

@(private)
scan_word :: proc(text: string, i: ^int, word: string) -> bool {
	if !strings.has_prefix(text[i^:], word) { return false }
	i^ += len(word)
	return true
}

@(private)
scan_digits :: proc(text: string, j: int) -> int {
	end := j
	for end < len(text) && text[end] >= '0' && text[end] <= '9' { end += 1 }
	return end
}

@(private)
scan_number :: proc(text: string, i: ^int) -> bool {
	j := i^
	if j < len(text) && text[j] == '-' { j += 1 }
	if j >= len(text) { return false }
	if text[j] == '0' {
		j += 1
	} else if text[j] >= '1' && text[j] <= '9' {
		j = scan_digits(text, j)
	} else {
		return false
	}
	if j < len(text) && text[j] == '.' {
		end := scan_digits(text, j + 1)
		if end == j + 1 { return false }
		j = end
	}
	if j < len(text) && (text[j] == 'e' || text[j] == 'E') {
		j += 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') { j += 1 }
		end := scan_digits(text, j)
		if end == j { return false }
		j = end
	}
	i^ = j
	return true
}

@(private)
hex4 :: proc(text: string, at: int) -> (unit: int, ok: bool) {
	if at + 4 > len(text) { return 0, false }
	for c in text[at:at + 4] {
		switch c {
		case '0' ..= '9': unit = unit * 16 + int(c - '0')
		case 'a' ..= 'f': unit = unit * 16 + int(c - 'a') + 10
		case 'A' ..= 'F': unit = unit * 16 + int(c - 'A') + 10
		case: return 0, false
		}
	}
	return unit, true
}

// A string is well formed when it holds no raw control character, only the
// JSON escapes, valid UTF-8 and surrogate escapes that come in high-low pairs,
// since a lone surrogate has no UTF-8 form to echo or forward.
@(private)
scan_string :: proc(text: string, i: ^int) -> bool {
	if i^ >= len(text) || text[i^] != '"' { return false }
	i^ += 1
	for i^ < len(text) {
		c := text[i^]
		switch {
		case c == '"':
			i^ += 1
			return true
		case c < 0x20:
			return false
		case c == '\\':
			i^ += 1
			if i^ >= len(text) { return false }
			switch text[i^] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				i^ += 1
			case 'u':
				unit, ok := hex4(text, i^ + 1)
				if !ok { return false }
				i^ += 5
				if unit >= 0xDC00 && unit <= 0xDFFF { return false }
				if unit >= 0xD800 && unit <= 0xDBFF {
					if i^ + 1 >= len(text) || text[i^] != '\\' || text[i^ + 1] != 'u' { return false }
					low, low_ok := hex4(text, i^ + 2)
					if !low_ok || low < 0xDC00 || low > 0xDFFF { return false }
					i^ += 6
				}
			case:
				return false
			}
		case c < 0x80:
			i^ += 1
		case:
			r, width := utf8.decode_rune_in_string(text[i^:])
			if r == utf8.RUNE_ERROR && width == 1 { return false }
			i^ += width
		}
	}
	return false
}

@(private)
field_int :: proc(fields, key: string) -> (int, bool) {
	value, found := control.response_field(fields, key)
	if !found { return 0, false }
	return strconv.parse_int(value)
}

// QCP records remain verbatim. Metadata is never reconstructed from a local
// registry, and patch names keep whitespace and unknown daemon fields.
@(private)
records :: proc(resp: control.Response) -> json.Object {
	lines := make(json.Array, 0, 0, context.temp_allocator)
	if resp.body != "" {
		body := resp.body
		for line in strings.split_iterator(&body, "\n") { append(&lines, line) }
	}
	return json.Object{"fields" = resp.fields, "lines" = lines}
}

Failure :: struct {
	code: string,
	message: string,
}

// QCP envelope tokens are separated by ASCII spaces. Remove only the one
// separator after a token so the remaining text can be returned verbatim.
@(private)
reply_token :: proc(text: string) -> (token, rest: string) {
	i := 0
	for i < len(text) && text[i] == ' ' { i += 1 }
	start := i
	for i < len(text) && text[i] != ' ' { i += 1 }
	token = text[start:i]
	if i < len(text) { i += 1 }
	return token, text[i:]
}

// The two older tools and the resources trim a reply's text at both ends, as
// they always have. The other tools pass it on verbatim, minus the single space
// that separates it from the token before it.
@(private)
request :: proc(path, command: string, changes := false, verbatim := false) -> (control.Response, Failure) {
	payload, failure, sent := roundtrip(path, fmt.tprintf("%d 1 %s", control.PROTOCOL_VERSION, command))
	if failure.code != "" { return {}, unsure(failure, sent && changes) }
	// JSON has no verbatim representation for malformed UTF-8. Refuse the
	// entire reply rather than normalizing it or guessing a byte encoding.
	if !utf8.valid_string(string(payload)) {
		return {}, unsure({"daemon_error", "QCP response is not valid UTF-8"}, sent && changes)
	}
	resp, ok := control.response_parse(payload)
	if !ok || resp.version != control.PROTOCOL_VERSION || resp.id != 1 {
		return {}, unsure({"daemon_error", "invalid QCP response"}, changes)
	}
	envelope := string(payload)
	if end := strings.index_byte(envelope, '\n'); end >= 0 { envelope = envelope[:end] }
	for _ in 0 ..< 3 { _, envelope = reply_token(envelope) }
	if resp.status == .Err {
		// control.Error_Code has no room for a token the daemon added later.
		code, message := reply_token(envelope)
		if code == "" { code = control.error_code_name(.Internal_Error) }
		return {}, {code, verbatim ? message : resp.fields}
	}
	if verbatim { resp.fields = envelope }
	return resp, {}
}

// A read that failed can be asked again. A change whose request was written
// cannot be told from one that took effect, and is never sent a second time.
@(private)
unsure :: proc(failure: Failure, sent: bool) -> Failure {
	if !sent { return failure }
	return {failure.code, fmt.tprintf("%s; the request was sent and the change may have been applied", failure.message)}
}

@(private)
inspect :: proc(path: string, registry: bool) -> (json.Object, Failure) {
	state, err := request(path, "state.snapshot")
	if err.code != "" { return nil, err }
	revision, ok := field_int(state.fields, "revision")
	if !ok { return nil, {"daemon_error", "snapshot has no revision"} }
	patch: control.Response
	patch, err = request(path, "patch.current")
	if err.code != "" { return nil, err }
	value := json.Object{"revision" = json.Integer(revision), "state" = records(state), "patch" = records(patch)}
	if registry {
		parameters, err := request(path, "parameter.list")
		if err.code != "" { return nil, err }
		value["parameters"] = records(parameters)
	}
	return value, {}
}

@(private)
apply :: proc(path: string, args: json.Object) -> (json.Object, Failure) {
	revision, valid_revision := integer(args["expected_revision"])
	parameters, valid_parameters := args["parameters"].(json.Array)
	if !valid_revision || revision < 0 || !valid_parameters {
		return nil, {"invalid_arguments", "expected_revision and parameters array are required"}
	}
	command := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&command, "parameter.set_many expected_revision=%d", revision)
	for entry in parameters {
		obj, is_object := entry.(json.Object)
		id, is_id := obj["id"].(string)
		value, is_value := integer(obj["value"])
		if !is_object || !is_id || !is_value || id == "" {
			return nil, {"invalid_arguments", "each parameter needs an id token and an integer value"}
		}
		for c in id {
			if !is_token_rune(c) {
				return nil, {"invalid_arguments", "parameter id is not a QCP token"}
			}
		}
		fmt.sbprintf(&command, " %s %d", id, value)
	}
	resp, err := request(path, strings.to_string(command), true)
	if err.code != "" { return nil, err }
	count, count_ok := field_int(resp.fields, "count")
	applied_revision, revision_ok := field_int(resp.fields, "revision")
	if !count_ok || !revision_ok {
		return nil, {"daemon_error", "invalid mutation acknowledgement"}
	}
	return json.Object{"count" = json.Integer(count), "revision" = json.Integer(applied_revision)}, {}
}

@(private)
tool_result :: proc(s: ^Session, id: json.Value, value: json.Object, err: Failure) -> string {
	value := value
	if err.code != "" {
		value = json.Object{"code" = err.code, "message" = err.message}
	}
	out := json.Object{"content" = json.Array{json.Object{"type" = "text", "text" = encode(value)}}}
	if err.code != "" { out["isError"] = true }
	if s.version >= "2025-06-18" { out["structuredContent"] = value }
	return result(id, out)
}

// Handle allocates its response and parsed data with the caller's temporary
// allocator. Only the protocol phase/version survive between requests.
handle :: proc(s: ^Session, line, path: string) -> string {
	context.allocator = context.temp_allocator
	empty: [dynamic]Where
	if !well_formed(line, &empty) { return rpc_error(nil, -32700, "Invalid JSON") }
	message, parse_err := json.parse(transmute([]u8)line, spec = .JSON)
	if parse_err != .None { return rpc_error(nil, -32700, "Invalid JSON") }
	obj, is_object := message.(json.Object)
	id, has_id := obj["id"]
	method, has_method := obj["method"].(string)
	version, _ := obj["jsonrpc"].(string)
	// An id is echoed exactly or the request is refused: a string as it came,
	// a number only when it is an integer, which is then written without a
	// fraction.
	valid_id := false
	#partial switch v in id {
	case string:
		valid_id = true
	case json.Float:
		if n, ok := integer(v); ok {
			id = json.Integer(n)
			valid_id = true
		}
	}
	if !is_object || version != "2.0" || !has_method || (has_id && !valid_id) {
		return rpc_error(nil, -32600, "Invalid JSON-RPC request")
	}
	if !has_id {
		if method == "notifications/initialized" && s.phase == .Initialized { s.phase = .Ready }
		return ""
	}
	params := json.Object{}
	if p, present := obj["params"]; present {
		ok: bool
		params, ok = p.(json.Object)
		if !ok { return rpc_error(id, -32602, "params must be an object") }
	}
	switch method {
	case "ping": return result(id, json.Object{})
	case "initialize":
		if s.phase != .New { return rpc_error(id, -32600, "Already initialized") }
		requested, vok := params["protocolVersion"].(string)
		_, cok := params["capabilities"].(json.Object)
		client, iok := params["clientInfo"].(json.Object)
		_, nok := client["name"].(string)
		_, rok := client["version"].(string)
		if !vok || !cok || !iok || !nok || !rok {
			return rpc_error(id, -32602, "initialize needs protocolVersion, capabilities and clientInfo")
		}
		s.version = PROTOCOL_VERSION
		switch requested {
		case "2024-11-05": s.version = "2024-11-05"
		case "2025-03-26": s.version = "2025-03-26"
		case "2025-06-18": s.version = "2025-06-18"
		}
		s.phase = .Initialized
		return result(id, json.Object{"protocolVersion" = s.version,
			"capabilities" = json.Object{"tools" = json.Object{}, "resources" = json.Object{}},
			"serverInfo" = json.Object{"name" = "quesynth", "version" = "1.0.0"}})
	case "tools/list", "tools/call", "resources/list", "resources/read":
		if s.phase != .Ready { return rpc_error(id, -32000, "Initialize and send notifications/initialized first") }
	case: return rpc_error(id, -32601, "Method not found")
	}
	switch method {
	case "tools/list": return result(id, tool_list())
	case "resources/list": return result(id, parse(RESOURCES))
	case "resources/read":
		uri, ok := params["uri"].(string)
		if !ok { return rpc_error(id, -32602, "resources/read needs a uri") }
		value: json.Object
		err: Failure
		switch uri {
		case "quesynth://parameters":
			resp: control.Response
			resp, err = request(path, "parameter.list")
			value = records(resp)
		case "quesynth://patch": value, err = inspect(path, false)
		case: return rpc_error(id, -32002, "Resource not found")
		}
		if err.code != "" {
			return rpc_error(id, -32000, fmt.tprintf("%s: %s", err.code, err.message), json.Object{"code" = err.code})
		}
		return result(id, json.Object{"contents" = json.Array{json.Object{"uri" = uri,
			"mimeType" = "application/json", "text" = encode(value)}}})
	case "tools/call":
		name, ok := params["name"].(string)
		if !ok { return rpc_error(id, -32602, "tools/call needs a tool name") }
		tool := find_tool(name)
		if tool == nil { return rpc_error(id, -32602, "Unknown tool") }
		args := json.Object{}
		if a, exists := params["arguments"]; exists {
			args, ok = a.(json.Object)
			if !ok { return tool_result(s, id, nil, {"invalid_arguments", "arguments must be an object"}) }
			put_back_empty_names(&args, empty[:])
		}
		value: json.Object
		err: Failure
		switch tool.handler {
		case .Inspect: value, err = inspect(path, true)
		case .Apply: value, err = apply(path, args)
		case .Command: value, err = forward(path, tool, args)
		}
		return tool_result(s, id, value, err)
	}
	unreachable()
}

run :: proc(path: string) -> int {
	return serve(os.to_stream(os.stdin), os.to_stream(os.stdout), path)
}

// One request per line, split on "\n" only: U+2028 and U+2029 are legal inside
// a JSON string and stay inside the request. A final line with no newline is
// answered at end of input. Nothing but replies is ever written to `output`.
serve :: proc(input: io.Reader, output: io.Writer, path: string) -> int {
	s: Session
	line: [dynamic]u8
	defer delete(line)
	reply :: proc(output: io.Writer, s: ^Session, line: []u8, path: string) {
		text := handle(s, string(line), path)
		if text != "" {
			io.write_string(output, text)
			io.write_byte(output, '\n')
		}
		free_all(context.temp_allocator)
	}
	buf: [4096]u8
	for {
		n, err := io.read(input, buf[:])
		for byte in buf[:n] {
			if byte != '\n' { append(&line, byte); continue }
			reply(output, &s, line[:], path)
			clear(&line)
		}
		if n == 0 || err != nil { break }
	}
	if len(line) > 0 { reply(output, &s, line[:], path) }
	return 0
}
