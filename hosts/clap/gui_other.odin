#+build !windows
#+build !linux
package synth_clap

// No web-view backend on this platform yet. Answering no GUI extension leaves
// a working instrument and the host's generic parameter view, not an editor
// that cannot open. plugin.odin calls these seams without knowing the platform.
gui_extension :: proc "c" () -> rawptr {
	return nil
}

gui_loop_extension :: proc "c" (id: cstring) -> rawptr {
	return nil
}
