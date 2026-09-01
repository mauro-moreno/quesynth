// Quesynth Pad browser controller. Rack rules live in pad-model.js; this file
// only adapts them to the shared synth editor, SynthBridge, and the DOM.
(function () {
  "use strict";

  var Model = window.QuesynthPadModel;
  var PARAMS = window.SYNTH1_PARAMS || [];
  var bridge = window.SynthBridge;
  if (!Model || !bridge || !PARAMS.length) return;

  var STORAGE_KEY = "quesynth.pad.kit.v1";
  var LEGACY_KEY = "quesynth.pad.v2";
  var kit = Model.createKit(PARAMS);
  var selected = 0;
  var clipboard = null;
  var applying = false;
  var learning = false;
  var cells = [];
  var routed = Object.create(null);
  var previewed = Object.create(null);
  var heldPads = Object.create(null);
  var saveTimer = null;
  var originalSend = bridge.send.bind(bridge);

  function byId(id) { return document.getElementById(id); }
  // Rewrite only a button's trailing label text, leaving any inline icon intact.
  function setTrailingText(el, text) {
    if (!el) return;
    var node = el.lastChild;
    if (node && node.nodeType === 3) node.nodeValue = text;
    else el.appendChild(document.createTextNode(text));
  }
  function pad() { return kit.pads[selected]; }
  function boundedInt(value, fallback) {
    value = Number(value);
    return isFinite(value) ? Math.max(0, Math.min(127, Math.round(value))) : fallback;
  }
  function eventKey(note, channel) {
    return (channel === undefined || channel === null ? "*" : channel) + ":" + note;
  }
  function copyMessage(message) {
    var out = {};
    Object.keys(message || {}).forEach(function (key) { out[key] = message[key]; });
    return out;
  }
  function sendTo(message, slot) {
    var out = copyMessage(message);
    out.slot = typeof slot === "number" ? slot : selected;
    return originalSend(out);
  }
  function sendPatch(slot) {
    sendTo({ type: "state", values: kit.pads[slot].values.slice() }, slot);
  }
  function sendMix(slot) {
    var item = kit.pads[slot];
    sendTo({ type: "mix", volume: item.volume, pan: item.pan }, slot);
  }
  function panicSlot(slot) {
    sendTo({ type: "panic" }, slot);
    delete heldPads[slot];
  }
  function dispatch(events) {
    events.forEach(function (event) {
      if (event.type === "panic") { panicSlot(event.slot); return; }
      if (event.type !== "note") return;
      var message = event.trigger_mode === "one-shot" && event.on
        ? { type: "trigger", note: event.note, velocity: event.velocity }
        : { type: "note", on: event.on, note: event.note, velocity: event.velocity };
      sendTo(message, event.slot);
      if (event.on) flash(event.slot);
    });
  }

  // Parameter/state edits target the selected rack slot. Notes from the shared
  // on-screen keyboard preview it chromatically; Web MIDI uses routeMidi below.
  bridge.send = function (message) {
    if (message && message.type === "state" && Array.isArray(message.values) && !applying) {
      pad().values = Model.normalizePad({ values: message.values }, selected, PARAMS).values;
      // The bank strip is shared UI too. Keep its identity beside the values so
      // selecting another pad restores both the sound and the patch it came
      // from, rather than leaving the previous pad's bank label on screen.
      if (window.SynthPatch) pad().patch_name = window.SynthPatch.name();
      if (window.SynthBank) {
        pad().patch_bank = window.SynthBank.label();
        pad().patch_index = window.SynthBank.index();
      }
      scheduleSave();
    }
    return sendTo(message, selected);
  };
  bridge.setParam = function (index, value) {
    if (!applying) { pad().values[index] = value; scheduleSave(); }
    return sendTo({ type: "set", index: index, value: value }, selected);
  };
  bridge.note = function (on, note, velocity) {
    var key = String(note);
    if (on) {
      previewed[key] = { slot: selected, note: note };
      sendTo({ type: "note", on: true, note: note, velocity: velocity || 100 }, selected);
      flash(selected);
    } else {
      var prior = previewed[key] || { slot: selected, note: note };
      delete previewed[key];
      sendTo({ type: "note", on: false, note: prior.note, velocity: 0 }, prior.slot);
    }
    return true;
  };
  bridge.beginEdit = function (index) { sendTo({ type: "edit", index: index, begin: true }, selected); };
  bridge.endEdit = function (index) { sendTo({ type: "edit", index: index, begin: false }, selected); };
  bridge.wheel = function (which, value) { sendTo({ type: "wheel", which: which, value: value }, selected); };

  function routeMidi(on, note, velocity, channel) {
    note = boundedInt(note, 60);
    var key = eventKey(note, channel);
    if (!on) {
      var previous = routed[key] || [];
      delete routed[key];
      dispatch(Model.noteOffEvents(previous));
      return previous.length > 0;
    }
    if (learning) {
      learning = false;
      pad().note = note;
      kit.mapping = "custom";
      paintAll(); syncControls(); scheduleSave();
      return true;
    }
    if (routed[key]) dispatch(Model.noteOffEvents(routed[key]));
    var events = Model.noteOnEvents(kit, note, velocity || 100, channel);
    dispatch(events);
    routed[key] = events.filter(function (event) { return event.type === "note"; });
    return events.length > 0;
  }

  function triggerSlot(index, velocity) {
    var item = kit.pads[index];
    if (!item.enabled || item.mute) return;
    var hasSolo = kit.pads.some(function (candidate) { return candidate.enabled && candidate.solo; });
    if (hasSolo && !item.solo) return;
    if (item.choke_group > 0) {
      kit.pads.forEach(function (other, otherIndex) {
        if (otherIndex !== index && other.choke_group === item.choke_group) panicSlot(otherIndex);
      });
    }
    var event = {
      type: "note", on: true, slot: index, note: item.root_note,
      velocity: Math.max(1, Math.min(127, Math.round((velocity || 110) * item.velocity))),
      trigger_mode: item.trigger_mode
    };
    dispatch([event]);
    heldPads[index] = event;
  }
  function releaseSlot(index) {
    var event = heldPads[index];
    delete heldPads[index];
    if (event) dispatch(Model.noteOffEvents([event]));
  }

  function select(index, focus) {
    if (index < 0 || index >= kit.pads.length) return;
    selected = index;
    kit.selected = index;
    applying = true;
    try {
      if (window.synthReceive) {
        window.synthReceive({ type: "state", values: pad().values.slice(), slot: index });
        window.synthReceive({
          type: "patch",
          name: pad().patch_name || pad().name,
          bank: pad().patch_bank || "Rack",
          index: pad().patch_index
        });
      }
    } finally { applying = false; }
    paintAll(); syncControls(); scheduleSave();
    if (focus && cells[index]) cells[index].focus();
  }
  function flash(index) {
    var cell = cells[index];
    if (!cell) return;
    cell.classList.add("lit");
    clearTimeout(cell._dim);
    cell._dim = setTimeout(function () { cell.classList.remove("lit"); }, 120);
  }
  function conflicts(index) {
    var note = kit.pads[index].note;
    return kit.pads.some(function (item, other) { return other !== index && item.note === note; });
  }
  function paint(index) {
    var cell = cells[index];
    if (!cell) return;
    var item = kit.pads[index];
    cell.classList.toggle("sel", index === selected);
    cell.classList.toggle("muted", item.mute || !item.enabled);
    cell.classList.toggle("solo", item.solo);
    cell.classList.toggle("conflict", conflicts(index));
    cell.setAttribute("aria-selected", index === selected ? "true" : "false");
    cell.setAttribute("aria-label", (index + 1) + ", " + item.name + ", trigger " +
      Model.noteName(item.note) + " " + item.note + (item.mute ? ", muted" : ""));
    cell.tabIndex = index === selected ? 0 : -1;
    cell.querySelector(".pad-cell-index").textContent = String(index + 1).padStart(2, "0");
    cell.querySelector(".pad-cell-name").textContent = item.name;
    cell.querySelector(".pad-cell-note").textContent = Model.noteName(item.note) + " · " + item.note;
    cell.querySelector(".pad-cell-mode").textContent = item.trigger_mode === "one-shot" ? "ONE SHOT" : "GATE";
  }
  function paintAll() { for (var i = 0; i < kit.pads.length; i++) paint(i); }
  function db(value) { return value <= 0 ? "−∞ dB" : (20 * Math.log(value) / Math.LN10).toFixed(1) + " dB"; }
  function panText(value) {
    var n = Math.round(value * 100);
    return n === 0 ? "Center" : Math.abs(n) + "% " + (n < 0 ? "L" : "R");
  }
  function pressed(id, value) {
    var element = byId(id);
    element.setAttribute("aria-pressed", value ? "true" : "false");
    element.classList.toggle("on", !!value);
  }
  function syncControls() {
    var item = pad();
    byId("kit-name").value = kit.name;
    byId("kit-mapping").value = kit.mapping;
    byId("kit-channel").value = String(kit.midi_channel);
    byId("pad-selected").textContent = String(selected + 1).padStart(2, "0") + " · " + item.name;
    byId("rack-editor-pad").textContent = item.name;
    byId("pad-name").value = item.name;
    byId("pad-note").value = item.note;
    byId("pad-note-read").textContent = Model.noteName(item.note) + " · " + item.note;
    byId("pad-root").value = item.root_note;
    byId("pad-root-read").textContent = Model.noteName(item.root_note) + " · " + item.root_note;
    byId("pad-mode").value = item.trigger_mode;
    byId("pad-choke").value = String(item.choke_group);
    byId("pad-velocity").value = Math.round(item.velocity * 100);
    byId("pad-velocity-read").textContent = Math.round(item.velocity * 100) + "%";
    byId("pad-volume").value = Math.round(item.volume * 100);
    byId("pad-volume-read").textContent = db(item.volume);
    byId("pad-pan").value = Math.round(item.pan * 100);
    byId("pad-pan-read").textContent = panText(item.pan);
    byId("pad-learn").classList.toggle("learning", learning);
    setTrailingText(byId("pad-learn"), learning ? "HIT A PAD…" : "MIDI LEARN");
    pressed("pad-enabled", item.enabled); pressed("pad-mute", item.mute); pressed("pad-solo", item.solo);
  }

  function scheduleSave() { clearTimeout(saveTimer); saveTimer = setTimeout(saveNow, 250); }
  function saveNow() {
    clearTimeout(saveTimer); saveTimer = null; kit.selected = selected;
    try { window.localStorage.setItem(STORAGE_KEY, Model.stringify(kit, PARAMS)); } catch (error) {}
  }
  function restore() {
    var raw = null;
    try { raw = window.localStorage.getItem(STORAGE_KEY); } catch (error) {}
    if (raw) { try { kit = Model.parse(raw, PARAMS); } catch (error) { raw = null; } }
    if (!raw) {
      try { raw = window.localStorage.getItem(LEGACY_KEY); } catch (error) {}
      if (raw) { try { kit = Model.normalizeKit(JSON.parse(raw), PARAMS); } catch (error) {} }
    }
    selected = kit.selected || 0;
  }
  function hydrate() {
    kit.pads.forEach(function (_item, index) { sendPatch(index); sendMix(index); });
  }
  function downloadKit() {
    var blob = new Blob([Model.stringify(kit, PARAMS)], { type: "application/json" });
    var url = URL.createObjectURL(blob);
    var link = document.createElement("a");
    link.href = url;
    link.download = (kit.name || "quesynth-kit").replace(/[^a-z0-9_-]+/gi, "-").replace(/^-|-$/g, "").toLowerCase() + ".qkit";
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  }
  function loadKit(file) {
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function () {
      try {
        kit = Model.parse(String(reader.result), PARAMS); selected = kit.selected || 0;
        hydrate(); select(selected);
      } catch (error) { byId("rack-hint").textContent = error.message || "That file is not a valid .qkit"; }
    };
    reader.readAsText(file);
  }
  function setCustom() { kit.mapping = "custom"; byId("kit-mapping").value = "custom"; }
  function bindInput(id, eventName, update) {
    byId(id).addEventListener(eventName, function (event) {
      update(event.target.value); paintAll(); syncControls(); scheduleSave();
    });
  }

  function buildGrid() {
    var grid = byId("pad-grid");
    kit.pads.forEach(function (_item, index) {
      var cell = document.createElement("button");
      cell.type = "button"; cell.className = "pad-cell"; cell.setAttribute("role", "gridcell");
      cell.innerHTML = '<span class="pad-cell-top"><span class="pad-cell-index"></span><span class="pad-cell-mode"></span></span>' +
        '<span class="pad-cell-name"></span><span class="pad-cell-note"></span>';
      cell.addEventListener("pointerdown", function (event) {
        event.preventDefault();
        try { cell.setPointerCapture(event.pointerId); } catch (error) {}
        select(index);
        triggerSlot(index, event.pressure > 0 ? Math.round(event.pressure * 127) : 110);
      });
      ["pointerup", "pointercancel", "pointerleave"].forEach(function (name) {
        cell.addEventListener(name, function () { releaseSlot(index); });
      });
      cell.addEventListener("keydown", function (event) {
        var next = index;
        if (event.key === "ArrowLeft") next = index % 4 ? index - 1 : index + 3;
        if (event.key === "ArrowRight") next = index % 4 < 3 ? index + 1 : index - 3;
        if (event.key === "ArrowUp") next = (index + 12) % 16;
        if (event.key === "ArrowDown") next = (index + 4) % 16;
        if (next !== index) { event.preventDefault(); select(next, true); return; }
        if ((event.key === " " || event.key === "Enter") && !event.repeat) {
          event.preventDefault(); select(index); triggerSlot(index, 110);
        }
      });
      cell.addEventListener("keyup", function (event) {
        if (event.key === " " || event.key === "Enter") releaseSlot(index);
      });
      cells.push(cell); grid.appendChild(cell);
    });
  }

  function bindControls() {
    for (var channel = 1; channel <= 16; channel++) {
      var option = document.createElement("option"); option.value = String(channel - 1); option.textContent = String(channel);
      byId("kit-channel").appendChild(option);
    }
    for (var group = 1; group <= 8; group++) {
      var choke = document.createElement("option"); choke.value = String(group); choke.textContent = String(group);
      byId("pad-choke").appendChild(choke);
    }
    bindInput("kit-name", "input", function (value) { kit.name = value.trim() || "Untitled Kit"; });
    bindInput("kit-channel", "change", function (value) { kit.midi_channel = value === "omni" ? "omni" : Number(value); });
    bindInput("kit-mapping", "change", function (value) { Model.applyMapping(kit, value); });
    bindInput("pad-name", "input", function (value) { pad().name = value.trim() || ("Pad " + (selected + 1)); });
    // Numeric fields update while they are edited. Waiting for `change` meant a
    // click on a pad could sound the old root before the input lost focus.
    bindInput("pad-note", "input", function (value) { pad().note = boundedInt(value, pad().note); setCustom(); });
    bindInput("pad-root", "input", function (value) { pad().root_note = boundedInt(value, pad().root_note); });
    bindInput("pad-mode", "change", function (value) { pad().trigger_mode = value === "one-shot" ? "one-shot" : "gate"; });
    bindInput("pad-choke", "change", function (value) { pad().choke_group = Number(value) || 0; });
    bindInput("pad-velocity", "input", function (value) { pad().velocity = Number(value) / 100; });
    bindInput("pad-volume", "input", function (value) { pad().volume = Number(value) / 100; sendMix(selected); });
    bindInput("pad-pan", "input", function (value) { pad().pan = Number(value) / 100; sendMix(selected); });
    byId("pad-learn").addEventListener("click", function () { learning = !learning; syncControls(); });
    byId("pad-enabled").addEventListener("click", function () { pad().enabled = !pad().enabled; if (!pad().enabled) panicSlot(selected); paintAll(); syncControls(); scheduleSave(); });
    byId("pad-mute").addEventListener("click", function () { pad().mute = !pad().mute; if (pad().mute) panicSlot(selected); paintAll(); syncControls(); scheduleSave(); });
    byId("pad-solo").addEventListener("click", function () {
      pad().solo = !pad().solo;
      if (kit.pads.some(function (item) { return item.solo; })) kit.pads.forEach(function (item, index) { if (!item.solo) panicSlot(index); });
      paintAll(); syncControls(); scheduleSave();
    });
    byId("pad-copy").addEventListener("click", function () { clipboard = Model.clonePad(pad(), PARAMS); byId("pad-paste").disabled = false; });
    byId("pad-paste").addEventListener("click", function () {
      if (!clipboard) return;
      var keptId = pad().id;
      kit.pads[selected] = Model.clonePad(clipboard, PARAMS); kit.pads[selected].id = keptId;
      sendPatch(selected); sendMix(selected); select(selected);
    });
    var editButton = byId("pad-edit");
    var editor = byId("rack-editor");
    function setEditor(open) {
      editor.hidden = !open;
      document.body.classList.toggle("rack-editor-closed", !open);
      setTrailingText(editButton, open ? "CLOSE SYNTH" : "EDIT SYNTH");
      editButton.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) byId("rack-editor-close").focus();
      else editButton.focus();
    }
    editButton.addEventListener("click", function () { setEditor(editor.hidden); });
    byId("rack-editor-close").addEventListener("click", function () { setEditor(false); });
    // Escape belongs to whatever is on top, and the drawer is never that while a
    // dialog or the information popover is open -- each of those closes itself on
    // the same key. Handler order cannot settle it: every one of them listens on
    // `document`, and this one is bound before either of theirs exists, so it is
    // asked first and has to decline. Without the guard a single press shut the
    // dialog *and* the whole editor under it, and two handlers then argued over
    // where focus went.
    function coveredByLayer() {
      return !!(window.SynthModal && window.SynthModal.isOpen()) ||
             !!(window.SynthInfo && window.SynthInfo.isOpen());
    }
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || editor.hidden || coveredByLayer()) return;
      event.preventDefault();
      setEditor(false);
    });
    document.querySelector(".rack-views").addEventListener("click", function (event) {
      var button = event.target.closest("[data-rack-view]");
      if (!button) return;
      byId("pads").setAttribute("data-view", button.getAttribute("data-rack-view"));
      this.querySelectorAll("[data-rack-view]").forEach(function (candidate) {
        var on = candidate === button;
        candidate.classList.toggle("on", on);
        candidate.setAttribute("aria-pressed", on ? "true" : "false");
      });
    });
    byId("kit-save").addEventListener("click", downloadKit);
    byId("kit-open").addEventListener("click", function () { byId("kit-file").click(); });
    byId("kit-file").addEventListener("change", function () { loadKit(this.files && this.files[0]); this.value = ""; });
    byId("kit-new").addEventListener("click", function () {
      kit.pads.forEach(function (_item, index) { panicSlot(index); });
      kit = Model.createKit(PARAMS); selected = 0; hydrate(); select(0);
    });
    window.addEventListener("pagehide", saveNow);
  }

  function build() {
    restore(); buildGrid(); bindControls(); hydrate(); paintAll(); select(selected);
  }

  window.QuesynthPad = {
    routeMidi: routeMidi,
    trigger: triggerSlot,
    release: releaseSlot,
    select: select,
    kit: function () { return kit; }
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setTimeout(build, 0); });
  } else { setTimeout(build, 0); }
})();
