package tui

import "core:fmt"

import "../../../src/registry"

// One line of the UI: a registered parameter and the value the daemon last
// reported for it.
Row :: struct {
	desc:  registry.Parameter_Descriptor,
	value: int,
}

BAR_WIDTH :: 20

// Draw the whole screen. It is a full redraw on every event, which is fine
// because the UI is event-driven, not animated: nothing changes between keys.
render :: proc(rows: []Row, selected: int, path: string) {
	terminal_clear()
	terminal_move(1, 2)
	terminal_write("Quesynth")
	terminal_move(2, 2)
	terminal_write("-----------------------------------------------")

	for row, i in rows {
		terminal_move(4 + i, 2)
		marker := i == selected ? ">" : " "
		bar := make_bar(registry.registry_normalize(row.desc, row.value), BAR_WIDTH)
		defer delete(bar)
		line := fmt.tprintf(
			"%s %-16s %-10s %s",
			marker,
			row.desc.label,
			registry.registry_format(row.desc, row.value),
			bar,
		)
		terminal_write(line)
	}

	footer := 4 + len(rows) + 1
	terminal_move(footer, 2)
	terminal_write("-----------------------------------------------")
	terminal_move(footer + 1, 2)
	terminal_write("up/down select   left/right change   R reset   Q quit")
	terminal_move(footer + 2, 2)
	terminal_write(fmt.tprintf("daemon: %s", path))
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
