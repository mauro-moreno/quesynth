#+build darwin
package webkit

import "base:intrinsics"
import "core:c"
import "core:fmt"
import NS "core:sys/darwin/Foundation"

// The Objective-C runtime beyond what core:sys/darwin/Foundation binds, and the
// one way this package makes classes of its own. Nothing here knows about
// WebKit or Audio Units, so hosts/au builds its view factory on the same pieces.
//
// A class made here is never looked up by name. Odin resolves every
// @(objc_class) and objc_find_class name once, at image startup, before any
// class of ours exists, so such a lookup would stay nil for the life of the
// process. The NS.Class that objc_allocateClassPair returns is kept in a
// `Class` instead and messaged directly.

foreign import objc_lib "system:objc"
foreign import system_lib "system:System"

// struct objc_super
Objc_Super :: struct {
	receiver:    ^NS.Object,
	super_class: NS.Class,
}

@(default_calling_convention = "c")
foreign objc_lib {
	// The void, argument-free form only: all a dealloc override needs.
	@(link_name = "objc_msgSendSuper")
	send_super :: proc(super: ^Objc_Super, op: NS.SEL) ---
	@(link_name = "objc_autoreleasePoolPush")
	pool_push :: proc() -> rawptr ---
	@(link_name = "objc_autoreleasePoolPop")
	pool_pop :: proc(pool: rawptr) ---
}

// <dlfcn.h>
Dl_Info :: struct {
	fname: cstring,
	fbase: rawptr,
	sname: cstring,
	saddr: rawptr,
}

@(default_calling_convention = "c")
foreign system_lib {
	dladdr :: proc(address: rawptr, info: ^Dl_Info) -> c.int ---
	pthread_main_np :: proc() -> c.int ---
}

on_main_thread :: proc "contextless" () -> bool {
	return pthread_main_np() != 0
}

// The loaded image this code is in: the plugin binary, not the DAW. The path is
// the loader's and stays valid while the image is loaded. The base address is
// what keeps our class names apart when two copies of the plugin are loaded.
image :: proc "contextless" () -> (path: cstring, base: uintptr, ok: bool) {
	info: Dl_Info
	if dladdr(rawptr(image), &info) == 0 || info.fname == nil {
		return nil, 0, false
	}
	return info.fname, uintptr(info.fbase), true
}

Method :: struct {
	name:  cstring,
	imp:   rawptr,
	types: cstring,
}

// A class of ours, with exactly one pointer-sized ivar. `slot` is that ivar's
// byte offset into an instance.
Class :: struct {
	cls:  NS.Class,
	slot: uintptr,
}

@(private)
IVAR_NAME :: "quesynth"
@(private)
IVAR_ALIGNMENT_LOG2 :: u8(intrinsics.constant_log2(align_of(rawptr)))

// Registers `<prefix>_<hex image base>` as a subclass of `superclass`. The
// protocol is adopted when the runtime knows it and skipped when it does not.
// Registration is not repeatable, so the caller runs it once (sync.Once) and
// keeps the result.
register_class :: proc(prefix: string, superclass: NS.Class, methods: []Method, protocol: cstring = nil) -> (Class, bool) {
	_, base, found := image()
	if !found || superclass == nil {
		return {}, false
	}
	cls := NS.objc_allocateClassPair(superclass, fmt.ctprintf("%s_%x", prefix, base), 0)
	if cls == nil {
		return {}, false
	}
	if !NS.class_addIvar(cls, IVAR_NAME, size_of(rawptr), IVAR_ALIGNMENT_LOG2, "^v") {
		NS.objc_disposeClassPair(cls)
		return {}, false
	}
	for m in methods {
		if !NS.class_addMethod(cls, NS.sel_registerName(m.name), auto_cast m.imp, m.types) {
			NS.objc_disposeClassPair(cls)
			return {}, false
		}
	}
	if protocol != nil {
		if p := NS.objc_getProtocol(protocol); p != nil {
			NS.class_addProtocol(cls, p)
		}
	}
	NS.objc_registerClassPair(cls)

	ivar := NS.class_getInstanceVariable(cls, IVAR_NAME)
	if ivar == nil {
		return {}, false
	}
	return Class{cls = cls, slot = uintptr(NS.ivar_getOffset(ivar))}, true
}

// [c.cls alloc]: +1, not yet initialised.
alloc_instance :: proc "contextless" (c: Class) -> ^NS.Object {
	return intrinsics.objc_send(^NS.Object, (^NS.Object)(rawptr(c.cls)), "alloc")
}

// The instance's pointer-sized ivar.
slot :: proc "contextless" (c: Class, obj: ^NS.Object) -> ^rawptr {
	return (^rawptr)(uintptr(rawptr(obj)) + c.slot)
}

// +1 NSURL of the bundle the runtime attributes `cls` to; toll-free a CFURLRef.
// For a class made by register_class that is the main bundle, which is the
// answer a host's [[NSBundle bundleWithPath:] classNamed:] can resolve.
bundle_url_for_class :: proc "contextless" (cls: NS.Class) -> ^NS.URL {
	bundle := intrinsics.objc_send(^NS.Bundle, NS.Bundle, "bundleForClass:", cls)
	if bundle == nil {
		return nil
	}
	path := NS.Bundle_bundlePath(bundle)
	if path == nil {
		return nil
	}
	return NS.URL_alloc()->initFileURLWithPath(path)
}
