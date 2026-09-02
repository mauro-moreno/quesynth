// Structural check for the artifact produced by tools/bundle-pad.mjs.
// It does not start Web Audio; it catches incomplete or internally inconsistent
// distributions before a browser turns those mistakes into a silent pad.
//
//   node tools/check-pad-bundle.mjs [build/quesynth-pad]
//
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import {fileURLToPath} from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY = path.resolve(HERE, "..");
const REQUIRED = ["pad.html", "quesynth-pad.js", "style.css", "worklet.js", "synth.wasm"];

function regularNonempty(file) {
  return fs.existsSync(file) && fs.statSync(file).isFile() && fs.statSync(file).size > 0;
}

export function checkPadBundle(directory, {allowMissingBank = false} = {}) {
  const root = path.resolve(directory);
  const problems = [];
  for (const name of REQUIRED) {
    if (!regularNonempty(path.join(root, name))) problems.push(`missing or empty ${name}`);
  }
  if (problems.length) throw new Error(problems.join("\n"));

  const html = fs.readFileSync(path.join(root, "pad.html"), "utf8");
  const js = fs.readFileSync(path.join(root, "quesynth-pad.js"), "utf8");
  const wasm = fs.readFileSync(path.join(root, "synth.wasm"));

  const scripts = [...html.matchAll(/<script\b[^>]*\bsrc\s*=\s*(["'])([^"']+)\1/gi)]
    .map(match => match[2]);
  if (scripts.length !== 1 || scripts[0] !== "quesynth-pad.js") {
    problems.push(`pad.html must load only quesynth-pad.js; found ${JSON.stringify(scripts)}`);
  }
  if (!/<link\b[^>]*\bhref\s*=\s*(["'])style\.css\1/i.test(html)) {
    problems.push("pad.html does not load style.css");
  }

  const boot = js.indexOf("quesynth bundle: ui/pad-boot.js");
  const host = js.indexOf("quesynth bundle: hosts/wasm/host.js");
  const bridge = js.indexOf("quesynth bundle: ui/bridge.js");
  const pad = js.indexOf("quesynth bundle: ui/pad.js");
  if (boot < 0) problems.push("bundle is missing pad-boot.js");
  if (host < 0) problems.push("bundle is missing the WebAssembly host.js overlay");
  if (bridge < 0) problems.push("bundle is missing bridge.js");
  if (pad < 0) problems.push("bundle is missing pad.js");
  if ([boot, host, bridge, pad].every(index => index >= 0) &&
      !(boot < host && host < bridge && bridge < pad)) {
    problems.push("pad boot, browser host, bridge, and pad controller are out of order");
  }
  if (!allowMissingBank && !js.includes("quesynth bundle: ui/bank.js")) {
    problems.push("bundle is missing generated ui/bank.js");
  }
  if (!js.includes('"synth.wasm"') && !js.includes("'synth.wasm'")) {
    problems.push("browser host does not name synth.wasm");
  }

  try {
    new vm.Script(js, {filename: "quesynth-pad.js"});
  } catch (error) {
    problems.push(`quesynth-pad.js does not parse: ${error.message}`);
  }
  try {
    new vm.Script(fs.readFileSync(path.join(root, "worklet.js"), "utf8"), {
      filename: "worklet.js",
    });
  } catch (error) {
    problems.push(`worklet.js does not parse: ${error.message}`);
  }
  if (wasm.length < 8 || wasm.subarray(0, 4).toString("hex") !== "0061736d") {
    problems.push("synth.wasm does not have the WebAssembly magic header");
  }

  if (problems.length) throw new Error(problems.join("\n"));
  return {directory: root, scripts, bytes: js.length};
}

function parseArgs(argv) {
  let directory = path.join(REPOSITORY, "build", "quesynth-pad");
  let allowMissingBank = false;
  for (const arg of argv) {
    if (arg === "--allow-missing-bank") allowMissingBank = true;
    else if (!arg.startsWith("--")) directory = path.resolve(arg);
    else throw new Error(`unknown argument: ${arg}`);
  }
  return {directory, allowMissingBank};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const result = checkPadBundle(options.directory, options);
    console.log(`pad bundle complete: ${result.bytes} bytes of JavaScript in ${result.directory}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
