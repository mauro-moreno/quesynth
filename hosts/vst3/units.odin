package synth_vst3

import "../../src/patch"
import "../../src/vst3"

// Units and programs: what makes a host send a MIDI Program Change here.
//
// The program parameter carrying kIsProgramChange was not enough on its own,
// and the symptom was total: Ableton and Bitwig both ignored program changes
// entirely, with no error anywhere to say why. The flag says "this parameter is
// the program". IUnitInfo is what says *the programs exist* -- a unit that owns
// a program list, and a list with a count and a name for each entry. A host
// with no list has nothing to change to, so it never routes the message.
//
// One unit, the root, owning one list of a hundred and twenty-eight. That is
// the shape of an instrument with a single bank, and describing more would be
// describing a rack this is not.
//
// The names come from the same embedded bank a program change loads from, so
// the list a host draws is the list it will actually get.

PROGRAM_LIST_ID :: i32(0)

@(private = "file")
put_name :: proc(into: ^vst3.String128, text: string) {
	vst3.copy_utf16(into, text)
}

unit_query_interface :: proc "c" (this: rawptr, iid: ^vst3.TUID, obj: ^rawptr) -> vst3.Result {
	p := from_unit_info(this)
	context = p.ctx
	return query_interface(p, iid, obj)
}

unit_add_ref :: proc "c" (this: rawptr) -> u32 {
	p := from_unit_info(this)
	p.ref_count += 1
	return u32(p.ref_count)
}

unit_release :: proc "c" (this: rawptr) -> u32 {
	return release(from_unit_info(this))
}

unit_get_unit_count :: proc "c" (this: rawptr) -> i32 {
	return 1
}

unit_get_unit_info :: proc "c" (this: rawptr, index: i32, info: ^vst3.Unit_Info) -> vst3.Result {
	if info == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	p := from_unit_info(this)
	context = p.ctx

	info.id = vst3.ROOT_UNIT_ID
	// The root's parent is itself in the SDK's own examples; -1 would be a unit
	// that is not in the tree.
	info.parent_unit_id = vst3.ROOT_UNIT_ID
	put_name(&info.name, "Quesynth")
	// The connection the whole thing turns on: this unit owns that list, and
	// the parameter flagged kIsProgramChange in this unit is what selects from
	// it.
	info.program_list_id = PROGRAM_LIST_ID
	return vst3.RESULT_OK
}

unit_get_program_list_count :: proc "c" (this: rawptr) -> i32 {
	return 1
}

unit_get_program_list_info :: proc "c" (
	this: rawptr,
	index: i32,
	info: ^vst3.Program_List_Info,
) -> vst3.Result {
	if info == nil || index != 0 {
		return vst3.INVALID_ARGUMENT
	}
	p := from_unit_info(this)
	context = p.ctx

	info.id = PROGRAM_LIST_ID
	put_name(&info.name, "Factory")
	info.program_count = i32(patch.FACTORY_SLOTS)
	return vst3.RESULT_OK
}

unit_get_program_name :: proc "c" (
	this: rawptr,
	list: i32,
	index: i32,
	name: ^vst3.String128,
) -> vst3.Result {
	if name == nil || list != PROGRAM_LIST_ID {
		return vst3.INVALID_ARGUMENT
	}
	if index < 0 || int(index) >= patch.FACTORY_SLOTS {
		return vst3.INVALID_ARGUMENT
	}
	p := from_unit_info(this)
	context = p.ctx

	// An empty slot is named rather than left blank. It is still a slot -- a
	// host's program menu has to have an entry for it or the numbering in that
	// menu stops matching the numbering everywhere else.
	put_name(name, patch.factory_name(int(index)))
	return vst3.RESULT_OK
}

unit_get_program_info :: proc "c" (
	this: rawptr,
	list: i32,
	index: i32,
	attribute: cstring,
	value: ^vst3.String128,
) -> vst3.Result {
	// No attributes. The only ones the SDK defines are things like an
	// instrument name and a category, and inventing them would be inventing
	// metadata this bank does not carry.
	return vst3.RESULT_FALSE
}

unit_has_program_pitch_names :: proc "c" (this: rawptr, list: i32, index: i32) -> vst3.Result {
	// Per-key names are for drum kits, where each key is a different sound.
	return vst3.RESULT_FALSE
}

unit_get_program_pitch_name :: proc "c" (
	this: rawptr,
	list: i32,
	index: i32,
	pitch: i16,
	name: ^vst3.String128,
) -> vst3.Result {
	return vst3.RESULT_FALSE
}

unit_get_selected_unit :: proc "c" (this: rawptr) -> i32 {
	return vst3.ROOT_UNIT_ID
}

unit_select_unit :: proc "c" (this: rawptr, unit: i32) -> vst3.Result {
	return vst3.RESULT_OK if unit == vst3.ROOT_UNIT_ID else vst3.RESULT_FALSE
}

unit_get_unit_by_bus :: proc "c" (
	this: rawptr,
	type: i32,
	dir: i32,
	bus: i32,
	channel: i32,
	unit: ^i32,
) -> vst3.Result {
	if unit == nil {
		return vst3.INVALID_ARGUMENT
	}
	// Everything belongs to the one unit there is.
	unit^ = vst3.ROOT_UNIT_ID
	return vst3.RESULT_OK
}

unit_set_unit_program_data :: proc "c" (
	this: rawptr,
	list_or_unit: i32,
	index: i32,
	data: ^vst3.IBStream,
) -> vst3.Result {
	// Writing a program back into the list. The bank is compiled in and there
	// is nowhere to put it yet; refused rather than silently accepted.
	return vst3.NOT_IMPLEMENTED
}

UNIT_INFO_VTBL := vst3.IUnit_Info_Vtbl {
	query_interface         = unit_query_interface,
	add_ref                 = unit_add_ref,
	release                 = unit_release,
	get_unit_count          = unit_get_unit_count,
	get_unit_info           = unit_get_unit_info,
	get_program_list_count  = unit_get_program_list_count,
	get_program_list_info   = unit_get_program_list_info,
	get_program_name        = unit_get_program_name,
	get_program_info        = unit_get_program_info,
	has_program_pitch_names = unit_has_program_pitch_names,
	get_program_pitch_name  = unit_get_program_pitch_name,
	get_selected_unit       = unit_get_selected_unit,
	select_unit             = unit_select_unit,
	get_unit_by_bus         = unit_get_unit_by_bus,
	set_unit_program_data   = unit_set_unit_program_data,
}
