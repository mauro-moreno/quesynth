#+build linux
package standalone_tests

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import "../../src/engine"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// The control thread lives as long as the daemon, and every command it serves
// may take from its temporary allocator: a bank written out, a bank or patch
// file read in, an archive indexed, an inner bank inflated, a page of patch
// names parsed. Nothing frees that allocator for it, so unless each request
// gives back what it took, a daemon left running grows by that much on every
// such command, for good. This drives a real control server with those
// commands, many times over, and holds the process's resident memory to a
// bound far below what they would leave behind if they kept it.
//
// bank.keep is not among them, because it writes under XDG_CONFIG_HOME and the
// environment belongs to the whole test process; it takes from the allocator
// what bank.write does, and the daemon itself is put to it in a real process.

@(private = "file")
Memory_Bench :: struct {
	live:     standalone.Live,
	bank:     patch.Slots,
	identity: standalone.Patch_Identity,
	archive:  standalone.Archive,
	state:    standalone.Daemon_State,
	server:   standalone.Control_Server,
	client:   posix.FD,
	done:     b32,
	audio:    ^thread.Thread,
}

// The audio thread's part, so loads are applied and the ring has room.
@(private = "file")
memory_audio :: proc(data: rawptr) {
	b := (^Memory_Bench)(data)
	for !intrinsics.atomic_load(&b.done) {
		standalone.live_render(&b.live, nil, 0, 2)
		time.sleep(time.Millisecond)
	}
}

// Little-endian fields of a zip header.
@(private = "file")
put16 :: proc(out: ^[dynamic]u8, v: int) {
	append(out, u8(v), u8(v >> 8))
}

@(private = "file")
put32 :: proc(out: ^[dynamic]u8, v: int) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
Zip_Item :: struct {
	name: string,
	data: []u8,
}

// A zip of deflated entries, written from the format's own layout. The
// deflate streams are stored blocks only, which every inflater must read, so
// each entry goes through the same inflate a real bank's does.
@(private = "file")
zip_build :: proc(items: []Zip_Item) -> []u8 {
	out: [dynamic]u8
	central: [dynamic]u8
	defer delete(central)
	for item in items {
		comp: [dynamic]u8
		defer delete(comp)
		rest := item.data
		for {
			n := min(len(rest), 65535)
			final := n == len(rest)
			append(&comp, final ? 1 : 0)
			put16(&comp, n)
			put16(&comp, ~n & 0xFFFF)
			append(&comp, ..rest[:n])
			rest = rest[n:]
			if final {break}
		}
		crc := int(hash.crc32(item.data))
		offset := len(out)
		put32(&out, 0x04034b50)
		put16(&out, 20)
		put16(&out, 0)
		put16(&out, 8)
		put32(&out, 0)
		put32(&out, crc)
		put32(&out, len(comp))
		put32(&out, len(item.data))
		put16(&out, len(item.name))
		put16(&out, 0)
		append(&out, ..transmute([]u8)item.name)
		append(&out, ..comp[:])

		put32(&central, 0x02014b50)
		put16(&central, 20)
		put16(&central, 20)
		put16(&central, 0)
		put16(&central, 8)
		put32(&central, 0)
		put32(&central, crc)
		put32(&central, len(comp))
		put32(&central, len(item.data))
		put16(&central, len(item.name))
		put16(&central, 0)
		put16(&central, 0)
		put16(&central, 0)
		put16(&central, 0)
		put32(&central, 0)
		put32(&central, offset)
		append(&central, ..transmute([]u8)item.name)
	}
	cd_offset := len(out)
	append(&out, ..central[:])
	put32(&out, 0x06054b50)
	put16(&out, 0)
	put16(&out, 0)
	put16(&out, len(items))
	put16(&out, len(items))
	put32(&out, len(central))
	put32(&out, cd_offset)
	put16(&out, 0)
	return out[:]
}

@(private = "file")
MEMORY_BANKS :: 24
@(private = "file")
MEMORY_PATCHES :: 128

// An archive of MEMORY_BANKS inner banks of MEMORY_PATCHES patches each, every
// patch the s1probe fixture.
@(private = "file")
write_archive :: proc(path: string) -> bool {
	sy1, err := os.read_entire_file("tools/s1probe/fixtures/unison-four.sy1", context.allocator)
	if err != nil {return false}
	defer delete(sy1)
	patches: [MEMORY_PATCHES]Zip_Item
	banks: [MEMORY_BANKS]Zip_Item
	defer {
		for b in banks {
			delete(b.data)
			delete(b.name)
		}
	}
	for i in 0 ..< MEMORY_PATCHES {
		patches[i] = {fmt.tprintf("A Rather Long Bank Folder/Patch Number %03d.sy1", i), sy1}
	}
	for i in 0 ..< MEMORY_BANKS {
		banks[i] = {fmt.aprintf("archive/Some Third Party Bank %02d.zip", i), zip_build(patches[:])}
	}
	outer := zip_build(banks[:])
	defer delete(outer)
	return os.write_entire_file(path, outer) == nil
}

// A bank with all 128 slots filled, so writing it and reading it are as large
// as a bank gets.
@(private = "file")
write_full_bank :: proc(path: string) -> bool {
	full := new(patch.Slots)
	defer free(full)
	patch.factory_prepare()
	patch.slots_load_factory(full)
	first := 0
	for !full.filled[first] {first += 1}
	for i in 0 ..< patch.FACTORY_SLOTS {
		if full.filled[i] {continue}
		full.values[i] = full.values[first]
		full.filled[i] = true
		name := fmt.tprintf("Filled Slot %03d", i)
		copy(full.names[i][:], name)
		full.name_len[i] = len(name)
	}
	json := patch.slots_write_json(full, context.allocator)
	defer delete(json)
	return os.write_entire_file_from_string(path, json) == nil
}

@(private = "file")
resident_kib :: proc() -> int {
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

@(private = "file")
memory_ask :: proc(b: ^Memory_Bench, line: string) -> string {
	reliability_send(b.client, line)
	return reliability_reply(b.client)
}

// One of each command that takes from the temporary allocator. The bank opened
// moves every round, so each round really reads and inflates one.
@(private = "file")
memory_round :: proc(t: ^testing.T, b: ^Memory_Bench, round: int, dir: string) -> bool {
	expect_ok :: proc(t: ^testing.T, reply, line: string) -> bool {
		return testing.expectf(t, strings.has_prefix(reply, "1 1 ok"), "%s -> %s", line, reply)
	}
	lines := [?]string {
		fmt.tprintf("1 1 bank.load_file %s/full bank.json", dir),
		fmt.tprintf("1 1 bank.write %s/written bank.json", dir),
		"1 1 patch.load_file tools/s1probe/fixtures/unison-four.sy1",
		fmt.tprintf("1 1 archive.open %s/archive.zip", dir),
		"1 1 archive.banks 0 256",
		fmt.tprintf("1 1 archive.bank %d", round % MEMORY_BANKS),
		"1 1 archive.patches 0 256",
		fmt.tprintf("1 1 archive.load %d", round % MEMORY_PATCHES),
	}
	for line in lines {
		if !expect_ok(t, memory_ask(b, line), line) {return false}
	}
	return true
}

@(test)
test_the_control_thread_gives_back_what_each_request_takes :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/quesynth-memory-%d", posix.getpid())
	if !testing.expect(t, os.make_directory_all(dir) == nil) {return}
	defer os.remove_all(dir)
	if !testing.expect(t, write_full_bank(fmt.tprintf("%s/full bank.json", dir))) {return}
	if !testing.expect(t, write_archive(fmt.tprintf("%s/archive.zip", dir))) {return}

	b := new(Memory_Bench)
	defer free(b)
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	engine.engine_load_patch(&b.live.eng, p, 48000)
	defer engine.engine_destroy(&b.live.eng)
	seed: standalone.Snapshot_Data
	for i in 0 ..< patch.PARAMETER_COUNT {seed.values[i] = i32(engine.engine_patch_value(&b.live.eng, i))}
	standalone.snapshot_publish(&b.live.snapshot, seed)
	patch.factory_prepare()
	patch.slots_load_factory(&b.bank)
	b.identity = standalone.Patch_Identity{slot = -1}
	b.state = .Running
	b.server.path = fmt.tprintf("/tmp/quesynth-memory-%d.sock", posix.getpid())
	b.server.ctx = standalone.Control_Context {
		ring     = &b.live.ring,
		snapshot = &b.live.snapshot,
		state    = &b.state,
		bank     = &b.bank,
		archive  = &b.archive,
		identity = &b.identity,
	}
	if !testing.expect(t, standalone.control_server_start(&b.server)) {return}
	defer {
		standalone.control_server_stop(&b.server)
		posix.unlink(strings.clone_to_cstring(fmt.tprintf("%s.lock", b.server.path), context.temp_allocator))
		// Opened on the control thread, which has the plain heap rather than
		// the tracking allocator this test runs under.
		context.allocator = runtime.heap_allocator()
		standalone.archive_close(&b.archive)
	}
	b.audio = thread.create_and_start_with_data(b, memory_audio)
	defer {
		intrinsics.atomic_store(&b.done, true)
		thread.join(b.audio)
		thread.destroy(b.audio)
	}
	connected: bool
	b.client, connected = connect_unix(b.server.path)
	if !testing.expect(t, connected) {return}
	defer posix.close(b.client)

	// A few rounds first, so what is kept for good -- the open archive and its
	// bank, the first block of the allocator -- is in place before measuring.
	WARM_UP :: 4
	ROUNDS :: 40
	for round in 0 ..< WARM_UP {
		if !memory_round(t, b, round, dir) {return}
	}
	before := resident_kib()
	for round in WARM_UP ..< WARM_UP + ROUNDS {
		if !memory_round(t, b, round, dir) {return}
	}
	after := resident_kib()
	if !testing.expect(t, before > 0 && after > 0, "cannot read VmRSS") {return}

	// Kept, the rounds above leave well over 200 MiB behind (measured by
	// taking the per-request reset out); given back, they leave next to
	// nothing. The bound leaves room for what other tests running beside
	// this one allocate meanwhile.
	LIMIT_KIB :: 48 * 1024
	log.infof("resident memory %d KiB before %d rounds, %d KiB after", before, ROUNDS, after)
	testing.expectf(t, after - before < LIMIT_KIB, "resident memory grew by %d KiB over %d rounds (from %d to %d KiB)", after - before, ROUNDS, before, after)
}
