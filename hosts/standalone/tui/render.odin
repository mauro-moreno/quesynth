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
// frame, so a timed metrics refresh does not flicker.
render :: proc(
	rows: []Row,
	groups: []Group_View,
	current_group, selected: int,
	metrics: Metrics,
	path: string,
) {
	terminal_home()
	draw_line(1, "Quesynth")
	draw_line(2, group_tabs(groups, current_group))

	group := groups[current_group]
	first_row := 4
	for local, k in group.indices {
		r := rows[local]
		marker := k == selected ? ">" : " "
		bar := make_bar(registry.registry_normalize(r.desc, r.value), BAR_WIDTH)
		defer delete(bar)
		draw_line(
			first_row + k,
			fmt.tprintf(
				"%s %-16s %-12s %s",
				marker,
				r.desc.label,
				registry.registry_format(r.desc, r.value),
				bar,
			),
		)
	}

	status := first_row + len(group.indices) + 1
	draw_line(status, "-------------------------------------------------")
	draw_line(
		status + 1,
		fmt.tprintf(
			"voices %d/%d   %d Hz   buffer %d   rev %d   up %ds",
			metrics.voices,
			metrics.max_voices,
			metrics.sample_rate,
			metrics.buffer,
			metrics.revision,
			metrics.uptime,
		),
	)
	draw_line(status + 2, "Tab group   up/down select   left/right change   R reset   Q quit")
	draw_line(status + 3, fmt.tprintf("daemon: %s", path))

	// Clear anything a previously larger group left below the current one.
	terminal_write("\x1b[J")
}

// The tab strip, with the current group bracketed. Uses the temp allocator, so
// the caller need not free it; the run loop resets that allocator each frame.
@(private)
group_tabs :: proc(groups: []Group_View, current_group: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for g, i in groups {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if i == current_group {
			strings.write_byte(&b, '[')
			strings.write_string(&b, g.name)
			strings.write_byte(&b, ']')
		} else {
			strings.write_string(&b, g.name)
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

// A fixed-width fill bar. The caller frees the returned string.
@(private)
make_bar :: proc(norm: f32, width: int) -> string {
	buf := make([]u8, width)
	filled := int(norm * f32(width) + 0.5)
	filled = clamp(filled, 0, width)
	for i in 0 ..< width {
		buf[i] = i < filled ? '#' : '-'
	}
	return string(buf)
}
