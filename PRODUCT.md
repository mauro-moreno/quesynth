# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Two audiences share one interface.

- **Players and sound designers** who already know Synth1, working in a DAW, on a
  desktop, or on a phone. They arrive with `.sy1` patches and expect the sound and
  the parameter names they know. On a phone the panel is the whole instrument, not
  an accessory to a mouse.
- **Readers taking the thing apart** — people who came from the null-test write-up
  and want to see what a measured parameter actually is. The README tells them to
  use Synth1 for real work, so a large share of traffic is here to inspect the
  method rather than to make music.

Quesynth Pad adds a third situation rather than a third audience: the same player
building a sixteen-cell rack, one Quesynth engine per cell, driven from a MIDI
controller or the on-screen grid.

## Product Purpose

A virtual-analogue synthesiser written in Odin that matches Synth1 closely enough
to load its `.sy1` patches and sound like them — verified by null-testing against
the original plugin rather than by ear. Success is a measured null depth, not a
listening opinion.

The interface exists so that a synthesiser reverse-engineered by measurement can
*show* its measurements. Explicitly not a finished instrument: the README tells
visitors to use Synth1 instead, and nothing in the UI may imply production
readiness or stability that the project does not claim.

## Positioning

Everything audible here has a number behind it. `tools/s1probe` loads the real
`Synth1 VST64.dll`, drives both engines with identical input, and compares
spectrum, envelope, level, stereo width and null depth; every table in
`src/engine` came from a probe in `tools/`.

The interface's own version of that claim: **the panel reads in units rather than
in `0..127`**. Synth1's own display shows a bare number for cutoff, every envelope
segment, LFO speed and resonance; here those read as hertz, milliseconds, Q and
octaves, taken from the measurements in `docs/null-test.md`. Where the reference
already shows a real unit, its own display string is used unchanged. A neighbouring
Synth1 clone could copy the sound; it could not copy the measurement record that
produced these readouts.

## Operating Context

One HTML interface serves four hosts, and nothing in `ui/` names a host:

| host | how the panel is loaded |
|---|---|
| VST3 | embedded in a WebView2 control as the plugin editor (tested in Ableton Live 11) |
| CLAP | plugin |
| standalone | desktop shell, WASAPI out, winmm MIDI in |
| WebAssembly | the browser demo at `mauro-moreno.github.io/quesynth/` |

Two shells sit over one panel: `ui/index.html` (one instrument, keyboard along the
foot) and `ui/pad.html` (Quesynth Pad, a 4×4 rack whose cells each hold a whole
instrument, editing whichever cell is selected). `node ui/check-pages.js` guards
that the two script lists stay in step.

The window is not a known size. A plugin host may size the editor to anything, the
desktop shell is resizable, and a phone is held in one hand — so there is no fixed
pixel layout anywhere in the sheet.

## Capabilities and Constraints

**Confirmed capabilities:** 99 Synth1 parameters across Master, Oscillators,
Filter, Amplifier, Modulation Envelope, LFO 1/2, Delay, Chorus, Effect, Equalizer,
Arpeggiator and Voice; `.sy1` and `.fxb` loading; a sixteen-patch factory bank; a
five-octave on-screen keyboard with pitch and modulation wheels; Web MIDI in;
MIDI-learn controller mapping. Quesynth Pad adds per-cell root-note translation,
velocity scaling, gate/one-shot triggers, choke groups, mute/solo, mix controls,
GM/chromatic/custom maps and portable `.qkit` files.

**Hard constraints future work must preserve:**

- **No build step, no bundler, no modules.** `ui/index.html` loads classic scripts
  in order so a WebView opening the page off the filesystem works. Anything that
  requires tooling to open the page is disqualified. `tools/bundle-pad.mjs` is a
  production concatenation step, not a source-time dependency.
- **`ui/params.js` is generated** by `odin run tools/uiparams` from the measured
  tables in `src/engine`, and checked in so the page opens without a build. Value
  text is never hand-authored. *(Verified this session: regenerating it produced no
  diff, so it is current with the engine.)*
- **Messages carry stored integers**, not normalised floats — normalising loses the
  display-keyed parameters whose stored integer is not their position.
- **No host is named above `bridge.js`.** With no host present the panel runs
  standalone against the reference's defaults.
- **Measured order wins over the manual.** Several enumerated parameters list their
  states in an order the manual gets wrong, and the LFO waveforms of parameters 42
  and 47 store `0, 1, 5, 2, 3, 4`. Selecting by position and converting at the edge
  keeps label and sound in agreement.
- **A control never gets smaller than a finger.** Knob drag is ~200px of travel
  whatever the parameter; a drag must not scroll the page under it.
- **Nothing of Synth1's is redistributed** — no plugin binary, no factory banks, no
  manual. `tools/uibank` reads them from the user's own installation.

**Terminology:** the panel spells names out. The reference abbreviates to fit a
fixed bitmap panel; `det`, `sprd`, `amt`, `PP`, `ST` read here as Detune, Spread,
Amount, Ping-Pong, Normal Stereo. Labels are always one line, and the group heading
carries the context the short label drops.

**Known gaps, not to be papered over:** parameters 86–89 (MIDI controller
assignment) have no controls; `hosts/clap` and `hosts/standalone` are not wired to
the panel; several patches are audibly off from the reference and are named in the
null-test write-up.

## Brand Commitments

- Name **Quesynth** (*keh-SINTH*); the rack shell is **Quesynth Pad**. Not
  affiliated with or endorsed by Synth1's author, Daichi Kanenaga.
- Voice: plain, measured, and self-deprecating. The README opens by telling the
  reader to use Synth1 instead. No marketing register, no superlatives, no claims
  without a number.
- MIT licensed, covering only this repository's own work.
- Incumbent visual world, confirmed by the user this session as the authority for
  refinement: black ground, silver controls, a deliberately tiny grey palette whose
  only colour is a faint blue cast on an active control, flat drawing with no
  gradients, bevels or drop shadows on the keys, and units set in grey against
  upper-case labels. The reasoning for each of those is recorded in `ui/README.md`
  and in the comments of `ui/style.css`; both are treated as design record.

## Evidence on Hand

- `docs/null-test.md` — the measurement record every unit in the panel descends
  from; over nine thousand lines, including this project's own retractions.
- `docs/synth1-params.md`, `docs/synth1-param-encoding.md`,
  `docs/synth1-param-states.json` — the reference's parameter table and encoding.
- `docs/images/panel.png`, `docs/images/keyboard.png` — the shipped interface.
- `patches/quesynth/factory.json` — sixteen patches written for this engine, the
  only bank that ships.
- Live demo: `https://mauro-moreno.github.io/quesynth/`.

**Absences that must not be invented:** no users, no adoption numbers, no
testimonials, no release, no support commitment, no pricing. Any performance or
accuracy claim must trace to a number in `docs/null-test.md`.

## Product Principles

1. **Show the measurement, not the number.** A control that has been measured reads
   in its real unit; a control that has not reads honestly rather than in a unit
   that was guessed.
2. **One interface, no host named.** A change made for the browser is made for the
   plugin, the desktop shell and the phone in the same edit — and a change made for
   the synth panel is made for the pad, because the rack reuses the editor rather
   than copying it.
3. **The window is not a known size.** Layout adapts; nothing is laid out in fixed
   pixels for a screen that may not exist.
4. **The instrument is the only bright thing.** Chrome recedes; what lights up is
   the note sounding or the control being moved.
5. **Nothing is claimed that is not measured.** In the copy, in the docs, and in
   what the interface implies about its own maturity.

## Accessibility & Inclusion

- Text contrast is **measured, not eyeballed**: the three ink tiers sit at 15.8:1,
  7.4:1 and 4.7:1 against `--panel`. A previous faint tier at 2.6:1 was raised
  after it proved unreadable on a phone in daylight — WCAG normal-text contrast is
  a floor this project has already chosen to meet, and it applies to any new tier.
- Every control is reachable and operable by keyboard; arrow keys work on a focused
  control, and `:focus-visible` outlines are drawn deliberately.
- `prefers-reduced-motion` is honoured on scroll behaviour and must be honoured by
  any motion added.
- Touch targets are sized for a finger; the drag gesture is claimed by the control
  rather than the scroller.
- Icon-bearing controls keep an accessible name; the information mark on every
  control stays reachable even when the control it describes is disabled.

## Gaps / Assumptions

- Users, purpose, positioning, constraints and evidence above are drawn from
  `README.md`, `CONTRIBUTING.md`, `ui/README.md`, `docs/`, and the source, not from
  a separate product interview. The user's one answered round this session
  confirmed the visual authority ("the existing panel"), the pad layout model, the
  icon approach and the measurement gap.
- `## Stack` is omitted: the existing codebase answers it (Odin engine; classic
  no-build HTML/CSS/JS panel).
- No image-generation tool is present in this session's surface, so this project
  proceeds **code-first** and nothing is recorded in `.impeccable/config.json`.
- Live mode is not configured. The project is runnable via
  `node hosts/wasm/serve.js` (port 8177) if it is wanted later.
