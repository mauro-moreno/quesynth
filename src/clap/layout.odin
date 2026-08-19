package clap

// Compile-time proof that these bindings have the layout the C headers declare.
//
// There is no C compiler in this build, so the expected numbers below are
// derived by hand from ext/clap/include/clap, field by field, using the 64-bit
// C rules the CLAP ABI assumes: 8-byte pointers and 8-byte-aligned `double` and
// `int64_t`, `char` arrays of alignment 1, and trailing padding to the struct's
// own alignment. Each derivation is written next to the assertion, so a reader
// can check the arithmetic against the header without running anything.
//
// The value of doing it this way is that a mistake is a build failure. A
// binding whose field order or padding drifts from the header does not
// misbehave subtly inside a host; it fails to compile here.

// clap_version_t: three uint32_t.
#assert(size_of(Version) == 12)
#assert(align_of(Version) == 4)

// clap_event_header_t: uint32, uint32, uint16, uint16, uint32.
#assert(size_of(Event_Header) == 16)
#assert(align_of(Event_Header) == 4)
#assert(offset_of(Event_Header, size) == 0)
#assert(offset_of(Event_Header, time) == 4)
#assert(offset_of(Event_Header, space_id) == 8)
#assert(offset_of(Event_Header, type) == 10)
#assert(offset_of(Event_Header, flags) == 12)

// clap_event_note_t: header(16), int32(16), three int16(20,22,24), then a
// double which realigns to 32. Trailing size 40.
#assert(offset_of(Event_Note, note_id) == 16)
#assert(offset_of(Event_Note, port_index) == 20)
#assert(offset_of(Event_Note, channel) == 22)
#assert(offset_of(Event_Note, key) == 24)
#assert(offset_of(Event_Note, velocity) == 32)
#assert(size_of(Event_Note) == 40)

// clap_event_param_value_t: header(16), clap_id(16), 4 bytes of padding before
// the cookie pointer(24), int32(32), three int16(36,38,40), double at 48.
#assert(offset_of(Event_Param_Value, param_id) == 16)
#assert(offset_of(Event_Param_Value, cookie) == 24)
#assert(offset_of(Event_Param_Value, note_id) == 32)
#assert(offset_of(Event_Param_Value, port_index) == 36)
#assert(offset_of(Event_Param_Value, channel) == 38)
#assert(offset_of(Event_Param_Value, key) == 40)
#assert(offset_of(Event_Param_Value, value) == 48)
#assert(size_of(Event_Param_Value) == 56)

// clap_event_midi_t: header(16), uint16(16), uint8[3](18..20), padded to the
// struct's 4-byte alignment.
#assert(offset_of(Event_Midi, port_index) == 16)
#assert(offset_of(Event_Midi, data) == 18)
#assert(size_of(Event_Midi) == 24)

// clap_event_transport_t: header(16), uint32(16), then nine int64/double fields
// from 24 to 95, int32 bar_number(96), two uint16(100,102).
#assert(offset_of(Event_Transport, flags) == 16)
#assert(offset_of(Event_Transport, song_pos_beats) == 24)
#assert(offset_of(Event_Transport, song_pos_seconds) == 32)
#assert(offset_of(Event_Transport, tempo) == 40)
#assert(offset_of(Event_Transport, tempo_inc) == 48)
#assert(offset_of(Event_Transport, loop_start_beats) == 56)
#assert(offset_of(Event_Transport, loop_end_beats) == 64)
#assert(offset_of(Event_Transport, loop_start_seconds) == 72)
#assert(offset_of(Event_Transport, loop_end_seconds) == 80)
#assert(offset_of(Event_Transport, bar_start) == 88)
#assert(offset_of(Event_Transport, bar_number) == 96)
#assert(offset_of(Event_Transport, tsig_num) == 100)
#assert(offset_of(Event_Transport, tsig_denom) == 102)
#assert(size_of(Event_Transport) == 104)

// clap_input_events_t: ctx + two function pointers.
#assert(size_of(Input_Events) == 24)
// clap_output_events_t: ctx + one function pointer.
#assert(size_of(Output_Events) == 16)

// clap_audio_buffer_t: two pointers, two uint32, one uint64 which realigns
// to 24.
#assert(offset_of(Audio_Buffer, data32) == 0)
#assert(offset_of(Audio_Buffer, data64) == 8)
#assert(offset_of(Audio_Buffer, channel_count) == 16)
#assert(offset_of(Audio_Buffer, latency) == 20)
#assert(offset_of(Audio_Buffer, constant_mask) == 24)
#assert(size_of(Audio_Buffer) == 32)

// clap_process_t: int64(0), uint32(8) then 4 bytes of padding before the
// transport pointer(16), two buffer pointers(24,32), two uint32(40,44), two
// event-list pointers(48,56).
#assert(offset_of(Process, steady_time) == 0)
#assert(offset_of(Process, frames_count) == 8)
#assert(offset_of(Process, transport) == 16)
#assert(offset_of(Process, audio_inputs) == 24)
#assert(offset_of(Process, audio_outputs) == 32)
#assert(offset_of(Process, audio_inputs_count) == 40)
#assert(offset_of(Process, audio_outputs_count) == 44)
#assert(offset_of(Process, in_events) == 48)
#assert(offset_of(Process, out_events) == 56)
#assert(size_of(Process) == 64)

// clap_istream_t / clap_ostream_t: ctx + one function pointer.
#assert(size_of(Istream) == 16)
#assert(size_of(Ostream) == 16)

// clap_host_t: version(0..11) then 4 bytes of padding before host_data(16),
// four strings(24..55), four function pointers(56..87).
#assert(offset_of(Host, clap_version) == 0)
#assert(offset_of(Host, host_data) == 16)
#assert(offset_of(Host, name) == 24)
#assert(offset_of(Host, vendor) == 32)
#assert(offset_of(Host, url) == 40)
#assert(offset_of(Host, version) == 48)
#assert(offset_of(Host, get_extension) == 56)
#assert(offset_of(Host, request_restart) == 64)
#assert(offset_of(Host, request_process) == 72)
#assert(offset_of(Host, request_callback) == 80)
#assert(size_of(Host) == 88)

// clap_plugin_descriptor_t: version(0..11), padding, then nine pointers.
#assert(offset_of(Plugin_Descriptor, id) == 16)
#assert(offset_of(Plugin_Descriptor, name) == 24)
#assert(offset_of(Plugin_Descriptor, vendor) == 32)
#assert(offset_of(Plugin_Descriptor, url) == 40)
#assert(offset_of(Plugin_Descriptor, manual_url) == 48)
#assert(offset_of(Plugin_Descriptor, support_url) == 56)
#assert(offset_of(Plugin_Descriptor, version) == 64)
#assert(offset_of(Plugin_Descriptor, description) == 72)
#assert(offset_of(Plugin_Descriptor, features) == 80)
#assert(size_of(Plugin_Descriptor) == 88)

// clap_plugin_t: two data pointers then ten function pointers.
#assert(offset_of(Plugin, desc) == 0)
#assert(offset_of(Plugin, plugin_data) == 8)
#assert(offset_of(Plugin, init) == 16)
#assert(offset_of(Plugin, destroy) == 24)
#assert(offset_of(Plugin, activate) == 32)
#assert(offset_of(Plugin, deactivate) == 40)
#assert(offset_of(Plugin, start_processing) == 48)
#assert(offset_of(Plugin, stop_processing) == 56)
#assert(offset_of(Plugin, reset) == 64)
#assert(offset_of(Plugin, process) == 72)
#assert(offset_of(Plugin, get_extension) == 80)
#assert(offset_of(Plugin, on_main_thread) == 88)
#assert(size_of(Plugin) == 96)

// clap_plugin_factory_t: three function pointers.
#assert(size_of(Plugin_Factory) == 24)

// clap_plugin_entry_t: version(0..11), padding, three function pointers.
#assert(offset_of(Plugin_Entry, init) == 16)
#assert(offset_of(Plugin_Entry, deinit) == 24)
#assert(offset_of(Plugin_Entry, get_factory) == 32)
#assert(size_of(Plugin_Entry) == 40)

// clap_audio_port_info_t: clap_id(0), char[256](4..259), two uint32(260,264),
// then a pointer which realigns to 272, clap_id(280), padded to 288.
#assert(offset_of(Audio_Port_Info, id) == 0)
#assert(offset_of(Audio_Port_Info, name) == 4)
#assert(offset_of(Audio_Port_Info, flags) == 260)
#assert(offset_of(Audio_Port_Info, channel_count) == 264)
#assert(offset_of(Audio_Port_Info, port_type) == 272)
#assert(offset_of(Audio_Port_Info, in_place_pair) == 280)
#assert(size_of(Audio_Port_Info) == 288)

// clap_note_port_info_t: three uint32 then char[256]; alignment 4.
#assert(offset_of(Note_Port_Info, id) == 0)
#assert(offset_of(Note_Port_Info, supported_dialects) == 4)
#assert(offset_of(Note_Port_Info, preferred_dialect) == 8)
#assert(offset_of(Note_Port_Info, name) == 12)
#assert(size_of(Note_Port_Info) == 268)

// clap_param_info_t: clap_id(0), flags(4), cookie(8), char[256](16..271),
// char[1024](272..1295), three doubles(1296,1304,1312).
#assert(offset_of(Param_Info, id) == 0)
#assert(offset_of(Param_Info, flags) == 4)
#assert(offset_of(Param_Info, cookie) == 8)
#assert(offset_of(Param_Info, name) == 16)
#assert(offset_of(Param_Info, module) == 272)
#assert(offset_of(Param_Info, min_value) == 1296)
#assert(offset_of(Param_Info, max_value) == 1304)
#assert(offset_of(Param_Info, default_value) == 1312)
#assert(size_of(Param_Info) == 1320)

// The extension vtables are function pointers only.
#assert(size_of(Plugin_Audio_Ports) == 16)
#assert(size_of(Plugin_Note_Ports) == 16)
#assert(size_of(Plugin_Params) == 48)
#assert(size_of(Plugin_State) == 16)
#assert(size_of(Plugin_Preset_Load) == 8)

// clap_host_params_t: three function pointers.
#assert(offset_of(Host_Params, rescan) == 0)
#assert(offset_of(Host_Params, clear) == 8)
#assert(offset_of(Host_Params, request_flush) == 16)
#assert(size_of(Host_Params) == 24)
