package tui

import "core:fmt"
import "core:strings"

// The bank navigator: the ordinary bank and every bank of the open archive as
// one list of banks, each opened onto its patches. It replaced a slot browser
// and a separate archive browser that each had their own keys, their own idea
// of where they were, and no way to say which of them the playing sound came
// from.
//
// Two things are kept apart on purpose. What the navigator *browses* -- the
// bank it lists, and the cursor in it -- belongs to this screen and loads
// nothing. What is *playing* is the daemon's provenance, read from
// patch.current. A row is marked as playing only when it is the very patch the
// sound came from: same kind of bank, same bank, same index. A cursor is never
// a claim about the sound.
//
// What the archive has open is the daemon's, shared with every front-end.
// Entering an archive bank opens it in the daemon, so a peer browsing the
// archive follows, and this screen follows a peer's change the same way
// (nav_follow).
//
// Everything here is plain data and procedures over it, with no terminal and
// no socket, so the rules can be tested directly; tui.odin does the reading
// and render.odin the drawing.

// The browsed bank when it is the ordinary one. An archive bank is its index
// in archive.banks, so the Banks level's rows are simply bank + 1.
ORDINARY :: -1

Nav_Level :: enum {
	Banks,
	Patches,
}

Navigator :: struct {
	shown:            bool,
	// Opened before: B then returns to where it was left.
	used:             bool,
	level:            Nav_Level,
	// At the Patches level, the bank listed: ORDINARY or an archive bank.
	browsing:         int,
	cursor:           int,
	// The Banks row a patch list was entered from, so going back up lands on it.
	bank_row:         int,
	// The daemon's answers, as last read. All owned; nav_free releases them.
	slots:            []Bank_Slot,
	label:            string,
	archive:          Archive_State,
	bank_names:       []string,
	// The patches of the archive bank being browsed.
	patch_names:      []string,
	// The bank_rev and archive_rev the lists above were read at, so a tick
	// re-reads only what a peer -- or this client -- has since changed.
	seen_bank_rev:    uint,
	seen_archive_rev: uint,
	// The `/` search of the names listed. The cursor stays a row of the whole
	// list, so what Enter and S act on is that row's own slot, bank or patch.
	query:            [dynamic]u8,
	searching:        bool,
}

nav_free :: proc(nav: ^Navigator) {
	client_bank_free(nav.slots)
	delete(nav.label)
	archive_state_free(&nav.archive)
	client_names_free(nav.bank_names)
	client_names_free(nav.patch_names)
	delete(nav.query)
	nav^ = {archive = {bank = -1}}
}

// How many banks the Banks level lists: the ordinary one, then the archive's.
nav_bank_count :: proc(nav: ^Navigator) -> int {
	return 1 + (nav.archive.open ? len(nav.bank_names) : 0)
}

nav_row_bank :: proc(row: int) -> int {return row - 1}
nav_bank_row :: proc(bank: int) -> int {return bank + 1}

// How many rows the current level has.
nav_row_count :: proc(nav: ^Navigator) -> int {
	if nav.level == .Banks {return nav_bank_count(nav)}
	return nav.browsing == ORDINARY ? len(nav.slots) : len(nav.patch_names)
}

nav_filled :: proc(nav: ^Navigator) -> int {
	n := 0
	for s in nav.slots {
		if s.filled {n += 1}
	}
	return n
}

// Whether patch `index` of `bank` is the one the sound came from. index is a
// slot number in the ordinary bank and a patch index in an archive bank.
nav_playing :: proc(prov: Provenance, bank, index: int) -> bool {
	if bank == ORDINARY {
		return prov.source == .Bank && prov.slot >= 0 && prov.slot == index
	}
	return prov.source == .Archive && prov.archive_bank >= 0 && prov.archive_bank == bank && prov.archive_patch == index
}

// The bank the sound came from, as this navigator lists it: an archive bank
// while the archive it came from is still the one open, otherwise the ordinary
// bank, which is where a sound from no bank can be saved to.
nav_provenance_bank :: proc(nav: ^Navigator, prov: Provenance) -> int {
	if prov.source == .Archive && nav.archive.open && prov.archive_bank >= 0 && prov.archive_bank < len(nav.bank_names) {
		return prov.archive_bank
	}
	return ORDINARY
}

// Move among the rows shown. A cursor on a row the search has just hidden
// goes to the first row shown; with none shown it stays, and nav_selected is
// false.
nav_move :: proc(nav: ^Navigator, delta: int) {
	nav.cursor = clamp(nav.cursor, 0, max(nav_row_count(nav) - 1, 0))
	shown := nav_shown_rows(nav)
	if len(shown) == 0 {return}
	at := 0
	for row, i in shown {
		if row == nav.cursor {at = i}
	}
	nav.cursor = shown[clamp(at + delta, 0, len(shown) - 1)]
}

nav_row_name :: proc(nav: ^Navigator, row: int) -> string {
	switch {
	case nav.level == .Banks && row == 0:
		return nav.label
	case nav.level == .Banks:
		bank := nav_row_bank(row)
		return bank >= 0 && bank < len(nav.bank_names) ? nav.bank_names[bank] : ""
	case nav.browsing == ORDINARY:
		return row >= 0 && row < len(nav.slots) ? nav.slots[row].name : ""
	}
	return row >= 0 && row < len(nav.patch_names) ? nav.patch_names[row] : ""
}

// As in the browser's bank search, the query is trimmed and matched in any
// case, so a query of only spaces shows every row.
nav_filtering :: proc(nav: ^Navigator) -> bool {
	return strings.trim_space(string(nav.query[:])) != ""
}

nav_row_matches :: proc(nav: ^Navigator, row: int) -> bool {
	needle := strings.trim_space(string(nav.query[:]))
	if needle == "" {return true}
	name := strings.to_lower(nav_row_name(nav, row), context.temp_allocator)
	return strings.contains(name, strings.to_lower(needle, context.temp_allocator))
}

// Temp-allocated.
nav_shown_rows :: proc(nav: ^Navigator) -> []int {
	shown := make([dynamic]int, context.temp_allocator)
	for row in 0 ..< nav_row_count(nav) {
		if nav_row_matches(nav, row) {append(&shown, row)}
	}
	return shown[:]
}

nav_selected :: proc(nav: ^Navigator) -> bool {
	return nav.cursor >= 0 && nav.cursor < nav_row_count(nav) && nav_row_matches(nav, nav.cursor)
}

nav_search_clear :: proc(nav: ^Navigator) {
	clear(&nav.query)
	nav.searching = false
}

Search_Outcome :: enum {
	Typing,
	Done,
	Quit,
}

// What the terminal sent while the query is being typed, a whole read at a
// time so a paste arrives whole. Nothing typed here is a command: `q` or `s`
// is part of a name.
nav_search_input :: proc(nav: ^Navigator, input: []u8) -> Search_Outcome {
	for i := 0; i < len(input); i += 1 {
		ch := input[i]
		switch {
		case ch == 0x03:
			return .Quit
		case ch == 0x0d || ch == 0x0a:
			nav.searching = false
			if !nav_filtering(nav) {clear(&nav.query)}
			nav_move(nav, 0)
			return .Done
		case ch == 0x1b && i + 1 < len(input):
			if input[i + 1] != '[' {
				i += 1
				continue
			}
			i += 2
			for i < len(input) && (input[i] < 0x40 || input[i] > 0x7e) {i += 1}
			if i < len(input) && input[i] == 'A' {nav_move(nav, -1)}
			if i < len(input) && input[i] == 'B' {nav_move(nav, 1)}
		case ch == 0x1b:
			nav_search_clear(nav)
			nav_move(nav, 0)
			return .Done
		case ch == 0x15:
			clear(&nav.query)
			nav_move(nav, 0)
		case ch == 0x7f || ch == 0x08:
			n := len(nav.query)
			for n > 0 {
				n -= 1
				if nav.query[n] & 0xc0 != 0x80 {break}
			}
			resize(&nav.query, n)
			nav_move(nav, 0)
		case ch >= 0x20:
			append(&nav.query, ch)
			nav_move(nav, 0)
		}
	}
	return .Typing
}

// `/`: the search opens, and takes what the same read carried behind the
// slash as if it had come in a read of its own.
nav_search_start :: proc(nav: ^Navigator, typed: []u8) -> Search_Outcome {
	nav.searching = true
	return nav_search_input(nav, typed)
}

// Show the navigator. The first time it opens on the list of banks, on the
// bank the sound came from; after that it comes back where it was left. Call
// with the daemon's answers freshly read (tui_sync_navigator), so a bank a
// peer has moved or closed since is followed first.
nav_open :: proc(nav: ^Navigator, prov: Provenance) {
	nav.shown = true
	if !nav.used {
		nav.used = true
		nav.level = .Banks
		nav.cursor = nav_bank_row(nav_provenance_bank(nav, prov))
	}
	nav_move(nav, 0)
}

// Into a bank's patches. Lands on the patch that is playing when this bank
// holds it, so the sound's place in its bank is in view; otherwise at the top.
// A search was of the list left, so it goes.
nav_descend :: proc(nav: ^Navigator, bank: int, prov: Provenance) {
	nav_search_clear(nav)
	nav.bank_row = nav_bank_row(bank)
	nav.level = .Patches
	nav.browsing = bank
	nav.cursor = 0
	if bank == ORDINARY {
		for s, row in nav.slots {
			if nav_playing(prov, ORDINARY, s.slot) {nav.cursor = row}
		}
	} else {
		for _, row in nav.patch_names {
			if nav_playing(prov, bank, row) {nav.cursor = row}
		}
	}
}

// Esc: first drops a search, leaving the cursor where it is; then up from a
// bank's patches to the banks, on the bank just left; from the banks, away.
nav_escape :: proc(nav: ^Navigator) {
	if len(nav.query) > 0 {
		nav_search_clear(nav)
		nav_move(nav, 0)
		return
	}
	if nav.level == .Patches {
		nav.level = .Banks
		nav.cursor = nav.bank_row
		nav_move(nav, 0)
		return
	}
	nav.shown = false
}

// Line the view up with what the daemon has open, after nav.archive and the
// lists have been read again. Browsing an archive bank follows the daemon's
// open bank, whoever opened it; with no bank open, or no archive, it goes back
// up to the banks. Browsing the ordinary bank is left alone: the archive rows
// below it have changed, the bank it shows has not. A search goes with the
// list it was of. Returns whether the browsed archive bank's patch names must
// be read again.
nav_follow :: proc(nav: ^Navigator) -> (reread_patches: bool) {
	if nav.level == .Patches && nav.browsing != ORDINARY {
		a := nav.archive
		if !a.open || a.bank < 0 || a.bank >= len(nav.bank_names) {
			nav_search_clear(nav)
			nav.level = .Banks
			nav.cursor = nav.bank_row
		} else {
			if a.bank != nav.browsing {
				nav_search_clear(nav)
				nav.browsing = a.bank
				nav.bank_row = nav_bank_row(a.bank)
				nav.cursor = 0
			}
			reread_patches = true
		}
	}
	nav_move(nav, 0)
	return
}

// The synth screen's line for the sound: its name, the bank it came from, and
// where in that bank, so it reads the same whichever client loaded it.
provenance_line :: proc(prov: Provenance) -> string {
	line := prov.name == "" ? "patch: (unsaved)" : fmt.tprintf("patch: %s", prov.name)
	if prov.bank != "" {
		line = fmt.tprintf("%s   bank: %s", line, prov.bank)
	}
	if at := provenance_position(prov); at != "" {
		line = fmt.tprintf("%s   %s", line, at)
	}
	return line
}

// The navigator's footer line for the sound, beside what is being browsed.
playing_line :: proc(prov: Provenance) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "playing: ")
	strings.write_string(&b, prov.name == "" ? "(unsaved)" : prov.name)
	if prov.bank != "" {
		strings.write_string(&b, " | ")
		strings.write_string(&b, prov.bank)
	}
	if at := provenance_position(prov); at != "" {
		strings.write_string(&b, " | ")
		strings.write_string(&b, at)
	}
	return strings.to_string(b)
}

// Where in its bank the sound is: a slot, an archive patch, or nowhere (a
// file, a cleared identity, a slot of a bank since replaced, an archive since
// closed).
@(private)
provenance_position :: proc(prov: Provenance) -> string {
	switch prov.source {
	case .Bank:
		if prov.slot >= 0 {return fmt.tprintf("slot %d", prov.slot)}
	case .Archive:
		if prov.archive_patch >= 0 {return fmt.tprintf("archive #%d", prov.archive_patch)}
	case .None, .File:
	}
	return ""
}

// The text of row `row` at the Banks level.
nav_bank_text :: proc(nav: ^Navigator, row: int) -> string {
	if row == 0 {
		return fmt.tprintf("%s  %d/%d", nav.label, nav_filled(nav), len(nav.slots))
	}
	bank := nav_row_bank(row)
	if bank < 0 || bank >= len(nav.bank_names) {return ""}
	return fmt.tprintf("%4d  %s", bank, nav.bank_names[bank])
}

// The Banks level's line about the archive when none is open: the one the
// daemon remembers but could not open, or how to open one.
nav_archive_hint :: proc(nav: ^Navigator) -> string {
	if nav.archive.open {return ""}
	if nav.archive.path != "" {
		return fmt.tprintf("archive not open: %s   Z opens another", nav.archive.path)
	}
	return "no archive   Z opens one"
}

// A scrolling window over `count` rows that keeps `selected` in view.
list_window :: proc(selected, count, window: int) -> (start, end: int) {
	start = clamp(selected - window + 1, 0, max(count - window, 0))
	end = min(count, start + window)
	return
}
