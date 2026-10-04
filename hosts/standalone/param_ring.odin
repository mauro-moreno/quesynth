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

// Every mutation crosses the ring as a run of Set commands ended by a commit.
// The audio thread stages the Sets and applies them together on the commit,
// bumping the revision once, so a batch is atomic relative to a block: no block
// ever renders half a transaction, and a reader never sees a partial one.
//
// The commit says what the batch is. Commit ends a run of ordinary edits, a
// knob or two, which must glide and keep every tail. Commit_Patch ends a whole
// patch: the audio thread replaces the patch instead, so nothing the previous
// one left in the effects, the smoothers or a reassigned controller is heard
// under the new one. Commit_Checked ends a run of ordinary edits only if the
// revision the audio thread has reached is the `expected_revision` it carries;
// otherwise the run is discarded. Either way the audio thread answers on the
// ring's results queue, tagged with the commit's `serial`. Appended rather than
// inserted so the older values keep their numbers.
Param_Command_Kind :: enum i32 {
	Set,
	Commit,
	Commit_Patch,
	Commit_Checked,
}

Param_Command :: struct {
	kind:              Param_Command_Kind,
	index:             i32,
	stored:            i32,
	expected_revision: int,
	serial:            u64,
}

// The most edits one transaction can stage. Larger than the whole registry, so
// even "set every parameter at once" fits.
TXN_STAGING_MAX :: 128

PARAM_RING_CAPACITY :: 256
PARAM_RING_MASK :: PARAM_RING_CAPACITY - 1
#assert(PARAM_RING_CAPACITY & PARAM_RING_MASK == 0)

// The audio thread's answer to one Commit_Checked: whether it applied the batch,
// and the revision it held afterwards, which it has already published.
Checked_Result :: struct {
	serial:   u64,
	revision: int,
	applied:  bool,
}

// Room for the results of more checked commits than the ring can hold at once,
// since each takes a Set and its commit at the least. The queue can fill only
// if the control thread stops draining it.
CHECKED_RESULT_CAPACITY :: 256
CHECKED_RESULT_MASK :: CHECKED_RESULT_CAPACITY - 1
#assert(CHECKED_RESULT_CAPACITY & CHECKED_RESULT_MASK == 0)
#assert(CHECKED_RESULT_CAPACITY >= PARAM_RING_CAPACITY / 2)

Param_Ring :: struct {
	cells:   [PARAM_RING_CAPACITY]Param_Command,
	head:    u32, // consumer-owned (audio thread)
	tail:    u32, // producer-owned (control thread)
	dropped: u32, // rejected enqueue attempts (one per refused transaction)
	// Odd while the audio thread is taking commands off the ring and
	// publishing what they did, even otherwise; it only grows. A popped
	// command is not in the snapshot until that publish, so `head` alone
	// cannot tell the control thread that the snapshot shows an edit. See
	// param_ring_published.
	drains:  u32, // consumer-owned (audio thread)
	// The answers to Commit_Checked, in the order the audio thread decided them:
	// a second single-producer single-consumer queue, running the other way. They
	// are kept here rather than on a waiting caller's stack, so a caller that
	// gave up leaves the audio callback nothing dangling. The control thread
	// numbers each checked commit (`checked_serial`, never 0) and matches the
	// serial of a result to the request that is waiting for it; a result nobody
	// waits for any more is discarded.
	checked_serial: u64, // producer-owned (control thread)
	results:        [CHECKED_RESULT_CAPACITY]Checked_Result,
	results_head:   u32, // consumer-owned (control thread)
	results_tail:   u32, // producer-owned (audio thread)
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

// Bracket, on the audio thread, a block's pops and the publish of what they
// applied. Odd before the first pop: each pop's release store of `head`
// carries the odd count to a reader that sees that head.
param_ring_drain_begin :: proc "contextless" (r: ^Param_Ring) {
	n := intrinsics.atomic_load_explicit(&r.drains, .Relaxed)
	intrinsics.atomic_store_explicit(&r.drains, n + 1, .Relaxed)
}

// Even again once the snapshot is published, and released after it, so a
// reader that sees the even count sees that publish.
param_ring_drain_end :: proc "contextless" (r: ^Param_Ring) {
	n := intrinsics.atomic_load_explicit(&r.drains, .Relaxed)
	intrinsics.atomic_store_explicit(&r.drains, n + 1, .Release)
}

// The snapshot, if it already shows what every command pushed before
// `position` did: a tail the control thread read after pushing them. It does
// once the audio thread has popped them all and finished the drain that
// popped them, which published what they applied. That is known when the
// drain count is even and does not move while `head` and the snapshot are
// read: a drain that began in between would have made it odd before any pop
// this could see. Otherwise false, during a drain too, and the caller asks
// again later. On the control thread; it never waits for the audio thread.
param_ring_published :: proc "contextless" (r: ^Param_Ring, s: ^Snapshot, position: u32) -> (data: Snapshot_Data, ok: bool) {
	before := intrinsics.atomic_load_explicit(&r.drains, .Acquire)
	if before & 1 != 0 {
		return
	}
	tail := intrinsics.atomic_load_explicit(&r.tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
	// Distances back from the tail, since the indices wrap: position has
	// been popped when no more is left after head than after it.
	if tail - head > tail - position {
		return
	}
	data = snapshot_read(s)
	intrinsics.atomic_thread_fence(.Acquire)
	return data, intrinsics.atomic_load_explicit(&r.drains, .Relaxed) == before
}

// Post one result, on the audio thread. Wait-free: a full queue drops the result
// rather than wait for room, and the request it answered then reports an unknown
// outcome, which is what it reports for an answer that never comes.
param_ring_post_result :: proc "contextless" (r: ^Param_Ring, result: Checked_Result) -> bool {
	tail := intrinsics.atomic_load_explicit(&r.results_tail, .Relaxed)
	head := intrinsics.atomic_load_explicit(&r.results_head, .Acquire)
	if tail - head >= CHECKED_RESULT_CAPACITY {
		return false
	}
	r.results[tail & CHECKED_RESULT_MASK] = result
	intrinsics.atomic_store_explicit(&r.results_tail, tail + 1, .Release)
	return true
}

// Take the oldest result, on the control thread. ok=false when there is none.
param_ring_take_result :: proc "contextless" (r: ^Param_Ring) -> (result: Checked_Result, ok: bool) {
	head := intrinsics.atomic_load_explicit(&r.results_head, .Relaxed)
	tail := intrinsics.atomic_load_explicit(&r.results_tail, .Acquire)
	if head == tail {
		return {}, false
	}
	result = r.results[head & CHECKED_RESULT_MASK]
	intrinsics.atomic_store_explicit(&r.results_head, head + 1, .Release)
	return result, true
}
