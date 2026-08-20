package synth_clap

import "base:intrinsics"
import "base:runtime"

import "../../src/clap"
import "../../src/engine"
import "../../src/patch"
import "../panel"

// Layer 2: the CLAP adapter.
//
// This file is a shell around src/engine. It owns nothing that makes sound: it
// translates CLAP's parameter, note and buffer conventions into the engine's,
// and it is the only place in the plugin allowed to know that a host exists.
//
// Threading, as CLAP defines it:
//
//   - create/init/destroy/activate/deactivate, the state extension and the
//     preset-load extension are [main-thread]. Allocation and file IO are legal
//     here, and both happen.
//   - process() and start/stop_processing are [audio-thread]. Nothing in the
//     path below them allocates, frees, locks or touches a file. The voice pool
//     is sized once in activate(); `engine.bind_patch` reads only static tables
//     and returns a value struct; `engine.engine_process` was written for this.
//
// Values arriving from the main thread while the audio thread is running are
// staged and picked up at the top of a process block, which is the only place
// the audio thread ever changes its parameter set.

Synth :: struct {
	// The host sees `&Synth.plugin`; plugin_data points back here. Keeping the
	// struct first is not required for that to work, but it keeps the two
	// addresses equal, which is convenient in a debugger.
	plugin:      clap.Plugin,
	host:        ^clap.Host,
	// The host half of the params extension, resolved once in init(). Null when
	// the host does not implement it, which is legal and has to stay working.
	host_params: ^clap.Host_Params,
	eng:         engine.Engine,

	// The audio thread's parameter set, in stored .sy1 integers.
	values:      [PARAM_COUNT]i32,

	// Staged by the main thread (state load, preset load). `staged_seq` is
	// bumped after the values are written; the audio thread compares it with
	// `applied_seq` at the top of a block.
	//
	// This is a sequence handshake, not a lock: a process() call that runs
	// exactly while the main thread is mid-write can observe a mix of the old
	// and new set for one block, and will observe the complete new set on the
	// next one, because the sequence is stored last. It never reads
	// uninitialised memory and it never blocks the audio thread, which is the
	// property that matters here.
	staged:      [PARAM_COUNT]i32,
	staged_seq:  u32,
	applied_seq: u32,

	// Scratch for rebinding. Held in the struct rather than on the stack so a
	// rebind on the audio thread cannot depend on stack size.
	mirror:      patch.Patch,

	sample_rate: f32,
	activated:   bool,

	// The engine's parameter block is stale and must be rebound before the next
	// sample is rendered.
	params_dirty: bool,

	// The host's picture of the parameters is stale: tell it on the next
	// process() or flush().
	notify_host: bool,

	// Bank Select arrives as two controllers and does nothing on its own; the
	// next Program Change is what acts on it. Held here because it is a
	// running state of the input rather than of any one message.
	//
	// Only bank 0 exists so far -- the factory bank is compiled in and there
	// is no way yet to put a second one beside it -- so a selection of
	// anything else is remembered and then ignored, which is what a
	// synthesiser with one bank does.
	bank_msb:     int,
	bank_lsb:     int,

	// The interface, and what it sends.
	//
	// A note played on the panel's keyboard arrives on the interface thread,
	// and allocating a voice there while process() is rendering is a race
	// over the whole voice pool -- so notes take the long way round through
	// the queue and are drained at the top of a block. Parameters do not need
	// it: one integer written and one flag set.
	editor:       panel.Panel,
	panel_ready:  bool,
	ui_queue:     panel.Ui_Queue,

	// The panel's own master fader, which is not a patch parameter: the
	// reference keeps its volume knob outside the patch and nothing in the
	// .sy1 format carries it.
	volume:       f32,
}

synth_of :: proc "contextless" (plugin: ^clap.Plugin) -> ^Synth {
	if plugin == nil {
		return nil
	}
	return (^Synth)(plugin.plugin_data)
}

// -- parameter plumbing ------------------------------------------------------

// Copy the stored integers into the engine's parameter block.
//
// `engine.bind_patch` performs no allocation: it reads the generated tables in
// src/patch and fills a plain value struct (verified by reading
// src/engine/binding.odin, which contains no make/new/append/delete). That is
// what makes a parameter change legal on the audio thread.
//
// The voice pool is deliberately not resized. Parameter 94 (polyphony) sizes it
// in engine_init, which allocates, so a change to 94 is held until the host
// next deactivates and activates the plugin.
apply_params :: proc(s: ^Synth) {
	for i in 0 ..< PARAM_COUNT {
		s.mirror.values[i] = int(s.values[i])
		s.mirror.present[i] = true
	}

	params := engine.bind_patch(s.mirror)
	if len(s.eng.voices) > 0 {
		params.polyphony = len(s.eng.voices)
	}
	s.eng.params = params

	// Shapes live on the LFO objects, so they have to be pushed out; the
	// envelope times live on the voices for the same reason. Both loops are
	// bounded by the pool size and neither allocates.
	for j in 0 ..< 2 {
		s.eng.global_lfo[j].shape = params.lfo[j].shape
	}
	for i in 0 ..< len(s.eng.voices) {
		engine.voice_apply_params(&s.eng.voices[i], &s.eng.params, s.eng.sample_rate)
	}
	engine.engine_update_lfo_rates(&s.eng)
}

// Stage a full parameter set from the main thread.
stage_values :: proc "contextless" (s: ^Synth, values: [PARAM_COUNT]i32) {
	s.staged = values
	intrinsics.atomic_store_explicit(&s.staged_seq, s.staged_seq + 1, .Release)

	// When the plugin is not processing there is no audio thread to hand the
	// set to, so it is adopted immediately and the engine, if it exists, is
	// rebound.
	if !s.activated {
		sync_staged(s)
	}
}

// Tell the host that the plugin changed parameter values by itself.
//
// This is what params.h scenario I ("Loading a preset") asks for: load the
// values, then "call clap_host_params.rescan() if anything changed". Without it
// a host has no reason to re-read anything, so it keeps displaying, saving and
// automating the values from before the load -- and a host that never calls
// process() or flush() never sees the change at all.
//
// Only CLAP_PARAM_RESCAN_VALUES is asked for: the parameter list, the ranges,
// the flags and the text formatting are fixed by the generated table in
// src/patch and cannot change while the plugin is loaded.
//
// [main-thread] -- every caller is a main-thread entry point, which is what
// makes calling into the host from here legal.
notify_host_values :: proc "contextless" (s: ^Synth) {
	if s.host_params == nil || s.host_params.rescan == nil || s.host == nil {
		return
	}
	s.host_params.rescan(s.host, clap.PARAM_RESCAN_VALUES)
}

sync_staged :: proc "contextless" (s: ^Synth) {
	seq := intrinsics.atomic_load_explicit(&s.staged_seq, .Acquire)
	if seq == s.applied_seq {
		return
	}
	s.values = s.staged
	s.applied_seq = seq
	s.params_dirty = true
	s.notify_host = true
}

// True when the main thread has staged a set the audio thread has not adopted.
staged_pending :: proc "contextless" (s: ^Synth) -> bool {
	return intrinsics.atomic_load_explicit(&s.staged_seq, .Acquire) != s.applied_seq
}

set_param :: proc "contextless" (s: ^Synth, id: clap.Id, value: f64) {
	index := int(id)
	if index < 0 || index >= PARAM_COUNT {
		return
	}
	stored, ok := param_clamp(index, value)
	if !ok {
		return
	}
	if s.values[index] != i32(stored) {
		s.values[index] = i32(stored)
		s.params_dirty = true
	}
}

// A Program Change: load the patch in that slot.
//
// On the audio thread, because that is where the event arrives, so it takes
// the same route a parameter event does -- writing s.values and marking the
// block dirty -- rather than the main thread's stage_values, which is not
// safe to call from here.
//
// The host is told afterwards. Loading a patch changes ninety-nine values
// behind its back, and a host that is not told goes on displaying, saving
// and automating the ones from before: that is params.h scenario I, and the
// same reason a state load sets this flag.
program_change :: proc "contextless" (s: ^Synth, program: int) {
	bank := s.bank_msb * 128 + s.bank_lsb
	// One bank for now. A program change against a bank that does not exist
	// is ignored rather than folded onto bank 0: silently playing the wrong
	// sound is worse than playing none.
	if bank != 0 {return}

	values, ok := patch.factory_patch(program)
	if !ok {return}

	changed := false
	for i in 0 ..< PARAM_COUNT {
		// The bank keeps stored integers as ints; this host keeps them as
		// i32, which is what the host's own parameter values are.
		wanted := i32(values[i])
		if s.values[i] != wanted {
			s.values[i] = wanted
			changed = true
		}
	}
	if changed {
		s.params_dirty = true
		s.notify_host = true
	}
}

// Tell the host every current parameter value. Used after a state or preset
// load, which changes values behind the host's back.
notify_params :: proc "contextless" (s: ^Synth, out: ^clap.Output_Events) {
	if !s.notify_host {
		return
	}
	s.notify_host = false
	if out == nil || out.try_push == nil {
		return
	}
	for i in 0 ..< PARAM_COUNT {
		event := clap.Event_Param_Value {
			header = {
				size = size_of(clap.Event_Param_Value),
				time = 0,
				space_id = clap.CORE_EVENT_SPACE_ID,
				type = clap.EVENT_PARAM_VALUE,
				flags = 0,
			},
			param_id = clap.Id(i),
			cookie = nil,
			note_id = -1,
			port_index = -1,
			channel = -1,
			key = -1,
			value = f64(s.values[i]),
		}
		out.try_push(out, &event.header)
	}
}

// -- events ------------------------------------------------------------------

MIDI_NOTE_OFF :: 0x80
MIDI_NOTE_ON :: 0x90
MIDI_CONTROL_CHANGE :: 0xB0
MIDI_PROGRAM_CHANGE :: 0xC0
MIDI_PITCH_BEND :: 0xE0

// Bank Select, from the MIDI specification: two controllers that set a
// pending bank and do nothing else. The Program Change that follows is what
// acts on it, and the bank is MSB * 128 + LSB.
MIDI_BANK_SELECT_MSB :: 0
MIDI_BANK_SELECT_LSB :: 32

// The 14-bit MIDI bend range is 0..16383 with 8192 at rest. Both halves are
// divided by 8192 so the centre is exactly zero; the top of the range therefore
// reaches 8191/8192 rather than 1.0, which is what the wire format actually
// offers.
MIDI_BEND_CENTRE :: 8192.0

// Not contextless: it drives the engine, whose procedures are ordinary Odin
// procedures. Every caller establishes a context first.
handle_event :: proc(s: ^Synth, header: ^clap.Event_Header) {
	if header == nil || header.space_id != clap.CORE_EVENT_SPACE_ID {
		return
	}

	switch header.type {
	case clap.EVENT_NOTE_ON:
		event := (^clap.Event_Note)(header)
		key := int(event.key)
		if key < 0 {
			return
		}
		// A note on with velocity 0 is explicitly not a note off in CLAP, so it
		// is passed through as the silent note the host asked for.
		velocity := f32(event.velocity)
		velocity = clamp(velocity, 0, 1)
		engine.engine_note_on(&s.eng, key, velocity)

	case clap.EVENT_NOTE_OFF, clap.EVENT_NOTE_CHOKE:
		event := (^clap.Event_Note)(header)
		key := int(event.key)
		// -1 is CLAP's wildcard: every sounding key matches.
		if key < 0 {
			engine.engine_all_notes_off(&s.eng)
			return
		}
		engine.engine_note_off(&s.eng, key)

	case clap.EVENT_PARAM_VALUE:
		event := (^clap.Event_Param_Value)(header)
		set_param(s, event.param_id, event.value)

	case clap.EVENT_MIDI:
		// The note port advertises the MIDI dialect, so raw MIDI has to be
		// understood as well as CLAP's own note events.
		event := (^clap.Event_Midi)(header)
		status := event.data[0] & 0xF0
		switch int(status) {
		case MIDI_NOTE_ON:
			key := int(event.data[1])
			velocity := int(event.data[2])
			if velocity == 0 {
				engine.engine_note_off(&s.eng, key)
			} else {
				engine.engine_note_on(&s.eng, key, f32(velocity) / 127.0)
			}
		case MIDI_NOTE_OFF:
			engine.engine_note_off(&s.eng, int(event.data[1]))
		case MIDI_CONTROL_CHANGE:
			controller := int(event.data[1])
			value := int(event.data[2])

			// Bank Select is held rather than acted on; see the program
			// change below.
			if controller == MIDI_BANK_SELECT_MSB {
				s.bank_msb = value
			} else if controller == MIDI_BANK_SELECT_LSB {
				s.bank_lsb = value
			} else {
				// Everything else goes to the engine, whose parameters 86 to
				// 89 route two controllers of the patch's choosing. Nothing is
				// swallowed here: which controllers matter is the patch's
				// decision and not this file's.
				engine.engine_control_change(&s.eng, controller, value)
			}

		case MIDI_PROGRAM_CHANGE:
			program_change(s, int(event.data[1]))

		case MIDI_PITCH_BEND:
			raw := int(event.data[1]) | (int(event.data[2]) << 7)
			engine.engine_set_pitch_bend(&s.eng, f32((f64(raw) - MIDI_BEND_CENTRE) / MIDI_BEND_CENTRE))
		}
	}
}

// -- lifecycle ---------------------------------------------------------------

// The host's extensions are resolved here rather than in the factory: CLAP only
// promises that clap_host.get_extension() answers from init() onwards.
plugin_init :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	s := synth_of(plugin)
	if s == nil {
		return false
	}

	// The factory bank, so a Program Change has something to select. Here
	// rather than in the factory because init() is [main-thread] and may
	// allocate, and because it only actually parses once per process however
	// many instances a host makes.
	patch.factory_prepare()

	if s.host != nil && s.host.get_extension != nil {
		s.host_params = (^clap.Host_Params)(s.host.get_extension(s.host, clap.EXT_PARAMS))
	}
	return true
}

plugin_destroy :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	s := synth_of(plugin)
	if s == nil {
		return
	}
	engine.engine_destroy(&s.eng)
	free(s)
}

plugin_activate :: proc "c" (
	plugin: ^clap.Plugin,
	sample_rate: f64,
	min_frames_count: u32,
	max_frames_count: u32,
) -> bool {
	context = runtime.default_context()
	s := synth_of(plugin)
	if s == nil {
		return false
	}
	if sample_rate <= 0 {
		return false
	}

	// Adopt anything staged before activation, then size the voice pool. This
	// is the one call in the plugin that allocates on purpose.
	sync_staged(s)
	s.sample_rate = f32(sample_rate)
	// Unity unless a panel has moved it. Zero would be silence, and the
	// field starts zeroed like the rest of the struct.
	if s.volume <= 0 {
		s.volume = 1
	}
	for i in 0 ..< PARAM_COUNT {
		s.mirror.values[i] = int(s.values[i])
		s.mirror.present[i] = true
	}
	engine.engine_load_patch(&s.eng, s.mirror, s.sample_rate)
	s.params_dirty = false
	s.activated = true
	return true
}

plugin_deactivate :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	s := synth_of(plugin)
	if s == nil {
		return
	}
	s.activated = false
	engine.engine_destroy(&s.eng)
}

plugin_start_processing :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return synth_of(plugin) != nil
}

plugin_stop_processing :: proc "c" (plugin: ^clap.Plugin) {
}

// CLAP's reset kills voices rather than releasing them: the host wants silence
// on the next sample, not a release tail.
plugin_reset :: proc "c" (plugin: ^clap.Plugin) {
	s := synth_of(plugin)
	if s == nil {
		return
	}
	for i in 0 ..< len(s.eng.voices) {
		s.eng.voices[i] = {}
	}
	s.eng.held_notes = 0
	s.eng.held_keys = {}
	s.eng.pitch_bend = 0
}

plugin_process :: proc "c" (plugin: ^clap.Plugin, process: ^clap.Process) -> clap.Process_Status {
	// default_context() initialises a context struct; it does not allocate. The
	// engine procedures below are ordinary Odin procedures and so need one to
	// exist, but none of them uses its allocator.
	context = runtime.default_context()

	s := synth_of(plugin)
	if s == nil || process == nil || !s.activated {
		return clap.PROCESS_ERROR
	}

	sync_staged(s)

	// Anything played on the panel's keyboard since the last block. Here
	// rather than where it was pressed: allocating a voice on the interface
	// thread while this one is rendering is a race over the whole pool.
	panel.drain_events(&s.ui_queue, &s.eng)

	// The transport, before anything reads it. The arpeggiator divides the beat,
	// so a project at 90 BPM has to be able to say so or the engine steps at its
	// own default and drifts against everything else.
	if process.transport != nil {
		t := process.transport
		if t.flags & clap.TRANSPORT_HAS_TEMPO != 0 && t.tempo > 0 {
			engine.engine_set_tempo(&s.eng, f32(t.tempo))
		}
	}

	frames := int(process.frames_count)

	// This plugin advertises exactly one stereo 32-bit output port. A host that
	// hands it anything else has broken the contract it was given, and silently
	// rendering half a signal would hide that.
	if process.audio_outputs_count < 1 || process.audio_outputs == nil {
		return clap.PROCESS_ERROR
	}
	out := &process.audio_outputs[0]
	if out.channel_count < 2 || out.data32 == nil {
		return clap.PROCESS_ERROR
	}
	left := out.data32[0]
	right := out.data32[1]
	if left == nil || right == nil {
		return clap.PROCESS_ERROR
	}
	// The buffer is written in full, so nothing here is a constant span.
	out.constant_mask = 0

	events := process.in_events
	event_count := u32(0)
	if events != nil && events.size != nil && events.get != nil {
		event_count = events.size(events)
	}
	event_index := u32(0)

	frame := 0
	for frame < frames {
		// Everything timed at or before the current frame happens now; the next
		// event's time bounds the sub-block, which is what makes note and
		// parameter timing sample accurate.
		block_end := frames
		for event_index < event_count {
			header := events.get(events, event_index)
			if header == nil {
				event_index += 1
				continue
			}
			at := int(header.time)
			if at > frame {
				if at < block_end {
					block_end = at
				}
				break
			}
			handle_event(s, header)
			event_index += 1
		}

		if s.params_dirty {
			apply_params(s)
			s.params_dirty = false
		}

		if block_end <= frame {
			block_end = frames
		}
		engine.engine_process(&s.eng, left[frame:block_end], right[frame:block_end])

		// The panel's master fader, over what was just rendered. Not a patch
		// parameter -- the reference keeps its volume knob outside the patch
		// and nothing in the .sy1 format carries it -- and skipped entirely
		// while it sits at unity, which is where it is unless a panel has
		// been opened and moved.
		if s.volume > 0 && s.volume < 1 {
			for i in frame ..< block_end {
				left[i] *= s.volume
				right[i] *= s.volume
			}
		}
		frame = block_end
	}

	// Events stamped at or past the end of the block still have to be consumed:
	// dropping them would lose a note on that the host placed on the boundary.
	for event_index < event_count {
		handle_event(s, events.get(events, event_index))
		event_index += 1
	}
	if s.params_dirty {
		apply_params(s)
		s.params_dirty = false
	}

	// After the events, not before them.
	//
	// It used to run at the top of the block, which told the host about a
	// state load staged by the main thread and missed anything that happened
	// during the block itself -- a Program Change arrives in this event list
	// and moves ninety-nine values, and the host did not hear about it until
	// the next call. Running here covers both: the flag is still set when a
	// main thread staged the load, and it is now also set by anything the
	// events did.
	notify_params(s, process.out_events)

	return clap.PROCESS_CONTINUE
}

plugin_on_main_thread :: proc "c" (plugin: ^clap.Plugin) {
}

plugin_get_extension :: proc "c" (plugin: ^clap.Plugin, id: cstring) -> rawptr {
	if id == nil {
		return nil
	}
	switch string(id) {
	case clap.EXT_AUDIO_PORTS:
		return &AUDIO_PORTS
	case clap.EXT_NOTE_PORTS:
		return &NOTE_PORTS
	case clap.EXT_PARAMS:
		return &PARAMS
	case clap.EXT_STATE:
		return &STATE
	case clap.EXT_GUI:
		return &GUI
	case clap.EXT_PRESET_LOAD, clap.EXT_PRESET_LOAD_COMPAT:
		return &PRESET_LOAD
	}
	return nil
}

// -- audio ports -------------------------------------------------------------

AUDIO_PORTS := clap.Plugin_Audio_Ports {
	count = proc "c" (plugin: ^clap.Plugin, is_input: bool) -> u32 {
		return is_input ? 0 : 1
	},
	get = proc "c" (
		plugin: ^clap.Plugin,
		index: u32,
		is_input: bool,
		info: ^clap.Audio_Port_Info,
	) -> bool {
		if is_input || index != 0 || info == nil {
			return false
		}
		info^ = {}
		info.id = 0
		copy_name(info.name[:], "main out")
		info.flags = clap.AUDIO_PORT_IS_MAIN
		info.channel_count = 2
		info.port_type = clap.PORT_STEREO
		info.in_place_pair = clap.INVALID_ID
		return true
	},
}

// -- note ports --------------------------------------------------------------

NOTE_PORTS := clap.Plugin_Note_Ports {
	count = proc "c" (plugin: ^clap.Plugin, is_input: bool) -> u32 {
		return is_input ? 1 : 0
	},
	get = proc "c" (
		plugin: ^clap.Plugin,
		index: u32,
		is_input: bool,
		info: ^clap.Note_Port_Info,
	) -> bool {
		if !is_input || index != 0 || info == nil {
			return false
		}
		info^ = {}
		info.id = 0
		// MIDI is accepted as well as CLAP's own note events because pitch bend
		// has no CLAP note-event spelling: it arrives as a raw MIDI 0xE0
		// message.
		info.supported_dialects = clap.NOTE_DIALECT_CLAP | clap.NOTE_DIALECT_MIDI
		info.preferred_dialect = clap.NOTE_DIALECT_CLAP
		copy_name(info.name[:], "note in")
		return true
	},
}

// -- params ------------------------------------------------------------------

PARAMS := clap.Plugin_Params {
	count = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return u32(PARAM_COUNT)
	},
	get_info = proc "c" (
		plugin: ^clap.Plugin,
		param_index: u32,
		param_info: ^clap.Param_Info,
	) -> bool {
		index := int(param_index)
		if index < 0 || index >= PARAM_COUNT || param_info == nil {
			return false
		}
		param_info^ = {}
		// The parameter id is the Synth1 parameter index, which is also the
		// index a .sy1 file records. Nothing else would survive a patch file.
		param_info.id = clap.Id(index)
		param_info.flags = clap.PARAM_IS_STEPPED | clap.PARAM_IS_AUTOMATABLE
		param_info.cookie = nil
		copy_name(param_info.name[:], param_name(index))
		param_info.min_value = f64(param_min(index))
		param_info.max_value = f64(param_max(index))
		param_info.default_value = f64(param_default(index))
		return true
	},
	get_value = proc "c" (plugin: ^clap.Plugin, param_id: clap.Id, out_value: ^f64) -> bool {
		s := synth_of(plugin)
		index := int(param_id)
		if s == nil || out_value == nil || index < 0 || index >= PARAM_COUNT {
			return false
		}
		// get_value is [main-thread]. A set staged by a state or preset load is
		// already the main thread's answer even though the audio thread will
		// not adopt it until the next block, so it is reported immediately
		// rather than making the host wait a buffer to see what it just loaded.
		if staged_pending(s) {
			out_value^ = f64(s.staged[index])
			return true
		}
		out_value^ = f64(s.values[index])
		return true
	},
	value_to_text = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Id,
		value: f64,
		out_buffer: [^]u8,
		out_buffer_capacity: u32,
	) -> bool {
		context = runtime.default_context()
		index := int(param_id)
		if out_buffer == nil || out_buffer_capacity == 0 {
			return false
		}
		if index < 0 || index >= PARAM_COUNT {
			return false
		}
		stored, ok := param_clamp(index, value)
		if !ok {
			return false
		}
		text, has_text := param_text(index, stored)
		if has_text {
			return write_cstring(out_buffer, out_buffer_capacity, text)
		}
		return write_int(out_buffer, out_buffer_capacity, stored)
	},
	text_to_value = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Id,
		param_value_text: cstring,
		out_value: ^f64,
	) -> bool {
		context = runtime.default_context()
		index := int(param_id)
		if out_value == nil || param_value_text == nil {
			return false
		}
		if index < 0 || index >= PARAM_COUNT {
			return false
		}
		stored, ok := param_parse(index, string(param_value_text))
		if !ok {
			return false
		}
		out_value^ = f64(stored)
		return true
	},
	flush = proc "c" (
		plugin: ^clap.Plugin,
		input: ^clap.Input_Events,
		output: ^clap.Output_Events,
	) {
		context = runtime.default_context()
		s := synth_of(plugin)
		if s == nil {
			return
		}
		sync_staged(s)
		if input != nil && input.size != nil && input.get != nil {
			count := input.size(input)
			for i in 0 ..< count {
				handle_event(s, input.get(input, i))
			}
		}
		if s.params_dirty {
			// Outside process() there may be no engine to rebind; activate()
			// will do it from the same values if that is the case.
			if s.activated {
				apply_params(s)
			}
			s.params_dirty = false
		}
		notify_params(s, output)
	},
}

// -- small string helpers ----------------------------------------------------

// CLAP's fixed-size char arrays are C strings: copy what fits and terminate.
copy_name :: proc "contextless" (dst: []u8, text: string) {
	if len(dst) == 0 {
		return
	}
	n := min(len(text), len(dst) - 1)
	for i in 0 ..< n {
		dst[i] = text[i]
	}
	dst[n] = 0
}

write_cstring :: proc "contextless" (dst: [^]u8, capacity: u32, text: string) -> bool {
	if capacity == 0 {
		return false
	}
	n := min(len(text), int(capacity) - 1)
	for i in 0 ..< n {
		dst[i] = text[i]
	}
	dst[n] = 0
	return n == len(text)
}

// Rendering an integer without core:strconv keeps this callable with no
// allocator in reach.
write_int :: proc "contextless" (dst: [^]u8, capacity: u32, value: int) -> bool {
	digits: [24]u8
	count := 0
	magnitude := value
	negative := value < 0
	if negative {
		magnitude = -value
	}
	if magnitude == 0 {
		digits[0] = '0'
		count = 1
	}
	for magnitude > 0 {
		digits[count] = u8('0' + magnitude % 10)
		magnitude /= 10
		count += 1
	}
	needed := count + (negative ? 1 : 0)
	if int(capacity) < needed + 1 {
		return false
	}
	at := 0
	if negative {
		dst[at] = '-'
		at += 1
	}
	for i := count - 1; i >= 0; i -= 1 {
		dst[at] = digits[i]
		at += 1
	}
	dst[at] = 0
	return true
}
