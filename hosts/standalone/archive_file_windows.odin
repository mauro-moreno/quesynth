#+build windows
package standalone

import "core:os"

// Whether path, with symlinks followed, names a regular file. Windows reads a
// file's attributes without opening it, so core:os's stat does not wait.
path_is_regular_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil && info.type == .Regular
}
