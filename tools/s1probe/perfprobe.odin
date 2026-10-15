package s1probe

// s1probe perf - what each engine costs to run, measured side by side.
//
// The reference is Synth1's own `Synth1 VST64.dll`, driven through
// `processReplacing`; ours is `engine_process`. Both receive the same patch (the
// reference through its own state chunk, as in `compare`), the same notes at the
// same velocity, the same block size and the same warm-up, and both are timed
// with the same clock. Runs alternate reference, ours, reference, ours..., and
// each configuration keeps the fastest of its repeats: a disturbance can only
// add time, so the minimum is the closest reading of the engine's own cost.
//
// The thread is pinned to one core and the process raised in priority so that
// scheduler noise does not decide the ratio. The peak of the last timed block
// is printed for both engines: a configuration in which one engine has gone
// silent is not measuring the same work.
//
// Build with the heap held below 4 GB, or the reference faults as soon as a
// second voice sounds (it truncates a pointer to 32 bits):
//
//   odin build tools/s1probe -o:speed -out:build/s1probe-perf.exe ^
//     -extra-linker-flags:"/HIGHENTROPYVA:NO /DYNAMICBASE:NO /BASE:0x400000"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"

import sengine "../../src/engine"
import cpatch "../../src/patch"

PERF_SECONDS :: 2.0
PERF_WARMUP_FRAMES :: 12000
PERF_NOTES := [16]u8{48, 52, 55, 59, 62, 65, 69, 72, 40, 44, 47, 51, 54, 57, 61, 64}

Perf_Options :: struct {
	block:    int,
	repeats:  int,
	banks:    [dynamic]string,
	sections: [dynamic]string,
	csv:      string,
	only:     string,
}

Perf_Case :: struct {
	label:  string,
	parsed: cpatch.Patch,
	voices: int,
}

Perf_Reading :: struct {
	ns_per_sample: f64,
	peak:          f32,
	mismatches:    int,
	active_voices: int,
	ok:            bool,
}

Perf_Row :: struct {
	label: string,
	ref:   Perf_Reading,
	ours:  Perf_Reading,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetPriorityClass :: proc(process: win.HANDLE, priority_class: u32) -> win.BOOL ---
	SetThreadAffinityMask :: proc(thread: win.HANDLE, mask: uint) -> uint ---
	SetThreadPriority :: proc(thread: win.HANDLE, priority: i32) -> win.BOOL ---
}

HIGH_PRIORITY_CLASS :: u32(0x80)
THREAD_PRIORITY_HIGHEST :: i32(2)

perf_pin_thread :: proc() {
	SetPriorityClass(win.GetCurrentProcess(), HIGH_PRIORITY_CLASS)
	SetThreadAffinityMask(win.GetCurrentThread(), 1 << 2)
	SetThreadPriority(win.GetCurrentThread(), THREAD_PRIORITY_HIGHEST)
}

perf_block_peak :: proc(left, right: []f32) -> f32 {
	peak: f32
	for i in 0 ..< len(left) {
		peak = max(peak, abs(left[i]), abs(right[i]))
	}
	return peak
}

perf_time_reference :: proc(
	dll: string,
	c: Perf_Case,
	pristine, work: []byte,
	block: int,
) -> (
	reading: Perf_Reading,
) {
	p, loaded := open_reference(dll)
	if !loaded {
		return
	}
	defer close_reference(&p)

	parsed := c.parsed
	reading.mismatches = load_reference_patch(&p, &parsed, pristine, work)
	p.eff.dispatcher(p.eff, i32(Op.SetBlockSize), 0, block, nil, 0)

	e := p.eff
	left := make([]f32, block)
	right := make([]f32, block)
	silence := make([]f32, block)
	defer delete(left)
	defer delete(right)
	defer delete(silence)
	outs := [2][^]f32{raw_data(left), raw_data(right)}
	ins := [1][^]f32{raw_data(silence)}

	host_transport_reset()
	if c.voices > 0 {
		send_midi_notes(&p, 0x90, PERF_NOTES[:c.voices], COMPARE_VELOCITY_MIDI, 0)
	}

	for done := 0; done < PERF_WARMUP_FRAMES; done += block {
		e.process_replacing(e, raw_data(ins[:]), raw_data(outs[:]), i32(block))
		host_transport_advance(block)
	}

	total := int(PERF_SECONDS * f64(SAMPLE_RATE))
	total -= total % block
	start := time.tick_now()
	for done := 0; done < total; done += block {
		e.process_replacing(e, raw_data(ins[:]), raw_data(outs[:]), i32(block))
		host_transport_advance(block)
	}
	elapsed := time.duration_seconds(time.tick_since(start))

	reading.ns_per_sample = elapsed * 1.0e9 / f64(total)
	reading.peak = perf_block_peak(left, right)
	reading.ok = true
	return
}

perf_time_ours :: proc(c: Perf_Case, block: int) -> (reading: Perf_Reading) {
	eng: sengine.Engine
	sengine.engine_load_patch(&eng, c.parsed, f32(SAMPLE_RATE))
	defer sengine.engine_destroy(&eng)

	left := make([]f32, block)
	right := make([]f32, block)
	defer delete(left)
	defer delete(right)

	for i in 0 ..< c.voices {
		sengine.engine_note_on(&eng, int(PERF_NOTES[i]), COMPARE_VELOCITY)
	}
	for done := 0; done < PERF_WARMUP_FRAMES; done += block {
		sengine.engine_process(&eng, left, right)
	}

	total := int(PERF_SECONDS * f64(SAMPLE_RATE))
	total -= total % block
	start := time.tick_now()
	for done := 0; done < total; done += block {
		sengine.engine_process(&eng, left, right)
	}
	elapsed := time.duration_seconds(time.tick_since(start))

	for vi in 0 ..< len(eng.voices) {
		if eng.voices[vi].active {
			reading.active_voices += 1
		}
	}
	reading.ns_per_sample = elapsed * 1.0e9 / f64(total)
	reading.peak = perf_block_peak(left, right)
	reading.ok = true
	return
}

perf_measure :: proc(dll: string, c: Perf_Case, pristine, work: []byte, opt: Perf_Options) -> Perf_Row {
	row := Perf_Row {
		label = c.label,
	}
	row.ref.ns_per_sample = 1.0e30
	row.ours.ns_per_sample = 1.0e30
	for _ in 0 ..< opt.repeats {
		if opt.only != "ours" {
			r := perf_time_reference(dll, c, pristine, work, opt.block)
			if r.ok && r.ns_per_sample < row.ref.ns_per_sample {
				row.ref = r
			}
		}
		if opt.only != "ref" {
			o := perf_time_ours(c, opt.block)
			if o.ok && o.ns_per_sample < row.ours.ns_per_sample {
				row.ours = o
			}
		}
	}
	return row
}

perf_pad :: proc(s: string, width: int) -> string {
	if len(s) >= width {
		return s
	}
	return fmt.tprintf("%v%v", strings.repeat(" ", width - len(s), context.temp_allocator), s)
}

perf_print_header :: proc(title: string) {
	fmt.printfln("\n%v", title)
	fmt.printfln(
		"  %-26s %v %v %v %v %v %v",
		"",
		perf_pad("ref ns/smp", 11),
		perf_pad("ours ns/smp", 12),
		perf_pad("ref RTF", 9),
		perf_pad("ours RTF", 9),
		perf_pad("ours/ref", 9),
		perf_pad("peaks ref/ours", 16),
	)
}

perf_rtf :: proc(ns_per_sample: f64) -> f64 {
	return 1.0e9 / f64(SAMPLE_RATE) / ns_per_sample
}

perf_print_row :: proc(r: Perf_Row) {
	if !r.ref.ok || !r.ours.ok {
		fmt.printfln("  %-26s  failed to load", r.label)
		return
	}
	ratio := r.ours.ns_per_sample / r.ref.ns_per_sample
	flag := r.ref.mismatches > 0 ? fmt.tprintf("  [%v params did not read back]", r.ref.mismatches) : ""
	fmt.printfln(
		"  %-26s %v %v %v %v %v %v%v",
		r.label,
		perf_pad(fmt.tprintf("%.0f", r.ref.ns_per_sample), 11),
		perf_pad(fmt.tprintf("%.0f", r.ours.ns_per_sample), 12),
		perf_pad(fmt.tprintf("%.0fx", perf_rtf(r.ref.ns_per_sample)), 9),
		perf_pad(fmt.tprintf("%.0fx", perf_rtf(r.ours.ns_per_sample)), 9),
		perf_pad(fmt.tprintf("%.2f", ratio), 9),
		perf_pad(fmt.tprintf("%.2f/%.2f", r.ref.peak, r.ours.peak), 16),
		flag,
	)
}

perf_base_patch :: proc(overrides: map[int]int = nil, bare := false) -> cpatch.Patch {
	p: cpatch.Patch
	for i in 0 ..< cpatch.PARAMETER_COUNT {
		p.values[i] = cpatch.PARAMETERS[i].default
		p.present[i] = true
	}
	if bare {
		for index in ([?]int{65, 66, 57, 58}) {
			p.values[index] = 0
		}
	}
	for index, value in overrides {
		p.values[index] = value
	}
	return p
}

perf_wants :: proc(opt: Perf_Options, section: string) -> bool {
	return len(opt.sections) == 0 || slice.contains(opt.sections[:], section)
}

perf_run_section :: proc(
	title: string,
	cases: []Perf_Case,
	dll: string,
	pristine, work: []byte,
	opt: Perf_Options,
	rows: ^[dynamic]Perf_Row,
) {
	perf_print_header(title)
	for c in cases {
		row := perf_measure(dll, c, pristine, work, opt)
		perf_print_row(row)
		append(rows, row)
	}
}

cmd_perf :: proc(dll: string, opt: Perf_Options) {
	perf_pin_thread()
	g_quiet_load = true

	pristine: []byte
	{
		p, ok := load(dll)
		if !ok {
			os.exit(1)
		}
		pristine = get_chunk_copy(&p, 0)
		unload(&p)
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	fmt.printfln(
		"perf -- %v Hz, %v-sample blocks, %.0f s per measurement, best of %v, thread pinned to core 2",
		SAMPLE_RATE,
		opt.block,
		PERF_SECONDS,
		opt.repeats,
	)
	fmt.printfln("reference: %v", dll)
	fmt.println("RTF = audio seconds rendered per CPU second; ns/smp = nanoseconds per output sample frame")

	rows: [dynamic]Perf_Row
	defer delete(rows)

	if perf_wants(opt, "voices") {
		cases: [dynamic]Perf_Case
		defer delete(cases)
		for v in ([?]int{0, 1, 2, 4, 8, 16}) {
			append(&cases, Perf_Case{fmt.tprintf("default patch, %v notes", v), perf_base_patch(), v})
		}
		for v in ([?]int{1, 8, 16}) {
			append(&cases, Perf_Case{fmt.tprintf("bare patch, %v notes", v), perf_base_patch(bare = true), v})
		}
		perf_run_section("polyphony (bare = delay, chorus and both LFOs off)", cases[:], dll, pristine, work, opt, &rows)
	}

	if perf_wants(opt, "sections") {
		Section :: struct {
			name:  string,
			index: int,
			value: int,
		}
		cases: [dynamic]Perf_Case
		defer delete(cases)
		for s in ([?]Section{
				{"bare", 0, -1},
				{"delay", 65, 1},
				{"chorus", 66, 1},
				{"effect unit", 77, 1},
				{"LFO 1", 57, 1},
				{"LFO 2", 58, 1},
				{"mod envelope", 10, 1},
			}) {
			overrides := make(map[int]int)
			defer delete(overrides)
			if s.value >= 0 {
				overrides[s.index] = s.value
			}
			append(&cases, Perf_Case{s.name, perf_base_patch(overrides, bare = true), 1})
		}
		for t in 0 ..< 10 {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[77] = 1
			overrides[78] = t
			append(&cases, Perf_Case{fmt.tprintf("effect unit type %v", t), perf_base_patch(overrides, bare = true), 1})
		}
		perf_run_section("one note, one section switched on over the bare patch", cases[:], dll, pristine, work, opt, &rows)
	}

	if perf_wants(opt, "filter") {
		cases: [dynamic]Perf_Case
		defer delete(cases)
		for t in 0 ..< 5 {
			overrides := make(map[int]int)
			defer delete(overrides)
			overrides[14] = t
			append(&cases, Perf_Case{fmt.tprintf("filter type %v", t), perf_base_patch(overrides, bare = true), 8})
		}
		perf_run_section("eight notes, filter type (parameter 14)", cases[:], dll, pristine, work, opt, &rows)
	}

	if perf_wants(opt, "unison") {
		cases: [dynamic]Perf_Case
		defer delete(cases)
		for voices in ([?]int{8, 16}) {
			for depth in 1 ..= 8 {
				overrides := make(map[int]int)
				defer delete(overrides)
				if depth > 1 {
					overrides[73] = 1
					overrides[93] = depth
				}
				append(&cases, Perf_Case{fmt.tprintf("%v notes, unison %v", voices, depth), perf_base_patch(overrides, bare = true), voices})
			}
		}
		perf_run_section("unison depth", cases[:], dll, pristine, work, opt, &rows)
	}

	if perf_wants(opt, "bank") {
		for bank in opt.banks {
			perf_run_bank(bank, dll, pristine, work, opt, &rows)
		}
	}

	if opt.csv != "" {
		perf_write_csv(opt.csv, rows[:])
	}
}

perf_run_bank :: proc(
	dir: string,
	dll: string,
	pristine, work: []byte,
	opt: Perf_Options,
	rows: ^[dynamic]Perf_Row,
) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintfln("perf: cannot read %q: %v", dir, err)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	perf_print_header(fmt.tprintf("eight notes held, every patch in %v (arpeggiator patches skipped: the reference crashes on them)", dir))
	bank_rows: [dynamic]Perf_Row
	defer delete(bank_rows)
	skipped := 0
	for info in entries {
		if !strings.has_suffix(strings.to_lower(info.name), ".sy1") {
			continue
		}
		data, read_err := os.read_entire_file(info.fullpath, context.allocator)
		if read_err != nil {
			continue
		}
		defer delete(data)
		parsed, parse_err := cpatch.parse_sy1(data)
		if parse_err != .None {
			continue
		}
		if parsed.values[59] != 0 {
			skipped += 1
			continue
		}
		row := perf_measure(dll, Perf_Case{strings.clone(info.name), parsed, 8}, pristine, work, opt)
		append(&bank_rows, row)
		append(rows, row)
	}

	slice.sort_by(bank_rows[:], proc(a, b: Perf_Row) -> bool {
		return a.ours.ns_per_sample / a.ref.ns_per_sample > b.ours.ns_per_sample / b.ref.ns_per_sample
	})
	fmt.println("  the five where ours is relatively slowest:")
	for r in bank_rows[:min(5, len(bank_rows))] {
		perf_print_row(r)
	}
	fmt.println("  the five where ours is relatively fastest:")
	for r in bank_rows[max(0, len(bank_rows) - 5):] {
		perf_print_row(r)
	}

	ratios: [dynamic]f64
	defer delete(ratios)
	ref_total, ours_total: f64
	ours_faster := 0
	for r in bank_rows {
		if !r.ref.ok || !r.ours.ok {
			continue
		}
		append(&ratios, r.ours.ns_per_sample / r.ref.ns_per_sample)
		ref_total += r.ref.ns_per_sample
		ours_total += r.ours.ns_per_sample
		if r.ours.ns_per_sample < r.ref.ns_per_sample {
			ours_faster += 1
		}
	}
	if len(ratios) == 0 {
		return
	}
	slice.sort(ratios[:])
	n := len(ratios)
	fmt.printfln(
		"\n  %v patches (%v arpeggiator patches skipped)\n  ours/ref cost ratio: min %.2f, median %.2f, mean-of-totals %.2f, p90 %.2f, max %.2f\n  ours cheaper on %v of %v patches\n  mean ns/sample: ref %.0f, ours %.0f",
		n,
		skipped,
		ratios[0],
		ratios[n / 2],
		ours_total / ref_total,
		ratios[n * 9 / 10],
		ratios[n - 1],
		ours_faster,
		n,
		ref_total / f64(n),
		ours_total / f64(n),
	)
}

perf_write_csv :: proc(path: string, rows: []Perf_Row) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "label,ref_ns_per_sample,ours_ns_per_sample,ratio,ref_peak,ours_peak,ref_mismatches\n")
	for r in rows {
		fmt.sbprintfln(
			&b,
			"%q,%.2f,%.2f,%.4f,%.4f,%.4f,%v",
			r.label,
			r.ref.ns_per_sample,
			r.ours.ns_per_sample,
			r.ours.ns_per_sample / r.ref.ns_per_sample,
			r.ref.peak,
			r.ours.peak,
			r.ref.mismatches,
		)
	}
	if err := os.write_entire_file(path, transmute([]byte)strings.to_string(b)); err != nil {
		fmt.eprintfln("perf: cannot write %q: %v", path, err)
	}
}

parse_perf_args :: proc(args: []string) -> (opt: Perf_Options, ok: bool) {
	opt.block = 128
	opt.repeats = 5
	i := 0
	for i < len(args) {
		flag := args[i]
		if i + 1 >= len(args) {
			return opt, false
		}
		value := args[i + 1]
		switch flag {
		case "--block":
			opt.block = strconv.parse_int(value) or_return
		case "--repeats":
			opt.repeats = strconv.parse_int(value) or_return
		case "--bank":
			append(&opt.banks, value)
		case "--section":
			append(&opt.sections, value)
		case "--csv":
			opt.csv = value
		case "--only":
			opt.only = value
		case:
			return opt, false
		}
		i += 2
	}
	if len(opt.banks) > 0 && len(opt.sections) == 0 {
		append(&opt.sections, "bank")
	}
	return opt, true
}
