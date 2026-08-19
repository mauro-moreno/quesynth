package bench

// What the engine costs, measured rather than reasoned about.
//
// The number that matters for an instrument is the **real-time factor**: how
// much faster than real time the engine renders. A host asks for one block
// every `block / sample_rate` seconds, so an RTF of 100x means the engine used
// 1% of one core and a hundred instances would fit; an RTF of 1x means it is
// exactly keeping up and any other plugin in the project makes it drop out.
//
// Everything here renders into a buffer that is allocated once and reused, so
// what is timed is the engine and not the allocator, and every run is preceded
// by a warm-up render that is thrown away -- the first pass through a cold
// instruction cache is not what a running instrument does.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../../src/engine"
import "../../src/patch"

SAMPLE_RATE :: f32(48000)
BLOCK :: 128
SECONDS :: f64(4)

// Notes spread over two octaves rather than a cluster, so voices land on
// different filter cutoffs and envelope positions and none of the work is
// shared by accident.
NOTES := [?]int{48, 52, 55, 59, 62, 65, 69, 72, 40, 44, 47, 51, 54, 57, 61, 64}

Result :: struct {
	label:   string,
	rtf:     f64,
	ns_per_sample: f64,
	percent_of_core: f64,
}

// One measurement: render `SECONDS` of audio with `voices` notes held, and
// report how long the wall clock says it took.
measure :: proc(
	label: string,
	p: patch.Patch,
	voices: int,
	left, right: []f32,
) -> Result {
	eng: engine.Engine
	engine.engine_load_patch(&eng, p, SAMPLE_RATE)
	defer engine.engine_destroy(&eng)

	for i in 0 ..< voices {
		engine.engine_note_on(&eng, NOTES[i % len(NOTES)], 0.8)
	}

	total_frames := int(f64(SAMPLE_RATE) * SECONDS)

	// Warm-up, discarded. A cold cache and an envelope still in its attack are
	// not the steady state being measured.
	for f := 0; f < SAMPLE_RATE_WARMUP; f += BLOCK {
		engine.engine_process(&eng, left[:BLOCK], right[:BLOCK])
	}

	start := time.now()
	rendered := 0
	for rendered < total_frames {
		n := min(BLOCK, total_frames - rendered)
		engine.engine_process(&eng, left[:n], right[:n])
		rendered += n
	}
	elapsed := time.duration_seconds(time.since(start))

	audio_seconds := f64(total_frames) / f64(SAMPLE_RATE)
	rtf := audio_seconds / elapsed
	return Result {
		label = label,
		rtf = rtf,
		ns_per_sample = elapsed * 1.0e9 / f64(total_frames),
		percent_of_core = 100.0 / rtf,
	}
}

SAMPLE_RATE_WARMUP :: 24000

// Odin's `fmt` pads a widthed float with zeros rather than spaces, which turns
// a column of numbers into a column of noise. Formatted without a width and
// padded by hand instead.
pad :: proc(s: string, width: int) -> string {
	if len(s) >= width {
		return s
	}
	spaces := "                                        "
	return fmt.tprintf("%v%v", spaces[:width - len(s)], s)
}

print_header :: proc(title: string) {
	fmt.printfln("\n%v", title)
	fmt.println("                    RTF   ns/sample   core")
}

print_result :: proc(r: Result) {
	fmt.printfln(
		"  %-12s %v %v %v",
		r.label,
		pad(fmt.tprintf("%.1fx", r.rtf), 8),
		pad(fmt.tprintf("%.0f", r.ns_per_sample), 10),
		pad(fmt.tprintf("%.1f%%", r.percent_of_core), 7),
	)
}

// A patch built from the reference's own defaults, with specific parameters
// overridden. Used to isolate what a single feature costs.
default_patch :: proc(overrides: map[int]int = nil) -> patch.Patch {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
		p.present[i] = true
	}
	for index, value in overrides {
		p.values[index] = value
	}
	return p
}

main :: proc() {
	args := os.args[1:]

	left := make([]f32, BLOCK)
	right := make([]f32, BLOCK)
	defer delete(left)
	defer delete(right)

	fmt.printfln("engine benchmark -- %v Hz, %v-sample blocks, %.0fs per measurement",
		int(SAMPLE_RATE), BLOCK, SECONDS)
	fmt.printfln("struct sizes: Engine_Params %v B, Voice %v B, Engine %v B",
		size_of(engine.Engine_Params), size_of(engine.Voice), size_of(engine.Engine))

	// -- how the cost scales with polyphony ---------------------------------
	//
	// The interesting part is the intercept, not the slope: whatever the engine
	// costs at zero voices is paid on every sample no matter how quiet the
	// patch is.
	if len(args) == 0 || args[0] == "voices" {
		p := default_patch()
		print_header("cost against held voices (default patch)")
		for v in ([?]int{0, 1, 2, 4, 8, 16}) {
			label := fmt.tprintf("%v", v)
			print_result(measure(label, p, v, left, right))
		}
	}

	// -- what each effect section costs -------------------------------------
	if len(args) == 0 || args[0] == "effects" {
		print_header("one voice, effect sections switched on")
		base := default_patch()
		print_result(measure("none", base, 1, left, right))

		// Parameter numbers from src/patch: 54 delay on, 60 chorus on,
		// 74 equaliser on, 78 effect type.
		Section :: struct {
			name:  string,
			index: int,
			value: int,
		}
		for spec in ([?]Section{
			{"delay", 54, 1},
			{"chorus", 60, 1},
			{"equaliser", 74, 1},
		}) {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[spec.index] = spec.value
			print_result(measure(spec.name, default_patch(overrides), 1, left, right))
		}
	}

	// -- what is expensive inside a voice -----------------------------------
	//
	// Held at 8 voices so the per-voice cost dominates the fixed per-sample
	// cost and a difference is visible rather than buried in it.
	if len(args) == 0 || args[0] == "voice" {
		print_header("8 voices, filter type (parameter 14)")
		FILTERS := [?]string {
			"LP 12", "LP 24", "HP 12", "BP 12", "ladder",
		}
		for name, value in FILTERS {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[14] = value
			print_result(measure(FILTERS[value], default_patch(overrides), 8, left, right))
		}

		// Labelled by what the control reads, not by the integer written into
		// it. Parameter 93's stored value is its position in a state table and
		// not the unison depth, which made an earlier run of this benchmark
		// look non-monotonic when it was only mislabelled.
		print_header("8 voices, unison depth (parameter 73 on, 93 stepped)")
		for stored in 0 ..< len(patch.parameter_states(93)) {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[73] = 1
			overrides[93] = stored
			label := fmt.tprintf("%v voices", state_display(93, stored))
			print_result(measure(label, default_patch(overrides), 8, left, right))
		}
	}

	// -- the real bank ------------------------------------------------------
	//
	// Synthetic patches understate the cost: the factory patches turn on
	// unison, effects and both LFOs in combinations nothing here would think
	// to try.
	if len(args) >= 1 && args[0] == "bank" {
		dir := len(args) >= 2 ? args[1] : "patches/incoming/soundbank00"
		handle, open_err := os.open(dir)
		if open_err != nil {
			fmt.eprintfln("bench: cannot open %v: %v", dir, open_err)
			os.exit(1)
		}
		files, read_err := os.read_dir(handle, -1, context.allocator)
		os.close(handle)
		if read_err != nil {
			fmt.eprintfln("bench: cannot read %v: %v", dir, read_err)
			os.exit(1)
		}

		worst_rtf := 1.0e30
		worst_name := ""
		total := 0.0
		count := 0

		fmt.printfln("\n8 voices held, every patch in %v", dir)
		fmt.println("  patch                    RTF   % of one core")
		for f in files {
			if !strings.has_suffix(f.name, ".sy1") {
				continue
			}
			data, data_err := os.read_entire_file(f.fullpath, context.allocator)
			if data_err != nil {
				continue
			}
			defer delete(data)
			parsed, parse_err := patch.parse_sy1(data)
			if parse_err != .None {
				continue
			}
			r := measure(f.name, parsed, 8, left, right)
			total += r.rtf
			count += 1
			if r.rtf < worst_rtf {
				worst_rtf = r.rtf
				worst_name = strings.clone(f.name)
			}
			// Only the expensive end is worth printing patch by patch.
			if r.rtf < 200 {
				fmt.printfln("  %-20s %7.1fx %10.2f%%", f.name, r.rtf, r.percent_of_core)
			}
		}
		if count > 0 {
			fmt.printfln("\n  %v patches, mean %.1fx, worst %.1fx (%v)",
				count, total / f64(count), worst_rtf, worst_name)
		}
	}
}

// The displayed value for a stored integer, so a benchmark label says what the
// control actually reads rather than what was written into it. Parameter 93's
// stored value is not its unison depth, which made an earlier run of this
// benchmark look non-monotonic when it was only mislabelled.
state_display :: proc(index, stored: int) -> string {
	states := patch.parameter_states(index)
	if stored < 0 || stored >= len(states) {
		return fmt.tprintf("raw %v", stored)
	}
	return states[stored].display
}
