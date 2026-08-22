// paramprobe - drive one parameter at a time across everything a file can store.
//
//   odin run tools/paramprobe                                  # 0..127, every parameter
//   odin run tools/paramprobe -- -wild                         # and the integers no state holds
//   odin run tools/paramprobe -- -param=94 -wild -trace
//   odin run tools/paramprobe -- -base=patches/incoming/soundbank00/002.sy1
//
// A patch file is a list of `index,value` pairs and `parse_sy1` puts no ceiling
// on the value: a hand-edited or foreign file can legally store 300, or -1, in
// any of the ninety-nine parameters. Everything downstream then treats that
// integer as a position in a measured table or a size to allocate. This walks
// the whole domain deliberately, one parameter at a time, so a table indexed
// without a clamp is found by sweeping rather than by waiting for the patch that
// happens to hit it.
//
// One parameter at a time on purpose: with the other ninety-eight left at their
// defaults, a failure names the parameter that caused it. That is the difference
// between this and patchprobe, which reports whole files.
//
// -wild adds the out-of-range integers. They are not hypothetical -- parameter
// 21's own reference default is one step past its measured table -- and they are
// exactly where an unclamped index lives.
//
// A hard crash takes the process with it, so -trace writes each case to stderr
// before running it and the last line names the pair that died.
package paramprobe

import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

SAMPLE_RATE :: f32(48000)
BLOCK :: 256
DEFAULT_HOLD :: 2048
DEFAULT_TAIL :: 1024
RUNAWAY_LEVEL :: f32(64)

// Integers outside every parameter's measured table. A .sy1 file can hold any of
// these, so the engine has to survive all of them.
WILD_VALUES := [?]int{-1000000, -100000, -1024, -256, -129, -128, -2, -1, 128, 129, 255, 256, 1024, 100000, 1000000}

Verdict :: enum {
	Ok,
	Silent,
	Non_Finite,
	Runaway,
}

Case :: struct {
	param:     int,
	value:     int,
	verdict:   Verdict,
	polyphony: int,
	peak:      f32,
	nonfinite: int,
}

usage :: proc() {
	fmt.eprintln("usage: paramprobe [options]")
	fmt.eprintln("  -base=<patch>  sweep on top of this patch instead of the defaults")
	fmt.eprintln("  -param=N       only parameter N (repeatable)")
	fmt.eprintln("  -lo=N -hi=N    stored range to sweep (default 0..127)")
	fmt.eprintln("  -wild          also sweep the integers no state holds")
	fmt.eprintln("  -only-wild     sweep only those")
	fmt.eprintln("  -note=N        MIDI note to play (default 60)")
	fmt.eprintln("  -hold=N -tail=N  frames (default 2048, 1024)")
	fmt.eprintln("  -trace         write every case to stderr before running it")
	os.exit(2)
}

main :: proc() {
	base_path := ""
	params: [dynamic]int
	defer delete(params)
	lo, hi := 0, 127
	wild, only_wild, trace := false, false, false
	note := 60
	hold, tail := DEFAULT_HOLD, DEFAULT_TAIL

	for arg in os.args[1:] {
		switch {
		case arg == "-wild":
			wild = true
		case arg == "-only-wild":
			wild, only_wild = true, true
		case arg == "-trace":
			trace = true
		case strings.has_prefix(arg, "-base="):
			base_path = arg[len("-base="):]
		case strings.has_prefix(arg, "-param="):
			append(&params, int_arg(arg, "-param="))
		case strings.has_prefix(arg, "-lo="):
			lo = int_arg(arg, "-lo=")
		case strings.has_prefix(arg, "-hi="):
			hi = int_arg(arg, "-hi=")
		case strings.has_prefix(arg, "-note="):
			note = int_arg(arg, "-note=")
		case strings.has_prefix(arg, "-hold="):
			hold = int_arg(arg, "-hold=")
		case strings.has_prefix(arg, "-tail="):
			tail = int_arg(arg, "-tail=")
		case:
			fmt.eprintfln("paramprobe: unknown option %q", arg)
			usage()
		}
	}

	base := patch.init_patch()
	if base_path != "" {
		data, read_err := os.read_entire_file(base_path, context.allocator)
		if read_err != nil {
			fmt.eprintfln("paramprobe: cannot read %q: %v", base_path, read_err)
			os.exit(1)
		}
		parsed, err := patch.parse_sy1(data)
		if err != .None {
			fmt.eprintfln("paramprobe: cannot parse %q: %v", base_path, err)
			os.exit(1)
		}
		base = parsed
	}

	// The sweep is a value list per parameter, built once.
	values: [dynamic]int
	defer delete(values)
	if !only_wild {
		for v := lo; v <= hi; v += 1 {
			append(&values, v)
		}
	}
	if wild {
		for v in WILD_VALUES {
			append(&values, v)
		}
	}
	if len(values) == 0 {usage()}

	if len(params) == 0 {
		for i in 0 ..< patch.PARAMETER_COUNT {
			append(&params, i)
		}
	}

	failures: [dynamic]Case
	defer delete(failures)
	probed := 0

	for index in params {
		if index < 0 || index >= patch.PARAMETER_COUNT {
			fmt.eprintfln("paramprobe: %d is not a parameter", index)
			os.exit(2)
		}
		worst := Verdict.Ok
		for value in values {
			if trace {
				fmt.eprintfln("param=%d %s value=%d", index, patch.PARAMETERS[index].name, value)
			}
			c := probe_case(base, index, value, note, hold, tail)
			probed += 1
			if c.verdict != .Ok {
				append(&failures, c)
				if c.verdict > worst {worst = c.verdict}
			}
		}
		fmt.printfln("%d\t%s\t%v", index, patch.PARAMETERS[index].name, worst)
	}

	fmt.println("--")
	for c in failures {
		fmt.printfln(
			"%d\t%s\tvalue=%d\t%v\tpoly=%d\tpeak=%.4f\tnonfinite=%d",
			c.param,
			patch.PARAMETERS[c.param].name,
			c.value,
			c.verdict,
			c.polyphony,
			c.peak,
			c.nonfinite,
		)
	}
	fmt.printfln("cases:    %d", probed)
	fmt.printfln("failures: %d", len(failures))
	if len(failures) != 0 {
		os.exit(1)
	}
}

int_arg :: proc(arg: string, prefix: string) -> int {
	text := arg[len(prefix):]
	value := 0
	negative := false
	for c, i in text {
		if i == 0 && c == '-' {
			negative = true
			continue
		}
		if c < '0' || c > '9' {
			fmt.eprintfln("paramprobe: %q is not a number", arg)
			os.exit(2)
		}
		value = value * 10 + int(c - '0')
	}
	return -value if negative else value
}

probe_case :: proc(base: patch.Patch, index, value, note, hold, tail: int) -> Case {
	p := base
	p.values[index] = value
	p.present[index] = true

	c := Case{param = index, value = value}
	c.polyphony = engine.bind_patch(p).polyphony

	eng: engine.Engine
	engine.engine_load_patch(&eng, p, SAMPLE_RATE)
	defer engine.engine_destroy(&eng)

	left: [BLOCK]f32
	right: [BLOCK]f32

	scan :: proc(l, r: []f32, c: ^Case) {
		for i in 0 ..< len(l) {
			for v in ([2]f32{l[i], r[i]}) {
				if v != v || v > 1e30 || v < -1e30 {
					c.nonfinite += 1
					continue
				}
				if abs(v) > c.peak {c.peak = abs(v)}
			}
		}
	}

	engine.engine_note_on(&eng, note, 1.0)
	remaining := hold
	for remaining > 0 {
		n := min(remaining, BLOCK)
		engine.engine_process(&eng, left[:n], right[:n])
		scan(left[:n], right[:n], &c)
		remaining -= n
	}
	engine.engine_note_off(&eng, note)
	remaining = tail
	for remaining > 0 {
		n := min(remaining, BLOCK)
		engine.engine_process(&eng, left[:n], right[:n])
		scan(left[:n], right[:n], &c)
		remaining -= n
	}

	switch {
	case c.nonfinite > 0:
		c.verdict = .Non_Finite
	case c.peak > RUNAWAY_LEVEL:
		c.verdict = .Runaway
	case c.peak == 0:
		// Not a failure on its own -- a patch can be legitimately silent at one
		// setting of one knob -- but worth seeing in the list.
		c.verdict = .Silent
	case:
		c.verdict = .Ok
	}
	return c
}
