package s1probe

// What the reference's arpeggiator actually does.
//
//   s1probe arpprobe [dll] [--base <patch.sy1>] [--type n] [--range n]
//                    [--beat n|all] [--gate n] [--notes 60,64,67] [--seconds n]
//
// The arpeggiator retriggers the amplitude envelope on every step, so each step
// is an attack in the envelope and the steps can be found by looking for them.
// Once the onsets are known, three things fall out of the same render: the step
// period, from the spacing; the pattern, from the pitch measured in each step;
// and the gate, from how much of each step has sound in it.
//
// Held at a base patch rather than built from defaults. Five of the eight
// factory arpeggiator patches segfault the reference (see compare.odin), and a
// patch assembled from scratch is as likely to land on whatever triggers that
// as not. 110.sy1 "Sequence 3" renders under every combination of type and
// octave range and every beat division, which makes it a platform rather than
// a guess.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import sengine "../../src/engine"
import cpatch "../../src/patch"

ARP_DEFAULT_BASE :: "patches/incoming/soundbank00/110.sy1"

// The tempo the host reports, and therefore what a beat is worth in seconds.
// Kept next to the probe that divides by it so the two cannot drift apart.
ARP_BEAT_SECONDS :: 60.0 / f64(HOST_TEMPO)

// Envelope resolution. One millisecond is short against the fastest step the
// reference offers -- a 32nd triplet at 120 BPM is 41 ms -- and long enough
// that a single noisy sample cannot look like an attack.
ARP_FRAME_MS :: 2.0

Arp_Onset :: struct {
	frame:    int,
	seconds:  f64,
	// Fundamental measured just after the attack, and the MIDI note nearest to
	// it. The note is what the pattern is read from.
	hz:       f64,
	midi:     f64,
	// How long the envelope stayed above the gate threshold, as a fraction of
	// the step that follows.
	duty:     f64,
}

// Render the reference holding several notes at once, so a pattern has
// something to arpeggiate over.
//
// `render_reference_note` sends one note and is what every other probe wants.
// A chord is the whole point here: with one held note the pattern order and the
// octave range are both invisible, because every step plays the same pitch.
render_reference_chord :: proc(p: ^Plugin, notes: []u8, seconds: f64) -> []f32 {
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

	frames := int(seconds * f64(SAMPLE_RATE))
	frames = (frames / BLOCK) * BLOCK
	out := make([]f32, frames)

	host_transport_reset()
	send_midi_notes(p, 0x90, notes, COMPARE_VELOCITY_MIDI, 0)

	for pos := 0; pos < frames; pos += BLOCK {
		for i in 0 ..< channels {
			for j in 0 ..< BLOCK {chans[i][j] = 0}
		}
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), i32(BLOCK))
		host_transport_advance(BLOCK)
		// Mono is enough: the pattern is in the timing and the pitch, and
		// summing the channels keeps a pan-spread step from reading as a
		// quieter one.
		for j in 0 ..< BLOCK {
			out[pos + j] = 0.5 * (chans[0][j] + chans[min(1, channels - 1)][j])
		}
	}
	return out
}

// Find the attacks.
//
// A step is a rise, so what is looked for is a frame that is well above the
// frame before it and above a floor set from the loudest frame in the render.
// The refractory gap stops one attack being counted several times as the
// envelope wobbles on the way up; it is set from the shortest step the
// reference can produce rather than from taste.
arp_find_onsets :: proc(audio: []f32, env: []f64, frame_len: int) -> [dynamic]Arp_Onset {
	onsets: [dynamic]Arp_Onset

	peak := 0.0
	for v in env {peak = max(peak, v)}
	if peak <= 0 {
		return onsets
	}
	// A Schmitt trigger on the envelope, not a rise detector.
	//
	// Looking for "this frame is twice the last" seemed obvious and is useless:
	// a sustaining tone ripples at its own period, every ripple clears a
	// factor-of-two test, and the first version of this probe duly reported the
	// same 0.046-beat period for all nineteen divisions -- which was its own
	// refractory limit, measured back to itself.
	//
	// A gated arpeggiator step is a loud stretch with a quiet gap after it, so
	// what actually marks a step is the envelope crossing *up* through a high
	// threshold having first fallen below a low one. Two thresholds rather than
	// one so ripple around a single level cannot retrigger it.
	high := peak * 0.25
	low := peak * 0.08
	armed := true

	for i in 1 ..< len(env) {
		if env[i] < low {
			armed = true
			continue
		}
		if armed && env[i] >= high {
			append(&onsets, Arp_Onset{frame = i, seconds = f64(i) * ARP_FRAME_MS / 1000.0})
			armed = false
		}
	}

	// Pitch and duty for each onset, from the audio rather than the envelope.
	for &o, index in onsets {
		start := o.frame * frame_len
		stop := index + 1 < len(onsets) ? onsets[index + 1].frame * frame_len : len(audio)
		if stop > len(audio) {stop = len(audio)}
		// Skip the attack transient before measuring pitch: the first few
		// milliseconds are a click and read as broadband.
		measure_from := min(start + frame_len * 5, stop)
		if stop - measure_from > 2048 {
			power := welch_power(audio, measure_from, stop)
			defer delete(power)
			bin_hz := f64(SAMPLE_RATE) / f64((len(power) - 1) * 2)
			o.hz = dominant_frequency(power, bin_hz, 5000.0)
			if o.hz > 0 {
				o.midi = 69.0 + 12.0 * math.log2(o.hz / 440.0)
			}
		}
		// Duty: frames above a tenth of this step's own peak.
		step_peak := 0.0
		for f := o.frame; f < stop / frame_len && f < len(env); f += 1 {
			step_peak = max(step_peak, env[f])
		}
		sounding := 0
		total := 0
		for f := o.frame; f < stop / frame_len && f < len(env); f += 1 {
			total += 1
			if env[f] > step_peak * 0.1 {sounding += 1}
		}
		if total > 0 {
			o.duty = f64(sounding) / f64(total)
		}
	}
	return onsets
}

// One render, reported.
arp_measure :: proc(
	dll: string,
	base: ^cpatch.Patch,
	pristine, work: []byte,
	notes: []u8,
	seconds: f64,
) -> (
	[dynamic]Arp_Onset,
	bool,
) {
	p, loaded := open_reference(dll)
	if !loaded {
		return nil, false
	}
	defer close_reference(&p)

	load_reference_patch(&p, base, pristine, work)
	audio := render_reference_chord(&p, notes, seconds)
	defer delete(audio)

	frame_len := int(ARP_FRAME_MS * f64(SAMPLE_RATE) / 1000.0)
	env := frame_envelope(audio, frame_len)
	defer delete(env)

	return arp_find_onsets(audio, env, frame_len), true
}

// The median spacing between onsets, in beats. Median rather than mean because
// the first step often lands early and the last is cut off by the end of the
// render, and neither should move the answer.
arp_period_beats :: proc(onsets: []Arp_Onset) -> (beats: f64, steps: int) {
	if len(onsets) < 3 {
		return 0, 0
	}
	gaps := make([]f64, len(onsets) - 1, context.temp_allocator)
	for i in 1 ..< len(onsets) {
		gaps[i - 1] = onsets[i].seconds - onsets[i - 1].seconds
	}
	return median(gaps) / ARP_BEAT_SECONDS, len(onsets)
}

cmd_arpprobe :: proc(
	dll: string,
	base_path: string,
	type_index, range_index, beat_index, gate_index: int,
	notes: []u8,
	seconds: f64,
	sweep_beats: bool,
) {
	data, read_err := os.read_entire_file(base_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("arpprobe: cannot read %v: %v", base_path, read_err)
		os.exit(1)
	}
	defer delete(data, context.allocator)
	parsed, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("arpprobe: cannot parse %v: %v", base_path, parse_err)
		os.exit(1)
	}

	pristine, work, chunk_ok := arp_chunk_buffers(dll)
	if !chunk_ok {
		os.exit(1)
	}
	defer delete(pristine)
	defer delete(work)

	note_text := strings.builder_make(context.temp_allocator)
	for n, i in notes {
		if i > 0 {strings.write_byte(&note_text, ' ')}
		fmt.sbprintf(&note_text, "%v", n)
	}

	fmt.printfln("arpeggiator, base %v", base_path)
	fmt.printfln("notes held: %v   tempo %v BPM   %.1f s per render",
		strings.to_string(note_text), HOST_TEMPO, seconds)

	// Everything the probe sets, set explicitly: a base patch has its own
	// arpeggiator settings and leaving any of them alone would measure the
	// base's choice rather than the one being asked about.
	parsed.values[59] = 1
	parsed.present[59] = true
	parsed.values[31] = type_index
	parsed.values[32] = range_index
	parsed.values[34] = gate_index
	parsed.present[31] = true
	parsed.present[32] = true
	parsed.present[34] = true

	if sweep_beats {
		fmt.println()
		fmt.printfln("type %v, range %v, gate %v -- every beat division",
			type_index, range_index, gate_index)
		fmt.println("  p33  display          steps   period (beats)   duty")
		for beat in 0 ..< len(cpatch.parameter_states(33)) {
			parsed.values[33] = beat
			parsed.present[33] = true
			onsets, ok := arp_measure(dll, &parsed, pristine, work, notes, seconds)
			defer delete(onsets)
			if !ok {
				fmt.eprintfln("  %-4v could not load the reference", beat)
				continue
			}
			beats, steps := arp_period_beats(onsets[:])
			duty := 0.0
			if len(onsets) > 1 {
				duties := make([]f64, len(onsets) - 1, context.temp_allocator)
				for i in 0 ..< len(onsets) - 1 {duties[i] = onsets[i].duty}
				duty = median(duties)
			}
			fmt.printfln("  %v %v %v %v %v",
				arp_pad(fmt.tprintf("%v", beat), 4),
				arp_pad_right(sengine.resolved_display(33, beat), 16),
				arp_pad(fmt.tprintf("%v", steps), 6),
				arp_pad(fmt.tprintf("%.4f", beats), 15),
				arp_pad(fmt.tprintf("%.2f", duty), 6))
		}
		return
	}

	parsed.values[33] = beat_index
	parsed.present[33] = true
	onsets, ok := arp_measure(dll, &parsed, pristine, work, notes, seconds)
	defer delete(onsets)
	if !ok {
		fmt.eprintln("arpprobe: could not load the reference")
		os.exit(1)
	}

	beats, steps := arp_period_beats(onsets[:])
	fmt.println()
	fmt.printfln("type %v (%v), range %v (%v), beat %v (%v), gate %v",
		type_index, sengine.resolved_display(31, type_index),
		range_index, sengine.resolved_display(32, range_index),
		beat_index, sengine.resolved_display(33, beat_index),
		gate_index)
	fmt.printfln("%v steps, median period %.4f beats", steps, beats)
	fmt.println()
	fmt.println("  step   time s    beats     Hz      midi    semitones from first   duty")
	first_midi := len(onsets) > 0 ? onsets[0].midi : 0
	for o, i in onsets {
		fmt.printfln("  %-6v %-9.4f %-9.3f %-7.1f %-7.2f %-22.2f %.2f",
			i, o.seconds, o.seconds / ARP_BEAT_SECONDS, o.hz, o.midi,
			o.midi - first_midi, o.duty)
	}
}

// The reference's own state chunk, read once so a patch can be pushed into it.
// Same shape as compare's setup; kept here so the probe stands on its own.
arp_chunk_buffers :: proc(dll: string) -> (pristine, work: []byte, ok: bool) {
	p, loaded := load(dll)
	if !loaded {
		fmt.eprintfln("arpprobe: cannot load %v", dll)
		return nil, nil, false
	}
	defer unload(&p)

	raw: rawptr
	size := p.eff.dispatcher(p.eff, i32(Op.GetChunk), 0, 0, &raw, 0)
	if size <= 0 || raw == nil {
		fmt.eprintln("arpprobe: the reference returned no state chunk")
		return nil, nil, false
	}
	pristine = make([]byte, int(size))
	src := ([^]byte)(raw)
	for i in 0 ..< int(size) {pristine[i] = src[i]}
	work = make([]byte, int(size))
	return pristine, work, true
}

// Odin's fmt pads a widthed number with zeros rather than spaces, which turns a
// column of measurements into a column of noise. Padded by hand instead.
arp_pad :: proc(s: string, width: int) -> string {
	if len(s) >= width {return s}
	spaces := "                                        "
	return fmt.tprintf("%v%v", spaces[:width - len(s)], s)
}

arp_pad_right :: proc(s: string, width: int) -> string {
	if len(s) >= width {return s}
	spaces := "                                        "
	return fmt.tprintf("%v%v", s, spaces[:width - len(s)])
}
