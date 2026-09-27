#+build darwin
package panel

import "base:runtime"

// The macOS half of the panel, as a seam and not yet a view.
//
// panel.odin compiles on darwin against this file, so the editor, when it comes,
// is one more platform file and not a second copy of the protocol. This file
// owes panel.odin what panel_windows.odin and panel_linux.odin owe it: the Panel
// type, with a `host` and a `view` that knows whether it is `ready`, and `post`,
// the one way a message reaches the page. start, stop, resize and find_content
// carry the names and signatures the other two use, and every field
// hosts/vst3/editor.odin and hosts/clap/gui.odin touch is here, so widening those
// two to darwin needs a platform file of their own and nothing new from this
// package.
//
// Nothing here opens yet. find_content finds nothing and start returns false,
// which is what the other platforms answer when their web-view runtime is
// missing, so a host that asks gets no editor and draws its generic view.
// `ready` never becomes true, so the sends that check it stop early, and `post`
// drops whatever gets past them. And no host asks yet: the Audio Unit, the CLAP
// and the VST3 all still offer no editor on macOS.
//
// The next increment is a WKWebView inside the NSView the host hands over,
// speaking the transport ui/bridge.js already detects as "wkwebview". The page
// sends through window.webkit.messageHandlers.synth, so the view registers a
// script-message handler named `synth` and hands each message body to
// on_message; the other way, `post` evaluates window.synthReceive(<json>) in the
// page, as the WebKitGTK view does. That is not the `quesynth` handler and
// window.synthPost that src/webkitgtk injects: WebKitGTK takes the generic
// transport so bridge.js will not mistake it for a WKWebView.

// What a WKWebView will be configured through: the fields the Windows and Linux
// views are configured through, under the same names.
Web_View :: struct {
	// The NSView the host hands over.
	parent:      rawptr,
	content_dir: string,
	on_message:  proc(user: rawptr, text: string),
	user:        rawptr,
	ready:       bool,
}

Panel :: struct {
	view:   Web_View,
	host:   Host,
	width:  i32,
	height: i32,
	open:   bool,
	ctx:    runtime.Context,
}

// Answering no here is what makes a host decline its editor before it allocates
// anything, the same as a Windows machine with no WebView2. Walking `candidates`
// from the plugin's own directory comes with the view: until there is one,
// nothing found here could be shown.
find_content :: proc(candidates: []string) -> (content: string, ok: bool) {
	return "", false
}

// Wired the way the other platforms wire theirs, then declined, because there is
// no WKWebView to create. Creating one inside `parent`, loading
// content_dir/index.html, registering the `synth` handler and setting
// view.ready once the page has loaded is the next increment.
start :: proc(p: ^Panel, parent: rawptr) -> bool {
	if p == nil || p.open {
		return false
	}
	p.view.parent = parent
	p.view.on_message = on_message
	p.view.user = p
	return false
}

stop :: proc(p: ^Panel) {
	if p == nil || !p.open {
		return
	}
	p.open = false
	p.view.ready = false
	p.view.parent = nil
}

// Remembered, so a host that asks for the size gets back what it set. There is
// no view to move yet.
resize :: proc(p: ^Panel, width, height: i32) {
	if p == nil {
		return
	}
	p.width = width
	p.height = height
}

// Nowhere to send it until there is a page.
@(private)
post :: proc(p: ^Panel, text: string) {}
