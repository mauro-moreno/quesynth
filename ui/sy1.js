// Reading Synth1's own `.sy1` patches, and the archives they are shipped in.
//
// This is a **second implementation** of what `src/patch/sy1.odin` does, which
// is a thing this project is otherwise careful not to have. It exists because
// the panel has to read a dropped file in every host it runs in, and only one
// of those hosts has the Odin parser within reach: the browser build keeps its
// engine in an AudioWorklet, so asking it to parse would mean a round trip
// through the audio thread for something that is not audio.
//
// The duplication is therefore *checked* rather than trusted. `tools/sy1check`
// runs this reader and the Odin one over every patch in a bank and compares all
// ninety-nine values of each; the two disagreeing is a build failure, not a
// surprise discovered later. Anything changed in sy1.odin has to be changed
// here, and that check is what says so.
//
// The pre-1.07 conversion below is the most important part of it. Every factory
// patch is `ver=105`, and v1.07 redefined parameters they all carry -- on two
// of them from a one-sided range to one centred at 63, so reading the number
// raw does not merely misplace it, it puts it on the wrong side of zero. The
// laws and the measurements behind them are documented at length in
// src/patch/sy1.odin; only the summary is repeated here.

(function () {
  "use strict";

  var BIPOLAR_VERSION = 107;

  function clampIndex(v) {
    if (v < 0) return 0;
    if (v > 127) return 127;
    return v;
  }

  // Exact-match tables. A value not listed is left alone, which is what the
  // Odin `sy1_lookup` does by returning its "not found" flag.
  var FEEDBACK_POINTS = [[0, 64], [78, 64], [127, 6]];
  var RATE_POINTS = [[19, 24], [26, 29], [64, 50]];
  var DELAY_TIME_POINTS = [[16, 19], [23, 24], [64, 64]];

  function lookup(table, v) {
    for (var i = 0; i < table.length; i++) {
      if (table[i][0] === v) return table[i][1];
    }
    return null;
  }

  // One curve, sampled by the four envelope-time parameters.
  var ENV_CURVE = [
    [0, 0], [8, 0], [28, 23], [39, 38], [47, 47], [60, 59], [64, 62],
    [68, 66], [78, 74], [92, 87], [104, 99], [105, 100], [118, 115],
  ];

  function envConvert(v) {
    var n = ENV_CURVE.length;
    if (v <= ENV_CURVE[0][0]) return ENV_CURVE[0][1];
    var last = ENV_CURVE[n - 1];
    // Past the measured range, hold the offset the last point had rather than
    // continuing a slope no measurement supports.
    if (v >= last[0]) return clampIndex(v + last[1] - last[0]);
    for (var i = 0; i < n - 1; i++) {
      var a = ENV_CURVE[i], b = ENV_CURVE[i + 1];
      if (v >= a[0] && v <= b[0]) {
        var span = b[0] - a[0];
        if (span <= 0) return a[1];
        // Integer arithmetic, rounded the same way the Odin does it: the two
        // must agree to the unit, and floating point rounding would not.
        return clampIndex(a[1] + Math.floor(((v - a[0]) * (b[1] - a[1]) * 2 + span) / (span * 2)));
      }
    }
    return clampIndex(v);
  }

  function upgradePre107(values, present, version) {
    if (version <= 0 || version >= BIPOLAR_VERSION) return;

    // 21 went from a one-sided 0..127 to a range whose zero is stored 63.
    if (present[21]) {
      values[21] = clampIndex(63 + Math.floor((values[21] * 64 * 2 + 127) / (127 * 2)));
    }
    // The delay's old level became a dry/wet balance over the same range.
    if (present[37]) {
      values[37] = clampIndex(Math.floor(values[37] / 2));
    }
    var tables = [[55, FEEDBACK_POINTS], [54, RATE_POINTS], [52, DELAY_TIME_POINTS]];
    for (var t = 0; t < tables.length; t++) {
      var index = tables[t][0];
      if (!present[index]) continue;
      var mapped = lookup(tables[t][1], values[index]);
      if (mapped !== null) values[index] = clampIndex(mapped);
    }
    var envelopes = [16, 18, 26, 28];
    for (var e = 0; e < envelopes.length; e++) {
      if (present[envelopes[e]]) values[envelopes[e]] = envConvert(values[envelopes[e]]);
    }
    // 50 and 51 are deliberately untouched: the same input converts to four
    // different outputs across the converted patches, so no function of the
    // value alone can express them.
  }

  // Bytes to text. The files are ASCII with the occasional stray byte in a
  // name; latin1 keeps every byte addressable rather than replacing it.
  function toText(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }

  // Parse one `.sy1`. Returns { name, version, values } or throws.
  function parse(bytes, defaults) {
    var lines = toText(bytes).split(/\r\n|\n|\r/);
    if (!lines.length) throw new Error("empty file");

    var values = defaults.slice();
    var present = [];
    for (var i = 0; i < values.length; i++) present.push(false);

    var name = lines[0];
    if (name.indexOf("Synth1 ") === 0) {
      name = name.slice("Synth1 ".length);
    } else if (!name.length) {
      throw new Error("not a .sy1 file");
    }

    if (lines.length < 3) throw new Error("not a .sy1 file");
    if (lines[1].indexOf("color=") !== 0) throw new Error("not a .sy1 file");
    if (lines[2].indexOf("ver=") !== 0) throw new Error("not a .sy1 file");
    var version = parseInt(lines[2].slice("ver=".length), 10);
    if (isNaN(version)) throw new Error("not a .sy1 file");

    for (var l = 3; l < lines.length; l++) {
      var line = lines[l].trim();
      if (!line.length) continue;
      var parts = line.split(",");
      if (parts.length !== 2) throw new Error("malformed line: " + line);
      var index = parseInt(parts[0].trim(), 10);
      var value = parseInt(parts[1].trim(), 10);
      if (isNaN(index) || isNaN(value)) throw new Error("malformed line: " + line);
      if (index < 0 || index >= values.length) {
        throw new Error("parameter " + index + " is out of range");
      }
      values[index] = value;
      present[index] = true;
    }

    upgradePre107(values, present, version);
    return { name: name.trim(), version: version, values: values };
  }

  // -- zip -------------------------------------------------------------------
  //
  // Enough of the format to list an archive and pull the `.sy1` files out of
  // it, which is how the patch banks people share are packaged.
  //
  // Read from the end: the central directory is the only part of a zip that is
  // authoritative about what is in it, because a local header may leave the
  // sizes as zero and defer them to a descriptor after the data. Walking local
  // headers forwards works on most archives and silently truncates on the rest.
  //
  // Deflate is done by the browser's own DecompressionStream rather than by an
  // inflate written here. It is in every engine this panel runs in, including
  // the plugin's WebView2, and a hand-written inflate would be several hundred
  // lines of exactly the sort of code that is wrong in one corner case.

  function u16(view, at) { return view.getUint16(at, true); }
  function u32(view, at) { return view.getUint32(at, true); }

  function findCentralDirectory(view) {
    // The end-of-central-directory record, searched backwards. Its comment can
    // be up to 64 KB, so the scan is bounded by that rather than by a guess.
    var limit = Math.min(view.byteLength, 0xFFFF + 22);
    for (var i = 22; i <= limit; i++) {
      var at = view.byteLength - i;
      if (at < 0) break;
      if (u32(view, at) === 0x06054b50) {
        return { entries: u16(view, at + 10), offset: u32(view, at + 16) };
      }
    }
    return null;
  }

  async function inflateRaw(bytes) {
    if (typeof DecompressionStream !== "function") {
      throw new Error("this browser cannot decompress zip entries");
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    var buffer = await new Response(stream).arrayBuffer();
    return new Uint8Array(buffer);
  }

  // Every `.sy1` in an archive, as { name, bytes }, in the order the directory
  // lists them.
  async function readZip(bytes) {
    var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    var end = findCentralDirectory(view);
    if (!end) throw new Error("not a zip file");

    var out = [];
    var at = end.offset;
    for (var i = 0; i < end.entries; i++) {
      if (u32(view, at) !== 0x02014b50) break;
      var method = u16(view, at + 10);
      var compressed = u32(view, at + 20);
      var nameLen = u16(view, at + 28);
      var extraLen = u16(view, at + 30);
      var commentLen = u16(view, at + 32);
      var localAt = u32(view, at + 42);
      var name = toText(bytes.subarray(at + 46, at + 46 + nameLen));
      at += 46 + nameLen + extraLen + commentLen;

      if (!/\.sy1$/i.test(name)) continue;

      // The local header repeats the name and extra fields at its own lengths,
      // which are not always the ones in the directory. Read them from there.
      if (u32(view, localAt) !== 0x04034b50) continue;
      var localNameLen = u16(view, localAt + 26);
      var localExtraLen = u16(view, localAt + 28);
      var dataAt = localAt + 30 + localNameLen + localExtraLen;
      var raw = bytes.subarray(dataAt, dataAt + compressed);

      var content;
      if (method === 0) {
        content = raw;
      } else if (method === 8) {
        content = await inflateRaw(raw);
      } else {
        continue; // a method nothing here supports; skip rather than fail
      }

      // Just the file name, so a bank does not show directory paths.
      var short = name.replace(/^.*[\\/]/, "").replace(/\.sy1$/i, "");
      out.push({ name: short, bytes: content });
    }
    return out;
  }

  window.SynthSy1 = {
    parse: parse,
    readZip: readZip,
    BIPOLAR_VERSION: BIPOLAR_VERSION,
  };
})();
