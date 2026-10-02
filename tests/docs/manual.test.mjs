import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const read = file => readFileSync(path.join(root, file), "utf8");
const { tools, commandFor } = createRequire(import.meta.url)("../../hosts/standalone/mcp/tools.js");

const docs = ["README.md", "docs/quesynth-manual.md"];
const manual = read("docs/quesynth-manual.md");
const mcpConfig = JSON.parse(read(".mcp.json"));
const mcpServe = "hosts/standalone/mcp/serve.js";

const fences = text => [...text.matchAll(/^```(\w*)\n([\s\S]*?)^```$/gm)].map(m => ({ lang: m[1], body: m[2] }));
const prose = text => text.replace(/^```[\s\S]*?^```$/gm, "");
const slug = heading => heading.toLowerCase().replace(/`/g, "").replace(/[^\w\- ]/g, "").replace(/ /g, "-");
const anchors = text => [...prose(text).matchAll(/^#{1,6} +(.+)$/gm)].map(m => slug(m[1].trim()));
const section = (text, title) => {
  const start = text.indexOf(`\n## ${title}\n`);
  assert.ok(start >= 0, `manual has no "${title}" section`);
  const end = text.indexOf("\n## ", start + 1);
  return text.slice(start, end < 0 ? undefined : end);
};
const mcpSection = section(manual, "MCP server");
const jsonBlock = (text, needle) => {
  const block = fences(text).find(f => f.lang === "json" && f.body.includes(needle));
  assert.ok(block, `no json block containing ${needle}`);
  return JSON.parse(block.body);
};

function sourceFiles(dir) {
  return readdirSync(path.join(root, dir), { withFileTypes: true }).flatMap(entry => {
    const rel = `${dir}/${entry.name}`;
    if (entry.isDirectory()) return sourceFiles(rel);
    return /\.(odin|js)$/.test(entry.name) ? [rel] : [];
  });
}

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

test("the manual's tool table lists exactly the tools of tools.js, with their daemon verbs", () => {
  const rows = [...mcpSection.matchAll(/^\| `([a-z_]+)` \| `([^`]+)` \|/gm)].map(m => [m[1], m[2]]);
  const sample = tool => Object.fromEntries(tool.inputSchema.required.map(key =>
    [key, tool.inputSchema.properties[key].type === "integer" ? 0 : "x"]));
  const expected = tools.map(tool => [tool.name, commandFor(tool.name, sample(tool)).split(" ")[0]]);
  assert.deepEqual(rows.sort(), expected.sort());
});

test("the manual's .mcp.json snippet is the repository's, and its launch target exists", () => {
  assert.deepEqual(jsonBlock(mcpSection, '"mcpServers"'), mcpConfig);
  const launch = mcpConfig.mcpServers.quesynth;
  assert.equal(launch.command, "node");
  assert.equal(launch.args[0], mcpServe);
  assert.ok(existsSync(path.join(root, launch.args[0])));
});

test("every --flag the manual shows is one the matching program accepts", () => {
  const sources = {
    quesynth: read("hosts/standalone/main.odin"),
    mcp: read(mcpServe),
    browser: read("hosts/standalone/browser/serve.js"),
  };
  const accepted = (source, flag) => source.includes(`"${flag}"`);
  const flags = text => [...text.matchAll(/--[a-z][a-z-]*/g)].map(m => m[0]);
  for (const flag of flags(manual)) {
    assert.ok(Object.values(sources).some(source => accepted(source, flag)), `no program accepts ${flag}`);
  }
  let checked = 0;
  for (const { lang, body } of fences(manual).filter(f => f.lang === "sh")) {
    for (const line of body.split("\n").map(l => l.replace(/#.*/, "").trim())) {
      const node = /^node (hosts\/standalone\/(mcp|browser)\/serve\.js)\b/.exec(line);
      const quesynth = /^(\.\/build\/)?quesynth\b/.test(line);
      if (!node && !quesynth) continue;
      if (node) assert.ok(existsSync(path.join(root, node[1])), line);
      for (const flag of flags(line)) {
        assert.ok(accepted(sources[node ? node[2] : "quesynth"], flag), `${line}: ${flag}`);
        checked++;
      }
    }
  }
  assert.ok(checked >= 10);
});

test("every environment variable the manual names is read somewhere in the source", () => {
  const names = new Set(manual.match(/\b(?:QUESYNTH_[A-Z_]+|XDG_[A-Z_]+|NO_COLOR)\b/g));
  const files = [...sourceFiles("hosts"), ...sourceFiles("src")].filter(f => !f.includes("/wasm/"));
  const text = files.map(read);
  for (const name of names) assert.ok(text.some(t => t.includes(name)), `${name} is not in the source`);
  assert.ok(names.has("QUESYNTH_ROOT") && names.has("QUESYNTH_SOCKET"));
  const readsSocket = files.filter(f => f.endsWith(".odin") && read(f).includes("QUESYNTH_SOCKET"));
  assert.deepEqual(readsSocket, [], "the manual says the Odin binary ignores QUESYNTH_SOCKET");
});

test("the README points to the manual and to the .mcp.json that exists", () => {
  const readme = read("README.md");
  assert.match(readme, /\]\(docs\/quesynth-manual\.md\)/);
  assert.match(readme, /\]\(docs\/quesynth-manual\.md#mcp-server\)/);
  assert.match(readme, /\]\(\.mcp\.json\)/);
  assert.ok(existsSync(path.join(root, ".mcp.json")));
  assert.ok(readme.includes(mcpConfig.mcpServers.quesynth.args[0]));
});

test("the manual's example responses have the shape the real server returns", { skip: process.platform === "win32" }, async t => {
  const request = jsonBlock(mcpSection, '"method": "tools/call"');
  assert.ok(tools.some(tool => tool.name === request.params.name));
  const examples = fences(mcpSection).filter(f => f.lang === "json").map(f => JSON.parse(f.body))
    .filter(m => m.id === request.id && m.result);
  const success = examples.find(m => !m.result.isError);
  const failure = examples.find(m => m.result.isError);
  assert.equal(JSON.stringify(success.result.structuredContent), success.result.content[0].text);
  assert.equal(typeof success.result.structuredContent.fields, "string");
  assert.ok(Array.isArray(success.result.structuredContent.lines));

  const missing = path.join(tmpdir(), `quesynth-docs-${process.pid}`, "no.sock");
  const child = spawn(process.execPath, [path.join(root, mcpServe), "--socket", missing], { stdio: ["pipe", "pipe", "inherit"] });
  t.after(() => child.kill());
  const answers = new Map();
  createInterface({ input: child.stdout }).on("line", line => {
    const message = JSON.parse(line);
    answers.get(message.id)?.(message);
  });
  const call = message => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no answer to ${message.method}`)), 5000);
    answers.set(message.id, answer => { clearTimeout(timer); resolve(answer); });
    child.stdin.write(JSON.stringify(message) + "\n");
  });
  await call({ jsonrpc: "2.0", id: "init", method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "docs-test", version: "1" } } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

  const real = await call(request);
  assert.equal(real.id, failure.id);
  assert.deepEqual(Object.keys(real.result).sort(), Object.keys(failure.result).sort());
  assert.equal(real.result.isError, true);
  const documented = JSON.parse(failure.result.content[0].text);
  const actual = JSON.parse(real.result.content[0].text);
  assert.deepEqual(Object.keys(actual), Object.keys(documented));
  assert.equal(actual.code, "daemon_unavailable");
  assert.equal(documented.code, actual.code);
});
