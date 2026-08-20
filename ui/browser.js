// The bank browser: which banks are open, and what is in the one you are in.
//
// Laid out the way the reference's List/Info window is, because that layout is
// not arbitrary -- banks down the left, slots down the right in numbered
// columns, filling downward. A player who knows the sound is "somewhere in the
// forties" finds it by running down the numbers, which a single alphabetical
// column does not allow and a name-only popover does not either.
//
// All hundred and twenty-eight slots are listed, the empty ones included and
// visibly empty, because an empty slot is a place to put something and hiding
// it would leave no way to arrive at one.
//
// Two modes, and the difference between them is the whole reason there are two.
//
//   load    picking a sound to play. A click loads it.
//   write   picking somewhere to put the sound you already have. A click
//           chooses a destination and loads nothing.
//
// Write cannot share the load behaviour. The sound being written is the one
// currently in the engine, so a browser that loaded on click would overwrite it
// the moment you went looking for somewhere to put it: you would arrive at the
// slot having already lost what you came to save. That is not a detail of the
// interface, it is why hardware has a Write button rather than a Save item in a
// menu.

(function () {
  "use strict";

  function api() { return window.SynthBank; }
  function files() { return window.SynthPatchFile; }

  function pad3(n) {
    var s = String(n);
    return s.length >= 3 ? s : ("000" + s).slice(-3);
  }

  // How many columns fit, and therefore how many rows deep each one runs.
  //
  // Measured rather than assumed: the dialog is 760px at its widest and a
  // single column on a phone, and the answer has to be right at both ends or
  // the numbers stop being findable.
  var MIN_COLUMN = 190;
  function layoutGrid(grid, count) {
    var apply = function () {
      var width = grid.clientWidth || MIN_COLUMN;
      var columns = Math.max(1, Math.floor(width / MIN_COLUMN));
      var rows = Math.ceil(count / columns);
      grid.style.gridTemplateColumns = "repeat(" + columns + ", minmax(0, 1fr))";
      grid.style.gridTemplateRows = "repeat(" + rows + ", auto)";
    };
    apply();
    // Again on the next frame. The first call happens while the dialog is still
    // being assembled, when the grid has no width yet and the answer is
    // therefore one column -- which then visibly snaps to two.
    requestAnimationFrame(apply);
    if (window.ResizeObserver) {
      if (grid._ro) grid._ro.disconnect();
      grid._ro = new ResizeObserver(apply);
      grid._ro.observe(grid);
    }
  }

  function button(className, text) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = className;
    if (text != null) b.textContent = text;
    return b;
  }

  // ---------------------------------------------------------------- the body

  function build(mode) {
    var writing = mode === "write";
    // In write mode this is the destination, and it starts where you already
    // are, so writing back to the same slot takes no navigation at all. It can
    // be -1 -- after switching banks nothing in this one is loaded -- and the
    // top of the bank is the sensible place to start from then.
    var target = Math.max(0, api().index());
    var field = null, where = null;

    // Move the destination, and everything that shows it, together.
    function setTarget(i) {
      target = i;
      if (where) where.textContent = "Slot " + pad3(i);
      if (field) {
        // The name of the sound being written, not of the one being replaced.
        //
        // The other way round is a trap: pick a slot holding "Strings", write
        // an organ into it without reading the field, and the bank now has an
        // organ called Strings. Re-saving a patch over itself still offers its
        // own name, because in that case they are the same name.
        field.value = window.SynthPatch.name() || "Untitled";
      }
    }

    var wrap = document.createElement("div");
    wrap.className = "browser";

    var panes = document.createElement("div");
    panes.className = "browser-panes";
    var left = document.createElement("div");
    left.className = "browser-sources";
    var right = document.createElement("div");
    right.className = "browser-slots";
    panes.appendChild(left);
    panes.appendChild(right);
    wrap.appendChild(panes);

    function paintSources() {
      left.textContent = "";

      var head = document.createElement("div");
      head.className = "browser-heading";
      var label = document.createElement("span");
      label.textContent = "Banks";
      head.appendChild(label);

      var actions = document.createElement("span");
      actions.className = "browser-heading-actions";

      // Somewhere to write to that is not the factory bank.
      var make = button("browser-mini", "New");
      make.title = "A new empty bank";
      make.addEventListener("click", function () {
        api().create("New Bank");
        if (writing) setTarget(0);
        paintSources();
        paintSlots();
      });

      // A bank from a file, joining the list rather than replacing it.
      var add = button("browser-mini", "Add");
      add.title = "Open a bank or patch file";
      add.addEventListener("click", function () {
        if (files() && files().pick) {
          files().pick(function () { paintSources(); paintSlots(); });
        }
      });

      actions.appendChild(make);
      actions.appendChild(add);
      head.appendChild(actions);
      left.appendChild(head);

      api().list().forEach(function (b, i) {
        var row = button("browser-source" + (b.current ? " on" : ""));
        var name = document.createElement("span");
        name.className = "browser-source-name";
        name.textContent = b.label;
        var count = document.createElement("span");
        count.className = "browser-source-count";
        count.textContent = b.used;
        row.appendChild(name);
        row.appendChild(count);
        row.addEventListener("click", function () {
          // Quietly when writing: choosing which bank to save into must not
          // load anything, or the sound being saved is the one it replaces.
          api().select(i, writing);
          if (writing) setTarget(0);
          paintSources();
          paintSlots();
        });
        left.appendChild(row);
      });
    }

    function paintSlots() {
      right.textContent = "";

      var head = document.createElement("div");
      head.className = "browser-slots-head";
      var title = document.createElement("span");
      title.className = "browser-bank-name";
      title.textContent = api().label();
      var count = document.createElement("span");
      count.className = "browser-bank-count";
      var slots = api().slots();
      count.textContent = slots.filter(Boolean).length + " of " + slots.length + " used";
      head.appendChild(title);
      head.appendChild(count);
      right.appendChild(head);

      var grid = document.createElement("div");
      grid.className = "browser-grid";
      var here = api().index();

      slots.forEach(function (slot, i) {
        var marked = writing ? i === target : i === here;
        var b = button("browser-slot" + (slot ? "" : " empty") +
                       (marked ? (writing ? " target" : " on") : ""));
        if (marked) b.setAttribute("aria-current", "true");

        var num = document.createElement("span");
        num.className = "browser-slot-num";
        num.textContent = pad3(i);

        var name = document.createElement("span");
        name.className = "browser-slot-name";
        name.textContent = slot ? slot.name : "—";

        b.appendChild(num);
        b.appendChild(name);

        b.addEventListener("click", function () {
          if (writing) {
            setTarget(i);
            paintSlots();
          } else {
            api().load(i);
            paintSlots();
          }
        });
        if (!writing) {
          b.addEventListener("dblclick", function () {
            api().load(i);
            window.SynthModal.close();
          });
        }
        grid.appendChild(b);
      });

      right.appendChild(grid);
      layoutGrid(grid, slots.length);

      var on = grid.querySelector(".browser-slot.on, .browser-slot.target");
      if (on) setTimeout(function () { on.scrollIntoView({ block: "center" }); }, 0);
    }

    // The write row: present the whole time in write mode, because it is the
    // point of the dialog rather than something hidden behind a button.
    if (writing) {
      var row = document.createElement("form");
      row.className = "browser-save";
      where = document.createElement("span");
      where.className = "browser-save-slot";
      where.textContent = "Slot " + pad3(target);
      field = document.createElement("input");
      field.type = "text";
      field.className = "browser-save-name";
      field.setAttribute("aria-label", "Patch name");
      var at = api().slots()[target];
      field.value = at ? at.name : (window.SynthPatch.name() || "Untitled");
      var go = document.createElement("button");
      go.type = "submit";
      go.className = "modal-action primary";
      go.textContent = "Write";
      row.appendChild(where);
      row.appendChild(field);
      row.appendChild(go);
      row.addEventListener("submit", function (e) {
        e.preventDefault();
        var name = field.value.trim();
        if (!name) { field.focus(); return; }
        api().store(target, name);
        window.SynthModal.close();
      });
      wrap.appendChild(row);
    }

    paintSources();
    paintSlots();

    wrap.refresh = function () { paintSources(); paintSlots(); };
    wrap.focusField = function () { if (field) { field.focus(); field.select(); } };
    return wrap;
  }

  // -------------------------------------------------------------------- open

  function open(mode) {
    if (!api()) return;
    var writing = mode === "write";
    var body = build(mode);

    var actions = writing
      ? [{ label: "Cancel", onClick: function (close) { close(); } }]
      : [
          {
            label: "Save patch…",
            onClick: function () { if (files() && files().savePatch) files().savePatch(); },
          },
          {
            label: "Save bank…",
            onClick: function () { if (files() && files().saveBank) files().saveBank(); },
          },
          { label: "Done", primary: true, onClick: function (close) { close(); } },
        ];

    window.SynthModal.show(writing ? "Write" : "Patches", body, actions);
    if (writing) body.focusField();
  }

  window.SynthBrowser = {
    open: function () { open("load"); },
    write: function () { open("write"); },
  };
})();
