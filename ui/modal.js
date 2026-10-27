// A modal dialog, and nothing about what goes in one.
//
// There are two of these coming -- the bank browser and the general options --
// and they share every part except their contents: the backdrop, the escape
// key, where focus goes and where it comes back to, and not letting the page
// behind scroll while one is open. Written once here so the second one is a
// body and a title rather than a second dialog.
//
// Deliberately not <dialog>. Its `showModal` gives the backdrop and the escape
// key for free, but the plugin runs this page inside a WebView2 window with the
// panel already at a fixed size, and a top-layer element there escapes the
// panel's own stacking and paints over the host's frame. A plain fixed overlay
// stays inside the page, which is what a plugin editor needs.

(function () {
  "use strict";

  // Open dialogs, the one in front last. A confirmation or an error raised from
  // inside the browser stacks on it instead of replacing it: asking "overwrite
  // slot 42?" by closing the browser would throw away the destination the
  // person had just chosen, and answering would leave them with nothing open.
  // Only the front one hears the keyboard or is in the Tab order.
  var stack = [];

  function front() { return stack.length ? stack[stack.length - 1] : null; }

  function focusables(root) {
    return [].slice.call(root.querySelectorAll(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    )).filter(function (el) { return !el.disabled && el.offsetParent !== null; });
  }

  // Tab must not walk out of the dialog and into the panel behind it, which is
  // still in the document and still focusable.
  function trap(e) {
    var it = front();
    if (!it || e.key !== "Tab") return;
    var list = focusables(it.root);
    if (!list.length) return;
    var first = list[0], last = list[list.length - 1];
    var inside = it.root.contains ? it.root.contains(document.activeElement) : true;
    if (e.shiftKey && (document.activeElement === first || !inside)) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && (document.activeElement === last || !inside)) {
      e.preventDefault();
      first.focus();
    }
  }

  function onKey(e) {
    if (!front()) return;
    if (e.key === "Escape") {
      e.preventDefault();
      close();
      return;
    }
    trap(e);
  }

  // Show a dialog. `title` names it, `body` is an element to put inside, and
  // `actions` is an optional array of { label, onClick, primary } for the foot.
  //
  // `options` are all optional: `stacked` puts it in front of what is open
  // instead of replacing it, `focus` is the index of the action that takes
  // focus when it opens (the first control otherwise), `role` is "alertdialog"
  // for one that interrupts, `describedBy` the id of the element that says what
  // it is about, and `onClose` runs once it is gone, however it went.
  //
  // Returns the dialog's root, so a caller that wants to rebuild its own body
  // in place can hold on to it.
  function show(title, body, actions, options) {
    options = options || {};
    if (!options.stacked) while (front()) close();

    var back = document.createElement("div");
    back.className = "modal-back";

    var root = document.createElement("div");
    root.className = "modal" + (options.className ? " " + options.className : "");
    root.setAttribute("role", options.role || "dialog");
    root.setAttribute("aria-modal", "true");
    root.setAttribute("aria-label", title);
    if (options.describedBy) root.setAttribute("aria-describedby", options.describedBy);

    var head = document.createElement("div");
    head.className = "modal-head";
    var h = document.createElement("div");
    h.className = "modal-title";
    h.textContent = title;
    var x = document.createElement("button");
    x.type = "button";
    x.className = "modal-close";
    x.setAttribute("aria-label", "Close");
    if (window.QuesynthIcon) x.appendChild(window.QuesynthIcon("close"));
    x.appendChild(document.createTextNode("CLOSE"));
    x.addEventListener("click", close);
    head.appendChild(h);
    head.appendChild(x);

    var content = document.createElement("div");
    content.className = "modal-body";
    if (body) content.appendChild(body);

    root.appendChild(head);
    root.appendChild(content);

    var buttons = [];
    if (actions && actions.length) {
      var foot = document.createElement("div");
      foot.className = "modal-foot";
      actions.forEach(function (a) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "modal-action" + (a.primary ? " primary" : "");
        b.textContent = a.label;
        // The button is handed over too, so an action can report back on it
        // -- keeping a bank writes a file nobody can see happen.
        b.addEventListener("click", function () { a.onClick(close, b); });
        foot.appendChild(b);
        buttons.push(b);
      });
      root.appendChild(foot);
    }

    back.appendChild(root);
    // A click on the backdrop closes; one inside the dialog must not, or every
    // click on a patch in the list would shut the thing being clicked in.
    back.addEventListener("click", function (e) {
      if (e.target === back && front() && front().back === back) close();
    });

    document.body.appendChild(back);
    document.body.classList.add("modal-open");
    // Bubble, not capture.
    //
    // On capture this runs before anything inside the dialog can see the key,
    // so a field that wants to handle Escape itself -- the bank search clears
    // rather than closing -- cannot: its stopPropagation comes too late,
    // because the document already had the event. Bubbling gives the contents
    // first refusal, which is the order a dialog should have.
    if (!stack.length) document.addEventListener("keydown", onKey);

    stack.push({
      back: back, root: root, previousFocus: document.activeElement,
      onClose: options.onClose,
    });

    var first = options.focus !== undefined && buttons[options.focus]
      ? buttons[options.focus] : focusables(root)[0];
    if (first) first.focus();

    return root;
  }

  // Close the dialog in front.
  function close() {
    var it = stack.pop();
    if (!it) return;
    if (!stack.length) {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("modal-open");
    }
    if (it.back.parentNode) it.back.parentNode.removeChild(it.back);
    // Back where it came from, so closing the browser returns the caret to the
    // strip rather than to the top of the document.
    if (it.previousFocus && it.previousFocus.focus) {
      try { it.previousFocus.focus(); } catch (e) { /* gone from the DOM */ }
    }
    if (it.onClose) it.onClose();
  }

  var serial = 0;

  // A body of paragraphs: `message` is one string or a list of them.
  function paragraphs(message) {
    var body = document.createElement("div");
    body.className = "modal-message";
    body.id = "modal-message-" + (++serial);
    [].concat(message || []).forEach(function (line) {
      var p = document.createElement("p");
      p.textContent = line;
      body.appendChild(p);
    });
    return body;
  }

  // Ask before something that cannot be taken back.
  //
  // `{ title, message, confirmLabel, cancelLabel, focus }`; resolves true only
  // for the confirm button. Escape, the close mark, the backdrop and Cancel all
  // resolve false, so that dismissing the dialog is always the safe answer.
  // Focus starts on Cancel unless `focus` is "confirm": the person asked to
  // overwrite a sound should have to reach for it, and Enter on an unread
  // dialog must not be the thing that overwrites it.
  function ask(options) {
    return new Promise(function (resolve) {
      var settled = false;
      function settle(answer) {
        if (settled) return;
        settled = true;
        resolve(answer);
      }
      var body = paragraphs(options.message);
      show(options.title || "Are you sure?", body, [
        { label: options.cancelLabel || "Cancel", onClick: function (closeIt) { closeIt(); } },
        { label: options.confirmLabel || "OK", primary: true,
          onClick: function (closeIt) { settle(true); closeIt(); } },
      ], {
        stacked: true,
        focus: options.focus === "confirm" ? 1 : 0,
        role: "alertdialog",
        describedBy: body.id,
        className: "modal-confirm",
        onClose: function () { settle(false); },
      });
    });
  }

  // Say that something did not work, or what happened, and wait to be read.
  // Resolves when it is closed. For results that must not be missed; the
  // status line in the strip is for the ones that may be.
  function tell(options) {
    return new Promise(function (resolve) {
      var body = paragraphs(options.message);
      show(options.title || "Quesynth", body, [
        { label: options.okLabel || "OK", primary: true, onClick: function (closeIt) { closeIt(); } },
      ], {
        stacked: true,
        focus: 0,
        role: "alertdialog",
        describedBy: body.id,
        className: "modal-confirm",
        onClose: resolve,
      });
    });
  }

  window.SynthModal = {
    show: show,
    close: close,
    confirm: ask,
    alert: tell,
    isOpen: function () { return stack.length > 0; },
  };
})();
