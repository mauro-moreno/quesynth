#+build linux
package webkitgtk

import "base:runtime"
import "core:c"
import "core:path/filepath"
import "core:strings"

// The web view inside a host's window, and the host's event loop that runs it.
//
// The same shape as src/webview2's View -- create, destroy, post, set_bounds and
// an on_message callback -- so hosts/panel drives both the same way. What is
// different underneath is where the work gets done.
//
// WebView2 runs on the Windows message loop, which every GUI thread has. GTK
// runs on GLib's main context, which nobody in a plugin host is iterating: the
// host has its own loop, and a private one on a thread of the plugin's would be
// a second GUI thread inside somebody else's process. So the host is asked to do
// it. The view tells the host which file descriptors GLib is waiting on and asks
// for a timer, and every time one of those fires the host calls `pump`, which
// runs one pass of the main context -- exactly what GLib's own loop would have
// done at that moment, driven from outside. How a host is asked is a plugin
// format's business, so it arrives here as `Loop`: CLAP's posix-fd and timer
// extensions, or VST3's IRunLoop.
//
// The page talks to the plugin through ui/bridge.js's generic transport. A
// script injected before anything else on the page defines window.synthPost,
// which forwards to a WebKit script-message handler; the other way, the plugin
// evaluates window.synthReceive(...) in the page. The handler is deliberately
// not called `synth`: bridge.js would take that for a WKWebView host, which is
// a different transport with the same vocabulary.

MESSAGE_HANDLER :: "quesynth"
MESSAGE_SIGNAL :: "script-message-received::" + MESSAGE_HANDLER
BRIDGE_SCRIPT :: "window.synthPost = function (text) { window.webkit.messageHandlers." + MESSAGE_HANDLER + ".postMessage(text); };"

// How often GLib gets a pass when no descriptor wakes it: its own timeouts and
// idle callbacks run on the next one. About a frame, and above the floor a host
// is allowed to impose on a timer.
TIMER_PERIOD_MS :: 16

Message_Proc :: #type proc(user: rawptr, text: string)

// What a descriptor is being watched for. The bits are CLAP's own
// (CLAP_POSIX_FD_READ, _WRITE, _ERROR), so the CLAP host passes them through.
Fd_Flag :: enum u32 {
	Read  = 0,
	Write = 1,
	Error = 2,
}
Fd_Flags :: bit_set[Fd_Flag;u32]

// The host's event loop, as a plugin format presents it.
//
// `register_fd` and `modify_fd` may refuse; a refused descriptor is left to the
// timer. The timer may not: without it GLib's timeouts would never run, so a
// host that will not register one gets no view.
Loop :: struct {
	user:             rawptr,
	register_fd:      proc(user: rawptr, fd: i32, flags: Fd_Flags) -> bool,
	modify_fd:        proc(user: rawptr, fd: i32, flags: Fd_Flags) -> bool,
	unregister_fd:    proc(user: rawptr, fd: i32),
	register_timer:   proc(user: rawptr, period_ms: u32) -> bool,
	unregister_timer: proc(user: rawptr),
}

// One descriptor as the host knows it.
@(private)
Watch :: struct {
	fd:         i32,
	// What the host was last told, and what GLib asked for this pass.
	flags:      Fd_Flags,
	wanted:     Fd_Flags,
	// False when the host refused it. Kept anyway, so it is not offered again
	// on every pass while GLib goes on wanting it.
	registered: bool,
	offered:    bool,
	seen:       bool,
}

View :: struct {
	// The host's X11 window.
	parent:         c.ulong,
	width:          i32,
	height:         i32,

	// The panel's folder, and the page in it to open.
	content_dir:    string,
	start_page:     string,

	on_message:     Message_Proc,
	user:           rawptr,

	loop:           Loop,

	plug:           rawptr,
	webview:        rawptr,
	content:        rawptr,
	message_signal: c.ulong,

	// GLib's poll set from the last pass, and what the host is watching.
	polled:         [dynamic]Poll_Fd,
	watched:        [dynamic]Watch,
	timer:          bool,

	ready:          bool,
	closing:        bool,

	ctx:            runtime.Context,
}

// Build the view inside the host's window and start loading the panel.
//
// Returns false, having built nothing, when there is no WebKitGTK, no display,
// no such window, or no timer: the host keeps its window and it stays empty.
create :: proc(v: ^View) -> bool {
	if !start_gtk() {
		return false
	}
	v.ctx = context
	v.closing = false
	v.ready = false

	page, join_err := filepath.join({v.content_dir, v.start_page}, context.temp_allocator)
	if join_err != nil {
		return false
	}
	uri := api.g_filename_to_uri(strings.clone_to_cstring(page, context.temp_allocator), nil, nil)
	if uri == nil {
		return false
	}
	defer api.g_free(rawptr(uri))

	// A GtkPlug is a toplevel whose X window is created as a child of another
	// program's window, which is exactly the arrangement here. If the id does
	// not name a window there is nothing to embed in, and an unembedded plug
	// would appear on the desktop as a window of its own.
	plug := api.gtk_plug_new(v.parent)
	if plug == nil {
		return false
	}
	if !api.gtk_plug_get_embedded(plug) {
		api.gtk_widget_destroy(plug)
		return false
	}
	v.plug = plug

	content := api.webkit_user_content_manager_new()
	v.content = content
	api.webkit_user_content_manager_register_script_message_handler(content, MESSAGE_HANDLER)
	script := api.webkit_user_script_new(
		BRIDGE_SCRIPT,
		USER_CONTENT_INJECT_TOP_FRAME,
		USER_SCRIPT_INJECT_AT_DOCUMENT_START,
		nil,
		nil,
	)
	api.webkit_user_content_manager_add_script(content, script)
	api.webkit_user_script_unref(script)
	v.message_signal = api.g_signal_connect_data(content, MESSAGE_SIGNAL, rawptr(on_script_message), v, nil, 0)

	webview := api.webkit_web_view_new_with_user_content_manager(content)
	v.webview = webview
	// A right-click menu offering Reload inside a plugin window is a way to
	// lose a patch, not a feature -- the same call the WebView2 host makes.
	api.g_signal_connect_data(webview, "context-menu", rawptr(on_context_menu), nil, nil, 0)

	api.gtk_container_add(plug, webview)
	api.gtk_window_resize(plug, max(v.width, 1), max(v.height, 1))
	api.gtk_widget_show_all(plug)
	// A plug waits for the program it is embedded in to map it, which is how
	// XEmbed works. Plugin hosts are not XEmbed embedders -- they hand over a
	// window and expect it filled -- so the plug maps itself.
	if window := api.gtk_widget_get_window(plug); window != nil {
		api.gdk_window_show(window)
	}

	api.webkit_web_view_load_uri(webview, uri)
	// Ready from here rather than from the page having loaded, as on Windows:
	// the panel asks for its state once it has loaded, and whatever is sent
	// before then is sent to a page that does not exist yet.
	v.ready = true

	if !v.loop.register_timer(v.loop.user, TIMER_PERIOD_MS) {
		destroy(v)
		return false
	}
	v.timer = true
	// One pass now, which also hands the host GLib's descriptors.
	pump(v)
	return true
}

destroy :: proc(v: ^View) {
	v.closing = true
	v.ready = false

	// The host first: nothing may call back into a view that is going away.
	for w in v.watched {
		if w.registered {
			v.loop.unregister_fd(v.loop.user, w.fd)
		}
	}
	clear(&v.watched)
	if v.timer {
		v.loop.unregister_timer(v.loop.user)
		v.timer = false
	}

	if v.content != nil && v.message_signal != 0 {
		api.g_signal_handler_disconnect(v.content, v.message_signal)
		v.message_signal = 0
	}
	if v.content != nil {
		api.webkit_user_content_manager_unregister_script_message_handler(v.content, MESSAGE_HANDLER)
	}

	if v.plug != nil {
		// Destroyed and flushed now, while the host's window still exists. The
		// host destroys that window as soon as this returns, and a request
		// about a child of it still sitting in the X output buffer would then
		// fail -- and an X error GDK has not been told to expect ends the
		// process. The trap covers a host that got there first.
		api.gdk_error_trap_push()
		api.gtk_widget_destroy(v.plug)
		api.gdk_flush()
		api.gdk_error_trap_pop_ignored()
		v.plug = nil
		v.webview = nil
	}
	if v.content != nil {
		api.g_object_unref(v.content)
		v.content = nil
	}

	delete(v.polled)
	v.polled = nil
	delete(v.watched)
	v.watched = nil
}

// Make the view fill the host's window at its new size.
set_bounds :: proc(v: ^View, width, height: i32) {
	v.width = width
	v.height = height
	if v.plug != nil {
		api.gtk_window_resize(v.plug, max(width, 1), max(height, 1))
	}
}

// Sends one JSON string to the panel, by calling window.synthReceive with it.
// JSON is a JavaScript expression, and bridge.js takes an object as readily as
// a string. Does nothing before the view is ready, as on Windows.
post :: proc(v: ^View, text: string) -> bool {
	if v.webview == nil || !v.ready {
		return false
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "window.synthReceive && window.synthReceive(")
	strings.write_string(&builder, text)
	strings.write_string(&builder, ");")
	script := strings.to_cstring(&builder)
	if api.webkit_web_view_evaluate_javascript != nil {
		api.webkit_web_view_evaluate_javascript(v.webview, script, -1, nil, nil, nil, nil, nil)
	} else {
		api.webkit_web_view_run_javascript(v.webview, script, nil, nil, nil)
	}
	return true
}

// One pass of GLib's main context, driven by the host: a descriptor it watches
// became ready, or the timer fired.
//
// The steps are the ones g_main_context_iteration takes, spelled out so that
// the poll set is visible: prepare, query, poll without waiting -- the host
// already waited -- check, dispatch. The poll set is then handed to the host,
// so the next time GLib has something to do the host is the one that notices.
pump :: proc(v: ^View) {
	if v.plug == nil || v.closing {
		return
	}
	ctx := api.g_main_context_default()
	// Owned by another thread means somebody else is running this context and
	// will get to it; there is nothing to do here that would not be a race.
	if !api.g_main_context_acquire(ctx) {
		return
	}

	priority: c.int
	something_ready := api.g_main_context_prepare(ctx, &priority)

	if len(v.polled) == 0 {
		resize(&v.polled, 16)
	}
	timeout: c.int
	count: c.int
	for {
		count = api.g_main_context_query(ctx, priority, &timeout, raw_data(v.polled), c.int(len(v.polled)))
		if int(count) <= len(v.polled) {
			break
		}
		resize(&v.polled, int(count))
	}
	api.g_poll(raw_data(v.polled), c.uint(count), 0)
	api.g_main_context_check(ctx, priority, raw_data(v.polled), count)

	// With a source already ready, query only reports the descriptors that
	// outrank it, which is not the set GLib is waiting on. The host is told
	// only about a full set; the timer carries anything in between.
	if !something_ready {
		watch(v, v.polled[:count])
	}

	api.g_main_context_dispatch(ctx)
	api.g_main_context_release(ctx)
}

// Bring the host's watched descriptors into line with GLib's poll set.
@(private)
watch :: proc(v: ^View, polled: []Poll_Fd) {
	for &w in v.watched {
		w.seen = false
		w.wanted = {}
	}

	// What GLib wants. A descriptor can appear more than once, for two
	// sources; the host is asked about it once, for everything either wants.
	// Errors are always asked for, so a hang-up wakes the view too.
	for p in polled {
		wanted := Fd_Flags{.Error}
		if p.events & (IO_IN | IO_PRI) != 0 {
			wanted += {.Read}
		}
		if p.events & IO_OUT != 0 {
			wanted += {.Write}
		}

		found := false
		for &w in v.watched {
			if w.fd == p.fd {
				w.wanted += wanted
				w.seen = true
				found = true
				break
			}
		}
		if !found {
			append(&v.watched, Watch{fd = p.fd, wanted = wanted, seen = true})
		}
	}

	// Then the host is told the difference: new ones registered, changed ones
	// modified, and ones GLib has let go of unregistered.
	for i := len(v.watched) - 1; i >= 0; i -= 1 {
		w := &v.watched[i]
		switch {
		case !w.seen:
			if w.registered {
				v.loop.unregister_fd(v.loop.user, w.fd)
			}
			unordered_remove(&v.watched, i)
		case !w.offered:
			w.offered = true
			w.registered = v.loop.register_fd(v.loop.user, w.fd, w.wanted)
			w.flags = w.wanted
		case w.registered && w.flags != w.wanted:
			v.loop.modify_fd(v.loop.user, w.fd, w.wanted)
			w.flags = w.wanted
		}
	}
}

// A message from the panel. The string belongs to GLib, so it is handed over
// for the length of the call and freed here.
@(private)
on_script_message :: proc "c" (manager: rawptr, result: rawptr, user: rawptr) {
	v := (^View)(user)
	if v == nil || result == nil {
		return
	}
	context = v.ctx

	if v.closing || v.on_message == nil {
		return
	}
	value := api.webkit_javascript_result_get_js_value(result)
	if value == nil {
		return
	}
	text := api.jsc_value_to_string(value)
	if text == nil {
		return
	}
	defer api.g_free(rawptr(text))
	v.on_message(v.user, string(text))
}

// Returning true is how a handler says it has dealt with the menu, which here
// means there is none.
@(private)
on_context_menu :: proc "c" (view: rawptr, menu: rawptr, event: rawptr, hit: rawptr, user: rawptr) -> gboolean {
	return true
}
