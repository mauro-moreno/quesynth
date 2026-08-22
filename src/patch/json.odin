package patch

// Patches and banks as JSON, so this project has a format of its own.
//
// The `.sy1` reader beside this file reads Synth1's format, which is the right
// thing for loading somebody's existing patches and the wrong thing to write.
// It carries a `ver=` field whose meaning changed in 2005 (see the note on
// `upgrade_pre_107`), it is keyed by parameter number with no names anywhere,
// and it is not ours to define. A bank of patches made *for* this instrument
// needs a format this project can version, read on any platform, and put in a
// repository as text a person can read and a diff can show.
//
//   {
//     "format": "quesynth.patch",
//     "version": 1,
//     "name": "Brass String",
//     "parameters": { "osc1 wave": 1, "filter freq": 74, ... }
//   }
//
// Four decisions, each of which could have gone the other way:
//
// **Keyed by name, not by index.** A parameter number means nothing without
// this repository open beside it, and the numbers are Synth1's rather than
// ours. The names are unique across all ninety-nine -- checked, not assumed --
// so they can key an object, and a patch file then says what it does. An index
// would also have quietly rotted if the table were ever extended in the middle.
//
// **Stored integers, not normalised floats.** This is the representation every
// other layer of the project already uses: `Patch.values`, the CLAP and VST3
// state chunks, and the wire format in ui/bridge.js all carry stored integers,
// for the reason bridge.js gives -- normalising loses the display-keyed
// parameters, whose stored integer is not their position. Writing floats here
// would put a lossy conversion in the one place that is meant to be lossless.
//
// **Every parameter, every time.** A sparse file listing only what differs from
// the default would be shorter and would depend on the default table to be
// read at all, which makes an old patch file mean something different after any
// change to the defaults. A complete file is self-contained.
//
// **Unknown names are an error, missing ones are not.** A file naming something
// this build has never heard of is either from a newer version or a typo, and
// silently ignoring it would load a patch that is not the patch. A file that
// omits a parameter gets that parameter's default, which is what lets version 1
// files survive a version 2 that adds one.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

PATCH_FORMAT :: "quesynth.patch"
BANK_FORMAT :: "quesynth.bank"
JSON_FORMAT_VERSION :: 1

Json_Error :: enum {
	None,
	Invalid_Json,
	Not_An_Object,
	Wrong_Format,
	Unsupported_Version,
	Unknown_Parameter,
	Bad_Value,
	No_Patches,
}

// The index of a parameter by name, or -1.
//
// Linear over ninety-nine entries, which is nothing against the file read that
// precedes it, and it keeps the table the single source of truth rather than
// introducing a map that could disagree with it.
parameter_index :: proc(name: string) -> int {
	for p, i in PARAMETERS {
		if p.name == name {
			return i
		}
	}
	return -1
}

// -- reading -----------------------------------------------------------------

json_number :: proc(value: json.Value) -> (int, bool) {
	#partial switch v in value {
	case json.Integer:
		return int(v), true
	case json.Float:
		// Accepted because a hand-edited file, or one written by a language
		// whose numbers are all doubles, will say 64.0 where it means 64.
		// Rejected when it is not whole, because a stored value between two
		// states is not a value this format can represent.
		whole := int(v)
		return whole, f64(whole) == f64(v)
	}
	return 0, false
}

// One patch out of a parsed object.
//
// The name is **cloned**, and the caller owns it. That is a real difference
// from `parse_sy1`, which borrows its name out of the buffer it was handed and
// requires that buffer to outlive the patch. Here the parsed JSON tree is
// destroyed before this returns, so borrowing would leave a dangling pointer.
// `destroy_patch` is the other half of it.
patch_from_object :: proc(
	object: json.Object,
	allocator := context.allocator,
) -> (
	p: Patch,
	err: Json_Error,
) {
	for i in 0 ..< PARAMETER_COUNT {
		p.values[i] = PARAMETERS[i].default
		p.present[i] = false
	}

	if name, ok := object["name"]; ok {
		if text, is_text := name.(json.String); is_text {
			p.name = strings.clone(string(text), allocator)
		}
	}

	// The version this format writes into every patch it produces. Kept on the
	// patch so `bind_patch` sees a modern one and never runs the pre-1.07
	// upgrade on a file that was never in that format.
	p.version = SY1_BIPOLAR_VERSION

	parameters, has_parameters := object["parameters"]
	if !has_parameters {
		return p, .None
	}
	table, is_table := parameters.(json.Object)
	if !is_table {
		return p, .Not_An_Object
	}

	for key, value in table {
		index := parameter_index(key)
		if index < 0 {
			return p, .Unknown_Parameter
		}
		stored, ok := json_number(value)
		if !ok {
			return p, .Bad_Value
		}
		p.values[index] = stored
		p.present[index] = true
	}
	return p, .None
}

// A single patch file.
parse_patch_json :: proc(data: []byte, allocator := context.allocator) -> (p: Patch, err: Json_Error) {
	value, parse_err := json.parse(data, allocator = allocator)
	// Before the check, not after it: json.parse allocates as it goes and
	// what it built before it gave up still has to go back.
	defer json.destroy_value(value, allocator)
	if parse_err != nil {
		return {}, .Invalid_Json
	}

	object, is_object := value.(json.Object)
	if !is_object {
		return {}, .Not_An_Object
	}
	if err := check_header(object, PATCH_FORMAT); err != .None {
		return {}, err
	}
	return patch_from_object(object, allocator)
}

check_header :: proc(object: json.Object, expected: string) -> Json_Error {
	format, has_format := object["format"]
	if !has_format {
		return .Wrong_Format
	}
	text, is_text := format.(json.String)
	if !is_text || string(text) != expected {
		return .Wrong_Format
	}
	if version, has_version := object["version"]; has_version {
		n, ok := json_number(version)
		if !ok || n > JSON_FORMAT_VERSION {
			return .Unsupported_Version
		}
	}
	return .None
}

Bank :: struct {
	name:    string,
	patches: []Patch,
	// Which slots actually held a sound in the file.
	//
	// A bank is a fixed row of slots and most of them are usually empty, so the
	// format writes an empty one as null rather than as a written-out Init
	// patch -- the file stays the size of what is in it, and, more importantly,
	// the ones after it keep their numbers. A reader that dropped nulls would
	// shift every later patch down by one and silently renumber the bank.
	//
	// The empty slots are materialised as Init patches, because that is what
	// they sound like and every caller wants to play them. This says which ones
	// they were, so a writer can put the nulls back.
	filled:  []bool,
}

// The sound an empty slot has: every parameter at its default.
//
// The name is not cloned, so it must not be freed with the rest of a parsed
// bank. destroy_bank knows this; see the note there about borrowed names.
init_patch :: proc() -> (p: Patch) {
	p.name = "Init"
	p.version = SY1_BIPOLAR_VERSION
	for i in 0 ..< PARAMETER_COUNT {
		p.values[i] = PARAMETERS[i].default
		p.present[i] = true
	}
	return
}

parse_bank_json :: proc(data: []byte, allocator := context.allocator) -> (bank: Bank, err: Json_Error) {
	value, parse_err := json.parse(data, allocator = allocator)
	// Before the check, not after it: json.parse allocates as it goes and
	// what it built before it gave up still has to go back.
	defer json.destroy_value(value, allocator)
	if parse_err != nil {
		return {}, .Invalid_Json
	}

	object, is_object := value.(json.Object)
	if !is_object {
		return {}, .Not_An_Object
	}
	if header_err := check_header(object, BANK_FORMAT); header_err != .None {
		return {}, header_err
	}

	if name, ok := object["name"]; ok {
		if text, is_text := name.(json.String); is_text {
			bank.name = strings.clone(string(text), allocator)
		}
	}

	// Everything below can fail, and a caller only destroys a bank it was
	// handed with .None -- which is the right rule and means the name has to
	// go back before any of those returns.
	failed := true
	defer if failed && bank.name != "" {
		delete(bank.name, allocator)
	}

	list, has_patches := object["patches"]
	if !has_patches {
		return {}, .No_Patches
	}
	array, is_array := list.(json.Array)
	if !is_array {
		return {}, .No_Patches
	}

	patches := make([]Patch, len(array), allocator)
	filled := make([]bool, len(array), allocator)
	for entry, i in array {
		// An empty slot. Filled with the defaults, which is the Init sound, and
		// recorded as empty above.
		if _, is_null := entry.(json.Null); is_null {
			patches[i] = init_patch()
			filled[i] = false
			continue
		}
		entry_object, entry_is_object := entry.(json.Object)
		if !entry_is_object {
			delete(patches, allocator)
			delete(filled, allocator)
			return {}, .Not_An_Object
		}
		p, patch_err := patch_from_object(entry_object, allocator)
		if patch_err != .None {
			delete(patches, allocator)
			delete(filled, allocator)
			return {}, patch_err
		}
		patches[i] = p
		filled[i] = true
	}
	bank.patches = patches
	bank.filled = filled
	failed = false
	return bank, .None
}

// -- writing -----------------------------------------------------------------
//
// Written by hand rather than through `json.marshal`, for one reason: key
// order. Marshalling a map gives whatever order the map iterates in, which
// changes between runs, and a file that reorders itself on every save produces
// a diff on every save. Emitted in parameter order, the file is stable and a
// change to one control shows as a change to one line.

json_escape :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\t':
			strings.write_string(b, "\\t")
		case '\r':
			strings.write_string(b, "\\r")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

write_patch_body :: proc(b: ^strings.Builder, p: Patch, indent: string) {
	fmt.sbprintf(b, "%v\"name\": ", indent)
	json_escape(b, strings.trim_space(p.name))
	// Braces go through write_string, never through a format string: Odin's
	// `fmt` reads `{` as the start of a directive and emits
	// "%!(MISSING CLOSE BRACE)" into the output instead of the brace.
	fmt.sbprintf(b, ",\n%v\"parameters\": ", indent)
	strings.write_string(b, "{\n")
	for i in 0 ..< PARAMETER_COUNT {
		fmt.sbprintf(b, "%v  ", indent)
		json_escape(b, PARAMETERS[i].name)
		fmt.sbprintf(b, ": %v", p.values[i])
		if i + 1 < PARAMETER_COUNT {
			strings.write_string(b, ",")
		}
		strings.write_string(b, "\n")
	}
	strings.write_string(b, indent)
	strings.write_string(b, "}\n")
}

write_patch_json :: proc(p: Patch, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"format\": \"%v\",\n  \"version\": %v,\n", PATCH_FORMAT, JSON_FORMAT_VERSION)
	write_patch_body(&b, p, "  ")
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// `filled` says which entries hold a sound. It may be nil, which means they
// all do -- that is what tools/factorybank hands in, and what every caller
// did before empty slots existed.
//
// An empty one is written as null rather than skipped, because position is
// meaning: a patch in slot 41 has to still be 41 after a round trip, and a
// reader that dropped the gaps would shift every later patch down by one.
write_bank_json :: proc(
	name: string,
	patches: []Patch,
	filled: []bool = nil,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"format\": \"%v\",\n  \"version\": %v,\n  \"name\": ", BANK_FORMAT, JSON_FORMAT_VERSION)
	json_escape(&b, name)
	strings.write_string(&b, ",\n  \"patches\": [\n")
	for p, i in patches {
		if filled != nil && i < len(filled) && !filled[i] {
			strings.write_string(&b, "    null")
		} else {
			strings.write_string(&b, "    {\n")
			write_patch_body(&b, p, "      ")
			strings.write_string(&b, "    }")
		}
		if i + 1 < len(patches) {
			strings.write_string(&b, ",")
		}
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "  ]\n}\n")
	return strings.to_string(b)
}

// -- ownership ---------------------------------------------------------------
//
// The JSON readers clone what they return, so they need a matching release.
// Nothing here is optional politeness: the test runner's memory tracker fails a
// build that leaks, which is how the first version of this file was caught
// cloning ninety-nine patch names and freeing none of them.
//
// A `Patch` read from `.sy1` must *not* be passed to these. Its name borrows out
// of the caller's file buffer, and freeing it would release memory this package
// never allocated.

destroy_patch :: proc(p: Patch, allocator := context.allocator) {
	if p.name != "" {
		delete(p.name, allocator)
	}
}

destroy_bank :: proc(bank: Bank, allocator := context.allocator) {
	for p, i in bank.patches {
		// An empty slot's patch was made by init_patch, whose name is a string
		// literal rather than a clone. Freeing it would hand the allocator a
		// pointer into static memory. `filled` is what tells the two apart, and
		// a bank with no `filled` at all -- one built by hand rather than
		// parsed -- is treated as all real, which is what it is.
		if bank.filled != nil && i < len(bank.filled) && !bank.filled[i] {
			continue
		}
		destroy_patch(p, allocator)
	}
	if bank.patches != nil {
		delete(bank.patches, allocator)
	}
	if bank.filled != nil {
		delete(bank.filled, allocator)
	}
	if bank.name != "" {
		delete(bank.name, allocator)
	}
}

// -- reading either format ---------------------------------------------------

// Which format a buffer holds, decided by looking at it rather than at a file
// name.
//
// Sniffed and not passed in, because the caller usually has a path and a path
// can lie: a patch saved from the interface and renamed to `.sy1` is still
// JSON, and refusing it on the strength of four characters would be a worse
// answer than reading it.
//
// It used to require the literal word "Synth1", which is the one thing a `.sy1`
// file does not reliably start with. Synth1's own factory bank names the patch
// on the first line with no prefix -- 127 of the 128 files in soundbank00 do --
// so the sniffer refused a hundred and twenty-seven patches that `parse_sy1`
// reads perfectly, and every host that goes through `parse_patch_any` reported
// them as unreadable. Two readers of one format disagreeing about what the
// format is, is worse than either being strict.
//
// So the two formats are told apart by what they *are*: JSON opens with a
// brace, and a `.sy1` is a short optional header over lines of
// `index,value`. Finding one of those records is the test, which is the same
// question `parse_sy1` asks and therefore cannot disagree with it.
//
// This package still touches no filesystem. Everything here takes bytes, which
// is what lets src/patch compile for the WebAssembly and mobile targets where
// there is no `core:os` worth having.
Patch_Format :: enum {
	Unknown,
	Sy1,
	Json,
}

// How far in to look for a record before giving up. A `.sy1` header is three
// lines at most, so anything beyond the fourth line is not this format.
SY1_SNIFF_LINES :: 6

detect_format :: proc(data: []byte) -> Patch_Format {
	i := 0
	for i < len(data) && (data[i] == ' ' || data[i] == '\t' || data[i] == '\r' || data[i] == '\n') {
		i += 1
	}
	if i >= len(data) {
		return .Unknown
	}
	if data[i] == '{' {
		return .Json
	}

	rest := data[i:]
	if len(rest) >= 6 && string(rest[:6]) == "Synth1" {
		return .Sy1
	}

	pos := i
	for line_number in 0 ..< SY1_SNIFF_LINES {
		if pos >= len(data) {
			break
		}
		line: []byte
		line, pos = line_end(data, pos)
		if has_prefix(line, "color=") || has_prefix(line, "ver=") || sy1_is_record(line) {
			return .Sy1
		}
	}
	return .Unknown
}

// Read a patch in whichever format it is in.
//
// `owned` says whether the name has to be freed: the JSON reader clones it and
// the `.sy1` reader borrows it out of `data`. Returned rather than hidden
// because getting it wrong is either a leak or a double free, and which one
// depends on a format the caller did not choose.
parse_patch_any :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	p: Patch,
	owned: bool,
	ok: bool,
) {
	switch detect_format(data) {
	case .Json:
		parsed, err := parse_patch_json(data, allocator)
		return parsed, true, err == .None
	case .Sy1:
		parsed, err := parse_sy1(data)
		return parsed, false, err == .None
	case .Unknown:
	}
	return {}, false, false
}
