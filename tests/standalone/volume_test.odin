package standalone_tests

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import control "../../src/control"
import engine "../../src/engine"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// Master volume: the command, and what it does to the sound through the real
// live_render. The reference for "what the sound was" is the engine rendered
// on its own, block by block, the way live_render rendered before it had a
// volume stage -- not the volume code's own arithmetic.

// The control side can reach one u32 of the audio side's volume and nothing
// more: a type the compiler checks, so no later edit can widen it quietly.
#assert(intrinsics.type_field_type(standalone.Control_Context, "volume") == ^standalone.Master_Volume)
#assert(size_of(standalone.Master_Volume) == size_of(u32))

@(private = "file")
BLOCK :: 256

@(private = "file")
default_patch :: proc() -> patch.Patch {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
	}
	return p
}

// A Live as run_daemon leaves it -- engine loaded, scratch sized, volume at
// unity -- with middle C held so there is something to scale.
@(private = "file")
sounding_live :: proc() -> ^standalone.Live {
	live := new(standalone.Live)
	engine.engine_load_patch(&live.eng, default_patch(), 48000)
	live.left = make([]f32, BLOCK)
	live.right = make([]f32, BLOCK)
	live.volume.milli = standalone.VOLUME_UNITY
	live.volume_prev = standalone.VOLUME_UNITY
	engine.engine_note_on(&live.eng, 60, 1)
	return live
}

@(private = "file")
live_free :: proc(live: ^standalone.Live) {
	engine.engine_destroy(&live.eng)
	delete(live.left)
	delete(live.right)
	free(live)
}

// Stand in for the audio device: one stereo block through the real callback.
@(private = "file")
render_block :: proc(live: ^standalone.Live, out: []f32) {
	standalone.live_render(live, raw_data(out), BLOCK, 2)
}

@(private = "file")
ask_volume :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

@(test)
test_volume_command_bounds_errors_and_info :: proc(t: ^testing.T) {
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	standalone.snapshot_publish(&snap, standalone.Snapshot_Data{revision = 9})
	vol := standalone.Master_Volume{milli = standalone.VOLUME_UNITY}
	metrics := standalone.Daemon_Metrics {
		sample_rate = 48000,
		buffer_size = BLOCK,
		max_voices  = 16,
		backend     = "ALSA (default)",
		start_tick  = time.tick_now(),
	}
	cc := standalone.Control_Context {
		ring     = &ring,
		snapshot = &snap,
		state    = &state,
		metrics  = &metrics,
		volume   = &vol,
	}

	testing.expect_value(t, ask_volume(&cc, "1 1 volume 0"), "1 1 ok volume=0")
	testing.expect_value(t, vol.milli, 0)
	testing.expect_value(t, ask_volume(&cc, "1 2 volume 1000"), "1 2 ok volume=1000")
	testing.expect_value(t, vol.milli, 1000)
	testing.expect_value(t, ask_volume(&cc, "1 3 volume 437"), "1 3 ok volume=437")

	for bad in ([]string{"1001", "-1", "loud", "12.5"}) {
		reply := ask_volume(&cc, fmt.tprintf("1 4 volume %s", bad))
		testing.expect_value(t, reply, "1 4 err invalid_payload volume needs 0..1000")
	}
	testing.expect_value(t, ask_volume(&cc, "1 5 volume"), "1 5 err invalid_payload volume needs 0..1000")
	testing.expect_value(t, vol.milli, 437)

	// Reported just before backend, which stays last for its spaces.
	info := ask_volume(&cc, "1 6 daemon.info")
	testing.expect(t, strings.has_suffix(info, " volume=437 backend=ALSA (default)"), info)
	// Not a patch parameter: no revision moved and nothing reached the ring.
	testing.expect(t, strings.contains(info, " revision=9 "), info)
	_, queued := standalone.param_ring_pop(&ring)
	testing.expect(t, !queued)

	cc.volume = nil
	testing.expect_value(t, ask_volume(&cc, "1 7 volume 500"), "1 7 err daemon_not_ready no audio")
	testing.expect(t, !strings.contains(ask_volume(&cc, "1 8 daemon.info"), "volume="))
}

@(test)
test_volume_at_unity_leaves_the_output_bit_identical :: proc(t: ^testing.T) {
	live := sounding_live()
	defer live_free(live)
	reference: engine.Engine
	engine.engine_load_patch(&reference, default_patch(), 48000)
	defer engine.engine_destroy(&reference)
	engine.engine_note_on(&reference, 60, 1)
	cc := standalone.Control_Context{volume = &live.volume}

	out: [BLOCK * 2]f32
	left, right: [BLOCK]f32
	peak: f32
	compare :: proc(out: []f32, left, right: []f32) -> (differing: int) {
		for i in 0 ..< BLOCK {
			if transmute(u32)out[2 * i] != transmute(u32)left[i] {differing += 1}
			if transmute(u32)out[2 * i + 1] != transmute(u32)right[i] {differing += 1}
		}
		return
	}

	differing := 0
	for _ in 0 ..< 16 {
		render_block(live, out[:])
		engine.engine_process(&reference, left[:], right[:])
		differing += compare(out[:], left[:], right[:])
		for s in left {peak = max(peak, abs(s))}
	}
	testing.expect(t, peak > 0.01, "the comparison must be of sound, not silence")
	testing.expect_value(t, differing, 0)

	// Down and back up: once the ramp back has finished, unity is again no stage
	// at all rather than a multiply that happens to be by one.
	ask_volume(&cc, "1 1 volume 500")
	for _ in 0 ..< 2 {
		render_block(live, out[:])
		engine.engine_process(&reference, left[:], right[:])
	}
	ask_volume(&cc, "1 2 volume 1000")
	render_block(live, out[:])
	engine.engine_process(&reference, left[:], right[:])
	differing = 0
	for _ in 0 ..< 8 {
		render_block(live, out[:])
		engine.engine_process(&reference, left[:], right[:])
		differing += compare(out[:], left[:], right[:])
	}
	testing.expect_value(t, differing, 0)
}

@(test)
test_volume_step_ramps_over_one_block_to_the_new_level :: proc(t: ^testing.T) {
	// Two identical voices: `full` stays at unity as the reference, `quiet` is
	// turned down. The engine is upstream of the gain, so the two only ever
	// differ by the gain that was applied.
	full := sounding_live()
	defer live_free(full)
	quiet := sounding_live()
	defer live_free(quiet)
	cc := standalone.Control_Context{volume = &quiet.volume}

	a, b: [BLOCK * 2]f32
	peak: f32
	for _ in 0 ..< 8 {
		render_block(full, a[:])
		render_block(quiet, b[:])
	}
	for s in a {peak = max(peak, abs(s))}
	if !testing.expect(t, peak > 0.01, "the comparison must be of sound, not silence") {return}

	testing.expect_value(t, ask_volume(&cc, "1 1 volume 500"), "1 1 ok volume=500")
	// The control thread stored the target and nothing else: the level the
	// audio thread ramps from is untouched until the audio thread renders.
	testing.expect_value(t, quiet.volume_prev, standalone.VOLUME_UNITY)

	render_block(full, a[:])
	render_block(quiet, b[:])
	// The gain each sample received, read wherever the reference is loud enough
	// to divide by. A step of 1 -> 0.5 spread over BLOCK samples may move the
	// gain by at most 0.5/BLOCK per sample; a click would jump 0.5 at once.
	per_sample := f32(0.5) / BLOCK
	tolerance := f32(1e-4)
	prev_i := -1
	prev_g := f32(1) // where the previous block ended
	valid := 0
	for i in 0 ..< BLOCK {
		ref := a[2 * i]
		if abs(ref) < 0.1 * peak {continue}
		g := b[2 * i] / ref
		testing.expectf(t, g >= 0.5 - tolerance && g <= 1 + tolerance, "gain %v at sample %d", g, i)
		testing.expectf(
			t,
			abs(g - prev_g) <= f32(i - prev_i) * per_sample + tolerance,
			"gain moved %v over %d samples at %d",
			g - prev_g,
			i - prev_i,
			i,
		)
		prev_i, prev_g = i, g
		valid += 1
	}
	testing.expect(t, valid > BLOCK / 4, "too few loud samples to trace the ramp")
	// By the block's end the ramp has arrived.
	testing.expectf(t, abs(prev_g - 0.5) <= f32(BLOCK - 1 - prev_i) * per_sample + tolerance, "ended at %v", prev_g)

	// From then on the level is steady at half.
	worst: f32
	for _ in 0 ..< 4 {
		render_block(full, a[:])
		render_block(quiet, b[:])
		for i in 0 ..< BLOCK * 2 {worst = max(worst, abs(b[i] - 0.5 * a[i]))}
	}
	testing.expectf(t, worst <= 1e-6 * peak, "half volume is off by %v", worst)
}
