package standalone_tests

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
