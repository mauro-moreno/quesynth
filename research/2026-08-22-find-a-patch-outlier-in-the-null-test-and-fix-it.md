# Research: the patch outlier in `build/nulltest-fm-fix.csv`, and what produces it

**Answer in one line.** The outlier is **`126.sy1` "Machine Gun"** (envelope error 18.69 dB). The subsystem is the **tempo delay's beat-division parser**, not the arpeggiator, not the envelope, not FM: `delay_display_beats` in `src/engine/binding.odin:343-345` reads the reference's `/3` notation as the musician's triplet (× 2⁄3) instead of the division the reference actually performs (÷ 3), so **every `/3` delay time is exactly 2× too long**. Fixing that one line takes 126's envelope error from **18.69 dB → 2.82 dB** and improves the isolated 123-patch bank overall.

Everything below was produced this session by driving `ext/synth1/Synth1/Synth1 VST64.dll` through `tools/s1probe`. The `--self` control ran at zero (`null −240.00 dB`, spectral/envelope/level `0.00`).

---

## 1. Which patch is the outlier, and why the other candidates are not

Statistics over the 123 rows in `build/nulltest-fm-fix.csv` (verified: mean spectral 6.5494, mean envelope 2.6730, matching the brief):

| metric | leader | value | z-score | multiples of IQR above Q3 |
|---|---|---:|---:|---:|
| `envelope_db` | **126.sy1** | **18.69** | **+7.04** | **9.50** |
| `envelope_db` | 029.sy1 (2nd) | 9.08 | +2.81 | 3.70 |
| `spectral_db` | 088.sy1 | 16.72 | +2.44 | 1.04 |
| `spectral_db` | 086 / 001 | 16.68 / 16.30 | +2.43 / +2.34 | 1.04 / 0.98 |
| `abs(level_db)` | 069.sy1 | 10.99 | +4.57 | — |

- **126 is the only genuine outlier.** Nothing else in the table is within a factor of two of its z-score, and it is the only value beyond even the 3.0×IQR fence (7.93) by more than a small margin.
- **088 / 086 / 001** are the top of a smooth spectral distribution — all three sit *inside* the ordinary 1.5×IQR fence (19.84 dB). They are the worst patches, not outliers. Their attack columns (`ref_attack_ms` vs `our_attack_ms`) are "time to loudest frame before note-off", which on a slow pad is a plateau argmax and not an attack law; treating "measured attacks roughly double the reference's" as a defect signal would be reading noise.
- **069** is the clearest *level* outlier (z = +4.57) and is a separate, real finding, but level bias is the metric CONTRIBUTING treats as separable by construction (`analysis.odin:24-26`).
- **119** and **120** are both delay-adjacent (see §6) but neither is a distributional outlier; `120`'s `spectral_valid=false` is not a defect at all — `ref_steady_rms = 2.4e-7`, `our_steady_rms = 1.2e-6`, i.e. *both* renders have decayed below the −100 dBFS sustain threshold (`analysis.odin:142-150`), exactly as for 113/115/116. There is no timbre to compare.

---

## 2. What 126 is, and the repo's own standing note about it

`ext/synth1/Synth1/soundbank00/126.sy1`, `ver=105`, name `Machine Gun`. Relevant records:

```
59,1  arpeggiator on      31,1 type up-down   32,0 one octave
33,15 arp beat = "(8) /3" = 1/6 beat = 83.33 ms at 120 BPM
34,16 arp gate  = 16/127 = 0.126 duty
65,1  delay on            35,2 delay time = "(16) /3"
36,21 feedback            37,73 dry/wet (→36 after the ver=105 conversion)
38,1  play mode mono      45,75 FM         66,0 chorus off
```

`docs/null-test.md:3914-3918` already flags this patch and says the cause is unknown:

> "126 is the one that got worse … its envelope error went from 8.58 dB to 17.83 dB, which is a real regression on that metric and **is not explained yet**. It is the fastest of the three, at `(8) /3` and a gate of 16, so the suspicion is the voice allocated per step against a release that outlasts the step."

**That suspicion is wrong.** Voice allocation is fine (§4).

---

## 3. The measurement chain that locates the defect

### 3.1 The reference's envelope has twice the onset rate ours does

`s1probe compare … --wav`, 5 ms RMS frames, two-threshold onset detector (the same method `docs/null-test.md:3838-3845` establishes):

```
ref onsets (ms): 0 40 80 125 165 210 250 295 330 375 415 460 500 545 ...   median step 41.6 ms
our onsets (ms): 0 85 165 250 335 415 500 585 665 750 835 915 1000 ...     median step 83.3 ms
```

### 3.2 The arpeggiator is not responsible

Rendering 126 with the **delay off** (`65,0`), reference and engine agree exactly:

| variant | reference median step | ours | envelope_db |
|---|---:|---:|---:|
| delay off, arp as-is `(8)/3` | 84.0 ms | 84.0 ms | **4.36** |
| delay off, arp beat → 14 `(16)` | 126.0 ms | 126.0 ms | — |
| delay off, arp beat → 17 `(16)/3` | 42.0 ms | 42.0 ms | — |
| delay off, arp off | — | — | **1.06** |
| delay off, gate → 64 | 84.0 ms | 84.0 ms | 2.39 |
| delay off, gate → 127 | — | — | 2.48 |
| **as-is (delay on)** | **41.6 ms** | **83.3 ms** | **18.69** |

`ARP_STEP_BEATS` (`src/engine/arpeggiator.odin:29-49`) is correct at every state tested, including its own `/3` entries, and the gate law survives its extremes. Turning the delay off alone removes 14.3 dB of the 18.69.

### 3.3 Direct sweep of the reference's delay-time law — the decisive number

A purpose-built probe patch (percussive click, `37,127` = 100 % wet, `36,0` = no feedback, `82,0`, `83,64` = no spread, `98,64` flat, arp/chorus/effect/LFO/unison all off, written as `ver=113` so the pre-1.07 conversion cannot interfere), swept over all 20 states of parameter 35 at the harness's 120 BPM (`tools/s1probe/main.odin:46`). First-sample-above-threshold gives the delay time directly:

| state | display | reference | ours (current) | ours ÷ ref |
|---:|---|---:|---:|---:|
| 0 | `0.1 msec` | 0.2 ms | 0.2 ms | — |
| **1** | **`(32) /3`** | **20.9 ms** | **41.8 ms** | **1.997** |
| **2** | **`(16) /3`** | **41.8 ms** | **83.4 ms** | **1.999** |
| 3 | `(32)` | 62.6 ms | 62.6 ms | 1.000 |
| **4** | **`(8) /3`** | **83.4 ms** | **166.8 ms** | **1.999** |
| 5 | `(16)` | 125.1 | 125.1 | 1.000 |
| **6** | **`(4) /3`** | **166.8 ms** | **333.4 ms** | **2.000** |
| 7 | `(16)+(32)` | 187.6 | 187.6 | 1.000 |
| 8 | `(8)` | 250.1 | 250.1 | 1.000 |
| **9** | **`(2) /3`** | **333.4 ms** | **666.8 ms** | **2.000** |
| 10–12 | `(8)+(16)`, `(8)+(16)+(32)`, `(4)` | 375.1 / 437.6 / 500.1 | identical | 1.000 |
| **13** | **`(1) /3`** | **666.8 ms** | **1333.4 ms** | **2.000** |
| 14–19 | `(4)+(8)` … `(1)` | 750.1 … 2000.1 | identical | 1.000 |

**All six `/3` states are exactly 2× too long; all fourteen others are exact.** In beats the reference's law is unambiguous: `(32)/3` = 0.0418 = 0.125/3, `(1)/3` = 1.3335 = 4/3. That is division by three, and `(2/3) ÷ (1/3) = 2` is precisely the observed factor.

### 3.4 Why 126 specifically explodes

126's arp step is `(8)/3` = 83.33 ms and its delay is `(16)/3` = 41.67 ms — the reference places one echo exactly *halfway between* steps, doubling the perceived onset rate. Our doubled delay time is 83.33 ms, which lands **exactly on the next step**, so the echo vanishes into the step it should have preceded. At gate 16/127 the duty cycle is 0.126, so a peak-normalised, −60 dB-floored 5 ms-frame envelope comparison (`analysis.odin:625-661`) is being asked to match a burst against a gap for most frames. That is the maximal-punishment configuration, and it is why 126 is 18.69 dB while the other triplet-delay patches sit at 5–9 dB.

Sweeping only 126's delay time confirms the mechanism, holding everything else fixed:

| 126 with delay state → | 3 `(32)` | 5 `(16)` | 10 `(8)+(16)` | 7 `(16)+(32)` | 0 `0.1 ms` | 8 `(8)` | 13 `(1)/3` | 9 `(2)/3` | 4 `(8)/3` | 6 `(4)/3` | 1 `(32)/3` | **2 `(16)/3` (actual)** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| envelope_db | 2.63 | 2.84 | 2.94 | 3.03 | 4.56 | 4.95 | 5.33 | 6.09 | 6.76 | 7.21 | 9.15 | **18.69** |

Plain states mean 3.49 dB; triplet states mean 8.87 dB; the resonant one is 18.69.

---

## 4. The corrected law

`src/engine/binding.odin:306-347`, `delay_display_beats`:

```odin
	if triplet {
		total *= 2.0 / 3.0      // ← wrong: the musician's triplet
	}
```

must become the reference's own division:

```odin
	if triplet {
		total /= 3.0
	}
```

This is a **one-line change** and it makes the delay agree with a law this repository already measured and already stores correctly two files away. `src/engine/arpeggiator.odin:20-23` states it outright:

> "`(N) /3` is that value divided by three … it is *not* the usual triplet convention — a musician writing 'quarter triplet' means two thirds of a quarter, while the reference means one third of it. `(1) /3` measured 1.332 beats … two thirds of a whole note would have been 2.667."

and `ARP_STEP_BEATS` encodes `4.0/3.0`, `2.0/3.0`, `1.0/3.0`, `1.0/6.0`, `1.0/12.0`, `1.0/24.0`. The two subsystems parse the **same nineteen-symbol notation** — parameter 33 and parameter 35 share it, and the vendor changelog even treats them as one display (`docs/synth1-readme-eng.txt:473`, Ver1.11: *"change delay arpegiator tempo display"*). The delay's parser was written to a guessed convention, and the guess was recorded as fact in two comments: `src/dsp/delay.odin:7-8` ("`/3` a triplet") and `ui/layout.js:356` ("a slash three is a triplet").

**Corroboration outside the null test.** The vendor manual (`docs/synth1-readme-eng.txt:186`) describes parameter 35 as *"ranging from 1/32 note triplets to whole note"*. A standard 32nd-note triplet is 1/48 note = 0.0833 beats; the reference's state 1 measures **0.0418 beats = 1/96 note = (1/32)/3**. The vendor's label is loose musical shorthand and the arithmetic is literal division — which is exactly the trap the arpeggiator section already documented, and exactly what would happen to anyone implementing from the manual's prose. The same manual entry (line 184) gives the delay a 3-second maximum buffer; the fix only ever *shortens* times, so no buffer-length consequence.

Nothing else changes: state 0 (`0.1 msec`) still takes the non-musical branch, the sum-of-parentheses arithmetic is untouched, and `delay_spread_ms`, feedback, dry/wet, tone and mode are all unaffected.

---

## 5. Measured effect on the bank (counterfactual run, already performed)

I applied the one-line change in a **scratch copy of the repository outside the workspace** (since deleted; `C:\Users\lamag\Code\synth` is byte-identical to `08c2dc0`, `git status --porcelain` empty) purely to obtain the numbers CONTRIBUTING requires, and ran the full isolated bank both ways with the same build of `tools/s1probe`. The five reference-crashing patches (095, 098, 100, 101, 106) were excluded automatically by `--isolate`; both runs reported them and completed. The baseline run reproduced `build/nulltest-fm-fix.csv` exactly (126: 6.11 / 18.69 / −3.16 / −0.05), confirming that CSV is current for `HEAD`.

**Both CSVs are on disk for the implementation stage** (gitignored):
`build/research-2026-08-22/nulltest-base.csv` and `build/research-2026-08-22/nulltest-delay-triplet-fix.csv`; the 20 probe patches are in `build/research-2026-08-22/delay-division-probe-patches/`.

### Aggregate, 123 patches

| metric | before | after | change |
|---|---:|---:|---|
| spectral mean | 6.5494 | **6.5399** | −0.0095 |
| spectral median | 6.0397 | **6.0277** | −0.0120 |
| envelope mean | 2.6730 | **2.5025** | **−0.1705** |
| envelope median | 2.0627 | 2.0627 | unchanged |
| null depth mean | −3.9574 | **−3.9634** | 0.006 dB deeper |
| correlation mean | 0.6077 | 0.6083 | +0.0006 |
| level bias (signed mean) | +0.2073 | **+0.1928** | closer to zero |
| level error (mean abs) | 1.9095 | 1.9255 | **+0.0160 worse** |
| stereo width delta mean | −0.0236 | −0.0237 | flat |

Every CONTRIBUTING gate metric improves except mean-absolute level, which worsens by 0.016 dB — that is entirely 126 and 114 moving their echoes and is named below rather than hidden.

### Per patch — only 6 of 123 move at all

| patch | Δ spectral | Δ envelope | Δ level | note |
|---|---:|---:|---:|---|
| **126 Machine Gun** | **−1.08** (6.11 → 5.03) | **−15.87** (18.69 → **2.82**) | −1.09 | the outlier, eliminated |
| **011 MusicBox** | −0.01 | **−4.47** (8.01 → 3.54) | +0.02 | was rank-4 envelope |
| **093 Sweep pad 2** | **+0.62** (9.86 → 10.48) | −2.84 (5.98 → 3.14) | −0.16 | **named regression** |
| **114 kick1** | −0.47 | −0.40 | −0.90 | |
| **127 LaserGun** | −0.24 | **+0.30** | +0.02 | minor regression |
| **119 SynDrum** | +0.03 | **+2.30** (2.96 → 5.26) | +0.24 | **named regression**, see §6 |
| 007, 121, 123 | 0.00 | 0.00 | 0.00 | triplet delay, but dry/wet 0 % or inaudible |
| other 114 patches | 0.00 | 0.00 | 0.00 | no triplet delay state |

**Named regressions: 119 (envelope +2.30), 093 (spectral +0.62), 127 (envelope +0.30).** Counts: spectral 3 improved / 1 regressed / 119 unchanged; envelope 4 improved / 2 regressed / 117 unchanged.

Nine factory patches carry a triplet delay time with the delay on: 126, 011, 121, 093, 123, 119, 127, 114, 007. Five of them are in the bank's top-12 envelope errors.

### Why 119 regresses — a second, pre-existing delay defect

119's envelope error lives entirely in the delay and is **not** caused by the fix:

| 119 variant | envelope (before) | envelope (after) |
|---|---:|---:|
| delay off | 1.18 | 1.18 |
| delay state → 3 `(32)`, a *non*-triplet | 4.34 | 4.34 |
| as-is (`(32)/3`) | 2.96 | 5.26 |

With the delay off both builds are identical. With a plain delay state both builds are identical **and worse than the as-is baseline** (4.34 vs 2.96). The old 41.8 ms placement was accidentally flattering; putting the echo where the reference puts it (20.9 ms) exposes a separate defect in what the delay *does* once it is there. That defect is worth chasing next but is not this fix's regression to own.

---

## 6. The other candidates, attributed

- **119's stereo width (0.277 → 0.018)** — attributed to the **delay**, not unison or chorus. `s1probe compare --verbose` on 119: delay off gives width 0.000/0.000; chorus off gives 0.052/0.018; as-is gives 0.277/0.018. The reference's normal-stereo delay decorrelates the channels strongly even at `83` default spread (`0.1 : 0.0 msec`) with feedback 0; ours barely does. A focused width sweep I ran (mono click, 100 % wet, feedback 100, `(8)` = 250 ms) shows the disagreement is real but does not by itself explain 119's *narrowness*:

  | param 83 | 0 | 32 | 64 | 66 (default) | 96 | 127 |
  |---|---:|---:|---:|---:|---:|---:|
  | ref side/mid | 0.965 | 0.912 | 0.000 | **0.269** | 0.912 | 0.965 |
  | ours | 0.965 | **1.208** | 0.000 | **0.847** | **1.208** | 0.965 |

  | param 82 (at 83 = 66) | 0 stereo | 1 cross | 2 ping-pong |
  |---|---:|---:|---:|
  | ref side/mid | 0.269 | 0.071 | 1.000 |
  | ours | 0.847 | 0.263 | 1.000 |
  | level | −1.11 dB | +0.67 dB | **+6.93 dB** |

  Endpoints and the exact centre agree; everything in between does not, and ping-pong is +6.9 dB hot. **Open finding, own investigation.**

- **069 (+10.99 dB level, 11.45 dB spectral)** — unrelated to the delay; unchanged by the fix. The clearest remaining level outlier in the bank.
- **088 / 086 / 001** — unchanged by the fix; a smooth spectral tail, not outliers.
- **120** — not a defect: both renders are legitimately below the sustain threshold, so `spectral_valid=false` is the metric declining to report, as designed.

---

## 7. Implementation guidance

**The change**
1. `src/engine/binding.odin:343-345` — `total *= 2.0 / 3.0` → `total /= 3.0`. Replace the surrounding comment with the measured law and cite the sweep, in the house style ("comments say why"): the reference divides by three, the musician's triplet is two thirds, and this is the same law as `ARP_STEP_BEATS`.
2. `src/dsp/delay.odin:7-8` — the header comment calls `/3` "a triplet". Correct it; it is the seed of the defect.
3. `ui/layout.js:356` — tooltip says "a slash three is a triplet". Correct it. Line 533 (arp beat) is already neutral.

**The test that must change — and the trap**
`tests/dsp/dsp_test.odin:1186-1219` (`test_delay_division_displays_parse_to_beats`) **currently asserts the wrong law**: its comment at line 1180 says "`/3` takes two thirds" and its cases are `{"(32) /3", 0.125 * 2.0/3.0}`, `{"(4) /3", 2.0/3.0}`, `{"(1) /3", 8.0/3.0}`. Verified: unmodified repo → 73 tests, all pass; with the fix → 73 tests, 1 fails, on exactly those three cases. This is CONTRIBUTING's named trap in its second form — the test checked the parser against a *convention someone assumed*, not against the reference, so it could never fail. Rewrite the three cases to the DLL-measured beats (0.0416667, 0.333333, 1.333333) and say in the comment where the numbers came from.

**The regression guard CONTRIBUTING asks for.** Add a `tests/dsp` test that ties the delay's division table to the measurement and to the arpeggiator, so the two can never drift again. The strongest form external to the code under test is: for each of the six `/3` displays, assert `delay_display_beats(display)` equals the **corresponding entry of `ARP_STEP_BEATS`**, which is an independently measured table, and additionally assert the six absolute beat values from the §3.3 sweep. A test asserting only self-consistency between the two parsers would repeat the trap; anchoring on the measured constants is what makes it a check.

**Also run** (from CONTRIBUTING's list): `odin test tests/clap`, `odin test tests/patch`, the four host builds, and `node hosts/wasm/check-imports.js`. `odin run tools/uiparams` is **not required** — verified: `ui/params.js` is byte-identical after the change, because it carries display strings, not the law.

**`docs/null-test.md` write-up.** The right place is a new section after "The arpeggiator, measured and implemented", and it must go back and settle the open note at lines 3914-3918: the per-step voice-allocation suspicion is disproved (126's envelope with the arp on and any non-triplet delay state is 2.6–5.0 dB), and the real cause is that the arp's step period was exactly twice the delay's mis-scaled time. The write-up should carry the full 20-state sweep table (§3.3), the bank before/after (§5), the three named regressions, and the 119 stereo-width finding as explicitly still open.

**Prediction to check against.** After the fix the bank should read spectral mean/median **6.54 / 6.03**, envelope mean **2.50**, null depth **−3.96**, level bias **+0.193**, with **126 at 5.03 / 2.82 / −4.25**. If an implementation produces different numbers, something other than this one line changed.

---

## 8. Caveats and what is not established

- The scratch build used to obtain §5 was deleted; the two CSVs are the surviving evidence. The implementation stage should regenerate them rather than trust the copies.
- All timings are at the harness's fixed 120 BPM and a single held note 60. The `/3` factor is a ratio and is tempo-independent by construction, but no other tempo was tested.
- `docs/null-test.md:4227-4228` states the post-FM-fix bank spectral mean/median as **6.77 / 6.23**; the CSV it refers to, and my reproduction of it at `HEAD`, both give **6.5494 / 6.0397**. Envelope (2.67) and null depth (−3.96) match the doc exactly. **The doc's spectral figures appear stale or mis-transcribed**; worth correcting in the same edit. Unverified which of the two is the typo.
- The 119 stereo-width and 069 level findings are located but not diagnosed. Neither is required by this fix.
- I did not attempt to explain 029, 053 or 089 (envelope ranks 2, 5, 6); they are unaffected by this change.

## Contract amendments received

None. No mid-run user message amended the objective or acceptance criteria.