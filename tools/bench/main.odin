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
import "core:strconv"
import "core:strings"
import "core:time"

import "../../src/engine"
import "../../src/patch"

SAMPLE_RATE :: f32(48000)
BLOCK :: 128
SECONDS :: f64(2)

// Notes spread over two octaves rather than a cluster, so voices land on
// different filter cutoffs and envelope positions and none of the work is
// shared by accident.
NOTES := [?]int{48, 52, 55, 59, 62, 65, 69, 72, 40, 44, 47, 51, 54, 57, 61, 64}

Result :: struct {
	label:   string,
	rtf:     f64,
	ns_per_sample: f64,
	percent_of_core: f64,

	// What the engine actually built, rather than what the patch asked for.
	// Reported because a benchmark that only prints time cannot tell a slow
	// configuration from a differently-sized one: eight notes at unison 8 and
	// eight notes at unison 2 are not the same amount of work unless the same
	// number of voices and layers are really running.
	active_voices: int,
	unison_count:  int,
	layers:        int,
}

// One measurement: render `SECONDS` of audio with `voices` notes held, and
// report how long the wall clock says it took -- repeated, keeping the
// *fastest* run rather than averaging.
//
// Not an optimistic choice -- the honest one. Noise on a benchmark is one
// sided: nothing another process does can make this code run faster than it
// can, so every disturbance adds time and the minimum is the closest estimate
// of the engine's own cost. Averaging folds in whatever else the machine was
// doing.
//
// This exists because a single sample lied. One reading of sixteen voices at
// unison eight came in 32% above every other reading of the same
// configuration, which looked exactly like a cache cliff and was in fact one
// disturbed run.
REPEATS :: 3

measure :: proc(
	label: string,
	p: patch.Patch,
	voices: int,
	left, right: []f32,
) -> Result {
	total_frames := int(f64(SAMPLE_RATE) * SECONDS)
	best := 1.0e30
	active, unison, layers := 0, 0, 0

	for repeat in 0 ..< REPEATS {
		eng: engine.Engine
		engine.engine_load_patch(&eng, p, SAMPLE_RATE)

		for i in 0 ..< voices {
			engine.engine_note_on(&eng, NOTES[i % len(NOTES)], 0.8)
		}

		// Warm-up, discarded. A cold cache and an envelope still in its attack
		// are not the steady state being measured.
		for f := 0; f < WARMUP_FRAMES; f += BLOCK {
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
		best = min(best, elapsed)

		// Counted after rendering, so a voice that was stolen or that finished
		// its release is not counted as work that was done.
		active, unison, layers = 0, 0, 0
		for vi in 0 ..< len(eng.voices) {
			v := &eng.voices[vi]
			if !v.active {
				continue
			}
			active += 1
			layers += v.unison_count
			unison = v.unison_count
		}

		engine.engine_destroy(&eng)
	}

	audio_seconds := f64(total_frames) / f64(SAMPLE_RATE)
	rtf := audio_seconds / best
	return Result {
		label = label,
		rtf = rtf,
		ns_per_sample = best * 1.0e9 / f64(total_frames),
		percent_of_core = 100.0 / rtf,
		active_voices = active,
		unison_count = unison,
		layers = layers,
	}
}

WARMUP_FRAMES :: 12000

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
	fmt.println("                    RTF   ns/sample   core   voices  layers   ns/layer")
}

print_result :: proc(r: Result) {
	// ns per layer is the number that makes configurations comparable: it
	// divides out how much the engine was actually asked to do.
	per_layer := r.layers > 0 ? (r.ns_per_sample - IDLE_NS) / f64(r.layers) : 0
	fmt.printfln(
		"  %-12s %v %v %v %v %v %v",
		r.label,
		pad(fmt.tprintf("%.1fx", r.rtf), 8),
		pad(fmt.tprintf("%.0f", r.ns_per_sample), 10),
		pad(fmt.tprintf("%.1f%%", r.percent_of_core), 7),
		pad(fmt.tprintf("%v", r.active_voices), 7),
		pad(fmt.tprintf("%v", r.layers), 7),
		pad(fmt.tprintf("%.0f", per_layer), 10),
	)
}

// The measured fixed per-sample cost with no voices at all, subtracted before
// dividing so a per-layer figure is the layer's own cost and not the layer's
// share of the engine's overhead.
IDLE_NS :: 119.0

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

		// The enables, taken from ui/layout.js rather than guessed. An earlier
		// version of this benchmark used 54, 60 and 74 -- which are the chorus
		// *rate*, the equaliser *tone* and portamento -- and duly reported that
		// switching the effects on cost nothing, because it had not switched
		// anything on.
		Section :: struct {
			name:  string,
			index: int,
			value: int,
		}
		for spec in ([?]Section{
			{"delay", 65, 1},
			{"chorus", 66, 1},
			{"effect unit", 77, 1},
			{"LFO 1", 57, 1},
			{"LFO 2", 58, 1},
			{"mod envelope", 10, 1},
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

		// Parameter 93 is display-keyed: the stored integer *is* the unison
		// depth, so the meaningful range is 2..8 and anything below it is out
		// of range and clamps to the top. Stepped over the real range, and
		// labelled through the engine's own resolution so the label cannot
		// disagree with what was bound.
		print_header("8 voices, unison depth (parameter 73 on, 93 = depth)")
		for stored in 1 ..= engine.MAX_UNISON {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[73] = 1
			overrides[93] = stored
			label := fmt.tprintf("%v -> %v", stored, state_display(93, stored))
			print_result(measure(label, default_patch(overrides), 8, left, right))
		}
	}

	// -- where the model stops holding --------------------------------------
	//
	// The two-term model is accurate to a few percent until the working set
	// gets large, and then it under-predicts badly. Sweeping depth at a fixed
	// voice count finds the knee, which is what says whether the cost is
	// arithmetic (a straight line) or memory (a bend).
	if len(args) >= 1 && args[0] == "knee" {
		voices := 16
		if len(args) >= 2 {
			if parsed, ok := strconv.parse_int(args[1]); ok {
				voices = parsed
			}
		}
		print_header(fmt.tprintf("%v voices, unison depth swept", voices))
		for depth in 1 ..= engine.MAX_UNISON {
			overrides := make(map[int]int)
			defer delete(overrides)
			if depth > 1 {
				overrides[73] = 1
				overrides[93] = depth
			}
			r := measure(fmt.tprintf("depth %v", depth), default_patch(overrides), voices, left, right)
			print_result(r)
		}
	}

	// -- does a two-term cost model actually hold? --------------------------
	//
	// Solved from two points -- eight voices at unison 2 and at unison 8 --
	// and then *predicted* against configurations it was not fitted to. A model
	// that only reproduces the numbers it was built from has said nothing.
	//
	// The split matters musically: the envelopes, the LFOs and the filter are
	// per voice and shared by that voice's whole unison stack, so a layer is
	// much cheaper than a note. That is why a unison patch is affordable at all.
	if len(args) >= 1 && args[0] == "model" {
		IDLE :: 119.0
		PER_VOICE :: 101.0
		PER_LAYER :: 68.0

		fmt.printfln("\nmodel: %.0f ns idle + %.0f per voice + %.0f per unison layer",
			IDLE, PER_VOICE, PER_LAYER)
		fmt.println("  config              predicted   measured    error")

		Config :: struct {
			voices: int,
			depth:  int,
		}
		for c in ([?]Config{
			{1, 1}, {4, 1}, {8, 1}, {16, 1},
			{4, 4}, {8, 4}, {16, 4},
			{2, 8}, {16, 8},
		}) {
			overrides := make(map[int]int)
			defer delete(overrides)
			if c.depth > 1 {
				overrides[73] = 1
				overrides[93] = c.depth
			}
			r := measure("", default_patch(overrides), c.voices, left, right)
			predicted := IDLE + f64(r.active_voices) * PER_VOICE + f64(r.layers) * PER_LAYER
			error := 100.0 * (r.ns_per_sample - predicted) / predicted
			fmt.printfln(
				"  %-18s %v %v %v",
				fmt.tprintf("%v voices x %v", c.voices, c.depth),
				pad(fmt.tprintf("%.0f", predicted), 9),
				pad(fmt.tprintf("%.0f", r.ns_per_sample), 10),
				pad(fmt.tprintf("%+.1f%%", error), 8),
			)
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

// What the control reads for a stored integer.
//
// Resolved the way the engine resolves it, rather than by indexing the state
// table with the stored value. For a *display-keyed* parameter those are not
// the same thing: the stored integer is the display, and its position in the
// table is unrelated. Parameter 93 is one, and indexing it by position made an
// earlier run of this benchmark report that unison 2 cost more than unison 8 --
// which was this tool mislabelling its own axis, not the engine misbehaving.
state_display :: proc(index, stored: int) -> string {
	return engine.resolved_display(index, stored)
}
