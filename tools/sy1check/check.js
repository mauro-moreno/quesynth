// Does ui/sy1.js read a patch the same way src/patch/sy1.odin does?
//
//   node tools/sy1check/check.js <directory of .sy1> <directory of .json>
//
// The panel carries a second implementation of the .sy1 reader, for the reason
// given at the top of ui/sy1.js. Two implementations that must agree are a
// liability until something checks that they do, so this compares all
// ninety-nine values of every patch in a bank. The JSON side is produced by the
// Odin reader through tools/patchconv, so what is compared is the two readers
// and not two copies of the same one.
const fs = require("fs");
const path = require("path");

global.window = {};
new Function(fs.readFileSync("ui/params.js", "utf8"))();
new Function(fs.readFileSync("ui/sy1.js", "utf8"))();
const PARAMS = global.window.SYNTH1_PARAMS;
const sy1 = global.window.SynthSy1;
const defaults = PARAMS.map((p) => p.def);

const sy1Dir = process.argv[2];
const jsonDir = process.argv[3];

const files = fs.readdirSync(sy1Dir).filter((f) => /\.sy1$/i.test(f)).sort();
let checked = 0, mismatched = 0;

for (const file of files) {
  const jsonPath = path.join(jsonDir, file.replace(/\.sy1$/i, ".json"));
  if (!fs.existsSync(jsonPath)) continue;

  const mine = sy1.parse(new Uint8Array(fs.readFileSync(path.join(sy1Dir, file))), defaults);
  const theirs = JSON.parse(fs.readFileSync(jsonPath, "utf8")).parameters;

  let bad = [];
  for (let i = 0; i < PARAMS.length; i++) {
    const expected = theirs[PARAMS[i].name];
    if (mine.values[i] !== expected) {
      bad.push(`${PARAMS[i].name} (${i}): js ${mine.values[i]} vs odin ${expected}`);
    }
  }
  checked++;
  if (bad.length) {
    mismatched++;
    console.log(`${file}: ${bad.length} differ`);
    bad.slice(0, 6).forEach((b) => console.log(`    ${b}`));
  }
}

console.log(`\n${checked} patches compared, ${mismatched} with any difference`);
process.exit(mismatched === 0 ? 0 : 1);
