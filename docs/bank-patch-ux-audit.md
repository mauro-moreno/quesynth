# Bank and Patch Browser UX Audit

## Verdict

The browser is functionally complete but information-dense. It currently exposes too many independent facts and actions at the same visual level: source, bank, slot, origin, read-only state, loading state, favorites, recent state, copy/move, rename, duplicate, export, close, and write destination. The result is technically scannable but visually crowded, especially in the 190px bank pane and on narrow plugin windows.

The redesign should preserve the existing dark, measured visual language while changing hierarchy and disclosure. Do not add more labels or badges to the existing rows.

## Evidence

- `ui/browser.js` renders bank rows with name, count, origin badge, read-only badge, and several bank actions in the same pane.
- Preset rows combine number, name, origin/bank metadata, read-only/loading/unavailable badges, and a favorite action.
- Slot view renders all 128 slots correctly, but copy/move controls are attached to individual cells and compete with the slot name.
- The left bank pane is fixed at 190px, so the heading and New/Import/Folder actions must wrap into a very small column.
- The browser tests pass (`node --test tests/ui/preset-browser-*.test.mjs`: 131/131), so the redesign must be structural and visual without changing the established behavior contract.

## Main UX problems

### 1. No dominant object

Banks and patches are presented as peers. A user looking for a sound must parse the bank list, source badges, filters, metadata, and action controls before identifying the patch itself.

### 2. Metadata competes with names

Origin, bank, slot, read-only, loading, unavailable, favorite, and current-state indicators are all visible in the row. The useful primary fields—patch name and current selection—do not receive enough space.

### 3. Actions are always nearby

Rename, duplicate, export, close, copy, move, write, and import controls appear around the browsing surface. These are infrequent actions, but their visual weight is similar to navigation and selection.

### 4. Slot view is accurate but noisy

The 128-slot grid is the right compatibility model, but each cell currently carries selection styling, empty-state text, and optional transfer controls. The grid needs a cleaner index-first treatment and a separate detail/action surface.

### 5. Mobile becomes a stack of panes

On narrow windows, the source pane moves above or below the results. This preserves content but increases vertical scanning and makes the primary task—finding or selecting a patch—feel buried.

## Proposed information hierarchy

1. **Current sound** — persistent, compact context header: patch name, source/bank, slot, dirty/unavailable state.
2. **Task switcher** — `Presets` and `Slots`, with the active task obvious.
3. **Primary workspace** — either a patch list or the numbered slot grid. The workspace gets most of the height.
4. **Context inspector** — selected patch/bank details and actions, shown only when a row is selected or an action is requested.
5. **Secondary navigation** — source filters, favorites, recent, and bank management move into collapsible controls or a single `Browse` filter button.
6. **Destructive/persistence actions** — Write, Move, Close, and overwrite actions stay in explicit dialogs or an action menu, never in the default row chrome.

## Recommended desktop layout

```text
┌──────────────────────────────────────────────────────────────┐
│ CURRENT SOUND                                                │
│ Solar Winds MW     Imported · Alfmeister's Magic Cracker · 042│
│                                                [Save] [More ▾]│
├──────────────────────────────────────────────────────────────┤
│ [PRESETS] [SLOTS]                         [Filters ▾] [Search]│
├───────────────────────────────┬──────────────────────────────┤
│ RESULTS                       │ DETAILS                      │
│ 042  Solar Winds MW           │ Solar Winds MW               │
│     Imported · Alfmeister...  │ Imported                     │
│                               │ Alfmeister's Magic Cracker   │
│ 043  ...                     │ Slot 042                     │
│                               │                              │
│                               │ [Load] [Favorite] [More ▾]   │
└───────────────────────────────┴──────────────────────────────┘
```

- The details pane is optional at narrow widths and can become a bottom sheet.
- The result row should show only number, name, and one quiet secondary line.
- Badges become plain status text or move into the details pane.
- Bank actions belong in the selected bank's `More` menu, not beside every bank heading.

## Recommended slots layout

```text
┌──────────────────────────────────────────────────────────────┐
│ [PRESETS] [SLOTS]  Bank: Alfmeister's Magic Cracker  119/128 │
├───────────────────────────────┬──────────────────────────────┤
│ 000 Strings                   │ SELECTED SLOT                │
│ 001 —                         │ 042 Solar Winds MW           │
│ 002 Bass                      │ Imported · read-only        │
│ ...                           │                              │
│ 075 —                         │ [Load] [Write here] [More ▾] │
└───────────────────────────────┴──────────────────────────────┘
```

- Keep all 128 slots and their indexes.
- Keep empty slots visibly addressable, but use a quieter placeholder than a full empty row treatment.
- Show copy/move only in the selected slot's details menu.
- In write mode, change the details pane to `Choose destination`; do not add more controls to every slot.

## Responsive behavior

### Wide window

Use a 2:1 workspace split: results remain dominant; details are secondary but persistent after selection.

### Narrow plugin window

Use one column:

1. current sound header;
2. tabs and search/filter controls;
3. results or slots;
4. selected-item details as a collapsible bottom section.

The bank list should not consume a full viewport-height pane. Make bank/source selection a drawer or filter sheet opened from `Filters`.

## Visual rules

- Preserve the black/silver palette and restrained active blue.
- Increase row height and horizontal breathing room rather than shrinking typography.
- Use one selected-state treatment, not separate bright treatments for current, target, loading, and source.
- Reserve badges for exceptional states: unavailable, loading, read-only, and dirty.
- Keep action buttons text-based and accessible, but hide infrequent actions behind `More`.
- Avoid adding another accent rail; the detector already flags the existing 3px side borders on status banners.

## Implementation slices

1. Introduce a shared browser shell with current-sound header, tabs, workspace, and details region. Preserve all existing message/API behavior.
2. Simplify preset rows and move metadata/actions into the details region.
3. Simplify slot cells and move copy/move/write actions into the selected-slot details region.
4. Replace the always-visible source pane with a filter/bank drawer on narrow widths and a collapsible pane on desktop.
5. Add visual acceptance coverage at wide and narrow dimensions; retain the existing behavior/accessibility suite.

## Acceptance criteria for the redesign

- A user can identify the currently playing patch and its source without scanning the bank list.
- A preset row communicates name and location in one glance, without four or more competing badges.
- Copy, move, rename, duplicate, export, close, and overwrite actions are discoverable but not visually dominant.
- The 128-slot compatibility view remains complete and index-stable.
- The primary patch list remains usable at narrow plugin sizes without stacking three dense panes.
- Existing restoration, persistence, keyboard, and screen-reader contracts remain unchanged.

## Implementation notes

The redesign is in `ui/browser.js` and `ui/style.css`; nothing in `ui/app.js`,
`ui/bank.js`, `ui/bridge.js`, `ui/store.js`, `hosts/` or `src/` changed, and no
message to a host did. `ui/README.md` describes the result ("The preset
browser", "How the browser is laid out"). The slices above were done in order and
each is its own commit.

Where the mock and the existing contracts disagreed, the contracts and the
existing tests won. Every place that happened, and every place a reading was
chosen that keeps what was there:

- **The header has the sound and not the actions.** The mock's `[Save] [More ▾]`
  are not in the header: the strip already has Browser, Save and More, and a
  second Save would be a second way to do the one thing with its own rules. The
  header is `.browser-now`, the status line the tests already read, in the same
  words, with the name set apart and the state in plain words. A destination
  dialog has no header: it is choosing a place.
- **The slot view's `[Write here]` is not added.** Write and Save As are the
  strip's and the dialogs'; "In write mode, change the details pane to Choose
  destination" is done by keeping the form that was the destination's surface
  (`.browser-save`, `.browser-transfer`) and saying so above it
  (`.browser-destination`, "Choose destination"). Nothing was added to a slot
  there.
- **A click on a slot still loads it.** The mock has a selected slot that is not
  yet loaded and a `[Load]` button. Changing what a click does is a change of
  behaviour, so the details are of the slot that is playing, or of the one that
  has been *looked at*: the one with the keyboard focus, or asked about with the
  menu key, Shift+F10, a right click or, on a touch screen, a press and hold
  (a touch or a pen held for 480ms, with pointer events, because iOS Safari
  sends no contextmenu event for a long press), which also open its More menu.
  The click that lifting a finger after a hold makes is swallowed, and a quick
  tap is still a load. Load is in the details for that slot.
- **Favorite is not mirrored in the details.** The star stays in its row as its
  own control, with its own name (`Favorite <name>`) and its own place in the
  arrow keys, which the tests pin; a second button of that name would be two
  answers to a lookup by label. It stays in the faintest ink tier that still
  meets the contrast of the rest of the page; receding it further would have
  put it under 3:1.
- **Badges.** A preset row has at most one: `Loading…` or `Unavailable`, the two
  states that change what a click does. `Read-only` is words on the row's one
  line, and a bank's origin and `Read-only` are words after its name. They are
  still `.browser-badge` elements in the bank list, with the weight taken off,
  because the tests read them there.
- **One way to mark a row or a slot.** The sound that is playing, or in a
  destination the place the sound will go, is marked the same way; the amber
  of the destination, and the brighter ink of a loading row, are gone. A slot
  that has been looked at is marked as a hover is, quieter than either.
- **The pane is open on a wide window.** The mock says "collapsible pane on
  desktop", not which way it starts; it starts open, as it was, and the button
  shuts it. On a narrow window (620px, as the old stacking rule) it is a sheet
  over the workspace, shut to begin with. The width is watched while the dialog
  is open: crossing 620px in either direction puts the pane and the details as
  they would have been at that width (so a pane left open never becomes a sheet
  over the list), and a person's own choice does not outlast a crossing.
- **Escape in the pane.** On a narrow window it shuts the sheet and gives the
  focus back; beside the workspace it is not intercepted and closes the dialog
  as it did. Choosing a bank in the sheet shuts it.
- **The archive area is as it was**: its path field, Open and Close and its
  status are a labelled form and not an action menu, so they stay in the pane,
  shown only when there is an archive.
- **Menus reach Copy, Move, Rename, Duplicate, Export bank, Close bank, New
  bank and the imports.** An item that does not apply is `aria-disabled` with
  the reason on hover and is still pressed, so the panel is the one that
  refuses, as before. Overwrite is, as it was, a question in a dialog, and the
  modal's own Export, Keep and Done are untouched.
- **The filters are built once**, in the pane. As a result a filter that is
  pressed is shown pressed after the slot view has come and gone; before, the
  list stayed narrowed and the chip said it was not.
- **Notes that sent a person to "Banks" say "under Browse".**

How the criteria above are checked: `tests/ui/preset-browser-structure.test.mjs`
(stand-in DOM: header, rows, details, menus, pane, sheet, destination) and
`tests/ui/preset-browser-layout.test.mjs` (a real engine, five sizes from 1180
to 320 wide: where the header is, how much of the dialog the list has, that the
pane is beside the list or a shut sheet, that nothing overflows sideways, that
all 128 slots are there as `000` to `127`, that the menus open inside the
dialog; screenshots in `build/ui-layout/`). The existing preset suites pass
unchanged in what they assert; where a control moved, the helpers in
`tests/ui/support/browser.mjs` reach it the way a person does -- open the pane,
open the menu -- and the few assertions that named "the button that asked" name
the menu's button.

A second pass, from a review of the sidebar and the buttons in the dialog, changed
how the pane and the dialogs say what they are and what to press. It changed no
behaviour, no message to a host and nothing that is stored:

- **The button says Browse.** It opened filters, banks, what is done to banks
  and an archive's path, so "Filters" promised less than it did. It says
  `Browse`, and `Browse · 2` with two filters pressed; a destination, which has
  no filters, still says `Banks`. The filters' group keeps its name, `Filters`.
- **The pane is three headed parts**: `Sources` (the filters, in the preset view
  only), `Manage banks` (Add bank, Bank actions for the bank in view and, with an
  archive, its path, Open and Close, which stay a labelled form) and `Banks` (the
  search and the list). The headings are small quiet capitals and nothing to
  press; the controls are words, so that what labels and what acts are not
  mistaken. **The list of banks is last**, in the DOM, the Tab order and on the
  screen alike: a zip lists a hundred and seventy-five banks, each a Tab stop, so
  with the list first Add bank and Bank actions were that many stops away. A
  structure test pins that the number of stops to them does not depend on the
  number of banks. The Tab order through the pane is therefore filters, Add
  bank, Bank actions, archive, bank search, banks; before it was filters, Add,
  archive, search, More, banks.
- **Names say what for.** `Add` is `Add bank`, and the two `More` are `Bank
  actions` and `Slot actions`; the accessible names begin with the words on the
  button and keep the thing (`Bank actions for My Bank`, `Slot actions for
  Delta`). The names of the menus, the items, the group and every other control
  are as they were. There is no `Preset actions`: the details of a preset have
  one action, Load, and the star is not mirrored there, as above.
- **What replaces or removes is last in its menu and set apart by a rule.**
  Close bank and Move. It is a rule on the item and not a separator element, so
  that every child of a menu is an item the arrows land on; an item that does
  not apply is still pressed and refused by the panel.
- **A bank's name leads.** It is the larger text, and where it came from and
  `Read-only` are words under it and level with it, in the quiet ink, not
  capitals and not boxes. One selected treatment for the bank in view.
- **Dialogs are titled for the task**: `Browse presets`, `Write to slot`, `Save
  preset as`; a copy and a move already were (`Copy <name> to...`). The note on a
  ZIP that has to be opened by path says `in the Archive field under Browse`.
- **Three tiers of action, one at a time.** The primary is filled (Done, Write
  or Save, Load, a question's confirm); what is beside it is outlined and
  quieter (Export, Keep, Cancel, Slot actions); an action that replaces or
  removes something is in a destructive tier, which is a flag on the action
  (`{ destructive: true }`) and not a colour: no fill and the brightest edge, in
  the same silver. A question sets its confirm there when it is an Overwrite, a
  Close bank, a Move, or a Copy onto a slot that holds something; a Copy into an
  empty slot is a primary and nothing more. No new colour was added.
- **What the last action said is where the action was.** Browsing, it is under
  the tabs and over the workspace, where it is in view with the pane and the
  details shut -- not under a list that has to be scrolled; the first message
  makes the workspace one line shorter. A destination says it directly under its
  form, as it did. There is still one `.browser-feedback` and one status region
  for a message. The archive's and the bank form's own messages stay beside their
  own controls.

These are checked in `tests/ui/preset-browser-structure.test.mjs` and
`tests/ui/preset-modal.test.mjs` (the stand-in DOM: headings, order, names, the
rule, the tiers, titles and where the message is) and
`tests/ui/preset-browser-layout.test.mjs` (a real engine: that the headings are
on view in order and quiet, that a bank's name is larger than what is said about
it, that the quiet controls are still targets, that the primary is filled and a
destructive confirm is not, and that a message is on view under the tabs on a
narrow window). WebKit's engine was not available where this was done, so the
layout checks ran in Chromium only.

Deferred, not done: a bottom sheet for the details (they are a section under
the workspace).
