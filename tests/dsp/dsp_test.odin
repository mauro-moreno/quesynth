package dsp_tests

import "core:fmt"
import "core:math"
import "core:testing"

import "../../src/dsp"
import "../../src/engine"
import "../../src/patch"

SR :: f32(48000.0)

// A patch whose every parameter is the plugin's own default. `parse_sy1`
// pre-fills all 99 indices before reading a line, so a file with nothing but a
// header is exactly the default patch -- and unlike the factory bank it is
// checked in, so these tests do not depend on ext/synth1 being present.
default_patch :: proc() -> patch.Patch {
	text := "Synth1 defaults\r\ncolor=default\r\nver=105\r\n"
	p, err := patch.parse_sy1(transmute([]byte)text)
	if err != .None {
		return {}
	}
	return p
}

finite :: proc(v: f32) -> bool {
	if v != v {return false}
	return v > -math.F32_MAX && v < math.F32_MAX
}

@(test)
test_midi_controller_assignments_add_on_one_destination :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[19] = 0
	p.values[50] = 127
	p.values[51] = 127
	p.values[86] = 0xB001
	p.values[87] = 19
	p.values[88] = 0xB002
	p.values[89] = 19

	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	engine.engine_control_change(&e, 1, 64)
	engine.engine_control_change(&e, 2, 64)

	want_patch := p
	want_patch.values[19] = 127
	want := engine.bind_patch(want_patch)
	testing.expect_value(t, e.params.filter_cutoff_hz, want.filter_cutoff_hz)
}

@(test)
test_midi_controller_updates_cached_lfo_shape :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[42] = 0
	p.values[50] = 127
	p.values[86] = 0xB001
	p.values[87] = 42

	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)
	before := e.global_lfo[0].shape
	engine.engine_control_change(&e, 1, 127)

	want_patch := p
	want_patch.values[42], _ = patch.parameter_stored_at_position(42, 5)
	want := engine.bind_patch(want_patch)
	testing.expect(t, e.global_lfo[0].shape != before, "controller did not move the LFO shape")
	testing.expect_value(t, e.global_lfo[0].shape, want.lfo[0].shape)
}

// ---------------------------------------------------------------------------
// Oscillators
// ---------------------------------------------------------------------------

// Every shape has to be audible and bounded. A shape that silently returns zero
// would still render, still write a WAV, and still pass a "no NaN" check, so
// the non-zero half of this assertion is the load-bearing half.
@(test)
test_oscillator_shapes_bounded_and_audible :: proc(t: ^testing.T) {
	for shape in dsp.Waveform {
		o: dsp.Oscillator
		dsp.oscillator_init(&o, 12345)
		dsp.oscillator_set_frequency(&o, 261.6256, SR)

		peak: f32 = 0
		energy: f32 = 0
		for _ in 0 ..< 4800 {
			dsp.oscillator_advance(&o)
			v := dsp.oscillator_value(&o, shape, 0.5)
			testing.expectf(t, finite(v), "%v produced a non-finite sample: %v", shape, v)
			a := abs(v)
			if a > peak {peak = a}
			energy += v * v
		}

		// PolyBLEP overshoots slightly past 1 at the corrected edges, so the
		// bound is the useful one rather than exactly 1.
		testing.expectf(t, peak <= 1.6, "%v exceeded its amplitude bound: peak %v", shape, peak)
		testing.expectf(t, peak > 0.1, "%v was inaudible: peak %v", shape, peak)
		testing.expectf(t, energy > 1.0, "%v carried no energy: %v", shape, energy)
	}
}

// A pulse at the two extremes of its width must not collapse into DC or blow
// up; the binding layer holds width to 0.02..0.98 for this reason and the
// oscillator clamps again for callers that do not.
@(test)
test_oscillator_pulse_width_extremes :: proc(t: ^testing.T) {
	for width in ([]f32{0.0, 0.01, 0.5, 0.99, 1.0}) {
		o: dsp.Oscillator
		dsp.oscillator_init(&o, 999)
		dsp.oscillator_set_frequency(&o, 440.0, SR)
		for _ in 0 ..< 2400 {
			dsp.oscillator_advance(&o)
			v := dsp.oscillator_value(&o, .Pulse, width)
			testing.expectf(t, finite(v), "pulse width %v produced %v", width, v)
			testing.expectf(t, abs(v) <= 2.0, "pulse width %v exceeded bound: %v", width, v)
		}
	}
}

// The frequency setter must survive what modulation actually sends it.
@(test)
test_oscillator_rejects_absurd_frequencies :: proc(t: ^testing.T) {
	o: dsp.Oscillator
	dsp.oscillator_init(&o, 7)

	for hz in ([]f32{0.0, -440.0, 1.0e12, SR, SR * 4.0}) {
		dsp.oscillator_set_frequency(&o, hz, SR)
		testing.expectf(t, finite(o.increment), "increment went non-finite for %v Hz", hz)
		testing.expectf(
			t,
			o.increment >= 0 && o.increment < 0.5,
			"increment %v out of range for %v Hz",
			o.increment,
			hz,
		)
		for _ in 0 ..< 128 {
			dsp.oscillator_advance(&o)
			testing.expect(t, finite(dsp.oscillator_value(&o, .Saw, 0.5)))
		}
	}
}

// Hard sync must land the slave inside its first sample, not somewhere else.
@(test)
test_oscillator_sync_resets_phase :: proc(t: ^testing.T) {
	o: dsp.Oscillator
	dsp.oscillator_init(&o, 3)
	dsp.oscillator_set_frequency(&o, 1000.0, SR)
	dsp.oscillator_set_phase(&o, 0.7)

	dsp.oscillator_sync(&o, 0.0)
	testing.expect_value(t, o.phase, 0.0)

	dsp.oscillator_sync(&o, 1.0)
	testing.expectf(t, o.phase == o.increment, "sync at end of sample gave %v", o.phase)
	testing.expect(t, o.phase >= 0 && o.phase < 1.0)
}

// ---------------------------------------------------------------------------
// Filter
// ---------------------------------------------------------------------------

// The contract for this slice names four responses at two slopes. Every
// combination is driven at the extremes of cutoff and damping with full-scale
// input; the filter is the only feedback path in the engine, so a divergence
// here is the one that poisons a whole render.
//
// The damping is swept directly rather than through the 0..1 resonance knob,
// because the engine no longer uses that knob's linear law: `voice_process`
// takes its damping from the measured table in `filter_resonance_table.odin`,
// which reaches dsp.MIN_DAMPING. Testing `filter_set` alone left the sharpest
// two decades of the engine's actual range unexercised.
//
// What is asserted is the property the old version meant to assert and did not.
// It required `peak < 40.0`, which is a statement about gain, not about
// stability -- and a wrong one, since a Q of 1000 is entitled to a gain of 1000
// while staying perfectly bounded. Reading it as a stability limit is what kept
// the resonance curve pinned at a fourteenth of the reference's. A filter that
// diverges is one whose output keeps growing; a filter that merely resonates
// rings up to a plateau and stays there. So the test compares the peak of the
// second half of a long run against the first half's, which separates the two,
// and keeps an absolute ceiling only as a backstop at the gain the topology can
// actually reach.
@(test)
test_filter_stable_across_modes_and_extremes :: proc(t: ^testing.T) {
	cutoffs := []f32{1.0, 20.0, 1000.0, 20000.0, SR, SR * 10.0}
	dampings := []f32{2.0, 1.0, 0.25, 0.05, 0.01, dsp.MIN_DAMPING}

	// A two-pole section's gain at resonance is 1/k, and the 24 dB path shares
	// its damping between two sections so the pair reaches the same. Twice that
	// is a backstop with room for the transient overshoot of a filter ringing up,
	// not a target anything is expected to approach.
	ceiling := 2.0 / dsp.MIN_DAMPING

	HALF :: 48000

	for mode in dsp.Filter_Mode {
		for slope in dsp.Filter_Slope {
			for cutoff in cutoffs {
				for damping in dampings {
					f: dsp.Filter
					dsp.filter_init(&f)
					dsp.filter_set_damping(&f, cutoff, damping, SR, slope)

					rng: dsp.Rng
					dsp.rng_init(&rng, 4242)

					early: f32 = 0
					late: f32 = 0
					for i in 0 ..< 2 * HALF {
						x := dsp.rng_next_bipolar(&rng)
						y := dsp.filter_process(&f, x, mode, slope, 0.0)
						testing.expectf(
							t,
							finite(y),
							"%v/%v at cutoff %v damping %v went non-finite",
							mode,
							slope,
							cutoff,
							damping,
						)
						if i < HALF {
							if abs(y) > early {early = abs(y)}
						} else {
							if abs(y) > late {late = abs(y)}
						}
					}

					// Ringing up is allowed; still climbing after a second is not.
					testing.expectf(
						t,
						late <= early * 1.5 + 1.0e-6,
						"%v/%v at cutoff %v damping %v is still growing: %v then %v",
						mode,
						slope,
						cutoff,
						damping,
						early,
						late,
					)
					testing.expectf(
						t,
						max(early, late) < ceiling,
						"%v/%v at cutoff %v damping %v reached %v, past the %v backstop",
						mode,
						slope,
						cutoff,
						damping,
						max(early, late),
						ceiling,
					)
				}
			}
		}
	}
}

// The two measured resonance curves have to be usable as damping without any
// further checking at the use site, which means bounded and monotonic.
//
// Monotonic is the audible one: `filter_damping` indexes these directly from the
// knob, so a single entry out of order is a resonance control that goes
// backwards at one setting.
@(test)
test_resonance_tables_are_bounded_and_monotonic :: proc(t: ^testing.T) {
	tables := [][]f32{engine.FILTER_DAMPING[:], engine.FILTER_DAMPING_24[:]}
	for table, which in tables {
		testing.expect_value(t, len(table), engine.FILTER_RESONANCE_TABLE_SIZE)
		for k, i in table {
			testing.expectf(
				t,
				k >= dsp.MIN_DAMPING && k <= 2.0,
				"table %v entry %v is %v, outside [%v, 2.0]",
				which,
				i,
				k,
				dsp.MIN_DAMPING,
			)
			if i > 0 {
				testing.expectf(
					t,
					k <= table[i - 1],
					"table %v goes backwards at %v: %v then %v",
					which,
					i,
					table[i - 1],
					k,
				)
			}
		}
		// The knob has to actually do something across its range.
		testing.expectf(
			t,
			table[0] > table[len(table) - 1] * 100.0,
			"table %v spans only %v to %v",
			which,
			table[0],
			table[len(table) - 1],
		)
	}
}

// Saturation is a nonlinearity in the signal path, so it gets its own sweep.
// The measured transfer is bounded, but it can receive an over-unity unison
// sum and must remain finite at every setting.
@(test)
test_filter_saturation_bounded :: proc(t: ^testing.T) {
	for drive in ([]f32{0.0, 2.321027, 16.879008}) {
		f: dsp.Filter
		dsp.filter_init(&f)
		dsp.filter_set(&f, 800.0, 1.0, SR)

		for i in 0 ..< 9600 {
			// Deliberately over unity: a unison stack summing in phase does
			// exactly this.
			x := 4.0 * math.sin(f32(i) * 0.05)
			y := dsp.filter_process(&f, x, .Low_Pass, .Slope_24, drive)
			testing.expectf(t, finite(y), "saturation drive %v went non-finite", drive)
			testing.expectf(t, abs(y) < 40.0, "saturation drive %v reached %v", drive, y)
		}
	}
}

@(test)
test_filter_saturation_is_peak_normalised :: proc(t: ^testing.T) {
	for drive in ([]f32{0.110344, 2.321027, 16.879008}) {
		testing.expectf(t, abs(dsp.filter_saturate(1.0, drive) - 1.0) < 0.00001,
			"positive peak moved at drive %v", drive)
		testing.expectf(t, abs(dsp.filter_saturate(-1.0, drive) + 1.0) < 0.00001,
			"negative peak moved at drive %v", drive)
	}
	testing.expect_value(t, dsp.filter_saturate(0.25, 0.0), f32(0.25))
	testing.expect(t, dsp.filter_saturate(0.01, 16.879008) > 0.1,
		"the measured high-drive curve should amplify small signals")
}

// The reference's open-filter transfer is the same in both slopes. Applying the
// saturation after each section would compound it in the 24 dB cascade, so keep
// a direct guard on the single, completed-filter placement.
@(test)
test_filter_saturation_is_not_compounded_by_slope :: proc(t: ^testing.T) {
	f12, f24: dsp.Filter
	dsp.filter_init(&f12)
	dsp.filter_init(&f24)
	dsp.filter_set_damping(&f12, 12000.0, 2.0, SR, .Slope_12)
	dsp.filter_set_damping(&f24, 12000.0, 2.0, SR, .Slope_24)

	difference, signal: f64
	for i in 0 ..< 12000 {
		x := 0.2 * math.sin(f32(i) * 0.02)
		y12 := dsp.filter_process(&f12, x, .Low_Pass, .Slope_12, 2.321027)
		y24 := dsp.filter_process(&f24, x, .Low_Pass, .Slope_24, 2.321027)
		if i >= 4000 {
			d := f64(y12 - y24)
			difference += d * d
			signal += f64(y12) * f64(y12)
		}
	}
	testing.expectf(t, difference / signal < 0.0001,
		"open 24 dB response compounded saturation: relative error %v", difference / signal)
}

@(test)
test_filter_saturation_binding_uses_measured_knots :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[23] = 109
	p.present[23] = true
	testing.expectf(t, abs(engine.bind_patch(p).filter_saturation_drive - 9.634074) < 0.00001,
		"stored 109 did not bind to its measured drive")
	p.values[23] = 122
	testing.expectf(t, abs(engine.bind_patch(p).filter_saturation_drive - 15.213064) < 0.00001,
		"stored 122 did not bind to its measured drive")
}

@(test)
test_24db_cutoff_binding_tracks_resonance_surface :: proc(t: ^testing.T) {
	p := default_patch()
	for index in ([]int{14, 19, 20, 21}) {
		p.present[index] = true
	}
	p.values[14] = 1 // 24 dB low pass
	p.values[19] = 64
	p.values[21] = 20

	p.values[20] = 0
	low := engine.bind_patch(p)
	low_expected := engine.FILTER_CUTOFF_HZ_24_LOW_RESONANCE[64] * f32(1.255)
	testing.expectf(t, abs(low.filter_cutoff_hz - low_expected) < 0.001,
		"resonance-0 cutoff did not use the low-Q surface: %v", low.filter_cutoff_hz)
	testing.expectf(t, abs(engine.filter_cutoff_at_state(&low, 0) - engine.FILTER_CUTOFF_HZ_24_LOW_RESONANCE[0]) < 0.001,
		"resonance-0 floor did not follow the low-Q surface")
	testing.expectf(t, abs(low.filter_env_cutoff_states - f32(20 - 63) * 2.0) < 0.001,
		"filter envelope amount did not resolve to two cutoff states per step")
	testing.expect_value(t, low.filter_cutoff_state, f32(64))
	testing.expect_value(t, low.filter_cutoff_surface_blend, f32(0))
	testing.expect_value(t, low.filter_cutoff_topology_scale, f32(1.255))

	p.values[20] = 4
	mid := engine.bind_patch(p)
	expected_mid := f32(1.259) * engine.FILTER_CUTOFF_HZ_24_LOW_RESONANCE[64] *
		math.pow(engine.FILTER_CUTOFF_HZ_24[64] / engine.FILTER_CUTOFF_HZ_24_LOW_RESONANCE[64], f32(0.2405))
	testing.expectf(t, abs(mid.filter_cutoff_hz - expected_mid) < 0.001,
		"resonance-4 cutoff did not use the measured log blend: %v vs %v", mid.filter_cutoff_hz, expected_mid)

	p.values[20] = 107
	high := engine.bind_patch(p)
	testing.expectf(t, abs(high.filter_cutoff_hz - engine.FILTER_CUTOFF_HZ_24[64]) < 0.001,
		"resonance-107 cutoff did not reach the high-Q surface: %v", high.filter_cutoff_hz)
	testing.expectf(t, abs(engine.filter_cutoff_at_state(&high, f32(engine.FILTER_TABLE_SIZE - 1)) - engine.FILTER_CUTOFF_HZ_24[engine.FILTER_TABLE_SIZE - 1]) < 0.001,
		"resonance-107 ceiling did not follow the high-Q surface")

	p.values[20] = 127
	at_top := engine.bind_patch(p)
	testing.expectf(t, abs(at_top.filter_cutoff_hz - high.filter_cutoff_hz) < 0.001,
		"cutoff surface moved above its measured resonance-107 endpoint")
}

// A non-finite input must not be able to lodge itself in the filter state, or
// one bad sample would silence the rest of the render.
@(test)
test_filter_recovers_from_non_finite_input :: proc(t: ^testing.T) {
	f: dsp.Filter
	dsp.filter_init(&f)
	dsp.filter_set(&f, 2000.0, 0.8, SR)

	poison := math.inf_f32(1)
	dsp.filter_process(&f, poison, .Low_Pass, .Slope_24, 0.0)
	dsp.filter_process(&f, math.nan_f32(), .Low_Pass, .Slope_24, 0.0)

	recovered := false
	for i in 0 ..< 4800 {
		y := dsp.filter_process(&f, math.sin(f32(i) * 0.02), .Low_Pass, .Slope_24, 0.0)
		testing.expect(t, finite(y))
		if abs(y) > 0.01 {
			recovered = true
		}
	}
	testing.expect(t, recovered, "filter never resumed passing signal after a poisoned sample")
}

// ---------------------------------------------------------------------------
// Envelopes
// ---------------------------------------------------------------------------

// The envelope has to actually traverse its states: reach 1.0, settle on the
// sustain level, and reach exactly zero after a release. The last one is not
// cosmetic -- `voice_is_finished` frees a voice on it, so an envelope that
// never terminates is a polyphony leak.
@(test)
test_envelope_reaches_sustain_and_completes_release :: proc(t: ^testing.T) {
	e: dsp.Envelope
	dsp.envelope_set(&e, 0.01, 0.05, 0.5, 0.05, SR)
	dsp.envelope_gate_on(&e, true)

	peak: f32 = 0
	for _ in 0 ..< int(0.02 * SR) {
		v := dsp.envelope_process(&e)
		if v > peak {peak = v}
	}
	testing.expectf(t, peak >= 0.999, "attack never reached full scale: %v", peak)

	for _ in 0 ..< int(0.5 * SR) {
		dsp.envelope_process(&e)
	}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Sustain)
	testing.expectf(t, abs(e.value - 0.5) < 1.0e-3, "sustain settled at %v, wanted 0.5", e.value)

	dsp.envelope_gate_off(&e)
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Release)

	for _ in 0 ..< int(2.0 * SR) {
		dsp.envelope_process(&e)
	}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Idle)
	testing.expect_value(t, e.value, 0.0)
	testing.expect(t, !dsp.envelope_is_active(&e))
}

// A zero attack still has to rise rather than step, and a zero release still
// has to terminate.
@(test)
test_envelope_degenerate_times :: proc(t: ^testing.T) {
	e: dsp.Envelope
	dsp.envelope_set(&e, 0, 0, 1.0, 0, SR)
	dsp.envelope_gate_on(&e, true)

	first := dsp.envelope_process(&e)
	testing.expect(t, finite(first))
	testing.expectf(t, first > 0, "zero attack produced silence")

	dsp.envelope_gate_off(&e)
	for _ in 0 ..< int(0.5 * SR) {
		dsp.envelope_process(&e)
	}
	testing.expect_value(t, e.stage, dsp.Envelope_Stage.Idle)
}

// An envelope that never got a gate must stay silent and inactive.
@(test)
test_envelope_idle_is_silent :: proc(t: ^testing.T) {
	e: dsp.Envelope
	dsp.envelope_set(&e, 0.1, 0.1, 0.8, 0.1, SR)
	for _ in 0 ..< 1000 {
		testing.expect_value(t, dsp.envelope_process(&e), 0.0)
	}
	testing.expect(t, !dsp.envelope_is_active(&e))
}

// ---------------------------------------------------------------------------
// LFOs
// ---------------------------------------------------------------------------

// The [-1, 1] bound is a contract every caller in voice.odin relies on: each
// destination multiplies the LFO by a depth in engine units and would have to
// re-clamp otherwise.
@(test)
test_lfo_bounded_and_moving :: proc(t: ^testing.T) {
	for shape in dsp.Lfo_Waveform {
		for rate in ([]f32{0.05, 5.0, 40.0, SR}) {
			l: dsp.Lfo
			dsp.lfo_init(&l, 8181)
			l.shape = shape
			dsp.lfo_set_frequency(&l, rate, SR)

			lo: f32 = 2.0
			hi: f32 = -2.0
			for _ in 0 ..< 48000 {
				v := dsp.lfo_process(&l)
				testing.expectf(t, finite(v), "%v at %v Hz went non-finite", shape, rate)
				testing.expectf(
					t,
					v >= -1.0 && v <= 1.0,
					"%v at %v Hz left [-1,1]: %v",
					shape,
					rate,
					v,
				)
				if v < lo {lo = v}
				if v > hi {hi = v}
			}
			// Variation is only required where at least one full cycle fits in
			// the one-second window. At 0.05 Hz a cycle is twenty seconds, so a
			// square correctly holds one level throughout and a sample & hold
			// correctly holds one value; asserting movement there would be
			// testing the window, not the oscillator.
			if rate >= 1.0 {
				testing.expectf(t, hi - lo > 0.1, "%v at %v Hz was static", shape, rate)
			}
		}
	}
}

// Key sync restarts the phase; without that, parameters 68 and 70 would do
// nothing observable.
@(test)
test_lfo_retrigger_resets_phase :: proc(t: ^testing.T) {
	l: dsp.Lfo
	dsp.lfo_init(&l, 5)
	l.shape = .Sine
	dsp.lfo_set_frequency(&l, 4.0, SR)
	for _ in 0 ..< 1000 {
		dsp.lfo_process(&l)
	}
	testing.expect(t, l.phase > 0)
	dsp.lfo_retrigger(&l)
	testing.expect_value(t, l.phase, 0.0)
}

// ---------------------------------------------------------------------------
// Noise
// ---------------------------------------------------------------------------

// The generator must not stall on its fixed point and must be reproducible from
// its seed, which is what makes a render deterministic.
@(test)
test_rng_bounded_and_reproducible :: proc(t: ^testing.T) {
	a: dsp.Rng
	b: dsp.Rng
	dsp.rng_init(&a, 0) // zero is xorshift32's fixed point; must be replaced
	dsp.rng_init(&b, 0)

	sum: f32 = 0
	for _ in 0 ..< 10000 {
		x := dsp.rng_next_bipolar(&a)
		y := dsp.rng_next_bipolar(&b)
		testing.expect_value(t, x, y)
		testing.expect(t, x >= -1.0 && x < 1.0)
		sum += x
	}
	testing.expect(t, abs(sum) < 500.0, "noise showed a large DC bias")
}

// ---------------------------------------------------------------------------
// Patch binding
// ---------------------------------------------------------------------------

// Parameters 42 and 47 hold their six states in display order 0, 1, 5, 2, 3, 4,
// and the shapes follow the *position*, not the out-of-order display.
//
// This test used to assert the opposite, on the reasoning that a display running
// out of order must be carrying an identity the position had lost. It is not, and
// `s1probe lfoshape` settles it by measurement: the LFO is pointed at the stereo
// position, its series folded into one cycle at a period taken from the series'
// own autocorrelation, and matched against saw, triangle, sine, square and the two
// random states. Reading the display identifier bound four of the six states to
// the wrong waveform -- both random shapes and the square among them.
//
// Kept as a regression test with its expectations inverted rather than deleted,
// because the trap it was written for is real: the two readings genuinely differ
// for four of six states, so whichever one is wrong fails loudly here.
@(test)
test_lfo_shape_follows_state_position :: proc(t: ^testing.T) {
	// Stored 2 resolves to position 3, whose display reads "2". The two readings
	// disagree here, which is exactly why this state is worth pinning.
	testing.expect_value(t, engine.resolved_position(42, 2), 3)
	testing.expect_value(t, engine.resolved_display_id(42, 2), 2)

	// Indexed by the stored value a patch actually contains. Read down the list
	// and it is the readme's own order permuted by the display table above --
	// which is what "the shapes are in position order" looks like from here.
	expected := []dsp.Lfo_Waveform {
		.Saw,
		.Triangle,
		.Square,
		.Sample_Hold,
		.Random_Smooth,
		.Sine,
	}
	for want, stored in expected {
		p := default_patch()
		p.values[42] = stored
		p.values[47] = stored
		bound := engine.bind_patch(p)
		testing.expectf(
			t,
			bound.lfo[0].shape == want,
			"lfo1 type %v bound to %v, wanted %v",
			stored,
			bound.lfo[0].shape,
			want,
		)
		testing.expect_value(t, bound.lfo[1].shape, want)
	}
}

// The five measured filter states map onto the four documented responses plus
// LPDL, which this slice binds to the 24 dB low pass.
@(test)
test_filter_type_binding :: proc(t: ^testing.T) {
	// Measured with `s1probe filterprobe`, which drives noise through each state
	// and fits the response. State 3 used to be bound as a 24 dB high pass, on
	// the English manual's word; it is a band pass, as the Japanese manual for
	// the same version says and as the measured pass band -- bounded at both
	// ends, and tracking the cutoff knob -- confirms.
	modes := []dsp.Filter_Mode{.Low_Pass, .Low_Pass, .High_Pass, .Band_Pass, .Low_Pass}
	slopes := []dsp.Filter_Slope{.Slope_12, .Slope_24, .Slope_12, .Slope_12, .Slope_24}

	for stored in 0 ..< 5 {
		p := default_patch()
		p.values[14] = stored
		bound := engine.bind_patch(p)
		testing.expectf(
			t,
			bound.filter_mode == modes[stored],
			"filter type %v mode %v",
			stored,
			bound.filter_mode,
		)
		testing.expect_value(t, bound.filter_slope, slopes[stored])
	}
}

// Parameter 82 has three distinct states. It used to be reduced to a boolean,
// which made state 2 silently fall back to normal stereo even though the
// reference names and renders it as ping-pong.
@(test)
test_delay_type_binding_preserves_all_three_modes :: proc(t: ^testing.T) {
	want := []dsp.Delay_Mode{.Stereo, .Cross, .Ping_Pong}
	for mode, stored in want {
		p := default_patch()
		p.values[82] = stored
		bound := engine.bind_patch(p)
		testing.expectf(
			t,
			bound.delay_mode == mode,
			"delay type %v bound to %v, wanted %v",
			stored,
			bound.delay_mode,
			mode,
		)
	}
}

@(test)
test_delay_feedback_binding_reaches_measured_unity :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[36] = 100
	testing.expectf(
		t,
		abs(engine.bind_patch(p).delay_feedback - 100.0 / 127.0) < 0.000001,
		"stored 100 did not bind to its measured repeat ratio",
	)
	p.values[36] = 127
	testing.expect_value(t, engine.bind_patch(p).delay_feedback, 1.0)
}

// Signed displays carry real units and must survive the trip. The three checked
// here are the ones whose display text needs a sign, a suffix or a separator to
// be parsed at all.
@(test)
test_signed_and_suffixed_displays_bind_to_units :: proc(t: ^testing.T) {
	// Parameter 2 displays "-60".."+60" semitones.
	p := default_patch()
	p.values[2] = 0
	testing.expect_value(t, engine.bind_patch(p).osc2_semitones, -60.0)
	p.values[2] = 127
	testing.expect_value(t, engine.bind_patch(p).osc2_semitones, 60.0)

	// Parameter 3 displays "-62 cent".."+61 cent"; the suffix must not defeat
	// the parse.
	p = default_patch()
	p.values[3] = 0
	testing.expect_value(t, engine.bind_patch(p).osc2_cents, -62.0)

	// Parameter 5 displays "100 : 0".."0 : 100" as oscillator 1's share, so the
	// stored mix is its complement.
	p = default_patch()
	p.values[5] = 0
	testing.expect_value(t, engine.bind_patch(p).osc_mix, 0.0)
	p.values[5] = 127
	testing.expect_value(t, engine.bind_patch(p).osc_mix, 1.0)

	// Parameter 40 displays "0".."24" semitones of bend range.
	p = default_patch()
	p.values[40] = 24
	testing.expect_value(t, engine.bind_patch(p).pitch_bend_range, 24.0)
}

// `s1probe mixprobe --values 0,32,64,96,127` anchors each curve at both
// endpoints and reads the reference's separate oscillator fundamentals. The
// oscillator 2 gains are 0.2520, 0.5040 and 0.7560; the tolerance excludes the
// display's rounded 0.25, 0.50 and 0.76.
@(test)
test_oscillator_mix_uses_the_reference_stored_ratio :: proc(t: ^testing.T) {
	for reading in ([]struct {stored: int, gain: f32} {
		{32, 0.2520},
		{64, 0.5040},
		{96, 0.7560},
	}) {
		p := default_patch()
		p.values[5] = reading.stored
		got := engine.bind_patch(p).osc_mix
		testing.expectf(t, abs(got - reading.gain) < 0.00015,
			"stored mix %d bound to %.6f; the reference reads %.4f",
			reading.stored, got, reading.gain)
	}
}

// Parameter 21's own reference default, stored 128, selects no state in a
// 128-state table. The plugin walks off the grid for it; an engine parameter
// has to stay bounded, so the binding clamps. This is the case that makes the
// out-of-range path in `resolved_position` load-bearing rather than defensive.
@(test)
test_out_of_range_stored_value_stays_bounded :: proc(t: ^testing.T) {
	p := default_patch()
	testing.expect_value(t, p.values[21], 128)
	bound := engine.bind_patch(p)
	// The amount is a signed state excursion. The top endpoint is 64 amount
	// steps above centre, at two cutoff states per step.
	limit := f32(engine.FILTER_TABLE_SIZE)
	testing.expectf(
		t,
		bound.filter_env_cutoff_states >= -limit && bound.filter_env_cutoff_states <= limit,
		"filter env amount left its range: %v cutoff states",
		bound.filter_env_cutoff_states,
	)
	// Stored 128 is out of range at the top, so it resolves to the top state and
	// the envelope opens the filter rather than closing it.
	testing.expect(t, bound.filter_env_cutoff_states > 0, "the top state should open the filter")

	// A negative stored value must clamp at the bottom, not read as a maximum.
	p.values[21] = -999
	testing.expect_value(t, engine.resolved_position(21, -999), 0)
}

// Parameter 73 off must collapse the unison count to one regardless of what 93
// holds, because every voice-layout calculation keys off the count alone.
@(test)
test_unison_switch_collapses_voice_count :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[93] = 8
	p.values[73] = 0
	testing.expect_value(t, engine.bind_patch(p).unison_voices, 1)
	p.values[73] = 1
	testing.expect_value(t, engine.bind_patch(p).unison_voices, 8)
}

// Outer-layer half-spans read off the reference by
//
//     s1probe unisonprobe --values 6,8,12,16,20,22,26,32,40,48,56,64,72,80,88,96,104,112,120,127 --note 84
//     s1probe unisonprobe --values 2,3,4,5,6,8,10,12,16,20,24,32,48,64,80,96 --note 108
//
// Both sweeps print the four signed layer cents and check them against the
// reference's own -1/2, -1/6, +1/6, +1/2 layout before reporting a half-span,
// so a row the transform could not separate cannot become a number here. The
// two notes agree to 0.13% where they overlap. The bound allows 0.3% plus a
// small floor for rounded low-span readings, yet stays tight enough to reject
// both prior laws. At the factory default of stored 22 the reference reads
// 3.239 cents; the quadratic before this read 1.500 and the linear before that
// 4.331.
@(test)
test_unison_detune_matches_the_reference_cents_sweep :: proc(t: ^testing.T) {
	for reading in ([][2]f32{
		{2, 0.251},
		{4, 0.509},
		{8, 1.051},
		{16, 2.244},
		{22, 3.239},
		{32, 5.129},
		{64, 13.614},
		{96, 27.662},
		{127, 49.999},
	}) {
		stored, reference := reading[0], reading[1]
		bound := 0.003 * reference + 0.001
		p := default_patch()
		p.values[75] = int(stored)
		full_span := engine.bind_patch(p).unison_detune
		// The layout halves the span, so the outer layers sit at +/- half of it.
		for outer in ([]f32{-0.5 * full_span, 0.5 * full_span}) {
			expected := outer < 0 ? -reference : reference
			testing.expectf(t, abs(outer - expected) < bound,
				"stored %.0f outer layer %.4f cents; reference reads %+.3f (bound %.4f)",
				stored, outer, expected, bound)
		}
	}
}

// Parameter 76 is an OSC1-internal construction, measured with outer unison
// disabled. The nine signed frequencies at stored 20 and 127 come from Synth1
// itself; they are not derived from the engine helper under test. Keeping every
// sign rejects the former parameter-93-dependent symmetric spread, which gives
// one centre component when the outer voice count is one.
@(test)
test_osc1_inner_detune_matches_the_signed_reference_components :: proc(t: ^testing.T) {
	for sweep in ([]struct {
		stored: int,
		reference: [9]f32,
		bound: f32,
	}{
		{20, {-22.049, -15.761, -9.448, -3.146, -0.008, 3.149, 9.466, 15.730, 22.055}, 0.03},
		{127, {-140.012, -99.993, -59.987, -20.013, -0.010, 19.990, 60.007, 99.993, 140.007}, 0.03},
	}) {
		p := default_patch()
		p.values[73] = 0
		p.values[93] = 1
		p.values[76] = sweep.stored
		step := engine.bind_patch(p).osc1_detune
		for expected, i in sweep.reference {
			got := engine.osc1_component_cents(i, step)
			testing.expectf(t, abs(got - expected) < sweep.bound,
				"stored %d component %d read %+.3f cents; reference reads %+.3f",
				sweep.stored, i, got, expected)
		}
	}
}

// Exercise the public engine path with one outer voice. The old symmetric
// guess made parameter 76 inert here because its only outer spread was zero.
@(test)
test_osc1_inner_detune_renders_nine_components_with_unison_off :: proc(t: ^testing.T) {
	N :: 48000
	single := make([]f32, N)
	defer delete(single)
	inner := make([]f32, N)
	defer delete(inner)
	p := phase_probe_patch()
	p.values[0] = 0 // sine OSC1: each projected frequency is unambiguous
	p.values[5] = 0 // OSC1 only
	p.values[73] = 0
	p.values[93] = 1
	p.values[76] = 0
	render_phase_patch(p, single)
	p.values[76] = 127
	render_phase_patch(p, inner)

	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)
	single_magnitude, _ := fundamental_phase(single, f0, f64(SR))
	testing.expect(t, single_magnitude > 0.005, "the p76=0 singleton was silent")
	for cents, i in ([9]f64{-140, -100, -60, -20, 0, 20, 60, 100, 140}) {
		hz := f0 * math.pow(2.0, cents / 1200.0)
		magnitude, _ := fundamental_phase(inner, hz, f64(SR))
		ratio := magnitude / single_magnitude
		testing.expectf(t, abs(ratio - 0.3) < 0.02,
			"component %d at %+.0f cents was %.4f of the singleton; reference reads 0.3",
			i, cents, ratio)
	}
}

// The external projection reads signed, non-symmetric free phase sets. An RMS
// or null depth could accept their mirrors, so inspect the note-on state and pin
// each sign. Engaging parameter 91 is a separate measured state: it aligns all
// nine components rather than retaining either free set.
@(test)
test_osc1_inner_components_use_signed_free_phases_and_fixed_alignment :: proc(t: ^testing.T) {
	free_osc1 := [9]f32{0.7485, 0.8978, 0.4838, 0.8087, 0, 0.1927, 0.5867, 0.3539, 0.8215}
	free_sub := [9]f32{0.3728, 0.4481, 0.2350, 0.3992, 0, 0.0920, 0.2871, 0.1751, 0.4059}
	for fixed in ([]bool{false, true}) {
		p := phase_probe_patch()
		p.values[73] = 0
		p.values[93] = 1
		p.values[76] = 127
		p.values[91] = fixed ? 1 : 0
		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		engine.engine_note_on(&e, 60, 1.0)
		u := &e.voices[0].unison[0]
		osc1_centre := engine.osc1_component(u, 4).phase
		sub_centre := engine.sub_component(u, 4).phase
		for component in 0 ..< 9 {
			osc1 := engine.osc1_component(u, component).phase - osc1_centre
			sub := engine.sub_component(u, component).phase - sub_centre
			for osc1 < 0 {osc1 += 1}
			for sub < 0 {sub += 1}
			want_osc1 := fixed ? f32(0) : free_osc1[component]
			want_sub := fixed ? f32(0) : free_sub[component]
			testing.expectf(t, abs(osc1 - want_osc1) < 0.00011,
				"fixed=%v OSC1 component %d phase %.4f; reference reads %.4f",
				fixed, component, osc1, want_osc1)
			testing.expectf(t, abs(sub - want_sub) < 0.00011,
				"fixed=%v sub component %d phase %.4f; reference reads %.4f",
				fixed, component, sub, want_sub)
		}
		engine.engine_destroy(&e)
	}
}

// The sub was isolated in the reference at -1 octave. Each of its nine signed
// components is 0.3 of the p76=0 centre; a 1/9 trim would fail this render test.
@(test)
test_parameter_76_sub_components_keep_the_measured_signed_gain :: proc(t: ^testing.T) {
	N :: 192000 // four seconds resolves the closest +/-20-cent sub pair
	single := make([]f32, N)
	defer delete(single)
	inner := make([]f32, N)
	defer delete(inner)
	p := phase_probe_patch()
	p.values[0] = 0
	p.values[5] = 0
	p.values[73] = 0
	p.values[93] = 1
	p.values[95] = 110
	p.values[96] = 0
	p.values[97] = 1
	p.values[76] = 0
	render_phase_patch(p, single)
	p.values[76] = 127
	render_phase_patch(p, inner)

	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0) * 0.5
	single_magnitude, _ := fundamental_phase(single, f0, f64(SR))
	testing.expect(t, single_magnitude > 0.005, "the isolated sub singleton was silent")
	for cents, i in ([9]f64{-140, -100, -60, -20, 0, 20, 60, 100, 140}) {
		hz := f0 * math.pow(2.0, cents / 1200.0)
		magnitude, _ := fundamental_phase(inner, hz, f64(SR))
		ratio := magnitude / single_magnitude
		testing.expectf(t, abs(ratio - 0.3) < 0.02,
			"sub component %d at %+.0f cents was %.4f of the singleton; reference reads 0.3",
			i, cents, ratio)
	}
}

// `s1probe` finds two pitch groups at every non-zero parameter-85 setting:
// even layers stay on the note and odd layers move by the displayed interval.
// This signed wiring test prevents the old global transpose from returning.
@(test)
test_unison_pitch_alternates_the_reference_voice_groups :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.unison_layer_pitch(0, 12), 0.0)
	testing.expect_value(t, engine.unison_layer_pitch(1, 12), 12.0)
	testing.expect_value(t, engine.unison_layer_pitch(2, -12), 0.0)
	testing.expect_value(t, engine.unison_layer_pitch(3, -12), -12.0)
}

// The signed per-layer start phases, in turns, from
//
//     s1probe unisonprobe --values 32,64,96,127 --note 84
//
// which reads them twice by different constructions. The digits asserted here
// are the cumulative projection with oscillator phase fixed and parameter 92 at
// its top, which resolves about 0.0004 turns. The same command's detuned rows
// project the four layers simultaneously and against the lowest of them, with
// no subtraction and with parameter 91 at zero, and read layers 1..3 at +0.174,
// +0.988 and +0.166 -- the second block below, at that method's own coarser
// resolution.
//
// They are kept signed rather than reduced to magnitudes: cancellation is an
// even function of an offset, so a magnitude cannot tell a layout from its
// mirror. The second reading is also the only one that pins a phase to a detune
// slot, since any permutation of one phase set has the same stack RMS.
@(test)
test_unison_phase_spread_uses_signed_reference_offsets :: proc(t: ^testing.T) {
	for reading in ([][2]f32{
		{1, 0.174683},
		{2, 0.988525},
		{3, 0.166234},
		{4, 0.875973},
		{5, 0.779656},
		{6, 0.375866},
		{7, 0.837611},
	}) {
		got := engine.unison_phase_offset(int(reading[0]), 1.0)
		testing.expectf(t, abs(got - reading[1]) < 0.0004,
			"layer %.0f phase factor %.6f; reference reads %.6f",
			reading[0], got, reading[1])
	}
	// The independent detuned reading, at its own resolution.
	for reading in ([][2]f32{
		{1, 0.174},
		{2, 0.988},
		{3, 0.166},
	}) {
		got := engine.unison_phase_offset(int(reading[0]), 1.0)
		testing.expectf(t, abs(got - reading[1]) < 0.007,
			"layer %.0f phase factor %.6f; the detuned projection reads %.3f",
			reading[0], got, reading[1])
	}
	// The patch binding scales those offsets rather than replacing them.
	p := default_patch()
	p.values[92] = 64
	got := engine.unison_phase_offset(1, engine.bind_patch(p).unison_phase_shift)
	testing.expectf(t, abs(got - 0.088276) < 0.0004,
		"stored 64 phase offset %.6f; reference reads %.6f", got, 0.088276)
}

// The reference's layer amplitudes are summed at unity. This is deliberately
// a signed external law, not a trim chosen to close one corpus row.
@(test)
test_unison_stack_has_no_count_trim :: proc(t: ^testing.T) {
	for count in ([]int{1, 2, 4, 8}) {
		testing.expect_value(t, engine.unison_stack_scale(count), 1.0)
	}
}

// What says the stack is summed at unity is that its level for 1..8 layers is
// already accounted for without a trim. `s1probe unisonprobe` reads the
// reference's steady RMS at zero detune, and the ratios are far from both
// 1/sqrt(N) and N:
//
//     voices  1       2       3       4       5       6       7       8
//     ratio   1.0000  1.7123  2.5910  3.4068  3.8003  3.8554  3.2229  3.6704
//
// They are the coherent sum of the start phases, and they fall at seven layers,
// which no monotonic count law of any shape can do. This test takes the phase
// constants, sums them as unit phasors and checks the magnitudes against those
// readings -- so the phase law and the gain law are tied to one measurement and
// neither can be adjusted alone.
@(test)
test_unison_stack_level_is_the_coherent_sum_of_the_phases :: proc(t: ^testing.T) {
	reference := [8]f32{1.0000, 1.7123, 2.5910, 3.4068, 3.8003, 3.8554, 3.2229, 3.6704}
	re, im, one: f32
	for count in 1 ..= 8 {
		turns := engine.unison_phase_offset(count - 1, 1.0)
		re += math.cos(2.0 * math.PI * turns)
		im += math.sin(2.0 * math.PI * turns)
		magnitude := math.sqrt(re * re + im * im) * engine.unison_stack_scale(count)
		if count == 1 {one = magnitude}
		ratio := magnitude / one
		expected := reference[count - 1]
		testing.expectf(t, abs(ratio / expected - 1.0) < 0.006,
			"%d layers sum to %.4f of one layer; the reference's RMS ratio is %.4f",
			count, ratio, expected)
	}
}

// Parameters 84 and 85 keep their measured controller ranges. Their use in the
// layer layout is tested above; this pins the state bindings independently.
@(test)
test_unison_pan_and_pitch_bindings_keep_reference_ranges :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[84] = 0
	p.values[85] = 0
	bound := engine.bind_patch(p)
	testing.expectf(t, abs(bound.unison_pan_spread + 1.0) < 0.000001,
		"pan state 0 bound to %.6f; reference reads -1", bound.unison_pan_spread)
	testing.expect_value(t, bound.unison_pitch, -24.0)
	p.values[84] = 64
	p.values[85] = 24
	bound = engine.bind_patch(p)
	testing.expectf(t, abs(bound.unison_pan_spread) < 0.000001,
		"pan state 64 bound to %.6f; reference reads 0", bound.unison_pan_spread)
	testing.expect_value(t, bound.unison_pitch, 0.0)
}

// Polyphony comes from parameter 94 and sizes the pool.
@(test)
test_polyphony_binding_and_pool_size :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[94] = 4
	bound := engine.bind_patch(p)
	testing.expect_value(t, bound.polyphony, 4)

	e: engine.Engine
	engine.engine_init(&e, bound, SR)
	defer engine.engine_destroy(&e)
	testing.expect_value(t, len(e.voices), 4)
}

// ---------------------------------------------------------------------------
// Measured envelope curve
// ---------------------------------------------------------------------------

// The generated tables have to stay a plausible envelope curve.
//
// They are machine-written from a sweep of the reference binary, which is not
// checked in, so nothing else in this suite would notice a regeneration that
// went wrong -- a truncated sweep, a segment that stopped resolving, a units
// slip between milliseconds and seconds. These are the properties any correct
// version of that measurement has.
@(test)
test_envelope_tables_are_a_monotonic_curve :: proc(t: ^testing.T) {
	tables := [][]f32 {
		engine.ENVELOPE_ATTACK_SECONDS[:],
		engine.ENVELOPE_DECAY_SECONDS[:],
		engine.ENVELOPE_RELEASE_SECONDS[:],
	}
	names := []string{"attack", "decay", "release"}

	for table, k in tables {
		testing.expect_value(t, len(table), engine.ENVELOPE_TABLE_SIZE)
		for i in 0 ..< len(table) {
			testing.expectf(t, table[i] > 0, "%v[%v] is %v, not a positive time", names[k], i, table[i])
			// A millisecond floor and a minute ceiling: wide enough that a real
			// measurement never trips it, narrow enough that a units slip does.
			testing.expectf(t, table[i] >= 0.001 && table[i] <= 60.0,
				"%v[%v] is %v s, outside anything an envelope segment should be", names[k], i, table[i])
			if i > 0 {
				// Rising, but not asserted to the last bit. Two measured facts
				// stop this from being a strict comparison, and neither is a
				// defect worth flattening the data to hide:
				//
				//   - The release at stored 0 is 9.6 ms against 8.2 ms at stored
				//     1. That reproduces at four times the analysis resolution
				//     and at two different notes, so it is something the plugin
				//     really does at the bottom of the range -- most likely an
				//     anti-click fade that outlasts the shortest real release.
				//   - Adjacent entries in the flat part of a curve can differ in
				//     the seventh decimal place, which is float noise in a
				//     measurement, not an inversion.
				//
				// The tolerance admits both and still catches a table that has
				// been generated backwards or half-overwritten.
				slack := max(f32(0.002), table[i - 1] * 0.05)
				testing.expectf(t, table[i] >= table[i - 1] - slack,
					"%v falls from [%v]=%v to [%v]=%v, further than measurement noise",
					names[k], i - 1, table[i - 1], i, table[i])
			}
		}
		// The reference spans four orders of magnitude. A table that has
		// collapsed onto one value would still pass everything above.
		testing.expectf(t, table[len(table) - 1] / table[0] > 100.0,
			"%v spans only %vx, which is not the measured curve",
			names[k], table[len(table) - 1] / table[0])
	}
}

// The binding must resolve a stored integer into the table the same way the rest
// of the engine resolves one, including when the file holds a value no state can
// take. An out-of-range index here would read past the end of a 128-entry array.
@(test)
test_envelope_times_bind_and_stay_in_range :: proc(t: ^testing.T) {
	p := default_patch()

	// Amp attack, decay and release at both ends of the range.
	p.values[25] = 0
	p.values[26] = 0
	p.values[28] = 0
	fastest := engine.bind_patch(p)
	p.values[25] = 127
	p.values[26] = 127
	p.values[28] = 127
	slowest := engine.bind_patch(p)

	testing.expect(t, slowest.amp_attack > fastest.amp_attack, "attack did not lengthen across the range")
	testing.expect(t, slowest.amp_decay > fastest.amp_decay, "decay did not lengthen across the range")
	testing.expect(t, slowest.amp_release > fastest.amp_release, "release did not lengthen across the range")

	// The measured release reaches tens of seconds, which is the finding that
	// motivated the table: the curve it replaced topped out at 12 s.
	testing.expectf(t, slowest.amp_release > 20.0,
		"the longest release is %v s; the measured reference is about 40 s", slowest.amp_release)

	// Out of range in both directions, which resolved_position clamps.
	out_of_range := []int{-5, 200, 1_000_000}
	for bad in out_of_range {
		p.values[25] = bad
		p.values[26] = bad
		p.values[28] = bad
		bound := engine.bind_patch(p)
		testing.expectf(t, bound.amp_attack > 0 && bound.amp_attack <= 60.0,
			"stored %v gave an attack of %v s", bad, bound.amp_attack)
		testing.expectf(t, bound.amp_decay > 0 && bound.amp_decay <= 60.0,
			"stored %v gave a decay of %v s", bad, bound.amp_decay)
		testing.expectf(t, bound.amp_release > 0 && bound.amp_release <= 60.0,
			"stored %v gave a release of %v s", bad, bound.amp_release)
	}
}

// The engine's release has to actually last as long as the table says, or the
// table is decorative. dsp.segment_coef is defined to cover 99.9% -- 60 dB -- in
// its argument, which is exactly what the reference was measured against.
@(test)
test_release_lasts_as_long_as_the_measured_table_says :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[25] = 0 // instant attack
	p.values[26] = 0 // no decay
	p.values[27] = 127 // full sustain
	p.values[28] = 64 // a mid release, about half a second
	// The effects have to be off for this to measure what it claims to. The
	// delay's repeats keep the output alive long after the amplitude envelope has
	// finished, which is the delay working correctly and this test measuring the
	// wrong thing.
	p.values[65] = 0 // delay off
	p.values[66] = 0 // chorus off
	bound := engine.bind_patch(p)
	expected := bound.amp_release

	e: engine.Engine
	engine.engine_init(&e, bound, SR)
	defer engine.engine_destroy(&e)

	hold := int(0.2 * f32(SR))
	tail := int((expected * 3.0 + 0.5) * f32(SR))
	left := make([]f32, hold + tail)
	defer delete(left)
	right := make([]f32, hold + tail)
	defer delete(right)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, left[:hold], right[:hold])
	engine.engine_note_off(&e, 60)
	engine.engine_process(&e, left[hold:], right[hold:])

	// Peak level over a 5 ms window, at note off and at one release time after.
	window := int(0.005 * f32(SR))
	peak_at :: proc(x: []f32, from, count: int) -> f32 {
		peak: f32 = 0
		for i in from ..< min(from + count, len(x)) {
			if abs(x[i]) > peak {
				peak = abs(x[i])
			}
		}
		return peak
	}

	at_off := peak_at(left[:], hold - window, window)
	one_release_later := peak_at(left[:], hold + int(expected * f32(SR)), window)
	testing.expect(t, at_off > 0.001, "the note was not sounding at note off")

	// 60 dB down is a factor of 1000. Allow a wide band around it: the point is
	// that the release is on the right order, not that the coefficient is exact.
	ratio := at_off / max(one_release_later, 1.0e-9)
	testing.expectf(t, ratio > 100.0 && ratio < 100_000.0,
		"after one release time (%v s) the level fell by a factor of %v, expected about 1000",
		expected, ratio)
}

// The pulse wave has to be free of DC at every width.
//
// This is the property that matters most about it, and the one the naive
// `t < pw ? 1 : -1` form does not have: its mean is 2*pw - 1, which at a 98%
// width is almost the entire signal. DC is invisible to a low pass, so a patch
// that closes the filter over an extreme pulse stayed at full level here while
// the reference fell silent.
@(test)
test_pulse_wave_carries_no_dc_at_any_width :: proc(t: ^testing.T) {
	widths := []f32{0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98}
	for width in widths {
		o: dsp.Oscillator
		dsp.oscillator_init(&o, 7)
		// A frequency that divides the sample rate evenly, so a whole number of
		// cycles fits the averaging window and the mean is the waveform's.
		dsp.oscillator_set_frequency(&o, 100.0, SR)

		cycles :: 40
		samples := int(SR / 100.0) * cycles
		sum: f64 = 0
		peak: f32 = 0
		for _ in 0 ..< samples {
			dsp.oscillator_advance(&o)
			v := dsp.oscillator_value(&o, .Pulse, width)
			sum += f64(v)
			if abs(v) > peak {
				peak = abs(v)
			}
		}
		mean := sum / f64(samples)
		testing.expectf(t, abs(mean) < 0.02,
			"pulse at width %v has a mean of %v; it should be DC-free", width, mean)
		// One peak to peak at every width, so no single excursion exceeds one.
		testing.expectf(t, peak <= 1.05,
			"pulse at width %v reached %v", width, peak)
	}
}

// A half-width pulse is a square wave, swinging half what the saw does: the
// reference's pulse measures at half its saw's amplitude, so ±0.5 here.
@(test)
test_pulse_at_half_width_is_a_square :: proc(t: ^testing.T) {
	o: dsp.Oscillator
	dsp.oscillator_init(&o, 3)
	dsp.oscillator_set_frequency(&o, 100.0, SR)

	high: f32 = -10
	low: f32 = 10
	for _ in 0 ..< int(SR / 100.0) * 8 {
		dsp.oscillator_advance(&o)
		v := dsp.oscillator_value(&o, .Pulse, 0.5)
		if v > high {high = v}
		if v < low {low = v}
	}
	testing.expectf(t, abs(high - 0.5) < 0.05, "square high was %v, expected 0.5", high)
	testing.expectf(t, abs(low + 0.5) < 0.05, "square low was %v, expected -0.5", low)
}

// The triangle crosses zero rising at phase 0 and peaks a quarter turn later.
//
// Checked against the reference's own render rather than against arithmetic:
// folding 100 cycles of `Synth1 VST64.dll` at note 60 reads 0.0055, 0.2230,
// -0.0056, -0.2230 at phases 0, 0.25, 0.5 and 0.75, which divided by its own
// peak is 0.02, 1, -0.03, -1. This engine started at the trough instead, a
// quarter turn late, and projecting the fundamental out of both renders agrees:
// -0.2507 turns for the reference against -0.4954 for ours.
//
// The table is what makes the check signed, and signed is the whole point. A
// quarter turn the other way gives 0, -1, 0, +1: the same magnitude spectrum,
// the same RMS, the same everything a single-oscillator metric can see, and the
// wrong waveform. Asserting `value(0) == 0` on its own would accept it.
@(test)
test_triangle_starts_at_its_rising_zero_crossing :: proc(t: ^testing.T) {
	// The reference's amplitudes at the four quarter points and the peak they
	// are normalised by, both from the same folded render, so its gain divides
	// out and only the shape is compared.
	ref := [4]f32{0.0055, 0.2230, -0.0056, -0.2230}
	ref_peak := f32(0.2230)

	o: dsp.Oscillator
	dsp.oscillator_init(&o, 11)
	dsp.oscillator_set_frequency(&o, 100.0, SR)

	for q in 0 ..< 4 {
		phase := f32(q) * 0.25
		dsp.oscillator_set_phase(&o, phase)
		got := dsp.oscillator_value(&o, .Triangle, 0.5)
		want := ref[q] / ref_peak
		testing.expectf(t, abs(got - want) < 0.05,
			"triangle at phase %v gave %v; the reference's folded cycle says %v",
			phase, got, want)
	}

	// Rising through phase 0, not falling. The reference climbs from 0.0055 to
	// 0.2230 over the first quarter; the two zero crossings on their own cannot
	// tell the two directions apart.
	dsp.oscillator_set_phase(&o, 0.05)
	early := dsp.oscillator_value(&o, .Triangle, 0.5)
	testing.expectf(t, early > 0.1,
		"the triangle should be rising just after phase 0, got %v", early)
}

// The pulse is high for `1 - pw` of its cycle, not for `pw`.
//
// Anchored on the reference's own folded render at stored width 29: high
// +0.0271 for 88.6% of the cycle, low -0.2113 for the remaining 11.4%. The two
// levels sit in the ratio the DC-free two-saw form predicts for that duty, so
// the fraction and the ratio pin the duty from two directions.
//
// No magnitude metric can see this. |sin(pi*k*d)| is symmetric in d <-> 1-d, so
// both duties have identical magnitude spectra; on a single pulse the spectral
// error read 0.18 dB while the null read -0.08 dB. It shows only in phase, in
// mixes and in the null -- 117 Perc1's level error went from 6.06 dB to 0.01 dB
// on this one line -- which is why the check is on the shape in time and not on
// a spectrum. `test_pulse_at_half_width_is_a_square` above passes either way and
// always would: a square is its own duty complement.
@(test)
test_pulse_is_high_for_the_complement_of_its_width :: proc(t: ^testing.T) {
	p := default_patch()
	// The width the reference was folded at, taken through the same binding a
	// patch file goes through, so the stored number and the shape are pinned
	// together rather than separately.
	p.values[8] = 29
	pw := engine.bind_patch(p).pulse_width
	testing.expectf(t, abs(pw - 0.114) < 0.005,
		"stored width 29 should be an 11.4%% duty, got %v", pw)

	o: dsp.Oscillator
	dsp.oscillator_init(&o, 13)
	// 100 Hz divides the sample rate, so a whole number of cycles fits the scan
	// and the fraction below is the waveform's own.
	dsp.oscillator_set_frequency(&o, 100.0, SR)
	period := int(SR / 100.0)

	above := 0
	total := period * 8
	for _ in 0 ..< total {
		dsp.oscillator_advance(&o)
		if dsp.oscillator_value(&o, .Pulse, pw) > 0 {above += 1}
	}
	fraction := f32(above) / f32(total)
	testing.expectf(t, abs(fraction - (1.0 - pw)) < 0.01,
		"the pulse was high for %v of its cycle; the reference is high for %v",
		fraction, 1.0 - pw)

	// The two plateau levels, read away from both edges where the PolyBLEP
	// correction is zero, against the reference's own two levels.
	dsp.oscillator_set_phase(&o, 0.5)
	high := dsp.oscillator_value(&o, .Pulse, pw)
	dsp.oscillator_set_phase(&o, 1.0 - 0.5 * pw)
	low := dsp.oscillator_value(&o, .Pulse, pw)
	testing.expectf(t, high > 0 && low < 0,
		"the plateaux should straddle zero, got %v and %v", high, low)

	// 0.0271 / -0.2113 = -0.1283 in the reference. Swapping the duty makes this
	// -7.8, so the ratio is a wide margin rather than a fine one.
	want_ratio := f32(0.0271 / -0.2113)
	ratio := high / low
	testing.expectf(t, abs(ratio - want_ratio) < 0.01,
		"the plateaux are in the ratio %v; the reference's folded cycle says %v",
		ratio, want_ratio)
}

// The top of parameter 8's range is a square, and its middle is a quarter duty.
// This is the mapping the harmonic measurement pinned down, and getting it wrong
// by the factor of two it used to be wrong by changes the timbre of every pulse
// patch in the bank.
@(test)
test_pulse_width_knob_reaches_a_square_at_its_top :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[8] = 127
	testing.expectf(t, abs(engine.bind_patch(p).pulse_width - 0.5) < 0.005,
		"the top of the width range should be a square, got %v",
		engine.bind_patch(p).pulse_width)

	p.values[8] = 64
	quarter := engine.bind_patch(p).pulse_width
	testing.expectf(t, abs(quarter - 0.252) < 0.005,
		"stored 64 should be a quarter duty, got %v", quarter)

	p.values[8] = 0
	testing.expect_value(t, engine.bind_patch(p).pulse_width, 0.0)
}

// Filter keyboard tracking is measured from C3, and at full tracking a note an
// octave above it must land an octave up.
//
// The reference puts the corner at the same frequency at every note with tracking
// off, and at that same frequency at *note 48* with tracking full. Reading from
// middle C instead cost a whole octave of brightness on every patch with the
// tracking knob up, which through a 24 dB filter is 24 dB of output, and it was
// why several of them rendered near silence here.
@(test)
test_filter_tracking_is_measured_from_c3 :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[14] = 0 // low pass 12
	p.values[19] = 64 // a mid cutoff, room to move
	p.values[21] = 63 // no envelope contribution
	p.values[22] = 127 // full keyboard tracking
	p.values[15] = 0
	p.values[16] = 0
	p.values[17] = 127
	p.values[18] = 0
	bound := engine.bind_patch(p)
	testing.expectf(t, abs(bound.filter_key_track - 1.0) < 0.01,
		"full tracking should read as one octave per octave, got %v", bound.filter_key_track)

	// The reference note itself: the offset the engine applies is
	// key_track * (note - 48) / 12, so a note at 48 gets nothing and middle C
	// gets a whole octave.
	testing.expect_value(t, engine.FILTER_TRACK_REFERENCE_NOTE, 48.0)

	offset_at_48 := bound.filter_key_track * (48.0 - engine.FILTER_TRACK_REFERENCE_NOTE) / 12.0
	offset_at_60 := bound.filter_key_track * (60.0 - engine.FILTER_TRACK_REFERENCE_NOTE) / 12.0
	testing.expectf(t, abs(offset_at_48) < 0.001,
		"the reference note should get no tracking offset, got %v octaves", offset_at_48)
	testing.expectf(t, abs(offset_at_60 - 1.0) < 0.02,
		"middle C should get one octave at full tracking, got %v", offset_at_60)
}

// ---------------------------------------------------------------------------
// Equaliser
// ---------------------------------------------------------------------------

// Parameter 61's display switches from hertz to kilohertz partway up its range,
// and reading the leading number alone turns 3.9 kHz into 3.9 Hz -- three orders
// of magnitude, silently, across the whole top half of the knob.
@(test)
test_equalizer_frequency_display_honours_kilohertz :: proc(t: ^testing.T) {
	testing.expectf(t, abs(engine.display_frequency_hz("50.0 Hz") - 50.0) < 0.01,
		"got %v", engine.display_frequency_hz("50.0 Hz"))
	testing.expectf(t, abs(engine.display_frequency_hz("915.0 Hz") - 915.0) < 0.01,
		"got %v", engine.display_frequency_hz("915.0 Hz"))
	testing.expectf(t, abs(engine.display_frequency_hz("3.9 KHz") - 3900.0) < 1.0,
		"a kilohertz display must scale by a thousand, got %v",
		engine.display_frequency_hz("3.9 KHz"))
	testing.expectf(t, abs(engine.display_frequency_hz("16.0 KHz") - 16000.0) < 1.0,
		"got %v", engine.display_frequency_hz("16.0 KHz"))

	// And through the binding: the top of the range has to land in the audible
	// band, not three orders of magnitude below it.
	p := default_patch()
	p.values[61] = 127
	testing.expectf(t, engine.bind_patch(p).eq_freq_hz > 10000.0,
		"the top of the frequency knob bound to %v Hz", engine.bind_patch(p).eq_freq_hz)
	p.values[61] = 0
	testing.expectf(t, abs(engine.bind_patch(p).eq_freq_hz - 50.0) < 1.0,
		"the bottom bound to %v Hz", engine.bind_patch(p).eq_freq_hz)
}

// The level knob's centre is flat, and the reference says so exactly: stored 64
// displays "0.0 db". That is what lets this section sit in the chain with no
// on/off switch.
@(test)
test_equalizer_is_flat_at_its_centre :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[62] = 64
	testing.expect_value(t, engine.bind_patch(p).eq_gain_db, 0.0)
	p.values[60] = 64
	testing.expectf(t, abs(engine.bind_patch(p).eq_tone) < 0.01,
		"the tone knob's centre should be flat, got %v", engine.bind_patch(p).eq_tone)

	// Both ends carry real decibels, read rather than mapped.
	p.values[62] = 0
	testing.expectf(t, engine.bind_patch(p).eq_gain_db < -20.0,
		"the bottom of the level knob bound to %v dB", engine.bind_patch(p).eq_gain_db)
	p.values[62] = 127
	testing.expectf(t, engine.bind_patch(p).eq_gain_db > 20.0,
		"the top bound to %v dB", engine.bind_patch(p).eq_gain_db)
}

// A peaking filter has to lift its own band and leave the rest alone, and it has
// to be stable at every setting the parameters can reach.
@(test)
test_peaking_filter_lifts_its_band_and_stays_stable :: proc(t: ^testing.T) {
	// Energy a filter passes at a given frequency, by running a sine through it.
	response :: proc(freq_hz, gain_db, q, probe_hz: f32) -> f64 {
		coefficients := dsp.peaking_coefficients(freq_hz, gain_db, q, SR)
		b: dsp.Biquad
		sum := 0.0
		n := 8192
		for i in 0 ..< n {
			x := math.sin(2.0 * math.PI * f64(probe_hz) * f64(i) / f64(SR))
			y := dsp.biquad_process(&b, &coefficients, f32(x))
			// Skip the first tenth while the filter settles.
			if i > n / 10 {
				sum += f64(y) * f64(y)
			}
		}
		return math.sqrt(sum / f64(n - n / 10 - 1))
	}

	// A +12 dB lift at 1 kHz should raise 1 kHz and leave 60 Hz nearly alone.
	at_band := response(1000.0, 12.0, 2.0, 1000.0)
	far_below := response(1000.0, 12.0, 2.0, 60.0)
	flat := response(1000.0, 0.0, 2.0, 1000.0)

	testing.expectf(t, at_band > flat * 2.0,
		"a 12 dB lift should roughly quadruple the power at its centre: %v against %v",
		at_band, flat)
	testing.expectf(t, far_below < flat * 1.3,
		"the lift reached two octaves below its centre: %v against %v", far_below, flat)

	// A cut is the mirror image.
	cut := response(1000.0, -12.0, 2.0, 1000.0)
	testing.expectf(t, cut < flat * 0.5, "a 12 dB cut left %v against %v", cut, flat)

	// Stability across the extremes the binding can produce, including a centre
	// above the analysis band and a Q at both ends.
	extremes := []f32{10.0, 50.0, 1000.0, 16000.0, 30000.0}
	qs := []f32{0.05, 0.3, 8.0, 100.0}
	for f in extremes {
		for q in qs {
			for g in ([]f32{-25.0, 0.0, 25.0}) {
				out := response(f, g, q, 1000.0)
				testing.expectf(t, out == out && out < 1000.0,
					"unstable at %v Hz, Q %v, %v dB: %v", f, q, g, out)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Delay and chorus
// ---------------------------------------------------------------------------

// Parameter 35's twenty displays are the reference's own notation for musical
// divisions, and they have to parse into beats exactly. A quarter note is one
// beat, "(N)" is 4/N beats, "+" sums, "/3" divides by three.
//
// That last one is the correction this case list carries. It used to read "/3
// takes two thirds" and assert 0.125*2/3, 2/3 and 8/3 for the three triplet
// displays -- the musician's convention, taken on faith from nobody's
// measurement. Sweeping all twenty states through the reference showed every
// "/3" state playing at exactly half those times. The expectations below are
// now the reference's, and test_delay_division_table_matches_the_measured_reference
// pins them to the numbers that came off the DLL.
//
// The list is not arithmetic on the state index: nothing about the index says
// whether a state is a plain note, a dotted sum or a division by three.
@(test)
test_delay_division_displays_parse_to_beats :: proc(t: ^testing.T) {
	Case :: struct {
		display: string,
		beats:   f32,
	}
	cases := []Case {
		{"(1)", 4.0},
		{"(2)", 2.0},
		{"(4)", 1.0},
		{"(8)", 0.5},
		{"(16)", 0.25},
		{"(32)", 0.125},
		// Dotted values, written as a sum.
		{"(16)+(32)", 0.375},
		{"(8)+(16)", 0.75},
		{"(8)+(16)+(32)", 0.875},
		{"(4)+(8)", 1.5},
		{"(2)+(4)", 3.0},
		// Triplets divide the whole sum by three.
		{"(32) /3", 0.125 / 3.0},
		{"(4) /3", 1.0 / 3.0},
		{"(1) /3", 4.0 / 3.0},
	}
	for c in cases {
		beats, musical := engine.delay_display_beats(c.display)
		testing.expectf(t, musical, "%q did not parse as a musical division", c.display)
		testing.expectf(t, abs(beats - c.beats) < 0.0005,
			"%q parsed as %v beats, expected %v", c.display, beats, c.beats)
	}

	// State 0 is a fixed time, not a division, and must not read as one.
	_, musical := engine.delay_display_beats("0.1 msec")
	testing.expect(t, !musical, "the fixed-millisecond state parsed as a division")
}

// The regression guard for parameter 35's whole division table, checked against
// two things that are not this parser.
//
// The first is the reference. All twenty of parameter 35's states were rendered
// through `ext/synth1/Synth1/Synth1 VST64.dll` -- percussive click, 100 % wet,
// no feedback, no spread, arp and chorus off, at the harness's 120 BPM -- and
// the first sample above threshold read straight off each render. Nothing is
// audible before the echo in that patch, so that sample *is* the delay time.
// The readings below are those measurements, transcribed, and they carry a
// constant +0.06 ms of the reference's own delay-line offset, which is why the
// tolerance is 0.15 ms rather than zero. That is still two orders of magnitude
// under the error this test exists to catch: a wrong "/3" factor moves the
// nearest of these by 20 ms.
//
// The second is src/engine/arpeggiator.odin. Parameter 33 spells its steps in
// the same notation and ARP_STEP_BEATS was measured separately, with `s1probe
// arpprobe`. The nineteen musical delay states turn out to be that table
// reversed, exactly -- which is the check, because the two were written from
// different measurements and disagreed by a factor of two on every "/3" state
// until the sweep above settled it. The old test could not see that: it
// asserted the convention its author had assumed, so it agreed with the code it
// was checking and could never fail. Pinning the table to the DLL and to a
// separately measured table is what makes this a test.
@(test)
test_delay_division_table_matches_the_measured_reference :: proc(t: ^testing.T) {
	MS_PER_BEAT :: f32(60000.0 / 120.0)

	// Parameter 35's states in order, with the reference's own display for each
	// (from ui/params.js, which tools/uiparams reads out of the plugin) and the
	// millisecond reading from the sweep.
	Case :: struct {
		display: string,
		ref_ms:  f32,
	}
	states := []Case {
		{"0.1 msec", 0.19}, // not a division; handled below
		{"(32) /3", 20.90},
		{"(16) /3", 41.73},
		{"(32)", 62.56},
		{"(8) /3", 83.40},
		{"(16)", 125.06},
		{"(4) /3", 166.73},
		{"(16)+(32)", 187.56},
		{"(8)", 250.06},
		{"(2) /3", 333.40},
		{"(8)+(16)", 375.06},
		{"(8)+(16)+(32)", 437.56},
		{"(4)", 500.06},
		{"(1) /3", 666.73},
		{"(4)+(8)", 750.06},
		{"(4)+(8)+(16)", 875.06},
		{"(2)", 1000.06},
		{"(2)+(4)", 1500.06},
		{"(2)+(4)+(8)", 1750.06},
		{"(1)", 2000.06},
	}

	for c, state in states {
		beats, musical := engine.delay_display_beats(c.display)

		if state == 0 {
			testing.expect(t, !musical, "the fixed-millisecond state parsed as a division")
			continue
		}
		testing.expectf(t, musical, "%q did not parse as a musical division", c.display)

		ms := beats * MS_PER_BEAT
		testing.expectf(t, abs(ms - c.ref_ms) < 0.15,
			"state %v %q is %v ms at 120 BPM; the reference plays it at %v ms",
			state, c.display, ms, c.ref_ms)

		// The nineteen musical states run longest-first in the arpeggiator's
		// table and shortest-first here, so state N is ARP_STEP_BEATS[19-N].
		arp := engine.ARP_STEP_BEATS[len(engine.ARP_STEP_BEATS) - state]
		testing.expectf(t, abs(beats - arp) < 0.0005,
			"state %v %q parses to %v beats; the arpeggiator's measured table has the same division at %v beats",
			state, c.display, beats, arp)
	}
}

// Parameter 83 reads out both channel times at once.
@(test)
test_delay_spread_display_parses_both_channels :: proc(t: ^testing.T) {
	l, r := engine.delay_spread_ms("0.0 : 100.0 msec")
	testing.expectf(t, abs(l) < 0.01 && abs(r - 100.0) < 0.01, "got %v : %v", l, r)

	l, r = engine.delay_spread_ms("100.0 : 0.0 msec")
	testing.expectf(t, abs(l - 100.0) < 0.01 && abs(r) < 0.01, "got %v : %v", l, r)

	l, r = engine.delay_spread_ms("0.0 : 0.0 msec")
	testing.expectf(t, abs(l) < 0.01 && abs(r) < 0.01, "centre should be no spread, got %v : %v", l, r)
}

// The delay line has to return what was put into it, a chosen number of samples
// later, and interpolate in between.
@(test)
test_delay_line_returns_what_went_in :: proc(t: ^testing.T) {
	buffer := make([]f32, 512)
	defer delete(buffer)
	line: dsp.Delay_Line
	dsp.delay_line_init(&line, buffer)

	// An impulse, then silence, and the impulse should come back out at the tap.
	dsp.delay_line_write(&line, 1.0)
	for _ in 0 ..< 99 {
		dsp.delay_line_write(&line, 0)
	}
	// The write head has advanced 100 samples, so the impulse is 100 back.
	testing.expectf(t, abs(dsp.delay_line_read(&line, 100) - 1.0) < 0.001,
		"the impulse did not come back at 100 samples: %v", dsp.delay_line_read(&line, 100))
	testing.expectf(t, abs(dsp.delay_line_read(&line, 50)) < 0.001,
		"something came back where there was silence")
	// Halfway between the impulse and its silent neighbour.
	half := dsp.delay_line_read(&line, 99.5)
	testing.expectf(t, half > 0.4 && half < 0.6,
		"a half-sample tap should interpolate to about 0.5, got %v", half)

	// A tap longer than the line is clamped, not wrapped: a wrapped read would
	// return a plausible echo at the wrong time.
	testing.expect(t, dsp.delay_line_read(&line, 100000) == dsp.delay_line_read(&line, f32(len(buffer) - 2)))
}

// The modes differ in where the input enters and where feedback returns. Two
// samples is long enough to make each repeat's channel explicit without an
// engine render or a tolerance-sensitive spectral comparison.
@(test)
test_delay_modes_route_repeats_independently :: proc(t: ^testing.T) {
	render := proc(mode: dsp.Delay_Mode, left_in, right_in: f32) -> ([9]f32, [9]f32) {
		left_buffer: [32]f32
		right_buffer: [32]f32
		d: dsp.Delay
		dsp.delay_init(&d, left_buffer[:], right_buffer[:])
		p := dsp.Delay_Params {
			left_samples  = 2,
			right_samples = 2,
			feedback      = 0.5,
			dry_wet       = 1,
			mode          = mode,
		}
		left, right: [9]f32
		for i in 0 ..< len(left) {
			in_l := i == 0 ? left_in : 0
			in_r := i == 0 ? right_in : 0
			left[i], right[i] = dsp.delay_process(&d, in_l, in_r, &p, SR)
		}
		return left, right
	}

	// Normal stereo never moves a left-only impulse to the right.
	left, right := render(.Stereo, 1, 0)
	testing.expect_value(t, left[2], 1.0)
	testing.expect_value(t, left[4], 0.5)
	testing.expect_value(t, right[2], 0.0)
	testing.expect_value(t, right[4], 0.0)

	// Cross feedback preserves the first echo's side, then alternates.
	left, right = render(.Cross, 1, 0)
	testing.expect_value(t, left[2], 1.0)
	testing.expect_value(t, right[4], 0.5)
	testing.expect_value(t, left[6], 0.25)

	// Ping-pong sums both inputs into the left line and alternates from there.
	left, right = render(.Ping_Pong, 0.25, 0.75)
	testing.expect_value(t, left[2], 1.0)
	testing.expect_value(t, right[2], 0.0)
	// Feedback is applied once per round trip, so the right echo matches the
	// first left echo and the next pair is down by the feedback amount.
	testing.expect_value(t, right[4], 1.0)
	testing.expect_value(t, left[6], 0.5)
	testing.expect_value(t, right[8], 0.5)
}

// A delay with the mix up has to still be sounding after the note has gone, and
// with the mix down it must be inaudible.
@(test)
test_delay_sustains_the_output_past_the_note :: proc(t: ^testing.T) {
	render :: proc(delay_on: bool) -> f32 {
		p := default_patch()
		p.values[66] = 0 // chorus off, so only the delay is under test
		p.values[65] = delay_on ? 1 : 0
		p.values[35] = 8 // an eighth note
		p.values[36] = 100 // plenty of feedback
		p.values[37] = 127 // fully wet
		p.values[25] = 0
		p.values[26] = 0
		p.values[27] = 127
		p.values[28] = 0 // instant release, so the voice itself stops at once

		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)

		hold := int(0.2 * SR)
		tail := int(1.0 * SR)
		l := make([]f32, hold + tail)
		defer delete(l)
		r := make([]f32, hold + tail)
		defer delete(r)

		engine.engine_note_on(&e, 60, 1.0)
		engine.engine_process(&e, l[:hold], r[:hold])
		engine.engine_note_off(&e, 60)
		engine.engine_process(&e, l[hold:], r[hold:])

		// Level well after the note has been released.
		peak: f32 = 0
		from := hold + int(0.4 * SR)
		for i in from ..< len(l) {
			if abs(l[i]) > peak {peak = abs(l[i])}
		}
		return peak
	}

	with := render(true)
	without := render(false)
	testing.expectf(t, without < 0.001,
		"with the delay off the tail should be silent, got %v", without)
	testing.expectf(t, with > 0.01,
		"with the delay on the tail should still be sounding, got %v", with)
}

// The chorus has to widen the image. That is its whole purpose, and it is the
// property the null test measures as stereo width.
@(test)
test_chorus_widens_the_image :: proc(t: ^testing.T) {
	side_over_mid :: proc(chorus_on: bool) -> f64 {
		p := default_patch()
		p.values[65] = 0 // delay off
		p.values[66] = chorus_on ? 1 : 0
		p.values[52] = 100 // a chorus-length delay, not a flanger-length one
		p.values[53] = 90 // deep
		p.values[54] = 30 // slow
		p.values[56] = 127 // fully wet
		p.values[64] = 2 // a middle stage count
		p.values[73] = 0 // unison off, so the width can only come from the chorus
		p.values[25] = 0
		p.values[26] = 0
		p.values[27] = 127

		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)

		n := int(1.5 * SR)
		l := make([]f32, n)
		defer delete(l)
		r := make([]f32, n)
		defer delete(r)
		engine.engine_note_on(&e, 60, 1.0)
		engine.engine_process(&e, l, r)

		mid := 0.0
		side := 0.0
		from := n / 3
		for i in from ..< n {
			m := 0.5 * (f64(l[i]) + f64(r[i]))
			s := 0.5 * (f64(l[i]) - f64(r[i]))
			mid += m * m
			side += s * s
		}
		return mid > 0 ? math.sqrt(side / mid) : 0
	}

	with := side_over_mid(true)
	without := side_over_mid(false)
	testing.expectf(t, without < 0.05,
		"without the chorus the image should be centred, got a side/mid of %v", without)
	testing.expectf(t, with > without + 0.05,
		"the chorus did not widen the image: %v against %v", with, without)
}

// Both effects have to stay bounded and finite whatever they are handed,
// including the feedback settings that would run away if they were not clamped.
@(test)
test_effects_stay_finite_at_their_extremes :: proc(t: ^testing.T) {
	feedbacks := []int{0, 64, 127}
	for fb in feedbacks {
		p := default_patch()
		p.values[65] = 1
		p.values[66] = 1
		p.values[36] = 127 // delay feedback at maximum
		p.values[37] = 127
		p.values[55] = fb // chorus feedback swept, including full negative
		p.values[52] = 1 // a very short chorus tap, the flanger extreme
		p.values[53] = 127
		p.values[54] = 127 // and the 400 Hz sweep
		p.values[56] = 127
		p.values[64] = 4

		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)

		n := int(2.0 * SR)
		l := make([]f32, n)
		defer delete(l)
		r := make([]f32, n)
		defer delete(r)
		engine.engine_note_on(&e, 60, 1.0)
		engine.engine_process(&e, l[:n / 2], r[:n / 2])
		engine.engine_note_off(&e, 60)
		engine.engine_process(&e, l[n / 2:], r[n / 2:])

		for i in 0 ..< n {
			// Bounded by the output limiter, which is transparent below its knee and
			// asymptotic to twice it above. The bound has moved twice and each move
			// was the same correction in a different place: 1.5 came from a limiter
			// that compressed at every level and cost 1 dB on every patch in the bank,
			// 2.0 from a knee at full scale, and the knee is now at the reference's
			// own measured peaks because the phaser's DC resonance legitimately
			// reaches +21 dB and the old knee flattened it to +10.
			//
			// What this test is for is unchanged: finite, and bounded by something.
			limit := f32(2.0) * dsp.SOFT_CLIP_KNEE
			ok := l[i] == l[i] && r[i] == r[i] && abs(l[i]) <= limit && abs(r[i]) <= limit
			if !ok {
				testing.expectf(t, false,
					"chorus feedback %v produced %v / %v at sample %v", fb, l[i], r[i], i)
				break
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Measured amplitude curves
// ---------------------------------------------------------------------------

gain_100_probe_patch :: proc(shape, resonance, width: int) -> patch.Patch {
	p := default_patch()
	p.values[0] = shape
	p.values[5] = 0 // oscillator 1 alone
	p.values[8] = width
	p.values[14] = 0 // low pass 12
	p.values[19] = 127 // filter open
	p.values[20] = resonance
	p.values[21] = 63 // filter envelope amount zero
	p.values[22] = 0 // keyboard tracking off
	p.values[23] = 0 // saturation off
	p.values[25] = 0 // instant attack
	p.values[26] = 0 // no decay
	p.values[27] = 127 // full sustain
	p.values[28] = 0 // instant release
	p.values[29] = 100
	p.values[30] = 0 // velocity scaling off
	p.values[66] = 0 // chorus off
	p.values[37] = 0 // delay dry/wet zero
	p.values[65] = 0 // delay off
	p.values[60] = 64 // equalizer tone flat
	p.values[62] = 64 // equalizer gain zero
	p.values[63] = 64 // equalizer Q neutral
	p.values[77] = 0 // extra effect off
	return p
}

render_gain_100_probe :: proc(shape, resonance, width: int) -> []f32 {
	N :: 48000
	audio := make([]f32, N)
	discard := make([]f32, N)
	e: engine.Engine
	engine.engine_load_patch(&e, gain_100_probe_patch(shape, resonance, width), SR)
	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, audio, discard)
	engine.engine_destroy(&e)
	delete(discard)
	return audio
}

// Direct reference renders fix the levels under test. These values do not come
// from AMP_GAIN_AMPLITUDE or FILTER_OUTPUT_GAIN, so they catch a second output
// multiplier and a wrong resonance-level law. Reproduce them with the quoted
// filtersaturation commands in docs/null-test.md.
@(test)
test_gain_100_neutral_fundamentals_match_reference :: proc(t: ^testing.T) {
	expected := [3]f64{0.48695, 0.3099, 0.1085}
	shapes := [3]int{0, 1, 2}

	for shape, i in shapes {
		width := shape == 2 ? 29 : 64
		audio := render_gain_100_probe(shape, 0, width)
		f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)
		mag, _ := fundamental_phase(audio[12000:], f0, f64(SR))
		amplitude := 4.0 * mag
		testing.expectf(t, abs(amplitude - expected[i]) < 0.001,
			"shape %d at amp gain 100 measured %.5f; reference is %.5f",
			shape, amplitude, expected[i])
		delete(audio)
	}
}

@(test)
test_gain_100_first_resonance_step_matches_reference :: proc(t: ^testing.T) {
	resonances := [2]int{0, 1}
	expected_amplitude := [2]f64{0.48695, 0.48427}
	expected_peak := [2]f64{0.4870, 0.4843}
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	for resonance, i in resonances {
		audio := render_gain_100_probe(0, resonance, 64)
		mag, _ := fundamental_phase(audio[12000:], f0, f64(SR))
		amplitude := 4.0 * mag
		peak := 0.0
		for sample in audio {
			peak = max(peak, abs(f64(sample)))
		}
		testing.expectf(t, abs(amplitude - expected_amplitude[i]) < 0.001,
			"resonance %d at amp gain 100 has fundamental %.5f; reference is %.5f",
			resonance, amplitude, expected_amplitude[i])
		testing.expectf(t, abs(peak - expected_peak[i]) < 0.0002,
			"resonance %d at amp gain 100 has peak %.5f; reference is %.5f",
			resonance, peak, expected_peak[i])
		delete(audio)
	}
}

// The generated gain and sustain tables have to stay a plausible amplitude
// curve. Same reasoning as the envelope tables: they are machine-written from a
// sweep of a binary that is not checked in, so nothing else here would notice a
// regeneration that produced nonsense.
@(test)
test_amplitude_tables_are_a_monotonic_curve :: proc(t: ^testing.T) {
	tables := [][]f32{engine.AMP_GAIN_AMPLITUDE[:], engine.AMP_SUSTAIN_LEVEL[:]}
	names := []string{"gain", "sustain"}

	for table, k in tables {
		testing.expect_value(t, len(table), engine.AMP_TABLE_SIZE)
		for i in 0 ..< len(table) {
			testing.expectf(t, table[i] >= 0, "%v[%v] is negative: %v", names[k], i, table[i])
			// Nothing here should exceed unity: the gain table is an amplitude a
			// sine reached, and the sustain table is a fraction of full sustain.
			testing.expectf(t, table[i] <= 1.001, "%v[%v] is %v, above unity", names[k], i, table[i])
			if i > 0 {
				testing.expectf(t, table[i] >= table[i - 1] - 0.001,
					"%v falls from [%v]=%v to [%v]=%v", names[k], i - 1, table[i - 1], i, table[i])
			}
		}
		testing.expectf(t, table[0] < 0.01, "%v does not start near silence: %v", names[k], table[0])
	}

	// The measurement's headline fact: full gain reaches 0.825, not 1.0. A binding
	// that reached unity would be 1.7 dB hot for that reason alone.
	//
	// This asserted 0.75 until the generator's analysis window was fixed. That
	// window ran past the note off into the render's silent tail, so every value in
	// the table read low by the square root of the sounding fraction -- 0.9102, or
	// 0.81 dB -- and this test agreed with it because it was written from the same
	// bad number. A test derived from the measurement it is checking cannot catch
	// that measurement being wrong; what caught it was comparing our render against
	// the reference's on a bare sine, where the two now agree to 0.0 dB.
	full := engine.AMP_GAIN_AMPLITUDE[engine.AMP_TABLE_SIZE - 1]
	testing.expectf(t, full > 0.80 && full < 0.85,
		"full gain measured %v; the reference reaches about 0.825", full)
	testing.expectf(t, engine.AMP_SUSTAIN_LEVEL[engine.AMP_TABLE_SIZE - 1] > 0.999,
		"full sustain should be 1.0 by construction, got %v",
		engine.AMP_SUSTAIN_LEVEL[engine.AMP_TABLE_SIZE - 1])
}

// Gain and sustain bind through the tables, and out-of-range stored values stay
// inside them.
@(test)
test_amplitude_binding_uses_the_measured_tables :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[29] = 127
	p.values[27] = 127
	loud := engine.bind_patch(p)
	testing.expect_value(t, loud.amp_gain, engine.AMP_GAIN_AMPLITUDE[127])
	testing.expect_value(t, loud.amp_sustain, engine.AMP_SUSTAIN_LEVEL[127])

	p.values[29] = 0
	p.values[27] = 0
	quiet := engine.bind_patch(p)
	testing.expect(t, quiet.amp_gain < loud.amp_gain, "gain did not fall across the range")
	testing.expect(t, quiet.amp_sustain < loud.amp_sustain, "sustain did not fall across the range")

	out_of_range := []int{-9, 500, 1_000_000}
	for bad in out_of_range {
		p.values[29] = bad
		p.values[27] = bad
		bound := engine.bind_patch(p)
		testing.expectf(t, bound.amp_gain >= 0 && bound.amp_gain <= 1.001,
			"stored %v gave a gain of %v", bad, bound.amp_gain)
		testing.expectf(t, bound.amp_sustain >= 0 && bound.amp_sustain <= 1.001,
			"stored %v gave a sustain of %v", bad, bound.amp_sustain)
	}
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

// The note off in the middle of a render must produce a real release, not a
// signal that simply keeps sounding. The contract's CLI renders 1.5 s held plus
// 1.0 s of tail, so this covers the shape of that file rather than only its
// peak: the end of the tail has to be quieter than the held portion.
@(test)
test_engine_release_tail_decays_after_note_off :: proc(t: ^testing.T) {
	p := default_patch()
	// A short release, so the decay is unambiguous inside a one-second tail.
	p.values[28] = 20
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	hold := int(1.5 * SR)
	tail := int(1.0 * SR)
	left := make([]f32, hold + tail)
	right := make([]f32, hold + tail)
	defer delete(left)
	defer delete(right)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, left[:hold], right[:hold])
	engine.engine_note_off(&e, 60)
	engine.engine_process(&e, left[hold:], right[hold:])

	window :: proc(buf: []f32, from, count: int) -> f32 {
		peak: f32 = 0
		for i in from ..< min(from + count, len(buf)) {
			if abs(buf[i]) > peak {peak = abs(buf[i])}
		}
		return peak
	}

	// The last tenth of a second while the key was still down.
	held_peak := window(left, hold - int(0.1 * SR), int(0.1 * SR))
	// The last tenth of a second of the tail.
	tail_peak := window(left, hold + tail - int(0.1 * SR), int(0.1 * SR))

	testing.expectf(t, held_peak > 0.0001, "held portion was silent: %v", held_peak)
	testing.expectf(
		t,
		tail_peak < held_peak * 0.5,
		"release tail did not decay: held %v, tail %v",
		held_peak,
		tail_peak,
	)
}

// Render the default patch the way tools/render does and hold it to the same
// bar the contract sets for the CLI: finite samples and an audible peak.
@(test)
test_engine_renders_audible_finite_output :: proc(t: ^testing.T) {
	e: engine.Engine
	engine.engine_load_patch(&e, default_patch(), SR)
	defer engine.engine_destroy(&e)

	hold := int(1.5 * SR)
	tail := int(1.0 * SR)
	left := make([]f32, hold + tail)
	right := make([]f32, hold + tail)
	defer delete(left)
	defer delete(right)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, left[:hold], right[:hold])
	engine.engine_note_off(&e, 60)
	engine.engine_process(&e, left[hold:], right[hold:])

	peak: f32 = 0
	for i in 0 ..< len(left) {
		testing.expectf(t, finite(left[i]), "left sample %d non-finite", i)
		testing.expectf(t, finite(right[i]), "right sample %d non-finite", i)
		if abs(left[i]) > peak {peak = abs(left[i])}
		if abs(right[i]) > peak {peak = abs(right[i])}
	}
	testing.expectf(t, peak > 0.0001, "render was inaudible: peak %v", peak)
	testing.expectf(t, peak <= 1.0, "render exceeded full scale: peak %v", peak)
}

// A released voice must return to the pool, or polyphony silently shrinks to
// nothing over a performance.
@(test)
test_engine_frees_voices_after_release :: proc(t: ^testing.T) {
	p := default_patch()
	// A short amplitude release so the test does not have to render for the
	// default patch's full tail.
	p.values[28] = 0
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	block := make([]f32, 512)
	other := make([]f32, 512)
	defer delete(block)
	defer delete(other)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, block, other)
	testing.expect_value(t, engine.engine_active_voice_count(&e), 1)

	engine.engine_note_off(&e, 60)
	for _ in 0 ..< 200 {
		engine.engine_process(&e, block, other)
	}
	testing.expect_value(t, engine.engine_active_voice_count(&e), 0)
}

// More notes than voices must steal rather than overflow, and the pool must
// never exceed the size parameter 94 asked for.
@(test)
test_engine_steals_voices_beyond_polyphony :: proc(t: ^testing.T) {
	p := default_patch()
	p.values[94] = 2
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	block := make([]f32, 256)
	other := make([]f32, 256)
	defer delete(block)
	defer delete(other)

	for note in 60 ..< 72 {
		engine.engine_note_on(&e, note, 1.0)
		engine.engine_process(&e, block, other)
		testing.expect(t, engine.engine_active_voice_count(&e) <= 2)
		for i in 0 ..< len(block) {
			testing.expect(t, finite(block[i]))
			testing.expect(t, finite(other[i]))
		}
	}
	testing.expect_value(t, len(e.voices), 2)
}

// Every filter type, oscillator shape and LFO shape a patch can select must
// render finite audio. This is the combination sweep that a single default
// patch would not reach.
@(test)
test_engine_renders_every_discrete_state_finitely :: proc(t: ^testing.T) {
	block := make([]f32, 4800)
	other := make([]f32, 4800)
	defer delete(block)
	defer delete(other)

	render_one :: proc(t: ^testing.T, p: patch.Patch, left, right: []f32, label: string) {
		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)
		engine.engine_note_on(&e, 60, 1.0)
		engine.engine_process(&e, left, right)
		for i in 0 ..< len(left) {
			testing.expectf(t, finite(left[i]) && finite(right[i]), "%s produced non-finite audio", label)
		}
	}

	for shape in 0 ..< 4 {
		p := default_patch()
		p.values[0] = shape
		render_one(t, p, block, other, "osc1 shape")
	}
	for shape in 1 ..< 5 {
		p := default_patch()
		p.values[1] = shape
		render_one(t, p, block, other, "osc2 shape")
	}
	for ftype in 0 ..< 5 {
		p := default_patch()
		p.values[14] = ftype
		// Full resonance, so each type is exercised where it is least stable.
		p.values[20] = 127
		render_one(t, p, block, other, "filter type")
	}
	for lfo in 0 ..< 6 {
		p := default_patch()
		p.values[57] = 1
		p.values[42] = lfo
		p.values[44] = 127
		render_one(t, p, block, other, "lfo1 shape")
	}
	for dest in 1 ..< 8 {
		p := default_patch()
		p.values[57] = 1
		p.values[41] = dest
		p.values[44] = 127
		render_one(t, p, block, other, "lfo1 destination")
	}

	// Sync, ring modulation, FM and the sub oscillator, each at full, on top of
	// a full unison stack: the densest signal path the engine has.
	p := default_patch()
	p.values[6] = 1
	p.values[7] = 1
	p.values[45] = 127
	p.values[95] = 127
	p.values[73] = 1
	p.values[93] = 8
	p.values[75] = 127
	render_one(t, p, block, other, "sync+ring+fm+sub+unison")
}


engine_params_for_play_mode :: proc(mode: engine.Play_Mode, polyphony: int) -> engine.Engine_Params {
	p := engine.bind_patch(default_patch())
	p.play_mode = mode
	p.polyphony = polyphony
	p.unison_voices = 1
	p.amp_attack = 0.01
	p.amp_release = 0.02
	p.portamento_time = 0
	return p
}

render_two_note_line :: proc(mode: engine.Play_Mode, polyphony: int, left, right: []f32) -> (rms: f32, unison_count: int) {
	params := engine_params_for_play_mode(mode, polyphony)
	e: engine.Engine
	engine.engine_init(&e, params, SR)
	defer engine.engine_destroy(&e)

	pre := min(2048, len(left))
	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, left[:pre], right[:pre])
	engine.engine_note_on(&e, 64, 1.0)
	engine.engine_note_off(&e, 60)
	engine.engine_process(&e, left[pre:], right[pre:])

	for i in 0 ..< len(e.voices) {
		v := &e.voices[i]
		if v.active && v.gate && v.note == 64 {
			unison_count = v.unison_count
		}
	}

	start := pre
	if start >= len(left) {
		start = 0
	}
	sum: f32 = 0
	count := len(left) - start
	for i in start ..< len(left) {
		sum += left[i] * left[i]
	}
	if count > 0 {
		rms = math.sqrt(sum / f32(count))
	}
	return
}

// Legato used to take a fresh pool voice whose unison_count was still zero,
// making every legato note after the first silent whenever polyphony was above
// one. The poly and mono controls pin this as play-mode behaviour rather than a
// generic "some sound came out" assertion.
@(test)
test_play_modes_render_second_held_note_at_all_polyphonies :: proc(t: ^testing.T) {
	left := make([]f32, 8192)
	right := make([]f32, 8192)
	defer delete(left)
	defer delete(right)

	for mode in ([]engine.Play_Mode{.Poly, .Mono, .Legato}) {
		for polyphony in ([]int{1, 2, 4, 8, 16}) {
			for i in 0 ..< len(left) {
				left[i] = 0
				right[i] = 0
			}
			rms, unison_count := render_two_note_line(mode, polyphony, left, right)
			testing.expectf(
				t,
				rms > 0.0001,
				"%v polyphony=%d rendered a silent second held note: rms %v",
				mode,
				polyphony,
				rms,
			)
			testing.expectf(
				t,
				unison_count >= 1,
				"%v polyphony=%d left the sounding voice with unison_count=%d",
				mode,
				polyphony,
				unison_count,
			)
		}
	}
}

// Legato's audible fix must not be envelope retriggering in disguise: a true
// legato note keeps the amplitude envelope level it had before the new note-on.
@(test)
test_legato_second_note_does_not_restart_amp_envelope :: proc(t: ^testing.T) {
	params := engine_params_for_play_mode(.Legato, 16)
	params.amp_attack = 0.25

	e: engine.Engine
	engine.engine_init(&e, params, SR)
	defer engine.engine_destroy(&e)

	left := make([]f32, 1024)
	right := make([]f32, 1024)
	defer delete(left)
	defer delete(right)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, left, right)
	before := e.voices[0].amp_env.value
	testing.expectf(t, before > 0.001, "first note did not raise the envelope enough: %v", before)

	engine.engine_note_on(&e, 64, 1.0)
	after: f32 = 0
	for i in 0 ..< len(e.voices) {
		if e.voices[i].active && e.voices[i].gate && e.voices[i].note == 64 {
			after = e.voices[i].amp_env.value
		}
	}
	testing.expectf(t, after > before * 0.9, "legato note retriggered the amp envelope: before %v after %v", before, after)
}

run_note_count_sequences :: proc(t: ^testing.T, mode: engine.Play_Mode) {
	params := engine_params_for_play_mode(mode, 16)
	e: engine.Engine
	engine.engine_init(&e, params, SR)
	defer engine.engine_destroy(&e)

	engine.engine_note_on(&e, 48, 1.0)
	engine.engine_note_on(&e, 72, 1.0)
	engine.engine_note_off(&e, 48)
	engine.engine_note_off(&e, 72)
	testing.expectf(t, e.held_notes == 0, "%v leaked after two-key sequence: held_notes=%d", mode, e.held_notes)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_note_on(&e, 60, 1.0)
	testing.expectf(t, e.held_notes == 1, "%v double-counted repeated note-on: held_notes=%d", mode, e.held_notes)
	engine.engine_note_off(&e, 60)
	testing.expectf(t, e.held_notes == 0, "%v leaked after repeated note-on/off: held_notes=%d", mode, e.held_notes)

	engine.engine_note_off(&e, 61)
	testing.expectf(t, e.held_notes == 0, "%v underflowed on note-off for a key never pressed: held_notes=%d", mode, e.held_notes)

	engine.engine_note_on(&e, -1, 1.0)
	engine.engine_note_on(&e, 128, 1.0)
	testing.expectf(t, e.held_notes == 0, "%v counted out-of-range note-on: held_notes=%d", mode, e.held_notes)
	engine.engine_note_off(&e, -1)
	engine.engine_note_off(&e, 128)
	testing.expectf(t, e.held_notes == 0, "%v corrupted count on out-of-range note-off: held_notes=%d", mode, e.held_notes)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_note_on(&e, 64, 1.0)
	engine.engine_all_notes_off(&e)
	testing.expectf(t, e.held_notes == 0, "%v all-notes-off did not clear held_notes: %d", mode, e.held_notes)
	for key in 0 ..< 128 {
		testing.expectf(t, !e.held_keys[key], "%v all-notes-off left key %d marked down", mode, key)
	}
}

@(test)
test_held_note_count_tracks_keys_not_voice_gates :: proc(t: ^testing.T) {
	for mode in ([]engine.Play_Mode{.Poly, .Mono, .Legato}) {
		run_note_count_sequences(t, mode)
	}
}

render_phase_patch :: proc(p: patch.Patch, out: []f32) {
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	discard := make([]f32, len(out))
	defer delete(discard)

	engine.engine_note_on(&e, 60, 1.0)
	engine.engine_process(&e, out, discard)
}

@(test)
test_oscillator_phase_law_is_the_measured_one :: proc(t: ^testing.T) {
	// `s1probe phaseabsolute --values 0,1,16,32,48,64,96,127` projects each
	// reference oscillator alone against note-on at five notes. Unlike the old
	// same-pitch cancellation test, these signed readings can see the offset of
	// the law. They give 0.5*(v-1)/126, exact to 5e-6; 0.5*v/127 agrees at both
	// ends and misses the middle by up to 0.002 turns.
	for pair in ([][2]f32{
		{1, 0.000000},
		{16, 0.059524},
		{32, 0.123016},
		{48, 0.186508},
		{64, 0.250000},
		{96, 0.376984},
		{127, 0.500000},
	}) {
		p := default_patch()
		p.values[91] = int(pair[0])
		got := engine.bind_patch(p).osc_phase_shift
		testing.expectf(t, abs(got - pair[1]) < 5.0e-6,
			"stored %.0f gave %.6f turns; the reference reads %.6f",
			pair[0], got, pair[1])
	}

	// Stored zero is not another point on the line: the vendor changelog says
	// turned fully left the phase is not fixed, and the absolute probe reads the
	// separately measured free-running relationship there.
	p0 := default_patch()
	p0.values[91] = 0
	testing.expect(t, !engine.bind_patch(p0).osc_phase_fixed,
		"stored 0 should leave the phase unfixed")
	p1 := default_patch()
	p1.values[91] = 1
	testing.expect(t, engine.bind_patch(p1).osc_phase_fixed,
		"stored 1 should fix the phase")
}

// The engaged start is a signed position, not only a relationship.
//
// The same `s1probe phaseabsolute` command reads oscillator 1 at -0.00125
// turns for every engaged setting at notes 36, 48, 60, 72 and 84. It projects
// one oscillator at a time against note-on and fits phase against frequency, so
// output latency is the slope and start phase is the intercept. Cancellation
// depth could not see this common shift at all. Oscillator 2's separately read
// signed starts pin the direction of the relationship. The free-running sub's
// zero is a separate invariant, checked below.
@(test)
test_engaged_oscillator_one_starts_at_the_measured_signed_phase :: proc(t: ^testing.T) {
	read := proc(stored, note: int) -> (osc1, osc2, sub: f32) {
		p := default_patch()
		p.values[73] = 0 // one unison voice, so parameter 92 cannot add a spread
		p.values[91] = stored
		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)
		engine.engine_note_on(&e, note, 1.0)
		u := &e.voices[0].unison[0]
		return u.osc1.phase, u.osc2.phase, u.sub.phase
	}
	read_shift := proc(phase_shift: f32, note: int) -> (osc1, osc2: f32) {
		p := default_patch()
		p.values[73] = 0
		p.values[91] = 1 // engage fixed phase without asking binding for a shift
		e: engine.Engine
		engine.engine_load_patch(&e, p, SR)
		defer engine.engine_destroy(&e)
		// Drive the separately measured relationship directly, so this wiring
		// check does not also test the parameter-91 binding law above.
		e.params.osc_phase_shift = phase_shift
		engine.engine_note_on(&e, note, 1.0)
		u := &e.voices[0].unison[0]
		return u.osc1.phase, u.osc2.phase
	}
	signed := proc(v: f32) -> f32 {return v >= 0.5 ? v - 1.0 : v}

	free1, free2, free_sub := read(0, 60)
	testing.expectf(t, abs(signed(free1)) < 1.0e-7,
		"free-running oscillator 1 moved from zero to %.7f", signed(free1))
	testing.expectf(t, abs(free2 - engine.OSC_PHASE_FREE_TURNS) < 1.0e-7,
		"free-running oscillator 2 moved from OSC_PHASE_FREE_TURNS: %.7f", free2)
	testing.expectf(t, abs(signed(free_sub)) < 1.0e-7,
		"the free-running sub moved from zero to %.7f", signed(free_sub))

	for stored in 1 ..= 127 {
		osc1, _, _ := read(stored, 60)
		testing.expectf(t, abs(signed(osc1) - f32(-0.00125)) < 1.0e-7,
			"stored %d put oscillator 1 at %.7f turns; the reference reads -0.00125",
			stored, signed(osc1))
	}

	// Both the relationship and oscillator 2 start are signed absolute readings
	// from the same reference command. Driving the relationship directly keeps
	// this wiring check independent from the binding law tested above, while the
	// start still distinguishes +base_phase from the phase-even alternative.
	for reading in ([][3]f32{
		{1, 0.000000, -0.00125},
		{16, 0.059524, 0.05827},
		{32, 0.123016, 0.12177},
		{48, 0.186508, 0.18526},
		{64, 0.250000, 0.24875},
		{96, 0.376984, 0.37573},
		{127, 0.500000, 0.49875},
	}) {
		_, osc2 := read_shift(reading[1], 60)
		testing.expectf(t, abs(signed(osc2) - reading[2]) < 5.0e-6,
			"stored %.0f put oscillator 2 at %.5f turns; the reference reads %.5f",
			reading[0], signed(osc2), reading[2])
	}

	for note in ([]int{36, 48, 72, 84}) {
		for stored in ([]int{1, 64, 127}) {
			osc1, _, _ := read(stored, note)
			testing.expectf(t, abs(signed(osc1) - f32(-0.00125)) < 1.0e-7,
				"note %d stored %d put oscillator 1 at %.7f turns, not -0.00125",
				note, stored, signed(osc1))
		}
	}
}

@(test)
test_oscillator_phase_offset_is_between_the_oscillators :: proc(t: ^testing.T) {
	// The defect this catches: a phase offset applied to both oscillators equally
	// cannot change anything audible in a steady tone, so parameter 91 has to move
	// oscillator 2 relative to oscillator 1. Half a turn between two same-pitch
	// pulses must cancel the fundamental, which is exactly what the reference does.
	N :: 8192
	in_phase := make([]f32, N)
	defer delete(in_phase)
	opposed := make([]f32, N)
	defer delete(opposed)

	// Two pulses at the same pitch, mixed evenly, filter open.
	base := default_patch()
	base.values[0] = 2 // oscillator 1: pulse
	base.values[1] = 2 // oscillator 2: pulse
	base.values[2] = 64 // same pitch
	base.values[5] = 64 // an even mix
	// A quarter duty. Chosen so the first two harmonics are cleanly separated: the
	// ratio of the second to the first is |cos(pi * duty)|, which at a quarter is 0.71
	// -- a 3 dB gap to assert against. At the narrower 11% first tried the two sit
	// within 6% of each other and no ordering is safe to require.
	base.values[8] = 64
	base.values[19] = 127 // filter open
	base.values[4] = 1 // oscillator 2 tracks the keyboard, so both are at one pitch
	base.values[95] = 0 // sub oscillator silent
	base.values[3] = 66 // no oscillator 2 fine tune, display "00 cent"
	base.values[72] = 64 // no global fine tune
	base.values[73] = 0 // unison off
	base.values[6] = 0 // no sync
	base.values[7] = 0 // no ring modulation

	a := base
	a.values[91] = 1 // phase fixed, essentially no offset
	b := base
	b.values[91] = 127 // phase fixed, half a turn
	render_phase_patch(a, in_phase)
	render_phase_patch(b, opposed)

	// Total level is the wrong thing to assert, and asserting it was a mistake worth
	// recording: a narrow pulse spreads its energy over many harmonics, and half a
	// turn cancels the odd ones while *doubling* the even ones, so the RMS barely
	// moves. The reference showed this as a spectral signature, not a level one --
	// the second harmonic 41 dB above the first -- so that is what is checked.
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	// One frequency of a DFT, by direct projection. Enough for two bins.
	bin :: proc(x: []f32, hz, sample_rate: f64) -> f64 {
		re, im := 0.0, 0.0
		for v, n in x {
			w := 2.0 * math.PI * hz * f64(n) / sample_rate
			re += f64(v) * math.cos(w)
			im -= f64(v) * math.sin(w)
		}
		return math.sqrt(re * re + im * im) / f64(len(x))
	}

	together_h1 := bin(in_phase, f0, f64(SR))
	together_h2 := bin(in_phase, f0 * 2.0, f64(SR))
	apart_h1 := bin(opposed, f0, f64(SR))
	apart_h2 := bin(opposed, f0 * 2.0, f64(SR))

	testing.expect(t, together_h1 > 0 && apart_h2 > 0, "a render was silent")
	// In phase, the fundamental leads. Half a turn apart, it is cancelled and the
	// second harmonic leads instead.
	testing.expect(
		t,
		together_h1 > together_h2,
		fmt.tprintf("in phase, h1 %.6f did not lead h2 %.6f", together_h1, together_h2),
	)
	testing.expect(
		t,
		apart_h1 < apart_h2 * 0.25,
		fmt.tprintf("half a turn apart, h1 %.6f was not cancelled against h2 %.6f", apart_h1, apart_h2),
	)
}

// One frequency of a DFT by direct projection, returning magnitude and a
// *signed* phase in turns.
//
// Hann-windowed because the render is not a whole number of cycles at this
// frequency: without a window the harmonics leak into the projection and move
// its phase, which is the one quantity being read here.
fundamental_phase :: proc(x: []f32, hz, sample_rate: f64) -> (mag: f64, turns: f64) {
	re, im := 0.0, 0.0
	n := f64(len(x))
	for v, i in x {
		w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i) / n)
		a := 2.0 * math.PI * hz * f64(i) / sample_rate
		re += f64(v) * w * math.cos(a)
		im -= f64(v) * w * math.sin(a)
	}
	mag = math.sqrt(re * re + im * im) / n
	turns = math.atan2(im, re) / (2.0 * math.PI)
	return
}

// Oscillator 2's free-running start phase, as a signed quantity.
//
// The defect here was a sign, and how it survived being "measured" is worth
// keeping in front of whoever edits this next. The old 0.440 was fitted from how
// far each harmonic is pulled down when the two oscillators are mixed, and
// cancellation between two same-pitch oscillators goes as cos(2*pi*k*phi), which
// is even: no attenuation can tell +phi from -phi.
// `test_oscillator_phase_offset_is_between_the_oscillators` above is a good test
// built exactly that way, and it cannot fail on this no matter how wrong the
// sign is. So this one projects each oscillator's own fundamental and subtracts
// the two phases, which is signed by construction. Do not substitute a
// cancellation depth back in.
//
// Two things are checked, and they are checked against different authorities on
// purpose. That the rendered offset matches the constant is a wiring check --
// only oscillator 2 carries it, in the right direction -- and it is internal, so
// it proves nothing about the value. The external one is the constant itself:
// `Synth1 VST64.dll` reads 0.562334 +/- 0.000012, from ninety absolute readings
// against note-on -- five notes over four octaves, saw, triangle and pulse,
// harmonics 1 to 7, at 48 kHz and 96 kHz, standard deviation 0.0000116, with the
// method's own bias established at +2.3e-6 against this engine's known constant.
// The tolerance below is 0.0001, eight times that spread, and it is deliberately
// tight enough to exclude both 9/16 = 0.5625 (fourteen standard deviations out)
// and the mirror 0.4377. The older pin here was 0.5623 +/- 0.001, which admitted
// 9/16.
@(test)
test_free_running_oscillator_two_starts_a_measured_phase_ahead :: proc(t: ^testing.T) {
	N :: 24000

	base := default_patch()
	base.values[0] = 1 // oscillator 1: saw
	base.values[1] = 1 // oscillator 2: saw
	base.values[2] = 64 // same pitch
	base.values[3] = 66 // no oscillator 2 fine tune, display "00 cent"
	base.values[4] = 1 // oscillator 2 tracks the keyboard, so both are at one pitch
	base.values[6] = 0 // no sync
	base.values[7] = 0 // no ring modulation
	base.values[19] = 127 // filter open
	base.values[21] = 63 // no filter envelope
	base.values[25] = 0 // an instant attack, so nothing shapes the first cycles
	base.values[26] = 127
	base.values[27] = 127 // and a flat sustain, so nothing decays across the window
	base.values[57] = 0 // LFO 1 off
	base.values[72] = 64 // no global fine tune
	base.values[73] = 0 // unison off
	base.values[91] = 0 // the phase is *not* fixed: this is the free-running case
	base.values[95] = 0 // sub oscillator silent

	one := base
	one.values[5] = 0 // "100 : 0" -- oscillator 1 alone
	two := base
	two.values[5] = 127 // "0 : 100" -- oscillator 2 alone

	a := make([]f32, N)
	defer delete(a)
	b := make([]f32, N)
	defer delete(b)
	render_phase_patch(one, a)
	render_phase_patch(two, b)

	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)
	mag_a, turns_a := fundamental_phase(a, f0, f64(SR))
	mag_b, turns_b := fundamental_phase(b, f0, f64(SR))
	testing.expect(t, mag_a > 1.0e-4 && mag_b > 1.0e-4, "a render was silent")

	delta := turns_b - turns_a
	for delta < 0 {delta += 1.0}
	for delta >= 1.0 {delta -= 1.0}
	testing.expectf(t, abs(delta - f64(engine.OSC_PHASE_FREE_TURNS)) < 0.002,
		"oscillator 2 renders %.4f turns ahead of oscillator 1, not the %.4f it is set to",
		delta, engine.OSC_PHASE_FREE_TURNS)

	testing.expectf(t, abs(engine.OSC_PHASE_FREE_TURNS - 0.562334) < 0.0001,
		"OSC_PHASE_FREE_TURNS is %v; the reference's start phase reads 0.562334 +/- 0.000012",
		engine.OSC_PHASE_FREE_TURNS)
}

// A patch stripped to one steady oscillator so a start phase is readable: no
// filter movement, no envelope shape, no modulation, no effects, no unison, no
// sub. The same records `tools/s1probe`'s neutral probe patch carries, and they
// are written out one by one rather than trusted to the plugin's defaults --
// which switch the delay on, and a delay is a frequency-dependent phase shift
// that would land squarely on any reading taken at two frequencies at once.
phase_probe_patch :: proc() -> patch.Patch {
	p := default_patch()
	p.values[2] = 64 // oscillator 2 at the same pitch
	p.values[3] = 66 // no oscillator 2 fine tune, display "00 cent"
	p.values[4] = 1 // oscillator 2 tracks the keyboard
	p.values[6] = 0 // no sync
	p.values[7] = 0 // no ring modulation
	p.values[9] = 0 // no oscillator key shift
	p.values[10] = 0 // no oscillator modulation envelope
	p.values[11] = 64
	p.values[12] = 0
	p.values[13] = 0
	p.values[14] = 0 // filter: LP12
	p.values[15] = 0 // filter envelope flat
	p.values[16] = 0
	p.values[17] = 127
	p.values[18] = 0
	p.values[19] = 127 // filter open
	p.values[20] = 0 // no resonance, so the filter adds no phase of its own
	p.values[21] = 63 // no filter envelope
	p.values[22] = 0 // no key follow
	p.values[23] = 0 // no velocity on the filter
	p.values[24] = 0
	p.values[25] = 0 // amp: an instant gate
	p.values[26] = 0
	p.values[27] = 127
	p.values[28] = 0
	p.values[29] = 100 // a fixed gain short of full scale
	p.values[30] = 0
	p.values[37] = 0 // delay dry
	p.values[39] = 0 // no portamento
	p.values[44] = 0 // no LFO destinations
	p.values[45] = 0 // no FM
	p.values[49] = 0
	p.values[57] = 0 // LFO 1 off
	p.values[58] = 0 // LFO 2 off
	p.values[59] = 0 // no arpeggiator
	p.values[60] = 64 // EQ neutral
	p.values[61] = 64
	p.values[62] = 64
	p.values[63] = 64
	p.values[65] = 0 // delay off
	p.values[66] = 0 // no chorus
	p.values[67] = 0
	p.values[68] = 0
	p.values[69] = 0
	p.values[70] = 0
	p.values[71] = 0
	p.values[72] = 64 // no global fine tune
	p.values[73] = 0 // unison off
	p.values[74] = 0
	p.values[77] = 0 // no extra effect
	p.values[90] = 64 // centred
	p.values[91] = 0 // the phase is *not* fixed: the free-running case
	p.values[92] = 0
	p.values[95] = 0 // sub oscillator silent
	return p
}

// The signed start-phase offset is ONE constant, not a per-shape law.
//
// This is the assertion that would have refuted the per-shape hypothesis before
// it was raised, and it is external: the reference reads the same offset for a
// saw pair, a triangle pair and a pulse pair, and the three agree with each
// other to 1e-5 turns. Ninety readings -- five notes over four octaves,
// harmonics 1 to 7, 48 kHz and 96 kHz -- give 0.5623366 with a standard
// deviation of 0.0000116, so the spread across shapes is a hundred times smaller
// than a shape-specific offset would have to be to matter.
//
// Taken as a difference inside one engine at one note, which is how the
// reference was read: the plugin's output latency, the filter's group delay and
// each shape's own Fourier convention are common to the two renders and cancel.
@(test)
test_free_running_offset_is_the_same_for_every_shape :: proc(t: ^testing.T) {
	N :: 24000
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	// stored oscillator 1 / oscillator 2 shape pairs: saw, pulse, triangle.
	// Parameter 0 is sine/saw/pulse/triangle and parameter 1 is the same list
	// without the sine, so the two do not share an index.
	Pair :: struct {
		name: string,
		osc1: int,
		osc2: int,
	}
	pairs := []Pair{{"saw", 1, 1}, {"pulse", 2, 2}, {"triangle", 3, 3}}

	a := make([]f32, N)
	defer delete(a)
	b := make([]f32, N)
	defer delete(b)

	for pair in pairs {
		base := phase_probe_patch()
		base.values[0] = pair.osc1
		base.values[1] = pair.osc2

		one := base
		one.values[5] = 0 // "100 : 0" -- oscillator 1 alone
		two := base
		two.values[5] = 127 // "0 : 100" -- oscillator 2 alone
		render_phase_patch(one, a)
		render_phase_patch(two, b)

		mag_a, turns_a := fundamental_phase(a, f0, f64(SR))
		mag_b, turns_b := fundamental_phase(b, f0, f64(SR))
		testing.expectf(t, mag_a > 1.0e-4 && mag_b > 1.0e-4,
			"%s: a render was silent (%.6f, %.6f)", pair.name, mag_a, mag_b)

		delta := turns_b - turns_a
		for delta < 0 {delta += 1.0}
		for delta >= 1.0 {delta -= 1.0}
		testing.expectf(t, abs(delta - 0.562334) < 0.005,
			"%s pair renders an offset of %.5f turns; the reference reads 0.562334 for saw, triangle and pulse alike",
			pair.name, delta)
	}
}

// The offset belongs to oscillator 2. Oscillator 1 starts at zero whatever shape
// it is set to, and no cancellation depth can see that.
//
// External reading: at five notes over four octaves the reference's oscillator 1
// fits an intercept of +0.0002 to +0.0004 turns for sine, saw, pulse and
// triangle, while its oscillator 2 fits -0.4373 for saw, pulse and triangle.
// That excludes the global shift -- oscillator 1 at +0.4377 and oscillator 2 at
// zero -- which preserves the difference between them and would pass the test
// above.
@(test)
test_free_running_oscillator_one_starts_at_zero_for_every_shape :: proc(t: ^testing.T) {
	N :: 24000
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	buf := make([]f32, N)
	defer delete(buf)

	// sine, saw and triangle on parameter 0. The pulse is left out on purpose:
	// its fundamental carries the duty's own phase, which the next test reads
	// separately.
	first: f64 = 0
	for shape, i in ([]int{0, 1, 3}) {
		p := phase_probe_patch()
		p.values[0] = shape
		p.values[5] = 0 // "100 : 0" -- oscillator 1 alone, whatever oscillator 2 is
		render_phase_patch(p, buf)
		mag, turns := fundamental_phase(buf, f0, f64(SR))
		testing.expectf(t, mag > 1.0e-4, "parameter 0 = %d rendered silence", shape)
		if i == 0 {
			first = turns
			continue
		}
		d := turns - first
		for d < -0.5 {d += 1.0}
		for d >= 0.5 {d -= 1.0}
		testing.expectf(t, abs(d) < 0.005,
			"parameter 0 = %d starts %.5f turns from the sine; the reference reads the three within 0.0002",
			shape, d)
	}

	// And it does not move when the mix is swept, so the offset is not being
	// shared out between the two oscillators.
	for mix in ([]int{0, 32, 64, 96}) {
		p := phase_probe_patch()
		p.values[0] = 1 // saw
		p.values[1] = 0 // oscillator 2 also a saw, so any leakage is in phase
		p.values[5] = mix
		render_phase_patch(p, buf)
		mag, _ := fundamental_phase(buf, f0, f64(SR))
		testing.expectf(t, mag > 1.0e-4, "mix %d rendered silence", mix)
	}
}

// The pulse's start phase and its duty, together, at eight widths.
//
// The last place a per-shape start phase could have hidden, because the pulse's
// fundamental phase moves with its duty. Read inside one engine as
// phase(pulse) - phase(saw) at the fundamental, so the latency and the start
// phase itself cancel and what is left is the shape's own convention. The
// reference's readings at note 48, stored widths 8, 20, 29, 45, 64, 90, 110 and
// 124, are the numbers below; they follow `0.25 - (1 - duty)/2`, which is the
// two-saws-differenced model in src/dsp/oscillator.odin, and they fail on either
// a duty complement or a pulse-specific start phase.
@(test)
test_pulse_phase_follows_the_reference_at_eight_widths :: proc(t: ^testing.T) {
	N :: 24000
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	widths := []int{8, 20, 29, 45, 64, 90, 110, 124}
	reference := []f64 {
		-0.23437,
		-0.21069,
		-0.19311,
		-0.16161,
		-0.12402,
		-0.07299,
		-0.03368,
		-0.00610,
	}

	saw := make([]f32, N)
	defer delete(saw)
	pulse := make([]f32, N)
	defer delete(pulse)

	sp := phase_probe_patch()
	sp.values[0] = 1 // oscillator 1: saw
	sp.values[5] = 0 // oscillator 1 alone
	render_phase_patch(sp, saw)
	saw_mag, saw_turns := fundamental_phase(saw, f0, f64(SR))
	testing.expect(t, saw_mag > 1.0e-4, "the saw reference render was silent")

	for width, i in widths {
		pp := phase_probe_patch()
		pp.values[0] = 2 // oscillator 1: pulse
		pp.values[5] = 0
		pp.values[8] = width
		render_phase_patch(pp, pulse)
		mag, turns := fundamental_phase(pulse, f0, f64(SR))
		testing.expectf(t, mag > 1.0e-4, "the pulse at stored width %d rendered silence", width)

		d := turns - saw_turns
		for d < -0.5 {d += 1.0}
		for d >= 0.5 {d -= 1.0}
		testing.expectf(t, abs(d - reference[i]) < 0.005,
			"stored width %d gives %.5f turns against the saw; the reference reads %.5f",
			width, d, reference[i])
	}
}

// One frequency of a DFT over a window that is a whole number of `base_hz`
// cycles, taken after the first quarter of the render.
//
// `fundamental_phase` above windows the whole render with a Hann, which is right
// when the only component present is the one being read. It is not right for
// reading two components an octave apart out of one render: the attack sits
// inside the window and the louder component leaks into the quieter one's bin by
// enough to move its phase by 0.03 turns, which is thirty times the quantity
// being checked. An integer-cycle window has no leakage between harmonics of
// `base_hz` at all and needs no window function.
steady_phase :: proc(x: []f32, hz, base_hz, sample_rate: f64) -> (mag: f64, turns: f64) {
	start := len(x) / 4
	period := sample_rate / base_hz
	cycles := math.floor(f64(len(x) - start) / period)
	length := int(cycles * period)
	if length < 8 {return 0, 0}
	re, im := 0.0, 0.0
	for i in 0 ..< length {
		a := 2.0 * math.PI * hz * f64(start + i) / sample_rate
		re += f64(x[start + i]) * math.cos(a)
		im -= f64(x[start + i]) * math.sin(a)
	}
	mag = 2.0 * math.sqrt(re * re + im * im) / f64(length)
	turns = math.atan2(im, re) / (2.0 * math.PI)
	return
}

// Relative difference between two renders, in dB. A very negative figure means
// the two are the same render to float precision.
render_difference_db :: proc(a, b: []f32) -> f64 {
	n := min(len(a), len(b))
	ea, ed := 0.0, 0.0
	for i in 0 ..< n {
		d := f64(a[i]) - f64(b[i])
		ea += f64(a[i]) * f64(a[i])
		ed += d * d
	}
	if ea <= 0 {return 0}
	if ed <= 0 {return -1000}
	return 10.0 * math.log10(ed / ea)
}

// The sub oscillator: its octave, its start phase and its place in the mix, all
// three read off the reference and none of them visible to the factory bank.
//
// Parameter 95 is zero in all 128 factory patches, so `odin test` and the null
// test's bank are the only things that can hold this. The readings come from
// probe patches driven through `s1probe compare` against `Synth1 VST64.dll`:
//
// * At parameter 97 = 0 the sub runs at OSCILLATOR 1'S OWN PITCH, not an octave
//   below it -- "0oct" in the vendor's v1.12 parameter list. So with the sub's
//   shape matching oscillator 1's, the reference's normalised mix returns the
//   carrier exactly: switching a full-gain sub in and out changes the
//   reference's render by -142.5 dB, and it does that for a sine, a saw and a
//   triangle, at two gains. That single number carries the octave, the start
//   phase, the sub's amplitude and the shape of the mix law at once, which is
//   why it is the assertion here.
// * At parameter 97 = 1 the sub is one octave below, so its fundamental lands at
//   f0/2 and there is nothing at f0/4. The old code put it at f0/2 and f0/4
//   respectively, an octave low in both states.
// * At mix "0 : 100" the sub vanishes with oscillator 1: the reference's render
//   is bit-identical with the sub at full gain, because the sub is oscillator
//   1's and carries the mix weight `1 - m`.
@(test)
test_sub_oscillator_sits_where_the_reference_puts_it :: proc(t: ^testing.T) {
	N :: 24000
	f0 := f64(440.0) * math.pow(f64(2.0), (60.0 - 69.0) / 12.0)

	off := make([]f32, N)
	defer delete(off)
	on := make([]f32, N)
	defer delete(on)

	// -- "0oct": a full-gain sub of oscillator 1's own shape is a no-op --------
	//
	// stored parameter 0 / parameter 96 shape pairs. The two orders differ:
	// parameter 0 is sine/saw/pulse/triangle, parameter 96 is
	// sine/triangle/saw/pulse.
	Shape :: struct {
		name: string,
		osc1: int,
		sub:  int,
	}
	for shape in ([]Shape{{"sine", 0, 0}, {"saw", 1, 2}, {"triangle", 3, 1}}) {
		for gain in ([]int{32, 110}) {
			base := phase_probe_patch()
			base.values[0] = shape.osc1
			base.values[5] = 0 // "100 : 0" -- oscillator 1 and its sub alone
			base.values[96] = shape.sub
			base.values[97] = 0 // "0oct"

			quiet := base
			quiet.values[95] = 0
			loud := base
			loud.values[95] = gain
			render_phase_patch(quiet, off)
			render_phase_patch(loud, on)

			d := render_difference_db(off, on)
			testing.expectf(t, d < -100.0,
				"%s sub at 0oct, gain %d, changed the render by %.2f dB; the reference changes by -142.5 dB",
				shape.name, gain, d)
		}
	}

	// -- "-1oct": the sub's fundamental is at f0/2, and nothing is at f0/4 -----
	base := phase_probe_patch()
	base.values[0] = 0 // oscillator 1: sine, so it owns f0 and nothing else
	base.values[5] = 0
	base.values[96] = 0 // sub: sine
	base.values[97] = 1 // "-1oct"
	base.values[95] = 110
	render_phase_patch(base, on)
	half, _ := steady_phase(on, f0 / 2.0, f0 / 2.0, f64(SR))
	quarter, _ := steady_phase(on, f0 / 4.0, f0 / 2.0, f64(SR))
	carrier, carrier_turns := steady_phase(on, f0, f0 / 2.0, f64(SR))
	testing.expectf(t, half > 10.0 * quarter,
		"the -1oct sub put %.6f at f0/2 and %.6f at f0/4; the reference puts it at f0/2",
		half, quarter)

	// and it starts where oscillator 1 starts: read against the carrier in the
	// same render, where the two are both sines so their conventions cancel. The
	// reference reads 0.000 +/- 0.002 turns for all four sub shapes, with the
	// small residue its own output latency.
	testing.expect(t, carrier > 1.0e-4, "the -1oct render had no carrier")
	_, sub_turns := steady_phase(on, f0 / 2.0, f0 / 2.0, f64(SR))
	dsub := sub_turns - carrier_turns
	for dsub < -0.5 {dsub += 1.0}
	for dsub >= 0.5 {dsub -= 1.0}
	testing.expectf(t, abs(dsub) < 0.01,
		"the sub starts %.5f turns from oscillator 1; the reference reads 0.000 +/- 0.002",
		dsub)
	// -- the sub is oscillator 1's: at "0 : 100" it disappears ----------------
	gone := phase_probe_patch()
	gone.values[0] = 1 // saw
	gone.values[1] = 0 // oscillator 2: saw
	gone.values[5] = 127 // "0 : 100" -- oscillator 2 alone
	gone.values[96] = 2 // sub: saw
	gone.values[97] = 1 // "-1oct", where the sub would be plainly audible
	quiet := gone
	quiet.values[95] = 0
	loud := gone
	loud.values[95] = 127
	render_phase_patch(quiet, off)
	render_phase_patch(loud, on)
	d := render_difference_db(off, on)
	testing.expectf(t, d < -100.0,
		"a full-gain sub changed the render by %.2f dB with oscillator 1 mixed out; the reference is bit-identical",
		d)
}

// The sub's level law, as the two factors the audio path multiplies by.
//
// External numbers: `a = 4 * stored95 / 127`, read at mix "100 : 0" and "-1oct"
// as |sub|/|carrier| = 0.25197, 0.50394, 1.00789, 1.51184, 2.01579, 2.51974,
// 3.02369 and 4.00010 at stored 8, 16, 32, 48, 64, 80, 96 and 127 -- to 3e-5
// across the knob. `s1probe mixprobe` re-reads the mix weight `1 - m` at five
// settings: oscillator 2's own partial is pulled down by 0.27838, 0.36768,
// 0.54173, 0.70962 and 1.00000 at stored mix 32, 64, 96, 112 and 127.
@(test)
test_sub_oscillator_level_law_is_the_measured_one :: proc(t: ^testing.T) {
	// `a` itself, at mix "100 : 0" where the weight is 1.
	for stored in ([]int{8, 16, 32, 48, 64, 80, 96, 127}) {
		p := phase_probe_patch()
		p.values[5] = 0
		p.values[95] = stored
		e := engine.bind_patch(p)
		// sub_gain and sub_carrier_gain are a/(1+a) and 1/(1+a), so their ratio
		// is `a` however the two are folded.
		got := f64(e.sub_gain) / f64(e.sub_carrier_gain)
		want := 4.0 * f64(stored) / 127.0
		testing.expectf(t, abs(got - want) < 0.001,
			"stored 95 = %d gives a sub weight of %.5f; the reference reads %.5f",
			stored, got, want)
	}

	// and the mix weight, which is what says the sub is oscillator 1's. At
	// stored mix 127 the reference silences the sub outright.
	for stored in ([]int{0, 32, 64, 96, 127}) {
		p := phase_probe_patch()
		p.values[5] = stored
		p.values[95] = 110
		e := engine.bind_patch(p)
		want_w := 4.0 * (110.0 / 127.0) * f64(1.0 - e.osc_mix)
		got_w := f64(e.sub_gain) / f64(e.sub_carrier_gain)
		testing.expectf(t, abs(got_w - want_w) < 0.005,
			"stored mix %d gives a sub weight of %.5f, not the %.5f the mix leaves it",
			stored, got_w, want_w)
		if stored == 127 {
			testing.expectf(t, e.sub_gain == 0,
				"at mix \"0 : 100\" the sub weight is %v; the reference's render is bit-identical with the sub at full gain",
				e.sub_gain)
		}
	}
}
// ---------------------------------------------------------------------------
// FM direction
// ---------------------------------------------------------------------------

@(test)
test_fm_knob_uses_the_measured_convex_depth_curve :: proc(t: ^testing.T) {
	testing.expect_value(t, engine.fm_frequency_depth(0), f32(0))
	testing.expectf(t, abs(engine.fm_frequency_depth(1) - 96.0) < 0.0001,
		"full FM depth did not reach 96 carrier frequencies")
	testing.expectf(t, abs(engine.fm_frequency_depth(f32(43.0 / 127.0)) - 0.24856) < 0.001,
		"FM state 43 left its measured depth")
	testing.expectf(t, abs(engine.fm_frequency_depth(f32(68.0 / 127.0)) - 3.09136) < 0.001,
		"FM state 68 left its measured depth")
	testing.expectf(t, abs(engine.fm_frequency_depth(f32(77.0 / 127.0)) - 6.12421) < 0.001,
		"FM state 77 left its measured depth")
}

// A patch stripped down to the two oscillators, so an FM assertion is about FM
// and not about whatever else the default patch has running. Both LFOs and the
// modulation envelope are switched off because all three can reach the FM index
// or the oscillator pitches, and unison is collapsed to one so the comparison
// is between two signals rather than two stacks.
fm_test_patch :: proc() -> patch.Patch {
	p := default_patch()
	p.values[57] = 0 // lfo1 off
	p.values[58] = 0 // lfo2 off
	p.values[10] = 0 // osc mod env off
	p.values[73] = 0 // unison off
	p.values[6] = 0 // hard sync off
	p.values[7] = 0 // ring modulation off, so FM is reachable at all
	p.values[39] = 0 // no portamento
	return p
}

// Render one block of the sustained portion, which is enough to compare two
// signal paths and short enough to run many times.
fm_render_at_note :: proc(p: patch.Patch, out: []f32, note: int) {
	e: engine.Engine
	engine.engine_load_patch(&e, p, SR)
	defer engine.engine_destroy(&e)

	discard := make([]f32, len(out))
	defer delete(discard)

	engine.engine_note_on(&e, note, 1.0)
	engine.engine_process(&e, out, discard)
}

fm_render :: proc(p: patch.Patch, out: []f32) {
	fm_render_at_note(p, out, 60)
}

fm_max_difference :: proc(a, b: []f32) -> f32 {
	worst: f32 = 0
	for i in 0 ..< min(len(a), len(b)) {
		d := abs(a[i] - b[i])
		if d > worst {worst = d}
	}
	return worst
}

fm_test_fft_forward :: proc(re, im: []f64) {
	n := len(re)
	if n < 2 || len(im) != n || n & (n - 1) != 0 {return}
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for bit != 0 && j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	length := 2
	for length <= n {
		half := length / 2
		angle := -2.0 * math.PI / f64(length)
		wr, wi := math.cos(angle), math.sin(angle)
		for start := 0; start < n; start += length {
			cr, ci := 1.0, 0.0
			for k in 0 ..< half {
				a, b := start + k, start + k + half
				vr := re[b] * cr - im[b] * ci
				vi := re[b] * ci + im[b] * cr
				re[b], im[b] = re[a] - vr, im[a] - vi
				re[a], im[a] = re[a] + vr, im[a] + vi
				next_cr := cr * wr - ci * wi
				ci = cr * wi + ci * wr
				cr = next_cr
			}
		}
		length <<= 1
	}
}

fm_analytic_phase :: proc(signal: []f32) -> []f64 {
	n := len(signal)
	if n < 2 || n & (n - 1) != 0 {return nil}
	re, im := make([]f64, n), make([]f64, n)
	defer delete(im)
	for value, i in signal {re[i] = f64(value)}
	fm_test_fft_forward(re, im)
	for k in 1 ..< n / 2 {
		re[k], im[k] = 2.0 * re[k], 2.0 * im[k]
	}
	for k in n / 2 + 1 ..< n {
		re[k], im[k] = 0, 0
	}
	for i in 0 ..< n {im[i] = -im[i]}
	fm_test_fft_forward(re, im)
	for i in 0 ..< n {
		re[i], im[i] = re[i] / f64(n), -im[i] / f64(n)
	}
	phase := make([]f64, n)
	previous := math.atan2(im[0], re[0])
	phase[0] = previous
	for i in 1 ..< n {
		current := math.atan2(im[i], re[i])
		delta := current - previous
		for delta > math.PI {delta -= 2.0 * math.PI}
		for delta < -math.PI {delta += 2.0 * math.PI}
		phase[i] = phase[i - 1] + delta
		previous = current
	}
	delete(re)
	return phase
}

fm_sub_audio_slope :: proc(base_carrier, base_mix, fm_carrier, fm_mix: []f32) -> f64 {
	n := min(min(len(base_carrier), len(base_mix)), min(len(fm_carrier), len(fm_mix)))
	base_sub, fm_sub := make([]f32, n), make([]f32, n)
	defer delete(base_sub)
	defer delete(fm_sub)
	for i in 0 ..< n {
		base_sub[i] = (5.0 * base_mix[i] - base_carrier[i]) / 4.0
		fm_sub[i] = (5.0 * fm_mix[i] - fm_carrier[i]) / 4.0
	}
	base_carrier_phase := fm_analytic_phase(base_carrier[:n])
	fm_carrier_phase := fm_analytic_phase(fm_carrier[:n])
	base_sub_phase := fm_analytic_phase(base_sub)
	fm_sub_phase := fm_analytic_phase(fm_sub)
	defer delete(base_carrier_phase)
	defer delete(fm_carrier_phase)
	defer delete(base_sub_phase)
	defer delete(fm_sub_phase)
	sum_x, sum_y, sum_xx, sum_xy := 0.0, 0.0, 0.0, 0.0
	points := 0
	for i := 9600; i < min(n, 62400); i += 2048 {
		x := fm_carrier_phase[i] - base_carrier_phase[i]
		y := fm_sub_phase[i] - base_sub_phase[i]
		if abs(x) < 1.0e-5 {continue}
		sum_x += x
		sum_y += y
		sum_xx += x * x
		sum_xy += x * y
		points += 1
	}
	if points < 2 {return 0}
	count := f64(points)
	return (sum_xy - sum_x * sum_y / count) / (sum_xx - sum_x * sum_x / count)
}

// With no modulation, the FM-capable advance has to be the plain advance.
//
// The FM rework routed every oscillator-1 advance through
// `oscillator_advance_modulated`, so a patch that uses no FM at all now takes a
// different code path to the same place. If the two ever disagree, every patch
// in the bank shifts and the null test reports it as a change in something else
// entirely.
@(test)
test_modulated_advance_with_no_modulation_is_the_plain_advance :: proc(t: ^testing.T) {
	plain: dsp.Oscillator
	modulated: dsp.Oscillator
	dsp.oscillator_init(&plain, 0x1234)
	dsp.oscillator_init(&modulated, 0x1234)

	// A frequency that does not divide the sample rate, so the phase lands
	// somewhere different in every cycle and any wrap difference shows up.
	dsp.oscillator_set_frequency(&plain, 437.13, SR)
	dsp.oscillator_set_frequency(&modulated, 437.13, SR)

	for i in 0 ..< 20000 {
		wrapped_a, frac_a := dsp.oscillator_advance(&plain)
		wrapped_b, frac_b := dsp.oscillator_advance_modulated(&modulated, 0)

		testing.expectf(t, plain.phase == modulated.phase,
			"phase diverged at sample %v: %v vs %v", i, plain.phase, modulated.phase)
		testing.expectf(t, wrapped_a == wrapped_b,
			"wrap flag diverged at sample %v", i)
		testing.expectf(t, frac_a == frac_b,
			"wrap fraction diverged at sample %v: %v vs %v", i, frac_a, frac_b)
	}
}

// A modulator can drive the phase backwards past zero, and more than a whole
// cycle forwards. Both have to wrap into 0..1 rather than escaping the table.
@(test)
test_modulated_advance_wraps_in_both_directions :: proc(t: ^testing.T) {
	o: dsp.Oscillator
	dsp.oscillator_init(&o, 99)
	dsp.oscillator_set_frequency(&o, 1000.0, SR)

	offsets := []f32{-0.9, -3.7, 0.9, 4.2, -0.5, 2.5}
	for pass in 0 ..< 500 {
		for offset in offsets {
			dsp.oscillator_advance_modulated(&o, offset)
			testing.expectf(t, o.phase >= 0 && o.phase < 1.0,
				"phase left the cycle: %v after offset %v", o.phase, offset)
		}
	}

	// A non-finite displacement must not poison the phase.
	dsp.oscillator_advance_modulated(&o, math.inf_f32(1))
	testing.expect(t, o.phase >= 0 && o.phase < 1.0, "an infinite offset escaped the cycle")
}

// Oscillator 2 is the FM modulator and oscillator 1 is the carrier. Both halves
// of this test invert if the two are swapped, which is the point of writing it
// as a pair.
//
//   - Listening to oscillator 1 alone, the FM amount must change what is heard,
//     because oscillator 1 is the carrier being modulated.
//   - Listening to oscillator 2 alone, the FM amount must change nothing at all,
//     because oscillator 2 is a modulator and is never itself modulated.
//
// Under the opposite direction the first comparison goes identical and the
// second starts differing, so neither assertion can pass by accident.
//
// This pair used to assert the opposite direction, on the strength of a run
// objective that said "FM from oscillator 1". Two primary sources from the
// author of the reference say otherwise, and they are what this now encodes:
// the manual ("oscillator 2 is the modulator, oscillator 1 is the carrier") and
// his write-up of Synth1's oscillator section, which displaces osc1's phase by
// osc2's output. A test can enforce a direction; only the reference can decide
// which one is right.
@(test)
test_fm_modulates_oscillator_one_from_oscillator_two :: proc(t: ^testing.T) {
	N :: 4096

	// Parameter 5 stores oscillator 1's share, so 0 is oscillator 1 alone and
	// 127 is oscillator 2 alone.
	carrier_off := fm_test_patch()
	carrier_off.values[5] = 0
	carrier_off.values[45] = 0
	carrier_on := carrier_off
	carrier_on.values[45] = 127

	// The FM amount really is at its extremes, or "changed the FM amount" is
	// not what this test varied.
	testing.expect_value(t, engine.bind_patch(carrier_off).osc1_fm, 0.0)
	testing.expect_value(t, engine.bind_patch(carrier_on).osc1_fm, 1.0)
	testing.expect_value(t, engine.bind_patch(carrier_on).osc_mix, 0.0)

	a := make([]f32, N)
	b := make([]f32, N)
	defer delete(a)
	defer delete(b)

	fm_render(carrier_off, a)
	fm_render(carrier_on, b)
	carrier_delta := fm_max_difference(a, b)
	testing.expectf(
		t,
		carrier_delta > 0.01,
		"oscillator 1 is not the FM carrier: turning FM up changed its output by only %v",
		carrier_delta,
	)

	// Now oscillator 2 alone. It is the modulator, so the FM amount must not
	// reach it: the two renders have to be sample-for-sample identical.
	mod_off := fm_test_patch()
	mod_off.values[5] = 127
	mod_off.values[45] = 0
	mod_on := mod_off
	mod_on.values[45] = 127
	testing.expect_value(t, engine.bind_patch(mod_on).osc_mix, 1.0)

	fm_render(mod_off, a)
	fm_render(mod_on, b)
	modulator_delta := fm_max_difference(a, b)
	testing.expectf(
		t,
		modulator_delta == 0.0,
		"oscillator 2 is being modulated rather than modulating: FM moved it by %v",
		modulator_delta,
	)

	// Both renders were of something, not of silence, or the equality above
	// would be satisfied by two empty buffers.
	peak: f32 = 0
	for v in b {
		if abs(v) > peak {peak = abs(v)}
	}
	testing.expectf(t, peak > 0.0001, "oscillator 2 render was silent: peak %v", peak)
}

// `s1probe fmsubprobe --values 0,16,24,32,43 --note 48` measures Synth1
// v1.11 directly. At -1oct its signed sub/OSC1 displacement slopes are
// 0.473336, 0.470593, 0.454299 and 0.500492 for the four non-zero FM states.
// Those readings are each nearest the 0.5 fractional-deviation candidate and
// exclude equal absolute displacement (1) and an unmodulated sub (0).
@(test)
test_fm_reaches_sub_with_reference_measured_displacement :: proc(t: ^testing.T) {
	fmsub_patch :: proc(octave, fm: int, sub_on, ring: bool) -> patch.Patch {
		p := fm_test_patch()
		p.values[0] = 0 // oscillator 1: sine
		p.values[1] = 1 // oscillator 2: triangle
		p.values[2] = 40 // oscillator 2: -24 semitones
		p.values[3] = 66 // oscillator 2: 0 cents
		p.values[4] = 1 // keyboard tracking on
		p.values[5] = 0 // oscillator 1 and sub alone
		p.values[45] = fm
		p.values[95] = sub_on ? 127 : 0
		p.values[96] = 0 // sub: sine
		p.values[97] = octave
		p.values[7] = ring ? 1 : 0
		p.values[91] = 1 // fixed, equal start phase
		p.values[19] = 127 // filter open
		p.values[20] = 0 // no resonance
		p.values[21] = 63 // no filter-envelope movement
		p.values[22] = 0 // no filter key tracking
		p.values[23] = 0 // no filter saturation
		p.values[25] = 0 // instant amplifier attack
		p.values[26] = 0 // no amplifier decay
		p.values[27] = 127 // full sustain
		p.values[28] = 0 // instant release
		p.values[29] = 100 // headroom
		p.values[30] = 0 // no velocity scaling
		p.values[37] = 0 // delay dry
		p.values[66] = 0 // chorus off
		p.values[77] = 0 // extra effect off
		return p
	}

	N :: 65536
	base_carrier, base_mix := make([]f32, N), make([]f32, N)
	fm_carrier, fm_mix := make([]f32, N), make([]f32, N)
	defer delete(base_carrier)
	defer delete(base_mix)
	defer delete(fm_carrier)
	defer delete(fm_mix)

	readings := []struct {fm: int, reference_slope: f64} {
		{16, 0.473336},
		{24, 0.470593},
		{32, 0.454299},
		{43, 0.500492},
	}
	for octave in 0 ..< 2 {
		fm_render_at_note(fmsub_patch(octave, 0, false, false), base_carrier, 48)
		fm_render_at_note(fmsub_patch(octave, 0, true, false), base_mix, 48)
		for reading in readings {
			fm_render_at_note(fmsub_patch(octave, reading.fm, false, false), fm_carrier, 48)
			fm_render_at_note(fmsub_patch(octave, reading.fm, true, false), fm_mix, 48)
			slope := fm_sub_audio_slope(base_carrier, base_mix, fm_carrier, fm_mix)
			want := octave == 0 ? 1.0 : reading.reference_slope
			tolerance := octave == 0 ? 0.02 : 0.065
			testing.expectf(t, abs(slope - want) < tolerance,
				"audio at FM state %d and octave %d gives sub/OSC1 slope %.6f; reference %.6f",
				reading.fm, octave, slope, want)
		}
	}

	// Ring suppresses FM in observable output at both octave settings.
	for octave in 0 ..< 2 {
		fm_render_at_note(fmsub_patch(octave, 0, true, true), base_mix, 48)
		for fm in ([]int{43, 77}) {
			fm_render_at_note(fmsub_patch(octave, fm, true, true), fm_mix, 48)
			testing.expectf(t, fm_max_difference(base_mix, fm_mix) == 0,
				"ring output changed with FM state %d at octave %d", fm, octave)
		}
	}
}
// The other direction-sensitive fact: with oscillator 1 alone in the mix and FM
// running, oscillator 2's own shape has to reach the output, because it is the
// modulator shaping the carrier. If oscillator 2 were the carrier instead, its
// shape could not affect an oscillator 1 that nothing modulates.
@(test)
test_fm_modulator_shape_reaches_the_output :: proc(t: ^testing.T) {
	N :: 4096

	base := fm_test_patch()
	base.values[5] = 0 // oscillator 1 alone
	base.values[45] = 127 // full FM

	// Oscillator 2's shapes are display-keyed "1".."4": triangle, saw, pulse,
	// noise. Noise is avoided, because two noise renders differ whatever the
	// FM path does and the comparison would pass for the wrong reason.
	triangle := base
	triangle.values[1] = 1
	saw := base
	saw.values[1] = 2

	// The two patches really do select different oscillator 2 shapes.
	testing.expect(
		t,
		engine.bind_patch(triangle).osc2_shape != engine.bind_patch(saw).osc2_shape,
		"the two patches selected the same oscillator 2 shape",
	)
	// ...and leave oscillator 1's shape alone.
	testing.expect_value(
		t,
		engine.bind_patch(triangle).osc1_shape,
		engine.bind_patch(saw).osc1_shape,
	)

	a := make([]f32, N)
	b := make([]f32, N)
	defer delete(a)
	defer delete(b)

	fm_render(triangle, a)
	fm_render(saw, b)
	delta := fm_max_difference(a, b)
	testing.expectf(
		t,
		delta > 0.01,
		"oscillator 2's shape did not reach the output: difference %v",
		delta,
	)
}

// ------------------------------------------------------------- effect unit

// The unit configured for one type, with both controls and the level given as
// 0..1 positions.
effect_params_for :: proc(type: dsp.Effect_Type, ctl1, ctl2, level: f32) -> dsp.Effect_Params {
	p := dsp.Effect_Params {
		enabled = true,
		type    = type,
		ctl1    = ctl1,
		ctl2    = ctl2,
		level   = level,
	}
	p.hold_samples = dsp.effect_hold_samples(ctl1 * 127.0, SR)
	dsp.effect_derive(&p)
	return p
}

// The compressor is a leveller, and its depth knob is an input gain.
//
// Both halves are measured -- `tools/s1probe/compcurve.odin` -- and both are
// checked here end to end rather than at the constants, because the constants
// are only right if the signal path assembles them the way the measurement read
// them: makeup before the detector, one symmetric time constant, and the curve
// applied to an RMS.
//
// The expectations are the reference's own settled levels. The last four rows
// are the ones that matter most: they are at depths the table was *not* built
// from, and at those depths even the quietest render is already compressing, so
// the makeup cannot be read off them directly. They were predictions first.
@(test)
test_the_compressor_levels_rather_than_compresses :: proc(t: ^testing.T) {
	// Depth is an input gain, linear in decibels over exactly forty of them.
	testing.expect(
		t,
		abs(20.0 * math.log10(dsp.effect_comp_makeup(0)) - 10.0) < 0.01,
		"the compressor's depth no longer starts at +10 dB",
	)
	testing.expect(
		t,
		abs(20.0 * math.log10(dsp.effect_comp_makeup(1)) - 50.0) < 0.01,
		"the compressor's depth no longer reaches +50 dB",
	)

	// One tone at one level, held until the detector has settled, read as RMS
	// over the last third -- which is what the probe reads, so the two are
	// comparable. ctl2 at the top: a slow detector does not move the gain within
	// a cycle, and a fast one does, which is a separate finding and not this one.
	settled :: proc(ctl1_stored, in_db: f32) -> f32 {
		fx: dsp.Effect
		p := effect_params_for(.Compressor, ctl1_stored / 127.0, 1.0, 1.0)
		amplitude := math.pow(f32(10.0), in_db / 20.0) * math.sqrt(f32(2.0))
		total := int(SR * 1.5)
		from := total * 2 / 3
		sum := f64(0)
		n := 0
		for i in 0 ..< total {
			x := amplitude * math.sin(2.0 * math.PI * 440.0 * f32(i) / SR)
			l, _ := dsp.effect_process(&fx, x, x, &p, SR)
			if i >= from {
				sum += f64(l) * f64(l)
				n += 1
			}
		}
		if n == 0 || sum <= 0 {return -200}
		return f32(20.0 * math.log10(math.sqrt(sum / f64(n))))
	}

	for c in ([]struct {
		ctl1, in_db, out_db: f32,
	} {
		// ctl1 = 64: the depth the curve was measured at.
		{64, -51.85, -21.69},
		{64, -42.01, -12.87},
		{64, -35.34, -11.23},
		{64, -27.11, -10.82},
		{64, -16.99, -10.75},
		{64, -4.68, -10.74},
		// And four rows the table never saw.
		{96, -55.43, -15.19},
		{96, -47.44, -11.51},
		{127, -55.43, -11.26},
		{127, -51.85, -10.97},
	}) {
		got := settled(c.ctl1, c.in_db)
		testing.expectf(
			t,
			abs(got - c.out_db) < 0.2,
			"depth %v, %v dB in: the reference settles at %v dB and this settles at %v",
			c.ctl1,
			c.in_db,
			c.out_db,
			got,
		)
	}

	// A leveller's output may never fall as its input rises. The old
	// threshold-and-ratio implementation could not violate this either, but the
	// curve is a table now, and a table can.
	previous := f32(-1e9)
	for db := f32(-40); db <= 20; db += 1 {
		out := db + 20.0 * math.log10(dsp.effect_comp_gain(math.pow(f32(10.0), db / 20.0)))
		testing.expectf(t, out >= previous - 0.001, "the leveller folds back at %v dB in", db)
		previous = out
	}
}

@(test)
test_effect_level_means_different_things_per_type :: proc(t: ^testing.T) {
	// Parameter 81 is not one law. The manual offers two readings of it -- "the
	// amount of the effect, or the balance with the original sound" -- and three
	// were measured. An earlier version of this test asserted the crossfade for
	// all ten types, which was a generalisation from the one type where dry and
	// wet are separable enough to measure; the direct A/B against the reference
	// showed only two types behave that way.

	// The decimator and the ring modulator crossfade, so level 0 is a true bypass
	// and has to be bit-identical.
	for type in ([]dsp.Effect_Type{.Decimator, .Ring_Mod}) {
		fx: dsp.Effect
		p := effect_params_for(type, 0.75, 0.75, 0)
		for i in 0 ..< 512 {
			x := math.sin(f32(i) * 0.05) * 0.7
			l, r := dsp.effect_process(&fx, x, -x, &p, SR)
			testing.expect_value(t, l, x)
			testing.expect_value(t, r, -x)
		}
	}

	// The three distortions have no dry path at all, so level 0 is silence.
	for type in ([]dsp.Effect_Type{.Analog_1, .Analog_2, .Digital}) {
		fx: dsp.Effect
		p := effect_params_for(type, 0.75, 0.75, 0)
		for i in 0 ..< 256 {
			x := math.sin(f32(i) * 0.05) * 0.7
			l, r := dsp.effect_process(&fx, x, -x, &p, SR)
			testing.expect_value(t, l, 0)
			testing.expect_value(t, r, 0)
		}
	}

	// And their wet gain is linear in the knob, measured against L/127.
	dry, wet := dsp.effect_mix(.Analog_1, 64.0 / 127.0)
	testing.expect_value(t, dry, 0)
	testing.expect(t, abs(wet - 0.504) < 0.01, "a.d.1's level is no longer linear in the knob")

	// The compressor's is linear in decibels instead: 30 dB down at level 0, so it
	// is quiet there rather than silent.
	_, comp_zero := dsp.effect_mix(.Compressor, 0)
	_, comp_full := dsp.effect_mix(.Compressor, 1)
	testing.expect_value(t, comp_full, 1)
	testing.expect(
		t,
		abs(20.0 * math.log10(comp_zero) + 30.0) < 0.5,
		"the compressor's level range left its measured 30 dB",
	)
	// Half way up the knob is half way down the range, which is what "linear in
	// decibels" means and is what separates this law from the distortions'.
	_, comp_mid := dsp.effect_mix(.Compressor, 0.5)
	testing.expect(t, abs(20.0 * math.log10(comp_mid) + 15.0) < 0.5)
}

@(test)
test_effect_disabled_passes_through :: proc(t: ^testing.T) {
	fx: dsp.Effect
	p := effect_params_for(.Digital, 1, 1, 1)
	p.enabled = false

	for i in 0 ..< 256 {
		x := math.sin(f32(i) * 0.03)
		l, r := dsp.effect_process(&fx, x, x, &p, SR)
		testing.expect_value(t, l, x)
		testing.expect_value(t, r, x)
	}
}

@(test)
test_effect_measured_curves_hit_their_measured_values :: proc(t: ^testing.T) {
	// The four curves that were read out of the reference in real units. If any of
	// these drifts, the measurement recorded in src/dsp/effect.odin has been lost.

	// The shared low-pass corner: 452 Hz at the bottom, 2901 Hz measured at
	// stored 64, and about 17.6 kHz at the top.
	testing.expect(t, abs(dsp.effect_lowpass_hz(0) - 451.9) < 1.0)
	mid_corner := dsp.effect_lowpass_hz(64.0 / 127.0)
	testing.expect(
		t,
		abs(mid_corner - 2901.0) < 90.0,
		"the low-pass corner at mid knob drifted from its measured 2901 Hz",
	)

	// The ring modulator: 92.7 Hz measured at stored 64, 7869 Hz at the top.
	ring_mid := dsp.effect_ring_hz(64.0 / 127.0)
	testing.expect(
		t,
		abs(ring_mid - 92.7) < 8.0,
		"the ring modulator frequency at mid knob drifted from its measured 92.7 Hz",
	)
	testing.expect(t, abs(dsp.effect_ring_hz(1) - 7869.0) < 400.0)

	// The decimator's step: exactly `stored - 9` samples at 48 kHz, and nothing
	// at all at the bottom of the knob.
	testing.expect_value(t, dsp.effect_hold_samples(127, SR), 118)
	testing.expect_value(t, dsp.effect_hold_samples(64, SR), 55)
	testing.expect_value(t, dsp.effect_hold_samples(9, SR), 0)
	testing.expect_value(t, dsp.effect_hold_samples(0, SR), 0)

	// The compressor's attack: 2 ms to 190 ms.
	testing.expect(t, abs(dsp.effect_comp_attack_s(0) - 0.002) < 0.0005)
	testing.expect(t, abs(dsp.effect_comp_attack_s(1) - 0.190) < 0.005)
}

@(test)
test_effect_decimator_holds_for_the_measured_step :: proc(t: ^testing.T) {
	// The step is read straight back out of the output, the same way it was
	// measured off the reference.
	fx: dsp.Effect
	p := effect_params_for(.Decimator, 127.0 / 127.0, 0, 1)

	out := make([]f32, 2048)
	defer delete(out)
	for i in 0 ..< len(out) {
		x := math.sin(f32(i) * 0.01)
		out[i], _ = dsp.effect_process(&fx, x, x, &p, SR)
	}

	// Count the run length of the first complete hold.
	first_change := 0
	for i in 1 ..< len(out) {
		if out[i] != out[i - 1] {
			first_change = i
			break
		}
	}
	run := 0
	for i in first_change + 1 ..< len(out) {
		if out[i] != out[first_change] {
			break
		}
		run += 1
	}

	testing.expect(t, run + 1 == 118, "the decimator's hold is not the measured 118 samples")
}

@(test)
test_effect_ring_modulator_ignores_its_second_control :: proc(t: ^testing.T) {
	// Measured: five settings of ctl2 gave bit-identical renders, and the manual
	// says r.m. has no second control. Anything that made ctl2 matter here would
	// be an invention.
	a: dsp.Effect
	b: dsp.Effect
	pa := effect_params_for(.Ring_Mod, 0.5, 0, 1)
	pb := effect_params_for(.Ring_Mod, 0.5, 1, 1)

	for i in 0 ..< 512 {
		x := math.sin(f32(i) * 0.02) * 0.6
		la, _ := dsp.effect_process(&a, x, x, &pa, SR)
		lb, _ := dsp.effect_process(&b, x, x, &pb, SR)
		testing.expect_value(t, la, lb)
	}
}

@(test)
test_effect_analog1_makes_even_harmonics_and_analog2_does_not :: proc(t: ^testing.T) {
	// The measured signature that separates the two analogue distortions: a.d.1 is
	// asymmetric and so produces even harmonics, a.d.2 is odd-symmetric and cannot.
	// Checked here on the shapers rather than through a spectrum, because
	// asymmetry is exactly the property being asserted: f(-x) = -f(x) for one and
	// not the other. a.d.1 carries a loop, so each polarity gets its own state and
	// is driven to rest first -- asymmetry in a loop is still asymmetry, and the
	// bias is what produces the even harmonics measured.
	symmetric_error, asymmetric_error: f32
	for i in 1 ..= 64 {
		x := f32(i) / 64.0 * 0.9
		pos, neg: [2]f32
		p1, n1: f32
		for _ in 0 ..< 64 {
			p1 = dsp.effect_shape_analog1(&pos, x, 8, 1, 0.01)
			n1 = dsp.effect_shape_analog1(&neg, -x, 8, 1, 0.01)
		}
		a2 := dsp.effect_shape_analog2(x, 8, 1) + dsp.effect_shape_analog2(-x, 8, 1)
		asymmetric_error += abs(p1 + n1)
		symmetric_error += abs(a2)
	}

	testing.expect(t, symmetric_error < 1.0e-4, "a.d.2 is not odd-symmetric, so it will make even harmonics")
	testing.expect(t, asymmetric_error > 0.5, "a.d.1 is symmetric, so it cannot make the even harmonics measured")
}

@(test)
test_effect_phaser_curves_match_the_saw_comb_measurement :: proc(t: ^testing.T) {
	// The rate law, measured by autocorrelating the frame-by-frame transfer
	// function of a saw wave driven through the reference. Five settings spanned
	// 0.27 to 7.81 Hz at 2.33 times per 16 steps.
	for pair in ([][2]f32{{48, 0.27}, {64, 0.65}, {80, 1.51}, {96, 3.61}, {112, 7.81}}) {
		measured := pair[1]
		ours := dsp.effect_phaser_rate_hz(pair[0] / 127.0)
		// Within a fifth, which is well inside the spread of the fit itself.
		testing.expect(
			t,
			ours > measured * 0.8 && ours < measured * 1.25,
			fmt.tprintf("rate at ctl2 %.0f is %.2f Hz, measured %.2f", pair[0], ours, measured),
		)
	}

	// The section counts, which the fitted circuit and the resonance count both
	// require: 2, 4, 8 and 12 accumulate enough phase for exactly 1, 2, 4 and 6
	// resonances above DC, and that is what the comb probe found.
	testing.expect_value(t, dsp.effect_phaser_stages(.Phaser_1), 2)
	testing.expect_value(t, dsp.effect_phaser_stages(.Phaser_2), 4)
	testing.expect_value(t, dsp.effect_phaser_stages(.Phaser_3), 8)
	testing.expect_value(t, dsp.effect_phaser_stages(.Phaser_4), 12)
}

// The phasers' comb comes out where the reference's does.
//
// This is the check the whole rewrite rests on, and it is not a fit: the corner
// is one frequency, and where the resonances land follows from the phase
// accumulating 180 degrees per section and the loop resonating wherever that
// passes a multiple of 360. Thirteen resonances across four types, from one
// number.
@(test)
test_effect_phaser_comb_lands_where_it_was_measured :: proc(t: ^testing.T) {
	corner := f64(dsp.EFFECT_PHASER_CORNER_REST_HZ)

	// The loop's phase, in radians: the sections, plus the one sample of delay the
	// feedback carries. That delay is not a rounding detail -- leaving it out puts
	// every resonance too high, and ph1's by a quarter.
	phase :: proc(f, corner: f64, sections: int) -> f64 {
		w := 2.0 * math.PI * f / 48000.0
		t := math.tan(math.PI * corner / 48000.0)
		c := (t - 1.0) / (t + 1.0)
		sw, cw := math.sin(w), math.cos(w)
		// One section: the numerator's angle less the denominator's. It runs from
		// zero at DC to -pi at Nyquist without wrapping, for a negative c.
		one := math.atan2(-sw, c + cw) - math.atan2(-c * sw, 1.0 + c * cw)
		return f64(sections) * one - w
	}

	for c in ([]struct {
		type:       dsp.Effect_Type,
		resonances: []f64,
	} {
		{.Phaser_1, {2771}},
		{.Phaser_2, {251, 3899}},
		{.Phaser_3, {104, 255, 605, 5457}},
		{.Phaser_4, {66, 147, 256, 441, 932, 6613}},
	}) {
		sections := dsp.effect_phaser_stages(c.type)
		for measured, k in c.resonances {
			// Where the loop's phase passes a whole turn, k+1 times over.
			lo, hi := f64(1), f64(23000)
			for _ in 0 ..< 200 {
				mid := math.sqrt(lo * hi)
				if phase(mid, corner, sections) > -2.0 * math.PI * f64(k + 1) {
					lo = mid
				} else {
					hi = mid
				}
			}
			got := math.sqrt(lo * hi)
			testing.expectf(
				t,
				abs(got / measured - 1.0) < 0.06,
				"%v resonance %v: the reference has it at %v Hz, this circuit puts it at %.0f",
				c.type,
				k + 1,
				measured,
				got,
			)
		}
	}
}

// Parameter 81 is a crossfade for two thirds of its travel and feedback for the
// last third. Both halves are measured; the zero below the knee is the part that
// an earlier reading of this knob got wrong.
@(test)
test_effect_phaser_level_is_a_crossfade_then_feedback :: proc(t: ^testing.T) {
	for level in ([]f32{0, 16, 32, 48, 56, 64}) {
		testing.expectf(
			t,
			dsp.effect_phaser_feedback(level / 127.0) == 0,
			"the phaser has feedback at level %v, where the reference has none",
			level,
		)
	}
	for c in ([]struct {
		level, feedback: f32,
	}{{80, 0.2505}, {96, 0.4977}, {112, 0.7439}, {127, 0.9747}}) {
		got := dsp.effect_phaser_feedback(c.level / 127.0)
		testing.expectf(
			t,
			abs(got - c.feedback) < 0.03,
			"feedback at level %v is %v, measured %v",
			c.level,
			got,
			c.feedback,
		)
	}

	// And the crossfade under it: dry falls while wet rises, and at the bottom of
	// the knob the wet path is shut and the response is the dry gain alone.
	d0, w0 := dsp.effect_phaser_mix(0)
	dk, wk := dsp.effect_phaser_mix(64.0 / 127.0)
	testing.expect_value(t, d0, 1.0)
	testing.expect_value(t, w0, 0.0)
	// And at the midpoint it arrives at a plain sum, which is where it stays.
	testing.expect_value(t, dk, 0.5)
	testing.expect_value(t, wk, 0.5)
	df, wf := dsp.effect_phaser_mix(1)
	testing.expect_value(t, df, 0.5)
	testing.expect_value(t, wf, 0.5)
}

@(test)
test_effect_phaser_sweeps_on_its_own :: proc(t: ^testing.T) {
	// Measured: the resonance sweeps with a period of about 277 ms at mid settings,
	// so the sweep is internal. A static filter would hold one level, and that is
	// the failure this catches.
	fx: dsp.Effect
	p := effect_params_for(.Phaser_2, 1, 0.756, 1)

	// Two windows a quarter of the LFO period apart must differ in level.
	rate := p.phaser_rate_hz
	testing.expect(t, rate > 0.5 && rate < 20.0, "the phaser rate left its measured range")

	quarter := int(0.25 * SR / rate)
	total := quarter * 4
	energy := make([]f32, 4)
	defer delete(energy)
	for i in 0 ..< total {
		x := math.sin(f32(i) * 0.02) * 0.7
		l, _ := dsp.effect_process(&fx, x, x, &p, SR)
		energy[min(i / quarter, 3)] += l * l
	}

	lo, hi := energy[0], energy[0]
	for v in energy {
		lo = min(lo, v)
		hi = max(hi, v)
	}
	testing.expect(t, hi > lo * 1.05, "the phaser's level does not move, so it is not sweeping")
}

@(test)
test_effect_output_stays_finite_at_every_extreme :: proc(t: ^testing.T) {
	// Every type, both controls at both ends, driven past full scale. The unit sits
	// in front of the delay and the chorus, so one non-finite sample here would
	// live in their feedback paths forever.
	for type in dsp.Effect_Type {
		for c1 in ([]f32{0, 1}) {
			for c2 in ([]f32{0, 1}) {
				fx: dsp.Effect
				p := effect_params_for(type, c1, c2, 1)
				for i in 0 ..< 2048 {
					x := math.sin(f32(i) * 0.07) * 4.0
					l, r := dsp.effect_process(&fx, x, -x, &p, SR)
					testing.expect(t, l == l && r == r, "the effect unit produced a NaN")
					testing.expect(t, abs(l) < 1000 && abs(r) < 1000, "the effect unit ran away")
				}
			}
		}
	}
}

@(test)
test_chorus_four_taps_are_narrower_than_two :: proc(t: ^testing.T) {
	// Measured on the reference: side/mid goes 0.000, 0.538, 0.418 for one, two and
	// four taps, so four taps are *narrower* than two. An earlier arrangement made
	// them wider -- 0.676 -- by handing each channel two taps at full level instead
	// of averaging them, and that showed up on the bank as 21.98 dB of spectral error
	// on the twelve patches using four taps, against about 9.6 for everything else.
	SR_LOCAL :: f32(48000.0)
	N :: 24000

	width :: proc(stages: int) -> f64 {
		left_buf := make([]f32, 4096)
		defer delete(left_buf)
		right_buf := make([]f32, 4096)
		defer delete(right_buf)
		c: dsp.Chorus
		dsp.chorus_init(&c, left_buf, right_buf)

		p := dsp.Chorus_Params {
			stages        = stages,
			delay_samples = 1200, // 25 ms
			depth         = 0.6,
			rate_hz       = 2.0,
			feedback      = 0,
			level         = 1.0,
		}

		// A deterministic broadband source, so both channels see the same input.
		state: u32 = 0x1234_5678
		mid, side := 0.0, 0.0
		for i in 0 ..< N {
			state = state * 1664525 + 1013904223
			x := f32(i32(state >> 8)) / f32(1 << 23) - 1.0
			l, r := dsp.chorus_process(&c, x, x, &p, SR_LOCAL)
			if i > N / 4 {
				m := 0.5 * (f64(l) + f64(r))
				s := 0.5 * (f64(l) - f64(r))
				mid += m * m
				side += s * s
			}
		}
		return mid > 0 ? math.sqrt(side / mid) : 0
	}

	one := width(1)
	two := width(2)
	four := width(4)

	// One tap is mono, which the reference measures as side/mid of exactly zero.
	testing.expect(t, one < 1.0e-6, fmt.tprintf("one tap was not mono: %.6f", one))
	testing.expect(t, two > 0.1, fmt.tprintf("two taps produced no width: %.4f", two))
	testing.expect(
		t,
		four < two,
		fmt.tprintf("four taps (%.4f) should be narrower than two (%.4f)", four, two),
	)
}

@(test)
test_effect_analog_drive_saturates :: proc(t: ^testing.T) {
	// The largest error in the old distortions was the drive, which ran
	// exponentially to 64 while the reference's stops moving: a.d.2's odd
	// harmonics are identical at ctl1 80, 96, 112 and 127, so whatever drives it
	// has reached its end well before the knob does.
	top := dsp.effect_ad_table(dsp.EFFECT_AD2_DRIVE, 1.0)
	at80 := dsp.effect_ad_table(dsp.EFFECT_AD2_DRIVE, 80.0 / 127.0)
	testing.expect(
		t,
		abs(top - at80) < 1.0e-3,
		fmt.tprintf("a.d.2's drive still moves above ctl1 80: %.3f against %.3f", at80, top),
	)
	testing.expect(t, top < 64.0, fmt.tprintf("a.d.2's drive reaches %.1f, the old law's ceiling", top))

	// And it rises monotonically below that, which is what a drive knob does.
	prev := f32(-1)
	for c in 0 ..= 127 {
		d := dsp.effect_ad_table(dsp.EFFECT_AD2_DRIVE, f32(c) / 127.0)
		testing.expect(t, d >= prev, fmt.tprintf("a.d.2's drive fell at ctl1 %d", c))
		prev = d
	}

}

@(test)
test_effect_digital_folds_rather_than_clips :: proc(t: ^testing.T) {
	// d.d.'s curve was read off its own harmonics rather than fitted, and what it
	// draws is a triangle fold: at ctl1 16 it rises along a slope of 1.2 to a peak
	// of 0.83 at x = 0.69 and comes back down, reaching 0.651 at x = 0.83 where a
	// triangle predicts 0.662. A clipper stays at its ceiling instead.
	drive := dsp.effect_ad_table(dsp.EFFECT_DD_DRIVE, 16.0 / 127.0)
	gain := dsp.effect_ad_table(dsp.EFFECT_DD_GAIN, 16.0 / 127.0)

	peak := dsp.effect_shape_digital(1.0 / drive, drive, gain)
	past := dsp.effect_shape_digital(1.35 / drive, drive, gain)
	testing.expect(
		t,
		past < peak * 0.9,
		fmt.tprintf("d.d. did not turn back: %.3f at the fold, %.3f past it", peak, past),
	)

	// The fold is odd-symmetric, which is why its even harmonics measure 70 dB
	// down, and it is continuous across every reflection.
	for i in 1 ..= 200 {
		x := f32(i) / 40.0
		a := dsp.effect_shape_digital(x, drive, gain)
		b := dsp.effect_shape_digital(-x, drive, gain)
		testing.expect(t, abs(a + b) < 1.0e-5, fmt.tprintf("d.d. is not odd at %.3f", x))
	}
	prev := dsp.effect_shape_digital(0, drive, gain)
	for i in 1 ..= 4000 {
		x := f32(i) / 200.0
		v := dsp.effect_shape_digital(x, drive, gain)
		testing.expect(
			t,
			abs(v - prev) < 0.05,
			fmt.tprintf("d.d. jumped at %.3f: %.3f to %.3f", x, prev, v),
		)
		prev = v
	}
}

@(test)
test_effect_analog1_is_a_loop_and_settles :: proc(t: ^testing.T) {
	// a.d.1 is the one type here that is not memoryless: the phases of its
	// harmonics read 0.146 to 0.439 where a.d.2 reads 0.011 to 0.042. So the same
	// input twice must not give the same output -- that is the whole point -- and
	// the loop must still be stable, which a feedback path has to be checked for.
	SR_LOCAL :: f32(48000.0)
	coef := dsp.one_pole_coef(dsp.EFFECT_ANALOG1_FEEDBACK_HZ, SR_LOCAL)
	drive := dsp.effect_ad_table(dsp.EFFECT_AD1_DRIVE, 1.0)
	gain := dsp.effect_ad_table(dsp.EFFECT_AD1_GAIN, 1.0)

	state: [2]f32
	first := dsp.effect_shape_analog1(&state, 0.5, drive, gain, coef)
	settled := first
	for _ in 0 ..< 4000 {
		settled = dsp.effect_shape_analog1(&state, 0.5, drive, gain, coef)
	}
	testing.expect(
		t,
		abs(settled - first) > 1.0e-6,
		"a.d.1 gave the same answer to the same input twice, so it has no loop",
	)

	// Stability: driven hard for a second, nothing may run away or go non-finite.
	loud: [2]f32
	for i in 0 ..< 48000 {
		x := f32(i % 97) / 48.0 - 1.0
		v := dsp.effect_shape_analog1(&loud, x, drive, gain, coef)
		if !(abs(v) <= gain * 1.001) || v != v {
			testing.expect(t, false, fmt.tprintf("a.d.1 left its rails at sample %d: %.4f", i, v))
			break
		}
	}
}
