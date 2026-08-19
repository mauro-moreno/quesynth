// s1probe progparam - read a parameter back after selecting a program through
// the plugin's *own* program list.
//
// Every other probe in this project pushes a patch into the reference by
// writing raw integers into a state chunk and calling SetChunk. That is the
// right instrument for comparing a specific set of values against this
// engine's rendering of the same values -- but it bypasses Synth1's own `.sy1`
// file parser completely, so it cannot answer questions *about* that parser.
//
// One such question: 124 of the 128 factory patches store parameter 55 (chorus
// feedback) as 0, and 0 is the bottom of a bipolar knob whose centre is 64.
// Through SetChunk the plugin reports that as "-99 %". If Synth1's own loader
// instead treats a stored 0 as absent and substitutes the default 64, the
// same patch would be "0 %" in the plugin's own GUI, this engine would be
// applying full negative feedback where the reference applies none, and it
// would be wrong on almost the whole bank.
//
// SetProgram makes Synth1 load one of its own programs, from its own
// soundbank, through its own code. Nothing here writes a parameter or a chunk.
//
// **It does not answer that question, and the reason is worth recording.**
// Synth1 reports exactly one program and does not read its `soundbank00`
// files on load at all: it restores a *persisted global state* -- what
// `initsettings.exe` and `reg2ini.exe` in its own directory exist to manage.
// Run against a DLL whose own `soundbank00/001.sy1` carries one set of values,
// this reported a different set entirely, matching a patch the machine's user
// had edited in the GUI earlier, on 9 of the 10 parameters where the two
// differ. What comes back is the last GUI session, not a freshly parsed file,
// so it says nothing about the file parser and everything about what someone
// last left the knobs on.
//
// That is a trap for any probe in this project that does not set every
// parameter explicitly. `load_reference_patch` writes all `PARAMETER_COUNT`
// values into the chunk before every render, so `compare` and everything built
// on it are immune; this command, which deliberately writes nothing, is the
// one thing that is not.
//
//   s1probe progparam [dll] [--program <n>] [--indices <list>] [--count <n>]
package s1probe

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import cpatch "../../src/patch"

cmd_progparam :: proc(dll: string, program: int, indices: []int, count: int) {
	p, ok := load(dll)
	if !ok {
		os.exit(1)
	}
	defer unload(&p)
	e := p.eff

	fmt.printfln("progparam: %v", dll)
	fmt.printfln("  the plugin reports %v programs", e.num_programs)
	fmt.println("  nothing below writes a parameter or a chunk; SetProgram only")
	fmt.println()

	first := program
	last := program + max(count, 1) - 1

	for prog in first ..= last {
		if prog < 0 || (e.num_programs > 0 && prog >= int(e.num_programs)) {
			continue
		}
		e.dispatcher(e, i32(Op.SetProgram), 0, prog, nil, 0)
		got := e.dispatcher(e, i32(Op.GetProgram), 0, 0, nil, 0)
		name := dispatch_str(&p, .GetProgramName, 0)

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		for i in indices {
			display := dispatch_str(&p, .GetParamDisplay, i32(i))
			norm := e.get_parameter(e, i32(i))
			// What stored integer that normalised value corresponds to, read
			// back through the same state table the patch format uses.
			stored := stored_from_norm(i, f64(norm))
			fmt.sbprintf(&b, "  %v=%v (norm %.6f, stored %v)", i, display, norm, stored)
		}
		fmt.printfln("program %3v (got %v) %-24v%v", prog, got, name, strings.to_string(b))
		free_all(context.temp_allocator)
	}
}

// The stored integer whose normalised value is closest to `norm`.
//
// `parameter_norm` is the forward direction the loader already uses; this
// searches it rather than inverting it, because a display-keyed parameter's
// mapping is a table and not a formula.
stored_from_norm :: proc(index: int, norm: f64) -> int {
	states := cpatch.parameter_states(index)
	best := -1
	best_error := 1.0e30
	for v in 0 ..< max(len(states), 1) {
		expected, resolved := cpatch.parameter_norm(index, v)
		if !resolved {
			continue
		}
		d := abs(f64(expected) - norm)
		if d < best_error {
			best_error = d
			best = v
		}
	}
	return best
}

parse_index_list :: proc(spec: string) -> []int {
	out := make([dynamic]int)
	parts := strings.split(spec, ",")
	defer delete(parts)
	for part in parts {
		trimmed := strings.trim_space(part)
		if len(trimmed) == 0 {
			continue
		}
		if v, ok := strconv.parse_int(trimmed); ok {
			append(&out, v)
		}
	}
	return out[:]
}
