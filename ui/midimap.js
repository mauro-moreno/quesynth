// Which controller moves what.
//
// There is a standard for most of this, and where there is one it is followed
// rather than invented.
//
// The two that matter most are not bindings at all, they are the MIDI
// specification, and they are handled in ui/midi.js:
//
//   Program Change      selects a patch, 0..127. This is why a bank holds a
//                       hundred and twenty-eight slots and why an empty slot
//                       is still a slot: program 47 has to mean something.
//   CC 0 and CC 32      Bank Select, coarse and fine. The defined sequence is
//                       CC 0, then CC 32, then a Program Change, and the bank
//                       is MSB * 128 + LSB.
//
// Then the Sound Controllers, from the MIDI 1.0 controller assignments. These
// are the numbers a hardware controller's knobs send when it is set to send
// "filter" and "envelope", so honouring them means a keyboard works on being
// plugged in rather than after being taught:
//
//   CC 71   Sound Controller 2, "Timbre / Harmonic Content"  -> resonance
//   CC 72   Sound Controller 3, "Release Time"               -> amp release
//   CC 73   Sound Controller 4, "Attack Time"                -> amp attack
//   CC 74   Sound Controller 5, "Brightness"                 -> filter cutoff
//   CC 75   Sound Controller 6, "Decay Time"                 -> amp decay
//   CC 93   Effects 3 Depth, chorus                          -> chorus level
//   CC 10   Pan                                              -> pan
//
// Three more are spoken for and are not offered here, because something else
// already answers them: CC 1 is the modulation wheel, which the engine's own
// controller assignment routes and the on-screen wheel shows; CC 7 is Channel
// Volume and drives the master fader; and pitch bend is not a controller.
//
// Everything else is free, and every one of these can be changed.
//
// A binding here drives the parameter directly, the way turning the knob does.
// It is deliberately *not* the engine's own controller assignment -- parameters
// 86 to 89 -- because those are patch data, saved and loaded with the sound. A
// controller is part of the desk, not part of the patch: it should not change
// when the patch does.

(function () {
  "use strict";

  // cc -> parameter index. Named here rather than by number so a reader can
  // check them against the list above.
  var STANDARD_BY_NAME = {
    71: "*filter resonance",
    72: "amp release",
    73: "amp attack",
    74: "*filter freq",
    75: "amp decay",
    93: "chorus level",
    10: "pan",
  };

  // Taken by something else, and so not assignable. Shown in the dialog so it
  // is clear they are handled rather than missing.
  var RESERVED = {
    0: "Bank Select (coarse)",
    32: "Bank Select (fine)",
    1: "Modulation wheel",
    7: "Master volume",
  };

  function params() { return window.SYNTH1_PARAMS || []; }

  function indexOf(name) {
    var list = params();
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i].i;
    return -1;
  }

  function standard() {
    var out = {};
    for (var cc in STANDARD_BY_NAME) {
      if (!Object.prototype.hasOwnProperty.call(STANDARD_BY_NAME, cc)) continue;
      var at = indexOf(STANDARD_BY_NAME[cc]);
      if (at >= 0) out[cc] = at;
    }
    return out;
  }

  var map = null;      // cc -> parameter index
  var pending = null;  // a learn in progress: { fn }

  function current() {
    if (!map) map = standard();
    return map;
  }

  window.SynthMidiMap = {
    RESERVED: RESERVED,

    reserved: function (cc) {
      return Object.prototype.hasOwnProperty.call(RESERVED, cc) ? RESERVED[cc] : null;
    },

    all: function () {
      var out = {}, m = current();
      for (var cc in m) if (Object.prototype.hasOwnProperty.call(m, cc)) out[cc] = m[cc];
      return out;
    },

    // What this controller is bound to, or -1.
    target: function (cc) {
      var m = current();
      return Object.prototype.hasOwnProperty.call(m, cc) ? m[cc] : -1;
    },

    // Bind, or unbind with a parameter index below zero. A controller can only
    // drive one thing: binding it a second time moves it rather than adding.
    bind: function (cc, index) {
      var m = current();
      if (index == null || index < 0) delete m[cc];
      else m[cc] = index;
      if (window.SynthStore) window.SynthStore.flush();
    },

    // Everything back to the specification's own assignments.
    reset: function () {
      map = standard();
      if (window.SynthStore) window.SynthStore.flush();
    },

    // For whatever is remembering this between sessions.
    snapshot: function () { return this.all(); },
    restore: function (saved) {
      if (!saved || typeof saved !== "object") return;
      map = {};
      for (var cc in saved) {
        if (!Object.prototype.hasOwnProperty.call(saved, cc)) continue;
        var n = Number(saved[cc]);
        if (isFinite(n) && n >= 0) map[cc] = n;
      }
    },

    // Wait for the next controller to move, and hand it over. Only one learn
    // can be waiting; asking again replaces the first, so a dialog that offers
    // a Learn button per row cannot end up with several armed at once.
    learn: function (fn) { pending = fn ? { fn: fn } : null; },
    learning: function () { return !!pending; },

    // Called by ui/midi.js for every controller message. Returns true when the
    // message was taken by a learn and should not also move anything.
    saw: function (cc) {
      if (!pending) return false;
      var fn = pending.fn;
      pending = null;
      fn(cc);
      return true;
    },
  };
})();
