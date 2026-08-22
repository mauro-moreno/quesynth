// patchprobe - take every patch in a tree through the whole play path.
//
//   odin run tools/patchprobe -- patches/incoming
//   odin run tools/patchprobe -- patches/incoming/soundbank00 -failures
//   odin run tools/patchprobe -- patches/incoming -force-sy1
//
// Why this exists, and why it is not the null test. `s1probe compare` answers
// "does this engine sound like the reference"; it cannot answer "does this file
// reach the engine at all", because it only ever runs on files that already
// did. Every stage between the bytes on disk and a sample coming out is a place
// a patch can be lost, and each of them fails differently:
//
//   read     the file is not there or not readable
//   sniff    detect_format refuses to name the format, so nothing parses it
//   parse    the reader rejects a record
//   bind     bind_patch reads a table with a value the file supplied
//   render   the engine runs but produces NaN, silence, or a runaway level
//
// So the probe reports the *stage*, not a yes/no. A patch that is rejected by
// the sniffer and a patch that crashes the binder are both "cannot be played",
// and treating them as one number hides which of the two anyone has.
//
// -force-sy1 is the load-bearing switch: it pushes a buffer the sniffer refused
// into parse_sy1 anyway. If the sniffer is wrong the file parses, and whatever
// the engine then does with it is a bug the sniffer was hiding.
//
// On crashes. A segfault takes the process with it, so the file being probed is
// written to stderr *before* the engine touches it and results go to stdout.
// The last line on stderr names the file that died; `-start=N` resumes past it.
package patchprobe

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

SAMPLE_RATE :: f32(48000)

// Short by the renderer's standards, long enough for an envelope to open and an
// arpeggiator to take several steps at 120 BPM.
DEFAULT_HOLD :: 12000
DEFAULT_TAIL :: 6000
DEFAULT_BLOCK :: 256
MAX_BLOCK :: 4096

// Above this a sample is not a loud patch, it is a runaway feedback path. The
// reference cannot exceed a few units; sixty-four is well past any patch and
// well below where f32 stops being informative.
RUNAWAY_LEVEL :: f32(64)

Verdict :: enum {
	Ok,
	Unreadable,
	Sniff_Unknown,
	Parse_Failed,
	Silent,
	Non_Finite,
	Runaway,
}

Result :: struct {
	path:      string,
	name:      string,
	format:    patch.Patch_Format,
	forced:    bool, // parsed as .sy1 after the sniffer refused it
	verdict:   Verdict,
	detail:    string,
	polyphony: int,
	peak:      f32,
	nonfinite: int,
}

Options :: struct {
	roots:         [dynamic]string,
	note:          int,
	hold:          int,
	tail:          int,
	block:         int,
	force_sy1:     bool,
	failures_only: bool,
	start:         int,
	quiet:         bool,
}

usage :: proc() {
	fmt.eprintln("usage: patchprobe [options] <file or directory>...")
	fmt.eprintln("  -force-sy1     parse as .sy1 even when detect_format refuses the buffer")
	fmt.eprintln("  -failures      print only the patches that did not play")
	fmt.eprintln("  -note=N        MIDI note to play (default 60)")
	fmt.eprintln("  -hold=N        frames held (default 12000)")
	fmt.eprintln("  -tail=N        frames after note off (default 6000)")
	fmt.eprintln("  -block=N       process block size (default 256)")
	fmt.eprintln("  -start=N       skip the first N files, to resume past a crash")
	fmt.eprintln("  -quiet         summary only, no progress on stderr")
	os.exit(2)
}

main :: proc() {
	opt := Options {
		note  = 60,
		hold  = DEFAULT_HOLD,
		tail  = DEFAULT_TAIL,
		block = DEFAULT_BLOCK,
	}
	defer delete(opt.roots)

	for arg in os.args[1:] {
		switch {
		case arg == "-force-sy1":
			opt.force_sy1 = true
		case arg == "-failures":
			opt.failures_only = true
		case arg == "-quiet":
			opt.quiet = true
		case strings.has_prefix(arg, "-note="):
			opt.note = int_arg(arg, "-note=")
		case strings.has_prefix(arg, "-hold="):
			opt.hold = int_arg(arg, "-hold=")
		case strings.has_prefix(arg, "-tail="):
			opt.tail = int_arg(arg, "-tail=")
		case strings.has_prefix(arg, "-block="):
			opt.block = clamp(int_arg(arg, "-block="), 1, MAX_BLOCK)
		case strings.has_prefix(arg, "-start="):
			opt.start = int_arg(arg, "-start=")
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("patchprobe: unknown option %q", arg)
			usage()
		case:
			append(&opt.roots, arg)
		}
	}
	if len(opt.roots) == 0 {usage()}

	files: [dynamic]string
	defer {
		for f in files {delete(f)}
		delete(files)
	}
	for root in opt.roots {
		collect(root, &files)
	}
	slice.sort(files[:])

	results: [dynamic]Result
	defer delete(results)

	for path, i in files {
		if i < opt.start {continue}
		// Before the work, not after it: this line is what names the file if
		// the engine takes the process down.
		if !opt.quiet {
			fmt.eprintfln("[%d/%d] %s", i + 1, len(files), path)
		}
		append(&results, probe_file(path, opt))
	}

	report(results[:], opt)
}

int_arg :: proc(arg: string, prefix: string) -> int {
	value := 0
	text := arg[len(prefix):]
	negative := false
	for c, i in text {
		if i == 0 && c == '-' {
			negative = true
			continue
		}
		if c < '0' || c > '9' {
			fmt.eprintfln("patchprobe: %q is not a number", arg)
			os.exit(2)
		}
		value = value * 10 + int(c - '0')
	}
	return -value if negative else value
}

// Every patch file under a path, directories walked.
collect :: proc(path: string, into: ^[dynamic]string) {
	if is_patch_file(path) {
		append(into, strings.clone(path))
		return
	}

	entries, err := os.read_directory_by_path(path, -1, context.allocator)
	if err != nil {
		// Not a directory and not a patch: still recorded, so a mistyped path
		// is reported rather than silently probing nothing.
		append(into, strings.clone(path))
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if entry.type == .Directory {
			collect(entry.fullpath, into)
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

probe_file :: proc(path: string, opt: Options) -> Result {
	result := Result{path = path}

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		result.verdict = .Unreadable
		result.detail = fmt.aprintf("%v", read_err)
		return result
	}
	defer delete(data, context.allocator)

	result.format = patch.detect_format(data)

	p: patch.Patch
	owned := false
	switch result.format {
	case .Json:
		parsed, err := patch.parse_patch_json(data)
		if err != .None {
			result.verdict = .Parse_Failed
			result.detail = fmt.aprintf("json %v", err)
			return result
		}
		p, owned = parsed, true
	case .Sy1:
		parsed, err := patch.parse_sy1(data)
		if err != .None {
			result.verdict = .Parse_Failed
			result.detail = fmt.aprintf("sy1 %v", err)
			return result
		}
		p = parsed
	case .Unknown:
		// The sniffer will not name it. Does the reader agree?
		if !opt.force_sy1 {
			result.verdict = .Sniff_Unknown
			parsed, err := patch.parse_sy1(data)
			if err == .None {
				result.detail = fmt.aprintf("sniff refused, parse_sy1 accepts %q", parsed.name)
			} else {
				result.detail = fmt.aprintf("sniff refused, parse_sy1 %v", err)
			}
			return result
		}
		parsed, err := patch.parse_sy1(data)
		if err != .None {
			result.verdict = .Parse_Failed
			result.detail = fmt.aprintf("forced sy1 %v", err)
			return result
		}
		p = parsed
		result.forced = true
	}
	// At this scope rather than nested in the `if`, or the name is freed here
	// and read on the next line. tools/render had the same bug.
	defer if owned {patch.destroy_patch(p)}

	result.name = strings.clone(strings.trim_space(p.name))
	result.polyphony = engine.bind_patch(p).polyphony

	eng: engine.Engine
	engine.engine_load_patch(&eng, p, SAMPLE_RATE)
	defer engine.engine_destroy(&eng)

	peak, nonfinite := render(&eng, opt)
	result.peak = peak
	result.nonfinite = nonfinite

	switch {
	case nonfinite > 0:
		result.verdict = .Non_Finite
		result.detail = fmt.aprintf("%d non-finite samples", nonfinite)
	case peak > RUNAWAY_LEVEL:
		result.verdict = .Runaway
		result.detail = fmt.aprintf("peak %.1f", peak)
	case peak == 0:
		result.verdict = .Silent
		result.detail = "no output"
	case:
		result.verdict = .Ok
	}
	return result
}

// Block by block with the note off between hold and tail, which is how a host
// drives it: a patch that only misbehaves on the second block, or on release,
// is invisible to one long call.
render :: proc(e: ^engine.Engine, opt: Options) -> (peak: f32, nonfinite: int) {
	left: [MAX_BLOCK]f32
	right: [MAX_BLOCK]f32
	block := clamp(opt.block, 1, MAX_BLOCK)

	scan :: proc(l, r: []f32, peak: ^f32, nonfinite: ^int) {
		for i in 0 ..< len(l) {
			for v in ([2]f32{l[i], r[i]}) {
				// NaN fails both comparisons with itself; an infinity is
				// finite-looking to abs() but not to this bound.
				if v != v || v > 1e30 || v < -1e30 {
					nonfinite^ += 1
					continue
				}
				if abs(v) > peak^ {peak^ = abs(v)}
			}
		}
	}

	engine.engine_note_on(e, opt.note, 1.0)
	remaining := opt.hold
	for remaining > 0 {
		n := min(remaining, block)
		engine.engine_process(e, left[:n], right[:n])
		scan(left[:n], right[:n], &peak, &nonfinite)
		remaining -= n
	}

	engine.engine_note_off(e, opt.note)
	remaining = opt.tail
	for remaining > 0 {
		n := min(remaining, block)
		engine.engine_process(e, left[:n], right[:n])
		scan(left[:n], right[:n], &peak, &nonfinite)
		remaining -= n
	}
	return
}

report :: proc(results: []Result, opt: Options) {
	counts: [Verdict]int
	for r in results {
		counts[r.verdict] += 1
	}

	for r in results {
		if opt.failures_only && r.verdict == .Ok {continue}
		fmt.printfln(
			"%s\t%v\t%v\tpoly=%d\tpeak=%.4f\t%s%s",
			r.path,
			r.format,
			r.verdict,
			r.polyphony,
			r.peak,
			r.detail,
			r.forced ? " [forced]" : "",
		)
	}

	fmt.println("--")
	fmt.printfln("probed:   %d", len(results))
	for verdict in Verdict {
		if counts[verdict] == 0 {continue}
		fmt.printfln("%v\t%d", verdict, counts[verdict])
	}
	if counts[.Ok] != len(results) {
		os.exit(1)
	}
}
