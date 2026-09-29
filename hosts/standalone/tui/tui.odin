package tui

import "core:fmt"
import "core:strings"
import "core:time"

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
	// The revision the displayed values were read at. When the daemon's revision
	// moves past it -- a load, a MIDI change, another client -- the rows are
	// re-snapshotted, so the parameter view always reflects the live state.
	shown_rev := metrics.revision

	// Bank browser state, active only while `browsing`.
	browsing := false
	bank_slots: []Bank_Slot
	bank_sel := 0

	// Archive browser state: 0 none, 1 banks, 2 patches. The opened archive and
	// its bank names persist while hidden, so returning to it costs no reload;
	// only the current patch list is re-fetched. `bank_arc_sel` remembers which
	// bank was highlighted so leaving and re-entering lands in the same place.
	archive_view := 0
	has_archive := false
	bank_names: []string
	patch_names: []string
	arc_sel := 0
	bank_arc_sel := 0

	for {
		// Reset the per-frame temp allocations (the tab strip and the formatted
		// lines) so the render loop does not grow memory without bound.
		free_all(context.temp_allocator)
		switch {
		case archive_view == 1:
			render_list("Quesynth — Archive banks", bank_names, arc_sel, "Enter open   O new archive   Esc hide   Q quit", theme)
		case archive_view == 2:
			render_list("Quesynth — Archive patches", patch_names, arc_sel, "Enter load   Esc back   Q quit", theme)
		case browsing:
			render_bank(bank_slots, bank_sel, theme)
		case:
			render(rows[:], groups, current_group, selected, metrics, path, theme)
		}

		key := read_key_timeout(REFRESH_MS)

		// The archive browser is a two-level list (banks, then patches) layered
		// over everything else; handle it first and skip the rest while it is up.
		if archive_view != 0 {
			items := archive_view == 1 ? bank_names : patch_names
			switch key {
			case .Quit:
				client_names_free(bank_names)
				client_names_free(patch_names)
				return 0
			case .Up:
				if arc_sel > 0 { arc_sel -= 1 }
			case .Down:
				if arc_sel < len(items) - 1 { arc_sel += 1 }
			case .Enter:
				if archive_view == 1 {
					if _, ok := client_archive_bank(&client, arc_sel); ok {
						if names, nok := client_archive_names(&client, "archive.patches"); nok {
							bank_arc_sel = arc_sel
							patch_names = names
							arc_sel = 0
							archive_view = 2
						}
					}
				} else if connected {
					// Load the patch live; stay in the list to audition others.
					prev_rev := metrics.revision
					if client_archive_load(&client, arc_sel) {
						metrics = tui_reload_values(&client, rows[:], prev_rev)
						connected = metrics.ok
					}
				}
			case .Load_File:
				// Open a different archive from the banks view, replacing this one.
				if archive_view == 1 && connected && tui_open_archive(&client, theme) {
					client_names_free(bank_names)
					bank_names = nil
					if names, ok := client_archive_names(&client, "archive.banks"); ok {
						bank_names = names
						arc_sel = 0
						bank_arc_sel = 0
					} else {
						has_archive = false
						archive_view = 0
					}
				}
			case .Escape, .Archive:
				if archive_view == 2 {
					// Back to the bank list, landing on the bank just left.
					client_names_free(patch_names)
					patch_names = nil
					arc_sel = bank_arc_sel
					archive_view = 1
				} else {
					// Hide the browser but keep the archive open, so returning to
					// it with A costs no reload.
					archive_view = 0
				}
			case .Tick, .Left, .Right, .Reset, .Tab, .Bank, .Save, .Load_Bank, .Other:
			// Ignored in the archive browser.
			}
			if client.fd < 0 { connected = false; metrics = {} }
			continue
		}

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
					prev_rev := metrics.revision
					if client_patch_load(&client, bank_slots[bank_sel].slot) {
						metrics = tui_reload_values(&client, rows[:], prev_rev)
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
				if connected {
					prev_rev := metrics.revision
					if m, did := tui_load_file(&client, rows[:], prev_rev, theme); did {
						metrics = m
						connected = metrics.ok
						client_bank_free(bank_slots)
						bank_slots = nil
						browsing = false
					}
				}
			case .Load_Bank:
				if connected && tui_load_bank(&client, theme) {
					client_bank_free(bank_slots)
					bank_slots, _ = client_bank_list(&client)
					bank_sel = clamp(bank_sel, 0, max(0, len(bank_slots) - 1))
				}
			case .Tick, .Left, .Right, .Reset, .Tab, .Archive, .Other:
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
				if !connected {
					client_close(&client)
				} else if metrics.revision != shown_rev {
					// Something moved the daemon's state; pull the new values in.
					client_load_snapshot(&client, rows[:])
					shown_rev = metrics.revision
				}
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
			if connected {
				prev_rev := metrics.revision
				if m, did := tui_load_file(&client, rows[:], prev_rev, theme); did {
					metrics = m
					connected = metrics.ok
				}
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
		case .Load_Bank:
			if connected && tui_load_bank(&client, theme) {
				// Loading a bank changes what is browsable; open the browser on it.
				if slots, ok := client_bank_list(&client); ok {
					bank_slots = slots
					bank_sel = 0
					browsing = true
				}
			}
		case .Archive:
			if connected {
				if has_archive {
					// The archive is already open; step back into it, no reload.
					arc_sel = bank_arc_sel
					archive_view = 1
				} else if tui_open_archive(&client, theme) {
					if names, ok := client_archive_names(&client, "archive.banks"); ok {
						bank_names = names
						has_archive = true
						arc_sel = 0
						bank_arc_sel = 0
						archive_view = 1
					}
				}
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

// Prompt for a patch file path and load it live. Returns the metrics after the
// load and whether a load was attempted. `prev_rev` is the revision before the
// load, so the values are read back only once the audio thread has applied it.
@(private)
tui_load_file :: proc(client: ^Client, rows: []Row, prev_rev: int, theme: Theme) -> (Metrics, bool) {
	terminal_clear()
	path, ok := prompt_line(1, "Load patch file: ", theme)
	trimmed := strings.trim_space(path)
	if !ok || len(trimmed) == 0 { return {}, false }
	if client_patch_load_file(client, trimmed) {
		return tui_reload_values(client, rows, prev_rev), true
	}
	return client_info(client), true
}

// Pull the values the daemon actually holds into the rows. A load is applied by
// the audio thread a block later and bumps the revision then, so this waits
// briefly for the revision to move past `prev_rev` before snapshotting --
// otherwise it would read back the values from before the load and the screen
// would look as if nothing changed. Returns the current metrics.
@(private)
tui_reload_values :: proc(client: ^Client, rows: []Row, prev_rev: int) -> Metrics {
	for _ in 0 ..< 25 {
		m := client_info(client)
		if !m.ok { return m }
		if m.revision != prev_rev {
			client_load_snapshot(client, rows)
			return m
		}
		time.sleep(8 * time.Millisecond)
	}
	// The revision never moved (an idle or stopped audio thread); snapshot anyway
	// rather than leave the display stuck.
	client_load_snapshot(client, rows)
	return client_info(client)
}

// Prompt for a bank file path and load it as the browsable bank. Returns whether
// the bank was replaced, so the caller can refresh its slot list.
@(private)
tui_load_bank :: proc(client: ^Client, theme: Theme) -> bool {
	terminal_clear()
	path, ok := prompt_line(1, "Load bank file: ", theme)
	trimmed := strings.trim_space(path)
	if !ok || len(trimmed) == 0 { return false }
	return client_bank_load_file(client, trimmed)
}

// Prompt for a zip archive path and open it for browsing. Returns whether an
// archive was opened, so the caller can fetch its bank list.
@(private)
tui_open_archive :: proc(client: ^Client, theme: Theme) -> bool {
	terminal_clear()
	path, ok := prompt_line(1, "Open archive (zip): ", theme)
	trimmed := strings.trim_space(path)
	if !ok || len(trimmed) == 0 { return false }
	_, opened := client_archive_open(client, trimmed)
	return opened
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
