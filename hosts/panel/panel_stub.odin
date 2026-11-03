#+build !windows
#+build !linux
#+build !darwin
package panel

// The panel seam on a platform with no web-view backend yet.
//
// Windows hosts WebView2, Linux hosts WebKitGTK, and macOS has the seam in
// panel_macos.odin; everywhere else the portable halves of this package -- the
// UI event queue, the on-disk bank and the protocol -- still build, and only
// the editor surface is stubbed. A plugin loads as a working instrument and the
// host draws its own generic parameter view: CLAP answers no GUI extension and
// VST3 returns nil from createView.
//
// Only the field the CLAP core reads needs to exist. It stays false, so the
// sends below are never reached, but they have to exist for the core to link.
Panel :: struct {
	open: bool,
}

send_state :: proc(p: ^Panel) {}

send_sync :: proc(p: ^Panel) {}

send_selection :: proc(p: ^Panel) {}
