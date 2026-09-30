#+build linux
package standalone

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

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

	client, connected := tui.client_connect(path)
	if !connected {
		fmt.eprintfln("error: no daemon listening at %s", path)
		return 1
	}
	defer tui.client_close(&client)
	if !tui.client_shutdown(&client) {
		fmt.eprintfln("error: daemon did not acknowledge stop")
		return 1
	}
	fmt.println("stop requested")
	return 0
}

// The default `quesynth`: make sure a daemon is running, then attach the TUI to
// it. The daemon is a separate, detached process, so quitting the TUI leaves it
// -- and the audio -- running (plan Invariant 3, §47).
run_tui :: proc(patch_path: string, bank_path: string) -> int {
	path, ok := ensure_daemon(patch_path, bank_path)
	if !ok {
		fmt.eprintfln("error: could not start or reach a daemon")
		return 1
	}
	defer delete(path)
	return tui.run(path)
}

// Attach if a daemon is already listening; otherwise spawn one detached and wait
// for its socket to come up. Returns the socket path on success.
ensure_daemon :: proc(patch_path: string, bank_path: string) -> (path: string, ok: bool) {
	path = control_socket_path()

	if daemon_is_running(path) {
		return path, true
	}
	if !spawn_daemon(patch_path, bank_path) {
		delete(path)
		return "", false
	}
	// Give the fresh daemon time to open its device and bind the socket.
	for _ in 0 ..< 50 {
		sleep_ms(100)
		if daemon_is_running(path) {
			return path, true
		}
	}
	delete(path)
	return "", false
}

// Start the shared HTML panel in a real browser while keeping audio in the
// native daemon. The Node helper is only the local HTTP/WebSocket adapter; it
// never owns synth state or audio.
run_browser :: proc(patch_path: string, bank_path: string) -> int {
	socket, ok := ensure_daemon(patch_path, bank_path)
	if !ok {
		fmt.eprintln("error: could not start or reach a daemon")
		return 1
	}
	root := "."
	if p := libc.getenv("QUESYNTH_ROOT"); p != nil && len(string(p)) > 0 { root = string(p) }
	pid := posix.fork()
	if pid < 0 { delete(socket); return 1 }
	if pid == 0 {
		node := strings.clone_to_cstring("node")
		script := strings.clone_to_cstring(fmt.tprintf("%s/hosts/standalone/browser/serve.js", root))
		r := strings.clone_to_cstring(root)
		s := strings.clone_to_cstring(socket)
		argv: [7]cstring = {node, script, "--root", r, "--socket", s, nil}
		posix.execvp(node, raw_data(argv[:]))
		posix._exit(127)
	}
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 {
		if posix.errno() != .EINTR { delete(socket); return 1 }
	}
	delete(socket)
	// The adapter's own outcome is the command's: a script or wrapper must be
	// able to tell that the browser front-end failed. 127 is the child's exec
	// failure above -- node is not on PATH -- which deserves a hint, not a code.
	switch {
	case posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 127:
		fmt.eprintln("error: could not start node; is Node.js installed?")
		return 1
	case posix.WIFEXITED(status):
		return int(posix.WEXITSTATUS(status))
	case posix.WIFSIGNALED(status):
		return 128 + int(posix.WTERMSIG(status))
	}
	return 1
}

// Whether a daemon is already listening at the path: a plain connect probe. Used
// to attach instead of spawning, and to refuse starting a second daemon over a
// live one.
daemon_is_running :: proc(path: string) -> bool {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	if posix.fcntl(fd, .SETFL, c.int(posix.O_NONBLOCK)) < 0 { return false }
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		return false
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK {
		return true
	}
	// A full backlog still belongs to a live listener; never wait on a probe.
	return posix.errno() == .EAGAIN || posix.errno() == .EINPROGRESS
}

// Spawn a fully detached daemon that re-execs this same binary with --daemon.
//
// This is the textbook double fork. The immediate child calls setsid to leave
// the terminal's session, then forks again and exits, so the grandchild -- the
// daemon -- is reparented to init: it can never be a job of the launching shell
// nor die with the TUI, and the parent reaps that immediate child at once, so no
// zombie is left and SIGCHLD needs no special handling.
//
// Before exec the daemon points its stdio at /dev/null and closes every other
// inherited descriptor. That last part matters: if the daemon kept a copy of the
// TUI's terminal or output pipe, whatever reads the TUI's output would never see
// end of file after the TUI exits, and would hang waiting on a process that has
// already gone.
@(private = "file")
spawn_daemon :: proc(patch_path: string, bank_path: string) -> bool {
	pid := posix.fork()
	if pid < 0 {
		return false
	}
	if pid != 0 {
		// Parent: reap the immediate child, which exits as soon as it has forked
		// the daemon.
		posix.waitpid(pid, nil, {})
		return true
	}

	// Immediate child: detach from the terminal, fork the daemon, get out of the
	// way so the daemon reparents to init.
	posix.setsid()
	if posix.fork() != 0 {
		posix._exit(0)
	}

	// Grandchild: the daemon. Silence stdio and drop every other inherited
	// descriptor before becoming it.
	devnull := posix.open("/dev/null", {.RDWR})
	if devnull >= 0 {
		posix.dup2(devnull, posix.STDIN_FILENO)
		posix.dup2(devnull, posix.STDOUT_FILENO)
		posix.dup2(devnull, posix.STDERR_FILENO)
	}
	for fd in 3 ..< 1024 {
		posix.close(posix.FD(fd))
	}

	// Rebuild the daemon's argv, forwarding --bank and the patch so the daemon
	// this front-end spawns loads the same bank the user asked for.
	exe: cstring = "/proc/self/exe"
	argv: [dynamic]cstring
	append(&argv, "quesynth", "--daemon")
	if bank_path != "" {
		append(&argv, "--bank", strings.clone_to_cstring(bank_path))
	}
	if patch_path != "" {
		append(&argv, strings.clone_to_cstring(patch_path))
	}
	append(&argv, nil)
	posix.execv(exe, raw_data(argv[:]))
	// execv only returns on failure.
	posix._exit(127)
}
