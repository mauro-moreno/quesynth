package s1probe

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// Running each patch in a child process, so the reference cannot take the
// harness down with it.
//
// Five of the 128 factory patches segfault *inside* `Synth1 VST64.dll` during
// `processReplacing`, and it is the arpeggiator that does it: switching the
// arpeggiator off in one of them makes it render, and switching it on in a
// patch that has never crashed makes that one crash instead. The fault is in a
// twenty-year-old binary this project cannot patch and would not want to.
//
// A crash inside a loaded DLL takes the whole process with it, which used to
// mean a bank run stopped dead at the first bad patch and everything after it
// went unmeasured. `--skip` and `--offset` existed to step over the ones that
// were already known, which only works once somebody has found them the hard
// way and remembered to pass the flag.
//
// So the reference render happens somewhere expendable. The parent spawns
// itself once per patch, the child does exactly what a single-patch run has
// always done -- including printing its own row, since it inherits the handles
// -- and the parent notices the exit code. A patch that kills its child is
// reported and the run carries on.

// Where this executable is, so a child is the same build as its parent rather
// than whatever happens to be on the PATH.
self_path :: proc() -> (string, bool) {
	buffer: [win.MAX_PATH_WIDE]u16
	length := win.GetModuleFileNameW(nil, &buffer[0], win.MAX_PATH_WIDE)
	if length == 0 || int(length) >= len(buffer) {
		return "", false
	}
	path, err := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length), context.allocator)
	if err != nil {
		return "", false
	}
	return path, true
}

// Anything with a space in it has to survive the child's own command-line
// parsing, and a patch bank under "D:\VST\VST 3" is exactly that.
quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	strings.write_string(b, s)
	strings.write_string(b, "\" ")
}

// Run one patch in a child and return its exit code. 0 is a clean run;
// anything else is the child dying, and 0xC0000005 is the access violation
// this exists for.
run_isolated :: proc(exe, dll, patch_path: string, opt: Compare_Options) -> (u32, bool) {
	b := strings.builder_make(context.temp_allocator)
	quote(&b, exe)
	strings.write_string(&b, "compare ")
	quote(&b, dll)
	quote(&b, patch_path)

	// Everything the parent was given, minus the flags that only make sense
	// once: --offset and --limit selected this patch already, and --isolate
	// itself must not be passed on or the child would spawn a grandchild.
	if opt.csv != "" {
		strings.write_string(&b, "--csv ")
		quote(&b, opt.csv)
	}
	if opt.wav_dir != "" {
		strings.write_string(&b, "--wav ")
		quote(&b, opt.wav_dir)
	}
	if opt.note != COMPARE_NOTE_DEFAULT {
		fmt.sbprintf(&b, "--note %v ", opt.note)
	}
	if opt.block != 0 {
		fmt.sbprintf(&b, "--block %v ", opt.block)
	}
	if opt.no_floor {
		strings.write_string(&b, "--no-floor ")
	}
	if opt.verbose {
		strings.write_string(&b, "--verbose ")
	}
	if opt.self {
		strings.write_string(&b, "--self ")
	}

	strings.write_string(&b, "--child ")

	return spawn_and_wait(strings.to_string(b))
}

// Run a command line to completion and return its exit code.
//
// Handles are inherited, so a child's rows land in the parent's output in the
// order they are produced and the table reads as one run.
spawn_and_wait :: proc(command: string) -> (u32, bool) {
	wide := win.utf8_to_wstring(command)

	startup: win.STARTUPINFOW
	startup.cb = size_of(win.STARTUPINFOW)
	info: win.PROCESS_INFORMATION

	created := win.CreateProcessW(nil, wide, nil, nil, true, 0, nil, nil, &startup, &info)
	if !created {
		return 0, false
	}
	defer win.CloseHandle(info.hProcess)
	defer win.CloseHandle(info.hThread)

	win.WaitForSingleObject(info.hProcess, win.INFINITE)
	code: win.DWORD
	if !win.GetExitCodeProcess(info.hProcess, &code) {
		return 0, false
	}
	return u32(code), true
}

// The exit code Windows reports for the access violation these patches cause.
STATUS_ACCESS_VIOLATION :: u32(0xC0000005)

exit_reason :: proc(code: u32) -> string {
	switch code {
	case STATUS_ACCESS_VIOLATION:
		return "segfault inside the reference"
	case 0:
		return "ok"
	}
	return fmt.tprintf("exit %v", code)
}
