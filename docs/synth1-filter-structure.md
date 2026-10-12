# The reference's filter section, and what this engine does about it

Facts about `Synth1 VST64.dll` (SHA-256
`51c6fe60d767c78f5a15b7023173ac5709edbcf03a55cbac9032569ba22f32c7`) that the
black-box probes could not reach, each with what was done about it and the
numbers that decided it. "Observed" means read from the plugin's own code or
data; "inferred" is a reading of observed structure.

## Cutoff

The corner is a position on a 1024-step exponential axis, `15 Hz *
(16000/15)^(i/1024)`, one step about 12 cents. The knob is `trunc(state/127 *
1023)`. Everything that moves the corner moves that position and only the sum is
turned into a frequency.

- **Keyboard tracking** is `(1 + a)^((note - 48) / 12)`: stored 64 is 0.585 octaves
  per octave, not 0.504. The result is held to the ends of the axis, so at high
  notes the corner stops (15343 Hz at note 84 and 96, cutoff 90, full tracking).
- **Envelope amount** is held to the room the knob and tracking leave on each
  side, then the envelope level takes its fraction of what survives.
- **LFO** takes `m/1024` of the room left above the position, applied last, so
  depth is a fraction of the travel and not a number of octaves. Bases 32 and 88
  at depth 32 open 23.8 and 9.8 states against 23.9 and 9.8 predicted.
- **Ramp**: an edit of knob, envelope amount or tracking takes `sample_rate/20`
  samples (50 ms), linear in position, from wherever the position is, toward the
  current target.

Done: `src/engine/cutoff.odin`.

## Two-pole types (0, 2, 3)

A Chamberlin section stepped twice per sample, step `2 sin(pi fc / (2 sr))`,
damping `1 - resonance`, input trim `1 - 0.7 resonance`, output held to +/-20
above a resonance of 0.9; the taps are the second low-pass state, the high-pass
node and the band-pass state. Resonance is `state/127` and nothing else.
`s1probe arch filtertype --values 64,<r>` agrees to 0.1 dB at every octave at
resonance 0, 40, 80 and 110. The measured corner, damping, output-gain and
saturation-level tables for this section are no longer used.

Done: `src/dsp/chamberlin.odin`.

## Type 4 ("LPDL")

A zero-delay-feedback four-stage ladder in double precision with a Pade tanh
`x(x^2 + 27)/(9x^2 + 27)` clipped beyond +/-3 on the summed input, a 120 Hz
one-pole in the loop, feedback `15 * resonance`, output gain `1 + 3 *
resonance`, run twice per sample (input on the first step only) up to 48 kHz.
Within 0.3 to 0.8 dB of the reference across the resonance knob.

Done: `src/dsp/diodeladder.odin`.

## 24 dB low pass (type 1)

A four-stage cascade of one-poles with the held output fed back:
`newest = x - r*y4; y1 = (newest + previous newest)*p - y1*k`, and likewise down
the stages, with `f = 2 fc / sr`, `k = 3.6 f - 1.6 f^2 - 1`, `p = (k + 1)/2` and
`r = resonance * exp((1 - 0.5 (4.3 f - 2.5 f^2)) * 1.386249)`. The three
coefficients are smoothed per sample, 98% of a step in a millisecond, and the
output is held to +/-20 above a resonance of 0.9. Identical to the reference to
0.1 dB at every octave at resonance 0, 64 and 107. No resonance, corner or level
table is involved.

Done: `src/dsp/moogladder.odin`.

## Resonance saturator

`x(1 + d)/(1 + d|x|)`, after the filter, for every type. This was already what
`filter_saturate` does.

## Equaliser

- **Peak**: a matched pole-zero design. Damping `1/2Q` (denominator) and `G/2Q`
  (numerator), swapped for a cut, each mapped through `z = exp(sT)`; the numerator
  scaled so the gain at the centre is exactly `G`. The controls are the stored-state
  formulas: frequency `50 Hz * 320^(s/127)`, level `(s - 64)/127 * 50` dB, `Q =
  10^(s/127)` (1 to 10).
- **Tone**: a first-order low pass up to the centre at `200 Hz * 110^(s/64)` and a
  high pass above at `10 Hz * 800^((s - 64)/64)`, bilinear with the corner entered
  as `2 pi f` and not pre-warped. The equaliser's tone is a 22 kHz low pass at its
  centre (1.1 dB down at 10 kHz at 48 kHz), not a bypass. The delay's tone is the
  same pair on `/63` and `(s - 65)/62` travel and is bypassed at 64.

`s1probe arch tone`: all nine states at all nine frequencies identical to the
reference. `s1probe arch eq`: peak level, frequency and width identical at every Q.

Done: `src/dsp/equalizer.odin`, `src/engine/binding.odin`.

## Output

The reference has no output limiter. The engine's soft clip stays as a bound for
hosts but its knee is now 256 (+48.2 dBFS), above everything the reference has been
measured producing (+41.2 dBFS), so `arch clip` agrees with it on every case.

## Stereo position

Three sources, each with its own pair of gains, **multiplied**: the unison stack's,
the static knob's, and an LFO's. The first two are `min(1, 1 -/+ p)`; the LFO's is a
cubic of `x = value * depth` (near channel `1.5 + 0.5 (x - 1)^3`, far channel
`(1 + x)^3`) with a 2 ms half-life smoothing. `arch pan`: every static, LFO and
composed cell within 0.003 of the reference.

Done: `src/engine/pan.odin`.

## LFO

Two LFOs, held by the engine and shared by every voice. A key-synced one restarts
when the key just pressed is the only key held, not when a voice starts. Free
running the rate is `1500^(s/127) / 12` Hz (0.083 to 125 Hz); the table it
replaced was a staircase of crossing counts and sat up to 1.7% low, which was the
free-running drift the phase probe could not explain. Tempo sync picks from thirty
divisions, `(s * 30) >> 7`, each a whole number of 24ths of a beat. The period is
a whole number of samples (`sr / hz`), the output is refreshed every 64 samples
from the cycle's start (32 above 10 Hz) and held, and the amplitude destination
alone hears it ramped linearly across each step. Smoothed random ramps linearly
between its last two draws across a cycle. `arch lfophase`: free-running phase
differences within 0.01 turns; `arch rate`: spikes at spacing 64 in both.

Done: `src/dsp/lfo.odin`, `src/engine/engine.odin`, `src/engine/binding.odin`.

## Voice pool

The pool is counted in layers: polyphony is the number of voices, held as slots, and
a note takes one per unison layer. A layer takes the first slot not held by a key,
scanning round-robin from the slot after the last one handed out, so a note in
release (or a voice that has finished) is free the moment the scan reaches it; when
every slot is held the oldest is taken. A note wanting more layers than there are
slots keeps only its last ones. `arch voices`: layers per note equal to the
reference in all 15 readable cases. That probe has no release in it; the release
behaviour is read from the allocator, which returns the first voice whose key flag
is clear, and is held by tests.

Done: `src/engine/engine.odin`, `src/engine/voice.odin`.

## Amplitude envelope

The reference renders in chunks of at most 256 frames, restarting at every host
block and note event, and its amplitude envelope is a whole number of 1/2048ths
joined by straight lines with the chunk's edges as the joins. The engine keeps a
chunk clock (restarting at every call and at every arpeggiator step that starts a
note); each voice steps a copy of its amplitude envelope to the chunk's last sample,
floors it to a whole step and ramps to it. A note's first chunk follows the
envelope exactly. The filter and modulation envelopes are read per sample: reading
them per chunk (end value or start value) made the deepest nulls up to 6 dB worse.
`arch rate`, envelope row: 117 spikes against the reference's 171, was 738. Patches
114, 107 and 013 went from 9-15 dB out on spectrum to 1.3-2.2 dB.

Done: `src/engine/engine.odin`, `src/engine/voice.odin`.

## Removed

The measured corner, damping, output-gain and ladder tables, the interpolation and
blends that sampled them, the state variable section and ladder they were fitted to,
and the probes that generated them. Every filter takes the cutoff position and the
resonance knob as they are.

## Results

Factory bank, 128 patches, spectral error mean in dB, by the bank's own per-row
means: 4.28 at the start of the series, 3.61 after the cutoff axis, 3.53 after the
two-pole section, 3.31 after the 24 dB ladder, 3.27 after the equaliser, 3.15 after
the LFO, 2.89 after the envelope chunks; the pan, voice pool and clean-up commits do
not move it, because the bank plays one note at a time and uses few pan LFOs. The
null depth went from -8.58 to -9.27 dB over the same commits. 26 factory patches
switched to type 4: 7.36 -> 5.05 dB. Patch 113 is a very short hat, so its envelope
error is read over few samples; it went 3.58 -> 3.25 dB and is not pursued further.

## Not yet done

- **Modulation held per render block**: the amplitude envelope, the LFOs' grid and
  the amplifier's ramp are copied. The filter and modulation envelopes, read per
  chunk, made the deepest nulls worse, so they stay per sample; what the reference
  does with them inside a chunk is not settled, and the probes read it only through
  those nulls.
- **Release in the voice-count probe**: `arch voices` holds every note until the end,
  so the slot rule for a note in release rests on the allocator's logic and the
  tests, not on a measurement of the reference.
