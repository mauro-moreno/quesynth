// Fixture tests for tools/corpus-level.mjs.
//
// What these check against is the .sy1 format and arithmetic done by hand, not
// this tool's own output: a preparation step that agreed with itself would let
// the gate's inputs drift from the patches they claim to be, which is the
// failure CONTRIBUTING.md warns about. So the selection is given patches that
// must and must not be picked, the rewrites are compared record by record with
// the original, and the statistics are given levels whose mean absolute error
// is obvious on sight.
import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {analysePair, contrastPairs, parsePatch, parseRecords, prepareCorpus, readCsv, setRecords, verifyIndex} from "./corpus-level.mjs";

const POST_VOICE = [[60, 64], [62, 64], [65, 0], [66, 0], [77, 0]];
const PROBE_HEADER = "patch,patch_sha256,level_db,param_mismatches,ref_silent,our_silent\n";
const fixtureHash = patch => createHash("sha256").update(patch).digest("hex");
const fixtureCsv = body => PROBE_HEADER + body.trim().split("\n").filter(Boolean).map(line => {
  const [patch, ...fields] = line.split(",");
  return [patch, fixtureHash(patch), ...fields].join(",");
}).join("\n") + "\n";
const fixtureIndex = rows => "name,gain95,mix5,identity_sha256,variant_sha256\n" + rows.map(([name, gain, mix]) => {
  const identity = fixtureHash(name);
  return `${name},${gain},${mix},${identity},on:${fixtureHash(`${name}.sy1`)};off:${fixtureHash(`${name}.sy1`)}`;
}).join("\n") + "\n";

function patch(values, name = "test") {
  return [`Synth1 ${name}`, ...Object.entries(values).map(([i, v]) => `${i},${v}`), ""].join("\n");
}

function temporary(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "corpus-level-"));
  try { run(directory); } finally { fs.rmSync(directory, {recursive: true, force: true}); }
}

test("prepare selects, deduplicates, and changes only declared records", () => {
  temporary(temp => {
    const root = path.join(temp, "source");
    fs.mkdirSync(path.join(root, "bank"), {recursive: true});
    const selected = patch({5: 64, 6: 0, 7: 0, 45: 0, 60: 12, 62: 90, 65: 1, 66: 1, 73: 0, 77: 1, 95: 64, 96: 2, 97: 1});
    fs.writeFileSync(path.join(root, "bank", "a.sy1"), selected);
    fs.writeFileSync(path.join(root, "bank", "duplicate.sy1"), selected);
    fs.writeFileSync(path.join(root, "bank", "low.sy1"), patch({6: 0, 7: 0, 45: 0, 73: 0, 95: 31}));
    fs.writeFileSync(path.join(root, "bank", "unison.sy1"), patch({6: 0, 7: 0, 45: 0, 73: 1, 95: 127}));
    fs.writeFileSync(path.join(root, "bank", "arp.sy1"), patch({6: 0, 7: 0, 45: 1, 73: 0, 95: 127}));

    const prefix = path.join(temp, "out");
    const result = prepareCorpus(root, prefix);
    assert.deepEqual([result.files, result.candidates, result.selected], [5, 2, 1]);

    const on = fs.readFileSync(`${prefix}-on/s000.sy1`, "latin1");
    assert.equal(on, selected, "the selected input must be the source, unedited");

    const offRecords = parseRecords(fs.readFileSync(`${prefix}-off/s000.sy1`, "latin1"));
    assert.equal(offRecords.get(95), 0);
    offRecords.set(95, 64);
    assert.deepEqual(offRecords, parseRecords(on), "the sub-off control may differ at 95 and nowhere else");

    for (const [control, changes] of [["post-off", POST_VOICE], ["delay-off", [[65, 0]]], ["eq-flat", [[60, 64], [62, 64]]]]) {
      const changed = parseRecords(fs.readFileSync(`${prefix}-on-${control}/s000.sy1`, "latin1"));
      const declared = new Map(changes);
      for (const [index, value] of declared) assert.equal(changed.get(index), value, `${control} must set ${index}`);
      for (const [index, value] of parseRecords(on)) {
        if (!declared.has(index)) assert.equal(changed.get(index), value, `${control} must leave ${index} alone`);
      }
      const both = parseRecords(fs.readFileSync(`${prefix}-off-${control}/s000.sy1`, "latin1"));
      assert.equal(both.get(95), 0, `${control} must keep the sub-off control off`);
    }

    const index = readCsv(`${prefix}-index.csv`);
    assert.deepEqual(index.map(row => [row.name, row.gain95, row.mix5, row.source]), [["s000", "64", "64", "bank/a.sy1"]]);
    const indexHash = createHash("sha256").update(fs.readFileSync(result.indexPath)).digest("hex");
    assert.equal(index[0].identity_sha256, index[0].semantic_sha256);
    assert.match(index[0].variant_sha256, /on:[0-9a-f]{64};off:[0-9a-f]{64}/);
    assert.equal(verifyIndex(result.indexPath, indexHash), indexHash);
    assert.throws(() => verifyIndex(result.indexPath, "0".repeat(64)), /index SHA-256/);
  });
});

test("prepare keeps version-sensitive patch semantics distinct", () => {
  temporary(temp => {
    const root = path.join(temp, "source");
    fs.mkdirSync(root);
    const records = "6,0\n7,0\n45,0\n73,0\n95,64\n";
    fs.writeFileSync(path.join(root, "old.sy1"), `old\nver=105\n${records}`);
    fs.writeFileSync(path.join(root, "new.sy1"), `new\nver=112\n${records}`);
    const result = prepareCorpus(root, path.join(temp, "out"), new Map());
    assert.deepEqual([result.candidates, result.selected], [2, 2]);
    assert.deepEqual(readCsv(result.indexPath).map(row => row.version), ["112", "105"]);
    assert.equal(parsePatch(`name\nver=105\n${records}`).version, 105);
    assert.throws(() => parsePatch("name\n99,0\n"), /out of range/);
    assert.throws(() => parsePatch("name\nnot a record\n"), /malformed patch line/);
  });
});

test("rewrites keep every byte the change does not name", () => {
  // A patch name outside ASCII and Windows line endings: both are in the real
  // corpus, and a rewrite that normalised either would hand the reference a
  // different file from the one the index names.
  const source = "Caf\xe9 lead\r\n6,0\r\n95,+64\r\n95,96\r\n77,1\r\n";
  assert.equal(parseRecords(source).get(95), 96, "the later duplicate record is the effective one");

  const off = setRecords(source, new Map([[95, 0]]));
  assert.equal(off, "Caf\xe9 lead\r\n6,0\r\n95,0\r\n95,0\r\n77,1\r\n");
  assert.equal(parseRecords(off).get(95), 0, "both duplicates must move or the effective value does not");

  const appended = setRecords("6,0\n", new Map([[77, 0]]));
  assert.equal(appended, "6,0\n77,0\n", "a missing record is appended");
  assert.equal(setRecords("6,0\n  \n", new Map([[77, 0]])), "6,0\n  \n77,0\n",
    "appending a record must preserve unrelated trailing bytes");
});

test("CSV reader keeps quoted newlines in one record", () => {
  temporary(temp => {
    const file = path.join(temp, "quoted.csv");
    fs.writeFileSync(file, 'name,source\ns000,"bank\nname.sy1"\n');
    assert.deepEqual(readCsv(file), [{name: "s000", source: "bank\nname.sy1"}]);
  });
});

// Levels chosen so the answer is arithmetic rather than a re-run of the tool:
// |-3| - |-1| = +2 and |2| - |3| = -1, so the mean absolute error moves
// +0.5 dB while the signed mean moves -1.5 dB. The gate metric is the first.
test("paired analysis reports the absolute movement, not the signed one", () => {
  temporary(temp => {
    fs.writeFileSync(path.join(temp, "on.csv"), fixtureCsv("s000.sy1,-3,0,false,false\ns001.sy1,2,0,false,false"));
    fs.writeFileSync(path.join(temp, "off.csv"), fixtureCsv("s000.sy1,-1,0,false,false\ns001.sy1,3,0,false,false"));
    fs.writeFileSync(path.join(temp, "index.csv"), fixtureIndex([["s000", 32, 0], ["s001", 64, 127]]));
    const result = analysePair(path.join(temp, "on.csv"), path.join(temp, "off.csv"), path.join(temp, "index.csv"));
    assert.equal(result.count, 2);
    assert.equal(result.onMae, 2.5);
    assert.equal(result.offMae, 2);
    assert.equal(result.maeDelta, 0.5);
    assert.equal(result.maeDeltaSum, 1);
    assert.equal(result.scale, 1.5);
    assert.deepEqual([result.better, result.worse, result.same], [1, 1, 0]);
    assert.equal(result.signedDelta, -1.5);
    assert.equal(result.gainSlope, 0.03125);
    assert.equal(result.gainCorrelation, 1);
    assert.equal(result.weightCorrelation, -1);
    assert.equal(result.onOffCorrelation, 1);
    assert.deepEqual(result.largestWorsening.map(row => row.patch), ["s000.sy1", "s001.sy1"]);

    fs.appendFileSync(path.join(temp, "on.csv"), `s000.sy1,${fixtureHash("s000.sy1")},9,0,false,false\n`);
    assert.throws(() => analysePair(path.join(temp, "on.csv"), path.join(temp, "off.csv"), path.join(temp, "index.csv")), /duplicate patch/);
  });
});

test("a silent row on either side leaves the pair", () => {
  temporary(temp => {
    fs.writeFileSync(path.join(temp, "on.csv"), fixtureCsv("s000.sy1,-3,0,false,false\ns001.sy1,2,0,true,false"));
    fs.writeFileSync(path.join(temp, "off.csv"), fixtureCsv("s000.sy1,-1,0,false,false\ns001.sy1,3,0,false,false"));
    fs.writeFileSync(path.join(temp, "index.csv"), fixtureIndex([["s000", 32, 0], ["s001", 64, 127]]));
    const result = analysePair(path.join(temp, "on.csv"), path.join(temp, "off.csv"), path.join(temp, "index.csv"));
    assert.equal(result.count, 1);
    assert.equal(result.maeDelta, 2);
  });
});

test("stable hashes preserve the gain fit across row reorder and reject stale sNNN labels", () => {
  temporary(temp => {
    const at = name => path.join(temp, name);
    const body = rows => rows.map(([name, level]) => `${name}.sy1,${level},0,false,false`).join("\n");
    fs.writeFileSync(at("index.csv"), fixtureIndex([["s000", 32, 0], ["s001", 64, 127]]));
    fs.writeFileSync(at("on.csv"), fixtureCsv(body([["s001", 2], ["s000", -3]])));
    fs.writeFileSync(at("off.csv"), fixtureCsv(body([["s001", 3], ["s000", -1]])));
    const result = analysePair(at("on.csv"), at("off.csv"), at("index.csv"));
    assert.equal(result.gainSlope, 0.03125, "gain fit must follow hash-bound identities, not CSV order");
    fs.writeFileSync(at("on.csv"), PROBE_HEADER + `s000.sy1,${fixtureHash("s001.sy1")},2,0,false,false\ns001.sy1,${fixtureHash("s000.sy1")},-3,0,false,false\n`);
    assert.throws(() => analysePair(at("on.csv"), at("off.csv"), at("index.csv")), /stale or reordered cohort/);
  });
});

test("paired analysis rejects incomplete or mismatched reference rows", () => {
  temporary(temp => {
    const at = name => path.join(temp, name);
    fs.writeFileSync(at("on.csv"), fixtureCsv("s000.sy1,-3,0,false,false\ns001.sy1,2,0,false,false"));
    fs.writeFileSync(at("off.csv"), fixtureCsv("s000.sy1,-1,0,false,false"));
    fs.writeFileSync(at("index.csv"), fixtureIndex([["s000", 32, 0], ["s001", 64, 127]]));
    assert.throws(() => analysePair(at("on.csv"), at("off.csv"), at("index.csv")), /full expected index/);
    fs.writeFileSync(at("off.csv"), fixtureCsv("s000.sy1,-1,,false,false\ns001.sy1,3,0,false,false"));
    assert.throws(() => analysePair(at("on.csv"), at("off.csv"), at("index.csv")), /empty param_mismatches/);
    fs.writeFileSync(at("off.csv"), fixtureCsv("s000.sy1,-1,1,false,false\ns001.sy1,3,0,false,false"));
    assert.throws(() => analysePair(at("on.csv"), at("off.csv"), at("index.csv")), /parameter load mismatch/);
  });
});

test("contrast pairs the same rows and separates carriers from scale", () => {
  temporary(temp => {
    const at = name => path.join(temp, name);
    const write = (name, body) => fs.writeFileSync(at(name), fixtureCsv(body));
    const index = fixtureIndex([["s000", 32, 0], ["s001", 64, 0], ["s002", 96, 0]]);
    fs.writeFileSync(at("index.csv"), index);
    write("on.csv", "s000.sy1,-12,0,false,false\ns001.sy1,1,0,false,false\ns002.sy1,1,0,false,false");
    write("off.csv", "s000.sy1,-4,0,false,false\ns001.sy1,2,0,false,false\ns002.sy1,2,0,false,false");
    write("c-on.csv", "s000.sy1,-4,0,false,false\ns001.sy1,1.5,0,false,false\ns002.sy1,1.5,0,false,false");
    write("c-off.csv", "s000.sy1,-4,0,false,false\ns001.sy1,2,0,false,false\ns002.sy1,2,0,false,false");
    const base = analysePair(at("on.csv"), at("off.csv"), at("index.csv"));
    const control = analysePair(at("c-on.csv"), at("c-off.csv"), at("index.csv"));
    const result = contrastPairs(base, control);
    assert.equal(result.count, 3);
    assert.equal(base.maeDeltaSum, 6);
    assert.equal(control.maeDeltaSum, -1);
    assert.deepEqual(result.carriers.map(row => [row.patch, row.base, row.control])[0], ["s000.sy1", 8, 0]);
    assert.equal(result.carrierBase, 6);
    assert.equal(result.carrierControl, -1);
    assert.equal(result.scaleRatio, control.scale / base.scale);
    write("short.csv", "s000.sy1,-4,0,false,false");
    assert.throws(() => contrastPairs(base, analysePair(at("short.csv"), at("short.csv"), at("index.csv"))), /full expected index/);
  });
});
