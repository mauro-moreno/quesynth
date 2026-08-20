// The bank browser: which banks there are, and what is in the one you are in.
//
// Laid out the way the reference's List/Info window is, because that layout is
// not arbitrary -- sources down the left, slots across the right in numbered
// columns. A player who knows the sound is "somewhere in the forties" finds it
// by running down the numbers, which a single alphabetical column does not
// allow and a name-only popover does not either.
//
// The slots are the point. All hundred and twenty-eight are listed, the empty
// ones included and visibly empty, because an empty slot is a place to put
// something and hiding it would leave no way to arrive at one.

(function () {
  "use strict";

  function api() { return window.SynthBank; }

  // Sources down the left. The bank compiled into the page is always there;
  // anything loaded from a file joins it for as long as the page is open.
  var sources = [];

  function registerSource(entry) {
    // Same label twice replaces, so loading the same file again does not stack
    // up identical rows.
    var at = -1;
    for (var i = 0; i < sources.length; i++) if (sources[i].label === entry.label) at = i;
    if (at >= 0) sources[at] = entry; else sources.push(entry);
  }

  function used(slots) {
    var n = 0;
    for (var i = 0; i < slots.length; i++) if (slots[i]) n++;
    return n;
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
    // Again on the next frame. The first call happens while the dialog is
    // still being assembled, when the grid has no width yet and the answer is
    // therefore one column -- which then visibly snaps to two. The observer
    // below would correct it either way; this stops it being seen.
    requestAnimationFrame(apply);
    if (window.ResizeObserver) {
      if (grid._ro) grid._ro.disconnect();
      grid._ro = new ResizeObserver(apply);
      grid._ro.observe(grid);
    }
  }

  function pad3(n) {
    var s = String(n);
    return s.length >= 3 ? s : ("000" + s).slice(-3);
  }

  // ------------------------------------------------------------------ render

  function build() {
    var wrap = document.createElement("div");
    wrap.className = "browser";

    var left = document.createElement("div");
    left.className = "browser-sources";
    var right = document.createElement("div");
    right.className = "browser-slots";

    var panes = document.createElement("div");
    panes.className = "browser-panes";
    panes.appendChild(left);
    panes.appendChild(right);
    wrap.appendChild(panes);

    function paintSources() {
      left.textContent = "";
      var heading = document.createElement("div");
      heading.className = "browser-heading";
      heading.textContent = "Banks";
      left.appendChild(heading);

      var current = api().label();
      sources.forEach(function (src) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "browser-source" + (src.label === current ? " on" : "");
        var name = document.createElement("span");
        name.className = "browser-source-name";
        name.textContent = src.label;
        var count = document.createElement("span");
        count.className = "browser-source-count";
        count.textContent = src.count != null ? "(" + src.count + ")" : "";
        b.appendChild(name);
        b.appendChild(count);
        b.addEventListener("click", function () {
          if (src.label === api().label()) return;
          src.select();
          paintSources();
          paintSlots();
        });
        left.appendChild(b);
      });

      var load = document.createElement("button");
      load.type = "button";
      load.className = "browser-open";
      load.textContent = "Open a file…";
      load.addEventListener("click", function () {
        if (window.SynthPatchFile && window.SynthPatchFile.pick) {
          window.SynthPatchFile.pick(function () {
            syncCurrent();
            paintSources();
            paintSlots();
          });
        }
      });
      left.appendChild(load);
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
      count.textContent = used(slots) + " of " + slots.length + " used";
      head.appendChild(title);
      head.appendChild(count);
      right.appendChild(head);

      var grid = document.createElement("div");
      grid.className = "browser-grid";
      var here = api().index();

      slots.forEach(function (slot, i) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "browser-slot" + (slot ? "" : " empty") + (i === here ? " on" : "");
        if (i === here) b.setAttribute("aria-current", "true");

        var num = document.createElement("span");
        num.className = "browser-slot-num";
        num.textContent = pad3(i);

        var name = document.createElement("span");
        name.className = "browser-slot-name";
        name.textContent = slot ? slot.name : "—";

        b.appendChild(num);
        b.appendChild(name);
        b.addEventListener("click", function () {
          api().load(i);
          paintSlots();
        });
        // Double-click loads and closes, which is what picking a sound to play
        // usually means.
        b.addEventListener("dblclick", function () {
          api().load(i);
          window.SynthModal.close();
        });
        grid.appendChild(b);
      });

      right.appendChild(grid);
      layoutGrid(grid, slots.length);

      // Keep the slot you are on in view when the browser is opened on a patch
      // somewhere down in the nineties.
      var on = grid.querySelector(".browser-slot.on");
      if (on) setTimeout(function () { on.scrollIntoView({ block: "center" }); }, 0);
    }

    // The bank the panel is actually on may have arrived from a file since the
    // browser was last open; make sure it is one of the rows.
    function syncCurrent() {
      registerSource({
        label: api().label(),
        count: used(api().slots()),
        select: function () { /* already current */ },
      });
    }

    syncCurrent();
    paintSources();
    paintSlots();

    wrap.refresh = function () { syncCurrent(); paintSources(); paintSlots(); };
    return wrap;
  }

  function open() {
    if (!api()) return;
    var body = build();

    // The save row: a name and a slot, shown only when asked for.
    //
    // Not window.prompt. A plugin's web view is entitled to refuse it, and the
    // panel would then have a button that silently does nothing in the one
    // build where the sound most needs keeping.
    var save = document.createElement("form");
    save.className = "browser-save";
    save.hidden = true;
    var field = document.createElement("input");
    field.type = "text";
    field.className = "browser-save-name";
    field.setAttribute("aria-label", "Patch name");
    var where = document.createElement("span");
    where.className = "browser-save-slot";
    var confirm = document.createElement("button");
    confirm.type = "submit";
    confirm.className = "modal-action primary";
    confirm.textContent = "Save";
    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "modal-action";
    cancel.textContent = "Cancel";
    save.appendChild(where);
    save.appendChild(field);
    save.appendChild(confirm);
    save.appendChild(cancel);
    body.appendChild(save);

    function hideSave() { save.hidden = true; }
    cancel.addEventListener("click", hideSave);
    save.addEventListener("submit", function (e) {
      e.preventDefault();
      var name = field.value.trim();
      if (!name) { field.focus(); return; }
      api().store(currentTarget, name);
      hideSave();
      body.refresh();
    });

    var currentTarget = 0;
    function askSave() {
      currentTarget = api().index();
      var slot = api().slots()[currentTarget];
      where.textContent = "Slot " + pad3(currentTarget);
      field.value = slot ? slot.name : (window.SynthPatch.name() || "Untitled");
      save.hidden = false;
      field.focus();
      field.select();
    }

    window.SynthModal.show("Patches", body, [
      { label: "Save into this slot…", onClick: askSave },
      { label: "Done", primary: true, onClick: function (close) { close(); } },
    ]);
  }

  window.SynthBrowser = {
    open: open,
    // So the file menu can add what it loads to the list down the left.
    registerSource: registerSource,
  };
})();
