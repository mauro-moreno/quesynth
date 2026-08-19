# Contributing

Contributions are welcome. Read this first, because this project is checked
differently from most and a change that would be fine elsewhere can be
unmergeable here.

## The one rule: claims need numbers

Quesynth exists to match a reference instrument, and every part of the engine
that could have been guessed at was measured instead. `tools/s1probe` loads the
real `Synth1 VST64.dll`, drives it and this engine with identical input, and
compares the results.

So a change to anything audible needs a measurement, not an argument. "This
sounds closer" is not reviewable; "spectral error 9.70 → 7.65 across the bank"
is. If you cannot measure it, say so plainly in the pull request rather than
leaving the reader to assume you did.

```
odin build tools/s1probe -out:build/s1probe.exe
./build/s1probe.exe compare <patch.sy1>
```

The probe needs your own Synth1 installation — see [What is not
included](README.md#what-is-not-included). Nothing of Synth1's is redistributed
here, so a fresh clone cannot run the null test until you point it at a copy.

A change that makes one patch better and three worse is not an improvement. Run
the whole bank before and after.

## The trap that has caught this project twice

**A test that builds its input with the same code that reads it cannot fail.**

Both times it cost real debugging. A null test comparing two engines cannot see
an error in what a patch *file* means, because the error is upstream of both —
that is how a format bug affecting all 128 factory patches stayed invisible for
weeks. Later, a VST3 host test wrote MIDI events through the same struct it read
them with, agreed with itself perfectly, and missed a byte-offset bug that made
the plugin silent in every real DAW.

If you are adding a test, ask what it is checking *against*. Something external
to the code under test — a vendored header, the reference plugin, a documented
layout — or it may only be checking that your code agrees with itself.

## Before opening a pull request

```
odin test tests/dsp
odin test tests/clap
odin test tests/patch
odin build hosts/standalone -out:build/quesynth.exe
odin build hosts/clap -build-mode:dll -out:build/quesynth.clap
odin build hosts/vst3 -build-mode:dll -out:build/quesynth.vst3
odin build hosts/wasm -target:js_wasm32 -out:hosts/wasm/synth.wasm
node hosts/wasm/check-imports.js
```

If you touched the measured tables in `src/engine`, regenerate the interface's
parameter table too, or CI will fail on a stale one:

```
odin run tools/uiparams
```

## Layering

`docs/architecture.md` has the rules; the short version is that they are load
bearing, because the point of them is that a mobile port is a new adapter rather
than a rewrite.

- **`src/dsp`** may not import `core:os`, `core:fmt` or `core:thread`, may not
  allocate on the audio path, and must compile for Android and iOS targets.
- **`src/engine`** owns allocation and does it once, in `engine_init`.
- **`hosts/*`** are adapters. Anything a second host would also need belongs
  further down, not copied sideways.
- **`ui/`** names no host. `index.html` loads `host.js` behind an `onerror`
  guard precisely so the panel never learns which host it is in; if you find
  yourself adding a branch on the host name above `ui/bridge.js`, the difference
  belongs inside `bridge.js` instead.

## Style

Match the file you are editing. Two habits are worth stating because they are
unusual and deliberate:

**Comments say why, not what.** The code already says what. Nearly every comment
in this repository exists to stop a future reader from "fixing" something that
looks wrong and is not — a magic constant that came out of a measurement, an
order of operations that matters, a simpler-looking approach that was tried and
was worse. If you delete a subtlety, delete its comment; if you add one, explain
it.

**Failed experiments are reverted, and the reason is kept.** Several comments
here record something that did not work — ladder saturation, allpass
interpolation, a 24 dB filter table measured at the wrong resonance. That is not
clutter. It is what stops the same idea being tried a third time.

Line width is 80 columns for comments and prose. Odin code is formatted the way
the surrounding file is.

## Reporting a difference from Synth1

The most useful issue this project can receive. Please include:

- The patch, or the exact parameter values.
- What you hear, and what the reference does instead.
- The output of `s1probe compare` on that patch, if you can run it.

A patch that sounds wrong and nulls well is interesting on its own — it means
the comparison is missing something, which is worth more than another fixed
patch.

## Contributors

- **Mauro Moreno** ([@mauro-moreno](https://github.com/mauro-moreno)) — author

Portions of this project were written with [Claude Code](https://claude.com/claude-code).

Add yourself here in the pull request that carries your first change.
