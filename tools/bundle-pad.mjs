// Assemble Quesynth Pad into a self-contained web distribution directory.
//
// The source interface deliberately remains a set of classic scripts: native
// web views can open ui/pad.html directly from disk and do not need a module
// loader. This tool is a production packaging step. It preserves the order in
// pad.html while combining those scripts, then adds the browser host artifacts
// that cannot be folded into JavaScript (the AudioWorklet and WebAssembly).
//
//   node tools/bundle-pad.mjs
//   node tools/bundle-pad.mjs --output build/my-pad

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY = path.resolve(HERE, "..");
const SCRIPT_TAG = /<script\b[^>]*\bsrc\s*=\s*(["'])([^"']+)\1[^>]*>\s*<\/script\s*>/gi;

function inside(directory, candidate) {
  const relative = path.relative(directory, candidate);
  return relative !== "" && !relative.startsWith(".." + path.sep) &&
    relative !== ".." && !path.isAbsolute(relative);
}

function rejectLinks(directory, candidate) {
  if (!fs.existsSync(directory)) return;
  if (fs.lstatSync(directory).isSymbolicLink()) {
    throw new Error(`refusing a symlinked build directory: ${directory}`);
  }
  const relative = path.relative(directory, candidate);
  let current = directory;
  for (const part of relative.split(path.sep)) {
    current = path.join(current, part);
    if (!fs.existsSync(current)) break;
    if (fs.lstatSync(current).isSymbolicLink()) {
      throw new Error(`refusing a symlink in the output path: ${current}`);
    }
  }
}

export function safeOutput(repository, requested) {
  const root = path.resolve(repository);
  const build = path.join(root, "build");
  const output = path.resolve(root, requested || path.join("build", "quesynth-pad"));
  if (!inside(build, output)) {
    throw new Error(`output must be a directory below ${build}: ${output}`);
  }
  rejectLinks(build, output);
  return output;
}

export function scriptsIn(html) {
  const scripts = [];
  for (const match of html.matchAll(SCRIPT_TAG)) scripts.push(match[2]);
  if (!scripts.length) throw new Error("pad.html contains no external scripts");
  return scripts;
}

function safeRelativeScript(source) {
  const normal = source.replaceAll("/", path.sep);
  if (path.isAbsolute(normal) || normal.split(path.sep).includes("..") ||
      /^[a-z][a-z0-9+.-]*:/i.test(source) || source.includes("?") ||
      source.includes("#")) {
    throw new Error(`pad.html contains an unsafe script path: ${source}`);
  }
  return normal;
}

function resolveOverlay(repository, source) {
  const relative = safeRelativeScript(source);
  const candidates = [
    path.join(repository, "hosts", "wasm", relative),
    path.join(repository, "ui", relative),
  ];
  return candidates.find(file => fs.existsSync(file) && fs.statSync(file).isFile()) || null;
}

function bundledHtml(html) {
  let first = true;
  return html.replace(SCRIPT_TAG, () => {
    if (!first) return "";
    first = false;
    return '<script src="quesynth-pad.js"></script>';
  });
}

function boundary(repository, file) {
  return path.relative(repository, file).replaceAll(path.sep, "/");
}

function readRequired(file, description) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    throw new Error(`missing ${description}: ${file}`);
  }
  return fs.readFileSync(file);
}

export function bundlePad({
  repository = REPOSITORY,
  output = path.join("build", "quesynth-pad"),
  allowMissingBank = false,
} = {}) {
  const root = path.resolve(repository);
  const destination = safeOutput(root, output);
  const htmlFile = path.join(root, "ui", "pad.html");
  const cssFile = path.join(root, "ui", "style.css");
  const workletFile = path.join(root, "hosts", "wasm", "worklet.js");
  const wasmFile = path.join(root, "hosts", "wasm", "synth.wasm");

  // Read and validate every input before removing a previous bundle. A failed
  // rebuild should leave the last known-good artifact available for inspection.
  const html = readRequired(htmlFile, "pad page").toString("utf8");
  const css = readRequired(cssFile, "pad stylesheet");
  const worklet = readRequired(workletFile, "AudioWorklet");
  const wasm = readRequired(wasmFile, "WebAssembly engine");
  const sources = [];
  for (const source of scriptsIn(html)) {
    const file = resolveOverlay(root, source);
    if (!file) {
      if (allowMissingBank && source === "bank.js") continue;
      const hint = source === "bank.js" ? " (run `odin run tools/uibank` first)" : "";
      throw new Error(`missing script from pad.html: ${source}${hint}`);
    }
    sources.push({source, file, contents: fs.readFileSync(file, "utf8")});
  }

  fs.rmSync(destination, {recursive: true, force: true});
  fs.mkdirSync(destination, {recursive: true});

  const javascript = sources.map(({file, contents}) => {
    const name = boundary(root, file);
    // A leading semicolon preserves the boundary between independently parsed
    // classic scripts when one happens to end in an expression without one.
    return `/* quesynth bundle: ${name} */\n;${contents.trimEnd()}\n`;
  }).join("\n");

  fs.writeFileSync(path.join(destination, "pad.html"), bundledHtml(html), "utf8");
  fs.writeFileSync(path.join(destination, "quesynth-pad.js"), javascript, "utf8");
  fs.writeFileSync(path.join(destination, "style.css"), css);
  fs.writeFileSync(path.join(destination, "worklet.js"), worklet);
  fs.writeFileSync(path.join(destination, "synth.wasm"), wasm);

  return {
    output: destination,
    scripts: sources.map(({source}) => source),
    bytes: javascript.length,
  };
}

export function parseArgs(argv) {
  let output = path.join("build", "quesynth-pad");
  let allowMissingBank = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--allow-missing-bank") {
      allowMissingBank = true;
    } else if (arg === "--output") {
      if (!argv[i + 1]) throw new Error("--output needs a path");
      output = argv[++i];
    } else if (arg.startsWith("--output=")) {
      output = arg.slice("--output=".length);
      if (!output) throw new Error("--output needs a path");
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return {output, allowMissingBank};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = bundlePad(parseArgs(process.argv.slice(2)));
    console.log(
      `bundled ${result.scripts.length} scripts (${result.bytes} bytes) into ${result.output}`
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
