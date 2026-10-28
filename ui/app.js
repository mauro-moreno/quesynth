// Builds the panel from params.js and layout.js and keeps it in step with the host.
//
// The interface holds one array of stored integers, `values`, indexed by parameter.
// Everything else is a view of it. A control moving writes into that array and
// tells the bridge; a message from the host writes into it and refreshes the
// affected control. There is no second copy of the state anywhere, which is what
// keeps automation from fighting the mouse.
//
// Controls address parameters by **position**, not by stored integer, and convert
// at the edge through the generated `s` table. That distinction is not pedantry: a
// third of the enumerated parameters store an integer that is not their position,
// and two of them list their states out of order entirely. A control that assumed
// the two were the same would set the wrong LFO waveform and look correct doing it.

(function () {
  "use strict";

  var PARAMS = window.SYNTH1_PARAMS || [];
  var LAYOUT = window.SYNTH1_LAYOUT || [];
  var bridge = window.SynthBridge;

  var byIndex = {};
  PARAMS.forEach(function (p) { byIndex[p.i] = p; });

  // Stored integer per parameter, seeded from the reference's own defaults so the
  // standalone page opens on a real patch rather than on zeros.
  var values = {};
  PARAMS.forEach(function (p) { values[p.i] = p.def; });

  var controls = {};    // parameter index -> refresh function
  var dependents = {};  // parameter index -> functions to run when it changes

  // Set once the navigation exists and the keyboard is built. The tail spacer
  // depends on how much of the window the keyboard is covering, so deploying it
  // has to be able to ask for the measurement again.
  var relayout = function () {};
  var keyboardHeight = function () { return 0; };

  function onChanged(index) {
    if (controls[index]) controls[index]();
    var list = dependents[index];
    if (list) for (var i = 0; i < list.length; i++) list[i]();
    // Only the browser build ships a store; in a plugin the host is already
    // saving this into the project and a second copy would fight it.
    if (window.SynthStore) window.SynthStore.touch();
    refreshDirty();
  }

  function dependOn(index, fn) {
    (dependents[index] = dependents[index] || []).push(fn);
  }

  // Pointer capture, which is allowed to fail.
  //
  // `setPointerCapture` throws NotFoundError when the pointer it names is no
  // longer active, and a pointer can end between the event being queued and the
  // handler running. Unguarded, that exception aborts the rest of the handler --
  // so a wheel drag would capture nothing *and* never set its value, which is
  // exactly the failure this was written for.
  function capture(el, id) {
    try { el.setPointerCapture(id); } catch (e) { /* the drag still works */ }
  }

  function uncapture(el, id) {
    try {
      if (el.hasPointerCapture(id)) el.releasePointerCapture(id);
    } catch (e) { /* already gone */ }
  }

  // ------------------------------------------------------------- conversions

  // The position a stored integer selects. Mirrors `resolved_position` in
  // src/engine/binding.odin, including its clamping, so what the interface shows
  // is what the engine will do with the same number.
  //
  // For a parameter whose stored integers are its displays (`s`), an integer that
  // matches none is clamped into the range the displays span and then looked up: the
  // state with the smallest display below the range, otherwise the state with the
  // largest display under it. By value and not by position, because the LFO types'
  // displays run 0, 1, 5, 2, 3, 4 and a stored 6 sounds as display 5, the third state.
  // See `display_state_clamped` in src/patch/value.odin, which has the evidence.
  function positionOf(param, stored) {
    if (param.s) {
      var exact = param.s.indexOf(stored);
      if (exact >= 0) return exact;
      var atOrBelow = -1, lowest = 0;
      for (var i = 0; i < param.s.length; i++) {
        if (param.s[i] < param.s[lowest]) lowest = i;
        if (param.s[i] <= stored && (atOrBelow < 0 || param.s[i] > param.s[atOrBelow])) atOrBelow = i;
      }
      return atOrBelow >= 0 ? atOrBelow : lowest;
    }
    if (stored < 0) return 0;
    if (stored >= param.n) return param.n - 1;
    return stored;
  }

  function storedOf(param, position) {
    if (param.s) return param.s[Math.max(0, Math.min(param.s.length - 1, position))];
    return Math.max(0, Math.min(param.n - 1, position));
  }

  // The position another parameter currently selects, by index.
  //
  // Conditional readings are handed this rather than the value map, because the
  // two things they ask about are not stored as their positions: the LFO
  // destinations of parameters 41 and 46 store 1..7 for positions 0..6, so a
  // formatter comparing raw stored values would name the destination one place
  // off and print semitones over a pan knob. -1 for a parameter this build does
  // not have, which no position matches, so such a formatter falls through to
  // the bare reading rather than guessing.
  function positionAt(index) {
    var p = byIndex[index];
    return p ? positionOf(p, values[index]) : -1;
  }

  function valueText(param, position) {
    if (!param.v) return String(position);
    return param.v[Math.max(0, Math.min(param.v.length - 1, position))];
  }

  // Split a reading into the number and its unit, so the unit can be greyed.
  //
  // The unit is the trailing run of letters, and it only counts as one when what
  // precedes it contains a digit. That proviso is doing real work: "On" and "Off"
  // are all letters and are not units, "-inf" ends in letters and is not a unit,
  // and "L 100%" begins with a letter that is not one either -- only its trailing
  // "%" is. Readings with no trailing letters at all, like "50 : 50" and "(8)",
  // come back whole.
  var UNIT_RE = /^(.*?)\s*([A-Za-z%\/]+)$/;

  function splitUnit(text) {
    var m = UNIT_RE.exec(text);
    if (!m || !/[0-9]/.test(m[1])) return { value: text, unit: "" };
    return { value: m[1], unit: m[2] };
  }

  // ------------------------------------------------------------------ setting

  function setPosition(index, position, notify) {
    var param = byIndex[index];
    if (!param) return;
    var stored = storedOf(param, position);
    if (values[index] === stored) return;
    values[index] = stored;
    onChanged(index);
    if (notify !== false) bridge.setParam(index, stored);
  }

  function setStored(index, stored) {
    var param = byIndex[index];
    if (!param) return;
    values[index] = stored;
    onChanged(index);
  }

  // --------------------------------------------------------------------- knob

  var SVG = "http://www.w3.org/2000/svg";

  // One hand-drawn icon language for chrome and enumerated shapes. Every glyph
  // is presentation-only: adjacent text and accessible names remain intact.
  var ICON_PATHS = {
    midi: ["M12 70V30h16v40M38 70V30h24v40M72 70V30h16v40"],
    keys: ["M10 25h80v50H10z", "M28 25v28M45 25v28M62 25v28M79 25v28"],
    write: ["M18 14h54l12 12v60H18z", "M31 14v26h38V14M34 86V57h32v29"],
    config: ["M18 25h64M18 50h64M18 75h64", "M35 16v18M65 41v18M43 66v18"],
    file: ["M20 12h42l18 18v58H20z", "M62 12v18h18"],
    open: ["M12 32h31l8 10h37L75 82H18z"],
    save: ["M18 14h64v72H18z", "M31 14v25h38V14M32 86V58h36v28"],
    copy: ["M31 29h50v55H31z", "M19 71V16h50v13"],
    paste: ["M26 24h48v62H26z", "M38 14h24v20H38z"],
    learn: ["M18 22h64v56H18z", "M34 38l32 24M66 38L34 62"],
    enabled: ["M20 52l18 18 42-44"],
    mute: ["M18 43h18l20-18v50L36 57H18z", "M68 39l18 22M86 39L68 61"],
    solo: ["M22 68c10 10 46 10 56-5 8-13-3-20-20-22l-16-2c-17-2-24-15-13-24 12-10 47-8 61 2"],
    edit: ["M18 72l8-25 39-39 19 19-39 39z", "M26 47l19 19"],
    close: ["M22 22l56 56M78 22L22 78"],
    star: ["M50 10l12 27 29 3-22 20 6 29-25-15-25 15 6-29-22-20 29-3z"],
    previous: ["M64 18L32 50l32 32"], next: ["M36 18l32 32-32 32"],
    // The stepper's two, so a whole number's controls are drawn in the same hand
    // as everything else rather than set in whatever the font has at "−".
    minus: ["M24 50h52"], plus: ["M50 24v52M24 50h52"],
    down: ["M50 18v64M25 57l25 25 25-25"], up: ["M50 82V18M25 43l25-25 25 25"],
    sine: ["M8 50c14-34 28-34 42 0s28 34 42 0"],
    saw: ["M8 70l35-40v40l41-40"], pulse: ["M8 68V34h38v34h38V34"],
    triangle: ["M8 70l28-40 28 40 28-40"],
    noise: ["M8 59l9-22 9 31 9-38 9 30 9-18 9 27 9-34 13 23"],
    sample: ["M8 64h16V36h18v28h18V36h24"],
    random: ["M8 63c12-4 14-31 28-20s19 27 28 8 14-20 28-10"],
    lowpass: ["M8 28h27c16 0 18 42 57 42"],
    highpass: ["M8 70h27c16 0 18-42 57-42"],
    bandpass: ["M8 70c19 0 22-40 42-40s23 40 42 40"],
  };

  function makeIcon(name, extraClass) {
    var svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("class", "icon" + (extraClass ? " " + extraClass : ""));
    svg.setAttribute("viewBox", "0 0 100 100");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    var paths = ICON_PATHS[name] || ICON_PATHS.config;
    for (var i = 0; i < paths.length; i++) {
      var path = document.createElementNS(SVG, "path");
      path.setAttribute("d", paths[i]);
      path.setAttribute("class", "icon-stroke");
      svg.appendChild(path);
    }
    return svg;
  }
  window.QuesynthIcon = makeIcon;

  function optionIcon(spec, param, position) {
    if ([0, 1, 14, 42, 47, 96].indexOf(param.i) < 0) return null;
    var label = ((spec.options && spec.options[position]) || valueText(param, position)).toLowerCase();
    var name = label.indexOf("sample") >= 0 ? "sample" :
      label.indexOf("random smooth") >= 0 ? "random" : label.indexOf("sine") >= 0 ? "sine" :
      label.indexOf("saw") >= 0 ? "saw" : label.indexOf("pulse") >= 0 || label.indexOf("square") >= 0 ? "pulse" :
      label.indexOf("triangle") >= 0 ? "triangle" : label.indexOf("noise") >= 0 ? "noise" :
      label.indexOf("high pass") >= 0 ? "highpass" : label.indexOf("band pass") >= 0 ? "bandpass" : "lowpass";
    return makeIcon(name, "option-icon");
  }

  function decorateIcons() {
    var nodes = document.querySelectorAll("[data-icon]");
    for (var i = 0; i < nodes.length; i++) {
      if (!nodes[i].querySelector("svg.icon"))
        nodes[i].insertBefore(makeIcon(nodes[i].getAttribute("data-icon")), nodes[i].firstChild);
    }
  }

  // The arc runs from seven o'clock to five o'clock, the 270 degrees a hardware
  // knob has, leaving the gap at the bottom where the pointer never goes.
  var A0 = 135, A1 = 405;

  function polar(cx, cy, r, deg) {
    var rad = (deg - 90) * Math.PI / 180;
    return [cx + r * Math.cos(rad), cy + r * Math.sin(rad)];
  }

  function arcPath(cx, cy, r, from, to) {
    var a = polar(cx, cy, r, from), b = polar(cx, cy, r, to);
    var large = Math.abs(to - from) > 180 ? 1 : 0;
    return "M " + a[0].toFixed(2) + " " + a[1].toFixed(2) +
           " A " + r + " " + r + " 0 " + large + " 1 " + b[0].toFixed(2) + " " + b[1].toFixed(2);
  }

  function makeKnob(spec, param) {
    var svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("class", "knob");
    svg.setAttribute("viewBox", "0 0 100 100");
    svg.setAttribute("tabindex", "0");
    svg.setAttribute("role", "slider");
    svg.setAttribute("aria-label", spec.name);
    svg.setAttribute("aria-valuemin", "0");
    svg.setAttribute("aria-valuemax", String(Math.max(0, param.n - 1)));

    // The metal: a vertical gradient, lit along the top edge.
    var defs = document.createElementNS(SVG, "defs");
    var gid = "metal" + param.i;
    defs.innerHTML =
      '<linearGradient id="' + gid + '" x1="0" y1="0" x2="0" y2="1">' +
      '<stop offset="0%" stop-color="#c9c9d1"/>' +
      '<stop offset="42%" stop-color="#7e7e88"/>' +
      '<stop offset="100%" stop-color="#3a3a41"/></linearGradient>';
    svg.appendChild(defs);

    var track = document.createElementNS(SVG, "path");
    track.setAttribute("class", "track");
    track.setAttribute("d", arcPath(50, 50, 40, A0, A1));
    track.setAttribute("fill", "none");
    track.setAttribute("stroke-width", "5");
    track.setAttribute("stroke-linecap", "round");
    svg.appendChild(track);

    var arc = document.createElementNS(SVG, "path");
    arc.setAttribute("class", "arc");
    arc.setAttribute("fill", "none");
    arc.setAttribute("stroke-width", "5");
    arc.setAttribute("stroke-linecap", "round");
    svg.appendChild(arc);

    var body = document.createElementNS(SVG, "circle");
    body.setAttribute("cx", "50");
    body.setAttribute("cy", "50");
    body.setAttribute("r", "28");
    body.setAttribute("fill", "url(#" + gid + ")");
    svg.appendChild(body);

    var face = document.createElementNS(SVG, "circle");
    face.setAttribute("cx", "50");
    face.setAttribute("cy", "50");
    face.setAttribute("r", "24");
    face.setAttribute("fill", "#141418");
    svg.appendChild(face);

    var pointer = document.createElementNS(SVG, "line");
    pointer.setAttribute("class", "pointer");
    pointer.setAttribute("stroke-width", "3");
    pointer.setAttribute("stroke-linecap", "round");
    svg.appendChild(pointer);

    function paint() {
      var position = positionOf(param, values[param.i]);
      var t = param.n > 1 ? position / (param.n - 1) : 0;
      var angle = A0 + t * (A1 - A0);
      // A zero-length arc still draws a dot with a round cap, so it is omitted.
      arc.setAttribute("d", t > 0.001 ? arcPath(50, 50, 40, A0, angle) : "");
      var inner = polar(50, 50, 12, angle), outer = polar(50, 50, 24, angle);
      pointer.setAttribute("x1", inner[0].toFixed(2));
      pointer.setAttribute("y1", inner[1].toFixed(2));
      pointer.setAttribute("x2", outer[0].toFixed(2));
      pointer.setAttribute("y2", outer[1].toFixed(2));
      svg.setAttribute("aria-valuenow", String(position));
      // Spoken from the same source the panel prints, so a conditional reading is
      // not silently read out as a bare integer to anyone using a screen reader.
      var f = typeof spec.formatValue === "function"
        ? spec.formatValue(position, positionAt)
        : null;
      svg.setAttribute("aria-valuetext", f
        ? (f.unit ? f.value + " " + f.unit : f.value)
        : valueText(param, position));
    }

    // Dragging. Vertical, and the travel is scaled so the whole range takes about
    // 200 pixels regardless of how many positions the parameter has -- a 128-step
    // filter cutoff and a 3-step routing switch should feel the same under the
    // finger. Holding shift divides the rate for fine work.
    var dragging = false, startY = 0, startPos = 0, pointerId = null;

    function pixelsPerRange(e) { return e && e.shiftKey ? 900 : 200; }

    svg.addEventListener("pointerdown", function (e) {
      dragging = true;
      pointerId = e.pointerId;
      startY = e.clientY;
      startPos = positionOf(param, values[param.i]);
      svg.classList.add("active");
      capture(svg, pointerId);
      bridge.beginEdit(param.i);
      e.preventDefault();
    });

    svg.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      var dy = startY - e.clientY;
      var steps = Math.round(dy / pixelsPerRange(e) * (param.n - 1));
      var next = Math.max(0, Math.min(param.n - 1, startPos + steps));
      setPosition(param.i, next);
    });

    function release() {
      if (!dragging) return;
      dragging = false;
      svg.classList.remove("active");
      if (pointerId !== null) uncapture(svg, pointerId);
      pointerId = null;
      bridge.endEdit(param.i);
    }
    svg.addEventListener("pointerup", release);
    svg.addEventListener("pointercancel", release);

    // Double click or double tap returns the control to the reference's default.
    svg.addEventListener("dblclick", function () {
      setPosition(param.i, positionOf(param, param.def));
    });

    svg.addEventListener("keydown", function (e) {
      var position = positionOf(param, values[param.i]);
      var step = e.shiftKey ? 1 : Math.max(1, Math.round(param.n / 32));
      if (e.key === "ArrowUp" || e.key === "ArrowRight") { setPosition(param.i, position + step); }
      else if (e.key === "ArrowDown" || e.key === "ArrowLeft") { setPosition(param.i, position - step); }
      else if (e.key === "Home") { setPosition(param.i, 0); }
      else if (e.key === "End") { setPosition(param.i, param.n - 1); }
      else return;
      e.preventDefault();
    });

    return { el: svg, paint: paint };
  }

  // ------------------------------------------------------------------- toggle

  function makeToggle(spec, param) {
    var btn = document.createElement("button");
    btn.className = "toggle";
    btn.setAttribute("role", "switch");
    btn.setAttribute("aria-label", spec.name);
    btn.type = "button";

    function paint() {
      var on = positionOf(param, values[param.i]) > 0;
      btn.setAttribute("aria-checked", on ? "true" : "false");
    }
    btn.addEventListener("click", function () {
      var on = positionOf(param, values[param.i]) > 0;
      setPosition(param.i, on ? 0 : 1);
    });
    return { el: btn, paint: paint };
  }

  // ------------------------------------------------------------------- radio

  // A list of lit options, which is what the reference does for its type
  // controls and is plainly better than a dropdown for them.
  //
  // A dropdown hides every choice but one, so "which filter types are there" and
  // "is this a band pass" both cost a click. With five states there is no reason
  // to hide four of them. It is kept for the effect unit alone, where ten states
  // in a column would be taller than the section it sits in.
  function makeRadio(spec, param) {
    var group = document.createElement("div");
    group.className = "radio";
    group.setAttribute("role", "radiogroup");
    group.setAttribute("aria-label", spec.name || spec.label);

    var buttons = [];
    for (var i = 0; i < param.n; i++) {
      (function (position) {
        var b = document.createElement("button");
        b.type = "button";
        b.setAttribute("role", "radio");

        var dot = document.createElement("span");
        dot.className = "dot";
        var glyph = optionIcon(spec, param, position);
        if (glyph) { dot.classList.add("has-glyph"); dot.appendChild(glyph); }
        b.appendChild(dot);

        var text = document.createElement("span");
        text.textContent = (spec.options && spec.options[position]) ||
          valueText(param, position);
        b.appendChild(text);

        b.addEventListener("click", function () {
          bridge.beginEdit(param.i);
          setPosition(param.i, position);
          bridge.endEdit(param.i);
        });
        group.appendChild(b);
        buttons.push(b);
      })(i);
    }

    function paint() {
      var position = positionOf(param, values[param.i]);
      for (var i = 0; i < buttons.length; i++) {
        buttons[i].setAttribute("aria-checked", i === position ? "true" : "false");
      }
    }
    return { el: group, paint: paint };
  }

  // ----------------------------------------------------------------- stepper

  // A number with a step either side, for the controls that are counts.
  //
  // Polyphony and the unison voice count are small whole numbers, and a knob is
  // the wrong instrument for a small whole number: it takes a careful drag to land
  // on "4" and the value has to be read back to find out whether it did. The
  // reference shows these as a numeric display with steps, and it is right to.
  function makeStepper(spec, param) {
    var wrap = document.createElement("div");
    wrap.className = "stepper";

    function step(by) {
      var b = document.createElement("button");
      b.type = "button";
      // Drawn, not typed. The accessible name is on the button, and the glyph is
      // hidden from it, so the only thing that changes is that the mark is ours.
      b.appendChild(makeIcon(by < 0 ? "minus" : "plus"));
      b.setAttribute("aria-label", (by < 0 ? "Less " : "More ") + (spec.name || spec.label));
      b.addEventListener("click", function () {
        bridge.beginEdit(param.i);
        setPosition(param.i, positionOf(param, values[param.i]) + by);
        bridge.endEdit(param.i);
      });
      return b;
    }

    var down = step(-1);
    var num = document.createElement("div");
    num.className = "num";
    var up = step(1);

    wrap.appendChild(down);
    wrap.appendChild(num);
    wrap.appendChild(up);

    function paint() {
      var position = positionOf(param, values[param.i]);
      num.textContent = valueText(param, position);
      down.disabled = position <= 0;
      up.disabled = position >= param.n - 1;
    }
    return { el: wrap, paint: paint };
  }

  // ------------------------------------------------------------------ choice

  // A dropdown over values the layout supplies, for the parameters that carry a
  // raw number instead of a state list.
  //
  // The four controller-routing parameters are the only ones like this in the
  // instrument: they read back as a fraction of 65536 rather than as states, so
  // `params.js` has no `v` for them and every other control here would show an
  // index. The values are written out in the layout instead, and this sends them
  // through unchanged rather than through `storedOf`.
  function makeChoice(spec, param) {
    var sel = document.createElement("select");
    sel.className = "options";
    sel.setAttribute("aria-label", spec.name || spec.label);

    spec.choices.forEach(function (c) {
      var opt = document.createElement("option");
      opt.value = String(c.v);
      opt.textContent = c.label;
      sel.appendChild(opt);
    });

    function paint() {
      var v = values[param.i];
      sel.value = String(v);
      // A patch can name a source or a destination this list does not offer, and
      // showing the first entry would quietly relabel it. Say so instead.
      if (sel.selectedIndex < 0) {
        var unknown = sel.querySelector("option[data-unknown]");
        if (!unknown) {
          unknown = document.createElement("option");
          unknown.setAttribute("data-unknown", "");
          sel.appendChild(unknown);
        }
        unknown.value = String(v);
        unknown.textContent = "Other (" + v + ")";
        sel.value = String(v);
      }
    }

    sel.addEventListener("change", function () {
      var v = parseInt(sel.value, 10);
      if (values[param.i] === v) return;
      values[param.i] = v;
      onChanged(param.i);
      bridge.setParam(param.i, v);
    });

    return { el: sel, paint: paint };
  }

  // ------------------------------------------------------------------ options

  function makeOptions(spec, param) {
    var sel = document.createElement("select");
    sel.className = "options";
    sel.setAttribute("aria-label", spec.name);

    for (var i = 0; i < param.n; i++) {
      var opt = document.createElement("option");
      opt.value = String(i);
      // The authored name where there is one, and the reference's own display
      // where the layout has not named that state. A state the layout forgot
      // should look unfinished, not invisible.
      opt.textContent = (spec.options && spec.options[i]) || valueText(param, i);
      sel.appendChild(opt);
    }

    function paint() { sel.value = String(positionOf(param, values[param.i])); }
    sel.addEventListener("change", function () {
      bridge.beginEdit(param.i);
      setPosition(param.i, parseInt(sel.value, 10));
      bridge.endEdit(param.i);
    });
    return { el: sel, paint: paint };
  }

  // -------------------------------------------------------------------- build

  function buildControl(spec) {
    var param = byIndex[spec.p];
    if (!param) return null;

    // Normalised up front, because the layout leaves `kind` off a knob entirely
    // and every test below wants a real name to compare against. A switch is
    // demoted to a knob when the parameter turns out to have more than two states,
    // so a layout entry that is wrong about a parameter degrades rather than
    // renders a two-position control over a hundred-position parameter.
    var kind = spec.kind || "knob";
    if (kind === "toggle" && param.n !== 2) kind = "knob";

    var full = spec.name || spec.label;

    var wrap = document.createElement("div");
    wrap.className = "control" +
      (spec.wide ? " wide" : "") +
      (kind === "options" || kind === "choice" ? " has-options" : "") +
      (kind === "radio" ? " has-radio" : "") +
      (kind === "stepper" ? " has-stepper" : "");
    wrap.title = full + (spec.desc ? " — " + spec.desc : "");

    var label = document.createElement("div");
    label.className = "label";
    // The short label, which the stylesheet holds to one line. The full name is
    // not lost -- it heads the information popover, along with the description.
    label.textContent = spec.label || spec.name;
    wrap.appendChild(label);

    // The active variant, for a control whose meaning follows another parameter.
    // Null when the control means one thing always, which is all but two of them.
    var variant = null;
    var setDisabled = makeDisabler(wrap);
    wrap.__disable = setDisabled;

    var info = document.createElement("button");
    info.type = "button";
    info.className = "info";
    info.textContent = "i";
    info.setAttribute("aria-label", "About " + full);
    info.addEventListener("click", function (e) {
      e.stopPropagation();
      showInfo(info,
        variant ? variant.name : full,
        variant ? variant.desc : spec.desc,
        param);
    });
    wrap.appendChild(info);
    var made = kind === "toggle" ? makeToggle(spec, param)
             : kind === "choice" ? makeChoice(spec, param)
             : kind === "options" ? makeOptions(spec, param)
             : kind === "radio" ? makeRadio(spec, param)
             : kind === "stepper" ? makeStepper(spec, param)
             : makeKnob(spec, param);
    wrap.appendChild(made.el);

    // Only a knob and a switch need a reading spelled out beneath them. The other
    // three carry theirs inside the control -- the lit option, the number between
    // the steps -- and repeating it underneath would be saying the same thing
    // twice in a panel that is trying to be quiet.
    var readout = null;
    if (kind === "knob" || kind === "toggle") {
      readout = document.createElement("div");
      readout.className = "value";
      wrap.appendChild(readout);
    }

    function refresh() {
      made.paint();
      if (!readout) return;
      var position = positionOf(param, values[param.i]);

      // A control whose reading depends on another parameter supplies a
      // formatter that returns the number and its unit already separated: the
      // LFO depth in semitones only while it drives pitch, an effect control in
      // the unit of the type currently selected. The formatter is handed the
      // resolver above so it can ask what position the parameter it follows is
      // on, and it returns
      // nothing when the current setting has no measured unit -- then the honest
      // bare integer below is shown instead of a suffix that would only be true
      // for another setting.
      var formatted = kind !== "toggle" && typeof spec.formatValue === "function"
        ? spec.formatValue(position, positionAt)
        : null;
      if (formatted) {
        readout.textContent = "";
        readout.appendChild(document.createTextNode(formatted.value));
        if (formatted.unit) {
          var fu = document.createElement("span");
          fu.className = "unit";
          fu.textContent = formatted.unit;
          readout.appendChild(fu);
        }
        return;
      }

      // A switch reads out as a word. The stored value of a two-state parameter
      // is 0 or 1, and printing that under a switch tells the player nothing
      // they cannot already see from the switch itself.
      var text = kind === "toggle"
        ? (position > 0 ? "On" : "Off")
        : valueText(param, position);

      // The number and its unit are separate elements so the unit can be greyed
      // wherever it came from. Some readings carry their own unit inside the
      // string the reference prints -- "15.12 msec", "+15 cent" -- and others
      // get one from the generated table's suffix. Both end up in the same span
      // rather than only the second, which is what made "cent" grey and "kHz"
      // white before.
      var parts = splitUnit(text);
      readout.textContent = "";
      readout.appendChild(document.createTextNode(parts.value));

      var unit = parts.unit || (param.unit && !/[a-zA-Z%]/.test(text) ? param.unit : "");
      if (unit) {
        var u = document.createElement("span");
        u.className = "unit";
        u.textContent = unit;
        readout.appendChild(u);
      }
    }

    // A control whose meaning depends on another parameter, which the effect
    // unit's two are: relabelled whenever the type changes.
    if (spec.depends != null && spec.variants) {
      var relabel = function () {
        var owner = byIndex[spec.depends];
        if (!owner) return;
        var v = spec.variants[positionOf(owner, values[spec.depends])];
        if (!v) return;
        label.textContent = v.label;
        wrap.title = v.name + (v.desc ? " — " + v.desc : "");
        variant = v;
        // A control the selected type does not read is switched off rather than
        // left looking operable.
        setDisabled(!!v.inert, "inert");
        // The reading follows the type too: its unit is the selected effect's,
        // so repaint it, not just the label.
        refresh();
      };
      dependOn(spec.depends, relabel);
      // Once now, so the control opens with the label its current type calls for
      // rather than with the placeholder in the layout.
      relabel();
    }

    // A control whose label is fixed but whose reading follows another parameter
    // -- the LFO depth's semitones track its destination -- repaints when that
    // parameter moves. This is separate from `depends`, which also rewrites the
    // label.
    if (spec.valueDepends) {
      for (var vd = 0; vd < spec.valueDepends.length; vd++) {
        dependOn(spec.valueDepends[vd], refresh);
      }
    }

    controls[spec.p] = refresh;
    refresh();
    return wrap;
  }

  // Switching a control off, from either of two independent reasons: the section's
  // own enable is off, or the selected effect type does not read it. They are
  // tracked separately so that turning the effect unit back on does not re-enable
  // a control the ring modulator still ignores.
  function makeDisabler(wrap) {
    var reasons = {};
    return function (off, reason) {
      reasons[reason || "enable"] = !!off;
      var any = false;
      for (var k in reasons) if (reasons[k]) any = true;

      wrap.classList.toggle("off", any);
      var fields = wrap.querySelectorAll("button, select");
      for (var i = 0; i < fields.length; i++) {
        // The information mark stays live: what a control does is worth reading
        // whether or not it is currently doing it.
        if (fields[i].classList.contains("info")) continue;
        fields[i].disabled = any;
      }
      var knob = wrap.querySelector(".knob");
      if (knob) {
        if (any) knob.setAttribute("tabindex", "-1");
        else knob.setAttribute("tabindex", "0");
      }
    };
  }

  // ----------------------------------------------------------------- the info

  // One popover, moved to whichever control asked for it.
  //
  // This replaces a switch in the footer that revealed every description at once.
  // That switch had to be found before it helped, and once thrown it tripled the
  // height of the panel to answer a question about one control. Asking at the
  // control is the same information at the moment it is wanted.
  var popover = null;

  function hideInfo() {
    if (popover) popover.classList.remove("open");
  }

  // Whether the popover is the layer on top at this moment. The pad shell's
  // editor drawer asks before it answers Escape: both listen on `document`, so
  // without this one press would dismiss the popover and the editor beneath it.
  function infoOpen() {
    return !!popover && popover.classList.contains("open");
  }
  window.SynthInfo = { isOpen: infoOpen };

  function showInfo(anchor, title, desc, param) {
    if (!popover) {
      popover = document.createElement("div");
      popover.className = "popover";
      popover.addEventListener("click", function (e) { e.stopPropagation(); });
      document.body.appendChild(popover);
      // Anywhere else, escape, or a scroll dismisses it.
      document.addEventListener("click", hideInfo);
      document.addEventListener("scroll", hideInfo, { passive: true });
      document.addEventListener("keydown", function (e) {
        if (e.key === "Escape") hideInfo();
      });
    }

    popover.textContent = "";

    var h = document.createElement("div");
    h.className = "popover-title";
    h.textContent = title;
    popover.appendChild(h);

    if (desc) {
      var d = document.createElement("p");
      d.textContent = desc;
      popover.appendChild(d);
    }

    // What the control actually is underneath: which parameter, and how many
    // positions it has. Useful when reading a patch against the .sy1 file or
    // against the measurements, and invisible until asked for.
    var meta = document.createElement("div");
    meta.className = "popover-meta";
    meta.textContent = "Parameter " + param.i + " · " + param.n + " steps";
    popover.appendChild(meta);

    popover.classList.add("open");

    // Placed under the control, then pulled back inside the window if that would
    // push it off an edge -- which it does for anything in the rightmost column.
    var r = anchor.getBoundingClientRect();
    var w = popover.offsetWidth;
    var left = Math.min(
      Math.max(8, r.left + r.width / 2 - w / 2),
      window.innerWidth - w - 8
    );
    var top = r.bottom + 8;
    if (top + popover.offsetHeight > window.innerHeight - 8) {
      top = Math.max(8, r.top - popover.offsetHeight - 8);
    }
    popover.style.left = Math.round(left) + "px";
    popover.style.top = Math.round(top) + "px";
  }

  function slug(title) {
    return title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  }

  function build() {
    var main = document.getElementById("panels");
    var sections = [];

    LAYOUT.forEach(function (panel) {
      var section = document.createElement("section");
      section.className = "panel";
      section.id = slug(panel.title);

      var h = document.createElement("h2");
      h.textContent = panel.title;
      section.appendChild(h);

      // A panel is a list of groups. A flat `controls` list is still accepted and
      // treated as one unlabelled group, so a panel that has no natural division
      // does not have to invent one.
      var groups = panel.groups ||
        [{ label: null, controls: panel.controls || [] }];
      var built = 0;

      var row = document.createElement("div");
      row.className = "groups";

      // Collected so an enable can be told what it governs once the whole panel
      // exists. A section's enable normally sits in a different group from the
      // controls it switches -- the LFO's is under "Routing" and its speed and
      // depth are under "Motion" -- so this cannot be resolved group by group.
      var inPanel = [];
      var governors = [];

      groups.forEach(function (group) {
        var box = document.createElement("div");
        box.className = "group";

        if (group.label) {
          var gh = document.createElement("div");
          gh.className = "group-label";
          gh.textContent = group.label;
          box.appendChild(gh);
        }

        var grid = document.createElement("div");
        grid.className = "controls";
        var here = 0;
        var inGroup = [];
        group.controls.forEach(function (spec) {
          var el = buildControl(spec);
          if (!el) return;
          grid.appendChild(el);
          here++;
          var entry = { spec: spec, el: el };
          inGroup.push(entry);
          inPanel.push(entry);
          if (spec.governs) governors.push({ spec: spec, scope: inGroup });
        });
        box.appendChild(grid);
        if (here > 0) { row.appendChild(box); built += here; }
      });
      section.appendChild(row);

      governors.forEach(function (g) {
        var scope = g.spec.governs === "group" ? g.scope : inPanel;
        var owner = byIndex[g.spec.p];
        if (!owner) return;
        var apply = function () {
          var on = positionOf(owner, values[g.spec.p]) > 0;
          scope.forEach(function (entry) {
            // The switch itself stays live, or there would be no way back on.
            if (entry.spec.p === g.spec.p) return;
            if (entry.el.__disable) entry.el.__disable(!on);
          });
        };
        dependOn(g.spec.p, apply);
        apply();
      });
      // A section whose parameters all failed to resolve is not shown, and must
      // not get a navigation entry pointing at nothing either.
      if (built > 0) {
        main.appendChild(section);
        sections.push({ id: section.id, title: panel.title, el: section });
      }
    });

    buildNav(sections);
  }

  function buildNav(sections) {
    var inner = document.querySelector("#navigator .nav-inner");
    var main = document.getElementById("panels");
    if (!inner || !main || !sections.length) return;
    var buttons = {};
    var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

    sections.forEach(function (s) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = s.title;
      b.setAttribute("aria-current", "false");
      b.addEventListener("click", function () {
        main.scrollTo({
          top: s.el.offsetTop - main.offsetTop,
          behavior: reduced.matches ? "auto" : "smooth",
        });
      });
      b.addEventListener("focus", function () {
        b.scrollIntoView({ block: "nearest", inline: "nearest" });
      });
      inner.appendChild(b);
      buttons[s.id] = b;
    });

    var marked = null;
    function updateCurrent() {
      var line = main.getBoundingClientRect().top + 8;
      var current = sections[0].id;
      for (var i = 0; i < sections.length; i++) {
        if (sections[i].el.getBoundingClientRect().top <= line) current = sections[i].id;
      }
      if (current === marked) return;
      marked = current;
      sections.forEach(function (s) {
        buttons[s.id].setAttribute("aria-current", s.id === current ? "true" : "false");
      });
      buttons[current].scrollIntoView({ block: "nearest", inline: "nearest" });
    }

    // Give a short final section exactly enough trailing room to reach the top
    // of this editor's own scroller. The keyboard changes the editor height via
    // --keys-h, so measuring the scroller here keeps one source of truth.
    function sizeTail() {
      main.style.paddingBottom = "0px";
      var last = sections[sections.length - 1].el;
      var missing = main.clientHeight - last.getBoundingClientRect().height;
      main.style.paddingBottom = Math.max(8, Math.round(missing)) + "px";
    }

    var queued = false;
    function onScroll() {
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () {
        queued = false;
        updateCurrent();
      });
    }
    function onResize() { sizeTail(); onScroll(); }
    relayout = onResize;
    main.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onResize, { passive: true });
    // In pad.html this scroller is initially inside a hidden drawer. Observe
    // its own box so opening the drawer sizes the tail without duplicating an
    // editor-height calculation in pad.js.
    if (window.ResizeObserver) new ResizeObserver(onResize).observe(main);
    sizeTail();
    updateCurrent();
  }

  // ---------------------------------------------------------------- keyboard

  // A real 88-key range on the desktop, A0 to C8, and a five-octave window on a
  // phone where a full board would put every key under a millimetre.
  //
  // The desktop board is sized to the window rather than to a fixed key width:
  // 52 white keys across whatever is available, which is what stops a wide
  // display showing a short keyboard against a field of empty space. The phone
  // keeps a fixed, finger-sized key and scrolls, because there the size is the
  // constraint and the range is what gives.
  var KEY_FULL_LOW = 21;    // A0
  var KEY_FULL_HIGH = 108;  // C8
  // How much of the board a phone shows when it is turned on its side.
  //
  // Landscape is the one case where width is plentiful and *height* is not,
  // so the keys can be wide without the panel eating the screen. Two octaves
  // across the window puts a white key near 58px on a typical phone -- wider
  // than the 45px portrait uses, which is the point: in landscape the phone
  // is being played with two hands rather than prodded with one thumb.
  var KEY_LANDSCAPE_OCTAVES = 2;

  // Every layout retains the complete piano range; narrow layouts scroll it.
  var WHITE_SEMITONES = [0, 2, 4, 5, 7, 9, 11];
  // Which white key each black one sits after, within an octave.
  var BLACK_AFTER = [0, 1, 3, 4, 5];
  var BLACK_SEMITONES = [1, 3, 6, 8, 10];
  var NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

  function isWhiteNote(note) {
    return WHITE_SEMITONES.indexOf(note % 12) >= 0;
  }

  function noteName(note) {
    return NOTE_NAMES[note % 12] + (Math.floor(note / 12) - 1);
  }

  function buildKeyboard() {
    var host = document.getElementById("keys");
    var scroll = document.getElementById("keys-scroll");
    var label = document.getElementById("oct-label");
    var toggle = document.getElementById("keys-toggle");
    var panel = document.getElementById("keyboard");
    if (!host || !toggle) return;

    var low = KEY_FULL_LOW;
    var high = KEY_FULL_HIGH;

    var byNote = {};
    var whiteIndex = {};
    var whiteCount = 0;
    var white = 26;
    var black = 16;

    for (var n = low; n <= high; n++) {
      if (isWhiteNote(n)) {
        whiteIndex[n] = whiteCount;
        whiteCount++;
      }
    }

    // Naturals first, then accidentals, so the black keys sit over the white
    // ones by document order without a z-index fight.
    for (n = low; n <= high; n++) {
      if (!isWhiteNote(n)) continue;
      var k = document.createElement("button");
      k.type = "button";
      k.className = "key natural" + (n === 60 ? " anchor" : "");
      k.dataset.note = String(n);
      k.setAttribute("aria-label", noteName(n));
      host.appendChild(k);
      byNote[n] = k;
    }
    for (n = low; n <= high; n++) {
      if (isWhiteNote(n)) continue;
      var kb = document.createElement("button");
      kb.type = "button";
      kb.className = "key accidental";
      kb.dataset.note = String(n);
      kb.setAttribute("aria-label", noteName(n));
      host.appendChild(kb);
      byNote[n] = kb;
    }

    var seam = 0;

    // Sizing is separate from building so a resize does not have to rebuild the
    // elements and re-bind every listener on them.
    function layoutKeys() {
      var avail = (scroll ? scroll.clientWidth : host.clientWidth) || 0;
      // Portrait phone: narrow window, so the range scrolls under a fixed,
      // finger-sized key.
      var isPhone = window.matchMedia("(max-width: 560px)").matches;
      // A phone on its side: wide but short. Bounded above on width as well, or
      // a merely short desktop window -- a laptop with the browser half-height --
      // would get a two-octave keyboard it has no use for.
      var isPhoneLandscape = window.matchMedia(
        "(orientation: landscape) and (max-height: 560px) and (max-width: 1024px)").matches;

      if (isPhoneLandscape && avail > 0) {
        // Exactly two octaves across the window. 7 naturals to the octave.
        white = Math.max(28, Math.floor(avail / (KEY_LANDSCAPE_OCTAVES * 7)));
      } else if (isPhone) {
        // Wide enough for a fingertip: 45px is about a finger pad, and below
        // roughly 40 the accidentals get too narrow to hit without catching the
        // natural beside them.
        white = 45;
      } else {
        // Fill the window exactly. The floor keeps a very narrow desktop window
        // from producing keys too thin to hit, at which point the strip scrolls
        // again as it always did.
        white = Math.max(14, Math.floor(avail / whiteCount));
      }
      black = Math.round(white * 0.62);

      for (var note in byNote) {
        var el = byNote[note];
        var num = parseInt(note, 10);
        if (isWhiteNote(num)) {
          el.style.left = (whiteIndex[num] * white) + "px";
          el.style.width = white + "px";
        } else {
          // On the seam between the two naturals it divides: the natural below
          // it is always note-1, which is white for every accidental.
          el.style.left = ((whiteIndex[num - 1] + 1) * white - black / 2) + "px";
          el.style.width = black + "px";
        }
      }
      seam = whiteCount * white;
      host.style.width = seam + "px";
    }
    layoutKeys();

    var layoutPending = null;
    // Rotating a phone fires both of these on different browsers, and the
    // viewport is not always updated by the time the first one arrives, so the
    // debounce below is doing double duty as a settle delay.
    window.addEventListener("orientationchange", function () {
      if (layoutPending) clearTimeout(layoutPending);
      layoutPending = setTimeout(function () {
        layoutPending = null;
        layoutKeys();
      }, 200);
    });
    window.addEventListener("resize", function () {
      if (layoutPending) clearTimeout(layoutPending);
      layoutPending = setTimeout(function () {
        layoutPending = null;
        layoutKeys();
      }, 120);
    });

    // -- playing ------------------------------------------------------------

    // One note per pointer, so two fingers are two notes and lifting one does not
    // silence the other.
    var sounding = {};

    function noteOn(pointerId, note) {
      if (sounding[pointerId] === note) return;
      noteOff(pointerId);
      sounding[pointerId] = note;
      if (byNote[note]) byNote[note].classList.add("down");
      bridge.note(true, note, 100);
    }

    function noteOff(pointerId) {
      var note = sounding[pointerId];
      if (note == null) return;
      delete sounding[pointerId];
      // Only unlight the key if no other pointer is still holding it.
      var held = external[note] > 0;
      for (var id in sounding) if (sounding[id] === note) held = true;
      if (!held && byNote[note]) byNote[note].classList.remove("down");
      bridge.note(false, note, 0);
    }

    // Notes arriving from somewhere other than this keyboard -- a MIDI
    // controller -- light the keys without being echoed back as new notes.
    // `midi.js` has already handed them to the bridge; this is only the
    // picture. Counted rather than set, so a note held on the controller and
    // also pressed on screen stays lit until both let go.
    var external = {};

    function stillHeld(note) {
      if (external[note] > 0) return true;
      for (var id in sounding) if (sounding[id] === note) return true;
      return false;
    }

    window.SynthKeys = {
      down: function (note) {
        external[note] = (external[note] || 0) + 1;
        if (byNote[note]) byNote[note].classList.add("down");
      },
      up: function (note) {
        if (external[note]) external[note] -= 1;
        if (!stillHeld(note) && byNote[note]) byNote[note].classList.remove("down");
      },
    };

    function noteAt(x, y) {
      var el = document.elementFromPoint(x, y);
      if (!el || !el.dataset || el.dataset.note == null) return null;
      return parseInt(el.dataset.note, 10);
    }

    host.addEventListener("pointerdown", function (e) {
      var note = noteAt(e.clientX, e.clientY);
      if (note == null) return;
      capture(host, e.pointerId);
      noteOn(e.pointerId, note);
      e.preventDefault();
    });

    // Sliding across the keys is a glissando, which is why the strip does not
    // scroll under a drag.
    host.addEventListener("pointermove", function (e) {
      if (sounding[e.pointerId] == null) return;
      var note = noteAt(e.clientX, e.clientY);
      if (note != null) noteOn(e.pointerId, note);
    });

    function release(e) { noteOff(e.pointerId); }
    host.addEventListener("pointerup", release);
    host.addEventListener("pointercancel", release);
    // A pointer that leaves the window entirely never reports up.
    window.addEventListener("blur", function () {
      for (var id in sounding) noteOff(id);
    });

    // -- the visible octave -------------------------------------------------

    function shownRange() {
      var first = Math.floor(scroll.scrollLeft / white);
      var count = Math.max(1, Math.round(scroll.clientWidth / white));
      var lastWhite = Math.min(whiteCount - 1, first + count - 1);
      function noteOfWhite(i) {
        // The i-th white key of the built range, whatever that range starts on.
        var seen = 0;
        for (var n = low; n <= high; n++) {
          if (!isWhiteNote(n)) continue;
          if (seen === i) return n;
          seen++;
        }
        return low;
      }
      return noteName(noteOfWhite(Math.min(first, whiteCount - 1))) + " – " +
             noteName(noteOfWhite(lastWhite));
    }

    var octButtons = panel.querySelectorAll(".oct");
    function refreshBar() {
      if (label) label.textContent = shownRange();
      var atStart = scroll.scrollLeft <= 1;
      var atEnd = scroll.scrollLeft >= scroll.scrollWidth - scroll.clientWidth - 1;
      octButtons[0].disabled = atStart;
      octButtons[1].disabled = atEnd;
    }

    for (var i = 0; i < octButtons.length; i++) {
      (function (btn) {
        btn.addEventListener("click", function () {
          scroll.scrollBy({ left: parseInt(btn.dataset.step, 10) * 7 * white, behavior: "smooth" });
        });
      })(octButtons[i]);
    }
    scroll.addEventListener("scroll", refreshBar, { passive: true });

    // -- deploying ----------------------------------------------------------

    var onDeploy = null;

    toggle.addEventListener("click", function () {
      var open = panel.hasAttribute("hidden");
      if (open) {
        panel.removeAttribute("hidden");
        // Size the board now it has a width to be sized against. Until the panel
        // is shown its scroller measures zero, and a full-width desktop board
        // laid out against zero collapses onto its minimum key width.
        layoutKeys();
        // Opens with middle C as the leftmost key, so the octave above it is what
        // is under the hand. Centring it instead was tried and puts half the
        // visible keys below the note most playing starts from -- on a phone that
        // is four of the eight.
        //
        // Measured off the anchor key rather than counted: the arithmetic version
        // of this put middle C at the twenty-eighth white key when it is the
        // twenty-first. The element knows where it is.
        var anchor = host.querySelector(".key.anchor");
        scroll.scrollLeft = anchor ? anchor.offsetLeft : 0;
      } else {
        panel.setAttribute("hidden", "");
        for (var id in sounding) noteOff(id);
      }
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      document.body.classList.toggle("keys-open", open);
      refreshBar();
      if (onDeploy) onDeploy();
    });

    return {
      height: function () {
        return panel.hasAttribute("hidden") ? 0 : panel.getBoundingClientRect().height;
      },
      onDeploy: function (fn) { onDeploy = fn; },
    };
  }

  // ------------------------------------------------------------ master volume

  // Outside the engine on purpose: nothing in the .sy1 format carries a master
  // volume, so it travels as its own message rather than as a parameter. See
  // `volume` in bridge.js. Stored, so the setting survives a reload the way a
  // hardware knob survives being switched off.
  (function () {
    var slider = document.getElementById("master-vol");
    var read = document.getElementById("master-vol-read");
    if (!slider) return;

    var saved = null;
    try { saved = window.localStorage.getItem("synth1.volume"); } catch (e) {}
    if (saved !== null && saved !== "") slider.value = saved;

    function apply() {
      var pct = Number(slider.value);
      if (read) read.textContent = String(pct);
      // Square the fader so the bottom of the travel is usable: a linear
      // gain control spends most of its range on the loudest 6 dB.
      var g = (pct / 100) * (pct / 100);
      if (window.SynthVolume) window.SynthVolume(g);
      try { window.localStorage.setItem("synth1.volume", slider.value); } catch (e) {}
    }

    slider.addEventListener("input", apply);
    apply();
  })();

  // -------------------------------------------------------------------- bank

  // The patch and bank readout, the two steps either side of it, and the
  // actions beside it.
  //
  // What the panel shows is a *selection*: one explicit record of which preset
  // the sound in the engine is, kept apart from three things it was once
  // conflated with -- the bank the browser is looking at (`currentBank`), the
  // slot a Write is aimed at (browser.js), and the live parameters themselves.
  // A host that has a program of its own tells the panel what it is with
  // `patch` and `restore`; the panel never infers it by loading something.

  // A bank is a hundred and twenty-eight slots. Always, however few of them
  // hold a sound.
  //
  // That is the convention every hardware synthesiser and every soft synth
  // that grew out of one follows, and it is not decoration. A fixed slot count
  // is what makes a patch addressable by number rather than only by name, so
  // "47" means something over MIDI and in a set list; and it is what gives a
  // new sound somewhere to be saved *to*. A bank that is only as long as the
  // sounds already in it has no empty slots, and so no way to grow.
  //
  // The file on disk stays short: the factory bank is sixteen entries and is
  // padded here. An empty slot is null rather than a written-out Init patch,
  // so a saved bank is the size of what is actually in it.
  var BANK_SLOTS = 128;

  // The host's `SLOT_NAME_MAX`. The host truncates a longer name without
  // saying so, which would make the name written differ from the name stored,
  // so a name over it is refused instead.
  var NAME_MAX_BYTES = 48;

  // Where a sound came from, which decides what may be done with it.
  //
  //   factory   the bank compiled into the page, or the one a host calls that
  //   user      a bank made here, or the one a host keeps for this instrument
  //   imported  a bank opened from a file, a zip or a folder
  //   archive   a bank inside a host's shared archive: always read-only
  //   file      one patch opened from a file: a sound with no bank behind it
  //   session   the sound as it is now, with no slot behind it
  var ORIGIN_LABELS = {
    factory: "Factory", user: "User", imported: "Imported",
    archive: "Archive", file: "File", session: "Current session",
  };

  function isOrigin(text) {
    return Object.prototype.hasOwnProperty.call(ORIGIN_LABELS, text);
  }

  function isSlot(n) {
    return typeof n === "number" && n % 1 === 0 && n >= 0 && n < BANK_SLOTS;
  }

  // The sound a slot has when nothing has been put in it: every parameter at
  // its default, which is the reference plugin's own init patch.
  function initValues() {
    var out = [];
    for (var i = 0; i < PARAMS.length; i++) out.push(PARAMS[i].def);
    return out;
  }

  function normalizeBank(b) {
    var slots = new Array(BANK_SLOTS);
    for (var i = 0; i < BANK_SLOTS; i++) slots[i] = null;
    if (b && b.patches) {
      for (var j = 0; j < b.patches.length && j < BANK_SLOTS; j++) {
        var e = b.patches[j];
        // A null, or an entry with no parameters, is an empty slot.
        slots[j] = e && e.v && e.v.length ? { n: e.n || "Untitled", v: e.v.slice() } : null;
      }
    }
    return { label: (b && b.label) || "Bank", patches: slots };
  }

  // A bank, with what the panel needs to know about its standing.
  //
  //   origin     see ORIGIN_LABELS
  //   readOnly   a host said so, whatever the origin; see bankReadOnly
  //   hostOwned  it is the bank a host sent, which that host plays out of
  //   persisted  and that host keeps it: a write to it asks the host to save
  function makeBank(spec, origin) {
    var made = normalizeBank(spec);
    made.origin = origin;
    made.readOnly = false;
    made.hostOwned = false;
    made.persisted = false;
    return made;
  }

  // Every bank that is open, not just the one being played.
  //
  // Loading a file used to replace the bank outright, so the list down the side
  // of the browser only ever had one row in it and there was nothing to
  // navigate between. Holding them means a file can be *added* -- and means
  // switching away from a bank and back does not lose what was saved into it,
  // because each one keeps its own slots.
  //
  // Whether anything was compiled into the page at all. An empty bank of a
  // hundred and twenty-eight Inits is still a bank you can save into, but the
  // strip must not claim a patch is loaded before one is, and it is not a
  // *factory* bank: nobody shipped it.
  var bankSupplied = !!(window.SYNTH1_BANK && window.SYNTH1_BANK.patches &&
                        window.SYNTH1_BANK.patches.length);
  var banks = [makeBank(window.SYNTH1_BANK, bankSupplied ? "factory" : "user")];
  // The bank the browser is looking at, and the one a new sound is written to.
  // Not the bank that is playing; see `selection`.
  var currentBank = 0;
  var bank = banks[0];
  // What is loaded right now, whether it came from the bank or from a file.
  var currentName = "";

  // A shared archive is only claimed by an `archive` from the host. Other
  // hosts keep their local banks and their existing zip reader unchanged.
  // Its open bank belongs to the host; which pane we are looking at does
  // not, and neither says where the sound came from.
  var archive = null;
  var browsedArchive = -1;
  var archiveWaiting = -1;
  var archiveError = "";
  var playing = null;
  var hostBank = null;
  // The bank the host believes it is playing out of. A plugin selects patches
  // by program change from its own copy, so when the panel moves to a bank the
  // host does not hold, the host has to be given it first or "program 12"
  // means two sounds at once. Until a host says otherwise, the bank compiled
  // into the page is the one it is taken to have.
  var hostPlaying = banks[0];

  // The selection: which preset the sound in the engine is.
  //
  //   origin      see ORIGIN_LABELS
  //   source      "bank", "archive", "file" or "none": `patch.source`'s words
  //   bank        the label of its bank, "" when there is none
  //   slot        0..127 only for an ordinary slot-backed preset, else null
  //   presetName  what to call it
  //   archive     { bank, patch } for an archive preset, else null
  //
  // Invariants, each held by one function so no caller can break them:
  // a slot is only ever a factory, user or imported preset's; an archive
  // preset has no slot and carries its two indexes instead; a file or the
  // current session has neither. A sound with no slot may still say which bank
  // it is shown beside: a host that names one is not contradicted.
  function makeSelection(origin, bankLabel, slot, name, from) {
    if (!isOrigin(origin)) origin = "session";
    var ordinary = origin === "factory" || origin === "user" || origin === "imported";
    return {
      origin: origin,
      source: origin === "archive" ? "archive" : origin === "file" ? "file"
        : origin === "session" ? "none" : "bank",
      bank: String(bankLabel || ""),
      slot: ordinary && isSlot(slot) ? slot : null,
      presetName: String(name || ""),
      archive: origin === "archive" && from ? { bank: from.bank, patch: from.patch } : null,
    };
  }

  var selection = makeSelection("session", "", null, "");
  // The values the selection was loaded with, or last exported with. Only
  // consulted when the slot it names cannot answer; see `storedValues`.
  var baseline = initValues();
  var lastDirty = false;
  // Set while a whole sound is being applied, so it is judged once at the end.
  var settling = false;

  // What the host answered to the last attempt to restore a program and bank.
  // See `restoreState` in SynthBank. `failure` is the last failed answer, kept
  // while a retry is in flight so the banner still says what is being retried.
  var restoreState = { state: "notRequested" };
  var failure = null;
  // An archive load asked of the host, until it answers.
  var pendingLoad = null;
  // Banks sent with "save": true that the host has not yet answered for.
  var pendingSaves = [];
  var resultListeners = [];
  var loadListeners = [];
  var lastResult = null;
  var statusTimer = null;
  var statusSerial = 0;

  function byId(id) { return document.getElementById(id); }

  function pad3(n) {
    var s = String(n);
    return s.length >= 3 ? s : ("000" + s).slice(-3);
  }

  function liveValues() {
    var out = [];
    for (var i = 0; i < PARAMS.length; i++) {
      out.push(values[PARAMS[i].i] !== undefined ? values[PARAMS[i].i] : PARAMS[i].def);
    }
    return out;
  }

  // Repaint every control from a list of stored integers, including the ones
  // whose label follows another parameter -- a new patch can change the effect
  // type under Control 1.
  function paintValues(list) {
    for (var i = 0; i < list.length; i++) {
      if (byIndex[i] !== undefined) values[i] = list[i];
    }
    for (var k in controls) controls[k]();
    for (var d in dependents) {
      dependents[d].forEach(function (fn) { fn(); });
    }
  }

  function bankByLabel(label) {
    for (var i = 0; i < banks.length; i++) if (banks[i].label === label) return banks[i];
    return null;
  }

  // Names are how the list is read, so two banks called the same thing would
  // be two rows nobody can tell apart.
  function uniqueLabel(wanted, except) {
    var name = wanted, n = 2;
    while (banks.some(function (b) { return b !== except && b.label === name; })) {
      name = wanted + " " + n++;
    }
    return name;
  }

  // Can the panel write into this bank?
  //
  // Archive banks never. The factory bank only where something keeps what is
  // written to it: the browser build's local storage, or a host that says its
  // bank is writable. Anywhere else (a bare page, the pad shell) a write to it
  // would last until the page closes and look like it had been saved.
  function bankReadOnly(rec) {
    if (!rec || rec.origin === "archive" || rec.readOnly) return true;
    if (rec.origin === "factory" && !rec.hostOwned && !window.SynthStore) return true;
    return false;
  }

  // A bank still waiting to be read has no patches yet, only 128 empty slots
  // that would be thrown away when it loads.
  function bankUnopened(rec) {
    return !!(rec && rec.load && !rec.loaded);
  }

  // A bank named by a caller: a position in `SynthBank.list()`, or a label.
  // `archive` is set for a row of the host's archive, which the panel can
  // list and ask for but never holds.
  function resolveBank(ref) {
    var rec = null, at = -1;
    if (typeof ref === "string") {
      for (var i = 0; i < banks.length; i++) if (banks[i].label === ref) { rec = banks[i]; at = i; }
      return rec ? { rec: rec, index: at } : null;
    }
    if (typeof ref !== "number" || ref % 1 !== 0 || ref < 0) return null;
    if (archive) {
      if (ref === 0) return { rec: banks[0], index: 0 };
      return ref - 1 < archive.banks.length ? { archive: true, bank: ref - 1 } : null;
    }
    return ref < banks.length ? { rec: banks[ref], index: ref } : null;
  }

  // The bank the host plays out of: where the selection is, else where the
  // browser is.
  function playingBank() {
    var chosen = selection.bank !== "" ? bankByLabel(selection.bank) : null;
    return chosen || bank;
  }

  // -- the selection, and what it says about itself

  // What the selection is stored as, to tell whether the sound was changed.
  // The slot is asked rather than a copy kept, so a bank replaced or edited
  // under the selection is noticed; a sound with no slot behind it -- or whose
  // slot is empty -- is held against what it was loaded with.
  function storedValues(sel) {
    if (sel.slot !== null) {
      var rec = bankByLabel(sel.bank);
      var p = rec && rec.patches[sel.slot];
      if (p) return p.v;
    }
    return baseline;
  }

  function computeDirty() {
    var live = liveValues();
    var stored = storedValues(selection);
    for (var i = 0; i < live.length; i++) {
      var s = stored[i] !== undefined ? stored[i] : PARAMS[i].def;
      if (live[i] !== s) return true;
    }
    return false;
  }

  // Called on every parameter change, so it only touches the page when the
  // answer changes.
  function refreshDirty() {
    if (settling) return;
    var now = computeDirty();
    if (now === lastDirty) return;
    lastDirty = now;
    paintStrip();
  }

  function selectedReadOnly() {
    if (selection.origin === "archive") return true;
    if (selection.origin === "session" || selection.origin === "file") return false;
    var rec = bankByLabel(selection.bank);
    return rec ? bankReadOnly(rec) : false;
  }

  // Single value, in this order: a load in flight beats everything, then a
  // restore that could not be shown, then unsaved edits, then read-only.
  // `readOnly()` says the last separately, so "Read-only" can stand beside
  // "dirty" when the sound was edited in a bank that cannot take the edit.
  function computeStatus() {
    if (pendingLoad || restoreState.state === "restoring") return "loading";
    if (restoreState.state === "failed") return "unavailable";
    if (lastDirty) return "dirty";
    if (selectedReadOnly()) return "readonly";
    return "clean";
  }

  // Make something the selection, and say what its stored values are.
  // `from` is the values it was loaded with; without them, the sound as it is.
  function setSelection(next, from) {
    selection = next;
    baseline = (from || liveValues()).slice();
    lastDirty = computeDirty();
    paintStrip();
  }

  function slotInView() {
    return selection.slot !== null && selection.bank === bank.label ? selection.slot : -1;
  }

  function originChip() {
    return selection.origin === "session" ? "Unsaved" : ORIGIN_LABELS[selection.origin];
  }

  // The patch, its bank, where it came from, whether it is changed, and
  // whether it can be saved where it is. Everything but the two original
  // elements is new, and those two keep their text forms: `NNN:Name` or the
  // bare name, and the bank's label alone.
  function paintStrip() {
    var position = selection.origin === "archive"
      ? (selection.archive ? selection.archive.patch : null) : selection.slot;
    var name = selection.presetName || "Untitled";
    var patchEl = byId("bank-patch");
    if (patchEl) patchEl.textContent = (position !== null ? pad3(position) + ":" : "") + name;
    var bankEl = byId("bank-name");
    if (bankEl) bankEl.textContent = selection.bank;
    var originEl = byId("bank-origin");
    if (originEl) {
      originEl.textContent = originChip();
      originEl.setAttribute("data-origin", selection.origin);
    }
    var dirtyEl = byId("bank-dirty");
    if (dirtyEl) dirtyEl.hidden = !lastDirty;
    var strip = byId("bank");
    if (strip) {
      strip.setAttribute("data-source", selection.source);
      strip.setAttribute("data-origin", selection.origin);
      strip.setAttribute("data-status", computeStatus());
      strip.setAttribute("data-readonly", selectedReadOnly() ? "true" : "false");
    }
    var save = byId("preset-save");
    if (save) {
      var writes = savesInPlace();
      save.setAttribute("data-route", writes ? "write" : "save-as");
      save.title = writes
        ? "Save to " + selection.bank + " / " + pad3(selection.slot)
        : "Save As: choose a bank and slot";
    }
  }

  // Does Save write back to where the sound came from, or ask where to put it?
  //
  // Only a slot the panel may overwrite and that is the preset's own: a user
  // bank's, or a factory bank's where something keeps it. An imported bank is
  // somebody else's file, a read-only one cannot take it, and a sound with no
  // slot has nowhere to go back to, so each of those opens Save As.
  function savesInPlace() {
    if (selection.slot === null) return false;
    if (selection.origin !== "user" && selection.origin !== "factory") return false;
    var rec = bankByLabel(selection.bank);
    return !!rec && !bankReadOnly(rec);
  }

  // -- visible results

  // Say what happened, in the strip, where it can be read without a dialog in
  // the way of the sound. Errors stay until the next result; the rest fade, as
  // a person has read them by then.
  function say(text, kind) {
    var el = byId("bank-status");
    // Each message is its own: a timer from an earlier one must not clear a
    // later one, whether or not the timer could be cancelled.
    var mine = ++statusSerial;
    if (statusTimer) { window.clearTimeout(statusTimer); statusTimer = null; }
    if (!el) return;
    el.textContent = text || "";
    el.hidden = !text;
    el.setAttribute("data-kind", kind || "ok");
    if (text && kind !== "error") {
      statusTimer = window.setTimeout(function () {
        if (mine !== statusSerial) return;
        statusTimer = null;
        el.hidden = true;
        el.textContent = "";
      }, 8000);
    }
  }

  // Every outcome goes through here: remembered, announced, and handed to
  // whoever asked to hear about them. A refusal has the same shape as a
  // success so a caller never has to guess which it got.
  function report(result) {
    lastResult = result;
    say(result.ok ? result.message : result.error.message,
        result.ok ? (result.warning ? "warn" : "ok") : "error");
    resultListeners.slice().forEach(function (fn) {
      try { fn(result); } catch (e) { console.error("result listener:", e.message); }
    });
    return result;
  }

  function refusal(action, code, message) {
    return report({ ok: false, action: action, error: { code: code, message: message } });
  }

  // A person chose a preset and it is now the sound. Said to whoever asked --
  // the browser's recently used list -- and not through `report`, because
  // stepping with PREV and NEXT is a load too and says nothing in the strip.
  function announceLoaded() {
    var chosen = window.SynthBank.selection();
    loadListeners.slice().forEach(function (fn) {
      try { fn(chosen); } catch (e) { console.error("load listener:", e.message); }
    });
  }

  // -- restoring what the host asked for

  // What a restore was after, as the banner names it: `Alfmeister Bank / 042`.
  function restoreWords(s) {
    if (s.bank) return isSlot(s.slot) ? s.bank + " / " + pad3(s.slot) : s.bank;
    return isSlot(s.slot) ? "slot " + pad3(s.slot) : "the saved preset";
  }

  function paintRestore() {
    var banner = byId("restore-banner");
    if (!banner) return;
    var s = restoreState;
    var failed = s.state === "failed" || s.state === "restoring";
    var done = s.state === "restored";
    banner.hidden = !failed && !done;
    banner.setAttribute("aria-busy", s.state === "restoring" ? "true" : "false");

    var ok = byId("restore-ok");
    if (ok) ok.hidden = !done;
    if (done) {
      var tail = (isSlot(s.slot) ? pad3(s.slot) : "") +
        (s.name ? (isSlot(s.slot) ? " " : "") + s.name : "");
      var words = [];
      if (isOrigin(s.origin)) words.push(ORIGIN_LABELS[s.origin]);
      if (s.bank) words.push(s.bank);
      if (tail) words.push(tail);
      var okId = byId("restore-ok-id");
      if (okId) okId.textContent = words.join(" / ");
    }

    var bad = byId("restore-failed");
    if (bad) bad.hidden = !failed;
    var missing = byId("restore-missing");
    if (missing) missing.hidden = !(failed && failure && failure.error === "MissingBank");
    if (failed && failure) {
      var badId = byId("restore-failed-id");
      if (badId) badId.textContent = restoreWords(failure);
      var retry = byId("restore-retry");
      if (retry) retry.disabled = failure.recoverable === false || s.state === "restoring";
      var dismiss = byId("restore-dismiss");
      if (dismiss) dismiss.hidden = failure.error === "MissingBank";
    }
  }

  function setRestore(next) {
    restoreState = next;
    paintRestore();
    paintStrip();
  }

  // Whatever restore was outstanding is over, because somebody moved on from
  // it: a person choosing something, whose `select` replaces the identity the
  // host was holding, or the host itself choosing -- a MIDI Program Change --
  // which drops it on its side. Either way the banner has nothing left to say.
  function settleRestore() {
    if (restoreState.state === "notRequested") return;
    failure = null;
    setRestore({ state: "notRequested" });
  }

  var RESTORE_ERRORS = {
    MissingBank: true, InvalidProgram: true, HostStateRejected: true,
    StateVersionUnsupported: true,
  };

  function identityOf(msg) {
    var out = {};
    if (isOrigin(msg.origin)) out.origin = msg.origin;
    if (typeof msg.bank === "string" && msg.bank !== "") out.bank = msg.bank;
    if (isSlot(msg.slot)) out.slot = msg.slot;
    if (typeof msg.name === "string" && msg.name !== "") out.name = msg.name;
    return out;
  }

  function receiveRestore(msg) {
    // The host holds nothing to restore. It answers a retry that way when the
    // instance moved on since the failure, and the page, which marked the
    // banner busy when it asked, would otherwise wait for an answer for good.
    if (msg.state === "notRequested") {
      settleRestore();
      return;
    }
    var identity = identityOf(msg);
    var next;
    if (msg.state === "restored") {
      next = { state: "restored" };
      for (var k in identity) next[k] = identity[k];
      // A host that answers a retry with a different preset than the one being
      // retried has contradicted the request. It is the authority, so what it
      // says stands, but the page remembers that it was not what was asked.
      if (restoreState.state === "restoring" && failure &&
          ((identity.bank !== undefined && identity.bank !== failure.bank) ||
           (identity.slot !== undefined && identity.slot !== failure.slot))) {
        next.conflict = true;
      }
      failure = null;
      pendingLoad = null;
      // The host's selection is the selection. `patch` normally arrived first
      // and said the same; this covers a host that only says it here. A bank
      // restored with nothing selected in it names no slot, and says nothing
      // about which sound is playing, so it leaves the selection as it is.
      if (identity.slot !== undefined) {
        takeHostSelection({
          name: identity.name, index: identity.slot, bank: identity.bank, origin: identity.origin,
        });
      }
      setRestore(next);
      return;
    }
    if (msg.state !== "failed") return;
    var error = RESTORE_ERRORS[msg.error] === true ? msg.error : "HostStateRejected";
    // Whatever the host did not say, the code decides: a missing bank or an
    // unusable program can be tried again, a state the host will not read
    // cannot.
    var recoverable = typeof msg.recoverable === "boolean" ? msg.recoverable
      : error === "MissingBank" || error === "InvalidProgram";
    next = { state: "failed", error: error, recoverable: recoverable };
    if (typeof msg.message === "string" && msg.message !== "") next.message = msg.message;
    for (var j in identity) next[j] = identity[j];
    failure = next;
    // Neither the sound, the bank nor the selection is touched: the failure is
    // information about the project, not an instruction.
    setRestore(next);
  }

  function receiveBankSaved(msg) {
    var label = typeof msg.bank === "string" ? msg.bank : "";
    var at = pendingSaves.indexOf(label);
    if (at >= 0) pendingSaves.splice(at, 1);
    var rec = bankByLabel(label);
    if (msg.ok === true) {
      if (rec) {
        // Kept: this is now the bank the host comes back to.
        banks.forEach(function (b) { b.persisted = false; });
        rec.persisted = true;
        rec.saveError = "";
      }
      return;
    }
    var code = msg.error === "InvalidBank" ? "InvalidBank" : "PersistenceFailed";
    var why = typeof msg.message === "string" && msg.message !== "" ? " (" + msg.message + ")" : "";
    if (rec) rec.saveError = why || "could not be saved";
    report({
      ok: false, action: "persist", error: {
        code: code,
        message: "Could not save " + (label || "the bank") + " in the host" + why +
          ". The change is kept for this session only.",
      },
    });
  }

  // -- the host says which preset is playing

  // Work out the selection a `patch` (or `restore`) describes and adopt it. The
  // daemon's `patch` and the pad shell's own carry no "v" and are read the same
  // way: what they say is the selection, and what they do not say is not
  // guessed.
  function takeHostSelection(msg) {
    var named = typeof msg.name === "string" && msg.name !== "";
    var slot = isSlot(msg.index) ? msg.index : null;
    var origin = isOrigin(msg.origin) ? msg.origin : "";
    var kind = msg.source;
    if (kind === "archive") origin = "archive";
    else if (kind === "file") origin = "file";
    else if (kind === "none") origin = "session";
    else if (origin === "" || origin === "archive") {
      var rec = typeof msg.bank === "string" ? bankByLabel(msg.bank) : null;
      origin = slot !== null ? (rec ? rec.origin : "user") : "session";
    }
    // A host with no selection to report names neither a slot nor a sound: the
    // panel keeps its own name, since the sound in the engine is still its own.
    var name = named ? msg.name : currentName;
    if (named) currentName = msg.name;
    selection = makeSelection(origin, msg.bank, slot, name, msg.archive);
    // A sound with no slot to compare against was whatever the host had just
    // sent; the `state` before this one, or the one after, is its baseline.
    if (storedValues(selection) === baseline) baseline = liveValues();
    lastDirty = computeDirty();
  }

  // Whether a host's `patch` names a preset, as opposed to saying it has
  // nothing to report: `index` null and no `name`, which keeps the panel's own.
  function namesPreset(msg) {
    return (typeof msg.name === "string" && msg.name !== "") || isSlot(msg.index) ||
      msg.source === "archive" || msg.source === "file";
  }

  function receivePatch(msg) {
    // The host answering a load this panel asked for, as opposed to a program
    // change somebody else made: only the first is the person's own choice.
    var answered = !!pendingLoad && msg.source === "archive" && !!msg.archive &&
      msg.archive.bank === pendingLoad.bank && msg.archive.patch === pendingLoad.patch;
    // Which patch a *host* says is loaded, after something other than this
    // panel changed it -- a MIDI program change, most often.
    //
    // Not only drawn. The panel's own idea of what is loaded has to move with
    // it, or the next "save patch" writes the sound that is playing under the
    // name of the one before it.
    if (typeof msg.source === "string") {
      playing = msg;
      if (msg.source === "archive") pendingLoad = null;
    }
    takeHostSelection(msg);
    // The host moving on ends a restore that was shown as done, which is old
    // news by now. It also ends one that failed: a host that chose a preset by
    // itself has dropped the identity it was holding, and a banner still
    // offering a Retry would be offering it for nothing. Only a patch that
    // names a preset says so. A failure the host still holds is sent again
    // after its patch (see bridge.js), so it is not lost here.
    //
    // A retry still waiting is left to its answer, which the host always
    // gives. The answer carries a patch ahead of its restore, so settling on
    // that patch would lose the retry the restore is checked against; and a
    // person cannot choose a preset in the meantime either (`loadPreset`).
    if (restoreState.state === "restored" ||
        (restoreState.state === "failed" && namesPreset(msg))) settleRestore();
    paintRestore();
    paintStrip();
    if (answered) announceLoaded();
    refreshBrowser();
  }

  // -- telling the host

  // Only with a shared archive, which other clients can move under an open
  // dialog; and with a host that can say a program changed, or a restore
  // finished, under one. Without either the dialog repaints on its own actions.
  function refreshBrowser() {
    if (window.SynthBrowser && window.SynthBrowser.refresh) window.SynthBrowser.refresh();
  }

  // What the host is told about a selection, once it has said it can read one.
  function announceSelection() {
    bridge.select(selection.origin, selection.bank, selection.slot, selection.presetName);
  }

  // Tell a host which bank is loaded, and whether to keep it.
  //
  // Only a plugin listens: in the browser the bank is remembered in local
  // storage instead, and host.js ignores a message it has no case for.
  //
  // Two separate questions, which is why there is a flag rather than two
  // conditions on one send:
  //
  //   what is playing   always. A plugin selects patches by program change out
  //                     of its own copy, so if the panel is showing a bank the
  //                     plugin does not have, "program 12" means two different
  //                     sounds at once. It did: loading a .zip left the plugin
  //                     on the bank it started with.
  //   what is kept      only the bank the host itself keeps. The others are
  //                     files somebody opened -- they are already on disk,
  //                     under their own names, and overwriting the saved bank
  //                     by browsing somebody else's would be a poor trade.
  //                     A host that speaks version 1 says which one that is
  //                     (`persisted`); an older one is taken to keep bank zero,
  //                     which was the only bank it ever kept.
  //
  // The whole bank goes each time rather than a description of what moved.
  // Writing a patch is something a person does, one at a time, and a few tens
  // of kilobytes on that is nothing next to a second way of saying it.
  function publishBank(rec) {
    rec = rec || bank;
    if (!rec || !window.SynthPatchFile || !window.SynthPatchFile.bankText) return;
    var at = banks.indexOf(rec);
    // A daemon's ordinary bank used to be added after the placeholder, so
    // publishing it did not also keep it. Removing that placeholder must
    // not turn browsing or adding a bank into a disk write; Keep still does.
    if (at < 0 || (archive && at !== 0)) return;
    var text = window.SynthPatchFile.bankText(at);
    if (!text) return;
    var v1 = bridge.version() >= 1;
    var save = !archive && (v1 ? rec.persisted === true : rec === banks[0]);
    var msg = { type: "bank", text: text, save: save };
    if (v1) { msg.v = 1; msg.origin = rec.origin; }
    hostPlaying = rec;
    if (bridge.send(msg) && save && v1) pendingSaves.push(rec.label);
  }

  // The host plays out of the bank the selection is in; when the panel moves
  // somewhere it has not, the host is given that bank before the sound.
  function ensurePlaying(rec) {
    if (rec && rec !== hostPlaying) publishBank(rec);
  }

  // Banks whose content just changed. The host's own bank is saved if it is
  // one of them, and because saving a bank makes the host play it, the bank the
  // panel is actually playing from is sent again afterwards.
  function publishChanged(recs) {
    var current = playingBank();
    var v1 = bridge.version() >= 1;
    var others = [];
    recs.forEach(function (r) {
      // From here on the bank is not just the file it was opened from, which
      // is what closing it would otherwise be able to claim.
      if (r) r.edited = true;
      if (r && r !== current && others.indexOf(r) < 0 && v1 && r.persisted) others.push(r);
    });
    others.forEach(function (r) { publishBank(r); });
    if (recs.indexOf(current) >= 0 || others.length) publishBank(current);
  }

  function flushStore() {
    if (window.SynthStore) window.SynthStore.flush();
  }

  // -- loading

  // Load one patch out of a bank.
  //
  // Every parameter goes at once rather than as ninety-nine separate messages:
  // the engine rebinds on each one, and a patch change that rebound a hundred
  // times would be audible as a smear rather than a change.
  function loadPatch(index, rec) {
    rec = rec || bank;
    if (!rec) return;
    var n = BANK_SLOTS;
    // Wraps, so stepping past either end is a way round rather than a dead stop.
    var slot = ((index % n) + n) % n;
    // An empty slot loads as Init rather than being skipped over. Skipping
    // would make the empty ones invisible to the arrows, and then there would
    // be no way to arrive at one in order to save into it.
    var p = rec.patches[slot] || { n: "Init", v: initValues() };
    paintValues(p.v);
    currentName = p.n;
    setSelection(makeSelection(rec.origin, rec.label, slot, p.n));
    bridge.send({ type: "state", values: p.v });
  }

  // What a person choosing a slot does, in the order a host needs it: its bank,
  // then the sound, then which preset that was. Nothing else loads a slot on
  // the person's behalf; in particular nothing a host *sends* does.
  function userLoad(index, rec) {
    rec = rec || bank;
    if (!rec) return;
    settleRestore();
    currentBank = banks.indexOf(rec);
    bank = rec;
    ensurePlaying(rec);
    loadPatch(index, rec);
    announceSelection();
    announceLoaded();
  }

  // The preset a host plays, asked for through the archive: the host answers
  // with a `patch`, and the selection moves then and not before.
  function loadArchive(bankIndex, patchIndex) {
    var bad = function (code, message) { return refusal("load", code, message); };
    if (!archive || !archive.open) return bad("UnavailableSource", "No archive is open.");
    if (typeof bankIndex !== "number" || bankIndex % 1 !== 0 || bankIndex < 0 ||
        bankIndex >= archive.banks.length) {
      return bad("UnavailableSource", "That archive bank is not in the archive.");
    }
    if (typeof patchIndex !== "number" || patchIndex % 1 !== 0 || patchIndex < 0 ||
        (archive.bank === bankIndex && patchIndex >= archive.patches.length)) {
      return bad("InvalidPreset", "That patch is not in the archive bank.");
    }
    archiveError = "";
    pendingLoad = { bank: bankIndex, patch: patchIndex };
    if (!bridge.send({ type: "archive-load", bank: bankIndex, index: patchIndex })) {
      pendingLoad = null;
      return bad("UnavailableSource", "The host could not be reached.");
    }
    paintStrip();
    return { ok: true, action: "load", pending: true, archive: { bank: bankIndex, patch: patchIndex } };
  }

  // The patch list, as a popover over the bar.
  function showBankList(anchor) {
    var list = document.getElementById("bank-list");
    if (!list) {
      list = document.createElement("div");
      list.id = "bank-list";
      list.className = "bank-list";
      document.body.appendChild(list);
      document.addEventListener("click", function () {
        list.classList.remove("open");
      });
      list.addEventListener("click", function (e) { e.stopPropagation(); });
    }

    if (!list.childElementCount) {
      bank.patches.forEach(function (p, i) {
        var b = document.createElement("button");
        b.type = "button";
        b.textContent = pad3(i) + "  " + (p ? p.n : "Init");
        b.addEventListener("click", function () {
          userLoad(i);
          list.classList.remove("open");
        });
        list.appendChild(b);
      });
    }

    var at = slotInView();
    var kids = list.children;
    for (var i = 0; i < kids.length; i++) {
      kids[i].setAttribute("aria-current", i === at ? "true" : "false");
    }

    list.classList.add("open");
    var r = anchor.getBoundingClientRect();
    var w = list.offsetWidth;
    list.style.left = Math.round(Math.max(8,
      Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 8))) + "px";
    list.style.bottom = Math.round(window.innerHeight - r.top + 8) + "px";
    // Bring the current patch into view rather than always opening at the top.
    if (kids[at]) kids[at].scrollIntoView({ block: "center" });
  }

  // What patchfile.js needs, and nothing more.
  //
  // The panel owns `values`, the control repaint and the bank; reading or
  // writing a file needs all three and none of the rest. Exposed the same way
  // the keyboard and the wheels are, so the file handling can live in its own
  // script instead of growing this one -- and so nothing outside can reach in
  // and change a parameter without the controls being repainted to match.
  window.SynthPatch = {
    // The current parameter set, as stored integers in parameter order.
    values: liveValues,

    // The name of what is actually loaded, which is not always the bank's.
    //
    // Reading it off `bank.patches[slot]` was wrong and testing found it:
    // loading a patch *file* leaves the bank's slot where it was, so a save
    // straight afterwards wrote the loaded patch's parameters under the
    // neighbouring bank entry's name. `currentName` is set by every path that
    // changes the sound.
    name: function () {
      return currentName || "Patch";
    },

    // Move one parameter, on 0..1, exactly as dragging its knob would.
    //
    // The same path as the knob rather than a shortcut into `values`: the
    // control has to repaint, anything depending on it has to repaint, and the
    // engine has to be told. A controller that changed the sound without
    // moving the panel would be the worst of the three.
    setParam: function (index, unit) {
      var param = byIndex[index];
      if (!param) return;
      // `unit` is 0..1, which is what a controller sends once it is divided by
      // 127. setPosition wants a *state index*, and passing the fraction
      // straight through stored the fraction: a cutoff of 0.787 rather than of
      // state 100. How many states there are differs per parameter, so the
      // scaling has to happen here and not at the call site.
      var count = param.s ? param.s.length : param.n;
      var position = Math.round(Math.max(0, Math.min(1, unit)) * (count - 1));
      setPosition(index, position, true);
    },

    // Apply a whole patch as the sound, with no bank behind it. Goes through
    // the same path a bank patch does, so a loaded file cannot end up shown
    // differently from one that was stepped to.
    apply: function (list, name) {
      settleRestore();
      paintValues(list);
      currentName = name || "Patch";
      setSelection(makeSelection("file", "", null, currentName));
      bridge.send({ type: "state", values: list });
      announceSelection();
    },

    // The bank in view.
    bank: function () {
      return bank;
    },
  };

  // Keep the bank that is open, whichever one it is.
  //
  // publishBank only marks the host's own bank to be saved, which is right for
  // the ordinary case and left no way at all to do the thing somebody actually
  // wants after opening a .zip: make *that* the bank the plugin comes back to.
  // There was "Save bank…", which downloads a file -- in a plugin that puts it
  // in Downloads, which is not a bank, and is where this was found.
  function keepBank() {
    if (!window.SynthPatchFile || !window.SynthPatchFile.bankText) return false;
    var text = window.SynthPatchFile.bankText(currentBank);
    if (!text) return false;
    var v1 = bridge.version() >= 1;
    var msg = { type: "bank", text: text, save: true };
    if (v1) { msg.v = 1; msg.origin = bank.origin; }
    hostPlaying = bank;
    var sent = bridge.send(msg);
    if (sent && v1) pendingSaves.push(bank.label);
    // What is stored is the slots; the sound being edited is not in it, and a
    // person pressing Keep after an edit is owed being told so.
    say(sent ? "Kept " + bank.label + "." + (lastDirty
      ? " Unsaved changes to " + selection.presetName + " were not included." : "")
      : "Could not keep " + bank.label + ".", sent ? (lastDirty ? "warn" : "ok") : "error");
    return sent;
  }

  function emptyBank(label) {
    return makeBank({ label: label, patches: [] }, "user");
  }

  function utf8Length(text) {
    var n = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xd800 && c < 0xdc00 && i + 1 < text.length &&
               (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) { n += 4; i++; }
      else n += 3;
    }
    return n;
  }

  // A name the host will store exactly as written.
  function checkName(raw) {
    if (typeof raw !== "string") return { error: "A name is text." };
    if (/[\u0000-\u001f\u007f-\u009f]/.test(raw)) {
      return { error: "A name cannot contain control characters." };
    }
    var name = raw.trim();
    if (!name) return { error: "A name cannot be empty." };
    var bytes = utf8Length(name);
    if (bytes > NAME_MAX_BYTES) {
      return { error: "That name is " + bytes + " bytes; the most a slot keeps is " + NAME_MAX_BYTES + "." };
    }
    return { name: name };
  }

  // A bank's name: anything readable. Banks come named after files, so there
  // is no length to hold them to.
  function checkLabel(raw) {
    if (typeof raw !== "string") return { error: "A bank's name is text." };
    if (/[\u0000-\u001f\u007f-\u009f]/.test(raw)) {
      return { error: "A bank's name cannot contain control characters." };
    }
    var label = raw.trim();
    return label ? { label: label } : { error: "A bank's name cannot be empty." };
  }

  function slotWords(rec, slot) {
    return rec.label + " / " + pad3(slot);
  }

  function copyPatch(p) {
    return { n: p.n, v: p.v.slice() };
  }

  function archiveBusy(action) {
    return refusal(action, "UnsupportedFormat",
      "Banks cannot be added or removed in the page while a shared archive is open.");
  }

  var ORIGIN_RANK = { factory: 0, user: 1, imported: 2, file: 3, archive: 4, session: 5 };

  // The preset's identity for anything that wants to remember it: favourites,
  // most recently used. Built from what names it, so a bank renamed or a slot
  // rewritten is a different preset and an old reference goes unavailable
  // instead of quietly pointing at something else.
  function presetKey(origin, label, slot, from, name) {
    var where = slot !== null ? String(slot) : from ? "a" + from.bank + "." + from.patch : "";
    return origin + "\u0000" + label + "\u0000" + where + "\u0000" + name;
  }

  function bankRow(b, i) {
    var used = null;
    if (!b.load || b.loaded) {
      used = 0;
      for (var j = 0; j < b.patches.length; j++) if (b.patches[j]) used++;
    }
    return {
      index: i,
      label: b.label,
      origin: b.origin,
      kind: "bank",
      used: used,
      loading: !!b.loading,
      unavailable: !!b.error,
      error: b.error || "",
      leftOut: b.leftOut || 0,
      readOnly: bankReadOnly(b),
      closable: bankClosable(b),
      persisted: b.persisted === true,
      edited: b.edited === true,
      saveError: b.saveError || "",
      current: i === currentBank,
      playing: selection.origin !== "archive" && selection.bank === b.label,
    };
  }

  // A bank that can be closed: one the panel made or opened, that no host
  // keeps.
  function bankClosable(rec) {
    if (archive || banks.length < 2) return false;
    if (rec.origin !== "imported" && rec.origin !== "user") return false;
    return !rec.hostOwned && !rec.persisted;
  }

  function receiveArchive(msg) {
    if (!archive) {
      // sync sends the ordinary bank before the archive capability. Keep
      // that bank, not the empty placeholder the hosted page began with.
      banks = [hostBank || bank];
      currentBank = 0;
      bank = banks[0];
    }
    archive = msg;
    if (browsedArchive >= 0) {
      browsedArchive = msg.open && msg.bank !== null ? msg.bank : -1;
    }
    archiveWaiting = -1;
    refreshBrowser();
  }

  // The bank a *plugin* holds, which is the one on disk, or the one it was
  // sent and keeps in its state. The copy compiled into this page is only what
  // a browser would have used, so it is replaced when it has the same name and
  // otherwise sits beside it.
  //
  // This changes the bank list and nothing else. It does not load slot 0, it
  // does not touch the sound, and it sends nothing: the bank came from the
  // host, and sending it straight back out -- or the first patch of it -- was
  // the write on every editor open that issue #13 is about. Which preset is
  // playing is the host's `state`, `patch` and `restore`, not this.
  function adoptHostBank(msg) {
    var parsed = window.SynthPatchFile.parseBank(msg.text);
    var origin = msg.origin === "factory" || msg.origin === "imported" ? msg.origin : "user";
    var made = makeBank({ label: parsed.label, patches: parsed.patches }, origin);
    made.hostOwned = true;
    made.readOnly = msg.readOnly === true;
    // Only a version-1 host says which bank it keeps, and it says it by
    // calling it factory or user. One that was sent from somebody's file and
    // merely embedded in the project is not on its disk, and a bank with no
    // origin to speak of must not be saved over the one that is.
    made.persisted = !made.readOnly && bridge.version() >= 1 &&
      (msg.origin === "factory" || msg.origin === "user");
    if (archive) {
      banks = [made];
      currentBank = 0;
    } else {
      var at = bankIndexOf(made.label);
      if (at >= 0) {
        banks[at] = made;
        currentBank = at;
      } else {
        banks.push(made);
        currentBank = banks.length - 1;
      }
    }
    bank = made;
    hostBank = made;
    hostPlaying = made;
    bankSupplied = true;
    var list = byId("bank-list");
    if (list) {
      list.textContent = "";
      list.classList.remove("open");
    }
    lastDirty = computeDirty();
    paintStrip();
  }

  // -- writing, copying, moving

  // The one door through which a sound becomes part of a bank. It writes the
  // live sound to exactly the slot asked for, or refuses and changes nothing.
  //
  //   writePreset({ bank, slot, name, overwrite })
  //
  // `bank` is a position in `SynthBank.list()` or a label. Writing over a sound
  // takes `overwrite: true`, which is the caller saying a person agreed: the
  // panel does not ask, and does not assume the answer.
  //
  // Returns { ok: true, action, bank, slot, name, message } or
  // { ok: false, action, error: { code, message } } with the code one of
  // InvalidSlot, ReadOnlyBank, InvalidName, OverwriteDenied.
  function writeSlot(req, action) {
    req = req || {};
    var bad = function (code, message) { return refusal(action, code, message); };
    var found = resolveBank(req.bank);
    if (!found || !isSlot(req.slot)) {
      return bad("InvalidSlot", "That is not a slot of a bank that is open.");
    }
    if (found.archive) return bad("ReadOnlyBank", "Archive banks are read-only.");
    var rec = found.rec;
    if (bankReadOnly(rec)) return bad("ReadOnlyBank", rec.label + " is read-only.");
    if (bankUnopened(rec)) return bad("ReadOnlyBank", "Open " + rec.label + " before writing to it.");
    var checked = checkName(req.name === undefined ? (currentName || "Untitled") : req.name);
    if (checked.error) return bad("InvalidName", checked.error);
    var old = rec.patches[req.slot];
    if (old && req.overwrite !== true) {
      return bad("OverwriteDenied", "Slot " + slotWords(rec, req.slot) + " already holds " + old.n + ".");
    }

    rec.patches[req.slot] = { n: checked.name, v: liveValues() };
    settleRestore();
    currentBank = found.index;
    bank = rec;
    currentName = checked.name;
    setSelection(makeSelection(rec.origin, rec.label, req.slot, checked.name));
    flushStore();
    publishChanged([rec]);
    announceSelection();
    refreshBrowser();
    return report({
      ok: true, action: action, bank: rec.label, slot: req.slot, name: checked.name,
      overwrote: !!old,
      message: "Saved " + checked.name + " to " + slotWords(rec, req.slot) + ".",
    });
  }

  // Copy or move one preset to another slot, the same bank's or another's. The
  // caller has already asked; a destination that holds a sound is only touched
  // with `overwrite: true`. A copy leaves the sound that is playing alone, and
  // so does a move, except that the sound that *was* the moved one is now at
  // its new address and the selection goes with it.
  function transfer(action, from, to, options) {
    var bad = function (code, message) { return refusal(action, code, message); };
    from = from || {};
    to = to || {};
    var src = resolveBank(from.bank), dst = resolveBank(to.bank);
    if (!src || !dst || !isSlot(from.slot) || !isSlot(to.slot)) {
      return bad("InvalidSlot", "That is not a slot of a bank that is open.");
    }
    if (src.archive) {
      return bad(action === "move" ? "ReadOnlyBank" : "UnavailableSource",
        "A patch in the shared archive is not held here to " + action + ".");
    }
    if (dst.archive) return bad("ReadOnlyBank", "Archive banks are read-only.");
    if (src.rec === dst.rec && from.slot === to.slot) {
      return bad("InvalidSlot", "That is the same slot.");
    }
    if (bankUnopened(src.rec)) return bad("UnavailableSource", src.rec.label + " has not been opened.");
    var p = src.rec.patches[from.slot];
    if (!p) return bad("InvalidPreset", "Slot " + slotWords(src.rec, from.slot) + " is empty.");
    if (bankReadOnly(dst.rec)) return bad("ReadOnlyBank", dst.rec.label + " is read-only.");
    if (bankUnopened(dst.rec)) return bad("ReadOnlyBank", "Open " + dst.rec.label + " before writing to it.");
    if (action === "move" && bankReadOnly(src.rec)) {
      return bad("ReadOnlyBank", src.rec.label + " is read-only, so nothing can be moved out of it.");
    }
    var there = dst.rec.patches[to.slot];
    if (there && !(options && options.overwrite === true)) {
      return bad("OverwriteDenied", "Slot " + slotWords(dst.rec, to.slot) + " already holds " + there.n + ".");
    }

    // Both ends are changed before anything is announced, so a host is told
    // about a move once and never sees a copy that has not lost its source yet.
    var wasSelected = selection.slot === from.slot && selection.bank === src.rec.label;
    dst.rec.patches[to.slot] = copyPatch(p);
    if (action === "move") src.rec.patches[from.slot] = null;
    if (action === "move" && wasSelected) {
      selection = makeSelection(dst.rec.origin, dst.rec.label, to.slot, p.n);
    }
    lastDirty = computeDirty();
    flushStore();
    publishChanged(action === "move" ? [dst.rec, src.rec] : [dst.rec]);
    if (action === "move" && wasSelected) announceSelection();
    paintStrip();
    refreshBrowser();
    return report({
      ok: true, action: action, name: p.n, overwrote: !!there,
      from: { bank: src.rec.label, slot: from.slot },
      to: { bank: dst.rec.label, slot: to.slot },
      message: (action === "move" ? "Moved " : "Copied ") + p.n + " from " +
        slotWords(src.rec, from.slot) + " to " + slotWords(dst.rec, to.slot) + ".",
    });
  }

  // -- Save, and Save As

  // Save writes the sound back to where it came from when that is somewhere it
  // may go, and otherwise asks where; it never overwrites a source it does not
  // own. Asking is the browser's job, because choosing a destination is what
  // its Write view is.
  function save() {
    if (savesInPlace()) {
      return writeSlot({
        bank: bankIndexOf(selection.bank), slot: selection.slot,
        name: selection.presetName || currentName || "Untitled", overwrite: true,
      }, "save");
    }
    return saveAs();
  }

  function saveAs() {
    var b = window.SynthBrowser;
    if (b && typeof b.saveAs === "function") b.saveAs();
    else if (b && typeof b.write === "function") b.write();
    else return refusal("save-as", "InvalidSlot", "There is nowhere to choose a destination here.");
    return { ok: true, action: "save-as", pending: true };
  }

  function bankIndexOf(label) {
    for (var i = 0; i < banks.length; i++) if (banks[i].label === label) return i;
    return -1;
  }

  // -- the browser's own entry points, as the strip reaches them

  function openBrowser() {
    var read = document.querySelector("#bank .bank-read");
    if (window.SynthBrowser && window.SynthBrowser.open) window.SynthBrowser.open();
    else if (read) showBankList(read);
  }

  function importWithPicker() {
    var b = window.SynthBrowser;
    if (b && typeof b.importBank === "function") { b.importBank(); return; }
    var files = window.SynthPatchFile;
    if (!files || !files.pick) {
      refusal("import", "UnsupportedFormat", "This build cannot open files.");
      return;
    }
    files.pick(function (err, what) {
      if (err) return;
      say(what ? "Opened " + what + "." : "", "ok");
    });
  }

  function runMenu(action) {
    var files = window.SynthPatchFile;
    var b = window.SynthBrowser;
    var missing = function (what) { refusal(action, "InvalidSlot", what + " is not available here."); };
    switch (action) {
      case "save-as": saveAs(); break;
      case "export-patch": if (files && files.savePatch) files.savePatch(); else missing("Export"); break;
      case "export-bank": if (files && files.saveBank) files.saveBank(); else missing("Export"); break;
      case "import-bank": importWithPicker(); break;
      case "write": if (b && b.write) b.write(); else missing("Write"); break;
    }
  }

  // The actions beside the strip: Browser, Save, and a menu of the rest.
  //
  // The menu is a menu button as the WAI-ARIA practices describe one: it opens
  // on click, Enter, Space and the arrow keys, focus moves into it and stays
  // inside, Escape closes it and gives focus back to the button, and so does
  // choosing something -- *before* the action runs, so that a dialog the action
  // opens takes the button as the place focus returns to rather than an item
  // that has just been hidden.
  function buildActions() {
    var browse = byId("preset-browse");
    var saveButton = byId("preset-save");
    var menu = byId("preset-menu");
    var list = byId("preset-menu-list");
    if (browse) browse.addEventListener("click", function (e) { e.stopPropagation(); openBrowser(); });
    if (saveButton) {
      saveButton.addEventListener("click", function (e) {
        e.stopPropagation();
        window.SynthBank.save();
      });
    }
    if (!menu || !list) return;

    var items = [].slice.call(list.querySelectorAll('[role="menuitem"]'));
    function setOpen(open, which) {
      list.hidden = !open;
      menu.setAttribute("aria-expanded", open ? "true" : "false");
      if (open && items.length) items[which === "last" ? items.length - 1 : 0].focus();
    }
    function move(from, by) {
      items[(from + by + items.length) % items.length].focus();
    }

    menu.addEventListener("click", function (e) {
      e.stopPropagation();
      setOpen(list.hidden, "first");
    });
    menu.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        setOpen(true, e.key === "ArrowUp" ? "last" : "first");
      }
    });
    items.forEach(function (item, at) {
      item.addEventListener("click", function (e) {
        e.stopPropagation();
        setOpen(false);
        menu.focus();
        runMenu(item.getAttribute("data-action"));
      });
      item.addEventListener("keydown", function (e) {
        if (e.key === "ArrowDown") { e.preventDefault(); move(at, 1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); move(at, -1); }
        else if (e.key === "Home") { e.preventDefault(); items[0].focus(); }
        else if (e.key === "End") { e.preventDefault(); items[items.length - 1].focus(); }
        else if (e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          setOpen(false);
          menu.focus();
        } else if (e.key === "Tab") setOpen(false);
      });
    });
    // A click anywhere else closes it, as for any menu.
    document.addEventListener("click", function () {
      if (!list.hidden) setOpen(false);
    });
  }

  function buildRestore() {
    var on = function (id, fn) {
      var el = byId(id);
      if (el) el.addEventListener("click", fn);
    };
    on("restore-retry", function () { window.SynthBank.restore.retry(); });
    on("restore-choose", function () { window.SynthBank.restore.chooseBank(); });
    on("restore-dismiss", function () { window.SynthBank.restore.discard(); });
    on("restore-factory", function () { window.SynthBank.restore.loadFactoryInit(); });
    on("restore-keep", function () { window.SynthBank.restore.discard(); });
  }

  // Does the host hold the sound? In a plugin, and in the standalone daemon's
  // page, it does: opening the editor is looking at an instrument that is
  // already playing, and the host will say what it is playing. A page whose
  // engine is *in* the page -- the browser build, the pad -- has been told
  // nothing, and a sound of its own is the only sound there will ever be.
  function hostHoldsSound() {
    return window.SynthBank.hosted() && !bridge.inPage;
  }

  function buildBank() {
    var el = byId("bank");
    if (!el) return;

    var steps = el.querySelectorAll(".bank-step");
    for (var i = 0; i < steps.length; i++) {
      (function (b) {
        b.addEventListener("click", function (e) {
          e.stopPropagation();
          var step = parseInt(b.dataset.step, 10);
          var at = slotInView();
          if (archive && playing && playing.source === "archive") {
            bridge.send({ type: "patch-step", step: step });
          } else if (bank) {
            // With nothing loaded from this bank the first press goes to its
            // ends, rather than to the slot one past a position that is not
            // one.
            userLoad(at < 0 ? (step > 0 ? 0 : BANK_SLOTS - 1) : at + step);
          } else {
            // No bank compiled in: the host may still have one.
            bridge.send({ type: "patch-step", step: step });
          }
        });
      })(steps[i]);
    }

    var read = el.querySelector(".bank-read");
    if (read) {
      read.classList.add("pickable");
      read.addEventListener("click", function (e) {
        e.stopPropagation();
        // The browser if it is loaded, the old popover if it is not. A native
        // host that ships a trimmed panel still gets a way to change patch.
        openBrowser();
      });
    }
    buildActions();
    buildRestore();

    // What was remembered, if anything is doing the remembering.
    //
    // The factory bank's slots go back first, so that loading slot zero below
    // loads the edited version of it rather than the one that shipped. The
    // current sound goes on top of that, because it is what was actually being
    // played and it need not be any slot's contents.
    var kept = window.SynthStore ? window.SynthStore.restore() : null;
    if (kept && kept.midi && window.SynthMidiMap) {
      window.SynthMidiMap.restore(kept.midi);
    }
    if (kept && kept.factory) {
      banks[0] = makeBank({ label: banks[0].label, patches: kept.factory }, banks[0].origin);
      if (currentBank === 0) bank = banks[0];
    }

    // Only when a bank actually came with the page, and only when nothing else
    // holds the sound. There is always a bank now -- an empty one is still 128
    // slots you can save into -- but loading slot zero of it sends an Init
    // patch or a factory one to the host, and in a plugin the host has its own
    // state and got there first. A panel that overwrote it on startup lost the
    // user's sound every time the window was opened. That is issue #13: the
    // editor is a view, and opening a view is not an edit.
    if (bankSupplied && !hostHoldsSound()) loadPatch(0, bank);
    else paintStrip();

    // And then the sound that was actually up, over the top of it. Restored
    // after loadPatch rather than instead of it, so the slot number and the
    // bank name are already right and only the sound changes.
    if (kept && kept.current && kept.current.values) {
      window.SynthPatch.apply(kept.current.values, kept.current.name);
      var slot = kept.current.slot;
      // A slot is a place in one bank, and the factory bank is the only one
      // remembered. A sound that came from another bank stays the sound it is
      // rather than becoming a factory preset it never was. A state written
      // before it recorded the bank has none to compare, and keeps its slot.
      var from = kept.current.bank;
      if (isSlot(slot) && (from === undefined || from === bank.label)) {
        setSelection(makeSelection(bank.origin, bank.label, slot, currentName));
      }
    }
    paintRestore();
  }

  // The bank as slots: what the browser and the file menu both work through.
  window.SynthBank = {
    SLOTS: BANK_SLOTS,

    archive: function () { return archive; },
    archiveError: function () { return archiveError; },
    playing: function () { return playing; },
    openArchive: function (path) {
      archiveError = "";
      return bridge.send({ type: "archive-open", path: path });
    },
    closeArchive: function () {
      archiveError = "";
      return bridge.send({ type: "archive-close" });
    },

    // -- what is selected, and how it is doing

    // Which preset the sound in the engine is. A copy: the page owns it.
    selection: function () {
      return makeSelection(selection.origin, selection.bank, selection.slot,
        selection.presetName, selection.archive);
    },

    // One of "loading", "unavailable", "dirty", "readonly" or "clean", the
    // first that applies. `dirty` is about the *sound*: the live parameters
    // differ from what the selection was stored as. It says nothing about
    // whether the host's project has unsaved changes.
    status: computeStatus,

    // Whether the selection is in a bank that cannot take a write.
    readOnly: selectedReadOnly,

    // What became of the last attempt to restore a program and bank:
    // { state: "notRequested" | "restoring" | "restored" | "failed", ... }.
    restoreState: function () {
      var out = {};
      for (var k in restoreState) out[k] = restoreState[k];
      return out;
    },

    restore: {
      // Ask the host to try again, and say nothing final until it answers.
      retry: function () {
        var cannot = function () {
          return refusal("restore-retry", "HostRejected", "This host cannot retry a restore.");
        };
        if (bridge.version() < 1) return cannot();
        if (restoreState.state === "restoring") return { ok: true, action: "restore-retry", pending: true };
        if (restoreState.state !== "failed" || !failure) return { ok: true, action: "restore-retry", pending: false };
        if (!bridge.restoreRetry()) return cannot();
        var next = { state: "restoring" };
        ["origin", "bank", "slot", "name"].forEach(function (k) {
          if (failure[k] !== undefined) next[k] = failure[k];
        });
        setRestore(next);
        return { ok: true, action: "restore-retry", pending: true };
      },

      // Keep the sound that is playing and let the host forget what it could
      // not restore.
      discard: function () {
        bridge.restoreDiscard();
        failure = null;
        setRestore({ state: "notRequested" });
        return { ok: true, action: "restore-discard" };
      },

      // The factory's Init, as a choice somebody made. This is the only thing
      // in the panel that ever puts the factory bank in place of a bank that
      // could not be found, and it only does it when asked.
      loadFactoryInit: function () {
        var rec = null;
        banks.forEach(function (b) { if (!rec && b.origin === "factory") rec = b; });
        var label = rec ? rec.label
          : (window.SYNTH1_BANK && window.SYNTH1_BANK.label) || "Quesynth Factory";
        settleRestore();
        if (rec && !archive) {
          currentBank = banks.indexOf(rec);
          bank = rec;
          ensurePlaying(rec);
        }
        var init = initValues();
        paintValues(init);
        currentName = "Init";
        setSelection(makeSelection("factory", label, null, "Init"));
        bridge.send({ type: "state", values: init });
        announceSelection();
        return report({ ok: true, action: "load-factory-init", message: "Loaded " + label + " / Init." });
      },

      chooseBank: function () {
        openBrowser();
        return { ok: true, action: "choose-bank" };
      },
    },

    // -- results

    // Say something in the strip, where it is seen and not in the way.
    // `kind` is "ok", "warn" or "error".
    announce: say,
    // Every outcome of a write, copy, move, save, import or export, as the
    // object it returned; and the last one, for whoever missed it.
    report: report,
    lastResult: function () { return lastResult; },
    onResult: function (fn) {
      resultListeners.push(fn);
      return function () {
        var at = resultListeners.indexOf(fn);
        if (at >= 0) resultListeners.splice(at, 1);
      };
    },
    // Told with the selection each time a person's choice becomes the sound:
    // a slot loaded, or the host's answer to an archive patch asked for.
    onLoad: function (fn) {
      loadListeners.push(fn);
      return function () {
        var at = loadListeners.indexOf(fn);
        if (at >= 0) loadListeners.splice(at, 1);
      };
    },

    // A patch was written to a file. A sound with no slot behind it is now what
    // it was exported as; one in a slot is still not what that slot holds.
    patchExported: function () {
      if (selection.slot !== null) return false;
      baseline = liveValues();
      lastDirty = false;
      paintStrip();
      return true;
    },

    // -- the banks

    // A view for navigation, not for exporting or storing the ordinary bank.
    // Keeping it apart from label/slots/index prevents an export or a write
    // from turning the open archive bank into an ordinary bank by accident.
    browsing: function () {
      if (!archive) return null;
      var remote = browsedArchive >= 0;
      var shown = remote && archive.bank === browsedArchive;
      var index = -1;
      if (playing) {
        if (!remote && playing.source === "bank" && playing.index !== null) index = playing.index;
        if (remote && playing.source === "archive" && playing.archive &&
            playing.archive.bank === browsedArchive) index = playing.archive.patch;
      }
      return {
        bank: browsedArchive,
        label: remote ? archive.banks[browsedArchive] : bank.label,
        slots: remote ? (shown ? archive.patches.map(function (name) { return { name: name }; }) : [])
          : window.SynthBank.slots(),
        index: index,
        loading: remote && archiveWaiting >= 0,
      };
    },

    loadBrowsed: function (i) {
      if (archive && browsedArchive >= 0) loadArchive(browsedArchive, i);
      else userLoad(i);
    },

    // Every open bank, for the list down the side.
    //
    // A bank can be listed without being open. The published Synth1 collection
    // is a zip of a hundred and seventy-five zips, and decompressing all of
    // them to draw a list would be reading eleven megabytes and building
    // twenty thousand patches to show a hundred and seventy-five names. So a
    // lazy one is a row with a loader behind it, and `used` is null until
    // somebody opens it.
    list: function () {
      if (archive) {
        var ordinary = bankRow(banks[0], 0);
        ordinary.used = banks[0].patches.filter(Boolean).length;
        ordinary.current = browsedArchive < 0;
        var rows = archive.banks.map(function (name, i) {
          return {
            index: i + 1, label: name, origin: "archive", kind: "archive",
            used: archive.bank === i ? archive.patches.length : null,
            loading: archiveWaiting === i, unavailable: false, error: "", leftOut: 0,
            readOnly: true, closable: false, persisted: false, edited: false, saveError: "",
            current: browsedArchive === i,
            playing: selection.origin === "archive" && !!selection.archive && selection.archive.bank === i,
          };
        });
        return [ordinary].concat(rows);
      }
      return banks.map(bankRow);
    },

    // One row of `list`, by the same position, or null.
    bankInfo: function (i) {
      return window.SynthBank.list()[i] || null;
    },
    origin: function (i) {
      var info = window.SynthBank.bankInfo(i);
      return info ? info.origin : null;
    },
    originLabel: function (origin) {
      return isOrigin(origin) ? ORIGIN_LABELS[origin] : "";
    },

    // A bank that exists but has not been read yet. `load` is called at most
    // once, the first time it is selected, and resolves to its patches.
    addLazy: function (label, load) {
      var made = emptyBank(uniqueLabel(String(label || "Bank")));
      made.origin = "imported";
      made.load = load;
      made.loaded = false;
      banks.push(made);
      return banks.length - 1;
    },

    current: function () { return currentBank; },

    // Switch to another open bank. `quiet` leaves the sound alone, which is
    // what looking for somewhere to save wants: choosing a destination must not
    // overwrite the thing being saved. Either way, the selection stays where it
    // was until something is chosen.
    select: function (i, quiet, done) {
      if (archive) {
        if (i < 0 || i > archive.banks.length) return;
        browsedArchive = i - 1;
        archiveError = "";
        archiveWaiting = browsedArchive;
        if (browsedArchive >= 0) bridge.send({ type: "archive-bank", index: browsedArchive });
        if (done) done(null, browsedArchive >= 0 ? "loading" : undefined);
        refreshBrowser();
        return;
      }
      if (i < 0 || i >= banks.length) return;
      var target = banks[i];

      // Not read yet: read it, then arrive. Selecting the same bank twice
      // while the first read is still going does nothing, rather than starting
      // a second one.
      if (target.load && !target.loaded) {
        if (target.loading) return;
        target.loading = true;
        target.error = "";
        target.load().then(function (patches) {
          target.loading = false;
          target.loaded = true;
          var filled = normalizeBank({ label: target.label, patches: patches });
          target.patches = filled.patches;
          // Said where it is read, so a bank that did not fit is never shown as
          // if it had.
          target.leftOut = Math.max(0, patches.length - BANK_SLOTS);
          window.SynthBank.select(i, quiet, done);
        }, function (err) {
          target.loading = false;
          // Left unloaded rather than emptied, so it can be tried again; marked
          // so the list can say why it is not there.
          target.error = (err && err.message) || "could not be read";
          if (done) done(err);
        });
        if (done) done(null, "loading");
        return;
      }

      if (i === currentBank) { if (done) done(null); return; }
      currentBank = i;
      bank = banks[i];
      var list = byId("bank-list");
      if (list) {
        list.textContent = "";
        list.classList.remove("open");
      }
      if (!quiet) userLoad(0, bank);
      if (done) done(null);
    },

    // A new empty bank: 128 slots with nothing in them, which is a perfectly
    // good bank to start writing sounds into.
    newBank: function (label) {
      if (archive) return archiveBusy("new-bank");
      var checked = checkLabel(label === undefined ? "New Bank" : label);
      if (checked.error) return refusal("new-bank", "InvalidName", checked.error);
      var made = emptyBank(uniqueLabel(checked.label));
      banks.push(made);
      window.SynthBank.select(banks.length - 1, true);
      return report({
        ok: true, action: "new-bank", index: banks.length - 1, label: made.label,
        message: "Made " + made.label + ".",
      });
    },
    create: function (label) {
      var r = window.SynthBank.newBank(label);
      return r.ok ? r.index : -1;
    },

    // A bank brought in from a file. The one thing it does is add a row: the
    // bank in view, the selection, the sound and the host are exactly as they
    // were, until somebody chooses something in it.
    //
    // `leftOut` is how many patches the file held beyond a bank's 128. It stays
    // on the bank, as it does for one read out of a zip of banks, so that an
    // export of it cannot pass for the whole of what was opened.
    importBank: function (label, patches, leftOut) {
      if (archive) return archiveBusy("import");
      var made = makeBank({ label: uniqueLabel(String(label || "Bank")), patches: patches }, "imported");
      if (leftOut > 0) made.leftOut = leftOut;
      banks.push(made);
      refreshBrowser();
      return {
        ok: true, action: "import", index: banks.length - 1, label: made.label,
        used: made.patches.filter(Boolean).length,
      };
    },

    // Rename a bank the panel owns: one it made or opened, that no host keeps
    // under its old name.
    renameBank: function (i, name) {
      var found = resolveBank(i);
      if (!found || found.archive) return refusal("rename-bank", "InvalidSlot", "That bank is not open.");
      var rec = found.rec;
      if (rec.origin === "factory" || rec.origin === "archive" || rec.hostOwned) {
        return refusal("rename-bank", "ReadOnlyBank", rec.label + " belongs to the host and cannot be renamed.");
      }
      var checked = checkLabel(name);
      if (checked.error) return refusal("rename-bank", "InvalidName", checked.error);
      if (checked.label === rec.label) {
        return { ok: true, action: "rename-bank", index: found.index, label: rec.label };
      }
      if (banks.some(function (b) { return b !== rec && b.label === checked.label; })) {
        return refusal("rename-bank", "InvalidName", "A bank called " + checked.label + " is already open.");
      }
      var was = rec.label;
      rec.label = checked.label;
      if (selection.bank === was) selection.bank = checked.label;
      if (rec === hostPlaying) publishBank(rec);
      paintStrip();
      refreshBrowser();
      return report({
        ok: true, action: "rename-bank", index: found.index, label: rec.label,
        message: "Renamed " + was + " to " + rec.label + ".",
      });
    },

    // A writable copy of a bank that is open and has been read, as a bank of
    // the user's own.
    duplicateBank: function (i) {
      if (archive) return archiveBusy("duplicate-bank");
      var found = resolveBank(i);
      if (!found) return refusal("duplicate-bank", "InvalidSlot", "That bank is not open.");
      if (bankUnopened(found.rec)) {
        return refusal("duplicate-bank", "UnavailableSource", found.rec.label + " has not been opened.");
      }
      var made = makeBank({
        label: uniqueLabel(found.rec.label + " copy"),
        patches: found.rec.patches.map(function (p) { return p ? copyPatch(p) : null; }),
      }, "user");
      banks.push(made);
      window.SynthBank.select(banks.length - 1, true);
      return report({
        ok: true, action: "duplicate-bank", index: banks.length - 1, label: made.label,
        message: "Copied " + found.rec.label + " to " + made.label + ".",
      });
    },

    // Close a bank the panel opened. Never the last one, never the host's, and
    // never the sound: if it was the one playing, the sound stays as it is and
    // simply has no slot behind it any more.
    removeBank: function (i) {
      var found = resolveBank(i);
      if (!found || found.archive) return refusal("remove-bank", "InvalidSlot", "That bank is not open.");
      var rec = found.rec;
      if (!bankClosable(rec)) {
        return refusal("remove-bank", "ReadOnlyBank",
          banks.length < 2 ? "The last bank cannot be closed." : rec.label + " cannot be closed.");
      }
      banks.splice(found.index, 1);
      if (found.index < currentBank) currentBank--;
      else if (found.index === currentBank) currentBank = Math.min(currentBank, banks.length - 1);
      bank = banks[currentBank];
      if (hostPlaying === rec) hostPlaying = null;
      if (selection.bank === rec.label && selection.origin !== "archive") {
        // What the sound was loaded with is still what it is measured against:
        // closing the bank it came from does not make an edit to it a
        // non-edit.
        var was = selection.slot !== null && rec.patches[selection.slot];
        selection = makeSelection("session", "", null, selection.presetName);
        baseline = was ? was.v.slice() : liveValues();
        lastDirty = computeDirty();
        announceSelection();
      }
      var list = byId("bank-list");
      if (list) {
        list.textContent = "";
        list.classList.remove("open");
      }
      paintStrip();
      refreshBrowser();
      return report({
        ok: true, action: "remove-bank", label: rec.label, message: "Closed " + rec.label + ".",
      });
    },

    // -- presets

    // Every preset the panel can name and load now, in one order: by where it
    // came from (factory, user, imported, file, archive, session), then the
    // order the banks were opened in, then slot. A bank that is listed but not
    // read contributes nothing, and nothing here reads one.
    presets: function () {
      var out = [];
      banks.forEach(function (b, i) {
        if (archive && i > 0) return;
        if (bankUnopened(b)) return;
        b.patches.forEach(function (p, slot) {
          if (!p) return;
          out.push({
            key: presetKey(b.origin, b.label, slot, null, p.n),
            origin: b.origin, source: "bank", bank: b.label, bankIndex: i, slot: slot,
            archive: null, name: p.n, readOnly: bankReadOnly(b), live: false,
          });
        });
      });
      if (archive && archive.open && archive.bank !== null) {
        var named = archive.banks[archive.bank];
        archive.patches.forEach(function (name, j) {
          var from = { bank: archive.bank, patch: j };
          out.push({
            key: presetKey("archive", named, null, from, name),
            origin: "archive", source: "archive", bank: named, bankIndex: archive.bank + 1,
            slot: null, archive: from, name: name, readOnly: true, live: false,
          });
        });
      }
      // The sound with nothing behind it is a preset too: the one thing in the
      // list that is only here until it is saved.
      if (selection.origin === "session" || selection.origin === "file") {
        var live = selection.presetName || "Untitled";
        out.push({
          key: presetKey(selection.origin, "", null, null, live),
          origin: selection.origin, source: selection.source, bank: "", bankIndex: -1,
          slot: null, archive: null, name: live, readOnly: false, live: true,
        });
      }
      return out.map(function (p, at) { return { p: p, at: at }; }).sort(function (a, b) {
        return (ORIGIN_RANK[a.p.origin] - ORIGIN_RANK[b.p.origin]) ||
          (a.p.bankIndex - b.p.bankIndex) ||
          ((a.p.slot !== null ? a.p.slot : a.p.archive ? a.p.archive.patch : 0) -
           (b.p.slot !== null ? b.p.slot : b.p.archive ? b.p.archive.patch : 0)) ||
          (a.at - b.at);
      }).map(function (e) { return e.p; });
    },

    // Make a preset the sound: `{ bank, slot }` for an ordinary slot, or
    // `{ archive: { bank, patch } }` for the host's. A slot of the panel's own
    // loads now; an archive patch is asked of the host and the selection
    // moves when it answers, with `pending: true` until then. Refuses, rather
    // than substituting anything, a preset that is not there.
    loadPreset: function (ref) {
      var bad = function (code, message) { return refusal("load", code, message); };
      if (!ref || typeof ref !== "object") return bad("InvalidPreset", "No preset was named.");
      if (restoreState.state === "restoring") {
        return bad("RestorationConflict", "A restore is still waiting on the host. Wait for it, or keep the current sound.");
      }
      if (ref.archive) return loadArchive(ref.archive.bank, ref.archive.patch);
      var found = resolveBank(ref.bank);
      if (!found) return bad("UnavailableSource", "That bank is not open.");
      if (found.archive) return loadArchive(found.bank, ref.slot);
      var rec = found.rec;
      if (bankUnopened(rec)) return bad("UnavailableSource", rec.label + " has not been opened.");
      if (!isSlot(ref.slot)) return bad("InvalidPreset", "That is not a slot.");
      if (!rec.patches[ref.slot]) {
        return bad("InvalidPreset", "Slot " + slotWords(rec, ref.slot) + " is empty.");
      }
      userLoad(ref.slot, rec);
      var chosen = window.SynthBank.selection();
      return report({
        ok: true, action: "load", pending: false, selection: chosen, bank: rec.label,
        slot: ref.slot, name: chosen.presetName,
        message: "Loaded " + chosen.presetName + " from " + slotWords(rec, ref.slot) + ".",
      });
    },

    writePreset: function (req) { return writeSlot(req, "write"); },
    copySlot: function (from, to, options) { return transfer("copy", from, to, options); },
    moveSlot: function (from, to, options) { return transfer("move", from, to, options); },

    // Save where the sound came from, or ask where to put it.
    save: save,

    label: function (which) {
      var rec = which === undefined ? bank : banks[which];
      return rec ? rec.label : "";
    },
    setLabel: function (text) {
      window.SynthBank.renameBank(currentBank, text);
    },

    // The slots themselves. Names only -- a caller listing 128 rows does not
    // need 128 copies of 99 parameters.
    slots: function () {
      return bank.patches.map(function (p) { return p ? { name: p.n } : null; });
    },

    // The slot of the selection in the bank in view, or -1: the selection can
    // be somewhere else, and a browser looking elsewhere marks nothing.
    index: slotInView,
    load: function (i) { userLoad(i); },

    // Put the sound that is currently loaded into a slot of the bank in view.
    // The caller has asked for exactly this slot, so a sound already there is
    // replaced; use writePreset to be told instead.
    store: function (i, name) {
      var r = writeSlot({ bank: currentBank, slot: i, name: name || undefined, overwrite: true }, "write");
      return r.ok;
    },

    clear: function (i) {
      if (!isSlot(i)) return false;
      if (bankReadOnly(bank) || bankUnopened(bank)) {
        refusal("clear", "ReadOnlyBank", bank.label + " is read-only.");
        return false;
      }
      bank.patches[i] = null;
      if (i === slotInView()) {
        loadPatch(i, bank);
        announceSelection();
      } else {
        lastDirty = computeDirty();
        paintStrip();
      }
      flushStore();
      publishChanged([bank]);
      return true;
    },

    // One bank's slots, in the shape a file uses, for whatever is keeping
    // them. Takes an index because only some banks are worth keeping and the
    // caller decides which -- ui/store.js keeps the factory and no other.
    snapshot: function (which) {
      var b = banks[which];
      if (!b) return null;
      var last = -1;
      for (var i = 0; i < BANK_SLOTS; i++) if (b.patches[i]) last = i;
      return b.patches.slice(0, last + 1).map(function (p) {
        return p ? { n: p.n, v: p.v.slice() } : null;
      });
    },

    // Keep the open bank as the one this instrument comes back to.
    //
    // Only means anything with a host: in the browser the bank that persists
    // is the factory one and it is kept in local storage already.
    keep: keepBank,
    // Is there somewhere to keep a bank?
    //
    // Not simply "is there a host": the browser build has one too --
    // hosts/wasm registers window.synthPost and bridge finds it -- and it
    // has nowhere to put a bank, which is why store.js exists. So the
    // question is whether this is the browser, and the answer is whether
    // store.js is here: it is the one file deliberately not shipped to a
    // plugin, for exactly the reason that the two remember differently.
    hosted: function () {
      return bridge.host !== "standalone" && !window.SynthStore;
    },

    // The slots that actually hold something, for writing a file. Trailing
    // empties are dropped: a bank whose last sound is in slot 20 writes 21
    // entries, not 128, and padding puts it back where it was on the way in.
    used: function () {
      var last = -1;
      for (var i = 0; i < BANK_SLOTS; i++) if (bank.patches[i]) last = i;
      return bank.patches.slice(0, last + 1);
    },
  };

  // ------------------------------------------------------------------ wheels

  // Pitch bend and modulation, as a hardware keyboard has them.
  //
  // These are performance and not parameters: they are not in the patch, they are
  // not automated, and they go to the host as their own message. Pitch springs
  // back to centre when let go, because a bend that stayed where it was left would
  // detune the instrument silently; modulation stays, because that is the whole
  // use of it.
  var WHEELS = [
    { id: "pitch", label: "Pitch", centre: true, value: 0 },
    { id: "mod", label: "Mod", centre: false, value: 0 },
  ];

  function buildWheels() {
    var host = document.getElementById("wheels");
    if (!host) return;

    WHEELS.forEach(function (w) {
      var wrap = document.createElement("div");
      wrap.className = "wheel";

      var track = document.createElement("div");
      track.className = "wheel-track";
      track.setAttribute("role", "slider");
      track.setAttribute("aria-label", w.label + " wheel");
      track.setAttribute("aria-valuemin", w.centre ? "-1" : "0");
      track.setAttribute("aria-valuemax", "1");

      var thumb = document.createElement("div");
      thumb.className = "wheel-thumb";
      track.appendChild(thumb);

      var label = document.createElement("div");
      label.className = "wheel-label";
      label.textContent = w.label;

      wrap.appendChild(track);
      wrap.appendChild(label);
      host.appendChild(wrap);

      function paint() {
        // 0 at the bottom for modulation, centred for pitch. Which end of the
        // track that is, and which axis it runs along, is the stylesheet's
        // business -- this only publishes the fraction.
        var t = w.centre ? (w.value + 1) / 2 : w.value;
        track.style.setProperty("--t", t);
        track.setAttribute("aria-valuenow", w.value.toFixed(2));
      }

      // Read from the track's own shape rather than from a media query.
      //
      // The wheels stand beside the keys on a wide window and lie across the top
      // on a phone, which changes the axis the drag runs along. Measuring the
      // element means the two never disagree -- there is no breakpoint written
      // twice, and a window dragged across the breakpoint needs no relayout.
      function setFrom(e) {
        var r = track.getBoundingClientRect();
        var t = r.width > r.height
          ? (e.clientX - r.left) / r.width
          : 1 - (e.clientY - r.top) / r.height;
        t = Math.max(0, Math.min(1, t));
        w.value = w.centre ? t * 2 - 1 : t;
        paint();
        bridge.wheel(w.id, w.value);
      }

      // Tracked here rather than asked of `hasPointerCapture`, since capture is
      // allowed to have failed and the drag still has to work when it did.
      var dragging = false;

      track.addEventListener("pointerdown", function (e) {
        dragging = true;
        capture(track, e.pointerId);
        setFrom(e);
        e.preventDefault();
      });
      track.addEventListener("pointermove", function (e) {
        if (!dragging) return;
        setFrom(e);
      });
      function release(e) {
        if (!dragging) return;
        dragging = false;
        uncapture(track, e.pointerId);
        // Only the bend springs back. Modulation is meant to stay where it is put.
        if (!w.centre) return;
        w.value = 0;
        paint();
        bridge.wheel(w.id, 0);
      }
      track.addEventListener("pointerup", release);
      track.addEventListener("pointercancel", release);

      paint();

      // A controller's own wheel moving this one.
      //
      // Picture only: `midi.js` has already sent the value on, so echoing it
      // back through the bridge would send everything twice. A drag in
      // progress on screen wins, because the hand on the mouse is the more
      // specific intent and a stream of controller messages would otherwise
      // fight it.
      w.setExternal = function (value) {
        if (dragging) return;
        w.value = w.centre ? Math.max(-1, Math.min(1, value)) : Math.max(0, Math.min(1, value));
        paint();
      };
    });

    window.SynthWheels = {
      set: function (id, value) {
        for (var i = 0; i < WHEELS.length; i++) {
          if (WHEELS[i].id === id && WHEELS[i].setExternal) WHEELS[i].setExternal(value);
        }
      },
    };
  }

  // ------------------------------------------------------------------ wiring

  function connect() {
    // There is no status line any more. Which host was found is still worth being
    // able to find out, since a build that silently failed to inject its bridge is
    // otherwise merely inert, so it hangs off the one piece of chrome left.
    var brand = document.querySelector(".brand");
    if (brand) brand.title = "Host: " + bridge.host;

    bridge.onMessage(function (msg) {
      if (!msg || !msg.type) return;
      if (msg.type === "state" && Array.isArray(msg.values)) {
        // One whole sound arriving, so the question "is it changed?" is asked
        // once it is all here, not after each of the ninety-nine.
        settling = true;
        try {
          msg.values.forEach(function (v, i) {
            if (byIndex[i] !== undefined && typeof v === "number") setStored(i, v);
          });
        } finally {
          settling = false;
        }
        // A sound that has no slot to be compared with is what the host just
        // said it is.
        if (storedValues(selection) === baseline) baseline = liveValues();
        lastDirty = computeDirty();
        paintStrip();
      } else if (msg.type === "param" && typeof msg.index === "number") {
        setStored(msg.index, msg.value);
      } else if (msg.type === "bank" && typeof msg.text === "string") {
        try {
          adoptHostBank(msg);
        } catch (e) {
          console.error("bank from host:", e.message);
          say("The host sent a bank this panel could not read (" + e.message +
              "). The banks here are unchanged.", "error");
        }
        refreshBrowser();
      } else if (msg.type === "bank-saved") {
        receiveBankSaved(msg);
      } else if (msg.type === "restore") {
        receiveRestore(msg);
      } else if (msg.type === "archive" && Array.isArray(msg.banks) && Array.isArray(msg.patches)) {
        receiveArchive(msg);
      } else if (msg.type === "error" && /^archive-/.test(msg["for"] || "")) {
        archiveError = msg.message || msg.code;
        archiveWaiting = -1;
        if (msg["for"] === "archive-load" && pendingLoad) {
          pendingLoad = null;
          report({ ok: false, action: "load", error: {
            code: "HostRejected", message: "The host did not load that patch: " + archiveError } });
          paintStrip();
        }
        refreshBrowser();
      } else if (msg.type === "error" && msg["for"] === "bank") {
        // The host refused the bank the page sent. The page still shows it, so
        // say that the host does not have it.
        report({ ok: false, action: "persist", error: {
          code: "PersistenceFailed",
          message: "The host did not take the bank (" + (msg.message || msg.code || "refused") +
            "). The change is kept for this session only." } });
      } else if (msg.type === "patch") {
        receivePatch(msg);
      }
    });

    // Ask for the real state. With no host this does nothing and the defaults
    // already on screen stand.
    bridge.requestState();
  }

  document.addEventListener("DOMContentLoaded", function () {
    decorateIcons();
    build();

    buildBank();
    buildWheels();
    var keys = buildKeyboard();
    if (keys) {
      keyboardHeight = keys.height;
      // Once at startup too, so the tail accounts for the bank bar before the
      // keyboard has ever been deployed.
      document.documentElement.style.setProperty("--keys-h", "0px");
      keys.onDeploy(function () {
        // The panels are enclosed between the strip above and the bank and
        // keyboard below: the page keeps enough padding under it that the last
        // section can still be scrolled clear of both.
        //
        // The keyboard's height is published as a variable rather than written
        // into two places, because the bank bar sits on top of it and has to move
        // by exactly the same amount.
        var h = Math.round(keys.height());
        document.documentElement.style.setProperty("--keys-h", h + "px");
        // The surface and drawer consume this published scalar directly; no
        // second body-padding calculation is allowed to drift from it.
        relayout();
      });
    }

    connect();
  });
})();
