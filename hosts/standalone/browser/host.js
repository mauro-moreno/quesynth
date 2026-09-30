// Native-daemon transport for the shared HTML panel.
(function () {
  "use strict";
  var socket = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/control");
  var queue = [];
  window.synthPost = function (text) {
    if (socket.readyState === WebSocket.OPEN) socket.send(text);
    else queue.push(text);
  };
  socket.addEventListener("open", function () {
    while (queue.length) socket.send(queue.shift());
  });
  socket.addEventListener("message", function (event) {
    if (window.synthReceive) window.synthReceive(event.data);
  });
  socket.addEventListener("error", function () {
    document.documentElement.dataset.hostError = "daemon";
  });
})();
