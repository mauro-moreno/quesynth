import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ui = path.join(root, "ui");
const fixture = path.join(root, "tools/s1probe/fixtures/unison-four.sy1");

function serverFor(dir) {
  return http.createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      const relative = pathname === "/" ? "/index.html" : pathname;
      const file = path.resolve(dir, `.${relative}`);
      if (!file.startsWith(dir + path.sep)) throw new Error("outside root");
      const body = await fs.readFile(file);
      res.writeHead(200).end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
}

test("WebKit file chooser loads a Synth1 patch", async () => {
  const {webkit} = await import("playwright");
  const server = serverFor(ui);
  let browser;
  try {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const port = server.address().port;
    browser = await webkit.launch({headless: true});
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${port}/index.html`, {waitUntil: "networkidle"});
    await page.locator(".bank-read").click();
    await page.getByRole("button", {name: "Add"}).click();
    const input = page.locator('input[type="file"]');
    await input.setInputFiles(fixture);
    await page.waitForFunction(() => /unison four/i.test(document.querySelector("#bank-patch")?.textContent || ""));
    assert.match(await page.locator("#bank-patch").textContent(), /unison four/i);
  } finally {
    if (browser) await browser.close();
    server.closeAllConnections?.();
    await new Promise(resolve => server.close(resolve));
  }
});
