#+build windows
package standalone

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// Windows MIDI input: the multimedia API (winmm).
//
// The other half of the platform seam in backend.odin. It opens every input the
// system reports, or the one the daemon's selection names, and pushes what
// arrives into the lock-free queue; it never touches the engine, and it never
// learns what a note is.
//
// core:sys/windows ships winmm bindings, but only the waveOut, waveIn and timer
// halves -- there are no midiIn declarations -- so the seven entry points this
// needs are declared below.
//
// Threading: winmm calls the callback on a thread it owns, one per open device.
// Two devices therefore produce concurrently, which is exactly why the queue in
// ring.odin is multi-producer. The documented rule for this callback is that it
// may only call a small set of system functions; it obeys a stricter rule than
// that and calls nothing at all except the queue push, which is wait-free
// enough to be safe here and cannot re-enter winmm.

foreign import winmm "system:Winmm.lib"

HMIDIIN :: win.HANDLE

MAXPNAMELEN :: 32

MIDIINCAPSW :: struct #packed {
	wMid:           win.WORD,
	wPid:           win.WORD,
	vDriverVersion: win.UINT,
	szPname:        [MAXPNAMELEN]win.WCHAR,
	dwSupport:      win.DWORD,
}

// The callback message we care about. MIM_DATA carries one complete short
// (channel voice or system) message; the LONGDATA variants carry sysex, which
// this shell has no use for.
MIM_DATA :: 0x3C3

CALLBACK_FUNCTION :: 0x00030000

MMSYSERR_NOERROR :: 0

Midi_In_Proc :: proc "system" (
	device: HMIDIIN,
	message: win.UINT,
	instance: win.DWORD_PTR,
	param1: win.DWORD_PTR,
	param2: win.DWORD_PTR,
)

@(default_calling_convention = "system")
foreign winmm {
	midiInGetNumDevs :: proc() -> win.UINT ---
	midiInGetDevCapsW :: proc(device_id: win.UINT_PTR, caps: ^MIDIINCAPSW, size: win.UINT) -> win.MMRESULT ---
	midiInOpen :: proc(handle: ^HMIDIIN, device_id: win.UINT, callback: Midi_In_Proc, instance: win.DWORD_PTR, flags: win.DWORD) -> win.MMRESULT ---
	midiInStart :: proc(handle: HMIDIIN) -> win.MMRESULT ---
	midiInStop :: proc(handle: HMIDIIN) -> win.MMRESULT ---
	midiInReset :: proc(handle: HMIDIIN) -> win.MMRESULT ---
	midiInClose :: proc(handle: HMIDIIN) -> win.MMRESULT ---
}

Winmm_Midi :: struct {
	handles: [dynamic]HMIDIIN,
	names:   [dynamic]string,
}

winmm_midi_input :: proc() -> (Midi_Input, bool) {
	m := new(Winmm_Midi)
	input := Midi_Input {
		impl         = m,
		open         = winmm_midi_open,
		list         = winmm_midi_list,
		open_device  = winmm_midi_open_device,
		close_inputs = winmm_midi_close_inputs,
		close        = winmm_midi_close,
	}
	return input, true
}

// Open every input the system reports.
//
// A device that refuses to open is skipped rather than failing the whole call:
// one busy controller should not stop the other three from playing. Opening
// none at all is still success -- the synthesiser runs, it just has nothing
// attached to play it.
winmm_midi_open :: proc(input: ^Midi_Input, queue: ^Midi_Queue) -> bool {
	m := (^Winmm_Midi)(input.impl)

	count := int(midiInGetNumDevs())
	for id in 0 ..< count {
		winmm_midi_open_port(m, queue, id)
	}

	input.count = len(m.handles)
	input.names = m.names[:]
	return true
}

// Every input, open or not. winmm knows a device only by its index, so that is
// the id; the name is the driver's, which two identical controllers share.
winmm_midi_list :: proc(input: ^Midi_Input) -> []Midi_Device {
	count := int(midiInGetNumDevs())
	devices := make([]Midi_Device, count)
	for id in 0 ..< count {
		devices[id] = Midi_Device {
			id   = fmt.aprintf("winmm:%d", id),
			name = winmm_midi_name(id),
		}
	}
	return devices
}

// Open the one input listed as `id`, if it is still there.
winmm_midi_open_device :: proc(input: ^Midi_Input, queue: ^Midi_Queue, id: string) -> bool {
	m := (^Winmm_Midi)(input.impl)
	count := int(midiInGetNumDevs())
	for index in 0 ..< count {
		buffer: [32]u8
		if fmt.bprintf(buffer[:], "winmm:%d", index) != id {
			continue
		}
		opened := winmm_midi_open_port(m, queue, index)
		input.count = len(m.handles)
		input.names = m.names[:]
		return opened
	}
	return false
}

// The driver's name for an input. The fallback is cloned rather than used as a
// literal so every name has the same owner and can be freed alike.
winmm_midi_name :: proc(id: int) -> string {
	caps: MIDIINCAPSW
	if midiInGetDevCapsW(win.UINT_PTR(id), &caps, size_of(MIDIINCAPSW)) == MMSYSERR_NOERROR {
		if text, err := win.wstring_to_utf8(
			win.wstring(raw_data(caps.szPname[:])),
			-1,
			context.allocator,
		); err == nil && text != "" {
			return text
		}
	}
	return strings.clone("(unnamed input)")
}

// Open one input and start it. On failure nothing is added.
winmm_midi_open_port :: proc(m: ^Winmm_Midi, queue: ^Midi_Queue, id: int) -> bool {
	handle: HMIDIIN
	// The queue pointer travels as the callback instance, so the callback
	// needs no globals and no state of its own.
	result := midiInOpen(
		&handle,
		win.UINT(id),
		winmm_midi_callback,
		win.DWORD_PTR(uintptr(queue)),
		CALLBACK_FUNCTION,
	)
	if result != MMSYSERR_NOERROR {
		return false
	}
	if midiInStart(handle) != MMSYSERR_NOERROR {
		midiInClose(handle)
		return false
	}

	append(&m.handles, handle)
	append(&m.names, winmm_midi_name(id))
	return true
}

// Runs on a winmm-owned thread, one per device.
winmm_midi_callback :: proc "system" (
	device: HMIDIIN,
	message: win.UINT,
	instance: win.DWORD_PTR,
	param1: win.DWORD_PTR,
	param2: win.DWORD_PTR,
) {
	if message != MIM_DATA {
		return
	}
	queue := (^Midi_Queue)(uintptr(instance))
	if queue == nil {
		return
	}

	// param1 already packs the message as status | data1<<8 | data2<<16, which
	// is exactly the queue's own layout, so nothing has to be rearranged.
	packed := u32(param1) & 0x00FFFFFF

	// Only channel voice messages are forwarded. System messages start at 0xF0
	// and include the clock, which arrives twenty-four times a beat and would
	// fill the queue with traffic nothing downstream reads.
	if packed & 0xF0 == 0xF0 {
		return
	}

	// A full queue drops the message and counts it. There is no other
	// real-time-safe option, and the count is reported on shutdown.
	midi_queue_push(queue, packed)
}

// Stop and close every open input, keeping the backend ready for another open.
// With nothing open it does nothing, so the final close after a switch to none
// closes nothing twice.
winmm_midi_close_inputs :: proc(input: ^Midi_Input) {
	m := (^Winmm_Midi)(input.impl)
	if m == nil {
		return
	}

	for handle in m.handles {
		// Stop before reset before close, which is the documented order. Reset
		// releases anything the driver still holds and guarantees the callback
		// has finished, so closing cannot race a message in flight.
		midiInStop(handle)
		midiInReset(handle)
		midiInClose(handle)
	}
	clear(&m.handles)

	for name in m.names {
		delete(name)
	}
	clear(&m.names)

	input.count = 0
	input.names = nil
}

winmm_midi_close :: proc(input: ^Midi_Input) {
	m := (^Winmm_Midi)(input.impl)
	if m == nil {
		return
	}

	winmm_midi_close_inputs(input)
	delete(m.handles)
	delete(m.names)

	free(m)
	input.impl = nil
}
