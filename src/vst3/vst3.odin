package vst3

// Layer 1: the VST3 C API, transcribed.
//
// Steinberg publishes `vst3_c_api.h`, a plain C binding to what is otherwise a
// COM-style C++ API, and it is vendored at ext/vst3_c_api/. Odin cannot include
// a C header, so the parts this plugin uses are written out here. Nothing in
// this file makes decisions; it is the shape of the ABI and nothing else, which
// is why it is a separate package from hosts/vst3.
//
// Only what the plugin actually calls or implements is transcribed. The header
// is 3777 lines and describes some forty interfaces; a synthesiser with no
// custom editor needs six of them, and transcribing the rest would be more
// surface to get wrong for no gain.
//
// Two ABI details are load-bearing on Windows and both are checked against the
// header rather than assumed:
//
//   - `SMTG_STDMETHODCALLTYPE` is `__stdcall` when `_WIN32`, which on x86-64 is
//     the one calling convention there is. `"c"` is therefore correct for the
//     64-bit build, and would not be for a 32-bit one.
//   - `SMTG_COM_COMPATIBLE` is 1 when `_WIN32`, which changes how an interface
//     identifier's bytes are laid out. See `uid` below: get this wrong and the
//     host silently fails to find any interface, because `queryInterface`
//     compares raw bytes.

// -- primitives --------------------------------------------------------------

TUID :: [16]u8
Result :: i32

// From the header. `kResultOk` and `kResultTrue` are the same value, as are
// `kResultFalse` and `kNotImplemented`'s neighbours; they are kept separate
// here because the calls that return them mean different things by them.
RESULT_OK :: Result(0)
RESULT_TRUE :: Result(0)
RESULT_FALSE :: Result(1)
// Written through u32 because these are the Windows HRESULT failure codes, all
// of which have the high bit set and so do not fit an i32 literal.
NO_INTERFACE :: Result(transmute(i32)u32(0x80004002))
INVALID_ARGUMENT :: Result(transmute(i32)u32(0x80070057))
NOT_IMPLEMENTED :: Result(transmute(i32)u32(0x80004001))

String128 :: [128]u16 // UTF-16, as Steinberg_Vst_String128

// Build an interface identifier from the four 32-bit words the header writes
// them as.
//
// This is `SMTG_INLINE_UID` under `SMTG_COM_COMPATIBLE`, which is what Windows
// compiles. The byte order is not one rule but three: the first word goes out
// little-endian, the second swaps its 16-bit halves and writes each of those
// little-endian, and the last two go out big-endian. That is Microsoft's GUID
// layout, and it is why a UID transcribed by eye from the header's hex almost
// never works.
uid :: proc "contextless" (l1, l2, l3, l4: u32) -> TUID {
	return TUID {
		u8(l1 & 0xFF), u8((l1 >> 8) & 0xFF), u8((l1 >> 16) & 0xFF), u8((l1 >> 24) & 0xFF),
		u8((l2 >> 16) & 0xFF), u8((l2 >> 24) & 0xFF), u8(l2 & 0xFF), u8((l2 >> 8) & 0xFF),
		u8((l3 >> 24) & 0xFF), u8((l3 >> 16) & 0xFF), u8((l3 >> 8) & 0xFF), u8(l3 & 0xFF),
		u8((l4 >> 24) & 0xFF), u8((l4 >> 16) & 0xFF), u8((l4 >> 8) & 0xFF), u8(l4 & 0xFF),
	}
}

// The interfaces this plugin implements or is handed.
IID_FUNKNOWN :: proc "contextless" () -> TUID {return uid(0x00000000, 0x00000000, 0xC0000000, 0x00000046)}
IID_PLUGIN_BASE :: proc "contextless" () -> TUID {return uid(0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625)}
IID_PLUGIN_FACTORY :: proc "contextless" () -> TUID {return uid(0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F)}
IID_PLUGIN_FACTORY_2 :: proc "contextless" () -> TUID {return uid(0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB)}
IID_PLUGIN_FACTORY_3 :: proc "contextless" () -> TUID {return uid(0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931)}
IID_COMPONENT :: proc "contextless" () -> TUID {return uid(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802)}
IID_AUDIO_PROCESSOR :: proc "contextless" () -> TUID {return uid(0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D)}
IID_EDIT_CONTROLLER :: proc "contextless" () -> TUID {return uid(0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E)}
IID_BSTREAM :: proc "contextless" () -> TUID {return uid(0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B)}

// -- enumerations ------------------------------------------------------------

MEDIA_AUDIO :: i32(0)
MEDIA_EVENT :: i32(1)

DIRECTION_INPUT :: i32(0)
DIRECTION_OUTPUT :: i32(1)

BUS_MAIN :: i32(0)

BUS_FLAG_DEFAULT_ACTIVE :: u32(1)

// ParameterInfo flags.
PARAM_CAN_AUTOMATE :: i32(1 << 0)
PARAM_IS_READ_ONLY :: i32(1 << 1)
PARAM_IS_LIST :: i32(1 << 2)
PARAM_IS_HIDDEN :: i32(1 << 3)
PARAM_IS_PROGRAM_CHANGE :: i32(1 << 15)
PARAM_IS_BYPASS :: i32(1 << 16)

// Event types.
EVENT_NOTE_ON :: u16(0)
EVENT_NOTE_OFF :: u16(1)

SAMPLE_32 :: i32(0)
SAMPLE_64 :: i32(1)

SPEAKER_STEREO :: u64(3) // kSpeakerL | kSpeakerR

// IBStream seek modes.
SEEK_SET :: i32(0)
SEEK_CUR :: i32(1)
SEEK_END :: i32(2)

// Class categories, as the factory reports them. Byte arrays rather than
// strings because they are copied into fixed C char buffers.
CATEGORY_AUDIO_EFFECT :: "Audio Module Class"

// PClassInfo cardinality: the host may make as many as it likes.
CARDINALITY_MANY_INSTANCES :: i32(0x7FFFFFFF)

// PClassInfo2 classFlags for a component that is *not* split into separate
// processor and controller objects. `kSimpleModeSupported` is not it -- the
// relevant flag is `kDistributable`, and a single-component plugin must not set
// it, because it cannot be split across a network.
COMPONENT_FLAGS_NONE :: u32(0)

// -- structures --------------------------------------------------------------

Factory_Info :: struct {
	vendor: [64]u8,
	url:    [256]u8,
	email:  [128]u8,
	flags:  i32,
}

// Factory_Info.flags
FACTORY_NO_FLAGS :: i32(0)
FACTORY_CLASSES_DISCARDABLE :: i32(1 << 0)
FACTORY_LICENSE_CHECK :: i32(1 << 1)
FACTORY_COMPONENT_NON_DISCARDABLE :: i32(1 << 3)
FACTORY_UNICODE :: i32(1 << 4)

Class_Info :: struct {
	cid:         TUID,
	cardinality: i32,
	category:    [32]u8,
	name:        [64]u8,
}

Class_Info_2 :: struct {
	cid:            TUID,
	cardinality:    i32,
	category:       [32]u8,
	name:           [64]u8,
	class_flags:    u32,
	sub_categories: [128]u8,
	vendor:         [64]u8,
	version:        [64]u8,
	sdk_version:    [64]u8,
}

// The unicode form of Class_Info_2, which IPluginFactory3 reports. Same fields,
// with the three human-readable ones widened to UTF-16.
Class_Info_W :: struct {
	cid:            TUID,
	cardinality:    i32,
	category:       [32]u8,
	name:           [64]u16,
	class_flags:    u32,
	sub_categories: [128]u8,
	vendor:         [64]u16,
	version:        [64]u16,
	sdk_version:    [64]u16,
}

Bus_Info :: struct {
	media_type:    i32,
	direction:     i32,
	channel_count: i32,
	name:          String128,
	bus_type:      i32,
	flags:         u32,
}

Routing_Info :: struct {
	media_type: i32,
	bus_index:  i32,
	channel:    i32,
}

Parameter_Info :: struct {
	id:                       u32,
	title:                    String128,
	short_title:              String128,
	units:                    String128,
	step_count:               i32,
	default_normalized_value: f64,
	unit_id:                  i32,
	flags:                    i32,
}

Process_Setup :: struct {
	process_mode:          i32,
	symbolic_sample_size:  i32,
	max_samples_per_block: i32,
	sample_rate:           f64,
}

Audio_Bus_Buffers :: struct {
	num_channels:    i32,
	silence_flags:   u64,
	// The union of `Sample32**` and `Sample64**`. Which one it is is decided by
	// `Process_Data.symbolic_sample_size`, not by anything here.
	channel_buffers: ^[^]f32,
}

Process_Data :: struct {
	process_mode:            i32,
	symbolic_sample_size:    i32,
	num_samples:             i32,
	num_inputs:              i32,
	num_outputs:             i32,
	inputs:                  [^]Audio_Bus_Buffers,
	outputs:                 [^]Audio_Bus_Buffers,
	input_parameter_changes: ^IParameterChanges,
	output_parameter_changes: ^IParameterChanges,
	input_events:            ^IEventList,
	output_events:           ^IEventList,
	process_context:         rawptr,
}

Note_On_Event :: struct {
	channel:  i16,
	pitch:    i16,
	tuning:   f32,
	velocity: f32,
	length:   i32,
	note_id:  i32,
}

Note_Off_Event :: struct {
	channel:  i16,
	pitch:    i16,
	velocity: f32,
	note_id:  i32,
	tuning:   f32,
}

// The event union, sized and *aligned* to the largest member the header declares.
//
// Only the two note events are read. The union is a byte array rather than an
// Odin union so that a member this plugin does not understand cannot be a type
// error -- the host fills it, and may fill it with anything.
//
// The four bytes of explicit padding are the whole point of this comment.
// Several members of the union hold pointers -- `DataEvent.bytes`,
// `ChordEvent.text`, `NoteExpressionTextEvent.text` -- so on a 64-bit target
// the union is 8-byte aligned and begins at offset **24**, after `type` ends at
// 20. A byte array has alignment 1, so without this padding the payload sits at
// 20 and every note read out of it is four bytes early: the pitch comes from
// what was padding, and the instrument stays silent while looking perfectly
// healthy.
//
// It stayed hidden through a full round of testing because `tools/vst3host`
// *writes* events with the same struct it reads them with. Two sides sharing
// one wrong layout agree with each other exactly; only a real host disagrees.
// The assertions below are what a self-consistent test cannot give.
Event :: struct {
	bus_index:     i32,
	sample_offset: i32,
	ppq_position:  f64,
	flags:         u16,
	type:          u16,
	_padding:      [4]u8,
	payload:       [24]u8,
}

// Checked against the C layout rather than trusted. The union's largest member
// is NoteOnEvent at 20 bytes, rounded up to 24 by its own 8-byte alignment, so
// the whole event is 48.
#assert(offset_of(Event, ppq_position) == 8)
#assert(offset_of(Event, flags) == 16)
#assert(offset_of(Event, type) == 18)
#assert(offset_of(Event, payload) == 24)
#assert(size_of(Event) == 48)

// The two structures read out of that payload, checked the same way.
#assert(size_of(Note_On_Event) == 20)
#assert(size_of(Note_Off_Event) == 16)

// And the buffer descriptor, whose 8-byte silenceFlags forces four bytes of
// padding after numChannels in exactly the same manner.
#assert(offset_of(Audio_Bus_Buffers, silence_flags) == 8)
#assert(offset_of(Audio_Bus_Buffers, channel_buffers) == 16)

// Process_Data's pointers are 8-aligned, so numOutputs at 16 is followed by
// four bytes of padding before `inputs`.
#assert(offset_of(Process_Data, num_outputs) == 16)
#assert(offset_of(Process_Data, inputs) == 24)
#assert(offset_of(Process_Data, input_events) == 56)

// The two structures the *plugin* fills in for the host. A wrong offset here
// does not silence anything -- it makes the host read a parameter name or a bus
// width out of the wrong bytes, which looks like a cosmetic bug and is not one.
#assert(offset_of(Parameter_Info, step_count) == 772)
#assert(offset_of(Parameter_Info, default_normalized_value) == 776)
#assert(size_of(Parameter_Info) == 792)
#assert(offset_of(Bus_Info, name) == 12)
#assert(offset_of(Bus_Info, flags) == 272)

// -- interfaces --------------------------------------------------------------
//
// Every VST3 interface begins with FUnknown's three methods, so each vtable
// repeats them. That repetition is the ABI: a pointer to any of these is a
// valid `FUnknown*`.

IPluginFactory :: struct {
	vtbl: ^IPluginFactory_Vtbl,
}

IPluginFactory_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	get_factory_info: proc "c" (this: rawptr, info: ^Factory_Info) -> Result,
	count_classes:   proc "c" (this: rawptr) -> i32,
	get_class_info:  proc "c" (this: rawptr, index: i32, info: ^Class_Info) -> Result,
	create_instance: proc "c" (this: rawptr, cid: cstring, iid: cstring, obj: ^rawptr) -> Result,
}

IPluginFactory2_Vtbl :: struct {
	using base:       IPluginFactory_Vtbl,
	get_class_info_2: proc "c" (this: rawptr, index: i32, info: ^Class_Info_2) -> Result,
}

IPluginFactory3_Vtbl :: struct {
	using factory2:        IPluginFactory2_Vtbl,
	get_class_info_unicode: proc "c" (this: rawptr, index: i32, info: ^Class_Info_W) -> Result,
	set_host_context:      proc "c" (this: rawptr, context_: rawptr) -> Result,
}

IComponent_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	initialize:      proc "c" (this: rawptr, context_: rawptr) -> Result,
	terminate:       proc "c" (this: rawptr) -> Result,
	get_controller_class_id: proc "c" (this: rawptr, class_id: ^TUID) -> Result,
	set_io_mode:     proc "c" (this: rawptr, mode: i32) -> Result,
	get_bus_count:   proc "c" (this: rawptr, type: i32, dir: i32) -> i32,
	get_bus_info:    proc "c" (this: rawptr, type: i32, dir: i32, index: i32, bus: ^Bus_Info) -> Result,
	get_routing_info: proc "c" (this: rawptr, in_info: ^Routing_Info, out_info: ^Routing_Info) -> Result,
	activate_bus:    proc "c" (this: rawptr, type: i32, dir: i32, index: i32, state: u8) -> Result,
	set_active:      proc "c" (this: rawptr, state: u8) -> Result,
	set_state:       proc "c" (this: rawptr, state: ^IBStream) -> Result,
	get_state:       proc "c" (this: rawptr, state: ^IBStream) -> Result,
}

IAudioProcessor_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	set_bus_arrangements: proc "c" (this: rawptr, inputs: [^]u64, num_ins: i32, outputs: [^]u64, num_outs: i32) -> Result,
	get_bus_arrangement:  proc "c" (this: rawptr, dir: i32, index: i32, arr: ^u64) -> Result,
	can_process_sample_size: proc "c" (this: rawptr, symbolic_sample_size: i32) -> Result,
	get_latency_samples: proc "c" (this: rawptr) -> u32,
	setup_processing: proc "c" (this: rawptr, setup: ^Process_Setup) -> Result,
	set_processing:  proc "c" (this: rawptr, state: u8) -> Result,
	process:         proc "c" (this: rawptr, data: ^Process_Data) -> Result,
	get_tail_samples: proc "c" (this: rawptr) -> u32,
}

IEditController_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	initialize:      proc "c" (this: rawptr, context_: rawptr) -> Result,
	terminate:       proc "c" (this: rawptr) -> Result,
	set_component_state: proc "c" (this: rawptr, state: ^IBStream) -> Result,
	set_state:       proc "c" (this: rawptr, state: ^IBStream) -> Result,
	get_state:       proc "c" (this: rawptr, state: ^IBStream) -> Result,
	get_parameter_count: proc "c" (this: rawptr) -> i32,
	get_parameter_info: proc "c" (this: rawptr, index: i32, info: ^Parameter_Info) -> Result,
	get_param_string_by_value: proc "c" (this: rawptr, id: u32, normalized: f64, str: ^String128) -> Result,
	get_param_value_by_string: proc "c" (this: rawptr, id: u32, str: [^]u16, normalized: ^f64) -> Result,
	normalized_param_to_plain: proc "c" (this: rawptr, id: u32, normalized: f64) -> f64,
	plain_param_to_normalized: proc "c" (this: rawptr, id: u32, plain: f64) -> f64,
	get_param_normalized: proc "c" (this: rawptr, id: u32) -> f64,
	set_param_normalized: proc "c" (this: rawptr, id: u32, value: f64) -> Result,
	set_component_handler: proc "c" (this: rawptr, handler: rawptr) -> Result,
	create_view:     proc "c" (this: rawptr, name: cstring) -> rawptr,
}


// -- IPlugView ---------------------------------------------------------------
//
// The editor window, returned by IEditController::createView. The host owns a
// hole in its own window and hands it over in `attached`; everything drawn
// inside it is the plugin's business.
//
// `Steinberg_ViewRect` is the whole geometry vocabulary: left, top, right and
// bottom in pixels, relative to the parent. It is not a width and a height,
// and reading it as one puts the window in the wrong place.

View_Rect :: struct {
	left:   i32,
	top:    i32,
	right:  i32,
	bottom: i32,
}

#assert(size_of(View_Rect) == 16)

PLATFORM_TYPE_HWND :: "HWND"
PLATFORM_TYPE_NSVIEW :: "NSView"

IID_PLUG_VIEW :: proc "contextless" () -> TUID {return uid(0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29)}
IID_PLUG_FRAME :: proc "contextless" () -> TUID {return uid(0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3)}

IPlugView :: struct {
	vtbl: ^IPlugView_Vtbl,
}

IPlugView_Vtbl :: struct {
	query_interface:           proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:                   proc "c" (this: rawptr) -> u32,
	release:                   proc "c" (this: rawptr) -> u32,
	is_platform_type_supported: proc "c" (this: rawptr, type: cstring) -> Result,
	attached:                  proc "c" (this: rawptr, parent: rawptr, type: cstring) -> Result,
	removed:                   proc "c" (this: rawptr) -> Result,
	on_wheel:                  proc "c" (this: rawptr, distance: f32) -> Result,
	on_key_down:               proc "c" (this: rawptr, key: u16, key_code: i16, modifiers: i16) -> Result,
	on_key_up:                 proc "c" (this: rawptr, key: u16, key_code: i16, modifiers: i16) -> Result,
	get_size:                  proc "c" (this: rawptr, size: ^View_Rect) -> Result,
	on_size:                   proc "c" (this: rawptr, new_size: ^View_Rect) -> Result,
	on_focus:                  proc "c" (this: rawptr, state: u8) -> Result,
	set_frame:                 proc "c" (this: rawptr, frame: ^IPlugFrame) -> Result,
	can_resize:                proc "c" (this: rawptr) -> Result,
	check_size_constraint:     proc "c" (this: rawptr, rect: ^View_Rect) -> Result,
}

// The host's side of resizing: the plugin asks, the host moves the hole, and
// only then does the plugin resize itself to match.
IPlugFrame :: struct {
	vtbl: ^IPlugFrame_Vtbl,
}

IPlugFrame_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	resize_view:     proc "c" (this: rawptr, view: ^IPlugView, new_size: ^View_Rect) -> Result,
}

// Interfaces the *host* provides. Only ever called, never implemented here.

IBStream :: struct {
	vtbl: ^IBStream_Vtbl,
}

IBStream_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	read:            proc "c" (this: rawptr, buffer: rawptr, num_bytes: i32, num_read: ^i32) -> Result,
	write:           proc "c" (this: rawptr, buffer: rawptr, num_bytes: i32, num_written: ^i32) -> Result,
	seek:            proc "c" (this: rawptr, pos: i64, mode: i32, result: ^i64) -> Result,
	tell:            proc "c" (this: rawptr, pos: ^i64) -> Result,
}

IEventList :: struct {
	vtbl: ^IEventList_Vtbl,
}

IEventList_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	get_event_count: proc "c" (this: rawptr) -> i32,
	get_event:       proc "c" (this: rawptr, index: i32, e: ^Event) -> Result,
	add_event:       proc "c" (this: rawptr, e: ^Event) -> Result,
}

IParameterChanges :: struct {
	vtbl: ^IParameterChanges_Vtbl,
}

IParameterChanges_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	get_parameter_count: proc "c" (this: rawptr) -> i32,
	get_parameter_data:  proc "c" (this: rawptr, index: i32) -> ^IParamValueQueue,
	add_parameter_data:  proc "c" (this: rawptr, id: ^u32, index: ^i32) -> ^IParamValueQueue,
}

IParamValueQueue :: struct {
	vtbl: ^IParamValueQueue_Vtbl,
}

IParamValueQueue_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	get_parameter_id: proc "c" (this: rawptr) -> u32,
	get_point_count: proc "c" (this: rawptr) -> i32,
	get_point:       proc "c" (this: rawptr, index: i32, sample_offset: ^i32, value: ^f64) -> Result,
	add_point:       proc "c" (this: rawptr, sample_offset: i32, value: f64, index: ^i32) -> Result,
}

// -- helpers -----------------------------------------------------------------

// Copy an ASCII string into a fixed C char buffer, null-terminated and never
// overrunning. The buffers in PClassInfo and PFactoryInfo are all of this shape.
copy_ascii :: proc "contextless" (dst: []u8, src: string) {
	n := min(len(dst) - 1, len(src))
	for i in 0 ..< n {
		dst[i] = src[i]
	}
	for i in n ..< len(dst) {
		dst[i] = 0
	}
}

// The same into a String128, which is UTF-16.
//
// Only the ASCII range is handled, which is all this plugin's parameter names
// and units use. A byte above 127 would need real UTF-8 decoding and there is
// none to decode.
copy_utf16 :: proc "contextless" (dst: ^String128, src: string) {
	n := min(len(dst) - 1, len(src))
	for i in 0 ..< n {
		dst[i] = u16(src[i])
	}
	for i in n ..< len(dst) {
		dst[i] = 0
	}
}

// The same as copy_utf16, into any width of UTF-16 buffer. PClassInfoW's fields
// are 64 wide, not 128.
copy_utf16_slice :: proc "contextless" (dst: []u16, src: string) {
	n := min(len(dst) - 1, len(src))
	for i in 0 ..< n {
		dst[i] = u16(src[i])
	}
	for i in n ..< len(dst) {
		dst[i] = 0
	}
}

tuid_equal :: proc "contextless" (a: ^TUID, b: TUID) -> bool {
	b := b
	for i in 0 ..< 16 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// -- IComponentHandler -------------------------------------------------------
//
// The host's ear for edits made inside the plugin's own editor. A knob turned
// in the web view has to arrive here or the host never learns of it: no
// automation is recorded, the generic panel goes stale, and the session saves
// without the move.
//
// The three calls are a unit. `begin_edit` and `end_edit` bracket a gesture so
// that dragging a knob is recorded as one movement rather than as the few
// hundred samples of it that actually crossed the wire.

IID_COMPONENT_HANDLER :: proc "contextless" () -> TUID {return uid(0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6)}

IComponentHandler :: struct {
	vtbl: ^IComponentHandler_Vtbl,
}

IComponentHandler_Vtbl :: struct {
	query_interface:   proc "c" (this: rawptr, iid: ^TUID, obj: ^rawptr) -> Result,
	add_ref:           proc "c" (this: rawptr) -> u32,
	release:           proc "c" (this: rawptr) -> u32,
	begin_edit:        proc "c" (this: rawptr, id: u32) -> Result,
	perform_edit:      proc "c" (this: rawptr, id: u32, value_normalized: f64) -> Result,
	end_edit:          proc "c" (this: rawptr, id: u32) -> Result,
	restart_component: proc "c" (this: rawptr, flags: i32) -> Result,
}

// -- ProcessContext ----------------------------------------------------------
//
// Where the host says the transport is. The arpeggiator is the one part of this
// instrument that needs it: a step is a division of the beat, so without a
// tempo it would run at whatever default the engine was built with while the
// project played at something else.
//
// `state` is a bitfield and the tempo is only meaningful when kTempoValid is
// set in it. A host is entitled to leave the field as garbage otherwise, so it
// is checked rather than assumed.

PROCESS_CONTEXT_PLAYING :: u32(1 << 1)
PROCESS_CONTEXT_TEMPO_VALID :: u32(1 << 10)

Chord :: struct {
	key_note:   u8,
	root_note:  u8,
	chord_mask: i16,
}

Frame_Rate :: struct {
	frames_per_second: u32,
	flags:             u32,
}

Process_Context :: struct {
	state:                   u32,
	sample_rate:             f64,
	project_time_samples:    i64,
	system_time:             i64,
	continuous_time_samples: i64,
	project_time_music:      f64,
	bar_position_music:      f64,
	cycle_start_music:       f64,
	cycle_end_music:         f64,
	tempo:                   f64,
	time_sig_numerator:      i32,
	time_sig_denominator:    i32,
	chord:                   Chord,
	smpte_offset_subframes:  i32,
	frame_rate:              Frame_Rate,
	samples_to_next_clock:   i32,
}

// The layout is checked rather than trusted, for the reason the Event asserts
// below it exist: a field in the wrong place here reads the bar position as a
// tempo and the arpeggiator runs at a nonsense rate.
#assert(offset_of(Process_Context, tempo) == 72)
#assert(offset_of(Process_Context, chord) == 88)
