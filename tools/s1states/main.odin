// Emit the reference plugin's authoritative per-parameter state table as JSON.
// For every parameter, sweep setParameter across 0..1 and record each distinct
// getParameter read-back state together with its display string. Synth1 snaps
// read-back to the canonical value of the selected state, so this enumerates
// exactly the states the plugin can be in.
package s1probe

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

DLL :: "C:/Users/lamag/Code/synth/ext/synth1/Synth1/Synth1 VST64.dll"
OUT :: "C:/Users/lamag/Code/synth/docs/synth1-param-states.json"

host_cb :: proc "c" (e: ^AEffect, opcode: i32, index: i32, value: int, ptr: rawptr, opt: f32) -> int {
	switch HostOp(opcode) {
	case .Version:                return 2400
	case .GetSampleRate:          return 48000
	case .GetBlockSize:           return 512
	case .GetCurrentProcessLevel: return 2
	case .GetLanguage:            return 1
	case .CanDo:                  return 1
	case .CurrentId, .Automate, .Idle, .PinConnected, .WantMidi, .GetTime,
	     .ProcessEvents, .TempoAt, .SizeWindow, .GetInputLatency, .GetOutputLatency,
	     .GetAutomationState, .GetVendorString, .GetProductString, .GetVendorVersion,
	     .UpdateDisplay, .BeginEdit, .EndEdit:
		return 0
	}
	return 0
}

buf_str :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {n += 1}
	return strings.clone(string(b[:n]))
}

esc :: proc(s: string, b: ^strings.Builder) {
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case:
			if c < 0x20 || c > 0x7e {
				strings.write_string(b, fmt.tprintf("\\u%04x", u32(c)))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
}

main :: proc() {
	mod := win.LoadLibraryW(win.utf8_to_wstring(DLL))
	entry := cast(VstEntry)win.GetProcAddress(mod, "VSTPluginMain")
	e := entry(host_cb)
	e.dispatcher(e, i32(Op.Open), 0, 0, nil, 0)
	e.dispatcher(e, i32(Op.SetSampleRate), 0, 0, nil, 48000.0)
	e.dispatcher(e, i32(Op.SetBlockSize), 0, 512, nil, 0)

	LAST_LIVE :: 98
	SWEEP :: 16384

	jb := strings.builder_make()
	strings.write_string(&jb, "{\n")
	strings.write_string(&jb, "  \"_method\": \"For each parameter, setParameter was swept over 0..1 in 16385 steps and getParameter read back. Synth1 snaps read-back to the canonical normalised value of the selected state, so the distinct read-back values enumerate the parameter's real states. 'norm' is the canonical value to send to setParameter to select that state.\",\n")
	strings.write_string(&jb, "  \"params\": [\n")

	for i in i32(0) ..= LAST_LIVE {
		nb: [512]u8
		e.dispatcher(e, i32(Op.GetParamName), i, 0, &nb[0], 0)
		name := buf_str(nb[:])
		if name == "" {name = "polyphony"}

		norms: [dynamic]f32
		disps: [dynamic]string
		defer delete(norms)
		defer delete(disps)
		prev := f32(-1)
		for k in 0 ..= SWEEP {
			v := f32(k) / f32(SWEEP)
			e.set_parameter(e, i, v)
			r := e.get_parameter(e, i)
			if k == 0 || r != prev {
				db: [512]u8
				e.dispatcher(e, i32(Op.GetParamDisplay), i, 0, &db[0], 0)
				append(&norms, r)
				append(&disps, buf_str(db[:]))
				prev = r
			}
		}
		// Parameters with thousands of states are effectively continuous.
		continuous := len(norms) > 1024

		if i > 0 {strings.write_string(&jb, ",\n")}
		fmt.sbprintf(&jb, "    {{\"index\": %v, \"name\": \"", i)
		esc(name, &jb)
		fmt.sbprintf(&jb, "\", \"continuous\": %v, \"state_count\": %v", continuous, len(norms))
		if continuous {
			strings.write_string(&jb, ", \"states\": []}")
		} else {
			strings.write_string(&jb, ", \"states\": [")
			for k in 0 ..< len(norms) {
				if k > 0 {strings.write_string(&jb, ", ")}
				fmt.sbprintf(&jb, "{{\"i\": %v, \"norm\": %.9f, \"display\": \"", k, norms[k])
				esc(disps[k], &jb)
				strings.write_string(&jb, "\"}")
			}
			strings.write_string(&jb, "]}")
		}
		fmt.printfln("%3v %-24v states=%-6v continuous=%v", i, name, len(norms), continuous)
	}
	strings.write_string(&jb, "\n  ]\n}\n")
	ok := os.write_entire_file(OUT, transmute([]u8)strings.to_string(jb))
	fmt.eprintfln("wrote %v (ok=%v)", OUT, ok == nil)
	e.dispatcher(e, i32(Op.Close), 0, 0, nil, 0)
}
