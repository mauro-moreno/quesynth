#+build linux
package standalone

import "base:intrinsics"
import "core:sys/posix"
import "core:time"

// Linux wiring for the platform seam: which backend to build, and how the
// process is asked to stop.
//
// The Linux counterpart of platform_windows.odin. live.odin calls these four
// procedures by name and never learns which platform answered them; the audio
// and MIDI halves are in audio_alsa.odin and midi_alsa.odin.

audio_backend_create :: proc() -> (Audio_Backend, bool) {
	return alsa_backend()
}

midi_input_create :: proc() -> (Midi_Input, bool) {
	return alsa_midi_input()
}

// Set by the signal handler, read by the main loop.
//
// The handler runs asynchronously with respect to the main thread, so the flag
// is atomic for that reason rather than as a formality.
@(private = "file")
g_shutdown: b32

install_shutdown_handler :: proc() {
	posix.signal(.SIGINT, signal_handler)
	posix.signal(.SIGTERM, signal_handler)
}

// The handler does one thing: raise the flag.
//
// Everything the shutdown actually involves -- stopping the stream, joining the
// audio thread, closing the MIDI devices, freeing the engine -- happens on the
// main thread in run_daemon, for the same reason the Windows console handler defers
// it there: this routine runs asynchronously while the render thread is still
// using those resources, so tearing them down here would race it. A signal
// handler may safely touch almost nothing; an atomic store is one of the few
// things it may.
@(private = "file")
signal_handler :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store_explicit(&g_shutdown, true, .Release)
}

shutdown_requested :: proc() -> bool {
	return bool(intrinsics.atomic_load_explicit(&g_shutdown, .Acquire))
}

// Set from the control server's daemon.shutdown handler, off the audio thread.
// It raises the same flag the signal handler does, so `quesynth --stop` unwinds
// through exactly the path Ctrl-C does.
request_shutdown :: proc() {
	intrinsics.atomic_store_explicit(&g_shutdown, true, .Release)
}

sleep_ms :: proc(milliseconds: int) {
	time.sleep(time.Duration(milliseconds) * time.Millisecond)
}
