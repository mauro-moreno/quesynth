package s1probe

// s1probe behavior - performance behaviour driven by an event script.
//
//   s1probe behavior keys      [--mode 0|1|2] [--scenario <name>] [--porta n]
//                              [--auto 0|1] [--attack n] [--modenv]
//                              [--notes a,b] [--wav <dir>]
//   s1probe behavior ctrl      [--source cc|pressure|bend] [--sens n]
//   s1probe behavior delaytone [--values <list>]
//   s1probe behavior chorus1
//   s1probe behavior osc2track
//   s1probe behavior arp       [--mode 0|1|2] [--gate n] [--porta n] [--auto 0|1]
//
// Every other probe in this tool plays one note and lets it go. The behaviour
// this one measures only exists *between* notes -- which key a mono voice falls
// back to, whether an overlapping key glides, whether an envelope restarts --
// or between a note and a controller. So it renders a timed script of MIDI
// events through the reference and, beside it, through this engine, and reads
// pitch and level back out of both renders at fixed offsets from each event.
//
// Event times are rounded to block boundaries. The reference is then handed
// every event at delta 0 at the top of the block it belongs to, and this
// engine applies it at the same sample, so neither side depends on how the
// other honours an intra-block offset.
//
// Pitch is read from interpolated positive-going zero crossings over a short
// window, which is exact for the sine and triangle sources these scenarios
// use and keeps a 20 ms resolution a long FFT cannot. Level is RMS in dB.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import sengine "../../src/engine"
import cpatch "../../src/patch"

Script_Event :: struct {
	frame:  int,
	status: u8,
	d1:     u8,
	d2:     u8,
	label:  string,
}

script_frame :: proc(seconds: f64) -> int {
	return int(math.round(seconds * f64(SAMPLE_RATE) / f64(BLOCK))) * BLOCK
}

script_on :: proc(seconds: f64, note: int, velocity := 100) -> Script_Event {
	return {
		frame = script_frame(seconds), status = 0x90, d1 = u8(note), d2 = u8(velocity),
		label = fmt.aprintf("on %v", note),
	}
}

script_off :: proc(seconds: f64, note: int) -> Script_Event {
	return {
		frame = script_frame(seconds), status = 0x80, d1 = u8(note), d2 = 0,
		label = fmt.aprintf("off %v", note),
	}
}

script_cc :: proc(seconds: f64, cc, value: int) -> Script_Event {
	return {
		frame = script_frame(seconds), status = 0xB0, d1 = u8(cc), d2 = u8(value),
		label = fmt.aprintf("cc%v %v", cc, value),
	}
}

// Channel pressure is a two-byte message: the value is the first data byte.
script_pressure :: proc(seconds: f64, value: int) -> Script_Event {
	return {
		frame = script_frame(seconds), status = 0xD0, d1 = u8(value), d2 = 0,
		label = fmt.aprintf("pressure %v", value),
	}
}

// Fourteen bits, least significant seven first, 8192 at rest.
script_bend :: proc(seconds: f64, raw: int) -> Script_Event {
	v := clamp(raw, 0, 16383)
	return {
		frame = script_frame(seconds), status = 0xE0, d1 = u8(v & 0x7F), d2 = u8((v >> 7) & 0x7F),
		label = fmt.aprintf("bend %v", v),
	}
}

// The reference through the script. Interleaved stereo, `frames` long rounded
// up to a whole block. Events must be in time order.
render_reference_script :: proc(
	dll: string,
	parsed: ^cpatch.Patch,
	pristine, work: []byte,
	events: []Script_Event,
	frames: int,
) -> []f32 {
	p, loaded := open_reference(dll)
	if !loaded {
		return nil
	}
	defer close_reference(&p)
	load_reference_patch(&p, parsed, pristine, work)

	e := p.eff
	channels := max(int(e.num_outputs), 2)
	chans := make([][]f32, channels)
	ptrs := make([][^]f32, channels)
	defer {
		for c in chans {delete(c)}
		delete(chans)
		delete(ptrs)
	}
	for i in 0 ..< channels {
		chans[i] = make([]f32, BLOCK)
		ptrs[i] = raw_data(chans[i])
	}
	inputs := max(int(e.num_inputs), 1)
	in_chans := make([][]f32, inputs)
	in_ptrs := make([][^]f32, inputs)
	defer {
		for c in in_chans {delete(c)}
		delete(in_chans)
		delete(in_ptrs)
	}
	for i in 0 ..< inputs {
		in_chans[i] = make([]f32, BLOCK)
		in_ptrs[i] = raw_data(in_chans[i])
	}

	total := (frames + BLOCK - 1) / BLOCK * BLOCK
	out := make([]f32, total * 2)
	host_transport_reset()

	next := 0
	for pos := 0; pos < total; pos += BLOCK {
		// One list per block: the reference keeps the latest list rather than
		// accumulating them, so two dispatches before one process would drop
		// the first. See send_midi_notes.
		count := 0
		for next < len(events) && events[next].frame < pos + BLOCK {
			ev := events[next]
			if count < len(g_midi_chord) {
				g_midi_chord[count] = VstMidiEvent {
					type         = 1,
					byte_size    = size_of(VstMidiEvent),
					delta_frames = i32(max(ev.frame - pos, 0)),
					midi_data    = {ev.status, ev.d1, ev.d2, 0},
				}
				g_midi_events.events[count] = &g_midi_chord[count]
				count += 1
			}
			next += 1
		}
		if count > 0 {
			g_midi_events.num_events = i32(count)
			e.dispatcher(e, i32(Op.ProcessEvents), 0, 0, &g_midi_events, 0)
			// The reference dies inside processReplacing with two voices
			// sounding in poly mode on these probe patches (exit 139 after the
			// second note-on), as it does for most arpeggiator patches; see
			// compare.odin. S1PROBE_TRACE shows which block it reached.
			if os.get_env("S1PROBE_TRACE", context.temp_allocator) != "" {
				fmt.eprintfln("[behavior] block %v: %v events", pos, count)
			}
		}
		for i in 0 ..< channels {
			for j in 0 ..< BLOCK {chans[i][j] = 0}
		}
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), i32(BLOCK))
		host_transport_advance(BLOCK)
		for j in 0 ..< BLOCK {
			out[(pos + j) * 2] = chans[0][j]
			out[(pos + j) * 2 + 1] = chans[1][j]
		}
	}
	return out
}

// What a host does with each message, spelled the way the hosts spell it:
// hosts/clap, hosts/au and hosts/standalone all turn a 14-bit bend into
// (raw - 8192) / 8192 before it reaches the engine.
ours_apply_event :: proc(eng: ^sengine.Engine, ev: Script_Event) {
	switch ev.status & 0xF0 {
	case 0x90:
		if ev.d2 > 0 {
			sengine.engine_note_on(eng, int(ev.d1), f32(ev.d2) / 127.0)
		} else {
			sengine.engine_note_off(eng, int(ev.d1))
		}
	case 0x80:
		sengine.engine_note_off(eng, int(ev.d1))
	case 0xB0:
		sengine.engine_control_change(eng, int(ev.d1), int(ev.d2))
	case 0xD0:
		ours_channel_pressure(eng, int(ev.d1))
	case 0xE0:
		raw := int(ev.d1) | (int(ev.d2) << 7)
		sengine.engine_set_pitch_bend(eng, f32((f64(raw) - 8192.0) / 8192.0))
	}
}

// Channel pressure, as the hosts deliver it. Before clause 4 of
// docs/synth1-behavior-errors.md there was no engine entry point for it and
// every host dropped 0xD0, which is what the "before" measurements recorded.
ours_channel_pressure :: proc(eng: ^sengine.Engine, value: int) {
	sengine.engine_channel_pressure(eng, value)
}

render_ours_script :: proc(parsed: cpatch.Patch, events: []Script_Event, frames: int) -> []f32 {
	eng: sengine.Engine
	sengine.engine_load_patch(&eng, parsed, f32(SAMPLE_RATE))
	defer sengine.engine_destroy(&eng)

	total := (frames + BLOCK - 1) / BLOCK * BLOCK
	left := make([]f32, total)
	defer delete(left)
	right := make([]f32, total)
	defer delete(right)

	next := 0
	pos := 0
	for pos < total {
		for next < len(events) && events[next].frame <= pos {
			ours_apply_event(&eng, events[next])
			next += 1
		}
		end := min(pos + BLOCK, total)
		if next < len(events) && events[next].frame < end {
			end = events[next].frame
		}
		sengine.engine_process(&eng, left[pos:end], right[pos:end])
		pos = end
	}

	out := make([]f32, total * 2)
	for i in 0 ..< total {
		out[i * 2] = left[i]
		out[i * 2 + 1] = right[i]
	}
	return out
}

// ------------------------------------------------------------------ analysis

// One channel (0 left, 1 right) or the mid (-1) of an interleaved render.
script_channel :: proc(audio: []f32, channel: int) -> []f32 {
	frames := len(audio) / 2
	out := make([]f32, frames)
	for i in 0 ..< frames {
		switch channel {
		case 0: out[i] = audio[i * 2]
		case 1: out[i] = audio[i * 2 + 1]
		case: out[i] = 0.5 * (audio[i * 2] + audio[i * 2 + 1])
		}
	}
	return out
}

// Frequency from interpolated positive-going zero crossings in x[from:to]: the
// whole cycles between the first and the last crossing over the time they span.
zc_frequency :: proc(x: []f32, from, to: int) -> f64 {
	lo := max(from, 1)
	hi := min(to, len(x))
	first := -1.0
	last := -1.0
	count := 0
	for i in lo ..< hi {
		a := f64(x[i - 1])
		b := f64(x[i])
		if a < 0 && b >= 0 {
			t := f64(i - 1) + (-a) / (b - a)
			if first < 0 {first = t}
			last = t
			count += 1
		}
	}
	if count < 2 || last <= first {
		return 0
	}
	return f64(count - 1) * f64(SAMPLE_RATE) / (last - first)
}

hz_to_midi :: proc(hz: f64) -> f64 {
	if hz <= 0 {return 0}
	return 69.0 + 12.0 * math.log2(hz / 440.0)
}

window_db :: proc(x: []f32, from, to: int) -> f64 {
	lo := max(from, 0)
	hi := min(to, len(x))
	if hi <= lo {return -200}
	sum := 0.0
	for i in lo ..< hi {
		sum += f64(x[i]) * f64(x[i])
	}
	rms := math.sqrt(sum / f64(hi - lo))
	return rms > 1.0e-10 ? 20.0 * math.log10(rms) : -200
}

midi_text :: proc(m: f64) -> string {
	return m <= 0 ? "   --  " : dec2(m, 7)
}

db_text :: proc(d: f64) -> string {
	return d <= -199 ? "  -inf " : dec1(d, 7)
}

ms_frames :: proc(ms: f64) -> int {
	return int(ms * f64(SAMPLE_RATE) / 1000.0)
}

// Pitch and level at fixed offsets from every event.
print_event_timeline :: proc(ref, ours: []f32, events: []Script_Event, offsets_ms: []f64) {
	PITCH_MS :: 20.0
	LEVEL_MS :: 10.0
	fmt.printfln("  %-12v %8v | %7v %7v | %7v %7v", "event", "offset", "ref midi", "ref dB", "our midi", "our dB")
	for ev in events {
		for off in offsets_ms {
			at := ev.frame + ms_frames(off)
			if at < 0 {continue}
			rm := hz_to_midi(zc_frequency(ref, at, at + ms_frames(PITCH_MS)))
			om := hz_to_midi(zc_frequency(ours, at, at + ms_frames(PITCH_MS)))
			rd := window_db(ref, at, at + ms_frames(LEVEL_MS))
			od := window_db(ours, at, at + ms_frames(LEVEL_MS))
			fmt.printfln("  %-12v %vms | %v %v | %v %v",
				ev.label, sdec0(off, 6), midi_text(rm), db_text(rd), midi_text(om), db_text(od))
		}
		fmt.println()
	}
}

// The lowest 2 ms level inside a span after an event, relative to the level
// just before it. A retriggered envelope with an audible attack dips here; a
// continuing one does not.
dip_db :: proc(x: []f32, at: int, span_ms: f64) -> f64 {
	before := window_db(x, at - ms_frames(12), at - ms_frames(2))
	lowest := 0.0
	step := ms_frames(2)
	first := true
	for t := at; t < at + ms_frames(span_ms); t += step {
		d := window_db(x, t, t + step)
		if first || d < lowest {
			lowest = d
			first = false
		}
	}
	return lowest - before
}

write_pair :: proc(dir, name: string, ref, ours: []f32) {
	if dir == "" {return}
	_ = os.make_directory(dir)
	wav_write_f32(fmt.tprintf("%v/%v-ref.wav", dir, name), ref, 2, SAMPLE_RATE)
	wav_write_f32(fmt.tprintf("%v/%v-ours.wav", dir, name), ours, 2, SAMPLE_RATE)
}

print_settings :: proc(p: ^cpatch.Patch, indices: []int) {
	for i in indices {
		fmt.printf("  %v %v=%v(%q)", i, cpatch.PARAMETERS[i].name, p.values[i],
			sengine.resolved_display(i, p.values[i]))
		fmt.println()
	}
}

// ------------------------------------------------------------------ keys

Behavior_Options :: struct {
	mode:       int,
	scenario:   string,
	porta:      int,
	auto:       int,
	attack:     int,
	// Amplitude decay and sustain. With full sustain an envelope restarted from
	// its current level is indistinguishable from one left alone; a lower
	// sustain makes a restart visible as a rise back to the peak.
	decay:      int,
	sustain:    int,
	modenv:     bool,
	filterenv:  bool,
	notes:      [2]int,
	wav:        string,
	source:     string,
	sens:       int,
	gate:       int,
	// Modulation envelope attack and decay for --modenv.
	mod_attack: int,
	mod_decay:  int,
	values:     [dynamic]int,
	dump:       bool,
}

behavior_keys_patch :: proc(o: ^Behavior_Options) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // oscillator 1 sine
	set_param(&p, 5, 0) // oscillator 1 only
	set_param(&p, 19, 127) // filter open
	set_param(&p, 29, 100)
	set_param(&p, 25, o.attack) // amp attack: long enough to see a restart
	set_param(&p, 26, o.decay)
	set_param(&p, 27, o.sustain)
	set_param(&p, 28, 0) // instant release
	set_param(&p, 38, o.mode)
	set_param(&p, 39, o.porta)
	set_param(&p, 74, o.auto)
	set_param(&p, 91, 1) // fixed oscillator phase: a render is a function of the patch
	if o.modenv {
		// Oscillator 2 alone, tracking the key, so its pitch minus the played note
		// is the modulation envelope.
		set_param(&p, 1, 3) // oscillator 2 triangle (display-keyed)
		set_param(&p, 5, 127)
		set_param(&p, 4, 1)
		set_param(&p, 2, 64)
		set_param(&p, 3, 64)
		set_param(&p, 10, 1) // modulation envelope on
		set_param(&p, 71, 0) // to oscillator 2 pitch
		set_param(&p, 11, 100) // amount
		set_param(&p, 12, o.mod_attack)
		set_param(&p, 13, o.mod_decay)
	}
	if o.filterenv {
		// The filter envelope made audible as level: a saw under a low cutoff
		// gets louder as the envelope opens the filter, with the amplifier held
		// flat so it cannot be what moves.
		set_param(&p, 0, 1) // oscillator 1 saw
		set_param(&p, 25, 0)
		set_param(&p, 26, 0)
		set_param(&p, 27, 127)
		set_param(&p, 19, 30) // cutoff low
		set_param(&p, 21, 127) // envelope amount, full positive
		set_param(&p, 15, o.attack)
		set_param(&p, 16, o.decay)
		set_param(&p, 17, o.sustain)
		set_param(&p, 18, 0)
	}
	return p
}

behavior_keys_script :: proc(o: ^Behavior_Options) -> (events: [dynamic]Script_Event, seconds: f64) {
	a := o.notes[0]
	b := o.notes[1]
	switch o.scenario {
	case "fallback":
		// Newest key released while the first is still held.
		append(&events, script_on(0.0, a), script_on(0.5, b), script_off(1.0, b), script_off(1.5, a))
		seconds = 2.0
	case "offother":
		// The key that is not sounding is released; the sounding one stays.
		append(&events, script_on(0.0, a), script_on(0.5, b), script_off(1.0, a), script_off(1.5, b))
		seconds = 2.0
	case "overlap":
		append(&events, script_on(0.0, a), script_on(0.5, b), script_off(0.8, a), script_off(1.3, b))
		seconds = 1.6
	case "separate":
		append(&events, script_on(0.0, a), script_off(0.45, a), script_on(0.5, b), script_off(1.3, b))
		seconds = 1.6
	case "repeat":
		// A second note-on for a key that is already down.
		append(&events, script_on(0.0, a), script_on(0.5, b), script_on(1.0, a), script_off(1.5, a), script_off(1.8, b))
		seconds = 2.2
	case:
		fmt.eprintfln("behavior keys: unknown scenario %q", o.scenario)
		os.exit(2)
	}
	return
}

cmd_behavior_keys :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	p := behavior_keys_patch(o)
	events, seconds := behavior_keys_script(o)
	defer delete(events)

	fmt.printfln("behavior keys: scenario %v", o.scenario)
	print_settings(&p, []int{25, 26, 27, 38, 39, 74, 10, 11, 12, 13, 71, 15, 16, 17, 19, 21})
	fmt.println()

	ref_audio := render_reference_script(dll, &p, pristine, work, events[:], script_frame(seconds))
	our_audio := render_ours_script(p, events[:], script_frame(seconds))
	defer delete(ref_audio)
	defer delete(our_audio)
	write_pair(o.wav, fmt.tprintf("keys-%v-mode%v-porta%v-auto%v%v%v", o.scenario, o.mode, o.porta, o.auto, o.modenv ? "-modenv" : "", o.filterenv ? "-filterenv" : ""), ref_audio, our_audio)

	ref := script_channel(ref_audio, -1)
	ours := script_channel(our_audio, -1)
	defer delete(ref)
	defer delete(ours)

	offsets := []f64{-30, 5, 15, 30, 50, 80, 120, 200, 300}
	print_event_timeline(ref, ours, events[1:], offsets)

	fmt.println("  level dip in the 120 ms after each event, against the 10 ms before it")
	for ev in events[1:] {
		fmt.printfln("  %-12v ref %v dB   ours %v dB",
			ev.label, sdec1(dip_db(ref, ev.frame, 120), 7), sdec1(dip_db(ours, ev.frame, 120), 7))
	}
}

// ------------------------------------------------------------------ ctrl

// A controller assignment aimed at oscillator 2's pitch, so where the
// controller has moved the parameter is a frequency.
behavior_ctrl_patch :: proc(o: ^Behavior_Options) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 1, 3) // oscillator 2 triangle
	set_param(&p, 5, 127) // oscillator 2 only
	set_param(&p, 4, 1)
	set_param(&p, 2, 64)
	set_param(&p, 3, 64)
	set_param(&p, 19, 127)
	set_param(&p, 29, 100)
	set_param(&p, 40, 0) // pitch bend range 0, so a bend moves nothing directly
	set_param(&p, 91, 1)
	source := 45057
	switch o.source {
	case "cc": source = 0xB001
	case "pressure": source = 0xD000
	case "bend": source = 0xE000
	}
	set_param(&p, 86, source)
	set_param(&p, 87, 2) // oscillator 2 pitch
	set_param(&p, 50, o.sens)
	set_param(&p, 88, 0xB001)
	set_param(&p, 89, 44)
	set_param(&p, 51, 64) // second assignment at 0%
	return p
}

cmd_behavior_ctrl :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	p := behavior_ctrl_patch(o)
	values := o.values[:]
	if len(values) == 0 {
		values = o.source == "bend" ? []int{8192, 0, 4096, 8192, 12288, 16383} : []int{0, 32, 64, 96, 127, 0}
	}
	SEG :: 0.3
	events: [dynamic]Script_Event
	defer delete(events)
	append(&events, script_on(0.0, 60))
	for v, i in values {
		t := SEG * f64(i + 1)
		switch o.source {
		case "cc": append(&events, script_cc(t, 1, v))
		case "pressure": append(&events, script_pressure(t, v))
		case "bend": append(&events, script_bend(t, v))
		}
	}
	end := SEG * f64(len(values) + 1)
	append(&events, script_off(end, 60))
	seconds := end + 0.1

	fmt.printfln("behavior ctrl: source %v -> parameter 2 (osc2 pitch), note 60", o.source)
	print_settings(&p, []int{86, 87, 50, 40, 2})
	fmt.println()

	ref_audio := render_reference_script(dll, &p, pristine, work, events[:], script_frame(seconds))
	our_audio := render_ours_script(p, events[:], script_frame(seconds))
	defer delete(ref_audio)
	defer delete(our_audio)
	write_pair(o.wav, fmt.tprintf("ctrl-%v-sens%v", o.source, o.sens), ref_audio, our_audio)
	ref := script_channel(ref_audio, -1)
	ours := script_channel(our_audio, -1)
	defer delete(ref)
	defer delete(ours)

	fmt.printfln("  %-16v | %8v %8v | %8v", "segment", "ref midi", "our midi", "ours-ref")
	for i in 0 ..< len(events) - 1 {
		from := events[i].frame + ms_frames(100)
		to := events[i + 1].frame - ms_frames(20)
		rm := hz_to_midi(zc_frequency(ref, from, to))
		om := hz_to_midi(zc_frequency(ours, from, to))
		fmt.printfln("  %-16v | %v %v | %v", events[i].label, dec3(rm, 8), dec3(om, 8), sdec3(om - rm, 8))
	}
}

// ------------------------------------------------------------------ delay tone

// Band levels of x[from:from+n] through a Hann window.
band_levels_db :: proc(x: []f32, from, n: int, edges: []f64) -> []f64 {
	re := make([]f64, n)
	defer delete(re)
	im := make([]f64, n)
	defer delete(im)
	for i in 0 ..< n {
		w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
		idx := from + i
		re[i] = idx >= 0 && idx < len(x) ? f64(x[idx]) * w : 0
	}
	fft_forward(re, im)
	bin_hz := f64(SAMPLE_RATE) / f64(n)
	out := make([]f64, len(edges) - 1)
	for b in 0 ..< len(edges) - 1 {
		sum := 0.0
		for k in 1 ..< n / 2 {
			hz := f64(k) * bin_hz
			if hz >= edges[b] && hz < edges[b + 1] {
				sum += re[k] * re[k] + im[k] * im[k]
			}
		}
		out[b] = sum > 0 ? 10.0 * math.log10(sum) : -200
	}
	return out
}

behavior_delay_patch :: proc(tone: int) -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 1) // oscillator 1 saw: energy across the whole band
	set_param(&p, 5, 0)
	set_param(&p, 19, 127)
	set_param(&p, 29, 100)
	set_param(&p, 25, 0)
	set_param(&p, 26, 40) // a short pluck, gone before the first echo
	set_param(&p, 27, 0)
	set_param(&p, 28, 0)
	set_param(&p, 91, 1)
	set_param(&p, 65, 1) // delay on
	// "(8)": 250 ms at 120 BPM. Parameter 35 is display-keyed, so the stored
	// integer is found by its display rather than assumed.
	eighth := 0
	for stored in 0 ..< 256 {
		if sengine.resolved_display(35, stored) == "(8)" {
			eighth = stored
			break
		}
	}
	set_param(&p, 35, eighth)
	set_param(&p, 36, 0) // no feedback: only the first echo exists
	set_param(&p, 37, 64)
	set_param(&p, 82, 0)
	set_param(&p, 98, tone)
	return p
}

cmd_behavior_delaytone :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	values := o.values[:]
	if len(values) == 0 {
		values = []int{0, 32, 64, 96, 127}
	}
	edges := []f64{100, 400, 1600, 3200, 6400, 12800}
	N :: 4096

	probe := behavior_delay_patch(64)
	fmt.println("behavior delaytone: note 48 saw pluck, feedback 0, first echo against the dry hit")
	print_settings(&probe, []int{35, 36, 37, 82, 83, 26})
	fmt.println("  per band: echo level minus dry level, dB; bands 100-400-1600-3200-6400-12800 Hz")
	fmt.println()

	events := []Script_Event{script_on(0.0, 48), script_off(0.1, 48)}
	results: [2][dynamic][]f64
	defer for r in results {
		for b in r {delete(b)}
		delete(r)
	}
	for tone in values {
		p := behavior_delay_patch(tone)
		ref_audio := render_reference_script(dll, &p, pristine, work, events, script_frame(0.8))
		our_audio := render_ours_script(p, events, script_frame(0.8))
		write_pair(o.wav, fmt.tprintf("delaytone-%v", tone), ref_audio, our_audio)
		for audio, side in ([2][]f32{ref_audio, our_audio}) {
			x := script_channel(audio, -1)
			// The echo starts where the dry hit started, one delay time later.
			onset := 0
			for i in 0 ..< len(x) {
				if abs(x[i]) > 1.0e-4 {
					onset = i
					break
				}
			}
			delay_frames := ms_frames(250)
			dry := band_levels_db(x, onset, N, edges)
			echo := band_levels_db(x, onset + delay_frames, N, edges)
			diff := make([]f64, len(dry))
			for b in 0 ..< len(dry) {
				diff[b] = echo[b] - dry[b]
			}
			delete(dry)
			delete(echo)
			append(&results[side], diff)
			delete(x)
		}
		delete(ref_audio)
		delete(our_audio)
	}

	flat := -1
	for v, i in values {
		if v == 64 {flat = i}
	}
	for side in 0 ..< 2 {
		fmt.printfln("  %v", side == 0 ? "reference" : "this engine")
		fmt.printfln("    tone  %v | relative to tone 64", "  100-400  400-1.6k  1.6-3.2k 3.2-6.4k 6.4-12.8k")
		for v, i in values {
			row := results[side][i]
			line := strings.builder_make(context.temp_allocator)
			for b in row {fmt.sbprintf(&line, " %v", dec2(b, 8))}
			strings.write_string(&line, " |")
			for b, k in row {
				rel := flat >= 0 ? b - results[side][flat][k] : 0
				fmt.sbprintf(&line, " %v", sdec2(rel, 7))
			}
			fmt.printfln("    %v %v", pad_left(fmt.tprint(v), 4), strings.to_string(line))
		}
	}
}

// ------------------------------------------------------------------ chorus x1

cmd_behavior_chorus1 :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	// Parameter 64 is display-keyed; find the state that reads "1".
	type_x1 := -1
	for stored in 0 ..< 8 {
		if sengine.resolved_display(64, stored) == "1" {
			type_x1 = stored
			break
		}
	}
	fmt.printfln("behavior chorus1: chorus type stored %v (%q), level 127, saw note 60", type_x1,
		sengine.resolved_display(64, type_x1))
	fmt.println("  wet = render with chorus on minus the same render with it off;")
	fmt.println("  corr = normalised correlation of the wet left against the wet right")
	fmt.printfln("  %-14v | %9v %9v | %9v %9v %6v | %9v %9v %6v", "input", "dry L dB", "dry R dB",
		"ref wetL", "ref wetR", "corr", "our wetL", "our wetR", "corr")

	// Pan is a per-voice control here, but nothing above proves the reference
	// applies it before the effects rather than after them. Unison pan spread
	// cannot be applied after the effects -- it pans layers of one voice apart
	// -- so the last row is the one that separates "the chorus mixes its two
	// inputs" from "the input was already panned when it got there".
	Chorus_Input :: struct {
		label:  string,
		pan:    int,
		spread: bool,
	}
	inputs := []Chorus_Input {
		{"pan L 100%", 0, false},
		{"pan center", 64, false},
		{"pan R 100%", 127, false},
		{"unison spread", 64, true},
	}
	unison_two := -1
	for stored in 0 ..< 16 {
		if sengine.resolved_display(93, stored) == "2" {
			unison_two = stored
			break
		}
	}

	events := []Script_Event{script_on(0.0, 60), script_off(1.0, 60)}
	for input in inputs {
		cells: [2][2]f64
		corr: [2]f64
		dry_db: [2]f64
		for side in 0 ..< 2 {
			renders: [2][]f32
			for on in 0 ..< 2 {
				p := neutral_probe_patch()
				set_param(&p, 0, 1)
				set_param(&p, 5, 0)
				set_param(&p, 19, 127)
				set_param(&p, 29, 100)
				set_param(&p, 91, 1)
				set_param(&p, 90, input.pan)
				if input.spread {
					set_param(&p, 73, 1) // unison on
					set_param(&p, 93, unison_two)
					set_param(&p, 75, 127) // detuned, so the two layers differ
					set_param(&p, 84, 127) // layers panned fully apart
				}
				set_param(&p, 64, type_x1)
				set_param(&p, 56, 127)
				set_param(&p, 66, on)
				if side == 0 {
					renders[on] = render_reference_script(dll, &p, pristine, work, events, script_frame(1.0))
				} else {
					renders[on] = render_ours_script(p, events, script_frame(1.0))
				}
			}
			from := ms_frames(200)
			to := ms_frames(900)
			cross := 0.0
			energy: [2]f64
			for ch in 0 ..< 2 {
				sum := 0.0
				dry := 0.0
				for i in from ..< to {
					d := f64(renders[1][i * 2 + ch]) - f64(renders[0][i * 2 + ch])
					sum += d * d
					dry += f64(renders[0][i * 2 + ch]) * f64(renders[0][i * 2 + ch])
				}
				n := f64(to - from)
				energy[ch] = sum
				cells[side][ch] = sum > 0 ? 10.0 * math.log10(sum / n) : -200
				if side == 0 {
					dry_db[ch] = dry > 0 ? 10.0 * math.log10(dry / n) : -200
				}
			}
			for i in from ..< to {
				l := f64(renders[1][i * 2]) - f64(renders[0][i * 2])
				r := f64(renders[1][i * 2 + 1]) - f64(renders[0][i * 2 + 1])
				cross += l * r
			}
			corr[side] = energy[0] > 0 && energy[1] > 0 ? cross / math.sqrt(energy[0] * energy[1]) : 0
			write_pair(o.wav, fmt.tprintf("chorus1-%v-%v", input.label, side == 0 ? "ref" : "ours"), renders[0], renders[1])
			delete(renders[0])
			delete(renders[1])
		}
		fmt.printfln("  %-14v | %v %v | %v %v %v | %v %v %v",
			input.label,
			db_text(dry_db[0]), db_text(dry_db[1]),
			db_text(cells[0][0]), db_text(cells[0][1]), dec3(corr[0], 6),
			db_text(cells[1][0]), db_text(cells[1][1]), dec3(corr[1], 6))
	}
}

// ------------------------------------------------------------------ osc2 tracking off

// The strongest one or two spectral peaks between lo and hi.
two_peaks :: proc(power: []f64, bin_hz, lo, hi: f64) -> (a, b: f64, a_db, b_db: f64) {
	best := [2]int{-1, -1}
	for k in 2 ..< len(power) - 2 {
		hz := f64(k) * bin_hz
		if hz < lo || hz > hi {continue}
		if power[k] < power[k - 1] || power[k] < power[k + 1] {continue}
		if best[0] < 0 || power[k] > power[best[0]] {
			best[1] = best[0]
			best[0] = k
		} else if best[1] < 0 || power[k] > power[best[1]] {
			best[1] = k
		}
	}
	interp :: proc(power: []f64, k: int, bin_hz: f64) -> f64 {
		a := power_db(power[k - 1])
		b := power_db(power[k])
		c := power_db(power[k + 1])
		d := a - 2.0 * b + c
		off := abs(d) > 1.0e-12 ? clamp(0.5 * (a - c) / d, -1.0, 1.0) : 0
		return (f64(k) + off) * bin_hz
	}
	if best[0] >= 0 {
		a = interp(power, best[0], bin_hz)
		a_db = power_db(power[best[0]])
	}
	if best[1] >= 0 {
		b = interp(power, best[1], bin_hz)
		b_db = power_db(power[best[1]])
	}
	return
}

Osc2_Variant :: struct {
	label: string,
	note:  int,
	set:   [4][2]int, // up to four (index, stored) pairs; index -1 ends the list
}

cmd_behavior_osc2track :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	// Stored values found by display, so the labels say what the plugin shows.
	find :: proc(index: int, display: string) -> int {
		for stored in 0 ..< 256 {
			if sengine.resolved_display(index, stored) == display {return stored}
		}
		return -1
	}
	shift_up := find(9, "12")
	fine_up := find(72, "+50 cent")
	if fine_up < 0 {fine_up = 127}
	unison_voices := find(93, "2")

	variants := []Osc2_Variant {
		{"note 60", 60, {{-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}}},
		{"note 72", 72, {{-1, 0}, {-1, 0}, {-1, 0}, {-1, 0}}},
		{"key shift", 60, {{9, shift_up}, {-1, 0}, {-1, 0}, {-1, 0}}},
		{"fine tune", 60, {{72, fine_up}, {-1, 0}, {-1, 0}, {-1, 0}}},
		{"unison 2, detune 127", 60, {{73, 1}, {93, unison_voices}, {75, 127}, {-1, 0}}},
	}

	fmt.println("behavior osc2track: oscillator 2 alone (triangle); strongest two peaks 150-700 Hz")
	fmt.printfln("  key shift stored %v (%q), fine tune stored %v (%q), unison voices stored %v (%q)",
		shift_up, sengine.resolved_display(9, shift_up), fine_up, sengine.resolved_display(72, fine_up),
		unison_voices, sengine.resolved_display(93, unison_voices))
	fmt.printfln("  %-6v %-22v | %18v | %18v", "track", "variant", "reference Hz", "this engine Hz")

	for track in ([2]int{0, 1}) {
		for v in variants {
			p := neutral_probe_patch()
			set_param(&p, 1, 3)
			set_param(&p, 5, 127)
			set_param(&p, 4, track)
			set_param(&p, 2, 64)
			set_param(&p, 3, 64)
			set_param(&p, 19, 127)
			set_param(&p, 29, 100)
			set_param(&p, 91, 1)
			for pair in v.set {
				if pair[0] < 0 {break}
				set_param(&p, pair[0], pair[1])
			}
			events := []Script_Event{script_on(0.0, v.note), script_off(1.5, v.note)}
			ref_audio := render_reference_script(dll, &p, pristine, work, events, script_frame(1.5))
			our_audio := render_ours_script(p, events, script_frame(1.5))
			cells: [2][2]f64
			for audio, side in ([2][]f32{ref_audio, our_audio}) {
				x := script_channel(audio, -1)
				power := welch_power(x, ms_frames(100), len(x))
				bin_hz := f64(SAMPLE_RATE) / f64((len(power) - 1) * 2)
				a, b, _, _ := two_peaks(power, bin_hz, 150, 700)
				cells[side] = {a, b}
				delete(power)
				delete(x)
			}
			fmt.printfln("  %-6v %-22v | %v %v | %v %v",
				track == 0 ? "off" : "on", v.label,
				dec2(cells[0][0], 8), dec2(cells[0][1], 8), dec2(cells[1][0], 8), dec2(cells[1][1], 8))
			delete(ref_audio)
			delete(our_audio)
			free_all(context.temp_allocator)
		}
	}
}

// ------------------------------------------------------------------ arpeggiator

cmd_behavior_arp :: proc(dll: string, o: ^Behavior_Options) {
	pristine, work := probe_open_chunk(dll)
	defer delete(pristine)
	defer delete(work)

	// The probe patch rather than a factory one, so pitch and level read
	// cleanly: a sine through an open filter. Only mono and legato are
	// measurable -- with more than one voice sounding in poly mode the
	// reference dies inside processReplacing under this host, which is the
	// arpeggiator crash compare.odin describes.
	parsed := neutral_probe_patch()
	set_param(&parsed, 0, 0) // oscillator 1 sine
	set_param(&parsed, 5, 0)
	set_param(&parsed, 19, 127)
	set_param(&parsed, 29, 100)
	set_param(&parsed, 91, 1)
	set_param(&parsed, 59, 1)
	set_param(&parsed, 31, 2) // up
	set_param(&parsed, 32, 0) // one octave
	set_param(&parsed, 33, 11) // "(8)": a 250 ms step
	set_param(&parsed, 34, o.gate)
	set_param(&parsed, 38, o.mode)
	set_param(&parsed, 39, o.porta)
	set_param(&parsed, 74, o.auto)
	// A visible restart: attack, then a decay to a sustain well under the peak.
	set_param(&parsed, 25, o.attack)
	set_param(&parsed, 26, o.decay)
	set_param(&parsed, 27, o.sustain)
	set_param(&parsed, 28, 0)

	fmt.println("behavior arp: probe patch, sine, chord 60 64 67 held for 2 s")
	print_settings(&parsed, []int{31, 32, 33, 34, 38, 39, 74, 25, 26, 27, 28})
	fmt.println()

	events: [dynamic]Script_Event
	defer delete(events)
	// One list carries the chord: the reference keeps only the latest list.
	append(&events, script_on(0.0, 60), script_on(0.0, 64), script_on(0.0, 67), script_off(2.0, 60), script_off(2.0, 64), script_off(2.0, 67))
	seconds := 2.4
	ref_audio := render_reference_script(dll, &parsed, pristine, work, events[:], script_frame(seconds))
	our_audio := render_ours_script(parsed, events[:], script_frame(seconds))
	defer delete(ref_audio)
	defer delete(our_audio)
	write_pair(o.wav, fmt.tprintf("arp-mode%v-gate%v-porta%v", o.mode, o.gate, o.porta), ref_audio, our_audio)

	ref := script_channel(ref_audio, -1)
	ours := script_channel(our_audio, -1)
	defer delete(ref)
	defer delete(ours)

	// Every 25 ms over the first second and the release at 2 s.
	fmt.printfln("  %8v | %7v %7v | %7v %7v", "time", "ref midi", "ref dB", "our midi", "our dB")
	for ms := 0.0; ms < 1100; ms += 25 {
		at := ms_frames(ms)
		fmt.printfln("  %vms | %v %v | %v %v", dec0(ms, 6),
			midi_text(hz_to_midi(zc_frequency(ref, at, at + ms_frames(20)))),
			db_text(window_db(ref, at, at + ms_frames(10))),
			midi_text(hz_to_midi(zc_frequency(ours, at, at + ms_frames(20)))),
			db_text(window_db(ours, at, at + ms_frames(10))))
	}
	fmt.println("  ...")
	for ms := 1950.0; ms < 2300; ms += 25 {
		at := ms_frames(ms)
		fmt.printfln("  %vms | %v %v | %v %v", dec0(ms, 6),
			midi_text(hz_to_midi(zc_frequency(ref, at, at + ms_frames(20)))),
			db_text(window_db(ref, at, at + ms_frames(10))),
			midi_text(hz_to_midi(zc_frequency(ours, at, at + ms_frames(20)))),
			db_text(window_db(ours, at, at + ms_frames(10))))
	}

	// The level dip at each 250 ms step boundary after the first.
	fmt.println()
	fmt.println("  level dip within 60 ms of each step boundary, against the 10 ms before it")
	for step in 1 ..< 8 {
		at := ms_frames(250 * f64(step))
		fmt.printfln("  step %v at %v ms   ref %v dB   ours %v dB", step, dec0(250 * f64(step), 4),
			sdec1(dip_db(ref, at, 60), 7), sdec1(dip_db(ours, at, 60), 7))
	}
}

// ------------------------------------------------------------------ entry

cmd_behavior :: proc(dll: string, args: []string) {
	if len(args) < 1 {
		usage()
	}
	o := Behavior_Options {
		mode     = 1,
		scenario = "fallback",
		porta    = 0,
		auto     = 0,
		attack   = 60,
		sustain  = 127,
		notes    = {60, 67},
		source   = "pressure",
		sens     = 80,
		gate     = 127,
		mod_attack = 70,
		mod_decay  = 110,
	}
	defer delete(o.values)
	sub := args[0]
	if sub == "arp" {
		// A restart is visible as a rise from sustain back to the peak.
		o.attack = 50
		o.decay = 50
		o.sustain = 40
	}
	i := 1
	for i < len(args) {
		need :: proc(args: []string, i: int) -> string {
			if i + 1 >= len(args) {usage()}
			return args[i + 1]
		}
		switch args[i] {
		case "--mode":
			o.mode, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--scenario":
			o.scenario = need(args, i)
			i += 2
		case "--porta":
			o.porta, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--auto":
			o.auto, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--decay":
			o.decay, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--sustain":
			o.sustain, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--attack":
			o.attack, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--modattack":
			o.mod_attack, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--moddecay":
			o.mod_decay, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--gate":
			o.gate, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--sens":
			o.sens, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--source":
			o.source = need(args, i)
			i += 2
		case "--wav":
			o.wav = need(args, i)
			i += 2
		case "--modenv":
			o.modenv = true
			i += 1
		case "--filterenv":
			o.filterenv = true
			i += 1
		case "--notes":
			fields := strings.split(need(args, i), ",", context.temp_allocator)
			for f, k in fields {
				if k < 2 {o.notes[k], _ = strconv.parse_int(strings.trim_space(f))}
			}
			i += 2
		case "--values":
			for f in strings.split(need(args, i), ",", context.temp_allocator) {
				if v, ok := strconv.parse_int(strings.trim_space(f)); ok {append(&o.values, v)}
			}
			i += 2
		case:
			usage()
		}
	}
	switch sub {
	case "keys": cmd_behavior_keys(dll, &o)
	case "ctrl": cmd_behavior_ctrl(dll, &o)
	case "delaytone": cmd_behavior_delaytone(dll, &o)
	case "chorus1": cmd_behavior_chorus1(dll, &o)
	case "osc2track": cmd_behavior_osc2track(dll, &o)
	case "arp": cmd_behavior_arp(dll, &o)
	case: usage()
	}
}
