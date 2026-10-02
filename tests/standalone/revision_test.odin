package standalone_tests

import "base:intrinsics"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "../../src/control"
import "../../src/engine"
import standalone "../../hosts/standalone"
import "../../src/patch"
import "../../src/registry"

// `parameter.set_many expected_revision=N ...`: the daemon compares N with the
// revision the audio thread has reached, in ring order, so a batch applies only
// to the state its sender saw. These drive the real handler, the real ring and
// the real transaction path of live_render; the audio thread is a stand-in that
// only calls live_render in a loop, or is left out to hold the ring still.

@(private = "file")
Revision_Bench :: struct {
	live:  ^standalone.Live,
	state: standalone.Daemon_State,
	cc:    standalone.Control_Context,
	done:  b32,
	audio: ^thread.Thread,
}

@(private = "file")
revision_audio :: proc(data: rawptr) {
	b := (^Revision_Bench)(data)
	for !intrinsics.atomic_load(&b.done) {
		standalone.live_render(b.live, nil, 0, 2)
		time.sleep(time.Millisecond)
	}
}

// The ring is drained from the start only when `draining`; otherwise the bench
// holds every enqueued command until the test starts the audio side itself.
@(private = "file")
bench_make :: proc(draining := true) -> ^Revision_Bench {
	b := new(Revision_Bench)
	b.live = new(standalone.Live)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT { p.values[i] = patch.PARAMETERS[i].default }
	engine.engine_load_patch(&b.live.eng, p, 48000)
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT { seed.values[i] = i32(engine.engine_patch_value(&b.live.eng, i)) }
	standalone.snapshot_publish(&b.live.snapshot, seed)
	b.state = .Running
	b.cc = standalone.Control_Context{ring = &b.live.ring, snapshot = &b.live.snapshot, state = &b.state}
	if draining { bench_start_audio(b) }
	return b
}

@(private = "file")
bench_start_audio :: proc(b: ^Revision_Bench) {
	b.audio = thread.create_and_start_with_data(b, revision_audio)
}

@(private = "file")
bench_free :: proc(b: ^Revision_Bench) {
	if b.audio != nil {
		intrinsics.atomic_store(&b.done, true)
		thread.join(b.audio)
		thread.destroy(b.audio)
	}
	engine.engine_destroy(&b.live.eng)
	free(b.live)
	free(b)
}

@(private = "file")
revision_request :: proc(b: ^Revision_Bench, line: string) -> string {
	req, ok := control.request_parse(transmute([]u8)line)
	assert(ok)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(&b.cc, req, &out)
	return strings.to_string(out)
}

@(private = "file")
published_revision :: proc(b: ^Revision_Bench) -> int {
	return standalone.snapshot_read(&b.live.snapshot).revision
}

@(private = "file")
published_value :: proc(b: ^Revision_Bench, id: string) -> int {
	d, found := registry.registry_describe(id)
	assert(found)
	return int(standalone.snapshot_read(&b.live.snapshot).values[d.index])
}

// Wait for the audio stand-in to reach a revision a legacy edit queued, whose
// acknowledgement does not wait for it.
@(private = "file")
await_revision :: proc(b: ^Revision_Bench, revision: int) -> bool {
	for _ in 0 ..< 1000 {
		if published_revision(b) == revision { return true }
		time.sleep(time.Millisecond)
	}
	return false
}

@(private = "file")
ring_is_empty :: proc(b: ^Revision_Bench) -> bool {
	_, any := standalone.param_ring_pop(&b.live.ring)
	return !any
}

@(test)
test_checked_batch_applies_once_and_rejects_stale_revision :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	first := revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40 filter.resonance 20")
	testing.expect_value(t, first, "1 1 ok count=2 revision=1")
	second := revision_request(b, "1 2 parameter.set_many expected_revision=0 filter.cutoff 80 filter.resonance 30")
	testing.expect_value(t, second, "1 2 err revision_conflict current_revision=1")
	snapshot := revision_request(b, "1 3 state.snapshot")
	testing.expect(t, strings.contains(snapshot, "revision=1"))
	testing.expect(t, strings.contains(snapshot, "id=filter.cutoff value=40\n"))
	testing.expect(t, strings.contains(snapshot, "id=filter.resonance value=20\n"))
}

@(test)
test_the_same_expected_revision_succeeds_for_one_batch_only :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	results: [4]string
	for i in 0 ..< len(results) {
		results[i] = revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 50")
	}
	testing.expect_value(t, results[0], "1 1 ok count=1 revision=1")
	for i in 1 ..< len(results) {
		testing.expect_value(t, results[i], "1 1 err revision_conflict current_revision=1")
	}
	testing.expect_value(t, published_revision(b), 1)
}

@(test)
test_a_refused_batch_leaves_the_revision_and_values_alone :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	before := published_value(b, "filter.cutoff")
	stale := revision_request(b, "1 1 parameter.set_many expected_revision=9 filter.cutoff 11")
	testing.expect_value(t, stale, "1 1 err revision_conflict current_revision=0")
	testing.expect_value(t, published_revision(b), 0)
	testing.expect_value(t, published_value(b, "filter.cutoff"), before)
	// A refused batch enqueued nothing, so a later matching one is the first.
	good := revision_request(b, "1 2 parameter.set_many expected_revision=0 filter.cutoff 11")
	testing.expect_value(t, good, "1 2 ok count=1 revision=1")
	testing.expect_value(t, published_value(b, "filter.cutoff"), 11)
}

@(test)
test_a_bad_member_rejects_the_whole_batch_even_when_the_revision_matches :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	cases := [][2]string {
		{"filter.cutoff 40 no.such.parameter 5", "err unknown_parameter"},
		{"filter.cutoff 40 filter.resonance 999999", "err out_of_range"},
		{"filter.cutoff 40 filter.resonance -1", "err out_of_range"},
		{"filter.cutoff 40 filter.resonance abc", "err invalid_payload"},
		{"filter.cutoff 40 filter.resonance 1.5", "err invalid_payload"},
		{"filter.cutoff 40 filter.resonance", "err invalid_payload"},
		{"filter.cutoff", "err invalid_payload"},
		{"", "err invalid_payload"},
	}
	for c in cases {
		line := strings.concatenate({"1 7 parameter.set_many expected_revision=0 ", c[0]}, context.temp_allocator)
		reply := revision_request(b, line)
		want := strings.concatenate({"1 7 ", c[1]}, context.temp_allocator)
		testing.expectf(t, strings.has_prefix(reply, want), "%q -> %q", c[0], reply)
		testing.expectf(t, ring_is_empty(b), "%q left something on the ring", c[0])
	}
	testing.expect_value(t, standalone.param_ring_dropped(&b.live.ring), u32(0))
}

@(test)
test_a_malformed_expected_revision_is_an_invalid_payload_and_enqueues_nothing :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	// The revision is 0. After the first four, which are no integer at all, come
	// the spellings a parser that takes a sign, a base prefix or an underscore,
	// or wraps past the largest int, reads as 0, and the ones just out of range.
	tails := []string {
		"", "abc", "-1", "1.5",
		"-0", "+0", "0x0", "0b0", "0o0", "0d0", "0_0", "_",
		"18446744073709551616", "36893488147419103232", "99999999999999999999999", "9223372036854775808",
	}
	for tail in tails {
		line := strings.concatenate({"1 3 parameter.set_many expected_revision=", tail, " filter.cutoff 40"}, context.temp_allocator)
		testing.expect_value(
			t,
			revision_request(b, line),
			"1 3 err invalid_payload expected_revision needs a nonnegative integer",
		)
		testing.expectf(t, ring_is_empty(b), "%q left something on the ring", tail)
	}
}

@(test)
test_an_expected_revision_is_the_number_its_decimal_digits_say :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	testing.expect_value(t, revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40"), "1 1 ok count=1 revision=1")
	// Each of these is 1 to a parser that wraps, or takes a prefix, a sign or an
	// underscore, so the guard would pass for a batch that names another revision.
	for tail in ([]string{"18446744073709551617", "+1", "0x1", "0b1", "0o1", "0d1", "1_", "0_1", "_1"}) {
		line := strings.concatenate({"1 2 parameter.set_many expected_revision=", tail, " filter.cutoff 90"}, context.temp_allocator)
		reply := revision_request(b, line)
		testing.expectf(t, reply == "1 2 err invalid_payload expected_revision needs a nonnegative integer", "%q -> %q", tail, reply)
	}
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 40)

	// Digits are taken as they are, leading zeros too, up to the largest int.
	testing.expect_value(t, revision_request(b, "1 3 parameter.set_many expected_revision=1 filter.cutoff 41"), "1 3 ok count=1 revision=2")
	testing.expect_value(
		t,
		revision_request(b, "1 4 parameter.set_many expected_revision=0000000000000000000000000002 filter.cutoff 42"),
		"1 4 ok count=1 revision=3",
	)
	testing.expect_value(
		t,
		revision_request(b, "1 5 parameter.set_many expected_revision=9223372036854775807 filter.cutoff 43"),
		"1 5 err revision_conflict current_revision=3",
	)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 42)
}

@(test)
test_the_expected_revision_token_belongs_to_set_many_alone :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	reply := revision_request(b, "1 4 patch.apply expected_revision=0 1 filter.cutoff 40")
	testing.expect(t, strings.has_prefix(reply, "1 4 err unknown_parameter"), reply)
	testing.expect(t, ring_is_empty(b))
}

@(test)
test_duplicate_ids_in_a_checked_batch_apply_in_order_and_the_last_wins :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	reply := revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 10 filter.resonance 3 filter.cutoff 20")
	testing.expect_value(t, reply, "1 1 ok count=3 revision=1")
	testing.expect_value(t, published_value(b, "filter.cutoff"), 20)
	testing.expect_value(t, published_value(b, "filter.resonance"), 3)
}

@(test)
test_an_edit_queued_ahead_of_a_checked_batch_makes_it_stale :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	// The legacy edit is acknowledged at once and applied by the audio thread
	// later; the checked batch queued behind it still sees its revision.
	set := revision_request(b, "1 1 parameter.set filter.cutoff 10")
	testing.expect(t, strings.has_prefix(set, "1 1 ok"), set)
	checked := revision_request(b, "1 2 parameter.set_many expected_revision=0 filter.cutoff 90")
	testing.expect_value(t, checked, "1 2 err revision_conflict current_revision=1")
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 10)

	plain := revision_request(b, "1 3 parameter.set_many filter.resonance 5")
	testing.expect(t, strings.has_prefix(plain, "1 3 ok"), plain)
	checked = revision_request(b, "1 4 parameter.set_many expected_revision=1 filter.cutoff 90")
	testing.expect_value(t, checked, "1 4 err revision_conflict current_revision=2")
	testing.expect_value(t, published_value(b, "filter.cutoff"), 10)
}

@(test)
test_every_kind_of_commit_moves_the_revision_a_checked_batch_is_held_to :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	// One knob edit, one checked batch and one whole-patch replacement: three
	// commits, three revisions, and a rejected batch is not a fourth.
	testing.expect(t, strings.has_prefix(revision_request(b, "1 1 parameter.set filter.cutoff 30"), "1 1 ok"))
	testing.expect_value(t, revision_request(b, "1 2 parameter.set_many expected_revision=1 filter.cutoff 31"), "1 2 ok count=1 revision=2")
	testing.expect(t, strings.has_prefix(revision_request(b, "1 3 patch.apply filter.cutoff 32 filter.resonance 4"), "1 3 ok"))
	testing.expect_value(t, revision_request(b, "1 4 parameter.set_many expected_revision=2 filter.cutoff 33"), "1 4 err revision_conflict current_revision=3")
	testing.expect_value(t, revision_request(b, "1 5 parameter.set_many expected_revision=3 filter.cutoff 33"), "1 5 ok count=1 revision=4")
	testing.expect_value(t, published_revision(b), 4)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 33)
	testing.expect_value(t, published_value(b, "filter.resonance"), 4)
}

@(test)
test_a_checked_batch_the_audio_side_never_reaches_reports_an_unknown_outcome :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	started := time.tick_now()
	reply := revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40 filter.resonance 20")
	elapsed := time.tick_since(started)
	testing.expect_value(t, reply, "1 1 err daemon_not_ready commit outcome unknown; inspect state before retrying")
	testing.expect(t, elapsed >= 200 * time.Millisecond && elapsed < 2 * time.Second, "the wait is bounded")

	// What was queued stays queued, in order, ended by the checked commit.
	c1, ok1 := standalone.param_ring_pop(&b.live.ring)
	c2, ok2 := standalone.param_ring_pop(&b.live.ring)
	c3, ok3 := standalone.param_ring_pop(&b.live.ring)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, c1.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, c2.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, c3.kind, standalone.Param_Command_Kind.Commit_Checked)
	testing.expect_value(t, c3.expected_revision, 0)
	testing.expect(t, ring_is_empty(b))
}

@(test)
test_an_unknown_outcome_is_real_and_a_late_completion_does_not_answer_the_next_batch :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	reply := revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40")
	testing.expect_value(t, reply, "1 1 err daemon_not_ready commit outcome unknown; inspect state before retrying")
	testing.expect_value(t, published_revision(b), 0)

	// The audio side wakes up and applies what was queued: the batch the caller
	// was told nothing sure about did take effect.
	bench_start_audio(b)
	testing.expect(t, await_revision(b, 1))
	testing.expect_value(t, published_value(b, "filter.cutoff"), 40)

	// Its late acknowledgement belongs to the first batch, so the second waits
	// for its own and is judged against the revision the first one produced.
	stale := revision_request(b, "1 2 parameter.set_many expected_revision=0 filter.cutoff 50")
	testing.expect_value(t, stale, "1 2 err revision_conflict current_revision=1")
	fresh := revision_request(b, "1 3 parameter.set_many expected_revision=1 filter.cutoff 50")
	testing.expect_value(t, fresh, "1 3 ok count=1 revision=2")
	testing.expect_value(t, published_value(b, "filter.cutoff"), 50)
}

@(test)
test_a_full_ring_refuses_a_checked_batch_whole_and_counts_the_refusal_once :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	// Leave room for two commands where the batch needs three.
	for _ in 0 ..< standalone.PARAM_RING_CAPACITY - 2 {
		standalone.param_ring_push(&b.live.ring, standalone.Param_Command{kind = .Commit})
	}
	started := time.tick_now()
	reply := revision_request(b, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40 filter.resonance 20")
	testing.expect_value(t, reply, "1 1 err daemon_not_ready control queue full")
	testing.expect(t, time.tick_since(started) < 100 * time.Millisecond, "a refusal does not wait for the audio side")
	testing.expect_value(t, standalone.param_ring_dropped(&b.live.ring), u32(1))
	testing.expect_value(t, standalone.param_ring_free_space(&b.live.ring), 2)
}

@(test)
test_set_many_without_the_token_answers_and_queues_exactly_as_before :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	reply := revision_request(b, "1 1 parameter.set_many filter.cutoff 50 filter.resonance 30")
	testing.expect_value(t, reply, "1 1 ok count=2 revision=0")
	kinds: [4]standalone.Param_Command_Kind
	n := 0
	for {
		cmd, any := standalone.param_ring_pop(&b.live.ring)
		if !any { break }
		kinds[n] = cmd.kind
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect_value(t, kinds[0], standalone.Param_Command_Kind.Set)
	testing.expect_value(t, kinds[1], standalone.Param_Command_Kind.Set)
	testing.expect_value(t, kinds[2], standalone.Param_Command_Kind.Commit)
}

@(private = "file")
checked_commit :: proc(expected, serial: int) -> standalone.Param_Command {
	return standalone.Param_Command{kind = .Commit_Checked, expected_revision = expected, serial = u64(serial)}
}

@(private = "file")
set_command :: proc(id: string, stored: int) -> standalone.Param_Command {
	d, found := registry.registry_describe(id)
	assert(found)
	return standalone.Param_Command{kind = .Set, index = i32(d.index), stored = i32(stored)}
}

@(test)
test_an_accepted_checked_commit_is_published_before_it_is_acknowledged :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	// Drained by hand, so nothing but live_drain_control can have published the
	// snapshot a reader sees once the acknowledgement is visible.
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 41))
	standalone.param_ring_push(&b.live.ring, checked_commit(0, 1))
	standalone.live_drain_control(b.live)
	testing.expect_value(t, intrinsics.atomic_load(&b.live.ring.completed_serial), u64(1))
	testing.expect(t, b.live.ring.completed_applied)
	testing.expect_value(t, b.live.ring.completed_revision, 1)
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 41)
}

@(test)
test_a_refused_checked_commit_publishes_the_revision_it_reports :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 12))
	standalone.param_ring_push(&b.live.ring, standalone.Param_Command{kind = .Commit})
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 99))
	standalone.param_ring_push(&b.live.ring, checked_commit(0, 1))
	standalone.live_drain_control(b.live)
	testing.expect_value(t, intrinsics.atomic_load(&b.live.ring.completed_serial), u64(1))
	testing.expect(t, !b.live.ring.completed_applied)
	testing.expect_value(t, b.live.ring.completed_revision, 1)
	// The revision in the refusal is one a reader can see, with the edit that
	// beat the refused batch and without the batch.
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 12)
}
