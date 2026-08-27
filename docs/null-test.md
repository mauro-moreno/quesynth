# The null test

`s1probe compare` renders the same `.sy1` patch through the reference Synth1
binary and through `src/engine` under conditions that are identical by
construction, and reports how far apart they are.

This is the oracle `docs/architecture.md` describes. Before it existed, every
acceptance gate in the project asserted only that the engine produced *a* sound
(`peak > 0.0001`) — a test the engine passes while being wrong about every
design decision it had to guess.

## Running it

```
odin build tools/s1probe -out:build/s1probe.exe
build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv build/nulltest.csv
build/s1probe.exe summarise build/nulltest.csv
```

Start with the control run, which compares the reference against a second render
of itself:

```
build/s1probe.exe compare ext/synth1/Synth1/soundbank00/001.sy1 --self --verbose
```

It must report zero on every metric. If it does not, the harness is measuring
itself and no other number in this document means anything.

## Why it is not one number

A raw sample-by-sample null is the strictest comparison and the least
informative. Two synthesisers that agree on every design decision but start
their oscillators a fraction of a cycle apart null at 0 dB, and so do two that
agree on nothing. The null depth is reported, and when it is deep the argument is
over — but the metrics that locate a defect are the ones that ignore phase:

| metric | what it answers |
|---|---|
| `spectral_db` | Timbre: is the harmonic balance right? Filter curve, FM direction, oscillator mix. Mean absolute 1/6-octave difference after both spectra are normalised to equal energy, so a level error does not smear into it. |
| `envelope_db` | Shape over time: is the amplitude contour right? Directly measures the attack/decay/sustain/release mapping. |
| `centroid`, `f0` | Gross errors: a wrong octave, a filter an octave off, a ring or sync path that moved the spectrum's centre of mass. |
| `level_db` | Gain staging alone, separated from everything above. |
| `width` | `side/mid` ratio: unison pan spread and the stereo effects. |

The aggregates in the summary matter more than any single patch. A mapping
constant that is wrong is wrong by the same amount on every patch at once, so it
shows up as a systematic bias; scatter with no bias means the mapping is right on
average and something patch-specific is off instead.

## Conditions

Both engines get the identical treatment, and the places where that took work are
the places where it would otherwise have silently lied:

- **Patch loading.** The stored integers are written into the reference's own
  state chunk and handed back with `effSetChunk`, the same path `verify` uses,
  because `setParameter` saturates at 1.0 while the loader genuinely reports
  values above it. Every parameter is read back and any mismatch is carried into
  the row, so a difference caused by the patch not loading can never be mistaken
  for a difference caused by the engine.
- **Velocity.** MIDI 100 to the reference, `100/127` to our engine. Parameter 30
  scales level by velocity, so a convenient `1.0` on our side would have been
  reported as a level error on every patch that uses it.
- **Note off.** The hold is a whole number of blocks, so the note off lands on
  the same sample in both. Otherwise the reference's note off arrives up to a
  block later and the difference is charged to the release curve, which is one of
  the things being measured.
- **Transport.** The host reports a running sample position, ppq position, bar
  and tempo, with the matching validity flags. The original version answered
  `audioMasterGetTime` with a transport frozen at bar one forever, which is not
  a small inaccuracy: anything driven by musical time — the arpeggiator, the
  tempo-synced delay, a tempo-synced LFO — was reading a lie, so the render was
  not the one the plugin would produce in a real host.
- **Isolation.** Every reference render gets a freshly loaded plugin. See below.

## The reference binary

Two things about `Synth1 VST64.dll` shape the harness.

**It must be reloaded between renders.** Suspend and resume — which is what
VST 2.4 gives a host for exactly this — segfaults after ten to twenty cycles.
Reloading the library avoids that, and makes the measurement exact: two renders
of one patch come out bit-identical, so the harness has no noise floor and every
difference reported is genuinely ours. Under suspend-and-resume the control run
reported 2.1 dB of spectral and 3.7 dB of envelope error *against itself*.

**Five patches crash it.** `095`, `098`, `100`, `101` and `106` segfault inside
Synth1 during the first render, in a fresh process, with one instantiation and no
prior patch loaded. This is not a resource limit: each reproduces on its own,
neighbouring patches render fine immediately afterwards in the same process, and
`verify` reads every parameter of each back correctly, so the state chunk they
are given is accepted — it is the render that dies.

This was initially misread as a cumulative instantiation limit, because two
full-bank runs stopped after exactly 94 patches. They stopped there because `095`
is the 95th patch.

**It is the arpeggiator, and it is not this host's doing.** Two probes narrow it:

- `s1probe paramcrash <patch.sy1>` restores one parameter at a time to the value
  the plugin's own factory chunk holds and renders. Of the twenty-eight
  parameters where `095` differs from the factory state, exactly one restoration
  survives: parameter 59, the arpeggiator switch. Every other one still dies.
- `s1probe hostprobe <patch.sy1>` varies what the host does, one thing per case,
  each in a child process: `audioMasterTempoAt` answered 0 or BPM×10000,
  `audioMasterWantMidi` and `audioMasterProcessEvents` answered 0 or 1, the
  transport claimed rolling or stopped, an empty `effProcessEvents` dispatched
  before every block or not at all, the retained event list zeroed after each
  dispatch, blocks of 64, 512 and 1024, and the state chunk pushed before the
  resume, after it, or with a suspend-and-resume cycle behind it. **All eleven
  die.** On a patch with the arpeggiator off, all eleven render to the same peak
  to four decimal places, so none of them is changing the audio either.

One of those cases has a lesson in it. `empty-events-per-block` appeared to fix
the crash on the first run — because dispatching the empty list before the first
block overwrote the note-on, so the reference rendered silence, and a probe that
counted "did not crash" as success called that a pass. That is the failure mode
CONTRIBUTING.md names, in a new costume: the probe was measuring its own input.
It now fails a case whose render is silent, and `empty-events-per-block` dies
with the rest.

So the fault is inside a twenty-year-old binary this project cannot patch, and
the defence is to lose nothing when it happens. `compare` renders **each patch in
its own process by default** for any run of more than one: a patch that kills the
reference costs its own row and the run finishes. Rows are appended to the CSV as
each patch completes, and the summary names the casualties.

```
build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv build/nulltest.csv
```

`--skip` and `--offset` still work, and are no longer the only defence.
`--no-isolate` puts the render back in this process, which is what a debugger
attached to the crash wants.

## Reading the aggregates

Each line in the systematic-bias block carries the number of patches it was
computed from, because they are over different subsets: a metric is included only
where both renders produced something to compare. The release figure is the one
to watch — it comes from the handful of patches where *both* tails finish inside
the render, nine of the current bank, because on the rest the reference is still
sounding at the end. A mean over nine patches sitting next to a mean over a
hundred, with nothing to distinguish them, invites a conclusion the data cannot
support.

The robust whole-bank numbers are the spectral and envelope errors.

## Baseline

123 of the 128 factory patches, middle C at velocity 100, 1.5 s held plus 1.0 s of
tail at 48 kHz. Measurement floor: exactly zero on every metric.

Three points: the original guessed curves, after the envelope curve was measured
(below), and after the FM direction was corrected to the reference's
(`docs/reference-notes.md`).

```
                     guessed   +envelope   +FM dir
spectral error mean  19.88 dB   20.44 dB   19.50 dB
envelope error mean  22.84 dB   17.44 dB   17.77 dB
level error    mean  +3.68 dB   +5.10 dB   +4.68 dB
null depth     mean  -1.00 dB   -1.38 dB   -1.24 dB

brightness     median  -0.02      -0.02      -0.02  octaves
tuning         median   +0.2       +0.3       +0.3  cents
release length median  -2.40      -0.22      -0.22  octaves  n=9
stereo width   median -0.430     -0.430     -0.430           n=123

ours silent by the sustain  15          7          7  patches
```

101 of 123 patches improved on envelope error, 5 got worse, 17 were unchanged.

The FM correction is precisely scoped: of the 53 patches that can reach neither
the FM path nor hard sync, **not one changed by any amount**. Among the 70 that
can, the mean spectral error fell 1.56 dB — but 26 improved and 17 got worse, so
it is a net gain rather than a clean one. The single largest win was patch 128,
the worst in the bank, from 49.6 dB to 21.8 dB. Splitting further: the 20 patches
using hard sync improved almost uniformly (6 better, 1 worse), while the mixed
result is entirely in the FM group. Something about our FM still differs from the
reference's — most likely that its carrier is a band-limited wavetable rather
than a PolyBLEP oscillator, which changes what modulation does to the spectrum.

### What the probes changed, one at a time

`docs/reference-notes.md` records four things measured out of the reference with
`s1probe waveprobe`, `filterprobe` and `lfoprobe`. Each was applied separately
and measured, because bundling them hides which one did what — a mistake made
twice in this project already:

```
                                  spectral error, mean / median dB
FM direction only ...............  19.50 / 19.17
+ waveform mapping ..............  19.01 / 18.42    improved
+ waveforms + LFO destinations ..  20.44 / 20.63    LFO regressed by 1.4
+ waveforms + LFO + filter type .  20.03 / 20.19    filter improved by 0.4
```

Three of the four are kept because they are measured facts. The fourth, the LFO
destination mapping, is **also** kept despite making the metric worse, and that
needs saying plainly: it was measured by comparing each state's render against
the same patch with the LFO off, which is about as direct as evidence gets. What
the regression shows is that the *depths* the destinations are scaled by are
still invented, and a correct destination driven by a wrong depth can be further
from the reference than a wrong destination that happened to be mild. Display 2
was bound to the filter cutoff and is really both oscillators' pitch, so it now
swings an octave of pitch where it used to sweep a filter.

Encoding a mapping known to be false because it scores better would be fitting
the metric rather than the reference. The LFO depth scalings in
`voice_process` are the next thing to measure.

The waveform correction also pushed the level error from +4.7 to +8.2 dB, for a
plain reason: saw and pulse are much louder than the triangle they replaced. That
made the amplitude curves the largest remaining guess, and they were measured
next.

### The amplitude curves

`s1probe leveltable` sweeps parameter 29 (gain) with the sustain held at maximum
and parameter 27 (sustain) with the gain held at maximum, rendering a sine
through an open filter with a flat envelope, and reads the amplitude back.

```
level error      before      after
mean            +7.20 dB   +3.70 dB
median          +4.91 dB   +1.35 dB
```

Three findings:

- **Full gain reaches an amplitude of 0.750, not 1.0.** The binding this replaced
  was `unit^2`, which reaches unity at the top of the range, so it gave away
  2.5 dB before the curve's shape is even considered.
- **The shape was wrong too**, by a further ~3 dB at the middle of the range.
- **Gain and sustain share one curve.** Swept independently, the two knobs
  produce the same amplitudes to five decimal places. They are kept as two
  tables because they are two parameters, but the equality is worth knowing.

Spectral error is unchanged at 20.0 dB, which is the expected result: the
spectral metric normalises energy away, so a pure level correction cannot move
it. That is a small check that the metric is behaving.

### What the level error is made of now

The mean is still +3.70 dB, but it is no longer a curve error -- it is bimodal
and dragged by outliers, one of them at +71 dB:

```
  < -3 dB : 42        -1..+1 dB :  9
  -3..-1  :  9        +1..+3    : 12
                      +3..+6    :  7
                      > +6 dB   : 44
```

Twenty of those patches are a single distinct fault, and it is not a level fault.
On them the *reference* barely sounds at all -- peak amplitudes around 0.0004
against our 0.24 -- and they share a signature: a low cutoff paired with a
**negative** filter envelope amount (parameter 21 stored between 22 and 40,
where 63 is zero). Synth1 closes the filter almost completely on these patches
and this engine does not. Compare 123.sy1, which has an even lower cutoff but a
positive envelope amount, and sounds in both.

### The filter, and what the quiet patches really were

`s1probe filtertable` measures the cutoff knob and the envelope amount the same
way `filterprobe` classifies the filter types -- noise through the low pass, the
corner read off the spectrum as the -3 dB point against a wide-open render, with
the crossing interpolated so the answer is not quantised to the 1/6-octave band
grid.

- **The cutoff curve** runs 24 Hz to about 17 kHz and moves in steps of very
  close to one semitone above stored 16. The chosen 20 Hz--20 kHz exponential it
  replaces was about a quarter of an octave sharp across the whole range.
- **The envelope amount is linear in octaves**, at 0.1595 per step, crossing zero
  at state 63 -- exactly the state whose display reads "0". So the knob reaches
  about ten octaves either way, where `voice_process` scaled it by an invented
  six. It is stored as a law rather than a table because the measured extremes
  saturate against the filter's own limits at the cutoff they were measured from,
  and a table would apply one setting's headroom to every other.

That fixed real error across the bank -- spectral 20.00 to 19.18 dB, level median
+1.35 to +0.49 dB -- but it did **not** fix the near-silent patches it was
motivated by. 080.sy1 stayed at +71 dB. The diagnosis had correlated without
being the cause.

The cause was the pulse wave. A naive `t < pw ? 1 : -1` carries a DC offset of
2*pw - 1, and 080.sy1 pairs a 98% width with a 24 dB low pass at 17 Hz: the
filter was doing its job and removing everything except the DC, which no low pass
can touch. Building the pulse as the difference of two saws, which is what the
reference's author describes and which is DC-free at every width, moved that
patch by 61 dB.

Measuring the pulse then settled two more things:

- **The width knob spans 0 to a half, not 0 to 1.** The reference's harmonics at
  stored 64 are h2 -3.1, h3 -9.8, h4 -41.3, h5 -13.8, h6 -12.6, h7 -17.4 dB, and
  `sin(n*pi*d)/n` reproduces all six to within 0.1 dB only at d = 0.252. The
  near-null at the fourth harmonic is what pins it: a half duty would put its
  nulls at the even harmonics instead. The binding was at a square where the
  reference is at a quarter.
- **The pulse swings half what the saw does**, from the two waveforms' measured
  RMS at the same gain.

With all of it in place the four waveforms match the reference's amplitudes
uniformly, to within 0.8 dB -- and that residual is this engine's own output
soft-clip, which the reference does not have.

### Where the level error actually lives

The bank-wide level error reads -6.5 dB, which looks like a regression until it
is split by whether the patch uses anything this engine does not implement:

```
patches with delay or chorus audible : n=115  mean level  -6.96 dB
patches with both off                : n=  8  mean level  -0.34 dB
```

On the patches this engine can actually reproduce in full, the level is now
within a third of a decibel. The rest is the missing chorus and delay adding
energy to the reference, which no amount of gain-curve work will close -- it
needs the effects. That also explains the stereo width sitting at half the
reference's throughout.

### The LFO depths: three measured, one failed

`s1probe lfodepth` drives one destination at one depth and reads the range the
observable moves over, peak to peak, so the LFO's shape and starting phase drop
out. Two details had to be got right first: the ends of the render must be
trimmed off, because the note's own onset and release put a 6 dB floor on any
level measurement; and the range has to be a percentile band rather than
min-to-max, because a corner estimated from noise jitters and min-to-max turned
an unmodulated sweep into two octaves of spurious movement.

```
depth    pitch      cutoff    volume     pan
   32   3.77 st   1.34 oct   1.75 dB   0.386
   64  10.54 st   1.91 oct   4.01 dB   0.669
   96  22.66 st   2.17 oct   7.13 dB   0.842
  127  42.33 st   2.50 oct  11.93 dB   0.927
```

Cutoff, volume and pan are taken: 2.42 octaves at full depth after the noise
floor is removed, 11.93 dB peak to peak, and 0.927 of full width. The volume
figure is the largest correction of the three -- the law it replaces ducked all
the way to silence, roughly 40 dB deeper than the reference goes.

**The pitch measurement failed and is not used.** It does not converge: full
depth reads 43.2, 42.3, 39.3 and 36.4 semitones at notes an octave and a half
apart, and an LFO depth cannot depend on the note played. It is not the pitch
tracker losing a swept saw's fundamental among its harmonics -- a triangle and a
sine, whose fundamentals dominate throughout, drift identically -- and neither
end of the sweep is against the analysis band's limits. Something the reference
does here is not captured by this method. The constant stays at twelve semitones,
with the measurement's one solid conclusion recorded next to it: the real depth
is *at least* 36 semitones, three times that.

A depth curve was nearly adopted on the same evidence -- the normalised pitch
figures match the measured amplitude curve's shape almost exactly, and parameters
27 and 29 already share that curve, so a third knob on it was a tidy story. It is
not kept, because the evidence for it is the same compromised sweep.

Applying the three sound scalings cost about 0.2 dB of spectral error
(19.55 to 19.66 mean) -- the same pattern as the destination mapping before it,
and for the same reason. The rate was still a chosen curve.

### The rate, which was the thing holding the rest up

`s1probe lforatetable` points the LFO at the stereo position -- a bipolar scalar
per frame that nothing else in the voice can contaminate -- and counts the
crossings of its own mean, two to a cycle, growing the render until enough cycles
fit. The measured curve runs **0.078 Hz to 125 Hz**, against a chosen 0.05 to 40:
the engine was 1.6 times too slow at the bottom of the range and **3.1 times too
slow at the top**. Like the filter cutoff, it moves in steps of close to one
semitone, 0.083 octaves per step over ten and a half octaves.

The first attempt at this measurement sampled the pan series every 5 ms, which
Nyquists at 100 Hz, and it read 52 Hz at stored 112 and then *38* at 127 -- lower
at a higher setting. That is the series aliasing, not the LFO slowing down; a 1 ms
frame at a high enough note to hold a cycle resolves the top of the range as
125 Hz. The version history's "LFO maximum speed up" entry is not an
exaggeration: this knob ends at an audio-rate oscillator.

Correcting it took spectral error from 20.19 to **19.31 dB** median.

### And then the pitch depth again

With the rate right, the deep pitch reading stopped being a regression and became
an improvement. Spectral error now falls monotonically as the constant rises:

```
LFO_PITCH_SEMITONES   12     24     36     42.33
spectral median      19.31  18.78  18.53  18.53 dB
```

So the deep end of the measured range is where the reference is, and the earlier
regression was the rate all along. The constant is set to 42.33 -- the reading at
the lowest note measured, which has the most headroom at the top of its sweep and
is therefore the least likely to have been truncated, and a truncated measurement
can only read low. The note-dependence itself is still unexplained and recorded
next to the constant.

That is the second time in this project a measured-correct change looked wrong
until a neighbouring guess was measured. It is worth stating as a working rule:
when a measurement that is sound makes the null test worse, suspect the parameter
next to it before doubting the measurement.

## The envelope error, and the octave hiding in the filter

Envelope error was the worst metric on the bank at 20.37 dB, so it was the next
target. Splitting it first was what made it tractable:

```
delay or chorus audible : n=115  envelope 21.19 dB
both off                : n=  8  envelope  9.86 dB
```

More than half of it is the missing effects' tails, not the envelope. The 9.86 dB
is the part this engine can do something about, and the thing to fix turned out
not to be an envelope parameter at all.

Fourteen patches were rendering silent through the sustain window. Eight of those
were ours going silent while the reference sounded, and they shared a feature:
keyboard tracking at or near maximum. `s1probe cutoffprobe --sweep note` settles
what the tracking does:

- With tracking off, the corner sits at the same frequency at every note.
- With tracking full, it rises exactly one octave per octave -- and passes through
  the untracked frequency at **note 48**, not note 60.

So the reference tracks from C3, an octave below middle C, where `voice_process`
was tracking from middle C. Every patch with the tracking knob up was a full
octave too dark, and through a 24 dB filter that is 24 dB of missing output. It is
why they fell silent.

Correcting the reference note is the largest single improvement in this whole
sequence, and it moved every metric at once:

```
                  before    after
envelope median   20.37 dB  18.87 dB
spectral median   18.53 dB  18.29 dB
level median      -6.93 dB  -4.17 dB
silent by sustain   14         11
envelope, effect-free patches   9.86 dB -> 7.92 dB
```

The tracking *amount* is left linear. It is right at both ends -- 0 and 1.01
octaves per octave -- but measures slightly convex between them, 0.589 octaves at
stored 64 against a linear 0.504. About a semitone, and recorded rather than
modelled.

### One guess that turned out to be right

The filter envelope's sustain was still a linear reading of its knob while the
amplitude sustain had been given a measured table, so it looked like an obvious
next correction. `cutoffprobe --sweep sustain` says it needs none:

```
stored     16      32      48      64      80      96     112
measured  0.1275  0.2549  0.3807  0.5064  0.6313  0.7575  0.8861
linear    0.1260  0.2520  0.3780  0.5039  0.6299  0.7559  0.8819
```

Within 0.005 across the range. Unlike the amplitude sustain, which shares the gain
knob's curve, this one really is linear. Worth recording: it is the first guess in
this project that a measurement has confirmed rather than overturned, and knowing
a parameter is *already right* is as useful as finding one that is wrong.

## The delay and the chorus

These were the dominant error on the bank -- 19.8 dB of envelope error on patches
that use them against 7.9 dB on patches that do not -- so the null test made the
case for implementing them, and it is the largest single improvement in the
project:

```
                  before    after
spectral median   18.29 dB  10.11 dB
envelope median   18.87 dB  16.17 dB
silent by sustain   11         6
stereo width      -0.433    -0.314
```

### Most of it was read, not chosen

Unusually for this project, the effect parameters mostly carry real units in
their displays, and the binding parses them rather than inventing curves:

| parameter | display | read as |
|---|---|---|
| 35 delay time | `(16)+(32)`, `(4) /3`, `0.1 msec` | musical divisions in beats |
| 83 delay spread | `0.0 : 100.0 msec` | both channel times, in ms |
| 37 delay dry/wet | `23%` | a fraction |
| 52 chorus delay | `0.05 msec` .. `30.00 msec` | milliseconds |
| 54 chorus rate | `0.01 Hz` .. `400.00 Hz` | hertz |
| 55 chorus feedback | `-99 %` .. `97 %` | a signed fraction |
| 64 chorus type | `1`, `2`, `4` | the number of stages |

Parameter 35's twenty states are a table, not a formula: `(16)+(32)` is a dotted
sixteenth, `/3` a triplet, and the states are not in ascending order of time --
state 9 is a half triplet at 1.33 beats and state 10 a dotted eighth at 0.75. A
quarter note is one beat, so `(N)` is 4/N beats.

Parameter 54 reaching 400 Hz is why one structure serves as both chorus and
flanger, which is what the manual calls the section. A 30 ms tap swept slowly with
no feedback is a chorus; a 0.2 ms tap at 90% feedback is a flanger; 400 Hz is
neither. All three fall out of the same three knobs.

Still chosen, and named at their use sites: the delay feedback curve, the tone
control's corner frequencies, which of parameter 82's three states is the
ping-pong routing, and the chorus depth and level curves.

### A design bug the null test caught

The chorus spreads its stages evenly around the LFO cycle and offsets the right
channel from the left. The obvious channel offsets both collide with the stage
spacing:

- Half a cycle: two stages sit at 0 and 0.5, so the right channel's sweeps land on
  the left's with the sign flipped and the stages cancel.
- A quarter cycle: four stages sit at 0, 0.25, 0.5, 0.75 and the right channel
  reads the same four positions, so the image collapses to mono.

Offsetting by half a *stage* cannot alias at any count. Measured on stereo width,
as this engine minus the reference: half a cycle −0.429, a quarter −0.340, half a
stage −0.314. Anti-phase is the textbook answer for a stereo chorus and it was the
worst of the three here, which is the sort of thing only a measurement finds.

### What parameter 64 actually is

The width was still 0.31 short, so the chorus's two remaining guesses -- the depth
and level curves -- got the same treatment. `s1probe chorusprobe` measures both off
the **side** signal, L minus R, where the centred dry cancels and only the chorus's
own output is left; the level curve is then the side against the mid, and the depth
curve is the pitch wobble of that side signal, which a swept tap produces and which
converts back to a delay swing in closed form.

The important finding was not either curve. It was that parameter 64 is not three
stage counts:

```
type 1   no side signal at all,      one tap's worth of wet
type 2   a wide side signal,         one tap's worth of wet
type 4   a narrower side signal,   *two* taps' worth of wet
```

So type 1 is a **mono** chorus, type 2 sends one tap to each channel, and type 4
sends two to each. That accounts for all three columns: per-channel level goes
1, 1, 2, and type 4 is narrower than type 2 because averaging two opposed sweeps
into one channel takes some of the difference back out.

The implementation had treated the number as a stage count, given every type a
channel offset, and divided by the count to hold the level steady -- so type 1 was
stereo when it should be mono, and the level difference between 2 and 4 was
flattened away. Correcting it:

```
                  before    after
envelope median   16.17 dB   9.53 dB
stereo width      -0.314    -0.065
level median      -5.18 dB  -3.00 dB
spectral median   10.11 dB  11.79 dB
```

Width is essentially solved. Spectral went 1.7 dB the other way, which is the one
cost; against six decibels of envelope error and a quarter of the stereo image, the
measured model stays.

### The level curve was already right; the depth curve is not, and stays out

Level, measured against a chorus-off render, grows 0.252, 0.504, 0.756, 1.000 of
full across stored 32, 64, 96, 127 -- linear to three decimal places, which is what
the binding already did. The second guess this project has confirmed rather than
overturned.

Depth is steeply exponential, normalised 0.004, 0.012, 0.050, 0.202, 1.000 against
a linear 0.126, 0.252, 0.504, 0.756. But the measurement settles the shape and not
the scale: at full depth the swing is 0.50 of the centre delay at a 30 ms centre,
0.35 at 18.9 ms and 0.25 at 3.8 ms, so there is no single fraction to apply.
Fitting the shape with half the centre as its top pushed stereo width from -0.065
back out to -0.323 and spectral up 0.4 dB, which is what a right shape on a wrong
scale does. It stays linear, with the measured shape recorded next to it.

That is the third time a measurement has been sound about shape and wrong about
what to do with it until a neighbouring quantity was understood. The rule from
earlier holds.

## The chorus rate and depth

Two questions, and they have different answers: the rate needed no curve, and the
depth's needed replacing.

### The rate is already exact, and now that is checked rather than assumed

Parameter 54 displays hertz — 0.06, 0.22, 2.72, 32.99, 369.99 Hz across the knob —
so the binding reads it and there is nothing to fit. What had never been verified is
whether the displayed hertz is the *actual* modulation rate; a factor of two hiding
there would be an octave of error in every chorus.

The tracked pitch of the chorused signal oscillates at the LFO rate, so counting its
cycles measures the rate independently of the display:

```
  shown Hz    0.45    0.99    1.58    2.15    2.72
  measured    3.24    4.49    1.50    2.24    2.74
  ratio       7.20    4.53    0.95    1.04    1.01
```

At the three settings whose period fits the analysis window the ratio is 1.00 to
within 5%. The two slow ones are the counter failing on periods longer than the
window, not the plugin. So the rate is confirmed correct as read.

A second consistency check falls out of the same runs: the pitch wobble scales
linearly with rate — 642, 645, 658, 675 and 693 cents per hertz — which is what a
delay swing set by *depth alone* must do.

### The depth: the shape was wrong, and the old conclusion about it was wrong too

A previous pass measured the depth's shape, found it steeply exponential, and left
the binding linear because the *scale* would not resolve: at full depth the swing
came out as 0.50 of the centre delay at a 30 ms centre, 0.35 at 18.9 ms and 0.25 at
3.8 ms, so the reference looked like it was not simply scaling by the centre.

It is. Those readings converted the pitch wobble using the displayed rate at
settings where the displayed and measured rates disagree. Redone at a rate that
checks out, the wobble per millisecond of centre delay is constant:

```
  centre ms      14.60   22.44   26.0    29.76
  wobble/centre   58.8    60.8    61.9    63.3   cents per ms
```

A constant ratio is exactly what a multiplicative law looks like, so the DSP's
existing "fraction of the centre delay" is the right form and only the curve from
the knob to that fraction was wrong.

### What the instruments could not do

The absolute scale is still unmeasured, and both attempts failed in ways worth
recording so a third does not repeat them.

**The pitch-wobble method breaks at large depth.** At full depth it reports swings of
16 to 42 ms against centre delays of 15 to 30 ms — a tap cannot swing further than
its own centre without the delay going negative, so the reading is impossible rather
than merely uncertain. The cause is that a two-stage chorus puts two
differently-modulated tones in the side signal and tracking the strongest bin hops
between them, summing two excursions. One stage would avoid that, and one stage is
mono, so there is no side signal to read at all.

**A time-domain tracker did not lock.** A delay is a time, so the obvious fix is to
autocorrelate noise through the chorus and read the tap's lag directly. Over a
4800-sample window the autocorrelation of noise has a standard deviation near 0.014,
and across the candidate lags the real peak does not clear the four-sigma noise —
the search returns its own bounds, both with the range open and with it bounded
around the centre the display states.

### The exponent, and what kind of number it is

The measured form is `exp(k * (u - 1))` for `u` the knob position. The exponent is
*bracketed* by the measurement rather than read off it, because both ends of the
sweep are its least reliable points: the full-depth reading is the impossible one
above, about 1.35 times too large, which refits `k` at roughly 5.4; and at stored 16
the wobble being read is 7 cents, near the tracker's noise floor, which pushes the
other way.

So three values were tried across the whole bank:

```
                spectral median   envelope median   width median
  linear            11.69 dB           9.35           -0.060
  k = 3              8.84 dB           9.02           -0.072
  k = 6             10.22 dB          10.91           -0.219
```

`k = 3` improves both headline metrics — spectral median by **2.85 dB**, the largest
single gain in this file — at a cost of 0.012 in stereo width. It ships, labelled as
what it is: a value chosen inside a measured bracket, not a reading. Only those three
were tried.

### The stereo mechanism, measured

The width regression above looked like a second mechanism waiting to be found — the
reference staying wide while its depth fell suggested it widened by some static
inter-channel offset. It does not. One render settles it, because at **depth zero
there is no modulation at all**:

```
  depth        0      16      32      64      96     127
  reference  0.000   0.525   0.532   0.536   0.540   0.538
  ours       0.545   0.543   0.542   0.546   0.547   0.546
```

The reference is **exactly mono** at depth zero — side/mid of 0.0000, channels
correlating at +1.000 — so its width is entirely modulation-driven, the same
mechanism as ours. And above depth 16 the two agree closely. The whole discrepancy
sat at one point of the knob.

The cause was a fault introduced by the previous section's own fix. `exp(k * (u - 1))`
never reaches zero: at the bottom of the knob it leaves 5% of depth, and for a
broadband source even 1.5 ms of swing decorrelates the channels completely. So our
chorus was fully wide where the reference was silent in the side channel.

Anchoring the curve at both ends — `(exp(k*u) - 1) / (exp(k) - 1)` — makes it exactly
zero at zero, and it happens to fit the measured shape better too. Width then matches
across the range, including the mono point:

```
  depth        0      16      64     127
  reference  0.000   0.525   0.536   0.538
  ours       0.000   0.509   0.543   0.546
```

The inter-channel lag agrees as well: −29.75 ms on both sides at depth zero.

### Choosing the exponent, and refusing 0.4 dB

Anchoring cost accuracy elsewhere, and the trade is worth recording:

```
                        spectral  envelope   width     (medians)
  linear                  11.69     9.35    -0.060
  exp(3(u-1))              8.84     9.02    -0.072    best, wrong at u = 0
  anchored k = 6          10.22    11.32    -0.230    best shape fit, too steep
  anchored k = 2           9.24     9.32    -0.076    ships
```

The floored form scores 0.4 dB better and is not used. It is wrong at a point that was
measured directly — the reference is mono at depth zero and that form is not — and a
curve which is wrong where the reference was checked does not get to ship for 0.4 dB.

Anchored `k = 6` is the closest fit to the measured shape and is clearly too steep on
the bank, which says the shape measurement under-reads the middle of the range. That
is consistent with its own weakness: the wobble it reads at stored 16 is 7 cents,
near the instrument's noise floor. So the *form* and the zero at the bottom are
measured; the exponent is chosen by the oracle inside the bracket.

Against the linear baseline this is still a large gain: spectral median 11.69 → 9.24 dB.

### The tap-to-channel assignment

The stage count behaved oppositely in the two engines:

```
  stages       1       2       4
  reference  0.000   0.538   0.418
  ours       0.000   0.546   0.676
```

Both agreed that one tap is mono and two are wide. At four the reference got
**narrower** and we got **wider**.

The first hypothesis was the inter-channel phase. It is not: sweeping the offset from
a quarter turn to nearly a half moved the width by **0.006 in total**, from 0.676 to
0.670. Ruling it out left the levels, and there the old code was explicit about doing
something the reference does not — it put two taps into each channel at full level,
on the reasoning that type 4 carries twice the wet of type 2. That doubles the side
against an unchanged dry, so the image widens for free rather than because the
channels decorrelated.

Averaging the taps per channel instead does two things at once: the level stops
doubling, and averaging two opposed sweeps leaves each channel closer to a fixed delay
than either tap is alone, so the channels resemble each other more. Four taps then
match the reference exactly:

```
  stages       1       2       4
  reference  0.000   0.538   0.418     correlation 0.701
  ours       0.000   0.543   0.418     correlation 0.700
```

### Two measurements that disagreed, and which one to believe

The bank did not initially agree. Split by the tap count each patch actually uses, the
change made the twelve four-tap patches *narrower* — width error from 0.225 to 0.332
below the reference — where the probe said they now matched perfectly. A probe reading
an exact match while the bank reads a bigger gap is a warning that the probe is
measuring a corner, and it is: its width saturates above a depth of about 16 with a
noise source, so it cannot discriminate at all in the region the bank patches occupy.

The split on the headline metric settles it:

```
  type   n     spectral before -> after     envelope
   1     5        7.81  ->   7.81           unchanged
   2   106        9.59  ->   9.65           unchanged
   4    12       21.98  ->  10.15           10.55 -> 13.67
```

Averaging halves the timbre error on exactly the patches it touches — 11.83 dB — and
takes the four-tap group from far and away the worst in the bank to the same place as
everything else. Nothing else moves. That accounts for the entire aggregate gain:
12/123 × 11.83 is 1.15 dB against the 1.16 dB observed.

So the tap levels are now right. What is still wrong is narrower: those same twelve
patches are 0.332 short on width and 3.1 dB worse on envelope, so *how* the two
channels differ is not fully modelled even though *how much* wet each carries now is.

## The tonal probe, and what it found

`s1probe choruspatch` is the instrument the noise probe could not be. Three things
differ from it, and each is there because the noise probe failed on that point:

- **The patch is real.** Every setting is the `.sy1` file's own — wet level, centre
  delay, rate, depth, waveform, filter — rather than pinned. The affected patches
  cluster tightly (all thirteen use delay 64 and rate 64, eleven use depth 64), so
  what varies between them is mostly the wet level, which is exactly the axis a
  pinned probe destroys.
- **Width is reported per octave.** One number cannot say *how* two channels differ,
  and that is the remaining question. Too quiet everywhere, decorrelated in the wrong
  part of the spectrum, and right in the middle but wrong at the edges are three
  different bugs that a single figure reports identically.
- **The chorus is isolated**, by rendering each engine again with parameter 66 forced
  off. A patch can be wide for reasons that have nothing to do with this section, and
  without the second render those get charged to it.

The isolation immediately earns its place: with the chorus off, the two engines' widths
agree closely on eleven of twelve patches — 0.024 against 0.023, 0.047 against 0.046,
0.128 against 0.119. Everything else stereo about these patches is already right, so
the gap really is the chorus.

### The defect is the shape of the decorrelation

```
  band centre Hz     88     177     354     707    1414    2828    5657   11314
  reference       0.370   0.890   0.492   0.673   0.559   0.606   0.585   0.598
  ours            0.349   1.013   0.188   0.227   0.387   0.636   1.022   0.665
  ours - ref     -0.021  +0.123  -0.304  -0.446  -0.172  +0.030  +0.437  +0.067
```

The reference's width is **flat across frequency** — near 0.6 from 88 Hz to 11 kHz.
Ours is **comb-shaped**: far too narrow at 354 and 707 Hz and half again too wide at
5.7 kHz. That is the signature of two channels carrying the same signal at slightly
different delays, which decorrelates only above roughly `1/(2 * delta)` and leaves the
low end correlated. The reference's flatness says its channels differ by something
that is not a small delay offset.

Two candidate levers were tested and both ruled out. The inter-channel phase, swept
from quadrature to anti-phase: it moves the tonal width by nothing that matters and
the band shape not at all. And the within-channel spread, changed from a full cycle
to a half so that each channel's tap pair stops being symmetric about the centre
delay — the per-band shape stayed comb-like, −0.363 and −0.476 at the same two bands.
So the remaining defect is in the decorrelation mechanism itself, not in how the taps
are dealt out or spaced.

### A larger finding, which is not the chorus

The mid level was added to the same table for a reason: a wet signal that is too quiet
and one that is not decorrelated enough look identical in a ratio. It answers that
question and raises a bigger one.

```
  patch      049   056   081   082   085   086   087   089   090   092   094   104
  mid dB    -8.8  -7.9 -12.3 -12.4 -15.9 -33.6 +14.0 -12.9 -11.5  -3.7 -14.0  -2.6
```

On eleven of these twelve patches our whole output is **3 to 16 dB quieter** than the
reference's, with one at −33.6 and one at +14.0. That is far outside the bank's −4 dB
median level error, it is present with the chorus switched off as well, and it is
therefore not this section at all. These twelve patches were the worst spectral group
in the bank before the tap fix and they remain the group with the largest level error;
whatever they have in common is worth finding, and it is a different investigation
from the one this section is about.

## The oscillator mix, and what the harmonic-balance error really was

The mix was the suspect for the 3 to 13 dB of harmonic-balance error on
two-oscillator patches. The crossfade shape was right, but this document called
its rounded display the law. That was wrong by up to 0.07 dB.

Parameter 5's display states a rounded ratio, but not what that ratio does to
the signal — a linear crossfade in amplitude, an equal-power crossfade and two
independent gains all honour the same displayed numbers. Making oscillator 1
a **sine** settles it, because a sine has exactly one partial: with oscillator
2 an octave above, the two contributions occupy different frequencies entirely
and each gain reads off its own fundamental.

This run includes both endpoints. The candidate laws agree there, so normalising
each curve to its own endpoint is an absolute reading, not a fit to how far a
harmonic moved:

```
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe mixprobe --values 0,8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,127

 stored  display   osc1 gain  osc2 gain      sum
     0   100 : 0      1.00000    0.00000  1.00000
    32    75 : 25     0.74803    0.25197  1.00000
    64    50 : 50     0.49606    0.50394  1.00000
    96    24 : 76     0.24409    0.75591  1.00000
   127     0 : 100    0.00000    1.00000  1.00000
```

The oscillator 2 readings are `stored/127`: 0.25197 and 0.50394 sit above
the display's 0.25 and 0.50, while 0.75591 sits below its 0.76. That change of
residual sign excludes the rounded display law rather than merely finding a
small offset. `sum` is 1.00000 at all seventeen settings, mean deviation 0.0000;
the mean equal-power error is 0.3104. So this is a unity-sum linear amplitude
crossfade, not equal-power or independent non-unity gains, but its exact law is
`osc2 = stored/127`, `osc1 = 1 - stored/127`.

### The sub's `(1-m)` survives the unrounded reading

Parameter 95's normalised sub mix uses oscillator 1's weight. `mixprobe` repeats
the earlier check with two saws four semitones apart, a saw sub at `-1oct` and
stored sub gain 110; no sub partial lands on oscillator 2, so its own partial
reads the normalising denominator. With `a = 4*110/127`:

| stored mix | 32 | 64 | 96 | 112 | 127 |
|---|--:|--:|--:|--:|--:|
| reference, sub on / sub off at oscillator 2 | 0.27838 | 0.36768 | 0.54173 | 0.70962 | 1.00000 |
| `1/(1+a*(1-stored/127))` | 0.27843 | 0.36783 | 0.54181 | 0.70962 | 1.00000 |
| denominator `1+a` alone | 0.22399 | 0.22399 | 0.22399 | 0.22399 | 0.22399 |

The unrounded `(1-m)` prediction agrees within 0.00015 across the sweep. The
flat alternative misses by 0.05439 already at stored 32 and cannot reach unity
when oscillator 1 and its sub vanish at 127.

### Factory-bank result

The full bank was read before and after with the same 123 comparable rows:

```
./build/s1probe.exe compare patches/incoming/soundbank00 --csv build/mix-before.csv
./build/s1probe.exe compare patches/incoming/soundbank00 --csv build/mix-after.csv
./build/s1probe.exe summarise build/mix-before.csv
./build/s1probe.exe summarise build/mix-after.csv
```

| metric | rounded display | `stored/127` |
|---|--:|--:|
| spectral mean / median | 6.6537 / 5.9766 | **6.6510 / 5.9766** |
| envelope mean / median | 2.0957 / 1.7701 | *2.0969 / 1.7701* |
| level, mean absolute | 1.6529 | **1.6528** |
| level, signed mean / median | +0.1749 / +0.0464 | *+0.1787 / +0.0646* |
| null depth mean / median | -6.6564 / -6.0802 | **-6.6582** / *-6.0558* |
| correlation mean / median | 0.76067304 / 0.875526 | *0.76065424 / 0.874448* |

The spectral mean, absolute level and mean null depth improve. Signed level does
not: its mean rises 0.003803 dB and its median rises 0.0182 dB. Patch 066 leads
the arithmetic rise at -0.0587 -> +0.0150 dB (delta +0.0737). Its stored mix 120
raises oscillator 2 from the displayed 0.94 to 0.94488. More generally the
measured unrounded law raises it at the low-to-middle readings 32 and 64, from
0.25 and 0.50 to 0.25197 and 0.50394, and lowers it at 96 from 0.76 to 0.75591.
Of these 123 rows, 105 store a mix below 96; those rows contribute +0.3039 dB
to the total +0.4678 dB signed level change. The small positive bank mean is
therefore a measured output shift from redistributing gain on a bank weighted
toward low-to-middle mixes, not an improvement hidden by absolute level.

The other named regressions are the envelope mean, up 0.00124 dB and led by 033
at 5.9888 -> 6.0602 (the only envelope regression above 0.05 dB); the null
median, row 063 at -6.0802 -> -6.0558, while the null mean deepens by 0.00180 dB
and no patch's null becomes 0.05 dB shallower; and correlation, whose mean falls
0.00001880, led by 033 at 0.436125 -> 0.432172, and whose median is row 063 at
0.875526 -> 0.874448.

At CSV precision, the remaining summary movers are also accounted for.
Brightness mean moves -0.110135 -> -0.110312 octaves (delta -0.000177), led in
signed movement by 111 at +0.223054 -> +0.213531, while its median improves.
Tuning mean moves +5.719009 -> +5.719279 cents (delta +0.000270), with the
largest signed move 053 at -0.57 -> -0.50 cents, while its median also improves.
Those leaders move toward zero even though cancellation makes each signed mean
slightly farther from zero. Stereo-width mean improves by 0.00000244; its median
and both release-length and time-to-peak aggregates do not move. The directly
measured gain law is not chosen by these interactions with the bank's other open
defects; the numbers explain rather than hide the small aggregate regressions.

### A correction to this document's own record

The former text said each gain equalled the displayed percentage and that the
binding was already correct. Its three quoted non-endpoint readings already
contained the contrary result, rounded to three decimals. Printing five decimals
and checking the residual on both sides of the rounded display exposes it.

### The cause was the oscillator phase, and it was wrong three ways

What led there was an impossible reading. Patch 068 mixes two pulses at the *same*
pitch, and the reference returns a second harmonic **11.4 dB above** its
fundamental. No pulse wave can do that: the ratio of the two is `|cos(pi * duty)|`,
at most one for any duty. Only cancellation between the two oscillators reaches it.

`s1probe phaseprobe` sweeps parameter 91 against two same-pitch pulses and finds
three nulls:

```
  stored 48   the third harmonic cancels     -> a sixth of a cycle
  stored 64   the second harmonic cancels    -> a quarter
  stored 127  the first and third cancel     -> a half
```

Three independent nulls on one line through the origin. The binding was wrong on
every part of it:

- **The offset went to all three oscillators equally.** A common start phase is
  inaudible in a steady tone, so parameter 91 could not change any *relationship* —
  which is the only thing it does. Now only oscillator 2 carries it.
- **The scale was a full turn across the knob.** Measured: half a turn.
- **Stored zero was treated as a phase of zero**, putting the two oscillators in
  perfect coherence. That is not merely a different choice from the reference's, it
  is the pathological one: two identical waveforms at identical pitch in exact phase
  put every partial at its maximum. The changelog entry that introduced the knob is
  explicit — turned fully left, *"the phase is not fixed (as before)"*. This matters
  for the whole bank, not a corner of it: every `ver=105` patch omits parameter 91
  and takes this default.
- **Parameter 92's unison spread applied regardless**, where the same entry says it
  "is not effective unless the phase is fixed in the oscillator section".

The free-running offset itself is measured, and the first reading of it was wrong
by a sign — see [069 Oboe, and three phase errors in the
oscillator](#069-oboe-and-three-phase-errors-in-the-oscillator) and [The
oscillator start phase, read
absolutely](#the-oscillator-start-phase-read-absolutely) at the end of this
document. The reading that produced this section's 0.440 turns was a fit of how
far each harmonic is pulled down — 158 degrees from the fundamental's 14.5 dB,
5.4 predicted against 5.0 measured on the third — and it was the **same at three
notes an octave apart**, so the offset is a fixed initial phase rather than
accumulated history, and therefore reproducible. It was kept at 0.440 rather
than tuned: 0.480 was tried across the whole bank and is indistinguishable.

**What an attenuation fit cannot do is tell `+phi` from `-phi`.** Cancellation
between two same-pitch oscillators goes as `cos(2*pi*k*phi)`, which is even, so
both signs pull every harmonic down by exactly the same amount. The magnitude
above is right; the sign was never determined and came down wrong. Nor could
that fit say *which* oscillator carried the offset, for the same reason. Both
questions are now answered by reading each oscillator's phase absolutely against
note-on: oscillator 1 starts at zero, oscillator 2 at **+0.56233 turns**, one
constant for every shape. The 158-degree fit is the method this whole thread is
about; everything else in this section stands.

### What it bought

```
                   before    after
  spectral median   11.69    11.69
  envelope mean     11.76    11.25
  envelope median    9.51     9.35
  null depth mean   -1.37    -1.73
  level median      -3.56    -4.02
```

Envelope error and null depth both improve — the null deepening by 26% is the
strictest of the four and the hardest to move. Timbre is unchanged in aggregate and
level is 0.46 dB worse, which is the expected direction: cancelling where we
previously added makes us quieter.

Per patch the effect is much larger than the aggregate suggests. On 007 the
second-harmonic error collapsed from **+12.7 dB to +2.3 dB**, and both engines now
agree which harmonic is strongest.

068 is not fixed and is not explained. The reference cancels its fundamental far
harder than a 0.44-turn offset can, and the arithmetic does not close; its filter
tilt accounts for part but not all of the gap. Recorded as open rather than guessed
at.

## The worst patch, and the band pass

Single-parameter sweeps having run out, the next move is to take the worst patch and
strip it. That is 117.sy1, "Perc1", at 36.86 dB of spectral error and −36.71 dB of
level — the reference sits flat at −22 dBFS while our render wanders between −52 and
−85, which is to say inaudible.

Its settings say what it is: oscillator 2 is **noise**, the filter is **type 3, the
band pass**, its resonance is **127**, its cutoff **17**, and the filter envelope
amount is **127**. A percussion patch built entirely out of a high-Q resonant ping.

### The band pass threw away its resonance gain

The band-pass output of this filter topology peaks at Q, and `svf_pick` returned
`k * bp` with k = 1/Q, which normalises that peak to exactly one at every resonance.
The comment said so and called it a feature. It is not what the reference does.

Driving a saw through the band pass and sweeping the resonance:

```
  resonance      0      32      64      96     127
  reference  -10.5   -10.7   -10.5    -8.8    -2.9  dBFS
  ours        -8.9    -9.7   -10.9   -13.0   -21.7
```

The reference gets **louder** by 7.6 dB from bottom to top; ours got quieter by 12.8.
An 18.8 dB divergence at maximum resonance, on exactly the setting the worst patch in
the bank uses.

Neither extreme fits: keeping all of the resonance gain rises about 26 dB across the
range, keeping none of it is flat, and the reference wants 7.6. Treating the scale as
`k^a` and reading the exponent off the energy relation gives a ≈ 0.2, and 0.25 measures
well:

```
  resonance          0     64     96    127
  divergence before +1.6   -0.4   -4.2  -18.8 dB
  divergence after  -2.9   -0.7   -0.5   -3.8
```

**Patch 117's level error goes from −36.71 dB to −21.71** — 15 dB recovered on the
worst patch in the bank — and the bank's level mean improves from −1.64 to −1.51 with
spectral, envelope and null all unchanged. Eleven patches use this filter type.

The exponent is fitted to one sweep at one cutoff, which is worth saying plainly: the
*direction* and the *size* are measured, the exact power is not.

### What is still wrong with it

Its timbre error did not move at all, and that is not a contradiction: the fix is a
gain, and the spectral metric normalises gain away. Band by band, 117 is now diagnosed
rather than merely bad:

```
  band centre Hz      44      88     177     354     707    1414    2828    5657   11314
  signed mean     +30.7    -0.7    +4.7   +13.7   +27.0   +42.2   +43.1   +41.9   +40.3
```

We are **forty decibels too bright above 1.4 kHz**. The reference's energy sits at 88
to 177 Hz, where we agree with it to within a decibel, and everything above that is
ours alone.

### Four candidates eliminated, then the resonance

With noise feeding a high-Q band pass, the excess had to come from the noise, the
filter's shape, or the filter's order. Measuring each:

```
  the noise oscillator alone, filter open   0.90 dB       not the noise
  the resonant peak's Q, 1/6-octave         6.28 vs 6.58  not the peak width
  a four-pole band pass instead of two      18.25 dB      worse; not the order
  the same test at three cutoffs            13.7 / 14.7 / 19.3   rises, so not
                                                          low-cutoff precision
```

What the octave profile called a flat 14 dB stopband excess turned out to be a
selectivity difference the peak measurement had smeared. Comparing peak *and* width
across the resonance range shows both:

```
  resonance         0                64               127
  reference   269 Hz, Q 1.40    214 Hz, Q 1.99    214 Hz, Q 8.57
  ours        427 Hz, Q 0.36    269 Hz, Q 0.69    240 Hz, Q 6.05
  distance         2.31 dB          2.70 dB          14.65 dB
```

Our resonant peak is about 30% too wide at the top of the range, and our band-pass
centre sits above the reference's. The damping was `k = 2 - 1.9r`, a maximum Q of 10
nominal.

### Where it stops, and why

Raising the slope tracks the reference steadily — Q 6.05, 6.93, 7.72, 8.17 at slopes
1.90, 1.93, 1.96, 1.98, against the reference's 8.57, with the band-pass distance
falling 14.65, 13.24, 11.16, 8.89. And then the tests stop it: at 1.95 the filter rings
to **58 times** its input at a 20 kHz cutoff and at 1.98 to 40 times, and the
bounded-output tests catch both. Those bounds guard a real hazard and are not worth
relaxing for a metric, so 1.93 ships — the last value that stays bounded.

That is a limit of the topology rather than of the number: matching the reference's Q
needs a filter that stays stable closer to self-oscillation.

```
  patch 117               spectral   level
  at the start             36.86    -36.71
  after the band-pass gain 36.86    -21.71
  after the resonance      35.39    -21.05
```

Over the two changes the worst patch in the bank gives up **15.7 dB of level error**
and 1.5 dB of timbre. Bank-wide, spectral mean moves 10.12 to 10.08 and level mean
−1.64 to −1.38, with envelope and null unchanged — small, because eleven patches use
the band pass and five sit at the resonance where this bites.

## The spectral error: what it is not

With the level error down to a 0.82 dB median, timbre is the dominant metric at
10.12 dB mean and 9.25 dB median. `s1probe bandprofile` was built to attack it: it
renders both engines over the whole bank and averages the *signed* band difference,
energy-normalised, so a systematic tilt separates from patch-specific scatter.

Two things it established immediately.

**The worst band is below 600 Hz for 100 of 117 patches**, 64 of them below 200 Hz,
with worst-band errors of 37 to 44 dB. And there is a real tilt across the bank:

```
  band centre Hz      44      88     177     354     707    1414    2828    5657   11314
  signed mean     -11.7    -6.6    +1.4    +0.4    -2.4    -0.3    +1.3    +3.6    +5.6
  absolute mean    16.3    15.5     6.8     4.0     6.1     7.0     7.7     9.3    11.0
```

Short at the bottom, hot at the top, nearly right in the middle.

**The metric is not at fault.** Given the history in this file that was worth checking:
about a fifth of the 1/6-octave bands lie below a patch's fundamental at note 60 and
hold only each engine's residue, and the distance averages every band equally. But
restricting it to bands within 60 dB of the reference's loudest — 68% of them — makes
the error *higher*, 11.12 dB against 9.55. The empty bands were diluting it. Whatever
this is, it is in the bands that carry signal.

### Every stage checks out on its own

Controlled patches, one axis at a time, reported as the timbre distance over
signal-bearing bands:

```
  oscillators, all four waveforms   within 0.1 dB across the entire harmonic range
  filter cutoff, 7 settings         0.33 to 2.24 dB
  filter resonance at 0             0.46 dB
  two oscillators, detuned          2.69 dB
  filter envelope moving            1.26 dB
```

The waveform result is worth stating plainly, because it retires a suspicion: from the
fundamental up to 5.7 kHz our saw, pulse and triangle match the reference to within a
tenth of a decibel. Every difference sits in bands below the fundamental, which for a
single oscillator hold nothing but residue. Our oscillators are not the problem and
neither is their aliasing.

### One real defect, and it is rare

Resonance is the exception:

```
  resonance         0      32      64      96     127
  timbre distance  0.46   1.17    1.45    3.92   14.22 dB
```

At full resonance we are **+26.9 dB at 1.4 kHz and +30.3 dB at 2.8 kHz** — our filter
rings far harder than the reference's. On the bank it shows up exactly where it should,
and only there:

```
  resonance    patches   mean spectral
    0-15         55        10.26 dB
   16-47         27         9.25
   48-79         22         9.01
   80-111         8        11.29
  112-127         5        16.40
```

So it explains the tail and not the bulk. The 55 low-resonance patches still average
10.26 dB where the equivalent controlled patch measures under half a decibel.

### A 10 dB defect the bank cannot see

The sub oscillator measures **10.03 dB** on its own — the largest single-feature error
found, and suspiciously close to the bank mean. It is not the cause: **no patch in the
factory bank uses it.** Parameter 95 defaults to zero and all 128 leave it there, so
like the extra effect unit this is a real defect that the null test is blind to. Worth
fixing on its own terms; worth not mistaking for an explanation of the bank.

### Where that leaves it

No feature grouping explains the spread either — LFOs, delay, chorus, arpeggiator, FM,
sync and ring all sit within a decibel or two of 10, and several of the *off* groups
score worse than the on ones. Every stage measured in isolation is close to exact, the
combinations tried reach 2.7 dB, and the bank sits at 10.

The honest reading is that the remaining timbre error is not one systematic thing. It
is many small per-patch differences accumulating, on top of two identified defects that
are large but narrow: high resonance, and a sub oscillator the bank never exercises.
The next step is not another sweep of a single parameter — those are exhausted — but
taking the worst individual patches and removing their features one at a time until the
error moves.

## Why patches are quiet, and the decay's shape

The chorus probe turned up something larger than the chorus: on eleven of twelve
four-tap patches our whole output sat 3 to 16 dB below the reference's, present with
the chorus switched off. It is not those twelve patches either — across the bank, ten
patches are more than 20 dB down and eighteen more between 12 and 20.

### Splitting the level error in two

Correlation found nothing. Level error against amp gain, amp sustain, cutoff, filter
sustain, filter envelope amount and velocity sensitivity all came back under
|r| = 0.15 over 123 patches; against the *extra decay*, resonance and both decays and
sustains and the attack all came back under 0.13. No single knob explains it.

The comparison already records peak and steady-state RMS for both engines, which
splits the error into the two things it can be:

```
  peak level, ours against the reference   -4.35 dB
  peak -> steady, reference               -17.74 dB
  peak -> steady, ours                    -21.75 dB
  our extra decay                          -4.01 dB
```

So it is about half a gain deficit at the peak and half our envelope arriving lower
by the time the steady-state window opens. Tracing the contour of the worst patches
makes the second half concrete — on 056 the reference falls 10.7 dB across the held
note and we fall **76.8 dB**, having started within 1.8 dB of it. The patches that
decay worst share a setting: amp sustain of zero, where the decay alone decides the
level and nothing holds the note up.

### The decay is exponential after all, and a bad measurement said otherwise

`envprobe` reports the reference's decay reaching −60 dB in only 5.14 times its time
to fall the first 6 dB, where an exponential gives exactly 10. Taken at face value that
says the decay starts shallow and steepens, and that our straight-line-in-dB
exponential is too steep exactly where a held note's steady state sits. A curve aiming
below the sustain was fitted to that ratio and shipped.

**It was wrong.** Comparing the two contours directly — the amplitude of both renders,
frame by frame, on a patch whose only moving part is the amp decay — shows the
reference falling in a straight line:

```
  decay 79, sustain 0, dBFS every 125 ms
  ref    -5.5  -9.4 -13.9 -18.3 -22.8 -27.4 -32.0 -36.7 -41.4 -46.4 -51.4 -56.9
         steps of 3.9, 4.5, 4.4, 4.5, 4.6, 4.6, 4.7, 4.7, 5.0, 5.0, 5.5 dB
```

That is 60 dB in about 1630 ms against a tabled 1631; at decay 96 it is 1.4 dB per
125 ms, or 5357 ms against a tabled 5230. Both settings are clean exponentials and both
match their own tabled times.

So the t(−6 dB) column disagrees with the contour by a factor of 1.83 while the
t(−60 dB) column from the same tool agrees with it. The fault is in that column, not in
the plugin, and the ratio built from it inherited the error. **A ratio between two
measurements is only as good as the worse of them**, and neither had been checked
against the shape it was supposed to be describing.

Reverting improved three of the four headline numbers — spectral 10.34 to 10.14,
envelope median 9.04 to 8.76, null −1.52 to −1.70 — and the contours now track within
about a decibel across the whole decay, which is the base-path offset rather than a
shape difference.

Splitting the decay and release constants is kept even though both are now ln(1000).
Giving the release the decay's constant during the experiment made it 25 times too
long, which the tests caught, and two separately named constants make that easier to
see than one shared number.

### The base-path residual: the measurement was wrong, not the engine

After the pan and limiter fixes a constant offset remained — a bare sine with the
filter open and every effect off sat 0.80 dB under the reference, and the same
0.80 dB appeared on every setting of an amp gain sweep and every setting of an amp
sustain sweep. A constant ratio on a signal path with almost nothing in it.

The engine turned out to be innocent. Our output amplitude was 0.751 and
`AMP_GAIN_AMPLITUDE[127]` is 0.750231, so the voice was doing exactly what its table
said. Measuring the reference directly at the same note gave 0.823.

**The table generator's analysis window ran past the note off.** `level_amplitude`
took the RMS from 100 ms to the *end of the array*, and `probe_render` appends a tail
after the held portion. With a 0.5 second hold that tail is silence, and an RMS over a
window that is part silence reads low by the square root of the sounding fraction:

```
  sounding 19776 of 23872 samples  ->  sqrt(0.8284) = 0.9102
  0.750231 / 0.9102 = 0.824        ->  matches the 0.823 measured mid-sustain
```

0.9102 is 0.81 dB, which is the residual to two decimal places. Fixing the window and
regenerating gives a full-gain amplitude of **0.82529**, and the bare sine now matches
the reference at **0.0 dB** across the whole note.

Two things about this are worth keeping.

It hid for a long time because the bias is one constant factor, so the table's *shape*
was untouched: a gain sweep tracked the reference perfectly across eight settings and
only the absolute scale was wrong. The sustain curve escaped entirely, being a ratio of
two numbers biased identically — which is why the sustain sweep measured exact while
the gain sweep was uniformly 0.8 dB low.

And a unit test asserted the wrong value with confidence. `test_amplitude_tables_are_a_
monotonic_curve` required full gain to land near 0.75, because it was written from the
same measurement it was checking. **A test derived from a measurement cannot catch that
measurement being wrong.** What caught it was comparing our render against the
reference's on the simplest patch that could be constructed.

```
                    level mean   level median   within 1 dB   within 2 dB
  before               -2.47        -1.65           10            19
  after                -1.64        -0.82           20            32
```

Nothing else moves: spectral 10.14 to 10.12, envelope and null identical. Over this
investigation as a whole the level median went from −4.67 dB to −0.82.

### Where the envelope error is not

With controlled patches — one oscillator, the filter open or explicitly swept, every
effect off — all three parts of the envelope path check out against the reference:

```
  amp sustain, 8 settings     constant -0.85 dB offset, shape exact
  amp decay, 2 settings       contours track within 1 dB
  filter sustain, 5 settings  within 0.8 dB
```

The −0.85 dB is the base-path residual left after the pan and limiter fixes, not an
envelope error. So there is no systematic envelope defect left to find here. The bank's
remaining "extra decay" statistic is peak-to-steady for each engine, so it moves with
the peak as much as with the decay — and it preferred the curve the contours disprove,
which is the clearest possible sign that it is not measuring what its name says.

### The peak deficit: two bugs, both on every patch

The peak deficit turned out to be the easiest thing in this file to find, once it was
looked at in the right place. Correlation was useless again — resonance, amp gain,
cutoff, filter envelope amount, attack, oscillator shape, mix and FM amount all came
back under |r| = 0.21 — and the distribution ran from −33 dB to +6, so it was not one
constant either.

The clue was in an old control run. The effect unit's bypass check had reported a level
error of −4.36 dB on a bare sine with the filter open and every effect off. That is the
same number as the bank-wide peak deficit, on a patch with almost nothing in it, which
says the fault is in the signal path everything shares. A minimal patch confirms it — a
flat **−4.4 dB, constant across the whole note**:

```
  ref    -4.7  -4.7  -4.7  -4.7 ...
  ours   -9.0  -9.0  -9.0  -9.0 ...
  diff   -4.4  -4.4  -4.4  -4.4 ...
```

**Three decibels of it was the pan law.** Ours was equal power: at the centre each
channel gets `cos(45°)` = 0.707, which is exactly the right thing for keeping level
constant while a voice sweeps across the image, and 3 dB down on a law that passes
unity there. Sweeping parameter 90 through the reference measures 6.0 dB from hard
left to centre where an equal-power law gives 3.0. The half-panned point picks between
the candidate laws, since they disagree there too:

```
  pan                        -1.0    -0.5     0.0
  min(1, 1-pan) / min(1, 1+pan), mid   0.50    0.75    1.00
  predicted, dB from centre  -6.0    -2.5     0.0
  measured                   -6.0    -2.5     0.0
```

So the reference attenuates the channel you pan away from and leaves the other alone.
The cost is that total power rises 3 dB toward the centre, which is what an equal-power
law exists to prevent — and it is what the reference does.

**One more decibel was the output limiter.** Ours was tanh-like at every level, so it
attenuated everything, not just the loud parts: at an amplitude of 0.75 it returned
0.645. There is also nothing to be faithful to, because the reference does not limit at
all — probing the effect unit measured its peaks at +19 and +30 dBFS. The limiter is
now transparent below full scale and asymptotic to 2 above it, which keeps this
engine's own contract without colouring the level of everything underneath.

```
                     level mean   level median    peak    within 6 dB
  before                -5.26        -5.01       -4.36      58/123
  after                 -2.25        -1.98       -1.16      68/123
```

A 3 dB improvement in level error and 3.2 dB of the peak deficit recovered, at no cost
anywhere else: spectral moves 0.03 dB, envelope improves 0.08, the null is unchanged.
It is the cleanest result in this file, and both halves of it had been sitting on every
patch in the bank since the beginning.

What is left of the level error is the decay's 3.84 dB, bounded as described above by
how few patches have a sustain low enough for the decay shape to reach the
steady-state window.

## The tuning column was measuring the wrong thing

For most of this project the summary carried a line reading `8 an octave out`, and
it was wrong. **No patch in the bank is out of tune.** Ten were checked
individually against the reference with an instrument that cannot be fooled — the
level of every harmonic of the note actually played, in both renders — and every
one of them has its partials at identical frequencies:

```
007.sy1  reference h1 -2.9 h2 -12.7    ours h1 -5.3 h2  0.0    reported +1200 cents
068.sy1  reference h1 -11.4 h2  0.0    ours h1  0.0 h2 -6.8    reported -1200 cents
110.sy1  reference h1 -1.8 h2  0.0     ours h1  0.0 h2 -1.7    reported -1200 cents
```

On 110 a **3.5 dB** difference in the balance between the first two harmonics was
enough to report a full octave of detuning, because the metric took each render's
loudest bin as its pitch. That is a fine way to find the brightest partial and a
bad way to measure tuning.

Fixing it took three attempts, and each failure is worth recording because each was
a different way for a plausible metric to be confidently wrong.

**Attempt one: log-frequency cross-correlation.** If our spectrum is the
reference's shifted along a log-frequency axis, the shift that aligns them is the
detuning, whatever the relative heights of the partials. This flipped *which*
patches were flagged — 110 was fixed — but still reported thirteen an octave out,
almost all negative.

**Attempt two: the tilt confound.** Printing the whole correlation curve showed why.
On the flagged patches it fell monotonically — `-1200: 0.777, -700: 0.705,
0: 0.654` — which is not two competing peaks, it is a slope. Our renders are darker
than the reference's, so shifting our spectrum *down* lines our roll-off up with
theirs. The reading was reporting spectral tilt and calling it detuning. Whitening
each profile first (subtracting a one-octave moving average, a high pass along the
log-frequency axis) removes the envelope and leaves only where the partials are.
After that, all five patches checked reported within 2 cents.

**Attempt three: harmonic rivalry.** A harmonic series still correlates with itself
an octave away — its partials 2, 4, 6 land on 1, 2, 3 — so near-equal rival peaks
remain, decided by exactly the amplitude balance the metric is supposed to ignore.
Two guards settle it: a penalty for distance from zero, so an octave must be
genuinely better rather than merely tied; and a requirement that the winning peak
stand clear of any rival more than half an octave away. Patch 091 is why the second
one exists — it scored 0.72 at +700 cents with 0.62 at −700 and **−0.30** at zero,
which is not a tuning measurement, it is two bad alignments of two spectra that do
not match. The patch is exactly in tune.

The final metric agrees with itself: confidence predicts the reading, monotonically.

```
  gate      n   median |cents|   within 10 cents
  >= 0.20  111       226.7            45
  >= 0.40   52         4.7            28
  >= 0.60   17         1.0            13
  >= 0.80    9         0.8          9 of 9
```

Where it is confident, everything is in tune. The cost of honesty is coverage: it
now reports on 18 of 123 patches and excludes 105 as "the two spectra do not align
under any shift". That exclusion is itself the finding — with a spectral error near
12 dB, most of this bank's timbres differ too much for tuning to be measurable from
the spectrum alone.

### What those patches were actually doing

Two real differences, neither of them tuning:

- **Harmonic balance.** On 007, 037, 068 and 110 the series is right and the
  relative levels are off by 3 to 13 dB, which for a two-oscillator patch points at
  the mix or the relative oscillator level.
- **Residual floor on heavily-filtered patches.** 045 and 091 both pair a *negative*
  filter envelope amount with a high filter sustain, so the reference drives the
  filter nearly shut and returns an almost pure tone — its 12th harmonic is 99.5 dB
  down. Ours is 66.9 dB down, and both renders are quiet in absolute terms
  (RMS 0.0094 against 0.0133, a 1.4× difference). At that level the reference's high
  harmonics are its own numerical floor, so the 32 dB "excess" is our residual floor
  sitting above theirs, not a filter that failed to close. The binding computes
  about 25 Hz of cutoff for 045, which is correct.

### One process failure

Adding two columns to the comparison CSV without updating the format string put 34
values through 32 specifiers. Nothing errored. The summary reported a stereo width
of −47.9 where the truth is −0.07, along with wrong counts on four other metrics,
and it took a second look at an implausible number to catch it. There is now a test
that writes a row and compares its field count to the header's.

## The extra effect unit

One slot, ten types, two general-purpose controls and a level: parameters 77 to 81.

This is the least observable section in the plugin, and the first thing to say
about it is that **the null test cannot see it at all**. Every one of the 128
factory patches stores 77 = 0, so the bank comparison can confirm that nothing
regressed and nothing else. This feature's oracle had to be built separately.

It is also the least documented. The English readme does not mention the section.
The Japanese manual names six types and gives the meaning of both controls for
each — but parameter 78 has **ten** states. The missing four turned up in the
changelog rather than the manual: v1.07 adds `Phaserの追加`, and the type table was
never updated for it. The user confirmed the plugin's own LCD reads

```
a.d.1   a.d.2   d.d.   deci.   r.m.   comp.   ph1   ph2   ph3   ph4
```

which the probe then corroborated independently, one type at a time. That
corroboration was not ceremony: the state *order* of parameters 0, 1, 41, 42, 46
and 47 all disagree with the order their documentation lists, so a name list is a
hypothesis until the signal agrees with it.

### Naming a nonlinearity from what it does to a pure tone

| type | what the probe saw | why that is the name |
|---|---|---|
| `a.d.1` | even harmonics dominate at low drive, −22.6 dB against −43.1 dB odd; fundamental **cut** 2.6 dB | the manual's "even-order harmonics" and "low-frequency attenuation from negative feedback" |
| `a.d.2` | **purely** odd, −46.5 dB against −103 dB even; fundamental **boosted** 5.5 dB | an odd-symmetric shaper cannot make even harmonics at any drive. The exact complement of a.d.1 |
| `d.d.` | the most aggressive of the three; ctl2 walks the spectral peak from the 3rd harmonic to the 39th | ctl2 is a low-pass corner |
| `deci.` | inharmonic content climbs −40 → −9.8 → −3.0 dB with ctl1 | nothing that only reshapes a waveform can do that; aliasing can |
| `r.m.` | fundamental annihilated 102 dB, sidebands straddling it, **ctl2 inert at every setting** | the manual says r.m. has no second control |
| `comp.` | overshoot to +29 dB, growing with both controls; THD *falls* −6.7 → −59.9 dB as ctl2 rises | ctl1 = depth, ctl2 = attack: a slow attack cannot move the gain within a cycle, so it cannot bend the wave |
| `ph1` | THD of −89.5 dB — a linear filter, 77 dB cleaner than the compressor beside it | an allpass chain adds no harmonics |

### Two mistakes in the method, both caught by the measurement

**Aliasing turned distortion into "inharmonic content."** The first version of this
probe used a 1397 Hz tone so that twelve harmonic windows would span the analysis
band. But the reference does not oversample its distortion, so a clipped tone
folds its high harmonics back to `|k·f0 − n·48000|` — and since 48000 is not a
multiple of 1397, those folded partials land *between* the harmonic windows.
Ordinary waveshaping read as the signature of a ring modulator. Fixed by dropping
to a 130 Hz fundamental and raising the window count to 128, so all 122 in-band
harmonics have a window and the inharmonic bucket holds only what no waveshaper
could have produced.

**The decimator was measured in the wrong domain.** Inferring a sample rate from
image positions gave readings that swung 15 dB between adjacent settings while the
control moved smoothly, because images cross in and out of the harmonic windows as
the rate sweeps. A decimator's output is *literally a staircase*, so the second
attempt read the step length off the samples — and got an exact answer at every
setting. Worth remembering as a general point: when an effect has a time-domain
structure, measure the time domain.

### What came out in real units

```
low-pass corner, shared by all three distortions, measured with noise
  ctl2        0     16     32     48     64     80     96    112
  corner    452    719   1150   1827   2901   4590   7212  11140   Hz
```

The three distortions agree to within 0.5% — tighter than the measurement's own
resolution — so it is one shared filter. A clean exponential at 0.0416 octaves per
step, 452 Hz to about 17.6 kHz. Noise rather than a sine, because a sine's only
test frequencies are the distortion's own harmonics and those move when the drive
moves, so filter and drive could not otherwise be separated.

```
ring modulator frequency, from the sideband positions
  ctl1       24     32     40     48     56     64     72     80 ...  127
  fm        5.5    9.6   17.0   29.8   52.6   92.7    163  287.5 ... 7869   Hz
```

A constant ×1.762 per 8 steps across fourteen settings. This one control is the
only place in the section where a real unit is recoverable directly, because
multiplying a carrier by `fm` states `fm` outright in the sideband spacing. There
are two branches and using only the first is wrong over most of the range: while
`fm < f0` the sidebands straddle the carrier and their half-separation is `fm`,
but once `fm > f0` the lower one has reflected through zero and it is the pair's
*centre* that becomes `fm`. Reading half-separation throughout reports a frequency
that rises to `f0` and then stops.

```
decimator step, read off the waveform
  ctl1       56    64    72    80    88    96   104   112   120   127
  hold       47    55    63    71    79    87    95   103   111   118   samples
```

Exactly `ctl1 − 9`, at every setting tried. Two details recorded rather than
smoothed over. The steps are followed by a damped ring lasting about nine samples,
which is the reference's own reconstruction filter and is not modelled here. And
this was measured at 48 kHz only, so whether the reference holds for a fixed
number of *samples* or a fixed *time* is unestablished; it is treated as a time,
since the manual calls the control a sampling frequency.

```
decimator depth, by counting distinct output values with the rate reduction off
  ctl2       64     72     80     88     96    104    112    120
  levels   4301   2236   1214    613    308    159    105     73
```

Halving every 8 steps — one bit per 8 steps. Both ends carry a known bias and are
treated as bounds: the counter saturates against its own limit below ctl2 32, and
at the top the count reflects how many levels a sine of that amplitude visits
rather than how many exist.

The compressor's attack came out at 2 ms to 190 ms, with the two independent
confirmations in the table above.

### The level knob, and a generalisation that was wrong

Parameter 81 was measured against the ring modulator first, because that is the
one type whose dry and wet spectra are disjoint enough to separate:

```
  level        0     16     32     48     64     80     96    112   127
  dry gain  1.000  0.871  0.750  0.624  0.496  0.372  0.245  0.117    0
  1 - L/127 1.000  0.874  0.748  0.622  0.496  0.370  0.244  0.118    0
```

A linear crossfade, worst deviation 0.003, with level 0 **bit-identical** to the
unit switched off. That result was then applied to all ten types, and it was
wrong for eight of them.

The direct A/B is what caught it. At level 0 the unit is bypassed, so the ten
types should have produced *identical* rows; only two did. Going back to the
reference showed that `deci.` and `r.m.` are the only types that crossfade at all.
The manual had said so in a clause that is easy to read past — "level: 効果の量、
または原音とのバランスを調整します", the *amount* of the effect, **or** the balance
with the original sound. The "or" is load-bearing.

Three laws, all measured:

- **`deci.`, `r.m.`** — a dry/wet crossfade, as above.
- **the three distortions** — wet only, no dry path at all, at a gain linear in
  amplitude (`L/127`, fitting 8 of 9 points to within 1.4%). Every shape reading
  is *identical* at all nine settings, so the knob is an output gain and not a
  drive.
- **`comp.`** — wet only again, but linear in **decibels**: a constant 3.8 dB per
  16 steps over a 30 dB range. Deliberately not made to match the distortions,
  because nine points say it does not.

The lesson is narrower than "measure more". It is that a parameter shared across
ten types is not one parameter, and the type chosen *because* it made the
measurement easy is the least safe one to generalise from.

### Ours against the reference

No factory patch exercises this section, so the comparison is against synthesised
patches: a single sine with everything else switched off, rendered through the
reference DLL and through our statically linked engine in the same process.

```
                          spectral  envelope     level     null
  deci. / r.m. at level 0     1.02      0.07     -4.36   -33.30   <- the floor
  comp.                       0.87     15.19     +5.68   -16.41
  ph1                         3.10      9.66     -9.35    -5.51
  ph2                         3.68      9.18     -4.31    -4.77
  a.d.2                       6.07      1.74     -6.01    -6.89
  r.m.                        6.24      0.46     -4.23    -2.11
  a.d.1                       6.46      1.51     +2.73    -5.02
  ph3                         7.79     14.00     -6.07    -0.79
  deci.                      12.68      0.18     -4.34    -7.93
  ph4                        14.90     14.28     -7.08    -0.34
  d.d.                       15.75      1.49     +5.03    -0.13
  mean 7.75 dB over ten types
```

The first row is the control: with the unit bypassed our render of the same patch
scores 1.02 dB with a −33 dB null, so everything above that is attributable to
this code and not to the rest of the engine. The mean of 7.75 dB sits below the
bank-wide median of 11.69, which is expected — these patches are a bare sine, so
almost nothing else is in play.

Where it is worst is where the curve was chosen rather than measured. `d.d.` and
`ph4` are the two ends of that: the digital distortion's transfer curve and the
phasers' control laws are the parts still guessed. `comp.` is the interesting
case — 0.87 dB of spectral error, better than the floor, and 15.19 dB of envelope
error. The timbre is right and the dynamics are not, which is a precise
description of what to fix next.

One honest gap in the control row: at level 0 the three distortions and the four
phasers read "n/a" rather than a score, because our output there is exactly silent
while the reference leaves about −36 dB of wet signal. `L/127` gives a hard zero
at the bottom of the knob. It is inaudible, and adding a floor would risk fitting
the plugin's own noise, but those rows are unscored rather than passing.

### What is still guessed

- the three distortion transfer curves — the harmonic *signatures* are measured
  and the shapers reproduce them, but the curves themselves are chosen
- ~~the phasers' depth curve and level law~~ — both measured, and the level law
  turned out not to be a level at all: see "The phasers: it was a stage count
  after all" at the end of this document
- the decimator's post-step ring
- ~~the compressor's threshold and ratio, and its envelope error~~ -- measured,
  and it was neither a threshold nor a ratio: see "The compressor is a leveller"
  at the end of this document

### The phasers, and three instruments

The phasers were the loose end of the effect unit, and getting them wrong three
times is more instructive than the answer.

**A single test tone cannot measure a filter.** The first attempt held a sine and
counted how often the level crossed its own mean. It returned 47, 6.67, 1.33, 3.67
and 15.33 Hz for five settings of one control — not a rate curve. One tone samples
the transfer function at exactly one frequency, so all it can say is "something
went past", and with N features sweeping there are N dips per cycle. The count
moves with the feature count and the sweep range as much as with the rate.

**A saw wave is the fitting instrument.** It is a dense harmonic comb, so one
render samples the transfer function at 80 known frequencies at once, and every
feature is visible in every frame instead of only when it crosses one tone. And it
is *deterministic*, unlike noise: dividing its harmonic magnitudes by the same
patch with the unit off gives the transfer function directly, with no averaging
needed to beat down a stochastic input. Two drives 6 dB apart returned the same
transfer function, which is the check that a linear filter is what is being
measured.

The first thing it showed is that the section is **not a phaser in the usual
sense**. There is no comb of notches — not one dip anywhere in any frame stands
3 dB clear of its neighbours. There is a single broad *resonance* that sweeps. Read
at ctl1 = 0, where the sweep stops and there is no time smearing at all, the shape
is exact: a flat skirt at **−13 dB**, a peak of about **+24 dB** at the corner, and
a return to **0 dB** above it. And ph1 to ph4 are one shape at four frequencies:

```
  type      ph1    ph2    ph3    ph4
  centre   2878   3924   5494   6540   Hz
  peak      +23    +26    +25    +24   dB
```

Not a stage count, which is what had been assumed.

> **This conclusion is wrong**, and the correction is at the end of this
> document. Only the tallest peak of each type was read. Sweeping a held tone
> down to 55 Hz finds one more resonance per type, counting out to exactly one
> for ph1 through four for ph4, so it is a stage count after all — with
> feedback turning what would be notches into resonances.

**The rate needed a third instrument.** Tracking the resonance's own trajectory
failed differently from the sine: the resonance leaves the analysis window at both
ends, so the trajectory saturates into a plateau, and where two maxima compete the
argument of the maximum jumps between them. That read 7.47 Hz where the numbers
underneath plainly showed a 277 ms period.

Autocorrelating the **whole spectrogram** needs no feature to be identified at all.
Whatever the response is doing, it returns to the same shape once per cycle, so the
lag at which the spectrogram best matches itself *is* the period. Every harmonic
contributes, so a resonance leaving the window costs a little correlation instead
of corrupting a tracked point. That, plus two guards, gave the two control laws:

```
ctl1 is the depth. At zero the resonance is static at 2878 Hz -- a measured span
of 0.00 octaves -- and the rate is unchanged at every depth, so the controls are
independent.
  ctl1        0     16     32     64     96    127
  band     2800   2923   3057   3304    131    131   Hz
           2800   6839   7781  10465  10465  10465

ctl2 is the rate. Exponential, 2.33 times per 16 steps.
  ctl2       48     64     80     96    112
  rate     0.27   0.65   1.51   3.61   7.81   Hz
```

The two guards matter as much as the method. Autocorrelation has an octave error —
a signal with period P also matches itself at 2P — which had three types reporting
277 ms and the fourth 555 ms at a *lower* correlation; preferring the earliest
strong local maximum fixes it. And when the true period is longer than the search
can reach, correlation simply falls away from the first lag examined, so the
maximum lands on the search's own lower bound. Every spurious "43 ms period" was
that: 43 ms is one analysis window, reported with a correlation of 0.99, which
reads exactly like a confident answer. The probe now says "no period resolvable"
instead, at both ends of the range.

### What was done with the result, and what was not

The measured structure was implemented — a swept resonant high pass with dry mixed
back at the measured skirt level — and compared against the shipped allpass version
at two operating points:

```
                      ph1    ph2    ph3    ph4   mean    level error
  ctl 64/64  allpass  3.07   3.41   7.89  15.00   7.34   -4 to -9 dB
             resonant 2.42   2.86   8.32  15.56   7.29   -16 to -22 dB
  ctl 112/96 allpass 12.64  25.61  35.66  44.72  29.66
             resonant 17.02  17.30  34.31  44.58  28.30
```

A tie on timbre and a consistent 10 to 13 dB loss on level, so the allpass version
stays and the finding is recorded instead. The level gap has a specific cause: the
resonance sits in its own −13 dB skirt for most of each cycle unless the corner
sweeps below the note being played, so the **depth curve** decides the output
level — and the depth curve is the one reading the saw comb could not finish,
because at high depth the resonance leaves the window and 131 Hz is the window's
floor rather than the sweep's. The phasers' **level law** is unmeasured too: at
level 0 they come back *louder* than bypass and broadband, fitting neither of the
two laws the other six types follow.

The measured rate law was kept, since it is solid and isolating it changed the
aggregate by 0.01 dB.

One process note, because it cost more than everything else here. The first four
comparisons of the resonant version were run at ctl 112/96 against a baseline
recorded at ctl 64/64, and read as a 20 dB regression that did not exist — at equal
settings the resonant version was slightly *ahead* on timbre. A baseline is only a
baseline at the same operating point, and "one change at a time" has to include not
changing where you measure.

### A side-finding

The changelog also settles a question left open when the delay was built.
Parameter 82's three states are named there but not in the manual: v1.07 alpha
lists `ノーマルステレオ(ST)、クロスフィードバック(X)、ピンポン(PP)`. So in order they
are normal stereo, cross feedback and ping-pong — which makes state 1 the
cross-fed one, confirming what had been a guess, and state 2 ping-pong.

## The equaliser

One parametric peak plus a tone tilt, which is what the manual describes and what
the parameters confirm. Two of the four carry real units: parameter 61 reads out in
hertz from 50 Hz to 16 kHz, parameter 62 in decibels from −25.2 to +24.8. The Q
curve and the tilt's corner frequencies are chosen.

There is no on/off switch for this section and it does not need one -- parameter
62 displays exactly "0.0 db" at stored 64 and the tone is flat at its own centre --
so a patch that leaves both alone passes through untouched. The defaults are flat,
so patches that omit these parameters are unaffected too.

The aggregate effect is small because the section is rarely used: only 7 of 128
factory patches move the level and 22 the tone. Split by whether a patch touches
it, which is the check that it is doing the right thing in the right places:

```
uses the equaliser : n= 23  spectral -0.72 dB   level -5.07 dB
left flat          : n=100  spectral +0.00 dB   level -0.05 dB
```

The improvement is concentrated where it should be. The level cost on those 23 is
the tilt: its corners are chosen, and it is evidently cutting more than the
reference's does.

### One trap, and one bug it uncovered

Parameter 61's display switches units partway up its range -- "915.0 Hz" then
"3.9 KHz" -- so reading the leading number alone turns 3.9 kHz into 3.9 Hz. Three
orders of magnitude, silently, across the whole top half of the knob.

Chasing why patches with a *flat* equaliser had changed at all turned up something
worse. The centre of a 128-state knob is state **64**, and the reference says so in
three places: parameter 90 displays "center" at 64 between "L 2%" and "R 2%",
parameter 11 displays "00" between "-01" and "+01", parameter 62 displays "0.0 db".
The two halves are therefore not the same size -- 64 steps below, 63 above.

The binding used `2 * unit - 1`, which at state 64 returns 0.0079 rather than 0. So
the equaliser's tilt, the delay's tone and **the pan of every voice** all carried a
small permanent offset, in the same direction every time. `centred_position` scales
the two halves separately and hits zero exactly.

Its effect on the null test is below the metric's resolution -- spectral 11.67 to
11.69 dB, level −3.61 to −3.56 -- and it is kept anyway, because the reference's own
displays say where the centre is and a systematic bias that hides inside an
aggregate is worth removing whether or not this particular aggregate can see it.

### What is left in the envelope

The residual on comparable patches is a shape difference rather than a timing one.
The decay and release measure t(-60 dB)/t(-6 dB) of 8.86 where a pure exponential
gives exactly 10, so the reference is slightly slower than exponential early and
faster late -- the shape of an exponential aimed past its target and stopped on
arrival. `src/dsp/envelope.odin` is a pure exponential. It is a small effect, worth
perhaps a decibel or two, and it is the next thing here after the effects.

### A confound worth recording

The first attempt to measure the FM change compared against a CSV produced by an
`s1probe` binary built *before* the envelope table was regenerated at higher
resolution. The engine is statically linked into the tool, so that baseline still
had the old table compiled in and the comparison mixed two changes together. The
numbers above come from a rebuilt baseline with only the FM change stashed.

The lesson generalises: `s1probe` embeds `src/engine`, so **any** measurement of
an engine change has to rebuild the tool, and a stale binary will quietly report
a mixture. Two full-bank runs of identical code are byte-identical across
processes, so anything else that moves is a real change to something.

The spectral error rose slightly because it is averaged over a *larger* set: eight
patches that previously had no sustain left to analyse now do, and they are not
good ones. The level error rose because our notes now last as long as the
reference's, so more energy is in the render — which points at the amplitude gain
curve, itself still a guess, as the next thing to measure.

What the test says about the guesses `docs/architecture.md` and the source
comments flag:

- **Envelope times — measured, fixed.** See the next section. This was the
  largest single defect; the release curve was short by a factor of five.
- **The filter cutoff mapping is close to right.** Median brightness error is
  −0.02 octaves. The invented 20 Hz–20 kHz curve is not the problem.
- **Tuning is exact for the majority and badly wrong for a minority.** The median
  is +0.3 cents, but a third of the comparable patches are off by more than 50
  cents and 6 by a whole octave. That is a discrete defect in a handful of code
  paths — the sub oscillator octave, oscillator 2's key-track-off pitch, or the
  unison pitch offset — not a mapping curve.
- **Stereo width is roughly half the reference's**, which is the chorus that
  `bind_patch` deliberately does not implement.
- **The null depth is uninformative**, as expected. It will stay that way until
  the phase-independent metrics are close, and it is kept for the day they are.

The worst patches by timbre (`128`, `056`, `063`, `126`, `110`) are where to look
for a missing feature rather than a mis-set constant.

## The envelope curve

`src/engine/binding.odin` used to map a stored 0..127 envelope parameter onto
seconds with a curve its own comment called chosen rather than measured: 1 ms to
12 s, exponential. `s1probe envprobe` and `s1probe envtable` replace it with the
reference's own curve.

```
build/s1probe.exe envprobe release --values all --csv build/env-release.csv
build/s1probe.exe envtable src/engine/envelope_table.odin
```

**Method.** A probe patch isolates the amplitude envelope: sine oscillator alone,
filter wide open with its envelope amount centred *and* its own envelope pinned
flat, delay, chorus, extra effect unit, both LFOs, arpeggiator, portamento,
unison and sub oscillator all off, velocity sensitivity zeroed. Each segment is
measured with the other three made degenerate — attack with sustain at maximum,
decay with sustain at zero, release with an instant attack and full sustain. One
setting per render, 128 settings per segment, and the render length doubles until
the segment fits inside it.

Two details are load-bearing, and both were found by the measurement disagreeing
with an assumption:

- `--dump` prints what the *plugin* says the probe patch is set to, rather than
  what the tool intended. The first version set parameter 21 (filter envelope
  amount) to a stored 0 expecting "no modulation"; that parameter is a direct
  state index whose states start at "−63", so it was at full negative amount and
  the filter envelope was sweeping the cutoff through every render while the tool
  reported the result as an amplitude envelope.
- Attack and decay run while the note is held, so both must be measured strictly
  inside the hold. Letting the search run past note off measures the release
  instead and still returns a plausible number: an unconstrained version reported
  the decay saturating at 510 ms and the attack at 450 ms for every setting above
  the middle of the range — which was the length of the hold it happened to be
  using.

**What the reference's envelope turned out to be.** Both shapes were measured
rather than assumed, and both match what `src/dsp/envelope.odin` already does:

- The **attack is a straight line**. Across every setting slow enough to resolve,
  the time to half level is 0.556 of the time to 90%, which is the linear ratio
  exactly; an exponential approach would give 0.30.
- **Decay and release are exponential**, with t(−60 dB)/t(−6 dB) of 8.9 against
  the ideal 10 — slightly faster than exponential in the last stretch, which is
  consistent with the voice being cut at a floor.

The ranges are much wider than the curve they replaced: attack 3.5 ms – 28.7 s,
decay 8.8 ms – 43.7 s, release 9.6 ms – 41.5 s, against a guess that topped out
at 12 s. Decay and release agree with each other to within about 5% and are kept
as separate tables anyway, because 5% is larger than anything else left in them.

**Why a table and not a formula.** Above stored 24 the curve is a clean
exponential — log time rises 0.0684 per step, to four figures. Below it, it
flattens away from that line, and at stored 0 the release is *longer* than at
stored 1 (9.6 ms against 8.2 ms). That last one reproduces at four times the
analysis resolution and at two different notes an octave apart, so it is
something the plugin really does — most likely an anti-click fade that outlasts
the shortest real release. A formula fitted to the top four fifths of the range
and quietly wrong across the rest is how the previous curve got there.

**Note independence.** The measured times do not depend on which note is played:
the same sweep at C6 and C8 agrees to within 0.3 ms everywhere. That is what
licenses choosing the probe note purely for analysis resolution, which is what
C8 buys — the analysis frame must hold a whole cycle, so the note sets the finest
resolution available.

## The resonance, and an instrument that could not see past its own resolution

Patch 117 had been the worst in the bank for a long time, and by a margin: 35.39 dB
of timbre error against 21.34 for the next patch down. It is `Perc1` — a pulse and
a noise oscillator into a **band pass at resonance 127**, with a full-depth filter
envelope. A percussion sound built out of one resonant ping and nothing else.

It now measures **11.60 dB** and is not in the worst ten.

### Everything about it was the resonance, and the resonance was measured wrong

Three controlled patches locate the fault without needing 117 at all — noise alone
into the band pass, tracking off, the filter envelope pinned flat, at three cutoffs
five octaves apart. `bandprofile` on each returns a signed band difference that is
**flat in every band except the one holding the peak**:

```
  band centre Hz      44      88     177     354     707    1414    2828    5657
  cutoff 17         -0.1   +11.0   +10.4   +10.4   +10.5   +10.2   +10.6   +10.2
  cutoff 48        +14.2   +14.7    -0.4   +13.1   +13.5   +13.3   +13.7   +13.3
  cutoff 80        +18.4   +19.0   +17.8   +17.5   +16.9    -0.2   +18.2   +17.8
```

A flat excess across eight octaves is not a skirt-slope error — a wrong slope would
grow band by band. It says the two filters agree on the shape of the skirt and
disagree on how far the peak stands above it, which for a two-pole section is
proportional to Q. Ten to eighteen decibels of it: our resonance was a factor of
three to eight too blunt.

### Why the number in the code was wrong, and it is worth being precise about it

`src/dsp/filter.odin` carried a maximum Q of 14 with a comment giving the
reference's as 8.57, "measured the same way" — off a 1/6-octave band profile.

**A 1/6-octave band has a Q of its own.** Its edges are a sixth of an octave apart,
so

    1 / (2^(1/12) - 2^(-1/12)) = 8.651

and any resonance sharper than that is smeared into a band-wide peak and reads back
as about 8.65 no matter what it really is. The measured 8.57 is that ceiling to
within one percent. It was a floor on the answer recorded as the answer, and every
subsequent decision rested on it: the damping slope was pushed from 1.9 to 1.93 and
stopped, on the reasoning that our peak was merely "30 percent too wide" and that
stability ran out just above.

Neither half of that was true. The topology is unconditionally stable at any
damping above zero; what ran out was a unit test asserting `peak < 40.0`, which is
a statement about gain and not about stability. A Q of 1000 is entitled to a gain
of 1000.

### An observable that does not need the peak resolved

`s1probe qprobe` drives noise through the filter and takes the ratio of the power
in the band holding the resonance to the power in a band a fixed distance above it.
Integrating over a band *wider* than the resonance is the point: peak gain squared
over a bandwidth proportional to 1/Q leaves a band power proportional to Q, while
the skirt sample does not move with Q at all. So the ratio tracks Q without the
peak ever having to be resolved — exactly the constraint that defeats a band
profile.

The ratio is never converted to a Q by formula. The same measurement runs against
`dsp.Filter` itself at a sweep of known damping values and the reference's reading
is inverted through that calibration, so what comes out is the damping *our*
topology needs, not a Q read off one filter design and applied to another.

Three checks, and each of them found something:

- **Conditioning.** The ratio has to keep moving as the damping falls, or the
  inversion is guessing. It runs 5.97 dB at k = 1 to 38.72 dB at k = 0.001.
- **The voice path.** The same reading taken through `render_ours` — oscillator,
  gain staging, pan law, limiter and all — recovers the table's own damping to
  within 6 to 9 percent, a uniform bias rather than a distortion of the curve.
- **Two skirt distances.** A path *around* the filter would lift the far sample
  without touching the near one. For the band pass the two agree within 4 to 20
  percent across the whole knob. For the 24 dB low pass they disagreed by a factor
  of 33, which was the far sample sitting 91 dB down — at the render's noise floor
  rather than on the filter — and the distances are now chosen per slope.

One artefact showed up and was fixed rather than smoothed: an otherwise clean
128-point curve had a single 14% reversal at stored 21, exactly where the loudest
band jumped from 269 Hz to 214. At the bottom of the knob a band pass's maximum is
broad and which band wins is decided by noise. The corner does not move when the
resonance turns, so the band is found once at the top of the knob and held.

### What the reference's resonance actually is

```
  stored      0     32     64     96    112    120    124    127
  k        0.935  0.698  0.460  0.220  0.100  0.041  0.012  0.001
  Q          1.1    1.4    2.2    4.5   10.0   24.4   82.3  952.4
```

Against a straight line from Q 0.5 to Q 14. The knob does almost all of its travel
in its last fifteen steps, which is why a linear law could not be right at both
ends at once and why this is a table. At stored 127 the reference is at or past
self-oscillation; that entry sits on `dsp.MIN_DAMPING`, which is where f32 stops
being able to represent the damping at all — `a1` is 1/(1 + g(g+k)), so k arrives
only as the product g·k, and at the bottom of the cutoff range that is five times
the epsilon.

### The 24 dB path needed its own curve, and its own arithmetic

Raising the resonance made the 24 dB low pass dramatically **worse** — 15.32 dB of
timbre error against the 12 dB low pass's 4.14, with the output pinned against the
limiter. Two separate causes, and both are properties of a cascade rather than of
the reference:

- **A cascade multiplies resonances.** Two identical sections both given k produce
  a peak of 1/k squared. `filter_set_damping` now gives each section the square
  root, which lands the pair on 1/k. The rule falls out well at both ends: k =
  0.001 becomes a Q of 32 twice over rather than an impossible 1000 once, and k = 2
  becomes 1.414 per section, which is exactly Butterworth.
- **A pair of two-pole resonances is not one four-pole resonance**, under any
  sharing of the damping. So the 24 dB curve is its own sweep, and comes out at
  roughly twice the 12 dB damping at the same knob position.

```
  24 dB low pass, timbre error at resonance 127
  both sections at k          26.62 dB
  square root per section     18.29
  and its own damping curve    5.98
```

### Resonance is energy, and one gain curve covers every response

With the real damping in place the timbre was right and the level was not: up to
eleven decibels loud at the top of the knob, which the spectral metric normalises
away and never saw.

The correction turns out to be one curve, and that is a measurement rather than a
convenience. The low pass, the high pass, the band pass and the 24 dB low pass all
need the same one to within about a decibel across the whole knob, and it is
independent of the cutoff — checked at three settings four octaves apart, which is
what a normalisation of the filter's own noise gain has to be.

```
  timbre / level at resonance 127, controlled patches
                      before            after
  low pass 12      10.78 / +9.62     3.33 / +0.67
  low pass 24      15.32 / +5.49     5.98 / +2.46
  high pass 12      4.82 / +3.03     4.64 / +1.03
  band pass 12      9.52 / -10.36    4.80 / +0.67
```

It replaces `BAND_PASS_K_EXPONENT`, a k^0.25 applied to the band pass alone and
fitted by driving a **saw** through it. A saw is the wrong instrument for a
narrowing resonance: its partials fall out of the peak as it sharpens, so the
reading under-states the gain, and the correction was never a band-pass matter in
the first place.

### The band pass does not centre where the cutoff table says

`FILTER_CUTOFF_HZ` was measured on the 12 dB **low pass**, as its own header says.
The reference's band pass centres about a minor third below it for the same knob
setting, and ours centred exactly on the table — so every band-pass patch was two
and a half semitones sharp. Measured at five cutoffs across five octaves, with the
resonance at maximum so the peak is unmistakable:

```
  stored      17      32      48      64      80
  ratio    0.868   0.868   0.860   0.855   0.844
```

Kept as one constant, 0.859. The 2.8% drift across the five is real and in one
direction, but it is a twentieth of what it is correcting, and a table there would
be fitting the last decimal of a corner estimate. Stored 96 was measured and thrown
out: the tracker returned 1242 Hz where the peak is near 2400, which is a lock on
the wrong feature and not a filter that moved.

### On the bank

```
                    before    after
  spectral mean     10.08 dB   9.99 dB
  spectral median    9.25      9.28
  envelope mean     11.24     11.37
  envelope median    8.76      9.05
  level mean        -1.38     -1.25
  level median      -0.81     -0.88
  null depth        -1.70     -1.71

  117.sy1 spectral  35.39     11.60
  117.sy1 envelope  17.46      8.75
  117.sy1 level    -21.05     -4.22
```

The aggregate barely moves, and it should not: one patch in 123 cannot shift a
median. Split by what the change can reach, it is scoped as tightly as the
band-profile evidence said it would be:

```
  resonance 120-127   n=  3    -6.44 dB
  resonance  96-119   n=  7    +1.64
  resonance   0- 95   n=113    -0.02
  band pass           n= 10    -2.77
```

### What is refused, and what is left

The output gain curve costs 0.10 dB of spectral mean on the bank — 9.89 dB without
it against 9.99 with — and it ships anyway. Without it the level median goes to
+1.64 dB where the baseline was −0.81, and it is directly measured, cutoff
independent, and agrees across four filter responses. Dropping a measurement that
was checked four ways to buy a tenth of a decibel on a metric that is blind to what
it corrects would be fitting the metric.

The **96 to 119** group is the honest cost, and it has a diagnosis rather than a
shrug. Its worst two, 054 and 079, are byte-identical in the filter section: 24 dB
low pass, cutoff 80, resonance 107, and **envelope amount 0** — which is not "no
modulation" but full *negative* amount, so the corner plunges about ten octaves
during the note. Their level improved a great deal (+13.96 to +2.32 dB on 054) and
their timbre got worse by five, and the band profile says why:

```
  054.sy1, ours minus the reference, energy-normalised
  band centre Hz     44      88     177     354     707    1414    2828
  signed mean     -16.9   -16.8    +2.2    +0.8   -32.9   -33.6   -22.4
```

A 33 dB hole at 707 and 1414 Hz. The filter is closing too far, and the old blunt
resonance was leaking enough through its skirt to hide it. That is the pattern this
file has recorded three times already — a sound measurement makes the null test
worse and the fault is in the parameter next to it — and it points at parameter
21's negative extreme, whose own generated header already marks the far end of that
sweep as extrapolated rather than measured.

Two things were ruled out on the way rather than assumed. The output limiter is not
involved: made transparent, 054 scores 13.48 dB, identical to the shipping build,
because its peak is 0.80 and never reaches the knee. And using the 12 dB curve for
both slopes instead of the measured 24 dB one does not recover those patches
either — it moves them by half a decibel while costing the 24 dB low pass seven
decibels of level error at full resonance.

## The LFO waveforms, and a display that was a red herring

The LFO's destinations were measured, and its rate, and three of its four depths.
Its *shapes* never were: parameters 42 and 47 were bound from the English readme's
list — "saw, triangle, sine, square, random(sample & hold) or random (smoothed)" —
read onto the display identifier. `s1probe lfoshape` measures them, and **four of
the six states were bound to the wrong waveform.**

### The instrument

The same observable `lforate` established: the LFO pointed at the stereo position,
which is a bipolar scalar per frame that nothing else in the voice can
contaminate. Instead of counting crossings, the series is folded into one cycle
and matched against saw, triangle, sine and square over every phase alignment.

Three details are load-bearing, and each is there because the first version got it
wrong:

- **The period comes from the series' own autocorrelation, not the rate table**,
  so the shape is measured without assuming the rate. But it has to be the
  autocorrelation's first peak past its first *negative* excursion, not its
  largest. A true period is rarely a whole number of frames, so a lag some whole
  number of cycles out — where the fractional part realigns with the integer lag
  grid — can correlate better than the period does. Our own LFO at this setting
  runs at 4.623 Hz, a period of 216.3 frames, and lag 1515 is 7.003 periods:
  taking the global maximum read a clean sine as 0.66 Hz and folded it into
  alternating noise.
- **The depth must not be full.** At depth 127 the reference's pan reaches the
  rails and stays there for a third of the cycle, which flattens the top of every
  shape — a triangle arrives as a trapezoid, a sine as a flat-topped sine, and the
  two stop being separable. Depth 48 keeps the observable linear.
- **Every state is rendered through our engine too**, under identical conditions.
  The question is not "what shape is this" but "does our binding produce the
  reference's shape for the same stored integer", and a verdict from classifying
  the reference alone would leave the mapping layer untested.

### What they are

```
  stored  display  position   reference          this used to bind
       0      "0"         0   saw down           saw               ok
       1      "1"         1   triangle           triangle          ok
       2      "5"         2   square             random smooth     wrong
       3      "2"         3   sample & hold      sine              wrong
       4      "3"         4   random smooth      square            wrong
       5      "4"         5   sine               sample & hold     wrong
```

Saw, triangle, sine and square each fold to a cycle correlating above 0.95 with
their template and repeat at 1.000. The two random states do not repeat at all,
and are told apart by their largest single-frame step: sample and hold jumps a
quarter of its range at once, the smoothed one never exceeds a hundredth.

Read down the **position** column and the readme's own order comes back exactly.
So the documentation was right about the order all along, and this engine was
wrong about what the order indexes. These two parameters display their states out
of order, as 0, 1, 5, 2, 3, 4, and that was read as a display carrying an identity
the position had lost. It carries nothing of the sort.

That is worth stating against the trap this file has recorded twice before, for
the oscillator waveforms and the LFO destinations, where the documented order
genuinely *was* wrong. The lesson is not "the manual lies" — it is that ordering
is a question for measurement either way, and a plausible story about why a
display looks odd is not evidence.

### The saw direction, which pan could not settle

One thing the pan observable cannot answer. A sign flip of the LFO is
indistinguishable from a sign flip of the destination it drives, so matching the
reference on pan proves only that the two conventions compose the same way.

Volume has no such ambiguity — louder is louder under any convention — so
`lfoshape --dest 4` reads the saw off the loudness instead. Both engines ramp
down and jump back up, folding to cycles that agree within a decibel across the
whole cycle. Our saw runs the right way.

Watched on pan, though, that same saw moved the reference's image left to right
and ours right to left. With the LFO ruled out, that is the pan destination's own
sign, and the static pan control is not the culprit either: parameter 90 hard left
reads positive on both. So `mod_pan` is negated in `voice_process`, and that is a
second defect this probe found rather than the one it went looking for.

### What it is worth, and why the bank barely moves

Almost nothing in the factory bank uses the affected states. Of the enabled LFOs
across all 128 patches, **119 select stored 1 — triangle, which was already
right.** Six selections across five patches reach anything else:

```
  patch  shape           destination      spectral        envelope
   085   random sm. -> sine    osc2 pitch    7.91 -> 8.08    9.38 -> 3.16
   123   sine -> square        cutoff       19.51 -> 12.38   6.00 -> 5.91
   125   sine -> square        both pitches 12.97 ->  7.89   0.85 -> 2.15
   124   sample&h. -> random   both pitches  6.01 ->  6.98   8.13 -> 7.39
   121   square -> sample&h.   both/cutoff  21.29 -> 21.64  10.55 -> 13.15
```

The split is not arbitrary, and it is the point. The three patches whose corrected
shape is **deterministic** improve substantially — 123 by 7.13 dB of timbre, 125 by
5.08, and 085 by 6.22 dB of envelope with its stereo width going 0.177 to 0.268
against the reference's 0.289. The two that move the wrong way are exactly the two
whose corrected shape is **random**.

That is expected rather than disappointing: our RNG is not the reference's, so a
correctly-shaped random LFO still produces a different sequence, and the null test
cannot reward it. On those two patches the metric is measuring which random
sequence we drew. It is the same blindness this file already records for the sub
oscillator — a real defect the bank cannot see — arriving from the other side.

On the whole bank:

```
                    before    after
  spectral mean      9.88      9.78 dB
  spectral median    9.29      9.28
  envelope mean     10.30     10.28
  level mean        -0.89     -0.80 dB
  stereo width      -0.094    -0.092
```

### 121 is still the worst patch, and it is not the waveform

The patch that prompted this is barely improved, and its diagnosis has moved. Its
LFO1 drives **both oscillators' pitch** at depth 111 — not the filter cutoff, as a
first reading of its parameters suggested — through `LFO_PITCH_SEMITONES`, which is
42.33 and is the least trustworthy constant in the engine: this file already
records that its measurement did not converge, reading 43.2, 42.3, 39.3 and 36.4
semitones at notes an octave and a half apart, and that the note-dependence is
unexplained. At depth 111 that is some thirty-seven semitones of pitch modulation,
now stepped randomly rather than squared.

Both the old shape and the new one are wrong about this patch for the same
underlying reason, and it is not the shape. The pitch depth is the next thing to
measure.

## The pitch depth, which was never note-dependent

`LFO_PITCH_SEMITONES` was the least trustworthy constant in the engine. This file
recorded its measurement as having failed: full depth read 43.2, 42.3, 39.3 and
36.4 semitones at notes an octave and a half apart, "and an LFO depth cannot
depend on the note played". The value shipped was the lowest note's reading, on
the reasoning that truncation can only read low, with the note-dependence left
open.

**The plugin was never note-dependent. The instrument was.**

### The square makes the pitch stand still

`lfodepth` leaves the LFO shape at its default, a triangle, so the pitch is
*sweeping* for the whole render and the range has to be recovered by tracking a
moving tone across overlapping windows. Two faults follow, and between them they
produce both the bias and the note-dependence:

- **A percentile band is not a range.** `span` discards the outer 5% at each end,
  and a triangle distributes its pitch uniformly across the interval, so a full
  tenth of the travel is thrown away before anything else happens.
- **Tracking a swept tone costs resolution, unevenly.** The window is 4096 points
  and its bins are 11.7 Hz apart whatever the note: 38 cents at C5, and 290 cents
  at C2. The pitch also moves *within* each window, smearing the peak by an amount
  that depends on how far the sweep travels per window — which depends on the note.

`s1probe lfopitch` sets the LFO to a **square**. The pitch stops sweeping and
becomes two steady values, each measurable with a long window at full precision,
and the interval between them is the depth by construction — no percentile, no
tracking, no assumption about how the waveform distributes its time. This is only
available now because `lfoshape` established which state the square is; before
that, this setting selected sample and hold.

### Exactly five octaves, at every note

```
  note   played Hz   ref high Hz    ratio   up
    36       65.41       2093.09    32.00   60.00 semitones
    48      130.81       4186.07    32.00   60.00
    60      261.63       8371.94    32.00   60.00
```

Note-independent to the last digit the instrument prints. The law is also
**symmetric**: the up and down excursions agree within 0.03 semitones at every
setting where both are inside the analysis range.

Reporting the two excursions separately rather than halving the interval is what
makes this legible, because at large depths one side is always against a wall. The
pair spans ten octaves at full depth, and ten octaves is the entire distance from
the analysis floor to Nyquist, so at note 60 the downward side reads 17.58 Hz —
which is the probe's own bin 3, not a measurement. Those readings are marked, and
the marked ones are the readings the old method was quietly averaging in.

### The depth knob is not linear

Twenty settings fit `(exp(k*u) - 1) / (exp(k) - 1)` at k = 2.3:

```
  stored      4     16     32     56     80    104    127
  measured 0.47   2.15   5.16  11.72  21.75  37.22  60.00  semitones
  this law 0.50   2.25   5.25  11.75  21.78  37.28  60.00
```

Worst deviation 0.10 semitones out of 60, which is below what the instrument
resolves. k is pinned rather than bracketed: 2.2 and 2.4 miss by 0.65 and 0.45
semitones at stored 64 where 2.3 misses by 0.09.

The earlier attempt at this curve got the **shape** right and the scale wrong. Its
normalised ratios were 0.089, 0.249 and 0.535 at stored 32, 64 and 96; the clean
measurement gives 0.086, 0.242 and 0.522. That is the third time in this file a
measurement has been sound about shape and wrong about what to do with it.

One tidy story does die here. The curve was thought to be the amplitude curve,
which parameters 27 and 29 already share. It is not: at stored 8 the pitch depth
is 31% above what that curve gives, though the two agree to three decimal places
at stored 64, which is presumably how the resemblance survived as long as it did.

**The curve is applied to the pitch destinations only**, and the restraint is
deliberate. One depth curve scaled per destination is the obvious design, and the
volume column is closer to this curve than to a linear reading at all three of its
points — but the cutoff and pan columns are not, and both of those instruments are
known to saturate. `lfoshape` shows the pan reading against the stereo rails by
depth 48 directly. Re-measuring those two with a square LFO is what would license
moving them. Full depth is unaffected either way, since the curve is 1.0 at the
top of the knob.

### Calibration, and what it is worth

Our engine now tracks the reference within 0.09 semitones at every depth measured,
and reproduces it exactly at full depth including the same bounded reading.

```
  depth        8     24     48     64     96    112    127
  reference 1.04   3.56   9.19  14.53  31.31  44.06  60.00
  ours      1.05   3.64   9.26  14.62  31.35  44.14  60.00
```

On the bank the aggregate barely moves, and the reason is worth stating precisely
because it is easy to get wrong. Sixty-eight of the bank's enabled LFOs *are*
pointed at a pitch destination — it is by far the most common choice — but almost
all of them sit at **depth 0 to 4**, a vibrato of well under a semitone either
way. Only six patches use a pitch depth above 10:

```
  patch  depth        spectral            envelope
   125      18    7.89 ->  1.35     2.15 ->  0.64
   124      94    6.98 ->  6.27     7.39 ->  7.47
   121     111   21.64 -> 23.20    13.15 -> 13.20
   085      72    8.08 ->  7.94     3.16 ->  3.83
   111      20    5.69 ->  5.65    34.62 -> 34.62
   084      35   10.74 -> 10.74     4.82 ->  4.82
```

```
                    before    after
  spectral mean      9.78      9.77 dB
  envelope mean     10.28     10.21
  envelope median    8.24      8.13
  level mean        -0.80     -0.89 dB
  null depth        -1.59     -1.66
```

**125.sy1 is essentially solved** — spectral 7.89 to **1.35 dB**, envelope 2.15 to
0.64, and a centroid matching the reference's to two decimal places, which is
close to the measurement floor. That is the clearest per-patch result in this file
since the band-pass work.

121 moves the wrong way again, and it is the same reason as the section above
rather than a new one: its LFO is a sample and hold, so our random sequence is not
the reference's and no depth correction can align two different random walks. Its
*centroid* error did improve, from −4.02 to −2.76 octaves, which is the part of it
the depth actually governs. It remains the worst patch in the bank and it remains
untestable by this metric.

## The other three depths, and the answer to the shared-curve question

The pitch curve was applied to the pitch destinations only, with the reason
recorded: one depth curve scaled per destination is the obvious design, but the
cutoff and pan columns of the old table disagreed and both of those instruments
were known to saturate. `s1probe lfosquare` puts the same square on the other
three, and the question has a clean answer.

**There is no shared curve.** All four destinations differ, and two of them are
not bipolar at all.

```
  destination   polarity          curve in the knob        full depth
  pitch         bipolar           exponential, k = 2.3     +/-60 semitones
  cutoff        upward only       linear in octaves        +5.06 octaves
  volume        downward only     linear in amplitude      silence
  pan           bipolar           steeply concave          hard left/right
```

### The cutoff only ever opens the filter

The low half of the square sits at **exactly the unmodulated corner** at every
depth. Moving the base from 585 Hz to 7 kHz does not change that: the corner still
never goes below it, where a bipolar modulation would have had its whole downward
half available. So this destination is unipolar upward, and our engine had it
swinging both ways.

This also explains an observation `docs/reference-notes.md` has carried since the
destinations were first identified, with no explanation attached: the cutoff
destination produces a **bit-identical render with the filter wide open**. A
bipolar modulation cannot do that. An upward-only one must.

```
  depth              8      32      64      96
  octaves up     0.317   1.262   2.553   3.881
  / (depth/127)   5.03    5.01    5.07    5.13
```

Linear to about 2%. The full-depth figure is the slope of that line rather than a
reading, because at full depth the corner is pushed past the top of the filter's
own range and stops being observable.

### The volume ducks to silence, and the old correction was the artefact

This one reverses a previous conclusion in this file. A previous pass measured a
swept triangle through a percentile band, found 11.93 dB, and replaced a law that
ducked to silence — recording that the old law went "about 40 dB deeper than the
reference goes".

A percentile band is exactly what cannot see a momentary silence. Read off a
square, the reference's low half at full depth is **digital silence**, and the
fraction of *amplitude* removed is the knob position:

```
  depth                 8     32     64     96    127
  amplitude removed 0.063  0.251  0.504  0.756  1.000
  depth / 127       0.063  0.252  0.504  0.756  1.000
```

So there is no decibel constant at all, and the law that was replaced was right.
That is worth stating plainly: this file has repeatedly warned that a measurement
can be sound about shape and wrong about scale, and this is the first case where a
measurement overturned something that had itself been correct.

### Two instrument failures worth recording

The cutoff took three attempts, and the first two failed in ways a fourth should
not repeat.

**Clustering on a noisy observable is biased, not merely weak.** `lfo_two_levels`
splits a series at its midpoint and takes the median of each side, which is exact
for a clean two-level signal. The filter corner is not clean: it is a *crossing*,
found by walking the band profile until the response falls 3 dB, so it inherits the
noise of a handful of bands. Splitting that at its midpoint sorts **the noise
itself** into a high group and a low group and manufactures a separation of about
twice the noise amplitude. The first version duly reported 1.54 octaves of cutoff
modulation at depth zero. Assigning each window to a half cycle by its *timestamp*
removes the bias completely, because the assignment no longer looks at the value it
is about to average.

**A window must fit inside the half cycle.** The corner is read over 32768 samples,
which is 683 ms. Run against a 1.04 s half cycle, two thirds of the hops straddled
an edge and the sweep came back unreadable. The old `lfodepth` used a very slow
cutoff rate for exactly this reason; second-guessing it was a mistake.

The third attempt replaced the corner with a **spectral centroid**, which is an
average rather than a crossing and therefore far quieter — the corner series
repeated at 0.18 where our own engine's repeated at 0.82, so the periodicity of a
plainly periodic signal was being lost in the estimator. A centroid is not
proportional to the corner across the whole range, so it is calibrated against the
reference's own static cutoff sweep and inverted through that, which is the pattern
`qprobe` already uses for the resonance.

One caveat on that calibration is worth keeping: it is the *reference's*, so
applying it to our own render carries a constant offset of about 0.23 octaves from
the two filters' shapes differing. The offset is the same at every depth, so it
does not disturb the slope, but our cutoff column in that probe should not be read
as an absolute.

### Calibration

Pan and volume now reproduce the reference essentially exactly:

```
  pan     depth        8     32     64     96    127
          reference  .243   .673   .913   .990   .999
          ours       .243   .673   .913   .990   .999

  volume  depth        8     32     64     96    127
          reference  0.562  2.517  6.084 12.242  silent   dB removed
          ours       0.565  2.521  6.089 12.248  silent
```

The cutoff cannot be calibrated that way for the reason above — its instrument
carries a constant offset when pointed at our engine — but our slope matches the
reference's at every depth once that offset is taken out.

### What it is worth

Only twelve selections across the bank reach these three destinations, all of them
the cutoff or the volume and none the pan, so the aggregate moves modestly:

```
                    before    after
  spectral mean      9.77      9.64 dB
  envelope mean     10.21     10.17
  level mean        -0.89     -0.83 dB
```

The per-patch results are where it shows, and **121.sy1 is finally out of the worst
ten**. It had been the worst patch in the bank for this entire sequence of work:

```
  patch                     spectral        envelope        centroid error
  121  square -> S&H etc    23.20 -> 13.22  13.20 -> 8.06   -2.76 -> -1.38 oct
  123  cutoff LFO            12.38 ->  5.56   5.91 -> 3.68   -1.61 -> -0.83
```

121's LFO2 points at the cutoff at depth 100, so the unipolar correction reaches
it directly — and the part of its error that remains is the sample-and-hold on its
*pitch*, which no metric here can align. 123 more than halved.

## The FM depth, and a defect the bank cannot see

The last chosen constant in the LFO loop, and the one this file had written off:
"the FM index is not a quantity the spectrum reports directly, so this stays at
unity and is the one depth in this list still chosen rather than measured".

That objection is true and it is not fatal. **Parameter 45 is a knob**, and a knob's
settings can be rendered one at a time. So the spectrum never has to yield an
index; it only has to tell one setting of that knob from another. `s1probe lfofm`
sweeps parameter 45 with the LFO off to calibrate the carrier's spectral centroid
against it, then reads the LFO's own excursion back in units of the knob it is
modulating. It is the cutoff's calibration trick pointed at a different parameter.

### Unipolar again, and scaled by the headroom

The low half of the square sits exactly on parameter 45's own value at every depth,
so this destination never reduces the FM — the third of the four to turn out
one-directional. What rises is linear in the depth. What is *not* constant is the
slope, and that is the finding:

```
  parameter 45 at   0.000   0.252   0.504
  measured slope     0.99    0.745   0.497
  1 - that value     1.000   0.748   0.496
```

The slope is the distance left to the top of the range. So a full-depth LFO drives
the FM amount to maximum from wherever the knob left it, and a half-depth one
covers half the remaining distance:

    fm = knob + (1 - knob) * depth * (1 + lfo) / 2

Measured at base 32 the linearity is tight — 0.738, 0.746, 0.746, 0.748, 0.743,
0.746, 0.745 across seven depths. Our engine had this bipolar and at full range,
which is wrong in three ways at once: the direction, the scale, and the dependence
on the knob.

Base 0 is the one setting this cannot be measured at, and for an instrument reason
rather than a plugin one: the low half then sits exactly on the calibration's first
point, and noise puts it a hair below, outside the calibrated span. The reading it
does return there agrees with the law.

### Nothing in the bank uses it

```
  destination      patches
  nothing at all      43
  both pitches        41
  oscillator 2 pitch  28
  filter cutoff        9
  volume               3
  FM                   0
```

**No factory patch points an LFO at FM**, so the bank is unchanged to the digit —
spectral mean 9.64 dB, envelope 10.17, level −0.83, identical before and after.

This is the third defect in this file that the null test is structurally blind to,
alongside the sub oscillator and the second effect unit. It is worth fixing on its
own terms and worth not expecting the oracle to confirm.

The same table is worth a second look for a different reason: **43 of the bank's
enabled LFOs point at state 5, which does nothing at all**. A third of the LFOs in
the factory bank are inert, which is a fact about the bank rather than about this
engine, but it does cap how much the null test can ever say about this section.

That closes the LFO. Its destinations, rate, waveforms and all five depths are now
measured rather than chosen.

## Parameter 21's negative extreme, closed

The suspicion above was half right. `FILTER_ENV_OCTAVES_PER_STEP` itself is not
wrong — `s1probe cutoffprobe --sweep amount --cutoff 80 --type 1 --res 107` (the
sweep now takes `--type` and `--res`, added for this) drives the envelope amount
across its full range on 054 and 079's own filter type and resonance, held fully
open the whole render, and it tracks the law to within a semitone at every setting,
floor included. The law was measured correctly.

What was wrong is how `voice_process` combined that law with a *fractional*
envelope value. It computed the full ten-octave figure, multiplied it by whatever
the envelope generator's 0..1 output was that sample, and clamped only the
resulting Hz. That is not what the reference does when the base cutoff does not
have ten octaves of headroom to give:

```
s1probe cutoffprobe --sweep sustain --cutoff 80 --amount 0 --type 1 --res 107
```

At cutoff 80 (1402 Hz) the envelope amount's full negative extreme reaches its
floor at 6.02 octaves down, not 10.05 — the filter runs out of room five octaves
early. A mid sustain (stored 32, the value both patches use) lands at **453 Hz**.
Scaling the raw 10.05-octave law by that same fraction and clamping afterwards, as
`voice_process` did, gives 246 Hz — the corner ends up **an octave low**, and with
these patches' Q of 107 that octave is the difference between the resonant peak
sitting where the reference puts it and sitting a full octave below, which is
exactly the shape of the errors 054 and 079 were showing: a huge spike where our
peak landed and nothing where the reference's peak actually was.

So the reference clamps the envelope's *full-depth* excursion once, against the
filter's own range, before taking any fraction of it — the fraction is of
whatever excursion survived the clamp, not of the law's raw figure. `voice_process`
now does the same: the full-depth target is computed and clamped to
`FILTER_CUTOFF_HZ[0]..FILTER_CUTOFF_HZ[127]` — the knob's own measured range,
not the general-purpose DSP safety floor, which is well below where the reference
actually stops — and the envelope value scales the octave distance that clamp
left rather than the unclamped law.

```
                  054.sy1           079.sy1
              before   after     before   after
  spectral    13.48    7.02      12.62    5.90    dB
  level       +2.32    +0.26     -2.25    -3.97   dB
  worst band  41.5 @604Hz->31.5 @34Hz   42.8 @604Hz->28.3 @107Hz
```

079's level error grows by 1.7 dB — the corner sitting an octave lower than it
should was accidentally holding back some level error along with the timbre error,
and correcting the frequency removes that cancellation. Timbre improved by 6.7 dB
on that same patch, which is the one this section was chasing.

On the full bank (`s1probe compare` over all 123 comparable patches):

```
                    before    after
  spectral mean      9.99      9.88   dB
  spectral median    9.28      9.29   dB
  envelope mean     11.37     10.30   dB
  envelope median     9.05      8.25   dB
  level mean         -1.25     -0.89   dB
  level median       -0.88     -0.60   dB
  null depth         -1.71     -1.59   dB
```

Envelope error is the one that moves — over a decibel on the mean, most of a
decibel on the median — which fits: the defect only bites during the part of the
note where the filter envelope sits at a fraction of its depth, i.e. attack, decay
and any sustain short of full or zero, so it shows up in the contour more than in
the settled timbre. Neither 054 nor 079 is in the worst ten patches any more.

## The chorus feedback, and a knob 124 of 128 patches leave at its floor

Parameter 55 is the chorus/flanger's feedback, `-99 %` to `97 %`, and it had never
been measured on its own — `chorus_process` fed the tap back as
`input + tap * feedback` with `feedback` clamped to `±0.95` and no evidence for
either the law or the ceiling. That would not matter if the factory bank mostly
sat away from the ends of the knob. It does not: **124 of the 128 patches store
55 at 0**, its display floor, "-99 %".

**Method.** `s1probe chorusfb` turns the chorus into a plain static comb rather
than trying to read feedback out of a musical patch: depth zero so the tap stops
sweeping, type 1 so there is one tap and no channel offset in the way, the
longest centre delay (30 ms) so a round trip is easy to resolve, full wet, and a
struck note with an instant attack and a fast decay so what is left afterwards is
only the loop ringing down. A feedback loop with a fixed delay decays
geometrically, so the tail's decay rate, read in dB per second and multiplied by
the round-trip time, *is* the feedback:

```
|feedback| = 10 ^ (dB per round trip / 20)
```

Nothing about the reference's internals is assumed, only that a delay loop
decays geometrically — which is what makes it a loop. The sign is not
measurable this way and does not need to be: a decay rate is the same either way
round, and the display already states which side of zero the knob is on.

```
build/s1probe.exe chorusfb "ext/synth1/Synth1/Synth1 VST64.dll" --values 0,8,16,32,48,64,80,96,112,120,127
```

```
  stored  display   ref |fb|   our |fb|  (before)
       0    -99%      1.000      0.953
       8    -87%      0.879      0.877
      16    -74%      0.766      0.754
      32    -50%      0.511      0.512
      48    -25%      0.273      0.295
      96     50%      0.511      0.513
     112     74%      0.766      0.766
     127     97%      0.980      0.953
```

The middle of the knob already agreed to within a couple of percent, which
confirms the law itself: the display is the feedback as a fraction of a hundred,
and the sign convention (negative inverts) was already right. The disagreement
was only at the extremes, and it went the opposite way from what the earlier
comment on `chorus_process` suspected. At stored 0 — the setting **97% of the
bank uses** — the reference's tail does not decay at all: 0.0 dB per second, a
loop gain of 1.000, ringing until the note itself is cut. The 0.95 clamp turned
that into 14 dB/s, so on almost the whole bank this engine's chorus was too
*damped*: less wet signal survives each round trip than the reference keeps,
which reads as a chorus that is too quiet and too narrow — exactly what the
stereo-width and level sections above kept finding, on a bank where the
per-patch cause could not be isolated because every patch's chorus differs in
a dozen other ways at once.

`chorus_process`'s clamp is now `±0.99` rather than `±0.95` — held a hair under
unity rather than at it, since the reference's 1.000 is only within this
instrument's resolution and a delay loop held at exact unity has no answer to
energy already sitting in it, which this engine still has to bound. 0.99 rings
for about twenty seconds at the longest centre delay, which is past the length
of any held note, so the audible ceiling is the same as the reference's within
what a probe can tell them apart on. With the new clamp:

```
       0    -99%      1.000      0.998
     127     97%      0.980      0.998
```

`--level` sweeps the wet level from 127 down to 24 at stored 0 and finds the law
level-independent — 1.000 / 0.992 / 0.990 — which rules out the alternative
explanation that the reference applies feedback before its level control and a
quiet chorus therefore has a quieter loop.

**On the bank.** Full-bank `s1probe compare`, same 123 comparable patches as the
sections above:

```
                    before    after
  spectral mean      9.89      9.82   dB
  spectral median    9.28      9.42   dB
  envelope mean     11.35      6.85   dB
  envelope median     9.05      4.88   dB
  level mean         +0.95     +1.14   dB
  level median       +1.64     +2.13   dB
  null depth         -1.71     -1.22   dB
  stereo width      -0.143     +0.054   (ours minus reference, mean)
  stereo width      -0.103     -0.000   (ours minus reference, median)
```

Envelope error is the one this section was chasing, and it is the one that
moves by far the most — nearly halved on the mean, nearly halved on the median —
which is what fixing a decay rate on the setting 97% of the bank carries should
do. The median stereo width goes from 0.10 narrow to an exact match, meaning the
*typical* patch is now right. Spectral and level are a wash within the noise this
test already has (both move by a couple tenths of a dB in opposite directions on
mean vs. median). Null depth moves against the fix, but it is the metric this
document already calls uninformative until the phase-independent ones are close,
so a small regression there is not evidence against anything.

The mean stereo width, unlike the median, gets worse — dragged there by two
patches, 002 and 004, whose reference width was already unusually narrow (0.008
and 0.219) and which now read markedly wider than the reference (0.637 and
0.737) rather than matching it. This is not the width law itself: `s1probe
choruswidth --sweep feedback` drives noise through the same chorus type and
depth these two patches use across the full feedback range and matches the
reference at every point, worst case 0.03 off, e.g. 0.913/0.905 at the floor and
0.884/0.852 at the ceiling. The law that turns feedback into width is right for
representative input. What is specific to 002 and 004 is their content: both are
sustained low patches with a fundamental near 28–32 Hz, close to the roughly
33 Hz natural frequency of a 30 ms feedback loop held near unity gain — the
comb's own resonance sits almost on top of the note being played into it. That
is a real and distinct interaction, worth its own measurement, but it is a
different defect from the one this section fixes and does not argue against
fixing it: leaving the feedback clamp wrong to avoid it would cost the other 121
comparable patches their envelope improvement to protect two that have a
separate problem regardless.

## 002, which plays almost nothing, and why: a lead, not yet a fix

002.sy1 ("Piano") was reported as making no sound. It is not literally silent
-- `s1probe compare` gives it a peak of 0.0333 against the reference's 0.0962,
-16.89 dB down on average -- but that is quiet enough, on top of a wrong attack
shape, to read as nothing through a speaker.

`s1probe patchdiag`, added for this, renders one patch through both engines
under a fixed set of one-parameter-at-a-time variants and prints peak and RMS
for each, so which change closes the gap is visible directly:

```
build/s1probe.exe patchdiag "ext/synth1/Synth1/Synth1 VST64.dll" patches/incoming/soundbank00/002.sy1
```

```
variant                              ref peak    ref rms   our peak    our rms
baseline                               0.1092     0.0461     0.0333     0.0067
FM off (45->0)                         0.0022     0.0003     0.0901     0.0156
filter env neutral (21->63)            0.2375     0.0581     0.1872     0.0661
filter wide open (19->127,20->0)       0.4832     0.1533     0.3993     0.1213
```

The `FM off` row is the finding. Turning off parameter 45 makes the *reference*
almost entirely silent -- 0.0022, near the floor -- while it makes *this
engine* louder. The two engines move in opposite directions from the same
change, which rules out a depth or headroom curve (those would move both
engines the same way, just by different amounts) and points at how much the
filter is actually closed.

002 pairs a modest base cutoff (parameter 19 at 44, 471.8 Hz open) with a
negative filter envelope amount (21 at 31, display "-32") and a mid-high
sustain (17 at 73). `s1probe cutoffprobe --sweep sustain --cutoff 44 --amount
31 --type 1 --res 0` plays that combination through the reference alone,
holding the envelope at each sustain setting for the whole render:

```
sustain 0 puts the corner at 86 Hz, sustain 127 at 23 Hz: -1.90 octaves of travel

  stored  corner Hz     fraction    if linear
       0         86      -0.0000       0.0000
      32         50       0.4076       0.2520
      64         33       0.7217       0.5039
      73         31       0.7729       0.5748
     127         23       1.0000       1.0000
```

At this patch's own sustain (73), the reference's corner sits at 31 Hz --
against a played note at 261 Hz, three and a half octaves into a 12 dB/oct
slope, which is why the bare carrier (FM off) all but disappears. `voice_process`
computes something well above that: clamping the full excursion against the
filter's own floor first and then applying sustain 73/127 linearly, as
`docs/null-test.md`'s parameter 21 section above describes, lands near 84 Hz for
this same combination -- audible, not buried, and the reference's FM-off row
says that is too high.

**This is a lead, not a fix.** The `fraction` column above is well clear of
`if linear`, which looks like an unmeasured sustain curve -- the amplitude
envelope's sustain got one (`AMP_SUSTAIN_LEVEL`), the filter's never did, and
`binding.odin` says so in so many words ("still a linear reading of the knob").
But repeating the same sweep at other cutoff/amount combinations does not hold
the curve steady:

```
  cutoff  amount  type   total octaves   fraction at sustain 64
      44      31     1          -1.90            0.7217
      44      31     0          -3.04            0.5772
     100      20     1          -6.28            0.5836
     100      20     0          -6.84            0.5090
```

The excess over `if linear` shrinks as the total measured travel grows, which
is what a *measurement* limit looks like -- the corner-fitting this probe uses
was trusted down to the filter's own 23.6 Hz floor because `filtertable`
already ships a table built the same way, but every one of those readings sits
well clear of the floor for most of its sweep, and these do not -- rather than
what a single fixed sustain law would produce, which should not care what it is
multiplying. Neither the current linear reading nor the clamp-achievable-first
formula above predicts 31 Hz at sustain 73; both land closer to 60-85 Hz. Until
that is pinned down with a measurement that stays clear of the floor across the
whole sweep, changing the sustain mapping risks trading 002's error for a wrong
number on some other patch, which is exactly the mistake this document exists
to catch before it ships. `s1probe patchdiag` and the `--sweep sustain` mode of
`cutoffprobe` are both in place for whoever measures it next.

## The 24 dB path's cutoff curve: built, measured, and reverted

The lead above pointed at a bigger gap first. Holding the filter envelope dead
centre -- no modulation at all -- and reading the base corner at several
settings of parameter 19, filter type 0 (12 dB) against type 1 (24 dB):

```
  stored 19    type 0     type 1
        20      53 Hz      32 Hz    (0.73 octaves apart)
        44     194 Hz      86 Hz    (1.17 octaves apart)
        64     585 Hz     255 Hz    (1.20 octaves apart)
        90    2493 Hz    1165 Hz    (1.10 octaves apart)
       110    7942 Hz    4586 Hz    (0.79 octaves apart)
```

`FILTER_CUTOFF_HZ` and `FILTER_ENV_OCTAVES_PER_STEP` were both measured with
`filtertable`'s filter type left at its default, state 0. Every patch using
state 1 or the LPDL state -- 80 of 128 factory patches, since both are bound to
`.Slope_24` -- has been reading its cutoff off a curve measured on the *other*
filter, and the gap is not a fixed offset: it moves from 0.73 to 1.20 octaves
across the range, so no single correction factor stands in for measuring it.

**Built.** `s1probe filtertable` grew a `--type` flag. It sets the probe's own
filter-type parameter before sweeping, so the same method that produced
`FILTER_CUTOFF_HZ` runs again through the 24 dB path, and emits its output with
a `_24` suffix on every symbol so both tables share the package. Two bugs came
out of making it generic rather than single-use: `emit_filter_table`'s dual
call needed the `FILTER_TABLE_SIZE` constant declared exactly once between the
two generated files, and `fit_env_amount`'s margin around the filter's floor
and ceiling was hard-coded to 538 Hz -- the type-0 base cutoff at the sweep's
own `BASE_CUTOFF`, close enough to that type's true value (585 Hz) not to have
mattered yet, and wrong by more than an octave for type 1's (255 Hz). Fixed to
take the measured base as a parameter. Regenerating the type-0 table with the
fixed tool reproduced the shipped one exactly, which is what confirms the fix
did not disturb the existing measurement.

```
build/s1probe.exe filtertable "ext/synth1/Synth1/Synth1 VST64.dll" src/engine/filter_table_24.odin --type 1
```

wrote `FILTER_CUTOFF_HZ_24` (24 Hz to 15.6 kHz) and `FILTER_ENV_OCTAVES_PER_STEP_24`
(0.163046, against the 12 dB path's 0.159530 -- close on this number, which is
consistent with the cutoff curve being the part that actually moved). Every
value cross-checked against a direct `cutoffprobe` reading at the same setting.

**Wired in and reverted.** `binding.odin` picked between the two tables by
`e.filter_slope == .Slope_24`, mirroring how `FILTER_DAMPING_24` already
does it for resonance; `voice_process`'s envelope-excursion clamp picked its
floor and ceiling the same way. All 63 tests still passed. The full bank did
not:

```
                    before    after
  spectral mean      9.82     10.54   dB
  envelope mean      6.85      7.22   dB
  level mean        +1.14     -1.48   dB
```

29 of 123 patches got worse by more than a decibel of spectral error against
12 that improved -- including 054 and 079, the two patches the parameter 21
section above was fitted against. Sorting the regressions and the improvements
by resonance settles why:

```
  regressed   122(77) 104(99) 121(89) 054(107) 083(115) 079(107) 055(95)
  improved    088(10) 086(10) 084(30) 044(12)  076(2)   002(0)   014(0)
```

Every regression sits at high resonance, every improvement at low. The new
table was measured entirely at resonance 0, and a direct check of what that
means: at parameter 19 stored 80, resonance 0 against resonance 107 --

```
              res 0     res 107
  type 0     1426 Hz    1298 Hz    (0.14 octaves apart)
  type 1      637 Hz    1402 Hz    (1.14 octaves apart)
```

Type 0 barely moves. Type 1's *measured corner* more than doubles. That is not
good evidence the parameter's actual cutoff frequency depends on resonance --
it is what `measure_corner`'s own method, the -3 dB point relative to the
passband's peak, is supposed to do on a resonant filter: raise the Q and a
peak appears near the corner, the "peak" the -3 dB threshold is measured from
moves onto it, and the point 3 dB down the peak's own skirt sits higher than
the non-resonant corner did. The 12 dB path barely shows it here only because
104 (its damping table) keeps its resonance gentler at the same stored 20; nothing
says the 24 dB path's true parameter-19 frequency has moved at all.

So the table is real and the method that built it is the same one already
trusted for the 12 dB path, but comparing it against patches whose resonance is
nowhere near 0 is comparing two different things measured by the same name.
Substituting it wholesale is worse than the status quo on the majority of the
bank that combines type 1 with real resonance, so `binding.odin` and
`voice.odin` are back to the single table -- `git diff` on both files is empty
against the version before this section. `filter_table_24.odin` stays in the
tree as the resonance-0 measurement, and `filtertable --type` as the tool that
made it, for whoever next measures the corner by its peak *frequency* rather
than its -3 dB point, which is the reading that should stay put as Q rises
instead of chasing the peak.

## The peak's own frequency, and this time the bank agreed

The peak-frequency reading exists now: `s1probe peakprobe` sweeps resonance at
one cutoff and type and reads the resonant peak's own frequency rather than the
-3 dB corner, with a parabolic fit across the three loudest bands the same way
`dominant_frequency` fits a bin peak, just walked through the bands' own fixed
log-ratio instead of a bin width.

It answered a narrower question than "is the corner resonance-invariant" --
by ordinary two-pole theory it is not going to be: a resonant peak sits at
`f0 * sqrt(1 - 1/(2Q^2))`, which does not exist below a critical Q and only
approaches `f0` as Q rises. So the peak's own frequency was always going to
move with resonance; the question worth asking is whether it moves toward the
*same* number on both filter types, which is what would say the two types
share an `f0` and differ only in slope.

```
cutoff   type 0 peak (res 127)   type 1 peak (res 127)   gap
  20            44.4 Hz                 56.4 Hz          0.35 oct
  44           170.3 Hz                190.4 Hz          0.16 oct
  64           482.9 Hz                566.6 Hz          0.23 oct
  80          1209.7 Hz               1356.3 Hz          0.16 oct
  90          2171.4 Hz               2434.1 Hz          0.17 oct
 110          6109.8 Hz               6893.5 Hz          0.17 oct
```

At maximum resonance the two types agree to 0.15-0.35 octaves -- nothing like
the 0.7-1.2 octaves the resonance-0 corner measured. The large gap the last
section found was mostly Q bias in the measurement, not in the parameter.

**Built.** `filtertable` gained `--peak <resonance>`: negative keeps the
original -3 dB method, resonance 0, for backward compatibility (regenerating
the shipped 12 dB table with it reproduces that table exactly); zero or above
switches to the peak reading with resonance pinned at that value for the whole
sweep. Regenerating `FILTER_CUTOFF_HZ_24` at resonance 107 -- high enough for
a sharp peak, and the value patches 054 and 079 themselves use -- needed two
more pieces the resonance-0 sweep never did:

- **`extrapolate_head`.** The -3 dB corner is defined on a filter with no peak
  at all, so the original sweep resolved all the way to the floor. A peak is
  not; at the bottom of the cutoff range even resonance 107 puts it below the
  analysed band, and 5 of 128 settings came back with nothing to read rather
  than a low reading. `extrapolate_tail` only ever extended the *top* of a
  curve, so the bottom needed its own version -- done in log2 space rather
  than linear Hz, since a linear backward extrapolation over several missing
  entries can cross zero on a curve this steep.
- **`smooth_log`.** The peak reading is noisier than the corner: a semitone or
  two of zigzag between adjacent settings where the corner method ran smooth,
  because a moderate-Q bump is fixed less precisely by three band-power
  samples than a wide -3 dB crossing is by the whole curve either side of it.
  The knob underneath is a plain 0..127 with no reason to reverse itself, so a
  three-point centred average in log2 space removes the method's noise
  without touching the curve's own shape.

**Wired in, and this time kept.** Same two sites as before -- `binding.odin`'s
choice of cutoff table and envelope-octaves law by `e.filter_slope`, and
`voice_process`'s excursion clamp by the same test -- with the peak-at-107
tables in place of the peak-at-0 ones. All 63 tests pass. The full bank, same
123 comparable patches:

```
                    before    after
  spectral mean      9.82      9.70   dB
  spectral median    9.42      9.26   dB
  envelope mean      6.85      6.77   dB
  level mean        +1.14     +1.02   dB
  null depth        -1.22     -1.27   dB
```

Every number moves the right way or stays flat, which is the opposite of the
resonance-0 attempt. Sorted by patch: 2 regress by more than a decibel of
spectral error (110, already the worst patch in the bank for unrelated reasons,
and 031) against 8 that improve by more than a decibel, several by over two --
110 more comparable patches for the numbers of a real fix than the 29-worse,
12-better split the resonance-0 table produced.

002 itself is a partial result. Its spectral error improves (10.41 to 9.87 dB)
but `s1probe patchdiag`'s FM-off row still reads the wrong way: this engine
gets *louder* with FM removed (0.031 to 0.085 peak) where the reference goes
nearly silent (0.109 to 0.002). That is not a failure of this measurement so
much as a reminder of its edge: 002 sits at resonance 0, exactly where a table
built at resonance 107 is extrapolated furthest from what it actually measured,
and where the still-unexplained sustain-fraction convexity from the section
above this one has the most room to matter, since the achievable excursion
there is smallest. Both loose ends -- the low-resonance end of this curve and
the sustain law -- point at the same patch and are plausibly the same
remaining defect, just not yet measured cleanly enough to fix without
repeating the mistake this document's whole method exists to catch.

## The chorus at near-unity feedback does not have a width, it has a drift

Reported from listening rather than from a render: 001.sy1 ("brastring"), held
as an actual note rather than a 1.5-2 s probe, "sounds like a ghost... bounces
from side to side," and sounds right again the moment the chorus feedback knob
is moved off its patched setting toward the centre. Every measurement in this
document up to the chorus feedback section held a note for at most a couple of
seconds -- long enough to read a level or a spectrum, not long enough to hear
what a sustained pad does.

`s1probe chorusstability` renders one held note for many seconds and reads the
stereo width (side/mid) in one-second windows, so a width that drifts shows up
as a series rather than a single number. Run on 001.sy1 exactly as patched
(chorus feedback stored 0, the -99% this document already established as
correct) for 20 seconds:

```
build/s1probe.exe chorusstability "ext/synth1/Synth1/Synth1 VST64.dll" --file patches/incoming/soundbank00/001.sy1 --seconds 20
```

```
 second  ref width  our width
      1      0.761      0.810
      2      1.028      1.005
      5      0.796      0.882
      6      0.379      0.800
     10      0.873      0.880
     13      0.418      0.891
     18      0.715      0.900
     20      0.488      0.900
```

The reference swings from 0.38 to 1.06 and is still moving at second 20, with
no sign of settling. This engine reaches a width in the same neighbourhood --
the earlier fix's whole point -- and then more or less stays there, 0.80 to
1.01 for the entire twenty seconds. Two candidate causes were ruled out before
landing on the real one:

- **Not either LFO.** Brastring's LFO1 targets FM (parameter 41 stored 5,
  which resolves to `.Fm` in the seven-state destination enum -- not `.Inert`
  at position 4, a misreading corrected during this investigation) at full
  depth, and LFO2 targets amplitude (parameter 46 stored 3, `.Amplitude`) at a
  slow rate. Zeroing both depths in turn (`44,0` then `49,0`) left the
  reference's drift fully intact -- if anything sharper, settling into a
  narrower and still-moving 0.32-0.58 rather than removing it.
- **Not a loudness artefact.** If the width ratio were being inflated by a
  fixed noise floor against a quiet `mid`, the dips would track `mid` dropping.
  They do not: at the second-6 dip, `mid` is 0.038 and `side` is 0.015 --
  `side` collapsing on its own, not `mid` shrinking under a steady `side`.

**It is the feedback setting itself.** Setting parameter 55 to its centre
(stored 64, display "0%" -- literally the adjustment that made it "sound
better") and re-running the same 20-second hold:

```
 second  ref width  our width
      3      0.242      0.245
      8      0.280      0.249
     13      0.248      0.255
     20      0.301      0.249
```

Both engines settle to a stable, narrow width within a couple of seconds and
stay there -- reference 0.24-0.39, this engine 0.23-0.27, close together and
both quiet. The drift only exists at the extreme the factory bank almost
universally uses.

So the reference's chorus, held at near-unity feedback, does not converge to a
wide stereo image and stay there -- it keeps evolving, slowly and without
repeating inside the twenty seconds tried. This engine's comb, given the same
near-unity coefficient, reaches a stable width and holds it. Both now agree on
*roughly how wide*, which is what the earlier fix measured and fixed; neither
engine was checked against *whether width is a single number at all* at that
setting, because nothing before this section held a note long enough to ask.

**Not yet understood, but better characterised.** A 60-second render answers
the question the 20-second one raised: the reference's dips are not an
unsettled transient still wandering. They repeat, close to every 7 seconds --
centred at roughly 6.5, 13.5, 20.5, 26.5, 33.5, 40.5, 47.5 and 54.5 s, a
spacing of 6-7 s eight times running. That is a stable limit cycle with a long
period, not chaos and not a transient that simply hadn't finished -- and it
survived zeroing both LFOs, so nothing this project currently reads out of the
patch is driving it. This engine shows no matching periodicity anywhere in the
same 60 s; its width sits in a tight band throughout. So the shape of the
open question changes: not "does this engine's chorus settle where the
reference doesn't" but "the reference's near-unity feedback loop has a second,
slow cycle this engine's does not reproduce at all."

Two directions worth measuring before touching any code, neither done yet:

- Does the ~7 s period move with parameter 54 (chorus rate)? If it scales with
  the sweep rate, it is a beat between the 2.94 Hz tap sweep and something else
  already in the signal path. If it stays near 7 s regardless of the rate
  knob, it looks like a second modulation source inside the reference's chorus
  that is not exposed through the parameters this project reads -- plausible
  for an "ensemble"-style effect, where a fixed slow wander is layered under
  the knob-controlled sweep for a less mechanical sound, and not something
  `docs/synth1-params.md` or the version history mentions.
- Does the period move with the delay time (parameter 52) or the note's own
  pitch? Either would point at the loop's own round-trip time or the input's
  fundamental as the second frequency the 2.94 Hz sweep is beating against,
  rather than an independent internal oscillator.

The manual's own changelog, decoded from the Shift-JIS the file's Japanese
sections need (`iconv -f SHIFT_JIS -t UTF-8`), confirms feedback and short
delay times are meant to interact strongly: "超ショートtime(0.05ms)を出せる
ように変更（feedbackと組み合わせて低域ブースト可能）" -- changed to allow a
super-short time (0.05 ms), which combined with feedback can boost the low
end. Nothing in the manual or changelog describes a second internal
oscillator, wander, or ensemble modulation, which the questions above were
checking for -- so whatever this is, it is not a documented feature this
project simply hasn't wired up.

Four measurements settle where the seven-second cycle actually comes from:

- **Not the feedback ceiling.** Raising this engine's clamp from 0.99 to
  0.9995 and re-running the 180 s hold left its autocorrelation exactly where
  it was -- noise, no lag above roughly 0.05. Whatever is missing is not a
  matter of degree.
- **A render long enough to resolve this engine's own period, if it has one
  at the patch's real rate, found none.** 600 s (25 potential lag-24 cycles
  at even a generous guessed period) gives a best peak of 0.118 at lag 53 --
  indistinguishable from noise -- against the reference's 0.847 at lag 48
  measured the same way, on the same data length. This engine is not a
  slower version of the same oscillation; at 2.94 Hz it does not have one.
- **Pitch matters.** The cycle is present at note 60 and gone at note 72, an
  octave up -- ruled out as an independent internal timer, since one would not
  care what note is playing.
- **Harmonic content matters more than pitch does.** Reducing brastring to a
  single sine oscillator (`0,0` and `5,0`, oscillator 1 alone) removes the
  cycle from the *reference* too -- both engines' autocorrelation collapses to
  near zero past lag 5. So the seven-second cycle is not simply "this note
  resonates and that one doesn't" -- it needs harmonic content to have
  something to resonate *with*, which reframes the open question. It is not
  "why does this engine's feedback loop fail to sustain a resonance" -- a pure
  sine shows neither engine sustains one, which is presumably correct in both
  cases. It is "why does brastring's actual, harmonically rich oscillator
  content line up with one of the feedback loop's resonant frequencies closely
  enough to lock in the reference, and not closely enough in this engine's
  rendering of the same patch." That is a question about this engine's
  oscillator's exact harmonic spectrum next to the reference's at this specific
  patch and note, not about the chorus in isolation -- a different, and
  differently scoped, measurement from everything else in this section.

## Chasing the spectrum: two real, partial answers and one still open

`s1probe oscspectrum` renders a patch with the chorus forced off (parameter 66
to 0) and prints both engines' FFT power, bin by bin, over a chosen window --
built to answer the question the section above landed on: does this engine's
oscillator put energy in the same place the reference's does, upstream of the
chorus entirely.

```
build/s1probe.exe oscspectrum "ext/synth1/Synth1/Synth1 VST64.dll" patches/incoming/soundbank00/001.sy1 --lo 150 --hi 350
```

At the default analysis point (0.3 s in) this engine sits 25-43 dB below the
reference almost everywhere in 150-350 Hz outside the fundamental itself. Two
things account for a large share of that gap, and one does not.

**FM sidebands, mostly accounted for.** Brastring's LFO1 targets FM (parameter
41 stored 5, resolved position 5 in the seven-state destination enum -- `.Fm`,
not `.Inert` at position 4, correcting an earlier misreading in this document)
at full depth. Zeroing it (`44,0`) narrows the gap close to the fundamental to
under a decibel -- 254.9 Hz reads -33.2 dB reference against -32.9 dB this
engine, 257.8 Hz reads -8.4 against -8.2. So the close-in skirt, within roughly
30 Hz of the fundamental, is FM sidebands and osc1/osc2 detune beating, and
this engine reproduces it correctly once the same modulation is applied. LFO2
(amplitude, parameter 46 stored 3, `.Amplitude`) contributes negligibly by
comparison -- zeroing it on top changed almost nothing.

**A real, separate filter calibration gap -- small, but confirmed.**
`cutoffprobe --sweep sustain`'s `--file`-style comparison now has an "our Hz"
column (`open_ours`/`corner_ours`, mirroring the reference-side functions), so
this engine's own corner can be read the same way, at the same settings,
without hand arithmetic:

```
build/s1probe.exe cutoffprobe "ext/synth1/Synth1/Synth1 VST64.dll" --sweep sustain --cutoff 75 --amount 37 --type 1 --res 10 --values 0,16,32,48,64,80,96,112,127
```

```
  stored  corner Hz     fraction    if linear     our Hz    our oct
      16        494       0.1279       0.1260        636      +0.36
      32        343       0.2570       0.2520        409      +0.25
      48        238       0.3856       0.3780        282      +0.24
      64        170       0.5051       0.5039        198      +0.23
      80        116       0.6405       0.6299        139      +0.27
      96         81       0.7656       0.7559         98      +0.27
     112         57       0.8877       0.8819         68      +0.23
     127         42       1.0000       1.0000         48      +0.21
```

This engine's corner sits a consistent 0.21-0.36 octaves above the reference's
across the whole sustain range, at brastring's own settings -- type 1, resonance
10, the low-resonance region this document already flagged, twice, as not yet
measured cleanly (the sustain-fraction section and the peak-frequency section
above). Real, and worth its own fix, but a 24 dB/octave slope only buys about
6 dB from a 0.25-octave cutoff shift at a fixed frequency -- nowhere near the
25-43 dB gap `oscspectrum` reads. This explains a slice of the discrepancy, not
the bulk of it.

**What is still unexplained.** With FM and LFO2 both zeroed, and the fundamental
region matching closely, a residual 10-35 dB gap remains from roughly 150-230 Hz
and 290-350 Hz -- and it is not static. Moved to 1.5 s into the sustain (chorus
still off), the reference's floor in that region *rises* -- 149 Hz goes from
-59 dB at 0.3 s to -38 dB at 1.5 s -- while this engine's *falls* further, -92
to -101 dB. Opening the filter fully (`19,127` `20,0`) shrinks the gap to a few
dB, which says the filter is where it lives, not the raw oscillator; zeroing
resonance alone while leaving the cutoff and its envelope motion in place barely
moved the gap at all, which rules resonance back out as the main lever and
leaves the cutoff's own trajectory -- not just its sustain value, which the
table above already covers, but however it got there -- as the remaining
suspect. Not measured yet: the filter's response *during* the attack/decay
sweep itself, before either engine reaches the sustain corner the table above
compares. That is where a growing-over-time floor with the filter's own
envelope motion as the only remaining candidate would have to come from, and it
has not been isolated the way FM and the sustain corner were.

## Why the filter has more to say than its coefficients: it is not a ladder

The unofficial manual (Zoran Nikolic's, compiled from Daichi's own text) settles
what "the filter's own trajectory" in the last section's open question actually
is, by naming what the 24 dB path *is*: "This is the classic synth filter used
in the Minimoog and Prophet-5, among others. It cuts out high frequencies
rather drastically (24db=4 poles)."

`src/dsp/filter.odin`'s own header says what this engine's 24 dB path is
instead: "two TPT sections in series... a cascade rather than a single
fourth-order design," chosen because one topology-preserving-transform section
gives all four contracted responses -- low pass, high pass, band pass, notch --
from one set of coefficients, and a ladder would not. That was the right choice
for the contract it was built against. It is also, by construction, linear:
two TPT sections in series compute an exact fourth-order transfer function and
nothing else.

A Minimoog-style ladder is not linear. Each of its four stages is a transistor
pair, and every modelling treatment of it in the literature -- Stilson & Smith,
Huovilainen's Moog ladder papers, and the virtual-analog work that followed --
treats the per-stage saturation as the part that has to be modelled, not a
detail to abstract away: it is where the filter's harmonics beyond the
coefficients' own four poles come from, and it grows with drive and with
resonance feedback, both signal-dependent and both exactly the two levers this
investigation kept landing on.

That is a candidate that fits every measurement in the two sections above at
once, without a new one:

- **Filter-specific.** Opening this engine's filter emptied the gap in
  `oscspectrum`'s window; a linear filter run wide open has almost nothing left
  to saturate regardless of topology, so this is silent on which topology is
  right, but it is not silent on where to look, and ladder saturation lives in
  the filter and nowhere the oscillator test could have found it.
- **Broadband, not tonal.** Per-stage saturation is a nonlinearity, and a
  nonlinearity fed anything harmonically rich answers with energy at sums and
  differences of what went in, not at a single frequency -- a skirt, which is
  what was measured.
- **Grows with the hold rather than decaying from the attack.** Saturation
  tracks the signal driving it, not a fixed impulse response; if the filter's
  own resonant ring builds as the envelope settles toward sustain, its
  saturated harmonics build with it, matching `oscspectrum`'s -59 to -38 dB
  climb between 0.3 and 1.5 s far better than any linear ringdown would, since
  a linear filter's transient only ever decays.
- **Needs both near-unity feedback and harmonic content to become audible as
  the seven-second cycle.** A pure sine gives a saturating stage almost nothing
  to generate sidebands from, matching the sine test emptying the reference's
  autocorrelation too; a harmonically rich note gives it plenty, and the
  chorus's near-unity feedback is what turns an otherwise-buried few-dB texture
  into something a comb filter can lock onto and ring for eight cycles running.

**Not yet measured**, and this is squarely a "measure before touching code"
case given how large a change it is: how much saturation, at what drive
threshold, per stage or lumped; whether it depends on resonance the way a
true ladder's feedback-around-all-four-stages does, or is closer to a simple
per-sample soft clip; and whether it needs to sit inside the TPT cascade's own
feedback path to reproduce the resonance-coupled growth above, or can be
approximated after the fact without disturbing the null test's other results,
particularly the recent chorus feedback and 24 dB cutoff fixes this same
investigation started from and which are already validated against the full
bank. Implementing it before measuring which of those it needs would repeat
the mistake the resonance-0 cutoff table already made once today.

## The ladder saturation, measured, implemented, and reverted

It was measured. `s1probe filterdistortion` drives a bare sine through the
filter alone -- oscillator 1, sine, nothing else -- with the envelope pinned
flat and keyboard tracking off, so the filter is the only thing between a pure
tone and the harmonics read back afterward, and sweeps resonance at a fixed
cutoff and note:

```
build/s1probe.exe filterdistortion "ext/synth1/Synth1/Synth1 VST64.dll" --type 1 --cutoff 64 --note 60 --values 0,64,96,112,120,124,127
```

```
resonance    ref THD    our THD   ref peak   our peak
       0       -64.4      -65.6      -7.6       -5.0
      64       -66.1      -66.3     -11.4       -6.3
      96       -66.5      -67.0     -13.7       -8.0
     112       -66.6      -67.3     -13.6       -9.2
     120       -66.7      -67.6     -13.4       -9.7
     124       -66.7      -67.8     -13.3       -8.4
     127        -5.7      -67.9      +0.9       -0.4
```

The reference tracks this engine's already-clean response within a decibel
from resonance 0 to 124, then falls off a cliff at 127 -- THD from -66.7 dB to
-5.7 dB, peak level from -13.3 dBFS to +0.9, in the last three steps of the
knob. This engine's THD does not move at all. That is genuine self-oscillation,
exactly what the manual's resonance section describes ("the filter will start
to self-oscillate... adding a ringing quality") and exactly the shape of
nonlinearity a ladder ahead of its four linear poles would produce and a
cascade of two exact TPT sections cannot: `soft_clip` composed with a linear
cascade is still linear everywhere below its own threshold, and nothing in the
signal here was reaching one.

**Built.** `svf_process` gained a resonance-scaled drive on `x - s.ic2eq`, the
term that plays the same role in a TPT section that a stage's own input plays
in a ladder: `drive = 1 + RESONANT_DRIVE_SCALE / k`, small near the identity
everywhere `k` is not and large only where `k` itself is, so it costs nothing
on the vast majority of patches that never turn resonance up far enough to
notice. Gated to the 24 dB path specifically (`resonant: bool` threaded through
from `filter_process`'s own `slope == .Slope_24`), because the first version,
applied everywhere, failed `tests/dsp/dsp_test.odin`'s stability sweep: 24 dB's
`k` is the square root of the requested damping and never reaches the 12 dB
path's own floor, so the same constant handed a 12 dB Band_Pass section a drive
of roughly 300 at its minimum damping and a state that no longer settled. Fit
against the sweep above, `RESONANT_DRIVE_SCALE = 0.1-0.3` put the peak level at
resonance 127 within 0.1 dB of the reference's, at every cutoff and scale
tried.

Two refinements, both tried and both fully documented above before being
removed along with the rest: an asymmetric term to reach the reference's
even-harmonic-dominated distortion (-5.8 dB even against -23.6 odd, where
`soft_clip` is an odd function and structurally cannot produce even harmonics
at all), which made both the level match and the THD worse at every
coefficient from 0.02 to 0.35 rather than better -- the nonlinearity sits
inside the resonant loop, and this particular term detuned its buildup instead
of colouring an unchanged peak; and a second gate on `f.g` (small exactly where
cutoff is small), added after full-bank testing below found one clear failure
and aimed at that specific failure rather than derived independently.

**Full-bank verdict: reverted.** `s1probe compare` over the same 123
comparable patches this document uses throughout moved the aggregate by
nothing worth reporting -- spectral mean 9.70 to 9.71 dB, everything else
inside a hundredth. That flat aggregate has an explanation this document
already had the tool to check: **exactly one factory patch reaches resonance
127**, the setting the whole fix is about.

```
type=1  resonance>=112, whole bank:
  123.sy1 "SpaceShip"    resonance 127, cutoff 5
  087.sy1 "High String"  resonance 117, cutoff 93
  083.sy1 "Solo Lead"    resonance 115, cutoff 33
```

087 and 083 sit below the cliff the sweep above measured -- resonance 117 and
115 read within a decibel of this engine's already-clean response in the
reference too, per the same sweep table, so the fix has almost nothing to do
there and moved them by under a decibel. 123 is the one patch actually at the
cliff, and it is a regression: 6.08 dB before any of today's filter work, 7.54
with the 24 dB cutoff fix alone, 8.67-11.44 with the resonant drive added on
top depending on the scale tried, worse at every scale from 0.02 (where the
drive is too weak to do anything, at either 123 or the calibration point) to
0.3. 123's own settings -- cutoff stored 5, nine octaves below the note the
sweep above was measured at -- sit far enough from where the fix was
calibrated that scaling the drive down with `f.g` recovered part of the
regression (11.44 to 8.67 dB) without cost at the calibration point, but not
all of it, and no amount of further tuning changed the fact that stood
underneath both attempts: **there is no patch in the factory bank this fix
measurably helps**, and the one patch it measurably touches, it hurts.

Reverted in full -- `svf_process`, `filter_process` and the two constants are
back to exactly what they were before this section, confirmed by re-reading
the functions against what this document quoted at the start of the
investigation, and by `tests/dsp/dsp_test.odin` passing again including the
stability sweep the first attempt broke. `s1probe filterdistortion` stays in
the tree as the instrument that found the self-oscillation cliff and would be
needed again by anyone re-attempting a fix; the finding itself -- the cliff is
real, it is where the manual says a ladder's self-oscillation lives, and this
engine does not have it -- stands. What was not found is a way to add it that
the factory bank, which is what any change here is ultimately answerable to,
agrees was worth having. A patch-specific or cutoff-and-resonance-jointly-
measured version might; a single global drive constant, fit against one
calibration point and unable to reproduce the reference's even-harmonic
balance at all, is not that version.

## The delay-line interpolation is linear, and the bank says keep it

The unofficial manual says of the chorus/flanger section: "The special care of
the delay-lines interpolation was taken to minimize aliasing." `delay_line_read`
does the crudest thing that works -- `lerp32` between the two neighbouring
samples -- so that sentence reads as a direct claim that the reference does
something this engine does not.

It also had a mechanism attached to it, and a specific open question to answer.
Linear interpolation is not merely approximate: it is a lowpass whose cutoff
depends on the *fractional* part of the delay, transparent at a whole-sample
offset and 3 dB down at a quarter of the sample rate at a half-sample one. A
chorus sweeps its tap, so that loss sweeps with it; a chorus with feedback
sends the signal through the same interpolator on every round trip. At the
reference's 15.12 ms and near-unity feedback that is 66 passes a second, and a
loss of 0.019 dB at 1 kHz -- nothing once -- is 8.6 dB over the ~460 passes in
the seven-second window where the section above measures a strong width cycle
in the reference and none at all in this engine. A comb bleeding its high end
away every pass is a plausible reason this engine's chorus settles flat where
the reference's keeps evolving.

Two replacements were implemented and measured against the whole bank.

- **First-order allpass**, which is what Dattorro's *Effect Design Part 2:
  Delay-Line Modulation and Chorus* recommends for exactly this job, and the
  strongest possible test of the mechanism above: an allpass has unit magnitude
  at every frequency by construction, so it cannot accumulate that loss however
  many times the signal goes round. Implemented with one recursive state per
  tap (two taps per channel at type 4, so four), and with the fractional part
  kept in [0.5, 1.5) rather than [0, 1) -- the coefficient (1-f)/(1+f) tends to
  1 as f tends to 0, a pole arbitrarily close to the unit circle that takes
  arbitrarily long to settle after the delay moves, which on a swept tap is
  every sample.
- **Four-point cubic** (Catmull-Rom), the stateless alternative: far flatter
  than a line, but a plain FIR, so a tap whose delay moves every sample cannot
  leave it mid-transient the way the recursive allpass can.

**The mechanism is falsified.** With allpass interpolation the width
autocorrelation on 001.sy1 over 180 s is unchanged to three decimals -- best
peak 0.055 at lag 7 against the reference's 0.739 at the same lag, exactly
where it sat with linear. The interpolator was verifiably live and doing
something: `s1probe chorusfb` moved the measured loop gain at stored 127 from
0.998 to 0.974 against the reference's 0.980, a small improvement. It simply
has nothing to do with why this engine's chorus does not develop the
reference's slow cycle.

**And the bank prefers linear, monotonically.** Same 123 comparable patches,
only the interpolator changed:

```
                    spectral mean   median
  linear (shipped)       9.71 dB    9.26 dB
  cubic                  9.97 dB    9.43 dB
  allpass               10.63 dB    9.95 dB
```

That ordering is the useful finding, and it is worth being careful about what
it does and does not say. It is not "linear interpolation is better" in any
absolute sense -- by every ordinary measure both replacements are more
accurate reconstructions. It is that this engine matches the *reference* best
with linear, and matches it monotonically worse the more accurate the
interpolator gets. The straightforward reading is that the reference's own
delay line interpolates linearly, or does something whose audible behaviour is
close to it, and that the manual's "special care... to minimize aliasing"
refers to something other than the interpolation kernel -- the sentence sits in
a paragraph about the effect being "modeled quite accurately as a linear
feed-forward Comb Filter", and may well be describing the delay-line
modulation's own band-limiting rather than the fractional read.

Both replacements reverted; `delay_line_read` is back to `lerp32` and the
`Chorus` struct back to a line pair and a phase, with no leftover interpolator
state. The seven-second width cycle remains unexplained, and the list of
things it is *not* is now longer by one: not the LFOs, not a loudness
artefact, not the feedback ceiling, not a longer-period version of the same
oscillation, not a pure-tone effect, and not the delay-line interpolation.

## The factory bank is `ver=105`, and five of its parameters changed meaning

The seven-second cycle was never real. Neither was the "ghost". The chorus was
never the problem, and neither was the filter. **The entire factory bank is
saved in a file format version whose parameters do not mean what this engine
read them to mean**, and every investigation above was chasing the consequences
of one misreading.

The reference's own changelog, Ver1.07(alpha), 2005.10.1:

```
Chorus/Flangr
	feedbackを+/-両方かけられるように変更
Filter
	AMOUNTのマイナス値対応
Tempo Delay
	旧levelつまみは廃止し、原音とディレイ音とのバランス調整式とした(d/w)
```

"Changed so that feedback can be applied both + and -"; "support for negative
values of AMOUNT"; "the old level knob was abolished and replaced with a
balance between the dry sound and the delayed sound". Three knobs that were
one-sided became two-sided, or changed their quantity entirely, in v1.07.

**Every file in the factory bank is `ver=105`.** All 128 of them, saved by
v1.05, two versions before that change. The reference converts them when it
loads them. This engine read the `ver=` field into `Patch.version` and never
looked at it again.

**The measurement.** Loading a factory patch into v1.13, changing nothing, and
saving it back writes a `ver=113` file, and the diff between the two *is* the
conversion table. Five patches were converted this way -- 001 brastring, 011
MusicBox, 023 Harmonica, 083 Solo Lead and 122 Wind, chosen to spread the
values of the parameters in question as widely as the bank allows -- and
`parse_sy1` now reproduces all five **exactly**, on every parameter present in
both files:

```
  21 filter amount    63 + old*64/127, rounded  0->63 18->72 37->82 43->85 73->100
  37 delay dry/wet    floor(old/2)              39->19 17->8 40->20 44->22
  55 chorus feedback  measured points only      0->64 (x3), 78->64, 127->6
  54 chorus rate      measured points only      19->24, 26->29, 64->50 (x3)
  52 chorus delay     measured points only      16->19, 23->24, 64->64 (x3)
  16/18/26/28         one shared curve, 13 pts  8->0 28->23 39->38 47->47 ...
  50/51               left alone -- not a function of the value
```

The four envelope-time parameters share a single curve: 105 -> 100 appears for
16 and for 18, 64 -> 62 for 18, 26 and 28, 68 -> 66 for 26 and 28. Its offset
runs -8 at the bottom, 0 near 47, -2 in the sixties and -5 in the nineties,
which is a remap between two time curves rather than a gain -- v1.08's own
changelog lists envelope changes.

55 and 54 are stored as measured points rather than fitted laws, because no law
fits: 0 -> 64 three times over, but 78 also lands on 64 and 127 lands on 6, and
those two come from the only patches whose chorus *delay time* moved as well,
which suggests the section is recomputed as a whole rather than knob by knob.
50 and 51 are refused outright: the same input, 127, converts to 64, 90, 125
and 95 in four different patches, so no function of the value alone can express
them. Parameters 75 and 93 differ too, but they are *absent* from every
`ver=105` file and Synth1 keeps whatever the editor already held -- session
state, not a rule -- and unison is off in all of them, so it is inaudible.

**Two of the three are sign errors, not approximations.** Parameters 21 and 55
went from one-sided to centred on 64, so reading them raw does not merely
misplace a value, it puts it on the wrong side of zero. Brastring's `21,37` is
*negative* filter envelope amount read raw and *positive* after conversion.
Its `55,0` -- the value **124 of the 128 factory patches carry** -- is -99%
feedback read raw and **0%** after conversion.

That is the whole ghost. Re-running `s1probe chorusstability` on 001.sy1 with
the conversion in place, the reference now reports `055 chorus feedback = 0 %`,
and the seven-second cycle **disappears from the reference too**:
autocorrelation at lag 7 falls from 0.739 to -0.035, both engines are flat
noise, and the mean widths agree at 0.242 against 0.231. The cycle was a real
property of a chorus at near-unity feedback -- and no factory patch has ever
been at near-unity feedback. Every measurement of it was of a configuration
that only existed because this engine put it there, and then faithfully drove
the reference into it too.

**Why nothing above could have caught it.** `s1probe compare` pushes the parsed
values into the reference through SetChunk. Before this fix it was pushing the
same unconverted numbers this engine was using, so both sides made the
identical misreading and agreed with each other. A null test compares two
engines against each other; it cannot see an error in what the *file* means,
because that error is upstream of both. Every "the reference does X and we do
not" result above was really "the reference does X *when driven with values it
would never load*".

## The chorus rate at stored 50 is not the defect

Converting parameter 54 is what costs the bank its remaining ground: with it,
the aggregate is 7.65 dB mean and 7.15 median; without it, 7.46 and 6.59, and
three chorus patches (086, 088, 103) each recover about 2.7 dB. The obvious
reading is that this engine's chorus rate mapping is wrong near stored 50.
It is not, and three measurements say so:

- **The hertz are right.** `display_number(54, ...)` reads the reference's own
  display string, and stored 50 parses cleanly as 0.99 Hz against stored 64's
  2.94 Hz. Nothing is being mis-mapped.
- **The width is right.** `s1probe choruswidth --sweep rate` over stored 19 to
  80 matches the reference within 0.01 at every setting -- 0.538 against 0.546
  at stored 50 -- with the channel correlation matching to three decimals.
- **The phase is right.** `s1probe chorusphase`, added for this, isolates the
  chorus into the side signal (the dry is centred, so L-R is the wet alone),
  takes its envelope, and cross-correlates the reference's sweep against this
  engine's. The best lag is **0.0 ms at every rate tested**, and the
  correlation at zero lag equals the correlation at the peak, 0.84 to 0.91.
  The two sweeps are in step.

So the conversion stays. It is verified against three independently converted
patches, and dropping it would mean playing these patches at 2.94 Hz where the
reference plays them at 0.99 -- audibly wrong, and bought with a null-test
score obtained by feeding both engines a value Synth1 never loads. That is
exactly the trap parameter 55 set earlier in this document, and the score being
better inside the trap is what made it one.

What the conversion exposes is a chorus defect, and it is **not** the delay.
Building `ver=113` variants of 088 -- so the parser converts nothing and the
values are set outright -- and toggling rate against delay separates them:

```
  rate 50, delay on    13.96 dB      rate 64, delay on    11.06     penalty 2.90
  rate 50, delay off   12.74 dB      rate 64, delay off   10.22     penalty 2.52
```

The penalty survives with the delay switched off, so "chorus and delay
together" was the wrong frame -- the delay contributes 0.4 dB of the 2.9. It is
the chorus alone, at a slow rate, and it needs *tonal* content: every noise
probe above is clean at that rate.

Two candidates were tested and neither is it. The **effect order** was swapped
to chorus-before-delay -- `engine.odin`'s own comment concedes the order was
taken from the panel layout rather than measured, and v1.06's changelog lists
"modify Delay<->Chorus/Flange patching" -- and the bank moved by 0.01 dB.
The **parameters absent from `ver=105`** were checked against what Synth1 fills
in for them, in case a delay type or spread was defaulting differently; only
75 differs, and unison is off in all of these patches.

The **depth curve is the defect**, and finding it took building the instrument
this section originally closed by asking for.

`binding.odin` computes `(exp(K*u)-1)/(exp(K)-1)`, and the four-point
verification table in the comment above it did not describe the constant beside
it: the table is `K = 6`, the constant was `2.0`. The constant had been retuned
against the bank at some point and the table left stale -- which is how a large
error survived in a file that documents everything else. Setting `K` back to 6
to match the table made the bank worse, so neither number was right and the
comment could not settle it.

### The instrument: `s1probe chorusdepth`

A swept tap Dopplers a tone, and for a tone the relation is closed-form rather
than statistical. With `D(t) = centre + swing*sin(2*pi*r*t)` the demodulated
phase against a fixed `f0` reference is exactly `-2*pi*f0*D(t)`, so the delay is
already in the phase. Its peak-to-peak swing over one sweep is
`2*pi*f0*(2*swing)`, giving

```
  swing = (phi_max - phi_min) / (4*pi*f0)
```

with no derivative and no transform. That is what makes a 0.99 Hz sweep free to
measure: a transform would have to resolve sidebands spaced by the sweep rate,
a third of one bin at this project's FFT size, which is precisely why
`chorusprobe` returns nothing at these settings and `chorustrack` reports 5.10
Hz for a 0.99 Hz sweep.

Two details are load-bearing, and both were found by the first version being
wrong. **Differentiating the phase does not work**: one sample of a 0.99 Hz
sweep moves it by around a millionth of a radian, below the arctangent's own
noise, so the derivative is noise multiplied by the sample rate -- measured that
way a *static* tap read as 135 ms of swing on a 15 ms line. Using the phase
excursion itself removes the problem entirely. **The release tail must be
excluded**: past the note off the tone decays into the noise floor where the
phase wanders without bound, and an unbounded wander is exactly what a
peak-to-peak measurement reports as a very deep chorus. That one cost a second
round of implausible numbers -- 28 ms of swing at depth 0 -- before it was found.

The wet is isolated by rendering the same patch with parameter 66 on and off and
subtracting, which is exact for a sine source; the diagnostic that proved it
reads `wet/dry = 1.00` on both engines. Type 1 is used so the wet is a *single*
swept tap and the closed form applies without averaging two of them.

It self-checks at both anchors: a static tap reads 0.000 on both engines, and
full depth reads 15.66 ms against the reference's own 15.12 ms centre delay --
which incidentally settles a question `binding.odin` recorded as unmeasured,
since full depth really does swing the tap by the whole centre delay.

### What it measured

```
  stored      0     16      32      64      96     112     127
  reference  0.000  0.0071  0.0229  0.0957  0.3286  0.5957  1.0357
  k = 4.65   0.000  0.0077  0.0215  0.0909  0.3149  0.5733  1.0000
  k = 2.0    0.000  0.0449  0.1026  0.2723  0.5533  0.7567  1.0000
```

`k = 4.65` is the least-squares fit in log space at 0.060, against 1.195 for the
shipped 2.0 and 0.678 for the comment's 6.0. At the quiet end of the knob the
shipped curve was **seven times too deep**; at stored 64 -- the setting the three
regressing patches use -- it was 2.9 times too deep. Re-measured after the
change, the ratio of ours to the reference's is 0.97 to 1.01 across the whole
knob.

On the bank, spectral 7.65 -> 7.57 mean and 7.15 -> 6.90 median, level +0.91 ->
+0.67, null depth -3.40 -> -3.59, envelope median 2.28 -> 2.13. Every metric
improves except the envelope mean, which moves 0.02 dB the other way.

### What it did not fix

086, 088 and 103 get *worse* -- 088 from 13.99 to 16.81 -- even though the
constant they run on is now verified correct to within 3% against the reference
at their own depth setting. They are the three the chorus rate conversion
exposed in the first place, they are now the worst chorus patches in the bank,
and whatever is wrong with them is neither the rate mapping, the sweep phase,
the effect order, nor the depth curve -- each of those has now been measured
against the reference directly and matches. Correcting the depth has removed the
last of the plausible-looking explanations rather than the fault.

**On the bank.** Same 123 comparable patches, and this is the largest single
improvement in this document by a wide margin:

```
                        before    after
  spectral mean          9.70      7.57   dB
  spectral median        9.26      6.90   dB
  envelope mean          6.77      3.23   dB
  envelope median        4.90      2.13   dB
  level mean            +1.02     +0.67   dB
  null depth            -1.27     -3.59   dB
  stereo width mean    -0.013    -0.013
  tuning, within 10 cents   20 of 29     104 of 106
  tuning, an octave out            3              0
  spectra that will not align     94             17
```

Envelope error more than halved. Null depth -- the metric this document has
called uninformative from the beginning, because it requires genuine phase
agreement before it says anything -- went from -1.27 to -3.25 dB, which is the
first time in this project it has moved like that. The tuning block is the
clearest signal: 100 of 103 comparable patches now agree within ten cents, none
are an octave out, and the number of patches whose spectra could not be aligned
at all fell from 94 to 20.

76 patches improve by more than a decibel against 18 that regress. The worst
regression is 083.sy1 at +20.8 dB, and it is not yet understood; isolating the
three conversions one at a time on single patches gave contradictory answers,
which is the tail-carryover trap this document records elsewhere -- single-patch
`compare` runs are not independent. Measured properly, as full-bank aggregates,
the ordering is unambiguous: all three conversions (7.47 dB) beats parameter 55
alone (8.39 dB) beats no conversion at all (9.70 dB).

**What this invalidates above.** The chorus feedback section's `±0.99` clamp
was fitted at stored 0, a setting no `ver=105` patch reaches once converted; it
still applies to `ver=113` files that genuinely store 0, so it stays, but its
bank-wide justification is gone. The 24 dB filter and ladder-saturation
sections were measured through SetChunk at explicit values and are unaffected
as measurements, though the bank numbers quoted in them predate this fix. The
open question about brastring's filter skirt growing over a held note should be
re-measured before any more work goes into it: parameter 21 was reading with
the wrong sign on that patch the entire time.

## The arpeggiator, measured and implemented

It was the last section that was parsed, shown in the interface and bound to
nothing. A patch with it switched on held the chord the reference was stepping
through, and eight of the 128 factory patches switch it on.

**Method.** `s1probe arpprobe` holds a chord, renders the reference, and finds
the attacks in the amplitude envelope. Three things come out of the same
render: the step period from the spacing of the onsets, the pattern from the
pitch measured inside each step, and the gate from how much of each step has
sound in it.

Two things had to be got right before any of it read correctly.

The first was the onset detector. Looking for a frame twice as loud as the one
before it is the obvious test and is useless: a sustaining tone ripples at its
own period, every ripple clears it, and the probe reported the same 0.046-beat
period for all nineteen divisions -- which was its own refractory limit measured
back to itself. A gated step is a loud stretch followed by a quiet gap, so what
marks it is the envelope crossing *up* through a high threshold having first
fallen below a low one. Two thresholds, so ripple around one level cannot
retrigger it.

The second was the host. `effProcessEvents` dispatched once per note looked
equivalent to one dispatch carrying three, and is not: Synth1 keeps the most
recent list rather than accumulating them, so a three-note chord left one note
held and dropped the other two. The pattern was invisible until this was fixed
because every step played the same pitch -- the last note sent.

**Step period.** Parameter 33's nineteen displays are a notation that turns out
to be plain arithmetic. `(N)` is a 1/N note and so 4/N beats, `(a)+(b)` is the
sum, and `(N) /3` is that value divided by three:

| display | measured beats | arithmetic |
|---|---|---|
| `(1)` | 4.0000 | 4 |
| `(2)+(4)+(8)` | 3.5000 | 2 + 1 + 0.5 |
| `(2)` | 2.0000 | 2 |
| `(1) /3` | 1.3320 | 4/3 |
| `(4)` | 1.0000 | 1 |
| `(8)+(16)` | 0.7480 | 0.75 |
| `(8)` | 0.5000 | 0.5 |
| `(16)` | 0.2480 | 0.25 |
| `(32)` | 0.1240 | 0.125 |
| `(32) /3` | 0.0400 | 1/24 |

All nineteen were measured and all nineteen fit, within the 2 ms frame
resolution. The `/3` reading is worth stating because it is **not** the usual
triplet convention: a musician writing "quarter triplet" means two thirds of a
quarter, while the reference means one third of it. `(1) /3` came out at 1.332
beats where two thirds of a whole note would have been 2.667.

The fastest six needed a percussive amplitude envelope on the base patch before
the steps could be told apart at all, because at 1/24 of a beat the reference's
own release smears one step into the next.

**Pattern.** Parameter 31 is display-keyed and stores 1..4. Holding 60, 64, 67:

| stored | measured sequence |
|---|---|
| 1 up and down | 60 64 67 64, repeating |
| 2 up | 60 64 67, repeating |
| 3 down | 67 64 60, repeating |
| 4 random | 67 64 64 60 67 67 60 67 ... |

Up and down is 2n-2 steps, not 2n: neither the top nor the bottom repeats on
the turn.

**Octave range.** Parameter 32 stores 0..3 for one to four octaves, and each
extra octave is a whole copy of the chord transposed up twelve. Range 1 measured
60 64 67 72 76 79; range 3 ran to 103. The position runs through the chord
first and the octave second.

**Gate.** Parameter 34 is linear in the stored value, with no curve on it: the
fraction of the step that sounds is the stored value over 127. Measured 0.13 at
16, 0.51 at 64, 0.76 at 96 and 1.00 at 127. A stored 0 is a note of no length
and therefore silence.

**Result.** Against the bank, with 116 of 119 measurable patches untouched
because their arpeggiator is off:

| patch | before | after |
|---|---|---|
| 110 Sequence 3 | 21.36 dB | **7.81 dB** |
| 111 Sequence 4 | 6.36 dB | 6.06 dB |
| 126 Machine Gun | 8.50 dB | 8.64 dB |

Bank mean 7.57 dB to 7.45 dB. 110 was the third-worst patch in the bank and is
now near its mean.

126 is the one that got worse, and only marginally on the spectrum -- but its
envelope error went from 8.58 dB to 17.83 dB, which is a real regression on that
metric and is not explained yet. It is the fastest of the three, at `(8) /3` and
a gate of 16, so the suspicion is the voice allocated per step against a release
that outlasts the step. Recorded rather than tidied away.

**Settled later, and the suspicion above was wrong.** The arpeggiator is not
involved: with the delay off, 126's step spacing agrees with the reference
exactly at every parameter-33 state tested, and its envelope error is 4.36 dB.
The fault was in the *delay*, whose `/3` states were all playing at twice the
reference's time -- and 126's arp step happened to be exactly twice its delay
time, so the doubling moved the echo from halfway between steps onto the next
step, where it vanished. See "The delay's `/3` is a division, not a triplet"
below; 126's envelope error is now 2.82 dB.

**Still not measured.** Whether the reference's arpeggiator re-triggers one
voice or allocates a new one per step; what it does when a key is added or
removed mid-pattern; and whether the step clock is free-running or locked to the
host's bar line. This engine allocates per step, rebuilds the sequence from the
held keys on every step, and free-runs from the first key press.

## Ping-pong delay, measured and implemented

Parameter 82 had three measured states but the engine stored only a boolean.
State 1 selected cross feedback and state 2 therefore fell through to normal
stereo, despite the reference's changelog naming it ping-pong.

**Method.** A fully wet, centred sine transient used an eighth-note delay at
120 BPM (250 ms), feedback 100 and no chorus or extra effect. Reference and
engine WAVs were measured in 80 ms windows around the first six repeats. The
old engine put every repeat in both channels. The reference sequence was left,
right, left, right, left, right.

The level law is also visible in that one render. Reference repeat ratios were
1.0000, 0.7874, 1.0000, 0.7874 and 1.0000. Stored 100 is exactly 100/127, and
the equal adjacent pairs mean feedback is applied once per complete
left-right round trip rather than once per hop. A second render at stored 127
held each pair at unity. The input to the first left repeat is the sum of the
two channels, not their average; hard-panning the probe halved its first repeat
relative to the centred render.

**Result.** Parameter 82 now binds to explicit stereo, cross and ping-pong
modes. Ping-pong sums the input into the left line, passes that repeat to the
right line at unity, and applies feedback on the return to the left. The
feedback control now reaches the reference's measured unity instead of the old
chosen 0.95 ceiling.

After the change, the engine matched all six channel positions and the five
repeat ratios above to four decimal places. On the controlled probe, stereo
side/mid moved from 0.000 against the reference's 1.000 to 1.000 against 1.000,
and null depth moved from -2.43 to -2.94 dB. The shallow absolute null is from
the already-known source level and envelope differences in this deliberately
minimal patch; the routing and decay signature are independent of that gain.

A musical Solo Lead patch using state 2 improved from 19.30 to 14.99 dB mean
spectral error. The whole 128-patch Synth1 bank was also rerun in isolation
(123 rendered; five known reference crashes). Although its old file version
stores no parameter 82 values, it exercises the feedback correction: spectral
mean improved 7.45 to 7.44 dB and median 6.90 to 6.87 dB. Null median stayed
-2.25 dB, level bias stayed +0.06 dB, and no engine render was silent or
non-finite.

## Filter saturation, measured and implemented

Parameter 23 was still one of the engine's explicitly chosen laws. It drove a
generic soft clip with `drive = 1 + 8 * saturation`, then divided the result by
`1 + 2 * saturation`. At the top of the knob that trim lost 3.7 dB of peak
level. The reference loses none.

**Method.** `s1probe filtersaturation` was added beside `filterdistortion`. It
drives a sine through a non-moving filter and sweeps parameter 23, reporting
the fundamental, THD, RMS and peak for the reference and this engine. Repeating
the sweep at several amp-gain settings establishes their ordering: parameter 29
scales the completed saturation result and does not alter its normalised
transfer.

With the filter open and resonance off, every saturation setting has exactly
the same peak as saturation zero. The RMS and odd-harmonic series approach a
square wave as the knob rises. Both observations are described by one transfer:

```
y = tanh(drive * x) / tanh(drive)
```

Inverting the measured THD gives the drive curve. Selected knots are:

| stored 23 | drive | reference THD |
|---:|---:|---:|
| 2 | 0.110344 | -59.9 dB |
| 16 | 0.403366 | -37.7 dB |
| 32 | 0.812051 | -26.5 dB |
| 64 | 2.321027 | -13.9 dB |
| 96 | 6.096842 | -8.9 dB |
| 109 | 9.634074 | -7.9 dB |
| 122 | 15.213064 | -7.3 dB |
| 127 | 16.879008 | -7.2 dB |

The binding stores 23 measured knots, including the exact settings used by the
two worst saturation-heavy factory patches, and linearly interpolates between
them. The widest gap is eight controller states and stays below the probe's
0.1 dB THD resolution. Stored zero remains an exact bypass.

**Placement.** The shaper runs once on the completed filter response. This is
not just the convenient place to put it. With the filter open the reference's
transfer is identical in the 12 and 24 dB modes. Applying the same shaper after
each section of this engine's two-section 24 dB cascade compounds it: at stored
32, THD becomes -20.7 dB against the reference's -26.5 dB. One application
matches -26.5 dB in both slopes. At stored 127 both reference and engine read
-7.2 dB, and the engine's peak remains fixed just as the reference's does.

There is a boundary to that result. At a low cutoff the reference's four-pole
path generates more gain and harmonics than a linear cascade followed by one
tanh can: type 1, cutoff 33, saturation 122 reads -16.9 dB THD in the reference
and -41.2 dB here. Putting the shaper per section reaches the harmonics but
breaks the independently measured open-filter transfer. This is the nonlinear
four-pole topology gap documented in the earlier ladder investigation, not a
reason to distort the now-measured knob law to fit one operating point.

**Second boundary: two tones.** The transfer above was fitted by driving one
sine through a non-moving filter, and low cutoff was its only recorded limit.
The tracked substage factorial recorded further down this file is the first
two-tone test of it, and it opens a second limit with the filter fully open.
The probe's THD reading is the energy in the `f0` harmonic bins relative to
`f0`. With OSC1 sine plus OSC2 triangle four semitones up (`p5=96`), `p95=0`
and stored 23 = 64, the reference reads `-17.032`, `-17.175` and `-17.080 dB`
at notes 60, 48 and 72, while this engine reads `-36.147`, `-36.470` and
`-36.172 dB`. That is a note-stable gap of about 19 dB.

The single-tone cell of the same run still reproduces the fit exactly:
reference `-13.918`, `-13.912` and `-13.943 dB` against ours `-13.900`,
`-13.900` and `-13.899 dB`, which is the -13.9 dB knot tabulated above. The
matched `p23=0` control shows no comparable gap: reference `-41.969`,
`-41.245` and `-45.999 dB` against ours `-40.991`, `-40.992` and
`-41.737 dB`, a spread of 1.0 to 4.3 dB in a floor roughly 25 dB below the
saturated reading. The break therefore belongs to the shaper, not to the
oscillator pair or the measurement.

So a peak-normalised memoryless tanh matches the knob on one tone and puts far
too little energy into those bins on two. This is a named defect in the
implemented law. A candidate replacement was measured and is reported with the
substage factorial below; it was rejected by the corpus and factory gates, so
the shaper is unchanged and this boundary stays open.

**Bank verdict: kept.** The isolated 123-patch run, against the immediately
preceding ping-pong baseline:

| metric | before | after |
|---|---:|---:|
| spectral mean | 7.44 dB | **7.13 dB** |
| spectral median | 6.87 dB | **6.69 dB** |
| envelope mean | 3.10 dB | **3.07 dB** |
| level bias | +0.06 dB | +0.15 dB |
| null median | -2.25 dB | -2.25 dB |

The change lands where it should. Patch 032 falls from 18.90 to 8.34 dB mean
spectral error; patch 083, previously the worst patch in the bank, falls from
28.95 to 4.71 dB. The run produced no silent or non-finite engine renders. The
DSP suite now includes the measured peak invariance, two exact binding knots,
the over-unity stability sweep, and a regression guard that prevents the 24 dB
path from compounding the shaper.

## The low-resonance 24 dB corner and sustain states 0--16

The high-resonance cutoff table left two related loose ends above: patch 002
uses the 24 dB path at resonance 0, while `FILTER_CUTOFF_HZ_24` was measured
from the peak at resonance 107; and the filter-sustain check sampled every
sixteen states, so it did not establish what happens immediately above stored
zero. Both were measured directly.

**Low-resonance cutoff.** The envelope was pinned neutral, keyboard tracking
off, and the -3 dB corner was read against an open render at ten cutoff states
and six low-to-mid resonance settings. Selected rows:

| cutoff | res 0 | res 4 | res 8 | res 16 | res 32 | res 64 |
|---:|---:|---:|---:|---:|---:|---:|
| 44 | 86 Hz | 102 Hz | 118 Hz | 147 Hz | 170 Hz | 185 Hz |
| 64 | 255 Hz | 307 Hz | 355 Hz | 436 Hz | 506 Hz | 556 Hz |
| 80 | 637 Hz | 768 Hz | 884 Hz | 1078 Hz | 1234 Hz | 1349 Hz |
| 110 | 4586 Hz | 5114 Hz | 5592 Hz | 6245 Hz | 6668 Hz | 6896 Hz |

This is a continuous resonance surface, not a special case at exactly zero.
Most of its travel happens below resonance 32; by 64 it is already close to the
peak-at-107 readings (190, 567, 1356 and 6894 Hz at the same four cutoff states).
The difference at resonance 0 is 1.15 octaves at cutoff 64 and 1.09 octaves at
cutoff 80 -- large enough to explain a 24 dB low pass being tens of decibels
wrong above its corner.

The complete resonance-0 run resolved 121 of 128 cutoff settings and wrote
`build/filter_table_24_res0.odin`, since promoted to
`src/engine/filter_table_24_low.odin`: 23 Hz through 15.6 kHz. It also reproduced
the envelope-amount slope, 0.1630 octaves per state. That agreement matters:
the low-resonance defect is the base response, not a second envelope-amount
law.

This does **not** mean the parameter's internal frequency literally changes
with resonance. A -3 dB corner defined relative to the response's own maximum
moves as Q changes; that was why the resonance-0 table was previously rejected
as a global replacement. It does mean the current high-Q calibration is the
wrong audible response for the low-Q end of this engine's different topology.
The implemented fix therefore uses a resonance-conditioned response rather
than replacing the existing high-Q table globally.

**Sustain immediately above zero.** The first sweep used cutoff 100 and amount
20, but its full-depth endpoint approached the filter floor. A second sweep at
cutoff 110 and amount 50 kept the complete 2.2--2.5 octave trajectory inside
the analysed band. States 0 through 8 were measured individually, then every
second state through 16.

At type 1, resonance 0, the first four measured fractions were:

| stored 17 | measured | linear |
|---:|---:|---:|
| 1 | 0.0057 | 0.0079 |
| 2 | 0.0166 | 0.0157 |
| 3 | 0.0220 | 0.0236 |
| 4 | 0.0323 | 0.0315 |

Every point is within 0.0022 of linear, with the error alternating around it.
There is no low-end dead zone, offset, or hidden coarse state conversion. At
state 8 the fraction is 0.0719 against 0.0630, and at 16 it is 0.1432 against
0.1260; the deviation grows away from zero, but it is not a sustain-controller
curve. The same parameter through type 0 at resonance 0 reads 0.1273 at state
16, and through type 1 at resonance 16 reads 0.1299. A real parameter-17 curve
cannot depend on the selected filter slope and resonance; the measured corner
can, as the table above demonstrates.

Patch 002's own cutoff 44, amount 31 combination confirms that every low state
is active: its reference corners at sustain 0--8 are 86, 85, 83, 81, 80, 79,
77, 76 and 75 Hz. Normalising that trajectory against its floor-limited 23 Hz
endpoint makes it look strongly convex, but that is the same endpoint confound,
not evidence for remapping the controller.

**Implementation.** Binding now resolves the 24 dB corner by geometrically
blending the resonance-0 corner table into the resonance-107 peak table. Seven
measured resonance anchors (0, 4, 8, 16, 32, 64 and 107) define the blend, and
a measured topology correction converts the reference corner to this engine's
cascade coefficient. The correction fades near the DSP floor, where applying
its mid-band value unchanged raised the minimum corner from 23 to 28 Hz.

The amount sweep also exposed a more useful law than the earlier octave fit:
parameter 21 moves exactly **two parameter-19 states per amount step**. The
apparent octave slope changes only because the low-Q cutoff table is not
uniform in octaves. `voice_process` now clamps the full envelope destination
to cutoff states 0--127, applies the linear parameter-17 fraction to the
achievable state travel, and samples the same resonance-conditioned surface at
the resulting fractional state. Keyboard tracking and LFO modulation remain
octave offsets after that lookup.

Two controlled checks bound the result:

| probe | reference | engine after fix | error |
|---|---:|---:|---:|
| cutoff 44, amount 31, sustain 73, res 0 | 31 Hz | 32 Hz | +0.06 oct |
| cutoff 110, amount 50, sustain 64, res 0 | 1831 Hz | 1809 Hz | -0.02 oct |
| cutoff 110, amount 50, sustain 127, res 0 | 823 Hz | 813 Hz | -0.02 oct |

Across the neutral-envelope cutoff sweep, states 32--110 are within 0.03
octave and state 20 is within 0.07. At the analyser boundary state 0 still
reads 26 Hz against 23 Hz (+0.16 octave); this is the remaining floor/topology
error, not the old one-octave mid-band displacement.

**Bank verdict.** The isolated 123-patch run is deliberately recorded even
though the aggregate does not improve: spectral mean/median move from
7.13/6.69 to 7.26/6.87 dB, envelope mean from 3.07 to 3.02 dB, and brightness
bias from +0.05 to +0.02 octave. The controlled filter response is now right,
but some factory patches had the old bright cutoff accidentally compensating
other oscillator/filter-shape errors. Of the low-resonance 24 dB cases, patch
012 improves 4.46 dB spectrally, 014 improves 1.88 dB and 076 improves 1.71 dB;
patch 002 itself regresses 3.05 dB in the whole-patch spectral score while its
measured sustain corner improves from a +0.45-octave error to +0.06. The bank
cannot be used to justify preserving a known-wrong parameter law.

**Verdict.** Parameter 17 remains linear. The low-resonance 24 dB surface and
the state-domain envelope movement are implemented and directly verified; the
last isolated gap is the bottom 3 Hz at the DSP floor.

## FM before and through the moving filter

Fixing the low-resonance cutoff made 012 and 014 much better, but both remained
outliers, and 038 had the same tell: switching parameter 45 off made this engine
many decibels louder behind the moving filter while barely changing the
reference. `patchdiag` could show the level consequence but could not separate
an FM spectrum that was too wide from a filter trajectory that was too closed.

`s1probe fmfilter` is the focused instrument for that separation. With no file
arguments it runs 012, 014 and 038. It disables effects, LFOs, the oscillator
modulation envelope, arpeggiator and unison, then renders four variants through
both engines:

```
build/s1probe_fmfilter.exe fmfilter
```

- the patch's moving filter with FM;
- the same trajectory with parameter 45 at zero;
- FM through a neutral, wide-open filter;
- the wide-open no-FM control.

Four 4096-sample FFT windows follow the trajectory at 0.02, 0.12, 0.35 and
0.80 seconds. The probe reports RMS, centroid and sixth-octave spectral error
for every variant, then divides moving-filter RMS by its matching open control.
That last ratio is the filter's attenuation with the upstream FM spectrum
removed as a confound. An open-filter parameter-45 sweep is printed afterward.

**The defect is upstream.** With the old implementation at each fixture's own
FM setting, the open-filter centroids were:

| patch | parameter 45 | reference | old engine |
|---:|---:|---:|---:|
| 012 | 68 | 326 Hz | 6487 Hz |
| 014 | 43 | 277 Hz | 2887 Hz |
| 038 | 77 | 690 Hz | 5726 Hz |

The voice path multiplied the knob's linear 0..1 position by half a turn and
added that displacement every sample. It therefore made the deviation almost
independent of carrier frequency and treated the panel position as an already
resolved phase offset. The moving filters then rejected 12--23 dB more of that
ultrawide spectrum than the reference filters did. The recently corrected
cutoff trajectory was not responsible.

The static sweep establishes two missing semantics. FM depth is relative to the
carrier's per-sample increment, and parameter 45 is very strongly convex. The
reference barely moves through the lower quarter, then rises quickly above the
middle. Across the complete sweep and the three fixtures, the fitted peak
frequency-deviation ratio is:

```
depth = 96 * (position / 127)^5.5
phase displacement = osc2 * depth * carrier phase increment
```

States 43, 68 and 77 therefore resolve to 0.249, 3.091 and 6.124 carrier
frequencies, rather than 0.339, 0.535 and 0.606 half-turn offsets. Oscillator 2
still modulates oscillator 1, the displacement still accumulates into phase,
ring modulation still takes precedence, and LFO-to-FM continues to move in
parameter-45 controller space before this curve is applied.

At the representative 0.35 second moving-filter window, spectral error changes
from 14.61 to 3.15 dB for 012, 3.40 to 2.12 for 014, and 11.72 to 1.06 for 038.
The whole-patch isolated comparison is stronger still:

| patch | before | after | centroid, reference/engine |
|---:|---:|---:|---:|
| 012 | 10.36 dB | 2.15 dB | 262/261 Hz |
| 014 | 19.36 dB | 8.98 dB | 264/263 Hz |
| 038 | 9.10 dB | 0.93 dB | 271/272 Hz |

**Bank verdict.** Across all 123 comparable patches, spectral mean/median improve
from 7.26/6.87 to 6.77/6.23 dB, envelope mean from 3.02 to 2.67 dB, and null
depth from -3.63 to -3.96 dB. Fourteen patches have nonzero static FM: ten
improve, three regress and one is unchanged, for a 4.16 dB mean spectral
improvement in that group. 076 improves by 10.81 dB and the three fixtures by
8.16--10.38 dB. Patches 127 and 128 regress by 2.33 and 4.42 dB and remain the
important high-FM residuals; their spectra point at waveform/alias distribution,
not a reason to restore the linear phase-offset law that the direct sweep
disproves.

## The delay's `/3` is a division, not a triplet

126 Machine Gun was the bank's one genuine outlier. At 18.69 dB its envelope
error was 7.04 standard deviations above the mean and 9.7 interquartile ranges
above the third quartile; the next worst patch, 029 E Guitar 3, was 9.08 dB at
z = 2.81. Nothing else in the bank was within a factor of two of its z-score,
and it was the only value past even the 3.0x fence at 7.79 dB by any margin. The
three worst *spectral* patches -- 088, 086 and 001 at 16.72, 16.68 and 16.30 dB
-- all sit inside the ordinary 1.5x fence at 19.13 dB and are the top of a
smooth distribution, so they are the worst patches rather than outliers, and
they are not this section.

The cause was one line in `delay_display_beats`, and the arpeggiator note above
had guessed wrong about it.

**Where it is not.** Rendering 126 with the delay switched off (`65,0`) gives an
envelope error of 4.36 dB, and that number is *identical* before and after the
change, as it must be. Rendering it with the delay on but moved to any
non-triplet state gives 2.63 dB at `(32)`, 2.84 dB at `(16)` and 4.95 dB at
`(8)` -- again identical before and after. So neither the arpeggiator, the
envelope, the gate nor the FM is involved: only the `/3` states move at all.

**The sweep.** A purpose-built probe patch -- percussive click, `37,127` for
100 % wet, `36,0` for no feedback, `83,64` for no spread, arp, chorus, effect,
LFO and unison all off, written as `ver=113` so the pre-1.07 conversion cannot
interfere -- was rendered through the reference at all twenty of parameter 35's
states. Nothing is audible in that patch before the echo, so the first sample
above threshold *is* the delay time. At the harness's 120 BPM:

| state | display | reference | engine, before | before / ref | engine, after |
|---:|---|---:|---:|---:|---:|
| 0 | `0.1 msec` | 0.19 ms | 0.17 ms | -- | 0.17 ms |
| **1** | **`(32) /3`** | **20.90 ms** | **41.73 ms** | **1.997** | **20.90 ms** |
| **2** | **`(16) /3`** | **41.73 ms** | **83.40 ms** | **1.999** | **41.73 ms** |
| 3 | `(32)` | 62.56 ms | 62.56 ms | 1.000 | 62.56 ms |
| **4** | **`(8) /3`** | **83.40 ms** | **166.73 ms** | **1.999** | **83.40 ms** |
| 5 | `(16)` | 125.06 ms | 125.06 ms | 1.000 | 125.06 ms |
| **6** | **`(4) /3`** | **166.73 ms** | **333.40 ms** | **2.000** | **166.73 ms** |
| 7 | `(16)+(32)` | 187.56 ms | 187.56 ms | 1.000 | 187.56 ms |
| 8 | `(8)` | 250.06 ms | 250.06 ms | 1.000 | 250.06 ms |
| **9** | **`(2) /3`** | **333.40 ms** | **666.73 ms** | **2.000** | **333.40 ms** |
| 10 | `(8)+(16)` | 375.06 ms | 375.06 ms | 1.000 | 375.06 ms |
| 11 | `(8)+(16)+(32)` | 437.56 ms | 437.56 ms | 1.000 | 437.56 ms |
| 12 | `(4)` | 500.06 ms | 500.06 ms | 1.000 | 500.06 ms |
| **13** | **`(1) /3`** | **666.73 ms** | **1333.40 ms** | **2.000** | **666.73 ms** |
| 14 | `(4)+(8)` | 750.06 ms | 750.06 ms | 1.000 | 750.06 ms |
| 15 | `(4)+(8)+(16)` | 875.06 ms | 875.06 ms | 1.000 | 875.06 ms |
| 16 | `(2)` | 1000.06 ms | 1000.06 ms | 1.000 | 1000.06 ms |
| 17 | `(2)+(4)` | 1500.06 ms | 1500.06 ms | 1.000 | 1500.06 ms |
| 18 | `(2)+(4)+(8)` | 1750.06 ms | 1750.06 ms | 1.000 | 1750.06 ms |
| 19 | `(1)` | 2000.06 ms | 2000.06 ms | 1.000 | 2000.06 ms |

All six `/3` states are exactly twice too long. All fourteen others are exact to
the sample, so the sum arithmetic was never in question. In beats the
reference's law is unambiguous: `(32) /3` is 0.0417 = 0.125/3 and `(1) /3` is
1.333 = 4/3. That is division by three, and `(2/3) / (1/3)` is precisely the
factor of two observed. After the change every one of the nineteen musical
states reads the reference's own time.

Two things in that table are not the defect and should not be read as one. The
musical readings carry a constant +0.06 ms, which is the reference's delay-line
offset and shows up on state 0's fixed `0.1 msec` as well. And state 0 itself
sits one sample early here, 0.17 against 0.19 ms at 48 kHz -- that state takes
the non-musical branch, it is unchanged by this work, and 0.02 ms is below what
this method resolves.

**Why nobody caught it.** This engine already knew the answer. `ARP_STEP_BEATS`
in `src/engine/arpeggiator.odin` was measured separately with `s1probe arpprobe`
and says so in a comment: "`(N) /3` is that value divided by three ... it is
*not* the usual triplet convention -- a musician writing 'quarter triplet' means
two thirds of a quarter, while the reference means one third of it." Parameter
33 and parameter 35 spell the same nineteen symbols, and the vendor changelog
treats them as one display (`docs/synth1-readme-eng.txt:473`, Ver1.11: "change
delay arpegiator tempo display"). The nineteen musical delay states turn out to
be `ARP_STEP_BEATS` reversed, exactly. The two tables had disagreed by a factor
of two since both were written.

The vendor manual is where the wrong guess came from and it is worth naming,
because anyone implementing from the prose would make the same one:
`docs/synth1-readme-eng.txt:186` describes parameter 35 as "ranging from 1/32
note triplets to whole note". A 32nd-note triplet is 1/48 note, or 0.0833 beats.
State 1 measures 0.0417 beats, which is 1/96 note -- `(1/32)/3`. The label is
loose musical shorthand; the arithmetic is literal division.

And this is the project's named trap in its second form.
`test_delay_division_displays_parse_to_beats` had asserted the wrong law since
it was written -- its comment said "`/3` takes two thirds" and its cases were
`0.125*2/3`, `2/3`, `8/3`. It could never fail, because it checked the parser
against the convention its author had assumed rather than against anything
external. It has been rewritten to the measured beats, and
`test_delay_division_table_matches_the_measured_reference` now pins all twenty
states to the millisecond readings above *and* to `ARP_STEP_BEATS`.

**Result.** Only 7 of 123 patches move at all; the other 116 carry no triplet
delay state with the delay audible.

| patch | spectral | envelope | level | note |
|---|---:|---:|---:|---|
| **126 Machine Gun** | 6.11 -> **5.03** | 18.69 -> **2.82** | -3.16 -> -4.25 | the outlier, eliminated |
| **011 MusicBox** | 6.65 -> 6.64 | 8.01 -> **3.54** | +0.02 | was rank-4 envelope |
| **093 Sweep pad 2** | 9.86 -> **10.48** | 5.98 -> 3.14 | -0.16 | named regression |
| **114 kick1** | 9.64 -> 9.17 | 1.33 -> 0.93 | -0.90 | |
| **119 SynDrum** | 14.20 -> 14.23 | 2.96 -> **5.26** | +0.23 | named regression, below |
| **127 LaserGun** | 10.81 -> 10.57 | 2.12 -> **2.42** | +0.02 | minor regression |
| 123 SpaceShip | 6.00 -> 5.98 | 5.66 -> 5.66 | +0.09 | |

**Bank verdict.** Across all 123 comparable patches, envelope mean improves from
2.67 to 2.50 dB, spectral mean from 6.77 to 6.76 dB with the median unchanged at
6.23, null depth from -3.9574 to -3.9634 dB, correlation from 0.6077 to 0.6083,
and level bias from +0.207 to +0.193 dB. Mean *absolute* level error worsens by
0.016 dB, from 1.9095 to 1.9255; that is 126 and 114 alone, moving their echoes,
and it is named here rather than left out. Envelope: four improved, two
regressed, 117 unchanged. Spectral: three improved, one regressed.

**Named regressions.** 119 is the largest, at +2.30 dB of envelope error, and it
is not this change's fault. With the delay off, 119 measures 1.18 dB and both
builds agree. With the delay moved to `(32)`, a *non*-triplet, both builds agree
again at 4.34 dB -- worse than the 2.96 dB the old, doubled `(32) /3` happened
to score. The old placement was accidentally flattering. Putting the echo where
the reference puts it exposes a second, pre-existing defect in what the delay
does once it is there. 093 (+0.62 dB spectral) and 127 (+0.30 dB envelope) are
the other two.

**Still open.** 119's stereo width, which the reference renders at 0.277 and
this engine at 0.018. Attributed to the delay rather than to unison or chorus:
with the delay off both are 0.000, with the chorus off they are 0.052 and 0.018,
and as-is they are 0.277 and 0.018. Moving 119 to the non-triplet `(32)` leaves
the reference at 0.282 and this engine at 0.018, so the gap is in what the delay
does to the stereo image rather than in where the echo lands, and this change
neither causes nor fixes it. Separate investigation. 069 Oboe's +10.99 dB level
error, at z = 4.57 the bank's clearest level outlier, is likewise untouched
here.

## 069 Oboe, and three phase errors in the oscillator

**The outlier.** Over the 123 comparable patches at the previous commit, 069.sy1
"Oboe" led absolute level error at **10.99 dB, z = 4.5** — 3.8 interquartile
ranges above the third quartile, against a 1.5×IQR fence of 5.96 — and sat
second on envelope error at **8.53 dB, z = 3.6**. It was the only patch in the
bank extreme on two independent metrics. Nothing else qualified: the spectral
leaders (088, 086, 001 at 16.7, 16.7, 16.3 dB) are the top of a smooth tail and
sit inside their own 1.5×IQR fence; the width leaders 119/089/111 are a trio
rather than one separated patch; and the `f0` leaders are octave ambiguity in
the pitch estimator, since `pitch_cents` on the same rows reads under a cent.

069 is a **triangle and a saw in unison**, mixed 48 : 52, through a 12 dB low
pass at cutoff 45 with a negative envelope amount. Its render was **11 dB louder
and 0.38 octaves darker at once**, which no gain error and no cutoff error can
be together.

### The gap is between the oscillators, not in either one

`patchdiag` blamed the filter, which is a red herring: the filter *amplifies*
what arrives. Stripping 069 one record at a time, and then muting one oscillator
at a time, says where the error is:

| variant | spectral | envelope | level | null | correlation |
|---|--:|--:|--:|--:|--:|
| as-is | 11.45 | 8.53 | +10.99 | −0.29 | 0.288 |
| filter bypassed, EQ neutral, chorus off, LFO 1 off ("c3") | 3.84 | 1.71 | +3.52 | −3.64 | 0.753 |
| **c3, oscillator 1 only** | **0.39** | 0.85 | −0.15 | **−39.91** | 0.999992 |
| **c3, oscillator 2 only** | **0.14** | 0.57 | −0.14 | **−28.04** | 0.999428 |

Each oscillator alone nulls at −40 and −28 dB. Mixed, they null at −3.6 dB and
come out 3.5 dB loud. Both waveforms are right and their *relationship* is
wrong, which can only be phase. The harmonic breakdown of c3 leaves no room at
all:

```
 k   refMag    ourMag   dB(o/r)      carried by
 1  3.611e-2  9.555e-2   +8.45   triangle + saw
 2  3.944e-2  3.879e-2   -0.14   saw only
 3  3.171e-2  1.723e-2   -5.30   triangle + saw
 4  1.970e-2  1.938e-2   -0.14   saw only
 5  1.749e-2  1.208e-2   -3.21   triangle + saw
 6  1.311e-2  1.291e-2   -0.14   saw only
```

Every harmonic the saw carries alone matches to 0.14 dB. Every harmonic both
oscillators reach is wrong. The error lives exactly and only where they overlap.

### Three phase errors, each measured directly

**D1 — the triangle started at its trough.** Projecting the fundamental out of
single-oscillator renders at note 60 gives the reference's start phase as
−0.2507 turns for sine, saw *and* triangle alike, against −0.4954 for our
triangle: a difference of exactly **−0.2500** once the +0.0053 of render
alignment common to every shape is removed. Folding 100 cycles of the two
renders shows it without any transform:

```
reference triangle          our triangle (before)
0.000   0.0055              0.000  -0.2179   <- ref crosses zero rising at 0
0.250   0.2230              0.250   0.0105      ours is at its trough
0.500  -0.0056              0.500   0.2179
0.750  -0.2230              0.750  -0.0105
```

**D3 — the pulse used the wrong duty.** Same method, at stored width 29:

```
reference pulse, pw=29                our pulse (before), pw=29
0.000  -0.1680  (edge)                0.000   0.0577  (edge)
0.031   0.0271  \  high +0.0271       0.031   0.2065  \  high +0.2076
  ...            >  for 88.6%           ...            >  for 11.4%
0.875   0.0276  /                     0.125   0.0437  /
0.906  -0.1711  (edge)                0.156  -0.0276  \  low  -0.0268
0.938  -0.2113  low -0.2113             ...            >  for 88.6%
0.969  -0.2113     for 11.4%          0.969  -0.0268  /
```

The reference's pulse is high for **`1 - pw`** of the cycle; ours was high for
`pw`. `|sin(pi*k*d)|` is symmetric in `d <-> 1-d`, so the two duties have
**identical magnitude spectra** — on a single pulse the spectral metric read
0.18 dB while the null read −0.08 dB. Predicting the phase of the first two
harmonics from the `1 - pw` model reproduces the reference to four decimals
(−0.4431 against −0.4432 at k=1; −0.3863 against −0.3863 at k=2).

The vendor manual points the other way and is describing the knob rather than
the polarity: *"p/w — Set the pulse width of the pulse wave. Turn left to narrow
the width, turn right to widen it"* (`docs/synth1-readme-eng.txt:128`). At stored
29, left of centre, what is narrow in the reference is the **negative**
excursion. The changelog *does* pin the saw, which is why the saw was already
right; the triangle and the pulse got no such sentence, and both were wrong.

**D2 — the free-running offset had the right magnitude and the wrong sign.**
Method: render a descending saw with an instant amplitude attack, filter open
and no effects; place the falling edge of each of the first 24 cycles to
sub-sample precision by interpolating across the jump; fit a line through
(cycle, time) and extrapolate the intercept back to note-on. Do it with each
oscillator alone; the difference is the offset. No spectra and no cancellation
depth are involved.

| rate | note 36 | note 48 | note 60 | note 72 | note 84 |
|--:|--:|--:|--:|--:|--:|
| 48 kHz | 0.5624 | 0.5621 | 0.5624 | 0.5629 | *0.5575* |
| 96 kHz | 0.5622 | 0.5621 | 0.5619 | 0.5623 | 0.5624 |

Nine readings give **0.56230, standard deviation 0.00030**, over four octaves
and two sample rates. The method's own accuracy is established by the same
measurement: run against this engine it reads the constant back to within
0.0008. The 48 kHz note-84 cell is discarded on a stated ground rather than
because it is inconvenient — a cycle there is 20 samples, and sub-sample edge
interpolation cannot resolve a thousandth of a turn across a band-limited edge
that short; the same note at 96 kHz, where the cycle is 40 samples, is in line
with the rest. The value does not move with note or rate, so it is a fixed
**phase**: a fixed sample offset would have halved between the two rates.

A frequency-domain cross-check agrees at notes 48/60/72 over saw, pulse and
triangle pairs: 0.5623 every time. 32 kHz gave no reading at all — the reference
renders silence through this harness at that rate, which is recorded as a limit
of the measurement and not as a result.

**Written at the precision the reading carries — and that precision has since
been sharpened by a factor of 25.** This paragraph used to record 9/16 = 0.5625
as a hypothesis sitting "inside the interval", indistinguishable from the
reading. It is not. An absolute reading of each oscillator against note-on gives
**0.562334 ± 0.000012**, which puts 9/16 **fourteen standard deviations away**
and rules it out; the constant is now written `0.56233`. 0.5600, the exact sign
flip of the old 0.440, is out by two hundred. See [The oscillator start phase,
read absolutely](#the-oscillator-start-phase-read-absolutely) at the end of this
document for the method and the readings.

**A discarded step, recorded so nobody repeats it.** The constant was first
swept over 0.5500/0.5600/0.5623/0.5625/0.5700 against the null depth of one
probe patch at one note. That is fitting a constant to a metric, and it was also
incapable of settling the question: the readings were −18.41, −25.75, −24.47,
−26.81, −20.90 dB, non-monotone around the true value, and would have preferred
0.5625 on noise. It is not evidence and none of the above rests on it.

### The single-oscillator nulls

| single oscillator, filter open, no effects | before | after |
|---|--:|--:|
| sine | −44.34 | −44.34 |
| saw | −28.65 | −28.65 |
| **triangle** | **−39.91** | **−44.14** |
| **pulse** | **−0.08** | **−27.17** |
| **two oscillators mixed (069's c3)** | **−3.64** | **−24.47** |

### This is a systematic correction, not an outlier fix

069 is the outlier, but what produces it is shared: the change moves **108 of
123 patches** by more than 0.005 dB on level, envelope or null depth. It alters
the phase relationship of every two-oscillator patch and the waveform of every
triangle and every pulse, so it is gated on the whole-bank aggregate.

| metric | before | after | change |
|---|--:|--:|---|
| spectral mean (119 valid) | 6.7597 | **6.6538** | −0.106 |
| spectral median (119 valid) | 6.2274 | **5.9766** | −0.251 |
| envelope mean | 2.5025 | **2.0956** | **−0.407 (−16%)** |
| envelope median | 2.0627 | **1.7701** | −0.293 |
| level error, mean absolute | 1.9255 | **1.6529** | −0.273 |
| level bias, signed mean | +0.1928 | +0.1749 | −0.018 |
| level, signed median | +0.1702 | **+0.0464** | closer to zero |
| **null depth mean** | −3.9634 | **−6.6565** | **2.69 dB deeper (+68%)** |
| **null depth median** | −2.5547 | **−6.0802** | **3.53 dB deeper** |
| correlation mean | 0.6083 | **0.7607** | +0.152 |
| stereo width delta mean | −0.0237 | −0.0246 | −0.0009 |

Counts: spectral **45 better / 49 worse**, envelope **82 / 24**, null depth
**84 deeper / 15 shallower** (at 0.05 dB). Spectral improves on both mean and
median while more patches move up than down, because the improvements are large
(−5.48, −3.11, −3.07, −1.79, −1.57) and the largest regression is +1.28.

**What it buys.** 117 Perc1 — which this document already names the bank's
historically worst patch — goes 9.55 → **4.06** spectral, 6.21 → **2.05**
envelope and −6.06 → **−0.01** dB level, all three from D3 alone. 029 E Guitar
3, the previous top envelope outlier at 9.08 dB, goes to **1.24** from D2 alone.
069 itself goes 11.45 → 8.35, 8.53 → 4.78, +10.99 → **+6.18**, with its null
2.69 dB deeper. 078 Whistle 2 nulls 10.20 dB deeper, 004 Honky Piano 10.66 dB
deeper, 039 Synth Bass 1 11.78 dB deeper.

**Named regressions.** Three are material and are the reason to read this
section before touching these lines again:

- **033 Acoustic Bass, envelope 1.41 → 5.99 dB.** The largest single regression
  and the only one that creates a new top-five envelope entry (z 2.57 after).
  Attributed entirely to D2 — D1 and D3 leave it at 1.41. It was recorded here
  as "not diagnosed" and as the one result that would justify holding the
  change. **It is now diagnosed, and it is not the phase.** 033 is one of the 21
  factory patches that run the oscillator modulation envelope on oscillator 2's
  pitch (parameter 10 = 1, destination 0), so its two oscillators are compared
  through a pitch ramp rather than at a constant offset, and the early
  cancellation pattern is extremely sensitive to where that ramp goes. Switch
  the envelope off and the regression disappears: **envelope 5.99 → 0.67, null
  −0.99 → −11.69**. Reduce 033 to oscillator 2 alone, where a start phase is a
  pure time shift and the null test searches lag anyway, and it still nulls at
  only **−0.30 dB**, with the two candidate phases 0.03 dB apart. A bare
  oscillator carrying nothing but 033's modulation-envelope records nulls at
  **−11.79 dB** against **−22.47 dB** with them off. D2 is right; the next defect
  in that chain is the modulation envelope, and it is the phase question's
  neighbour rather than its consequence.
- **047 Harp**, the only patch worse on three metrics at once: envelope +0.76,
  level +1.21, null 3.40 dB shallower, against spectral −1.48.
- **085 Sync lead 2, level 2.46 → 4.36 dB**, against an envelope improvement of
  −0.93 and a null 3.34 dB deeper.

Above 0.1 dB the rest are: spectral — 031 +1.28, 108 +1.27, 016 +1.11, 118
+0.74, 083 +0.73, 046 +0.62, 121 +0.50, 033 +0.43, 084 +0.37, 066 +0.25, 063
+0.24, 079 +0.24, 103 +0.23, 060 +0.23, 088 +0.21, 081 +0.20, 126 +0.20, 019
+0.19, 094 +0.16, 054 +0.16, 044 +0.15, 068 +0.14, 018 +0.13, 051 +0.12, 096
+0.12; envelope — 084 +1.53, 088 +0.62, 124 +0.43, 062 +0.31, 003 +0.29, 083
+0.27, 092 +0.26, 052 +0.25, 127 +0.16, 063 +0.16, 114 +0.15, 090 +0.12, 082
+0.12, 050 +0.11; level — 094 +0.51, 060 +0.41, 056 +0.35, 124 +0.35, 074
+0.33, 018 +0.27, 050 +0.22, 063 +0.18, 077 +0.16, 112 +0.16, 116 +0.14, 108
+0.13, 067 +0.12, 072 +0.11; null — 062 +1.63, 032 +0.80, 089 +0.51, 117 +0.45,
033 +0.42, 027 +0.41, 002 +0.40, 075 +0.22, 053 +0.20, 028 +0.18, 048 +0.14,
052 +0.13, 006 +0.12. Everything not listed is under 0.1 dB. The full
enumeration is one command away:

```
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv build/bank.csv
```

### The three parts do not stand alone

| patch | metric | before | D1 only | D2 only | D3 only | D1+D2 | **all three** |
|---|---|--:|--:|--:|--:|--:|--:|
| 069 Oboe | level | 10.99 | 5.54 | *13.77* | 10.99 | 6.18 | **6.18** |
| 069 Oboe | envelope | 8.53 | 5.43 | *9.89* | 8.53 | 4.78 | **4.78** |
| 029 E Guitar 3 | envelope | 9.08 | 9.08 | **1.24** | 9.08 | 1.24 | **1.24** |
| 117 Perc1 | level | 6.06 | 6.06 | 6.06 | **0.01** | 6.06 | **0.01** |
| 002 Piano | envelope | 4.09 | *7.77* | *4.92* | *7.41* | *5.91* | **2.10** |
| 004 Honky Piano | envelope | 5.12 | 5.15 | 5.20 | *5.49* | 3.96 | **0.95** |

**002 Piano is the decisive row.** Every partial correction makes it worse — the
triangle alone raises it to 7.77 and would have created a new bank outlier — and
only the complete correction improves it. D2 applied alone regresses 069, the
patch that started this. Three phase errors compose: removing one at a time
moves the relationship to a different wrong place. The parts are separable for
attribution and not for shipping.

### The trap, in the form it took here

**No existing test could see any of the three**, and one of them is a good test
that *cannot* catch this by construction.
`test_pulse_at_half_width_is_a_square` checks the one width where D3 is
invisible: a square is its own duty complement.
`test_oscillator_phase_offset_is_between_the_oscillators` asserts that half a
turn between two same-pitch pulses cancels the fundamental — correct, external,
and blind to D2, **because cancellation depth is an even function of phase**.
Any test built on "how far did this harmonic drop" is sign-blind, which is
exactly how a sign survived being measured.

The three pins added to `tests/dsp` are therefore signed and anchored on the
reference's own numbers: the triangle and the pulse against the folded cycles
printed above, and the offset as a *signed* phase difference between the two
oscillators' own fundamentals. Reverting each of the three source lines fails
exactly one of them.

### Still open

- **The oscillator modulation envelope on oscillator 2's pitch**, which is what
  033's +4.58 dB envelope regression turned out to be (see above). 21 factory
  patches run it — 016, 027, 028, 029, 030, 031, 032, 033, 035, 046, 047, 048,
  053, 055, 062, 107, 108, 114, 119, 126, 127, all with destination 0 — and three
  of D2's four largest envelope regressions are among them, as is 047 Harp. The
  group means do not separate (mean Δenvelope −0.055 against −0.003 for the other
  102), so it is the demonstrated explanation for 033 and an enriched suspect for
  the rest, not a universal one.
- **Unison, on the shared banks.** Not visible in the factory bank's aggregates,
  but a probe of four unison voices with the sub off and no detune reads
  spectral 0.74, envelope 1.61, level −2.71 and a null of only −1.74 dB, against
  0.14 / 0.05 / −0.14 / −28.55 for the same patch with unison off; adding the
  detune takes the null to −0.01 dB. It is now the leading defect on the
  corpus patches that use the sub, which is how it was found.
- **069's remaining +6.18 dB**, which is not the oscillator. With the filter
  opened it falls to +0.92, and with a *static* cutoff at 45 to +0.75, so the
  residual is the filter **envelope** at a negative amount over a low cutoff —
  not the cutoff table and not the resonance. 069 belongs to a woodwind level
  cluster that is now the bank's leading group: 083 (9.86), 071 (8.56), 032
  (7.04), 073 (6.27), 069 (6.18), 070 (5.73), 077 (4.45). They share a filter
  configuration, not an oscillator one.
- **119 SynDrum's stereo width**, and 089/111 with it. Untouched by this change.
- **The bank-wide width deficit** (signed mean −0.0246), the known chorus and
  delay energy shortfall.

### A correction to this document's own record

The spectral figures quoted in different sections here are not inconsistent, and
one earlier report was wrong to flag them: 6.7597 over all 123 rows and 6.5399
over the 119 with `spectral_valid=true` are the same number under two
denominators (6.7597 × 119 / 123 = 6.5399). Where a spectral mean appears, it is
the 119 valid rows unless it says otherwise.

## The oscillator start phase, read absolutely

The section above left one thing open that its own method could not close: the
offset's **assignment**. `0.5623 + 0.4377 = 1.0000` exactly, and for a same-shape
same-pitch pair "oscillator 2 at +φ" and "oscillator 1 at +(1−φ)" are time-mirror
images with identical magnitude spectra. The edge fit that produced 0.5623 took
the *difference* of two renders, so it fixed the magnitude and left the
assignment to its own polarity convention. The bank appeared to disagree with
itself about which way round it went — 033 Acoustic Bass, the only same-shape
pair among the discriminating patches, preferred the mirror while 029 and 069
preferred the shipped sign — which is the signature a **per-shape** start phase
would leave.

It is not a per-shape law. It is one constant, on oscillator 2, with the sign the
code already had.

### Why this reading is allowed to settle it

Sweeping a constant against a metric is forbidden here and none of what follows
does it. Three constructions, no knobs:

- **Absolute harmonic phase against note-on.** `s1probe compare` sends the note
  on before the first block and drives both engines in the same block size, so
  **frame 0 is the note-on sample in both renders**. Projecting onto
  `cos/sin(2πk f₀ t)` with `t` counted from frame 0 gives an absolute phase, not
  a difference.
- **Phase separated from latency by pitch.** At one pitch a start phase and an
  output latency are the same thing. They separate over pitch: a start phase is
  constant in turns, a latency contributes `τ·f₀` turns. Five notes over four
  octaves, fitted in `f₀`, give both.
- **Differences taken inside one engine at one note**, where the plugin's
  latency, the filter's group delay and the shape's own Fourier convention are
  common to the two renders and cancel exactly. This is what carries the 1×10⁻⁵
  precision.

### The readings

Apparent start phase in turns, time origin = note-on; `phi0` is the fit's
intercept and `tau` its slope in samples at 48 kHz. Each shape's Fourier
convention is taken from this engine's oscillator 1, whose start phase is pinned
at zero, so a mistake in the triangle's or the pulse's convention cannot become a
mistake in the answer.

```
stem      shape  side      n36      n48      n60      n72      n84     phi0  tau(samp)
o1sine    sine   ref   -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36
o1saw     saw    ref   -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36
o1pulse   pulse  ref   -0.0004  -0.0007  -0.0017  -0.0037  -0.0077   0.0002    -0.36
o1tri     tri    ref   -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36
o2saw     saw    ref   -0.4378  -0.4382  -0.4392  -0.4412  -0.4451  -0.4373    -0.36
o2pulse   pulse  ref   -0.4380  -0.4384  -0.4394  -0.4414  -0.4453  -0.4374    -0.36
o2tri     tri    ref   -0.4378  -0.4382  -0.4392  -0.4412  -0.4451  -0.4372    -0.36
```

**Oscillator 1 starts at zero for every shape. Oscillator 2 starts at −0.4373 =
+0.5627 for every shape.** The drift across each row is the latency term, and it
is the same for both oscillators and all four shapes. At 96 kHz the intercepts
are +0.0001…+0.0002 and −0.4375…−0.4377.

That alone excludes both alternatives with the same magnitude:

- **the mirror** (oscillator 2 at +0.4377): oscillator 2 reads 0.5623, which is
  0.125 turns away — a hundred times the method's absolute accuracy;
- **the global shift** (oscillator 1 at +0.4377, oscillator 2 at zero), which
  preserves the difference: oscillator 1 reads 0.000, not 0.4377.

**The value itself**, as `osc2(alone) − osc1(alone)` inside one engine at one
note. Pooling 90 readings — 5 notes × 3 shapes × harmonics 1–7:

- reference **0.5623366, standard deviation 0.0000116** (min 0.562292, max
  0.562398);
- this engine reads 0.5623022 against its own known `f32(0.5623) = 0.56229996`,
  so the **method's bias is +2.3×10⁻⁶**;
- reference with the bias removed: **0.562334 ± 0.000012**;
- `9/16 = 0.5625` is **14 sd away and excluded**. `10^(−1/4) = 0.5623413` is 0.6
  sd away, which is a coincidence and must not be written into the code as a
  value.

At 96 kHz every cell reads −0.43766/−0.43767, unchanged. A fixed sample offset
would have halved.

**It is a phase of oscillator 2's own cycle, not a time.** Transposed ±12
semitones and read against its own fundamental the reference gives 0.5616/0.5596
and 0.5630/0.5626; a fixed time of `0.5623/f₀` seconds would read 0.1246 at +12.

**Superposition, and the mirror rejected on the reference's own audio.** For one
note, three renders of the same engine — oscillator 1 alone, oscillator 2 alone,
and the pair at a known mix — solved for complex `α, β` in
`H_pair,k = α·H_osc1,k + β·H_osc2,k` over harmonics 1..7. No waveform model
appears in it anywhere.

```
note 60      side   mix     |alpha| arg(a)turn  |beta| arg(b)turn  residual  conjugate
prsaw25      ref   75:25    0.7482    0.0000   0.2520   -0.0000   -97.25 dB   -3.91 dB
prsaw75      ref   25:75    0.2442   -0.0000   0.7561    0.0000   -97.24 dB    5.51 dB
prtri25      ref   75:25    0.7480    0.0000   0.2520    0.0000  -170.75 dB   -1.11 dB
prpul25      ref   75:25    0.7480   -0.0000   0.2520    0.0000  -181.41 dB   -5.92 dB
prsinesaw    ref   50:50    0.4961   -0.0000   0.5040    0.0000  -102.40 dB    6.00 dB
prtrisaw     ref   50:50    0.4961   -0.0000   0.5040    0.0000  -100.35 dB    7.02 dB
```

`arg α = arg β = 0.0000`: each oscillator sits in the pair exactly where it sits
alone. The residual says the reference's two-oscillator render **is** the sum of
its two single-oscillator renders. The last column is the mirrored assignment
fitted to the *same* render, and it does not fit at all — ninety to a hundred and
eighty decibels between the two hypotheses, on the same-shape pair and on both
mixed-shape pairs, including 029's `sine + saw` and 069's `triangle + saw`.

**The pulse, at eight widths — the per-shape hypothesis's last hiding place**,
since the pulse's fundamental phase moves with its duty. `phase(pulse) −
phase(saw)` at `k=1`, inside one engine, note 48:

| stored 8 | duty | reference | ours | ref − ours | `0.25 − (1−d)/2` |
|--:|--:|--:|--:|--:|--:|
| 8 | 3.1 % | −0.23437 | −0.23425 | −0.00011 | −0.2345 |
| 20 | 7.9 % | −0.21069 | −0.21063 | −0.00005 | −0.2105 |
| 29 | 11.4 % | −0.19311 | −0.19291 | −0.00019 | −0.1930 |
| 45 | 17.7 % | −0.16161 | −0.16142 | −0.00020 | −0.1615 |
| 64 | 25.2 % | −0.12402 | −0.12402 | 0.00000 | −0.1240 |
| 90 | 35.4 % | −0.07299 | −0.07283 | −0.00016 | −0.0730 |
| 110 | 43.3 % | −0.03368 | −0.03346 | −0.00022 | −0.0335 |
| 124 | 48.8 % | −0.00610 | −0.00590 | −0.00019 | −0.0060 |

The last column is the shipped two-saws-differenced model, and it reproduces the
reference across the whole range. Harmonic by harmonic the residual is
`−0.0017 × k` turns at every width, which is a pure delay of 0.62 samples — the
same latency term seen everywhere else. **The triangle and the pulse as shipped
are right, absolutely and per shape, and there is no residual for a fourth
constant to absorb.**

### The bank's apparent contradiction was never about phase

033 and 029 are the two of the five discriminating patches that run the
oscillator modulation envelope on oscillator 2's pitch. Switch it off and both
agree with the reading, and both null 6 to 10 dB deeper:

| patch, one record changed | shipped `osc2 = +0.5623` | mirror `osc2 = +0.4377` |
|---|--:|--:|
| **033 as shipped** | envelope 5.99, null −0.99 | envelope **1.39**, null −1.42 |
| **033 with `10=0`** | envelope **0.67**, null **−11.69** | envelope 1.08, null −5.04 |
| **029 as shipped** | envelope **1.24**, null −5.91 | envelope 9.13, null −4.00 |
| **029 with `10=0`** | envelope **0.81**, null **−11.74** | envelope 1.27, null −2.13 |
| 033 reduced to oscillator 2 alone | envelope 1.50, null **−0.30** | 2.13, −0.33 |

And two of the five could never have settled anything: **117 Perc1's oscillator 2
is noise**, which has no phase, so the two candidate engines render it
bit-identically (`md5 63c6525340686298ce6e2873e36c14b2` for both); **078 Whistle
2 is a single-oscillator patch** (mix "0 : 100"), where the constant is a pure
time shift of the whole voice and the null test searches lag anyway. The one
clean mixed-shape case that does not use the modulation envelope, **069 Oboe,
agrees with the reading** (envelope 4.78 against the mirror's 5.51, null −2.98
against −2.23).

Also worth recording: the objective this work started from quoted "1.41 at the
old 0.440" and "1.39 at the mirror 0.4377" as two readings. They are one reading
twice — `build/diag033/V0-033.csv` gives envelope 1.4073 and `VFLIP-033.csv`
1.3909, and 0.440 and 0.4377 differ by 0.0023 turns.

### What the mirror would have cost

Reported as a consequence, not as the selection criterion:

| metric | shipped | mirror | change |
|---|--:|--:|---|
| spectral mean | 6.6538 | 6.7487 | +0.095 |
| envelope mean / median | 2.0956 / 1.7701 | 2.3792 / 1.9018 | +0.284 / +0.132 |
| level, mean absolute | 1.6529 | 1.7566 | +0.104 |
| null depth mean / median | −6.6565 / −6.0802 | −5.4430 / −4.2873 | **1.21 / 1.79 dB shallower** |
| correlation mean | 0.7607 | 0.7089 | −0.052 |

Its only material gain is 033's envelope, −4.60, which the section above
attributes to the modulation envelope.

### What changed in the code

`OSC_PHASE_FREE_TURNS` **0.5623 → 0.56233**, the reading to the precision it
carries. The bank cannot see the difference and that is the point — the reading
must, and does. Before and after over the isolated 123-patch bank:

| metric | 0.5623 | 0.56233 |
|---|--:|--:|
| spectral mean / median (119 valid) | 6.6538 / 5.9766 | 6.6537 / 5.9766 |
| envelope mean / median | 2.0956 / 1.7701 | 2.0957 / 1.7701 |
| level, mean absolute / signed median | 1.6529 / +0.0464 | 1.6529 / +0.0464 |
| null depth mean / median | −6.6565 / −6.0802 | −6.6564 / −6.0802 |
| correlation mean | 0.7607 | 0.7607 |

Largest per-patch movement on any metric **0.004 dB** (127 envelope +0.004, 039
null +0.003, 029 envelope −0.002, 033 envelope +0.002). No regression above
0.004 dB. The two patches the argument was about, reported explicitly: **033
envelope 5.9873 → 5.9888, null −0.9856 → −0.9854; 029 envelope 1.2397 → 1.2377,
null −5.9131 → −5.9134.** 0 reference-silent, 0 ours-silent, 123 rows, the same
five patches killing the reference as always.

### The caveat that still stands

All of this is the fresh-voice case: one plugin instance, one note-on, no note
history, which is the condition the null test renders under. A host that has had
the plugin running for minutes could find genuinely free-running oscillators
somewhere else. The reference's fitted latency (−0.36 samples against ours at
+0.77) is common to both oscillators and all four shapes, so it cancels out of
every claim here, but it is not explained. 32 kHz was not attempted; the
reference renders silence through this harness at that rate.

## The sub oscillator, and what the factory bank cannot see

This document has recorded since [A 10 dB defect the bank cannot
see](#a-10-db-defect-the-bank-cannot-see) that the sub oscillator measures
**10.03 dB on its own** and that **no factory patch uses it** — parameter 95 is
zero in all 128. So it could be described and not gated. The shared banks close
that gap: of **16698 patches** in them, **4284 set parameter 95**, 2450 of those
in the "−1oct" state.

### Three laws, all of them wrong here, all of them measured

**Parameter 97 is `0oct` / `−1oct`, not one octave down / two.** The vendor's own
v1.12 parameter list says so — *"97 - osc1 sub octave: 0 - 0oct, the same pitch
as the Oscillator 1; 1 - -1oct, one octave under"* — and the reference is
unambiguous. At stored 0, with a sine carrier and a full-gain sine sub,
**switching the sub in and out changes the reference's render by −142.5 dB**,
which is float rounding: at oscillator 1's own pitch and phase a normalised mix
of two identical signals returns the carrier exactly. The same null appears for a
saw carrier with a saw sub, a triangle with a triangle, at two gains, and with
four unison voices. At stored 1 the sub's fundamental appears at f₀/2 and there is
nothing at f₀/4. Stored 2..127 render identically to stored 1.

The old mapping put the sub an octave below the truth in *both* states. That is
why the sub previously looked as though the reference "produced nothing at f₀/2":
it was being asked for the wrong state and read in the wrong bin.

**The level law is `a = 4 × stored95 / 127`, and the mix is a normalised one:**

```
out = ((1-m) * (osc1 + a*sub) + m*osc2) / (1 + a*(1-m))
```

Read three ways, each isolating one part. `a`, at mix "100 : 0" and "−1oct" where
the sub sits at f₀/2 and the carrier at f₀ so they are separate bins, note 48:

| stored 95 | 8 | 16 | 32 | 48 | 64 | 80 | 96 | 127 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| \|sub\|/\|carrier\| | 0.25197 | 0.50394 | 1.00789 | 1.51184 | 2.01579 | 2.51974 | 3.02369 | 4.00010 |
| `127a/(4·stored)` | 1.00000 | 1.00001 | 1.00001 | 1.00002 | 1.00002 | 1.00002 | 1.00002 | 1.00003 |

— `4·stored/127` to 3×10⁻⁵ across the knob, and the same render gives `1 + a` a
second way, as the carrier with the sub off over the carrier with it on, agreeing
to five decimals. The **division** by `1 + a` rather than merely holding the
carrier is what the −142.5 dB null says. `s1probe mixprobe` re-reads the `(1−m)`
at five mix settings, with two saws four semitones apart so no partial of the sub
lands on oscillator 2:

| stored mix | 32 | 64 | 96 | 112 | 127 |
|---|--:|--:|--:|--:|--:|
| oscillator 2's partial, sub on / sub off | 0.27838 | 0.36768 | 0.54173 | 0.70962 | 1.00000 |
| `1/(1+a*(1-stored/127))` | 0.27843 | 0.36783 | 0.54181 | 0.70962 | 1.00000 |
| a denominator of `1 + a` alone | 0.22399 | 0.22399 | 0.22399 | 0.22399 | 0.22399 |

At mix "0 : 100" the sub **vanishes with oscillator 1**: the reference's render is
bit-identical with the sub at full gain. The parameter is called "osc1 sub gain"
and it means it. What was here before, `mix*(1 − 0.5*g) + sub*g`, had the right
shape and none of the three factors: at full gain it lifted the carrier by 3 dB
where the reference drops it by 14, undersold the sub by the same reasoning, and
kept the sub audible with oscillator 1 mixed out.

**And the sub's start phase is oscillator 1's.** The −142.5 dB null says so at
"0oct" to float precision, for three shapes and two gains. At "−1oct", where the
sub is at f₀/2 and cannot cancel anything, its own fundamental reads
**0.000 ± 0.002 turns** against oscillator 1's in the same render, for all four
sub shapes and at three notes. `voice.odin`'s `oscillator_set_phase(&u.sub, 0)`
was previously the one start phase in the file with nothing behind it; it is now
the best-measured of the three.

### What it bought, on probes and on the shared banks

Controlled probes, oscillator 1 alone with the sub at "−1oct", note 48 — nine
gains and four sub shapes, before → after:

```
                      spectral        envelope        null
  stored 95 = 8      6.59 -> 0.00    1.35 -> 0.04   -11.66 -> -37.87
  stored 95 = 32    10.55 -> 0.00    3.80 -> 0.05    -2.64 -> -38.14
  stored 95 = 64     9.83 -> 0.00    4.54 -> 0.06    -0.63 -> -39.46
  stored 95 = 110   10.78 -> 0.00    4.94 -> 0.04    -0.10 -> -40.51
  stored 95 = 127   10.40 -> 0.00    5.13 -> 0.04    -0.05 -> -40.74
  sub triangle      20.34 -> 0.20    5.34 -> 0.06    -0.19 -> -40.47
  sub saw           13.03 -> 0.17    5.65 -> 0.06    -2.98 -> -28.51
  sub square        20.07 -> 0.17    3.63 -> 0.04    -0.29 -> -29.46
  (the same patch with the sub off)  0.00 / 0.03 / -38.35
```

Every one of them now matches the sub-off control. The seven-mix set behaves the
same way: at stored mix 127 our render is now bit-identical with the sub at full
gain, as the reference's is.

**A gate of real patches, since the factory bank has none.** Every patch in the
shared banks with `95 >= 32`, no unison, no sync, no ring and no FM,
deduplicated by its records, sorted by bank then filename — 97 patches, 92 with a
valid spectral reading, 1 killing the reference, 0 silent on either side:

| metric | before | after | the same patches with the sub off in both engines |
|---|--:|--:|--:|
| spectral mean / median | 11.9468 / 11.3068 | **8.9055 / 7.8004** | 9.2404 / 8.0711 |
| envelope mean / median | 4.3204 / 3.4148 | **4.0444 / 2.9134** | 4.0198 / 3.1409 |
| level, mean absolute | 4.4652 | *4.8243* | 4.5485 |
| null depth mean / median | −0.7969 / −0.3153 | **−2.8722 / −0.8737** | −2.6892 / −0.8357 |
| correlation mean | 0.3120 | **0.4668** | 0.4584 |

Counts at 0.05 dB: spectral **62 better / 22 worse**, envelope **50 / 36**, null
**54 deeper / 11 shallower**, correlation **51 / 4**, level **38 / 51**.

The third column is what makes the first two readable. Before the change, having
the sub switched on cost **2.47 dB** of spectral error against the same patches
with it removed from both engines; after, it costs **−0.31 dB**. The sub has
stopped being a source of error.

**Named regressions.** Envelope: s089 +15.03, s063 +7.67, s069 +4.78, s087 +1.99,
s056 +1.84, s021 +1.66, s029 +1.62, s023 +1.61. Spectral: s023 +7.95, s088 +5.32,
s029 +4.50, s059 +4.40, s018 +4.24, s027 +3.59, s087 +2.84, s015 +2.69. Null:
s059 +0.54, s020 +0.52, s015 +0.50, s087 +0.40, s043 +0.39. The largest of them,
s089's envelope 2.82 → 17.85, reads **19.84** with the sub switched off in both
engines — the broken sub was masking a larger error underneath it, and that is
what the control column is for. **Level is the one aggregate that does not
improve** (4.4652 → 4.8243, against 4.5485 with the sub off). The audit below
reproduces that residual but does not establish its cause.

**A first gate that could not adjudicate, recorded so it is not repeated.** The
obvious selection — every corpus patch with `95 >= 32`, nothing else — gives 76
patches of which **67 use unison**, and unison is broken independently: four
voices with the sub off and no detune null at −1.74 dB and sit 2.71 dB low in
level, and with detune the null is −0.01 dB. That gate's own control says it
cannot see the sub at all: the same 76 patches with parameter 95 forced to zero
read spectral **12.9142**, *worse* than the 12.1819 they read with a broken sub
switched on. A gate whose patches do not improve when the feature under test is
removed cannot be evidence about that feature.

### The factory bank is untouched by all of this

As it must be, since no factory patch sets parameter 95: 123 rows, spectral
6.6537 / 5.9766, envelope 2.0957 / 1.7701, |level| 1.6529, null −6.6564 /
−6.0802, correlation 0.7607 — the same to four decimals as before, with the
largest per-patch movement 0.004 dB and that from the phase constant's last
digit rather than the sub.

### Parameter 91: the engaged phase is offset by one step

The old law, `0.5·v/127`, came from the three nulls printed by `phaseprobe`.
Those nulls establish useful magnitudes, but cancellation is an even function of
phase: it cannot establish a sign, an absolute origin, or whether the line is
offset by one stored step. The absolute reading is now a separate command:

```
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe phaseabsolute --values 0,1,16,32,48,64,96,127
```

It renders one descending saw at a time, never a two-oscillator cancellation,
and projects its fundamental with sample zero as note-on. The apparent phase is
read at notes 36, 48, 60, 72 and 84; fitting phase against frequency puts the
fixed output latency in the slope and the start phase in the intercept. A
descending saw's fundamental convention comes from the waveform itself, not
this engine. The reference's own free-running oscillator 1 then defines zero,
removing the common probe-path phase without using this engine as an oracle.

The command printed:

| stored 91 | reference osc1 start | reference osc2 start | osc2 − osc1 | `0.5·(v−1)/126` |
|--:|--:|--:|--:|--:|
| 0 | +0.00000 | −0.43766 | 0.56233 | free-running |
| 1 | **−0.00125** | −0.00125 | 0.00000 | 0.000000 |
| 16 | **−0.00125** | +0.05827 | **0.05952** | 0.059524 |
| 32 | **−0.00125** | +0.12177 | **0.12302** | 0.123016 |
| 48 | **−0.00125** | +0.18526 | **0.18651** | 0.186508 |
| 64 | **−0.00125** | +0.24875 | **0.25000** | 0.250000 |
| 96 | **−0.00125** | +0.37573 | **0.37698** | 0.376984 |
| 127 | **−0.00125** | +0.49875 | **0.50000** | 0.500000 |

The relationship residual was at most 0.8×10⁻⁶ turns, inside the 5×10⁻⁶
precision of the reading. Thus stored 16 → 0.05952, 32 → 0.12302, 48 →
0.18651, 64 → 0.25000, 96 → 0.37698, 127 → 0.50000. The two candidate laws
agree at the engaged endpoints, but the absolute reading excludes
`0.5·v/127` by up to 0.002 turns in the middle. Oscillator 1 reads the same
**−0.00125 turns for every engaged `v >= 1`**, note-independent; that excludes
pinning both main oscillators to the free-run zero. Stored zero remains
free-running, `OSC_PHASE_FREE_TURNS` remains 0.56233, and the sub's
**free-running** zero is unchanged. That qualifier matters: the evidence audit's
isolated −1-octave sub read found engaged-minus-free at **−0.0006256 turns**
across all four shapes, two gains, and three notes. It temporarily extended the
same absolute-phase isolation used by `phaseabsolute`, rendering the sub alone
in the free-running and engaged states; the temporary probe was then removed.
That excludes the previous engaged-zero claim, so the signed engine test pins
only the measured main oscillators and keeps a separate free-running-sub check.
The engaged main-oscillator origin is not a replacement for either free-run
constant.

Every `ver=105` factory patch omits parameter 91, so both changes are unreachable
from this bank. That prediction was checked rather than assumed at exact source
endpoints: parent `36d1cb7b3aaa10403b92e070b63f5cd73a7890f2` and phase-law commit
`f729e3140081d6869556e160ce392b9711318b6f`. Each executable was built from its
own `git archive` extraction, so neither comparison can silently reuse the other
engine:

```powershell
$before = Join-Path $env:TEMP "quesynth-phase91-36d1cb7"
$after  = Join-Path $env:TEMP "quesynth-phase91-f729e31"
New-Item -ItemType Directory -Force $before, $after | Out-Null
git archive 36d1cb7b3aaa10403b92e070b63f5cd73a7890f2 | tar -xf - -C $before
git archive f729e3140081d6869556e160ce392b9711318b6f | tar -xf - -C $after
odin build "$before/tools/s1probe" -out:build/s1probe-36d1cb7.exe
odin build "$after/tools/s1probe" -out:build/s1probe-f729e31.exe
./build/s1probe-36d1cb7.exe compare ext/synth1/Synth1/soundbank00 --csv build/phase91-before.csv
./build/s1probe-f729e31.exe compare ext/synth1/Synth1/soundbank00 --csv build/phase91-after.csv
./build/s1probe-f729e31.exe summarise build/phase91-before.csv
./build/s1probe-f729e31.exe summarise build/phase91-after.csv
cmp build/phase91-before.csv build/phase91-after.csv
```

| metric | before | after |
|---|--:|--:|
| spectral mean / median (119 valid) | 6.6510 / 5.9766 | 6.6510 / 5.9766 |
| envelope mean / median | 2.0969 / 1.7701 | 2.0969 / 1.7701 |
| level, mean absolute / signed median | 1.6528 / +0.0646 | 1.6528 / +0.0646 |
| null depth mean / median | −6.6582 / −6.0558 | −6.6582 / −6.0558 |
| correlation mean | 0.7607 | 0.7607 |

Both CSVs contain 123 rows, 0 reference-silent and 0 ours-silent; the same five
patches (095, 098, 100, 101 and 106) crashed inside the reference, and the same
four had no spectrum left at sustain. They are byte-identical, SHA-256
`49cc89afe5dc1468fff0ea1e212ccaef2a21a13ab3ddb036e37f403c190233f9`:
**0 of 123 patches moved, so there are no per-patch regressions to name.**

### FM reaches the sub oscillator

The v1.11 changelog says that FM influences the sub as well as OSC1. The
controlled reference command is:

```
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe fmsubprobe --values 0,16,24,32,43 --note 48
```

The first checked-in analyser did not reproduce the numbers recorded here. It
smoothed each oscillator over its own period, so the `−1oct` sub was smoothed
over twice as much time as OSC1, then wrapped the two accumulated phase deltas
separately. Both operations changed the ratio being measured. `fmsubprobe` now
forms each signal's analytic phase with one Hilbert transform, keeps the phase
deltas unwrapped, and fits their signed covariance with a free intercept. The
same binary and command now reproduce:

| stored FM | `−1oct` sub/OSC1 slope | windows | nearest candidate | `0oct` max | `0oct` RMS |
|---:|---:|---:|---|---:|---:|
| 0 | 0 (control) | 0 | control | 2.38e−7 | 3.3e−8 |
| 16 | +0.473336 | 26 | fractional | 2.38e−7 | 3.3e−8 |
| 24 | +0.470593 | 26 | fractional | 2.68e−7 | 3.3e−8 |
| 32 | +0.454299 | 26 | fractional | 2.38e−7 | 3.3e−8 |
| 43 | +0.500492 | 26 | fractional | 2.09e−7 | 3.3e−8 |

At `−1oct`, the candidates are 1 for equal absolute displacement, 0.5 for
equal fractional deviation, and 0 for no FM at the sub. All four non-zero rows
select the 0.5 law. The implemented advance is therefore:

```
sub_phase += sub_increment + osc2_value * fm_depth(fm_position) * sub_increment
```

The `0oct` rows are the same-pitch control: a full-gain sine sub and the
sub-off carrier differ only at float noise. The probe also measures the ring
control rather than just stating it: FM 43 and 77 against FM off have max and
RMS **0** at both `0oct` and `−1oct`.

The engine test is
`test_fm_reaches_sub_with_reference_measured_displacement`. Its expected table
contains the four reference slopes above; it no longer computes its expected
ratio from the engine's increments. It renders the carrier and the normalized
carrier-plus-sub paths, isolates the audible sub, applies the same analytic
phase fit, checks the independent `0oct` reading, and keeps ring-on output at
FM-off. `odin test tests/dsp` passes all 85 tests. Sub-off no-movement is also
covered by the matched shared-bank control and the factory endpoint gate below.

### FM + sub shared-bank gate

`compare --fmsub-gate <case>` implements this gate. It walks the bank root
recursively, sorts paths, keeps source records with **95 ≥ 32** and **45 > 0**,
excludes unison, sync, ring, enabled modulation-envelope-to-FM, and enabled
LFO-to-FM records, then deduplicates the complete 99-parameter record before
applying a case. Selection always uses the unchanged source record. The three
cases alter both the reference and this engine in the same way:

- `original`: no parameter change;
- `fm-off`: parameter 45 set to zero;
- `fm-sub-off`: parameters 45 and 95 set to zero.

The reproducible commands are:

```
./build/s1probe.exe compare <shared-bank-root> --fmsub-gate original \
  --no-floor --csv build/fmsub-shared-original.csv --note 48
./build/s1probe.exe compare <shared-bank-root> --fmsub-gate fm-off \
  --no-floor --csv build/fmsub-shared-fm-off.csv --note 48
./build/s1probe.exe compare <shared-bank-root> --fmsub-gate fm-sub-off \
  --no-floor --csv build/fmsub-shared-fm-sub-off.csv --note 48
./build/s1probe.exe summarise build/fmsub-shared-original.csv
./build/s1probe.exe summarise build/fmsub-shared-fm-off.csv
./build/s1probe.exe summarise build/fmsub-shared-fm-sub-off.csv
```

Run on the local shared-bank extraction used by the prior sub gate
(`build/rp3/sub` in the main worktree), selection found **71 unique records out
of 4284**, with 4211 excluded, 2 duplicates removed, and 0 unreadable. The same
eight arpeggiator records killed the reference in all three cases, leaving the
same **63 matched rows** each time. All three have 0 invalid spectra, 0 silent
renders on either side, 0 non-finite renders, and 0 parameter-load failures.

| case | spectral mean / median | envelope mean / median | `|level|` mean / median | null mean / median | correlation mean / median |
|---|---:|---:|---:|---:|---:|
| original | 10.7378 / 9.4623 | 4.7885 / 3.6700 | 4.6664 / 3.2248 | −1.5204 / −0.4016 | 0.3787 / 0.3608 |
| FM off | 9.2946 / 7.7017 | 4.6363 / 3.7129 | 5.0926 / 3.6865 | −2.9599 / −0.8598 | 0.4778 / 0.4899 |
| FM + sub off | 9.1117 / 7.2983 | 4.5458 / 3.7260 | 4.9746 / 3.6474 | −3.1398 / −0.5637 | 0.4668 / 0.4072 |

At a 0.05 threshold, original versus FM-off is better/worse on spectral
**15/35**, envelope **21/25**, absolute level **22/18**, null depth **6/29**,
and correlation **4/26**. Original versus FM+sub-off is **15/39**, **19/36**,
**24/31**, **11/32**, and **11/30** in the same order. These controls do not
choose the displacement law—the direct signed probe does that. They show that
the gate now measures the intended active feature set while keeping the known
broader FM and sub errors visible rather than assigning them to this law.

### Factory-bank no-movement gate

The Synth1 factory bank has **123 comparable rows** and parameter 95 is zero in
all of them, so this FM-to-sub path is unreachable there. Rebuild the two source
endpoints independently, run the factory compare command against each executable,
and byte-compare the CSVs:

```powershell
$before = Join-Path $env:TEMP "quesynth-fmsub-integration"
$after  = Join-Path $env:TEMP "quesynth-fmsub-head"
New-Item -ItemType Directory -Force $before, $after | Out-Null
git archive 8e6c3b4 | tar -xf - -C $before
git archive HEAD | tar -xf - -C $after
odin build "$before/tools/s1probe" -out:build/s1probe-fmsub-before.exe
odin build "$after/tools/s1probe" -out:build/s1probe-fmsub-after.exe
./build/s1probe-fmsub-before.exe compare ext/synth1/Synth1/soundbank00 --csv build/fmsub-factory-before.csv
./build/s1probe-fmsub-after.exe compare ext/synth1/Synth1/soundbank00 --csv build/fmsub-factory-after.csv
cmp build/fmsub-factory-before.csv build/fmsub-factory-after.csv
```

The independent archive builds produce byte-identical 123-row CSVs with SHA-256
`49cc89afe5dc1468fff0ea1e212ccaef2a21a13ab3ddb036e37f403c190233f9`.
Both read spectral **6.6510 / 5.9766**, envelope **2.0969 / 1.7701**,
`|level|` mean **1.6528**, null **−6.6582 / −6.0558**, and correlation mean
**0.7607**. Thus **0 of 123 factory patches moved**.

### Unison stack measurement and gate

The committed fixture and command reproduce the external readings directly:

```powershell
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe unisonprobe --fixture tools/s1probe/fixtures/unison-four.sy1 `
  --values 16,22,32,64,96,127 --note 84
```

The fixture is one sine oscillator, an open static filter, no sub, effects or
modulation, and four unison voices. The command opens a fresh reference instance
for every render. Its zero-detune RMS ratios for voice counts 1..8 are
**1.0000 / 1.7123 / 2.5910 / 3.4068 / 3.8003 / 3.8554 / 3.2229 /
3.6704**. Those agree with the committed phase constants' predicted coherent
sums within 0.16%, so the layers sum at unity; there is no `1/sqrt(N)` trim.

Parameter 75 was measured over 36 layout-checked rows at notes 84 and 108. Six
of them, including the factory default and endpoint, are:

| stored 75 | reference outer half-span | fitted half-span | after level / null |
|--:|--:|--:|--:|
| 16 | 2.244 cents | 2.243 | −0.216 / −32.24 dB |
| 22 | 3.239 cents | 3.241 | −0.201 / −32.07 dB |
| 32 | 5.129 cents | 5.128 | −0.213 / −32.45 dB |
| 64 | 13.614 cents | 13.615 | −0.209 / −32.27 dB |
| 96 | 27.662 cents | 27.661 | −0.185 / −32.52 dB |
| 127 | 49.999 cents | 49.987 | −0.226 / −27.29 dB |

The four layers read the signed `−0.5, −1/6, +1/6, +0.5` layout. The fit across
all 36 rows is `7.83036*(2^(stored/44.0306)-1)` cents of outer half-span,
implemented as twice that value before the symmetric layout. Its worst relative
error is 0.22% and its RMS relative error is 0.066%. These commands produce all
36 fit rows:

```powershell
./build/s1probe.exe unisonprobe --fixture tools/s1probe/fixtures/unison-four.sy1 `
  --values 6,8,12,16,20,22,26,32,40,48,56,64,72,80,88,96,104,112,120,127 --note 84
./build/s1probe.exe unisonprobe --fixture tools/s1probe/fixtures/unison-four.sy1 `
  --values 2,3,4,5,6,8,10,12,16,20,24,32,48,64,80,96 --note 108
```

The old quadratic read only 1.50 cents at the default stored value 22, against
the reference's 3.239; the linear law before it read 4.331. The fitted law takes
the default controlled null from **−0.30 dB to −32.07 dB**, so detune no longer
takes that null to about zero.

The same command checks the other unison controls. With oscillator phase fixed,
the four-voice RMS ratios at parameter 92 = 0/64/127 are **4.0000 / 2.0079 /
3.4068**. It prints each directional layer phase at 64 and 127; the cumulative
projection resolves about 0.0004 turns and revalidates the committed constants,
while the detuned projection independently ties the first four phases to their
pitch slots. Parameter 85 at stored 12 and 36 reads the pitch groups **−12/0**
and **0/+12 semitones**. The fixture at zero detune reads **−0.3293 dB** level
and **−32.6465 dB** null; with parameter 73 off it reads **−0.1406 dB** and
**−38.1387 dB**. These are probe outputs, not values copied from the engine.

### Parameter 76: measured OSC1 component field

The original detuned reproduction changes parameter **76** from 0 to 20 while
75 remains 22. Parameter 76 is not another outer unison spread. It creates
OSC1's centre plus four signed pairs even when parameter 73 is off:

```text
d76 = 20 * stored76 / 127 cents
inner = {-7, -5, -3, -1, 0, +1, +3, +5, +7} * d76
```

At stored 20 the reference reads **−22.049, −15.761, −9.448, −3.146,
−0.008, +3.149, +9.466, +15.730 and +22.055 cents**. Stored 127 reads
**−140.012, −99.993, −59.987, −20.013, −0.010, +19.990, +60.007,
+99.993 and +140.007 cents**. Sweeps at stored 8, 16, 32, 64 and 96 and at
notes 60, 84 and 108 follow the same signed law. The engine now binds the base
step directly and renders all nine components inside every outer layer; it no
longer multiplies parameter 76 by parameter 93's symmetric spread.

Parameter 75 composes outside that field. With two voices, p75=64 and p76=127,
the probe resolves all **18** Cartesian frequencies, from −153.617 to +153.607
cents. The p76 voice-count control asks for 9, 18 and 36 peaks at counts 1, 2
and 4 and gets exactly those counts; the first/last readings are
−140.012/+140.007, −153.617/+153.607 and −153.622/+153.611 cents. Thus the
inner field stays nine components per outer layer rather than taking its size
from parameter 93.

The free phases are signed and are not an additive inner-plus-outer table. The
probe prints all 36 separately resolved phases at p75=64/p76=127. A second
controlled field at p75=22/p76=20 reproduces each of the first four outer-layer
rows within 0.018 turns, which is the matrix used by the engine. Parameter 91 is
also explicit now: at p76=127, p91=0 prints the non-symmetric OSC1 phases
`+0.7420,+0.8907,+0.4712,+0.8070,0,+0.1927,+0.5815,+0.3503,+0.8183`
against the centre, while p91=1 puts every reading within 0.0075 turns of zero.

The sub was isolated rather than copied from OSC1. With a sine sub at `97=1`,
sub gain 110, one outer voice and oscillator 1 held at its own octave, p76=0
leaves one component at the sub frequency. At p76=127 the reference reads nine
sub components at −140/−100/−60/−20/0/+20/+60/+100/+140 cents. Each isolated
component reads **4402.9--4409.8** against the p76=0 centre at **14703.3**:
the gain is **0.3 per component**, not `1/9`. Its separately measured free
phases are
`+0.3728,+0.4481,+0.2350,+0.3992,0,+0.0920,+0.2871,+0.1751,+0.4059`.

Reproduce the signed values, the p75 Cartesian field, p91 alignment and the
three voice counts at note 60. The note-108 run also resolves the controlled
four-voice field; below note 96 its closest pair is narrower than one FFT bin.

```powershell
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe unisonprobe "ext/synth1/Synth1/Synth1 VST64.dll" `
  --fixture tools/s1probe/fixtures/unison-four.sy1 --values 22 --note 60
./build/s1probe.exe unisonprobe "ext/synth1/Synth1/Synth1 VST64.dll" `
  --fixture tools/s1probe/fixtures/unison-four.sy1 --values 22 --note 108
```

The DSP suite pins the two external signed frequency rows, the public one-voice
nine-component render, both signed phase sets and fixed alignment, and the
sub's signed frequencies and 0.3 gain. These tests do not derive their expected
values from the engine helpers and reject the former symmetric guess.

The one-voice phase values are reported only to the probe's finite precision
(0.0001 turns); closely spaced multi-voice peaks can fall below one FFT bin.
The **0.3** value is an isolated one-voice component gain, not a fitted global
trim for every outer layer. Those phase and component-gain limits stay open
outside the signed rows and controls above.

The committed p76-on fixture is the stop gate:

```powershell
./build/s1probe.exe compare "ext/synth1/Synth1/Synth1 VST64.dll" `
  tools/s1probe/fixtures/unison-four-p76-20.sy1 --limit 1 --note 60
```

The former engine read **3.26 dB spectral, +3.61 dB level and −0.40 dB null**.
The measured field reads **3.95 dB spectral, 0.78 dB envelope, +0.35 dB level
and −16.82 dB null**. Spectral error does not improve on this one fixture, so it
is not used as a broad pass claim; the load-bearing stop condition is that the
original detuned fixture no longer nulls near 0 dB.

The frozen shared subset has 48 p76-nonzero patches among the 67 selected
unison-on files. The same names were used before and after; the unison-off
control has 40 non-silent reference rows:

| metric, mean / median | before on | after on | before off | after off |
|---|--:|--:|--:|--:|
| spectral dB | 9.98 / 8.78 | 8.83 / 7.46 | 10.88 / 9.41 | 9.39 / 8.17 |
| envelope dB | 4.91 / 4.48 | 5.18 / 4.48 | 4.65 / 3.71 | 5.01 / 3.92 |
| signed level dB | −8.82 / −7.40 | −9.32 / −7.89 | −8.01 / −7.35 | −8.59 / −7.77 |
| null dB | −0.22 / −0.09 | −0.36 / −0.13 | −0.33 / −0.19 | −0.72 / −0.25 |

The spectral and null aggregates improve both with unison on and off, as they
must: parameter 76 is an OSC1 construction and remains active when parameter 73
is off. Envelope mean and signed level regress and are recorded rather than
hidden. This does **not** claim all parameter-76 or unison behavior is fixed.
The p76 phase rows for outer layers 4--7, its outer-layer sub phase composition,
and its FM and hard-sync interactions remain unmeasured; the engine retains the
separately measured component and outer offsets in those paths rather than
fitting a trim to this corpus.

The shared-bank gate keeps the original selection (`95 >= 32` and unison on),
flattens recursive input into numbered files, clears stale output, works with a
single selected patch under strict mode, writes `on.csv` and `unison-off.csv`,
and throws on any non-zero native probe exit:

```powershell
git archive --format=tar --output=build/unison-before.tar 8e6c3b4
Remove-Item build/unison-before-src -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force build/unison-before-src | Out-Null
tar -xf build/unison-before.tar -C build/unison-before-src
odin build build/unison-before-src/tools/s1probe -out:build/s1probe-before.exe
odin build tools/s1probe -out:build/s1probe.exe
$shared = 'path/to/the/frozen/shared-gate'
pwsh tools/unison-gate.ps1 -SharedBank $shared `
  -S1Probe build/s1probe-before.exe -Out build/unison-gate-before
pwsh tools/unison-gate.ps1 -SharedBank $shared `
  -S1Probe build/s1probe.exe -Out build/unison-gate-after
```

The reported frozen set has 79 files, 76 distinct parameter-record sets and 67
patches with unison enabled; those same 67 rows ran before and after. The full
unison-on aggregate is:

| metric, mean / median | parent `8e6c3b4` | repaired |
|---|--:|--:|
| spectral error | 12.3807 / 12.2725 | 9.7101 / 8.4670 |
| envelope error | 5.2059 / 4.6858 | 4.7638 / 4.1809 |
| signed level error | −11.0633 / −9.2135 dB | −7.1529 / −6.4072 dB |
| null depth | −0.4549 / −0.0417 dB | −0.6354 / −0.1138 dB |

Turning parameter 73 off killed the reference on the same 14 patches in both
runs, so the matched control has 53 rows. On that exact set:

| metric, mean / median | before on | after on | before off | after off |
|---|--:|--:|--:|--:|
| spectral | 12.3492 / 12.2725 | 9.6225 / 8.4670 | 13.7553 / 13.5947 | 10.3723 / 9.1411 |
| envelope | 4.9196 / 4.4619 | 4.6171 / 4.1809 | 4.4425 / 3.5207 | 4.3470 / 3.5705 |
| signed level dB | −10.0540 / −8.4668 | −6.1726 / −5.5544 | −6.2337 / −6.0828 | −6.6567 / −5.1165 |
| null dB | −0.4202 / −0.0458 | −0.6174 / −0.1520 | −0.7879 / −0.0839 | −0.9616 / −0.2257 |

The off control changes because parent `8e6c3b4` applied parameter 85 as a
global transpose even after unison collapsed to one layer. The repaired
alternating-layer law makes the unison pitch control inert in that state.

The factory no-change gate compared executables built from `8e6c3b4` and this
repair against all 123 loadable patches. The CSVs are byte-identical, SHA-256
`49cc89afe5dc1468fff0ea1e212ccaef2a21a13ab3ddb036e37f403c190233f9`.
No factory patch contains a 73, 75, 84, 85 or 92 record, which is the actual
reason this unison change cannot reach the bank. The unchanged summary is
spectral **6.6510 / 5.9766**, envelope **2.0969 / 1.7701**, absolute level
**1.6528 dB**, and null **−6.6582 / −6.0558 dB**.

```powershell
./build/s1probe-before.exe compare ext/synth1/Synth1/soundbank00 --csv build/unison-factory-before.csv
./build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv build/unison-factory-after.csv
```


### Still open on the sub

- **Unison**, above, which is now the leading defect on the corpus patches that
  use the sub.
- **The corpus-level residual**, below: the integrated HEAD pair measures
  `4.585238 / 4.569491 dB`, delta **+0.015747 dB**. The earlier accepted
  result was from a stale pre-integration measurement.
- **The corpus gate excludes FM and related controls**, so it does not add a
  second FM/sub measurement; the FM-to-sub law and its controls are measured
  above.
- **A uniform ~0.15 dB level deficit at amp gain 100**: single-oscillator
  renders read a reference fundamental of `0.3099` against our `0.3045` for the
  saw, `0.1085` against `0.1069` for the pulse at width 29 — 1.3 to 1.8 %,
  consistent across shapes, widths and notes.

## Amp gain 100 residual (2026-08-24)

The residual is a scale ownership error, not a special case at resonance zero.
`AMP_GAIN_AMPLITUDE` is absolute: `gainprobe` reads **0.48695** at state 100,
and the table stores **0.486947**. `FILTER_OUTPUT_GAIN` must therefore be a
relative resonance-level law whose state zero is one. The old generated curve
started at **0.982168**. Changing only entry zero to one fixed the neutral
render but left state one at **0.976835**, creating a false step at the start of
the knob.

The fixed law divides every measured output-gain entry by its measured neutral
entry. Its first values are now `1.000000, 0.994570, 0.989136, 0.983702`.
`qtable` performs that normalisation itself, requires a valid state-zero
measurement, and writes state zero as exactly one. Thus the generated source and
the engine agree; this is not a hand edit to generated code.

### Direct reference anchors

The probe patch is oscillator 1 alone, low-pass 12, cutoff 127, flat filter and
amp envelopes, velocity scaling off, and saturation and effects off. The DLL
path must be quoted. `filtersaturation` accepts oscillator shape and pulse width
and prints a linear fundamental amplitude, so all checked-in anchors come from
the same reproducible command:

```powershell
odin build tools/s1probe -out:build/s1probe.exe
$dll = "ext/synth1/Synth1/Synth1 VST64.dll"
./build/s1probe.exe filtersaturation $dll --type 0 --cutoff 127 --res 0 --note 60 --shape 0 --width 64 --values 0 --gains 100
./build/s1probe.exe filtersaturation $dll --type 0 --cutoff 127 --res 1 --note 60 --shape 0 --width 64 --values 0 --gains 100
./build/s1probe.exe filtersaturation $dll --type 0 --cutoff 127 --res 0 --note 60 --shape 1 --width 64 --values 0 --gains 100
./build/s1probe.exe filtersaturation $dll --type 0 --cutoff 127 --res 0 --note 60 --shape 2 --width 29 --values 0 --gains 100
```

The repaired sine results are:

| resonance | ref/ours fundamental | ref/ours RMS | ref/ours peak |
|---:|---:|---:|---:|
| 0 | 0.48695 / 0.48697 | 0.3348 / 0.3348 | 0.4870 / 0.4870 |
| 1 | 0.48427 / 0.48432 | 0.3329 / 0.3330 | 0.4843 / 0.4843 |

### Q-level residual outside the neutral anchor

The retained `qlevel` check at cutoff 48 covers states `0,1,32,127` for all
five bound filter types. Only state zero changes under the level repair; the
higher states remain byte-identical. The state-zero RMS pairs (before → after)
are:

```text
             state 0       state 1       state 32      state 127
LP12         .01455→.01481 .01452→.01452 .01380→.01380 .09157→.09157
LP24         .00794→.00809 .00808→.00808 .00916→.00916 .20377→.20377
HP12         .11010→.11210 .10951→.10951 .09137→.09137 .09994→.09994
BP12         .01316→.01340 .01314→.01314 .01256→.01256 .11353→.11353
LPDL         .00794→.00809 .00808→.00808 .00916→.00916 .20377→.20377
```

The larger mode-specific residuals at cutoff 48 are existing filter-topology
errors, not regressions from this repair. High-pass and band-pass are not used
as open-filter level controls because their response is not flat at that note.

Before the whole-law repair, state one read RMS **0.3270** and peak **0.4757**,
or about **-0.155 dB**, despite state zero matching. The engine's zero-to-one
drop was about **-0.204 dB** against the reference's **-0.048 dB**. The repaired
table removes that discontinuity. At state zero, saw and pulse fundamentals are
reference/ours **0.30994/0.30998** and **0.10846/0.10882** (pulse width 29).
THD remains unchanged; the sine reads **-66.8 dB** reference and **-67.9 dB**
ours.

The DSP tests keep these DLL readings as constants and project fresh public
engine renders. They do not read either generated gain table to form an
expectation. One test covers the three state-zero waveform fundamentals; a
second covers sine fundamental and peak at resonance states zero and one.

### Generator fixed point

The generator was run twice from the repaired engine. The second output was
byte-identical to the checked-in file:

```powershell
$dll = "ext/synth1/Synth1/Synth1 VST64.dll"
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe qtable $dll build/filter-resonance-1.odin
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe qtable $dll build/filter-resonance-2.odin
$source = (Get-FileHash src/engine/filter_resonance_table.odin -Algorithm SHA256).Hash
$regen = (Get-FileHash build/filter-resonance-2.odin -Algorithm SHA256).Hash
if ($source -ne $regen) { throw "qtable output differs from source" }
```

Both hashes are
`cf5fdd63bf9efcb248a16c7e216f8f064966528a539b385064e3d02053582390`.
Both sweeps resolved all 128 output-gain states and skipped none for clipping.

### Factory-bank gate

The bank evidence uses three pinned source endpoints: integration before this
work (`8e6c3b47c33b012da213f1bf96289c4d4f822069`), the incomplete state-zero
change (`afeba3cc6a0e106bf8c891d113d56cecb75506c2`), and the whole-law code
(`967f4b9f331e1417c394aa50911067c73c5bf531`). Each executable is built from a
separate `git archive`; no ignored binary can silently stand for both sides:

```powershell
$before = Join-Path $env:TEMP "quesynth-level-8e6c3b4"
$faulty = Join-Path $env:TEMP "quesynth-level-afeba3c"
$after  = Join-Path $env:TEMP "quesynth-level-967f4b9"
Remove-Item -Recurse -Force $before, $faulty, $after -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $before, $faulty, $after | Out-Null
git archive 8e6c3b47c33b012da213f1bf96289c4d4f822069 | tar -xf - -C $before
git archive afeba3cc6a0e106bf8c891d113d56cecb75506c2 | tar -xf - -C $faulty
git archive 967f4b9f331e1417c394aa50911067c73c5bf531 | tar -xf - -C $after
odin build "$before/tools/s1probe" -out:build/s1probe-8e6c3b4.exe
odin build "$faulty/tools/s1probe" -out:build/s1probe-afeba3c.exe
odin build "$after/tools/s1probe"  -out:build/s1probe-967f4b9.exe
./build/s1probe-8e6c3b4.exe compare ext/synth1/Synth1/soundbank00 --csv build/level-8e6c3b4.csv
./build/s1probe-afeba3c.exe compare ext/synth1/Synth1/soundbank00 --csv build/level-afeba3c.csv
./build/s1probe-967f4b9.exe compare ext/synth1/Synth1/soundbank00 --csv build/level-967f4b9.csv
./build/s1probe-967f4b9.exe summarise build/level-8e6c3b4.csv
./build/s1probe-967f4b9.exe summarise build/level-afeba3c.csv
./build/s1probe-967f4b9.exe summarise build/level-967f4b9.csv
```

| metric | integration | state-zero only | whole law |
|---|---:|---:|---:|
| spectral mean / median | 6.65 / 5.98 | 6.65 / 5.98 | 6.65 / 5.98 dB |
| envelope mean / median | 2.10 / 1.77 | 2.10 / 1.77 | 2.10 / 1.77 dB |
| signed level mean / median | +0.18 / +0.06 | +0.22 / +0.10 | +0.33 / +0.22 dB |
| absolute level mean / median | 1.6528 / 1.1099 | 1.6447 / 1.1099 | 1.6767 / 1.1156 dB |
| null mean / median | -6.66 / -6.06 | -6.66 / -6.06 | -6.66 / -6.06 dB |

All three runs contain 123 rows, the same five reference crashes (095, 098,
100, 101, 106), no reference-silent, engine-silent, non-finite, or load-failed
rows, and the same four engine renders silent by sustain. CSV SHA-256 values,
in table order, are:

- `49cc89afe5dc1468fff0ea1e212ccaef2a21a13ab3ddb036e37f403c190233f9`
- `d3422df7a33c635cc4fbf8f1efa2579672975036eab196c99f879d6d073ce66d`
- `c88f367e01e5893fd26f605f010cf7598fe32d213938d0c3a9811fc4ddb4987b`

The state-zero-only commit moved 30 patches. Eighteen improved in absolute level
error; these 12 regressed: **005, 006, 010, 012, 013, 014, 018, 034, 075, 103,
109, 118**. The whole-law repair retains those measured state-zero results and
moves the other 93 patches. Of those, 34 improve: **001, 017, 020, 026, 027,
028, 030, 032, 037, 049, 050, 055, 059, 060, 063, 067, 074, 076, 079, 081,
082, 083, 086, 087, 093, 094, 102, 104, 105, 110, 119, 120, 122, 128**. The
other 59 regress in absolute level error: **007, 008, 015, 016, 019, 021, 022,
023, 024, 025, 029, 031, 035, 036, 038, 039, 040, 041, 042, 043, 044, 045,
046, 047, 048, 051, 053, 054, 056, 057, 058, 061, 062, 064, 065, 066, 068,
069, 070, 071, 072, 073, 077, 084, 088, 091, 092, 096, 099, 107, 108, 112,
115, 116, 117, 121, 123, 124, 125**. Relative to integration, the final count
is therefore 52 improved and 71 regressed, with none unchanged.

Those regressions are expected and bounded, not omitted evidence. The measured
law raises every resonance state by `1 / 0.982168`, or **+0.156284 dB**. A patch
that was already loud must worsen in absolute level error even though this
specific amp-gain ownership error is fixed; the factory bank also contains
other level defects and was not used to fit this constant. Every row moves by
0.1562 or 0.1563 dB except 123, whose peak is already about 1.88 and enters the
measured output limiter; it moves by 0.1492 dB and its scale-sensitive envelope
score changes by 0.0367 dB. Spectral, envelope, and null aggregates remain
unchanged at the report's precision. No crash, silence, or finite-sample status
regresses.
### The integrated corpus residual remains open (2026-08-25)

The earlier accepted result is stale. The integrated HEAD was measured first,
using the pinned reference DLL and index:

- HEAD: `8ad672d3dfeb1eda9210cf8501a0b53b53897a9d`
- reference SHA-256: `51c6fe60d767c78f5a15b7023173ac5709edbcf03a55cbac9032569ba22f32c7`
- index SHA-256: `bf3227a7f5b3dfd7095283ecdbf1962e4dc6738a63b67b6bbdc976edbc8b72e2`
- 97 identities, 92 matched rows, and the same crashes: `s022`, `s034`,
  `s040`, `s053`, `s087`
- base CSV SHA-256: on `0ffb2b7a140c2734db67bda5408a9c0658a98fb82312c1fed05e49f0bb04a6c8`,
  off `c79ef79d39ea956b0e0112706e7963703aec13e51a2529e961f95f1882940c65`

The exact measurement is:

| pair | on MAE | off MAE | delta |
|---|---:|---:|---:|
| integrated HEAD base | 4.585238 | 4.569491 | **+0.015747 dB** |

The earlier `+0.280227 dB` is superseded, not unexplained. It was measured on
the pre-merge line at `ab9f679`, before the level, FM, unison and parameter-76
work was integrated. The stored pre-parameter-76 integration CSVs
(`build/pre76-on.csv`, `build/pre76-off.csv`) read `4.699363 / 4.486818`, or
`+0.212545 dB`, on the same 92 rows. Integration moved the figure; the cohort
did not change and nothing was refitted.

The MAE delta hides large row motion: mean absolute change in the gate metric
is `1.1016 dB`, mean absolute raw signed-error movement is `1.265414 dB`, and
the signed on-minus-off mean is `+0.127855 dB` (`30 / 38 / 24` better, worse,
same at a 0.05 dB threshold). These are distinct metrics; neither is a trim
target.

The six exact-variant controls are matched evidence, not causal proof. Their
labels are the parameter interventions, not the old swapped labels:

| control | on MAE | off MAE | delta | gate movement |
|---|---:|---:|---:|---:|
| EQ flat | 4.186843 | 4.111374 | +0.075470 | 0.8907 |
| delay off | 3.808040 | 3.822808 | −0.014767 | 1.0436 |
| chorus off (`p66=0`) | 4.547145 | 4.453549 | +0.093596 | 1.0214 |
| effect off (`p77=0`) | 2.891026 | 2.958730 | −0.067704 | 0.8142 |
| post off | 1.755282 | 1.763351 | −0.008070 | 0.4936 |
| filter open | 4.215401 | 4.068007 | +0.147395 | 0.8504 |

`post-off` changes five settings and still leaves mixed row movement. The
single-stage controls do not isolate a law. There is, however, a useful
parameter-23 lead on the 92 matched base rows: `p23=0` has `n=24`, on/off MAE
`3.860583 / 4.068900 dB`, delta `-0.208317 dB`; `p23>0` has `n=68`, on/off MAE
`4.840999 / 4.746171 dB`, delta `+0.094828 dB`. This split motivated the direct
saturation experiment below; it is a lead, not row-level causal proof. The
historical 586-row reference-only sweep was temporary and untracked, so its
executable source is not reviewable and it is not causal evidence.

The licensed 16,698-file source corpus is not present in this checkout, so the
original selection cannot currently be rerun. The pinned index and all 14
generated variant directories were hash-verified. With the source corpus
available, the reproducible gate is:

```powershell
node tools/corpus-level.mjs prepare build/tmp/corpus build/corpus-level-97
node tools/corpus-level.mjs verify-index build/corpus-level-97-index.csv
$reference = "ext/synth1/Synth1/Synth1 VST64.dll"
odin build tools/s1probe -out:build/s1probe-final-head.exe
$variants = @("on", "off", "on-eq-flat", "off-eq-flat", "on-delay-off",
  "off-delay-off", "on-chorus-off", "off-chorus-off", "on-effect-off",
  "off-effect-off", "on-post-off", "off-post-off", "on-filter-open",
  "off-filter-open")
foreach ($variant in $variants) {
  ./build/s1probe-final-head.exe compare $reference "build/corpus-level-97-$variant" --no-floor `
    --csv "build/final-head-corpus-$variant.csv"
}
node tools/corpus-level.mjs analyse build/final-head-corpus-on.csv `
  build/final-head-corpus-off.csv build/corpus-level-97-index.csv
```

### Tracked substage factorial

`substageprobe` is the decisive matched reference/engine measurement. It is
implemented in `tools/s1probe/substageprobe.odin`, registered in
`tools/s1probe/main.odin`, and enforced by `odin test tools/s1probe`. Every
cell loads a fresh reference instance and uses the comparator's 48 kHz, 512
frame blocks, MIDI velocity 100, and 1.5 second hold. The fixed patch has
OSC1 sine, OSC2 triangle at stored `p2=68` (+4 semitones), sub sine at `p97=1`,
`p76=0`, open LP12, flat EQ, effects off, fixed phase, and gain 64. It measures
mid-channel Hann-projected amplitudes at `f0/2`, `f0`, and OSC2's `f2`, plus
THD, RMS, peak, parameter mismatches, and non-finite samples.

The corrected default is the continuous stored-95 sweep
`0,16,32,48,64,80,96,112,127`, not the former two selected nonzero points.
Metric calculation preserves the render/mismatch `row_ok` result. Ordinary
amplitude observables must be above `1e-5` of each render's own peak (-100 dB)
and have explicit CSV validity columns; therefore noise-only bins are not
printed as measurements. The separate leakage control deliberately measures
lower, relative to an audible isolated OSC2 fundamental, at every requested
note and at the selected gain.

```powershell
odin test tools/s1probe
odin build tools/s1probe -out:build/s1probe-substage-corrected.exe
./build/s1probe-substage-corrected.exe substageprobe $reference `
  --notes 60 --mix 0,96 --saturation 0,64 --gain 64 `
  --csv build/substage-corrected-note60.csv
./build/s1probe-substage-corrected.exe substageprobe $reference `
  --notes 48,72 --mix 0,96 --saturation 0,64 --gain 64 `
  --csv build/substage-corrected-notes48-72.csv
```

The two CSVs are the reproducible pins:

- note 60 CSV: `6390a29d1aff3a87d25bade9c616c307b928a2dc5aa8698337dcb6b809424ba6`;
- notes 48 and 72 CSV: `328209975fd6509f4235ec18a363d57c09077e3254a8b208052df3bb10112aaa`.

Both reproduce byte for byte from a fresh `odin build tools/s1probe` at this
commit against the pinned reference DLL
`51c6fe60d767c78f5a15b7023173ac5709edbcf03a55cbac9032569ba22f32c7`. The probe
executable itself is not pinned: its PE header carries a link timestamp, so two
builds of identical source differ in hash while their CSV output does not. Only
hashes that a reader can regenerate are recorded here.

The signed formula is `E = 20 log10(ours / reference)`, so positive means
ours is high. `R` is the sub/carrier ratio residual. All 48 valid `R` cells at
`p23=0` (eight nonzero p95 values, two mixes, three notes) are negative, from
`-0.003111` through `-0.000199 dB`; the former “no stable sign” statement was
wrong. Their magnitude still passes the +/-0.10 dB sub-coefficient band.

`C` is the carrier on/off denominator residual. The table reports every
nonzero-p95 C condition. Each cell gives note 60 exactly followed by the full
notes 48/60/72 range in brackets:

| p95 | mix | C, p23=0 dB | C, p23=64 dB |
|---:|---:|---:|---:|
| 16 | 0 | -0.000001 [-0.000002,+0.000006] | +0.013470 [+0.013380,+0.013840] |
| 16 | 96 | -0.000002 [-0.000002,+0.000006] | +0.060752 [+0.060394,+0.060752] |
| 32 | 0 | -0.000003 [-0.000004,+0.000012] | -0.209952 [-0.210111,-0.209254] |
| 32 | 96 | -0.000003 [-0.000004,+0.000012] | +0.033038 [+0.032392,+0.033038] |
| 48 | 0 | -0.000004 [-0.000006,+0.000018] | +0.182076 [+0.181914,+0.182938] |
| 48 | 96 | -0.000004 [-0.000006,+0.000018] | -0.064619 [-0.065569,-0.064619] |
| 64 | 0 | -0.000006 [-0.000008,+0.000024] | +0.741073 [+0.740953,+0.741974] |
| 64 | 96 | -0.000006 [-0.000008,+0.000024] | -0.192038 [-0.193143,-0.191615] |
| 80 | 0 | -0.000007 [-0.000010,+0.000030] | +0.901385 [+0.901318,+0.902298] |
| 80 | 96 | -0.000008 [-0.000010,+0.000030] | -0.290752 [-0.292044,-0.289019] |
| 96 | 0 | -0.000009 [-0.000012,+0.000036] | +0.883081 [+0.883061,+0.884008] |
| 96 | 96 | -0.000009 [-0.000012,+0.000036] | -0.295471 [-0.296846,-0.292351] |
| 112 | 0 | -0.000010 [-0.000014,+0.000042] | +0.807426 [+0.807426,+0.808368] |
| 112 | 96 | -0.000010 [-0.000014,+0.000042] | -0.208121 [-0.209138,-0.203101] |
| 127 | 0 | -0.000012 [-0.000016,+0.000047] | +0.722489 [+0.722489,+0.723447] |
| 127 | 96 | -0.000012 [-0.000016,+0.000047] | -0.080129 [-0.081266,-0.074223] |

Thus only the `p23=0` denominator control passes +/-0.05 dB. Many `p23=64`
cells fail it; omitting them was selective reporting.

### Continuous saturation interaction and candidate law

At note 60, mix zero, the p23=64 raw `E_carrier` curve for p95
`0,16,32,48,64,80,96,112,127` is respectively `+0.172305, +0.185775,
-0.037647, +0.354381, +0.913378, +1.073691, +1.055387, +0.979731,
+0.894794 dB`. After the matched p23=0 and p95=0 controls, `I_carrier` at the
eight nonzero points is `+0.013471, -0.209949, +0.182080, +0.741078,
+0.901393, +0.883090, +0.807436, +0.722500 dB`; `I_R` is `+0.182809,
+0.480515, -0.123956, -0.759514, -0.893852, -0.845904, -0.750454,
-0.654299 dB`. Notes 48 and 72 reproduce the curve: across all notes and both
mixes, maximum magnitudes are `0.902308 dB` for `I_carrier` and `0.894095 dB`
for `I_R`. This is one note-stable, drive-dependent curve with a zero crossing,
not absence of a stable law. The old same-sign test at only p95 32 and 96
straddled that curve and was mis-specified.

Saturation engagement remains valid: reference THD movement at p95=0, mix=0
is `+90.444556`, `+106.438957`, and `+119.892771 dB` at notes 48, 60, and 72;
ours is `+89.071423`, `+104.574490`, and `+106.170373 dB`. At the p5=127
endpoint, OSC2 and RMS on-minus-off are `+0.000000 dB` in both the reference
and engine at all three notes. Leakage is checked at all three notes and gain
64 (worst reported f0/f2 is below -119 dB); every factorial row has zero
mismatches, zero non-finite samples, and peak below 0.8.

The same run also breaks the single-tone saturation transfer. At `p95=0`,
mix 96 and `p23=64` the reference THD is `-17.032`, `-17.175` and
`-17.080 dB` at notes 60, 48 and 72 while this engine reads `-36.147`,
`-36.470` and `-36.172 dB`, and the matched `p23=0` control has no comparable
gap. The single-tone cell of the same run still lands on the tabulated
-13.9 dB knot. This is recorded with the transfer itself under "Filter
saturation, measured and implemented" above; it is the direct waveform-domain
statement of the interaction curve measured here.

Matched reference waveform analysis names a candidate transfer for p23:

\[
y = \frac{x(1+d)}{1+d|x|}
\]

This is a peak-normalised softsign, rather than the currently implemented
peak-normalised tanh derived from one sine. At stored p23=64 the direct
reference fit gives `d=2.831889409` and about `-68.9 dB` waveform residual.
A temporary implementation using reference-fitted softsign drive knots reduced
the full three-note direct interaction to maximum `|I_carrier|=0.007389 dB`
and `|I_R|=0.007277 dB`; its probe CSV SHA-256 was
`425822b214e87ece46c44efaa96301d28c13a30b63853dc87d70bb43d689bb06`.

The waveform fitter, fitted knot table, and temporary mutation were exploratory
build artifacts and are not tracked. They are a bounded lead, not accepted
proof or a basis for an engine change. The tracked, pinned evidence is the
two-tone interaction curve above; that measured law remains open.

The candidate was nevertheless rejected by the required 92-row closure gate:

| engine | on MAE | off MAE | delta |
|---|---:|---:|---:|
| integrated baseline | 4.585238 | 4.569491 | +0.015747 dB |
| temporary softsign | 4.590173 | 4.499079 | +0.091093 dB |

The candidate on/off CSV SHA-256 values were
`548ab76a1df2a2dff5b9dd1998df4744e8b95876eecc84d59e06186be0152167`
and `993f9df5727e23c0d7795a5f54b07439370b95b76e50c0cbcd400144870d31a2`.
Coverage remained 92 rows with the same five crashes. All 24 p23=0 rows were
byte-identical. Among 68 p23>0 rows, absolute error improved/worsened `42/26`
for sub-on and `46/22` for sub-off. Most importantly, sub-on worsened from its
baseline and remained above sub-off, so the repair acceptance gate failed.

The full factory candidate also failed the row-prediction gate even though its
aggregate absolute level MAE improved from `1.676711` to `1.637975 dB`: only
five of 123 matched rows changed, with two better and three worse, and no
independent prediction supplied every changed row's error direction. Its CSV
SHA-256 was `d6b82008d2fc2de72dbc83bb2fa7b86718a5d1ebfe55358b019777810fdc3447`;
the same five reference crashes remained. Aggregate improvement cannot replace
the required row-level prediction.

The temporary DSP/engine mutation was reverted. No trim was fitted, and this
repair changes no DSP or engine file. The peak-normalised softsign remains a
named two-tone candidate, but its implementation is blocked by the corpus and
factory gates.

**This is not a pass.** The preregistered stop condition for leaving the engine
unchanged was that no stable signed `R`, `C` or `I` remains. `R` passes its
band. `C` and `I` do not: `C` at `p23=64` reaches `+0.901` dB against a
±0.05 dB band, `I_carrier` reaches `0.902` dB and `I_R` reaches `0.894` dB
against a ±0.10 dB band, raw `E_carrier` reaches `+1.074` dB, and all of them
hold their sign across notes 48, 60 and 72 to within about 0.003 dB. A
note-stable, drive-dependent saturation law of up to roughly 1.07 dB is
therefore measured, named, and left open. The engine is unchanged because the
only candidate replacement failed the corpus and factory row gates, not because
the residual was shown to be absent.

### Full factory baseline

The integrated executable was run against all 128 factory patches. The CSV
SHA-256 is `dd13c651be53eaaa1a6496f701cccb9f825b22fc960bc738b8759168285b7319`.
There are 123 matched rows and the same five reference crashes (`095`, `098`,
`100`, `101`, `106`), with zero parameter mismatches, zero engine non-finite
rows, and four engine-silent-by-sustain rows. Absolute level MAE is
`1.676711 dB`; signed level mean/median are `+0.33 / +0.22 dB`. No factory
patch has nonzero parameter 95, so this bank is regression evidence only and
cannot prove the sub law.

## The compressor is a leveller (2026-08-25)

`comp.` was the one type in the effect unit whose diagnosis was already written
down and never acted on: 0.87 dB of spectral error, better than the section's own
floor, against 15.19 dB of envelope error. The timbre right and the dynamics
wrong. What had not been noticed is that the same reading also says the *static*
law was never measured at all, and it was the static law that was wrong.

Nine of the ten types in this section were named from what they do to a pure
tone. That instrument cannot work here and the section's own notes say why: a
compressor "adds nothing, and changes the envelope". One tone at one level is one
point on a curve whose whole content is its shape.

### The instrument

Hold the tone and move the level going in. Every point renders the same patch
twice, once with the unit switched off, and the off render *is* the measurement
of what arrived — so the input is never inferred from the amp gain knob, whose
own curve would otherwise be fitted into the answer. Both renders happen in this
process, the reference through the DLL and ours through the statically linked
engine, so the columns are matched rather than merely comparable.

```
ctl1 = 64, ctl2 = 127, level 127, note 48, settled RMS in dBFS
  in    -51.9  -42.0  -35.3  -27.1  -21.5  -17.0  -13.3  -10.0   -7.1   -4.7
  out   -21.7  -12.9  -11.2  -10.8  -10.8  -10.7  -10.7  -10.7  -10.7  -10.7
```

The output does not move. Over a 37 dB span of input it stays within a tenth of a
decibel of −10.74 dBFS. That is a **leveller** — gain reduction tracking input one
for one — and not the threshold-and-ratio compressor that was implemented, which
had a threshold at 0.25, a ratio reaching 20:1 and a flat +10.9 dB of make-up
where the reference was giving +30.2.

### Depth is an input gain

Plot each depth against the level *after* its own make-up and the curves fall on
top of each other. Over 115 points at seven depths, the residual of predicting
each point from the other depths' points is **0.0024 dB mean and 0.088 dB worst**,
and that worst point is the knee, where interpolating between neighbours is
hardest.

So depth is not a threshold, a ratio or a knee width. It is a gain in front, and
it is linear in decibels across exactly forty of them:

```
  ctl1        0     16     32     64
  make-up +10.00 +15.04 +20.08 +30.16 dB     10 + 40*(ctl1/127) fits all four
```

The three depths above 64 were held back rather than fitted, because at those
settings even the quietest render this patch can produce is already compressing,
so the make-up cannot be read off directly. Predicting them puts all twelve rows
within **0.02 dB**:

```
  ctl1 = 96      in  -55.43  -51.85  -49.38  -47.44
                 ref -15.19  -12.75  -11.92  -11.51
                 predicted   -15.21  -12.77  -11.92  -11.52
  ctl1 = 127     in  -55.43  -51.85  -49.38  -47.44
                 ref -11.26  -10.97  -10.87  -10.83
                 predicted   -11.26  -10.97  -10.87  -10.83
```

Two more controls say this is the whole law. Notes 36 and 72, three octaves
apart, reproduce note 48 to three decimals, so nothing here is frequency
weighted. And the level knob moves every point by the same amount — 0.23625 dB
per step, 30.0 dB across the range, which is the crossfade law already measured
for this type — so it is an output gain sitting after all of this rather than part
of it.

### One instrument error, caught by disagreement

The first sweep was run at ctl2 = 0, the fastest attack, on the reasoning that a
fast detector settles soonest. It gives a curve of the same shape sitting up to
1.09 dB lower, and it is not the static law: at 2 ms against a 7.7 ms period the
gain moves *within* the cycle, which is the −6.7 dB of THD this section already
had on record for that setting. The static curve has to be read where the
detector cannot follow the waveform. The two sweeps agreeing in shape and
disagreeing in level is what identified the mistake.

### The curve

A table rather than a formula, because no formula was found that fits. The curve
is exactly unity below −15.3 dB — identity to four decimal places, a real
threshold and not a soft approach to one — and then bends over into limiting far
more sharply than a soft knee does while still taking twenty decibels to get
there. Every closed form tried was either too gentle at the corner or still
compressing below the threshold: a peak-normalised algebraic saturator at any
exponent, tanh, `1 − exp`, and the standard quadratic soft knee. On a one-decibel
grid the table reconstructs the 118 measured points to **0.0018 dB mean, 0.0426 dB
worst**, that worst again at the knee, which is better than any of them managed
anywhere.

### The detector is symmetric, and that is measured twice

The rebuilt engine matched the reference's curve to 0.51 dB and then stopped,
with a flat **+0.68 dB** left over at every level in the limiting region — the
signature of a constant, not a curve. It was the detector: 190 ms of attack
against 120 ms of release settles off-centre on a signal that ripples, because it
tracks downward faster than up. Making the two equal took the residual to
**0.00 dB at every point**. A steady tone cannot be levelled to the same place by
an asymmetric detector, so the reference's is not one.

The second line of evidence is independent and comes from the other direction.
Timing the gain's return after a step down — with the amplifier's own decay
providing the step — the recovery slows as ctl2 rises, which a fixed release
cannot do:

```
  ctl2         32     48     80     96
  attack      6.3   11.2   35.2   62.5  ms, the law already measured
  recovery     ~9    ~16    ~49    ~80  ms, first-order fit to the trajectory
```

One knob, one time constant, both directions. The recovery reads about 1.35 times
the attack rather than exactly equal, and that factor is **not** adopted: the two
are measured through different mappings — the attack from an overshoot in level,
the recovery from a gain trajectory through the knee — and a sweep of the scale
across five settings of ctl2 confirms it buys nothing.

```
  detector scale   1.0    1.35   1.7    2.2
  ctl2 = 0        1.72    1.78   1.82   1.86   mean |gain error|, dB
  ctl2 = 32       0.23    0.32   0.39   0.46
  ctl2 = 64       0.25    0.33   0.40   0.47
  ctl2 = 96       0.70    0.78   0.83   0.88
  ctl2 = 127      1.54    1.51   1.43   1.26
```

So the attack law is left exactly as it was measured, and the only change to the
dynamics is the symmetry.

### The other instrument this needed

Timing a compressor by watching its output confounds two things, because the
level moving is the input moving *and* the gain moving. Rendering the same patch
twice and dividing frame by frame separates them exactly and needs a model of
neither: the ratio is the gain the unit applied, with the note's own envelope
cancelled out of it. That is `comptrace`, and it is what both the recovery
readings and the scale sweep above are measured with.

### What it bought

The level sweep it was diagnosed with, at the depth and attack the curve was read
at, over 37 levels spanning 51 dB:

```
                          mean |error|   worst
  before                     11.25 dB   19.25 dB
  after                       0.00 dB    0.04 dB
```

And the direct A/B against the reference, on the `comp.` row, at six operating
points. Spectral and envelope are decibels of error; level is ours minus theirs:

```
  ctl1  ctl2      spectral            envelope             level
                before  after      before  after      before   after
     0    64     0.99    0.34       8.46    0.28      +5.80   -0.07
    64     0    17.17   16.48       3.52    5.73      +8.74   +0.82
    64    64     0.29    0.36      11.52    4.94      +8.17   -0.68
    64   127     1.60    0.02      23.76   12.12      +3.90   -6.50
    96    96     0.65    0.10      22.57   12.75      +4.80   -5.05
   127    64     0.29    0.36      15.05    7.78      +7.51   -1.45
  mean            3.50    2.94     14.15    7.27       6.45    2.43
```

The factory bank is untouched, and has to be: no patch in it switches this unit
on. Both executables were run against all 128 patches and the CSVs are
byte-identical, SHA-256 `dd13c651be53eaaa1a6496f701cccb9f825b22fc960bc738b`
`8759168285b7319`, which is also the hash already recorded for the full factory
baseline above.

### Two residuals, both measured, both left open

**The fast attack sits 0.78 dB high.** At ctl2 = 0 the reference's settled level
is 0.78 dB below its own slow-attack level, from the gain moving within the cycle,
and this engine reproduces 0.01 dB of that. The obvious cause is not the cause:
making the detector ten times faster at that end of the knob — 2 ms to 0.2 ms —
moved the residual from 0.77 to 0.73 dB, so it is not the time constant, and the
measured attack law is left alone. It is the `ctl1=64 ctl2=0` row's remaining
16.48 dB of spectral error.

**The slowest attack overshoots on the way in.** At ctl2 = 127 the level error
went from +3.90 to −6.50 dB while everything else on that row improved, and the
trajectory says where it comes from: at the note's first frames the reference has
already applied 5.4 dB of reduction where this engine has applied 13.3. Both
detectors start from silence and neither reaches the true level for tens of
milliseconds; they take different paths there. The static law is exact at that
setting — 0.00 dB over 37 levels — so this is the detector's approach and not the
curve.

### Reproducing it

```powershell
$reference = "ext/synth1/Synth1/Synth1 VST64.dll"
odin build tools/s1probe -out:build/s1probe.exe

# the static law, and the collapse that shows depth is an input gain
./build/s1probe.exe compcurve $reference --ctl2 127 --level 127 `
  --depths 32,48,64,80,96,112,127 `
  --gains 2,4,6,8,10,12,16,20,24,32,40,48,64,80,96,112,127 --csv build/comp-law

# the dynamics: the gain itself, with the note's envelope divided out
./build/s1probe.exe comptrace $reference --ctl1 64 --ctl2 64 `
  --amp 127 --decay 24 --sustain 32 --step 2

# and the section's own A/B
./build/s1probe.exe fxcompare $reference --ctl1 64 --ctl2 64 --level 127
```

## The phasers: it was a stage count after all (2026-08-25)

Two readings in this section were marked unfinished -- the depth curve and the
level law -- and finishing them overturned a third that was not marked at all.

### The old depth numbers were the instrument measuring itself

```
  ctl1        0     16     32     64     96    127
  band     2800   2923   3057   3304    131    131   Hz
           2800   6839   7781  10465  10465  10465
```

131 Hz and 10465 Hz are not edges of anything the plugin does. The saw probe's
fundamental is 130.8 Hz and it uses eighty harmonics, so 131 and 10465 are the
lowest and highest frequencies that instrument can see at all. Above ctl1 32 the
resonance simply leaves it and every reading after that is the window reporting
its own size. The note in the margin -- "the 131 Hz readings are the analysis
window's floor rather than the sweep's" -- was right, and the table was left in
anyway.

Widening the window cannot fix it: harmonics have to be resolvable, so a lower
fundamental needs a longer FFT, and a longer FFT smears a corner that is moving.
A sweep is exactly the case where both requirements bite at once.

### A tone, not a spectrum

`phaserband` drops the spectrum entirely. A resonance passing over a tone
announces itself in that tone's own level, so a single sine held at frequency f
rises by the height of the resonance, briefly, once per sweep -- but only if the
corner reaches f at all. Sweeping f over nine octaves and asking whether the peak
ever arrives maps the swept band directly, at a resolution set by the spacing of
the notes and by nothing else.

The control is ctl1 = 0, where the sweep stops and the answer is already known.
It returns a single sharp peak of **+25.85 dB at 2794 Hz** with a -11 dB skirt
below and 0 dB above, which is the shape this section already had on record, and
the peak equals the floor in every row, which is what "static" looks like.

### The instrument's own error, and the control that caught it

The first depth readings were nonsense in an interesting way: the band's lower
edge was not monotonic in depth, rising from 2960 Hz at ctl1 8 to 4186 Hz at
ctl1 48 and then falling to 2093 Hz at 127. No depth control does that.

Holding the depth fixed and moving the *rate* -- which by every earlier
measurement is a separate control that does not touch the depth -- showed the
reading was the instrument's:

```
  ctl1 = 8, band read at five rates
  ctl2        48        64        80        96       112
  band   2960-3729 2960-5274 3729-5920 5274-5920 5920-6645  Hz
```

Two causes, both fixed by one rule. A corner sweeping quickly crosses a note in
less than one analysis frame, so its peak is averaged away; and at the slowest
rates the LFO period reaches 8 seconds, so a 6-second render does not contain a
whole sweep. Requiring the render to hold **three complete LFO cycles** and
keeping the rate off the top of its range makes three rates agree exactly:

```
  ctl1 = 48       ctl2 48 / 12 s   ctl2 64 / 6 s   ctl2 80 / 3 s
  band              4186-8372       4186-8372       4186-8372   Hz
```

### The finding: one resonance per type, not one shape at four frequencies

This section concluded that ph1 to ph4 are one shape at four centre frequencies
-- 2878, 3924, 5494 and 6540 Hz -- and that "what separates ph1 from ph4 is the
centre frequency, not the number of sections". That is wrong, and it is wrong
because only the tallest peak was read. Sweeping the tone down to 55 Hz at
ctl1 = 0 finds the rest of them:

```
  static response at ctl1 = 0, level 127, dB against the unit off
  Hz        55     65     78     92    110    131    156    185    220    262    311
  ph1    -4.06  -5.42  -6.72  -7.94  -9.10 -10.09 -10.93 -11.56 -11.98 -12.15 -12.06
  ph2    -8.90 -10.04 -10.98 -11.61 -11.97 -11.56 -10.22  -7.23  -0.39 +11.49  -3.59
  ph3   -10.91 -10.26  -7.87  +0.04  +8.70  -6.02 -10.92 -11.05  -5.91  +7.61  -8.16
  ph4    -5.07  +9.28  -0.17  -8.74 -10.79  -4.37  +1.43  -9.71  -8.05  +5.25 -10.17
```

Every one of those is a peak standing 9 to 20 dB clear of both neighbours, and
they count out exactly:

| | extra resonances | the tall one | total |
|---|---|---|---|
| ph1 | none | 2794 Hz | **1** |
| ph2 | 262 | 4186 | **2** |
| ph3 | 110, 262 | 5920 | **3** |
| ph4 | 65, 156, 262 | 7040 | **4** |

> These counts are **low**, and the finer instrument in the next section says by
> how much: ph3 has four resonances and ph4 has six. At three-semitone spacing
> ph3's 605 Hz and ph4's 441 Hz fall between the notes. The direction of the
> correction stands -- it is a comb that grows with the type -- but the numbers
> to use are the ones measured per resonance.

So it is a stage count, the shipped implementation has had the right count since
the first guess, and what it is missing is what turns an allpass chain's notches
into resonances: **feedback**.

### The level law, which was never a level

Parameter 81 for these four types was recorded as unmeasured, with the note that
at level 0 they come back "louder than bypass and broadband, fitting neither of
the two laws the other six types follow". Measured directly, per frequency, at
ctl1 = 0 where the response is static:

```
  level        0     32     64     96    104    112    118    122    127
  peak      -2.61  -1.70  -0.13  +3.35  +5.07  +7.68 +10.92 +14.56 +25.85  dB at 2794 Hz
  skirt     -1.53  -2.08  -4.69  -8.24  -8.94  -9.48  -9.80  -9.96 -10.09  dB at 131 Hz
```

It is not a mix and it is not an output gain. At level 0 the response is flat to
within a decibel; as the knob rises the peak grows and the notch deepens
together, and the output level far from either barely moves -- at 8372 Hz it runs
+0.63, +0.47, +0.16, -0.15, -0.39, -0.71 dB across the top six settings, which is
unity throughout. A knob that deepens a notch and raises a peak while leaving the
broadband level alone is a **feedback** control.

Read as one, the numbers are a clean law. A feedback loop's peak gain is
1/(1-g), so the measured peak states g outright:

```
  level        96     104     112     118     122     127
  g        0.3208  0.4426  0.5870  0.7155  0.8129  0.9491
  fitted   0.3241  0.4407  0.5856  0.7157  0.8135  0.9491    g = 0.9491*(L/127)^3.84
```

Every fitted peak lands within **0.05 dB** of the measurement. The exponent is
stable at 3.82 to 3.88 across the five points it is fitted through.

This also explains the two things that made the old reading look unfit for either
law. "Louder than bypass" and "broadband" are the same observation: at level 0
the feedback is zero, the comb collapses, and what comes back is nearly flat.

### The depth curve, and where it stands

At large depth the band is now rate-independent and reproducible:

```
  ctl1        48        80        127
  band   4186-8372  2960-9956  2093-11840  Hz
  span      1.00       1.75       2.50     octaves
```

At small depth it is not, and the reason is the finding above rather than the
instrument: with several resonances sweeping at once, "the band" is the union of
several narrow excursions, and which of them a sweep of held tones catches
depends on where the notes fall. The union only becomes a single contiguous
interval once the excursions overlap, which is why ctl1 48, 80 and 127 agree
across rates to the note while 8 and 24 do not. The summary statistic is the
wrong abstraction below that point, not a broken measurement.

So the depth curve is measured where it is meaningful and named where it is not.
What it needs is a probe that tracks each resonance separately, which is a
different instrument again.

### What is not changed, and why

No engine file changes here. The structure this points to -- the existing
allpass chain with feedback added, the level knob driving that feedback, and the
sweep spanning the measured bands -- is a rewrite of the section rather than a
constant, and two of its four inputs are still open: the per-type centre
frequencies have only been read at the tallest peak, and the depth curve is
established only at the top of its range. Shipping the level law alone would put
feedback into a chain whose resonances sit in the wrong places.

The section's own record is corrected instead: the stage count is real, the
level law is feedback, and the depth table that read 131 and 10465 was the probe
measuring itself.

### Reproducing it

```powershell
$reference = "ext/synth1/Synth1/Synth1 VST64.dll"
odin build tools/s1probe -out:build/s1probe.exe

# the control: at depth zero the sweep stops and the peak has a known place
./build/s1probe.exe phaserband $reference --type 6 --ctl1 0 --ctl2 80 --level 127 `
  --seconds 2 --notes 90,93,96,99,101,102,103,105,108,114,120

# how many resonances each type has
./build/s1probe.exe phaserband $reference --type 9 --ctl1 0 --ctl2 80 --level 127 `
  --seconds 2 --notes 33,36,39,42,45,48,51,54,57,60,63

# the level law
./build/s1probe.exe phaserband $reference --type 6 --ctl1 0 --ctl2 80 --level 112 `
  --seconds 2 --notes 48,96,99,100,101,102,103,106,120

# and the depth band, at a rate whose period fits three times into the render
./build/s1probe.exe phaserband $reference --type 6 --ctl1 48 --ctl2 80 --level 127 `
  --seconds 4 --notes 75,78,81,84,87,90,93,96,99,102,105,108,111,114,117,120,123,126
```

### The per-resonance probe (2026-08-25)

The two instruments before this each answered one question and blocked on the
next. The saw comb reads a whole transfer function from one render, which is what
identified the section as resonant rather than notched, but its fundamental is
its floor and above ctl1 32 the resonance leaves it. The held tone has no floor
and found the resonances the comb had missed, which is what showed the count is
the type index, but it reports one number per note, so several resonances
sweeping at once collapse into a single "band" that is only their union.

What was left is the question the structure turns on: where is *each* resonance,
and how does each one move. That needs a whole transfer function **and** time
resolution, which is the pair this document had called irreconcilable -- lower
fundamentals need longer FFTs, and longer FFTs smear a moving corner.

It is reconcilable by moving the third variable. Nothing requires the sweep to
run at a musical rate while it is being measured. Slowed to a period of tens of
seconds, a 341 ms window sees the comb move under two per cent of one cycle: a
static comb, photographed a hundred times across a sweep. The rate law is
independent of depth, which is measured below rather than assumed, so slowing it
changes nothing else about what is read. The window then resolves a 16 Hz
fundamental, and the whole comb is visible at once, from ph4's 65 Hz resonance to
its 7 kHz one.

`phasercomb` is that instrument. Its control is the one place the answer is
already known: ph1 at ctl1 = 0 returns **exactly one resonance in 116 of 116
frames, at 2770.8 to 2771.7 Hz**, a span of 0.00 octaves.

### The combs, counted and placed

```
  ph1   2771
  ph2    251   3899
  ph3    104    255    605   5457
  ph4     66    147    256    441    932   6613   Hz, ctl1 = 0, level 127
```

One, two, four and six. The held tone had found five of ph4's six and three of
ph3's four -- at three-semitone spacing 441 Hz and 605 Hz fall between the notes
-- so even the corrected count in the section above was low. What is not in doubt
is the direction of the correction: this is a comb whose size grows with the type,
not one shape at four frequencies.

The same runs measure this engine at every setting and find **no resonance in any
frame of any of them**. That is the defect stated exactly: the shipped allpass
chain sums with dry and makes shallow dips, and the reference makes a comb of
resonances 25 dB tall.

### The depth curve

Measured on ph1, where there is a single resonance to follow, at ctl2 = 40 with
renders holding three full cycles:

```
  ctl1        0      8     16     24     32     48     64     80     96    112    127
  low      2771   2782   2827   2829   2829   2909   3024   3026   2680   2321   2011  Hz
  high     2772   6432   6881   7327   7828   8847  10054  11266  12476  13404  14700  Hz
  span    0.000  1.209  1.284  1.373  1.468  1.605  1.733  1.896  2.219  2.530  2.870  oct
```

> **These spans include a start-up transient** and are superseded by the fit at
> the end of this document. The corner begins at its 2771 Hz rest point and
> slews into the sweep's band, which at low depth takes longer than the whole
> render measured here: the steady-state span at ctl1 16 is 0.376 octaves, not
> the 1.284 above. The centre and the linearity survive; the numbers do not.

Two things in it are structural rather than incidental. The bottom of the sweep
sits at the depth-0 rest point and **stays there** to ctl1 80, so the modulation
is one-sided -- upward from where the corner rests -- and only above that does the
sweep also reach below it. And converted into an allpass coefficient through the
bilinear map, the top of the sweep moves at a nearly constant **0.0045 per step**
from ctl1 8 to 127, which is a linear control on the coefficient rather than on
the frequency; the octave span looks saturating only because frequency is a
saturating function of the coefficient.

### Two instrument errors, both now caught by the instrument

**A render shorter than one cycle reports where the recording stopped.** At
ctl2 = 16 the first depth sweep read 0.79 octaves for ctl1 16, against 1.284
measured over three cycles: the trajectory was still rising when the render
ended. The probe now counts the turning points of the lowest resonance's own
trajectory and refuses to present a span as anything but a lower bound when it
sees fewer than two, which is what it does at ctl1 1, 2 and 4.

**An analysis ceiling reads as a sweep's top.** With the ceiling at 13 kHz the
deepest sweeps returned 12559 and 12672 Hz and fourteen frames of the deepest
returned nothing at all. Raised to 20 kHz, the same settings read 12559 -- real --
and 15061 -- not. This is the identical mistake as the 131 Hz and 10465 Hz of the
original depth table, made again, one instrument later, and caught only because
the number sat suspiciously close to a limit that had just been chosen.

### What the trajectory does that a single LFO does not

The sweep's shape is where this stops rather than concludes.

At ctl2 = 40, holding ctl1 at 16, 64 and 127, the trajectory turns around every
**5.6, 5.7 and 5.6 seconds** and the turning points land at the same times to
within a few tenths, so the rate is independent of depth and the phase is
reproducible across renders. Both confirm what this section already recorded.

But at ctl1 4, at that same rate, the trajectory **rises monotonically for the
whole twenty seconds** and never turns at all, and at ctl1 16 it makes one large
rise to 6819 Hz over nine seconds before settling into much smaller oscillations
between 5300 and 6700 Hz. A single triangle sweeping a corner does neither. There
is a slow component and a fast one, their balance moves with depth, and the depth
table above is a measurement of the pair rather than of one law.

That is the next reading, and it is now a reading rather than a guess: the
trajectory is recorded frame by frame in the probe's CSV, so whatever this is can
be fitted rather than inferred from extremes.

### Reproducing it

```powershell
$reference = "ext/synth1/Synth1/Synth1 VST64.dll"
odin build tools/s1probe -out:build/s1probe.exe

# the control: one resonance, in a known place, in every frame
./build/s1probe.exe phasercomb $reference --type 6 --ctl1 0 --ctl2 16 --seconds 3

# the comb each type makes
./build/s1probe.exe phasercomb $reference --type 9 --ctl1 0 --ctl2 16 --seconds 3

# the depth curve, at a rate whose period fits three times into the render
./build/s1probe.exe phasercomb $reference --type 6 --ctl1 64 --ctl2 40 `
  --seconds 20 --csv build/comb-c64.csv

# and the trajectory itself, frame by frame
./build/s1probe.exe phasercomb $reference --type 6 --ctl1 16 --ctl2 40 `
  --seconds 20 --show
```

### The trajectory, fitted (2026-08-25)

The per-resonance probe left the sweep's shape open, with the observation that a
single triangle explains neither the monotone twenty-second rise at ctl1 4 nor
the large first excursion followed by much smaller oscillations at ctl1 16. Both
turned out to be the same thing, and it is not part of the waveform at all.

### The rise is a start-up transient, and it happens once

A sixty-second render settles it. The climb from the rest point happens **once**,
between 0 and 9 seconds, and never recurs: for the remaining fifty seconds the
corner oscillates steadily between 5281 and 6854 Hz with a period of 5.63 s, and
every later maximum lands within 30 Hz of the first one.

So every span reported before this -- including the depth table in the section
above -- measured the transient and the sweep together. The steady state is a
different and much smaller number: 0.376 octaves at ctl1 16, against the 1.284
that table gives.

### What the sweep actually is

Measured after the transient has passed, at ctl2 40:

```
  ctl1        8     16     32     48     64     96    127
  low      5642   5281   4626   4009   3500   2712   2011  Hz
  high     6455   6852   7827   8849  10056  12595  14895  Hz
  span    0.194  0.376  0.759  1.142  1.523  2.215  2.889  octaves
  centre   6035   6016   6018   5956   5933   5844   5473  Hz
```

Two readings, and they are the whole law. The **centre is fixed** -- 6035 down to
5933 Hz over a sixteenfold change in depth, and only at the very top of the knob
does it fall away as the sweep runs out of room. And the **span is linear in the
knob**, at 0.0231 octaves per step through the origin, which puts every point
within 0.05 octaves of the fit.

That is not where the corner sits when the sweep is switched off. At ctl1 = 0 it
parks at **2771 Hz**, an octave and an eighth below the centre it sweeps around
the moment the knob leaves zero. The two are separate facts about the same
control and the earlier readings had merged them.

### The domain the sweep is linear in

Straightness of each limb, as a percentage of its own range, over nine limbs at
each depth:

```
  ctl1               32     64     96    127
  log frequency     3.7    2.7    3.7    5.0  %
  allpass coefficient 4.3  5.8    8.0    8.6  %
```

Log frequency wins at every depth and by more as the excursion grows, which is
the direction that decides it: two domains agree where the excursion is small and
separate where it is large. So the modulation is a triangle in **octaves**, and
the sweep is `centre * 2^(span/2 * triangle(t))`.

### The prediction that confirms it

If the corner is a ramp, its slope is the same whether it is sweeping or catching
up. The transient's length is then not a free parameter: it is how far the corner
has to travel from 2771 Hz to reach the band, divided by the sweep's own rate,
both of which are already measured. Nothing is fitted here.

```
  ctl1        8     16     32     48     64     96    127
  predicted 14.9    7.0    2.7    1.3    0.6   none   none  s
  observed  14.2    6.3    2.6    1.2    0.5   none   none  s
```

Every one, across a twenty-fivefold range, and the two settings where the band
already contains the rest point correctly show no transient at all: the
prediction goes negative at ctl1 96 and 127 and the corner is in the band from
the first frame. The transient is not a separate mechanism. It is the same ramp,
starting from somewhere it does not normally start.

That also names the implementation: the corner is slewed toward a target at a
fixed rate rather than assigned from a waveform, which is what makes a triangle
out of a square and what makes the first excursion from an unusual starting point
take longer than a limb.

### The rate law holds where it had been extrapolated

The 5.63 s period measured here is at ctl2 40, inside the range the rate law had
only extrapolated across -- it was measured from 48 to 112 and the probe of the
day reported "no period resolvable" below that. The law predicts 5.34 s. That is
5 % out, on an extrapolation of nearly two octaves of rate, and it is the first
direct reading below ctl2 48.

### Where this leaves the rewrite

Of the four inputs the rewrite needs, three are now measured:

- **the structure** -- an allpass chain with feedback, one resonance per stage,
  1, 2, 4 and 6 for ph1 to ph4
- **the feedback**, which is what parameter 81 sets: `0.9491 * (level/127)^3.84`,
  every point within 0.05 dB
- **the trajectory**: a triangle in octaves, centre fixed, span `0.0231 * ctl1`
  octaves, rate from the existing law, slewed rather than assigned, and parked at
  2771 Hz when the depth is zero

The fourth is the other three types' sweep, and taking the same reading for them
found a limitation in this probe rather than an answer. Rank is a stable identity
only while the number of resonances is stable, and it is not: sweeping ph3 the
count runs from 4 to more than 12 across a cycle, ph4 from 5 to more than 12, ph2
from 2 to 9. The comb's *spacing* changes with the corner, so resonances arrive
in and leave the analysed range as it sweeps, and a summary keyed on rank then
averages different resonances together -- which is exactly what it did, reporting
eleven tracks for a type that has four.

Tracking by continuity rather than by rank is the fix, and it is a change to the
summary rather than to the measurement: the per-frame positions are already in
the CSV.

There is also a reason to think the fourth input may not be a free parameter at
all. If the structure is one allpass chain with feedback, there is a single
corner, and the resonance positions follow from it and from the stage count. Then
ph2's tallest resonance sitting at 3899 Hz where ph1's sits at 2771 is a
consequence of chain length, not a second centre to measure, and the trajectory
fitted here is the trajectory for all four. That is a prediction the continuity
tracker can test directly: one corner law should reproduce every type's comb.

> The tracker was built and it answers this: **no**. The low resonances of ph2,
> ph3 and ph4 sweep 3.10, 3.25 and 3.19 octaves where ph1's single resonance
> sweeps 1.73, all at the same depth and driven by the same corner. A comb that
> merely scaled with its corner would give every member the same octave span. See
> the next section.

### The continuity tracker (2026-08-25)

Rank is a stable identity only while the number of resonances is stable, and the
previous section showed it is not. `comb_track` follows resonances frame to frame
instead: greedy nearest-neighbour in log frequency, closest pair first so a clear
match is never displaced by an ambiguous one, one peak to one track.

Its controls are the two places the answer is known, and it passes both exactly.
Static ph1 returns one track across every frame; static ph3 returns **four**
tracks, each present in all 32 frames, at 103.6, 254.4, 605.4 and 5457 Hz --
which is the rank summary, because with a stable count the two must agree.

### Three things it took to work, and one that had to be undone

**The peak cap was throwing frames away.** It was set to twelve on the reasoning
that a four-stage chain cannot make more, which is true standing still and false
while sweeping: the comb's spacing changes with its corner, so as the sweep runs
low more of the comb falls inside the analysed band. ph4 reaches more than twelve
in nearly two frames in five, every one of which was discarded whole -- and a
discarded frame matches no track, so every track died at the same instants. That
alone accounted for most of the fragmentation. Raised to forty, with a full frame
now keeping what it found and saying it was full.

**The jump tolerance was guessed, and the guess was wrong.** It had been derived
from the corner's own speed, 0.18 octaves per frame at the fastest sweep. But the
members of a comb do not move at the corner's rate -- the spacing changes, so the
outer ones move faster. Measured over the renders themselves, the step between
frames has a median of 0.10 to 0.14 octaves and a 99th percentile of 0.35 to
0.60, so a 0.35 tolerance was rejecting a few per cent of legitimate steps. Every
rejection starts a new track, which is why a few per cent of bad steps produced
hundreds of fragments.

Two changes rather than a larger tolerance, because the spacing between
neighbouring resonances is only about 0.8 octaves and there is not much room. The
hop is a quarter of the window instead of a half, which costs only arithmetic and
halves every step; and a track is matched against where its own velocity says it
will be rather than where it was, so a resonance moving steadily is followed
however fast it goes.

**Coasting through gaps was tried and reverted.** Carrying a track through a gap
on its last velocity reconnected fragments, and some of what it reconnected was
wrong: ph3 came back with a track running 168 Hz to 13294 Hz, a span of 6.3
octaves, which is two resonances joined across a gap where a third had passed
between them. A broken track is a visible fragment and an honest one; a track
joined to the wrong resonance is a measurement that looks fine and is not. The
gap is six frames, half a second, and tracks break rather than guess.

### What it can and cannot follow

```
                       longest track   tracks agreeing on that span
  ph1, swept            465 / 465      1
  ph2, low resonance     86 / 465      6, spanning 402-3540 Hz
  ph3, low resonance    132 / 465      4, spanning 168-1612 Hz
  ph4, low resonance    171 / 465      3, spanning 113-1024 Hz
```

ph1 is followed perfectly, which is the case the trajectory was fitted on. The
others still break, and the reason is now visible rather than mysterious: their
resonances genuinely merge, cross and leave the band as the spacing changes, and
no amount of tolerance separates two peaks that have become one. What the
fragments do is agree -- six independent fragments of ph2's low resonance return
the same 3.10 octaves to within 0.05 -- so the span is measured even where a
single unbroken track is not available.

### And a finding, from the spans it does return

```
  ph1 single resonance   1.73 octaves
  ph2 low resonance      3.10
  ph3 low resonance      3.25
  ph4 low resonance      3.19
```

All at ctl1 64, all driven by the same corner. **The resonances do not all move by
the same amount in log frequency.** A comb that simply scaled with its corner
would give every member the same octave span, and the lower members move roughly
twice as far as ph1's single one.

That is a constraint on the structure rather than an answer, and it is the first
one measured. It rules out the simplest reading of "one corner scales the whole
comb", and it says the fourth input the rewrite needs cannot be assumed from
ph1's trajectory after all: whatever maps corner to comb has to reproduce these
four spans as well as the four static combs.

> **Half of this is wrong**, and the next section says which half. Those spans
> were measured over whole renders, so they include the start-up transient, and
> over broken tracks. Measured in steady state, ph2, ph3 and ph4 agree with each
> other to within two per cent and do share one corner law. ph1 is genuinely the
> odd one, at about half their sweep. The comb does scale rigidly after all.

### The corner-to-comb map (2026-08-25)

The previous section closed with a constraint: whatever maps corner to comb has
to reproduce four static combs and four swept spans. Fitting it needs no
knowledge of the corner at all, because the combs supply their own reference.

### The comb scales rigidly

If one corner drives a chain, every resonance is a function of that single
parameter, so the ratios between them are fixed and the whole comb slides as a
unit. Measured across a sweep, using only frames where the comb is intact -- the
count equal to the type's own, so position and identity agree:

```
  spread of each resonance's ratio to the lowest, over a sweep
  ph3, all below  7 kHz,  57 frames, 0.71 oct of sweep    1.8%  1.6%  6.8%
  ph3, all below 10 kHz, 145 frames, 1.84 oct             1.4%  1.4% 16.8%
  ph4, all below 10 kHz,  87 frames, 1.35 oct             2.4%  2.3%  2.2%  2.3% 11.3%
```

The inner resonances hold their ratios to within a couple of per cent while the
corner moves more than an octave. The comb is rigid.

The outermost one is the exception, and it is an artefact rather than a finding:
its spread falls from 24.5 to 16.8 to 6.8 per cent as the analysis is restricted
to lower and lower frames. A structural departure does not shrink when you look
at a smaller part of the range; a resonance leaving the top of the analysed band
does exactly that.

### It is not a uniform chain

A chain of N identical allpass sections with feedback puts its resonances where
the accumulated phase crosses a multiple of pi, at
`tan(theta_k)/tan(theta_0)` with `theta_k = 90(2k+1)/N` degrees. That family is a
one-parameter fit against each measured comb, and it fails:

```
  ph2, 2 resonances    best N =  3.2   worst error   1.0%
  ph3, 4 resonances    best N =  8.1   worst error  39.5%
  ph4, 6 resonances    best N = 12.6   worst error  54.6%
```

ph2 fits because two points and one parameter always will. ph3 and ph4 do not fit
at all, so the sections are **staggered** -- at different corner frequencies --
rather than identical. That is what an analogue phaser does, and it is why the
comb's spacing is uneven.

### The map, then, is the ratios themselves

With the comb rigid and the sections staggered, the map has no closed form to
recover: it is a fixed set of ratios per type, and those are read directly off
the static comb, where nothing is moving and the measurement is exact.

```
  ph1   1
  ph2   1   15.53
  ph3   1    2.452    5.817   52.47
  ph4   1    2.227    3.879    6.682   14.12   100.2
```

### The corner's own sweep, and one type that does not share it

The remaining question is how far the corner moves per step of depth. Taking the
lowest resonance of each type as the reference -- it sits low enough that
frequency and the analogue prototype agree there, so no warping enters:

```
  span of the lowest resonance, steady state, octaves
  ctl1     ph1      ph2      ph3      ph4
     8    0.194    0.392    0.399    0.411
    24    0.554    1.180    1.212    1.203
    48    1.142    2.362    2.417    2.436
  per step 0.0238   0.0491   0.0503   0.0508
```

**ph2, ph3 and ph4 share one law**, 0.050 octaves per step, agreeing with each
other to within two per cent at every depth. That is the answer to the question
the tracker raised: their sweeps do follow a single corner law, and the earlier
suggestion that they did not came from spans measured through the start-up
transient and through broken tracks.

**ph1 does not.** It sweeps 0.0238 octaves per step, close to half, at every one
of five depths. Converting to the analogue prototype, where its resonance sits
high enough for the warping to matter, narrows the gap but does not close it:
1.281 octaves against 2.438 at ctl1 48, a factor of 1.90.

That is left as measured rather than explained. It is a clean, repeatable factor
of about two between one type and the other three, and the obvious readings --
that ph1's single section is modulated half as hard, or that its resonance is not
where the others' reference is -- are not distinguishable from four combs.

### What the rewrite now has

```
  structure     an allpass chain with feedback, sections staggered, one
                resonance per section pair: 1, 2, 4 and 6 for ph1 to ph4
  feedback      parameter 81:  0.9491 * (level/127)^3.84, within 0.05 dB
                -- SUPERSEDED: derived from peak = 1/(1-g), which the fitted
                topology rules out. See the last section.
  comb          rigid, at the measured ratios above
  corner        centre fixed per type; span 0.050 octaves per depth step for
                ph2 to ph4 and 0.0238 for ph1; triangle in octaves; slewed
                rather than assigned; parked at the rest point at depth zero
  rate          the existing law, now confirmed at ctl2 40 to within 5%
```

Every input the rewrite needs is measured. What remains before writing it is the
one thing measurement cannot supply: a topology that produces staggered sections
in these particular ratios, which is a design decision to be gated against the
combs above rather than a further reading.

### The topology, fitted -- and a level law that has to be re-derived (2026-08-25)

The rewrite needed one thing measurement cannot supply: a circuit. No probe says
what produced a response, only what the response is. So it was fitted, against
the measured magnitude curve rather than against the resonance positions, and
`tools/phaserfit.py` holds the method.

Fitting against positions was tried first and is hopeless: three quite different
section layouts reproduced ph4's six resonances to within 5 % of each other while
giving different responses between them. Positions leave the corners wildly
underdetermined. The curve does not.

### What the curve rules out

**A pure feedback loop cannot notch deep enough.** `x/(1 - g*A)` has its minimum
where `A = -1`, at `1/(1+g)`, which is -6 dB even as g approaches one. The
reference notches **-12.15 dB** at 262 Hz. Fitting that form over two signs and
two to six sections bottoms out at 6.13 dB of error, and the residual sits almost
entirely at the notch. So a dry path is summed with the wet one.

**The response rises toward DC**, +6.04 dB at 16 Hz and still climbing where the
notch above it is -12.15, which is a resonance at zero frequency. That is what
distinguishes positive feedback from negative, which would put a minimum there.
It is also why the resonance count came out at 1, 2, 4 and 6 rather than one
more: a peak at DC is not visible to a probe that sweeps a tone.

### What it leaves

```
  v   = x + g * A(v)
  out = d * x + w * A(v)
```

with A a chain of staggered first-order allpass sections. For ph1, over the
twenty-five measured points from 16 Hz to 8.4 kHz:

```
  3 sections at 73.5, 1077 and 6735 Hz     g = 0.9469   d = 0.897   w = 1.131
  worst error 2.21 dB
```

and that worst error is almost entirely a constant offset: the residual runs
+1.5 to +2.2 dB across nineteen of the twenty-five points, so the *shape* is
matched to within about half a decibel and the model is a gain trim away.

The check that it is not merely a curve with enough freedom: **the fit recovers
the feedback**. It was given no knowledge of the level law and returned
`g = 0.9469` against the `0.9491` measured independently from six settings of the
level knob -- 0.2 % apart.

### And the finding that stops the rewrite here

That agreement is also the problem. The level law was derived from
`peak = 1/(1-g)`, which is the pure feedback loop -- the form the notch depth has
just ruled out. Under the fitted topology the peak is `d + w/(1-g)`, and the two
disagree:

```
  level                96      104      112      118      122      127
  g from 1/(1-g)   0.3200   0.4422   0.5870   0.7156   0.8129   0.9490
  g from d+w/(1-g) -0.3322  0.0793   0.4255   0.6529   0.7911   0.9491
```

They agree at the top of the knob, where the feedback dominates and the dry path
is negligible, which is why the fit reproduced the number: 127 is the setting the
law was anchored on. They diverge everywhere else, to the point of returning a
negative feedback at level 96. So `0.9491 * (level/127)^3.84` is an artefact of
the wrong model over most of its range, and the exponent fitted through those
points is not a real number about the plugin.

This is recorded rather than patched because the repair is a measurement, not
arithmetic: `d` and `w` are themselves functions of the level knob -- at level 0
the response is flat at about -2.5 dB, which is `d` alone with the wet path shut
off -- so the law has three unknowns per setting where it was fitted with one.
The level sweep already on record supplies the data; it needs re-fitting under
this form.

### Where the rewrite stands

It is not written, and writing it now would ship a phaser whose level knob is
wrong over three quarters of its travel. What is settled is the shape of the
thing:

```
  topology     d*x + w*A(v), v = x + g*A(v), staggered first-order sections
               -- fitted, and cross-validated by recovering the feedback
  ph1          3 sections at 0.0265, 0.3887 and 2.4306 of the corner
  comb         rigid, at the measured ratios
  trajectory   triangle in octaves, centre fixed, span 0.050 per depth step for
               ph2 to ph4 and 0.0238 for ph1, slewed, parked at rest at depth 0
  rate         the existing law
```

What is not: the level law, which needs re-deriving in `d`, `w` and `g` together;
and the section layout for ph2 to ph4, whose curves are sampled at three
semitones and fit to only 7.18 dB, with corners at 0.01 Hz that are plainly the
optimiser exploiting gaps in the data rather than a circuit. Both are measurement
problems with a known instrument, which is a better place to be than the guess
this would otherwise have been.

### The level law, re-derived (2026-08-25)

The previous section retired `0.9491 * (level/127)^3.84` as an artefact of the
wrong model. This is the replacement, measured under the fitted topology.

### A denser instrument, for nothing

The curves it is fitted to are the whole transfer function rather than a handful
of held tones, and they come from renders that were already being made. The saw
comb computes the transfer at every harmonic of its fundamental; `phasercomb`
was picking peaks out of it and discarding the rest. `--curve` writes it out:
**1223 points from 16 Hz to 20 kHz, from one render**, against the twenty-five a
tone sweep took several minutes to produce.

The two agree to **0.2 dB at every frequency they share** -- 131 Hz reads -10.11
against -10.11, the peak 25.80 against 25.85, 8372 Hz -0.71 against -0.71. Two
instruments with nothing in common but the plugin.

### Three parameters, not one

With ph1's sections held fixed -- the knob does not move frequencies -- and `d`,
`w` and `g` fitted independently at each of twelve settings:

```
  level      0     16     32     48     64     80     96    104    112    118    122    127
  g       0.000  0.000  0.000  0.000  0.000  0.000  0.059  0.211  0.401  0.578  0.718  0.917
  d       0.837  0.818  0.795  0.770  0.736  0.749  0.777  0.800  0.828  0.853  0.872  0.899
  w      ~0     ~0     0.082  0.365  0.697  0.637  0.658  0.752  0.876  0.998  1.096  1.239
```

**The feedback is exactly zero over two thirds of the knob.** It does not engage
until about level 87 and then climbs steeply:

```
  g = 0.917 * ((level - 87)/40)^1.76      worst deviation 0.0079 over six settings
  g = 0                                    below level 87
```

What the knob does below that is mix. `w` rises from nothing to about 0.7 by
level 64 while `d` holds near 0.81 -- so the lower two thirds is a dry/wet
crossfade and the top third adds resonance on top of it. That is a normal design
for a phaser and it is what the manual's "the amount of the effect, or the
balance with the original sound" says, with both halves of the "or" true at once
in different parts of the travel.

`d` near 0.81 is also directly checkable: at level 0 the wet path is shut and the
response should be flat at `20 log10(d)` = -1.8 dB. The measurement reads -1.53 dB
at 131 Hz.

### How wrong the old law was

```
  level                   96      104      112      118      122      127
  measured g           0.059    0.211    0.401    0.578    0.718    0.917
  0.9491*(L/127)^3.84  0.320    0.442    0.587    0.716    0.813    0.949
```

It agrees only at the top, which is the anchor it was fitted through, and it is
wrong by a factor of five at level 96 -- and it claimed a feedback of 0.32 at 96
and 0.07 at 64 where there is none at all. The exponent 3.84 was never a number
about the plugin.

### The section fits, and where they stop

```
                sections   rms     worst
  ph1              3      1.93 dB  5.01 dB
  ph2              5      1.97     5.16
  ph3              7-8    4.02    16.46
  ph4              9-12   5.35    25.65
```

ph1 and ph2 fit; ph3 and ph4 do not, and the honest reading is that this does not
yet distinguish two possibilities. With eight to twelve free corners plus three
mixing parameters, a random-walk optimiser in pure Python may simply be failing
to converge -- one ph3 run left a corner at 5e18 Hz, which is a section the
optimiser had switched off rather than placed. Or the single-loop form is wrong
for the longer chains and they nest their feedback.

Distinguishing those needs a better optimiser rather than more measurement, which
is worth saying plainly: the data is dense, matched and cross-validated, and it is
the fitting that is short. ph1 and ph2 are ready to implement; ph3 and ph4 are
not.

> It was the search. Levenberg-Marquardt takes ph3 to 2.07 dB and ph4 to 2.43,
> and finds the sections are coincident rather than staggered -- which collapses
> the whole model to five numbers. See the next section.

### The circuit, identified (2026-08-25)

The random walk had left ph3 and ph4 unfinished at 3.87 and 5.35 dB rms, with the
honest caveat that this did not distinguish a wrong model from a failed search.
It was a failed search. Levenberg-Marquardt, written out in
`tools/phaserfit.py` because there is no numpy here, takes the same data and the
same model to **2.07 and 2.43 dB** -- level with ph1 and ph2.

Two details in it earn their place. `g` is carried as a logistic so the search
cannot walk it past one, where the loop stops converging and the cost function
goes meaningless rather than merely large. And the Jacobian's corner columns
reuse the phase already computed, subtracting one section's arctangent and adding
the perturbed one, which is what makes a thirty-parameter fit tractable in plain
Python.

### What it converged on

Freed, LM did not produce the staggered corners the earlier fitting had assumed.
It produced **coincident** ones -- seven identical values at 249.58 Hz for ph3,
twelve at 255.3 Hz for ph4 -- which is a cascade of identical sections, and a
standard phaser topology rather than an exotic one.

That is a much smaller model, and constraining the fit to it collapses thirty-odd
parameters to five with no meaningful loss:

```
  corner        254.80 Hz     the sections, all at one frequency
  high section 14740.2 Hz     one more, shared by every type
  g              0.9630       feedback
  d              0.5138       dry
  w              0.5266       wet

  ph1   2 sections   rms 2.05 dB   worst 5.69 dB
  ph2   4            rms 1.96      worst 5.44
  ph3   8            rms 2.07      worst 4.87
  ph4  12            rms 2.43      worst 7.02
                     joint rms 2.133 dB
```

**Five numbers and a section count reproduce four measured curves.** The section
count is 2, 4, 8 and 12, and it is not fitted freely: it is what the free fits
converged on, and it independently predicts the resonance counts. A chain of N
first-order sections accumulates 180N degrees, and with positive feedback a
resonance falls wherever the phase passes a multiple of 360 -- so N of 2, 4, 8
and 12 gives 1, 2, 4 and 6 resonances above DC, which is exactly what the comb
probe counted.

The mixing numbers are also a check rather than three free dials. `d` and `w` are
each about 0.52, and the four types were fitted individually before they were
fitted together: their separate answers agreed at g around 0.96, d around 0.52
and w around 0.53 before anything forced them to. A joint fit from random starts
did *not* find this -- it stalled at 4.83 dB -- and only converged when seeded
from the individual solutions, which is worth recording as the reason the search
needed steering rather than more iterations.

### Where the corner sits

254.80 Hz is the corner at rest, at ctl1 = 0, and it is the parameter the LFO
sweeps. It is not the resonance: ph1's single resonance sits at 2771 Hz, which is
where two sections at 255 Hz have turned the phase through 360 degrees. That
distinction is why the swept-band measurements and the static comb measurements
looked like they disagreed for so long -- they were measuring different things,
one the corner and one what the corner produces.

### The rewrite's inputs, complete

```
  structure    N first-order allpass sections at one corner, plus one at
               14.7 kHz, positive feedback, out = d*x + w*A(v), v = x + g*A(v)
  sections     2, 4, 8, 12 for ph1 to ph4
  level        g = 0.917*((level-87)/40)^1.76 above the threshold and zero below;
               d near 0.81 throughout; w rising from zero to about 1.24
  corner       rest 254.8 Hz; triangle in octaves; span 0.050 octaves per depth
               step for ph2 to ph4 and 0.0238 for ph1; slewed, not assigned
  rate         the existing law, confirmed at ctl2 40 to within 5%
```

> Both of these were superseded within the hour by one missing term -- the
> feedback's one-sample delay -- which took the joint fit from 2.133 dB to
> 0.153 and removed the high section entirely. See "The rewrite" at the end.

One inconsistency is left standing rather than smoothed: the level fit put `d`
near 0.81 and `w` up to 1.24 at level 127, while the circuit fit puts them at
0.51 and 0.53. Both reproduce their own data. They differ because the level fit
held ph1's *staggered* corners fixed -- the ones LM has now superseded -- so its
`d` and `w` absorbed the difference between two chains. The level law's shape is
unaffected, since the threshold and the zero below it come from `g`, but the two
mixing numbers need one more pass with the corners that are now known.

### The rewrite (2026-08-27)

Written, and gated. The circuit is smaller than any of the three guesses that
preceded it:

```
  v   = x + g * z^-1 * A(v)        A = N identical allpass sections at 254.61 Hz
  out = 0.5 * (x + A(v))           N = 2, 4, 8, 12 for ph1 to ph4
```

That is a textbook phaser. The sections are coincident, not staggered; there is
no second filter anywhere; and the output is a plain half-and-half sum.

### The one sample that mattered

The previous fit sat at 2.13 dB rms and could not do better, and the reason was a
term nobody had written down: **the feedback carries one sample of delay**. Any
realisable loop does -- the reference's included -- and modelling the loop without
it puts every resonance too high, ph1's by a quarter.

Putting `z^-1` in the loop and refitting took the joint error from 2.133 dB to
**0.153 dB rms, 0.74 dB worst**, across all four types at once. It also removed
the extra high-frequency section the earlier fits had needed: that section had
been standing in for the delay's own phase, and once the delay is present it
fits at 35 kHz, which is to say nowhere.

So five numbers became three, and two of those are a half:

```
  corner   254.61 Hz      the sections, all at one frequency
  g        0.9747         feedback at level 127
  d, w     0.4983, 0.4979 -- a plain sum, to three decimal places
```

### Parameter 81, a third time

Re-fitting the level knob under the corrected circuit gave a law simple enough to
be obviously deliberate. Below the knob's midpoint the feedback is zero and the
control is a crossfade from dry to that half-and-half sum. Above it the mix stops
moving entirely and the feedback rises in a **straight line**:

```
  level      80      96     104     112     118     122     127
  measured  0.2505  0.4977  0.6209  0.7439  0.8361  0.8977  0.9747
  the law   0.2510  0.4985  0.6217  0.7447  0.8367  0.8981  0.9747
```

Worst deviation 0.0008 over seven settings, and `d` and `w` sit at 0.4983 and
0.4977 at every one of them. This is the third law recorded for this control. The
first, `L/127` as an output gain, came from generalising the distortions'. The
second, `0.9491*(level/127)^3.84`, came from assuming the peak is `1/(1-g)`. Both
were fitted to a structure that was wrong; this one is fitted to a structure that
predicts thirteen resonances it was not shown.

### What it does against the reference

The comb, which is the check the whole rewrite rests on:

```
             reference        this engine
  ph1        2770.8 Hz        2771.0 Hz
  ph4          66.0             66.0
              147.1            147.1
              255.6            255.6
              440.8            440.8
              931.6            931.6
             6612.4           6612.4
```

Every resonance, to a fraction of a hertz, from one corner frequency and a
section count.

And the direct A/B, over four operating points and all four types -- sixteen rows,
spectral error in dB:

```
                        before    after
  mean spectral         17.97      4.19
  mean level             4.65      1.74
  mean envelope          9.00      5.01
```

At ctl1 = 0, where the sweep is stopped, the four types now read 0.00, 0.01, 0.06
and 0.64 dB of spectral error against 0.00, 0.59, 2.21 and 4.26, with level error
under a tenth of a decibel where it had been up to +10.95.

One row is worse: ph1 at ctl1 127, ctl2 96 goes from 11.94 to 13.38 dB. Every
other row improves, several of them by more than twenty decibels -- ph2, ph3 and
ph4 at that same setting go from 32.73, 43.48 and 48.64 to 1.88, 1.99 and 1.30.

The factory bank is untouched and has to be: no patch in it switches this unit on.

### What is still approximate

The sweep. The corner's trajectory -- triangle in octaves, centre fixed, span
0.050 octaves per depth step, slewed rather than assigned -- is measured and
implemented, but it is measured through the resonances rather than on the corner
itself, and the two are related by an arctangent that saturates. That is why the
deeper sweeps still show several decibels of spectral error where the static
settings show hundredths. The static response is now essentially exact; the moving
one is not, and the remaining error is concentrated there.

### The remaining error, located (2026-08-27)

The rewrite left the sweep approximate and said the error was concentrated there.
Checking it found two things: one measurement that can now be done exactly, and
one defect that is this engine's own.

### The corner can now be read directly

The trajectory had been measured *through* the resonances, because until the
circuit was identified there was no way to convert one into the other. There is
now. Inverting the loop's phase equation on the reference's own steady-state
bands gives the corner itself, and it is a much better-behaved quantity:

```
  ctl1    resonance band        corner band          span    per step
     8    5642..  6455 Hz    1103.. 1468 Hz      0.413 oct    0.0516
    16    5281..  6852       959.. 1670          0.800        0.0500
    32    4626..  7827       728.. 2234          1.619        0.0506
    48    4037..  8849       549.. 2940          2.421        0.0504
    64    3500.. 10056       410.. 3944          3.267        0.0510
    96    2713.. 12595       244.. 6746          4.789        0.0499
   127    2011.. 14895       133..10137          6.249        0.0492
```

The span law survives intact -- 0.0504 octaves per step, against the 0.050 already
implemented. The **centre does not**: the corner sweeps about 1271 Hz, not the
1187 that came from treating the resonance as the corner. The seven depths give
1272, 1266, 1275, 1271, 1271, 1283 and 1162 Hz, and the constant is corrected to
the measurement.

Two checks on the inversion itself. It returns 254.74 Hz for the resonance the
engine sits at when the corner is 254.61, which is the round trip. And the
per-step figure it produces is constant across a sixteenfold change in depth,
which the old reading was not -- that reading had ph1 sweeping half as far as the
other types, and this is what the difference was.

### And a defect that is ours

Sweeping ph1 at full level, our resonance and the reference's do not match, and
the summary hides how:

```
                strongest peak, after the transient
  reference     3500 .. 10055 Hz   1.52 octaves
  this engine     51 ..  8143 Hz   7.31 octaves
```

The 51 Hz is not a resonance. Two sections and a sample of delay cannot put one
there: at 51 Hz the loop's phase is about nine degrees, and it needs 360. It is a
spurious peak, and looking at the frames it appears in says what it is:

```
     7168 ms                7718 Hz (+4.7)
     7253 ms                7915   (+4.7)
     7339 ms    51.3 (+12.5)  8226   (+5.2)
     7424 ms    51.6 (+13.0)  8423   (+5.4)
     7509 ms    51.9 (+13.4)  8732   (+5.7)
     7595 ms    52.0 (+13.7)  9043   (+6.9)
```

It arrives only when the real resonance climbs past about 8 kHz, it tracks that
resonance as it moves, and **it grows** -- 12.5 to 14.2 dB over six frames. A
filter feature does not grow. That is energy accumulating in the feedback loop.

It is bounded and its conditions are exact. It appears only above about 0.9 of
feedback -- at level 96 and 112, where the law gives 0.495 and 0.743, every frame
of the same sweep has exactly one resonance -- and only while the corner is
moving: the static response at full level is a single resonance at 2771.1 Hz
against the reference's 2770.8, in all sixty-seven frames. The reference, at the
same full feedback and the same sweep, has one peak in 227 of 231 frames and none
below 200 Hz.

The mechanism is not settled. The obvious reading -- that a direct-form allpass is
not passive while its coefficient moves, so a loop with two and a half per cent
of margin can gain -- fits the feedback threshold and the fact that it is worst
where the phase near DC is flattest. It does not fit the rate: the artefact is
just as present at ctl2 8, where the corner moves 4.6e-6 octaves per sample, as
at ctl2 64.

> **Neither reading was right, and the rate is why.** It is not modulation at
> all: pinning the corner high and still reproduces it in every frame. It is the
> master limiter, whose knee sat at full scale while the phaser's DC resonance
> legitimately reaches +21 dB. See the last section.

### What that costs, and why the correction still stands

Correcting the centre to the measured 1271 Hz moves the sixteen-row A/B mean from
4.19 to 4.54 dB, which is worse. It is kept anyway, and the reason is the defect
above: a better-founded trajectory drives the corner higher, and the artefact
scales with the corner. Tuning the centre back to hide that would be fitting one
measurement to cancel a bug in the code rather than fixing either.

The static settings are unaffected and remain essentially exact -- 0.00, 0.01,
0.06 and 0.64 dB across the four types at ctl1 = 0. The whole of the remaining
phaser error is in the sweep, and the largest part of it is this.

### The artefact was the output limiter (2026-08-27)

The spurious 51 Hz peak is not a phaser defect. It is the engine's master limiter,
and the phaser is simply the first thing loud enough to reach it.

### Found by pinning the corner

The artefact only ever appeared while the corner was moving, which pointed at
modulation. It is not. Setting the rest frequency to 3900 Hz temporarily -- so the
corner sits high and **still** -- put the 52.7 Hz peak in every one of sixty-seven
frames. Nothing was sweeping.

At that corner the engine's whole curve is wrong, and wrong in a way that names
the cause. Against the model it was fitted to it runs -5.8 dB at 16 Hz, -14.1 at
33, -28 at 1 kHz, -57 at 3 kHz: a progressive collapse, not a filter. Rendering
the same setting at amp gain 40 instead of 96 brings it back to **within 1.2 dB
everywhere**. Level-dependent, therefore a nonlinearity, and the only one in the
path is `soft_clip` on the master output.

### Why the knee was in the wrong place

A phaser with feedback has a resonance at DC -- the loop's phase is zero there --
whose height is `1/(1-g)`, and at full feedback that is +26 dB. It is not a
modelling artefact: driving the reference at the same setting and reading held
tones from 33 Hz upward,

```
   Hz      33     41     52     65     82    104    131
  ref   +21.15 +19.59 +18.11 +16.39 +14.48 +12.63 +10.70  dB
  ours  +10.21 +10.11  +9.97  +9.79  +9.52  +9.10  +8.42
```

The reference really does put +21 dB at 33 Hz. Ours was flat at +10, which is a
limiter's output, not a filter's.

The note beside `soft_clip` had already said the reference does not limit and had
measured its peaks at +19 and +30 dBFS. The knee was at 1.0 anyway, so anything
above full scale was squashed toward 2. It now sits at **32**, which is those
measured peaks, and the contract it exists for is untouched: an output asymptotic
to 64 is still bounded, which is all "a stack of unison voices summing in phase
must not produce something unbounded" ever required.

### What it fixes

The sweep, which was the whole of the remaining phaser error:

```
                 resonances per frame        strongest peak
  reference      1 in 227 of 231 frames      3024 .. 10055 Hz   1.73 oct
  before         1 in 109, 2 in 120            51 ..  8143      7.31
  after          1 in 231 of 231             3024 ..  9860      1.71
```

Every frame, one resonance, sweeping where the reference sweeps.

Over the sixteen-row A/B the mean spectral error goes from 4.54 to **3.35 dB** and
the mean level error from 1.74 to 1.37. The largest single move is ph1 at ctl1
127, ctl2 96: **13.72 to 1.69 dB**, with its level error going from -4.57 to +0.15.

### What it costs

One factory patch. 123.sy1 goes from 5.9758 to 6.1413 dB of spectral error,
because it was clipping and now is not, and the clipping had been flattering it.
Across all 128 the aggregate moves by **+0.0013 dB** spectral, +0.0042 envelope
and +0.0006 level -- three figures that are, in effect, the one row.

That trade is taken rather than tuned around. The reference's own peaks are
measured at +19 and +30 dBFS, so a knee at full scale was never faithful; keeping
it there to hold one factory row steady would be preferring a number to the
instrument that produced it.

### The remaining error, again (2026-08-27)

With the limiter's knee moved, the phaser's error is no longer spread across the
control range. It is concentrated at one end of one knob.

**Static settings are exact.** At ctl1 = 0 the four types read 0.00, 0.01, 0.06
and 0.64 dB of spectral error.

**Swept settings up to ctl2 112 are close.** Held tones through both engines at
ctl1 64, comparing peak levels note by note:

```
             1760 Hz      2093      2489      2960      3520
  ctl2 64   -3.6/-3.9  -0.7/-1.1  +3.2/+2.8  +9.8/+9.1  +25.4/+25.9
  ctl2 96   -2.7/-4.4  +0.4/-1.7  +4.7/+2.1  +12.3/+8.0 +24.2/+23.4
  ctl2 112  -4.1/-4.8  -1.3/-2.1  +2.5/+1.5  +8.7/+7.2  +24.1/+21.4
```

reference first, this engine second. And the swept band itself, measured with the
comb probe after the start-up transient has passed, at ctl2 40:

```
  reference   3500 .. 10055 Hz   1.52 octaves
  ours        3612 ..  9860      1.45
```

Five per cent narrow, at both ends.

**ctl2 127 is where it goes wrong**, and by a lot: at 2960 Hz the reference reads
+21.39 dB and this engine +5.58. Our sweep does not reach that low, and the
reference's does.

### Why that setting and not its neighbours

The reference's own reading at 2960 Hz across the rate knob is not monotonic --
+9.80, +12.31, +8.74 and then **+21.39** at ctl2 64, 96, 112 and 127. A faster
sweep dwells less at any given frequency, so more energy at the top of the knob is
the opposite of what the rate alone predicts. Something about the sweep changes
there, and its span reaching lower is the reading that fits.

This is also exactly where nothing is measured. The rate law was fitted from
ctl2 48 to 112 and extrapolated past it, and at 127 the two instruments that read
a rate disagree outright -- tracking the resonance's trajectory gives 15.56 Hz and
autocorrelating the spectrogram gives 5.21, against a law that says 18.6. At
ctl2 112, inside the measured range, they agree: 8.53 and 8.52 against 7.81.

So the error sits on top of an extrapolation, in a region where the existing
instruments cannot resolve the thing being extrapolated. Fitting a special case
there would be fitting to the least reliable numbers in the section.

### What is not wrong

ph4 is the worst type in the A/B and its comb is not the reason. Sweeping it and
reading every resonance, each of ours falls inside the reference's own swept
range:

```
                  1        2        3        4         5         6
  reference   114-130  235-289  412-475  721-843  1472-1704  8289-8844
  ours          116      250      428      724      1529       8374
```

The structure tracks. What is left is where the corner goes at the top of the rate
knob, and how fast it goes there.
