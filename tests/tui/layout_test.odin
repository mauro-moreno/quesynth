#+build linux
package tui_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

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
			chosen := rows[v.indices[k]].desc.label
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
