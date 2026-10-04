// A fake daemon and an in-process bridge in front of it, torn down after the
// test that made them.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {createRequire} from "node:module";
import {FakeDaemon, ROOT} from "./fake-daemon.mjs";
import {TestSocket, sleep} from "./ws-client.mjs";

const require = createRequire(import.meta.url);
export const {createBridge} = require("../../../hosts/standalone/browser/serve.js");

// Unix-domain sockets are what the daemon speaks; there is no such transport
// on Windows (the daemon has only stubs there).
export const unix = process.platform !== "win32";

// Each test file runs in its own process; a private temporary directory per
// process lets a test say "the adapter left nothing behind" without seeing
// another file's sessions at work.
const privateTmp = fs.mkdtempSync(path.join(os.tmpdir(), "qs-browser-tests-"));
process.env.TMPDIR = privateTmp;
process.on("exit", () => fs.rmSync(privateTmp, {recursive: true, force: true}));

export async function startEnv(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "qs-bridge-test-"));
  const socketPath = path.join(dir, "daemon.sock");
  const daemon = new FakeDaemon({
    socketPath,
    keepPath: path.join(dir, "config", "quesynth", "bank.json"),
    ...options.daemon,
  });
  await daemon.start();
  const logs = [];
  const bridge = createBridge({
    root: options.root || ROOT,
    socketPath,
    port: 0,
    pollMs: options.pollMs || 20,
    echoMs: options.echoMs,
    adoptMs: options.adoptMs,
    requestTimeoutMs: options.requestTimeoutMs,
    log: message => logs.push(message),
  });
  await bridge.listen();
  const sockets = [];
  t.after(async () => {
    for (const s of sockets) s.destroy();
    await bridge.close();
    await daemon.stop();
    fs.rmSync(dir, {recursive: true, force: true});
  });
  return {
    daemon,
    bridge,
    dir,
    socketPath,
    logs,
    port: bridge.port,
    async open(opts) {
      const ws = await TestSocket.open(bridge.port, opts);
      if (ws instanceof TestSocket) sockets.push(ws);
      return ws;
    },
  };
}

// Poll until `fn` returns something truthy, for state that settles
// asynchronously (connection counts, the fake daemon's log).
export async function until(fn, timeoutMs = 3000, what = "condition") {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const value = fn();
    if (value) return value;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(10);
  }
}

// Temp directories the adapter made and did not remove.
export function strayTempDirs() {
  return fs.readdirSync(privateTmp).filter(name => name.startsWith("quesynth-bridge-"));
}
