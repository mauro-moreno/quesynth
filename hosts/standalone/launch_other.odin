#+build !linux
package standalone

import "core:fmt"

// The control transport is Unix-socket only for now, so there is nothing to
// connect to on other targets. The path is still defined so cross-platform code
// can name it; --stop reports honestly rather than pretending.

control_socket_path :: proc() -> string {
	return ""
}

run_tui :: proc(patch_path: string) -> int {
	fmt.eprintfln("error: the interactive UI is not supported on this platform yet")
	return 1
}

run_stop :: proc() -> int {
	fmt.eprintfln("error: --stop is not supported on this platform yet")
	return 1
}
