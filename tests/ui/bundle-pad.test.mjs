import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {bundlePad, parseArgs, safeOutput, scriptsIn} from "../../tools/bundle-pad.mjs";
import {checkPadBundle} from "../../tools/check-pad-bundle.mjs";

const SCRIPT_NAMES = [
  "pad-boot.js",
  "host.js",
  "params.js",
  "bank.js",
  "bridge.js",
  "pad.js",
];

function temporary(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "quesynth-pad-bundle-"));
  try {
    return run(directory);
  } finally {
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

function fixture(root) {
  const ui = path.join(root, "ui");
  const wasm = path.join(root, "hosts", "wasm");
  fs.mkdirSync(ui, {recursive: true});
  fs.mkdirSync(wasm, {recursive: true});
  fs.mkdirSync(path.join(root, "build"), {recursive: true});

  const tags = SCRIPT_NAMES.map(name =>
    `<script src="${name}"${name === "host.js" ? ' onerror="void 0"' : ""}></script>`
  ).join("\n");
  fs.writeFileSync(path.join(ui, "pad.html"), [
    "<!doctype html>",
    '<link rel="stylesheet" href="style.css">',
    "<body><main></main>",
    tags,
    "</body>",
  ].join("\n"));
  fs.writeFileSync(path.join(ui, "style.css"), "body { color: white; }\n");
  fs.writeFileSync(path.join(ui, "pad-boot.js"), "window.order = ['boot']\n");
  fs.writeFileSync(path.join(ui, "host.js"), "window.order.push('wrong ui host')\n");
  fs.writeFileSync(path.join(wasm, "host.js"),
    "window.order.push('wasm host'); window.wasmName = \"synth.wasm\"\n");
  fs.writeFileSync(path.join(ui, "params.js"), "window.order.push('params')\n");
  fs.writeFileSync(path.join(ui, "bank.js"), "window.order.push('bank')\n");
  fs.writeFileSync(path.join(ui, "bridge.js"), "window.order.push('bridge')\n");
  fs.writeFileSync(path.join(ui, "pad.js"), "window.order.push('pad')\n");
  fs.writeFileSync(path.join(wasm, "worklet.js"), "class PadWorklet {}\n");
  fs.writeFileSync(path.join(wasm, "synth.wasm"),
    Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]));
}

test("bundle preserves page order, applies the host overlay, and cleans stale output", () => {
  temporary(root => {
    fixture(root);
    const output = path.join(root, "build", "release");
    fs.mkdirSync(output, {recursive: true});
    fs.writeFileSync(path.join(output, "stale.js"), "old");

    const result = bundlePad({repository: root, output});
    assert.deepEqual(result.scripts, SCRIPT_NAMES);
    assert.equal(fs.existsSync(path.join(output, "stale.js")), false);

    const html = fs.readFileSync(path.join(output, "pad.html"), "utf8");
    assert.deepEqual(scriptsIn(html), ["quesynth-pad.js"]);
    assert.doesNotMatch(html, /onerror=/);
    const javascript = fs.readFileSync(path.join(output, "quesynth-pad.js"), "utf8");
    const tokens = ["['boot']", "'wasm host'", "'params'", "'bank'", "'bridge'", "'pad'"];
    for (let i = 1; i < tokens.length; i++) {
      assert.ok(javascript.indexOf(tokens[i - 1]) < javascript.indexOf(tokens[i]),
        `${tokens[i - 1]} must precede ${tokens[i]}`);
    }
    assert.doesNotMatch(javascript, /wrong ui host/);
    assert.deepEqual(fs.readFileSync(path.join(output, "style.css")),
      fs.readFileSync(path.join(root, "ui", "style.css")));
    assert.deepEqual(fs.readFileSync(path.join(output, "worklet.js")),
      fs.readFileSync(path.join(root, "hosts", "wasm", "worklet.js")));
    assert.deepEqual(fs.readFileSync(path.join(output, "synth.wasm")),
      fs.readFileSync(path.join(root, "hosts", "wasm", "synth.wasm")));

    assert.equal(checkPadBundle(output).scripts[0], "quesynth-pad.js");
  });
});

test("output safety rejects build itself, siblings, traversal, and symlinks", () => {
  temporary(root => {
    fixture(root);
    const outside = path.join(root, "keep-me");
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, "sentinel"), "present");

    for (const output of ["build", "elsewhere", path.join("build", "..", "elsewhere")]) {
      assert.throws(() => safeOutput(root, output), /below/);
    }
    assert.equal(fs.readFileSync(path.join(outside, "sentinel"), "utf8"), "present");

    const link = path.join(root, "build", "linked");
    try {
      fs.symlinkSync(outside, link, process.platform === "win32" ? "junction" : "dir");
      assert.throws(() => safeOutput(root, path.join(link, "release")), /symlink/);
    } catch (error) {
      // Some Windows environments deny creating junctions to unprivileged test
      // processes. That platform limitation is not a bundler failure.
      if (!error.message.includes("EPERM") && !error.message.includes("privilege")) throw error;
    }
  });
});

test("a missing generated bank fails before cleaning unless explicitly allowed", () => {
  temporary(root => {
    fixture(root);
    fs.rmSync(path.join(root, "ui", "bank.js"));
    const output = path.join(root, "build", "release");
    fs.mkdirSync(output);
    const sentinel = path.join(output, "previous-good-bundle");
    fs.writeFileSync(sentinel, "keep");

    assert.throws(() => bundlePad({repository: root, output}), /run `odin run tools\/uibank`/);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "keep");

    const result = bundlePad({repository: root, output, allowMissingBank: true});
    assert.equal(result.scripts.includes("bank.js"), false);
    assert.equal(fs.existsSync(sentinel), false);
    assert.doesNotThrow(() => checkPadBundle(output, {allowMissingBank: true}));
  });
});

test("missing required inputs and unsafe script paths fail before cleaning", () => {
  temporary(root => {
    fixture(root);
    const output = path.join(root, "build", "release");
    fs.mkdirSync(output);
    const sentinel = path.join(output, "previous-good-bundle");
    fs.writeFileSync(sentinel, "keep");

    fs.rmSync(path.join(root, "ui", "bridge.js"));
    assert.throws(() => bundlePad({repository: root, output}), /missing script.*bridge\.js/);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "keep");

    fixture(root);
    const htmlFile = path.join(root, "ui", "pad.html");
    fs.writeFileSync(htmlFile,
      fs.readFileSync(htmlFile, "utf8").replace('src="params.js"', 'src="../secret.js"'));
    assert.throws(() => bundlePad({repository: root, output}), /unsafe script path/);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "keep");
  });
});

test("checker rejects malformed JavaScript and a file merely named wasm", () => {
  temporary(root => {
    fixture(root);
    const output = path.join(root, "build", "release");
    bundlePad({repository: root, output});

    fs.appendFileSync(path.join(output, "quesynth-pad.js"), "\nfunction {\n");
    assert.throws(() => checkPadBundle(output), /does not parse/);

    bundlePad({repository: root, output});
    fs.writeFileSync(path.join(output, "synth.wasm"), "not wasm");
    assert.throws(() => checkPadBundle(output), /magic header/);
  });
});

test("CLI argument parsing supports both output forms and rejects ambiguity", () => {
  assert.deepEqual(parseArgs([]), {
    output: path.join("build", "quesynth-pad"),
    allowMissingBank: false,
  });
  assert.deepEqual(parseArgs(["--output", "build/a", "--allow-missing-bank"]), {
    output: "build/a",
    allowMissingBank: true,
  });
  assert.deepEqual(parseArgs(["--output=build/b"]), {
    output: "build/b",
    allowMissingBank: false,
  });
  assert.throws(() => parseArgs(["--output"]), /needs a path/);
  assert.throws(() => parseArgs(["--wat"]), /unknown argument/);
});
