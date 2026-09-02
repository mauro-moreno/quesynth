// uiparams - emit the parameter table the HTML interface reads.
//
//   odin run tools/uiparams -out:build/uiparams.exe
//
// The interface needs three things per parameter that only this repository knows:
// how many positions the control has, which stored integer each position writes,
// and what the value at that position actually *is* in a real unit.
//
// The third is the point. Synth1's own display is a bare 0..127 for most of the
// interesting controls -- the filter cutoff, every envelope segment, the LFO
// speed, the resonance -- so a interface that echoed the plugin would show a
// number that means nothing. This project has measured what those numbers are, and
// `src/engine`'s generated tables hold the answers, so the interface can show
// hertz, seconds, decibels and Q instead. Where a parameter has no measured table,
// the reference's own display string is used, which for the effects and the
// tunings already carries a unit.
//
// Regenerate after any change to those tables. The generated file is checked in so
// the interface can be opened without a build step.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import patch "../../src/patch"
import engine "../../src/engine"

OUT_PATH :: "ui/params.js"

// How a parameter's value should be shown.
Unit_Kind :: enum {
	// The reference's own display string, which already carries a unit.
	Reference,
	Seconds_Attack,
	Seconds_Decay,
	Seconds_Release,
	Cutoff_Hz,
	Resonance_Q,
	Filter_Env_Octaves,
	Gain_Db,
	Amp_Sustain_Percent,
	Linear_Percent,
	Lfo_Rate_Hz,
	Pulse_Width_Percent,
	Track_Octaves,
	Detune_Cents,
	Fm_Carrier_Ratio,
	Osc1_Component_Cents,
	Osc_Phase_Turns,
	Sub_Carrier_Ratio,
}

// Which parameters this project has measured a real unit for.
//
// Everything absent from this list falls back to the reference's display. That is
// not a gap: parameters 35, 52, 54, 55, 61, 62, 90 and the tunings already read out
// in beats, milliseconds, hertz, percent, decibels and cents respectively.
unit_for :: proc(index: int) -> Unit_Kind {
	switch index {
	case 12, 15, 25:
		return .Seconds_Attack
	case 13, 16, 26:
		return .Seconds_Decay
	case 18, 28:
		return .Seconds_Release
	case 19:
		return .Cutoff_Hz
	case 20:
		return .Resonance_Q
	case 21:
		return .Filter_Env_Octaves
	case 29:
		return .Gain_Db
	case 27:
		return .Amp_Sustain_Percent
	case 17, 34:
		return .Linear_Percent
	case 43, 48:
		return .Lfo_Rate_Hz
	case 8:
		return .Pulse_Width_Percent
	case 22:
		return .Track_Octaves
	case 75:
		return .Detune_Cents
	case 45:
		return .Fm_Carrier_Ratio
	case 76:
		return .Osc1_Component_Cents
	case 91:
		return .Osc_Phase_Turns
	case 95:
		return .Sub_Carrier_Ratio
	}
	return .Reference
}

// The unit's suffix, shown once under the control rather than on every value.
unit_suffix :: proc(kind: Unit_Kind) -> string {
	switch kind {
	case .Seconds_Attack, .Seconds_Decay, .Seconds_Release:
		return "time"
	case .Cutoff_Hz:
		return "Hz"
	case .Resonance_Q:
		return "Q"
	case .Filter_Env_Octaves:
		return "oct"
	case .Gain_Db:
		return "dB"
	case .Amp_Sustain_Percent, .Linear_Percent, .Pulse_Width_Percent:
		return "%"
	case .Lfo_Rate_Hz:
		return "Hz"
	case .Track_Octaves:
		return "oct/oct"
	case .Detune_Cents, .Osc1_Component_Cents:
		return "cents"
	case .Fm_Carrier_Ratio, .Sub_Carrier_Ratio:
		return "× carrier"
	case .Osc_Phase_Turns:
		return "turns"
	case .Reference:
		return ""
	}
	return ""
}

// A duration written the way a musician reads one.
format_seconds :: proc(s: f64) -> string {
	if s < 0.001 {
		return fmt.tprintf("%.2f ms", s * 1000.0)
	}
	if s < 1.0 {
		return fmt.tprintf("%.0f ms", s * 1000.0)
	}
	if s < 10.0 {
		return fmt.tprintf("%.2f s", s)
	}
	return fmt.tprintf("%.1f s", s)
}

format_hz :: proc(hz: f64) -> string {
	if hz < 1.0 {
		return fmt.tprintf("%.3f Hz", hz)
	}
	if hz < 100.0 {
		return fmt.tprintf("%.2f Hz", hz)
	}
	if hz < 1000.0 {
		return fmt.tprintf("%.0f Hz", hz)
	}
	return fmt.tprintf("%.2f kHz", hz / 1000.0)
}

// The value at one position of one parameter, in its real unit.
value_text :: proc(index, position: int, kind: Unit_Kind) -> string {
	states := patch.parameter_states(index)
	count := len(states)
	unit_pos := count > 1 ? f64(position) / f64(count - 1) : 0

	switch kind {
	case .Seconds_Attack:
		return format_seconds(f64(engine.ENVELOPE_ATTACK_SECONDS[min(position, 127)]))
	case .Seconds_Decay:
		return format_seconds(f64(engine.ENVELOPE_DECAY_SECONDS[min(position, 127)]))
	case .Seconds_Release:
		return format_seconds(f64(engine.ENVELOPE_RELEASE_SECONDS[min(position, 127)]))
	case .Cutoff_Hz:
		return format_hz(f64(engine.FILTER_CUTOFF_HZ[min(position, 127)]))
	case .Resonance_Q:
		// The damping is 1/Q by construction, so this is the resonance the filter
		// actually reaches -- which runs to nearly 1000 in the last few steps.
		k := f64(engine.FILTER_DAMPING[min(position, 127)])
		if k <= 0 {
			return "max"
		}
		q := 1.0 / k
		if q < 10.0 {
			return fmt.tprintf("%.2f", q)
		}
		if q < 100.0 {
			return fmt.tprintf("%.1f", q)
		}
		return fmt.tprintf("%.0f", q)
	case .Filter_Env_Octaves:
		oct := f64(position - engine.FILTER_ENV_CENTRE_STATE) *
			f64(engine.FILTER_ENV_OCTAVES_PER_STEP)
		return fmt.tprintf("%+.2f", oct)
	case .Gain_Db:
		a := f64(engine.AMP_GAIN_AMPLITUDE[min(position, 127)])
		if a <= 1.0e-6 {
			return "-inf"
		}
		return fmt.tprintf("%+.1f", 20.0 * math.log10(a))
	case .Amp_Sustain_Percent:
		return fmt.tprintf("%.0f", 100.0 * f64(engine.AMP_SUSTAIN_LEVEL[min(position, 127)]))
	case .Linear_Percent:
		return fmt.tprintf("%.0f", 100.0 * unit_pos)
	case .Lfo_Rate_Hz:
		return format_hz(f64(engine.LFO_RATE_HZ[min(position, 127)]))
	case .Pulse_Width_Percent:
		// The knob spans a quarter duty at its centre and a half at the top, which
		// is measured and is not what the reference's bare number suggests.
		return fmt.tprintf("%.1f", 100.0 * unit_pos * 0.5)
	case .Track_Octaves:
		return fmt.tprintf("%.2f", unit_pos)
	case .Detune_Cents:
		return fmt.tprintf("%.1f", 50.0 * unit_pos)
	case .Fm_Carrier_Ratio:
		ratio := 96.0 * math.pow(unit_pos, 5.5)
		if ratio < 1.0 {
			return fmt.tprintf("%.3f", ratio)
		}
		return fmt.tprintf("%.2f", ratio)
	case .Osc1_Component_Cents:
		return fmt.tprintf("%.2f", 20.0 * unit_pos)
	case .Osc_Phase_Turns:
		if position == 0 {
			return "free"
		}
		return fmt.tprintf("%.4f", 0.5 * f64(position - 1) / 126.0)
	case .Sub_Carrier_Ratio:
		return fmt.tprintf("%.2f", 4.0 * unit_pos)
	case .Reference:
		return states[position].display
	}
	return states[position].display
}

js_escape :: proc(s: string, b: ^strings.Builder) {
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n', '\r', '\t':
			strings.write_string(b, " ")
		case:
			strings.write_byte(b, c)
		}
	}
}

main :: proc() {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, `// Code generated by "odin run tools/uiparams"; do not edit.
//
// The reference Synth1's parameter table, with each position's value in a real
// unit wherever this project has measured one. Method and provenance are in
// docs/null-test.md; the tables this is built from are the generated files in
// src/engine.
//
// Per parameter:
//   i     parameter index, as the engine and the .sy1 format number them
//   name  the reference's own short name
//   def   the stored integer that reproduces the plugin's default
//   n     how many positions the control has
//   unit  suffix for the value readout, "" when the value text carries its own
//   v     the value at each position, in order
//   s     the stored integer each position writes, omitted when it is the position
//
// `)
	fmt.sbprintf(&b, "%v parameters.\nwindow.SYNTH1_PARAMS = [\n", patch.PARAMETER_COUNT)

	for index in 0 ..< patch.PARAMETER_COUNT {
		p := patch.PARAMETERS[index]
		states := patch.parameter_states(index)
		kind := unit_for(index)

		strings.write_byte(&b, '{')
		fmt.sbprintf(&b, "i:%v,name:\"", index)
		js_escape(p.name, &b)
		fmt.sbprintf(&b, "\",def:%v,n:%v", p.default, len(states))

		suffix := unit_suffix(kind)
		if suffix != "" {
			fmt.sbprintf(&b, ",unit:\"%v\"", suffix)
		}

		if p.continuous || len(states) == 0 {
			// 86..89 read back as a fraction and have no state table at all.
			fmt.sbprintf(&b, ",n:%v,cont:1", patch.CONTINUOUS_DENOMINATOR)
			strings.write_string(&b, "},\n")
			continue
		}

		strings.write_string(&b, ",v:[")
		for position in 0 ..< len(states) {
			if position > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_byte(&b, '"')
			js_escape(value_text(index, position, kind), &b)
			strings.write_byte(&b, '"')
		}
		strings.write_byte(&b, ']')

		// The stored integer per position, when it is not simply the position.
		//
		// It differs for every display-keyed parameter whose displays are not in
		// order, which is where this project has twice been caught: the LFO
		// waveforms of 42 and 47 list their six states as 0, 1, 5, 2, 3, 4.
		needs_steps := false
		for position in 0 ..< len(states) {
			if stored_for_position(index, position) != position {
				needs_steps = true
				break
			}
		}
		if needs_steps {
			strings.write_string(&b, ",s:[")
			for position in 0 ..< len(states) {
				if position > 0 {
					strings.write_byte(&b, ',')
				}
				fmt.sbprintf(&b, "%v", stored_for_position(index, position))
			}
			strings.write_byte(&b, ']')
		}
		strings.write_string(&b, "},\n")
	}
	strings.write_string(&b, "];\n")

	// The error itself, not just that there was one. This runs in CI, where the
	// difference between "no such directory" and "permission denied" is the
	// difference between reading the log and guessing.
	if err := os.write_entire_file(OUT_PATH, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintfln("uiparams: could not write %v: %v", OUT_PATH, err)
		os.exit(1)
	}
	fmt.printfln("wrote %v (%v parameters)", OUT_PATH, patch.PARAMETER_COUNT)
}

// The stored integer that selects a given position.
//
// For a display-keyed parameter the plugin selects the state whose display equals
// the stored integer, so the interface has to write that display rather than the
// index. `resolved_position` is the inverse and this has to agree with it.
stored_for_position :: proc(index, position: int) -> int {
	states := patch.parameter_states(index)
	if position < 0 || position >= len(states) {
		return position
	}
	if !patch.PARAMETERS[index].display_keyed {
		return position
	}
	if d, ok := patch.display_integer(states[position].display); ok {
		return d
	}
	return position
}
