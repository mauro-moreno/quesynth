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

  var open = null; // { root, previousFocus, onClose }

  function focusables(root) {
    return [].slice.call(root.querySelectorAll(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    )).filter(function (el) { return !el.disabled && el.offsetParent !== null; });
  }

  // Tab must not walk out of the dialog and into the panel behind it, which is
  // still in the document and still focusable.
  function trap(e) {
    if (!open || e.key !== "Tab") return;
    var list = focusables(open.root);
    if (!list.length) return;
    var first = list[0], last = list[list.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  function onKey(e) {
    if (!open) return;
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
  // Returns the dialog's root, so a caller that wants to rebuild its own body
  // in place can hold on to it.
  function show(title, body, actions) {
    close();

    var back = document.createElement("div");
    back.className = "modal-back";

    var root = document.createElement("div");
    root.className = "modal";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-modal", "true");
    root.setAttribute("aria-label", title);

    var head = document.createElement("div");
    head.className = "modal-head";
    var h = document.createElement("div");
    h.className = "modal-title";
    h.textContent = title;
    var x = document.createElement("button");
    x.type = "button";
    x.className = "modal-close";
    x.setAttribute("aria-label", "Close");
    x.textContent = "×";
    x.addEventListener("click", close);
    head.appendChild(h);
    head.appendChild(x);

    var content = document.createElement("div");
    content.className = "modal-body";
    if (body) content.appendChild(body);

    root.appendChild(head);
    root.appendChild(content);

    if (actions && actions.length) {
      var foot = document.createElement("div");
      foot.className = "modal-foot";
      actions.forEach(function (a) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "modal-action" + (a.primary ? " primary" : "");
        b.textContent = a.label;
        b.addEventListener("click", function () { a.onClick(close); });
        foot.appendChild(b);
      });
      root.appendChild(foot);
    }

    back.appendChild(root);
    // A click on the backdrop closes; one inside the dialog must not, or every
    // click on a patch in the list would shut the thing being clicked in.
    back.addEventListener("click", function (e) {
      if (e.target === back) close();
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
    document.addEventListener("keydown", onKey);

    open = { back: back, root: root, previousFocus: document.activeElement };

    var first = focusables(root)[0];
    if (first) first.focus();

    return root;
  }

  function close() {
    if (!open) return;
    var it = open;
    open = null;
    document.removeEventListener("keydown", onKey);
    document.body.classList.remove("modal-open");
    if (it.back.parentNode) it.back.parentNode.removeChild(it.back);
    // Back where it came from, so closing the browser returns the caret to the
    // strip rather than to the top of the document.
    if (it.previousFocus && it.previousFocus.focus) {
      try { it.previousFocus.focus(); } catch (e) { /* gone from the DOM */ }
    }
  }

  window.SynthModal = {
    show: show,
    close: close,
    isOpen: function () { return !!open; },
  };
})();
