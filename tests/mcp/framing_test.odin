package mcp_tests

import "core:encoding/json"
import "core:io"
import "core:strings"
import "core:testing"
import "core:time"

import "../../hosts/standalone/mcp"

// The stdio loop: how bytes become requests and replies become lines. The
// input arrives in chunks of the size the test picks, so a request is cut
// wherever the pipe happens to cut it, and the output is whatever the loop
// writes, so "nothing but replies" is checked on the bytes themselves.

@(private = "file")
Chunked :: struct {
	data:  string,
	pos:   int,
	chunk: int,
}

@(private = "file")
chunked_stream :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	c := (^Chunked)(stream_data)
	#partial switch mode {
	case .Read:
		if c.pos >= len(c.data) { return 0, .EOF }
		n = i64(copy(p[:min(len(p), c.chunk)], c.data[c.pos:]))
		c.pos += int(n)
		return n, nil
	case .Query:
		return io.query_utility({.Read})
	}
	return 0, .Empty
}

// Everything written for `input`, read `chunk` bytes at a time. The returned
// string is on the default heap and is the caller's to delete.
@(private = "file")
transcript :: proc(input: string, chunk: int) -> (output: string, status: int) {
	source := Chunked{data = input, chunk = chunk}
	sink := strings.builder_make()
	status = mcp.serve(io.Stream{procedure = chunked_stream, data = &source}, strings.to_writer(&sink), ABSENT)
	return strings.to_string(sink), status
}

PINGS :: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n"
PING_REPLIES :: "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}}\n{\"id\":2,\"jsonrpc\":\"2.0\",\"result\":{}}\n"

@(test)
test_each_line_is_one_request_and_each_reply_is_one_line_in_order :: proc(t: ^testing.T) {
	for chunk in ([]int{1, 2, 3, 7, 64, 4096}) {
		output, status := transcript(PINGS, chunk)
		defer delete(output)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, output, PING_REPLIES)
	}
}

@(test)
test_a_last_line_with_no_newline_is_answered_at_end_of_input :: proc(t: ^testing.T) {
	for chunk in ([]int{1, 5, 4096}) {
		output, status := transcript("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}", chunk)
		defer delete(output)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, output, PING_REPLIES)
	}
}

@(test)
test_carriage_returns_before_the_newline_are_only_whitespace :: proc(t: ^testing.T) {
	output, _ := transcript("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\r\n", 3)
	defer delete(output)
	testing.expect_value(t, output, PING_REPLIES)
}

@(test)
test_line_and_paragraph_separators_stay_inside_the_request :: proc(t: ^testing.T) {
	// A reader that split on every Unicode line break would cut this in two and
	// answer both halves with a parse error.
	request := "{\"jsonrpc\":\"2.0\",\"id\":\"a\u2028b\u2029c\u0085d\",\"method\":\"ping\"}\n"
	for chunk in ([]int{1, 2, 4096}) {
		output, _ := transcript(request, chunk)
		defer delete(output)
		testing.expect_value(t, output, "{\"id\":\"a\\u2028b\\u2029c\\u0085d\",\"jsonrpc\":\"2.0\",\"result\":{}}\n")
	}
}

@(test)
test_a_blank_line_is_a_parse_error_and_the_next_line_is_still_answered :: proc(t: ^testing.T) {
	output, _ := transcript("\n\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n", 4096)
	defer delete(output)
	error := "{\"error\":{\"code\":-32700,\"message\":\"Invalid JSON\"},\"id\":null,\"jsonrpc\":\"2.0\"}\n"
	testing.expect_value(t, output, strings.concatenate({error, error, "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}}\n"}, context.temp_allocator))
}

@(test)
test_notifications_and_an_empty_input_write_nothing :: proc(t: ^testing.T) {
	output, status := transcript("", 4096)
	testing.expect_value(t, output, "")
	testing.expect_value(t, status, 0)
	delete(output)
	output, _ = transcript("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"nonsense\"}\n", 4096)
	testing.expect_value(t, output, "")
	delete(output)
}

@(test)
test_every_output_line_is_one_json_value_and_nothing_else_is_written :: proc(t: ^testing.T) {
	input := strings.concatenate(
		{
			"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}\n",
			"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n",
			"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n",
			"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_synth\"}}\n",
			"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/list\"}\n",
			"garbage\n",
			"[]\n",
			"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"quesynth://patch\"}}\n",
		},
	)
	defer delete(input)
	output, _ := transcript(input, 13)
	defer delete(output)
	testing.expect(t, strings.has_suffix(output, "\n"))
	lines := strings.split(strings.trim_suffix(output, "\n"), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 7)
	for line in lines {
		_, err := json.parse(transmute([]u8)line, spec = .JSON, allocator = context.temp_allocator)
		testing.expectf(t, err == .None, "not one JSON value: %q", line)
	}
}

@(test)
test_a_request_longer_than_any_read_is_reassembled_in_linear_time :: proc(t: ^testing.T) {
	filler := strings.repeat("x", 4 * 1024 * 1024)
	defer delete(filler)
	input := strings.concatenate({"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"note\":\"", filler, "\"}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n"})
	defer delete(input)
	started := time.tick_now()
	output, _ := transcript(input, 4096)
	defer delete(output)
	testing.expect_value(t, output, PING_REPLIES)
	testing.expect(t, time.tick_since(started) < 5 * time.Second, "framing took too long")
}
