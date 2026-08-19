package factorybank

// The factory bank: sixteen patches of this project's own, written as data.
//
//   odin run tools/factorybank -- patches/quesynth/factory.json
//
// Why a program and not sixteen JSON files by hand. A patch is ninety-nine
// numbers, and ninety-nine numbers written out by hand are ninety-nine numbers
// nobody will ever check. Here each patch is the handful of settings that make
// it what it is, on top of the reference's own defaults, with a line saying
// what it is for -- so the file is readable as a description of the sound and
// the bank is regenerated rather than maintained.
//
// These are original. The banks under patches/ and in zipbank.zip belong to
// Synth1 and to their own authors, and were read to learn which parameters
// matter for a given archetype -- that a pad wants a slow filter attack and a
// long release, that a pluck lives on a fast decay with high key tracking --
// which is knowledge about the instrument rather than anybody's patch. Every
// value below was chosen here.
//
// The bank is chosen to cover the instrument rather than to be a greatest hits:
// between them these sixteen use all four oscillator 1 waveforms, all four of
// oscillator 2's including noise, sync, ring modulation, FM, the sub
// oscillator, all five filter types, the modulation envelope on each of its
// three destinations, both LFOs with tempo and key sync, all four effect
// sections, unison, portamento, all three play modes, and the arpeggiator.

import "core:fmt"
import "core:math"
import "core:os"

import "../../src/engine"
import "../../src/patch"

Setting :: struct {
	name:  string,
	value: int,
}

Design :: struct {
	name:     string,
	// What this patch is here to demonstrate. Not written into the file -- the
	// format has no room for it -- but the reason the patch exists.
	shows:    string,
	settings: []Setting,
}

// Parameter names are the ones in src/patch/params.odin, which is what the JSON
// format keys on. A typo is caught at generation rather than becoming a silently
// ignored line in a patch file.
DESIGNS := []Design {
	{
		name = "Strings",
		shows = "unison, chorus, a slow filter envelope",
		settings = {
			{"osc1 shape", 1}, // saw
			{"osc2 shape", 0}, // saw
			{"osc2 fine tune", 74},
			{"osc mix", 64},
			{"filter type", 1}, // low pass 24
			{"filter attack", 62},
			{"filter decay", 78},
			{"filter sustain", 88},
			{"filter release", 96},
			{"*filter freq", 66},
			{"*filter resonance", 18},
			{"filter amount", 96},
			{"filter kbd track", 72},
			{"amp attack", 74},
			{"amp decay", 80},
			{"amp sustain", 118},
			{"amp release", 98},
			{"amp gain", 100},
			{"unison mode", 1},
			{"unison voice num", 4},
			{"unison detune", 18},
			{"unison pan spread", 84},
			{"chorus on/off", 1},
			{"chorus depth", 70},
			{"chorus rate", 44},
			{"delay on/off", 1},
			{"delay dry/wet", 34},
			{"polyphony", 16},
		},
	},
	{
		name = "Pad",
		shows = "a tempo-synced LFO on the cutoff, long everything",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 fine tune", 88},
			{"osc mix", 58},
			{"filter type", 0}, // low pass 12, gentler for a wash
			{"filter attack", 96},
			{"filter sustain", 110},
			{"filter release", 118},
			{"*filter freq", 54},
			{"*filter resonance", 26},
			{"filter amount", 84},
			{"amp attack", 112},
			{"amp sustain", 127},
			{"amp release", 120},
			{"amp gain", 92},
			// LFO 1 on the cutoff, locked to the beat: the slow breathing that
			// makes a pad move without anybody playing anything.
			{"lfo1 on/off", 1},
			{"lfo1 destination", 3}, // displays 1..7; 3 is the filter cutoff
			{"lfo1 type", 2}, // sine
			{"lfo1 tempo sync", 1},
			{"lfo1 speed", 30},
			{"lfo1 depth", 44},
			{"unison mode", 1},
			{"unison voice num", 5},
			{"unison detune", 26},
			{"unison pan spread", 104},
			{"chorus on/off", 1},
			{"chorus depth", 84},
			{"chorus rate", 30},
			{"delay on/off", 1},
			{"delay time", 10},
			{"delay feedback", 52},
			{"delay dry/wet", 58},
		},
	},
	{
		name = "Solo Lead",
		shows = "monophonic play with portamento, and the delay in ping-pong",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 1}, // pulse
			{"osc2 fine tune", 70},
			{"osc mix", 70},
			{"osc pulse width", 82},
			{"filter type", 1},
			{"filter attack", 20},
			{"filter decay", 70},
			{"filter sustain", 84},
			{"*filter freq", 62},
			{"*filter resonance", 34},
			{"filter amount", 92},
			{"filter kbd track", 80},
			{"amp attack", 22},
			{"amp sustain", 122},
			{"amp release", 58},
			{"play mode type", 1}, // monophonic
			{"portament time", 44},
			{"unison mode", 1},
			{"unison voice num", 3},
			{"unison detune", 22},
			{"delay on/off", 1},
			{"delay type", 2}, // ping-pong
			{"delay time", 11},
			{"delay feedback", 56},
			{"delay dry/wet", 46},
			{"chorus on/off", 1},
			{"chorus level", 30},
		},
	},
	{
		name = "Bass",
		shows = "the sub oscillator and a fast filter envelope, dry",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 pitch", 64},
			{"osc2 fine tune", 66},
			{"osc mix", 54},
			{"osc1 sub gain", 74},
			{"osc1 sub shape", 1},
			{"osc1 sub octave", 0}, // one octave down
			{"filter type", 1},
			{"filter attack", 0},
			{"filter decay", 52},
			{"filter sustain", 24},
			{"filter release", 40},
			{"*filter freq", 42},
			{"*filter resonance", 52},
			{"filter amount", 104},
			{"filter kbd track", 60},
			{"amp attack", 2},
			{"amp decay", 74},
			{"amp sustain", 96},
			{"amp release", 40},
			{"amp gain", 110},
			{"play mode type", 1},
			// Dry on purpose. A bass with a long delay on it is a bass nobody
			// can place in a mix, and the bank needs at least one patch that
			// shows the instrument with no effects at all.
			{"delay on/off", 0},
			{"chorus on/off", 0},
			{"polyphony", 4},
		},
	},
	{
		name = "Pluck",
		shows = "a short decay with heavy key tracking, and velocity",
		settings = {
			{"osc1 shape", 2}, // pulse
			{"osc2 shape", 0},
			{"osc2 fine tune", 72},
			{"osc mix", 60},
			{"osc pulse width", 96},
			{"filter type", 1},
			{"filter attack", 0},
			{"filter decay", 44},
			{"filter sustain", 8},
			{"filter release", 44},
			{"*filter freq", 58},
			{"*filter resonance", 40},
			{"filter amount", 112},
			{"filter kbd track", 104},
			{"amp attack", 0},
			{"amp decay", 58},
			{"amp sustain", 30},
			{"amp release", 52},
			// Wide open, so playing softly is audible as playing softly. Most of
			// the bank sits nearer the reference's own default.
			{"amp velocity sens", 104},
			{"delay on/off", 1},
			{"delay dry/wet", 30},
			{"chorus on/off", 1},
			{"chorus level", 26},
		},
	},
	{
		name = "Bells",
		shows = "FM, with the modulation envelope driving the FM amount",
		settings = {
			{"osc1 shape", 0}, // sine, so the FM sidebands are the whole timbre
			{"osc2 shape", 2}, // triangle
			{"osc2 pitch", 76}, // a twelfth up, which is what makes it a bell
			{"osc mix", 20},
			{"osc1 FM", 74},
			{"osc mod env on/off", 1},
			{"osc mod dest", 1}, // FM amount
			{"osc mod env amount", 92},
			{"osc mod env attack", 4},
			{"osc mod env decay", 62},
			{"filter type", 0},
			{"filter sustain", 127},
			{"*filter freq", 96},
			{"*filter resonance", 4},
			{"filter amount", 64},
			{"amp attack", 0},
			{"amp decay", 96},
			{"amp sustain", 40},
			{"amp release", 104},
			{"delay on/off", 1},
			{"delay time", 9},
			{"delay feedback", 48},
			{"delay dry/wet", 52},
			{"chorus on/off", 1},
			{"chorus depth", 60},
		},
	},
	{
		name = "Organ",
		shows = "the sub oscillator as a drawbar, full sustain, no envelope",
		settings = {
			{"osc1 shape", 3}, // triangle
			{"osc2 shape", 2}, // triangle
			{"osc2 pitch", 76},
			{"osc mix", 58},
			{"osc1 sub gain", 62},
			{"osc1 sub shape", 0},
			{"filter type", 0},
			{"filter sustain", 127},
			{"filter release", 20},
			{"*filter freq", 82},
			{"*filter resonance", 8},
			{"filter amount", 64},
			{"filter kbd track", 96},
			// The organ shape: no attack, no decay, no release worth the name.
			{"amp attack", 0},
			{"amp sustain", 127},
			{"amp release", 16},
			{"amp gain", 80},
			{"amp velocity sens", 0}, // a drawbar organ does not respond to touch
			{"chorus on/off", 1},
			{"chorus type", 2},
			{"chorus depth", 74},
			{"chorus rate", 52},
			{"chorus level", 62},
			{"delay on/off", 0},
			{"polyphony", 16},
		},
	},
	{
		name = "Brass",
		shows = "a filter envelope with an attack on it, and the equaliser",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 fine tune", 76},
			{"osc mix", 66},
			{"filter type", 1},
			// The brass gesture: the cutoff arrives a moment after the note.
			{"filter attack", 44},
			{"filter decay", 66},
			{"filter sustain", 72},
			{"filter release", 60},
			{"*filter freq", 50},
			{"*filter resonance", 30},
			{"filter amount", 108},
			{"filter kbd track", 70},
			{"filter saturation", 22},
			{"amp attack", 34},
			{"amp decay", 70},
			{"amp sustain", 112},
			{"amp release", 54},
			// Three unison voices through a saturating filter and then an
			// equaliser boost is a lot of gain stages in a row; the level has to
			// come back somewhere or the soft clip does it instead.
			{"amp gain", 62},
			{"equalizer tone", 78},
			{"equalizer freq", 74},
			{"equalizer level", 84},
			{"equalizer Q", 58},
			{"unison mode", 1},
			{"unison voice num", 3},
			{"unison detune", 14},
			{"delay on/off", 1},
			{"delay dry/wet", 28},
		},
	},
	{
		name = "Arp",
		shows = "the arpeggiator: up and down, two octaves, sixteenths",
		settings = {
			{"osc1 shape", 2},
			{"osc2 shape", 1},
			{"osc2 fine tune", 70},
			{"osc mix", 62},
			{"osc pulse width", 88},
			{"arpeggiator on/off", 1},
			{"arpeggiator type", 1}, // up and down
			{"arpeggiator oct range", 1}, // two octaves
			{"arpeggiator beat", 14}, // (16)
			{"arpeggiator gate", 52},
			{"filter type", 1},
			{"filter attack", 0},
			{"filter decay", 48},
			{"filter sustain", 20},
			{"*filter freq", 60},
			{"*filter resonance", 44},
			{"filter amount", 100},
			{"filter kbd track", 84},
			{"amp attack", 0},
			{"amp decay", 54},
			{"amp sustain", 44},
			{"amp release", 40},
			{"delay on/off", 1},
			{"delay type", 2},
			{"delay time", 14},
			{"delay feedback", 58},
			{"delay dry/wet", 44},
			{"chorus on/off", 1},
		},
	},
	{
		name = "Sweep",
		shows = "noise on oscillator 2 under a band pass, LFO on the cutoff",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 3}, // noise
			{"osc mix", 88}, // mostly noise
			{"filter type", 3}, // band pass
			{"filter attack", 88},
			{"filter sustain", 96},
			{"filter release", 100},
			{"*filter freq", 58},
			// A band pass is a narrow window on the noise, and the narrower the
			// resonance makes it the less comes through. High enough to hear the
			// sweep, low enough that there is a signal to sweep.
			{"*filter resonance", 30},
			{"filter amount", 100},
			{"amp attack", 96},
			{"amp sustain", 120},
			{"amp release", 110},
			{"amp gain", 118},
			{"lfo1 on/off", 1},
			{"lfo1 destination", 3}, // filter cutoff
			{"lfo1 type", 6}, // random smooth
			{"lfo1 speed", 38},
			{"lfo1 depth", 60},
			{"chorus on/off", 1},
			{"chorus depth", 90},
			{"delay on/off", 1},
			{"delay dry/wet", 60},
			{"delay feedback", 60},
		},
	},
	{
		name = "Sync Lead",
		shows = "oscillator sync, swept by the modulation envelope",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 sync", 1},
			{"osc2 pitch", 78},
			{"osc mix", 96}, // sync lives on oscillator 2
			{"osc mod env on/off", 1},
			{"osc mod dest", 0}, // oscillator 2 pitch, which is the sync sweep
			{"osc mod env amount", 100},
			{"osc mod env attack", 8},
			{"osc mod env decay", 74},
			{"filter type", 1},
			{"filter sustain", 110},
			{"*filter freq", 78},
			{"*filter resonance", 20},
			{"filter amount", 72},
			{"amp attack", 4},
			{"amp sustain", 120},
			{"amp release", 48},
			{"play mode type", 2}, // legato
			{"portament time", 28},
			{"delay on/off", 1},
			{"delay dry/wet", 40},
			{"delay type", 1}, // cross feedback
		},
	},
	{
		name = "Ring Bell",
		shows = "ring modulation, and the pulse width under the mod envelope",
		settings = {
			{"osc1 shape", 2}, // pulse
			{"osc2 shape", 2},
			{"osc2 ring modulation", 1},
			{"osc2 pitch", 71},
			{"osc2 fine tune", 90},
			{"osc mix", 64},
			{"osc pulse width", 74},
			{"osc mod env on/off", 1},
			{"osc mod dest", 2}, // pulse width
			{"osc mod env amount", 84},
			{"osc mod env attack", 0},
			{"osc mod env decay", 70},
			{"filter type", 0},
			{"filter sustain", 120},
			{"*filter freq", 88},
			{"filter amount", 64},
			{"amp attack", 0},
			{"amp decay", 84},
			{"amp sustain", 24},
			{"amp release", 96},
			{"delay on/off", 1},
			{"delay dry/wet", 48},
			{"delay feedback", 54},
			{"chorus on/off", 1},
		},
	},
	{
		name = "Wobble",
		shows = "a square LFO locked to the beat, which is the whole patch",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 fine tune", 68},
			{"osc mix", 60},
			{"osc1 sub gain", 56},
			{"osc1 sub octave", 0},
			{"filter type", 1},
			{"filter sustain", 127},
			{"*filter freq", 38},
			{"*filter resonance", 88},
			{"filter amount", 64},
			{"amp attack", 4},
			{"amp sustain", 122},
			{"amp release", 44},
			{"lfo1 on/off", 1},
			{"lfo1 destination", 3},
			{"lfo1 type", 4}, // square
			{"lfo1 tempo sync", 1},
			{"lfo1 speed", 62},
			{"lfo1 depth", 92},
			{"lfo1 key sync", 1},
			{"play mode type", 1},
			{"delay on/off", 0},
			{"chorus on/off", 0},
		},
	},
	{
		name = "Noise Perc",
		shows = "a high pass on noise with no sustain at all",
		settings = {
			{"osc1 shape", 2},
			{"osc2 shape", 3}, // noise
			{"osc mix", 118},
			{"filter type", 2}, // high pass 12
			{"filter attack", 0},
			{"filter decay", 30},
			{"filter sustain", 0},
			{"filter release", 24},
			// A high pass this far up on a source that is already mostly noise
			// throws away nearly all of it. Measured at 70 the patch came out at
			// a peak of 0.02, which is present on a meter and absent in a mix.
			{"*filter freq", 46},
			{"*filter resonance", 56},
			{"filter amount", 88},
			{"amp attack", 0},
			{"amp decay", 52},
			{"amp sustain", 0},
			{"amp release", 28},
			{"amp velocity sens", 96},
			{"amp gain", 124},
			{"delay on/off", 1},
			{"delay type", 2},
			{"delay time", 14},
			{"delay feedback", 44},
			{"delay dry/wet", 40},
			{"polyphony", 8},
		},
	},
	{
		name = "Phaser Pad",
		shows = "the effect unit, on one of its four phasers",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 2},
			{"osc2 fine tune", 86},
			{"osc mix", 62},
			{"filter type", 0},
			{"filter attack", 80},
			{"filter sustain", 112},
			{"filter release", 110},
			{"*filter freq", 62},
			{"filter amount", 76},
			{"amp attack", 100},
			{"amp sustain", 124},
			{"amp release", 116},
			{"amp gain", 94},
			{"effect on/off", 1},
			{"effect type", 6}, // the first of the phasers
			{"effect control1", 80},
			{"effect control2", 40},
			{"effect level/mix", 90},
			{"unison mode", 1},
			{"unison voice num", 4},
			{"unison detune", 20},
			{"unison pan spread", 96},
			{"chorus on/off", 1},
			{"delay on/off", 1},
			{"delay dry/wet", 40},
		},
	},
	{
		name = "Ladder Lead",
		shows = "the ladder filter driven into its saturation",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 0},
			{"osc2 fine tune", 72},
			{"osc mix", 66},
			{"filter type", 4}, // low pass ladder
			{"filter attack", 6},
			{"filter decay", 60},
			{"filter sustain", 76},
			{"filter release", 50},
			{"*filter freq", 54},
			{"*filter resonance", 96},
			{"filter amount", 96},
			{"filter kbd track", 76},
			{"filter saturation", 92},
			{"amp attack", 6},
			{"amp sustain", 118},
			{"amp release", 50},
			{"amp gain", 96},
			{"play mode type", 2},
			{"portament time", 20},
			{"delay on/off", 1},
			{"delay dry/wet", 38},
			{"delay feedback", 50},
		},
	},
}

build_patch :: proc(design: Design) -> (patch.Patch, bool) {
	p: patch.Patch
	p.name = design.name
	p.version = patch.SY1_BIPOLAR_VERSION
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
		p.present[i] = true
	}

	ok := true
	for setting in design.settings {
		index := patch.parameter_index(setting.name)
		if index < 0 {
			fmt.eprintfln("%v: no parameter named %q", design.name, setting.name)
			ok = false
			continue
		}
		// The states a parameter actually has. A value past the end is a
		// mistake in the design above, not something to pass on to a file: the
		// plugin would clamp it and the patch would quietly not be the patch.
		states := len(patch.parameter_states(index))
		if states > 0 && !patch.PARAMETERS[index].display_keyed {
			if setting.value < 0 || setting.value >= states {
				fmt.eprintfln(
					"%v: %v = %v is outside its %v states",
					design.name,
					setting.name,
					setting.value,
					states,
				)
				ok = false
				continue
			}
		}
		p.values[index] = setting.value
	}
	return p, ok
}

main :: proc() {
	args := os.args[1:]
	output := len(args) >= 1 ? args[0] : "patches/quesynth/factory.json"

	patches := make([]patch.Patch, len(DESIGNS))
	defer delete(patches)

	ok := true
	for design, i in DESIGNS {
		p, built := build_patch(design)
		if !built {
			ok = false
		}
		patches[i] = p
	}
	if !ok {
		os.exit(1)
	}

	text := patch.write_bank_json("Quesynth Factory", patches)
	defer delete(text)
	if err := os.write_entire_file(output, transmute([]u8)text); err != nil {
		fmt.eprintfln("cannot write %v: %v", output, err)
		os.exit(1)
	}

	fmt.printfln("wrote %v", output)
	fmt.println()
	check(patches)
}

// Render every patch and report what came out.
//
// A bank generator that only writes a file has verified nothing: a patch whose
// filter is shut, whose amplitude envelope never opens, or which is a
// copy of its neighbour with a different name, all write out perfectly well. So
// each one is played and measured, and the numbers are printed side by side
// where "these two are the same sound" is visible.
//
// Brightness here is the zero-crossing rate rather than a spectral centroid:
// this tool has no FFT and does not need one, because the question is only
// whether sixteen patches differ from each other and by roughly how much.
check :: proc(patches: []patch.Patch) {
	fmt.println("  patch          peak      rms     bright   attacks   verdict")

	seconds :: 3.0
	frames := int(seconds * 48000)
	left := make([]f32, frames)
	right := make([]f32, frames)
	defer delete(left)
	defer delete(right)

	for p, i in patches {
		eng: engine.Engine
		engine.engine_load_patch(&eng, p, 48000)
		// A chord rather than one note: the arpeggiator has nothing to
		// arpeggiate over otherwise, and unison and polyphony are only exercised
		// by more than one voice.
		engine.engine_note_on(&eng, 48, 0.8)
		engine.engine_note_on(&eng, 55, 0.8)
		engine.engine_note_on(&eng, 60, 0.8)
		engine.engine_process(&eng, left, right)
		engine.engine_destroy(&eng)

		peak, sum := 0.0, 0.0
		crossings := 0
		previous := f32(0)
		for j in 0 ..< frames {
			v := left[j]
			a := abs(f64(v))
			peak = max(peak, a)
			sum += f64(v) * f64(v)
			if (v >= 0) != (previous >= 0) {
				crossings += 1
			}
			previous = v
		}
		rms := math.sqrt(sum / f64(frames))
		bright := f64(crossings) / seconds

		// Attacks, counted the way tools/s1probe's arpeggiator probe does: a
		// rise through a high threshold having first fallen below a low one.
		// One attack is a held note; several mean the patch retriggers, which
		// for this bank means the arpeggiator is running.
		attacks := 0
		armed := true
		window := 480 // 10 ms
		for j := 0; j + window < frames; j += window {
			local := 0.0
			for k in j ..< j + window {
				local = max(local, abs(f64(left[k])))
			}
			if local < peak * 0.08 {
				armed = true
			} else if armed && local >= peak * 0.35 {
				attacks += 1
				armed = false
			}
		}

		verdict := "ok"
		if peak < 0.005 {
			verdict = "SILENT"
		} else if peak > 0.99 {
			verdict = "CLIPPING"
		}

		fmt.printfln(
			"  %-14v %v %v %v %v   %v",
			DESIGNS[i].name,
			pad(fmt.tprintf("%.4f", peak), 8),
			pad(fmt.tprintf("%.4f", rms), 8),
			pad(fmt.tprintf("%.0f", bright), 8),
			pad(fmt.tprintf("%v", attacks), 8),
			verdict,
		)
	}
}

pad :: proc(s: string, width: int) -> string {
	if len(s) >= width {return s}
	spaces := "                    "
	return fmt.tprintf("%v%v", spaces[:width - len(s)], s)
}
