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
only for `--browser` and for the MCP server. Run every command from the
repository root.

```sh
odin build hosts/standalone -o:speed -out:build/quesynth
./build/quesynth --help
```

The binary loads `libasound.so.2` at run time for audio and MIDI, so no ALSA
development package is needed to build. PipeWire and PulseAudio serve the same
`default` ALSA device. On Windows the standalone uses WASAPI and WinMM, and
`odin build hosts/standalone -o:speed -out:build/quesynth.exe` builds it.

Only the Linux build has a control socket. On Windows `--daemon` plays
and listens to MIDI, but the TUI, `--browser`, `--stop` and the MCP server
report that they are not supported there yet. On other targets the daemon
reports that no audio backend exists.

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
./build/quesynth --stop
./build/quesynth --selftest patch.sy1 out.wav
```

`./build/quesynth --help` prints them to stdout with a short description of
each and exits 0. `--bank` may appear once. A second positional argument, a
second `--bank` or an unknown option prints an error and the usage to stderr
and exits 2.

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

The daemon, the TUI and `--stop` use one path, chosen like this:

1. If `XDG_RUNTIME_DIR` is set and non-empty, the socket is
   `$XDG_RUNTIME_DIR/quesynth/quesynth.sock`. The `quesynth` directory is
   created with mode 0700.
2. Otherwise it is `/tmp/quesynth-<uid>.sock`.

Beside the socket the daemon keeps a lock file named `<socket>.lock`. The
socket itself has mode 0600. The Odin binary does not read `QUESYNTH_SOCKET`.
That variable is read by the browser adapter and the MCP server, as the
default for their `--socket` option, so that they can reach a daemon whose
socket you located yourself. To move the daemon's own socket, change
`XDG_RUNTIME_DIR` for it.

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

Clients talk to the daemon over the Unix socket. The framing is in
`src/control/codec.odin` and the messages in `src/control/message.odin`.

- Each message is a 4-byte little-endian length followed by that many payload
  bytes. The payload limit is 64 KiB. A longer frame closes the connection.
- A request is one line: `1 <id> <command> [operands]`. `1` is the protocol
  version.
- A response starts with `1 <id> ok [key=value ...]` or
  `1 <id> err <code> [message]`, optionally followed by record lines.
- Error codes are `unsupported_version`, `unknown_command`, `invalid_payload`,
  `unknown_parameter`, `out_of_range`, `daemon_not_ready`,
  `transaction_failed` and `internal_error`.

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
typed there; open it with a front-end that can send it (the browser or an MCP
tool).

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
bank. Loading a bank file later (`L`, or the `bank_load_file` tool) replaces the
browsable bank only. It does not change the sound.

An archive is a ZIP file of bank ZIPs, each holding `.sy1` patches. The daemon
indexes the outer ZIP and reads one inner bank and one patch at a time, so a
corpus of tens of thousands of patches is not unpacked into memory. Banks and
patches are listed in the order they are stored in the ZIP, and a patch is
listed by the name inside its file, or by the file name when it has none.

Opening, browsing and loading are separate:

- Opening an archive (`Z` in the TUI, `archive_open` in MCP) indexes it and
  remembers its path. It loads no sound.
- Opening a bank (`archive_bank`, or Enter on a bank row) is browsing. It is
  shared, so a peer showing the archive follows. It does not change the sound.
- Loading a patch (`archive_load`, or Enter on a patch row) replaces the sound.
  Held notes keep sounding.

`archive_load` accepts an optional bank. Send it when your list came from a
particular bank, since a peer may have opened another one since you listed it.

Two counters tell a polling client when to read again. `bank_rev` moves when
the ordinary bank's contents or label change. `archive_rev` moves when the
archive or its open bank changes, including a change from another client. Both
appear in `patch.current`. Asking for the bank that is already open does not
move `archive_rev`.

An archive is closed with `archive.close` (settings screen with a blank path, or
the `archive_close` tool). That also deletes the remembered path.

## Patch identity

The daemon records which patch is sounding, so every front-end names it the
same way. `patch.current` (the `patch_current` tool) returns:

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

- `midi.list` (the `midi_list` tool) enumerates the inputs now, without
  caching, so a controller plugged in since the last call is there. Each record
  has an `id` and a `name`. On Linux an id is `hw:<card>,<device>`, on
  Windows `winmm:<index>`. Two identical controllers can share a name, so
  choose by id.
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

The `midi` command (the `midi_send` tool) pushes one message into the same queue
the hardware uses: `midi <status> <data1> <data2>`, status 0 to 255, data bytes
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
keeps the path. `archive_open` with no path tries it again.

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

`hosts/standalone/mcp/serve.js` is a local Model Context Protocol server over
stdio. It lets an MCP client (an editor or agent) inspect and control a running
daemon. It does not start a daemon and it does not make sound itself. Each tool
sends one daemon command over the control socket, so the server contains no
engine logic. It needs Node.js 20 or later and uses only built-in modules.

The project configures it in `.mcp.json` at the repository root:

```json
{
  "mcpServers": {
    "quesynth": {
      "command": "node",
      "args": ["hosts/standalone/mcp/serve.js"]
    }
  }
}
```

Start a daemon first (`./build/quesynth --daemon`, or `./build/quesynth`
once). The client launches the server from the repository root, since `args` is
a relative path.

Options:

```sh
node hosts/standalone/mcp/serve.js --socket /run/user/1000/quesynth/quesynth.sock
node hosts/standalone/mcp/serve.js --timeout-ms 5000
node hosts/standalone/mcp/serve.js --help
```

- `--socket PATH` is the daemon's control socket. The default is
  `QUESYNTH_SOCKET` if set, then `$XDG_RUNTIME_DIR/quesynth/quesynth.sock`, then
  `/tmp/quesynth-<uid>.sock`, which is the path the daemon uses.
- `--timeout-ms MS` is how long to wait for a daemon reply, an integer from 1 to
  2147483647. The default is 3000.
- A bad option prints `quesynth MCP: <reason>` on stderr and exits 2.

The server starts and lists its tools even when no daemon is running. The
daemon is contacted on the first tool call and reconnected after a failure.

### Protocol

The server speaks newline-delimited JSON-RPC 2.0 on stdin and stdout and writes
nothing else to stdout. It accepts the MCP protocol versions 2024-11-05,
2025-03-26, 2025-06-18 and 2025-11-25, and answers `initialize` with the
client's version if it knows it, otherwise with the newest. Send `initialize`,
then the `notifications/initialized` notification, before `tools/list` or
`tools/call`. Before that they return error `-32000`. `ping` works at any time.

Every successful tool result carries the daemon's reply as JSON text in
`content[0].text`, in the shape `{"fields": "...", "lines": ["..."]}`. `fields`
is the header after `ok` and `lines` are the record lines, unchanged. For
protocol 2025-06-18 and later the same object is also returned as
`structuredContent`, and each tool declares an `outputSchema`. Tool
`annotations` (`readOnlyHint`, `destructiveHint`, `openWorldHint`) are
declared for the versions that define them.

### Tools

| Tool | Daemon verb | Purpose |
|---|---|---|
| `daemon_status` | `daemon.status` | Read daemon state, protocol and parameter revision. |
| `daemon_info` | `daemon.info` | Read state, audio metrics, queue drops and master volume. |
| `parameter_list` | `parameter.list` | List parameter IDs with their stored ranges, defaults and labels. |
| `parameter_get` | `parameter.get` | Read one parameter's stored value and revision. |
| `parameter_set` | `parameter.set` | Set one parameter to a stored integer. Changes the sound. |
| `patch_current` | `patch.current` | Read the sounding patch's identity and the bank and archive generations. |
| `patch_load` | `patch.load` | Load a filled ordinary-bank slot (0 to 127). |
| `patch_load_file` | `patch.load_file` | Read a local `.sy1` or JSON patch and load its sound. |
| `bank_list` | `bank.list` | List all 128 ordinary-bank slots, empty ones included. |
| `bank_load_file` | `bank.load_file` | Replace the browsable ordinary bank from a local JSON bank. |
| `archive_current` | `archive.current` | Read the archive path, open bank and generation. |
| `archive_open` | `archive.open` | Open a ZIP archive and remember its path, or reopen the remembered one. |
| `archive_banks` | `archive.banks` | Page through the archive's bank names. |
| `archive_bank` | `archive.bank` | Open one archive bank for browsing, for all clients. |
| `archive_patches` | `archive.patches` | Page through the open bank's patch names. |
| `archive_load` | `archive.load` | Load an archive patch, optionally from a named bank. |
| `archive_close` | `archive.close` | Close the archive and forget its saved path. |
| `midi_list` | `midi.list` | List native MIDI inputs and the current selection. |
| `midi_current` | `midi.current` | Read the selected input and `midi_rev`. |
| `midi_select` | `midi.select` | Select `all`, `none` or an input id for every client. |
| `midi_send` | `midi` | Inject one MIDI message: status, data1, data2. |

Call `parameter_list` for the parameter ids and their stored ranges.
`parameter_set` takes the stored integer, not Hz, dB or another display unit.
For `midi_send` give `data2` even for a Program Change, as `0`. The paging
tools take `offset` and `count`, default 0 and 64, and the daemon caps `count`
at 256.

These daemon commands are deliberately not exposed: `daemon.shutdown`,
`parameter.set_many`, `patch.apply`, `patch.save`, `patch.clear`,
`bank.write`, `bank.keep`, `archive.adopt`, `state.snapshot` and `volume`. The
tool list is a fixed allowlist, not a way to send arbitrary commands.

### Validation and errors

The server checks arguments against each tool's schema before it contacts the
daemon. Unknown arguments are rejected. A missing required argument, a value of
the wrong type, a non-integer or a number out of range never reaches the
daemon. Neither does a string that holds a lone surrogate, a C0 or C1 control
character (U+0000 to U+001F, U+0080 to U+009F), DEL (U+007F), U+2028 or U+2029,
or, for ids, any whitespace. Ordinary spaces and non-ASCII text are fine in a
path, and the empty string is a valid path.

A tool failure is a normal result with `isError: true` and a JSON text body of
exactly `{"code": "...", "message": "..."}`:

- `invalid_arguments` means the server refused the arguments. Nothing was sent.
- `daemon_unavailable` means the socket is missing, refused, closed, sent a
  malformed or oversized frame, or did not answer within the timeout (3000 ms by
  default). A timeout closes the connection, and the next call opens a new one.
  A mutating call is never replayed after a failure.
- Any other `code` is the daemon's own error token, for example `out_of_range`,
  `unknown_parameter`, `invalid_payload` or `daemon_not_ready`, with its message.

A request the server cannot handle at all, such as an unknown tool name, an
unknown method or a malformed message, is a JSON-RPC error instead: `-32700`
invalid JSON, `-32600` invalid request, `-32601` method not found, `-32602`
invalid params or unknown tool, `-32000` called before initialisation.

### Example

A request, after the `initialize` handshake:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "parameter_get",
    "arguments": { "id": "filter.cutoff" }
  }
}
```

With a daemon running, the response looks like this (the values depend on the
patch):

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      { "type": "text", "text": "{\"fields\":\"value=64 revision=3\",\"lines\":[]}" }
    ],
    "structuredContent": { "fields": "value=64 revision=3", "lines": [] }
  }
}
```

With no daemon listening, the same request returns an error result and the
session stays usable:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "isError": true,
    "content": [
      { "type": "text", "text": "{\"code\":\"daemon_unavailable\",\"message\":\"connect ENOENT /run/user/1000/quesynth/quesynth.sock\"}" }
    ]
  }
}
```

### Safety notes for MCP clients

- The server never runs a shell and never builds a command line. Arguments go
  into a single control-socket line, and a value that could start a second
  request is refused first.
- Treat `parameter_set`, the `patch_*` and `archive_load` tools, and
  `midi_send` as able to change what you hear, and always pair a note on with a
  note off.
- `patch_load_file`, `bank_load_file` and `archive_open` make the daemon read
  the path you give. The daemon trims leading and trailing whitespace from it,
  resolves a relative path against its own working directory, does no `~` or
  shell expansion, and runs with your permissions. A path of only spaces for
  `archive_open` reopens the remembered archive.
  The tools only read files. Writing a bank or a patch is not exposed.
- `archive_open` with a path and `archive_close` change what the daemon
  remembers across restarts.
- `midi_select` changes the input for every client, and `archive_bank` changes
  what every client is browsing.

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

**Stale socket.** A leftover socket from a crash is removed at the next start.
If the start fails with `control endpoint is owned or unavailable`, the path is
held by something that is not a stale socket of yours. Look at `ls -l` on the
path and on its `.lock` file, and check for a running daemon with
`pgrep -a quesynth`. Never delete the `.lock` file while a daemon is running.

**`error: cannot open an audio output device`.** The binary could not load
`libasound.so.2` or open the `default` PCM. Check `aplay -l` and that your sound
server (PipeWire, PulseAudio) is running and exposes an ALSA default device.

**`error: could not start node; is Node.js installed?`** `--browser` and the MCP
server need Node.js 20 or later on `PATH`. Check `node -v`.

**`error: 127.0.0.1:8177 is already in use`.** Another `--browser` adapter is
running. Close it, or start the adapter by hand with `--port`
(see [Browser](#browser)).

**Browser: the page is blank or the adapter exits at start.** It needs
`ui/params.js` under its root. Run from the repository root or set
`QUESYNTH_ROOT`.

**Nothing audible.** In order: `quesynth --daemon` shows the audio line without
an error; `daemon_info` or the TUI status line shows a non-zero `volume` and
`voices` rising when you play; the MIDI input is the one you are playing (press
`M`, or call `midi_list`); the parameter values are not at a silent extreme.
The master volume can be set to zero by a client, and the TUI has no control for
it. Restarting the daemon resets it to full level.

**A note will not stop.** See [Injecting messages](#injecting-messages). Send the
matching note off, or restart the daemon.

**MIDI device not listed.** `midi_list` enumerates ALSA raw MIDI ports, so the
device must be visible to `amidi -l`. Press R on the TUI's MIDI screen to scan
again. A device used by another program may refuse to open.

**Archive will not open.** `cannot open archive` means the path is unreadable
or not a ZIP. The path is read by the daemon, relative to the daemon's working
directory, so use an absolute path. The archive must be a ZIP of ZIP banks. If
the remembered path fails at start, the daemon keeps it and prints
`archive could not reopen <path>`. Mount the disk and call `archive_open` with
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
- The MCP server is a stdio process with no network listener. Anything that
  can start it can drive your daemon, so only add it to clients you trust.
- `parameter_set`, patch and archive loads and `midi_send` change the sound
  immediately. Turn your monitors down before testing, since a note-on with a
  high velocity or an extreme parameter can be loud. The daemon's master
  volume (`volume` over the socket) is not exposed to MCP.
- Notes can hang. There is no all-notes-off. Send a note off, or run
  `./build/quesynth --stop`.
- The daemon reads the files you name (patches, banks, archives) with your
  permissions, and writes only `archive.path`, `bank.json` and, through the TUI,
  `config.conf`, `theme.conf`, and the bank file you choose to write.
- Quesynth is experimental software. Do not rely on it unattended in a session
  you cannot repeat.
