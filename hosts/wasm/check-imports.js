// Check that worklet.js supplies every import the WebAssembly module asks for.
//
//   node hosts/wasm/check-imports.js [path/to/synth.wasm] [path/to/worklet.js]
//
// Worth having as its own step because the failure it catches is invisible until
// the page is open and then total: a missing import is a LinkError at
// instantiation, the engine never starts, and the panel still works perfectly.
// The module's import list is not fixed either -- it grows whenever the engine
// reaches for a libm function it did not use before, and `ln` is already in there
// while `log` is not.
//
// It lives in a file rather than inline in the workflow because the regular
// expression does not survive being quoted through a shell: the first version of
// this was written inline and reported every import as missing, including the
// seven that were plainly there.
const fs = require("fs");
const path = require("path");

const wasmPath = process.argv[2] || path.join(__dirname, "synth.wasm");
const workletPath = process.argv[3] || path.join(__dirname, "worklet.js");

if (!fs.existsSync(wasmPath)) {
  console.error("no module at " + wasmPath);
  console.error("build it: odin build hosts/wasm -target:js_wasm32 -out:hosts/wasm/synth.wasm");
  process.exit(1);
}

const bytes = fs.readFileSync(wasmPath);
const worklet = fs.readFileSync(workletPath, "utf8");

WebAssembly.compile(bytes).then((mod) => {
  const imports = WebAssembly.Module.imports(mod);
  const missing = imports.filter((i) => {
    // The worklet defines each one as an object property: `name: fn` or
    // `name: (args) => ...`. Looking for the key is enough and does not care how
    // the function is written.
    return !new RegExp("\\b" + i.name + "\\s*:").test(worklet);
  });

  if (missing.length) {
    console.error("worklet.js does not provide: " +
      missing.map((i) => i.module + "." + i.name).join(", "));
    process.exit(1);
  }
  console.log("all " + imports.length + " imports provided: " +
    imports.map((i) => i.name).join(", "));
}).catch((err) => {
  console.error("could not compile " + wasmPath + ": " + err.message);
  process.exit(1);
});
