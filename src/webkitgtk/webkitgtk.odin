#+build linux
package webkitgtk

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:sys/posix"

// WebKitGTK, bound by hand and loaded at run time.
//
// The Linux counterpart of src/webview2: the panel in ui/ hosted in a
// WebKitWebView, the same way Windows hosts it in WebView2. Only the entry
// points this package calls are bound, from their documented C signatures in
// the webkit2gtk-4.1 (GTK 3) API.
//
// Loaded, not linked, for the reason hosts/standalone/audio_alsa.odin gives for
// libasound: a build must not need the -dev packages installed, and a machine
// without WebKitGTK should cost nothing and simply have no editor. A plugin that
// linked against it would instead fail to load at all on such a machine, which
// is the one failure a plugin must never have -- the instrument works without
// its panel, and the host draws its own controls.
//
// The libraries are the runtime sonames every desktop distribution ships with
// WebKitGTK 4.1. JavaScriptCore's two entry points are looked up through the
// WebKit handle, which already depends on it.

LIB_GLIB :: "libglib-2.0.so.0"
LIB_GOBJECT :: "libgobject-2.0.so.0"
LIB_GDK :: "libgdk-3.so.0"
LIB_GTK :: "libgtk-3.so.0"
LIB_WEBKIT :: "libwebkit2gtk-4.1.so.0"

// GPollFD, which on Unix has the layout of struct pollfd.
Poll_Fd :: struct {
	fd:      i32,
	events:  u16,
	revents: u16,
}

#assert(size_of(Poll_Fd) == 8)

// GIOCondition
IO_IN :: u16(1)
IO_PRI :: u16(2)
IO_OUT :: u16(4)

// WebKitUserContentInjectedFrames and WebKitUserScriptInjectionTime
USER_CONTENT_INJECT_TOP_FRAME :: c.int(1)
USER_SCRIPT_INJECT_AT_DOCUMENT_START :: c.int(0)

// gboolean is a C int, not a C bool.
gboolean :: b32

Api :: struct {
	// GLib
	g_free:                     proc "c" (mem: rawptr),
	g_filename_to_uri:          proc "c" (filename: cstring, hostname: cstring, error: ^rawptr) -> cstring,
	g_main_context_default:     proc "c" () -> rawptr,
	g_main_context_acquire:     proc "c" (ctx: rawptr) -> gboolean,
	g_main_context_release:     proc "c" (ctx: rawptr),
	g_main_context_prepare:     proc "c" (ctx: rawptr, priority: ^c.int) -> gboolean,
	g_main_context_query:       proc "c" (ctx: rawptr, max_priority: c.int, timeout: ^c.int, fds: [^]Poll_Fd, n_fds: c.int) -> c.int,
	g_main_context_check:       proc "c" (ctx: rawptr, max_priority: c.int, fds: [^]Poll_Fd, n_fds: c.int) -> gboolean,
	g_main_context_dispatch:    proc "c" (ctx: rawptr),
	g_poll:                     proc "c" (fds: [^]Poll_Fd, nfds: c.uint, timeout: c.int) -> c.int,

	// GObject
	g_signal_connect_data:      proc "c" (instance: rawptr, signal: cstring, handler: rawptr, data: rawptr, destroy: rawptr, flags: c.int) -> c.ulong,
	g_signal_handler_disconnect: proc "c" (instance: rawptr, id: c.ulong),
	g_object_unref:             proc "c" (object: rawptr),

	// GDK
	gdk_set_allowed_backends:   proc "c" (backends: cstring),
	gdk_window_show:            proc "c" (window: rawptr),
	gdk_flush:                  proc "c" (),
	gdk_error_trap_push:        proc "c" (),
	gdk_error_trap_pop_ignored: proc "c" (),

	// GTK
	gtk_disable_setlocale:      proc "c" (),
	gtk_init_check:             proc "c" (argc: ^c.int, argv: rawptr) -> gboolean,
	gtk_plug_new:               proc "c" (socket_id: c.ulong) -> rawptr,
	gtk_plug_get_embedded:      proc "c" (plug: rawptr) -> gboolean,
	gtk_container_add:          proc "c" (container: rawptr, widget: rawptr),
	gtk_widget_show_all:        proc "c" (widget: rawptr),
	gtk_widget_get_window:      proc "c" (widget: rawptr) -> rawptr,
	gtk_widget_destroy:         proc "c" (widget: rawptr),
	gtk_window_resize:          proc "c" (window: rawptr, width: c.int, height: c.int),

	// WebKit
	webkit_user_content_manager_new: proc "c" () -> rawptr,
	webkit_user_content_manager_register_script_message_handler: proc "c" (manager: rawptr, name: cstring) -> gboolean,
	webkit_user_content_manager_unregister_script_message_handler: proc "c" (manager: rawptr, name: cstring),
	webkit_user_content_manager_add_script: proc "c" (manager: rawptr, script: rawptr),
	webkit_user_script_new:     proc "c" (source: cstring, frames: c.int, time: c.int, allow_list: rawptr, block_list: rawptr) -> rawptr,
	webkit_user_script_unref:   proc "c" (script: rawptr),
	webkit_web_view_new_with_user_content_manager: proc "c" (manager: rawptr) -> rawptr,
	webkit_web_view_load_uri:   proc "c" (view: rawptr, uri: cstring),
	webkit_javascript_result_get_js_value: proc "c" (result: rawptr) -> rawptr,
	jsc_value_to_string:        proc "c" (value: rawptr) -> cstring,

	// Running script in the page. evaluate_javascript is 2.40 and later and
	// replaces run_javascript, which is deprecated but still present; whichever
	// the installed library has is used, and at least one has to be there.
	webkit_web_view_evaluate_javascript: proc "c" (view: rawptr, script: cstring, length: int, world_name: cstring, source_uri: cstring, cancellable: rawptr, callback: rawptr, user_data: rawptr),
	webkit_web_view_run_javascript: proc "c" (view: rawptr, script: cstring, cancellable: rawptr, callback: rawptr, user_data: rawptr),
}

@(private)
api: Api

@(private)
Stage :: enum {
	Untried,
	Ready,
	Failed,
}

@(private)
loaded: Stage
@(private)
started: Stage

// A process that already has GTK 2 in it cannot have GTK 3 as well.
//
// GTK 3 checks for this itself when it initialises -- it looks up
// gtk_progress_get_type, a GTK 2 symbol, in the process's global scope -- and
// the check is not a refusal but an abort: the whole process goes, and here the
// process is somebody's DAW with an unsaved session in it. Ardour is the host
// this matters for: it is built on its own copy of GTK 2, linked into the
// executable, so any GTK 3 plugin editor would take it down on opening.
//
// So the same lookup is made here first, the same way, and a process that
// answers it gets no editor. Before anything is loaded, too: WebKitGTK's own
// references to GTK would otherwise resolve against GTK 2's symbols of the same
// names.
@(private)
gtk2_present :: proc() -> bool {
	self := posix.dlopen(nil, {.LAZY})
	if self == nil {
		return false
	}
	defer posix.dlclose(self)
	return posix.dlsym(self, "gtk_progress_get_type") != nil
}

// Load the libraries and bind every entry point. A missing library or a missing
// symbol is not fatal to anything: it means no editor, which the plugins report
// by not offering one. Tried once per process; the answer does not change.
load :: proc() -> bool {
	switch loaded {
	case .Ready:
		return true
	case .Failed:
		return false
	case .Untried:
	}
	loaded = .Failed

	if gtk2_present() {
		fmt.eprintln("Quesynth: this host has GTK 2 loaded, and GTK 3 cannot share a process with it; the editor is off and the host's own controls are used instead")
		return false
	}

	glib := dynlib.load_library(LIB_GLIB) or_return
	gobject := dynlib.load_library(LIB_GOBJECT) or_return
	gdk := dynlib.load_library(LIB_GDK) or_return
	gtk := dynlib.load_library(LIB_GTK) or_return
	webkit := dynlib.load_library(LIB_WEBKIT) or_return

	ok := true
	a := &api

	a.g_free = auto_cast symbol(glib, "g_free", &ok)
	a.g_filename_to_uri = auto_cast symbol(glib, "g_filename_to_uri", &ok)
	a.g_main_context_default = auto_cast symbol(glib, "g_main_context_default", &ok)
	a.g_main_context_acquire = auto_cast symbol(glib, "g_main_context_acquire", &ok)
	a.g_main_context_release = auto_cast symbol(glib, "g_main_context_release", &ok)
	a.g_main_context_prepare = auto_cast symbol(glib, "g_main_context_prepare", &ok)
	a.g_main_context_query = auto_cast symbol(glib, "g_main_context_query", &ok)
	a.g_main_context_check = auto_cast symbol(glib, "g_main_context_check", &ok)
	a.g_main_context_dispatch = auto_cast symbol(glib, "g_main_context_dispatch", &ok)
	a.g_poll = auto_cast symbol(glib, "g_poll", &ok)

	a.g_signal_connect_data = auto_cast symbol(gobject, "g_signal_connect_data", &ok)
	a.g_signal_handler_disconnect = auto_cast symbol(gobject, "g_signal_handler_disconnect", &ok)
	a.g_object_unref = auto_cast symbol(gobject, "g_object_unref", &ok)

	a.gdk_set_allowed_backends = auto_cast symbol(gdk, "gdk_set_allowed_backends", &ok)
	a.gdk_window_show = auto_cast symbol(gdk, "gdk_window_show", &ok)
	a.gdk_flush = auto_cast symbol(gdk, "gdk_flush", &ok)
	a.gdk_error_trap_push = auto_cast symbol(gdk, "gdk_error_trap_push", &ok)
	a.gdk_error_trap_pop_ignored = auto_cast symbol(gdk, "gdk_error_trap_pop_ignored", &ok)

	a.gtk_disable_setlocale = auto_cast symbol(gtk, "gtk_disable_setlocale", &ok)
	a.gtk_init_check = auto_cast symbol(gtk, "gtk_init_check", &ok)
	a.gtk_plug_new = auto_cast symbol(gtk, "gtk_plug_new", &ok)
	a.gtk_plug_get_embedded = auto_cast symbol(gtk, "gtk_plug_get_embedded", &ok)
	a.gtk_container_add = auto_cast symbol(gtk, "gtk_container_add", &ok)
	a.gtk_widget_show_all = auto_cast symbol(gtk, "gtk_widget_show_all", &ok)
	a.gtk_widget_get_window = auto_cast symbol(gtk, "gtk_widget_get_window", &ok)
	a.gtk_widget_destroy = auto_cast symbol(gtk, "gtk_widget_destroy", &ok)
	a.gtk_window_resize = auto_cast symbol(gtk, "gtk_window_resize", &ok)

	a.webkit_user_content_manager_new = auto_cast symbol(webkit, "webkit_user_content_manager_new", &ok)
	a.webkit_user_content_manager_register_script_message_handler = auto_cast symbol(webkit, "webkit_user_content_manager_register_script_message_handler", &ok)
	a.webkit_user_content_manager_unregister_script_message_handler = auto_cast symbol(webkit, "webkit_user_content_manager_unregister_script_message_handler", &ok)
	a.webkit_user_content_manager_add_script = auto_cast symbol(webkit, "webkit_user_content_manager_add_script", &ok)
	a.webkit_user_script_new = auto_cast symbol(webkit, "webkit_user_script_new", &ok)
	a.webkit_user_script_unref = auto_cast symbol(webkit, "webkit_user_script_unref", &ok)
	a.webkit_web_view_new_with_user_content_manager = auto_cast symbol(webkit, "webkit_web_view_new_with_user_content_manager", &ok)
	a.webkit_web_view_load_uri = auto_cast symbol(webkit, "webkit_web_view_load_uri", &ok)
	a.webkit_javascript_result_get_js_value = auto_cast symbol(webkit, "webkit_javascript_result_get_js_value", &ok)
	a.jsc_value_to_string = auto_cast symbol(webkit, "jsc_value_to_string", &ok)

	// Either of the two, so neither is required on its own.
	a.webkit_web_view_evaluate_javascript = auto_cast dynlib.symbol_address(webkit, "webkit_web_view_evaluate_javascript")
	a.webkit_web_view_run_javascript = auto_cast dynlib.symbol_address(webkit, "webkit_web_view_run_javascript")
	if a.webkit_web_view_evaluate_javascript == nil && a.webkit_web_view_run_javascript == nil {
		ok = false
	}

	if !ok {
		// The libraries stay loaded. Nothing has been initialised, and GTK
		// marks itself not to be unloaded in any case.
		return false
	}
	loaded = .Ready
	return true
}

@(private)
symbol :: proc(lib: dynlib.Library, name: string, ok: ^bool) -> rawptr {
	ptr, found := dynlib.symbol_address(lib, name)
	if !found {
		ok^ = false
	}
	return ptr
}

// Initialise GTK, once per process and on the thread the host runs its
// interface on, which is the only thread GTK may then be used from.
//
// X11 only. The host hands over an X11 window, and GtkPlug -- how the view gets
// inside it -- exists only on X11; a Wayland session reaches this through
// XWayland. setlocale is left alone: GTK would otherwise switch the host's whole
// process to the user's locale, and a host that prints or parses numbers with a
// decimal comma it did not ask for is a broken host.
@(private)
start_gtk :: proc() -> bool {
	switch started {
	case .Ready:
		return true
	case .Failed:
		return false
	case .Untried:
	}
	started = .Failed
	if !load() {
		return false
	}
	api.gdk_set_allowed_backends("x11")
	api.gtk_disable_setlocale()
	if !api.gtk_init_check(nil, nil) {
		// No display to open: nowhere to show a view.
		return false
	}
	started = .Ready
	return true
}
