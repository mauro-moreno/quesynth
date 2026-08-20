#+build windows
package panel

import "base:intrinsics"

import "../../src/engine"

// Performance sent from the editor, carried across to the audio thread.
//
// A note played on the panel's keyboard arrives on the interface thread, and
// allocating a voice there while `process` is rendering is a race over the
// whole voice pool. Parameters do not need this -- a parameter is one integer
// written and one flag set, and `process` rebinds when it next runs -- but a
// note is a search for a free voice and a write to several of its fields.
//
// So notes take the long way round: written here, drained at the top of the
// next block. One producer and one consumer, which is what makes the two
// indices enough and a lock unnecessary.

Ui_Event_Kind :: enum u8 {
	Note_On,
	Note_Off,
	Bend,
	Control,
}

Ui_Event :: struct {
	kind: Ui_Event_Kind,
	// Note number, or controller number. Unused by Bend.
	a:    i32,
	// Velocity on 0..1, bend on -1..1, or controller value on 0..127.
	b:    f32,
}

UI_QUEUE_CAPACITY :: 256

Ui_Queue :: struct {
	events: [UI_QUEUE_CAPACITY]Ui_Event,
	write:  u32,
	read:   u32,
}

// Called from the interface thread only.
//
// A full queue drops the event rather than blocking or growing. Two hundred and
// fifty-six notes behind means the audio thread has stopped, and in that case
// there is nothing useful left to do with a note anyway.
push_event :: proc(q: ^Ui_Queue, event: Ui_Event) {
	write := intrinsics.atomic_load_explicit(&q.write, .Relaxed)
	read := intrinsics.atomic_load_explicit(&q.read, .Acquire)
	if write - read >= UI_QUEUE_CAPACITY {
		return
	}
	q.events[write % UI_QUEUE_CAPACITY] = event
	// Released after the slot is written, so a consumer that sees the new index
	// also sees the event in it.
	intrinsics.atomic_store_explicit(&q.write, write + 1, .Release)
}

// Called from the audio thread only, at the top of a block.
drain_events :: proc(q: ^Ui_Queue, eng: ^engine.Engine) {
	read := intrinsics.atomic_load_explicit(&q.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&q.write, .Acquire)

	for read != write {
		event := q.events[read % UI_QUEUE_CAPACITY]
		switch event.kind {
		case .Note_On:
			engine.engine_note_on(eng, int(event.a), event.b)
		case .Note_Off:
			engine.engine_note_off(eng, int(event.a))
		case .Bend:
			engine.engine_set_pitch_bend(eng, event.b)
		case .Control:
			engine.engine_control_change(eng, int(event.a), int(event.b))
		}
		read += 1
	}

	intrinsics.atomic_store_explicit(&q.read, read, .Release)
}
