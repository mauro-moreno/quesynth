"use strict";
const http = require("http"), net = require("net"), crypto = require("crypto"), fs = require("fs"), path = require("path");
const { spawn } = require("child_process");
function option(name, fallback) { const i = process.argv.indexOf(name); return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback; }
const root = path.resolve(option("--root", path.resolve(__dirname, "../../..")));
const socketPath = option("--socket", process.env.QUESYNTH_SOCKET || "");
const port = Number(option("--port", "8177"));
if (!socketPath) throw new Error("--socket is required");
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8" };
function fileFor(url) {
  const rel = decodeURIComponent(url.split("?")[0] === "/" ? "/ui/index.html" : url.split("?")[0]);
  if (rel === "/ui/host.js") return path.resolve(__dirname, "host.js");
  const file = path.resolve(root, "." + rel);
  return file.startsWith(root + path.sep) && fs.existsSync(file) && fs.statSync(file).isFile() ? file : null;
}
class Daemon {
  constructor() { this.next = 1; this.buf = Buffer.alloc(0); this.pending = new Map(); this.sock = net.createConnection(socketPath); this.sock.on("data", b => this.read(b)); }
  read(b) { this.buf = Buffer.concat([this.buf, b]); while (this.buf.length >= 4) { const n = this.buf.readUInt32LE(0); if (this.buf.length < n + 4) return; const text = this.buf.subarray(4, n + 4).toString(); this.buf = this.buf.subarray(n + 4); const id = Number(text.split(" ", 2)[1]); const resolve = this.pending.get(id); if (resolve) { this.pending.delete(id); resolve(text); } } }
  request(command) { return new Promise((resolve, reject) => { const id = this.next++; const body = Buffer.from(`1 ${id} ${command}`); const frame = Buffer.alloc(body.length + 4); frame.writeUInt32LE(body.length, 0); body.copy(frame, 4); this.pending.set(id, resolve); this.sock.write(frame, err => { if (err) { this.pending.delete(id); reject(err); } }); }); }
  close() { this.sock.destroy(); }
}
function parameterIds(response) { const ids = {}; for (const line of response.split("\n").slice(1)) { const m = line.match(/id=([^ ]+) .*?index=(\d+)/); if (m) ids[Number(m[2])] = m[1]; } return ids; }
async function makeAdapter() { const daemon = new Daemon(); return { daemon, ids: parameterIds(await daemon.request("parameter.list")) }; }
async function handle(adapter, msg, send) {
  const d = adapter.daemon;
  if (msg.type === "sync") {
    const response = await d.request("state.snapshot"), values = [];
    for (const line of response.split("\n").slice(1)) { const m = line.match(/id=([^ ]+) value=(-?\d+)/); if (!m) continue; const i = Object.keys(adapter.ids).find(k => adapter.ids[k] === m[1]); if (i !== undefined) values[Number(i)] = Number(m[2]); }
    send({ type: "state", values }); return;
  }
  if (msg.type === "set" && adapter.ids[msg.index]) { await d.request(`parameter.set ${adapter.ids[msg.index]} ${msg.value}`); return; }
  if (msg.type === "state" && Array.isArray(msg.values)) { const pairs = []; msg.values.forEach((v, i) => { if (adapter.ids[i] && Number.isInteger(v)) pairs.push(`${adapter.ids[i]} ${v}`); }); if (pairs.length) await d.request(`parameter.set_many ${pairs.join(" ")}`); return; }
  if (msg.type === "note") { await d.request(`midi ${msg.on ? 144 : 128} ${msg.note | 0} ${msg.velocity | 0}`); return; }
  if (msg.type === "wheel") {
    if (msg.which === "pitch") { const raw = Math.max(0, Math.min(16383, Math.round((Number(msg.value) + 1) * 8192))); await d.request(`midi 224 ${raw & 127} ${raw >> 7}`); }
    else await d.request(`midi 176 1 ${Math.max(0, Math.min(127, Math.round(Number(msg.value) * 127)))}`);
  }
}
function acceptFrames(ws, data) {
  ws.buffer = Buffer.concat([ws.buffer, data]); let offset = 0;
  while (offset + 2 <= ws.buffer.length) {
    const second = ws.buffer[offset + 1]; let length = second & 127; let header = 2;
    if (length === 126) { if (offset + 4 > ws.buffer.length) break; length = ws.buffer.readUInt16BE(offset + 2); header = 4; }
    if (length === 127 || !(second & 0x80) || offset + header + 4 + length > ws.buffer.length) break;
    const mask = ws.buffer.subarray(offset + header, offset + header + 4), start = offset + header + 4;
    const payload = Buffer.from(ws.buffer.subarray(start, start + length)); offset = start + length;
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    if (payload.length && payload[0] === 0x7b) ws.onText(payload.toString());
  }
  ws.buffer = ws.buffer.subarray(offset);
}
function frame(text) { const body = Buffer.from(text); if (body.length < 126) return Buffer.concat([Buffer.from([129, body.length]), body]); const h = Buffer.alloc(4); h[0] = 129; h[1] = 126; h.writeUInt16BE(body.length, 2); return Buffer.concat([h, body]); }
const server = http.createServer((req, res) => { const file = fileFor(req.url); if (!file) { res.writeHead(404); res.end("not found"); return; } res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" }); fs.createReadStream(file).pipe(res); });
server.on("upgrade", async (req, socket) => {
  if (req.url !== "/control" || !req.headers["sec-websocket-key"]) return socket.destroy();
  const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  try { const adapter = await makeAdapter(); const ws = { buffer: Buffer.alloc(0), onText: async text => { try { await handle(adapter, JSON.parse(text), m => socket.write(frame(JSON.stringify(m)))); } catch (_) {} } }; socket.on("data", data => acceptFrames(ws, data)); socket.on("close", () => adapter.daemon.close()); } catch (_) { socket.destroy(); }
});
server.listen(port, "127.0.0.1", () => { const url = `http://127.0.0.1:${port}/ui/index.html`; console.log(`browser interface on ${url}`); if (!process.argv.includes("--no-open")) spawn(process.platform === "win32" ? "start" : "xdg-open", [url], { detached: true, stdio: "ignore", shell: process.platform === "win32" }).unref(); });
