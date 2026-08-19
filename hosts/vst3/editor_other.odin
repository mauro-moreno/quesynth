#+build !windows
package synth_vst3

// The editor seam on a platform that has no web view backend yet.
//
// This file exists for the same reason hosts/standalone/platform_other.odin
// does: to keep the shape of the port visible, and to keep the rest of the
// plugin from having to know which platform it is on. plugin.odin calls
// `make_editor` and the two send procedures by name and never learns that here
// they do nothing.
//
// A macOS port replaces this with an editor_darwin.odin hosting a WKWebView in
// the NSView the host passes to `attached`. The interface in ui/ needs no
// change for it: ui/bridge.js already speaks to `window.webkit.messageHandlers`.

Editor :: struct {}

// No editor, so `createView` returns nil and the host draws its generic panel
// from `getParameterInfo`. That is a working instrument, which is the point of
// answering honestly rather than failing to load.
make_editor :: proc(p: ^Plugin) -> ^Editor {
	return nil
}

editor_send_state :: proc(ed: ^Editor) {}

editor_send_param :: proc(ed: ^Editor, index: int, stored: i32) {}
