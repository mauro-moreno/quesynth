// The audio thread: the WebAssembly engine, rendering into the browser's output.
//
// An AudioWorklet rather than the older ScriptProcessorNode, because a synth on
// the main thread stutters whenever the interface repaints -- and this interface
// repaints on every knob drag. Here the engine runs on the audio thread and the
// panel cannot interrupt it.
//
// The module arrives as bytes through `processorOptions`. It cannot be fetched
// from in here: `fetch` does not exist in an AudioWorkletGlobalScope, which is the
// one real constraint this file is shaped by.

class SynthProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ready = false;
    this.pending = [];
    this.port.onmessage = (e) => this.onMessage(e.data);

    const bytes = options.processorOptions && options.processorOptions.wasm;
    // How many instruments this page wants behind the one output. One for the
    // synth panel; sixteen for the pad, whose sixteen cells are sixteen whole
    // engines summed here rather than one engine switched between sounds.
    const slots = (options.processorOptions && options.processorOptions.slots) || 1;
    if (bytes) this.boot(bytes, options.processorOptions.blockSize || 128, slots);
  }

  boot(bytes, blockSize, slots) {
    // Everything the module asks the host for, and it is a short list: two
    // runtime hooks and the five libm functions the browser does not provide.
    // Odin's own JavaScript runtime is not needed for a module this small, and
    // could not be loaded in here anyway.
    //
    // The list is short but it is not guessable -- `ln` is imported and `log` is
    // not, and missing one is a LinkError with the whole engine dead. Check it
    // against the module rather than against this comment:
    //
    //   node -e "const b=require('fs').readFileSync('hosts/wasm/synth.wasm');
    //     WebAssembly.compile(b).then(m=>console.log(
    //       WebAssembly.Module.imports(m).map(i=>i.name).join(' ')))"
    const env = {
      // Anything the engine printed. Nothing does on the audio path; if that ever
      // changes, this is where it would show up rather than being lost.
      write: (fd, ptr, len) => {},
      rand_bytes: (ptr, len) => {
        const view = new Uint8Array(this.memory.buffer, ptr, len);
        for (let i = 0; i < len; i++) view[i] = (Math.random() * 256) | 0;
      },
      sin: Math.sin,
      cos: Math.cos,
      pow: Math.pow,
      ln: Math.log,
      exp: Math.exp,
    };

    WebAssembly.instantiate(bytes, { odin_env: env }).then((result) => {
      const inst = result.instance;
      this.wasm = inst.exports;
      this.memory = this.wasm.memory;
      // Runs Odin's global initialisers. Nothing works before it.
      this.wasm._start();

      this.blockSize = blockSize;
      const ptr = this.wasm.synth_init(sampleRate, blockSize, slots);
      // Two planes, left then right, in the module's own memory. Rebuilt whenever
      // the memory grows, since growing detaches every view onto it.
      this.audioPtr = ptr;
      this.refreshViews();

      this.ready = true;
      this.pending.forEach((m) => this.apply(m));
      this.pending.length = 0;
      this.port.postMessage({ type: "ready", sampleRate, slots: this.wasm.synth_slot_count() });
    }).catch((err) => {
      this.port.postMessage({ type: "error", message: String(err) });
    });
  }

  refreshViews() {
    const n = this.blockSize;
    this.left = new Float32Array(this.memory.buffer, this.audioPtr, n);
    this.right = new Float32Array(this.memory.buffer, this.audioPtr + n * 4, n);
  }

  onMessage(m) {
    if (!this.ready) {
      this.pending.push(m);
      return;
    }
    this.apply(m);
  }

  apply(m) {
    const w = this.wasm;
    // Which instrument the message is for. Absent means the first, so the synth
    // panel needs to know nothing about slots.
    const slot = m.slot | 0;
    switch (m.type) {
      case "note":      m.on ? w.synth_note_on(slot, m.note, m.velocity) : w.synth_note_off(slot, m.note); break;
      case "trigger":   w.synth_trigger(slot, m.note, m.velocity); break;
      case "set":       w.synth_set_param(slot, m.index, m.value); break;
      case "mix":       w.synth_set_mix(slot, m.volume, m.pan); break;
      case "cc":        w.synth_control_change(slot, m.cc, m.value); break;
      case "bend":      w.synth_pitch_bend(slot, m.value); break;
      case "tempo":     w.synth_set_tempo(slot, m.bpm); break;
      case "panic":     w.synth_all_notes_off(Number.isInteger(m.slot) ? slot : -1); break;
      case "state": {
        // A whole patch, written into the module's own buffer and applied once.
        // Setting each parameter in turn would rebind the instrument ninety-nine
        // times on the way to one sound.
        const buf = new Int32Array(this.memory.buffer, w.synth_patch_buffer(), m.values.length);
        buf.set(m.values);
        w.synth_apply_patch(slot);
        break;
      }
    }
  }

  process(inputs, outputs) {
    const out = outputs[0];
    if (!this.ready || !out || out.length === 0) return true;

    // Setting a parameter can allocate, and allocating can grow the module's
    // memory, which detaches every view onto its buffer. Cheap to check and
    // silent to get wrong -- the views would just read zeroes for ever.
    if (this.left.buffer !== this.memory.buffer) this.refreshViews();

    this.wasm.synth_render();
    out[0].set(this.left);
    if (out.length > 1) out[1].set(this.right);
    return true;
  }
}

registerProcessor("synth-processor", SynthProcessor);
