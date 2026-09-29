package tui

import "core:fmt"
import "core:strings"

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
	connected = client_load_snapshot(&client, rows[:])

	groups := build_groups(rows[:])
	defer free_groups(groups)
	if len(groups) == 0 {
		return 0
	}

	term: Terminal
	terminal_enter(&term)
	defer terminal_leave(&term)

	theme := theme_load()
	current_group := 0
	selected := 0
	metrics: Metrics
	if connected { metrics = client_info(&client); connected = metrics.ok }
	if !connected { client_close(&client) }

	// Bank browser state, active only while `browsing`.
	browsing := false
	bank_slots: []Bank_Slot
	bank_sel := 0

	for {
		// Reset the per-frame temp allocations (the tab strip and the formatted
		// lines) so the render loop does not grow memory without bound.
		free_all(context.temp_allocator)
		if browsing {
			render_bank(bank_slots, bank_sel, theme)
		} else {
			render(rows[:], groups, current_group, selected, metrics, path, theme)
		}

		key := read_key_timeout(REFRESH_MS)
		if browsing {
			switch key {
			case .Quit:
				client_bank_free(bank_slots)
				return 0
			case .Escape, .Bank:
				client_bank_free(bank_slots)
				bank_slots = nil
				browsing = false
			case .Up:
				if bank_sel > 0 { bank_sel -= 1 }
			case .Down:
				if bank_sel < len(bank_slots) - 1 { bank_sel += 1 }
			case .Enter:
				if connected && len(bank_slots) > 0 {
					if client_patch_load(&client, bank_slots[bank_sel].slot) {
						client_load_snapshot(&client, rows[:])
						metrics = client_info(&client)
						connected = metrics.ok
					}
					client_bank_free(bank_slots)
					bank_slots = nil
					browsing = false
				}
			case .Save:
				if connected && len(bank_slots) > 0 {
					tui_save(&client, bank_slots[bank_sel].slot, theme)
					client_bank_free(bank_slots)
					bank_slots, _ = client_bank_list(&client)
					bank_sel = clamp(bank_sel, 0, max(0, len(bank_slots) - 1))
				}
			case .Load_File:
				if connected && tui_load_file(&client, rows[:], theme) {
					metrics = client_info(&client)
					connected = metrics.ok
					client_bank_free(bank_slots)
					bank_slots = nil
					browsing = false
				}
			case .Tick, .Left, .Right, .Reset, .Tab, .Other:
			// Ignored in the browser.
			}
			if client.fd < 0 { connected = false; metrics = {} }
			continue
		}

		switch key {
		case .Tick:
			if connected {
				metrics = client_info(&client)
				connected = metrics.ok
				if !connected { client_close(&client) }
			}
		case .Quit:
			// Quitting closes the client only. The daemon -- a separate process
			// -- keeps making sound.
			return 0
		case .Tab:
			current_group = (current_group + 1) % len(groups)
			selected = 0
		case .Up:
			if selected > 0 { selected -= 1 }
		case .Down:
			if selected < len(groups[current_group].indices) - 1 { selected += 1 }
		case .Left:
			if connected { tui_nudge(&client, &rows[groups[current_group].indices[selected]], -1) }
		case .Right:
			if connected { tui_nudge(&client, &rows[groups[current_group].indices[selected]], +1) }
		case .Reset:
			if connected {
				row := &rows[groups[current_group].indices[selected]]
				if applied, ok := client_set(&client, row.desc.id, registry.registry_default(row.desc)); ok {
					row.value = applied
				}
			}
		case .Bank:
			if connected {
				if slots, ok := client_bank_list(&client); ok {
					bank_slots = slots
					bank_sel = 0
					browsing = true
				}
			}
		case .Load_File:
			if connected && tui_load_file(&client, rows[:], theme) {
				metrics = client_info(&client)
				connected = metrics.ok
			}
		case .Enter:
			if !connected {
				// A new connection gets a fresh snapshot, never a replay of an
				// edit whose acknowledgement may have been lost.
				client, connected = client_connect(path)
				if connected { connected = client_load_snapshot(&client, rows[:]) }
				if connected { metrics = client_info(&client); connected = metrics.ok }
				if !connected { client_close(&client); metrics = {} }
			}
		case .Save, .Escape, .Other:
		// Save applies only in the bank browser; Escape and Other are ignored.
		}
		if client.fd < 0 { connected = false; metrics = {} }
	}
}

// Save the live sound into a bank slot under a typed name, then optionally write
// the whole bank to a file. Both steps are cancellable with Escape.
@(private)
tui_save :: proc(client: ^Client, slot: int, theme: Theme) {
	terminal_clear()
	name, named := prompt_line(1, "Save current sound as: ", theme)
	if !named { return }
	if !client_patch_save(client, slot, name) { return }
	path, pathed := prompt_line(1, "Write bank to file (blank to skip): ", theme)
	trimmed := strings.trim_space(path)
	if pathed && len(trimmed) > 0 {
		client_bank_write(client, trimmed)
	}
}

// Prompt for a patch file path and load it live, refreshing the rows. Returns
// whether a load was attempted (so the caller re-reads metrics).
@(private)
tui_load_file :: proc(client: ^Client, rows: []Row, theme: Theme) -> bool {
	terminal_clear()
	path, ok := prompt_line(1, "Load patch file: ", theme)
	trimmed := strings.trim_space(path)
	if !ok || len(trimmed) == 0 { return false }
	if client_patch_load_file(client, trimmed) {
		client_load_snapshot(client, rows)
	}
	return true
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
