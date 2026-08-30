# Research: is the oscillator start phase one constant or a per-shape law? — settled by absolute measurement

**Repository** `C:\Users\lamag\Code\synth` · **HEAD** `92e5e48` "Three phase errors in the oscillator" · `git status --porcelain` empty before and after this session (verified) · every figure below produced this session against `ext/synth1/Synth1/Synth1 VST64.dll`.

**Probe provenance.** `build/s1probe.exe` was rebuilt from the working tree at the start of the session and again at the end (`odin build tools/s1probe -out:build/s1probe.exe`). The engine variants used for attribution were built from a `git archive HEAD` copy at `C:\Users\lamag\Code\synth-rp2`, one source line changed each, and were checked against the working-tree probe for staleness: `build/rp2/VA.exe` (unmodified HEAD, built in the scratch tree) and `build/s1probe.exe` render `033.sy1` **bit-identically** (`md5 b9e5e347cfc0b985ff873a87441f35c3`). The scratch tree was restored after each build and now differs from HEAD only in line endings.

**Contract amendments received.** None. No mid-run user message arrived during this stage.

---

## 1. The answer

**It is one constant, applied to oscillator 2, with the sign and the assignment the code already has. There is no per-shape start phase left to find.** The measurement is not a difference between two renders of a fitted quantity; it is an absolute reading of each oscillator against note-on, and it says:

| quantity | reference, measured this session | `src/engine` at HEAD |
|---|---|---|
| oscillator 1 free-run start phase, all four shapes | **0.000 ± 0.002 turns** | `0` (`voice.odin:209`) |
| oscillator 2 free-run start phase | **+0.562334 ± 0.000012 turns** | `OSC_PHASE_FREE_TURNS = 0.5623` (`params.odin:556`) |
| shape dependence of that offset (saw / triangle / pulse) | none: the three agree to **1×10⁻⁵ turns** | one constant, shape-blind |
| note dependence (notes 36, 48, 60, 72, 84) | none: sd **1.2×10⁻⁵** over four octaves | note-blind |
| sample-rate dependence (48 kHz vs 96 kHz) | none, to 1×10⁻⁵ | rate-blind |
| behaviour when both oscillators run together | exact superposition of the two single-oscillator renders, residual **−97 to −181 dB** | superposition by construction |

The mirror — the same magnitude with the opposite sign, `osc2` at `0.4377` — is **excluded by the reading itself**, not by a metric: fitting the reference's own two-oscillator render as `α·(osc1 alone) + β·(osc2 alone)` gives `arg α = arg β = 0.0000` turns and a residual of −97 dB, while the conjugate (mirrored) model fits the *same* render at −4 dB to +7 dB. Two hypotheses separated by ninety to a hundred and eighty decibels of residual on the reference's own audio.

**Two things the reading changes.**

1. **`9/16 = 0.5625` is now ruled out.** `params.odin:550-552` and `docs/null-test.md:4509-4514` record it as a hypothesis "inside the interval" that "cannot be told apart" from the reading. The new reading is 25× sharper: 0.5625 is 1.66×10⁻⁴ away, **14 standard deviations**. The value the evidence now supports is **0.562334 ± 0.000012**; the written `0.5623` is 3.4×10⁻⁵ (≈3 sd) low.
2. **The written constant's last digit is now resolvable but inconsequential.** A bank run with `f32(0.56233)` is identical to HEAD on every aggregate to four decimals, largest per-patch change 0.004 dB (§7).

**And the thing the objective asked to settle about the bank: the contradiction was never about phase.** 033 Acoustic Bass and 029 E Guitar 3 — the two patches that pull in opposite directions — are the two of the five that run the **oscillator modulation envelope on oscillator 2's pitch** (parameter 10 = 1, dest 71 = 0). Switch that envelope off and both agree with the absolute reading, and both null 6–10 dB deeper:

| patch, one record changed | HEAD (`osc2 = +0.5623`) | mirror (`osc2 = +0.4377`) |
|---|--:|--:|
| **033 as shipped** | envelope 5.99, null −0.99 | envelope **1.39**, null −1.42 |
| **033 with `10=0` (mod env off)** | envelope **0.67**, null **−11.69** | envelope 1.08, null −5.04 |
| **029 as shipped** | envelope **1.24**, null −5.91 | envelope 9.13, null −4.00 |
| **029 with `10=0`** | envelope **0.81**, null **−11.74** | envelope 1.27, null −2.13 |
| 033 reduced to oscillator 2 alone (`5=127`) | envelope 1.50, null **−0.30** | envelope 2.13, null −0.33 |

The last row is the one that ends the argument: with 033 reduced to a *single* oscillator, where a start phase is a pure time shift and the null test searches lag anyway, the null is still only **−0.30 dB**, and the two candidate phases differ by 0.03 dB. 033's damage is upstream of any phase question. A bare oscillator carrying 033's own modulation-envelope settings and nothing else nulls at **−11.79 dB** where the same oscillator with the envelope off nulls at **−22.47 dB** (envelope error 2.23 vs 0.05) — a phase-free measurement of the real defect.

**So: the law stands, the constant is held (optionally refined to the sharper reading), and 033 is diagnosed — as the oscillator modulation envelope, not the start phase.** Choosing the mirror because 033's envelope metric improves would be tuning the oscillator to hide a pitch-envelope error; it costs 029 (1.24 → 9.13) and, bank-wide, 1.21 dB of mean null depth (§7).

---

## 2. Why this measurement is allowed to settle it

The forbidden method is choosing a constant by sweeping it against a metric. Nothing below does that. Every number in §3–§5 comes from one of three constructions, and none of them has a knob:

- **Absolute harmonic phase against note-on.** `tools/s1probe/compare.odin:254` sends the note-on before the first block and drives both engines in the same block size, so **frame 0 is the note-on sample in both renders**. Projecting a render onto `cos/sin(2πk f₀ t)` with `t` counted from frame 0 gives an absolute phase, not a difference.
- **Separation of phase from latency by pitch.** At one pitch a start phase and an output latency are the same thing. They separate over pitch: a start phase is constant in turns at every note, a latency is constant in seconds and so contributes `τ·f₀` turns. Reading five notes over four octaves and fitting a straight line in `f₀` gives both. (The reference also *declares* its latency: `s1probe compare` prints "reference reports 0 samples of initial delay", and the fit reads τ = −0.36 samples at 48 kHz.)
- **Differences taken inside one engine at one note**, where the plugin's latency, the filter's group delay and the shape's own Fourier convention cancel exactly because they are common to the two renders. This is what gives the 1×10⁻⁵ precision on the offset.

Three controls, all run this session:

1. **Which oscillator is which, checked on the reference, not assumed.** With `5=0` (mix "100 : 0"), changing oscillator 2's shape from saw to pulse leaves the *reference's* render **bit-identical** (residual −∞ dB). With `5=127`, changing oscillator 1's shape from sine to pulse leaves it bit-identical. The mix polarity, which is the whole assignment question, is pinned by the reference's own silence.
2. **The method's own bias, against a known truth.** Our engine's oscillator 2 is at exactly `f32(0.5623) = 0.56229996`. The method reads it back as **0.5623022** — a bias of **+2.3×10⁻⁶ turns**. The same method reads the reference as 0.5623366, so the reference's value is 0.562334.
3. **Non-silence, never assumed.** Every render was made through `s1probe compare`, which reports "reference silent" and "ours silent" counts per run; all were 0. The whole-bank runs report the five reference-crashing patches and complete 123 rows.

---

## 3. The absolute readings

### 3.1 Per oscillator, per shape, 48 kHz, notes 36–84

Apparent start phase in turns, time origin = note-on, with each shape's own Fourier convention taken from our oscillator 1 (whose start phase is pinned at 0 by `voice.odin:209`) rather than derived on paper — so an error in the triangle's or the pulse's convention cannot become an error in the answer. `phi0` is the intercept of the fit in `f₀`, `tau` its slope expressed in samples at 48 kHz.

```
stem        shape  side        n36      n48      n60      n72      n84     phi0   tau(samp)  rms
o1sine      sine   ref    -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36   0.0000
o1saw       saw    ref    -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36   0.0000
o1pulse     pulse  ref    -0.0004  -0.0007  -0.0017  -0.0037  -0.0077   0.0002    -0.36   0.0000
o1tri       tri    ref    -0.0002  -0.0005  -0.0015  -0.0035  -0.0075   0.0004    -0.36   0.0000
o2saw       saw    ref    -0.4378  -0.4382  -0.4392  -0.4412  -0.4451  -0.4373    -0.36   0.0000
o2pulse     pulse  ref    -0.4380  -0.4384  -0.4394  -0.4414  -0.4453  -0.4374    -0.36   0.0000
o2tri       tri    ref    -0.4378  -0.4382  -0.4392  -0.4412  -0.4451  -0.4372    -0.36   0.0000
o1*         all    ours    0.0000   0.0010   0.0037   0.0080   0.0158  -0.0008    +0.77   0.0003
o2*         all    ours   -0.4377  -0.4367  -0.4340  -0.4297  -0.4219  -0.4385    +0.77   0.0003
```

Read: **oscillator 1 starts at 0 for every shape** (intercept 0.0002–0.0004, and the method's absolute accuracy is ~0.001 turns because the convention is calibrated at note 36 where our own fit still carries +0.001); **oscillator 2 starts at −0.4373 = +0.5627** for every shape. The drift across the row is the latency term and it is identical for both oscillators and all four shapes. At 96 kHz the same table gives `phi0` = +0.0001…+0.0002 for oscillator 1 and −0.4375…−0.4377 for oscillator 2.

This alone excludes the two alternatives with the same magnitude:

- **the mirror** (`osc1 = 0, osc2 = +0.4377`): oscillator 2 reads 0.5623, not 0.4377 — 0.125 turns out, 100× the method's absolute accuracy;
- **the global shift** (`osc1 = +0.4377, osc2 = 0`, which preserves the difference): oscillator 1 reads 0.000, not 0.4377.

### 3.2 The offset itself, to 1×10⁻⁵

Signed `osc2(alone) − osc1(alone)` in the same engine at the same note, so latency, filter group delay and shape convention cancel:

```
shape  side         n36       n48       n60       n72       n84      mean      sd
saw    ref     -0.43766  -0.43767  -0.43767  -0.43767  -0.43766  -0.43766  0.00000
tri    ref     -0.43767  -0.43767  -0.43767  -0.43767  -0.43767  -0.43767  0.00000
pulse  ref     -0.43766  -0.43767  -0.43766  -0.43767  -0.43766  -0.43766  0.00000
saw    ours    -0.43770  -0.43770  -0.43770  -0.43770  -0.43770  -0.43770  0.00000
```

Harmonics 1–7 agree with harmonic 1 to 3×10⁻⁵ in every cell (the branch of `d/k` is resolved against the `k=1` estimate). Pooling 90 readings — 5 notes × 3 shapes × up to 7 harmonics, 48 kHz:

- **reference: 0.5623366, sd 0.0000116** (min 0.562292, max 0.562398)
- ours: 0.5623022, sd 0.0000100, against a truth of 0.56229996 → **method bias +2.3×10⁻⁶**
- **reference, bias removed: 0.562334 ± 0.000012**
- `9/16 = 0.5625` → 14 sd away, **excluded**
- `10^(−1/4) = 0.5623413` → 0.6 sd away. A coincidence worth one sentence and no more; it must not be written into the code as a value.

At 96 kHz (three notes, three shapes): −0.43766 / −0.43767 in every cell, unchanged. **A fixed sample offset would have halved; it did not move at all.**

### 3.3 A phase of oscillator 2's own cycle, not a time

Transposing oscillator 2 by ±12 semitones and reading it alone against its own fundamental, note 48 and 60:

| osc2 transposed | reference start phase in its own cycle |
|---|--:|
| +12 semitones | 0.56159 (note 48), 0.55961 (note 60) |
| −12 semitones | 0.56296 (note 48), 0.56259 (note 60) |

If the offset were a fixed *time* of `0.5623/f₀` seconds, at +12 it would read `1.1246 mod 1 = 0.1246`. It reads 0.560, with the small deviations tracking the latency term (which doubles with the frequency, as it must). It is a phase of oscillator 2's own cycle.

### 3.4 Both oscillators running: exact superposition, and the mirror rejected on the reference's own audio

For one note, three renders of the same engine — oscillator 1 alone, oscillator 2 alone, and the pair at a known mix — solved for complex `α, β` in `H_pair,k = α·H_osc1,k + β·H_osc2,k` over harmonics 1..7. No waveform model appears anywhere in it.

```
note 60
pair          side   mix       |alpha|  arg(a)turn   |beta|  arg(b)turn   residual  conj-residual
prsaw25      ref   75:25     0.7482     0.0000   0.2520    -0.0000     -97.25 dB    -3.91 dB
prsaw75      ref   25:75     0.2442    -0.0000   0.7561     0.0000     -97.24 dB     5.51 dB
prtri25      ref   75:25     0.7480     0.0000   0.2520     0.0000    -170.75 dB    -1.11 dB
prpul25      ref   75:25     0.7480    -0.0000   0.2520     0.0000    -181.41 dB    -5.92 dB
prsinesaw    ref   50:50     0.4961    -0.0000   0.5040     0.0000    -102.40 dB     6.00 dB
prtrisaw     ref   50:50     0.4961    -0.0000   0.5040     0.0000    -100.35 dB     7.02 dB
```

Same at note 48. Read:

- **`arg α = arg β = 0.0000` turns**: each oscillator sits in the pair exactly where it sits alone. Switching the other oscillator on moves neither phase.
- **residual −97 to −181 dB**: the reference's two-oscillator render *is* the sum of its two single-oscillator renders.
- **conjugate residual −4 to +7 dB**: the mirrored assignment does not fit the same render at all. This is measured on the same-shape pair (`prsaw25/75`), on the other two same-shape pairs, and on both mixed-shape pairs — the 029 configuration (`sine + saw`) and the 069 configuration (`triangle + saw`).

### 3.5 The pulse, at eight widths — the per-shape hypothesis's last hiding place

The one place a per-shape phase law could still have lived is the pulse, whose phase depends on its duty. `phase(pulse) − phase(saw)` at `k=1`, taken inside one engine so latency cancels, note 48:

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

The last column is the analytic prediction of the shipped model — two saws differenced with a shift of `1 − pw`. It reproduces the reference across the whole range. And comparing the reference to ours harmonic by harmonic, the residual is **`−0.0017 × k` turns at every width** (−0.0017, −0.0035, −0.0052, −0.0069, −0.0087 at k=1..5): linear in `k` is a pure delay of 0.62 samples, the same latency term seen everywhere else. A duty error or a shape-specific start phase would be neither width-independent nor linear in `k`. **The triangle (D1) and the pulse (D3) as shipped are exactly right, absolutely, and there is no residual per-shape phase for a fourth constant to absorb.**

---

## 4. The contradicting patches, explained rather than averaged

Patch records read this session from `ext/synth1/Synth1/soundbank00/`:

| patch | osc1 | osc2 | pitch | mix | mod env (10 / 11 / 12 / 13, dest 71) |
|---|---|---|---|---|---|
| 033 Acoustic Bass | saw (`0,1`) | saw (`1,1`) | identical | `5,59` | **on**, 27 / 53 / 0, dest 0 = osc2 pitch |
| 029 E Guitar 3 | sine (`0,0`) | saw (`1,1`) | identical | `5,84` | **on**, 36 / 39 / 0, dest 0 = osc2 pitch |
| 069 Oboe | triangle (`0,3`) | saw (`1,1`) | identical | `5,66` | off |
| 117 Perc1 | pulse (`0,2`) | **noise** (`1,4`) | — | `5,47` | off |
| 078 Whistle 2 | sine | triangle (`1,3`) | — | **`5,127` = oscillator 2 alone** | off |

**033 and 029: the modulation envelope, not the phase.** Both sweep oscillator 2's pitch at note-on, so the phase relationship is integrated through a pitch ramp instead of being constant, and the early cancellation pattern becomes extremely sensitive to where the sweep goes. Our sweep is not the reference's, measured directly with no phase involved: a bare saw on oscillator 2 alone, filter open, no effects, carrying only 033's modulation-envelope records, nulls at **−11.79 dB** (envelope error 2.23) against **−22.47 dB** (envelope 0.05) with the envelope off; 029's records give −19.04 / 0.84. Instantaneous frequency read cycle by cycle off both renders at note 60 shows the reference diving past −1746 cents within 19 ms while ours passes −1200 and settles there — different curves, same direction. The isolation table in §1 then shows that with the envelope off both patches prefer the measured sign, by 6.6 dB and 9.6 dB of null depth.

**069 Oboe is the clean mixed-shape case and it agrees with the reading.** It does not use the modulation envelope. HEAD: spectral 8.35, envelope 4.78, level +6.18, null −2.98. Mirror: 7.90 / 5.51 / +5.62 / −2.23 — worse on envelope and null, marginally better on spectral. Its remaining error is the filter envelope, as `docs/null-test.md:4637-4643` already records.

**117 is sign-blind provably, not just empirically.** Its oscillator 2 is noise, which has no phase, and only oscillator 2 carries the constant — so the two candidate engines produce **bit-identical renders**: `md5 63c6525340686298ce6e2873e36c14b2` for both. Metrics identical to the last digit (4.06 / 2.05 / −0.01 / −2.89).

**078 is a single-oscillator patch** (mix "0 : 100"), so the constant is a pure time shift of the whole voice and the null test searches lag: 3.76 / 0.85 / −1.31 / −11.22 against 3.82 / 0.82 / −1.31 / −11.02.

**The premise the objective drew from the bank does not survive.** "Every patch preferring +φ pairs a different osc1 shape against osc2's saw; the only same-shape pair prefers −φ" was true of the readings but not of the physics: the same-shape pair is the one with the pitch envelope, and with the envelope off it prefers +φ like everything else. Two of the five discriminating patches cannot discriminate at all (one provably), and the two that appeared to contradict share a subsystem that has nothing to do with shape.

**The three columns in the objective are not three pieces of evidence.** `0.440` and the mirror `0.4377` differ by 0.0023 turns, and the previous session's own binaries agree they are the same measurement: `build/diag033/V0-033.csv` reads envelope 1.4073, null −1.4093 and `VFLIP-033.csv` reads 1.3909 / −1.4151; on 029, 9.0812 and 9.1268. My own mirror build reads 1.39 / −1.42 and 9.13 / −4.00. So "1.41 at 0.440, 1.39 at 0.4377" is one reading twice.

---

## 5. A second, unrelated sign-blindness in the same code region: parameter 91's law

Worth reporting because the *method* that produced it is the one the objective condemns. `binding.odin:565-589` sets the fixed-phase relationship to `0.5 · v/127`, justified by three cancellation nulls — and cancellation depth is even in phase, so those nulls could not see a sign or an offset either. Measured absolutely this session, oscillator 1 alone and oscillator 2 alone at `91 = v`, referred to the free-run oscillator 1 of the same engine (identical at notes 48 and 60):

| stored 91 | ref osc1 | ref osc2 | ref osc2 − osc1 | `0.5(v−1)/126` | our engine `0.5v/127` |
|--:|--:|--:|--:|--:|--:|
| 0 | 0.00000 | 0.56233 | +0.56233 | — (not fixed) | 0.5623 |
| 16 | 0.99875 | 0.05827 | **0.05952** | 0.059524 | 0.06299 |
| 32 | 0.99875 | 0.12176 | **0.12302** | 0.123016 | 0.12598 |
| 48 | 0.99875 | 0.18526 | **0.18651** | 0.186508 | 0.18898 |
| 64 | 0.99875 | 0.24875 | **0.25000** | 0.250000 | 0.25197 |
| 96 | 0.99875 | 0.37573 | **0.37698** | 0.376984 | 0.37795 |
| 127 | 0.99875 | 0.49875 | **0.50000** | 0.500000 | 0.50000 |

Two readings, both exact to 5×10⁻⁶:

- the relationship is **`0.5·(v−1)/126` turns**, not `0.5·v/127` — the same at both ends and wrong by up to 0.002 turns in between (0.25000 against our 0.25197 at the knob's centre);
- when parameter 91 is engaged the reference's oscillator 1 does **not** sit at the free-run 0 but at **−0.00125 turns**, note-independent, the same for every `v ≥ 1`. Our code pins it at 0.

Both of these are invisible to the bank: **every `ver=105` factory patch omits parameter 91**, so no null-test aggregate can move and neither change can be gated on it. That is exactly why they need the reading and a test rather than a metric. They are adjacent to the objective's literal text (which disputes `OSC_PHASE_FREE_TURNS`), so treat them as an optional companion change that must not delay the deliverable — and note that `tests/dsp/dsp_test.odin:2113` currently asserts `{48→0.189, 64→0.252, 127→0.500}`, which are *the code's own* numbers with a 0.005 tolerance wide enough to admit the reference's. That test is one of the "checking that your code agrees with itself" cases `CONTRIBUTING.md:33` warns about.

---

## 6. Implementation guidance (nothing here was applied)

**6.1 `src/engine/params.odin:524-556`.** The law is confirmed; the comment is now partly wrong and the value can be sharpened.

- Keep the assignment and the sign. Add that they are now established *absolutely* rather than by difference: oscillator 1 reads 0.000 ± 0.002 for all four shapes, oscillator 2 reads +0.5623, and the mirror is rejected at −97 dB of superposition residual on the reference's own two-oscillator render.
- **Correct the `9/16` sentence** (`params.odin:550-553`): it is excluded at 14 sd, not indistinguishable.
- **Optionally set the constant to `f32(0.56233)`** — the reading is 0.562334 ± 0.000012 and CONTRIBUTING asks for the measured value. The bank cannot see the difference (§7), so this rests entirely on the reading, which is the correct footing. Holding `0.5623` is also defensible; what is not defensible is leaving the comment claiming `0.5625` might be it.
- Record the method, because it is what makes the sign readable: absolute harmonic phase against frame 0, latency separated by the note dependence, and the offset taken as a difference inside one engine so the shape convention and the latency cancel.

**6.2 `src/engine/voice.odin:189-212`.** The prose is now understated rather than wrong. "The distance is read off the reference's own first cycles … the falling edges of a fast-attack saw" describes a method that fixed the magnitude; the sign and the assignment now come from the absolute reading. Worth adding one sentence that the offset is shape-independent to 1×10⁻⁵ and that the reference's oscillator 1 is genuinely at zero, so nobody re-opens the per-shape hypothesis.

**6.3 Do not touch `src/dsp/oscillator.odin`.** The triangle's quarter turn and the pulse's `1 − pw` are confirmed absolutely, per shape and at eight pulse widths, to 2×10⁻⁴ turns.

**6.4 Optional, separately justified (§5):** `binding.odin:589` `OSC_PHASE_MAX_TURNS * v/127` → `0.5*(v−1)/126`, and the `−0.00125` common phase in the fixed branch of `voice.odin:173-183`. Neither can be gated on the bank; both need the reading in the comment and a test. If the second is skipped, say in the comment that it was measured at `−0.00125` turns and left out because a common start phase is inaudible in isolation — do not leave it unrecorded.

**6.5 The 033 note is now a diagnosis, not a phase question.** The next defect in that chain is the oscillator modulation envelope on oscillator 2's pitch: 21 of the 128 factory patches run it (016, 027, 028, 029, 030, 031, 032, 033, 035, 046, 047, 048, 053, 055, 062, 107, 108, 114, 119, 126, 127 — all with dest 0). Three of the four largest envelope regressions D2 produced (033 +4.58, 062 +1.74, 032 +1.22, against 069 +1.36) are in that set of 21, and 047 Harp — the "worse on three metrics at once" regression at `docs/null-test.md:4574` — is in it too. The group *means* do not separate (mean Δenvelope −0.055 for the 21 against −0.003 for the other 102), so the modulation envelope is not a universal explanation for D2's regressions; it is the demonstrated explanation for 033, and a strongly enriched suspect for the rest.

---

## 7. Gates

All figures from `build/s1probe.exe` and the scratch variants, run from the repository root against the same DLL and the same isolated 123-patch bank this session.

**HEAD baseline reproduces `docs/null-test.md` exactly** (`build/rp2/bank-head.csv`, 123 rows, 0 reference-silent, 0 ours-silent, 0 failed to load, floor 0.00 on every metric):

| metric | this session | `docs/null-test.md:4542-4552` |
|---|--:|--:|
| spectral mean / median (119 valid) | 6.6538 / 5.9766 | 6.6538 / 5.9766 |
| envelope mean / median | 2.0956 / 1.7701 | 2.0956 / 1.7701 |
| level, mean absolute / signed median | 1.6529 / +0.0464 | 1.6529 / +0.0464 |
| null depth mean / median | −6.6565 / −6.0802 | −6.6565 / −6.0802 |
| correlation mean | 0.7607 | 0.7607 |

**033 and 029 at HEAD, reported explicitly as required:**

```
033.sy1  spectral 8.51 (worst band 76 Hz, 25.9 dB)  envelope 5.99  level -0.66  null -0.99
         time to peak ref 10 ms / ours 45 ms;  correlation 0.4361
029.sy1  spectral 4.52 (worst band 190 Hz, 23.0 dB) envelope 1.24  level -0.01  null -5.91
         time to peak ref 5 ms / ours 10 ms;   correlation 0.8624
```

**The refinement to `0.56233` moves nothing** (`build/rp2/bank-VD.csv`): spectral 6.6537 / 5.9766, envelope 2.0957 / 1.7701, |level| 1.6529, null −6.6564 / −6.0802, correlation 0.7607. Largest per-patch change on any metric **0.004 dB** (127 envelope +0.004; 039 null +0.003; 029 envelope −0.002; 033 envelope +0.002). **The bank cannot choose between 0.5623 and 0.56233 — which is the point: the reading must, and does.** If the implementation adopts the refinement, this is the expected "after"; regressions to name: none above 0.004 dB.

**What the mirror would cost, reported as a consequence and not as the selection criterion** (`build/rp2/bank-VB.csv`, `osc2 = 0.4377`):

| metric | HEAD | mirror | change |
|---|--:|--:|---|
| spectral mean | 6.6538 | 6.7487 | +0.095 |
| envelope mean / median | 2.0956 / 1.7701 | 2.3792 / 1.9018 | +0.284 / +0.132 |
| level, mean absolute | 1.6529 | 1.7566 | +0.104 |
| null depth mean / median | −6.6565 / −6.0802 | −5.4430 / −4.2873 | **1.21 / 1.79 dB shallower** |
| correlation mean | 0.7607 | 0.7089 | −0.052 |

Worst under the mirror: null 039 +11.92, 038 +8.48, 112 +8.30, 007 +7.34, 044 +6.35, 042 +6.32, 043 +6.21, 004 +5.73; envelope 038 +8.35, **029 +7.89**, 002 +2.62, 102 +2.17, 004 +1.73. Its only material gain is **033 −4.60** envelope, which §4 attributes to the modulation envelope.

**Test suites at HEAD, this session:** `odin test tests/dsp` 77 passed, `odin test tests/clap` 36 passed, `odin test tests/patch` 28 passed.

**Remaining gate commands from `CONTRIBUTING.md:46-64`, not run this session** (nothing was changed, so there was nothing to gate): the four host builds plus `node hosts/wasm/check-imports.js`, and `odin run tools/uiparams` if a measured table in `src/engine` changes. Note that `OSC_PHASE_FREE_TURNS` does not appear in `ui/params.js` (the generated table carries parameter displays), but `binding.odin`'s parameter-91 law would — regenerate if §6.4 is taken. `tools/sy1check/check.js` is not implicated: `src/patch/sy1.odin` is untouched.

---

## 8. The test guard

The existing pin (`tests/dsp/dsp_test.odin:2251-2301`) is already signed, which is the important half, and its comment already carries the lesson. Two things are wrong with it as an external check: line 2298 asserts the reading `0.5623 ± 0.001`, a tolerance that also admits `9/16`, which the reference now excludes; and it exercises **only the saw**, so a per-shape offset in the code would pass.

Externally-anchored numbers available to assert, all measured this session against `Synth1 VST64.dll`:

1. **The constant.** `abs(OSC_PHASE_FREE_TURNS − 0.562334) < 0.0001`. A pure constant comparison, no rendering, so the tolerance can be the reading's. ±0.0001 is 8× the measurement's own spread and **excludes both `9/16 = 0.5625` (0.000166 away) and the mirror**. Comment must carry: 90 readings, 5 notes over four octaves × 3 shapes × harmonics 1–7, 48 kHz and 96 kHz, sd 1.2×10⁻⁵, method bias +2.3×10⁻⁶ established against this engine's own known constant.
2. **Shape independence.** Repeat the existing signed rendered-offset check with a **triangle pair and a pulse pair** as well as the saw. The reference reads the same offset for all three to 1×10⁻⁵ (§3.2), so a shape-specific offset fails. This is the assertion that would have refuted the per-shape hypothesis before it was raised.
3. **The assignment.** Assert that oscillator **1** alone renders the *same* fundamental phase whichever of sine, saw and triangle it is set to — the reference reads the three equal to 0.0002 turns (§3.1) — and that this phase does not move when parameter 5 is swept. That pins "the offset belongs to oscillator 2", which no cancellation depth can see.
4. **The pulse's duty and start phase together**, from §3.5: `phase(pulse) − phase(saw)` at `k=1` must equal the reference's measured `−0.23437, −0.21069, −0.19311, −0.16161, −0.12402, −0.07299, −0.03368, −0.00610` at stored widths 8, 20, 29, 45, 64, 90, 110, 124, to about 0.0005 turns. Eight widths, the reference's own numbers, and it fails on either a duty complement or a start-phase error.
5. **If §6.4 is taken**, replace the `{48→0.189, 64→0.252, 127→0.500}` expectations at line 2113 with the reference's `{16→0.059524, 32→0.123016, 48→0.186508, 64→0.250000, 96→0.376984, 127→0.500000}` and tighten the tolerance to 0.0005. The current numbers are the code's own.

The existing helpers are sufficient: `fundamental_phase` (`dsp_test.odin:2217`) returns a signed phase in turns, and `render_phase_patch` (2090) renders one block from a note-on — enough for 1–4. Keep `test_oscillator_phase_offset_is_between_the_oscillators` as it is; the comment at 2231-2242 explaining *why* it cannot catch a sign is the most valuable prose in the file.

---

## 9. Docs

**`docs/null-test.md:4570-4574`**, the bullet to replace:

> - **033 Acoustic Bass, envelope 1.41 → 5.99 dB.** The largest single regression and the only one that creates a new top-five envelope entry (z 2.57 after). Attributed entirely to D2 — D1 and D3 leave it at 1.41 — and **not diagnosed**. It is the one result here that would justify holding the change.

It must now say that D2 is right and that 033's regression is the oscillator modulation envelope on oscillator 2's pitch, with the isolation numbers (033 `10=0`: envelope 5.99 → 0.67, null −0.99 → −11.69; 033 reduced to oscillator 2 alone still nulls at −0.30 dB with the two candidate phases 0.03 dB apart; a bare oscillator carrying only 033's modulation records nulls −11.79 against −22.47 with them off), and that 21 factory patches run that envelope.

Three more places in the same document need the same edit, or they will contradict the new note:

- **`4509-4514`** — the `9/16` hypothesis: now excluded at 14 sd.
- **`4633-4636`** — "Still open: 033 Acoustic Bass's +4.58 dB envelope regression, located to D2 and not explained": closed, and replaced by the modulation envelope as the next named defect.
- **`925-935`** — "Fitting it from how far each harmonic is pulled down gives 158 degrees … It was kept at that 0.440 turns rather than tuned": stale in the parent's tense, and the "158 degrees" fit is the method whose sign-blindness this whole thread is about.

Worth adding, because it is the reusable part: the reading is absolute because frame 0 is note-on in both renders, and a start phase separates from a latency by its note dependence.

---

## 10. Found while measuring, out of scope, with numbers

Reported so they are not lost, and explicitly **not** part of this objective. Each needs its own session.

1. **The oscillator mix is `stored/127`, not the displayed percentage.** From the superposition fits, the reference's gains are exactly `osc2 = stored/127`: 32 → 0.2520 (32/127 = 0.251968), 64 → 0.5040 (0.503937), 96 → 0.7560 (0.755906), with `osc1 = 1 − stored/127`. Our engine reads the display's rounded integer percentages (0.25, 0.50, 0.76). Up to 0.07 dB on every two-oscillator patch — small, systematic, and `docs/null-test.md:888-892` states the law as "equals the displayed percentage", which is the rounding of the real one.
2. **The sub oscillator produces nothing at `f0/2` in the reference.** Sub gain 110, shape sine, octave "−12", note 60: our render carries 0.414 at `f0/2`; the reference carries 1.4×10⁻⁶ — nothing — and its `f0` component instead rises from 0.310 to 0.447. `param_mismatches = 0`, so the reference accepted parameters 95/96/97 and reports the same normalised values back. Our render nulls at −0.76 dB against it (spectral 7.86) where the same patch without the sub nulls at −28.55. **No patch in `soundbank00` sets parameter 95**, so the bank cannot see this at all, and `voice.odin`'s `sub` start phase cannot be validated on it either. Whether our 95/96/97 mapping is wrong or the reference's sub needs something else enabled is not established.
3. **A uniform ~0.15 dB level deficit at amp gain 100.** Single-oscillator renders, note 48 and 60: reference fundamental 0.3099 against ours 0.3045 for the saw, 0.1085 against 0.1069 for the pulse at width 29 — 1.3–1.8 %, consistent across shapes, widths and notes. Unexamined; the bank's signed level bias is +0.17 dB, so this is not obviously the same thing.

---

## 11. Caveats and what is not established

- **The absolute readings carry ~0.001 turns of systematic uncertainty**, because the shape convention is calibrated from our own oscillator 1 at note 36 where our fit still shows +0.001 turns of apparent latency. That is 100× smaller than the question it answers (0.125 turns) and 100× larger than the *difference* measurement in §3.2, which is bias-free to 2×10⁻⁶.
- **Everything here is the fresh-voice case** — one plugin instance, one note-on, no note history, which is the condition the null test renders under. `params.odin:544-548` already caveats it and the caveat still stands: a host that has had the plugin running for minutes could find genuinely free-running oscillators elsewhere. `voice.odin:184-188` covers that path and is not measured here.
- **The reference's fitted latency is small and not identical to ours** (−0.36 samples against +0.77 at 48 kHz, both from the same fit; the plugin itself reports 0 samples of initial delay). It is common to both oscillators and all four shapes, so it cancels out of every claim above, but it is not explained — probably the filter's group delay at maximum cutoff differing between the two engines.
- **32 kHz was not attempted.** The previous session recorded that the reference renders silence through this harness at that rate; I did not re-check it.
- **069's residual +6.18 dB is still the filter envelope**, as already documented, and I did not advance it.
- **The `10^(−1/4)` coincidence is a coincidence** until something else supports it. Daichi's own account of the oscillator (below) gives a 16:16 fixed-point phase into a 2048-entry table, i.e. `2^27` steps per turn; 0.562334 is 75,475,000-odd of those and lands on no round value, and `9/16` — which *would* be round (`1152 << 16`) — is excluded by the reading. Where the constant comes from is therefore **not established**.
- **Which of D2's other regressions the modulation envelope explains is not established.** The enrichment at the top of the list is real; the group means do not separate.

---

## 12. Online grounding

Used to interpret, never to override.

- **Daichi's own account of the oscillator section** (https://daichilab.sakura.ne.jp/synthprog/index.html, fetched this session): waveforms are generated by **wavetable lookup with first-order interpolation**, not BLIT — "波形の生成には、WAVEテーブル参照方式＋一次補間を使っている" — with **one table of 2048 float samples**; the phase variable is an **unsigned 16:16 fixed point** masked with `2048*(1<<16)-1`, so a turn is `2^27` steps; the **pulse has no table of its own** and is made by differencing two saws shifted against each other, the shift setting the width; FM is accumulated into oscillator 1's phase (`osc1_phase = osc1_phase + osc1_delta + _FLOAT2INT(osc2_out * fmAmount * 2048/2 * (1<<16))`). This corroborates the pulse model confirmed in §3.5 and the FM direction already in `oscillator.odin:107-119`, and it is why a per-shape start phase was a reasonable hypothesis at all — a table-based oscillator carries whatever phase its table was written at. The measurement says all four tables were written at the same phase, which is also what §3.1 shows.
- **The vendor manual and the v1.0.9 changelog** on parameter 91 (https://daichilab.sakura.ne.jp/softsynth/synmanu/readmeeng.html; https://www.kvraudio.com/news/ichiro_toda_updates_synth1_to_v1_0_9_14286): *"The 'phase' knob in the Oscillators section immobilizes phase relations in the trigger of oscillator 1 and oscillator 2 and adjusts it. The phase is not fixed if you turn a knob to the left (like conventionally)."* A **relation**, and zero means not fixed — which is what `binding.odin` implements and what §5 measured. Robert Heaton's unofficial manual (https://robertheaton.com/2019/04/21/synth1-unofficial-manual/) says the same and adds that the change is only heard on the next key press, consistent with a note-on-time assignment.
- **The published documentation says nothing about a free-run offset**, and calls the knob-at-zero case "entirely unfixed". The reference is nevertheless bit-reproducible at +0.562334 after a fresh load — so the documentation is not wrong, it is describing a different condition, and the caveat in `params.odin:544-548` is the right way to hold both.
- Standard start-phase conventions (STK's BLIT `reset()` to phase 0, wavetable oscillators initialising phase to zero, DPW saws with drifting phase) predict *either* every shape starting at table index 0 *or* per-shape offsets baked into the tables. The measurement picks the first, for all four shapes, in both oscillators.

---

## 13. Reproducing this

Scripts and renders are under `build/rp2/` (gitignored, ~495 MB, discardable). Each script carries its method in a header comment.

```
odin build tools/s1probe -out:build/s1probe.exe                  # never measure with a stale probe

# probe patches, written from the reference's own defaults so no absent record
# can mean "whatever zero happens to be" on either side
node build/rp2/mkprobe.js build/rp2/p "o1saw:0=1,5=0" "o2saw:1=1,5=127" ...
for n in 36 48 60 72 84; do
  ./build/s1probe.exe compare build/rp2/p/<patch>.sy1 --note $n --wav build/rp2/w$n --no-floor
done

node build/rp2/fit.js    build/rp2/w 36,48,60,72,84 o1saw:saw o2saw:saw ...   # absolute, latency fitted out
node build/rp2/offset.js build/rp2/w 36,48,60,72,84 saw tri pulse             # the signed offset, 1e-5
node build/rp2/pair.js   build/rp2/w60 60 prsaw25:75:25:o1saw:o2saw ...       # superposition + mirror rejection
node build/rp2/agg.js    build/rp2/bank-head.csv build/rp2/bank-VD.csv        # bank aggregates and per-patch deltas
```

Variant binaries, each one source line from HEAD, all built from `C:\Users\lamag\Code\synth-rp2` and run from the repository root: `build/rp2/VA.exe` HEAD (bit-identical output to the working-tree probe), `VB.exe` the mirror `osc2 = 0.4377`, `VC.exe` the global shift `osc1 = 0.4377, osc2 = 0`, `VD.exe` the refined `0.56233`, `S96.exe` HEAD at 96 kHz. Bank CSVs: `bank-head.csv`, `bank-VB.csv`, `bank-VD.csv`.