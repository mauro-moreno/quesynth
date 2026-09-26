#+build linux
package standalone

import "base:intrinsics"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:sys/posix"

// Linux MIDI input: ALSA raw MIDI.
//
// The other half of the platform seam in backend.odin, the Linux counterpart of
// midi_winmm.odin. It opens every hardware MIDI input the system reports and
// pushes what arrives into the lock-free queue; it never touches the engine, and
// it never learns what a note is.
//
// Raw MIDI rather than the sequencer API: rawmidi delivers a plain byte stream,
// so the whole ALSA-facing surface is an open, a read and a close plus a short
// enumeration -- no snd_seq_event_t union to bind through dlsym and get subtly
// wrong. The cost is that only hardware ports are seen, not the virtual ports
// other applications publish; a controller plugged into the machine, which is
// what a standalone synthesiser is played from, is a hardware port.
//
// One thread per open device, each reading in non-blocking mode and napping when
// idle. Non-blocking is what makes close prompt: a thread parked in a blocking
// read could only be woken by closing the handle underneath it, which races the
// read. Two devices produce concurrently, which is why the queue in ring.odin is
// multi-producer.

MIDI_LIBRARY :: "libasound.so.2"

SND_RAWMIDI_STREAM_INPUT :: 1
SND_RAWMIDI_NONBLOCK :: 2

// ALSA returns negated errno values. -EAGAIN is the ordinary "no bytes waiting"
// answer in non-blocking mode and means nap, not fail.
ALSA_EAGAIN :: -11

// Poll interval when a device has no bytes waiting. 1 ms is inaudible as input
// latency and keeps the idle thread from spinning.
MIDI_NAP_NS :: 1_000_000

Snd_Rawmidi_Open :: #type proc "c" (in_rmidi: ^rawptr, out_rmidi: ^rawptr, name: cstring, mode: i32) -> i32
Snd_Rawmidi_Read :: #type proc "c" (rmidi: rawptr, buffer: rawptr, size: c.ulong) -> c.long
Snd_Rawmidi_Close :: #type proc "c" (rmidi: rawptr) -> i32
Snd_Card_Next :: #type proc "c" (card: ^i32) -> i32
Snd_Ctl_Open :: #type proc "c" (ctl: ^rawptr, name: cstring, mode: i32) -> i32
Snd_Ctl_Close :: #type proc "c" (ctl: rawptr) -> i32
Snd_Ctl_Rawmidi_Next_Device :: #type proc "c" (ctl: rawptr, device: ^i32) -> i32
Snd_Ctl_Rawmidi_Info :: #type proc "c" (ctl: rawptr, info: rawptr) -> i32
Snd_Rawmidi_Info_Sizeof :: #type proc "c" () -> c.ulong
Snd_Rawmidi_Info_Set_Device :: #type proc "c" (info: rawptr, val: u32)
Snd_Rawmidi_Info_Set_Subdevice :: #type proc "c" (info: rawptr, val: u32)
Snd_Rawmidi_Info_Set_Stream :: #type proc "c" (info: rawptr, stream: i32)
Snd_Rawmidi_Info_Get_Name :: #type proc "c" (info: rawptr) -> cstring

Alsa_Midi :: struct {
	lib:                dynlib.Library,
	loaded:             bool,

	rawmidi_open:       Snd_Rawmidi_Open,
	rawmidi_read:       Snd_Rawmidi_Read,
	rawmidi_close:      Snd_Rawmidi_Close,
	card_next:          Snd_Card_Next,
	ctl_open:           Snd_Ctl_Open,
	ctl_close:          Snd_Ctl_Close,
	next_device:        Snd_Ctl_Rawmidi_Next_Device,
	ctl_info:           Snd_Ctl_Rawmidi_Info,
	info_sizeof:        Snd_Rawmidi_Info_Sizeof,
	info_set_device:    Snd_Rawmidi_Info_Set_Device,
	info_set_subdevice: Snd_Rawmidi_Info_Set_Subdevice,
	info_set_stream:    Snd_Rawmidi_Info_Set_Stream,
	info_get_name:      Snd_Rawmidi_Info_Get_Name,

	ports:              [dynamic]^Alsa_Midi_Port,
	names:              [dynamic]string,

	// One flag for every reader thread; set false by close, read each nap.
	running:            b32,
}

// Per-device reader state. Each thread owns one, and the running-status parser
// keeps its half-built message here between reads.
Alsa_Midi_Port :: struct {
	owner:  ^Alsa_Midi,
	handle: rawptr,
	queue:  ^Midi_Queue,
	thread: posix.pthread_t,

	// Running-status decode state; see midi_alsa_byte.
	status: u8,
	data:   [2]u8,
	have:   int,
}

alsa_midi_input :: proc() -> (Midi_Input, bool) {
	m := new(Alsa_Midi)
	input := Midi_Input {
		impl  = m,
		open  = alsa_midi_open,
		close = alsa_midi_close,
	}
	return input, true
}

alsa_midi_load :: proc(m: ^Alsa_Midi) -> bool {
	if m.loaded {
		return true
	}
	lib, ok := dynlib.load_library(MIDI_LIBRARY)
	if !ok {
		return false
	}

	bound := true
	m.rawmidi_open = transmute(Snd_Rawmidi_Open)alsa_symbol(lib, "snd_rawmidi_open", &bound)
	m.rawmidi_read = transmute(Snd_Rawmidi_Read)alsa_symbol(lib, "snd_rawmidi_read", &bound)
	m.rawmidi_close = transmute(Snd_Rawmidi_Close)alsa_symbol(lib, "snd_rawmidi_close", &bound)
	m.card_next = transmute(Snd_Card_Next)alsa_symbol(lib, "snd_card_next", &bound)
	m.ctl_open = transmute(Snd_Ctl_Open)alsa_symbol(lib, "snd_ctl_open", &bound)
	m.ctl_close = transmute(Snd_Ctl_Close)alsa_symbol(lib, "snd_ctl_close", &bound)
	m.next_device = transmute(Snd_Ctl_Rawmidi_Next_Device)alsa_symbol(lib, "snd_ctl_rawmidi_next_device", &bound)
	m.ctl_info = transmute(Snd_Ctl_Rawmidi_Info)alsa_symbol(lib, "snd_ctl_rawmidi_info", &bound)
	m.info_sizeof = transmute(Snd_Rawmidi_Info_Sizeof)alsa_symbol(lib, "snd_rawmidi_info_sizeof", &bound)
	m.info_set_device = transmute(Snd_Rawmidi_Info_Set_Device)alsa_symbol(lib, "snd_rawmidi_info_set_device", &bound)
	m.info_set_subdevice = transmute(Snd_Rawmidi_Info_Set_Subdevice)alsa_symbol(lib, "snd_rawmidi_info_set_subdevice", &bound)
	m.info_set_stream = transmute(Snd_Rawmidi_Info_Set_Stream)alsa_symbol(lib, "snd_rawmidi_info_set_stream", &bound)
	m.info_get_name = transmute(Snd_Rawmidi_Info_Get_Name)alsa_symbol(lib, "snd_rawmidi_info_get_name", &bound)

	if !bound {
		dynlib.unload_library(lib)
		return false
	}

	m.lib = lib
	m.loaded = true
	return true
}

// Open every hardware raw-MIDI input across every sound card.
//
// A device that refuses to open is skipped rather than failing the whole call:
// one busy controller must not stop the others. Opening none is still success --
// the synthesiser runs, it just has nothing attached to play it.
alsa_midi_open :: proc(input: ^Midi_Input, queue: ^Midi_Queue) -> bool {
	m := (^Alsa_Midi)(input.impl)
	if !alsa_midi_load(m) {
		// No libasound is the same situation as no MIDI hardware: not a failure.
		input.count = 0
		return true
	}
	// Raised before any reader thread is created; each thread checks it on every
	// nap and exits when close clears it.
	intrinsics.atomic_store_explicit(&m.running, true, .Release)


	// The info block is opaque and sized by the library; a byte buffer of the
	// reported size, cleared, is what its setters and getters expect.
	info_size := int(m.info_sizeof())
	info := make([]u8, info_size, context.temp_allocator)

	card := i32(-1)
	if m.card_next(&card) < 0 {
		card = -1
	}
	for card >= 0 {
		ctl_name := fmt.ctprintf("hw:%d", card)
		ctl: rawptr
		if m.ctl_open(&ctl, ctl_name, 0) >= 0 && ctl != nil {
			device := i32(-1)
			for {
				if m.next_device(ctl, &device) < 0 || device < 0 {
					break
				}

				for i in 0 ..< info_size {
					info[i] = 0
				}
				m.info_set_device(raw_data(info), u32(device))
				m.info_set_subdevice(raw_data(info), 0)
				m.info_set_stream(raw_data(info), SND_RAWMIDI_STREAM_INPUT)
				// Non-zero means this device has no input on subdevice 0; skip.
				if m.ctl_info(ctl, raw_data(info)) < 0 {
					continue
				}

				name := alsa_midi_device_name(m, info, card, device)
				alsa_midi_open_device(m, queue, card, device, name)
			}
			m.ctl_close(ctl)
		}

		if m.card_next(&card) < 0 {
			break
		}
	}

	input.count = len(m.ports)
	input.names = m.names[:]
	return true
}

// The friendly name the library reports, falling back to the hw address so every
// entry has an owned string that close can free alike.
alsa_midi_device_name :: proc(m: ^Alsa_Midi, info: []u8, card, device: i32) -> string {
	raw := m.info_get_name(raw_data(info))
	text := string(raw) if raw != nil else ""
	if text == "" {
		return fmt.aprintf("hw:%d,%d", card, device)
	}
	return fmt.aprintf("%s (hw:%d,%d)", text, card, device)
}

// Open one device in non-blocking input mode and start its reader thread. On any
// failure the half-built port is dropped and the name freed.
alsa_midi_open_device :: proc(m: ^Alsa_Midi, queue: ^Midi_Queue, card, device: i32, name: string) {
	hw := fmt.ctprintf("hw:%d,%d", card, device)
	handle: rawptr
	if m.rawmidi_open(&handle, nil, hw, SND_RAWMIDI_NONBLOCK) < 0 || handle == nil {
		delete(name)
		return
	}

	port := new(Alsa_Midi_Port)
	port.owner = m
	port.handle = handle
	port.queue = queue

	if posix.pthread_create(&port.thread, nil, alsa_midi_thread, port) != .NONE {
		m.rawmidi_close(handle)
		free(port)
		delete(name)
		return
	}

	append(&m.ports, port)
	append(&m.names, name)
}

// Runs on its own thread, one per device. Reads bytes and feeds them to the
// running-status decoder, napping while the port is idle.
alsa_midi_thread :: proc "c" (arg: rawptr) -> rawptr {
	port := (^Alsa_Midi_Port)(arg)
	m := port.owner

	buffer: [64]u8
	for intrinsics.atomic_load_explicit(&m.running, .Acquire) {
		read := m.rawmidi_read(port.handle, raw_data(buffer[:]), c.ulong(len(buffer)))
		if read > 0 {
			for i in 0 ..< int(read) {
				alsa_midi_byte(port, buffer[i])
			}
			continue
		}
		// -EAGAIN means simply nothing waiting; anything else is a real error
		// (a device unplugged, most often) and ends this reader.
		if read < 0 && read != ALSA_EAGAIN {
			break
		}
		alsa_midi_nap()
	}
	return nil
}

// Decode one raw MIDI byte, emitting a packed message once a channel-voice
// message is complete. Running status is honoured: a data byte with no fresh
// status reuses the previous one, which is how a stream of same-type messages
// arrives on the wire.
alsa_midi_byte :: proc "c" (port: ^Alsa_Midi_Port, value: u8) {
	// System real-time bytes (0xF8..0xFF) may interleave anywhere and carry no
	// data; they are ignored without disturbing a message in progress.
	if value >= 0xF8 {
		return
	}
	if value >= 0x80 {
		// A system-common status (0xF0..0xF7) both cancels running status and is
		// itself ignored here -- nothing downstream reads sysex or song select.
		if value >= 0xF0 {
			port.status = 0
			port.have = 0
			return
		}
		port.status = value
		port.have = 0
		return
	}

	// A data byte with no running status to attach to is unattributable; drop it.
	if port.status == 0 {
		return
	}

	port.data[port.have] = value
	port.have += 1
	needed := alsa_midi_message_length(port.status)
	if port.have >= needed {
		second := port.data[1] if needed >= 2 else 0
		midi_queue_push(port.queue, midi_pack(port.status, port.data[0], second))
		// Keep the status: running status lets the next message omit it.
		port.have = 0
	}
}

// Data-byte count for a channel-voice status. Program change and channel
// pressure carry one; the rest carry two.
alsa_midi_message_length :: proc "c" (status: u8) -> int {
	switch status & 0xF0 {
	case 0xC0, 0xD0:
		return 1
	case:
		return 2
	}
}

alsa_midi_nap :: proc "c" () {
	request := posix.timespec {
		tv_sec  = 0,
		tv_nsec = MIDI_NAP_NS,
	}
	posix.nanosleep(&request, nil)
}

alsa_midi_close :: proc(input: ^Midi_Input) {
	m := (^Alsa_Midi)(input.impl)
	if m == nil {
		return
	}

	// Stop first so every reader sees the cleared flag on its next nap, then
	// join before closing any handle: a handle must not be closed while its
	// thread might still be inside a read.
	intrinsics.atomic_store_explicit(&m.running, false, .Release)
	for port in m.ports {
		posix.pthread_join(port.thread, nil)
	}
	for port in m.ports {
		if m.rawmidi_close != nil {
			m.rawmidi_close(port.handle)
		}
		free(port)
	}
	delete(m.ports)

	for name in m.names {
		delete(name)
	}
	delete(m.names)

	if m.loaded {
		dynlib.unload_library(m.lib)
		m.loaded = false
	}

	free(m)
	input.impl = nil
	input.count = 0
	input.names = nil
}
