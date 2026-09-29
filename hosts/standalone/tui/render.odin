package tui

import "core:fmt"
import "core:strings"

import "../../../src/registry"

// One line of the UI: a registered parameter and the value the daemon last
// reported for it.
Row :: struct {
	desc:  registry.Parameter_Descriptor,
	value: int,
}

// A tab: a parameter group and the row indices that belong to it, in order.
Group_View :: struct {
	name:    string,
	indices: []int,
}

BAR_WIDTH :: 20

// Build one tab per group, in first-appearance order, each listing the rows in
// that group. The caller frees the result with free_groups.
build_groups :: proc(rows: []Row) -> []Group_View {
	names: [dynamic]string
	defer delete(names)
	for r in rows {
		found := false
		for n in names {
			if n == r.desc.group {
				found = true
				break
			}
		}
		if !found {
			append(&names, r.desc.group)
		}
	}

	views := make([]Group_View, len(names))
	for name, gi in names {
		indices: [dynamic]int
		for r, ri in rows {
			if r.desc.group == name {
				append(&indices, ri)
			}
		}
		views[gi] = Group_View {
			name    = name,
			indices = indices[:],
		}
	}
	return views
}

free_groups :: proc(views: []Group_View) {
	for v in views {
		delete(v.indices)
	}
	delete(views)
}

// Draw the screen for the current group. Rendering is a bounded redraw: the
// cursor homes and each line is overwritten and cleared to its end, then the
// region below the last line is cleared. There is no full-screen clear per
// frame, so a timed metrics refresh does not flicker. Colours come from `theme`;
// with colour off every paint is a no-op and the layout is byte-for-byte plain.
render :: proc(
	rows: []Row,
	groups: []Group_View,
	current_group, selected: int,
	metrics: Metrics,
	path: string,
	theme: Theme,
) {
	terminal_home()
	draw_line(1, paint(theme, theme.title, "Quesynth"))
	draw_line(2, group_tabs(groups, current_group, theme))

	group := groups[current_group]
	first_row := 4
	for local, k in group.indices {
		r := rows[local]
		chosen := k == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		label := paint(
			theme,
			chosen ? theme.selected : theme.label,
			fmt.tprintf("%-16s", r.desc.label),
		)
		value := paint(theme, theme.value, fmt.tprintf("%-12s", registry.registry_format(r.desc, r.value)))
		bar := make_bar(theme, registry.registry_normalize(r.desc, r.value), BAR_WIDTH)
		draw_line(first_row + k, fmt.tprintf("%s %s %s %s", marker, label, value, bar))
	}

	status := first_row + len(group.indices) + 1
	draw_line(status, paint(theme, theme.dim, "-------------------------------------------------"))
	if !metrics.ok {
		draw_line(status + 1, paint(theme, theme.warning, "DISCONNECTED - cached values are stale; edits disabled"))
		draw_line(status + 2, paint(theme, theme.status, "Enter reconnect   Q quit (daemon is not stopped)"))
		draw_line(status + 3, paint(theme, theme.dim, fmt.tprintf("daemon: %s", path)))
		terminal_write("\x1b[J")
		return
	}
	draw_line(
		status + 1,
		paint(
			theme,
			theme.status,
			fmt.tprintf(
				"voices %d/%d   %d Hz   buffer %d   rev %d   up %ds",
				metrics.voices,
				metrics.max_voices,
				metrics.sample_rate,
				metrics.buffer,
				metrics.revision,
				metrics.uptime,
			),
		),
	)
	draw_line(status + 2, paint(theme, theme.status, "Tab group   up/down select   left/right change   R reset   Q quit"))
	draw_line(status + 3, paint(theme, theme.dim, fmt.tprintf("daemon: %s", path)))

	// Clear anything a previously larger group left below the current one.
	terminal_write("\x1b[J")
}

// The bank browser: the filled slots, one per line, the selected one marked.
// Same bounded redraw as the parameter view.
render_bank :: proc(slots: []Bank_Slot, selected: int, theme: Theme) {
	terminal_home()
	draw_line(1, paint(theme, theme.title, "Quesynth — Bank"))
	if len(slots) == 0 {
		draw_line(3, paint(theme, theme.warning, "the bank is empty"))
		draw_line(5, paint(theme, theme.status, "O load a patch file   Esc back   Q quit"))
		terminal_write("\x1b[J")
		return
	}
	for s, k in slots {
		chosen := k == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		text := paint(
			theme,
			chosen ? theme.selected : theme.label,
			fmt.tprintf("%3d  %s", s.slot, s.name),
		)
		draw_line(3 + k, fmt.tprintf("%s %s", marker, text))
	}
	foot := 3 + len(slots) + 1
	draw_line(foot, paint(theme, theme.dim, "-------------------------------------------------"))
	draw_line(foot + 1, paint(theme, theme.status, "up/down select   Enter load   S save here   O load file   Esc back"))
	terminal_write("\x1b[J")
}

// The tab strip, with the current group bracketed. Uses the temp allocator, so
// the caller need not free it; the run loop resets that allocator each frame.
@(private)
group_tabs :: proc(groups: []Group_View, current_group: int, theme: Theme) -> string {
	b := strings.builder_make(context.temp_allocator)
	for g, i in groups {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if i == current_group {
			strings.write_string(&b, paint(theme, theme.tab_active, fmt.tprintf("[%s]", g.name)))
		} else {
			strings.write_string(&b, paint(theme, theme.tab_inactive, g.name))
		}
	}
	return strings.to_string(b)
}

@(private)
draw_line :: proc(row: int, s: string) {
	terminal_move(row, 2)
	terminal_write(s)
	terminal_write("\x1b[K") // clear from the cursor to the end of the line
}

// A fixed-width fill bar, its filled and empty runs coloured. Temp-allocated.
@(private)
make_bar :: proc(theme: Theme, norm: f32, width: int) -> string {
	filled := clamp(int(norm * f32(width) + 0.5), 0, width)
	fill := strings.repeat("#", filled, context.temp_allocator)
	empty := strings.repeat("-", width - filled, context.temp_allocator)
	return fmt.tprintf("%s%s", paint(theme, theme.bar_fill, fill), paint(theme, theme.bar_empty, empty))
}
