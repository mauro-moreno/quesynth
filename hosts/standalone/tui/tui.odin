package tui

import "core:fmt"

import "../../../src/registry"

// The TUI: connect to a running daemon, cache the registered parameters, read
// their current values over the protocol, and let the user move them. It holds
// no engine state and makes no sound; every value it shows and every change it
// makes goes through the control socket.
//
// Descriptor metadata (ids, labels, ranges) comes from src/registry, the shared
// authoritative table the plan makes client-importable; live values come from
// the daemon. That split is the point: a client knows the shape of the synth
// from the registry and its state from the protocol.

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
		value, ok := client_get(&client, descriptor.id)
		rows[i].value = ok ? value : registry.registry_default(descriptor)
	}

	term: Terminal
	terminal_enter(&term)
	defer terminal_leave(&term)

	selected := 0
	for {
		render(rows[:], selected, path)

		switch read_key() {
		case .Quit:
			// Quitting closes the client only. The daemon -- a separate process
			// -- keeps making sound.
			return 0
		case .Up:
			if selected > 0 {
				selected -= 1
			}
		case .Down:
			if selected < len(rows) - 1 {
				selected += 1
			}
		case .Left:
			tui_nudge(&client, &rows[selected], -1)
		case .Right:
			tui_nudge(&client, &rows[selected], +1)
		case .Reset:
			row := &rows[selected]
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
// value the daemon accepted.
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
