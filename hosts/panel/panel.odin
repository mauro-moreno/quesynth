#+build windows, linux, darwin
package panel

// The panel, hosted in a web view, for any plugin format that wants one.
//
// This started inside hosts/vst3 and moved here when the CLAP build wanted the
// same interface. What differs between the two formats is how a host hands over
// a window and asks for a size -- IPlugView on one side, clap_plugin_gui on the
// other -- and that stays with each host. What does not differ is everything
// else: finding the panel on disk, starting the web view, and the protocol in
// ui/bridge.js.
//
// Sharing it is not tidiness. This project has already been bitten twice by two
// implementations of one protocol drifting apart: the VST3 editor was missing
// the `state` message for a while, so stepping the bank repainted the panel and
// changed no sound, while the browser build -- which had always handled it --
// was fine. A second copy of this for CLAP would be the same wager taken again.
//
// The same goes for platforms. The protocol is protocol.odin, and it is the only
// copy: it builds every message as text and posts none of them. This file is
// what carries them, and the web view underneath it is WebView2 on Windows
// (panel_windows.odin) and WebKitGTK on Linux (panel_linux.odin); each of those
// supplies the Panel type, starting and stopping the view, and `post`, the one
// way a message gets to the page. On macOS, panel_macos.odin supplies the same
// names around a WKWebView, hosted in the NSView the Audio Unit's Cocoa view
// hands over.

// Big enough that no section starts out scrolled.
WIDTH :: i32(1180)
HEIGHT :: i32(720)

// -- messages from the panel -------------------------------------------------

// Everything the interface sends arrives here as one JSON object. What it
// means, and what is said back, is protocol.odin; this carries the answers.
on_message :: proc(user: rawptr, text: string) {
	p := (^Panel)(user)
	if p == nil || p.host.user == nil {
		return
	}
	for reply in handle_message(&p.host, text) {
		post(p, reply)
	}
}

// -- messages to the panel ---------------------------------------------------

// The whole parameter set in one message, which is what the panel asks for when
// it loads.
send_state :: proc(p: ^Panel) {
	if p == nil {
		return
	}
	if message, ok := message_state(&p.host); ok {
		post(p, message)
	}
}

// What the panel is told when it asks for everything, sent unasked: after a
// state load has changed what the instance is playing under an open editor.
// The bank first, for the reason given at `sync`.
send_sync :: proc(p: ^Panel) {
	if p == nil || !p.view.ready {
		return
	}
	for message in sync_replies(&p.host) {
		post(p, message)
	}
}

// Which patch is loaded, by name and by number, so the strip follows a program
// change instead of naming the one before it.
send_selection :: proc(p: ^Panel) {
	if p == nil || !p.view.ready {
		return
	}
	for message in selection_replies(&p.host) {
		post(p, message)
	}
}

// One parameter that changed somewhere else -- an automation lane, or the
// host's own generic panel -- so the web view follows instead of going stale.
send_param :: proc(p: ^Panel, index: int, stored: i32) {
	if p == nil || !p.view.ready {
		return
	}
	post(p, message_param(index, stored))
}
