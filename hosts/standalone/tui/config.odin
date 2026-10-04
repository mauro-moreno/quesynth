package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

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
			delete(c.archive_path)
			c.archive_path = strings.clone(val)
		case "bank":
			delete(c.bank_path)
			c.bank_path = strings.clone(val)
		}
	}
	return c
}

// Only the bank belongs to this front-end now. Leave the legacy archive and
// every unrelated byte alone; that path goes only after the daemon takes it.
config_save :: proc(c: Config) -> bool {
	return config_edit("bank", c.bank_path, false)
}

config_drop_archive :: proc() -> bool {
	return config_edit("archive", "", true)
}

@(private = "file")
config_edit :: proc(key, value: string, remove: bool) -> bool {
	path, ok := config_file_path(context.temp_allocator)
	if !ok { return false }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil && rerr != os.General_Error.Not_Exist { return false }
	text := string(data)
	// The loader uses the last duplicate. Edit that value, not earlier lines
	// the user may have kept as notes. Dropping archive removes every retry.
	last := -1
	for rest := text; len(rest) > 0; {
		start := len(text) - len(rest)
		raw := config_take_line(&rest)
		if config_key(raw) == key { last = start }
	}
	b := strings.builder_make(context.temp_allocator)
	for rest := text; len(rest) > 0; {
		start := len(text) - len(rest)
		raw := config_take_line(&rest)
		if config_key(raw) != key || (!remove && start != last) {
			strings.write_string(&b, raw)
			continue
		}
		if remove { continue }
		eq := strings.index_byte(raw, '=')
		begin := eq + 1
		for begin < len(raw) && (raw[begin] == ' ' || raw[begin] == '\t') { begin += 1 }
		end := len(strings.trim_right_space(raw))
		end = max(end, begin)
		strings.write_string(&b, raw[:begin])
		strings.write_string(&b, value)
		strings.write_string(&b, raw[end:])
	}
	if last < 0 && !remove && value != "" {
		if len(text) > 0 && text[len(text)-1] != '\n' { strings.write_byte(&b, '\n') }
		fmt.sbprintf(&b, "%s = %s\n", key, value)
	}
	after := strings.to_string(b)
	if after == text { return true }
	return config_write_atomic(path, after)
}

// Keep line terminators rather than split/rejoin, including CRLF and an
// unterminated last line.
@(private = "file")
config_take_line :: proc(rest: ^string) -> string {
	raw := rest^
	if nl := strings.index_byte(raw, '\n'); nl >= 0 { raw = raw[:nl+1] }
	rest^ = rest^[len(raw):]
	return raw
}

@(private = "file")
config_key :: proc(raw: string) -> string {
	line := strings.trim_space(raw)
	if len(line) == 0 || line[0] == '#' { return "" }
	if eq := strings.index_byte(line, '='); eq >= 0 { return strings.trim_space(line[:eq]) }
	return ""
}

// config.conf may be a link into a dotfiles checkout. Rename replaces whatever
// name it is given, so the link would be swapped for a plain file; follow it
// first and replace the file it points at. A dangling link resolves to the
// name it points at, which is then created. The cap is SYMLOOP_MAX's, so a
// loop ends in a refusal rather than a spin.
@(private = "file")
config_resolve :: proc(path: string) -> (string, bool) {
	path := path
	for _ in 0 ..< 40 {
		info, err := os.lstat(path, context.temp_allocator)
		if err == os.General_Error.Not_Exist { return path, true }
		if err != nil { return "", false }
		if info.type != .Symlink { return path, true }
		target, lerr := os.read_link(path, context.temp_allocator)
		if lerr != nil { return "", false }
		if len(target) > 0 && target[0] == '/' {
			path = target
		} else {
			path = strings.concatenate({path[:strings.last_index_byte(path, '/') + 1], target}, context.temp_allocator)
		}
	}
	return "", false
}

@(private = "file")
config_write_atomic :: proc(link, text: string) -> bool {
	path, resolved := config_resolve(link)
	if !resolved { return false }
	// core:os's Permissions hold only the nine rwx bits; the replaced file
	// keeps setuid, setgid and sticky as well. Its type bits are not a mode.
	st: posix.stat_t
	mode: posix.mode_t
	existing := posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK
	if existing {
		mode = st.st_mode & ~posix.S_IFMT
	} else if posix.errno() != .ENOENT {
		return false
	}
	slash := strings.last_index_byte(path, '/')
	dir := slash > 0 ? path[:slash] : "."
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist { return false }
	// Each TUI gets its own temporary file: another client must never truncate
	// one we are about to rename, or have already published.
	f, err := os.create_temp_file(dir, "config.conf.*.tmp")
	if err != nil { return false }
	tmp := strings.clone(os.name(f), context.temp_allocator)
	// Before any content, so a private file is never readable half way, and
	// again after it, because a write clears setuid and setgid.
	kept := !existing || posix.fchmod(posix.FD(os.fd(f)), mode) == .OK
	n, werr := os.write_string(f, text)
	kept = kept && (!existing || posix.fchmod(posix.FD(os.fd(f)), mode) == .OK)
	serr := os.sync(f)
	cerr := os.close(f)
	if !kept || werr != nil || n != len(text) || serr != nil || cerr != nil || os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}
