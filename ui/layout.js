// Panel layout: which control goes where, what it is called, and what it does.
//
// Hand written, unlike params.js. Four kinds of thing live here and nowhere else:
//
//   - **Grouping.** Controls that act on the same thing sit together under a
//     sub-heading, so the two oscillators do not interleave and the filter's
//     envelope is visibly one envelope rather than four loose knobs.
//   - **Two names per control.** `label` is what is printed under the control and
//     is always one line; `name` is the full name, which the information popover
//     shows. The group heading supplies the context the short label drops, so
//     "Fine Tune" under "Oscillator 2" loses nothing -- and nothing is ever
//     abbreviated to letters, which is the failure the reference's own panel has.
//   - **What it does.** One line per control, shown in the popover.
//   - **Option names.** The enumerated parameters store bare integers, and several
//     list their states in an order the manual gets wrong. The names here are the
//     *measured* ones from docs/reference-notes.md, in position order.
//
// `p` is the parameter index. Options are listed in position order, which is what
// params.js `s` maps back to the stored integer.

// The MIDI sources a controller assignment can name.
//
// Stored as a 16-bit MIDI status and data byte: 0xB0 in the high byte is a
// control change on channel 1, and the low byte is the controller number. So the
// modulation wheel is 0xB001, which is 45057 -- the number every factory patch
// carries, because none of them stores these at all and that is the default.
//
// A short list of the controllers a keyboard actually sends, rather than all 128.
var MIDI_SOURCES = [
  { v: 0xB001, label: "Modulation Wheel" },
  { v: 0xB002, label: "Breath" },
  { v: 0xB004, label: "Foot Pedal" },
  { v: 0xB007, label: "Volume" },
  { v: 0xB00A, label: "Pan" },
  { v: 0xB00B, label: "Expression" },
  { v: 0xB040, label: "Sustain Pedal" },
  { v: 0xB041, label: "Portamento Pedal" },
  { v: 0xB047, label: "Resonance" },
  { v: 0xB04A, label: "Brightness" },
];

// The destinations, which are simply parameter indices.
//
// Built from the generated table rather than typed out, so it cannot drift from
// the instrument, with -1 for "nothing". The reference's own dropdown offers a
// shorter, reordered list; that is a display, and what it stores is the index.
var MIDI_DESTINATIONS = (function () {
  var out = [{ v: -1, label: "None" }];
  (window.SYNTH1_PARAMS || []).forEach(function (p) {
    // The routing parameters themselves are not offered as destinations: a
    // controller wired to its own assignment is not a feature.
    if (p.i === 50 || p.i === 51 || (p.i >= 86 && p.i <= 89)) return;
    out.push({ v: p.i, label: p.name });
  });
  return out;
})();

window.SYNTH1_LAYOUT = [
  {
    // First, because it is about the instrument rather than about the sound: the
    // wheels, what they are wired to, and the output. Everything after it is one
    // stage of the voice.
    title: "Master",
    groups: [
      {
        label: "Output",
        controls: [
          { p: 90, label: "Pan", name: "Pan",
            desc: "Stereo position of the whole instrument." },
        ],
      },
      {
        label: "Pitch Wheel",
        controls: [
          { p: 40, label: "Bend Range", name: "Pitch Bend Range", kind: "stepper",
            desc: "How far the pitch wheel bends, in semitones." },
        ],
      },
      // Where the two wheels go. The source and destination are the only
      // parameters in the instrument that carry a raw number rather than a state
      // list, so their choices are spelled out here -- see `choices` in app.js.
      {
        label: "Controller 1",
        controls: [
          { p: 86, label: "Source", name: "Controller 1 Source", kind: "choice",
            desc: "Which incoming MIDI controller drives this assignment.",
            choices: MIDI_SOURCES },
          { p: 87, label: "Destination", name: "Controller 1 Destination", kind: "choice",
            desc: "Which parameter it moves. Stored as the parameter's own index.",
            choices: MIDI_DESTINATIONS },
          { p: 50, label: "Amount", name: "Controller 1 Amount",
            desc: "How far it moves that parameter, as a signed percentage of the full range." },
        ],
      },
      {
        label: "Controller 2",
        controls: [
          { p: 88, label: "Source", name: "Controller 2 Source", kind: "choice",
            desc: "Which incoming MIDI controller drives this assignment.",
            choices: MIDI_SOURCES },
          { p: 89, label: "Destination", name: "Controller 2 Destination", kind: "choice",
            desc: "Which parameter it moves. Stored as the parameter's own index.",
            choices: MIDI_DESTINATIONS },
          { p: 51, label: "Amount", name: "Controller 2 Amount",
            desc: "How far it moves that parameter, as a signed percentage of the full range." },
        ],
      },
    ],
  },
  {
    title: "Oscillators",
    groups: [
      {
        label: "Oscillator 1",
        controls: [
          { p: 0, label: "Waveform", name: "Oscillator 1 Waveform", kind: "radio",
            desc: "Waveform of the first oscillator, the carrier when FM is used.",
            options: ["Sine", "Sawtooth", "Pulse", "Triangle"] },
          { p: 76, label: "Detune", name: "Oscillator 1 Detune",
            desc: "Extra detune applied to oscillator 1 alone within a unison stack." },
        ],
      },
      {
        label: "Oscillator 2",
        controls: [
          { p: 1, label: "Waveform", name: "Oscillator 2 Waveform", kind: "radio",
            desc: "Waveform of the second oscillator, the modulator when FM is used.",
            options: ["Sawtooth", "Pulse", "Triangle", "Noise"] },
          { p: 2, label: "Pitch", name: "Oscillator 2 Pitch",
            desc: "Coarse tuning of oscillator 2, in semitones from oscillator 1." },
          { p: 3, label: "Fine Tune", name: "Oscillator 2 Fine Tune",
            desc: "Fine tuning of oscillator 2, in cents. Small amounts make the pair beat against each other." },
          { p: 4, label: "Key Tracking", name: "Oscillator 2 Key Tracking", kind: "toggle",
            desc: "When off, oscillator 2 holds one pitch regardless of the note played." },
        ],
      },
      {
        label: "Both Oscillators",
        controls: [
          { p: 5, label: "Mix", name: "Oscillator Mix",
            desc: "Balance between the two oscillators, as a percentage of each." },
          { p: 8, label: "Pulse Width", name: "Pulse Width",
            desc: "Duty cycle of both pulse waves. The knob spans 0 to 50 percent duty, not 0 to 100." },
          { p: 9, label: "Key Shift", name: "Key Shift",
            desc: "Transposes both oscillators, in semitones." },
          { p: 72, label: "Fine Tune", name: "Fine Tune",
            desc: "Fine tuning of both oscillators together, in cents." },
          { p: 91, label: "Phase", name: "Oscillator Phase",
            desc: "Start phase of oscillator 2 relative to oscillator 1. Fully left leaves the phase free running." },
        ],
      },
      {
        label: "Cross Modulation",
        controls: [
          { p: 45, label: "FM Amount", name: "FM Amount",
            desc: "Oscillator 2 modulates oscillator 1's frequency. Full amount is half a cycle of displacement." },
          { p: 6, label: "Sync", name: "Oscillator Sync", kind: "toggle",
            desc: "Oscillator 1 resets oscillator 2's phase, the hard sync tearing sound." },
          { p: 7, label: "Ring", name: "Ring Modulation", kind: "toggle",
            desc: "Multiplies the two oscillators together. Takes precedence over FM when both are on." },
        ],
      },
      {
        label: "Sub Oscillator",
        controls: [
          { p: 95, label: "Level", name: "Sub Oscillator Level",
            desc: "Level of an extra oscillator below oscillator 1. No factory patch uses it." },
          { p: 96, label: "Waveform", name: "Sub Oscillator Waveform", kind: "radio",
            desc: "Waveform of the sub oscillator.",
            options: ["Sine", "Sawtooth", "Pulse", "Triangle"] },
          { p: 97, label: "Octave", name: "Sub Oscillator Octave", kind: "radio",
            desc: "How far below oscillator 1 the sub oscillator sounds.",
            options: ["1 Octave Down", "2 Octaves Down"] },
        ],
      },
    ],
  },
  {
    title: "Filter",
    groups: [
      {
        label: "Shape",
        controls: [
          { p: 14, label: "Type", name: "Filter Type", kind: "radio",
            desc: "Response shape and steepness. The fourth is a band pass, not the high pass the English manual lists.",
            options: ["Low Pass 12 dB/oct", "Low Pass 24 dB/oct", "High Pass 12 dB/oct",
                      "Band Pass 12 dB/oct", "Low Pass Ladder"] },
          { p: 19, label: "Cutoff", name: "Cutoff Frequency", wide: true,
            desc: "Corner frequency. Measured from the reference: 24 Hz to about 17 kHz, in steps of roughly one semitone." },
          { p: 20, label: "Resonance", name: "Resonance", wide: true,
            desc: "Emphasis at the corner, shown as Q. Almost all of the travel is in the last fifteen steps, reaching self oscillation." },
          { p: 23, label: "Saturation", name: "Filter Saturation",
            desc: "Drive into the filter, adding harmonics as it is pushed." },
        ],
      },
      {
        label: "Modulation",
        controls: [
          { p: 21, label: "Amount", name: "Filter Envelope Amount",
            desc: "How far the filter envelope moves the corner, in octaves. Negative values sweep downwards." },
          { p: 22, label: "Key Tracking", name: "Filter Key Tracking",
            desc: "How much the corner follows the note played, in octaves per octave. Tracks from C3." },
          { p: 24, label: "Velocity", name: "Filter Velocity Switch", kind: "toggle",
            desc: "Scales the envelope amount by how hard the note is played." },
        ],
      },
      {
        label: "Envelope",
        controls: [
          { p: 15, label: "Attack", name: "Filter Envelope Attack",
            desc: "Time for the filter envelope to rise to full after a note starts." },
          { p: 16, label: "Decay", name: "Filter Envelope Decay",
            desc: "Time for the filter envelope to fall from full to its sustain level." },
          { p: 17, label: "Sustain", name: "Filter Envelope Sustain",
            desc: "Level the filter envelope holds while the note is held." },
          { p: 18, label: "Release", name: "Filter Envelope Release",
            desc: "Time for the filter envelope to fall away after the note is let go." },
        ],
      },
    ],
  },
  {
    title: "Amplifier",
    groups: [
      {
        label: "Envelope",
        controls: [
          { p: 25, label: "Attack", name: "Amplifier Attack",
            desc: "Time for the note to rise to full level. The rise is a straight line." },
          { p: 26, label: "Decay", name: "Amplifier Decay",
            desc: "Time to fall from full level to the sustain level. Exponential." },
          { p: 27, label: "Sustain", name: "Amplifier Sustain",
            desc: "Level held while the note is held, as a percentage of full." },
          { p: 28, label: "Release", name: "Amplifier Release",
            desc: "Time to fall to silence after the note is let go." },
        ],
      },
      {
        label: "Level",
        controls: [
          { p: 29, label: "Gain", name: "Amplifier Gain",
            desc: "Output level of the voice. Full gain reaches an amplitude of 0.75, not unity." },
          { p: 30, label: "Velocity", name: "Amplifier Velocity Sensitivity",
            desc: "How much playing harder raises the level." },
        ],
      },
    ],
  },
  {
    title: "Modulation Envelope",
    groups: [
      {
        label: "Routing",
        controls: [
          { p: 10, label: "Enable", name: "Modulation Envelope Enable", kind: "toggle", governs: "panel",
            desc: "Switches the third envelope on. It has an attack and a decay only." },
          { p: 71, label: "Destination", name: "Modulation Envelope Destination", kind: "radio",
            desc: "What this envelope moves.",
            options: ["Oscillator 2 Pitch", "FM Amount", "Pulse Width"] },
          { p: 11, label: "Amount", name: "Modulation Envelope Amount",
            desc: "How far the envelope moves its destination. Centre is no modulation." },
        ],
      },
      {
        label: "Envelope",
        controls: [
          { p: 12, label: "Attack", name: "Modulation Envelope Attack",
            desc: "Time for this envelope to rise to full." },
          { p: 13, label: "Decay", name: "Modulation Envelope Decay",
            desc: "Time for it to fall back to nothing." },
        ],
      },
    ],
  },
  {
    title: "LFO 1",
    groups: [
      {
        label: "Routing",
        controls: [
          { p: 57, label: "Enable", name: "LFO 1 Enable", kind: "toggle", governs: "panel",
            desc: "Switches the first low frequency oscillator on." },
          { p: 42, label: "Waveform", name: "LFO 1 Waveform", kind: "radio",
            desc: "Shape of the modulation. Measured order; the plugin lists these states out of order internally.",
            options: ["Sawtooth", "Triangle", "Sine", "Square", "Sample & Hold", "Random Smooth"] },
          { p: 41, label: "Destination", name: "LFO 1 Destination", kind: "radio",
            desc: "What this LFO moves. The fifth state does nothing in this build, and the seventh is undocumented.",
            options: ["Oscillator 2 Pitch", "Both Oscillator Pitches", "Filter Cutoff",
                      "Volume", "Nothing", "FM Amount", "Pan"] },
        ],
      },
      {
        label: "Motion",
        controls: [
          { p: 43, label: "Speed", name: "LFO 1 Speed",
            desc: "Modulation rate. Measured from the reference: 0.078 Hz to 125 Hz, so the top of the knob is audio rate." },
          { p: 44, label: "Depth", name: "LFO 1 Depth",
            desc: "How far it moves the destination. Full depth is five octaves of pitch, five octaves of cutoff, or silence." },
          { p: 67, label: "Tempo Sync", name: "LFO 1 Tempo Sync", kind: "toggle",
            desc: "Locks the rate to the host tempo instead of the speed knob." },
          { p: 68, label: "Key Sync", name: "LFO 1 Key Sync", kind: "toggle",
            desc: "Restarts the LFO's phase at every note." },
        ],
      },
    ],
  },
  {
    title: "LFO 2",
    groups: [
      {
        label: "Routing",
        controls: [
          { p: 58, label: "Enable", name: "LFO 2 Enable", kind: "toggle", governs: "panel",
            desc: "Switches the second low frequency oscillator on." },
          { p: 47, label: "Waveform", name: "LFO 2 Waveform", kind: "radio",
            desc: "Shape of the modulation.",
            options: ["Sawtooth", "Triangle", "Sine", "Square", "Sample & Hold", "Random Smooth"] },
          { p: 46, label: "Destination", name: "LFO 2 Destination", kind: "radio",
            desc: "What this LFO moves.",
            options: ["Oscillator 2 Pitch", "Both Oscillator Pitches", "Filter Cutoff",
                      "Volume", "Nothing", "FM Amount", "Pan"] },
        ],
      },
      {
        label: "Motion",
        controls: [
          { p: 48, label: "Speed", name: "LFO 2 Speed",
            desc: "Modulation rate, from 0.078 Hz to 125 Hz." },
          { p: 49, label: "Depth", name: "LFO 2 Depth",
            desc: "How far it moves the destination." },
          { p: 69, label: "Tempo Sync", name: "LFO 2 Tempo Sync", kind: "toggle",
            desc: "Locks the rate to the host tempo." },
          { p: 70, label: "Key Sync", name: "LFO 2 Key Sync", kind: "toggle",
            desc: "Restarts the LFO's phase at every note." },
        ],
      },
    ],
  },
  {
    title: "Delay",
    groups: [
      {
        label: "Routing",
        controls: [
          { p: 65, label: "Enable", name: "Delay Enable", kind: "toggle", governs: "panel",
            desc: "Switches the delay on." },
          { p: 82, label: "Routing", name: "Delay Routing", kind: "radio",
            desc: "How the two channels feed each other.",
            options: ["Normal Stereo", "Cross Feedback", "Ping-Pong"] },
        ],
      },
      {
        label: "Time",
        controls: [
          { p: 35, label: "Time", name: "Delay Time",
            desc: "Delay time as a division of the beat. Bracketed numbers are note values; a slash three divides that value by three, which is not the same as a musician's triplet." },
          { p: 83, label: "Spread", name: "Delay Time Spread",
            desc: "Offsets the right channel's delay from the left, in milliseconds, to widen the image." },
        ],
      },
      {
        label: "Character",
        controls: [
          { p: 36, label: "Feedback", name: "Delay Feedback",
            desc: "How much of the output is fed back in, setting how many repeats there are." },
          { p: 98, label: "Tone", name: "Delay Tone",
            desc: "Damping of the repeats, so each one comes back duller than the last." },
          { p: 37, label: "Dry / Wet", name: "Delay Dry / Wet",
            desc: "Balance between the untreated and delayed signal." },
        ],
      },
    ],
  },
  {
    title: "Chorus and Flanger",
    groups: [
      {
        label: "Routing",
        controls: [
          { p: 66, label: "Enable", name: "Chorus Enable", kind: "toggle", governs: "panel",
            desc: "Switches the chorus on." },
          { p: 64, label: "Mode", name: "Chorus Mode", kind: "radio",
            desc: "How many delayed taps are sent to each channel. The first is mono; the others widen the image.",
            options: ["Mono", "Stereo, One Tap", "Stereo, Two Taps"] },
        ],
      },
      {
        label: "Motion",
        controls: [
          { p: 52, label: "Delay Time", name: "Chorus Delay Time",
            desc: "Centre delay of the swept tap, in milliseconds. Short times with feedback make a flanger." },
          { p: 53, label: "Depth", name: "Chorus Depth",
            desc: "How far the tap is swept around that centre." },
          { p: 54, label: "Rate", name: "Chorus Rate",
            desc: "Sweep speed in hertz. It reaches 400 Hz, which is why one section serves as both chorus and flanger." },
        ],
      },
      {
        label: "Character",
        controls: [
          { p: 55, label: "Feedback", name: "Chorus Feedback",
            desc: "How much output is fed back. Negative values invert it." },
          { p: 56, label: "Level", name: "Chorus Level",
            desc: "How much of the effect is mixed into the output." },
        ],
      },
    ],
  },
  {
    title: "Effect",
    groups: [
      {
        label: "Unit",
        controls: [
          { p: 77, label: "Enable", name: "Effect Enable", kind: "toggle", governs: "panel",
            desc: "Switches the extra effect unit on." },
          { p: 78, label: "Type", name: "Effect Type", kind: "options",
            desc: "Which effect. The last four are phasers, added after the manual's table was written.",
            options: ["Attack Decay 1", "Attack Decay 2", "Decay Decay", "Decimator",
                      "Ring Modulator", "Compressor", "Phaser 1", "Phaser 2", "Phaser 3", "Phaser 4"] },
        ],
      },
      {
        label: "Settings",
        controls: [
          // The effect unit's two controls mean something different for each type,
          // so they are labelled with what they actually do rather than with their
          // position on the panel. `depends` names the parameter that decides, and
          // `variants` is indexed by that parameter's position.
          //
          // None of this is guessed. Every law is measured and written up in
          // src/dsp/effect.odin, including the one entry below that does nothing:
          // the ring modulator's second control is inert at every setting -- five
          // of them render bit-identically -- so it is labelled and disabled
          // rather than left looking operable.
          { p: 79, label: "Control 1", name: "Effect Control 1", depends: 78,
            desc: "First parameter of the selected effect; its meaning changes with the type.",
            variants: [
              { label: "Drive", name: "Distortion Drive",
                desc: "How hard the signal is pushed into the distortion." },
              { label: "Drive", name: "Distortion Drive",
                desc: "How hard the signal is pushed into the distortion." },
              { label: "Drive", name: "Distortion Drive",
                desc: "How hard the signal is pushed into the distortion." },
              { label: "Sample Rate", name: "Decimator Sample Rate",
                desc: "How long each sample is held before the next is taken, coarsening the sample rate." },
              { label: "Frequency", name: "Ring Modulator Frequency",
                desc: "Frequency of the modulating oscillator, in hertz." },
              { label: "Depth", name: "Compression Depth",
                desc: "How far the compression ratio is pushed." },
              { label: "Depth", name: "Phaser Depth",
                desc: "How far the notches sweep. At zero the notch stands still." },
              { label: "Depth", name: "Phaser Depth",
                desc: "How far the notches sweep. At zero the notch stands still." },
              { label: "Depth", name: "Phaser Depth",
                desc: "How far the notches sweep. At zero the notch stands still." },
              { label: "Depth", name: "Phaser Depth",
                desc: "How far the notches sweep. At zero the notch stands still." },
            ] },
          { p: 80, label: "Control 2", name: "Effect Control 2", depends: 78,
            desc: "Second parameter of the selected effect; its meaning changes with the type.",
            variants: [
              { label: "Tone", name: "Distortion Tone",
                desc: "Low-pass corner after the distortion. All three distortions share this one law." },
              { label: "Tone", name: "Distortion Tone",
                desc: "Low-pass corner after the distortion. All three distortions share this one law." },
              { label: "Tone", name: "Distortion Tone",
                desc: "Low-pass corner after the distortion. All three distortions share this one law." },
              { label: "Bit Depth", name: "Decimator Bit Depth",
                desc: "How many quantisation levels the signal is reduced to." },
              { label: "Unused", name: "Unused", inert: true,
                desc: "The ring modulator ignores this control. Five settings were rendered and came back bit-identical, and the manual agrees." },
              { label: "Attack", name: "Compressor Attack",
                desc: "How quickly the compressor reacts to a rise in level." },
              { label: "Rate", name: "Phaser Rate",
                desc: "Sweep speed of the notches, in hertz." },
              { label: "Rate", name: "Phaser Rate",
                desc: "Sweep speed of the notches, in hertz." },
              { label: "Rate", name: "Phaser Rate",
                desc: "Sweep speed of the notches, in hertz." },
              { label: "Rate", name: "Phaser Rate",
                desc: "Sweep speed of the notches, in hertz." },
            ] },
          { p: 81, label: "Level", name: "Effect Level",
            desc: "How much of the effect is mixed into the output." },
        ],
      },
    ],
  },
  {
    title: "Equalizer",
    groups: [
      {
        label: "Tone",
        controls: [
          { p: 60, label: "Tone", name: "Equalizer Tone",
            desc: "Overall brightness tilt applied to the output." },
        ],
      },
      {
        label: "Band",
        controls: [
          { p: 61, label: "Frequency", name: "Equalizer Frequency",
            desc: "Centre frequency of the adjustable band, in hertz." },
          { p: 62, label: "Level", name: "Equalizer Level",
            desc: "Cut or boost at that frequency, in decibels." },
          { p: 63, label: "Bandwidth", name: "Equalizer Bandwidth",
            desc: "How wide a band around that frequency is affected. Higher Q is a narrower band." },
        ],
      },
    ],
  },
  {
    title: "Arpeggiator",
    groups: [
      {
        label: "Pattern",
        controls: [
          { p: 59, label: "Enable", name: "Arpeggiator Enable", kind: "toggle", governs: "panel",
            desc: "Plays held notes one at a time in a pattern." },
          { p: 31, label: "Pattern", name: "Arpeggiator Pattern", kind: "radio",
            desc: "Order the held notes are played in.",
            options: ["Up and Down", "Up", "Down", "Random"] },
          { p: 32, label: "Range", name: "Arpeggiator Octave Range", kind: "radio",
            desc: "How many octaves the pattern spans before repeating.",
            options: ["1 Octave", "2 Octaves", "3 Octaves", "4 Octaves"] },
        ],
      },
      {
        label: "Timing",
        controls: [
          { p: 33, label: "Rate", name: "Arpeggiator Rate",
            desc: "Step length as a division of the beat." },
          { p: 34, label: "Gate", name: "Arpeggiator Gate",
            desc: "How much of each step the note sounds for." },
        ],
      },
    ],
  },
  {
    title: "Voice",
    groups: [
      {
        label: "Playing",
        controls: [
          { p: 38, label: "Play Mode", name: "Play Mode", kind: "radio",
            desc: "How overlapping notes behave.",
            options: ["Polyphonic", "Monophonic", "Legato"] },
          { p: 94, label: "Polyphony", name: "Polyphony", kind: "stepper",
            desc: "Maximum number of notes sounding at once." },
        ],
      },
      {
        label: "Portamento",
        controls: [
          { p: 39, label: "Time", name: "Portamento Time",
            desc: "Time taken to glide from one note's pitch to the next." },
          { p: 74, label: "Automatic", name: "Portamento Automatic", kind: "toggle",
            desc: "Glides only between notes that overlap, rather than every note." },
        ],
      },
      {
        label: "Unison",
        controls: [
          { p: 73, label: "Enable", name: "Unison Enable", kind: "toggle", governs: "group",
            desc: "Stacks detuned copies of the whole oscillator section on every note." },
          { p: 93, label: "Voices", name: "Unison Voices", kind: "stepper",
            desc: "How many copies are stacked." },
          { p: 75, label: "Detune", name: "Unison Detune",
            desc: "How far the copies are spread apart in pitch, in cents." },
          { p: 84, label: "Pan Spread", name: "Unison Pan Spread",
            desc: "How far the copies are spread across the stereo image." },
          { p: 85, label: "Pitch", name: "Unison Pitch",
            desc: "Pitch offset applied across the stack." },
          { p: 92, label: "Phase", name: "Unison Phase",
            desc: "Spreads the copies' start phases. Only effective when the oscillator phase is fixed." },
        ],
      },
    ],
  },
];
