#+build darwin
package webkit

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// The slice of WebKit and AppKit the editor needs, bound by hand from the
// documented selectors; neither framework ships with Odin.
//
// Both frameworks are linked, not merely referenced. The class names below are
// resolved once at image startup (see objc.odin), and a framework that is not
// loaded by then leaves them nil for good. A framework named by @(require)
// stays a load command of the binary even though no symbol of it is used.
//
// No selector here returns a struct, so nothing needs objc_msgSend_stret on
// x86_64. Keep it that way: bind no `frame` or `bounds` getter.

@(require) foreign import webkit_framework "system:WebKit.framework"
@(require) foreign import appkit_framework "system:AppKit.framework"

@(objc_class = "WKWebView")
WK_Web_View :: struct { using _: NS.View }
@(objc_class = "WKWebViewConfiguration")
WK_Web_View_Configuration :: struct { using _: NS.Object }
@(objc_class = "WKUserContentController")
WK_User_Content_Controller :: struct { using _: NS.Object }
@(objc_class = "WKUserScript")
WK_User_Script :: struct { using _: NS.Object }
@(objc_class = "WKScriptMessage")
WK_Script_Message :: struct { using _: NS.Object }

WK_User_Script_Injection_Time :: enum NS.Integer {
	At_Document_Start = 0,
	At_Document_End   = 1,
}

// NSAutoresizingMaskOptions
VIEW_WIDTH_SIZABLE :: NS.UInteger(2)
VIEW_HEIGHT_SIZABLE :: NS.UInteger(16)

// False when WebKit did not load, which means no editor rather than a crash.
available :: proc "contextless" () -> bool {
	return intrinsics.objc_find_class("WKWebView") != nil
}

is_string :: proc "c" (obj: ^NS.Object) -> bool {
	return intrinsics.objc_send(NS.BOOL, obj, "isKindOfClass:", intrinsics.objc_find_class("NSString"))
}

view_set_frame :: proc "c" (v: ^NS.View, frame: NS.Rect) {
	intrinsics.objc_send(nil, v, "setFrame:", frame)
}

view_set_autoresizing_mask :: proc "c" (v: ^NS.View, mask: NS.UInteger) {
	intrinsics.objc_send(nil, v, "setAutoresizingMask:", mask)
}

view_remove_from_superview :: proc "c" (v: ^NS.View) {
	intrinsics.objc_send(nil, v, "removeFromSuperview")
}

@(objc_type = WK_Web_View, objc_name = "alloc", objc_is_class_method = true)
WK_Web_View_alloc :: proc "c" () -> ^WK_Web_View {
	return intrinsics.objc_send(^WK_Web_View, WK_Web_View, "alloc")
}

@(objc_type = WK_Web_View, objc_name = "initWithFrame")
WK_Web_View_initWithFrame :: proc "c" (self: ^WK_Web_View, frame: NS.Rect, configuration: ^WK_Web_View_Configuration) -> ^WK_Web_View {
	return intrinsics.objc_send(^WK_Web_View, self, "initWithFrame:configuration:", frame, configuration)
}

// Returns the WKNavigation, +0.
@(objc_type = WK_Web_View, objc_name = "loadFileURL")
WK_Web_View_loadFileURL :: proc "c" (self: ^WK_Web_View, url: ^NS.URL, read_access: ^NS.URL) -> ^NS.Object {
	return intrinsics.objc_send(^NS.Object, self, "loadFileURL:allowingReadAccessToURL:", url, read_access)
}

// `completion` is a block pointer; nil asks for no result.
@(objc_type = WK_Web_View, objc_name = "evaluateJavaScript")
WK_Web_View_evaluateJavaScript :: proc "c" (self: ^WK_Web_View, script: ^NS.String, completion: rawptr) {
	intrinsics.objc_send(nil, self, "evaluateJavaScript:completionHandler:", script, completion)
}

// +0. A web view copies its configuration, and the copy shares this controller.
@(objc_type = WK_Web_View_Configuration, objc_name = "userContentController")
WK_Web_View_Configuration_userContentController :: proc "c" (self: ^WK_Web_View_Configuration) -> ^WK_User_Content_Controller {
	return intrinsics.objc_send(^WK_User_Content_Controller, self, "userContentController")
}

// The controller retains the handler until it is removed by name.
@(objc_type = WK_User_Content_Controller, objc_name = "addScriptMessageHandler")
WK_User_Content_Controller_addScriptMessageHandler :: proc "c" (self: ^WK_User_Content_Controller, handler: ^NS.Object, name: ^NS.String) {
	intrinsics.objc_send(nil, self, "addScriptMessageHandler:name:", handler, name)
}

@(objc_type = WK_User_Content_Controller, objc_name = "removeScriptMessageHandlerForName")
WK_User_Content_Controller_removeScriptMessageHandlerForName :: proc "c" (self: ^WK_User_Content_Controller, name: ^NS.String) {
	intrinsics.objc_send(nil, self, "removeScriptMessageHandlerForName:", name)
}

@(objc_type = WK_User_Content_Controller, objc_name = "addUserScript")
WK_User_Content_Controller_addUserScript :: proc "c" (self: ^WK_User_Content_Controller, script: ^WK_User_Script) {
	intrinsics.objc_send(nil, self, "addUserScript:", script)
}

@(objc_type = WK_User_Script, objc_name = "alloc", objc_is_class_method = true)
WK_User_Script_alloc :: proc "c" () -> ^WK_User_Script {
	return intrinsics.objc_send(^WK_User_Script, WK_User_Script, "alloc")
}

@(objc_type = WK_User_Script, objc_name = "initWithSource")
WK_User_Script_initWithSource :: proc "c" (self: ^WK_User_Script, source: ^NS.String, injection_time: WK_User_Script_Injection_Time, main_frame_only: NS.BOOL) -> ^WK_User_Script {
	return intrinsics.objc_send(^WK_User_Script, self, "initWithSource:injectionTime:forMainFrameOnly:", source, injection_time, main_frame_only)
}

@(objc_type = WK_Script_Message, objc_name = "body")
WK_Script_Message_body :: proc "c" (self: ^WK_Script_Message) -> ^NS.Object {
	return intrinsics.objc_send(^NS.Object, self, "body")
}
