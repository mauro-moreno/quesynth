#+build windows
package standalone

import "core:strings"
import win "core:sys/windows"

// Windows MIDI input: the multimedia API (winmm).
//
// The other half of the platform seam in backend.odin. It opens every input the
// system reports and pushes what arrives into the lock-free queue; it never
// touches the engine, and it never learns what a note is.
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
		impl  = m,
		open  = winmm_midi_open,
		close = winmm_midi_close,
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
		caps: MIDIINCAPSW
		name: string
		if midiInGetDevCapsW(win.UINT_PTR(id), &caps, size_of(MIDIINCAPSW)) == MMSYSERR_NOERROR {
			if text, err := win.wstring_to_utf8(
				win.wstring(raw_data(caps.szPname[:])),
				-1,
				context.allocator,
			); err == nil {
				name = text
			}
		}
		// The fallback is cloned rather than used as a literal so every entry
		// in `names` has the same owner and `close` can free them all alike.
		if name == "" {
			name = strings.clone("(unnamed input)")
		}

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
			continue
		}
		if midiInStart(handle) != MMSYSERR_NOERROR {
			midiInClose(handle)
			continue
		}

		append(&m.handles, handle)
		append(&m.names, name)
	}

	input.count = len(m.handles)
	input.names = m.names[:]
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

winmm_midi_close :: proc(input: ^Midi_Input) {
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
	delete(m.handles)

	for name in m.names {
		delete(name)
	}
	delete(m.names)

	free(m)
	input.impl = nil
	input.count = 0
	input.names = nil
}
