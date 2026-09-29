package tui

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The colour theme for the terminal UI, and its config file.
//
// The palette ships as Catppuccin Mocha, baked in so a fresh checkout is themed
// with no setup. On first run the daemon writes that palette to a config file the
// user can then edit; on every later run the file, if present, overrides the
// built-in defaults key by key. Colours are true-colour (24-bit) foreground
// escapes; a terminal that ignores them, or a user who sets NO_COLOR, gets the
// same layout in plain text.

Color :: struct {
	r, g, b: u8,
	set:     bool,
}

Theme :: struct {
	enabled:      bool,
	title:        Color,
	tab_active:   Color,
	tab_inactive: Color,
	selected:     Color,
	label:        Color,
	value:        Color,
	bar_fill:     Color,
	bar_empty:    Color,
	status:       Color,
	dim:          Color,
	warning:      Color,
}

// Catppuccin Mocha (https://catppuccin.com), the shipped default.
theme_defaults :: proc() -> Theme {
	return Theme {
		enabled      = true,
		title        = {0xcb, 0xa6, 0xf7, true}, // mauve
		tab_active   = {0xa6, 0xe3, 0xa1, true}, // green
		tab_inactive = {0x6c, 0x70, 0x86, true}, // overlay0
		selected     = {0xb4, 0xbe, 0xfe, true}, // lavender
		label        = {0xcd, 0xd6, 0xf4, true}, // text
		value        = {0xfa, 0xb3, 0x87, true}, // peach
		bar_fill     = {0x94, 0xe2, 0xd5, true}, // teal
		bar_empty    = {0x45, 0x47, 0x5a, true}, // surface1
		status       = {0xa6, 0xad, 0xc8, true}, // subtext0
		dim          = {0x58, 0x5b, 0x70, true}, // surface2
		warning      = {0xf3, 0x8b, 0xa8, true}, // red
	}
}

// The escape that selects `c` as the foreground colour. Temp-allocated; the run
// loop resets that allocator each frame.
color_fg :: proc(c: Color) -> string {
	return fmt.tprintf("\x1b[38;2;%d;%d;%dm", c.r, c.g, c.b)
}

// Wrap `s` in `c` and a reset. A no-op when the theme is off or the colour is
// unset, so every call site can paint unconditionally.
paint :: proc(t: Theme, c: Color, s: string) -> string {
	if !t.enabled || !c.set {
		return s
	}
	return fmt.tprintf("%s%s\x1b[0m", color_fg(c), s)
}

// Parse `#rrggbb` (or bare `rrggbb`). ok=false leaves the caller's value intact.
theme_parse_color :: proc(s: string) -> (Color, bool) {
	t := strings.trim_space(s)
	if len(t) == 7 && t[0] == '#' {
		t = t[1:]
	}
	if len(t) != 6 {
		return {}, false
	}
	r, r_ok := strconv.parse_u64_of_base(t[0:2], 16)
	g, g_ok := strconv.parse_u64_of_base(t[2:4], 16)
	b, b_ok := strconv.parse_u64_of_base(t[4:6], 16)
	if !r_ok || !g_ok || !b_ok {
		return {}, false
	}
	return Color{u8(r), u8(g), u8(b), true}, true
}

// Overlay `key = value` lines onto `base`. Unknown keys and malformed lines are
// ignored, so an old or hand-edited config never stops the UI from starting.
theme_parse :: proc(text: string, base: Theme) -> Theme {
	t := base
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		if key == "enabled" {
			t.enabled = val == "true" || val == "on" || val == "1"
			continue
		}
		color, ok := theme_parse_color(val)
		if !ok {
			continue
		}
		switch key {
		case "title":
			t.title = color
		case "tab_active":
			t.tab_active = color
		case "tab_inactive":
			t.tab_inactive = color
		case "selected":
			t.selected = color
		case "label":
			t.label = color
		case "value":
			t.value = color
		case "bar_fill":
			t.bar_fill = color
		case "bar_empty":
			t.bar_empty = color
		case "status":
			t.status = color
		case "dim":
			t.dim = color
		case "warning":
			t.warning = color
		}
	}
	return t
}

// The config path: $XDG_CONFIG_HOME/quesynth/theme.conf, or ~/.config/... .
theme_config_path :: proc(allocator := context.allocator) -> (string, bool) {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/quesynth/theme.conf", x, allocator = allocator), true
	}
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return fmt.aprintf("%s/.config/quesynth/theme.conf", h, allocator = allocator), true
	}
	return "", false
}

// Load the theme: Catppuccin Mocha, overlaid by the config file if it exists, or
// with that file written out the first time so the user has something to edit.
// NO_COLOR always wins, per https://no-color.org.
theme_load :: proc() -> Theme {
	t := theme_defaults()
	if path, ok := theme_config_path(context.temp_allocator); ok {
		if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
			t = theme_parse(string(data), t)
		} else {
			theme_write_default(path)
		}
	}
	if os.get_env("NO_COLOR", context.temp_allocator) != "" {
		t.enabled = false
	}
	return t
}

// Best-effort: create the config directory and write the default palette. Any
// failure is silent -- the built-in defaults still colour the UI.
@(private = "file")
theme_write_default :: proc(path: string) {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		make_directory_all(path[:slash])
	}
	_ = os.write_entire_file_from_string(path, THEME_DEFAULT_CONFIG)
}

// mkdir -p: create every missing component, ignoring "already exists". Silent on
// any other failure, which the caller treats as "no config file this run".
@(private = "file")
make_directory_all :: proc(dir: string) {
	for i in 1 ..< len(dir) {
		if dir[i] == '/' {
			os.make_directory(dir[:i])
		}
	}
	os.make_directory(dir)
}

THEME_DEFAULT_CONFIG :: `# Quesynth terminal UI theme -- Catppuccin Mocha.
# Colours are #rrggbb. Delete a line to fall back to its built-in default.
# Set "enabled = false" (or export NO_COLOR) for a plain, uncoloured UI.

enabled      = true
title        = #cba6f7
tab_active   = #a6e3a1
tab_inactive = #6c7086
selected     = #b4befe
label        = #cdd6f4
value        = #fab387
bar_fill     = #94e2d5
bar_empty    = #45475a
status       = #a6adc8
dim          = #585b70
warning      = #f38ba8
`
