#+build linux
package panel_tests

import "core:testing"

import "../../src/webkitgtk"

// How the Linux editor brings GTK up inside a host, checked against stand-ins.
//
// The fault this guards against (issue #12) is one call: GTK's first
// initialisation sets GDK's single event handler to GTK's own (gtkmain.c,
// do_pre_parse_initialization). In REAPER, whose windows are SWELL's on GDK,
// that takes the handler from SWELL and the whole host stops answering. SWELL's
// way out is SWELL_ExtendedAPI("LOAD_GTK", NULL), which initialises GTK and
// sets SWELL's handler back (WDL/swell/swell-generic-gdk.cpp, SWELL_load_gtk).
//
// The stand-ins below model exactly those two facts, from the upstream sources
// rather than from this package: gtk_init_check makes GTK the handler, LOAD_GTK
// leaves SWELL the handler, and only the exact names and arguments SWELL
// declares are answered. No display or host is needed, and none is pretended:
// whether a real REAPER then draws the editor is not something this can see.

@(private = "file")
Handler :: enum {
	None,
	Swell,
	Gtk,
}

// One record per test thread: the runner runs tests in parallel, and the
// stand-ins are C procedures with nowhere else to keep it.
@(private = "file")
Fake :: struct {
	// What the process looks like before the editor starts.
	gdk_up:         bool,
	handler:        Handler,
	init_succeeds:  bool,
	// What the host offers.
	has_extended:   bool,
	load_gtk_works: bool,

	// What was done to it, in order.
	calls:          [16]string,
	n:              int,
	asked_for:      [4]string,
	asked:          int,
	load_key:       string,
	load_value:     rawptr,
	load_calls:     int,
	backends:       string,
}

@(private = "file", thread_local)
fake: Fake

@(private = "file")
record :: proc "contextless" (call: string) {
	if fake.n < len(fake.calls) {
		fake.calls[fake.n] = call
	}
	fake.n += 1
}

@(private = "file")
fake_display :: proc "c" () -> rawptr {
	record("gdk_display_get_default")
	return rawptr(uintptr(0x1)) if fake.gdk_up else nil
}

@(private = "file")
fake_backends :: proc "c" (backends: cstring) {
	record("gdk_set_allowed_backends")
	fake.backends = string(backends)
}

@(private = "file")
fake_setlocale :: proc "c" () {
	record("gtk_disable_setlocale")
}

@(private = "file")
fake_init_check :: proc "c" (argc: ^i32, argv: rawptr) -> webkitgtk.gboolean {
	record("gtk_init_check")
	// What GTK 3 does on its first initialisation, display or not.
	fake.handler = .Gtk
	if fake.init_succeeds {
		fake.gdk_up = true
	}
	return webkitgtk.gboolean(fake.init_succeeds)
}

@(private = "file")
LOAD_GTK_OK := cstring("OK")

// SWELL_ExtendedAPI: "OK" for LOAD_GTK when SWELL's GTK support works, NULL
// otherwise and for any key it does not know.
@(private = "file")
fake_extended :: proc "c" (key: cstring, value: rawptr) -> rawptr {
	record("SWELL_ExtendedAPI")
	fake.load_calls += 1
	fake.load_key = string(key)
	fake.load_value = value
	if string(key) != "LOAD_GTK" || !fake.load_gtk_works {
		return nil
	}
	// SWELL_load_gtk: gtk_init_check, which takes the handler, then SWELL's own
	// handler set back over it.
	fake.handler = .Gtk
	fake.handler = .Swell
	return rawptr(LOAD_GTK_OK)
}

// SWELLAPI_GetFunc: a function by exact name, NULL for anything else.
@(private = "file")
fake_get_func :: proc "c" (name: cstring) -> rawptr {
	record("SWELLAPI_GetFunc")
	if fake.asked < len(fake.asked_for) {
		fake.asked_for[fake.asked] = string(name)
	}
	fake.asked += 1
	if fake.has_extended && string(name) == "SWELL_ExtendedAPI" {
		return rawptr(fake_extended)
	}
	return nil
}

@(private = "file")
fake_api :: proc() -> webkitgtk.Api {
	return webkitgtk.Api {
		gdk_display_get_default = fake_display,
		gdk_set_allowed_backends = fake_backends,
		gtk_disable_setlocale = fake_setlocale,
		gtk_init_check = auto_cast fake_init_check,
	}
}

@(private = "file")
called :: proc(name: string) -> bool {
	for i in 0 ..< min(fake.n, len(fake.calls)) {
		if fake.calls[i] == name {
			return true
		}
	}
	return false
}

// A process that already runs GDK: REAPER after SWELL has opened its display.
@(private = "file")
host_with_gdk :: proc() {
	fake = {}
	fake.gdk_up = true
	fake.handler = .Swell
	fake.init_succeeds = true
}

// A process with no GDK in it yet, like this test.
@(private = "file")
host_without_gdk :: proc(init_succeeds: bool) {
	fake = {}
	fake.init_succeeds = init_succeeds
}

// REAPER: SWELL is asked, by the names it exports, and GTK comes up on SWELL's
// handler with nothing of GTK's called here at all.
@(test)
test_swell_brings_gtk_up_and_keeps_its_handler :: proc(t: ^testing.T) {
	host_with_gdk()
	fake.has_extended = true
	fake.load_gtk_works = true
	api := fake_api()

	ok := webkitgtk.init_gtk(fake_get_func, &api)

	testing.expect(t, ok, "SWELL initialised GTK, so the editor should start")
	testing.expect_value(t, fake.handler, Handler.Swell)
	testing.expect_value(t, fake.asked, 1)
	testing.expect_value(t, fake.asked_for[0], "SWELL_ExtendedAPI")
	testing.expect_value(t, fake.load_calls, 1)
	testing.expect_value(t, fake.load_key, "LOAD_GTK")
	testing.expect_value(t, fake.load_value, nil)
	testing.expect(t, !called("gtk_init_check"), "gtk_init_check was called after SWELL had initialised GTK")
	testing.expect(t, !called("gtk_disable_setlocale"), "GTK was touched after SWELL had initialised it")
	testing.expect(t, !called("gdk_set_allowed_backends"), "GDK was touched after SWELL had initialised GTK")
	testing.expect(t, !called("gdk_display_get_default"), "GDK was probed after SWELL had initialised GTK")
}

// GDK up, and no way to ask anyone: no editor, and the host keeps its handler.
@(test)
test_running_gdk_without_swell_is_refused :: proc(t: ^testing.T) {
	host_with_gdk()
	api := fake_api()

	ok := webkitgtk.init_gtk(nil, &api)

	testing.expect(t, !ok, "an editor was started on a GDK the host already runs")
	testing.expect_value(t, fake.handler, Handler.Swell)
	testing.expect(t, called("gdk_display_get_default"), "the running GDK was never looked for")
	testing.expect(t, !called("gtk_init_check"), "gtk_init_check took the host's event handler")
	testing.expect(t, !called("gtk_disable_setlocale"), "GTK was touched in a refused host")
	testing.expect(t, !called("gdk_set_allowed_backends"), "GDK was reconfigured in a refused host")
}

// A host with SWELL's table but no SWELL_ExtendedAPI in it: the same refusal.
@(test)
test_swell_without_extended_api_is_refused :: proc(t: ^testing.T) {
	host_with_gdk()
	fake.has_extended = false
	api := fake_api()

	ok := webkitgtk.init_gtk(fake_get_func, &api)

	testing.expect(t, !ok, "an editor was started with no SWELL_ExtendedAPI to share GDK through")
	testing.expect_value(t, fake.asked, 1)
	testing.expect_value(t, fake.asked_for[0], "SWELL_ExtendedAPI")
	testing.expect_value(t, fake.load_calls, 0)
	testing.expect_value(t, fake.handler, Handler.Swell)
	testing.expect(t, !called("gtk_init_check"), "gtk_init_check took the host's event handler")
}

// A SWELL that answers NULL to LOAD_GTK -- built without GTK support, or its
// GTK failed to start -- is no help either, and GDK is still the host's.
@(test)
test_swell_that_cannot_load_gtk_is_refused :: proc(t: ^testing.T) {
	host_with_gdk()
	fake.has_extended = true
	fake.load_gtk_works = false
	api := fake_api()

	ok := webkitgtk.init_gtk(fake_get_func, &api)

	testing.expect(t, !ok, "an editor was started after SWELL could not load GTK")
	testing.expect_value(t, fake.load_calls, 1)
	testing.expect_value(t, fake.load_key, "LOAD_GTK")
	testing.expect_value(t, fake.handler, Handler.Swell)
	testing.expect(t, !called("gtk_init_check"), "gtk_init_check took the host's event handler")
}

// Nobody runs GDK yet: GTK is initialised here as it always was -- X11, the
// host's locale left alone, then gtk_init_check -- in that order.
@(test)
test_fresh_process_initialises_gtk_itself :: proc(t: ^testing.T) {
	host_without_gdk(true)
	api := fake_api()

	ok := webkitgtk.init_gtk(nil, &api)

	testing.expect(t, ok, "GTK should start in a process with no GDK in it")
	testing.expect_value(t, fake.n, 4)
	testing.expect_value(t, fake.calls[0], "gdk_display_get_default")
	testing.expect_value(t, fake.calls[1], "gdk_set_allowed_backends")
	testing.expect_value(t, fake.calls[2], "gtk_disable_setlocale")
	testing.expect_value(t, fake.calls[3], "gtk_init_check")
	testing.expect_value(t, fake.backends, "x11")
}

// SWELL present but its GDK not up yet: LOAD_GTK says no, nothing is running to
// be taken over, so this falls back to initialising GTK as before.
@(test)
test_swell_saying_no_before_gdk_runs_falls_back :: proc(t: ^testing.T) {
	host_without_gdk(true)
	fake.has_extended = true
	fake.load_gtk_works = false
	api := fake_api()

	ok := webkitgtk.init_gtk(fake_get_func, &api)

	testing.expect(t, ok, "GTK should start where no GDK is running")
	testing.expect_value(t, fake.load_calls, 1)
	testing.expect(t, called("gtk_init_check"), "GTK was never initialised")
}

// No display to open: no editor, as before.
@(test)
test_fresh_process_without_display_has_no_editor :: proc(t: ^testing.T) {
	host_without_gdk(false)
	api := fake_api()

	ok := webkitgtk.init_gtk(nil, &api)

	testing.expect(t, !ok, "an editor was started with no display")
	testing.expect(t, called("gtk_init_check"), "gtk_init_check was not tried")
}

// The lookup itself, in a process that is not a SWELL host: this test binary
// exports no SWELLAPI_GetFunc, so the host has no table to offer.
@(test)
test_a_process_without_swell_has_no_table :: proc(t: ^testing.T) {
	testing.expect(t, webkitgtk.swell_get_func() == nil, "found a SWELLAPI_GetFunc in a process that has none")
}
