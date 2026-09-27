#+build darwin
package audiounit

import "core:c"

// The slice of CoreFoundation the Audio Unit needs, bound by hand.
//
// Two AU properties are unavoidably CoreFoundation-shaped and auval requires
// them: ClassInfo is a CFDictionary carrying the unit's saved state, and
// PresentPreset is an AUPreset whose name is a CFString. The editor adds the
// CocoaUI answer (a CFURL and a CFString) and a main-run-loop timer that carries
// host-side parameter changes to the panel. CoreFoundation is loaded in every
// macOS host. As with the rest of the AU it is declared from the documented
// signatures rather than an SDK header.
//
// A symbol core:sys/darwin/CoreFoundation also binds must be declared with a
// signature Odin finds compatible with its one, because the editor's Foundation
// import brings that package into the same build. CFStringGetCString is left out
// for that reason: the core binding types its encoding as a long.

CF_Type_Ref :: rawptr
CF_String_Ref :: rawptr
CF_Dictionary_Ref :: rawptr
CF_Mutable_Dictionary_Ref :: rawptr
CF_Number_Ref :: rawptr
CF_Data_Ref :: rawptr
CF_Allocator_Ref :: rawptr
CF_URL_Ref :: rawptr
CF_Run_Loop_Ref :: rawptr
CF_Run_Loop_Timer_Ref :: rawptr
CF_Index :: c.long

CF_STRING_ENCODING_UTF8 :: u32(0x08000100)
CF_NUMBER_SINT32_TYPE :: CF_Index(3)

// CFDictionaryKeyCallBacks / CFDictionaryValueCallBacks are global structs a
// mutable dictionary is created with. Only their address is passed, so the exact
// interior does not matter here; a buffer at least as large as the real struct
// stands in for it.
CF_Dictionary_Callbacks :: struct {
	_opaque: [64]u8,
}

CF_Run_Loop_Timer_Callback :: #type proc "c" (timer: CF_Run_Loop_Timer_Ref, info: rawptr)

// CFRunLoopTimerContext. CFRunLoopTimerCreate copies it; with no retain or
// release callbacks, `info` is a raw pointer the timer does not own.
CF_Run_Loop_Timer_Context :: struct {
	version:          CF_Index,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

foreign import core_foundation "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign core_foundation {
	kCFTypeDictionaryKeyCallBacks:   CF_Dictionary_Callbacks
	kCFTypeDictionaryValueCallBacks: CF_Dictionary_Callbacks
	kCFRunLoopCommonModes:           CF_String_Ref

	CFRelease :: proc(obj: CF_Type_Ref) ---
	CFRetain :: proc(obj: CF_Type_Ref) -> CF_Type_Ref ---

	CFStringCreateWithCString :: proc(alloc: CF_Allocator_Ref, c_str: cstring, encoding: u32) -> CF_String_Ref ---

	CFDictionaryCreateMutable :: proc(alloc: CF_Allocator_Ref, capacity: CF_Index, key_cb: rawptr, value_cb: rawptr) -> CF_Mutable_Dictionary_Ref ---
	CFDictionarySetValue :: proc(dict: CF_Mutable_Dictionary_Ref, key: rawptr, value: rawptr) ---
	CFDictionaryGetValue :: proc(dict: CF_Dictionary_Ref, key: rawptr) -> rawptr ---

	CFNumberCreate :: proc(alloc: CF_Allocator_Ref, type: CF_Index, value_ptr: rawptr) -> CF_Number_Ref ---
	CFNumberGetValue :: proc(num: CF_Number_Ref, type: CF_Index, value_ptr: rawptr) -> Boolean ---

	CFDataCreate :: proc(alloc: CF_Allocator_Ref, bytes: [^]u8, length: CF_Index) -> CF_Data_Ref ---
	CFDataGetBytePtr :: proc(data: CF_Data_Ref) -> [^]u8 ---
	CFDataGetLength :: proc(data: CF_Data_Ref) -> CF_Index ---

	CFAbsoluteTimeGetCurrent :: proc() -> f64 ---
	CFRunLoopGetMain :: proc() -> CF_Run_Loop_Ref ---
	CFRunLoopTimerCreate :: proc(alloc: CF_Allocator_Ref, fire_date: f64, interval: f64, flags: c.ulong, order: CF_Index, callout: CF_Run_Loop_Timer_Callback, ctx: ^CF_Run_Loop_Timer_Context) -> CF_Run_Loop_Timer_Ref ---
	CFRunLoopAddTimer :: proc(rl: CF_Run_Loop_Ref, timer: CF_Run_Loop_Timer_Ref, mode: CF_String_Ref) ---
	CFRunLoopTimerInvalidate :: proc(timer: CF_Run_Loop_Timer_Ref) ---
}
