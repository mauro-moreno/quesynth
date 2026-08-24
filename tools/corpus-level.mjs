#!/usr/bin/env node
// corpus-level - prepare and analyse the sub-oscillator level gate.
//
//   node tools/corpus-level.mjs prepare <corpus-root> <output-prefix>
//   node tools/corpus-level.mjs analyse <on.csv> <off.csv> <index.csv> [on-variant off-variant]
//   node tools/corpus-level.mjs contrast <on.csv> <off.csv> <control-on.csv> <control-off.csv> <index.csv> <control>
//
// The gate in docs/null-test.md asks whether parameter 95 is normalised right
// on real patches. That needs a cohort the factory bank cannot supply -- no
// factory patch sets the sub at all -- so it is selected from a large corpus,
// and a selection made by hand is a selection that can be made to say
// anything. `prepare` is here so the cohort, its sub-off control and its
// section controls all come out of one rule that a reader can re-run.
//
// `analyse` exists for the same reason. The number the gate moves is a mean
// absolute error, and a signed mean, a correlation or a fitted slope can all
// stay flat while it moves; those statistics answer different questions and
// substituting one for another is how an unexplained residual gets called
// explained. So the mean absolute change is computed directly, per row, and
// the rows that carry it are named.
//
// `contrast` compares two matched pairs -- the same patches with one section
// of the engine neutralised in both -- row by row. A control that shrinks the
// whole error shrinks every difference with it, so the per-row numbers and the
// overall scale are printed together and the reader can see which moved.
import fs from "node:fs";
import path from "node:path";
import {createHash} from "node:crypto";
import {fileURLToPath} from "node:url";

// Selection rule. Sub gain at or above a quarter scale so the sub is audible,
// and the four things that would put a second unmeasured effect in the same
// reading off: unison (73), oscillator sync (6), ring modulation (7) and
// oscillator 1 FM (45), whose path to the sub is not measured either way.
const SELECT_MIN_GAIN = 32;
const SELECT_ZERO = [73, 6, 7, 45];
const PARAMETER_COUNT = 99;
// The committed identity of the measured cohort. The index includes each
// selected source path, patch version, stable semantic identity, source-byte
// hash and every generated variant hash.
export const CORPUS_INDEX_SHA256 = "8b2ec1aa825fd68ede2ce9c227d8f44ea9f0e89040db1f50d16c6dc05f115ec3";

// Section controls, each neutralising one architectural section by setting the
// records that switch it off or flat. `post-off` is the union of the four
// post-voice controls above it; `filter-open` is not post-voice at all and is
// here as the check that any large section would do -- it does not.
const CONTROLS = new Map([
  ["eq-flat", new Map([[60, 64], [62, 64]])],
  ["delay-off", new Map([[65, 0]])],
  ["chorus-off", new Map([[66, 0]])],
  ["effect-off", new Map([[77, 0]])],
  ["post-off", new Map([[60, 64], [62, 64], [65, 0], [66, 0], [77, 0]])],
  ["filter-open", new Map([[10, 0], [14, 0], [19, 127], [20, 0], [21, 63], [22, 0], [23, 0], [24, 0]])],
]);

// A .sy1 file is ASCII records, but a patch name is whatever the author's code
// page held and one stray byte read as UTF-8 comes back as U+FFFD -- which
// would edit the input the gate is supposed to leave alone. latin1 maps every
// byte to one character and back, so a file this tool does not change comes out
// byte for byte identical.
const ENCODING = "latin1";

function sy1Record(line) {
  const match = line.trim().match(/^(\d+)\s*,\s*([+-]?\d+)$/);
  if (!match) return undefined;
  const index = Number(match[1]);
  if (index >= PARAMETER_COUNT) throw new Error(`parameter index ${index} is out of range`);
  return [index, Number(match[2])];
}

export function parseRecords(text) {
  const records = new Map();
  for (const line of text.split(/\r?\n/)) {
    const record = sy1Record(line);
    if (record) records.set(...record);
  }
  return records;
}

// Read enough of the file exactly as src/patch/sy1.odin does to reject input
// that the engine cannot load and to retain the version in the deduplication
// key. The same numeric records can mean something else before version 1.07.
export function parsePatch(text) {
  if (!text.trim()) throw new Error("missing patch header");
  const lines = text.split(/\r?\n/);
  let position = 0;
  const first = lines[0] ?? "";
  const firstIsRecord = /^(\d+)\s*,\s*([+-]?\d+)$/.test(first.trim());
  if (first.startsWith("Synth1 ") ||
      (!firstIsRecord && !first.startsWith("color=") &&
       !first.startsWith("ver="))) position++;
  if ((lines[position] ?? "").startsWith("color=")) position++;
  let version = 0;
  if ((lines[position] ?? "").startsWith("ver=")) {
    const value = lines[position].slice(4);
    if (!/^[+-]?\d+$/.test(value)) throw new Error("malformed patch version");
    version = Number(value);
    position++;
  }
  const records = new Map();
  for (; position < lines.length; position++) {
    const line = lines[position];
    if (!line.trim()) continue;
    const record = sy1Record(line);
    if (!record) throw new Error(`malformed patch line ${position + 1}`);
    records.set(...record);
  }
  return {version, records};
}

function recordKey(records) {
  return [...records].sort((a, b) => a[0] - b[0]).map(([i, v]) => `${i},${v}`).join("\n");
}

function semanticKey(version, records) {
  return `ver=${version}\n${recordKey(records)}`;
}

function collectSy1(root) {
  const found = [];
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.name.toLowerCase().endsWith(".sy1")) found.push(full);
    }
  };
  visit(root);
  return found.sort((a, b) => {
    const left = path.relative(root, a).replaceAll("\\", "/");
    const right = path.relative(root, b).replaceAll("\\", "/");
    return left < right ? -1 : left > right ? 1 : 0;
  });
}

// Rewrites records in place. Every occurrence, because the format allows a
// record to appear twice and the later one wins: changing the first and
// leaving the second would write a file whose effective value is the old one.
export function setRecords(text, changes) {
  let output = text;
  for (const [index, value] of changes) {
    const pattern = new RegExp(`^([ \\t]*${index}[ \\t]*,[ \\t]*)[+-]?\\d+([ \\t]*\\r?)$`, "gm");
    if (output.search(pattern) >= 0) { output = output.replace(pattern, `$1${value}$2`); continue; }
    // A missing record is appended without trimming the name, final spaces or
    // blank lines. Those bytes are outside the declared change.
    const eol = output.includes("\r\n") ? "\r\n" : "\n";
    const separator = !output || output.endsWith("\n") || output.endsWith("\r") ? "" : eol;
    output = `${output}${separator}${index},${value}${eol}`;
  }
  return output;
}

function resetDirectory(directory) {
  fs.rmSync(directory, {recursive: true, force: true});
  fs.mkdirSync(directory, {recursive: true});
}

function csvCell(value) {
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

export function prepareCorpus(root, prefix, controls = CONTROLS) {
  const files = collectSy1(root);
  const candidates = [];
  for (const source of files) {
    const text = fs.readFileSync(source, ENCODING);
    let parsed;
    try { parsed = parsePatch(text); }
    catch (error) { throw new Error(`${source}: ${error.message}`); }
    const {version, records} = parsed;
    if ((records.get(95) ?? 0) < SELECT_MIN_GAIN) continue;
    if (!SELECT_ZERO.every(index => (records.get(index) ?? 0) === 0)) continue;
    candidates.push({source, text, version, records, key: semanticKey(version, records)});
  }

  // Banks are copied and renamed constantly, so the same patch arrives many
  // times over. Deduplicating on the version and effective parameter records
  // keeps one row per distinct sound and does not let a popular patch weigh
  // more than a rare one.
  const unique = new Map();
  for (const candidate of candidates) if (!unique.has(candidate.key)) unique.set(candidate.key, candidate);
  const selected = [...unique.values()];

  const dirs = {on: `${prefix}-on`, off: `${prefix}-off`};
  for (const name of controls.keys()) {
    dirs[`on-${name}`] = `${prefix}-on-${name}`;
    dirs[`off-${name}`] = `${prefix}-off-${name}`;
  }
  Object.values(dirs).forEach(resetDirectory);

  const index = ["name,gain95,mix5,shape96,octave97,version,source,identity_sha256,source_sha256,variant_sha256"];
  selected.forEach((item, i) => {
    const name = `s${String(i).padStart(3, "0")}`;
    const filename = `${name}.sy1`;
    const off = setRecords(item.text, new Map([[95, 0]]));
    const variants = new Map([["on", item.text], ["off", off]]);
    fs.writeFileSync(path.join(dirs.on, filename), item.text, ENCODING);
    fs.writeFileSync(path.join(dirs.off, filename), off, ENCODING);
    for (const [control, changes] of controls) {
      const onText = setRecords(item.text, changes);
      const offText = setRecords(off, changes);
      variants.set(`on-${control}`, onText);
      variants.set(`off-${control}`, offText);
      fs.writeFileSync(path.join(dirs[`on-${control}`], filename), onText, ENCODING);
      fs.writeFileSync(path.join(dirs[`off-${control}`], filename), offText, ENCODING);
    }
    const variantHashes = [...variants].map(([variant, text]) =>
      `${variant}:${createHash("sha256").update(text, ENCODING).digest("hex")}`).join(";");
    const identity = createHash("sha256").update(item.key).digest("hex");
    index.push([
      name,
      item.records.get(95) ?? 0,
      item.records.get(5) ?? 0,
      item.records.get(96) ?? 0,
      item.records.get(97) ?? 0,
      item.version,
      path.relative(root, item.source).replaceAll("\\", "/"),
      identity,
      createHash("sha256").update(item.text, ENCODING).digest("hex"),
      variantHashes,
    ].map(csvCell).join(","));
  });
  const indexPath = `${prefix}-index.csv`;
  fs.writeFileSync(indexPath, index.join("\n") + "\n");
  return {files: files.length, candidates: candidates.length, selected: selected.length, dirs, indexPath};
}

export function verifyIndex(file, expected = CORPUS_INDEX_SHA256) {
  const actual = createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  if (actual !== expected) throw new Error(`${file}: index SHA-256 ${actual}, expected ${expected}`);
  return actual;
}

export function readCsv(file) {
  const text = fs.readFileSync(file, "utf8");
  const records = []; let record = []; let field = ""; let quoted = false;
  const pushField = () => { record.push(field); field = ""; };
  const pushRecord = () => {
    pushField();
    if (record.some(value => value !== "")) records.push(record);
    record = [];
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"' && quoted && text[i + 1] === '"') { field += '"'; i++; }
    else if (c === '"') quoted = !quoted;
    else if (c === "," && !quoted) pushField();
    else if ((c === "\n" || c === "\r") && !quoted) {
      if (c === "\r" && text[i + 1] === "\n") i++;
      pushRecord();
    } else field += c;
  }
  if (quoted) throw new Error(`${file}: unterminated quoted CSV field`);
  if (field !== "" || record.length) pushRecord();
  if (!records.length) return [];
  const header = records[0];
  return records.slice(1).map(fields => Object.fromEntries(header.map((key, i) => [key, fields[i] ?? ""])));
}

function mean(values) { return values.reduce((sum, value) => sum + value, 0) / values.length; }
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
function sum(values) { return values.reduce((total, value) => total + value, 0); }
function linear(x, y) {
  const xm = mean(x), ym = mean(y);
  const xx = x.reduce((total, value) => total + (value - xm) ** 2, 0);
  const yy = y.reduce((total, value) => total + (value - ym) ** 2, 0);
  const xy = x.reduce((total, value, i) => total + (value - xm) * (y[i] - ym), 0);
  return {slope: xx ? xy / xx : 0, correlation: xx && yy ? xy / Math.sqrt(xx * yy) : 0};
}

const TOP_ROWS = 6;
export function analysePair(onFile, offFile, indexFile, onVariant = "on", offVariant = "off", threshold = 0.05) {
  if (!indexFile) throw new Error("an index file is required for stable cohort identity");
  if (onVariant === offVariant) throw new Error("the pair must name two distinct variants");
  const onRows = readCsv(onFile), offRows = readCsv(offFile);
  const required = ["patch", "patch_sha256", "level_db", "param_mismatches", "ref_silent", "our_silent"];
  if (!onRows.length || !required.every(column => column in onRows[0])) throw new Error(`${onFile}: expected ${required.join(", ")} columns`);
  if (!offRows.length || !required.every(column => column in offRows[0])) throw new Error(`${offFile}: expected ${required.join(", ")} columns`);
  const indexRows = readCsv(indexFile);
  const indexRequired = ["name", "gain95", "mix5", "identity_sha256", "variant_sha256"];
  if (!indexRows.length || !indexRequired.every(column => column in indexRows[0])) {
    throw new Error(`${indexFile}: expected ${indexRequired.join(", ")} columns`);
  }

  // sNNN is only a display name and can be reassigned by another preparation.
  // Resolve exact variant bytes to semantic identity before joining metadata.
  const indexByIdentity = new Map();
  const indexNames = new Set();
  for (const meta of indexRows) {
    const identity = meta.identity_sha256.trim().toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(identity)) throw new Error(`${indexFile}: invalid identity_sha256 for ${meta.name}`);
    if (indexByIdentity.has(identity)) throw new Error(`${indexFile}: duplicate identity_sha256 ${identity}`);
    if (!meta.name || indexNames.has(meta.name)) throw new Error(`${indexFile}: duplicate or missing name ${meta.name}`);
    const variants = new Map();
    for (const token of meta.variant_sha256.split(";")) {
      const match = token.match(/^([^:]+):([0-9a-f]{64})$/i);
      if (!match) throw new Error(`${indexFile}: malformed variant_sha256 for ${meta.name}`);
      const label = match[1], digest = match[2].toLowerCase();
      if (variants.has(label)) throw new Error(`${indexFile}: duplicate variant ${label} for ${meta.name}`);
      variants.set(label, digest);
    }
    const normalized = {...meta, identity_sha256: identity, variants};
    indexByIdentity.set(identity, normalized);
    indexNames.add(meta.name);
  }

  const variantIndex = variant => {
    const result = new Map();
    for (const meta of indexByIdentity.values()) {
      const digest = meta.variants.get(variant);
      if (!digest) throw new Error(`${indexFile}: missing variant ${variant} for ${meta.name}`);
      if (result.has(digest)) throw new Error(`${indexFile}: variant ${variant} hash is ambiguous for ${meta.name}`);
      result.set(digest, meta);
    }
    return result;
  };
  const bind = (data, file, variant) => {
    const byDigest = variantIndex(variant);
    const byIdentity = new Map();
    for (const row of data) {
      const digest = row.patch_sha256.trim().toLowerCase();
      if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error(`${file}: invalid patch_sha256 for ${row.patch}`);
      const meta = byDigest.get(digest);
      if (!meta) throw new Error(`${file}: stale, reordered, or wrong-variant cohort row ${row.patch} for ${variant}`);
      const expectedName = `${meta.name}.sy1`;
      if (row.patch !== expectedName) {
        throw new Error(`${file}: stale or reordered cohort row ${row.patch}; hash belongs to ${expectedName}`);
      }
      if (byIdentity.has(meta.identity_sha256)) throw new Error(`${file}: duplicate identity_sha256 ${meta.identity_sha256}`);
      byIdentity.set(meta.identity_sha256, {row, meta});
    }
    return byIdentity;
  };
  const on = bind(onRows, onFile, onVariant), off = bind(offRows, offFile, offVariant);
  const expected = new Set(indexByIdentity.keys());
  const missing = rows => [...expected].filter(identity => !rows.has(identity));
  const extra = rows => [...rows.keys()].filter(identity => !expected.has(identity));
  const missingOn = missing(on), missingOff = missing(off), extraOn = extra(on), extraOff = extra(off);
  if (missingOn.length || missingOff.length || extraOn.length || extraOff.length) {
    const names = values => values.slice(0, 5).map(identity => indexByIdentity.get(identity)?.name ?? identity).join(", ") || "none";
    throw new Error(`${indexFile}: CSVs do not cover the full expected index (missing on: ${names(missingOn)}; missing off: ${names(missingOff)}; extra on: ${names(extraOn)}; extra off: ${names(extraOff)})`);
  }

  const rows = [];
  for (const [identity, onBound] of on) {
    const offBound = off.get(identity);
    if (!offBound) throw new Error(`${onBound.meta.name}: pair does not cover the same identity`);
    const a = onBound.row, b = offBound.row, meta = onBound.meta;
    const patch = `${meta.name}.sy1`;
    if (a.param_mismatches.trim() === "" || b.param_mismatches.trim() === "") {
      throw new Error(`${patch}: empty param_mismatches`);
    }
    const onMismatches = Number(a.param_mismatches), offMismatches = Number(b.param_mismatches);
    if (!Number.isInteger(onMismatches) || !Number.isInteger(offMismatches) ||
        onMismatches < 0 || offMismatches < 0) throw new Error(`${patch}: invalid param_mismatches`);
    if (onMismatches || offMismatches) throw new Error(`${patch}: reference parameter load mismatch (${onMismatches} on, ${offMismatches} off)`);
    if (a.ref_silent === "true" || a.our_silent === "true" || b.ref_silent === "true" || b.our_silent === "true") continue;
    if (a.level_db.trim() === "" || b.level_db.trim() === "") throw new Error(`${patch}: empty level_db`);
    const onLevel = Number(a.level_db), offLevel = Number(b.level_db);
    if (!Number.isFinite(onLevel) || !Number.isFinite(offLevel)) throw new Error(`${patch}: non-finite level_db`);
    const gain = Number(meta.gain95), mix = Number(meta.mix5);
    if (meta.gain95.trim() === "" || meta.mix5.trim() === "" || !Number.isFinite(gain) || !Number.isFinite(mix)) {
      throw new Error(`${indexFile}: invalid metadata for ${patch}`);
    }
    rows.push({patch, identity, onLevel, offLevel, signedDelta: onLevel - offLevel,
      absoluteDelta: Math.abs(onLevel) - Math.abs(offLevel),
      gain, weight: gain * (1 - mix / 127)});
  }
  if (!rows.length) throw new Error("no matched, non-silent rows");
  const absoluteDelta = rows.map(row => row.absoluteDelta);
  const signedDelta = rows.map(row => row.signedDelta);
  const onLevel = rows.map(row => row.onLevel), offLevel = rows.map(row => row.offLevel);
  const result = {
    rows,
    count: rows.length,
    onMae: mean(onLevel.map(Math.abs)),
    offMae: mean(offLevel.map(Math.abs)),
    maeDelta: mean(absoluteDelta),
    maeDeltaSum: sum(absoluteDelta),
    medianDelta: median(absoluteDelta),
    scale: mean(absoluteDelta.map(Math.abs)),
    signedDelta: mean(signedDelta),
    better: absoluteDelta.filter(value => value < -threshold).length,
    worse: absoluteDelta.filter(value => value > threshold).length,
    same: absoluteDelta.filter(value => Math.abs(value) <= threshold).length,
    onOffCorrelation: linear(offLevel, onLevel).correlation,
  };
  result.largestWorsening = [...rows].sort((a, b) => b.absoluteDelta - a.absoluteDelta).slice(0, TOP_ROWS);
  result.largestWorseningSum = sum(result.largestWorsening.map(row => row.absoluteDelta));
  const gainFit = linear(rows.map(row => row.gain), signedDelta);
  const weightFit = linear(rows.map(row => row.weight), signedDelta);
  result.gainSlope = gainFit.slope;
  result.gainCorrelation = gainFit.correlation;
  result.weightCorrelation = weightFit.correlation;
  return result;
}

// Two pairs over the same patches: the gate, and the gate with one section
// neutralised in both members. Only rows present in both pairs are used, so
// the two columns are the same patches or the call fails.
export function contrastPairs(base, control) {
  const controlRows = new Map(control.rows.map(row => [row.identity, row]));
  const missing = base.rows.filter(row => !controlRows.has(row.identity)).map(row => row.patch);
  if (missing.length || base.count !== control.count) {
    throw new Error(`the two pairs do not cover the same identities (${base.count} vs ${control.count}${missing.length ? `, missing ${missing.slice(0, 5).join(", ")}` : ""})`);
  }
  const carriers = base.largestWorsening.map(row => {
    const controlRow = controlRows.get(row.identity);
    return {
      patch: row.patch,
      identity: row.identity,
      base: row.absoluteDelta,
      control: controlRow.absoluteDelta,
      baseSigned: row.signedDelta,
      controlSigned: controlRow.signedDelta,
    };
  });
  const carrierBase = sum(carriers.map(row => row.base));
  const carrierControl = sum(carriers.map(row => row.control));
  return {
    count: base.count,
    carriers,
    carrierBase,
    carrierControl,
    restBase: base.maeDeltaSum - carrierBase,
    restControl: control.maeDeltaSum - carrierControl,
    carrierRatio: carrierControl / carrierBase,
    scaleRatio: control.scale / base.scale,
    maeRatio: control.onMae / base.onMae,
  };
}

const signed = (value, digits = 6) => `${value >= 0 ? "+" : ""}${value.toFixed(digits)}`;

function printAnalysis(result) {
  console.log(`matched rows: ${result.count}`);
  console.log(`level MAE on/off/delta: ${result.onMae.toFixed(6)} / ${result.offMae.toFixed(6)} / ${signed(result.maeDelta)} dB`);
  console.log(`row change sum: ${signed(result.maeDeltaSum, 4)} dB over ${result.count} rows`);
  console.log(`better/worse/same at 0.05 dB: ${result.better} / ${result.worse} / ${result.same}`);
  console.log(`row change median / mean magnitude: ${signed(result.medianDelta, 4)} / ${result.scale.toFixed(4)} dB`);
  console.log(`signed on-minus-off mean: ${signed(result.signedDelta)} dB`);
  console.log(`on/off level correlation: ${result.onOffCorrelation.toFixed(6)}`);
  console.log(`largest ${TOP_ROWS} row changes, with the levels they came from:`);
  console.log(`  patch      change in |level error|   level on    level off`);
  for (const row of result.largestWorsening) {
    console.log(`  ${row.patch}  ${signed(row.absoluteDelta, 4).padStart(21)} dB  ${signed(row.onLevel, 3).padStart(9)} dB  ${signed(row.offLevel, 3).padStart(9)} dB`);
  }
  console.log(`those ${TOP_ROWS} / all other rows: ${signed(result.largestWorseningSum, 4)} / ${signed(result.maeDeltaSum - result.largestWorseningSum, 4)} dB`);
  if (result.gainSlope !== undefined) {
    console.log(`signed delta vs gain: slope ${signed(result.gainSlope)} dB/step, r=${result.gainCorrelation.toFixed(6)}`);
    console.log(`signed delta vs effective weight: r=${result.weightCorrelation.toFixed(6)}`);
  }
}

function printContrast(base, control, result) {
  console.log(`matched rows: ${result.count}`);
  console.log(`base    level MAE on/off/delta: ${base.onMae.toFixed(6)} / ${base.offMae.toFixed(6)} / ${signed(base.maeDelta)} dB`);
  console.log(`control level MAE on/off/delta: ${control.onMae.toFixed(6)} / ${control.offMae.toFixed(6)} / ${signed(control.maeDelta)} dB`);
  console.log(`  patch       |change| base -> control    signed base -> control`);
  for (const row of result.carriers) {
    console.log(`  ${row.patch}  ${signed(row.base, 4)} -> ${signed(row.control, 4)} dB    ${signed(row.baseSigned, 4)} -> ${signed(row.controlSigned, 4)} dB`);
  }
  console.log(`those ${TOP_ROWS} rows: ${signed(result.carrierBase, 4)} -> ${signed(result.carrierControl, 4)} dB (x${result.carrierRatio.toFixed(4)})`);
  console.log(`all other rows: ${signed(result.restBase, 4)} -> ${signed(result.restControl, 4)} dB`);
  console.log(`mean row change magnitude: ${base.scale.toFixed(4)} -> ${control.scale.toFixed(4)} dB (x${result.scaleRatio.toFixed(4)})`);
  console.log(`sub-on level MAE: ${base.onMae.toFixed(4)} -> ${control.onMae.toFixed(4)} dB (x${result.maeRatio.toFixed(4)})`);
}

function usage() {
  console.error([
    "usage:",
    "  node tools/corpus-level.mjs prepare <corpus-root> <output-prefix>",
    "  node tools/corpus-level.mjs verify-index <index.csv>",
    "  node tools/corpus-level.mjs analyse <on.csv> <off.csv> <index.csv> [on-variant off-variant]",
    "  node tools/corpus-level.mjs contrast <on.csv> <off.csv> <control-on.csv> <control-off.csv> <index.csv> <control>",
    `controls: ${[...CONTROLS.keys()].join(", ")}`,
  ].join("\n"));
  process.exit(2);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, ...args] = process.argv.slice(2);
  if (command === "prepare" && args.length === 2) {
    const result = prepareCorpus(args[0], args[1]);
    console.log(`read ${result.files} corpus files; ${result.candidates} candidates; ${result.selected} unique patch semantics`);
    console.log(`wrote ${Object.values(result.dirs).length} directories under ${args[1]}- and ${result.indexPath}`);
    for (const directory of Object.values(result.dirs)) console.log(`  ${directory}`);
  } else if (command === "verify-index" && args.length === 1) {
    console.log(`index SHA-256 verified: ${verifyIndex(args[0])}`);
  } else if (command === "analyse" && (args.length === 3 || args.length === 5)) {
    printAnalysis(analysePair(args[0], args[1], args[2], args[3], args[4]));
  } else if (command === "contrast" && args.length === 6) {
    const base = analysePair(args[0], args[1], args[4]);
    const control = analysePair(args[2], args[3], args[4], `on-${args[5]}`, `off-${args[5]}`);
    printContrast(base, control, contrastPairs(base, control));
  } else usage();
}
