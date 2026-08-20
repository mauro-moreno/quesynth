#+build windows
package synth_clap

import "base:runtime"

import "../../src/clap"
import "../panel"

// The interface, in the CLAP build.
//
// The same panel the VST3 plugin shows and the same one that opens in a
// browser: what differs between the formats is only how a host hands over a
// window. CLAP calls that create/set_parent/show where VST3 calls it
// createView/attached, and everything after the window -- starting the web
// view, the protocol, the parameter conversions -- is in hosts/panel and
// shared.
//
// Windows only for now, and it says so rather than claiming otherwise:
// is_api_supported answers false for anything but win32, and a host that asks
// for something else gets no editor instead of an empty window.

// Where the panel is, relative to the plugin file.
//
// A CLAP plugin on Windows is a single file with no bundle around it, so there
// is nowhere *inside* it to put an interface. The convention here is a folder
// beside it, which is what tools/build-clap.ps1 assembles:
//
//   synth.clap
//   Quesynth-ui/          the panel
//   WebView2Loader.dll
//
// The VST3 layout is tried as well, so a build that puts both formats in one
// bundle still finds it. First match wins.
GUI_CONTENT :: []string{"Quesynth-ui", "ui", "../Resources/ui"}

gui_is_api_supported :: proc "c" (plugin: ^clap.Plugin, api: cstring, is_floating: bool) -> bool {
	if api == nil {
		return false
	}
	// Embedded only. A floating window would be the plugin creating and pumping
	// a window of its own, which is a different lifetime to get wrong and
	// nothing here needs it.
	if is_floating {
		return false
	}
	return string(api) == clap.WINDOW_API_WIN32
}

gui_get_preferred_api :: proc "c" (plugin: ^clap.Plugin, api: ^cstring, is_floating: ^bool) -> bool {
	if api == nil || is_floating == nil {
		return false
	}
	// The constant itself, not a copy: the header asks for a pointer to one of
	// the CLAP_WINDOW_API_ strings rather than a string the host must free.
	api^ = clap.WINDOW_API_WIN32
	is_floating^ = false
	return true
}

gui_create :: proc "c" (plugin: ^clap.Plugin, api: cstring, is_floating: bool) -> bool {
	s := synth_of(plugin)
	if s == nil {
		return false
	}
	context = runtime.default_context()

	if !gui_is_api_supported(plugin, api, is_floating) {
		return false
	}
	if s.panel_ready {
		return true
	}

	// The loader and the panel, before anything is allocated: a machine with no
	// WebView2 costs nothing and simply has no editor.
	content, ok := panel.find_content(GUI_CONTENT)
	if !ok {
		return false
	}

	s.editor.width = panel.WIDTH
	s.editor.height = panel.HEIGHT
	s.editor.ctx = context
	s.editor.view.content_dir = content
	s.editor.host = panel.Host {
		user        = rawptr(s),
		param_count = PARAM_COUNT,
		read_values = gui_read_values,
		set_param   = gui_set_param,
		set_state   = gui_set_state,
		edit        = gui_edit,
		note        = gui_note,
		bend        = gui_bend,
		control     = gui_control,
		volume      = gui_volume,
	}
	s.panel_ready = true
	return true
}

gui_destroy :: proc "c" (plugin: ^clap.Plugin) {
	s := synth_of(plugin)
	if s == nil || !s.panel_ready {
		return
	}
	context = runtime.default_context()
	panel.stop(&s.editor)
	if s.editor.view.content_dir != "" {
		delete(s.editor.view.content_dir)
		s.editor.view.content_dir = ""
	}
	s.panel_ready = false
}

gui_set_scale :: proc "c" (plugin: ^clap.Plugin, scale: f64) -> bool {
	// Ignored, which the header allows: the page is laid out in CSS pixels and
	// the web view applies the system scaling itself.
	return false
}

gui_get_size :: proc "c" (plugin: ^clap.Plugin, width: ^u32, height: ^u32) -> bool {
	s := synth_of(plugin)
	if s == nil || width == nil || height == nil {
		return false
	}
	width^ = u32(s.editor.width if s.editor.width > 0 else panel.WIDTH)
	height^ = u32(s.editor.height if s.editor.height > 0 else panel.HEIGHT)
	return true
}

// The panel is responsive, so any size the host offers is a size it can use.
gui_can_resize :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

gui_get_resize_hints :: proc "c" (plugin: ^clap.Plugin, hints: ^clap.Gui_Resize_Hints) -> bool {
	if hints == nil {
		return false
	}
	hints.can_resize_horizontally = true
	hints.can_resize_vertically = true
	hints.preserve_aspect_ratio = false
	hints.aspect_ratio_width = 0
	hints.aspect_ratio_height = 0
	return true
}

gui_adjust_size :: proc "c" (plugin: ^clap.Plugin, width: ^u32, height: ^u32) -> bool {
	if width == nil || height == nil {
		return false
	}
	// A floor rather than a fixed size: below this the section strip and the
	// keyboard start overlapping and the window stops being usable. The same
	// numbers the VST3 view enforces, for the same reason.
	if width^ < 640 {
		width^ = 640
	}
	if height^ < 420 {
		height^ = 420
	}
	return true
}

gui_set_size :: proc "c" (plugin: ^clap.Plugin, width: u32, height: u32) -> bool {
	s := synth_of(plugin)
	if s == nil {
		return false
	}
	context = runtime.default_context()
	panel.resize(&s.editor, i32(width), i32(height))
	return true
}

gui_set_parent :: proc "c" (plugin: ^clap.Plugin, window: ^clap.Window) -> bool {
	s := synth_of(plugin)
	if s == nil || window == nil || window.handle == nil {
		return false
	}
	if window.api == nil || string(window.api) != clap.WINDOW_API_WIN32 {
		return false
	}
	context = runtime.default_context()
	if s.editor.open {
		return true
	}
	return panel.start(&s.editor, window.handle)
}

gui_set_transient :: proc "c" (plugin: ^clap.Plugin, window: ^clap.Window) -> bool {
	// Floating windows only, and this plugin does not offer one.
	return false
}

gui_suggest_title :: proc "c" (plugin: ^clap.Plugin, title: cstring) {
	// Floating windows only.
}

// The web view is created on set_parent and lives until destroy, so showing and
// hiding are the host's business with the window it owns. Answering true rather
// than false because the request is satisfied -- there is nothing this side has
// to do to honour it.
gui_show :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

gui_hide :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

// -- what the panel asks of this host ----------------------------------------

gui_read_values :: proc(user: rawptr, out: []i32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	for i in 0 ..< min(len(out), PARAM_COUNT) {
		out[i] = s.values[i]
	}
}

gui_set_param :: proc(user: rawptr, index: int, stored: i32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	if s.values[index] != stored {
		s.values[index] = stored
		s.params_dirty = true
	}
	// And the host is told, or the move exists only inside the web view: no
	// automation recorded, and a session saved without it.
	notify_host_values(s)
}

gui_set_state :: proc(user: rawptr, values: []i32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	changed := false
	for v, i in values {
		if i >= PARAM_COUNT {
			break
		}
		if s.values[i] != v {
			s.values[i] = v
			changed = true
		}
	}
	if changed {
		s.params_dirty = true
		notify_host_values(s)
	}
}

gui_edit :: proc(user: rawptr, index: int, begin: bool) {
	// CLAP marks a gesture with the BEGIN and END adjust flags on the parameter
	// event itself rather than with separate calls, and this plugin reports
	// changes through params.flush rather than as events. Nothing to do here;
	// see the note on notify_params.
}

gui_note :: proc(user: rawptr, on: bool, note: int, velocity: f32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	panel.push_event(
		&s.ui_queue,
		panel.Ui_Event{kind = .Note_On if on else .Note_Off, a = i32(note), b = velocity},
	)
}

gui_bend :: proc(user: rawptr, amount: f32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	panel.push_event(&s.ui_queue, panel.Ui_Event{kind = .Bend, b = amount})
}

gui_control :: proc(user: rawptr, cc: int, value: f32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	panel.push_event(&s.ui_queue, panel.Ui_Event{kind = .Control, a = i32(cc), b = value})
}

gui_volume :: proc(user: rawptr, amount: f32) {
	s := (^Synth)(user)
	if s == nil {
		return
	}
	s.volume = amount
}

GUI := clap.Plugin_Gui {
	is_api_supported  = gui_is_api_supported,
	get_preferred_api = gui_get_preferred_api,
	create            = gui_create,
	destroy           = gui_destroy,
	set_scale         = gui_set_scale,
	get_size          = gui_get_size,
	can_resize        = gui_can_resize,
	get_resize_hints  = gui_get_resize_hints,
	adjust_size       = gui_adjust_size,
	set_size          = gui_set_size,
	set_parent        = gui_set_parent,
	set_transient     = gui_set_transient,
	suggest_title     = gui_suggest_title,
	show              = gui_show,
	hide              = gui_hide,
}
