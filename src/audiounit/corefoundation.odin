#+build darwin
package audiounit

import "core:c"

// The slice of CoreFoundation the Audio Unit needs, bound by hand.
//
// Two AU properties are unavoidably CoreFoundation-shaped and auval requires
// them: ClassInfo is a CFDictionary carrying the unit's saved state, and
// PresentPreset is an AUPreset whose name is a CFString. Everything else the unit
// answers is plain C and needs no framework, so this is the one place hosts/au
// links against something -- CoreFoundation, which every macOS host already has
// loaded. As with the rest of the AU it is declared from the documented
// signatures rather than an SDK header.

CF_Type_Ref :: rawptr
CF_String_Ref :: rawptr
CF_Dictionary_Ref :: rawptr
CF_Mutable_Dictionary_Ref :: rawptr
CF_Number_Ref :: rawptr
CF_Data_Ref :: rawptr
CF_Allocator_Ref :: rawptr
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

foreign import core_foundation "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign core_foundation {
	kCFTypeDictionaryKeyCallBacks:   CF_Dictionary_Callbacks
	kCFTypeDictionaryValueCallBacks: CF_Dictionary_Callbacks

	CFRelease :: proc(obj: CF_Type_Ref) ---
	CFRetain :: proc(obj: CF_Type_Ref) -> CF_Type_Ref ---

	CFStringCreateWithCString :: proc(alloc: CF_Allocator_Ref, c_str: cstring, encoding: u32) -> CF_String_Ref ---
	CFStringGetCString :: proc(s: CF_String_Ref, buffer: [^]u8, buffer_size: CF_Index, encoding: u32) -> Boolean ---

	CFDictionaryCreateMutable :: proc(alloc: CF_Allocator_Ref, capacity: CF_Index, key_cb: rawptr, value_cb: rawptr) -> CF_Mutable_Dictionary_Ref ---
	CFDictionarySetValue :: proc(dict: CF_Mutable_Dictionary_Ref, key: rawptr, value: rawptr) ---
	CFDictionaryGetValue :: proc(dict: CF_Dictionary_Ref, key: rawptr) -> rawptr ---

	CFNumberCreate :: proc(alloc: CF_Allocator_Ref, type: CF_Index, value_ptr: rawptr) -> CF_Number_Ref ---
	CFNumberGetValue :: proc(num: CF_Number_Ref, type: CF_Index, value_ptr: rawptr) -> Boolean ---

	CFDataCreate :: proc(alloc: CF_Allocator_Ref, bytes: [^]u8, length: CF_Index) -> CF_Data_Ref ---
	CFDataGetBytePtr :: proc(data: CF_Data_Ref) -> [^]u8 ---
	CFDataGetLength :: proc(data: CF_Data_Ref) -> CF_Index ---
}
