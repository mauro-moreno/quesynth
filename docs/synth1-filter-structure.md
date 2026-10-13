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

## Chorus

Two lines, one per channel, each holding its channel's input times the level; the wet
that comes out is already at its level and the feedback carries it. One quadrature
oscillator, stepped `s -= k c; c += k s` with `k = 2 sin(pi f / sr)`, starting at
(0, 0.9999) and restarted at a block's start if the cosine has risen above 0.9999. A tap
is read `delay - excursion * osc` behind the newest sample, so the sine side sweeps
longer first and the cosine side shorter first: the left channel's sweep runs on the
sine and the right's on the cosine, which is the opposite sign of the right channel the
engine used to have. The delay is a whole number of samples, the excursion is a whole
number of samples (the delay times the depth, truncated) and is cut back to
`period / 2 pi` so a tap never moves faster than a sample per sample: a 400 Hz sweep at
full depth on 30 ms is 19 samples wide. Parameter 64 picks the taps:

- 1: each channel reads its *own* line at the sine's position (the engine read the left
  line into both);
- 2: left at the sine's position, right at the cosine's;
- 4: the sine's and cosine's positions and each one's mirror about the centre, four taps
  mixed into both channels, `L = .9 Ln + .1 Lf + .7 Rn + .3 Rf`, `R = .1 Ln + .9 Lf +
  .3 Rn + .7 Rf`. Feedback comes from the near taps only.

The laws behind the displays: delay `0.05 * 300 ^ ((2u) ^ 0.6)` ms below the middle of
the knob and `30 u` ms from it up, rate `0.02 * 20000 ^ u` Hz (stored 0 plays its
displayed 0.01), depth `(100 ^ u - 1) / 99` of the delay, feedback `(s - 64) / 64 *
0.99`, level `u`. All 127 delay and rate displays equal them. The engine's fitted depth
exponent was 4.65 where the law is ln 100 = 4.605.

`s1probe arch chorus` renders a source with the section on and off in both engines and
cancels the wets against each other. Before: right channel of types 1 and 2 +3 to +4 dB
(worse than no cancellation), type 4 -1 to -5 dB and 4 to 6 dB too quiet. After, every
case (three types, depth, rate, delay, level, feedback, flanger, fast and deep) is at the
floor the two dry sources set (-31 dB on two unison sines) with levels within 0.1 dB.
The one exception is feedback of -99%, whose first second carries the engines' known
onset difference round a loop of gain 0.99; it is at the floor from 0.65 s on at -94%.

Factory bank: null depth -9.27 to -13.62 dB (91 patches closer, 5 further; the patches
that sat near -12 dB went to about -31), envelope error 1.61 to 1.42, spectral 2.87 to
2.84.

Done: `src/dsp/chorus.odin`, `src/engine/binding.odin`.

## Oscillator timing and note start

Every oscillator is read and then advanced, so a note's first sample is its start
phase's value and a sine begins at exactly zero. The engine advanced first and so ran
one sample ahead at every pitch; it also carried a start phase of -0.00125 turns that
an earlier probe had read as a constant, which is one sample at 60 Hz (60 / 48000).
Across nine notes the reference trails the old engine by `1 - 59.1 / f` samples,
which is one sample less that constant's phase. Dry sine against the reference now
nulls to -56 dB at note 60 and -82 dB at note 84 (-44 and -57 before); two detuned
saws to -41 dB (-17), one panned saw to -31 dB (-16).

A note's level on its first sample is not an envelope shape. The amplitude attack is
`0.0005 * 56000 ^ (v / 127)` seconds, a linear ramp, from half a millisecond at stored
0, and the filter envelope's attack is the same law. The table both used before floors
at 3.5 ms because of the next point, so it was reading the engine's gain smoother and
not an attack. The engine's gain smoother (half-life 1 ms, `tau` 69 samples) starts at
zero on a fresh engine and takes the first note after a load up with it, as the
reference's does; a second note, on the same voice or another, reaches full level on
its own ramp alone. Measured as a sine's envelope: the first note's 10 / 50 / 90 %
times at stored 0 are 9 / 48 / 162 samples in both engines, and a second note is the
same sample for sample. A per-note factor of `1 - exp(-n / 69)`, which the older
evidence tried and set aside, made later notes 60% quiet at sample 160 for exactly
this reason.

## Pitch edits and the wheel

Oscillator 2's pitch (parameter 2) slides linearly to a new value over fifty
milliseconds whatever the size of the edit: 39.9 ms from 10 to 90% for twelve semitones,
39.7 for three. Key shift, fine tune and master tune do not slide; they move at once.
The wheel moves at a fixed rate in wheel units, about 23.75 full scales a second (a full
travel in 42 ms), so the time to bend is the same 33.6 ms from 10 to 90% at a range of
2, 12 and 24 semitones and scales with the distance the wheel moves (17.4 ms for half a
travel, 8.6 for a quarter). `s1probe arch ramp` against the reference, up and down:
profiles within 0.02 at every 5 ms offset, 10 to 90% times within 0.5 ms.

## Modulation and filter envelopes

Both follow the amplitude envelope's laws, read from their own traces and not assumed:
a linear attack of `0.0005 * 56000 ^ (v / 127)` seconds, a decay and release that are
`exp(-8u) * (1 - u)` over `0.01 * 6000 ^ (v / 127)` seconds, and a sustain level for
the filter envelope that is linear in the knob.

`s1probe arch modenv` reads oscillator 2's pitch above an envelope-off render, with
the modulation envelope on pitch. Given only the attack and decay lengths the law
predicts 28.5 semitones at 150 ms and 5.59 at one second for attack 64, decay 90 and
amount 96, and the reference reads 28.97 and 5.59. The reach is **60 semitones** at full
amount and linear in the amount: 0.94 semitones a step of parameter 11 at the
envelope's peak, 7.20, 14.42 and 28.97 semitones at amounts 72, 80 and 96. The engine
had 24, "two octaves", and an exponential decay, so it was 2.5 times too shallow and fell
away slightly too fast. Now within 1% at attack 0, 20, 40, 64 and 90 and decay 50 to 110.

`s1probe arch filterenv` reads a sine two octaves above the low pass's corner in dB
over time. Attack 64, decay 90: reference and engine agree to 0.1 dB from 100 ms to
3.4 s (the one-pole decay was 0.5 dB low by 600 ms); with sustain 40 and with a
110 decay and sustain 60 the same.

Factory bank, 128 patches, from the pitch slides: null depth -14.34 -> -16.72 dB
(65 patches closer, 24 further), envelope error 1.37 -> 1.21 dB, spectral 2.75 -> 2.56
dB. Patches 033, 108, 016 and 027 go from about -5 dB to between -25 and -32 dB.

### The filter envelope's early milliseconds

The first milliseconds of the filter envelope agree where they can be read. A cutoff held
constant from the first sample, an instant attack and full sustain, nulls to 0.00 dB at
every time (the filter's own startup is exact). A sine near the corner follows the
cutoff's rise to within 0.1 dB from 2 ms onward in both engines. The one place they
differ is a sine six octaves above the corner, where the level is a residual about 60
dB under the passband and a 6 dB difference at 10 ms is the startup transient beating
against it. Reading the envelope the way the amplitude is read (knots of 1/2048 with
straight lines between chunk ends) was the closest candidate and made the bank worse
(null depth -16.72 to -15.26 dB, 66 patches further), and reading it once per chunk, at
the chunk's start or its end, was worse on the traces; the filter envelope stays per
sample.

### Its other two destinations

`s1probe arch modenvscale` reads FM and pulse width as the static setting of the same
parameter that cancels against the enveloped render, in each engine against itself,
with the envelope held near its peak (instant attack, longest decay).

FM: the scale of 1.0 was right. At amounts 80 and 96 the equivalent static values are 31
and 62 in the reference and 31 and 61 in the engine, a quarter and a half of the
knob's 127. At full amount FM stops being monotonic and nothing nulls in either engine.

Pulse width was wrong, and was not an offset. The envelope moves the duty a share of the
way to the end it is heading for: `d' = d + m (1 - d)` for a positive amount `m` and
`d' = d + m d` for a negative one, `d` the knob's duty (0 to 0.5) and `m` the amount
times the envelope. From a base of 32 the reference's equivalent is 58, 72, 98 and 112
at amounts 72, 76, 84 and 88 (a constant 213 steps per unit); from 96 it is 85, 73 and 50
at 56, 48 and 32 (91 per unit, shrinking with the base); from 64 the two directions
differ threefold. The engine added a constant 0.45 and read 60 and 54 where the reference
read 85 and 61. The law reproduces all thirteen readings within two steps of the knob.
Four of them are bit-identical renders in the reference (-324 dB null), so the match is
exact where the knob can resolve it.

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
  does with them inside a chunk is not settled.
- **Release in the voice-count probe**: `arch voices` holds every note until the end,
  so the slot rule for a note in release rests on the allocator's logic and the
  tests, not on a measurement of the reference.
- **Chorus at feedback -99% and at the fastest, deepest sweeps** agrees with the
  reference to -25 and -42 dB where the dry source nulls to -56: the loop's gain of
  0.99 amplifies any difference a hundredfold, and no cause has been found for the
  rest.
