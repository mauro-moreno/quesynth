#+build linux
package synth_vst3

import "base:runtime"

import "../../src/vst3"
import "../panel"

// The event-loop seam on Linux.
//
// GTK has no system loop to run on inside a plugin, so the host lends its own:
// the web view watches GLib's file descriptors and a timer, and each of those is
// registered with the Steinberg Linux IRunLoop the host exposes as an extra
// interface of the IPlugFrame. When the host sees a registered descriptor ready,
// or the timer fires, it calls back on its GUI thread and the view takes one
// GMainContext pass. There is no loop of the plugin's own -- the same rule the
// CLAP build follows through its two loop extensions.
//
// The bridge is panel.Loop: editor.odin wires ed.panel.view.loop to the five
// procedures below before the view starts, and they turn each into an IRunLoop
// registration. IEventHandler and ITimerHandler are implemented here because the
// host calls them; one event handler is kept per descriptor, because
// unregisterEventHandler drops every descriptor a handler was registered for and
// the view removes descriptors one at a time.

EDITOR_PLATFORM_TYPE :: vst3.PLATFORM_TYPE_X11_EMBED_WINDOW_ID

// GLib polls only a handful of descriptors; this is comfortably above that.
FD_HANDLER_SLOTS :: 16

// vtbl first, so the pointer the host is handed casts straight back here.
Fd_Handler :: struct {
	vtbl:   ^vst3.IEventHandler_Vtbl,
	ed:     ^Editor,
	fd:     i32,
	active: bool,
}

Timer_Handler :: struct {
	vtbl: ^vst3.ITimerHandler_Vtbl,
	ed:   ^Editor,
}

Editor_Loop :: struct {
	run_loop: ^vst3.IRunLoop,
	fds:      [FD_HANDLER_SLOTS]Fd_Handler,
	timer:    Timer_Handler,
}

// Get the host's run loop and wire the view's loop callbacks to it. Called from
// view_attached before the view starts; a host that offers no run loop gets no
// editor rather than a private GTK thread.
editor_loop_attach :: proc(ed: ^Editor) -> bool {
	if ed == nil || ed.frame == nil {
		return false
	}
	iid := vst3.IID_RUN_LOOP()
	obj: rawptr
	if ed.frame.vtbl.query_interface(ed.frame, &iid, &obj) != vst3.RESULT_OK || obj == nil {
		return false
	}
	ed.loop.run_loop = (^vst3.IRunLoop)(obj)
	ed.loop.timer.vtbl = &TIMER_HANDLER_VTBL
	ed.loop.timer.ed = ed
	ed.panel.view.loop = panel.Loop {
		user             = ed,
		register_fd      = editor_register_fd,
		modify_fd        = editor_modify_fd,
		unregister_fd    = editor_unregister_fd,
		register_timer   = editor_register_timer,
		unregister_timer = editor_unregister_timer,
	}
	return true
}

editor_loop_detach :: proc(ed: ^Editor) {
	if ed == nil || ed.loop.run_loop == nil {
		return
	}
	rl := ed.loop.run_loop
	// The view unregisters its own descriptors and timer as it is destroyed, but
	// drop anything still live before letting go of the run loop.
	for &slot in ed.loop.fds {
		if slot.active {
			rl.vtbl.unregister_event_handler(rl, &slot)
			slot.active = false
		}
	}
	rl.vtbl.unregister_timer(rl, &ed.loop.timer)
	// queryInterface took a reference; balance it.
	rl.vtbl.release(rl)
	ed.loop.run_loop = nil
}

// -- panel.Loop bridge -------------------------------------------------------

// One slot per descriptor: reuse the slot already bound to this fd, otherwise
// take a free one. Nil when every slot is in use.
editor_fd_slot :: proc(ed: ^Editor, fd: i32) -> ^Fd_Handler {
	free: ^Fd_Handler
	for &slot in ed.loop.fds {
		if slot.active && slot.fd == fd {
			return &slot
		}
		if free == nil && !slot.active {
			free = &slot
		}
	}
	return free
}

editor_register_fd :: proc(user: rawptr, fd: i32, flags: panel.Fd_Flags) -> bool {
	ed := (^Editor)(user)
	if ed == nil || ed.loop.run_loop == nil {
		return false
	}
	slot := editor_fd_slot(ed, fd)
	if slot == nil {
		return false
	}
	slot.vtbl = &FD_HANDLER_VTBL
	slot.ed = ed
	slot.fd = fd
	slot.active = true
	rl := ed.loop.run_loop
	if rl.vtbl.register_event_handler(rl, slot, fd) != vst3.RESULT_OK {
		slot.active = false
		return false
	}
	return true
}

// IRunLoop watches a descriptor for readability and has no notion of the flags
// GLib passes, so a flag change needs nothing done to keep the descriptor live.
editor_modify_fd :: proc(user: rawptr, fd: i32, flags: panel.Fd_Flags) -> bool {
	ed := (^Editor)(user)
	if ed == nil {
		return false
	}
	return editor_fd_slot(ed, fd) != nil
}

editor_unregister_fd :: proc(user: rawptr, fd: i32) {
	ed := (^Editor)(user)
	if ed == nil || ed.loop.run_loop == nil {
		return
	}
	for &slot in ed.loop.fds {
		if slot.active && slot.fd == fd {
			ed.loop.run_loop.vtbl.unregister_event_handler(ed.loop.run_loop, &slot)
			slot.active = false
			return
		}
	}
}

editor_register_timer :: proc(user: rawptr, period_ms: u32) -> bool {
	ed := (^Editor)(user)
	if ed == nil || ed.loop.run_loop == nil {
		return false
	}
	rl := ed.loop.run_loop
	return rl.vtbl.register_timer(rl, &ed.loop.timer, u64(period_ms)) == vst3.RESULT_OK
}

editor_unregister_timer :: proc(user: rawptr) {
	ed := (^Editor)(user)
	if ed == nil || ed.loop.run_loop == nil {
		return
	}
	ed.loop.run_loop.vtbl.unregister_timer(ed.loop.run_loop, &ed.loop.timer)
}

// -- IEventHandler / ITimerHandler -------------------------------------------
//
// Implemented here, called by the host. Both do the same single GMainContext
// pass: the host only tells us that something is ready, and GLib's own check
// step reads the actual state of every source.

handler_add_ref :: proc "c" (this: rawptr) -> u32 {
	return 1
}

handler_release :: proc "c" (this: rawptr) -> u32 {
	// The handlers live inside Editor_Loop; the editor owns their lifetime, not
	// the host, so this never falls to zero.
	return 1
}

fd_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	if obj == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	if vst3.tuid_equal(iid, vst3.IID_FUNKNOWN()) || vst3.tuid_equal(iid, vst3.IID_EVENT_HANDLER()) {
		obj^ = this
		return vst3.RESULT_OK
	}
	obj^ = nil
	return vst3.NO_INTERFACE
}

fd_on_fd_is_set :: proc "c" (this: rawptr, fd: i32) {
	h := (^Fd_Handler)(this)
	if h == nil || h.ed == nil {
		return
	}
	context = h.ed.ctx
	panel.pump(&h.ed.panel)
}

timer_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	if obj == nil || iid == nil {
		return vst3.INVALID_ARGUMENT
	}
	if vst3.tuid_equal(iid, vst3.IID_FUNKNOWN()) || vst3.tuid_equal(iid, vst3.IID_TIMER_HANDLER()) {
		obj^ = this
		return vst3.RESULT_OK
	}
	obj^ = nil
	return vst3.NO_INTERFACE
}

timer_on_timer :: proc "c" (this: rawptr) {
	t := (^Timer_Handler)(this)
	if t == nil || t.ed == nil {
		return
	}
	context = t.ed.ctx
	panel.pump(&t.ed.panel)
}

FD_HANDLER_VTBL := vst3.IEventHandler_Vtbl {
	query_interface = fd_query_interface,
	add_ref         = handler_add_ref,
	release         = handler_release,
	on_fd_is_set    = fd_on_fd_is_set,
}

TIMER_HANDLER_VTBL := vst3.ITimerHandler_Vtbl {
	query_interface = timer_query_interface,
	add_ref         = handler_add_ref,
	release         = handler_release,
	on_timer        = timer_on_timer,
}
