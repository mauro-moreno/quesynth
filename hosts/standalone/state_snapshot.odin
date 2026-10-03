package standalone

import "base:intrinsics"

import "../../src/patch"

// The audio -> control boundary for reads.
//
// The audio thread owns the live patch, so the control thread cannot read it
// under a lock -- a lock the audio thread might be holding is exactly what must
// never happen on the audio path. Instead the audio thread publishes a coherent
// copy of the stored values and the current revision into this snapshot after
// each batch of edits, and the control thread reads it without ever blocking
// the audio thread.
//
// The mechanism is a seqlock: the writer brackets its copy with an odd, then
// even, sequence number, and the reader retries whenever it catches a write in
// progress or a write that landed during its copy. The writer never waits,
// which is the whole point on the audio thread; the reader may spin, which is
// fine at control rate.

Snapshot_Data :: struct {
	revision: int,
	values:   [patch.PARAMETER_COUNT]i32,
}

Snapshot :: struct {
	seq:  u32, // even = stable, odd = a write is in progress
	data: Snapshot_Data,
}

// Writer: the audio thread only.
snapshot_publish :: proc "contextless" (s: ^Snapshot, data: Snapshot_Data) {
	seq := intrinsics.atomic_load_explicit(&s.seq, .Relaxed)
	intrinsics.atomic_store_explicit(&s.seq, seq + 1, .Relaxed) // mark odd
	intrinsics.atomic_thread_fence(.Release) // odd is visible before the copy
	s.data = data
	intrinsics.atomic_thread_fence(.Release) // the copy is done before even
	intrinsics.atomic_store_explicit(&s.seq, seq + 2, .Relaxed) // mark even
}

// Reader: the control thread. Spins until it reads a stable, even sequence that
// did not change across the copy.
snapshot_read :: proc "contextless" (s: ^Snapshot) -> Snapshot_Data {
	for {
		seq1 := intrinsics.atomic_load_explicit(&s.seq, .Acquire)
		if seq1 & 1 != 0 {
			continue
		}
		data := s.data
		intrinsics.atomic_thread_fence(.Acquire) // the copy is done before seq2
		seq2 := intrinsics.atomic_load_explicit(&s.seq, .Relaxed)
		if seq1 == seq2 {
			return data
		}
	}
}
