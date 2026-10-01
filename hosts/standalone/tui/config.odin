package tui

import "core:fmt"
import "core:os"
import "core:strings"

// The front-end's own remembered settings, kept beside the theme in the config
// directory: the user bank path, so a user's own bank can be reloaded without
// hunting for it. The zip archive path was kept here too until the daemon kept
// it for every front-end; an `archive =` line from before is handed to the
// daemon once (tui_migrate_archive) and stays here only until it takes it.

Config :: struct {
	archive_path: string,
	bank_path:    string,
}

config_free :: proc(c: ^Config) {
	delete(c.archive_path)
	delete(c.bank_path)
	c^ = {}
}

// $XDG_CONFIG_HOME/quesynth/config.conf, or ~/.config/quesynth/config.conf.
config_file_path :: proc(allocator := context.allocator) -> (string, bool) {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/quesynth/config.conf", x, allocator = allocator), true
	}
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return fmt.aprintf("%s/.config/quesynth/config.conf", h, allocator = allocator), true
	}
	return "", false
}

// Read the settings file. Missing keys and a missing file are not errors -- an
// empty config just means nothing has been remembered yet. Values are cloned.
config_load :: proc() -> Config {
	c: Config
	path, ok := config_file_path(context.temp_allocator)
	if !ok {
		return c
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return c
	}
	text := string(data)
	for raw in strings.split_lines_iterator(&text) {
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
		switch key {
		case "archive":
			c.archive_path = strings.clone(val)
		case "bank":
			c.bank_path = strings.clone(val)
		}
	}
	return c
}

// Write the settings back, best effort. A failure to write (an unwritable config
// directory) is silent: the setting still holds for this run, it just will not be
// remembered for the next.
config_save :: proc(c: Config) {
	path, ok := config_file_path(context.temp_allocator)
	if !ok {
		return
	}
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		make_directory_all_config(path[:slash])
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Quesynth front-end settings.\n")
	if c.archive_path != "" {
		fmt.sbprintf(&b, "archive = %s\n", c.archive_path)
	}
	if c.bank_path != "" {
		fmt.sbprintf(&b, "bank = %s\n", c.bank_path)
	}
	_ = os.write_entire_file_from_string(path, strings.to_string(b))
}

// Take the `archive =` lines out of the settings file once the daemon has the
// path, and leave every other byte as it is: the rest is the user's, not the
// hand-off's to rewrite. Best effort, as config_save is.
config_drop_archive :: proc() {
	path, ok := config_file_path(context.temp_allocator)
	if !ok {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	rest := string(data)
	for len(rest) > 0 {
		raw := rest
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			raw = rest[:nl + 1]
		}
		rest = rest[len(raw):]
		line := strings.trim_space(raw)
		eq := strings.index_byte(line, '=')
		if len(line) > 0 && line[0] != '#' && eq >= 0 && strings.trim_space(line[:eq]) == "archive" {
			continue
		}
		strings.write_string(&b, raw)
	}
	_ = os.write_entire_file_from_string(path, strings.to_string(b))
}

@(private = "file")
make_directory_all_config :: proc(dir: string) {
	for i in 1 ..< len(dir) {
		if dir[i] == '/' {
			os.make_directory(dir[:i])
		}
	}
	os.make_directory(dir)
}
