// Files to hand the panel, built here so that what a test opens is written down
// in the test and not in a fixture somebody has to go and read.
//
// This is a *writer*, and a deliberately small one: stored entries only, no
// checksums. The panel's reader (ui/sy1.js) is the code under test, and it is
// checked against the same zip layout the standalone tools and the Odin tests
// use (tests/zip/fixtures); a writer that shared its code with the reader could
// only ever agree with it.

const encoder = new TextEncoder();

// A `.sy1` patch whose cutoff (parameter 19) is `cutoff`, named `name`. Version
// 107 so the reader applies no pre-1.07 conversion to the number.
export function sy1(name, cutoff) {
  return encoder.encode(`Synth1 ${name}\nver=107\n19,${cutoff}\n`);
}

function u16(n) { return [n & 255, (n >> 8) & 255]; }
function u32(n) { return [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >>> 24) & 255]; }

// A zip of `{ name, bytes }` entries, in the order given, stored uncompressed.
export function zip(entries) {
  const parts = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const local = [...u32(0x04034b50), ...u16(20), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u32(0),
      ...u32(entry.bytes.length), ...u32(entry.bytes.length), ...u16(name.length), ...u16(0)];
    parts.push(Uint8Array.from(local), name, entry.bytes);
    central.push(Uint8Array.from([...u32(0x02014b50), ...u16(20), ...u16(20), ...u16(0), ...u16(0), ...u16(0),
      ...u16(0), ...u32(0), ...u32(entry.bytes.length), ...u32(entry.bytes.length), ...u16(name.length),
      ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u32(0), ...u32(offset)]), name);
    offset += local.length + name.length + entry.bytes.length;
  }
  const directory = central.reduce((n, p) => n + p.length, 0);
  const end = Uint8Array.from([...u32(0x06054b50), ...u16(0), ...u16(0), ...u16(entries.length),
    ...u16(entries.length), ...u32(directory), ...u32(offset), ...u16(0)]);
  const all = [...parts, ...central, end];
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of all) { out.set(p, at); at += p.length; }
  return out;
}

// `count` patches, named `${prefix}${i}`, with the cutoff `base + i`.
export function patches(count, {prefix = "P", base = 0, pad = 3} = {}) {
  return Array.from({length: count}, (_, i) => ({
    name: `${prefix}${String(i).padStart(pad, "0")}.sy1`,
    bytes: sy1(`${prefix}${String(i).padStart(pad, "0")}`, (base + i) % 128),
  }));
}

// What a folder picker hands over: files with a name, the path the browser
// reports, and bytes a FileReader will read back.
export function folder(dir, names) {
  return names.map(name => ({
    name, webkitRelativePath: `${dir}/${name}`, bytes: name.endsWith(".sy1") ? sy1(name.replace(/\.sy1$/i, ""), 7) : encoder.encode("x"),
  }));
}

// A FileReader that reads those, asynchronously as a real one does, and fails
// for any file marked `unreadable`.
export class FakeFileReader {
  readAsArrayBuffer(file) {
    queueMicrotask(() => {
      if (file.unreadable) { this.onerror(); return; }
      this.result = file.bytes.buffer.slice(file.bytes.byteOffset, file.bytes.byteOffset + file.bytes.byteLength);
      this.onload();
    });
  }
}
