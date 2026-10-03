package standalone

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/engine"
import "../../src/patch"

// The real-time render path and the MIDI decode that feeds it.
//
// The lifecycle -- opening the device, loading the patch, sizing the buffers,
// starting the stream and tearing it all down in order -- lives in daemon.odin.
// This file is the part the audio thread runs: `live_render` fills a block,
// `live_handle_midi` decodes one message, and `live_load_patch` builds the
// patch the daemon plays. Read the two together to review the live behaviour.
//
// The threading story is the part worth checking:
//
//   - The daemon's main thread opens the device, loads the patch, sizes every
//     buffer, starts the stream, and then does nothing but wait for a signal.
//   - Each MIDI device's callback thread packs its message and pushes it into
//     a lock-free queue. It never touches the engine.
//   - The audio thread drains that queue and is the only thread that ever
//     calls into src/engine once the stream is running.
//
// So the engine has exactly one caller at a time without a single lock, and the
// audio callback below allocates nothing, locks nothing, opens nothing and
// formats no strings.

MIDI_NOTE_OFF :: 0x80
MIDI_NOTE_ON :: 0x90
MIDI_CONTROL_CHANGE :: 0xB0
MIDI_PROGRAM_CHANGE :: 0xC0
MIDI_PITCH_BEND :: 0xE0

// Bank Select, from the MIDI specification: two controllers that set a pending
// bank, coarse and fine, which the next Program Change acts on. The bank is
// MSB * 128 + LSB.
MIDI_BANK_SELECT_MSB :: 0
MIDI_BANK_SELECT_LSB :: 32

// The 14-bit MIDI bend range is 0..16383 with 8192 at rest. Both halves are
// divided by 8192 so the centre is exactly zero, which is the same convention
// hosts/clap/plugin.odin uses; the top of the range therefore reaches
// 8191/8192 rather than 1.0, which is what the wire format actually offers.
MIDI_BEND_CENTRE :: 8192.0

// Master output gain in thousandths of full scale. Integer thousandths rather
// than a float so unity is an exact value to compare against, which is what
// lets the render skip the multiply entirely at the default.
VOLUME_UNITY :: 1000

// All the control thread shares with the audio side for volume: one u32,
// stored and loaded atomically, never a lock. A struct of its own so that
// Control_Context can point at it without being able to reach the rest of Live.
Master_Volume :: struct {
	milli: u32,
}

Live :: struct {
	eng:   engine.Engine,
	queue: Midi_Queue,

	// Bank Select and Program Change, passed on rather than played. Choosing
	// a patch reads the bank and writes the ring, and both belong to the
	// control thread, so this thread only forwards them: it is the queue's one
	// producer and the control thread its one consumer. run_daemon initialises
	// it before the stream starts.
	select_queue: Midi_Queue,

	// De-interleave scratch. `engine_process` writes separate left and right
	// spans but every audio API on the planet wants them interleaved, so the
	// shell owns the buffers that bridge the two. Allocated once, before the
	// stream starts, sized to the largest block the device can ask for.
	left:  []f32,
	right: []f32,

	// The control plane, threaded through the audio callback. The control
	// server pushes edits onto `ring`; this callback drains them, applies them,
	// bumps `revision` and republishes `snapshot` for readers. All three are
	// zero-valued and inert until a control server is wired to them.
	ring:     Param_Ring,
	snapshot: Snapshot,
	revision: int,

	// Transaction staging: a batch's Set commands accumulate here until their
	// commit, so the batch applies all-or-nothing within one block. It persists
	// across blocks in case a transaction is split across the ring.
	txn_staging: [TXN_STAGING_MAX]Param_Command,
	txn_count:   int,

	// Runtime metrics shared with the control thread. nil until a control server
	// is wired; when present, the audio thread stores the live voice count into
	// it each block.
	metrics:  ^Daemon_Metrics,

	// Master volume. The control thread stores `volume`; the audio thread loads
	// it once per block and ramps to it from `volume_prev`, the level the
	// previous block ended at, which only the audio thread touches. Both are
	// zero -- silence -- in a zero Live, so run_daemon sets unity before the
	// stream starts.
	volume:      Master_Volume,
	volume_prev: u32,
}

// Drain queued control edits, applying each committed transaction to the engine
// and returning whether anything was applied. A transaction's Set commands are
// staged until its commit, so a batch applies at once and bumps the revision
// once; a transaction split across the ring simply finishes on a later block.
// Extracted from the audio callback so a test can drive it without a device.
live_drain_control :: proc(s: ^Live) -> (applied: bool) {
	for {
		cmd, ok := param_ring_pop(&s.ring)
		if !ok {
			break
		}
		switch cmd.kind {
		case .Commit:
			for i in 0 ..< s.txn_count {
				edit := s.txn_staging[i]
				engine.engine_set_stored(&s.eng, int(edit.index), int(edit.stored))
			}
			s.txn_count = 0
			s.revision += 1
			applied = true
		case .Commit_Checked:
			accepted := s.revision == cmd.expected_revision
			if accepted {
				for i in 0 ..< s.txn_count {
					edit := s.txn_staging[i]
					engine.engine_set_stored(&s.eng, int(edit.index), int(edit.stored))
				}
				s.revision += 1
				applied = true
			}
			s.txn_count = 0
			// Publish before acknowledging so a following read sees the edit.
			live_publish_snapshot(s)
			param_ring_post_result(&s.ring, Checked_Result{serial = cmd.serial, revision = s.revision, applied = accepted})
		case .Commit_Patch:
			live_replace_patch(s)
			s.txn_count = 0
			s.revision += 1
			applied = true
		case .Set:
			if s.txn_count < TXN_STAGING_MAX {
				s.txn_staging[s.txn_count] = cmd
				s.txn_count += 1
			}
		}
	}
	return applied
}

// Replace the patch with the staged transaction, as one change rather than as
// ninety-nine edits. Applied one by one, each value would glide from the last
// patch's, the delay and chorus would play the last patch's tail back under the
// new one, and a controller slot reassigned to another number would keep the
// old wheel's position and bend the new patch by it. engine_apply_patch with
// `snap` clears all of that; see it for the controller rule.
//
// The pool is kept: this is the audio thread, which must not allocate, and the
// key that is down must keep sounding. Parameters the transaction does not name
// keep the values the engine holds, because a file or an archive entry may name
// only some of them and loading one has always meant applying what it names.
// A replacement that changes no value still clears the effects: loading the
// same patch again is how a player silences what it left ringing.
@(private = "file")
live_replace_patch :: proc(s: ^Live) {
	next := s.eng.patch
	for i in 0 ..< s.txn_count {
		edit := s.txn_staging[i]
		if edit.index < 0 || int(edit.index) >= patch.PARAMETER_COUNT {continue}
		next.values[edit.index] = int(edit.stored)
	}
	engine.engine_apply_patch(&s.eng, next, snap = true, keep_voice_pool = true)
}

// The audio callback. Everything it touches is preallocated or atomic.
live_render :: proc "c" (user: rawptr, out: [^]f32, frames: int, channels: int) {
	// `engine_process` is an ordinary Odin procedure and so needs a context to
	// exist. `default_context()` fills a struct on the stack; it allocates
	// nothing, and nothing below it uses the allocator the struct names. This
	// is the same move hosts/clap/plugin.odin makes in process().
	context = runtime.default_context()

	s := (^Live)(user)
	if s == nil {
		return
	}

	// Drain the queue first so a note that arrived while the previous block was
	// rendering sounds at the top of this one. Timing is therefore block
	// accurate rather than sample accurate: the queue carries no timestamps,
	// and at a ~10 ms shared-mode period that is below what a player can hear
	// as late. Sample accuracy would mean timestamping against the device
	// clock, which is worth doing only if it ever proves audible.
	for {
		message, ok := midi_queue_pop(&s.queue)
		if !ok {
			break
		}
		live_handle_midi(s, message)
	}

	// Drain control edits at the same block-accurate timing. A transaction's Set
	// commands are staged and applied together on its commit, so the block below
	// never renders a partial batch.
	applied := live_drain_control(s)
	// Republish only when something changed, so an idle daemon does no snapshot
	// work per block. A reader between now and the next edit sees this state.
	if applied { live_publish_snapshot(s) }

	// One relaxed atomic per block so daemon.info can report the live voice
	// count without the control thread ever reaching into the engine.
	if s.metrics != nil {
		intrinsics.atomic_store_explicit(
			&s.metrics.active_voices,
			u32(engine.engine_active_voice_count(&s.eng)),
			.Relaxed,
		)
	}

	// The scratch was sized from the backend's own stated maximum, so this
	// clamp should never bite. It is here because the alternative to clamping,
	// on the audio thread, is a heap allocation or an overrun.
	n := min(frames, len(s.left))

	if n > 0 {
		engine.engine_process(&s.eng, s.left[:n], s.right[:n])
		live_apply_volume(s, n)
	}

	for i in 0 ..< n {
		base := i * channels
		out[base + 0] = s.left[i]
		out[base + 1] = s.right[i]
		// The engine is stereo. On a device with more channels the extras are
		// silenced rather than left holding whatever the driver's buffer
		// happened to contain.
		for c in 2 ..< channels {
			out[base + c] = 0
		}
	}

	// Silence anything the clamp above refused to render, so a short block is a
	// gap rather than stale audio.
	for i in n ..< frames {
		base := i * channels
		for c in 0 ..< channels {
			out[base + c] = 0
		}
	}
}

@(private = "file")
live_publish_snapshot :: proc(s: ^Live) {
	data: Snapshot_Data
	data.revision = s.revision
	for i in 0 ..< patch.PARAMETER_COUNT {
		data.values[i] = i32(engine.engine_patch_value(&s.eng, i))
	}
	snapshot_publish(&s.snapshot, data)
}

// Scale the finished block by the master volume, ramping linearly from the
// level the previous block ended at to this block's target, so a step becomes a
// fade one block long instead of a click. At unity on both ends the buffers are
// left exactly as the engine wrote them -- not even a multiply by one -- so the
// default output is bit-identical to a daemon with no volume stage.
@(private = "file")
live_apply_volume :: proc "contextless" (s: ^Live, n: int) {
	target := intrinsics.atomic_load_explicit(&s.volume.milli, .Relaxed)
	from := s.volume_prev
	s.volume_prev = target
	if from == VOLUME_UNITY && target == VOLUME_UNITY {return}
	g0 := f32(from) / VOLUME_UNITY
	step := (f32(target) / VOLUME_UNITY - g0) / f32(n)
	for i in 0 ..< n {
		g := g0 + step * f32(i + 1)
		s.left[i] *= g
		s.right[i] *= g
	}
}

// Decode one packed channel-voice message. Mirrors the MIDI half of
// hosts/clap/plugin.odin's handle_event so the plugin and the standalone
// build respond to a controller identically.
live_handle_midi :: proc(s: ^Live, message: u32) {
	status := midi_status(message) & 0xF0
	data1 := midi_data1(message)
	data2 := midi_data2(message)

	switch int(status) {
	case MIDI_NOTE_ON:
		// Running status aside, a note on with velocity 0 is the standard way
		// keyboards spell a note off, so it is treated as one.
		if data2 == 0 {
			engine.engine_note_off(&s.eng, int(data1))
		} else {
			engine.engine_note_on(&s.eng, int(data1), f32(data2) / 127.0)
		}

	case MIDI_NOTE_OFF:
		engine.engine_note_off(&s.eng, int(data1))

	case MIDI_CONTROL_CHANGE:
		// Bank Select is pending state, not an ordinary routed controller.
		// Forward the channel intact; the control thread owns patch loading.
		if data1 == MIDI_BANK_SELECT_MSB || data1 == MIDI_BANK_SELECT_LSB {
			midi_queue_push(&s.select_queue, message)
		} else {
			engine.engine_control_change(&s.eng, int(data1), int(data2))
		}

	case MIDI_PROGRAM_CHANGE:
		midi_queue_push(&s.select_queue, message)

	case MIDI_PITCH_BEND:
		raw := int(data1) | (int(data2) << 7)
		engine.engine_set_pitch_bend(&s.eng, f32((f64(raw) - MIDI_BEND_CENTRE) / MIDI_BEND_CENTRE))
	}
}

// Build the patch the daemon will play. With no path given it is the plugin's
// own defaults, which is what `parse_sy1` starts from before it applies a file.
//
// The returned name is always a fresh allocation the caller owns. It has to be:
// `patch.Patch.name` is a slice pointing into the file bytes, and those bytes
// are freed the moment this procedure returns, so handing the slice back would
// be a use-after-free that prints whatever the allocator left behind.
live_load_patch :: proc(patch_path: string) -> (parsed: patch.Patch, name: string, ok: bool) {
	if patch_path == "" {
		for i in 0 ..< patch.PARAMETER_COUNT {
			parsed.values[i] = patch.PARAMETERS[i].default
		}
		return parsed, strings.clone("(defaults)"), true
	}

	data, read_err := os.read_entire_file(patch_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read patch %s: %v", patch_path, read_err)
		return {}, "", false
	}
	defer delete(data)

	owned, parse_ok: bool
	parsed, owned, parse_ok = patch.parse_patch_any(data)
	if !parse_ok {
		fmt.eprintfln("error: cannot parse %s", patch_path)
		return {}, "", false
	}
	// Deliberately not `if owned {defer ...}`: a defer inside a block runs at
	// the end of that block, which would free the cloned name one line before
	// it is read.
	defer if owned {patch.destroy_patch(parsed)}
	// Only `values` is read from here on -- `bind_patch` never looks at the
	// name or the colour -- so copying the name is enough to make the struct
	// safe to keep after `data` goes away.
	return parsed, strings.clone(strings.trim_space(parsed.name)), true
}
