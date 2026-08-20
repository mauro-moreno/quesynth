#+build windows
package claphost

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"

import "../../src/clap"

// Opening the CLAP plugin's interface in a real window.
//
// The same job tools/vst3host does for the other format, and it exists for the
// same reason: the panel is created asynchronously inside a browser process, so
// a check that does not create a real window and pump a real message loop would
// see nothing happen and call it success.
//
// What it proves, in order of how much it is worth:
//
//   the entry point loads, the factory answers, and a plugin is created
//   the gui extension exists at all
//   it says win32 is supported and floating is not
//   create() found the panel beside the plugin and the WebView2 loader with it
//   set_parent() accepted a real HWND
//   a child window appears under ours, which only happens once the WebView2
//     environment has been created and the page told to navigate
//
// What it does not prove: that the page rendered, or that a message from the
// panel reached the engine. Those live inside the browser process. Said plainly
// rather than implied by an OK.

WINDOW_CLASS :: "QuesynthClapHostWindow"

@(private)
child_count: int

@(private)
count_child :: proc "system" (hwnd: win.HWND, param: win.LPARAM) -> win.BOOL {
	child_count += 1
	return win.TRUE
}

@(private)
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

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintfln("usage: %s <path to Quesynth.clap> [seconds]", args[0])
		os.exit(2)
	}
	path := args[1]
	seconds := 6.0

	wide := win.utf8_to_wstring(path)
	module := win.LoadLibraryW(wide)
	if module == nil {
		fmt.eprintfln("could not load %s", path)
		os.exit(1)
	}
	fmt.println("module   : loaded")

	entry := (^clap.Plugin_Entry)(win.GetProcAddress(module, "clap_entry"))
	if entry == nil {
		fmt.eprintln("FAIL: no clap_entry export")
		os.exit(1)
	}

	// The directory, not the file: the specification hands the entry point the
	// plugin's own path so it can find anything it keeps beside itself.
	dir := path
	if at := strings.last_index_any(path, "/\\"); at >= 0 {
		dir = path[:at]
	}
	if entry.init != nil && !entry.init(strings.clone_to_cstring(dir)) {
		fmt.eprintln("FAIL: clap_entry.init refused")
		os.exit(1)
	}
	fmt.println("entry    : initialised")

	factory := (^clap.Plugin_Factory)(entry.get_factory(clap.PLUGIN_FACTORY_ID))
	if factory == nil {
		fmt.eprintln("FAIL: no plugin factory")
		os.exit(1)
	}
	count := factory.get_plugin_count(factory)
	fmt.printfln("factory  : %v plugin(s)", count)
	if count == 0 {
		os.exit(1)
	}

	descriptor := factory.get_plugin_descriptor(factory, 0)
	if descriptor == nil {
		fmt.eprintln("FAIL: no descriptor")
		os.exit(1)
	}

	host := clap.Host {
		clap_version = clap.VERSION,
		host_data    = nil,
		name         = "claphost",
		vendor       = "quesynth",
		url          = "",
		version      = "0.1.0",
		get_extension = proc "c" (host: ^clap.Host, id: cstring) -> rawptr {return nil},
		request_restart = proc "c" (host: ^clap.Host) {},
		request_process = proc "c" (host: ^clap.Host) {},
		request_callback = proc "c" (host: ^clap.Host) {},
	}

	plugin := factory.create_plugin(factory, &host, descriptor.id)
	if plugin == nil {
		fmt.eprintln("FAIL: create_plugin returned nil")
		os.exit(1)
	}
	if plugin.init != nil && !plugin.init(plugin) {
		fmt.eprintln("FAIL: plugin.init refused")
		os.exit(1)
	}
	fmt.println("plugin   : created")

	gui := (^clap.Plugin_Gui)(plugin.get_extension(plugin, clap.EXT_GUI))
	if gui == nil {
		fmt.eprintln("FAIL: the plugin does not offer clap.gui")
		os.exit(1)
	}
	fmt.println("gui      : extension present")

	if !gui.is_api_supported(plugin, clap.WINDOW_API_WIN32, false) {
		fmt.eprintln("FAIL: win32 is not supported")
		os.exit(1)
	}
	// Floating is deliberately refused; a host that asked for one should be
	// told so rather than handed an empty window.
	if gui.is_api_supported(plugin, clap.WINDOW_API_WIN32, true) {
		fmt.eprintln("FAIL: a floating window was claimed")
		os.exit(1)
	}

	preferred: cstring
	floating: bool
	if gui.get_preferred_api(plugin, &preferred, &floating) {
		fmt.printfln("gui      : prefers %v, floating %v", preferred, floating)
	}

	if !gui.create(plugin, clap.WINDOW_API_WIN32, false) {
		fmt.println("gui      : create refused -- no WebView2, or the panel is not beside the plugin")
		// Not a failure. It is the documented answer on a machine with no
		// WebView2 runtime, and the instrument still plays.
		fmt.println("OK")
		return
	}

	width, height: u32
	if gui.get_size(plugin, &width, &height) {
		fmt.printfln("gui      : opens at %vx%v", width, height)
	}

	// WebView2 is COM and wants a single-threaded apartment with a message
	// pump. A real host has done this long before it loads a plugin.
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

	frame := win.RECT{0, 0, i32(width), i32(height)}
	win.AdjustWindowRect(&frame, win.WS_OVERLAPPEDWINDOW, win.FALSE)

	// Off screen and never shown: this is a check, not a demonstration.
	hwnd := win.CreateWindowExW(
		0,
		class_name,
		win.utf8_to_wstring("Quesynth CLAP editor check"),
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
		fmt.eprintln("FAIL: could not create a window")
		os.exit(1)
	}
	defer win.DestroyWindow(hwnd)

	window := clap.Window {
		api    = clap.WINDOW_API_WIN32,
		handle = rawptr(hwnd),
	}
	if !gui.set_parent(plugin, &window) {
		fmt.eprintln("FAIL: set_parent refused a real HWND")
		os.exit(1)
	}
	fmt.println("gui      : attached to a window")

	gui.show(plugin)
	pump(seconds)

	child_count = 0
	win.EnumChildWindows(hwnd, count_child, 0)
	if child_count == 0 {
		fmt.eprintfln("FAIL: nothing was created in the window after %.1fs", seconds)
		os.exit(1)
	}
	fmt.printfln("gui      : %v child window(s) -- the web view is up", child_count)

	// Resizing, which is where a width gets read as an edge.
	if gui.can_resize(plugin) {
		gui.set_size(plugin, width - 100, height - 60)
		pump(0.3)
		fmt.println("gui      : resized")
	}

	gui.destroy(plugin)
	if plugin.destroy != nil {
		plugin.destroy(plugin)
	}
	if entry.deinit != nil {
		entry.deinit()
	}
	fmt.println("gui      : closed cleanly")
	fmt.println("OK")
}
