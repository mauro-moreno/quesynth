package synth_vst3

import "base:runtime"

import "../../src/engine"
import "../../src/patch"
import "../../src/vst3"
import "../panel"

// Layer 2: the VST3 adapter.
//
// A shell around src/engine, the same job hosts/clap does for CLAP. It owns
// nothing that makes sound; it translates VST3's parameter, note and buffer
// conventions into the engine's.
//
// **One object, three interfaces.** VST3 lets a plugin split its processor and
// its editor into two separately-instantiated classes so a host can run them on
// different machines. Nothing here benefits from that -- there is no editor, and
// the parameter set is small and shared -- so this is a "single component
// effect": one object implementing IComponent, IAudioProcessor and
// IEditController at once, which is a supported and common arrangement.
//
// That shape is why the struct begins with three vtable pointers. In this C ABI
// an interface pointer *is* a pointer to a vtable field, so a host holding an
// `IAudioProcessor*` is holding `&plugin.processor_vtbl`. Recovering the plugin
// from such a pointer means subtracting that field's offset, which is what the
// three `from_*` procedures below do. Getting one of them wrong does not fail to
// compile; it reads a neighbouring field as a pointer, so each is written once
// and used everywhere rather than open-coded per method.
//
// Threading. VST3 names two contexts and this follows them: `process` and
// `setProcessing` are the audio thread and allocate nothing, while
// `initialize`, `setActive`, `setState` and `getState` are the main thread and
// may. Parameter values arriving from either side are held as plain stored
// integers and only turned into engine parameters at the top of a process
// block.

PARAM_COUNT :: patch.PARAMETER_COUNT

Plugin :: struct {
	// The three interface pointers, first and in a fixed order. See `from_*`.
	component_vtbl:  ^vst3.IComponent_Vtbl,
	processor_vtbl:  ^vst3.IAudioProcessor_Vtbl,
	controller_vtbl: ^vst3.IEditController_Vtbl,
	// Fourth, and after the three above rather than among them: `from_*`
	// recovers the plugin from a field offset, so the order of the ones
	// already there cannot change.
	midi_map_vtbl:   ^vst3.IMidi_Mapping_Vtbl,
	unit_info_vtbl:  ^vst3.IUnit_Info_Vtbl,

	ref_count:       i32,

	eng:             engine.Engine,
	// The parameter set, as stored .sy1 integers -- the representation every
	// other layer of this project uses.
	values:          [PARAM_COUNT]i32,

	// Scratch for rebinding, held in the struct so a rebind on the audio thread
	// does not depend on stack size.
	mirror:          patch.Patch,

	sample_rate:     f32,
	max_block:       int,
	active:          bool,
	params_dirty:    bool,
	// Which program a host last selected. Kept only so it can be reported
	// back: the sound itself lives in `values` like any other.
	program:         i32,

	// The host's handler, kept only so `setComponentHandler` has somewhere to
	// put it. Nothing here calls back into it: this plugin never changes a
	// parameter on its own initiative.
	handler:         rawptr,

	// The editor, while one exists. Owned by the host through its own
	// reference count, not by the plugin: this is a back-pointer so a
	// parameter changed elsewhere can be shown, and it is cleared by the
	// editor's own release.
	editor:          ^Editor,

	// Master volume, which is deliberately not a patch parameter: the
	// reference keeps `vol` beside the patch name and nothing in the .sy1
	// format carries it. Not saved with the session either, for the same
	// reason -- in a host the track fader is the thing that gets recalled.
	volume:          f32,
	volume_smooth:   engine.Smoother,

	// Notes and wheels from the editor, waiting for the audio thread.
	ui_queue:        panel.Ui_Queue,

	ctx:             runtime.Context,
}

// -- recovering the object from an interface pointer -------------------------

from_component :: proc "contextless" (this: rawptr) -> ^Plugin {
	return (^Plugin)(this)
}

from_processor :: proc "contextless" (this: rawptr) -> ^Plugin {
	return (^Plugin)(uintptr(this) - uintptr(offset_of(Plugin, processor_vtbl)))
}

from_controller :: proc "contextless" (this: rawptr) -> ^Plugin {
	return (^Plugin)(uintptr(this) - uintptr(offset_of(Plugin, controller_vtbl)))
}

from_midi_map :: proc "contextless" (this: rawptr) -> ^Plugin {
	return (^Plugin)(uintptr(this) - uintptr(offset_of(Plugin, midi_map_vtbl)))
}

from_unit_info :: proc "contextless" (this: rawptr) -> ^Plugin {
	return (^Plugin)(uintptr(this) - uintptr(offset_of(Plugin, unit_info_vtbl)))
}

// -- parameters --------------------------------------------------------------

// Copy the stored integers into the engine's parameter block.
//
// `engine.bind_patch` allocates nothing -- it reads the generated tables in
// src/patch and returns a value struct -- which is what makes this legal on the
// audio thread. The voice pool is deliberately not resized: parameter 94 sizes
// it in `engine_init`, which does allocate, so a change there waits for the
// host to deactivate and reactivate.
mirror_values :: proc "contextless" (p: ^Plugin) {
	for i in 0 ..< PARAM_COUNT {
		p.mirror.values[i] = int(p.values[i])
		p.mirror.present[i] = true
	}
}

apply_params :: proc(p: ^Plugin) {
	mirror_values(p)
	params := engine.bind_patch(p.mirror)
	if len(p.eng.voices) > 0 {
		params.polyphony = len(p.eng.voices)
	}
	p.eng.params = params

	// Shapes live on the LFO objects and envelope times on the voices, so both
	// have to be pushed out rather than read from `params` at render time.
	for j in 0 ..< 2 {
		p.eng.global_lfo[j].shape = params.lfo[j].shape
	}
	for i in 0 ..< len(p.eng.voices) {
		engine.voice_apply_params(&p.eng.voices[i], &params, p.eng.sample_rate)
	}
	p.params_dirty = false
}

// A parameter's normalised 0..1 value, which is what VST3 trades in, from its
// stored integer -- and back.
//
// The stored integer is the state's *index*, so the conversion is by position
// in the state table rather than by any value the display carries. That keeps a
// display-keyed parameter (whose displays are not in numeric order) working:
// index 3 is the fourth state whatever it reads as.
param_state_count :: proc(index: int) -> int {
	n := len(patch.parameter_states(index))
	return n if n > 0 else 1
}

// A parameter with no states at all.
//
// Parameters 86 to 89 -- the patch's own two controller assignments -- are
// continuous: they have no state table and their reading is
// (stored + 1) / CONTINUOUS_DENOMINATOR. Both conversions below used to see
// a state count of one and answer zero, which pinned all four to zero for
// every host: a patch's controller assignments could not be read, set or
// saved through VST3 at all. It went unnoticed because nothing here had ever
// compared a whole patch against what the host reads back.
//
// The stored range is the denominator, so the mapping is a plain division.
continuous_span :: f64(patch.CONTINUOUS_DENOMINATOR - 1)

normalized_of :: proc(index: int, stored: i32) -> f64 {
	if patch.PARAMETERS[index].continuous {
		v := clamp(int(stored), 0, patch.CONTINUOUS_DENOMINATOR - 1)
		return f64(v) / continuous_span
	}
	n := param_state_count(index)
	if n <= 1 {
		return 0
	}
	v := int(stored)
	v = clamp(v, 0, n - 1)
	return f64(v) / f64(n - 1)
}

stored_of :: proc(index: int, normalized: f64) -> i32 {
	if patch.PARAMETERS[index].continuous {
		t := clamp(normalized, 0, 1)
		return i32(int(t * continuous_span + 0.5))
	}
	n := param_state_count(index)
	if n <= 1 {
		return 0
	}
	t := clamp(normalized, 0, 1)
	// Round rather than truncate: a host sending back exactly what it was given
	// must land on the same state it came from.
	return i32(int(t * f64(n - 1) + 0.5))
}

// -- IComponent --------------------------------------------------------------

component_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	p := from_component(this)
	context = p.ctx
	return query_interface(p, iid, obj)
}

component_add_ref :: proc "c" (this: rawptr) -> u32 {
	p := from_component(this)
	p.ref_count += 1
	return u32(p.ref_count)
}

component_release :: proc "c" (this: rawptr) -> u32 {
	p := from_component(this)
	return release(p)
}

component_initialize :: proc "c" (this: rawptr, context_: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

component_terminate :: proc "c" (this: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

// The controller lives on this same object, so there is no separate class for
// the host to instantiate. Reporting `kNotImplemented` is how a single-component
// plugin says so; a host that sees it queries this object for IEditController
// instead, which succeeds.
component_get_controller_class_id :: proc "c" (this: rawptr, class_id: ^vst3.TUID) -> vst3.Result {
	return vst3.NOT_IMPLEMENTED
}

component_set_io_mode :: proc "c" (this: rawptr, mode: i32) -> vst3.Result {
	return vst3.NOT_IMPLEMENTED
}

// One stereo audio output and one event input. No audio input: this is an
// instrument, and advertising an input bus it never reads would make hosts
// offer it as an effect.
component_get_bus_count :: proc "c" (this: rawptr, type: i32, dir: i32) -> i32 {
	if type == vst3.MEDIA_AUDIO && dir == vst3.DIRECTION_OUTPUT {
		return 1
	}
	if type == vst3.MEDIA_EVENT && dir == vst3.DIRECTION_INPUT {
		return 1
	}
	return 0
}

component_get_bus_info :: proc "c" (this: rawptr, type: i32, dir: i32, index: i32, bus: ^vst3.Bus_Info) -> vst3.Result {
	if bus == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	if type == vst3.MEDIA_AUDIO && dir == vst3.DIRECTION_OUTPUT {
		bus.media_type = type
		bus.direction = dir
		bus.channel_count = 2
		vst3.copy_utf16(&bus.name, "Stereo Out")
		bus.bus_type = vst3.BUS_MAIN
		bus.flags = vst3.BUS_FLAG_DEFAULT_ACTIVE
		return vst3.RESULT_OK
	}
	if type == vst3.MEDIA_EVENT && dir == vst3.DIRECTION_INPUT {
		bus.media_type = type
		bus.direction = dir
		// One MIDI channel's worth. The engine folds every channel together, so
		// claiming sixteen would promise a per-channel independence it has not
		// got.
		bus.channel_count = 1
		vst3.copy_utf16(&bus.name, "MIDI In")
		bus.bus_type = vst3.BUS_MAIN
		bus.flags = vst3.BUS_FLAG_DEFAULT_ACTIVE
		return vst3.RESULT_OK
	}
	return vst3.INVALID_ARGUMENT
}

component_get_routing_info :: proc "c" (this: rawptr, in_info: ^vst3.Routing_Info, out_info: ^vst3.Routing_Info) -> vst3.Result {
	return vst3.NOT_IMPLEMENTED
}

component_activate_bus :: proc "c" (this: rawptr, type: i32, dir: i32, index: i32, state: u8) -> vst3.Result {
	return vst3.RESULT_OK
}

// Where the voice pool is built and torn down. Allocating is legal here and
// nowhere on the audio path.
component_set_active :: proc "c" (this: rawptr, state: u8) -> vst3.Result {
	p := from_component(this)
	context = p.ctx

	if state != 0 {
		if !p.active {
			// The one call here that allocates on purpose: it sizes the voice
			// pool from parameter 94 and binds the whole set in one go.
			mirror_values(p)
			engine.engine_load_patch(&p.eng, p.mirror, p.sample_rate)
			p.params_dirty = false
			p.active = true
		}
	} else {
		if p.active {
			engine.engine_destroy(&p.eng)
			p.active = false
		}
	}
	return vst3.RESULT_OK
}

component_set_state :: proc "c" (this: rawptr, stream: ^vst3.IBStream) -> vst3.Result {
	p := from_component(this)
	context = p.ctx
	return load_state(p, stream)
}

component_get_state :: proc "c" (this: rawptr, stream: ^vst3.IBStream) -> vst3.Result {
	p := from_component(this)
	context = p.ctx
	return save_state(p, stream)
}

// -- IAudioProcessor ---------------------------------------------------------

processor_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	p := from_processor(this)
	context = p.ctx
	return query_interface(p, iid, obj)
}

processor_add_ref :: proc "c" (this: rawptr) -> u32 {
	p := from_processor(this)
	p.ref_count += 1
	return u32(p.ref_count)
}

processor_release :: proc "c" (this: rawptr) -> u32 {
	return release(from_processor(this))
}

// Stereo out and nothing else. Refusing anything else is deliberate: a host
// that asks for mono gets `kResultFalse` and falls back, rather than being told
// yes and then handed two channels.
processor_set_bus_arrangements :: proc "c" (this: rawptr, inputs: [^]u64, num_ins: i32, outputs: [^]u64, num_outs: i32) -> vst3.Result {
	if num_ins == 0 && num_outs == 1 && outputs != nil && outputs[0] == vst3.SPEAKER_STEREO {
		return vst3.RESULT_OK
	}
	return vst3.RESULT_FALSE
}

processor_get_bus_arrangement :: proc "c" (this: rawptr, dir: i32, index: i32, arr: ^u64) -> vst3.Result {
	if arr == nil || index != 0 || dir != vst3.DIRECTION_OUTPUT {
		return vst3.INVALID_ARGUMENT
	}
	arr^ = vst3.SPEAKER_STEREO
	return vst3.RESULT_OK
}

processor_can_process_sample_size :: proc "c" (this: rawptr, symbolic_sample_size: i32) -> vst3.Result {
	// The engine renders f32. A host wanting f64 is told no and will use 32-bit.
	return vst3.RESULT_OK if symbolic_sample_size == vst3.SAMPLE_32 else vst3.RESULT_FALSE
}

processor_get_latency_samples :: proc "c" (this: rawptr) -> u32 {
	return 0
}

processor_setup_processing :: proc "c" (this: rawptr, setup: ^vst3.Process_Setup) -> vst3.Result {
	p := from_processor(this)
	context = p.ctx
	if setup == nil {
		return vst3.INVALID_ARGUMENT
	}
	p.sample_rate = f32(setup.sample_rate)
	p.max_block = int(setup.max_samples_per_block)
	engine.smoother_set_time(&p.volume_smooth, 0.01, p.sample_rate)
	// If the host changes the rate while active, the engine has to be rebuilt at
	// the new rate; it is only ever legal to do that here, not in `process`.
	if p.active {
		mirror_values(p)
		engine.engine_load_patch(&p.eng, p.mirror, p.sample_rate)
		p.params_dirty = false
	}
	return vst3.RESULT_OK
}

processor_set_processing :: proc "c" (this: rawptr, state: u8) -> vst3.Result {
	p := from_processor(this)
	context = p.ctx
	// Leaving the processing state should silence the instrument, or a note
	// held across a transport stop sounds again when it restarts.
	if state == 0 && p.active {
		engine.engine_all_notes_off(&p.eng)
	}
	return vst3.RESULT_OK
}

processor_get_tail_samples :: proc "c" (this: rawptr) -> u32 {
	// The chorus at near-unity feedback rings for a long time and the delay is
	// tempo-synced, so no honest finite tail can be given. `0xFFFFFFFF` is the
	// API's "infinite", which stops a host truncating the release.
	return 0xFFFFFFFF
}

processor_process :: proc "c" (this: rawptr, data: ^vst3.Process_Data) -> vst3.Result {
	p := from_processor(this)
	context = p.ctx

	if data == nil || !p.active {
		return vst3.RESULT_OK
	}

	// Parameter changes first, so a value and a note in the same block are
	// applied in that order -- which is what a host means by sending both.
	apply_parameter_changes(p, data.input_parameter_changes)
	// The transport, before anything reads it. The arpeggiator divides the beat,
	// so a host that plays at 90 BPM has to be able to say so; without this the
	// engine would step at its own 120 default and drift against the project on
	// every patch that arpeggiates.
	if data.process_context != nil {
		context_ := (^vst3.Process_Context)(data.process_context)
		if context_.state & vst3.PROCESS_CONTEXT_TEMPO_VALID != 0 && context_.tempo > 0 {
			engine.engine_set_tempo(&p.eng, f32(context_.tempo))
		}
	}

	// Notes played on the editor keyboard, which arrived on the interface
	// thread and have been waiting for this one. See ui_events.odin.
	panel.drain_events(&p.ui_queue, &p.eng)
	if p.params_dirty {
		apply_params(p)
	}

	frames := int(data.num_samples)
	if frames <= 0 {
		// A zero-length block is still allowed to carry events, and hosts use
		// that to deliver parameter changes while stopped.
		dispatch_events(p, data.input_events, 0, 0)
		return vst3.RESULT_OK
	}

	if data.num_outputs < 1 || data.outputs == nil || data.symbolic_sample_size != vst3.SAMPLE_32 {
		return vst3.RESULT_OK
	}
	out := &data.outputs[0]
	if out.num_channels < 2 || out.channel_buffers == nil {
		return vst3.RESULT_OK
	}
	buffers := ([^][^]f32)(out.channel_buffers)
	left := buffers[0]
	right := buffers[1]
	if left == nil || right == nil {
		return vst3.RESULT_OK
	}

	// Render in runs bounded by the next event, so a note lands on the sample
	// the host asked for rather than at a block boundary.
	frame := 0
	event_index := i32(0)
	event_count := i32(0)
	if data.input_events != nil {
		event_count = data.input_events.vtbl.get_event_count(data.input_events)
	}

	for frame < frames {
		block_end := frames

		// Apply every event due at or before this frame, and find where the
		// next one falls.
		for event_index < event_count {
			e: vst3.Event
			if data.input_events.vtbl.get_event(data.input_events, event_index, &e) != vst3.RESULT_OK {
				event_index += 1
				continue
			}
			offset := int(e.sample_offset)
			if offset <= frame {
				handle_event(p, &e)
				event_index += 1
				continue
			}
			if offset < block_end {
				block_end = offset
			}
			break
		}

		if block_end <= frame {
			block_end = frame + 1
		}
		engine.engine_process(&p.eng, left[frame:block_end], right[frame:block_end])
		frame = block_end
	}

	// Master volume last, over the finished block. Through a smoother rather
	// than as a bare multiply: the control is dragged, and a step in gain is a
	// click.
	for i in 0 ..< frames {
		gain := engine.smoother_process(&p.volume_smooth, p.volume)
		left[i] *= gain
		right[i] *= gain
	}

	// The output is not silent; saying so lets a host skip work downstream, and
	// saying it wrongly makes a held note disappear.
	out.silence_flags = 0
	return vst3.RESULT_OK
}

// -- events and parameter changes --------------------------------------------

handle_event :: proc(p: ^Plugin, e: ^vst3.Event) {
	switch e.type {
	case vst3.EVENT_NOTE_ON:
		note := (^vst3.Note_On_Event)(&e.payload)
		pitch := int(note.pitch)
		if pitch < 0 || pitch > 127 {
			return
		}
		velocity := note.velocity
		// VST3 delivers velocity already normalised. A note on at zero velocity
		// is a note off in MIDI, and hosts translating MIDI pass it straight
		// through, so it is honoured here too.
		if velocity <= 0 {
			engine.engine_note_off(&p.eng, pitch)
			return
		}
		engine.engine_note_on(&p.eng, pitch, clamp(velocity, 0, 1))

	case vst3.EVENT_NOTE_OFF:
		note := (^vst3.Note_Off_Event)(&e.payload)
		pitch := int(note.pitch)
		if pitch < 0 || pitch > 127 {
			return
		}
		engine.engine_note_off(&p.eng, pitch)
	}
}

dispatch_events :: proc(p: ^Plugin, events: ^vst3.IEventList, from, to: int) {
	if events == nil {
		return
	}
	count := events.vtbl.get_event_count(events)
	for i in 0 ..< count {
		e: vst3.Event
		if events.vtbl.get_event(events, i, &e) != vst3.RESULT_OK {
			continue
		}
		handle_event(p, &e)
	}
}

// Take the last point of each parameter's queue.
//
// VST3 delivers a parameter change as a list of (sample offset, value) points
// so a host can automate within a block. The engine rebinds its whole parameter
// set at once and cannot do that per sample without rebinding per sample, so
// the value at the end of the block is used. For a knob being turned that is
// the value the user let go on.
apply_parameter_changes :: proc(p: ^Plugin, changes: ^vst3.IParameterChanges) {
	if changes == nil {
		return
	}
	count := changes.vtbl.get_parameter_count(changes)
	for i in 0 ..< count {
		queue := changes.vtbl.get_parameter_data(changes, i)
		if queue == nil {
			continue
		}
		points := queue.vtbl.get_point_count(queue)
		if points <= 0 {
			continue
		}
		id := queue.vtbl.get_parameter_id(queue)
		if id != PROGRAM_PARAM_ID && int(id) >= PARAM_COUNT {
			continue
		}
		offset: i32
		value: f64
		if queue.vtbl.get_point(queue, points - 1, &offset, &value) != vst3.RESULT_OK {
			continue
		}
		// A program change arrives here, as a change to the program
		// parameter: the host converts the MIDI message into one.
		if id == PROGRAM_PARAM_ID {
			select_program(p, program_of(value))
			continue
		}
		stored := stored_of(int(id), value)
		if p.values[id] != stored {
			p.values[id] = stored
			p.params_dirty = true
		}
	}
}

// -- IEditController ---------------------------------------------------------

controller_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	p := from_controller(this)
	context = p.ctx
	return query_interface(p, iid, obj)
}

controller_add_ref :: proc "c" (this: rawptr) -> u32 {
	p := from_controller(this)
	p.ref_count += 1
	return u32(p.ref_count)
}

controller_release :: proc "c" (this: rawptr) -> u32 {
	return release(from_controller(this))
}

controller_initialize :: proc "c" (this: rawptr, context_: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

controller_terminate :: proc "c" (this: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

// The processor's state, handed to the controller so the two agree. Since they
// are the same object here, this is the same read as `setState`.
controller_set_component_state :: proc "c" (this: rawptr, stream: ^vst3.IBStream) -> vst3.Result {
	p := from_controller(this)
	context = p.ctx
	return load_state(p, stream)
}

controller_set_state :: proc "c" (this: rawptr, stream: ^vst3.IBStream) -> vst3.Result {
	return vst3.RESULT_OK
}

controller_get_state :: proc "c" (this: rawptr, stream: ^vst3.IBStream) -> vst3.Result {
	return vst3.RESULT_OK
}

controller_get_parameter_count :: proc "c" (this: rawptr) -> i32 {
	// One more than the synth has: the last is the program.
	return i32(PARAM_COUNT) + 1
}

controller_get_parameter_info :: proc "c" (this: rawptr, index: i32, info: ^vst3.Parameter_Info) -> vst3.Result {
	context = from_controller(this).ctx
	if info == nil || index < 0 || int(index) > PARAM_COUNT {
		return vst3.INVALID_ARGUMENT
	}

	// The program parameter, which is how VST3 delivers a MIDI Program
	// Change: there is no event for one. A parameter carrying
	// kIsProgramChange is what a host routes it to, and selecting a preset
	// in the host's own menu arrives the same way.
	if int(index) == PARAM_COUNT {
		info.id = PROGRAM_PARAM_ID
		vst3.copy_utf16(&info.title, "Program")
		vst3.copy_utf16(&info.short_title, "Program")
		vst3.copy_utf16(&info.units, "")
		info.step_count = i32(patch.FACTORY_SLOTS - 1)
		info.default_normalized_value = 0
		info.unit_id = 0
		info.flags = vst3.PARAM_IS_PROGRAM_CHANGE | vst3.PARAM_IS_LIST
		return vst3.RESULT_OK
	}

	i := int(index)
	meta := patch.PARAMETERS[i]

	info.id = u32(index)
	vst3.copy_utf16(&info.title, meta.name)
	vst3.copy_utf16(&info.short_title, meta.name)
	vst3.copy_utf16(&info.units, "")
	// `stepCount` is the number of steps *between* values, so a parameter with
	// n states has n-1. Zero would declare it continuous.
	info.step_count = i32(max(param_state_count(i) - 1, 0))
	info.default_normalized_value = normalized_of(i, i32(meta.default))
	info.unit_id = 0
	info.flags = vst3.PARAM_CAN_AUTOMATE
	return vst3.RESULT_OK
}

// The reading the host shows beside the parameter: the reference's own display
// string for that state, which is what every other layer of this project uses.
controller_get_param_string_by_value :: proc "c" (this: rawptr, id: u32, normalized: f64, str: ^vst3.String128) -> vst3.Result {
	context = from_controller(this).ctx
	if str == nil || int(id) >= PARAM_COUNT {
		return vst3.INVALID_ARGUMENT
	}
	i := int(id)
	states := patch.parameter_states(i)
	stored := stored_of(i, normalized)
	if len(states) == 0 || int(stored) >= len(states) {
		vst3.copy_utf16(str, "")
		return vst3.RESULT_OK
	}
	vst3.copy_utf16(str, states[stored].display)
	return vst3.RESULT_OK
}

controller_get_param_value_by_string :: proc "c" (this: rawptr, id: u32, s: [^]u16, normalized: ^f64) -> vst3.Result {
	return vst3.NOT_IMPLEMENTED
}

// The plain value is the stored integer, which is what the .sy1 format and
// every table in this project index by.
controller_normalized_param_to_plain :: proc "c" (this: rawptr, id: u32, normalized: f64) -> f64 {
	context = from_controller(this).ctx
	if int(id) >= PARAM_COUNT {
		return 0
	}
	return f64(stored_of(int(id), normalized))
}

controller_plain_param_to_normalized :: proc "c" (this: rawptr, id: u32, plain: f64) -> f64 {
	context = from_controller(this).ctx
	if int(id) >= PARAM_COUNT {
		return 0
	}
	return normalized_of(int(id), i32(plain))
}

controller_get_param_normalized :: proc "c" (this: rawptr, id: u32) -> f64 {
	p := from_controller(this)
	context = p.ctx
	if id == PROGRAM_PARAM_ID {
		return program_normalized(p.program)
	}
	if int(id) >= PARAM_COUNT {
		return 0
	}
	return normalized_of(int(id), p.values[id])
}

controller_set_param_normalized :: proc "c" (this: rawptr, id: u32, value: f64) -> vst3.Result {
	p := from_controller(this)
	context = p.ctx
	if id == PROGRAM_PARAM_ID {
		select_program(p, program_of(value))
		// This path is the main thread -- a host setting the program on the
		// controller -- so the panel can be told directly. The audio-thread
		// path in process() cannot, and relies on the host telling the
		// controller as well, which is what a host does to keep its own
		// generic panel in step.
		if p.editor != nil {
			editor_send_state(p.editor)
		}
		return vst3.RESULT_OK
	}
	if int(id) >= PARAM_COUNT {
		return vst3.INVALID_ARGUMENT
	}
	stored := stored_of(int(id), value)
	if p.values[id] != stored {
		p.values[id] = stored
		p.params_dirty = true
		// Off the audio thread there may be no engine to rebind into; when
		// there is one, rebinding now keeps a knob turned while stopped
		// audible on the next block.
		if p.active {
			apply_params(p)
		}
		// And shown, if the panel is open: this call is how a host reports an
		// automation lane or its own generic control moving, and the web view
		// has no other way to hear about it.
		editor_send_param(p.editor, int(id), stored)
	}
	return vst3.RESULT_OK
}

controller_set_component_handler :: proc "c" (this: rawptr, handler: rawptr) -> vst3.Result {
	p := from_controller(this)
	p.handler = handler
	return vst3.RESULT_OK
}

// The editor is the interface in ui/, hosted in a WebView2 control. See
// editor.odin.
//
// Returning nil is a valid answer and not a failure: it is how a plugin says
// the host should draw the generic panel from `getParameterInfo` instead. That
// is what happens on a machine with no WebView2 runtime, and it leaves a
// working instrument rather than a plugin that will not open.
controller_create_view :: proc "c" (this: rawptr, name: cstring) -> rawptr {
	p := from_controller(this)
	context = p.ctx

	if name == nil || string(name) != "editor" {
		return nil
	}
	if p.editor != nil {
		// The host gets a counted reference either way, or it would release
		// a view still in use.
		p.editor.ref_count += 1
		return rawptr(p.editor)
	}
	ed := make_editor(p)
	if ed == nil {
		return nil
	}
	p.editor = ed
	return rawptr(ed)
}

// -- FUnknown ----------------------------------------------------------------

// Hand out whichever interface was asked for.
//
// Each answer is the address of the matching vtable *field*, not of the object,
// because that is what the C ABI means by an interface pointer. FUnknown and
// IPluginBase are ambiguous -- all three interfaces derive from them -- and the
// convention is to answer with the component, which is what a host expects to
// receive when it asks an audio module for its identity.
query_interface :: proc(p: ^Plugin, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	if obj == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	obj^ = nil

	if vst3.tuid_equal(iid, vst3.IID_FUNKNOWN()) ||
	   vst3.tuid_equal(iid, vst3.IID_PLUGIN_BASE()) ||
	   vst3.tuid_equal(iid, vst3.IID_COMPONENT()) {
		p.ref_count += 1
		obj^ = rawptr(p)
		return vst3.RESULT_OK
	}
	if vst3.tuid_equal(iid, vst3.IID_AUDIO_PROCESSOR()) {
		p.ref_count += 1
		obj^ = rawptr(&p.processor_vtbl)
		return vst3.RESULT_OK
	}
	if vst3.tuid_equal(iid, vst3.IID_EDIT_CONTROLLER()) {
		p.ref_count += 1
		obj^ = rawptr(&p.controller_vtbl)
		return vst3.RESULT_OK
	}
	if vst3.tuid_equal(iid, vst3.IID_MIDI_MAPPING()) {
		p.ref_count += 1
		obj^ = rawptr(&p.midi_map_vtbl)
		return vst3.RESULT_OK
	}
	if vst3.tuid_equal(iid, vst3.IID_UNIT_INFO()) {
		p.ref_count += 1
		obj^ = rawptr(&p.unit_info_vtbl)
		return vst3.RESULT_OK
	}
	return vst3.NO_INTERFACE
}

release :: proc "c" (p: ^Plugin) -> u32 {
	context = p.ctx
	p.ref_count -= 1
	if p.ref_count > 0 {
		return u32(p.ref_count)
	}
	if p.active {
		engine.engine_destroy(&p.eng)
		p.active = false
	}
	free(p)
	return 0
}

// -- the vtables -------------------------------------------------------------
//
// One shared instance of each, since none of them holds per-object state.

COMPONENT_VTBL := vst3.IComponent_Vtbl {
	query_interface         = component_query_interface,
	add_ref                 = component_add_ref,
	release                 = component_release,
	initialize              = component_initialize,
	terminate               = component_terminate,
	get_controller_class_id = component_get_controller_class_id,
	set_io_mode             = component_set_io_mode,
	get_bus_count           = component_get_bus_count,
	get_bus_info            = component_get_bus_info,
	get_routing_info        = component_get_routing_info,
	activate_bus            = component_activate_bus,
	set_active              = component_set_active,
	set_state               = component_set_state,
	get_state               = component_get_state,
}

PROCESSOR_VTBL := vst3.IAudioProcessor_Vtbl {
	query_interface         = processor_query_interface,
	add_ref                 = processor_add_ref,
	release                 = processor_release,
	set_bus_arrangements    = processor_set_bus_arrangements,
	get_bus_arrangement     = processor_get_bus_arrangement,
	can_process_sample_size = processor_can_process_sample_size,
	get_latency_samples     = processor_get_latency_samples,
	setup_processing        = processor_setup_processing,
	set_processing          = processor_set_processing,
	process                 = processor_process,
	get_tail_samples        = processor_get_tail_samples,
}

CONTROLLER_VTBL := vst3.IEditController_Vtbl {
	query_interface           = controller_query_interface,
	add_ref                   = controller_add_ref,
	release                   = controller_release,
	initialize                = controller_initialize,
	terminate                 = controller_terminate,
	set_component_state       = controller_set_component_state,
	set_state                 = controller_set_state,
	get_state                 = controller_get_state,
	get_parameter_count       = controller_get_parameter_count,
	get_parameter_info        = controller_get_parameter_info,
	get_param_string_by_value = controller_get_param_string_by_value,
	get_param_value_by_string = controller_get_param_value_by_string,
	normalized_param_to_plain = controller_normalized_param_to_plain,
	plain_param_to_normalized = controller_plain_param_to_normalized,
	get_param_normalized      = controller_get_param_normalized,
	set_param_normalized      = controller_set_param_normalized,
	set_component_handler     = controller_set_component_handler,
	create_view               = controller_create_view,
}

// -- construction ------------------------------------------------------------

make_plugin :: proc() -> ^Plugin {
	p := new(Plugin)
	if p == nil {
		return nil
	}

	// The factory bank, so a program change has something to select. Here
	// rather than lazily because this runs on the main thread and may
	// allocate, while a program change arrives on the audio thread and may
	// not. It parses once per process however many instances are made.
	patch.factory_prepare()
	p.component_vtbl = &COMPONENT_VTBL
	p.processor_vtbl = &PROCESSOR_VTBL
	p.controller_vtbl = &CONTROLLER_VTBL
	p.midi_map_vtbl = &MIDI_MAP_VTBL
	p.unit_info_vtbl = &UNIT_INFO_VTBL
	p.ref_count = 1
	p.sample_rate = 44100
	p.max_block = 512
	// The same default the control in the strip opens at.
	p.volume = 0.8
	engine.smoother_init(&p.volume_smooth, p.volume, 0.01, p.sample_rate)
	p.ctx = context

	// The reference's own defaults, so an instance that is never given a patch
	// still sounds like something.
	for i in 0 ..< PARAM_COUNT {
		p.values[i] = i32(patch.PARAMETERS[i].default)
	}
	return p
}
