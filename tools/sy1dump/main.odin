// sy1dump - parse every Synth1 text patch in a directory.
package sy1dump

import "core:fmt"
import "core:os"
import "core:strings"
import patch "../../src/patch"

usage :: proc() {
	fmt.eprintln("usage: sy1dump <directory>")
	os.exit(2)
}

main :: proc() {
	if len(os.args) != 2 {
		usage()
	}

	dir := os.args[1]
	entries, dir_err := os.read_directory_by_path(dir, -1, context.allocator)
	if dir_err != nil {
		fmt.eprintfln("sy1dump: cannot read %q: %v", dir, dir_err)
		os.exit(1)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	total := 0
	parsed := 0
	errors := 0
	for info in entries {
		if !strings.has_suffix(info.name, ".sy1") {
			continue
		}
		total += 1
		data, read_err := os.read_entire_file(info.fullpath, context.allocator)
		if read_err != nil {
			errors += 1
			fmt.printfln("%s: error reading: %v", info.name, read_err)
			continue
		}
		_, parse_err := patch.parse_sy1(data)
		delete(data, context.allocator)
		if parse_err != .None {
			errors += 1
			fmt.printfln("%s: error: %v", info.name, parse_err)
			continue
		}
		parsed += 1
		fmt.printfln("%s: ok", info.name)
	}

	fmt.printfln("parsed: %v/%v", parsed, total)
	fmt.printfln("errors: %v", errors)
	if errors != 0 {
		os.exit(1)
	}
}
