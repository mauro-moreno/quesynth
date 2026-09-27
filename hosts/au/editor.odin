#+build darwin
package synth_au

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:sync"
import NS "core:sys/darwin/Foundation"

import au "../../src/audiounit"
import "../../src/patch"
import "../../src/webkit"
import "../panel"

// The editor: the panel in ui/, in a WKWebView, as the Audio Unit's Cocoa view.
//
// An AUv2 unit offers a view through kAudioUnitProperty_CocoaUI: a bundle and
// the name of a factory class in it. The host loads the class, makes a factory,
// and calls -uiViewForAudioUnit:withSize: with the AudioUnit it opened; the
// NSView that comes back is the host's to show and release. Two classes are
// created at run time for this, because Odin cannot declare an Objective-C
// class: the factory, and the container NSView that owns everything the editor
// is and tears it down in -dealloc.
//
// Everything past the container is hosts/panel, the same code the VST3 and CLAP
// editors run: this file is the panel.Host over an AU instance, and the
// main-run-loop timer that brings changes made elsewhere to the page.
//
// Threads. The factory, the page's messages, the timer and -dealloc all run on
// the main thread. The render thread never touches WebKit: it takes the notes
// the panel queued, and it reads the parameter values and the volume. A host's
// AudioUnitSetParameter may arrive on any thread, so it only sets bits the
// timer drains.
//
// Build with -define:QUESYNTH_AU_EDITOR=false for a unit that offers no view.

AU_EDITOR :: #config(QUESYNTH_AU_EDITOR, true)

// A private property: the address of this unit's instance, for the view factory
// to find it from the AudioUnit it is handed. Apple reserves IDs below 64000.
PROP_INSTANCE :: u32(0x51534155) // 'QSAU'

// Where the panel is, relative to the binary in Contents/MacOS: the same
// Contents/Resources/ui a VST3 bundle uses, which tools/build-au.sh fills.
AU_CONTENT :: []string{"../Resources/ui"}

PARAM_WORDS :: (PARAM_COUNT + 63) / 64

// More host-side changes than this between two ticks are sent as one state
// message rather than one message each: a parameter fuzz or dense automation
// would otherwise queue hundreds of scripts into the page.
PANEL_PARAM_BURST :: 8
TICK_SECONDS :: 1.0 / 30.0

Au_Editor :: struct {
	// Nil once the unit has closed or a newer view of it has opened; the
	// editor is inert from then on.
	unit:      ^AU,
	panel:     panel.Panel,
	// The host owns it; the editor lives as long as it does.
	container: ^NS.View,
	timer:     au.CF_Run_Loop_Timer_Ref,
	ctx:       runtime.Context,
}

// -- the runtime classes -----------------------------------------------------

@(private = "file")
classes_once: sync.Once
@(private = "file")
classes_ok: bool
@(private = "file")
factory_class: webkit.Class
@(private = "file")
view_class: webkit.Class

// Once per image, on whichever thread first asks whether there is a view:
// hosts scan from background threads.
@(private = "file")
register_classes :: proc() {
	factory_methods := []webkit.Method {
		{"interfaceVersion", rawptr(factory_interface_version), "I@:"},
		{"uiViewForAudioUnit:withSize:", rawptr(factory_ui_view), "@@:^v{CGSize=dd}"},
	}
	// AUCocoaUIBase is adopted when some image in the process defines it. A
	// host that checks conformance has to reference the protocol itself, so
	// the only case where it is missing is one where nobody asks.
	factory_ok: bool
	factory_class, factory_ok = webkit.register_class("QuesynthAUViewFactory", intrinsics.objc_find_class("NSObject"), factory_methods, "AUCocoaUIBase")
	if !factory_ok {
		return
	}
	view_methods := []webkit.Method{{"dealloc", rawptr(view_dealloc), "v@:"}}
	view_ok: bool
	view_class, view_ok = webkit.register_class("QuesynthAUView", intrinsics.objc_find_class("NSView"), view_methods)
	classes_ok = view_ok
}

// -interfaceVersion (AUCocoaUIBase).
@(private = "file")
factory_interface_version :: proc "c" (self: ^NS.Object, cmd: NS.SEL) -> u32 {
	return 0
}

// -uiViewForAudioUnit:withSize: (AUCocoaUIBase). The size is ignored, as JUCE
// ignores it: the view comes back at the panel's own size and the host fits
// its window to that.
@(private = "file")
factory_ui_view :: proc "c" (self: ^NS.Object, cmd: NS.SEL, unit: rawptr, size: NS.Size) -> ^NS.View {
	if unit == nil || !webkit.on_main_thread() {
		return nil
	}
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	s: ^AU
	io_size := u32(size_of(rawptr))
	if au.AudioUnitGetProperty(unit, PROP_INSTANCE, au.SCOPE_GLOBAL, 0, &s, &io_size) != au.NO_ERR || s == nil {
		return nil
	}

	// auval asks for the view with no autorelease pool in place.
	pool := webkit.pool_push()
	view := editor_open(s)
	webkit.pool_pop(pool)
	if view == nil {
		return nil
	}
	// +0 to the caller, as the method's name promises: the host retains it.
	view->autorelease()
	return view
}

// -dealloc on the container: AppKit sends it on the main thread when the host
// lets go of the view, and it is the only place an Au_Editor is freed.
@(private = "file")
view_dealloc :: proc "c" (self: ^NS.Object, cmd: NS.SEL) {
	slot := webkit.slot(view_class, self)
	if ed := (^Au_Editor)(slot^); ed != nil {
		slot^ = nil
		context = ed.ctx
		editor_close(ed)
	}
	super := webkit.Objc_Super{receiver = self, super_class = intrinsics.objc_find_class("NSView")}
	webkit.send_super(&super, cmd)
}

// -- the CocoaUI and instance properties -------------------------------------

// Whether this unit offers a view: the classes registered, WebKit loaded, and
// the panel found in the bundle. Any thread.
editor_available :: proc() -> bool {
	when !AU_EDITOR {
		return false
	} else {
		sync.once_do(&classes_once, register_classes)
		if !classes_ok {
			return false
		}
		content, found := panel.find_content(AU_CONTENT)
		if !found {
			return false
		}
		delete(content)
		return true
	}
}

// The bundle is whatever NSBundle attributes the factory class to. A class made
// at run time has no image, so that is the main bundle -- the host itself -- and
// that is the one answer the host's [[NSBundle bundleWithPath:] classNamed:]
// resolves; the .component's own path would not find the class. JUCE's AU
// wrapper answers the same way.
editor_view_info :: proc(out: ^au.Audio_Unit_Cocoa_View_Info) -> bool {
	pool := webkit.pool_push()
	defer webkit.pool_pop(pool)

	url := webkit.bundle_url_for_class(factory_class.cls)
	name := au.CFStringCreateWithCString(nil, NS.class_getName(factory_class.cls), au.CF_STRING_ENCODING_UTF8)
	if url == nil || name == nil {
		if url != nil {
			url->release()
		}
		if name != nil {
			au.CFRelease(name)
		}
		return false
	}
	out.bundle_location = au.CF_URL_Ref(url)
	out.class_names[0] = name
	return true
}

editor_property_info :: proc "contextless" (prop: u32, scope: u32) -> (size: u32, status: au.OSStatus) {
	if !AU_EDITOR || scope != au.SCOPE_GLOBAL {
		return 0, au.ERR_INVALID_PROPERTY
	}
	switch prop {
	case PROP_INSTANCE:
		return size_of(rawptr), au.NO_ERR
	case au.PROP_COCOA_UI:
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if editor_available() {
			return size_of(au.Audio_Unit_Cocoa_View_Info), au.NO_ERR
		}
	}
	return 0, au.ERR_INVALID_PROPERTY
}

editor_get_property :: proc "contextless" (s: ^AU, prop: u32, scope: u32, out_data: rawptr, io_size: ^u32) -> au.OSStatus {
	if !AU_EDITOR || scope != au.SCOPE_GLOBAL {
		return au.ERR_INVALID_PROPERTY
	}
	switch prop {
	case PROP_INSTANCE:
		if io_size^ < size_of(rawptr) {
			return au.PARAM_ERR
		}
		(^rawptr)(out_data)^ = s
		io_size^ = size_of(rawptr)
		return au.NO_ERR
	case au.PROP_COCOA_UI:
		if io_size^ < size_of(au.Audio_Unit_Cocoa_View_Info) {
			return au.PARAM_ERR
		}
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if !editor_available() || !editor_view_info((^au.Audio_Unit_Cocoa_View_Info)(out_data)) {
			return au.ERR_INVALID_PROPERTY
		}
		io_size^ = size_of(au.Audio_Unit_Cocoa_View_Info)
		return au.NO_ERR
	}
	return au.ERR_INVALID_PROPERTY
}

// -- opening and closing -----------------------------------------------------

// The container with the panel inside it, +1, or nil when there is no panel to
// show. Main thread.
editor_open :: proc(s: ^AU) -> ^NS.View {
	content, found := panel.find_content(AU_CONTENT)
	if !found {
		return nil
	}
	editor_load_bank(s)

	ed := new(Au_Editor)
	if ed == nil {
		delete(content)
		return nil
	}
	ed.unit = s
	ed.ctx = context
	ed.panel.width = panel.WIDTH
	ed.panel.height = panel.HEIGHT
	ed.panel.ctx = context
	ed.panel.view.content_dir = content
	ed.panel.host = panel.Host {
		user        = rawptr(ed),
		param_count = PARAM_COUNT,
		read_values = editor_read_values,
		set_param   = editor_set_param,
		set_state   = editor_set_state,
		edit        = editor_edit,
		note        = editor_note,
		bend        = editor_bend,
		control     = editor_control,
		volume      = editor_volume,
		set_bank    = editor_set_bank,
		read_bank   = editor_read_bank,
	}

	frame := NS.Rect{size = {NS.Float(panel.WIDTH), NS.Float(panel.HEIGHT)}}
	container := NS.View_initWithFrame((^NS.View)(webkit.alloc_instance(view_class)), frame)
	if container == nil {
		delete(content)
		free(ed)
		return nil
	}
	webkit.slot(view_class, container)^ = ed
	ed.container = container

	// A web view that will not come up -- a headless session with no window
	// server, as auval's and pluginval's runners may be -- still leaves a real,
	// empty NSView for the host to show and release, rather than a nil the host
	// reads as "no view". A crash or hang inside WebKit cannot be caught here;
	// QUESYNTH_AU_EDITOR=false and PLUGINVAL_GUI=0 are the ways round that.
	if panel.start(&ed.panel, container) {
		editor_start_timer(ed)
	}

	// The page asks for the whole state once it has loaded, so nothing marked
	// before now needs sending on its own.
	intrinsics.atomic_store_explicit(&s.panel_reload, false, .Relaxed)
	for w in 0 ..< PARAM_WORDS {
		intrinsics.atomic_store_explicit(&s.panel_dirty[w], 0, .Relaxed)
	}

	// One live view per unit. An older one the host still holds goes inert
	// rather than two pages steering one instance.
	if s.editor != nil {
		s.editor.unit = nil
	}
	s.editor = ed
	return container
}

@(private = "file")
editor_start_timer :: proc(ed: ^Au_Editor) {
	timer_context := au.CF_Run_Loop_Timer_Context {
		info = ed,
	}
	first := au.CFAbsoluteTimeGetCurrent() + TICK_SECONDS
	ed.timer = au.CFRunLoopTimerCreate(nil, first, TICK_SECONDS, 0, 0, editor_tick, &timer_context)
	if ed.timer == nil {
		return
	}
	// Common modes, so the panel keeps following automation while the host is
	// tracking the mouse or running a modal loop.
	au.CFRunLoopAddTimer(au.CFRunLoopGetMain(), ed.timer, au.kCFRunLoopCommonModes)
}

// Main thread, from the container's -dealloc.
@(private = "file")
editor_close :: proc(ed: ^Au_Editor) {
	if ed.timer != nil {
		au.CFRunLoopTimerInvalidate(ed.timer)
		au.CFRelease(ed.timer)
		ed.timer = nil
	}
	panel.stop(&ed.panel)
	if ed.unit != nil && ed.unit.editor == ed {
		ed.unit.editor = nil
	}
	delete(ed.panel.view.content_dir)
	free(ed)
}

// The unit is closing. A view the host still holds turns inert instead of
// reaching a freed unit; its container frees the rest when it goes.
editor_detach :: proc "contextless" (s: ^AU) {
	if s.editor != nil {
		s.editor.unit = nil
		s.editor = nil
	}
}

// -- host -> panel -----------------------------------------------------------

// Any thread, including render: lock-free and allocation-free.
mark_param_for_panel :: proc "contextless" (s: ^AU, index: int) {
	intrinsics.atomic_or_explicit(&s.panel_dirty[index / 64], u64(1) << uint(index % 64), .Release)
}

// The whole state was replaced (ClassInfo). Any thread.
mark_state_for_panel :: proc "contextless" (s: ^AU) {
	intrinsics.atomic_store_explicit(&s.panel_reload, true, .Release)
}

// Released after the values are written, so the render thread that takes the
// flag rebinds from values at least that new.
mark_params_dirty :: proc "contextless" (s: ^AU) {
	intrinsics.atomic_store_explicit(&s.params_dirty, true, .Release)
}

// The timer: what the host changed since the last tick, carried to the page.
@(private = "file")
editor_tick :: proc "c" (timer: au.CF_Run_Loop_Timer_Ref, info: rawptr) {
	ed := (^Au_Editor)(info)
	if ed == nil || ed.unit == nil || !ed.panel.open || ed.unit.editor != ed {
		return
	}
	s := ed.unit
	context = ed.ctx
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pool := webkit.pool_push()
	defer webkit.pool_pop(pool)

	reload := intrinsics.atomic_exchange_explicit(&s.panel_reload, false, .Acquire)
	dirty: [PARAM_WORDS]u64
	count := 0
	for w in 0 ..< PARAM_WORDS {
		dirty[w] = intrinsics.atomic_exchange_explicit(&s.panel_dirty[w], 0, .Acquire)
		count += int(intrinsics.count_ones(dirty[w]))
	}
	if reload || count > PANEL_PARAM_BURST {
		panel.send_state(&ed.panel)
		return
	}
	for word, w in dirty {
		bits := word
		for bits != 0 {
			index := w * 64 + int(intrinsics.count_trailing_zeros(bits))
			bits &= bits - 1
			if index < PARAM_COUNT {
				panel.send_param(&ed.panel, index, s.values[index])
			}
		}
	}
}

// -- what the panel asks of this host (main thread) --------------------------

@(private = "file")
editor_au :: proc "contextless" (user: rawptr) -> ^AU {
	ed := (^Au_Editor)(user)
	if ed == nil {
		return nil
	}
	return ed.unit
}

// Tell the host a parameter moved or a gesture began or ended, so it records
// automation and its own displays follow. JUCE's AU wrapper does the same.
@(private = "file")
notify_host :: proc "contextless" (s: ^AU, event_type: u32, index: int) {
	if s.instance == nil {
		return
	}
	event := au.Audio_Unit_Event {
		event_type = event_type,
		argument = au.Audio_Unit_Parameter {
			audio_unit = s.instance,
			parameter_id = u32(index),
			scope = au.SCOPE_GLOBAL,
			element = 0,
		},
	}
	au.AUEventListenerNotify(nil, nil, &event)
}

@(private = "file")
editor_read_values :: proc(user: rawptr, out: []i32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	for i in 0 ..< min(len(out), PARAM_COUNT) {
		out[i] = s.values[i]
	}
}

// Marked rather than applied: au_render rebinds on the audio thread, so the
// engine is never rebuilt underneath a render. A host that echoes the change
// back through AudioUnitSetParameter finds the value already there, so the
// panel's own moves do not come back to it.
@(private = "file")
editor_set_param :: proc(user: rawptr, index: int, stored: i32) {
	s := editor_au(user)
	if s == nil || index < 0 || index >= PARAM_COUNT {
		return
	}
	value := i32(param_clamp(index, f32(stored)))
	if s.values[index] == value {
		return
	}
	s.values[index] = value
	mark_params_dirty(s)
	notify_host(s, au.EVENT_PARAMETER_VALUE_CHANGE, index)
}

// A whole patch: one rebind, and every parameter that moved reported.
@(private = "file")
editor_set_state :: proc(user: rawptr, values: []i32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	changed: [PARAM_WORDS]u64
	any_changed := false
	for v, i in values {
		if i >= PARAM_COUNT {
			break
		}
		value := i32(param_clamp(i, f32(v)))
		if s.values[i] != value {
			s.values[i] = value
			changed[i / 64] |= u64(1) << uint(i % 64)
			any_changed = true
		}
	}
	if !any_changed {
		return
	}
	mark_params_dirty(s)
	for word, w in changed {
		bits := word
		for bits != 0 {
			index := w * 64 + int(intrinsics.count_trailing_zeros(bits))
			bits &= bits - 1
			notify_host(s, au.EVENT_PARAMETER_VALUE_CHANGE, index)
		}
	}
}

@(private = "file")
editor_edit :: proc(user: rawptr, index: int, begin: bool) {
	s := editor_au(user)
	if s == nil || index < 0 || index >= PARAM_COUNT {
		return
	}
	notify_host(s, au.EVENT_BEGIN_PARAMETER_CHANGE_GESTURE if begin else au.EVENT_END_PARAMETER_CHANGE_GESTURE, index)
}

// Notes, bend and controllers are queued and played at the top of the next
// render, never here: allocating a voice on this thread would race the render.
@(private = "file")
editor_note :: proc(user: rawptr, on: bool, note: int, velocity: f32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	panel.push_event(&s.ui_queue, panel.Ui_Event{kind = .Note_On if on else .Note_Off, a = i32(note), b = velocity})
}

@(private = "file")
editor_bend :: proc(user: rawptr, amount: f32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	panel.push_event(&s.ui_queue, panel.Ui_Event{kind = .Bend, b = amount})
}

@(private = "file")
editor_control :: proc(user: rawptr, cc: int, value: f32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	panel.push_event(&s.ui_queue, panel.Ui_Event{kind = .Control, a = i32(cc), b = value})
}

// One float written here and read by the render, which smooths toward it.
@(private = "file")
editor_volume :: proc(user: rawptr, amount: f32) {
	s := editor_au(user)
	if s == nil {
		return
	}
	s.volume = amount
}

// The panel changed the bank: play out of it, and keep it when it is the
// panel's own. The text is written as it arrived, as the VST3 and CLAP editors
// write it.
@(private = "file")
editor_set_bank :: proc(user: rawptr, text: string, save: bool) {
	s := editor_au(user)
	if s == nil || text == "" {
		return
	}
	parsed, err := patch.parse_bank_json(transmute([]u8)text)
	if err != .None {
		// Refused rather than written: a bank that will not parse would come
		// back as no bank at all next time.
		return
	}
	defer patch.destroy_bank(parsed)
	patch.slots_load(&s.slots, parsed)
	s.slots_loaded = true
	if save {
		if path := au_bank_path(context.temp_allocator); path != "" {
			panel.bank_write_to(path, text)
		}
	}
}

@(private = "file")
editor_read_bank :: proc(user: rawptr) -> string {
	s := editor_au(user)
	if s == nil || !s.slots_loaded {
		return ""
	}
	return patch.slots_write_json(&s.slots, context.temp_allocator)
}

// The bank, read when the editor first opens rather than when the unit is made:
// nothing else in the AU selects out of it yet, and a unit a host only scans
// should not read a file for a panel it never shows.
@(private = "file")
editor_load_bank :: proc(s: ^AU) {
	if s.slots_loaded {
		return
	}
	patch.factory_prepare()
	if path := au_bank_path(context.temp_allocator); path != "" {
		panel.bank_load_from(path, &s.slots)
	} else {
		patch.slots_load_factory(&s.slots)
	}
	s.slots_loaded = true
}

// ~/Library/Application Support/Quesynth/user-bank.json, or "" without a HOME.
// hosts/panel's bank_path is the Windows location; the AU hands this path to
// the same bank_load_from and bank_write_to, so the shared file stays as it is.
au_bank_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	path, err := filepath.join({home, "Library", "Application Support", "Quesynth", "user-bank.json"}, allocator)
	if err != nil {
		return ""
	}
	return path
}
