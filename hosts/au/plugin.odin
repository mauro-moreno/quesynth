#+build darwin
package synth_au

import "base:runtime"

import au "../../src/audiounit"
import "../../src/engine"
import "../../src/patch"

// Layer 2: the Audio Unit adapter, the macOS counterpart of hosts/clap and
// hosts/vst3. It is a shell around src/engine and owns nothing that makes sound:
// it answers the AU selectors a host calls, translates AU's parameter, MIDI and
// buffer conventions into the engine's, and nothing here allocates or locks on
// the render path once the unit is initialised.
//
// This is a foundation: it builds and loads as a music-device AU with parameters,
// MIDI input and stereo rendering. State save/restore (ClassInfo), factory
// presets and the WebKitGTK editor are not wired in yet, and it has not been run
// through auval or a DAW -- there is no macOS on the machine it was written on.
// What it has is a macOS CI build; the rest is the next increment.
//
// On macOS the editor is a WKWebView, not WebKitGTK, and its seam is
// hosts/panel/panel_macos.odin. Nothing here uses it yet: the unit does not
// answer kAudioUnitProperty_CocoaUI, so the host draws its generic view.

MANUFACTURER :: u32(0x51535954) // 'QSYT'
SUBTYPE :: u32(0x51737931) // 'Qsy1'

// The instance. The AudioComponentPlugInInterface is first, because the pointer
// the host is handed back from the factory is the address of this struct, and
// every selector is called with that same pointer as `self`.
AU :: struct {
	interface:    au.Audio_Component_Plug_In_Interface,
	instance:     rawptr,

	eng:          engine.Engine,
	values:       [PARAM_COUNT]i32,
	mirror:       patch.Patch,

	sample_rate:  f64,
	max_frames:   int,
	initialized:  bool,
	params_dirty: bool,

	// Buffers the unit renders into when the host asks it to supply its own --
	// an AudioBufferList arriving with null mData -- which is a render contract
	// auval exercises. Allocated in Initialize, sized to max_frames.
	scratch_left:  []f32,
	scratch_right: []f32,
	last_error:    au.OSStatus,

	// Property-change listeners the host registers. A small fixed set: a host
	// watches a handful of properties, not dozens.
	listeners:     [32]Listener,
}

Listener :: struct {
	prop:   u32,
	callback: au.Property_Listener_Proc,
	user:   rawptr,
	active: bool,
}

au_of :: proc "contextless" (self: rawptr) -> ^AU {
	return (^AU)(self)
}

// -- property listeners ------------------------------------------------------

au_add_property_listener :: proc "c" (self: rawptr, prop: u32, listener: au.Property_Listener_Proc, user: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil || listener == nil {
		return au.PARAM_ERR
	}
	for &l in s.listeners {
		if !l.active {
			l = Listener{prop = prop, callback = listener, user = user, active = true}
			return au.NO_ERR
		}
	}
	return au.NO_ERR
}

au_remove_property_listener :: proc "c" (self: rawptr, prop: u32, listener: au.Property_Listener_Proc) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	for &l in s.listeners {
		if l.active && l.prop == prop && l.callback == listener {
			l.active = false
		}
	}
	return au.NO_ERR
}

au_remove_property_listener_with_user_data :: proc "c" (self: rawptr, prop: u32, listener: au.Property_Listener_Proc, user: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	for &l in s.listeners {
		if l.active && l.prop == prop && l.callback == listener && l.user == user {
			l.active = false
		}
	}
	return au.NO_ERR
}

// Tell every listener watching this property that it changed.
notify_property :: proc "c" (s: ^AU, prop: u32, scope: u32, element: u32) {
	for &l in s.listeners {
		if l.active && l.prop == prop && l.callback != nil {
			l.callback(l.user, s.instance, prop, scope, element)
		}
	}
}

// -- parameter binding -------------------------------------------------------

apply_params :: proc(s: ^AU) {
	for i in 0 ..< PARAM_COUNT {
		s.mirror.values[i] = int(s.values[i])
		s.mirror.present[i] = true
	}
	params := engine.bind_patch(s.mirror)
	if len(s.eng.voices) > 0 {
		params.polyphony = len(s.eng.voices)
	}
	s.eng.patch = s.mirror
	s.eng.has_patch = true
	for i in 0 ..< 2 {
		if s.eng.params.midi_ctrl[i].cc != params.midi_ctrl[i].cc {
			s.eng.ctrl_value[i] = 0
		}
	}
	s.eng.params = params
	engine.engine_refresh_controllers(&s.eng)
}

// -- lifecycle selectors -----------------------------------------------------

au_open :: proc "c" (self: rawptr, instance: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	s.instance = instance
	return au.NO_ERR
}

au_close :: proc "c" (self: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.NO_ERR
	}
	context = runtime.default_context()
	if s.initialized {
		engine.engine_destroy(&s.eng)
	}
	delete(s.scratch_left)
	delete(s.scratch_right)
	free(s)
	return au.NO_ERR
}

au_initialize :: proc "c" (self: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	context = runtime.default_context()
	if s.sample_rate <= 0 {
		s.sample_rate = 44100
	}
	if s.max_frames <= 0 {
		s.max_frames = 1156
	}
	for i in 0 ..< PARAM_COUNT {
		s.mirror.values[i] = int(s.values[i])
		s.mirror.present[i] = true
	}
	engine.engine_load_patch(&s.eng, s.mirror, f32(s.sample_rate))
	delete(s.scratch_left)
	delete(s.scratch_right)
	s.scratch_left = make([]f32, s.max_frames)
	s.scratch_right = make([]f32, s.max_frames)
	s.params_dirty = false
	s.initialized = true
	return au.NO_ERR
}

au_uninitialize :: proc "c" (self: rawptr) -> au.OSStatus {
	s := au_of(self)
	if s == nil || !s.initialized {
		return au.NO_ERR
	}
	context = runtime.default_context()
	engine.engine_destroy(&s.eng)
	s.initialized = false
	return au.NO_ERR
}

au_reset :: proc "c" (self: rawptr, scope: u32, element: u32) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	for i in 0 ..< len(s.eng.voices) {
		s.eng.voices[i] = {}
	}
	s.eng.held_notes = 0
	s.eng.held_keys = {}
	s.eng.pitch_bend = 0
	return au.NO_ERR
}

// -- parameters --------------------------------------------------------------

au_get_parameter :: proc "c" (self: rawptr, param: u32, scope: u32, element: u32, out_value: ^f32) -> au.OSStatus {
	s := au_of(self)
	if s == nil || out_value == nil {
		return au.PARAM_ERR
	}
	if scope != au.SCOPE_GLOBAL || int(param) >= PARAM_COUNT {
		return au.ERR_INVALID_PARAMETER
	}
	out_value^ = f32(s.values[param])
	return au.NO_ERR
}

au_set_parameter :: proc "c" (self: rawptr, param: u32, scope: u32, element: u32, value: f32, offset: u32) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}
	if scope != au.SCOPE_GLOBAL || int(param) >= PARAM_COUNT {
		return au.ERR_INVALID_PARAMETER
	}
	stored := i32(param_clamp(int(param), value))
	if s.values[param] != stored {
		s.values[param] = stored
		s.params_dirty = true
	}
	return au.NO_ERR
}

// -- MIDI --------------------------------------------------------------------

MIDI_NOTE_OFF :: 0x80
MIDI_NOTE_ON :: 0x90
MIDI_CONTROL_CHANGE :: 0xB0
MIDI_PITCH_BEND :: 0xE0
MIDI_BEND_CENTRE :: 8192.0

au_midi_event :: proc "c" (self: rawptr, status_byte: u32, data1: u32, data2: u32, offset: u32) -> au.OSStatus {
	s := au_of(self)
	if s == nil || !s.initialized {
		return au.NO_ERR
	}
	context = runtime.default_context()
	status := int(status_byte) & 0xF0
	switch status {
	case MIDI_NOTE_ON:
		if data2 == 0 {
			engine.engine_note_off(&s.eng, int(data1))
		} else {
			engine.engine_note_on(&s.eng, int(data1), f32(data2) / 127.0)
		}
	case MIDI_NOTE_OFF:
		engine.engine_note_off(&s.eng, int(data1))
	case MIDI_CONTROL_CHANGE:
		engine.engine_control_change(&s.eng, int(data1), int(data2))
	case MIDI_PITCH_BEND:
		raw := int(data1) | (int(data2) << 7)
		engine.engine_set_pitch_bend(&s.eng, f32((f64(raw) - MIDI_BEND_CENTRE) / MIDI_BEND_CENTRE))
	}
	return au.NO_ERR
}

// -- render ------------------------------------------------------------------

au_render :: proc "c" (self: rawptr, flags: ^u32, timestamp: rawptr, bus: u32, frames: u32, data: ^au.Audio_Buffer_List) -> au.OSStatus {
	s := au_of(self)
	if s == nil || data == nil {
		return au.PARAM_ERR
	}
	context = runtime.default_context()
	if !s.initialized {
		s.last_error = au.ERR_UNINITIALIZED
		return au.ERR_UNINITIALIZED
	}

	if s.params_dirty {
		apply_params(s)
		s.params_dirty = false
	}

	// Rendering more than the agreed MaximumFramesPerSlice is an error, not
	// something to clamp: the host sized its buffers to that maximum, and auval
	// checks that the unit refuses an over-long block rather than truncating it.
	if int(frames) > s.max_frames {
		s.last_error = au.ERR_TOO_MANY_FRAMES
		return au.ERR_TOO_MANY_FRAMES
	}
	n := int(frames)

	// Two non-interleaved channel buffers. The host may hand over its own
	// buffers, or it may pass null mData and ask the unit to supply them -- both
	// are the render contract, and auval tests the second. When mData is null the
	// unit renders into its own scratch and hands back the pointer.
	if data.number_buffers < 2 {
		return au.PARAM_ERR
	}
	buffers := ([^]au.Audio_Buffer)(&data.buffers[0])
	left := ([^]f32)(buffers[0].data)
	if left == nil {
		left = raw_data(s.scratch_left)
		buffers[0].data = left
		buffers[0].data_byte_size = u32(frames) * 4
	}
	right := ([^]f32)(buffers[1].data)
	if right == nil {
		right = raw_data(s.scratch_right)
		buffers[1].data = right
		buffers[1].data_byte_size = u32(frames) * 4
	}
	if left == nil || right == nil {
		return au.PARAM_ERR
	}

	if n > 0 {
		engine.engine_process(&s.eng, left[:n], right[:n])
	}
	// Silence any frames beyond the clamp so a short block is a gap, not stale.
	for i in n ..< int(frames) {
		left[i] = 0
		right[i] = 0
	}
	return au.NO_ERR
}

// -- properties --------------------------------------------------------------

// -- class info (saved state) ------------------------------------------------

@(private = "file")
dict_set_number :: proc "c" (dict: rawptr, key_name: cstring, value: i32) {
	v := value
	key := au.CFStringCreateWithCString(nil, key_name, au.CF_STRING_ENCODING_UTF8)
	num := au.CFNumberCreate(nil, au.CF_NUMBER_SINT32_TYPE, &v)
	au.CFDictionarySetValue(dict, key, num)
	au.CFRelease(key)
	au.CFRelease(num)
}

@(private = "file")
dict_set_string :: proc "c" (dict: rawptr, key_name: cstring, value: cstring) {
	key := au.CFStringCreateWithCString(nil, key_name, au.CF_STRING_ENCODING_UTF8)
	val := au.CFStringCreateWithCString(nil, value, au.CF_STRING_ENCODING_UTF8)
	au.CFDictionarySetValue(dict, key, val)
	au.CFRelease(key)
	au.CFRelease(val)
}

// The unit's state as a CFDictionary the host can save and hand back: the
// component identity plus a data blob of the stored parameter integers. The
// caller owns the returned dictionary and releases it.
class_info_dict :: proc "c" (s: ^AU) -> au.CF_Dictionary_Ref {
	dict := au.CFDictionaryCreateMutable(nil, 0, &au.kCFTypeDictionaryKeyCallBacks, &au.kCFTypeDictionaryValueCallBacks)
	if dict == nil {
		return nil
	}
	dict_set_number(dict, "version", 0)
	dict_set_number(dict, "type", i32(au.TYPE_MUSIC_DEVICE))
	dict_set_number(dict, "subtype", i32(SUBTYPE))
	dict_set_number(dict, "manufacturer", i32(MANUFACTURER))
	dict_set_string(dict, "name", "Quesynth")

	key := au.CFStringCreateWithCString(nil, "data", au.CF_STRING_ENCODING_UTF8)
	data := au.CFDataCreate(nil, ([^]u8)(&s.values[0]), au.CF_Index(PARAM_COUNT * size_of(i32)))
	au.CFDictionarySetValue(dict, key, data)
	au.CFRelease(key)
	au.CFRelease(data)
	return dict
}

// Restore the parameter values from a state dictionary's data blob.
class_info_restore :: proc "c" (s: ^AU, dict: au.CF_Dictionary_Ref) {
	key := au.CFStringCreateWithCString(nil, "data", au.CF_STRING_ENCODING_UTF8)
	data := au.CFDictionaryGetValue(dict, key)
	au.CFRelease(key)
	if data == nil {
		return
	}
	ptr := au.CFDataGetBytePtr(data)
	n := int(au.CFDataGetLength(data))
	if ptr == nil || n < PARAM_COUNT * size_of(i32) {
		return
	}
	src := ([^]i32)(ptr)
	for i in 0 ..< PARAM_COUNT {
		s.values[i] = src[i]
	}
	s.params_dirty = true
}

// A stereo, non-interleaved, 32-bit float stream at the current rate: the layout
// engine_process already writes, so the host and the engine agree with no
// conversion.
stream_format :: proc "contextless" (s: ^AU) -> au.Audio_Stream_Basic_Description {
	rate := s.sample_rate
	if rate <= 0 {
		rate = 44100
	}
	return au.Audio_Stream_Basic_Description {
		sample_rate        = rate,
		format_id          = au.FORMAT_LINEAR_PCM,
		format_flags       = au.FORMAT_FLAG_IS_FLOAT | au.FORMAT_FLAG_IS_PACKED | au.FORMAT_FLAG_IS_NON_INTERLEAVED,
		bytes_per_packet   = 4,
		frames_per_packet  = 1,
		bytes_per_frame    = 4,
		channels_per_frame = 2,
		bits_per_channel   = 32,
		reserved           = 0,
	}
}

// {0 in, 2 out}: an instrument with one stereo output and no audio input.
Channel_Info :: struct {
	in_channels:  i16,
	out_channels: i16,
}

au_get_property_info :: proc "c" (self: rawptr, prop: u32, scope: u32, element: u32, out_size: ^u32, out_writable: ^au.Boolean) -> au.OSStatus {
	size := u32(0)
	writable := au.Boolean(0)
	status := au.NO_ERR

	switch prop {
	case au.PROP_STREAM_FORMAT:
		// Instrument: an output stream only. Refusing the input scope is what tells
		// a host there is no input to feed, so it does not try to set a render
		// callback for one.
		if scope == au.SCOPE_INPUT {
			return au.ERR_INVALID_SCOPE
		}
		size = size_of(au.Audio_Stream_Basic_Description)
		writable = 1
	case au.PROP_SAMPLE_RATE:
		size = size_of(f64)
		writable = 1
	case au.PROP_MAXIMUM_FRAMES_PER_SLICE:
		size = size_of(u32)
		writable = 1
	case au.PROP_ELEMENT_COUNT:
		size = size_of(u32)
	case au.PROP_LAST_RENDER_ERROR:
		size = size_of(au.OSStatus)
	case au.PROP_LATENCY, au.PROP_TAIL_TIME:
		size = size_of(f64)
	case au.PROP_IN_PLACE_PROCESSING:
		size = size_of(u32)
	case au.PROP_SUPPORTED_NUM_CHANNELS:
		size = size_of(Channel_Info)
	case au.PROP_PARAMETER_LIST:
		if scope == au.SCOPE_GLOBAL {
			size = u32(PARAM_COUNT) * size_of(au.Audio_Unit_Parameter_ID)
		} else {
			size = 0
		}
	case au.PROP_PARAMETER_INFO:
		size = size_of(au.Audio_Unit_Parameter_Info)
	case au.PROP_CLASS_INFO:
		size = size_of(au.CF_Dictionary_Ref)
		writable = 1
	case au.PROP_PRESENT_PRESET:
		size = size_of(au.AU_Preset)
		writable = 1
	case:
		status = au.ERR_INVALID_PROPERTY
	}

	if out_size != nil {
		out_size^ = size
	}
	if out_writable != nil {
		out_writable^ = writable
	}
	return status
}

au_get_property :: proc "c" (self: rawptr, prop: u32, scope: u32, element: u32, out_data: rawptr, io_size: ^u32) -> au.OSStatus {
	s := au_of(self)
	if s == nil || out_data == nil || io_size == nil {
		return au.PARAM_ERR
	}

	switch prop {
	case au.PROP_STREAM_FORMAT:
		if scope == au.SCOPE_INPUT {
			return au.ERR_INVALID_SCOPE
		}
		if io_size^ < size_of(au.Audio_Stream_Basic_Description) {
			return au.PARAM_ERR
		}
		(^au.Audio_Stream_Basic_Description)(out_data)^ = stream_format(s)
		io_size^ = size_of(au.Audio_Stream_Basic_Description)
		return au.NO_ERR
	case au.PROP_SAMPLE_RATE:
		rate := s.sample_rate
		if rate <= 0 {
			rate = 44100
		}
		(^f64)(out_data)^ = rate
		io_size^ = size_of(f64)
		return au.NO_ERR
	case au.PROP_MAXIMUM_FRAMES_PER_SLICE:
		(^u32)(out_data)^ = u32(s.max_frames if s.max_frames > 0 else 1156)
		io_size^ = size_of(u32)
		return au.NO_ERR
	case au.PROP_ELEMENT_COUNT:
		// One output element, no input elements: a music device.
		count := u32(0)
		if scope == au.SCOPE_OUTPUT || scope == au.SCOPE_GLOBAL {
			count = 1
		}
		(^u32)(out_data)^ = count
		io_size^ = size_of(u32)
		return au.NO_ERR
	case au.PROP_LAST_RENDER_ERROR:
		(^au.OSStatus)(out_data)^ = s.last_error
		s.last_error = au.NO_ERR
		io_size^ = size_of(au.OSStatus)
		return au.NO_ERR
	case au.PROP_LATENCY:
		(^f64)(out_data)^ = 0
		io_size^ = size_of(f64)
		return au.NO_ERR
	case au.PROP_TAIL_TIME:
		// A long release plus the delay line's worst case; a safe upper bound.
		(^f64)(out_data)^ = 45
		io_size^ = size_of(f64)
		return au.NO_ERR
	case au.PROP_IN_PLACE_PROCESSING:
		(^u32)(out_data)^ = 0
		io_size^ = size_of(u32)
		return au.NO_ERR
	case au.PROP_SUPPORTED_NUM_CHANNELS:
		if io_size^ < size_of(Channel_Info) {
			return au.PARAM_ERR
		}
		(^Channel_Info)(out_data)^ = Channel_Info{in_channels = 0, out_channels = 2}
		io_size^ = size_of(Channel_Info)
		return au.NO_ERR
	case au.PROP_PARAMETER_LIST:
		if scope != au.SCOPE_GLOBAL {
			io_size^ = 0
			return au.NO_ERR
		}
		need := u32(PARAM_COUNT) * size_of(au.Audio_Unit_Parameter_ID)
		if io_size^ < need {
			return au.PARAM_ERR
		}
		ids := ([^]au.Audio_Unit_Parameter_ID)(out_data)
		for i in 0 ..< PARAM_COUNT {
			ids[i] = au.Audio_Unit_Parameter_ID(i)
		}
		io_size^ = need
		return au.NO_ERR
	case au.PROP_PARAMETER_INFO:
		if scope != au.SCOPE_GLOBAL || int(element) >= PARAM_COUNT {
			return au.ERR_INVALID_PARAMETER
		}
		if io_size^ < size_of(au.Audio_Unit_Parameter_Info) {
			return au.PARAM_ERR
		}
		info := (^au.Audio_Unit_Parameter_Info)(out_data)
		info^ = {}
		name := param_name(int(element))
		nlen := min(len(name), len(info.name) - 1)
		for i in 0 ..< nlen {
			info.name[i] = name[i]
		}
		info.name[nlen] = 0
		info.unit = au.PARAMETER_UNIT_INDEXED
		info.min_value = f32(param_min(int(element)))
		info.max_value = f32(param_max(int(element)))
		info.default_value = f32(param_default(int(element)))
		info.flags = au.PARAMETER_FLAG_IS_READABLE | au.PARAMETER_FLAG_IS_WRITABLE
		io_size^ = size_of(au.Audio_Unit_Parameter_Info)
		return au.NO_ERR
	case au.PROP_CLASS_INFO:
		if io_size^ < size_of(au.CF_Dictionary_Ref) {
			return au.PARAM_ERR
		}
		(^au.CF_Dictionary_Ref)(out_data)^ = class_info_dict(s)
		io_size^ = size_of(au.CF_Dictionary_Ref)
		return au.NO_ERR
	case au.PROP_PRESENT_PRESET:
		if io_size^ < size_of(au.AU_Preset) {
			return au.PARAM_ERR
		}
		// No factory preset: number -1 and a name the caller owns and releases.
		preset := (^au.AU_Preset)(out_data)
		preset.preset_number = -1
		preset.preset_name = au.CFStringCreateWithCString(nil, "Untitled", au.CF_STRING_ENCODING_UTF8)
		io_size^ = size_of(au.AU_Preset)
		return au.NO_ERR
	}
	return au.ERR_INVALID_PROPERTY
}

au_set_property :: proc "c" (self: rawptr, prop: u32, scope: u32, element: u32, in_data: rawptr, in_size: u32) -> au.OSStatus {
	s := au_of(self)
	if s == nil {
		return au.PARAM_ERR
	}

	switch prop {
	case au.PROP_STREAM_FORMAT:
		if scope == au.SCOPE_INPUT {
			return au.ERR_INVALID_SCOPE
		}
		if in_data == nil || in_size < size_of(au.Audio_Stream_Basic_Description) {
			return au.PARAM_ERR
		}
		fmt := (^au.Audio_Stream_Basic_Description)(in_data)
		// Only the rate is adopted; the layout is fixed at stereo float. A format
		// that is not two-channel float is refused rather than quietly accepted.
		if fmt.channels_per_frame != 2 || fmt.format_id != au.FORMAT_LINEAR_PCM {
			return au.ERR_INVALID_PROPERTY_VALUE
		}
		if fmt.sample_rate > 0 {
			s.sample_rate = fmt.sample_rate
		}
		return au.NO_ERR
	case au.PROP_SAMPLE_RATE:
		if in_data == nil || in_size < size_of(f64) {
			return au.PARAM_ERR
		}
		rate := (^f64)(in_data)^
		if rate > 0 {
			s.sample_rate = rate
		}
		return au.NO_ERR
	case au.PROP_MAXIMUM_FRAMES_PER_SLICE:
		if in_data == nil || in_size < size_of(u32) {
			return au.PARAM_ERR
		}
		s.max_frames = int((^u32)(in_data)^)
		// A host may be listening for this; it changed, so tell it.
		notify_property(s, au.PROP_MAXIMUM_FRAMES_PER_SLICE, au.SCOPE_GLOBAL, 0)
		return au.NO_ERR
	case au.PROP_CLASS_INFO:
		if in_data == nil || in_size < size_of(au.CF_Dictionary_Ref) {
			return au.PARAM_ERR
		}
		dict := (^au.CF_Dictionary_Ref)(in_data)^
		if dict == nil {
			return au.PARAM_ERR
		}
		class_info_restore(s, dict)
		return au.NO_ERR
	case au.PROP_PRESENT_PRESET:
		// Accepted: there are no factory presets to switch between, so there is
		// nothing to store, but refusing it would fail validation.
		return au.NO_ERR
	}
	return au.ERR_INVALID_PROPERTY
}

// A no-op that reports success, for the listener and render-notify selectors a
// host registers: this unit pushes no notifications, so there is nothing to keep.
au_ok_stub :: proc "c" (self: rawptr) -> au.OSStatus {
	return au.NO_ERR
}

// -- the interface -----------------------------------------------------------

au_lookup :: proc "c" (selector: i16) -> au.Audio_Component_Method {
	switch selector {
	case au.SELECT_INITIALIZE:
		return rawptr(au_initialize)
	case au.SELECT_UNINITIALIZE:
		return rawptr(au_uninitialize)
	case au.SELECT_GET_PROPERTY_INFO:
		return rawptr(au_get_property_info)
	case au.SELECT_GET_PROPERTY:
		return rawptr(au_get_property)
	case au.SELECT_SET_PROPERTY:
		return rawptr(au_set_property)
	case au.SELECT_GET_PARAMETER:
		return rawptr(au_get_parameter)
	case au.SELECT_SET_PARAMETER:
		return rawptr(au_set_parameter)
	case au.SELECT_RESET:
		return rawptr(au_reset)
	case au.SELECT_RENDER:
		return rawptr(au_render)
	case au.SELECT_MIDI_EVENT:
		return rawptr(au_midi_event)
	case au.SELECT_ADD_PROPERTY_LISTENER:
		return rawptr(au_add_property_listener)
	case au.SELECT_REMOVE_PROPERTY_LISTENER:
		return rawptr(au_remove_property_listener)
	case au.SELECT_REMOVE_PROPERTY_LISTENER_WITH_USER_DATA:
		return rawptr(au_remove_property_listener_with_user_data)
	case au.SELECT_ADD_RENDER_NOTIFY, au.SELECT_REMOVE_RENDER_NOTIFY:
		return rawptr(au_ok_stub)
	}
	return nil
}

// -- factory -----------------------------------------------------------------

// The symbol the bundle's Info.plist names as the AudioComponent factory. It
// allocates one instance per host request; Close frees it.
@(export, link_name = "QuesynthAUFactory")
au_factory :: proc "c" (desc: ^au.Audio_Component_Description) -> ^au.Audio_Component_Plug_In_Interface {
	context = runtime.default_context()
	s := new(AU)
	if s == nil {
		return nil
	}
	s.interface = au.Audio_Component_Plug_In_Interface {
		open   = au_open,
		close  = au_close,
		lookup = au_lookup,
	}
	for i in 0 ..< PARAM_COUNT {
		s.values[i] = i32(param_default(i))
	}
	s.sample_rate = 44100
	s.max_frames = 1156
	return &s.interface
}
