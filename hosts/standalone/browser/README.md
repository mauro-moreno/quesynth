# Native browser front-end

`quesynth --browser` attaches to (or starts) the standalone daemon, serves the
shared `ui/` files locally, and opens the default browser. Audio and state remain
owned by the daemon; this directory only provides the HTTP/WebSocket adapter.

The adapter requires Node.js and uses only built-in modules. The browser connects
to `/control`; each WebSocket message is translated to the daemon's framed Unix
socket protocol. Set `QUESYNTH_ROOT` when launching the binary outside the source
tree so the adapter can find `ui/`:

```sh
QUESYNTH_ROOT=/path/to/quesynth ./build/quesynth --browser
```
