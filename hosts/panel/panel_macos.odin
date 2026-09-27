#+build darwin
package panel

import "base:runtime"
import "core:os"
import "core:path/filepath"

import "../../src/webkit"

// The macOS half of the panel. The host hands over an NSView, a WKWebView goes
// inside it, and everything it says is the protocol in panel.odin -- the same
// one the Windows WebView2 and Linux WebKitGTK panels speak. Only the window,
// the loader and the way a message reaches the page differ: the page posts
// through window.webkit.messageHandlers.synth, which ui/bridge.js detects as
// "wkwebview", and `post` evaluates window.synthReceive(<json>) in the page.
//
// Main thread only, as AppKit is. There is nothing to pump: WebKit runs on the
// host's own run loop, and a message posted from another thread is dropped
// rather than marshalled, so a host brings its off-thread changes to the main
// thread itself.

Panel :: struct {
	view:   webkit.View,
	host:   Host,
	width:  i32,
	height: i32,
	open:   bool,
	ctx:    runtime.Context,
}

// dladdr finds the image an address belongs to, not the executable. The
// executable is the DAW, and its directory is not where this plugin's panel
// lives. The returned path belongs to the loader and is borrowed, not freed.
module_dir :: proc() -> (string, bool) {
	path, _, found := webkit.image()
	if !found {
		return "", false
	}
	return filepath.dir(string(path)), true
}

// Before offering an editor, rather than after opening an empty window. No
// WebKit in the process means the host draws its generic controls.
available :: proc() -> bool {
	return webkit.available()
}

// The same ordered search as on Windows and Linux: candidates are relative to
// the plugin binary, and the first directory that exists wins. A VST3 and an
// Audio Unit both put the panel in Contents/Resources/ui, reached from
// Contents/MacOS.
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
	p.view.parent = parent
	p.view.width = p.width
	p.view.height = p.height
	p.view.start_page = "index.html"
	p.view.on_message = on_message
	p.view.user = p

	if !webkit.create(&p.view) {
		return false
	}
	p.open = true
	return true
}

stop :: proc(p: ^Panel) {
	if p == nil || !p.open {
		return
	}
	webkit.destroy(&p.view)
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
		webkit.set_bounds(&p.view, width, height)
	}
}

@(private)
post :: proc(p: ^Panel, text: string) {
	webkit.post(&p.view, text)
}
