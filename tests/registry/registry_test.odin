package registry_tests

import "core:testing"

import patch "../../src/patch"
import registry "../../src/registry"

// The registry is checked against the measured src/patch table -- the source it
// overlays -- rather than against its own output, so a test cannot pass by
// agreeing with itself (CONTRIBUTING, "the trap").

@(test)
test_ids_are_unique_and_bind_to_live_indices :: proc(t: ^testing.T) {
	list := registry.registry_list()
	testing.expect(t, len(list) > 0)
	for a, i in list {
		testing.expect(t, a.index >= 0 && a.index < patch.PARAMETER_COUNT)
		for b, j in list {
			if i == j {
				continue
			}
			testing.expect(t, a.id != b.id)
			testing.expect(t, a.index != b.index)
		}
	}
}

@(test)
test_bound_index_matches_the_measured_name :: proc(t: ^testing.T) {
	// The registry's hardcoded indices are pinned to the measured table's own
	// names, so a table reindex cannot silently repoint an id.
	expected := [?]struct {
		id:   string,
		name: string,
	} {
		{"master.volume", "amp gain"},
		{"filter.cutoff", "*filter freq"},
		{"filter.resonance", "*filter resonance"},
	}

	for want in expected {
		d, ok := registry.registry_describe(want.id)
		testing.expect(t, ok)
		testing.expect_value(t, patch.PARAMETERS[d.index].name, want.name)
	}
}

@(test)
test_describe_unknown_returns_false :: proc(t: ^testing.T) {
	_, ok := registry.registry_describe("no.such.parameter")
	testing.expect(t, !ok)
}

@(test)
test_validate_rejects_out_of_range_and_unknown :: proc(t: ^testing.T) {
	d, ok := registry.registry_describe("filter.cutoff")
	testing.expect(t, ok)
	lo, hi, ranged := registry.registry_stored_range(d)
	testing.expect(t, ranged)

	_, err_low := registry.registry_validate(d, lo - 1)
	testing.expect_value(t, err_low, registry.Registry_Error.Out_Of_Range)
	_, err_high := registry.registry_validate(d, hi + 1)
	testing.expect_value(t, err_high, registry.Registry_Error.Out_Of_Range)

	got, err_ok := registry.registry_validate(d, hi)
	testing.expect_value(t, err_ok, registry.Registry_Error.None)
	testing.expect_value(t, got, hi)

	_, err_unknown := registry.registry_validate_id("no.such", 0)
	testing.expect_value(t, err_unknown, registry.Registry_Error.Unknown_Parameter)
}

@(test)
test_normalize_denormalize_round_trip :: proc(t: ^testing.T) {
	// Every position's stored value must survive normalize -> denormalize. The
	// stored value is taken from the patch table's own inverse, so the domain
	// is the one a client actually moves through, not an arbitrary integer.
	for d in registry.registry_list() {
		n := registry.registry_state_count(d)
		testing.expect(t, n > 1)
		for pos in 0 ..< n {
			stored, ok := patch.parameter_stored_at_position(d.index, pos)
			if !ok {
				continue
			}
			back := registry.registry_denormalize(d, registry.registry_normalize(d, stored))
			testing.expect_value(t, back, stored)
		}
	}
}

@(test)
test_format_is_the_measured_display :: proc(t: ^testing.T) {
	// The default of every registered parameter must format to a non-empty
	// display; a blank would mean the format fell through the measured table.
	for d in registry.registry_list() {
		def := registry.registry_default(d)
		testing.expect(t, registry.registry_format(d, def) != "")
	}
}
