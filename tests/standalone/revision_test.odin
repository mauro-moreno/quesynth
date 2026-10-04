#+build linux
package standalone_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
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
// to the state its sender saw. These drive the real control server over a real
// Unix socket, the real ring and the real transaction path of live_render; the
// audio thread is a stand-in that only calls live_render in a loop, or is left
// out to hold the ring still.

@(private = "file")
Revision_Bench :: struct {
	live:   ^standalone.Live,
	state:  standalone.Daemon_State,
	server: standalone.Control_Server,
	// The connection requests go over unless a test opens more. -1 once closed,
	// or when there is no server.
	client: posix.FD,
	done:   b32,
	audio:  ^thread.Thread,
}

@(private = "file")
bench_count: u32

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
// Without `serving` there is no control server, for the tests that call
// control_handle or drain the ring by hand.
@(private = "file")
bench_make :: proc(draining := true, serving := true) -> ^Revision_Bench {
	b := new(Revision_Bench)
	b.live = new(standalone.Live)
	b.client = -1
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT { p.values[i] = patch.PARAMETERS[i].default }
	engine.engine_load_patch(&b.live.eng, p, 48000)
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT { seed.values[i] = i32(engine.engine_patch_value(&b.live.eng, i)) }
	standalone.snapshot_publish(&b.live.snapshot, seed)
	b.state = .Running
	if serving {
		b.server.path = fmt.aprintf("/tmp/quesynth-revision-%d-%d.sock", posix.getpid(), intrinsics.atomic_add(&bench_count, 1))
		b.server.ctx = standalone.Control_Context{ring = &b.live.ring, snapshot = &b.live.snapshot, state = &b.state}
		assert(standalone.control_server_start(&b.server))
		ok: bool
		b.client, ok = connect_unix(b.server.path)
		assert(ok)
	}
	if draining { bench_start_audio(b) }
	return b
}

@(private = "file")
bench_start_audio :: proc(b: ^Revision_Bench) {
	b.audio = thread.create_and_start_with_data(b, revision_audio)
}

@(private = "file")
bench_free :: proc(b: ^Revision_Bench) {
	if b.client >= 0 { posix.close(b.client) }
	if b.server.path != "" {
		standalone.control_server_stop(&b.server)
		lock := strings.clone_to_cstring(fmt.tprintf("%s.lock", b.server.path), context.temp_allocator)
		posix.unlink(lock)
		delete(b.server.path)
	}
	if b.audio != nil {
		intrinsics.atomic_store(&b.done, true)
		thread.join(b.audio)
		thread.destroy(b.audio)
	}
	engine.engine_destroy(&b.live.eng)
	free(b.live)
	free(b)
}

// One request on the bench's own connection, and its reply.
@(private = "file")
revision_request :: proc(b: ^Revision_Bench, line: string) -> string {
	return ask(b.client, line)
}

@(private = "file")
ask :: proc(fd: posix.FD, line: string) -> string {
	reliability_send(fd, line)
	return reliability_reply(fd)
}

// The reply, if one arrives within the limit. It does not wait for more than the
// first bytes: a reply is a few dozen of them, written at once.
@(private = "file")
reply_within :: proc(fd: posix.FD, limit: time.Duration) -> (reply: string, arrived: bool) {
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	if posix.poll(&fds[0], 1, c.int(limit / time.Millisecond)) <= 0 { return "", false }
	reply = reliability_reply(fd)
	return reply, reply != "TIMEOUT/CLOSED"
}

// Several requests in one write, as a pipelining client sends them.
@(private = "file")
send_together :: proc(fd: posix.FD, lines: ..string) {
	wire := make([dynamic]u8, context.temp_allocator)
	for line in lines {
		n := len(line)
		append(&wire, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(&wire, ..transmute([]u8)line)
	}
	posix.send(fd, raw_data(wire[:]), c.size_t(len(wire)), {.NOSIGNAL})
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

// What the audio thread has told the control thread about a checked commit.
@(private = "file")
next_result :: proc(b: ^Revision_Bench) -> (standalone.Checked_Result, bool) {
	return standalone.param_ring_take_result(&b.live.ring)
}

@(test)
test_an_accepted_checked_commit_is_published_before_it_is_acknowledged :: proc(t: ^testing.T) {
	b := bench_make(draining = false, serving = false)
	defer bench_free(b)
	// Drained by hand, so nothing but live_drain_control can have published the
	// snapshot a reader sees once the acknowledgement is visible.
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 41))
	standalone.param_ring_push(&b.live.ring, checked_commit(0, 1))
	standalone.live_drain_control(b.live)
	result, answered := next_result(b)
	testing.expect(t, answered)
	testing.expect_value(t, result, standalone.Checked_Result{serial = 1, revision = 1, applied = true})
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 41)
	_, another := next_result(b)
	testing.expect(t, !another, "one commit, one answer")
}

@(test)
test_a_refused_checked_commit_publishes_the_revision_it_reports :: proc(t: ^testing.T) {
	b := bench_make(draining = false, serving = false)
	defer bench_free(b)
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 12))
	standalone.param_ring_push(&b.live.ring, standalone.Param_Command{kind = .Commit})
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 99))
	standalone.param_ring_push(&b.live.ring, checked_commit(0, 1))
	standalone.live_drain_control(b.live)
	result, answered := next_result(b)
	testing.expect(t, answered)
	testing.expect_value(t, result, standalone.Checked_Result{serial = 1, revision = 1, applied = false})
	// The revision in the refusal is one a reader can see, with the edit that
	// beat the refused batch and without the batch.
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 12)
}

@(test)
test_signed_zero_padded_parameter_values_keep_their_decimal_meaning :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	for command in ([]string{"parameter.set", "parameter.set_many", "parameter.set_many expected_revision=0", "patch.apply"}) {
		for value in ([]string{"0", "-0", "00000000000000000000000", "-00000000000000000000000", "-0005", "0005"}) {
			prefix := command
			if strings.contains(command, "expected_revision=") {
				prefix = fmt.tprintf("parameter.set_many expected_revision=%d", published_revision(b))
			}
			line := fmt.tprintf("1 9 %s osc.key_shift %s", prefix, value)
			revision := published_revision(b)
			reply := revision_request(b, line)
			testing.expectf(t, strings.has_prefix(reply, "1 9 ok"), "%s -> %s", line, reply)
			testing.expect(t, await_revision(b, revision + 1))
			want := strings.contains(value, "5") ? (value[0] == '-' ? -5 : 5) : 0
			testing.expect_value(t, published_value(b, "osc.key_shift"), want)
		}
	}
}

// What follows is the daemon's answer to a guarded batch while the audio thread
// is slow, absent or beaten to it. The control server must go on serving every
// other client the whole time, answer each guarded one only once the audio thread
// has decided, and let a late answer die with its request.

@(private = "file")
BATCH :: "parameter.set_many expected_revision=0 filter.cutoff 40 filter.resonance 20"

@(private = "file")
UNKNOWN :: "err daemon_not_ready commit outcome unknown; inspect state before retrying"

// Wait until the control thread has put `commands` on the ring in all, so the
// order in which two clients' batches were queued does not rest on scheduling.
@(private = "file")
await_queued :: proc(b: ^Revision_Bench, commands: int) -> bool {
	for _ in 0 ..< 1000 {
		if standalone.PARAM_RING_CAPACITY - standalone.param_ring_free_space(&b.live.ring) == commands { return true }
		time.sleep(time.Millisecond)
	}
	return false
}

@(private = "file")
answered_promptly :: proc(t: ^testing.T, fd: posix.FD, line, want_prefix: string) -> string {
	started := time.tick_now()
	reply := ask(fd, line)
	elapsed := time.tick_since(started)
	testing.expectf(t, strings.has_prefix(reply, want_prefix), "%s -> %s", line, reply)
	testing.expectf(t, elapsed < 100 * time.Millisecond, "%s took %v while a guarded batch was pending", line, elapsed)
	return reply
}

@(test)
test_a_pending_guarded_batch_does_not_hold_up_other_clients :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	other, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(other)

	reliability_send(b.client, strings.concatenate({"1 1 ", BATCH}, context.temp_allocator))
	if !testing.expect(t, await_queued(b, 3)) { return }

	// The audio thread has not looked at the batch, so its sender has no answer
	// and nobody else is made to wait for one.
	answered_promptly(t, other, "1 2 daemon.status", "1 2 ok")
	snapshot := answered_promptly(t, other, "1 3 state.snapshot", "1 3 ok revision=0")
	testing.expect(t, !strings.contains(snapshot, "id=filter.cutoff value=40\n"), "the batch is not applied yet")
	answered_promptly(t, other, "1 4 parameter.get filter.cutoff", "1 4 ok")
	_, early := reply_within(b.client, 0)
	testing.expect(t, !early, "the guarded request is answered only when the audio thread has decided")

	bench_start_audio(b)
	reply, arrived := reply_within(b.client, time.Second)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, "1 1 ok count=2 revision=1")

	snapshot = ask(other, "1 5 state.snapshot")
	testing.expect(t, strings.has_prefix(snapshot, "1 5 ok revision=1"), snapshot)
	testing.expect(t, strings.contains(snapshot, "id=filter.cutoff value=40\n"), snapshot)
	testing.expect(t, strings.contains(snapshot, "id=filter.resonance value=20\n"), snapshot)
}

@(test)
test_two_pending_guarded_batches_are_each_answered_for_themselves :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	second, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(second)

	// Both name revision 0 and both are queued before the audio thread looks at
	// either, so one of them wins and the other is judged against what it made.
	reliability_send(b.client, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40")
	if !testing.expect(t, await_queued(b, 2)) { return }
	reliability_send(second, "1 2 parameter.set_many expected_revision=0 filter.cutoff 50 filter.resonance 7")
	if !testing.expect(t, await_queued(b, 5)) { return }
	_, early := reply_within(second, 0)
	testing.expect(t, !early)

	bench_start_audio(b)
	first_reply, first_arrived := reply_within(b.client, time.Second)
	second_reply, second_arrived := reply_within(second, time.Second)
	testing.expect(t, first_arrived && second_arrived)
	testing.expect_value(t, first_reply, "1 1 ok count=1 revision=1")
	testing.expect_value(t, second_reply, "1 2 err revision_conflict current_revision=1")
	testing.expect_value(t, published_revision(b), 1)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 40)
	resonance, _ := registry.registry_describe("filter.resonance")
	testing.expect_value(t, published_value(b, "filter.resonance"), registry.registry_default(resonance))
}

@(test)
test_a_guarded_batch_that_the_audio_thread_never_answers_times_out_while_others_are_served :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	other, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(other)

	sent := time.tick_now()
	reliability_send(b.client, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40")
	// Served all through the wait, which lasts a quarter of a second.
	for time.tick_since(sent) < 200 * time.Millisecond {
		answered_promptly(t, other, "1 2 daemon.status", "1 2 ok")
		time.sleep(20 * time.Millisecond)
	}
	reply, arrived := reply_within(b.client, time.Second)
	waited := time.tick_since(sent)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, strings.concatenate({"1 1 ", UNKNOWN}, context.temp_allocator))
	testing.expect(t, waited >= 250 * time.Millisecond, "the outcome is not called unknown before the wait is over")
	testing.expect(t, waited < time.Second, "and is called unknown once it is")

	// The batch is still queued, and the requests that follow are queued behind
	// it: one on the connection that gave up, naming the revision before the
	// batch, and one on the other, naming the revision after it.
	reliability_send(b.client, "1 3 parameter.set_many expected_revision=0 filter.cutoff 50")
	if !testing.expect(t, await_queued(b, 4)) { return }
	reliability_send(other, "1 4 parameter.set_many expected_revision=1 filter.cutoff 60")
	if !testing.expect(t, await_queued(b, 6)) { return }

	// The audio thread comes at last. It applies the batch the first request was
	// told nothing sure about, and its answer, which is the first one waiting on
	// the results queue, goes to nobody: each of the others gets its own.
	bench_start_audio(b)
	reply, arrived = reply_within(b.client, time.Second)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, "1 3 err revision_conflict current_revision=1")
	reply, arrived = reply_within(other, time.Second)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, "1 4 ok count=1 revision=2")
	testing.expect_value(t, published_revision(b), 2)
	testing.expect_value(t, published_value(b, "filter.cutoff"), 60)
	_, stray := reply_within(b.client, 100 * time.Millisecond)
	testing.expect(t, !stray, "the late answer reached the connection that gave up on it")
	_, stray = reply_within(other, 0)
	testing.expect(t, !stray, "the late answer reached another connection")
	testing.expect_value(t, ask(b.client, "1 5 parameter.get filter.cutoff"), "1 5 ok value=60 revision=2")
}

@(test)
test_a_request_pipelined_behind_a_guarded_batch_is_answered_after_it_in_order :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	send_together(b.client, "1 1 parameter.set_many expected_revision=0 filter.cutoff 40", "1 2 parameter.get filter.cutoff")
	if !testing.expect(t, await_queued(b, 2)) { return }

	// The read behind the guarded request is not answered ahead of it, from the
	// state before the batch.
	_, early := reply_within(b.client, 100 * time.Millisecond)
	testing.expect(t, !early, "a request behind a pending one was answered first")

	bench_start_audio(b)
	first, first_arrived := reply_within(b.client, time.Second)
	second, second_arrived := reply_within(b.client, time.Second)
	testing.expect(t, first_arrived && second_arrived)
	testing.expect_value(t, first, "1 1 ok count=1 revision=1")
	testing.expect_value(t, second, "1 2 ok value=40 revision=1")
}

@(test)
test_pipelined_guarded_batches_wait_one_after_the_other :: proc(t: ^testing.T) {
	b := bench_make()
	defer bench_free(b)
	// The second guarded request waits for the first to be answered, and so names
	// the revision the first made; the reads between are answered in turn.
	send_together(
		b.client,
		"1 1 parameter.set_many expected_revision=0 filter.cutoff 40",
		"1 2 parameter.get filter.cutoff",
		"1 3 parameter.set_many expected_revision=1 filter.cutoff 41",
		"1 4 parameter.set_many expected_revision=1 filter.cutoff 42",
		"1 5 parameter.get filter.cutoff",
	)
	for want in ([]string{
		"1 1 ok count=1 revision=1",
		"1 2 ok value=40 revision=1",
		"1 3 ok count=1 revision=2",
		"1 4 err revision_conflict current_revision=2",
		"1 5 ok value=41 revision=2",
	}) {
		reply, arrived := reply_within(b.client, time.Second)
		testing.expect(t, arrived)
		testing.expect_value(t, reply, want)
	}
}

@(test)
test_a_client_that_hangs_up_while_its_batch_is_pending_leaves_the_daemon_serving :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	reliability_send(b.client, strings.concatenate({"1 1 ", BATCH}, context.temp_allocator))
	if !testing.expect(t, await_queued(b, 3)) { return }
	posix.close(b.client)
	b.client = -1

	// The slot the first client held goes to the next one that connects.
	next, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(next)
	answered_promptly(t, next, "1 2 daemon.status", "1 2 ok")

	// The batch was queued, so it applies; its answer has nobody to go to, and
	// does not go to the client that took the slot over.
	bench_start_audio(b)
	testing.expect(t, await_revision(b, 1))
	testing.expect_value(t, published_value(b, "filter.cutoff"), 40)
	_, stray := reply_within(next, 100 * time.Millisecond)
	testing.expect(t, !stray, "the answer to a client that left reached another")
	testing.expect_value(t, ask(next, "1 3 parameter.set_many expected_revision=1 filter.cutoff 41"), "1 3 ok count=1 revision=2")
	testing.expect_value(t, ask(next, "1 4 parameter.get filter.cutoff"), "1 4 ok value=41 revision=2")
}

@(test)
test_a_guarded_batch_pending_when_another_client_shuts_the_daemon_down_still_gets_its_answer :: proc(t: ^testing.T) {
	b := bench_make(draining = false)
	defer bench_free(b)
	other, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) { return }
	defer posix.close(other)

	// The audio thread has not reached the batch, and a read waits behind it.
	send_together(b.client, strings.concatenate({"1 1 ", BATCH}, context.temp_allocator), "1 2 parameter.get filter.cutoff")
	if !testing.expect(t, await_queued(b, 3)) { return }

	// Another client stops the daemon and is answered at once.
	shutdown := answered_promptly(t, other, "1 9 daemon.shutdown", "1 9 ok")
	testing.expect_value(t, shutdown, "1 9 ok")
	testing.expect(t, standalone.shutdown_requested(), "daemon.shutdown raises the flag the main thread waits on")
	_, early := reply_within(b.client, 0)
	testing.expect(t, !early, "the guarded request was answered before anything decided it")

	// What run_daemon's main thread does once it sees the flag.
	started := time.tick_now()
	standalone.control_server_stop(&b.server)
	stopping := time.tick_since(started)
	testing.expectf(t, stopping < 200 * time.Millisecond, "stopping took %v, as if it waited out the batch", stopping)

	// The client is told the outcome is unknown, once, and then the connection
	// ends: the read behind the batch is not answered.
	reply, arrived := reply_within(b.client, time.Second)
	testing.expect(t, arrived, "the connection closed without the answer it was owed")
	testing.expect_value(t, reply, strings.concatenate({"1 1 ", UNKNOWN}, context.temp_allocator))
	testing.expect(t, reliability_hung_up(b.client, time.Second), "something followed the one answer")

	// Which is true: the batch is still queued, whole, for the audio thread.
	c1, ok1 := standalone.param_ring_pop(&b.live.ring)
	c2, ok2 := standalone.param_ring_pop(&b.live.ring)
	c3, ok3 := standalone.param_ring_pop(&b.live.ring)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, c1.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, c2.kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, c3.kind, standalone.Param_Command_Kind.Commit_Checked)
	testing.expect(t, ring_is_empty(b))
}

@(test)
test_control_handle_returns_at_once_for_a_guarded_batch_and_leaves_its_reply_to_the_ticket :: proc(t: ^testing.T) {
	b := bench_make(draining = false, serving = false)
	defer bench_free(b)
	cc := standalone.Control_Context{ring = &b.live.ring, snapshot = &b.live.snapshot, state = &b.state}
	line := "1 7 " + BATCH
	req, parsed := control.request_parse(transmute([]u8)line)
	if !testing.expect(t, parsed) { return }
	out := strings.builder_make(context.temp_allocator)

	started := time.tick_now()
	ticket := standalone.control_handle(&cc, req, &out)
	elapsed := time.tick_since(started)
	testing.expect(t, elapsed < 50 * time.Millisecond, "control_handle waited for the audio thread")
	testing.expect_value(t, ticket, standalone.Wait_Ticket{serial = 1, count = 2})
	testing.expect_value(t, strings.builder_len(out), 0)

	// The batch is on the ring, in order, ended by the commit that names the ticket.
	kinds: [4]standalone.Param_Command
	n := 0
	for {
		cmd, any := standalone.param_ring_pop(&b.live.ring)
		if !any { break }
		kinds[n] = cmd
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect_value(t, kinds[0].kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, kinds[1].kind, standalone.Param_Command_Kind.Set)
	testing.expect_value(t, kinds[2], standalone.Param_Command{kind = .Commit_Checked, expected_revision = 0, serial = 1})

	// Every other outcome is the reply, written at once, with nothing pending.
	for c in ([][2]string{
		{"1 8 parameter.set_many expected_revision=0 filter.cutoff 999999", "1 8 err out_of_range value out of range"},
		{"1 9 parameter.set_many expected_revision=0 filter.cutoff 0x5", "1 9 err invalid_payload value is not an integer"},
		{"1 10 parameter.set_many expected_revision=x filter.cutoff 5", "1 10 err invalid_payload expected_revision needs a nonnegative integer"},
		{"1 11 parameter.set_many filter.cutoff 5", "1 11 ok count=1 revision=0"},
	}) {
		again, ok := control.request_parse(transmute([]u8)c[0])
		testing.expect(t, ok)
		reply := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, standalone.control_handle(&cc, again, &reply), standalone.Wait_Ticket{})
		testing.expect_value(t, strings.to_string(reply), c[1])
	}

	// With no audio there is nobody to wait for, and a full ring takes no more.
	cc.ring = nil
	req, parsed = control.request_parse(transmute([]u8)line)
	testing.expect(t, parsed)
	out = strings.builder_make(context.temp_allocator)
	testing.expect_value(t, standalone.control_handle(&cc, req, &out), standalone.Wait_Ticket{})
	testing.expect_value(t, strings.to_string(out), "1 7 err daemon_not_ready no audio")
}

@(test)
test_a_refused_batch_changes_nothing_and_an_accepted_one_is_published_once_in_order :: proc(t: ^testing.T) {
	b := bench_make(draining = false, serving = false)
	defer bench_free(b)
	cc := standalone.Control_Context{ring = &b.live.ring, snapshot = &b.live.snapshot, state = &b.state}
	handle :: proc(cc: ^standalone.Control_Context, line: string) -> (standalone.Wait_Ticket, control.Request) {
		req, parsed := control.request_parse(transmute([]u8)line)
		assert(parsed)
		out := strings.builder_make(context.temp_allocator)
		return standalone.control_handle(cc, req, &out), req
	}
	published :: proc(b: ^Revision_Bench) -> u32 {
		return intrinsics.atomic_load(&b.live.snapshot.seq) / 2
	}

	// A plain edit takes the revision to 1, so the first guarded batch is stale.
	standalone.param_ring_push(&b.live.ring, set_command("filter.cutoff", 12))
	standalone.param_ring_push(&b.live.ring, standalone.Param_Command{kind = .Commit})
	stale, stale_req := handle(&cc, "1 1 parameter.set_many expected_revision=0 filter.cutoff 90 filter.resonance 91 filter.cutoff 92")
	standalone.live_drain_control(b.live)
	before := standalone.snapshot_read(&b.live.snapshot)
	testing.expect_value(t, before.revision, 1)

	result, answered := next_result(b)
	testing.expect(t, answered)
	testing.expect_value(t, result.serial, stale.serial)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_write_checked_reply(&out, stale_req, stale, result)
	testing.expect_value(t, strings.to_string(out), "1 1 err revision_conflict current_revision=1")
	// Nothing of the refused batch is anywhere a reader can see it.
	d_cutoff, _ := registry.registry_describe("filter.cutoff")
	d_reso, _ := registry.registry_describe("filter.resonance")
	testing.expect_value(t, before.values[d_cutoff.index], 12)
	testing.expect_value(t, before.values[d_reso.index], i32(registry.registry_default(d_reso)))

	// The accepted batch lands whole, as one revision and one publication, with
	// its repeated id applied in order.
	accepted, accepted_req := handle(&cc, "1 2 parameter.set_many expected_revision=1 filter.cutoff 10 filter.resonance 3 filter.cutoff 20")
	seen := published(b)
	standalone.live_drain_control(b.live)
	testing.expect_value(t, published(b), seen + 1)
	result, answered = next_result(b)
	testing.expect(t, answered)
	testing.expect_value(t, result.serial, accepted.serial)
	out = strings.builder_make(context.temp_allocator)
	standalone.control_write_checked_reply(&out, accepted_req, accepted, result)
	testing.expect_value(t, strings.to_string(out), "1 2 ok count=3 revision=2")
	after := standalone.snapshot_read(&b.live.snapshot)
	testing.expect_value(t, after.revision, 2)
	testing.expect_value(t, after.values[d_cutoff.index], 20)
	testing.expect_value(t, after.values[d_reso.index], 3)
	for v, i in after.values {
		if i != d_cutoff.index && i != d_reso.index { testing.expectf(t, v == before.values[i], "parameter %d changed", i) }
	}
}
