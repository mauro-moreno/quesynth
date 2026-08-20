#+build windows
package synth_vst3

import "base:runtime"

import "../../src/patch"
import "../../src/vst3"
import "../panel"

// The editor: the interface in ui/ hosted in an Edge WebView2 control.
//
// The point of this file is that there is only one interface. The same HTML
// that opens in a browser, ships in the WebAssembly build and runs on a phone
// is what a DAW shows, because `ui/bridge.js` was written to find whatever host
// it is in and talk to it in one vocabulary. Everything here is the other end
// of that conversation.
//
// What is left in this file is IPlugView and nothing else. Starting the web
// view, finding the panel on disk and speaking the protocol all moved to
// hosts/panel when the CLAP build wanted the same interface -- and the reason
// they moved rather than being copied is written at the top of that file.
//
// The wire format is documented at the top of ui/bridge.js and is deliberately
// in *stored .sy1 integers* rather than normalised floats. This file is still
// the only place in the plugin that converts between the two, because that
// conversion belongs at the VST3 edge, where the parameter's state count is
// known.

Editor :: struct {
	// First, and for the same reason as in plugin.odin: an interface pointer is
	// the address of the vtable field, so this must be at offset zero for the
	// cast back to work.
	vtbl:      ^vst3.IPlugView_Vtbl,
	ref_count: i32,

	plugin:    ^Plugin,
	frame:     ^vst3.IPlugFrame,
	panel:     panel.Panel,

	ctx:       runtime.Context,
}

from_view :: proc "contextless" (this: rawptr) -> ^Editor {
	return (^Editor)(this)
}

// -- what the panel asks of this host ----------------------------------------

editor_read_values :: proc(user: rawptr, out: []i32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	for i in 0 ..< min(len(out), PARAM_COUNT) {
		out[i] = ed.plugin.values[i]
	}
}

editor_set_param :: proc(user: rawptr, index: int, stored: i32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	p := ed.plugin
	p.values[index] = stored
	// Marked rather than applied: `process` rebinds on the audio thread when it
	// next runs, so the engine is never rebuilt underneath a render.
	p.params_dirty = true
	// And told to the host, or the move exists only inside the web view -- no
	// automation recorded, and a session saved without it.
	if p.handler != nil {
		handler := (^vst3.IComponentHandler)(p.handler)
		handler.vtbl.perform_edit(p.handler, u32(index), normalized_of(index, stored))
	}
}

editor_set_state :: proc(user: rawptr, values: []i32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	p := ed.plugin
	count := min(len(values), PARAM_COUNT)
	for i in 0 ..< count {
		p.values[i] = values[i]
	}
	// One flag for the whole patch. Rebinding ninety-nine times on the way to
	// one sound is what `params_dirty` exists to avoid.
	p.params_dirty = true

	// Every parameter reported, or the host keeps the old automation values and
	// writes them back over this the moment the transport moves.
	if p.handler != nil {
		handler := (^vst3.IComponentHandler)(p.handler)
		for i in 0 ..< count {
			handler.vtbl.perform_edit(p.handler, u32(i), normalized_of(i, p.values[i]))
		}
	}
}

editor_edit :: proc(user: rawptr, index: int, begin: bool) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil || ed.plugin.handler == nil {
		return
	}
	p := ed.plugin
	handler := (^vst3.IComponentHandler)(p.handler)
	if begin {
		handler.vtbl.begin_edit(p.handler, u32(index))
	} else {
		handler.vtbl.end_edit(p.handler, u32(index))
	}
}

editor_note :: proc(user: rawptr, on: bool, note: int, velocity: f32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	if on {
		panel.push_event(&ed.plugin.ui_queue, panel.Ui_Event{kind = .Note_On, a = i32(note), b = velocity})
	} else {
		panel.push_event(&ed.plugin.ui_queue, panel.Ui_Event{kind = .Note_Off, a = i32(note)})
	}
}

editor_bend :: proc(user: rawptr, amount: f32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	panel.push_event(&ed.plugin.ui_queue, panel.Ui_Event{kind = .Bend, b = amount})
}

editor_control :: proc(user: rawptr, cc: int, value: f32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	panel.push_event(&ed.plugin.ui_queue, panel.Ui_Event{kind = .Control, a = i32(cc), b = value})
}

editor_volume :: proc(user: rawptr, amount: f32) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return
	}
	// One float written for another to read, and the audio thread smooths
	// whatever it finds. No queue: unlike a note, a stale value here is simply
	// the previous gain for one more block.
	ed.plugin.volume = amount
}

// The panel changed the bank: keep it, and play out of it.
//
// The text is written as it arrived rather than re-encoded, so what is saved
// is exactly what the panel produced; then it is parsed into this instance's
// slots, because a program change has to select out of the bank that is on
// screen and not the one loaded at startup.
editor_set_bank :: proc(user: rawptr, text: string, save: bool) {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil || text == "" {
		return
	}

	parsed, err := patch.parse_bank_json(transmute([]u8)text)
	if err != .None {
		// Refused rather than written: a bank that will not parse would come
		// back as no bank at all on the next start.
		return
	}
	defer patch.destroy_bank(parsed)

	// Always played, only sometimes kept; see the note on set_bank.
	patch.slots_load(&ed.plugin.slots, parsed)
	if save {
		panel.bank_write(text)
	}
}

// The bank this instance is playing out of, for the panel to show.
editor_read_bank :: proc(user: rawptr) -> string {
	ed := (^Editor)(user)
	if ed == nil || ed.plugin == nil {
		return ""
	}
	return patch.slots_write_json(&ed.plugin.slots, context.temp_allocator)
}

// The whole parameter set, after a state load: the panel is showing the patch
// from before it and has no way to know otherwise.
editor_send_state :: proc(ed: ^Editor) {
	if ed == nil {
		return
	}
	panel.send_state(&ed.panel)
}

// Which patch is loaded, by name and by number, so the strip follows a
// program change instead of naming the one before it.
editor_send_patch :: proc(ed: ^Editor, program: int) {
	if ed == nil {
		return
	}
	if ed.plugin == nil {
		return
	}
	panel.send_patch(
		&ed.panel,
		patch.slots_name(&ed.plugin.slots, program),
		program,
		patch.slots_label(&ed.plugin.slots),
	)
}

// One parameter that changed somewhere else -- an automation lane, or the
// host's own generic panel -- so the web view follows instead of going stale.
editor_send_param :: proc(ed: ^Editor, index: int, stored: i32) {
	if ed == nil {
		return
	}
	panel.send_param(&ed.panel, index, stored)
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
	panel.stop(&ed.panel)
	delete(ed.panel.view.content_dir)
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
	if ed.panel.open {
		return vst3.RESULT_FALSE
	}
	if !panel.start(&ed.panel, parent) {
		// No runtime, or the loader refused. The host keeps the window; it just
		// stays empty. Said plainly rather than pretended away: returning OK
		// here would claim an editor that is not there.
		return vst3.RESULT_FALSE
	}
	return vst3.RESULT_OK
}

view_removed :: proc "c" (this: rawptr) -> vst3.Result {
	ed := from_view(this)
	context = ed.ctx
	panel.stop(&ed.panel)
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
	size^ = vst3.View_Rect{0, 0, ed.panel.width, ed.panel.height}
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
	panel.resize(&ed.panel, new_size.right - new_size.left, new_size.bottom - new_size.top)
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
	// The panel sits one level up in Resources, which is the layout
	// tools/build-vst3.ps1 assembles.
	content, ok := panel.find_content({"../Resources/ui"})
	if !ok {
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
	ed.ctx = p.ctx

	ed.panel.width = panel.WIDTH
	ed.panel.height = panel.HEIGHT
	ed.panel.ctx = p.ctx
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
	return ed
}
