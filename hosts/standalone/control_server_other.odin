#+build !linux
package standalone

// The control server is Unix-socket only for now, so on every other target it
// is a no-op: the daemon still runs and makes sound, it just offers no control
// surface. A Windows named-pipe or a portable transport can implement these two
// procedures later without the daemon changing.

Control_Server :: struct {
	ctx:  Control_Context,
	path: string,
}

control_server_start :: proc(cs: ^Control_Server) -> bool {
	return false
}

control_server_stop :: proc(cs: ^Control_Server) {
}
