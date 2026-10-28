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
node hosts/wasm/serve.js     # builds nothing; then open :4817
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

### Five readings that depend on another control

Some controls do not mean one thing. The two LFO depths mean semitones while the
LFO drives pitch and nothing nameable while it drives cutoff, volume or pan. The
effect unit's two controls and its level mean whatever the selected type makes
them mean. A single suffix in the generated table would therefore be true at one
setting and a lie at the rest, so those five carry no generated unit at all;
`COND` in `layout.js` supplies a `formatValue` instead, and `app.js` prefers it
over the table when it returns something.

The rule that governs them is that **a unit is only shown where
`docs/null-test.md` measured one**, and the fallback is the honest bare integer
rather than a plausible suffix:

| control | reads | and stays bare at |
|---|---|---|
| LFO 1 / 2 Depth | semitones, at the two pitch destinations | cutoff, volume, nothing, FM amount, pan — the file applies its curve to pitch alone |
| Effect Control 1 | ring modulator hertz, compressor decibels, phaser octaves | distortion drive, which has no physical unit, and the decimator's hold, measured only at 48 kHz |
| Effect Control 2 | distortion tone in hertz, phaser rate in hertz | decimator bit depth, whose table is bounded at both ends; compressor attack, given only as a range; the ring modulator's, which is inert |
| Effect Level | percent, for the three distortions and the two crossfading types | the compressor, whose decibel slope has no anchor, and the phasers, whose feedback law is superseded |

A formatter is handed its own position and a resolver for any other parameter's
**position**, never the raw stored value: parameters 41 and 46 store 1..7 for
positions 0..6, so comparing stored numbers would name the destination one place
off. The knob speaks the same reading it prints — `aria-valuetext` comes from the
formatter too, so a conditional unit is not silently dropped for a screen reader.
Every law carries its `docs/null-test.md` line range at the point it is used.

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
| `bridge.js` | host transport; absorbs every platform difference, and the version-1 handshake |
| `app.js` | builds the panel and keeps it in step with the host; owns the selection, the banks and the restore banner |
| `patchfile.js` | `.json`, `.zip`, folder and `.sy1` in and out; import validates before it adds |
| `modal.js` | the dialog shell and its confirm and alert questions |
| `browser.js` | the bank and slot browser |
| `midi.js` | Web MIDI: a controller plays the panel and lights its keys; under a host that claims MIDI input (`window.SynthHostMidi`), never Web MIDI, only the host's input selection |
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

A host that keeps a program of its own adds version-1 messages -- `restore`,
`bank-saved`, and `v`, `origin` and `readOnly` on `bank` and `patch` -- and the
page may then send `select`, `restore-retry` and `restore-discard`. See
[Presets and banks](#presets-and-banks) and the header of `bridge.js`.

`edit` brackets a gesture so a host recording automation records one move rather
than the few hundred values a drag passes through.

A host that reads the MIDI devices itself sets `window.SynthHostMidi = true`
before `midi.js` loads, the way a host inside the page claims `SynthVolume`.
Web MIDI in that page would be a second way in for the same keyboard, and every
note would sound twice, so `midi.js` then never asks for it. The MIDI button
shows the host's selection instead and offers All inputs, each input, and None.
It keeps no selection of its own: choosing sends a request, and the button
changes only when the host's answer comes back.

```json
{"type":"midi-select","id":"hw:1,0"}
{"type":"midi-list"}
{"type":"midi","inputs":[{"id":"hw:1,0","name":"Keystation 49"}],"selected":"hw:1,0","name":"Keystation 49","rev":2}
```

`midi-select` takes `all`, `none` or an input's id. `midi-list` asks for the
inputs again, which the page does whenever the list opens. `midi`, from the
host, is the selection with its inputs; `selected` is null when there is
nothing to select.

A host that keeps a zip of banks itself and shares it between its clients, as
the standalone daemon does, says so by sending `archive`. The archive, its open
bank and where the playing sound came from are then the host's, and the page
only shows them and asks:

```json
{"type":"archive-open","path":"/srv/banks.zip"}
{"type":"archive-bank","index":1}
{"type":"archive-load","bank":1,"index":2}
{"type":"archive-close"}
{"type":"archive","rev":3,"open":true,"path":"/srv/banks.zip","banks":["bankA.zip","bankB.zip"],"bank":1,"patches":["Pad","Bass","Keys"]}
{"type":"patch","name":"Bass","index":null,"bank":"bankB.zip","source":"archive","archive":{"bank":1,"patch":1}}
```

`archive-open` without a path, or with `""`, reopens the path the host
remembers. `archive` is the host's whole view, sent again after every request
(after an `error` when the host refused it): `banks` and `patches` (the open
bank's, `[]` when none is open) by index, `bank` the open bank or null, and
`path` the remembered path (`""` if none, and possibly set while `open` is
false). `source` in `patch` is `none`, `bank`, `archive` or `file`; `index` is
only ever an ordinary slot, and `archive` the archive bank and patch, or null.
A `patch` with a `source` puts the slot (`bank`) or the archive patch's index
(`archive`) in front of the name on the strip, as in `002:Bass`, shows its bank
label beside it, sets `data-source` on `#bank`, and leaves an ordinary slot
selected only when `source` is `bank` and `index` is a number.

Once one `archive` has arrived (`SynthBank.archive()` is not null):

- The bank browser lists the host's ordinary bank first and the archive's
  banks after it. A `bank` from the host replaces the ordinary bank's row in
  place.
- Picking an archive bank browses it (`archive-bank`): its patches are shown
  by the host's names, however many there are, and nothing is loaded.
  Clicking one sends `archive-load` with the bank being browsed. Clicking an
  ordinary slot loads it as before.
- The open bank is shared: when an `archive` names another one, a page
  browsing the archive follows it, and a page browsing the ordinary bank stays
  there with only the archive's rows updated.
- A row is marked playing only from the last `patch`, never from the cursor:
  an ordinary slot when `source` is `bank` and `index` is that slot, an
  archive patch when `source` is `archive` and `archive` names the bank being
  browsed and that patch.
- The dialog has an archive field: the remembered path, Open, Close (only
  while one is open) and a line saying how many banks it has, that it is
  unavailable, that none is open, or what the host refused. A zip picked in
  the page is refused with a message pointing at that field.
- PREV and NEXT during an archive patch send `patch-step`, for the host to
  step through that archive bank.
- WRITE offers only the ordinary bank, and Export and Keep work on it alone:
  archive banks are read-only.

A host that never sends `archive` (a plugin, the browser build, the page on
its own) keeps its own banks and reads a zip in the page as before.

## Presets and banks

The strip at the foot (at the top on a phone) says which preset the sound is,
where it came from, and whether it has been changed:

```text
[PREV]  IMPORTED  042:Glass Pad *  Alfmeister Bank  [NEXT]  [Browser] [Save] [More]
```

`#bank-patch` is `NNN:Name` or the bare name and `#bank-name` is the bank's
label, exactly as they always were. The origin chip (`#bank-origin`) and the
edit marker (`#bank-dirty`) are their own elements, so nothing that reads the
name has to know about them.

### What the panel knows about the sound

`SynthBank.selection()` is the one answer to "which preset is this": its
`origin`, `source`, `bank`, `slot`, `presetName` and, for an archive preset,
`archive: { bank, patch }`. It is kept apart from three things it used to be
mistaken for -- the bank the browser is *looking at* (`current()`), the slot a
Write is *aimed at*, and the live parameters.

| origin | what it is | a slot? |
|---|---|---|
| `factory` | the bank compiled into the page, or the one a host calls that | yes |
| `user` | a bank made here, or the one a host keeps for this instrument | yes |
| `imported` | a bank opened from a file, a zip or a folder | yes |
| `archive` | a bank inside the host's shared archive | never: `archive` carries its indexes |
| `file` | one patch opened from a file | never |
| `session` | the sound as it is, with nothing behind it ("Unsaved") | never |

`SynthBank.status()` is one of `loading`, `unavailable`, `dirty`, `readonly`
or `clean`, the first that applies. **`dirty` means the sound differs from what
the selection was stored as and nothing more**: it is not, and nothing in the
interface may say it is, the host's project having unsaved changes. A sound with
no slot is measured against what it was loaded or last exported with.
`SynthBank.readOnly()` says the last part separately.

The factory bank is read-only wherever nothing keeps what is written to it:
anywhere but the browser build (which has `store.js`) or a host that sends
`"readOnly":false`. An archive bank always is. Save on anything read-only, or
imported, or with no slot, opens Save As and never overwrites its source.

### Opening the editor is not an edit

Issue #13: reopening a plugin's editor, or toggling a project offline and
online, reset the program and the bank, because the page loaded slot 0 of its
own bank and sent that sound to the host. Two rules came out of it, and both
have tests (`tests/ui/preset-reopen.test.mjs`):

- A page whose host holds the sound -- every plugin and the standalone
  daemon's page, which is `SynthBank.hosted()` with the engine *not* in the
  page (`SynthBridge.inPage` is false) -- never loads a patch and never sends a
  `state` when it starts. A page whose engine is in the page (the browser build
  and Quesynth Pad, where `host.js` claims `SynthVolume`) has been told nothing
  and keeps selecting slot 0, as it always did.
- Adopting a bank the host sends changes the list of banks and nothing else. It
  does not load a slot, change the sound, or send a `state`, a `select` or a
  `bank` back. Which preset is playing is the host's `state`, `patch` and
  `restore`.

### Restoring what the host asked for

A host that restored a program and bank when the project loaded says how that
went (`restore`, in the header of `bridge.js`). A failure keeps the sound, the
bank and the program, and the banner (`#restore-banner`, `role="alert"`) says so:

> Could not restore `Alfmeister Bank / 042`. The current sound was kept.
> [Retry] [Choose bank]

and, for a missing bank only,

> The saved bank is unavailable. Load Factory / Init instead?
> [Load Factory / Init] [Keep current sound]

Those words are in `index.html` and `pad.html` and are the contract; `app.js`
fills in only the bank and slot. **Nothing ever substitutes the factory bank for
one that could not be found unless the person presses Load Factory / Init.**
Retry sends `restore-retry`, Keep current sound `restore-discard`, Choose bank
opens the browser; choosing any preset replaces the identity the host was
holding. A failure that cannot be retried (`recoverable: false`) disables Retry,
and one that is not a missing bank gets a Dismiss button instead of the second
line. `SynthBank.restoreState()` is `{ state: "notRequested" | "restoring" |
"restored" | "failed", error, recoverable, origin, bank, slot, name }`.

The host can also choose by itself. A MIDI Program Change is a choice like any
other, and the host's session lets go of the failed restore it was holding, so
a `patch` that names a preset ends a failed restore on the page too, and the
banner goes. A failure the host still holds is sent again straight after its
`patch`, so a patch is never the last word on one (`sync` answers in the order
bank, state, patch, restore for the same reason).

A retry that is waiting is left to its own answer, which the host always gives:
the restored bank and preset, the same failure again, or

```json
{"type":"restore","v":1,"state":"notRequested"}
```

when there is nothing left to retry because the instance has moved on. That
state is only ever an answer to a retry; at `sync` a host with nothing to say
says nothing. Without it a Retry would leave the banner busy, with Retry
disabled and `loadPreset` refusing with `RestorationConflict`, until the person
pressed Keep current sound.

### Version 1 of the protocol

`"v":1` is the whole of the handshake: the page sends `select`,
`restore-retry`, `restore-discard` and the new fields of `bank` only after it has
received a host message that carries a `v`, so a legacy host (the standalone
daemon's adapter answers an unknown type with an `error`) never hears one.
Nothing that existed is renamed or dropped. The messages are written out in the
header of `bridge.js`; `SynthBridge.PROTOCOL`, `version()` and `sendV1()` are
how the rest of the panel uses them, and a transport that throws makes `send()`
return `false` with the reason in `SynthBridge.error()`.

### Writing, saving and moving

`SynthBank.writePreset({ bank, slot, name, overwrite })` is the one door
through which a sound becomes part of a bank. It writes exactly that slot or
refuses and changes nothing; it never asks a question, and never assumes the
answer -- `overwrite: true` is the caller saying a person agreed. `copySlot`
and `moveSlot` take `{ bank, slot }` for both ends and the same flag. Every
refusal is `{ ok: false, error: { code, message } }`:

| code | when |
|---|---|
| `InvalidSlot` | not an integer 0..127, or not a bank that is open |
| `ReadOnlyBank` | factory with nothing to keep it, archive, a bank not yet read, a move out of a read-only bank |
| `InvalidName` | empty, control characters, or over 48 UTF-8 bytes (the host's limit: it truncates silently, so the panel refuses) |
| `OverwriteDenied` | the slot holds a sound and `overwrite` was not `true` |
| `PersistenceFailed` | the host answered `bank-saved` with `ok: false`; the sound is in the bank here, the message says it is kept for this session only |

`loadPreset` refuses with `UnavailableSource`, `InvalidPreset`, `HostRejected`
or `RestorationConflict` and never loads a bank to find out. Results are shown in
the strip (`#bank-status`, `role="status"`) and handed to whoever asked to hear
(`SynthBank.onResult`).

`bankText()` and Export write **what is stored**. The sound being edited is no
longer substituted for its slot, so an export or a keep never contains something
nobody chose to put there, and an export of a dirty sound says "Unsaved changes
to Glass Pad were not included." Interior empty slots are written as `null`, so
every patch comes back at the slot it left.

### Opening files

An import validates the whole file before it touches anything, then adds one
`imported` bank under a name that is not already taken (`Name 2`, `Name 3`), and
that is all: not the bank in view, not the selection, not the sound, and nothing
is sent to the host. A bad file leaves all of those as they were and fails with a
code, and the message it always had:

| code | for |
|---|---|
| `UnsupportedFormat` | another `format`, a newer `version`, a container or reader this build lacks, text that is not a patch |
| `InvalidBank` | it does not parse, holds nothing, names a parameter that does not exist, a damaged patch |
| `TooManySlots` | a JSON bank with more than 128 patches: refused, not cut |
| `ReadFailed` | the file could not be read |

A zip or a folder with more than 128 patches fills a bank with the first 128 --
the archive's own order for a zip, the file names as numbers for a folder -- and
reports "(N left out)". A zip of zips stays a list: no inner archive is read
until somebody opens it. One `.sy1` or patch `.json` is not a bank; it becomes
the sound, as a `file`. `tests/ui/preset-import.test.mjs` covers every row.

### Dialogs

`modal.js` stacks: `SynthModal.confirm({ title, message, confirmLabel })` and
`SynthModal.alert(...)` open *in front of* a dialog that is already up instead of
closing it, because a question that closed the browser would lose the
destination it was asked about. Escape, the close mark, the backdrop and Cancel
all answer no, focus starts on Cancel, Tab cannot leave, and focus goes back to
whatever opened it.

### The preset browser

`SynthBrowser.open()` opens the **preset view**; `SynthBrowser.open({ view:
"slots" })`, or the Slots tab, opens the bank and slot view, which is the browser
as it was before there was a preset view (`.browser-source`, `.browser-slot`,
`.browser-slot.on`, `.browser-archive-path` and the rest are unchanged). The two
are tabs of one dialog, `role="tablist"`, and the arrows move between them.

The preset view is for finding a sound by name:

- **Search** is over the names of the presets the panel already knows
  (`SynthBank.presets()`), case-insensitively, as you type. A bank that is listed
  but not opened -- one row of a zip of banks, or an archive bank the host has
  not opened -- contributes no names, **is never opened by searching**, and the
  list says so in a note, with how to open it. Opening a bank is a click on it in
  Banks.
- **Filters** are toggle buttons (`aria-pressed`): Factory, User, Imported,
  Archives, Current session (which includes a single patch opened from a file),
  then Favorites and Recent. None pressed means everything; several sources
  pressed show their union; Favorites and Recent narrow what is left.
- The order is the panel's and does not move: origin, then the order the banks
  were opened, then slot. Recent is its own, most recent first.
- Each row has the slot number, the name, where it is from (`Imported /
  Alfmeister Bank`) and a star. An empty slot is not a preset, so it is not
  listed here; it is always listed in the slot view.

A click, or Enter, **loads** the preset through `SynthBank.loadPreset`, and the
row that says it is playing (`aria-selected`) follows `SynthBank.selection()`:
it moves when the sound has. An archive preset is asked of the host and shows
`Loading…` until the host answers; a refusal is read in the dialog with its name.
What the view can be in is always said in words: an empty list says why it is
empty; `Read-only`, `Loading…` and `Unavailable` are on the row or in the line
that says what is playing (`SynthBank.status()`); the last thing the panel
reported is in `.browser-feedback`, `role="status"`.

**Favorites and Recent are the person's, not the instrument's** (the spec's
UI-only decision). They are never in a bank, never in an export, never in the
plugin's state and never in a message to a host. With `store.js` -- the browser
build -- they are kept under `quesynth.prefs.v1`, apart from `quesynth.state.v1`,
through `SynthStore.prefs()` and `SynthStore.setPrefs({ favorites, recent })`:
lists of preset keys, `origin NUL bank NUL slot-or-archive-position NUL name`
(`presets()[].key`), Recent most recent first and at most 20. Without it, which
is every plugin, they last as long as the editor does. A key is the preset's
whole address, so a slot that was rewritten, or a bank that was renamed or closed,
makes the favorite **unavailable**: still listed, with that word on it, never
loadable, and never replaced by another preset that happens to have the same
name. Recent records every load a person makes -- a click, NEXT or PREV, a call
to `loadPreset` -- when it has happened (`SynthBank.onLoad`), and an archive
preset when the host has answered.

By keyboard: Arrow Down from the search box enters the list at the preset that is
playing; Up and Down, Home and End move between rows, Enter or Space loads, and
the list is one tab stop with the star of its current row next. Escape clears the
search first and closes the dialog second; Tab cannot leave the dialog and focus
returns to whatever opened it. Every control has an accessible name; the star is
`Favorite <name>`.

#### Banks

The Banks pane lists every open bank with where it came from (`Factory`,
`User`, `Imported`, `Archive`) and `Read-only` where nothing can be written to
it. The buttons beside it act on the bank in view and leave the sound, the
selection and the host alone:

- **New bank...** asks for a name and opens an empty bank of your own. The name
  is a small form in the pane; Escape or Cancel closes the form and not the
  dialog, and a name the panel refuses is said beside it with the form kept.
- **Import file...** and **Import folder...** add an `imported` bank (see
  [Opening files](#opening-files)). A refusal is read in the dialog with its
  code, and a bank that did not fit says how many patches were left out.
  `SynthBrowser.importBank()` is the same file picker for the strip's menu,
  where a refusal is an alert. The archive path field and its Open and Close
  are as they were.
- **Rename...** is for a bank of your own or one you opened. The factory bank,
  a bank the host keeps, and an archive refuse in the panel's words.
- **Duplicate** makes a writable `User` copy called `<name> copy` of a bank
  that has been opened, a read-only one included.
- **Export bank** writes the stored slots of a bank that has been opened,
  interior empties kept, and says so when the sound has unsaved changes.
- **Close bank** takes a bank out of the session: never the last one, never one
  the host keeps, and never the sound that is playing, which stays as it is
  with no slot behind it. A bank whose content is in no file -- one you made,
  or one you opened and then wrote into -- is asked about first.

#### Where a sound is put

`SynthBrowser.saveAs()` and `write()` open one destination dialog. Both choose
a slot and a name and go through `SynthBank.writePreset`, and neither loads
anything.

- **Save As** (what Save opens for a sound with nowhere to go back to) lists
  the banks that can take a preset, never an archive and never a read-only
  bank, plus New bank.... It starts on the first empty slot of the bank in
  view, with the name in focus.
- **Write** keeps its old default, the sound's own slot, and lists every
  ordinary bank with the read-only ones marked: writing into one is refused
  with the panel's `ReadOnlyBank` message and the dialog stays open.

A slot that holds another preset is asked about first; the sound's own slot is
not. Cancelling puts back the bank that was in view, because NEXT and PREV
step through it.

#### Copy and move

In the slot view each filled slot has **Copy** and **Move**, which open a
picker over the browser: choose a bank and a slot, which may be empty, in the
same bank or another that can be written to. The picker says what will happen
and what is already there, and then asks, naming both ends, **before** anything
is written; Cancel, Escape and the backdrop change nothing. It calls
`SynthBank.copySlot` or `moveSlot` once, so a move is one change, and shows
what the panel answered: a read-only destination, the same slot, or a move out
of a read-only bank is refused in words and the picker stays for another try.
A move of the preset that is playing takes the selection to its new slot. There
is no undo afterwards, which is why the question comes first.

In the preset view there is no Copy or Move, and in write mode there is no
preset view: a destination is a slot, so it is the slot view, and a click
chooses where to write and loads nothing.

## Using it

Drag a knob vertically. Hold shift for fine adjustment, double click to return a
control to the reference's own default. Arrow keys work on a focused control, and
every control is reachable by keyboard.

The full range of a knob is about 200 pixels of travel whatever the parameter, so
a 128-step cutoff and a 3-state routing switch feel the same under the finger.

## Layout

Each section is one full-width row inside the editor's own scrolling surface. On
a wide window that reads as a stack of labelled rows rather than columns the eye
has to track up and down; on a phone the rows become a filling grid.

The shell header carries identity and global actions only. The thirteen-section
navigator belongs to the editor it moves through: it is a vertical, independently
scrolling rail on a wide window and a horizontal strip on a narrow one. This is
especially important in Quesynth Pad, where the navigator arrives and leaves with
the editor drawer rather than occupying a dead band over the rack.

Two details in here are less obvious than they look:

- **The scroll offset is set in exactly one place.** `scroll-padding-top` on the
  editor scroller is the sole offset. Adding `scroll-margin-top` on the sections
  would add the two and land every jump too low.
- **There is a spacer after the last section.** Without it the last two or three
  sections can never reach the top, so selecting one scrolls as far as it can and
  then marks a different section. The spacer is sized from the editor scroller
  itself. The keyboard changes that scroller through the published `--keys-h`
  scalar, so it cannot make the last navigator entries unreachable.

Scroll snapping was tried and removed. Sections run from four controls to
seventeen, so a snap point lands as often in the middle of what is being read as
at the top of it, and the strip navigates well enough without taking over the
scroll.

The type scale has five roles: 18px lead, 15px title, 13px readout, 12px body,
and an 11px uppercase micro label with 0.14em tracking. Eleven pixels is a hard
floor. Control labels stay on one line; when a label grows, its padding gives the
space back so density does not drift.

Chrome and waveform/filter choices share one hand-drawn inline SVG language.
The strokes use `currentColor` and are created with `createElementNS`; there is no
asset, library, module, or build step. An icon is paired with its text wherever
there is text to pair it with; the stepper's two marks are the one place there is
none, and there the button's `aria-label` carries the whole name. The SVG itself
is always hidden from accessibility APIs, because the control keeps its ordinary
accessible name either way. No Unicode glyph stands in for an icon anywhere,
including the marks built at runtime.

Every rendered interactive target clears 28px in both directions, and the primary
actions, the bank and octave steps, and the stepper's two are 34px. The floor is
measured on what the browser lays out, not on what a rule declares: a 24px-wide
button with a 34px minimum height still fails it. The 88 piano keys are the
instrument's own geometry and are sized by the keyboard, not by this ledger.

## The keyboard

Deployed from the button at the right of the strip, and fixed to the foot of the
window when it is, so the panels are enclosed between the two. The page keeps
enough padding beneath it that the last section can still be scrolled clear.

Exactly 88 notes, MIDI 21 through 108 (A0 through C8), are always present. On a
desktop the 52 natural keys divide the available width without overflowing. On a
narrow screen the same complete range keeps finger-width keys and scrolls; the
octave buttons move the strip. It opens with middle C at the left edge, and the
octave buttons sit at the two ends of the bar so they fall under the thumbs.

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

## Known exceptions

- Parameters 86–89 remain the documented control-shape exception: unlike the
  ordinary generated state tables, they carry raw MIDI source/destination values.
- `hosts/clap` and `hosts/vst3` now host this panel: on Windows in an Edge
  WebView2 control, on Linux in a WebKitGTK view, both speaking the protocol
  below. `hosts/standalone` has no panel by design -- it is the audio engine and
  MIDI, played from the command line -- and the macOS Audio Unit (`hosts/au`) has
  no custom editor yet, so a host draws its own generic controls there.

## Two shells, one panel

`pad.html` loads the same files in the same order as `index.html` and adds three:
`pad-boot.js`, which asks the host for sixteen instruments; `pad-model.js`, the
DOM-free kit schema and routing rules; and `pad.js`, the browser controller. It
omits `store.js`, which remembers one sound where the pad has sixteen.

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

The rack keeps trigger and pitch separate. An incoming MIDI note selects every
cell assigned to it, while the cell's root note is what its engine sounds.
Assignments can be chromatic, General MIDI (channel 10), or custom; MIDI Learn
captures the next Note On. Each cell also owns velocity scaling, gate/one-shot
mode, choke group, volume, pan, enabled/mute/solo state, and its Synth1 parameter
array. The browser autosaves the same validated schema exported as `.qkit`.

The synth editor starts collapsed and is still exactly the shared editor. It is
an overlay drawer over the rack, not content appended below it, so opening it
does not make Quesynth Pad taller than the viewport. On a narrow screen the one
bank transport moves to the top, keeping loaded bank/patch identity present only
there while the keyboard alone docks to the bottom; desktop keeps the same
transport at the foot. Opening the editor and selecting a cell sends that cell's
state and remembered bank identity down the ordinary host-to-panel path, so both
the controls and bank strip follow the selection.

`node ui/check-pages.js` guards the arrangement. The way two shells over one panel
fail is quiet -- a file added to one page and not the other leaves the second
working but silently lacking the feature -- so the two script lists are compared,
and any difference has to be one that file knows the reason for.

## Pad tests and production bundle

The rack model and bundler use only Node's built-ins:

```text
node --test tests/ui/pad-model.test.cjs tests/ui/bundle-pad.test.mjs
node tools/bundle-pad.mjs --output build/quesynth-pad
node tools/check-pad-bundle.mjs build/quesynth-pad
```

Source stays as classic scripts for native WebViews. The production step combines
those scripts in their page order and copies the separate AudioWorklet and WASM
binary into `build/quesynth-pad/`; those two cannot be folded into JavaScript.
