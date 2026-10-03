import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { quesynthBinary } from "./binary.mjs";

export const config = JSON.parse(readFileSync(new URL("../../../.mcp.json", import.meta.url)));

// Launches the way .mcp.json does, with the built binary in place of `quesynth`
// on PATH. The server reaches the daemon through XDG_RUNTIME_DIR, so a test with
// no daemon of its own gets an empty one rather than the developer's.
//
// The server answers requests in order and sends nothing for a notification, so
// each reply is the next message. request() and take() consume them in turn,
// which makes an unexpected extra reply fail the next call loudly.
export function startClient(t, { runtime, env = {}, cwd } = {}) {
  if (runtime === undefined) {
    runtime = mkdtempSync(join(tmpdir(), "qmcp-"));
    t.after(() => rmSync(runtime, { recursive: true, force: true }));
  }
  const child = spawn(quesynthBinary(), config.mcpServers.quesynth.args, {
    cwd, env: { ...process.env, XDG_RUNTIME_DIR: runtime, ...env }, stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.on("error", () => {});
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  const messages = [];
  const raw = [];
  const waiters = new Set();
  let id = 0;
  let cursor = 0;
  let buffered = "";
  const exited = once(child, "close");
  child.stdout.setEncoding("utf8").on("data", text => {
    const lines = (buffered + text).split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      raw.push(line);
      messages.push(JSON.parse(line));
    }
    for (const waiter of [...waiters]) waiter.check();
  });
  child.on("close", code => {
    for (const waiter of [...waiters]) waiter.check();
    for (const waiter of [...waiters]) waiter.fail(new Error(`MCP exited ${code}: ${stderr}`));
  });
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
  });
  function write(text) { child.stdin.write(text); }
  function send(message) { write(JSON.stringify(message) + "\n"); }
  function take(count = 1) {
    return new Promise((resolve, reject) => {
      const done = () => { clearTimeout(timer); waiters.delete(waiter); };
      const waiter = {
        check() {
          if (messages.length - cursor < count) return;
          done();
          resolve(messages.slice(cursor, cursor += count));
        },
        fail(error) { done(); reject(error); },
      };
      const timer = setTimeout(() => waiter.fail(new Error(`MCP did not send ${count} message(s): ${stderr}`)), 5000);
      waiters.add(waiter);
      waiter.check();
    });
  }
  async function request(method, params, requestId = ++id) {
    send({ jsonrpc: "2.0", id: requestId, method, ...(params === undefined ? {} : { params }) });
    const [reply] = await take();
    assert.deepEqual(reply.id, requestId, `${method} was answered out of turn`);
    return reply;
  }
  async function initialize(protocolVersion = "2025-11-25") {
    const response = await request("initialize", {
      protocolVersion, capabilities: {}, clientInfo: { name: "quesynth-test", version: "1" },
    });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    return response;
  }
  return {
    child, runtime, request, send, write, take, initialize, exited, raw,
    call: (name, args = {}) => request("tools/call", { name, arguments: args }),
    stderr: () => stderr,
  };
}

// A tool failure is a result with isError, not a JSON-RPC error.
export function errorOf(response) {
  assert.equal(response.result.isError, true, JSON.stringify(response));
  return JSON.parse(response.result.content[0].text);
}

export function resultOf(response) {
  assert.equal(response.error, undefined, JSON.stringify(response));
  assert.equal(response.result.isError, undefined, JSON.stringify(response));
  return JSON.parse(response.result.content[0].text);
}
