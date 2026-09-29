package standalone

import "core:time"

// The runtime metrics a client reads with daemon.info.
//
// The static fields are filled once at startup. active_voices is stored every
// block by the audio thread -- a single relaxed atomic, the only per-block cost
// the control plane adds -- and read atomically by the control thread. Uptime is
// derived from start_tick by the reader, so nothing has to tick it.
Daemon_Metrics :: struct {
	sample_rate:   int,
	buffer_size:   int,
	max_voices:    int,
	backend:       string,
	start_tick:    time.Tick,
	active_voices: u32,
}
