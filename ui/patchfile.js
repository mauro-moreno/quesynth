// Reading and writing patches and banks as files, from the panel.
//
// The format is the one src/patch/json.odin defines and documents -- keyed by
// parameter name, carrying stored integers, complete rather than sparse -- so a
// patch saved here loads in the engine, and a bank built by tools/factorybank
// loads here. That is the whole point of writing it in two places: if the two
// disagree the format is not a format, it is a habit.
//
// Everything is done with the file input and a blob download, which is the one
// mechanism that works in every host the panel runs in. The browser build has
// no filesystem, and the plugin's web view has one but cannot reach it from
// JavaScript; both support `<input type="file">` and an anchor with `download`.
// A native file dialog would be better in the plugin alone, and worse
// everywhere else, and would need the same work again per host.

(function () {
  "use strict";

  var FORMAT_PATCH = "quesynth.patch";
  var FORMAT_BANK = "quesynth.bank";
  var FORMAT_VERSION = 1;

  function params() {
    return window.SYNTH1_PARAMS || [];
  }

  // -- writing ---------------------------------------------------------------

  // One patch as the object the format describes. Emitted in parameter order so
  // two saves of the same patch are the same bytes: a file that reorders itself
  // produces a diff for no reason, which is the same argument the Odin writer
  // makes for not marshalling a map.
  function patchObject(name, values) {
    var out = {};
    var table = params();
    for (var i = 0; i < table.length; i++) {
      out[table[i].name] = values[i];
    }
    return { name: name || "Patch", parameters: out };
  }

  function download(filename, text) {
    var blob = new Blob([text], { type: "application/json" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    // Revoked on a timer rather than immediately: some browsers have not
    // finished reading the blob when click() returns, and revoking under them
    // saves an empty file.
    setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
  }

  // A filename from a patch name, without the characters a filesystem objects
  // to. "Solo Lead" becomes "Solo Lead.json"; anything stranger degrades to
  // underscores rather than to a failed save.
  function safeName(name, extension) {
    var base = String(name || "patch").replace(/[^A-Za-z0-9 _-]+/g, "_").trim();
    return (base || "patch") + extension;
  }

  function savePatch() {
    var api = window.SynthPatch;
    if (!api) return;
    var name = api.name();
    var doc = {
      format: FORMAT_PATCH,
      version: FORMAT_VERSION,
      name: patchObject(name, api.values()).name,
      parameters: patchObject(name, api.values()).parameters,
    };
    download(safeName(name, ".json"), JSON.stringify(doc, null, 2) + "\n");
  }

  function saveBank() {
    var api = window.SynthPatch;
    if (!api) return;
    var bank = api.bank();
    if (!bank || !bank.patches.length) return;

    // The bank as it stands, including any patch the player has edited: the
    // current parameter set replaces the entry it was loaded from, so saving
    // after a tweak keeps the tweak. Anything else would quietly discard it.
    var current = api.values();
    var patches = bank.patches.map(function (p, i) {
      var values = i === bankIndexOf(bank) ? current : p.v;
      return patchObject(p.n, values);
    });

    var doc = {
      format: FORMAT_BANK,
      version: FORMAT_VERSION,
      name: bank.label || "Bank",
      patches: patches,
    };
    download(safeName(bank.label || "bank", ".json"), JSON.stringify(doc, null, 2) + "\n");
  }

  // Which entry of the bank is loaded. Read off the bar rather than tracked
  // here, so there is one answer to it and app.js owns it.
  function bankIndexOf(bank) {
    var shown = document.getElementById("bank-patch");
    if (!shown) return -1;
    var n = parseInt(String(shown.textContent).split(":")[0], 10);
    return isNaN(n) ? -1 : n;
  }

  // -- reading ---------------------------------------------------------------

  // Stored integers out of a parameters object, in parameter order.
  //
  // A name this build does not know is refused rather than ignored, and a
  // missing one takes its default -- the same two rules the Odin reader
  // follows, and for the same reason: silently dropping a name loads something
  // that is not the patch in the file.
  function valuesFrom(object) {
    var table = params();
    var known = {};
    for (var i = 0; i < table.length; i++) known[table[i].name] = i;

    for (var key in object) {
      if (!Object.prototype.hasOwnProperty.call(object, key)) continue;
      if (known[key] === undefined) {
        throw new Error("unknown parameter: " + key);
      }
    }

    var out = [];
    for (var j = 0; j < table.length; j++) {
      var v = object[table[j].name];
      out.push(v === undefined ? table[j].def : Math.round(Number(v)));
    }
    return out;
  }

  function checkHeader(doc, expected) {
    if (!doc || doc.format !== expected) {
      throw new Error("not a " + expected + " file");
    }
    if (doc.version !== undefined && doc.version > FORMAT_VERSION) {
      throw new Error("written by a newer version (" + doc.version + ")");
    }
  }

  function loadText(text) {
    var api = window.SynthPatch;
    if (!api) return;
    var doc = JSON.parse(text);

    if (doc.format === FORMAT_BANK) {
      checkHeader(doc, FORMAT_BANK);
      if (!Array.isArray(doc.patches) || !doc.patches.length) {
        throw new Error("the bank has no patches");
      }
      var patches = doc.patches.map(function (p) {
        return { n: p.name || "Patch", v: valuesFrom(p.parameters || {}) };
      });
      api.setBank(doc.name || "Bank", patches);
      return doc.patches.length + " patches";
    }

    checkHeader(doc, FORMAT_PATCH);
    api.apply(valuesFrom(doc.parameters || {}), doc.name);
    return doc.name || "patch";
  }

  // One hidden input, reused. Created on demand so a build that never opens the
  // menu never makes it.
  var input = null;

  function pickFile(onDone) {
    if (!input) {
      input = document.createElement("input");
      input.type = "file";
      input.accept = ".json,application/json";
      input.style.display = "none";
      document.body.appendChild(input);
    }
    input.value = "";
    input.onchange = function () {
      var file = input.files && input.files[0];
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () {
        try {
          onDone(null, loadText(String(reader.result)));
        } catch (err) {
          onDone(err);
        }
      };
      reader.onerror = function () { onDone(new Error("could not read the file")); };
      reader.readAsText(file);
    };
    input.click();
  }

  // -- the menu --------------------------------------------------------------

  var menu = null;

  function flash(text) {
    var button = document.getElementById("file-toggle");
    if (!button) return;
    var resting = "FILE";
    button.textContent = text;
    setTimeout(function () { button.textContent = resting; }, 1600);
  }

  function buildMenu() {
    menu = document.createElement("div");
    menu.id = "file-menu";
    menu.className = "bank-list";
    document.body.appendChild(menu);
    document.addEventListener("click", function () { menu.classList.remove("open"); });
    menu.addEventListener("click", function (e) { e.stopPropagation(); });

    var items = [
      ["Save patch", function () { savePatch(); flash("SAVED"); }],
      ["Load patch or bank…", function () {
        pickFile(function (err, what) {
          flash(err ? "FAILED" : "LOADED");
          if (err) console.error("patch file:", err.message);
        });
      }],
      ["Save bank", function () { saveBank(); flash("SAVED"); }],
    ];

    items.forEach(function (item) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = item[0];
      b.addEventListener("click", function () {
        menu.classList.remove("open");
        item[1]();
      });
      menu.appendChild(b);
    });
  }

  function openMenu(anchor) {
    if (!menu) buildMenu();
    menu.classList.add("open");
    var r = anchor.getBoundingClientRect();
    var w = menu.offsetWidth;
    menu.style.left = Math.round(Math.max(8,
      Math.min(r.left + r.width / 2 - w / 2, window.innerWidth - w - 8))) + "px";
    menu.style.bottom = Math.round(window.innerHeight - r.top + 8) + "px";
  }

  // The reading and writing, without the file handling around it.
  //
  // Exposed because the claim this module makes -- that what it writes is the
  // format src/patch/json.odin reads, and the other way round -- is checkable,
  // and a claim about two implementations agreeing is worth nothing until
  // somebody checks it. A host that wants to hand the panel a patch it got from
  // somewhere else can use it too.
  window.SynthPatchFile = {
    patchText: function () {
      var api = window.SynthPatch;
      var built = patchObject(api.name(), api.values());
      return JSON.stringify({
        format: FORMAT_PATCH,
        version: FORMAT_VERSION,
        name: built.name,
        parameters: built.parameters,
      }, null, 2) + "\n";
    },
    load: loadText,
  };

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("file-toggle");
    if (!button) return;
    button.addEventListener("click", function (e) {
      e.stopPropagation();
      if (menu && menu.classList.contains("open")) {
        menu.classList.remove("open");
      } else {
        openMenu(button);
      }
    });
  });
})();
