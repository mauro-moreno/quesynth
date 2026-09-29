package standalone

import "base:intrinsics"

// The control -> audio boundary for parameter edits.
//
// A single-producer single-consumer ring: the control server thread pushes
// commands, the audio thread pops them at the top of each block, the same
// block-accurate timing MIDI already gets. SPSC is enough because the control
// server multiplexes all connections on one thread: exactly one producer and
// one audio consumer. This is simpler than the MPMC MIDI ring, whose many
// producer threads it does not need to match.
//
// The audio thread never blocks on this: pop is wait-free, and a full ring
// drops on the producer side with a count, exactly as the MIDI queue does.

// Every mutation crosses the ring as a run of Set commands ended by a Commit.
// The audio thread stages the Sets and applies them together on the Commit,
// bumping the revision once, so a batch is atomic relative to a block: no block
// ever renders half a transaction, and a reader never sees a partial one.
Param_Command_Kind :: enum i32 {
	Set,
	Commit,
}

Param_Command :: struct {
	kind:   Param_Command_Kind,
	index:  i32,
	stored: i32,
}

// The most edits one transaction can stage. Larger than the whole registry, so
// even "set every parameter at once" fits.
TXN_STAGING_MAX :: 128

PARAM_RING_CAPACITY :: 256
PARAM_RING_MASK :: PARAM_RING_CAPACITY - 1
#assert(PARAM_RING_CAPACITY & PARAM_RING_MASK == 0)

Param_Ring :: struct {
	cells:   [PARAM_RING_CAPACITY]Param_Command,
	head:    u32, // consumer-owned (audio thread)
	tail:    u32, // producer-owned (control thread)
	dropped: u32, // rejected enqueue attempts (one per refused transaction)
}

// Producer side, on the control thread. Returns false when the ring is full.
param_ring_push :: proc "contextless" (r: ^Param_Ring, cmd: Param_Command) -> bool {
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	// Unsigned distance: both indices wrap, and only the gap between them is
	// meaningful. A full ring is exactly CAPACITY apart.
	if tail - head >= PARAM_RING_CAPACITY {
		intrinsics.atomic_add_explicit(&r.dropped, 1, .Relaxed)
		return false
	}
	r.cells[tail & PARAM_RING_MASK] = cmd
	intrinsics.atomic_store_explicit(&r.tail, tail + 1, .Release)
	return true
}

// Free slots, read by the producer before pushing a whole transaction so it
// never pushes a partial one. Only the control thread calls this, so reading the
// producer-owned tail relaxed is correct.
param_ring_free_space :: proc "contextless" (r: ^Param_Ring) -> int {
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	return PARAM_RING_CAPACITY - int(tail - head)
}

// Consumer side, on the audio thread. ok=false when the ring is empty.
param_ring_pop :: proc "contextless" (r: ^Param_Ring) -> (cmd: Param_Command, ok: bool) {
	head := intrinsics.atomic_load_explicit(&r.head, .Relaxed)
	tail := intrinsics.atomic_load_explicit(&r.tail, .Acquire)
	if head == tail {
		return {}, false
	}
	cmd = r.cells[head & PARAM_RING_MASK]
	intrinsics.atomic_store_explicit(&r.head, head + 1, .Release)
	return cmd, true
}

param_ring_dropped :: proc "contextless" (r: ^Param_Ring) -> u32 {
	return intrinsics.atomic_load_explicit(&r.dropped, .Relaxed)
}
