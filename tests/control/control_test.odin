package control_tests

import "core:testing"

import control "../../src/control"

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

@(test)
test_frame_round_trip :: proc(t: ^testing.T) {
	frame := control.frame_encode(bytes("hello"))
	defer delete(frame)

	r: control.Frame_Reader
	defer control.frame_reader_destroy(&r)
	control.frame_reader_push(&r, frame)

	payload, ok, err := control.frame_reader_next(&r)
	defer delete(payload)
	testing.expect(t, ok)
	testing.expect(t, !err)
	testing.expect_value(t, string(payload), "hello")
}

@(test)
test_frame_does_not_assume_one_read_is_one_message :: proc(t: ^testing.T) {
	frame := control.frame_encode(bytes("filter.cutoff"))
	defer delete(frame)

	r: control.Frame_Reader
	defer control.frame_reader_destroy(&r)

	// Feed the frame one byte at a time; a message emerges only once its last
	// byte arrives, never before and never split.
	for i in 0 ..< len(frame) {
		control.frame_reader_push(&r, frame[i:i + 1])
		payload, ok, err := control.frame_reader_next(&r)
		testing.expect(t, !err)
		if i < len(frame) - 1 {
			testing.expect(t, !ok)
		} else {
			testing.expect(t, ok)
			testing.expect_value(t, string(payload), "filter.cutoff")
			delete(payload)
		}
	}
}

@(test)
test_frame_multiple_messages_in_one_push :: proc(t: ^testing.T) {
	a := control.frame_encode(bytes("one"))
	defer delete(a)
	b := control.frame_encode(bytes("two"))
	defer delete(b)

	joined := make([]u8, len(a) + len(b))
	defer delete(joined)
	copy(joined, a)
	copy(joined[len(a):], b)

	r: control.Frame_Reader
	defer control.frame_reader_destroy(&r)
	control.frame_reader_push(&r, joined)

	p1, ok1, _ := control.frame_reader_next(&r)
	defer delete(p1)
	p2, ok2, _ := control.frame_reader_next(&r)
	defer delete(p2)
	_, ok3, _ := control.frame_reader_next(&r)

	testing.expect(t, ok1)
	testing.expect(t, ok2)
	testing.expect(t, !ok3)
	testing.expect_value(t, string(p1), "one")
	testing.expect_value(t, string(p2), "two")
}

@(test)
test_frame_oversized_length_is_rejected :: proc(t: ^testing.T) {
	// A header claiming a payload past the cap must be flagged, not allocated.
	header := []u8{0xFF, 0xFF, 0xFF, 0xFF}
	r: control.Frame_Reader
	defer control.frame_reader_destroy(&r)
	control.frame_reader_push(&r, header)

	_, ok, err := control.frame_reader_next(&r)
	testing.expect(t, !ok)
	testing.expect(t, err)
}

@(test)
test_request_parse :: proc(t: ^testing.T) {
	req, ok := control.request_parse(bytes("1 42 parameter.set filter.cutoff 3200"))
	testing.expect(t, ok)
	testing.expect_value(t, req.version, 1)
	testing.expect_value(t, req.id, 42)
	testing.expect_value(t, req.command, "parameter.set")
	testing.expect_value(t, req.operand_count, 2)
	testing.expect_value(t, req.operands[0], "filter.cutoff")
	testing.expect_value(t, req.operands[1], "3200")
}

@(test)
test_request_parse_rejects_a_line_with_no_command :: proc(t: ^testing.T) {
	_, ok := control.request_parse(bytes("1 42"))
	testing.expect(t, !ok)
}

@(test)
test_response_parse_ok_fields :: proc(t: ^testing.T) {
	resp, ok := control.response_parse(bytes("1 42 ok value=3200 revision=7"))
	testing.expect(t, ok)
	testing.expect_value(t, resp.status, control.Status.Ok)
	value, has_value := control.response_field(resp.fields, "value")
	testing.expect(t, has_value)
	testing.expect_value(t, value, "3200")
	revision, has_rev := control.response_field(resp.fields, "revision")
	testing.expect(t, has_rev)
	testing.expect_value(t, revision, "7")
}

@(test)
test_response_parse_err_code :: proc(t: ^testing.T) {
	resp, ok := control.response_parse(bytes("1 5 err out_of_range value too large"))
	testing.expect(t, ok)
	testing.expect_value(t, resp.status, control.Status.Err)
	testing.expect_value(t, resp.error, control.Error_Code.Out_Of_Range)
	testing.expect_value(t, resp.fields, "value too large")
}

@(test)
test_error_code_names_round_trip :: proc(t: ^testing.T) {
	codes := []control.Error_Code {
		.None,
		.Unsupported_Version,
		.Unknown_Command,
		.Invalid_Payload,
		.Unknown_Parameter,
		.Out_Of_Range,
		.Daemon_Not_Ready,
		.Internal_Error,
	}
	for code in codes {
		back := control.error_code_from_name(control.error_code_name(code))
		testing.expect_value(t, back, code)
	}
}
