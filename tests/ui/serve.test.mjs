import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {createRequire} from "node:module";

const require = createRequire(import.meta.url);
const {createServer, DEFAULT_PORT, HOST} = require("../../hosts/wasm/serve.js");

// hosts/wasm/serve.js is the development server for the panel. It reads
// whatever path the browser sends, so what it must never do is fall over on a
// bad one or hand out a file that is not under one of its two roots. Each test
// below builds throwaway roots and a "-secret" directory beside the first, whose
// name starts with the first root's, which is exactly what a string-prefix test
// on the path lets through.

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "qs-wasm-serve-"));
const first = path.join(tmp, "root");
const second = path.join(tmp, "root2");
const secret = path.join(tmp, "root-secret");
for (const dir of [first, second, secret]) fs.mkdirSync(dir);
fs.writeFileSync(path.join(first, "index.html"), "first index");
fs.writeFileSync(path.join(first, "both.js"), "from first");
fs.writeFileSync(path.join(second, "both.js"), "from second");
fs.writeFileSync(path.join(second, "only-second.css"), "body{}");
fs.writeFileSync(path.join(secret, "secret.txt"), "SECRET");
fs.writeFileSync(path.join(tmp, "outside.txt"), "SECRET");

const server = createServer([first, second]);
await new Promise((resolve) => server.listen(0, HOST, resolve));
const {port} = server.address();
test.after(() => {
  server.close();
  fs.rmSync(tmp, {recursive: true, force: true});
});

// The path goes out exactly as written: http.get would not change it, but the
// URL class would, and "../" and "%2e" are the point. A request that is never
// answered fails after two seconds: a handler that throws leaves its socket
// open, and a hung run says much less than a failed one.
function get(rawPath) {
  return new Promise((resolve, reject) => {
    http
      .get({host: HOST, port, path: rawPath, timeout: 2000}, (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => resolve({status: res.statusCode, body, headers: res.headers}));
      })
      .on("timeout", function () {
        this.destroy(new Error(`${rawPath} was never answered`));
      })
      .on("error", reject);
  });
}

test("a malformed percent escape is a 400 and the server keeps answering", async () => {
  for (const bad of ["/%", "/%E0%A4%A", "/%zz", "/ok%2"]) {
    assert.equal((await get(bad)).status, 400, bad);
  }
  const after = await get("/both.js");
  assert.equal(after.status, 200);
  assert.equal(after.body, "from first");
});

test("an encoded NUL byte is a 400, not an fs error", async () => {
  assert.equal((await get("/both.js%00.png")).status, 400);
  assert.equal((await get("/%00")).status, 400);
  assert.equal((await get("/both.js")).status, 200);
});

test("no spelling of ../ reaches a file outside the roots", async () => {
  const attempts = [
    "/../outside.txt",
    "/../../outside.txt",
    "/%2e%2e/outside.txt",
    "/%2e%2e%2foutside.txt",
    "/..%2foutside.txt",
    "/..%2Foutside.txt",
    "/%2E%2E/%2E%2E/outside.txt",
    "/../..",
    "/%2e%2e%2f%2e%2e",
    `/${encodeURIComponent(path.join(tmp, "outside.txt"))}`,
  ];
  for (const attempt of attempts) {
    const {status, body} = await get(attempt);
    assert.ok(status === 400 || status === 404, `${attempt} answered ${status}`);
    assert.ok(!body.includes("SECRET"), `${attempt} leaked a file outside the roots`);
  }
});

test("a sibling directory that shares the root's name as a prefix is not served", async () => {
  const attempts = [
    "/../root-secret/secret.txt",
    "/%2e%2e/root-secret/secret.txt",
    "/..%2froot-secret%2fsecret.txt",
    "/%2e%2e%2froot-secret/secret.txt",
  ];
  for (const attempt of attempts) {
    const {status, body} = await get(attempt);
    assert.ok(status === 400 || status === 404, `${attempt} answered ${status}`);
    assert.ok(!body.includes("SECRET"), `${attempt} leaked the sibling directory`);
  }
});

test("a dot-dot that stays inside the root still resolves", async () => {
  const {status, body} = await get("/nested/../both.js");
  assert.equal(status, 200);
  assert.equal(body, "from first");
});

test("the first root shadows the second, and a file only the second has is served", async () => {
  const shadowed = await get("/both.js");
  assert.equal(shadowed.status, 200);
  assert.equal(shadowed.body, "from first");

  const only = await get("/only-second.css?v=3");
  assert.equal(only.status, 200);
  assert.equal(only.body, "body{}");
  assert.equal(only.headers["content-type"], "text/css; charset=utf-8");
});

test("/ serves index.html, a missing file is 404, and a directory is not a file", async () => {
  const index = await get("/");
  assert.equal(index.status, 200);
  assert.equal(index.body, "first index");
  assert.equal((await get("/missing.js")).status, 404);
  assert.equal((await get("/index.html/nope")).status, 404);
});

test("it listens on the loopback address only, and not on the port quesynth --browser uses", () => {
  assert.equal(server.address().address, "127.0.0.1");
  assert.equal(HOST, "127.0.0.1");
  assert.notEqual(DEFAULT_PORT, 8177);
});
