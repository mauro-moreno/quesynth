package profile

// A sampling profiler for the engine on Windows.
//
// A second thread suspends the rendering thread every few tens of microseconds,
// reads its instruction pointer, and resumes it. The addresses are resolved to
// source lines through dbghelp, so the report says which lines of the engine the
// time went to even where the optimiser has inlined a procedure into its caller.
//
//   odin build tools/profile -o:speed -debug -out:build/profile.exe
//   build/profile.exe default 8          eight notes on the default patch
//   build/profile.exe path/to/x.sy1 8    eight notes on one patch
//   build/profile.exe digest <dir>...    hash the engine's exact output for every patch
//
// The report attributes samples to source lines through inlined frames. Samples
// inside libm are credited to the first engine frame on the stack, which inlining
// makes coarse, and the sampler over-represents them: judge a change by timing two
// builds against each other (tools/bench), not by this percentage.
//
// Optional: --seconds <n>, --top <n>, --unison <n>, --bare.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

import "../../src/engine"
import "../../src/patch"

foreign import kernel32 "system:Kernel32.lib"
foreign import dbghelp "system:Dbghelp.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	OpenThread :: proc(access: u32, inherit: win.BOOL, id: u32) -> win.HANDLE ---
	SuspendThread :: proc(thread: win.HANDLE) -> u32 ---
	ResumeThread :: proc(thread: win.HANDLE) -> u32 ---
	GetThreadContext :: proc(thread: win.HANDLE, ctx: ^win.CONTEXT) -> win.BOOL ---
}

Symbol_Info :: struct {
	size_of_struct: u32,
	type_index:     u32,
	reserved:       [2]u64,
	index:          u32,
	size:           u32,
	mod_base:       u64,
	flags:          u32,
	value:          u64,
	address:        u64,
	register:       u32,
	scope:          u32,
	tag:            u32,
	name_len:       u32,
	max_name_len:   u32,
	name:           [512]u8,
}

Line_Info :: struct {
	size_of_struct: u32,
	key:            rawptr,
	line_number:    u32,
	file_name:      cstring,
	address:        u64,
}

@(default_calling_convention = "system")
foreign dbghelp {
	SymInitialize :: proc(process: win.HANDLE, search_path: cstring, invade: win.BOOL) -> win.BOOL ---
	SymSetOptions :: proc(options: u32) -> u32 ---
	SymFromAddr :: proc(process: win.HANDLE, address: u64, displacement: ^u64, symbol: ^Symbol_Info) -> win.BOOL ---
	SymGetLineFromAddr64 :: proc(process: win.HANDLE, address: u64, displacement: ^u32, line: ^Line_Info) -> win.BOOL ---
	SymAddrIncludeInlineTrace :: proc(process: win.HANDLE, address: u64) -> u32 ---
	SymQueryInlineTrace :: proc(process: win.HANDLE, start_address: u64, start_context: u32, start_return: u64, current_address: u64, current_context: ^u32, current_frame_index: ^u32) -> win.BOOL ---
	SymGetLineFromInlineContext :: proc(process: win.HANDLE, address: u64, inline_context: u32, mod_base: u64, displacement: ^u32, line: ^Line_Info) -> win.BOOL ---
}

SYMOPT_LOAD_LINES :: u32(0x10)
SYMOPT_UNDNAME :: u32(0x2)
THREAD_ALL_ACCESS :: u32(0x1FFFFF)
CONTEXT_CONTROL :: u32(0x100001)

SAMPLE_RATE :: f32(48000)
BLOCK :: 128
NOTES := [16]int{48, 52, 55, 59, 62, 65, 69, 72, 40, 44, 47, 51, 54, 57, 61, 64}

Sampler :: struct {
	target:  win.HANDLE,
	stop:    bool,
	samples: [dynamic]u64,
	stacks:  [dynamic][STACK_WORDS]u64,
}

STACK_WORDS :: 40

sample_loop :: proc(t: ^thread.Thread) {
	s := cast(^Sampler)t.data
	ctx: win.CONTEXT
	ctx.ContextFlags = CONTEXT_CONTROL
	for !sync.atomic_load(&s.stop) {
		if SuspendThread(s.target) != ~u32(0) {
			if GetThreadContext(s.target, &ctx) {
				append(&s.samples, u64(ctx.Rip))
				words: [STACK_WORDS]u64
				stack := cast([^]u64)uintptr(ctx.Rsp)
				for i in 0 ..< STACK_WORDS {
					words[i] = stack[i]
				}
				append(&s.stacks, words)
			}
			ResumeThread(s.target)
		}
		start := time.tick_now()
		for time.duration_microseconds(time.tick_since(start)) < 50 {}
	}
}

// Every patch in each directory rendered through a chord with a note-off partway,
// and the exact bits of the output hashed. Two builds that print the same digests
// produced the same samples, which is the claim an optimisation has to make.
//
//   build/profile.exe digest <dir>... > digests.txt
VARIANTS := [][][2]int {
	{},
	{{73, 1}, {93, 3}, {76, 40}, {95, 60}},
	{{57, 1}, {41, 1}, {44, 90}, {43, 80}},
	{{57, 1}, {41, 2}, {44, 90}, {43, 80}},
	{{57, 1}, {41, 3}, {44, 90}, {43, 80}},
	{{57, 1}, {41, 4}, {44, 90}, {43, 80}},
	{{57, 1}, {41, 6}, {44, 90}, {43, 80}},
	{{38, 1}, {39, 80}, {74, 1}},
	{{10, 1}, {11, 100}, {71, 0}, {45, 40}, {6, 1}},
	{{14, 3}, {23, 60}, {20, 100}},
	{{14, 4}, {20, 90}, {7, 1}},
}

digest :: proc(dirs: []string) {
	left := make([]f32, BLOCK)
	right := make([]f32, BLOCK)
	total_hash: u64 = 14695981039346656037
	count := 0
	for dir in dirs {
		entries, err := os.read_directory_by_path(dir, -1, context.allocator)
		if err != nil {
			continue
		}
		for info in entries {
			if !strings.has_suffix(strings.to_lower(info.name), ".sy1") {
				continue
			}
			data, read_err := os.read_entire_file(info.fullpath, context.allocator)
			if read_err != nil {
				continue
			}
			base, parse_err := patch.parse_sy1(data)
			if parse_err != .None {
				continue
			}
			for variant in 0 ..< len(VARIANTS) {
			parsed := base
			for override in VARIANTS[variant] {
				parsed.values[override[0]] = override[1]
				parsed.present[override[0]] = true
			}
			eng: engine.Engine
			engine.engine_load_patch(&eng, parsed, SAMPLE_RATE)
			engine.engine_note_on(&eng, 48, 100.0 / 127.0)
			engine.engine_note_on(&eng, 55, 80.0 / 127.0)
			engine.engine_note_on(&eng, 64, 120.0 / 127.0)
			hash: u64 = 14695981039346656037
			for block in 0 ..< 400 {
				if block == 250 {
					engine.engine_note_off(&eng, 55)
				}
				if block == 300 {
					engine.engine_note_off(&eng, 48)
					engine.engine_note_off(&eng, 64)
				}
				engine.engine_process(&eng, left, right)
				for i in 0 ..< BLOCK {
					hash = (hash ~ u64(transmute(u32)left[i])) * 1099511628211
					hash = (hash ~ u64(transmute(u32)right[i])) * 1099511628211
				}
			}
			engine.engine_destroy(&eng)
			fmt.printfln("%v/%v v%v %016x", dir, info.name, variant, hash)
			total_hash = (total_hash ~ hash) * 1099511628211
			count += 1
			}
			delete(data)
		}
	}
	fmt.printfln("TOTAL %v patches %016x", count, total_hash)
}

main :: proc() {
	args := os.args[1:]
	if len(args) >= 2 && args[0] == "digest" {
		digest(args[1:])
		return
	}
	if len(args) < 2 {
		fmt.eprintln("usage: profile <default|patch.sy1> <notes> [--seconds n] [--top n] [--unison n] [--bare]")
		os.exit(2)
	}
	notes, _ := strconv.parse_int(args[1])
	seconds := 8.0
	top := 40
	unison := 0
	warmup := 100
	bare := false
	for i := 2; i < len(args); i += 1 {
		switch args[i] {
		case "--seconds":
			i += 1
			seconds, _ = strconv.parse_f64(args[i])
		case "--top":
			i += 1
			top, _ = strconv.parse_int(args[i])
		case "--unison":
			i += 1
			unison, _ = strconv.parse_int(args[i])
		case "--bare":
			bare = true
		case "--warmup":
			i += 1
			seconds_warm, _ := strconv.parse_f64(args[i])
			warmup = int(seconds_warm * f64(SAMPLE_RATE) / BLOCK)
		}
	}

	p: patch.Patch
	if args[0] == "default" {
		for i in 0 ..< patch.PARAMETER_COUNT {
			p.values[i] = patch.PARAMETERS[i].default
			p.present[i] = true
		}
	} else {
		data, err := os.read_entire_file(args[0], context.allocator)
		if err != nil {
			fmt.eprintfln("cannot read %v", args[0])
			os.exit(1)
		}
		parsed, perr := patch.parse_sy1(data)
		if perr != .None {
			fmt.eprintfln("cannot parse %v", args[0])
			os.exit(1)
		}
		p = parsed
	}
	if bare {
		for index in ([?]int{65, 66, 57, 58}) {
			p.values[index] = 0
		}
	}
	if unison > 1 {
		p.values[73] = 1
		p.values[93] = unison
	}

	process := win.GetCurrentProcess()
	SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME)
	SymInitialize(process, nil, true)

	eng: engine.Engine
	engine.engine_load_patch(&eng, p, SAMPLE_RATE)
	for i in 0 ..< notes {
		engine.engine_note_on(&eng, NOTES[i % len(NOTES)], 100.0 / 127.0)
	}
	left := make([]f32, BLOCK)
	right := make([]f32, BLOCK)
	for _ in 0 ..< warmup {
		engine.engine_process(&eng, left, right)
	}

	sampler := Sampler {
		target  = OpenThread(THREAD_ALL_ACCESS, false, win.GetCurrentThreadId()),
		samples = make([dynamic]u64, 0, 1 << 20),
		stacks  = make([dynamic][STACK_WORDS]u64, 0, 1 << 20),
	}
	sampling := thread.create(sample_loop)
	sampling.data = &sampler
	thread.start(sampling)

	started := time.tick_now()
	for time.duration_seconds(time.tick_since(started)) < seconds {
		engine.engine_process(&eng, left, right)
	}
	sync.atomic_store(&sampler.stop, true)
	thread.join(sampling)

	by_caller := make(map[string]int)
	by_line := make(map[string]int)
	by_function := make(map[string]int)
	for address, sample_index in sampler.samples {
		symbol := Symbol_Info{}
		symbol.size_of_struct = 88
		symbol.max_name_len = 511
		displacement: u64
		function := "?"
		if SymFromAddr(process, address, &displacement, &symbol) {
			function = strings.clone(string(cstring(raw_data(symbol.name[:]))))
		}
		by_function[function] += 1
		if !strings.has_prefix(function, "engine::") && !strings.has_prefix(function, "dsp::") && function != "?" {
			caller := "(no engine frame on stack)"
			for word in sampler.stacks[sample_index] {
				candidate := Symbol_Info{}
				candidate.size_of_struct = 88
				candidate.max_name_len = 511
				candidate_displacement: u64
				if word > 0x1000 && SymFromAddr(process, word - 1, &candidate_displacement, &candidate) {
					name := string(cstring(raw_data(candidate.name[:])))
					if strings.has_prefix(name, "engine::") || strings.has_prefix(name, "dsp::") {
						line := Line_Info{}
						line.size_of_struct = size_of(Line_Info)
						line_displacement: u32
						where_ := name
						inline_context, frame_index: u32
						found := false
						if SymAddrIncludeInlineTrace(process, word - 1) > 0 &&
						   SymQueryInlineTrace(process, word - 1, 0, word - 1, word - 1, &inline_context, &frame_index) {
							found = bool(SymGetLineFromInlineContext(process, word - 1, inline_context, 0, &line_displacement, &line))
						}
						if !found {
							found = bool(SymGetLineFromAddr64(process, word - 1, &line_displacement, &line))
						}
						if found {
							file := string(line.file_name)
							if cut := strings.last_index_any(file, "/\\"); cut >= 0 {
								file = file[cut + 1:]
							}
							where_ = fmt.aprintf("%v:%v", file, line.line_number)
						}
						caller = fmt.aprintf("%v <- %v", function, where_)
						break
					}
				}
			}
			by_caller[caller] += 1
		}

		line := Line_Info{}
		line.size_of_struct = size_of(Line_Info)
		line_displacement: u32
		location := "?"
		found := false
		if SymAddrIncludeInlineTrace(process, address) > 0 {
			inline_context, frame_index: u32
			if SymQueryInlineTrace(process, address, 0, address, address, &inline_context, &frame_index) {
				found = bool(SymGetLineFromInlineContext(process, address, inline_context, 0, &line_displacement, &line))
			}
		}
		if !found {
			found = bool(SymGetLineFromAddr64(process, address, &line_displacement, &line))
		}
		if found {
			file := string(line.file_name)
			if cut := strings.last_index_any(file, "/\\"); cut >= 0 {
				file = file[cut + 1:]
			}
			location = fmt.aprintf("%v:%v", file, line.line_number)
		}
		by_line[location] += 1
	}

	total := f64(len(sampler.samples))
	fmt.printfln("%v samples, %v notes, %v", len(sampler.samples), notes, args[0])
	print_top :: proc(title: string, counts: map[string]int, total: f64, top: int) {
		Entry :: struct {
			name:  string,
			count: int,
		}
		entries := make([dynamic]Entry)
		for name, count in counts {
			append(&entries, Entry{name, count})
		}
		slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.count > b.count})
		fmt.printfln("\n%v", title)
		for e in entries[:min(top, len(entries))] {
			fmt.printfln("  %5.1f%%  %v", 100.0 * f64(e.count) / total, e.name)
		}
	}
	by_file := make(map[string]int)
	for location, count in by_line {
		file := location
		if colon := strings.last_index_byte(location, ':'); colon >= 0 {
			file = location[:colon]
		}
		by_file[file] += count
	}
	print_top("library samples by caller", by_caller, total, 30)
	print_top("by file", by_file, total, 20)
	print_top("by function", by_function, total, 25)
	print_top("by source line", by_line, total, top)
}
