#+build linux
package standalone_tests

import "core:testing"

import engine "../../src/engine"
import patch "../../src/patch"
import standalone "../../hosts/standalone"

// Channel aftertouch from a hardware port reaches an assignment whose source is
// 53248 (0xD000), exactly as hosts/clap does; the CLAP suite measures the
// resulting pitch against the reference. Before, 0xD0 fell through the switch
// in live_handle_midi and was dropped.
@(test)
test_channel_pressure_reaches_an_aftertouch_assignment :: proc(t: ^testing.T) {
	p: patch.Patch
	for i in 0 ..< patch.PARAMETER_COUNT {p.values[i] = patch.PARAMETERS[i].default}
	p.values[19] = 0
	p.values[86], p.values[87], p.values[50] = 0xD000, 19, 127
	p.values[88] = 0

	live: standalone.Live
	engine.engine_load_patch(&live.eng, p, 48000)
	defer engine.engine_destroy(&live.eng)
	before := live.eng.params.filter_cutoff_hz

	standalone.live_handle_midi(&live, standalone.midi_pack(0xD0, 127, 0))
	testing.expect_value(t, live.eng.ctrl_value[0], f32(1))
	testing.expect(t, live.eng.params.filter_cutoff_hz > before,
		"full aftertouch did not open the filter it is assigned to")

	standalone.live_handle_midi(&live, standalone.midi_pack(0xD0, 0, 0))
	testing.expect_value(t, live.eng.params.filter_cutoff_hz, before)
}
