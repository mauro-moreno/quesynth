package tui

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../../../src/control"

// The protocol client half of the TUI. It speaks only the public control
// protocol over the Unix socket -- it imports src/control and src/registry, and
// never src/engine or the daemon package. That is the whole point of the slice:
// if the TUI can drive the synth through this and nothing else, so can any
// future client.

Client :: struct {
	fd:      posix.FD,
	next_id: int,
	// Archive/config errors survive periodic reads until the next user action.
	notice:  string,
}

// A total round-trip bound, not an inactivity timer: a trickling or stopped
// daemon must still give the terminal back so the user can reconnect or quit.
CLIENT_TIMEOUT_MS :: 500

client_connect :: proc(path: string) -> (Client, bool) {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return Client{fd = -1}, false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) == 0 || len(path) >= len(addr.sun_path) || strings.contains(path, "\x00") ||
		posix.fcntl(fd, .SETFL, c.int(posix.O_NONBLOCK)) < 0 {
		posix.close(fd)
		return Client{fd = -1}, false
	}
	for i in 0 ..< len(path) {
		addr.sun_path[i] = path[i]
	}
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		if posix.errno() != .EINPROGRESS || !client_wait(fd, {.OUT}, time.tick_now()) {
			posix.close(fd)
			return Client{fd = -1}, false
		}
		err: c.int
		len_err := posix.socklen_t(size_of(err))
		if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &err, &len_err) != .OK || err != 0 {
			posix.close(fd)
			return Client{fd = -1}, false
		}
	}
	return Client{fd = fd, next_id = 1}, true
}

client_close :: proc(cl: ^Client) {
	delete(cl.notice)
	cl.notice = ""
	if cl.fd >= 0 {
		posix.close(cl.fd)
		cl.fd = -1
	}
}

client_set_notice :: proc(cl: ^Client, message: string) {
	delete(cl.notice)
	cl.notice = strings.clone(message)
}

// The current stored value of a parameter. ok=false on a transport error, which
// the caller reads as "the daemon went away".
client_get :: proc(cl: ^Client, id: string) -> (value: int, ok: bool) {
	line := fmt.tprintf("%d %d parameter.get %s", control.PROTOCOL_VERSION, cl.next_id, id)
	cl.next_id += 1
	return client_value_request(cl, line)
}

// Set a parameter and return the value the daemon accepted (echoed back at
// once, before the audio thread applies it). ok=false on a transport error or a
// rejected value.
client_set :: proc(cl: ^Client, id: string, value: int) -> (applied: int, ok: bool) {
	line := fmt.tprintf(
		"%d %d parameter.set %s %d",
		control.PROTOCOL_VERSION,
		cl.next_id,
		id,
		value,
	)
	cl.next_id += 1
	return client_value_request(cl, line)
}

// The runtime metrics from daemon.info. `ok` is false on a transport error.
Metrics :: struct {
	sample_rate: int,
	buffer:      int,
	voices:      int,
	max_voices:  int,
	uptime:      int,
	revision:    int,
	ok:          bool,
}

client_info :: proc(cl: ^Client) -> Metrics {
	m: Metrics
	line := fmt.tprintf("%d %d daemon.info", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent {
		return m
	}
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok {
		return m
	}
	m.ok = true
	m.sample_rate = client_field_int(resp.fields, "sample_rate")
	m.buffer = client_field_int(resp.fields, "buffer")
	m.voices = client_field_int(resp.fields, "voices")
	m.max_voices = client_field_int(resp.fields, "max_voices")
	m.uptime = client_field_int(resp.fields, "uptime")
	m.revision = client_field_int(resp.fields, "revision")
	return m
}

@(private)
client_field_int :: proc(fields: string, key: string) -> int {
	if s, has := control.response_field(fields, key); has {
		if v, ok := strconv.parse_int(s); ok {
			return v
		}
	}
	return 0
}

// Load every parameter value in one round-trip via state.snapshot, filling the
// rows that match by id. Returns false on a transport error, leaving the rows'
// existing values (their defaults) in place.
client_load_snapshot :: proc(cl: ^Client, rows: []Row) -> bool {
	line := fmt.tprintf("%d %d state.snapshot", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent {
		return false
	}
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok {
		return false
	}

	body := resp.body
	for len(body) > 0 {
		record := body
		if idx := strings.index_byte(body, '\n'); idx >= 0 {
			record = body[:idx]
			body = body[idx + 1:]
		} else {
			body = ""
		}
		id, has_id := control.response_field(record, "id")
		value_str, has_value := control.response_field(record, "value")
		if !has_id || !has_value {
			continue
		}
		value, vok := strconv.parse_int(value_str)
		if !vok {
			continue
		}
		for &row in rows {
			if row.desc.id == id {
				row.value = value
				break
			}
		}
	}
	return true
}

// Send a request and read the "value=" field of an ok response.
@(private)
client_value_request :: proc(cl: ^Client, line: string) -> (value: int, ok: bool) {
	payload, sent := client_roundtrip(cl, line)
	if !sent {
		return 0, false
	}
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok {
		return 0, false
	}
	value_str, has := control.response_field(resp.fields, "value")
	if !has {
		return 0, false
	}
	return strconv.parse_int(value_str)
}

// Also used by --stop, which needs the same deadline and broken-pipe behavior.
client_shutdown :: proc(cl: ^Client) -> bool {
	line := fmt.tprintf("%d %d daemon.shutdown", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, ok := client_roundtrip(cl, line)
	if !ok { return false }
	defer delete(payload)
	resp, _ := control.response_parse(payload)
	return resp.status == .Ok
}

// One browsable bank entry: a slot index, the name reported for it, and whether
// it holds a patch. Every slot is listed, empty ones included, so a client can
// browse the whole bank and save into an empty slot.
Bank_Slot :: struct {
	slot:   int,
	name:   string,
	filled: bool,
}

// bank.list: every slot in order and the bank's label. Names and the label are
// cloned; free each slot name and the slice with client_bank_free, and the label
// with delete.
client_bank_list :: proc(cl: ^Client) -> (slots: []Bank_Slot, label: string, ok: bool) {
	line := fmt.tprintf("%d %d bank.list", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return nil, "", false }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return nil, "", false }
	if l, has := control.response_field(resp.fields, "label"); has { label = strings.clone(l) }

	out: [dynamic]Bank_Slot
	body := resp.body
	for len(body) > 0 {
		record := body
		if idx := strings.index_byte(body, '\n'); idx >= 0 {
			record = body[:idx]
			body = body[idx + 1:]
		} else {
			body = ""
		}
		slot_str, has_slot := control.response_field(record, "slot")
		name, has_name := control.response_field(record, "name")
		if !has_slot || !has_name { continue }
		filled_str, _ := control.response_field(record, "filled")
		if slot, sok := strconv.parse_int(slot_str); sok {
			append(&out, Bank_Slot{slot = slot, name = strings.clone(name), filled = filled_str == "1"})
		}
	}
	return out[:], label, true
}

client_bank_free :: proc(slots: []Bank_Slot) {
	for s in slots { delete(s.name) }
	delete(slots)
}

// patch.load, or with `init` patch.load <slot> init, which loads an empty slot
// as the Init patch rather than refusing it.
client_patch_load :: proc(cl: ^Client, slot: int, init := false) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d patch.load %d%s", control.PROTOCOL_VERSION, cl.next_id, slot, init ? " init" : ""))
}

// Load a patch file. Returns the patch's own name (from inside the file, cloned;
// caller frees) and whether it loaded.
client_patch_load_file :: proc(cl: ^Client, path: string) -> (name: string, ok: bool) {
	abs, resolved := client_absolute_path(cl, path)
	if !resolved { return "", false }
	line := fmt.tprintf("%d %d patch.load_file %s", control.PROTOCOL_VERSION, cl.next_id, abs)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return "", false }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return "", false }
	body := resp.body
	for line in strings.split_lines_iterator(&body) {
		if strings.has_prefix(line, "name=") {
			name = strings.clone(strings.trim_space(line[5:]))
			break
		}
	}
	return name, true
}

// patch.current: which patch the daemon is playing, the bank generation and the
// live revision, in one round-trip. The daemon owns this, so it names a patch
// another front-end loaded as readily as one this client did. bank and name are
// read raw to the end of their record lines, so a name keeps its spaces; both
// are cloned with `allocator` (an absent or empty one is "").
client_patch_current :: proc(
	cl: ^Client,
	allocator := context.allocator,
) -> (
	slot: int,
	bank: string,
	name: string,
	bank_rev: uint,
	revision: int,
	ok: bool,
) {
	p, got := client_provenance(cl, allocator)
	return p.slot, p.bank, p.name, p.bank_rev, p.revision, got
}

// Where the sound came from, which is a different question from what a client
// is browsing: an archive patch and an ordinary slot can share an index, and
// only the bank the sound came from may show it as playing.
Source :: enum {
	None,
	Bank,
	Archive,
	File,
}

// All of patch.current. The archive indices are -1 unless the sound came from
// the archive the daemon still has open.
Provenance :: struct {
	slot:          int,
	source:        Source,
	bank:          string,
	name:          string,
	archive_bank:  int,
	archive_patch: int,
	bank_rev:      uint,
	archive_rev:   uint,
	revision:      int,
}

// patch.current in full. A daemon from before the archive was shared sends
// none of the later fields; its answer reads as no source and no archive.
// bank and name are cloned with `allocator`; free with provenance_free.
client_provenance :: proc(cl: ^Client, allocator := context.allocator) -> (p: Provenance, ok: bool) {
	p.archive_bank, p.archive_patch = -1, -1
	line := fmt.tprintf("%d %d patch.current", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return }
	p.slot = client_field_int(resp.fields, "slot")
	p.revision = client_field_int(resp.fields, "revision")
	if s, has := control.response_field(resp.fields, "bank_rev"); has {
		p.bank_rev, _ = strconv.parse_uint(s)
	}
	if s, has := control.response_field(resp.fields, "archive_rev"); has {
		p.archive_rev, _ = strconv.parse_uint(s)
	}
	if s, has := control.response_field(resp.fields, "archive_bank"); has {
		p.archive_bank, _ = strconv.parse_int(s)
	}
	if s, has := control.response_field(resp.fields, "archive_patch"); has {
		p.archive_patch, _ = strconv.parse_int(s)
	}
	source, _ := control.response_field(resp.fields, "source")
	switch source {
	case "bank":
		p.source = .Bank
	case "archive":
		p.source = .Archive
	case "file":
		p.source = .File
	}
	body := resp.body
	for record in strings.split_lines_iterator(&body) {
		if strings.has_prefix(record, "bank=") {
			p.bank = strings.clone(record[5:], allocator)
		} else if strings.has_prefix(record, "name=") {
			p.name = strings.clone(record[5:], allocator)
		}
	}
	return p, true
}

provenance_free :: proc(p: ^Provenance) {
	delete(p.bank)
	delete(p.name)
	p^ = {slot = -1, archive_bank = -1, archive_patch = -1}
}

// patch.save. A refusal -- the daemon cannot keep the bank, or the edits sent
// before the save did not reach the sound in time -- is the footer's to show,
// as an archive refusal is, or S would look as if it had done nothing.
client_patch_save :: proc(cl: ^Client, slot: int, name: string) -> bool {
	line := name == "" \
		? fmt.tprintf("%d %d patch.save %d", control.PROTOCOL_VERSION, cl.next_id, slot) \
		: fmt.tprintf("%d %d patch.save %d %s", control.PROTOCOL_VERSION, cl.next_id, slot, name)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	defer delete(payload)
	_, accepted := client_noted_response(cl, payload, sent, "save")
	return accepted
}

client_bank_write :: proc(cl: ^Client, path: string) -> bool {
	abs, resolved := client_absolute_path(cl, path)
	if !resolved { return false }
	return client_ok(cl, fmt.tprintf("%d %d bank.write %s", control.PROTOCOL_VERSION, cl.next_id, abs))
}

client_bank_load_file :: proc(cl: ^Client, path: string) -> bool {
	abs, resolved := client_absolute_path(cl, path)
	if !resolved { return false }
	return client_ok(cl, fmt.tprintf("%d %d bank.load_file %s", control.PROTOCOL_VERSION, cl.next_id, abs))
}

// The daemon opens a path it is sent from its own working directory: the one
// it was started in, which is not this TUI's once another front-end started it
// or it restarted somewhere else. And archive.open keeps the path as given, to
// reopen at the next start. So every request that names a file sends it
// absolute, made so here, where no wrapper that sends one can skip it.
//
// A relative path is put under this process's working directory, where the
// user typed it, and nothing more: no cleaning, no symlink resolved, no check
// that it exists. os.get_absolute_path does all three on Linux -- it opens the
// file -- so it would refuse the new file bank.write is asked to create. `~` is
// not expanded; the prompt never was a shell. "" stays "" (archive.open's
// "reopen the remembered one"). Without a working directory nothing is sent:
// a relative path would name a file wherever the daemon happens to be.
@(private)
client_absolute_path :: proc(cl: ^Client, path: string) -> (string, bool) {
	if path == "" || path[0] == '/' { return path, true }
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || cwd == "" {
		client_set_notice(cl, "cannot read the working directory to resolve a relative path")
		return "", false
	}
	sep := cwd[len(cwd) - 1] == '/' ? "" : "/"
	return strings.concatenate({cwd, sep, path}, context.temp_allocator), true
}

// The navigator's archive half. Names are listed in daemon-index order, so a
// name's position is the index archive.bank / archive.load expect.

// archive.open, with no path when `path` is empty: the daemon then reopens the
// archive it remembers.
client_archive_open :: proc(cl: ^Client, path: string) -> (banks: int, ok: bool) {
	abs, resolved := client_absolute_path(cl, path)
	if !resolved { return 0, false }
	line := abs == "" \
		? fmt.tprintf("%d %d archive.open", control.PROTOCOL_VERSION, cl.next_id) \
		: fmt.tprintf("%d %d archive.open %s", control.PROTOCOL_VERSION, cl.next_id, abs)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	defer delete(payload)
	resp, accepted := client_noted_response(cl, payload, sent, "archive")
	if !accepted { return 0, false }
	return client_field_int(resp.fields, "banks"), true
}

// The daemon decides and opens in one request. A peer's existing choice,
// including a remembered path that will not open, is never overwritten.
client_archive_adopt :: proc(cl: ^Client, path: string) -> bool {
	abs, resolved := client_absolute_path(cl, path)
	if !resolved { return false }
	line := fmt.tprintf("%d %d archive.adopt %s", control.PROTOCOL_VERSION, cl.next_id, abs)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	defer delete(payload)
	resp, accepted := client_noted_response(cl, payload, sent, "archive")
	return accepted && client_field_int(resp.fields, "adopted") == 1
}

client_archive_bank :: proc(cl: ^Client, index: int) -> (patches: int, ok: bool) {
	line := fmt.tprintf("%d %d archive.bank %d", control.PROTOCOL_VERSION, cl.next_id, index)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return 0, false }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return 0, false }
	return client_field_int(resp.fields, "patches"), true
}

// Load patch `index` of archive bank `bank`, the one this client is showing:
// the daemon opens that bank first if a peer has opened another since. A
// negative bank loads from whichever bank is open, as the older form did.
client_archive_load :: proc(cl: ^Client, index: int, bank := -1) -> bool {
	if bank < 0 {
		return client_ok(cl, fmt.tprintf("%d %d archive.load %d", control.PROTOCOL_VERSION, cl.next_id, index))
	}
	return client_ok(cl, fmt.tprintf("%d %d archive.load %d %d", control.PROTOCOL_VERSION, cl.next_id, index, bank))
}

client_archive_close :: proc(cl: ^Client) -> bool {
	line := fmt.tprintf("%d %d archive.close", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	defer delete(payload)
	_, accepted := client_noted_response(cl, payload, sent, "archive")
	return accepted
}

// Keep the refusal until it has been shown, not just until the next periodic
// state read. A protocol refusal leaves the connection usable. `what` names
// the request in the notices of its own: "archive" or "save".
@(private = "file")
client_noted_response :: proc(cl: ^Client, payload: []u8, sent: bool, what: string) -> (control.Response, bool) {
	if !sent {
		client_set_notice(cl, fmt.tprintf("%s request failed: daemon disconnected", what))
		return {}, false
	}
	resp, parsed := control.response_parse(payload)
	if !parsed {
		client_set_notice(cl, fmt.tprintf("invalid %s response", what))
		return {}, false
	}
	client_set_notice(cl, resp.status == .Ok ? "" : resp.fields)
	return resp, resp.status == .Ok
}

// What archive.current says the daemon has open. The archive is the daemon's,
// shared with every peer, so this is read rather than remembered: a peer may
// have opened another, moved the open bank or closed it.
Archive_State :: struct {
	open:      bool,
	banks:     int,
	// The open bank's index, or -1 when none is open.
	bank:      int,
	patches:   int,
	rev:       uint,
	// The archive the daemon reopens, kept even while it will not open.
	path:      string,
	bank_name: string,
}

// archive.current. path and bank_name are read raw to the end of their record
// lines and cloned; free them with archive_state_free.
client_archive_current :: proc(cl: ^Client) -> (state: Archive_State, ok: bool) {
	state.bank = -1
	line := fmt.tprintf("%d %d archive.current", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return }
	state.open = client_field_int(resp.fields, "open") == 1
	state.banks = client_field_int(resp.fields, "banks")
	if s, has := control.response_field(resp.fields, "bank"); has {
		state.bank, _ = strconv.parse_int(s)
	}
	state.patches = client_field_int(resp.fields, "patches")
	if s, has := control.response_field(resp.fields, "archive_rev"); has {
		state.rev, _ = strconv.parse_uint(s)
	}
	body := resp.body
	for record in strings.split_lines_iterator(&body) {
		if strings.has_prefix(record, "path=") {
			state.path = strings.clone(record[5:])
		} else if strings.has_prefix(record, "bank_name=") {
			state.bank_name = strings.clone(record[10:])
		}
	}
	return state, true
}

archive_state_free :: proc(state: ^Archive_State) {
	delete(state.path)
	delete(state.bank_name)
	state^ = {bank = -1}
}

// Page through a listing verb (archive.banks / archive.patches) and return every
// name in order. The caller frees each name and the slice with client_names_free.
client_archive_names :: proc(cl: ^Client, verb: string) -> ([]string, bool) {
	names: [dynamic]string
	PAGE :: 256
	offset := 0
	for {
		line := fmt.tprintf("%d %d %s %d %d", control.PROTOCOL_VERSION, cl.next_id, verb, offset, PAGE)
		cl.next_id += 1
		payload, sent := client_roundtrip(cl, line)
		if !sent {
			client_names_free(names[:])
			return nil, false
		}
		defer delete(payload)
		resp, parsed := control.response_parse(payload)
		if !parsed || resp.status != .Ok {
			client_names_free(names[:])
			return nil, false
		}
		total := client_field_int(resp.fields, "total")
		got := 0
		body := resp.body
		for len(body) > 0 {
			record := body
			if idx := strings.index_byte(body, '\n'); idx >= 0 {
				record = body[:idx]
				body = body[idx + 1:]
			} else {
				body = ""
			}
			// name is the last field on the record; take it to the line end so a
			// name with spaces is kept whole.
			if at := strings.index(record, "name="); at >= 0 {
				append(&names, strings.clone(strings.trim_space(record[at + 5:])))
				got += 1
			}
		}
		offset += PAGE
		if got == 0 || offset >= total {
			break
		}
	}
	return names[:], true
}

client_names_free :: proc(names: []string) {
	for n in names { delete(n) }
	delete(names)
}

// The daemon's native MIDI inputs. It owns the one selection every front-end
// shares, so the TUI keeps none of its own: it lists, asks for a change and
// reads back what the daemon then listens to.

// One input as midi.list reports it: the id midi.select takes and the name to
// show, which two identical controllers may share.
Midi_Device :: struct {
	id:   string,
	name: string,
}

// midi.list: every input the daemon sees now, in its order, and the token it
// listens to ("all", "none" or one of the ids). Ids, names and the token are
// cloned; free the list with client_midi_free and the token with delete.
client_midi_list :: proc(cl: ^Client) -> (devices: []Midi_Device, selected: string, midi_rev: uint, ok: bool) {
	line := fmt.tprintf("%d %d midi.list", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return }
	if s, has := control.response_field(resp.fields, "midi_rev"); has {
		midi_rev, _ = strconv.parse_uint(s)
	}
	token, _ := control.response_field(resp.fields, "selected")

	out: [dynamic]Midi_Device
	body := resp.body
	for record in strings.split_lines_iterator(&body) {
		// An id has no spaces, so the first " name=" ends it, and the name
		// runs raw to the line end with its spaces.
		at := strings.index(record, " name=")
		if !strings.has_prefix(record, "id=") || at < 0 { continue }
		append(&out, Midi_Device{id = strings.clone(record[3:at]), name = strings.clone(record[at + 6:])})
	}
	return out[:], strings.clone(token), midi_rev, true
}

client_midi_free :: proc(devices: []Midi_Device) {
	for d in devices {
		delete(d.id)
		delete(d.name)
	}
	delete(devices)
}

// midi.select: make the daemon listen to `token` instead. A refusal -- an
// input unplugged since the list, one that will not open -- is an answer, so
// it returns false with the connection still up; only a transport error
// closes it.
client_midi_select :: proc(cl: ^Client, token: string) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d midi.select %s", control.PROTOCOL_VERSION, cl.next_id, token))
}

// midi.current: the token the daemon listens to and the name to show for it,
// read raw to the end of its record line; both cloned, the caller deletes
// them. midi_rev moves once per change, whichever front-end made it.
client_midi_current :: proc(cl: ^Client) -> (selected: string, name: string, midi_rev: uint, ok: bool) {
	line := fmt.tprintf("%d %d midi.current", control.PROTOCOL_VERSION, cl.next_id)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return }
	if s, has := control.response_field(resp.fields, "midi_rev"); has {
		midi_rev, _ = strconv.parse_uint(s)
	}
	token, _ := control.response_field(resp.fields, "selected")
	body := resp.body
	for record in strings.split_lines_iterator(&body) {
		if strings.has_prefix(record, "name=") {
			name = strings.clone(record[5:])
			break
		}
	}
	return strings.clone(token), name, midi_rev, true
}

// Send a request and report only whether it succeeded, advancing the id.
@(private)
client_ok :: proc(cl: ^Client, line: string) -> bool {
	cl.next_id += 1
	payload, ok := client_roundtrip(cl, line)
	if !ok { return false }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	return parsed && resp.status == .Ok
}

@(private)
client_roundtrip :: proc(cl: ^Client, line: string) -> (payload: []u8, ok: bool) {
	if cl.fd < 0 { return nil, false }
	defer if !ok { client_close(cl) }
	start := time.tick_now()
	frame := control.frame_encode(transmute([]u8)line)
	defer delete(frame)
	if !client_write_all(cl.fd, frame, start) { return nil, false }
	payload, ok = client_read_frame(cl.fd, start)
	if !ok { return nil, false }
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.id != cl.next_id - 1 || resp.version != control.PROTOCOL_VERSION {
		delete(payload)
		return nil, false
	}
	return payload, true
}

@(private)
client_wait :: proc(fd: posix.FD, events: posix.Poll_Event, start: time.Tick) -> bool {
	for {
		remaining := CLIENT_TIMEOUT_MS - int(time.duration_milliseconds(time.tick_since(start)))
		if remaining <= 0 { return false }
		fds := [1]posix.pollfd{{fd = fd, events = events}}
		n := posix.poll(&fds[0], 1, c.int(remaining))
		if n < 0 && posix.errno() == .EINTR { continue }
		return n > 0 && fds[0].revents & (events | {.HUP}) != {}
	}
}

@(private)
client_write_all :: proc(fd: posix.FD, data: []u8, start: time.Tick) -> bool {
	sent := 0
	for sent < len(data) {
		if !client_wait(fd, {.OUT}, start) { return false }
		remaining := len(data) - sent
		n := posix.send(fd, raw_data(data[sent:]), c.size_t(remaining), {.NOSIGNAL})
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) { continue }
		if n <= 0 { return false }
		sent += int(n)
	}
	return true
}

@(private)
client_read_frame :: proc(fd: posix.FD, start: time.Tick) -> ([]u8, bool) {
	reader: control.Frame_Reader
	defer control.frame_reader_destroy(&reader)
	buf: [1024]u8
	for {
		if !client_wait(fd, {.IN}, start) { return nil, false }
		n := posix.read(fd, raw_data(buf[:]), c.size_t(len(buf)))
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) { continue }
		if n <= 0 { return nil, false }
		control.frame_reader_push(&reader, buf[:int(n)])
		payload, ok, err := control.frame_reader_next(&reader)
		if err { return nil, false }
		if ok { return payload, true }
	}
}
