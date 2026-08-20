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

  function bankDoc() {
    var slots = window.SynthBank;
    var api = window.SynthPatch;
    if (!slots || !api) return null;

    // Position is meaning. A patch in slot 41 has to come back in slot 41, or
    // every reference to it by number -- a set list, a program change -- points
    // at a different sound after a round trip. So an empty slot is written as
    // null rather than skipped: that is what keeps the ones after it in place.
    //
    // Trailing empties are dropped. A bank whose last sound is in slot 20
    // writes 21 entries and loading pads it back to 128; there is nothing to
    // preserve about an empty slot at the end.
    var here = slots.index();
    // Including an edit in progress: the live parameters replace the entry
    // they were loaded from, so saving after a tweak keeps the tweak. Anything
    // else would quietly discard it.
    var current = api.values();
    var patches = slots.used().map(function (p, i) {
      if (i === here) return patchObject(p ? p.n : api.name(), current);
      return p ? patchObject(p.n, p.v) : null;
    });

    return {
      format: FORMAT_BANK,
      version: FORMAT_VERSION,
      name: slots.label(),
      patches: patches,
    };
  }

  function saveBank() {
    var doc = bankDoc();
    if (!doc) return;
    download(safeName(doc.name || "bank", ".json"), JSON.stringify(doc, null, 2) + "\n");
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

  // What a file is, decided by looking at it.
  //
  // Sniffed rather than taken from the extension, for the reason
  // patch.detect_format gives on the engine side: a path can lie, and the three
  // formats begin with bytes that cannot be confused -- a zip with "PK\3\4",
  // JSON with a brace, and a Synth1 patch with its own name.
  function sniff(bytes) {
    var i = 0;
    while (i < bytes.length && (bytes[i] === 32 || bytes[i] === 9 || bytes[i] === 13 || bytes[i] === 10)) i++;
    if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4B) return "zip";
    if (i < bytes.length && bytes[i] === 0x7B) return "json";
    return "sy1";
  }

  function defaults() {
    return params().map(function (p) { return p.def; });
  }

  function textOf(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }

  // A whole file, in whichever of the three formats it is.
  //
  // A zip becomes a bank, because that is what one is: the patch banks people
  // share are archives of `.sy1` files, and loading one patch out of forty
  // would be answering a question nobody asked.
  async function loadBytes(bytes, filename) {
    var api = window.SynthPatch;
    if (!api) return "";

    switch (sniff(bytes)) {
      case "zip":
        if (!window.SynthSy1) throw new Error("the .sy1 reader is not loaded");
        var found = await window.SynthSy1.readZip(bytes);
        if (!found.length) throw new Error("no .sy1 patches in the archive");
        var base = defaults();
        var patches = found.map(function (entry) {
          var p = window.SynthSy1.parse(entry.bytes, base);
          return { n: p.name || entry.name, v: p.values };
        });
        var label = String(filename || "Bank").replace(/\.zip$/i, "");
        api.setBank(label, patches);
        return patches.length + " patches";

      case "sy1":
        if (!window.SynthSy1) throw new Error("the .sy1 reader is not loaded");
        var one = window.SynthSy1.parse(bytes, defaults());
        api.apply(one.values, one.name || String(filename || "Patch").replace(/\.sy1$/i, ""));
        return one.name || "patch";

      default:
        return loadText(textOf(bytes));
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
      // A null entry is an empty slot, and it is kept rather than compacted
      // away: dropping it would shift every patch after it down by one and
      // silently renumber the bank.
      var patches = doc.patches.map(function (p) {
        if (!p) return null;
        return { n: p.name || "Patch", v: valuesFrom(p.parameters || {}) };
      });
      api.setBank(doc.name || "Bank", patches);
      return patches.filter(Boolean).length + " patches";
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
      input.accept = ".json,.sy1,.zip,application/json,application/zip";
      input.style.display = "none";
      document.body.appendChild(input);
    }
    input.value = "";
    input.onchange = function () {
      var file = input.files && input.files[0];
      if (!file) return;
      var reader = new FileReader();
      // Read as bytes, not as text: a zip is binary, and decoding it as text
      // first would corrupt it before anything got the chance to look.
      reader.onload = function () {
        loadBytes(new Uint8Array(reader.result), file.name)
          .then(function (what) { onDone(null, what); })
          .catch(function (err) { onDone(err); });
      };
      reader.onerror = function () { onDone(new Error("could not read the file")); };
      reader.readAsArrayBuffer(file);
    };
    input.click();
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
    bankText: function () {
      var doc = bankDoc();
      return doc ? JSON.stringify(doc, null, 2) + "\n" : "";
    },
    savePatch: savePatch,
    saveBank: saveBank,
    load: loadText,
    loadBytes: loadBytes,
    sniff: sniff,
    // Exposed so the bank browser can offer the same thing without owning a
    // second file input, and so both paths end up in one place.
    pick: pickFile,
  };

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("write-toggle");
    if (!button || !window.SynthBrowser) return;
    button.addEventListener("click", function (e) {
      e.stopPropagation();
      window.SynthBrowser.write();
    });
  });
})();
