import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import {spawn} from "node:child_process";
import {ROOT} from "./support/fake-daemon.mjs";
import {createBridge, startEnv, unix} from "./support/harness.mjs";
import {TestSocket, rawHttp, upgradeRequest} from "./support/ws-client.mjs";

const SERVE = path.join(ROOT, "hosts", "standalone", "browser", "serve.js");
const ADAPTER_HOST = fs.readFileSync(path.join(ROOT, "hosts", "standalone", "browser", "host.js"), "utf8");

// A root with the things the adapter must not hand out planted in it: a
// decoy ui/host.js, the two withheld scripts, a dotfile, a symlink out of
// ui/, and files beside ui/ that every repository has.
function decoyRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "qs-root-"));
  const ui = path.join(root, "ui");
  fs.mkdirSync(ui);
  for (const name of ["params.js", "index.html", "style.css", "store.js"]) {
    fs.copyFileSync(path.join(ROOT, "ui", name), path.join(ui, name));
  }
  fs.writeFileSync(path.join(ui, "bank.js"), "// decoy: the generated factory bank\n");
  fs.writeFileSync(path.join(ui, "host.js"), "// decoy: not the adapter's transport\n");
  fs.writeFileSync(path.join(ui, ".hidden"), "secret\n");
  fs.writeFileSync(path.join(root, "README.md"), "outside ui\n");
  fs.mkdirSync(path.join(root, ".git"));
  fs.writeFileSync(path.join(root, ".git", "config"), "[core]\n");
  fs.symlinkSync(path.join(root, "README.md"), path.join(ui, "escape.txt"));
  return root;
}

function get(port, target, headers = {}) {
  const lines = [`GET ${target} HTTP/1.1`];
  if (!("Host" in headers)) lines.push(`Host: 127.0.0.1:${port}`);
  for (const [name, value] of Object.entries(headers)) if (value !== null) lines.push(`${name}: ${value}`);
  lines.push("Connection: close");
  return rawHttp(port, lines.join("\r\n") + "\r\n\r\n");
}

function bodyOf(response) {
  return response.text.slice(response.text.indexOf("\r\n\r\n") + 4);
}

test("serves ui/ and the adapter's host.js, refuses everything else, and survives it", {skip: !unix}, async t => {
  const root = decoyRoot();
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const env = await startEnv(t, {root});
  const port = env.port;

  const index = await get(port, "/ui/index.html");
  assert.equal(index.status, 200);
  assert.match(bodyOf(index), /<script src="host.js"/);
  assert.match(index.text, /Content-Type: text\/html/i);

  const home = await get(port, "/");
  assert.equal(home.status, 302);
  assert.match(home.text, /Location: \/ui\/index.html/i);

  const host = await get(port, "/ui/host.js");
  assert.equal(host.status, 200);
  assert.equal(bodyOf(host), ADAPTER_HOST, "the adapter's host.js, not the one in ui/");

  const head = await rawHttp(port,
    `HEAD /ui/index.html HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`);
  assert.equal(head.status, 200);
  assert.equal(bodyOf(head), "");

  const missing = [
    "/ui/store.js", "/ui/bank.js", "/.git/config", "/README.md", "/ui/.hidden",
    "/ui/escape.txt", "/ui/../README.md", "/ui/%2e%2e/README.md", "/ui/..%2fREADME.md",
    "/ui/%2E%2E%2F%2E%2E%2Fetc%2Fpasswd", "/../../etc/passwd", "/ui//store.js", "/ui/./store.js",
    "/ui/nope.js",
  ];
  for (const target of missing) {
    assert.equal((await get(port, target)).status, 404, target);
  }
  assert.equal((await get(port, "/ui/%zz")).status, 400, "malformed percent-encoding");
  assert.equal((await get(port, "/ui/%E0%A4%A")).status, 400, "truncated percent-encoding");
  assert.equal((await get(port, "/ui/index.html%00")).status, 400, "NUL");

  assert.equal((await get(port, "/ui/index.html", {Host: `evil.example:${port}`})).status, 403);
  assert.equal((await get(port, "/ui/index.html", {Host: `127.0.0.1:${port + 1}`})).status, 403);
  assert.equal((await get(port, "/ui/index.html", {Host: `localhost:${port}`})).status, 200);
  const hostless = await rawHttp(port, "GET /ui/index.html HTTP/1.1\r\nConnection: close\r\n\r\n");
  assert.equal(hostless.status, 400);

  const post = await rawHttp(port, `POST /ui/index.html HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n` +
    "Content-Length: 2\r\nConnection: close\r\n\r\nhi");
  assert.equal(post.status, 405);
  assert.match(post.text, /Allow: GET, HEAD/i);

  // The WebSocket is where the disk-writing commands are, so it is checked
  // at least as hard as the files.
  for (const origin of ["http://evil.example", `http://127.0.0.1:${port + 1}`, "null",
    `https://127.0.0.1:${port}`, `http://127.0.0.1:${port}.evil.example`]) {
    const refused = await env.open({origin});
    assert.equal(refused.status, 403, origin);
  }
  assert.equal((await env.open({host: `evil.example:${port}`})).status, 403);
  assert.equal((await rawHttp(port, upgradeRequest(port, {path: "/elsewhere"}))).status, 404);
  const noKey = upgradeRequest(port).replace(/Sec-WebSocket-Key: .*\r\n/, "");
  assert.equal((await rawHttp(port, noKey)).status, 400);
  const oldVersion = upgradeRequest(port).replace("Sec-WebSocket-Version: 13", "Sec-WebSocket-Version: 8");
  assert.equal((await rawHttp(port, oldVersion)).status, 426);

  assert.equal((await get(port, "/ui/index.html")).status, 200, "still serving");
  const ws = await env.open({origin: `http://localhost:${port}`});
  assert.ok(ws instanceof TestSocket, "a page from the adapter's own origin connects");
  await ws.synced();
});

test("a second adapter on a busy port fails with a clear message and exit code 1", {skip: !unix}, async t => {
  const holder = net.createServer();
  await new Promise(resolve => holder.listen(0, "127.0.0.1", resolve));
  t.after(() => holder.close());
  const port = holder.address().port;

  const bridge = createBridge({root: ROOT, socketPath: "/nonexistent/quesynth.sock", port});
  await assert.rejects(bridge.listen(), {code: "EADDRINUSE"});

  const child = spawn(process.execPath, [SERVE, "--root", ROOT, "--socket", "/nonexistent/quesynth.sock",
    "--port", String(port), "--no-open"], {stdio: ["ignore", "pipe", "pipe"]});
  let stderr = "";
  child.stderr.on("data", c => { stderr += c; });
  const code = await new Promise(resolve => child.on("exit", resolve));
  assert.equal(code, 1);
  assert.match(stderr, new RegExp(`127\\.0\\.0\\.1:${port} is already in use`));
});

test("SIGTERM closes every page with 1001 and exits 0", {skip: !unix}, async t => {
  const env = await startEnv(t);
  const child = spawn(process.execPath, [SERVE, "--root", ROOT, "--socket", env.socketPath,
    "--port", "0", "--no-open"], {stdio: ["ignore", "pipe", "pipe"]});
  t.after(() => child.kill("SIGKILL"));
  let stdout = "";
  const port = await new Promise((resolve, reject) => {
    child.stdout.on("data", c => {
      stdout += c;
      const m = /127\.0\.0\.1:(\d+)\/ui\/index\.html/.exec(stdout);
      if (m) resolve(Number(m[1]));
    });
    child.on("exit", () => reject(new Error("serve.js exited early")));
  });
  const ws = await TestSocket.open(port);
  await ws.synced();
  const exited = new Promise(resolve => child.on("exit", resolve));
  child.kill("SIGTERM");
  assert.deepEqual(await ws.closed, {code: 1001, reason: "adapter shutting down"});
  assert.equal(await exited, 0);
});

test("the CLI rejects missing or malformed options instead of guessing", async () => {
  for (const args of [[], ["--socket", "s", "--port", "70000"], ["--socket", "s", "--poll-ms", "x"],
    ["--socket", "s", "--frobnicate"]]) {
    const child = spawn(process.execPath, [SERVE, ...args, "--no-open"], {
      stdio: ["ignore", "pipe", "pipe"],
      env: {...process.env, QUESYNTH_SOCKET: ""},
    });
    let stderr = "";
    child.stderr.on("data", c => { stderr += c; });
    assert.equal(await new Promise(resolve => child.on("exit", resolve)), 1, args.join(" "));
    assert.match(stderr, /^error: /);
  }
});
