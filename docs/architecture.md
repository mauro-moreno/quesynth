# Architecture

Goal: **Quesynth**, a Synth1-compatible virtual analogue synthesiser written in
Odin that loads existing Synth1 `.sy1` patches, ships first as a CLAP plugin, and
can later be embedded in a mobile app.

Synth1 appears throughout this repository as the *reference* — the instrument
being matched, measured against, and null-tested with. It is not this project's
name.

## Layering

The mobile-port requirement drives the layering. Everything that makes sound
lives in a layer with no operating system, plugin, or allocator dependency, so
each host shell is a thin adapter.

```
  layer 2   hosts       synth.clap        iOS shell        Android shell
            (adapters)  CLAP entry        AudioUnit        AAudio/Oboe
                 |            |               |                 |
  layer 1   engine      +-----+---------------+-----------------+
            (glue)      voice allocation, parameter smoothing,
                        patch -> engine parameter binding
                 |
  layer 0   core        oscillators, filters, envelopes, LFOs
            (pure DSP)  no imports beyond core:math, no allocation
                        after init, no globals, C ABI export
```

Rules for layer 0 (`src/dsp`):

- No `core:os`, `core:fmt`, `core:thread`, no syscalls.
- No allocation on the audio path. All state lives in caller-owned structs.
- Must compile for `windows_amd64`, `linux_arm64 -subtarget:android`, and
  `darwin_arm64 -subtarget:iphone`.

Odin supports `-subtarget:iphone`, `-subtarget:iphonesimulator` and
`-subtarget:android`, so the mobile port stays pure Odin rather than needing a
rewrite.

## Reference-driven development

The original `Synth1 VST64.dll` is checked out under `ext/synth1/` (not
committed). `tools/s1probe` is a small VST 2.4 host, written from the public
`AEffect` struct layout with no Steinberg SDK dependency, that loads the real
plugin and extracts ground truth:

    build/s1probe.exe dump      # parameter names, defaults, programs
    build/s1probe.exe ranges    # per-parameter step counts and display strings
    build/s1probe.exe render 0 out.wav

This makes the project measurement-driven: the parameter table, the patch value
encoding, and the target audio are all read out of the reference binary rather
than guessed.

The oracle those rendered WAVs were for is `s1probe compare`:

    build/s1probe.exe compare ext/synth1/Synth1/soundbank00 --csv build/nulltest.csv
    build/s1probe.exe summarise build/nulltest.csv

It renders each patch through the reference and through `src/engine` under
identical conditions and reports the distance between them — timbre, amplitude
contour, tuning, level and stereo width — with a measurement floor of exactly
zero, since two reference renders of one patch are bit-identical. The analysis
itself is in `tools/s1probe/analysis.odin`, kept free of the plugin host and the
filesystem so it can be unit-tested against signals whose answer is known in
advance. See `docs/null-test.md` for the method, the current baseline, and what
it says about the parameter mappings this project had to guess.

## Patch format

`.sy1` files are plain text, CRLF line endings:

```
Synth1 brastring          <- literal "Synth1 " prefix + patch name
color=default
ver=105
0,1                       <- <parameter index>,<integer value>
45,0
...
```

The parameter index is the VST parameter index, confirmed against the reference
binary. Indices `0..98` are live; `99..254` are inert padding. Index `94` has no
name in the plugin but is real (polyphony, 1..32).

Values are stored as small integers. The conversion to a VST normalised value
is **not** uniform quantisation: `(patch_int + 0.5) / steps` disagrees with the
reference plugin on ten parameters. A stored integer selects a *state*, and each
state's normalised value is looked up in the measured table generated into
`src/patch/params.odin`. See `docs/synth1-param-encoding.md` for the resolution
order, the out-of-range behaviour, and how both were measured.

Older patches (`ver=105`) omit parameters added in later versions; missing
indices take the plugin's default value.

Banks also exist as `.fxb` (VST2 chunk format) and as zipped `soundbankNN`
directories.

## Layout

The delay and chorus live in layer 0 with the rest of the DSP, and keep its rules:
their delay lines run in buffers the engine allocates once in `engine_init` and
hands over, so `engine_process` still reaches no allocator. Sizing is from the
worst case the parameters allow -- four beats at 30 BPM plus the 100 ms channel
spread -- so a host changing tempo can never ask for a longer line than the one
already there.

The effect chain runs equaliser, then the extra effect unit, then delay, then
chorus. That order is the one the manual lists the sections in, which turned out to
be right for the three that the null test can check. The effect unit needs no
buffer of its own -- none of its ten types is a delay -- so it is plain state on
the `Engine` struct.

```
src/dsp/          layer 0, pure DSP core
src/engine/       layer 1, voices, parameters, patch binding
src/patch/        .sy1 and .fxb parsing
src/clap/         C ABI bindings: CLAP
src/vst3/         C ABI bindings: VST3
src/webview2/     C ABI bindings: Edge WebView2, for the plugin editor
ui/               layer 2 shared: the panel, one HTML interface for every host
hosts/clap/       layer 2: CLAP plugin
hosts/vst3/       layer 2: VST3 plugin, hosts ui/ in a web view
hosts/standalone/ layer 2: desktop shell, WASAPI out and winmm MIDI in
hosts/wasm/       layer 2: the browser, engine compiled to WebAssembly
tools/s1probe     reference VST2 probe (development only)
docs/             generated ground truth + design notes
```

A host is the panel plus its own glue, and each one assembles that pairing
itself: `hosts/wasm/serve.js` lays its directory over `ui/`, and
`tools/install-vst3.ps1` copies `ui/` into the plugin bundle. Nothing in `ui/`
names a host -- `index.html` loads `host.js` behind an `onerror` guard, and a
native host simply does not ship one.
