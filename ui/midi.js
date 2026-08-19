// Web MIDI input: play the instrument from a real keyboard.
//
// The interface's own keyboard is fine for checking that a patch sounds, and no
// use at all for finding out whether it *plays*. Velocity, held chords, the
// pitch wheel actually returning to centre and the modulation wheel arriving as
// controller 1 -- which is what parameters 86 and 88 name by default -- are all
// things only a controller exercises.
//
// Everything found here is handed to the same bridge the on-screen keyboard uses,
// so nothing downstream knows or cares which one a note came from.
//
// Access needs a user gesture and a permission prompt, so nothing is requested
// until the button is pressed. A browser without Web MIDI -- Safari, as of
// writing -- says so rather than failing quietly.

(function () {
  "use strict";

  var access = null;
  var current = null;    // the connected input
  var button = null;
  var list = null;

  function label(text) {
    if (button) button.textContent = text;
  }

  // Route one incoming message. Only the three that matter here; anything else,
  // including clock and active sensing, is ignored rather than mishandled.
  function onMessage(e) {
    var d = e.data;
    if (!d || d.length < 2) return;
    var status = d[0] & 0xF0;
    var bridge = window.SynthBridge;
    if (!bridge) return;

    switch (status) {
      case 0x90:
        // A note on with zero velocity is a note off, and plenty of keyboards
        // only ever send it that way.
        if (d[2] > 0) {
          bridge.note(true, d[1], d[2]);
          if (window.SynthKeys) window.SynthKeys.down(d[1]);
        } else {
          bridge.note(false, d[1], 0);
          if (window.SynthKeys) window.SynthKeys.up(d[1]);
        }
        break;
      case 0x80:
        bridge.note(false, d[1], 0);
        if (window.SynthKeys) window.SynthKeys.up(d[1]);
        break;
      case 0xB0:
        // Everything goes to the engine: parameters 86 to 89 can assign any
        // controller to any destination, so nothing may be swallowed here.
        bridge.send({ type: "cc", cc: d[1], value: d[2] });
        // Controller 1 is the modulation wheel, which is what parameters 86
        // and 88 name by default and what the on-screen wheel represents.
        if (d[1] === 1 && window.SynthWheels) {
          window.SynthWheels.set("mod", d[2] / 127);
        }
        // Controller 7 is Channel Volume in the MIDI specification, and it is
        // what the volume fader on a controller keyboard sends. Driving the
        // master volume with it is what a player expects; it is *also* still
        // passed to the engine above, so a patch that has assigned controller
        // 7 to a parameter keeps working.
        if (d[1] === 7) {
          var slider = document.getElementById("master-vol");
          if (slider) {
            slider.value = String(Math.round((d[2] / 127) * 100));
            slider.dispatchEvent(new Event("input"));
          }
        }
        break;
      case 0xE0:
        // 14 bits across two bytes, centred at 8192, delivered on -1..1.
        var raw = (d[2] << 7) | d[1];
        var bend = (raw - 8192) / 8192;
        bridge.wheel("pitch", bend);
        if (window.SynthWheels) window.SynthWheels.set("pitch", bend);
        break;
    }
  }

  function connect(input) {
    if (current) current.onmidimessage = null;
    current = input;
    if (!input) {
      label("MIDI");
      return;
    }
    input.onmidimessage = onMessage;
    label(input.name || "MIDI");
  }

  function showList(anchor) {
    if (!list) {
      list = document.createElement("div");
      list.className = "midi-list";
      document.body.appendChild(list);
      document.addEventListener("click", function () { list.classList.remove("open"); });
      list.addEventListener("click", function (e) { e.stopPropagation(); });
    }

    list.textContent = "";
    var inputs = [];
    access.inputs.forEach(function (i) { inputs.push(i); });

    if (!inputs.length) {
      var none = document.createElement("div");
      none.className = "midi-none";
      none.textContent = "No inputs found";
      list.appendChild(none);
    }

    inputs.forEach(function (input) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = input.name || input.id;
      b.setAttribute("aria-current", current && current.id === input.id ? "true" : "false");
      b.addEventListener("click", function () {
        connect(current && current.id === input.id ? null : input);
        list.classList.remove("open");
      });
      list.appendChild(b);
    });

    list.classList.add("open");
    var r = anchor.getBoundingClientRect();
    var w = list.offsetWidth;
    list.style.left = Math.round(Math.min(r.right - w, window.innerWidth - w - 8)) + "px";
    list.style.top = Math.round(r.bottom + 8) + "px";
  }

  function open(e) {
    e.stopPropagation();
    if (access) {
      showList(button);
      return;
    }
    if (!navigator.requestMIDIAccess) {
      label("no MIDI");
      return;
    }
    label("...");
    navigator.requestMIDIAccess().then(function (a) {
      access = a;
      // A controller plugged in later should appear without a reload.
      access.onstatechange = function () {
        if (list && list.classList.contains("open")) showList(button);
        // If the connected device went away, stop pretending it is there.
        if (current && current.state === "disconnected") connect(null);
      };
      label("MIDI");
      showList(button);
    }).catch(function () {
      label("MIDI denied");
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    button = document.getElementById("midi-toggle");
    if (button) button.addEventListener("click", open);
  });

  // Attaching an input from outside.
  //
  // Web MIDI needs a permission the page cannot grant itself, so the routing
  // above is otherwise unreachable without a device and a human to allow it --
  // which means the one part with real logic in it, the message decoding, could
  // only ever be checked by hand. This lets an input be handed in from anywhere,
  // including a test that feeds it bytes.
  window.SynthMidi = {
    connect: connect,
    handleMessage: onMessage,
    connected: function () { return current ? (current.name || current.id) : null; },
  };
})();
