# Quesynth

*Pronounced “keh-synth”.*

Quesynth is a polyphonic virtual-analogue synthesizer written in
[Odin](https://odin-lang.org). It recreates the sound and parameter model of
[Synth1](https://daichilab.sakura.ne.jp/) through direct measurement, supports
Synth1 `.sy1` patches, and runs as VST3, CLAP, a Windows standalone instrument,
and WebAssembly.

**[Open the browser instrument](https://mauro-moreno.github.io/quesynth/)**

![Quesynth panel](docs/images/panel.png)

## Instrument overview

- Two main oscillators and a sub oscillator, with pulse-width control, frequency
  modulation, ring modulation, and hard sync
- State-variable and four-pole ladder filtering, resonance, key tracking,
  envelope modulation, and saturation
- Amplitude, filter, and modulation envelopes; two tempo-synchronizable LFOs
- Polyphonic and monophonic playing modes, portamento, unison, and arpeggiation
- Parametric equalization, ten effect algorithms, delay, and chorus
- A shared HTML interface for browser, VST3, and CLAP hosts
- Synth1 `.sy1` and bank import, plus Quesynth JSON patch and bank formats

Panel values are presented in musical or engineering units—including hertz,
milliseconds, decibels, Q, semitones, cents, and rhythmic divisions—rather than
only as stored integers.

## Quick start

The browser version requires no installation. Open the live instrument, select a
patch, and play from a MIDI controller, the computer keyboard, or the on-screen
keyboard. Audio begins after the first user interaction, as required by browser
audio policy.

For plugin or standalone use, build the desired target as described below. The
VST3 editor uses the Microsoft Edge WebView2 runtime. When WebView2 is unavailable,
the audio engine still loads and the host may display its generic parameter view.

| Target | Purpose | Platform |
|---|---|---|
| WebAssembly | Browser instrument and live demonstration | Modern browsers |
| VST3 | DAW instrument with embedded Quesynth interface | Windows |
| CLAP | DAW instrument with WebView2 editor | Windows CLAP hosts |
| Standalone | WASAPI audio and WinMM MIDI instrument | Windows |

## Signal architecture

```text
OSC 1 ─┐
OSC 2 ─┼─ modulation/mix ─ filter ─ amplifier ─ EQ ─ effect ─ delay ─ chorus ─ output
SUB   ─┘                         ▲          ▲
                         filter envelope   amplitude envelope
                                ▲
                         LFO 1 · LFO 2 · modulation envelope
```

Oscillators and filters are evaluated for every active unison layer. Envelopes
and note-level modulation belong to the note voice. The effects chain processes
the mixed stereo output once per sample. The [synthesis theory manual](https://github.com/mauro-moreno/quesynth/wiki/Synthesis-Theory)
explains how these stages shape a sound; [the mathematics](https://github.com/mauro-moreno/quesynth/wiki/Mathematics)
documents their discrete-time models and coefficients.

## User manual

The [Quesynth Wiki](https://github.com/mauro-moreno/quesynth/wiki) is the primary
user manual.

| Topic | Contents |
|---|---|
| [Getting started](https://github.com/mauro-moreno/quesynth/wiki/Getting-Started) | Browser, standalone, and plugin setup |
| [The panel](https://github.com/mauro-moreno/quesynth/wiki/The-Panel) | Control-by-control reference |
| [Banks and patches](https://github.com/mauro-moreno/quesynth/wiki/Banks-And-Patches) | Browsing, writing, importing, and persistence |
| [MIDI control](https://github.com/mauro-moreno/quesynth/wiki/MIDI-Control) | Program changes, bank select, and controller assignments |
| [Synthesis theory](https://github.com/mauro-moreno/quesynth/wiki/Synthesis-Theory) | Oscillators, spectra, filters, envelopes, modulation, and gain staging |
| [Mathematics](https://github.com/mauro-moreno/quesynth/wiki/Mathematics) | Equations used by the audio engine |
| [Patch archetypes](https://github.com/mauro-moreno/quesynth/wiki/Patch-Archetypes) | Practical starting points for sound design |
| [Architecture](https://github.com/mauro-moreno/quesynth/wiki/Architecture) | DSP, engine, host, and interface boundaries |
| [Verification](https://github.com/mauro-moreno/quesynth/wiki/Verification) | Measurement and null-test methodology |

## Building and testing

Install [Odin](https://odin-lang.org), then run commands from the repository root.

```powershell
odin test tests/dsp
odin build hosts/standalone -o:speed -out:build/quesynth.exe
pwsh tools/build-clap.ps1 -Output build/clap-stage
pwsh tools/install-vst3.ps1 -Destination "C:\Program Files\Common Files\VST3"
```

Build and serve the browser target with:

```powershell
odin build hosts/wasm -target:js_wasm32 -o:speed -out:hosts/wasm/synth.wasm
node hosts/wasm/serve.js
```

Then open `http://localhost:8177`. Additional build and platform details are in
the host-specific README files under `hosts/`.

## Compatibility and verification

Quesynth is a measurement-driven compatibility project, not an official Synth1
release. `tools/s1probe` hosts the reference plugin and Quesynth with identical
events, then compares level, spectrum, envelope contour, stereo behavior, and
sample-aligned null depth. The measured parameter tables live in `src/engine`;
the methodology and known limitations are documented in
[`docs/null-test.md`](docs/null-test.md).

Synth1 binaries, manuals, and patch banks are not redistributed. Import tools
operate on files supplied from the user's own Synth1 installation.

## Repository layout

```text
src/dsp/           allocation-free DSP primitives
src/engine/        voices, smoothing, modulation, and parameter binding
src/patch/         Synth1 and Quesynth patch parsing
src/clap/          CLAP ABI bindings
src/vst3/          VST3 ABI bindings
src/webview2/      Edge WebView2 ABI bindings
ui/                shared instrument and pad interface
hosts/             standalone, plugin, and WebAssembly adapters
patches/quesynth/  Quesynth factory bank
tools/             measurement, conversion, and installation utilities
docs/              engineering specifications and verification reports
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting audible changes.
Compatibility claims must be supported by reproducible measurements or tests.

## Project status

Quesynth is experimental software. Host integration, session compatibility, and
sound matching continue to evolve, and some reference patches remain measurably
or audibly different. Evaluate the current build before relying on it in a
production session.

## License and attribution

Quesynth is available under the [MIT License](LICENSE). Synth1 was created by
Daichi Kanenaga. Quesynth is an independent project and is not affiliated with or
endorsed by the Synth1 author.
