#+build !windows
package standalone

import "core:time"

// The platform seam on a target that has no backend yet.
//
// This file exists so the shape of the port is visible: an iOS shell replaces
// it with an audio_audiounit.odin and a midi_coremidi.odin, an Android shell
// with an AAudio pair, and neither has to touch live.odin, selftest.odin or
// anything under src/.
//
// The self-test mode is fully portable and keeps working here -- it opens no
// device by design -- so a build on such a target is still useful for checking
// that the engine renders. Only live mode is unavailable, and it says so rather
// than pretending to start.

audio_backend_create :: proc() -> (Audio_Backend, bool) {
	return {}, false
}

midi_input_create :: proc() -> (Midi_Input, bool) {
	return {}, false
}

install_shutdown_handler :: proc() {
}

// Live mode never reaches its wait loop on this target, because
// audio_backend_create fails first.
shutdown_requested :: proc() -> bool {
	return true
}

sleep_ms :: proc(milliseconds: int) {
	time.sleep(time.Duration(milliseconds) * time.Millisecond)
}
