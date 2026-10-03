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
// how much one read takes.
read_key :: proc(buf: []u8) -> (key: Key, rest: []u8) {
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	return decode_key(buf[:max(int(n), 0)])
}

// The key a read began with. Arrow keys arrive as a three-byte escape burst
// (ESC [ A..D); a single read returns the whole burst, so decoding does not
// need to reassemble it across reads. No bytes at all is a closed stdin, which
// reads as Quit so the loop always terminates. A burst decodes to its first key
// only, except behind `/`: a paste, or text typed faster than the loop turns,
// comes in the read that carries the `/`, and what follows it is the start of
// the search that `/` opens, so it comes back as `rest`. That can end inside an
// escape sequence, which the search finishes (nav_search_input).
decode_key :: proc(input: []u8) -> (key: Key, rest: []u8) {
	if len(input) == 0 {
		return .Quit, nil
	}
	if input[0] == 0x1b {
		if len(input) >= 3 && input[1] == '[' {
			switch input[2] {
			case 'A':
				return .Up, nil
			case 'B':
				return .Down, nil
			case 'C':
				return .Right, nil
			case 'D':
				return .Left, nil
			}
		}
		return len(input) == 1 ? .Escape : .Other, nil
	}
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
read_key_timeout :: proc(timeout_ms: int, buf: []u8) -> (key: Key, rest: []u8) {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	n := posix.poll(&fds[0], 1, c.int(timeout_ms))
	if n <= 0 {
		return .Tick, nil
	}
	if fds[0].revents & {.HUP, .ERR, .NVAL} != {} { return .Quit, nil }
	if .IN not_in fds[0].revents {
		return .Tick, nil
	}
	return read_key(buf)
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
