#+build windows
package synth_vst3

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

import "../../src/engine"
import "../../src/vst3"
import "../../src/webview2"

// The editor: the interface in ui/ hosted in an Edge WebView2 control.
//
// The point of this file is that there is only one interface. The same HTML
// that opens in a browser, ships in the WebAssembly build and runs on a phone
// is what a DAW shows, because `ui/bridge.js` was written to find whatever host
// it is in and talk to it in one vocabulary. Everything here is the other end
// of that conversation.
//
// The wire format is documented at the top of ui/bridge.js and is deliberately
// in *stored .sy1 integers* rather than normalised floats. This file is the
// only place in the plugin that converts between the two, and it converts at
// the VST3 edge, where the parameter's state count is known.

// The size the window opens at. The panel is responsive and will lay itself out
// at whatever the host allows, so this is a starting point rather than a
// constraint -- but it should be big enough that no section starts out
// scrolled.
EDITOR_WIDTH :: i32(1180)
EDITOR_HEIGHT :: i32(720)

// The folder in ui/ is mapped to this name so the page loads over https with a
// real origin. A `.invalid` domain can never resolve on the public internet,
// which is the point: nothing here should ever reach the network.
CONTENT_HOST :: "synth.invalid"
START_URL :: "https://synth.invalid/index.html"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: win.wstring, phModule: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: win.DWORD(0x00000004)
GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: win.DWORD(0x00000002)

Editor :: struct {
	// First, and for the same reason as in plugin.odin: an interface pointer is
	// the address of the vtable field, so this must be at offset zero for the
	// cast back to work.
	vtbl:      ^vst3.IPlugView_Vtbl,
	ref_count: i32,

	plugin:    ^Plugin,
	frame:     ^vst3.IPlugFrame,
	view:      webview2.View,

	width:     i32,
	height:    i32,
	open:      bool,

	ctx:       runtime.Context,
}

from_view :: proc "contextless" (this: rawptr) -> ^Editor {
	return (^Editor)(this)
}

// -- where the plugin lives --------------------------------------------------

// The directory holding this DLL.
//
// Found from the address of a procedure in this module rather than from the
// process, because the process is the DAW and its directory is not ours. This
// is what makes the bundle relocatable: nothing is looked up by absolute path
// or by an environment variable a host may not have set.
//
// The result borrows from the temporary allocator and must not be freed.
// `filepath.dir` does not allocate -- it returns a slice of the path handed to
// it -- so deleting the result would free a pointer into the temp arena
// through the heap allocator, which is a crash and not a leak.
module_dir :: proc() -> (string, bool) {
	module: win.HMODULE
	flags := GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT
	if !GetModuleHandleExW(flags, win.wstring(rawptr(module_dir)), &module) {
		return "", false
	}

	buffer: [win.MAX_PATH_WIDE]u16
	length := win.GetModuleFileNameW(module, &buffer[0], win.MAX_PATH_WIDE)
	if length == 0 || int(length) >= len(buffer) {
		return "", false
	}

	path, err := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length), context.temp_allocator)
	if err != nil {
		return "", false
	}
	return filepath.dir(path), true
}

// WebView2 needs somewhere writable of its own. Under the user's local app data
// rather than beside the plugin: a bundle in Program Files is not writable, and
// a browser profile is per-user anyway.
user_data_dir :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", allocator)
	if local == "" {
		return strings.clone(".", allocator)
	}
	joined, err := filepath.join({local, "Quesynth", "WebView2"}, allocator)
	if err != nil {
		return strings.clone(".", allocator)
	}
	return joined
}

// -- IPlugView ---------------------------------------------------------------

view_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	if obj == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	if vst3.tuid_equal(iid, vst3.IID_FUNKNOWN()) || vst3.tuid_equal(iid, vst3.IID_PLUG_VIEW()) {
		obj^ = this
		ed := from_view(this)
		ed.ref_count += 1
		return vst3.RESULT_OK
	}
	obj^ = nil
	return vst3.NO_INTERFACE
}

view_add_ref :: proc "c" (this: rawptr) -> u32 {
	ed := from_view(this)
	ed.ref_count += 1
	return u32(ed.ref_count)
}

view_release :: proc "c" (this: rawptr) -> u32 {
	ed := from_view(this)
	context = ed.ctx
	ed.ref_count -= 1
	if ed.ref_count > 0 {
		return u32(ed.ref_count)
	}
	if ed.plugin != nil && ed.plugin.editor == ed {
		ed.plugin.editor = nil
	}
	if ed.open {
		webview2.destroy(&ed.view)
		ed.open = false
	}
	delete(ed.view.content_dir)
	free(ed)
	return 0
}

view_is_platform_type_supported :: proc "c" (this: rawptr, type: cstring) -> vst3.Result {
	if type == nil {
		return vst3.INVALID_ARGUMENT
	}
	return vst3.RESULT_OK if string(type) == vst3.PLATFORM_TYPE_HWND else vst3.RESULT_FALSE
}

// The host hands over a window. Everything the editor is gets built here and
// torn down in `removed`, because a view may be attached and detached several
// times over its life and must not leak a browser process each time.
view_attached :: proc "c" (this: rawptr, parent: rawptr, type: cstring) -> vst3.Result {
	ed := from_view(this)
	context = ed.ctx

	if parent == nil || type == nil || string(type) != vst3.PLATFORM_TYPE_HWND {
		return vst3.INVALID_ARGUMENT
	}
	if ed.open {
		return vst3.RESULT_FALSE
	}

	ed.view.parent = win.HWND(parent)
	ed.view.bounds = win.RECT{0, 0, ed.width, ed.height}
	ed.view.host_name = CONTENT_HOST
	ed.view.start_url = START_URL
	ed.view.on_message = editor_on_message
	ed.view.user = rawptr(ed)

	data_dir := user_data_dir(context.temp_allocator)
	if !webview2.create(&ed.view, data_dir) {
		// No runtime, or the loader refused. The host keeps the window; it just
		// stays empty. Said plainly rather than pretended away: returning OK
		// here would claim an editor that is not there.
		return vst3.RESULT_FALSE
	}
	ed.open = true
	return vst3.RESULT_OK
}

view_removed :: proc "c" (this: rawptr) -> vst3.Result {
	ed := from_view(this)
	context = ed.ctx
	if ed.open {
		webview2.destroy(&ed.view)
		ed.open = false
	}
	ed.view.parent = nil
	return vst3.RESULT_OK
}

view_on_wheel :: proc "c" (this: rawptr, distance: f32) -> vst3.Result {
	return vst3.RESULT_FALSE
}

view_on_key_down :: proc "c" (this: rawptr, key: u16, key_code: i16, modifiers: i16) -> vst3.Result {
	return vst3.RESULT_FALSE
}

view_on_key_up :: proc "c" (this: rawptr, key: u16, key_code: i16, modifiers: i16) -> vst3.Result {
	return vst3.RESULT_FALSE
}

view_get_size :: proc "c" (this: rawptr, size: ^vst3.View_Rect) -> vst3.Result {
	if size == nil {
		return vst3.INVALID_ARGUMENT
	}
	ed := from_view(this)
	size^ = vst3.View_Rect{0, 0, ed.width, ed.height}
	return vst3.RESULT_OK
}

view_on_size :: proc "c" (this: rawptr, new_size: ^vst3.View_Rect) -> vst3.Result {
	if new_size == nil {
		return vst3.INVALID_ARGUMENT
	}
	ed := from_view(this)
	context = ed.ctx

	// A ViewRect is edges, not a size. Subtracting is the whole conversion, and
	// treating right/bottom as width/height puts the control off the window.
	ed.width = new_size.right - new_size.left
	ed.height = new_size.bottom - new_size.top
	webview2.set_bounds(&ed.view, win.RECT{0, 0, ed.width, ed.height})
	return vst3.RESULT_OK
}

view_on_focus :: proc "c" (this: rawptr, state: u8) -> vst3.Result {
	return vst3.RESULT_OK
}

view_set_frame :: proc "c" (this: rawptr, frame: ^vst3.IPlugFrame) -> vst3.Result {
	ed := from_view(this)
	ed.frame = frame
	return vst3.RESULT_OK
}

// The panel is responsive, so any size the host offers is a size it can use.
view_can_resize :: proc "c" (this: rawptr) -> vst3.Result {
	return vst3.RESULT_OK
}

view_check_size_constraint :: proc "c" (this: rawptr, rect: ^vst3.View_Rect) -> vst3.Result {
	if rect == nil {
		return vst3.INVALID_ARGUMENT
	}
	// A floor rather than a fixed size: below this the section strip and the
	// keyboard start overlapping and the window stops being usable.
	if rect.right - rect.left < 640 {
		rect.right = rect.left + 640
	}
	if rect.bottom - rect.top < 420 {
		rect.bottom = rect.top + 420
	}
	return vst3.RESULT_OK
}

VIEW_VTBL := vst3.IPlugView_Vtbl {
	query_interface            = view_query_interface,
	add_ref                    = view_add_ref,
	release                    = view_release,
	is_platform_type_supported = view_is_platform_type_supported,
	attached                   = view_attached,
	removed                    = view_removed,
	on_wheel                   = view_on_wheel,
	on_key_down                = view_on_key_down,
	on_key_up                  = view_on_key_up,
	get_size                   = view_get_size,
	on_size                    = view_on_size,
	on_focus                   = view_on_focus,
	set_frame                  = view_set_frame,
	can_resize                 = view_can_resize,
	check_size_constraint      = view_check_size_constraint,
}

// -- creating the editor -----------------------------------------------------

make_editor :: proc(p: ^Plugin) -> ^Editor {
	// Borrowed from the temp allocator; see module_dir. Not freed here.
	dir, ok := module_dir()
	if !ok {
		return nil
	}

	// The loader sits beside the binary and the panel one level up in
	// Resources, which is the layout tools/install-vst3.ps1 assembles. Loading the DLL
	// before anything is allocated means a machine without WebView2 costs
	// nothing and simply has no editor.
	loader, loader_err := filepath.join({dir, "WebView2Loader.dll"}, context.temp_allocator)
	if loader_err != nil || !webview2.load(loader) {
		return nil
	}

	content, content_err := filepath.join({dir, "..", "Resources", "ui"})
	if content_err != nil {
		return nil
	}
	if !os.exists(content) {
		delete(content)
		return nil
	}

	ed := new(Editor)
	if ed == nil {
		delete(content)
		return nil
	}
	ed.vtbl = &VIEW_VTBL
	ed.ref_count = 1
	ed.plugin = p
	ed.width = EDITOR_WIDTH
	ed.height = EDITOR_HEIGHT
	ed.ctx = p.ctx
	ed.view.content_dir = content
	return ed
}

// -- messages from the panel -------------------------------------------------

// Everything the interface sends arrives here as one JSON object. The types are
// the ones listed at the top of ui/bridge.js.
editor_on_message :: proc(user: rawptr, text: string) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	p := ed.plugin

	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return
	}

	kind, has_kind := json_string(object, "type")
	if !has_kind {
		return
	}

	switch kind {
	case "sync":
		editor_send_state(ed)

	case "set":
		index, has_index := json_int(object, "index")
		stored, has_value := json_int(object, "value")
		if !has_index || !has_value || index < 0 || int(index) >= PARAM_COUNT {
			return
		}
		p.values[index] = i32(stored)
		// Marked rather than applied: `process` rebinds on the audio thread when
		// it next runs, so the engine is never rebuilt underneath a render.
		p.params_dirty = true
		// And told to the host, or the move exists only inside the web view --
		// no automation recorded, and a session saved without it.
		if p.handler != nil {
			handler := (^vst3.IComponentHandler)(p.handler)
			handler.vtbl.perform_edit(p.handler, u32(index), normalized_of(int(index), i32(stored)))
		}

	case "edit":
		index, has_index := json_int(object, "index")
		begin, has_begin := json_bool(object, "begin")
		if !has_index || !has_begin || index < 0 || int(index) >= PARAM_COUNT {
			return
		}
		if p.handler != nil {
			handler := (^vst3.IComponentHandler)(p.handler)
			if begin {
				handler.vtbl.begin_edit(p.handler, u32(index))
			} else {
				handler.vtbl.end_edit(p.handler, u32(index))
			}
		}

	case "note":
		note, has_note := json_int(object, "note")
		on, has_on := json_bool(object, "on")
		if !has_note || !has_on {
			return
		}
		velocity, has_velocity := json_int(object, "velocity")
		if !has_velocity {
			velocity = 100
		}
		if on {
			push_ui_event(p, UI_Event{kind = .Note_On, a = i32(note), b = f32(velocity) / 127.0})
		} else {
			push_ui_event(p, UI_Event{kind = .Note_Off, a = i32(note)})
		}

	case "wheel":
		which, has_which := json_string(object, "which")
		amount, has_amount := json_float(object, "value")
		if !has_which || !has_amount {
			return
		}
		if which == "pitch" {
			push_ui_event(p, UI_Event{kind = .Bend, b = f32(amount)})
		} else {
			// Controller 1, which is what parameters 86 and 88 name by default.
			push_ui_event(p, UI_Event{kind = .Control, a = 1, b = f32(amount * 127.0)})
		}

	case "volume":
		amount, has_amount := json_float(object, "value")
		if !has_amount {
			return
		}
		// One float written for another to read, and the audio thread smooths
		// whatever it finds. No queue: unlike a note, a stale value here is
		// simply the previous gain for one more block.
		p.volume = f32(clamp(amount, 0, 1))

	case "cc":
		cc, has_cc := json_int(object, "cc")
		amount, has_amount := json_int(object, "value")
		if !has_cc || !has_amount {
			return
		}
		push_ui_event(p, UI_Event{kind = .Control, a = i32(cc), b = f32(amount)})
	}
}

// -- messages to the panel ---------------------------------------------------

// The whole parameter set in one message, which is what the panel asks for when
// it loads. One message rather than ninety-nine because the panel rebuilds its
// controls from it in a single pass.
editor_send_state :: proc(ed: ^Editor) {
	if ed == nil || ed.plugin == nil {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"state","values":[`)
	for i in 0 ..< PARAM_COUNT {
		if i > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, int(ed.plugin.values[i]))
	}
	strings.write_string(&builder, `]}`)
	webview2.post(&ed.view, strings.to_string(builder))
}

// One parameter that changed somewhere else -- an automation lane, or the
// host's own generic panel -- so the web view follows instead of going stale.
editor_send_param :: proc(ed: ^Editor, index: int, stored: i32) {
	if ed == nil || !ed.view.ready {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"param","index":`)
	strings.write_int(&builder, index)
	strings.write_string(&builder, `,"value":`)
	strings.write_int(&builder, int(stored))
	strings.write_byte(&builder, '}')
	webview2.post(&ed.view, strings.to_string(builder))
}

// -- reading JSON ------------------------------------------------------------
//
// Small readers rather than a struct and a reflection pass: the messages have
// five shapes between them, and a missing field has to be distinguishable from
// a field that is present and zero.

json_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	return string(text), is_string
}

json_float :: proc(object: json.Object, key: string) -> (f64, bool) {
	value, found := object[key]
	if !found {
		return 0, false
	}
	#partial switch v in value {
	case json.Float:
		return f64(v), true
	case json.Integer:
		return f64(v), true
	}
	return 0, false
}

json_int :: proc(object: json.Object, key: string) -> (i64, bool) {
	amount, ok := json_float(object, key)
	if !ok {
		return 0, false
	}
	return i64(amount), true
}

json_bool :: proc(object: json.Object, key: string) -> (bool, bool) {
	value, found := object[key]
	if !found {
		return false, false
	}
	flag, is_bool := value.(json.Boolean)
	return bool(flag), is_bool
}
