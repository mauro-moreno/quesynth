import net from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export async function daemonFixture(t, answer = () => "ok") {
  const dir = await mkdtemp(join(tmpdir(), "quesynth-mcp-"));
  const socket = join(dir, "control.sock");
  const commands = [];
  const sockets = new Set();
  const server = net.createServer(peer => {
    sockets.add(peer);
    peer.on("close", () => sockets.delete(peer));
    let pending = Buffer.alloc(0);
    peer.on("data", chunk => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
        const n = pending.readUInt32LE(0);
        const text = pending.subarray(4, 4 + n).toString("utf8");
        pending = pending.subarray(4 + n);
        const match = /^1 (\d+) (.*)$/.exec(text);
        if (!match) throw new Error(`Unexpected control frame: ${text}`);
        commands.push(match[2]);
        const result = answer(match[2], peer);
        if (result === undefined) continue;
        const payload = Buffer.from(`1 ${match[1]} ${result}`);
        const frame = Buffer.alloc(4 + payload.length);
        frame.writeUInt32LE(payload.length);
        payload.copy(frame, 4);
        // Fragmentation must be handled by the real shared transport.
        peer.write(frame.subarray(0, 3));
        peer.write(frame.subarray(3));
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socket, resolve);
  });
  t.after(async () => {
    for (const peer of sockets) peer.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  return { socket, commands, dir };
}
