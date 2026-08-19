package synth_vst3

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

UI_Event_Kind :: enum u8 {
	Note_On,
	Note_Off,
	Bend,
	Control,
}

UI_Event :: struct {
	kind: UI_Event_Kind,
	// Note number, or controller number. Unused by Bend.
	a:    i32,
	// Velocity on 0..1, bend on -1..1, or controller value on 0..127.
	b:    f32,
}

UI_QUEUE_CAPACITY :: 256

UI_Queue :: struct {
	events: [UI_QUEUE_CAPACITY]UI_Event,
	write:  u32,
	read:   u32,
}

// Called from the interface thread only.
//
// A full queue drops the event rather than blocking or growing. Two hundred and
// fifty-six notes behind means the audio thread has stopped, and in that case
// there is nothing useful left to do with a note anyway.
push_ui_event :: proc(p: ^Plugin, event: UI_Event) {
	write := intrinsics.atomic_load_explicit(&p.ui_queue.write, .Relaxed)
	read := intrinsics.atomic_load_explicit(&p.ui_queue.read, .Acquire)
	if write - read >= UI_QUEUE_CAPACITY {
		return
	}
	p.ui_queue.events[write % UI_QUEUE_CAPACITY] = event
	// Released after the slot is written, so a consumer that sees the new index
	// also sees the event in it.
	intrinsics.atomic_store_explicit(&p.ui_queue.write, write + 1, .Release)
}

// Called from the audio thread only, at the top of a block.
drain_ui_events :: proc(p: ^Plugin) {
	read := intrinsics.atomic_load_explicit(&p.ui_queue.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&p.ui_queue.write, .Acquire)

	for read != write {
		event := p.ui_queue.events[read % UI_QUEUE_CAPACITY]
		switch event.kind {
		case .Note_On:
			engine.engine_note_on(&p.eng, int(event.a), event.b)
		case .Note_Off:
			engine.engine_note_off(&p.eng, int(event.a))
		case .Bend:
			engine.engine_set_pitch_bend(&p.eng, event.b)
		case .Control:
			engine.engine_control_change(&p.eng, int(event.a), int(event.b))
		}
		read += 1
	}

	intrinsics.atomic_store_explicit(&p.ui_queue.read, read, .Release)
}
