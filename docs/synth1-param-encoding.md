# How Synth1 encodes parameter values

All facts here were measured against `ext/synth1/Synth1/Synth1 VST64.dll`, not
inferred. The machine-readable form is `docs/synth1-param-states.json`.

## Measurement method

`setParameter` accepts any float in 0..1, but `getParameter` reads back the
**canonical value of the state the plugin actually selected**. Sweeping
`setParameter` across 0..1 and collecting the distinct read-back values
therefore enumerates a parameter's real states exactly.

Counting distinct *display strings* does **not** work: displays are frequently
many-to-one, which undercounts states. An earlier version of
`docs/synth1-param-ranges.json` was built that way and was wrong for seven
parameters.

`docs/synth1-param-states.json` holds, for every parameter, each state's index,
its canonical normalised value (`norm`), and its display string.

## The critical rule

**Never compute the normalised value arithmetically. Look up `norm` in the state
table.**

`norm = (n + 0.5) / state_count` holds for most parameters but not all, and the
exceptions are silent:

| index | name | states | canonical norms |
|---|---|---|---|
| 41, 46 | lfo1/lfo2 destination | 7 | `0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8` — not a partition of 0..1 |
| 42, 47 | lfo1/lfo2 type | 6 | `0.2 .. 0.7`, and displays run `0, 1, 5, 2, 3, 4` — state order is not display order |
| | | | The waveform follows the **position**, not that display: measured in `docs/reference-notes.md`. Reading the display as an identity bound four of six states to the wrong shape. |
| 64 | chorus type | 3 | displays are `1, 2, 4` — display `3` does not exist |

Feeding `(n + 0.5) / 7` to `lfo1 destination` lands in the wrong state, which
produced 83 of the 231 remaining mismatches on its own.

## Parameter classes

Of 99 live parameters (0..98):

- **80** have plain-integer displays. Four of these are irregular: indices 2, 42
  and 47 are not ascending, and 64 has a gap.
- **15** have non-integer displays: 3, 5, 33, 35, 37, 50, 51, 52, 54, 55, 61,
  62, 72, 83, 90 (for example `+15 cent`, `50 : 50`, `0.99 Hz`, `L 100%`).
- **4** are effectively continuous with 16385 read-back values: 86, 87, 88, 89
  (`midi ctrl src1/assign1/src2/assign2`). These are not on the 0..127 patch
  convention and need separate handling.

## Mapping a `.sy1` integer to a state

Resolve in this order, per parameter:

1. If the parameter is **display-keyed** and the file's integer appears among
   its displays, select the state whose display equals that integer.
2. Otherwise treat the file's integer as a direct **state index**.
3. Otherwise the value is out of range; see below.

Whether a parameter is display-keyed is *measured*, not inferred from the shape
of its displays. Having plain-integer displays is necessary but not sufficient:
indices 21 and 84 have them and are still direct state indices. See "Where the
resolution order above is measurably wrong".

Rule 1 alone is not sufficient and rule 2 alone is not sufficient:

- Index 1 `osc2 shape` has 4 states displaying `1..4` and factory patches store
  `1..4`. Treating the value as a state index makes value `4` overflow. It is a
  display integer. Same for 31 `arpeggiator type` and 64 `chorus type`.
- Index 2 `osc2 pitch` has 128 states displaying `-60..+60` and factory patches
  store `0..127`. Value `64` has no matching display, so it is a state index.

## Out-of-range values, resolved

*This section supersedes the "unresolved" note that stood here. The behaviour is
now measured, not guessed.*

### The oracle: Synth1's own loader

Synth1 sets `effFlagsProgramChunks`. `effGetChunk` returns a 2624-byte block
headed `Synth1 VST Chunk Data`, in which **parameter `i`'s stored integer is a
little-endian `i32` at byte `572 + 8*i`**. The layout was derived from the plugin
rather than assumed: `s1probe chunkmap` moves one parameter at a time and reports
which four-byte slot changed.

Writing a slot and handing the block back with `effSetChunk` runs Synth1's own
state-restore path over that exact integer, so `getParameter` reports precisely
what loading a `.sy1` holding that integer would produce. This is a real oracle,
and unlike the bank-folder route below it works headless.

It is also the *only* way to reach these values. `setParameter` saturates:

```
$ s1probe setget 33 3.394736767 1.868421078 0.5
sent           read_back      display      round_trips
3.394736767    0.973684251    "(32) /3"    false
1.868421078    0.973684251    "(32) /3"    false
0.500000000    0.500000000    "(8)+(16)"   true
```

A verify built on `setParameter` therefore *cannot* match the reference for
these patches, no matter how the mapping is written. `s1probe verify` drives the
plugin through `effSetChunk` for this reason.

### There is no clamp

Indices 33 and 35 are direct state indices over their whole range. The plugin
stores the integer verbatim and reports the uniform grid value **unclamped,
including above 1.0**:

```
$ s1probe chunkscan 0 33 35 35     # and 42, 64
stored   norm           display
35       1.868421078    "(4)+(8)+(16)"
42       2.236841917    "(1) x 9"
64       3.394736767    "(4) /3"

$ s1probe chunkscan 0 35 27 27     # and 40
27       1.375000000    "(1) x 3"
40       2.025000095    "(8)+(16)"
```

The measured table stops at 19 and 20 entries only because `setParameter`'s
0..1 domain cannot reach indices beyond that. That is a limit of the sweep, not
of the parameter. The earlier guess that these switch between free and
tempo-synced interpretations is wrong: `s1probe drivers` finds no parameter that
changes either one's state set.

The exact arithmetic matters. The plugin forms the reciprocal once and scales
both terms by it:

    step = 1.0f / state_count
    norm = state * step + 0.5f * step

Dividing by `state_count` instead lands one ulp away on several values; index 33
storing 42 is the clearest case (`2.236841917` measured, `2.236842155` computed
by division).

### Display-keyed parameters saturate instead

Not every parameter runs free. A parameter whose stored integer is matched
against display text saturates at its **top** state, at both ends, when no
display matches:

```
$ s1probe chunkscan 0 46 0 8
stored   norm           state
0        0.800000012    6      <- top, not state 0
1        0.200000003    0
5        0.600000024    4
7        0.800000012    6
8        0.800000012    6      <- top
```

Whether a parameter clamps or runs free is a property of the plugin, not of its
state table: index 0 and index 9 both have uniform tables and strict integer
displays, yet index 0 saturates and index 9 keeps walking the grid. It is
therefore measured per parameter, not inferred.

## Where the resolution order above is measurably wrong

The order in the previous section is right for 97 of the 99 parameters, and the
two exceptions are recorded here rather than quietly patched.

**Index 46 storing 0.** `111.sy1` contains `46,0`. Rule 1 does not fire, because
the displays are `1..7` and `0` is not among them, so the documented order falls
to rule 2 and selects state 0, norm `0.2`. The plugin measurably produces `0.8`,
the top state (see the scan above). Measurement wins: the implementation
saturates, and `verify` reports 0 only because of it. This is a third
out-of-range case beyond indices 33 and 35.

**Indices 21 and 84.** Both display plain signed integers (`-63..64` and
`-64..63`), so rule 1 looks applicable, but both are really direct state
indices: index 21 storing 0 reads back `0.00390625`, state 0, not the state
displaying `0`. Applying rule 1 to them would break all 128 factory patches.

`tools/genparams` prints a line for each parameter where the measured mapping
disagrees with the documented order, so neither divergence can be reintroduced
silently.

## Continuous parameters

Indices 86..89 (`midi ctrl src1/assign1/src2/assign2`) are not on the state
convention at all. Across the whole probed range they read back

    norm = (stored + 1) / 65536

exactly, confirmed for every stored value in -30..135. They are marked
`continuous` in the generated table, carry no state table, and are never forced
onto the 0..127 convention.

## How the mapping is recorded

`s1probe mapping` scores every candidate rule for every parameter against the
loader over stored values -30..135 and writes the exact fit to
`docs/synth1-param-mapping.json`. `tools/genparams` consumes that alongside
`docs/synth1-param-states.json`, and refuses to generate if any parameter lacks
an exact fit.

All 99 parameters fit exactly over stored values 0..135. Three parameters (9,
33, 85) read back one ulp below the computed grid for a single *negative* stored
value that falls outside their table (-26, -2 and -2 respectively), recorded as
`negative_deviations` in that file. No factory patch reaches those: the only
parameter storing negative values is index 9, over -24..24, every one of which
lands on a state.

## The superseded ranges table

`docs/synth1-param-ranges.json` and its `.md` have been **deleted**, along with
the `s1probe ranges` subcommand that produced them. They recorded display-run
counts as if they were state counts and assumed uniform quantisation; both are
wrong. `s1states` measures the state tables and `s1probe mapping` measures the
stored-integer mapping.

## What this does and does not prove

The circularity noted in earlier revisions is gone. That objection was against
driving the plugin with `setParameter` and comparing the display back, which is
self-consistent by construction: it proves a stored value reaches *a* state, not
that it reaches the state Synth1's loader would pick.

`effSetChunk` removes it. The plugin's own state-restore path consumes the raw
stored integer, so the read-back *is* the semantic choice Synth1 makes, and the
comparison is against a normalised value rather than display text. This matters:
after a chunk load the display echoes the raw stored integer, so index 1 storing
0 shows `"0"` while actually sitting on the top state. A display comparison
would have passed it.

What remains unproven is the audio path. Selecting the same state as the
reference is not the same as rendering the same samples; audio comparison
belongs to a later slice.

## Attempted oracle that did not work

Synth1 reads banks of `%03d.sy1` files from folders configured in
`%APPDATA%\Daichi\Synth1\synth1.ini` under `[General]` with `bankfolder<N>`
keys. Pointing that at a soundbank and sending MIDI bank select plus program
change does not change the loaded patch when the plugin is hosted headless with
no editor open: `numPrograms` stays 1 and the parameters do not move.

That route is still dead, but it is no longer needed: `effSetChunk` reaches the
same loader without an editor.
