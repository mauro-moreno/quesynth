#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode"

// The tools. One table says, for every tool, which QCP command it is, what
// arguments it takes, and what kind of change it makes. tools/list, the checks
// on a call and the line sent to the daemon are all made from that table, so
// the schema a client reads cannot drift from what the server accepts or from
// what reaches the socket.
//
// This is an allowlist of typed tools, not a way to send a command: no tool
// takes a command name, a line or a free-form list of operands, so a client
// can say only what a row below lets it say.
//
// Nothing here knows what a value means. Whether a parameter exists, a slot is
// filled, an archive is open or a device is plugged in is the daemon's to say.
// A value is refused here only when sending it would make QCP read something
// else than the caller wrote: a new line ends a request, a space splits an
// operand, and the daemon trims the whitespace around a path. The limits below
// are the daemon's own numbers, because a count or a number out of range is
// just as unreadable to it, and a test holds them to the daemon's.

// The most id/value pairs the daemon takes in one transaction.
MAX_PAIRS :: 128
// Slots in the daemon's ordinary bank.
SLOT_COUNT :: 128
// Master volume at full level, in thousandths.
VOLUME_MAX :: 1000

Kind :: enum {
	// An integer in [min, max]. JSON numbers such as 30.0 count as 30.
	Integer,
	// One QCP token: a non-empty string with no whitespace or control
	// character, so the daemon cannot split it in two.
	Token,
	// Text the daemon reads to the end of the line. It may hold spaces, but
	// neither a control character, a line separator, nor whitespace at either
	// end, which the daemon would trim. Empty counts as omitted when optional.
	Text,
	// Id/value pairs: 1 to MAX_PAIRS objects with exactly an `id` token and an
	// integer `value`.
	Pairs,
}

Arg :: struct {
	name:        string,
	kind:        Kind,
	required:    bool,
	// Integer bounds, inclusive.
	min, max:    int,
	// Written before an integer on the wire, as in expected_revision=<n>.
	prefix:      string,
	// What stands in for this operand when it is left out but a later one is
	// given, because the daemon reads operands by position.
	pad:         string,
	// Pairs only: an id that begins like this is refused, because the daemon
	// would read it as something else.
	reserved:    string,
	description: string,
}

Handler :: enum {
	// One QCP command built from the arguments.
	Command,
	// The two tools that predate the table. They make several requests or
	// check an acknowledgement, so server.odin runs them; the table only
	// describes them.
	Inspect,
	Apply,
}

Tool :: struct {
	name:          string,
	command:       string,
	description:   string,
	args:          []Arg,
	handler:       Handler,
	// The three hints MCP clients are told. A read-only tool changes nothing;
	// destructive and idempotent are only meaningful for the rest.
	read_only:     bool,
	destructive:   bool,
	idempotent:    bool,
	// Set only for the two older tools, whose schemas are written out exactly
	// as they have always been sent.
	input_schema:  string,
	output_schema: string,
}

// The classes of character that decide what a token or a text may hold, as
// patterns a client can check with. They are exactly what token_problem and
// text_problem accept, and a test over every Unicode scalar value holds them to
// it. Whitespace is spelled out because \s differs between JavaScript and
// Odin, and Odin itself has two sets: unicode.is_space, which splits an
// operand and also counts U+200B, U+200E, U+200F and U+FEFF, and the narrower
// one strings.trim_space cuts from the ends of a path.
//
// A token excludes every control character and all of the first set.
@(private)
TOKEN_CLASS :: `[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200b\u200e\u200f\u2028\u2029\u202f\u205f\u3000\ufeff]`
// The first and last character of a text exclude the controls and what is
// trimmed; between them anything but a control character or a line separator.
@(private)
EDGE_CLASS :: `[^\u0000-\u0020\u007f-\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]`
@(private)
INNER_CLASS :: `[^\u0000-\u001f\u007f-\u009f\u2028\u2029]`

TOKEN_PATTERN :: `^` + TOKEN_CLASS + `+$`
TEXT_PATTERN :: `^` + EDGE_CLASS + `(?:` + INNER_CLASS + `*` + EDGE_CLASS + `)?$`
OPTIONAL_TEXT_PATTERN :: `^(?:` + EDGE_CLASS + `(?:` + INNER_CLASS + `*` + EDGE_CLASS + `)?)?$`

@(private)
ID :: Arg {
	name        = "id",
	kind        = .Token,
	required    = true,
	description = "Parameter id exactly as parameter_list gives it, for example filter.cutoff.",
}

@(private)
VALUE :: Arg {
	name        = "value",
	kind        = .Integer,
	required    = true,
	min         = -MAX_SAFE_INTEGER,
	max         = MAX_SAFE_INTEGER,
	description = "Stored integer, not Hz, dB or display units. The range for each id is in parameter_list.",
}

@(private)
PAIRS_TEXT :: "Id and stored value pairs, 1 to 128, applied in order; a repeated id is set again and the last value wins. The daemon checks every id and range first and refuses the whole batch if any is wrong."

@(private)
PAIRS :: Arg {
	name        = "parameters",
	kind        = .Pairs,
	required    = true,
	description = PAIRS_TEXT,
}

// parameter_set_many reads a first operand that starts expected_revision= as
// its guard, so no id may.
@(private)
GUARDED_PAIRS :: Arg {
	name        = "parameters",
	kind        = .Pairs,
	required    = true,
	reserved    = "expected_revision=",
	description = PAIRS_TEXT,
}

@(private)
EXPECTED_REVISION :: Arg {
	name        = "expected_revision",
	kind        = .Integer,
	min         = 0,
	max         = MAX_SAFE_INTEGER,
	prefix      = "expected_revision=",
	description = "The revision you last saw, from state_snapshot, daemon_status or the last edit. Strongly advised: it makes a stale batch fail instead of overwriting.",
}

@(private)
SLOT :: Arg {
	name        = "slot",
	kind        = .Integer,
	required    = true,
	min         = 0,
	max         = SLOT_COUNT - 1,
	description = "Zero-based slot of the ordinary bank.",
}

@(private)
FILE_PATH :: Arg {
	name        = "path",
	kind        = .Text,
	required    = true,
	description = "File path as the daemon reads it: relative to the daemon's working directory, with no ~ or shell expansion. No control characters, and no whitespace at either end.",
}

@(private)
OFFSET :: Arg {
	name        = "offset",
	kind        = .Integer,
	min         = 0,
	max         = MAX_SAFE_INTEGER,
	pad         = "0",
	description = "Index of the first entry to list. Default 0.",
}

@(private)
COUNT :: Arg {
	name        = "count",
	kind        = .Integer,
	min         = 0,
	max         = MAX_SAFE_INTEGER,
	description = "How many entries to list. Default 64. The daemon lists at most 256 and clamps a larger count; zero lists none.",
}

@(private)
REPLY_SCHEMA :: `{"type":"object","required":["fields","lines"],"additionalProperties":false,"properties":{"fields":{"type":"string","description":"The text after ok on the first line of the daemon's reply."},"lines":{"type":"array","items":{"type":"string"},"description":"The record lines that follow it, unchanged and in the daemon's order."}}}`

@(private)
RECORDS :: `{"type":"object","required":["fields","lines"],"additionalProperties":false,"properties":{"fields":{"type":"string"},"lines":{"type":"array","items":{"type":"string"}}}}`

// In the order tools/list returns them. Hints: read_only; or destructive (can
// overwrite or discard what the daemon does not keep elsewhere, or the daemon
// itself) and idempotent (the same call again leaves the same state and does
// nothing further audible), the counters revision, bank_rev, archive_rev and
// midi_rev aside.
TOOLS := [?]Tool {
	{
		name = "inspect_synth",
		description = "Read current parameter values, the daemon's registry and sounding patch identity. No audio is started.",
		handler = .Inspect,
		read_only = true,
		idempotent = true,
		input_schema = `{"type":"object","properties":{}}`,
		output_schema = `{"type":"object","required":["revision","state","patch","parameters"],"additionalProperties":false,"properties":{"revision":{"type":"integer"},"state":` + RECORDS + `,"patch":` + RECORDS + `,"parameters":` + RECORDS + `}}`,
	},
	{
		name = "apply_parameters",
		description = "Atomically edit stored integer parameters if the daemon revision still matches. Duplicate IDs apply in order, last wins. Inspect again after an uncertain transport failure; mutations are never retried.",
		handler = .Apply,
		destructive = true,
		idempotent = true,
		input_schema = `{"type":"object","required":["expected_revision","parameters"],"properties":{"expected_revision":{"type":"integer","minimum":0},"parameters":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"integer"}}}}}}`,
		output_schema = `{"type":"object","required":["count","revision"],"additionalProperties":false,"properties":{"count":{"type":"integer"},"revision":{"type":"integer"}}}`,
	},
	{
		name = "daemon_status",
		command = "daemon.status",
		description = "Read the daemon's state, its protocol version and the current parameter revision.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "daemon_info",
		command = "daemon.info",
		description = "Read the daemon's state, protocol and revision, how many control and MIDI messages it has dropped, and, as far as it can report them, sample rate, buffer size, voices sounding, uptime, master volume and audio backend.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "daemon_shutdown",
		command = "daemon.shutdown",
		description = "Ask the running daemon to shut down, as quesynth --stop does. It replies, stops the sound and exits; every other tool then returns daemon_unavailable until a daemon is started again. Nothing is saved.",
		destructive = true,
		idempotent = true,
	},
	{
		name = "parameter_list",
		command = "parameter.list",
		description = "List every parameter the daemon has: id, group, index, stored minimum and maximum, default and label.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "parameter_get",
		command = "parameter.get",
		description = "Read one parameter's stored value and the daemon's revision.",
		args = {ID},
		read_only = true,
		idempotent = true,
	},
	{
		name = "parameter_set",
		command = "parameter.set",
		description = "Set one parameter to a stored integer. Changes the sound. The daemon replies when the edit is queued, before the audio thread has applied it, with the revision it had then. To avoid overwriting someone else's edit use parameter_set_many with expected_revision.",
		args = {ID, VALUE},
		destructive = true,
		idempotent = true,
	},
	{
		name = "parameter_set_many",
		command = "parameter.set_many",
		description = "Set several parameters as one batch that is applied together, all or nothing. Changes the sound. With expected_revision the daemon applies the batch only if its revision is still that number and replies after the audio thread has decided, with the new revision; otherwise it returns revision_conflict and changes nothing. Without it the batch is queued and the reply carries the revision at that moment.",
		args = {EXPECTED_REVISION, GUARDED_PAIRS},
		destructive = true,
		idempotent = true,
	},
	{
		name = "state_snapshot",
		command = "state.snapshot",
		description = "Read the revision and the stored value of every parameter from one consistent snapshot, with the sample rate and buffer size.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "patch_load",
		command = "patch.load",
		description = "Load a filled slot of the ordinary bank as the sound. Replaces the whole patch at once and clears what the last one left ringing; held notes keep sounding. Names the slot as the playing patch. The reply comes when the load is queued.",
		args = {SLOT},
		destructive = true,
	},
	{
		name = "patch_apply",
		command = "patch.apply",
		description = "Replace the sound with the given parameters as one patch, the way a front-end loads a patch it holds. Parameters not named keep their values. Clears what the last patch left ringing. The playing patch's name is left as it was; use patch_clear to forget it. The reply comes when the load is queued.",
		args = {PAIRS},
		destructive = true,
	},
	{
		name = "patch_load_file",
		command = "patch.load_file",
		description = "Read a .sy1 or JSON patch file and load it as the sound. The daemon reads the file, not this server. Replaces the whole patch and clears what the last one left ringing. The playing patch is named after the name in the file, or the file's name. Writes no file.",
		args = {FILE_PATH},
		destructive = true,
	},
	{
		name = "patch_save",
		command = "patch.save",
		description = "Store the sound as it is now in a slot of the ordinary bank, overwriting that slot, and name the slot as the playing patch. It lives in the daemon's memory until bank_keep or bank_write is called.",
		args = {
			SLOT,
			{
				name = "name",
				kind = .Text,
				description = "Name to store. The daemon keeps at most 48 bytes. Omit it, or send an empty string, to keep the slot's current name (Init for an empty slot). No control characters, and no whitespace at either end.",
			},
		},
		destructive = true,
		idempotent = true,
	},
	{
		name = "patch_current",
		command = "patch.current",
		description = "Read which patch is sounding: its slot, source, bank and patch names and archive position, with the revision, bank_rev and archive_rev counters.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "patch_clear",
		command = "patch.clear",
		description = "Forget which patch the sound came from. The parameter values, the banks and the counters do not change.",
		destructive = true,
		idempotent = true,
	},
	{
		name = "bank_list",
		command = "bank.list",
		description = "List the ordinary bank: its label, how many slots are filled, and all 128 slots with their names, empty ones included. ZIP archive banks are listed by archive_banks.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "bank_write",
		command = "bank.write",
		description = "Write the whole ordinary bank to a JSON file. The daemon writes the file, not this server, and replaces it if it exists. The bank and the sound do not change.",
		args = {FILE_PATH},
		destructive = true,
		idempotent = true,
	},
	{
		name = "bank_load_file",
		command = "bank.load_file",
		description = "Replace the ordinary bank with a JSON bank file the daemon reads. The sound does not change and the bank is not saved. The playing patch keeps its names but no longer names a slot.",
		args = {FILE_PATH},
		destructive = true,
		idempotent = true,
	},
	{
		name = "bank_keep",
		command = "bank.keep",
		description = "Write the ordinary bank to bank.json in the daemon's own configuration directory, which the daemon loads at its next start. It takes no path, and replaces the previous file in one step.",
		destructive = true,
		idempotent = true,
	},
	{
		name = "archive_open",
		command = "archive.open",
		description = "Open a ZIP archive of bank ZIPs for every client and remember its path for the next daemon start. Loads no sound. Omit path, or send an empty string, to open the remembered archive again. The daemon reads the file, not this server.",
		args = {
			{
				name = "path",
				kind = .Text,
				description = "Archive path as the daemon reads it: relative to the daemon's working directory, with no ~ or shell expansion. No control characters, and no whitespace at either end.",
			},
		},
		destructive = true,
		idempotent = true,
	},
	{
		name = "archive_adopt",
		command = "archive.adopt",
		description = "Offer the daemon an archive path to open, which it takes only if it has no archive open and remembers none; the reply says adopted=1 or adopted=0. Otherwise nothing changes.",
		args = {FILE_PATH},
		idempotent = true,
	},
	{
		name = "archive_current",
		command = "archive.current",
		description = "Read the shared archive: whether one is open, how many banks it has, the open bank and its patch count, archive_rev, the archive path and the open bank's name.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "archive_banks",
		command = "archive.banks",
		description = "List a page of the open archive's banks, in the order the ZIP stores them. Read archive_rev to notice another client changing the archive.",
		args = {OFFSET, COUNT},
		read_only = true,
		idempotent = true,
	},
	{
		name = "archive_bank",
		command = "archive.bank",
		description = "Open one bank of the open archive for browsing, for every client. The sound and the playing patch do not change.",
		args = {
			{
				name = "index",
				kind = .Integer,
				required = true,
				min = 0,
				max = MAX_SAFE_INTEGER,
				description = "Zero-based bank index, as archive_banks lists it.",
			},
		},
		idempotent = true,
	},
	{
		name = "archive_patches",
		command = "archive.patches",
		description = "List a page of the patch names in the open archive bank. The reply names the bank and archive_rev, so a page can be told from another bank's.",
		args = {OFFSET, COUNT},
		read_only = true,
		idempotent = true,
	},
	{
		name = "archive_load",
		command = "archive.load",
		description = "Load one patch of an archive bank as the sound. Replaces the whole patch and clears what the last one left ringing. With bank, that bank is opened first for every client; without it the open bank is used.",
		args = {
			{
				name = "index",
				kind = .Integer,
				required = true,
				min = 0,
				max = MAX_SAFE_INTEGER,
				description = "Zero-based patch index, as archive_patches lists it.",
			},
			{
				name = "bank",
				kind = .Integer,
				min = 0,
				max = MAX_SAFE_INTEGER,
				description = "Zero-based bank index the patch list came from, as archive_banks lists it. Send it when another client may have browsed elsewhere.",
			},
		},
		destructive = true,
	},
	{
		name = "archive_close",
		command = "archive.close",
		description = "Close the shared archive and forget its remembered path, so the next daemon start does not reopen it. The sound does not change.",
		destructive = true,
		idempotent = true,
	},
	{
		name = "midi_list",
		command = "midi.list",
		description = "List the native MIDI inputs the daemon finds now, with each one's id and name, and the current selection. Choose by id: two controllers can share a name.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "midi_select",
		command = "midi.select",
		description = "Choose which MIDI inputs the daemon listens to, for every client: all, none, or an id from midi_list. Not saved across restarts. Held notes are not released, and midi_send still works with none.",
		args = {
			{
				name = "input",
				kind = .Token,
				required = true,
				description = "all, none or a device id from midi_list, exactly as listed.",
			},
		},
		idempotent = true,
	},
	{
		name = "midi_current",
		command = "midi.current",
		description = "Read the selected MIDI input, its name and midi_rev, which changes whenever any client changes the selection.",
		read_only = true,
		idempotent = true,
	},
	{
		name = "midi_send",
		command = "midi",
		description = "Inject one MIDI message as if a controller had played it. A note on keeps sounding until its note off arrives, so always send both. Nothing releases held notes but a note off or stopping the daemon.",
		args = {
			{
				name = "status",
				kind = .Integer,
				required = true,
				min = 0,
				max = 255,
				description = "Status byte, channel in the low four bits: 144 is note on, 128 note off, 176 control change, 192 program change, 224 pitch bend, on channel 1.",
			},
			{
				name = "data1",
				kind = .Integer,
				required = true,
				min = 0,
				max = 127,
				description = "First data byte: the note number, controller number or program.",
			},
			{
				name = "data2",
				kind = .Integer,
				required = true,
				min = 0,
				max = 127,
				description = "Second data byte: the velocity or value. Send 0 for a program change.",
			},
		},
	},
	{
		name = "volume",
		command = "volume",
		description = "Set the daemon's master output level for every client: 0 is silent, 1000 is full level, the level at each start. It is the listener's level, not a patch parameter, so no revision changes. daemon_info reports the current level.",
		args = {
			{
				name = "milli",
				kind = .Integer,
				required = true,
				min = 0,
				max = VOLUME_MAX,
				description = "Level in thousandths of full scale.",
			},
		},
		idempotent = true,
	},
}

find_tool :: proc(name: string) -> ^Tool {
	for &tool in TOOLS {
		if tool.name == name { return &tool }
	}
	return nil
}

@(private)
is_token_rune :: proc(c: rune) -> bool {
	return !(unicode.is_space(c) || c < 0x20 || (c >= 0x7f && c <= 0x9f))
}

@(private)
is_control_rune :: proc(c: rune) -> bool {
	return c < 0x20 || (c >= 0x7f && c <= 0x9f) || c == 0x2028 || c == 0x2029
}

// Why a token cannot go to the daemon as it is, or "" when it can.
@(private)
token_problem :: proc(label, text: string) -> string {
	if text == "" { return fmt.tprintf("%s must not be empty", label) }
	for c in text {
		if !is_token_rune(c) {
			return fmt.tprintf("%s must not contain whitespace or control characters (U+%04X)", label, c)
		}
	}
	return ""
}

// Why a text cannot go to the daemon as it is, or "" when it can. The daemon
// trims whitespace from both ends of a path, which would name another file.
@(private)
text_problem :: proc(label, text: string) -> string {
	for c in text {
		if is_control_rune(c) {
			return fmt.tprintf("%s must not contain control characters or line separators (U+%04X)", label, c)
		}
	}
	if strings.trim_space(text) != text {
		return fmt.tprintf("%s must not start or end with whitespace", label)
	}
	return ""
}

@(private)
integer_problem :: proc(label: string, value: json.Value, min, max: int) -> (n: int, problem: string) {
	parsed, ok := integer(value)
	if ok && parsed >= min && parsed <= max { return parsed, "" }
	return 0, fmt.tprintf("%s must be an integer from %d to %d", label, min, max)
}

@(private)
invalid :: proc(message: string) -> Failure {
	return {"invalid_arguments", message}
}

// The line that goes to the daemon after the version and id, or the reason the
// arguments cannot be sent. Nothing has been sent when it fails.
@(private)
call_line :: proc(tool: ^Tool, args: json.Object) -> (line: string, failure: Failure) {
	// Reported first and in key order, not map order, so the message does not
	// depend on how the keys were hashed. A misspelt expected_revision must
	// not quietly drop the guard it was meant to be.
	unknown: string
	found := false
	for key in args {
		known := false
		for a in tool.args { known ||= a.name == key }
		if !known && (!found || key < unknown) { unknown, found = key, true }
	}
	if found { return "", invalid(fmt.tprintf("unknown argument: %s", unknown)) }

	words := make([dynamic]string, 0, 8)
	append(&words, tool.command)
	// Optional operands passed over, written only if a later one is given.
	gaps := make([dynamic]string, 0, 4)
	for a in tool.args {
		value, present := args[a.name]
		if !present && a.required { return "", invalid(fmt.tprintf("missing argument: %s", a.name)) }
		operands := make([dynamic]string, 0, 2)
		if present {
			switch a.kind {
			case .Integer:
				n, problem := integer_problem(a.name, value, a.min, a.max)
				if problem != "" { return "", invalid(problem) }
				append(&operands, fmt.tprintf("%s%d", a.prefix, n))
			case .Token:
				text, is_text := value.(string)
				if !is_text { return "", invalid(fmt.tprintf("%s must be a string", a.name)) }
				if problem := token_problem(a.name, text); problem != "" { return "", invalid(problem) }
				append(&operands, text)
			case .Text:
				text, is_text := value.(string)
				if !is_text { return "", invalid(fmt.tprintf("%s must be a string", a.name)) }
				if text == "" && a.required { return "", invalid(fmt.tprintf("%s must not be empty", a.name)) }
				if text != "" {
					if problem := text_problem(a.name, text); problem != "" { return "", invalid(problem) }
					append(&operands, text)
				}
			case .Pairs:
				entries, is_array := value.(json.Array)
				if !is_array || len(entries) < 1 || len(entries) > MAX_PAIRS {
					return "", invalid(fmt.tprintf("%s must be an array of 1 to %d entries", a.name, MAX_PAIRS))
				}
				for entry, i in entries {
					pair, problem := pair_operands(a, entry, i)
					if problem != "" { return "", invalid(problem) }
					append(&operands, ..pair[:])
				}
			}
		}
		if len(operands) == 0 {
			// A named operand (expected_revision=) can simply be missing; a
			// positional one has to be filled if another follows it.
			if a.prefix == "" { append(&gaps, a.pad) }
			continue
		}
		for gap in gaps {
			// A skipped operand with nothing to stand for it would shift the
			// ones after it into its place.
			assert(gap != "")
			append(&words, gap)
		}
		clear(&gaps)
		append(&words, ..operands[:])
	}
	return strings.join(words[:], " "), {}
}

@(private)
pair_operands :: proc(a: Arg, entry: json.Value, i: int) -> (operands: [2]string, problem: string) {
	pair, is_object := entry.(json.Object)
	if !is_object { return {}, fmt.tprintf("%s[%d] must be an object with id and value", a.name, i) }
	for key in pair {
		if key != "id" && key != "value" { return {}, fmt.tprintf("%s[%d] has an unknown key: %s", a.name, i, key) }
	}
	id_value, has_id := pair["id"]
	number, has_value := pair["value"]
	if !has_id || !has_value { return {}, fmt.tprintf("%s[%d] needs id and value", a.name, i) }
	id, is_text := id_value.(string)
	if !is_text { return {}, fmt.tprintf("%s[%d].id must be a string", a.name, i) }
	label := fmt.tprintf("%s[%d].id", a.name, i)
	if problem = token_problem(label, id); problem != "" { return {}, problem }
	if a.reserved != "" && strings.has_prefix(id, a.reserved) {
		return {}, fmt.tprintf("%s must not begin with %s", label, a.reserved)
	}
	n: int
	n, problem = integer_problem(fmt.tprintf("%s[%d].value", a.name, i), number, -MAX_SAFE_INTEGER, MAX_SAFE_INTEGER)
	if problem != "" { return {}, problem }
	return {id, fmt.tprintf("%d", n)}, ""
}

// The daemon's reply as it came, run on one connection. Anything that is not
// read-only is sent as a change, so a failure after the request was written
// says it may have taken effect and is never retried.
@(private)
forward :: proc(path: string, tool: ^Tool, args: json.Object) -> (json.Object, Failure) {
	line, failure := call_line(tool, args)
	if failure.code != "" { return nil, failure }
	resp, err := request(path, line, !tool.read_only)
	if err.code != "" { return nil, err }
	return records(resp), {}
}

@(private)
input_schema :: proc(tool: ^Tool) -> json.Value {
	if tool.input_schema != "" { return parse(tool.input_schema) }
	properties := json.Object{}
	required := json.Array{}
	for a in tool.args {
		properties[a.name] = arg_schema(a)
		if a.required { append(&required, a.name) }
	}
	schema := json.Object{"type" = "object", "properties" = properties, "additionalProperties" = false}
	if len(required) > 0 { schema["required"] = required }
	return schema
}

@(private)
arg_schema :: proc(a: Arg) -> json.Object {
	schema := json.Object{"description" = a.description}
	switch a.kind {
	case .Integer:
		schema["type"] = "integer"
		schema["minimum"] = json.Integer(a.min)
		schema["maximum"] = json.Integer(a.max)
	case .Token:
		schema["type"] = "string"
		schema["minLength"] = json.Integer(1)
		schema["pattern"] = TOKEN_PATTERN
	case .Text:
		schema["type"] = "string"
		if a.required {
			schema["minLength"] = json.Integer(1)
			schema["pattern"] = TEXT_PATTERN
		} else {
			schema["pattern"] = OPTIONAL_TEXT_PATTERN
		}
	case .Pairs:
		id := json.Object{"type" = "string", "minLength" = json.Integer(1), "pattern" = TOKEN_PATTERN}
		if a.reserved != "" {
			id["description"] = fmt.tprintf("Parameter id exactly as parameter_list gives it. An id that begins with %s is refused.", a.reserved)
		}
		value := json.Object{"type" = "integer", "minimum" = json.Integer(-MAX_SAFE_INTEGER), "maximum" = json.Integer(MAX_SAFE_INTEGER)}
		entry := json.Object {
			"type"                 = "object",
			"required"             = json.Array{"id", "value"},
			"additionalProperties" = false,
			"properties"           = json.Object{"id" = id, "value" = value},
		}
		schema["type"] = "array"
		schema["minItems"] = json.Integer(1)
		schema["maxItems"] = json.Integer(MAX_PAIRS)
		schema["items"] = entry
	}
	return schema
}

@(private)
tool_json :: proc(tool: ^Tool) -> json.Object {
	output := tool.output_schema != "" ? parse(tool.output_schema) : parse(REPLY_SCHEMA)
	return json.Object {
		"name" = tool.name,
		"description" = tool.description,
		"inputSchema" = input_schema(tool),
		"outputSchema" = output,
		"annotations" = json.Object {
			"readOnlyHint" = tool.read_only,
			"destructiveHint" = tool.destructive,
			"idempotentHint" = tool.idempotent,
			"openWorldHint" = false,
		},
	}
}

@(private)
tool_list :: proc() -> json.Object {
	tools := make(json.Array, 0, len(TOOLS))
	for &tool in TOOLS { append(&tools, tool_json(&tool)) }
	return json.Object{"tools" = tools}
}
