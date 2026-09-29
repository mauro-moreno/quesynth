# Standalone daemon architecture — implementation plan

The Linux standalone build is **replaced** by a daemon-centric architecture. The
audio daemon becomes the standalone core; the interactive surface (a terminal
UI now, a browser GUI later) is just a front-end that talks to the daemon over a
versioned control protocol. There is one binary, `quesynth`, with modes.

This plan is written against the code that exists today, so the file names and
reuse points below are the real ones.

## Decided shape

Confirmed with the maintainer:

- **Daemon persists; front-ends attach and detach.** `quesynth` auto-starts a
  detached daemon if none is running, then attaches a front-end. Quitting the
  front-end leaves audio playing; an explicit stop command ends the daemon.
  (Honors handoff Invariant 3 / §47, headless Pi boot, swappable TUI↔browser.)
- **One binary, mode flags** (not `quesynthd` + `quesynth`):
  - `quesynth` — attach-or-spawn the daemon, run the **TUI** front-end. Default.
  - `quesynth --daemon` — run the **headless daemon** only (Pi/servers, systemd).
  - `quesynth --browser` — attach-or-spawn the daemon, serve the **browser GUI**
    front-end (later slice; the eventual `quesynth --browser`).
  - `quesynth --stop` — ask the running daemon to shut down.
  - `quesynth --selftest <patch.sy1> <out.wav>` — offline render, opens no
    device, starts no daemon. **Kept unchanged**; CI depends on it.
- **The direct-to-engine live path is removed.** Today's default
  (`hosts/standalone/live.odin`, raw MIDI play with no UI) is deleted. The
  default becomes daemon + TUI over the protocol. Only `--selftest` keeps a
  no-daemon engine path.

So the process picture is:

```
  quesynth              quesynth --browser        (future clients)
  (TUI front-end)       (browser front-end)       quesynth-mcp, ...
        \                     |                        /
         \                    |                       /
          `------ Quesynth Control Protocol (Unix socket) ------'
                              |
                    quesynth --daemon   ← the persistent core (this binary,
                              |            detached; auto-spawned or systemd)
                        control server
                              |
                     command ring / snapshot
                              |
                        AUDIO ENGINE (src/engine, unchanged)
```

`quesynth` with no daemon running spawns `quesynth --daemon` detached
(double-fork / `setsid`, re-exec of the same binary), waits for the socket, then
attaches. If a daemon is already at the socket, it just attaches. Front-end exit
never signals the daemon.

## What already exists (and must be reused, not rebuilt)

- **The engine is already a clean layer-1 core.** `src/engine/engine.odin`
  allocates only in `engine_init`; `engine_process` reaches no allocator, lock,
  or syscall. The daemon is a new **layer-2 host** in `docs/architecture.md`
  terms — it replaces the standalone adapter rather than adding a layer.
- **There is no scalar `engine_set_parameter`.** Engine state is a
  `patch.Patch` — 99 integer-valued VST parameters, indices `0..98`. A live edit
  is already done realtime-safely by `engine_control_change` /
  `engine_refresh_controllers` (`src/engine/engine.odin:266`, `:290`): they
  rewrite the *stored* patch value and call `bind_patch`, which allocates
  nothing and keeps sounding voices intact. **This is the mechanism the protocol
  drives** (handoff §24). We do not invent a second one.
- **The measured parameter table is the authoritative metadata source.**
  `patch.PARAMETERS[99]` (`src/patch/params.odin:7396`) plus `parameter_states`,
  `parameter_position`, `parameter_stored_at_position`, `parameter_norm`
  (`src/patch/value.odin`) already encode every range, step count, default and
  display string, copied verbatim from the reference. The registry is a
  **naming + semantic overlay** over this table (Invariant 7); it never restates
  a range.
- **A realtime-safe MPMC control queue already exists.**
  `hosts/standalone/ring.odin` is a Vyukov bounded MPMC ring carrying `u32` MIDI
  words to the audio thread, lock-free and drop-counted. The control→audio path
  reuses this exact structure for parameter commands.
- **The daemon is today's live shell plus a socket.**
  `hosts/standalone/live.odin` already opens ALSA audio + ALSA MIDI, drains a
  queue in the audio callback, and tears down cleanly on Ctrl-C via
  `install_shutdown_handler`. `Audio_Backend` / `Midi_Input`
  (`hosts/standalone/backend.odin`) are proc-pointer interfaces, ALSA-backed on
  Linux. `--daemon` keeps this render loop verbatim and adds a control server
  thread; the interactive banner/play code becomes a client instead.

### Mapping the handoff's IDs onto the real engine

IDs like `filter.cutoff`, `osc1.waveform` map to VST indices: `filter.cutoff →
19` (`*filter freq`), `filter.resonance → 20`, `osc1.waveform → 0` (`osc1
shape`), `master.volume → 29` (`amp gain`). A **descriptor is `{ id, group,
index, semantics }`** where `index` is the VST index and the range/steps/format
come from `patch` at that index. Setting `filter.cutoff` = resolve id → index 19
→ write a stored integer into `patch.values[19]` → rebind, exactly what
`engine_control_change` already does per CC.

## Placement

The repo uses `hosts/<name>/` for layer-2 executables, `src/<name>/` for shared
layers, `tests/<name>/`. The single binary stays at `hosts/standalone` (its
build target `build/quesynth` is unchanged), reorganized into daemon core +
front-ends + shared protocol/registry:

```
src/control/      protocol: framing, codec, request/response, commands,
                  versions, errors. Pure. No engine import. Front-end-importable.
src/registry/     descriptor table (id → VST index + semantics), normalize/
                  format/validate over src/patch. No engine import. Importable.

hosts/standalone/                 the one binary, `build/quesynth`
  main.odin                       arg parse → daemon | tui | browser | stop |
                                  selftest
  selftest.odin                   UNCHANGED offline render (no device, no daemon)
  backend.odin, ring.odin,        UNCHANGED audio/MIDI shell, now shared by the
  platform_*.odin, *_alsa.odin,     daemon mode
  wav.odin
  daemon/
    daemon.odin                   Daemon struct, Daemon_State, --daemon entry
    runtime.odin                  startup/shutdown ordering
    control_server.odin           accept loop, per-connection framing (own thread)
    command_handler.odin          validate via registry → command ring / snapshot
    state_snapshot.odin           audio→control published state (seqlock)
    param_ring.odin               Vyukov ring specialised to Param_Command
    param_bridge.odin             id → index → engine_set_stored
    launch.odin                   spawn-detached-or-attach, socket discovery, stop
  tui/
    tui.odin                      --daemon-less front-end entry; event loop
    client.odin                   protocol client (imports src/control only)
    terminal.odin, input.odin, render.odin, screen.odin, widgets/
  browser/                        later: serves ui/ as a protocol client

tests/control/    framing, codec, versioning, error-serialization.
tests/registry/   id uniqueness, range/default/enum, normalize round-trips.
tests/standalone/ daemon lifecycle + protocol integration + launch/attach/stop.
```

Boundary enforced by imports: **`src/control` and `src/registry` never import
`src/engine`**; **`hosts/standalone/tui` and `.../browser` import `src/control`
and `src/registry` only, never `src/engine` or the `daemon/` package** (Invariants
1, 2, 4). The front-end and the daemon live in one repo directory but are wired
only through the socket — a front-end reaching daemon or engine state is a review
failure.

---

## Slice 1 — `--daemon`: headless persistent daemon (no protocol yet)

**Objective.** `quesynth --daemon` boots the engine, opens ALSA audio + MIDI,
plays, runs a persistent event loop, and shuts down deterministically on SIGINT
and (later) on `--stop`. The interactive default is rewired to *launch* this and
attach — but with no front-end yet, so `quesynth` in this slice just runs the
daemon in the foreground as a stand-in. (handoff §41 Slice 1.)

**Affected.**
- `hosts/standalone/main.odin` — new mode dispatch: `--daemon`, `--selftest`
  (unchanged), `--help`; default temporarily aliases `--daemon` foreground.
- `hosts/standalone/daemon/daemon.odin` — `Daemon` (owns `engine.Engine`, audio
  backend, MIDI input, queues) and `Daemon_State`
  (`Starting/Ready/Running/Stopping/Error`, handoff §5) as an atomic.
- `hosts/standalone/daemon/runtime.odin` — startup/shutdown ordering (handoff §4).
- Reuses `live_render`, `install_shutdown_handler`, `audio_backend_create`,
  `midi_input_create`. The old `run_live` interactive banner logic is retired
  here (it returns in Slice 4 as the TUI).

**Public interfaces introduced.** CLI modes; startup banner (handoff §47);
`Daemon_State` read atomically. Socket comes in Slice 3.

**Realtime implications.** Identical to `hosts/standalone` today: one audio
thread, MIDI producer threads, lock-free queue. No new audio-path code.

**Tests (`tests/standalone/`).** `--selftest` still renders bit-identically
(reuses the existing offline path, CI needs no device). A lifecycle test drives
the daemon startup/teardown through an injectable shutdown hook headlessly and
asserts the ordered teardown (stop stream → close MIDI → destroy engine).

**Acceptance (handoff §41).** Runs headless; audio operates; SIGINT produces
clean shutdown; `--selftest` unchanged.

**Dependencies.** None.

---

## Slice 2 — Minimal parameter registry (3 parameters)

**Objective.** A registry naming a small set of existing parameters, with
descriptor lookup, validation, and a get/set bridge to the engine's stored patch
— no engine internals exposed. (handoff §41 Slice 2.)

**Affected.**
- `src/registry/registry.odin` — `Registry`, id→descriptor lookup, `list`.
- `src/registry/parameter.odin` — `Parameter_Descriptor` (handoff §17), built by
  wrapping a VST index: `{ id, label, group, kind, unit, scale, index }`;
  `min/max/default/enum` **derived from `src/patch`** at that index, not stored
  twice.
- `src/registry/validation.odin` — `normalize/denormalize/format/validate`
  (handoff §19–20) delegating to `parameter_position`,
  `parameter_stored_at_position`, `parameter_norm`, and the `display` strings.
- `hosts/standalone/daemon/param_bridge.odin` — `registry_get(e)`,
  `registry_set(e, id, value)`: id → index → stored integer → engine. From
  Slice 3 the set enqueues onto the command ring; in this slice it can call the
  new engine entry synchronously for unit tests off the audio thread.
- `src/engine/engine.odin` — new `engine_set_stored(e, index, stored)`: writes
  `e.patch.values[index]` and calls the existing `engine_refresh_controllers`
  rebind. Realtime-safe by construction (mirrors `engine_control_change`).

Initial IDs: `master.volume` (29), `filter.cutoff` (19), `filter.resonance`
(20). Do not migrate the rest yet.

**Public interfaces introduced.** `Parameter_Descriptor`, `Parameter_Kind`,
`Parameter_Unit`, `Parameter_Scale`; `registry_init`, `registry_describe`,
`registry_list`, `registry_validate`, `registry_format`; `engine_set_stored`.

**Realtime implications.** `engine_set_stored` runs the same rebind an incoming
MIDI CC already runs on the audio thread — allocation-free, voice-safe.
Descriptor/validation code is non-realtime; it yields a plain `stored: int` the
RT side consumes. Validation never runs in the audio callback.

**Tests (`tests/registry/`).** Unique IDs; every id resolves to a live VST
index; `validate` rejects out-of-range/unknown; `normalize`↔`denormalize`
round-trips against `parameter_norm`; `format` matches the measured `display`
for sampled states; enum value lists match `parameter_states`. Checked against
the measured `patch` table (external to the registry), per CONTRIBUTING's
"check against something external" rule.

**Acceptance (handoff §41).** Stable IDs; enumerable metadata; invalid values
rejected.

**Dependencies.** Slice 1.

---

## Slice 3 — Control protocol over a Unix socket

**Objective.** A versioned, framed request/response protocol carrying
`daemon.status`, `parameter.list`, `parameter.get`, `parameter.set` over a Unix
socket, with the set path crossing the realtime boundary through a command ring.
Adds socket lifecycle so `--stop` and attach/spawn become possible. (handoff §41
Slice 3.)

**Affected.**
- `src/control/version.odin` — `PROTOCOL_VERSION :: 1` (`QCP/1`), independent of
  app version (handoff §35, Invariant 10).
- `src/control/codec.odin` — `[len:u32-LE][payload]` framing (handoff §9).
  Evaluate reusing `src/patch/json.odin` before writing a codec (handoff §10); if
  thin enough use it, else a compact tagged key/value. Command semantics stay
  codec-independent.
- `src/control/command.odin`, `response.odin` — `Request{version,id,command,
  payload}`, `Response{version,id,status,payload,error}` (handoff §11);
  `Error_Code` enum (handoff §34).
- `hosts/standalone/daemon/control_server.odin` — accept loop on its own thread;
  per-connection framing/parse/dispatch. Touches the engine only via the command
  ring and the published snapshot.
- `hosts/standalone/daemon/command_handler.odin` — validate via registry; for
  `parameter.set` enqueue `Param_Command{index:u16, stored:i32, txn_id}`; for
  get/list/status read the published snapshot and atomic `Daemon_State`/`revision`.
- `hosts/standalone/daemon/state_snapshot.odin` — the audio thread publishes
  `{ values:[99]i32, revision:u64 }` via a seqlock/double buffer; the control
  thread reads it without locking the audio thread (handoff §25). `revision` is
  an atomic `u64` bumped by the audio thread per applied mutation (handoff §14).
- `hosts/standalone/daemon/param_ring.odin` — Vyukov ring (from `ring.odin`)
  specialised to `Param_Command`, drained in `live_render` beside the MIDI queue.
- `hosts/standalone/daemon/launch.odin` — socket path
  `$XDG_RUNTIME_DIR/quesynth/quesynth.sock`, fallback `/tmp/quesynth-$UID.sock`
  (handoff §6), user-only perms (handoff §36), removed on shutdown; `--stop`
  sends a `daemon.shutdown` request (or connects and signals) to a running
  daemon.

**Public interfaces introduced.** The wire protocol (framing, `Request`/
`Response`, four commands, `Error_Code`, version handshake in `daemon.status`,
handoff §35); `Param_Command` + ring API; the socket contract; `--stop`.

**Realtime implications (the core of the design).**
- Socket I/O, parsing, validation, formatting run **only** on the control thread
  (handoff §23). The audio callback does none of it.
- `parameter.set` = control thread validates → pushes `Param_Command` on the
  lock-free ring → returns the applied (or accepted) `revision`. The audio thread
  drains at block top (like MIDI), applies via `engine_set_stored`, bumps
  `revision`, republishes the snapshot. Audio never waits on control (Invariant
  6); control never blocks audio (Invariant 5).
- Ring overflow is drop-counted like the MIDI queue; an overflowed set returns
  `transaction_failed`/`daemon_not_ready`, never blocks.

**Tests.** `tests/control/`: framing (partial reads, multiple messages per read,
oversized/short), unsupported version, unknown command, bad payload, request-id
echo, error serialization (handoff §39) — bytes fed to the codec, not struct
round-trips (CONTRIBUTING "the trap"). `tests/standalone/`: spawn daemon on a
temp socket, raw test client `parameter.set filter.cutoff`, `parameter.get`
reflects it and `revision` incremented; invalid command does not crash; audio
keeps running (assert via a metrics field); `--stop` ends the daemon and removes
the socket.

**Acceptance (handoff §41).** Test client connects; a parameter changes
externally; audio keeps running; invalid command does not crash.

**Dependencies.** Slices 1, 2.

---

## Slice 4 — Default `quesynth`: TUI front-end + attach/spawn (**first checkpoint**)

**Objective.** `quesynth` with no args spawns-or-attaches the daemon and runs the
TUI, giving the smallest full path from a keystroke to an audible engine change
over the public protocol only. Quitting the TUI leaves the daemon (and audio)
running. (handoff §41 Slice 4, §47; the decided default.)

**Affected.**
- `hosts/standalone/main.odin` — default mode: call `launch` (attach if socket
  live, else spawn `quesynth --daemon` detached via double-fork/`setsid`, wait
  for the socket), then run the TUI.
- `hosts/standalone/daemon/launch.odin` — the attach-or-spawn + readiness-wait
  logic; guards against two racing spawns (socket create is the lock).
- `hosts/standalone/tui/tui.odin` — event loop, quit (`q`) closes the client
  socket only; the daemon is untouched.
- `hosts/standalone/tui/client.odin` — protocol client: frame, send `Request`,
  match `Response` by id. **Imports `src/control` only.**
- `hosts/standalone/tui/terminal.odin` — raw mode, alternate screen buffer,
  restore on exit (handoff §30), dependency-free ANSI, termios via
  `core:sys/linux`.
- `hosts/standalone/tui/input.odin`, `render.odin` — arrows/Enter/`q`; draw
  daemon status + the three parameters + values.

Flow: `connect → daemon.status → parameter.list → cache descriptors →
parameter.get ×3 → render`; `←/→` sends `parameter.set`, re-renders from the
response (handoff §32).

**Public interfaces introduced.** None on the protocol; this consumes Slices
2–3 and proves a generic client drives the synth from metadata alone (Invariant
4). Plus the front-end launch UX (auto-spawn/attach).

**Realtime implications.** None in the front-end path — the TUI sends control-
rate messages; the daemon it attaches to is a separate process (handoff §46).

**Tests.** `tests/standalone/`: client-logic units against a stub server
(descriptor caching, response matching, reconnect state machine); an integration
test drives the real daemon through the client library with no TTY (connect →
list → get → set → observe, handoff §39); a launch test asserts `quesynth`
spawns a daemon when none runs, attaches when one does, and that **TUI exit
leaves the daemon alive** (poll the socket after the client quits).

**Acceptance (handoff §41, §47).** TUI never links engine control (import
audit); daemon survives TUI exit; moving `Filter → Cutoff` changes audio
immediately; `q` quits without stopping audio; relaunching reconstructs state
from the daemon.

**Dependencies.** Slices 1–3. **The milestone the plan front-loads toward** —
everything before it is the minimum to reach an audible round trip.

---

## Slice 5 — Full registry migration

**Objective.** Every user-controllable parameter gets a stable ID and group,
still with zero hardcoded ranges in any front-end. (handoff §41 Slice 5.)

**Affected.** `src/registry/` — a complete descriptor table over `0..98`,
grouped `oscillators, mixer, filter, amp, envelopes, lfo, arp, effects, global`.
Consider generating it from `patch.PARAMETERS` names + a hand-authored
id/group/semantics map (the `tools/genparams` precedent) so the two never drift.
Exclude config-not-patch items (`polyphony` 94, sample rate) from the patch
namespace (handoff §37); keep MIDI-routing controls (86–89, 50, 51)
non-settable, matching `controller_target_valid`.

**Public interfaces.** Larger `parameter.list`; unchanged command set.

**Realtime implications.** None new — every id resolves to the same
`engine_set_stored` path.

**Tests.** Extend `tests/registry/` to the full table: every non-excluded index
covered exactly once, groups complete, enum values match `parameter_states`,
round-trips over the whole table.

**Acceptance.** All intended parameters have stable IDs; front-ends discover them
with no hardcoded ranges.

**Dependencies.** Slice 2; best after Slice 4.

---

## Slice 6 — Rich TUI

**Objective.** A usable TUI: groups/tabs, enum selection, formatted values,
reset-to-default, status bar, engine metrics, help. (handoff §41 Slice 6, §31.)

**Affected.** `hosts/standalone/tui/screen.odin`, `tui/widgets/` (group tabs,
param rows with bar meters, status bar); `render.odin` (dirty-region redraw:
input immediate, meters ~10–20 Hz, no 60 FPS, handoff §30). Reset sends
`parameter.set` with the descriptor default. Metrics come from `daemon.info`
(handoff §27: sample rate, buffer, active/max voices, xruns if available,
backend, uptime, revision).

**Public interfaces introduced.** `daemon.info` / metrics payload (handoff §12,
§27) if not added earlier.

**Realtime implications.** Metrics (active voices via
`engine_active_voice_count`, xrun count) read from the published snapshot; the
audio thread only writes atomics. No new audio-path work.

**Tests.** Headless render-to-buffer: given a cached registry + snapshot, assert
the framebuffer contains expected labels/values; enum cycling; reset restores
default; meter throttling.

**Acceptance.** Metadata-driven UI renders all groups; enum and reset work
through the protocol only.

**Dependencies.** Slices 4, 5.

---

## Slice 7 — Transactions and snapshot

**Objective.** `parameter.set_many` (atomic batch), `state.snapshot`, and the
revision contract. (handoff §41 Slice 7, §13, §14, §26.)

**Affected.** `src/control/` — `parameter.set_many`, `state.snapshot`.
`command_handler.odin` — validate **all** members before enqueuing any (reject
the whole transaction on any failure, handoff §13); enqueue as one
`Param_Transaction` (contiguous run + commit marker) so the audio thread applies
the whole batch within one block and bumps `revision` **once** (handoff §14). The
ring gains transaction framing so a partial drain can never apply half a batch.
`state_snapshot.odin` — `state.snapshot` returns `{daemon, engine{sample_rate,
buffer_size}, patch{revision}, parameters{id→value}}` (handoff §26) in one
response, so a front-end initializes without N gets.

**Public interfaces introduced.** `parameter.set_many`, `state.snapshot`;
`revision` in every mutation response.

**Realtime implications.** The audio thread applies a transaction atomically
relative to a block: whole batch or none before rendering, so no client observes
a partial batch (handoff §13). One `revision` increment per committed
transaction. Still allocation-free — the batch is a bounded slice in the ring.

**Tests.** Valid batch succeeds; one invalid member rejects the whole batch with
no state change; revision increments exactly once per batch; snapshot revision
matches the last applied revision; TUI initializes from one snapshot.

**Acceptance.** Batch changes atomic; TUI initializes from one coherent
snapshot.

**Dependencies.** Slices 3, 4.

---

## Slice 8 — Reliability hardening

**Objective.** Make the surface robust enough to be the stable foundation for
future front-ends (browser GUI, MCP). (handoff §41 Slice 8, §33, §40.)

**Affected.** `hosts/standalone/tui/` — reconnect UI + optional auto-reconnect
(handoff §33); daemon keeps producing audio with no front-end (Invariant 3).
`control_server.odin` — robust per-connection lifecycle, survives client crash
mid-frame, multiple sequential clients, socket cleanup on abnormal exit;
`launch.odin` — stale-socket detection (connect-or-unlink) so a crashed daemon's
socket does not block a respawn. `src/control/` — fuzz/error corpus. Queue-
overflow surfaced as a metric + structured error; xrun/overflow counters exposed
(handoff §27, §40). Test-build realtime-safety instrumentation (allocator/lock
assertions around `engine_process`, handoff §40).

**Public interfaces.** Error categories finalized (handoff §34); metrics
extended.

**Realtime implications.** Instrumentation is test-build only; production audio
path unchanged. Overflow reported, never blocked.

**Tests.** Fuzzing rejects malformed frames without crashing; daemon survives
client crash; socket removed after abnormal exit; stale-socket respawn works;
overflow returns a structured error; the RT-assertion build catches an injected
audio-path allocation.

**Acceptance.** Architecture is MCP-ready: enumeration, semantic metadata,
snapshot, transactions, stable IDs, metrics, versioning, structured errors all
present and tested (handoff §43).

**Dependencies.** Slices 1–7.

---

## Slice 9 (deferred, planned) — `quesynth --browser`

**Objective.** The eventual browser GUI: `quesynth --browser` attaches-or-spawns
the daemon and serves the existing `ui/` panel as a **protocol client**, native
audio through the daemon rather than the current in-browser AudioWorklet engine.

**Sketch.** A small local HTTP server serves `ui/`; a WebSocket↔Unix-socket
bridge in `hosts/standalone/browser/` relays the control protocol to the browser
(handoff §7 lists WebSocket bridge as an intended transport reuse). `ui/bridge.js`
gains a native-daemon transport behind its existing `onerror`/host-guard so the
panel does not learn which host it is in (CONTRIBUTING layering rule). No engine
in the browser for this mode — the daemon owns audio. Out of scope until Slices
1–8 land; listed so the protocol/registry decisions keep it reachable (this is
why the browser is a front-end, not a special case).

**Dependencies.** Slices 3–8; `ui/` and its `bridge.js` seam.

---

## Critical path (front-loaded, per handoff §48)

```
Slice 1  quesynth --daemon (headless persistent audio)
   → Slice 2 registry (3 params + engine_set_stored)
      → Slice 3 protocol + socket + command ring + --stop
         → Slice 4 default quesynth = attach/spawn daemon + TUI
              ← FIRST CHECKPOINT: keystroke → audible change, TUI exit keeps audio
```

Slices 5–8 broaden and harden; Slice 9 (browser) is the deferred payoff of the
same protocol. The plan deliberately does **not** build the full registry,
transactions, rich TUI, or the browser bridge before the thin audible path in
Slice 4 exists.

## Invariants this plan enforces, and where

| Invariant | Enforced by |
|---|---|
| 1 engine independent | `src/control`,`src/registry` never import `src/engine`; daemon is a layer-2 host |
| 2 clients never mutate engine | set path is protocol → ring → `engine_set_stored` only |
| 3 daemon runs client-free | `--daemon` headless; detached spawn; front-end exit never signals it |
| 4 front-ends use the public protocol | `tui`/`browser` import `src/control`+`src/registry` only |
| 5 protocol off the RT thread | parse/validate/format on the control thread; Slice 3 |
| 6 audio never waits on control | lock-free command ring; audio drains, never blocks |
| 7 one metadata source | registry overlays `patch.PARAMETERS`; ranges never restated |
| 8 IDs are stable API | ids decoupled from labels; VST index is the binding |
| 9 atomic multi-set | Slice 7 transaction framing, one revision per commit |
| 10 protocol versioned independently | `PROTOCOL_VERSION` in `src/control/version.odin` |

## Open decisions to resolve during implementation

1. **Spawn mechanism:** re-exec `quesynth --daemon` via double-fork + `setsid`
   (clean detach, survives the launching terminal) vs. a `fork` before the TUI
   takes the terminal. Re-exec is preferred: one code path, and `--daemon` is
   the same thing systemd would run.
2. **Codec:** reuse `src/patch/json.odin` vs. a compact tagged format. Measure
   before choosing (handoff §10); keep command semantics codec-independent.
3. **Snapshot mechanism:** seqlock vs. double-buffer for publishing `[99]i32 +
   revision` from audio to control thread. Both RT-safe; pick the simpler test.
4. **`revision` on `parameter.set`:** return the applied revision (audio thread
   committed) vs. an accepted marker. Applied is cleaner for clients; it needs
   the control thread to observe the audio thread's atomic increment — a bounded
   spin on an atomic, never a lock, so it does not block audio.
5. **Stale-socket policy** (Slice 8): connect-then-unlink on a dead socket vs. a
   pidfile. Connect-or-unlink is simplest and needs no extra file.
6. **Config vs. patch namespace** (handoff §37): confirm `polyphony` (94),
   sample rate, buffer size live only in daemon config, never in `parameter.set`.

## Deferred (handoff §42)

MCP server, HTTP/WebSocket remote access beyond the local browser bridge,
network/remote control, auth, DAW integration, audio streaming through the
protocol. The plan guarantees only MCP *readiness* (§43 capability set, delivered
by Slice 8) and a local browser front-end (Slice 9).
