// The tools of the full control-protocol surface, written out by hand from the
// design and the protocol rather than read from the server: for each, a call
// that is valid, the QCP line that call must put on the socket, and what kind
// of change it is. A tool the server lists that is not here, or listed here and
// missing there, fails the tests that use this.

// Every tool and its hints, in the order tools/list returns them.
// r = read-only, d = destructive, i = idempotent.
const HINTS = {
  inspect_synth: "r i", apply_parameters: "d i",
  daemon_status: "r i", daemon_info: "r i", daemon_shutdown: "d i", parameter_list: "r i", parameter_get: "r i",
  parameter_set: "d i", parameter_set_many: "d i", state_snapshot: "r i", patch_load: "d", patch_apply: "d",
  patch_load_file: "d", patch_save: "d i", patch_current: "r i", patch_clear: "d i", bank_list: "r i",
  bank_write: "d i", bank_load_file: "d i", bank_keep: "d i", archive_open: "d i", archive_adopt: "i",
  archive_current: "r i", archive_banks: "r i", archive_bank: "i", archive_patches: "r i", archive_load: "d",
  archive_close: "d i", midi_list: "r i", midi_select: "i", midi_current: "r i", midi_send: "", volume: "i",
};

export const TOOL_NAMES = Object.keys(HINTS);

export function annotationsOf(name) {
  const hints = HINTS[name].split(" ");
  return {
    readOnlyHint: hints.includes("r"), destructiveHint: hints.includes("d"),
    idempotentHint: hints.includes("i"), openWorldHint: false,
  };
}

// name, a valid call, and the one line it must send.
export const CALLS = [
  ["daemon_status", {}, "daemon.status"],
  ["daemon_info", {}, "daemon.info"],
  ["daemon_shutdown", {}, "daemon.shutdown"],
  ["parameter_list", {}, "parameter.list"],
  ["parameter_get", { id: "filter.cutoff" }, "parameter.get filter.cutoff"],
  ["parameter_set", { id: "filter.cutoff", value: 90 }, "parameter.set filter.cutoff 90"],
  ["parameter_set_many",
    { expected_revision: 7, parameters: [{ id: "filter.cutoff", value: 90 }, { id: "filter.resonance", value: 5 }] },
    "parameter.set_many expected_revision=7 filter.cutoff 90 filter.resonance 5"],
  ["state_snapshot", {}, "state.snapshot"],
  ["patch_load", { slot: 12 }, "patch.load 12"],
  ["patch_apply", { parameters: [{ id: "filter.cutoff", value: 90 }] }, "patch.apply filter.cutoff 90"],
  ["patch_load_file", { path: "/tmp/my patches/lead.sy1" }, "patch.load_file /tmp/my patches/lead.sy1"],
  ["patch_save", { slot: 3, name: "Lead  Pad" }, "patch.save 3 Lead  Pad"],
  ["patch_current", {}, "patch.current"],
  ["patch_clear", {}, "patch.clear"],
  ["bank_list", {}, "bank.list"],
  ["bank_write", { path: "/tmp/bank.json" }, "bank.write /tmp/bank.json"],
  ["bank_load_file", { path: "/tmp/bank.json" }, "bank.load_file /tmp/bank.json"],
  ["bank_keep", {}, "bank.keep"],
  ["archive_open", { path: "/tmp/corpus.zip" }, "archive.open /tmp/corpus.zip"],
  ["archive_adopt", { path: "/tmp/corpus.zip" }, "archive.adopt /tmp/corpus.zip"],
  ["archive_current", {}, "archive.current"],
  ["archive_banks", { offset: 2, count: 3 }, "archive.banks 2 3"],
  ["archive_bank", { index: 1 }, "archive.bank 1"],
  ["archive_patches", { offset: 2, count: 3 }, "archive.patches 2 3"],
  ["archive_load", { index: 4, bank: 1 }, "archive.load 4 1"],
  ["archive_close", {}, "archive.close"],
  ["midi_list", {}, "midi.list"],
  ["midi_select", { input: "hw:2,0" }, "midi.select hw:2,0"],
  ["midi_current", {}, "midi.current"],
  ["midi_send", { status: 144, data1: 60, data2: 100 }, "midi 144 60 100"],
  ["volume", { milli: 250 }, "volume 250"],
];

// The commands control_handle dispatches on, from its source.
export function handlerCommands(source) {
  const start = source.indexOf("control_handle :: proc(");
  const body = source.slice(start, source.indexOf("\n}\n", start));
  return [...body.matchAll(/^\tcase "([a-z_.]+)":/gm)].map(match => match[1]);
}
