#+build !windows
package standalone

import "core:strings"
import "core:sys/posix"

// Whether path, with symlinks followed, names a regular file. A true stat(2),
// not core:os's stat, which opens the path to read it and so would wait on a
// FIFO exactly as opening the archive would.
path_is_regular_file :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	return posix.stat(cpath, &st) == .OK && posix.S_ISREG(st.st_mode)
}
