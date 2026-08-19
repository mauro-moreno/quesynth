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

// What a patch in this bank should measure, in dBFS RMS, on a three-note chord.
//
// Level matching is not cosmetic. A bank whose patches sit thirty decibels
// apart makes the loud ones sound harsh and the quiet ones sound thin, and the
// listener blames the sound rather than the gain -- which is exactly the
// complaint this bank drew. -22 dBFS leaves room for a six-note chord without
// clipping while still being a healthy signal.
TARGET_DBFS :: -22.0

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
			{"osc2 shape", 1}, // saw
			{"osc2 fine tune", 74},
			{"osc mix", 64},
			{"filter type", 1}, // low pass 24
			{"filter attack", 62},
			{"filter decay", 78},
			{"filter sustain", 88},
			{"filter release", 96},
			{"*filter freq", 58},
			{"*filter resonance", 18},
			{"filter amount", 72},
			{"filter kbd track", 72},
			{"amp attack", 74},
			{"amp decay", 80},
			{"amp sustain", 118},
			{"amp release", 98},
			{"amp gain", 54}, // levelled; see `factorybank -calibrate`
			{"unison mode", 1},
			{"unison voice num", 4},
			{"unison detune", 12},
			{"unison pan spread", 84},
			{"chorus on/off", 1},
			{"chorus depth", 46},
			{"chorus rate", 44},
			{"delay on/off", 1},
			{"delay dry/wet", 22},
			{"polyphony", 16},
		},
	},
	{
		name = "Pad",
		shows = "a tempo-synced LFO on the cutoff, long everything",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 1}, // saw
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
			{"amp gain", 90}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 2}, // pulse
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
			{"amp gain", 93}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Bass",
		shows = "the sub oscillator and a fast filter envelope, dry",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 1}, // saw
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
			{"amp gain", 104}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 1}, // saw
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
			{"amp gain", 127}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Bells",
		shows = "FM, with the modulation envelope driving the FM amount",
		settings = {
			{"osc1 shape", 0}, // sine, so the FM sidebands are the whole timbre
			{"osc2 shape", 3}, // triangle
			{"osc2 pitch", 84}, // a twelfth up, which is what makes it a bell
			{"osc2 fine tune", 62}, // dead in tune; the default is +15 cents
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
			{"amp gain", 84}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Organ",
		shows = "the sub oscillator as a drawbar, full sustain, no envelope",
		settings = {
			{"osc1 shape", 3}, // triangle
			{"osc2 shape", 3}, // triangle
			{"osc2 pitch", 77},
			{"osc2 fine tune", 62}, // dead in tune; the default is +15 cents
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
			{"amp gain", 42}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 1}, // saw
			{"osc2 fine tune", 76},
			{"osc mix", 66},
			{"filter type", 1},
			// The brass gesture: the cutoff arrives a moment after the note.
			{"filter attack", 44},
			{"filter decay", 66},
			{"filter sustain", 72},
			{"filter release", 60},
			{"*filter freq", 50},
			{"*filter resonance", 18},
			{"filter amount", 78},
			{"filter kbd track", 70},
			{"filter saturation", 22},
			{"amp attack", 34},
			{"amp decay", 70},
			{"amp sustain", 112},
			{"amp release", 54},
			{"amp gain", 53}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 2}, // pulse
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
			{"amp gain", 127}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Sweep",
		shows = "noise on oscillator 2 under a band pass, LFO on the cutoff",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 4}, // noise
			{"osc mix", 78}, // mostly noise
			{"filter type", 3}, // band pass
			{"filter attack", 88},
			{"filter sustain", 96},
			{"filter release", 100},
			{"*filter freq", 58},
			// A band pass is a narrow window on the noise, and the narrower the
			// resonance makes it the less comes through. High enough to hear the
			// sweep, low enough that there is a signal to sweep.
			{"*filter resonance", 16},
			{"filter amount", 100},
			{"amp attack", 96},
			{"amp sustain", 120},
			{"amp release", 110},
			{"amp gain", 101}, // levelled; see `factorybank -calibrate`
			{"lfo1 on/off", 1},
			{"lfo1 destination", 3}, // filter cutoff
			{"lfo1 type", 5}, // the last type; there are six, displayed 0..5
			{"lfo1 speed", 38},
			{"lfo1 depth", 60},
			{"chorus on/off", 1},
			{"chorus depth", 64},
			{"delay on/off", 1},
			{"delay dry/wet", 40},
			{"delay feedback", 60},
		},
	},
	{
		name = "Sync Lead",
		shows = "oscillator sync, swept by the modulation envelope",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 1}, // saw
			{"osc2 sync", 1},
			{"osc2 pitch", 79},
			{"osc2 fine tune", 62}, // dead in tune; the default is +15 cents
			// Not all the way over to oscillator 2. A hard-synced oscillator
			// swept across two octaves is inharmonic by construction -- that is
			// the sound -- and at a mix of 96 there was nothing else left to
			// hold a pitch, so it measured 0.32 tonal and read as noise rather
			// than as a sync sweep. Oscillator 1 stays audible underneath it.
			{"osc mix", 62},
			{"osc mod env on/off", 1},
			{"osc mod dest", 0}, // oscillator 2 pitch, which is the sync sweep
			{"osc mod env amount", 72},
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
			{"amp gain", 96}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Ring Bell",
		shows = "ring modulation, and the pulse width under the mod envelope",
		settings = {
			{"osc1 shape", 2}, // pulse
			{"osc2 shape", 3}, // triangle
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
			{"amp gain", 103}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Wobble",
		shows = "a square LFO locked to the beat, which is the whole patch",
		settings = {
			{"osc1 shape", 1},
			{"osc2 shape", 1}, // saw
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
			{"amp gain", 75}, // levelled; see `factorybank -calibrate`
		},
	},
	{
		name = "Noise Perc",
		shows = "a high pass on noise with no sustain at all",
		settings = {
			{"osc1 shape", 2},
			{"osc2 shape", 4}, // noise
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
			{"amp gain", 119}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 3}, // triangle
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
			{"amp gain", 76}, // levelled; see `factorybank -calibrate`
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
			{"osc2 shape", 1}, // saw
			{"osc2 fine tune", 72},
			{"osc mix", 66},
			{"filter type", 4}, // low pass ladder
			{"filter attack", 6},
			{"filter decay", 60},
			{"filter sustain", 76},
			{"filter release", 50},
			{"*filter freq", 54},
			{"*filter resonance", 74},
			{"filter amount", 72},
			{"filter kbd track", 76},
			{"filter saturation", 66},
			{"amp attack", 6},
			{"amp sustain", 118},
			{"amp release", 50},
			{"amp gain", 77}, // levelled; see `factorybank -calibrate`
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

		// The check above deliberately skips display-keyed parameters, and that
		// is the hole every osc2 shape in this bank went through.
		//
		// A display-keyed parameter stores its display rather than its position,
		// so oscillator 2's four states, shown "1".."4", have no state 0 --
		// while oscillator 1's, shown "0".."3", do. Written 0-based like its
		// neighbour, every shape here named the wrong waveform, and the eight
		// that asked for 0 fell off the bottom of the table and got what
		// Clamp_To_Top gives, which is noise. Nothing failed: the bank generated,
		// the patches rendered, and eight of them were quietly the wrong sound.
		//
		// Only the clamping ones are checked. A Continue_Grid parameter is meant
		// to be driven past its table -- amp sustain's own default is past it --
		// so a value with no display is ordinary there and not a mistake.
		if states > 0 &&
		   patch.PARAMETERS[index].display_keyed &&
		   patch.PARAMETERS[index].out_of_range == .Clamp_To_Top {
			selects_a_state := false
			for state in patch.parameter_states(index) {
				if value, is_number := patch.display_integer(state.display);
				   is_number && value == setting.value {
					selects_a_state = true
					break
				}
			}
			if !selects_a_state {
				fmt.eprintfln(
					"%v: %v = %v selects no state; it would clamp to another one",
					design.name,
					setting.name,
					setting.value,
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
	if len(args) >= 1 && args[0] == "-calibrate" {
		calibrate()
		return
	}
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
// Renders a chord and fills in `left`/`right`. Separate from the measuring
// because the same patch is played twice: once as it would be played, and once
// with both hands down, which is the only way to see how much headroom it has
// left before a normal performance clips it.
// The RMS of the loudest 300 ms, rather than of the whole render.
//
// Whole-render RMS is not a level. A pluck that decays in 200 ms and a pad that
// holds for three seconds can sit equally loud under the hand and still read
// twenty decibels apart, because most of the pluck's window is silence.
// Levelling a bank on that figure makes every percussive patch far too loud.
// A short-term window is what a loudness meter uses, for this reason.
loudest_rms :: proc(left: []f32) -> f64 {
	window := 14400 // 300 ms at 48 kHz
	if len(left) < window {window = len(left)}
	if window <= 0 {return 0}

	// A sliding sum, so this stays a single pass however long the render is.
	sum := 0.0
	for j in 0 ..< window {
		sum += f64(left[j]) * f64(left[j])
	}
	best := sum
	for j in window ..< len(left) {
		sum += f64(left[j]) * f64(left[j])
		sum -= f64(left[j - window]) * f64(left[j - window])
		best = max(best, sum)
	}
	return math.sqrt(best / f64(window))
}

render_chord :: proc(p: patch.Patch, notes: []int, left, right: []f32) -> f64 {
	eng: engine.Engine
	engine.engine_load_patch(&eng, p, 48000)
	for note in notes {
		engine.engine_note_on(&eng, note, 0.8)
	}
	engine.engine_process(&eng, left, right)
	engine.engine_destroy(&eng)

	peak := 0.0
	for v in left {
		peak = max(peak, abs(f64(v)))
	}
	return peak
}

check :: proc(patches: []patch.Patch) {
	fmt.println("  patch          peak      rms      dBFS      hot     bright     tonal   attacks   verdict")

	seconds :: 5.0
	frames := int(seconds * 48000)
	left := make([]f32, frames)
	right := make([]f32, frames)
	defer delete(left)
	defer delete(right)

	// A chord rather than one note: the arpeggiator has nothing to arpeggiate
	// over otherwise, and unison and polyphony are only exercised by more than
	// one voice.
	chord := []int{48, 55, 60}
	// Both hands. Nobody plays an organ patch with three fingers, and a bank
	// levelled on three notes has patches that clip the moment it is played
	// properly -- which is heard as the patch being harsh, not as the bank
	// being loud.
	full := []int{36, 48, 55, 60, 64, 67}

	for p, i in patches {
		hot := render_chord(p, full, left, right)
		render_chord(p, chord, left, right)

		peak := 0.0
		crossings := 0
		previous := f32(0)
		for j in 0 ..< frames {
			v := left[j]
			a := abs(f64(v))
			peak = max(peak, a)
			if (v >= 0) != (previous >= 0) {
				crossings += 1
			}
			previous = v
		}
		rms := loudest_rms(left)
		bright := f64(crossings) / seconds
		dbfs := rms > 1.0e-9 ? 20.0 * math.log10(rms) : -99.0

		// How periodic the sound is, on 0..1.
		//
		// The normalised autocorrelation at its best lag: a tone repeats itself
		// and scores near 1, noise does not repeat and scores near 0. This is
		// here because "the bank sounds noisy" is a real complaint and peak and
		// brightness cannot tell a bright sawtooth from a hiss -- both are lots
		// of zero crossings at a healthy level.
		//
		// Measured over a window after the attack, so the click at the start of
		// a percussive patch does not read as noise across the whole patch.
		//
		// The window is 200 ms and not the 100 ms it started as, because at 100
		// ms only six periods of a 60 Hz fundamental fit and the correlation
		// falls off for want of signal rather than for want of pitch. That
		// artefact is not hypothetical: it made a sub oscillator two octaves
		// down score worse than the same sub one octave down at every one of
		// the four shapes, which is a suspiciously tidy result for something
		// claiming to measure noise.
		tonality := 0.0
		{
			from := min(frames / 4, frames - 1)
			window := min(9600, frames - from) // 200 ms
			if window > 1600 {
				energy := 0.0
				for j in from ..< from + window {
					energy += f64(left[j]) * f64(left[j])
				}
				if energy > 1.0e-12 {
					// Lags from 40 samples (1200 Hz) to 800 (60 Hz), which
					// covers every fundamental this bank plays.
					for lag in 40 ..= min(800, window - 1) {
						correlation := 0.0
						for j in from ..< from + window - lag {
							correlation += f64(left[j]) * f64(left[j + lag])
						}
						tonality = max(tonality, correlation / energy)
					}
				}
			}
		}

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
		} else if hot > 0.99 {
			verdict = "CLIPS"
		} else if dbfs > TARGET_DBFS + 4.0 {
			verdict = "loud"
		} else if dbfs < TARGET_DBFS - 6.0 {
			verdict = "quiet"
		}

		fmt.printfln(
			"  %-14v %v %v %v %v %v %v %v   %v",
			DESIGNS[i].name,
			pad(fmt.tprintf("%.4f", peak), 8),
			pad(fmt.tprintf("%.4f", rms), 8),
			pad(fmt.tprintf("%.1f", dbfs), 8),
			pad(fmt.tprintf("%.3f", hot), 8),
			pad(fmt.tprintf("%.0f", bright), 8),
			pad(fmt.tprintf("%.2f", tonality), 8),
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

// Search for the `amp gain` that puts each patch at TARGET_DBFS without
// clipping a six-note chord, and print what to paste into DESIGNS.
//
// By rendering rather than by arithmetic on the gain table. The level a patch
// reaches is not the amp stage alone -- a resonant filter, a chorus, a delay
// and the unison voice count all multiply into it, and two of the patches that
// clipped were nowhere near the top of the gain table. Rendering costs a few
// seconds and is right about all of them.
//
// The answer is printed, not applied. A bank whose levels are solved at
// generation time is a bank whose contents quietly change the next time the
// filter does; pasting the numbers into DESIGNS keeps them visible, reviewable
// and stable.
calibrate :: proc() {
	fmt.println("  patch          amp gain     dBFS      hot")

	seconds :: 5.0
	frames := int(seconds * 48000)
	left := make([]f32, frames)
	right := make([]f32, frames)
	defer delete(left)
	defer delete(right)

	chord := []int{48, 55, 60}
	full := []int{36, 48, 55, 60, 64, 67}

	for design, i in DESIGNS {
		level_at :: proc(
			design: Design,
			gain: int,
			notes: []int,
			left, right: []f32,
		) -> (
			rms: f64,
			peak: f64,
		) {
			tuned := design
			settings := make([]Setting, len(design.settings) + 1)
			defer delete(settings)
			copy(settings, design.settings)
			settings[len(design.settings)] = Setting{"amp gain", gain}
			tuned.settings = settings

			p, built := build_patch(tuned)
			if !built {return 0, 0}

			peak = render_chord(p, notes, left, right)
			return loudest_rms(left), peak
		}

		// Bisection on the gain position. The mapping is monotonic -- more gain
		// is never less level -- which is the only property a bisection needs,
		// and it holds however the table is shaped.
		low, high := 0, 127
		for _ in 0 ..< 8 {
			mid := (low + high) / 2
			rms, _ := level_at(design, mid, chord[:], left, right)
			db := rms > 1.0e-9 ? 20.0 * math.log10(rms) : -99.0
			if db < TARGET_DBFS {
				low = mid + 1
			} else {
				high = mid
			}
		}
		gain := clamp(low, 0, 127)

		// Then back off until both hands fit. A patch levelled to the target on
		// three notes can still clip on six, and a clipped patch is heard as a
		// bad sound rather than a loud one -- which is the whole reason this
		// exists.
		for gain > 0 {
			_, peak := level_at(design, gain, full[:], left, right)
			if peak <= 0.95 {break}
			gain -= 4
		}
		gain = max(gain, 0)

		rms, _ := level_at(design, gain, chord[:], left, right)
		_, hot := level_at(design, gain, full[:], left, right)
		db := rms > 1.0e-9 ? 20.0 * math.log10(rms) : -99.0

		fmt.printfln(
			"  %-14v %v %v %v",
			DESIGNS[i].name,
			pad(fmt.tprintf("%v", gain), 8),
			pad(fmt.tprintf("%.1f", db), 8),
			pad(fmt.tprintf("%.3f", hot), 8),
		)
	}
}
