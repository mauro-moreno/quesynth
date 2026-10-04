"use strict";
// The local web server `quesynth --browser` starts: the shared panel's files
// over HTTP and one WebSocket per page, each backed by its own connection to
// the daemon's control socket. The daemon owns the sound, the bank and the
// patch identity; see README.md beside this file for who owns what.
//
//   node serve.js --socket PATH [--root DIR] [--port N] [--poll-ms N]
//                 [--no-open]

const fs = require("fs");
const http = require("http");
const path = require("path");
const { spawn } = require("child_process");
const { checkHandshake, rejectUpgrade, acceptUpgrade } = require("./websocket");
const { DaemonClient } = require("./daemon");
const { Session, readRegistry } = require("./session");
const { loadParams } = require("./bank");

const HOST = "127.0.0.1";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
};

// Never served, deliberately. The adapter hosts the panel the way a plugin
// does, so the two files that make the page its own authority are left out:
// store.js keeps the sound and the bank in local storage, and bank.js is the
// factory bank compiled into the page. ui/index.html loads both behind
// onerror="void 0" so a host that owns persistence can omit them; with them
// gone SynthBank.hosted() is true and nothing in the page can overwrite the
// daemon (the contract's section 1.3).
const WITHHELD = new Set(["store.js", "bank.js"]);

function createBridge(options) {
  const root = path.resolve(options.root);
  const uiDir = fs.realpathSync(path.join(root, "ui"));
  const hostScript = path.join(__dirname, "host.js");
  const socketPath = options.socketPath;
  const params = loadParams(root);
  const log = options.log || (() => {});
  const sessionOptions = {
    params,
    log,
    pollMs: options.pollMs,
    echoMs: options.echoMs,
    adoptMs: options.adoptMs,
  };
  const sessions = new Set();
  let port = null;
  let closing = false;
  let daemonDown = false;

  // A page from anywhere else, or a hostname rebound to 127.0.0.1, must not
  // reach a socket that can rewrite the user's saved bank.
  function allowedHosts() {
    const hosts = [`${HOST}:${port}`, `localhost:${port}`];
    if (port === 80) hosts.push(HOST, "localhost");
    return hosts;
  }

  function checkHost(req) {
    const host = req.headers.host;
    if (!host) return { status: 400, message: "missing host" };
    if (!allowedHosts().includes(host.toLowerCase())) return { status: 403, message: "wrong host" };
    return null;
  }

  // A browser always sends Origin on a WebSocket; a missing one is a local
  // tool, which could reach the daemon's socket directly anyway.
  function originAllowed(origin) {
    if (origin === undefined) return true;
    return allowedHosts().some(h => origin.toLowerCase() === `http://${h}`);
  }

  function route(url) {
    const pathname = String(url).split("?")[0];
    let decoded;
    try {
      decoded = decodeURIComponent(pathname);
    } catch (err) {
      return { status: 400, message: "bad url encoding" };
    }
    if (!decoded.startsWith("/") || decoded.includes("\0") || decoded.includes("\\")) {
      return { status: 400, message: "bad path" };
    }
    // The page's own scripts and styles are relative to it, so it has to be
    // loaded from under /ui/.
    if (decoded === "/" || decoded === "/ui" || decoded === "/ui/") {
      return { status: 302, location: "/ui/index.html" };
    }
    // This directory's transport, not whatever ui/ may hold under that name.
    if (decoded === "/ui/host.js") return { file: hostScript };
    if (!decoded.startsWith("/ui/")) return { status: 404 };
    const parts = decoded.slice(4).split("/");
    if (parts.some(p => p === "" || p.startsWith("."))) return { status: 404 };
    let file;
    try {
      file = fs.realpathSync(path.join(uiDir, ...parts));
    } catch (err) {
      return { status: 404 };
    }
    // Checked on the resolved path, so neither a symlink nor a case-folding
    // filesystem can reach the files withheld above or anything outside ui/.
    const rel = path.relative(uiDir, file);
    if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return { status: 404 };
    if (WITHHELD.has(rel.toLowerCase())) return { status: 404 };
    return { file };
  }

  function respond(res, status, message, headers) {
    const body = `${message || http.STATUS_CODES[status] || ""}\n`;
    res.writeHead(status, Object.assign({
      "Content-Type": "text/plain; charset=utf-8",
      "Content-Length": Buffer.byteLength(body),
      "Cache-Control": "no-store",
    }, headers));
    res.end(res.req.method === "HEAD" ? undefined : body);
  }

  function serveFile(req, res, file) {
    fs.stat(file, (err, stat) => {
      if (err || !stat.isFile()) return respond(res, 404);
      res.writeHead(200, {
        "Content-Type": TYPES[path.extname(file).toLowerCase()] || "application/octet-stream",
        "Content-Length": stat.size,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      });
      if (req.method === "HEAD") return res.end();
      const stream = fs.createReadStream(file);
      stream.on("error", () => res.destroy());
      stream.pipe(res);
      return undefined;
    });
  }

  function onRequest(req, res) {
    try {
      const bad = checkHost(req);
      if (bad) return respond(res, bad.status, bad.message);
      if (req.method !== "GET" && req.method !== "HEAD") {
        return respond(res, 405, "GET or HEAD only", { Allow: "GET, HEAD" });
      }
      const found = route(req.url);
      if (found.file) return serveFile(req, res, found.file);
      if (found.location) return respond(res, found.status, "", { Location: found.location });
      return respond(res, found.status, found.message);
    } catch (err) {
      log(`request error: ${err.stack || err}`);
      if (!res.headersSent) return respond(res, 500);
      return res.destroy();
    }
  }

  // The daemon connection is made before the upgrade completes, so a daemon
  // that is down or full is a plain 503 the page can back off from, rather
  // than a socket that opens and immediately dies.
  function onUpgrade(req, socket, head) {
    socket.on("error", () => socket.destroy());
    try {
      const bad = checkHost(req);
      if (bad) return rejectUpgrade(socket, bad.status, bad.message);
      if (!originAllowed(req.headers.origin)) return rejectUpgrade(socket, 403, "origin not allowed");
      if (String(req.url).split("?")[0] !== "/control") return rejectUpgrade(socket, 404);
      const refused = checkHandshake(req);
      if (refused) return rejectUpgrade(socket, refused.status, refused.message, refused.headers);
      if (closing) return rejectUpgrade(socket, 503, "shutting down");

      const daemon = new DaemonClient(socketPath, { timeoutMs: options.requestTimeoutMs });
      // The socket is read while the daemon answers, or a page that goes
      // away in the meantime would not be noticed until the daemon did.
      // Nothing legitimate arrives before the 101; whatever does is kept.
      const early = [];
      const hold = chunk => {
        early.push(chunk);
        if (early.reduce((n, c) => n + c.length, 0) > 64 * 1024) socket.destroy();
      };
      const abandon = () => {
        daemon.close();
        socket.destroy();
      };
      const settle = () => {
        socket.removeListener("data", hold);
        socket.removeListener("end", abandon);
        socket.removeListener("close", abandon);
      };
      socket.on("data", hold);
      socket.once("end", abandon);
      socket.once("close", abandon);
      readRegistry(daemon, params).then(registry => {
        settle();
        if (socket.destroyed || closing) {
          daemon.close();
          if (!socket.destroyed) rejectUpgrade(socket, 503, "shutting down");
          return;
        }
        if (daemonDown) log("daemon reachable again");
        daemonDown = false;
        const ws = acceptUpgrade(req, socket, Buffer.concat([head, ...early]));
        const session = new Session(ws, daemon, registry, Object.assign({
          onClose: s => sessions.delete(s),
        }, sessionOptions));
        sessions.add(session);
      }, err => {
        settle();
        daemon.close();
        // Logged once per outage: the page retries every few seconds.
        if (!daemonDown) log(`daemon unavailable at ${socketPath}: ${err.message}`);
        daemonDown = true;
        rejectUpgrade(socket, 503, "daemon unavailable");
      }).catch(err => {
        log(`upgrade error: ${err.stack || err}`);
        daemon.close();
        socket.destroy();
      });
    } catch (err) {
      log(`upgrade error: ${err.stack || err}`);
      socket.destroy();
    }
    return undefined;
  }

  const server = http.createServer(onRequest);
  server.on("upgrade", onUpgrade);

  return {
    get port() { return port; },
    get url() { return `http://${HOST}:${port}/ui/index.html`; },
    get sessions() { return sessions.size; },

    listen() {
      return new Promise((resolve, reject) => {
        const failed = err => reject(err);
        server.once("error", failed);
        server.listen(options.port === undefined ? 8177 : options.port, HOST, () => {
          server.removeListener("error", failed);
          server.on("error", err => log(`server error: ${err.message}`));
          port = server.address().port;
          resolve(server.address());
        });
      });
    },

    // Every page is told the adapter is going away (1001) rather than left to
    // find out from a reset.
    close() {
      closing = true;
      const pending = [...sessions].map(s => {
        s.close(1001, "adapter shutting down");
        return s.done;
      });
      return new Promise(resolve => {
        server.close(() => resolve());
        server.closeAllConnections();
      }).then(() => Promise.all(pending)).then(() => undefined);
    },
  };
}

function parseArgs(argv) {
  const out = { root: path.resolve(__dirname, "../../.."), socket: process.env.QUESYNTH_SOCKET || "",
    port: 8177, pollMs: 100, open: true };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`);
      return argv[++i];
    };
    const integer = (lo, hi) => {
      const text = value();
      const n = Number(text);
      if (!/^\d+$/.test(text) || n < lo || n > hi) throw new Error(`${arg} needs an integer ${lo}..${hi}`);
      return n;
    };
    if (arg === "--root") out.root = path.resolve(value());
    else if (arg === "--socket") out.socket = value();
    else if (arg === "--port") out.port = integer(0, 65535);
    else if (arg === "--poll-ms") out.pollMs = integer(10, 10000);
    else if (arg === "--no-open") out.open = false;
    else throw new Error(`unknown option ${arg}`);
  }
  if (!out.socket) throw new Error("--socket is required (or set QUESYNTH_SOCKET)");
  return out;
}

// Failing to open a browser is not failing to serve: the URL is printed and
// the user can open it by hand.
function openBrowser(url) {
  let command = "xdg-open";
  let args = [url];
  if (process.platform === "darwin") command = "open";
  if (process.platform === "win32") {
    command = "cmd";
    args = ["/c", "start", "", url];
  }
  try {
    const child = spawn(command, args, { detached: true, stdio: "ignore" });
    child.on("error", err => {
      console.error(`could not open a browser (${err.message}); open ${url} yourself`);
    });
    child.unref();
  } catch (err) {
    console.error(`could not open a browser (${err.message}); open ${url} yourself`);
  }
}

function main() {
  let args;
  let bridge;
  try {
    args = parseArgs(process.argv.slice(2));
    bridge = createBridge({ root: args.root, socketPath: args.socket, port: args.port,
      pollMs: args.pollMs, log: message => console.error(message) });
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
  bridge.listen().then(() => {
    console.log(`browser interface on ${bridge.url}`);
    if (args.open) openBrowser(bridge.url);
  }, err => {
    if (err.code === "EADDRINUSE") {
      console.error(`error: ${HOST}:${args.port} is already in use ` +
        "(another quesynth --browser?); pick another with --port");
    } else {
      console.error(`error: cannot listen on ${HOST}:${args.port}: ${err.message}`);
    }
    process.exit(1);
  });
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    // Bounded, so a page that never finishes its close handshake cannot
    // keep the process alive.
    setTimeout(() => process.exit(0), 3000).unref();
    bridge.close().then(() => process.exit(0));
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

if (require.main === module) main();

module.exports = { createBridge };
