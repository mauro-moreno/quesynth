// The configuration dialog: what the controllers do.
//
// The second body for the shell in ui/modal.js, which was written for two from
// the start. What it edits, and what it only reports, is the whole shape of it:
// the parts covered by the MIDI specification are shown and not offered for
// editing, and everything else is yours.
//
// See ui/midimap.js for which assignments are the standard's and why.

(function () {
  "use strict";

  function map() { return window.SynthMidiMap; }
  function params() { return window.SYNTH1_PARAMS || []; }

  function el(tag, className, text) {
    var e = document.createElement(tag);
    if (className) e.className = className;
    if (text != null) e.textContent = text;
    return e;
  }

  function nameOf(index) {
    var list = params();
    for (var i = 0; i < list.length; i++) if (list[i].i === index) return list[i].name;
    return "—";
  }

  function build() {
    var wrap = el("div", "options");

    // --- what the specification already decides ---------------------------

    var fixed = el("section", "options-block");
    fixed.appendChild(el("h3", "options-heading", "Fixed by the MIDI standard"));
    fixed.appendChild(el("p", "options-note",
      "These are not assignable. They are what the specification says these " +
      "messages mean, and a controller that sends them expects them to work."));

    var table = el("div", "options-fixed");
    [
      ["Program Change", "Selects a patch, 0–127 — one per slot"],
      ["CC 0 / CC 32", "Bank Select, coarse and fine. The next Program Change acts on it"],
      ["CC 1", "Modulation wheel"],
      ["CC 7", "Master volume"],
      ["Pitch bend", "Pitch, over the bend range in the Master section"],
    ].forEach(function (row) {
      var line = el("div", "options-fixed-row");
      line.appendChild(el("span", "options-fixed-what", row[0]));
      line.appendChild(el("span", "options-fixed-does", row[1]));
      table.appendChild(line);
    });
    fixed.appendChild(table);
    wrap.appendChild(fixed);

    // --- the assignable ones ----------------------------------------------

    var bound = el("section", "options-block");
    var head = el("div", "options-heading-row");
    head.appendChild(el("h3", "options-heading", "Controller assignments"));
    var reset = el("button", "browser-mini", "Standard");
    reset.type = "button";
    reset.title = "Back to the MIDI specification's own assignments";
    reset.addEventListener("click", function () {
      map().reset();
      paint();
    });
    head.appendChild(reset);
    bound.appendChild(head);
    bound.appendChild(el("p", "options-note",
      "Moving a bound controller moves that parameter, exactly as turning its " +
      "knob does. These belong to the instrument, not to the patch, so they do " +
      "not change when the sound does."));

    var rows = el("div", "options-rows");
    bound.appendChild(rows);

    var add = el("button", "browser-mini options-add", "Add an assignment");
    add.type = "button";
    bound.appendChild(add);
    wrap.appendChild(bound);

    // A row being learnt, so only one is armed at a time.
    var learning = null;

    function paint() {
      rows.textContent = "";
      var all = map().all();
      var ccs = Object.keys(all).map(Number).sort(function (a, b) { return a - b; });

      if (!ccs.length) {
        rows.appendChild(el("div", "options-empty", "Nothing assigned."));
      }

      ccs.forEach(function (cc) {
        var row = el("div", "options-row");

        var label = el("span", "options-cc", "CC " + cc);
        row.appendChild(label);

        // Which parameter. Every one of them, because there is no reason to
        // decide for somebody which knobs are worth a controller.
        var pick = document.createElement("select");
        pick.className = "options-target";
        params().forEach(function (p) {
          var o = document.createElement("option");
          o.value = String(p.i);
          o.textContent = p.name;
          if (p.i === all[cc]) o.selected = true;
          pick.appendChild(o);
        });
        pick.addEventListener("change", function () {
          map().bind(cc, Number(pick.value));
        });
        row.appendChild(pick);

        var learn = el("button", "browser-mini", learning === cc ? "Move one…" : "Learn");
        learn.type = "button";
        learn.title = "Move a controller to put it here instead";
        learn.addEventListener("click", function () {
          if (learning === cc) { map().learn(null); learning = null; paint(); return; }
          learning = cc;
          paint();
          map().learn(function (heard) {
            var to = all[cc];
            map().bind(cc, -1);
            map().bind(heard, to);
            learning = null;
            paint();
          });
        });
        row.appendChild(learn);

        var drop = el("button", "browser-mini", "Remove");
        drop.type = "button";
        drop.addEventListener("click", function () {
          map().bind(cc, -1);
          paint();
        });
        row.appendChild(drop);

        rows.appendChild(row);
      });
    }

    add.addEventListener("click", function () {
      // The first controller that is neither taken nor spoken for.
      var all = map().all();
      for (var cc = 1; cc < 120; cc++) {
        if (map().reserved(cc)) continue;
        if (Object.prototype.hasOwnProperty.call(all, cc)) continue;
        map().bind(cc, params()[0] ? params()[0].i : 0);
        paint();
        return;
      }
    });

    paint();
    wrap.stopLearning = function () { map().learn(null); };
    return wrap;
  }

  function open() {
    if (!map()) return;
    var body = build();
    window.SynthModal.show("Configure", body, [
      { label: "Done", primary: true, onClick: function (close) { body.stopLearning(); close(); } },
    ]);
  }

  window.SynthOptions = { open: open };

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("config-toggle");
    if (!button) return;
    // The markup hides it; this file existing is what says it can be pressed.
    button.hidden = false;
    button.addEventListener("click", function (e) {
      e.stopPropagation();
      open();
    });
  });
})();
