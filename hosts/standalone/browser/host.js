// Native-daemon transport for the shared HTML panel, served as /ui/host.js by
// serve.js beside it. It defines window.synthPost, which ui/bridge.js finds
// as the "generic" host, and carries the panel's messages over one WebSocket.
//
// The daemon is the authority and the page only a view, which decides what
// happens across a lost connection: every (re)connection starts with a
// `sync`, so the page is repainted from the daemon, and anything the page
// sends while disconnected is dropped rather than replayed later. A replayed
// edit could land after something newer from another client -- the TUI
// reconnects the same way, to a fresh snapshot and never to a replay.
(function () {
  "use strict";

  // The daemon reads the MIDI devices itself, so Web MIDI in the page would
  // be a second source: a keyboard both could see would play every note
  // twice. Claimed here, before ui/midi.js runs, which then never opens Web
  // MIDI and shows the daemon's selection instead (midi, midi-select and
  // midi-list in ui/bridge.js).
  window.SynthHostMidi = true;

  var MIN_DELAY = 250;
  var MAX_DELAY = 5000;
  // Only what the page posts while it is still loading, before the socket has
  // ever opened: the startup volume and the panel's own sync. Bounded so a
  // page that never connects does not grow it without end.
  var QUEUE_LIMIT = 256;
  var SYNC = '{"type":"sync"}';

  var socket = null;
  var everOpened = false;
  var delay = MIN_DELAY;
  var timer = null;
  var stopped = false;
  var queue = [];

  function markDown() {
    document.documentElement.dataset.hostError = "daemon";
  }

  function isSync(text) {
    try {
      var msg = JSON.parse(text);
      return !!msg && msg.type === "sync";
    } catch (e) {
      return false;
    }
  }

  function connect() {
    timer = null;
    if (stopped) return;
    var ws;
    try {
      ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/control");
    } catch (e) {
      markDown();
      retry();
      return;
    }
    socket = ws;
    var delivered = false;

    ws.addEventListener("open", function () {
      if (socket !== ws) return;
      delete document.documentElement.dataset.hostError;
      ws.send(SYNC);
      if (!everOpened) {
        everOpened = true;
        // The panel queued its own sync while loading; the one above stands
        // for it, and a second would send the bank twice.
        for (var i = 0; i < queue.length; i++) {
          if (!isSync(queue[i])) ws.send(queue[i]);
        }
      }
      queue = [];
    });

    ws.addEventListener("message", function (event) {
      if (socket !== ws || typeof event.data !== "string") return;
      if (event.data.indexOf('{"type":"error"') === 0) {
        var report = null;
        try { report = JSON.parse(event.data); } catch (e) { report = null; }
        if (report) console.warn("quesynth daemon:", report["for"] || "", report.code, report.message);
      } else if (!delivered) {
        // Backoff is only reset by a connection that actually delivered
        // something; one the adapter accepts and immediately drops would
        // otherwise retry four times a second forever.
        delivered = true;
        delay = MIN_DELAY;
      }
      if (window.synthReceive) window.synthReceive(event.data);
    });

    ws.addEventListener("error", function () {
      if (socket === ws) markDown();
    });

    ws.addEventListener("close", function () {
      if (socket !== ws) return;
      socket = null;
      markDown();
      retry();
    });
  }

  function retry() {
    if (stopped || timer !== null) return;
    timer = setTimeout(connect, delay);
    delay = Math.min(delay * 2, MAX_DELAY);
  }

  window.synthPost = function (text) {
    if (socket && socket.readyState === 1) {
      socket.send(String(text));
    } else if (!everOpened) {
      queue.push(String(text));
      if (queue.length > QUEUE_LIMIT) queue.shift();
    }
  };

  window.addEventListener("pagehide", function () {
    stopped = true;
    if (timer !== null) clearTimeout(timer);
    timer = null;
    var ws = socket;
    socket = null;
    if (ws) ws.close();
  });

  // Back from the back-forward cache: the old socket was closed on the way
  // in, so start again, with a sync like any other reconnection.
  window.addEventListener("pageshow", function (event) {
    if (!event.persisted || !stopped) return;
    stopped = false;
    delay = MIN_DELAY;
    connect();
  });

  connect();
})();
