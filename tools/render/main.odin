package render

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

// Offline renderer.
//
// Takes a .sy1 path and an output .wav path, plays a held middle C, and writes
// what the engine produced. This is layer 2 in docs/architecture.md terms: it
// is the only part of the three deliverables allowed to touch core:os, and it
// exists so the audio engine can be exercised and compared against the
// reference plugin's own `s1probe render` output without a plugin host.

SAMPLE_RATE :: 48000
CHANNELS :: 2

// The contract for this slice: a held middle C for 1.5 seconds, then 1.0 second
// of release tail. The tail is rendered after the note off rather than being
// trimmed off the end, so a patch with a long release is audibly truncated in
// the file rather than silently cut in the engine.
HOLD_SECONDS :: f32(1.5)
TAIL_SECONDS :: f32(1.0)

MIDDLE_C :: 60
VELOCITY :: f32(1.0)

main :: proc() {
	args := os.args
	if len(args) != 3 && len(args) != 4 {
		fmt.eprintfln(
			"usage: %s <patch.sy1> <output.wav> [midi note]",
			len(args) > 0 ? args[0] : "render",
		)
		os.exit(2)
	}

	// Which note to play. Middle C unless asked otherwise, because a patch that
	// behaves at middle C can still misbehave two octaves up: the filter's
	// keyboard tracking moves the cutoff with the note, and what a patch does at
	// the top of the keyboard is not visible from one note in the middle.
	note := MIDDLE_C
	if len(args) == 4 {
		parsed_note, ok := strconv.parse_int(args[3])
		if !ok || parsed_note < 0 || parsed_note > 127 {
			fmt.eprintfln("error: %v is not a MIDI note", args[3])
			os.exit(2)
		}
		note = parsed_note
	}

	patch_path := args[1]
	output_path := args[2]

	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read patch %s: %v", patch_path, read_err)
		os.exit(1)
	}
	defer delete(data)

	// Either format: a patch saved from the interface is JSON, and this reads
	// whichever one it was handed. See patch.detect_format.
	parsed, owned, parse_ok := patch.parse_patch_any(data)
	if !parse_ok {
		fmt.eprintfln("error: cannot parse %s", patch_path)
		os.exit(1)
	}
	// Not `if owned {defer ...}`: a defer inside a block runs at the end of
	// *that block*, so the name would be freed here and read below. The name is
	// wanted at the end of this procedure, so the release has to be deferred at
	// this scope, guarded rather than nested.
	defer if owned {patch.destroy_patch(parsed)}

	eng: engine.Engine
	engine.engine_load_patch(&eng, parsed, f32(SAMPLE_RATE))
	defer engine.engine_destroy(&eng)

	hold_frames := int(HOLD_SECONDS * f32(SAMPLE_RATE))
	tail_frames := int(TAIL_SECONDS * f32(SAMPLE_RATE))
	total_frames := hold_frames + tail_frames

	interleaved := make([]f32, total_frames * CHANNELS)
	defer delete(interleaved)

	// Rendered in two calls with the note off between them, which is what makes
	// the release tail a real release rather than a fade the tool applied.
	left := make([]f32, total_frames)
	defer delete(left)
	right := make([]f32, total_frames)
	defer delete(right)

	engine.engine_note_on(&eng, note, VELOCITY)
	engine.engine_process(&eng, left[:hold_frames], right[:hold_frames])

	engine.engine_note_off(&eng, note)
	engine.engine_process(&eng, left[hold_frames:], right[hold_frames:])

	peak: f32 = 0
	non_finite := 0
	for i in 0 ..< total_frames {
		l := left[i]
		r := right[i]
		// A non-finite sample is a bug, not a loud sample, so it is counted and
		// reported instead of being folded into the peak as a NaN.
		if l != l || r != r {
			non_finite += 1
			l = 0
			r = 0
		}
		if abs(l) > peak {peak = abs(l)}
		if abs(r) > peak {peak = abs(r)}
		interleaved[i * CHANNELS + 0] = l
		interleaved[i * CHANNELS + 1] = r
	}

	if !wav_write_f32(output_path, interleaved, CHANNELS, SAMPLE_RATE) {
		fmt.eprintfln("error: cannot write %s", output_path)
		os.exit(1)
	}

	name := strings.trim_space(parsed.name)
	fmt.printfln(
		"rendered %s \"%s\" -> %s frames=%d rate=%d channels=%d nonfinite=%d peak=%.6f",
		patch_path,
		name,
		output_path,
		total_frames,
		SAMPLE_RATE,
		CHANNELS,
		non_finite,
		peak,
	)
}

// Write interleaved 32-bit float samples as a WAVE_FORMAT_IEEE_FLOAT file.
// Deliberately the same shape as tools/s1probe/wav.odin so the two tools'
// output is byte-comparable header and all.
wav_write_f32 :: proc(path: string, samples: []f32, channels: int, sample_rate: int) -> bool {
	data_bytes := u32(len(samples) * size_of(f32))
	buf: [dynamic]u8
	defer delete(buf)

	put_str :: proc(b: ^[dynamic]u8, s: string) {
		for c in transmute([]u8)s do append(b, c)
	}
	put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
		x := v
		bytes := transmute([4]u8)x
		for c in bytes do append(b, c)
	}
	put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
		x := v
		bytes := transmute([2]u8)x
		for c in bytes do append(b, c)
	}

	put_str(&buf, "RIFF")
	put_u32(&buf, 4 + 8 + 18 + 8 + data_bytes)
	put_str(&buf, "WAVE")

	put_str(&buf, "fmt ")
	put_u32(&buf, 18)
	put_u16(&buf, 3) // IEEE float
	put_u16(&buf, u16(channels))
	put_u32(&buf, u32(sample_rate))
	put_u32(&buf, u32(sample_rate * channels * 4))
	put_u16(&buf, u16(channels * 4))
	put_u16(&buf, 32)
	put_u16(&buf, 0)

	put_str(&buf, "data")
	put_u32(&buf, data_bytes)

	base := len(buf)
	resize(&buf, base + int(data_bytes))
	mem.copy(&buf[base], raw_data(samples), int(data_bytes))

	return os.write_entire_file(path, buf[:]) == nil
}
