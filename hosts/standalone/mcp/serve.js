"use strict";

const { DaemonClient } = require("../browser/daemon.js");
const { tools, commandFor, validateArguments } = require("./tools.js");

const versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const rpcError = (code, message) => Object.assign(new Error(message), { code });
const toolError = (code, message) => ({
  isError: true, content: [{ type: "text", text: JSON.stringify({ code, message }) }],
});
const structured = version => version >= "2025-06-18";
const listed = ({ annotations, outputSchema, ...tool }, version) => ({
  ...tool,
  ...(version >= "2025-03-26" ? { annotations } : {}),
  ...(structured(version) ? { outputSchema } : {}),
});

function options(args) {
  let socket = process.env.QUESYNTH_SOCKET || (process.env.XDG_RUNTIME_DIR
    ? `${process.env.XDG_RUNTIME_DIR}/quesynth/quesynth.sock`
    : typeof process.getuid === "function" ? `/tmp/quesynth-${process.getuid()}.sock` : "");
  let timeoutMs = 3000;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--help") {
      process.stderr.write("Usage: node hosts/standalone/mcp/serve.js [--socket PATH] [--timeout-ms MS]\n");
      return null;
    }
    const flag = args[i];
    if (flag !== "--socket" && flag !== "--timeout-ms") throw new Error(`Unknown option: ${flag}`);
    const value = args[++i];
    if (!value) throw new Error(`${flag} needs a value`);
    if (flag === "--socket") socket = value;
    else {
      if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 2147483647) {
        throw new Error("--timeout-ms must be an integer in 1..2147483647");
      }
      timeoutMs = Number(value);
    }
  }
  if (!socket) throw new Error("No socket path; the native daemon control transport currently requires Linux");
  return { socket, timeoutMs };
}

function main({ socket, timeoutMs }) {
  let daemon;
  let phase = "new";
  let version;
  let active = 0;
  let ended = false;
  const reply = message => process.stdout.write(JSON.stringify(message) + "\n");
  const finish = () => { if (ended && active === 0) daemon?.close(); };

  async function dispatch(message) {
    const params = message.params === undefined ? {} : message.params;
    if (!object(params)) throw rpcError(-32602, "params must be an object");
    switch (message.method) {
      case "initialize": {
        if (phase !== "new") throw rpcError(-32600, "Already initialized");
        if (typeof params.protocolVersion !== "string" || !object(params.capabilities)
          || !object(params.clientInfo) || typeof params.clientInfo.name !== "string"
          || typeof params.clientInfo.version !== "string") {
          throw rpcError(-32602, "initialize needs protocolVersion, capabilities and clientInfo");
        }
        phase = "initialized";
        version = versions.includes(params.protocolVersion) ? params.protocolVersion : versions.at(-1);
        return {
          protocolVersion: version,
          capabilities: { tools: {} }, serverInfo: { name: "quesynth", version: "1.0.0" },
        };
      }
      case "ping": return {};
      case "tools/list":
      case "tools/call":
        if (phase !== "ready") throw rpcError(-32000, "Initialize and send notifications/initialized first");
        break;
      default: throw rpcError(-32601, "Method not found");
    }
    if (message.method === "tools/list") return { tools: tools.map(tool => listed(tool, version)) };
    if (typeof params.name !== "string") throw rpcError(-32602, "tools/call needs a tool name");
    const tool = tools.find(tool => tool.name === params.name);
    if (!tool) throw rpcError(-32602, "Unknown tool");
    const arguments_ = params.arguments === undefined ? {} : params.arguments;
    const invalid = validateArguments(tool, arguments_);
    if (invalid) return toolError("invalid_arguments", invalid);
    try {
      if (!daemon || daemon.closed) daemon = new DaemonClient(socket, { timeoutMs });
      const answer = await daemon.request(commandFor(tool.name, arguments_));
      const result = { fields: answer.fields, lines: answer.lines };
      const content = [{ type: "text", text: JSON.stringify(result) }];
      return structured(version) ? { content, structuredContent: result } : { content };
    } catch (error) {
      return toolError(error.code || "daemon_error", error.message);
    }
  }

  async function handle(message) {
    if (!object(message) || message.jsonrpc !== "2.0" || typeof message.method !== "string"
      || (Object.hasOwn(message, "id") && typeof message.id !== "string" && !Number.isSafeInteger(message.id))) {
      reply({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid JSON-RPC request" } });
      return;
    }
    if (!Object.hasOwn(message, "id")) {
      if (message.method === "notifications/initialized" && phase === "initialized") phase = "ready";
      return;
    }
    const response = { jsonrpc: "2.0", id: message.id };
    active++;
    try { response.result = await dispatch(message); }
    catch (error) {
      response.error = { code: Number.isInteger(error.code) ? error.code : -32603, message: error.message };
    } finally { active--; }
    reply(response);
    finish();
  }

  require("readline").createInterface({ input: process.stdin }).on("line", line => {
    let message;
    try { message = JSON.parse(line); }
    catch {
      reply({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Invalid JSON" } });
      return;
    }
    handle(message);
  }).on("close", () => { ended = true; finish(); });
}

try {
  const config = options(process.argv.slice(2));
  if (config) main(config);
} catch (error) {
  process.stderr.write(`quesynth MCP: ${error.message}\n`);
  process.exitCode = 2;
}
