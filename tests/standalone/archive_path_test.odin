#+build linux
package standalone_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import standalone "../../hosts/standalone"

// archive.open takes a path from a client, so it must not wait on whatever the
// path happens to be: opening a FIFO blocks until something writes to it, and
// the daemon would block with it. Only a regular file is an archive.

@(private = "file")
FIXTURE :: "tests/zip/fixtures/nested.zip"

@(private = "file")
scratch_dir :: proc(tag: string) -> (dir: string, ok: bool) {
	dir = fmt.tprintf("/tmp/quesynth-archpath-%s-%d", tag, posix.getpid())
	os.remove_all(dir)
	return dir, os.make_directory_all(dir) == nil
}

@(private = "file")
Open_Job :: struct {
	path:   string,
	opened: bool,
	done:   bool,
}

// archive_open on its own thread, so a test whose open hangs can notice and
// fail instead of hanging with it.
@(private = "file")
open_job :: proc(data: rawptr) {
	job := (^Open_Job)(data)
	arch: standalone.Archive
	job.opened = standalone.archive_open(&arch, job.path)
	standalone.archive_close(&arch)
	sync.atomic_store(&job.done, true)
}

@(test)
test_archive_open_refuses_a_fifo_without_waiting_for_a_writer :: proc(t: ^testing.T) {
	dir, dok := scratch_dir("fifo")
	if !testing.expect(t, dok) {return}
	defer os.remove_all(dir)
	fifo := fmt.tprintf("%s/bank.zip", dir)
	cfifo := strings.clone_to_cstring(fifo, context.temp_allocator)
	if !testing.expect(t, posix.mkfifo(cfifo, {.IRUSR, .IWUSR}) == .OK) {return}

	job := Open_Job{path = fifo}
	worker := thread.create_and_start_with_data(&job, open_job)
	defer thread.destroy(worker)
	deadline := time.tick_now()
	hung := false
	for !sync.atomic_load(&job.done) {
		if time.tick_diff(deadline, time.tick_now()) > 2 * time.Second {
			hung = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if hung {
		// Let the blocked open through, so the failure is reported rather
		// than the test run hanging: a writer's arrival ends the wait.
		for !sync.atomic_load(&job.done) {
			if wfd := posix.open(cfifo, {.WRONLY, .NONBLOCK}); wfd != -1 {posix.close(wfd)}
			time.sleep(5 * time.Millisecond)
		}
	}
	thread.join(worker)
	testing.expect(t, !hung, "archive_open waited on a FIFO for a writer")
	testing.expect(t, !job.opened)
}

@(test)
test_archive_open_refuses_a_directory_and_keeps_the_open_archive :: proc(t: ^testing.T) {
	dir, dok := scratch_dir("dir")
	if !testing.expect(t, dok) {return}
	defer os.remove_all(dir)

	arch: standalone.Archive
	defer standalone.archive_close(&arch)
	if !testing.expect(t, standalone.archive_open(&arch, FIXTURE)) {return}

	testing.expect(t, !standalone.archive_open(&arch, dir))
	testing.expect(t, !standalone.archive_open(&arch, "/dev/null"))
	testing.expect(t, !standalone.archive_open(&arch, "/dev/zero"))
	// Still the archive that was open before.
	testing.expect(t, arch.open)
	testing.expect_value(t, arch.path, FIXTURE)
	testing.expect_value(t, len(arch.bank_indices), 1)
}

@(test)
test_archive_open_follows_a_symlink_to_a_regular_file :: proc(t: ^testing.T) {
	dir, dok := scratch_dir("link")
	if !testing.expect(t, dok) {return}
	defer os.remove_all(dir)
	cwd, cerr := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, cerr == nil) {return}
	target := strings.clone_to_cstring(fmt.tprintf("%s/%s", cwd, FIXTURE), context.temp_allocator)
	link := fmt.tprintf("%s/linked.zip", dir)
	if !testing.expect(t, posix.symlink(target, strings.clone_to_cstring(link, context.temp_allocator)) == .OK) {return}

	arch: standalone.Archive
	defer standalone.archive_close(&arch)
	testing.expect(t, standalone.archive_open(&arch, link))
	testing.expect_value(t, len(arch.bank_indices), 1)
}

@(test)
test_archive_open_still_opens_the_fixture_banks :: proc(t: ^testing.T) {
	arch: standalone.Archive
	defer standalone.archive_close(&arch)
	testing.expect(t, standalone.archive_open(&arch, "tests/standalone/fixtures/banks.zip"))
	testing.expect(t, len(arch.bank_indices) > 0)
	testing.expect(t, standalone.archive_open_bank(&arch, 0))
	testing.expect(t, standalone.archive_patch_count(&arch) > 0)
}

// The sizes in an archive's directories are claims, not facts: a hostile one
// must be refused before it becomes an allocation.

@(private = "file")
forged_fixture :: proc(dir, name: string, patch: proc(data: []u8)) -> (path: string, ok: bool) {
	data, rerr := os.read_entire_file(FIXTURE, context.temp_allocator)
	if rerr != nil {return "", false}
	patch(data)
	path = fmt.tprintf("%s/%s", dir, name)
	return path, os.write_entire_file(path, data) == nil
}

@(private = "file")
set_u32 :: proc(b: []u8, off: int, v: u32) {
	b[off], b[off + 1], b[off + 2], b[off + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(test)
test_archive_open_refuses_a_directory_past_the_end_of_the_file :: proc(t: ^testing.T) {
	dir, dok := scratch_dir("cdsize")
	if !testing.expect(t, dok) {return}
	defer os.remove_all(dir)
	// The end record ends the file, with the directory size at +12 in it.
	path, ok := forged_fixture(dir, "huge-cd.zip", proc(data: []u8) {set_u32(data, len(data) - 22 + 12, 0xffff_fff0)})
	if !testing.expect(t, ok) {return}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.Allocator{mem.tracking_allocator_proc, &track}

	arch: standalone.Archive
	defer standalone.archive_close(&arch)
	testing.expect(t, !standalone.archive_open(&arch, path))
	testing.expectf(t, track.peak_memory_allocated < 1 << 20, "allocated %d bytes for a forged directory", track.peak_memory_allocated)
}

@(test)
test_archive_refuses_a_bank_whose_stored_size_is_forged :: proc(t: ^testing.T) {
	dir, dok := scratch_dir("compsize")
	if !testing.expect(t, dok) {return}
	defer os.remove_all(dir)
	// Every central record's compressed size (at +20 in it) claims nearly 4 GiB.
	path, ok := forged_fixture(dir, "huge-bank.zip", proc(data: []u8) {
		for i in 0 ..< len(data) - 4 {
			if data[i] == 'P' && data[i + 1] == 'K' && data[i + 2] == 1 && data[i + 3] == 2 {
				set_u32(data, i + 20, 0xffff_fff0)
			}
		}
	})
	if !testing.expect(t, ok) {return}

	arch: standalone.Archive
	defer standalone.archive_close(&arch)
	if !testing.expect(t, standalone.archive_open(&arch, path)) {return}
	testing.expect_value(t, len(arch.bank_indices), 1)

	// The entry is read into the temp allocator.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.temp_allocator = mem.Allocator{mem.tracking_allocator_proc, &track}
	testing.expect(t, !standalone.archive_open_bank(&arch, 0))
	testing.expect(t, !arch.bank_open)
	testing.expectf(t, track.peak_memory_allocated < 1 << 20, "allocated %d bytes for a forged size", track.peak_memory_allocated)
}
