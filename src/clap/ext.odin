package clap

// The plugin-side extensions this synthesiser implements: audio-ports,
// note-ports, params, state, and preset-load.
//
// preset-load is here because loading a .sy1 file's values into the parameters
// is a required deliverable and CLAP already has the interface for it: the host
// hands the plugin a file path on the main thread and the plugin reads it. The
// alternative -- an extra exported C symbol of our own invention -- would be a
// private protocol no real host could drive.
//
// The host-side halves of these extensions are not bound: the plugin reports
// parameter changes through the output event queue it is already given, and
// needs no callback into the host to do it.

// -- audio ports -------------------------------------------------------------

EXT_AUDIO_PORTS :: "clap.audio-ports"

PORT_MONO :: "mono"
PORT_STEREO :: "stereo"

AUDIO_PORT_IS_MAIN :: u32(1 << 0)
AUDIO_PORT_SUPPORTS_64BITS :: u32(1 << 1)
AUDIO_PORT_PREFERS_64BITS :: u32(1 << 2)
AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE :: u32(1 << 3)

// clap_audio_port_info_t
Audio_Port_Info :: struct {
	id:            Id,
	name:          [NAME_SIZE]u8,
	flags:         u32,
	channel_count: u32,
	port_type:     cstring,
	in_place_pair: Id,
}

// clap_plugin_audio_ports_t
Plugin_Audio_Ports :: struct {
	count: proc "c" (plugin: ^Plugin, is_input: bool) -> u32,
	get:   proc "c" (
		plugin: ^Plugin,
		index: u32,
		is_input: bool,
		info: ^Audio_Port_Info,
	) -> bool,
}

// -- note ports --------------------------------------------------------------

EXT_NOTE_PORTS :: "clap.note-ports"

// clap_note_dialect
NOTE_DIALECT_CLAP :: u32(1 << 0)
NOTE_DIALECT_MIDI :: u32(1 << 1)
NOTE_DIALECT_MIDI_MPE :: u32(1 << 2)
NOTE_DIALECT_MIDI2 :: u32(1 << 3)

// clap_note_port_info_t
Note_Port_Info :: struct {
	id:                 Id,
	supported_dialects: u32,
	preferred_dialect:  u32,
	name:               [NAME_SIZE]u8,
}

// clap_plugin_note_ports_t
Plugin_Note_Ports :: struct {
	count: proc "c" (plugin: ^Plugin, is_input: bool) -> u32,
	get:   proc "c" (
		plugin: ^Plugin,
		index: u32,
		is_input: bool,
		info: ^Note_Port_Info,
	) -> bool,
}

// -- params ------------------------------------------------------------------

EXT_PARAMS :: "clap.params"

// clap_param_info_flags
PARAM_IS_STEPPED :: u32(1 << 0)
PARAM_IS_PERIODIC :: u32(1 << 1)
PARAM_IS_HIDDEN :: u32(1 << 2)
PARAM_IS_READONLY :: u32(1 << 3)
PARAM_IS_BYPASS :: u32(1 << 4)
PARAM_IS_AUTOMATABLE :: u32(1 << 5)
PARAM_IS_MODULATABLE :: u32(1 << 10)
PARAM_REQUIRES_PROCESS :: u32(1 << 15)
PARAM_IS_ENUM :: u32(1 << 16)

// clap_param_info_t
Param_Info :: struct {
	id:            Id,
	flags:         u32,
	cookie:        rawptr,
	name:          [NAME_SIZE]u8,
	module:        [PATH_SIZE]u8,
	min_value:     f64,
	max_value:     f64,
	default_value: f64,
}

// clap_plugin_params_t
Plugin_Params :: struct {
	count:         proc "c" (plugin: ^Plugin) -> u32,
	get_info:      proc "c" (plugin: ^Plugin, param_index: u32, param_info: ^Param_Info) -> bool,
	get_value:     proc "c" (plugin: ^Plugin, param_id: Id, out_value: ^f64) -> bool,
	value_to_text: proc "c" (
		plugin: ^Plugin,
		param_id: Id,
		value: f64,
		out_buffer: [^]u8,
		out_buffer_capacity: u32,
	) -> bool,
	text_to_value: proc "c" (
		plugin: ^Plugin,
		param_id: Id,
		param_value_text: cstring,
		out_value: ^f64,
	) -> bool,
	flush:         proc "c" (plugin: ^Plugin, input: ^Input_Events, output: ^Output_Events),
}

// clap_param_rescan_flags. Only the value rescan is used: this plugin's
// parameter list, ranges and text never change after the descriptor is built,
// so nothing here ever needs CLAP_PARAM_RESCAN_INFO or _ALL.
PARAM_RESCAN_VALUES :: u32(1 << 0)
PARAM_RESCAN_TEXT :: u32(1 << 1)
PARAM_RESCAN_INFO :: u32(1 << 2)
PARAM_RESCAN_ALL :: u32(1 << 3)

// clap_param_clear_flags
PARAM_CLEAR_ALL :: u32(1 << 0)
PARAM_CLEAR_AUTOMATIONS :: u32(1 << 1)
PARAM_CLEAR_MODULATIONS :: u32(1 << 2)

// clap_host_params_t
//
// The host half of the params extension. The plugin needs it because a value it
// changes by itself -- loading a state blob or a .sy1 file -- is otherwise
// invisible to the host: params.h scenario I ("Loading a preset") says to call
// rescan(). `clear` and `request_flush` are bound because they are part of the
// struct and leaving them out would put the wrong thing at the wrong offset the
// day one of them is needed.
Host_Params :: struct {
	rescan:        proc "c" (host: ^Host, flags: u32),
	clear:         proc "c" (host: ^Host, param_id: Id, flags: u32),
	request_flush: proc "c" (host: ^Host),
}

// -- state -------------------------------------------------------------------

EXT_STATE :: "clap.state"

// clap_plugin_state_t
Plugin_State :: struct {
	save: proc "c" (plugin: ^Plugin, stream: ^Ostream) -> bool,
	load: proc "c" (plugin: ^Plugin, stream: ^Istream) -> bool,
}

// -- preset load -------------------------------------------------------------

EXT_PRESET_LOAD :: "clap.preset-load/2"
EXT_PRESET_LOAD_COMPAT :: "clap.preset-load.draft/2"

// clap_preset_discovery_location_kind. A .sy1 patch is a file on disk, so FILE
// is the only kind this plugin accepts.
PRESET_DISCOVERY_LOCATION_FILE :: u32(0)
PRESET_DISCOVERY_LOCATION_PLUGIN :: u32(1)

// clap_plugin_preset_load_t
Plugin_Preset_Load :: struct {
	from_location: proc "c" (
		plugin: ^Plugin,
		location_kind: u32,
		location: cstring,
		load_key: cstring,
	) -> bool,
}
