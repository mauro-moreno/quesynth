package tui

import "core:fmt"

import "../../../src/registry"

// The TUI: connect to a running daemon, cache the registered parameters, read
// their current values over the protocol, and let the user move them, one group
// at a time. It holds no engine state and makes no sound; every value it shows
// and every change it makes goes through the control socket.
//
// Descriptor metadata (ids, labels, ranges, groups) comes from src/registry, the
// shared authoritative table the plan makes client-importable; live values and
// metrics come from the daemon. That split is the point: a client knows the
// shape of the synth from the registry and its state from the protocol.

// How often the status line refreshes when no key is pressed. The synth is not a
// game; a few times a second is plenty to watch the voice count and uptime move.
REFRESH_MS :: 400

run :: proc(path: string) -> int {
	client, connected := client_connect(path)
	if !connected {
		fmt.eprintfln("error: cannot reach the daemon at %s", path)
		return 1
	}
	defer client_close(&client)

	descriptors := registry.registry_list()
	rows := make([]Row, len(descriptors))
	defer delete(rows)
	for descriptor, i in descriptors {
		rows[i].desc = descriptor
		rows[i].value = registry.registry_default(descriptor)
	}
	// One round-trip instead of a get per parameter: state.snapshot returns
	// every value at once, and fills the rows that match by id.
	client_load_snapshot(&client, rows[:])

	groups := build_groups(rows[:])
	defer free_groups(groups)
	if len(groups) == 0 {
		return 0
	}

	term: Terminal
	terminal_enter(&term)
	defer terminal_leave(&term)

	current_group := 0
	selected := 0
	metrics := client_info(&client)

	for {
		// Reset the per-frame temp allocations (the tab strip and the formatted
		// lines) so the render loop does not grow memory without bound.
		free_all(context.temp_allocator)
		render(rows[:], groups, current_group, selected, metrics, path)

		switch read_key_timeout(REFRESH_MS) {
		case .Tick:
			metrics = client_info(&client)
		case .Quit:
			// Quitting closes the client only. The daemon -- a separate process
			// -- keeps making sound.
			return 0
		case .Tab:
			current_group = (current_group + 1) % len(groups)
			selected = 0
		case .Up:
			if selected > 0 {
				selected -= 1
			}
		case .Down:
			if selected < len(groups[current_group].indices) - 1 {
				selected += 1
			}
		case .Left:
			tui_nudge(&client, &rows[groups[current_group].indices[selected]], -1)
		case .Right:
			tui_nudge(&client, &rows[groups[current_group].indices[selected]], +1)
		case .Reset:
			row := &rows[groups[current_group].indices[selected]]
			applied, ok := client_set(&client, row.desc.id, registry.registry_default(row.desc))
			if ok {
				row.value = applied
			}
		case .Enter, .Other:
		// Nothing yet; Enter becomes value-entry in a later slice.
		}
	}
}

// Move the selected parameter by one step, clamped to its domain, and adopt the
// value the daemon accepted. For an enum or a toggle this walks its states; for
// a continuous control it is a single-unit nudge.
@(private)
tui_nudge :: proc(client: ^Client, row: ^Row, delta: int) {
	lo, hi, _ := registry.registry_stored_range(row.desc)
	target := clamp(row.value + delta, lo, hi)
	if target == row.value {
		return
	}
	if applied, ok := client_set(client, row.desc.id, target); ok {
		row.value = applied
	}
}
