package tui_tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import tui "../../hosts/standalone/tui"

// The browser panel's colour tokens, read from ui/style.css itself: `--name:
// #rrggbb;` declarations, and the warn colour, which the sheet only ever names
// with its fallback, `var(--warn, #rrggbb)`.
@(private = "file")
browser_token :: proc(t: ^testing.T, name: string, loc := #caller_location) -> tui.Color {
	data, err := os.read_entire_file("ui/style.css", context.temp_allocator)
	if !testing.expect(t, err == nil, "cannot read ui/style.css", loc = loc) {return {}}
	css := string(data)
	for needle in ([2]string{fmt.tprintf("%s: ", name), fmt.tprintf("var(%s, ", name)}) {
		if at := strings.index(css, needle); at >= 0 {
			c, ok := tui.theme_parse_color(css[at + len(needle):][:7])
			if testing.expectf(t, ok, "%s is not #rrggbb in ui/style.css", name, loc = loc) {return c}
			return {}
		}
	}
	testing.expectf(t, false, "ui/style.css has no %s", name, loc = loc)
	return {}
}

// Each theme key and the browser token it takes its colour from.
@(private = "file")
Theme_Key :: struct {
	key:   string,
	token: string,
	color: proc(th: tui.Theme) -> tui.Color,
	text:  bool,
}

@(private = "file")
THEME_KEYS := []Theme_Key {
	{"title", "--ink", proc(th: tui.Theme) -> tui.Color {return th.title}, true},
	{"tab_active", "--accent", proc(th: tui.Theme) -> tui.Color {return th.tab_active}, true},
	{"tab_inactive", "--ink-faint", proc(th: tui.Theme) -> tui.Color {return th.tab_inactive}, true},
	{"selected", "--accent", proc(th: tui.Theme) -> tui.Color {return th.selected}, true},
	{"label", "--ink-dim", proc(th: tui.Theme) -> tui.Color {return th.label}, true},
	{"value", "--ink", proc(th: tui.Theme) -> tui.Color {return th.value}, true},
	{"bar_fill", "--accent", proc(th: tui.Theme) -> tui.Color {return th.bar_fill}, true},
	{"bar_empty", "--metal-dark", proc(th: tui.Theme) -> tui.Color {return th.bar_empty}, false},
	{"status", "--ink-dim", proc(th: tui.Theme) -> tui.Color {return th.status}, true},
	{"dim", "--ink-faint", proc(th: tui.Theme) -> tui.Color {return th.dim}, true},
	{"warning", "--warn", proc(th: tui.Theme) -> tui.Color {return th.warning}, true},
}

@(test)
test_theme_defaults_are_the_browser_panels_palette :: proc(t: ^testing.T) {
	defaults := tui.theme_defaults()
	testing.expect(t, defaults.enabled)
	// The file written on first run says the same as the built-in defaults,
	// key by key: parsed over a theme with nothing set, every key is there.
	written := tui.theme_parse(tui.THEME_DEFAULT_CONFIG, tui.Theme{})
	testing.expect(t, written.enabled)
	for k in THEME_KEYS {
		want := browser_token(t, k.token)
		testing.expectf(t, k.color(defaults) == want, "%s is %v, not %s %v", k.key, k.color(defaults), k.token, want)
		testing.expectf(t, k.color(written) == want, "the default file's %s is %v, not %s %v", k.key, k.color(written), k.token, want)
	}
}

// WCAG 2 relative luminance and contrast ratio.
@(private = "file")
luminance :: proc(c: tui.Color) -> f64 {
	channel :: proc(v: u8) -> f64 {
		s := f64(v) / 255
		return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

@(private = "file")
contrast :: proc(a, b: tui.Color) -> f64 {
	la, lb := luminance(a), luminance(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// Every colour text is drawn in reads at WCAG's 4.5:1 against the browser's
// panel, the floor ui/style.css holds its own ink tiers to.
@(test)
test_theme_default_text_colours_are_readable_on_the_panel :: proc(t: ^testing.T) {
	panel := browser_token(t, "--panel")
	defaults := tui.theme_defaults()
	for k in THEME_KEYS {
		if !k.text {continue}
		ratio := contrast(k.color(defaults), panel)
		testing.expectf(t, ratio >= 4.5, "%s is %.2f:1 against --panel", k.key, ratio)
	}
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<unreadable>"
}

// The theme.conf earlier versions wrote on first run, Catppuccin Mocha.
@(private = "file")
OLD_DEFAULT_CONFIG :: `# Quesynth terminal UI theme -- Catppuccin Mocha.
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

// theme.conf: a missing one is written with the defaults. One that is there
// is the user's, whatever it says -- the old default palette included -- so
// it is read and never rewritten, and wins key by key over the defaults.
@(test)
test_theme_file_is_written_when_missing_and_otherwise_overrides :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/quesynth-tui-theme-%d", posix.getpid())
	defer os.remove_all(root)
	path := fmt.tprintf("%s/nested/quesynth/theme.conf", root)
	defaults := tui.theme_defaults()

	missing := tui.theme_load_file(path)
	testing.expect(t, missing == defaults)
	testing.expect_value(t, read_text(path), tui.THEME_DEFAULT_CONFIG)
	testing.expect(t, tui.theme_load_file(path) == defaults)

	mauve, _ := tui.theme_parse_color("#cba6f7")
	peach, _ := tui.theme_parse_color("#fab387")
	mine, _ := tui.theme_parse_color("#123456")
	kept := []string {OLD_DEFAULT_CONFIG, "value = #123456\n", "enabled = false\r\n"}
	for text, i in kept {
		testing.expect(t, os.write_entire_file_from_string(path, text) == nil)
		th := tui.theme_load_file(path)
		testing.expect_value(t, read_text(path), text)
		switch i {
		case 0:
			testing.expect_value(t, th.title, mauve)
			testing.expect_value(t, th.value, peach)
			testing.expect(t, th.enabled)
		case 1:
			testing.expect_value(t, th.value, mine)
			testing.expect_value(t, th.title, defaults.title)
			testing.expect(t, th.enabled)
		case 2:
			testing.expect(t, !th.enabled)
			testing.expect_value(t, th.title, defaults.title)
		}
	}
}

@(test)
test_theme_parse_color_accepts_hex_forms :: proc(t: ^testing.T) {
	hash, ok1 := tui.theme_parse_color("#cba6f7")
	testing.expect(t, ok1)
	testing.expect_value(t, hash.r, u8(0xcb))
	testing.expect_value(t, hash.g, u8(0xa6))
	testing.expect_value(t, hash.b, u8(0xf7))
	testing.expect(t, hash.set)

	bare, ok2 := tui.theme_parse_color("  a6e3a1  ")
	testing.expect(t, ok2)
	testing.expect_value(t, bare.g, u8(0xe3))

	_, bad1 := tui.theme_parse_color("#12345")
	testing.expect(t, !bad1)
	_, bad2 := tui.theme_parse_color("nothex!")
	testing.expect(t, !bad2)
}

@(test)
test_theme_parse_overlays_and_ignores_junk :: proc(t: ^testing.T) {
	base := tui.theme_defaults()
	config := `# a comment
title = #010203
bar_fill = #040506
not_a_key = #ffffff
garbage line with no equals
value =
enabled = false
`
	th := tui.theme_parse(config, base)

	// Recognised keys are overlaid.
	testing.expect_value(t, th.title.r, u8(0x01))
	testing.expect_value(t, th.title.g, u8(0x02))
	testing.expect_value(t, th.title.b, u8(0x03))
	testing.expect_value(t, th.bar_fill.r, u8(0x04))
	// A malformed value leaves the default intact.
	testing.expect_value(t, th.value.r, base.value.r)
	// enabled toggles off.
	testing.expect(t, !th.enabled)
}

@(test)
test_theme_paint_respects_enabled_and_set :: proc(t: ^testing.T) {
	on := tui.theme_defaults()
	painted := tui.paint(on, on.title, "X")
	testing.expect(t, strings.contains(painted, "\x1b[38;2;"))
	testing.expect(t, strings.has_suffix(painted, "\x1b[0m"))
	testing.expect(t, strings.contains(painted, "X"))

	// Colour off: identical bytes, no escapes -- proves the plain layout.
	off := on
	off.enabled = false
	testing.expect_value(t, tui.paint(off, off.title, "X"), "X")

	// An unset colour is never painted, even with colour on.
	testing.expect_value(t, tui.paint(on, tui.Color{}, "Y"), "Y")
}
