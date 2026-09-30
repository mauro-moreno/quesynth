#+build linux
package standalone_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import control "../../src/control"
import standalone "../../hosts/standalone"
import tui "../../hosts/standalone/tui"

// The daemon's one native MIDI input selection, driven through the real
// control_handle and the real Midi_Queue. There is no raw-MIDI hardware on a CI
// box, so a fake Midi_Input stands in for ALSA and WinMM, and it plays the part
// a reader thread plays: a device pushes into the queue only while it is open,
// once per reader attached to it, so a device opened twice would deliver every
// event twice and show here. The expected replies are the wire format as the
// protocol contract spells it, written out by hand, and the expected queue
// words are the documented status | data1<<8 | data2<<16 layout.

@(private = "file")
FAKE_MAX :: 8

@(private = "file")
Fake_Device :: struct {
	id, name: string,
	// Readers attached now; the most ever attached at once; opens in all.
	readers:  int,
	peak:     int,
	opens:    int,
	// Refuses to open, as a busy or just-unplugged controller does.
	refuses:  bool,
	queue:    ^standalone.Midi_Queue,
}

@(private = "file")
Midi_Bench :: struct {
	queue:     standalone.Midi_Queue,
	devices:   [FAKE_MAX]Fake_Device,
	count:     int,
	input:     standalone.Midi_Input,
	selection: standalone.Midi_Selection,
	cc:        standalone.Control_Context,
}

// Two inputs share a name, as two identical controllers do; only the id tells
// them apart. One name has spaces, which travel raw to the end of the line.
@(private = "file")
KEYS :: [2]string{"hw:1,0", "Launchkey Mini MK3 MIDI"}
@(private = "file")
PAD_A :: [2]string{"hw:2,0", "USB MIDI Interface"}
@(private = "file")
PAD_B :: [2]string{"hw:3,0", "USB MIDI Interface"}

// A daemon's selection as run_daemon starts it, over the fake backend.
@(private = "file")
midi_bench_start :: proc(devices: ..[2]string) -> ^Midi_Bench {
	b := new(Midi_Bench)
	standalone.midi_queue_init(&b.queue)
	for d, i in devices {
		b.devices[i] = Fake_Device {
			id   = d[0],
			name = d[1],
		}
	}
	b.count = len(devices)
	b.input = standalone.Midi_Input {
		impl         = b,
		open         = fake_open,
		list         = fake_list,
		open_device  = fake_open_device,
		close_inputs = fake_close_inputs,
		close        = fake_close_inputs,
	}
	standalone.midi_selection_init(&b.selection, &b.input, &b.queue)
	b.cc = standalone.Control_Context {
		midi        = &b.queue,
		midi_select = &b.selection,
	}
	return b
}

@(private = "file")
midi_bench_stop :: proc(b: ^Midi_Bench) {
	b.input.close(&b.input)
	free(b)
}

@(private = "file")
fake_attach :: proc(b: ^Midi_Bench, i: int, queue: ^standalone.Midi_Queue) {
	d := &b.devices[i]
	d.readers += 1
	d.peak = max(d.peak, d.readers)
	d.opens += 1
	d.queue = queue
}

@(private = "file")
fake_open :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue) -> bool {
	b := (^Midi_Bench)(m.impl)
	for i in 0 ..< b.count {
		if !b.devices[i].refuses {fake_attach(b, i, queue)}
	}
	return true
}

@(private = "file")
fake_list :: proc(m: ^standalone.Midi_Input) -> []standalone.Midi_Device {
	b := (^Midi_Bench)(m.impl)
	devices := make([]standalone.Midi_Device, b.count)
	for i in 0 ..< b.count {
		devices[i] = standalone.Midi_Device {
			id   = strings.clone(b.devices[i].id),
			name = strings.clone(b.devices[i].name),
		}
	}
	return devices
}

@(private = "file")
fake_open_device :: proc(m: ^standalone.Midi_Input, queue: ^standalone.Midi_Queue, id: string) -> bool {
	b := (^Midi_Bench)(m.impl)
	for i in 0 ..< b.count {
		if b.devices[i].id != id {continue}
		if b.devices[i].refuses {return false}
		fake_attach(b, i, queue)
		return true
	}
	return false
}

@(private = "file")
fake_close_inputs :: proc(m: ^standalone.Midi_Input) {
	b := (^Midi_Bench)(m.impl)
	for i in 0 ..< b.count {b.devices[i].readers = 0}
}

// A key played on the device `id`: every reader attached to it pushes it, and
// a device nobody opened delivers nothing.
@(private = "file")
play :: proc(b: ^Midi_Bench, id: string, message: u32) {
	for i in 0 ..< b.count {
		d := &b.devices[i]
		if d.id != id {continue}
		for _ in 0 ..< d.readers {standalone.midi_queue_push(d.queue, message)}
	}
}

@(private = "file")
device :: proc(b: ^Midi_Bench, id: string) -> ^Fake_Device {
	for i in 0 ..< b.count {
		if b.devices[i].id == id {return &b.devices[i]}
	}
	return nil
}

// Everything the audio thread would take from the queue now, in order.
@(private = "file")
drain_queue :: proc(q: ^standalone.Midi_Queue) -> []u32 {
	got: [dynamic]u32
	got.allocator = context.temp_allocator
	for {
		message, ok := standalone.midi_queue_pop(q)
		if !ok {break}
		append(&got, message)
	}
	return got[:]
}

@(private = "file")
expect_queue :: proc(t: ^testing.T, b: ^Midi_Bench, want: []u32, loc := #caller_location) {
	got := drain_queue(&b.queue)
	testing.expectf(t, slice.equal(got, want), "queue held %x, want %x", got, want, loc = loc)
}

@(private = "file")
midi_ask :: proc(cc: ^standalone.Control_Context, line: string) -> string {
	req, parsed := control.request_parse(transmute([]u8)line)
	assert(parsed)
	out := strings.builder_make(context.temp_allocator)
	standalone.control_handle(cc, req, &out)
	return strings.to_string(out)
}

@(test)
test_midi_list_reports_every_input_and_opens_none :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)

	testing.expect_value(
		t,
		midi_ask(&b.cc, "1 1 midi.list"),
		"1 1 ok count=3 selected=all midi_rev=0\nid=hw:1,0 name=Launchkey Mini MK3 MIDI\nid=hw:2,0 name=USB MIDI Interface\nid=hw:3,0 name=USB MIDI Interface",
	)

	// Plugged in since: the next list has it, because nothing is cached.
	b.devices[3] = Fake_Device {
		id   = "hw:4,0",
		name = "Keystation 49",
	}
	b.count = 4
	testing.expect_value(
		t,
		midi_ask(&b.cc, "1 2 midi.list"),
		"1 2 ok count=4 selected=all midi_rev=0\nid=hw:1,0 name=Launchkey Mini MK3 MIDI\nid=hw:2,0 name=USB MIDI Interface\nid=hw:3,0 name=USB MIDI Interface\nid=hw:4,0 name=Keystation 49",
	)
	// Listing opened nothing: the three are open once, from startup.
	for i in 0 ..< 3 {testing.expect_value(t, b.devices[i].opens, 1)}
	testing.expect_value(t, b.devices[3].opens, 0)
}

@(test)
test_midi_list_with_no_inputs :: proc(t: ^testing.T) {
	b := midi_bench_start()
	defer midi_bench_stop(b)
	testing.expect_value(t, midi_ask(&b.cc, "1 1 midi.list"), "1 1 ok count=0 selected=all midi_rev=0")
	testing.expect_value(t, midi_ask(&b.cc, "1 2 midi.current"), "1 2 ok selected=all midi_rev=0\nname=All inputs")
}

@(test)
test_midi_selection_starts_with_every_input_open :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	testing.expect_value(t, midi_ask(&b.cc, "1 1 midi.current"), "1 1 ok selected=all midi_rev=0\nname=All inputs")
	for i in 0 ..< 3 {
		testing.expect_value(t, b.devices[i].readers, 1)
		testing.expect_value(t, b.devices[i].opens, 1)
	}
}

@(test)
test_midi_select_bumps_rev_once_per_real_change :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)

	testing.expect_value(t, midi_ask(&b.cc, "1 1 midi.select hw:3,0"), "1 1 ok selected=hw:3,0 midi_rev=1")
	testing.expect_value(t, midi_ask(&b.cc, "1 2 midi.current"), "1 2 ok selected=hw:3,0 midi_rev=1\nname=USB MIDI Interface")
	testing.expect_value(t, device(b, "hw:1,0").readers, 0)
	testing.expect_value(t, device(b, "hw:2,0").readers, 0)
	testing.expect_value(t, device(b, "hw:3,0").readers, 1)

	// The one already selected: nothing closed, nothing reopened, no rev.
	testing.expect_value(t, midi_ask(&b.cc, "1 3 midi.select hw:3,0"), "1 3 ok selected=hw:3,0 midi_rev=1")
	testing.expect_value(t, device(b, "hw:3,0").opens, 2)
	testing.expect_value(t, device(b, "hw:3,0").readers, 1)

	testing.expect_value(t, midi_ask(&b.cc, "1 4 midi.select none"), "1 4 ok selected=none midi_rev=2")
	testing.expect_value(t, midi_ask(&b.cc, "1 5 midi.current"), "1 5 ok selected=none midi_rev=2\nname=None")
	for i in 0 ..< 3 {testing.expect_value(t, b.devices[i].readers, 0)}
	testing.expect_value(t, midi_ask(&b.cc, "1 6 midi.select none"), "1 6 ok selected=none midi_rev=2")

	testing.expect_value(t, midi_ask(&b.cc, "1 7 midi.select all"), "1 7 ok selected=all midi_rev=3")
	testing.expect_value(t, midi_ask(&b.cc, "1 8 midi.current"), "1 8 ok selected=all midi_rev=3\nname=All inputs")
	testing.expect_value(t, midi_ask(&b.cc, "1 9 midi.select all"), "1 9 ok selected=all midi_rev=3")
	for i in 0 ..< 3 {
		testing.expect_value(t, b.devices[i].readers, 1)
		testing.expect_value(t, b.devices[i].peak, 1)
	}
	testing.expect_value(t, device(b, "hw:1,0").opens, 2)
}

@(test)
test_midi_select_refusals_leave_the_selection_alone :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	testing.expect_value(t, midi_ask(&b.cc, "1 1 midi.select hw:1,0"), "1 1 ok selected=hw:1,0 midi_rev=1")
	want := "1 9 ok selected=hw:1,0 midi_rev=1\nname=Launchkey Mini MK3 MIDI"

	// Unplugged since a client listed it: checked against what is there now.
	b.devices[1] = b.devices[2]
	b.count = 2

	refused := [][2]string {
		{"1 2 midi.select", "1 2 err invalid_payload midi.select needs all, none or an input id"},
		{"1 3 midi.select hw:2,0 hw:3,0", "1 3 err invalid_payload midi.select needs all, none or an input id"},
		{"1 4 midi.select hw:9,0", "1 4 err invalid_payload no such midi input"},
		{"1 5 midi.select hw:2,0", "1 5 err invalid_payload no such midi input"},
		{"1 6 midi.select Launchkey", "1 6 err invalid_payload no such midi input"},
	}
	for r in refused {
		testing.expect_value(t, midi_ask(&b.cc, r[0]), r[1])
		testing.expect_value(t, midi_ask(&b.cc, "1 9 midi.current"), want)
	}
	testing.expect_value(t, device(b, "hw:1,0").opens, 2)
	testing.expect_value(t, device(b, "hw:1,0").readers, 1)
	testing.expect_value(t, device(b, "hw:3,0").readers, 0)
}

@(test)
test_midi_select_open_failure_keeps_the_previous_selection :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	device(b, "hw:2,0").refuses = true

	testing.expect_value(t, midi_ask(&b.cc, "1 1 midi.select hw:1,0"), "1 1 ok selected=hw:1,0 midi_rev=1")
	testing.expect_value(t, midi_ask(&b.cc, "1 2 midi.select hw:2,0"), "1 2 err internal_error cannot open midi input")
	testing.expect_value(t, midi_ask(&b.cc, "1 3 midi.current"), "1 3 ok selected=hw:1,0 midi_rev=1\nname=Launchkey Mini MK3 MIDI")
	testing.expect_value(t, device(b, "hw:1,0").readers, 1)
	testing.expect_value(t, device(b, "hw:2,0").readers, 0)
	testing.expect_value(t, device(b, "hw:3,0").readers, 0)

	// From every input, the same: all of them back, and the rev where it was.
	testing.expect_value(t, midi_ask(&b.cc, "1 4 midi.select all"), "1 4 ok selected=all midi_rev=2")
	testing.expect_value(t, midi_ask(&b.cc, "1 5 midi.select hw:2,0"), "1 5 err internal_error cannot open midi input")
	testing.expect_value(t, midi_ask(&b.cc, "1 6 midi.current"), "1 6 ok selected=all midi_rev=2\nname=All inputs")
	testing.expect_value(t, device(b, "hw:1,0").readers, 1)
	testing.expect_value(t, device(b, "hw:3,0").readers, 1)
	for i in 0 ..< 3 {testing.expect(t, b.devices[i].peak <= 1)}
}

@(test)
test_midi_commands_without_a_backend :: proc(t: ^testing.T) {
	queue: standalone.Midi_Queue
	cc := standalone.Control_Context {
		midi = &queue,
	}
	testing.expect_value(t, midi_ask(&cc, "1 1 midi.list"), "1 1 err daemon_not_ready no midi input")
	testing.expect_value(t, midi_ask(&cc, "1 2 midi.select all"), "1 2 err daemon_not_ready no midi input")
	testing.expect_value(t, midi_ask(&cc, "1 3 midi.current"), "1 3 err daemon_not_ready no midi input")

	// A backend that implements none of it, as a platform stub's zero value
	// does: nothing to list, nothing to switch, and no crash.
	stub: standalone.Midi_Input
	selection: standalone.Midi_Selection
	standalone.midi_selection_init(&selection, &stub, &queue)
	cc.midi_select = &selection
	testing.expect_value(t, midi_ask(&cc, "1 4 midi.list"), "1 4 ok count=0 selected=all midi_rev=0")
	testing.expect_value(t, midi_ask(&cc, "1 5 midi.select none"), "1 5 err daemon_not_ready no midi input")
	testing.expect_value(t, midi_ask(&cc, "1 6 midi.current"), "1 6 ok selected=all midi_rev=0\nname=All inputs")
}

@(test)
test_only_the_selected_input_reaches_the_queue :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	testing.expect(t, strings.has_prefix(midi_ask(&b.cc, "1 1 midi.select hw:1,0"), "1 1 ok"))

	play(b, "hw:1,0", 0x643C90) // note on 60
	play(b, "hw:2,0", 0x643E90) // note on 62
	play(b, "hw:3,0", 0x644090) // note on 64
	play(b, "hw:1,0", 0x003C80) // note off 60
	expect_queue(t, b, {0x643C90, 0x003C80})

	// Switched: the old device is closed before the new one opens, so it
	// delivers nothing afterwards.
	testing.expect(t, strings.has_prefix(midi_ask(&b.cc, "1 2 midi.select hw:2,0"), "1 2 ok"))
	play(b, "hw:1,0", 0x643C90)
	play(b, "hw:2,0", 0x643E90)
	expect_queue(t, b, {0x643E90})
}

@(test)
test_every_input_to_one_leaves_no_other_reader :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	play(b, "hw:1,0", 0x643C90)
	play(b, "hw:2,0", 0x643E90)
	play(b, "hw:3,0", 0x644090)
	expect_queue(t, b, {0x643C90, 0x643E90, 0x644090})

	sequence := []string{"hw:3,0", "all", "hw:3,0", "none", "hw:1,0", "all", "all", "hw:1,0"}
	for token, i in sequence {
		reply := midi_ask(&b.cc, fmt.tprintf("1 %d midi.select %s", i + 1, token))
		testing.expect(t, strings.has_prefix(reply, fmt.tprintf("1 %d ok selected=%s ", i + 1, token)), reply)
		play(b, "hw:1,0", 0x643C90)
		play(b, "hw:2,0", 0x643E90)
		play(b, "hw:3,0", 0x644090)
		switch token {
		case "all":
			expect_queue(t, b, {0x643C90, 0x643E90, 0x644090})
		case "none":
			expect_queue(t, b, {})
		case "hw:1,0":
			expect_queue(t, b, {0x643C90})
		case "hw:3,0":
			expect_queue(t, b, {0x644090})
		}
	}
	// Never two readers on one device, at any point of any switch.
	for i in 0 ..< 3 {testing.expect_value(t, b.devices[i].peak, 1)}
}

@(test)
test_forwarded_and_native_events_each_arrive_once :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A)
	defer midi_bench_stop(b)
	testing.expect(t, strings.has_prefix(midi_ask(&b.cc, "1 1 midi.select hw:1,0"), "1 1 ok"))

	// A key on the controller and a key on the page's keyboard, which the
	// browser adapter forwards with the midi command.
	play(b, "hw:1,0", 0x643C90)
	testing.expect_value(t, midi_ask(&b.cc, "1 2 midi 144 62 100"), "1 2 ok")
	expect_queue(t, b, {0x643C90, 0x643E90})

	// With no native input the forwarded one still arrives, once.
	testing.expect(t, strings.has_prefix(midi_ask(&b.cc, "1 3 midi.select none"), "1 3 ok"))
	play(b, "hw:1,0", 0x643C90)
	testing.expect_value(t, midi_ask(&b.cc, "1 4 midi 128 62 0"), "1 4 ok")
	expect_queue(t, b, {0x003E80})
}

// The TUI's side of a request: the TUI client's own connection, read with the
// control package's parser. The browser's side below compares raw bytes.
@(private = "file")
tui_peer_ask :: proc(cl: ^tui.Client, line: string) -> (resp: control.Response, ok: bool) {
	reliability_send(cl.fd, line)
	reply := reliability_reply(cl.fd)
	return control.response_parse(transmute([]u8)reply)
}

@(private = "file")
browser_ask :: proc(fd: posix.FD, line: string) -> string {
	reliability_send(fd, line)
	return reliability_reply(fd)
}

@(test)
test_peers_share_the_midi_selection_over_the_socket :: proc(t: ^testing.T) {
	b := midi_bench_start(KEYS, PAD_A, PAD_B)
	defer midi_bench_stop(b)
	ring: standalone.Param_Ring
	snap: standalone.Snapshot
	state := standalone.Daemon_State.Running
	standalone.snapshot_publish(&snap, standalone.Snapshot_Data{})

	cs: standalone.Control_Server
	cs.path = fmt.tprintf("/tmp/quesynth-midi-peers-%d.sock", posix.getpid())
	cs.ctx = b.cc
	cs.ctx.ring = &ring
	cs.ctx.snapshot = &snap
	cs.ctx.state = &state
	if !testing.expect(t, standalone.control_server_start(&cs)) {return}
	defer standalone.control_server_stop(&cs)
	client, connected := tui.client_connect(cs.path)
	defer tui.client_close(&client)
	browser, reached := connect_unix(cs.path)
	if !testing.expect(t, connected && reached) {return}
	defer posix.close(browser)

	testing.expect_value(t, browser_ask(browser, "1 1 midi.current"), "1 1 ok selected=all midi_rev=0\nname=All inputs")

	// The TUI picks one; the browser's next poll sees the rev move.
	resp, ok := tui_peer_ask(&client, "1 1 midi.select hw:3,0")
	testing.expect(t, ok && resp.status == .Ok)
	testing.expect_value(t, browser_ask(browser, "1 2 midi.current"), "1 2 ok selected=hw:3,0 midi_rev=1\nname=USB MIDI Interface")
	testing.expect_value(
		t,
		browser_ask(browser, "1 3 midi.list"),
		"1 3 ok count=3 selected=hw:3,0 midi_rev=1\nid=hw:1,0 name=Launchkey Mini MK3 MIDI\nid=hw:2,0 name=USB MIDI Interface\nid=hw:3,0 name=USB MIDI Interface",
	)

	// The browser picks none; the TUI sees it.
	testing.expect_value(t, browser_ask(browser, "1 4 midi.select none"), "1 4 ok selected=none midi_rev=2")
	current, cur_ok := tui_peer_ask(&client, "1 2 midi.current")
	testing.expect(t, cur_ok && current.status == .Ok)
	selected, _ := control.response_field(current.fields, "selected")
	rev, _ := control.response_field(current.fields, "midi_rev")
	testing.expect_value(t, selected, "none")
	testing.expect_value(t, rev, "2")
	testing.expect_value(t, current.body, "name=None")
	for i in 0 ..< 3 {testing.expect_value(t, b.devices[i].readers, 0)}
}
