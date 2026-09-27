#+build darwin
package audiounit

// Audio Unit v2 C ABI, bound by hand.
//
// A modern AUv2 plugin is a plain C interface the host calls into: a factory
// function named in the bundle's Info.plist returns an
// AudioComponentPlugInInterface, whose Lookup hands the host a function pointer
// for each selector it asks for. Like src/vst3 and src/clap, this binds the
// structures and constants from their documented layouts rather than importing
// an SDK header. The host drives nearly everything; the few calls the unit makes
// back are CoreFoundation's (corefoundation.odin) and, for the editor, two of
// AudioToolbox's (audiotoolbox.odin), both frameworks every AU host has loaded.
//
// The layouts are from CoreAudioTypes.h and AudioUnitProperties.h. Where a
// constant's exact value could not be confirmed without the SDK it is marked so;
// the shapes that matter for loading and rendering -- the interface, the
// selectors, the stream format and the buffer list -- are the well-known ones.

// -- primitives --------------------------------------------------------------

OSStatus :: i32

NO_ERR :: OSStatus(0)
PARAM_ERR :: OSStatus(-50)
UNIMPLEMENTED_ERR :: OSStatus(-4)

// AudioUnit error codes (kAudioUnitErr_*), from AUComponent.h.
ERR_INVALID_PROPERTY :: OSStatus(-10879)
ERR_INVALID_PARAMETER :: OSStatus(-10878)
ERR_INVALID_ELEMENT :: OSStatus(-10877)
ERR_UNINITIALIZED :: OSStatus(-10867)
ERR_INVALID_SCOPE :: OSStatus(-10866)
ERR_TOO_MANY_FRAMES :: OSStatus(-10874)
ERR_INVALID_PROPERTY_VALUE :: OSStatus(-10851)
ERR_CANNOT_DO_IN_CURRENT_CONTEXT :: OSStatus(-10863)

Boolean :: u8

// A four-character code, e.g. 'aumu', as the big-endian integer the headers use.
fourcc :: proc "contextless" (s: string) -> u32 {
	if len(s) != 4 {
		return 0
	}
	return (u32(s[0]) << 24) | (u32(s[1]) << 16) | (u32(s[2]) << 8) | u32(s[3])
}

// -- component + interface ---------------------------------------------------

Audio_Component_Description :: struct {
	component_type:         u32,
	component_sub_type:     u32,
	component_manufacturer: u32,
	component_flags:        u32,
	component_flags_mask:   u32,
}

// A music device (an instrument). kAudioUnitType_MusicDevice = 'aumu'.
TYPE_MUSIC_DEVICE :: u32(0x61756D75)

// Each selector is looked up and called with the instance and its own arguments;
// the signatures differ per selector, so Lookup is typed to return a raw pointer
// that each call site casts to the right procedure.
Audio_Component_Method :: rawptr

Audio_Component_Plug_In_Interface :: struct {
	open:     proc "c" (self: rawptr, instance: rawptr) -> OSStatus,
	close:    proc "c" (self: rawptr) -> OSStatus,
	lookup:   proc "c" (selector: i16) -> Audio_Component_Method,
	reserved: rawptr,
}

// The factory returns a heap interface for each instance; the host frees it via
// Close. Signature: AudioComponentPlugInInterface* (*)(const AudioComponentDescription*).
Audio_Component_Factory_Function :: proc "c" (desc: ^Audio_Component_Description) -> ^Audio_Component_Plug_In_Interface

// -- selectors (kAudioUnit*Select, AUComponent.h) ----------------------------

SELECT_INITIALIZE :: i16(0x0001)
SELECT_UNINITIALIZE :: i16(0x0002)
SELECT_GET_PROPERTY_INFO :: i16(0x0003)
SELECT_GET_PROPERTY :: i16(0x0004)
SELECT_SET_PROPERTY :: i16(0x0005)
SELECT_ADD_PROPERTY_LISTENER :: i16(0x000A)
SELECT_REMOVE_PROPERTY_LISTENER :: i16(0x000B)
SELECT_REMOVE_PROPERTY_LISTENER_WITH_USER_DATA :: i16(0x0012)
SELECT_ADD_RENDER_NOTIFY :: i16(0x000F)
SELECT_REMOVE_RENDER_NOTIFY :: i16(0x0010)
SELECT_GET_PARAMETER :: i16(0x0006)
SELECT_SET_PARAMETER :: i16(0x0007)
SELECT_SCHEDULE_PARAMETERS :: i16(0x0011)
SELECT_RENDER :: i16(0x000E)
SELECT_RESET :: i16(0x0009)

// MusicDevice selectors (MusicDevice.h).
SELECT_MIDI_EVENT :: i16(0x0101)
SELECT_SYS_EX :: i16(0x0102)
SELECT_START_NOTE :: i16(0x0105)
SELECT_STOP_NOTE :: i16(0x0106)

// -- scopes and properties ---------------------------------------------------

SCOPE_GLOBAL :: u32(0)
SCOPE_INPUT :: u32(1)
SCOPE_OUTPUT :: u32(2)

Audio_Unit_Property_ID :: u32
Audio_Unit_Scope :: u32
Audio_Unit_Element :: u32

PROP_CLASS_INFO :: u32(0)
PROP_SAMPLE_RATE :: u32(2)
PROP_PARAMETER_LIST :: u32(3)
PROP_PARAMETER_INFO :: u32(4)
PROP_STREAM_FORMAT :: u32(8)
PROP_ELEMENT_COUNT :: u32(11)
PROP_LATENCY :: u32(12)
PROP_SUPPORTED_NUM_CHANNELS :: u32(13)
PROP_MAXIMUM_FRAMES_PER_SLICE :: u32(14)
PROP_TAIL_TIME :: u32(20)
PROP_LAST_RENDER_ERROR :: u32(22)
PROP_SET_RENDER_CALLBACK :: u32(23)
PROP_IN_PLACE_PROCESSING :: u32(29)
PROP_SHOULD_ALLOCATE_BUFFER :: u32(51)
PROP_PRESENT_PRESET :: u32(36)
PROP_COCOA_UI :: u32(31)

// AudioUnitCocoaViewInfo: where the view factory class lives and its name. The
// host sizes the class array as (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef),
// so one name makes it 16 bytes. Both references are +1; the host releases them.
Audio_Unit_Cocoa_View_Info :: struct {
	bundle_location: CF_URL_Ref,
	class_names:     [1]CF_String_Ref,
}
#assert(size_of(Audio_Unit_Cocoa_View_Info) == 16)

// -- audio formats and buffers (CoreAudioTypes.h) ----------------------------

Audio_Stream_Basic_Description :: struct {
	sample_rate:        f64,
	format_id:          u32,
	format_flags:       u32,
	bytes_per_packet:   u32,
	frames_per_packet:  u32,
	bytes_per_frame:    u32,
	channels_per_frame: u32,
	bits_per_channel:   u32,
	reserved:           u32,
}

FORMAT_LINEAR_PCM :: u32(0x6C70636D) // 'lpcm'

FORMAT_FLAG_IS_FLOAT :: u32(1 << 0)
FORMAT_FLAG_IS_PACKED :: u32(1 << 3)
FORMAT_FLAG_IS_NON_INTERLEAVED :: u32(1 << 5)

Audio_Buffer :: struct {
	number_channels: u32,
	data_byte_size:  u32,
	data:            rawptr,
}

// The header declares a trailing array of one; a real list carries
// number_buffers of them. The renderer indexes past the first with pointer
// arithmetic rather than trusting the fixed length.
Audio_Buffer_List :: struct {
	number_buffers: u32,
	buffers:        [1]Audio_Buffer,
}

Audio_Unit_Render_Action_Flags :: u32

// The timestamp is received but not read here, so its interior (SMPTETime and
// the rest) is left opaque; only that a pointer is passed matters.
Audio_Time_Stamp :: struct {
	sample_time: f64,
	host_time:   u64,
	rate_scalar: f64,
	word_clock:  u64,
	smpte:       [use_smpte_size]u8,
	flags:       u32,
	reserved:    u32,
}
use_smpte_size :: 24

// -- parameters (AudioUnitProperties.h) --------------------------------------

Audio_Unit_Parameter_ID :: u32
Audio_Unit_Parameter_Value :: f32

// The char[52] name is used rather than the CFStringRef alternative, so the unit
// needs no CoreFoundation and links against nothing.
Audio_Unit_Parameter_Info :: struct {
	name:           [52]u8,
	unit_name:      rawptr,
	clump_id:       u32,
	cf_name_string: rawptr,
	unit:           u32,
	min_value:      f32,
	max_value:      f32,
	default_value:  f32,
	flags:          u32,
}

PARAMETER_UNIT_INDEXED :: u32(1)
PARAMETER_UNIT_GENERIC :: u32(0)

PARAMETER_FLAG_IS_READABLE :: u32(1 << 30)
PARAMETER_FLAG_IS_WRITABLE :: u32(1 << 31)

// -- render callback ---------------------------------------------------------

AU_Render_Callback :: proc "c" (in_ref_con: rawptr, io_action_flags: ^Audio_Unit_Render_Action_Flags, in_time_stamp: rawptr, in_bus_number: u32, in_number_frames: u32, io_data: ^Audio_Buffer_List) -> OSStatus

AU_Render_Callback_Struct :: struct {
	input_proc:         AU_Render_Callback,
	input_proc_ref_con: rawptr,
}

// -- presets and property listeners ------------------------------------------

// AUPreset: a factory or user preset, identified by a number and a CFString name.
// A number of -1 means "no factory preset", which is what this unit reports.
AU_Preset :: struct {
	preset_number: i32,
	preset_name:   CF_String_Ref,
}

// AudioUnitPropertyListenerProc: the host registers one of these to hear when a
// property changes, and it is called back with the unit and the property that
// moved. auval registers one on MaximumFramesPerSlice and checks it fires.
Property_Listener_Proc :: proc "c" (ref_con: rawptr, unit: rawptr, prop_id: u32, scope: u32, element: u32)
