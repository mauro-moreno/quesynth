import test from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { quesynthBinary, skip } from "../mcp/support/binary.mjs";

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

test("the Node MCP server is gone and no document still describes its tools or flags", () => {
  for (const file of ["serve.js", "tools.js"]) {
    assert.ok(!existsSync(path.join(root, "hosts/standalone/mcp", file)), `hosts/standalone/mcp/${file} still exists`);
  }
  // The tool names of the removed Node server. `archive_bank` is left out
  // because patch.current has a field of that name.
  const removed = ["daemon_status", "daemon_info", "parameter_list", "parameter_get", "parameter_set",
    "patch_current", "patch_load", "patch_load_file", "bank_list", "bank_load_file", "archive_current",
    "archive_open", "archive_banks", "archive_patches", "archive_load", "archive_close", "midi_list",
    "midi_current", "midi_select", "midi_send"];
  for (const file of ["README.md", "CONTRIBUTING.md", "docs/quesynth-manual.md", "docs/quesynth.1"]) {
    const text = read(file);
    for (const name of removed) assert.ok(!new RegExp(`\\b${name}\\b`).test(text), `${file} still names the tool ${name}`);
    for (const stale of ["mcp/serve.js", "mcp/tools.js", "--timeout-ms"]) {
      assert.ok(!text.includes(stale), `${file} still mentions ${stale}`);
    }
  }
  assert.ok(!/needed\s+only for `--browser` and for the MCP/.test(manual), "the manual still says MCP needs Node.js");
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
  for (const name of ["inspect_synth", "apply_parameters", "quesynth://parameters", "quesynth://patch"]) {
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

test("the manual's tools and resources are the ones the built binary lists", { skip }, async t => {
  const server = startServer(t, await runtimeDir(t));
  await server.initialize();
  const tools = (await server.call({ jsonrpc: "2.0", id: 1, method: "tools/list" })).result.tools;
  const resources = (await server.call({ jsonrpc: "2.0", id: 2, method: "resources/list" })).result.resources;

  const toolsPart = part(manual, "### Tools");
  const rows = [...toolsPart.matchAll(/^\| `([a-z_]+)` \|/gm)].map(m => m[1]);
  assert.deepEqual(rows.sort(), tools.map(tool => tool.name).sort());
  const schemas = jsonFences(toolsPart);
  for (const tool of tools) {
    assert.ok(schemas.some(schema => isDeepStrictEqual(schema, tool.inputSchema)), `the manual does not show the input schema of ${tool.name}`);
  }

  const resourceRows = [...part(manual, "### Resources").matchAll(/^\| `(quesynth:\/\/[a-z]+)` \| `([a-z]+)` \|/gm)].map(m => [m[1], m[2]]);
  assert.deepEqual(resourceRows.sort(), resources.map(r => [r.uri, r.name]).sort());
  for (const resource of resources) assert.equal(resource.mimeType, "application/json");
  assert.equal((await server.finish()).code, 0);
});

test("the manual's session without a daemon is what the built binary answers", { skip }, async t => {
  const server = startServer(t, await runtimeDir(t));
  assert.ok(await replay(server, jsonFences(part(mcpSection, "#### Without a daemon"))) >= 2);
  // What else needs no daemon still answers, and the server leaves quietly.
  assert.equal((await server.call({ jsonrpc: "2.0", id: "t", method: "tools/list" })).result.tools.length, 2);
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
  assert.equal((await ask("tools/list")).result.tools.length, 2);
  for (const method of ["resources/templates/list", "prompts/list", "nope"]) assert.equal(code(await ask(method)), -32601, method);
  assert.equal(code(await ask("tools/call", {})), -32602);
  assert.equal(code(await ask("tools/call", { name: "daemon_status", arguments: {} })), -32602);
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
    '{"jsonrpc":"2.0","method":"ping","id":null}', '{"jsonrpc":"2.0","method":"ping","id":{}}'];
  for (const line of lines) raw.child.stdin.write(line + "\n");
  raw.child.stdin.write('{"jsonrpc":"2.0","id":9,"method":"ping"}');
  const done = await raw.finish();
  assert.deepEqual(done.replies.map(reply => reply.error?.code ?? reply.result), [-32700, -32600, -32600, -32600, -32600, -32600, -32600, {}]);
  assert.deepEqual(done.replies.slice(0, -1).map(reply => reply.id), lines.map(() => null));
  assert.equal(done.replies.at(-1).id, 9);
  assert.deepEqual([done.code, done.stderr], [0, ""]);
});
