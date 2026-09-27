#+build windows
package panel

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

import "../../src/webview2"

// The Windows half of the panel: the web view is WebView2, inside the HWND the
// host hands over. The protocol it speaks is in panel.odin and shared with the
// Linux half in panel_linux.odin.

// The folder in ui/ is mapped to this name so the page loads over https with a
// real origin. A `.invalid` domain can never resolve on the public internet,
// which is the point: nothing here should ever reach the network.
CONTENT_HOST :: "synth.invalid"
START_URL :: "https://synth.invalid/index.html"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: win.wstring, phModule: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: win.DWORD(0x00000004)
GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: win.DWORD(0x00000002)

Panel :: struct {
	view:   webview2.View,
	host:   Host,
	width:  i32,
	height: i32,
	open:   bool,
	ctx:    runtime.Context,
}

// -- where the plugin lives --------------------------------------------------

// The directory holding this DLL.
//
// Found from the address of a procedure in this module rather than from the
// process, because the process is the DAW and its directory is not ours. This
// is what makes a bundle relocatable: nothing is looked up by absolute path or
// by an environment variable a host may not have set.
//
// The result borrows from the temporary allocator and must not be freed.
// `filepath.dir` does not allocate -- it returns a slice of the path handed to
// it -- so deleting the result would free a pointer into the temp arena through
// the heap allocator, which is a crash and not a leak.
module_dir :: proc() -> (string, bool) {
	module: win.HMODULE
	flags := GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT
	if !GetModuleHandleExW(flags, win.wstring(rawptr(module_dir)), &module) {
		return "", false
	}

	buffer: [win.MAX_PATH_WIDE]u16
	length := win.GetModuleFileNameW(module, &buffer[0], win.MAX_PATH_WIDE)
	if length == 0 || int(length) >= len(buffer) {
		return "", false
	}

	path, err := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length), context.temp_allocator)
	if err != nil {
		return "", false
	}
	return filepath.dir(path), true
}

// WebView2 needs somewhere writable of its own. Under the user's local app data
// rather than beside the plugin: a bundle in Program Files is not writable, and
// a browser profile is per-user anyway.
user_data_dir :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", allocator)
	if local == "" {
		return strings.clone(".", allocator)
	}
	joined, err := filepath.join({local, "Quesynth", "WebView2"}, allocator)
	if err != nil {
		return strings.clone(".", allocator)
	}
	return joined
}

// Find the loader and the panel, wherever this format puts them.
//
// `candidates` are tried in order, relative to the module's own directory, and
// the first that exists wins. The two formats lay themselves out differently --
// a VST3 is a bundle with Contents/Resources, a CLAP on Windows is one file with
// a folder beside it -- and neither should have to know about the other's shape.
//
// The loader is looked for first and beside the binary in both. Loading it
// before anything is allocated means a machine with no WebView2 costs nothing
// and simply has no editor, which is the documented behaviour rather than a
// failure.
find_content :: proc(candidates: []string) -> (content: string, ok: bool) {
	dir, found := module_dir()
	if !found {
		return "", false
	}

	loader, loader_err := filepath.join({dir, "WebView2Loader.dll"}, context.temp_allocator)
	if loader_err != nil || !webview2.load(loader) {
		return "", false
	}

	for candidate in candidates {
		path, err := filepath.join({dir, candidate})
		if err != nil {
			continue
		}
		if os.exists(path) {
			return path, true
		}
		delete(path)
	}
	return "", false
}

// -- opening and closing -----------------------------------------------------

// Start the web view inside a window the host owns.
start :: proc(p: ^Panel, parent: rawptr) -> bool {
	if p == nil || p.open {
		return false
	}
	profile := user_data_dir(context.temp_allocator)

	p.view.parent = win.HWND(parent)
	p.view.bounds = win.RECT{0, 0, p.width, p.height}
	p.view.host_name = CONTENT_HOST
	p.view.start_url = START_URL
	p.view.on_message = on_message
	p.view.user = rawptr(p)

	if !webview2.create(&p.view, profile) {
		// No runtime, or the loader refused. The host keeps its window; it just
		// stays empty. Said plainly rather than pretended away.
		return false
	}
	p.open = true
	return true
}

stop :: proc(p: ^Panel) {
	if p == nil || !p.open {
		return
	}
	webview2.destroy(&p.view)
	p.open = false
	p.view.parent = nil
}

resize :: proc(p: ^Panel, width, height: i32) {
	if p == nil {
		return
	}
	p.width = width
	p.height = height
	if p.open {
		webview2.set_bounds(&p.view, win.RECT{0, 0, width, height})
	}
}

// One JSON message to the panel, through WebView2's own message channel.
@(private)
post :: proc(p: ^Panel, text: string) {
	webview2.post(&p.view, text)
}
