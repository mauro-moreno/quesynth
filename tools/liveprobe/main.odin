// liveprobe - play patches the way a host plays them, not the way a file does.
//
//   odin run tools/liveprobe -- patches/incoming/soundbank00
//   odin run tools/liveprobe -- build/tmp/corpus -rate=44100 -chord
//
// patchprobe answers "does this file reach the engine and make a sound". It
// loads one patch into a fresh engine, plays one note, and stops. A host does
// none of those things: it changes the patch while a note is sounding, plays
// chords deeper than the voice pool, sends controllers, moves the tempo, and
// asks for blocks of whatever length its buffer happens to be -- including one
// sample. Every one of those is a path `engine_load_patch` alone never takes.
//
// The one that matters most is the patch change. `engine_apply_patch` exists
// because reloading would cut the sounding note, and it has a second path
// inside it: when parameter 94 differs between the two patches the voice pool
// has to be resized, which frees and rebuilds everything the audio path is
// holding. That branch is taken by the *pair* of patches, not by either one, so
// no probe that loads a single patch can reach it. This walks consecutive pairs
// for exactly that reason.
//
// Blocks are deliberately ragged. A fixed 256 hides anything that depends on a
// block boundary -- an effect that reads one sample ahead, a smoother that
// assumes it is called more than once -- so the run lengths cycle through 1, 2,
// 3, 7, 64 and 512 instead.
//
// A hard crash takes the process with it, so each pair is written to stderr
// before it runs and results go to stdout.
package liveprobe

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

MAX_BLOCK :: 512
BLOCK_RUNS := [?]int{1, 2, 3, 7, 64, 512}

// A chord deeper than MAX_POLYPHONY, so voice stealing is exercised rather than
// assumed.
CHORD := [?]int{36, 43, 48, 52, 55, 60, 64, 67, 72, 76, 79, 84, 88, 91, 96, 100}

// Controllers a patch may or may not have asked for. Sent regardless: an
// assignment the patch does not use must be as safe as one it does.
CONTROLLERS := [?]int{1, 2, 7, 11, 64, 71, 74, 120, 121}

Verdict :: enum {
	Ok,
	Non_Finite,
	Runaway,
}

RUNAWAY_LEVEL :: f32(64)

Result :: struct {
	from:      string,
	to:        string,
	verdict:   Verdict,
	peak:      f32,
	nonfinite: int,
}

usage :: proc() {
	fmt.eprintln("usage: liveprobe [options] <file or directory>...")
	fmt.eprintln("  -rate=N     sample rate (default 48000)")
	fmt.eprintln("  -chord      hold sixteen notes instead of one")
	fmt.eprintln("  -failures   print only the pairs that misbehaved")
	fmt.eprintln("  -quiet      no progress on stderr")
	os.exit(2)
}

main :: proc() {
	roots: [dynamic]string
	defer delete(roots)
	rate := f32(48000)
	chord, failures_only, quiet := false, false, false

	for arg in os.args[1:] {
		switch {
		case arg == "-chord":
			chord = true
		case arg == "-failures":
			failures_only = true
		case arg == "-quiet":
			quiet = true
		case strings.has_prefix(arg, "-rate="):
			rate = f32(int_arg(arg, "-rate="))
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("liveprobe: unknown option %q", arg)
			usage()
		case:
			append(&roots, arg)
		}
	}
	if len(roots) == 0 || rate <= 0 {usage()}

	paths: [dynamic]string
	defer delete(paths)
	for root in roots {
		collect(root, &paths)
	}
	slice.sort(paths[:])
	if len(paths) == 0 {
		fmt.eprintln("liveprobe: no patches found")
		os.exit(1)
	}

	// Read every patch first. The values are all that is played, and holding
	// them means the pair loop is not re-reading files it already read.
	loaded: [dynamic]patch.Patch
	names: [dynamic]string
	defer delete(loaded)
	defer delete(names)
	for path in paths {
		p, ok := read_patch(path)
		if !ok {continue}
		append(&loaded, p)
		append(&names, path)
	}
	if len(loaded) == 0 {
		fmt.eprintln("liveprobe: nothing parsed")
		os.exit(1)
	}

	results: [dynamic]Result
	defer delete(results)

	// Consecutive pairs, wrapping, so every patch is both loaded fresh and
	// swapped in under a sounding note.
	for i in 0 ..< len(loaded) {
		j := (i + 1) % len(loaded)
		if !quiet {
			fmt.eprintfln("[%d/%d] %s -> %s", i + 1, len(loaded), names[i], names[j])
		}
		append(&results, probe_pair(loaded[i], loaded[j], names[i], names[j], rate, chord))
	}

	counts: [Verdict]int
	for r in results {
		counts[r.verdict] += 1
		if failures_only && r.verdict == .Ok {continue}
		fmt.printfln("%s\t%s\t%v\tpeak=%.4f\tnonfinite=%d", r.from, r.to, r.verdict, r.peak, r.nonfinite)
	}
	fmt.println("--")
	fmt.printfln("pairs:    %d", len(results))
	for v in Verdict {
		if counts[v] == 0 {continue}
		fmt.printfln("%v\t%d", v, counts[v])
	}
	if counts[.Ok] != len(results) {
		os.exit(1)
	}
}

int_arg :: proc(arg: string, prefix: string) -> int {
	value := 0
	for c in arg[len(prefix):] {
		if c < '0' || c > '9' {
			fmt.eprintfln("liveprobe: %q is not a number", arg)
			os.exit(2)
		}
		value = value * 10 + int(c - '0')
	}
	return value
}

collect :: proc(path: string, into: ^[dynamic]string) {
	if is_patch_file(path) {
		append(into, path)
		return
	}
	entries, err := os.read_directory_by_path(path, -1, context.allocator)
	if err != nil {return}
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if entry.type == .Directory {
			collect(strings.clone(entry.fullpath), into)
			continue
		}
		if is_patch_file(entry.fullpath) {
			append(into, strings.clone(entry.fullpath))
		}
	}
}

is_patch_file :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".sy1") || strings.has_suffix(lower, ".json")
}

// Whatever the file is, and .sy1 even when the sniffer will not say so: the
// point is to play what the reader can read, not to agree with detect_format.
read_patch :: proc(path: string) -> (p: patch.Patch, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {return {}, false}
	// Deliberately not freed: parse_sy1's name borrows out of this buffer and
	// the patch outlives this procedure. A probe leaking a file's worth of
	// bytes per patch is cheaper than a probe reading freed memory.
	if patch.detect_format(data) == .Json {
		parsed, err := patch.parse_patch_json(data)
		return parsed, err == .None
	}
	parsed, err := patch.parse_sy1(data)
	return parsed, err == .None
}

probe_pair :: proc(a, b: patch.Patch, from, to: string, rate: f32, chord: bool) -> Result {
	r := Result{from = from, to = to}

	eng: engine.Engine
	engine.engine_load_patch(&eng, a, rate)
	defer engine.engine_destroy(&eng)

	notes := chord ? CHORD[:] : CHORD[5:6]

	for n in notes {
		engine.engine_note_on(&eng, n, 0.8)
	}
	run(&eng, &r, 3)

	// A tempo the arpeggiator has to follow, moved mid-note.
	engine.engine_set_tempo(&eng, 174)
	run(&eng, &r, 1)

	// The patch change, under everything that is sounding. This is the branch
	// the probe exists for.
	engine.engine_apply_patch(&eng, b, true)
	run(&eng, &r, 3)

	// And back, so the pool is resized in both directions.
	engine.engine_apply_patch(&eng, a, true)
	run(&eng, &r, 2)

	for cc in CONTROLLERS {
		engine.engine_control_change(&eng, cc, 127)
		engine.engine_control_change(&eng, cc, 0)
	}
	engine.engine_set_pitch_bend(&eng, 1)
	run(&eng, &r, 1)
	engine.engine_set_pitch_bend(&eng, -1)
	run(&eng, &r, 1)

	for n in notes {
		engine.engine_note_off(&eng, n)
	}
	run(&eng, &r, 3)

	// Everything off, then a note again on the same engine: a stale voice or a
	// stale arpeggiator step shows up here rather than on a fresh instrument.
	engine.engine_all_notes_off(&eng)
	engine.engine_note_on(&eng, 96, 1.0)
	run(&eng, &r, 2)

	switch {
	case r.nonfinite > 0:
		r.verdict = .Non_Finite
	case r.peak > RUNAWAY_LEVEL:
		r.verdict = .Runaway
	case:
		r.verdict = .Ok
	}
	return r
}

// `passes` times through the ragged run lengths.
run :: proc(e: ^engine.Engine, r: ^Result, passes: int) {
	left: [MAX_BLOCK]f32
	right: [MAX_BLOCK]f32
	for _ in 0 ..< passes {
		for n in BLOCK_RUNS {
			engine.engine_process(e, left[:n], right[:n])
			for i in 0 ..< n {
				for v in ([2]f32{left[i], right[i]}) {
					if v != v || v > 1e30 || v < -1e30 {
						r.nonfinite += 1
						continue
					}
					if abs(v) > r.peak {r.peak = abs(v)}
				}
			}
		}
	}
}
