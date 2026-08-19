package patchconv

// Convert between Synth1's `.sy1` and this project's JSON.
//
//   patchconv patch  <in.sy1>            <out.json>
//   patchconv bank   <directory>         <out.json>  ["Bank name"]
//   patchconv back   <in.json>           <out.sy1>
//
// The point of `bank` is that a directory of patches becomes one file that is
// readable, diffable and version-stamped. The point of `back` is that this
// format is not a trap: anything written here can be taken to Synth1 itself.
//
// A note on what should be converted. The factory banks under `patches/` are
// Synth1's own and are not this project's to redistribute in any format --
// re-encoding them as JSON does not change whose they are. This exists for
// patches of your own, and for taking a bank you have made somewhere else.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../../src/patch"

usage :: proc() -> ! {
	fmt.eprintln("usage:")
	fmt.eprintln("  patchconv patch <in.sy1>     <out.json>")
	fmt.eprintln("  patchconv bank  <directory>  <out.json> [\"Bank name\"]")
	fmt.eprintln("  patchconv back  <in.json>    <out.sy1>")
	os.exit(2)
}

read_sy1 :: proc(path: string) -> (patch.Patch, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %v: %v", path, err)
		return {}, false
	}
	// parse_sy1 borrows out of `data`, so it is deliberately not freed here:
	// the returned patch's name points into it.
	parsed, parse_err := patch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("cannot parse %v: %v", path, parse_err)
		return {}, false
	}
	return parsed, true
}

write_file :: proc(path, contents: string) -> bool {
	if err := os.write_entire_file(path, transmute([]u8)contents); err != nil {
		fmt.eprintfln("cannot write %v: %v", path, err)
		return false
	}
	return true
}

// `.sy1` is a list of `index,value` lines under a three-line header. Written
// back at the modern version, because that is what the values in a JSON patch
// mean: a file this project produced was never in the pre-1.07 format, and
// stamping it 105 would tell Synth1 to reinterpret five parameters.
write_sy1 :: proc(p: patch.Patch, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "Synth1 %v\r\n", strings.trim_space(p.name))
	fmt.sbprintf(&b, "color=%v\r\n", p.color == "" ? "default" : p.color)
	fmt.sbprintf(&b, "ver=%v\r\n", patch.SY1_BIPOLAR_VERSION)
	for i in 0 ..< patch.PARAMETER_COUNT {
		fmt.sbprintf(&b, "%v,%v\r\n", i, p.values[i])
	}
	return strings.to_string(b)
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 3 {
		usage()
	}
	command, input, output := args[0], args[1], args[2]

	switch command {
	case "patch":
		p, ok := read_sy1(input)
		if !ok {
			os.exit(1)
		}
		text := patch.write_patch_json(p)
		defer delete(text)
		if !write_file(output, text) {
			os.exit(1)
		}
		fmt.printfln("wrote %v (%q)", output, strings.trim_space(p.name))

	case "bank":
		handle, open_err := os.open(input)
		if open_err != nil {
			fmt.eprintfln("cannot open %v: %v", input, open_err)
			os.exit(1)
		}
		entries, read_err := os.read_dir(handle, -1, context.allocator)
		os.close(handle)
		if read_err != nil {
			fmt.eprintfln("cannot read %v: %v", input, read_err)
			os.exit(1)
		}

		paths: [dynamic]string
		defer delete(paths)
		for entry in entries {
			if strings.has_suffix(strings.to_lower(entry.name), ".sy1") {
				append(&paths, entry.fullpath)
			}
		}
		// Sorted, so a bank built twice from the same directory comes out
		// identical rather than in whatever order the filesystem answered in.
		slice.sort(paths[:])
		if len(paths) == 0 {
			fmt.eprintfln("no .sy1 files in %v", input)
			os.exit(1)
		}

		patches := make([]patch.Patch, len(paths))
		defer delete(patches)
		kept := 0
		for path in paths {
			p, ok := read_sy1(path)
			if !ok {
				continue
			}
			patches[kept] = p
			kept += 1
		}

		name := len(args) >= 4 ? args[3] : filepath.base(input)
		text := patch.write_bank_json(name, patches[:kept])
		defer delete(text)
		if !write_file(output, text) {
			os.exit(1)
		}
		fmt.printfln("wrote %v (%v patches, %q)", output, kept, name)

	case "back":
		data, err := os.read_entire_file(input, context.allocator)
		if err != nil {
			fmt.eprintfln("cannot read %v: %v", input, err)
			os.exit(1)
		}
		defer delete(data, context.allocator)
		p, json_err := patch.parse_patch_json(data)
		if json_err != .None {
			fmt.eprintfln("cannot read %v: %v", input, json_err)
			os.exit(1)
		}
		text := write_sy1(p)
		defer delete(text)
		if !write_file(output, text) {
			os.exit(1)
		}
		fmt.printfln("wrote %v (%q)", output, strings.trim_space(p.name))

	case:
		usage()
	}
}
