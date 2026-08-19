#+build windows
package vst3host

import "core:fmt"
import "core:time"
import win "core:sys/windows"

import "../../src/vst3"

// Opening the plugin's editor in a real window.
//
// This exists because of a lesson this project has now learned twice: a test
// that builds its input with the same code that reads it cannot fail. The
// silent-plugin bug earlier was an Event struct laid out wrongly, and this host
// missed it precisely because it wrote events through the same wrong struct.
//
// So this does not simulate a window. It registers a class, creates a real
// HWND, hands it to `attached`, and pumps a real message loop -- because
// WebView2 creation is asynchronous and completes *on* that loop, so a test
// that does not pump one would see nothing happen and call it success.
//
// What it proves, in order of how much it is worth:
//
//   createView returns a view at all, and it answers to IPlugView.
//   attached() accepts an HWND, which means WebView2Loader.dll was found beside
//     the plugin and the runtime accepted the request.
//   A child window appears under ours, which only happens once the controller
//     callback has run -- so the environment was created, the folder mapping
//     was applied and the page was told to navigate.
//
// What it does not prove: that the page rendered, or that a message from the
// panel reaches the engine. Those live inside the browser process and this
// host cannot see them. Said plainly rather than implied by an OK.

WINDOW_CLASS :: "SynthVst3HostWindow"

@(private = "file")
child_count: int

// The first child's rectangle, in the parent's client coordinates. Compared
// against the parent's own client rect to answer a question a screenshot
// cannot: whether a border around the editor is the host's window frame or a
// strip of parent window the plugin simply failed to cover.
@(private = "file")
first_child_rect: win.RECT
@(private = "file")
first_child_parent: win.HWND

@(private = "file")
count_child :: proc "system" (hwnd: win.HWND, param: win.LPARAM) -> win.BOOL {
	if child_count == 0 {
		rect: win.RECT
		if win.GetWindowRect(hwnd, &rect) {
			// GetWindowRect is in screen coordinates; the comparison has to be
			// in the parent's, so both corners are mapped back.
			top_left := win.POINT{rect.left, rect.top}
			bottom_right := win.POINT{rect.right, rect.bottom}
			win.ScreenToClient(first_child_parent, &top_left)
			win.ScreenToClient(first_child_parent, &bottom_right)
			first_child_rect = win.RECT{top_left.x, top_left.y, bottom_right.x, bottom_right.y}
		}
	}
	child_count += 1
	return win.TRUE
}

// Runs the message loop for a while, the way a host does between UI events.
// WebView2 needs this: nothing it was asked for arrives until the thread that
// asked returns to its loop.
@(private = "file")
pump :: proc(seconds: f64) {
	deadline := time.time_add(time.now(), time.Duration(seconds * f64(time.Second)))
	message: win.MSG
	for time.diff(time.now(), deadline) > 0 {
		for win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&message)
			win.DispatchMessageW(&message)
		}
		time.sleep(10 * time.Millisecond)
	}
}

check_editor :: proc(controller: ^^vst3.IEditController_Vtbl, cobj: rawptr, seconds: f64) -> bool {
	view_ptr := controller^.create_view(cobj, "editor")
	if view_ptr == nil {
		fmt.println("editor   : createView returned nil -- no editor, host draws the generic panel")
		// Not a failure. It is the documented answer on a machine with no
		// WebView2 runtime, and the instrument still works.
		return true
	}
	view := (^^vst3.IPlugView_Vtbl)(view_ptr)
	fmt.println("editor   : createView returned a view")

	view_iid := vst3.IID_PLUG_VIEW()
	probe: rawptr
	if view^.query_interface(view_ptr, &view_iid, &probe) != vst3.RESULT_OK || probe == nil {
		fmt.eprintln("FAIL: the view does not answer to IPlugView")
		return false
	}
	view^.release(probe)

	if view^.is_platform_type_supported(view_ptr, "HWND") != vst3.RESULT_OK {
		fmt.eprintln("FAIL: the view does not support HWND")
		return false
	}

	size: vst3.View_Rect
	if view^.get_size(view_ptr, &size) != vst3.RESULT_OK {
		fmt.eprintln("FAIL: getSize failed")
		return false
	}
	width := size.right - size.left
	height := size.bottom - size.top
	fmt.printfln("editor   : opens at %vx%v", width, height)

	// WebView2 is COM and wants a single-threaded apartment with a message
	// pump. A real host has done this long before it loads a plugin; this one
	// has to do it itself, or the environment callback is never delivered and
	// the view sits there empty with nothing to say why.
	win.CoInitializeEx(nil, win.COINIT.APARTMENTTHREADED)

	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class_name := win.utf8_to_wstring(WINDOW_CLASS)
	window_class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = win.DefWindowProcW,
		hInstance     = instance,
		lpszClassName = class_name,
	}
	win.RegisterClassExW(&window_class)

	// CreateWindowExW is given the size of the whole window, frame included,
	// while a host hands a plugin the size of the area it may draw in. Asking
	// for the client area and letting AdjustWindowRect add the frame is what
	// makes the coverage check below mean anything: sized the other way, the
	// view would always look oversized by the width of a border.
	frame := win.RECT{0, 0, width, height}
	win.AdjustWindowRect(&frame, win.WS_OVERLAPPEDWINDOW, win.FALSE)

	// Off screen and never shown. This is a check, not a demonstration, and a
	// window appearing over whatever the user is doing would be rude.
	hwnd := win.CreateWindowExW(
		0,
		class_name,
		win.utf8_to_wstring("Quesynth editor check"),
		win.WS_OVERLAPPEDWINDOW,
		-32000,
		-32000,
		frame.right - frame.left,
		frame.bottom - frame.top,
		nil,
		nil,
		instance,
		nil,
	)
	if hwnd == nil {
		fmt.eprintln("FAIL: could not create a window to attach to")
		return false
	}
	defer win.DestroyWindow(hwnd)

	result := view^.attached(view_ptr, rawptr(hwnd), "HWND")
	if result != vst3.RESULT_OK {
		fmt.println("editor   : attached() declined -- WebView2Loader.dll or the runtime is missing")
		view^.release(view_ptr)
		return true
	}
	fmt.println("editor   : attached to a window")

	pump(seconds)

	child_count = 0
	first_child_parent = hwnd
	win.EnumChildWindows(hwnd, count_child, 0)

	// Does the view actually fill the window it was given? A host draws its own
	// frame around a plugin and that is the host's business, but a gap between
	// the web view and the edge of the client area is the plugin's.
	client: win.RECT
	if child_count > 0 && win.GetClientRect(hwnd, &client) {
		fmt.printfln(
			"editor   : client %vx%v, view at (%v,%v) %vx%v",
			client.right - client.left,
			client.bottom - client.top,
			first_child_rect.left,
			first_child_rect.top,
			first_child_rect.right - first_child_rect.left,
			first_child_rect.bottom - first_child_rect.top,
		)
		if first_child_rect.left != client.left ||
		   first_child_rect.top != client.top ||
		   first_child_rect.right != client.right ||
		   first_child_rect.bottom != client.bottom {
			fmt.println("           the view does not cover the whole client area")
		}
	}

	if child_count == 0 {
		fmt.eprintfln("FAIL: nothing was created in the window after %.1fs", seconds)
		view^.removed(view_ptr)
		view^.release(view_ptr)
		return false
	}
	fmt.printfln("editor   : %v child window(s) -- the web view is up", child_count)

	// Resizing is where a ViewRect gets misread as a width and a height, so it
	// is worth doing once rather than trusting the arithmetic.
	resized := vst3.View_Rect{0, 0, width - 100, height - 60}
	view^.on_size(view_ptr, &resized)
	pump(0.3)

	view^.removed(view_ptr)
	if view^.release(view_ptr) != 0 {
		fmt.eprintln("FAIL: the view outlived its last reference")
		return false
	}
	fmt.println("editor   : closed cleanly")
	return true
}
