# What the author of Synth1 documented

Primary-source notes from Daichi Kanenaga's site, <https://daichilab.sakura.ne.jp/>,
recorded here because several of them settle questions this project had been
guessing at, and because a couple contradict the English readme in `docs/`.

Sources:

- `synthprog/` — "シンセプログラミング" (Synth Programming), 2006-05. His own
  write-up of Synth1's internal structure, with code.
- `softsynth/synmanu/readme.html` — the Japanese manual for v1.13 (2014-07-10),
  the same version as the binary under `ext/synth1/`.
- `softsynth/synmanu/readmeeng.html` — the English manual, already vendored as
  `docs/synth1-readme-eng.txt`.
- `vstisample/` — a VSTi synth template with source, `MySynthSrc.zip`.

Where the Japanese and English manuals disagree, both are noted rather than one
being picked. They are both official.

## Settled: FM runs from oscillator 2 into oscillator 1

Two independent statements, both from the author:

- The manual, on the FM knob: oscillator 2 is the modulator and oscillator 1 is
  the carrier, and FM is only active when ring modulation is off.
- The Synth Programming write-up gives the phase update directly, on a
  2048-entry table with 16:16 fixed-point phase:

      osc1_phase += osc1_delta + (osc2_out * fmAmount * 2048/2)

This project had implemented the opposite direction, on the strength of a run
objective that said "FM from oscillator 1", with a comment in
`src/engine/voice.odin` noting that the readme disagreed and that the oracle
slice should settle it. It is settled, and the code now follows the reference.

Two details beyond the direction:

- The displacement is **accumulated into the running phase**, not applied to a
  copy of it. That is frequency modulation — the phase carries the integral of
  the modulator — where a phase-modulation formulation would displace the phase
  transiently. `dsp.oscillator_advance_modulated` accumulates.
- Full amount is half a cycle of displacement, `2048/2` on a 2048-entry table.
  The scaling this project already used, 0.5 turns, was right.

The author's signal loop also generates both oscillator outputs **before**
advancing either phase, so a hard-sync reset lands on the following sample.
`voice_process` now reads oscillator 2 before the sync reset for that reason.

## Settled: the oscillator is a wavetable, not a band-limited step

Synth1 does not use BLIT or PolyBLEP. The author is explicit that he had not
heard of BLIT when he started and avoided it later as too heavy:

- **Wavetable with linear interpolation**, 2048 samples per table, `float`.
- **Multiple tables per waveform, selected by frequency**, each holding only the
  harmonics that fit below Nyquist for that band. He notes that doing this
  rigorously across the whole range would need hundreds of tables, and that
  because aliasing is most audible on high notes he gets away with a few dozen.
- **Sine** needs one table, having no harmonics.
- **Pulse has no table of its own**: it is the difference of two saw waves offset
  in time, and the offset is the pulse width.
- **Noise** is not a table: an M-sequence of period 2^24 − 1.
- Phase is a 16:16 fixed-point integer, so wrapping is a mask.

This project uses PolyBLEP saw and pulse and an xorshift32 noise source. That is
a different anti-aliasing strategy with a different residue, and the pulse in
particular is a different construction — two offset saws are not a naive pulse
with two corrections applied.

## Settled by measurement: the oscillator waveform states

`s1probe waveprobe` renders each waveform state alone through an open filter and
reads its harmonic series. The series name the waveform without ambiguity, and
they say the listing order in both manuals is **not** the state order:

| state | h2 | h3 | h4 | h5 | width? | waveform |
|---|---|---|---|---|---|---|
| osc1 0 | – | – | – | – | 0.0 | sine |
| osc1 1 | −6.0 | −9.5 | −12.1 | −14.0 | 0.0 | **saw** (1/n exactly) |
| osc1 2 | −3.1 | −9.8 | −41.3 | −13.8 | 39.9 | **pulse** |
| osc1 3 | – | −19.1 | – | −28.0 | 0.0 | **triangle** (1/n² odd only) |

Oscillator 2's states 1..4 carry the same three waveforms in the same order plus
noise. So the real order is **sine, saw, pulse, triangle**, against the manuals'
"sine, triangle, saw, pulse": three of the four states were bound to the wrong
waveform, on both oscillators.

The "width?" column is how far the harmonic series moved when the pulse width
knob was changed. It is what makes state 2 certain rather than merely likely, and
it is also how the error surfaced: the LFO probe changed the width by 110 steps
and got a **bit-identical render**, which a pulse wave cannot do.

This is the same trap parameters 42 and 47 already carry a warning about — the
manual lists the waveforms in a tidy order the plugin does not use.

## Settled by measurement: the LFO destinations

`s1probe lfoprobe` drives each of the seven states at full depth in four
configurations and compares every render against the same patch with the LFO
switched off, so "this destination does nothing" is distinguishable from "these
metrics cannot see it".

| state | evidence | destination |
|---|---|---|
| 1 | only oscillator 2's render changes | oscillator 2 pitch |
| 2 | both oscillators move, ~10100 cents | **both pitches** |
| 3 | changes only while the filter has room; bit-identical with the cutoff open | filter cutoff |
| 4 | 27 dB of level swing, no pitch, no timbre | volume |
| 5 | **bit-identical to the LFO being off**, every configuration, every width | **nothing at all** |
| 6 | only oscillator 1, and it changes for a sine carrier too | FM amount |
| 7 | the stereo image swings the full width | **pan** |

So the English manual's five destinations are wrong about the order, the Japanese
manual's six are right about the set except that its fifth — pulse width — is
**inert in v1.13 beta 3**, and the seventh, pan, is undocumented in both.

## Settled by measurement: the LFO waveform states

`s1probe lfoshape` points each LFO at the stereo position, folds the resulting
series into one cycle at a period taken from its own autocorrelation, and matches
that against the deterministic candidates over every phase alignment. Parameters
42 and 47 both measure the same.

| stored | display | position | waveform | evidence |
|---|---|---|---|---|
| 0 | "0" | 0 | **saw**, descending | repeats at 1.000, one discontinuity per cycle |
| 1 | "1" | 1 | **triangle** | 0.993 against the template |
| 2 | "5" | 2 | **square** | 0.967, two levels |
| 3 | "2" | 3 | **sample & hold** | does not repeat; steps a quarter of its range at once |
| 4 | "3" | 4 | **random, smoothed** | does not repeat; never moves a hundredth of its range in a frame |
| 5 | "4" | 5 | **sine** | 0.991 |

So the English readme's list — "saw, triangle, sine, square, random(sample &
hold) or random (smoothed)" — is **right**, and it indexes the state's *position*.

This is the opposite of the trap parameters 0, 1, 41 and 46 carry, and worth
recording as such. Those two parameters display their six states out of order, as
0, 1, 5, 2, 3, 4, and this project read that as a display carrying the waveform's
identity where the position had lost it. It does not: reading the identifier bound
four of the six states to the wrong shape, both random ones and the square among
them. An odd-looking display invites a story, and a story is not a measurement.

The saw's direction is measured separately, through the volume destination rather
than pan, because a sign flip of the LFO cannot be told from a sign flip of the
destination it drives and only loudness has an absolute sense. It descends.

## Settled by measurement: how far the LFO moves the pitch

`s1probe lfopitch` uses the square state above to hold the pitch still at two
values instead of sweeping it, which is what makes this measurable at all.

- **Full depth is exactly five octaves either way.** The played note times 32.00
  at notes 36, 48 and 60 — 2093.09, 4186.07 and 8371.94 Hz. It does not depend on
  the note, and the previous record in this project that it did was an artefact of
  tracking a swept tone with a window whose resolution in cents is five times
  coarser at C2 than at C5.
- **The law is symmetric**: the up and down excursions agree within 0.03
  semitones wherever both are inside the analysis range.
- **The depth knob is exponential**, fitting `(exp(2.3u) - 1)/(exp(2.3) - 1)` to
  within 0.1 semitone of 60 across twenty settings.

It is *not* the amplitude curve that parameters 27 and 29 share, though it is
close enough to have been mistaken for it — the two agree to three decimals at
stored 64 and differ by 31% at stored 8.

## Settled by measurement: the other three LFO depths

`s1probe lfosquare` points the same square at the cutoff, the volume and the pan.
The question it was built to answer — whether one depth curve drives every
destination — has a clear answer: **no**. All four differ, and two of the four are
not even bipolar.

| destination | polarity | curve in the knob | full depth |
|---|---|---|---|
| pitch | bipolar, symmetric | exponential, `(e^2.3u−1)/(e^2.3−1)` | ±60 semitones |
| cutoff | **upward only** | linear in octaves | +5.06 octaves |
| volume | **downward only** | linear in amplitude | silence |
| pan | bipolar, symmetric | steeply concave | hard left/right |
| FM | **upward only** | linear, scaled by `1 − knob` | maximum FM |

The FM row is measured the same way, against parameter 45 rather than against a
physical unit: an FM index is not something a spectrum reports, but one setting of
parameter 45 is distinguishable from another, and that is all the measurement needs.
Its full-depth behaviour is to drive the FM amount to maximum **from wherever the
knob was left**, so the depth scales the headroom rather than a fixed range.

- **The cutoff never closes the filter.** The low half of the square sits on the
  unmodulated corner at every depth, and still does with the base moved from
  585 Hz to 7 kHz. This retroactively explains `lfoprobe`'s observation that the
  cutoff destination goes bit-identical with the filter wide open, which a bipolar
  modulation could not do.
- **The volume ducks to silence** at full depth, and the fraction of *amplitude*
  removed is the knob position to three decimals. There is no decibel constant.
- **The pan reaches a fully hard image**, not the 0.927 previously recorded, and
  its curve is concave where the pitch's is convex.

The cutoff needed a different instrument from the rest of the filter work: the
−3 dB corner every other measurement here uses is a crossing, and is far too noisy
to survive being split into two levels. A spectral centroid, calibrated against the
reference's own static cutoff sweep and inverted through it, is smooth enough.

## Contradiction resolved: the fourth filter type

- English manual: "low-pass (12 dB), low-pass (24 dB), high-pass (12 dB) or
  high-pass (24 dB)".
- Japanese manual, same version: ローパス(12db)、ローパス(24db)、ハイパス(12db)、
  **バンドパス(12db)** — low-pass 12, low-pass 24, high-pass 12, **band-pass 12**.

`s1probe filterprobe` settles it: **the Japanese manual is right.** Driving noise
through each state and fitting the response against a wide-open render gives

```
state   -3dB band Hz     low slope    high slope   response
  0          21-538             -       -12.2      low pass, 12 dB/oct (2-pole)
  1          21-240             -       -25.5      low pass, 24 dB/oct (4-pole)
  2       479-15343         +12.0           -      high pass, 12 dB/oct (2-pole)
  3         339-761          +6.2        -5.5      BAND PASS
  4           21-60             -       -14.3      low pass, ~13 dB/oct  (LPDL)
```

State 3's pass band is bounded at **both** ends and tracks the cutoff knob — at a
higher setting it moves to 1356–3417 Hz — while the real high pass at state 2
passes everything from its corner to the top of the range. Two poles, so ±6 dB
per octave: the manual's "band pass (12 dB)" and this measurement are the same
filter described two ways.

Note also that state 4, `LPDL`, measures 12–14 dB per octave with a corner far
below the others' for the same knob setting. The changelog calls it close to
LP24; by slope it is closer to LP12. It stays bound to LP24 pending a ladder
model, and the discrepancy is recorded here rather than hidden.

The fifth state is `LPDL`, added in v1.13 beta 2 and described in the changelog
as close to LP24; the current binding maps it to the 24 dB low pass.

Note also that Synth1 has **no notch filter** and no 24 dB band pass or high
pass. `src/dsp` implements notch and a 24 dB slope for all four responses, which
the contract for that slice required, but no reference filter-type state reaches
them.

## Contradiction: how many LFO destinations

- English manual: five — oscillator 2 pitch, filter cutoff, volume, oscillator 2
  pulse width, FM.
- Japanese manual: six — オシレータ２のピッチ, **オシレータ１と２のピッチ**,
  フィルタのカットオフ周波数, 音量, オシレータ１と２のパルス幅, ＦＭ変調量.
  That is: osc 2 pitch, **both oscillators' pitch**, cutoff, volume, **both
  oscillators'** pulse width, FM amount.
- Measured: parameters 41 and 46 have **seven** states.

So the newer Japanese manual adds a destination the English one omits — pitch of
*both* oscillators — and one state is still undocumented in either.

`src/engine/params.odin` guesses states 6 and 7 as oscillator 1 pitch and pan,
and says so. The Japanese manual suggests the second destination is "both
oscillators' pitch" rather than "oscillator 1 pitch", and offers nothing that
looks like pan. Its listing order also differs from the order this project
assumed. None of that is conclusive — prose order need not be state order — so
the honest next step is the same as for the filter: drive each state with a deep,
slow LFO and observe which quantity moves.

The Japanese manual also confirms that the pulse-width destination affects
**both** oscillators, which matches what `voice_process` does.

## Settled by the changelog: the undocumented effect types, and the delay's

Two questions that the manual's own reference tables could not answer were
answered by its version history instead. Worth noting as a habit: where this
project has found the manual stale, the changelog has usually been right.

**Parameter 78 has ten states and the manual names six.** The type table lists
`a.d.1`, `a.d.2`, `d.d.`, `deci.`, `r.m.` and `comp.` and stops. The v1.07 entry
adds `Phaserの追加` — a phaser — and the table was never revised. The plugin's LCD
reads `a.d.1 a.d.2 d.d. deci. r.m. comp. ph1 ph2 ph3 ph4`, so the last four are
phaser variants; `docs/null-test.md` records the probe that corroborates each name
independently, which mattered because the state order of parameters 0, 1, 41, 42,
46 and 47 all disagree with the order their documentation lists.

**Parameter 82's three delay states.** The v1.07 alpha entry spells them out:
`ノーマルステレオ(ST)、クロスフィードバック(X)、ピンポン(PP)`. Normal stereo, cross
feedback, ping-pong, in that order — so state 1 is the cross-fed one, which
confirms what `binding.odin` had been guessing, and state 2 is ping-pong.

The same entry is also where the delay's stereo behaviour and its `spread`
parameter arrive, and where the old `level` knob is replaced by a dry/wet balance
— which is why parameter 37 reads out as a percentage.

## Smaller confirmations

- Ring modulation is `osc2_out *= osc1_out`, and it takes precedence over FM.
- Hard sync makes oscillator 1 the master and resets oscillator 2.
- Pulse width and the `tune` fine-tune both apply to oscillators 1 and 2.
- Filter keyboard tracking: fully right is one octave of cutoff per octave of
  note, fully left is no change — the linear 0..1 reading already used.
- The modulation envelope's destinations are oscillator 2 pitch, FM amount and
  pulse width, as already bound.
- Synth1 is modelled on the **Clavia Nord Lead 2**, which is the reference for
  the filter's character and for the general architecture. A `nordlead2.ccm`
  ships in `ext/synth1/Synth1/settings/`.

## The sample source, and licensing

`vstisample/MySynthSrc.zip` is a VSTi template by the same author containing a
wavetable oscillator with per-band anti-aliasing — the same technique as Synth1 —
plus unison detune and stereo spread. It has no filter, envelope or LFO.

He grants it explicitly: free to use commercially or non-commercially, with no
warranty. That is a real grant and worth recording, but it is a grant to *his
sample*, not to Synth1 itself. Anything taken from it should be attributed here,
and nothing in this repository has been taken from it so far — the findings above
are documented facts and techniques, which is a different thing from copied
expression.
