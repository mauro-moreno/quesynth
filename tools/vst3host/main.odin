package vst3host

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import cpatch "../../src/patch"
import "../../src/vst3"

// A minimal VST3 host, for proving the plugin actually loads and sounds.
//
//   vst3host <plugin.vst3> [patch.sy1]
//
// Building a plugin proves nothing about it. A VST3 module can export all three
// entry points, report a factory, and still be refused by a host because one
// interface identifier's bytes are in the wrong order or `queryInterface` hands
// back the object where it should hand back a vtable field -- neither of which
// is a compile error, and both of which are silent. This does what a host does,
// in the order a host does it, and says which step failed.
//
// It is deliberately not a general host. It instantiates one plugin, drives one
// note through it, and reports the peak. That is the whole contract worth
// checking automatically; everything past it needs ears.

Module :: struct {
	handle:      win.HMODULE,
	get_factory: proc "c" () -> ^vst3.IPluginFactory,
	init_dll:    proc "c" () -> bool,
	exit_dll:    proc "c" () -> bool,
}

load_module :: proc(path: string) -> (m: Module, ok: bool) {
	wpath := win.utf8_to_wstring(path)
	m.handle = win.LoadLibraryW(wpath)
	if m.handle == nil {
		fmt.eprintfln("LoadLibraryW failed for %q (error %v)", path, win.GetLastError())
		return {}, false
	}

	get := win.GetProcAddress(m.handle, "GetPluginFactory")
	if get == nil {
		fmt.eprintln("the module exports no GetPluginFactory")
		return {}, false
	}
	m.get_factory = auto_cast get

	// Both are optional in the specification and expected in practice.
	if p := win.GetProcAddress(m.handle, "InitDll"); p != nil {
		m.init_dll = auto_cast p
	}
	if p := win.GetProcAddress(m.handle, "ExitDll"); p != nil {
		m.exit_dll = auto_cast p
	}
	return m, true
}

utf16_to_string :: proc(s: []u16) -> string {
	n := 0
	for n < len(s) && s[n] != 0 {
		n += 1
	}
	b := strings.builder_make()
	for i in 0 ..< n {
		strings.write_rune(&b, rune(s[i]))
	}
	return strings.to_string(b)
}

c_to_string :: proc(s: []u8) -> string {
	n := 0
	for n < len(s) && s[n] != 0 {
		n += 1
	}
	return string(s[:n])
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 {
		fmt.eprintln("usage: vst3host <plugin.vst3> [patch.sy1] [--editor]")
		os.exit(2)
	}

	// `--editor` opens the plugin's own window in a real HWND. Off by default
	// because it starts a browser process and takes a few seconds, which is not
	// what a render check should cost.
	check_the_editor := false
	positional: [dynamic]string
	defer delete(positional)
	for arg in args {
		if arg == "--editor" {
			check_the_editor = true
		} else {
			append(&positional, arg)
		}
	}
	args = positional[:]
	if len(args) < 1 {
		fmt.eprintln("usage: vst3host <plugin.vst3> [patch.sy1] [--editor]")
		os.exit(2)
	}
	plugin_path := args[0]

	m, ok := load_module(plugin_path)
	if !ok {
		os.exit(1)
	}
	if m.init_dll != nil {
		m.init_dll()
	}

	factory := m.get_factory()
	if factory == nil || factory.vtbl == nil {
		fmt.eprintln("GetPluginFactory returned nothing")
		os.exit(1)
	}

	info: vst3.Factory_Info
	if factory.vtbl.get_factory_info(factory, &info) != vst3.RESULT_OK {
		fmt.eprintln("getFactoryInfo failed")
		os.exit(1)
	}
	fmt.printfln("factory  : vendor %q", c_to_string(info.vendor[:]))

	count := factory.vtbl.count_classes(factory)
	fmt.printfln("classes  : %v", count)
	if count < 1 {
		fmt.eprintln("the factory offers no classes")
		os.exit(1)
	}

	// The factory interfaces a real host asks for before it will open anything.
	//
	// This block exists because Ableton refused the plugin with "could not be
	// opened" while the rest of this host loaded it happily: the module scanned,
	// the name came back, and instantiation still failed. The reason was that
	// only IPluginFactory was answered. A host reads the *subcategory* --
	// "Instrument|Synth" -- from getClassInfo2, and PClassInfo has no field for
	// it, so a host with no IPluginFactory2 cannot tell an instrument from an
	// effect and will not open it as either. Checking it here is what stops that
	// being discovered in a DAW again.
	f2_iid := vst3.IID_PLUGIN_FACTORY_2()
	f2obj: rawptr
	if factory.vtbl.query_interface(factory, &f2_iid, &f2obj) != vst3.RESULT_OK || f2obj == nil {
		fmt.eprintln("queryInterface(IPluginFactory2) failed -- a host cannot read the subcategory")
		os.exit(1)
	}
	factory2 := (^^vst3.IPluginFactory2_Vtbl)(f2obj)

	f3_iid := vst3.IID_PLUGIN_FACTORY_3()
	f3obj: rawptr
	if factory.vtbl.query_interface(factory, &f3_iid, &f3obj) != vst3.RESULT_OK || f3obj == nil {
		fmt.eprintln("queryInterface(IPluginFactory3) failed")
		os.exit(1)
	}

	info2: vst3.Class_Info_2
	if factory2^.get_class_info_2(f2obj, 0, &info2) != vst3.RESULT_OK {
		fmt.eprintln("getClassInfo2 failed")
		os.exit(1)
	}
	sub := c_to_string(info2.sub_categories[:])
	fmt.printfln("class 0/2: subcategories %q, vendor %q, version %q",
		sub, c_to_string(info2.vendor[:]), c_to_string(info2.version[:]))
	if sub == "" {
		fmt.eprintln("the class reports no subcategory; a host cannot classify it")
		os.exit(1)
	}

	class: vst3.Class_Info
	if factory.vtbl.get_class_info(factory, 0, &class) != vst3.RESULT_OK {
		fmt.eprintln("getClassInfo failed")
		os.exit(1)
	}
	fmt.printfln("class 0  : %q, category %q", c_to_string(class.name[:]), c_to_string(class.category[:]))

	// Instantiate as IComponent, exactly as a host does: the class id and the
	// interface id are passed as raw 16-byte identifiers, not as strings.
	component_iid := vst3.IID_COMPONENT()
	obj: rawptr
	cid := class.cid
	if factory.vtbl.create_instance(factory, cstring(rawptr(&cid)), cstring(rawptr(&component_iid)), &obj) != vst3.RESULT_OK || obj == nil {
		fmt.eprintln("createInstance for IComponent failed")
		os.exit(1)
	}
	component := (^^vst3.IComponent_Vtbl)(obj)
	fmt.println("component: created")

	if component^.initialize(obj, nil) != vst3.RESULT_OK {
		fmt.eprintln("IComponent::initialize failed")
		os.exit(1)
	}

	// The two other interfaces have to come back from queryInterface on the
	// object the host already holds. This is the step that catches a wrong
	// interface identifier or a bad vtable-field offset.
	processor_iid := vst3.IID_AUDIO_PROCESSOR()
	pobj: rawptr
	if component^.query_interface(obj, &processor_iid, &pobj) != vst3.RESULT_OK || pobj == nil {
		fmt.eprintln("queryInterface(IAudioProcessor) failed")
		os.exit(1)
	}
	processor := (^^vst3.IAudioProcessor_Vtbl)(pobj)
	fmt.println("processor: obtained")

	controller_iid := vst3.IID_EDIT_CONTROLLER()
	cobj: rawptr
	if component^.query_interface(obj, &controller_iid, &cobj) != vst3.RESULT_OK || cobj == nil {
		fmt.eprintln("queryInterface(IEditController) failed")
		os.exit(1)
	}
	controller := (^^vst3.IEditController_Vtbl)(cobj)

	// Can a host find out which parameter a controller moves?
	//
	// VST3 delivers no controller messages at all: a host asks IMidiMapping
	// once and then sends parameter changes. So a plugin that does not answer
	// this is a plugin whose filter knob no keyboard can reach, and nothing
	// about that is visible from the outside -- there is no error, the
	// controller simply does nothing. Asked here the way a host asks it.
	{
		mapping_iid := vst3.IID_MIDI_MAPPING()
		mobj: rawptr
		if component^.query_interface(obj, &mapping_iid, &mobj) != vst3.RESULT_OK ||
		   mobj == nil {
			fmt.eprintln("FAIL: the plugin does not answer to IMidiMapping")
			os.exit(1)
		}
		mapping := (^^vst3.IMidi_Mapping_Vtbl)(mobj)

		// CC 74 is Brightness in the MIDI specification, and the cutoff here.
		cutoff := cpatch.parameter_index("*filter freq")
		id: u32
		if mapping^.get_midi_controller_assignment(mobj, 0, 0, 74, &id) != vst3.RESULT_OK {
			fmt.eprintln("FAIL: controller 74 is not assigned to anything")
			os.exit(1)
		}
		if int(id) != cutoff {
			fmt.eprintfln(
				"FAIL: controller 74 maps to parameter %v, expected %v",
				id,
				cutoff,
			)
			os.exit(1)
		}

		// And one that is deliberately not assigned answers "nothing here"
		// rather than handing back a parameter it was never given.
		spare: u32 = 0xFFFFFFFF
		if mapping^.get_midi_controller_assignment(mobj, 0, 0, 20, &spare) == vst3.RESULT_OK {
			fmt.eprintln("FAIL: an unassigned controller was given a parameter")
			os.exit(1)
		}

		mapping^.release(mobj)
		fmt.printfln("midi     : controller 74 moves parameter %v", cutoff)
	}

	// Does the host know there are programs to change to?
	//
	// A parameter carrying kIsProgramChange is not enough on its own. Both
	// Ableton and Bitwig ignored program changes entirely with only that,
	// and said nothing about why: what they look for is a unit owning a
	// program list, through IUnitInfo. With no list there is nothing to
	// change to, so the message is never routed.
	{
		units_iid := vst3.IID_UNIT_INFO()
		uobj: rawptr
		if component^.query_interface(obj, &units_iid, &uobj) != vst3.RESULT_OK ||
		   uobj == nil {
			fmt.eprintln("FAIL: the plugin does not answer to IUnitInfo")
			os.exit(1)
		}
		units := (^^vst3.IUnit_Info_Vtbl)(uobj)

		if units^.get_unit_count(uobj) < 1 {
			fmt.eprintln("FAIL: no units")
			os.exit(1)
		}
		unit: vst3.Unit_Info
		if units^.get_unit_info(uobj, 0, &unit) != vst3.RESULT_OK {
			fmt.eprintln("FAIL: getUnitInfo failed")
			os.exit(1)
		}
		// The connection the whole thing turns on: without a list id on the
		// unit, the program parameter belongs to nothing.
		if unit.program_list_id == vst3.NO_PROGRAM_LIST_ID {
			fmt.eprintln("FAIL: the unit owns no program list")
			os.exit(1)
		}

		list: vst3.Program_List_Info
		if units^.get_program_list_info(uobj, 0, &list) != vst3.RESULT_OK {
			fmt.eprintln("FAIL: getProgramListInfo failed")
			os.exit(1)
		}
		if int(list.program_count) != cpatch.FACTORY_SLOTS {
			fmt.eprintfln(
				"FAIL: the list has %v programs, expected %v",
				list.program_count,
				cpatch.FACTORY_SLOTS,
			)
			os.exit(1)
		}

		// Every entry has a name, the empty ones included: a gap in a host's
		// program menu would make its numbering stop matching everything
		// else's, and the number is the point.
		blank := 0
		for i in 0 ..< list.program_count {
			name: vst3.String128
			if units^.get_program_name(uobj, list.id, i, &name) != vst3.RESULT_OK ||
			   name[0] == 0 {
				blank += 1
			}
		}
		if blank > 0 {
			fmt.eprintfln("FAIL: %v programs have no name", blank)
			os.exit(1)
		}

		units^.release(uobj)
		// The first program by name, which is how a bank loaded from disk
		// can be told from the one compiled into the binary.
		first: vst3.String128
		units^.get_program_name(uobj, list.id, 0, &first)
		fmt.printfln(
			"units    : %v, %v programs, program 0 is %v",
			vst3.utf16_to_string(&list.name, context.temp_allocator),
			list.program_count,
			vst3.utf16_to_string(&first, context.temp_allocator),
		)
	}

	// Can a host select a patch by number?
	//
	// VST3 has no Program Change event either: a host turns the message into
	// a change to whichever parameter carries kIsProgramChange. So the check
	// is that such a parameter exists, that setting it loads the patch out of
	// the bank compiled into the plugin, and that reading it back gives the
	// program that was asked for.
	{
		count := controller^.get_parameter_count(cobj)
		program_id: u32 = 0xFFFFFFFF
		steps: i32 = 0
		for i in 0 ..< count {
			info: vst3.Parameter_Info
			if controller^.get_parameter_info(cobj, i, &info) != vst3.RESULT_OK {
				continue
			}
			if info.flags & vst3.PARAM_IS_PROGRAM_CHANGE != 0 {
				program_id = info.id
				steps = info.step_count
			}
		}
		if program_id == 0xFFFFFFFF {
			fmt.eprintln("FAIL: no parameter carries kIsProgramChange")
			os.exit(1)
		}
		if steps != 127 {
			fmt.eprintfln("FAIL: the program parameter has %v steps, expected 127", steps)
			os.exit(1)
		}

		// This host has its own copy of the embedded bank -- src/patch is
		// compiled into the executable as well as into the plugin -- so it has
		// to be read in here too. Both copies come from the same file at
		// compile time, which is what makes comparing them meaningful.
		cpatch.factory_prepare()

		// Program 6, which is the Organ in the factory bank.
		wanted, filled := cpatch.factory_patch(6)
		if !filled {
			fmt.eprintln("FAIL: the embedded bank has nothing in slot 6")
			os.exit(1)
		}
		controller^.set_param_normalized(cobj, program_id, 6.0 / 127.0)

		// Every parameter, read back the way a host reads them and converted
		// back to a stored value by the plugin's own arithmetic. Comparing
		// against the bank rather than against a number this file worked out
		// for itself: the question is whether the plugin loaded the patch,
		// and a check that recomputed the mapping here would only be this
		// host agreeing with itself.
		wrong := 0
		for i in 0 ..< cpatch.PARAMETER_COUNT {
			got := controller^.get_param_normalized(cobj, u32(i))
			plain := controller^.normalized_param_to_plain(cobj, u32(i), got)
			if int(plain + 0.5) != wanted[i] {
				wrong += 1
			}
		}
		if wrong > 0 {
			fmt.eprintfln("FAIL: %v parameters do not match the patch in slot 6", wrong)
			os.exit(1)
		}

		back := controller^.get_param_normalized(cobj, program_id)
		if int(back * 127.0 + 0.5) != 6 {
			fmt.eprintfln("FAIL: program read back as %v, expected 6", back * 127.0)
			os.exit(1)
		}
		fmt.printfln("program  : parameter %v selects a patch, 0..%v", program_id, steps)
	}

	nparams := controller^.get_parameter_count(cobj)
	fmt.printfln("controller: %v parameters", nparams)

	// Buses, as a host enumerates them before deciding what to connect.
	audio_out := component^.get_bus_count(obj, vst3.MEDIA_AUDIO, vst3.DIRECTION_OUTPUT)
	event_in := component^.get_bus_count(obj, vst3.MEDIA_EVENT, vst3.DIRECTION_INPUT)
	fmt.printfln("buses    : %v audio out, %v event in", audio_out, event_in)
	if audio_out < 1 || event_in < 1 {
		fmt.eprintln("expected one audio output and one event input")
		os.exit(1)
	}

	bus: vst3.Bus_Info
	if component^.get_bus_info(obj, vst3.MEDIA_AUDIO, vst3.DIRECTION_OUTPUT, 0, &bus) == vst3.RESULT_OK {
		fmt.printfln("           out bus %q, %v channels", utf16_to_string(bus.name[:]), bus.channel_count)
	}

	// A patch, if one was named, pushed in through the parameters the way a
	// host restoring automation would.
	if len(args) >= 2 {
		data, rerr := os.read_entire_file_from_path(args[1], context.allocator)
		if rerr != nil {
			fmt.eprintfln("could not read %q", args[1])
			os.exit(1)
		}
		parsed, perr := cpatch.parse_sy1(data)
		if perr != nil {
			fmt.eprintfln("could not parse %q: %v", args[1], perr)
			os.exit(1)
		}
		applied := 0
		for i in 0 ..< cpatch.PARAMETER_COUNT {
			states := cpatch.parameter_states(i)
			if len(states) <= 1 {
				continue
			}
			v := clamp(parsed.values[i], 0, len(states) - 1)
			normalized := f64(v) / f64(len(states) - 1)
			if controller^.set_param_normalized(cobj, u32(i), normalized) == vst3.RESULT_OK {
				applied += 1
			}
		}
		fmt.printfln("patch    : %q, %v parameters applied", args[1], applied)
	}

	// Set up and activate, in the order the specification requires: the bus
	// arrangement and the process setup are both refused once active.
	stereo := [1]u64{vst3.SPEAKER_STEREO}
	if processor^.set_bus_arrangements(pobj, nil, 0, &stereo[0], 1) != vst3.RESULT_OK {
		fmt.eprintln("setBusArrangements(stereo out) refused")
		os.exit(1)
	}

	SAMPLE_RATE :: 48000.0
	BLOCK :: 512
	setup := vst3.Process_Setup {
		process_mode          = 0, // kRealtime
		symbolic_sample_size  = vst3.SAMPLE_32,
		max_samples_per_block = BLOCK,
		sample_rate           = SAMPLE_RATE,
	}
	if processor^.setup_processing(pobj, &setup) != vst3.RESULT_OK {
		fmt.eprintln("setupProcessing failed")
		os.exit(1)
	}

	component^.activate_bus(obj, vst3.MEDIA_AUDIO, vst3.DIRECTION_OUTPUT, 0, 1)
	component^.activate_bus(obj, vst3.MEDIA_EVENT, vst3.DIRECTION_INPUT, 0, 1)
	if component^.set_active(obj, 1) != vst3.RESULT_OK {
		fmt.eprintln("setActive(true) failed")
		os.exit(1)
	}
	processor^.set_processing(pobj, 1)
	fmt.println("state    : active and processing")

	// Render two seconds, with a note on at the first block.
	left := make([]f32, BLOCK)
	right := make([]f32, BLOCK)
	channels := [2][^]f32{raw_data(left), raw_data(right)}
	buffers := vst3.Audio_Bus_Buffers {
		num_channels    = 2,
		silence_flags   = 0,
		channel_buffers = (^[^]f32)(&channels[0]),
	}

	peak := 0.0
	rms := 0.0
	total := 0
	blocks := int(SAMPLE_RATE * 2.0) / BLOCK

	for b in 0 ..< blocks {
		for i in 0 ..< BLOCK {
			left[i] = 0
			right[i] = 0
		}

		events := Event_List{}
		event_list_init(&events)
		if b == 0 {
			e := vst3.Event {
				bus_index     = 0,
				sample_offset = 0,
				type          = vst3.EVENT_NOTE_ON,
			}
			note := (^vst3.Note_On_Event)(&e.payload)
			note.channel = 0
			note.pitch = 60
			note.velocity = 0.8
			note.note_id = -1
			event_list_add(&events, e)
		}

		data := vst3.Process_Data {
			process_mode         = 0,
			symbolic_sample_size = vst3.SAMPLE_32,
			num_samples          = BLOCK,
			num_inputs           = 0,
			num_outputs          = 1,
			outputs              = &buffers,
			input_events         = &events.iface,
		}
		if processor^.process(pobj, &data) != vst3.RESULT_OK {
			fmt.eprintln("process failed")
			os.exit(1)
		}

		for i in 0 ..< BLOCK {
			l := f64(left[i])
			r := f64(right[i])
			peak = max(peak, abs(l), abs(r))
			rms += l * l + r * r
			total += 2
		}
	}

	rms = total > 0 ? math.sqrt(rms / f64(total)) : 0
	fmt.printfln("render   : %v blocks, peak %.6f, rms %.6f", blocks, peak, rms)

	// While the plugin is still active, because that is when a host opens an
	// editor and the editor is entitled to expect a live engine behind it.
	editor_ok := true
	if check_the_editor {
		editor_ok = check_editor(controller, cobj, 6.0)
	}

	processor^.set_processing(pobj, 0)
	component^.set_active(obj, 0)
	component^.terminate(obj)
	controller^.release(cobj)
	processor^.release(pobj)
	component^.release(obj)
	if m.exit_dll != nil {
		m.exit_dll()
	}

	if peak <= 0.0001 {
		fmt.eprintln("FAIL: the plugin loaded but produced silence")
		os.exit(1)
	}
	if !editor_ok {
		os.exit(1)
	}
	fmt.println("OK")
}

// -- a minimal IEventList the plugin can read --------------------------------
//
// The plugin calls back into this, so it has to be a real COM object with a
// vtable, not a struct the host fills in.

MAX_EVENTS :: 16

Event_List :: struct {
	iface:  vst3.IEventList,
	events: [MAX_EVENTS]vst3.Event,
	count:  i32,
}

event_list_vtbl := vst3.IEventList_Vtbl {
	query_interface = proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
		if obj != nil {
			obj^ = this
		}
		return vst3.RESULT_OK
	},
	add_ref = proc "c" (this: rawptr) -> u32 {return 1},
	release = proc "c" (this: rawptr) -> u32 {return 1},
	get_event_count = proc "c" (this: rawptr) -> i32 {
		l := (^Event_List)(this)
		return l.count
	},
	get_event = proc "c" (this: rawptr, index: i32, e: ^vst3.Event) -> vst3.Result {
		l := (^Event_List)(this)
		if e == nil || index < 0 || index >= l.count {
			return vst3.INVALID_ARGUMENT
		}
		e^ = l.events[index]
		return vst3.RESULT_OK
	},
	add_event = proc "c" (this: rawptr, e: ^vst3.Event) -> vst3.Result {
		return vst3.NOT_IMPLEMENTED
	},
}

event_list_init :: proc(l: ^Event_List) {
	l.iface.vtbl = &event_list_vtbl
	l.count = 0
}

event_list_add :: proc(l: ^Event_List, e: vst3.Event) {
	if l.count >= MAX_EVENTS {
		return
	}
	l.events[l.count] = e
	l.count += 1
}
