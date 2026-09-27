#+build linux
package panel

import "base:runtime"
import "core:c"
import "core:os"
import "core:path/filepath"

import "../../src/webkitgtk"

// The Linux half of the panel. The host hands over an X11 window id, the view
// goes inside it, and everything it says is the protocol in panel.odin -- the
// same one the Windows WebView2 panel speaks. Only the window, the loader and
// the way a message reaches the page differ.

Loop :: webkitgtk.Loop
Fd_Flags :: webkitgtk.Fd_Flags

Panel :: struct {
	view:   webkitgtk.View,
	host:   Host,
	width:  i32,
	height: i32,
	open:   bool,
	ctx:    runtime.Context,
}

// dladdr finds the module an address belongs to, not the executable. The
// executable is the DAW, and its directory is not where this plugin's panel
// lives. The returned name belongs to the loader and is borrowed, not freed.
Dl_Info :: struct {
	filename: cstring,
	base:     rawptr,
	symbol:   cstring,
	address:  rawptr,
}

foreign import libc "system:c"
foreign libc {
	dladdr :: proc "c" (address: rawptr, info: ^Dl_Info) -> c.int ---
}

module_dir :: proc() -> (string, bool) {
	info: Dl_Info
	if dladdr(rawptr(module_dir), &info) == 0 || info.filename == nil {
		return "", false
	}
	return filepath.dir(string(info.filename)), true
}

// Before offering an editor, rather than after opening an empty window. No
// runtime or an incompatible host means the host draws its generic controls.
available :: proc() -> bool {
	return webkitgtk.load()
}

// The same ordered search as on Windows: candidates are relative to the
// plugin, and the first directory that exists wins. A VST3 puts the panel in
// Contents/Resources/ui, a CLAP in Quesynth-ui beside the plugin file.
find_content :: proc(candidates: []string) -> (content: string, ok: bool) {
	dir, found := module_dir()
	if !found || !available() {
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

start :: proc(p: ^Panel, parent: rawptr) -> bool {
	if p == nil || p.open {
		return false
	}
	p.view.parent = c.ulong(uintptr(parent))
	p.view.width = p.width
	p.view.height = p.height
	p.view.start_page = "index.html"
	p.view.on_message = on_message
	p.view.user = p

	if !webkitgtk.create(&p.view) {
		return false
	}
	p.open = true
	return true
}

stop :: proc(p: ^Panel) {
	if p == nil || !p.open {
		return
	}
	webkitgtk.destroy(&p.view)
	p.open = false
	p.view.parent = 0
}

resize :: proc(p: ^Panel, width, height: i32) {
	if p == nil {
		return
	}
	p.width = width
	p.height = height
	if p.open {
		webkitgtk.set_bounds(&p.view, width, height)
	}
}

// Called by the host's fd and timer callbacks, on its GUI thread. There is no
// loop of the plugin's own.
pump :: proc(p: ^Panel) {
	if p != nil && p.open {
		webkitgtk.pump(&p.view)
	}
}

@(private)
post :: proc(p: ^Panel, text: string) {
	webkitgtk.post(&p.view, text)
}
