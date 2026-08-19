#+build windows
package standalone

import "base:intrinsics"
import win "core:sys/windows"

// Windows audio output: WASAPI, shared mode, event driven.
//
// This is one half of the platform seam described in backend.odin. Nothing
// above it knows that COM exists; nothing in it knows what a note is.
//
// Odin ships no WASAPI bindings, so the four interfaces this needs are declared
// here from the documented vtable layouts. Only the methods actually called are
// given real signatures -- but every method *before* them still has to be
// present, because a vtable is an array and calling the wrong slot is how COM
// bindings go wrong. The unused trailing methods are simply omitted, which is
// safe: nothing ever reads past the last slot declared.
//
// Shared mode rather than exclusive: exclusive mode takes the endpoint away
// from every other application on the machine, which is hostile behaviour for
// something a user launches to try a patch. Event driven rather than polled:
// the device signals an event when it wants the next block, which is what lets
// the render thread sleep instead of spinning.

// -- GUIDs -------------------------------------------------------------------

CLSID_MMDeviceEnumerator := win.GUID {
	0xBCDE0395,
	0xE52F,
	0x467C,
	{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E},
}

IID_IMMDeviceEnumerator := win.GUID {
	0xA95664D2,
	0x9614,
	0x4F35,
	{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6},
}

IID_IAudioClient := win.GUID {
	0x1CB9AD4C,
	0xDBFA,
	0x4C32,
	{0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2},
}

IID_IAudioRenderClient := win.GUID {
	0xF294ACFC,
	0x3146,
	0x4483,
	{0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2},
}

// The subtype a WAVE_FORMAT_EXTENSIBLE mix format carries when its samples are
// 32-bit floats, which is the only thing the engine can write without a
// conversion pass.
KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := win.GUID {
	0x00000003,
	0x0000,
	0x0010,
	{0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71},
}

// PKEY_Device_FriendlyName: the string a user would recognise, e.g. "Speakers
// (Realtek Audio)". The property key is a GUID plus an id, not a GUID alone.
PKEY_Device_FriendlyName := Property_Key {
	fmtid = {0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}},
	pid = 14,
}

Property_Key :: struct {
	fmtid: win.GUID,
	pid:   u32,
}

// -- constants ---------------------------------------------------------------

AUDCLNT_SHAREMODE_SHARED :: 0
AUDCLNT_STREAMFLAGS_EVENTCALLBACK :: 0x00040000

// EDataFlow / ERole, both of which are plain enums on the wire.
E_DATA_FLOW_RENDER :: 0
E_ROLE_CONSOLE :: 0

STGM_READ :: 0

WAVE_FORMAT_IEEE_FLOAT :: 0x0003
WAVE_FORMAT_EXTENSIBLE :: 0xFFFE

VT_LPWSTR :: 31

// -- interfaces --------------------------------------------------------------

// The three IUnknown slots are spelled out in every vtable rather than embedded
// from win.IUnknown_VTable, so each `this` has its own concrete type and no
// call site needs a cast to be correct.

IMMDeviceEnumerator :: struct {
	using vtable: ^IMMDeviceEnumerator_VTable,
}

IMMDeviceEnumerator_VTable :: struct {
	QueryInterface:           proc "system" (
		this: ^IMMDeviceEnumerator,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:                   proc "system" (this: ^IMMDeviceEnumerator) -> win.ULONG,
	Release:                  proc "system" (this: ^IMMDeviceEnumerator) -> win.ULONG,
	EnumAudioEndpoints:       proc "system" (
		this: ^IMMDeviceEnumerator,
		data_flow: i32,
		state_mask: u32,
		devices: ^rawptr,
	) -> win.HRESULT,
	GetDefaultAudioEndpoint:  proc "system" (
		this: ^IMMDeviceEnumerator,
		data_flow: i32,
		role: i32,
		endpoint: ^^IMMDevice,
	) -> win.HRESULT,
}

IMMDevice :: struct {
	using vtable: ^IMMDevice_VTable,
}

IMMDevice_VTable :: struct {
	QueryInterface:    proc "system" (
		this: ^IMMDevice,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:            proc "system" (this: ^IMMDevice) -> win.ULONG,
	Release:           proc "system" (this: ^IMMDevice) -> win.ULONG,
	Activate:          proc "system" (
		this: ^IMMDevice,
		iid: win.REFIID,
		cls_ctx: u32,
		activation_params: rawptr,
		iface: ^rawptr,
	) -> win.HRESULT,
	OpenPropertyStore: proc "system" (
		this: ^IMMDevice,
		access: u32,
		properties: ^^IPropertyStore,
	) -> win.HRESULT,
}

IPropertyStore :: struct {
	using vtable: ^IPropertyStore_VTable,
}

IPropertyStore_VTable :: struct {
	QueryInterface: proc "system" (
		this: ^IPropertyStore,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IPropertyStore) -> win.ULONG,
	Release:        proc "system" (this: ^IPropertyStore) -> win.ULONG,
	GetCount:       proc "system" (this: ^IPropertyStore, count: ^u32) -> win.HRESULT,
	GetAt:          proc "system" (
		this: ^IPropertyStore,
		index: u32,
		key: ^Property_Key,
	) -> win.HRESULT,
	GetValue:       proc "system" (
		this: ^IPropertyStore,
		key: ^Property_Key,
		value: ^Prop_Variant,
	) -> win.HRESULT,
}

// PROPVARIANT as this file uses it. core:sys/windows declares a 16-byte
// placeholder, which is the wrong size for the real 24-byte union on x64, so
// the shape that matters here is spelled out instead of borrowed.
Prop_Variant :: struct {
	vt:        u16,
	reserved1: u16,
	reserved2: u16,
	reserved3: u16,
	value:     win.wstring,
	_padding:  uintptr,
}

#assert(size_of(Prop_Variant) == 24)

IAudioClient :: struct {
	using vtable: ^IAudioClient_VTable,
}

IAudioClient_VTable :: struct {
	QueryInterface:     proc "system" (
		this: ^IAudioClient,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:             proc "system" (this: ^IAudioClient) -> win.ULONG,
	Release:            proc "system" (this: ^IAudioClient) -> win.ULONG,
	Initialize:         proc "system" (
		this: ^IAudioClient,
		share_mode: i32,
		stream_flags: u32,
		buffer_duration: i64,
		periodicity: i64,
		format: ^win.WAVEFORMATEX,
		session_guid: ^win.GUID,
	) -> win.HRESULT,
	GetBufferSize:      proc "system" (this: ^IAudioClient, frames: ^u32) -> win.HRESULT,
	GetStreamLatency:   proc "system" (this: ^IAudioClient, latency: ^i64) -> win.HRESULT,
	GetCurrentPadding:  proc "system" (this: ^IAudioClient, frames: ^u32) -> win.HRESULT,
	IsFormatSupported:  proc "system" (
		this: ^IAudioClient,
		share_mode: i32,
		format: ^win.WAVEFORMATEX,
		closest: ^^win.WAVEFORMATEX,
	) -> win.HRESULT,
	GetMixFormat:       proc "system" (
		this: ^IAudioClient,
		format: ^^win.WAVEFORMATEX,
	) -> win.HRESULT,
	GetDevicePeriod:    proc "system" (
		this: ^IAudioClient,
		default_period: ^i64,
		minimum_period: ^i64,
	) -> win.HRESULT,
	Start:              proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Stop:               proc "system" (this: ^IAudioClient) -> win.HRESULT,
	Reset:              proc "system" (this: ^IAudioClient) -> win.HRESULT,
	SetEventHandle:     proc "system" (this: ^IAudioClient, event: win.HANDLE) -> win.HRESULT,
	GetService:         proc "system" (
		this: ^IAudioClient,
		riid: win.REFIID,
		service: ^rawptr,
	) -> win.HRESULT,
}

IAudioRenderClient :: struct {
	using vtable: ^IAudioRenderClient_VTable,
}

IAudioRenderClient_VTable :: struct {
	QueryInterface: proc "system" (
		this: ^IAudioRenderClient,
		riid: win.REFIID,
		ppv: ^rawptr,
	) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IAudioRenderClient) -> win.ULONG,
	Release:        proc "system" (this: ^IAudioRenderClient) -> win.ULONG,
	GetBuffer:      proc "system" (
		this: ^IAudioRenderClient,
		frames: u32,
		data: ^[^]f32,
	) -> win.HRESULT,
	ReleaseBuffer:  proc "system" (
		this: ^IAudioRenderClient,
		frames: u32,
		flags: u32,
	) -> win.HRESULT,
}

// WAVEFORMATEXTENSIBLE, which is what a shared-mode mix format almost always
// is. Only the subtype is read, to confirm the samples really are floats.
Wave_Format_Extensible :: struct #packed {
	format:         win.WAVEFORMATEX,
	samples:        u16,
	channel_mask:   u32,
	sub_format:     win.GUID,
}

// -- implementation state ----------------------------------------------------

Wasapi :: struct {
	enumerator:    ^IMMDeviceEnumerator,
	device:        ^IMMDevice,
	client:        ^IAudioClient,
	renderer:      ^IAudioRenderClient,

	event:         win.HANDLE,
	thread:        win.HANDLE,

	buffer_frames: u32,
	channels:      int,

	render:        Audio_Render_Proc,
	user:          rawptr,

	// Read by the render thread every period, cleared by `stop`.
	running:       b32,

	co_initialised: bool,
	name_owned:     string,
}

wasapi_backend :: proc() -> (Audio_Backend, bool) {
	w := new(Wasapi)
	b := Audio_Backend {
		impl    = w,
		open    = wasapi_open,
		start   = wasapi_start,
		stop    = wasapi_stop,
		destroy = wasapi_destroy,
	}
	return b, true
}

// -- open --------------------------------------------------------------------

wasapi_open :: proc(b: ^Audio_Backend) -> bool {
	w := (^Wasapi)(b.impl)

	// Multi-threaded apartment: the render thread created below calls methods
	// on these interfaces directly, which an apartment-threaded object would
	// require marshalling for. Audio interfaces are free-threaded, so MTA is
	// both correct and the documented choice for WASAPI.
	//
	// RPC_E_CHANGED_MODE means something else in the process already picked an
	// apartment. That is not fatal here, so only a hard failure is refused.
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	if hr >= 0 {
		w.co_initialised = true
	}

	hr = win.CoCreateInstance(
		&CLSID_MMDeviceEnumerator,
		nil,
		win.CLSCTX_ALL,
		&IID_IMMDeviceEnumerator,
		(^win.LPVOID)(&w.enumerator),
	)
	if hr < 0 || w.enumerator == nil {
		return false
	}

	// The default console render endpoint is what "the speakers" means to a
	// user, and it follows them when they change the system default.
	hr = w.enumerator->GetDefaultAudioEndpoint(E_DATA_FLOW_RENDER, E_ROLE_CONSOLE, &w.device)
	if hr < 0 || w.device == nil {
		return false
	}

	b.name = wasapi_device_name(w)

	hr = w.device->Activate(&IID_IAudioClient, win.CLSCTX_ALL, nil, (^rawptr)(&w.client))
	if hr < 0 || w.client == nil {
		return false
	}

	// The endpoint states its mix format; a shared-mode client does not get to
	// negotiate. Everything downstream adapts to what this reports.
	mix: ^win.WAVEFORMATEX
	hr = w.client->GetMixFormat(&mix)
	if hr < 0 || mix == nil {
		return false
	}
	defer win.CoTaskMemFree(mix)

	if !wasapi_format_is_float32(mix) {
		// Refusing is better than writing floats into an integer buffer, which
		// is not a quiet failure: it is full-scale noise into someone's ears.
		return false
	}

	// hnsBufferDuration of 0 asks WASAPI for the endpoint's own default period,
	// which is the lowest latency shared mode offers without special pleading.
	hr = w.client->Initialize(
		AUDCLNT_SHAREMODE_SHARED,
		AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
		0,
		0,
		mix,
		nil,
	)
	if hr < 0 {
		return false
	}

	// Auto-reset: the device sets it once per period and the render thread
	// consumes that signal.
	w.event = win.CreateEventW(nil, false, false, nil)
	if w.event == nil {
		return false
	}
	hr = w.client->SetEventHandle(w.event)
	if hr < 0 {
		return false
	}

	hr = w.client->GetBufferSize(&w.buffer_frames)
	if hr < 0 {
		return false
	}

	hr = w.client->GetService(&IID_IAudioRenderClient, (^rawptr)(&w.renderer))
	if hr < 0 || w.renderer == nil {
		return false
	}

	w.channels = int(mix.nChannels)

	b.format.sample_rate = f32(mix.nSamplesPerSec)
	b.format.channels = w.channels
	// The render thread is never asked for more than one buffer's worth, so
	// this is the true upper bound the shell sizes its scratch from.
	b.max_frames = int(w.buffer_frames)
	return true
}

// A mix format is usable only if its samples are 32-bit floats, either declared
// directly or through the EXTENSIBLE subtype.
wasapi_format_is_float32 :: proc(format: ^win.WAVEFORMATEX) -> bool {
	if format.wBitsPerSample != 32 {
		return false
	}
	switch format.wFormatTag {
	case WAVE_FORMAT_IEEE_FLOAT:
		return true
	case WAVE_FORMAT_EXTENSIBLE:
		if format.cbSize < 22 {
			return false
		}
		extensible := (^Wave_Format_Extensible)(format)
		return extensible.sub_format == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
	}
	return false
}

// Best-effort friendly name. A device with no readable name still plays, so a
// failure here degrades to a placeholder rather than refusing to start.
wasapi_device_name :: proc(w: ^Wasapi) -> string {
	properties: ^IPropertyStore
	if w.device->OpenPropertyStore(STGM_READ, &properties) < 0 || properties == nil {
		return "(unnamed output device)"
	}
	defer properties->Release()

	value: Prop_Variant
	if properties->GetValue(&PKEY_Device_FriendlyName, &value) < 0 {
		return "(unnamed output device)"
	}
	if value.vt != VT_LPWSTR || value.value == nil {
		return "(unnamed output device)"
	}
	// The string belongs to COM. Copy it into our allocator, then hand the
	// original back -- which is all PropVariantClear would do for a VT_LPWSTR.
	name, err := win.wstring_to_utf8(value.value, -1, context.allocator)
	win.CoTaskMemFree(rawptr(value.value))
	if err != nil {
		return "(unnamed output device)"
	}
	w.name_owned = name
	return name
}

// -- streaming ---------------------------------------------------------------

wasapi_start :: proc(b: ^Audio_Backend, render: Audio_Render_Proc, user: rawptr) -> bool {
	w := (^Wasapi)(b.impl)
	if w.client == nil || w.renderer == nil {
		return false
	}

	w.render = render
	w.user = user
	intrinsics.atomic_store_explicit(&w.running, true, .Release)

	// A raw OS thread rather than core:thread: this one must not carry an Odin
	// context or a temp allocator it might be tempted to use, and the shell
	// owns its lifetime explicitly.
	w.thread = win.CreateThread(nil, 0, wasapi_thread, w, 0, nil)
	if w.thread == nil {
		intrinsics.atomic_store_explicit(&w.running, false, .Release)
		return false
	}

	if w.client->Start() < 0 {
		wasapi_stop(b)
		return false
	}
	return true
}

wasapi_thread :: proc "system" (parameter: rawptr) -> win.DWORD {
	w := (^Wasapi)(parameter)

	// Audio glitches are far more audible than a scheduling delay anywhere else
	// in this process, so this thread outranks the rest of it. MMCSS
	// ("Pro Audio") would be better still; it is deliberately left out because
	// it needs avrt.dll and this is meant to stay small and readable.
	win.SetThreadPriority(win.GetCurrentThread(), win.THREAD_PRIORITY_TIME_CRITICAL)

	for intrinsics.atomic_load_explicit(&w.running, .Acquire) {
		// The device signals once per period. The timeout is a safety net: if
		// the endpoint disappears the thread exits rather than hanging.
		if win.WaitForSingleObject(w.event, 2000) != win.WAIT_OBJECT_0 {
			break
		}
		if !intrinsics.atomic_load_explicit(&w.running, .Acquire) {
			break
		}

		padding: u32
		if w.client->GetCurrentPadding(&padding) < 0 {
			break
		}
		// What the device has room for right now, which is the buffer minus
		// whatever it has not played yet.
		available := w.buffer_frames - padding
		if available == 0 {
			continue
		}

		data: [^]f32
		if w.renderer->GetBuffer(available, &data) < 0 {
			break
		}
		w.render(w.user, data, int(available), w.channels)
		w.renderer->ReleaseBuffer(available, 0)
	}
	return 0
}

wasapi_stop :: proc(b: ^Audio_Backend) {
	w := (^Wasapi)(b.impl)

	intrinsics.atomic_store_explicit(&w.running, false, .Release)

	// Join before releasing anything: the caller is about to free the engine
	// and the scratch buffers the render callback is holding pointers into, so
	// "stopped" has to mean the thread is provably gone, not merely asked.
	if w.thread != nil {
		// Nudge the event so a thread parked in WaitForSingleObject wakes and
		// sees the cleared flag instead of waiting out the timeout.
		if w.event != nil {
			win.SetEvent(w.event)
		}
		win.WaitForSingleObject(w.thread, win.INFINITE)
		win.CloseHandle(w.thread)
		w.thread = nil
	}

	if w.client != nil {
		w.client->Stop()
	}
}

wasapi_destroy :: proc(b: ^Audio_Backend) {
	w := (^Wasapi)(b.impl)
	if w == nil {
		return
	}

	wasapi_stop(b)

	if w.renderer != nil {
		w.renderer->Release()
		w.renderer = nil
	}
	if w.client != nil {
		w.client->Release()
		w.client = nil
	}
	if w.device != nil {
		w.device->Release()
		w.device = nil
	}
	if w.enumerator != nil {
		w.enumerator->Release()
		w.enumerator = nil
	}
	if w.event != nil {
		win.CloseHandle(w.event)
		w.event = nil
	}
	if w.name_owned != "" {
		delete(w.name_owned)
		w.name_owned = ""
	}
	if w.co_initialised {
		win.CoUninitialize()
		w.co_initialised = false
	}

	free(w)
	b.impl = nil
}
