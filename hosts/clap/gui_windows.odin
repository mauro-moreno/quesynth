#+build windows
package synth_clap

import "../../src/clap"

GUI_API :: clap.WINDOW_API_WIN32

// Windows already has its message loop. There is nothing to ask the host for,
// and the fd and timer extensions that Linux uses are not offered here.
gui_host_supported :: proc "contextless" (plugin: ^clap.Plugin) -> bool {return true}
gui_prepare_loop :: proc(s: ^Synth) {}

gui_extension :: proc "c" () -> rawptr {
	return &GUI
}

gui_loop_extension :: proc "c" (id: cstring) -> rawptr {
	return nil
}
