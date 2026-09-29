#+build linux
package standalone

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

import "../../src/control"

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
