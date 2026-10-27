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
  // The slots in a bank; the same number app.js holds.
  var BANK_SLOTS = 128;

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

  // Every way an import can go wrong carries one of four codes, so a caller
  // can tell "that is not one of ours" from "that is ours and damaged" from
  // "that does not fit" from "the file could not be read" without matching
  // on prose. The prose stays what it always was, for people.
  //
  //   UnsupportedFormat  not a format this build reads: a different `format`,
  //                      a newer `version`, a container it cannot open
  //   InvalidBank        it is one of ours and cannot be used: it does not
  //                      parse, holds nothing, or names a parameter that does
  //                      not exist
  //   TooManySlots       a JSON bank with more than 128 patches
  //   ReadFailed         the file could not be read at all
  function failure(code, message) {
    var err = new Error(message);
    err.code = code;
    return err;
  }

  // The bank at `which` -- the one in view when absent -- as the document the
  // format describes, or null when there is nothing honest to write.
  //
  // Only what is stored. The sound being edited used to be substituted for the
  // slot it was loaded from, so that saving after a tweak kept the tweak; it
  // also meant a bank written to disk, or sent to a host to keep, held a sound
  // nobody had chosen to put there. Writing a sound into a bank is a Save or a
  // Write, and says so; an export or a keep is of the bank as it is.
  function bankDoc(which) {
    var slots = window.SynthBank;
    if (!slots) return null;
    var at = which === undefined ? slots.current() : which;
    var info = slots.bankInfo(at);
    // A bank that is listed but not read has no patches to write, and a file
    // of 128 empty slots would pass for the real bank.
    if (!info || info.kind === "archive" || info.used === null) return null;

    // Position is meaning. A patch in slot 41 has to come back in slot 41, or
    // every reference to it by number -- a set list, a program change -- points
    // at a different sound after a round trip. So an empty slot is written as
    // null rather than skipped: that is what keeps the ones after it in place.
    //
    // Trailing empties are dropped. A bank whose last sound is in slot 20
    // writes 21 entries and loading pads it back to 128; there is nothing to
    // preserve about an empty slot at the end.
    var stored = slots.snapshot(at);
    if (!stored) return null;
    return {
      format: FORMAT_BANK,
      version: FORMAT_VERSION,
      name: slots.label(at),
      patches: stored.map(function (p) { return p ? patchObject(p.n, p.v) : null; }),
    };
  }

  // Said once, in the strip, and handed back as the object it describes.
  function reportOf(result) {
    var slots = window.SynthBank;
    return slots && slots.report ? slots.report(result) : result;
  }

  function exportFailed(action, code, message) {
    return reportOf({ ok: false, action: action, error: { code: code, message: message } });
  }

  // Write the bank at `which` to a file: the stored slots, interior empties
  // kept as null, and a plain statement of anything the file does not hold.
  function saveBank(which) {
    var slots = window.SynthBank;
    var doc = bankDoc(which);
    if (!doc) {
      return exportFailed("export-bank", "UnavailableSource",
        "That bank has not been opened, so there is nothing to export yet.");
    }
    try {
      download(safeName(doc.name || "bank", ".json"), JSON.stringify(doc, null, 2) + "\n");
    } catch (err) {
      return exportFailed("export-bank", "ExportFailed", "Could not write the file: " + err.message);
    }
    var count = doc.patches.filter(Boolean).length;
    // A person looking at an edited sound and pressing Export is owed knowing
    // the edit is not in the file.
    var unsaved = slots && slots.status && slots.status() === "dirty";
    var name = slots && slots.selection ? slots.selection().presetName : "";
    return reportOf({
      ok: true, action: "export-bank", name: doc.name, count: count, unsaved: !!unsaved,
      warning: !!unsaved,
      message: "Exported " + doc.name + " (" + count + (count === 1 ? " patch" : " patches") + ")." +
        (unsaved ? " Unsaved changes to " + (name || "the sound") + " were not included." : ""),
    });
  }

  // Write the sound that is playing as a `quesynth.patch` file.
  function savePatch() {
    var api = window.SynthPatch;
    var slots = window.SynthBank;
    if (!api) return exportFailed("export-patch", "UnavailableSource", "There is no sound to export.");
    var one = patchObject(api.name(), api.values());
    var doc = { format: FORMAT_PATCH, version: FORMAT_VERSION, name: one.name, parameters: one.parameters };
    try {
      download(safeName(one.name, ".json"), JSON.stringify(doc, null, 2) + "\n");
    } catch (err) {
      return exportFailed("export-patch", "ExportFailed", "Could not write the file: " + err.message);
    }
    // Only a sound with no slot is now "as saved". One that came from a slot is
    // still not what that slot holds, however many files it has been written
    // to.
    var cleared = !!(slots && slots.patchExported && slots.patchExported());
    return reportOf({
      ok: true, action: "export-patch", name: one.name, cleared: cleared,
      message: "Exported " + one.name + ".",
    });
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
        throw failure("InvalidBank", "unknown parameter: " + key);
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
      throw failure("UnsupportedFormat", "not a " + expected + " file");
    }
    if (doc.version !== undefined && doc.version > FORMAT_VERSION) {
      throw failure("UnsupportedFormat", "written by a newer version (" + doc.version + ")");
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

  // A JSON bank, read completely or refused. Nothing is added to the panel
  // until every patch in it has been read, so a bank with one bad entry in the
  // middle is not half there.
  //
  // `strict` is for a bank somebody opened: more than a bank's 128 patches is
  // refused, not cut off, because a bank that silently lost its tail is not the
  // bank in the file. A bank a host hands over has only ever had 128.
  function parseBankDoc(doc, strict) {
    checkHeader(doc, FORMAT_BANK);
    if (!Array.isArray(doc.patches) || !doc.patches.length) {
      throw failure("InvalidBank", "the bank has no patches");
    }
    if (strict && doc.patches.length > BANK_SLOTS) {
      throw failure("TooManySlots", "the bank has " + doc.patches.length +
        " patches and a bank holds " + BANK_SLOTS);
    }
    // A null entry is an empty slot, and it is kept rather than compacted
    // away: dropping it would shift every patch after it down by one and
    // silently renumber the bank.
    var patches = doc.patches.map(function (p) {
      if (!p) return null;
      return { n: p.name || "Patch", v: valuesFrom(p.parameters || {}) };
    });
    return { label: doc.name || "Bank", patches: patches };
  }

  function parseJson(text) {
    try {
      return JSON.parse(text);
    } catch (err) {
      throw failure("InvalidBank", err.message);
    }
  }

  // The bank in a `quesynth.bank` document, as `{ label, patches }`, for the
  // panel to adopt from a host or for `load` to add. Throws with a code.
  function parseBank(text) {
    return parseBankDoc(parseJson(text), false);
  }

  // Add a bank that was read, and nothing else: the bank in view, the
  // selection, the sound and the host stay exactly as they were. The bank is a
  // row in the list until somebody chooses something in it.
  function addBank(label, patches, leftOut) {
    var slots = window.SynthBank;
    if (!slots || !slots.importBank) throw failure("UnsupportedFormat", "this build cannot hold several banks");
    var added = slots.importBank(label, patches);
    if (!added.ok) throw failure(added.error.code, added.error.message);
    var count = patches.filter(Boolean).length;
    return {
      kind: "bank", label: added.label, count: count, leftOut: leftOut || 0, index: added.index,
      message: count + " patches" + (leftOut ? " (" + leftOut + " left out)" : ""),
    };
  }

  function zipFailure(err) {
    if (err && err.code) return err;
    var message = err && err.message ? err.message : String(err);
    return failure(/cannot decompress/.test(message) ? "UnsupportedFormat" : "InvalidBank", message);
  }

  function sy1Failure(err) {
    if (err && err.code) return err;
    var message = err && err.message ? err.message : String(err);
    // Not recognisably the format at all, as opposed to the format damaged.
    return failure(/^(not a \.sy1 file|empty file)$/.test(message) ? "UnsupportedFormat" : "InvalidBank", message);
  }

  // A whole file, in whichever of the three formats it is, and what became of
  // it: `{ kind, message, ... }`. A bank is *added* -- see addBank -- and a
  // single patch becomes the sound, as a file's patch always has.
  //
  // Everything is read and checked before the panel is touched, so a file that
  // turns out to be damaged on its last patch leaves the panel as it found it.
  async function importBytes(bytes, filename) {
    var api = window.SynthPatch;
    if (!api) return { kind: "none", message: "" };

    switch (sniff(bytes)) {
      case "zip":
        // A shared archive lives at the host, not in this page. Publishing a
        // decoded zip as `bank` would replace the ordinary bank and leave
        // every other client without the archive it came from.
        if (window.SynthBank && window.SynthBank.archive && window.SynthBank.archive()) {
          throw failure("UnsupportedFormat", "Open this ZIP by its path in the Archive field in Patches.");
        }
        if (!window.SynthSy1) throw failure("UnsupportedFormat", "the .sy1 reader is not loaded");
        var found;
        try {
          found = await window.SynthSy1.readZip(bytes);
        } catch (err) {
          throw zipFailure(err);
        }

        // Patches straight inside: one bank, read now.
        if (found.length) {
          // A bank holds 128. A zip with more fills the bank, in the order the
          // archive lists them, and says how many were left out rather than
          // dropping them without a word.
          var over = Math.max(0, found.length - BANK_SLOTS);
          var base = defaults();
          var patches = found.slice(0, BANK_SLOTS).map(function (entry) {
            try {
              var p = window.SynthSy1.parse(entry.bytes, base);
              return { n: p.name || entry.name, v: p.values };
            } catch (err) {
              throw sy1Failure(err);
            }
          });
          var label = String(filename || "Bank").replace(/\.zip$/i, "");
          return addBank(label, patches, over);
        }

        // No patches, but archives inside: a zip of banks, which is how the
        // published collection comes -- one file holding a hundred and
        // seventy-five of them.
        //
        // Listed rather than read. Opening all of them would be eleven
        // megabytes of inflating and twenty thousand patches built to show a
        // hundred and seventy-five names, and only one is ever wanted at a
        // time. Each row keeps the bytes of its own archive and opens it when
        // it is picked.
        var inner;
        try {
          inner = await window.SynthSy1.readZippedBanks(bytes);
        } catch (err) {
          throw zipFailure(err);
        }
        if (!inner.length) throw failure("InvalidBank", "no .sy1 patches in the archive");

        var slots = window.SynthBank;
        if (!slots || !slots.addLazy) throw failure("UnsupportedFormat", "this build cannot hold several banks");

        inner.sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
        inner.forEach(function (entry) {
          slots.addLazy(entry.name, function () {
            return window.SynthSy1.readZip(entry.bytes).then(function (list) {
              if (!list.length) throw new Error("no .sy1 patches in " + entry.name);
              var d = defaults();
              return list.map(function (one) {
                var parsed = window.SynthSy1.parse(one.bytes, d);
                return { n: parsed.name || one.name, v: parsed.values };
              });
            });
          });
        });
        return { kind: "banks", count: inner.length, leftOut: 0, message: inner.length + " banks" };

      case "sy1":
        if (!window.SynthSy1) throw failure("UnsupportedFormat", "the .sy1 reader is not loaded");
        var one;
        try {
          one = window.SynthSy1.parse(bytes, defaults());
        } catch (err) {
          throw sy1Failure(err);
        }
        api.apply(one.values, one.name || String(filename || "Patch").replace(/\.sy1$/i, ""));
        return { kind: "patch", name: one.name, message: one.name || "patch" };

      default:
        return importText(textOf(bytes));
    }
  }

  function importText(text) {
    var api = window.SynthPatch;
    if (!api) return { kind: "none", message: "" };
    var doc = parseJson(text);

    if (doc && doc.format === FORMAT_BANK) {
      var parsed = parseBankDoc(doc, true);
      return addBank(parsed.label, parsed.patches, 0);
    }

    checkHeader(doc, FORMAT_PATCH);
    var values = valuesFrom(doc.parameters || {});
    api.apply(values, doc.name);
    return { kind: "patch", name: doc.name, message: doc.name || "patch" };
  }

  // What the three file formats have always answered with: a line saying what
  // was opened.
  async function loadBytes(bytes, filename) {
    return (await importBytes(bytes, filename)).message;
  }

  function loadText(text) {
    return importText(text).message;
  }

  // One hidden input, reused. Created on demand so a build that never opens the
  // menu never makes it.
  var input = null;

  // A bank as a folder of .sy1 files, which is the third shape one comes in.
  //
  // The reference keeps its own banks this way -- a directory per bank with a
  // patch per file -- so a bank on somebody's disk is as likely to be a folder
  // as a .zip of the same thing. Reading one is the same work as reading the
  // archive, minus the unzipping.
  //
  // Order is the file names, compared so that "10" sorts after "9" rather than
  // between "1" and "2". Sorting them as plain strings is what puts a bank's
  // hundredth patch third, and the numbering in these names is the whole point
  // of them.
  var collator = window.Intl && window.Intl.Collator
    ? new window.Intl.Collator(undefined, { numeric: true, sensitivity: "base" })
    : null;

  // The name, then where in the folder it was, so that two files that compare
  // equal -- "A.sy1" and "a.sy1" -- are not left in whatever order the browser
  // happened to list them. The same folder has to make the same bank twice.
  function byName(a, b) {
    var order = collator ? collator.compare(a.name, b.name) : 0;
    if (order) return order;
    if (a.name !== b.name) return a.name < b.name ? -1 : 1;
    var pa = a.webkitRelativePath || "", pb = b.webkitRelativePath || "";
    return pa < pb ? -1 : pa > pb ? 1 : 0;
  }

  function readOne(file) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onload = function () { resolve(new Uint8Array(reader.result)); };
      reader.onerror = function () { reject(failure("ReadFailed", "could not read " + file.name)); };
      reader.readAsArrayBuffer(file);
    });
  }

  async function importFolder(fileList) {
    var api = window.SynthPatch;
    if (!api) return { kind: "none", message: "" };
    if (!window.SynthSy1) throw failure("UnsupportedFormat", "the .sy1 reader is not loaded");

    var all = [].slice.call(fileList);
    var found = all.filter(function (f) { return /\.sy1$/i.test(f.name); });
    if (!found.length) throw failure("InvalidBank", "no .sy1 patches in that folder");

    found.sort(byName);

    // The folder's own name, off the relative path the browser gives with each
    // file. Falls back to the first path segment, then to something generic.
    // Taken from the first file *in order*, so that a folder with subfolders is
    // named the same whichever file the browser listed first.
    var label = "Bank";
    var path = found[0].webkitRelativePath || "";
    var parts = path.split("/");
    if (parts.length > 1) label = parts[parts.length - 2] || parts[0] || label;

    // A bank holds 128, so a folder with more than that in it fills the bank
    // and says how many were left out rather than silently dropping them.
    var over = Math.max(0, found.length - BANK_SLOTS);
    if (over) found = found.slice(0, BANK_SLOTS);

    var base = defaults();
    var patches = [];
    for (var i = 0; i < found.length; i++) {
      var bytes = await readOne(found[i]);
      var one;
      try {
        one = window.SynthSy1.parse(bytes, base);
      } catch (err) {
        throw sy1Failure(err);
      }
      patches.push({ n: one.name || found[i].name.replace(/\.sy1$/i, ""), v: one.values });
    }

    return addBank(label, patches, over);
  }

  async function loadFolder(fileList) {
    return (await importFolder(fileList)).message;
  }

  // Say how an import went, where it is seen, whichever way: the dialog that
  // asked has its own line, but it is not always on screen when the answer is.
  function announceImport(err, what) {
    var slots = window.SynthBank;
    if (!slots || !slots.report) return;
    if (err) {
      slots.report({
        ok: false, action: "import",
        error: { code: err.code || "InvalidBank", message: err.message || "could not open that file" },
      });
    } else {
      slots.report({
        ok: true, action: "import", warning: /left out/.test(what || ""),
        message: what ? "Opened " + what + "." : "Opened.",
      });
    }
  }

  // One hidden directory input, beside the file one. `webkitdirectory` is the
  // only way a page can be handed a folder, and despite the name every current
  // browser implements it.
  var folderInput = null;

  function pickFolder(onDone) {
    if (!folderInput) {
      folderInput = document.createElement("input");
      folderInput.type = "file";
      folderInput.webkitdirectory = true;
      folderInput.setAttribute("webkitdirectory", "");
      folderInput.setAttribute("directory", "");
      folderInput.multiple = true;
      folderInput.style.display = "none";
      document.body.appendChild(folderInput);
    }
    folderInput.value = "";
    folderInput.onchange = function () {
      if (!folderInput.files || !folderInput.files.length) return;
      loadFolder(folderInput.files)
        .then(function (what) { announceImport(null, what); onDone(null, what); })
        .catch(function (err) { announceImport(err); onDone(err); });
    };
    folderInput.click();
  }

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
          .then(function (what) { announceImport(null, what); onDone(null, what); })
          .catch(function (err) { announceImport(err); onDone(err); });
      };
      reader.onerror = function () {
        var err = failure("ReadFailed", "could not read the file");
        announceImport(err);
        onDone(err);
      };
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
    // The bank at `which` (the one in view without it) as the text of its file.
    // Only what is stored in its slots; see bankDoc.
    bankText: function (which) {
      var doc = bankDoc(which);
      return doc ? JSON.stringify(doc, null, 2) + "\n" : "";
    },
    // A host's bank as `{ label, patches }`, or a thrown error with a `code`.
    parseBank: parseBank,
    saveBank: saveBank,
    savePatch: savePatch,
    // Opening, as the line a person reads: "128 patches (3 left out)".
    load: loadText,
    loadBytes: loadBytes,
    loadFolder: loadFolder,
    // The same, as the object: what kind of thing it was, and how many.
    importText: importText,
    importBytes: importBytes,
    importFolder: importFolder,
    sniff: sniff,
    // Exposed so the bank browser can offer these without owning its own file
    // inputs, and so every way in ends up in one place.
    pick: pickFile,
    pickFolder: pickFolder,
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
