// Tests for tools/compare-patch.ps1, run through PowerShell the way a user runs
// it.
//
// The reference plugin only loads on Windows, so s1probe and odin are stand-ins
// here: small scripts that record the command line they were given and the
// hash of the patch file they were pointed at, and write WAVs (or fail) as
// told. What is checked is what the script decides -- which file, which
// arguments, what it keeps -- against fixture banks whose answer is known on
// sight. The stand-ins are Unix scripts, so this skips on Windows, and it skips
// where PowerShell is not installed. Set PWSH to use one that is not on PATH.
import test from "node:test";
import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {createHash} from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const PWSH = process.env.PWSH || "pwsh";
const SCRIPT = path.join(import.meta.dirname, "compare-patch.ps1");
const pwshRuns = spawnSync(PWSH, ["-NoProfile", "-Command", "exit 0"]).status === 0;
const skip = process.platform === "win32" ? "the stand-ins are Unix scripts"
  : !pwshRuns ? `no PowerShell at ${PWSH}` : false;

const sha = bytes => createHash("sha256").update(bytes).digest("hex");

// Records its arguments and the patch's hash, then behaves as FAKE_MODE says.
const S1PROBE = `
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const args = process.argv.slice(2);
const target = args[2];
const hash = fs.existsSync(target) ? crypto.createHash("sha256").update(fs.readFileSync(target)).digest("hex") : null;
fs.appendFileSync(process.env.FAKE_LOG, JSON.stringify({tool: "s1probe", args, hash}) + "\\n");
const mode = process.env.FAKE_MODE || "ok";
if (mode === "crash") process.exit(3);
if (mode === "silent") { console.error(path.basename(target) + ": cannot parse"); process.exit(0); }
const wav = args[args.indexOf("--wav") + 1];
// compare.odin's rule: cut at the last dot, unless the dot is the first character.
const base = path.basename(target), dot = base.lastIndexOf(".");
const stem = dot > 0 ? base.slice(0, dot) : base;
for (const kind of mode === "ref-only" ? ["ref"] : ["ref", "ours", "residual"]) {
  fs.writeFileSync(path.join(wav, stem + "." + kind + ".wav"), kind + " " + (process.env.FAKE_TAG || "") + " " + hash);
}
`;

// Records its arguments and "builds" by writing the s1probe stand-in. Like the
// real odin (dev-2026-09), it refuses an -out path with a bracket in it.
const ODIN = `
const fs = require("fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_LOG, JSON.stringify({tool: "odin", args, cwd: process.cwd()}) + "\\n");
if (process.env.FAKE_ODIN_FAIL) { console.error("odin: Syntax Error"); process.exit(1); }
const out = args.find(a => a.startsWith("-out:")).slice(5);
if (/[[\\]]/.test(out)) { console.error("Invalid -out path, got " + out); process.exit(1); }
fs.writeFileSync(out, fs.readFileSync(process.env.FAKE_S1PROBE));
fs.chmodSync(out, 0o755);
`;

const OPENER = `
require("fs").appendFileSync(process.env.FAKE_LOG, JSON.stringify({tool: "open", args: process.argv.slice(2)}) + "\\n");
`;

const writeScript = (file, body) => {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, `#!${process.execPath}\n${body}`);
  fs.chmodSync(file, 0o755);
};

// A repository with the script in it, under a path with a space and brackets,
// and a bank whose files are created out of order. Sorted by name, ordinally,
// the bank is 001, 002, 010, Lead [A], UPPER.SY1, bass -- a culture-aware sort
// would put bass before Lead.
const BANK = ["010.sy1", "bass.sy1", "002.sy1", "Lead [A].sy1", "notes.txt", "UPPER.SY1", "001.sy1"];

const fixture = t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "compare-patch-"));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const root = path.join(dir, "q root [1]");
  const fx = {
    dir, root,
    script: path.join(root, "tools", "compare-patch.ps1"),
    bank: path.join(dir, "bank [x] y"),
    bin: path.join(dir, "bin"),
    log: path.join(dir, "calls.jsonl"),
    s1probe: path.join(root, "build", "s1probe.exe"),
    render: path.join(root, "build", "render.exe"),
    dll: path.join(root, "ext", "synth1", "Synth1", "Synth1 VST64.dll"),
    standIn: path.join(dir, "s1probe-stand-in"),
  };
  fs.mkdirSync(path.dirname(fx.script), {recursive: true});
  fs.copyFileSync(SCRIPT, fx.script);
  writeScript(fx.standIn, S1PROBE);
  writeScript(fx.s1probe, S1PROBE);
  writeScript(fx.render, S1PROBE);
  writeScript(path.join(fx.bin, "odin"), ODIN);
  writeScript(path.join(fx.bin, "xdg-open"), OPENER);
  fs.mkdirSync(path.dirname(fx.dll), {recursive: true});
  fs.writeFileSync(fx.dll, "not really a plugin");
  fs.mkdirSync(fx.bank);
  for (const name of BANK) fs.writeFileSync(path.join(fx.bank, name), `${name}\r\nver=112\r\n0,1\r\n`);
  fs.writeFileSync(fx.log, "");
  return fx;
};

const run = (fx, args, {cwd = fx.dir, env = {}} = {}) => {
  const result = spawnSync(PWSH, ["-NoProfile", "-NonInteractive", "-File", fx.script, ...args], {
    cwd,
    encoding: "utf8",
    env: {PATH: fx.bin, HOME: fx.dir, NO_COLOR: "1", FAKE_LOG: fx.log, FAKE_S1PROBE: fx.standIn, ...env},
  });
  // PowerShell wraps an error to the console's width under a "     | " gutter.
  const out = (result.stdout + result.stderr).replace(/\x1b\[[0-9;]*m/g, "").replace(/\s*\n\s+\| /g, " ");
  const calls = fs.readFileSync(fx.log, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line));
  fs.writeFileSync(fx.log, "");
  return {status: result.status, out, calls};
};

const outDir = fx => path.join(fx.root, "build", "compare-patch");
const listing = dir => fs.existsSync(dir) ? fs.readdirSync(dir).sort() : [];

test("a number counts the bank's .sy1 files from 1 in name order", {skip}, t => {
  const fx = fixture(t);
  const expected = [["1", "001.sy1"], ["3", "010.sy1"], ["004", "Lead [A].sy1"], ["5", "UPPER.SY1"], ["6", "bass.sy1"]];
  for (const [selector, name] of expected) {
    const r = run(fx, [fx.bank, selector]);
    assert.equal(r.status, 0, r.out);
    const probe = r.calls.filter(c => c.tool === "s1probe");
    assert.equal(probe.length, 1, r.out);
    assert.equal(probe[0].args[2], path.join(fx.bank, name), `selector ${selector}`);
  }
});

test("the probe is given the plugin, the patch file as it is, and the note", {skip}, t => {
  const fx = fixture(t);
  const patch = path.join(fx.bank, "002.sy1");
  const before = sha(fs.readFileSync(patch));
  const r = run(fx, [fx.bank, "2"]);
  assert.equal(r.status, 0, r.out);
  const [probe] = r.calls;
  assert.deepEqual(probe.args.slice(0, 3), ["compare", fx.dll, patch]);
  assert.deepEqual(probe.args.slice(5), ["--note", "60"]);
  assert.equal(probe.args[3], "--wav");
  assert.equal(path.dirname(probe.args[4]), outDir(fx), "the probe wrote somewhere other than the output directory");
  assert.equal(probe.hash, before, "the probe read different bytes from the bank's file");
  assert.equal(sha(fs.readFileSync(patch)), before, "the patch file changed");
  assert.deepEqual(listing(fx.bank), [...BANK].sort());

  const out = outDir(fx);
  assert.deepEqual(listing(out), ["002.ours.wav", "002.ref.wav", "002.residual.wav"]);
  assert.equal(fs.readFileSync(path.join(out, "002.ours.wav"), "utf8"), `ours  ${before}`);
  assert.match(r.out, new RegExp(`reference: ${RegExp.escape(path.join(out, "002.ref.wav"))}`));
  assert.match(r.out, new RegExp(`quesynth:  ${RegExp.escape(path.join(out, "002.ours.wav"))}`));
});

test("a name is looked up in the bank, brackets and spaces included", {skip}, t => {
  const fx = fixture(t);
  const r = run(fx, [fx.bank, "Lead [A].sy1", "-Note", "0"]);
  assert.equal(r.status, 0, r.out);
  assert.equal(r.calls[0].args[2], path.join(fx.bank, "Lead [A].sy1"));
  assert.deepEqual(r.calls[0].args.slice(5), ["--note", "0"]);
  assert.deepEqual(listing(outDir(fx)), ["Lead [A].ours.wav", "Lead [A].ref.wav", "Lead [A].residual.wav"]);

  // Digits with the extension are a name, not a position: 010.sy1 is third.
  const named = run(fx, [fx.bank, "010.sy1"]);
  assert.equal(named.status, 0, named.out);
  assert.equal(named.calls[0].args[2], path.join(fx.bank, "010.sy1"));
});

test("paths the user gives are relative to where they ran it", {skip}, t => {
  const fx = fixture(t);
  const here = path.join(fx.dir, "elsewhere");
  fs.mkdirSync(path.join(here, "mine"), {recursive: true});
  fs.writeFileSync(path.join(here, "mine", "pad.sy1"), "pad\r\n");
  fs.writeFileSync(path.join(here, "other.dll"), "");
  const r = run(fx, ["../bank [x] y", "mine/pad.sy1", "-Dll", "other.dll", "-OutDir", "listen here", "-Note", "127"], {cwd: here});
  assert.equal(r.status, 0, r.out);
  assert.deepEqual(r.calls[0].args.slice(0, 3), ["compare", path.join(here, "other.dll"), path.join(here, "mine", "pad.sy1")]);
  assert.deepEqual(r.calls[0].args.slice(5), ["--note", "127"]);
  assert.deepEqual(listing(path.join(here, "listen here")), ["pad.ours.wav", "pad.ref.wav", "pad.residual.wav"]);
  assert.deepEqual(listing(outDir(fx)), []);

  const absolute = run(fx, [fx.bank, path.join(here, "mine", "pad.sy1"), "-OutDir", path.join(fx.dir, "abs out")], {cwd: here});
  assert.equal(absolute.status, 0, absolute.out);
  assert.equal(absolute.calls[0].args[2], path.join(here, "mine", "pad.sy1"));
  assert.deepEqual(listing(path.join(fx.dir, "abs out")), ["pad.ours.wav", "pad.ref.wav", "pad.residual.wav"]);
});

test("a second run replaces the pair, and the same selection picks the same file", {skip}, t => {
  const fx = fixture(t);
  const first = run(fx, [fx.bank, "4"], {env: {FAKE_TAG: "first"}});
  const second = run(fx, [fx.bank, "4"], {env: {FAKE_TAG: "second"}});
  assert.equal(first.status, 0, first.out);
  assert.equal(second.status, 0, second.out);
  assert.equal(first.calls[0].args[2], second.calls[0].args[2]);
  assert.match(fs.readFileSync(path.join(outDir(fx), "Lead [A].ref.wav"), "utf8"), /^ref second /);
  assert.deepEqual(listing(outDir(fx)), ["Lead [A].ours.wav", "Lead [A].ref.wav", "Lead [A].residual.wav"]);
});

test("bad input is refused before anything is built or run", {skip}, t => {
  const fx = fixture(t);
  fs.rmSync(fx.s1probe);
  const cases = [
    [[path.join(fx.dir, "nope"), "1"], /Bank directory not found: .*nope/],
    [[fx.bank, "0"], /Patch 0 is out of range: .* has 6 \.sy1 files, numbered 1 to 6/],
    [[fx.bank, "7"], /Patch 7 is out of range/],
    [[fx.bank, "99999999999"], /Patch 99999999999 is out of range/],
    [[fx.bank, "missing.sy1"], /Patch not found: .*missing\.sy1 \(a bare name is looked up in the bank/],
    [[fx.bank, "notes.txt"], /Not a \.sy1 file: .*notes\.txt/],
    [[fx.bank, "1", "-Dll", "plugin.so"], /-Dll must name the plugin's \.dll file/],
    [[fx.bank, "1", "-Dll", "absent.dll"], /Reference plugin not found: .*absent\.dll/],
    [[fx.bank, "1", "-Note", "128"], /128/],
  ];
  for (const [args, message] of cases) {
    const r = run(fx, args);
    assert.notEqual(r.status, 0, `${args.join(" ")} succeeded`);
    assert.match(r.out, message);
    assert.deepEqual(r.calls, [], `${args.join(" ")} built or ran something`);
  }
  const empty = path.join(fx.dir, "empty");
  fs.mkdirSync(empty);
  const r = run(fx, [empty, "1"]);
  assert.notEqual(r.status, 0);
  assert.match(r.out, /No \.sy1 files in .*empty/);

  fs.rmSync(fx.dll);
  const noPlugin = run(fx, [fx.bank, "1"]);
  assert.notEqual(noPlugin.status, 0);
  assert.match(noPlugin.out, /Reference plugin not found: .*Synth1 VST64\.dll\. Synth1 is not redistributed here/);
});

test("a failed comparison keeps nothing and leaves the earlier pair alone", {skip}, t => {
  const fx = fixture(t);
  const ok = run(fx, [fx.bank, "1"], {env: {FAKE_TAG: "good"}});
  assert.equal(ok.status, 0, ok.out);
  const out = outDir(fx);
  const kept = Object.fromEntries(listing(out).map(name => [name, fs.readFileSync(path.join(out, name), "utf8")]));

  for (const [mode, message] of [
    ["crash", /s1probe compare exited with code 3; no WAVs were kept/],
    ["silent", /s1probe compare did not write 001\.ref\.wav; see its output above\. No WAVs were kept/],
    ["ref-only", /s1probe compare did not write 001\.ours\.wav/],
  ]) {
    const r = run(fx, [fx.bank, "1", "-Open"], {env: {FAKE_MODE: mode, FAKE_TAG: "bad"}});
    assert.notEqual(r.status, 0, `${mode} reported success`);
    assert.match(r.out, message);
    assert.doesNotMatch(r.out, /reference: /);
    assert.deepEqual(listing(out), Object.keys(kept).sort(), `${mode} left files behind`);
    for (const [name, body] of Object.entries(kept)) {
      assert.equal(fs.readFileSync(path.join(out, name), "utf8"), body, `${mode} touched ${name}`);
    }
    assert.equal(r.calls.filter(c => c.tool === "open").length, 0, `${mode} opened a player`);
  }
});

test("missing tools are built with odin, or the build command is printed", {skip}, t => {
  const fx = fixture(t);
  fs.rmSync(fx.s1probe);
  fs.rmSync(fx.render);
  fs.rmSync(path.join(fx.root, "build"), {recursive: true});

  const noOdin = run(fx, [fx.bank, "1"], {env: {PATH: path.join(fx.dir, "nothing")}});
  assert.notEqual(noOdin.status, 0);
  assert.match(noOdin.out, /s1probe\.exe is missing and odin is not on PATH/);
  assert.match(noOdin.out, /Install Odin \(https:\/\/odin-lang\.org\/docs\/install\/\) and run this again\./);
  assert.match(noOdin.out, /from the repository root: New-Item -ItemType Directory -Force build; odin build tools\/s1probe -out:build\/s1probe\.exe/);
  assert.deepEqual(noOdin.calls, []);

  const failing = run(fx, [fx.bank, "1"], {env: {FAKE_ODIN_FAIL: "1"}});
  assert.notEqual(failing.status, 0);
  assert.match(failing.out, /Building s1probe failed \(odin exited with 1\)\. To build it by hand, from the repository root: New-Item -ItemType Directory -Force build; odin build tools\/s1probe/);
  assert.equal(failing.calls.filter(c => c.tool === "s1probe").length, 0);

  const built = run(fx, [fx.bank, "1"]);
  assert.equal(built.status, 0, built.out);
  assert.deepEqual(built.calls.map(c => c.tool), ["odin", "odin", "s1probe"]);
  // Built from inside build/, because the repository's path has brackets in it.
  assert.deepEqual(built.calls[0].args, ["build", path.join(fx.root, "tools", "s1probe"), "-out:s1probe.exe"]);
  assert.deepEqual(built.calls[1].args, ["build", path.join(fx.root, "tools", "render"), "-out:render.exe"]);
  assert.equal(built.calls[0].cwd, path.join(fx.root, "build"));
  assert.ok(fs.existsSync(fx.s1probe) && fs.existsSync(fx.render));

  // Present now, so not built again.
  const again = run(fx, [fx.bank, "1"]);
  assert.equal(again.status, 0, again.out);
  assert.deepEqual(again.calls.map(c => c.tool), ["s1probe"]);
});

test("-Open opens the reference and Quesynth WAVs after they are written", {skip}, async t => {
  const fx = fixture(t);
  const r = run(fx, [fx.bank, "2"]);
  assert.equal(r.calls.filter(c => c.tool === "open").length, 0, "opened without -Open");

  const opened = spawnSync(PWSH, ["-NoProfile", "-NonInteractive", "-File", fx.script, fx.bank, "2", "-Open"], {
    cwd: fx.dir,
    encoding: "utf8",
    env: {PATH: fx.bin, HOME: fx.dir, FAKE_LOG: fx.log, FAKE_S1PROBE: fx.standIn},
  });
  assert.equal(opened.status, 0, opened.stdout + opened.stderr);
  // The opener is started, not waited for.
  let calls = [];
  for (let i = 0; i < 50; i++) {
    calls = fs.readFileSync(fx.log, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line))
      .filter(c => c.tool === "open");
    if (calls.length >= 2) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.deepEqual(calls.map(c => c.args.at(-1)).sort(),
    [path.join(outDir(fx), "002.ours.wav"), path.join(outDir(fx), "002.ref.wav")]);
});

test("a patch is named the way s1probe names its WAVs, hidden files included", {skip}, t => {
  const fx = fixture(t);
  const bank = path.join(fx.dir, "dotted");
  fs.mkdirSync(bank);
  fs.writeFileSync(path.join(bank, "001.sy1"), "one\r\n");
  fs.writeFileSync(path.join(bank, ".sy1"), "dot\r\n");
  fs.writeFileSync(path.join(bank, "a.b.sy1"), "ab\r\n");

  // Sorted ordinally, "." comes before the digits, and a dot file counts.
  const first = run(fx, [bank, "1"]);
  assert.equal(first.status, 0, first.out);
  assert.equal(first.calls[0].args[2], path.join(bank, ".sy1"));
  assert.deepEqual(listing(outDir(fx)), [".sy1.ours.wav", ".sy1.ref.wav", ".sy1.residual.wav"]);

  const dotted = run(fx, [bank, "a.b.sy1"]);
  assert.equal(dotted.status, 0, dotted.out);
  assert.ok(fs.existsSync(path.join(outDir(fx), "a.b.ref.wav")), dotted.out);
});

// A player holding the old file is a Windows lock; a file that cannot be opened
// for writing stands in for it here.
test("an old WAV that cannot be replaced leaves the whole old pair in place", {skip}, t => {
  const fx = fixture(t);
  assert.equal(run(fx, [fx.bank, "1"], {env: {FAKE_TAG: "old"}}).status, 0);
  const ours = path.join(outDir(fx), "001.ours.wav");
  fs.chmodSync(ours, 0o444);
  const r = run(fx, [fx.bank, "1", "-Open"], {env: {FAKE_TAG: "new"}});
  assert.notEqual(r.status, 0);
  assert.match(r.out, /001\.ours\.wav is open in another program; close it and run this again\. No WAVs were replaced\./);
  for (const kind of ["ref", "ours", "residual"]) {
    assert.match(fs.readFileSync(path.join(outDir(fx), `001.${kind}.wav`), "utf8"), /^\w+ old /, kind);
  }
  assert.deepEqual(listing(outDir(fx)), ["001.ours.wav", "001.ref.wav", "001.residual.wav"]);
  assert.equal(r.calls.filter(c => c.tool === "open").length, 0);
});
