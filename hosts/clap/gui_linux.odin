#+build linux
package synth_clap

import "base:runtime"

import "../../src/clap"
import "../panel"

GUI_API :: clap.WINDOW_API_X11

// The host drives GLib, through CLAP's two main-thread loop extensions. A host
// without them gets no editor; starting a private GTK loop instead would put
// the web view on a second GUI thread inside the host process.
gui_host_supported :: proc "contextless" (plugin: ^clap.Plugin) -> bool {
	s := synth_of(plugin)
	if s == nil || s.host == nil || s.host.get_extension == nil {
		return false
	}
	s.host_fd = (^clap.Host_Posix_Fd_Support)(s.host.get_extension(s.host, clap.EXT_POSIX_FD_SUPPORT))
	s.host_timer = (^clap.Host_Timer_Support)(s.host.get_extension(s.host, clap.EXT_TIMER_SUPPORT))
	return s.host_fd != nil && s.host_timer != nil &&
	       s.host_fd.register_fd != nil && s.host_fd.modify_fd != nil && s.host_fd.unregister_fd != nil &&
	       s.host_timer.register_timer != nil && s.host_timer.unregister_timer != nil
}

gui_extension :: proc "c" () -> rawptr {
	context = runtime.default_context()
	if !panel.available() {
		return nil
	}
	return &GUI
}

gui_loop_extension :: proc "c" (id: cstring) -> rawptr {
	switch string(id) {
	case clap.EXT_POSIX_FD_SUPPORT:
		return &GUI_FD
	case clap.EXT_TIMER_SUPPORT:
		return &GUI_TIMER
	}
	return nil
}

gui_prepare_loop :: proc(s: ^Synth) {
	s.editor.view.loop = panel.Loop {
		user             = s,
		register_fd      = gui_register_fd,
		modify_fd        = gui_modify_fd,
		unregister_fd    = gui_unregister_fd,
		register_timer   = gui_register_timer,
		unregister_timer = gui_unregister_timer,
	}
}

gui_register_fd :: proc(user: rawptr, fd: i32, flags: panel.Fd_Flags) -> bool {
	s := (^Synth)(user)
	return s.host_fd.register_fd(s.host, fd, transmute(u32)flags)
}

gui_modify_fd :: proc(user: rawptr, fd: i32, flags: panel.Fd_Flags) -> bool {
	s := (^Synth)(user)
	return s.host_fd.modify_fd(s.host, fd, transmute(u32)flags)
}

gui_unregister_fd :: proc(user: rawptr, fd: i32) {
	s := (^Synth)(user)
	s.host_fd.unregister_fd(s.host, fd)
}

gui_register_timer :: proc(user: rawptr, period_ms: u32) -> bool {
	s := (^Synth)(user)
	return s.host_timer.register_timer(s.host, period_ms, &s.gui_timer)
}

gui_unregister_timer :: proc(user: rawptr) {
	s := (^Synth)(user)
	s.host_timer.unregister_timer(s.host, s.gui_timer)
}

// These are only called on the main thread. The readiness flags and timer id
// identify why the host woke us, but GLib's check step reads the actual state of
// every source, so both callbacks do the same single pass.
gui_on_fd :: proc "c" (plugin: ^clap.Plugin, fd: i32, flags: u32) {
	s := synth_of(plugin)
	if s == nil {
		return
	}
	context = runtime.default_context()
	panel.pump(&s.editor)
}

gui_on_timer :: proc "c" (plugin: ^clap.Plugin, timer_id: clap.Id) {
	s := synth_of(plugin)
	if s == nil || timer_id != s.gui_timer {
		return
	}
	context = runtime.default_context()
	panel.pump(&s.editor)
}

GUI_FD := clap.Plugin_Posix_Fd_Support {on_fd = gui_on_fd}
GUI_TIMER := clap.Plugin_Timer_Support {on_timer = gui_on_timer}
