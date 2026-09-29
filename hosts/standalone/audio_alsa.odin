#+build linux
package standalone

import "base:intrinsics"
import "core:c"
import "core:dynlib"
import "core:sys/posix"

// Linux audio output: ALSA PCM, blocking writes on a dedicated thread.
//
// This is one half of the platform seam described in backend.odin, the Linux
// counterpart of audio_wasapi.odin. Nothing above it knows ALSA exists; nothing
// in it knows what a note is.
//
// libasound is loaded at run time rather than linked, for the same reason
// src/webview2 loads its DLL: a build must not require the -dev package to be
// installed, and a machine without libasound should cost nothing and simply have
// no audio -- which run_daemon already reports honestly. The runtime library
// (libasound.so.2) ships with essentially every Linux desktop, and PipeWire
// provides the same ALSA PCM device, so "default" reaches whatever the user
// actually runs.
//
// Only the seven entry points this needs are bound, from their documented C
// signatures. snd_pcm_set_params does in one call what a dozen hw_params_*
// procedures would, which keeps the surface small enough to read.

ALSA_LIBRARY :: "libasound.so.2"
ALSA_DEVICE :: "default"

SND_PCM_STREAM_PLAYBACK :: 0
SND_PCM_FORMAT_FLOAT_LE :: 14
SND_PCM_ACCESS_RW_INTERLEAVED :: 3

// The engine is stereo; a device wanting more channels is not this backend's
// concern because set_params asks for exactly two.
ALSA_CHANNELS :: 2
// Soft resampling is left on (the 1 passed to set_params), so the engine always
// runs at this rate whatever the device prefers -- the same rate the self-test
// and the offline renderer use.
ALSA_RATE :: 48000
// One write's worth, and therefore the max_frames the shell sizes its scratch
// from. Small enough to play responsively, large enough that per-block overhead
// is nothing.
ALSA_PERIOD_FRAMES :: 512
// Target latency handed to set_params, in microseconds. ALSA sizes its own ring
// buffer from this; ~40 ms is comfortable for shared playback.
ALSA_LATENCY_US :: 40000

Snd_Pcm_Open :: #type proc "c" (pcm: ^rawptr, name: cstring, stream: i32, mode: i32) -> i32
Snd_Pcm_Set_Params :: #type proc "c" (pcm: rawptr, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency: u32) -> i32
Snd_Pcm_Writei :: #type proc "c" (pcm: rawptr, buffer: rawptr, size: c.ulong) -> c.long
Snd_Pcm_Recover :: #type proc "c" (pcm: rawptr, err: i32, silent: i32) -> i32
Snd_Pcm_Drop :: #type proc "c" (pcm: rawptr) -> i32
Snd_Pcm_Close :: #type proc "c" (pcm: rawptr) -> i32

Alsa :: struct {
	lib:        dynlib.Library,
	loaded:     bool,

	pcm:        rawptr,

	open_fn:    Snd_Pcm_Open,
	set_params: Snd_Pcm_Set_Params,
	writei:     Snd_Pcm_Writei,
	recover:    Snd_Pcm_Recover,
	drop:       Snd_Pcm_Drop,
	close_fn:   Snd_Pcm_Close,

	// Interleaved scratch the render callback fills and writei drains. Owned by
	// this backend, sized once in `open`, so the audio thread never allocates.
	buffer:     []f32,
	channels:   int,

	render:     Audio_Render_Proc,
	user:       rawptr,

	thread:     posix.pthread_t,
	has_thread: bool,
	// Read by the render thread every period, cleared by `stop`.
	running:    b32,
}

alsa_backend :: proc() -> (Audio_Backend, bool) {
	a := new(Alsa)
	b := Audio_Backend {
		impl    = a,
		open    = alsa_open,
		start   = alsa_start,
		stop    = alsa_stop,
		destroy = alsa_destroy,
	}
	return b, true
}

// Load libasound and bind the entry points. A missing library or a missing
// symbol is not fatal to the process: it means no audio backend, which `open`
// reports by returning false.
alsa_load :: proc(a: ^Alsa) -> bool {
	if a.loaded {
		return true
	}
	lib, ok := dynlib.load_library(ALSA_LIBRARY)
	if !ok {
		return false
	}

	bound := true
	a.open_fn = transmute(Snd_Pcm_Open)alsa_symbol(lib, "snd_pcm_open", &bound)
	a.set_params = transmute(Snd_Pcm_Set_Params)alsa_symbol(lib, "snd_pcm_set_params", &bound)
	a.writei = transmute(Snd_Pcm_Writei)alsa_symbol(lib, "snd_pcm_writei", &bound)
	a.recover = transmute(Snd_Pcm_Recover)alsa_symbol(lib, "snd_pcm_recover", &bound)
	a.drop = transmute(Snd_Pcm_Drop)alsa_symbol(lib, "snd_pcm_drop", &bound)
	a.close_fn = transmute(Snd_Pcm_Close)alsa_symbol(lib, "snd_pcm_close", &bound)

	if !bound {
		dynlib.unload_library(lib)
		return false
	}

	a.lib = lib
	a.loaded = true
	return true
}

alsa_symbol :: proc(lib: dynlib.Library, name: string, ok: ^bool) -> rawptr {
	ptr, found := dynlib.symbol_address(lib, name)
	if !found {
		ok^ = false
	}
	return ptr
}

alsa_open :: proc(b: ^Audio_Backend) -> bool {
	a := (^Alsa)(b.impl)
	if !alsa_load(a) {
		return false
	}

	pcm: rawptr
	// Mode 0 is blocking, which is what the render thread relies on: writei
	// parks the thread until the device can take the next period.
	if a.open_fn(&pcm, ALSA_DEVICE, SND_PCM_STREAM_PLAYBACK, 0) < 0 || pcm == nil {
		return false
	}
	a.pcm = pcm

	if a.set_params(
		   pcm,
		   SND_PCM_FORMAT_FLOAT_LE,
		   SND_PCM_ACCESS_RW_INTERLEAVED,
		   ALSA_CHANNELS,
		   ALSA_RATE,
		   1,
		   ALSA_LATENCY_US,
	   ) <
	   0 {
		a.close_fn(pcm)
		a.pcm = nil
		return false
	}

	a.channels = ALSA_CHANNELS
	a.buffer = make([]f32, ALSA_PERIOD_FRAMES * ALSA_CHANNELS)

	b.name = "ALSA (default)"
	b.format.sample_rate = f32(ALSA_RATE)
	b.format.channels = ALSA_CHANNELS
	b.max_frames = ALSA_PERIOD_FRAMES
	return true
}

alsa_start :: proc(b: ^Audio_Backend, render: Audio_Render_Proc, user: rawptr) -> bool {
	a := (^Alsa)(b.impl)
	if a.pcm == nil {
		return false
	}

	a.render = render
	a.user = user
	intrinsics.atomic_store_explicit(&a.running, true, .Release)

	// A raw pthread rather than core:thread: this one must not carry an Odin
	// context, exactly as the WASAPI render thread does not. The render
	// callback establishes its own context and allocates nothing.
	if posix.pthread_create(&a.thread, nil, alsa_thread, a) != .NONE {
		intrinsics.atomic_store_explicit(&a.running, false, .Release)
		return false
	}
	a.has_thread = true
	return true
}

alsa_thread :: proc "c" (arg: rawptr) -> rawptr {
	a := (^Alsa)(arg)

	for intrinsics.atomic_load_explicit(&a.running, .Acquire) {
		a.render(a.user, raw_data(a.buffer), ALSA_PERIOD_FRAMES, a.channels)

		written := a.writei(a.pcm, rawptr(raw_data(a.buffer)), c.ulong(ALSA_PERIOD_FRAMES))
		if written < 0 {
			// An underrun (-EPIPE) or a suspend (-ESTRPIPE) is recoverable;
			// recover prepares the device to be written again. Anything it
			// cannot fix ends the stream rather than spinning on the error.
			if a.recover(a.pcm, i32(written), 1) < 0 {
				break
			}
		}
	}
	return nil
}

alsa_stop :: proc(b: ^Audio_Backend) {
	a := (^Alsa)(b.impl)

	intrinsics.atomic_store_explicit(&a.running, false, .Release)

	// Join before the caller frees the engine and the scratch the render
	// callback holds pointers into. The thread checks the flag once per period,
	// so this waits at most one block -- the current writei -- before returning.
	if a.has_thread {
		posix.pthread_join(a.thread, nil)
		a.has_thread = false
	}

	if a.pcm != nil && a.drop != nil {
		a.drop(a.pcm)
	}
}

alsa_destroy :: proc(b: ^Audio_Backend) {
	a := (^Alsa)(b.impl)
	if a == nil {
		return
	}

	alsa_stop(b)

	if a.pcm != nil && a.close_fn != nil {
		a.close_fn(a.pcm)
		a.pcm = nil
	}
	if a.buffer != nil {
		delete(a.buffer)
		a.buffer = nil
	}
	if a.loaded {
		dynlib.unload_library(a.lib)
		a.loaded = false
	}

	free(a)
	b.impl = nil
}
