package standalone

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

// Live mode: the real-time path.
//
// Read this file to review the live behaviour; it is the whole of it. The two
// platform files it leans on only move bytes -- WASAPI hands us a buffer to
// fill, winmm hands us three MIDI bytes -- and neither knows what a note is.
//
// The threading story is the part worth checking:
//
//   - The main thread opens the device, loads the patch, sizes every buffer,
//     starts the stream, and then does nothing but wait for Ctrl-C.
//   - Each MIDI device's callback thread packs its message and pushes it into
//     a lock-free queue. It never touches the engine.
//   - The audio thread drains that queue and is the only thread that ever
//     calls into src/engine once the stream is running.
//
// So the engine has exactly one caller at a time without a single lock, and the
// audio callback below allocates nothing, locks nothing, opens nothing and
// formats no strings.

MIDI_NOTE_OFF :: 0x80
MIDI_NOTE_ON :: 0x90
MIDI_PITCH_BEND :: 0xE0

// The 14-bit MIDI bend range is 0..16383 with 8192 at rest. Both halves are
// divided by 8192 so the centre is exactly zero, which is the same convention
// hosts/clap/plugin.odin uses; the top of the range therefore reaches
// 8191/8192 rather than 1.0, which is what the wire format actually offers.
MIDI_BEND_CENTRE :: 8192.0

Live :: struct {
	eng:   engine.Engine,
	queue: Midi_Queue,

	// De-interleave scratch. `engine_process` writes separate left and right
	// spans but every audio API on the planet wants them interleaved, so the
	// shell owns the buffers that bridge the two. Allocated once, before the
	// stream starts, sized to the largest block the device can ask for.
	left:  []f32,
	right: []f32,
}

// The audio callback. Everything it touches is preallocated or atomic.
live_render :: proc "c" (user: rawptr, out: [^]f32, frames: int, channels: int) {
	// `engine_process` is an ordinary Odin procedure and so needs a context to
	// exist. `default_context()` fills a struct on the stack; it allocates
	// nothing, and nothing below it uses the allocator the struct names. This
	// is the same move hosts/clap/plugin.odin makes in process().
	context = runtime.default_context()

	s := (^Live)(user)
	if s == nil {
		return
	}

	// Drain the queue first so a note that arrived while the previous block was
	// rendering sounds at the top of this one. Timing is therefore block
	// accurate rather than sample accurate: the queue carries no timestamps,
	// and at a ~10 ms shared-mode period that is below what a player can hear
	// as late. Sample accuracy would mean timestamping against the device
	// clock, which is worth doing only if it ever proves audible.
	for {
		message, ok := midi_queue_pop(&s.queue)
		if !ok {
			break
		}
		live_handle_midi(s, message)
	}

	// The scratch was sized from the backend's own stated maximum, so this
	// clamp should never bite. It is here because the alternative to clamping,
	// on the audio thread, is a heap allocation or an overrun.
	n := min(frames, len(s.left))

	if n > 0 {
		engine.engine_process(&s.eng, s.left[:n], s.right[:n])
	}

	for i in 0 ..< n {
		base := i * channels
		out[base + 0] = s.left[i]
		out[base + 1] = s.right[i]
		// The engine is stereo. On a device with more channels the extras are
		// silenced rather than left holding whatever the driver's buffer
		// happened to contain.
		for c in 2 ..< channels {
			out[base + c] = 0
		}
	}

	// Silence anything the clamp above refused to render, so a short block is a
	// gap rather than stale audio.
	for i in n ..< frames {
		base := i * channels
		for c in 0 ..< channels {
			out[base + c] = 0
		}
	}
}

// Decode one packed channel-voice message. Mirrors the MIDI half of
// hosts/clap/plugin.odin's handle_event so the plugin and the standalone
// build respond to a controller identically.
live_handle_midi :: proc(s: ^Live, message: u32) {
	status := midi_status(message) & 0xF0
	data1 := midi_data1(message)
	data2 := midi_data2(message)

	switch int(status) {
	case MIDI_NOTE_ON:
		// Running status aside, a note on with velocity 0 is the standard way
		// keyboards spell a note off, so it is treated as one.
		if data2 == 0 {
			engine.engine_note_off(&s.eng, int(data1))
		} else {
			engine.engine_note_on(&s.eng, int(data1), f32(data2) / 127.0)
		}

	case MIDI_NOTE_OFF:
		engine.engine_note_off(&s.eng, int(data1))

	case MIDI_PITCH_BEND:
		raw := int(data1) | (int(data2) << 7)
		engine.engine_set_pitch_bend(&s.eng, f32((f64(raw) - MIDI_BEND_CENTRE) / MIDI_BEND_CENTRE))
	}
}

// Build the patch live mode will play. With no path given it is the plugin's
// own defaults, which is what `parse_sy1` starts from before it applies a file.
//
// The returned name is always a fresh allocation the caller owns. It has to be:
// `patch.Patch.name` is a slice pointing into the file bytes, and those bytes
// are freed the moment this procedure returns, so handing the slice back would
// be a use-after-free that prints whatever the allocator left behind.
live_load_patch :: proc(patch_path: string) -> (parsed: patch.Patch, name: string, ok: bool) {
	if patch_path == "" {
		for i in 0 ..< patch.PARAMETER_COUNT {
			parsed.values[i] = patch.PARAMETERS[i].default
		}
		return parsed, strings.clone("(defaults)"), true
	}

	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read patch %s: %v", patch_path, read_err)
		return {}, "", false
	}
	defer delete(data)

	owned, parse_ok: bool
	parsed, owned, parse_ok = patch.parse_patch_any(data)
	if !parse_ok {
		fmt.eprintfln("error: cannot parse %s", patch_path)
		return {}, "", false
	}
	if owned {defer patch.destroy_patch(parsed)}
	// Only `values` is read from here on -- `bind_patch` never looks at the
	// name or the colour -- so copying the name is enough to make the struct
	// safe to keep after `data` goes away.
	return parsed, strings.clone(strings.trim_space(parsed.name)), true
}

// Returns the process exit code.
run_live :: proc(patch_path: string) -> int {
	audio, audio_ok := audio_backend_create()
	if !audio_ok {
		fmt.eprintfln("error: no audio backend for this platform")
		return 1
	}
	defer audio.destroy(&audio)

	// Open before loading the patch: the device dictates the sample rate, and
	// the engine has to be built at the rate it will actually run at.
	if !audio.open(&audio) {
		fmt.eprintfln("error: cannot open an audio output device")
		return 1
	}

	parsed, patch_name, patch_ok := live_load_patch(patch_path)
	if !patch_ok {
		return 1
	}
	defer delete(patch_name)

	// Heap-allocated because the audio thread holds this pointer for the whole
	// life of the stream; a main-thread stack frame is the wrong owner.
	s := new(Live)
	defer free(s)
	midi_queue_init(&s.queue)

	engine.engine_load_patch(&s.eng, parsed, audio.format.sample_rate)
	defer engine.engine_destroy(&s.eng)

	// The last allocation before the stream starts. Everything the audio thread
	// needs now exists.
	s.left = make([]f32, audio.max_frames)
	defer delete(s.left)
	s.right = make([]f32, audio.max_frames)
	defer delete(s.right)

	midi, midi_ok := midi_input_create()
	if midi_ok {
		// Not fatal: a machine with no MIDI hardware still runs the
		// synthesiser, it just has nothing to play it with.
		midi.open(&midi, &s.queue)
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

	// Installed before the stream starts so Ctrl-C is never the thing that
	// races the device open.
	install_shutdown_handler()

	if !audio.start(&audio, live_render, s) {
		fmt.eprintfln("error: cannot start the audio stream")
		return 1
	}

	fmt.printfln("playing; press Ctrl-C to stop")

	// The handler only sets a flag, so the actual teardown happens here on the
	// main thread where blocking and freeing are legal.
	for !shutdown_requested() {
		sleep_ms(50)
	}

	fmt.printfln("stopping")
	// Order matters: stop the stream first so the audio thread is provably not
	// inside `live_render` before the deferred engine and buffer teardown above
	// starts pulling memory out from under it.
	audio.stop(&audio)

	if dropped := midi_queue_dropped(&s.queue); dropped > 0 {
		fmt.eprintfln("warning: dropped %d MIDI messages", dropped)
	}
	return 0
}
