# The browser host

The engine compiled to WebAssembly, plus the page-side glue that lets `ui/` drive
it. A host in exactly the sense `hosts/vst3` is one: it owns an engine and speaks
the protocol in `ui/bridge.js`.

```
odin build hosts/wasm -target:js_wasm32 -o:speed -out:hosts/wasm/synth.wasm
node hosts/wasm/serve.js                                  # then open :8177
```

| file | |
|---|---|
| `main.odin` | the engine's WebAssembly entry points |
| `host.js` | starts the engine and answers the panel as a host would |
| `worklet.js` | the AudioWorkletProcessor, and the imports the module needs |
| `serve.js` | a static server, development only |
| `check-imports.js` | verifies `worklet.js` supplies every import the module asks for |
| `check-slots.js` | verifies a message reaches the instrument it names and no other |
| `synth.wasm` | **build artifact**, not committed |

It serves two pages, because there are two instruments over one engine:
`/index.html` is the synth and `/pad.html` is the pad. See `ui/README.md`.

`serve.js` lays this directory over `ui/`, because that is what the web build
*is*: the panel plus this host's own glue. Every host assembles the same way —
`tools/install-vst3.ps1` copies `ui/` into a bundle beside the plugin binary —
and serving it any other way would mean developing against a layout nothing
ships.

The panel loads `host.js` behind an `onerror` guard and names no host at all, so
a native build simply omits the file and provides the bridge from its own side.

## It really plays

`hosts/wasm` compiles **the same `src/engine`** the plugin and the desktop build
run — not a reimplementation, not a subset — so the page is the instrument rather
than a picture of it. That is the point: the interface can be exercised on any
machine with a browser, including the phone it is designed for, without anybody
installing a plugin host. It is what `.github/workflows/pages.yml` publishes.

The engine runs in an **AudioWorklet**, not on the main thread. A synth on the main
thread stutters whenever the interface repaints, and this interface repaints on
every knob drag.

Three things about that boundary are worth knowing before changing it:

- **The module cannot fetch itself.** `fetch` does not exist in an
  AudioWorkletGlobalScope, so `host.js` fetches the bytes and hands them to the
  processor through `processorOptions`.
- **Odin's JavaScript runtime is not shipped.** The module imports seven
  functions — `write`, `rand_bytes` and five from libm — which `worklet.js`
  supplies in a dozen lines. The list is short but not guessable: `ln` is imported
  and `log` is not, and a missing one is a LinkError that kills the engine while
  leaving the panel working perfectly. `node hosts/wasm/check-imports.js` verifies
  it, and CI runs it on every deploy.
- **Growing the memory detaches every view onto it.** Setting a parameter can
  allocate, so the processor re-makes its buffer views when it sees the buffer has
  changed. Getting this wrong is silent: the views read zeroes for ever.

Audio needs a gesture before any browser will start it, so the engine boots on the
first touch and the strip says `tap to start` until it is running, then the sample
rate.

When a native host *is* present, `host.js` stands down at its first line rather
than booting a second engine underneath the real one — the same check
`ui/bridge.js` makes, in the same order, because it is the same question.

## Publishing

`.github/workflows/pages.yml` builds the module, checks the worklet against it,
checks the generated parameter table is current, gathers `ui/` and this directory
into one folder and publishes that to GitHub Pages. Nothing is bundled or
transformed — the panel ships exactly as it is developed, and the relative paths
work under a project subpath. Pages is HTTPS, which AudioWorklet requires.

`hosts/wasm/synth.wasm` is a build artifact and is not committed; CI produces it.

## More than one instrument in a page

`synth_init` takes how many it should make:

```
synth_init(sample_rate, block, slots) -> [^]f32
```

One for the synth panel. Sixteen for the pad, which is a four by four grid with a
whole Quesynth behind every cell -- the point of it being that a drum sound *is* a
synth patch, so a pad is not a sampler with a grid drawn on it but sixteen of this
instrument laid out in a square. `host.js` reads `window.QUESYNTH_SLOTS`, which
`ui/pad-boot.js` sets before it loads; a page that says nothing gets one.

Every entry point that addresses an instrument takes the slot first --
`synth_note_on(slot, note, velocity)`, `synth_set_param(slot, index, stored)` --
and the worklet fills it in from `m.slot | 0`, so a message that does not name one
goes to the first. That default is what lets the synth page know nothing about any
of this.

Rack slots initialize on first use, so opening the 4×4 page does not allocate
sixteen complete effect buffers up front. Initialization happens on a control
message or hit, never inside `synth_render`.

`synth_render` sums them. A slot with no voices sounding is skipped entirely once
its tail has run out, which is what makes sixteen affordable: a grid is mostly
idle, and an idle slot that is skipped costs nothing rather than costing a whole
effect chain. The tail is there because the delay and the chorus outlive the note
that fed them, and cutting a slot the instant its last voice ended would chop the
end off every hit.

`node hosts/wasm/check-slots.js` is the guard on the arrangement. Getting it wrong
is quiet -- drop the slot argument anywhere along the chain and every pad plays
pad one, which sounds like a synth working perfectly -- so the check strikes one
cell and asks the other fifteen whether they made a sound.

The rack mixer is host state rather than patch state: `synth_set_mix` applies
per-slot volume and pan while summing. `synth_trigger` runs a patch's attack and
decay and releases it at sustain without waiting for MIDI Note Off. Slot-scoped
all-notes-off supplies choke and mute. The slot check covers isolation, mix
silence, and one-shot voice cleanup as well as ordinary note routing.
