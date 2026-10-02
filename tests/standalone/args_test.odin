package standalone_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import standalone "../../hosts/standalone"

// The CLI contract, asserted against the documented modes rather than against
// the parser's own output: these cases are the usage text turned into
// expectations, so a change that quietly redefines a flag fails here.

@(test)
test_default_runs_the_tui :: proc(t: ^testing.T) {
	cli := standalone.parse_args([]string{"quesynth"})
	testing.expect_value(t, cli.mode, standalone.Mode.Run)
	testing.expect_value(t, cli.patch_path, "")
}

@(test)
test_default_takes_a_positional_patch :: proc(t: ^testing.T) {
	cli := standalone.parse_args([]string{"quesynth", "lead.sy1"})
	testing.expect_value(t, cli.mode, standalone.Mode.Run)
	testing.expect_value(t, cli.patch_path, "lead.sy1")
}

@(test)
test_daemon_flag_with_and_without_patch :: proc(t: ^testing.T) {
	bare := standalone.parse_args([]string{"quesynth", "--daemon"})
	testing.expect_value(t, bare.mode, standalone.Mode.Daemon)
	testing.expect_value(t, bare.patch_path, "")

	with_patch := standalone.parse_args([]string{"quesynth", "--daemon", "pad.sy1"})
	testing.expect_value(t, with_patch.mode, standalone.Mode.Daemon)
	testing.expect_value(t, with_patch.patch_path, "pad.sy1")
}

@(test)
test_browser_flag_with_and_without_patch :: proc(t: ^testing.T) {
	bare := standalone.parse_args([]string{"quesynth", "--browser"})
	testing.expect_value(t, bare.mode, standalone.Mode.Browser)
	with_patch := standalone.parse_args([]string{"quesynth", "--browser", "pad.sy1"})
	testing.expect_value(t, with_patch.mode, standalone.Mode.Browser)
	testing.expect_value(t, with_patch.patch_path, "pad.sy1")
}

@(test)
test_bank_flag_in_run_and_daemon :: proc(t: ^testing.T) {
	run := standalone.parse_args([]string{"quesynth", "--bank", "user.json"})
	testing.expect_value(t, run.mode, standalone.Mode.Run)
	testing.expect_value(t, run.bank_path, "user.json")
	testing.expect_value(t, run.patch_path, "")

	run_both := standalone.parse_args([]string{"quesynth", "--bank", "user.json", "lead.sy1"})
	testing.expect_value(t, run_both.mode, standalone.Mode.Run)
	testing.expect_value(t, run_both.bank_path, "user.json")
	testing.expect_value(t, run_both.patch_path, "lead.sy1")

	daemon := standalone.parse_args([]string{"quesynth", "--daemon", "--bank", "b.json", "pad.sy1"})
	testing.expect_value(t, daemon.mode, standalone.Mode.Daemon)
	testing.expect_value(t, daemon.bank_path, "b.json")
	testing.expect_value(t, daemon.patch_path, "pad.sy1")

	// A dangling --bank and a repeated --bank are both errors.
	missing := standalone.parse_args([]string{"quesynth", "--bank"})
	testing.expect_value(t, missing.mode, standalone.Mode.Usage_Error)
	twice := standalone.parse_args([]string{"quesynth", "--bank", "a.json", "--bank", "b.json"})
	testing.expect_value(t, twice.mode, standalone.Mode.Usage_Error)
}

@(test)
test_selftest_needs_two_operands :: proc(t: ^testing.T) {
	ok := standalone.parse_args([]string{"quesynth", "--selftest", "in.sy1", "out.wav"})
	testing.expect_value(t, ok.mode, standalone.Mode.Selftest)
	testing.expect_value(t, ok.patch_path, "in.sy1")
	testing.expect_value(t, ok.output_path, "out.wav")

	// One operand short is an error, not a defaulted output path: a green CI
	// run that wrote nowhere would be meaningless.
	short := standalone.parse_args([]string{"quesynth", "--selftest", "in.sy1"})
	testing.expect_value(t, short.mode, standalone.Mode.Usage_Error)

	extra := standalone.parse_args(
		[]string{"quesynth", "--selftest", "in.sy1", "out.wav", "extra"},
	)
	testing.expect_value(t, extra.mode, standalone.Mode.Usage_Error)
}

@(test)
test_help :: proc(t: ^testing.T) {
	for flag in ([]string{"--help", "-h"}) {
		cli := standalone.parse_args([]string{"quesynth", flag})
		testing.expect_value(t, cli.mode, standalone.Mode.Help)
	}
}

@(test)
test_unknown_option_is_an_error_not_a_patch :: proc(t: ^testing.T) {
	// A mistyped option must fail loudly rather than be taken for a patch path
	// that does not exist.
	cli := standalone.parse_args([]string{"quesynth", "--daemonn"})
	testing.expect_value(t, cli.mode, standalone.Mode.Usage_Error)
}

@(test)
test_extra_positional_is_an_error :: proc(t: ^testing.T) {
	cli := standalone.parse_args([]string{"quesynth", "a.sy1", "b.sy1"})
	testing.expect_value(t, cli.mode, standalone.Mode.Usage_Error)
}

@(test)
test_every_state_has_a_name :: proc(t: ^testing.T) {
	// A missing case would return "unknown"; each state must have a real label
	// so a control client never reports a blank status.
	states := []standalone.Daemon_State {
		.Starting,
		.Ready,
		.Running,
		.Stopping,
		.Error,
	}
	for state in states {
		testing.expect(t, standalone.daemon_state_name(state) != "unknown")
	}
}

@(test)
test_mcp_is_its_own_mode_and_takes_no_operands :: proc(t: ^testing.T) {
	cli := standalone.parse_args([]string{"quesynth", "--mcp"})
	testing.expect_value(t, cli.mode, standalone.Mode.MCP)
	testing.expect_value(t, cli.message, "")
	testing.expect_value(t, cli.patch_path, "")
	testing.expect_value(t, cli.bank_path, "")
	testing.expect_value(t, cli.output_path, "")

	// Anything after it is refused with the same words --stop uses, so the MCP
	// server never grows a socket option, a bank or a patch of its own.
	for extra in ([]string{"--bank", "patch.sy1", "--daemon", "--socket", "--timeout-ms", "--help", "--mcp", ""}) {
		cli := standalone.parse_args([]string{"quesynth", "--mcp", extra})
		testing.expect_value(t, cli.mode, standalone.Mode.Usage_Error)
		testing.expect_value(t, cli.message, fmt.tprintf("error: unexpected extra argument %q", extra))
	}
	several := standalone.parse_args([]string{"quesynth", "--mcp", "--bank", "b.json", "p.sy1"})
	testing.expect_value(t, several.mode, standalone.Mode.Usage_Error)
	testing.expect_value(t, several.message, `error: unexpected extra argument "--bank"`)
}

@(test)
test_mcp_is_only_a_mode_and_never_an_operand_of_another :: proc(t: ^testing.T) {
	for args in ([][]string {
			{"quesynth", "--daemon", "--mcp"},
			{"quesynth", "--browser", "--mcp"},
			{"quesynth", "--mcp", "--stop"},
			{"quesynth", "lead.sy1", "--mcp"},
			{"quesynth", "--bank", "b.json", "--mcp"},
			{"quesynth", "--stop", "--mcp"},
		}) {
		testing.expect_value(t, standalone.parse_args(args).mode, standalone.Mode.Usage_Error)
	}
}

@(test)
test_adding_mcp_left_every_other_mode_parsing_as_it_did :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, args: []string, mode: standalone.Mode, patch_path, bank_path, output_path: string, loc := #caller_location) {
		cli := standalone.parse_args(args)
		testing.expect_value(t, cli.mode, mode, loc = loc)
		testing.expect_value(t, cli.patch_path, patch_path, loc = loc)
		testing.expect_value(t, cli.bank_path, bank_path, loc = loc)
		testing.expect_value(t, cli.output_path, output_path, loc = loc)
		testing.expect_value(t, cli.message, "", loc = loc)
	}
	check(t, {"quesynth"}, .Run, "", "", "")
	check(t, {"quesynth", "lead.sy1"}, .Run, "lead.sy1", "", "")
	check(t, {"quesynth", "--bank", "b.json", "lead.sy1"}, .Run, "lead.sy1", "b.json", "")
	check(t, {"quesynth", "--daemon"}, .Daemon, "", "", "")
	check(t, {"quesynth", "--daemon", "pad.sy1"}, .Daemon, "pad.sy1", "", "")
	check(t, {"quesynth", "--daemon", "--bank", "b.json", "pad.sy1"}, .Daemon, "pad.sy1", "b.json", "")
	check(t, {"quesynth", "--daemon", "pad.sy1", "--bank", "b.json"}, .Daemon, "pad.sy1", "b.json", "")
	check(t, {"quesynth", "--browser"}, .Browser, "", "", "")
	check(t, {"quesynth", "--browser", "--bank", "b.json"}, .Browser, "", "b.json", "")
	check(t, {"quesynth", "--stop"}, .Stop, "", "", "")
	check(t, {"quesynth", "--selftest", "in.sy1", "out.wav"}, .Selftest, "in.sy1", "", "out.wav")
	check(t, {"quesynth", "--help"}, .Help, "", "", "")
	check(t, {"quesynth", "-h"}, .Help, "", "", "")

	extra_stop := standalone.parse_args([]string{"quesynth", "--stop", "now"})
	testing.expect_value(t, extra_stop.mode, standalone.Mode.Usage_Error)
	testing.expect_value(t, extra_stop.message, `error: unexpected extra argument "now"`)
	for option in ([]string{"--socket", "--timeout-ms", "--mcpx", "--MCP", "mcp"}) {
		cli := standalone.parse_args([]string{"quesynth", "--daemon", option})
		testing.expect(t, cli.mode != .MCP)
	}
	// "mcp" without dashes is a patch path, as any other bare word is.
	bare := standalone.parse_args([]string{"quesynth", "mcp"})
	testing.expect_value(t, bare.mode, standalone.Mode.Run)
	testing.expect_value(t, bare.patch_path, "mcp")
}

@(test)
test_usage_names_every_mode_with_its_description_in_one_column :: proc(t: ^testing.T) {
	lines := strings.split(standalone.USAGE, "\n", context.temp_allocator)
	testing.expect_value(t, lines[0], "usage:")
	testing.expect_value(t, len(lines), 7)
	column := -1
	has_mcp := false
	for line in lines[1:] {
		gap := strings.index(line[2:], "  ") + 2
		testing.expectf(t, gap >= 2, "no description column in %q", line)
		start := gap
		for start < len(line) && line[start] == ' ' { start += 1 }
		if column < 0 { column = start }
		testing.expectf(t, start == column, "description of %q starts at column %d, not %d", line, start, column)
		if strings.has_prefix(line, "  quesynth --mcp ") { has_mcp = true }
	}
	testing.expect(t, has_mcp)
}
