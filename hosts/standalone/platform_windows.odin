#+build windows
package standalone

import "base:intrinsics"
import win "core:sys/windows"

// Windows wiring for the platform seam: which backend to build, and how the
// process is asked to stop.
//
// A port adds the same four procedures in a platform_ios.odin or
// platform_android.odin beside this file. live.odin calls them by name and
// never learns which one it got.

audio_backend_create :: proc() -> (Audio_Backend, bool) {
	return wasapi_backend()
}

midi_input_create :: proc() -> (Midi_Input, bool) {
	return winmm_midi_input()
}

// Set by the console handler, read by the main loop.
//
// The handler runs on a thread the operating system injects into the process,
// so it is genuinely concurrent with the main thread and the flag is atomic for
// that reason rather than as a formality.
@(private = "file")
g_shutdown: b32

install_shutdown_handler :: proc() {
	win.SetConsoleCtrlHandler(console_handler, true)
}

// The handler does one thing: raise the flag.
//
// Everything the shutdown actually involves -- stopping the stream, joining the
// audio thread, closing the MIDI devices, freeing the engine -- happens on the
// main thread in run_live. That is deliberate. This routine runs on an injected
// thread while the rest of the process keeps going, so tearing COM objects down
// here would race the render thread that is still using them. Returning true
// tells Windows the signal was handled and suppresses the default kill, which
// is what gives the main thread its chance to unwind cleanly.
@(private = "file")
console_handler :: proc "system" (control_type: win.DWORD) -> win.BOOL {
	switch control_type {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT, win.CTRL_CLOSE_EVENT:
		intrinsics.atomic_store_explicit(&g_shutdown, true, .Release)
		return true
	}
	return false
}

shutdown_requested :: proc() -> bool {
	return bool(intrinsics.atomic_load_explicit(&g_shutdown, .Acquire))
}

sleep_ms :: proc(milliseconds: int) {
	win.Sleep(win.DWORD(milliseconds))
}
