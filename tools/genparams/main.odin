// genparams - generate the live Synth1 parameter table used by patch parsing.
//
// Inputs, all measured against the reference plugin and all read-only here:
//
//   docs/synth1-param-states.json   every parameter's real states, each with the
//                                   canonical normalised value the plugin reports
//                                   for it and the text it displays
//   docs/synth1-params.json         the plugin's own default for each parameter
//   docs/synth1-param-mapping.json  how a stored patch integer selects a state,
//                                   and what the plugin does with one that fits
//                                   no state (see tools/s1probe mapping)
//
// The generated table carries the canonical `norm` values verbatim. Nothing here
// reconstructs a normalised value arithmetically from a step count: the formula
// (n + 0.5) / state_count is wrong for ten parameters and wrong silently, which
// is the whole reason this generator was retargeted at the state tables.
// The previous input, a table of display-run counts, has been deleted: it
// undercounted states and is superseded by the inputs above.
package genparams

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

STATES_PATH :: "docs/synth1-param-states.json"
DEFAULT_PATH :: "docs/synth1-params.json"
MAPPING_PATH :: "docs/synth1-param-mapping.json"
OUTPUT_PATH :: "src/patch/params.odin"
LIVE_COUNT :: 99

// Continuous parameters (86..89) are not on the 0..127 state convention: the
// plugin reports (stored + 1) / 65536 for them. Measured, see
// docs/synth1-param-encoding.md.
CONTINUOUS_DENOMINATOR :: 65536

State :: struct {
	i:       int,
	norm:    f64,
	display: string,
}

States_Param :: struct {
	index:       int,
	name:        string,
	continuous:  bool,
	state_count: int,
	states:      []State,
}

States_File :: struct {
	params: []States_Param,
}

Default_Param :: struct {
	index:   int,
	default: f64,
}

Default_File :: struct {
	params: []Default_Param,
}

Mapping_Param :: struct {
	index:         int,
	continuous:    bool,
	display_keyed: bool,
	clamps:        bool,
	exact:         bool,
}

Mapping_File :: struct {
	params: []Mapping_Param,
}

read_json :: proc(path: string, dst: ^$T) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("genparams: read %q: %v", path, err)
		return false
	}
	defer delete(data)

	if err := json.unmarshal(data, dst); err != nil {
		fmt.eprintfln("genparams: parse %q: %v", path, err)
		return false
	}
	return true
}

// A display is a "plain integer" only in the strict sense: optional minus sign
// then digits, no leading plus and no leading zeros. This must agree exactly
// with the same test in src/patch and in tools/s1probe, because it decides
// whether a stored integer is matched against display text at all.
plain_integer :: proc(s: string) -> (value: int, ok: bool) {
	if len(s) == 0 {return 0, false}
	digits := s
	negative := false
	if s[0] == '-' {
		negative = true
		digits = s[1:]
	}
	if len(digits) == 0 {return 0, false}
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' {return 0, false}
	}
	if len(digits) > 1 && digits[0] == '0' {return 0, false}
	if negative && digits == "0" {return 0, false}
	return strconv.parse_int(s, 10)
}

// The grid the plugin reports for a state index, including indices past the
// table. The operation order is measured, not chosen: forming the reciprocal
// once and scaling both terms by it reproduces every out-of-range read-back,
// while dividing by the state count is one ulp out on several of them.
grid_norm :: proc(state, state_count: int) -> f32 {
	step := f32(1) / f32(state_count)
	return f32(state) * step + 0.5 * step
}

// The stored integer that reproduces the plugin's own default.
//
// Almost every default lands exactly on a state, so the state table answers it.
// Index 21 is the exception: its default sits one step above the top state, on
// the free-running grid, and the reference genuinely defaults there.
default_stored_value :: proc(p: ^States_Param, keyed, clamps: bool, want: f64) -> int {
	if p.continuous {
		return int(want * f64(CONTINUOUS_DENOMINATOR) + 0.5) - 1
	}

	best_state := 0
	best_error := abs(p.states[0].norm - want)
	for s in p.states {
		if e := abs(s.norm - want); e < best_error {
			best_error = e
			best_state = s.i
		}
	}
	// Half a grid step is the widest a genuine on-a-state default can miss by
	// once the recorded default has been rounded to six decimals.
	tolerance := 0.5 / f64(p.state_count)
	if best_error <= tolerance {
		if keyed {
			if d, ok := plain_integer(p.states[best_state].display); ok {
				return d
			}
		}
		return best_state
	}
	if clamps {
		// Nothing outside the table is reachable, so the nearest state stands.
		if keyed {
			if d, ok := plain_integer(p.states[best_state].display); ok {
				return d
			}
		}
		return best_state
	}
	// Off the table and free-running: invert the grid.
	offset := 0
	if keyed {
		if base, ok := plain_integer(p.states[0].display); ok {
			offset = -base
		}
	}
	state := int(want * f64(p.state_count) - 0.5 + 0.5)
	return state - offset
}

write_quoted :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 || c == 0x7f {
				fmt.sbprintf(b, "\\x%02x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

main :: proc() {
	states: States_File
	defaults: Default_File
	mapping: Mapping_File
	if !read_json(STATES_PATH, &states) ||
	   !read_json(DEFAULT_PATH, &defaults) ||
	   !read_json(MAPPING_PATH, &mapping) {
		os.exit(1)
	}
	if len(states.params) != LIVE_COUNT {
		fmt.eprintfln("genparams: expected %v state tables, got %v", LIVE_COUNT, len(states.params))
		os.exit(1)
	}

	by_index: [LIVE_COUNT]^States_Param
	seen_defaults: [LIVE_COUNT]bool
	seen_mapping: [LIVE_COUNT]bool
	wanted: [LIVE_COUNT]f64
	keyed: [LIVE_COUNT]bool
	clamps: [LIVE_COUNT]bool

	for &p in states.params {
		if p.index < 0 || p.index >= LIVE_COUNT || by_index[p.index] != nil {
			fmt.eprintfln("genparams: invalid or duplicate state index %v", p.index)
			os.exit(1)
		}
		if p.continuous {
			if len(p.states) != 0 {
				fmt.eprintfln("genparams: continuous parameter %v carries a state table", p.index)
				os.exit(1)
			}
		} else {
			if p.state_count <= 0 || len(p.states) != p.state_count {
				fmt.eprintfln("genparams: parameter %v has %v states but state_count %v",
					p.index, len(p.states), p.state_count)
				os.exit(1)
			}
			for s, k in p.states {
				if s.i != k {
					fmt.eprintfln("genparams: parameter %v state %v is out of order", p.index, k)
					os.exit(1)
				}
			}
		}
		by_index[p.index] = &p
	}
	for i in 0 ..< LIVE_COUNT {
		if by_index[i] == nil {
			fmt.eprintfln("genparams: missing state table for index %v", i)
			os.exit(1)
		}
	}

	for d in defaults.params {
		if d.index < 0 || d.index >= LIVE_COUNT {continue}
		if seen_defaults[d.index] {
			fmt.eprintfln("genparams: duplicate default index %v", d.index)
			os.exit(1)
		}
		seen_defaults[d.index] = true
		wanted[d.index] = d.default
	}
	for m in mapping.params {
		if m.index < 0 || m.index >= LIVE_COUNT {continue}
		if seen_mapping[m.index] {
			fmt.eprintfln("genparams: duplicate mapping index %v", m.index)
			os.exit(1)
		}
		if !m.exact {
			fmt.eprintfln("genparams: mapping for index %v is not an exact fit; re-run `s1probe mapping`", m.index)
			os.exit(1)
		}
		if m.continuous != by_index[m.index].continuous {
			fmt.eprintfln("genparams: mapping and state table disagree about index %v being continuous", m.index)
			os.exit(1)
		}
		seen_mapping[m.index] = true
		keyed[m.index] = m.display_keyed
		clamps[m.index] = m.clamps
	}
	for i in 0 ..< LIVE_COUNT {
		if !seen_defaults[i] {
			fmt.eprintfln("genparams: missing default for index %v", i)
			os.exit(1)
		}
		if !seen_mapping[i] {
			fmt.eprintfln("genparams: missing mapping for index %v", i)
			os.exit(1)
		}
	}

	// Report where the measured mapping and the resolution order written in
	// docs/synth1-param-encoding.md disagree, so a divergence is auditable in
	// the build log instead of silently baked into the table.
	for i in 0 ..< LIVE_COUNT {
		p := by_index[i]
		if p.continuous {continue}
		documented := true
		for s in p.states {
			if _, ok := plain_integer(s.display); !ok {
				documented = false
				break
			}
		}
		if documented != keyed[i] {
			fmt.printfln("mapping differs from the documented rule order: index %v (%v) has %v displays but is measured %v",
				i, p.name,
				documented ? "plain-integer" : "non-integer",
				keyed[i] ? "display-keyed" : "a direct state index")
		}
	}

	total_states := 0
	for i in 0 ..< LIVE_COUNT {
		total_states += len(by_index[i].states)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "// Code generated by tools/genparams; do not edit.\n")
	strings.write_string(&b, "// Inputs: docs/synth1-param-states.json, docs/synth1-params.json,\n")
	strings.write_string(&b, "//         docs/synth1-param-mapping.json\n")
	strings.write_string(&b, "//\n")
	strings.write_string(&b, "// Every `norm` below is the canonical value the reference plugin reports for\n")
	strings.write_string(&b, "// that state, copied verbatim from the measured table. Do not recompute one\n")
	strings.write_string(&b, "// from a step count: (n + 0.5) / state_count disagrees with the plugin for\n")
	strings.write_string(&b, "// indices 14, 38, 40, 41, 42, 46, 47, 64, 71 and 93.\n")
	strings.write_string(&b, "package patch\n\n")

	strings.write_string(&b, "Parameter_State :: struct {\n\tnorm:    f32,\n\tdisplay: string,\n}\n\n")
	strings.write_string(&b, "// What the plugin does with a stored integer that selects no state.\n")
	strings.write_string(&b, "Out_Of_Range :: enum u8 {\n")
	strings.write_string(&b, "\t// Saturate at the top state, at both ends.\n\tClamp_To_Top,\n")
	strings.write_string(&b, "\t// Keep walking the uniform grid, which runs past 1.0.\n\tContinue_Grid,\n")
	strings.write_string(&b, "}\n\n")
	strings.write_string(&b, "Parameter :: struct {\n")
	strings.write_string(&b, "\tname:          string,\n")
	strings.write_string(&b, "\t// The stored integer that reproduces the plugin's own default.\n")
	strings.write_string(&b, "\tdefault:       int,\n")
	strings.write_string(&b, "\t// 86..89 read back (stored + 1) / CONTINUOUS_DENOMINATOR and have no states.\n")
	strings.write_string(&b, "\tcontinuous:    bool,\n")
	strings.write_string(&b, "\t// True when the stored integer selects the state whose display equals it,\n")
	strings.write_string(&b, "\t// false when it is a direct state index. Measured, not inferred.\n")
	strings.write_string(&b, "\tdisplay_keyed: bool,\n")
	strings.write_string(&b, "\tout_of_range:  Out_Of_Range,\n")
	strings.write_string(&b, "\tstate_offset:  int,\n")
	strings.write_string(&b, "\t// Length of this parameter's slice of PARAMETER_STATES; zero when continuous.\n")
	strings.write_string(&b, "\tstate_count:   int,\n")
	strings.write_string(&b, "}\n\n")
	fmt.sbprintf(&b, "PARAMETER_COUNT :: %v\n", LIVE_COUNT)
	fmt.sbprintf(&b, "PARAMETER_STATE_COUNT :: %v\n", total_states)
	fmt.sbprintf(&b, "CONTINUOUS_DENOMINATOR :: %v\n\n", CONTINUOUS_DENOMINATOR)

	strings.write_string(&b, "PARAMETER_STATES: [PARAMETER_STATE_COUNT]Parameter_State = {\n")
	offsets: [LIVE_COUNT]int
	cursor := 0
	first := true
	for i in 0 ..< LIVE_COUNT {
		p := by_index[i]
		offsets[i] = cursor
		for s in p.states {
			if !first {strings.write_string(&b, ",\n")}
			first = false
			fmt.sbprintf(&b, "\t{{%v, ", f32(s.norm))
			write_quoted(&b, s.display)
			strings.write_string(&b, "}")
			cursor += 1
		}
	}
	strings.write_string(&b, "\n}\n\n")

	strings.write_string(&b, "PARAMETERS: [PARAMETER_COUNT]Parameter = {\n")
	for i in 0 ..< LIVE_COUNT {
		p := by_index[i]
		value := default_stored_value(p, keyed[i], clamps[i], wanted[i])
		mode := clamps[i] ? "Clamp_To_Top" : "Continue_Grid"
		if i > 0 {strings.write_string(&b, ",\n")}
		strings.write_string(&b, "\t{")
		write_quoted(&b, p.name)
		fmt.sbprintf(&b, ", %v, %v, %v, .%v, %v, %v}",
			value, p.continuous, keyed[i], mode, offsets[i], len(p.states))
	}
	strings.write_string(&b, "\n}\n")

	if err := os.write_entire_file(OUTPUT_PATH, transmute([]byte)strings.to_string(b)); err != nil {
		fmt.eprintfln("genparams: write %q: %v", OUTPUT_PATH, err)
		os.exit(1)
	}

	fmt.printfln("generated %v parameters and %v states in %v", LIVE_COUNT, total_states, OUTPUT_PATH)
}
