package synth_vst3

import "base:runtime"

import "../../src/vst3"

// The shared library's entry points and its class factory.
//
// A VST3 module on Windows exports three symbols: `InitDll`, `ExitDll` and
// `GetPluginFactory`. The first two are optional in the specification and
// required in practice, because hosts call them when present and some refuse a
// module that exports a factory without them.

PLUGIN_NAME :: "Quesynth"
PLUGIN_VENDOR :: "quesynth"
PLUGIN_VERSION :: "0.1.0"
PLUGIN_URL :: ""
PLUGIN_EMAIL :: ""

// The SDK version string a host matches against. This is the C API's own
// vintage, not this project's.
SDK_VERSION :: "VST 3.7.4"

// "Instrument|Synth" is what puts the plugin under Instruments in a host's
// browser rather than under audio effects.
SUB_CATEGORIES :: "Instrument|Synth"

// This plugin's own class identifier.
//
// Generated once and fixed forever: a host stores it in every session that uses
// the plugin, so changing it orphans saved projects. It is not derived from
// anything, which is the point -- two unrelated plugins sharing a UID is the one
// failure the value exists to prevent.
CLASS_UID :: proc "contextless" () -> vst3.TUID {
	return vst3.uid(0x5E9A3C71, 0x4D2B4F86, 0xA1C05B73, 0x9F28E640)
}

// -- IPluginFactory ----------------------------------------------------------
//
// The factory is a static object with no state to reference-count, so its
// addRef and release are honest no-ops returning a count that never falls to
// zero. Hosts are allowed to call them and do.

factory_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	if obj == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	obj^ = nil
	// All three factory interfaces are the same object: IPluginFactory2 and 3
	// extend IPluginFactory, and this vtable is laid out as the widest of them,
	// so a caller holding any of the three finds the methods it expects at the
	// offsets it expects.
	//
	// Answering 2 and 3 is not optional in practice. A host reads the plugin's
	// *subcategory* from getClassInfo2 -- "Instrument|Synth" -- and there is
	// nowhere else to read it from; PClassInfo, which IPluginFactory alone
	// offers, has no field for it. A host that cannot tell an instrument from
	// an effect will refuse to open it as either.
	if vst3.tuid_equal(iid, vst3.IID_FUNKNOWN()) ||
	   vst3.tuid_equal(iid, vst3.IID_PLUGIN_FACTORY()) ||
	   vst3.tuid_equal(iid, vst3.IID_PLUGIN_FACTORY_2()) ||
	   vst3.tuid_equal(iid, vst3.IID_PLUGIN_FACTORY_3()) {
		obj^ = rawptr(&FACTORY)
		return vst3.RESULT_OK
	}
	return vst3.NO_INTERFACE
}

factory_add_ref :: proc "c" (this: rawptr) -> u32 {
	return 1
}

factory_release :: proc "c" (this: rawptr) -> u32 {
	return 1
}

factory_get_factory_info :: proc "c" (this: rawptr, info: ^vst3.Factory_Info) -> vst3.Result {
	if info == nil {
		return vst3.INVALID_ARGUMENT
	}
	vst3.copy_ascii(info.vendor[:], PLUGIN_VENDOR)
	vst3.copy_ascii(info.url[:], PLUGIN_URL)
	vst3.copy_ascii(info.email[:], PLUGIN_EMAIL)
	// `kUnicode` says the String128 fields really are UTF-16, which they are.
	info.flags = vst3.FACTORY_UNICODE
	return vst3.RESULT_OK
}

factory_count_classes :: proc "c" (this: rawptr) -> i32 {
	// One: processor and controller are the same object. See plugin.odin.
	return 1
}

factory_get_class_info :: proc "c" (this: rawptr, index: i32, info: ^vst3.Class_Info) -> vst3.Result {
	if info == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	info.cid = CLASS_UID()
	info.cardinality = vst3.CARDINALITY_MANY_INSTANCES
	vst3.copy_ascii(info.category[:], vst3.CATEGORY_AUDIO_EFFECT)
	vst3.copy_ascii(info.name[:], PLUGIN_NAME)
	return vst3.RESULT_OK
}

factory_create_instance :: proc "c" (this: rawptr, cid: cstring, iid: cstring, obj: ^rawptr) -> vst3.Result {
	context = runtime.default_context()

	if obj == nil || cid == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	obj^ = nil

	// `cid` and `iid` are raw 16-byte identifiers passed as `FIDString`, which
	// is a `char*`. They are not null-terminated strings and must not be read
	// as such.
	requested_cid := (^vst3.TUID)(rawptr(cid))
	if !vst3.tuid_equal(requested_cid, CLASS_UID()) {
		return vst3.NO_INTERFACE
	}

	p := make_plugin()
	if p == nil {
		return vst3.RESULT_FALSE
	}

	// Hand back the interface actually asked for. `make_plugin` already set the
	// count to one, so `query_interface` incrementing it again would leak; the
	// extra reference is dropped here to leave the caller holding exactly one.
	requested_iid := (^vst3.TUID)(rawptr(iid))
	result := query_interface(p, requested_iid, obj)
	if result != vst3.RESULT_OK {
		release(p)
		return result
	}
	p.ref_count -= 1
	return vst3.RESULT_OK
}

factory_get_class_info_2 :: proc "c" (this: rawptr, index: i32, info: ^vst3.Class_Info_2) -> vst3.Result {
	if info == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	info.cid = CLASS_UID()
	info.cardinality = vst3.CARDINALITY_MANY_INSTANCES
	vst3.copy_ascii(info.category[:], vst3.CATEGORY_AUDIO_EFFECT)
	vst3.copy_ascii(info.name[:], PLUGIN_NAME)
	info.class_flags = vst3.COMPONENT_FLAGS_NONE
	// The field that tells the host this is an instrument rather than an effect.
	vst3.copy_ascii(info.sub_categories[:], SUB_CATEGORIES)
	vst3.copy_ascii(info.vendor[:], PLUGIN_VENDOR)
	vst3.copy_ascii(info.version[:], PLUGIN_VERSION)
	vst3.copy_ascii(info.sdk_version[:], SDK_VERSION)
	return vst3.RESULT_OK
}

factory_get_class_info_unicode :: proc "c" (this: rawptr, index: i32, info: ^vst3.Class_Info_W) -> vst3.Result {
	if info == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	info.cid = CLASS_UID()
	info.cardinality = vst3.CARDINALITY_MANY_INSTANCES
	vst3.copy_ascii(info.category[:], vst3.CATEGORY_AUDIO_EFFECT)
	vst3.copy_utf16_slice(info.name[:], PLUGIN_NAME)
	info.class_flags = vst3.COMPONENT_FLAGS_NONE
	vst3.copy_ascii(info.sub_categories[:], SUB_CATEGORIES)
	vst3.copy_utf16_slice(info.vendor[:], PLUGIN_VENDOR)
	vst3.copy_utf16_slice(info.version[:], PLUGIN_VERSION)
	vst3.copy_utf16_slice(info.sdk_version[:], SDK_VERSION)
	return vst3.RESULT_OK
}

// The host offers itself here. Nothing is kept: this plugin asks the host for
// nothing, and holding a reference it never releases would be a leak.
factory_set_host_context :: proc "c" (this: rawptr, context_: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

// Laid out as IPluginFactory3, which is IPluginFactory2, which is
// IPluginFactory. One object answers to all three identifiers above.
FACTORY_VTBL := vst3.IPluginFactory3_Vtbl {
	query_interface  = factory_query_interface,
	add_ref          = factory_add_ref,
	release          = factory_release,
	get_factory_info = factory_get_factory_info,
	count_classes    = factory_count_classes,
	get_class_info   = factory_get_class_info,
	create_instance  = factory_create_instance,
	get_class_info_2 = factory_get_class_info_2,
	get_class_info_unicode = factory_get_class_info_unicode,
	set_host_context = factory_set_host_context,
}

FACTORY := vst3.IPluginFactory {
	// The widest vtable, reinterpreted as the narrowest. Safe because the layout
	// is an extension: the first seven entries are IPluginFactory's, in order.
	vtbl = (^vst3.IPluginFactory_Vtbl)(&FACTORY_VTBL),
}

// -- module entry points -----------------------------------------------------

@(export, link_name = "InitDll")
init_dll :: proc "c" () -> bool {
	return true
}

@(export, link_name = "ExitDll")
exit_dll :: proc "c" () -> bool {
	return true
}

@(export, link_name = "GetPluginFactory")
get_plugin_factory :: proc "c" () -> ^vst3.IPluginFactory {
	return &FACTORY
}
