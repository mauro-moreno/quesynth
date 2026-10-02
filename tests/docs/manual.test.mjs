import test from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { quesynthBinary, skip } from "../mcp/support/binary.mjs";
import { CALLS, handlerCommands } from "../mcp/support/surface.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const read = file => readFileSync(path.join(root, file), "utf8");

const docs = ["README.md", "docs/quesynth-manual.md"];
const manual = read("docs/quesynth-manual.md");
const readme = read("README.md");
const man = read("docs/quesynth.1");
const mainSource = read("hosts/standalone/main.odin");
const mcpConfig = JSON.parse(read(".mcp.json"));

const fences = text => [...text.matchAll(/^```(\w*)\n([\s\S]*?)^```$/gm)].map(m => ({ lang: m[1], body: m[2] }));
const prose = text => text.replace(/^```[\s\S]*?^```$/gm, "");
const slug = heading => heading.toLowerCase().replace(/`/g, "").replace(/[^\w\- ]/g, "").replace(/ /g, "-");
const anchors = text => [...prose(text).matchAll(/^#{1,6} +(.+)$/gm)].map(m => slug(m[1].trim()));
// The text under a heading, up to the next heading of the same or a higher level.
const part = (text, heading) => {
  const level = heading.match(/^#+/)[0].length;
  const start = text.indexOf(`\n${heading}\n`);
  assert.ok(start >= 0, `no "${heading}" heading`);
  const rest = text.slice(start + 1 + heading.length);
  const next = rest.search(new RegExp(`\\n#{1,${level}} `));
  return next < 0 ? rest : rest.slice(0, next);
};
const mcpSection = part(manual, "## MCP server");
const jsonFences = text => fences(text).filter(f => f.lang === "json").map(f => JSON.parse(f.body));
const jsonBlock = (text, needle) => {
  const block = fences(text).find(f => f.lang === "json" && f.body.includes(needle));
  assert.ok(block, `no json block containing ${needle}`);
  return JSON.parse(block.body);
};

// The manual's table of tools: one row for each tool, in the order it is listed.
const toolsPart = part(manual, "### Tools");
const toolRows = [...toolsPart.matchAll(/^\| `([a-z_]+)` \| (.+?) \| (.+?) \| (yes|no) \| (yes|no) \| (yes|no) \|$/gm)].map(m => ({
  name: m[1],
  commands: [...m[2].matchAll(/`([a-z._]+)`/g)].map(command => command[1]),
  arguments: m[3],
  readOnly: m[4] === "yes",
  destructive: m[5] === "yes",
  idempotent: m[6] === "yes",
}));
const originalTools = ["inspect_synth", "apply_parameters"];
const MAX_SAFE = 9007199254740991;
// The man page's source with its escaped hyphens read as plain ones.
const manText = man.replace(/\\-/g, "-");
// The man page's text under one `.SH` heading.
const manSection = title => {
  const found = new RegExp(`^\\.SH "?${title}"?\\n([\\s\\S]*?)(?=^\\.SH |(?![\\s\\S]))`, "m").exec(manText);
  assert.ok(found, `the man page has no ${title} section`);
  return found[1];
};

// The usage text that `quesynth --help` prints, as main.odin defines it, and its
// command forms with the description column and the `<placeholder>` brackets off.
const usageText = /USAGE :: `([\s\S]*?)`/.exec(mainSource)[1];
const usageForms = usageText.split("\n").slice(1)
  .map(line => line.trim().replace(/\s{2,}.*$/, "").replace(/[<>]/g, ""));

function sourceFiles(dir) {
  return readdirSync(path.join(root, dir), { withFileTypes: true }).flatMap(entry => {
    const rel = `${dir}/${entry.name}`;
    if (entry.isDirectory()) return sourceFiles(rel);
    return /\.(odin|js)$/.test(entry.name) ? [rel] : [];
  });
}

// ---- running the real binary -------------------------------------------------

// A reply as the manual shows it. The JSON text a tool or a resource carries is
// compared as JSON, so key order and spacing inside it are not differences.
const comparable = message => {
  const copy = structuredClone(message);
  for (const item of [...(copy.result?.content ?? []), ...(copy.result?.contents ?? [])]) {
    if (typeof item.text === "string" && item.text.startsWith("{")) item.text = JSON.parse(item.text);
  }
  return copy;
};

async function runtimeDir(t) {
  // Short, because a Unix socket path has a length limit.
  const dir = await mkdtemp(path.join(tmpdir(), "qsd-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

// `quesynth --mcp` as an MCP client starts it. `runtime` is the XDG_RUNTIME_DIR
// it finds the daemon's socket under.
function startServer(t, runtime) {
  const child = spawn(quesynthBinary(), ["--mcp"], {
    env: { ...process.env, XDG_RUNTIME_DIR: runtime }, stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  const waiting = new Map();
  const replies = [];
  createInterface({ input: child.stdout }).on("line", line => {
    const message = JSON.parse(line);
    replies.push(message);
    waiting.get(message.id)?.(message);
  });
  const exited = new Promise(resolve => child.on("exit", (code, signal) => resolve({ code, signal })));
  t.after(() => child.kill());
  const send = message => child.stdin.write(JSON.stringify(message) + "\n");
  const call = message => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no reply to ${message.method} ${message.id}; stderr: ${stderr}`)), 5000);
    waiting.set(message.id, reply => { clearTimeout(timer); resolve(reply); });
    send(message);
  });
  const initialize = async (protocolVersion = "2025-11-25") => {
    const reply = await call({ jsonrpc: "2.0", id: "init", method: "initialize",
      params: { protocolVersion, capabilities: {}, clientInfo: { name: "docs-test", version: "1" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    return reply;
  };
  const finish = async () => { child.stdin.end(); return { ...(await exited), stderr, replies }; };
  return { child, send, call, initialize, finish };
}

// What `tools/list` says, asked of the built binary once. It needs no daemon.
let listedTools;
function binaryTools() {
  if (!listedTools) {
    const runtime = mkdtempSync(path.join(tmpdir(), "qsd-"));
    try {
      const input = [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "docs-test", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/list" },
      ].map(message => JSON.stringify(message)).join("\n") + "\n";
      const run = spawnSync(quesynthBinary(), ["--mcp"], { input, encoding: "utf8", env: { ...process.env, XDG_RUNTIME_DIR: runtime } });
      assert.equal(run.status, 0, run.stderr);
      listedTools = run.stdout.trim().split("\n").map(line => JSON.parse(line)).find(message => message.id === 2).result.tools;
    } finally {
      rmSync(runtime, { recursive: true, force: true });
    }
  }
  return listedTools;
}

// A stand-in daemon on the socket the server looks for. Its replies are the real
// daemon's, captured from `quesynth --daemon` on a fresh start, with the two
// record lists cut to two entries. Only the rule for the revision is the stand-in's.
async function standInDaemon(t, runtime, misbehave = () => undefined) {
  await mkdir(path.join(runtime, "quesynth"), { recursive: true });
  const commands = [];
  let revision = 0;
  const answer = command => {
    const [verb, ...rest] = command.split(" ");
    if (verb === "state.snapshot") {
      return `ok revision=${revision} sample_rate=48000 buffer=512 count=92\nid=osc1.shape value=2\nid=osc1.fm value=0`;
    }
    if (verb === "patch.current") {
      return `ok slot=-1 bank_rev=0 revision=${revision} source=none archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=\nname=`;
    }
    if (verb === "parameter.list") {
      return "ok count=92\nid=osc1.shape group=osc1 index=0 min=0 max=3 default=2 label=Shape\n"
        + "id=osc1.fm group=osc1 index=45 min=0 max=127 default=0 label=FM";
    }
    if (verb === "parameter.set_many") {
      const expected = /^expected_revision=(\d+)$/.exec(rest[0]);
      if (!expected) return "err invalid_payload set_many needs id value pairs";
      if (rest.length < 3) return "err invalid_payload set_many needs id value pairs";
      if (Number(expected[1]) !== revision) return `err revision_conflict current_revision=${revision}`;
      revision += 1;
      return `ok count=${(rest.length - 1) / 2} revision=${revision}`;
    }
    return "err unknown_command unknown command";
  };
  const peers = new Set();
  const server = net.createServer(peer => {
    peers.add(peer);
    peer.on("close", () => peers.delete(peer));
    let pending = Buffer.alloc(0);
    peer.on("data", chunk => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
        const size = pending.readUInt32LE(0);
        const request = /^1 (\d+) (.*)$/s.exec(pending.subarray(4, 4 + size).toString("utf8"));
        pending = pending.subarray(4 + size);
        if (!request) { peer.destroy(); return; }
        commands.push(request[2]);
        const fault = misbehave(request[2]);
        if (fault === "hang") continue;
        if (fault === "disconnect") { peer.destroy(); return; }
        const payload = Buffer.from(`1 ${request[1]} ${answer(request[2])}`);
        const frame = Buffer.alloc(4 + payload.length);
        frame.writeUInt32LE(payload.length);
        payload.copy(frame, 4);
        peer.write(frame);
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(path.join(runtime, "quesynth", "quesynth.sock"), resolve);
  });
  t.after(async () => {
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  return { commands, revision: () => revision };
}

// A stand-in daemon that answers a script: each request must be the next line of
// it, and gets the reply written beside it. It is for the session in the manual
// that was captured from a real daemon, so what it answers is what that daemon
// said, and the test checks that the server asks it the same questions in the
// same order. Like the real daemon, it removes its socket after daemon.shutdown.
async function scriptedDaemon(t, runtime, script) {
  await mkdir(path.join(runtime, "quesynth"), { recursive: true });
  const seen = [];
  const peers = new Set();
  const server = net.createServer(peer => {
    peers.add(peer);
    peer.on("close", () => peers.delete(peer));
    let pending = Buffer.alloc(0);
    peer.on("data", chunk => {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
        const size = pending.readUInt32LE(0);
        const request = /^1 (\d+) (.*)$/s.exec(pending.subarray(4, 4 + size).toString("utf8"));
        pending = pending.subarray(4 + size);
        if (!request) { peer.destroy(); return; }
        seen.push(request[2]);
        const next = script[seen.length - 1];
        const reply = next?.[0] === request[2] ? next[1] : `err internal_error not the next request of the script: ${request[2]}`;
        const payload = Buffer.from(`1 ${request[1]} ${reply}`);
        const frame = Buffer.alloc(4 + payload.length);
        frame.writeUInt32LE(payload.length);
        payload.copy(frame, 4);
        peer.write(frame);
        if (request[2] === "daemon.shutdown") server.close();
      }
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(path.join(runtime, "quesynth", "quesynth.sock"), resolve);
  });
  t.after(async () => {
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  return { seen };
}

// Replays the requests of a documented session and checks each reply against the
// one the manual shows right after it.
async function replay(server, exchanges) {
  let replayed = 0;
  for (let i = 0; i < exchanges.length; i++) {
    if (exchanges[i].method === undefined) continue;
    if (exchanges[i].id === undefined) { server.send(exchanges[i]); continue; }
    assert.deepEqual(comparable(await server.call(exchanges[i])), comparable(exchanges[i + 1]), JSON.stringify(exchanges[i]));
    replayed++;
  }
  return replayed;
}

// ---- links, anchors and file facts ------------------------------------------

test("every relative link and anchor in the README and the manual resolves", () => {
  for (const doc of docs) {
    const links = [...prose(read(doc)).matchAll(/\]\(([^)\s]+)\)/g)].map(m => m[1])
      .filter(link => !/^[a-z][a-z0-9+.-]*:/i.test(link));
    assert.ok(links.length > 0, doc);
    for (const link of links) {
      const [file, fragment] = link.split("#");
      const target = path.resolve(root, path.dirname(doc), file || path.basename(doc));
      assert.ok(existsSync(target), `${doc} links to missing ${link}`);
      if (fragment && target.endsWith(".md")) {
        assert.ok(anchors(readFileSync(target, "utf8")).includes(fragment), `${doc} links to missing anchor ${link}`);
      }
    }
  }
});

test("the README points to the manual, the man page and the .mcp.json that exist", () => {
  assert.match(readme, /\]\(docs\/quesynth-manual\.md\)/);
  assert.match(readme, /\]\(docs\/quesynth-manual\.md#mcp-server\)/);
  assert.match(readme, /\]\(docs\/quesynth\.1\)/);
  assert.match(readme, /\]\(\.mcp\.json\)/);
  assert.ok(existsSync(path.join(root, ".mcp.json")));
  assert.ok(readme.includes("`quesynth --mcp`"));
});

test("the manual's .mcp.json snippet is the repository's, and it launches `quesynth --mcp`", () => {
  assert.deepEqual(jsonBlock(mcpSection, '"mcpServers"'), mcpConfig);
  assert.deepEqual(mcpConfig, { mcpServers: { quesynth: { command: "quesynth", args: ["--mcp"] } } });
  assert.ok(mainSource.includes('"--mcp"'), "main.odin does not accept --mcp");
});

test("the Node MCP server is gone and no document still describes its files or flags", () => {
  for (const file of ["serve.js", "tools.js"]) {
    assert.ok(!existsSync(path.join(root, "hosts/standalone/mcp", file)), `hosts/standalone/mcp/${file} still exists`);
  }
  for (const file of ["README.md", "CONTRIBUTING.md", "docs/quesynth-manual.md", "docs/quesynth.1"]) {
    const text = read(file);
    for (const stale of ["mcp/serve.js", "mcp/tools.js", "--timeout-ms"]) {
      assert.ok(!text.includes(stale), `${file} still mentions ${stale}`);
    }
  }
  assert.ok(!/needed\s+only for `--browser` and for the MCP/.test(manual), "the manual still says MCP needs Node.js");
});

test("no document still says the server has two tools, cannot write, or has no annotations", () => {
  const stale = [/exactly two tools/i, /offers two tools/i, /\btwo tools\b/i, /cannot load a patch/i, /not reachable from MCP/i,
    /no `?outputSchema/i, /no tool annotations/i, /not described by an `?outputSchema/i, /skip failed calls/i, /read-only\s+resources\s+and\s+nothing\s+else/i];
  for (const file of ["README.md", "CONTRIBUTING.md", "docs/quesynth-manual.md", "docs/quesynth.1", "docs/architecture.md",
    "hosts/standalone/browser/README.md", "hosts/wasm/README.md"]) {
    const text = read(file).replace(/\s+/g, " ");
    for (const pattern of stale) assert.ok(!pattern.test(text), `${file} still says ${pattern}`);
  }
});

test("every json block in the manual is valid JSON", () => {
  const blocks = fences(manual).filter(f => f.lang === "json");
  assert.ok(blocks.length >= 20, `only ${blocks.length} json blocks`);
  for (const { body } of blocks) assert.doesNotThrow(() => JSON.parse(body), body.slice(0, 80));
});

// ---- command line and environment -------------------------------------------

test("the manual shows exactly the command forms main.odin prints for --help", () => {
  const block = fences(manual).find(f => f.lang === "sh" && f.body.includes("--selftest patch.sy1 out.wav\n") && f.body.includes("--stop"));
  assert.ok(block, "no command forms block");
  const shown = block.body.split("\n").filter(Boolean).map(line => line.replace(/^\.\/build\//, ""));
  assert.deepEqual([...shown].sort(), usageForms.filter(Boolean).sort());
  assert.ok(shown.includes("quesynth --mcp"));
});

test("every --flag the manual shows is one the matching program accepts", () => {
  const sources = { quesynth: mainSource, browser: read("hosts/standalone/browser/serve.js") };
  const accepted = (source, flag) => source.includes(`"${flag}"`);
  const flags = text => [...text.matchAll(/--[a-z][a-z-]*/g)].map(m => m[0]);
  for (const flag of flags(manual)) {
    assert.ok(Object.values(sources).some(source => accepted(source, flag)), `no program accepts ${flag}`);
  }
  let checked = 0;
  for (const { body } of fences(manual).filter(f => f.lang === "sh")) {
    for (const line of body.split("\n").map(l => l.replace(/#.*/, "").trim())) {
      const node = /^node hosts\/standalone\/browser\/serve\.js\b/.test(line);
      const quesynth = /^(\.\/build\/)?quesynth\b/.test(line);
      if (!node && !quesynth) continue;
      for (const flag of flags(line)) {
        assert.ok(accepted(node ? sources.browser : sources.quesynth, flag), `${line}: ${flag}`);
        checked++;
      }
    }
  }
  assert.ok(checked >= 10);
  // `quesynth --mcp` takes no options, and the Node server's --socket and --timeout-ms are gone.
  assert.deepEqual([...new Set(flags(mcpSection))].sort(), ["--daemon", "--mcp", "--stop"]);
});

test("every environment variable the manual and the man page name is read somewhere in the source", () => {
  const names = new Set([...manual.matchAll(/\b(?:QUESYNTH_[A-Z_]+|XDG_[A-Z_]+|NO_COLOR)\b/g)].map(m => m[0]));
  const manNames = new Set([...manText.matchAll(/\b(?:QUESYNTH_[A-Z_]+|XDG_[A-Z_]+|NO_COLOR|HOME)\b/g)].map(m => m[0]));
  const files = [...sourceFiles("hosts"), ...sourceFiles("src")].filter(f => !f.includes("/wasm/"));
  const text = files.map(read);
  for (const name of new Set([...names, ...manNames])) {
    assert.ok(text.some(t => new RegExp(`["'.]${name}\\b`).test(t)), `${name} is not read in the source`);
  }
  assert.ok(names.has("QUESYNTH_ROOT") && names.has("QUESYNTH_SOCKET"));
  const readsSocket = files.filter(f => f.endsWith(".odin") && read(f).includes("QUESYNTH_SOCKET"));
  assert.deepEqual(readsSocket, [], "the manual says the Odin binary ignores QUESYNTH_SOCKET");
});

// ---- the man page -----------------------------------------------------------

test("the man page names every mode of --help, the MCP tools, an environment, files and exit statuses", () => {
  const synopsis = manSection("SYNOPSIS");
  const modes = usageForms.filter(line => line.startsWith("quesynth")).map(line => line.split(" ")[1])
    .filter(word => word.startsWith("--") && word !== "--bank");
  assert.deepEqual([...modes].sort(), ["--browser", "--daemon", "--mcp", "--selftest", "--stop"]);
  for (const mode of modes) assert.ok(synopsis.includes(mode), `the man page SYNOPSIS lacks ${mode}`);
  for (const title of ["NAME", "SYNOPSIS", "DESCRIPTION", "MCP", "ENVIRONMENT", "FILES", "EXIT STATUS", "SEE ALSO"]) manSection(title);
  for (const status of ["0", "1", "2"]) assert.ok(manSection("EXIT STATUS").includes(`\n.B ${status}\n`), `EXIT STATUS lacks ${status}`);
  assert.equal(toolRows.length, 33);
  // Each tool has its own entry, `.TP` then `.B <name>` on a line by itself.
  for (const { name } of toolRows) {
    assert.ok(new RegExp(`^\\.TP\\n\\.B ${name}$`, "m").test(manSection("MCP")), `the man page has no entry for ${name}`);
  }
  for (const name of ["quesynth://parameters", "quesynth://patch"]) {
    assert.ok(manSection("MCP").includes(name), `the man page does not name ${name}`);
  }
});

const groff = spawnSync("groff", ["--version"], { encoding: "utf8" });
test("the man page is clean under groff -man -ww", {
  skip: groff.error ? "groff is not installed, so the man page syntax was NOT checked on this machine" : false,
}, () => {
  const run = spawnSync("groff", ["-man", "-ww", "-z", path.join(root, "docs/quesynth.1")], { encoding: "utf8" });
  assert.equal(run.stderr, "");
  assert.equal(run.status, 0);
});

// ---- the real binary --------------------------------------------------------

test("`quesynth --help` prints the usage the manual follows, and --mcp takes no operand", { skip }, () => {
  const help = spawnSync(quesynthBinary(), ["--help"], { encoding: "utf8" });
  assert.equal(help.status, 0);
  assert.equal(help.stdout, usageText + "\n");
  assert.ok(help.stdout.includes("quesynth --mcp"));
  const extra = spawnSync(quesynthBinary(), ["--mcp", "extra"], { encoding: "utf8" });
  assert.equal(extra.status, 2);
  assert.match(extra.stderr, /unexpected extra argument "extra"/);
  assert.equal(extra.stdout, "");
});

// ---- the tools --------------------------------------------------------------

test("the manual's tool table lists every tool the binary lists, once and in its order, with its annotations", { skip }, async t => {
  const tools = binaryTools();
  assert.deepEqual(toolRows.map(row => row.name), tools.map(tool => tool.name));
  assert.equal(new Set(toolRows.map(row => row.name)).size, tools.length, "a tool is in the table twice");
  const hints = ["destructiveHint", "idempotentHint", "openWorldHint", "readOnlyHint"];
  for (const tool of tools) {
    const row = toolRows.find(candidate => candidate.name === tool.name);
    assert.deepEqual(Object.keys(tool.annotations).sort(), hints, `${tool.name} annotations`);
    for (const hint of hints) assert.equal(typeof tool.annotations[hint], "boolean", `${tool.name} ${hint}`);
    assert.equal(tool.annotations.openWorldHint, false, `${tool.name} openWorldHint`);
    assert.deepEqual(
      [row.readOnly, row.destructive, row.idempotent],
      [tool.annotations.readOnlyHint, tool.annotations.destructiveHint, tool.annotations.idempotentHint],
      `the manual's hints for ${tool.name}`,
    );
    assert.ok(tool.description.length > 0 && tool.inputSchema.type === "object" && tool.outputSchema.type === "object", tool.name);
  }
  // The same list at every protocol version: neither the annotations nor the schemas depend on it.
  for (const version of ["2024-11-05", "2025-03-26", "2025-06-18", "1999-01-01"]) {
    const server = startServer(t, await runtimeDir(t));
    await server.initialize(version);
    assert.deepEqual((await server.call({ jsonrpc: "2.0", id: 1, method: "tools/list" })).result.tools, tools, version);
    await server.finish();
  }
});

test("every command control_handle dispatches has exactly one tool in the manual, and a new command fails until it has", () => {
  const commands = handlerCommands(read("hosts/standalone/command_handler.odin"));
  const rows = toolRows.filter(row => !originalTools.includes(row.name));
  for (const row of rows) assert.equal(row.commands.length, 1, `${row.name} names one command`);
  assert.deepEqual(rows.map(row => row.commands[0]).sort(), [...commands].sort());
  assert.equal(new Set(commands).size, commands.length);
  for (const row of toolRows.filter(row => originalTools.includes(row.name))) {
    for (const command of row.commands) assert.ok(commands.includes(command), `${row.name}: ${command} is not a command`);
  }
  // The name rule the manual states: the command with its dot written as an underscore, except midi.
  for (const row of rows) assert.equal(row.name, row.commands[0] === "midi" ? "midi_send" : row.commands[0].replace(".", "_"));
});

test("each tool sends the command the manual names, and nothing else", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await standInDaemon(t, runtime);
  const server = startServer(t, runtime);
  await server.initialize();
  const tools = binaryTools();
  assert.deepEqual(CALLS.map(([name]) => name).sort(), tools.map(tool => tool.name).filter(name => !originalTools.includes(name)).sort());
  let id = 0;
  const call = (name, args) => server.call({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } });
  for (const [name, args] of CALLS) {
    const before = daemon.commands.length;
    await call(name, args);
    const sent = daemon.commands.slice(before);
    assert.deepEqual(sent.map(line => line.split(" ")[0]), toolRows.find(row => row.name === name).commands, name);
  }
  const before = daemon.commands.length;
  await call("inspect_synth", {});
  await call("apply_parameters", { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 1 }] });
  assert.deepEqual(daemon.commands.slice(before).map(line => line.split(" ")[0]),
    [...toolRows.find(row => row.name === "inspect_synth").commands, ...toolRows.find(row => row.name === "apply_parameters").commands]);
});

test("the manual's argument column, patterns and schemas are the ones tools/list returns", { skip }, () => {
  const tools = binaryTools();
  const shown = {};
  for (const m of toolsPart.matchAll(/^(token|text|optional text|set_many id) {2,}(\^\S+\$)$/gm)) shown[m[1]] = m[2];
  assert.deepEqual(Object.keys(shown).sort(), ["optional text", "set_many id", "text", "token"]);
  // The ids of parameter_set_many are tokens that do not begin with what the daemon reads as its guard.
  assert.equal(shown["set_many id"], `^(?!expected_revision=)${shown.token.slice(1)}`);
  const used = new Set();
  const describe = schema => {
    if (schema.type === "integer") return `integer ${schema.minimum === -schema.maximum ? `±${schema.maximum}` : `${schema.minimum}..${schema.maximum}`}`;
    if (schema.type === "string") {
      used.add(schema.pattern);
      if (schema.pattern === shown.token || schema.pattern === shown["set_many id"]) { assert.equal(schema.minLength, 1); return "token"; }
      if (schema.pattern === shown.text) { assert.equal(schema.minLength, 1); return "text"; }
      assert.equal(schema.pattern, shown["optional text"]);
      assert.equal(schema.minLength, undefined);
      return "text";
    }
    assert.equal(schema.type, "array");
    assert.equal(describe(schema.items.properties.id), "token");
    assert.equal(describe(schema.items.properties.value), `integer ±${MAX_SAFE}`);
    assert.deepEqual(schema.items.required, ["id", "value"]);
    assert.equal(schema.items.additionalProperties, false);
    assert.deepEqual(Object.keys(schema.items.properties).sort(), ["id", "value"]);
    return `pairs ${schema.minItems}..${schema.maxItems}`;
  };
  const fromSchema = schema => Object.entries(schema.properties)
    .map(([name, property]) => `${name} ${describe(property)}${schema.required?.includes(name) ? "" : " optional"}`).sort();
  const fromManual = cell => (cell === "none" ? [] : cell.split("; ").map(item => {
    const m = /^`([a-z0-9_]+)` (.+?)(, optional)?$/.exec(item);
    assert.ok(m, `cannot read the argument ${item}`);
    return `${m[1]} ${m[2]}${m[3] ? " optional" : ""}`;
  }).sort());

  for (const tool of tools.filter(candidate => !originalTools.includes(candidate.name))) {
    const row = toolRows.find(candidate => candidate.name === tool.name);
    assert.equal(tool.inputSchema.type, "object");
    assert.equal(tool.inputSchema.additionalProperties, false, `${tool.name} is a closed object`);
    for (const name of tool.inputSchema.required ?? []) assert.ok(name in tool.inputSchema.properties, `${tool.name}: ${name}`);
    assert.deepEqual(fromManual(row.arguments), fromSchema(tool.inputSchema), `the manual's arguments for ${tool.name}`);
    const entry = tool.inputSchema.properties.parameters?.items;
    if (entry) assert.equal(entry.properties.id.pattern === shown["set_many id"], tool.name === "parameter_set_many", `${tool.name} pair id pattern`);
  }
  // The patterns the manual prints are exactly those in use, and no others are.
  assert.deepEqual([...used].sort(), Object.values(shown).sort());

  // The two original tools keep their schemas as written; every output schema is shown.
  const blocks = jsonFences(toolsPart);
  const isShown = schema => blocks.some(block => isDeepStrictEqual(block, schema));
  for (const name of originalTools) assert.ok(isShown(tools.find(tool => tool.name === name).inputSchema), `the manual does not show the input schema of ${name}`);
  for (const tool of tools) assert.ok(isShown(tool.outputSchema), `the manual does not show the output schema of ${tool.name}`);
  assert.equal(new Set(tools.filter(tool => !originalTools.includes(tool.name)).map(tool => JSON.stringify(tool.outputSchema))).size, 1);
  // A failed call's {code, message} is described by the same schema as a success,
  // so a client that checks structuredContent without reading isError accepts it.
  for (const tool of tools) {
    assert.equal(tool.outputSchema.additionalProperties, false, tool.name);
    assert.deepEqual(tool.outputSchema.oneOf.at(-1), { required: ["code", "message"] }, `${tool.name} describes its failure`);
    assert.equal(tool.outputSchema.properties.code.type, "string", tool.name);
    assert.equal(tool.outputSchema.properties.message.type, "string", tool.name);
  }
  assert.ok(/oneOf/.test(toolsPart) && /`code` and `message`/.test(toolsPart), "the manual does not say the schema covers a failure");
  assert.ok(blocks.some(block => isDeepStrictEqual(block, tools.find(tool => tool.name === "volume"))), "the manual does not show the entry for volume");
  // Ranges the prose states.
  const property = (name, key) => tools.find(tool => tool.name === name).inputSchema.properties[key];
  assert.deepEqual([property("patch_load", "slot").minimum, property("patch_load", "slot").maximum], [0, 127]);
  assert.deepEqual([property("volume", "milli").minimum, property("volume", "milli").maximum], [0, 1000]);
  assert.deepEqual([property("parameter_set_many", "parameters").minItems, property("parameter_set_many", "parameters").maxItems], [1, 128]);
});

test("the refusals the manual lists are what the binary says, and none of them reaches the daemon", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await standInDaemon(t, runtime);
  const server = startServer(t, runtime);
  await server.initialize();
  const rows = [...part(manual, "#### Arguments and checks").matchAll(/^\| `([a-z_]+)` \| `([^`]+)` \| `([^`]+)` \|$/gm)];
  assert.ok(rows.length >= 25, `only ${rows.length} refusals`);
  let id = 0;
  for (const [, name, args, message] of rows) {
    const reply = await server.call({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: JSON.parse(args) } });
    assert.equal(reply.result.isError, true, `${name} ${args}`);
    assert.deepEqual(JSON.parse(reply.result.content[0].text), { code: "invalid_arguments", message }, `${name} ${args}`);
  }
  assert.deepEqual(daemon.commands, [], "a refused call reached the daemon");
});

test("the manual counts a program change as destructive, and the binary marks midi_send so and not idempotent", { skip }, () => {
  const annotations = part(manual, "#### Annotations").replace(/\s+/g, " ");
  assert.ok(annotations.includes("It is `true` for `midi_send`, because a program change replaces the sounding patch."));
  assert.ok(!annotations.includes("an injected MIDI message"), "the manual still lists a MIDI message as not destructive");
  const midi = binaryTools().find(tool => tool.name === "midi_send");
  assert.equal(midi.annotations.destructiveHint, true);
  assert.equal(midi.annotations.idempotentHint, false);
  // What the manual lists as not destructive is still so.
  for (const name of ["volume", "midi_select", "archive_bank", "archive_adopt"]) {
    assert.equal(binaryTools().find(tool => tool.name === name).annotations.destructiveHint, false, name);
  }
});

test("the manual's rules for omitted arguments and for the zero-width characters hold for the binary", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await standInDaemon(t, runtime);
  const server = startServer(t, runtime);
  await server.initialize();
  const checks = mcpSection.replace(/\s+/g, " ");
  for (const claim of [
    "A `count` with no `offset` starts at offset 0.",
    "With no `path`, or an empty one, it opens the remembered archive again.",
    "Without a `name`, or with an empty one, the slot keeps its current name, which is `Init` for an empty slot.",
    "U+200B, U+200E, U+200F and U+FEFF are allowed anywhere in a text and not in a token.",
    "An optional one that is an empty string counts as left out.",
  ]) assert.ok(checks.includes(claim), `the manual no longer says: ${claim}`);

  let id = 0;
  const call = (name, args) => server.call({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } });
  for (const [name, args] of [["archive_banks", { count: 5 }], ["archive_patches", { offset: 2 }], ["archive_open", {}], ["archive_open", { path: "" }],
    ["patch_save", { slot: 1 }], ["patch_save", { slot: 1, name: "" }]]) await call(name, args);
  assert.deepEqual(daemon.commands, ["archive.banks 0 5", "archive.patches 2", "archive.open", "archive.open", "patch.save 1", "patch.save 1"]);

  daemon.commands.length = 0;
  for (const point of ["\u200b", "\u200e", "\u200f", "\ufeff"]) {
    const refused = (await call("parameter_get", { id: `filter${point}.cutoff` })).result;
    assert.equal(JSON.parse(refused.content[0].text).code, "invalid_arguments", `U+${point.codePointAt(0).toString(16)} in a token`);
    for (const [name, args, line] of [["patch_save", { slot: 1, name: `a${point}b` }, `patch.save 1 a${point}b`],
      ["bank_write", { path: `${point}x.json${point}` }, `bank.write ${point}x.json${point}`]]) {
      const sent = daemon.commands.length;
      await call(name, args);
      assert.deepEqual(daemon.commands.slice(sent), [line], `U+${point.codePointAt(0).toString(16)} in a text`);
    }
  }
  // Whitespace that the daemon trims is refused at either end of a text, and is fine inside it
  // unless it is a control character, which a tab and U+0085 are.
  const before = daemon.commands.length;
  const trimmed = ["\t", " ", "\u0085", "\u00a0", "\u1680", "\u2000", "\u200a", "\u202f", "\u205f", "\u3000"];
  for (const point of trimmed) {
    for (const path of [`${point}a`, `a${point}`]) {
      assert.equal(JSON.parse((await call("bank_write", { path })).result.content[0].text).code, "invalid_arguments", JSON.stringify(path));
    }
  }
  assert.equal(daemon.commands.length, before, "a path with whitespace at an end reached the daemon");
  const inside = trimmed.filter(point => point !== "\t" && point !== "\u0085");
  for (const point of inside) await call("bank_write", { path: `a${point}b` });
  assert.deepEqual(daemon.commands.slice(before), inside.map(point => `bank.write a${point}b`));
});

test("a refusal by the daemon comes through with its token and its message, and an empty message when it gave none", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await scriptedDaemon(t, runtime, [["parameter.get filter.cutoff", "err invalid_payload"], ["patch.load 100", "err unknown_parameter slot is empty"]]);
  const server = startServer(t, runtime);
  await server.initialize();
  const failure = async (name, args) => {
    const reply = (await server.call({ jsonrpc: "2.0", id: name, method: "tools/call", params: { name, arguments: args } })).result;
    assert.equal(reply.isError, true);
    assert.deepEqual(reply.structuredContent, JSON.parse(reply.content[0].text));
    return reply.structuredContent;
  };
  assert.deepEqual(await failure("parameter_get", { id: "filter.cutoff" }), { code: "invalid_payload", message: "" });
  assert.deepEqual(await failure("patch_load", { slot: 100 }), { code: "unknown_parameter", message: "slot is empty" });
  assert.equal(daemon.seen.length, 2);
  assert.ok(mcpSection.replace(/\s+/g, " ").includes("`message` is empty if the daemon gave none"));
});

test("the number of tools the README, the manual and the man page state is the number the binary lists", { skip }, () => {
  const count = binaryTools().length;
  assert.equal(Number(/offers (\d+) typed tools/.exec(readme)?.[1]), count);
  assert.equal(Number(/`tools\/list` returns (\d+) tools/.exec(manual)?.[1]), count);
  assert.equal(Number(/There are (\d+) tools/.exec(man)?.[1]), count);
});

test("the manual's resources are the ones the built binary lists", { skip }, async t => {
  const server = startServer(t, await runtimeDir(t));
  await server.initialize();
  const resources = (await server.call({ jsonrpc: "2.0", id: 2, method: "resources/list" })).result.resources;
  const resourceRows = [...part(manual, "### Resources").matchAll(/^\| `(quesynth:\/\/[a-z]+)` \| `([a-z]+)` \|/gm)].map(m => [m[1], m[2]]);
  assert.deepEqual(resourceRows.sort(), resources.map(r => [r.uri, r.name]).sort());
  for (const resource of resources) assert.equal(resource.mimeType, "application/json");
  assert.equal((await server.finish()).code, 0);
});

test("the manual's session without a daemon is what the built binary answers", { skip }, async t => {
  const server = startServer(t, await runtimeDir(t));
  assert.ok(await replay(server, jsonFences(part(mcpSection, "#### Without a daemon"))) >= 2);
  // What else needs no daemon still answers, and the server leaves quietly.
  assert.equal((await server.call({ jsonrpc: "2.0", id: "t", method: "tools/list" })).result.tools.length, toolRows.length);
  assert.equal((await server.call({ jsonrpc: "2.0", id: "r", method: "resources/list" })).result.resources.length, 2);
  assert.deepEqual((await server.call({ jsonrpc: "2.0", id: "p", method: "ping" })).result, {});
  const exit = await server.finish();
  assert.deepEqual([exit.code, exit.signal, exit.stderr], [0, null, ""]);
});

test("the manual's session with a daemon is what the built binary answers, and sends what the manual says", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await standInDaemon(t, runtime);
  const server = startServer(t, runtime);
  assert.equal(await replay(server, jsonFences(part(mcpSection, "#### With a daemon"))), 5);
  assert.equal(daemon.revision(), 1);

  const inspect = /It sends the daemon\s+((?:`[a-z.]+`(?:,| and)?\s*)+),\s+in that order/.exec(part(manual, "#### inspect_synth"));
  assert.ok(inspect, "the manual does not say what inspect_synth sends");
  const named = [...inspect[1].matchAll(/`([a-z.]+)`/g)].map(m => m[1]);
  assert.deepEqual(named, ["state.snapshot", "patch.current", "parameter.list"]);
  assert.deepEqual(daemon.commands, [
    ...named,
    "parameter.set_many expected_revision=0 filter.cutoff 90 filter.resonance 20",
    "parameter.set_many expected_revision=0 filter.cutoff 95",
    "state.snapshot", "patch.current",
  ]);
});

// The requests and replies of the manual's session "Driving the daemon", as a
// real `quesynth --daemon` exchanged them with `quesynth --mcp`. They were
// recorded by a proxy on the socket between the two: the daemon had a fresh
// XDG_CONFIG_HOME, a null ALSA device and a working directory that held
// corpus.zip (tests/zip/fixtures/nested.zip). Only the calls that reach the
// daemon are here; the manual's other two calls are answered by the server.
const driving = [
  ["daemon.status", "ok state=running proto=1 revision=0"],
  ["midi.select none", "ok selected=none midi_rev=1"],
  ["volume 0", "ok volume=0"],
  ["parameter.get filter.cutoff", "ok value=81 revision=0"],
  ["parameter.set_many expected_revision=0 filter.cutoff 70 filter.resonance 10", "ok count=2 revision=1"],
  ["parameter.set_many expected_revision=0 filter.cutoff 71", "err revision_conflict current_revision=1"],
  ["patch.save 5 Warm Pad", "ok slot=5 name=Warm_Pad bank_rev=1"],
  ["patch.load 5", "ok slot=5 name=Warm_Pad count=99 revision=1"],
  ["patch.current", "ok slot=5 bank_rev=1 revision=2 source=bank archive_rev=0 archive_bank=-1 archive_patch=-1\nbank=Factory\nname=Warm Pad"],
  ["patch.load 100", "err unknown_parameter slot is empty"],
  ["midi 144 60 100", "ok"],
  ["midi 128 60 0", "ok"],
  ["archive.open corpus.zip", "ok banks=1 archive_rev=1"],
  ["archive.banks", "ok total=1 archive_rev=1\nbank=0 name=bankA.zip"],
  ["archive.bank 0", "ok patches=2 bank=0 archive_rev=2"],
  ["archive.patches", "ok total=2 bank=0 archive_rev=2\npatch=0 name=Test Patch One\npatch=1 name=Test Patch Two"],
  ["archive.load 1", "ok count=3 revision=2 bank=0 patch=1"],
  ["archive.close", "ok archive_rev=3"],
  ["daemon.shutdown", "ok"],
];

test("the manual's session driving the whole surface is what the built binary answers, and it asks the daemon these questions", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await scriptedDaemon(t, runtime, driving);
  const server = startServer(t, runtime);
  await server.initialize();
  const exchanges = jsonFences(part(mcpSection, "#### Driving the daemon"));
  assert.equal(await replay(server, exchanges), 22);
  assert.deepEqual(daemon.seen, driving.map(([line]) => line));
  const exit = await server.finish();
  assert.deepEqual([exit.code, exit.signal, exit.stderr], [0, null, ""]);

  // Each thing the section sets out to show is in it.
  const called = exchanges.filter(message => message.method === "tools/call").map(message => message.params.name);
  for (const name of ["daemon_status", "midi_select", "volume", "parameter_get", "parameter_set_many", "patch_save", "patch_load",
    "patch_current", "bank_write", "midi_send", "archive_open", "archive_banks", "archive_bank", "archive_patches", "archive_load",
    "archive_close", "daemon_shutdown"]) assert.ok(called.includes(name), `the session does not call ${name}`);
  assert.equal(called.at(-1), "daemon_status", "the session does not end on a call after daemon_shutdown");
  assert.equal(exchanges.at(-1).result.structuredContent.code, "daemon_unavailable");
});

test("apply_parameters checks what the manual says before it contacts the daemon, and passes the rest on", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const daemon = await standInDaemon(t, runtime);
  const server = startServer(t, runtime);
  await server.initialize();
  let id = 0;
  const call = args => server.call({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name: "apply_parameters", arguments: args } });
  const apply = async args => {
    const reply = await call(args);
    return reply.result.isError ? JSON.parse(reply.result.content[0].text) : reply.result.structuredContent;
  };
  const one = [{ id: "filter.cutoff", value: 1 }];
  const withId = value => ({ expected_revision: 0, parameters: [{ id: value, value: 1 }] });
  const refused = [
    {}, { parameters: one }, { expected_revision: 0 }, { expected_revision: -1, parameters: one },
    { expected_revision: 0.5, parameters: one }, { expected_revision: "0", parameters: one },
    { expected_revision: 0, parameters: "x" }, { expected_revision: 0, parameters: [1] },
    { expected_revision: 0, parameters: [{ value: 1 }] }, { expected_revision: 0, parameters: [{ id: "filter.cutoff" }] },
    { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 1.5 }] },
    { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: "1" }] },
    withId(""), withId("filter cutoff"), withId("filter.cutoff\n"), withId("filter\u007f.cutoff"),
    withId("filter\u0085.cutoff"), withId("filter\u00a0.cutoff"), withId("filter\u2028.cutoff"), withId("filter\u0000.cutoff"),
    { expected_revision: 9007199254740992, parameters: one },
    { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 9007199254740992 }] },
    { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: -9007199254740992 }] },
    { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 1e300 }] },
  ];
  for (const args of refused) assert.equal((await apply(args)).code, "invalid_arguments", JSON.stringify(args));
  assert.equal(JSON.parse((await call([])).result.content[0].text).code, "invalid_arguments", "arguments that are not an object");
  assert.deepEqual(daemon.commands, [], "a call that fails the check reached the daemon");

  // Passed on: 30.0 is the integer 30, other keys are ignored, duplicates keep their order.
  assert.deepEqual(await apply({ expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 30.0, note: "x" }], other: true }),
    { count: 1, revision: 1 });
  assert.deepEqual(await apply({ expected_revision: 1, parameters: [
    { id: "filter.cutoff", value: 10 }, { id: "filter.cutoff", value: 20 }] }), { count: 2, revision: 2 });
  assert.deepEqual(daemon.commands, [
    "parameter.set_many expected_revision=0 filter.cutoff 30",
    "parameter.set_many expected_revision=1 filter.cutoff 10 filter.cutoff 20",
  ]);
  // The largest integers a JSON number holds exactly are still sent, as written out.
  const limit = 9007199254740991;
  assert.ok(manual.includes(`±${limit}`), "the manual does not state the integer range");
  assert.deepEqual(await apply({ expected_revision: 2, parameters: [{ id: "filter.cutoff", value: limit }, { id: "filter.resonance", value: -limit }] }),
    { count: 2, revision: 3 });
  assert.equal(daemon.commands.at(-1), `parameter.set_many expected_revision=2 filter.cutoff ${limit} filter.resonance -${limit}`);
  // An empty batch is the daemon's to refuse, not the server's.
  assert.equal((await apply({ expected_revision: 3, parameters: [] })).code, "invalid_payload");
  assert.equal(daemon.commands.length, 4);
});

test("the manual says what --mcp leaves in the runtime directory, and the binary does that and no more", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const server = startServer(t, runtime);
  assert.deepEqual((await server.call({ jsonrpc: "2.0", id: 1, method: "ping" })).result, {});
  await server.finish();
  const claim = mcpSection.replace(/\s+/g, " ");
  assert.ok(claim.includes("creates the empty `quesynth` directory under `XDG_RUNTIME_DIR` (mode 0700)"), "the manual does not describe the directory");
  assert.ok(claim.includes("The server never creates the socket."));
  assert.deepEqual(readdirSync(runtime), ["quesynth"]);
  assert.equal(statSync(path.join(runtime, "quesynth")).mode & 0o777, 0o700);
  assert.deepEqual(readdirSync(path.join(runtime, "quesynth")), [], "the server left a file behind");
});

test("a failure after apply_parameters was sent says the change may have been applied, and nothing is sent twice", { skip }, async t => {
  const sent = " the request was sent and the change may have been applied";
  for (const [fault, code] of [["hang", "daemon_timeout"], ["disconnect", "daemon_error"]]) {
    const runtime = await runtimeDir(t);
    let misbehaving = true;
    const daemon = await standInDaemon(t, runtime, () => (misbehaving ? fault : undefined));
    const server = startServer(t, runtime);
    await server.initialize();
    const tool = (name, args) => server.call({ jsonrpc: "2.0", id: `${name}-${fault}`, method: "tools/call", params: { name, arguments: args } })
      .then(reply => JSON.parse(reply.result.content[0].text));

    const applied = await tool("apply_parameters", { expected_revision: 0, parameters: [{ id: "filter.cutoff", value: 1 }] });
    assert.equal(applied.code, code, fault);
    assert.ok(applied.message.endsWith(`;${sent}`), `${fault}: ${applied.message}`);
    assert.equal(daemon.commands.length, 1, "the request was sent again");

    // A read that failed has changed nothing, so it says so no more than the manual does.
    const inspected = await tool("inspect_synth", {});
    assert.equal(inspected.code, code, fault);
    assert.ok(!inspected.message.includes("may have been applied"), inspected.message);

    // The next call connects afresh and works.
    misbehaving = false;
    assert.equal((await tool("inspect_synth", {})).revision, 0);
  }
});

test("the protocol facts the manual states hold for the built binary", { skip }, async t => {
  const runtime = await runtimeDir(t);
  const server = startServer(t, runtime);
  const ask = (method, params) => server.call({ jsonrpc: "2.0", id: method, method, ...(params === undefined ? {} : { params }) });
  const code = reply => reply.error?.code;

  assert.deepEqual((await ask("ping")).result, {});
  for (const method of ["tools/list", "tools/call", "resources/list", "resources/read"]) {
    assert.equal(code(await ask(method, {})), -32000, `${method} before initialize`);
  }
  assert.equal(code(await ask("initialize", {})), -32602);
  const legacy = await ask("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "1" } });
  assert.deepEqual(legacy.result.capabilities, { tools: {}, resources: {} });
  assert.equal(legacy.result.serverInfo.name, "quesynth");
  assert.equal(code(await ask("tools/list")), -32000, "after initialize, before notifications/initialized");
  assert.equal(code(await ask("initialize", {})), -32600, "a second initialize");
  server.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  server.send({ jsonrpc: "2.0", method: "notifications/whatever" });
  assert.equal((await ask("tools/list")).result.tools.length, toolRows.length);
  for (const method of ["resources/templates/list", "prompts/list", "nope"]) assert.equal(code(await ask(method)), -32601, method);
  assert.equal(code(await ask("tools/call", {})), -32602);
  // A tool is only a tool by its name here: the daemon's own spellings and invented ones are not.
  const toolNames = toolRows.map(row => row.name);
  const spellings = [...handlerCommands(read("hosts/standalone/command_handler.odin")), "command", "qcp", "raw", "shell", "inspect-synth"]
    .filter(name => !toolNames.includes(name));
  assert.ok(spellings.includes("daemon.status") && spellings.includes("midi"));
  for (const name of spellings) {
    const refused = await ask("tools/call", { name, arguments: {} });
    assert.deepEqual([code(refused), refused.error.message], [-32602, "Unknown tool"], name);
  }
  // A real tool is answered as a result, here the failure of a call with no daemon behind it.
  const real = await ask("tools/call", { name: "daemon_status", arguments: {} });
  assert.equal(real.error, undefined);
  assert.equal(JSON.parse(real.result.content[0].text).code, "daemon_unavailable");
  assert.equal(code(await ask("resources/read", {})), -32602);
  assert.equal(code(await ask("resources/read", { uri: "quesynth://nothing" })), -32002);
  const unreachable = await ask("resources/read", { uri: "quesynth://parameters" });
  assert.equal(unreachable.error.code, -32000);
  assert.match(unreachable.error.message, /^daemon_unavailable: /);
  assert.equal(code(await ask("tools/list", [])), -32602);
  const done = await server.finish();
  assert.deepEqual([done.code, done.stderr], [0, ""]);
  // Neither notification got a reply.
  assert.ok(done.replies.every(reply => reply.id !== undefined && reply.id !== null));

  // The client's version when known, 2025-11-25 otherwise; structuredContent from 2025-06-18 on.
  for (const [asked, answered, structured] of [["2024-11-05", "2024-11-05", false], ["2025-03-26", "2025-03-26", false],
    ["2025-06-18", "2025-06-18", true], ["2025-11-25", "2025-11-25", true], ["1999-01-01", "2025-11-25", true]]) {
    const other = startServer(t, runtime);
    assert.equal((await other.initialize(asked)).result.protocolVersion, answered);
    const failed = (await other.call({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "inspect_synth", arguments: {} } })).result;
    assert.equal(failed.isError, true);
    assert.equal(JSON.parse(failed.content[0].text).code, "daemon_unavailable");
    assert.equal("structuredContent" in failed, structured, asked);
  }
});

test("lines that are not requests are answered with the JSON-RPC errors the manual lists, and a last line without a newline is answered", { skip }, async t => {
  const raw = startServer(t, await runtimeDir(t));
  const lines = ["{broken", "[]", "null", '{"jsonrpc":"1.0","method":"ping","id":1}', '{"jsonrpc":"2.0","method":7,"id":1}',
    '{"jsonrpc":"2.0","method":"ping","id":null}', '{"jsonrpc":"2.0","method":"ping","id":{}}',
    '{"jsonrpc":"2.0","id":3,"method":"ping","id":4}', '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"parameter_get","arguments":{"id":"a","\\u0069d":"b"}}}'];
  for (const line of lines) raw.child.stdin.write(line + "\n");
  raw.child.stdin.write('{"jsonrpc":"2.0","id":9,"method":"ping"}');
  const done = await raw.finish();
  assert.deepEqual(done.replies.map(reply => reply.error?.code ?? reply.result),
    [-32700, -32600, -32600, -32600, -32600, -32600, -32600, -32700, -32700, {}]);
  assert.deepEqual(done.replies.slice(0, -1).map(reply => reply.id), lines.map(() => null));
  assert.equal(done.replies.at(-1).id, 9);
  assert.deepEqual([done.code, done.stderr], [0, ""]);
});
