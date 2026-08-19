// mapping - measure how Synth1's own loader turns a stored patch integer into a
// parameter value, and record it as docs/synth1-param-mapping.json.
//
//   s1probe mapping [dll]
//
// Why this exists
// ---------------
// docs/synth1-param-states.json says what states a parameter has. It cannot say
// which stored integer selects which state, and the two are genuinely
// independent: index 9 and index 21 both display plain signed integers, yet 9
// keys off the display text and 21 keys off the raw state index. Nor can it say
// what happens to a stored integer that lands outside the table: index 0
// saturates at its top state while index 33 keeps walking up the uniform grid
// past 1.0. Both facts are properties of the plugin, so both are measured here
// rather than guessed from the table's shape.
//
// Method: effGetChunk hands back Synth1's own state block, in which parameter i
// occupies a little-endian i32 at CHUNK_VALUE_BASE + i*CHUNK_VALUE_STRIDE.
// Writing one slot and handing the block back with effSetChunk runs Synth1's own
// restore path over that exact integer, so getParameter reports precisely what
// loading a .sy1 holding that integer would produce. Unlike setParameter, which
// saturates at 1.0, this reaches every value a patch file can store.
package s1probe

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import spatch "../../src/patch"

MAPPING_STATES_PATH :: "docs/synth1-param-states.json"
MAPPING_OUTPUT_PATH :: "docs/synth1-param-mapping.json"

// Layout of Synth1's state chunk, derived from the plugin itself with
// `s1probe chunkmap`: parameter i's stored integer is a little-endian i32 at
// CHUNK_VALUE_BASE + i*CHUNK_VALUE_STRIDE.
CHUNK_VALUE_BASE :: 572
CHUNK_VALUE_STRIDE :: 8

// The stored-integer window the mapping is fitted over. Factory patches use
// -24..127; the window is widened well past that so a rule that only happens to
// hold over the factory range cannot be mistaken for the real one.
MAPPING_PROBE_LO :: -30
MAPPING_PROBE_HI :: 135

// Continuous parameters read back (stored + 1) / 65536. Kept local because the
// mapping has to be measured before tools/genparams can emit the runtime copy
// of this constant into src/patch.
MAPPING_CONTINUOUS_DENOMINATOR :: 65536

Map_State :: struct {
	i:       int,
	norm:    f64,
	display: string,
}

Map_Param :: struct {
	index:       int,
	name:        string,
	continuous:  bool,
	state_count: int,
	states:      []Map_State,
}

Map_States_File :: struct {
	params: []Map_Param,
}

// A display is a "plain integer" only in the strict sense: an optional minus
// sign and digits, with no leading plus and no leading zeros. Synth1 renders
// index 2 as "00"/"+01" and index 3 as "+15 cent", and neither keys off its
// display text, so the strict form is what distinguishes a display-keyed
// parameter from one that is merely numeric-looking.
mapping_plain_integer :: proc(s: string) -> (value: int, ok: bool) {
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

// The grid Synth1 reports for a state index, including indices past the table.
// Measured operation order: a reciprocal is formed once and both terms are
// scaled by it. Dividing by the state count instead differs by one ulp on
// several values (index 33 stored 42 is the clearest case).
mapping_grid_norm :: proc(state, state_count: int) -> f32 {
	step := f32(1) / f32(state_count)
	return f32(state) * step + 0.5 * step
}

Mapping_Result :: struct {
	index:               int,
	continuous:          bool,
	display_keyed:       bool,
	clamps:              bool,
	// Exact over stored values 0..MAPPING_PROBE_HI, the domain a patch file
	// can put a parameter into.
	exact:               bool,
	deviations:          int,
	// Negative stored values that fall outside the state table read back one
	// ulp below the computed grid on three parameters. See
	// docs/synth1-param-encoding.md.
	negative_deviations: int,
}

// Read one stored integer back through Synth1's own loader.
mapping_probe :: proc(p: ^Plugin, work, pristine: []byte, param, value: int) -> f32 {
	copy(work, pristine)
	write_le_u32(work, CHUNK_VALUE_BASE + param * CHUNK_VALUE_STRIDE, u32(i32(value)))
	p.eff.dispatcher(p.eff, i32(Op.SetChunk), 0, len(work), raw_data(work), 0)
	return p.eff.get_parameter(p.eff, i32(param))
}

// Predict a read-back under one candidate rule, so the rule can be scored
// against the loader rather than assumed.
mapping_predict :: proc(mp: ^Map_Param, display_keyed, clamps: bool, value: int) -> f32 {
	n := mp.state_count
	state := value
	resolved := false

	if display_keyed {
		for s in mp.states {
			if d, ok := mapping_plain_integer(s.display); ok && d == value {
				state = s.i
				resolved = true
				break
			}
		}
	} else if value >= 0 && value < n {
		state = value
		resolved = true
	}
	if resolved {
		return f32(mp.states[state].norm)
	}
	if clamps {
		return f32(mp.states[n - 1].norm)
	}
	// Unresolved and free-running: the stored integer sits on the same uniform
	// grid the table does, offset so that the lowest display lands on state 0.
	offset := 0
	if display_keyed {
		if base, ok := mapping_plain_integer(mp.states[0].display); ok {
			offset = -base
		}
	}
	return mapping_grid_norm(value + offset, n)
}

cmd_mapping :: proc(dll: string) {
	raw, read_err := os.read_entire_file(MAPPING_STATES_PATH, context.allocator)
	if read_err != nil {
		fmt.eprintfln("mapping: cannot read %q: %v", MAPPING_STATES_PATH, read_err)
		os.exit(1)
	}
	defer delete(raw, context.allocator)

	states: Map_States_File
	if err := json.unmarshal(raw, &states); err != nil {
		fmt.eprintfln("mapping: cannot parse %q: %v", MAPPING_STATES_PATH, err)
		os.exit(1)
	}
	if len(states.params) != spatch.PARAMETER_COUNT {
		fmt.eprintfln("mapping: expected %v parameters, got %v",
			spatch.PARAMETER_COUNT, len(states.params))
		os.exit(1)
	}

	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)

	pristine := get_chunk_copy(&p, 0)
	if len(pristine) == 0 {
		fmt.eprintln("mapping: plugin returned an empty chunk")
		os.exit(1)
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	results := make([]Mapping_Result, spatch.PARAMETER_COUNT)
	defer delete(results)

	for &mp in states.params {
		if mp.index < 0 || mp.index >= spatch.PARAMETER_COUNT {
			fmt.eprintfln("mapping: parameter index %v out of range", mp.index)
			os.exit(1)
		}
		res := Mapping_Result{index = mp.index, continuous = mp.continuous}

		if mp.continuous {
			// Not on the 0..127 state convention at all: these read back a
			// 1/65536 grid. Confirm that rather than assume it.
			bad := 0
			negative_bad := 0
			for v in MAPPING_PROBE_LO ..= MAPPING_PROBE_HI {
				if mapping_probe(&p, work, pristine, mp.index, v) !=
					f32(v + 1) / f32(MAPPING_CONTINUOUS_DENOMINATOR) {
					if v < 0 {negative_bad += 1} else {bad += 1}
				}
			}
			res.exact = bad == 0
			res.deviations = bad
			res.negative_deviations = negative_bad
			results[mp.index] = res
			continue
		}

		if len(mp.states) != mp.state_count || mp.state_count <= 0 {
			fmt.eprintfln("mapping: parameter %v has an inconsistent state table", mp.index)
			os.exit(1)
		}

		// Rule 1 can only be in play when every display is a strict integer.
		keyed_possible := true
		for s in mp.states {
			if _, plain := mapping_plain_integer(s.display); !plain {
				keyed_possible = false
				break
			}
		}
		observed := make([]f32, MAPPING_PROBE_HI - MAPPING_PROBE_LO + 1)
		defer delete(observed)
		for v in MAPPING_PROBE_LO ..= MAPPING_PROBE_HI {
			observed[v - MAPPING_PROBE_LO] = mapping_probe(&p, work, pristine, mp.index, v)
		}

		// Candidate order matters only where the loader cannot tell two rules
		// apart. Ties go to the resolution order documented in
		// docs/synth1-param-encoding.md, so the generated table follows the
		// documentation wherever measurement is silent and the cross-check in
		// tools/genparams only fires on a real divergence.
		best_bad := max(int)
		for keyed in ([2]bool{true, false}) {
			if keyed && !keyed_possible {continue}
			for clamps in ([2]bool{false, true}) {
				bad := 0
				negative_bad := 0
				for v in MAPPING_PROBE_LO ..= MAPPING_PROBE_HI {
					if mapping_predict(&mp, keyed, clamps, v) != observed[v - MAPPING_PROBE_LO] {
						if v < 0 {negative_bad += 1} else {bad += 1}
					}
				}
				if bad < best_bad {
					best_bad = bad
					res.display_keyed = keyed
					res.clamps = clamps
					res.deviations = bad
					res.negative_deviations = negative_bad
				}
			}
		}
		res.exact = best_bad == 0
		results[mp.index] = res
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\n")
	strings.write_string(&b, "  \"_method\": \"Measured against Synth1 VST64.dll through effSetChunk, which runs the plugin's own state-restore path over a raw stored integer. For each parameter every candidate rule was scored over stored values ")
	fmt.sbprintf(&b, "%v..%v", MAPPING_PROBE_LO, MAPPING_PROBE_HI)
	strings.write_string(&b, " and scored. 'display_keyed' means the stored integer selects the state whose display equals it; otherwise the stored integer is a direct state index. 'clamps' means a stored integer the rule cannot place saturates at the top state; otherwise it keeps walking the uniform grid, which runs past 1.0. 'exact' covers stored 0..hi, the domain a patch file can put a parameter into; 'negative_deviations' counts negative stored values outside the state table, where three parameters read back one ulp below the computed grid. Regenerate with: s1probe mapping\",\n")
	strings.write_string(&b, "  \"params\": [\n")
	for r, i in results {
		if i > 0 {strings.write_string(&b, ",\n")}
		fmt.sbprintf(&b,
			"    {{\"index\": %v, \"continuous\": %v, \"display_keyed\": %v, \"clamps\": %v, \"exact\": %v, \"deviations\": %v, \"negative_deviations\": %v}}",
			r.index, r.continuous, r.display_keyed, r.clamps, r.exact, r.deviations, r.negative_deviations)
	}
	strings.write_string(&b, "\n  ]\n}\n")

	if err := os.write_entire_file(MAPPING_OUTPUT_PATH, transmute([]byte)strings.to_string(b)); err != nil {
		fmt.eprintfln("mapping: cannot write %q: %v", MAPPING_OUTPUT_PATH, err)
		os.exit(1)
	}

	inexact := 0
	keyed_count := 0
	clamp_count := 0
	for r in results {
		if !r.exact {inexact += 1}
		if r.display_keyed {keyed_count += 1}
		if r.clamps {clamp_count += 1}
	}
	fmt.printfln("wrote %v", MAPPING_OUTPUT_PATH)
	fmt.printfln("display-keyed: %v, clamping: %v, parameters without an exact fit: %v",
		keyed_count, clamp_count, inexact)
	for r in results {
		if !r.exact {
			fmt.printfln("  index %v: %v deviations over stored 0..%v", r.index, r.deviations, MAPPING_PROBE_HI)
		}
		if r.negative_deviations != 0 {
			fmt.printfln("  index %v: %v negative stored values read back one ulp off the grid",
				r.index, r.negative_deviations)
		}
	}
}
