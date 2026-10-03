#+build linux
package standalone_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import control "../../src/control"
import "../../src/engine"
import patch "../../src/patch"
import "../../src/registry"
import standalone "../../hosts/standalone"

// patch.save stores what every edit sent ahead of it made of the sound, even
// one the audio thread has not applied yet. The control thread answers a
// parameter.set as soon as it is queued, so a client that sets a value and
// saves straight after -- the TUI does, the browser does -- must not get the
// value from before the set in its slot. These drive the real control server
// over a Unix socket and the real live_render, called by the test in place of
// the audio device, so the test decides when the audio side runs: the edits
// are queued and the save is waiting before any of them is applied.

@(private = "file")
SAVE_BLOCK :: 64

@(private = "file")
Save_Bench :: struct {
	live:     standalone.Live,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	state:    standalone.Daemon_State,
	out:      [SAVE_BLOCK * 2]f32,
	server:   standalone.Control_Server,
	client:   posix.FD,
}

@(private = "file")
save_bench_count: u32

@(private = "file")
save_bench_make :: proc() -> ^Save_Bench {
	b := new(Save_Bench)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	engine.engine_load_patch(&b.live.eng, p, 48000)
	b.live.left = make([]f32, SAVE_BLOCK)
	b.live.right = make([]f32, SAVE_BLOCK)
	b.live.volume.milli = standalone.VOLUME_UNITY
	b.live.volume_prev = standalone.VOLUME_UNITY
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(engine.engine_patch_value(&b.live.eng, i))}
	standalone.snapshot_publish(&b.live.snapshot, seed)
	patch.factory_prepare()
	patch.slots_load_factory(&b.bank)
	b.identity = standalone.Patch_Identity{slot = -1}
	b.state = .Running
	b.server.path = fmt.aprintf("/tmp/quesynth-save-%d-%d.sock", posix.getpid(), intrinsics.atomic_add(&save_bench_count, 1))
	b.server.ctx = standalone.Control_Context {
		ring     = &b.live.ring,
		snapshot = &b.live.snapshot,
		state    = &b.state,
		bank     = &b.bank,
		identity = &b.identity,
	}
	assert(standalone.control_server_start(&b.server))
	ok: bool
	b.client, ok = connect_unix(b.server.path)
	assert(ok)
	return b
}

@(private = "file")
save_bench_free :: proc(b: ^Save_Bench) {
	posix.close(b.client)
	standalone.control_server_stop(&b.server)
	posix.unlink(strings.clone_to_cstring(fmt.tprintf("%s.lock", b.server.path), context.temp_allocator))
	delete(b.server.path)
	engine.engine_destroy(&b.live.eng)
	delete(b.live.left)
	delete(b.live.right)
	free(b)
}

// One audio block, which is when the queued edits are applied and published.
@(private = "file")
audio_block :: proc(b: ^Save_Bench) {
	standalone.live_render(&b.live, raw_data(b.out[:]), SAVE_BLOCK, 2)
}

// Several requests in one write, so the server reads and handles them in one
// pass, the save straight after the edit with no audio block between them.
@(private = "file")
send_all :: proc(fd: posix.FD, lines: ..string) {
	wire := make([dynamic]u8, context.temp_allocator)
	for line in lines {
		n := len(line)
		append(&wire, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(&wire, ..transmute([]u8)line)
	}
	posix.send(fd, raw_data(wire[:]), c.size_t(len(wire)), {.NOSIGNAL})
}

// Wait until the server has queued `commands` on the ring, then a little
// longer, so the save sent with them has been handled before anything is
// applied: the edit is queued and not applied when the save is taken.
@(private = "file")
await_handled :: proc(b: ^Save_Bench, commands: int) -> bool {
	for _ in 0 ..< 1000 {
		if standalone.PARAM_RING_CAPACITY - standalone.param_ring_free_space(&b.live.ring) >= commands {
			time.sleep(30 * time.Millisecond)
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

@(private = "file")
pending_reply :: proc(fd: posix.FD, limit: time.Duration) -> (string, bool) {
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	if posix.poll(&fds[0], 1, c.int(limit / time.Millisecond)) <= 0 {return "", false}
	reply := reliability_reply(fd)
	return reply, reply != "TIMEOUT/CLOSED"
}

@(private = "file")
index_of :: proc(id: string) -> int {
	d, found := registry.registry_describe(id)
	assert(found)
	return d.index
}

@(private = "file")
raw_ask :: proc(fd: posix.FD, line: string) -> string {
	reliability_send(fd, line)
	return reliability_reply(fd)
}

@(private = "file")
NOT_SAVED :: "err daemon_not_ready earlier edits not applied; nothing saved"

@(test)
test_a_save_straight_after_a_set_stores_the_new_value :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)
	cutoff := index_of("filter.cutoff")
	testing.expect(t, b.bank.values[120][cutoff] != 77)

	// A read behind the save is answered after it, in order.
	send_all(b.client, "1 1 parameter.set filter.cutoff 77", "1 2 patch.save 120 Lead", "1 3 patch.current")
	if !testing.expect(t, await_handled(b, 2)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=77 revision=0")
	audio_block(b)

	testing.expect_value(t, reliability_reply(b.client), "1 2 ok slot=120 name=Lead bank_rev=1")
	testing.expect_value(t, b.bank.values[120][cutoff], 77)
	// The set moved the revision once; the save did not move it.
	testing.expect_value(
		t,
		reliability_reply(b.client),
		"1 3 ok slot=120 bank_rev=1 revision=1 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Factory\nname=Lead",
	)
	testing.expect_value(t, standalone.snapshot_read(&b.live.snapshot).revision, 1)
}

@(test)
test_a_save_straight_after_a_batch_an_apply_or_a_load_stores_it :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)
	cutoff := index_of("filter.cutoff")
	resonance := index_of("filter.resonance")

	send_all(b.client, "1 1 parameter.set_many filter.cutoff 11 filter.resonance 22", "1 2 patch.save 121 Batch")
	if !testing.expect(t, await_handled(b, 3)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok count=2 revision=0")
	audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 2 ok slot=121 name=Batch bank_rev=1")
	testing.expect_value(t, b.bank.values[121][cutoff], 11)
	testing.expect_value(t, b.bank.values[121][resonance], 22)

	send_all(b.client, "1 3 patch.apply filter.cutoff 33", "1 4 patch.save 122 Applied")
	if !testing.expect(t, await_handled(b, 2)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 3 ok count=1 revision=1")
	audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 4 ok slot=122 name=Applied bank_rev=2")
	testing.expect_value(t, b.bank.values[122][cutoff], 33)
	testing.expect_value(t, b.bank.values[122][resonance], 22)

	// A slot load replaces every parameter; the save takes all of them.
	k := -1
	for i in 0 ..< patch.FACTORY_SLOTS {
		if b.bank.filled[i] && b.bank.values[i][cutoff] != 33 {k = i; break}
	}
	if !testing.expect(t, k >= 0) {return}
	want := b.bank.values[k]
	send_all(b.client, fmt.tprintf("1 5 patch.load %d", k), "1 6 patch.save 123 Loaded")
	if !testing.expect(t, await_handled(b, patch.PARAMETER_COUNT + 1)) {return}
	testing.expect(t, strings.has_prefix(reliability_reply(b.client), "1 5 ok"))
	audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 6 ok slot=123 name=Loaded bank_rev=3")
	testing.expect_value(t, b.bank.values[123], want)
	testing.expect_value(t, standalone.snapshot_read(&b.live.snapshot).revision, 3)
}

@(test)
test_a_save_on_one_connection_stores_a_set_from_another :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)
	cutoff := index_of("filter.cutoff")
	peer, connected := connect_unix(b.server.path)
	if !testing.expect(t, connected) {return}
	defer posix.close(peer)

	// The set is acknowledged, so it was queued before the save is sent.
	reliability_send(peer, "1 1 parameter.set filter.cutoff 55")
	testing.expect_value(t, reliability_reply(peer), "1 1 ok value=55 revision=0")
	reliability_send(b.client, "1 1 patch.save 120 From Peer")
	time.sleep(30 * time.Millisecond)

	// While the save waits, the peer is served as usual, and nothing is saved
	// yet; a save of its own waits behind the same edit.
	reliability_send(peer, "1 2 patch.current")
	testing.expect_value(
		t,
		reliability_reply(peer),
		"1 2 ok slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
	)
	reliability_send(peer, "1 3 patch.save 121 Peer Own")
	time.sleep(30 * time.Millisecond)

	audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok slot=120 name=From_Peer bank_rev=1")
	testing.expect_value(t, reliability_reply(peer), "1 3 ok slot=121 name=Peer_Own bank_rev=2")
	testing.expect_value(t, b.bank.values[120][cutoff], 55)
	testing.expect_value(t, b.bank.values[121][cutoff], 55)
}

@(test)
test_a_full_ring_does_not_refuse_a_save :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)
	cutoff := index_of("filter.cutoff")

	// Two batches of 127 pairs and their commits fill the ring; a third edit
	// is refused for room and counted once.
	pairs := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 127 {fmt.sbprintf(&pairs, " filter.cutoff %d", i)}
	batch := strings.to_string(pairs)
	testing.expect_value(t, raw_ask(b.client, fmt.tprintf("1 1 parameter.set_many%s", batch)), "1 1 ok count=127 revision=0")
	testing.expect_value(t, raw_ask(b.client, fmt.tprintf("1 2 parameter.set_many%s", batch)), "1 2 ok count=127 revision=0")
	testing.expect_value(t, raw_ask(b.client, "1 3 parameter.set filter.cutoff 99"), "1 3 err daemon_not_ready control queue full")
	testing.expect_value(t, standalone.param_ring_free_space(&b.live.ring), 0)

	reliability_send(b.client, "1 4 patch.save 120 Full")
	_, early := pending_reply(b.client, 30 * time.Millisecond)
	testing.expect(t, !early, "the save was answered before the edits ahead of it were applied")
	audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 4 ok slot=120 name=Full bank_rev=1")
	testing.expect_value(t, b.bank.values[120][cutoff], 126)
	testing.expect_value(t, standalone.param_ring_dropped(&b.live.ring), 1)
}

@(test)
test_a_save_whose_edits_are_not_applied_in_time_saves_nothing :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)
	cutoff := index_of("filter.cutoff")
	before := b.bank.values[120]

	started := time.tick_now()
	send_all(b.client, "1 1 parameter.set filter.cutoff 66", "1 2 patch.save 120 Late")
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=66 revision=0")
	reply, arrived := pending_reply(b.client, 2 * time.Second)
	waited := time.tick_since(started)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, strings.concatenate({"1 2 ", NOT_SAVED}, context.temp_allocator))
	testing.expectf(t, waited >= 200 * time.Millisecond, "refused after %v, before the audio thread had its time", waited)

	// Nothing was stored or named, then or once the edit is applied.
	audio_block(b)
	testing.expect_value(t, raw_ask(b.client, "1 3 parameter.get filter.cutoff"), "1 3 ok value=66 revision=1")
	testing.expect(t, !b.bank.filled[120])
	testing.expect_value(t, b.bank.values[120], before)
	testing.expect(t, b.bank.values[120][cutoff] != 66)
	testing.expect_value(
		t,
		raw_ask(b.client, "1 4 patch.current"),
		"1 4 ok slot=-1 bank_rev=0 revision=1 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
	)
}

@(test)
test_a_save_waiting_when_the_server_stops_saves_nothing :: proc(t: ^testing.T) {
	b := save_bench_make()
	defer save_bench_free(b)

	send_all(b.client, "1 1 parameter.set filter.cutoff 44", "1 2 patch.save 120 Stopped", "1 3 patch.current")
	if !testing.expect(t, await_handled(b, 2)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=44 revision=0")
	_, early := pending_reply(b.client, 0)
	testing.expect(t, !early, "the save was answered before the edit ahead of it was applied")

	started := time.tick_now()
	standalone.control_server_stop(&b.server)
	stopping := time.tick_since(started)
	testing.expectf(t, stopping < 200 * time.Millisecond, "stopping took %v, as if it waited out the save", stopping)

	// One answer, and then the connection ends: the read behind the save is
	// not answered.
	reply, arrived := pending_reply(b.client, time.Second)
	testing.expect(t, arrived, "the connection closed without the answer it was owed")
	testing.expect_value(t, reply, strings.concatenate({"1 2 ", NOT_SAVED}, context.temp_allocator))
	testing.expect(t, reliability_hung_up(b.client, time.Second), "something followed the one answer")
	testing.expect(t, !b.bank.filled[120])
	testing.expect_value(t, b.identity.bank_rev, 0)
}

// Without a ring there is nothing queued to wait for: a bare handler saves at
// once from the snapshot, as it always did.
@(test)
test_a_handler_without_a_ring_saves_at_once :: proc(t: ^testing.T) {
	bank := new(patch.Slots)
	defer free(bank)
	patch.factory_prepare()
	patch.slots_load_factory(bank)
	snap: standalone.Snapshot
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(i % 5)}
	standalone.snapshot_publish(&snap, seed)
	state := standalone.Daemon_State.Running
	cc := standalone.Control_Context{snapshot = &snap, state = &state, bank = bank}

	line := "1 1 patch.save 7 Bare"
	req, parsed := control.request_parse(transmute([]u8)line)
	if !testing.expect(t, parsed) {return}
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(&cc, req, &out)
	testing.expect_value(t, strings.to_string(out), "1 1 ok slot=7 name=Bare")
	for i in 0 ..< patch.PARAMETER_COUNT {testing.expect_value(t, bank.values[7][i], i32(i % 5))}
}
