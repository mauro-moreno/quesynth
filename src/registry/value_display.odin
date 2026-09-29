package registry

import "core:fmt"
import "core:math"
import "core:strings"

import "../engine"
import "../patch"

// A parameter's value in a real, measured unit -- hertz, seconds, decibels,
// percent, cents -- the way the reference's own read-out shows it and the way the
// web panel shows it, rather than the bare 0..127 the .sy1 format stores. The
// numbers here are computed from the same measured engine tables the web panel's
// generator (tools/uiparams) reads, so a value shown in the terminal matches the
// value shown in the browser to the digit.
//
// Kept beside the registry because it is client display metadata: a client asks
// the registry for a parameter's descriptor and, from the same place, how to
// read a value of it aloud.

Value_Unit :: enum {
	// The reference's own display string, which already reads correctly.
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

// Which parameters this project has measured a real unit for. Everything else
// falls back to the reference's own display, which for the effects and tunings
// already reads out in beats, milliseconds, hertz, percent, decibels or cents.
value_unit_kind :: proc(index: int) -> Value_Unit {
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

// The unit's suffix, appended after a bare numeric reading. "" when the reading
// carries its own unit (the reference display already reads "3.20 kHz", "4 ms").
value_unit_suffix :: proc(index: int) -> string {
	switch value_unit_kind(index) {
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
@(private)
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

@(private)
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

// The value at one position of one parameter, in its real unit. Temp-allocated.
value_text :: proc(index, position: int) -> string {
	states := patch.parameter_states(index)
	count := len(states)
	if count == 0 {
		return ""
	}
	pos := clamp(position, 0, count - 1)
	unit_pos := count > 1 ? f64(pos) / f64(count - 1) : 0

	switch value_unit_kind(index) {
	case .Seconds_Attack:
		return format_seconds(f64(engine.ENVELOPE_ATTACK_SECONDS[min(pos, 127)]))
	case .Seconds_Decay:
		return format_seconds(f64(engine.ENVELOPE_DECAY_SECONDS[min(pos, 127)]))
	case .Seconds_Release:
		return format_seconds(f64(engine.ENVELOPE_RELEASE_SECONDS[min(pos, 127)]))
	case .Cutoff_Hz:
		return format_hz(f64(engine.FILTER_CUTOFF_HZ[min(pos, 127)]))
	case .Resonance_Q:
		k := f64(engine.FILTER_DAMPING[min(pos, 127)])
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
		oct := f64(pos - engine.FILTER_ENV_CENTRE_STATE) * f64(engine.FILTER_ENV_OCTAVES_PER_STEP)
		return fmt.tprintf("%+.2f", oct)
	case .Gain_Db:
		a := f64(engine.AMP_GAIN_AMPLITUDE[min(pos, 127)])
		if a <= 1.0e-6 {
			return "-inf"
		}
		return fmt.tprintf("%+.1f", 20.0 * math.log10(a))
	case .Amp_Sustain_Percent:
		return fmt.tprintf("%.0f", 100.0 * f64(engine.AMP_SUSTAIN_LEVEL[min(pos, 127)]))
	case .Linear_Percent:
		return fmt.tprintf("%.0f", 100.0 * unit_pos)
	case .Lfo_Rate_Hz:
		return format_hz(f64(engine.LFO_RATE_HZ[min(pos, 127)]))
	case .Pulse_Width_Percent:
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
		if pos == 0 {
			return "free"
		}
		return fmt.tprintf("%.4f", 0.5 * f64(pos - 1) / 126.0)
	case .Sub_Carrier_Ratio:
		return fmt.tprintf("%.2f", 4.0 * unit_pos)
	case .Reference:
		return states[pos].display
	}
	return states[pos].display
}

// The full read-out for a stored value: the measured value and its unit, combined
// the way the web panel combines them -- a unit already inside the reading wins,
// otherwise the parameter's measured suffix is appended when the reading is a bare
// number. Temp-allocated when combined; safe to use until the next allocator reset.
registry_value_display :: proc(d: Parameter_Descriptor, stored: int) -> string {
	pos, ok := patch.parameter_position(d.index, stored)
	if !ok {
		return fmt.tprintf("%d", stored)
	}
	reading := value_text(d.index, pos)
	value, embedded := split_trailing_unit(reading)
	unit := embedded
	if unit == "" && !has_letter_or_percent(reading) {
		unit = value_unit_suffix(d.index)
	}
	if unit == "" {
		return reading
	}
	return fmt.tprintf("%s %s", value, unit)
}

// Split a reading into its numeric part and a trailing unit. The unit is the
// trailing run of unit characters, and only when the part before it holds a
// digit -- so "3.20 kHz" splits to ("3.20", "kHz") but "-inf" and "free" do not.
@(private)
split_trailing_unit :: proc(s: string) -> (value: string, unit: string) {
	i := len(s)
	for i > 0 {
		c := s[i - 1]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '%' || c == '/' {
			i -= 1
		} else {
			break
		}
	}
	if i == len(s) {
		return s, ""
	}
	prefix := s[:i]
	has_digit := false
	for c in prefix {
		if c >= '0' && c <= '9' {
			has_digit = true
			break
		}
	}
	if !has_digit {
		return s, ""
	}
	return strings.trim_space(prefix), strings.trim_space(s[i:])
}

@(private)
has_letter_or_percent :: proc(s: string) -> bool {
	for c in s {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '%' {
			return true
		}
	}
	return false
}
