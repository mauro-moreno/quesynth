package control

import "core:strconv"
import "core:strings"

// The message layer: how a framed payload reads as a request or a response.
// This is separate from the framing (codec.odin) and from the transport, so the
// command set does not depend on either.
//
// The V1 encoding is a compact line format, chosen because control traffic is
// tiny and being able to read it in a socket dump is worth more than a byte or
// two. A request is one line:
//
//     <version> <id> <command> [operand ...]
//
// A response is an envelope line, optionally followed by record lines:
//
//     <version> <id> ok [key=value ...]
//     <version> <id> err <code> [message ...]
//
// The command semantics never depend on this being text; a later slice could
// swap the encoding without touching the command set.

Status :: enum {
	Ok,
	Err,
}

Error_Code :: enum {
	None,
	Unsupported_Version,
	Unknown_Command,
	Invalid_Payload,
	Unknown_Parameter,
	Out_Of_Range,
	Daemon_Not_Ready,
	Internal_Error,
}

// The machine-readable token for each error. A client keys off this rather than
// the human message, which exists only to be read (Error_Code, plan §34).
error_code_name :: proc(code: Error_Code) -> string {
	switch code {
	case .None:
		return "none"
	case .Unsupported_Version:
		return "unsupported_version"
	case .Unknown_Command:
		return "unknown_command"
	case .Invalid_Payload:
		return "invalid_payload"
	case .Unknown_Parameter:
		return "unknown_parameter"
	case .Out_Of_Range:
		return "out_of_range"
	case .Daemon_Not_Ready:
		return "daemon_not_ready"
	case .Internal_Error:
		return "internal_error"
	}
	return "internal_error"
}

error_code_from_name :: proc(name: string) -> Error_Code {
	switch name {
	case "none":
		return .None
	case "unsupported_version":
		return .Unsupported_Version
	case "unknown_command":
		return .Unknown_Command
	case "invalid_payload":
		return .Invalid_Payload
	case "unknown_parameter":
		return .Unknown_Parameter
	case "out_of_range":
		return .Out_Of_Range
	case "daemon_not_ready":
		return .Daemon_Not_Ready
	case "internal_error":
		return .Internal_Error
	}
	return .Internal_Error
}

MAX_OPERANDS :: 4

// A parsed request. The strings point into the payload it was parsed from, so
// that payload must outlive the Request.
Request :: struct {
	version:       int,
	id:            int,
	command:       string,
	operands:      [MAX_OPERANDS]string,
	operand_count: int,
}

// Parse a request payload's envelope line. Requests are single-line in V1; any
// trailing lines are ignored.
request_parse :: proc(payload: []u8) -> (req: Request, ok: bool) {
	line := string(payload)
	if idx := strings.index_byte(line, '\n'); idx >= 0 {
		line = line[:idx]
	}

	rest := line
	version_tok: string
	version_tok, rest = next_token(rest)
	version, vok := strconv.parse_int(version_tok)
	if !vok {
		return {}, false
	}
	id_tok: string
	id_tok, rest = next_token(rest)
	id, iok := strconv.parse_int(id_tok)
	if !iok {
		return {}, false
	}
	command: string
	command, rest = next_token(rest)
	if len(command) == 0 {
		return {}, false
	}

	req.version = version
	req.id = id
	req.command = command
	for req.operand_count < MAX_OPERANDS {
		operand: string
		operand, rest = next_token(rest)
		if len(operand) == 0 {
			break
		}
		req.operands[req.operand_count] = operand
		req.operand_count += 1
	}
	return req, true
}

// A parsed response. `fields` is the remainder of the envelope line (the
// key=value results on ok, or the human message on err); `body` is any record
// lines after it. Both point into the payload.
Response :: struct {
	version: int,
	id:      int,
	status:  Status,
	error:   Error_Code,
	fields:  string,
	body:    string,
}

response_parse :: proc(payload: []u8) -> (resp: Response, ok: bool) {
	text := string(payload)
	envelope := text
	if idx := strings.index_byte(text, '\n'); idx >= 0 {
		envelope = text[:idx]
		resp.body = text[idx + 1:]
	}

	rest := envelope
	version_tok: string
	version_tok, rest = next_token(rest)
	version, vok := strconv.parse_int(version_tok)
	if !vok {
		return {}, false
	}
	id_tok: string
	id_tok, rest = next_token(rest)
	id, iok := strconv.parse_int(id_tok)
	if !iok {
		return {}, false
	}
	status_tok: string
	status_tok, rest = next_token(rest)

	resp.version = version
	resp.id = id
	switch status_tok {
	case "ok":
		resp.status = .Ok
		resp.fields = strings.trim_space(rest)
	case "err":
		resp.status = .Err
		code_tok: string
		code_tok, rest = next_token(rest)
		resp.error = error_code_from_name(code_tok)
		resp.fields = strings.trim_space(rest)
	case:
		return {}, false
	}
	return resp, true
}

// Look up a key=value token in a space-separated field string.
response_field :: proc(fields: string, key: string) -> (value: string, ok: bool) {
	rest := fields
	for len(rest) > 0 {
		token: string
		token, rest = next_token(rest)
		if len(token) == 0 {
			break
		}
		if eq := strings.index_byte(token, '='); eq >= 0 && token[:eq] == key {
			return token[eq + 1:], true
		}
	}
	return "", false
}

// The next space-delimited token and the remainder after it. Leading spaces are
// skipped; the token is empty only when the rest holds nothing but spaces.
@(private)
next_token :: proc(s: string) -> (token: string, rest: string) {
	i := 0
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' {
		i += 1
	}
	return s[start:i], s[i:]
}
