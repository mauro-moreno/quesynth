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

  var restingLabel = "MIDI";
  var flashTimer = null;

  // Update only the trailing text of the button so the inline icon survives.
  function setButtonText(text) {
    if (!button) return;
    var node = button.lastChild;
    if (node && node.nodeType === 3) node.nodeValue = text;
    else button.appendChild(document.createTextNode(text));
  }

  function label(text) {
    restingLabel = text;
    if (flashTimer === null) setButtonText(text);
  }

  // Show the velocity of the note just played, then go back to the device name.
  //
  // This is a diagnostic, and it earns its place: "velocity does nothing" has
  // two completely different causes and no way to tell them apart by ear. The
  // engine may be ignoring it, or the keyboard may be sending the same number
  // every time -- controllers commonly have a fixed-velocity curve, and it is
  // not always obvious which one is selected. One is a bug here; the other is a
  // setting on the keyboard, and no amount of work in this repository fixes it.
  //
  // Watching this while playing soft and hard answers it in a second.
  function flashVelocity(v) {
    if (!button) return;
    setButtonText("v" + v);
    if (flashTimer !== null) clearTimeout(flashTimer);
    flashTimer = setTimeout(function () {
      flashTimer = null;
      setButtonText(restingLabel);
    }, 600);
  }

  // Route one incoming message. Only the three that matter here; anything else,
  // including clock and active sensing, is ignored rather than mishandled.
  // Bank Select arrives as two controllers and does nothing until a Program
  // Change follows. Kept here because they are a running state of the input,
  // not of any one message.
  var bankMsb = 0, bankLsb = 0, pendingBank = null;

  function onMessage(e) {
    var d = e.data;
    if (!d || d.length < 2) return;
    var status = d[0] & 0xF0;
    var channel = d[0] & 0x0F;
    var bridge = window.SynthBridge;
    if (!bridge) return;

    // The rack needs the channel as well as the note for filtering and learn.
    // Ordinary synth pages keep using the bridge directly.
    function note(on, number, velocity) {
      if (window.QuesynthPad && typeof window.QuesynthPad.routeMidi === "function") {
        return window.QuesynthPad.routeMidi(on, number, velocity, channel);
      }
      return bridge.note(on, number, velocity, channel);
    }

    switch (status) {
      case 0x90:
        // A note on with zero velocity is a note off, and plenty of keyboards
        // only ever send it that way.
        if (d[2] > 0) {
          note(true, d[1], d[2]);
          flashVelocity(d[2]);
          if (window.SynthKeys) window.SynthKeys.down(d[1]);
        } else {
          note(false, d[1], 0);
          if (window.SynthKeys) window.SynthKeys.up(d[1]);
        }
        break;
      case 0x80:
        note(false, d[1], 0);
        if (window.SynthKeys) window.SynthKeys.up(d[1]);
        break;
      case 0xC0:
        // Program Change: the patch number, 0..127.
        //
        // This is the reason a bank is a hundred and twenty-eight slots and
        // the reason an empty slot is still a slot -- program 47 has to select
        // something, and it has to be the same something every time.
        //
        // A Bank Select seen earlier applies here rather than when it arrived,
        // which is what the specification asks for: the pair of controllers
        // sets a pending bank and the next Program Change is what acts on it.
        if (window.SynthBank) {
          if (pendingBank !== null) {
            var wanted = pendingBank;
            pendingBank = null;
            if (wanted >= 0 && wanted < window.SynthBank.list().length) {
              window.SynthBank.select(wanted, false, function () {
                window.SynthBank.load(d[1]);
              });
              break;
            }
          }
          window.SynthBank.load(d[1]);
        }
        break;
      case 0xB0:
        // A controller being learnt takes the message and nothing else does.
        if (window.SynthMidiMap && window.SynthMidiMap.saw(d[1])) break;

        // Bank Select, coarse and fine. Held rather than acted on; see the
        // Program Change above.
        if (d[1] === 0) { bankMsb = d[2]; pendingBank = bankMsb * 128 + bankLsb; break; }
        if (d[1] === 32) { bankLsb = d[2]; pendingBank = bankMsb * 128 + bankLsb; break; }

        // Everything goes to the engine: parameters 86 to 89 can assign any
        // controller to any destination, so nothing may be swallowed here.
        bridge.send({ type: "cc", cc: d[1], value: d[2] });

        // And then whatever the panel has this controller bound to. Separate
        // from the engine's own assignment on purpose: that one is patch data
        // and changes with the sound, this one is the desk and does not.
        if (window.SynthMidiMap && window.SynthPatch) {
          var to = window.SynthMidiMap.target(d[1]);
          if (to >= 0) window.SynthPatch.setParam(to, d[2] / 127);
        }
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
