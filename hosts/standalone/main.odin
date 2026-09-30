package standalone

import "core:fmt"
import "core:os"

// The standalone synthesiser: layer 2 in docs/architecture.md terms.
//
// It makes no sound of its own. src/dsp generates the audio, src/engine
// allocates the voices and binds the patch, src/patch reads the .sy1 file, and
// this program is the shell that connects them to an operating system -- the
// same job hosts/clap does for a plugin host.
//
// The binary is a small set of modes, and the split between them is enforced by
// construction, not by a flag test scattered around:
//
//   default      Run the synthesiser. In this slice that is the daemon in the
//                foreground; a later slice makes the default attach a front-end
//                (the TUI) to a daemon it spawns or finds already running.
//
//   --daemon     Run the headless audio daemon: open the real output and every
//                MIDI input and play, with no interactive surface. This is the
//                mode a Raspberry Pi or a systemd unit would run. See
//                daemon.odin, which is the whole of the behaviour.
//
//   --selftest   Render to a file. Must run on a machine with no audio
//                hardware, no MIDI hardware and nobody present, so it opens no
//                device at all. This is the mode CI runs. run_selftest in
//                selftest.odin never refers to anything in backend.odin, so
//                there is no branch anywhere in it that could reach a device.
//
// parse_args is kept pure and separate from main so the mode dispatch can be
// unit-tested without opening a device.

USAGE :: `usage:
  quesynth [--bank <bank.json>] [patch.sy1]              run the synthesiser
  quesynth --daemon [--bank <bank.json>] [patch.sy1]     run the headless daemon
  quesynth --browser [--bank <bank.json>] [patch.sy1]    open the shared browser UI
  quesynth --stop                                        stop a running daemon
  quesynth --selftest <patch.sy1> <out.wav>              render offline, open no device`

Mode :: enum {
	Run,
	Daemon,
	Browser,
	Stop,
	Selftest,
	Help,
	Usage_Error,
}

Cli :: struct {
	mode:        Mode,
	patch_path:  string,
	bank_path:   string,
	output_path: string,
	// Set only for Usage_Error: the line printed before the usage text.
	message:     string,
}

// Parse the whole of `os.args` (program name included) into a mode and its
// operands. Pure: it opens nothing and exits nothing, so a test can assert the
// CLI contract directly.
parse_args :: proc(args: []string) -> Cli {
	operands := len(args) > 0 ? args[1:] : args

	if len(operands) == 0 {
		return Cli{mode = .Run}
	}

	switch operands[0] {
	case "--help", "-h":
		return Cli{mode = .Help}

	case "--stop":
		if len(operands) > 1 {
			return Cli {
				mode = .Usage_Error,
				message = fmt.tprintf("error: unexpected extra argument %q", operands[1]),
			}
		}
		return Cli{mode = .Stop}

	case "--selftest":
		// Exactly two operands. Being strict here matters: a missing output
		// path that silently defaulted somewhere would make a green CI run
		// meaningless.
		if len(operands) != 3 {
			return Cli {
				mode = .Usage_Error,
				message = "error: --selftest needs <patch.sy1> <out.wav>",
			}
		}
		return Cli{mode = .Selftest, patch_path = operands[1], output_path = operands[2]}
	case "--daemon", "--browser":
		pp, bp, ok, msg := parse_run_operands(operands[1:])
		if !ok {
			return Cli{mode = .Usage_Error, message = msg}
		}
		return Cli{mode = operands[0] == "--browser" ? .Browser : .Daemon, patch_path = pp, bank_path = bp}
	}

	// The default mode with an optional --bank and a positional patch.
	pp, bp, ok, msg := parse_run_operands(operands)
	if !ok {
		return Cli{mode = .Usage_Error, message = msg}
	}
	return Cli{mode = .Run, patch_path = pp, bank_path = bp}
}

// Parse the operands common to Run and Daemon mode: an optional `--bank <path>`
// and an optional positional patch, in any order. An unknown flag, a repeated
// --bank or a second positional is an error rather than a silently-taken path.
@(private)
parse_run_operands :: proc(ops: []string) -> (patch_path, bank_path: string, ok: bool, message: string) {
	i := 0
	for i < len(ops) {
		a := ops[i]
		if a == "--bank" {
			if i + 1 >= len(ops) {
				return "", "", false, "error: --bank needs a path"
			}
			if bank_path != "" {
				return "", "", false, "error: --bank given more than once"
			}
			bank_path = ops[i + 1]
			i += 2
			continue
		}
		if len(a) > 0 && a[0] == '-' {
			return "", "", false, fmt.tprintf("error: unknown option %q", a)
		}
		if patch_path != "" {
			return "", "", false, fmt.tprintf("error: unexpected extra argument %q", a)
		}
		patch_path = a
		i += 1
	}
	return patch_path, bank_path, true, ""
}

main :: proc() {
	cli := parse_args(os.args)
	switch cli.mode {
	case .Selftest:
		os.exit(run_selftest(cli.patch_path, cli.output_path))
	case .Daemon:
		os.exit(run_daemon(cli.patch_path, cli.bank_path))
	case .Browser:
		os.exit(run_browser(cli.patch_path, cli.bank_path))
	case .Run:
		os.exit(run_tui(cli.patch_path, cli.bank_path))
	case .Stop:
		os.exit(run_stop())
	case .Help:
		fmt.println(USAGE)
		os.exit(0)
	case .Usage_Error:
		fmt.eprintln(cli.message)
		fmt.eprintln(USAGE)
		os.exit(2)
	}
}
