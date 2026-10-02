"use strict";

const integer = (description, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) =>
  ({ type: "integer", minimum, maximum, description });
const token = {
  type: "string", minLength: 1, pattern: "^[^\\s\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]+$",
  description: "One daemon identifier, exactly as listed.",
};
const path = {
  type: "string", pattern: "^[^\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]*$",
  description: "Local path read by the daemon, relative to its cwd; no shell or tilde expansion.",
};
const page = {
  offset: integer("First index; default 0."),
  count: integer("Requested count; default 64, capped at 256 by the daemon. Zero lists none."),
};
const outputSchema = {
  type: "object", required: ["fields", "lines"], additionalProperties: false,
  properties: {
    fields: { type: "string", description: "Daemon response header after the ok envelope." },
    lines: { type: "array", items: { type: "string" }, description: "Ordered daemon record lines, unchanged." },
  },
};

// This is an allowlist, not a generic command gateway. The daemon owns parameter
// ranges, patch identity, file parsing and every change to the running engine.
const definitions = [
  ["daemon_status", "daemon.status", "Read daemon state, protocol and revision.", true],
  ["daemon_info", "daemon.info", "Read daemon state, audio metrics, queue drops and master volume.", true],
  ["parameter_list", "parameter.list", "List stable parameter IDs and their stored integer ranges, defaults and labels.", true],
  ["parameter_get", "parameter.get", "Read a parameter's stored value and revision.", true, { id: token }, ["id"]],
  ["parameter_set", "parameter.set", "Edit a parameter. May change audible output; query parameter_list for its range. Acknowledgement precedes audio-thread application.", false,
    { id: token, value: integer("Stored integer, not Hz/dB/display units.", Number.MIN_SAFE_INTEGER) }, ["id", "value"]],
  ["patch_current", "patch.current", "Read sounding patch provenance and bank/archive generations; browsing is separate.", true],
  ["patch_load", "patch.load", "Load a filled ordinary-bank slot. Changes sound, preserves held notes; does not close the archive.", false,
    { slot: integer("Zero-based ordinary-bank slot.", 0, 127) }, ["slot"]],
  ["patch_load_file", "patch.load_file", "Read a local .sy1 or JSON patch and load its sound. Does not write files.", false, { path }, ["path"]],
  ["bank_list", "bank.list", "List all 128 ordinary-bank slots, including empty ones. ZIP banks use archive_banks.", true],
  ["bank_load_file", "bank.load_file", "Read a local JSON bank into the ordinary browser. Does not change sound or persist the bank; clears its current slot association.", false, { path }, ["path"]],
  ["archive_current", "archive.current", "Read the shared archive path, open bank and generation.", true],
  ["archive_open", "archive.open", "Open a ZIP of bank ZIPs and remember its path for daemon restarts. Omit path or use an empty string to reopen the remembered path. Does not load sound.", false, { path }],
  ["archive_banks", "archive.banks", "Page through ZIP bank names in daemon order. Read archive_rev to detect a peer changing the archive.", true, page],
  ["archive_bank", "archive.bank", "Browse one ZIP bank for all clients without changing the sounding patch.", false,
    { index: integer("Zero-based archive bank index.") }, ["index"]],
  ["archive_patches", "archive.patches", "Page through the open ZIP bank's patch names. Replies identify bank and archive_rev.", true, page],
  ["archive_load", "archive.load", "Load a ZIP patch. Supply bank to select from the listed bank even if a peer browsed elsewhere; omitted bank uses the currently open one.", false,
    { index: integer("Zero-based patch index."), bank: integer("Optional zero-based archive bank index.") }, ["index"]],
  ["archive_close", "archive.close", "Close the shared archive and forget its saved path. Sound remains, but archive provenance indices are cleared.", false],
  ["midi_list", "midi.list", "Enumerate native MIDI inputs and the daemon's selection. Device IDs are not names.", true],
  ["midi_current", "midi.current", "Read selected MIDI input and midi_rev.", true],
  ["midi_select", "midi.select", "Select all, none, or an ID from midi_list for every client. Not persisted. Releases no held notes: one held on an input it closes sounds until a note-off arrives some other way, such as midi_send. Does not disable injected MIDI.", false, { id: token }, ["id"]],
  ["midi_send", "midi", "Inject one MIDI message into the daemon queue. Can sound notes/change patches; always pair note-on with note-off. Supply data2=0 for Program Change.", false,
    { status: integer("Status byte, including zero-based channel nibble.", 0, 255),
      data1: integer("First data byte.", 0, 127), data2: integer("Second data byte.", 0, 127) },
    ["status", "data1", "data2"]],
];

const tools = definitions.map(([name, , description, readOnly, properties = {}, required = []]) => ({
  name, description,
  inputSchema: { type: "object", properties, required, additionalProperties: false },
  outputSchema,
  annotations: { readOnlyHint: readOnly, destructiveHint: !readOnly, openWorldHint: false },
}));

function commandFor(name, args) {
  const definition = definitions.find(row => row[0] === name);
  const [, verb, , , properties = {}] = definition;
  const values = Object.keys(properties).map(key => args[key]);
  // Positional paging needs offset 0 when only count is given. Other optional
  // operands are trailing, so absence must stay absence, not an empty token.
  if (properties === page && args.count !== undefined && args.offset === undefined) values[0] = 0;
  while (values.length && values.at(-1) === undefined) values.pop();
  return [verb, ...values].join(" ");
}

function validateArguments(tool, args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return "arguments must be an object";
  const { properties, required } = tool.inputSchema;
  for (const key of required) {
    if (!Object.hasOwn(args, key)) return `missing argument: ${key}`;
  }
  for (const [key, value] of Object.entries(args)) {
    if (!Object.hasOwn(properties, key)) return `unknown argument: ${key}`;
    const schema = properties[key];
    if (schema.type === "integer") {
      if (!Number.isSafeInteger(value) || value < schema.minimum || value > schema.maximum) {
        return `${key} must be an integer in ${schema.minimum}..${schema.maximum}`;
      }
    } else if (typeof value !== "string" || !value.isWellFormed()
      || value.length < (schema.minLength || 0)
      || new RegExp(schema.pattern, "u").exec(value)?.[0] !== value) {
      return `${key} must be valid text matching ${schema.pattern}`;
    }
  }
  return null;
}

module.exports = { tools, commandFor, validateArguments };
