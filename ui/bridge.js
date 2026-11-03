// Transport between the interface and whatever is hosting it.
//
// The point of putting the interface in a web view is that one panel serves the
// desktop build, the mobile build and the plugin. That only holds if nothing above
// this file knows which of them it is running in, so every host difference is
// absorbed here and `app.js` sees one object.
//
// Four hosts are recognised, and a fifth case matters just as much:
//
//   WebView2          window.chrome.webview          Windows desktop, most DAWs on Windows
//   WKWebView         window.webkit.messageHandlers  macOS and iOS
//   Android WebView   window.SynthHost               a plain injected Java object
//   Generic           window.synthPost               anything that defines one function
//   None              a plain browser, for development
//
// With no host the interface runs standalone against an in-memory copy of the
// parameter defaults. That is not a toy mode -- it is how the panel gets worked on
// without building the engine, and it means opening index.html in a browser is
// always a valid thing to do.
//
// Wire format, JSON both ways. Values are the **stored integers** the .sy1 format
// and `patch.Patch.values` use, not normalised floats, because that is the only
// representation that survives the display-keyed parameters intact. A plugin host
// that speaks normalised automation converts at its own edge, where it already
// knows the parameter's state count.
//
//   to host    {"type":"set","index":19,"value":80}     a control moved
//              {"type":"sync"}                          send me everything
//              {"type":"note","on":true,"note":60,"velocity":100}
//              {"type":"wheel","which":"pitch","value":-0.4}   pitch on -1..1
//              {"type":"wheel","which":"mod","value":0.7}      modulation on 0..1
//              {"type":"volume","value":0.8}             master gain on 0..1
//              {"type":"edit","index":19,"begin":true}  gesture start and end
//              {"type":"midi-select","id":"hw:1,0"}     input id, all or none
//              {"type":"midi-list"}                     list host inputs again
//              {"type":"archive-open","path":"/srv/banks.zip"}  "" or none: reopen
//              {"type":"archive-bank","index":1}        browse an archive bank
//              {"type":"archive-load","bank":1,"index":2}  play one of its patches
//              {"type":"archive-close"}                 close it, forget its path
//
//   to interface  {"type":"state","values":[...]}       all parameters at once
//                 {"type":"param","index":19,"value":80} one changed elsewhere
//                 {"type":"patch","name":"Computer","bank":"soundbank00"}
//                 {"type":"patch","name":"Bass","index":null,"bank":"bankB.zip",
//                  "source":"archive","archive":{"bank":1,"patch":1}}
//                 {"type":"midi","inputs":[{"id":"hw:1,0","name":"..."}],
//                  "selected":"all","name":"All inputs","rev":3}
//                 {"type":"archive","rev":3,"open":true,"path":"/srv/banks.zip",
//                  "banks":["bankA.zip","bankB.zip"],"bank":1,
//                  "patches":["Pad","Bass","Keys"]}
//
// The three MIDI messages are for a host that reads the MIDI devices itself.
// It claims them by setting window.SynthHostMidi = true before midi.js loads,
// as a host in the page claims SynthVolume below. midi.js then never opens Web
// MIDI, which would be a second way in for the same keyboard and sound every
// note twice, and shows only what the last `midi` said: `selected` is "all",
// "none" or an input's id, and null when the host has no selection to offer.
//
// The archive messages are for a host that keeps a zip of banks itself and
// shares it between clients, as the standalone daemon does. Sending one
// `archive` claims it: the page then lists the host's ordinary bank and the
// archive's banks as one list, browses and loads through the four requests
// rather than reading a zip itself, and refuses a zip opened in the page.
// `archive` is the host's whole view: `banks` and `patches` (the open bank's,
// [] when none) by index, `bank` the open bank or null, `path` the one the
// host remembers ("" if none); closed, it is open:false with no banks. Each
// request is answered with a fresh `archive`, after an `error` when refused.
// A `patch` with `source` ("none", "bank", "archive" or "file") says where the
// sound came from: `index` is then only an ordinary slot, and `archive` the
// archive bank and patch, or null. After an `archive`, PREV and NEXT during an
// archive patch send {"type":"patch-step","step":1} for the host to walk its
// bank. A host that never sends `archive` keeps the page's own zip handling,
// and a `patch` without `source` is read as it always was.
//
// Version 1 -- which preset the host is playing, and whether it could be
// restored. Every message below carries "v":1, and the page sends none of the
// ones marked "page" until it has received one host message that carries a "v"
// of its own: a host that never says it is a legacy host, and a legacy host
// (the standalone daemon's adapter, which answers an unknown type with an
// `error`) is never sent anything it did not already understand. Nothing that
// existed is renamed or dropped; v1 only adds fields and messages.
//
//   to interface  {"type":"bank","text":"<quesynth.bank>","v":1,
//                  "origin":"factory|user|imported","readOnly":false,
//                  "kept":true}
//                     `origin`, `readOnly` and `kept` are new on the existing
//                     message. Adopting it never selects a slot, loads a
//                     patch, or answers with a `state`: it is the host saying
//                     what it holds, not a request to change what is playing.
//                     `kept` is whether this is the bank the host keeps -- its
//                     saved bank, or the compiled-in one while it has none --
//                     and so the only one a `bank` with "save":true may be
//                     sent for. It is false for a bank the host only plays: one
//                     the page made and sent, one opened from a file, one the
//                     project embedded. `origin` is only what to call it, and
//                     a bank the person made is the user's too. A message
//                     without `kept` is read as false.
//                 {"type":"patch","name":"Glass Pad","index":42,
//                  "bank":"My Bank","v":1,"origin":"user"}
//                     `index` null and no `name` when the host has nothing to
//                     report; the page then keeps its own sound and name and
//                     calls it the current session's. A `patch` that names a
//                     preset is also the host saying it moved on by itself (a
//                     MIDI Program Change), and the page lets go of a failed
//                     restore it was showing, as it does when a person picks
//                     a preset: the host dropped the identity too. A failure
//                     the host still holds is sent again after its `patch`,
//                     so a `patch` is never the last word on one. A retry the
//                     page is waiting on is left to its own answer, which
//                     carries a `patch` ahead of its `restore`.
//                 {"type":"restore","v":1,"state":"restored",
//                  "origin":"imported","bank":"Alfmeister Bank","slot":42,
//                  "name":"Foo"}
//                 {"type":"restore","v":1,"state":"failed",
//                  "error":"MissingBank","recoverable":true,"message":"...",
//                  "origin":"imported","bank":"Alfmeister Bank","slot":42,
//                  "name":"Foo"}
//                     `error` is MissingBank, InvalidProgram, HostStateRejected
//                     or StateVersionUnsupported. A failed restore touches
//                     neither the sound, the bank nor the program.
//                 {"type":"restore","v":1,"state":"notRequested"}
//                     The host holds nothing to restore. Sent only to answer
//                     a `restore-retry`, never at `sync` (which says nothing
//                     when nothing was asked): the failure being retried is
//                     gone, because the instance moved to another preset
//                     since. It resolves the page's retry, which `restoring`
//                     would otherwise wait on for good.
//                 {"type":"bank-saved","v":1,"ok":true,"bank":"My Bank"}
//                 {"type":"bank-saved","v":1,"ok":false,
//                  "error":"PersistenceFailed","message":"...",
//                  "bank":"My Bank"}
//                     The answer to a `bank` with "save":true; `error` is
//                     PersistenceFailed or InvalidBank.
//                 `sync` is answered in this order: bank, state, patch (if the
//                 host has a selection), restore (if one was requested).
//
//   to host       {"type":"select","v":1,"origin":"user","bank":"My Bank",
//                  "slot":42,"name":"Glass Pad"}                     page
//                     What the panel just selected. `slot` is null for a sound
//                     with no slot behind it (a file, or the current session).
//                 {"type":"restore-retry","v":1}                      page
//                     Re-evaluate the pending, failed restore. Always
//                     answered, so the page is never left waiting: with the
//                     bank if it changed, the `patch` once the restore is
//                     over, and a `restore` -- `restored`, `failed` again, or
//                     `notRequested` when there is nothing to retry.
//                 {"type":"restore-discard","v":1}                    page
//                     The person dismissed the failure: forget the identity.
//                 `bank`, which the page already sent, gains "v":1 and
//                 "origin" once a host has said v. `save` keeps its meaning.

(function () {
  "use strict";

  function detect() {
    if (window.chrome && window.chrome.webview &&
        typeof window.chrome.webview.postMessage === "function") {
      return {
        name: "webview2",
        send: function (msg) { window.chrome.webview.postMessage(JSON.stringify(msg)); },
        listen: function (fn) {
          window.chrome.webview.addEventListener("message", function (e) {
            fn(typeof e.data === "string" ? e.data : JSON.stringify(e.data));
          });
        },
      };
    }
    if (window.webkit && window.webkit.messageHandlers &&
        window.webkit.messageHandlers.synth) {
      return {
        name: "wkwebview",
        send: function (msg) { window.webkit.messageHandlers.synth.postMessage(JSON.stringify(msg)); },
        listen: function () { /* the host calls window.synthReceive directly */ },
      };
    }
    if (window.SynthHost && typeof window.SynthHost.postMessage === "function") {
      return {
        name: "android",
        send: function (msg) { window.SynthHost.postMessage(JSON.stringify(msg)); },
        listen: function () { /* the host calls window.synthReceive directly */ },
      };
    }
    if (typeof window.synthPost === "function") {
      return {
        name: "generic",
        send: function (msg) { window.synthPost(JSON.stringify(msg)); },
        listen: function () { /* the host calls window.synthReceive directly */ },
      };
    }
    return null;
  }

  // The newest protocol this page speaks. See "Version 1" above.
  var PROTOCOL = 1;

  var transport = detect();
  // A host that runs inside the page -- the browser build's engine -- claims
  // `SynthVolume` itself before this file loads (see the bottom of it). It is
  // the one kind of host that holds nothing the page did not send it, so the
  // page has to supply its sound; every other host already has one.
  var inPage = !!transport && typeof window.SynthVolume === "function";
  var handlers = [];
  // The highest version the host has spoken, capped at ours: what both sides
  // understand. Zero until a host message carries a "v".
  var peer = 0;
  var failure = null;

  function deliver(text) {
    var msg;
    try {
      msg = typeof text === "string" ? JSON.parse(text) : text;
    } catch (err) {
      return;
    }
    // Before the handlers run, so the reply a handler sends to this very
    // message can already be a version-1 one.
    if (msg && typeof msg.v === "number" && msg.v >= 1 && msg.v > peer) {
      peer = Math.min(Math.floor(msg.v), PROTOCOL);
    }
    for (var i = 0; i < handlers.length; i++) handlers[i](msg);
  }

  // Every host that cannot push events to us calls this instead. Kept on window
  // deliberately: a native side that can only evaluate a string of JavaScript can
  // still reach the interface through it.
  window.synthReceive = deliver;

  if (transport && transport.listen) transport.listen(deliver);

  window.SynthBridge = {
    // Which host was found, or "standalone". Shown in the header so a build that
    // silently failed to inject its bridge is visible rather than merely inert.
    host: transport ? transport.name : "standalone",
    connected: !!transport,

    // True when the host's engine is in this very page and holds no state the
    // page did not give it. See where it is computed.
    inPage: inPage,

    // A transport that throws -- a host mid-teardown, a web view that has
    // already closed its end -- must not take the page's handler down with it:
    // a refused write is a `false` with the reason kept in `error`, which is
    // how the panel already treats having no host at all.
    send: function (msg) {
      if (!transport) return false;
      try {
        transport.send(msg);
        failure = null;
        return true;
      } catch (err) {
        failure = String(err && err.message ? err.message : err);
        return false;
      }
    },

    // Why the last send failed, or null if it did not. Cleared by the next one
    // that goes through.
    error: function () { return failure; },

    PROTOCOL: PROTOCOL,

    // What the host and this page both understand: 0 until the host has sent a
    // message with a "v", then the lower of its version and PROTOCOL.
    version: function () { return peer; },

    // A message only a version-1 host can read. Refused, and not sent, to a
    // host that has not said it is one, so a legacy host never hears a type it
    // would answer with an error.
    sendV1: function (msg) {
      if (peer < 1) return false;
      var out = { v: PROTOCOL };
      for (var key in msg) if (Object.prototype.hasOwnProperty.call(msg, key)) out[key] = msg[key];
      return this.send(out);
    },

    // What the panel selected, for a host that keeps track of it.
    select: function (origin, bank, slot, name) {
      return this.sendV1({ type: "select", origin: origin, bank: bank, slot: slot, name: name });
    },
    restoreRetry: function () { return this.sendV1({ type: "restore-retry" }); },
    restoreDiscard: function () { return this.sendV1({ type: "restore-discard" }); },

    onMessage: function (fn) { handlers.push(fn); },

    setParam: function (index, value) {
      return this.send({ type: "set", index: index, value: value });
    },

    // Gesture boundaries, so a host that records automation records one move
    // rather than a few hundred samples of one.
    beginEdit: function (index) { this.send({ type: "edit", index: index, begin: true }); },
    endEdit: function (index) { this.send({ type: "edit", index: index, begin: false }); },

    requestState: function () { return this.send({ type: "sync" }); },

    note: function (on, note, velocity, channel) {
      var message = { type: "note", on: on, note: note, velocity: velocity || 100 };
      if (typeof channel === "number") message.channel = channel;
      return this.send(message);
    },

    // The two wheels, as normalised floats rather than as MIDI numbers: pitch on
    // -1..1 and modulation on 0..1. The host converts, because how far a bend of
    // 1.0 actually goes is parameter 40's business and the panel has no reason to
    // know. Sent for the same reason notes are -- these are performance, not
    // parameters, and they must not land in a patch.
    wheel: function (which, value) {
      return this.send({ type: "wheel", which: which, value: value });
    },

    // Master volume, on 0..1. Its own message rather than a parameter: the
    // reference keeps `vol` beside the patch name and nothing in the .sy1 format
    // carries it, so it must not travel as one of the ninety-nine and must not
    // land in a patch.
    volume: function (value) {
      return this.send({ type: "volume", value: value });
    },
  };

  // A host that runs inside the page claims this itself and applies the gain to
  // its own output node, so it is left alone. With a native host there is no
  // node here to turn down and the request has to be forwarded, or the control
  // in the strip moves and nothing happens.
  if (transport && typeof window.SynthVolume !== "function") {
    window.SynthVolume = function (value) {
      window.SynthBridge.volume(Math.max(0, Math.min(1, value)));
    };
  }
})();
