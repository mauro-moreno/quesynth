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

// The whole screen is redrawn as one framed box every frame. `present` writes
// every terminal row -- top border, body, an optional bottom-pinned footer, and
// the bottom border -- so a row a previous frame used is always overwritten and
// nothing is ever left stranded when a view or a group changes. All allocation is
// on the temp allocator the run loop resets each frame.
present :: proc(title: string, body: []string, footer: []string, theme: Theme) {
	rows, cols := terminal_size()
	if cols < 24 {cols = 24}
	if rows < 6 {rows = 6}
	inner := cols - 4 // "│ " ... " │"

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\x1b[H")
	strings.write_string(&b, box_top(title, cols, theme))

	body_count := rows - 2 // rows 2 .. rows-1
	foot_n := min(len(footer), max(body_count - 1, 0))
	sep := foot_n > 0 ? 1 : 0
	top_n := body_count - foot_n - sep

	for i in 0 ..< body_count {
		strings.write_string(&b, fmt.tprintf("\x1b[%d;1H", 2 + i))
		line := ""
		if i < top_n {
			if i < len(body) {line = body[i]}
		} else if sep == 1 && i == top_n {
			line = paint(theme, theme.dim, strings.repeat("─", inner, context.temp_allocator))
		} else {
			fi := i - top_n - sep
			if fi >= 0 && fi < foot_n {line = footer[fi]}
		}
		strings.write_string(&b, box_line(line, inner, theme))
	}

	strings.write_string(&b, fmt.tprintf("\x1b[%d;1H", rows))
	strings.write_string(&b, box_bottom(cols, theme))
	terminal_write(strings.to_string(b))
}

// The visible width of a string in terminal cells: runes counted, ANSI colour
// escapes skipped. Enough for this UI, whose content is ASCII and box glyphs.
@(private)
visible_width :: proc(s: string) -> int {
	w := 0
	in_esc := false
	for r in s {
		if in_esc {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {in_esc = false}
			continue
		}
		if r == 0x1b {
			in_esc = true
			continue
		}
		w += 1
	}
	return w
}

// Cut a (possibly coloured) string to at most `max` visible cells, ending with a
// reset so a truncated colour does not bleed into the border.
@(private)
truncate_visible :: proc(s: string, max: int) -> string {
	if visible_width(s) <= max {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	w := 0
	in_esc := false
	for r in s {
		if in_esc {
			strings.write_rune(&b, r)
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {in_esc = false}
			continue
		}
		if r == 0x1b {
			in_esc = true
			strings.write_rune(&b, r)
			continue
		}
		if w >= max {break}
		strings.write_rune(&b, r)
		w += 1
	}
	strings.write_string(&b, "\x1b[0m")
	return strings.to_string(b)
}

@(private)
box_top :: proc(title: string, cols: int, theme: Theme) -> string {
	tw := visible_width(title)
	fill := max(cols - 5 - tw, 0)
	return fmt.tprintf(
		"%s%s%s%s",
		paint(theme, theme.dim, "┌─ "),
		paint(theme, theme.title, title),
		paint(theme, theme.dim, " "),
		paint(theme, theme.dim, fmt.tprintf("%s┐", strings.repeat("─", fill, context.temp_allocator))),
	)
}

@(private)
box_bottom :: proc(cols: int, theme: Theme) -> string {
	return paint(theme, theme.dim, fmt.tprintf("└%s┘", strings.repeat("─", cols - 2, context.temp_allocator)))
}

@(private)
box_line :: proc(content: string, inner: int, theme: Theme) -> string {
	c := truncate_visible(content, inner)
	pad := max(inner - visible_width(c), 0)
	edge := paint(theme, theme.dim, "│")
	return fmt.tprintf("%s %s%s %s", edge, c, strings.repeat(" ", pad, context.temp_allocator), edge)
}

// Draw the parameter view for the current group: a tab strip, the group's rows
// with value and bar, and a bottom-pinned status/help footer.
render :: proc(
	rows: []Row,
	groups: []Group_View,
	current_group, selected: int,
	metrics: Metrics,
	path: string,
	theme: Theme,
) {
	body: [dynamic]string
	body.allocator = context.temp_allocator
	append(&body, group_tabs(groups, current_group, theme))
	append(&body, "")

	group := groups[current_group]
	for local, k in group.indices {
		r := rows[local]
		chosen := k == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		label := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%-16s", r.desc.label))
		value := paint(theme, theme.value, fmt.tprintf("%-16s", registry.registry_value_display(r.desc, r.value)))
		bar := make_bar(theme, registry.registry_normalize(r.desc, r.value), BAR_WIDTH)
		append(&body, fmt.tprintf("%s %s %s %s", marker, label, value, bar))
	}

	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	if !metrics.ok {
		append(&footer, paint(theme, theme.warning, "DISCONNECTED - cached values are stale; edits disabled"))
		append(&footer, paint(theme, theme.status, "Enter reconnect   Q quit (daemon is not stopped)"))
	} else {
		append(
			&footer,
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
		append(&footer, paint(theme, theme.status, "Tab group   arrows move/change   R reset   B bank   A archive   Q quit"))
	}
	append(&footer, paint(theme, theme.dim, fmt.tprintf("daemon: %s", path)))
	present("Quesynth", body[:], footer[:], theme)
}

// The slot bank browser.
render_bank :: proc(slots: []Bank_Slot, selected: int, theme: Theme) {
	body: [dynamic]string
	body.allocator = context.temp_allocator
	if len(slots) == 0 {
		append(&body, paint(theme, theme.warning, "the bank is empty"))
	}
	for s, k in slots {
		chosen := k == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		text := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%3d  %s", s.slot, s.name))
		append(&body, fmt.tprintf("%s %s", marker, text))
	}
	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	append(&footer, paint(theme, theme.status, "up/down select   Enter load   S save   O patch file   L bank file   Esc back"))
	present("Quesynth — Bank", body[:], footer[:], theme)
}

// A scrolling list, used for the archive's bank and patch views. The window
// follows the selection, so a list far larger than the terminal browses without
// drawing it all.
render_list :: proc(title: string, items: []string, selected: int, footer_text: string, theme: Theme) {
	rows, _ := terminal_size()
	window := max(rows - 5, 1) // room for both borders, a separator and the footer

	body: [dynamic]string
	body.allocator = context.temp_allocator
	if len(items) == 0 {
		append(&body, paint(theme, theme.warning, "(empty)"))
	}
	start := 0
	if selected >= window {
		start = selected - window + 1
	}
	if start > len(items) - window {
		start = max(0, len(items) - window)
	}
	end := min(len(items), start + window)
	for i in start ..< end {
		chosen := i == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		text := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%5d  %s", i, items[i]))
		append(&body, fmt.tprintf("%s %s", marker, text))
	}
	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	count := len(items) == 0 ? 0 : selected + 1
	append(&footer, paint(theme, theme.status, fmt.tprintf("%d/%d   %s", count, len(items), footer_text)))
	present(title, body[:], footer[:], theme)
}

// The tab strip, with the current group bracketed. Temp-allocated.
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

// A fixed-width fill bar, its filled and empty runs coloured. Temp-allocated.
@(private)
make_bar :: proc(theme: Theme, norm: f32, width: int) -> string {
	filled := clamp(int(norm * f32(width) + 0.5), 0, width)
	fill := strings.repeat("#", filled, context.temp_allocator)
	empty := strings.repeat("-", width - filled, context.temp_allocator)
	return fmt.tprintf("%s%s", paint(theme, theme.bar_fill, fill), paint(theme, theme.bar_empty, empty))
}
