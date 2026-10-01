package standalone

import "../../src/patch"

// The audio thread forwards selection messages; the control thread owns the
// bank, identity and ring producer. On platforms without a control server the
// daemon's main thread drains them instead. No client needs to be connected.
// Only bank 0 exists as a Bank Select number: it is the current Slots, not an
// archive bank index.
DAEMON_BANK :: 0
MIDI_CHANNELS :: 16

// Each half starts at zero and persists across Program Changes. A controller
// sending only one half keeps the other half's last value.
Bank_Select :: struct {
	msb:    u8,
	lsb:    u8,
	// Whether either half has ever arrived. A keyboard that sends a bare
	// Program Change has not asked for bank 0, so it stays in the bank the
	// sound is playing from; one that sent Bank Select 0 asked for the
	// daemon's bank. Never cleared, like the halves.
	chosen: bool,
}

Program_Select :: struct {
	// The consumer side of Live.select_queue.
	queue:    ^Midi_Queue,
	// Every channel starts with no bank chosen, so a bare Program Change
	// selects from the bank the sound is playing from.
	channels: [MIDI_CHANNELS]Bank_Select,
	// A Program Change the ring had no room for. It goes first on the next
	// drain, and nothing behind it is read until it loads or stops selecting.
	held:     u32,
	has_held: bool,
}

// A slot of the daemon's bank, or a patch of the archive bank the sound is
// playing from.
@(private = "file")
Program_Target :: struct {
	archive: bool,
	bank:    int,
	index:   int,
}

// Preserve order and repeated loads. Bound the work so MIDI cannot starve
// clients. A load the ring has no room for waits rather than being refused,
// so a burst ends on its last Program Change; it is resolved again when room
// returns, since the bank or the sound may have been replaced in the meantime.
program_select_drain :: proc(cc: ^Control_Context) {
	ps := cc.program
	if ps == nil || ps.queue == nil {return}
	for _ in 0 ..< MIDI_QUEUE_CAPACITY {
		message, ok := ps.held, ps.has_held
		if !ok {
			message, ok = midi_queue_pop(ps.queue)
			if !ok {break}
		}
		ps.has_held = false
		target, selects := program_select_message(ps, cc, message)
		if !selects {continue}
		if !program_select_load(cc, target) {
			ps.held, ps.has_held = message, true
			return
		}
	}
}

// Fold one forwarded message into the channel state. A Program Change that
// selects something reports it: a patch of the archive bank the sound came
// from, on a channel that has chosen no bank, or else a filled slot of the
// daemon's bank. Everything else -- Bank Select, a missing bank, an empty
// slot, a data byte the wire cannot carry -- selects nothing, and a failure
// leaves the channel as it was. An archive patch is checked as it loads,
// because reading it is the check.
@(private = "file")
program_select_message :: proc(
	ps: ^Program_Select,
	cc: ^Control_Context,
	message: u32,
) -> (
	target: Program_Target,
	selects: bool,
) {
	status := midi_status(message)
	channel := &ps.channels[status & 0x0F]
	data1 := midi_data1(message)
	data2 := midi_data2(message)

	switch status & 0xF0 {
	case MIDI_CONTROL_CHANGE:
		if data2 > 127 {return}
		switch data1 {
		case MIDI_BANK_SELECT_MSB:
			channel.msb = data2
			channel.chosen = true
		case MIDI_BANK_SELECT_LSB:
			channel.lsb = data2
			channel.chosen = true
		}
	case MIDI_PROGRAM_CHANGE:
		if data1 > 127 {return}
		if !channel.chosen {
			if bank, playing := program_playing_archive_bank(cc); playing {
				return {archive = true, bank = bank, index = int(data1)}, true
			}
		} else if int(channel.msb) * 128 + int(channel.lsb) != DAEMON_BANK {
			return
		}
		if _, filled := patch.slots_patch(cc.bank, int(data1)); !filled {return}
		return {index = int(data1)}, true
	}
	return
}

// The archive bank the sound came from, while the archive that supplied it is
// still the one open; the identity stops naming one as soon as it is not.
@(private = "file")
program_playing_archive_bank :: proc(cc: ^Control_Context) -> (bank: int, ok: bool) {
	id, a := cc.identity, cc.archive
	if id == nil || id.source != .Archive || a == nil || !a.open {return}
	if id.archive_bank < 0 || id.archive_bank >= len(a.bank_indices) {return}
	return id.archive_bank, true
}

// False when the load must wait for the ring to have room for a whole one.
@(private = "file")
program_select_load :: proc(cc: ^Control_Context, target: Program_Target) -> bool {
	if target.archive {return archive_program_load(cc, target.bank, target.index)}
	if !bank_load_has_room(cc) {return false}
	bank_load_slot(cc, target.index)
	return true
}
