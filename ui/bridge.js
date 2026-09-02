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
//
//   to interface  {"type":"state","values":[...]}       all parameters at once
//                 {"type":"param","index":19,"value":80} one changed elsewhere
//                 {"type":"patch","name":"Computer","bank":"soundbank00"}

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

  var transport = detect();
  var handlers = [];

  function deliver(text) {
    var msg;
    try {
      msg = typeof text === "string" ? JSON.parse(text) : text;
    } catch (err) {
      return;
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

    send: function (msg) {
      if (transport) {
        transport.send(msg);
        return true;
      }
      return false;
    },

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
