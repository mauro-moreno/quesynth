package tui_tests

import "core:strings"
import "core:testing"

import tui "../../hosts/standalone/tui"

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
