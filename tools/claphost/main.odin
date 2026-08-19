package claphost

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/clap"
import "../../src/patch"

// A minimal standalone CLAP host.
//
// It exists to prove the plugin from the outside: it knows nothing about
// hosts/clap beyond the CLAP API and the .sy1 format, loads the shared
// library by path, and drives it through the same calls a DAW would. Anything
// it can do, a real host can do.
//
// Usage:
//     claphost <plugin.clap> <patch.sy1>
//
// It loads the library, resolves clap_entry, creates the plugin through the
// factory, activates it, asks the plugin to load the patch through the
// preset-load extension, checks that all 99 parameters arrived, plays a middle
// C for about two seconds and reports the peak. Any failure exits non-zero.

SAMPLE_RATE :: 48000
BLOCK_FRAMES :: 512
RENDER_SECONDS :: 2
MIDDLE_C :: 60
VELOCITY :: 1.0

// The peak below which the render is not audibly a note. The verification
// contract for this tool is that a real patch produces more than this.
MIN_AUDIBLE_PEAK :: f32(0.0001)

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("error: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// -- event queues ------------------------------------------------------------

MAX_EVENTS :: 256
EVENT_BYTES :: 8192

// The host's input event list. `list` is first so the address handed to the
// plugin is the address of a real clap_input_events, and `ctx` points back here
// the way CLAP intends.
Input_Queue :: struct {
	list:    clap.Input_Events,
	buffer:  [EVENT_BYTES]u8,
	offsets: [MAX_EVENTS]int,
	count:   int,
	used:    int,
}

input_queue_init :: proc(q: ^Input_Queue) {
	q.count = 0
	q.used = 0
	q.list = clap.Input_Events {
		ctx = q,
		size = proc "c" (list: ^clap.Input_Events) -> u32 {
			q := (^Input_Queue)(list.ctx)
			return u32(q.count)
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

input_queue_clear :: proc(q: ^Input_Queue) {
	q.count = 0
	q.used = 0
}

// Events are copied into one byte buffer, each aligned to 8, which is the
// alignment of the widest field any of them has.
input_queue_push :: proc(q: ^Input_Queue, event: ^$T) -> bool {
	size := size_of(T)
	offset := (q.used + 7) & ~int(7)
	if q.count >= MAX_EVENTS || offset + size > EVENT_BYTES {
		return false
	}
	source := (^[size_of(T)]u8)(event)
	for i in 0 ..< size {
		q.buffer[offset + i] = source[i]
	}
	q.offsets[q.count] = offset
	q.count += 1
	q.used = offset + size
	return true
}

// The host's output event list. The plugin reports parameter changes here; the
// count is kept so the run can say whether that happened.
Output_Queue :: struct {
	list:  clap.Output_Events,
	count: int,
}

output_queue_init :: proc(q: ^Output_Queue) {
	q.count = 0
	q.list = clap.Output_Events {
		ctx = q,
		try_push = proc "c" (list: ^clap.Output_Events, event: ^clap.Event_Header) -> bool {
			q := (^Output_Queue)(list.ctx)
			q.count += 1
			return true
		},
	}
}

// -- host --------------------------------------------------------------------

make_host :: proc() -> clap.Host {
	return clap.Host {
		clap_version = clap.VERSION,
		host_data = nil,
		name = "claphost",
		vendor = "quesynth",
		url = "",
		version = "0.1.0",
		// This host offers no extensions and never asks the plugin to restart.
		get_extension = proc "c" (host: ^clap.Host, extension_id: cstring) -> rawptr {
			return nil
		},
		request_restart = proc "c" (host: ^clap.Host) {},
		request_process = proc "c" (host: ^clap.Host) {},
		request_callback = proc "c" (host: ^clap.Host) {},
	}
}

// -- main --------------------------------------------------------------------

main :: proc() {
	args := os.args
	if len(args) != 3 {
		fmt.eprintfln("usage: %s <plugin.clap> <patch.sy1>", len(args) > 0 ? args[0] : "claphost")
		os.exit(2)
	}
	plugin_path := args[1]
	patch_path := args[2]

	// The host parses the patch too, but only so it can check the plugin's
	// parameters against it afterwards. Loading it into the plugin is the
	// plugin's job.
	patch_bytes, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fail("cannot read patch %s: %v", patch_path, read_err)
	}
	defer delete(patch_bytes)
	expected, parse_err := patch.parse_sy1(patch_bytes)
	if parse_err != .None {
		fail("cannot parse %s: %v", patch_path, parse_err)
	}

	library, library_ok := dynlib.load_library(plugin_path)
	if !library_ok {
		fail("cannot load %s: %s", plugin_path, dynlib.last_error())
	}

	symbol, symbol_ok := dynlib.symbol_address(library, "clap_entry")
	if !symbol_ok || symbol == nil {
		fail("%s exports no clap_entry symbol: %s", plugin_path, dynlib.last_error())
	}
	entry := (^clap.Plugin_Entry)(symbol)

	if !clap.version_is_compatible(entry.clap_version) {
		fail(
			"plugin reports incompatible CLAP version %d.%d.%d",
			entry.clap_version.major,
			entry.clap_version.minor,
			entry.clap_version.revision,
		)
	}
	if entry.init == nil || entry.get_factory == nil {
		fail("clap_entry is missing init or get_factory")
	}

	plugin_path_c := strings.clone_to_cstring(plugin_path)
	defer delete(plugin_path_c)
	if !entry.init(plugin_path_c) {
		fail("clap_entry.init failed")
	}

	factory_id := strings.clone_to_cstring(clap.PLUGIN_FACTORY_ID)
	defer delete(factory_id)
	factory := (^clap.Plugin_Factory)(entry.get_factory(factory_id))
	if factory == nil {
		fail("plugin offers no %s", clap.PLUGIN_FACTORY_ID)
	}

	plugin_count := factory.get_plugin_count(factory)
	if plugin_count < 1 {
		fail("factory advertises no plugins")
	}
	descriptor := factory.get_plugin_descriptor(factory, 0)
	if descriptor == nil || descriptor.id == nil {
		fail("factory returned no descriptor for index 0")
	}

	host := make_host()
	plugin := factory.create_plugin(factory, &host, descriptor.id)
	if plugin == nil {
		fail("factory could not create %s", descriptor.id)
	}
	if plugin.init == nil || !plugin.init(plugin) {
		fail("plugin.init failed")
	}

	// Extensions. All four the plugin promises are required here: a missing one
	// is a defect, not a degraded mode to paper over.
	params := (^clap.Plugin_Params)(plugin.get_extension(plugin, clap.EXT_PARAMS))
	if params == nil {
		fail("plugin does not implement %s", clap.EXT_PARAMS)
	}
	state := (^clap.Plugin_State)(plugin.get_extension(plugin, clap.EXT_STATE))
	if state == nil {
		fail("plugin does not implement %s", clap.EXT_STATE)
	}
	audio_ports := (^clap.Plugin_Audio_Ports)(plugin.get_extension(plugin, clap.EXT_AUDIO_PORTS))
	if audio_ports == nil {
		fail("plugin does not implement %s", clap.EXT_AUDIO_PORTS)
	}
	note_ports := (^clap.Plugin_Note_Ports)(plugin.get_extension(plugin, clap.EXT_NOTE_PORTS))
	if note_ports == nil {
		fail("plugin does not implement %s", clap.EXT_NOTE_PORTS)
	}
	preset_load := (^clap.Plugin_Preset_Load)(plugin.get_extension(plugin, clap.EXT_PRESET_LOAD))
	if preset_load == nil {
		fail("plugin does not implement %s", clap.EXT_PRESET_LOAD)
	}

	// The port layout this host is written for: one stereo output, one note
	// input.
	if audio_ports.count(plugin, false) != 1 || audio_ports.count(plugin, true) != 0 {
		fail("expected exactly one output audio port and no input port")
	}
	audio_info: clap.Audio_Port_Info
	if !audio_ports.get(plugin, 0, false, &audio_info) {
		fail("audio_ports.get failed for output port 0")
	}
	if audio_info.channel_count != 2 {
		fail("output port is not stereo: %d channels", audio_info.channel_count)
	}
	if note_ports.count(plugin, true) != 1 {
		fail("expected exactly one note input port")
	}

	if params.count(plugin) != u32(patch.PARAMETER_COUNT) {
		fail(
			"plugin exposes %d parameters, expected %d",
			params.count(plugin),
			patch.PARAMETER_COUNT,
		)
	}

	if !plugin.activate(plugin, f64(SAMPLE_RATE), 1, BLOCK_FRAMES) {
		fail("plugin.activate failed")
	}
	if !plugin.start_processing(plugin) {
		fail("plugin.start_processing failed")
	}

	// Ask the plugin to load the patch. This is the plugin reading the file,
	// not the host pushing values into it.
	patch_path_c := strings.clone_to_cstring(patch_path)
	defer delete(patch_path_c)
	if !preset_load.from_location(
		plugin,
		clap.PRESET_DISCOVERY_LOCATION_FILE,
		patch_path_c,
		nil,
	) {
		fail("preset_load.from_location failed for %s", patch_path)
	}

	// Every parameter must now read back the value the file holds. This is the
	// check that the patch actually landed rather than the plugin merely
	// claiming success.
	mismatches := 0
	for index in 0 ..< patch.PARAMETER_COUNT {
		value: f64
		if !params.get_value(plugin, clap.Id(index), &value) {
			fail("params.get_value failed for parameter %d", index)
		}
		if int(value) != expected.values[index] {
			fmt.eprintfln(
				"error: parameter %d (%s) is %d, patch says %d",
				index,
				patch.PARAMETERS[index].name,
				int(value),
				expected.values[index],
			)
			mismatches += 1
		}
	}
	if mismatches != 0 {
		fail("%d parameter(s) did not match %s", mismatches, patch_path)
	}

	// Buffers and event lists. Allocated once, before the render loop.
	left := make([]f32, BLOCK_FRAMES)
	defer delete(left)
	right := make([]f32, BLOCK_FRAMES)
	defer delete(right)
	channels := [2][^]f32{raw_data(left), raw_data(right)}
	output := clap.Audio_Buffer {
		data32        = raw_data(channels[:]),
		data64        = nil,
		channel_count = 2,
		latency       = 0,
		constant_mask = 0,
	}

	input_queue: Input_Queue
	input_queue_init(&input_queue)
	output_queue: Output_Queue
	output_queue_init(&output_queue)

	// Middle C at the very first frame of the render.
	note_on := clap.Event_Note {
		header = {
			size = size_of(clap.Event_Note),
			time = 0,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = clap.EVENT_NOTE_ON,
			flags = 0,
		},
		note_id = -1,
		port_index = 0,
		channel = 0,
		key = MIDDLE_C,
		velocity = VELOCITY,
	}
	if !input_queue_push(&input_queue, &note_on) {
		fail("could not queue the note on event")
	}

	total_frames := SAMPLE_RATE * RENDER_SECONDS
	peak: f32 = 0
	non_finite := 0
	rendered := 0
	steady: i64 = 0

	for rendered < total_frames {
		frames := min(BLOCK_FRAMES, total_frames - rendered)

		process := clap.Process {
			steady_time         = steady,
			frames_count        = u32(frames),
			transport           = nil,
			audio_inputs        = nil,
			audio_outputs       = &output,
			audio_inputs_count  = 0,
			audio_outputs_count = 1,
			in_events           = &input_queue.list,
			out_events          = &output_queue.list,
		}

		status := plugin.process(plugin, &process)
		if status == clap.PROCESS_ERROR {
			fail("plugin.process returned CLAP_PROCESS_ERROR at frame %d", rendered)
		}

		for i in 0 ..< frames {
			l := left[i]
			r := right[i]
			// A non-finite sample is a defect, so it is counted rather than
			// folded into the peak where a NaN would hide it.
			if l != l || r != r {
				non_finite += 1
				continue
			}
			if abs(l) > peak {peak = abs(l)}
			if abs(r) > peak {peak = abs(r)}
		}

		// The note on is only sent in the first block.
		input_queue_clear(&input_queue)
		rendered += frames
		steady += i64(frames)
	}

	plugin.stop_processing(plugin)
	plugin.deactivate(plugin)
	plugin.destroy(plugin)
	if entry.deinit != nil {
		entry.deinit()
	}

	if non_finite != 0 {
		fail("%d non-finite sample(s) in the render", non_finite)
	}

	name := strings.trim_space(expected.name)
	fmt.printfln(
		"claphost %s plugin=\"%s\" patch=%s \"%s\" frames=%d rate=%d params=%d paramevents=%d nonfinite=%d peak=%.6f",
		plugin_path,
		string(descriptor.name),
		patch_path,
		name,
		total_frames,
		SAMPLE_RATE,
		patch.PARAMETER_COUNT,
		output_queue.count,
		non_finite,
		peak,
	)

	if !(peak > MIN_AUDIBLE_PEAK) {
		fail("peak %.6f is not above %.6f: the plugin made no sound", peak, MIN_AUDIBLE_PEAK)
	}
}
