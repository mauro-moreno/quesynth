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
// Descriptor metadata (ids, labels, ranges) comes from src/registry, the
// shared authoritative table the plan makes client-importable; live values and
// metrics come from the daemon. That split is the point: a client knows the
// shape of the synth from the registry and its state from the protocol. The
// tabs and their order are the browser panel's sections (layout.odin).

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

	// The bank navigator (navigator.odin): the ordinary bank and the archive's
	// banks as one list, each opened onto its patches. What it lists and where
	// its cursor is persist while hidden, so B reopens exactly where the user
	// left off.
	nav := Navigator{browsing = ORDINARY, archive = {bank = -1}}
	defer nav_free(&nav)

	// Which patch the daemon is playing and where it came from, shown on the
	// synth screen and marked in the navigator. The daemon owns this, not the
	// client, so a load from another front-end shows here too. Re-read every
	// tick, and straight after this client's own loads and saves so the screen
	// never lags its own action; unnamed until one names it.
	prov := Provenance{slot = -1, archive_bank = -1, archive_patch = -1}
	defer provenance_free(&prov)
	// The name of the native MIDI input the daemon listens to, for the same
	// screen. The browser page changes it too, so it is re-read with the
	// patch; "" while unknown.
	current_midi := ""
	defer delete(current_midi)

	// MIDI input screen state, live only while `choosing_midi`: the inputs and
	// the daemon's token as the last midi.list gave them, the cursor, and the
	// row whose select the daemon refused (-1 for none). The token is only
	// ever the daemon's answer; this screen asks for a change and shows what
	// the daemon then says, it never holds a choice of its own.
	choosing_midi := false
	midi_devices: []Midi_Device
	midi_selected := ""
	midi_cursor := 0
	midi_refused := -1

	// Remembered settings (the user bank path) and the settings screen state.
	// The archive path is the daemon's, which reopens it at its own start for
	// every front-end; config.conf holds one only from before that.
	config := config_load()
	defer config_free(&config)
	configuring := false
	config_sel := 0
	// A remembered user bank is loaded so it is browsable from the first B.
	if connected && config.bank_path != "" {
		client_bank_load_file(&client, config.bank_path)
	}
	if connected {
		tui_migrate_archive(&client, &config)
		tui_read_provenance(&client, &prov)
		tui_read_midi(&client, &current_midi)
	}
	for {
		// Reset the per-frame temp allocations (the tab strip and the formatted
		// lines) so the render loop does not grow memory without bound.
		free_all(context.temp_allocator)
		switch {
		case configuring:
			cfg_path, _ := config_file_path(context.temp_allocator)
			render_config(config, nav.archive.path, cfg_path, config_sel, theme)
		case nav.shown:
			render_navigator(&nav, prov, theme)
		case choosing_midi:
			render_midi(midi_devices, midi_selected, midi_cursor, midi_refused, theme)
		case:
			render(rows[:], groups, current_group, selected, metrics, path, prov, current_midi, theme)
		}
		render_notice(client.notice, theme)

		if nav.shown && nav.searching {
			buf: [256]u8
			n := read_input_timeout(REFRESH_MS, buf[:])
			if n < 0 { return 0 }
			if n == 0 {
				if connected && tui_read_provenance(&client, &prov) { tui_sync_navigator(&client, &nav, prov) }
			} else {
				client_set_notice(&client, "")
				if nav_search_input(&nav, buf[:n]) == .Quit { return 0 }
			}
			if client.fd < 0 { connected = false; metrics = {} }
			continue
		}
		// A read takes 8 bytes at most. What a long paste carries behind a `/`
		// past that comes in the next read, which the search takes whole.
		input: [8]u8
		key, typed := read_key_timeout(REFRESH_MS, input[:])
		if key != .Tick { client_set_notice(&client, "") }

		// The settings screen sits over everything; handle it first.
		if configuring {
			switch key {
			case .Quit:
				return 0
			case .Up:
				if config_sel > 0 { config_sel -= 1 }
			case .Down:
				if config_sel < CONFIG_FIELDS - 1 { config_sel += 1 }
			case .Enter:
				tui_edit_setting(&client, &config, config_sel, theme)
				if connected {
					tui_read_provenance(&client, &prov)
					tui_sync_navigator(&client, &nav, prov, true)
				}
			case .Tick:
				// The archive path shown is the daemon's, and a peer may change it.
				if connected && tui_read_provenance(&client, &prov) { tui_sync_navigator(&client, &nav, prov) }
			case .Escape, .Config:
				configuring = false
			case .Left, .Right, .Reset, .Tab, .Bank, .Save, .Load_File, .Load_Bank, .Midi, .Open_Archive, .Search, .Other:
			// Ignored on the settings screen.
			}
			if client.fd < 0 { connected = false; metrics = {} }
			continue
		}

		// The navigator is a two-level list (banks, then a bank's patches)
		// layered over everything else; handle it first and skip the rest while
		// it is up. Moving through it only browses: a sound changes on Enter at
		// the patches, never because a cursor or a bank moved.
		if nav.shown {
			switch key {
			case .Quit:
				return 0
			case .Tick:
				// A peer's load moves the playing mark, and its bank or archive
				// change the lists, while this screen is up.
				if connected && tui_read_provenance(&client, &prov) { tui_sync_navigator(&client, &nav, prov) }
			case .Up:
				nav_move(&nav, -1)
			case .Down:
				nav_move(&nav, 1)
			case .Escape:
				nav_escape(&nav)
			case .Bank:
				nav.shown = false
			case .Search:
				if nav_search_start(&nav, typed) == .Quit { return 0 }
			case .Enter:
				if connected && nav.level == .Banks && nav_selected(&nav) {
					tui_browse_bank(&client, &nav, nav_row_bank(nav.cursor), prov)
				} else if connected {
					prev_rev := metrics.revision
					if tui_load_cursor(&client, &nav) {
						// Back to the synth. The level and cursor stay, so B
						// reopens here to pick another.
						metrics = tui_reload_values(&client, rows[:], prev_rev)
						connected = metrics.ok
						if connected { tui_read_provenance(&client, &prov) }
						nav.shown = false
					}
				}
			case .Save:
				// Only into the ordinary bank: an archive is read-only.
				if connected && nav.level == .Patches && nav.browsing == ORDINARY && nav_selected(&nav) {
					tui_save(&client, nav.slots[nav.cursor].slot, theme)
					tui_read_provenance(&client, &prov)
					tui_sync_navigator(&client, &nav, prov, true)
				}
			case .Load_File:
				if connected {
					prev_rev := metrics.revision
					if m, did := tui_load_file(&client, rows[:], prev_rev, theme); did {
						metrics = m
						connected = metrics.ok
						if connected { tui_read_provenance(&client, &prov) }
						nav.shown = false
					}
				}
			case .Load_Bank:
				// The bank just loaded is what there is to browse.
				if connected && tui_load_bank(&client, theme) {
					tui_read_provenance(&client, &prov)
					tui_sync_navigator(&client, &nav, prov, true)
					nav_descend(&nav, ORDINARY, prov)
				}
			case .Open_Archive:
				if connected && tui_open_archive(&client, theme) {
					tui_read_provenance(&client, &prov)
					tui_sync_navigator(&client, &nav, prov, true)
					nav_search_clear(&nav)
					nav.level = .Banks
					nav.cursor = nav_bank_row(max(nav.archive.bank, 0))
					nav_move(&nav, 0)
				}
			case .Left, .Right, .Reset, .Tab, .Config, .Midi, .Other:
			// Ignored in the navigator.
			}
			if client.fd < 0 { connected = false; metrics = {} }
			continue
		}

		if choosing_midi {
			switch key {
			case .Quit:
				client_midi_free(midi_devices)
				delete(midi_selected)
				return 0
			case .Up:
				if midi_cursor > 0 { midi_cursor -= 1 }
			case .Down:
				if midi_cursor < midi_row_count(midi_devices) - 1 { midi_cursor += 1 }
			case .Enter:
				if connected {
					token, _, _ := midi_row(midi_devices, midi_cursor)
					if client_midi_select(&client, token) {
						tui_read_midi(&client, &current_midi)
						client_midi_free(midi_devices)
						delete(midi_selected)
						midi_devices = nil
						midi_selected = ""
						choosing_midi = false
					} else if client.fd >= 0 {
						// Refused, not disconnected: stay, so the user can pick
						// another or re-scan for what is plugged in now.
						midi_refused = midi_cursor
					}
				}
			case .Reset:
				if connected {
					if devices, token, _, ok := client_midi_list(&client); ok {
						// The cursor stays on its input if that is still
						// there, wherever the list moved it to.
						on, _, _ := midi_row(midi_devices, midi_cursor)
						cursor, kept := midi_row_of(devices, on)
						if !kept { cursor, _ = midi_row_of(devices, token) }
						client_midi_free(midi_devices)
						delete(midi_selected)
						midi_devices = devices
						midi_selected = token
						midi_cursor = cursor
						midi_refused = -1
					}
				}
			case .Escape, .Midi:
				client_midi_free(midi_devices)
				delete(midi_selected)
				midi_devices = nil
				midi_selected = ""
				choosing_midi = false
			case .Tick:
				if connected { tui_refresh_midi_selected(&client, &midi_selected) }
			case .Left, .Right, .Tab, .Bank, .Save, .Load_File, .Load_Bank, .Config, .Open_Archive, .Search, .Other:
			// Ignored on the MIDI screen.
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
				} else {
					if metrics.revision != shown_rev {
						// Something moved the daemon's state; pull the new values in.
						client_load_snapshot(&client, rows[:])
						shown_rev = metrics.revision
					}
					// Another front-end may have loaded, saved or replaced the
					// bank, or chosen another MIDI input.
					tui_read_provenance(&client, &prov)
					tui_read_midi(&client, &current_midi)
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
				tui_sync_navigator(&client, &nav, prov, true)
				nav_open(&nav, prov)
			}
		case .Load_File:
			if connected {
				prev_rev := metrics.revision
				if m, did := tui_load_file(&client, rows[:], prev_rev, theme); did {
					metrics = m
					connected = metrics.ok
					if connected { tui_read_provenance(&client, &prov) }
				}
			}
		case .Enter:
			if !connected {
				// A new connection gets a fresh snapshot, never a replay of an
				// edit whose acknowledgement may have been lost.
				client, connected = client_connect(path)
				if connected { connected = client_load_snapshot(&client, rows[:]) }
				if connected { metrics = client_info(&client); connected = metrics.ok }
				if connected {
					tui_migrate_archive(&client, &config)
					tui_read_provenance(&client, &prov)
					tui_read_midi(&client, &current_midi)
				}
				if !connected { client_close(&client); metrics = {} }
			}
		case .Load_Bank:
			if connected && tui_load_bank(&client, theme) {
				tui_read_provenance(&client, &prov)
				// Loading a bank changes what is browsable; open the navigator
				// on it.
				tui_sync_navigator(&client, &nav, prov, true)
				nav_open(&nav, prov)
				nav_descend(&nav, ORDINARY, prov)
			}
		case .Config:
			// The archive path it shows is the daemon's, read afresh.
			if connected { tui_sync_navigator(&client, &nav, prov, true) }
			configuring = true
			config_sel = 0
		case .Midi:
			if connected {
				if devices, token, _, ok := client_midi_list(&client); ok {
					midi_devices = devices
					midi_selected = token
					// On the input the daemon listens to, so Enter at once
					// changes nothing.
					midi_cursor, _ = midi_row_of(devices, token)
					midi_refused = -1
					choosing_midi = true
				}
			}
		case .Save, .Open_Archive, .Escape, .Search, .Other:
		// Save, Z and / apply only in the navigator; Escape and Other are ignored.
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
	if name, loaded := client_patch_load_file(client, trimmed); loaded {
		delete(name) // the daemon names the patch now, through patch.current
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

// Z: prompt for a zip archive path and open it in the daemon, replacing the
// archive open there for every front-end. A blank answer or Escape keeps the
// archive as it is; forgetting it is the settings screen's blank edit.
@(private)
tui_open_archive :: proc(client: ^Client, theme: Theme) -> bool {
	terminal_clear()
	path, ok := prompt_line(1, "Open archive (zip, blank to keep): ", theme)
	trimmed := strings.trim_space(path)
	if !ok || len(trimmed) == 0 { return false }
	_, opened := client_archive_open(client, trimmed)
	return opened
}

// Re-read which patch the daemon is playing and where it came from. A failed
// read leaves the last answer: a dropped connection is the footer's to report,
// and the names come back with the next good read.
tui_read_provenance :: proc(client: ^Client, prov: ^Provenance) -> bool {
	p, ok := client_provenance(client)
	if !ok { return false }
	provenance_free(prov)
	prov^ = p
	return true
}

// Bring the navigator's lists up to what the daemon holds: the ordinary bank
// when bank_rev has moved past the one it was read at, the archive when
// archive_rev has, both when `force`. A list that cannot be read keeps the
// last good one.
tui_sync_navigator :: proc(client: ^Client, nav: ^Navigator, prov: Provenance, force := false) {
	if force || nav.seen_bank_rev != prov.bank_rev {
		if slots, label, ok := client_bank_list(client); ok {
			client_bank_free(nav.slots)
			delete(nav.label)
			nav.slots, nav.label = slots, label
			nav.seen_bank_rev = prov.bank_rev
		}
	}
	if force || nav.seen_archive_rev != prov.archive_rev {
		if state, ok := client_archive_current(client); ok {
			names: []string
			if state.open {
				got: bool
				names, got = client_archive_names(client, "archive.banks")
				if !got {
					archive_state_free(&state)
					return
				}
			}
			archive_state_free(&nav.archive)
			client_names_free(nav.bank_names)
			nav.archive, nav.bank_names = state, names
			nav.seen_archive_rev = state.rev
			if nav_follow(nav) { tui_read_archive_patches(client, nav) }
		}
	}
	nav_move(nav, 0)
}

@(private)
tui_read_archive_patches :: proc(client: ^Client, nav: ^Navigator) -> bool {
	names, ok := client_archive_names(client, "archive.patches")
	if !ok { return false }
	client_names_free(nav.patch_names)
	nav.patch_names = names
	nav_move(nav, 0)
	return true
}

// Enter at the banks: into `bank`'s patches. An archive bank is opened in the
// daemon, where every peer browsing the archive sees it; the sound and where
// it came from stay as they were.
tui_browse_bank :: proc(client: ^Client, nav: ^Navigator, bank: int, prov: Provenance) -> bool {
	browsed := bank
	if bank != ORDINARY {
		if _, ok := client_archive_bank(client, bank); !ok { return false }
		tui_sync_navigator(client, nav, prov, true)
		// A peer may have opened another bank between those two requests:
		// show the bank the daemon has open, never one bank's name over
		// another's patches.
		browsed = nav.archive.bank
		if browsed < 0 || !tui_read_archive_patches(client, nav) { return false }
	}
	nav_descend(nav, browsed, prov)
	return true
}

// Enter at a bank's patches: load the one under the cursor from the bank
// listed. An archive load names that bank, so it is the patch this list shows
// even when a peer has opened another bank since the list was read.
tui_load_cursor :: proc(client: ^Client, nav: ^Navigator) -> bool {
	if nav.level != .Patches || !nav_selected(nav) { return false }
	if nav.browsing == ORDINARY {
		// Only a filled slot; an empty one is a place to save, not load.
		s := nav.slots[nav.cursor]
		return s.filled && client_patch_load(client, s.slot)
	}
	return client_archive_load(client, nav.cursor, nav.browsing)
}

// Re-read the name of the MIDI input the daemon listens to. Unlike the patch
// names, a failed read clears it: a daemon that cannot answer midi.current
// has no selection to name, and the last one seen may not hold any more.
@(private)
tui_read_midi :: proc(client: ^Client, current_midi: ^string) {
	selected, name, _, ok := client_midi_current(client)
	delete(selected)
	delete(current_midi^)
	current_midi^ = ok ? name : ""
}

// Re-read the token the daemon listens to for the MIDI screen's (*) mark, so
// a peer's change shows while the screen is open. Only the token: a fresh
// list could move rows under the cursor, so re-scanning stays R's. A refused
// or failed read keeps the last answer; a drop is the loop's to report.
tui_refresh_midi_selected :: proc(client: ^Client, selected: ^string) -> bool {
	token, name, _, ok := client_midi_current(client)
	delete(name)
	if !ok { return false }
	delete(selected^)
	selected^ = token
	return true
}

// Legacy: before the daemon kept the archive path, this front-end kept it in
// config.conf. It is handed to a daemon that remembers none, and leaves
// config.conf only once the daemon has taken it, so a path that does not open
// now is not lost.
tui_migrate_archive :: proc(client: ^Client, config: ^Config) {
	if !tui_hand_over_archive(client, config.archive_path) { return }
	tui_drop_legacy_archive(client, config)
}

// Whether the daemon took `legacy` as its archive. Never over a path the
// daemon already has: that is a choice made since, in some front-end.
tui_hand_over_archive :: proc(client: ^Client, legacy: string) -> bool {
	if legacy == "" { return false }
	return client_archive_adopt(client, legacy)
}

// Edit one remembered setting from the settings screen. The archive path is
// the daemon's: a path opens that archive there for every front-end, and a
// blank one closes it and forgets it, so no start reopens it. Setting the bank
// path saves it here and loads that bank now, so the change takes effect at
// once.
@(private)
tui_edit_setting :: proc(client: ^Client, config: ^Config, field: int, theme: Theme) {
	terminal_clear()
	if field == 0 {
		path, ok := prompt_line(1, "Zip archive path (blank to forget): ", theme)
		if !ok {
			return
		}
		tui_set_archive(client, config, path)
	} else {
		path, ok := prompt_line(1, "User bank path: ", theme)
		if !ok {
			return
		}
		trimmed := strings.trim_space(path)
		if config_save(Config{bank_path = trimmed}) {
			delete(config.bank_path)
			config.bank_path = strings.clone(trimmed)
			if trimmed != "" { client_bank_load_file(client, trimmed) }
		} else {
			client_set_notice(client, "cannot save config.conf")
		}
	}
}

// Apply the settings edit only after the daemon accepts it. In particular,
// a persistence refusal must not discard a pending legacy path here.
tui_set_archive :: proc(client: ^Client, config: ^Config, path: string) -> bool {
	trimmed := strings.trim_space(path)
	done := false
	if trimmed == "" {
		done = client_archive_close(client)
	} else {
		_, done = client_archive_open(client, trimmed)
	}
	// A path still in config.conf would be handed over again the next time
	// the daemon remembers none -- after a forget, too. With none there,
	// config.conf is not touched at all.
	if !done || config.archive_path == "" { return done }
	return tui_drop_legacy_archive(client, config)
}

// The daemon has accepted the path change. Keep the retry in memory too if
// removing it from disk fails, and tell the user rather than claim success.
@(private)
tui_drop_legacy_archive :: proc(client: ^Client, config: ^Config) -> bool {
	if !config_drop_archive() {
		client_set_notice(client, "archive changed; cannot update config.conf")
		return false
	}
	delete(config.archive_path)
	config.archive_path = ""
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
