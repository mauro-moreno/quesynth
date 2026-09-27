#+build !windows
#+build !linux
package panel

// The panel seam on a platform with no web-view backend yet.
//
// Windows hosts WebView2, Linux hosts WebKitGTK; everywhere else the portable
// halves of this package -- the UI event queue and the on-disk bank -- still
// build, and only the editor surface is stubbed. A plugin loads as a working
// instrument and the host draws its own generic parameter view: CLAP answers no
// GUI extension and VST3 returns nil from createView.
//
// Only the field the CLAP core reads needs to exist. It stays false, so the
// sends below are never reached, but they have to exist for the core to link.
Panel :: struct {
	open: bool,
}

send_state :: proc(p: ^Panel) {}

send_patch :: proc(p: ^Panel, name: string, index: int, bank: string) {}
