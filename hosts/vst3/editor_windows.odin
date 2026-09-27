#+build windows
package synth_vst3

import "../../src/vst3"

// The event-loop seam on Windows: there is none to bridge.
//
// A WebView2 control is a child window that runs on the host's own message loop,
// so nothing has to be registered and nothing has to be pumped. This file is the
// Windows half of the seam editor.odin calls into; editor_linux.odin is the other
// half, where the host lends its run loop because Linux has none to assume.
//
// EDITOR_PLATFORM_TYPE is the platform-type string the host hands to attached()
// and the one this view answers to in isPlatformTypeSupported.

EDITOR_PLATFORM_TYPE :: vst3.PLATFORM_TYPE_HWND

Editor_Loop :: struct {}

editor_loop_attach :: proc(ed: ^Editor) -> bool {
	return true
}

editor_loop_detach :: proc(ed: ^Editor) {
}
