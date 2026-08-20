#+build windows
package panel

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

import "../../src/webview2"

// The panel, hosted in a web view, for any plugin format that wants one.
//
// This started inside hosts/vst3 and moved here when the CLAP build wanted the
// same interface. What differs between the two formats is how a host hands over
// a window and asks for a size -- IPlugView on one side, clap_plugin_gui on the
// other -- and that stays with each host. What does not differ is everything
// below: finding the panel on disk, starting the web view, and the protocol in
// ui/bridge.js.
//
// Sharing it is not tidiness. This project has already been bitten twice by two
// implementations of one protocol drifting apart: the VST3 editor was missing
// the `state` message for a while, so stepping the bank repainted the panel and
// changed no sound, while the browser build -- which had always handled it --
// was fine. A second copy of this for CLAP would be the same wager taken again.

// Big enough that no section starts out scrolled.
WIDTH :: i32(1180)
HEIGHT :: i32(720)

// The folder in ui/ is mapped to this name so the page loads over https with a
// real origin. A `.invalid` domain can never resolve on the public internet,
// which is the point: nothing here should ever reach the network.
CONTENT_HOST :: "synth.invalid"
START_URL :: "https://synth.invalid/index.html"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: win.wstring, phModule: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: win.DWORD(0x00000004)
GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: win.DWORD(0x00000002)

// What the panel needs from whatever is hosting it.
//
// A struct of procedures rather than an interface: there are two callers, they
// are both plugins, and the alternative is generics over something that is not
// a type.
Host :: struct {
	user:        rawptr,

	// How many parameters there are, and how to read them.
	param_count: int,
	read_values: proc(user: rawptr, out: []i32),

	// The panel moved one parameter.
	set_param:   proc(user: rawptr, index: int, stored: i32),
	// The panel loaded a whole patch. One call rather than ninety-nine: a host
	// that rebound per parameter would be audible as a smear.
	set_state:   proc(user: rawptr, values: []i32),
	// The edges of a gesture, so a host can record automation for the drag
	// rather than for the samples it happened to see.
	edit:        proc(user: rawptr, index: int, begin: bool),

	note:        proc(user: rawptr, on: bool, note: int, velocity: f32),
	bend:        proc(user: rawptr, amount: f32),
	control:     proc(user: rawptr, cc: int, value: f32),
	volume:      proc(user: rawptr, amount: f32),

	// The panel's bank changed -- a patch written into a slot, a bank
	// loaded from a file. The text is a whole quesynth.bank document, and
	// is handed over as text rather than as something parsed so that what
	// is written to disk is exactly what the panel produced. The panel's
	// writer and src/patch's reader already agree; re-encoding it in the
	// middle would be a third implementation to keep in step.
	// `save` separates the two questions this message answers. The bank is
	// always adopted -- a plugin selecting patches out of a bank the panel
	// is not showing means one program number is two sounds -- but only the
	// panel's own bank is written to disk. A bank somebody opened from a
	// .zip or a folder is already on disk under its own name, and browsing
	// one should not overwrite what they had saved.
	set_bank:    proc(user: rawptr, text: string, save: bool),
	// The bank the host holds, as a quesynth.bank document. Borrowed from
	// the temporary allocator: it is written into one message and not kept.
	read_bank:   proc(user: rawptr) -> string,
}

Panel :: struct {
	view:   webview2.View,
	host:   Host,
	width:  i32,
	height: i32,
	open:   bool,
	ctx:    runtime.Context,
}

// -- where the plugin lives --------------------------------------------------

// The directory holding this DLL.
//
// Found from the address of a procedure in this module rather than from the
// process, because the process is the DAW and its directory is not ours. This
// is what makes a bundle relocatable: nothing is looked up by absolute path or
// by an environment variable a host may not have set.
//
// The result borrows from the temporary allocator and must not be freed.
// `filepath.dir` does not allocate -- it returns a slice of the path handed to
// it -- so deleting the result would free a pointer into the temp arena through
// the heap allocator, which is a crash and not a leak.
module_dir :: proc() -> (string, bool) {
	module: win.HMODULE
	flags := GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT
	if !GetModuleHandleExW(flags, win.wstring(rawptr(module_dir)), &module) {
		return "", false
	}

	buffer: [win.MAX_PATH_WIDE]u16
	length := win.GetModuleFileNameW(module, &buffer[0], win.MAX_PATH_WIDE)
	if length == 0 || int(length) >= len(buffer) {
		return "", false
	}

	path, err := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length), context.temp_allocator)
	if err != nil {
		return "", false
	}
	return filepath.dir(path), true
}

// WebView2 needs somewhere writable of its own. Under the user's local app data
// rather than beside the plugin: a bundle in Program Files is not writable, and
// a browser profile is per-user anyway.
user_data_dir :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", allocator)
	if local == "" {
		return strings.clone(".", allocator)
	}
	joined, err := filepath.join({local, "Quesynth", "WebView2"}, allocator)
	if err != nil {
		return strings.clone(".", allocator)
	}
	return joined
}

// Find the loader and the panel, wherever this format puts them.
//
// `candidates` are tried in order, relative to the module's own directory, and
// the first that exists wins. The two formats lay themselves out differently --
// a VST3 is a bundle with Contents/Resources, a CLAP on Windows is one file with
// a folder beside it -- and neither should have to know about the other's shape.
//
// The loader is looked for first and beside the binary in both. Loading it
// before anything is allocated means a machine with no WebView2 costs nothing
// and simply has no editor, which is the documented behaviour rather than a
// failure.
find_content :: proc(candidates: []string) -> (content: string, ok: bool) {
	dir, found := module_dir()
	if !found {
		return "", false
	}

	loader, loader_err := filepath.join({dir, "WebView2Loader.dll"}, context.temp_allocator)
	if loader_err != nil || !webview2.load(loader) {
		return "", false
	}

	for candidate in candidates {
		path, err := filepath.join({dir, candidate})
		if err != nil {
			continue
		}
		if os.exists(path) {
			return path, true
		}
		delete(path)
	}
	return "", false
}

// -- opening and closing -----------------------------------------------------

// Start the web view inside a window the host owns.
start :: proc(p: ^Panel, parent: rawptr) -> bool {
	if p == nil || p.open {
		return false
	}
	profile := user_data_dir(context.temp_allocator)

	p.view.parent = win.HWND(parent)
	p.view.bounds = win.RECT{0, 0, p.width, p.height}
	p.view.host_name = CONTENT_HOST
	p.view.start_url = START_URL
	p.view.on_message = on_message
	p.view.user = rawptr(p)

	if !webview2.create(&p.view, profile) {
		// No runtime, or the loader refused. The host keeps its window; it just
		// stays empty. Said plainly rather than pretended away.
		return false
	}
	p.open = true
	return true
}

stop :: proc(p: ^Panel) {
	if p == nil || !p.open {
		return
	}
	webview2.destroy(&p.view)
	p.open = false
	p.view.parent = nil
}

resize :: proc(p: ^Panel, width, height: i32) {
	if p == nil {
		return
	}
	p.width = width
	p.height = height
	if p.open {
		webview2.set_bounds(&p.view, win.RECT{0, 0, width, height})
	}
}

// -- messages from the panel -------------------------------------------------

// Everything the interface sends arrives here as one JSON object. The types are
// the ones listed at the top of ui/bridge.js.
on_message :: proc(user: rawptr, text: string) {
	p := (^Panel)(user)
	if p == nil || p.host.user == nil {
		return
	}
	h := &p.host

	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return
	}

	kind, has_kind := json_string(object, "type")
	if !has_kind {
		return
	}

	switch kind {
	case "sync":
		// The bank first, then the sound.
		//
		// The panel comes up showing the bank compiled into the page, which
		// in a plugin is only what a browser would have used -- the real one
		// is the file the host loaded. Sending it here replaces that copy
		// before anything is played, and sending it *before* the state
		// matters: loading a bank in the panel selects its first patch, which
		// would otherwise overwrite the sound this message is about to send.
		if h.read_bank != nil {
			send_bank(p, h.read_bank(h.user))
		}
		send_state(p)

	case "set":
		index, has_index := json_int(object, "index")
		stored, has_value := json_int(object, "value")
		if !has_index || !has_value || index < 0 || int(index) >= h.param_count {
			return
		}
		if h.set_param != nil {
			h.set_param(h.user, int(index), i32(stored))
		}

	case "state":
		// A whole patch at once: stepping the bank, or loading a file.
		//
		// This case was missing from the VST3 editor once, and the symptom was
		// oddly specific -- the panel showed the new patch and the sound did
		// not change. The panel repaints its own controls locally and only then
		// tells the host, so everything visible worked while nothing audible
		// did. It is handled in one place now, which is the point of this file.
		list, has_list := object["values"]
		if !has_list {
			return
		}
		array, is_array := list.(json.Array)
		if !is_array {
			return
		}
		count := min(len(array), h.param_count)
		values := make([]i32, count, context.temp_allocator)
		for i in 0 ..< count {
			stored, ok := json_value_int(array[i])
			if !ok {
				continue
			}
			values[i] = i32(stored)
		}
		if h.set_state != nil {
			h.set_state(h.user, values)
		}

	case "edit":
		index, has_index := json_int(object, "index")
		begin, has_begin := json_bool(object, "begin")
		if !has_index || !has_begin || index < 0 || int(index) >= h.param_count {
			return
		}
		if h.edit != nil {
			h.edit(h.user, int(index), begin)
		}

	case "note":
		note, has_note := json_int(object, "note")
		on, has_on := json_bool(object, "on")
		if !has_note || !has_on {
			return
		}
		velocity, has_velocity := json_int(object, "velocity")
		if !has_velocity {
			velocity = 100
		}
		if h.note != nil {
			h.note(h.user, on, int(note), f32(velocity) / 127.0)
		}

	case "wheel":
		which, has_which := json_string(object, "which")
		amount, has_amount := json_float(object, "value")
		if !has_which || !has_amount {
			return
		}
		if which == "pitch" {
			if h.bend != nil {
				h.bend(h.user, f32(amount))
			}
		} else if h.control != nil {
			// Controller 1, which is what parameters 86 and 88 name by default.
			h.control(h.user, 1, f32(amount * 127.0))
		}

	case "volume":
		amount, has_amount := json_float(object, "value")
		if !has_amount {
			return
		}
		if h.volume != nil {
			h.volume(h.user, f32(clamp(amount, 0, 1)))
		}

	case "bank":
		// A whole bank, as text. Only ever a few tens of kilobytes and only
		// when somebody writes a patch, so there is nothing to be clever
		// about here.
		text, has_text := json_string(object, "text")
		if !has_text || h.set_bank == nil {
			return
		}
		// Absent means no: a message without the flag is one from an older
		// panel, and adopting without saving is the safe half.
		save, _ := json_bool(object, "save")
		h.set_bank(h.user, text, save)

	case "cc":
		cc, has_cc := json_int(object, "cc")
		amount, has_amount := json_int(object, "value")
		if !has_cc || !has_amount {
			return
		}
		if h.control != nil {
			h.control(h.user, int(cc), f32(amount))
		}
	}
}

// -- messages to the panel ---------------------------------------------------

// The whole parameter set in one message, which is what the panel asks for when
// it loads. One message rather than ninety-nine because the panel rebuilds its
// controls from it in a single pass.
send_state :: proc(p: ^Panel) {
	if p == nil || p.host.read_values == nil || p.host.param_count <= 0 {
		return
	}
	values := make([]i32, p.host.param_count, context.temp_allocator)
	p.host.read_values(p.host.user, values)

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"state","values":[`)
	for v, i in values {
		if i > 0 {
			strings.write_byte(&builder, ',')
		}
		strings.write_int(&builder, int(v))
	}
	strings.write_string(&builder, `]}`)
	webview2.post(&p.view, strings.to_string(builder))
}

// One parameter that changed somewhere else -- an automation lane, or the
// host's own generic panel -- so the web view follows instead of going stale.
send_param :: proc(p: ^Panel, index: int, stored: i32) {
	if p == nil || !p.view.ready {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"param","index":`)
	strings.write_int(&builder, index)
	strings.write_string(&builder, `,"value":`)
	strings.write_int(&builder, int(stored))
	strings.write_byte(&builder, '}')
	webview2.post(&p.view, strings.to_string(builder))
}

// -- reading JSON ------------------------------------------------------------
//
// Small readers rather than a struct and a reflection pass: the messages have
// five shapes between them, and a missing field has to be distinguishable from
// a field that is present and zero.

json_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := value.(json.String)
	return string(text), is_string
}

// A number out of a bare JSON value.
//
// The helpers below are keyed by name, which is what every message here needs
// except one: the `state` message carries an array, and its elements have no
// keys to look up.
json_value_int :: proc(value: json.Value) -> (int, bool) {
	#partial switch v in value {
	case json.Integer:
		return int(v), true
	case json.Float:
		return int(v), true
	}
	return 0, false
}

json_float :: proc(object: json.Object, key: string) -> (f64, bool) {
	value, found := object[key]
	if !found {
		return 0, false
	}
	#partial switch v in value {
	case json.Float:
		return f64(v), true
	case json.Integer:
		return f64(v), true
	}
	return 0, false
}

json_int :: proc(object: json.Object, key: string) -> (i64, bool) {
	amount, ok := json_float(object, key)
	if !ok {
		return 0, false
	}
	return i64(amount), true
}

json_bool :: proc(object: json.Object, key: string) -> (bool, bool) {
	value, found := object[key]
	if !found {
		return false, false
	}
	flag, is_bool := value.(json.Boolean)
	return bool(flag), is_bool
}

// Which patch is loaded, by name and by number.
//
// Sent alongside the state after something other than the panel changes the
// sound -- a MIDI program change, most often. Without it every knob moves and
// the strip goes on naming the patch from before, which is the sort of half-lie
// that is worse than no update at all: the interface looks like it is telling
// you what you are playing.
//
// The protocol at the top of ui/bridge.js has always had this message; nothing
// on this side ever sent one.
send_patch :: proc(p: ^Panel, name: string, index: int, bank: string) {
	if p == nil || !p.view.ready {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"patch","name":`)
	write_json_string(&builder, name)
	strings.write_string(&builder, `,"index":`)
	strings.write_int(&builder, index)
	strings.write_string(&builder, `,"bank":`)
	write_json_string(&builder, bank)
	strings.write_byte(&builder, '}')
	webview2.post(&p.view, strings.to_string(builder))
}

// The bank the plugin holds, handed to the panel.
//
// Sent when the panel asks for state, because in a plugin the bank on disk
// is the real one and the copy compiled into the page is only what a browser
// would have used. Without this the panel would show the factory bank while
// a program change played something else -- which is what it did.
send_bank :: proc(p: ^Panel, text: string) {
	if p == nil || !p.view.ready || text == "" {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, `{"type":"bank","text":`)
	write_json_string(&builder, text)
	strings.write_byte(&builder, '}')
	webview2.post(&p.view, strings.to_string(builder))
}

// A JSON string, quoted and escaped.
//
// Patch names come out of somebody else's bank and are not this project's to
// vouch for: one containing a quote or a backslash would otherwise produce a
// message the panel cannot parse, and the symptom would be the name silently
// never updating for that one patch.
@(private = "file")
write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\r':
			strings.write_string(builder, `\r`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			// Control characters have to be escaped as well; everything else,
			// UTF-8 included, goes through as bytes.
			if c < 0x20 {
				strings.write_string(builder, `\u00`)
				// Odin will not index a constant string, so the digits are a
				// variable.
				hex := "0123456789abcdef"
				strings.write_byte(builder, hex[(c >> 4) & 0xF])
				strings.write_byte(builder, hex[c & 0xF])
			} else {
				strings.write_byte(builder, c)
			}
		}
	}
	strings.write_byte(builder, '"')
}
