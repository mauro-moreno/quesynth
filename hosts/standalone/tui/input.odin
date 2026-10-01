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
	Archive,
	Config,
	Midi,
	Open_Archive,
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
	case 'a', 'A':
		return .Archive
	case 'c', 'C':
		return .Config
	case 'm', 'M':
		return .Midi
	case 'z', 'Z':
		return .Open_Archive
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
