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

// A tab: one section of the browser panel (ui/layout.js, through layout.odin),
// the rows in it in the panel's order, and the panel's groups within it, each a
// run of those rows under its heading.
Group_View :: struct {
	name:      string,
	indices:   []int,
	subgroups: []Subgroup_View,
}

// A heading and the run of a tab's indices under it: indices[start:][:count].
Subgroup_View :: struct {
	label:        string,
	start, count: int,
}

BAR_WIDTH :: 20

// Build one tab per panel section that has a registered parameter in it,
// listing the rows in the panel's order. Rows are matched by the parameter
// index they carry, so the indices are positions in `rows` whatever order the
// rows come in; a panel control with no row is left out, and so is a group or
// a section left with none. The caller frees the result with free_groups.
build_groups :: proc(rows: []Row) -> []Group_View {
	views: [dynamic]Group_View
	for section in PANEL_LAYOUT {
		indices: [dynamic]int
		subgroups: [dynamic]Subgroup_View
		for group in section.groups {
			start := len(indices)
			for p in group.params {
				for r, ri in rows {
					if r.desc.index == p {append(&indices, ri)}
				}
			}
			if len(indices) > start {
				append(&subgroups, Subgroup_View{label = group.label, start = start, count = len(indices) - start})
			}
		}
		if len(indices) == 0 {
			delete(indices)
			delete(subgroups)
			continue
		}
		append(&views, Group_View{name = section.title, indices = indices[:], subgroups = subgroups[:]})
	}
	return views[:]
}

free_groups :: proc(views: []Group_View) {
	for v in views {
		delete(v.indices)
		delete(v.subgroups)
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

// A refused archive/config change must remain visible through polling. Use
// the last footer row in every view, so startup migration errors show too.
render_notice :: proc(message: string, theme: Theme) {
	if message == "" { return }
	rows, cols := terminal_size()
	line := paint(theme, theme.warning, fmt.tprintf("Error: %s", message))
	terminal_write(fmt.tprintf("\x1b[%d;1H%s", max(rows, 6)-1, box_line(line, max(cols, 24)-4, theme)))
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
	// Cut to the frame: a bank's name in the title can be any length, and a top
	// row wider than the terminal wraps and pushes every row below it down.
	shown := truncate_visible(title, max(cols - 5, 0))
	tw := visible_width(shown)
	fill := max(cols - 5 - tw, 0)
	return fmt.tprintf(
		"%s%s%s%s",
		paint(theme, theme.dim, "┌─ "),
		paint(theme, theme.title, shown),
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

// Draw the parameter view for the current section: a tab strip, the section's
// rows under their group headings with value and bar, and a bottom-pinned
// status/help footer. The rows scroll to keep the selected one in view.
render :: proc(
	rows: []Row,
	groups: []Group_View,
	current_group, selected: int,
	metrics: Metrics,
	path: string,
	prov: Provenance,
	current_midi: string,
	theme: Theme,
) {
	term_rows, term_cols := terminal_size()
	body: [dynamic]string
	body.allocator = context.temp_allocator
	// Where the sound came from, so what is loaded is always in view.
	append(&body, paint(theme, theme.value, provenance_line(prov)))
	// Left out while unknown -- an older daemon, one with no MIDI backend, or
	// none reachable -- because any name shown then could be the wrong one.
	if metrics.ok && current_midi != "" {
		append(&body, paint(theme, theme.value, fmt.tprintf("midi: %s", current_midi)))
	}
	append(&body, group_tabs(groups, current_group, theme, max(term_cols, 24) - 4))
	append(&body, "")

	group := groups[current_group]
	// Size the value column to the widest reading in this group, so the bars line
	// up whether the readings are short numbers or long choice labels.
	vals: [dynamic]string
	vals.allocator = context.temp_allocator
	vw := 8
	for local in group.indices {
		r := rows[local]
		disp := registry.registry_value_display(r.desc, r.value)
		append(&vals, disp)
		vw = max(vw, visible_width(disp))
	}
	lines: [dynamic]string
	lines.allocator = context.temp_allocator
	selected_line := 0
	for sub in group.subgroups {
		append(&lines, paint(theme, theme.dim, strings.to_upper(sub.label, context.temp_allocator)))
		for k in sub.start ..< sub.start + sub.count {
			r := rows[group.indices[k]]
			chosen := k == selected
			if chosen {selected_line = len(lines)}
			marker := paint(theme, theme.selected, chosen ? ">" : " ")
			label := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%-16s", r.desc.label))
			padded := fmt.tprintf("%s%s", vals[k], strings.repeat(" ", vw - visible_width(vals[k]), context.temp_allocator))
			value := paint(theme, theme.value, padded)
			bar := make_bar(theme, registry.registry_normalize(r.desc, r.value), BAR_WIDTH)
			append(&lines, fmt.tprintf("%s %s %s %s", marker, label, value, bar))
		}
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
		// Two lines: on one, the last keys would be cut off at 80 columns.
		append(&footer, paint(theme, theme.status, "Tab group   arrows move/change   R reset   Q quit"))
		append(&footer, paint(theme, theme.status, "B banks   M midi   C settings"))
	}
	append(&footer, paint(theme, theme.dim, fmt.tprintf("daemon: %s", path)))

	// What present leaves above the separator and the footer, less the lines
	// already in the body: a section can be taller than the screen.
	body_count := max(term_rows, 6) - 2
	foot_n := min(len(footer), max(body_count - 1, 0))
	room := body_count - foot_n - (foot_n > 0 ? 1 : 0) - len(body)
	start, end := list_window(selected_line, len(lines), max(room, 1))
	append(&body, ..lines[start:end])
	present("Quesynth", body[:], footer[:], theme)
}

// The bank navigator (navigator.odin): the list of banks, or one bank's
// patches, cut down to the names a `/` search holds. The cursor is > and the
// patch the sound came from is *, two marks for two facts; the footer says
// what is playing whatever is being browsed. Rows keep their own numbers
// however many a search hides.
render_navigator :: proc(nav: ^Navigator, prov: Provenance, theme: Theme) {
	shown := nav_shown_rows(nav)
	position := 0
	for row, i in shown {
		if row == nav.cursor {position = i + 1}
	}
	esc := nav.level == .Banks ? "Esc hide" : "Esc banks"
	if len(nav.query) > 0 {esc = "Esc clear"}
	keys: string
	switch {
	case nav.searching:
		keys = "type to search   up/down move   Enter keep   Esc cancel   ^U clear"
	case nav.level == .Banks:
		keys = fmt.tprintf("Enter browse   O patch file   L bank file   Z archive   %s", esc)
	case nav.browsing == ORDINARY:
		keys = fmt.tprintf("Enter load   S save   O patch file   L bank file   %s", esc)
	case:
		keys = fmt.tprintf("Enter load   O patch file   Z archive   %s", esc)
	}
	search: string
	switch {
	case nav.searching:
		search = paint(theme, theme.selected, fmt.tprintf("/%s_", string(nav.query[:])))
	case len(nav.query) > 0:
		search = paint(theme, theme.value, fmt.tprintf("search: %s   %d of %d   / edit", string(nav.query[:]), len(shown), nav_row_count(nav)))
	case:
		search = paint(theme, theme.dim, "/ search names")
	}
	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	append(&footer, paint(theme, theme.status, fmt.tprintf("%d/%d   %s", position, len(shown), keys)))
	append(&footer, search)
	append(&footer, paint(theme, theme.value, playing_line(prov)))
	archive := nav.archive.open ? fmt.tprintf("archive: %s", nav.archive.path) : "no archive - Z opens one"
	append(&footer, paint(theme, theme.dim, archive))

	// The archive's hint is a line of its own below the banks, never a row the
	// cursor can land on: there is nothing on it to browse.
	hint := nav.level == .Banks ? nav_archive_hint(nav) : ""
	// What present leaves between the borders, the separator and the footer.
	// A short terminal gives up footer lines, the last first, rather than the
	// row under the cursor: present would hand the footer every row it asked
	// for and draw no list at all.
	rows, _ := terminal_size()
	rows = max(rows, 6)
	if len(footer) > rows - 4 { resize(&footer, rows - 4) }
	window := max(rows - 3 - len(footer) - (hint != "" ? 1 : 0), 1)
	start, end := list_window(max(position - 1, 0), len(shown), window)

	body: [dynamic]string
	body.allocator = context.temp_allocator
	if nav_row_count(nav) == 0 {
		append(&body, paint(theme, theme.warning, "(empty)"))
	} else if len(shown) == 0 {
		append(&body, paint(theme, theme.warning, "(no matches)"))
	}
	for row in shown[start:end] {
		text: string
		playing, empty := false, false
		switch {
		case nav.level == .Banks:
			text = nav_bank_text(nav, row)
		case nav.browsing == ORDINARY:
			s := nav.slots[row]
			text = fmt.tprintf("%3d  %s", s.slot, s.name)
			playing = nav_playing(prov, ORDINARY, s.slot)
			empty = !s.filled
		case:
			text = fmt.tprintf("%5d  %s", row, nav.patch_names[row])
			playing = nav_playing(prov, nav.browsing, row)
		}
		chosen := row == nav.cursor
		cursor := paint(theme, theme.selected, chosen ? ">" : " ")
		mark := paint(theme, theme.value, playing ? "*" : " ")
		colour := chosen ? theme.selected : (empty ? theme.dim : theme.label)
		append(&body, fmt.tprintf("%s%s %s", cursor, mark, paint(theme, colour, text)))
	}
	if hint != "" {
		append(&body, paint(theme, theme.dim, fmt.tprintf("   %s", hint)))
	}

	title := "Quesynth — Browsing banks"
	if nav.level == .Patches {
		label := nav.label
		if nav.browsing != ORDINARY && nav.browsing < len(nav.bank_names) {
			label = nav.bank_names[nav.browsing]
		}
		title = fmt.tprintf("Quesynth — Browsing: %s", label)
	}
	present(title, body[:], footer[:], theme)
}

// The MIDI input screen. `selected` is the daemon's token, not the cursor's
// row: the (*) moves only when the daemon says it listens to something else.
// `refused` is the row whose select the daemon turned down, or -1.
render_midi :: proc(devices: []Midi_Device, selected: string, cursor: int, refused: int, theme: Theme) {
	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	if refused >= 0 {
		token, name, is_input := midi_row(devices, refused)
		refusal := is_input ? fmt.tprintf("%s (%s)", name, token) : name
		append(&footer, paint(theme, theme.warning, fmt.tprintf("the daemon refused %s", refusal)))
	}
	append(&footer, paint(theme, theme.status, "up/down select   Enter use   R re-scan   Esc back   Q quit"))

	// What present leaves between the borders, the separator and the footer;
	// the window follows the cursor, as the navigator's does.
	rows, _ := terminal_size()
	window := max(rows - 3 - len(footer), 1)
	count := midi_row_count(devices)
	start := clamp(cursor - window + 1, 0, max(count - window, 0))
	end := min(count, start + window)

	body: [dynamic]string
	body.allocator = context.temp_allocator
	for row in start ..< end {
		if row == count - 1 && len(devices) == 0 {
			append(&body, paint(theme, theme.dim, "      (no MIDI inputs found)"))
		}
		token, name, is_input := midi_row(devices, row)
		chosen := row == cursor
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		text := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%s %s", token == selected ? "(*)" : "( )", name))
		if is_input {
			text = fmt.tprintf("%s  %s", text, paint(theme, theme.dim, token))
		}
		append(&body, fmt.tprintf("%s %s", marker, text))
	}
	present("Quesynth — MIDI input", body[:], footer[:], theme)
}

// The MIDI screen's rows, in order: All inputs, each input as the daemon
// listed it, None. A row's token is what midi.select takes for it.
@(private)
midi_row :: proc(devices: []Midi_Device, row: int) -> (token: string, name: string, is_input: bool) {
	if row <= 0 { return "all", "All inputs", false }
	if row > len(devices) { return "none", "None", false }
	return devices[row - 1].id, devices[row - 1].name, true
}

@(private)
midi_row_count :: proc(devices: []Midi_Device) -> int {
	return len(devices) + 2
}

// The row that selects `token`, if the list has one.
@(private)
midi_row_of :: proc(devices: []Midi_Device, token: string) -> (int, bool) {
	for row in 0 ..< midi_row_count(devices) {
		if t, _, _ := midi_row(devices, row); t == token { return row, true }
	}
	return 0, false
}

// The settings screen: the remembered paths, each editable, and where they are
// stored. Enter edits the highlighted row. The archive path is the daemon's --
// every front-end opens the same one -- so it is shown as the daemon has it,
// and only the bank path lives in this front-end's own config.
render_config :: proc(cfg: Config, archive_path: string, cfg_path: string, selected: int, theme: Theme) {
	unset :: "(unset — press Enter to set)"
	fields := [][2]string {
		{"Zip archive", archive_path == "" ? unset : archive_path},
		{"User bank", cfg.bank_path == "" ? unset : cfg.bank_path},
	}
	body: [dynamic]string
	body.allocator = context.temp_allocator
	for f, k in fields {
		chosen := k == selected
		marker := paint(theme, theme.selected, chosen ? ">" : " ")
		name := paint(theme, chosen ? theme.selected : theme.label, fmt.tprintf("%-14s", f[0]))
		value := paint(theme, f[1] == unset ? theme.dim : theme.value, f[1])
		append(&body, fmt.tprintf("%s %s %s", marker, name, value))
	}
	footer: [dynamic]string
	footer.allocator = context.temp_allocator
	append(&footer, paint(theme, theme.status, "up/down select   Enter edit   Esc back   Q quit"))
	append(&footer, paint(theme, theme.dim, fmt.tprintf("config: %s", cfg_path)))
	present("Quesynth — Settings", body[:], footer[:], theme)
}

CONFIG_FIELDS :: 2

// The tab strip, with the current group bracketed, in at most `width` cells.
// The panel has more sections than an 80-column strip holds, so the strip
// scrolls to keep the current one shown, with `<` and `>` where tabs are off
// either end. Temp-allocated.
@(private)
group_tabs :: proc(groups: []Group_View, current_group: int, theme: Theme, width: int) -> string {
	shown :: proc(groups: []Group_View, i, current: int) -> int {
		return strings.rune_count(groups[i].name) + (i == current ? 2 : 0)
	}
	more := current_group < len(groups) - 1 ? 2 : 0
	first := 0
	for ; first < current_group; first += 1 {
		w := first > 0 ? 2 : 0
		for i in first ..= current_group {w += shown(groups, i, current_group) + (i > first ? 1 : 0)}
		if w + more <= width {break}
	}
	b := strings.builder_make(context.temp_allocator)
	used := 0
	if first > 0 {
		strings.write_string(&b, paint(theme, theme.tab_inactive, "<"))
		used = 1
	}
	for i in first ..< len(groups) {
		gap := used > 0 ? 1 : 0
		w := gap + shown(groups, i, current_group)
		if i > current_group && used + w + (i < len(groups) - 1 ? 2 : 0) > width {
			strings.write_string(&b, " ")
			strings.write_string(&b, paint(theme, theme.tab_inactive, ">"))
			break
		}
		if gap > 0 {strings.write_byte(&b, ' ')}
		if i == current_group {
			strings.write_string(&b, paint(theme, theme.tab_active, fmt.tprintf("[%s]", groups[i].name)))
		} else {
			strings.write_string(&b, paint(theme, theme.tab_inactive, groups[i].name))
		}
		used += w
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
