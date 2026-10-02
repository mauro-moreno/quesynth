package mcp_tests

import "core:os"
import "core:strings"
import "core:testing"

// The MCP is a client and nothing more: it reaches the synth only through the
// control protocol. That is a property of its source, so it is read from its
// source -- every file of the package, every import line.

MCP_SOURCE :: #directory + "../../hosts/standalone/mcp"

ALLOWED_PROJECT_IMPORTS :: []string{"../../../src/control"}

@(test)
test_the_mcp_package_imports_only_core_and_the_control_protocol :: proc(t: ^testing.T) {
	files, err := os.read_all_directory_by_path(MCP_SOURCE, context.temp_allocator)
	testing.expect(t, err == nil)
	scanned := 0
	for file in files {
		if !strings.has_suffix(file.name, ".odin") { continue }
		scanned += 1
		bytes, read_err := os.read_entire_file(file.fullpath, context.temp_allocator)
		testing.expect(t, read_err == nil)
		for line in strings.split_lines(string(bytes), context.temp_allocator) {
			trimmed := strings.trim_space(line)
			if !strings.has_prefix(trimmed, "import ") { continue }
			open := strings.index_byte(trimmed, '"')
			close := strings.last_index_byte(trimmed, '"')
			testing.expectf(t, open >= 0 && close > open, "%s: cannot read %q", file.name, trimmed)
			path := trimmed[open + 1:close]
			allowed := strings.has_prefix(path, "core:")
			for project in ALLOWED_PROJECT_IMPORTS { allowed ||= path == project }
			testing.expectf(t, allowed, "%s imports %q", file.name, path)
			for forbidden in ([]string{"core:net", "core:c/libc", "core:os/os2", "core:sys/linux"}) {
				testing.expectf(t, path != forbidden, "%s imports %q", file.name, path)
			}
		}
	}
	testing.expect(t, scanned >= 2, "the package source was not found")
}

@(test)
test_the_mcp_package_names_no_synth_internals :: proc(t: ^testing.T) {
	files, _ := os.read_all_directory_by_path(MCP_SOURCE, context.temp_allocator)
	for file in files {
		if !strings.has_suffix(file.name, ".odin") { continue }
		bytes, _ := os.read_entire_file(file.fullpath, context.temp_allocator)
		text := string(bytes)
		for forbidden in ([]string{"src/engine", "src/registry", "src/patch", "src/dsp", "/tui", "standalone.", "registry_", "engine_"}) {
			testing.expectf(t, !strings.contains(text, forbidden), "%s mentions %q", file.name, forbidden)
		}
	}
}
