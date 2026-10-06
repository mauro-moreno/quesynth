# Synth1 behaviour errors: implementation notes

Working notes for branch `fix/synth1-behavior-errors` (from `main` at 36481ee),
goal run 610ca2c3-1c16-49a8-ac10-3b180a815061. They record what was asked, what
was measured on the reference, what changed, and what was deliberately left
alone.

Every "reference" number below comes from `build/s1probe.exe` driving the
installed `ext/synth1/Synth1/Synth1 VST64.dll` (SHA256
`51C6FE60D767C78F5A15B7023173AC5709EDBCF03A55CBAC9032569BA22F32C7`) in this
checkout, at 48 kHz, 512-frame blocks, 120 BPM. A number that came only from
this engine is labelled "ours" and is not reference proof. Raw probe output is
kept under `build/behavior/` (ignored by git); the commands that regenerate it
are given with each table.

## Goal

Fix the reported Synth1 behaviour errors in independently verifiable slices,
without guessing and without rewriting unrelated DSP:

1. mono/legato held-key fallback when the newest key is released, retriggering
   amp/filter in mono but not in legato;
2. auto portamento gliding in mono when keys overlap;
3. the modulation envelope restarting from zero on every new key, legato too;
4. MIDI aftertouch and pitch bend as controller-assignment sources
   53248 (`0xD000`) and 57344 (`0xE000`);
5. keeping the integrated synced oscillator-2 noise (9f0382e, 36481ee);
6. the delay tone filter applying to the first wet echo as well as feedback;
7. the arpeggiator honouring play mode, legato and portamento, gate 127
   included.

Lower confidence, measured before any change: oscillator 2 with key tracking
off still receiving key shift, fine tune and unison detune; chorus x1 being a
mono sum of both inputs. Documentation: the LFO waveform table in
`docs/reference-notes.md`, positions 2/3/4/5, keeping LFO destination 5 (pulse
width) deliberately inert.

## Contract amendments received

Verbatim steering from the originating session, relayed by the parent:

> Continue the requested full behavior-error scope in bounded slices. Preserve
> already integrated synced-noise behavior. For each item, require independent
> evidence and focused tests; defer lower-confidence oscillator-2
> tracking/chorus only if measurements do not support a safe change. Avoid
> speculative broad refactors and do not create a PR.

Supervisor decisions on the contradictions measured below (summarised):

- **Clause 3:** the literal contract controls. The modulation envelope resets to
  zero on every new key, legato included. This is a **requested behaviour
  change, not a reference-matching fix**. The reference and the manual
  contradict it, and that contradiction is recorded here.
- **Clause 1:** "retrigger" may restart the attack from the current level,
  because the clause does not say "from zero". Shared mono/legato
  sounding-voice transitions are authorised only as far as needed to make mono
  retrigger and legato truly not retrigger.
- **Clauses 2 and 6:** authorised. Their coefficient laws (portamento time,
  tone corner frequencies) are deferred.
- **Item 8:** key shift is disproved and deferred. Fine tune and unison detune
  are fixed as a partial supported change, not as proof of the whole asserted
  triple. The 220 Hz versus 261.6 Hz fixed base pitch is not to be changed.
- **Item 9:** if a mono sum is unsupported, defer it with the evidence. Do not
  substitute a per-channel architecture; record that as deferred work.

## Acceptance matrix

Product clauses (status: *implemented*, *requested change*, *partial*,
*deferred*, *verified unchanged*):

| # | clause | reference evidence (before) | change | regression coverage | status |
|---|---|---|---|---|---|
| 1 | releasing the newest key in mono/legato returns to the still-held previous key; mono retriggers amp/filter, legato does not | falls back in both modes; mono restarts the attack from the current level; legato leaves amp and filter alone (see "Clause 1") | pending | pending | pending |
| 2 | auto portamento glides in mono when a new key arrives before the previous one is released | mono + auto + overlap glides (62.34 → 71.96 over 300 ms); separated keys do not glide | pending | pending | pending |
| 3 | the modulation envelope restarts from zero on every new key, legato included | **contradicted**: legato does not restart it, and mono restarts from the current level (see "Clause 3") | pending, as a requested change | pending | pending |
| 4 | controller-assignment source 53248 (`0xD000`, channel aftertouch) and 57344 (`0xE000`, pitch bend) move their assigned parameter | pressure acts exactly like CC1; bend is bipolar about 8192 | pending | pending | pending |
| 5 | synced oscillator-2 noise (9f0382e/36481ee) is kept | `noiseprobe` figures in docs/reference-notes.md | none intended | existing tests and `noiseprobe` rerun | pending |
| 6 | the delay tone filter shapes the first wet echo as well as the feedback | with feedback 0 the first echo is shaped by tone (see "Clause 6") | pending | pending | pending |
| 7 | the arpeggiator honours play mode, legato and portamento, gate 127 included | gate 127 steps overlap: legato does not retrigger, mono restarts from the current level, auto portamento glides (see "Clause 7") | pending | pending | pending |
| 8 | (lower confidence) oscillator 2 with key tracking off still receives key shift, fine tune and unison detune | fine tune and unison detune apply; **key shift does not** | pending: fine tune and unison only | pending | pending |
| 9 | (lower confidence) chorus x1 is a mono sum of both inputs, not left only | **mono sum unsupported**: the reference keeps L and R apart (see "Item 9") | none | probe record only | deferred |
| 10 | `docs/reference-notes.md` LFO waveform table positions 2/3/4/5 corrected; LFO pulse width stays inert | pending `lfoshape` rerun | docs only | pending | pending |

Process clauses (user receipt requirements, not product behaviour):

| # | requirement | how it is checked | status |
|---|---|---|---|
| P1 | branch `fix/synth1-behavior-errors` based on `main` 36481ee | `git merge-base HEAD 36481ee` equals 36481ee | pending final check |
| P2 | independently verifiable slices, one commit each | `git log --oneline 36481ee..HEAD` | pending |
| P3 | focused regression per implemented slice; the bug-fix test fails on the old code | red run recorded per slice below | pending |
| P4 | relevant Odin suites and host builds pass | commands under "Host and suite checks" | pending |
| P5 | numerical external evidence, not self-referential tests | reference columns from `s1probe behavior` | in progress |
| P6 | lower-confidence items measured, then fixed or deferred with rationale | items 8 and 9 | measured |
| P7 | `specs/` preserved byte for byte, untracked, never added or ignored | `sha256sum specs/2026-09-28-sequencer.md`; `git status --short` shows `?? specs/` | pending final check |
| P8 | no guessing, no unrelated DSP rewrite, no PR | deferred list below; no `gh pr` was run | ongoing |
| P9 | unavailable checks reported, not implied | "Environment and unavailable checks" | ongoing |
| P10 | parent host/browser validation | owned by the parent session | pending, supplied by parent |

## Invariants and how each is checked

| invariant | check |
|---|---|
| `src/dsp` allocation-free, no `core:os`/`core:fmt`; engine allocates only in `engine_init` | `git diff 36481ee -- src/dsp src/engine \| grep -E 'make\(\|new\(\|append\(\|core:os\|core:fmt'` is empty |
| behaviour lives in the shared engine; hosts only forward messages | host diffs are one-line forwards to an engine procedure |
| public shapes keep their identity, order and raw values: parameter indices, stored integers, `Midi_Control`'s existing fields, host entry points | `odin test tests/patch`, `tests/clap`, `tests/vst3` and `tests/dsp` pass unchanged |
| unspecified controller sources stay inert, not misread | engine test: a source that is neither `0xB0nn`, `0xD000` nor `0xE000` moves nothing |
| synced noise untouched | `git diff 36481ee -- src/dsp/oscillator.odin src/dsp/noise.odin` is empty; noise tests pass |
| `specs/` untouched | P7 |

## State model (keyboard, arpeggiator off)

The **held keys** (what the player is holding, `Engine.held_keys` plus press
order) are kept separate from the **sounding voice** (what the single mono or
legato voice plays). Reference observations come from `s1probe behavior keys`,
with sine oscillator 1, amp attack 50, decay 50, sustain 40, release 0, and
keys 60 then 67.

| event | held keys after | reference, mono | reference, legato | ours before |
|---|---|---|---|---|
| note-on, nothing held | {n} | new note from silence | same | same |
| note-on while k held | {k, n} | n sounds, attack restarts from the current level | n sounds, amp/filter untouched | mono: new voice from zero; legato: attack restarts from the current level |
| repeated note-on of held 60 (after 67) | 60 becomes newest | 60 sounds, attack restarts | 60 sounds, untouched | as the row above |
| note-off of the sounding key, others held | set minus n | falls back to the newest held key, attack restarts | falls back, untouched | silence |
| note-off of a key that is not sounding | set minus k | no change | no change | no change |
| note-off of the last key | {} | release | release | release |

Portamento: with auto off every new pitch glides. With auto on, only a pitch
change made while another key is held glides. That covers the overlapping
note-on and the fallback, in mono and in legato alike.

## State model (arpeggiator)

`s1probe behavior arp`, sine, chord 60 64 67, pattern up, one octave, step
"(8)" (250 ms):

| event | reference |
|---|---|
| step starts, previous step already released (gate < 127) | a fresh note; no auto glide |
| step starts while the previous step is still gated (gate 127) | an overlap: legato keeps amp level flat (dip −0.2 to −1.2 dB), mono restarts the attack from the current level (+1.1 to +2.3 dB rise), auto portamento glides |
| gate closes inside the step (gate < 127) | the step's note is released |
| last chord key released | the sounding step is released |

Poly mode with more than one voice sounding cannot be measured: the reference
dies inside `processReplacing` under this host (exit 139) as soon as a second
voice starts, which is the arpeggiator crash `compare.odin` already records.

## Measurements before any change

### Clause 1: fallback

```
build/s1probe.exe behavior keys --mode <1|2> --scenario fallback \
  --attack 50 --decay 50 --sustain 40
```

Pitch (MIDI) and level (dB) at offsets from `off 67` while 60 is still held:

| offset | ref mono | ours mono | ref legato | ours legato |
|---|---|---|---|---|
| −30 ms | 67.00 / −28.8 | 67.00 / −28.8 | 67.00 / −28.7 | 67.00 / −28.7 |
| +5 ms | 60.00 / −17.4 | silence | 60.00 / −28.8 | silence |
| +30 ms | 60.00 / −10.0 | silence | 60.00 / −28.8 | silence |
| +120 ms | 60.00 / −25.1 | silence | 60.00 / −28.7 | silence |

The overlapping note-on (`on 67` with 60 held) at +5/+15/+30 ms: ref mono
−17.4/−13.0/−10.0 dB (from the −28.7 dB sustain), ours mono −20.2/−14.6/−10.1
(a fresh voice from zero); ref legato −28.6/−28.6/−28.7, ours legato
−17.7/−13.0/−9.9 (attack re-entered). The filter envelope behaves the same way
(`--filterenv`): ref mono +5.1 dB rise on fallback, ref legato steady.

### Clause 2: auto portamento

```
build/s1probe.exe behavior keys --mode 1 --scenario <overlap|separate> \
  --porta 64 --auto 1 --notes 60,72
```

| offset from `on 72` | +5 | +30 | +80 | +120 | +300 ms |
|---|---|---|---|---|---|
| ref, overlapping | 62.34 | 65.00 | 68.62 | 70.14 | 71.96 |
| ours, overlapping | 72.06 | 72.00 | 72.00 | 72.00 | 72.00 |
| ref, separated | 72.00 at +50 ms and after | | | | |

Fallback with portamento glides in both modes: 69.85 → 66.98 → 60.04 at
+5/+30/+300 ms.

### Clause 3: modulation envelope

```
build/s1probe.exe behavior keys --mode <1|2> --scenario fallback --modenv \
  [--modattack 0 --moddecay 50]
```

The setup is oscillator 2 alone, tracking the key, with the modulation envelope
routed to its pitch. Pitch minus the played key is the envelope.

| case | reference | ours before |
|---|---|---|
| legato, envelope already decayed (attack 0, decay 50), `on 67` | 67.00 at +5/+15/+30 ms: **no restart** | 76.63 at +5 ms: restarted |
| legato, envelope mid-decay (attack 70, decay 110) | offset 29.92 → 29.40 → 29.25 st: continues | re-enters attack |
| mono, envelope already decayed | 90.12 at +5 ms (+23 st): restarted | a fresh voice from zero |
| mono, mid-decay | 29.9 → 32.2 → 33.9 st peak: restarted from the current level | from zero |

The manual says the same: in legato "the VCO and VCA envelopes are not
triggered". Clause 3 is implemented as worded anyway (see the contract
amendments), and the regression test pins the requested behaviour. It does
not claim the reference.

### Clause 4: controller sources

```
build/s1probe.exe behavior ctrl --source <cc|pressure|bend> --sens 80
```

Source → parameter 2 (osc2 pitch), sensitivity stored 80 ("25%"), pitch bend
range 0. Oscillator 2 pitch (MIDI) after each message:

| value | CC1 ref | CC1 ours | pressure ref | pressure ours | bend raw | bend ref | bend ours |
|---|---|---|---|---|---|---|---|
| 0 | 60.000 | 60.000 | 60.000 | 60.000 | 0 | 29.065 | 60.000 |
| 32 | 67.960 | 68.000 | 67.960 | 60.000 | 4096 | 43.962 | 60.000 |
| 64 | 74.907 | 75.000 | 74.907 | 60.000 | 8192 | 59.920 | 60.000 |
| 96 | 82.960 | 83.000 | 82.960 | 60.000 | 12288 | 74.962 | 60.000 |
| 127 | 89.907 | 90.000 | 89.907 | 60.000 | 16383 | 89.962 | 60.000 |

Channel pressure is the CC law with the pressure value. Pitch bend is
bipolar: the centre moves nothing and each extreme displaces as far as a full
controller.

### Clause 6: delay tone on the first echo

```
build/s1probe.exe behavior delaytone
```

A saw pluck at note 48 with delay "(8)", feedback 0 and dry/wet 50%. The table
gives echo level minus dry level per band, relative to tone 64, in dB:

| tone | 100–400 | 0.4–1.6k | 1.6–3.2k | 3.2–6.4k | 6.4–12.8k |
|---|---|---|---|---|---|
| ref 0 | −1.94 | −10.81 | −20.27 | −25.88 | −33.58 |
| ref 32 | +0.00 | −0.52 | −2.86 | −6.41 | −13.09 |
| ref 96 | −5.56 | −0.66 | −0.08 | −0.02 | −0.00 |
| ref 127 | −32.37 | −19.67 | −11.61 | −6.52 | −2.18 |
| ours, every tone | +0.00 | +0.00 | +0.00 | +0.00 | +0.00 |

### Clause 7: arpeggiator

```
build/s1probe.exe behavior arp --mode <1|2> --gate <127|64> [--porta 64 --auto <0|1>]
```

Level change within 60 ms of the step boundaries at 250/500/750 ms, against the
10 ms before:

| case | reference | ours before |
|---|---|---|
| legato, gate 127 | −1.2, −0.8, −0.3 dB (no restart) | −8.0, −6.5, −3.5 dB (restart from zero) |
| mono, gate 127 | +1.1, +2.2, +1.8 dB (restart from the current level) | −8.0, −6.5, −3.5 dB |
| legato, gate 64 | a fresh note each step, matching ours within 0.2 dB | same |

Pitch 0–150 ms into step 1 (60 → 64), legato, gate 127, portamento 64, auto on:
ref 60.57, 61.59, 62.31, 62.82, 63.17 at 250/275/300/325/350 ms. Ours jumps
straight to 63.92/64.00. With gate 64 and auto on, neither glides.

### Item 8: oscillator 2 with key tracking off

```
build/s1probe.exe behavior osc2track
```

The table gives the strongest one or two spectral peaks, 150–700 Hz, with
oscillator 2 alone (triangle):

| variant | reference Hz | ours Hz |
|---|---|---|
| track off, note 60 | 220.02 | 261.67 |
| track off, note 72 | 220.02 | 261.67 |
| track off, key shift "12" | 220.02 (**unchanged**) | 261.67 |
| track off, fine tune "+50 cent" | 226.49 (+50.1 cents) | 261.67 |
| track off, unison 2, detune 127 | 213.73 and 226.49 (−50/+50 cents) | 261.67 |
| track on, key shift "12" | 523.21 | 523.22 |
| track on, fine tune "+50 cent" | 269.27 | 269.27 |
| track on, unison 2, detune 127 | 269.27 and 254.13 | 269.27 and 254.13 |

### Item 9: chorus x1

```
build/s1probe.exe behavior chorus1
```

Wet = chorus on minus chorus off, saw note 60, level 127. "corr" is the
correlation of wet left against wet right.

| input | ref wet L / R dB | ref corr | ours wet L / R dB | ours corr |
|---|---|---|---|---|
| pan L 100% | −11.1 / −inf | 0.000 | −11.2 / −11.2 | 1.000 |
| pan centre | −11.1 / −11.1 | 1.000 | −11.2 / −11.2 | 1.000 |
| pan R 100% | −inf / −11.1 | 0.000 | −inf / −inf | 0.000 |
| unison spread (layers panned apart) | −11.1 / −11.1 | 0.046 | −11.2 / −11.2 | 1.000 |

A mono sum would put a hard-panned input's wet into both channels and make the
unison-spread wet identical in both (correlation 1). The reference does
neither. Unison pan spread cannot be applied after the effects, so the last
row rules out "pan is applied after the chorus". The requested mono sum is
therefore **unsupported** and is deferred. The measured alternative, each
channel through its own line on the shared sweep, is recorded as deferred work
rather than substituted. Ours is wrong too (a left-only tap, so a hard-right
voice gets no chorus at all), and that is deferred with it.

## Per-slice records

(filled in per slice)

## Environment and unavailable checks

- Odin `dev-2026-09-nightly:a2fb372`. The CI pin `dev-2026-08` is not
  installed: only dev-2026-05 and dev-2026-09 are cached, so CI's exact
  compiler was not run.
- The reference dies in poly mode with two voices sounding under this host, so
  poly-mode behaviour between notes (and a poly arpeggio) is unmeasured.
- qlty: `.qlty/qlty.toml` enables actionlint only, and `qlty` is not on PATH.

## Deferred and out of scope

- **Clause 3's reference behaviour.** In the reference, legato does not restart
  the modulation envelope and mono restarts it from its current level. That
  behaviour is recorded above and deliberately not implemented, per the
  contract.
- **Portamento time law.** At stored 64 the reference glides with a time
  constant of about 70 ms (60 → 71.96 in 300 ms). Ours settles in about 80 ms.
  The `exp_map(0.002, 3.0)` curve is chosen, not measured.
- **First-note glide origin.** With auto off, the reference's first note glides
  up from far below (41.55 at 75 ms on the way to 60); ours starts at 60.
- **Mono retrigger after a released note.** Whether a mono note-on during
  another note's release restarts from the release level or from zero is
  unmeasured. That path is unchanged.
- **Item 8, key shift.** Not applied by the reference with tracking off.
- **Item 8, fixed base pitch.** The reference's tracking-off base is 220.02 Hz
  (A3); ours is 261.6 Hz. Not to be changed in this work.
- **Item 9, chorus x1 routing.** Per-channel processing is measured; mono sum
  is not supported. Both are left as they are.
- **Delay tone corner frequencies.** These are chosen, not measured. Only where
  the filter sits in the signal path is in scope.
- **`bind_lfo` comment.** `src/engine/binding.odin` `bind_lfo` carries the same
  stale "reference" column as the docs table in clause 10, while its `switch`
  binds the correct shapes. The clause names the docs table only.
- **Small controller offsets.** Returning a controller to rest reads
  60.062 (CC/pressure 0) and 59.920 (bend 8192) in the reference, against
  60.000 before. This is not modelled.
