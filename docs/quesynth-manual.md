# Quesynth standalone manual

This manual covers the native standalone build on Linux: the audio daemon, the
terminal UI (TUI), the browser front-end, banks and archives, MIDI input, the
files Quesynth keeps, and the stdio MCP server. The instrument itself, its
panel and its sound design are in the [wiki](https://github.com/mauro-moreno/quesynth/wiki).
The VST3, CLAP, Audio Unit and WebAssembly builds are described in the
[README](../README.md#building-and-testing) and in the `hosts/` READMEs.

Everything here was checked against the source under `hosts/standalone/`,
`src/control/` and `src/registry/`. Where the source and an older document
disagree, the source wins.

Contents:

- [Install and build](#install-and-build)
- [The daemon](#the-daemon)
- [Terminal UI](#terminal-ui)
- [Browser](#browser)
- [Banks and archives](#banks-and-archives)
- [Patch identity](#patch-identity)
- [MIDI](#midi)
- [Configuration and persistence](#configuration-and-persistence)
- [MCP server](#mcp-server)
- [Troubleshooting](#troubleshooting)
- [Safety](#safety)

## Install and build

You need [Odin](https://odin-lang.org) to build. Node.js 20 or later is needed
only for `--browser`. Run every command from the repository root.

```sh
odin build hosts/standalone -o:speed -out:build/quesynth
./build/quesynth --help
```

The binary loads `libasound.so.2` at run time for audio and MIDI, so no ALSA
development package is needed to build. PipeWire and PulseAudio serve the same
`default` ALSA device. On Windows the standalone uses WASAPI and WinMM, and
`odin build hosts/standalone -o:speed -out:build/quesynth.exe` builds it.

Only the Linux build has a control socket. On Windows `--daemon` plays
and listens to MIDI, but the TUI, `--browser`, `--stop` and `--mcp` report
that they are not supported there yet. On other targets the daemon reports
that no audio backend exists.

Run the tests the way [CONTRIBUTING.md](../CONTRIBUTING.md) lists them. The
standalone and TUI suites are `odin test tests/standalone` and
`odin test tests/tui`.

To check a patch without any audio or MIDI hardware, render it to a file:

```sh
./build/quesynth --selftest patch.sy1 out.wav
```

`--selftest` takes exactly those two operands. It holds middle C for 1.5 s,
adds a 1.0 s release tail, writes a 48 kHz stereo WAV, opens no device, and
exits 0 only if the patch loaded and the file was written. CI uses it.

The binary finds `ui/` and the browser adapter relative to the working
directory. If you run it from elsewhere, set `QUESYNTH_ROOT` to the repository
root (see [Browser](#browser)).

The command forms are:

```sh
./build/quesynth [--bank bank.json] [patch.sy1]
./build/quesynth --daemon [--bank bank.json] [patch.sy1]
./build/quesynth --browser [--bank bank.json] [patch.sy1]
./build/quesynth --mcp
./build/quesynth --stop
./build/quesynth --selftest patch.sy1 out.wav
```

`./build/quesynth --help` prints them to stdout with a short description of
each and exits 0. `--bank` may appear once. A second positional argument, a
second `--bank`, an operand after `--stop` or `--mcp`, or an unknown option
prints an error and the usage to stderr and exits 2.

## The daemon

### Starting and attaching

The daemon owns the audio device, the engine, the MIDI inputs, the patch bank,
the archive and the control socket. Front-ends attach to it and can come and go
without interrupting the sound.

| Command | What it does |
|---|---|
| `./build/quesynth --daemon` | Runs the daemon in the foreground. Prints its state and Ctrl-C stops it. |
| `./build/quesynth` | Attaches the TUI. If no daemon is listening, starts one first. |
| `./build/quesynth --browser` | Same attach-or-start, then serves the browser panel. |
| `./build/quesynth --stop` | Asks the running daemon to shut down. |

A daemon started by the TUI or the browser is detached: it forks twice,
leaves the terminal's session, and points its standard streams at `/dev/null`.
Quitting the TUI does not stop it, and you will not see its output. To read
the daemon's log, run `--daemon` yourself in a terminal. It prints lines such as
`audio ALSA (default) rate=48000 ...`, `patch ...`, one `midi [n] name` line
per input, `archive <path>` when it reopened one, `control <socket path>`, and
`quesynth daemon ready; press Ctrl-C to stop`.

The patch argument and `--bank` apply only when this command starts the daemon.
If one is already running, `quesynth patch.sy1` attaches and the argument is
ignored. Without a patch argument the daemon plays the built-in defaults,
named `(defaults)`.

After starting a daemon, the TUI and the browser wait up to five seconds for
its socket. If it never appears they print
`error: could not start or reach a daemon` and exit 1.

### Socket path

The daemon, the TUI, `--stop` and `--mcp` use one path, chosen like this:

1. If `XDG_RUNTIME_DIR` is set and non-empty, the socket is
   `$XDG_RUNTIME_DIR/quesynth/quesynth.sock`. The `quesynth` directory is
   created with mode 0700.
2. Otherwise it is `/tmp/quesynth-<uid>.sock`.

Beside the socket the daemon keeps a lock file named `<socket>.lock`. The
socket itself has mode 0600. The Odin binary does not read `QUESYNTH_SOCKET`.
That variable is read only by the browser adapter, as the default for its
`--socket` option, so that it can reach a daemon whose socket you located
yourself. To move the daemon's own socket, change `XDG_RUNTIME_DIR` for it and
for the clients that should find it.

### Single instance, stale sockets and shutdown

A second `--daemon` while one is listening prints
`a quesynth daemon is already running at <path>` and exits 0. Starts are also
serialised by an exclusive lock on the lock file, taken before the audio device
is opened, so two simultaneous starters cannot both win.

A socket file left by a crashed daemon is removed at the next start, but only
if it is a socket, owned by you, and refuses connections. A regular file at that
path, a socket owned by someone else, or a live listener makes the start fail
with `error: control endpoint is owned or unavailable: <path>` and exit 1.

The daemon stops on Ctrl-C, on SIGTERM, and on `quesynth --stop`. All three
raise the same flag and the main thread tears down in order: stop accepting
clients, stop the audio stream, then free the engine. If its socket file is
removed or replaced while it runs, the daemon notices within about a second
and shuts itself down, so it never keeps sounding with no way to steer it.

`--stop` prints `stop requested` and exits 0. If nothing is listening it prints
`error: no daemon listening at <path>` and exits 1.

If the audio device cannot be opened the daemon prints
`error: cannot open an audio output device` and exits 1. A missing MIDI
backend or no MIDI hardware is not an error. The daemon runs and has nothing to
listen to.

### What the daemon owns

The daemon keeps these, and every front-end shows the same values:

- the parameter values and their revision
- the 128-slot ordinary bank, its label and `bank_rev`
- the patch identity (see [Patch identity](#patch-identity))
- the archive, its remembered path, its open bank and `archive_rev`
- the selected MIDI input and `midi_rev`
- the master volume

A front-end keeps no copy of these that outlives its connection.

### Control protocol

Clients talk to the daemon over the Unix socket, in the Quesynth Control
Protocol (QCP). The framing is in `src/control/codec.odin` and the messages in
`src/control/message.odin`.

- Each message is a 4-byte little-endian length followed by that many payload
  bytes. The payload limit is 64 KiB. A longer frame closes the connection.
- A request is one line: `1 <id> <command> [operands]`. `1` is the protocol
  version.
- A response starts with `1 <id> ok [key=value ...]` or
  `1 <id> err <code> [message]`, optionally followed by record lines.
- Error codes are `unsupported_version`, `unknown_command`, `invalid_payload`,
  `unknown_parameter`, `out_of_range`, `daemon_not_ready`,
  `transaction_failed`, `internal_error` and `revision_conflict`.

`parameter.set_many` takes `<id> <value>` pairs and checks the whole batch
(every id, every integer, every range, and at most 128 pairs) before it queues
anything. The audio thread then applies the batch as one transaction at a block
boundary, so the revision moves once. Duplicate ids apply in order, and the
last one wins. The reply is `ok count=<n> revision=<r>`, where `r` is the
revision the daemon had published when it queued the batch.

The request may instead start with `expected_revision=<n>`, as its first token
and with `n` a non-negative integer:

```text
parameter.set_many [expected_revision=<n>] <id> <value> ...
```

Then the audio thread applies the batch only if the revision it holds equals
`n` when it reaches the batch. The daemon queues the batch, waits for the audio
thread to apply or refuse it, and replies once the new state is published, so a
`state.snapshot` sent after the reply sees it. On success the reply is
`ok count=<n> revision=<r>` with `r` the revision after the change. If the
revision differs, nothing is applied and the reply is
`err revision_conflict current_revision=<r>`, with `r` the revision now. If the
audio thread has not answered within 250 ms the reply is
`err daemon_not_ready commit outcome unknown; inspect state before retrying`:
the batch stays queued and may still be applied. A first token that starts with
`expected_revision=` and is not followed by a non-negative integer is refused
with `invalid_payload expected_revision needs a nonnegative integer`.
`patch.apply` takes no `expected_revision`.

The daemon serves at most 16 connections at once. It drops a client whose
unread output passes 256 KiB. You rarely need to speak the protocol by hand,
because the TUI, the browser adapter and the [MCP server](#mcp-server) do.

### What survives a restart

Kept on disk: the archive path, and the user bank when one was written to the
config directory (see [Configuration and persistence](#configuration-and-persistence)).
Not kept: parameter values, the current patch, the patch identity, the MIDI
selection (it starts at all inputs), and the master volume (it starts at full
level). A restarted daemon plays `patch.sy1` if you give one and the built-in
defaults otherwise.

## Terminal UI

```sh
./build/quesynth
```

The TUI attaches to the daemon, reads every parameter in one request, and
refreshes about every 400 ms. It holds no sound state. When the daemon's
revision moves, because another client loaded a patch or a MIDI controller
changed something, the values are read again.

Q, Ctrl-C or a closed terminal quits the TUI and leaves the daemon running.
If the daemon goes away the footer shows
`DISCONNECTED - cached values are stale; edits disabled`, and Enter
reconnects.

The theme is read from `theme.conf` in the config directory, and written there
with the Catppuccin Mocha palette the first time the TUI runs. `NO_COLOR` set to
anything non-empty turns colour off.

### Synth screen

Parameters are listed one group at a time, each with its value and a bar.

| Key | Action |
|---|---|
| Tab | Next parameter group |
| Up, Down | Select a parameter |
| Left, Right | Change the selected parameter by one stored step |
| R | Reset the selected parameter to its default |
| B | Open the bank navigator |
| O | Load a patch file (`.sy1` or JSON), by typing its path |
| L | Load a bank file (JSON), by typing its path |
| M | Open the MIDI input screen |
| C | Open the settings screen |
| Q | Quit the TUI |

The top of the screen shows the playing patch and the selected MIDI input. The
status line at the bottom shows the voice count, the sample rate, the buffer
size, the revision and the uptime.

### Bank navigator

B opens one list of banks: the ordinary bank first, then every bank of the open
archive. Enter on a bank lists its patches. Enter on a patch loads it and
returns to the synth screen. Moving the cursor never changes the sound.

The cursor is `>`. The patch that is currently sounding is marked `*`, and only
when the row is the very patch the sound came from. Patch 5 of an archive bank
is not marked as slot 5 of the ordinary bank.

| Key | Action |
|---|---|
| Up, Down | Move the cursor |
| Enter | At the banks, open the bank. At the patches, load the patch |
| Esc | Back from patches to banks, and from banks hide the navigator |
| B | Hide the navigator |
| S | Save the sound into the selected ordinary-bank slot |
| O, L | Load a patch file or a bank file |
| Z | Open a ZIP archive |
| Q | Quit |

S asks for a name, then offers to write the whole bank to a file (blank skips).
It works only in the ordinary bank, since an archive is read-only. Prompts take
printable ASCII. Escape cancels, so a path with other characters cannot be
typed there; open it with the browser.

A saved slot lives in the daemon's memory. It survives a restart only if you
wrote the bank to a file and that file is the daemon's `--bank`, the TUI's
`User bank` setting, or `bank.json` in the config directory.

### MIDI input screen

M lists All inputs, each input the daemon found, and None. `(*)` marks the one
the daemon listens to. Enter selects the row under the cursor. R scans again for
devices plugged in since. Esc goes back. If the daemon refuses a choice, the
footer says `the daemon refused ...` and the screen stays open.

### Settings screen

C shows two settings, selected with Up and Down and edited with Enter.

- `Zip archive`. A path opens that archive in the daemon for every front-end. A
  blank answer closes the archive and forgets its path.
- `User bank`. The path is written to `config.conf` and loaded now.

The screen footer prints the path of `config.conf`.

## Browser

```sh
./build/quesynth --browser
```

This attaches to or starts the daemon, starts the Node adapter
`hosts/standalone/browser/serve.js`, and opens the default browser at
`http://127.0.0.1:8177`. The page is the shared `ui/` panel. It is a peer of
the TUI. A patch loaded in one shows in the other, and so does a change of
bank, archive or MIDI input.

- The adapter listens on `127.0.0.1` only, and checks the `Host` and `Origin`
  headers, so a page from another site cannot reach it.
- The port is 8177. `quesynth --browser` has no port option. To pick another,
  start the adapter yourself:
  `node hosts/standalone/browser/serve.js --socket PATH --port 9000 --no-open`.
  The adapter's other options are `--root DIR` and `--poll-ms N` (10 to 10000).
- `quesynth --browser` runs until the adapter exits, and returns its exit code.
  Ctrl-C stops the adapter and leaves the daemon playing.
- The adapter runs `node` from `PATH`. If it cannot start, the command prints
  `error: could not start node; is Node.js installed?`.
- It serves `ui/` from `QUESYNTH_ROOT`, or from the working directory when that
  is unset. The directory must contain `ui/` and `ui/params.js`.
- The page never uses Web MIDI. The daemon reads the MIDI devices, and a second
  path would play every note twice. The page's MIDI button shows and changes
  the daemon's selection.
- The page does not keep its own sound or bank in local storage. It shows what
  the daemon holds.

When the page saves a bank, the adapter also sends `bank.keep`, and the daemon
writes it to `bank.json` in the config directory, which it loads at its next
start.

The message-level contract between the page and the daemon is in
[hosts/standalone/browser/README.md](../hosts/standalone/browser/README.md).

## Banks and archives

There are two kinds of bank, shown as one list in the TUI navigator and in the
browser.

The ordinary bank has 128 slots. Each slot is empty or holds a patch. The
daemon starts with the factory bank, labelled `Factory`, then replaces it with
a user bank when there is one:

1. the file given with `--bank`, if you gave one
2. otherwise `bank.json` in the config directory, if it exists

If that file cannot be read or parsed, the daemon prints
`bank   could not load <path>; using the factory bank` and keeps the factory
bank. Loading a bank file later (`L`, or the daemon's `bank.load_file`)
replaces the browsable bank only. It does not change the sound.

An archive is a ZIP file of bank ZIPs, each holding `.sy1` patches. The daemon
indexes the outer ZIP and reads one inner bank and one patch at a time, so a
corpus of tens of thousands of patches is not unpacked into memory. Banks and
patches are listed in the order they are stored in the ZIP, and a patch is
listed by the name inside its file, or by the file name when it has none.

Opening, browsing and loading are separate:

- Opening an archive (`Z` in the TUI, or `archive.open`) indexes it and
  remembers its path. It loads no sound.
- Opening a bank (`archive.bank`, or Enter on a bank row) is browsing. It is
  shared, so a peer showing the archive follows. It does not change the sound.
- Loading a patch (`archive.load`, or Enter on a patch row) replaces the sound.
  Held notes keep sounding.

`archive.load` accepts an optional bank. Send it when your list came from a
particular bank, since a peer may have opened another one since you listed it.

Two counters tell a polling client when to read again. `bank_rev` moves when
the ordinary bank's contents or label change. `archive_rev` moves when the
archive or its open bank changes, including a change from another client. Both
appear in `patch.current`. Asking for the bank that is already open does not
move `archive_rev`.

An archive is closed with `archive.close` (the settings screen does it when you
give a blank path). That also deletes the remembered path.

## Patch identity

The daemon records which patch is sounding, so every front-end names it the
same way. `patch.current` returns:

| Field | Meaning |
|---|---|
| `slot` | The ordinary-bank slot, or `-1` for none |
| `source` | `none`, `bank`, `archive` or `file` |
| `bank_rev` | Generation of the ordinary bank |
| `revision` | Parameter revision |
| `archive_rev` | Generation of the archive |
| `archive_bank`, `archive_patch` | Where an archive patch came from, `-1` otherwise |
| `bank` | Bank label, on its own line, spaces kept |
| `name` | Patch name, on its own line, spaces kept |

A fresh daemon reports `slot=-1` and `source=none`, even if it was started with
a patch file. How the identity changes:

| Event | `source` | `slot` | `bank` | `name` |
|---|---|---|---|---|
| Load an ordinary slot, or a Program Change that picks one | `bank` | the slot | the bank label | the slot's name |
| Save into a slot | `bank` | the slot | the bank label | the saved name |
| Load a patch file | `file` | `-1` | `file` | the name in the file, else the file name |
| Load an archive patch | `archive` | `-1` | the archive bank's file name | the patch name |
| Load a bank file | unchanged | `-1` | unchanged | unchanged |
| Close or replace the archive | unchanged | unchanged | unchanged | unchanged, but `archive_bank` and `archive_patch` become `-1` |

Loading a bank file leaves the sound's provenance alone, since the sound did not
change, but the old slot number would now point into a different bank, so the
slot becomes `-1`. Editing a parameter does not change the identity. Names are
cut to 48 bytes, and a line break in a name becomes a space.

## MIDI

### Choosing an input

By default the daemon opens every MIDI input. One selection is shared by every
front-end, so the TUI and the browser never listen to the same keyboard twice.

- `midi.list` enumerates the inputs now, without caching, so a controller
  plugged in since the last call is there. Each record has an `id` and a
  `name`. On Linux an id is `hw:<card>,<device>`, on Windows `winmm:<index>`.
  Two identical controllers can share a name, so choose by id.
- `midi.select` takes `all`, `none` or an id from the list. `none` stops
  listening to hardware only. Injected messages (below) still arrive. Switching
  closes the old inputs and does not release notes. A note held on an input
  that was closed sounds until a note off arrives some other way.
- `midi.current` reports `selected=<token>` and `midi_rev`, and the name on its
  own line. `midi_rev` moves once per real change, and a request for the
  selection already in force changes nothing.
- The selection is not saved. Each daemon start begins at `all` with
  `midi_rev=0`.

An unknown id is refused with `invalid_payload no such midi input`. An input
that is listed but will not open gives `internal_error cannot open midi input`,
and the previous selection is restored. A daemon with no MIDI backend answers
`daemon_not_ready no midi input`.

### Bank Select and Program Change

A controller can pick patches. The README summarises this in
[Building and testing](../README.md#building-and-testing). The exact rules, from
`hosts/standalone/program_select.odin`:

- CC 0 holds the bank's MSB and CC 32 its LSB, one pair per MIDI channel. Both
  start at zero. A data byte above 127 is ignored.
- A Program Change from 0 to 127 selects a patch.
- Sending only one half keeps the other's last value. Program Change does not
  reset either.
- Bank number 0 (`MSB * 128 + LSB`) is the daemon's ordinary bank, and the only
  number that exists. Any other bank number, an empty slot, or a patch index past
  the end of a bank selects nothing and leaves the sound unchanged.
- A channel that has never sent CC 0 or CC 32 has chosen no bank. Its Program
  Change stays in the bank the sound is playing from. After loading from an
  archive bank, patch 0 to 127 of that bank. Otherwise, slot 0 to 127 of the
  ordinary bank. An archive that is merely open, with a different sound playing,
  does not take Program Changes.
- A channel that has sent either half has chosen. From then on bank 0 means the
  ordinary bank, even when the sound came from an archive.

These loads use the same atomic replacement as the TUI and the browser. Held
notes keep sounding, and the identity changes as in the table above. If the
control queue has no room, the Program Change waits and is tried again.

### Injecting messages

The `midi` command pushes one message into the same queue the hardware uses:
`midi <status> <data1> <data2>`, status 0 to 255, data bytes
0 to 127. The daemon decodes note on and off, control change, program change and
pitch bend. A note on with velocity 0 is a note off. A full queue is refused with
`daemon_not_ready midi queue full`.

The daemon has no all-notes-off message, and switching MIDI input does not
release held notes. CC 123 is not handled. A note sounds
until its note off arrives, so always send the matching note off, or stop the
daemon.

## Configuration and persistence

Files live under `$XDG_CONFIG_HOME/quesynth/`, or `~/.config/quesynth/` when
that variable is unset. With neither `XDG_CONFIG_HOME` nor `HOME` set, nothing
is saved.

| File | Written by | Contents |
|---|---|---|
| `archive.path` | the daemon | The archive's path on one line. Written when `archive.open` gets an explicit path. Deleted by `archive.close`. Read at daemon start. |
| `bank.json` | the daemon, on `bank.keep` | The ordinary bank. The browser sends `bank.keep` when it saves a bank. Read at daemon start unless `--bank` is given. |
| `config.conf` | the TUI | `bank = <path>`. May also hold a legacy `archive = <path>` line. |
| `theme.conf` | the TUI, once | Colours. Created with the default palette if absent. |

`archive.path` is how every front-end finds the same archive open. If the
remembered archive cannot be opened at start (a disk that is not mounted yet),
the daemon prints `archive could not reopen <path>; it stays remembered` and
keeps the path. `archive.open` with no path tries it again.

`config.conf` is plain `key = value` text. Blank lines and `#` comments are
allowed. The TUI edits only the line it owns. Comments, blank lines, unknown
keys, CRLF endings and the file's mode (including setuid, setgid and sticky
bits) are kept. The last of several duplicate keys is the one it changes. If
`config.conf` is a symlink, for example into a dotfiles checkout, the TUI
follows the link and rewrites the target file, and the link stays a link. The
write goes to a temporary file in the same directory and is renamed over the
target, so a crash leaves the old file whole.

Each time a TUI starts, it loads the `bank` file named in `config.conf` into the
running daemon. That replaces the daemon's browsable bank. An `archive =` line
from before the daemon kept the path itself is offered to a daemon that remembers
no archive, and removed from `config.conf` once the daemon takes it.

## MCP server

`quesynth --mcp` is a local Model Context Protocol server over stdio. It lets an
MCP client, such as an editor or an agent, read a running daemon's parameters
and patch identity and change parameter values. It is a mode of the standalone
executable, not a separate program, and it needs no Node.js, Python or other
runtime.

The server is a client of the daemon's control socket, the way the TUI is. It
does not start audio, it does not start a daemon, and it holds no engine,
registry or parameter state: the daemon stays the only authority for parameter
metadata and values, and every reply carries what the daemon said. It exits
with status 0 when its standard input closes.

### Launching it

`--mcp` takes no operands and no options. An extra operand prints an error and
the usage to stderr and exits 2, as it does for `--stop`.

An MCP client starts the server from the command in its configuration. The
repository's `.mcp.json` registers it:

```json
{
  "mcpServers": {
    "quesynth": {
      "command": "quesynth",
      "args": ["--mcp"]
    }
  }
}
```

The client looks `quesynth` up on its `PATH`. To put the build there, from the
repository root (any directory on your `PATH` will do instead of
`$HOME/.local/bin`):

```sh
odin build hosts/standalone -o:speed -out:build/quesynth
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/build/quesynth" "$HOME/.local/bin/quesynth"
```

Start the daemon separately, with `./build/quesynth --daemon` or once with
`./build/quesynth`. The server finds it at the path in
[Socket path](#socket-path), the one `--stop` uses, so the client has to run
with the same `XDG_RUNTIME_DIR` as the daemon. The server does not read
`QUESYNTH_SOCKET`. Working out that path creates the empty `quesynth` directory
under `XDG_RUNTIME_DIR` (mode 0700) when it is missing, as it does for the
other modes. The server never creates the socket.

Without a daemon the server still starts, and `initialize`, `ping`,
`tools/list` and `resources/list` answer normally. A call that needs the daemon
returns `daemon_unavailable`. Start the daemon and call again; the server
connects afresh for every request, so there is nothing to reconnect.

Only the Linux build has the control socket. On other targets `--mcp` prints
`error: --mcp is not supported on this platform yet` and exits 1.

### Protocol

The server speaks newline-delimited JSON-RPC 2.0: one message per line on
standard input, one reply per line on standard output. It handles one request
at a time, in the order they arrive. It writes nothing else to standard output
and nothing to standard error in normal use. A final line with no newline is
still answered at end of input. A reply carries the request's `id` back: a
string as it came, and a number as an integer, so `1.0` comes back as `1`. The
keys of a reply's objects are written in sorted order.

It accepts the protocol versions `2024-11-05`, `2025-03-26`, `2025-06-18` and
`2025-11-25`. `initialize` needs `protocolVersion`, `capabilities` and
`clientInfo` (with a string `name` and `version`) and is answered with the
client's version when it is one of those, and `2025-11-25` otherwise. The
result advertises the `tools` and `resources` capabilities and the server name
`quesynth`.

The session has three steps. Send `initialize`, then the
`notifications/initialized` notification. Until the notification arrives,
`tools/list`, `tools/call`, `resources/list` and `resources/read` return error
`-32000`. A second `initialize` returns `-32600`. `ping` works at any time. A
notification, which has no `id`, never gets a reply, and an unknown one is
ignored. Every other method, including `resources/templates/list`, returns
`-32601`.

### Tools

There are exactly two tools, listed by `tools/list`:

| Tool | What it does |
|---|---|
| `inspect_synth` | Reads the daemon's parameter values and revision, its parameter registry and the sounding patch's identity. Starts no audio and changes nothing. |
| `apply_parameters` | Changes the sound: sets stored parameter values as one batch, if the daemon's revision is still the one you name. |

Their input schemas are:

```json
{"type":"object","properties":{}}
```

```json
{"type":"object","required":["expected_revision","parameters"],"properties":{"expected_revision":{"type":"integer","minimum":0},"parameters":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"integer"}}}}}}
```

A successful call returns the tool's result object as JSON text in
`content[0].text`. From protocol `2025-06-18` on, the same object is also
returned as `structuredContent`. A failed call has `isError: true` and the
object `{"code": ..., "message": ...}` in the same places. The server declares
no `outputSchema` and no tool annotations.

#### inspect_synth

It takes no arguments, and ignores any it is given. It sends the daemon
`state.snapshot`, `patch.current` and `parameter.list`, in that order, each on
its own connection, and returns:

```json
{"revision":0,"state":{"fields":"...","lines":["..."]},"patch":{"fields":"...","lines":["..."]},"parameters":{"fields":"...","lines":["..."]}}
```

`revision` is the `revision=` of the `state.snapshot` reply, and the values in
`state` are from that same snapshot, so the revision and the values belong
together. Each of `state`, `patch` and `parameters` is the daemon's reply as it
came: `fields` is the text after `ok` on the first line and `lines` are the
record lines that follow, unchanged and in the daemon's order. The `patch` read
is a separate request, made after the snapshot. The records are the ones
described under [Patch identity](#patch-identity) for `patch`; `state` lines are
`id=<id> value=<stored value>`, and `parameters` lines are
`id=<id> group=<group> index=<n> min=<n> max=<n> default=<n> label=<label>`,
one per registry entry.

#### apply_parameters

Both `expected_revision` and `parameters` are required. `expected_revision` is
the `revision` you got from `inspect_synth` or from the last successful apply.
`parameters` is an array of `{"id": <string>, "value": <integer>}` objects, in
the order to apply them. Duplicate ids are kept, in order, and the last one
wins.

Before it contacts the daemon the server checks only the shape of the call:
`arguments` is an object, `expected_revision` is an integer that is not
negative, `parameters` is an array, and each entry is an object with a
non-empty string `id` and an integer `value`. A number such as `30.0` counts as
the integer 30, and an integer has to lie within ±9007199254740991, the largest
that a JSON number holds exactly. An `id` must be one token for the daemon, so it may contain no
whitespace and no control character: nothing below U+0020, nothing from U+007F
to U+009F, and no Unicode space. Any other key is ignored. A call that fails
the check returns `invalid_arguments` and sends nothing.

Whether an id exists, and whether a value is in range, are the daemon's to say.
The server sends one request, `parameter.set_many expected_revision=<n> <id>
<value> ...`, which the daemon checks as a whole before it queues anything
(see [Control protocol](#control-protocol)). The batch is all or nothing: if any
id or value is refused, nothing is applied. The daemon refuses more than 128
pairs as `transaction_failed`, and an empty `parameters` array as
`invalid_payload`. A request line over the 64 KiB frame limit is refused by the
server itself as `daemon_error`, and is not sent.

The audio thread decides whether the batch applies. It compares
`expected_revision` with its own revision when it reaches the batch. If they are
equal it applies every value at once and the revision moves up by one; if not
it applies nothing, so of two batches that carry the same revision only the
first is applied. Any change moves the revision, whichever client made it: a
knob in the TUI, a patch load, a Program Change from a controller. The daemon
replies after the audio thread has answered, and the new state is already
published by then, so an `inspect_synth` that follows sees it. A success returns

```json
{"count":2,"revision":1}
```

where `count` is the number of pairs and `revision` is the revision after the
change, the one to pass as `expected_revision` next time. A stale
`expected_revision` returns `revision_conflict`, with the revision the daemon
holds now in the message as `current_revision=<n>`, and changes nothing. Call
`inspect_synth`, look again, then send the batch with the new revision.

#### When the outcome is not known

The server gives each request to the daemon on a connection of its own, with a
deadline of 500 ms. It never sends a request twice. If the answer to an
`apply_parameters` does not arrive, the batch may or may not have been applied.
When a request was already sent, the message of the failure ends with
`; the request was sent and the change may have been applied`. The cases are:

- `daemon_timeout`: the deadline passed after the server had connected.
- `daemon_error`: the daemon closed the connection before it replied, or its
  reply could not be read.
- `daemon_not_ready` with `commit outcome unknown; inspect state before
  retrying`: the daemon queued the batch and the audio thread did not answer
  within 250 ms. The batch stays queued and may still be applied.

In each case call `inspect_synth` and compare before you send anything again.

#### Errors

A tool failure is a normal result with `isError: true`. Its `code` is one of:

- `invalid_arguments`: the call failed the check above. Nothing was sent.
- `daemon_unavailable`: the server could not open the socket or connect to it.
  Nothing was sent.
- `daemon_timeout`: the daemon did not answer within the 500 ms deadline.
- `daemon_error`: a failure of the server's own, with no daemon error behind it:
  a request over the 64 KiB frame limit, which is not sent; a daemon that
  hung up; a reply or a frame that could not be read.
- A daemon error token, with the daemon's message: `revision_conflict`,
  `out_of_range`, `unknown_parameter`, `invalid_payload`, `daemon_not_ready`,
  `transaction_failed` and the others in
  [Control protocol](#control-protocol).

Failures of the protocol itself are JSON-RPC errors with a `code` and a
`message`:

| Code | Meaning |
|---|---|
| `-32700` | The line is not valid JSON. `id` is `null`. Text after the value, a trailing comma, a malformed number or string and nesting more than 100 levels deep are refused the same way, and so is an empty line. |
| `-32600` | Not a JSON-RPC 2.0 request: not an object, `jsonrpc` is not `"2.0"`, `method` is not a string, or `id` is neither a string nor an integer-valued number. `id` is `null`. A second `initialize` also returns `-32600`, with its own `id`. |
| `-32601` | Method not found. |
| `-32602` | Bad parameters: `initialize` without its fields, `params` that is not an object, `tools/call` without a tool name or with a tool that is not one of the two, `resources/read` without a string `uri`. |
| `-32000` | A call before the session is initialized, or a `resources/read` the daemon could not answer. The message is `<code>: <detail>` and `error.data` is `{"code": "<code>"}`. |
| `-32002` | `resources/read` of a URI that is not one of the two. |

### Resources

There are exactly two, both `application/json`, listed by `resources/list`:

| URI | Name | Contents |
|---|---|---|
| `quesynth://parameters` | `parameters` | The parameter registry: the daemon's `parameter.list` reply as `{"fields": ..., "lines": [...]}`. |
| `quesynth://patch` | `patch` | `revision`, `state` and `patch` as `inspect_synth` returns them, read from `state.snapshot` and `patch.current`. |

`resources/read` takes `{"uri": ...}` and returns
`{"contents":[{"uri":...,"mimeType":"application/json","text":...}]}`, with the
JSON as text. If the daemon cannot answer, the call fails with error `-32000`,
the message `<code>: <detail>`, for example
`daemon_unavailable: no daemon listening on the local socket`, and the error's
`data` is `{"code": "<code>"}`.

### Example

Both sessions below were captured from `quesynth --mcp`. Each request and each
reply is one line of JSON, shown as it was sent or received.

#### Without a daemon

The server initializes without one. A call that needs the daemon returns
`daemon_unavailable`.

Initialize, then send the `notifications/initialized` notification, which has no reply:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}
```

```json
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"resources":{},"tools":{}},"protocolVersion":"2025-11-25","serverInfo":{"name":"quesynth","version":"1.0.0"}}}
```

```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

Ask to inspect the synth:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_synth","arguments":{}}}
```

```json
{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"daemon_unavailable\",\"message\":\"no daemon listening on the local socket\"}","type":"text"}],"isError":true,"structuredContent":{"code":"daemon_unavailable","message":"no daemon listening on the local socket"}}}
```

#### With a daemon

A daemon that had just started. The registry and the snapshot are cut to their
first two entries here; the daemon's own reply lists all 92 parameters
(`count=92`).

Initialize, then send the `notifications/initialized` notification:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}
```

```json
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"resources":{},"tools":{}},"protocolVersion":"2025-11-25","serverInfo":{"name":"quesynth","version":"1.0.0"}}}
```

```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

Inspect the synth:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_synth","arguments":{}}}
```

```json
{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"parameters\":{\"fields\":\"count=92\",\"lines\":[\"id=osc1.shape group=osc1 index=0 min=0 max=3 default=2 label=Shape\",\"id=osc1.fm group=osc1 index=45 min=0 max=127 default=0 label=FM\"]},\"patch\":{\"fields\":\"slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\",\"lines\":[\"bank=\",\"name=\"]},\"revision\":0,\"state\":{\"fields\":\"revision=0 sample_rate=48000 buffer=512 count=92\",\"lines\":[\"id=osc1.shape value=2\",\"id=osc1.fm value=0\"]}}","type":"text"}],"structuredContent":{"parameters":{"fields":"count=92","lines":["id=osc1.shape group=osc1 index=0 min=0 max=3 default=2 label=Shape","id=osc1.fm group=osc1 index=45 min=0 max=127 default=0 label=FM"]},"patch":{"fields":"slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1","lines":["bank=","name="]},"revision":0,"state":{"fields":"revision=0 sample_rate=48000 buffer=512 count=92","lines":["id=osc1.shape value=2","id=osc1.fm value=0"]}}}}
```

Apply two values, if the revision is still 0:

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply_parameters","arguments":{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":90},{"id":"filter.resonance","value":20}]}}}
```

```json
{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\"count\":2,\"revision\":1}","type":"text"}],"structuredContent":{"count":2,"revision":1}}}
```

Apply again with the same revision. It is stale now, so nothing changes:

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"apply_parameters","arguments":{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":95}]}}}
```

```json
{"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"revision_conflict\",\"message\":\"current_revision=1\"}","type":"text"}],"isError":true,"structuredContent":{"code":"revision_conflict","message":"current_revision=1"}}}
```

Read the patch resource. The revision is now 1:

```json
{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"quesynth://patch"}}
```

```json
{"id":5,"jsonrpc":"2.0","result":{"contents":[{"mimeType":"application/json","text":"{\"patch\":{\"fields\":\"slot=-1 bank_rev=0 revision=1 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\",\"lines\":[\"bank=\",\"name=\"]},\"revision\":1,\"state\":{\"fields\":\"revision=1 sample_rate=48000 buffer=512 count=92\",\"lines\":[\"id=osc1.shape value=2\",\"id=osc1.fm value=0\"]}}","uri":"quesynth://patch"}]}}
```

### Safety notes for MCP clients

- The server runs no shell and builds no command line. Parameter ids are
  checked to be single tokens, and a request is one line of the control
  protocol.
- It offers two tools and two resources. It cannot load a patch, bank or
  archive, send MIDI, change the master volume or stop the daemon, and it has no
  file, command or network tool.
- `apply_parameters` changes what you hear at once. Keep the level down while
  you test.
- Anyone who can start it can change the daemon's parameters as your user.
  Register it only with clients you trust.

## Troubleshooting

**`error: could not start or reach a daemon`.** The spawned daemon failed or
took more than five seconds. Run it in the foreground and read why:

```sh
./build/quesynth --daemon
```

**`error: cannot reach the daemon at <path>`, or MCP `daemon_unavailable`.**
Nothing is listening. Check the path your session resolves to:

```sh
ls -l "${XDG_RUNTIME_DIR:-/tmp}"/quesynth/quesynth.sock "/tmp/quesynth-$(id -u).sock"
./build/quesynth --stop
```

A client with a different `XDG_RUNTIME_DIR` than the daemon looks at a different
path. A daemon started under `sudo` or in a container is not found by your
session either.

**MCP `revision_conflict`.** The sound changed, from any client, after the
`revision` you passed. The message gives the revision now as
`current_revision=<n>`, and nothing was applied. Call `inspect_synth` again and
send the batch with the new revision.

**Stale socket.** A leftover socket from a crash is removed at the next start.
If the start fails with `control endpoint is owned or unavailable`, the path is
held by something that is not a stale socket of yours. Look at `ls -l` on the
path and on its `.lock` file, and check for a running daemon with
`pgrep -a quesynth`. Never delete the `.lock` file while a daemon is running.

**`error: cannot open an audio output device`.** The binary could not load
`libasound.so.2` or open the `default` PCM. Check `aplay -l` and that your sound
server (PipeWire, PulseAudio) is running and exposes an ALSA default device.

**`error: could not start node; is Node.js installed?`** The `--browser`
adapter needs Node.js 20 or later on `PATH`. Check `node -v`.

**`error: 127.0.0.1:8177 is already in use`.** Another `--browser` adapter is
running. Close it, or start the adapter by hand with `--port`
(see [Browser](#browser)).

**Browser: the page is blank or the adapter exits at start.** It needs
`ui/params.js` under its root. Run from the repository root or set
`QUESYNTH_ROOT`.

**Nothing audible.** In order: `quesynth --daemon` shows the audio line without
an error; the daemon's `daemon.info` reply shows a non-zero `volume` and
`voices` rising when you play (the TUI status line shows the voice count); the
MIDI input is the one you are playing (press `M`); the parameter values are not
at a silent extreme. The master volume can be set to zero by a client, and the
TUI has no control for it. Restarting the daemon resets it to full level.

**A note will not stop.** See [Injecting messages](#injecting-messages). Send the
matching note off, or restart the daemon.

**MIDI device not listed.** `midi.list` enumerates ALSA raw MIDI ports, so the
device must be visible to `amidi -l`. Press R on the TUI's MIDI screen to scan
again. A device used by another program may refuse to open.

**Archive will not open.** `cannot open archive` means the path is unreadable
or not a ZIP. The path is read by the daemon, relative to the daemon's working
directory, so use an absolute path. The archive must be a ZIP of ZIP banks. If
the remembered path fails at start, the daemon keeps it and prints
`archive could not reopen <path>`. Mount the disk and send `archive.open` with
no path.

**`unknown command` after upgrading.** A running daemon from an older build
does not know newer commands. Run `./build/quesynth --stop` and start again.

## Safety

- Control is local. The daemon binds no network port, only a Unix socket with
  mode 0600 in a directory owned by you (0700 under `XDG_RUNTIME_DIR`). Anyone
  who can run code as your user can control it.
- The browser adapter binds `127.0.0.1`, rejects other `Host` and `Origin`
  values, and withholds the page's own storage so it cannot overwrite the
  daemon's bank. Do not forward its port to other machines. It has no login.
- The MCP server is a stdio process with no network listener. It offers two
  tools, `inspect_synth` and `apply_parameters`, and two read-only resources,
  and nothing else: no shell, file, command or network access. Anyone who can
  start it can change the daemon's parameter values, so only add it to clients
  you trust.
- `apply_parameters`, patch and archive loads and injected MIDI messages change
  the sound immediately. Turn your monitors down before testing, since a
  note-on with a high velocity or an extreme parameter can be loud. The
  daemon's master volume (`volume` over the socket) is not reachable from MCP.
- Notes can hang. There is no all-notes-off. Send a note off, or run
  `./build/quesynth --stop`.
- The daemon reads the files you name (patches, banks, archives) with your
  permissions, and writes only `archive.path`, `bank.json` and, through the TUI,
  `config.conf`, `theme.conf`, and the bank file you choose to write.
- Quesynth is experimental software. Do not rely on it unattended in a session
  you cannot repeat.
