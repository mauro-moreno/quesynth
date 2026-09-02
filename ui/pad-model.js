// Pure state and routing rules for Quesynth Pad.
//
// Kept free of DOM and host details so the browser controller, a future native
// rack host, and Node tests all use the same definition of a kit. The wrapper is
// intentionally compatible with both classic <script> tags and CommonJS.
(function (root, factory) {
  "use strict";
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  if (root) root.QuesynthPadModel = api;
})(typeof window !== "undefined" ? window : globalThis, function () {
  "use strict";

  var FORMAT = "quesynth-kit";
  var VERSION = 1;
  var PAD_COUNT = 16;
  var FIRST_NOTE = 36;
  var NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  var GM = [
    [36, "Kick"], [37, "Rim"], [38, "Snare"], [39, "Clap"],
    [41, "Low Tom"], [42, "Closed Hat"], [45, "Mid Tom"], [46, "Open Hat"],
    [48, "High Tom"], [49, "Crash"], [51, "Ride"], [56, "Cowbell"],
    [54, "Tambourine"], [75, "Claves"], [69, "Cabasa"], [70, "Maracas"]
  ];

  function clamp(value, low, high) {
    value = Number(value);
    if (!isFinite(value)) value = low;
    return Math.max(low, Math.min(high, value));
  }

  function integer(value, fallback, low, high) {
    value = Number(value);
    if (!isFinite(value)) value = fallback;
    return Math.max(low, Math.min(high, Math.round(value)));
  }

  function noteName(note) {
    note = integer(note, 60, 0, 127);
    return NOTE_NAMES[note % 12] + (Math.floor(note / 12) - 1);
  }

  function defaultValues(parameters) {
    var values = [];
    (parameters || []).forEach(function (parameter) {
      values[parameter.i] = parameter.def;
    });
    return values;
  }

  function normalizeValues(values, parameters) {
    var out = defaultValues(parameters);
    if (!Array.isArray(values)) return out;
    values.forEach(function (value, index) {
      if (typeof value === "number" && isFinite(value)) out[index] = Math.round(value);
    });
    return out;
  }

  function createPad(index, parameters) {
    return {
      id: "pad-" + (index + 1),
      name: "Pad " + (index + 1),
      note: FIRST_NOTE + index,
      root_note: 60,
      trigger_mode: "gate",
      velocity: 1,
      volume: 1,
      pan: 0,
      choke_group: 0,
      enabled: true,
      mute: false,
      solo: false,
      patch_name: "Init",
      patch_bank: "",
      patch_index: null,
      values: defaultValues(parameters)
    };
  }

  function normalizePad(raw, index, parameters) {
    raw = raw || {};
    var pad = createPad(index, parameters);
    var patchValues = raw.values;
    if (!patchValues && raw.patch && Array.isArray(raw.patch.values)) patchValues = raw.patch.values;
    if (!patchValues && Array.isArray(raw.patch_values)) patchValues = raw.patch_values;

    pad.id = typeof raw.id === "string" && raw.id ? raw.id : pad.id;
    pad.name = typeof raw.name === "string" && raw.name.trim() ? raw.name.trim().slice(0, 48) : pad.name;
    pad.note = integer(raw.note, pad.note, 0, 127);
    pad.root_note = integer(raw.root_note, 60, 0, 127);
    pad.trigger_mode = raw.trigger_mode === "one-shot" ? "one-shot" : "gate";
    pad.velocity = clamp(raw.velocity === undefined ? 1 : raw.velocity, 0, 2);
    pad.volume = clamp(raw.volume === undefined ? 1 : raw.volume, 0, 1.5);
    pad.pan = clamp(raw.pan === undefined ? 0 : raw.pan, -1, 1);
    pad.choke_group = integer(raw.choke_group, 0, 0, 8);
    pad.enabled = raw.enabled === undefined ? true : !!raw.enabled;
    pad.mute = !!raw.mute;
    pad.solo = !!raw.solo;
    pad.patch_name = typeof raw.patch_name === "string" ? raw.patch_name.slice(0, 80) :
      (raw.patch && typeof raw.patch.name === "string" ? raw.patch.name.slice(0, 80) : pad.patch_name);
    pad.patch_bank = typeof raw.patch_bank === "string" ? raw.patch_bank.slice(0, 80) :
      (raw.patch && typeof raw.patch.bank === "string" ? raw.patch.bank.slice(0, 80) : pad.patch_bank);
    var patchIndex = raw.patch_index;
    if (patchIndex === undefined && raw.patch) patchIndex = raw.patch.index;
    pad.patch_index = patchIndex === null || patchIndex === undefined ? null : integer(patchIndex, 0, 0, 127);
    pad.values = normalizeValues(patchValues, parameters);
    return pad;
  }

  function createKit(parameters) {
    var pads = [];
    for (var i = 0; i < PAD_COUNT; i++) pads.push(createPad(i, parameters));
    return {
      format: FORMAT,
      version: VERSION,
      name: "Untitled Kit",
      mapping: "chromatic",
      midi_channel: "omni",
      selected: 0,
      pads: pads
    };
  }

  function normalizeChannel(channel) {
    if (channel === "omni" || channel === undefined || channel === null || channel === "") return "omni";
    return integer(channel, 0, 0, 15);
  }

  function normalizeKit(raw, parameters) {
    raw = raw || {};
    var kit = createKit(parameters);
    kit.name = typeof raw.name === "string" && raw.name.trim() ? raw.name.trim().slice(0, 80) : kit.name;
    kit.mapping = raw.mapping === "gm" ? "gm" : (raw.mapping === "custom" ? "custom" : "chromatic");
    kit.midi_channel = normalizeChannel(raw.midi_channel);
    kit.selected = integer(raw.selected, 0, 0, PAD_COUNT - 1);
    for (var i = 0; i < PAD_COUNT; i++) {
      kit.pads[i] = normalizePad(raw.pads && raw.pads[i], i, parameters);
    }
    return kit;
  }

  function applyMapping(kit, preset) {
    if (!kit || !Array.isArray(kit.pads)) return kit;
    if (preset === "gm") {
      kit.mapping = "gm";
      kit.midi_channel = 9;
      kit.pads.forEach(function (pad, index) {
        pad.note = GM[index][0];
        pad.name = GM[index][1];
        pad.choke_group = (pad.note === 42 || pad.note === 46) ? 1 : 0;
      });
      return kit;
    }
    if (preset === "chromatic") {
      kit.mapping = "chromatic";
      kit.midi_channel = "omni";
      kit.pads.forEach(function (pad, index) {
        pad.note = FIRST_NOTE + index;
      });
      return kit;
    }
    kit.mapping = "custom";
    return kit;
  }

  function channelMatches(kit, channel) {
    if (channel === undefined || channel === null || kit.midi_channel === "omni") return true;
    return Number(channel) === Number(kit.midi_channel);
  }

  function targetsForNote(kit, note, channel) {
    if (!kit || !Array.isArray(kit.pads) || !channelMatches(kit, channel)) return [];
    var hasSolo = kit.pads.some(function (pad) { return pad.enabled && pad.solo; });
    var targets = [];
    kit.pads.forEach(function (pad, index) {
      if (pad.note !== note || !pad.enabled || pad.mute) return;
      if (hasSolo && !pad.solo) return;
      targets.push(index);
    });
    return targets;
  }

  function noteOnEvents(kit, note, velocity, channel) {
    var events = [];
    targetsForNote(kit, note, channel).forEach(function (slot) {
      var pad = kit.pads[slot];
      if (pad.choke_group > 0) {
        kit.pads.forEach(function (other, otherSlot) {
          if (otherSlot !== slot && other.choke_group === pad.choke_group) {
            events.push({ type: "panic", slot: otherSlot, reason: "choke" });
          }
        });
      }
      events.push({
        type: "note",
        on: true,
        slot: slot,
        note: pad.root_note,
        velocity: integer(Number(velocity || 0) * pad.velocity, 0, 1, 127),
        trigger_mode: pad.trigger_mode
      });
    });
    return events;
  }

  function noteOffEvents(routes) {
    var events = [];
    (routes || []).forEach(function (route) {
      if (route.trigger_mode === "gate") {
        events.push({ type: "note", on: false, slot: route.slot, note: route.note, velocity: 0 });
      }
    });
    return events;
  }

  function qkitObject(kit, parameters) {
    kit = normalizeKit(kit, parameters);
    return {
      format: FORMAT,
      version: VERSION,
      name: kit.name,
      mapping: kit.mapping,
      midi_channel: kit.midi_channel,
      pads: kit.pads.map(function (pad) {
        return {
          id: pad.id,
          note: pad.note,
          name: pad.name,
          root_note: pad.root_note,
          trigger_mode: pad.trigger_mode,
          velocity: pad.velocity,
          volume: pad.volume,
          pan: pad.pan,
          choke_group: pad.choke_group,
          enabled: pad.enabled,
          mute: pad.mute,
          solo: pad.solo,
          patch: {
            format: "quesynth-patch",
            name: pad.patch_name,
            bank: pad.patch_bank,
            index: pad.patch_index,
            values: pad.values.slice()
          }
        };
      })
    };
  }

  function stringify(kit, parameters) {
    return JSON.stringify(qkitObject(kit, parameters), null, 2) + "\n";
  }

  function parse(text, parameters) {
    var raw = typeof text === "string" ? JSON.parse(text) : text;
    if (!raw || raw.format !== FORMAT) throw new Error("Not a Quesynth kit");
    if (raw.version !== VERSION) throw new Error("Unsupported Quesynth kit version: " + raw.version);
    return normalizeKit(raw, parameters);
  }

  function clonePad(pad, parameters) {
    return normalizePad(JSON.parse(JSON.stringify(pad)), 0, parameters);
  }

  return {
    FORMAT: FORMAT,
    VERSION: VERSION,
    PAD_COUNT: PAD_COUNT,
    FIRST_NOTE: FIRST_NOTE,
    noteName: noteName,
    createPad: createPad,
    createKit: createKit,
    normalizePad: normalizePad,
    normalizeKit: normalizeKit,
    applyMapping: applyMapping,
    targetsForNote: targetsForNote,
    noteOnEvents: noteOnEvents,
    noteOffEvents: noteOffEvents,
    qkitObject: qkitObject,
    stringify: stringify,
    parse: parse,
    clonePad: clonePad
  };
});
