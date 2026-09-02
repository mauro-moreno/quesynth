// The in-browser host: starts the engine and answers the panel as a host would.
//
// This is the page-side half of the WebAssembly build, and it is a host in the
// same sense hosts/vst3 is one -- it owns an engine and speaks the protocol in
// ui/bridge.js. index.html loads it as `host.js` with an onerror guard, so the
// panel names no host at all: a native build simply does not ship this file and
// provides the bridge from the other side.
//
// `bridge.js` looks for a native host and finds none in a browser, so it falls
// back to standalone and the panel drives nothing. This registers itself as
// `window.synthPost` before that check runs, which makes the browser a host like
// any other -- the panel does not know the difference, and neither does anything
// else in `app.js`.
//
// Audio cannot start until the page has been touched. Every browser requires a
// gesture before an AudioContext will run, so the engine is booted on the first
// interaction rather than on load, and the button in the strip says so until then.

(function () {
  "use strict";

  // A native host owns the audio, so this file must stand down.
  //
  // In the plugin and in the desktop shell the engine is native and already
  // running; booting the WebAssembly one on top of it would mean two engines,
  // two voices per key, and the one you hear not being the one the host saves.
  //
  // The test is the same one bridge.js makes, in the same order, because it is
  // the same question -- is something already hosting us. Two different answers
  // to it would be a silent double engine. The one case not tested for is the
  // generic `window.synthPost` hook, which is what this file installs below:
  // finding it here would only ever be finding ourselves.
  function nativeHost() {
    return !!((window.chrome && window.chrome.webview &&
               typeof window.chrome.webview.postMessage === "function") ||
              (window.webkit && window.webkit.messageHandlers &&
               window.webkit.messageHandlers.synth) ||
              (window.SynthHost && typeof window.SynthHost.postMessage === "function"));
  }

  if (nativeHost()) {
    return;
  }

  // How many instruments the page wants. The synth panel says nothing and gets
  // one; the pad sets this before loading and gets sixteen.
  function slotCount() {
    var n = window.QUESYNTH_SLOTS | 0;
    return n > 0 ? n : 1;
  }

  var node = null;      // the AudioWorkletNode, once running
  var ctx = null;
  // Master volume, which is deliberately *not* an engine parameter.
  // The reference's own `vol` knob sits beside the patch name rather than in
  // the panel, and nothing in the .sy1 format carries it, so scaling here
  // leaves every measured mapping in the engine untouched.
  var masterGain = null;
  var pendingVolume = 0.8;
  var starting = false;
  var queue = [];       // messages that arrived before the engine existed
  var listeners = [];

  function post(json) {
    var msg;
    try { msg = JSON.parse(json); } catch (e) { return; }

    // Translate the panel's vocabulary into the worklet's. They are close but not
    // the same: the panel talks about wheels and gestures, the engine about
    // controllers and numbers.
    var out = null;
    switch (msg.type) {
      case "set":
        out = { type: "set", index: msg.index, value: msg.value };
        break;
      case "note":
        out = { type: "note", on: msg.on, note: msg.note, velocity: msg.velocity };
        break;
      case "trigger":
        // A rack one-shot: the engine runs attack and decay, then releases
        // itself without waiting for a hardware Note Off.
        out = { type: "trigger", note: msg.note, velocity: msg.velocity };
        break;
      case "mix":
        // Rack mixer state is deliberately outside the Synth1 patch.
        out = { type: "mix", volume: msg.volume, pan: msg.pan };
        break;
      case "panic":
        out = { type: "panic" };
        break;
      case "wheel":
        if (msg.which === "pitch") {
          out = { type: "bend", value: msg.value };
        } else {
          // The modulation wheel is controller 1, which is what parameters 86 and
          // 88 name by default and what every factory patch expects.
          out = { type: "cc", cc: 1, value: Math.round(msg.value * 127) };
        }
        break;
      case "state":
        // A whole patch. Sent as one message so the engine does not rebind
        // ninety-nine times on the way to one sound.
        out = { type: "state", values: msg.values };
        break;
      case "cc":
        // Straight from a MIDI controller. What it moves, if anything, is what
        // parameters 86..89 were set to.
        out = { type: "cc", cc: msg.cc, value: msg.value };
        break;
      case "sync":
        // Nothing to answer with. The engine holds no state the panel did not
        // send it, and the browser build's patches come from the bank compiled
        // into the page rather than from here.
        //
        // This used to reply with a placeholder patch to keep the handshake
        // symmetric, which was worse than saying nothing: the reply arrived after
        // the bank had already loaded its first patch and overwrote the name with
        // "Init". A host that has patches answers; this one does not have any.
        return;
      case "edit":
      case "patch-step":
        // Gesture boundaries have no meaning without a host recording automation,
        // and there are no banks to step through in the browser build yet.
        return;
    }
    if (!out) return;
    // Which instrument it is for, carried straight through. The panel does not
    // set this and gets slot zero; the pad tags every message with its cell.
    if (typeof msg.slot === "number") out.slot = msg.slot;

    if (node) {
      node.port.postMessage(out);
    } else {
      queue.push(out);
      start();
    }
  }

  function deliver(msg) {
    var text = JSON.stringify(msg);
    listeners.forEach(function (fn) { fn(text); });
    if (window.synthReceive) window.synthReceive(text);
  }

  // Why there is no sound, said on the page.
  //
  // Everything that can stop the engine -- a context that will not leave
  // "suspended", a worklet that will not load, a wasm module that will not
  // compile -- used to go to the console and nowhere else, and the comment at
  // the top of this file claimed a button in the strip said so, which had not
  // been true for some time. On a phone there is no console to look in, so a
  // failure and a patch that happens to be silent look exactly alike.
  //
  // It is a button rather than a label because on iOS the reliable way to get
  // audio started is a click on something the person meant to click: that
  // carries the user activation a stray touch may not.
  var notice = null;
  function say(text) {
    if (!notice) {
      notice = document.createElement("button");
      notice.type = "button";
      notice.style.cssText = [
        "position:fixed", "left:50%", "bottom:16px", "transform:translateX(-50%)",
        "z-index:9999", "padding:10px 18px", "border-radius:999px",
        "border:1px solid rgba(255,255,255,0.25)", "background:rgba(20,20,22,0.92)",
        "color:#eee", "font:inherit", "font-size:14px", "cursor:pointer",
        "max-width:90vw", "text-align:center",
      ].join(";");
      notice.addEventListener("click", wake);
      document.body.appendChild(notice);
    }
    notice.textContent = text;
    notice.hidden = false;
  }
  function quiet() {
    if (notice) notice.hidden = true;
  }

  // Only complain once a gesture has been spent and the context still is not
  // running, so a page nobody has touched yet does not nag.
  function checkRunning() {
    if (!ctx) return;
    if (ctx.state === "running") { quiet(); return; }
    say("Tap to start audio");
  }

  // Boot the engine. Safe to call repeatedly; only the first one does anything.
  function start() {
    if (ctx || starting) return;
    starting = true;

    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) {
      console.error("engine: this browser has no AudioContext");
      return;
    }
    // On iOS a page's audio defaults to the "ambient" session, which the
    // hardware ringer switch silences -- so a phone with the switch flipped
    // plays nothing at all and gives no clue why. Declaring the session as
    // playback is the sanctioned fix; it is Safari 16.4 and later, and absent
    // everywhere else, so it is asked for and not required.
    if (navigator.audioSession) {
      try { navigator.audioSession.type = "playback"; } catch (e) {}
    }

    ctx = new Ctx({ latencyHint: "interactive" });
    ctx.onstatechange = checkRunning;

    Promise.all([
      ctx.audioWorklet.addModule("worklet.js"),
      fetch("synth.wasm").then(function (r) {
        if (!r.ok) throw new Error("synth.wasm " + r.status);
        return r.arrayBuffer();
      }),
    ]).then(function (results) {
      var bytes = results[1];
      node = new AudioWorkletNode(ctx, "synth-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
        processorOptions: { wasm: bytes, blockSize: 128, slots: slotCount() },
      });

      // The engine used to report its sample rate into the strip. Nothing shows
      // it now, so `ready` is no longer worth listening for -- but a failure
      // still has to go somewhere, or the panel goes on working perfectly over
      // an engine that never started.
      node.port.onmessage = function (e) {
        if (e.data && e.data.type === "error") {
          console.error("engine:", e.data.message);
          say("The audio engine failed to start");
        }
      };

      masterGain = ctx.createGain();
      masterGain.gain.value = pendingVolume;
      node.connect(masterGain);
      masterGain.connect(ctx.destination);
      queue.forEach(function (m) { node.port.postMessage(m); });
      queue.length = 0;

      // Resume after the gesture that got us here.
      if (ctx.state === "suspended") ctx.resume();
    }).catch(function (err) {
      console.error("engine:", err);
      starting = false;
      // Distinguished, because they are different problems for whoever is
      // reading it: one is a browser too old for the API this build needs, the
      // other is a file that did not arrive.
      say(ctx && !ctx.audioWorklet
        ? "This browser cannot run the audio engine"
        : "The audio engine could not load");
    });
  }

  // Registered before bridge.js runs, so the browser is found as a host.
  window.synthPost = post;

  // What the audio is doing, for anything that needs to ask.
  //
  // Nothing could, which is why the silence on iOS took as long to pin down as
  // it did: from outside this file an engine that never left "suspended" and
  // one playing a patch that happens to be quiet are the same observation.
  // "idle" means no gesture has started it yet, which is not a fault.
  window.SynthAudioState = function () {
    if (!ctx) return starting ? "starting" : "idle";
    return ctx.state;
  };

  // Set before the engine exists too: the value is held and applied on boot,
  // so moving the control while the page is still silent is not lost.
  window.SynthVolume = function (v) {
    var g = Math.max(0, Math.min(1, v));
    pendingVolume = g;
    if (masterGain && ctx) {
      // A short ramp rather than a jump: a step in gain is a click.
      masterGain.gain.setTargetAtTime(g, ctx.currentTime, 0.01);
    }
  };

  // The first gesture anywhere starts the engine, since audio needs one and the
  // first thing anyone does here is press a key or turn a knob.
  //
  // Listening on more than pointerdown is not belt and braces. WebKit grants
  // the user activation that lets an AudioContext leave "suspended" only on
  // touchend, click and keydown -- touchstart, and so the pointerdown that
  // WebKit derives from it, is not on that list. Every gesture on iOS is a
  // pointerdown that never becomes activation, so resume() was called on every
  // touch, refused every time, and the page stayed silent while behaving
  // perfectly in every other respect.
  //
  // pointerdown stays, and first, because everywhere else it is the earliest
  // moment the engine can start and that is latency the player feels.
  function wake() {
    start();
    if (ctx && ctx.state === "suspended") {
      // The promise rejects when there was no activation to spend, which is
      // the iOS case above. Swallowed rather than logged: it is the expected
      // answer on the events that do not carry activation, and the next
      // listener below is what succeeds.
      var resumed = ctx.resume();
      if (resumed && resumed.catch) resumed.catch(function () {});
    }
    setTimeout(checkRunning, 400);
  }
  ["pointerdown", "touchend", "click", "keydown"].forEach(function (name) {
    document.addEventListener(name, wake, { once: false, passive: true });
  });
})();
