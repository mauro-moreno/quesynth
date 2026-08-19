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
// Two modes, because they have opposite requirements:
//
//   --selftest   Renders to a file. Must run on a machine with no audio
//                hardware, no MIDI hardware and nobody present, so it opens no
//                device at all. This is the mode CI runs.
//
//   live         Opens the real output and every MIDI input, and plays. Cannot
//                be checked automatically, so the path is kept small enough to
//                review by reading: live.odin is the whole of the behaviour.
//
// The split is enforced by construction, not by a flag test scattered around:
// run_selftest in selftest.odin never refers to anything in backend.odin, so
// there is no branch anywhere in it that could reach WASAPI.

USAGE :: `usage:
  quesynth --selftest <patch.sy1> <out.wav>   render offline, open no device
  quesynth [patch.sy1]                        play live through WASAPI`

main :: proc() {
	args := os.args

	if len(args) > 1 && args[1] == "--selftest" {
		// Exactly two operands. Being strict here matters: a missing output
		// path that silently defaulted somewhere would make a green CI run
		// meaningless.
		if len(args) != 4 {
			fmt.eprintfln("error: --selftest needs <patch.sy1> <out.wav>")
			fmt.eprintln(USAGE)
			os.exit(2)
		}
		os.exit(run_selftest(args[2], args[3]))
	}

	// Live mode is the default. The patch is optional; without one the
	// synthesiser comes up on the plugin's own default parameters.
	patch_path := ""
	if len(args) > 2 {
		fmt.eprintfln("error: unexpected extra argument %q", args[2])
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if len(args) == 2 {
		if args[1] == "--help" || args[1] == "-h" {
			fmt.println(USAGE)
			os.exit(0)
		}
		patch_path = args[1]
	}

	os.exit(run_live(patch_path))
}
