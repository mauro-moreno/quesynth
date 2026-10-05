// A static file server for working on the interface in a browser.
//
//   node hosts/wasm/serve.js [port]       (default 4817, this machine only)
//
// Development only, and deliberately the smallest thing that works: a web view
// opens the panel straight off the filesystem and needs no server at all. This
// exists because a browser refuses to load a page's scripts over file:// under
// some settings. It listens on this machine only; checking the touch targets on
// a phone means forwarding the port to it (adb reverse, ssh -L), not exposing it.
//
// It serves two directories laid over one another, because that is what the web
// build *is*: the panel in ui/, plus this host's own glue. Every host assembles
// the same way -- tools/install-vst3.ps1 copies ui/ into a bundle beside the
// plugin binary -- and serving it any other way here would mean developing
// against a layout nothing ships.
//
// This directory wins on a name collision, so a file here shadows one in ui/.
const http = require("http");
const fs = require("fs");
const path = require("path");

// Loopback only. This serves the working tree to whoever can reach the port, and
// it is a development tool, so the machine it runs on is the whole audience.
const HOST = "127.0.0.1";

// Not 8177, which is where `quesynth --browser` listens (hosts/standalone/
// browser/serve.js): the two are run side by side while working on the panel,
// and whichever started second would fail with EADDRINUSE. Nothing else in this
// repository uses 4817, and it is not one of the ports other dev servers claim.
const DEFAULT_PORT = 4817;

const types = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
};

// Nearest first: this directory, then ui/.
const defaultRoots = [__dirname, path.join(__dirname, "..", "..", "ui")].map(
  (dir) => path.resolve(dir)
);

// True when `file` is `root` itself or somewhere beneath it. Compared as a
// relative path rather than a string prefix: "/a/ui-secret" starts with
// "/a/ui" and is not inside it.
function within(root, file) {
  const rel = path.relative(root, file);
  return rel === "" || (rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel));
}

// The first root that has the file. A miss in all of them is a 404, which is a
// normal answer here rather than a failure: index.html asks for host.js and
// bank.js with an onerror guard precisely so that a build without them still
// runs.
function find(roots, rel) {
  for (const root of roots) {
    const file = path.join(root, rel);
    // Never serve outside the root, however the path was spelled.
    if (!within(root, file)) continue;
    try {
      if (fs.statSync(file).isFile()) return file;
    } catch (err) {
      // Absent, or not a directory on the way: a miss like any other.
    }
  }
  return null;
}

function createServer(roots = defaultRoots) {
  return http.createServer((req, res) => {
    let rel;
    try {
      rel = decodeURIComponent(req.url.split("?")[0]);
    } catch (err) {
      // A malformed escape such as "/%E0%A4%A" is the client's mistake, not a
      // reason for the server to stop.
      res.writeHead(400).end("bad request");
      return;
    }
    if (rel.includes("\0")) {
      res.writeHead(400).end("bad request");
      return;
    }
    const file = find(roots, rel === "/" ? "index.html" : rel);
    if (!file) {
      res.writeHead(404).end("not found");
      return;
    }
    fs.readFile(file, (err, body) => {
      if (err) {
        res.writeHead(404).end("not found");
        return;
      }
      res.writeHead(200, {
        "Content-Type": types[path.extname(file)] || "application/octet-stream",
        "Cache-Control": "no-store",
      });
      res.end(body);
    });
  });
}

module.exports = { createServer, DEFAULT_PORT, HOST };

if (require.main === module) {
  const server = createServer();
  server.listen(Number(process.argv[2]) || DEFAULT_PORT, HOST, () => {
    console.log(`interface on http://${HOST}:${server.address().port} (this machine only)`);
  });
}
