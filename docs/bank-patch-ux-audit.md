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
