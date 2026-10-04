package standalone

import "../../src/engine"
import "../../src/registry"

// The bridge between a parameter id and the engine.
//
// It resolves the id through the registry, validates the value against the
// measured domain, and applies it with engine_set_stored. In this slice it is
// called synchronously so it can be unit-tested against a plain Engine; Slice 3
// moves the apply behind the command ring so the control thread never calls the
// engine directly, but the resolve-and-validate half stays exactly here.

daemon_param_set :: proc(e: ^engine.Engine, id: string, value: int) -> registry.Registry_Error {
	d, found := registry.registry_describe(id)
	if !found {
		return .Unknown_Parameter
	}
	stored, err := registry.registry_validate(d, value)
	if err != .None {
		return err
	}
	engine.engine_set_stored(e, d.index, stored)
	return .None
}

daemon_param_get :: proc(e: ^engine.Engine, id: string) -> (stored: int, ok: bool) {
	d, found := registry.registry_describe(id)
	if !found {
		return 0, false
	}
	return engine.engine_patch_value(e, d.index), true
}
