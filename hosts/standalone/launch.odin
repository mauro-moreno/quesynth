#+build linux
package standalone

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

import "../../src/control"
import "tui"

// Where the control socket lives, and the client half of `quesynth --stop`.
//
// The socket path prefers $XDG_RUNTIME_DIR -- the per-user runtime directory a
// login session already owns, cleaned up on logout -- and falls back to a
// uid-qualified name under /tmp when it is unset (a bare cron or container
// session). Either way the path is local and private to the user; the daemon
// binds no network port (plan §36).

// The control socket path. The caller owns the returned string.
control_socket_path :: proc() -> string {
	xdg := libc.getenv("XDG_RUNTIME_DIR")
	if xdg != nil && len(string(xdg)) > 0 {
		dir := fmt.tprintf("%s/quesynth", string(xdg))
		cdir := strings.clone_to_cstring(dir)
		posix.mkdir(cdir, {.IRUSR, .IWUSR, .IXUSR}) // 0o700; harmless if it exists
		delete(cdir)
		return fmt.aprintf("%s/quesynth.sock", dir)
	}
	return fmt.aprintf("/tmp/quesynth-%d.sock", u32(posix.getuid()))
}

// Connect to a running daemon and ask it to shut down. Returns the exit code.
run_stop :: proc() -> int {
	path := control_socket_path()
	defer delete(path)

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		fmt.eprintfln("error: cannot create a control socket")
		return 1
	}
	defer posix.close(fd)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		fmt.eprintfln("error: socket path too long: %s", path)
		return 1
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0

	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		fmt.eprintfln("error: no daemon listening at %s", path)
		return 1
	}

	frame := control.frame_encode(transmute([]u8)string("1 1 daemon.shutdown"))
	defer delete(frame)
	posix.write(fd, raw_data(frame), c.size_t(len(frame)))
	fmt.println("stop requested")
	return 0
}

// The default `quesynth`: make sure a daemon is running, then attach the TUI to
// it. The daemon is a separate, detached process, so quitting the TUI leaves it
// -- and the audio -- running (plan Invariant 3, §47).
run_tui :: proc(patch_path: string) -> int {
	path, ok := ensure_daemon(patch_path)
	if !ok {
		fmt.eprintfln("error: could not start or reach a daemon")
		return 1
	}
	defer delete(path)
	return tui.run(path)
}

// Attach if a daemon is already listening; otherwise spawn one detached and wait
// for its socket to come up. Returns the socket path on success.
ensure_daemon :: proc(patch_path: string) -> (path: string, ok: bool) {
	path = control_socket_path()
	if daemon_listening(path) {
		return path, true
	}
	if !spawn_daemon(patch_path) {
		delete(path)
		return "", false
	}
	// Give the fresh daemon time to open its device and bind the socket.
	for _ in 0 ..< 50 {
		sleep_ms(100)
		if daemon_listening(path) {
			return path, true
		}
	}
	delete(path)
	return "", false
}

@(private = "file")
daemon_listening :: proc(path: string) -> bool {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		return false
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0
	return posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK
}

// Fork a detached daemon that re-execs this same binary with --daemon. The
// child leaves the terminal's session with setsid and silences its stdio, so it
// neither dies with the TUI nor writes over its screen. SIGCHLD is ignored so a
// daemon that exits early leaves no zombie behind the TUI.
@(private = "file")
spawn_daemon :: proc(patch_path: string) -> bool {
	posix.signal(.SIGCHLD, transmute(proc "cdecl" (posix.Signal))posix.SIG_IGN)
	pid := posix.fork()
	if pid < 0 {
		return false
	}
	if pid != 0 {
		return true // parent: the TUI carries on
	}

	posix.setsid()
	devnull := posix.open("/dev/null", {.RDWR})
	if devnull >= 0 {
		posix.dup2(devnull, posix.STDIN_FILENO)
		posix.dup2(devnull, posix.STDOUT_FILENO)
		posix.dup2(devnull, posix.STDERR_FILENO)
	}

	exe: cstring = "/proc/self/exe"
	if patch_path == "" {
		argv := [?]cstring{"quesynth", "--daemon", nil}
		posix.execv(exe, raw_data(argv[:]))
	} else {
		cpatch := strings.clone_to_cstring(patch_path)
		argv := [?]cstring{"quesynth", "--daemon", cpatch, nil}
		posix.execv(exe, raw_data(argv[:]))
	}
	// execv only returns on failure.
	posix._exit(127)
}
