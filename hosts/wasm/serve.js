// A static file server for working on the interface in a browser.
//
//   node hosts/wasm/serve.js [port]
//
// Development only, and deliberately the smallest thing that works: a web view
// opens the panel straight off the filesystem and needs no server at all. This
// exists because a browser refuses to load a page's scripts over file:// under
// some settings, and because a phone on the same network can point at it to
// check the touch targets on real glass.
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

const roots = [__dirname, path.join(__dirname, "..", "..", "ui")].map((dir) =>
  path.resolve(dir)
);
const port = Number(process.argv[2]) || 8177;

const types = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
};

// The first root that has the file. A miss in both is a 404, which is a normal
// answer here rather than a failure: index.html asks for host.js and bank.js
// with an onerror guard precisely so that a build without them still runs.
function resolve(rel) {
  for (const root of roots) {
    const file = path.join(root, rel);
    // Never serve outside the root, however the path was spelled.
    if (!file.startsWith(root)) continue;
    if (fs.existsSync(file) && fs.statSync(file).isFile()) return file;
  }
  return null;
}

http
  .createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]);
    const file = resolve(rel === "/" ? "index.html" : rel);
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
  })
  .listen(port, () => {
    console.log(`interface on http://localhost:${port}`);
  });
