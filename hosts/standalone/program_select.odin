package standalone

import "../../src/patch"

// The audio thread forwards selection messages; the control thread owns the
// bank, identity and ring producer. On platforms without a control server the
// daemon's main thread drains them instead. No client needs to be connected.
// Only bank 0 exists: it is the current Slots, not an archive bank index.
DAEMON_BANK :: 0
MIDI_CHANNELS :: 16

// Each half starts at zero and persists across Program Changes. A controller
// sending only one half keeps the other half's last value.
Bank_Select :: struct {
	msb: u8,
	lsb: u8,
}

Program_Select :: struct {
	// The consumer side of Live.select_queue.
	queue:    ^Midi_Queue,
	// Every channel starts at bank 0, so a bare Program Change selects from
	// the daemon's bank.
	channels: [MIDI_CHANNELS]Bank_Select,
	// A Program Change the ring had no room for. It goes first on the next
	// drain, and nothing behind it is read until it loads or stops selecting.
	held:     u32,
	has_held: bool,
}

// Preserve order and repeated loads. Bound the work so MIDI cannot starve
// clients. A load the ring has no room for waits rather than being refused,
// so a burst ends on its last Program Change; it is resolved again when room
// returns, since the bank may have been replaced in the meantime.
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
		slot, selects := program_select_message(ps, cc.bank, message)
		if !selects {continue}
		if !bank_load_has_room(cc) {
			ps.held, ps.has_held = message, true
			return
		}
		bank_load_slot(cc, slot)
	}
}

// Fold one forwarded message into the channel state. A Program Change that
// selects a filled slot of the daemon's bank reports it; everything else --
// Bank Select, a missing bank, an empty slot, a data byte the wire cannot
// carry -- selects nothing, and a failure leaves the channel as it was.
@(private = "file")
program_select_message :: proc(
	ps: ^Program_Select,
	bank: ^patch.Slots,
	message: u32,
) -> (
	slot: int,
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
		case MIDI_BANK_SELECT_LSB:
			channel.lsb = data2
		}
	case MIDI_PROGRAM_CHANGE:
		if data1 > 127 {return}
		if int(channel.msb) * 128 + int(channel.lsb) != DAEMON_BANK {return}
		if _, filled := patch.slots_patch(bank, int(data1)); !filled {return}
		return int(data1), true
	}
	return
}
