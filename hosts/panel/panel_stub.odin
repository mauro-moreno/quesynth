#+build !windows
package panel

// The panel seam on a platform with no web-view backend yet.
//
// panel.odin is the WebView2 editor and is Windows-only; this file is what the
// package presents everywhere else, and it exists for the same reason
// hosts/vst3/editor_other.odin does: to keep the shape of the port visible and
// to let the plugin cores compile and run without knowing which platform they
// are on. The portable halves of the package -- the UI event queue in events.odin
// and the on-disk bank in bank.odin -- are shared and build here unchanged; only
// the editor surface is stubbed.
//
// With no editor, a plugin loads as a working instrument and the host draws its
// own generic parameter view: hosts/clap answers no GUI extension (gui_other.odin)
// and hosts/vst3 returns nil from createView (editor_other.odin). Nothing calls
// the two sends below, because the editor is never opened -- clap guards them
// behind `editor.open`, which stays false -- but they have to exist for the
// shared plugin cores to link.
//
// A Linux editor replaces this with a WebKitGTK panel embedded in the host's X11
// or Wayland window; the protocol in ui/bridge.js needs no change for it, the
// same way it needed none for the WebView2 and WKWebView hosts.

// Only the field the clap core reads: whether an editor is open. It never is on
// this target, so the sends below are reached only after a check that is always
// false -- but the type still has to carry the field.
Panel :: struct {
	open: bool,
}

send_state :: proc(p: ^Panel) {}

send_patch :: proc(p: ^Panel, name: string, index: int, bank: string) {}
