package tui

import "core:c"
import "core:fmt"
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
	if cl.fd >= 0 {
		posix.close(cl.fd)
		cl.fd = -1
	}
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

client_patch_load :: proc(cl: ^Client, slot: int) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d patch.load %d", control.PROTOCOL_VERSION, cl.next_id, slot))
}

// Load a patch file. Returns the patch's own name (from inside the file, cloned;
// caller frees) and whether it loaded.
client_patch_load_file :: proc(cl: ^Client, path: string) -> (name: string, ok: bool) {
	line := fmt.tprintf("%d %d patch.load_file %s", control.PROTOCOL_VERSION, cl.next_id, path)
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

client_patch_save :: proc(cl: ^Client, slot: int, name: string) -> bool {
	line := name == "" \
		? fmt.tprintf("%d %d patch.save %d", control.PROTOCOL_VERSION, cl.next_id, slot) \
		: fmt.tprintf("%d %d patch.save %d %s", control.PROTOCOL_VERSION, cl.next_id, slot, name)
	return client_ok(cl, line)
}

client_bank_write :: proc(cl: ^Client, path: string) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d bank.write %s", control.PROTOCOL_VERSION, cl.next_id, path))
}

client_bank_load_file :: proc(cl: ^Client, path: string) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d bank.load_file %s", control.PROTOCOL_VERSION, cl.next_id, path))
}

// The archive browser's client half. Names are listed in daemon-index order, so a
// name's position is the index archive.bank / archive.load expect.

client_archive_open :: proc(cl: ^Client, path: string) -> (banks: int, ok: bool) {
	line := fmt.tprintf("%d %d archive.open %s", control.PROTOCOL_VERSION, cl.next_id, path)
	cl.next_id += 1
	payload, sent := client_roundtrip(cl, line)
	if !sent { return 0, false }
	defer delete(payload)
	resp, parsed := control.response_parse(payload)
	if !parsed || resp.status != .Ok { return 0, false }
	return client_field_int(resp.fields, "banks"), true
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

client_archive_load :: proc(cl: ^Client, index: int) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d archive.load %d", control.PROTOCOL_VERSION, cl.next_id, index))
}

client_archive_close :: proc(cl: ^Client) -> bool {
	return client_ok(cl, fmt.tprintf("%d %d archive.close", control.PROTOCOL_VERSION, cl.next_id))
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
