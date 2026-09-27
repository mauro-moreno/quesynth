#+build darwin
package audiounit

// The two AudioToolbox calls the editor makes, bound by hand like the rest of
// the AU.
//
// AudioUnitGetProperty is how the view factory, handed only the AudioUnit a
// host opened, reaches this unit's own instance: it asks the unit for a private
// property, and the call goes through the host's normal component dispatch.
//
// AUEventListenerNotify is how a move made in the panel reaches the host --
// automation, gestures and the host's own parameter display -- the call
// AudioUnitUtilities.h prescribes for a unit's view.
//
// Linking AudioToolbox costs nothing in practice: every process that hosts an
// Audio Unit already has it loaded.

foreign import audio_toolbox "system:AudioToolbox.framework"

// kAudioUnitEvent_* (AudioUnitUtilities.h).
EVENT_PARAMETER_VALUE_CHANGE :: u32(0)
EVENT_BEGIN_PARAMETER_CHANGE_GESTURE :: u32(1)
EVENT_END_PARAMETER_CHANGE_GESTURE :: u32(2)

// AudioUnitParameter: the unit, and which of its parameters.
Audio_Unit_Parameter :: struct {
	audio_unit:   rawptr,
	parameter_id: u32,
	scope:        u32,
	element:      u32,
}
#assert(size_of(Audio_Unit_Parameter) == 24)

// AudioUnitEvent. The header's argument is a union of AudioUnitParameter and
// AudioUnitProperty, which are the same size; only parameter events are sent.
Audio_Unit_Event :: struct {
	event_type: u32,
	argument:   Audio_Unit_Parameter,
}
#assert(size_of(Audio_Unit_Event) == 32)
#assert(offset_of(Audio_Unit_Event, argument) == 8)

@(default_calling_convention = "c")
foreign audio_toolbox {
	AudioUnitGetProperty :: proc(unit: rawptr, prop: u32, scope: u32, element: u32, out_data: rawptr, io_size: ^u32) -> OSStatus ---
	AUEventListenerNotify :: proc(sending_listener: rawptr, sending_object: rawptr, event: ^Audio_Unit_Event) -> OSStatus ---
}
