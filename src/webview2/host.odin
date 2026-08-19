#+build windows
package webview2

import "base:runtime"
import win "core:sys/windows"

// The three callback objects WebView2 requires, and the lifecycle around them.
//
// Everything here is COM seen from the other side: instead of calling an
// interface the runtime implements, these are interfaces *this* code
// implements and the runtime calls. A callback object is a pointer to a vtable
// pointer, which is why each one begins with `vtbl` and why the runtime can be
// handed its address directly.
//
// The three are embedded in `View` rather than allocated, so their addresses
// are stable for as long as the view is and their reference counts can be
// honest no-ops: nothing the runtime does to the count can free memory the
// view still owns. The subscription is removed before the view goes away,
// which is the part that actually matters.

// -- the loader --------------------------------------------------------------

Create_Environment_Proc :: #type proc "c" (
	browser_executable_folder: win.wstring,
	user_data_folder: win.wstring,
	environment_options: rawptr,
	handler: rawptr,
) -> HRESULT

@(private)
loader_module: win.HMODULE
@(private)
create_environment: Create_Environment_Proc

// Loads WebView2Loader.dll from an explicit path.
//
// By full path deliberately. A bare LoadLibrary would search the host's
// directory first, and a DAW that ships its own copy of a different vintage is
// not a theoretical concern -- the plugin must get the one it was built
// against, sitting beside it in the bundle.
load :: proc(dll_path: string) -> bool {
	if create_environment != nil {
		return true
	}
	wide := win.utf8_to_wstring(dll_path)
	loader_module = win.LoadLibraryW(wide)
	if loader_module == nil {
		return false
	}
	proc_address := win.GetProcAddress(loader_module, "CreateCoreWebView2EnvironmentWithOptions")
	if proc_address == nil {
		return false
	}
	create_environment = Create_Environment_Proc(proc_address)
	return true
}

available :: proc() -> bool {
	return create_environment != nil
}

// -- callback vtables --------------------------------------------------------

Env_Completed_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	invoke:          proc "c" (this: rawptr, code: HRESULT, env: ^ICoreWebView2Environment) -> HRESULT,
}

Ctrl_Completed_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	invoke:          proc "c" (this: rawptr, code: HRESULT, controller: ^ICoreWebView2Controller) -> HRESULT,
}

Msg_Received_Vtbl :: struct {
	query_interface: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:         proc "c" (this: rawptr) -> u32,
	release:         proc "c" (this: rawptr) -> u32,
	invoke:          proc "c" (this: rawptr, sender: ^ICoreWebView2, args: ^ICoreWebView2WebMessageReceivedEventArgs) -> HRESULT,
}

Env_Completed :: struct {
	vtbl: ^Env_Completed_Vtbl,
	view: ^View,
}

Ctrl_Completed :: struct {
	vtbl: ^Ctrl_Completed_Vtbl,
	view: ^View,
}

Msg_Received :: struct {
	vtbl: ^Msg_Received_Vtbl,
	view: ^View,
}

// -- the view ----------------------------------------------------------------

Message_Proc :: #type proc(user: rawptr, text: string)

View :: struct {
	parent:      win.HWND,
	bounds:      win.RECT,

	// Where the panel is served from, and what it is served as. The folder is
	// mapped to a host name so the page has a real https origin.
	content_dir: string,
	host_name:   string,
	start_url:   string,

	on_message:  Message_Proc,
	user:        rawptr,

	env_handler:  Env_Completed,
	ctrl_handler: Ctrl_Completed,
	msg_handler:  Msg_Received,

	env:         ^ICoreWebView2Environment,
	controller:  ^ICoreWebView2Controller,
	webview:     ^ICoreWebView2,
	msg_token:   i64,

	ready:       bool,
	// Set the moment teardown begins. The two creation callbacks are delivered
	// later on the host message loop and must find out that the window they
	// were being built for has gone, rather than attaching to it.
	closing:     bool,

	ctx:         runtime.Context,
}

// Handlers live inside the view, so the count is a fiction the runtime is
// welcome to keep. See the note at the top of this file.
handler_add_ref :: proc "c" (this: rawptr) -> u32 {return 1}
handler_release :: proc "c" (this: rawptr) -> u32 {return 1}

env_query_interface :: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT {
	if obj == nil {
		return E_POINTER
	}
	if guid_equal(iid, &IID_IUNKNOWN) || guid_equal(iid, &IID_ENVIRONMENT_COMPLETED) {
		obj^ = this
		return S_OK
	}
	obj^ = nil
	return E_NOINTERFACE
}

ctrl_query_interface :: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT {
	if obj == nil {
		return E_POINTER
	}
	if guid_equal(iid, &IID_IUNKNOWN) || guid_equal(iid, &IID_CONTROLLER_COMPLETED) {
		obj^ = this
		return S_OK
	}
	obj^ = nil
	return E_NOINTERFACE
}

msg_query_interface :: proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT {
	if obj == nil {
		return E_POINTER
	}
	if guid_equal(iid, &IID_IUNKNOWN) || guid_equal(iid, &IID_WEB_MESSAGE_RECEIVED) {
		obj^ = this
		return S_OK
	}
	obj^ = nil
	return E_NOINTERFACE
}

// Step two of three: the environment exists, so ask it for a controller bound
// to the window the host gave us.
env_invoke :: proc "c" (this: rawptr, code: HRESULT, env: ^ICoreWebView2Environment) -> HRESULT {
	handler := (^Env_Completed)(this)
	v := handler.view
	if v == nil {
		return S_OK
	}
	context = v.ctx

	if v.closing || code != S_OK || env == nil {
		return S_OK
	}

	v.env = env
	env.vtbl.add_ref(env)
	env.vtbl.create_core_webview2_controller(env, v.parent, &v.ctrl_handler)
	return S_OK
}

// Step three: the controller exists. Everything that configures the view
// happens here, because this is the first moment there is a view to configure.
ctrl_invoke :: proc "c" (this: rawptr, code: HRESULT, controller: ^ICoreWebView2Controller) -> HRESULT {
	handler := (^Ctrl_Completed)(this)
	v := handler.view
	if v == nil {
		return S_OK
	}
	context = v.ctx

	if v.closing || code != S_OK || controller == nil {
		return S_OK
	}

	v.controller = controller
	controller.vtbl.add_ref(controller)

	webview: ^ICoreWebView2
	if controller.vtbl.get_core_webview2(controller, &webview) != S_OK || webview == nil {
		return S_OK
	}
	v.webview = webview

	settings: ^ICoreWebView2Settings
	if webview.vtbl.get_settings(webview, &settings) == S_OK && settings != nil {
		settings.vtbl.put_is_web_message_enabled(settings, win.TRUE)
		// A right-click menu offering Reload and Save As inside a plugin window
		// is a way to lose a patch, not a feature.
		settings.vtbl.put_are_default_context_menus_enabled(settings, win.FALSE)
		settings.vtbl.put_is_zoom_control_enabled(settings, win.FALSE)
		settings.vtbl.put_is_status_bar_enabled(settings, win.FALSE)
		settings.vtbl.release(settings)
	}

	webview.vtbl.add_web_message_received(webview, &v.msg_handler, &v.msg_token)

	// The folder mapping needs ICoreWebView2_3. Asking for it by interface
	// rather than assuming the runtime is new enough is the difference between
	// a blank panel and a clear failure on an old machine.
	webview3: ^ICoreWebView2
	if webview.vtbl.query_interface(webview, &IID_WEBVIEW2_3, (^rawptr)(&webview3)) == S_OK && webview3 != nil {
		host_wide := win.utf8_to_wstring(v.host_name)
		dir_wide := win.utf8_to_wstring(v.content_dir)
		webview3.vtbl.set_virtual_host_name_to_folder_mapping(
			webview3,
			host_wide,
			dir_wide,
			HOST_RESOURCE_ACCESS_ALLOW,
		)
		webview3.vtbl.release(webview3)
	}

	controller.vtbl.put_bounds(controller, client_bounds(v))
	controller.vtbl.put_is_visible(controller, win.TRUE)

	url_wide := win.utf8_to_wstring(v.start_url)
	webview.vtbl.navigate(webview, url_wide)

	v.ready = true
	return S_OK
}

// A message from the panel. The string is only valid for the length of this
// call and the buffer belongs to COM, so it is copied into Odin memory, handed
// over, and freed here.
msg_invoke :: proc "c" (this: rawptr, sender: ^ICoreWebView2, args: ^ICoreWebView2WebMessageReceivedEventArgs) -> HRESULT {
	handler := (^Msg_Received)(this)
	v := handler.view
	if v == nil || args == nil {
		return S_OK
	}
	context = v.ctx

	if v.closing || v.on_message == nil {
		return S_OK
	}

	raw: win.wstring
	if args.vtbl.try_get_web_message_as_string(args, &raw) != S_OK || raw == nil {
		return S_OK
	}
	defer win.CoTaskMemFree(rawptr(raw))

	text, err := win.wstring_to_utf8(raw, -1, context.temp_allocator)
	if err != nil {
		return S_OK
	}
	v.on_message(v.user, text)
	return S_OK
}

ENV_COMPLETED_VTBL := Env_Completed_Vtbl {
	query_interface = env_query_interface,
	add_ref         = handler_add_ref,
	release         = handler_release,
	invoke          = env_invoke,
}

CTRL_COMPLETED_VTBL := Ctrl_Completed_Vtbl {
	query_interface = ctrl_query_interface,
	add_ref         = handler_add_ref,
	release         = handler_release,
	invoke          = ctrl_invoke,
}

MSG_RECEIVED_VTBL := Msg_Received_Vtbl {
	query_interface = msg_query_interface,
	add_ref         = handler_add_ref,
	release         = handler_release,
	invoke          = msg_invoke,
}

// Starts building the view. Returns whether the *request* was accepted, which
// is not the same as the view existing: see the note about asynchrony at the
// top of webview2.odin. Nothing may touch `webview` until `ready`.
create :: proc(v: ^View, user_data_dir: string) -> bool {
	if create_environment == nil {
		return false
	}

	v.ctx = context
	v.closing = false
	v.ready = false

	v.env_handler = Env_Completed {
		vtbl = &ENV_COMPLETED_VTBL,
		view = v,
	}
	v.ctrl_handler = Ctrl_Completed {
		vtbl = &CTRL_COMPLETED_VTBL,
		view = v,
	}
	v.msg_handler = Msg_Received {
		vtbl = &MSG_RECEIVED_VTBL,
		view = v,
	}

	user_wide := win.utf8_to_wstring(user_data_dir)
	// A nil browser folder means "find the installed runtime", which is what a
	// plugin wants: the user's Edge WebView2 runtime, not one shipped here.
	result := create_environment(nil, user_wide, nil, &v.env_handler)
	return result == S_OK
}

destroy :: proc(v: ^View) {
	v.closing = true
	v.ready = false

	if v.webview != nil {
		if v.msg_token != 0 {
			v.webview.vtbl.remove_web_message_received(v.webview, v.msg_token)
			v.msg_token = 0
		}
		v.webview.vtbl.release(v.webview)
		v.webview = nil
	}
	if v.controller != nil {
		// Close tears down the browser process side. Without it the window is
		// destroyed under a live control and the runtime is left holding a
		// handle to nothing.
		v.controller.vtbl.close(v.controller)
		v.controller.vtbl.release(v.controller)
		v.controller = nil
	}
	if v.env != nil {
		v.env.vtbl.release(v.env)
		v.env = nil
	}
}

// The rectangle the control should occupy: the whole of the parent's client
// area.
//
// Measured from the window rather than taken from the size the host asked for,
// because those two are not always the same number. A host may round the size,
// reserve a strip for its own chrome, or hand back a client area that differs
// from the rectangle it named. Every pixel of difference is a pixel of the
// host's own window left showing around the edge of the panel -- which is what
// a mysterious border around a plugin editor usually is.
//
// The requested size is kept as a fallback for the moment before there is a
// parent to measure.
client_bounds :: proc(v: ^View) -> win.RECT {
	rect: win.RECT
	if v.parent != nil && win.GetClientRect(v.parent, &rect) {
		return rect
	}
	return v.bounds
}

set_bounds :: proc(v: ^View, bounds: win.RECT) {
	v.bounds = bounds
	if v.controller != nil {
		v.controller.vtbl.put_bounds(v.controller, client_bounds(v))
	}
}

// Sends one JSON string to the panel, where it arrives as a `message` event on
// `window.chrome.webview`. Silently does nothing before the view is ready,
// which is correct: the panel asks for its state on load, so anything sent
// earlier would have been sent to a page that does not exist yet.
post :: proc(v: ^View, text: string) -> bool {
	if v.webview == nil || !v.ready {
		return false
	}
	wide := win.utf8_to_wstring(text)
	return v.webview.vtbl.post_web_message_as_string(v.webview, wide) == S_OK
}
