#+build !linux
package mcp

roundtrip :: proc(path, line: string) -> (payload: []u8, failure: Failure, sent: bool) {
	return nil, {"daemon_unavailable", "the daemon QCP transport is supported on Linux only"}, false
}
