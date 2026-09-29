package standalone

import "base:intrinsics"

// The control -> audio boundary for parameter edits.
//
// A single-producer single-consumer ring: the control server thread pushes
// commands, the audio thread pops them at the top of each block, the same
// block-accurate timing MIDI already gets. SPSC is enough because the control
// server serves one connection at a time on one thread, so there is exactly one
// producer, and the audio thread is the only consumer. That keeps this far
// simpler than the MPMC MIDI ring, whose many producer threads it does not
// need to match.
//
// The audio thread never blocks on this: pop is wait-free, and a full ring
// drops on the producer side with a count, exactly as the MIDI queue does.

Param_Command :: struct {
	index:  i32,
	stored: i32,
}

PARAM_RING_CAPACITY :: 256
PARAM_RING_MASK :: PARAM_RING_CAPACITY - 1
#assert(PARAM_RING_CAPACITY & PARAM_RING_MASK == 0)

Param_Ring :: struct {
	cells:   [PARAM_RING_CAPACITY]Param_Command,
	head:    u32, // consumer-owned (audio thread)
	tail:    u32, // producer-owned (control thread)
	dropped: u32,
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
