# Synth1 envelope and filter evidence

Goal run `27f346a2-4ad2-4630-8aaf-ef42a40e5aa9`, baseline `d441290`.

This file is shared by two slices. The envelope slice (E rows, the Envelope
section) is complete in the commit that introduced it. The filter slice (F
rows, the Filter section) is filled in by its own commit; until then those rows
say Pending and mean that no claim has been established.

## Frozen goal and acceptance

Measure the specified envelope and filter theories against the reference and
current engine, then implement only independently supported bounded changes.

The equations are hypotheses to verify, not permission to replace measured
behaviour. Each sub-theory needs an explicit measured, unresolved, disproved
or unavailable status. Feasible probes and focused tests must pass. Any audible
change needs numerical reference support and no existing-suite or factory-bank
regression. Preserve prior fixes and synced noise. Do not infer unavailable
disassembly, broadly rewrite DSP, modify `specs/`, or create a PR.

## Acceptance matrix

Status words: **supported** (a probe reproduces it against the reference),
**partial**, **disproved**, **unresolved** (measured, not explained),
**unavailable** (not observable from audio). Numbers are in the Envelope section.

| ID | Clause | Check and status |
|---|---|---|
| E1 | attack = `0.0005 * 56000^(v/127)` seconds | **Supported, not adopted.** Reference/formula 0.9993 at stored 48, 1.0001 at 64, 1.0000 at 80/96/112, 1.0002 at 127; with the onset factor fitted too, 0.9981 at 32 and 0.9892 at 16; 0.9505 at 0, where a 24-sample ramp is not resolvable. The table (90% time / 0.9) is 1.8-2.4% long. Adopting the law lost on the bank (Deferred D1) |
| E2 | decay length = `0.01 * 6000^(v/127)` seconds | **Supported, implemented.** Every readable tick equals `floor(2048 * law)` at stored 64-127 (116 to 8658 knots, 0 misses); 91.9% at 48 (3 of 37 knots one step off); 9 of 9 at 32; two knots or fewer below that. The -60 dB table is 0.73-0.78 of the length from stored 32 up, not a substitute |
| E3 | release length = same law | **Supported, implemented.** 100% at 48, 96, 112, 127; 99.1% and 99.7% at 64 and 80 (one knot each, one step off); 8 of 8 at 32 |
| E4 | decay = exponential x linear fade | **Supported, implemented.** Exponent 8.000 (7.992-8.001 where 8 or more knots are read); fade ends at 1.000 of the length (scan 0.90-1.10); the best plain exponential reaches 0.24-0.28 exact |
| E5 | release = exponential x linear fade | **Supported, implemented.** Same figures. Also holds from any starting level: levels 496, 304, 528 all exact |
| E6 | fade reaches exactly zero at segment end | **Partial.** The fade's zero is at 1.000 of the length by the exact-fit scan. The end value itself is **unavailable**: the reference's output is already exactly zero from 0.7716 of the length, where `floor(2048 * law)` first reads 0 |
| E7 | amp release idle at 90% of its length | **Unavailable.** Output is silent from 0.7716, before 0.9. What follows is a constant plateau that ends a fixed 38 ticks later at every setting, which is not 0.9 of the length. The idle state is not observable; the engine keeps its -80 dB idle (0.882 of the length on this curve) |
| E8 | reference and table checked before editing | Done: `build/envelope-filter/envlaw-baseline-grid.txt` was taken from `d441290`'s engine before any DSP edit, and `envlaw-grid-before.txt` repeats it with the final instrument. The generator and `envelope_table.odin` are unchanged |
| F1 | shared 1024-index `fc(i)=15*(16000/15)^(i/1024)` | Pending |
| F2 | type 0 2x Chamberlin/state-variable kernel | Pending |
| F3 | type 2 2x Chamberlin/state-variable kernel | Pending |
| F4 | type 3 2x Chamberlin/state-variable kernel | Pending |
| F5 | type-2 offset | Pending |
| F6 | type 1 four one-pole Moog variation | Pending |
| F7 | type 4 2x zero-delay ladder | Pending |
| F8 | saturation | Pending |
| F9 | output gain | Pending |
| F10 | hard clipping above resonance 0.9 | Pending |
| F11 | unresolved 100-300 Hz correction | Pending |
| G1 | each theory against reference and current engine | Envelope: `arch envlaw`, every row above. Filter: Pending |
| G2 | only supported laws, bounded slices, regression tests | Envelope: decay and release only, six new tests in `tests/dsp/envelope_law_test.odin` anchored on reference integers; attack deferred. Filter: Pending |
| G3 | prior behaviour fixes | `behavior keys/ctrl/arp/osc2track` before and after: see Preserved behaviour |
| G4 | synced noise | `noiseprobe --notes 48,60,72` before and after: sync lags identical (366/366, 183/182, 91/91) |
| G5 | no unavailable disassembly inference, no broad rewrite | Internal identities (integer state, tick, idle) are described only as what audio shows; the engine diff is one envelope branch and two binding lines |
| G6 | every sub-theory documented | Envelope: this file. Filter: Pending |
| G7 | feasible probes and focused tests exist and pass | Envelope: `arch envlaw`; `tools/s1probe` 82 tests, `tests/dsp` 138 tests, on dev-2026-08 and dev-2026-09 |
| G8 | no existing-suite/factory-bank regression | Envelope: bank before/after below, with the three patches whose spectral figure moves and why |
| G9 | relevant Odin tests/builds pass | See Gates |
| G10 | specs unchanged and untracked | SHA256 below, checked before and after |
| G11 | no PR | No external write performed |
| G12 | local commit, tracked tree clean | The envelope commit; `git status --porcelain` shows only `?? specs/` |

## Setup and evidence boundaries

Reference `ext/synth1/Synth1/Synth1 VST64.dll`, SHA256
`51C6FE60D767C78F5A15B7023173AC5709EDBCF03A55CBAC9032569BA22F32C7`.
48 kHz, 512-sample blocks, 120 BPM, note 84, velocity 100, a sine through an
open filter (`arch_sine_patch`). Renders reset plugin/engine state.
Raw logs live in ignored `build/envelope-filter/`.

The generated `src/engine/envelope_table.odin` stores linear attack duration
and decay/release **-60 dB times**, not segment lengths. The baseline DSP
released at level 0.0001. Prior notes document misleading envelope crossings
and reverted ladder saturation experiments; those are not evidence for this
task's predictions.

`specs/2026-09-28-sequencer.md` SHA256:
`807053ADB331F3CE4DE2CAF0F753D73FCE8C52BCFD3C155FF5A7D63BD380CE54`.
It remains intentionally untracked. A clean tracked tree therefore still has
`?? specs/` in porcelain output.

## Interfaces and states

Preserve public Odin types, stored parameters, and generator formats. Probe
options follow existing optional defaults; value order and duplicates survive,
raw output paths survive, and no new validation error is invented.

Lifecycle is idle -> attack -> decay -> sustain -> release -> idle. Note-off
during attack/decay enters release from its current level; a second note-off
during release no longer restarts it (the fade branch would otherwise restart
its progress). Gate-on restarts from zero or continues from the current level;
mono/legato ownership is the engine's existing contract and unchanged. Idle
note-off is a no-op. Stored values outside 0..127 clamp as `envelope_table_index`
already does. No schema or feature flag is added.

## Envelope

### Commands

```
odin build tools/s1probe -out:build/s1probe.exe
build/s1probe.exe arch envlaw                            # the grid below, 35 s
build/s1probe.exe arch envlaw --values 64,96             # 5 s
build/s1probe.exe arch envlaw --values 48 --what knots   # every knot read, with the law's value
build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv <before|after>.csv
```

`--values` keeps order and duplicates, defaults to 0, 16, 32, 48, 64, 80, 96,
112, 127 when empty, and `--wav <dir>` keeps every render pair. The probe reads
both engines the same way and prints the table's column beside them.

### What the reference does

Each of these is a reading, not a design recovered from the binary.

- **The envelope is a whole number of 1/2048ths.** Divide a render by a flat
  render of the same note (attack 0, sustain 127) and what is left is the
  envelope. Fit a line inside every 256-sample tick; the lines on both sides of
  a tick boundary agree to 0.1 step, and the value there is an integer. From
  stored 48 up the envelope is these integers joined by straight lines.
- **Decay and release are `floor(2048 * exp(-8u) * (1 - u))`**, u = time / length,
  length = `0.01 * 6000^(v/127)` seconds. A decay to a sustain S falls from 2048
  to S by `S + (2048 - S) * exp(-8u) * (1 - u)`; a release from level L is
  `L * exp(-8u) * (1 - u)`. The decay's clock starts when its attack ends (sample
  751 for stored attack 40, which is floor of the formula's 751.1) and the
  release's at the note-off tick.
- **The attack is a linear ramp of the formula's length under an approach.** The
  level is `min(1, n/ramp) * (1 - exp(-n/tau))`, tau 68-70 samples (1.44 ms), n
  counted from a fresh note. That factor's own 90% time is 3.3 ms, which is the
  table's floor of 0.003501 s at stored 0 to 21, and why no attack at the
  bottom of the range reads shorter than about 3 ms.
- **Silence comes early.** `floor(2048 * law)` is 0 from u = 0.7716, so the
  output is exactly zero from there, not from the end of the segment. A constant
  plateau (8.254e-7 at note 84, both channels) follows and ends 38 ticks (9728
  samples) after the first zero tick at every setting from stored 16 up, 37 at 0.
- **Below stored 48 the lines between ticks bend.** At stored 16, 24, 32 and 40
  there are extra breaks inside the 256-sample ticks (stored 16: samples 61, 92,
  125, 199; stored 40: 206, 441), so only a few knots agree (2 at stored 16, 9
  at 32 for the decay). What is read there fits the law; what lies between is
  unresolved.

### Attack, formula against reference against table

`line rms` is the line fit's residual in fractions of full level; `model rms`
is the product model's.

| v | formula s | table s | ref line s | /formula | /table | line rms | model s | /formula | tau | model rms | ours /formula |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 0.0005 | 0.0035 | 0.0044 | 8.779 | 1.254 | 6.4e-2 | 0.0005 | 0.9505 | 68.8 | 7.8e-4 | 7.002 |
| 16 | 0.0020 | 0.0035 | 0.0032 | 1.610 | 0.912 | 7.3e-2 | 0.0020 | 0.9892 | 68.9 | 6.6e-4 | 1.766 |
| 32 | 0.0079 | 0.0079 | 0.0072 | 0.914 | 0.906 | 3.4e-3 | 0.0078 | 0.9981 | 68.3 | 2.5e-4 | 1.009 |
| 48 | 0.0312 | 0.0317 | 0.0310 | 0.994 | 0.977 | 1.6e-3 | 0.0311 | 0.9993 | 68.4 | 1.8e-4 | 1.018 |
| 64 | 0.1235 | 0.1257 | 0.1235 | 1.0000 | 0.982 | 1.7e-4 | 0.1235 | 1.0001 | 69.9 | 1.9e-4 | 1.018 |
| 80 | 0.4897 | 0.5014 | 0.4897 | 1.0000 | 0.977 | 2.5e-4 | | | | | 1.024 |
| 96 | 1.9416 | 1.9733 | 1.9416 | 1.0000 | 0.984 | 6.1e-4 | | | | | 1.017 |
| 112 | 7.6975 | 7.8837 | 7.6976 | 1.0000 | 0.976 | 2.1e-3 | | | | | 1.018 |
| 127 | 28.0000 | 28.6496 | 28.0044 | 1.0002 | 0.978 | 7.4e-3 | | | | | 1.008 |

A line through the middle of a ramp that is short against tau reads the
approach, which is the line column's 8.8 at stored 0. The model column reads
both and stays within 0.001 of full level at every setting it was run on.

### Decay and release, formula against reference against both engines

Reference columns are from the final `arch envlaw`. `ours dB` is the largest
gap between the engine's knots and the law, above 32/2048, less half a step; the
engine does not floor to whole steps, so 0.14 dB is its resolution here, not an
error. Before is the baseline engine, after is this commit's, same instrument.

| segment | formula s | table s | table/formula | knots read | exact | miss | k | fade ends | plain exp best | first zero u | tail ticks | ours dB before | ours dB after |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| decay 0 | 0.0100 | 0.0088 | 0.881 | 1 | 1.000 | 0 | | | | | 37 | | |
| decay 16 | 0.0299 | 0.0246 | 0.823 | 2 | 1.000 | 0 | | | | 0.891 | 38 | | |
| decay 32 | 0.0895 | 0.0700 | 0.781 | 9 | 1.000 | 0 | 7.998 | 1.001 | 0.556 | 0.834 | 38 | | |
| decay 48 | 0.2679 | 0.1952 | 0.729 | 37 | 0.919 | 1 | 8.001 | 1.000 | 0.270 | 0.776 | 38 | 0.75 | 0.11 |
| decay 64 | 0.8016 | 0.5829 | 0.727 | 116 | 1.000 | 0 | 8.000 | 1.000 | 0.250 | 0.772 | 38 | 0.78 | 0.13 |
| decay 80 | 2.3985 | 1.7458 | 0.728 | 347 | 1.000 | 0 | 8.000 | 1.000 | 0.242 | 0.772 | 38 | 0.75 | 0.14 |
| decay 96 | 7.1767 | 5.2296 | 0.729 | 1036 | 1.000 | 0 | 8.000 | 1.000 | 0.244 | 0.770 | 38 | 0.74 | 0.14 |
| decay 112 | 21.4740 | 15.6369 | 0.728 | 3099 | 1.000 | 0 | 8.000 | 1.000 | 0.244 | 0.770 | 38 | 0.68 | 0.14 |
| decay 127 | 60.0000 | 43.6868 | 0.728 | 8658 | 1.000 | 0 | 8.000 | 1.000 | 0.244 | 0.770 | 38 | 0.63 | 0.14 |
| release 0 | 0.0100 | 0.0096 | 0.962 | 1 | 1.000 | 0 | | | | | 37 | | |
| release 16 | 0.0299 | 0.0215 | 0.717 | 2 | 1.000 | 0 | | | | 0.891 | 38 | | |
| release 32 | 0.0895 | 0.0628 | 0.701 | 8 | 1.000 | 0 | 7.992 | 1.006 | 0.375 | 0.774 | 38 | | |
| release 48 | 0.2679 | 0.1855 | 0.692 | 36 | 1.000 | 0 | 8.000 | 1.000 | 0.278 | 0.776 | 38 | 2.43 | 0.09 |
| release 64 | 0.8016 | 0.5567 | 0.695 | 116 | 0.991 | 1 | 8.000 | 1.000 | 0.250 | 0.772 | 38 | 2.27 | 0.13 |
| release 80 | 2.3985 | 1.6598 | 0.692 | 347 | 0.997 | 1 | 8.000 | 1.000 | 0.251 | 0.772 | 38 | 2.42 | 0.13 |
| release 96 | 7.1767 | 4.9632 | 0.692 | 1036 | 1.000 | 0 | 8.000 | 1.000 | 0.244 | 0.770 | 38 | 2.40 | 0.14 |
| release 112 | 21.4740 | 14.8465 | 0.691 | 3099 | 1.000 | 0 | 8.000 | 1.000 | 0.245 | 0.770 | 38 | 2.54 | 0.14 |
| release 127 | 60.0000 | 41.4767 | 0.691 | 8658 | 1.000 | 0 | 8.000 | 1.000 | 0.244 | 0.770 | 38 | 2.31 | 0.14 |

"Exact" counts knots equal to the prediction out of the knots read; "miss" is
the largest gap in whole steps (never more than one). Settings below 32 read
too few knots to say more than that the ones read are exact. "Plain exp best"
is the share exact for the best-fitting plain exponential of the same length
with no fade; "first zero u" is where the reference's envelope first reads 0
as a share of the length; "tail ticks" is how long the plateau lasts after it.

Decay to a sustain, and release from other levels, at stored 64 (0.8016 s):

| case | reference level /2048 | knots read | exact | miss | ours dB before | ours dB after |
|---|---|---|---|---|---|---|
| decay to sustain stored 32 | 154 | 190 | 1.000 | 0 | 0.43 | 0.03 |
| decay to sustain stored 64 | 496 | 190 | 1.000 | 0 | 0.23 | 0.01 |
| decay to sustain stored 96 | 1108 | 190 | 1.000 | 0 | 0.10 | 0.00 |
| release from sustain 64 | 496 | 98 | 1.000 | 0 | 1.81 | 0.13 |
| release during decay 80 | 304 | 91 | 1.000 | 0 | 1.50 | 0.13 |
| release during attack 96 | 528 | 98 | 1.000 | 0 | 1.84 | 0.13 |

The engine's sustain levels already match the reference's at those three
settings (154, 496, 1108 of 2048).

### Engine change

Decay and release of the **amplitude** envelope follow the law; nothing else
changed.

- `src/dsp/envelope.odin`: `envelope_set_fade` sets the lengths in seconds and
  turns the fade branch on; the decay branch becomes `S + (1 - S) * fade(u)` and
  ends at u = 1, the release `release_from * fade(u)`. `envelope_set` is
  unchanged and still sets the exponential approach, so the filter and
  modulation envelopes are untouched. A second note-off no longer restarts a
  release. `u` is a `f64` counter: at 60 s, f32 steps would round away.
- `src/engine/binding.odin`: `envelope_segment_length` is the length law;
  `amp_decay` and `amp_release` use it. The tables, the generator
  (`s1probe envtable`) and `envelope_table.odin` are unchanged, so they still
  agree byte for byte.
- `src/engine/voice.odin`: the amplitude envelope calls `envelope_set_fade`.

Not changed: the amplitude attack (D1), the filter and modulation envelopes
(D3), the registry's displayed seconds (D4).

Tests, `tests/dsp/envelope_law_test.odin` and one updated release test. The
integers are the reference's own readings, so none of this is the engine
agreeing with itself:

| test | against |
|---|---|
| `test_amp_decay_matches_the_references_measured_ticks` | reference ticks 20, 40, 60, 75, 90, 100, 110 of stored 64: 615, 179, 50, 19, 6, 3, 1 |
| `test_amp_decay_settles_on_the_sustain_by_the_same_curve` | sustain 496: ticks 20, 40, 80, 100, 140, 160: 962, 632, 506, 498, 496, 496 |
| `test_amp_release_scales_the_curve_by_the_level_it_started_from` | released from 304 and 528: 286, 239, 115, 43, 5 and 497, 415, 201, 75, 10 |
| `test_amp_fade_segments_end_exactly_at_their_length` | the decay arrives on its sustain, and a release is gone, at their length and not before |
| `test_a_second_note_off_does_not_restart_the_release` | a repeat note-off lets the release go on falling |
| `test_amp_decay_and_release_lengths_follow_the_measured_law` | 0.01, 0.8016, 60 s at stored 0, 64, 127; the filter's tables unchanged |
| `test_release_follows_the_fade_law_over_its_length` (replaces `..._measured_table_says`) | a sine through an open filter: -40.8 dB half way, silent at the end |

Red runs, the old law against the same readings: of the first two tests'
anchors the old exponential misses decay ticks 20, 40, 60 and 75 (581.8, 164.3,
46.4, 18.0 against 615, 179, 50, 19) and release ticks 1, 4, 16, 32 (284.5, 233.3,
105.5, 36.6 against 286, 239, 115, 43). Against the baseline engine the length
test fails at every setting (decay 64 gave 0.582873 s, wanted 0.8015862) and the
release test reads a factor of 37.9 and sound after the end. Logs:
`build/envelope-filter/red-old-law-anchors.txt`, `red-engine-tests.txt`.

The instrument is held to known signals in `tools/s1probe/envlaw_test.odin`, with
inputs written from the formulas and not by the code that reads them: a decay
whose knots are the formula's integers is read back with every knot exact and
exponent 8; the same decay against a plain exponential reads as not matching;
a straight ramp reads as its length; a ramp under an approach reads as both. A
16-sample error in the decay's start fails the first one (7 of 15 knots exact).

### Factory bank

`compare ext/synth1/Synth1/soundbank00 --csv`, 128 patches, the baseline probe
against this commit's built on dev-2026-08. Five patches (095, 098, 100, 101,
106) kill the reference, as at the baseline. A run with a dev-2026-09 build is
cell for cell the same.

| metric | before | after |
|---|---|---|
| envelope error mean / median | 1.7389 / 1.3615 dB | 1.6534 / 1.1873 dB |
| level error mean / median | -1.0832 / -0.6725 dB | -1.0205 / -0.4963 dB |
| null depth mean / median | -8.5731 / -7.2847 dB | -8.5834 / -7.3022 dB |
| correlation mean | 0.7685 | 0.7686 |
| spectral error, all 128 rows, mean / median | 4.2930 / 3.4840 dB | 4.3951 / 3.4840 dB |
| spectral error, 119 valid rows, mean | 4.6177 dB | 4.7275 dB |
| spectral error, 116 valid rows without 114, 107, 013 | 4.5216 dB | 4.5069 dB |

51 patches improve on envelope error by more than 0.05 dB (best 120 -1.28, 012
-1.04, 119 -0.89, 009 -0.71), 15 get worse by more than that (030 +0.29, 029
+0.25, 016 +0.25, 056 +0.21, 105 +0.21, then 0.11 or less). No patch moves its
null depth by 0.5 dB either way. The release-length comparison (77 patches with a
tail in both) is unchanged, 39.0 ms mean gap.

**Three patches get worse on spectral error**, and it is stated, not absorbed:
114 kick1 7.59 -> 15.93 dB, 107 Shami 10.57 -> 14.49, 013 Marimba 6.84 -> 9.35.
Their sustain is 0 and their decays 66-68, and the spectrum is read from 0.40 s
to the end of the hold, where the reference's RMS is -77.3, -75.2 and -67.7 dB.
In 114's window the reference's energy sits at 180-250 Hz (-5 dB) and 500-1000 Hz
(-18 dB) and every other band is 30 to 55 dB lower; the "worst band" is 302 Hz at
44.7 dB, a band the reference holds at -36 dB and neither version reproduces
(old -65.6 dB, new -75.5). What is being compared there is the level of the
reference's own skirts, which come from its integer steps. A throwaway variant
that floored this engine's output to 1/2048ths, not shipped, moved the same three
patches from 15.93, 14.49 and 9.35 to 8.19, 5.09 and 18.41 dB: down for two, up
for one, for a change nobody could hear. A figure that moves that much for that is not a measure
of the envelope law, which is why the three are reported and the change kept;
the metrics that read the envelope itself, the level and the null, all improve.

### Preserved behaviour

`s1probe behavior ...` before (baseline probe) and after, text diffed, with the
probe's own timing lines removed:

| probe | result |
|---|---|
| `keys --mode 1 --scenario overlap`, `--mode 2 --scenario fallback`, `--mode 1 --scenario fallback --modenv` | identical except one row each, the 5 ms after a note-off: ours -51.8, -50.7, -55.1 dB before and -62.9, -61.4, -66.7 after, against the reference's -60.0, -59.2, -61.7. Key-change levels and the carried and restarted envelopes are identical |
| `ctrl --source cc --sens 80`, `osc2track` | identical |
| `arp --mode 1 --gate 127` | the decay readings move by 0.1 dB |
| `noiseprobe --notes 48,60,72` | sync lags identical (366/366, 183/182, 91/91); correlations move in the fourth decimal |

### For the filter slice

Reusable, in `tools/s1probe/envlaw.odin`: `envlaw_knots` (the envelope from a
render and a flat control), `envlaw_match`, `envlaw_best_k`, `envlaw_attack_model`.
Things that cost time here:

- Fitting a free curve to a reference envelope looks right and is not: with the
  fade's end left free a fit settles on 0.94 of the length and sits within the
  integers' own rounding. Exact integers against a prediction told it apart in
  one run.
- A tail's last nonzero sample is not an idle detector: it is the end of a
  constant plateau 38 ticks after the envelope reads zero.
- The reference's attack is under an approach of about 69 samples, so any level
  read in the first 10 ms of a fresh note needs it divided out.
- The reference's output below about 1e-6 of full scale carries that plateau.
- The full grid takes 35 s, `--values 64,96` 5 s; renders of stored 127 dominate.

## Filter

Pending. The filter slice records its probes, results and statuses here.

## Gates

Each on dev-2026-08 (`dev-2026-08-nightly:902106f`, the CI pin) and, where noted,
on the machine's dev-2026-09 build.

| gate | result |
|---|---|
| `odin test tools/s1probe` | 82 pass (08 and 09) |
| `odin test tests/dsp` | 138 pass (08 and 09) |
| `odin test tests/patch` / `clap` / `panel` / `vst3` | 29 / 41 / 4 / 26 pass (08 and 09) |
| `odin test tests/standalone` / `control` / `registry` | 24 / 12 / 8 pass (08 and 09) |
| `odin build` vst3 dll, clap dll, wasm, standalone, `tools/s1probe` | built on 08 |
| `node hosts/wasm/check-imports.js` on the built wasm | all 7 imports provided (`exp` was already one) |
| `ui/params.js` | not regenerated: no parameter changed |
| `git diff --check` | clean |
| `specs/` SHA256 | `807053ad...ce54` before and after, untracked |

## Deferred list

- **D1 (adopted for the amplitude and filter attacks; see
  `docs/synth1-filter-structure.md`, "Oscillator timing and note start").** The
  onset factor is the engine's gain smoother on the first note after a load, not a
  per-note factor, which is why applying it per note made later notes too quiet. The
  rest of this entry is the record as it stood. **D1. The amplitude attack law and its onset factor.** Supported (E1), not in
  the engine. The table stays. Two bank runs from this commit's engine: the
  law in place of the table for every setting made the envelope mean 1.6534 ->
  1.7642 dB, 19 patches worse and 13 better by more than 0.05 dB, 117 +5.5, 033
  +4.0, 113 +3.2. The law with the factor, `1 - exp(-n/69)` on fresh notes only,
  made the mean 1.6534 -> 1.6610 and the median 1.1873 -> 1.1644, moved the
  attack-time column onto or toward the reference for 007, 032 and 097 (375 ms
  -> 1300 ms against 1365), put 048 and 115 a frame off, and made 113 "hat"
  worse by 1.30 dB and the level mean -1.0205 -> -1.0828. Mixed, and the filter
  and modulation envelopes share `envelope_attack_time`, so whether the factor
  belongs to the amplitude path alone is not read. Next: read the filter
  envelope's attack the way this reads the amplitude's.
- **D2. The integer staircase and the 256-sample tick.** Not copied; the engine
  keeps a smooth float. What it costs is measured above (three spectral rows).
  The finer breaks below stored 48 are unresolved.
- **D3 (done; see `docs/synth1-filter-structure.md`, "Modulation and filter
  envelopes").** Both follow the amplitude's laws, read from the pitch and cutoff
  traces. The entry below is the record as it stood. **D3. Filter and modulation envelope laws.** Not read. They share the type,
  and stay exponential with the table times. Applying the law to them without
  a reading moved the bank both ways (all envelopes: envelope mean 1.7389 ->
  1.6801 but 033 +1.8 and 031 +0.9, null worse than 0.5 dB on two) and was
  discarded.
- **D4. Displayed time.** `registry/value_display.odin` still prints the table's
  60 dB seconds for parameters 26 and 28; from stored 48 up the segment is now
  1.37 to 1.45 times that. Changing the display touches the registry tests and
  the panel.
- **D5. E7 idle at 90%.** Unavailable from audio. The engine idles at 1e-4,
  which this curve reaches at 0.882 of the length.
- **D6. The 38-tick plateau and the voice that outlives its sound.** Measured,
  not copied.

## Contract amendments received

None.
