package standalone_tests

import "core:testing"

import engine "../../src/engine"
import patch "../../src/patch"
import registry "../../src/registry"
import standalone "../../hosts/standalone"

// The transaction application path, driven headlessly through live_drain_control
// -- the same procedure the audio callback runs. It proves the two properties a
// batch has to have: it applies all-or-nothing within one drain, and it bumps
// the revision exactly once.

@(private = "file")
fresh_live :: proc() -> ^standalone.Live {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {
		p.values[i] = patch.PARAMETERS[i].default
	}
	live := new(standalone.Live)
	engine.engine_load_patch(&live.eng, p, 48000)
	return live
}

@(test)
test_transaction_applies_together_and_bumps_revision_once :: proc(t: ^testing.T) {
	live := fresh_live()
	defer {
		engine.engine_destroy(&live.eng)
		free(live)
	}

	cutoff, _ := registry.registry_describe("filter.cutoff")
	reso, _ := registry.registry_describe("filter.resonance")

	standalone.param_ring_push(
		&live.ring,
		standalone.Param_Command{kind = .Set, index = i32(cutoff.index), stored = 50},
	)
	standalone.param_ring_push(
		&live.ring,
		standalone.Param_Command{kind = .Set, index = i32(reso.index), stored = 30},
	)
	standalone.param_ring_push(&live.ring, standalone.Param_Command{kind = .Commit})

	applied := standalone.live_drain_control(live)
	testing.expect(t, applied)
	testing.expect_value(t, live.revision, 1) // one bump for the whole batch
	testing.expect_value(t, engine.engine_patch_value(&live.eng, cutoff.index), 50)
	testing.expect_value(t, engine.engine_patch_value(&live.eng, reso.index), 30)
}

@(test)
test_split_transaction_waits_for_its_commit :: proc(t: ^testing.T) {
	live := fresh_live()
	defer {
		engine.engine_destroy(&live.eng)
		free(live)
	}

	cutoff, _ := registry.registry_describe("filter.cutoff")
	before := engine.engine_patch_value(&live.eng, cutoff.index)

	// A Set with no Commit yet: the drain must stage it, apply nothing, and
	// leave the revision and the engine untouched.
	standalone.param_ring_push(
		&live.ring,
		standalone.Param_Command{kind = .Set, index = i32(cutoff.index), stored = 50},
	)
	applied1 := standalone.live_drain_control(live)
	testing.expect(t, !applied1)
	testing.expect_value(t, live.revision, 0)
	testing.expect_value(t, engine.engine_patch_value(&live.eng, cutoff.index), before)

	// The Commit on a later drain applies the staged edit.
	standalone.param_ring_push(&live.ring, standalone.Param_Command{kind = .Commit})
	applied2 := standalone.live_drain_control(live)
	testing.expect(t, applied2)
	testing.expect_value(t, live.revision, 1)
	testing.expect_value(t, engine.engine_patch_value(&live.eng, cutoff.index), 50)
}
