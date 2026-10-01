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
| the current patch identity (slot, bank label, name) and where it came from (`source`, archive bank and patch) | the daemon |
| the patch archive: its remembered path, the open archive bank, and `archive_rev` | the daemon |
| master volume | the daemon |
| the selected native MIDI input, and `midi_rev` | the daemon |
| the browser page | nobody: it is a view |

The adapter keeps nothing that outlives a connection: what the page is believed
to show, which writes are still in flight, the bank it last sent, and the last
`archive_rev` and `midi_rev` it saw. All of it exists to decide what to tell
the page.

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
| `sync` | nothing; the page is sent `bank`, `state`, `patch`, `archive` (only from a daemon that shares one), `midi`, in that order |
| `set` | `parameter.set <id> <value>` |
| `state` | see below: dropped, `patch.load <k>`, or `patch.apply` then `patch.clear` |
| `edit` | nothing, by design: gesture brackets are for hosts that record automation, and the daemon records none |
| `note` | `midi 144\|128 <note> <velocity>` (on the message's channel) |
| `wheel` | pitch: `midi 224 <lsb> <msb>` (−1..1 onto 0..16383); mod: `midi 176 1 <0..127>` |
| `cc` | `midi 176 <cc> <value>` |
| `volume` | `volume <round(value × 1000)>`, clamped to 0..1000 |
| `bank` | the text goes to a private temporary file for `bank.load_file`; `save: true` adds `bank.keep` |
| `patch-step` | when the sound came from an archive bank (`source` `archive` with both archive indices): `archive.bank <b>` for its patch count, then `archive.load <next> <b>`, wrapping round that bank; otherwise `patch.load` of the next filled slot in that direction, wrapping round the bank |
| `midi-select` | `midi.select <id>` (`all`, `none` or an input's id, one token); answered with `midi` |
| `midi-list` | nothing changes; `midi.current` and a fresh `midi.list`, answered with `midi` |
| `archive-open` | `archive.open <path>`, or `archive.open` (reopen the remembered path) when `path` is absent or `""`; answered with `archive` |
| `archive-bank` | `archive.bank <index>`; answered with `archive` |
| `archive-load` | `archive.load <index> <bank>`; answered with `archive` |
| `archive-close` | `archive.close`; answered with `archive` |

To the page go `state` (all 99 values), `param` (one value), `patch`
(`{name, index, bank, source, archive}`, see below), `bank` (a
`quesynth.bank` document), `archive` (the daemon's archive, see below), `midi`
(`{inputs: [{id, name}], selected, name, rev}`: the daemon's MIDI selection,
its display name, `midi_rev`, and what `midi.list` found), and `error`
(`{for, code, message}`), which the panel ignores and `host.js` logs with
`console.warn`. Every field is checked before a command is built; a bad
message, an unknown type or broken JSON gets an `error` and the socket stays
open. A `midi-select` the daemon refuses gets an `error`, then a `midi` with
the selection it kept.

`patch` says what the daemon is playing and where it came from:

```json
{"type":"patch","name":"Bells","index":5,"bank":"My Bank","source":"bank","archive":null}
{"type":"patch","name":"Bells","index":null,"bank":"aaa bbb Thanks Ms Ichiro 01.zip","source":"archive","archive":{"bank":0,"patch":3}}
```

`index` is only ever a slot of the ordinary bank, null when the identity names
none. `source` is `patch.current`'s: `none`, `bank`, `archive` or `file`. A
daemon older than that field gets one worked out from what it does say: a slot
is `bank`, no bank label and no name is `none`, the label `file` is `file`, a
label ending `.zip` (only an archive bank has one) is `archive`, anything else
`bank`.
`archive` is `{bank, patch}`, the archive bank and patch the sound was loaded
from, only while `source` is `archive` and the daemon still reports both
indices (`archive_bank`/`archive_patch` at least 0: it stops once that archive
is closed or replaced); otherwise null. So patch 5 of an archive bank is never
mistaken for slot 5 of the ordinary bank.

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

## The shared archive

The daemon browses a patch archive -- a zip of bank zips -- without unpacking
it, and everything about it is the daemon's: the path it remembers, the
archive bank it has open, and where an archive patch came from. The open bank
is shared, so a bank one client opens is the one every client is shown.

A daemon shares its archive when its `patch.current` carries `archive_rev`.
The page is then sent an `archive`:

```json
{"type":"archive","rev":3,"open":true,"path":"/srv/quesynth/patch banks.zip","banks":["aaa bbb Thanks Ms Ichiro 01.zip","bankB.zip","empty.zip"],"bank":1,"patches":["Pad 2","Bass","Keys"]}
{"type":"archive","rev":4,"open":false,"path":"","banks":[],"bank":null,"patches":[]}
```

- `rev` is `archive_rev`.
- `path` is the path the daemon remembers, `""` when none. It can be set
  while `open` is false: the remembered archive did not open (a zip on a disk
  that is not mounted, say).
- `banks` names every archive bank; a name's position is that bank's index
  in `archive.banks`. `bank` is the open bank's index, or null. `patches`
  names every patch of the open bank by index, `[]` when none is open. With
  `open` false, `banks` and `patches` are empty and `bank` is null.
- Names are the daemon's own strings: spaces kept, nothing trimmed.

It is sent after the `patch` on `sync`, when a poll finds `archive_rev`
moved, and after each of this page's archive requests. The names are read
with `archive.banks` and `archive.patches`, 256 a request, until each
answer's `total`. Every answer carries `archive_rev` (and `archive.patches`
its bank), so one from another generation shows a client moved the archive
between two requests, and the read starts again from `archive.current`. After
three tries what was read is sent anyway, and the next poll reads it again.

The page asks for changes with four messages:

```json
{"type":"archive-open","path":"/srv/quesynth/patch banks.zip"}
{"type":"archive-bank","index":1}
{"type":"archive-load","bank":1,"index":2}
{"type":"archive-close"}
```

- `archive-open`: `path` absent or `""` reopens the remembered path;
  otherwise it is a string of 1 to 4096 UTF-8 bytes (so no lone surrogate)
  with no control character (C0, DEL or C1) and neither U+2028 nor U+2029,
  which the daemon keeps as given (trimmed). The archive opens with no bank
  open.
- `archive-bank`: `index` is a non-negative integer. It opens that bank for
  browsing; it loads no sound and leaves the identity alone.
- `archive-load`: `bank` and `index` are non-negative integers. `bank` is the
  bank the page is showing: if a client opened another since, the daemon
  opens the page's again before loading, so the patch loaded is the one the
  page's list names.
- `archive-close`: closes the archive and makes the daemon forget its path.

Anything else in those fields gets an `error` with code `invalid_payload`,
and nothing is sent to the daemon. A valid request is answered with an
`archive`. One the daemon refuses is first reported, then answered all the
same, so the page never goes on showing a view the daemon does not hold:

```json
{"type":"error","for":"archive-load","code":"invalid_payload","message":"patch index out of range"}
```

Other pages learn of a change from `archive_rev` on their next poll, and the
TUI from its own. Nothing about the archive goes through a file: no
`bank.load_file` and no temporary bank. Nothing else asks the archive
anything either: a `state` or a `bank` from the page never becomes an archive
request, and an ordinary load, store, bank change or `patch.clear`, from any
client, leaves the archive and its open bank as they were.

A daemon without `archive_rev` in its `patch.current` (one older than the
shared archive), or one that answers `archive.current` with
`unknown_command` or `daemon_not_ready` (no archive support), is not polled
for an archive on that connection, and the page is never sent an `archive`;
it keeps its own zip handling. An archive request is then answered with an
`error` carrying the code and message the daemon gives `archive.current`,
and nothing else is sent to it: an older daemon has archive verbs of its
own, and what they did could not be shown. A request that arrives before
`sync` is checked the same way first.

## Keeping the page in step

Each page has its own daemon connection and polls `patch.current` every
`--poll-ms` (100 ms); a poll is only armed once the last has finished. Its
answer says what moved. If `bank_rev` moved, the bank is dumped with
`bank.write` to a private temporary file and sent; if the revision moved,
`state.snapshot` is read and the parameters that differ from what the page
shows go as `param`s, or as one `state` when more than eight moved; if the
identity moved (its slot, bank label, name, `source` or archive indices), a
`patch` follows. A new bank is always followed by a full `state` and a
`patch`, because adopting it moved the page to slot 0. If `archive_rev` moved,
or the last read of the archive was cut short, the archive is read again and
an `archive` sent. Each poll then asks `midi.current`; if `midi_rev` moved,
`midi.list` is read and a `midi` sent. That is how a selection made in the
TUI reaches the page. A daemon with no selection to offer is not polled for
one again on that connection; opening the page's MIDI list still asks.

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
- An archive path from the page is handed to the daemon as given (checked
  only to be one line of at most 4096 bytes), so the page can have the daemon
  open any zip the user can read; the checks above are what keep that to the
  adapter's own page.

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
`archive.test.mjs` covers the shared archive against the stand-in's archive,
held in memory but answering as `hosts/standalone/archive.odin` does, and as a
daemon from before `archive_rev` did.
