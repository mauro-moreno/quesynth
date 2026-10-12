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

## Resonance saturator

`x(1 + d)/(1 + d|x|)`, after the filter, for every type. This was already what
`filter_saturate` does.

## Results

Factory bank, 128 patches, spectral error mean (dB), by the bank's own per-row
means: 4.28 -> 3.61 (cutoff axis) -> 3.53 (two-pole section); 91 patches
closer and 23 further over the two. 26 factory patches switched to type 4:
7.36 -> 5.05 dB. The patches that got further are small moves on patches that
carry large unrelated error; patch 113's envelope contour (1.31 -> 3.08 dB) is
not explained.

## Not yet done

- **24 dB ladder** (type 1): the reference's is a four-stage ladder with the
  stage coefficient `3.6 f - 1.6 f^2 - 1` and the same +/-20 clamp. The engine's
  ladder agrees with it to 0.2 dB at resonance 0 but still runs on measured
  surfaces indexed by state.
- **Output**: the reference has no output limiter and renders in blocks of at
  most 256 frames, 32 in some modes; this engine soft-clips above +30 dBFS by
  design.
- **Equaliser peak**: not the plain bilinear peaking form, which is why a fitted
  Q left 0.31 dB of residual; the exact law is not extracted.
- **Pan composition, LFO ownership, the 64-sample LFO grid, voice allocation**:
  not traced.
