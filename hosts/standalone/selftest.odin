package standalone

import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

// Offline self-test mode.
//
// This exists so the standalone build can be proved on a machine with no audio
// hardware, no MIDI hardware and nobody sitting in front of it -- a CI box, in
// other words. It touches none of the platform seam in backend.odin: no device
// is opened, no audio thread is created, and the only Windows call in the
// process is the file write. That is what makes it a valid check of the parts
// that actually make sound.
//
// It is deliberately the same render the offline renderer performs, so the two
// outputs can be compared sample for sample when the sound-alike work needs an
// oracle.

SELFTEST_SAMPLE_RATE :: 48000
SELFTEST_CHANNELS :: 2

// A held middle C for 1.5 seconds, then 1.0 second of release tail. The tail is
// rendered after the note off rather than trimmed off the end, so a patch with
// a long release is audibly truncated in the file instead of being silently cut
// short in the engine.
SELFTEST_HOLD_SECONDS :: f32(1.5)
SELFTEST_TAIL_SECONDS :: f32(1.0)

SELFTEST_NOTE :: 60
SELFTEST_VELOCITY :: f32(1.0)

// Returns the process exit code: 0 only when the patch loaded, the render
// produced finite samples and the file was written.
run_selftest :: proc(patch_path, output_path: string) -> int {
	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read patch %s: %v", patch_path, read_err)
		return 1
	}
	defer delete(data)

	parsed, parse_err := patch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("error: cannot parse %s: %v", patch_path, parse_err)
		return 1
	}

	eng: engine.Engine
	engine.engine_load_patch(&eng, parsed, f32(SELFTEST_SAMPLE_RATE))
	defer engine.engine_destroy(&eng)

	hold_frames := int(SELFTEST_HOLD_SECONDS * f32(SELFTEST_SAMPLE_RATE))
	tail_frames := int(SELFTEST_TAIL_SECONDS * f32(SELFTEST_SAMPLE_RATE))
	total_frames := hold_frames + tail_frames

	left := make([]f32, total_frames)
	defer delete(left)
	right := make([]f32, total_frames)
	defer delete(right)
	interleaved := make([]f32, total_frames * SELFTEST_CHANNELS)
	defer delete(interleaved)

	// Two calls with the note off between them, which is what makes the tail a
	// real release rather than a fade this tool applied.
	engine.engine_note_on(&eng, SELFTEST_NOTE, SELFTEST_VELOCITY)
	engine.engine_process(&eng, left[:hold_frames], right[:hold_frames])

	engine.engine_note_off(&eng, SELFTEST_NOTE)
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
		interleaved[i * SELFTEST_CHANNELS + 0] = l
		interleaved[i * SELFTEST_CHANNELS + 1] = r
	}

	if !wav_write_f32(output_path, interleaved, SELFTEST_CHANNELS, SELFTEST_SAMPLE_RATE) {
		fmt.eprintfln("error: cannot write %s", output_path)
		return 1
	}

	name := strings.trim_space(parsed.name)
	fmt.printfln(
		"selftest %s \"%s\" -> %s frames=%d rate=%d channels=%d nonfinite=%d peak=%.6f",
		patch_path,
		name,
		output_path,
		total_frames,
		SELFTEST_SAMPLE_RATE,
		SELFTEST_CHANNELS,
		non_finite,
		peak,
	)

	// A render that produced a NaN wrote a file, but it did not pass. Saying so
	// with the exit code is the whole point of calling this a self-test.
	if non_finite > 0 {
		fmt.eprintfln("error: %d non-finite samples", non_finite)
		return 1
	}
	return 0
}
