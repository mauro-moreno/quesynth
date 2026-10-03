#+build linux
package tui_tests

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:thread"

import registry "../../src/registry"
import tui "../../hosts/standalone/tui"

// The synth screen's tabs are the browser panel's sections and its headings
// the panel's groups. tui.PANEL_LAYOUT is ui/layout.js carried over by
// tools/tuilayout.mjs, and tests/ui/tui-layout.test.mjs holds it to that file;
// these hold the TUI to it, and its section order to ui/layout.js directly.

@(private = "file")
registry_rows :: proc() -> []tui.Row {
	descriptors := registry.registry_list()
	rows := make([]tui.Row, len(descriptors), context.temp_allocator)
	for d, i in descriptors {
		rows[i] = {desc = d, value = registry.registry_default(d)}
	}
	return rows
}

@(private = "file")
registered :: proc(rows: []tui.Row, p: int) -> bool {
	for r in rows {
		if r.desc.index == p {return true}
	}
	return false
}

// Each tab and heading against the panel's, in order, with the panel's
// controls the rows do not carry left out: the rows under a heading are the
// rows carrying that group's parameters, in the group's order.
@(private = "file")
expect_panel_order :: proc(t: ^testing.T, rows: []tui.Row, groups: []tui.Group_View, loc := #caller_location) {
	g := 0
	for section in tui.PANEL_LAYOUT {
		params: [dynamic]int
		params.allocator = context.temp_allocator
		for group in section.groups {
			for p in group.params {
				if registered(rows, p) {append(&params, p)}
			}
		}
		if len(params) == 0 {continue}
		if !testing.expectf(t, g < len(groups), "no tab for %s", section.title, loc = loc) {return}
		view := groups[g]
		g += 1
		testing.expect_value(t, view.name, section.title, loc = loc)
		sub := 0
		for group in section.groups {
			want: [dynamic]int
			want.allocator = context.temp_allocator
			for p in group.params {
				if registered(rows, p) {append(&want, p)}
			}
			if len(want) == 0 {continue}
			if !testing.expectf(t, sub < len(view.subgroups), "%s has no heading %s", section.title, group.label, loc = loc) {return}
			s := view.subgroups[sub]
			sub += 1
			testing.expect_value(t, s.label, group.label, loc = loc)
			if !testing.expect_value(t, s.count, len(want), loc = loc) {continue}
			for p, k in want {
				testing.expect_value(t, rows[view.indices[s.start + k]].desc.index, p, loc = loc)
			}
		}
		testing.expect_value(t, sub, len(view.subgroups), loc = loc)
	}
	testing.expect_value(t, g, len(groups), loc = loc)
}

@(test)
test_tabs_are_the_browser_panels_sections_and_groups :: proc(t: ^testing.T) {
	rows := registry_rows()
	groups := tui.build_groups(rows)
	defer tui.free_groups(groups)
	expect_panel_order(t, rows, groups)

	// Every registered parameter has a place, and only one.
	seen := make([]int, len(rows), context.temp_allocator)
	for v in groups {
		for i in v.indices {seen[i] += 1}
	}
	for n, i in seen {
		testing.expectf(t, n == 1, "%s is shown %d times", rows[i].desc.id, n)
	}

	// The sections in the order ui/layout.js itself declares them.
	data, err := os.read_entire_file("ui/layout.js", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	at := 0
	for v in groups {
		i := strings.index(string(data[at:]), fmt.tprintf("title: %q", v.name))
		if !testing.expectf(t, i >= 0, "%s is not the next section of ui/layout.js", v.name) {return}
		at += i
	}

	// A registry group is not a tab: master.volume, "global" in the
	// registry, is the panel's Amplifier Level beside amp.velocity.
	for v in groups {
		for s in v.subgroups {
			for k in s.start ..< s.start + s.count {
				if rows[v.indices[k]].desc.id != "master.volume" {continue}
				testing.expect_value(t, v.name, "Amplifier")
				testing.expect_value(t, s.label, "Level")
			}
		}
	}
}

// The rows are matched by the parameter they carry, never by position, so
// another order or a subset still lands each row under its own heading -- and
// a heading or a tab with no row left is not shown.
@(test)
test_tabs_follow_the_rows_by_parameter_index :: proc(t: ^testing.T) {
	reversed := slice.clone(registry_rows(), context.temp_allocator)
	slice.reverse(reversed)
	groups := tui.build_groups(reversed)
	expect_panel_order(t, reversed, groups)
	tui.free_groups(groups)

	// Without the equalizer's tone and the arpeggiator: the Equalizer tab
	// loses its Tone heading, and there is no Arpeggiator tab.
	subset: [dynamic]tui.Row
	subset.allocator = context.temp_allocator
	for r in reversed {
		if r.desc.index == 60 || (r.desc.index >= 31 && r.desc.index <= 34) || r.desc.index == 59 {continue}
		append(&subset, r)
	}
	groups = tui.build_groups(subset[:])
	defer tui.free_groups(groups)
	expect_panel_order(t, subset[:], groups)
	for v in groups {
		testing.expect(t, v.name != "Arpeggiator")
		if v.name == "Equalizer" {
			testing.expect_value(t, len(v.subgroups), 1)
			testing.expect_value(t, v.subgroups[0].label, "Band")
		}
	}
}

// The synth screen: the current tab bracketed in the strip whichever it is,
// the headings over their rows, and the selected row in view however tall
// the section -- the row the marker is on being the one an edit changes.
@(test)
test_synth_screen_shows_each_section_and_keeps_the_selection_in_view :: proc(t: ^testing.T) {
	rows := registry_rows()
	groups := tui.build_groups(rows)
	defer tui.free_groups(groups)
	screen_of := proc(rows: []tui.Row, groups: []tui.Group_View, g, k: int) -> string {
		prov := tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}
		cap := capture_begin()
		tui.render(rows, groups, g, k, tui.Metrics{ok = true}, "/tmp/quesynth.sock", prov, "", plain_theme())
		return capture_end(cap)
	}
	for v, g in groups {
		for k in ([2]int{0, len(v.indices) - 1}) {
			screen := screen_of(rows, groups, g, k)
			testing.expectf(t, strings.contains(screen, fmt.tprintf("[%s]", v.name)), "no [%s] in %q", v.name, screen)
			chosen := panel_label(rows[v.indices[k]].desc.index)
			testing.expectf(t, strings.contains(screen, fmt.tprintf("│ > %-16s ", chosen)), "%s row %d (%s) not selected in %q", v.name, k, chosen, screen)
			for s in v.subgroups {
				if k >= s.start && k < s.start + s.count {
					testing.expectf(t, strings.contains(screen, fmt.tprintf("│ %s ", strings.to_upper(s.label, context.temp_allocator))), "no heading %s over %s in %q", s.label, chosen, screen)
				}
			}
		}
	}

	// Oscillators is taller than 80x24: at its last row the first heading
	// has scrolled away. The strip shows `>` while tabs are off its right end
	// and `<` once the current one has pushed tabs off its left.
	testing.expect_value(t, groups[1].name, "Oscillators")
	oscillators := screen_of(rows, groups, 1, len(groups[1].indices) - 1)
	testing.expect(t, strings.contains(oscillators, "│ SUB OSCILLATOR "), oscillators)
	testing.expect(t, !strings.contains(oscillators, "│ OSCILLATOR 1 "), oscillators)
	expect_rows(t, oscillators, "Master [Oscillators] Filter Amplifier Modulation Envelope LFO 1 LFO 2 >")
	last := len(groups) - 1
	expect_rows(t, screen_of(rows, groups, last, 0), fmt.tprintf("< LFO 1 LFO 2 Delay Chorus and Flanger Effect Equalizer Arpeggiator [%s]", groups[last].name))
}

// The label ui/layout.js prints under parameter p's control, as
// tests/ui/tui-layout.test.mjs holds tui.PANEL_LABELS to it.
@(private = "file")
panel_label :: proc(p: int) -> string {
	for l in tui.PANEL_LABELS {
		if l.param == p {return l.label}
	}
	return ""
}

// Each row is named as the browser panel names its control, where the
// registry's label, which is the API's, says something else.
@(test)
test_rows_carry_the_browser_panels_labels :: proc(t: ^testing.T) {
	rows := registry_rows()
	groups := tui.build_groups(rows)
	defer tui.free_groups(groups)
	for v, g in groups {
		for local, k in v.indices {
			want := panel_label(rows[local].desc.index)
			if !testing.expectf(t, want != "", "%s has no panel label", rows[local].desc.id) {continue}
			cap := capture_begin()
			tui.render(rows, groups, g, k, tui.Metrics{ok = true}, "/tmp/quesynth.sock", tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}, "", plain_theme())
			screen := capture_end(cap)
			testing.expectf(t, strings.contains(screen, fmt.tprintf("│ > %-16s ", want)), "%s is not drawn as %q", rows[local].desc.id, want)
		}
	}
	// Some the registry names otherwise.
	for c in ([]struct {
			id, panel, registry: string,
		} {
			{"osc1.shape", "Waveform", "Shape"},
			{"master.volume", "Gain", "Volume"},
			{"filter.kbd_track", "Key Tracking", "Kbd Track"},
			{"delay.mix", "Dry / Wet", "Dry/Wet"},
			{"lfo1.on", "Enable", "On"},
		}) {
		d, ok := registry.registry_describe(c.id)
		if !testing.expect(t, ok) {continue}
		testing.expect_value(t, d.label, c.registry)
		testing.expect_value(t, panel_label(d.index), c.panel)
	}
}

// ---- Narrow footers ---------------------------------------------------------

@(private = "file")
TIOCSWINSZ :: 0x5414

// What one draw puts on a pseudo-terminal of `rows` x `cols`, so the screen
// is drawn at that size as on a real terminal.
@(private = "file")
sized_screen :: proc(rows, cols: int, draw: proc(data: rawptr), data: rawptr) -> string {
	master := posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {return ""}
	defer posix.close(master)
	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {return ""}
	slave := posix.open(posix.ptsname(master), {.RDWR, .NOCTTY})
	if slave < 0 {return ""}
	ws := [4]u16{u16(rows), u16(cols), 0, 0}
	linux.ioctl(linux.Fd(slave), TIOCSWINSZ, uintptr(&ws))

	Drain :: struct {
		fd:  posix.FD,
		out: strings.Builder,
	}
	drain := Drain{fd = master, out = strings.builder_make(context.temp_allocator)}
	reader := thread.create_and_start_with_data(&drain, proc(p: rawptr) {
		d := (^Drain)(p)
		buf: [4096]u8
		for {
			n := posix.read(d.fd, raw_data(buf[:]), c.size_t(len(buf)))
			if n <= 0 {return}
			strings.write_bytes(&d.out, buf[:n])
		}
	})

	sync.mutex_lock(&stdout_capture)
	saved := posix.dup(posix.STDOUT_FILENO)
	posix.dup2(slave, posix.STDOUT_FILENO)
	draw(data)
	posix.dup2(saved, posix.STDOUT_FILENO)
	posix.close(saved)
	sync.mutex_unlock(&stdout_capture)
	posix.close(slave)
	thread.join(reader)
	thread.destroy(reader)
	return strings.to_string(drain.out)
}

@(private = "file")
Footer_Case :: struct {
	nav:   ^tui.Navigator,
	theme: tui.Theme,
}

@(private = "file")
draw_navigator :: proc(data: rawptr) {
	c := (^Footer_Case)(data)
	tui.render_navigator(c.nav, tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}, c.theme)
}

// At 60 columns, 56 inside the frame, a footer line too long for it ends in
// an ellipsis at the frame's edge rather than stopping mid-word.
@(test)
test_a_footer_too_wide_for_the_terminal_ends_in_an_ellipsis :: proc(t: ^testing.T) {
	slots := []tui.Bank_Slot{{slot = 0, name = "Init"}}
	nav := tui.Navigator{shown = true, level = .Banks, browsing = tui.ORDINARY, slots = slots, label = "Factory", archive = {bank = -1}}
	keys := "1/1   Enter browse   O patch file   L bank file   Z archive   Esc hide"
	// Cut to the 56 cells inside the frame, right up to its border.
	cut := fmt.tprintf("│ %s…\x1b[0m │", keys[:55])

	plain := Footer_Case{&nav, plain_theme()}
	screen := sized_screen(20, 60, draw_navigator, &plain)
	if !testing.expect(t, screen != "", "no pseudo-terminal") {return}
	testing.expectf(t, strings.contains(screen, cut), "no %q in %q", cut, screen)
	expect_rows(t, screen, "/ search names", "playing: (unsaved)", "no archive - Z opens one")
	testing.expect(t, !strings.contains(screen, keys[:56]), screen)
	// The list above is cut as it was, without one.
	testing.expect_value(t, strings.count(screen, "…"), 1)

	// Coloured, the colour is reset before the frame.
	coloured := Footer_Case{&nav, tui.theme_defaults()}
	screen = sized_screen(20, 60, draw_navigator, &coloured)
	at := strings.index(screen, fmt.tprintf("%s…\x1b[0m", keys[:55]))
	testing.expectf(t, at >= 0, "no reset after the ellipsis in %q", screen)

	// At 80 columns the same line fits and is drawn whole.
	wide := capture_begin()
	tui.render_navigator(&nav, tui.Provenance{slot = -1, archive_bank = -1, archive_patch = -1}, plain_theme())
	expect_rows(t, capture_end(wide), keys)

	// A line exactly as wide as the frame is not cut.
	exact := fmt.tprintf("archive: %s", strings.repeat("p", 56 - len("archive: "), context.temp_allocator))
	nav.archive = {open = true, bank = -1, path = exact[len("archive: "):]}
	screen = sized_screen(20, 60, draw_navigator, &plain)
	expect_rows(t, screen, exact)
	testing.expect_value(t, strings.count(screen, "…"), 1)
	nav.archive.path = fmt.tprintf("%sq", nav.archive.path)
	screen = sized_screen(20, 60, draw_navigator, &plain)
	cut = fmt.tprintf("│ %s…\x1b[0m │", exact[:55])
	testing.expectf(t, strings.contains(screen, cut), "no %q in %q", cut, screen)
}
