package tui

import "core:c"
import "core:strings"
import "core:sys/posix"

Key :: enum {
	Other,
	Up,
	Down,
	Left,
	Right,
	Enter,
	Reset,
	Quit,
	Tab,
	Tick,
	Bank,
	Save,
	Load_File,
	Load_Bank,
	Config,
	Midi,
	Open_Archive,
	Escape,
	Search,
}

// Read one key into buf, and with it what the read held behind a `/`. buf is
// the caller's, so that `rest` is still there when this returns; its length is
// how much one read takes. `held` is what the last read left of an escape
// sequence (decode_key).
read_key :: proc(buf: []u8, held: ^Search_Escape = nil) -> (key: Key, rest: []u8) {
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	got := buf[:max(int(n), 0)]
	return decode_key(got, held, held != nil && len(got) > 0 && input_waiting())
}

// The key a read began with. Arrow keys arrive as a three-byte escape burst
// (ESC [ A..D, or with parameters before the final byte, as Ctrl-Down's
// ESC [ 1 ; 5 B). No bytes at all is a closed stdin, which reads as Quit so the
// loop always terminates. A burst decodes to its first key only, except behind
// `/`: a paste, or text typed faster than the loop turns, comes in the read
// that carries the `/`, and what follows it is the start of the search that
// `/` opens, so it comes back as `rest`. That can end inside an escape
// sequence, which the search finishes (nav_search_input).
//
// A read can also end inside an escape sequence outside a search, or one that
// a search ended inside of can be left over: `held` carries it from one read
// to the next, so its final byte -- the B of Down -- is never read as a key of
// its own. An ESC [ is never a key by itself, so it is held whether or not the
// rest has come yet, until the next read or the refresh tick before it
// (key_timed_out). A lone ESC is held only while more_waiting says the
// terminal has sent more; otherwise it is the Esc key, as before.
decode_key :: proc(input: []u8, held: ^Search_Escape = nil, more_waiting := false) -> (key: Key, rest: []u8) {
	state := Search_Escape.None
	if held != nil {
		state = held^
		held^ = .None
	}
	if len(input) == 0 {
		return .Quit, nil
	}
	at := 0
	if state == .None && input[0] != 0x1b {
		key, rest = decode_byte(input)
		if key == .Search {return}
		at = 1
	} else {
		key = .Other
		if state == .None {
			state = .Esc
			at = 1
		}
		ended := false
		for !ended && at < len(input) {
			final: u8
			final, ended = escape_step(&state, input[at])
			at += 1
			if ended {key = escape_key(final)}
		}
		if !ended && state == .Esc && !(held != nil && more_waiting) {
			key = .Escape
		}
	}
	for ch in input[at:] {escape_step(&state, ch)}
	if held != nil && (more_waiting || state == .Csi || state == .Csi_Param) {held^ = state}
	return key, nil
}

@(private)
decode_byte :: proc(input: []u8) -> (key: Key, rest: []u8) {
	switch input[0] {
	case 'q', 'Q', 0x03: // q or Ctrl-C
		return .Quit, nil
	case 'r', 'R':
		return .Reset, nil
	case 'b', 'B':
		return .Bank, nil
	case 's', 'S':
		return .Save, nil
	case 'o', 'O':
		return .Load_File, nil
	case 'l', 'L':
		return .Load_Bank, nil
	case 'c', 'C':
		return .Config, nil
	case 'm', 'M':
		return .Midi, nil
	case 'z', 'Z':
		return .Open_Archive, nil
	case 0x0d, 0x0a:
		return .Enter, nil
	case 0x09:
		return .Tab, nil
	case '/':
		return .Search, input[1:]
	}
	return .Other, nil
}

// One byte of an escape sequence in progress. `ended` once the sequence is
// over: `final` is then a plain CSI's final byte; ESC when a second ESC shows
// the first was the Esc key on its own, the second starting another sequence;
// or 0 for an Alt key or a CSI with parameters, both ignored outside search.
escape_step :: proc(state: ^Search_Escape, ch: u8) -> (final: u8, ended: bool) {
	switch state^ {
	case .None:
		if ch == 0x1b {state^ = .Esc}
	case .Esc:
		switch ch {
		case '[':
			state^ = .Csi
		case 0x1b:
			return 0x1b, true
		case:
			state^ = .None
			return 0, true
		}
	case .Csi, .Csi_Param:
		if ch >= 0x40 && ch <= 0x7e {
			plain := state^ == .Csi
			state^ = .None
			return plain ? ch : 0, true
		}
		state^ = .Csi_Param
	}
	return 0, false
}

@(private)
escape_key :: proc(final: u8) -> Key {
	switch final {
	case 'A':
		return .Up
	case 'B':
		return .Down
	case 'C':
		return .Right
	case 'D':
		return .Left
	case 0x1b:
		return .Escape
	}
	return .Other
}

// Read a line of text from a prompt drawn at `row`, in raw mode. Returns the
// text on Enter, or ok=false on Escape. Printable ASCII is appended; Backspace
// deletes. The text is temp-allocated, valid until the run loop's next reset.
prompt_line :: proc(row: int, label: string, theme: Theme) -> (string, bool) {
	buf: [dynamic]u8
	defer delete(buf)
	for {
		terminal_move(row, 2)
		terminal_write(paint(theme, theme.status, label))
		terminal_write(string(buf[:]))
		terminal_write("\x1b[K")
		b: [64]u8
		n := posix.read(posix.STDIN_FILENO, raw_data(b[:]), c.size_t(len(b)))
		if n <= 0 {
			return "", false
		}
		// Consume every byte the read returned, so a pasted or fast-typed path is
		// not truncated to its first character.
		for i in 0 ..< int(n) {
			ch := b[i]
			switch {
			case ch == 0x1b:
				return "", false
			case ch == 0x0d || ch == 0x0a:
				return strings.clone(string(buf[:]), context.temp_allocator), true
			case ch == 0x7f || ch == 0x08:
				if len(buf) > 0 {
					pop(&buf)
				}
			case ch >= 0x20 && ch < 0x7f:
				append(&buf, ch)
			}
		}
	}
}

// Read a key, or return Tick when none arrives within timeout_ms. That lets the
// UI refresh its metrics on a timer without a keypress, while still answering a
// key the instant it is pressed.
read_key_timeout :: proc(timeout_ms: int, buf: []u8, held: ^Search_Escape = nil) -> (key: Key, rest: []u8) {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	n := posix.poll(&fds[0], 1, c.int(timeout_ms))
	if n <= 0 {
		return held != nil ? key_timed_out(held) : .Tick, nil
	}
	if fds[0].revents & {.HUP, .ERR, .NVAL} != {} { return .Quit, nil }
	if .IN not_in fds[0].revents {
		return held != nil ? key_timed_out(held) : .Tick, nil
	}
	return read_key(buf, held)
}

// No read came to finish what `held` keeps: an ESC was the Esc key after all,
// and a sequence cut short is dropped.
key_timed_out :: proc(held: ^Search_Escape) -> Key {
	was := held^
	held^ = .None
	return was == .Esc ? .Escape : .Tick
}

// Whether the terminal has sent more than the last read took. Asked right after
// a read, so that an escape sequence the read ended inside is finished by the
// next one. A read that filled its buffer is no sign of more by itself: an Esc
// that was its last byte, with nothing behind it, would wait for the next tick.
input_waiting :: proc() -> bool {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	return posix.poll(&fds[0], 1, 0) > 0 && .IN in fds[0].revents
}

// Read what the terminal has sent, up to len(buf) bytes, within timeout_ms:
// the count read, 0 when nothing came, -1 once stdin is closed.
read_input_timeout :: proc(timeout_ms: int, buf: []u8) -> int {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	if posix.poll(&fds[0], 1, c.int(timeout_ms)) <= 0 {return 0}
	if fds[0].revents & {.HUP, .ERR, .NVAL} != {} {return -1}
	if .IN not_in fds[0].revents {return 0}
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	return n <= 0 ? -1 : int(n)
}
