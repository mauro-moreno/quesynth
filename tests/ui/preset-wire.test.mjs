// The wire between a plugin host and the page, held against a file neither
// side wrote its half of.
//
// preset-reopen, preset-restore and preset-persistence each state the messages
// in JavaScript, and tests/panel/protocol_test.odin states them in Odin, by a
// different hand. A field spelled differently on one side would pass both
// suites and break the editor in a real host. tests/panel/fixtures/wire-v1.json
// is the one copy; tests/panel/wire_test.odin replays it from the host's end.
// Here it is replayed from the page's.
//
// Each exchange is a person doing something to the page, the exact strings the
// page then posts, the exact strings a host answers with, and what the page
// must look like after it has been told. The host's strings go in verbatim,
// through window.synthReceive as a string, which is how a native host calls it;
// the page's strings are what its transport was handed, byte for byte. Nothing
// here builds a message and then reads it back with the code that wrote it.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {bootPanel, compiledBank, plain} from "./support/panel.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(fs.readFileSync(path.join(HERE, "..", "panel", "fixtures", "wire-v1.json"), "utf8"));

// What bank.js would have compiled into the page. A plugin's real bank has
// another label ("Factory"), which is why the page lists both.
const FACTORY = compiledBank("Quesynth Factory", ["Strings", "Brass", "Bells"], 70);

// -- the fixture against the written protocol ---------------------------------

// ui/bridge.js's header and section 2 of the design, as the keys of each
// message in the order they are written there. Held in order for the host's
// messages, which a reader of a captured log depends on; the page's are held as
// sets, because the page's own JSON.stringify decides their order.
const TO_PAGE = {
  bank: [["type", "text"], ["type", "text", "v", "origin", "readOnly"]],
  state: [["type", "values"]],
  patch: [["type", "name", "index", "bank", "v", "origin"]],
  restore: [
    ["type", "v", "state"],
    ["type", "v", "state", "origin", "bank", "slot", "name"],
    ["type", "v", "state", "error", "recoverable", "message"],
    ["type", "v", "state", "error", "recoverable", "message", "origin", "bank", "slot", "name"],
  ],
  "bank-saved": [
    ["type", "v", "ok", "bank"],
    ["type", "v", "ok", "error", "message", "bank"],
    ["type", "v", "ok", "error", "message"],
  ],
};
const TO_HOST = {
  sync: [["type"]],
  state: [["type", "values"]],
  select: [["type", "v", "origin", "bank", "slot", "name"]],
  "restore-retry": [["type", "v"]],
  "restore-discard": [["type", "v"]],
  bank: [["type", "text", "save"], ["type", "text", "save", "v", "origin"]],
};
const HOST_DOES = ["program_change", "announce"];
const ORIGINS = ["factory", "user", "imported", "archive", "file", "session"];
const RESTORE_ERRORS = ["MissingBank", "InvalidProgram", "HostStateRejected", "StateVersionUnsupported"];

const exchanges = FIXTURE.scenarios.flatMap(s => s.exchanges.map((x, i) => ({scenario: s.name, number: i + 1, ...x})));
const toPage = exchanges.flatMap(x => x.host_to_page.map(text => ({where: `${x.scenario} #${x.number}`, text, message: JSON.parse(text)})));
const toHost = exchanges.flatMap(x => x.page_to_host.map(text => ({where: `${x.scenario} #${x.number}`, text, message: JSON.parse(text)})));

function holdsToWritten(table, side, {ordered}) {
  for (const {where, text, message} of side) {
    const shapes = table[message.type];
    assert.ok(shapes, `${where}: ${message.type} is not a message in the written protocol`);
    const keys = Object.keys(message);
    const fits = shapes.some(shape => ordered
      ? keys.join() === shape.join()
      : keys.length === shape.length && shape.every(k => keys.includes(k)));
    assert.ok(fits, `${where}: the keys of ${message.type} are ${keys.join(",")}, which is none of ${shapes.map(s => s.join(",")).join(" | ")}\n${text.slice(0, 200)}`);
    if ("origin" in message) assert.ok(ORIGINS.includes(message.origin), `${where}: origin ${message.origin}`);
    if ("error" in message && message.type === "restore") assert.ok(RESTORE_ERRORS.includes(message.error), `${where}: ${message.error}`);
    if ("slot" in message) assert.ok(message.slot === null || Number.isInteger(message.slot), `${where}: slot ${message.slot}`);
    if ("v" in message) assert.equal(message.v, 1, `${where}: v`);
  }
}

test("every string the fixture holds for a host is a message the written protocol has, with its keys in its order", () => {
  holdsToWritten(TO_PAGE, toPage, {ordered: true});
});

test("every string the fixture holds for the page's side has the keys the written protocol lists", () => {
  holdsToWritten(TO_HOST, toHost, {ordered: false});
});

test("the fixture covers every message of the contract, so removing a scenario cannot quietly drop one", () => {
  const seen = (side, pick) => side.filter(pick).length;
  const to = (type, pick = () => true) => seen(toPage, ({message: m}) => m.type === type && pick(m));
  const from = (type, pick = () => true) => seen(toHost, ({message: m}) => m.type === type && pick(m));

  assert.ok(from("sync"));
  assert.ok(from("state"));
  assert.ok(from("select", m => Number.isInteger(m.slot)), "select with a slot");
  assert.ok(from("select", m => m.slot === null), "select with a null slot");
  assert.ok(from("restore-retry"));
  assert.ok(from("restore-discard"));
  assert.ok(from("bank", m => m.save === true && m.origin === "user"), "bank to be kept");
  assert.ok(from("bank", m => m.save === false && m.origin === "imported"), "bank to be played and not kept");

  assert.ok(to("bank", m => m.v === 1));
  assert.ok(to("bank", m => m.v === undefined), "a bank a legacy host sends");
  assert.ok(to("state"));
  assert.ok(to("patch"));
  assert.ok(to("restore", m => m.state === "restored" && m.slot !== null));
  assert.ok(to("restore", m => m.state === "restored" && m.slot === null), "a bank restored with nothing selected");
  assert.ok(to("restore", m => m.state === "notRequested"), "a host that holds nothing to restore answering a retry");
  for (const error of RESTORE_ERRORS) assert.ok(to("restore", m => m.error === error), `restore ${error}`);
  assert.ok(to("bank-saved", m => m.ok === true));
  assert.ok(to("bank-saved", m => m.error === "PersistenceFailed"));
  assert.ok(to("bank-saved", m => m.error === "InvalidBank"));
  // The two that have to be escaped to be one line: a quote, a backslash, a
  // control character and something that is not ASCII.
  assert.ok(toPage.some(({text}) => /\\"/.test(text) && /\\\\/.test(text) && /\\u0001/.test(text) && /[^\x00-\x7f]/.test(text)),
    "a name that needs escaping");
});

// -- playing a scenario -------------------------------------------------------

// Everything the transport was handed, as the bytes it was handed.
function boot() {
  const posted = [];
  const page = bootPanel({bank: FACTORY, before: window => {
    const post = window.synthPost;
    window.synthPost = text => { posted.push(text); post(text); };
  }});
  return {page, posted};
}

function act(page, does) {
  if (does.idle) {
    // The host's turn: it does something of its own, and the page only hears.
  } else if (does.click) {
    const button = page.document.querySelector(does.click);
    assert.ok(button, `there is no ${does.click} to click`);
    button.click();
  } else if (does.call) {
    const [owner, name] = does.call.split(".");
    page.window[owner][name](...does.args);
  } else {
    assert.fail(`the fixture asks the page to do something this test cannot: ${JSON.stringify(does)}`);
  }
}

const shown = (page, id) => !page.$(id).hasAttribute("hidden");
const buttonsOf = (page, id) => page.$(id).querySelectorAll("button").filter(b => !b.hasAttribute("hidden")).map(b => b.textContent);

function expectBanner(page, want, at) {
  const lines = {ok: "restore-ok", failed: "restore-failed", missing: "restore-missing"};
  const words = {ok: "restore-ok", failed: "restore-failed-text", missing: "restore-missing"};
  for (const [key, value] of Object.entries(want)) {
    if (key === "visible") assert.equal(shown(page, "restore-banner"), value, `${at}: banner visible`);
    else if (key in lines) {
      if (value === null) assert.equal(shown(page, lines[key]), false, `${at}: the ${key} line is hidden`);
      else {
        assert.equal(shown(page, lines[key]), true, `${at}: the ${key} line is shown`);
        const element = key === "missing" ? page.$(words[key]).querySelector("p") : page.$(words[key]);
        assert.equal(element.textContent, value, `${at}: the ${key} line`);
      }
    } else if (key === "buttons") assert.deepEqual(buttonsOf(page, "restore-failed"), value, `${at}: buttons`);
    else if (key === "missing_buttons") assert.deepEqual(buttonsOf(page, "restore-missing"), value, `${at}: the missing-bank buttons`);
    else if (key === "retry_disabled") assert.equal(page.$("restore-retry").disabled, value, `${at}: Retry disabled`);
    else assert.fail(`${at}: the fixture's banner has a key this test does not read: ${key}`);
  }
}

function expectPage(page, scenario, effect, at) {
  const bank = page.window.SynthBank;
  for (const [key, want] of Object.entries(effect)) {
    switch (key) {
      case "protocol": assert.equal(page.window.SynthBridge.version(), want, `${at}: the version the page believes the host speaks`); break;
      case "selection": assert.deepEqual(plain(bank.selection()), want, `${at}: selection()`); break;
      case "status": assert.equal(bank.status(), want, `${at}: status()`); break;
      case "restore": assert.deepEqual(plain(bank.restoreState()), want, `${at}: restoreState()`); break;
      case "strip":
        for (const [id, text] of Object.entries(want)) assert.equal(page.text(id), text, `${at}: #${id}`);
        break;
      case "banner": expectBanner(page, want, at); break;
      case "sound": assert.deepEqual(page.values(), want === "host" ? scenario.host.values : want, `${at}: the sound`); break;
      case "index": assert.equal(bank.index(), want, `${at}: index()`); break;
      case "status_line":
        assert.equal(page.text("bank-status"), want.text, `${at}: the line under the strip`);
        assert.equal(page.$("bank-status").getAttribute("data-kind"), want.kind, `${at}: its kind`);
        break;
      case "result": {
        const last = bank.lastResult();
        assert.equal(last.ok, want.ok, `${at}: lastResult().ok`);
        if (want.code) assert.equal(last.error.code, want.code, `${at}: lastResult().error.code`);
        break;
      }
      default: assert.fail(`${at}: the fixture's page_effect has a key this test does not read: ${key}`);
    }
  }
}

function play(scenario) {
  const {page, posted} = boot();
  scenario.exchanges.forEach((exchange, i) => {
    const at = `${scenario.name}, exchange ${i + 1}`;
    const does = exchange.page_does;

    if (does.boot) {
      // The page also tells the host its master volume as it opens, which is
      // not part of the preset contract.
      const said = posted.filter(text => JSON.parse(text).type !== "volume");
      assert.deepEqual(said, exchange.page_to_host, `${at}: what the page said on opening`);
    } else if (does.injected) {
      // A request the page cannot be made to send, such as a bank that is not
      // a bank: the host side is fed it, and this side only hears the answer.
    } else {
      posted.length = 0;
      act(page, does);
      assert.deepEqual(posted, exchange.page_to_host, `${at}: what the page said`);
    }

    // What the host does by itself is the Odin side's to do; the page hears the
    // strings it posts. A key spelt differently there would never be played.
    for (const key of Object.keys(exchange.host_does ?? {})) {
      assert.ok(HOST_DOES.includes(key), `${at}: the fixture has a host_does key this test does not know: ${key}`);
    }

    posted.length = 0;
    for (const text of exchange.host_to_page) {
      assert.equal(typeof text, "string");
      page.window.synthReceive(text);
    }

    expectPage(page, scenario, exchange.page_effect, at);
    assert.deepEqual(posted, [], `${at}: the page answered the host`);
  });
}

for (const scenario of FIXTURE.scenarios) test(`wire: ${scenario.name}`, () => play(scenario));
