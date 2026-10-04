#+build linux
package tui_tests

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"

import tui "../../hosts/standalone/tui"

// Every TUI request that carries a file or archive path names it absolutely.
// The daemon opens what it is sent from its own working directory, which is
// wherever it was started, and keeps an archive path as given for its next
// start; a relative path typed at this TUI would name a file there instead.
// The request lines are read off the far end of a socket pair and compared
// with the line built by hand from the working directory, so the client is
// held to what reaches the daemon, not to its own helper.

@(private = "file")
Path_Request :: struct {
	verb:  string,
	reply: string,
}

// One wrapper per verb, all answered as the contract says the daemon answers.
@(private = "file")
PATH_REQUESTS := [?]Path_Request {
	{"patch.load_file", "1 1 ok count=3 revision=1\nname=Lead"},
	{"bank.load_file", "1 1 ok label=Mine count=1 bank_rev=1"},
	{"bank.write", "1 1 ok bytes=10"},
	{"archive.open", "1 1 ok banks=2 archive_rev=1"},
	{"archive.adopt", "1 1 ok adopted=1 open=1 banks=2 archive_rev=1"},
}

@(private = "file")
send_path :: proc(client: ^tui.Client, verb, path: string) -> bool {
	switch verb {
	case "patch.load_file":
		name, ok := tui.client_patch_load_file(client, path)
		delete(name)
		return ok
	case "bank.load_file":
		return tui.client_bank_load_file(client, path)
	case "bank.write":
		return tui.client_bank_write(client, path)
	case "archive.open":
		_, ok := tui.client_archive_open(client, path)
		return ok
	case "archive.adopt":
		return tui.client_archive_adopt(client, path)
	}
	return false
}

// A client whose next request is answered with `reply` on the far end of a
// socket pair, written in the documented framing by hand.
@(private = "file")
path_client :: proc(reply: string) -> (client: tui.Client, far: posix.FD) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK {return tui.Client{fd = -1}, -1}
	n := len(reply)
	header := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	posix.send(fds[1], raw_data(header[:]), 4, {.NOSIGNAL})
	posix.send(fds[1], raw_data(reply), c.size_t(n), {.NOSIGNAL})
	return tui.Client{fd = fds[0], next_id = 1}, fds[1]
}

// The request the client sent, or "" when none is waiting.
@(private = "file")
sent_line :: proc(fd: posix.FD) -> string {
	header: [4]u8
	if !sent_exact(fd, header[:]) {return ""}
	n := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
	text := make([]u8, n, context.temp_allocator)
	if !sent_exact(fd, text) {return ""}
	return string(text)
}

@(private = "file")
sent_exact :: proc(fd: posix.FD, data: []u8) -> bool {
	at := 0
	for at < len(data) {
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&fds[0], 1, 1000) <= 0 {return false}
		remaining := len(data) - at
		n := posix.read(fd, raw_data(data[at:]), c.size_t(remaining))
		if n <= 0 {return false}
		at += int(n)
	}
	return true
}

// Whether anything at all has reached the far end, without waiting.
@(private = "file")
anything_sent :: proc(fd: posix.FD) -> bool {
	fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
	return posix.poll(&fds[0], 1, 0) > 0
}

@(test)
test_a_relative_path_reaches_the_daemon_under_the_tuis_directory :: proc(t: ^testing.T) {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, err == nil && strings.has_prefix(cwd, "/")) {return}
	// Spaces doubled, a byte past ASCII, a parent step and a name with no
	// directory: all kept as typed, only put under the directory.
	relative := []string{"two  spaces/My Bank.json", "ünïcode.zip", "../up/./there.sy1", "plain"}
	for r in PATH_REQUESTS {
		for path in relative {
			client, far := path_client(r.reply)
			defer {tui.client_close(&client); posix.close(far)}
			testing.expect(t, send_path(&client, r.verb, path), r.verb)
			testing.expect_value(t, sent_line(far), fmt.tprintf("1 1 %s %s/%s", r.verb, cwd, path))
		}
	}
}

@(test)
test_an_absolute_path_reaches_the_daemon_as_typed :: proc(t: ^testing.T) {
	for r in PATH_REQUESTS {
		for path in ([]string{"/tmp/My  Banks/a b.zip", "/", "/x/../y/./z.json"}) {
			client, far := path_client(r.reply)
			defer {tui.client_close(&client); posix.close(far)}
			testing.expect(t, send_path(&client, r.verb, path), r.verb)
			testing.expect_value(t, sent_line(far), fmt.tprintf("1 1 %s %s", r.verb, path))
		}
	}
	// No path still asks the daemon to reopen the archive it remembers.
	client, far := path_client("1 1 ok banks=2 archive_rev=1")
	defer {tui.client_close(&client); posix.close(far)}
	_, opened := tui.client_archive_open(&client, "")
	testing.expect(t, opened)
	testing.expect_value(t, sent_line(far), "1 1 archive.open")
}

// With no working directory to put it under, a relative path is not sent at
// all -- the daemon would read it from its own -- and the user is told why;
// the connection stays up and the next request keeps its id. The directory is
// taken away from this thread only (unshare CLONE_FS), so the tests running
// beside it keep theirs, and it is given back before the test ends.
@(test)
test_a_relative_path_is_not_sent_without_a_working_directory :: proc(t: ^testing.T) {
	home := posix.open(".", {.DIRECTORY, .CLOEXEC})
	if !testing.expect(t, home >= 0) {return}
	defer posix.close(home)
	CLONE_FS :: 0x200
	if !testing.expect_value(t, intrinsics.syscall(linux.SYS_unshare, CLONE_FS), 0) {return}
	gone := fmt.tprintf("/tmp/quesynth-tui-gone-%d", posix.getpid())
	cgone := strings.clone_to_cstring(gone, context.temp_allocator)
	if !testing.expect(t, posix.mkdir(cgone, {.IRUSR, .IWUSR, .IXUSR}) == .OK) {return}
	defer posix.fchdir(home)
	testing.expect(t, posix.chdir(cgone) == .OK)
	testing.expect(t, posix.rmdir(cgone) == .OK)
	_, cwd_err := os.get_working_directory(context.temp_allocator)
	if !testing.expect(t, cwd_err != nil, "the working directory is still readable") {return}

	for r in PATH_REQUESTS {
		client, far := path_client(r.reply)
		defer {tui.client_close(&client); posix.close(far)}
		testing.expect(t, !send_path(&client, r.verb, "rel/bank.json"), r.verb)
		testing.expect(t, !anything_sent(far), r.verb)
		testing.expect(t, client.fd >= 0, r.verb)
		testing.expect_value(t, client.next_id, 1)
		testing.expect(t, client.notice != "", r.verb)
		// An absolute path needs no directory, and goes as it did.
		testing.expect(t, send_path(&client, r.verb, "/abs/bank.json"), r.verb)
		testing.expect_value(t, sent_line(far), fmt.tprintf("1 1 %s /abs/bank.json", r.verb))
	}
}
