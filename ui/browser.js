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

  // What a part of a pane is for, said above it: words, and not something to
  // press. A heading and not a label, so that it is found as one.
  function sectionTitle(words) {
    return element("h3", "browser-section-title", words);
  }

  // One id for each thing a button controls, so that two browsers open at once
  // -- a destination chosen over the browser -- never share one.
  var serial = 0;
  function uid(prefix) { return prefix + "-" + (++serial); }

  // -------------------------------------------------------------- menu buttons
  //
  // What is not done every visit is behind a button that opens a menu, as the
  // WAI-ARIA practices describe one and as the strip's menu does it (ui/app.js,
  // buildActions): it opens on click, Enter, Space and the arrow keys, the
  // focus moves into it and stays in it, Escape shuts it and gives the focus
  // back to the button, and so does choosing something -- before the action
  // runs, so that a dialog the action opens takes the button as the place the
  // focus goes back to, and not an item that has just been hidden. Tab shuts
  // it, and so does a click anywhere else. Shut, it is hidden and not only out
  // of sight, so that neither a keyboard nor a screen reader meets what is in
  // it.
  //
  // The list is in the flow, under its button, and not laid over what is
  // beside it: it has to open inside a region that scrolls and in a dialog as
  // narrow as a phone, and a list that floats is clipped by the one and runs
  // off the other.
  //
  // `config`: { label, name, listLabel, className, listClass }. The caller puts
  // `trigger` and `list` where they belong and adds the items; an item that
  // does not apply is marked `aria-disabled` by the caller and still runs, so
  // that whoever decides what is allowed is the one that says no.
  //
  // An item that replaces or removes something is added with
  // `{ destructive: true }` and put last: it is set apart by a rule above it
  // and not by a separator element, so that every child of the list is an item
  // and the arrow keys land on all of them.
  function menuButton(config) {
    var list = element("div", config.listClass);
    list.id = uid("browser-menu");
    list.setAttribute("role", "menu");
    list.setAttribute("aria-label", config.listLabel);
    list.hidden = true;
    var trigger = button(config.className, config.label);
    trigger.setAttribute("aria-haspopup", "menu");
    trigger.setAttribute("aria-expanded", "false");
    trigger.setAttribute("aria-controls", list.id);
    if (config.name) trigger.setAttribute("aria-label", config.name);
    var items = [];
    var listening = false;

    function outside(e) {
      if (!list.contains(e.target) && !trigger.contains(e.target)) setOpen(false);
    }

    function setOpen(open, which) {
      list.hidden = !open;
      trigger.setAttribute("aria-expanded", open ? "true" : "false");
      if (open && !listening) { document.addEventListener("click", outside); listening = true; }
      if (!open && listening) { document.removeEventListener("click", outside); listening = false; }
      if (open && items.length) items[which === "last" ? items.length - 1 : 0].focus();
    }

    function move(from, by) {
      items[(from + by + items.length) % items.length].focus();
    }

    trigger.addEventListener("click", function () { setOpen(list.hidden, "first"); });
    trigger.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        setOpen(true, e.key === "ArrowUp" ? "last" : "first");
      } else if (e.key === "Escape" && !list.hidden) {
        e.preventDefault();
        e.stopPropagation();
        setOpen(false);
      }
    });

    return {
      trigger: trigger,
      list: list,
      open: setOpen,
      close: function () { setOpen(false); },
      add: function (label, onSelect, options) {
        var item = button("browser-menuitem" + (options && options.destructive ? " destructive" : ""), label);
        item.setAttribute("role", "menuitem");
        var at = items.length;
        items.push(item);
        item.addEventListener("click", function () {
          setOpen(false);
          trigger.focus();
          onSelect();
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
            trigger.focus();
          } else if (e.key === "Tab") setOpen(false);
        });
        list.appendChild(item);
        return item;
      },
    };
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

  // How a slot is called when it is named in a sentence.
  function slotWords(label, slot) {
    return label + " / " + pad3(slot);
  }

  // `mode` is what the dialog is for:
  //
  //   load     choosing a sound to play, in the preset view or the slot view
  //   write    choosing where to put the sound that is playing, the legacy way:
  //            starting on its own slot, every bank listed, the read-only ones
  //            marked and refused by the panel in its own words
  //   saveas   the same, for a sound that has no home yet: banks that can take
  //            it, starting on the first empty slot
  //   copy     choosing where a preset in a slot is copied to
  //   move     ... or moved to
  //
  // `startView` is "presets" or "slots" and only means something to load; every
  // other mode is choosing a slot. `job` is what a copy or a move is of:
  // `{ from: { bank, slot }, name }`.
  function build(mode, startView, job) {
    // Choosing a place for something, as against choosing something to play.
    var picking = mode !== "load";
    var forms = mode === "write" || mode === "saveas";
    var transfer = mode === "copy" || mode === "move";
    var view = picking || startView === "slots" ? "slots" : "presets";

    // The bank a destination is chosen in is the bank in view; these two modes
    // begin by looking at one that can take what is being put there.
    if (mode === "saveas" || transfer) arrive();

    // In write mode this is the destination, and it starts where you already
    // are, so writing back to the same slot takes no navigation at all. It can
    // be -1 -- after switching banks nothing in this one is loaded -- and the
    // top of the bank is the sensible place to start from then. The others
    // start on the first empty slot, which is where a new sound belongs.
    var target = mode === "write" ? Math.max(0, api().index()) : firstEmpty();
    var field = null, where = null, commitButton = null, edited = false;
    var wrote = false;

    // Move the destination, and everything that shows it, together.
    function setTarget(i) {
      target = i;
      if (forms) {
        where.textContent = "Slot " + pad3(i);
        // The name of the sound being written, not of the one being replaced.
        //
        // The other way round is a trap: pick a slot holding "Strings", write
        // an organ into it without reading the field, and the bank now has an
        // organ called Strings. Re-saving a patch over itself still offers its
        // own name, because in that case they are the same name. A name that
        // somebody has typed is theirs, though, and clicking another slot does
        // not take it back.
        if (!edited) field.value = window.SynthPatch.name() || "Untitled";
      }
      if (transfer) paintTransfer();
    }

    var wrap = element("div", "browser");
    wrap.setAttribute("data-view", view);
    wrap.setAttribute("data-mode", mode);

    var tabs = null;
    var main = element("div", "browser-main");
    var left = element("div", "browser-sources");
    left.id = uid("browser-sources");
    var right = element("div", "browser-slots");
    main.appendChild(left);
    main.appendChild(right);

    // Where a bank is chosen, what is done to one, and what the presets are
    // narrowed by: behind one button, and not a pane that is always there.
    // The workspace is the point of the dialog, and a person who is looking
    // for a sound should not have to read past a list of banks to find it.
    //
    // Where there is room it is a pane beside the workspace, open to begin
    // with and shut with the button. Where there is not, a phone or a narrow
    // plugin window, it is a sheet over the workspace, shut to begin with:
    // opened it takes the focus, Escape shuts it and gives the focus back to
    // the button, and choosing a bank shuts it too, because the reason for
    // choosing one is to look at what is in it. Shut, it is hidden, so what
    // is in it is not in the Tab order or in what a screen reader reads.
    var width = window.matchMedia ? window.matchMedia("(max-width: 620px)") : null;
    function narrow() { return !!(width && width.matches); }
    var drawerToggle = button("browser-filters-toggle", picking ? "Banks" : "Browse");
    drawerToggle.setAttribute("aria-controls", left.id);
    function setDrawerOpen(open, focusIn) {
      left.hidden = !open;
      drawerToggle.setAttribute("aria-expanded", open ? "true" : "false");
      if (open && focusIn) {
        var first = left.querySelector("button, input");
        if (first) first.focus();
      }
      // A menu that was open in what has just gone is not left open in it.
      if (!open) {
        if (addMenu) addMenu.close();
        if (toolsMenu) toolsMenu.close();
      }
    }
    // A bank has been chosen, and the sheet is over what it was chosen to look
    // at: out of the way, and the focus where the person started.
    function leaveSheet() {
      if (left.hidden || !narrow()) return;
      setDrawerOpen(false);
      drawerToggle.focus();
    }
    setDrawerOpen(!narrow());
    drawerToggle.addEventListener("click", function () { setDrawerOpen(left.hidden, narrow()); });
    left.addEventListener("keydown", function (e) {
      if (e.key !== "Escape" || left.hidden || !narrow()) return;
      e.preventDefault();
      e.stopPropagation();
      setDrawerOpen(false);
      drawerToggle.focus();
    });

    // The sound that is playing, above everything and in both views: the
    // question the person arrives with is "what am I on?", and it should not
    // take reading a list of banks to answer it. Choosing somewhere to put a
    // sound is not that question, so a destination has no such header.
    var now = null;
    if (!picking) {
      var current = element("div", "browser-current");
      current.setAttribute("role", "group");
      current.setAttribute("aria-label", "Current sound");
      now = element("p", "browser-now");
      now.setAttribute("role", "status");
      current.appendChild(now);
      wrap.appendChild(current);
    }

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

    // The bank the dialog is looking at, as `list()` describes it, or null.
    // Choosing a destination never looks at an archive bank, which is not
    // one: the page's own bank is the only one `slots()` reads then.
    function viewRow() {
      var rows = api().list();
      if (picking && api().archive()) return rows[0] || null;
      for (var i = 0; i < rows.length; i++) if (rows[i].current) return rows[i];
      return null;
    }

    // Is the bank this dialog is looking at somewhere its job can go?
    function canTarget() {
      var row = viewRow();
      if (!row || !picking) return true;
      return mode !== "saveas" || (!row.readOnly && row.used !== null);
    }

    // Does the sources list offer this bank in this mode?
    function offered(b) {
      if (picking && b.kind === "archive") return false;
      return mode !== "saveas" || !b.readOnly;
    }

    // Where a destination is chosen first: a bank in view that can take it.
    function arrive() {
      var banks = api().list();
      if (api().archive()) return;
      var ok = function (r) { return r && r.kind === "bank" && !r.readOnly && r.used !== null; };
      var here = banks.filter(function (r) { return r.current; })[0];
      // A copy or a move starts in the bank the preset is in; Save As in the
      // bank that is playing, if the one in view cannot take it.
      var chosen = transfer
        ? banks.filter(function (r) { return r.label === job.from.bank; })[0]
        : banks.filter(function (r) { return r.playing; })[0];
      var pick = ok(here) ? here : ok(chosen) ? chosen : banks.filter(ok)[0];
      if (pick && !pick.current) api().select(pick.index, true);
    }

    function firstEmpty() {
      var slots = api().slots();
      for (var i = 0; i < slots.length; i++) if (!slots[i]) return i;
      return 0;
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
      archiveArea.hidden = picking || !a;
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

    // ---------------------------------------------------- naming a bank

    // One small form at a time, in the sources pane, for the two things that
    // need a name: a new bank and a renamed one. Inline rather than a dialog
    // of its own because the dialog it would stack on is the one the person is
    // working in, and a bank's name is one line. It stays open when the panel
    // refuses the name, with the reason beside it, and closes when it is
    // accepted. Escape and Cancel put focus back on what opened it.
    var formHost = element("div", "browser-form-host");
    var openForm = null;

    function closeForm(refocus) {
      if (!openForm) return;
      var opener = openForm.opener;
      if (openForm.form.parentNode) openForm.form.parentNode.removeChild(openForm.form);
      openForm = null;
      if (refocus && opener && opener.focus) opener.focus();
    }

    // `config`: { label, value, submit, opener, onSubmit(name) -> result }.
    function showForm(config) {
      closeForm(false);
      var form = element("form", "browser-form");
      form.appendChild(element("span", "browser-form-label", config.label));
      var name = element("input", "browser-form-name");
      name.type = "text";
      name.value = config.value;
      name.setAttribute("aria-label", config.label);
      var go = element("button", "browser-mini", config.submit);
      go.type = "submit";
      var cancel = button("browser-mini", "Cancel");
      form.appendChild(name);
      form.appendChild(go);
      form.appendChild(cancel);
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        var result = config.onSubmit(name.value);
        // Only a name can be put right by trying another one: a bank that
        // belongs to the host is refused whatever it is called.
        if (result && !result.ok && result.error.code === "InvalidName") name.focus();
        else closeForm(true);
      });
      cancel.addEventListener("click", function () { closeForm(true); });
      // Before the dialog hears it: Escape here means "never mind the name".
      form.addEventListener("keydown", function (e) {
        if (e.key !== "Escape") return;
        e.preventDefault();
        e.stopPropagation();
        closeForm(true);
      });
      openForm = { form: form, opener: config.opener };
      formHost.appendChild(form);
      name.focus();
      name.select();
    }

    // ----------------------------------------------- importing from files

    // Say how an import went, in the dialog as well as in the strip: the
    // typed refusal comes through `onResult` with its code, and a bank that did
    // not fit gets the sentence that says what that means.
    function imported(err, what) {
      if (!err) {
        var left = /\((\d+) left out\)/.exec(what || "");
        if (left) {
          say("Opened " + what + ". " + left[1] + (left[1] === "1" ? " patch" : " patches") +
            " did not fit a bank's " + api().SLOTS + " slots and " + (left[1] === "1" ? "was" : "were") +
            " left out.", "warn");
        }
      }
      paintAll();
    }

    function pickWith(name) {
      if (!files() || !files()[name]) {
        say("This build cannot open files.", "error");
        return;
      }
      files()[name](imported);
    }

    // -------------------------------------------------------- bank tools

    // What can be done to the bank in view. Built once, so that the form that
    // one of them opens is not taken from under the person's hands by a
    // repaint; `paintTools` only says which of them apply.
    var tools = element("div", "browser-bank-tools");
    tools.setAttribute("role", "group");
    tools.setAttribute("aria-label", "Bank actions");
    var toolsName = element("span", "browser-bank-tools-name");
    var toolsMenu = menuButton({
      label: "Bank actions", listLabel: "Bank actions", className: "browser-more", listClass: "browser-menu-list",
    });
    var toolsWrap = element("div", "browser-menu");
    toolsWrap.appendChild(toolsMenu.trigger);
    toolsWrap.appendChild(toolsMenu.list);
    tools.appendChild(toolsName);
    tools.appendChild(toolsWrap);

    // A tool that does not apply looks it, and says why on hover; it is not
    // taken out of reach. The panel decides what is allowed and answers a press
    // in its own words, which is the one place those words are written.
    function applies(b, ok, why) {
      b.setAttribute("aria-disabled", ok ? "false" : "true");
      b.title = ok ? "" : why;
    }

    function renameBank() {
      var row = viewRow();
      if (!row) return;
      // The two it can never be are refused by asking, which is where the
      // reason is written; the others get the form.
      if (row.origin === "factory") { api().renameBank(row.label, row.label); return; }
      showForm({
        label: "New name for " + row.label, value: row.label, submit: "Rename", opener: toolsMenu.trigger,
        onSubmit: function (name) {
          var result = api().renameBank(row.label, name);
          paintAll();
          return result;
        },
      });
    }
    function duplicateBank() {
      var row = viewRow();
      if (!row) return;
      api().duplicateBank(row.label);
      paintAll();
    }
    function exportBank() {
      var row = viewRow();
      if (!row) return;
      if (files() && files().saveBank) files().saveBank(row.index);
    }
    function closeBank() {
      var row = viewRow();
      if (!row) return;
      // What is in a bank of the person's own, or put into one they opened,
      // is in no file: closing it is the only way to lose it here, so it is
      // asked. A bank that is still only what its file said is not.
      var theirs = row.origin === "user" ? row.used > 0 : row.edited;
      if (theirs && row.closable) {
        window.SynthModal.confirm({
          title: "Close " + row.label + "?",
          message: [
            row.origin === "user"
              ? row.label + " has " + row.used + (row.used === 1 ? " preset" : " presets") + " and is not saved anywhere else."
              : row.label + " was opened from a file, and what has been written into it since is not saved anywhere else.",
            "Closing it removes it from this session. The sound that is playing does not change.",
            "Export it first if you want to keep it.",
          ],
          confirmLabel: "Close bank",
        }).then(function (yes) {
          if (!yes) return;
          api().removeBank(row.label);
          paintAll();
        });
        return;
      }
      api().removeBank(row.label);
      paintAll();
    }
    var toolRename = toolsMenu.add("Rename...", renameBank);
    var toolDuplicate = toolsMenu.add("Duplicate", duplicateBank);
    var toolExport = toolsMenu.add("Export bank", exportBank);
    var toolClose = toolsMenu.add("Close bank", closeBank, { destructive: true });

    function paintTools() {
      var row = viewRow();
      tools.hidden = picking || !row || row.kind === "archive";
      if (tools.hidden) { toolsMenu.close(); return; }
      toolsName.textContent = row.label;
      toolsMenu.trigger.setAttribute("aria-label", "Bank actions for " + row.label);
      applies(toolRename, row.origin !== "factory", "The factory bank belongs to the instrument and cannot be renamed.");
      applies(toolDuplicate, row.used !== null, "Open this bank before copying it.");
      applies(toolExport, row.used !== null, "Open this bank before exporting it.");
      applies(toolClose, row.closable, api().list().length < 2
        ? "The last bank cannot be closed." : row.label + " cannot be closed.");
    }

    // What the presets are narrowed by, kept with the banks they come from:
    // where a sound came from, whether it is a favourite, whether it was
    // played lately. Built once; `paintFilters` says which are pressed, and
    // how many, on the button that opens this, so that a list that has been
    // narrowed says so while the filters are out of sight.
    var filters = null, sources = null;
    var chips = [];
    function buildFilters() {
      filters = element("div", "browser-filters");
      filters.setAttribute("role", "group");
      filters.setAttribute("aria-label", "Filters");
      function chip(label, isOn, flip) {
        var c = button("browser-chip", label);
        c.setAttribute("aria-pressed", "false");
        c.addEventListener("click", function () {
          flip();
          paintFilters();
          paintResults();
        });
        chips.push({ el: c, isOn: isOn });
        filters.appendChild(c);
      }
      SOURCES.forEach(function (s) {
        chip(s.label, function () { return pressed[s.id] === true; },
          function () { pressed[s.id] = !pressed[s.id]; });
      });
      chip("Favorites", function () { return favoritesOn; }, function () { favoritesOn = !favoritesOn; });
      chip("Recent", function () { return recentOn; }, function () { recentOn = !recentOn; });
      sources = element("div", "browser-section browser-section-sources");
      sources.appendChild(sectionTitle("Sources"));
      sources.appendChild(filters);
      left.appendChild(sources);
    }

    function paintFilters() {
      if (!filters) return;
      filters.hidden = view !== "presets";
      sources.hidden = filters.hidden;
      var on = 0;
      chips.forEach(function (c) {
        var is = c.isOn();
        if (is) on++;
        c.el.setAttribute("aria-pressed", is ? "true" : "false");
      });
      drawerToggle.textContent = "Browse" + (on ? " \u00b7 " + on : "");
    }

    var addMenu = null;
    function buildHeader() {
      if (!picking) buildFilters();

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

      // The pane is in the order of what a visit is for: narrow the presets,
      // choose a bank, and last, because it is least often, make one or do
      // something to one. Each part says what it is in a heading.
      var banks = element("div", "browser-section browser-section-banks");
      banks.appendChild(sectionTitle("Banks"));
      banks.appendChild(find);
      banks.appendChild(rows);
      banks.appendChild(empty);
      left.appendChild(banks);

      // New and the imports are menu items: how a bank comes to be is not
      // what most visits are for.
      addMenu = menuButton({
        label: "Add bank", listLabel: "Add a bank", className: "browser-more", listClass: "browser-menu-list",
      });
      var addWrap = element("div", "browser-menu");
      addWrap.appendChild(addMenu.trigger);
      addWrap.appendChild(addMenu.list);

      // Somewhere to write to that is not the factory bank.
      var make = addMenu.add("New bank...", function () {
        showForm({
          label: "Name for the new bank", value: "New Bank", submit: "Create", opener: addMenu.trigger,
          onSubmit: function (name) {
            var made = api().newBank(name);
            // The new bank is in view and empty: its first slot is the start.
            if (made.ok && picking) setTarget(firstEmpty());
            paintAll();
            return made;
          },
        });
      });
      make.title = "A new empty bank";

      if (!picking) {
        // A bank from a file, joining the list rather than replacing it.
        var add = addMenu.add("Import file...", function () { pickWith("pick"); });
        add.title = "Open a .json bank, a .zip of patches, or one .sy1 patch";

        // And the third shape a bank comes in: a folder of .sy1 files, which is
        // how the reference keeps its own. Its own item rather than something
        // the file picker guesses at, because a folder and a file are chosen in
        // different dialogs and the browser has to be told which to open.
        var folder = addMenu.add("Import folder...", function () { pickWith("pickFolder"); });
        folder.title = "Open a folder of .sy1 patches";
      }

      var head = element("div", "browser-heading");
      head.appendChild(sectionTitle("Manage banks"));
      head.appendChild(addWrap);
      var manage = element("div", "browser-section browser-section-manage");
      manage.appendChild(head);
      manage.appendChild(formHost);
      manage.appendChild(tools);
      manage.appendChild(archiveArea);
      left.appendChild(manage);
    }

    function paintSources() {
      paintArchive();
      paintTools();
      var held = keep(rows);
      rows.textContent = "";
      var shown = 0;

      api().list().forEach(function (b, i) {
        if (!offered(b)) return;
        if (query && b.label.toLowerCase().indexOf(query) < 0) return;
        shown++;
        var here = picking && api().archive() ? i === 0 : b.current;
        var row = button("browser-source" + (here ? " on" : "") +
                         (b.used === null && !b.loading ? " unopened" : ""));
        if (here) row.setAttribute("aria-current", "true");
        var name = element("span", "browser-source-name", b.label);
        var count = element("span", "browser-source-count");
        // A bank out of a zip of banks has not been read yet, so there is no
        // honest number to show until it has been.
        count.textContent = b.loading ? "…" : (b.used === null ? "" : b.used);
        row.appendChild(name);
        row.appendChild(count);
        // Where it came from, and whether it can be written to.
        var badges = element("span", "browser-source-badges");
        badges.appendChild(element("span", "browser-badge", api().originLabel(b.origin)));
        if (b.readOnly) badges.appendChild(element("span", "browser-badge", "Read-only"));
        row.appendChild(badges);
        row.addEventListener("click", function () {
          // In the page's own bank list an archive bank is never a destination,
          // and there is only the one bank to be in.
          if (picking && api().archive()) { setTarget(mode === "write" ? 0 : firstEmpty()); paintAll(); leaveSheet(); return; }
          // Quietly when picking a destination: choosing which bank to save
          // into must not load anything, or the sound being saved is the one it
          // replaces. The preset view is quiet too: there a click on a bank is
          // looking at it, and a sound is chosen from the list of presets.
          api().select(i, picking || view === "presets", function (err, state) {
            if (err) {
              count.textContent = "!";
              row.title = err.message;
              return;
            }
            // "loading" comes back straight away for a bank that has to be
            // read first; the real answer arrives on the second call.
            if (state === "loading") { paintSources(); return; }
            if (picking) setTarget(mode === "write" ? 0 : firstEmpty());
            paintAll();
            leaveSheet();
          });
        });
        rows.appendChild(row);
      });

      empty.hidden = shown > 0;
      give(rows, held);
    }

    // ---------------------------------------------------------- slot view

    // Say what a copy or a move would do, where it can be read before it is
    // asked for: the destination, and what is in it.
    function paintTransfer() {
      if (!where) return;
      var label = api().label();
      var there = api().slots()[target];
      where.textContent = (mode === "copy" ? "Copy " : "Move ") + job.name + " from " +
        slotWords(job.from.bank, job.from.slot) + " to " + slotWords(label, target) + ", which " +
        (there ? "holds " + there.name + " and would be replaced." : "is empty.");
    }

    // A repaint rebuilds every slot, so the one that had the focus is found
    // again afterwards.
    function heldSlot() {
      var el = document.activeElement;
      if (!el || !el.getAttribute || !right.contains(el)) return null;
      return el.getAttribute("data-slot");
    }

    function giveSlot(held) {
      if (held === null) return;
      var goal = right.querySelector('[data-slot="' + held + '"]');
      if (goal) goal.focus();
    }

    // What the slot view last painted, for the details to be about.
    var slotView = null;
    // A slot that has been looked at and not loaded: the focus is on it, or it
    // was asked about with the menu key or a right click. Remembered with the
    // sound it was looked at beside, so that it is not the one the details
    // are about once the sound has moved, and with the bank, so that looking
    // at another bank and back does not lose it.
    var inspected = null;

    function inspectedAt(v) {
      return inspected && inspected.bank === v.bankLabel && inspected.here === v.here
        ? inspected.slot : v.here;
    }

    function inspect(i) {
      if (picking || !slotView || i === inspectedAt(slotView)) return;
      inspected = { bank: slotView.bankLabel, slot: i, here: slotView.here };
      paintSlotDetails();
    }

    // Press and hold, which is what a finger has for the menu key and a right
    // click: a touch screen taps to load, and some browsers (iOS Safari) send
    // no contextmenu event for a long press, so a slot that is not playing
    // could not be looked at without being loaded. A touch or a pen held on a
    // slot for HOLD_MS asks about it, as the right click does, and the click
    // that its release makes is not a load. A mouse never starts one: it has
    // a right button.
    //
    // Kept here and not per slot, because a repaint rebuilds every slot and the
    // finger is still down on the one that was there.
    var HOLD_MS = 480;
    var HOLD_SLOP = 8;
    var hold = null;
    var swallowUntil = 0;
    function cancelHold() {
      if (hold) clearTimeout(hold.timer);
      hold = null;
    }

    function focusSlot(i) {
      var goal = right.querySelector('.browser-slot[data-slot="' + i + '"]');
      if (goal) goal.focus();
    }

    function paintSlots() {
      var held = heldSlot();
      right.textContent = "";

      // A bank that cannot take what is being put there is not shown as if it
      // could: the slots of a read-only bank in Save As would be 128 targets
      // that all refuse.
      if (picking && !canTarget()) {
        right.appendChild(element("p", "browser-empty",
          "No bank here can take a new preset yet. Make one with New bank..., or choose another on the left."));
        if (commitButton) commitButton.disabled = true;
        return;
      }
      if (commitButton) commitButton.disabled = false;

      var head = element("div", "browser-slots-head");
      var title = element("span", "browser-bank-name");
      var browsing = !picking ? api().browsing() : null;
      title.textContent = browsing ? "Browsing: " + browsing.label : api().label();
      var count = element("span", "browser-bank-count");
      var slots = browsing ? browsing.slots : api().slots();
      count.textContent = browsing && browsing.loading ? "Opening…"
        : slots.filter(Boolean).length + " of " + slots.length + " used";
      head.appendChild(title);
      head.appendChild(count);
      right.appendChild(head);
      if (!picking && api().archive()) {
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
      // Copy and Move are of the page's own banks: a patch in the host's
      // archive is not held here to take anywhere.
      var movable = !picking && (!browsing || browsing.bank < 0);
      var bankLabel = browsing ? browsing.label : api().label();
      var cells = [];
      slotView = { slots: slots, here: here, bankLabel: bankLabel, browsing: browsing, movable: movable, cells: cells };

      slots.forEach(function (slot, i) {
        var marked = picking ? i === target : i === here;
        var b = button("browser-slot" + (slot ? "" : " empty") +
                       (marked ? (picking ? " target" : " on") : ""));
        if (marked) b.setAttribute("aria-current", "true");
        if (transfer && bankLabel === job.from.bank && i === job.from.slot) {
          b.classList.add("source");
          b.title = "This is the slot being " + (mode === "copy" ? "copied" : "moved") + ".";
        }
        b.setAttribute("data-slot", String(i));

        b.appendChild(element("span", "browser-slot-num", pad3(i)));
        b.appendChild(element("span", "browser-slot-name", slot ? slot.name : "—"));

        b.addEventListener("click", function (e) {
          if (picking) {
            setTarget(i);
            paintSlots();
          } else {
            // The release of a press and hold is a click on the slot, and the
            // hold already said what it was for. It goes no further either:
            // a click that reached the document would shut the menu the hold
            // opened, as a click anywhere else does.
            if (swallowUntil) {
              var swallow = Date.now() < swallowUntil;
              swallowUntil = 0;
              if (swallow) {
                e.stopPropagation();
                // Releasing a finger on a button focuses it, which took the
                // focus out of the menu the hold had opened.
                if (!more.list.hidden) more.open(true, "first");
                return;
              }
            }
            if (browsing) api().loadBrowsed(i);
            else api().load(i);
            paintSlots();
          }
        });
        if (!picking) {
          b.addEventListener("dblclick", function () {
            if (browsing) api().loadBrowsed(i);
            else api().load(i);
            window.SynthModal.close();
          });
          // A slot is looked at, in the details, without being loaded: by the
          // keyboard, which has the focus on it before it has done anything
          // to it, and by the menu key or a right click, which ask about it.
          // A click is still a load, as it always was.
          b.addEventListener("focus", function () { inspect(i); });
          function askAbout() {
            inspect(i);
            if (movable && slot) {
              setDetailsOpen(true);
              more.open(true, "first");
            }
          }
          function ask(e) {
            e.preventDefault();
            askAbout();
          }
          b.addEventListener("contextmenu", ask);
          b.addEventListener("pointerdown", function (e) {
            cancelHold();
            swallowUntil = 0;
            if (e.pointerType !== "touch" && e.pointerType !== "pen") return;
            var h = { x: e.clientX, y: e.clientY, held: false, timer: 0 };
            h.timer = setTimeout(function () {
              h.held = true;
              askAbout();
            }, HOLD_MS);
            hold = h;
          });
          b.addEventListener("pointermove", function (e) {
            if (!hold || hold.held) return;
            if (Math.abs(e.clientX - hold.x) > HOLD_SLOP || Math.abs(e.clientY - hold.y) > HOLD_SLOP) cancelHold();
          });
          b.addEventListener("pointerup", function () {
            if (hold && hold.held) swallowUntil = Date.now() + 600;
            cancelHold();
          });
          b.addEventListener("pointercancel", cancelHold);
          b.addEventListener("pointerleave", function () {
            // After the hold has fired the finger is still down and may roll
            // off the slot on its way up: the release is still the hold's.
            if (hold && !hold.held) cancelHold();
          });
          // The menu key and Shift+F10 are what a keyboard has for the same
          // thing. A browser turns them into a contextmenu event of its own,
          // but not everywhere and not under automation, and this is the one
          // way along 128 slots to the menu in the details without tabbing
          // through all of them.
          b.addEventListener("keydown", function (e) {
            if (e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey)) ask(e);
          });
        }
        cells.push(b);
        grid.appendChild(b);
      });

      right.appendChild(grid);
      layoutGrid(grid, slots.length);
      paintNow();
      paintSlotDetails();

      var on = grid.querySelector(".browser-slot.on, .browser-slot.target");
      if (on) setTimeout(function () { on.scrollIntoView({ block: "center" }); }, 0);
      if (transfer) paintTransfer();
      giveSlot(held);
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

      // A row says a number, a name and one quiet line under the name of where
      // it is. What a sound is in more detail is in the details region; what
      // is true of it that the line should not hide -- it cannot be written
      // to, it is loading, it is not there -- is words on that line or, for
      // the two that change what a click does, a badge at the end.
      var at = positionOf(p);
      option.appendChild(element("span", "browser-result-num", at !== null ? pad3(at) : ""));
      var text = element("span", "browser-result-text");
      text.appendChild(element("span", "browser-result-name", p.name));
      var origin = p.origin === "session" ? "Unsaved" : api().originLabel(p.origin);
      var line = element("span", "browser-result-line");
      line.appendChild(element("span", "browser-result-meta",
        origin + (p.bank ? (origin ? " / " : "") + p.bank : "")));
      if (p.readOnly) line.appendChild(element("span", "browser-result-state", "Read-only"));
      text.appendChild(line);
      option.appendChild(text);
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
      right.appendChild(bar);

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
      paintPresetDetails();
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

    // The header: what is playing, from where, and in what state, in the words
    // the strip and the status line use. The name leads and the rest is quiet;
    // a state is words, not a badge, because it is true of the sound and not a
    // label on a row.
    function paintNow() {
      if (!now) return;
      var sel = api().selection();
      var status = api().status();
      var at = sel.slot !== null ? pad3(sel.slot) + " " : sel.archive ? pad3(sel.archive.patch) + " " : "";
      var origin = sel.origin === "session" ? "Unsaved" : api().originLabel(sel.origin);
      now.textContent = "";
      now.appendChild(element("span", "browser-now-label", "Playing "));
      now.appendChild(element("span", "browser-now-name", at + (sel.presetName || "Untitled")));
      now.appendChild(element("span", "browser-now-where", " · " + origin + (sel.bank ? " / " + sel.bank : "")));
      var words = [];
      if (status === "loading") words.push("Loading…");
      if (status === "unavailable") {
        var why = api().restoreState().error;
        words.push("Unavailable" + (why ? ": " + why : ""));
      }
      if (status === "dirty") words.push("Unsaved changes");
      if (api().readOnly()) words.push("Read-only");
      words.forEach(function (word) {
        now.appendChild(element("span", "browser-now-state", " · " + word));
      });
      now.setAttribute("data-status", status);
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
            " not searched. Open one under Browse to include it.",
          kind: "hint",
        });
      }
      if (a && (a.open ? unopenedArchive.length > 0 : !!a.path)) {
        lines.push({
          text: a.open
            ? "Archive banks are searched once they are open. Open one under Browse to include its presets."
            : "The archive is not open, so Archives has no presets to search. Open it under Browse.",
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
      parts.focusAt = focusAt;
      paintNow();
      paintPresetDetails();
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

    // ------------------------------------------------------ the details

    // What the row or the slot that has the attention is, said once and at
    // length, so that the rows and the cells can say less. The one place the
    // facts about a sound that are not its name are written out: where it
    // came from, which bank, which slot, and what state it is in.
    //
    // Open beside the list where there is room for it, shut under the list
    // where there is not, and a button either way: it is the thing a person
    // asks for, not the thing they must read past.
    var detailsId = uid("browser-details");
    var details = element("aside", "browser-details");
    details.setAttribute("aria-label", "Details");
    var detailsToggle = button("browser-details-toggle", "Details");
    detailsToggle.setAttribute("aria-controls", detailsId);
    var detailsBody = element("div", "browser-details-body");
    detailsBody.id = detailsId;
    var detailName = element("p", "browser-detail-name");
    var detailFacts = element("dl", "browser-detail-facts");
    var detailActions = element("div", "browser-detail-actions");
    var detailHint = element("p", "browser-detail-hint");
    detailsBody.appendChild(detailName);
    detailsBody.appendChild(detailFacts);
    detailsBody.appendChild(detailActions);
    detailsBody.appendChild(detailHint);
    details.appendChild(detailsToggle);
    details.appendChild(detailsBody);

    function setDetailsOpen(open) {
      detailsToggle.setAttribute("aria-expanded", open ? "true" : "false");
      detailsBody.hidden = !open;
      if (!open && more) more.close();
    }
    setDetailsOpen(!narrow());
    detailsToggle.addEventListener("click", function () { setDetailsOpen(detailsBody.hidden); });

    // The window crossing the breakpoint while the dialog is open: a plugin
    // window dragged narrower, a phone turned. What was chosen for the width
    // it had is no longer right for the width it has -- a pane left open would
    // now be a sheet over the list -- so each is put as it would have been had
    // the dialog been opened at this width. Whoever had the focus in what is
    // hidden by it has it on the button that opens it, which is where they
    // would look for it.
    function widthChanged() {
      var active = document.activeElement;
      var inPane = left.contains(active);
      var inDetails = detailsBody.contains(active);
      setDrawerOpen(!narrow());
      setDetailsOpen(!narrow());
      if (narrow() && inPane) drawerToggle.focus();
      else if (narrow() && inDetails) detailsToggle.focus();
    }
    if (width && width.addEventListener) width.addEventListener("change", widthChanged);
    else if (width && width.addListener) width.addListener(widthChanged);

    // `model`: { name, facts: [[label, value], ...], actions, hint }. A fact
    // with nothing to say is left out rather than shown as a dash.
    //
    // `actions` are elements. The ones that are made once and wanted again
    // are left where they are, so that a button that has the focus keeps it
    // through a repaint; the ones made afresh each time are found again by
    // their place, as the rows are.
    function showDetails(model) {
      detailName.textContent = model.name;
      detailFacts.textContent = "";
      model.facts.forEach(function (fact) {
        if (!fact[1]) return;
        detailFacts.appendChild(element("dt", null, fact[0]));
        detailFacts.appendChild(element("dd", null, fact[1]));
      });
      detailHint.textContent = model.hint || "";
      detailHint.hidden = !model.hint;

      var wanted = model.actions || [];
      var held = document.activeElement;
      var holding = !!held && detailActions.contains(held);
      var kept = holding ? keep(detailActions) : -1;
      [].slice.call(detailActions.children).forEach(function (child) {
        if (wanted.indexOf(child) < 0) detailActions.removeChild(child);
      });
      wanted.forEach(function (action, at) {
        if (detailActions.children[at] !== action) {
          detailActions.insertBefore(action, detailActions.children[at] || null);
        }
      });
      detailActions.hidden = !wanted.length;
      if (holding && !detailActions.contains(held)) give(detailActions, kept);
    }

    // The preset the list has its attention on: the one the arrows reached or
    // that was clicked, and failing that the one that is playing.
    function paintPresetDetails() {
      if (picking || !parts) return;
      var p = shownByKey[activeKey] || shownByKey[parts.focusAt];
      if (!p) {
        showDetails({ name: "No preset selected", facts: [] });
        return;
      }
      var at = positionOf(p);
      var sel = api().selection();
      var playing = isPlaying(p, sel);
      var status = [];
      if (playing) status.push("Playing");
      if (isPending(p)) status.push("Loading…");
      if (p.unavailable) status.push("Unavailable");
      if (p.readOnly) status.push("Read-only");
      var actions = [];
      // Loading what the arrows have reached, for a person who has not got
      // Enter to hand. Not offered for what cannot be loaded or is already
      // the sound, which a click would only say.
      if (!playing && !p.unavailable && !p.live && !isPending(p)) {
        var load = button("browser-action", "Load");
        load.setAttribute("aria-label", "Load " + p.name);
        load.addEventListener("click", function () {
          choose(p);
          // The button is not there once the sound is: the row is.
          var row = activeRow();
          if (row) focusRow(row);
        });
        actions.push(load);
      }
      showDetails({
        name: p.name,
        facts: [
          ["Source", p.origin === "session" ? "Unsaved" : api().originLabel(p.origin)],
          ["Bank", p.bank],
          [p.archive ? "Patch" : "Slot", at !== null ? pad3(at) : ""],
          ["Status", status.join(" · ")],
        ],
        actions: actions,
      });
    }

    // The slot that has the attention in the bank in view: the one that is
    // playing, unless another has been looked at.
    //
    // What can be done to it is here and not on the slot: Load, for a slot
    // that is not the sound, and a menu for the two things that take its
    // preset somewhere else. Both are made once, so that a repaint does not
    // take the focus from under them.
    var slotLoad = button("browser-action", "Load");
    slotLoad.addEventListener("click", function () {
      var v = slotView;
      var at = inspectedAt(v);
      if (v.browsing) api().loadBrowsed(at);
      else api().load(at);
      paintSlots();
      focusSlot(at);
    });
    var more = menuButton({
      label: "Slot actions", listLabel: "Slot actions", className: "browser-more", listClass: "browser-menu-list",
    });
    var slotMenu = element("div", "browser-menu");
    slotMenu.appendChild(more.trigger);
    slotMenu.appendChild(more.list);
    function startTransfer(kind) {
      var v = slotView;
      var at = inspectedAt(v);
      var slot = at >= 0 ? v.slots[at] : null;
      if (slot) openTransfer(kind, { bank: v.bankLabel, slot: at }, slot.name);
    }
    var copyItem = more.add("Copy", function () { startTransfer("copy"); });
    var moveItem = more.add("Move", function () { startTransfer("move"); }, { destructive: true });
    copyItem.setAttribute("data-tool", "copy");
    moveItem.setAttribute("data-tool", "move");

    function paintSlotDetails() {
      if (picking || !slotView) return;
      var v = slotView;
      var at = inspectedAt(v);
      var row = viewRow();
      var slot = at >= 0 ? v.slots[at] : null;
      var playing = at >= 0 && at === v.here;
      var status = [];
      if (playing) status.push("Playing");
      if (row && row.readOnly) status.push("Read-only");
      v.cells.forEach(function (cell, i) { cell.classList.toggle("inspected", i === at && !playing); });

      var actions = [];
      if (at >= 0 && !playing) {
        slotLoad.setAttribute("aria-label", "Load " + (slot ? slot.name : "slot " + pad3(at)));
        actions.push(slotLoad);
      }
      if (v.movable && slot) {
        more.trigger.setAttribute("aria-label", "Slot actions for " + slot.name);
        more.trigger.setAttribute("data-slot", String(at));
        [[copyItem, "Copy"], [moveItem, "Move"]].forEach(function (pair) {
          pair[0].setAttribute("aria-label", pair[1] + " " + slot.name + " to...");
          pair[0].setAttribute("data-slot", String(at));
        });
        actions.push(slotMenu);
      } else {
        more.close();
      }
      showDetails({
        name: at < 0 ? "No slot selected" : slot ? slot.name : "Empty slot",
        facts: [
          ["Source", row ? api().originLabel(row.origin) : ""],
          ["Bank", row ? row.label : ""],
          ["Slot", at >= 0 ? pad3(at) : ""],
          ["Status", status.join(" · ")],
        ],
        actions: actions,
        hint: v.movable ? "Press the menu key, right-click or press and hold a slot to act on it without loading it." : "",
      });
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
      paintFilters();
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
      paintFilters();
      paintRight();
    }

    if (!picking) {
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
    }
    // The tabs, and at the far end the button for everything that narrows or
    // manages what the tabs show. A destination has no tabs, only the button.
    var bar = element("div", "browser-bar");
    if (tabs) bar.appendChild(tabs);
    bar.appendChild(drawerToggle);
    wrap.appendChild(bar);
    wrap.appendChild(main);
    if (!picking) main.appendChild(details);

    // Put the sound that is playing in the slot that is chosen, or ask first.
    //
    // The panel refuses to write over a sound unless it is told a person
    // agreed, so the person is asked, here, before it is told. Writing over the
    // preset's own slot is not asking for anything: that is Save, and Save does
    // not ask either. Anything else that holds a sound is somebody's, and the
    // question names it.
    function commitWrite() {
      var label = api().label();
      var old = api().slots()[target];
      var chosen = api().selection();
      var own = chosen.slot === target && chosen.bank === label;
      var name = field.value;
      function write(overwrite) {
        var result = api().writePreset({ bank: label, slot: target, name: name, overwrite: overwrite });
        wrote = result.ok;
        if (result.ok) window.SynthModal.close();
        else field.focus();
        return result;
      }
      if (!old || own) { write(!!old); return; }
      window.SynthModal.confirm({
        title: "Overwrite slot " + pad3(target) + "?",
        message: [
          slotWords(label, target) + " already holds " + old.name + ".",
          "Writing " + (name.trim() || "this sound") + " there will replace it.",
        ],
        confirmLabel: "Overwrite",
      }).then(function (yes) { if (yes) write(true); });
    }

    // A copy or a move, once somewhere has been chosen: the question comes
    // first, naming both ends and what is already at the far one, and nothing
    // is changed unless it is answered yes.
    function commitTransfer() {
      var label = api().label();
      var there = api().slots()[target];
      var to = { bank: label, slot: target };
      var verb = mode === "copy" ? "Copy" : "Move";
      var message = [
        verb + " " + job.name + " from " + slotWords(job.from.bank, job.from.slot) + " to " + slotWords(label, target) + ".",
        there ? slotWords(label, target) + " already holds " + there.name + ". It will be replaced."
          : slotWords(label, target) + " is empty.",
      ];
      if (mode === "move") message.push(slotWords(job.from.bank, job.from.slot) + " will be emptied.");
      window.SynthModal.confirm({
        title: verb + " " + job.name + "?",
        message: message,
        confirmLabel: there ? "Overwrite" : verb,
      }).then(function (yes) {
        if (!yes) return;
        var result = mode === "copy"
          ? api().copySlot(job.from, to, { overwrite: !!there })
          : api().moveSlot(job.from, to, { overwrite: !!there });
        if (result.ok) window.SynthModal.close();
      });
    }

    if (picking) wrap.appendChild(element("p", "browser-destination", "Choose destination"));

    // The write row: present the whole time in write mode, because it is the
    // point of the dialog rather than something hidden behind a button.
    if (forms) {
      var row = element("form", "browser-save");
      where = element("span", "browser-save-slot", "Slot " + pad3(target));
      field = element("input", "browser-save-name");
      field.type = "text";
      field.setAttribute("aria-label", "Patch name");
      var at = api().slots()[target];
      field.value = mode === "write" && at ? at.name : (window.SynthPatch.name() || "Untitled");
      field.addEventListener("input", function () { edited = true; });
      commitButton = element("button", "modal-action primary", mode === "write" ? "Write" : "Save");
      commitButton.type = "submit";
      row.appendChild(where);
      row.appendChild(field);
      row.appendChild(commitButton);
      row.addEventListener("submit", function (e) {
        e.preventDefault();
        commitWrite();
      });
      wrap.appendChild(row);
    }
    if (transfer) {
      where = element("p", "browser-transfer");
      where.setAttribute("role", "status");
      wrap.appendChild(where);
    }
    wrap.appendChild(feedback);

    // Anything the panel reports while the dialog is up -- a load that the host
    // refused, a bank that would not open, a copy that was refused -- is said
    // here as well as in the strip behind it.
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
    wrap.dispose = function () {
      stopListening();
      cancelHold();
      more.close();
      addMenu.close();
      toolsMenu.close();
      if (width && width.removeEventListener) width.removeEventListener("change", widthChanged);
      else if (width && width.removeListener) width.removeListener(widthChanged);
    };
    wrap.focusField = function () { if (field) { field.focus(); field.select(); } };
    wrap.focusSearch = function () { if (parts && parts.search) parts.search.focus(); };
    wrap.commit = commitTransfer;
    wrap.wrote = function () { return wrote; };
    return wrap;
  }

  // -------------------------------------------------------------------- open

  function openBrowser(options) {
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

    window.SynthModal.show("Patches", body, actions, { className: "modal-browser", onClose: body.dispose });
    if (view === "presets") body.focusSearch();
  }

  // Write and Save As: the dialog that chooses where the sound goes. Replaces
  // the browser if it is open, as Write always did.
  //
  // Choosing looks at other banks, and the bank in view is the one NEXT and
  // PREV step through, so a dialog that was cancelled puts it back: leaving it
  // where Save As arrived would change what the arrows do after nothing was
  // saved. A write that happened leaves it, because the sound is there now.
  function openDestination(mode) {
    if (!api()) return;
    var was = api().current();
    var inPage = !api().archive();
    var body = build(mode);
    window.SynthModal.show(mode === "saveas" ? "Save As" : "Write", body,
      [{ label: "Cancel", onClick: function (close) { close(); } }], {
        className: "modal-browser",
        onClose: function () {
          body.dispose();
          if (inPage && !body.wrote() && api().current() !== was) api().select(was, true);
        },
      });
    body.focusField();
  }

  // Copy or Move of one slot: a dialog over the browser, which stays under it,
  // for choosing where it goes. Looking at other banks to choose moves the bank
  // the browser is in; it is put back, so that what is under this is what was
  // there.
  function openTransfer(mode, from, name) {
    if (!api()) return;
    var was = api().current();
    var inPage = !api().archive();
    var body = build(mode, "slots", { from: from, name: name });
    var verb = mode === "copy" ? "Copy" : "Move";
    window.SynthModal.show(verb + " " + name + " to...", body, [
      { label: "Cancel", onClick: function (close) { close(); } },
      { label: verb + " here", primary: true, onClick: function () { body.commit(); } },
    ], {
      className: "modal-browser",
      stacked: true,
      onClose: function () {
        body.dispose();
        if (inPage && api().current() !== was) api().select(was, true);
        window.SynthBrowser.refresh();
        // What had the focus is the menu that asked, which a repaint keeps; or,
        // if the details have moved on, the slot it was.
        var again = document.querySelector('.browser-more[data-slot="' + from.slot + '"]') ||
          document.querySelector('.browser-slot[data-slot="' + from.slot + '"]');
        if (again) again.focus();
      },
    });
  }

  // Open a file as a bank, from the strip's menu. The dialog does the same
  // from its own button and says the result in its own words; here there is no
  // dialog, and a refusal is something that must not be missed.
  function importBank() {
    if (!files() || !files().pick) {
      if (api() && api().announce) api().announce("This build cannot open files.", "error");
      return;
    }
    files().pick(function (err) {
      if (err && window.SynthModal) {
        window.SynthModal.alert({
          title: "Could not open that file",
          message: [err.message || "The file could not be opened.",
            "Nothing was changed. (" + (err.code || "InvalidBank") + ")"],
        });
      }
      window.SynthBrowser.refresh();
    });
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
    open: openBrowser,
    // Where to put the sound that is playing: on its own slot, any bank...
    write: function () { openDestination("write"); },
    // ... or a bank that can take it, starting on the first empty slot.
    saveAs: function () { openDestination("saveas"); },
    importBank: importBank,
  };
})();
