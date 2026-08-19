package clap

// Hand-written Odin bindings for the parts of the CLAP 1.2.10 C API this
// project uses. The headers are at ext/clap/include/clap; nothing here is
// generated, and there is deliberately no C or C++ translation unit anywhere in
// the build. CLAP is a pure C API with no library to link against: a plugin is
// a shared object exporting one `clap_entry` symbol whose type is a plain
// struct of function pointers, so a binding is all that is needed.
//
// Only what the plugin and the host tool actually call is bound. The rest of
// the API -- gui, latency, thread pools, preset discovery providers, MIDI2,
// surround -- is absent on purpose rather than by oversight.
//
// Every struct below is laid out to match its header declaration exactly. The
// layouts are asserted at compile time in layout.odin, with the offsets derived
// field by field from the header rather than measured from this file, so a
// binding that drifts from the C declaration fails the build instead of
// corrupting a host's memory.
//
// Calling convention: CLAP_ABI is __cdecl on Windows and the platform default
// elsewhere, which is what Odin's `proc "c"` produces on every target here.

// -- version -----------------------------------------------------------------

// clap_version_t
Version :: struct {
	major:    u32,
	minor:    u32,
	revision: u32,
}

// CLAP_VERSION_MAJOR/MINOR/REVISION from version.h.
VERSION_MAJOR :: 1
VERSION_MINOR :: 2
VERSION_REVISION :: 10

VERSION :: Version{VERSION_MAJOR, VERSION_MINOR, VERSION_REVISION}

// clap_version_is_compatible: versions 0.x.y were the development stage.
version_is_compatible :: proc "contextless" (v: Version) -> bool {
	return v.major >= 1
}

// clap_id, CLAP_INVALID_ID
Id :: u32
INVALID_ID :: Id(max(u32))

// clap_beattime / clap_sectime
Beat_Time :: i64
Sec_Time :: i64

// -- string sizes ------------------------------------------------------------

NAME_SIZE :: 256
PATH_SIZE :: 1024

// -- events ------------------------------------------------------------------

// clap_event_header_t
Event_Header :: struct {
	size:     u32,
	time:     u32,
	space_id: u16,
	type:     u16,
	flags:    u32,
}

CORE_EVENT_SPACE_ID :: u16(0)

// clap_event_flags
EVENT_IS_LIVE :: u32(1 << 0)
EVENT_DONT_RECORD :: u32(1 << 1)

// Event types. Only the ones this plugin reads or writes are named.
EVENT_NOTE_ON :: u16(0)
EVENT_NOTE_OFF :: u16(1)
EVENT_NOTE_CHOKE :: u16(2)
EVENT_NOTE_END :: u16(3)
EVENT_PARAM_VALUE :: u16(5)
EVENT_TRANSPORT :: u16(9)
EVENT_MIDI :: u16(10)

// clap_event_note_t
Event_Note :: struct {
	header:     Event_Header,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	velocity:   f64,
}

// clap_event_param_value_t
Event_Param_Value :: struct {
	header:     Event_Header,
	param_id:   Id,
	cookie:     rawptr,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	value:      f64,
}

// clap_event_midi_t
Event_Midi :: struct {
	header:     Event_Header,
	port_index: u16,
	data:       [3]u8,
}

// clap_transport_flags
TRANSPORT_HAS_TEMPO :: u32(1 << 0)
TRANSPORT_HAS_BEATS_TIMELINE :: u32(1 << 1)
TRANSPORT_HAS_SECONDS_TIMELINE :: u32(1 << 2)
TRANSPORT_HAS_TIME_SIGNATURE :: u32(1 << 3)
TRANSPORT_IS_PLAYING :: u32(1 << 4)
TRANSPORT_IS_RECORDING :: u32(1 << 5)
TRANSPORT_IS_LOOP_ACTIVE :: u32(1 << 6)
TRANSPORT_IS_WITHIN_PRE_ROLL :: u32(1 << 7)

// clap_event_transport_t.
//
// Bound because `Process` carries a pointer to it and a pointer field cannot be
// typed without the type. This plugin does not consume transport information:
// it has no host-tempo-dependent behaviour it is required to expose, and the
// engine's own tempo defaults to 120 BPM.
Event_Transport :: struct {
	header:             Event_Header,
	flags:              u32,
	song_pos_beats:     Beat_Time,
	song_pos_seconds:   Sec_Time,
	tempo:              f64,
	tempo_inc:          f64,
	loop_start_beats:   Beat_Time,
	loop_end_beats:     Beat_Time,
	loop_start_seconds: Sec_Time,
	loop_end_seconds:   Sec_Time,
	bar_start:          Beat_Time,
	bar_number:         i32,
	tsig_num:           u16,
	tsig_denom:         u16,
}

// clap_input_events_t
Input_Events :: struct {
	ctx:  rawptr,
	size: proc "c" (list: ^Input_Events) -> u32,
	get:  proc "c" (list: ^Input_Events, index: u32) -> ^Event_Header,
}

// clap_output_events_t
Output_Events :: struct {
	ctx:      rawptr,
	try_push: proc "c" (list: ^Output_Events, event: ^Event_Header) -> bool,
}

// -- audio buffers and process -----------------------------------------------

// clap_audio_buffer_t
Audio_Buffer :: struct {
	data32:        [^][^]f32,
	data64:        [^][^]f64,
	channel_count: u32,
	latency:       u32,
	constant_mask: u64,
}

// clap_process_status
Process_Status :: i32

PROCESS_ERROR :: Process_Status(0)
PROCESS_CONTINUE :: Process_Status(1)
PROCESS_CONTINUE_IF_NOT_QUIET :: Process_Status(2)
PROCESS_TAIL :: Process_Status(3)
PROCESS_SLEEP :: Process_Status(4)

// clap_process_t
Process :: struct {
	steady_time:         i64,
	frames_count:        u32,
	transport:           ^Event_Transport,
	audio_inputs:        [^]Audio_Buffer,
	audio_outputs:       [^]Audio_Buffer,
	audio_inputs_count:  u32,
	audio_outputs_count: u32,
	in_events:           ^Input_Events,
	out_events:          ^Output_Events,
}

// -- streams -----------------------------------------------------------------

// clap_istream_t. `read` returns the number of bytes read; 0 is end of file and
// -1 a read error, so a caller must loop.
Istream :: struct {
	ctx:  rawptr,
	read: proc "c" (stream: ^Istream, buffer: rawptr, size: u64) -> i64,
}

// clap_ostream_t. `write` returns the number of bytes written, -1 on error.
Ostream :: struct {
	ctx:   rawptr,
	write: proc "c" (stream: ^Ostream, buffer: rawptr, size: u64) -> i64,
}

// -- host --------------------------------------------------------------------

// clap_host_t
Host :: struct {
	clap_version:     Version,
	host_data:        rawptr,
	name:             cstring,
	vendor:           cstring,
	url:              cstring,
	version:          cstring,
	get_extension:    proc "c" (host: ^Host, extension_id: cstring) -> rawptr,
	request_restart:  proc "c" (host: ^Host),
	request_process:  proc "c" (host: ^Host),
	request_callback: proc "c" (host: ^Host),
}

// -- plugin ------------------------------------------------------------------

// Plugin feature strings from plugin-features.h; only the ones this plugin
// advertises.
PLUGIN_FEATURE_INSTRUMENT :: "instrument"
PLUGIN_FEATURE_SYNTHESIZER :: "synthesizer"
PLUGIN_FEATURE_STEREO :: "stereo"

// clap_plugin_descriptor_t
Plugin_Descriptor :: struct {
	clap_version: Version,
	id:           cstring,
	name:         cstring,
	vendor:       cstring,
	url:          cstring,
	manual_url:   cstring,
	support_url:  cstring,
	version:      cstring,
	description:  cstring,
	// Null-terminated array of feature strings.
	features:     [^]cstring,
}

// clap_plugin_t
Plugin :: struct {
	desc:             ^Plugin_Descriptor,
	plugin_data:      rawptr,
	init:             proc "c" (plugin: ^Plugin) -> bool,
	destroy:          proc "c" (plugin: ^Plugin),
	activate:         proc "c" (
		plugin: ^Plugin,
		sample_rate: f64,
		min_frames_count: u32,
		max_frames_count: u32,
	) -> bool,
	deactivate:       proc "c" (plugin: ^Plugin),
	start_processing: proc "c" (plugin: ^Plugin) -> bool,
	stop_processing:  proc "c" (plugin: ^Plugin),
	reset:            proc "c" (plugin: ^Plugin),
	process:          proc "c" (plugin: ^Plugin, process: ^Process) -> Process_Status,
	get_extension:    proc "c" (plugin: ^Plugin, id: cstring) -> rawptr,
	on_main_thread:   proc "c" (plugin: ^Plugin),
}

// -- factory and entry -------------------------------------------------------

PLUGIN_FACTORY_ID :: "clap.plugin-factory"

// clap_plugin_factory_t
Plugin_Factory :: struct {
	get_plugin_count:      proc "c" (factory: ^Plugin_Factory) -> u32,
	get_plugin_descriptor: proc "c" (
		factory: ^Plugin_Factory,
		index: u32,
	) -> ^Plugin_Descriptor,
	create_plugin:         proc "c" (
		factory: ^Plugin_Factory,
		host: ^Host,
		plugin_id: cstring,
	) -> ^Plugin,
}

// clap_plugin_entry_t. The one symbol a CLAP shared library must export.
Plugin_Entry :: struct {
	clap_version: Version,
	init:         proc "c" (plugin_path: cstring) -> bool,
	deinit:       proc "c" (),
	get_factory:  proc "c" (factory_id: cstring) -> rawptr,
}
