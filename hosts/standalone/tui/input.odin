package tui

import "core:c"
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
		return .Other
	}
	switch buf[0] {
	case 'q', 'Q', 0x03: // q or Ctrl-C
		return .Quit
	case 'r', 'R':
		return .Reset
	case 0x0d, 0x0a:
		return .Enter
	}
	return .Other
}
