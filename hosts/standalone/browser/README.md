# Native browser front-end

`quesynth --browser` attaches to (or starts) the standalone daemon, serves the
shared `ui/` panel on `127.0.0.1`, and opens the default browser. The page is a
peer of the TUI: both are clients of the same daemon, and a change made in
either shows up in the other.

```sh
./build/quesynth --browser
QUESYNTH_ROOT=/path/to/quesynth ./build/quesynth --browser   # outside the tree
node hosts/standalone/browser/serve.js --socket PATH [--root DIR] [--port 8177] [--poll-ms 100] [--no-open]
```

The adapter needs Node.js 20 or later and uses only built-in modules:
`serve.js` (command line, HTTP, upgrade), `websocket.js` (RFC 6455, server
side), `daemon.js` (the control socket's framing), `session.js` (one page and
its daemon connection), `bank.js` (reading a bank document), and `host.js` (the
page's transport, served as `/ui/host.js`).

## Who owns what

| thing | owner |
|---|---|
| the 99 parameter values and their revision | the daemon (the audio thread publishes them) |
| the 128-slot bank, its label, and `bank_rev` | the daemon |
| the current patch identity (slot, bank label, name) | the daemon |
| master volume | the daemon |
| the selected native MIDI input, and `midi_rev` | the daemon |
| the browser page | nobody: it is a view |

The adapter keeps nothing that outlives a connection: what the page is believed
to show, which writes are still in flight, the bank it last sent, and the last
`midi_rev` it saw. All of it exists to decide what to tell the page.

## The page runs as a hosted panel

The adapter does not serve `/ui/store.js` or `/ui/bank.js`; both are 404.
`store.js` makes the page remember the sound and the bank in local storage, and
`bank.js` is a factory bank compiled into the page. Either would be a second
authority that could overwrite the daemon on page load. `ui/index.html` loads
both behind `onerror="void 0"` so that a host that owns persistence can leave
them out, exactly as a plugin does. Without them `SynthBank.hosted()` is true,
the page never sends its own slot 0 at load, and it gets the daemon's bank and
identity on `sync`.

## The page never uses Web MIDI

The daemon reads the MIDI devices itself, and by default every input it can
open. Web MIDI in the page would be a second way in for the same keyboard,
and every note would sound twice. So `host.js` sets `window.SynthHostMidi` as
it loads, before `ui/midi.js` runs, and the panel then never asks for Web MIDI,
never listens to an input, and refuses one handed to `SynthMidi.connect`. The
MIDI button shows the daemon's selection instead (All inputs, one input, or
None), and choosing another only asks the daemon (`midi-select`). The page
keeps no selection of its own, so the button changes only when the daemon's
answer comes back. The TUI changes the same selection, and each sees the
other's change.

A daemon older than the MIDI selection answers `unknown_command`, and one with
no MIDI input `daemon_not_ready`. Neither closes the page, as a refused
`patch.current` would. The page is sent `midi` with `selected: null` and no
inputs, the button offers nothing to choose, and Web MIDI stays off all the
same.

## Messages

What each message of `ui/bridge.js` does here:

| from the page | effect on the daemon |
|---|---|
| `sync` | nothing; the page is sent `bank`, `state`, `patch`, `midi`, in that order |
| `set` | `parameter.set <id> <value>` |
| `state` | see below: dropped, `patch.load <k>`, or `patch.apply` then `patch.clear` |
| `edit` | nothing, by design: gesture brackets are for hosts that record automation, and the daemon records none |
| `note` | `midi 144\|128 <note> <velocity>` (on the message's channel) |
| `wheel` | pitch: `midi 224 <lsb> <msb>` (−1..1 onto 0..16383); mod: `midi 176 1 <0..127>` |
| `cc` | `midi 176 <cc> <value>` |
| `volume` | `volume <round(value × 1000)>`, clamped to 0..1000 |
| `bank` | the text goes to a private temporary file for `bank.load_file`; `save: true` adds `bank.keep` |
| `patch-step` | `patch.load` of the next filled slot in that direction, wrapping round the bank |
| `midi-select` | `midi.select <id>` (`all`, `none` or an input's id, one token); answered with `midi` |
| `midi-list` | nothing changes; `midi.current` and a fresh `midi.list`, answered with `midi` |

To the page go `state` (all 99 values), `param` (one value), `patch`
(`{name, index, bank}`, `index` null when no slot), `bank` (a `quesynth.bank`
document), `midi` (`{inputs: [{id, name}], selected, name, rev}`: the daemon's
MIDI selection, its display name, `midi_rev`, and what `midi.list` found),
and `error` (`{for, code, message}`), which the panel ignores and `host.js`
logs with `console.warn`. Every field is checked before a command is built; a
bad message, an unknown type or broken JSON gets an `error` and the socket
stays open. A `midi-select` the daemon refuses gets an `error`, then a `midi`
with the selection it kept.

A `state` is a whole patch, and three things send one:

- **The page's echo of a bank it was sent.** Adopting a bank makes the panel
  select slot 0 (or Init when slot 0 is empty) and post it back. The bank came
  from the daemon, so this is not a request; the first `state` equal to that
  sound after each `bank` (within two seconds) is dropped.
- **A slot of the bank the page was shown**, when the values are exactly a
  filled slot's (the page's PREV/NEXT and bank browser load by value). It
  becomes `patch.load <k>`, the slot already current if it matches, else the
  lowest, so the daemon records the identity every client then shows.
- **Anything else** (a patch file): `patch.apply` of every value the daemon
  exposes, then `patch.clear`, since a sound no slot holds has no name. It is
  `patch.apply` and never `parameter.set_many`: a whole patch is an atomic
  replacement on the audio thread, which resets the previous patch's effect
  tails and smoothers as `patch.load` does, while `set_many` is an ordinary
  batch edit that leaves them running. A `set` is still `parameter.set`.

A `bank` from the page is how the panel stores a patch (`SynthBank.store`): it
posts the whole bank with one slot changed. When exactly one slot differs, it
is filled with a plain name (non-empty, no control characters), the bank label
is unchanged, and its values equal what the page shows (the seven hidden
parameters aside), it is sent as `patch.save <slot> <name>`, so the daemon
records that slot and name as the identity. Anything else (a cleared slot,
several slots, another bank, other values, no name) is adopted whole with
`bank.load_file`, which leaves the identity naming no slot. Either way the
sender is not sent its bank back.

## Keeping the page in step

Each page has its own daemon connection and polls `patch.current` every
`--poll-ms` (100 ms); a poll is only armed once the last has finished. Its
answer says what moved. If `bank_rev` moved, the bank is dumped with
`bank.write` to a private temporary file and sent; if the revision moved,
`state.snapshot` is read and the parameters that differ from what the page
shows go as `param`s, or as one `state` when more than eight moved; if the
identity moved, a `patch` follows. A new bank is always followed by a full
`state` and a `patch`, because adopting it moved the page to slot 0. Each
poll then asks `midi.current`; if `midi_rev` moved, `midi.list` is read and a
`midi` sent. That is how a selection made in the TUI reaches the page. A
daemon with no selection to offer is not polled for one again on that
connection; opening the page's MIDI list still asks.

A page's own write outranks the daemon's value for that parameter until the
daemon reports the written value or 500 ms pass, so a knob does not flick back
while the audio thread has yet to apply it. After that the daemon's value wins,
which is also how a change another client made to the same parameter inside
that window reaches the page. A bank the page sent is not sent back to it;
other pages get it.

The daemon's registry leaves out seven parameters (50, 51, 86 to 89, 94; see
`src/registry/registry.odin`), so they can be neither read nor set over the
socket. The page is shown the values of the slot the identity names, or the
Init values when there is none, and a `set` of one of them is refused.

An identity with no name (a fresh daemon, or after `patch.clear`) is sent to
the page as `Untitled`, the panel's own name for an unnamed sound: the panel
ignores an empty name and would keep showing the first patch of the bank it
just adopted while the daemon plays something else.

## When things go wrong

- **Daemon down or full**: the WebSocket upgrade is answered `503` (the daemon
  connection is made before the upgrade completes), and `host.js` retries with
  backoff from 250 ms to 5 s, marking the page with
  `data-host-error="daemon"` on `<html>` until it is back.
- **Daemon lost mid-session**, an unanswered request (3 s), or a malformed
  frame from the daemon: the page is closed with `1011` and reconnects.
- **What is dropped**: anything the page sends while disconnected, once it has
  been connected. It is never replayed; a reconnection starts with `sync` and a
  fresh snapshot, as the TUI's does. Before the first connection, up to 256
  messages are held (the startup volume, mostly).
- **A refused write** (by the adapter or the daemon) is reported with `error`,
  and the page is sent the daemon's values again so it never shows something
  the daemon did not take. A refused bank is followed by the daemon's bank.
- A page that disappears (closed tab, reset connection) takes its daemon
  connection and any temporary files with it. SIGINT or SIGTERM closes every
  page with `1001` and exits 0; a busy port exits 1 with a message.

## Security

The adapter can rewrite the user's saved bank (`bank.keep`), so it is local
only and checked:

- It listens on `127.0.0.1` alone.
- Every request must carry `Host: 127.0.0.1:<port>` or `localhost:<port>`
  (a hostname rebound to 127.0.0.1 is refused), and a WebSocket upgrade with
  an `Origin` must come from one of those two. Other pages cannot open it.
- Only the `ui/` directory is served, minus `store.js`, `bank.js` and
  dotfiles, checked after resolving symbolic links; everything else, including
  the rest of the repository, is 404.
- Bank files handed to the daemon live in a fresh `0700` directory that is
  removed as soon as the daemon has read or written them.

## Tests

```sh
node --test tests/browser/*.test.mjs
```

They run the adapter in process against `tests/browser/support/fake-daemon.mjs`,
a stand-in speaking the real framing with the registry's real ids. The bank
fixture is written by the daemon's own writer (`tests/browser/fixtures/genbank`),
and `panel-native.test.mjs` boots the real panel scripts against the adapter.
`midi.test.mjs` does the same to check that a hosted page never touches Web
MIDI and that a page without `host.js` still uses it.
