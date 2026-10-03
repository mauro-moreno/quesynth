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
//   audio_alsa.odin        Linux, ALSA PCM render on a dedicated thread
//   midi_alsa.odin         Linux, ALSA raw-MIDI input
//   platform_linux.odin    Linux, the constructors and the signal handler
//   platform_other.odin    every remaining target: honest "not implemented" stubs
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

// One input the platform reports, open or not. `id` is what midi.select takes:
// a single token -- no spaces, no line breaks, never "all" or "none" -- that
// the backend can find the same device by again. `name` is free text, and two
// identical controllers may share it. Both strings are allocated; a list is
// released with midi_devices_free.
Midi_Device :: struct {
	id:   string,
	name: string,
}

Midi_Input :: struct {
	impl:         rawptr,

	// Number of inputs currently open, and their names, valid after `open`
	// or `open_device`. Opening zero devices is not a failure: a machine with
	// no MIDI hardware still runs the synthesiser, it just has nothing to play
	// it with.
	count:        int,
	names:        []string,

	// Open every available input and push what arrives into `queue`.
	open:         proc(m: ^Midi_Input, queue: ^Midi_Queue) -> bool,
	// Enumerate every input without opening any. Fresh on every call, so a
	// controller plugged in since the last call is there.
	list:         proc(m: ^Midi_Input) -> []Midi_Device,
	// Open exactly the input `list` reported as `id`. False if it is gone or
	// refuses; nothing is opened then.
	open_device:  proc(m: ^Midi_Input, queue: ^Midi_Queue, id: string) -> bool,
	// Stop and close every open input but keep the backend usable for another
	// open. After this returns, nothing further is pushed into the queue.
	// Safe to call with nothing open.
	close_inputs: proc(m: ^Midi_Input),
	// Close every input and release the backend itself.
	close:        proc(m: ^Midi_Input),
}

midi_devices_free :: proc(devices: []Midi_Device) {
	for d in devices {
		delete(d.id)
		delete(d.name)
	}
	delete(devices)
}
