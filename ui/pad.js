// The pad: sixteen instruments behind one editor.
//
// Nothing here is a second interface. `app.js` builds the same panel it builds on
// the synth page, out of the same `params.js` and `layout.js`, and this file does
// three things around it:
//
//   * puts a four by four grid above it, one cell per instrument
//   * tags everything the panel sends with which instrument it is for
//   * hands the panel a different set of values when the selection moves
//
// The third is what makes the reuse work. `app.js` holds exactly one array of
// stored integers and refreshes its controls when a *host* sends it a new one --
// that path already exists, because a plugin host has to be able to say "the
// project loaded, here is the patch". Selecting a pad is the same event: this
// file delivers a `state` message and the panel repaints itself. The panel has
// no idea there are sixteen of anything, which is what makes editing it improve
// both pages at once.

(function () {
  "use strict";

  var ROWS = 4, COLS = 4;
  var COUNT = ROWS * COLS;
  // Bumped from v1 because the notes changed meaning rather than merely changing.
  // v1 opened with every cell on C4, which was harmless while a note only ever
  // played the selected cell and is not now that a note addresses the cells that
  // answer to it: sixteen pads all listening to C4 would sound sixteen at once.
  // A stored grid from then is discarded rather than migrated -- it is a minute
  // old and holds nothing but defaults.
  var KEY = "quesynth.pad.v2";
  var NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

  var PARAMS = window.SYNTH1_PARAMS || [];
  var bridge = window.SynthBridge;
  if (!bridge || !PARAMS.length) return;

  function noteName(n) {
    return NAMES[((n % 12) + 12) % 12] + (Math.floor(n / 12) - 1);
  }

  // One patch per cell, as the array of stored integers the panel and the .sy1
  // format both speak. Seeded from the reference's own defaults so every cell
  // opens on a real instrument rather than on zeros.
  function defaults() {
    var v = [];
    PARAMS.forEach(function (p) { v[p.i] = p.def; });
    return v;
  }

  // Which note each cell answers to: sixteen chromatic steps up from MIDI 36,
  // read left to right and top to bottom.
  //
  // 36 because that is where every drum machine and every drum rack starts, so a
  // controller made for one already lines up with this without being told to.
  // The strip below the grid names it C2, which is what the rest of this
  // interface calls it -- middle C is C4 here.
  var FIRST_NOTE = 36;

  var pads = [];
  for (var i = 0; i < COUNT; i++) {
    pads.push({ values: defaults(), note: FIRST_NOTE + i, name: "" });
  }
  var selected = 0;
  var clipboard = null;
  var applying = false;   // true while a selection is being pushed into the panel
  var cells = [];

  // ---------------------------------------------------------------- the engine

  // Which instrument a message is for. The panel never sets this; everything it
  // sends is for whichever cell is selected, and the pads themselves say so
  // explicitly when they are struck.
  var send = bridge.send.bind(bridge);

  function tagged(msg, slot) {
    msg.slot = (typeof slot === "number") ? slot : selected;
    return send(msg);
  }

  // The methods are replaced on the object rather than the object being replaced,
  // because `app.js` took hold of it when it loaded and holds it still.
  bridge.send = function (msg) {
    // A whole patch on its way out -- a bank patch being loaded, most often.
    // Recorded here as well as sent, or the cell would sound like the new patch
    // and remember the old one.
    if (msg && msg.type === "state" && Array.isArray(msg.values) && !applying) {
      msg.values.forEach(function (v, i) {
        if (typeof v === "number") pads[selected].values[i] = v;
      });
      save();
    }
    return tagged(msg);
  };

  bridge.setParam = function (index, value) {
    if (!applying) {
      pads[selected].values[index] = value;
      save();
    }
    return tagged({ type: "set", index: index, value: value });
  };

  // A note addresses the cell that answers to it, wherever the note came from --
  // a MIDI keyboard, the keys along the foot, a controller's own pads.
  //
  // Sending it to whichever cell happened to be selected is the obvious thing and
  // it is wrong: selecting is how you choose what to *edit*, and clicking a pad
  // both selects and strikes it, so a bar into a session every note played would
  // be arriving at whichever pad was last touched. On a grid of sixteen
  // instruments the note is the address.
  //
  // A note no cell answers to falls back to the selected one, which is what makes
  // the keyboard still useful: it plays the sound being worked on, chromatically,
  // without having to be assigned anywhere first.
  var routed = {};   // note -> the cells it was sent to, so its note off matches

  function cellsAnswering(note) {
    var out = [];
    for (var i = 0; i < COUNT; i++) if (pads[i].note === note) out.push(i);
    return out;
  }

  bridge.note = function (on, note, velocity) {
    if (!on) {
      var previous = routed[note] || [selected];
      delete routed[note];
      previous.forEach(function (s) {
        tagged({ type: "note", on: false, note: note, velocity: 0 }, s);
      });
      return true;
    }
    var targets = cellsAnswering(note);
    if (!targets.length) targets = [selected];
    routed[note] = targets;
    targets.forEach(function (s) {
      tagged({ type: "note", on: true, note: note, velocity: velocity || 100 }, s);
      flash(s);
    });
    return true;
  };

  bridge.beginEdit = function (index) { tagged({ type: "edit", index: index, begin: true }); };
  bridge.endEdit = function (index) { tagged({ type: "edit", index: index, begin: false }); };
  bridge.wheel = function (which, value) { tagged({ type: "wheel", which: which, value: value }); };

  // ------------------------------------------------------------- the selection

  // Hand the panel a different instrument. This is the whole trick: the message
  // is the one a host sends when a project loads, so the panel's own handler does
  // the work and nothing here has to know what a control looks like.
  function select(index) {
    if (index < 0 || index >= COUNT) return;
    selected = index;
    applying = true;
    try {
      if (window.synthReceive) {
        window.synthReceive({ type: "state", values: pads[index].values.slice() });
      }
    } finally {
      applying = false;
    }
    paintAll();
    var label = document.getElementById("pad-selected");
    if (label) label.textContent = "Pad " + (index + 1);
    var slider = document.getElementById("pad-note");
    if (slider) slider.value = String(pads[index].note);
    showNote();
    save();
  }

  function showNote() {
    var read = document.getElementById("pad-note-read");
    if (read) read.textContent = noteName(pads[selected].note);
  }

  // ------------------------------------------------------------------ striking

  var held = {};   // cell -> the note it is currently sounding

  // Lighting a cell, whoever struck it. A note arriving over MIDI has to show on
  // the grid as plainly as a finger does, or there is no way to see which cell
  // answered without listening for it.
  function flash(index) {
    var el = cells[index];
    if (!el) return;
    el.classList.add("lit");
    // Restarted rather than accumulated, so a fast roll keeps lighting up.
    clearTimeout(el._dim);
    el._dim = setTimeout(function () { el.classList.remove("lit"); }, 110);
  }

  function strike(index, velocity) {
    if (held[index] !== undefined) release(index);
    var note = pads[index].note;
    held[index] = note;
    tagged({ type: "note", on: true, note: note, velocity: velocity || 110 }, index);
    flash(index);
  }

  function release(index) {
    if (held[index] === undefined) return;
    tagged({ type: "note", on: false, note: held[index], velocity: 0 }, index);
    delete held[index];
  }

  // --------------------------------------------------------------------- paint

  function paint(index) {
    var el = cells[index];
    if (!el) return;
    el.classList.toggle("sel", index === selected);
    var name = el.querySelector(".pad-cell-name");
    if (name) name.textContent = pads[index].name || ("Pad " + (index + 1));
    var sub = el.querySelector(".pad-cell-note");
    if (sub) sub.textContent = noteName(pads[index].note);
  }

  function paintAll() {
    for (var i = 0; i < COUNT; i++) paint(i);
  }

  // --------------------------------------------------------------- remembering

  // This page's own, under its own key. `store.js` is not loaded here: it
  // remembers one sound and there are sixteen, and two things writing the same
  // idea into local storage is how they end up disagreeing.
  var saveTimer = null;

  function save() {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      saveTimer = null;
      try {
        window.localStorage.setItem(KEY, JSON.stringify({
          selected: selected,
          pads: pads.map(function (p) {
            return { values: p.values, note: p.note, name: p.name };
          })
        }));
      } catch (e) { /* private browsing refuses the write; the page still works */ }
    }, 400);
  }

  function restore() {
    var raw;
    try { raw = window.localStorage.getItem(KEY); } catch (e) { return false; }
    if (!raw) return false;
    var data;
    try { data = JSON.parse(raw); } catch (e) { return false; }
    if (!data || !Array.isArray(data.pads)) return false;
    data.pads.forEach(function (p, i) {
      if (i >= COUNT || !p) return;
      if (Array.isArray(p.values)) {
        p.values.forEach(function (v, j) {
          if (typeof v === "number") pads[i].values[j] = v;
        });
      }
      if (typeof p.note === "number") pads[i].note = p.note;
      if (typeof p.name === "string") pads[i].name = p.name;
    });
    if (typeof data.selected === "number") {
      selected = Math.max(0, Math.min(COUNT - 1, data.selected));
    }
    return true;
  }

  // Every cell's patch has to reach its own engine, and only the selected one
  // travels there through the panel. The other fifteen are sent straight out.
  function pushAll() {
    for (var i = 0; i < COUNT; i++) {
      if (i === selected) continue;
      tagged({ type: "state", values: pads[i].values.slice() }, i);
    }
  }

  // ------------------------------------------------------------------ the grid

  function build() {
    var grid = document.getElementById("pad-grid");
    if (!grid) return;

    for (var i = 0; i < COUNT; i++) {
      (function (index) {
        var el = document.createElement("button");
        el.type = "button";
        el.className = "pad-cell";
        el.setAttribute("aria-label", "Pad " + (index + 1));
        var name = document.createElement("span");
        name.className = "pad-cell-name";
        var note = document.createElement("span");
        note.className = "pad-cell-note";
        el.appendChild(name);
        el.appendChild(note);

        // Pointer rather than click: a pad has to sound on the way down, and a
        // click fires on the way up.
        el.addEventListener("pointerdown", function (e) {
          e.preventDefault();
          try { el.setPointerCapture(e.pointerId); } catch (err) { /* still works */ }
          select(index);
          strike(index, 110);
        });
        el.addEventListener("pointerup", function () { release(index); });
        el.addEventListener("pointercancel", function () { release(index); });
        el.addEventListener("pointerleave", function () { release(index); });

        // The keyboard reaches it too: the grid is sixteen buttons, and a button
        // that cannot be worked from a keyboard is not a button.
        el.addEventListener("keydown", function (e) {
          if (e.key === " " || e.key === "Enter") {
            e.preventDefault();
            select(index);
            strike(index, 110);
          }
        });
        el.addEventListener("keyup", function (e) {
          if (e.key === " " || e.key === "Enter") release(index);
        });

        cells.push(el);
        grid.appendChild(el);
      })(i);
    }

    var slider = document.getElementById("pad-note");
    if (slider) {
      slider.addEventListener("input", function () {
        pads[selected].note = parseInt(slider.value, 10) || 60;
        showNote();
        paint(selected);
        save();
      });
    }

    var copy = document.getElementById("pad-copy");
    var paste = document.getElementById("pad-paste");
    if (copy && paste) {
      copy.addEventListener("click", function () {
        clipboard = { values: pads[selected].values.slice(), note: pads[selected].note };
        paste.disabled = false;
        copy.textContent = "COPIED";
        setTimeout(function () { copy.textContent = "COPY"; }, 700);
      });
      paste.addEventListener("click", function () {
        if (!clipboard) return;
        pads[selected].values = clipboard.values.slice();
        pads[selected].note = clipboard.note;
        // Straight out as well as into the panel: the engine behind this cell
        // has to hear the whole patch, not the ninety-nine edits that would
        // otherwise arrive one at a time.
        tagged({ type: "state", values: pads[selected].values.slice() }, selected);
        select(selected);
      });
    }

    restore();
    paintAll();
    select(selected);
    pushAll();
  }

  // After `app.js`. Its own DOMContentLoaded handler builds the panel, and this
  // one has to run against a panel that exists -- so it is registered later and,
  // if the document is already parsed, deferred by a turn.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { setTimeout(build, 0); });
  } else {
    setTimeout(build, 0);
  }
})();
