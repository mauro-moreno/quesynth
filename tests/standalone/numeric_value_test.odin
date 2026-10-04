package standalone_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "../../src/control"
import standalone "../../hosts/standalone"

// These spellings either wrapped into valid knob values or were accepted as
// another base, or with a leading plus, by parse_int. No member of a refused
// transaction may enqueue.
@(test)
test_parameter_values_are_decimal_and_do_not_wrap :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snapshot: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cc := standalone.Control_Context{ring = &ring, snapshot = &snapshot, state = &state}
	before := standalone.snapshot_read(&snapshot)
	for prefix in ([]string{
		"parameter.set filter.cutoff",
		"parameter.set_many filter.cutoff",
		"parameter.set_many expected_revision=0 filter.cutoff",
		"patch.apply filter.cutoff",
		"parameter.set_many filter.resonance 20 filter.cutoff",
		"parameter.set_many expected_revision=0 filter.resonance 20 filter.cutoff",
		"patch.apply filter.resonance 20 filter.cutoff",
	}) {
		for token in ([]string{
			"0x5", "0b101", "0o5", "0d5", "5_0", "_5", "5_",
			"1e2", "1.5", "-", "--5", "-+5", "+-5", "_", "+", "-0x5", "-5_",
			"+5", "+0", "+0005", "+00000000000000000000000", "+9223372036854775807",
			"18446744073709551621", "9223372036854775808",
			"-9223372036854775809", "99999999999999999999999",
		}) {
			line := fmt.tprintf("1 8 %s %s", prefix, token)
			req, ok := control.request_parse(transmute([]u8)line)
			assert(ok)
			out := strings.builder_make(context.temp_allocator)
			standalone.control_handle(&cc, req, &out)
			testing.expectf(t, strings.to_string(out) == "1 8 err invalid_payload value is not an integer", "%s -> %s", line, strings.to_string(out))
			queued := false
			for { _, any := standalone.param_ring_pop(&ring); if !any { break }; queued = true }
			testing.expectf(t, !queued, "%s enqueued commands", line)
			testing.expect_value(t, standalone.snapshot_read(&snapshot), before)
		}
	}
}


// The full signed 64-bit range is still an integer, so one that is no valid knob
// value is the parameter's out_of_range rather than a malformed number. Leading
// zeroes and a lone minus sign before the digits change nothing about that.
@(test)
test_the_whole_int_range_is_read_as_an_integer_and_judged_by_the_parameter :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snapshot: standalone.Snapshot
	state := standalone.Daemon_State.Running
	cc := standalone.Control_Context{ring = &ring, snapshot = &snapshot, state = &state}
	for prefix in ([]string{
		"parameter.set filter.cutoff",
		"parameter.set_many filter.cutoff",
		"parameter.set_many expected_revision=0 filter.cutoff",
		"patch.apply filter.cutoff",
	}) {
		for token in ([]string{
			"9223372036854775807", "-9223372036854775808", "-0009223372036854775808", "0009223372036854775807",
			"-9223372036854775807", "4294967296", "-4294967297",
		}) {
			line := fmt.tprintf("1 8 %s %s", prefix, token)
			req, ok := control.request_parse(transmute([]u8)line)
			assert(ok)
			out := strings.builder_make(context.temp_allocator)
			standalone.control_handle(&cc, req, &out)
			testing.expectf(t, strings.to_string(out) == "1 8 err out_of_range value out of range", "%s -> %s", line, strings.to_string(out))
			_, queued := standalone.param_ring_pop(&ring)
			testing.expectf(t, !queued, "%s enqueued commands", line)
		}
	}
}
