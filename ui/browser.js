// The preset browser, and the bank browser behind it.
//
// Two views of the same banks, because people ask two different questions of
// them.
//
//   Presets   "where is that pad I made?" Names across everything the panel
//             already knows, narrowed by where a sound came from, by what is
//             a favourite, by what was played lately. It is the view that opens,
//             because looking for a sound by name is what most visits are for.
//   Slots     "what is in slot 41?" The reference's List/Info layout, which is
//             not arbitrary -- banks down the left, slots down the right in
//             numbered columns, filling downward. A player who knows the sound
//             is "somewhere in the forties" finds it by running down the
//             numbers, which a single alphabetical column does not allow.
//
// All hundred and twenty-eight slots are listed in the slot view, the empty
// ones included and visibly empty, because an empty slot is a place to put
// something and hiding it would leave no way to arrive at one. The preset view
// lists only what is a preset, which an empty slot is not.
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

  function element(tag, className, text) {
    var e = document.createElement(tag);
    if (className) e.className = className;
    if (text != null) e.textContent = text;
    return e;
  }

  function button(className, text) {
    var b = element("button", className, text);
    b.type = "button";
    return b;
  }

  // ------------------------------------------- favourites and recently used
  //
  // The person's habits, and nothing else's business. They are kept apart from
  // everything that describes the instrument: not in a bank, so an export never
  // carries them; not in the plugin's state, which belongs to the host; not in
  // any message to one. Where there is somewhere that is only the browser's
  // (ui/store.js, which a plugin does not load) they are kept there, under a key
  // of their own; everywhere else they last as long as the editor does, which
  // is all a preference can ask of a host that has nowhere to put one.

  var RECENT_MAX = 20;
  var prefs = null;

  function loadPrefs() {
    if (prefs) return prefs;
    var store = window.SynthStore;
    var kept = store && store.prefs ? store.prefs() : null;
    prefs = {
      favorites: kept && Array.isArray(kept.favorites) ? kept.favorites.slice() : [],
      recent: kept && Array.isArray(kept.recent) ? kept.recent.slice(0, RECENT_MAX) : [],
    };
    return prefs;
  }

  function savePrefs() {
    var store = window.SynthStore;
    if (store && store.setPrefs) {
      store.setPrefs({ favorites: prefs.favorites.slice(), recent: prefs.recent.slice() });
    }
  }

  function isFavorite(key) {
    return loadPrefs().favorites.indexOf(key) >= 0;
  }

  function toggleFavorite(key) {
    var list = loadPrefs().favorites;
    var at = list.indexOf(key);
    if (at >= 0) list.splice(at, 1);
    else list.push(key);
    savePrefs();
  }

  function noteRecent(key) {
    var list = loadPrefs().recent;
    var at = list.indexOf(key);
    if (at >= 0) list.splice(at, 1);
    list.unshift(key);
    if (list.length > RECENT_MAX) list.length = RECENT_MAX;
    savePrefs();
  }

  // What names a preset to the things that remember it. The format is
  // `presets()[].key` in app.js, which is where it is explained; it is
  // rebuilt here only for an archive patch that is not in that list yet.
  var NUL = "\u0000";

  function keyOf(origin, label, slot, from, name) {
    var where = slot !== null ? String(slot) : from ? "a" + from.bank + "." + from.patch : "";
    return origin + NUL + label + NUL + where + NUL + name;
  }

  // A favourite or a recent whose preset is not there now. It keeps what the
  // key says about it so that it can be shown and, in the case of a favourite,
  // un-starred; it carries nothing that could be loaded.
  function missing(key) {
    var parts = key.split(NUL);
    var where = parts[2] || "";
    var archive = /^a(\d+)\.(\d+)$/.exec(where);
    return {
      key: key, origin: parts[0], source: "", bank: parts[1] || "", bankIndex: -1,
      slot: /^\d+$/.test(where) ? Number(where) : null,
      archive: archive ? { bank: Number(archive[1]), patch: Number(archive[2]) } : null,
      name: parts.slice(3).join(NUL), readOnly: false, live: false, unavailable: true,
    };
  }

  function positionOf(p) {
    return p.slot !== null ? p.slot : p.archive ? p.archive.patch : null;
  }

  // Is this preset the one that is playing? By where it is, not by what it is
  // called: two slots may share a name, and a slot may have been rewritten.
  function isPlaying(p, sel) {
    if (p.unavailable) return false;
    if (p.live) return sel.origin === "session" || sel.origin === "file";
    if (p.archive) {
      return !!sel.archive && sel.archive.bank === p.archive.bank &&
        sel.archive.patch === p.archive.patch;
    }
    return sel.slot !== null && sel.slot === p.slot && sel.bank === p.bank;
  }

  // The key of the preset a selection is, or null for one that is not a stored
  // preset: an empty slot loads as Init and is not worth remembering.
  function keyOfSelection(sel) {
    var all = api().presets();
    for (var i = 0; i < all.length; i++) {
      if (!all[i].live && isPlaying(all[i], sel)) return all[i].key;
    }
    var a = api().archive();
    if (sel.archive && a && a.banks[sel.archive.bank] !== undefined) {
      return keyOf("archive", a.banks[sel.archive.bank], null, sel.archive, sel.presetName);
    }
    return null;
  }

  // Which of the five source filters a preset belongs to. A single patch opened
  // from a file is the sound that is playing and nothing else yet, so it sits
  // with the current session rather than with a bank it is not in.
  var SOURCES = [
    { id: "factory", label: "Factory", origins: ["factory"] },
    { id: "user", label: "User", origins: ["user"] },
    { id: "imported", label: "Imported", origins: ["imported"] },
    { id: "archive", label: "Archives", origins: ["archive"] },
    { id: "session", label: "Current session", origins: ["session", "file"] },
  ];

  function sourceOf(origin) {
    for (var i = 0; i < SOURCES.length; i++) {
      if (SOURCES[i].origins.indexOf(origin) >= 0) return SOURCES[i].id;
    }
    return "";
  }

  // Recorded for every load a person makes, whether or not the browser is open:
  // stepping with NEXT is using a preset as much as clicking it is.
  var listening = false;
  function listen() {
    if (listening || !api() || !api().onLoad) return;
    listening = true;
    api().onLoad(function (sel) {
      var key = keyOfSelection(sel);
      if (key) noteRecent(key);
      window.SynthBrowser.refresh();
    });
  }

  // ---------------------------------------------------------------- the body

  // `mode` is "load" or "write"; `startView` is "presets" or "slots" and only
  // means something to load, since a destination is always a slot.
  function build(mode, startView) {
    var writing = mode === "write";
    var view = writing || startView === "slots" ? "slots" : "presets";
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

    var wrap = element("div", "browser");
    wrap.setAttribute("data-view", view);

    var tabs = null;
    var panes = element("div", "browser-panes");
    var left = element("div", "browser-sources");
    var right = element("div", "browser-slots");
    panes.appendChild(left);
    panes.appendChild(right);

    // What the last thing said, where it is read. The strip says it too, but
    // the strip is behind the dialog: a refusal nobody can see is the one way
    // a write can go wrong without the person knowing why.
    var feedback = element("p", "browser-feedback");
    feedback.setAttribute("role", "status");
    feedback.hidden = true;
    function say(text, kind) {
      feedback.textContent = text || "";
      feedback.hidden = !text;
      feedback.setAttribute("data-kind", kind || "ok");
    }

    // What has been typed into the bank search box, lower-cased once.
    var query = "";
    // Built once, kept: see the note above buildHeader.
    var rows = element("div", "browser-source-list");
    var empty = element("div", "browser-source-empty", "No bank of that name");
    empty.hidden = true;

    var archiveArea = element("div", "browser-archive");
    var archiveLabel = element("label", null, "Archive");
    var archivePath = element("input", "browser-archive-path");
    archivePath.type = "text";
    archivePath.placeholder = "Path to a ZIP on the host";
    archivePath.setAttribute("aria-label", "Archive path");
    archiveLabel.appendChild(archivePath);
    archiveArea.appendChild(archiveLabel);
    var archiveActions = element("div", "browser-heading-actions");
    var archiveOpen = button("browser-mini", "Open");
    archiveOpen.setAttribute("aria-label", "Open archive");
    function openArchive() { api().openArchive(archivePath.value); }
    archiveOpen.addEventListener("click", openArchive);
    archivePath.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); openArchive(); }
    });
    var archiveClose = button("browser-mini", "Close");
    archiveClose.setAttribute("aria-label", "Close archive");
    archiveClose.addEventListener("click", function () { api().closeArchive(); });
    archiveActions.appendChild(archiveOpen);
    archiveActions.appendChild(archiveClose);
    archiveArea.appendChild(archiveActions);
    var archiveStatus = element("div", "browser-status");
    archiveStatus.setAttribute("role", "status");
    archiveArea.appendChild(archiveStatus);
    var lastPath = null;

    function paintArchive() {
      var a = api().archive();
      archiveArea.hidden = writing || !a;
      if (!a) return;
      // A peer's change updates the remembered path, but a patch poll must
      // not wipe out a path the user is still typing.
      if (a.path !== lastPath) { archivePath.value = a.path; lastPath = a.path; }
      archiveClose.hidden = !a.open;
      var error = api().archiveError();
      archiveStatus.textContent = error || (a.open ? a.banks.length + " banks · read-only"
        : a.path ? "Archive unavailable" : "No archive open");
      archiveStatus.className = "browser-status" + (error ? " error" : "");
    }

    // Repainting throws the rows away, and with them the focus a keyboard user
    // had in them: Enter on a bank would leave the next Tab starting from the
    // top of the dialog. `keep` notes which child had it and `give` hands it
    // back to the same position in whatever replaced them.
    function keep(container) {
      var kids = container.children;
      for (var i = 0; i < kids.length; i++) {
        if (kids[i] === document.activeElement || kids[i].contains(document.activeElement)) return i;
      }
      return -1;
    }

    function give(container, at) {
      if (at < 0) return;
      var kid = container.children[Math.min(at, container.children.length - 1)];
      if (kid && kid.focus) kid.focus();
    }

    function buildHeader() {
      var head = element("div", "browser-heading");
      head.appendChild(element("span", null, "Banks"));

      var actions = element("span", "browser-heading-actions");

      // Somewhere to write to that is not the factory bank.
      var make = button("browser-mini", "New");
      make.title = "A new empty bank";
      make.addEventListener("click", function () {
        api().create("New Bank");
        if (writing) setTarget(0);
        paintAll();
      });

      // A bank from a file, joining the list rather than replacing it.
      var add = button("browser-mini", "Add");
      add.title = "Open a .json bank, a .zip of patches, or one .sy1 patch";
      add.addEventListener("click", function () {
        if (files() && files().pick) {
          files().pick(function (err, what) {
            if (err) { showStatus(err.message || "could not open that file", false); return; }
            showStatus(what ? "Opened " + what : "", true);
            paintAll();
          });
        }
      });

      // And the third shape a bank comes in: a folder of .sy1 files, which is
      // how the reference keeps its own. Its own button rather than something
      // the file picker guesses at, because a folder and a file are chosen in
      // different dialogs and the browser has to be told which to open.
      var folder = button("browser-mini", "Folder");
      folder.title = "Open a folder of .sy1 patches";
      folder.addEventListener("click", function () {
        if (files() && files().pickFolder) {
          files().pickFolder(function (err, what) {
            if (err) { showStatus(err.message || "could not open that folder", false); return; }
            showStatus(what ? "Opened " + what : "", true);
            paintAll();
          });
        }
      });

      actions.appendChild(make);
      actions.appendChild(add);
      actions.appendChild(folder);
      head.appendChild(actions);
      left.appendChild(head);
      left.appendChild(archiveArea);

      // Bank names, not patch names.
      //
      // Searching the patches would mean opening every bank to read them, and
      // for a zip of a hundred and seventy-five that is exactly the eleven
      // megabytes of work the listing avoids. What can be searched is what is
      // already known, which is the names. The preset view's own box searches
      // the patch names of the banks that are open, and says what it left out.
      var find = element("input", "browser-search");
      find.type = "search";
      find.placeholder = "Search banks";
      find.setAttribute("aria-label", "Search banks by name");
      find.addEventListener("input", function () {
        query = find.value.trim().toLowerCase();
        paintSources();
      });
      // A search box inside a dialog swallows Escape in some browsers to clear
      // itself; let it through so the dialog still closes on the first press.
      find.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && !find.value) return;
        if (e.key === "Escape") {
          find.value = "";
          query = "";
          paintSources();
          e.stopPropagation();
        }
      });
      left.appendChild(find);

      // A place for the file pickers to say what happened. They fail quietly
      // otherwise -- a patch that will not parse loaded nothing and said
      // nothing, which is the one way a load can go wrong that leaves the
      // player with no idea why.
      var status = element("div", "browser-status");
      status.setAttribute("role", "status");
      status.hidden = true;
      left.appendChild(status);
      function showStatus(message, ok) {
        status.textContent = message || "";
        status.hidden = !message;
        status.className = "browser-status" + (ok ? " ok" : " error");
      }
      left.appendChild(rows);
      left.appendChild(empty);
    }

    function paintSources() {
      paintArchive();
      var held = keep(rows);
      rows.textContent = "";
      var shown = 0;

      api().list().forEach(function (b, i) {
        if (writing && b.kind === "archive") return;
        if (query && b.label.toLowerCase().indexOf(query) < 0) return;
        shown++;
        var row = button("browser-source" + (b.current ? " on" : "") +
                         (b.used === null && !b.loading ? " unopened" : ""));
        var name = element("span", "browser-source-name", b.label);
        var count = element("span", "browser-source-count");
        // A bank out of a zip of banks has not been read yet, so there is no
        // honest number to show until it has been.
        count.textContent = b.loading ? "…" : (b.used === null ? "" : b.used);
        row.appendChild(name);
        row.appendChild(count);
        row.addEventListener("click", function () {
          // Quietly when writing: choosing which bank to save into must not
          // load anything, or the sound being saved is the one it replaces.
          // The preset view is quiet too: there a click on a bank is looking
          // at it, and a sound is chosen from the list of presets.
          api().select(i, writing || view === "presets", function (err, state) {
            if (err) {
              count.textContent = "!";
              row.title = err.message;
              return;
            }
            // "loading" comes back straight away for a bank that has to be
            // read first; the real answer arrives on the second call.
            if (state === "loading") { paintSources(); return; }
            if (writing) setTarget(0);
            paintAll();
          });
        });
        rows.appendChild(row);
      });

      empty.hidden = shown > 0;
      give(rows, held);
    }

    // ---------------------------------------------------------- slot view

    function paintSlots() {
      right.textContent = "";

      var head = element("div", "browser-slots-head");
      var title = element("span", "browser-bank-name");
      var browsing = !writing ? api().browsing() : null;
      title.textContent = browsing ? "Browsing: " + browsing.label : api().label();
      var count = element("span", "browser-bank-count");
      var slots = browsing ? browsing.slots : api().slots();
      count.textContent = browsing && browsing.loading ? "Opening…"
        : slots.filter(Boolean).length + " of " + slots.length + " used";
      head.appendChild(title);
      head.appendChild(count);
      right.appendChild(head);
      if (api().archive()) {
        var provenance = api().playing();
        var line = element("div", "browser-playing");
        var position = provenance && provenance.source === "archive"
          ? (provenance.archive ? provenance.archive.patch : null)
          : (provenance ? provenance.index : null);
        line.textContent = "Playing: " + (provenance ? provenance.name : "Untitled") +
          (provenance && provenance.bank ? " · " + provenance.bank : "") +
          (position !== null ? " · " + (provenance.source === "archive" ? "#" : "slot ") + position : "");
        right.appendChild(line);
      }

      var grid = element("div", "browser-grid");
      var here = browsing ? browsing.index : api().index();

      slots.forEach(function (slot, i) {
        var marked = writing ? i === target : i === here;
        var b = button("browser-slot" + (slot ? "" : " empty") +
                       (marked ? (writing ? " target" : " on") : ""));
        if (marked) b.setAttribute("aria-current", "true");
        b.setAttribute("data-slot", String(i));

        b.appendChild(element("span", "browser-slot-num", pad3(i)));
        b.appendChild(element("span", "browser-slot-name", slot ? slot.name : "—"));

        b.addEventListener("click", function () {
          if (writing) {
            setTarget(i);
            paintSlots();
          } else {
            if (browsing) api().loadBrowsed(i);
            else api().load(i);
            paintSlots();
          }
        });
        if (!writing) {
          b.addEventListener("dblclick", function () {
            if (browsing) api().loadBrowsed(i);
            else api().load(i);
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

    // -------------------------------------------------------- preset view

    // The view's own state. Kept in the closure rather than read back from the
    // controls, so that a repaint cannot lose it and a test can drive the
    // controls the way a person would.
    var presetQuery = "", presetRaw = "";
    var pressed = {};
    var favoritesOn = false, recentOn = false;
    var activeKey = null;
    // An archive load that has been asked of the host and not yet answered: the
    // selection does not move until it is, so this is what keeps the row
    // honest about what is happening.
    var pending = null;
    var shownByKey = {};
    var parts = null;

    function sourcesPressed() {
      return SOURCES.some(function (s) { return pressed[s.id]; });
    }

    // What the list shows, in order.
    //
    // Recent is its own order, most recent first, and the others keep the
    // panel's: origin, then the order banks were opened, then slot. Both
    // together mean the recent ones that are also favourites. A favourite or a
    // recent whose preset is gone stays in the list, marked, so it can be
    // un-starred and so nothing is quietly replaced by something else.
    function visible() {
      var all = api().presets();
      var byKey = {};
      all.forEach(function (p) { byKey[p.key] = p; });
      var p = loadPrefs();
      var list;
      if (recentOn) {
        list = p.recent.map(function (key) { return byKey[key] || missing(key); });
      } else {
        list = all.slice();
        if (favoritesOn) {
          p.favorites.forEach(function (key) { if (!byKey[key]) list.push(missing(key)); });
        }
      }
      if (favoritesOn) list = list.filter(function (e) { return isFavorite(e.key); });
      if (sourcesPressed()) {
        list = list.filter(function (e) { return pressed[sourceOf(e.origin)] === true; });
      }
      if (presetQuery) {
        list = list.filter(function (e) { return e.name.toLowerCase().indexOf(presetQuery) >= 0; });
      }
      return list;
    }

    function isPending(p) {
      if (!pending || p.unavailable) return false;
      return p.archive && pending.archive
        ? p.archive.bank === pending.archive.bank && p.archive.patch === pending.archive.patch
        : false;
    }

    function rowFor(p, active, sel) {
      var playing = isPlaying(p, sel);
      var row = element("div", "browser-row");
      row.setAttribute("role", "presentation");
      row.setAttribute("data-key", p.key);

      var option = element("div", "browser-result" + (playing ? " on" : "") +
        (p.unavailable ? " unavailable" : "") + (isPending(p) ? " loading" : ""));
      option.setAttribute("role", "option");
      option.setAttribute("aria-selected", playing ? "true" : "false");
      option.setAttribute("tabindex", active ? "0" : "-1");
      if (p.unavailable) option.setAttribute("aria-disabled", "true");
      if (isPending(p)) option.setAttribute("aria-busy", "true");

      var at = positionOf(p);
      option.appendChild(element("span", "browser-result-num", at !== null ? pad3(at) : ""));
      option.appendChild(element("span", "browser-result-name", p.name));
      var origin = p.origin === "session" ? "Unsaved" : api().originLabel(p.origin);
      var meta = element("span", "browser-result-meta",
        origin + (p.bank ? (origin ? " / " : "") + p.bank : ""));
      option.appendChild(meta);
      if (p.readOnly) option.appendChild(element("span", "browser-badge", "Read-only"));
      if (isPending(p)) option.appendChild(element("span", "browser-badge", "Loading…"));
      if (p.unavailable) option.appendChild(element("span", "browser-badge", "Unavailable"));
      option.addEventListener("click", function () { choose(p); });
      row.appendChild(option);

      // The live sound has no place to come back to, so a star on it would be
      // a favourite that could never be found again.
      if (!p.live) {
        var star = button("browser-star");
        star.setAttribute("aria-label", "Favorite " + p.name);
        star.setAttribute("aria-pressed", isFavorite(p.key) ? "true" : "false");
        star.setAttribute("tabindex", active ? "0" : "-1");
        star.appendChild(window.QuesynthIcon ? window.QuesynthIcon("star") : document.createTextNode("*"));
        star.addEventListener("click", function () {
          var held = heldRow(p.key);
          activeKey = p.key;
          toggleFavorite(p.key);
          paintResults({ key: p.key, star: true, at: held ? held.at : 0 });
        });
        row.appendChild(star);
      }
      return row;
    }

    // Choose a preset in the list. A person's click is a load, and a load is
    // the panel's to do: it says no in words when it cannot, and the selection
    // moves when the sound has, which for the host's archive is when the host
    // says so.
    function choose(p) {
      activeKey = p.key;
      if (p.unavailable) {
        say(p.name + " is not available now, so it was not loaded.", "error");
        paintResults();
        return;
      }
      if (p.live) {
        say(p.name + " is the sound that is playing now.", "ok");
        paintResults();
        return;
      }
      var result = api().loadPreset(p.archive ? { archive: p.archive } : { bank: p.bank, slot: p.slot });
      pending = result.ok && result.pending ? { key: p.key, archive: p.archive } : null;
      paintResults();
    }

    function buildPresets() {
      right.className = "browser-presets";
      right.textContent = "";
      parts = {};

      var bar = element("div", "browser-toolbar");
      var search = element("input", "browser-search browser-preset-search");
      search.type = "search";
      search.placeholder = "Search presets";
      search.setAttribute("aria-label", "Search presets by name");
      search.addEventListener("input", function () {
        presetRaw = search.value.trim();
        presetQuery = presetRaw.toLowerCase();
        paintResults();
      });
      search.addEventListener("keydown", function (e) {
        if (e.key === "ArrowDown" || e.key === "Enter") {
          e.preventDefault();
          focusRow(activeRow());
        }
      });
      parts.search = search;
      bar.appendChild(search);

      var filters = element("div", "browser-filters");
      filters.setAttribute("role", "group");
      filters.setAttribute("aria-label", "Filters");
      function chip(label, isOn, flip) {
        var c = button("browser-chip", label);
        c.setAttribute("aria-pressed", "false");
        c.addEventListener("click", function () {
          flip();
          c.setAttribute("aria-pressed", isOn() ? "true" : "false");
          paintResults();
        });
        filters.appendChild(c);
      }
      SOURCES.forEach(function (s) {
        chip(s.label, function () { return pressed[s.id] === true; },
          function () { pressed[s.id] = !pressed[s.id]; });
      });
      chip("Favorites", function () { return favoritesOn; }, function () { favoritesOn = !favoritesOn; });
      chip("Recent", function () { return recentOn; }, function () { recentOn = !recentOn; });
      bar.appendChild(filters);
      right.appendChild(bar);

      parts.now = element("p", "browser-now");
      parts.now.setAttribute("role", "status");
      right.appendChild(parts.now);

      parts.notes = element("div", "browser-notes");
      right.appendChild(parts.notes);

      parts.count = element("p", "browser-count");
      parts.count.setAttribute("role", "status");
      right.appendChild(parts.count);

      parts.results = element("div", "browser-results");
      parts.results.setAttribute("role", "listbox");
      parts.results.setAttribute("aria-label", "Presets");
      parts.results.addEventListener("keydown", resultKey);
      right.appendChild(parts.results);

      parts.empty = element("p", "browser-empty");
      parts.empty.hidden = true;
      right.appendChild(parts.empty);
      paintResults();
    }

    function rowList() {
      return parts ? [].slice.call(parts.results.children) : [];
    }

    function activeRow() {
      var list = rowList();
      for (var i = 0; i < list.length; i++) {
        if (list[i].getAttribute("data-key") === activeKey) return list[i];
      }
      for (var j = 0; j < list.length; j++) {
        if (list[j].children[0].getAttribute("aria-selected") === "true") return list[j];
      }
      return list[0] || null;
    }

    // One tab stop for the whole list, wherever you last were in it, and the
    // star of that row beside it: arrow keys move between rows and Tab moves
    // between the controls, rather than a hundred and twenty-eight of each.
    function focusRow(row, onStar) {
      if (!row) return;
      activeKey = row.getAttribute("data-key");
      rowList().forEach(function (other) {
        var on = other === row;
        for (var i = 0; i < other.children.length; i++) {
          other.children[i].setAttribute("tabindex", on ? "0" : "-1");
        }
      });
      var goal = onStar && row.children[1] ? row.children[1] : row.children[0];
      goal.focus();
      if (goal.scrollIntoView) goal.scrollIntoView({ block: "nearest" });
    }

    function resultKey(e) {
      var row = e.target.closest ? e.target.closest(".browser-row") : null;
      if (!row) return;
      var list = rowList();
      var at = list.indexOf(row);
      var onStar = e.target.classList.contains("browser-star");
      var to;
      if (e.key === "ArrowDown") to = Math.min(list.length - 1, at + 1);
      else if (e.key === "ArrowUp") to = at - 1;
      else if (e.key === "Home") to = 0;
      else if (e.key === "End") to = list.length - 1;
      else if ((e.key === "Enter" || e.key === " ") && !onStar) {
        e.preventDefault();
        choose(shownByKey[row.getAttribute("data-key")]);
        return;
      } else return;
      e.preventDefault();
      if (to < 0) parts.search.focus();
      else focusRow(list[to], onStar);
    }

    // Which row, and which control in it, has the focus: so a repaint can hand
    // it back. A row that has gone (the last favourite un-starred in Favorites)
    // passes it to the one that took its place.
    function heldRow(key) {
      var list = rowList();
      for (var i = 0; i < list.length; i++) {
        if (key !== undefined ? list[i].getAttribute("data-key") === key : list[i].contains(document.activeElement)) {
          return {
            key: list[i].getAttribute("data-key"), at: i,
            star: document.activeElement.classList.contains("browser-star"),
          };
        }
      }
      return null;
    }

    function paintNow(sel) {
      var status = api().status();
      var at = sel.slot !== null ? pad3(sel.slot) + " " : sel.archive ? pad3(sel.archive.patch) + " " : "";
      var origin = sel.origin === "session" ? "Unsaved" : api().originLabel(sel.origin);
      var words = ["Playing " + at + (sel.presetName || "Untitled") + " · " + origin +
        (sel.bank ? " / " + sel.bank : "")];
      if (status === "loading") words.push("Loading…");
      if (status === "unavailable") {
        var why = api().restoreState().error;
        words.push("Unavailable" + (why ? ": " + why : ""));
      }
      if (status === "dirty") words.push("Unsaved changes");
      if (api().readOnly()) words.push("Read-only");
      parts.now.textContent = words.join(" · ");
      parts.now.setAttribute("data-status", status);
    }

    // What the list does not contain, and why. A search that quietly left out
    // everything it had not read would look like a search that found nothing.
    function paintNotes() {
      parts.notes.textContent = "";
      var banks = api().list();
      var unopened = banks.filter(function (b) { return b.kind === "bank" && b.used === null && !b.loading && !b.unavailable; });
      var unopenedArchive = banks.filter(function (b) { return b.kind === "archive" && b.used === null && !b.loading; });
      var a = api().archive();
      var lines = [];
      banks.forEach(function (b) {
        if (b.loading) lines.push({ text: "Opening " + b.label + "…", kind: "loading" });
        if (b.unavailable) lines.push({ text: b.label + " could not be opened: " + b.error, kind: "error" });
      });
      if (unopened.length) {
        lines.push({
          text: unopened.length + (unopened.length === 1 ? " bank is" : " banks are") +
            " listed but not open, so " + (unopened.length === 1 ? "its presets are" : "their presets are") +
            " not searched. Open one in Banks to include it.",
          kind: "hint",
        });
      }
      if (a && (a.open ? unopenedArchive.length > 0 : !!a.path)) {
        lines.push({
          text: a.open
            ? "Archive banks are searched once they are open. Open one in Banks to include its presets."
            : "The archive is not open, so Archives has no presets to search. Open it in Banks.",
          kind: "hint",
        });
      }
      var error = api().archiveError();
      if (error) lines.push({ text: error, kind: "error" });
      lines.forEach(function (line) {
        var p = element("p", "browser-note", line.text);
        p.setAttribute("data-kind", line.kind);
        parts.notes.appendChild(p);
      });
    }

    function emptyWords() {
      if (recentOn && favoritesOn) return "None of your recent presets is a favorite.";
      if (recentOn) return "Nothing has been played from here yet.";
      if (favoritesOn) return "No favorites yet. Use the star beside a preset to add one.";
      if (presetQuery) return "No preset is called anything like \u201c" + presetRaw + "\u201d.";
      if (sourcesPressed()) return "No preset comes from the sources chosen.";
      return "There are no presets here yet. Write a sound into a slot, or import a bank.";
    }

    function paintResults(hold) {
      if (!parts) return;
      var sel = api().selection();
      // Answered, one way or the other: a failed load is said by `report`, and
      // the selection is whatever the host left it as.
      if (pending && api().status() !== "loading") pending = null;
      var held = hold || heldRow();
      var list = visible();
      shownByKey = {};
      list.forEach(function (p) { shownByKey[p.key] = p; });
      if (held) {
        var stillThere = list.some(function (p) { return p.key === held.key; });
        if (!stillThere) {
          var heir = list[Math.min(held.at, list.length - 1)];
          activeKey = heir ? heir.key : null;
          held = heir ? { key: heir.key, star: held.star, at: held.at } : { key: null };
        }
      }
      var focusAt = activeKey && list.some(function (p) { return p.key === activeKey; }) ? activeKey : null;
      if (!focusAt) {
        for (var i = 0; i < list.length && !focusAt; i++) if (isPlaying(list[i], sel)) focusAt = list[i].key;
        if (!focusAt && list.length) focusAt = list[0].key;
      }
      parts.results.textContent = "";
      list.forEach(function (p) { parts.results.appendChild(rowFor(p, p.key === focusAt, sel)); });
      parts.count.textContent = list.length + (list.length === 1 ? " preset" : " presets");
      parts.empty.textContent = emptyWords();
      parts.empty.hidden = list.length > 0;
      paintNow(sel);
      paintNotes();
      if (held && held.key) {
        rowList().forEach(function (row) {
          if (row.getAttribute("data-key") === held.key) focusRow(row, held.star);
        });
      } else if (held) {
        // The list emptied under the focus: the search box is where it goes.
        parts.search.focus();
      }
      if (!parts.scrolled) {
        parts.scrolled = true;
        var on = parts.results.querySelector(".browser-result.on");
        if (on) setTimeout(function () { on.scrollIntoView({ block: "center" }); }, 0);
      }
    }

    // ------------------------------------------------------------- the rest

    function paintTabs() {
      if (!tabs) return;
      [].slice.call(tabs.children).forEach(function (t) {
        var on = t.getAttribute("data-view") === view;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.setAttribute("tabindex", on ? "0" : "-1");
        if (on) right.setAttribute("aria-labelledby", t.id);
      });
    }

    function paintRight() {
      if (view === "presets") {
        if (!parts) buildPresets(); else paintResults();
      } else {
        paintSlots();
      }
    }

    function paintAll() {
      paintSources();
      paintRight();
    }

    function setView(next) {
      if (next === view) return;
      view = next;
      wrap.setAttribute("data-view", view);
      right.textContent = "";
      right.className = view === "presets" ? "browser-presets" : "browser-slots";
      parts = null;
      paintTabs();
      paintRight();
    }

    if (!writing) {
      tabs = element("div", "browser-views");
      tabs.setAttribute("role", "tablist");
      tabs.setAttribute("aria-label", "Browser view");
      [["presets", "Presets"], ["slots", "Slots"]].forEach(function (v) {
        var t = button("browser-tab", v[1]);
        t.id = "browser-tab-" + v[0];
        t.setAttribute("role", "tab");
        t.setAttribute("data-view", v[0]);
        t.setAttribute("aria-controls", "browser-view");
        t.addEventListener("click", function () { setView(v[0]); });
        // The arrows move between the two and switch as they go, as tabs do;
        // with two of them, either arrow is "the other one".
        t.addEventListener("keydown", function (e) {
          var to = e.key === "ArrowRight" || e.key === "ArrowLeft" ? (view === "presets" ? 1 : 0)
            : e.key === "Home" ? 0 : e.key === "End" ? 1 : -1;
          if (to < 0) return;
          e.preventDefault();
          setView(to === 0 ? "presets" : "slots");
          tabs.children[to].focus();
        });
        tabs.appendChild(t);
      });
      right.id = "browser-view";
      right.setAttribute("role", "tabpanel");
      wrap.appendChild(tabs);
    }
    wrap.appendChild(panes);

    // The write row: present the whole time in write mode, because it is the
    // point of the dialog rather than something hidden behind a button.
    if (writing) {
      var row = element("form", "browser-save");
      where = element("span", "browser-save-slot", "Slot " + pad3(target));
      field = element("input", "browser-save-name");
      field.type = "text";
      field.setAttribute("aria-label", "Patch name");
      var at = api().slots()[target];
      field.value = at ? at.name : (window.SynthPatch.name() || "Untitled");
      var go = element("button", "modal-action primary", "Write");
      go.type = "submit";
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
    wrap.appendChild(feedback);

    // Anything the panel reports while the dialog is up -- a load that the host
    // refused, a bank that would not open -- is said here as well as in the
    // strip behind it.
    var stopListening = api().onResult ? api().onResult(function (result) {
      say(result.ok ? result.message : result.error.message + " (" + result.error.code + ")",
        result.ok ? (result.warning ? "warn" : "ok") : "error");
      if (view === "presets") paintResults();
    }) : function () {};

    // Escape clears a search before it closes anything: the person who typed
    // something and wants it gone should not lose the dialog to say so.
    wrap.addEventListener("keydown", function (e) {
      if (e.key !== "Escape" || view !== "presets" || !presetQuery) return;
      e.preventDefault();
      e.stopPropagation();
      parts.search.value = "";
      presetQuery = presetRaw = "";
      paintResults();
      parts.search.focus();
    });

    buildHeader();
    paintTabs();
    paintAll();

    wrap.refresh = function () { paintAll(); };
    wrap.dispose = function () { stopListening(); };
    wrap.focusField = function () { if (field) { field.focus(); field.select(); } };
    wrap.focusSearch = function () { if (parts && parts.search) parts.search.focus(); };
    return wrap;
  }

  // -------------------------------------------------------------------- open

  function open(options) {
    if (!api()) return;
    var view = options && options.view === "slots" ? "slots" : "presets";
    var body = build("load", view);

    var actions = [
      {
        // Export, not save. There are two ways to keep a bank and the
        // difference between them is why both exist: this one writes a
        // file you choose -- in a plugin, that means Downloads -- and Keep
        // puts it where the instrument will look for it next time.
        label: api().archive() ? "Export ordinary bank" : "Export",
        onClick: function () { if (files() && files().saveBank) files().saveBank(); },
      },
      { label: "Done", primary: true, onClick: function (close) { close(); } },
    ];

    // In a plugin, one more: keep this bank. A plugin has somewhere to keep one
    // and a browser does not -- there the factory bank is remembered already
    // and the rest are files you opened.
    if (api().hosted && api().hosted()) {
      actions.splice(actions.length - 1, 0, {
        label: api().archive() ? "Keep ordinary bank" : "Keep",
        // Says so afterwards. Keeping a bank writes a file somewhere the player
        // cannot see, and a button that does nothing visible is one people
        // press twice and then distrust.
        onClick: function (close, button) {
          var ok = api().keep();
          if (!button) return;
          var was = button.textContent;
          button.textContent = ok ? "Kept" : "Could not keep it";
          button.disabled = true;
          setTimeout(function () {
            button.textContent = was;
            button.disabled = false;
          }, 1400);
        },
      });
    }

    window.SynthModal.show("Patches", body, actions, { onClose: body.dispose });
    if (view === "presets") body.focusSearch();
  }

  function openWrite() {
    if (!api()) return;
    var body = build("write");
    window.SynthModal.show("Write", body,
      [{ label: "Cancel", onClick: function (close) { close(); } }], { onClose: body.dispose });
    body.focusField();
  }

  listen();

  window.SynthBrowser = {
    refresh: function () {
      var bodies = document.querySelectorAll(".browser");
      for (var i = 0; i < bodies.length; i++) {
        if (bodies[i].refresh) bodies[i].refresh();
      }
    },
    // The preset view unless `{ view: "slots" }` asks for the bank and slot view.
    open: open,
    write: openWrite,
  };
})();
