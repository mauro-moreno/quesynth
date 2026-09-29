package standalone

import "base:intrinsics"
import "core:fmt"
import "core:time"

import "../../src/engine"
import "../../src/patch"

// The daemon: the persistent audio core of the standalone build.
//
// This is what run_live used to be, renamed and given an explicit lifecycle.
// The standalone binary no longer wraps the engine for a player to hear as its
// whole reason to exist; this daemon owns the audio device, the engine and the
// MIDI input, runs headless, and -- from a later slice -- accepts control
// connections over a socket. A front-end (the TUI, and eventually the browser
// panel) is a separate process that attaches over that socket and can come and
// go without the audio stopping.
//
// Slice 1 has no socket and no front-end yet: `quesynth` and `quesynth
// --daemon` both land here and simply play, exactly as the old live mode did.
// The lifecycle states below exist now so the control server added later has a
// coherent thing to report, and so the startup and teardown order is stated in
// one place rather than left implied by the order of a procedure body.

// The states a client will be able to inspect once the control server exists.
// A u32 so the field can be read atomically from a thread other than the one
// that runs the lifecycle.
Daemon_State :: enum u32 {
	Starting,
	Ready,
	Running,
	Stopping,
	Error,
}

Daemon :: struct {
	// Embedded first so `&d.live` is a `^Live` the audio callback can take as
	// its user pointer with no offset games.
	live:  Live,
	state: Daemon_State,
}

daemon_state_name :: proc(state: Daemon_State) -> string {
	switch state {
	case .Starting:
		return "starting"
	case .Ready:
		return "ready"
	case .Running:
		return "running"
	case .Stopping:
		return "stopping"
	case .Error:
		return "error"
	}
	return "unknown"
}

// Publish a new state and say so on stdout. The store is Release so a control
// thread that later reads the field with an Acquire load sees the transition in
// order with whatever produced it.
daemon_set_state :: proc(d: ^Daemon, state: Daemon_State) {
	intrinsics.atomic_store_explicit(&d.state, state, .Release)
	fmt.printfln("daemon %s", daemon_state_name(state))
}

daemon_state :: proc(d: ^Daemon) -> Daemon_State {
	return intrinsics.atomic_load_explicit(&d.state, .Acquire)
}

// Run the daemon until a signal asks it to stop. Returns the process exit code.
//
// The ordering is the point of this procedure, and it is the same ordering the
// old live mode arrived at by construction:
//
//   open the device  -> it dictates the sample rate the engine is built at
//   load the patch   -> needs that rate
//   size the engine  -> the last allocation before the stream starts
//   open MIDI        -> a producer for the queue the audio thread drains
//   start the stream -> after this the audio thread is live; allocate nothing
//   wait             -> the signal handler only raises a flag
//   stop the stream  -> provably out of the callback before anything is freed
run_daemon :: proc(patch_path: string) -> int {
	// Heap-allocated because the audio thread holds `&d.live` for the whole
	// life of the stream; a main-thread stack frame is the wrong owner.
	d := new(Daemon)
	defer free(d)
	daemon_set_state(d, .Starting)

	audio, audio_ok := audio_backend_create()
	if !audio_ok {
		fmt.eprintfln("error: no audio backend for this platform")
		daemon_set_state(d, .Error)
		return 1
	}
	defer audio.destroy(&audio)

	// Open before loading the patch: the device dictates the sample rate, and
	// the engine has to be built at the rate it will actually run at.
	if !audio.open(&audio) {
		fmt.eprintfln("error: cannot open an audio output device")
		daemon_set_state(d, .Error)
		return 1
	}

	parsed, patch_name, patch_ok := live_load_patch(patch_path)
	if !patch_ok {
		daemon_set_state(d, .Error)
		return 1
	}
	defer delete(patch_name)

	midi_queue_init(&d.live.queue)

	engine.engine_load_patch(&d.live.eng, parsed, audio.format.sample_rate)
	defer engine.engine_destroy(&d.live.eng)

	// Publish the initial state so a client that connects before any edit sees
	// the loaded patch rather than an all-zero snapshot.
	{
		init: Snapshot_Data
		for i in 0 ..< patch.PARAMETER_COUNT {
			init.values[i] = i32(engine.engine_patch_value(&d.live.eng, i))
		}
		snapshot_publish(&d.live.snapshot, init)
	}

	// The last allocations before the stream starts. Everything the audio
	// thread needs now exists.
	d.live.left = make([]f32, audio.max_frames)
	defer delete(d.live.left)
	d.live.right = make([]f32, audio.max_frames)
	defer delete(d.live.right)

	// Runtime metrics for daemon.info. Filled now, while every static fact is
	// known; the audio thread stores the live voice count into it each block.
	metrics := Daemon_Metrics {
		sample_rate = int(audio.format.sample_rate),
		buffer_size = audio.max_frames,
		max_voices  = engine.engine_max_voices(&d.live.eng),
		backend     = audio.name,
		start_tick  = time.tick_now(),
	}
	d.live.metrics = &metrics

	midi, midi_ok := midi_input_create()
	if midi_ok {
		// Not fatal: a machine with no MIDI hardware still runs the
		// synthesiser, it just has nothing to play it with.
		midi.open(&midi, &d.live.queue)
	}
	defer if midi_ok {midi.close(&midi)}

	source := patch_path == "" ? "built-in defaults" : patch_path
	fmt.printfln(
		"audio  %s rate=%.0f channels=%d buffer=%d frames",
		audio.name,
		audio.format.sample_rate,
		audio.format.channels,
		audio.max_frames,
	)
	fmt.printfln("patch  %s \"%s\"", source, patch_name)
	if midi_ok && midi.count > 0 {
		for name, i in midi.names {
			fmt.printfln("midi   [%d] %s", i, name)
		}
	} else {
		fmt.printfln("midi   no inputs found")
	}

	// Everything is initialised and the buffers are sized; the daemon is ready
	// to run the moment the stream starts.
	daemon_set_state(d, .Ready)

	// Installed before the stream starts so a signal is never the thing that
	// races the device open.
	install_shutdown_handler()

	if !audio.start(&audio, live_render, &d.live) {
		fmt.eprintfln("error: cannot start the audio stream")
		daemon_set_state(d, .Error)
		return 1
	}
	daemon_set_state(d, .Running)
	fmt.printfln("quesynth daemon ready; press Ctrl-C to stop")

	// Bring up the control surface once audio is running. A failure here is not
	// fatal: the daemon still makes sound, it just has nothing to steer it. The
	// context hands the server a ring to push edits onto and a snapshot to read,
	// never the engine itself.
	cs: Control_Server
	cs.path = control_socket_path()
	cs.ctx = Control_Context {
		ring     = &d.live.ring,
		snapshot = &d.live.snapshot,
		state    = &d.state,
		metrics  = &metrics,
	}
	control_ok := control_server_start(&cs)
	if control_ok {
		fmt.printfln("control %s", cs.path)
	} else {
		fmt.eprintfln("control unavailable; running without a control surface")
	}

	// The handler only sets a flag, so the actual teardown happens here on the
	// main thread where blocking and freeing are legal.
	for !shutdown_requested() {
		sleep_ms(50)
	}

	daemon_set_state(d, .Stopping)
	// Stop accepting clients before the audio stream, so no edit is taken while
	// the engine is tearing down.
	if control_ok {
		control_server_stop(&cs)
	}
	delete(cs.path)

	// Order matters: stop the stream first so the audio thread is provably not
	// inside `live_render` before the deferred engine and buffer teardown above
	// starts pulling memory out from under it.
	audio.stop(&audio)

	if dropped := midi_queue_dropped(&d.live.queue); dropped > 0 {
		fmt.eprintfln("warning: dropped %d MIDI messages", dropped)
	}
	return 0
}
