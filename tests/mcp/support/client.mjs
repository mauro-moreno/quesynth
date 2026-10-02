import { spawn } from "node:child_process";
import { once } from "node:events";
import { readFileSync } from "node:fs";

// The server speaks to the daemon over a Unix socket, as the browser adapter does.
export const skip = process.platform === "win32";

const config = JSON.parse(readFileSync(new URL("../../../.mcp.json", import.meta.url)));

export function startClient(t, { args = [], env = {}, cwd } = {}) {
  const launch = config.mcpServers.quesynth;
  const child = spawn(launch.command, [...launch.args, ...args], {
    cwd, env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  const pending = new Map();
  const messages = [];
  let id = 0;
  const exited = once(child, "exit");
  let buffered = "";
  child.stdout.setEncoding("utf8").on("data", text => {
    const lines = (buffered + text).split("\n");
    buffered = lines.pop();
    lines.forEach(onLine);
  });
  function onLine(line) {
    const message = JSON.parse(line);
    messages.push(message);
    const entry = pending.get(message.id);
    if (entry) {
      pending.delete(message.id);
      clearTimeout(entry.timer);
      entry.resolve(message);
    }
  }
  child.on("exit", code => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error(`MCP exited ${code}: ${stderr}`));
    }
    pending.clear();
  });
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
  });
  function send(message) { child.stdin.write(JSON.stringify(message) + "\n"); }
  function request(method, params, requestId = ++id) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`MCP did not answer ${method}: ${stderr}`));
      }, 5000);
      pending.set(requestId, { resolve, reject, timer });
      send({ jsonrpc: "2.0", id: requestId, method, ...(params === undefined ? {} : { params }) });
    });
  }
  async function initialize(protocolVersion = "2025-11-25") {
    const response = await request("initialize", {
      protocolVersion, capabilities: {}, clientInfo: { name: "quesynth-test", version: "1" },
    });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    return response;
  }
  return {
    child, request, send, initialize, messages, exited,
    call: (name, args = {}) => request("tools/call", { name, arguments: args }),
    stderr: () => stderr,
  };
}
