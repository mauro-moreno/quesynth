import net from "node:net";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A QCP frame is a 4-byte little-endian length, then the payload.
export function frame(text) {
  const payload = Buffer.from(text);
  const bytes = Buffer.alloc(4 + payload.length);
  bytes.writeUInt32LE(payload.length);
  payload.copy(bytes, 4);
  return bytes;
}

// Stands in for the daemon. `quesynth --mcp` finds it through XDG_RUNTIME_DIR,
// so the socket sits where the real daemon's does: <runtime>/quesynth/quesynth.sock.
// A request is `1 <id> <command>`. `answer(command, peer, id)` returns the text
// that follows `1 <id> ` in the reply, or undefined to send nothing itself.
export async function daemonFixture(t, answer = () => "ok") {
  const runtime = await mkdtemp(join(tmpdir(), "qmcp-"));
  await mkdir(join(runtime, "quesynth"));
  const socket = join(runtime, "quesynth", "quesynth.sock");
  const commands = [];
  const peers = new Set();
  let server;

  function serve(peer) {
    peers.add(peer);
    peer.on("close", () => peers.delete(peer));
    let pending = Buffer.alloc(0);
    peer.on("data", chunk => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
        const n = pending.readUInt32LE(0);
        const text = pending.subarray(4, 4 + n).toString("utf8");
        pending = pending.subarray(4 + n);
        const match = /^1 (\d+) ([^]*)$/.exec(text);
        if (!match) throw new Error(`Unexpected control frame: ${text}`);
        commands.push(match[2]);
        const reply = answer(match[2], peer, Number(match[1]));
        if (reply === undefined) continue;
        const bytes = frame(`1 ${match[1]} ${reply}`);
        // Fragmentation must be handled by the shared QCP framing.
        peer.write(bytes.subarray(0, 3));
        peer.write(bytes.subarray(3));
      }
    });
  }

  async function start() {
    server = net.createServer(serve);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(socket, resolve);
    });
  }

  async function stop() {
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
  }

  await start();
  t.after(async () => {
    await stop();
    await rm(runtime, { recursive: true, force: true });
  });
  return { runtime, socket, commands, start, stop };
}

// The daemon's side of the parameter protocol, small enough to read at a glance:
// a revision that moves once per applied batch, and set_many that validates the
// whole batch before changing anything and refuses a stale expected_revision.
export function synthModel() {
  const parameters = [
    { id: "filter.cutoff", group: "filter", index: 19, min: 0, max: 127, default: 81, label: "Cutoff" },
    { id: "filter.resonance", group: "filter", index: 20, min: 0, max: 127, default: 0, label: "Resonance" },
    { id: "osc1.shape", group: "osc1", index: 0, min: 0, max: 3, default: 2, label: "Shape" },
  ];
  const model = {
    revision: 0,
    values: Object.fromEntries(parameters.map(p => [p.id, p.default])),
    parameters,
    patch: "slot=-1 bank_rev=0 revision=0 source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=",
    answer(command) {
      const [verb, ...tokens] = command.split(/\s+/);
      if (command === "state.snapshot") {
        const records = parameters.map(p => `id=${p.id} value=${model.values[p.id]}`);
        return [`ok revision=${model.revision} count=${parameters.length}`, ...records].join("\n");
      }
      if (command === "parameter.list") {
        const records = parameters.map(p =>
          `id=${p.id} group=${p.group} index=${p.index} min=${p.min} max=${p.max} default=${p.default} label=${p.label}`);
        return [`ok count=${parameters.length}`, ...records].join("\n");
      }
      if (command === "patch.current") return `ok ${model.patch}`;
      if (verb !== "parameter.set_many") return "err unknown_command unknown command";
      const expected = /^expected_revision=(\d+)$/.exec(tokens[0] ?? "");
      if (expected) tokens.shift();
      if (expected && Number(expected[1]) !== model.revision) return `err revision_conflict current_revision=${model.revision}`;
      if (tokens.length === 0 || tokens.length % 2 !== 0) return "err invalid_payload set_many needs id value pairs";
      const edits = [];
      for (let i = 0; i < tokens.length; i += 2) {
        const parameter = parameters.find(p => p.id === tokens[i]);
        if (!parameter) return `err unknown_parameter ${tokens[i]}`;
        const value = Number(tokens[i + 1]);
        if (!Number.isInteger(value) || value < parameter.min || value > parameter.max) return `err out_of_range ${tokens[i]}`;
        edits.push([parameter.id, value]);
      }
      for (const [id, value] of edits) model.values[id] = value;
      model.revision += 1;
      return `ok count=${edits.length} revision=${model.revision}`;
    },
  };
  return model;
}
