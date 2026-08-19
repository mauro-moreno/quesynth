#+build windows
package webview2

import win "core:sys/windows"

// Hosting an Edge WebView2 control, which is how the interface in ui/ becomes
// the plugin's editor.
//
// This is a transcription of the parts of ext/webview2/include/WebView2.h that
// this project calls, in the same spirit as src/vst3: the vtable order *is* the
// ABI, so the order below was read out of the header rather than remembered.
// A method inserted in the wrong place does not fail to compile -- it calls a
// different function with the wrong arguments.
//
// Two things make this different from the VST3 binding:
//
//   The loader is optional. WebView2Loader.dll is loaded by name at run time
//   rather than imported, so a machine without the WebView2 runtime gets a
//   plugin that makes sound and shows the host generic parameter panel,
//   instead of a plugin the host refuses to load at all. An editor is worth
//   having; it is not worth trading the instrument for.
//
//   Creation is asynchronous. Starting it returns before there is anything to
//   show: the environment arrives on one callback and the controller on a
//   second, both delivered on the thread message loop, which in a plugin
//   belongs to the host. Nothing may assume the view exists until it is ready.

// -- COM ---------------------------------------------------------------------
//
// WebView2 is ordinary COM and uses ordinary GUIDs, laid out in memory the way
// Microsoft writes them. This is *not* the VST3 TUID convention, where
// SMTG_COM_COMPATIBLE reorders the bytes. Do not reuse the vst3 uid helper.

GUID :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

HRESULT :: i32
S_OK :: HRESULT(0)
E_NOINTERFACE :: HRESULT(transmute(i32)u32(0x80004002))
E_POINTER :: HRESULT(transmute(i32)u32(0x80004003))

IID_IUNKNOWN := GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

IID_ENVIRONMENT_COMPLETED := GUID {
	0x4e8a3389,
	0xc9d8,
	0x4bd2,
	{0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d},
}
IID_CONTROLLER_COMPLETED := GUID {
	0x6c4819f3,
	0xc9b7,
	0x4260,
	{0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c},
}
IID_WEB_MESSAGE_RECEIVED := GUID {
	0x57213f19,
	0x00e6,
	0x49fa,
	{0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2},
}

// ICoreWebView2_3 is the first revision with SetVirtualHostNameToFolderMapping,
// which is what lets the panel load from a folder over https rather than
// file://, where a fetch or a WebAssembly instantiation would be blocked as
// cross-origin.
IID_WEBVIEW2_3 := GUID {
	0xA0D6DF20,
	0x3B92,
	0x416D,
	{0xAA, 0x0C, 0x43, 0x7A, 0x9C, 0x72, 0x78, 0x57},
}

guid_equal :: proc "contextless" (a: ^GUID, b: ^GUID) -> bool {
	if a == nil || b == nil {
		return false
	}
	if a.data1 != b.data1 || a.data2 != b.data2 || a.data3 != b.data3 {
		return false
	}
	for i in 0 ..< 8 {
		if a.data4[i] != b.data4[i] {
			return false
		}
	}
	return true
}

HOST_RESOURCE_ACCESS_ALLOW :: i32(1)

// -- interfaces the runtime provides -----------------------------------------

ICoreWebView2Environment :: struct {
	vtbl: ^ICoreWebView2Environment_Vtbl,
}

ICoreWebView2Environment_Vtbl :: struct {
	query_interface:                     proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:                             proc "c" (this: rawptr) -> u32,
	release:                             proc "c" (this: rawptr) -> u32,
	create_core_webview2_controller:     proc "c" (this: rawptr, parent: win.HWND, handler: rawptr) -> HRESULT,
	create_web_resource_response:        proc "c" (this: rawptr, a, b, c, d: rawptr) -> HRESULT,
	get_browser_version_string:          proc "c" (this: rawptr, version: ^win.wstring) -> HRESULT,
	add_new_browser_version_available:   proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_new_browser_version_available: proc "c" (this: rawptr, token: i64) -> HRESULT,
}

ICoreWebView2Controller :: struct {
	vtbl: ^ICoreWebView2Controller_Vtbl,
}

ICoreWebView2Controller_Vtbl :: struct {
	query_interface:                proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:                        proc "c" (this: rawptr) -> u32,
	release:                        proc "c" (this: rawptr) -> u32,
	get_is_visible:                 proc "c" (this: rawptr, value: ^win.BOOL) -> HRESULT,
	put_is_visible:                 proc "c" (this: rawptr, value: win.BOOL) -> HRESULT,
	get_bounds:                     proc "c" (this: rawptr, value: ^win.RECT) -> HRESULT,
	put_bounds:                     proc "c" (this: rawptr, value: win.RECT) -> HRESULT,
	get_zoom_factor:                proc "c" (this: rawptr, value: ^f64) -> HRESULT,
	put_zoom_factor:                proc "c" (this: rawptr, value: f64) -> HRESULT,
	add_zoom_factor_changed:        proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_zoom_factor_changed:     proc "c" (this: rawptr, token: i64) -> HRESULT,
	set_bounds_and_zoom_factor:     proc "c" (this: rawptr, bounds: win.RECT, zoom: f64) -> HRESULT,
	move_focus:                     proc "c" (this: rawptr, reason: i32) -> HRESULT,
	add_move_focus_requested:       proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_move_focus_requested:    proc "c" (this: rawptr, token: i64) -> HRESULT,
	add_got_focus:                  proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_got_focus:               proc "c" (this: rawptr, token: i64) -> HRESULT,
	add_lost_focus:                 proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_lost_focus:              proc "c" (this: rawptr, token: i64) -> HRESULT,
	add_accelerator_key_pressed:    proc "c" (this: rawptr, handler: rawptr, token: ^i64) -> HRESULT,
	remove_accelerator_key_pressed: proc "c" (this: rawptr, token: i64) -> HRESULT,
	get_parent_window:              proc "c" (this: rawptr, value: ^win.HWND) -> HRESULT,
	put_parent_window:              proc "c" (this: rawptr, value: win.HWND) -> HRESULT,
	notify_parent_window_position_changed: proc "c" (this: rawptr) -> HRESULT,
	close:                          proc "c" (this: rawptr) -> HRESULT,
	get_core_webview2:              proc "c" (this: rawptr, value: ^^ICoreWebView2) -> HRESULT,
}

ICoreWebView2 :: struct {
	vtbl: ^ICoreWebView2_Vtbl,
}

// Laid out to ICoreWebView2_3, so one pointer serves both: the first 61 entries
// are the ICoreWebView2 ones, in order, and the tail adds what _2 and _3
// introduced. Only a pointer obtained from QueryInterface(IID_WEBVIEW2_3) may
// have the tail entries called on it.
ICoreWebView2_Vtbl :: struct {
	query_interface:                  proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:                          proc "c" (this: rawptr) -> u32,
	release:                          proc "c" (this: rawptr) -> u32,
	get_settings:                     proc "c" (this: rawptr, settings: ^^ICoreWebView2Settings) -> HRESULT,
	get_source:                       proc "c" (this: rawptr, uri: ^win.wstring) -> HRESULT,
	navigate:                         proc "c" (this: rawptr, uri: win.wstring) -> HRESULT,
	navigate_to_string:               proc "c" (this: rawptr, html: win.wstring) -> HRESULT,
	add_navigation_starting:          proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_navigation_starting:       proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_content_loading:              proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_content_loading:           proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_source_changed:               proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_source_changed:            proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_history_changed:              proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_history_changed:           proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_navigation_completed:         proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_navigation_completed:      proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_frame_navigation_starting:    proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_frame_navigation_starting: proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_frame_navigation_completed:   proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_frame_navigation_completed: proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_script_dialog_opening:        proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_script_dialog_opening:     proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_permission_requested:         proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_permission_requested:      proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_process_failed:               proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_process_failed:            proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_script_to_execute_on_document_created: proc "c" (this: rawptr, script: win.wstring, h: rawptr) -> HRESULT,
	remove_script_to_execute_on_document_created: proc "c" (this: rawptr, id: win.wstring) -> HRESULT,
	execute_script:                   proc "c" (this: rawptr, script: win.wstring, h: rawptr) -> HRESULT,
	capture_preview:                  proc "c" (this: rawptr, format: i32, stream: rawptr, h: rawptr) -> HRESULT,
	reload:                           proc "c" (this: rawptr) -> HRESULT,
	post_web_message_as_json:         proc "c" (this: rawptr, json: win.wstring) -> HRESULT,
	post_web_message_as_string:       proc "c" (this: rawptr, text: win.wstring) -> HRESULT,
	add_web_message_received:         proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_web_message_received:      proc "c" (this: rawptr, t: i64) -> HRESULT,
	call_dev_tools_protocol_method:   proc "c" (this: rawptr, name: win.wstring, params: win.wstring, h: rawptr) -> HRESULT,
	get_browser_process_id:           proc "c" (this: rawptr, value: ^u32) -> HRESULT,
	get_can_go_back:                  proc "c" (this: rawptr, value: ^win.BOOL) -> HRESULT,
	get_can_go_forward:               proc "c" (this: rawptr, value: ^win.BOOL) -> HRESULT,
	go_back:                          proc "c" (this: rawptr) -> HRESULT,
	go_forward:                       proc "c" (this: rawptr) -> HRESULT,
	get_dev_tools_protocol_event_receiver: proc "c" (this: rawptr, name: win.wstring, r: rawptr) -> HRESULT,
	stop:                             proc "c" (this: rawptr) -> HRESULT,
	add_new_window_requested:         proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_new_window_requested:      proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_document_title_changed:       proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_document_title_changed:    proc "c" (this: rawptr, t: i64) -> HRESULT,
	get_document_title:               proc "c" (this: rawptr, title: ^win.wstring) -> HRESULT,
	add_host_object_to_script:        proc "c" (this: rawptr, name: win.wstring, object: rawptr) -> HRESULT,
	remove_host_object_from_script:   proc "c" (this: rawptr, name: win.wstring) -> HRESULT,
	open_dev_tools_window:            proc "c" (this: rawptr) -> HRESULT,
	add_contains_full_screen_element_changed: proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_contains_full_screen_element_changed: proc "c" (this: rawptr, t: i64) -> HRESULT,
	get_contains_full_screen_element: proc "c" (this: rawptr, value: ^win.BOOL) -> HRESULT,
	add_web_resource_requested:       proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_web_resource_requested:    proc "c" (this: rawptr, t: i64) -> HRESULT,
	add_web_resource_requested_filter: proc "c" (this: rawptr, uri: win.wstring, ctx: i32) -> HRESULT,
	remove_web_resource_requested_filter: proc "c" (this: rawptr, uri: win.wstring, ctx: i32) -> HRESULT,
	add_window_close_requested:       proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_window_close_requested:    proc "c" (this: rawptr, t: i64) -> HRESULT,

	// ICoreWebView2_2
	add_web_resource_response_received: proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_web_resource_response_received: proc "c" (this: rawptr, t: i64) -> HRESULT,
	navigate_with_web_resource_request: proc "c" (this: rawptr, request: rawptr) -> HRESULT,
	add_dom_content_loaded:           proc "c" (this: rawptr, h: rawptr, t: ^i64) -> HRESULT,
	remove_dom_content_loaded:        proc "c" (this: rawptr, t: i64) -> HRESULT,
	get_cookie_manager:               proc "c" (this: rawptr, value: ^rawptr) -> HRESULT,
	get_environment:                  proc "c" (this: rawptr, value: ^rawptr) -> HRESULT,

	// ICoreWebView2_3
	try_suspend:                      proc "c" (this: rawptr, h: rawptr) -> HRESULT,
	resume:                           proc "c" (this: rawptr) -> HRESULT,
	get_is_suspended:                 proc "c" (this: rawptr, value: ^win.BOOL) -> HRESULT,
	set_virtual_host_name_to_folder_mapping: proc "c" (this: rawptr, host: win.wstring, folder: win.wstring, access: i32) -> HRESULT,
	clear_virtual_host_name_to_folder_mapping: proc "c" (this: rawptr, host: win.wstring) -> HRESULT,
}

ICoreWebView2Settings :: struct {
	vtbl: ^ICoreWebView2Settings_Vtbl,
}

ICoreWebView2Settings_Vtbl :: struct {
	query_interface:                       proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:                               proc "c" (this: rawptr) -> u32,
	release:                               proc "c" (this: rawptr) -> u32,
	get_is_script_enabled:                 proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_is_script_enabled:                 proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_is_web_message_enabled:            proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_is_web_message_enabled:            proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_are_default_script_dialogs_enabled: proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_are_default_script_dialogs_enabled: proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_is_status_bar_enabled:             proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_is_status_bar_enabled:             proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_are_dev_tools_enabled:             proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_are_dev_tools_enabled:             proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_are_default_context_menus_enabled: proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_are_default_context_menus_enabled: proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_are_host_objects_allowed:          proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_are_host_objects_allowed:          proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_is_zoom_control_enabled:           proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_is_zoom_control_enabled:           proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
	get_is_built_in_error_page_enabled:    proc "c" (this: rawptr, v: ^win.BOOL) -> HRESULT,
	put_is_built_in_error_page_enabled:    proc "c" (this: rawptr, v: win.BOOL) -> HRESULT,
}

ICoreWebView2WebMessageReceivedEventArgs :: struct {
	vtbl: ^ICoreWebView2WebMessageReceivedEventArgs_Vtbl,
}

ICoreWebView2WebMessageReceivedEventArgs_Vtbl :: struct {
	query_interface:               proc "c" (this: rawptr, iid: ^GUID, obj: ^rawptr) -> HRESULT,
	add_ref:                       proc "c" (this: rawptr) -> u32,
	release:                       proc "c" (this: rawptr) -> u32,
	get_source:                    proc "c" (this: rawptr, value: ^win.wstring) -> HRESULT,
	get_web_message_as_json:       proc "c" (this: rawptr, value: ^win.wstring) -> HRESULT,
	try_get_web_message_as_string: proc "c" (this: rawptr, value: ^win.wstring) -> HRESULT,
}
