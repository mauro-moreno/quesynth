package standalone_tests

import "core:testing"

import engine "../../src/engine"
import patch "../../src/patch"
import registry "../../src/registry"
import standalone "../../hosts/standalone"

// The bridge is checked by reading the value back through the engine, not
// through the registry's own memory: this proves engine_set_stored actually
// persisted the change into the running engine's patch, which is what a
// parameter.set has to do.

@(test)
test_param_bridge_sets_and_gets_through_the_engine :: proc(t: ^testing.T) {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
	}
	e: engine.Engine
	engine.engine_load_patch(&e, p, 48000)
	defer engine.engine_destroy(&e)

	d, ok := registry.registry_describe("filter.cutoff")
	testing.expect(t, ok)
	lo, hi, _ := registry.registry_stored_range(d)
	target := (lo + hi) / 2

	err := standalone.daemon_param_set(&e, "filter.cutoff", target)
	testing.expect_value(t, err, registry.Registry_Error.None)

	got, got_ok := standalone.daemon_param_get(&e, "filter.cutoff")
	testing.expect(t, got_ok)
	testing.expect_value(t, got, target)
}

@(test)
test_param_bridge_rejects_out_of_range_without_moving_the_value :: proc(t: ^testing.T) {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
	}
	e: engine.Engine
	engine.engine_load_patch(&e, p, 48000)
	defer engine.engine_destroy(&e)

	d, _ := registry.registry_describe("filter.cutoff")
	_, hi, _ := registry.registry_stored_range(d)
	before, _ := standalone.daemon_param_get(&e, "filter.cutoff")

	err := standalone.daemon_param_set(&e, "filter.cutoff", hi + 1000)
	testing.expect_value(t, err, registry.Registry_Error.Out_Of_Range)

	after, _ := standalone.daemon_param_get(&e, "filter.cutoff")
	testing.expect_value(t, after, before)
}

@(test)
test_param_bridge_unknown_id :: proc(t: ^testing.T) {
	e: engine.Engine
	err := standalone.daemon_param_set(&e, "no.such.parameter", 0)
	testing.expect_value(t, err, registry.Registry_Error.Unknown_Parameter)
}
