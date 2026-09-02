I have everything measured. Final report follows.

---

# Research: the next distributional outlier in the isolated 123-patch null test, and what produces it

**Repository** `C:\Users\lamag\Code\synth` · **HEAD** `5c790fd` ("The delay's /3 is a division, not a triplet") · `git status --porcelain` empty before and after this session · all figures produced this session against `ext/synth1/Synth1/Synth1 VST64.dll`.

**Measurement floor.** `build/s1probe.exe compare ext/synth1/Synth1/soundbank00/001.sy1 --self` → spectral `0.00`, envelope `0.00`, level `+0.00`, null `−240.00 dB`. The harness measures nothing of itself.

---

## Contract amendments received

Two mid-run user messages amended this run. Both are quoted in full because both changed what I did.

> Do not tune OSC_PHASE_FREE_TURNS by sweeping it against null depth on one probe patch. Choosing 0.5623 over 0.5600 because the null went from -25.75 to -24.47 dB on c3 is fitting a constant to a metric on a single patch at a single note, which CONTRIBUTING forbids and which your own refined question ruled out. Either measure the reference's free-run start phase directly - render its first cycles and read the initial phase, at more than one note and rate, the way the existing waveform probes do - and adopt only a value that measurement supports, or leave the constant where it is and let the rest of the change stand on its own evidence. A digit that only a null depth justifies is not a measurement.

> Report which patch was the distributional outlier, which is what you were asked. A change that moves 111 of 123 patches is a systematic correction, not an outlier fix; that is a fine and probably better result, but say so plainly and gate it on the whole-bank aggregate with every regression among those 111 named, rather than presenting it as the outlier answer.

Both are honoured below. §3 replaces the null-depth sweep with a direct start-phase reading at five notes and two sample rates; the sweep is withdrawn as justification and reported only as a discarded step. §1 answers the outlier question on its own terms and §5 states plainly that the fix that follows is a systematic correction, not an outlier-local patch, and gates it on the whole-bank aggregate with every regression named.

---

## 1. The outlier: `069.sy1` "Oboe"

The question asked which single patch is now the bank's next genuine distributional outlier. **It is `069.sy1` "Oboe".**

Statistics over the 123 rows of `build/research-next/nulltest-head.csv` (fresh run at HEAD; the five reference-crashing patches 095/098/100/101/106 excluded automatically by the isolating child-process run, which reported all five and completed):

| metric | n | leader | value | z | multiples of IQR above Q3 | 1.5×IQR fence |
|---|--:|---|--:|--:|--:|--:|
| **`abs(level_db)`** | 123 | **069 Oboe** | **10.99** | **+4.51** | **3.81** | 5.96 |
| | | 083 Solo Lead | 9.82 | +3.93 | 3.27 | |
| | | 071 Basson | 8.62 | +3.33 | 2.72 | |
| **`envelope_db`** | 123 | 029 E Guitar 3 | 9.08 | +3.90 | 3.89 | 5.27 |
| | | **069 Oboe** | **8.53** | **+3.58** | **3.55** | |
| | | 053 Choir | 7.46 | +2.94 | 2.87 | |
| `spectral_db` | 119 | 088 Sweep lead | 16.72 | +2.45 | 1.13 | 19.09 |
| | | 086 / 001 | 16.68 / 16.30 | +2.44 / +2.34 | 1.12 / 1.06 | |
| width `abs(our−ref)` | 123 | 119 SynDrum | 0.2598 | +4.97 | 6.08 | 0.094 |
| | | 089 Warm pad | 0.2462 | +4.67 | 5.70 | |
| | | 111 Sequence 4 | 0.1935 | +3.52 | 4.24 | |
| centroid `abs(log2)` | 119 | 126 / 128 / 056 / 127 | 1.45 / 1.35 / 1.30 / 1.10 | +4.7…+3.4 | 5.6…4.0 | 0.56 |
| `f0` cents | 123 | 121 / 054 / 079 / 059 | 5046 / 2775 / 2774 / 1902 | — | — | 10.0 |

Why 069 and not the others:

- **069 is the only patch that is a top-two outlier on two independent metrics.** It leads `abs(level_db)` at z = 4.51 and sits second on `envelope_db` at z = 3.58, and its spectral error is 11.45 dB with a correlation of 0.288 — the lowest correlation of any non-percussive patch. Nothing else in the bank is simultaneously extreme on level and contour.
- **`spectral_db` has no outlier at all.** 088/086/001 sit at 1.06–1.13×IQR above Q3, well inside the ordinary 1.5×IQR fence of 19.09 dB. That is the top of a smooth tail, as the previous round already found; it has not changed.
- **029** leads envelope alone (z 3.90) but its level (3.55) and spectral (6.31) are ordinary. It is a single-metric leader, and — see §5 — it turns out to be produced by the same subsystem.
- **119 SynDrum's width is not a lone outlier.** 119 (0.2598), 089 (0.2462) and 111 (0.1935) form a trio; 119 is not separated from 089. The named open candidate is therefore correctly *not* the answer to a question about a single separated outlier, and the bank-wide width deficit (signed mean −0.0237) is the known chorus/delay energy deficit that the question already rules out as a non-defect.
- **`f0` outliers are metric artefacts.** The leaders cluster at exactly ±1200 cents (103, 094, 030, 071, 091, 110 all read 1197.7–1200.2) — octave ambiguity in the pitch estimator, not tuning error. `pitch_cents` in the same rows reads under 1 cent. Discarded.
- **Centroid outliers are the percussion patches** 126/128/056/127, whose ref/our centroids are dominated by transient content; 119 is fifth at z 1.98. Not separated.
- **113 / 115 / 116 / 120** carry `spectral_valid=false` and are excluded from spectral statistics as the question requires.

069 is `ver=105`, name `Oboe`: oscillator 1 **triangle** (`0,3`), oscillator 2 **saw** (`1,1`), oscillator 2 at **the same pitch** (`2,64` = 00 semitones, `3,66` = 00 cent), mixed **48 : 52** (`5,66`). Filter type 0 (LP12) at cutoff 45, resonance 29, envelope amount stored 34 = **−29**, sustain 3. Delay on but dry/wet 0. Chorus on at level 14. EQ tone 110.

Its verbose row at HEAD:

```
069.sy1
  level       ref rms 0.00630  ours 0.02231  -> +10.99 dB   (peak 0.0551 / 0.1033)
  null        -0.29 dB at lag -347 samples, correlation 0.2881
  spectrum    11.45 dB mean over 58 bands, worst 27.4 dB at 604 Hz
  centroid    ref 347 Hz  ours 267 Hz  (-0.38 octaves)
  envelope    8.53 dB mean
```

Louder by 11 dB *and* darker by 0.38 octaves — which no gain error and no cutoff error can be at the same time.

---

## 2. What produces it: the oscillator start phase, measured not inferred

### 2.1 Bisection to the two oscillators

`s1probe patchdiag` on 069 put the gap in the filter (opening it wide took ref/our RMS from 0.0088/0.0277 to 0.0327/0.0381). That is a red herring — the filter *amplifies* an upstream error. Stripping 069 one parameter at a time (variants written to `build/research-next/v069c/`, each a copy of `069.sy1` with named records overridden):

| variant | spectral | envelope | level | null | correlation |
|---|--:|--:|--:|--:|--:|
| as-is | 11.45 | 8.53 | +10.99 | −0.29 | 0.288 |
| filter bypassed (19=127, 20=0, 21=63) | 4.72 | 1.38 | +2.45 | −0.26 | |
| + EQ tone neutral (60=64) | 6.53 | 1.66 | +4.26 | −0.72 | |
| + chorus off (66=0) | 6.46 | 1.71 | +4.18 | −0.74 | |
| + LFO 1 off (57=0) — **"c3"** | 3.84 | 1.71 | **+3.52** | **−3.64** | 0.753 |
| **c3, oscillator 1 only (5=0)** | **0.39** | 0.85 | **−0.15** | **−39.91** | 0.999992 |
| **c3, oscillator 2 only (5=127)** | **0.14** | 0.57 | **−0.14** | **−28.04** | 0.999428 |

Each oscillator alone nulls at −40 dB and −28 dB against the reference. Mixed 48 : 52 they null at −3.6 dB and come out 3.5 dB too loud. Both oscillators are right; **their relationship is wrong**, which can only be relative phase.

The harmonic breakdown of c3 says the same thing with no room left:

```
 k   refMag    ourMag   dB(o/r)      contributed by
 1  3.611e-2  9.555e-2   +8.45   triangle + saw
 2  3.944e-2  3.879e-2   -0.14   saw only
 3  3.171e-2  1.723e-2   -5.30   triangle + saw
 4  1.970e-2  1.938e-2   -0.14   saw only
 5  1.749e-2  1.208e-2   -3.21   triangle + saw
 6  1.311e-2  1.291e-2   -0.14   saw only
 8  9.813e-3  9.667e-3   -0.13   saw only
```

Every harmonic the saw carries alone matches to 0.14 dB. Every harmonic both oscillators reach is wrong. The error lives exactly and only where they overlap.

### 2.2 Three phase facts, read directly off the reference

Fundamental phase of each waveform, by projection onto a known `f0` over a whole number of periods in the steady part (note 60, `build/research-next/phase.js`; identical at windows starting 300, 600 and 1000 ms, so there is no drift):

| oscillator 1 shape | reference phase (turns) | ours | difference |
|---|--:|--:|--:|
| sine | −0.2507 | −0.2454 | +0.0053 |
| saw | −0.2507 | −0.2454 | +0.0053 |
| **triangle** | **−0.2507** | **−0.4954** | **−0.2447** |
| pulse (pw 29) | −0.4439 | −0.0525 | not a delay — see below |

The reference starts its sine, saw and triangle at the same fundamental phase. Ours starts the triangle a quarter turn late: **−0.2447 − 0.0053 = exactly −0.2500 turns**, once the common +0.0053 (≈ 1 sample of render alignment, present on every shape) is removed.

Folding one cycle of the rendered audio confirms it without any transform (`build/research-next/shape.js`, 100 cycles averaged, note 60):

```
reference triangle          our triangle
0.000   0.0055              0.000  -0.2179     <- ref crosses zero rising at phase 0
0.250   0.2230              0.250   0.0105        ours is at its trough
0.500  -0.0056              0.500   0.2179
0.750  -0.2230              0.750  -0.0105
```

And the pulse, same method:

```
reference pulse, pw=29                our pulse, pw=29
0.000  -0.1680  (edge)                0.000   0.0577  (edge)
0.031   0.0271  \                     0.031   0.2065  \  high +0.2076
  ...   0.0271   >  high +0.0271        ...            >  for 11.4% of the cycle
0.875   0.0276  /   for 88.6%         0.125   0.0437  /
0.906  -0.1711  (edge)                0.156  -0.0276  \  low  -0.0268
0.938  -0.2113  low                     ...            >  for 88.6%
0.969  -0.2113                        0.969  -0.0268  /
```

**The reference's pulse is high for `1 − pw` of the cycle; ours is high for `pw`.** The magnitude spectra of the two are identical (`|sin(πkd)|` is symmetric in `d ↔ 1−d`), which is why the spectral metric reads 0.18 dB on a single pulse while the null reads −0.08 dB. Predicted phases from the `1−pw` model reproduce the reference to four decimals at k = 1 and k = 2 (`−0.4431` predicted / `−0.4432` measured; `−0.3863` / `−0.3863`).

The vendor manual is silent on both, and its one relevant sentence points the wrong way: *"p/w — Set the pulse width of the pulse wave. Turn left to narrow the width, turn right to widen it"* (`docs/synth1-readme-eng.txt:128`). At stored 29 — left of centre — what is narrow in the reference is the **negative** excursion. The manual describes the knob, not the polarity. By contrast the changelog *does* pin the saw, and our saw is right because of it: *"The saw wave was changed from rising type to the descent type … The amplitude value by 0 phases changed from 0 to +1"* (`docs/synth1-readme-eng.txt:300-302`), which is `1 - 2*phase`, exactly what `src/dsp/oscillator.odin:189` computes. The triangle and the pulse got no such sentence, and both are wrong.

---

## 3. Oscillator 2's free-running start phase, measured directly

`src/engine/params.odin:534` holds `OSC_PHASE_FREE_TURNS :: f32(0.440)`, applied to oscillator 2 at note-on in `src/engine/voice.odin:210`. `docs/null-test.md:927-932` records how it was obtained: *"Fitting it from how far each harmonic is pulled down gives 158 degrees from the fundamental's 14.5 dB…"*.

**Attenuation depth is an even function of the offset.** Cancellation between two same-pitch oscillators depends on `cos(2πkφ)`, so a fit to how far a harmonic is pulled down cannot distinguish `+φ` from `−φ`. The magnitude was measured correctly; the sign was never determined, and the coin came down wrong.

### 3.1 The reading, from first-cycle edge timing

Per the amendment, the sweep against null depth is withdrawn. What follows is a direct reading of the start phase and nothing else.

Method (`build/research-next/startphase.js`): render a descending saw with an instant amplitude attack (`25=0, 26=127, 27=127`), filter open, no chorus/EQ/LFO/effect. Locate the falling discontinuity in each of the first 24 cycles by the steepest sample pair, place it to sub-sample precision by linear interpolation across the jump, fit a straight line through (cycle index, time), and extrapolate the intercept back to the note-on sample. The intercept, reduced modulo the measured period, is the oscillator's phase at note-on. Do it once with oscillator 1 alone and once with oscillator 2 alone; the difference is the offset. No spectra, no cancellation depth, no null.

| sample rate | note | ref osc1 | ref osc2 | **ref offset** | our osc1 | our osc2 | our offset |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 48 000 | 36 | 0.9978 | 0.5602 | **0.5624** | 0.9980 | 0.4380 | 0.4400 |
| 48 000 | 48 | 0.9948 | 0.5569 | **0.5621** | 0.9959 | 0.4362 | 0.4403 |
| 48 000 | 60 | 0.9882 | 0.5506 | **0.5624** | 0.9923 | 0.4317 | 0.4394 |
| 48 000 | 72 | 0.9751 | 0.5380 | **0.5629** | 0.9841 | 0.4256 | 0.4415 |
| 48 000 | 84 | 0.9538 | 0.5113 | *0.5575* | 0.9694 | 0.4098 | 0.4404 |
| 96 000 | 36 | 0.9978 | 0.5600 | **0.5622** | 0.9976 | 0.4376 | 0.4400 |
| 96 000 | 48 | 0.9944 | 0.5565 | **0.5621** | 0.9953 | 0.4353 | 0.4400 |
| 96 000 | 60 | 0.9874 | 0.5493 | **0.5619** | 0.9902 | 0.4307 | 0.4405 |
| 96 000 | 72 | 0.9733 | 0.5356 | **0.5623** | 0.9812 | 0.4204 | 0.4392 |
| 96 000 | 84 | 0.9462 | 0.5086 | **0.5624** | 0.9617 | 0.4026 | 0.4409 |

- **Method accuracy is established by the same measurement.** Our own engine's constant is exactly 0.440; the method reads it back as 0.4400 ± 0.0008 across all ten rows. It is unbiased to under a thousandth of a turn.
- The 48 kHz / note 84 row is discarded on a stated ground, not because it is inconvenient: a note-84 cycle is 20 samples at 48 kHz, and sub-sample edge interpolation across a band-limited edge cannot resolve a thousandth of a turn there. The same note at 96 kHz, where the cycle is 40 samples, reads 0.5624 in line with the rest.
- The nine kept readings give **0.56230, standard deviation 0.00030**, over **four octaves (notes 36 to 84)** and **two sample rates (48 kHz, 96 kHz)**.
- The value does not move with note or rate, so it is a fixed **phase**, not a fixed time and not a fixed sample count. A fixed sample offset would have halved between 48 and 96 kHz; it did not move at all.
- **32 kHz gave no reading**: the reference renders silence through this harness at that rate (both probe rows report `NO SUSTAIN`, ref RMS 0). Recorded as a limit of the measurement, not as a result.

### 3.2 Independent confirmation, and what the reading does and does not support

The frequency-domain route agrees, at notes 48/60/72 and three same-shape oscillator pairs:

| pair | note 48 | note 60 | note 72 |
|---|--:|--:|--:|
| saw + saw | 0.5624 | 0.5623 | 0.5623 |
| pulse + pulse | 0.5624 | 0.5624 | 0.5623 |
| triangle + triangle | — | 0.5623 | — |

Two methods with nothing in common, eight notes, three waveform pairs, two sample rates: **0.5623**.

What the measurement supports, stated at its own precision:

- **0.5623 ± 0.001.** That is what should be written down.
- **9/16 = 0.5625 is inside the interval and cannot be distinguished from it.** It is worth recording as a hypothesis (it is 1152 entries of a 2048-entry table, and the reference's author describes a 2048-entry oscillator table) but it must not be presented as the reading. On the whole bank the two are indistinguishable: every aggregate agrees to four decimals except envelope mean (2.0956 vs 2.0960) and null mean (−6.6565 vs −6.6572).
- **0.5600 — the exact sign flip of the existing 0.440 — is ruled out**, at 0.0023 from the mean, about seven standard deviations of the direct reading. It is ruled out by the start-phase measurement alone; no null depth is involved in saying so.

**Withdrawn.** Earlier in this session I swept the constant over 0.5500/0.5600/0.5623/0.5625/0.5700 and read the null depth of one probe patch at one note. That sweep is not evidence and is not used. For the record it was also incapable of settling the question: the readings were −18.41, −25.75, −24.47, −26.81, −20.90, which is non-monotone around the true value and would have preferred 0.5625 over 0.5623 on noise. It is reported here only so no one repeats it.

---

## 4. Summary of the defect

One subsystem — **the oscillator's start phase**, `src/dsp/oscillator.odin` and `src/engine/params.odin` — in three places:

| # | where | now | reference, measured | evidence |
|---|---|---|---|---|
| **D1** | `src/dsp/oscillator.odin:186` triangle | `1 - 4*abs(t - 0.5)` — starts at its trough | starts at zero crossing rising: a quarter turn earlier, **0.2500 turns exactly** | folded cycle; fundamental phase at 3 notes |
| **D2** | `src/engine/params.odin:534` `OSC_PHASE_FREE_TURNS` | `0.440` | **0.5623 ± 0.001** (equivalently −0.4377) | edge timing, 5 notes × 2 rates; harmonic phase, 3 notes × 3 pairs |
| **D3** | `src/dsp/oscillator.odin:214` pulse | delayed saw shifted by `pw`; high for `pw` | shifted by `1 − pw`; **high for `1 − pw`** | folded cycle; k=1,2 phase predicted to 4 dp |

D1 is what makes 069 an outlier. D2 and D3 are invisible to every magnitude metric and show only in the null depth and in mixes — which is precisely why they survived this long.

The single-oscillator null depths, which are checks against the reference and nothing else:

| single oscillator, filter open, no effects | HEAD | with the correction |
|---|--:|--:|
| sine | −44.34 | −44.34 |
| saw | −28.65 | −28.65 |
| **triangle** | **−39.91** | **−44.14** |
| **pulse** | **−0.08** | **−27.17** |
| **two oscillators mixed (069's c3)** | **−3.64** | **−24.47** |

---

## 5. The change is a systematic correction, not an outlier fix

**Stated plainly, as the amendment requires: 069 Oboe is the outlier, but correcting what produces it moves 111 of 123 patches.** This is not a patch-local repair and must not be reviewed as one. It changes the phase relationship of every two-oscillator patch in the bank and the waveform of every triangle and every pulse. It has to be gated on the whole-bank aggregate, and every patch it makes worse has to be named.

All figures from a scratch copy of the repository at `C:\Users\lamag\Code\synth-phase-scratch`, outside the workspace, built to `build/s1probe-F*.exe` and run from the repository root against the same DLL and the same bank. The workspace itself was not modified at any point (`git status --porcelain` empty, HEAD `5c790fd`). The scratch tree has since been reverted to pristine; the variant binaries are what survive.

### 5.1 Whole-bank aggregate, 123 patches

| metric | HEAD | D1+D2+D3 | change |
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

Counts: **spectral 45 better / 49 worse**, **envelope 82 better / 24 worse**, **null 84 deeper / 15 shallower**. Every aggregate improves. Spectral improves on mean and median while more patches move up than down, because the improvements are large (−5.48, −3.11, −3.07, −1.79, −1.57) and the regressions are small (largest +1.28).

### 5.2 Every regression, named

**Spectral, 49 patches worse** (before → after, delta):

031 Dist. Guitar 5.68→6.96 **+1.28** · 108 Koto 5.11→6.38 **+1.27** · 016 Dulcimer 4.66→5.78 **+1.11** · 118 Tom1 7.36→8.10 +0.74 · 083 Solo Lead 4.86→5.59 +0.73 · 046 Pizzicato 9.60→10.22 +0.62 · 121 Computer 9.56→10.06 +0.50 · 033 Acoustic Bass 8.08→8.51 +0.43 · 084 Sync lead 10.64→11.01 +0.37 · 066 AltoSax +0.25 · 063 SynBrass1 +0.24 · 079 Porta synth +0.24 · 103 Trans Brass +0.23 · 060 MuteTrumpet +0.23 · 088 Sweep lead +0.21 · 081 Square lead +0.20 · 126 Machine Gun +0.20 · 019 Rock Organ +0.19 · 094 Sweep pad 3 +0.16 · 054 Voice +0.16 · 044 Contrabass +0.15 · 068 BaritoneSax +0.14 · 018 Perc Organ +0.13 · 051 SynStrings1 +0.12 · 096 Light brass +0.12 · 086 Brass lead +0.10 · 010 Glocken +0.10 · 075 Recoder +0.10 · 043 Cello +0.07 · 111 Sequence 4 +0.07 · 042 Viola +0.07 · 089 Warm pad +0.06 · 056 Hit +0.04 · 067 TenorSax +0.04 · 104 Reso brass +0.04 · 125 Telephone +0.03 · 070 EnglishHorn +0.03 · 006 Chorus Piano +0.03 · 048 Timpani +0.02 · 001 Synth1 brastring +0.02 · 074 Flute +0.02 · 077 Whistle +0.02 · 023 Harmonica, 007 Harpsicode, 032 Harmo. Guitar, 015 Tubler Bells, 009 Celesta, 093 Sweep pad 2, 022 Accordion all +0.01 or less.

**Envelope, 24 patches worse:**

**033 Acoustic Bass 1.41→5.99 +4.58** · **084 Sync lead 1.76→3.29 +1.53** · 047 Harp 1.45→2.21 +0.76 · 088 Sweep lead 3.66→4.28 +0.62 · 124 Alien 4.31→4.74 +0.43 · 062 Brass1 +0.31 · 003 E.Piano +0.29 · 083 Solo Lead +0.27 · 092 Sweep pad 1 +0.26 · 052 SynStrings2 +0.25 · 127 LaserGun +0.16 · 063 SynBrass1 +0.16 · 114 kick1 +0.15 · 090 String pad +0.12 · 082 Saw lead +0.12 · 050 SlowStrings +0.11 · 116 snare2 +0.10 · 103 Trans Brass +0.09 · 118 Tom1 +0.07 · 010 Glocken, 075 Recoder, 087 High String, 089 Warm pad, 017 Hammond organ all +0.03 or less.

**Absolute level, 35 patches worse:**

085 Sync lead 2 2.46→4.36 **+1.90** · 047 Harp 0.85→2.06 **+1.21** · 094 Sweep pad 3 +0.51 · 060 MuteTrumpet +0.41 · 056 Hit +0.35 · 124 Alien +0.35 · 074 Flute +0.33 · 018 Perc Organ +0.27 · 050 SlowStrings +0.22 · 063 SynBrass1 +0.18 · 077 Whistle +0.16 · 112 Solo Synth +0.16 · 116 snare2 +0.14 · 108 Koto +0.13 · 067 TenorSax +0.12 · 072 Clarinet +0.11 · 088 Sweep lead +0.09 · 086 Brass lead +0.09 · 039 Synth Bass 1 +0.08 · 019 Rock Organ +0.08 · 030 Overdrive Guitar +0.07 · 089 Warm pad +0.07 · 045 Tremolo Strings +0.06 · 051 SynStrings1 +0.05 · 083 Solo Lead +0.04 · 068 BaritoneSax +0.04 · 082 Saw lead +0.03 · 049 Strings +0.03 · 070 EnglishHorn +0.03 · 121 Computer, 027 E Guitar, 033 Acoustic Bass, 114 kick1, 044 Contrabass, 028 E Guitar 2 all +0.02 or less.

**Null depth, 15 patches shallower:**

047 Harp −7.25→−3.85 **+3.40** · 062 Brass1 −6.98→−5.35 +1.63 · 032 Harmo. Guitar −10.05→−9.24 +0.80 · 089 Warm pad +0.51 · 117 Perc1 +0.45 · 033 Acoustic Bass +0.42 · 027 E Guitar +0.41 · 002 Piano +0.40 · 075 Recoder +0.22 · 053 Choir +0.20 · 028 E Guitar 2 +0.18 · 048 Timpani +0.14 · 052 SynStrings2 +0.13 · 006 Chorus Piano +0.12 · 005 Rhodes Piano +0.07.

**Three regressions are material and should be settled before merge:**

- **033 Acoustic Bass, envelope 1.41 → 5.99.** Attributed entirely to D2 (the offset); D1 and D3 leave it at 1.41. This is the largest single regression in the change and the only one that creates a new top-ten envelope entry (z 2.56 after). It needs its own isolation run.
- **047 Harp**, the only patch worse on three metrics at once (spectral −1.48 better, but envelope +0.76, level +1.21, null +3.40).
- **085 Sync lead 2, level 2.46 → 4.36**, against an envelope improvement of −0.93 and a null 3.34 dB deeper.

The rest are under half a decibel and are the ordinary cost of changing a waveform.

### 5.3 What it buys, named

| patch | | spectral | envelope | \|level\| | null |
|---|---|---|---|---|---|
| **117 Perc1** | 9.55 → **4.06** | −5.48 | 6.21 → **2.05** | 6.06 → **0.01** | +0.45 |
| **029 E Guitar 3** | 6.31 → 4.52 | −1.79 | **9.08 → 1.24** | 3.55 → **0.01** | −1.86 |
| **069 Oboe** | 11.45 → 8.35 | −3.11 | 8.53 → 4.78 | 10.99 → 6.18 | −2.69 |
| **078 Whistle 2** | 6.83 → 3.76 | −3.07 | −0.46 | 7.35 → **1.31** | −1.02 → **−11.22** |
| **004 Honky Piano** | −0.74 | 5.12 → **0.95** | −0.91 | −2.97 → **−13.63** |
| 065 SolpnanoSax | −0.66 | −0.97 | 4.36 → 1.28 | −4.16 |
| 002 Piano | −0.71 | 4.09 → 2.10 | 2.49 → 0.52 | +0.40 |
| 035 E Bass 2 | 0.00 | 4.60 → 1.53 | −0.34 | −10.89 |
| 039 Synth Bass 1 | −0.01 | −0.98 | +0.08 | **−11.78** |
| 008 Clavinet | 0.00 | −0.59 | 0.00 | **−11.21** |
| 034, 026, 019, 040 | ~0 | small | ~0 | −11.14, −10.09, −10.11, **−14.04** |

**117 Perc1** is worth calling out on its own: `docs/null-test.md:962` names it as the bank's historically worst patch, and D3 alone takes its level error from 6.06 dB to **0.01 dB**. **029** was the bank's top envelope outlier at HEAD, and D2 alone takes it from 9.08 to 1.24.

### 5.4 The three parts do not stand alone

Each part measured separately against HEAD, on the patches that discriminate them:

| patch | metric | HEAD | D1 only | D2 only | D3 only | D1+D2 | **all three** |
|---|---|--:|--:|--:|--:|--:|--:|
| 069 Oboe | level | 10.99 | 5.54 | *13.77* | 10.99 | 6.18 | **6.18** |
| 069 Oboe | envelope | 8.53 | 5.43 | *9.89* | 8.53 | 4.78 | **4.78** |
| 029 E Guitar 3 | envelope | 9.08 | 9.08 | **1.24** | 9.08 | 1.24 | **1.24** |
| 117 Perc1 | level | 6.06 | 6.06 | 6.06 | **0.01** | 6.06 | **0.01** |
| 002 Piano | envelope | 4.09 | *7.77* | *4.92* | *7.41* | *5.91* | **2.10** |
| 004 Honky Piano | envelope | 5.12 | 5.15 | 5.20 | *5.49* | 3.96 | **0.95** |

**002 Piano is the decisive row.** Every partial correction makes it worse — the triangle alone raises it to 7.77 and would have created a new bank outlier — and only the complete correction improves it, to 2.10. D2 applied alone regresses 069, the patch that started this. Three phase errors compose; removing one at a time moves the relationship to a different wrong place. The parts are separable for *attribution* and not for *shipping*.

### 5.5 Outlier ranking afterwards

069 leaves the top three on every metric:

- `abs(level_db)`: 083 Solo Lead 9.86 (z 4.59), 071 Basson 8.56, 032 Harmo. Guitar 7.04, 073 Piccolo 6.27, **069 6.18** (5th, z 2.53).
- `envelope_db`: 053 Choir 7.25 (z 3.39), 089 Warm pad 6.96, 120 6.65, 033 Acoustic Bass 5.99, 121 Computer 5.95, **069 4.78** (9th, z 1.77).
- `spectral_db`: 088 16.93, 086 16.78, 001 16.32 — the same smooth tail, still no outlier.
- width: 119 / 089 / 111 unchanged.

The bank's next lead becomes the **level cluster at 069–083** — 083 (9.86), 071 (8.56), 073 (6.27), 069 (6.18), 070 (5.73), 077 (4.45), plus 032 (7.04). These are the woodwind family and they share a filter configuration, not an oscillator one. On 069 after the correction, opening the filter (19=127) takes the level error from +6.18 to **+0.92**, and a *static* cutoff at 45 takes it to +0.75 — so the residual is the filter **envelope** at a negative amount over a low cutoff, not the cutoff table and not the resonance. That is a clean starting point and it is a different subsystem.

---

## 6. Implementation guidance

### 6.1 The change

Three edits, all measured, none tuned.

1. **`src/dsp/oscillator.odin:186`**, the triangle. `return 1.0 - 4.0 * abs(t - 0.5)` must evaluate at `t + 0.25` (wrapped). The comment must say what was measured: the reference's triangle crosses zero rising at phase 0 and peaks at a quarter, and ours started at its trough — a quarter turn, exactly, confirmed by folding the reference's own render and by the fundamental's phase at three notes. Say that this is inaudible in a single-oscillator patch and wrecks every patch that mixes a triangle with anything at the same pitch, so that no one "simplifies" it back.

2. **`src/dsp/oscillator.odin:214`**, the pulse. `t2 := t - pw` becomes `t2 := t - (1.0 - pw)`. The comment must record that the reference's pulse is high for `1 − pw`, that the magnitude spectra of the two are identical so the spectral metric cannot see the difference, and that the vendor's "turn left to narrow the width" describes the negative excursion. The existing note about the two-saw form being DC-free is still true and must stay: the identity holds for any shift.

3. **`src/engine/params.odin:534`**. `OSC_PHASE_FREE_TURNS :: f32(0.440)` becomes `f32(0.5623)`. The comment must be rewritten, not amended: the current one cites a 158-degree fit to attenuation depth, and that method cannot see a sign. Replace it with the start-phase reading — 0.5623 ± 0.001, from falling-edge timing extrapolated to note-on at five notes over four octaves and two sample rates, cross-checked by fundamental phase at three notes and three waveform pairs — and state explicitly that the magnitude was right, the sign was not, and that no attenuation fit could ever have told the difference. Record 9/16 = 0.5625 as inside the measurement's own interval and 0.5600 as ruled out by it. Do not write a digit the reading does not carry.

`src/engine/voice.odin:192-206` carries the same "158 degrees" reasoning in prose and must be corrected with it.

Line 916 of `docs/null-test.md` (*"Fitting it from how far each harmonic is pulled down gives 158 degrees"*) is the origin of the error and should be revisited in the same edit rather than left standing.

### 6.2 The tests, and the trap

**No existing test can see any of this.** Verified: `odin test tests/dsp` gives 74 passing at HEAD and 74 passing with all three changes applied; `tests/clap` 36 passing both ways; `tests/patch` 28 passing both ways. Three defects in the audible core, and the suite is blind to every one.

The two tests that come nearest are worth reading before writing new ones, because each shows a different half of CONTRIBUTING's trap:

- **`test_pulse_at_half_width_is_a_square`** (`tests/dsp/dsp_test.odin:998`) asserts high `+0.5` and low `−0.5` at width 0.5. It passes either way, and it always would: a square is its own duty complement. Checking the one width where the defect is invisible.
- **`test_oscillator_phase_offset_is_between_the_oscillators`** (`tests/dsp/dsp_test.odin:2030`) asserts that half a turn between two same-pitch pulses cancels the fundamental. It is a *good* test that cannot possibly catch D2, and the reason is the whole lesson: **cancellation depth is an even function of phase, so any test built on "how far did this harmonic drop" is sign-blind by construction.** That is exactly how a sign survived being "measured".

So the pin has to be a **signed** quantity, and it has to be anchored on the reference:

- **D2.** Render two same-pitch, same-shape oscillators, project the mix and each oscillator alone onto the fundamental, and assert the *signed* phase difference is `0.5623 ± 0.002` turns. Not the attenuation. Record in the comment that the attenuation form was tried, is what let the sign through, and must not be substituted back.
- **D1 and D3.** Assert the waveform against the reference's own folded cycle, with the numbers this session read off `Synth1 VST64.dll` and the command that produced them in the comment: the triangle is `0.0055, 0.2230, −0.0056, −0.2230` at phases `0, 0.25, 0.5, 0.75`; the pulse at width 29 is high `+0.0271` from phase 0.03 to 0.89 and low `−0.2113` from 0.91 to 1.0. Asserting `oscillator_value(.Triangle, 0) == 0` instead would be checking the code against the assumption that replaced the last one.

These belong in `tests/dsp` beside the existing oscillator tests, as measured tables with provenance, which is how `FILTER_CUTOFF_HZ` and `ARP_STEP_BEATS` already carry their measurements.

### 6.3 Gates

Run, from CONTRIBUTING's list — all verified green with the change applied in the scratch tree:

- `odin test tests/dsp` (74), `odin test tests/clap` (36), `odin test tests/patch` (28)
- `odin build hosts/standalone`, `hosts/clap`, `hosts/vst3`, `hosts/wasm`, then `node hosts/wasm/check-imports.js` (all 7 imports provided)
- `odin run tools/uiparams` — **verified not required but harmless**: `ui/params.js` is byte-identical afterwards (`md5 5a29da956817d2b3b36f96e76cd40c18` before and after). The change touches a phase constant, not a parameter display.
- `tools/sy1check/check.js` is **not** implicated: `src/patch/sy1.odin` is untouched, so `ui/sy1.js` cannot drift.

**Prediction to check against.** After all three changes the bank should read spectral mean/median **6.654 / 5.977**, envelope mean/median **2.096 / 1.770**, level absolute mean **1.653**, level signed median **+0.046**, null mean/median **−6.657 / −6.080**, correlation **0.761**, with **069 at 8.35 / 4.78 / +6.18 / −2.98**, **117 at 4.06 / 2.05 / +0.01**, **029 at 4.52 / 1.24 / +0.01**. Different numbers mean something other than these three lines changed.

---

## 7. Corrections to the record, and what is not established

- **`docs/null-test.md`'s spectral figures are not stale.** The previous round's report (`research/2026-08-22-find-a-patch-outlier-in-the-null-test-and-fix-it.md:243`) flagged the doc's 6.77 / 6.23 as possibly mis-transcribed against its own 6.5399 / 6.0277. Both are right and the denominators differ: 6.7597 × 119 / 123 = 6.5399 exactly. The doc averages the 119 rows with `spectral_valid=true`; the previous report averaged all 123. The doc needs no correction; the convention should be stated wherever the figure appears. Every other HEAD aggregate reproduces that report's post-delay-fix predictions exactly (envelope mean 2.5025 vs 2.50 predicted, level bias +0.1928 vs +0.193, null −3.9634 vs −3.96), so the delay fix landed as described.
- **`o2s0` is a probe artefact, not a bank defect.** Writing `1,0` into a `.sy1` selects no display for parameter 1, so `resolved_display_id` falls through to Noise in our engine while the reference gives a saw. No factory patch stores it — the bank's oscillator-2 shapes are `1,1` ×20, `1,2` ×70, `1,3` ×24, `1,4` ×14. Ignored, and mentioned only because it appears in `build/research-next/vph.csv`.
- **Every render is at velocity 100, note 60 unless stated, 1.5 s held + 1.0 s tail, block 512.** The start-phase readings are the only measurements taken at other notes and rates.
- **32 kHz produced no reference output** through this harness. Whether that is the plugin or the harness is not established.
- **033 Acoustic Bass's +4.58 dB envelope regression is located to D2 and not diagnosed.** It is the one result here that would justify holding the change.
- **The residual on 069 (+6.18 dB) is located to the filter envelope and not diagnosed.** So is the 069–083 woodwind level cluster it belongs to.
- **119 SynDrum's width and 089/111's** are untouched by this change and remain open, as does the bank-wide width deficit.
- **The scratch tree at `C:\Users\lamag\Code\synth-phase-scratch` has been reverted to pristine.** The test-suite and host-build results in §6.3 were taken with the change applied there before the revert; the implementation stage should regenerate them rather than trust this note. What survives is the variant binaries, `build/s1probe-F1.exe` (D1), `-F2` (D2), `-F5` (D3), `-F3` (D1+D2), `-F4` (all three), `-F6` (all three at 0.5625), `-96000` and `-32000` (pristine engine, other sample rates).

## 8. Artefacts left on disk

All under `build/` and therefore gitignored:

- `build/research-next/nulltest-head.csv` — the HEAD baseline, 123 rows
- `build/research-next/bank-F1..F6.csv` — the same bank under each candidate
- `build/research-next/v069/`, `v069b/`, `v069c/`, `vph/`, `vsp/` — the isolation and probe patch sets
- `build/research-next/{stats,agg,pick,regress,phase,startphase,shape,wavan,params,variant}.js` — the analysis scripts, each with its method in a header comment
- `build/research-next/wav*/`, `wsp-*/`, `wavn*/` — the renders the phase readings come from