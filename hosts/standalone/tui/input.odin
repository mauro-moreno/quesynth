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
	Escape,
}

// Read one key. Arrow keys arrive as a three-byte escape burst (ESC [ A..D); a
// single read returns the whole burst, so decoding does not need to reassemble
// it across reads. A closed stdin reads as Quit so the loop always terminates.
read_key :: proc() -> Key {
	buf: [8]u8
	n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), c.size_t(len(buf)))
	if n <= 0 {
		return .Quit
	}
	if buf[0] == 0x1b {
		if int(n) >= 3 && buf[1] == '[' {
			switch buf[2] {
			case 'A':
				return .Up
			case 'B':
				return .Down
			case 'C':
				return .Right
			case 'D':
				return .Left
			}
		}
		return int(n) == 1 ? .Escape : .Other
	}
	switch buf[0] {
	case 'q', 'Q', 0x03: // q or Ctrl-C
		return .Quit
	case 'r', 'R':
		return .Reset
	case 'b', 'B':
		return .Bank
	case 's', 'S':
		return .Save
	case 'o', 'O':
		return .Load_File
	case 'l', 'L':
		return .Load_Bank
	case 0x0d, 0x0a:
		return .Enter
	case 0x09:
		return .Tab
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
		b: [8]u8
		n := posix.read(posix.STDIN_FILENO, raw_data(b[:]), c.size_t(len(b)))
		if n <= 0 {
			return "", false
		}
		switch {
		case b[0] == 0x1b:
			return "", false
		case b[0] == 0x0d || b[0] == 0x0a:
			return strings.clone(string(buf[:]), context.temp_allocator), true
		case b[0] == 0x7f || b[0] == 0x08:
			if len(buf) > 0 {
				pop(&buf)
			}
		case b[0] >= 0x20 && b[0] < 0x7f:
			append(&buf, b[0])
		}
	}
}

// Read a key, or return Tick when none arrives within timeout_ms. That lets the
// UI refresh its metrics on a timer without a keypress, while still answering a
// key the instant it is pressed.
read_key_timeout :: proc(timeout_ms: int) -> Key {
	fds := [1]posix.pollfd{{fd = posix.STDIN_FILENO, events = {.IN}}}
	n := posix.poll(&fds[0], 1, c.int(timeout_ms))
	if n <= 0 {
		return .Tick
	}
	if fds[0].revents & {.HUP, .ERR, .NVAL} != {} { return .Quit }
	if .IN not_in fds[0].revents {
		return .Tick
	}
	return read_key()
}
