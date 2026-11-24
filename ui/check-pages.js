// Do the two shells still load the same interface?
//
//   node ui/check-pages.js
//
// `index.html` and `pad.html` are two shells over one panel: the same
// `params.js`, `layout.js` and `app.js` build the same controls on both, and the
// point of that is that improving the instrument improves the pad with it.
//
// The way that arrangement fails is quiet. Somebody adds a file to `index.html`
// -- a new section, a new dialog -- and does not add it to `pad.html`, and the
// pad keeps working while silently lacking the feature. Nothing throws, because
// a script that is not loaded is not an error; it is simply absent.
//
// So the two lists are compared, and the differences have to be ones this file
// knows the reason for.
const fs = require("fs");
const path = require("path");

// What each page is allowed to have that the other does not, and why.
const ONLY_INDEX = {
  "store.js":
    "remembers one sound; the pad has sixteen and does its own remembering",
};
const ONLY_PAD = {
  "pad-boot.js": "asks the host for sixteen instruments instead of one",
  "pad-model.js": "the reusable kit schema and rack routing rules",
  "pad.js": "the grid, and the tagging that sends each cell to its own engine",
};

function scripts(file) {
  const html = fs.readFileSync(path.join(__dirname, file), "utf8");
  const out = [];
  const re = /<script\b[^>]*\bsrc\s*=\s*"([^"]+)"/g;
  let m;
  while ((m = re.exec(html)) !== null) out.push(m[1]);
  return out;
}

const index = scripts("index.html");
const pad = scripts("pad.html");

// The preset strip and the restore banner inside it are markup, not scripts,
// and drift in the same quiet way: a button added to one shell leaves the
// other working without it. The strip is the `#bank` element, taken to its
// closing tag by counting, and compared with layout and comments removed.
function strip(file) {
  const html = fs.readFileSync(path.join(__dirname, file), "utf8");
  const start = html.indexOf('<div id="bank"');
  if (start < 0) return null;
  const tag = /<div\b|<\/div>/g;
  tag.lastIndex = start;
  let depth = 0;
  for (let m; (m = tag.exec(html));) {
    depth += m[0] === "</div>" ? -1 : 1;
    if (depth === 0) {
      return html.slice(start, m.index + m[0].length)
        .replace(/<!--[\s\S]*?-->/g, "").replace(/>\s+</g, "><").replace(/\s+/g, " ").trim();
    }
  }
  return null;
}

const missingFromPad = index.filter((s) => !pad.includes(s) && !ONLY_INDEX[s]);
const extraInPad = pad.filter((s) => !index.includes(s) && !ONLY_PAD[s]);

// Order matters as much as membership: `bridge.js` has to be there before
// `app.js` takes hold of it, and `pad.js` after, so shared files must stay in
// the same relative order on both pages.
const shared = index.filter((s) => pad.includes(s));
const padOrder = shared.slice().sort((a, b) => pad.indexOf(a) - pad.indexOf(b));
const reordered = shared.filter((s, i) => padOrder[i] !== s);

const problems = [];
if (missingFromPad.length) {
  problems.push("pad.html does not load: " + missingFromPad.join(", "));
}
if (extraInPad.length) {
  problems.push("pad.html loads what index.html does not: " + extraInPad.join(", "));
}
if (reordered.length) {
  problems.push("the shared files are in a different order on the two pages: " +
    reordered.join(", "));
}

if (strip("index.html") === null || strip("pad.html") === null) {
  problems.push("a shell has no #bank strip");
} else if (strip("index.html") !== strip("pad.html")) {
  problems.push("the preset strip (#bank) is not the same markup on the two pages");
}

if (problems.length) {
  console.error("the two shells have drifted apart:");
  problems.forEach((p) => console.error("  " + p));
  process.exit(1);
}

console.log("both shells load the same " + shared.length + " files in the same order");
Object.keys(ONLY_INDEX).forEach((s) =>
  console.log("  index only: " + s + " -- " + ONLY_INDEX[s]));
Object.keys(ONLY_PAD).forEach((s) =>
  console.log("  pad only:   " + s + " -- " + ONLY_PAD[s]));
