// How the browser is laid out in a real layout engine, at the sizes a plugin
// window and a phone give it.
//
// The stand-in DOM the other preset tests use never lays anything out, so it
// cannot say whether the sound that is playing is at the top, whether the list
// has most of the dialog, whether the banks are a pane beside it or a sheet
// over it, or whether anything runs off the side of a narrow window. This loads
// ui/index.html in a browser and measures. The contract is
// docs/bank-patch-ux-audit.md: a header for the sound that is playing in both
// tabs, a workspace that is not stacked with other dense panes, the banks and
// the filters behind one button, and nothing that overflows sideways.
//
// Playwright is not a dependency of this repository -- CI fetches it where it
// is wanted -- so without it this is skipped, saying so. Chromium is tried
// first and WebKit second, which is the engine a macOS editor runs in; set
// QUESYNTH_LAYOUT_ENGINE to ask for one. Screenshots of every state go to
// build/ui-layout/, whether the checks pass or not.

import test, {after} from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ui = path.join(root, "ui");
const shots = path.join(root, "build", "ui-layout");

const TYPES = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml"};

function serve() {
  return http.createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      const file = path.resolve(ui, "." + (pathname === "/" ? "/index.html" : pathname));
      if (!file.startsWith(ui + path.sep)) throw new Error("outside root");
      const body = await fs.readFile(file);
      res.writeHead(200, {"content-type": TYPES[path.extname(file)] || "application/octet-stream"}).end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
}

let playwright = null;
try { playwright = await import("playwright"); } catch { /* skipped below, with the reason */ }

async function launch() {
  const asked = process.env.QUESYNTH_LAYOUT_ENGINE;
  for (const name of asked ? [asked] : ["chromium", "webkit"]) {
    try {
      return {name, browser: await playwright[name].launch({headless: true})};
    } catch { /* the next engine */ }
  }
  return null;
}

const engine = playwright ? await launch() : null;
const server = engine ? serve() : null;
if (server) await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
after(async () => {
  if (engine) await engine.browser.close();
  if (server) {
    server.closeAllConnections?.();
    await new Promise(resolve => server.close(resolve));
  }
});

const skip = !playwright ? "playwright is not installed (npm install --no-save --no-package-lock playwright)"
  : !engine ? "no playwright browser could be launched (npx playwright install chromium or webkit)"
    : false;

// What a plugin window, a laptop and a phone give the browser. `tiny` is the
// narrowest a phone goes, and nothing may run off the side of it.
const SIZES = {
  wide: {width: 1180, height: 720},
  plugin: {width: 900, height: 600},
  phone: {width: 360, height: 640},
  small: {width: 420, height: 560},
  tiny: {width: 320, height: 568},
};
const NARROW = ["phone", "small", "tiny"];

// A bank with names of every length, one of the person's own with gaps in it,
// and the imported one playing, so that rows and slots have something to say.
async function fill(page) {
  await page.evaluate(() => {
    const bank = window.SynthBank;
    const patch = name => name && {n: name, v: window.SYNTH1_PARAMS.map(p => p.def)};
    bank.newBank("My Bank");
    ["Warm Keys", "Glass Pad", "Deep Sub", "Pluck Lead"].forEach((name, i) =>
      bank.writePreset({bank: "My Bank", slot: [1, 3, 4, 9][i], name}));
    bank.importBank("Alfmeister's Magic Cracker", [
      "Solar Winds MW", "Cathedral Strings", null, "Analog Brass", "Zither", null, "Harp", "Moog Bass",
      "Resonant Sweep", "Electric Piano Deluxe Edition With A Very Long Name",
    ].map(patch));
    bank.loadPreset({bank: "Alfmeister's Magic Cracker", slot: 0});
  });
}

async function start(name) {
  const page = await engine.browser.newPage({viewport: SIZES[name]});
  page.setDefaultTimeout(5000);
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, {waitUntil: "networkidle"});
  await fill(page);
  await page.locator("#preset-browse").click();
  await page.locator(".browser").waitFor();
  page.errors = errors;
  return page;
}

async function shoot(page, size, state) {
  await fs.mkdir(shots, {recursive: true});
  await page.screenshot({path: path.join(shots, `${engine.name}-${size}-${state}.png`)});
}

const box = async locator => (await locator.boundingBox());
const visible = locator => locator.isVisible();
const focusedClass = page => page.evaluate(() => document.activeElement && document.activeElement.className);

// How far each of these reaches past its own edge, sideways. Zero is the answer.
const OVERFLOW = [".modal", ".browser", ".browser-main", ".browser-sources", ".browser-presets", ".browser-slots",
  ".browser-results", ".browser-grid", ".browser-details", ".browser-bar", ".browser-current"];
async function sideways(page) {
  return page.evaluate(selectors => {
    const out = {page: document.documentElement.scrollWidth - document.documentElement.clientWidth};
    for (const selector of selectors) {
      for (const el of document.querySelectorAll(selector)) {
        const shown = el.getClientRects().length > 0;
        if (shown && el.scrollWidth - el.clientWidth > 1) out[selector] = el.scrollWidth - el.clientWidth;
      }
    }
    return out;
  }, OVERFLOW);
}

// The brightness of a computed `rgb(r, g, b)`: enough to say which of two inks is the quieter.
const luminance = color => {
  const [r, g, b] = color.match(/[\d.]+/g).map(Number);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

// The banks, which the narrow sizes keep behind the button.
async function openPane(page) {
  const toggle = page.locator(".browser-filters-toggle");
  if ((await toggle.getAttribute("aria-expanded")) === "false") await toggle.click();
}

for (const size of Object.keys(SIZES)) {
  const narrow = NARROW.includes(size);

  test(`${size}: the sound that is playing is at the top, readable, in the presets and in the slots`, {skip}, async () => {
    const page = await start(size);
    try {
      const modal = await box(page.locator(".modal"));
      const {width, height} = SIZES[size];
      assert.ok(modal.x >= 0 && modal.x + modal.width <= width + 1, "the dialog is inside the window sideways");
      assert.ok(modal.y >= 0 && modal.y + modal.height <= height + 1, "and up and down");

      for (const view of ["Presets", "Slots"]) {
        await page.locator(".browser-tab", {hasText: view}).click();
        const now = page.locator(".browser-now");
        assert.ok(await visible(now), `${view}: the header is shown`);
        assert.match(await now.textContent(), /Playing 000 Solar Winds MW · Imported \/ Alfmeister's Magic Cracker/);
        const at = await box(now);
        const tabs = await box(page.locator(".browser-bar"));
        assert.ok(at.y < tabs.y, `${view}: above the tabs`);
        assert.ok(at.y < modal.y + modal.height * 0.3, `${view}: in the top third of the dialog`);
        assert.ok(at.x >= modal.x && at.x + at.width <= modal.x + modal.width + 1, `${view}: and inside it`);
        const type = await page.locator(".browser-now-name").evaluate(el => parseFloat(getComputedStyle(el).fontSize));
        assert.ok(type >= 13, `${view}: the name is set at ${type}px`);
        assert.ok(at.height >= 16, `${view}: and has a line to itself`);
      }
      await shoot(page, size, "header-slots");
      assert.deepEqual(page.errors, []);
    } finally { await page.close(); }
  });

  test(`${size}: nothing runs off the side, in either tab or with the banks open`, {skip}, async () => {
    const page = await start(size);
    try {
      assert.deepEqual(await sideways(page), {page: 0}, "presets");
      await page.locator(".browser-tab", {hasText: "Slots"}).click();
      assert.deepEqual(await sideways(page), {page: 0}, "slots");
      const toggle = page.locator(".browser-filters-toggle");
      if ((await toggle.getAttribute("aria-expanded")) === "false") await toggle.click();
      assert.deepEqual(await sideways(page), {page: 0}, "slots, with the banks open");
      await page.locator(".browser-tab", {hasText: "Presets"}).click();
      assert.deepEqual(await sideways(page), {page: 0}, "presets, with the banks open");
      await page.evaluate(() => window.SynthBrowser.write());
      assert.deepEqual(await sideways(page), {page: 0}, "choosing where to write");
    } finally { await page.close(); }
  });

  test(`${size}: the list has most of the dialog, and the banks are ${narrow ? "a sheet that is shut" : "a pane beside it"}`, {skip}, async () => {
    const page = await start(size);
    try {
      const modal = await box(page.locator(".modal"));
      const work = await box(page.locator("#browser-view"));
      const share = work.height / modal.height;
      assert.ok(share >= (narrow ? 0.38 : 0.5), `the workspace is ${Math.round(share * 100)}% of the dialog's height`);
      const rows = await page.locator(".browser-result").evaluateAll(els => els.map(el => el.getBoundingClientRect().height));
      assert.ok(rows.length > 0 && Math.min(...rows) >= 44, `rows are at least 44px tall, the shortest is ${Math.min(...rows)}`);
      assert.ok(await visible(page.locator(".browser-results")), "and the list is on view");

      const pane = page.locator(".browser-sources");
      const toggle = page.locator(".browser-filters-toggle");
      assert.equal(await toggle.getAttribute("aria-controls"), await pane.getAttribute("id"));
      if (narrow) {
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        assert.equal(await visible(pane), false, "the sheet is shut: no pane is stacked with the list");
        const column = await page.locator(".browser-main").evaluate(el => getComputedStyle(el).flexDirection);
        assert.equal(column, "column");
        const body = page.locator(".browser-details-body");
        assert.equal(await visible(body), false, "and the details are a section that is shut");
        const list = await box(page.locator(".browser-results"));
        assert.ok(list.y < modal.y + modal.height * 0.6, "the first rows are in the top 60% of the dialog");
      } else {
        assert.equal(await toggle.getAttribute("aria-expanded"), "true");
        const side = await box(pane);
        assert.ok(side && side.width >= 150 && side.width <= modal.width * 0.3, `the pane is ${side && side.width}px beside the list`);
        assert.ok(side.x < work.x, "and on its left");
        const details = await box(page.locator(".browser-details"));
        assert.ok(work.width >= details.width * 1.5, `the workspace is ${work.width}px to the details' ${details.width}px`);
        assert.ok(work.x + work.width <= details.x + 1, "and the details are on its right");
      }
      await shoot(page, size, "presets");
    } finally { await page.close(); }
  });

  test(`${size}: Browse opens and shuts the banks, and a narrow window gets a sheet over the list`, {skip}, async () => {
    const page = await start(size);
    try {
      const pane = page.locator(".browser-sources");
      const toggle = page.locator(".browser-filters-toggle");
      const modal = await box(page.locator(".modal"));
      const open = narrow ? async () => { await toggle.click(); } : async () => { await toggle.click(); await toggle.click(); };
      await open();
      if (narrow) {
        assert.equal(await toggle.getAttribute("aria-expanded"), "true");
        assert.ok(await visible(pane));
        const sheet = await box(pane);
        const work = await box(page.locator("#browser-view"));
        assert.ok(sheet.x < work.x + work.width && sheet.x + sheet.width > work.x, "the sheet is over the list");
        assert.ok(sheet.y >= modal.y && sheet.y + sheet.height <= modal.y + modal.height + 1, "and inside the dialog");
        assert.ok(sheet.width >= modal.width * 0.9, "the width of the dialog");
        assert.ok(await visible(page.locator(".browser-chip", {hasText: "Favorites"})), "the filters are in it");
        assert.ok(await visible(page.locator(".browser-source").first()), "and the banks");
        await shoot(page, size, "filters-open");
        await page.keyboard.press("Escape");
        assert.equal(await visible(pane), false, "Escape shuts the sheet");
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        assert.match(await focusedClass(page), /browser-filters-toggle/, "the focus is on the button");
        assert.ok(await visible(page.locator(".modal")), "and the dialog is still there");
      } else {
        assert.ok(await visible(pane), "open again after being shut and opened");
        await toggle.click();
        assert.equal(await visible(pane), false, "shut");
        const wider = await box(page.locator("#browser-view"));
        await toggle.click();
        const narrower = await box(page.locator("#browser-view"));
        assert.ok(wider.width > narrower.width, "the list takes the room the pane gave back");
        await shoot(page, size, "filters-open");
      }
    } finally { await page.close(); }
  });

  test(`${size}: the slot view has all 128 slots, 000 to 127, and the details beside the slot`, {skip}, async () => {
    const page = await start(size);
    try {
      await page.locator(".browser-tab", {hasText: "Slots"}).click();
      const nums = await page.locator(".browser-slot .browser-slot-num").allTextContents();
      assert.equal(nums.length, 128);
      assert.deepEqual(nums, Array.from({length: 128}, (_, i) => String(i).padStart(3, "0")));
      const tools = await page.locator(".browser-grid .browser-mini, .browser-grid .browser-slot-tools").count();
      assert.equal(tools, 0, "no tools on the slots");
      const empty = page.locator(".browser-slot.empty").first();
      assert.ok(await visible(empty), "an empty slot is on view");
      const slot = await box(empty);
      assert.ok(slot.height >= 28, "and is big enough to hit");

      if (narrow) await page.locator(".browser-details-toggle").click();
      await page.locator(".browser-slot", {hasText: "Zither"}).focus();
      assert.ok(await visible(page.locator(".browser-details-body")));
      assert.equal(await page.locator(".browser-detail-name").textContent(), "Zither");
      const details = await box(page.locator(".browser-details"));
      const modal = await box(page.locator(".modal"));
      assert.ok(details.x + details.width <= modal.x + modal.width + 1, "the details are inside the dialog");
      await shoot(page, size, "slots-details");
    } finally { await page.close(); }
  });

  test(`${size}: the More menus open in place, stay inside the dialog, and Escape gives the focus back`, {skip}, async () => {
    const page = await start(size);
    try {
      await page.locator(".browser-tab", {hasText: "Slots"}).click();
      if (narrow) await page.locator(".browser-details-toggle").click();
      await page.locator(".browser-slot", {hasText: "Zither"}).focus();
      const trigger = page.locator(".browser-details .browser-more");
      const list = page.locator(".browser-details [role=menu]");
      assert.equal(await visible(list), false, "shut to begin with");
      await page.keyboard.press("ContextMenu");
      assert.ok(await visible(list), "the menu key on a slot opens its menu");
      await page.keyboard.press("Escape");
      assert.equal(await visible(list), false);
      await page.locator(".browser-slot", {hasText: "Zither"}).click({button: "right"});
      assert.ok(await visible(list), "and so does a right click");
      assert.equal(await page.locator(".browser-now").textContent().then(t => /Solar Winds MW/.test(t)), true, "neither loaded it");
      await page.keyboard.press("Escape");
      await trigger.click();
      assert.ok(await visible(list));
      assert.equal(await trigger.getAttribute("aria-expanded"), "true");
      const menu = await box(list);
      const modal = await box(page.locator(".modal"));
      assert.ok(menu.x >= modal.x && menu.x + menu.width <= modal.x + modal.width + 1, "inside the dialog sideways");
      assert.ok(menu.y + menu.height <= modal.y + modal.height + 1, "and not below it");
      assert.deepEqual(await page.locator(".browser-details [role=menuitem]").allTextContents(), ["Copy", "Move"]);
      await shoot(page, size, "slot-menu");
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Escape");
      assert.equal(await visible(list), false);
      assert.equal(await trigger.getAttribute("aria-expanded"), "false");
      assert.equal(await page.evaluate(el => document.activeElement === el, await trigger.elementHandle()), true, "the focus is on the button");
      assert.ok(await visible(page.locator(".modal")), "Escape took the menu and not the dialog");

      const toggle = page.locator(".browser-filters-toggle");
      if ((await toggle.getAttribute("aria-expanded")) === "false") await toggle.click();
      const banks = page.locator(".browser-bank-tools .browser-more");
      const bankList = page.locator(".browser-bank-tools [role=menu]");
      await banks.click();
      assert.ok(await visible(bankList));
      assert.deepEqual(await page.locator(".browser-bank-tools [role=menuitem]").allTextContents(),
        ["Rename...", "Duplicate", "Export bank", "Close bank"]);
      const inside = await box(bankList);
      const pane = await box(page.locator(".browser-sources"));
      assert.ok(inside.x >= pane.x && inside.x + inside.width <= pane.x + pane.width + 1, "the bank's menu is inside the pane");
      await shoot(page, size, "bank-menu");
      await page.keyboard.press("Escape");
      assert.equal(await visible(bankList), false);
      assert.deepEqual(await sideways(page), {page: 0});
    } finally { await page.close(); }
  });

  test(`${size}: choosing where to write is a list of slots with the form under it and nothing on them`, {skip}, async () => {
    const page = await start(size);
    try {
      await page.evaluate(() => window.SynthBrowser.write());
      const dialog = page.locator(".modal").last();
      assert.equal((await dialog.getAttribute("aria-label")), "Write");
      assert.equal(await dialog.locator(".browser-slot").count(), 128);
      assert.equal(await dialog.locator(".browser-tab").count(), 0);
      assert.equal(await dialog.locator(".browser-grid .browser-mini").count(), 0);
      assert.ok(await visible(dialog.locator(".browser-destination")), "it says what it is for");
      assert.ok(await visible(dialog.locator(".browser-save")), "and the form is on view");
      assert.ok(await visible(dialog.locator(".browser-save-name")));
      assert.equal(await visible(dialog.locator(".browser-sources")), !narrow, "the banks are a pane where there is room, and behind Banks where there is not");
      assert.equal(await dialog.locator(".browser-filters-toggle").textContent(), "Banks");
      assert.deepEqual(await sideways(page), {page: 0});
      await shoot(page, size, "write");
    } finally { await page.close(); }
  });

  test(`${size}: the pane is headed Sources, Manage banks and Banks, in that order, in quiet words that are not controls`, {skip}, async () => {
    const page = await start(size);
    try {
      await openPane(page);
      const titles = page.locator(".browser-sources .browser-section-title");
      assert.deepEqual(await titles.allTextContents(), ["Sources", "Manage banks", "Banks"]);
      const pane = await box(page.locator(".browser-sources"));
      const name = await page.locator(".browser-source.on .browser-source-name").evaluate(el => getComputedStyle(el).color);
      let last = -1;
      for (const title of await titles.all()) {
        const words = await title.textContent();
        assert.ok(await visible(title), `${words} is on view`);
        const at = await box(title);
        assert.ok(at.y > last, `${words} is below the one before it`);
        last = at.y;
        assert.ok(at.x >= pane.x && at.x + at.width <= pane.x + pane.width + 1, `${words} is inside the pane`);
        const style = await title.evaluate(el => {
          const s = getComputedStyle(el);
          return {size: parseFloat(s.fontSize), caps: s.textTransform, color: s.color, weight: Number(s.fontWeight), controls: el.querySelectorAll("button, input, a").length};
        });
        assert.ok(style.size >= 11 && style.size <= 12, `${words} is ${style.size}px`);
        assert.equal(style.caps, "uppercase", words);
        assert.ok(style.weight < 600, `${words} is not set heavier than a name`);
        assert.ok(luminance(style.color) < luminance(name), `${words} is quieter than the name of the bank in view`);
        assert.equal(style.controls, 0, words);
        assert.equal(await title.evaluate(el => el.tabIndex), -1, `${words} is not in the Tab order`);
      }
      await shoot(page, size, "pane-sections");
      assert.deepEqual(await sideways(page), {page: 0});
    } finally { await page.close(); }
  });

  test(`${size}: a bank's name leads, and where it came from is quiet words level with it, under it`, {skip}, async () => {
    const page = await start(size);
    try {
      await openPane(page);
      const rows = page.locator(".browser-source");
      const count = await rows.count();
      assert.ok(count >= 3, "a bank of each kind");
      for (let i = 0; i < count; i++) {
        const row = rows.nth(i);
        const [name, line] = [await box(row.locator(".browser-source-name")), await box(row.locator(".browser-source-badges"))];
        assert.ok(line.y >= name.y + name.height - 1, "what is said about it is under its name");
        assert.ok(Math.abs(line.x - name.x) <= 2, `and level with it, not set away from it (${line.x - name.x}px)`);
        const style = await row.evaluate(el => {
          const of = selector => getComputedStyle(el.querySelector(selector));
          return {
            nameSize: parseFloat(of(".browser-source-name").fontSize), nameColor: of(".browser-source-name").color,
            lineSize: parseFloat(of(".browser-badge").fontSize), lineColor: of(".browser-badge").color,
            caps: of(".browser-badge").textTransform, border: of(".browser-badge").borderTopWidth,
            spill: el.scrollWidth - el.clientWidth,
          };
        });
        assert.ok(style.nameSize > style.lineSize, `the name is ${style.nameSize}px and the line ${style.lineSize}px`);
        assert.ok(style.lineSize >= 11, "and the line is still legible");
        assert.ok(luminance(style.lineColor) < luminance(style.nameColor), "and in a quieter ink");
        assert.equal(style.caps, "none", "in words, not capitals that read as a label or a button");
        assert.equal(style.border, "0px", "and not in a box");
        assert.ok(style.spill <= 1, `the row does not run off the side (${style.spill}px)`);
      }
    } finally { await page.close(); }
  });

  test(`${size}: the filters and the menu buttons in the pane are text, and still a target a finger can hit`, {skip}, async () => {
    const page = await start(size);
    try {
      await openPane(page);
      const triggers = page.locator(".browser-sources .browser-more");
      assert.equal(await triggers.count(), 2, "Add bank and Bank actions");
      assert.deepEqual((await triggers.allTextContents()).map(t => t.trim()), ["Add bank", "Bank actions"]);
      for (const trigger of await triggers.all()) {
        const at = await box(trigger);
        const style = await trigger.evaluate(el => { const s = getComputedStyle(el); return {border: s.borderTopWidth, background: s.backgroundColor}; });
        assert.ok(at.height >= 34, `${await trigger.textContent()} is ${at.height}px tall`);
        assert.equal(style.border, "0px", "no box round it");
        assert.equal(style.background, "rgba(0, 0, 0, 0)", "and no fill");
      }
      for (const chip of await page.locator(".browser-sources .browser-chip").all()) {
        const at = await box(chip);
        const caps = await chip.evaluate(el => getComputedStyle(el).textTransform);
        assert.ok(at.height >= 28, `${await chip.textContent()} is ${at.height}px tall`);
        assert.equal(caps, "none", "a filter is in words, as a heading is in capitals");
      }
    } finally { await page.close(); }
  });

  test(`${size}: Close bank and Move are set apart from the other items of their menus by a rule`, {skip}, async () => {
    const page = await start(size);
    try {
      const rules = list => list.locator("[role=menuitem]").evaluateAll(els => els.map(el => {
        const at = el.getBoundingClientRect();
        return {words: el.textContent, rule: parseFloat(getComputedStyle(el).borderTopWidth), top: at.top, bottom: at.bottom};
      }));
      await openPane(page);
      await page.locator(".browser-bank-tools .browser-more").click();
      const bank = await rules(page.locator(".browser-bank-tools [role=menu]"));
      assert.deepEqual(bank.map(i => i.words), ["Rename...", "Duplicate", "Export bank", "Close bank"]);
      assert.deepEqual(bank.map(i => i.rule > 0), [false, false, false, true]);
      assert.ok(bank[3].top >= bank[2].bottom + 2, "with room above it as well as a rule");
      await shoot(page, size, "bank-menu-tiers");
      await page.keyboard.press("Escape");
      if (narrow) await page.locator(".browser-filters-toggle").click();

      await page.locator(".browser-tab", {hasText: "Slots"}).click();
      if (narrow) await page.locator(".browser-details-toggle").click();
      await page.locator(".browser-slot", {hasText: "Zither"}).focus();
      await page.keyboard.press("ContextMenu");
      const slot = await rules(page.locator(".browser-details [role=menu]"));
      assert.deepEqual(slot.map(i => i.words), ["Copy", "Move"]);
      assert.deepEqual(slot.map(i => i.rule > 0), [false, true]);
      assert.ok(slot[1].top >= slot[0].bottom + 2);
      assert.equal((await page.locator(".browser-details .browser-more").textContent()).trim(), "Slot actions");
    } finally { await page.close(); }
  });
}

// ---------------------------------------------------- the window changing size

test("resizing the window across 620px with the dialog open shuts the pane and the details, and widening opens them", {skip}, async () => {
  const page = await start("wide");
  try {
    const pane = page.locator(".browser-sources");
    const toggle = page.locator(".browser-filters-toggle");
    assert.ok(await visible(pane));
    assert.ok(await visible(page.locator(".browser-details-body")));
    await page.locator(".browser-chip", {hasText: "Favorites"}).focus();

    await page.setViewportSize(SIZES.phone);
    await page.waitForFunction(() => document.querySelector(".browser-sources").hidden);
    assert.equal(await visible(pane), false, "the pane is not a sheet over the list");
    assert.equal(await toggle.getAttribute("aria-expanded"), "false");
    assert.equal(await visible(page.locator(".browser-details-body")), false, "and the details are a section that is shut");
    assert.match(await focusedClass(page), /browser-filters-toggle/, "the focus that was in the pane is on its button");
    assert.ok(await visible(page.locator(".browser-results")), "the list is on view");
    const modal = await box(page.locator(".modal"));
    const work = await box(page.locator("#browser-view"));
    assert.ok(work.height / modal.height >= 0.38, `the list has ${Math.round(100 * work.height / modal.height)}% of the dialog`);
    assert.ok(modal.x >= 0 && modal.x + modal.width <= SIZES.phone.width + 1, "inside the narrower window");
    assert.deepEqual(await sideways(page), {page: 0});
    await shoot(page, "phone", "resized-narrow");

    await page.setViewportSize(SIZES.wide);
    await page.waitForFunction(() => !document.querySelector(".browser-sources").hidden);
    assert.ok(await visible(pane), "the pane is open again");
    assert.equal(await toggle.getAttribute("aria-expanded"), "true");
    assert.ok(await visible(page.locator(".browser-details-body")), "and the details");
    const side = await box(pane);
    const list = await box(page.locator("#browser-view"));
    assert.ok(side.x < list.x && side.x + side.width <= list.x + 1, "beside the list again");
    assert.deepEqual(await sideways(page), {page: 0});
    await shoot(page, "wide", "resized-wide");
    assert.deepEqual(page.errors, []);
  } finally { await page.close(); }
});

// ---------------------------------------------------- press and hold on a touch screen

// Chromium's touch input is driven through the DevTools protocol, which is the
// only way to hold a finger down for a while; Playwright's touchscreen only
// taps. So this is Chromium's, and the stand-in DOM test has the rest.
test("a finger held on a slot asks about it and opens its menu without loading it; a tap still loads", {
  skip: skip || (engine.name !== "chromium" && "a held touch is driven through the Chrome DevTools protocol"),
}, async () => {
  const context = await engine.browser.newContext({viewport: SIZES.phone, hasTouch: true});
  const page = await context.newPage();
  page.setDefaultTimeout(5000);
  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`, {waitUntil: "networkidle"});
    await fill(page);
    await page.locator("#preset-browse").tap();
    await page.locator(".browser").waitFor();
    await page.locator(".browser-tab", {hasText: "Slots"}).tap();

    const zither = page.locator(".browser-slot", {hasText: "Zither"});
    const at = await box(zither);
    const cdp = await context.newCDPSession(page);
    const point = {x: Math.round(at.x + at.width / 2), y: Math.round(at.y + at.height / 2), id: 1};
    await cdp.send("Input.dispatchTouchEvent", {type: "touchStart", touchPoints: [point]});
    assert.equal(await visible(page.locator(".browser-details [role=menu]")), false, "not at once");
    await page.waitForTimeout(700);
    assert.ok(await visible(page.locator(".browser-details [role=menu]")), "a finger held for a while opens the menu");
    await cdp.send("Input.dispatchTouchEvent", {type: "touchEnd", touchPoints: []});
    await page.waitForTimeout(150);
    assert.equal(await page.locator(".browser-detail-name").textContent(), "Zither", "the details are of that slot");
    assert.match(await page.locator(".browser-now").textContent(), /Playing 000 Solar Winds MW/, "and it was not loaded");
    await shoot(page, "phone", "touch-hold-menu");

    await page.keyboard.press("Escape");
    await page.locator(".browser-slot", {hasText: "Harp"}).tap();
    assert.match(await page.locator(".browser-now").textContent(), /Playing 006 Harp/, "a tap loads");
    assert.deepEqual(await sideways(page), {page: 0});
  } finally {
    await context.close();
  }
});
