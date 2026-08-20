package clap_tests

import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import clap "../../src/clap"
import engine "../../src/engine"
import patch "../../src/patch"
import synth "../../hosts/clap"

// The plugin is exercised through its own CLAP vtables rather than by calling
// its internals: every test below goes through the factory, the extension
// pointers the plugin hands out, and real event lists. That is the same surface
// a host sees, so a break in the adapter shows up here rather than only in a
// DAW.

TEST_HOST := clap.Host {
	clap_version = clap.VERSION,
	name = "clap_tests",
	vendor = "quesynth",
	url = "",
	version = "0.1.0",
	get_extension = proc "c" (host: ^clap.Host, extension_id: cstring) -> rawptr {return nil},
	request_restart = proc "c" (host: ^clap.Host) {},
	request_process = proc "c" (host: ^clap.Host) {},
	request_callback = proc "c" (host: ^clap.Host) {},
}

// A host that counts the callbacks it is asked for.
//
// Its own instance rather than a counter on TEST_HOST: the suite runs on six
// threads and every test shares that host, so a shared counter would be read
// and written by whatever else happened to be running.
Counting_Host :: struct {
	host:      clap.Host,
	callbacks: int,
}

counting_host_init :: proc(c: ^Counting_Host) {
	c.host = TEST_HOST
	c.host.host_data = rawptr(c)
	c.host.request_callback = proc "c" (host: ^clap.Host) {
		if host == nil || host.host_data == nil {return}
		counter := (^Counting_Host)(host.host_data)
		counter.callbacks += 1
	}
}

make_plugin :: proc(t: ^testing.T) -> ^clap.Plugin {
	plugin := synth.FACTORY.create_plugin(&synth.FACTORY, &TEST_HOST, synth.PLUGIN_ID)
	testing.expect(t, plugin != nil, "factory did not create the plugin")
	if plugin == nil {
		return nil
	}
	testing.expect(t, plugin.init(plugin), "plugin.init failed")
	return plugin
}

params_of :: proc(plugin: ^clap.Plugin) -> ^clap.Plugin_Params {
	return (^clap.Plugin_Params)(plugin.get_extension(plugin, clap.EXT_PARAMS))
}

state_of :: proc(plugin: ^clap.Plugin) -> ^clap.Plugin_State {
	return (^clap.Plugin_State)(plugin.get_extension(plugin, clap.EXT_STATE))
}

preset_of :: proc(plugin: ^clap.Plugin) -> ^clap.Plugin_Preset_Load {
	return (^clap.Plugin_Preset_Load)(plugin.get_extension(plugin, clap.EXT_PRESET_LOAD))
}

// -- event and buffer harness ------------------------------------------------

MAX_EVENTS :: 64
EVENT_BYTES :: 4096

Input_Queue :: struct {
	list:    clap.Input_Events,
	buffer:  [EVENT_BYTES]u8,
	offsets: [MAX_EVENTS]int,
	count:   int,
	used:    int,
}

input_init :: proc(q: ^Input_Queue) {
	q.count = 0
	q.used = 0
	q.list = clap.Input_Events {
		ctx = q,
		size = proc "c" (list: ^clap.Input_Events) -> u32 {
			return u32((^Input_Queue)(list.ctx).count)
		},
		get = proc "c" (list: ^clap.Input_Events, index: u32) -> ^clap.Event_Header {
			q := (^Input_Queue)(list.ctx)
			if int(index) >= q.count {
				return nil
			}
			return (^clap.Event_Header)(&q.buffer[q.offsets[index]])
		},
	}
}

input_push :: proc(q: ^Input_Queue, event: ^$T) {
	size := size_of(T)
	offset := (q.used + 7) & ~int(7)
	if q.count >= MAX_EVENTS || offset + size > EVENT_BYTES {
		return
	}
	source := (^[size_of(T)]u8)(event)
	for i in 0 ..< size {
		q.buffer[offset + i] = source[i]
	}
	q.offsets[q.count] = offset
	q.count += 1
	q.used = offset + size
}

Output_Queue :: struct {
	list:  clap.Output_Events,
	count: int,
}

output_init :: proc(q: ^Output_Queue) {
	q.count = 0
	q.list = clap.Output_Events {
		ctx = q,
		try_push = proc "c" (list: ^clap.Output_Events, event: ^clap.Event_Header) -> bool {
			(^Output_Queue)(list.ctx).count += 1
			return true
		},
	}
}

note_event :: proc(type: u16, time: u32, key: i16, velocity: f64) -> clap.Event_Note {
	return clap.Event_Note {
		header = {
			size = size_of(clap.Event_Note),
			time = time,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = type,
			flags = 0,
		},
		note_id = -1,
		port_index = 0,
		channel = 0,
		key = key,
		velocity = velocity,
	}
}

param_event :: proc(time: u32, id: u32, value: f64) -> clap.Event_Param_Value {
	return clap.Event_Param_Value {
		header = {
			size = size_of(clap.Event_Param_Value),
			time = time,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = clap.EVENT_PARAM_VALUE,
			flags = 0,
		},
		param_id = clap.Id(id),
		cookie = nil,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = value,
	}
}

midi_event :: proc(time: u32, a, b, c: u8) -> clap.Event_Midi {
	return clap.Event_Midi {
		header = {
			size = size_of(clap.Event_Midi),
			time = time,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = clap.EVENT_MIDI,
			flags = 0,
		},
		port_index = 0,
		data = {a, b, c},
	}
}

BLOCK :: 256

Render :: struct {
	left:     [BLOCK]f32,
	right:    [BLOCK]f32,
	channels: [2][^]f32,
	output:   clap.Audio_Buffer,
}

render_init :: proc(r: ^Render) {
	r.channels = {raw_data(r.left[:]), raw_data(r.right[:])}
	r.output = clap.Audio_Buffer {
		data32        = raw_data(r.channels[:]),
		channel_count = 2,
	}
}

// Run one block and return the peak sample it produced.
run_block :: proc(
	plugin: ^clap.Plugin,
	r: ^Render,
	input: ^Input_Queue,
	output: ^Output_Queue,
	frames: int = BLOCK,
) -> f32 {
	process := clap.Process {
		steady_time         = 0,
		frames_count        = u32(frames),
		audio_outputs       = &r.output,
		audio_outputs_count = 1,
		in_events           = &input.list,
		out_events          = &output.list,
	}
	plugin.process(plugin, &process)

	peak: f32 = 0
	for i in 0 ..< frames {
		if abs(r.left[i]) > peak {peak = abs(r.left[i])}
		if abs(r.right[i]) > peak {peak = abs(r.right[i])}
	}
	input.count = 0
	input.used = 0
	return peak
}

// -- parameters --------------------------------------------------------------

@(test)
test_param_info_matches_patch_table :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	testing.expect(t, params != nil, "no params extension")
	testing.expect_value(t, params.count(plugin), u32(patch.PARAMETER_COUNT))

	for index in 0 ..< patch.PARAMETER_COUNT {
		info: clap.Param_Info
		testing.expect(t, params.get_info(plugin, u32(index), &info), "get_info failed")

		// The id is the Synth1 parameter index: that is what a .sy1 file
		// records and what the state blob stores.
		testing.expect_value(t, info.id, clap.Id(index))

		expected_name := patch.PARAMETERS[index].name
		got_name := string(cstring(&info.name[0]))
		testing.expect_value(t, got_name, expected_name)

		reference := patch.PARAMETERS[index]

		// The advertised range is checked by what it must be able to express
		// rather than by restating the rule that produced it, which would only
		// compare the adapter with itself.
		//
		// The contract is that every state the reference can select is reachable:
		// a direct-index parameter is addressed by table position, so the whole
		// 0..state_count-1 span must fit, and a display-keyed one is addressed by
		// the number it shows, so every strict-integer display must fit. That is
		// what the plain 0..state_count-1 rule got wrong for the eleven
		// parameters whose displays are not 0-based.
		if reference.continuous {
			testing.expect_value(t, info.min_value, 0.0)
			testing.expect_value(t, info.max_value, f64(patch.CONTINUOUS_DENOMINATOR - 1))
		} else {
			states := patch.PARAMETER_STATES[reference.state_offset:][:reference.state_count]
			if reference.display_keyed {
				for state in states {
					value, is_int := patch.display_integer(state.display)
					if !is_int {
						continue
					}
					testing.expectf(
						t,
						f64(value) >= info.min_value && f64(value) <= info.max_value,
						"parameter %d (%s) cannot express its display %q (%d), range %v..%v",
						index,
						reference.name,
						state.display,
						value,
						info.min_value,
						info.max_value,
					)
				}
			} else {
				testing.expectf(
					t,
					info.min_value <= 0.0 && info.max_value >= f64(reference.state_count - 1),
					"parameter %d (%s) cannot address its %d states, range %v..%v",
					index,
					reference.name,
					reference.state_count,
					info.min_value,
					info.max_value,
				)
			}
		}

		// The measured default is advertised verbatim, never rewritten to fit.
		testing.expect_value(t, info.default_value, f64(reference.default))

		// CLAP requires min <= default <= max for every parameter.
		testing.expect(
			t,
			info.min_value <= info.default_value && info.default_value <= info.max_value,
			"default outside the advertised range",
		)
		expected_flags := clap.PARAM_IS_AUTOMATABLE
		if !reference.continuous {
			expected_flags |= clap.PARAM_IS_STEPPED
		}
		testing.expect_value(t, info.flags, expected_flags)
	}
}

// Index 21's reference default is one past the top of its 128-state table. The
// range is widened to hold it rather than the default being clamped, because
// clamping would change the sound of every patch that does not set it.
@(test)
test_param_21_range_holds_its_out_of_range_default :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	info: clap.Param_Info
	testing.expect(t, params.get_info(plugin, 21, &info), "get_info failed")
	testing.expect_value(t, patch.PARAMETERS[21].state_count, 128)
	testing.expect_value(t, info.max_value, 128.0)
	testing.expect_value(t, info.default_value, 128.0)

	value: f64
	testing.expect(t, params.get_value(plugin, 21, &value), "get_value failed")
	testing.expect_value(t, value, 128.0)
}

@(test)
test_param_defaults_are_the_reference_defaults :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	for index in 0 ..< patch.PARAMETER_COUNT {
		value: f64
		testing.expect(t, params.get_value(plugin, clap.Id(index), &value), "get_value failed")
		testing.expect_value(t, int(value), patch.PARAMETERS[index].default)
	}
}

@(test)
test_param_round_trip_through_flush :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)

	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	// Parameter 19 is the filter cutoff: 128 states, so 0..127.
	set := param_event(0, 19, 100)
	input_push(&input, &set)
	params.flush(plugin, &input.list, &output.list)

	value: f64
	testing.expect(t, params.get_value(plugin, 19, &value), "get_value failed")
	testing.expect_value(t, value, 100.0)

	// Out of range in both directions is clamped to the advertised range, and a
	// fractional value truncates, which is how CLAP defines a stepped value.
	input.count = 0
	input.used = 0
	high := param_event(0, 19, 10_000)
	low := param_event(0, 20, -5)
	fraction := param_event(0, 22, 42.9)
	input_push(&input, &high)
	input_push(&input, &low)
	input_push(&input, &fraction)
	params.flush(plugin, &input.list, &output.list)

	testing.expect(t, params.get_value(plugin, 19, &value), "get_value failed")
	testing.expect_value(t, value, 127.0)
	testing.expect(t, params.get_value(plugin, 20, &value), "get_value failed")
	testing.expect_value(t, value, 0.0)
	testing.expect(t, params.get_value(plugin, 22, &value), "get_value failed")
	testing.expect_value(t, value, 42.0)
}

@(test)
test_param_value_to_text_uses_the_measured_display :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	buffer: [clap.NAME_SIZE]u8

	// Parameter 5 is the oscillator mix, whose measured displays are the
	// reference plugin's own "100 : 0" style rather than bare integers.
	testing.expect(
		t,
		params.value_to_text(plugin, 5, 0, raw_data(buffer[:]), len(buffer)),
		"value_to_text failed",
	)
	states := patch.parameter_states(5)
	testing.expect(t, len(states) > 0, "parameter 5 has no measured states")
	testing.expect_value(t, string(cstring(&buffer[0])), states[0].display)

	// Parameter 2 is a direct state index, so its text is the reference's own
	// display for that state -- "00" at state 64, not the number 64.
	testing.expect(t, !patch.PARAMETERS[2].display_keyed, "parameter 2 changed kind")
	testing.expect(
		t,
		params.value_to_text(plugin, 2, 64, raw_data(buffer[:]), len(buffer)),
		"value_to_text failed",
	)
	testing.expect_value(t, string(cstring(&buffer[0])), patch.parameter_states(2)[64].display)

	// A display-keyed parameter stores the number it shows, so its text is the
	// integer itself.
	testing.expect(t, patch.PARAMETERS[8].display_keyed, "parameter 8 changed kind")
	testing.expect(
		t,
		params.value_to_text(plugin, 8, 64, raw_data(buffer[:]), len(buffer)),
		"value_to_text failed",
	)
	testing.expect_value(t, string(cstring(&buffer[0])), "64")

	out: f64
	testing.expect(t, params.text_to_value(plugin, 2, "70", &out), "text_to_value failed")
	testing.expect_value(t, out, 70.0)
	testing.expect(
		t,
		!params.text_to_value(plugin, 2, "not a number", &out),
		"text_to_value accepted nonsense",
	)
}

// -- ports -------------------------------------------------------------------

@(test)
test_ports_are_one_stereo_out_and_one_note_in :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	audio := (^clap.Plugin_Audio_Ports)(plugin.get_extension(plugin, clap.EXT_AUDIO_PORTS))
	testing.expect(t, audio != nil, "no audio-ports extension")
	testing.expect_value(t, audio.count(plugin, false), u32(1))
	testing.expect_value(t, audio.count(plugin, true), u32(0))

	audio_info: clap.Audio_Port_Info
	testing.expect(t, audio.get(plugin, 0, false, &audio_info), "audio_ports.get failed")
	testing.expect_value(t, audio_info.channel_count, u32(2))
	testing.expect_value(t, audio_info.flags, clap.AUDIO_PORT_IS_MAIN)
	testing.expect_value(t, string(audio_info.port_type), clap.PORT_STEREO)
	testing.expect_value(t, audio_info.in_place_pair, clap.INVALID_ID)
	testing.expect(t, !audio.get(plugin, 1, false, &audio_info), "phantom second audio port")

	notes := (^clap.Plugin_Note_Ports)(plugin.get_extension(plugin, clap.EXT_NOTE_PORTS))
	testing.expect(t, notes != nil, "no note-ports extension")
	testing.expect_value(t, notes.count(plugin, true), u32(1))
	testing.expect_value(t, notes.count(plugin, false), u32(0))

	note_info: clap.Note_Port_Info
	testing.expect(t, notes.get(plugin, 0, true, &note_info), "note_ports.get failed")
	// MIDI is required as well as CLAP's note events: pitch bend only exists in
	// the MIDI dialect.
	testing.expect_value(
		t,
		note_info.supported_dialects,
		clap.NOTE_DIALECT_CLAP | clap.NOTE_DIALECT_MIDI,
	)
}

// -- notes -------------------------------------------------------------------

@(test)
test_note_on_sounds_and_note_off_releases :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	testing.expect(t, plugin.start_processing(plugin), "start_processing failed")
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	// Silence before a note.
	testing.expect_value(t, run_block(plugin, &render, &input, &output), f32(0))

	on := note_event(clap.EVENT_NOTE_ON, 0, 60, 1.0)
	input_push(&input, &on)
	held: f32 = 0
	for _ in 0 ..< 40 {
		block := run_block(plugin, &render, &input, &output)
		if block > held {held = block}
	}
	testing.expect(t, held > 0.001, "a held note produced no sound")

	off := note_event(clap.EVENT_NOTE_OFF, 0, 60, 0.0)
	input_push(&input, &off)
	// Long enough for any release in the default patch to finish.
	tail: f32 = 0
	for _ in 0 ..< 600 {
		tail = run_block(plugin, &render, &input, &output)
	}
	testing.expect(t, tail < held, "note off did not release the voice")
	testing.expect(t, tail < 0.001, "the voice was still sounding long after note off")
}

// A note-off with the wildcard key -1 releases everything, which is how CLAP
// spells "all notes off".
@(test)
test_wildcard_note_off_releases_every_voice :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	for key in i16(60) ..= 64 {
		on := note_event(clap.EVENT_NOTE_ON, 0, key, 1.0)
		input_push(&input, &on)
	}
	for _ in 0 ..< 20 {
		run_block(plugin, &render, &input, &output)
	}

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")
	testing.expect(t, s.eng.held_notes > 0, "no keys were registered as held")

	wildcard := note_event(clap.EVENT_NOTE_OFF, 0, -1, 0.0)
	input_push(&input, &wildcard)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.held_notes, 0)
}

@(test)
test_pitch_bend_reaches_the_engine :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")
	testing.expect_value(t, s.eng.pitch_bend, f32(0))

	// 0xE0: 14-bit bend, LSB first. 0x2000 (8192) is the rest position.
	full_up := midi_event(0, 0xE0, 0x7F, 0x7F)
	input_push(&input, &full_up)
	run_block(plugin, &render, &input, &output)
	testing.expect(t, s.eng.pitch_bend > 0.99, "full upward bend did not reach the engine")

	full_down := midi_event(0, 0xE0, 0x00, 0x00)
	input_push(&input, &full_down)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.pitch_bend, f32(-1))

	centre := midi_event(0, 0xE0, 0x00, 0x40)
	input_push(&input, &centre)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.pitch_bend, f32(0))
}

// A controller reaches the engine, where the patch's own two assignments
// decide what it does. Controller 1 is the modulation wheel by default, which
// is what parameters 86 and 88 name.
@(test)
test_midi_cc_reaches_the_engine :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")

	wheel_up := midi_event(0, 0xB0, 1, 127)
	input_push(&input, &wheel_up)
	run_block(plugin, &render, &input, &output)
	testing.expect(t, s.eng.ctrl_value[0] > 0.99, "controller 1 did not reach the engine")

	wheel_down := midi_event(0, 0xB0, 1, 0)
	input_push(&input, &wheel_down)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.ctrl_value[0], f32(0))
}

// Parameter automation must also replace the stored patch controller motion is
// relative to. Otherwise a CC after an edit jumps back to the values and routing
// that were present when the plugin was activated.
@(test)
test_midi_cc_uses_the_current_automated_patch :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)
	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	for &event in ([]clap.Event_Param_Value {
		param_event(0, 19, 0),
		param_event(0, 50, 127),
		param_event(0, 86, 45057),
		param_event(0, 87, 19),
		param_event(0, 88, 0),
	}) {
		input_push(&input, &event)
	}
	run_block(plugin, &render, &input, &output)

	wheel := midi_event(0, 0xB0, 1, 127)
	input_push(&input, &wheel)
	run_block(plugin, &render, &input, &output)

	s := synth.synth_of(plugin)
	want_patch := s.eng.patch
	want_patch.values[19] = 127
	want := engine.bind_patch(want_patch)
	testing.expect_value(t, s.eng.params.filter_cutoff_hz, want.filter_cutoff_hz)

	// An unrelated edit keeps the wheel's current displacement.
	resonance := param_event(0, 20, 32)
	input_push(&input, &resonance)
	run_block(plugin, &render, &input, &output)
	want_after_resonance_patch := s.eng.patch
	want_after_resonance_patch.values[19] = 127
	want_after_resonance := engine.bind_patch(want_after_resonance_patch)
	testing.expect_value(t, s.eng.params.filter_cutoff_hz, want_after_resonance.filter_cutoff_hz)

	// Reassigning the slot to another source cannot reuse CC1's stale value as
	// though it had already arrived from CC2.
	new_source := param_event(0, 86, 45058)
	input_push(&input, &new_source)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.ctrl_value[0], f32(0))
	base := engine.bind_patch(s.eng.patch)
	testing.expect_value(t, s.eng.params.filter_cutoff_hz, base.filter_cutoff_hz)
}

// A Program Change selects a patch by number out of the bank compiled into
// the plugin. This is the whole reason a bank is a hundred and twenty-eight
// slots, and the reason the bank is embedded: a host can send a program
// change to a plugin whose editor has never been opened.
@(test)
test_program_change_loads_a_patch :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")

	// Slot 6 of the bank *this instance* loaded, which is not always the one
	// compiled in: a machine with a saved bank plays that instead. Comparing
	// against the embedded bank made this test pass or fail on what happened
	// to be in the app data of whoever ran it -- the same fault as the one
	// that made the suite need patches/incoming.
	wanted, ok := patch.slots_patch(&s.slots, 6)
	testing.expect(t, ok, "the bank has nothing in slot 6")
	if !ok {return}

	change := midi_event(0, 0xC0, 6, 0)
	input_push(&input, &change)
	run_block(plugin, &render, &input, &output)

	same := true
	for i in 0 ..< synth.PARAM_COUNT {
		if s.values[i] != wanted[i] {same = false}
	}
	testing.expect(t, same, "program change did not load the patch in that slot")

	// And the host has to be told, or it goes on displaying and saving the
	// values from before the change.
	testing.expect(t, output.count > 0, "the host was not told the parameters moved")
}

// A program change has to reach the panel as well as the engine.
//
// The sound changed and the interface went on showing the patch from before
// it, which is the same class of bug as the VST3 editor missing the `state`
// message: everything audible worked and everything visible was a lie. The
// web view may only be spoken to from the thread it was made on, and a
// program change arrives on the audio thread, so the plugin has to ask the
// host for a main-thread callback and do it there.
@(test)
test_program_change_asks_for_a_callback :: proc(t: ^testing.T) {
	counter: Counting_Host
	counting_host_init(&counter)
	plugin := synth.FACTORY.create_plugin(&synth.FACTORY, &counter.host, synth.PLUGIN_ID)
	testing.expect(t, plugin != nil, "factory did not create the plugin")
	if plugin == nil {return}
	testing.expect(t, plugin.init(plugin), "plugin.init failed")
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	before := counter.callbacks
	change := midi_event(0, 0xC0, 6, 0)
	input_push(&input, &change)
	run_block(plugin, &render, &input, &output)

	testing.expect(
		t,
		counter.callbacks > before,
		"a program change did not ask the host for a main-thread callback",
	)

	// And the callback itself has to be safe to make with no editor open,
	// which is the usual case: a host may call back whenever it likes.
	plugin.on_main_thread(plugin)

	// A block with nothing in it must not ask again, or the plugin is
	// waking the main thread on every buffer for nothing.
	quiet := counter.callbacks
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, counter.callbacks, quiet)
}
// A bank sent by the panel has to reach the thing that answers program
// changes.
//
// This is the wiring the interface depends on and the one place it cannot be
// seen from: the panel sends a bank, the host adopts it, and from then on a
// program change has to select out of *that* bank. Everything about it is
// invisible from outside the plugin -- the only symptom of it being wrong is
// a sound that does not match what is on screen.
//
// Deliberately with save = false. The saving half is checked in tests/panel
// against a temporary file; doing it here would write over the bank belonging
// to whoever is running the tests.
@(test)
test_a_bank_from_the_panel_is_adopted :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")
	if s == nil {return}

	// What the plugin starts with: the bank compiled in, or one saved on
	// this machine. Either way, not the one below.
	before := patch.slots_name(&s.slots, 0)

	text: string = `{"format":"quesynth.bank","version":1,"name":"From The Panel","patches":[
		{"name":"Panel Patch","parameters":{"osc1 shape":1}},
		null,
		{"name":"Third","parameters":{"osc1 shape":3}}
	]}`

	synth.gui_set_bank(rawptr(s), text, false)

	testing.expect_value(t, patch.slots_label(&s.slots), "From The Panel")
	testing.expect_value(t, patch.slots_name(&s.slots, 0), "Panel Patch")
	testing.expect_value(t, patch.slots_name(&s.slots, 2), "Third")
	testing.expectf(
		t,
		patch.slots_name(&s.slots, 0) != before || before == "Panel Patch",
		"the bank did not change: slot 0 is still %v",
		before,
	)

	// And the gap is a gap, so program 1 selects nothing.
	_, filled := patch.slots_patch(&s.slots, 1)
	testing.expect(t, !filled, "the empty slot came back filled")

	// The point of all of it: a program change now plays out of this bank.
	wanted, ok := patch.slots_patch(&s.slots, 2)
	testing.expect(t, ok, "slot 2 is empty")
	if !ok {return}
	synth.program_change(s, 2)
	same := true
	for i in 0 ..< synth.PARAM_COUNT {
		if s.values[i] != wanted[i] {same = false}
	}
	testing.expect(t, same, "a program change did not load the patch from the new bank")
}
// An empty slot is still a slot. Program 120 selects nothing rather than
// selecting the nearest sound, because a number has to mean the same thing
// every time it is sent.
@(test)
test_program_change_on_an_empty_slot_does_nothing :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")

	before := s.values
	_, filled := patch.slots_patch(&s.slots, 120)
	testing.expect(t, !filled, "slot 120 was expected to be empty")

	change := midi_event(0, 0xC0, 120, 0)
	input_push(&input, &change)
	run_block(plugin, &render, &input, &output)

	testing.expect(t, before == s.values, "an empty slot changed the sound")
}

// Bank Select does nothing on its own: the specification says the pair of
// controllers sets a pending bank and the Program Change that follows acts on
// it. And a bank that does not exist is ignored rather than folded onto the
// one that does.
@(test)
test_bank_select_waits_for_a_program_change :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")

	before := s.values
	msb := midi_event(0, 0xB0, 0, 0)
	lsb := midi_event(0, 0xB0, 32, 1)
	input_push(&input, &msb)
	input_push(&input, &lsb)
	run_block(plugin, &render, &input, &output)
	testing.expect(t, before == s.values, "bank select alone changed the sound")

	// Bank 1 does not exist, so this program change is refused.
	change := midi_event(0, 0xC0, 6, 0)
	input_push(&input, &change)
	run_block(plugin, &render, &input, &output)
	testing.expect(t, before == s.values, "a program change into a bank that does not exist was obeyed")

	// Back to bank 0, and the same program change is obeyed.
	back := midi_event(0, 0xB0, 32, 0)
	input_push(&input, &back)
	input_push(&input, &change)
	run_block(plugin, &render, &input, &output)
	testing.expect(t, before != s.values, "a program change into bank 0 was refused")
}
// The plugin advertises the MIDI dialect, so raw MIDI notes have to work too,
// including the note-on-with-velocity-0 spelling of a note off.
@(test)
test_midi_notes_are_handled :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	s := synth.synth_of(plugin)

	on := midi_event(0, 0x90, 60, 100)
	input_push(&input, &on)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.held_notes, 1)

	zero_velocity_off := midi_event(0, 0x90, 60, 0)
	input_push(&input, &zero_velocity_off)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.held_notes, 0)

	on_again := midi_event(0, 0x90, 64, 100)
	input_push(&input, &on_again)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.held_notes, 1)

	off := midi_event(0, 0x80, 64, 0)
	input_push(&input, &off)
	run_block(plugin, &render, &input, &output)
	testing.expect_value(t, s.eng.held_notes, 0)
}

// An event stamped inside the block must take effect at its own frame, not at
// the start of the block: the samples before it stay silent.
@(test)
test_note_timing_is_sample_accurate :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	on := note_event(clap.EVENT_NOTE_ON, BLOCK / 2, 60, 1.0)
	input_push(&input, &on)
	run_block(plugin, &render, &input, &output)

	before: f32 = 0
	for i in 0 ..< BLOCK / 2 {
		if abs(render.left[i]) > before {before = abs(render.left[i])}
	}
	testing.expect_value(t, before, f32(0))
}

// -- state -------------------------------------------------------------------

// A stream that hands over a few bytes at a time, because a host is allowed to
// and the plugin has to loop.
Memory_Stream :: struct {
	out:   clap.Ostream,
	input: clap.Istream,
	data:  [dynamic]u8,
	read:  int,
	chunk: int,
}

memory_stream_init :: proc(m: ^Memory_Stream, chunk: int) {
	m.data = make([dynamic]u8)
	m.read = 0
	m.chunk = chunk
	m.out = clap.Ostream {
		ctx = m,
		write = proc "c" (stream: ^clap.Ostream, buffer: rawptr, size: u64) -> i64 {
			context = TEST_CONTEXT
			m := (^Memory_Stream)(stream.ctx)
			n := min(int(size), m.chunk)
			source := ([^]u8)(buffer)
			for i in 0 ..< n {
				append(&m.data, source[i])
			}
			return i64(n)
		},
	}
	m.input = clap.Istream {
		ctx = m,
		read = proc "c" (stream: ^clap.Istream, buffer: rawptr, size: u64) -> i64 {
			m := (^Memory_Stream)(stream.ctx)
			remaining := len(m.data) - m.read
			n := min(min(int(size), m.chunk), remaining)
			destination := ([^]u8)(buffer)
			for i in 0 ..< n {
				destination[i] = m.data[m.read + i]
			}
			m.read += n
			return i64(n)
		},
	}
}

memory_stream_destroy :: proc(m: ^Memory_Stream) {
	delete(m.data)
}

// The write callback needs an Odin context to append to a dynamic array; a real
// host's stream would not.
TEST_CONTEXT: runtime.Context

@(test)
test_state_round_trip_restores_all_99_values :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	state := state_of(plugin)
	testing.expect(t, state != nil, "no state extension")

	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	// Move every parameter off its default so a restore that quietly does
	// nothing cannot pass.
	written: [patch.PARAMETER_COUNT]int
	for index in 0 ..< patch.PARAMETER_COUNT {
		info: clap.Param_Info
		params.get_info(plugin, u32(index), &info)
		value := int(info.default_value) == int(info.max_value) \
			? int(info.min_value) \
			: int(info.default_value) + 1
		written[index] = value
		event := param_event(0, u32(index), f64(value))
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			params.flush(plugin, &input.list, &output.list)
			input.count = 0
			input.used = 0
		}
	}
	params.flush(plugin, &input.list, &output.list)
	input.count = 0
	input.used = 0

	// Saved through a stream that only ever writes 7 bytes at a time.
	stream: Memory_Stream
	memory_stream_init(&stream, 7)
	defer memory_stream_destroy(&stream)
	testing.expect(t, state.save(plugin, &stream.out), "state.save failed")
	testing.expect_value(t, len(stream.data), 12 + patch.PARAMETER_COUNT * 4)

	// Scribble over every value, then restore.
	for index in 0 ..< patch.PARAMETER_COUNT {
		event := param_event(0, u32(index), 0)
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			params.flush(plugin, &input.list, &output.list)
			input.count = 0
			input.used = 0
		}
	}
	params.flush(plugin, &input.list, &output.list)

	testing.expect(t, state.load(plugin, &stream.input), "state.load failed")

	for index in 0 ..< patch.PARAMETER_COUNT {
		value: f64
		testing.expect(t, params.get_value(plugin, clap.Id(index), &value), "get_value failed")
		testing.expect_value(t, int(value), written[index])
	}
}

@(test)
test_state_rejects_a_foreign_or_truncated_blob :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	state := state_of(plugin)

	// Wrong magic.
	foreign_stream: Memory_Stream
	memory_stream_init(&foreign_stream, 64)
	defer memory_stream_destroy(&foreign_stream)
	for i in 0 ..< 12 + patch.PARAMETER_COUNT * 4 {
		append(&foreign_stream.data, u8(i))
	}
	testing.expect(t, !state.load(plugin, &foreign_stream.input), "a foreign blob was accepted")

	// Right magic, truncated body.
	short_stream: Memory_Stream
	memory_stream_init(&short_stream, 64)
	defer memory_stream_destroy(&short_stream)
	testing.expect(t, state.save(plugin, &short_stream.out), "state.save failed")
	resize(&short_stream.data, len(short_stream.data) - 4)
	testing.expect(t, !state.load(plugin, &short_stream.input), "a truncated blob was accepted")
}

// -- .sy1 loading ------------------------------------------------------------

SY1_TEXT :: "Synth1 test patch\r\ncolor=default\r\nver=113\r\n0,1\r\n19,40\r\n21,37\r\n29,120\r\n94,4\r\n"

@(test)
test_preset_load_puts_sy1_values_into_the_params :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	preset := preset_of(plugin)
	testing.expect(t, preset != nil, "no preset-load extension")
	params := params_of(plugin)

	path := "build/clap_test_patch.sy1"
	testing.expect(
		t,
		os.write_entire_file(path, transmute([]byte)string(SY1_TEXT)) == nil,
		"could not write the test patch",
	)
	defer os.remove(path)

	testing.expect(
		t,
		preset.from_location(plugin, clap.PRESET_DISCOVERY_LOCATION_FILE, "build/clap_test_patch.sy1", nil),
		"preset load failed",
	)

	expected, err := patch.parse_sy1(transmute([]byte)string(SY1_TEXT))
	testing.expect_value(t, err, patch.Sy1_Error.None)

	for index in 0 ..< patch.PARAMETER_COUNT {
		value: f64
		testing.expect(t, params.get_value(plugin, clap.Id(index), &value), "get_value failed")
		testing.expect_value(t, int(value), expected.values[index])
	}

	// The records the file carries, checked explicitly: a parameter the patch
	// names, and one it omits which must fall back to the reference default.
	value: f64
	params.get_value(plugin, 19, &value)
	testing.expect_value(t, value, 40.0)
	params.get_value(plugin, 94, &value)
	testing.expect_value(t, value, 4.0)
	params.get_value(plugin, 2, &value)
	testing.expect_value(t, value, f64(patch.PARAMETERS[2].default))

}

@(test)
test_preset_load_rejects_bad_input :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	preset := preset_of(plugin)

	testing.expect(
		t,
		!preset.from_location(plugin, clap.PRESET_DISCOVERY_LOCATION_FILE, "build/no-such-file.sy1", nil),
		"a missing file was accepted",
	)
	// A .sy1 is a single-patch file, so a load key names nothing.
	testing.expect(
		t,
		!preset.from_location(
			plugin,
			clap.PRESET_DISCOVERY_LOCATION_FILE,
			"build/clap_test_patch.sy1",
			"key",
		),
		"a load key was accepted",
	)
	// Only files; this plugin is not a preset container.
	testing.expect(
		t,
		!preset.from_location(plugin, clap.PRESET_DISCOVERY_LOCATION_PLUGIN, nil, nil),
		"a non-file location kind was accepted",
	)
}

// A patch loaded while the plugin is active must reach the audio thread, which
// only adopts a staged set at the top of a block.
@(test)
test_preset_load_while_active_reaches_the_engine :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	path := "build/clap_test_active.sy1"
	testing.expect(
		t,
		os.write_entire_file(path, transmute([]byte)string(SY1_TEXT)) == nil,
		"could not write the test patch",
	)
	defer os.remove(path)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	preset := preset_of(plugin)
	testing.expect(
		t,
		preset.from_location(
			plugin,
			clap.PRESET_DISCOVERY_LOCATION_FILE,
			"build/clap_test_active.sy1",
			nil,
		),
		"preset load failed",
	)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	run_block(plugin, &render, &input, &output)

	s := synth.synth_of(plugin)
	testing.expect(t, s != nil, "no plugin state")
	// Parameter 0 is the oscillator 1 shape; the patch sets it to 1 where the
	// reference default is 2.
	testing.expect_value(t, s.values[0], i32(1))
	testing.expect_value(t, s.values[19], i32(40))

	// The host is told about the new values on that same block.
	testing.expect_value(t, output.count, patch.PARAMETER_COUNT)
}

// Parameter 94 sizes the voice pool, which is allocated in activate(). A change
// while active must not resize it: process() is not allowed to allocate.
@(test)
test_polyphony_change_does_not_resize_the_pool_while_active :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	plugin.start_processing(plugin)

	s := synth.synth_of(plugin)
	pool := len(s.eng.voices)
	testing.expect(t, pool > 0, "no voices were allocated")

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	event := param_event(0, 94, 1)
	input_push(&input, &event)
	run_block(plugin, &render, &input, &output)

	testing.expect_value(t, len(s.eng.voices), pool)
	testing.expect_value(t, s.eng.params.polyphony, pool)

	plugin.stop_processing(plugin)
	plugin.deactivate(plugin)

	// After a restart the new polyphony takes effect.
	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "reactivate failed")
	defer plugin.deactivate(plugin)
	testing.expect_value(t, len(s.eng.voices), 1)
}

// -- host notification and text conversion -----------------------------------
//
// The tests below were written against the failures clap-validator 0.4.1 found
// in the first cut of this plugin: `param-conversions` and the three
// `state-reproducibility` cases. They reproduce what that host does, so the
// defects cannot come back without a red test here.

// A host that records the parameter rescan requests the plugin makes. The
// counters live in the struct rather than in a package variable so the test
// runner can keep running tests in parallel.
Recording_Host :: struct {
	host:         clap.Host,
	params:       clap.Host_Params,
	rescan_calls: int,
	rescan_flags: u32,
}

recording_host_init :: proc(h: ^Recording_Host) {
	h.rescan_calls = 0
	h.rescan_flags = 0
	h.params = clap.Host_Params {
		rescan = proc "c" (host: ^clap.Host, flags: u32) {
			r := (^Recording_Host)(host.host_data)
			r.rescan_calls += 1
			r.rescan_flags |= flags
		},
		clear = proc "c" (host: ^clap.Host, param_id: clap.Id, flags: u32) {},
		request_flush = proc "c" (host: ^clap.Host) {},
	}
	h.host = clap.Host {
		clap_version = clap.VERSION,
		host_data = h,
		name = "clap_tests",
		vendor = "quesynth",
		url = "",
		version = "0.1.0",
		get_extension = proc "c" (host: ^clap.Host, extension_id: cstring) -> rawptr {
			if host == nil || extension_id == nil {
				return nil
			}
			r := (^Recording_Host)(host.host_data)
			if string(extension_id) == clap.EXT_PARAMS {
				return &r.params
			}
			return nil
		},
		request_restart = proc "c" (host: ^clap.Host) {},
		request_process = proc "c" (host: ^clap.Host) {},
		request_callback = proc "c" (host: ^clap.Host) {},
	}
}

make_plugin_with_host :: proc(t: ^testing.T, host: ^clap.Host) -> ^clap.Plugin {
	plugin := synth.FACTORY.create_plugin(&synth.FACTORY, host, synth.PLUGIN_ID)
	testing.expect(t, plugin != nil, "factory did not create the plugin")
	if plugin == nil {
		return nil
	}
	testing.expect(t, plugin.init(plugin), "plugin.init failed")
	return plugin
}

// A value the plugin changed on the main thread is invisible to the host until
// it is told to look again: params.h scenario I ("Loading a preset") says to
// call clap_host_params.rescan(). Without this the host keeps showing, saving
// and automating the values from before the load.
@(test)
test_state_load_asks_the_host_to_rescan_values :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	recorder: Recording_Host
	recording_host_init(&recorder)

	plugin := make_plugin_with_host(t, &recorder.host)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	state := state_of(plugin)

	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	// Save a blob that differs from where the parameters are left afterwards,
	// so the load really does change something.
	set := param_event(0, 19, 100)
	input_push(&input, &set)
	params.flush(plugin, &input.list, &output.list)

	stream: Memory_Stream
	memory_stream_init(&stream, 7)
	defer memory_stream_destroy(&stream)
	testing.expect(t, state.save(plugin, &stream.out), "state.save failed")

	input.count = 0
	input.used = 0
	scribble := param_event(0, 19, 3)
	input_push(&input, &scribble)
	params.flush(plugin, &input.list, &output.list)

	before := recorder.rescan_calls
	testing.expect(t, state.load(plugin, &stream.input), "state.load failed")

	testing.expect(
		t,
		recorder.rescan_calls > before,
		"state.load changed the parameters without asking the host to rescan them",
	)
	testing.expect(
		t,
		recorder.rescan_flags & clap.PARAM_RESCAN_VALUES != 0,
		"the rescan request did not include CLAP_PARAM_RESCAN_VALUES",
	)

	value: f64
	testing.expect(t, params.get_value(plugin, 19, &value), "get_value failed")
	testing.expect_value(t, value, 100.0)
}

@(test)
test_preset_load_asks_the_host_to_rescan_values :: proc(t: ^testing.T) {
	recorder: Recording_Host
	recording_host_init(&recorder)

	plugin := make_plugin_with_host(t, &recorder.host)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	path := "build/clap_test_rescan.sy1"
	testing.expect(
		t,
		os.write_entire_file(path, transmute([]byte)string(SY1_TEXT)) == nil,
		"could not write the test patch",
	)
	defer os.remove(path)

	preset := preset_of(plugin)
	testing.expect(
		t,
		preset.from_location(plugin, clap.PRESET_DISCOVERY_LOCATION_FILE, "build/clap_test_rescan.sy1", nil),
		"preset load failed",
	)

	testing.expect(
		t,
		recorder.rescan_calls > 0,
		"the preset load changed the parameters without asking the host to rescan them",
	)
	testing.expect(
		t,
		recorder.rescan_flags & clap.PARAM_RESCAN_VALUES != 0,
		"the rescan request did not include CLAP_PARAM_RESCAN_VALUES",
	)
}

// A failed load must not tell the host that anything changed.
@(test)
test_a_rejected_state_blob_does_not_ask_for_a_rescan :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	recorder: Recording_Host
	recording_host_init(&recorder)

	plugin := make_plugin_with_host(t, &recorder.host)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	state := state_of(plugin)

	foreign_stream: Memory_Stream
	memory_stream_init(&foreign_stream, 64)
	defer memory_stream_destroy(&foreign_stream)
	for i in 0 ..< 12 + patch.PARAMETER_COUNT * 4 {
		append(&foreign_stream.data, u8(i))
	}
	testing.expect(t, !state.load(plugin, &foreign_stream.input), "a foreign blob was accepted")
	testing.expect_value(t, recorder.rescan_calls, 0)
}

// The sweep clap-validator's `param-conversions` performs: walk the advertised
// range, turn the value into text, turn that text back into a value, and turn
// that value into text again. Both strings come from the plugin, so they have
// to agree, and the second parse has to land on the same value as the first.
@(test)
test_param_text_conversions_are_consistent :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)

	first: [clap.NAME_SIZE]u8
	second: [clap.NAME_SIZE]u8

	STEPS :: 41

	for index in 0 ..< patch.PARAMETER_COUNT {
		info: clap.Param_Info
		testing.expect(t, params.get_info(plugin, u32(index), &info), "get_info failed")

		for step in 0 ..< STEPS {
			value :=
				info.min_value +
				(info.max_value - info.min_value) * (f64(step) / f64(STEPS - 1))

			if !params.value_to_text(plugin, clap.Id(index), value, raw_data(first[:]), len(first)) {
				testing.expectf(t, false, "value_to_text failed for parameter %d at %f", index, value)
				continue
			}
			starting_text := string(cstring(&first[0]))

			reconverted: f64
			if !params.text_to_value(plugin, clap.Id(index), cstring(&first[0]), &reconverted) {
				testing.expectf(
					t,
					false,
					"text_to_value failed for parameter %d (%s) on its own text %q",
					index,
					patch.PARAMETERS[index].name,
					starting_text,
				)
				continue
			}

			if !params.value_to_text(
				plugin,
				clap.Id(index),
				reconverted,
				raw_data(second[:]),
				len(second),
			) {
				testing.expectf(t, false, "repeat value_to_text failed for parameter %d", index)
				continue
			}
			reconverted_text := string(cstring(&second[0]))

			testing.expectf(
				t,
				starting_text == reconverted_text,
				"parameter %d (%s): %f -> %q -> %f -> %q is not consistent",
				index,
				patch.PARAMETERS[index].name,
				value,
				starting_text,
				reconverted,
				reconverted_text,
			)

			final: f64
			testing.expect(
				t,
				params.text_to_value(plugin, clap.Id(index), cstring(&second[0]), &final),
				"repeat text_to_value failed",
			)
			testing.expectf(
				t,
				final == reconverted,
				"parameter %d (%s): parsing %q twice gave %f then %f",
				index,
				patch.PARAMETERS[index].name,
				reconverted_text,
				reconverted,
				final,
			)
		}
	}
}

// The text a direct-index parameter shows is the reference plugin's own display
// string, so parsing it has to return the state that shows it -- not the number
// the string happens to spell.
@(test)
test_text_to_value_reads_the_measured_display :: proc(t: ^testing.T) {
	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	out: f64

	// Parameter 2 is a direct state index whose state 3 displays "-58".
	testing.expect(t, !patch.PARAMETERS[2].display_keyed, "parameter 2 changed kind")
	testing.expect_value(t, patch.parameter_states(2)[3].display, "-58")
	testing.expect(t, params.text_to_value(plugin, 2, "-58", &out), "text_to_value failed")
	testing.expect_value(t, out, 3.0)

	// Parameter 5's displays are not numbers at all, and two states share the
	// display "50 : 50". The first is the answer: a parse has to be a function,
	// and taking the first keeps text -> value -> text stable.
	testing.expect_value(t, patch.parameter_states(5)[63].display, "50 : 50")
	testing.expect_value(t, patch.parameter_states(5)[64].display, "50 : 50")
	testing.expect(t, params.text_to_value(plugin, 5, "50 : 50", &out), "text_to_value failed")
	testing.expect_value(t, out, 63.0)

	// Parameter 90 shows words, and "center" belongs to one state only.
	testing.expect(t, params.text_to_value(plugin, 90, "center", &out), "text_to_value failed")
	testing.expect_value(t, out, 64.0)

	// A display-keyed parameter stores the number it shows, so the number is
	// what a parse must return: parameter 9 shows "-24".."24" and its state 29
	// displays "5", but the value that shows "5" is 5.
	testing.expect(t, patch.PARAMETERS[9].display_keyed, "parameter 9 changed kind")
	testing.expect_value(t, patch.parameter_states(9)[29].display, "5")
	testing.expect(t, params.text_to_value(plugin, 9, "5", &out), "text_to_value failed")
	testing.expect_value(t, out, 5.0)

	// Text no display and no integer explains is still refused.
	testing.expect(
		t,
		!params.text_to_value(plugin, 2, "not a number", &out),
		"text_to_value accepted nonsense",
	)
}

// clap-validator's `state-reproducibility-binary`: the blob saved after loading
// a blob has to be the same bytes.
@(test)
test_state_resave_is_byte_identical :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	state := state_of(plugin)

	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	for index in 0 ..< patch.PARAMETER_COUNT {
		info: clap.Param_Info
		params.get_info(plugin, u32(index), &info)
		value := int(info.min_value) + (index * 7) % (int(info.max_value) - int(info.min_value) + 1)
		event := param_event(0, u32(index), f64(value))
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			params.flush(plugin, &input.list, &output.list)
			input.count = 0
			input.used = 0
		}
	}
	params.flush(plugin, &input.list, &output.list)

	first: Memory_Stream
	memory_stream_init(&first, 23)
	defer memory_stream_destroy(&first)
	testing.expect(t, state.save(plugin, &first.out), "state.save failed")

	// Move everything, then load the blob back through a stream that only hands
	// over 17 bytes at a time, and save again.
	input.count = 0
	input.used = 0
	for index in 0 ..< patch.PARAMETER_COUNT {
		event := param_event(0, u32(index), 0)
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			params.flush(plugin, &input.list, &output.list)
			input.count = 0
			input.used = 0
		}
	}
	params.flush(plugin, &input.list, &output.list)

	first.chunk = 17
	testing.expect(t, state.load(plugin, &first.input), "state.load failed")

	second: Memory_Stream
	memory_stream_init(&second, 5)
	defer memory_stream_destroy(&second)
	testing.expect(t, state.save(plugin, &second.out), "state.save failed")

	testing.expect_value(t, len(second.data), len(first.data))
	if len(second.data) == len(first.data) {
		for i in 0 ..< len(first.data) {
			testing.expectf(
				t,
				first.data[i] == second.data[i],
				"resaved state differs at byte %d: %d vs %d",
				i,
				first.data[i],
				second.data[i],
			)
		}
	}
}

// The same round trip as the flush test, but the values are set the way a host
// sets them while the plugin is running: parameter events inside process().
@(test)
test_state_round_trip_after_process_events_while_active :: proc(t: ^testing.T) {
	TEST_CONTEXT = context

	plugin := make_plugin(t)
	if plugin == nil {return}
	defer plugin.destroy(plugin)

	params := params_of(plugin)
	state := state_of(plugin)

	testing.expect(t, plugin.activate(plugin, 48000, 1, BLOCK), "activate failed")
	defer plugin.deactivate(plugin)
	plugin.start_processing(plugin)
	defer plugin.stop_processing(plugin)

	render: Render
	render_init(&render)
	input: Input_Queue
	input_init(&input)
	output: Output_Queue
	output_init(&output)

	written: [patch.PARAMETER_COUNT]int
	for index in 0 ..< patch.PARAMETER_COUNT {
		info: clap.Param_Info
		params.get_info(plugin, u32(index), &info)
		value := int(info.default_value) == int(info.max_value) \
			? int(info.min_value) \
			: int(info.default_value) + 1
		written[index] = value
		event := param_event(0, u32(index), f64(value))
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			run_block(plugin, &render, &input, &output)
			input.count = 0
			input.used = 0
		}
	}
	run_block(plugin, &render, &input, &output)
	input.count = 0
	input.used = 0

	stream: Memory_Stream
	memory_stream_init(&stream, 7)
	defer memory_stream_destroy(&stream)
	testing.expect(t, state.save(plugin, &stream.out), "state.save failed")

	for index in 0 ..< patch.PARAMETER_COUNT {
		event := param_event(0, u32(index), 0)
		input_push(&input, &event)
		if input.count == MAX_EVENTS {
			run_block(plugin, &render, &input, &output)
			input.count = 0
			input.used = 0
		}
	}
	run_block(plugin, &render, &input, &output)

	testing.expect(t, state.load(plugin, &stream.input), "state.load failed")

	// Read back on the main thread, the way a host does, while the audio thread
	// has not yet adopted the set.
	for index in 0 ..< patch.PARAMETER_COUNT {
		value: f64
		testing.expect(t, params.get_value(plugin, clap.Id(index), &value), "get_value failed")
		testing.expectf(
			t,
			int(value) == written[index],
			"parameter %d read back %d, saved %d",
			index,
			int(value),
			written[index],
		)
	}

	// And after the audio thread picks it up, the engine agrees.
	input.count = 0
	input.used = 0
	run_block(plugin, &render, &input, &output)
	s := synth.synth_of(plugin)
	for index in 0 ..< patch.PARAMETER_COUNT {
		testing.expectf(
			t,
			int(s.values[index]) == written[index],
			"parameter %d reached the audio thread as %d, saved %d",
			index,
			int(s.values[index]),
			written[index],
		)
	}
}

// ---------------------------------------------------------------------------
// Advertised parameter ranges
//
// A CLAP host may clamp any value it is given to [min_value, max_value], and it
// reloads a session by writing the values it read back. So a stored .sy1 integer
// that falls outside the advertised range is not a cosmetic problem: the patch
// comes back changed. The two tests below pin the two halves of that -- that no
// real patch is outside the range, and that clamping cannot alter the sound
// where the reference itself clamps.
// ---------------------------------------------------------------------------

// Locate the patch corpus, if this machine has one.
//
// `odin test tests/clap` is run from the repository root, but the package also
// has to be testable from its own directory, so both are tried.
//
// It used to say the corpus was committed, and that is no longer true:
// patches/incoming is Synth1's own banks and other people's, and it was taken
// out of the repository over exactly that. `patches/*` is ignored and only
// patches/quesynth/factory.json is tracked.
//
// So the corpus is a thing a development machine may happen to have, and the
// test below is skipped where it does not. That is a real loss -- it is the
// check that a hundred and twenty-eight real patches all sit inside the ranges
// this plugin advertises -- and pretending otherwise by failing would only mean
// a suite that can never pass on a fresh clone.
corpus_root :: proc() -> (path: string, ok: bool) {
	for candidate in ([]string{"patches/incoming", "../../patches/incoming"}) {
		if os.exists(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// Every .sy1 under `dir`, recursively, appended to `out`.
collect_sy1 :: proc(dir: string, out: ^[dynamic]string) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		return
	}
	// The entries own their path strings, so the slice alone is not enough to
	// free; the test runner's leak check catches it if this is wrong.
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if entry.type == .Directory {
			collect_sy1(entry.fullpath, out)
			continue
		}
		if len(entry.name) > 4 && entry.name[len(entry.name) - 4:] == ".sy1" {
			append(out, strings.clone(entry.fullpath))
		}
	}
}

@(test)
test_every_committed_patch_value_is_inside_the_advertised_range :: proc(t: ^testing.T) {
	root, found := corpus_root()
	if !found {
		// Skipped, not failed. The corpus is not in the repository and cannot
		// be: see corpus_root. Logged so a run that skipped it does not read
		// like a run that checked it.
		log.info(
			"skipped: patches/incoming is not on this machine, so there is no corpus to check",
		)
		return
	}

	files: [dynamic]string
	defer {
		for f in files {delete(f)}
		delete(files)
	}
	collect_sy1(root, &files)

	// A silent pass over an empty corpus would make this test worthless, so
	// the count is asserted: a corpus that is present must be a real one.
	// 128 .sy1 files is what Synth1's own bank holds; more may be there.
	testing.expectf(t, len(files) >= 128, "found only %d .sy1 files under %s", len(files), root)
	checked := 0
	violations := 0
	for file in files {
		data, read_err := os.read_entire_file(file, context.allocator)
		if read_err != nil {
			testing.expectf(t, false, "cannot read %s: %v", file, read_err)
			continue
		}
		defer delete(data)

		parsed, parse_err := patch.parse_sy1(data)
		if parse_err != .None {
			testing.expectf(t, false, "cannot parse %s: %v", file, parse_err)
			continue
		}

		for index in 0 ..< patch.PARAMETER_COUNT {
			if !parsed.present[index] {
				continue
			}
			stored := parsed.values[index]
			lo := synth.param_min(index)
			hi := synth.param_max(index)
			checked += 1
			if stored < lo || stored > hi {
				violations += 1
				// Reported once per offending file/parameter pair; a blanket
				// count would hide which parameter regressed.
				testing.expectf(
					t,
					false,
					"%s stores %d at parameter %d (%s), outside the advertised %d..%d",
					file,
					stored,
					index,
					patch.PARAMETERS[index].name,
					lo,
					hi,
				)
			}
		}
	}

	testing.expectf(t, checked > 0, "no stored values were checked")
	testing.expectf(t, violations == 0, "%d stored values fall outside their advertised range", violations)
}

@(test)
test_advertised_range_contains_the_reference_default :: proc(t: ^testing.T) {
	// CLAP requires min_value <= default_value <= max_value, and the default is
	// measured from the reference and must never be rewritten to satisfy that.
	for index in 0 ..< patch.PARAMETER_COUNT {
		lo := synth.param_min(index)
		hi := synth.param_max(index)
		def := patch.PARAMETERS[index].default
		testing.expectf(
			t,
			lo <= def && def <= hi,
			"parameter %d (%s) default %d is outside %d..%d",
			index,
			patch.PARAMETERS[index].name,
			def,
			lo,
			hi,
		)
		testing.expectf(t, lo <= hi, "parameter %d has an empty range %d..%d", index, lo, hi)
	}
}

// Does the key that the advertised range ends at select the same state the
// reference saturates to?
//
// The reference saturates to the *last* state in the table. A direct-index
// parameter is addressed by position, so its last position is trivially the
// top. A display-keyed one is addressed by the number it shows, so this asks
// whether the last state also carries the largest display integer.
saturation_is_the_top_key :: proc(index: int) -> bool {
	p := patch.PARAMETERS[index]
	if p.continuous || p.state_count == 0 {
		return false
	}
	if !p.display_keyed {
		return true
	}

	states := patch.PARAMETER_STATES[p.state_offset:][:p.state_count]
	top, top_ok := patch.display_integer(states[len(states) - 1].display)
	if !top_ok {
		return false
	}
	for state in states {
		value, is_int := patch.display_integer(state.display)
		if is_int && value > top {
			return false
		}
	}
	return true
}

@(test)
test_clamping_to_the_advertised_range_is_lossless :: proc(t: ^testing.T) {
	// The property that matters: if a host clamps a value, the engine must still
	// resolve it to what the raw value meant.
	//
	// It holds for a .Clamp_To_Top parameter above its range, because every
	// integer past the table resolves to the top state and the top of the
	// advertised range is that same state. It cannot hold unconditionally for a
	// .Continue_Grid parameter, whose norms keep moving for ever while a CLAP
	// range is finite; for those the guarantee is that the range covers the
	// domain the reference itself produces, which the corpus test above pins.
	//
	// The sweep is 0..135, the non-negative part of the span
	// docs/synth1-param-encoding.md measured the stored-integer mapping over.
	// Negative stored values are deliberately excluded, and that is a measured
	// exclusion rather than a convenience: the same document records that "the
	// only parameter storing negative values is index 9, over -24..24, every one
	// of which lands on a state", and index 9's whole negative domain is inside
	// its advertised range, so nothing there is ever clamped. The exclusion is
	// load-bearing for a parameter like 97, whose two states display "0" and "1":
	// a raw -1 saturates at the top state while clamping it to 0 selects the
	// bottom one, so a negative would be lossy if the reference could store one.
	// Two parameters cannot have it, and they are named here rather than
	// silently skipped. Indices 42 and 47 (lfo1/lfo2 type) list their displays
	// out of order -- "0", "1", "5", "2", "3", "4" -- so the state the reference
	// saturates to is the one displaying "4" while the largest key in the table
	// is 5. A range ending at 4 would make the state displaying "5" unloadable,
	// and reachability wins: a patch storing 5 must still select that state,
	// whereas a value above 5 is something neither the reference nor a host can
	// produce. `saturation_is_the_top_key` recomputes the condition from the
	// table, so a regenerated table that reorders another parameter's displays
	// fails here instead of quietly joining the exception list.
	exceptions: [dynamic]int
	defer delete(exceptions)

	for index in 0 ..< patch.PARAMETER_COUNT {
		p := patch.PARAMETERS[index]
		if p.continuous || p.out_of_range != .Clamp_To_Top {
			continue
		}
		if !saturation_is_the_top_key(index) {
			append(&exceptions, index)
			continue
		}

		for raw in 0 ..= 135 {
			clamped, ok := synth.param_clamp(index, f64(raw))
			testing.expect(t, ok, "param_clamp rejected a finite value")

			raw_norm, raw_ok := patch.parameter_norm(index, raw)
			clamped_norm, clamped_ok := patch.parameter_norm(index, clamped)
			testing.expect(t, raw_ok && clamped_ok, "parameter_norm failed for a live parameter")
			testing.expectf(
				t,
				raw_norm == clamped_norm,
				"parameter %d (%s): raw %d resolves to %v but clamps to %d which resolves to %v",
				index,
				p.name,
				raw,
				raw_norm,
				clamped,
				clamped_norm,
			)
		}
	}

	testing.expectf(
		t,
		len(exceptions) == 2 && exceptions[0] == 42 && exceptions[1] == 47,
		"the set of parameters whose top state is not their largest key changed: %v",
		exceptions[:],
	)

	// What must still hold for those two: the largest key selects a real state,
	// so no patch value is lost on the way in.
	for index in exceptions {
		p := patch.PARAMETERS[index]
		states := patch.PARAMETER_STATES[p.state_offset:][:p.state_count]
		hi := synth.param_max(index)
		clamped, ok := synth.param_clamp(index, f64(hi))
		testing.expect(t, ok, "param_clamp rejected the top of the range")
		testing.expect_value(t, clamped, hi)

		hi_norm, _ := patch.parameter_norm(index, hi)
		matched := false
		for state in states {
			if state.norm == hi_norm {
				matched = true
				break
			}
		}
		testing.expectf(t, matched, "parameter %d top of range %d selects no state", index, hi)
	}

	// Index 9's measured negative domain, asserted rather than assumed: none of
	// it is clamped, so none of it can be lost.
	for raw in -24 ..= 24 {
		clamped, ok := synth.param_clamp(9, f64(raw))
		testing.expect(t, ok, "param_clamp rejected a finite value")
		testing.expectf(t, clamped == raw, "index 9 clamped %d to %d", raw, clamped)
	}
}

@(test)
test_range_ends_and_default_survive_clamping :: proc(t: ^testing.T) {
	// The three values a host is most likely to write back verbatim.
	for index in 0 ..< patch.PARAMETER_COUNT {
		lo := synth.param_min(index)
		hi := synth.param_max(index)
		for raw in ([]int{lo, hi, patch.PARAMETERS[index].default}) {
			clamped, ok := synth.param_clamp(index, f64(raw))
			testing.expect(t, ok, "param_clamp rejected a finite value")
			testing.expectf(
				t,
				clamped == raw,
				"parameter %d (%s): %d did not survive clamping, became %d (range %d..%d)",
				index,
				patch.PARAMETERS[index].name,
				raw,
				clamped,
				lo,
				hi,
			)

			raw_norm, _ := patch.parameter_norm(index, raw)
			clamped_norm, _ := patch.parameter_norm(index, clamped)
			testing.expect_value(t, clamped_norm, raw_norm)
		}
	}
}

@(test)
test_display_keyed_ranges_are_the_display_span :: proc(t: ^testing.T) {
	// The derivation itself, pinned on the parameters that motivated it, so a
	// future edit to the rule has to face these numbers.
	//
	// index 1 and 31 display "1".."4"; index 64 displays "1", "2", "4" and so
	// reaches 4 with only three states; index 9 displays "-24".."24"; index 46
	// displays "1".."7". The bottom stays at 0 for all of them except index 9,
	// whose own displays go lower.
	Expected :: struct {
		index: int,
		lo:    int,
		hi:    int,
	}
	cases := []Expected {
		{1, 0, 4},
		{9, -24, 24},
		{31, 0, 4},
		{41, 0, 7},
		{46, 0, 7},
		{64, 0, 4},
		// Direct-index parameters that run free past a sweep-truncated table.
		{33, 0, 127},
		{35, 0, 127},
		{85, 0, 127},
		// The measured default that sits one past the top state.
		{21, 0, 128},
		// Untouched: a direct index that saturates, and a continuous parameter.
		{0, 0, 3},
		{86, 0, 65535},
	}
	for c in cases {
		testing.expectf(
			t,
			synth.param_min(c.index) == c.lo && synth.param_max(c.index) == c.hi,
			"parameter %d (%s) advertises %d..%d, expected %d..%d",
			c.index,
			patch.PARAMETERS[c.index].name,
			synth.param_min(c.index),
			synth.param_max(c.index),
			c.lo,
			c.hi,
		)
	}
}
