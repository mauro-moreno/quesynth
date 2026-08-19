package standalone

import "base:intrinsics"

// A bounded lock-free queue carrying MIDI messages from the input threads to
// the audio thread.
//
// Why it has to be multi-producer: the live shell opens *every* MIDI input, and
// the Windows multimedia API delivers each device's messages on its own
// callback thread. A single-producer ring would be quietly wrong the moment a
// second device is plugged in, which is exactly the kind of bug that only
// appears on someone else's desk.
//
// Why it has to be lock-free: the consumer is the audio render thread. It may
// never block on a mutex that a MIDI callback thread happens to hold, because
// the scheduler is under no obligation to run that thread before the device
// wants its next buffer, and the audible result is a dropout.
//
// The algorithm is Dmitry Vyukov's bounded MPMC queue. Every cell carries a
// sequence number saying whose turn the cell is:
//
//   - A producer claims a ticket by advancing `enqueue_pos`, writes the
//     payload, then publishes the cell with a Release store of `sequence`.
//   - A consumer only takes a cell whose sequence proves that publishing store
//     already happened, which it observes with an Acquire load.
//
// That per-cell handshake is the part a bare compare-exchange on a write index
// cannot do: it makes a slot that has been claimed but not yet written
// invisible to the consumer, instead of letting it read the previous lap's
// message.

// 1024 messages is far more than a period's worth of even a dense controller
// sweep, so the drop path below is a genuine last resort rather than something
// normal playing reaches.
MIDI_QUEUE_CAPACITY :: 1024
MIDI_QUEUE_MASK :: MIDI_QUEUE_CAPACITY - 1

// The mask arithmetic above is only a valid modulo for a power of two.
#assert(MIDI_QUEUE_CAPACITY & MIDI_QUEUE_MASK == 0)

Midi_Cell :: struct {
	sequence: u32,
	message:  u32,
}

Midi_Queue :: struct {
	cells:       [MIDI_QUEUE_CAPACITY]Midi_Cell,
	enqueue_pos: u32,
	dequeue_pos: u32,
	// Messages the queue had no room for. Counted rather than ignored so the
	// shell can say so on shutdown instead of losing notes silently.
	dropped:     u32,
}

// Seed each cell with its own index, which is what marks every cell empty and
// "on lap zero" for the sequence comparisons below.
midi_queue_init :: proc "contextless" (q: ^Midi_Queue) {
	for i in 0 ..< MIDI_QUEUE_CAPACITY {
		q.cells[i].sequence = u32(i)
		q.cells[i].message = 0
	}
	q.enqueue_pos = 0
	q.dequeue_pos = 0
	q.dropped = 0
}

// Called from a MIDI input thread. Returns false when the queue is full.
midi_queue_push :: proc "contextless" (q: ^Midi_Queue, message: u32) -> bool {
	pos := intrinsics.atomic_load_explicit(&q.enqueue_pos, .Relaxed)
	cell: ^Midi_Cell

	for {
		cell = &q.cells[pos & MIDI_QUEUE_MASK]
		sequence := intrinsics.atomic_load_explicit(&cell.sequence, .Acquire)
		// Signed difference: `sequence` and `pos` both wrap, and only their
		// distance is meaningful.
		difference := i64(sequence) - i64(pos)

		switch {
		case difference == 0:
			// The cell is free and this ticket owns it. Take the ticket; on
			// success `pos` stays the claimed slot.
			old, swapped := intrinsics.atomic_compare_exchange_weak_explicit(
				&q.enqueue_pos,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)
			if swapped {
				// Claimed. Fall through to the publish below.
				cell.message = message
				intrinsics.atomic_store_explicit(&cell.sequence, pos + 1, .Release)
				return true
			}
			// Another producer won the race; retry against its value.
			pos = old

		case difference < 0:
			// The consumer is a full lap behind: there is nowhere to put this.
			// Dropping is the only real-time-safe answer, so it is recorded.
			intrinsics.atomic_add_explicit(&q.dropped, 1, .Relaxed)
			return false

		case:
			// A concurrent producer has already moved the index on; re-read it.
			pos = intrinsics.atomic_load_explicit(&q.enqueue_pos, .Relaxed)
		}
	}
}

// Called from the audio thread. Returns ok=false when the queue is empty.
midi_queue_pop :: proc "contextless" (q: ^Midi_Queue) -> (message: u32, ok: bool) {
	pos := intrinsics.atomic_load_explicit(&q.dequeue_pos, .Relaxed)
	cell: ^Midi_Cell

	for {
		cell = &q.cells[pos & MIDI_QUEUE_MASK]
		sequence := intrinsics.atomic_load_explicit(&cell.sequence, .Acquire)
		// A cell is readable once its sequence has advanced one past the
		// ticket that wrote it, which is `pos + 1`.
		difference := i64(sequence) - i64(pos + 1)

		switch {
		case difference == 0:
			old, swapped := intrinsics.atomic_compare_exchange_weak_explicit(
				&q.dequeue_pos,
				pos,
				pos + 1,
				.Relaxed,
				.Relaxed,
			)
			if swapped {
				message = cell.message
				// Release the cell to the producer one lap ahead.
				intrinsics.atomic_store_explicit(
					&cell.sequence,
					pos + MIDI_QUEUE_CAPACITY,
					.Release,
				)
				return message, true
			}
			pos = old

		case difference < 0:
			// The producer has not published this slot: the queue is empty.
			return 0, false

		case:
			pos = intrinsics.atomic_load_explicit(&q.dequeue_pos, .Relaxed)
		}
	}
}

midi_queue_dropped :: proc "contextless" (q: ^Midi_Queue) -> u32 {
	return intrinsics.atomic_load_explicit(&q.dropped, .Relaxed)
}

// -- message packing ---------------------------------------------------------

// A channel-voice MIDI message is three bytes, so it travels through the queue
// as one 32-bit word. Packing it keeps each cell a single atomic-sized payload
// and removes any question of tearing between the status and the data bytes.
midi_pack :: proc "contextless" (status, data1, data2: u8) -> u32 {
	return u32(status) | (u32(data1) << 8) | (u32(data2) << 16)
}

midi_status :: proc "contextless" (message: u32) -> u8 {
	return u8(message & 0xFF)
}

midi_data1 :: proc "contextless" (message: u32) -> u8 {
	return u8((message >> 8) & 0xFF)
}

midi_data2 :: proc "contextless" (message: u32) -> u8 {
	return u8((message >> 16) & 0xFF)
}
