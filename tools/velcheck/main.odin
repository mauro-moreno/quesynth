package velcheck

// Does a velocity change actually change the level? Renders one patch at a
// spread of velocities and reports the peak of each, so "velocity does nothing"
// can be answered with numbers instead of listening.

import "core:fmt"
import "core:math"
import "core:os"

import "../../src/engine"
import "../../src/patch"

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 {
		fmt.eprintln("usage: velcheck <patch.sy1>")
		os.exit(1)
	}
	data, err := os.read_entire_file(args[0], context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %v: %v", args[0], err)
		os.exit(1)
	}
	parsed, parse_err := patch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("cannot parse: %v", parse_err)
		os.exit(1)
	}

	params := engine.bind_patch(parsed)
	fmt.printfln("%v  parameter 30 stored %v -> amp_velocity_sens %.4f",
		args[0], parsed.values[30], params.amp_velocity_sens)
	fmt.println()
	fmt.println("  midi vel   peak      dB above vel 1")

	left := make([]f32, 48000)
	right := make([]f32, 48000)
	defer delete(left)
	defer delete(right)

	reference := 0.0
	for midi in ([?]int{1, 16, 32, 64, 96, 127}) {
		eng: engine.Engine
		engine.engine_load_patch(&eng, parsed, 48000)
		engine.engine_note_on(&eng, 60, f32(midi) / 127.0)
		engine.engine_process(&eng, left, right)

		peak := 0.0
		for i in 0 ..< len(left) {
			peak = max(peak, abs(f64(left[i])), abs(f64(right[i])))
		}
		engine.engine_destroy(&eng)
		if midi == 1 {reference = peak}

		// Against the softest key, which is the range a player actually feels.
		db := reference > 0 && peak > 0 ? 20.0 * math.log10(peak / reference) : 0
		fmt.printfln("  %v %v %v",
			pad(fmt.tprintf("%v", midi), 8),
			pad(fmt.tprintf("%.5f", peak), 10),
			pad(fmt.tprintf("%.2f", db), 10))
	}
}

pad :: proc(s: string, w: int) -> string {
	if len(s) >= w {return s}
	spaces := "                    "
	return fmt.tprintf("%v%v", spaces[:w - len(s)], s)
}
