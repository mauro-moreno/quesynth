// Minimal VST 2.4 host ABI declarations.
//
// These are plain C struct/enum layouts, declared from scratch so the project
// carries no Steinberg SDK dependency. Used only by the offline probe tool to
// interrogate the reference Synth1 binary; the synth itself never links this.
package s1probe

// ---------------------------------------------------------------- AEffect

AEffect :: struct {
	magic:                    i32, // 'VstP'
	_pad0:                    i32,
	dispatcher:               Dispatcher,
	process_deprecated:       proc "c" (e: ^AEffect, inp, outp: [^][^]f32, n: i32),
	set_parameter:            proc "c" (e: ^AEffect, index: i32, value: f32),
	get_parameter:            proc "c" (e: ^AEffect, index: i32) -> f32,
	num_programs:             i32,
	num_params:               i32,
	num_inputs:               i32,
	num_outputs:              i32,
	flags:                    i32,
	_pad1:                    i32,
	resvd1:                   int,
	resvd2:                   int,
	initial_delay:            i32,
	real_qualities:           i32,
	off_qualities:            i32,
	io_ratio:                 f32,
	object:                   rawptr,
	user:                     rawptr,
	unique_id:                i32,
	version:                  i32,
	process_replacing:        proc "c" (e: ^AEffect, inp, outp: [^][^]f32, n: i32),
	process_double_replacing: proc "c" (e: ^AEffect, inp, outp: [^][^]f64, n: i32),
	future:                   [56]u8,
}

#assert(size_of(AEffect) == 192)

Dispatcher :: proc "c" (e: ^AEffect, opcode: i32, index: i32, value: int, ptr: rawptr, opt: f32) -> int
HostCallback :: proc "c" (e: ^AEffect, opcode: i32, index: i32, value: int, ptr: rawptr, opt: f32) -> int
VstEntry :: proc "c" (host: HostCallback) -> ^AEffect

MAGIC :: i32(0x56737450) // 'VstP'

FLAG_HAS_EDITOR :: i32(1 << 0)
FLAG_CAN_REPLACING :: i32(1 << 4)
FLAG_PROGRAM_CHUNKS :: i32(1 << 5)
FLAG_IS_SYNTH :: i32(1 << 8)

// ---------------------------------------------------------------- opcodes

Op :: enum i32 {
	Open              = 0,
	Close             = 1,
	SetProgram        = 2,
	GetProgram        = 3,
	SetProgramName    = 4,
	GetProgramName    = 5,
	GetParamLabel     = 6,
	GetParamDisplay   = 7,
	GetParamName      = 8,
	SetSampleRate     = 10,
	SetBlockSize      = 11,
	MainsChanged      = 12,
	EditGetRect       = 13,
	EditOpen          = 14,
	EditClose         = 15,
	GetChunk          = 23,
	SetChunk          = 24,
	ProcessEvents     = 25,
	CanBeAutomated    = 26,
	String2Parameter  = 27,
	GetProgramNameIdx = 29,
	GetEffectName     = 45,
	GetVendorString   = 47,
	GetProductString  = 48,
	GetVendorVersion  = 49,
	CanDo             = 51,
	GetVstVersion     = 58,
	StartProcess      = 71,
	StopProcess       = 72,
}

HostOp :: enum i32 {
	Automate                = 0,
	Version                 = 1,
	CurrentId               = 2,
	Idle                    = 3,
	PinConnected            = 4,
	WantMidi                = 6,
	GetTime                 = 7,
	ProcessEvents           = 8,
	TempoAt                 = 10,
	SizeWindow              = 15,
	GetSampleRate           = 16,
	GetBlockSize            = 17,
	GetInputLatency         = 18,
	GetOutputLatency        = 19,
	GetCurrentProcessLevel  = 23,
	GetAutomationState      = 24,
	GetVendorString         = 32,
	GetProductString        = 33,
	GetVendorVersion        = 34,
	CanDo                   = 37,
	GetLanguage             = 38,
	UpdateDisplay           = 42,
	BeginEdit               = 43,
	EndEdit                 = 44,
}

// ---------------------------------------------------------------- events

VstMidiEvent :: struct {
	type:              i32, // 1 = midi
	byte_size:         i32,
	delta_frames:      i32,
	flags:             i32,
	note_length:       i32,
	note_offset:       i32,
	midi_data:         [4]u8,
	detune:            i8,
	note_off_velocity: u8,
	reserved1:         u8,
	reserved2:         u8,
}

VstEvents :: struct {
	num_events: i32,
	_pad:       i32,
	reserved:   int,
	events:     [16]^VstMidiEvent,
}

VstTimeInfo :: struct {
	sample_pos:            f64,
	sample_rate:           f64,
	nano_seconds:          f64,
	ppq_pos:               f64,
	tempo:                 f64,
	bar_start_pos:         f64,
	cycle_start_pos:       f64,
	cycle_end_pos:         f64,
	time_sig_numerator:    i32,
	time_sig_denominator:  i32,
	smpte_offset:          i32,
	smpte_frame_rate:      i32,
	samples_to_next_clock: i32,
	flags:                 i32,
}
