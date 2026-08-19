package standalone

// The platform seam.
//
// Everything above this file is portable: the engine, the patch loader, the
// self-test and the live wiring in live.odin all speak only to the two structs
// below. Everything below it is one operating system's idea of audio output and
// MIDI input, and lives in its own clearly named file:
//
//   audio_wasapi.odin      Windows, WASAPI shared-mode event-driven render
//   midi_winmm.odin        Windows, multimedia API MIDI input
//   platform_windows.odin  Windows, the constructors and the Ctrl-C handler
//   platform_other.odin    every other target: honest "not implemented" stubs
//
// An iOS shell adds audio_audiounit.odin and midi_coremidi.odin beside those
// and implements the same two structs; nothing in live.odin has to change. That
// is the whole reason the interface is a struct of procedure pointers rather
// than a direct call into WASAPI.

// What the device actually decided to run at. The shell adapts to the device
// rather than demanding a rate, because a shared-mode endpoint does not
// negotiate: it states its mix format and the client either matches it or is
// resampled behind its back.
Audio_Format :: struct {
	sample_rate: f32,
	channels:    int,
}

// Fill `frames` frames of interleaved float output.
//
// Called on the audio thread. The contract for every implementation of this
// callback, and the reason the engine was written the way it was: no
// allocation, no locks, no file access, no string formatting. It is "c" calling
// convention because the thread it runs on is created by the platform, not by
// the Odin runtime, so it cannot assume a context exists.
Audio_Render_Proc :: proc "c" (user: rawptr, out: [^]f32, frames: int, channels: int)

Audio_Backend :: struct {
	// Opaque per-implementation state, owned by the implementation.
	impl:       rawptr,

	// Valid once `open` has returned true.
	format:     Audio_Format,
	// The largest block `render` can ever be asked for. The shell sizes its
	// scratch buffers from this, once, before the stream starts, so the audio
	// thread never needs to allocate.
	max_frames: int,
	// Human-readable endpoint name, for the line the live mode prints.
	name:       string,

	// Acquire the device and report its format. Opens no thread and produces
	// no sound: splitting this from `start` is what lets the caller size its
	// buffers to a known maximum before any audio callback can run.
	open:       proc(b: ^Audio_Backend) -> bool,
	// Begin streaming. `render` is called repeatedly until `stop`.
	start:      proc(b: ^Audio_Backend, render: Audio_Render_Proc, user: rawptr) -> bool,
	// Stop streaming and join the audio thread. After this returns, `render`
	// is guaranteed not to be running or to run again.
	stop:       proc(b: ^Audio_Backend),
	// Release the device. Safe to call whether or not `open` succeeded.
	destroy:    proc(b: ^Audio_Backend),
}

Midi_Input :: struct {
	impl:    rawptr,

	// Number of inputs actually opened, and their names, valid after `open`.
	// Opening zero devices is not a failure: a machine with no MIDI hardware
	// still runs the synthesiser, it just has nothing to play it with.
	count:   int,
	names:   []string,

	// Open every available input and push what arrives into `queue`.
	open:    proc(m: ^Midi_Input, queue: ^Midi_Queue) -> bool,
	// Stop and close every input. After this returns, nothing further is
	// pushed into the queue.
	close:   proc(m: ^Midi_Input),
}
