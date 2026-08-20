// Remembering, in the browser and nowhere else.
//
// This file is not copied into the plugin bundle. See tools/build-vst3.ps1,
// which copies a named list and leaves this out for the same reason it leaves
// out host.js: in a plugin the *host* owns persistence. VST3 and CLAP both save
// the current sound into the project through getState/setState, and a panel
// that also wrote to its web view's local storage would be a second copy of the
// same thing, restored in an order neither side controls. index.html asks for
// this file behind an onerror guard, so a build without it simply does not
// remember -- which is correct, because something else is remembering for it.
//
// What is kept, and what is not:
//
//   the current sound   always. It is what you were in the middle of, and
//                       losing it to a page reload is the one thing that
//                       actually costs work.
//   the factory bank    yes. It is the bank that ships with the page, so it is
//                       the one somebody experimenting will write into.
//   everything else     no. Banks opened from a file are on disk already, and
//                       a browser is a demo of the instrument rather than the
//                       place a library should live.

(function () {
  "use strict";

  var KEY = "quesynth.state.v1";

  // Long enough that dragging a knob writes once at the end of the gesture
  // rather than sixty times through it, short enough that a reload a moment
  // after a change still has the change.
  var SETTLE_MS = 400;

  var timer = null;
  var read = null;   // what was there at startup, parsed once
  var loaded = false;

  function available() {
    try {
      // Private browsing refuses the write rather than the property, so this
      // has to be a real round trip and not a typeof check.
      window.localStorage.setItem(KEY + ".probe", "1");
      window.localStorage.removeItem(KEY + ".probe");
      return true;
    } catch (e) {
      return false;
    }
  }

  var usable = available();

  function stored() {
    if (loaded) return read;
    loaded = true;
    if (!usable) return (read = null);
    try {
      var text = window.localStorage.getItem(KEY);
      read = text ? JSON.parse(text) : null;
    } catch (e) {
      // Corrupt or from a version that wrote something else. Dropped rather
      // than repaired: it is a convenience, and refusing to start because of
      // it would be worse than forgetting.
      read = null;
    }
    return read;
  }

  function write(state) {
    if (!usable) return;
    try {
      window.localStorage.setItem(KEY, JSON.stringify(state));
    } catch (e) {
      // Out of quota, most likely. Nothing to do and nothing worth saying: the
      // instrument works, it just will not remember.
    }
  }

  // Everything worth keeping, gathered at the moment of writing rather than
  // tracked as it changes -- there is one writer and it is cheap.
  function snapshot() {
    var patch = window.SynthPatch, banks = window.SynthBank;
    if (!patch || !banks) return null;
    return {
      v: 1,
      current: { name: patch.name(), values: patch.values(), slot: banks.index() },
      // Only the factory bank, which is the first one and the one that came
      // with the page. Trailing empty slots are dropped; loading pads back.
      factory: banks.snapshot(0),
      // The controller assignments. Not the patch's -- see ui/midimap.js on
      // why those are two different things.
      midi: window.SynthMidiMap ? window.SynthMidiMap.snapshot() : null,
    };
  }

  function save() {
    var state = snapshot();
    if (state) write(state);
  }

  window.SynthStore = {
    // What was remembered, for app.js to apply while it is starting up.
    restore: function () { return stored(); },

    // Something changed. Coalesced, because this is called from the parameter
    // path and that fires on every step of a drag.
    touch: function () {
      if (!usable) return;
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () { timer = null; save(); }, SETTLE_MS);
    },

    // Something changed that should not wait, such as a patch being written
    // into a slot.
    flush: function () {
      if (timer) { clearTimeout(timer); timer = null; }
      save();
    },

    forget: function () {
      if (!usable) return;
      try { window.localStorage.removeItem(KEY); } catch (e) {}
      read = null;
      loaded = false;
    },
  };

  // A reload is not the only way a page goes away. On a phone the tab is far
  // more likely to be dropped in the background than closed, and pagehide is
  // the event that survives that; visibilitychange covers being switched away
  // from without leaving.
  window.addEventListener("pagehide", function () { window.SynthStore.flush(); });
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") window.SynthStore.flush();
  });
})();
