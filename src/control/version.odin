package control

// The Quesynth Control Protocol version. It moves when the wire contract
// changes, not when Quesynth does (docs/standalone-daemon-plan.md, Invariant
// 10): a daemon reports the versions it supports so a client can detect an
// incompatible peer cleanly rather than misparsing it. On the wire this is
// "QCP/1"; in code it is the integer below.
PROTOCOL_VERSION :: 1
