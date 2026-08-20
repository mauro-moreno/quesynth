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
  function positionOf(param, stored) {
    if (param.s) {
      var exact = param.s.indexOf(stored);
      if (exact >= 0) return exact;
      return stored < 0 ? 0 : param.s.length - 1;
    }
    if (stored < 0) return 0;
    if (stored >= param.n) return param.n - 1;
    return stored;
  }

  function storedOf(param, position) {
    if (param.s) return param.s[Math.max(0, Math.min(param.s.length - 1, position))];
    return Math.max(0, Math.min(param.n - 1, position));
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
      svg.setAttribute("aria-valuetext", valueText(param, position));
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
      b.textContent = by < 0 ? "−" : "+";
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
      if (readout) {
        var position = positionOf(param, values[param.i]);
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
      };
      dependOn(spec.depends, relabel);
      // Once now, so the control opens with the label its current type calls for
      // rather than with the placeholder in the layout.
      relabel();
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
    var inner = document.querySelector("#nav .nav-inner");
    var buttons = {};

    sections.forEach(function (s) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = s.title;
      b.setAttribute("aria-current", "false");
      b.addEventListener("click", function () {
        s.el.scrollIntoView({ block: "start", behavior: "smooth" });
      });
      inner.appendChild(b);
      buttons[s.id] = b;
    });

    // Which section is being looked at: the last one whose top has passed under
    // the sticky bar.
    //
    // "The topmost section still on screen" is the obvious rule and it is wrong.
    // Jumping to a section leaves the previous one's last row still poking into
    // view, so the topmost thing on screen is the section you just left and the
    // mark stays behind by one the whole way down the page.
    // Read from the stylesheet rather than repeated here, so the bar's height is
    // stated once and the scroll offset and this test cannot disagree. A section
    // that has just been jumped to sits exactly on the bar, so the test needs a
    // few pixels of slack under it.
    var navH = parseInt(
      getComputedStyle(document.documentElement).getPropertyValue("--nav-h"), 10) || 37;
    var line = navH + 8;
    var marked = null;

    function updateCurrent() {
      var current = sections[0].id;
      for (var i = 0; i < sections.length; i++) {
        if (sections[i].el.getBoundingClientRect().top <= line) current = sections[i].id;
      }

      if (current === marked) return;
      marked = current;

      sections.forEach(function (s) {
        buttons[s.id].setAttribute("aria-current", s.id === current ? "true" : "false");
      });

      // Keep the marked entry inside the strip when the strip itself has scrolled.
      var active = buttons[current];
      var left = active.offsetLeft, right = left + active.offsetWidth;
      if (left < inner.scrollLeft || right > inner.scrollLeft + inner.clientWidth) {
        inner.scrollTo({ left: left - 12, behavior: "smooth" });
      }
    }

    // Driven by scroll, coalesced onto a frame.
    //
    // An IntersectionObserver was tried first and cannot do this on its own: the
    // bottom-of-page case above needs to be re-evaluated while the page is still
    // moving but no boundary is being crossed, and the observer stays silent
    // through exactly that stretch. The cost of the scroll listener is nil where
    // it would have mattered -- a knob sets `touch-action: none` and captures the
    // pointer, so dragging one never scrolls the page and never runs this.
    // Enough room after the last section that it can still reach the top.
    //
    // Without this the last two or three sections are unreachable in the only
    // sense that matters here: the page runs out of scroll before their tops get
    // to the bar, so selecting one scrolls as far as it can and then marks a
    // different section, which reads as the navigation being broken. Special
    // casing the bottom was tried and only moved the wrongness around -- with
    // three sections sharing the last screen there is no rule that picks the one
    // the player asked for. Giving them the room instead makes the ordinary rule
    // correct everywhere.
    //
    // Sized to exactly what is missing, so a tall last section adds nothing and a
    // short one adds only the difference.
    var main = document.getElementById("panels");
    var bank = document.getElementById("bank");
    function sizeTail() {
      main.style.paddingBottom = "0px";
      var last = sections[sections.length - 1].el;
      // The bank bar and, when it is out, the keyboard both cover the foot of the
      // window, so the room the last section has to climb into is smaller by both.
      var below = keyboardHeight() + (bank ? bank.getBoundingClientRect().height : 0);
      var missing = window.innerHeight - navH - below -
        last.getBoundingClientRect().height;
      main.style.paddingBottom = Math.max(0, Math.round(missing)) + "px";
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

    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onResize, { passive: true });
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

  var KEY_PHONE_LOW = 24;   // C1
  var KEY_PHONE_HIGH = 84;  // C6
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

    var phone = window.matchMedia("(max-width: 560px)").matches;
    var low = phone ? KEY_PHONE_LOW : KEY_FULL_LOW;
    var high = phone ? KEY_PHONE_HIGH : KEY_FULL_HIGH;

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

  // The patch and bank readout, and the two steps either side of it.
  //
  // Purely a view plus two requests: the interface does not hold a bank, it asks
  // the host to change patch and waits to be told what happened. Anything else
  // would put a second idea of "what is loaded" in the panel, and the whole state
  // model here rests on there being one.
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

  // Every bank that is open, not just the one being played.
  //
  // Loading a file used to replace the bank outright, so the list down the side
  // of the browser only ever had one row in it and there was nothing to
  // navigate between. Holding them means a file can be *added* -- and means
  // switching away from a bank and back does not lose what was saved into it,
  // because each one keeps its own slots.
  var banks = [normalizeBank(window.SYNTH1_BANK)];
  var currentBank = 0;
  var bank = banks[0];
  // Whether anything was compiled into the page at all. An empty bank of a
  // hundred and twenty-eight Inits is still a bank you can save into, but the
  // strip must not claim a patch is loaded before one is.
  var bankSupplied = !!(window.SYNTH1_BANK && window.SYNTH1_BANK.patches &&
                        window.SYNTH1_BANK.patches.length);
  // What is loaded right now, whether it came from the bank or from a file.
  var currentName = "";
  var bankIndex = -1;

  function buildBank() {
    var el = document.getElementById("bank");
    if (!el) return;

    var steps = el.querySelectorAll(".bank-step");
    for (var i = 0; i < steps.length; i++) {
      (function (b) {
        b.addEventListener("click", function (e) {
          e.stopPropagation();
          var step = parseInt(b.dataset.step, 10);
          if (bank) {
            loadPatch(bankIndex + step);
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
        if (window.SynthBrowser) window.SynthBrowser.open();
        else showBankList(read);
      });
    }

    var name = document.getElementById("bank-name");
    if (name) name.textContent = bank.label;
    // Only when a bank actually came with the page. There is always a bank now
    // -- an empty one is still 128 slots you can save into -- but loading slot
    // zero of it would send an Init patch to the host, and in a plugin the host
    // has its own state and got there first. A panel that overwrote it on
    // startup would lose the user's sound every time the window was opened.
    if (bankSupplied) loadPatch(0);
  }

  // Load one patch out of the compiled-in bank.
  //
  // Every parameter goes at once rather than as ninety-nine separate messages:
  // the engine rebinds on each one, and a patch change that rebound a hundred
  // times would be audible as a smear rather than a change.
  function loadPatch(index) {
    if (!bank) return;
    var n = BANK_SLOTS;
    // Wraps, so stepping past either end is a way round rather than a dead stop.
    bankIndex = ((index % n) + n) % n;
    // An empty slot loads as Init rather than being skipped over. Skipping
    // would make the empty ones invisible to the arrows, and then there would
    // be no way to arrive at one in order to save into it.
    var p = bank.patches[bankIndex] || { n: "Init", v: initValues() };

    for (var i = 0; i < p.v.length; i++) {
      if (byIndex[i] !== undefined) values[i] = p.v[i];
    }
    // Repaint everything, including the controls whose label follows another
    // parameter -- a new patch can change the effect type under Control 1.
    for (var k in controls) controls[k]();
    for (var d in dependents) {
      dependents[d].forEach(function (fn) { fn(); });
    }

    currentName = p.n;
    bridge.send({ type: "state", values: p.v });
    showPatch({ name: p.n, index: bankIndex, bank: bank.label });
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
        b.textContent = pad3(i) + "  " + p.n;
        b.addEventListener("click", function () {
          loadPatch(i);
          list.classList.remove("open");
        });
        list.appendChild(b);
      });
    }

    var kids = list.children;
    for (var i = 0; i < kids.length; i++) {
      kids[i].setAttribute("aria-current", i === bankIndex ? "true" : "false");
    }

    list.classList.add("open");
    var r = anchor.getBoundingClientRect();
    var w = list.offsetWidth;
    list.style.left = Math.round(Math.max(8,
      Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 8))) + "px";
    list.style.bottom = Math.round(window.innerHeight - r.top + 8) + "px";
    // Bring the current patch into view rather than always opening at the top.
    if (kids[bankIndex]) kids[bankIndex].scrollIntoView({ block: "center" });
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
    values: function () {
      var out = [];
      for (var i = 0; i < PARAMS.length; i++) {
        out.push(values[PARAMS[i].i] !== undefined ? values[PARAMS[i].i] : PARAMS[i].def);
      }
      return out;
    },

    // The name of what is actually loaded, which is not always the bank's.
    //
    // Reading it off `bank.patches[bankIndex]` was wrong and testing found it:
    // loading a patch *file* leaves the bank index where it was, so a save
    // straight afterwards wrote the loaded patch's parameters under the
    // neighbouring bank entry's name. `currentName` is set by both paths.
    name: function () {
      return currentName || "Patch";
    },

    // Apply a whole patch. Goes through the same path a bank patch does, so a
    // loaded file cannot end up shown differently from one that was stepped to.
    apply: function (list, name) {
      for (var i = 0; i < list.length; i++) {
        if (byIndex[i] !== undefined) values[i] = list[i];
      }
      for (var k in controls) controls[k]();
      for (var d in dependents) {
        dependents[d].forEach(function (fn) { fn(); });
      }
      currentName = name || "Patch";
      bridge.send({ type: "state", values: list });
      showPatch({ name: currentName, index: null, bank: bank ? bank.label : "" });
    },

    // The bank as it stands, and a way to replace it. Replacing rebuilds the
    // list popover, which is cached after its first open.
    bank: function () {
      return bank;
    },

    // Add a bank and switch to it. Replaces one already open under the same
    // name -- opening the same file twice should not give two identical rows.
    setBank: function (label, patches) {
      var made = normalizeBank({ label: label, patches: patches });
      var at = -1;
      for (var i = 0; i < banks.length; i++) if (banks[i].label === made.label) at = i;
      if (at >= 0) { banks[at] = made; currentBank = at; }
      else { banks.push(made); currentBank = banks.length - 1; }
      bank = made;
      bankSupplied = true;
      bankIndex = 0;
      var list = document.getElementById("bank-list");
      if (list) {
        list.textContent = "";
        list.classList.remove("open");
      }
      loadPatch(0);
    },
  };

  function emptyBank(label) {
    return normalizeBank({ label: label, patches: [] });
  }

  // The bank as slots: what the browser and the file menu both work through.
  window.SynthBank = {
    SLOTS: BANK_SLOTS,

    // Every open bank, for the list down the side.
    list: function () {
      return banks.map(function (b, i) {
        var used = 0;
        for (var j = 0; j < b.patches.length; j++) if (b.patches[j]) used++;
        return { label: b.label, used: used, current: i === currentBank };
      });
    },

    current: function () { return currentBank; },

    // Switch to another open bank. `quiet` leaves the sound alone, which is
    // what looking for somewhere to save wants: choosing a destination must not
    // overwrite the thing being saved.
    select: function (i, quiet) {
      if (i < 0 || i >= banks.length || i === currentBank) return;
      currentBank = i;
      bank = banks[i];
      var name = document.getElementById("bank-name");
      if (name) name.textContent = bank.label;
      if (quiet) {
        // No slot number. The sound in the engine did not come from this bank,
        // so claiming a slot in it would be a lie -- and a specific one: it
        // would read "060:Lead Copy" over a bank whose slot 60 is empty.
        // Nothing is loaded here on purpose; see the write mode in browser.js.
        bankIndex = -1;
        showPatch({ name: currentName, index: null, bank: bank.label });
      } else {
        loadPatch(0);
      }
    },

    // A new empty bank: 128 slots with nothing in them, which is a perfectly
    // good bank to start writing sounds into.
    create: function (label) {
      var wanted = String(label || "New Bank");
      // Names are how the list is read, so two banks called the same thing
      // would be two rows nobody can tell apart.
      var name = wanted, n = 2;
      while (banks.some(function (b) { return b.label === name; })) {
        name = wanted + " " + n++;
      }
      banks.push(emptyBank(name));
      window.SynthBank.select(banks.length - 1, true);
      return banks.length - 1;
    },

    label: function () { return bank.label; },
    setLabel: function (text) {
      bank.label = String(text || "Bank");
      showPatch({ name: currentName, index: bankIndex, bank: bank.label });
    },

    // The slots themselves. Names only -- a caller listing 128 rows does not
    // need 128 copies of 99 parameters.
    slots: function () {
      return bank.patches.map(function (p) { return p ? { name: p.n } : null; });
    },

    index: function () { return bankIndex; },
    load: function (i) { loadPatch(i); },

    // Put the sound that is currently loaded into a slot.
    store: function (i, name) {
      if (i < 0 || i >= BANK_SLOTS) return false;
      bank.patches[i] = { n: String(name || currentName || "Untitled"),
                          v: window.SynthPatch.values() };
      bankIndex = i;
      currentName = bank.patches[i].n;
      showPatch({ name: currentName, index: i, bank: bank.label });
      return true;
    },

    clear: function (i) {
      if (i < 0 || i >= BANK_SLOTS) return false;
      bank.patches[i] = null;
      if (i === bankIndex) loadPatch(i);
      return true;
    },

    // Replace the whole bank, padding to the slot count. The same call the
    // file menu makes through SynthPatch.setBank; both are here so neither can
    // drift into padding differently.
    replace: function (label, patches) {
      window.SynthPatch.setBank(label, patches);
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

  function showPatch(msg) {
    var p = document.getElementById("bank-patch");
    var b = document.getElementById("bank-name");
    if (p && msg.name) {
      p.textContent = (msg.index != null ? pad3(msg.index) + ":" : "") + msg.name;
    }
    if (b && msg.bank) b.textContent = msg.bank;
    // Only in the bank bar at the foot. It used to be repeated in the strip
    // beside the name, which said the same thing twice and made the one piece
    // of fixed chrome change width as patches were stepped through.
  }

  function pad3(n) {
    var s = String(n);
    return s.length >= 3 ? s : ("000" + s).slice(-3);
  }

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
        msg.values.forEach(function (v, i) {
          if (byIndex[i] !== undefined && typeof v === "number") setStored(i, v);
        });
      } else if (msg.type === "param" && typeof msg.index === "number") {
        setStored(msg.index, msg.value);
      } else if (msg.type === "patch") {
        showPatch(msg);
      }
    });

    // Ask for the real state. With no host this does nothing and the defaults
    // already on screen stand.
    bridge.requestState();
  }

  document.addEventListener("DOMContentLoaded", function () {
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
        var bank = document.getElementById("bank");
        var bankH = bank ? bank.getBoundingClientRect().height : 0;
        document.body.style.paddingBottom = Math.round(h + bankH + 8) + "px";
        relayout();
      });
    }

    connect();
  });
})();
