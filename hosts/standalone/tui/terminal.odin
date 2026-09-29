package tui

import "core:fmt"
import "core:os"
import "core:sys/posix"

// The terminal seam: raw mode, the alternate screen, and cursor moves via plain
// ANSI escapes. No terminal framework -- a synth control surface does not need
// one, and the plan asks the rendering to stay dependency-free.

Terminal :: struct {
	original: posix.termios,
}

// Enter raw mode and the alternate screen buffer. The original terminal state is
// saved so terminal_leave can restore it exactly, including on an error path.
terminal_enter :: proc(term: ^Terminal) {
	posix.tcgetattr(posix.STDIN_FILENO, &term.original)
	raw := term.original
	// Read a key the instant it is pressed, and do not echo it: the UI draws
	// the effect of a key, not the key.
	raw.c_lflag -= {.ICANON, .ECHO}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	terminal_write("\x1b[?1049h\x1b[?25l") // alternate screen, hide cursor
}

terminal_leave :: proc(term: ^Terminal) {
	terminal_write("\x1b[?25h\x1b[?1049l") // show cursor, leave alternate screen
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &term.original)
}

terminal_write :: proc(s: string) {
	os.write_string(os.stdout, s)
}

terminal_clear :: proc() {
	terminal_write("\x1b[2J\x1b[H")
}

terminal_home :: proc() {
	terminal_write("\x1b[H")
}

terminal_move :: proc(row, col: int) {
	terminal_write(fmt.tprintf("\x1b[%d;%dH", row, col))
}
