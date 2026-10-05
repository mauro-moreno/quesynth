#+build linux
package standalone_tests

import "core:testing"
import "core:time"

import standalone "../../hosts/standalone"

// Positions are u32 and wrap; the queue only stays correct if the cell
// sequence comparisons use the wrapped 32-bit distance. Seed the queue just
// below the u32 limit so every test below crosses the wrap.
@(private = "file")
seed_near_wrap :: proc(q: ^standalone.Midi_Queue, start: u32) {
	// Cell j must hold the ticket in [start, start+CAPACITY) that maps to j.
	for i in 0 ..< u32(standalone.MIDI_QUEUE_CAPACITY) {
		ticket := start + i
		q.cells[ticket & standalone.MIDI_QUEUE_MASK].sequence = ticket
		q.cells[ticket & standalone.MIDI_QUEUE_MASK].message = 0
	}
	q.enqueue_pos = start
	q.dequeue_pos = start
	q.dropped = 0
}

@(test)
midi_queue_keeps_fifo_order_across_position_wrap :: proc(t: ^testing.T) {
	// A misread sequence makes push/pop spin forever; fail instead of hanging.
	testing.set_fail_timeout(t, 10 * time.Second)
	q := new(standalone.Midi_Queue)
	defer free(q)
	seed_near_wrap(q, max(u32) - 10)

	// Several laps' worth so both positions and every cell sequence wrap.
	for i in u32(0) ..< 3 * standalone.MIDI_QUEUE_CAPACITY {
		testing.expect(t, standalone.midi_queue_push(q, i + 1), "push should succeed")
		message, ok := standalone.midi_queue_pop(q)
		testing.expect(t, ok, "pop should find the message just pushed")
		testing.expect_value(t, message, i + 1)
	}
	testing.expect(t, q.enqueue_pos < 3 * standalone.MIDI_QUEUE_CAPACITY, "positions should have wrapped")

	_, ok := standalone.midi_queue_pop(q)
	testing.expect(t, !ok, "an empty queue must report empty after the wrap")
	testing.expect_value(t, standalone.midi_queue_dropped(q), 0)
}

@(test)
midi_queue_preserves_batch_order_across_position_wrap :: proc(t: ^testing.T) {
	// A misread sequence makes push/pop spin forever; fail instead of hanging.
	testing.set_fail_timeout(t, 10 * time.Second)
	q := new(standalone.Midi_Queue)
	defer free(q)
	seed_near_wrap(q, max(u32) - 10)

	for i in u32(0) ..< 100 {
		testing.expect(t, standalone.midi_queue_push(q, i + 1), "push should succeed")
	}
	for i in u32(0) ..< 100 {
		message, ok := standalone.midi_queue_pop(q)
		testing.expect(t, ok, "pop should succeed")
		testing.expect_value(t, message, i + 1)
	}
	_, ok := standalone.midi_queue_pop(q)
	testing.expect(t, !ok, "queue should be empty")
}

@(test)
midi_queue_reports_full_across_position_wrap :: proc(t: ^testing.T) {
	// A misread sequence makes push/pop spin forever; fail instead of hanging.
	testing.set_fail_timeout(t, 10 * time.Second)
	q := new(standalone.Midi_Queue)
	defer free(q)
	seed_near_wrap(q, max(u32) - 10)

	for i in u32(0) ..< standalone.MIDI_QUEUE_CAPACITY {
		testing.expect(t, standalone.midi_queue_push(q, i + 1), "push into free space should succeed")
	}
	testing.expect(t, !standalone.midi_queue_push(q, 0xDEAD), "a full queue must refuse the push")
	testing.expect_value(t, standalone.midi_queue_dropped(q), 1)

	for i in u32(0) ..< standalone.MIDI_QUEUE_CAPACITY {
		message, ok := standalone.midi_queue_pop(q)
		testing.expect(t, ok, "pop should succeed")
		testing.expect_value(t, message, i + 1)
	}
}
