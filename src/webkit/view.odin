#+build darwin
package webkit

import "base:intrinsics"
import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import NS "core:sys/darwin/Foundation"

// The web view inside a host's NSView.
//
// The same shape as src/webview2's and src/webkitgtk's View -- create, destroy,
// post, set_bounds and an on_message callback -- so hosts/panel drives all
// three the same way. Unlike GTK there is no loop to pump: AppKit's main run
// loop is the host's own, and WebKit runs on it.
//
// Main thread only. create refuses any other thread, and post drops what is
// sent from one rather than marshalling it; a host moves off-thread changes to
// the main thread itself.
//
// The page talks to the plugin through ui/bridge.js's WKWebView transport:
// bridge.js finds window.webkit.messageHandlers.synth and posts JSON strings to
// it, which arrive at a script-message handler registered here. The other way,
// the plugin evaluates window.synthReceive(...) in the page.

MESSAGE_HANDLER :: "synth"
// A right-click menu offering Reload inside a plugin window is a way to lose a
// patch, not a feature -- the WebView2 and WebKitGTK hosts turn it off too.
CONTEXT_MENU_SCRIPT :: `document.addEventListener("contextmenu", function (e) { e.preventDefault(); });`

Message_Proc :: #type proc(user: rawptr, text: string)

View :: struct {
	// The host's NSView.
	parent:      rawptr,
	width:       i32,
	height:      i32,

	// The panel's folder, and the page in it to open.
	content_dir: string,
	start_page:  string,

	on_message:  Message_Proc,
	user:        rawptr,

	// Each +1 and ours. The controller is kept to remove the handler at
	// destroy; the handler's ivar points back at this View.
	webview:     ^WK_Web_View,
	content:     ^WK_User_Content_Controller,
	handler:     ^NS.Object,

	ready:       bool,

	ctx:         runtime.Context,
}

// The WKScriptMessageHandler class, registered once per image on first create.
@(private)
handler_once: sync.Once
@(private)
handler_class: Class
@(private)
handler_ok: bool

@(private)
register_handler_class :: proc() {
	methods := []Method{{"userContentController:didReceiveScriptMessage:", rawptr(on_script_message), "v@:@@"}}
	handler_class, handler_ok = register_class("QuesynthScriptHandler", intrinsics.objc_find_class("NSObject"), methods, "WKScriptMessageHandler")
}

// Build the view inside the host's NSView and start loading the panel.
//
// Returns false, having left nothing behind, off the main thread, without
// WebKit, without a parent, or when any object fails to come up: the host
// keeps its view and it stays empty.
create :: proc(v: ^View) -> bool {
	if !on_main_thread() || !available() || v.parent == nil {
		return false
	}
	sync.once_do(&handler_once, register_handler_class)
	if !handler_ok {
		return false
	}
	v.ctx = context
	v.ready = false

	page, join_err := filepath.join({v.content_dir, v.start_page}, context.temp_allocator)
	if join_err != nil {
		return false
	}
	pool := pool_push()
	defer pool_pop(pool)

	config := NS.alloc(WK_Web_View_Configuration)->init()
	if config == nil {
		return false
	}
	defer config->release()

	content := config->userContentController()
	if content == nil {
		return false
	}
	content->retain()
	v.content = content

	// Registered before the page loads, so bridge.js finds it when it looks.
	handler := alloc_instance(handler_class)->init()
	if handler == nil {
		destroy(v)
		return false
	}
	slot(handler_class, handler)^ = v
	v.handler = handler
	content->addScriptMessageHandler(handler, NS.AT(MESSAGE_HANDLER))

	script := WK_User_Script.alloc()->initWithSource(NS.AT(CONTEXT_MENU_SCRIPT), .At_Document_Start, true)
	if script == nil {
		destroy(v)
		return false
	}
	content->addUserScript(script)
	script->release()

	frame := NS.Rect{size = {NS.Float(max(v.width, 1)), NS.Float(max(v.height, 1))}}
	webview := WK_Web_View.alloc()->initWithFrame(frame, config)
	if webview == nil {
		destroy(v)
		return false
	}
	v.webview = webview
	view_set_autoresizing_mask(webview, VIEW_WIDTH_SIZABLE | VIEW_HEIGHT_SIZABLE)
	(^NS.View)(v.parent)->addSubview(webview)

	page_path := ns_string(page)
	defer page_path->release()
	dir_path := ns_string(v.content_dir)
	defer dir_path->release()
	if page_path == nil || dir_path == nil {
		destroy(v)
		return false
	}
	page_url := NS.URL_alloc()->initFileURLWithPath(page_path)
	defer page_url->release()
	dir_url := NS.URL_alloc()->initFileURLWithPath(dir_path)
	defer dir_url->release()
	if page_url == nil || dir_url == nil {
		destroy(v)
		return false
	}
	// The read-access URL is what lets WebKit's sandboxed content process
	// open the rest of the panel's folder, not just the page.
	webview->loadFileURL(page_url, dir_url)

	// Ready from here rather than from the page having loaded, as on Windows
	// and Linux: the panel asks for its state once it has loaded, and whatever
	// is sent before then is sent to a page that does not exist yet.
	v.ready = true
	return true
}

destroy :: proc(v: ^View) {
	v.ready = false
	// Teardown autoreleases, and not every caller has a pool in place.
	pool := pool_push()
	defer pool_pop(pool)

	// Cleared first: a message already queued for the handler then finds no
	// View rather than one that is going away.
	if v.handler != nil {
		slot(handler_class, v.handler)^ = nil
	}
	if v.content != nil {
		if v.handler != nil {
			v.content->removeScriptMessageHandlerForName(NS.AT(MESSAGE_HANDLER))
		}
		v.content->release()
		v.content = nil
	}
	if v.handler != nil {
		v.handler->release()
		v.handler = nil
	}
	if v.webview != nil {
		view_remove_from_superview(v.webview)
		v.webview->release()
		v.webview = nil
	}
}

// Make the view fill the host's view at its new size.
set_bounds :: proc(v: ^View, width, height: i32) {
	v.width = width
	v.height = height
	if v.webview != nil {
		view_set_frame(v.webview, NS.Rect{size = {NS.Float(max(width, 1)), NS.Float(max(height, 1))}})
	}
}

// Sends one JSON string to the panel, by calling window.synthReceive with it.
// JSON is a JavaScript expression, and bridge.js takes an object as readily as
// a string. Does nothing before the view is ready or off the main thread.
post :: proc(v: ^View, text: string) -> bool {
	if v.webview == nil || !v.ready || !on_main_thread() {
		return false
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "window.synthReceive && window.synthReceive(")
	strings.write_string(&builder, text)
	strings.write_string(&builder, ");")
	source := strings.to_cstring(&builder)
	script := NS.String_alloc()->initWithCString(source, .UTF8)
	if script == nil {
		return false
	}
	v.webview->evaluateJavaScript(script, nil)
	script->release()
	return true
}

// +1, copied: NSString's no-copy initialisers would outlive the temp buffer.
@(private)
ns_string :: proc(text: string) -> ^NS.String {
	return NS.String_alloc()->initWithCString(strings.clone_to_cstring(text, context.temp_allocator), .UTF8)
}

// userContentController:didReceiveScriptMessage: -- WebKit calls it on the main
// thread. The text is the page's JSON.stringify output, borrowed for the length
// of the call from a buffer the pool below frees.
@(private)
on_script_message :: proc "c" (self: ^NS.Object, cmd: NS.SEL, controller: ^NS.Object, message: ^WK_Script_Message) {
	v := (^View)(slot(handler_class, self)^)
	if v == nil || v.on_message == nil || message == nil {
		return
	}
	context = v.ctx
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pool := pool_push()
	defer pool_pop(pool)

	body := message->body()
	// UTF8String sent to anything but a string would raise.
	if body == nil || !is_string(body) {
		return
	}
	text := NS.String_UTF8String((^NS.String)(body))
	if text == nil {
		return
	}
	v.on_message(v.user, string(text))
}
