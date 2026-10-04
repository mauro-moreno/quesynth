#+build linux
package standalone_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import control "../../src/control"
import "../../src/engine"
import patch "../../src/patch"
import "../../src/registry"
import standalone "../../hosts/standalone"

// A saved patch must still be there after the daemon restarts, whichever
// front-end saved it. patch.save used to change only the daemon's memory, so
// every client had to remember to ask for bank.keep as well, and most did not.
// Now the daemon writes the bank itself, to the file it loads at its next
// start, once a save has succeeded -- and only when run_daemon gave the
// control context a path for it, so the tests that drive a handler with the
// developer's real HOME never write ~/.config.
//
// What is expected is spelled out here from the values the tests set, and the
// kept file is read back through load_bank_file, the daemon's own start-up
// reader, so a bank that the daemon could not load again would fail too.

@(private = "file")
keep_dir_count: u32

@(private = "file")
keep_dir_make :: proc() -> string {
	dir := fmt.aprintf("/tmp/quesynth-keep-%d-%d", posix.getpid(), intrinsics.atomic_add(&keep_dir_count, 1))
	os.remove_all(dir)
	assert(os.make_directory_all(dir) == nil)
	return dir
}

@(private = "file")
keep_dir_free :: proc(dir: string) {
	os.remove_all(dir)
	delete(dir)
}

// What the live sound holds for parameter i: distinct, so a slot that kept the
// wrong values cannot pass for the right ones, and not the factory's.
@(private = "file")
keep_value :: proc(i: int) -> i32 {
	return i32((i * 7 + 3) % 101)
}

@(private = "file")
Keep_Handler :: struct {
	bank:     patch.Slots,
	snap:     standalone.Snapshot,
	state:    standalone.Daemon_State,
	identity: standalone.Patch_Identity,
	cc:       standalone.Control_Context,
}

@(private = "file")
keep_handler_make :: proc(keep: string) -> ^Keep_Handler {
	h := new(Keep_Handler)
	patch.factory_prepare()
	patch.slots_load_factory(&h.bank)
	seed := standalone.Snapshot_Data{revision = 5}
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = keep_value(i)}
	standalone.snapshot_publish(&h.snap, seed)
	h.state = .Running
	h.identity = standalone.Patch_Identity{slot = -1}
	h.cc = standalone.Control_Context {
		snapshot  = &h.snap,
		state     = &h.state,
		bank      = &h.bank,
		identity  = &h.identity,
		bank_keep = keep,
	}
	return h
}

@(private = "file")
keep_ask :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

// The kept file, read the way the daemon reads it at start.
@(private = "file")
keep_read :: proc(path: string) -> (^patch.Slots, bool) {
	fresh := new(patch.Slots)
	if !standalone.load_bank_file(fresh, path) {
		free(fresh)
		return nil, false
	}
	return fresh, true
}

@(private = "file")
keep_expect_slot :: proc(t: ^testing.T, kept: ^patch.Slots, slot: int, name: string) {
	testing.expectf(t, kept.filled[slot], "slot %d is empty in the kept bank", slot)
	testing.expect_value(t, patch.slots_name(kept, slot), name)
	for i in 0 ..< patch.PARAMETER_COUNT {
		testing.expect_value(t, kept.values[slot][i], keep_value(i))
	}
}

@(test)
test_a_save_is_kept_for_the_next_start :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/quesynth/bank.json", dir)
	h := keep_handler_make(keep)
	defer free(h)
	factory := h.bank

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Warm Pad"), "1 1 ok slot=120 name=Warm_Pad bank_rev=1")

	kept, ok := keep_read(keep)
	if !testing.expect(t, ok, "no bank where the next start looks for one") {return}
	defer free(kept)
	keep_expect_slot(t, kept, 120, "Warm Pad")
	// The whole bank is kept, not the slot alone: what was there stays.
	testing.expect_value(t, patch.slots_label(kept), "Factory")
	for i in 0 ..< patch.FACTORY_SLOTS {
		if i == 120 {continue}
		testing.expectf(t, kept.filled[i] == factory.filled[i], "slot %d changed its filled state", i)
		if !factory.filled[i] {continue}
		testing.expect_value(t, patch.slots_name(kept, i), patch.slots_name(&factory, i))
		testing.expect_value(t, kept.values[i], factory.values[i])
	}
}

@(test)
test_every_save_is_kept_and_overwrites_its_slot :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	h := keep_handler_make(keep)
	defer free(h)

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 First"), "1 1 ok slot=120 name=First bank_rev=1")
	testing.expect_value(t, keep_ask(&h.cc, "1 2 patch.save 127  Last  One "), "1 2 ok slot=127 name=Last__One bank_rev=2")
	kept, ok := keep_read(keep)
	if !testing.expect(t, ok) {return}
	keep_expect_slot(t, kept, 120, "First")
	keep_expect_slot(t, kept, 127, "Last  One")
	free(kept)

	// A slot saved again is replaced, and a save with no name keeps the name.
	for i in 0 ..< patch.PARAMETER_COUNT {h.snap.data.values[i] = 9}
	testing.expect_value(t, keep_ask(&h.cc, "1 3 patch.save 120"), "1 3 ok slot=120 name=First bank_rev=3")
	kept, ok = keep_read(keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	testing.expect_value(t, patch.slots_name(kept, 120), "First")
	for i in 0 ..< patch.PARAMETER_COUNT {testing.expect_value(t, kept.values[120][i], 9)}
	keep_expect_slot(t, kept, 127, "Last  One")
}

// Loading another bank file to browse it does not make it the kept bank: a save
// after it keeps that one slot in the kept file, and every other slot there
// stays. Only bank.keep adopts the loaded bank, and saves after that write it
// whole again.
@(test)
test_a_save_after_loading_another_bank_keeps_only_its_slot :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/mine.json", dir)
	h := keep_handler_make(keep)
	defer free(h)
	factory := h.bank

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Mine"), "1 1 ok slot=120 name=Mine bank_rev=1")

	other := new(patch.Slots)
	defer free(other)
	other^ = factory
	copy(other.label[:], "Other")
	other.label_len = len("Other")
	copy(other.names[3][:], "Other Three")
	other.name_len[3] = len("Other Three")
	for i in 0 ..< patch.PARAMETER_COUNT {other.values[3][i] = 1}
	other_path := fmt.tprintf("%s/other.json", dir)
	testing.expect(t, os.write_entire_file_from_string(other_path, patch.slots_write_json(other, context.temp_allocator)) == nil)

	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, fmt.tprintf("1 2 bank.load_file %s", other_path)), "1 2 ok label=Other"))
	testing.expect_value(t, keep_ask(&h.cc, "1 3 patch.save 7 New"), "1 3 ok slot=7 name=New bank_rev=3")
	// The browsable bank holds the save too.
	testing.expect_value(t, patch.slots_name(&h.bank, 7), "New")

	kept, ok := keep_read(keep)
	if !testing.expect(t, ok) {return}
	keep_expect_slot(t, kept, 120, "Mine")
	keep_expect_slot(t, kept, 7, "New")
	testing.expect_value(t, patch.slots_label(kept), "Factory")
	testing.expect_value(t, patch.slots_name(kept, 3), patch.slots_name(&factory, 3))
	testing.expect_value(t, kept.values[3], factory.values[3])
	free(kept)

	// The loaded file itself is left as it was.
	loaded, lok := keep_read(other_path)
	if !testing.expect(t, lok) {return}
	testing.expect_value(t, patch.slots_name(loaded, 7), patch.slots_name(&factory, 7))
	free(loaded)

	// bank.keep adopts the loaded bank, saves included; later saves write it whole.
	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, "1 4 bank.keep"), "1 4 ok"))
	testing.expect_value(t, keep_ask(&h.cc, "1 5 patch.save 9 Later"), "1 5 ok slot=9 name=Later bank_rev=4")
	kept, ok = keep_read(keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	testing.expect_value(t, patch.slots_label(kept), "Other")
	testing.expect_value(t, patch.slots_name(kept, 3), "Other Three")
	keep_expect_slot(t, kept, 7, "New")
	keep_expect_slot(t, kept, 9, "Later")
	testing.expectf(t, !kept.filled[120] || patch.slots_name(kept, 120) != "Mine", "bank.keep should have replaced the kept bank with the loaded one")
}

// The bank file the save goes into, and the "Other Three" bank that is loaded.
@(private = "file")
keep_other_bank :: proc(t: ^testing.T, dir: string, factory: ^patch.Slots) -> string {
	other := new(patch.Slots)
	defer free(other)
	other^ = factory^
	copy(other.names[3][:], "Other Three")
	other.name_len[3] = len("Other Three")
	path := fmt.tprintf("%s/other.json", dir)
	testing.expect(t, os.write_entire_file_from_string(path, patch.slots_write_json(other, context.temp_allocator)) == nil)
	return path
}

// With the kept file gone, a save after loading another bank starts from the
// factory bank, which is what the next start would load.
@(test)
test_a_save_after_loading_another_bank_into_no_kept_file_starts_from_factory :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/new/bank.json", dir)
	h := keep_handler_make(keep)
	defer free(h)
	factory := h.bank
	other_path := keep_other_bank(t, dir, &factory)

	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, "1 1 patch.save 120 Mine"), "1 1 ok"))
	testing.expect(t, os.remove(keep) == nil)
	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, fmt.tprintf("1 2 bank.load_file %s", other_path)), "1 2 ok"))
	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, "1 3 patch.save 7 New"), "1 3 ok slot=7 name=New"))
	kept, ok := keep_read(keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	keep_expect_slot(t, kept, 7, "New")
	testing.expect_value(t, patch.slots_name(kept, 3), patch.slots_name(&factory, 3))
	testing.expect_value(t, patch.slots_name(kept, 120), patch.slots_name(&factory, 120))
}

// A bank loaded over the factory bank nobody chose (bank_rev 0) is adopted,
// as the TUI's User bank is: nothing kept is lost, and saves keep it whole.
@(test)
test_a_bank_loaded_over_the_untouched_factory_bank_is_kept_whole :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	h := keep_handler_make(keep)
	defer free(h)
	factory := h.bank
	other_path := keep_other_bank(t, dir, &factory)

	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, fmt.tprintf("1 1 bank.load_file %s", other_path)), "1 1 ok"))
	testing.expect(t, strings.has_prefix(keep_ask(&h.cc, "1 2 patch.save 7 New"), "1 2 ok slot=7 name=New"))
	kept, ok := keep_read(keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	keep_expect_slot(t, kept, 7, "New")
	testing.expect_value(t, patch.slots_name(kept, 3), "Other Three")
}

// What a client reads back must not depend on whether the daemon keeps.
@(test)
test_a_kept_save_answers_the_same_bytes_as_one_that_is_not :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	kept := keep_handler_make(fmt.tprintf("%s/bank.json", dir))
	defer free(kept)
	plain := keep_handler_make("")
	defer free(plain)

	lines := [?]string {
		"1 1 patch.save 120 My Lead",
		"1 2 patch.save 121",
		"1 3 patch.save 0",
		"1 4 patch.save 127 Ünï ©ode ✓",
		"1 5 patch.save 5 " + "N" + "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN",
		"1 6 patch.save 999 Nope",
		"1 7 patch.save",
		"1 8 patch.current",
	}
	for line in lines {
		testing.expect_value(t, keep_ask(&kept.cc, line), keep_ask(&plain.cc, line))
	}
}

// Memory-only, as it has always been, where nothing says where to keep.
@(test)
test_a_save_with_no_keep_path_writes_nothing :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	h := keep_handler_make("")
	defer free(h)

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Memory"), "1 1 ok slot=120 name=Memory bank_rev=1")
	testing.expect(t, h.bank.filled[120])
	for i in 0 ..< patch.PARAMETER_COUNT {testing.expect_value(t, h.bank.values[120][i], keep_value(i))}
	// Not here, and bank.keep stays the way to write one on request.
	testing.expect(t, !os.exists(fmt.tprintf("%s/bank.json", dir)))
}

@(private = "file")
keep_bank_untouched :: proc(t: ^testing.T, h: ^Keep_Handler, bank: ^patch.Slots, identity: standalone.Patch_Identity) {
	testing.expect(t, h.bank == bank^, "the refused save left a mark on the bank")
	testing.expect(t, h.identity == identity, "the refused save changed which patch is playing")
}

@(test)
test_a_save_that_cannot_be_kept_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	// The directory the bank belongs in is a file: nothing can be written there.
	blocker := fmt.tprintf("%s/blocker", dir)
	assert(os.write_entire_file_from_string(blocker, "not a directory") == nil)
	h := keep_handler_make(fmt.tprintf("%s/bank.json", blocker))
	defer free(h)
	before := new(patch.Slots)
	defer free(before)
	before^ = h.bank
	identity := h.identity

	// An empty slot, a filled one with a name of its own, and one that is
	// refused as before.
	filled := 0
	for !h.bank.filled[filled] {filled += 1}
	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Lost"), "1 1 err internal_error cannot keep bank")
	keep_bank_untouched(t, h, before, identity)
	testing.expect_value(t, keep_ask(&h.cc, fmt.tprintf("1 2 patch.save %d Over", filled)), "1 2 err internal_error cannot keep bank")
	keep_bank_untouched(t, h, before, identity)
	testing.expect(t, !h.bank.filled[120])
	testing.expect_value(t, patch.slots_name(&h.bank, 120), "Init")
	testing.expect_value(t, h.identity.bank_rev, 0)
	testing.expect_value(t, keep_ask(&h.cc, "1 3 patch.save 999 Nope"), "1 3 err invalid_payload slot out of range")

	// Once the bank can be kept the same save goes through, and counts as
	// the first: the refused ones moved nothing.
	h.cc.bank_keep = fmt.tprintf("%s/bank.json", dir)
	testing.expect_value(t, keep_ask(&h.cc, "1 4 patch.save 120 Found"), "1 4 ok slot=120 name=Found bank_rev=1")
	kept, ok := keep_read(h.cc.bank_keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	keep_expect_slot(t, kept, 120, "Found")
}

// A path the daemon cannot replace is not written over, and no half of a
// bank is left beside it.
@(test)
test_a_refused_keep_leaves_no_half_written_file :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	// A directory where the bank file belongs: the rename over it fails after
	// the temporary file is written.
	keep := fmt.tprintf("%s/bank.json", dir)
	assert(os.make_directory_all(keep) == nil)
	h := keep_handler_make(keep)
	defer free(h)

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Nowhere"), "1 1 err internal_error cannot keep bank")
	testing.expect(t, os.is_dir(keep))
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", keep)), "a temporary bank was left behind")
	testing.expect(t, !h.bank.filled[120])
}

// The bank kept by an earlier save is whole when a later one cannot be written.
@(test)
test_a_failed_keep_leaves_the_earlier_bank_whole :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	h := keep_handler_make(keep)
	defer free(h)

	testing.expect_value(t, keep_ask(&h.cc, "1 1 patch.save 120 Before"), "1 1 ok slot=120 name=Before bank_rev=1")
	earlier, rerr := os.read_entire_file(keep, context.temp_allocator)
	testing.expect(t, rerr == nil)

	// The temporary file's name is taken by a directory, so the next write
	// cannot start.
	assert(os.make_directory_all(fmt.tprintf("%s.tmp", keep)) == nil)
	for i in 0 ..< patch.PARAMETER_COUNT {h.snap.data.values[i] = 1}
	testing.expect_value(t, keep_ask(&h.cc, "1 2 patch.save 121 After"), "1 2 err internal_error cannot keep bank")
	testing.expect(t, !h.bank.filled[121])
	testing.expect_value(t, h.identity.bank_rev, 1)

	now, nerr := os.read_entire_file(keep, context.temp_allocator)
	testing.expect(t, nerr == nil)
	testing.expect_value(t, string(now), string(earlier))
	kept, ok := keep_read(keep)
	if !testing.expect(t, ok) {return}
	defer free(kept)
	keep_expect_slot(t, kept, 120, "Before")
	testing.expect(t, !kept.filled[121])
}

// -- a save that has to wait for the audio thread ------------------------------
//
// Driven as save_test.odin drives it: a real control server, and live_render
// called by the test in place of the device, so the save is waiting before
// anything it waits for is applied. The wait ends outside the request that
// began it, which is where the keep must also be right.

@(private = "file")
KEEP_BLOCK :: 64

@(private = "file")
Keep_Bench :: struct {
	live:     standalone.Live,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	state:    standalone.Daemon_State,
	out:      [KEEP_BLOCK * 2]f32,
	server:   standalone.Control_Server,
	client:   posix.FD,
}

@(private = "file")
keep_bench_count: u32

@(private = "file")
keep_bench_make :: proc(keep: string) -> ^Keep_Bench {
	b := new(Keep_Bench)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	engine.engine_load_patch(&b.live.eng, p, 48000)
	b.live.left = make([]f32, KEEP_BLOCK)
	b.live.right = make([]f32, KEEP_BLOCK)
	b.live.volume.milli = standalone.VOLUME_UNITY
	b.live.volume_prev = standalone.VOLUME_UNITY
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(engine.engine_patch_value(&b.live.eng, i))}
	standalone.snapshot_publish(&b.live.snapshot, seed)
	patch.factory_prepare()
	patch.slots_load_factory(&b.bank)
	b.identity = standalone.Patch_Identity{slot = -1}
	b.state = .Running
	b.server.path = fmt.aprintf("/tmp/quesynth-keepw-%d-%d.sock", posix.getpid(), intrinsics.atomic_add(&keep_bench_count, 1))
	b.server.ctx = standalone.Control_Context {
		ring      = &b.live.ring,
		snapshot  = &b.live.snapshot,
		state     = &b.state,
		bank      = &b.bank,
		identity  = &b.identity,
		bank_keep = keep,
	}
	assert(standalone.control_server_start(&b.server))
	ok: bool
	b.client, ok = connect_unix(b.server.path)
	assert(ok)
	return b
}

@(private = "file")
keep_bench_free :: proc(b: ^Keep_Bench) {
	posix.close(b.client)
	standalone.control_server_stop(&b.server)
	posix.unlink(strings.clone_to_cstring(fmt.tprintf("%s.lock", b.server.path), context.temp_allocator))
	delete(b.server.path)
	engine.engine_destroy(&b.live.eng)
	delete(b.live.left)
	delete(b.live.right)
	free(b)
}

@(private = "file")
keep_audio_block :: proc(b: ^Keep_Bench) {
	standalone.live_render(&b.live, raw_data(b.out[:]), KEEP_BLOCK, 2)
}

@(private = "file")
keep_send_all :: proc(fd: posix.FD, lines: ..string) {
	wire := make([dynamic]u8, context.temp_allocator)
	for line in lines {
		n := len(line)
		append(&wire, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(&wire, ..transmute([]u8)line)
	}
	posix.send(fd, raw_data(wire[:]), c.size_t(len(wire)), {.NOSIGNAL})
}

// Until the server has queued `commands` on the ring and handled the save sent
// behind them, which is before anything is applied.
@(private = "file")
keep_await_handled :: proc(b: ^Keep_Bench, commands: int, settle: time.Duration) -> bool {
	for _ in 0 ..< 1000 {
		if standalone.PARAM_RING_CAPACITY - standalone.param_ring_free_space(&b.live.ring) >= commands {
			time.sleep(settle)
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

@(private = "file")
keep_ask_wire :: proc(b: ^Keep_Bench, line: string) -> string {
	reliability_send(b.client, line)
	return reliability_reply(b.client)
}

@(private = "file")
keep_pending_reply :: proc(fd: posix.FD, limit: time.Duration) -> (string, bool) {
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	if posix.poll(&fds[0], 1, c.int(limit / time.Millisecond)) <= 0 {return "", false}
	reply := reliability_reply(fd)
	return reply, reply != "TIMEOUT/CLOSED"
}

@(private = "file")
keep_cutoff :: proc() -> int {
	d, found := registry.registry_describe("filter.cutoff")
	assert(found)
	return d.index
}

@(test)
test_a_save_that_waited_is_kept_once_it_is_answered :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	b := keep_bench_make(keep)
	defer keep_bench_free(b)

	keep_send_all(b.client, "1 1 parameter.set filter.cutoff 77", "1 2 patch.save 120 Waited Lead")
	if !testing.expect(t, keep_await_handled(b, 2, 30 * time.Millisecond)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=77 revision=0")
	// Waiting: nothing is stored yet, so nothing is written.
	_, early := keep_pending_reply(b.client, 0)
	testing.expect(t, !early, "the save was answered before the edit ahead of it was applied")
	testing.expect(t, !os.exists(keep), "the bank was written for a save that had not been stored")

	keep_audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 2 ok slot=120 name=Waited_Lead bank_rev=1")
	kept, ok := keep_read(keep)
	if !testing.expect(t, ok, "the save was answered and the bank was not kept") {return}
	defer free(kept)
	testing.expect(t, kept.filled[120])
	testing.expect_value(t, patch.slots_name(kept, 120), "Waited Lead")
	// The value set just before the save, which the audio thread applied only
	// afterwards, and every other parameter as the engine held it.
	testing.expect_value(t, kept.values[120][keep_cutoff()], 77)
	for i in 0 ..< patch.PARAMETER_COUNT {
		if i == keep_cutoff() {continue}
		testing.expect_value(t, kept.values[120][i], i32(engine.engine_patch_value(&b.live.eng, i)))
	}
}

@(test)
test_a_save_refused_for_waiting_too_long_is_not_kept :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	b := keep_bench_make(keep)
	defer keep_bench_free(b)

	keep_send_all(b.client, "1 1 parameter.set filter.cutoff 66", "1 2 patch.save 120 Late")
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=66 revision=0")
	reply, arrived := keep_pending_reply(b.client, 2 * time.Second)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, "1 2 err daemon_not_ready earlier edits not applied; nothing saved")

	// Not now, and not once the edit is applied.
	testing.expect(t, !os.exists(keep))
	keep_audio_block(b)
	time.sleep(30 * time.Millisecond)
	testing.expect(t, !os.exists(keep))
	testing.expect(t, !b.bank.filled[120])
}

@(test)
test_a_save_waiting_when_the_server_stops_is_not_kept :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	keep := fmt.tprintf("%s/bank.json", dir)
	b := keep_bench_make(keep)
	defer keep_bench_free(b)

	keep_send_all(b.client, "1 1 parameter.set filter.cutoff 44", "1 2 patch.save 120 Stopped")
	if !testing.expect(t, keep_await_handled(b, 2, 30 * time.Millisecond)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=44 revision=0")
	standalone.control_server_stop(&b.server)
	reply, arrived := keep_pending_reply(b.client, time.Second)
	testing.expect(t, arrived)
	testing.expect_value(t, reply, "1 2 err daemon_not_ready earlier edits not applied; nothing saved")
	testing.expect(t, !os.exists(keep))
	testing.expect(t, !b.bank.filled[120])
}

@(test)
test_a_save_that_waited_and_cannot_be_kept_is_refused :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	blocker := fmt.tprintf("%s/blocker", dir)
	assert(os.write_entire_file_from_string(blocker, "not a directory") == nil)
	b := keep_bench_make(fmt.tprintf("%s/bank.json", blocker))
	defer keep_bench_free(b)
	before := new(patch.Slots)
	defer free(before)
	before^ = b.bank

	keep_send_all(b.client, "1 1 parameter.set filter.cutoff 88", "1 2 patch.save 120 Nowhere", "1 3 patch.current")
	if !testing.expect(t, keep_await_handled(b, 2, 30 * time.Millisecond)) {return}
	testing.expect_value(t, reliability_reply(b.client), "1 1 ok value=88 revision=0")
	keep_audio_block(b)
	testing.expect_value(t, reliability_reply(b.client), "1 2 err internal_error cannot keep bank")
	// The connection goes on, and the sound is still the one that was set.
	testing.expect_value(
		t,
		reliability_reply(b.client),
		"1 3 ok slot=-1 bank_rev=0 revision=1 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
	)
	testing.expect(t, b.bank == before^, "the refused save left a mark on the bank")
	testing.expect_value(t, standalone.snapshot_read(&b.live.snapshot).values[keep_cutoff()], 88)
}

// -- what the keep takes from the temporary allocator -----------------------------
//
// A save that waited is answered from the server's tick, outside the request
// that began it and the per-request allocator guard, and the bank written out
// takes a patches array and its JSON from that allocator. Left to pile up on a
// thread that lives as long as the daemon, a save per second would make
// megabytes an hour. A bounded run of such saves must not grow the process.

@(private = "file")
keep_resident_kib :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/status", context.allocator)
	if err != nil {return -1}
	defer delete(data)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "VmRSS:") {continue}
		field := strings.trim_space(strings.trim_suffix(strings.trim_space(line[len("VmRSS:"):]), "kB"))
		kib, ok := strconv.parse_int(field)
		return ok ? kib : -1
	}
	return -1
}

@(test)
test_saves_that_waited_give_back_what_keeping_took :: proc(t: ^testing.T) {
	dir := keep_dir_make()
	defer keep_dir_free(dir)
	b := keep_bench_make(fmt.tprintf("%s/bank.json", dir))
	defer keep_bench_free(b)

	// A full bank, so the one written each time is as large as a bank gets.
	for slot in 0 ..< patch.FACTORY_SLOTS {
		reply := keep_ask_wire(b, fmt.tprintf("1 1 patch.save %d Filled Slot %03d", slot, slot))
		if !testing.expectf(t, strings.has_prefix(reply, "1 1 ok"), "slot %d: %s", slot, reply) {return}
	}

	ROUNDS :: 300
	// The first rounds size the allocator's blocks and the page cache; what
	// grows after them is what is not given back.
	warm :: 20
	before := 0
	for round in 0 ..< ROUNDS {
		if round == warm {before = keep_resident_kib()}
		keep_send_all(b.client, fmt.tprintf("1 1 parameter.set filter.cutoff %d", round % 128), "1 2 patch.save 127 Round")
		if !testing.expect(t, keep_await_handled(b, 2, 2 * time.Millisecond)) {return}
		reply := reliability_reply(b.client)
		if !testing.expectf(t, strings.has_prefix(reply, "1 1 ok"), "round %d: %s", round, reply) {return}
		keep_audio_block(b)
		reply = reliability_reply(b.client)
		if !testing.expectf(t, strings.has_prefix(reply, "1 2 ok"), "round %d: %s", round, reply) {return}
	}
	after := keep_resident_kib()
	if !testing.expect(t, before > 0 && after > 0, "cannot read VmRSS") {return}
	log.infof("resident memory %d KiB after %d rounds, %d KiB after %d", before, warm, after, ROUNDS)
	// Keeping a full bank takes a megabyte or so from the allocator, so
	// keeping what it took would add hundreds of MiB here.
	LIMIT_KIB :: 48 * 1024
	testing.expectf(t, after - before < LIMIT_KIB, "resident memory grew by %d KiB over %d saves (from %d to %d KiB)", after - before, ROUNDS - warm, before, after)
}
