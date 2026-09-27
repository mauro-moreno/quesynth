#!/usr/bin/env node
// GUI smoke: renders ui/index.html in headless WebKit (the WKWebView engine),
// asserts the panel was built, and saves a full-page PNG.
//
// Usage: node tools/ui-screenshot.mjs [out.png]
//   env UI_SCREENSHOT_OUT overrides the default build/ui-smoke/panel.png.

import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const UI_DIR = path.join(REPO_ROOT, "ui");
const VIEWPORT = { width: 1180, height: 720 };
const MIN_SECTIONS = 10;
const BUILD_TIMEOUT_MS = 20000;

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

const FATAL_ERROR_PATTERN = /ReferenceError|SyntaxError|TypeError|is not defined|Can't find variable/;

function resolveOutputPath() {
  const requested = process.argv[2] || process.env.UI_SCREENSHOT_OUT || "build/ui-smoke/panel.png";
  return path.resolve(REPO_ROOT, requested);
}

async function loadWebkit() {
  try {
    const playwright = await import("playwright");
    return playwright.webkit;
  } catch (err) {
    throw new Error(
      "Playwright is not available (" + err.message + ").\n" +
      "Install it just-in-time, e.g.:\n" +
      "  npm install --no-save playwright && npx playwright install webkit",
    );
  }
}

function startStaticServer(rootDir) {
  const server = http.createServer(async (req, res) => {
    try {
      const urlPath = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      const relative = urlPath.endsWith("/") ? urlPath + "index.html" : urlPath;
      const filePath = path.resolve(rootDir, "." + relative);
      if (filePath !== rootDir && !filePath.startsWith(rootDir + path.sep)) {
        res.writeHead(403).end("Forbidden");
        return;
      }
      const body = await fs.readFile(filePath);
      const type = CONTENT_TYPES[path.extname(filePath).toLowerCase()] || "application/octet-stream";
      res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" }).end(body);
    } catch {
      res.writeHead(404, { "Content-Type": "text/plain" }).end("Not Found");
    }
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function closeServer(server) {
  return new Promise((resolve) => {
    server.closeAllConnections?.();
    server.close(() => resolve());
  });
}

async function countPanel(page) {
  return page.evaluate(() => ({
    sections: document.querySelectorAll("#panels section.panel").length,
    navButtons: document.querySelectorAll("#navigator .nav-inner button").length,
    controls: document.querySelectorAll("#panels .control").length,
  }));
}

async function run() {
  const outputPath = resolveOutputPath();
  const webkit = await loadWebkit();
  const consoleErrors = [];
  const pageErrors = [];
  let server;
  let browser;

  try {
    server = await startStaticServer(UI_DIR);
    const { port } = server.address();
    const url = `http://127.0.0.1:${port}/index.html`;

    browser = await webkit.launch({ headless: true });
    const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1 });
    const page = await context.newPage();
    page.on("console", (msg) => {
      if (msg.type() === "error") consoleErrors.push(msg.text());
    });
    page.on("pageerror", (err) => pageErrors.push(String(err && err.stack || err)));

    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForLoadState("load");
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});

    try {
      await page.waitForFunction(
        () =>
          document.querySelectorAll("#panels section.panel").length > 0 &&
          document.querySelectorAll("#navigator .nav-inner button").length > 0,
        null,
        { timeout: BUILD_TIMEOUT_MS },
      );
    } catch {
      const partial = await countPanel(page).catch(() => null);
      throw new Error(
        "Panel did not build within " + BUILD_TIMEOUT_MS + "ms" +
        (partial ? ` (sections=${partial.sections}, nav=${partial.navButtons}, controls=${partial.controls})` : ""),
      );
    } finally {
      await fs.mkdir(path.dirname(outputPath), { recursive: true });
      await page.screenshot({ path: outputPath, fullPage: true }).catch(() => {});
    }

    const counts = await countPanel(page);
    const failures = [];
    if (counts.sections < MIN_SECTIONS) {
      failures.push(`expected at least ${MIN_SECTIONS} sections, found ${counts.sections}`);
    }
    if (counts.controls === 0) failures.push("no .control elements were built");
    if (counts.navButtons === 0) failures.push("navigator has no buttons");
    if (pageErrors.length) {
      failures.push("uncaught page errors:\n    " + pageErrors.join("\n    "));
    }
    const fatalConsole = consoleErrors.filter((text) => FATAL_ERROR_PATTERN.test(text));
    if (fatalConsole.length) {
      failures.push("console errors:\n    " + fatalConsole.join("\n    "));
    }

    console.log(`screenshot: ${outputPath}`);
    console.log(`sections: ${counts.sections}  nav buttons: ${counts.navButtons}  controls: ${counts.controls}`);
    const tolerated = consoleErrors.filter((text) => !FATAL_ERROR_PATTERN.test(text));
    for (const text of tolerated) console.log(`tolerated console error: ${text}`);

    if (failures.length) throw new Error("UI smoke failed:\n  - " + failures.join("\n  - "));
    console.log("UI smoke passed");
  } finally {
    if (browser) await browser.close().catch(() => {});
    if (server) await closeServer(server);
  }
}

run().then(
  () => process.exit(0),
  (err) => {
    console.error(err && err.message ? err.message : err);
    process.exit(1);
  },
);
