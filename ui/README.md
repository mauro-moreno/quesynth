# The interface

An HTML panel for the synth, meant to be the *only* interface: the same files are
loaded by a web view on the desktop, on a phone, and inside the plugin. Nothing
here is specific to any of the three.

There are two shells over it. `index.html` is the synth: one instrument, a
keyboard along the foot. `pad.html` is **Quesynth Pad**, a four by four grid with
a whole instrument behind every cell -- the same panel underneath, editing
whichever cell is selected.

Open `index.html` and the panel works. There is no build step, no bundler and no
module loader, because a web view opening a page off the filesystem is the case
that has to work everywhere and it is the one most easily broken by tooling.

To hear it, one of the hosts has to be running underneath. The quickest is the
browser one:

```
node hosts/wasm/serve.js     # builds nothing; then open :8177
```

See `hosts/wasm/README.md` for what that host is and how to build its engine.
The panel itself needs none of it — nothing in this directory names a host.

## What it shows, and why that is the point

Synth1's own panel displays a bare `0..127` for most of the controls worth
touching — the filter cutoff, every envelope segment, the LFO speed, the
resonance. A number with no unit tells a player nothing, so this interface shows
what those settings **actually are**, taken from the measurements in
`docs/null-test.md`:

| control | reads |
|---|---|
| Cutoff Frequency | hertz, from 24 Hz to 16.9 kHz |
| Resonance | Q, from 1.07 to self-oscillation |
| Envelope Amount | octaves, signed |
| Attack / Decay / Release | milliseconds and seconds, out to 43 s |
| LFO Speed | hertz, from 0.078 Hz to 125 Hz |
| Gain | decibels |
| Sustain | percent |
| Pulse Width | percent duty, which spans 0 to 50, not 0 to 100 |

Where the reference already displays a real unit — the chorus in milliseconds and
hertz, the delay in beat divisions, the tunings in cents — that display is used
unchanged.

Units are grey and everything else is upper case, wherever the unit came from —
the reference's own display string (`+15 cent`, `15.12 msec`) or the generated
table's suffix (`1.51 kHz`, `1.20 Q`). A reading is split into its number and its
trailing unit, and the split only fires when what precedes the letters contains a
digit, so `On`, `-inf` and the `L` in `L 100%` are not mistaken for units.

Names are spelled out. The reference abbreviates to fit a fixed bitmap panel; there
is no reason to inherit `det`, `sprd`, `amt`, `PP` or `ST` here, so they read
Detune, Spread, Amount, Ping-Pong and Normal Stereo.

**Labels are always one line.** Controls sit in named groups — "Oscillator 2",
"Envelope", "Unison" — and the group heading carries the context the short label
drops, so "Fine Tune" under "Oscillator 2" says what "Oscillator 2 Fine Tune" said
over three ragged lines. Nothing is abbreviated to letters to achieve it. The full
name is never lost: it heads the information popover and is the hover title.

Every control has a mark in its corner that opens what it does, its full name, and
which parameter it is. That replaced a switch in the footer which revealed all
ninety-five descriptions at once — it had to be found before it helped, and once
thrown it tripled the height of the panel to answer a question about one control.

## Kinds of control

Five, chosen by what the parameter is rather than by what is easiest to render.

| kind | for |
|---|---|
| knob | anything continuous — a cutoff, a time, a level |
| switch | the two-state ones, reading On and Off |
| **list** | the type controls: filter response, waveform, routing, destination |
| **stepper** | the counts: polyphony and unison voices |
| dropdown | the effect unit alone |

The last three follow the reference's own panel, and for its reasons.

A **list** of lit options beats a dropdown for a type control because a dropdown
hides every choice but one: with five filter responses, both "which responses are
there" and "is this a band pass" cost a click to answer. The dropdown survives for
the effect unit, whose ten states in a column would be taller than the section
holding them.

A **stepper** beats a knob for a count. Polyphony and unison voices are small whole
numbers, and landing a knob on exactly 4 takes a careful drag followed by reading
the value back to find out whether it worked.

## Controls that are switched off

A section's Enable dims and disables everything it governs — the whole panel for
the modulation envelope, both LFOs, the delay, the chorus, the effect unit and the
arpeggiator, and just its own group for unison. The switch itself stays live, or
there would be no way back on, and so does the information mark: what a control
does is worth reading whether or not it is currently doing it.

They are dimmed rather than hidden, so a section does not change shape when it is
switched off. A panel that reflows as it is disabled makes finding the switch again
a matter of remembering where the panel used to be.

Note that the enable usually sits in a different group from what it governs — the
LFO's is under "Routing" while its speed and depth are under "Motion" — so this is
resolved once the whole panel exists rather than group by group.

## The effect unit's two controls

Parameters 79 and 80 do something different for each of the ten effect types, so
they are labelled with what they actually do and relabel themselves when the type
changes:

| type | control 1 | control 2 |
|---|---|---|
| the three distortions | Drive | Tone |
| Decimator | Sample Rate | Bit Depth |
| Ring Modulator | Frequency | **nothing** |
| Compressor | Depth | Attack |
| the four phasers | Depth | Rate |

Every one of those is measured, and written up in `src/dsp/effect.odin` — including
the blank: the ring modulator ignores its second control at every setting, five of
which were rendered and came back bit-identical. That control is labelled Unused
and disabled rather than left looking operable.

Two reasons for a control being off are tracked separately, which matters at
exactly one place: switching the effect unit off and on again while the ring
modulator is selected must not re-enable a control the ring modulator still
ignores.

The option names are the **measured** ones. Several enumerated parameters list
their states in an order their own manual gets wrong, and two of them store
integers that are not their position at all — the LFO waveforms of parameters 42
and 47 run `0, 1, 5, 2, 3, 4`. Selecting by position and converting at the edge is
what keeps the label and the sound in agreement.

## Files

| file | |
|---|---|
| `index.html` | the page; loads the scripts in order, and names no host |
| `style.css` | black ground, silver controls, one responsive grid |
| `params.js` | **generated** — every parameter, its positions, and each position's value |
| `layout.js` | hand written — panels, groups, both names per control, descriptions, option names |
| `bridge.js` | host transport; absorbs every platform difference |
| `app.js` | builds the panel and keeps it in step with the host |
| `midi.js` | Web MIDI: a controller plays the panel and lights its keys |
| `bank.js` | **generated**, optional — the patch bank; see the note in .gitignore |

Regenerate `params.js` after any change to the measured tables in `src/engine`:

```
odin run tools/uiparams
```

It is checked in so the page opens without a build.

## Talking to the host

`bridge.js` recognises WebView2, WKWebView, an injected Android object, and a
generic `window.synthPost`. With none of them it runs standalone against the
reference's own defaults, which is how the panel gets worked on without building
the engine.

A host that cannot push events into the page can instead call
`window.synthReceive(json)`, which every path ends up in.

Messages are JSON. Values are the **stored integers** the `.sy1` format and
`patch.Patch.values` use — not normalised floats. That is deliberate: normalising
loses the display-keyed parameters, whose stored integer is not their position. A
plugin host that speaks normalised automation converts at its own edge, where it
already knows the parameter's state count.

To the host:

```json
{"type":"set","index":19,"value":80}
{"type":"edit","index":19,"begin":true}
{"type":"sync"}
{"type":"note","on":true,"note":60,"velocity":100}
```

To the interface:

```json
{"type":"state","values":[ ...99 stored integers... ]}
{"type":"param","index":19,"value":80}
{"type":"patch","name":"Computer","bank":"soundbank00"}
```

`edit` brackets a gesture so a host recording automation records one move rather
than the few hundred values a drag passes through.

## Using it

Drag a knob vertically. Hold shift for fine adjustment, double click to return a
control to the reference's own default. Arrow keys work on a focused control, and
every control is reachable by keyboard.

The full range of a knob is about 200 pixels of travel whatever the parameter, so
a 128-step cutoff and a 3-state routing switch feel the same under the finger.

## Layout

Each section is one full-width row, and the sticky strip at the top jumps between
them. On a wide window that reads as a stack of labelled rows rather than columns
the eye has to track up and down; on a phone the rows become a filling grid and
the strip scrolls sideways.

**The strip is the only chrome.** There is no header and no footer: in a plugin
window every row given to a title is a row taken from the controls, and the strip
has to be on screen anyway. The name sits at its left and the keyboard button at
its right. Which host was found is on the name's hover title, so a build that
failed to inject its bridge is still diagnosable without spending a line on it.

Two details in here are less obvious than they look:

- **The scroll offset is set in exactly one place.** `scroll-padding-top` on the
  scroll container and `scroll-margin-top` on the sections look equivalent and
  add, landing every jump a full bar-height too low — far enough to leave the
  strip marking the section above the one that was asked for.
- **There is a spacer after the last section.** Without it the last two or three
  sections can never reach the top, so selecting one scrolls as far as it can and
  then marks a different section. Special-casing the bottom only moves the
  wrongness around: with three sections sharing the last screen there is no rule
  that picks the one the player asked for. The spacer is sized to exactly what is
  missing — including whatever the deployed keyboard is covering — so a tall last
  section adds nothing.

Scroll snapping was tried and removed. Sections run from four controls to
seventeen, so a snap point lands as often in the middle of what is being read as
at the top of it, and the strip navigates well enough without taking over the
scroll.

## The keyboard

Deployed from the button at the right of the strip, and fixed to the foot of the
window when it is, so the panels are enclosed between the two. The page keeps
enough padding beneath it that the last section can still be scrolled clear.

Five octaves, C1 to C6, wider than any window on purpose: the strip scrolls and
the octave buttons move it, rather than the range being cut to whatever fits. It
opens centred on middle C, which is marked with a dot. On a phone the keys are big
enough to play — this is the whole instrument there, not an accessory to a mouse —
and the octave buttons sit at the two ends of the bar rather than together in the
middle, so they fall under the thumbs.

**The keys are not ivory.** A bank of white keys under a black panel is the
brightest thing on the screen and pulls the eye off the controls, so the keys are
the panel's own greys — and what lights up is the key being *played*, in the same
silver the lit options and the knob pointers use. The instrument reads as one
object and the only bright thing on it is the note sounding.

They are drawn flat: one fill and one border each, no gradients, no bevels, no
drop shadows. A key is a rectangle, its border says where it ends, and the only
state it carries is whether it is sounding.

Dragging across the keys is a **glissando**, not a scroll — which is why the
octave buttons exist. A swipe cannot mean both "reach another octave" and "play
every key on the way", so the two gestures are not allowed to compete and the
buttons take the navigation.

One note is tracked per pointer, so two fingers are two notes and lifting one does
not silence the other.

## The wheels

Pitch bend and modulation, to the left of the keys. Pitch springs back to centre
when it is let go, because a bend left where it was put detunes the instrument
silently; modulation stays, because that is the whole use of it.

Both are performance rather than parameters: they are not in the patch, they are
not automated, and they leave as their own message — pitch on −1..1 and modulation
on 0..1, normalised. How far a bend of 1.0 actually goes is parameter 40's
business, and the panel has no reason to know it.

On a phone they **lie down and move above the keys**. Standing beside them they
cost about eighty pixels of a 375-pixel screen, which is a whole octave of reach;
lying across the top they cost a row barely taller than the label they already
needed, and the keys get the full width — eight naturals rather than under seven.

The drag works either way round without a breakpoint written twice: the track reads
its own orientation from its shape, and publishes one fraction that the stylesheet
turns into a position along whichever axis it is currently lying on.

## Not done yet

- No on-screen keyboard; the `note` message exists but nothing sends it.
- The four MIDI controller assignment parameters (86–89) have no controls. They
  read back as a fraction rather than a state table and need a different kind of
  control from anything here.
- Nothing is wired into `hosts/clap` or `hosts/standalone` yet — this is the
  panel and the protocol, not the host side of either.

## Two shells, one panel

`pad.html` loads the same files in the same order as `index.html` and adds two:
`pad-boot.js`, which asks the host for sixteen instruments instead of one, and
`pad.js`, which puts the grid above the panel and tags everything the panel sends
with the cell it is for. It omits `store.js`, which remembers one sound where the
pad has sixteen.

The panel itself is untouched, and that is the whole design. `app.js` holds one
array of stored integers and refreshes its controls when a *host* hands it a new
one -- a path that already existed, because a plugin host has to be able to say
"the project loaded, here is the patch". Selecting a pad is that same event:
`pad.js` delivers a `state` message and the panel repaints itself. It has no idea
there are sixteen of anything, so a control improved for the synth is improved for
the pad in the same edit, and neither page has a copy of the other's layout.

The styling follows from the same rule. A cell is the `.panel` surface with the
`.knob` metal on its rim, written against the tokens in `:root`, so restyling the
instrument restyles the pad with it.

`node ui/check-pages.js` guards the arrangement. The way two shells over one panel
fail is quiet -- a file added to one page and not the other leaves the second
working but silently lacking the feature -- so the two script lists are compared,
and any difference has to be one that file knows the reason for.
