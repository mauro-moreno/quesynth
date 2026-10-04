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

`--bank` names the bank file a daemon starts from and keeps its bank in: every
save writes it, and the first save creates it if it does not exist yet. It is
used instead of `bank.json`, which that daemon does not write (see
[What survives a restart](#what-survives-a-restart)).

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

Values in `parameter.set`, `parameter.set_many` and `patch.apply` are decimal
integers: digits, with an optional single leading `-` (`-5`), and zero-padding
is allowed. A `+` sign, a `-` alone, base prefixes such as `0x`, underscores,
exponents, fractions and values outside the signed 64-bit range are refused as
`invalid_payload value is not an integer`, before anything is queued. An integer
outside a parameter's stored range is still `out_of_range`.

The request may instead start with `expected_revision=<n>`, as its first token
and with `n` a non-negative integer in decimal digits:

```text
parameter.set_many [expected_revision=<n>] <id> <value> ...
```

Then the audio thread applies the batch only if the revision it holds equals
`n` when it reaches the batch. The daemon queues the batch and answers that
client once the audio thread has applied or refused it and published the new
state, so a `state.snapshot` sent after the reply sees it. Until then the daemon
reads nothing more from that client, so requests it sent behind the guarded one
are answered after it, in order. Other clients are served as usual while it
waits. On success the reply is
`ok count=<n> revision=<r>` with `r` the revision after the change. If the
revision differs, nothing is applied and the reply is
`err revision_conflict current_revision=<r>`, with `r` the revision now. If the
audio thread has not answered within 250 ms the reply is
`err daemon_not_ready commit outcome unknown; inspect state before retrying`:
the batch stays queued and may still be applied, and an answer that comes after
that is discarded. If the daemon is stopped while the batch waits, that client
gets the same reply at once, or the audio thread's answer if it has already
come, before the connection closes, and the requests it sent behind the batch
are not answered. A first token that starts with
`expected_revision=` and is not followed by a non-negative integer is refused
with `invalid_payload expected_revision needs a nonnegative integer`. Only the
digits 0 to 9 make one: a sign, a `0x` or `0b` prefix, an underscore, nothing at
all and a number above 9223372036854775807 are refused the same way, and
leading zeros are allowed. `patch.apply` takes no `expected_revision`.

`patch.save <slot> [name]` stores every change the daemon had queued when the
save arrived, from any client. A `parameter.set` is answered before the audio
thread applies it, so a client that sets a value and saves straight away still
saves the new value. While such changes are not applied yet, the daemon
answers the save once the audio thread has applied them, and reads nothing
more from that client until then, as for a guarded batch. Other clients are
served as usual. The save queues nothing itself, so it does not move the
revision and a full queue does not refuse it. If the changes are not applied
within 250 ms, or the daemon is stopped first, the reply is
`err daemon_not_ready earlier edits not applied; nothing saved`. No slot, name
or `bank_rev` changed, and the save can be sent again.

The daemon also keeps what it saved. Once the slot is stored it writes the
bank to the file it keeps its bank in, the file `bank.keep` writes, and
answers only after that, so the patch is there after a restart whichever
client saved it, with no `bank.keep` needed. That file is the one given with
`--bank` when the daemon was started with one, and `bank.json` in the config
directory otherwise. If the file cannot be written the reply is
`err internal_error cannot keep bank`, and the slot, the playing patch and
`bank_rev` are as they were before the save. With no `--bank` and no config
directory (neither `XDG_CONFIG_HOME` nor `HOME` set) nothing is written and the
save stays in memory, as it always did. The reply of a save that succeeds is
the same either way.

The daemon serves at most 16 connections at once. It drops a client whose
unread output passes 256 KiB. You rarely need to speak the protocol by hand,
because the TUI, the browser adapter and the [MCP server](#mcp-server) do.

### What survives a restart

Kept on disk: the archive path, and the ordinary bank. Every successful
`patch.save` writes the bank to the file the daemon keeps its bank in:
the file given with `--bank` if the daemon was started with one, otherwise
`bank.json` in the config directory (see
[Configuration and persistence](#configuration-and-persistence)). The next
start with the same `--bank`, or with none, loads that file, so a saved patch
is there after a restart whichever front-end saved it. Loading another bank
file with `bank.load_file` (`L` in the TUI) is for browsing it and does not
replace the kept bank: a save after it puts that one slot into the kept file
and leaves its other slots as they were. `bank.keep` makes the loaded bank the
kept one, and saves after that write it whole. A bank loaded over the factory
bank before anything was loaded or saved, as the TUI does with its User bank,
loses nothing kept, so it is the kept bank from then on.

A daemon started with `--bank` never writes `bank.json`, so a start without
`--bank` does not have the patches saved under it. If the `--bank` file does
not exist, the first save creates it. A `--bank` file that the daemon could not
load at start, such as a text file that is not a bank or a directory, is never
replaced unless it is empty or the daemon has written it since: a save then
fails with `cannot keep bank`, the file stays as it was, and the daemon said so
on stderr when it started. The TUI's `User bank` file does not replace the bank
a start loaded: a TUI loads it only into a daemon still on the factory bank
(see [Configuration and persistence](#configuration-and-persistence)).

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

Q or a closed terminal quits the TUI and leaves the daemon running. Ctrl-C ends
the TUI too and the daemon keeps running, but it does not restore the terminal;
see [Key input limits](#key-input-limits).
If the daemon goes away the footer shows
`DISCONNECTED - cached values are stale; edits disabled`, and Enter
reconnects.

A footer line wider than the frame ends in `…` in its last cell, and so does the
`Error: ...` line that reports a refused change. A list row or the title that is
too wide is cut at the edge, with no mark.

The theme is read from `theme.conf` in the config directory, and written there
with the browser panel's palette the first time the TUI runs. Each line in the
file overrides one colour of the built-in palette. A `theme.conf` written by an
earlier version holds the old Catppuccin Mocha colours and keeps them. Delete it,
or the lines you do not want, to get the panel's palette. `NO_COLOR` set to
anything non-empty turns colour off, and so does `enabled = false`.

### Synth screen

The tabs are the browser panel's sections, in the panel's order: Master,
Oscillators, Filter and so on. Within a tab the parameters sit under the panel's
group headings, such as `OSCILLATOR 1` or `UNISON`, each with its value and a
bar. A row carries the label the panel prints under its control: `Waveform`,
`Gain`, `Key Tracking`, `Dry / Wet`, `Enable`. `parameter.list` still reports
the registry's label, so the TUI shows `Waveform` for `osc1.shape`, which that
list calls `Shape`. A parameter the daemon does not expose, such as polyphony,
is left out, and so is a heading or a tab that would have nothing under it:
Master has no Controller 1 or Controller 2 heading. The list scrolls to keep the
selected parameter in view, and the tab strip scrolls to keep the current tab in
view, with `<` and `>` where more tabs are off the edge.

| Key | Action |
|---|---|
| Tab | Next section |
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
| Enter | At the banks, open the bank. At the patches, load the patch. On an empty `Init` slot, start a new sound |
| / | Search the names in the list |
| Esc | Clear the search. Without one, go back from patches to banks, and from banks hide the navigator |
| B | Hide the navigator |
| S | Save the sound into the selected ordinary-bank slot |
| O, L | Load a patch file or a bank file |
| Z | Open a ZIP archive |
| Q | Quit |

S asks for a name, then offers to write the whole bank to a file (blank skips).
It works only in the ordinary bank, since an archive is read-only. Prompts take
printable ASCII. Escape cancels, so a path with other characters cannot be
typed there; open it with the browser.

A path typed at a prompt (O, L, the file S offers, Z, and both settings) is
read from the directory the TUI was started in, and the daemon is sent it as an
absolute path. The daemon may have started elsewhere, so a relative path sent
as typed would name a file in its directory, not yours. A path that starts with
`/` is sent as typed. A relative one is only put after the TUI's directory:
`..`, `.`, symlinks and spaces stay as you typed them, and the file need not
exist yet. The prompt is not a shell, so `~` is not expanded. If the TUI cannot
read its own directory (it was deleted), it sends nothing and the footer says
`cannot read the working directory to resolve a relative path`.

Enter on an empty slot starts a new sound: every parameter at its default, the
Init patch an empty slot stands for. The TUI sends `patch.load <slot> init`. The
daemon applies the defaults of all 99 parameters as one replacement and names
the sound as that slot, with the bank label and the name `Init`, the way a
loaded patch is named. It writes nothing to the bank: `bank_rev` and the bank
file stay as they were, and the slot stays empty until S saves into it.

Only `patch.load` takes `init`, and only as that exact lowercase word. Any other
second operand is ignored, so an empty slot with `INIT` is refused. On a filled
slot `init` changes nothing: the slot's own patch loads. The MCP tool
`patch_load` has only a `slot` argument, so an empty slot comes back as
`unknown_parameter slot is empty`. A Program Change never loads an empty slot.
The browser page never sends `init`: a patch it loads that no filled slot holds
exactly, such as the Init values of an empty slot, reaches the daemon as
`patch.apply` and then `patch.clear`, so the daemon records no name for it.

`/` searches the list on screen: bank names at the banks, slot or patch names
in a bank. Empty slots are named `Init`, so `/init` finds the free slots. As you
type, the list keeps only the rows whose name contains the text, ignoring case
and leading or trailing spaces. The daemon sends the ordinary bank's label and
slot names with each space as `_`, and the navigator draws them that way. In
those rows a space and `_` match each other, so `solo lead` and `solo_lead` both
find `Solo_Lead`. An archive's bank and patch names are compared as they come,
so there a space matches only a space. Neither the text you typed nor the names
on screen are rewritten. Each row keeps its own number, and the footer line
under the keys shows what you typed. While typing:

| Key | Action |
|---|---|
| Any text | Add to the search. Letters are text here, not commands |
| Backspace | Remove the last character |
| Ctrl-U | Clear the search and keep typing |
| Up, Down | Move among the rows shown |
| Enter | Stop typing and keep the search |
| Esc | Stop typing and clear the search |
| Ctrl-C | End the TUI, as anywhere else; see [Key input limits](#key-input-limits) |

With a search kept, the keys work as usual on the rows shown: Enter opens or
loads the selected row, and S saves into it. `/` edits the search again, and
Esc clears it with the cursor left on the same row. When nothing matches, the
list reads `(no matches)` and Enter and S do nothing. A search belongs to its
list. Opening a bank, going back to the banks, opening an archive, or the
archive's open bank changing clears it. Hiding the navigator keeps it, so B
comes back to the same rows.

A saved slot is kept for you. As soon as the save succeeds the daemon writes
the bank to the file it keeps its bank in, the `--bank` file it was
started with or `bank.json` in the config directory, and the next start with
the same `--bank`, or with none, loads it. If it cannot write the file, the
daemon refuses the save and the slot is as it was; the footer then reads
`Error: cannot keep bank`. Any other refusal of the save is shown there the
same way. The file S offers to write is an extra copy, for a bank you load
yourself or set as the `User bank`. A `User bank` does not replace a bank file
the daemon loaded at start, since a TUI loads it only into a daemon still on
the factory bank.

### MIDI input screen

M lists All inputs, each input the daemon found, and None. `(*)` marks the one
the daemon listens to. Enter selects the row under the cursor. R scans again for
devices plugged in since. Esc goes back. If the daemon refuses a choice, the
footer says `the daemon refused ...` and the screen stays open.

### Settings screen

C shows two settings, selected with Up and Down and edited with Enter.

- `Zip archive`. A path opens that archive in the daemon for every front-end. A
  blank answer closes the archive and forgets its path. Because the path is
  sent absolute, the daemon reopens the same archive whatever directory it
  next starts in.
- `User bank`. The path, made absolute, is written to `config.conf` and loaded
  now.

The screen footer prints the path of `config.conf`.

### Key input limits

The TUI reads what the terminal has sent one chunk at a time. Keys sent in a
burst, and an arrow split across two chunks, behave as follows.

- A key read takes at most 8 bytes, and a read in an open search takes 256.
  Outside a search the TUI acts on the first key of a read and drops the rest,
  so two Down arrows sent in one write move once. `/` is the exception: it opens
  the search, and the rest of that read is typed into it. In an open search, an
  arrow in the same read as the Enter or Esc that ends it still moves.
- An arrow is `ESC [ A` to `ESC [ D`. If a read ends inside one, the TUI finishes
  it with the next read, so a cut arrow still moves once. An `ESC [` waits one
  400 ms refresh tick for its last byte. After that it is dropped, and a `B`
  that comes later is the B key. A trailing ESC is held only while more input is
  already waiting.
- A lone ESC is the Esc key at once. If the ESC of an arrow arrives in a read of
  its own, as it can on a slow link, it acts as Esc. The arrow's `[` then does
  nothing, and its `B`, in a read of its own, is the B key, which opens or hides
  the navigator.
- Ctrl- and Shift-arrows (`ESC [ 1 ; 5 B`) do nothing outside a search. In an
  open search they move like the plain arrows.
- On a normal terminal Ctrl-C is not read as a key. The TUI leaves the
  terminal's signal keys on and has no handler, so Ctrl-C sends SIGINT and ends
  it at once, on any screen and in an open search. It does not leave the
  alternate screen or show the cursor again, and the shell sees exit status 130.
  The daemon keeps running. Quit with Q to avoid this. After a Ctrl-C,
  `tput rmcup; tput cnorm` restores the screen and the cursor. `reset` may bring
  back only the cursor.

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

A patch written into a slot in the page reaches the daemon as `patch.save`,
which writes the bank to the file the daemon keeps it in (the `--bank` file it
was started with, or `bank.json` in the config directory), and the daemon loads
that file at its next start. When the page keeps a whole bank (the Keep
button), the adapter also sends `bank.keep`, which writes the same file.

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
bank. When it is a `--bank` file that is not empty, it also prints
`bank   patch.save and bank.keep will not overwrite <path>; move it away or start with another --bank`,
and saves are refused until that file is gone or empty (see
[What survives a restart](#what-survives-a-restart)). Loading a bank file later
(`L`, or the daemon's `bank.load_file`) replaces the browsable bank only. It
does not change the sound, and it does not change which file the daemon keeps
its bank in.

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
the ordinary bank's contents or label change. It starts at 1 when the daemon
loaded a bank file at start, and at 0 when it kept the factory bank.
`archive_rev` moves when the archive or its open bank changes, including a
change from another client. Both appear in `patch.current`. Asking for the
bank that is already open does not move `archive_rev`.

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
| `patch.load <slot> init` on an empty slot | `bank` | the slot | the bank label | `Init` |
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
that variable is unset. With neither `XDG_CONFIG_HOME` nor `HOME` set, none of
these files is read or written. A daemon started with `--bank` keeps its bank
in the `--bank` file either way.

| File | Written by | Contents |
|---|---|---|
| `archive.path` | the daemon | The archive's path on one line. Written when `archive.open` gets an explicit path. Deleted by `archive.close`. Read at daemon start. |
| `bank.json` | the daemon, on every successful `patch.save` and on `bank.keep`, when it was started without `--bank` | The ordinary bank. Read at daemon start unless `--bank` is given. A daemon started with `--bank` keeps its bank in that file instead and never writes `bank.json`. |
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

When a TUI starts, it loads the `bank` file named in `config.conf` into the
daemon only if the daemon is still on the factory bank (`bank_rev` is still 0):
it loaded no bank file at start, neither `--bank` nor `bank.json`, and nothing
has been saved into the bank or a bank file loaded since, from any front-end.
The file then replaces the factory bank. Otherwise a TUI starting or attaching
leaves the bank as it is, so a patch saved into it and kept in the daemon's bank
file (`bank.json`, or the `--bank` file) is still there after the daemon
restarts. A relative `bank` value is made absolute against the TUI's directory
when it is sent. `config.conf` itself is not rewritten. An `archive =` line
from before the daemon kept the path itself is offered to a daemon that
remembers no archive, and removed from `config.conf` once the daemon takes it.

## MCP server

`quesynth --mcp` is a local Model Context Protocol server over stdio. It gives
an MCP client, such as an editor or an agent, one typed tool for every command
the daemon's control protocol accepts. With them a client can read and edit
parameters, save and load patches, work with the bank and the archive, choose
MIDI inputs and send MIDI messages, set the master volume and stop the daemon.
It is a mode of the standalone executable, not a separate program, and it needs
no Node.js, Python or other runtime.

The server is a client of the daemon's control socket, the way the TUI is. It
does not start audio, it does not start a daemon, and it holds no engine,
registry or parameter state. The daemon stays the only authority for parameter
metadata and values, and every reply carries what the daemon said. The server
runs no shell, has no network listener and opens no file of its own. When a tool
takes a path, the daemon reads or writes that path, with your permissions, and
resolves a relative one against the daemon's working directory. The server exits
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

`tools/list` returns 33 tools. `inspect_synth` and `apply_parameters` came
first and keep their names, input schemas and results. Each of the other 31
sends one command of the control protocol, and there is one for every command
that `control_handle` in `hosts/standalone/command_handler.odin` accepts. A
tool is named after its command with the dot written as an underscore, except
that the command `midi` is the tool `midi_send`.

The tools are an allowlist. No tool takes a command name, a protocol line, a
shell string, a URL or a free-form list of operands, so a client can ask only
for what a row below describes. A `tools/call` with any other name fails with
the JSON-RPC error `-32602` and the message `Unknown tool`. That includes the
daemon's own spellings, such as `daemon.status` and `midi`.

The tables follow the order of `tools/list`. The arguments column gives each
argument's name, its type and its range, and says `optional` when it can be
left out; the types are explained under [Arguments and checks](#arguments-and-checks).
The last three columns are the tool's annotations, explained under
[Annotations](#annotations).

#### The two original tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `inspect_synth` | `state.snapshot`, `patch.current`, `parameter.list` | none; other keys are ignored | yes | no | yes |
| `apply_parameters` | `parameter.set_many` | `expected_revision` and `parameters`, as [described below](#apply_parameters) | no | yes | yes |

#### Daemon tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `daemon_status` | `daemon.status` | none | yes | no | yes |
| `daemon_info` | `daemon.info` | none | yes | no | yes |
| `daemon_shutdown` | `daemon.shutdown` | none | no | yes | yes |

`daemon_status` returns the daemon's `state`, the protocol version `proto` and
the parameter `revision`. `daemon_info` adds how many control and MIDI messages
the daemon dropped because a queue was full and, as far as it can report them,
`sample_rate`, `buffer`, `voices`, `max_voices`, `uptime` in seconds, `volume`
and `backend`. `backend` comes last because its value, such as `ALSA (default)`,
has spaces.

`daemon_shutdown` does what `quesynth --stop` does. The daemon answers first,
then stops the sound and exits. It saves nothing more. A patch saved with
`patch_save` is already in the daemon's bank file (`bank.json`, or the bank
file named on its command line), but a bank you loaded with `bank_load_file`
and did not keep is lost. Every tool then returns `daemon_unavailable` until a
daemon is started again.

#### Parameter and state tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `parameter_list` | `parameter.list` | none | yes | no | yes |
| `parameter_get` | `parameter.get` | `id` token | yes | no | yes |
| `parameter_set` | `parameter.set` | `id` token; `value` integer ±9007199254740991 | no | yes | yes |
| `parameter_set_many` | `parameter.set_many` | `parameters` pairs 1..128; `expected_revision` integer 0..9007199254740991, optional | no | yes | yes |
| `state_snapshot` | `state.snapshot` | none | yes | no | yes |

`parameter_list` returns the registry as record lines, `parameter_get` one
stored value with the revision, and `state_snapshot` the revision, the sample
rate, the buffer size and every stored value from one consistent snapshot.
Values are stored integers, not Hz or dB.

`parameter_set` sets one parameter, and `parameter_set_many` sets a batch that
the audio thread applies together. The daemon checks every id and value first,
and a batch with one bad member changes nothing. A repeated id is set again in
order, so the last value wins. With `expected_revision`, the daemon applies the
batch only if its revision is still that number, and it answers after the audio
thread has decided. If the revision has moved it returns `revision_conflict`
with `current_revision=<n>` and changes nothing. If the audio thread does not
answer within 250 ms, the call fails with `daemon_not_ready` and the message
`commit outcome unknown; inspect state before retrying`, and the batch may still
be applied. Without `expected_revision`,
the batch is queued and the call can overwrite an edit made since you looked.
Send the guard unless you mean to overwrite.

#### Patch tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `patch_load` | `patch.load` | `slot` integer 0..127 | no | yes | no |
| `patch_apply` | `patch.apply` | `parameters` pairs 1..128 | no | yes | no |
| `patch_load_file` | `patch.load_file` | `path` text | no | yes | no |
| `patch_save` | `patch.save` | `slot` integer 0..127; `name` text, optional | no | yes | yes |
| `patch_current` | `patch.current` | none | yes | no | yes |
| `patch_clear` | `patch.clear` | none | no | yes | yes |

`patch_load`, `patch_apply`, `patch_load_file` and the archive tool
`archive_load` replace the whole sound at once and clear what the last patch
left ringing. Held notes keep sounding. Loading the same patch again is how a
player silences a ringing tail, which is why these four are not idempotent.

`patch_load` loads a filled slot of the ordinary bank, and an empty slot comes
back as the daemon's `unknown_parameter` error. The tool has no `init` argument
(see [Bank navigator](#bank-navigator)). `patch_apply` applies the pairs
you give as one patch, the way a front-end loads a patch it holds, and
parameters you do not name keep their values. It leaves the playing patch's name
as it was; `patch_clear` forgets it. `patch_load_file` makes the daemon read a
`.sy1` or JSON patch file, names the playing patch after the name inside the
file or else after the file, and returns that name as a `name=` record line.

`patch_save` stores the sound as it is now in a slot, overwriting it, and names
the playing patch after the slot. Every change sent before it counts, from any
client, even one the audio thread has not applied yet: the daemon answers once
it has. If that takes more than 250 ms, the call fails with `daemon_not_ready`
and `earlier edits not applied; nothing saved`, and nothing is stored. The
daemon then writes the bank to the file it keeps its bank in, which it
loads at its next start, so the slot survives a restart without `bank_keep`.
After another bank file was loaded only that slot is written there, so the
kept bank's other slots stay.
That file is the bank file named on the daemon's command line, or else
`bank.json` in its configuration directory; a daemon started with a bank file
never writes `bank.json`. If it cannot write the file, the call fails with
`internal_error` and `cannot keep bank`, and nothing is stored. It also fails so
when the bank file from the command line is not empty and is not a bank the
daemon loaded or wrote, which it never replaces. With neither that file nor a
configuration directory the slot stays in memory. Without a `name`, or with an
empty one, the slot keeps its current name, which is `Init` for an empty slot.
The daemon keeps at most 48 bytes of a name. If that cut falls inside a
multi-byte character, the name the daemon stores is not valid UTF-8, and JSON
cannot carry it. The save succeeds, but `patch_current`, `inspect_synth` and the
`quesynth://patch` resource then fail with `daemon_error` and the message
`QCP response is not valid UTF-8`, until `patch_clear` or the load of a
different patch replaces the identity. Loading the same slot again does not.
`patch_current` reads the patch identity described under
[Patch identity](#patch-identity), and `patch_clear` forgets where the sound
came from while the values and the banks stay.

#### Bank tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `bank_list` | `bank.list` | none | yes | no | yes |
| `bank_write` | `bank.write` | `path` text | no | yes | yes |
| `bank_load_file` | `bank.load_file` | `path` text | no | yes | yes |
| `bank_keep` | `bank.keep` | none | no | yes | yes |

`bank_list` returns the bank's label, how many slots are filled and one record
line for each of the 128 slots, empty ones included. `bank_write` makes the
daemon write the whole bank as JSON to the path you give, and it replaces a file
that is already there. `bank_load_file` replaces the browsable bank with a JSON
bank the daemon reads. The sound does not change, and the bank is not saved.
`bank_keep` takes no path. It writes the same file `patch_save` writes, the
bank file from the daemon's command line or `bank.json`, and reports it in
`path`. `patch_save` already does this after every save, so `bank_keep` is for
a bank you replaced with `bank_load_file` and did not save a patch into.

#### Archive tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `archive_open` | `archive.open` | `path` text, optional | no | yes | yes |
| `archive_adopt` | `archive.adopt` | `path` text | no | no | yes |
| `archive_current` | `archive.current` | none | yes | no | yes |
| `archive_banks` | `archive.banks` | `offset` integer 0..9007199254740991, optional; `count` integer 0..9007199254740991, optional | yes | no | yes |
| `archive_bank` | `archive.bank` | `index` integer 0..9007199254740991 | no | no | yes |
| `archive_patches` | `archive.patches` | `offset` integer 0..9007199254740991, optional; `count` integer 0..9007199254740991, optional | yes | no | yes |
| `archive_load` | `archive.load` | `index` integer 0..9007199254740991; `bank` integer 0..9007199254740991, optional | no | yes | no |
| `archive_close` | `archive.close` | none | no | yes | yes |

These work on the one archive the daemon shares with every front-end, as
described under [Banks and archives](#banks-and-archives). `archive_open`
indexes a ZIP of bank ZIPs and remembers its path for the next daemon start. It
loads no sound. With no `path`, or an empty one, it opens the remembered
archive again. `archive_adopt` offers a path that the daemon takes only if it
has no archive open and remembers none, and the reply says `adopted=1` or
`adopted=0`. `archive_close` closes the archive and forgets the path.

`archive_banks` and `archive_patches` return a page. `count` defaults to 64 and
the daemon returns at most 256, so a larger `count` is clamped. Zero returns
none. A `count` with no `offset` starts at offset 0. `archive_bank` opens a bank
for browsing, for every client, and does not change the sound. `archive_load`
loads one patch. With `bank`, that bank is opened first; send it when another
client may have browsed elsewhere since you listed the patches. Without it the
open bank is used. Read `archive_rev` in the replies to notice another client
changing the archive.

#### MIDI tools

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `midi_list` | `midi.list` | none | yes | no | yes |
| `midi_select` | `midi.select` | `input` token | no | no | yes |
| `midi_current` | `midi.current` | none | yes | no | yes |
| `midi_send` | `midi` | `status` integer 0..255; `data1` integer 0..127; `data2` integer 0..127 | no | yes | no |

`midi_list` returns the inputs the daemon finds now, each with an `id` and a
`name`, and the current selection. `midi_select` takes `all`, `none` or an id
from that list, for every client; see [MIDI](#midi). `midi_current` returns the
selection and `midi_rev`. `midi_send` injects one message into the queue that
the hardware inputs use. The status byte carries the channel in its low four
bits: 144 is note on and 128 note off on channel 1, 176 control change, 192
program change and 224 pitch bend. Send 0 for the missing data byte of a program
change. A note on keeps sounding until its note off arrives, and nothing
releases held notes but a note off or stopping the daemon. A program change
loads the patch it picks, as under
[Bank Select and Program Change](#bank-select-and-program-change), which
replaces the sound and any edit of it that was not saved, so `midi_send` is
destructive.

#### Volume tool

| Tool | QCP command | Arguments | Read-only | Destructive | Idempotent |
|---|---|---|---|---|---|
| `volume` | `volume` | `milli` integer 0..1000 | no | no | yes |

`volume` sets the master output level for every client, in thousandths: 0 is
silent and 1000 is full level, which is where each daemon start begins. It is
the listener's level, not a patch parameter, so no revision moves. There is no
tool that reads it alone; `daemon_info` reports the current level.

#### Annotations

Every tool carries all four annotations as booleans, whatever protocol version
the client negotiated. They describe the tool in the tables above.

| Annotation | Meaning here |
|---|---|
| `readOnlyHint` | The call changes nothing in the daemon, on disk or anywhere else. |
| `destructiveHint` | The call can overwrite or discard something the daemon keeps nowhere else: parameter values, the sounding patch, a bank slot or the bank, a file on disk, the remembered archive, the patch identity, or the daemon itself. It is `false` for effects that last only for the session or only add to it: the master volume, the MIDI selection, browsing an archive bank and `archive_adopt`. It is `true` for `midi_send`, because a program change replaces the sounding patch. |
| `idempotentHint` | Repeating the same call leaves the same state and does nothing more that you can hear or see, leaving aside the counters `revision`, `bank_rev`, `archive_rev` and `midi_rev`. It is `false` for the four calls that replace the whole patch, because loading again clears what the last load left ringing, and for `midi_send`. |
| `openWorldHint` | Always `false`. The only party a call reaches is the local daemon. |

`destructiveHint` and `idempotentHint` mean something only for a tool that is
not read-only. The server still sets them on every tool, and a read-only tool is
always not destructive and idempotent. Annotations are hints for the client, for
example to ask you before a destructive call. They do not stop a call, and the
server enforces nothing based on them.

#### Arguments and checks

The server checks every call before it contacts the daemon. A call that fails a
check returns `invalid_arguments`, names the argument in its message and sends
nothing. The checks cover the types, required arguments and ranges in the
tables, and whatever would make the daemon read something other than what you
wrote. They never decide whether a parameter exists, whether a value is inside
a parameter's range, whether a slot is filled, whether an archive is open or
whether a device is plugged in. Those are the daemon's to say.

For the 31 tools after the first two:

- `arguments` must be an object. Leaving it out is the same as `{}`.
- An argument the tool does not declare is refused as `unknown argument: <name>`,
  naming the first such name in alphabetical order. This is deliberate. A
  misspelt `expected_revision` would otherwise drop its guard without a word.
  The empty string is a name like any other, so `{"":1}` is refused as
  `unknown argument: ` with nothing after the colon and space. It comes first in
  alphabetical order.
- A required argument must be present. `null` is never the same as leaving an
  argument out, because it has the wrong type. Nothing is converted, so the
  string `"5"` is not the integer 5.
- An `integer` is a whole number inside the stated range. `30.0` and `3e1` count
  as 30. No integer goes beyond ±9007199254740991, the largest that a JSON
  number holds exactly.
- A `token` is one non-empty string with no space and no control character.
  The control characters are U+0000 to U+001F and U+007F to U+009F. The spaces
  are what Odin's `unicode.is_space` counts: U+0009 to U+000D, U+0020, U+0085,
  U+00A0, U+1680, U+2000 to U+200B, U+200E, U+200F, U+2028, U+2029, U+202F,
  U+205F, U+3000 and U+FEFF. That list includes the zero-width space, the two
  direction marks and the byte order mark. The daemon splits a request on
  spaces, so a token containing one would arrive as two. Parameter ids,
  `midi_select`'s `input` and the ids inside `parameters` are tokens.
- A `text` is a string the daemon reads to the end of the line: a path or a
  name. It may hold spaces inside, as in `my patches/lead.sy1`. It may not hold a
  control character, U+2028 or U+2029, because those would end the line. It may
  not start or end with whitespace either, because the daemon trims both ends and
  would then use a different path. The whitespace it trims is U+0009 to U+000D,
  U+0020, U+0085, U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F,
  U+205F and U+3000. That is narrower than what splits a token, so U+200B,
  U+200E, U+200F and U+FEFF are allowed anywhere in a text and not in a token. A
  required `text` must not be empty. An optional one that is an empty string
  counts as left out.
- `pairs` is an array of 1 to 128 objects. Each has exactly an `id` token and a
  `value` integer, and any other key is refused, one named with the empty string
  too, as `parameters[<n>] has an unknown key: `. The limit of 128 is the
  daemon's. An `id` that starts with `expected_revision=` is refused by
  `parameter_set_many`, because the daemon would read it as the guard.
  Within the first invalid pair in array order, the lexicographically smallest
  unknown key is reported, including the empty string.

The two original tools keep their own checks, described under
[`apply_parameters`](#apply_parameters), and keep ignoring keys they do not
declare, one named with the empty string included.

The server does not limit how long a text is. The daemon keeps at most 48 bytes
of a patch name, and a request line over the 64 KiB frame limit is refused by
the server itself as `daemon_error` and not sent.

These calls are refused with these messages. Each row was run against the built
binary, and none of them reached the daemon.

| Tool | Arguments | Message |
|---|---|---|
| `parameter_get` | `[]` | `arguments must be an object` |
| `parameter_get` | `{}` | `missing argument: id` |
| `parameter_get` | `{"id":"filter.cutoff","extra":1}` | `unknown argument: extra` |
| `parameter_get` | `{"id":"filter.cutoff","":1}` | `unknown argument: ` |
| `parameter_get` | `{"id":null}` | `id must be a string` |
| `parameter_get` | `{"id":""}` | `id must not be empty` |
| `parameter_get` | `{"id":"filter cutoff"}` | `id must not contain whitespace or control characters (U+0020)` |
| `parameter_get` | `{"id":"filter\u200b.cutoff"}` | `id must not contain whitespace or control characters (U+200B)` |
| `parameter_set` | `{"id":"filter.cutoff","value":1.5}` | `value must be an integer from -9007199254740991 to 9007199254740991` |
| `patch_load` | `{"slot":128}` | `slot must be an integer from 0 to 127` |
| `volume` | `{"milli":1001}` | `milli must be an integer from 0 to 1000` |
| `midi_send` | `{"status":144,"data1":128,"data2":0}` | `data1 must be an integer from 0 to 127` |
| `parameter_set_many` | `{"parameters":[]}` | `parameters must be an array of 1 to 128 entries` |
| `parameter_set_many` | `{"parameters":[1]}` | `parameters[0] must be an object with id and value` |
| `parameter_set_many` | `{"parameters":[{"id":"a"}]}` | `parameters[0] needs id and value` |
| `parameter_set_many` | `{"parameters":[{"id":1,"value":1}]}` | `parameters[0].id must be a string` |
| `parameter_set_many` | `{"parameters":[{"id":"a","value":1,"x":2}]}` | `parameters[0] has an unknown key: x` |
| `parameter_set_many` | `{"parameters":[{"id":"a","value":1,"":2}]}` | `parameters[0] has an unknown key: ` |
| `parameter_set_many` | `{"parameters":[{"id":"expected_revision=3","value":1}]}` | `parameters[0].id must not begin with expected_revision=` |
| `parameter_set_many` | `{"expected_revision":-1,"parameters":[{"id":"a","value":1}]}` | `expected_revision must be an integer from 0 to 9007199254740991` |
| `parameter_set_many` | `{"expected_revison":3,"parameters":[{"id":"a","value":1}]}` | `unknown argument: expected_revison` |
| `patch_apply` | `{"expected_revision":3,"parameters":[{"id":"a","value":1}]}` | `unknown argument: expected_revision` |
| `patch_load_file` | `{"path":""}` | `path must not be empty` |
| `bank_write` | `{"path":"bank.json "}` | `path must not start or end with whitespace` |
| `bank_write` | `{"path":"a\nb.json"}` | `path must not contain control characters or line separators (U+000A)` |
| `patch_save` | `{"slot":1,"name":"Lead\u0000"}` | `name must not contain control characters or line separators (U+0000)` |
| `archive_banks` | `{"offset":-1}` | `offset must be an integer from 0 to 9007199254740991` |
| `midi_select` | `{"input":"hw:2,0 "}` | `input must not contain whitespace or control characters (U+0020)` |
| `daemon_shutdown` | `{"now":true}` | `unknown argument: now` |

#### Schemas

`tools/list` describes every tool with a `name`, a `description`, an
`inputSchema`, an `outputSchema` and `annotations`. It lists the same thing for
every protocol version, with the annotations and the `outputSchema` always
present.

The input schema of each of the 31 tools is a closed object: `"type":"object"`,
`"additionalProperties":false`, a `properties` entry for each argument and a
`required` list, which is left out when nothing is required. Integers carry a
`minimum` and a `maximum`, and an array carries `minItems` and `maxItems`. A
token or a text carries a `pattern` that accepts exactly the strings the server
accepts. The four patterns are these, in ECMA-262 syntax for the `u` flag. The
whitespace is spelled out because `\s` means something different in JavaScript
and in Odin.

```text
token          ^[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200b\u200e\u200f\u2028\u2029\u202f\u205f\u3000\ufeff]+$
text           ^[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000](?:[^\u0000-\u001f\u007f-\u009f\u2028\u2029]*[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000])?$
optional text  ^(?:[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000](?:[^\u0000-\u001f\u007f-\u009f\u2028\u2029]*[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000])?)?$
set_many id    ^(?!expected_revision=)[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200b\u200e\u200f\u2028\u2029\u202f\u205f\u3000\ufeff]+$
```

`optional text` is the pattern of an optional `text` argument, which also
accepts the empty string. A required `text` has `"minLength":1` as well, and a
`token` has it too. `set_many id` is the pattern of the `id` in each entry of
the `parameters` of `parameter_set_many`: the token pattern behind a negative
lookahead, because that tool refuses an id that begins with `expected_revision=`
at any position, as the daemon would read it as the guard. The `id` of an entry
of `patch_apply` has the plain token pattern, since that command has no guard.

As an example, this is the complete entry that `tools/list` returns for
`volume`:

```json
{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":false},"description":"Set the daemon's master output level for every client: 0 is silent, 1000 is full level, the level at each start. It is the listener's level, not a patch parameter, so no revision changes. daemon_info reports the current level.","inputSchema":{"additionalProperties":false,"properties":{"milli":{"description":"Level in thousandths of full scale.","maximum":1000,"minimum":0,"type":"integer"}},"required":["milli"],"type":"object"},"name":"volume","outputSchema":{"additionalProperties":false,"oneOf":[{"required":["fields","lines"]},{"required":["code","message"]}],"properties":{"code":{"description":"On a failed call, the error token: the daemon's own, or invalid_arguments, daemon_unavailable, daemon_timeout or daemon_error.","type":"string"},"fields":{"description":"The text after ok on the first line of the daemon's reply, without the one space that separates it from ok.","type":"string"},"lines":{"description":"The record lines that follow it, unchanged and in the daemon's order.","items":{"type":"string"},"type":"array"},"message":{"description":"On a failed call, the daemon's message, or the server's reason.","type":"string"}},"type":"object"}}
```

The input schemas of the two original tools are the ones the server has always
had. They have no `additionalProperties` and no ranges beyond the minimum shown:

```json
{"type":"object","properties":{}}
```

```json
{"type":"object","required":["expected_revision","parameters"],"properties":{"expected_revision":{"type":"integer","minimum":0},"parameters":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"integer"}}}}}}
```

The 31 tools share one `outputSchema`. The structured content of a call is the
daemon's reply on success and `{"code": ..., "message": ...}` on failure, and a
client library may check it against the schema without looking at `isError`
first. So the schema is one closed object that lists the properties of both
shapes and says, with `oneOf`, that exactly one set is present: `fields` and
`lines`, or `code` and `message`. The `code` is the error token and is not an
enumeration, since the daemon owns its tokens. A success with an extra key, a
failure without its `message` and a payload with both shapes all fail the check.

```json
{"additionalProperties":false,"oneOf":[{"required":["fields","lines"]},{"required":["code","message"]}],"properties":{"code":{"description":"On a failed call, the error token: the daemon's own, or invalid_arguments, daemon_unavailable, daemon_timeout or daemon_error.","type":"string"},"fields":{"description":"The text after ok on the first line of the daemon's reply, without the one space that separates it from ok.","type":"string"},"lines":{"description":"The record lines that follow it, unchanged and in the daemon's order.","items":{"type":"string"},"type":"array"},"message":{"description":"On a failed call, the daemon's message, or the server's reason.","type":"string"}},"type":"object"}
```

`inspect_synth` and `apply_parameters` describe their own results in the same
way, each with the failure shape beside its success shape:

```json
{"additionalProperties":false,"oneOf":[{"required":["revision","state","patch","parameters"]},{"required":["code","message"]}],"properties":{"code":{"description":"On a failed call, the error token: the daemon's own, or invalid_arguments, daemon_unavailable, daemon_timeout or daemon_error.","type":"string"},"message":{"description":"On a failed call, the daemon's message, or the server's reason.","type":"string"},"parameters":{"additionalProperties":false,"properties":{"fields":{"type":"string"},"lines":{"items":{"type":"string"},"type":"array"}},"required":["fields","lines"],"type":"object"},"patch":{"additionalProperties":false,"properties":{"fields":{"type":"string"},"lines":{"items":{"type":"string"},"type":"array"}},"required":["fields","lines"],"type":"object"},"revision":{"type":"integer"},"state":{"additionalProperties":false,"properties":{"fields":{"type":"string"},"lines":{"items":{"type":"string"},"type":"array"}},"required":["fields","lines"],"type":"object"}},"type":"object"}
```

```json
{"additionalProperties":false,"oneOf":[{"required":["count","revision"]},{"required":["code","message"]}],"properties":{"code":{"description":"On a failed call, the error token: the daemon's own, or invalid_arguments, daemon_unavailable, daemon_timeout or daemon_error.","type":"string"},"count":{"type":"integer"},"message":{"description":"On a failed call, the daemon's message, or the server's reason.","type":"string"},"revision":{"type":"integer"}},"type":"object"}
```

#### Results

A successful call returns the daemon's reply as JSON text in `content[0].text`.
From protocol `2025-06-18` on, the same object is also returned as
`structuredContent`. For each of the 31 tools after the first two it is:

```json
{"fields":"...","lines":["..."]}
```

`fields` is the text after `ok` on the reply's first line, without the one
space that separates it from `ok`, and `lines` are the record lines that follow
it, one string each, unchanged and in the daemon's order. Any other space, at
either end of `fields` too, is kept. A reply with nothing after `ok` has an
empty `fields`, and one without record lines has an empty `lines`.

The daemon writes a newline before each record line. The server splits what
follows the first newline on newlines, preserving every empty record, including
the last. Thus `ok` has `lines: []`, `ok\n` has `lines: [""]`, and `ok\n\n` has
`lines: ["",""]`. A patch name that ends in a newline shows it: the daemon's
reply to `patch_load_file` then ends in `name=Trail` and a newline, and `lines`
is `["name=Trail",""]`.

The server does not rename, reorder or tidy anything. If the daemon folds the
spaces of a name into underscores in a field, as `patch_save` does in `name=`,
you get the underscores. If it keeps them in a record line, as `patch_current`
does, you get the spaces. The fields of each
reply are the ones the daemon documents under [Control protocol](#control-protocol),
[Banks and archives](#banks-and-archives), [Patch identity](#patch-identity)
and [MIDI](#midi), and the examples below show real ones.

Some commands only queue their work. `parameter_set`, a `parameter_set_many`
without `expected_revision`, `patch_load`, `patch_apply`, `patch_load_file` and
`archive_load` are answered when the change is queued, before the audio thread
has applied it. The `revision` in such a reply is the one the daemon held at that
moment, so it is the revision before the change, and a read made straight after
can still show the old values until the audio thread's next block. A guarded
`parameter_set_many` is different. The daemon answers after the audio thread has
decided, and the `revision` in a success is the one after the change.
`patch_save` waits too, for the changes queued before it, so a save straight
after any of these stores what they did.

The two original tools return the results described under
[`inspect_synth`](#inspect_synth) and [`apply_parameters`](#apply_parameters).
They, and the two resources, strip the spaces at both ends of each `fields` and
of a failure's `message`, as they always have.

A failed call is a normal result with `isError: true`. It carries the object
`{"code": ..., "message": ...}` in the same places as a success does. A refusal
by the daemon comes through with its error token as `code`, whatever the token
is, and its message unchanged apart from the one space after the token, and
`message` is empty if the daemon gave none. Each tool's
`outputSchema` accepts this object as well as the success result (see
[Schemas](#schemas)), so a failed call passes the same check as a successful one.

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
published by then, so an `inspect_synth` that follows sees it. If the audio
thread has not answered within 250 ms, the reply is `daemon_not_ready` with the
message `commit outcome unknown; inspect state before retrying`, and the batch
stays queued and may still be applied. A success returns

```json
{"count":2,"revision":1}
```

where `count` is the number of pairs and `revision` is the revision after the
change, the one to pass as `expected_revision` next time. A stale
`expected_revision` returns `revision_conflict`, with the revision the daemon
holds now in the message as `current_revision=<n>`, and changes nothing. Call
`inspect_synth`, look again, then send the batch with the new revision.
`parameter_set_many` sends the same command with the stricter checks of the
other 31 tools, and there `expected_revision` is optional.

#### When the outcome is not known

The server gives each request to the daemon on a connection of its own, with a
deadline of 500 ms that starts at the connect and covers the whole exchange. It
never sends a request twice. A tool that is not read-only is sent as a change.
If the answer to one does not arrive, the change may or may not have happened.
When the request was already sent, the message of the failure ends with
`; the request was sent and the change may have been applied`. The cases are:

- `daemon_timeout`: the deadline passed after the server had connected.
- `daemon_error`: the daemon closed the connection before it replied, or its
  reply could not be read.
- `daemon_not_ready` with `commit outcome unknown; inspect state before
  retrying`: the daemon queued a guarded batch and the audio thread did not
  answer within 250 ms, or the daemon was stopped first. The batch stays queued
  and may still be applied.

In each case read the state before you send anything again: `state_snapshot`
or `inspect_synth` for parameters, `patch_current`, `bank_list`,
`archive_current` or `midi_current` for the rest. A read-only tool that fails
gets the plain message without that sentence, because asking again is safe.

The 500 ms deadline is the same for every command, including those that read or
write a file. A slow one, such as `archive_open` on a very large archive, can
overrun it. The server then reports `daemon_timeout` with the sentence above and
does not repeat the request.

#### Errors

A tool failure is a normal result with `isError: true`. Its `code` is one of:

- `invalid_arguments`: the call failed the checks above. Nothing was sent.
- `daemon_unavailable`: the server could not open the socket or connect to it.
  Nothing was sent. After `daemon_shutdown` every call gets this.
- `daemon_timeout`: the daemon did not answer within the 500 ms deadline.
- `daemon_error`: a failure of the server's own, with no daemon error behind it:
  a request over the 64 KiB frame limit, which is not sent; a daemon that
  hung up; a reply or a frame that could not be read; a reply that is not valid
  UTF-8, which JSON cannot carry unchanged, so none of it is returned.
- A daemon error token, with the daemon's message: `revision_conflict`,
  `out_of_range`, `unknown_parameter`, `invalid_payload`, `daemon_not_ready`,
  `transaction_failed` and the others in
  [Control protocol](#control-protocol).

Failures of the protocol itself are JSON-RPC errors with a `code` and a
`message`:

| Code | Meaning |
|---|---|
| `-32700` | The line is not valid JSON. `id` is `null`. Text after the value, a trailing comma, a malformed number or string and nesting more than 100 levels deep are refused the same way, and so is an empty line. So is a request in which one object has the same member name twice, at any depth and however the name is spelt, so a client cannot match the reply to its request; only a name that is the empty string may repeat. |
| `-32600` | Not a JSON-RPC 2.0 request: not an object, `jsonrpc` is not `"2.0"`, `method` is not a string, or `id` is neither a string nor an integer-valued number. `id` is `null`. A second `initialize` also returns `-32600`, with its own `id`. |
| `-32601` | Method not found. |
| `-32602` | Bad parameters: `initialize` without its fields, `params` that is not an object, `tools/call` without a tool name or with a name that is not one of the 33 tools, `resources/read` without a string `uri`. |
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

The sessions below were captured from `quesynth --mcp`. Each request and each
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

A daemon that had just started on the factory bank, with no bank file to load,
so `bank_rev` is 0. The registry and the snapshot are cut to their first two
entries here; the daemon's own reply lists all 92 parameters (`count=92`).

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

#### Driving the daemon

This session used a real daemon with a fresh configuration directory. Its working
directory held a small archive, `corpus.zip`, with one bank of two patches. The
requests follow an `initialize` and a `notifications/initialized` like the ones
above, so the ids start at 2. The values in the replies, such as the revision
numbers, are what that daemon said at the time.

Silence the instrument first. `daemon_status` is a read: `fields` is the text
after `ok` and `lines` is empty because the reply has no record lines.
`midi_select` with `none` stops the daemon listening to MIDI hardware, and
`volume` with 0 turns the master level down, so nothing below makes a sound.

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"daemon_status","arguments":{}}}
```

```json
{"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"state=running proto=1 revision=0\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"state=running proto=1 revision=0","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"midi_select","arguments":{"input":"none"}}}
```

```json
{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"selected=none midi_rev=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"selected=none midi_rev=1","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"volume","arguments":{"milli":0}}}
```

```json
{"id":4,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"volume=0\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"volume=0","lines":[]}}}
```

Read one parameter, then change two with the revision you were shown. The
daemon applies both together and the revision moves by one:

```json
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"parameter_get","arguments":{"id":"filter.cutoff"}}}
```

```json
{"id":5,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"value=81 revision=0\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"value=81 revision=0","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"parameter_set_many","arguments":{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":70},{"id":"filter.resonance","value":10}]}}}
```

```json
{"id":6,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"count=2 revision=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"count=2 revision=1","lines":[]}}}
```

The same revision is stale now. The daemon refuses the batch and changes
nothing, and its `revision_conflict` comes through unchanged:

```json
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"parameter_set_many","arguments":{"expected_revision":0,"parameters":[{"id":"filter.cutoff","value":71}]}}}
```

```json
{"id":7,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"revision_conflict\",\"message\":\"current_revision=1\"}","type":"text"}],"isError":true,"structuredContent":{"code":"revision_conflict","message":"current_revision=1"}}}
```

Save the sound into slot 5, load that slot, and read the patch identity. The
daemon folds the space in the name into an underscore in the `name=` field of
the first two replies, and keeps it in the `name=` record line of the third.
The load was answered with `revision=1`, before the audio thread applied it, and
`patch_current` already shows 2:

```json
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"patch_save","arguments":{"slot":5,"name":"Warm Pad"}}}
```

```json
{"id":8,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"slot=5 name=Warm_Pad bank_rev=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"slot=5 name=Warm_Pad bank_rev=1","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"patch_load","arguments":{"slot":5}}}
```

```json
{"id":9,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"slot=5 name=Warm_Pad count=99 revision=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"slot=5 name=Warm_Pad count=99 revision=1","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"patch_current","arguments":{}}}
```

```json
{"id":10,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"slot=5 bank_rev=1 revision=2 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\",\"lines\":[\"bank=Factory\",\"name=Warm Pad\"]}","type":"text"}],"structuredContent":{"fields":"slot=5 bank_rev=1 revision=2 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1","lines":["bank=Factory","name=Warm Pad"]}}}
```

Loading an empty slot is the daemon's refusal, and it passes through:

```json
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"patch_load","arguments":{"slot":100}}}
```

```json
{"id":11,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"unknown_parameter\",\"message\":\"slot is empty\"}","type":"text"}],"isError":true,"structuredContent":{"code":"unknown_parameter","message":"slot is empty"}}}
```

A call that fails the server's own checks never reaches the daemon. The path ends
in a space, which the daemon would have trimmed, so it would have written
`bank.json` instead of `bank.json `:

```json
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"bank_write","arguments":{"path":"bank.json "}}}
```

```json
{"id":12,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"invalid_arguments\",\"message\":\"path must not start or end with whitespace\"}","type":"text"}],"isError":true,"structuredContent":{"code":"invalid_arguments","message":"path must not start or end with whitespace"}}}
```

Play a note and release it. Status 144 is note on and 128 is note off, both on
channel 1, for note 60. Both are accepted, and nothing is heard at volume 0:

```json
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"midi_send","arguments":{"status":144,"data1":60,"data2":100}}}
```

```json
{"id":13,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"midi_send","arguments":{"status":128,"data1":60,"data2":0}}}
```

```json
{"id":14,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"","lines":[]}}}
```

Open the archive and walk down to a patch. The path is relative, so the daemon
resolves it against its own working directory. `archive_load` sends the patch to
the audio thread, and `archive_close` forgets the archive and its path:

```json
{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"archive_open","arguments":{"path":"corpus.zip"}}}
```

```json
{"id":15,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"banks=1 archive_rev=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"banks=1 archive_rev=1","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"archive_banks","arguments":{}}}
```

```json
{"id":16,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"total=1 archive_rev=1\",\"lines\":[\"bank=0 name=bankA.zip\"]}","type":"text"}],"structuredContent":{"fields":"total=1 archive_rev=1","lines":["bank=0 name=bankA.zip"]}}}
```

```json
{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"archive_bank","arguments":{"index":0}}}
```

```json
{"id":17,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"patches=2 bank=0 archive_rev=2\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"patches=2 bank=0 archive_rev=2","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"archive_patches","arguments":{}}}
```

```json
{"id":18,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"total=2 bank=0 archive_rev=2\",\"lines\":[\"patch=0 name=Test Patch One\",\"patch=1 name=Test Patch Two\"]}","type":"text"}],"structuredContent":{"fields":"total=2 bank=0 archive_rev=2","lines":["patch=0 name=Test Patch One","patch=1 name=Test Patch Two"]}}}
```

```json
{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"archive_load","arguments":{"index":1}}}
```

```json
{"id":19,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"count=3 revision=2 bank=0 patch=1\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"count=3 revision=2 bank=0 patch=1","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"archive_close","arguments":{}}}
```

```json
{"id":20,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"archive_rev=3\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"archive_rev=3","lines":[]}}}
```

A name that is not on the list of tools, even the daemon's own spelling of one,
is a protocol error and nothing is sent:

```json
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"daemon.status","arguments":{}}}
```

```json
{"error":{"code":-32602,"message":"Unknown tool"},"id":21,"jsonrpc":"2.0"}
```

Stop the daemon. It answers, then exits. The next call finds nobody listening:

```json
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"daemon_shutdown","arguments":{}}}
```

```json
{"id":22,"jsonrpc":"2.0","result":{"content":[{"text":"{\"fields\":\"\",\"lines\":[]}","type":"text"}],"structuredContent":{"fields":"","lines":[]}}}
```

```json
{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"daemon_status","arguments":{}}}
```

```json
{"id":23,"jsonrpc":"2.0","result":{"content":[{"text":"{\"code\":\"daemon_unavailable\",\"message\":\"no daemon listening on the local socket\"}","type":"text"}],"isError":true,"structuredContent":{"code":"daemon_unavailable","message":"no daemon listening on the local socket"}}}
```

### Safety notes for MCP clients

- The server runs no shell, opens no file and builds no command line from your
  text. Every tool is one fixed daemon command, the tables above are the whole
  list, and a call with another name is refused. Tokens, paths and names are
  checked so that a request stays one line of the control protocol and is read
  the way it was written.
- Most tools change something. Through the daemon they can change parameters,
  replace the sound by loading a patch, a bank slot or an archive entry,
  overwrite a bank slot, replace the browsable bank, send MIDI, set the master
  volume and stop the daemon.
- The daemon reads and writes the paths you give, with your permissions.
  `patch_load_file`, `bank_load_file`, `archive_open` and `archive_adopt` read a
  file. `bank_write` writes the bank to any path the daemon can write, and
  replaces a file that is already there. `patch_save` and `bank_keep` write the
  daemon's bank file: `bank.json` in its configuration directory, or the bank
  file named on its command line. `archive_open`, `archive_adopt` and
  `archive_close` write or delete the daemon's own files in its configuration
  directory. Relative paths resolve against the daemon's working directory,
  which your client may not share, so give absolute paths.
- The annotations tell a client which tools are destructive. A client can use
  them to ask you first. A client that does not ask can still call every tool.
- Parameter edits, patch and archive loads and `midi_send` change what you hear
  at once. Call `volume` with a low value before you test. A note on keeps
  sounding until its note off arrives. Nothing releases held notes but a note
  off or stopping the daemon.
- Anyone who can start the server controls the daemon as your user, including
  its shutdown. There is no login. Register it only with clients you trust.

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
`current_revision=<n>`, and nothing was applied. Call `inspect_synth` or
`state_snapshot` again and send the batch with the new revision.

**MCP `invalid_arguments`.** The server refused the call before it sent
anything, and the message names the argument. The usual causes are an argument
the tool does not declare, often a misspelt name, an integer written as a string
or with a fraction, and a path or name with a space at either end. The daemon
would have trimmed that space and used another path. The messages are listed under
[Arguments and checks](#arguments-and-checks).

**MCP `daemon_unavailable` right after `daemon_shutdown`.** That is expected.
`daemon_shutdown` stops the daemon, and every tool answers `daemon_unavailable`
until you start one again. The server needs no restart.

**A path tool cannot find a file that exists.** The daemon opens the path, not
the MCP server, and it resolves a relative path against its own working
directory. A daemon that the TUI started keeps the directory the TUI was
started in. Use an absolute path.

**MCP `daemon_timeout` with `the request was sent and the change may have been
applied`.** Every request has a deadline of 500 ms, and a slow command, such as
`archive_open` on a large archive, can pass it. The request was already sent and
the server does not repeat it. Read the state, for example with `archive_current`,
before you call again.

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
- The MCP server is a stdio process with no network listener. It has one typed
  tool for each command of the control protocol and two read-only resources,
  and no shell, file, command or network tool of its own. Through the daemon it
  can still change parameters, load and overwrite patches and bank slots, write
  the bank to a path of your choosing, send MIDI, set the master volume and stop
  the daemon. Anyone who can start it controls the daemon as your user, so only
  add it to clients you trust. See
  [Safety notes for MCP clients](#safety-notes-for-mcp-clients).
- Parameter edits, patch and archive loads and injected MIDI messages, whether
  they come from a front-end or from MCP, change the sound immediately. Turn
  your monitors down before testing, since a note-on with a high velocity or an
  extreme parameter can be loud. The master volume is the `volume` command, and
  the `volume` MCP tool sets it.
- Notes can hang. There is no all-notes-off. Send a note off, or run
  `./build/quesynth --stop`.
- The daemon reads the files you name (patches, banks, archives) with your
  permissions, and writes only `archive.path`, `bank.json` or the `--bank` file
  you start it with, and, through the TUI, `config.conf`, `theme.conf`, and the
  bank file you choose to write.
- Quesynth is experimental software. Do not rely on it unattended in a session
  you cannot repeat.
