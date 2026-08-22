package patch

import "core:strconv"

// Sy1_Error distinguishes malformed records from an index outside the live
// parameter table. The parser does not read files or allocate storage.
Sy1_Error :: enum {
	None,
	Missing_Header,
	Malformed_Header,
	Malformed_Color,
	Malformed_Version,
	Malformed_Line,
	Invalid_Index,
	Index_Out_Of_Range,
	Invalid_Value,
}

Patch :: struct {
	name:    string,
	color:   string,
	version: int,
	values:  [PARAMETER_COUNT]int,
	present: [PARAMETER_COUNT]bool,
}

line_end :: proc(data: []byte, start: int) -> (line: []byte, next: int) {
	end := start
	for end < len(data) && data[end] != '\n' {
		end += 1
	}
	line = data[start:end]
	if len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	next = end
	if next < len(data) {
		next += 1
	}
	return
}

has_prefix :: proc(line: []byte, prefix: string) -> bool {
	if len(line) < len(prefix) {return false}
	for i in 0 ..< len(prefix) {
		if line[i] != prefix[i] {return false}
	}
	return true
}

bytes_string :: proc(data: []byte) -> string {
	return transmute(string)data
}
is_ascii_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

trim_ascii_space :: proc(data: []byte) -> []byte {
	start := 0
	end := len(data)
	for start < end && is_ascii_space(data[start]) {
		start += 1
	}
	for end > start && is_ascii_space(data[end-1]) {
		end -= 1
	}
	return data[start:end]
}


// Is this line one of the file's `index,value` records?
//
// Tested rather than assumed, because the header above the records is not
// always there. Knowing what a record looks like is what lets the name, the
// colour and the version each be optional without any of them swallowing a
// record by accident.
sy1_is_record :: proc(line: []byte) -> bool {
	trimmed := trim_ascii_space(line)
	if len(trimmed) == 0 {return false}

	comma := -1
	for c, i in trimmed {
		if c == ',' {
			if comma >= 0 {return false}
			comma = i
		}
	}
	if comma <= 0 || comma >= len(trimmed)-1 {return false}

	for i in 0 ..< comma {
		if trimmed[i] < '0' || trimmed[i] > '9' {return false}
	}
	value := trimmed[comma+1:]
	if value[0] == '-' || value[0] == '+' {
		value = value[1:]
	}
	if len(value) == 0 {return false}
	for c in value {
		if c < '0' || c > '9' {return false}
	}
	return true
}

parse_sy1 :: proc(data: []byte) -> (patch: Patch, err: Sy1_Error) {
	for i in 0 ..< PARAMETER_COUNT {
		patch.values[i] = PARAMETERS[i].default
	}

	if len(trim_ascii_space(data)) == 0 {
		return {}, .Missing_Header
	}

	// The three header lines are each optional, and each is claimed only by a
	// line that is actually one of them.
	//
	// Every one of them is missing from real banks. Synth1's own factory files
	// name themselves on the first line with no `Synth1 ` prefix -- 127 of the
	// 128 in soundbank00 do -- and the older third-party banks have no `color=`
	// or `ver=` line at all: 386 of the 16698 patches in the collection this
	// project tests against are name-then-records, some of them with only the
	// first fifty parameters that version had. A reader that insists on the
	// full header refuses all of them, and the reference plugin loads them.
	line, pos := line_end(data, 0)
	switch {
	case has_prefix(line, "Synth1 "):
		patch.name = bytes_string(line[len("Synth1 "):])
	case sy1_is_record(line) || has_prefix(line, "color=") || has_prefix(line, "ver="):
		// Nameless: this line is content, so it is not consumed here.
		pos = 0
	case len(trim_ascii_space(line)) > 0:
		patch.name = bytes_string(line)
	case:
		// A leading blank line names nothing and is not a record either.
		break
	}

	if pos < len(data) {
		resume := pos
		line, pos = line_end(data, pos)
		if has_prefix(line, "color=") {
			patch.color = bytes_string(line[len("color="):])
		} else {
			pos = resume
		}
	}

	// No `ver=` line leaves the version at zero, which `upgrade_pre_107` reads
	// as "unknown" and therefore converts nothing. That is deliberate: a file
	// that does not say which format it is in cannot be converted out of it,
	// and this project does not apply a law it has not measured.
	if pos < len(data) {
		resume := pos
		line, pos = line_end(data, pos)
		if has_prefix(line, "ver=") {
			version, ok := strconv.parse_int(bytes_string(line[len("ver="):]), 10)
			if !ok {
				return {}, .Malformed_Version
			}
			patch.version = version
		} else {
			pos = resume
		}
	}

    for pos < len(data) {
        line, pos = line_end(data, pos)
        line = trim_ascii_space(line)
        if len(line) == 0 {
            continue
        }

        comma := -1
        for c, i in line {
            if c == ',' {
                if comma >= 0 {
                    return {}, .Malformed_Line
                }
                comma = i
            }
        }
        if comma <= 0 || comma >= len(line)-1 {
            return {}, .Malformed_Line
        }

        index_text := trim_ascii_space(line[:comma])
        value_text := trim_ascii_space(line[comma+1:])
        if len(index_text) == 0 || len(value_text) == 0 {
            return {}, .Malformed_Line
        }
        index, index_ok := strconv.parse_int(bytes_string(index_text), 10)
        if !index_ok {
            return {}, .Invalid_Index
        }
        if index < 0 {
            return {}, .Invalid_Index
        }
        if index >= PARAMETER_COUNT {
            return {}, .Index_Out_Of_Range
        }
        value, value_ok := strconv.parse_int(bytes_string(value_text), 10)
        if !value_ok {
            return {}, .Invalid_Value
        }
        // Duplicate records are accepted; the later record is the effective one.
        patch.values[index] = value
        patch.present[index] = true
    }

	upgrade_pre_107(&patch)
	return patch, .None
}

// The version at which several parameters changed meaning, from the reference's
// own changelog: "Ver1.07(alpha) (2005.10.1)".
SY1_BIPOLAR_VERSION :: 107

// Bring a patch saved before v1.07 up to the meaning its values have today.
//
// Every file in the factory bank is `ver=105`, and v1.07 redefined parameters
// they all carry. The reference converts on load; this engine did not, and
// read the field only to store it. On the knobs that went from unipolar to
// bipolar that is not an approximation, it is a sign error -- 124 of the 128
// factory patches store `55,0`, which this engine read as -99 % feedback where
// the reference reads 0 %.
//
// The conversion is measured, not guessed. Loading factory `001.sy1`
// (`ver=105`) into v1.13 and saving it back untouched writes `ver=113` with
// exactly ten parameters changed, and that pair of files is the table:
//
//   param                     ver105  ver113   law
//   21 filter amount              37      82   64 + old/2
//   55 chorus feedback             0      64   64 + old/2
//   37 delay dry/wet              39      19   old/2
//   16 filter decay              105     100   not yet known
//   18 filter release             78      74   not yet known
//   26 amp decay                  28      23   not yet known
//   28 amp release                64      62   not yet known
//   50 midi ctrl sens1           127      64   not yet known
//   51 midi ctrl sens2           127      96   not yet known
//   54 chorus rate                64      50   not yet known
//
// Only the three with an exact integer law are applied. They are also the
// three that matter most: 21 and 55 both changed from a unipolar range to a
// bipolar one, so reading them raw does not merely misplace a value, it puts
// it on the wrong side of centre -- 21 at 37 is *negative* filter envelope
// amount read raw and *positive* after conversion. The remaining seven are
// left alone rather than approximated: 16, 18, 26 and 28 move by about 5%,
// 54's range was widened to 0.01-400 Hz so its law is a curve, and 50 and 51
// map the same input to two different outputs, so no function of the value
// alone can express them. Each needs more converted patches to pin down, and a
// wrong law would be worse than none.
//
// Why the null test could not have found this: `s1probe compare` pushes the
// parsed values into the reference through SetChunk, so before this the
// reference was being driven with the same unconverted numbers as this engine.
// Both sides made the identical misreading and agreed with each other. The
// error is in what the file means, not in what either engine does with it.
// The four envelope-time parameters share one conversion curve.
//
// 16, 18, 26 and 28 are filter decay, filter release, amp decay and amp
// release, and the five converted patches give eleven (old, new) pairs between
// them that agree wherever they overlap -- 105 -> 100 appears for 16 and for
// 18, 64 -> 62 for 18, 26 and 28, 68 -> 66 for 26 and 28. One curve, sampled
// by four parameters. It is not a scaling: the offset runs -8 at the bottom,
// -1 in the thirties, -2 in the sixties and -5 in the nineties, which is what
// a remap between two different time curves looks like rather than a gain.
// v1.08's changelog lists "modify attack time" among its envelope changes.
SY1_ENV_CURVE := [?][2]int{
	{0, 0}, {8, 0}, {28, 23}, {39, 38}, {47, 47}, {60, 59}, {64, 62},
	{68, 66}, {78, 74}, {92, 87}, {104, 99}, {105, 100}, {118, 115},
}

// Measured points only, no extrapolation past the last one.
sy1_env_convert :: proc(v: int) -> int {
	n := len(SY1_ENV_CURVE)
	if v <= SY1_ENV_CURVE[0][0] {
		return SY1_ENV_CURVE[0][1]
	}
	last := SY1_ENV_CURVE[n - 1]
	if v >= last[0] {
		// Beyond the measured range, hold the offset the last point had rather
		// than continuing a slope no measurement supports.
		return clamp_index(v + last[1] - last[0])
	}
	for i in 0 ..< n - 1 {
		a := SY1_ENV_CURVE[i]
		b := SY1_ENV_CURVE[i + 1]
		if v >= a[0] && v <= b[0] {
			span := b[0] - a[0]
			if span <= 0 {
				return a[1]
			}
			// Linear between the two measured points, rounded.
			return clamp_index(a[1] + ((v - a[0]) * (b[1] - a[1]) * 2 + span) / (span * 2))
		}
	}
	return v
}

// A measured value pair, applied only where it was measured.
sy1_lookup :: proc(table: [][2]int, v: int) -> (int, bool) {
	for e in table {
		if e[0] == v {
			return e[1], true
		}
	}
	return v, false
}

// Parameter 55, chorus feedback. Three patches storing 0 all convert to 64,
// which is the case that matters: 124 of the 128 factory patches store 0.
// The two non-zero conversions available do not fit any law through those --
// 78 also lands on 64, and 127 lands on 6 -- and both come from the only two
// patches whose chorus *delay time* (52) moved as well, which suggests the
// section is recomputed as a whole rather than per knob. Measured points are
// applied; anything else is left alone rather than guessed.
SY1_FEEDBACK_POINTS := [?][2]int{{0, 64}, {78, 64}, {127, 6}}

// Parameter 54, chorus rate. v1.07 widened the range to 0.01-400 Hz, so the
// conversion is a curve; 64 -> 50 is confirmed by three separate patches.
SY1_RATE_POINTS := [?][2]int{{19, 24}, {26, 29}, {64, 50}}

// Parameter 52, chorus delay time. v1.07 added an "ultra short time (0.05ms)"
// to the bottom of the range, which compresses the low end and leaves the rest
// alone: 64 is unchanged in three patches, while the two patches with a short
// delay both move up, 16 -> 19 and 23 -> 24.
SY1_DELAY_TIME_POINTS := [?][2]int{{16, 19}, {23, 24}, {64, 64}}

upgrade_pre_107 :: proc(patch: ^Patch) {
	if patch.version <= 0 || patch.version >= SY1_BIPOLAR_VERSION {
		return
	}

	// Parameter 21 went from a one-sided 0..127 to a range whose zero is stored
	// 63 -- the state whose display reads "0", which `FILTER_ENV_CENTRE_STATE`
	// already records. Five converted patches fit `63 + old * 64/127` exactly:
	// 0 -> 63, 18 -> 72, 37 -> 82, 43 -> 85, 73 -> 100.
	if patch.present[21] {
		v := patch.values[21]
		patch.values[21] = clamp_index(63 + (v * 64 * 2 + 127) / (127 * 2))
	}
	// The delay's old `level` became a dry/wet balance over the same 0..127.
	// Four patches: 39 -> 19, 17 -> 8, 40 -> 20, 44 -> 22.
	if patch.present[37] {
		patch.values[37] = clamp_index(patch.values[37] / 2)
	}
	if patch.present[55] {
		if v, ok := sy1_lookup(SY1_FEEDBACK_POINTS[:], patch.values[55]); ok {
			patch.values[55] = clamp_index(v)
		}
	}
	if patch.present[54] {
		if v, ok := sy1_lookup(SY1_RATE_POINTS[:], patch.values[54]); ok {
			patch.values[54] = clamp_index(v)
		}
	}
	if patch.present[52] {
		if v, ok := sy1_lookup(SY1_DELAY_TIME_POINTS[:], patch.values[52]); ok {
			patch.values[52] = clamp_index(v)
		}
	}
	for i in ([?]int{16, 18, 26, 28}) {
		if patch.present[i] {
			patch.values[i] = sy1_env_convert(patch.values[i])
		}
	}
	// 50 and 51 are deliberately untouched. The same input (127) converts to
	// 64, 90, 125 and 95 in four different patches, so no function of the value
	// alone can express them; v1.07 is also where the MIDI controller section
	// was reworked, so they are likely recomputed from parameters that did not
	// exist in the older format rather than rescaled.
}

clamp_index :: proc(v: int) -> int {
	if v < 0 {return 0}
	if v > 127 {return 127}
	return v
}
